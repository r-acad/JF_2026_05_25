# Finite-difference guard for SOL101 centrifugal RFORCE load sensitivity.
#
# RFORCE inertial loads depend on element mass and geometry. This guard checks
# the material-density load-only adjoint path for compliance, scalar
# displacement, and single-entry KS displacement on the shell slice and on the
# two-node CROD/CONROD/CBAR/CBEAM line-element slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_rforce_load_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0
const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_rforce_quad_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 RFORCE load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,1.,0.,0.")
        println(io, "GRID,2,,2.,0.,0.")
        println(io, "GRID,3,,2.,1.,0.")
        println(io, "GRID,4,,1.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,2,4")
        println(io, "RFORCE,1,0,0,0.5,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_rforce_rod_deck(path::AbstractString, card_type::AbstractString)
    card = uppercase(card_type)
    A = card == "CROD" ? 1.0e-2 : 7.0e-3
    J = card == "CROD" ? 2.5e-5 : 1.6e-5
    x0 = 1.0
    L = card == "CROD" ? 2.0 : 1.5
    rate = 0.5
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 $card RFORCE load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,$x0,0.,0.")
        println(io, "GRID,2,,$(x0 + L),0.,0.")
        if card == "CROD"
            println(io, "CROD,1,1,1,2")
            println(io, "PROD,1,1,$A,$J")
        else
            println(io, "CONROD,1,1,2,1,$A,$J")
        end
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "RFORCE,1,0,0,$rate,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, x0=x0, length=L, rate=rate, E=E_ROD)
end

function _write_rforce_beam_deck(path::AbstractString, card_type::AbstractString)
    card = uppercase(card_type)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    x0 = 1.0
    L = 2.0
    rate = 0.5
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 $card RFORCE load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,$x0,0.,0.")
        println(io, "GRID,2,,$(x0 + L),0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "RFORCE,1,0,0,$rate,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, x0=x0, length=L, rate=rate, E=E_BEAM)
end

function _with_material_field(model, mid::Int, field::AbstractString, delta::Float64)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + delta
    return m
end

function _compliance_value(results)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return dot(u, results["K"] * u)
end

function _response_value(results, response)
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

function _ks_displacement_response(grid::Integer, dof::Integer=1)
    return Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [Int(grid)],
        "dof" => Int(dof),
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
end

function _check_shell_rforce(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    dv = Dict{String,Any}("id" => "mat1_rho", "type" => "material_RHO", "mids" => [1])
    comp_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    @test comp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    comp_diag = comp_response["design_variable_diagnostics"][dv["id"]]
    @test comp_diag["load_derivative_nonzero"] == true
    @test Float64(comp_diag["load_derivative_norm"]) > 1e-9
    h = Float64(comp_diag["step"])
    @test h > 0.0

    results_p = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", h))
    results_m = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", -h))

    comp_fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
    comp_hook = Float64(comp_response["gradient"][dv["id"]])
    comp_relerr = _relerr(comp_hook, comp_fd)
    @test comp_relerr < 1e-6

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 3, "dof" => 1)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    @test disp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    disp_fd = (_response_value(results_p, disp_resp) - _response_value(results_m, disp_resp)) / (2.0 * h)
    disp_hook = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_hook, disp_fd)
    @test disp_relerr < 1e-6

    ks_resp = _ks_displacement_response(3, 1)
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_resp, [dv])
    @test ks_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    ks_fd = (_response_value(results_p, ks_resp) - _response_value(results_m, ks_resp)) / (2.0 * h)
    ks_hook = Float64(ks_response["gradient"][dv["id"]])
    ks_relerr = _relerr(ks_hook, ks_fd)
    @test ks_relerr < 1e-6

    return Dict(
        "deck" => abspath(deck),
        "load_norm" => Float64(comp_diag["load_derivative_norm"]),
        "compliance" => (fd=comp_fd, hook=comp_hook, rel=comp_relerr),
        "displacement" => (fd=disp_fd, hook=disp_hook, rel=disp_relerr),
        "ks_displacement" => (fd=ks_fd, hook=ks_hook, rel=ks_relerr),
    )
end

function _expected_line_density_displacement(case)
    omega2 = (2.0 * pi * case.rate)^2
    L = Float64(case.length)
    x0 = Float64(case.x0)
    return omega2 / Float64(case.E) * (0.5 * x0 * L^2 + L^3 / 3.0)
end

