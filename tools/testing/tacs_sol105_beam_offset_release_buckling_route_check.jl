# Guard for TACS-formulation SOL105 CBAR/CBEAM buckling offsets and pin releases.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_beam_offset_release_buckling_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _spec_value(spec::NamedTuple, key::Symbol, default)
    return haskey(spec, key) ? getfield(spec, key) : default
end

function _beam_card_line(card::AbstractString, spec)
    spec === nothing && return "$card,1,1,1,2,0.,1.,0."
    pa = Int(_spec_value(spec, :pa, 0))
    pb = Int(_spec_value(spec, :pb, 0))
    wa = Float64.(collect(_spec_value(spec, :wa, (0.0, 0.0, 0.0))))
    wb = Float64.(collect(_spec_value(spec, :wb, (0.0, 0.0, 0.0))))
    return "$card,1,1,1,2,0.,1.,0.,,$pa,$pb,$(wa[1]),$(wa[2]),$(wa[3]),$(wb[1]),$(wb[2]),$(wb[3])"
end

function _write_beam_buckling_deck(path::AbstractString, card_type::AbstractString; spec=nothing)
    A = 1.0e-2
    I1 = 1.1e-6
    I2 = 2.3e-6
    J = 3.4e-6
    L = 2.0
    axial_force = -800.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 $card offset/release buckling check")
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
        println(io, _beam_card_line(card, spec))
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "SPC1,2,123456,1")
        println(io, "SPC1,2,1246,2")
        println(io, "FORCE,1,2,0,$(-axial_force),-1.,0.,0.")
        println(io, "EIGRL,1,,,2")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, spec=spec)
end

function _element_group(card::AbstractString)
    c = uppercase(card)
    c == "CBAR" && return "CBARs"
    c == "CBEAM" && return "CBEAMs"
    error("unsupported beam card $card")
end

function _beam_element(model::AbstractDict, card::AbstractString)
    group = get(model, _element_group(card), Dict())
    @test haskey(group, "1")
    return group["1"]
end

function _check_parsed_spec(model::AbstractDict, card::AbstractString, spec::NamedTuple)
    beam = _beam_element(model, card)
    @test Int(get(beam, "PA", 0)) == Int(_spec_value(spec, :pa, 0))
    @test Int(get(beam, "PB", 0)) == Int(_spec_value(spec, :pb, 0))
    @test Float64.(get(beam, "WA", [])) == Float64.(collect(_spec_value(spec, :wa, (0.0, 0.0, 0.0))))
    @test Float64.(get(beam, "WB", [])) == Float64.(collect(_spec_value(spec, :wb, (0.0, 0.0, 0.0))))
    return nothing
end

function _solve_backend(model::AbstractDict, backend::AbstractString)
    m = deepcopy(model)
    m["backend"] = backend
    return OpenJFEM.solve_model(m)
end

function _relative_norm(a, b)
    return norm(Matrix(a) - Matrix(b)) / max(norm(Matrix(b)), 1.0e-30)
end

function _relative_scalar(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1.0e-30)
end

