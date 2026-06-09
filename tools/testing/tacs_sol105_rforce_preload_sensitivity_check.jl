# Finite-difference guard for SOL105 RFORCE inertial-preload sensitivity.
#
# RFORCE shell preload depends on shell mass and geometry. This guard checks the
# SOL105 load-driven Rayleigh Kg path for MAT1 density variables and the total
# coordinate path on a centrifugal preload.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_rforce_preload_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_rforce_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL105 RFORCE preload sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,1.,0.,0.")
        println(io, "GRID,2,,2.,0.,0.")
        println(io, "GRID,3,,2.,1.,0.")
        println(io, "GRID,4,,1.,1.,0.")
        println(io, "GRID,5,,3.,0.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "SPC1,2,123456,5")
        println(io, "RFORCE,1,5,0,0.5,0.,0.,1.")
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "ENDDATA")
    end
    return path
end

function _with_material_field(model, mid::Int, field::AbstractString, delta::Float64)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + delta
    m["backend"] = "tacs_formulation"
    return m
end

function _with_node_coord(model, grid::Int, comp::Int, delta::Float64)
    m = deepcopy(model)
    grid_data = m["GRIDs"][string(grid)]
    coords = Float64.(collect(grid_data["X"]))
    coords[comp] += delta
    grid_data["X"] = coords
    m["backend"] = "tacs_formulation"
    return m
end

_first_lambda(results) = Float64(results["eigenvalues"][1])

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol105_rforce_preload_sens_")
    deck = _write_rforce_sol105_deck(joinpath(tmp, "rforce_sol105.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    @test length(results["eigenvalues"]) >= 1
    dv = Dict{String,Any}("id" => "mat1_rho", "type" => "material_RHO", "mids" => [1])
    response = OpenJFEM.buckling_load_factor_design_gradient(results, [dv]; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_load_kg_directional_fd"
    diag = response["design_variable_diagnostics"][dv["id"]]
    @test diag["load_derivative_nonzero"] == true
    @test Float64(diag["load_derivative_norm"]) > 1e-8
    h = Float64(diag["step"])
    @test h > 0.0

    results_p = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", h))
    results_m = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", -h))
    fd = (_first_lambda(results_p) - _first_lambda(results_m)) / (2.0 * h)
    hook = Float64(response["gradient"][dv["id"]])
    relerr = _relerr(hook, fd)
    @test relerr < 2e-5

    coord_dv = Dict{String,Any}("id" => "grid3_x", "type" => "node_coord", "grid" => 3, "comp" => 1)
    coord_response = OpenJFEM.buckling_load_factor_design_gradient(results, [coord_dv]; mode=1)
    @test coord_response["gradient_backend"] == "tacs_formulation_rayleigh_coordinate_kg_directional_fd"
    coord_diag = coord_response["design_variable_diagnostics"][coord_dv["id"]]
    @test coord_diag["load_derivative_nonzero"] == true
    @test Float64(coord_diag["load_derivative_norm"]) > 1e-8
    h_x = Float64(coord_diag["step"])
    @test h_x > 0.0

    coord_results_p = OpenJFEM.solve_model(_with_node_coord(model, 3, 1, h_x))
    coord_results_m = OpenJFEM.solve_model(_with_node_coord(model, 3, 1, -h_x))
    coord_fd = (_first_lambda(coord_results_p) - _first_lambda(coord_results_m)) / (2.0 * h_x)
    coord_hook = Float64(coord_response["gradient"][coord_dv["id"]])
    coord_relerr = _relerr(coord_hook, coord_fd)
    @test coord_relerr < 5e-4

    println("TACS SOL105 RFORCE preload sensitivity check passed")
    println("  deck                 = ", abspath(deck))
    println("  first eigenvalue     = ", _first_lambda(results))
    println("  dF/dRHO norm         = ", diag["load_derivative_norm"])
    println("  dLambda/dRHO FD      = ", fd)
    println("  dLambda/dRHO hook    = ", hook)
    println("  dLambda/dRHO relerr  = ", relerr)
    println("  dF/dX norm           = ", coord_diag["load_derivative_norm"])
    println("  dLambda/dX FD        = ", coord_fd)
    println("  dLambda/dX hook      = ", coord_hook)
    println("  dLambda/dX relerr    = ", coord_relerr)
end

main()
