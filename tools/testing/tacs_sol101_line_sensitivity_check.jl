# Guard for TACS-formulation SOL101 line-element static design sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_line_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_crod_deck(path::AbstractString)
    A = 1.0e-2
    J = 2.5e-5
    L = 2.0
    F = 1000.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CROD sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CROD,1,1,1,2")
        println(io, "PROD,1,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, length=L, force=F)
end

function _write_conrod_deck(path::AbstractString)
    A = 7.0e-3
    J = 1.6e-5
    L = 1.5
    F = 600.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CONROD sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CONROD,1,1,2,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, length=L, force=F)
end

function _write_celas1_deck(path::AbstractString)
    k = 2500.0
    f = 125.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CELAS1 sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "PELAS,1,$k")
        println(io, "CELAS1,1,1,1,1,2,1")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _write_celas2_deck(path::AbstractString)
    k = 1750.0
    f = 70.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CELAS2 sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "CELAS2,1,$k,1,1,2,1")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _write_cbush_deck(path::AbstractString)
    k = 3200.0
    f = 160.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CBUSH sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "CBUSH,1,1,1,2")
        println(io, "PBUSH,1,K,$k,0.,0.,0.,0.,0.")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _gradient(results, dv)
    response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    return Float64(response["gradient"][string(dv["id"])]), response
end

function _displacement_gradient(results, dv)
    response_spec = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 1)
    response = OpenJFEM.static_displacement_design_gradient(results, response_spec, [dv])
    return Float64(response["gradient"][string(dv["id"])]), response
end

function _ks_displacement_gradient(results, dv)
    response_spec = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 1,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    response = OpenJFEM.static_ks_displacement_design_gradient(results, response_spec, [dv])
    return Float64(response["gradient"][string(dv["id"])]), response
end