function _reduced_first_positive_buckling_eigenvalue(results::AbstractDict)
    ndof = Int(results["ndof"])
    model = results["model"]
    buckling_subcase = get(get(model["CASE_CONTROL"], "SUBCASES", Dict()), 2, Dict{String,Any}())
    spc_id = get(buckling_subcase, "SPC", 2)
    free_dofs, fixed_dofs = OpenJFEM.Solver.compute_free_dofs(
        results["K_eig"],
        ndof,
        model,
        results["id_map"],
        spc_id,
        results["rbe3_map"],
    )
    @test !isempty(free_dofs)
    Kff = Matrix(results["K_eig"][free_dofs, free_dofs])
    Kgff = Matrix(results["Kg"][free_dofs, free_dofs])
    Kff = 0.5 .* (Kff .+ transpose(Kff))
    Bff = -0.5 .* (Kgff .+ transpose(Kgff))
    kfac = cholesky(Symmetric(Kff))
    L = Matrix(kfac.L)
    C = L \ (Bff / transpose(L))
    C = 0.5 .* (C .+ transpose(C))
    theta = eigvals(Symmetric(C))
    lambdas = [1.0 / Float64(t) for t in theta if isfinite(t) && abs(Float64(t)) > 1.0e-12]
    positive = sort!([v for v in lambdas if isfinite(v) && v > 1.0e-8])
    @test !isempty(positive)
    return positive[1], length(free_dofs), length(fixed_dofs)
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    case.spec !== nothing && _check_parsed_spec(model, case.card, case.spec)

    tacs = _solve_backend(model, "tacs_formulation")
    parity = _solve_backend(model, "nastran_parity")

    @test tacs["backend"] == "tacs_formulation"
    @test tacs["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test tacs["formulation"]["beam_geometric_stiffness"] == "native_residual_first_cbar_cbeam_operator"
    @test Int(get(get(tacs["solver_diagnostics"][1], "kg_timings", Dict()), "tacs_native_kg_beam_elements", 0)) == 1
    @test !isempty(tacs["eigenvalues"])
    @test !isempty(parity["eigenvalues"])

    expected, free_dofs, fixed_dofs = _reduced_first_positive_buckling_eigenvalue(tacs)
    eig_reduced_relerr = _relative_scalar(tacs["eigenvalues"][1], expected)
    eig_parity_relerr = _relative_scalar(tacs["eigenvalues"][1], parity["eigenvalues"][1])
    k_relerr = _relative_norm(tacs["K"], parity["K"])
    kg_relerr = _relative_norm(tacs["Kg"], parity["Kg"])
    u_relerr = norm(Float64.(tacs["u_static"]) - Float64.(parity["u_static"])) /
        max(norm(Float64.(parity["u_static"])), 1.0e-30)

    @test eig_reduced_relerr < 1.0e-9
    @test eig_parity_relerr < 1.0e-8
    @test k_relerr < 1.0e-12
    @test kg_relerr < 1.0e-12
    @test u_relerr < 1.0e-10

    return Dict(
        "K" => Matrix(tacs["K"]),
        "Kg" => Matrix(tacs["Kg"]),
        "eigenvalue" => Float64(tacs["eigenvalues"][1]),
        "eig_reduced_relerr" => eig_reduced_relerr,
        "eig_parity_relerr" => eig_parity_relerr,
        "K_parity_relerr" => k_relerr,
        "Kg_parity_relerr" => kg_relerr,
        "u_parity_relerr" => u_relerr,
        "free_dofs" => free_dofs,
        "fixed_dofs" => fixed_dofs,
    )
end

function _check_card(tmp::AbstractString, card::AbstractString)
    specs = Dict(
        "offset" => (pa=0, pb=0, wa=(0.0, 0.12, 0.08), wb=(0.0, -0.04, 0.03)),
        "release" => (pa=0, pb=5, wa=(0.0, 0.0, 0.0), wb=(0.0, 0.0, 0.0)),
        "offset_release" => (pa=0, pb=5, wa=(0.0, 0.12, 0.08), wb=(0.0, -0.04, 0.03)),
    )
    base = _check_case(
        _write_beam_buckling_deck(joinpath(tmp, "tacs_$(lowercase(card))_sol105_base.bdf"), card),
    )
    checks = Dict{String,Any}()
    for name in sort(collect(keys(specs)))
        item = _check_case(
            _write_beam_buckling_deck(
                joinpath(tmp, "tacs_$(lowercase(card))_sol105_$(name).bdf"),
                card;
                spec=specs[name],
            ),
        )
        k_delta = _relative_norm(item["K"], base["K"])
        kg_delta = _relative_norm(item["Kg"], base["Kg"])
        eig_delta = _relative_scalar(item["eigenvalue"], base["eigenvalue"])
        @test k_delta > 1.0e-12
        @test eig_delta > 1.0e-12
        if occursin("offset", name)
            @test kg_delta > 1.0e-12
        end
        checks[name] = merge(item, Dict("K_delta" => k_delta, "Kg_delta" => kg_delta, "eig_delta" => eig_delta))
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_sol105_offset_release_")
    checks = Dict{String,Any}()
    for card in ("CBAR", "CBEAM")
        card_checks = _check_card(tmp, card)
        for (name, item) in card_checks
            checks["$(card)_$name"] = item
        end
    end

    println("TACS SOL105 beam offset/release buckling route guard passed")
    for key in sort(collect(keys(checks)))
        item = checks[key]
        println("  $key reduced eigen relerr = $(item["eig_reduced_relerr"])")
        println("  $key parity eigen relerr  = $(item["eig_parity_relerr"])")
        println("  $key K parity relerr      = $(item["K_parity_relerr"])")
        println("  $key Kg parity relerr     = $(item["Kg_parity_relerr"])")
        println("  $key u parity relerr      = $(item["u_parity_relerr"])")
        println("  $key K delta              = $(item["K_delta"])")
        println("  $key Kg delta             = $(item["Kg_delta"])")
        println("  $key eig delta            = $(item["eig_delta"])")
        println("  $key free/fixed DOFs      = $(item["free_dofs"])/$(item["fixed_dofs"])")
    end
    return true
end

exit(main() ? 0 : 1)
