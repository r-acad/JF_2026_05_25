# Guard for TACS-formulation CBAR/CBEAM node-coordinate shape sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_sol103_beam_shape_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_deck(path::AbstractString, card_type::AbstractString; sol::Integer)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    Fz = 100.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL $(Int(sol))")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL$(Int(sol)) $card beam shape sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        if Int(sol) == 101
            println(io, "  LOAD = 1")
        else
            println(io, "  METHOD = 1")
        end
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        if Int(sol) == 101
            println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        else
            println(io, "SPC1,1,1246,2")
            println(io, "EIGRL,1,0.,1.0E8,1")
        end
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, force_z=Fz)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(actual)), abs(Float64(expected)), 1e-30)
end

function _solve_tacs(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return model, OpenJFEM.solve_model(model)
end

function _first_modal_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return Float64(OpenJFEM.solve_model(m)["eigenvalues"][1])
end

function _expected_modal_lambda(case, L::Real)
    Lf = Float64(L)
    K2 = [
        12.0 * E_BEAM * case.I2 / Lf^3    -6.0 * E_BEAM * case.I2 / Lf^2;
        -6.0 * E_BEAM * case.I2 / Lf^2     4.0 * E_BEAM * case.I2 / Lf
    ]
    M2 = Diagonal([
        RHO_BEAM * case.area * Lf / 2.0,
        RHO_BEAM * case.I2 * Lf / 2.0,
    ])
    vals = sort!(real.(eigvals(Symmetric(K2), Symmetric(Matrix(M2)))))
    return vals[1]
end

function _check_static_shape(case)
    model, results = _solve_tacs(case.path)
    dv = Dict{String,Any}("id" => "$(lowercase(case.card))_x2", "type" => "node_coord", "grid" => 2, "component" => 1)
    displacement = case.force_z * case.length^3 / (3.0 * E_BEAM * case.I2)
    compliance = case.force_z * displacement
    expected_disp_grad = case.force_z * case.length^2 / (E_BEAM * case.I2)
    expected_comp_grad = case.force_z * expected_disp_grad
    expected_mass_grad = RHO_BEAM * case.area

    comp_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
    comp_grad = Float64(comp_response["gradient"][dv["id"]])
    comp_relerr = _relative_error(comp_grad, expected_comp_grad)
    @test comp_response["gradient_backend"] == "tacs_formulation_coordinate_fd"
    @test comp_relerr < 1e-6

    disp_spec = Dict{String,Any}("type" => "displacement", "grid" => 2, "dof" => 3)
    disp_response = OpenJFEM.static_displacement_design_gradient(results, disp_spec, [dv])
    disp_grad = Float64(disp_response["gradient"][dv["id"]])
    disp_relerr = _relative_error(disp_grad, expected_disp_grad)
    @test disp_response["gradient_backend"] == "tacs_formulation_coordinate_fd"
    @test disp_relerr < 1e-6

    ks_spec = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2],
        "dof" => 3,
        "displacement_ref" => 1.0,
        "rho" => 50.0,
    )
    ks_response = OpenJFEM.static_ks_displacement_design_gradient(results, ks_spec, [dv])
    ks_grad = Float64(ks_response["gradient"][dv["id"]])
    ks_relerr = _relative_error(ks_grad, expected_disp_grad)
    @test ks_response["gradient_backend"] == "tacs_formulation_coordinate_fd"
    @test ks_relerr < 1e-6

    mass_response = OpenJFEM.structural_mass_design_gradient(results, [dv])
    mass_grad = Float64(mass_response["gradient"][dv["id"]])
    mass_relerr = _relative_error(mass_grad, expected_mass_grad)
    @test mass_response["gradient_backend"] == "tacs_formulation_mass_coordinate_fd"
    @test mass_relerr < 1e-7
    @test isapprox(Float64(mass_response["value"]), RHO_BEAM * case.area * case.length; rtol=1e-12)

    _ = model
    return Dict(
        "compliance" => comp_relerr,
        "displacement" => disp_relerr,
        "ks_displacement" => ks_relerr,
        "mass" => mass_relerr,
        "compliance_grad" => comp_grad,
        "displacement_grad" => disp_grad,
        "mass_grad" => mass_grad,
        "compliance_expected" => expected_comp_grad,
        "displacement_expected" => expected_disp_grad,
        "mass_expected" => expected_mass_grad,
    )
end

function _check_modal_shape(case)
    model, results = _solve_tacs(case.path)
    dv = Dict{String,Any}("id" => "$(lowercase(case.card))_x2_modal", "type" => "node_coord", "grid" => 2, "component" => 1)
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_modal_coordinate_fd"
    h = Float64(response["design_variable_diagnostics"][dv["id"]]["step"])
    hook = Float64(response["gradient"][dv["id"]])
    model_p = OpenJFEM._tacs_model_with_grid_coord_delta(model, 2, 1, h)
    model_m = OpenJFEM._tacs_model_with_grid_coord_delta(model, 2, 1, -h)
    fd = (_first_modal_eigenvalue(model_p) - _first_modal_eigenvalue(model_m)) / (2.0 * h)
    expected = (_expected_modal_lambda(case, case.length + h) - _expected_modal_lambda(case, case.length - h)) / (2.0 * h)
    fd_relerr = _relative_error(hook, fd)
    expected_relerr = _relative_error(hook, expected)
    @test isfinite(hook)
    @test isfinite(fd)
    @test fd_relerr < 1e-6
    @test expected_relerr < 1e-6
    return Dict(
        "eigenvalue" => Float64(results["eigenvalues"][1]),
        "fd" => fd,
        "hook" => hook,
        "expected" => expected,
        "fd_relerr" => fd_relerr,
        "expected_relerr" => expected_relerr,
    )
end

function _check_card(card::AbstractString)
    tmp = mktempdir(; prefix="openjfem_tacs_beam_shape_")
    static_case = _write_beam_deck(joinpath(tmp, "tacs_$(lowercase(card))_sol101_shape.bdf"), card; sol=101)
    modal_case = _write_beam_deck(joinpath(tmp, "tacs_$(lowercase(card))_sol103_shape.bdf"), card; sol=103)
    return _check_static_shape(static_case), _check_modal_shape(modal_case)
end

function main()
    cbar_static, cbar_modal = _check_card("CBAR")
    cbeam_static, cbeam_modal = _check_card("CBEAM")

    println("TACS SOL101/SOL103 beam shape sensitivity guard passed")
    for (name, static_checks, modal_checks) in (
        ("CBAR", cbar_static, cbar_modal),
        ("CBEAM", cbeam_static, cbeam_modal),
    )
        println("  $name dCompliance/dX FD/hook rel = ", static_checks["compliance"],
            " (hook/expected ", static_checks["compliance_grad"], " / ", static_checks["compliance_expected"], ")")
        println("  $name dDisp/dX FD/hook rel       = ", static_checks["displacement"],
            " (hook/expected ", static_checks["displacement_grad"], " / ", static_checks["displacement_expected"], ")")
        println("  $name dKSDisp/dX rel             = ", static_checks["ks_displacement"])
        println("  $name dMass/dX rel               = ", static_checks["mass"],
            " (hook/expected ", static_checks["mass_grad"], " / ", static_checks["mass_expected"], ")")
        println("  $name modal eigenvalue           = ", modal_checks["eigenvalue"])
        println("  $name dLambda/dX FD/hook/expected/rel = ",
            modal_checks["fd"], " / ", modal_checks["hook"], " / ",
            modal_checks["expected"], " / ", modal_checks["fd_relerr"])
    end
    return true
end

exit(main() ? 0 : 1)
