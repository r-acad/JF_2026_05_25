# Guard for TACS-formulation SOL101 CBAR/CBEAM KS beam-stress sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_stress_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_bending_deck(path::AbstractString, card_type::AbstractString)
    width_z = 8.0e-2
    height_y = 1.2e-1
    L = 2.0
    Fz = 120.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card beam stress sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBARL,1,1,,BAR,$width_z,$height_y")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card)
end

function _write_axial_deck(path::AbstractString, card_type::AbstractString)
    width_z = 8.0e-2
    height_y = 1.2e-1
    L = 2.4
    Fx = 1500.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card axial stress sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBARL,1,1,,BAR,$width_z,$height_y")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$Fx,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card)
end

function _solve_model_from_path(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _ks_beam_stress_response(; point::Int=3, beam_end::String="a")
    return Dict{String,Any}(
        "type" => "ks_von_mises",
        "eids" => [1],
        "beam_end" => beam_end,
        "beam_point" => point,
        "sigma_ref" => 1.0,
        "rho" => 50.0,
    )
end

function _response_value(results::AbstractDict, response::AbstractDict)
    subcase = results["subcases"][1]
    return OpenJFEM.Solver.evaluate_response(
        response,
        Float64.(subcase["u_analysis"]),
        results["model"],
        results["id_map"],
        Int(results["ndof"]),
        results["node_coords"],
        results["node_R"],
    )
end

function _property_value(model::AbstractDict, field::AbstractString)
    prop = model["PBARLs"]["1"]
    field == "I1" && return Float64(get(prop, "I1", get(prop, "I", 0.0)))
    return Float64(get(prop, field, 0.0))
end

function _model_with_property_delta(model::AbstractDict, field::AbstractString, delta::Real)
    m = deepcopy(model)
    prop = m["PBARLs"]["1"]
    prop[field] = _property_value(m, field) + Float64(delta)
    field == "I1" && (prop["I"] = prop[field])
    m["backend"] = "tacs_formulation"
    return m
end

function _model_with_material_delta(model::AbstractDict, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = m["MATs"]["1"]
    mat[field] = Float64(mat[field]) + Float64(delta)
    m["backend"] = "tacs_formulation"
    return m
end

function _fd_property_gradient(results::AbstractDict, response::AbstractDict, field::AbstractString)
    model = results["model"]
    value0 = _property_value(model, field)
    h = min(max(abs(value0) * 1e-5, 1e-11), 0.1 * value0)
    plus = OpenJFEM.solve_model(_model_with_property_delta(model, field, h))
    minus = OpenJFEM.solve_model(_model_with_property_delta(model, field, -h))
    return (_response_value(plus, response) - _response_value(minus, response)) / (2.0 * h)
end

function _fd_material_gradient(results::AbstractDict, response::AbstractDict, field::AbstractString)
    model = results["model"]
    value0 = Float64(model["MATs"]["1"][field])
    h = max(abs(value0) * 1e-5, 1e-3)
    plus = OpenJFEM.solve_model(_model_with_material_delta(model, field, h))
    minus = OpenJFEM.solve_model(_model_with_material_delta(model, field, -h))
    return (_response_value(plus, response) - _response_value(minus, response)) / (2.0 * h)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _check_bending_case(case)
    results = _solve_model_from_path(case.path)
    @test results["backend"] == "tacs_formulation"
    response = _ks_beam_stress_response(; point=3, beam_end="a")
    dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I2_stress", "type" => "beam_I2", "pids" => [1])
    gradient = OpenJFEM.static_ks_von_mises_design_gradient(results, response, [dv])
    hook = Float64(gradient["gradient"][dv["id"]])
    fd = _fd_property_gradient(results, response, "I2")
    rel = _relative_error(hook, fd)
    @test gradient["response"] == "ks_von_mises"
    @test gradient["gradient_backend"] == "tacs_formulation_stress_adjoint_design_tangent"
    @test rel < 5e-5
    return hook, fd, rel
end

function _check_axial_case(case)
    results = _solve_model_from_path(case.path)
    @test results["backend"] == "tacs_formulation"
    response = _ks_beam_stress_response(; point=1, beam_end="a")
    area_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_area_stress", "type" => "beam_area", "pids" => [1])
    e_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_E_stress", "type" => "material_E", "mids" => [1])
    gradient = OpenJFEM.static_ks_von_mises_design_gradient(results, response, [area_dv, e_dv])
    area_hook = Float64(gradient["gradient"][area_dv["id"]])
    e_hook = Float64(gradient["gradient"][e_dv["id"]])
    area_fd = _fd_property_gradient(results, response, "A")
    e_fd = _fd_material_gradient(results, response, "E")
    area_rel = _relative_error(area_hook, area_fd)
    e_abs = abs(e_hook - e_fd)
    @test area_rel < 5e-5
    @test e_abs < 1e-8
    return area_hook, area_fd, area_rel, e_hook, e_fd, e_abs
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_stress_sens_")
    cases = (
        _write_bending_deck(joinpath(tmp, "tacs_cbar_beam_stress_sens.bdf"), "CBAR"),
        _write_bending_deck(joinpath(tmp, "tacs_cbeam_beam_stress_sens.bdf"), "CBEAM"),
    )
    axial_cases = (
        _write_axial_deck(joinpath(tmp, "tacs_cbar_axial_stress_sens.bdf"), "CBAR"),
        _write_axial_deck(joinpath(tmp, "tacs_cbeam_axial_stress_sens.bdf"), "CBEAM"),
    )

    bending_checks = Dict(case.card => _check_bending_case(case) for case in cases)
    axial_checks = Dict(case.card => _check_axial_case(case) for case in axial_cases)

    println("TACS SOL101 beam stress sensitivity guard passed")
    for name in sort!(collect(keys(bending_checks)))
        hook, fd, rel = bending_checks[name]
        println("  $name beam_I2 stress FD/hook/rel = $fd / $hook / $rel")
    end
    for name in sort!(collect(keys(axial_checks)))
        area_hook, area_fd, area_rel, e_hook, e_fd, e_abs = axial_checks[name]
        println("  $name beam_area stress FD/hook/rel = $area_fd / $area_hook / $area_rel")
        println("  $name material_E stress FD/hook/abs = $e_fd / $e_hook / $e_abs")
    end
    return true
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main() ? 0 : 1)
end
