# Guard for TACS-formulation SOL103 CBAR/CBEAM beam sizing sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_beam_sizing_sensitivity_check.jl

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
        println(io, "TITLE = Generated TACS SOL103 $card beam sizing sensitivity check")
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
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L)
end

function _write_beam_modal_y_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.5e-6
    I2 = 2.4e-6
    J = 3.0e-6
    L = 2.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $card beam_I1 sizing sensitivity check")
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
        println(io, "SPC1,1,1345,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L)
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

function _check_modal_gradient(results::AbstractDict, model::AbstractDict, dv::Dict{String,Any})
    h = OpenJFEM._tacs_line_static_design_step(model, dv)
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    hook = Float64(response["gradient"][dv["id"]])
    freq_hook = Float64(response["frequency_gradient"][dv["id"]])
    fd = _centered_fd(model, dv, h)
    lambda = Float64(results["eigenvalues"][1])
    freq_fd = lambda > 0.0 ? fd / (4.0 * pi * sqrt(lambda)) : NaN
    relerr = _relative_error(hook, fd)
    freq_relerr = _relative_error(freq_hook, freq_fd)
    @test response["gradient_backend"] == "tacs_formulation_modal_design_tangent_fd"
    @test isfinite(hook)
    @test isfinite(freq_hook)
    @test relerr < 1e-6
    @test freq_relerr < 1e-6
    return (fd=fd, hook=hook, relerr=relerr, freq_fd=freq_fd, freq_hook=freq_hook, freq_relerr=freq_relerr)
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    @test occursin("tacs_lumped_cbar_cbeam_mass", results["tacs_formulation_sol103"]["mass"])
    @test occursin("residual_first_cbar_cbeam_sol101_sol103_sol105", results["tacs_formulation_sol103"]["linear_stiffness"])

    I2_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I2", "type" => "beam_I2", "pids" => [1])
    area_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_area", "type" => "beam_area", "pids" => [1])
    i2 = _check_modal_gradient(results, model, I2_dv)
    area = _check_modal_gradient(results, model, area_dv)
    return Dict(
        "lambda" => Float64(results["eigenvalues"][1]),
        "beam_I2" => i2,
        "beam_area" => area,
    )
end

function _check_i1_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    @test occursin("tacs_lumped_cbar_cbeam_mass", results["tacs_formulation_sol103"]["mass"])
    @test occursin("residual_first_cbar_cbeam_sol101_sol103_sol105", results["tacs_formulation_sol103"]["linear_stiffness"])

    I1_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I1", "type" => "beam_I1", "pids" => [1])
    i1 = _check_modal_gradient(results, model, I1_dv)
    return Dict(
        "lambda" => Float64(results["eigenvalues"][1]),
        "beam_I1" => i1,
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_sizing_sol103_")
    cbar = _write_beam_modal_deck(joinpath(tmp, "tacs_cbar_sol103_beam_sizing.bdf"), "CBAR")
    cbeam = _write_beam_modal_deck(joinpath(tmp, "tacs_cbeam_sol103_beam_sizing.bdf"), "CBEAM")
    cbar_i1 = _write_beam_modal_y_deck(joinpath(tmp, "tacs_cbar_sol103_beam_i1_sizing.bdf"), "CBAR")
    cbeam_i1 = _write_beam_modal_y_deck(joinpath(tmp, "tacs_cbeam_sol103_beam_i1_sizing.bdf"), "CBEAM")

    cbar_checks = _check_case(cbar)
    cbeam_checks = _check_case(cbeam)
    cbar_i1_checks = _check_i1_case(cbar_i1)
    cbeam_i1_checks = _check_i1_case(cbeam_i1)

    println("TACS SOL103 beam sizing sensitivity guard passed")
    for (name, checks, i1_checks) in (
        ("CBAR", cbar_checks, cbar_i1_checks),
        ("CBEAM", cbeam_checks, cbeam_i1_checks),
    )
        println("  $name eigenvalue              = ", checks["lambda"])
        println("  $name beam_I2 FD/hook/rel     = ",
            checks["beam_I2"].fd, " / ", checks["beam_I2"].hook, " / ", checks["beam_I2"].relerr)
        println("  $name beam_I1 FD/hook/rel     = ",
            i1_checks["beam_I1"].fd, " / ", i1_checks["beam_I1"].hook, " / ", i1_checks["beam_I1"].relerr)
        println("  $name beam_area FD/hook/rel   = ",
            checks["beam_area"].fd, " / ", checks["beam_area"].hook, " / ", checks["beam_area"].relerr)
        println("  $name beam_I2 freq relerr     = ", checks["beam_I2"].freq_relerr)
        println("  $name beam_I1 freq relerr     = ", i1_checks["beam_I1"].freq_relerr)
        println("  $name beam_area freq relerr   = ", checks["beam_area"].freq_relerr)
    end
    return true
end

exit(main() ? 0 : 1)
