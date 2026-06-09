# Finite-difference guard for TACS PCOMP ply KS von-Mises sensitivities.
#
# The guard uses a compact unsymmetric MAT8 PCOMP laminate and checks SOL101
# KS von-Mises response derivatives for PCOMP ply thickness and ply angle
# variables against full plus/minus static re-solves.
#
# Usage:
#   julia --project=. tools/testing/tacs_pcomp_stress_ks_ply_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_pcomp_stress_deck(path::AbstractString)
    nx = 2
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS PCOMP KS stress ply sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx + 0.11 * j
            y = j / ny
            z = 0.02 * sin(pi * i / max(nx, 1)) * j
            println(io, "GRID,$gid,,$x,$y,$z")
        end
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,1,2,3,6,5")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,45.,YES,1,0.0015,-30.,YES")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for (k, nid) in enumerate(top)
            println(io, "FORCE,1,$nid,0,$(40.0 + 10.0 * k),0.,0.,-1.")
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

function _fd_gradient(model::AbstractDict, pid::Integer, dv::AbstractDict, step::Float64, response::AbstractDict)
    model_p = OpenJFEM._tacs_model_with_pcomp_ply_delta(
        model,
        pid,
        Int(dv["ply_index"]),
        string(dv["type"]),
        step,
    )
    model_m = OpenJFEM._tacs_model_with_pcomp_ply_delta(
        model,
        pid,
        Int(dv["ply_index"]),
        string(dv["type"]),
        -step,
    )
    results_p = OpenJFEM.solve_model(model_p)
    results_m = OpenJFEM.solve_model(model_m)
    return (_response_value(results_p, response) - _response_value(results_m, response)) / (2.0 * step)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_pcomp_stress_ks_ply_")
    deck = _write_pcomp_stress_deck(joinpath(tmp, "pcomp_stress_ks_ply.bdf"))

    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)

    response = Dict{String,Any}(
        "type" => "ks_von_mises",
        "eids" => "all",
        "surface" => "top",
        "rho" => 25.0,
        "sigma_ref" => 1.0,
    )
    design_variables = Dict{String,Any}[
        Dict("id" => "ply1_t", "type" => "pcomp_ply_thickness", "pids" => [1], "ply_index" => 1),
        Dict("id" => "ply2_theta", "type" => "pcomp_ply_angle", "pids" => [1], "ply_index" => 2),
    ]

    gradient = OpenJFEM.static_ks_von_mises_design_gradient(results, response, design_variables)
    @test gradient["response"] == "ks_von_mises"
    @test gradient["gradient_backend"] == "tacs_formulation_stress_adjoint_design_tangent"
    @test Float64(gradient["value"]) > 0.0

    relerrs = Dict{String,Float64}()
    for dv in design_variables
        dv_id = string(dv["id"])
        diag = gradient["design_variable_diagnostics"][dv_id]
        step = Float64(diag["step"])
        @test step > 0.0
        fd_step = string(dv["type"]) == "pcomp_ply_angle" ? max(step, 1e-4) : step
        fd = _fd_gradient(model, 1, dv, fd_step, response)
        hook = Float64(gradient["gradient"][dv_id])
        rel = abs(fd - hook) / max(abs(fd), abs(hook), 1e-30)
        relerrs[dv_id] = rel
        @test rel < 5e-5
    end

    println("TACS PCOMP KS stress ply sensitivity check passed")
    println("  deck                     = ", abspath(deck))
    println("  response value           = ", gradient["value"])
    println("  ply-thickness rel error  = ", relerrs["ply1_t"])
    println("  ply-angle rel error      = ", relerrs["ply2_theta"])
    return true
end

main()