function _check_line_rforce(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    dv = Dict{String,Any}("id" => "$(lowercase(case.card))_rho", "type" => "material_RHO", "mids" => [1])
    comp_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    @test comp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    comp_diag = comp_response["design_variable_diagnostics"][dv["id"]]
    @test comp_diag["load_derivative_nonzero"] == true
    @test Float64(comp_diag["load_derivative_norm"]) > 1e-9
    h = Float64(comp_diag["step"])
    @test h > 0.0

    results_p = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", h))
    results_m = OpenJFEM.solve_model(_with_material_field(model, 1, "RHO", -h))

    comp_fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
    comp_hook = Float64(comp_response["gradient"][dv["id"]])
    comp_relerr = _relerr(comp_hook, comp_fd)
    @test comp_relerr < 1e-6

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 1)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    @test disp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    disp_fd = (_response_value(results_p, disp_resp) - _response_value(results_m, disp_resp)) / (2.0 * h)
    disp_hook = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_hook, disp_fd)
    expected_disp = _expected_line_density_displacement(case)
    expected_relerr = _relerr(disp_hook, expected_disp)
    @test disp_relerr < 1e-6
    @test expected_relerr < 1e-6

    ks_resp = _ks_displacement_response(2, 1)
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_resp, [dv])
    @test ks_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    ks_fd = (_response_value(results_p, ks_resp) - _response_value(results_m, ks_resp)) / (2.0 * h)
    ks_hook = Float64(ks_response["gradient"][dv["id"]])
    ks_relerr = _relerr(ks_hook, ks_fd)
    ks_expected_relerr = _relerr(ks_hook, expected_disp)
    @test ks_relerr < 1e-6
    @test ks_expected_relerr < 1e-6

    return Dict(
        "deck" => abspath(case.path),
        "load_norm" => Float64(comp_diag["load_derivative_norm"]),
        "compliance" => (fd=comp_fd, hook=comp_hook, rel=comp_relerr),
        "displacement" => (fd=disp_fd, hook=disp_hook, rel=disp_relerr, expected=expected_disp, expected_rel=expected_relerr),
        "ks_displacement" => (fd=ks_fd, hook=ks_hook, rel=ks_relerr, expected=expected_disp, expected_rel=ks_expected_relerr),
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol101_rforce_load_sens_")
    shell = _check_shell_rforce(_write_rforce_quad_deck(joinpath(tmp, "rforce_quad.bdf")))
    cases = (
        _write_rforce_rod_deck(joinpath(tmp, "rforce_crod.bdf"), "CROD"),
        _write_rforce_rod_deck(joinpath(tmp, "rforce_conrod.bdf"), "CONROD"),
        _write_rforce_beam_deck(joinpath(tmp, "rforce_cbar.bdf"), "CBAR"),
        _write_rforce_beam_deck(joinpath(tmp, "rforce_cbeam.bdf"), "CBEAM"),
    )
    line_checks = [(case.card, _check_line_rforce(case)) for case in cases]

    println("TACS SOL101 RFORCE load sensitivity check passed")
    println("  shell deck               = ", shell["deck"])
    println("  shell dF/dRHO norm       = ", shell["load_norm"])
    println("  shell dCompliance FD/hook/rel = ",
        shell["compliance"].fd, " / ", shell["compliance"].hook, " / ", shell["compliance"].rel)
    println("  shell dU/dRHO FD/hook/rel = ",
        shell["displacement"].fd, " / ", shell["displacement"].hook, " / ", shell["displacement"].rel)
    println("  shell dKSdisp/dRHO FD/hook/rel = ",
        shell["ks_displacement"].fd, " / ", shell["ks_displacement"].hook, " / ", shell["ks_displacement"].rel)
    for (name, checks) in line_checks
        println("  $name deck                = ", checks["deck"])
        println("  $name dF/dRHO norm        = ", checks["load_norm"])
        println("  $name dCompliance FD/hook/rel = ",
            checks["compliance"].fd, " / ", checks["compliance"].hook, " / ", checks["compliance"].rel)
        println("  $name dU/dRHO FD/hook/expected/rel = ",
            checks["displacement"].fd, " / ", checks["displacement"].hook, " / ",
            checks["displacement"].expected, " / ", checks["displacement"].rel)
        println("  $name dU/dRHO expected rel = ", checks["displacement"].expected_rel)
        println("  $name dKSdisp/dRHO FD/hook/expected/rel = ",
            checks["ks_displacement"].fd, " / ", checks["ks_displacement"].hook, " / ",
            checks["ks_displacement"].expected, " / ", checks["ks_displacement"].rel)
        println("  $name dKSdisp/dRHO expected rel = ", checks["ks_displacement"].expected_rel)
    end
end

main()
