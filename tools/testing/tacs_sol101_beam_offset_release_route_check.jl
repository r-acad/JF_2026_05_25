# Guard for TACS-formulation SOL101 CBAR/CBEAM offsets and pin releases.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_offset_release_route_check.jl

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

function _write_base_beam_deck(path::AbstractString, card_type::AbstractString; spec=nothing)
    A = 1.0e-2
    I1 = 1.1e-6
    I2 = 2.3e-6
    J = 3.4e-6
    L = 2.0
    Fz = 100.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card offset/release check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, _beam_card_line(card, spec))
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, length=L, force_z=Fz, spec=spec)
end

function _element_group(card::AbstractString)
    c = uppercase(card)
    c == "CBAR" && return "CBARs"
    c == "CBEAM" && return "CBEAMs"
    error("unsupported beam card $card")
end

function _beam_element!(model::AbstractDict, card::AbstractString)
    group = get(model, _element_group(card), Dict())
    @test haskey(group, "1")
    return group["1"]
end

function _configure_case!(model::AbstractDict, card::AbstractString, spec::NamedTuple)
    beam = _beam_element!(model, card)
    beam["PA"] = Int(_spec_value(spec, :pa, 0))
    beam["PB"] = Int(_spec_value(spec, :pb, 0))
    beam["WA"] = Float64.(collect(_spec_value(spec, :wa, (0.0, 0.0, 0.0))))
    beam["WB"] = Float64.(collect(_spec_value(spec, :wb, (0.0, 0.0, 0.0))))
    return model
end

function _check_parsed_spec(model::AbstractDict, card::AbstractString, spec::NamedTuple)
    beam = _beam_element!(model, card)
    @test Int(get(beam, "PA", 0)) == Int(_spec_value(spec, :pa, 0))
    @test Int(get(beam, "PB", 0)) == Int(_spec_value(spec, :pb, 0))
    @test Float64.(get(beam, "WA", [])) == Float64.(collect(_spec_value(spec, :wa, (0.0, 0.0, 0.0))))
    @test Float64.(get(beam, "WB", [])) == Float64.(collect(_spec_value(spec, :wb, (0.0, 0.0, 0.0))))
    return nothing
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _relative_norm(a, b)
    return norm(Matrix(a) - Matrix(b)) / max(norm(Matrix(b)), 1e-30)
end

function _solve_displacements(model)
    results = OpenJFEM.solve_model(model)
    return results, Float64.(results["subcases"][1]["u_analysis"])
end

function _check_static_model(case, parity_model::Dict)
    parity_model["backend"] = "nastran_parity"

    tacs_model = deepcopy(parity_model)
    tacs_model["backend"] = "tacs_formulation"

    K_ref, id_ref, _, ndof_ref, _, _, _, _, _ =
        OpenJFEM.Solver.assemble_stiffness(parity_model; sol101_context=true)
    K_tacs, id_tacs, _, ndof_tacs, _, max_elem_stiff, _, _, _ =
        OpenJFEM._tacs_assemble_sol101(tacs_model)

    @test id_tacs == id_ref
    @test ndof_tacs == ndof_ref == 12
    @test max_elem_stiff > 0.0
    @test norm(Matrix(K_tacs) - transpose(Matrix(K_tacs))) / max(norm(K_tacs), 1e-30) < 1e-12

    k_relerr = _relative_norm(K_tacs, K_ref)
    @test k_relerr < 1e-12

    parity_results, u_ref = _solve_displacements(parity_model)
    tacs_results, u_tacs = _solve_displacements(tacs_model)
    @test parity_results["backend"] == "nastran_parity"
    @test tacs_results["backend"] == "tacs_formulation"
    @test tacs_results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"

    u_relerr = norm(u_tacs - u_ref) / max(norm(u_ref), 1e-30)
    @test u_relerr < 1e-10
    return Dict(
        "matrix_relerr" => k_relerr,
        "disp_relerr" => u_relerr,
        "tip_uz" => u_tacs[_grid_dof(id_tacs, 2, 3)],
    )
end

function _check_static_case(case, spec::NamedTuple)
    parity_model = OpenJFEM.bdf_to_model(case.path)
    _configure_case!(parity_model, case.card, spec)
    return _check_static_model(case, parity_model)
end

function _check_parser_backed_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    _check_parsed_spec(model, case.card, case.spec)
    return _check_static_model(case, model)
end

function _model_for_sol(case, spec::NamedTuple, sol::Int)
    model = OpenJFEM.bdf_to_model(case.path)
    _configure_case!(model, case.card, spec)
    model["SOL"] = sol
    model["CASE_CONTROL"]["SOL"] = sol
    model["backend"] = "tacs_formulation"
    return model
end

function _expect_beam_feature_rejection(case, spec::NamedTuple, sol::Int, needle::AbstractString)
    model = _model_for_sol(case, spec, sol)
    caught = false
    msg = ""
    try
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(sol,), route_label="SOL$sol offset/release guard")
    catch err
        caught = true
        msg = lowercase(sprint(showerror, err))
    end
    @test caught
    @test occursin(lowercase(needle), msg)
    return msg
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_offset_release_")
    cases = Any[
        _write_base_beam_deck(joinpath(tmp, "tacs_cbar_sol101_offset_release.bdf"), "CBAR"),
        _write_base_beam_deck(joinpath(tmp, "tacs_cbeam_sol101_offset_release.bdf"), "CBEAM"),
    ]
    specs = Dict(
        "offset" => (pa=0, pb=0, wa=(0.0, 0.0, 0.15), wb=(0.0, 0.0, 0.05)),
        "release" => (pa=0, pb=5, wa=(0.0, 0.0, 0.0), wb=(0.0, 0.0, 0.0)),
        "offset_release" => (pa=0, pb=5, wa=(0.0, 0.12, 0.08), wb=(0.0, -0.04, 0.03)),
    )

    checks = Dict{String,Any}()
    for case in cases
        for name in sort(collect(keys(specs)))
            checks["$(case.card)_$name"] = _check_static_case(case, specs[name])
        end
        _expect_beam_feature_rejection(case, specs["offset"], 106, "unsupported groups")
        _expect_beam_feature_rejection(case, specs["release"], 106, "unsupported groups")
    end
    parser_cases = Any[
        _write_base_beam_deck(
            joinpath(tmp, "tacs_cbar_sol101_parser_offset_release.bdf"),
            "CBAR";
            spec=specs["offset_release"],
        ),
        _write_base_beam_deck(
            joinpath(tmp, "tacs_cbeam_sol101_parser_offset_release.bdf"),
            "CBEAM";
            spec=specs["offset_release"],
        ),
    ]
    for case in parser_cases
        checks["$(case.card)_parser_offset_release"] = _check_parser_backed_case(case)
    end

    println("TACS SOL101 beam offset/release route guard passed")
    for key in sort(collect(keys(checks)))
        item = checks[key]
        println("  $key matrix relerr = $(item["matrix_relerr"])")
        println("  $key disp relerr   = $(item["disp_relerr"])")
        println("  $key tip uz        = $(item["tip_uz"])")
    end
    return true
end

exit(main() ? 0 : 1)
