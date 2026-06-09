# Finite-difference guard for TACS-formulation static design-dependent loads.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_load_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_pressure_quad_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 pressure load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
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

function _compliance_value(results)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return dot(u, results["K"] * u)
end

function _displacement_value(results, response)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return Float64(OpenJFEM.Solver.evaluate_response(
        response,
        u,
        results["model"],
        results["id_map"],
        results["ndof"],
        results["node_coords"],
        results["node_R"],
    ))
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol101_load_sens_")
    deck = _write_pressure_quad_deck(joinpath(tmp, "pressure_quad.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    dv = Dict{String,Any}("id" => "grid3_x", "type" => "node_coord", "grid" => 3, "comp" => 1)
    comp_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    comp_diag = comp_response["design_variable_diagnostics"][dv["id"]]
    @test comp_diag["load_derivative_nonzero"] == true
    @test Float64(comp_diag["load_derivative_norm"]) > 1e-6
    h = Float64(comp_diag["step"])
    @test h > 0.0

    model_p = _with_node_coord(model, 3, 1, h)
    model_m = _with_node_coord(model, 3, 1, -h)
    results_p = OpenJFEM.solve_model(model_p)
    results_m = OpenJFEM.solve_model(model_m)

    comp_fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
    comp_grad = Float64(comp_response["gradient"][dv["id"]])
    comp_relerr = _relerr(comp_grad, comp_fd)
    @test comp_relerr < 5e-4

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 3, "dof" => 3)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    disp_diag = disp_response["design_variable_diagnostics"][dv["id"]]
    @test disp_diag["load_derivative_nonzero"] == true
    disp_fd = (_displacement_value(results_p, disp_resp) - _displacement_value(results_m, disp_resp)) / (2.0 * h)
    disp_grad = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_grad, disp_fd)
    @test disp_relerr < 5e-4

    println("TACS SOL101 design-dependent load sensitivity check passed")
    println("  deck                     = ", abspath(deck))
    println("  dF/dX norm               = ", comp_diag["load_derivative_norm"])
    println("  dCompliance/dX FD        = ", comp_fd)
    println("  dCompliance/dX hook      = ", comp_grad)
    println("  dCompliance/dX rel error = ", comp_relerr)
    println("  dU/dX FD                 = ", disp_fd)
    println("  dU/dX hook               = ", disp_grad)
    println("  dU/dX rel error          = ", disp_relerr)
end

main()
