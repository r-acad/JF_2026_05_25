# Guard for TACS-formulation SOL103 CELAS/CBUSH spring plus point/scalar mass modal slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_spring_modal_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

function _write_spring_modal_deck(path::AbstractString, kind::Symbol, mass_kind::Symbol)
    k = kind == :celas1 ? 2400.0 : kind == :celas2 ? 1750.0 : 3200.0
    m = kind == :celas1 ? 12.0 : kind == :celas2 ? 7.0 : 16.0
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $(uppercase(string(kind))) spring modal check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        if kind == :celas1
            println(io, "CELAS1,1,1,1,1")
            println(io, "PELAS,1,$k")
        elseif kind == :celas2
            println(io, "CELAS2,1,$k,1,1")
        else
            println(io, "CBUSH,1,1,1")
            println(io, "PBUSH,1,K,$k,0.,0.,0.,0.,0.")
        end
        if mass_kind == :conm2
            println(io, "CONM2,1,1,,$m")
        elseif mass_kind == :cmass2
            println(io, "CMASS2,1,$m,1,1")
        else
            println(io, "CMASS1,1,1,1,1")
            println(io, "PMASS,1,$m")
        end
        println(io, "SPC1,1,23456,1")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, kind=kind, mass_kind=mass_kind, stiffness=k, mass=m)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _first_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(m)
    return Float64(results["eigenvalues"][1])
end

function _centered_fd(model::AbstractDict, dv::AbstractDict, h::Real)
    hp = Float64(h)
    mp = OpenJFEM._tacs_model_with_design_delta(model, dv, hp)
    mm = OpenJFEM._tacs_model_with_design_delta(model, dv, -hp)
    return (_first_eigenvalue(mp) - _first_eigenvalue(mm)) / (2.0 * hp)
end

function _spring_dv(case)
    if case.kind == :celas1
        return Dict{String,Any}(
            "id" => "celas1_k",
            "type" => "spring_stiffness",
            "pids" => [1],
            "step" => max(1e-6 * case.stiffness, 1e-6),
        )
    elseif case.kind == :celas2
        return Dict{String,Any}(
            "id" => "celas2_k",
            "type" => "spring_stiffness",
            "eids" => [1],
            "step" => max(1e-6 * case.stiffness, 1e-6),
        )
    end
    return Dict{String,Any}(
        "id" => "cbush_k1",
        "type" => "bush_stiffness",
        "pids" => [1],
        "component" => 1,
        "step" => max(1e-6 * case.stiffness, 1e-6),
    )
end

function _mass_dv(case)
    if case.mass_kind == :cmass1
        return Dict{String,Any}(
            "id" => "$(string(case.kind))_pmass",
            "type" => "point_mass",
            "pids" => [1],
            "step" => max(1e-6 * case.mass, 1e-8),
        )
    end
    return Dict{String,Any}(
        "id" => "$(string(case.kind))_mass",
        "type" => "point_mass",
        "eids" => [1],
        "step" => max(1e-6 * case.mass, 1e-8),
    )
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    expected_lambda = case.stiffness / case.mass
    expected_freq = sqrt(expected_lambda) / (2.0 * pi)
    lambda = Float64(results["eigenvalues"][1])
    freq = Float64(results["frequencies"][1])
    @test _relative_error(lambda, expected_lambda) < 1e-12
    @test _relative_error(freq, expected_freq) < 1e-12
    @test results["formulation"]["spring"] == "residual_first_celas1_celas2_cbush_sol101_sol103"
    @test occursin("residual_first_celas1_celas2_cbush_sol101_sol103", results["tacs_formulation_sol103"]["linear_stiffness"])
    @test occursin("shared_jfem_modal_point_mass", results["tacs_formulation_sol103"]["mass"])

    dv = _spring_dv(case)
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    hook = Float64(response["gradient"][dv["id"]])
    expected_grad = 1.0 / case.mass
    fd = _centered_fd(model, dv, Float64(dv["step"]))
    @test _relative_error(hook, expected_grad) < 1e-8
    @test _relative_error(fd, expected_grad) < 1e-8
    @test _relative_error(hook, fd) < 1e-8

    mass_dv = _mass_dv(case)
    mass_response = OpenJFEM.modal_eigenvalue_design_gradient(results, [mass_dv]; mode=1)
    mass_hook = Float64(mass_response["gradient"][mass_dv["id"]])
    expected_mass_grad = -case.stiffness / (case.mass * case.mass)
    mass_fd = _centered_fd(model, mass_dv, Float64(mass_dv["step"]))
    @test _relative_error(mass_hook, expected_mass_grad) < 1e-8
    @test _relative_error(mass_fd, expected_mass_grad) < 1e-8
    @test _relative_error(mass_hook, mass_fd) < 1e-8
    return (
        lambda_relerr=_relative_error(lambda, expected_lambda),
        freq_relerr=_relative_error(freq, expected_freq),
        fd=fd,
        hook=hook,
        expected=expected_grad,
        mass_fd=mass_fd,
        mass_hook=mass_hook,
        mass_expected=expected_mass_grad,
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_spring_modal_")
    cases = (
        _write_spring_modal_deck(joinpath(tmp, "tacs_celas1_conm2_sol103.bdf"), :celas1, :conm2),
        _write_spring_modal_deck(joinpath(tmp, "tacs_celas2_cmass2_sol103.bdf"), :celas2, :cmass2),
        _write_spring_modal_deck(joinpath(tmp, "tacs_cbush_cmass1_sol103.bdf"), :cbush, :cmass1),
    )
    checks = Dict{Symbol,Any}()
    for case in cases
        checks[case.kind] = _check_case(case)
    end
    println("TACS SOL103 spring modal route guard passed")
    for name in (:celas1, :celas2, :cbush)
        check = checks[name]
        println("  $(uppercase(string(name))) eigenvalue/frequency relerr = ",
            check.lambda_relerr, " / ", check.freq_relerr)
        println("  $(uppercase(string(name))) dLambda/dK FD/hook/exp = ",
            check.fd, " / ", check.hook, " / ", check.expected)
        println("  $(uppercase(string(name))) dLambda/dm FD/hook/exp = ",
            check.mass_fd, " / ", check.mass_hook, " / ", check.mass_expected)
    end
    return true
end

exit(main() ? 0 : 1)
