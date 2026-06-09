# Finite-difference guard for SOL101 gravity-load design sensitivity.
#
# Material density does not affect the guarded static shell/beam stiffness, but
# it does affect GRAV loads. This checks the load-only adjoint path for the
# shell slice and the constant-section CBAR/CBEAM beam slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_gravity_load_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_gravity_quad_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 gravity load sensitivity guard")
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
        println(io, "GRAV,1,0,9.81,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_gravity_beam_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    g = 9.81
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 $card gravity load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,1246,2")
        println(io, "GRAV,1,0,$g,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I2=I2, length=L, gravity=g)
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

function _check_shell_gravity(deck::AbstractString)
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

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 3, "dof" => 3)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    @test disp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    disp_fd = (_response_value(results_p, disp_resp) - _response_value(results_m, disp_resp)) / (2.0 * h)
    disp_hook = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_hook, disp_fd)
    @test disp_relerr < 1e-6

    stress_resp = Dict{String,Any}(
        "type" => "ks_von_mises",
        "eids" => "all",
        "surface" => "top",
        "rho" => 25.0,
        "sigma_ref" => 1.0,
    )
    stress_response = OpenJFEM.static_ks_von_mises_design_gradient(results, stress_resp, [dv])
    @test stress_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    stress_fd = (_response_value(results_p, stress_resp) - _response_value(results_m, stress_resp)) / (2.0 * h)
    stress_hook = Float64(stress_response["gradient"][dv["id"]])
    stress_relerr = _relerr(stress_hook, stress_fd)
    @test stress_relerr < 1e-5

    return Dict(
        "deck" => abspath(deck),
        "load_norm" => Float64(comp_diag["load_derivative_norm"]),
        "compliance" => (fd=comp_fd, hook=comp_hook, rel=comp_relerr),
        "displacement" => (fd=disp_fd, hook=disp_hook, rel=disp_relerr),
        "stress_ks" => (fd=stress_fd, hook=stress_hook, rel=stress_relerr),
    )
end

function _check_beam_gravity(case)
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

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 3)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    @test disp_response["gradient_backend"] == "tacs_formulation_load_fd_adjoint"
    disp_fd = (_response_value(results_p, disp_resp) - _response_value(results_m, disp_resp)) / (2.0 * h)
    disp_hook = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_hook, disp_fd)
    expected_disp = -case.area * case.gravity * case.length^4 / (6.0 * E_BEAM * case.I2)
    expected_relerr = _relerr(disp_hook, expected_disp)
    @test disp_relerr < 1e-6
    @test expected_relerr < 1e-6

    return Dict(
        "deck" => abspath(case.path),
        "load_norm" => Float64(comp_diag["load_derivative_norm"]),
        "compliance" => (fd=comp_fd, hook=comp_hook, rel=comp_relerr),
        "displacement" => (fd=disp_fd, hook=disp_hook, rel=disp_relerr, expected=expected_disp, expected_rel=expected_relerr),
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol101_gravity_load_sens_")
    shell = _check_shell_gravity(_write_gravity_quad_deck(joinpath(tmp, "gravity_quad.bdf")))
    cbar = _check_beam_gravity(_write_gravity_beam_deck(joinpath(tmp, "gravity_cbar.bdf"), "CBAR"))
    cbeam = _check_beam_gravity(_write_gravity_beam_deck(joinpath(tmp, "gravity_cbeam.bdf"), "CBEAM"))

    println("TACS SOL101 gravity load sensitivity check passed")
    println("  shell deck               = ", shell["deck"])
    println("  shell dF/dRHO norm       = ", shell["load_norm"])
    println("  shell dCompliance FD/hook/rel = ",
        shell["compliance"].fd, " / ", shell["compliance"].hook, " / ", shell["compliance"].rel)
    println("  shell dU/dRHO FD/hook/rel = ",
        shell["displacement"].fd, " / ", shell["displacement"].hook, " / ", shell["displacement"].rel)
    println("  shell dKS/dRHO FD/hook/rel = ",
        shell["stress_ks"].fd, " / ", shell["stress_ks"].hook, " / ", shell["stress_ks"].rel)
    for (name, checks) in (("CBAR", cbar), ("CBEAM", cbeam))
        println("  $name deck                = ", checks["deck"])
        println("  $name dF/dRHO norm        = ", checks["load_norm"])
        println("  $name dCompliance FD/hook/rel = ",
            checks["compliance"].fd, " / ", checks["compliance"].hook, " / ", checks["compliance"].rel)
        println("  $name dU/dRHO FD/hook/expected/rel = ",
            checks["displacement"].fd, " / ", checks["displacement"].hook, " / ",
            checks["displacement"].expected, " / ", checks["displacement"].rel)
        println("  $name dU/dRHO expected rel = ", checks["displacement"].expected_rel)
    end
end

main()
