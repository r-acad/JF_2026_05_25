# Guard for TACS-formulation SOL103 CBAR/CBEAM modal material sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_beam_modal_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_modal_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $card modal sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,1246,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, card=card)
end

function _first_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(m)
    return Float64(results["eigenvalues"][1])
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _centered_fd(model::AbstractDict, dv::AbstractDict, h::Real)
    hp = Float64(h)
    mp = OpenJFEM._tacs_model_with_design_delta(model, dv, hp)
    mm = OpenJFEM._tacs_model_with_design_delta(model, dv, -hp)
    return (_first_eigenvalue(mp) - _first_eigenvalue(mm)) / (2.0 * hp)
end

function _check_gradient(results::AbstractDict, dv::Dict{String,Any}, expected::Real; rel_tol=1e-7, abs_tol=1e-8)
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    hook = Float64(response["gradient"][dv["id"]])
    freq_hook = Float64(response["frequency_gradient"][dv["id"]])
    lambda = Float64(results["eigenvalues"][1])
    expected_freq = lambda > 0.0 ? Float64(expected) / (4.0 * pi * sqrt(lambda)) : NaN
    @test isfinite(hook)
    @test isfinite(freq_hook)
    @test _relative_error(freq_hook, expected_freq) < rel_tol ||
        abs(freq_hook - expected_freq) < abs_tol
    @test _relative_error(hook, expected) < rel_tol ||
        abs(hook - expected) < abs_tol
    return hook, freq_hook, response
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    lambda = Float64(results["eigenvalues"][1])
    @test occursin("tacs_lumped_cbar_cbeam_mass", results["tacs_formulation_sol103"]["mass"])

    h_E = max(1e-6 * E_BEAM, 1e-3)
    E_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_E", "type" => "material_E", "mids" => [1], "step" => h_E)
    expected_E = lambda / E_BEAM
    hook_E, _, _ = _check_gradient(results, E_dv, expected_E)
    fd_E = _centered_fd(model, E_dv, h_E)
    @test _relative_error(hook_E, fd_E) < 1e-6

    h_rho = max(1e-6 * RHO_BEAM, 1e-9)
    rho_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_rho", "type" => "material_RHO", "mids" => [1], "step" => h_rho)
    expected_rho = -lambda / RHO_BEAM
    hook_rho, _, _ = _check_gradient(results, rho_dv, expected_rho)
    fd_rho = _centered_fd(model, rho_dv, h_rho)
    @test _relative_error(hook_rho, fd_rho) < 1e-6

    return Dict(
        "lambda" => lambda,
        "material_E" => (fd=fd_E, hook=hook_E, expected=expected_E),
        "material_RHO" => (fd=fd_rho, hook=hook_rho, expected=expected_rho),
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_modal_sens_")
    cbar = _write_beam_modal_deck(joinpath(tmp, "tacs_cbar_sol103_sensitivity.bdf"), "CBAR")
    cbeam = _write_beam_modal_deck(joinpath(tmp, "tacs_cbeam_sol103_sensitivity.bdf"), "CBEAM")

    cbar_checks = _check_case(cbar)
    cbeam_checks = _check_case(cbeam)

    println("TACS SOL103 beam modal sensitivity guard passed")
    for (name, checks) in (("CBAR", cbar_checks), ("CBEAM", cbeam_checks))
        println("  $name eigenvalue              = ", checks["lambda"])
        println("  $name material_E FD/hook/exp  = ",
            checks["material_E"].fd, " / ", checks["material_E"].hook, " / ", checks["material_E"].expected)
        println("  $name material_RHO FD/hook/exp = ",
            checks["material_RHO"].fd, " / ", checks["material_RHO"].hook, " / ", checks["material_RHO"].expected)
    end
    return true
end

exit(main() ? 0 : 1)
