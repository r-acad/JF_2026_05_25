# Finite-difference guard for MAT8 strength-field sensitivities in ks_ply_failure.
#
# The guard checks explicit SOL101 PCOMP failure-response derivatives for MAT8
# strength allowables against full plus/minus static re-solves. Strength fields
# affect only the failure response, so the TACS hook should use zero stiffness
# and load tangents plus an explicit response derivative.
#
# Usage:
#   julia --project=. tools/testing/tacs_pcomp_failure_strength_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_pcomp_failure_deck(path::AbstractString)
    nx = 2
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS PCOMP failure strength sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx + 0.08 * j
            y = j / ny
            z = 0.015 * sin(pi * i / max(nx, 1)) * j
            println(io, "GRID,$gid,,$x,$y,$z")
        end
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,1,2,3,6,5")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.,0.,0.,0.,1.8E9,1.2E9,6.0E7,2.0E8,9.0E7,0.,0.")
        println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,45.,YES,1,0.0015,-30.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for (k, nid) in enumerate(top)
            println(io, "FORCE,1,$nid,0,$(55.0 + 12.0 * k),0.20,0.05,-1.")
        end
        println(io, "ENDDATA")
    end
    return path
end

function _response_value(results::AbstractDict, response::AbstractDict)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return Float64(OpenJFEM.Solver.evaluate_response(
        response,
        u,
        results["model"],
        results["id_map"],
        results["ndof"],
        results["node_coords"],
        results["node_R"],
    ))
end

function _strength_step(model::AbstractDict, mid::Integer, field::AbstractString)
    value = Float64(model["MATs"][string(Int(mid))][field])
    return min(max(abs(value) * 1e-6, 1e-3), 0.25 * value)
end

function _model_with_strength_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Float64)
    m = deepcopy(model)
    m["MATs"][string(Int(mid))][field] = Float64(m["MATs"][string(Int(mid))][field]) + delta
    return m
end

function _fd_gradient(model::AbstractDict, mid::Integer, field::AbstractString, step::Float64, response::AbstractDict)
    model_p = _model_with_strength_delta(model, mid, field, step)
    model_m = _model_with_strength_delta(model, mid, field, -step)
    results_p = OpenJFEM.solve_model(model_p)
    results_m = OpenJFEM.solve_model(model_m)
    return (_response_value(results_p, response) - _response_value(results_m, response)) / (2.0 * step)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_pcomp_failure_strength_")
    deck = _write_pcomp_failure_deck(joinpath(tmp, "pcomp_failure_strength.bdf"))

    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    response = Dict{String,Any}(
        "type" => "ks_ply_failure",
        "criterion" => "modified_tsai_wu",
        "eids" => "all",
        "plies" => "all",
        "surface" => "both",
        "rho" => 18.0,
        "failure_ref" => 1.0,
    )
    design_variables = Dict{String,Any}[
        Dict("id" => "mat_xt", "type" => "material_XT", "mids" => [1]),
        Dict("id" => "mat_s", "type" => "material_S", "mids" => [1]),
    ]
    fields = Dict("mat_xt" => "XT", "mat_s" => "S")

    gradient = OpenJFEM.static_ks_ply_failure_design_gradient(results, response, design_variables)
    @test gradient["response"] == "ks_ply_failure"
    @test gradient["gradient_backend"] == "tacs_formulation_ply_failure_adjoint_design_tangent"

    relerrs = Dict{String,Float64}()
    for dv in design_variables
        dv_id = string(dv["id"])
        diag = gradient["design_variable_diagnostics"][dv_id]
        @test diag["sensitivity_contract"]["derivative_method"] == "explicit_failure_strength"
        field = fields[dv_id]
        step = _strength_step(model, 1, field)
        fd = _fd_gradient(model, 1, field, step, response)
        hook = Float64(gradient["gradient"][dv_id])
        rel = abs(fd - hook) / max(abs(fd), abs(hook), 1e-30)
        relerrs[dv_id] = rel
        @test rel < 1e-5
    end

    println("TACS PCOMP failure strength sensitivity check passed")
    println("  deck                     = ", abspath(deck))
    println("  response value           = ", gradient["value"])
    println("  XT rel error             = ", relerrs["mat_xt"])
    println("  S rel error              = ", relerrs["mat_s"])
    return true
end

main()
