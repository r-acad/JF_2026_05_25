# Guard for TACS-formulation SOL103 CBAR/CBEAM modal offsets and pin releases.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_beam_offset_release_modal_route_check.jl

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

function _write_beam_modal_deck(path::AbstractString, card_type::AbstractString; spec=nothing)
    A = 1.0e-2
    I1 = 1.1e-6
    I2 = 2.3e-6
    J = 3.4e-6
    L = 2.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $card offset/release modal check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, _beam_card_line(card, spec))
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,1246,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
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

function _reduced_first_positive_eigenvalue(K, M, ndof::Int, model, id_map)
    free_dofs, _, diagnostics = OpenJFEM.Solver.compute_free_dofs(
        K,
        ndof,
        model,
        id_map,
        1,
        Dict{Int,Vector{Tuple{Int,Float64}}}();
        return_diagnostics=true,
    )
    @test !isempty(free_dofs)
    Kff = Matrix(K[free_dofs, free_dofs])
    Mff = Matrix(M[free_dofs, free_dofs])
    Kff = 0.5 .* (Kff .+ transpose(Kff))
    Mff = 0.5 .* (Mff .+ transpose(Mff))
    vals = eigvals(Symmetric(Kff), Symmetric(Mff))
    positive = sort!([Float64(v) for v in vals if isfinite(v) && v > 1.0e-6])
    @test !isempty(positive)
    return positive[1], diagnostics
end

function _relative_matrix_delta(a::AbstractMatrix, b::AbstractMatrix)
    return norm(Matrix(a) - Matrix(b)) / max(norm(Matrix(b)), 1.0e-30)
end

function _check_modal_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    case.spec !== nothing && _check_parsed_spec(model, case.card, case.spec)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, _, _, _ =
        OpenJFEM._tacs_assemble_sol101(
            model;
            allowed_sol_types=(103,),
            route_label="SOL103 beam offset/release guard",
        )
    M = OpenJFEM._tacs_sol103_modal_mass_builder(model, id_map, X, node_R, ndof)
    @test norm(Matrix(K) - transpose(Matrix(K))) / max(norm(K), 1.0e-30) < 1.0e-12
    @test norm(Matrix(M) - transpose(Matrix(M))) / max(norm(M), 1.0e-30) < 1.0e-12

    expected_lambda, bc_diagnostics = _reduced_first_positive_eigenvalue(K, M, ndof, model, id_map)

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test occursin("residual_first_cbar_cbeam_sol101_sol103_sol105", results["tacs_formulation_sol103"]["linear_stiffness"])
    @test occursin("tacs_lumped_cbar_cbeam_mass", results["tacs_formulation_sol103"]["mass"])
    @test !isempty(results["eigenvalues"])

    lambda_relerr = abs(Float64(results["eigenvalues"][1]) - expected_lambda) /
        max(abs(expected_lambda), 1.0e-30)
    @test lambda_relerr < 1.0e-10

    return Dict(
        "K" => Matrix(K),
        "M" => Matrix(M),
        "lambda" => Float64(results["eigenvalues"][1]),
        "lambda_relerr" => lambda_relerr,
        "free_dofs" => Int(get(bc_diagnostics, "free_dofs", 0)),
        "fixed_dofs" => Int(get(bc_diagnostics, "fixed_dofs", 0)),
    )
end

function _check_card(tmp::AbstractString, card::AbstractString)
    specs = Dict(
        "offset" => (pa=0, pb=0, wa=(0.0, 0.12, 0.08), wb=(0.0, -0.04, 0.03)),
        "release" => (pa=0, pb=5, wa=(0.0, 0.0, 0.0), wb=(0.0, 0.0, 0.0)),
        "offset_release" => (pa=0, pb=5, wa=(0.0, 0.12, 0.08), wb=(0.0, -0.04, 0.03)),
    )

    base = _check_modal_case(
        _write_beam_modal_deck(joinpath(tmp, "tacs_$(lowercase(card))_sol103_base.bdf"), card),
    )
    checks = Dict{String,Any}()
    for name in sort(collect(keys(specs)))
        item = _check_modal_case(
            _write_beam_modal_deck(
                joinpath(tmp, "tacs_$(lowercase(card))_sol103_$(name).bdf"),
                card;
                spec=specs[name],
            ),
        )
        k_delta = _relative_matrix_delta(item["K"], base["K"])
        m_delta = _relative_matrix_delta(item["M"], base["M"])
        @test k_delta > 1.0e-12
        if occursin("offset", name)
            @test m_delta > 1.0e-12
        end
        checks[name] = merge(item, Dict("K_delta" => k_delta, "M_delta" => m_delta))
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_modal_offset_release_")
    checks = Dict{String,Any}()
    for card in ("CBAR", "CBEAM")
        card_checks = _check_card(tmp, card)
        for (name, item) in card_checks
            checks["$(card)_$name"] = item
        end
    end

    println("TACS SOL103 beam offset/release modal route guard passed")
    for key in sort(collect(keys(checks)))
        item = checks[key]
        println("  $key eigenvalue relerr = $(item["lambda_relerr"])")
        println("  $key K delta           = $(item["K_delta"])")
        println("  $key M delta           = $(item["M_delta"])")
        println("  $key free/fixed DOFs   = $(item["free_dofs"])/$(item["fixed_dofs"])")
    end
    return true
end

exit(main() ? 0 : 1)
