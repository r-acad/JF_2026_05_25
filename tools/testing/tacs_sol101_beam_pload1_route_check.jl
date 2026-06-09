# Guard for TACS-formulation SOL101 CBAR/CBEAM PLOAD1 beam loads.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_pload1_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_pload1_deck(
    path::AbstractString,
    card_type::AbstractString,
    load_type::AbstractString,
    scale_type::AbstractString,
    x1::Real,
    p1::Real,
    x2::Real,
    p2::Real,
)
    A = 1.0e-2
    I1 = 1.2e-6
    I2 = 2.4e-6
    J = 3.2e-6
    L = 2.4
    card = uppercase(card_type)
    load = uppercase(load_type)
    scale = uppercase(scale_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card PLOAD1 $load check")
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
        println(io, "PLOAD1,1,1,$load,$scale,$x1,$p1,$x2,$p2")
        println(io, "ENDDATA")
    end
    return (
        path=path, card=card, load=load, scale=scale,
        x1=Float64(x1), p1=Float64(p1), x2=Float64(x2), p2=Float64(p2),
        length=L, area=A, I1=I1, I2=I2, torsion=J,
    )
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _relerr(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _integrate_5pt(f, a::Float64, b::Float64)
    xg = (
        -0.906179845938664,
        -0.5384693101056831,
        0.0,
        0.5384693101056831,
        0.906179845938664,
    )
    wg = (
        0.2369268850561891,
        0.47862867049936647,
        0.5688888888888889,
        0.47862867049936647,
        0.2369268850561891,
    )
    mid = 0.5 * (a + b)
    half = 0.5 * (b - a)
    total = 0.0
    for (xi, wi) in zip(xg, wg)
        total += wi * f(mid + half * xi)
    end
    return half * total
end

function _physical_interval(case)
    xa0, xb0 =
        case.scale == "FR" ?
        (case.x1 * case.length, case.x2 * case.length) :
        (case.x1, case.x2)
    xa = clamp(xa0, 0.0, case.length)
    xb = clamp(xb0, 0.0, case.length)
    @test xb > xa
    return xa0, xb0, xa, xb
end

function _q_at(case, x::Float64, xa0::Float64, xb0::Float64)
    return case.p1 + (case.p2 - case.p1) * (x - xa0) / (xb0 - xa0)
end

function _expected(case)
    xa0, xb0, xa, xb = _physical_interval(case)
    q(x) = _q_at(case, x, xa0, xb0)
    inertia = case.load == "FY" ? case.I1 : case.I2
    shear = _integrate_5pt(x -> q(x), xa, xb)
    moment = _integrate_5pt(x -> q(x) * x, xa, xb)
    tip = _integrate_5pt(
        x -> q(x) * x^2 * (3.0 * case.length - x) / (6.0 * E_BEAM * inertia),
        xa,
        xb,
    )
    return shear, moment, tip
end

function _solve(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _check_case(case)
    results = _solve(case)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    subcase = results["subcases"][1]
    u = Float64.(subcase["u_analysis"])
    id_map = results["id_map"]
    force_rows = subcase["forces"]["cbar"]
    @test length(force_rows) == 1
    force_row = first(force_rows)

    expected_shear, expected_moment, expected_tip = _expected(case)
    response_dof = case.load == "FY" ? 2 : 3
    orthogonal_dof = case.load == "FY" ? 3 : 2
    shear_key = case.load == "FY" ? "shear_1" : "shear_2"
    moment_key = case.load == "FY" ? "moment_a1" : "moment_a2"

    tip_relerr = _relerr(u[_grid_dof(id_map, 2, response_dof)], expected_tip)
    shear_relerr = _relerr(force_row[shear_key], expected_shear)
    moment_relerr = _relerr(force_row[moment_key], expected_moment)
    orthogonal_abs = abs(u[_grid_dof(id_map, 2, orthogonal_dof)])

    @test tip_relerr < 1e-10
    @test shear_relerr < 1e-10
    @test moment_relerr < 1e-10
    @test orthogonal_abs < 1e-14
    return Dict(
        "tip" => tip_relerr,
        "shear" => shear_relerr,
        "moment" => moment_relerr,
        "orthogonal_abs" => orthogonal_abs,
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_pload1_")
    cases = Any[]
    for card in ("CBAR", "CBEAM")
        push!(cases, _write_beam_pload1_deck(
            joinpath(tmp, "tacs_$(lowercase(card))_pload1_fy_le.bdf"),
            card, "FY", "LE", 0.0, 70.0, 2.4, 70.0))
        push!(cases, _write_beam_pload1_deck(
            joinpath(tmp, "tacs_$(lowercase(card))_pload1_fz_fr_partial.bdf"),
            card, "FZ", "FR", 0.2, 45.0, 0.85, 90.0))
    end

    checks = Dict{String,Any}()
    for case in cases
        checks["$(case.card)_$(case.load)_$(case.scale)"] = _check_case(case)
    end

    println("TACS SOL101 beam PLOAD1 route guard passed")
    for key in sort(collect(keys(checks)))
        item = checks[key]
        println("  $key tip relerr        = $(item["tip"])")
        println("  $key shear relerr      = $(item["shear"])")
        println("  $key moment relerr     = $(item["moment"])")
        println("  $key orthogonal abs    = $(item["orthogonal_abs"])")
    end
    return true
end

exit(main() ? 0 : 1)