function _relerr(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _check_rod_case(case, area_dv)
    results = _solve(case.path)
    displacement = case.force * case.length / (E_ROD * case.area)
    compliance = case.force^2 * case.length / (E_ROD * case.area)
    area_grad, area_response = _gradient(results, area_dv)
    material_grad, material_response = _gradient(
        results,
        Dict{String,Any}("id" => "rod_material_E", "type" => "material_E", "mids" => [1]),
    )
    area_expected = -compliance / case.area
    material_expected = -compliance / E_ROD
    area_relerr = _relerr(area_grad, area_expected)
    material_relerr = _relerr(material_grad, material_expected)
    @test area_relerr < 1e-7
    @test material_relerr < 1e-7
    @test area_response["gradient_backend"] == "tacs_formulation_design_tangent"
    @test material_response["gradient_backend"] == "tacs_formulation_design_tangent"

    area_disp_grad, area_disp_response = _displacement_gradient(results, area_dv)
    material_disp_grad, _ = _displacement_gradient(
        results,
        Dict{String,Any}("id" => "rod_material_E", "type" => "material_E", "mids" => [1]),
    )
    area_disp_expected = -displacement / case.area
    material_disp_expected = -displacement / E_ROD
    area_disp_relerr = _relerr(area_disp_grad, area_disp_expected)
    material_disp_relerr = _relerr(material_disp_grad, material_disp_expected)
    @test area_disp_relerr < 1e-7
    @test material_disp_relerr < 1e-7
    @test area_disp_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"

    area_ks_grad, area_ks_response = _ks_displacement_gradient(results, area_dv)
    area_ks_relerr = _relerr(area_ks_grad, area_disp_expected)
    @test area_ks_relerr < 1e-7
    @test area_ks_response["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    return area_relerr, material_relerr, area_disp_relerr, material_disp_relerr, area_ks_relerr
end

function _check_spring_case(case, dv)
    results = _solve(case.path)
    displacement = case.force / case.stiffness
    compliance = case.force^2 / case.stiffness
    grad, response = _gradient(results, dv)
    expected = -compliance / case.stiffness
    relerr = _relerr(grad, expected)
    @test relerr < 1e-7
    @test response["gradient_backend"] == "tacs_formulation_design_tangent"

    disp_grad, disp_response = _displacement_gradient(results, dv)
    disp_expected = -displacement / case.stiffness
    disp_relerr = _relerr(disp_grad, disp_expected)
    @test disp_relerr < 1e-7
    @test disp_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"

    ks_grad, ks_response = _ks_displacement_gradient(results, dv)
    ks_relerr = _relerr(ks_grad, disp_expected)
    @test ks_relerr < 1e-7
    @test ks_response["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    return relerr, disp_relerr, ks_relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_line_sens_")
    crod = _write_crod_deck(joinpath(tmp, "tacs_crod_sens.bdf"))
    conrod = _write_conrod_deck(joinpath(tmp, "tacs_conrod_sens.bdf"))
    celas1 = _write_celas1_deck(joinpath(tmp, "tacs_celas1_sens.bdf"))
    celas2 = _write_celas2_deck(joinpath(tmp, "tacs_celas2_sens.bdf"))
    cbush = _write_cbush_deck(joinpath(tmp, "tacs_cbush_sens.bdf"))

    crod_area_relerr, crod_e_relerr, crod_disp_relerr, crod_e_disp_relerr, crod_ks_relerr = _check_rod_case(
        crod,
        Dict{String,Any}("id" => "crod_area", "type" => "rod_area", "pids" => [1]),
    )
    conrod_area_relerr, conrod_e_relerr, conrod_disp_relerr, conrod_e_disp_relerr, conrod_ks_relerr = _check_rod_case(
        conrod,
        Dict{String,Any}("id" => "conrod_area", "type" => "rod_area", "eids" => [1]),
    )
    celas1_relerr, celas1_disp_relerr, celas1_ks_relerr = _check_spring_case(
        celas1,
        Dict{String,Any}("id" => "celas1_k", "type" => "spring_stiffness", "pids" => [1]),
    )
    celas2_relerr, celas2_disp_relerr, celas2_ks_relerr = _check_spring_case(
        celas2,
        Dict{String,Any}("id" => "celas2_k", "type" => "spring_stiffness", "eids" => [1]),
    )
    cbush_relerr, cbush_disp_relerr, cbush_ks_relerr = _check_spring_case(
        cbush,
        Dict{String,Any}("id" => "cbush_k1", "type" => "bush_stiffness", "pids" => [1], "component" => 1),
    )

    println("TACS SOL101 line sensitivity guard passed")
    println("  CROD area compliance relerr      = $crod_area_relerr")
    println("  CROD material_E compliance relerr = $crod_e_relerr")
    println("  CROD area displacement relerr    = $crod_disp_relerr")
    println("  CROD material_E disp relerr      = $crod_e_disp_relerr")
    println("  CROD area KS disp relerr         = $crod_ks_relerr")
    println("  CONROD area compliance relerr    = $conrod_area_relerr")
    println("  CONROD material_E relerr         = $conrod_e_relerr")
    println("  CONROD area displacement relerr  = $conrod_disp_relerr")
    println("  CONROD material_E disp relerr    = $conrod_e_disp_relerr")
    println("  CONROD area KS disp relerr       = $conrod_ks_relerr")
    println("  CELAS1 stiffness relerr          = $celas1_relerr")
    println("  CELAS1 displacement relerr       = $celas1_disp_relerr")
    println("  CELAS1 KS displacement relerr    = $celas1_ks_relerr")
    println("  CELAS2 stiffness relerr          = $celas2_relerr")
    println("  CELAS2 displacement relerr       = $celas2_disp_relerr")
    println("  CELAS2 KS displacement relerr    = $celas2_ks_relerr")
    println("  CBUSH K1 stiffness relerr        = $cbush_relerr")
    println("  CBUSH K1 displacement relerr     = $cbush_disp_relerr")
    println("  CBUSH K1 KS displacement relerr  = $cbush_ks_relerr")
    return true
end

exit(main() ? 0 : 1)
