# Finite-difference guard for SOL105 static-preload design-dependent loads.
#
# The buckling gradient uses the preload derivative
#   K du/dx = dF/dx - dK/dx * u_static
# before differentiating geometric stiffness. This guard isolates that state
# derivative on a PLOAD4 pressure preload so the load-vector term is nonzero.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_preload_load_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_pressure_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL105 preload load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,2,4")
        println(io, "PLOAD4,1,1,100.")
        println(io, "EIGRL,1,0.,1.0E9,2")
        println(io, "ENDDATA")
    end
    return path
end

function _with_node_coord(model, grid::Int, comp::Int, delta::Float64)
    m = deepcopy(model)
    grid_data = m["GRIDs"][string(grid)]
    coords = Float64.(collect(grid_data["X"]))
    coords[comp] += delta
    grid_data["X"] = coords
    return m
end

function _sol105_static_reference_state(model::Dict)
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag =
        OpenJFEM._tacs_assemble_sol101(
            model;
            allowed_sol_types=(105,),
            route_label="SOL105 preload load sensitivity guard",
        )
    sub = model["CASE_CONTROL"]["SUBCASES"][1]
    load_id = get(sub, "LOAD", nothing)
    spc_id = get(sub, "SPC", nothing)
    _, _, _, u_static, fixed_dofs = OpenJFEM.Solver.solve_case(
        K,
        ndof,
        model,
        id_map,
        X,
        load_id,
        spc_id,
        node_R;
        max_elem_stiff=max_elem_stiff,
        rbe3_map=rbe3_map,
        snorm_normals=snorm_normals,
        orig_diag=orig_diag,
    )
    return Dict{String,Any}(
        "sol_type" => 105,
        "model" => model,
        "K" => K,
        "id_map" => id_map,
        "node_coords" => X,
        "ndof" => ndof,
        "node_R" => node_R,
        "rbe3_map" => rbe3_map,
        "u_static" => u_static,
        "fixed_dofs" => fixed_dofs,
        "solver_diagnostics" => Any[Dict{String,Any}("static_subcase" => 1)],
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol105_preload_load_sens_")
    deck = _write_pressure_sol105_deck(joinpath(tmp, "pressure_sol105.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = _sol105_static_reference_state(model)
    dv = Dict{String,Any}("id" => "grid3_x", "type" => "node_coord", "grid" => 3, "comp" => 1, "step" => 1e-6)
    dK, _, _, _, _, stiffness_steps = OpenJFEM._tacs_assemble_sol101_design_derivative(
        model,
        dv;
        allowed_sol_types=(105,),
        route_label="SOL105 preload load sensitivity guard",
    )
    dF, load_steps = OpenJFEM._tacs_sol105_static_load_design_derivative(results, dv; stiffness_steps=stiffness_steps)
    @test norm(dF) > 1e-6
    du_hook = OpenJFEM._tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)

    h = maximum(vcat(Float64.(stiffness_steps), Float64.(load_steps)))
    @test h > 0.0
    results_p = _sol105_static_reference_state(_with_node_coord(model, 3, 1, h))
    results_m = _sol105_static_reference_state(_with_node_coord(model, 3, 1, -h))
    du_fd = (Float64.(results_p["u_static"]) .- Float64.(results_m["u_static"])) ./ (2.0 * h)
    relerr = norm(du_hook .- du_fd) / max(norm(du_hook), norm(du_fd), 1e-30)
    @test relerr < 5e-5

    println("TACS SOL105 preload load sensitivity check passed")
    println("  deck           = ", abspath(deck))
    println("  dF/dX norm     = ", norm(dF))
    println("  du/dX FD norm  = ", norm(du_fd))
    println("  du/dX hook norm = ", norm(du_hook))
    println("  du/dX rel error = ", relerr)
end

main()
