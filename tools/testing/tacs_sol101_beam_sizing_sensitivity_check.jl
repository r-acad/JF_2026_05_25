# Guard for TACS-formulation SOL101 CBAR/CBEAM beam sizing sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_sizing_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    Fz = 100.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card beam sizing sensitivity check")
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
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, force_z=Fz)
end

function _write_beam_y_bending_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.5e-6
    I2 = 2.4e-6
    J = 3.0e-6
    L = 2.0
    Fy = 80.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card beam_I1 sizing sensitivity check")
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
        println(io, "FORCE,1,2,0,$Fy,0.,1.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, force_y=Fy)
end

function _write_beam_torsion_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.5e-6
    L = 2.0
    Mx = 55.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card beam_J sizing sensitivity check")
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
        println(io, "SPC1,1,12356,2")
        println(io, "MOMENT,1,2,0,$Mx,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, moment_x=Mx)
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _check_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    I2_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I2", "type" => "beam_I2", "pids" => [1])
    displacement = case.force_z * case.length^3 / (3.0 * E_BEAM * case.I2)
    compliance = case.force_z * displacement
    expected_disp_grad = -displacement / case.I2
    expected_comp_grad = -compliance / case.I2

    comp_response = OpenJFEM.static_compliance_design_gradient(results, [I2_dv])
    comp_grad = Float64(comp_response["gradient"][I2_dv["id"]])
    comp_relerr = _relative_error(comp_grad, expected_comp_grad)
    @test comp_response["gradient_backend"] == "tacs_formulation_design_tangent"
    @test comp_relerr < 1e-7

    disp_spec = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 3)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_spec, [I2_dv])
    disp_grad = Float64(disp_response["gradient"][I2_dv["id"]])
    disp_relerr = _relative_error(disp_grad, expected_disp_grad)
    @test disp_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"
    @test disp_relerr < 1e-7

    ks_spec = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 3,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_spec, [I2_dv])
    ks_grad = Float64(ks_response["gradient"][I2_dv["id"]])
    ks_relerr = _relative_error(ks_grad, expected_disp_grad)
    @test ks_response["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test ks_relerr < 1e-7

    area_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_area", "type" => "beam_area", "pids" => [1])
    rho_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_rho", "type" => "material_RHO", "mids" => [1])
    mass_response = OpenJFEM.structural_mass_design_gradient(results, [area_dv, rho_dv, I2_dv])
    expected_mass = RHO_BEAM * case.area * case.length
    expected_area_grad = RHO_BEAM * case.length
    expected_rho_grad = case.area * case.length
    mass_relerr = _relative_error(Float64(mass_response["value"]), expected_mass)
    area_relerr = _relative_error(Float64(mass_response["gradient"][area_dv["id"]]), expected_area_grad)
    rho_relerr = _relative_error(Float64(mass_response["gradient"][rho_dv["id"]]), expected_rho_grad)
    i2_mass_grad = Float64(mass_response["gradient"][I2_dv["id"]])
    @test startswith(string(mass_response["gradient_backend"]), "tacs_formulation_mixed")
    @test mass_relerr < 1e-12
    @test area_relerr < 1e-12
    @test rho_relerr < 1e-12
    @test i2_mass_grad == 0.0

    return Dict(
        "compliance_I2" => comp_relerr,
        "displacement_I2" => disp_relerr,
        "ks_displacement_I2" => ks_relerr,
        "mass_value" => mass_relerr,
        "mass_area" => area_relerr,
        "mass_rho" => rho_relerr,
    )
end

function _check_i1_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    I1_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I1", "type" => "beam_I1", "pids" => [1])
    displacement = case.force_y * case.length^3 / (3.0 * E_BEAM * case.I1)
    compliance = case.force_y * displacement
    expected_disp_grad = -displacement / case.I1
    expected_comp_grad = -compliance / case.I1

    comp_response = OpenJFEM.static_compliance_design_gradient(results, [I1_dv])
    comp_grad = Float64(comp_response["gradient"][I1_dv["id"]])
    comp_relerr = _relative_error(comp_grad, expected_comp_grad)
    @test comp_response["gradient_backend"] == "tacs_formulation_design_tangent"
    @test comp_relerr < 1e-7

    disp_spec = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 2)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_spec, [I1_dv])
    disp_grad = Float64(disp_response["gradient"][I1_dv["id"]])
    disp_relerr = _relative_error(disp_grad, expected_disp_grad)
    @test disp_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"
    @test disp_relerr < 1e-7

    ks_spec = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 2,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_spec, [I1_dv])
    ks_grad = Float64(ks_response["gradient"][I1_dv["id"]])
    ks_relerr = _relative_error(ks_grad, expected_disp_grad)
    @test ks_response["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test ks_relerr < 1e-7

    return Dict("compliance_I1" => comp_relerr, "displacement_I1" => disp_relerr,
                "ks_displacement_I1" => ks_relerr)
end

function _check_j_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    J_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_J", "type" => "beam_J", "pids" => [1])
    rotation = case.moment_x * case.length / (G_BEAM * case.torsion)
    compliance = case.moment_x * rotation
    expected_rotation_grad = -rotation / case.torsion
    expected_comp_grad = -compliance / case.torsion

    comp_response = OpenJFEM.static_compliance_design_gradient(results, [J_dv])
    comp_grad = Float64(comp_response["gradient"][J_dv["id"]])
    comp_relerr = _relative_error(comp_grad, expected_comp_grad)
    @test comp_response["gradient_backend"] == "tacs_formulation_design_tangent"
    @test comp_relerr < 1e-7

    disp_spec = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 4)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_spec, [J_dv])
    disp_grad = Float64(disp_response["gradient"][J_dv["id"]])
    disp_relerr = _relative_error(disp_grad, expected_rotation_grad)
    @test disp_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"
    @test disp_relerr < 1e-7

    ks_spec = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 4,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_spec, [J_dv])
    ks_grad = Float64(ks_response["gradient"][J_dv["id"]])
    ks_relerr = _relative_error(ks_grad, expected_rotation_grad)
    @test ks_response["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test ks_relerr < 1e-7

    return Dict("compliance_J" => comp_relerr, "rotation_J" => disp_relerr,
                "ks_rotation_J" => ks_relerr)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_sizing_sol101_")
    cbar = _write_beam_deck(joinpath(tmp, "tacs_cbar_sol101_beam_sizing.bdf"), "CBAR")
    cbeam = _write_beam_deck(joinpath(tmp, "tacs_cbeam_sol101_beam_sizing.bdf"), "CBEAM")
    cbar_i1 = _write_beam_y_bending_deck(joinpath(tmp, "tacs_cbar_sol101_beam_i1.bdf"), "CBAR")
    cbeam_i1 = _write_beam_y_bending_deck(joinpath(tmp, "tacs_cbeam_sol101_beam_i1.bdf"), "CBEAM")
    cbar_j = _write_beam_torsion_deck(joinpath(tmp, "tacs_cbar_sol101_beam_j.bdf"), "CBAR")
    cbeam_j = _write_beam_torsion_deck(joinpath(tmp, "tacs_cbeam_sol101_beam_j.bdf"), "CBEAM")

    cbar_checks = _check_case(cbar)
    cbeam_checks = _check_case(cbeam)
    cbar_i1_checks = _check_i1_case(cbar_i1)
    cbeam_i1_checks = _check_i1_case(cbeam_i1)
    cbar_j_checks = _check_j_case(cbar_j)
    cbeam_j_checks = _check_j_case(cbeam_j)

    println("TACS SOL101 beam sizing sensitivity guard passed")
    for (name, checks, i1_checks, j_checks) in (
        ("CBAR", cbar_checks, cbar_i1_checks, cbar_j_checks),
        ("CBEAM", cbeam_checks, cbeam_i1_checks, cbeam_j_checks),
    )
        println("  $name beam_I2 compliance relerr      = ", checks["compliance_I2"])
        println("  $name beam_I2 displacement relerr    = ", checks["displacement_I2"])
        println("  $name beam_I2 KS displacement relerr = ", checks["ks_displacement_I2"])
        println("  $name beam_I1 compliance relerr      = ", i1_checks["compliance_I1"])
        println("  $name beam_I1 displacement relerr    = ", i1_checks["displacement_I1"])
        println("  $name beam_I1 KS displacement relerr = ", i1_checks["ks_displacement_I1"])
        println("  $name beam_J compliance relerr       = ", j_checks["compliance_J"])
        println("  $name beam_J rotation relerr         = ", j_checks["rotation_J"])
        println("  $name beam_J KS rotation relerr      = ", j_checks["ks_rotation_J"])
        println("  $name mass value relerr              = ", checks["mass_value"])
        println("  $name beam_area mass relerr          = ", checks["mass_area"])
        println("  $name material_RHO mass relerr       = ", checks["mass_rho"])
    end
    return true
end

exit(main() ? 0 : 1)
