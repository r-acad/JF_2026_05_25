# Guard for TACS-formulation SOL105 CBAR/CBEAM buckling shape sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_beam_shape_sensitivity_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10

function _write_beam_buckling_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    axial_force = -800.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 $card beam shape buckling check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 2")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "SPC1,2,123456,1")
        println(io, "SPC1,2,1246,2")
        println(io, "FORCE,1,2,0,$(-axial_force),-1.,0.,0.")
        println(io, "EIGRL,1,,,2")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I2=I2, length=L, axial_force=axial_force)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) /
           max(abs(Float64(actual)), abs(Float64(expected)), 1e-30)
end

function _solve(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _first_eigenvalue(model::AbstractDict)
    return Float64(_solve(model)["eigenvalues"][1])
end

function _expected_buckling_lambda(case, L::Real)
    Lf = Float64(L)
    K2 = [
        12.0 * E_BEAM * case.I2 / Lf^3     6.0 * E_BEAM * case.I2 / Lf^2;
        6.0 * E_BEAM * case.I2 / Lf^2      4.0 * E_BEAM * case.I2 / Lf
    ]
    Kg2 = [
        6.0 * case.axial_force / (5.0 * Lf)    case.axial_force / 10.0;
        case.axial_force / 10.0                2.0 * case.axial_force * Lf / 15.0
    ]
    vals = eigvals(Symmetric(K2), Symmetric(-Kg2))
    positive = sort!([Float64(v) for v in vals if isfinite(Float64(v)) && Float64(v) > 0.0])
    isempty(positive) && error("SOL105 beam shape guard found no positive analytical load factor.")
    return positive[1]
end

function _check_card(card::AbstractString)
    tmp = mktempdir(; prefix="openjfem_tacs_beam_sol105_shape_")
    case = _write_beam_buckling_deck(joinpath(tmp, "tacs_$(lowercase(card))_sol105_shape.bdf"), card)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    dv = Dict{String,Any}(
        "id" => "$(lowercase(case.card))_x2_buckling",
        "type" => "node_coord",
        "grid" => 2,
        "component" => 1,
    )

    response = OpenJFEM.buckling_load_factor_design_gradient(results, [dv]; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_coordinate_kg_directional_fd"
    h = Float64(response["directional_steps"][dv["id"]])
    hook = Float64(response["gradient"][dv["id"]])
    model_p = OpenJFEM._tacs_model_with_grid_coord_delta(model, 2, 1, h)
    model_m = OpenJFEM._tacs_model_with_grid_coord_delta(model, 2, 1, -h)
    fd = (_first_eigenvalue(model_p) - _first_eigenvalue(model_m)) / (2.0 * h)
    expected = (_expected_buckling_lambda(case, case.length + h) -
                _expected_buckling_lambda(case, case.length - h)) / (2.0 * h)
    fd_relerr = _relative_error(hook, fd)
    expected_relerr = _relative_error(hook, expected)
    @test isfinite(hook)
    @test isfinite(fd)
    @test isfinite(expected)
    @test fd_relerr < 1e-6
    @test expected_relerr < 1e-6

    ks_response = OpenJFEM.buckling_load_factor_ks_design_gradient(results, [dv]; modes=[1], rho=1.0)
    @test ks_response["gradient_backend"] == "tacs_formulation_buckling_ks_weighted_rayleigh"
    @test ks_response["base_gradient_backend"] == "tacs_formulation_rayleigh_coordinate_kg_directional_fd"
    ks_hook = Float64(ks_response["gradient"][dv["id"]])
    ks_relerr = _relative_error(ks_hook, fd)
    @test ks_relerr < 1e-6

    return Dict(
        "eigenvalue" => Float64(results["eigenvalues"][1]),
        "hook" => hook,
        "fd" => fd,
        "expected" => expected,
        "fd_relerr" => fd_relerr,
        "expected_relerr" => expected_relerr,
        "ks_hook" => ks_hook,
        "ks_relerr" => ks_relerr,
        "step" => h,
    )
end

function main()
    cbar = _check_card("CBAR")
    cbeam = _check_card("CBEAM")
    println("TACS SOL105 beam shape sensitivity guard passed")
    for (name, checks) in (("CBAR", cbar), ("CBEAM", cbeam))
        println("  $name eigenvalue                  = ", checks["eigenvalue"])
        println("  $name dLambda/dX FD/hook/expected = ",
            checks["fd"], " / ", checks["hook"], " / ", checks["expected"])
        println("  $name dLambda/dX relerr           = ", checks["fd_relerr"])
        println("  $name dLambda/dX expected relerr  = ", checks["expected_relerr"])
        println("  $name KS dLambda/dX hook/relerr   = ",
            checks["ks_hook"], " / ", checks["ks_relerr"])
        println("  $name coordinate step             = ", checks["step"])
    end
    return true
end

exit(main() ? 0 : 1)
