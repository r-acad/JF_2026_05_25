# Finite-difference guard for SOL101 line-element thermal load sensitivity.
#
# TEMP(LOAD) axial thermal loads depend on MAT1 E, ALPHA, and TREF. This guard
# checks the generic TACS static load-derivative adjoint path on compliance,
# scalar displacement, and single-entry KS displacement responses for CROD,
# CONROD, CBAR, and CBEAM two-node line elements.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_line_thermal_load_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

const E_LINE = 7.0e10
const G_LINE = 2.6923e10
const RHO_LINE = 2700.0
const ALPHA_LINE = 1.2e-5
const TREF_LINE = 20.0
const TEMP_LINE = 80.0

function _write_thermal_rod_deck(path::AbstractString, card_type::AbstractString)
    card = uppercase(card_type)
    A = card == "CROD" ? 1.0e-2 : 7.0e-3
    J = card == "CROD" ? 2.5e-5 : 1.6e-5
    L = card == "CROD" ? 2.0 : 1.5
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 $card thermal load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  TEMP(LOAD) = 7")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        if card == "CROD"
            println(io, "CROD,1,1,1,2")
            println(io, "PROD,1,1,$A,$J")
        else
            println(io, "CONROD,1,1,2,1,$A,$J")
        end
        println(io, "MAT1,1,$E_LINE,$G_LINE,0.3,$RHO_LINE,$ALPHA_LINE,$TREF_LINE")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "TEMPD,7,$TEMP_LINE")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, length=L, alpha=ALPHA_LINE, tref=TREF_LINE, temp=TEMP_LINE)
end

function _write_thermal_beam_deck(path::AbstractString, card_type::AbstractString)
    card = uppercase(card_type)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS SOL101 $card thermal load sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  TEMP(LOAD) = 7")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_LINE,$G_LINE,0.3,$RHO_LINE,$ALPHA_LINE,$TREF_LINE")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "TEMPD,7,$TEMP_LINE")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, length=L, alpha=ALPHA_LINE, tref=TREF_LINE, temp=TEMP_LINE)
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

function _expected_displacement_derivative(case, dv_type::AbstractString)
    dT = Float64(case.temp - case.tref)
    L = Float64(case.length)
    dv_type == "material_ALPHA" && return dT * L
    dv_type == "material_TREF" && return -Float64(case.alpha) * L
    dv_type == "material_E" && return 0.0
    error("unexpected design type $dv_type")
end

function _check_design(case, dv_type::AbstractString)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    dv = Dict{String,Any}(
        "id" => "$(lowercase(case.card))_$(lowercase(replace(dv_type, "material_" => "")))",
        "type" => dv_type,
        "mids" => [1],
    )
    comp_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    comp_diag = comp_response["design_variable_diagnostics"][dv["id"]]
    @test get(comp_diag, "load_derivative_nonzero", false) == true
    @test Float64(comp_diag["load_derivative_norm"]) > 1e-9
    h = Float64(comp_diag["step"])
    @test h > 0.0

    field =
        dv_type == "material_ALPHA" ? "ALPHA" :
        dv_type == "material_TREF" ? "TREF" :
        dv_type == "material_E" ? "E" :
        error("unexpected design type $dv_type")
    results_p = OpenJFEM.solve_model(_with_material_field(model, 1, field, h))
    results_m = OpenJFEM.solve_model(_with_material_field(model, 1, field, -h))

    comp_fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
    comp_hook = Float64(comp_response["gradient"][dv["id"]])
    comp_relerr = _relerr(comp_hook, comp_fd)
    @test comp_relerr < 1e-6

    disp_resp = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 1)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, [dv])
    disp_fd = (_response_value(results_p, disp_resp) - _response_value(results_m, disp_resp)) / (2.0 * h)
    disp_hook = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relerr(disp_hook, disp_fd)
    expected_disp = _expected_displacement_derivative(case, dv_type)
    expected_abs = abs(disp_hook - expected_disp)
    if expected_disp == 0.0
        @test abs(disp_hook - disp_fd) < 1e-12
        @test expected_abs < 1e-12
    else
        @test disp_relerr < 1e-6
        @test _relerr(disp_hook, expected_disp) < 1e-6
    end

    ks_resp = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 1,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_resp, [dv])
    expected_ks_backend =
        dv_type in ("material_ALPHA", "material_TREF") ?
        "tacs_formulation_load_fd_adjoint" :
        "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test ks_response["gradient_backend"] == expected_ks_backend
    ks_fd = (_response_value(results_p, ks_resp) - _response_value(results_m, ks_resp)) / (2.0 * h)
    ks_hook = Float64(ks_response["gradient"][dv["id"]])
    ks_relerr = _relerr(ks_hook, ks_fd)
    if expected_disp == 0.0
        @test abs(ks_hook - ks_fd) < 1e-12
        @test abs(ks_hook - expected_disp) < 1e-12
    else
        @test ks_relerr < 1e-6
        @test _relerr(ks_hook, expected_disp) < 1e-6
    end

    return Dict(
        "load_norm" => Float64(comp_diag["load_derivative_norm"]),
        "step" => h,
        "compliance" => (fd=comp_fd, hook=comp_hook, rel=comp_relerr),
        "displacement" => (
            fd=disp_fd,
            hook=disp_hook,
            rel=disp_relerr,
            expected=expected_disp,
            expected_abs=expected_abs,
        ),
        "ks_displacement" => (
            fd=ks_fd,
            hook=ks_hook,
            rel=ks_relerr,
            expected=expected_disp,
        ),
        "backend" => comp_response["gradient_backend"],
    )
end

function _check_case(case)
    checks = Dict{String,Any}()
    for dv_type in ("material_ALPHA", "material_TREF", "material_E")
        checks[dv_type] = _check_design(case, dv_type)
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol101_line_thermal_load_sens_")
    cases = (
        _write_thermal_rod_deck(joinpath(tmp, "thermal_crod.bdf"), "CROD"),
        _write_thermal_rod_deck(joinpath(tmp, "thermal_conrod.bdf"), "CONROD"),
        _write_thermal_beam_deck(joinpath(tmp, "thermal_cbar.bdf"), "CBAR"),
        _write_thermal_beam_deck(joinpath(tmp, "thermal_cbeam.bdf"), "CBEAM"),
    )
    results = [(case, _check_case(case)) for case in cases]

    println("TACS SOL101 line thermal load sensitivity check passed")
    for (case, checks) in results
        println("  ", case.card, " deck = ", abspath(case.path))
        for dv_type in ("material_ALPHA", "material_TREF", "material_E")
            check = checks[dv_type]
            println("    ", dv_type, " dF norm/step = ", check["load_norm"], " / ", check["step"])
            println("    ", dv_type, " dCompliance FD/hook/rel = ",
                check["compliance"].fd, " / ", check["compliance"].hook, " / ", check["compliance"].rel)
            println("    ", dv_type, " dU FD/hook/expected/rel = ",
                check["displacement"].fd, " / ", check["displacement"].hook, " / ",
                check["displacement"].expected, " / ", check["displacement"].rel)
            println("    ", dv_type, " dKSdisp FD/hook/expected/rel = ",
                check["ks_displacement"].fd, " / ", check["ks_displacement"].hook, " / ",
                check["ks_displacement"].expected, " / ", check["ks_displacement"].rel)
        end
    end
end

main()
