# Finite-difference guard for TACS PCOMP ply eigen sensitivities.
#
# Checks SOL103 modal and SOL105 buckling first-eigenvalue derivatives for
# PCOMP ply thickness and ply angle design variables against full plus/minus
# re-solves of the laminate CLT data.
#
# Usage:
#   julia --project=. tools/testing/tacs_pcomp_eigen_ply_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_pcomp_eigen_deck(path::AbstractString, sol::Integer)
    sol in (103, 105) || error("PCOMP eigen guard only writes SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS SOL", sol, " PCOMP ply eigen sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        if sol == 103
            println(io, "  METHOD = 1")
        else
            println(io, "  LOAD = 1")
            println(io, "SUBCASE 2")
            println(io, "  SPC = 1")
            println(io, "  METHOD = 1")
            println(io, "  STATSUB = 1")
        end
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        sol == 103 && println(io, "PARAM,COUPMASS,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,35.,YES,1,0.0015,-20.,YES")
        println(io, "SPC1,1,123456,1,4")
        if sol == 105
            println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
            println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        end
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "ENDDATA")
    end
    return path
end

function _solve_model(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _first_eigenvalue(model::AbstractDict)
    return Float64(_solve_model(model)["eigenvalues"][1])
end

function _perturbed_model(model::AbstractDict, dv::AbstractDict, step::Real)
    pid = Int(only(Int.(collect(dv["pids"]))))
    return OpenJFEM._tacs_model_with_pcomp_ply_delta(
        model,
        pid,
        Int(dv["ply_index"]),
        string(dv["type"]),
        Float64(step),
    )
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function _check_response(results::AbstractDict, response::AbstractDict, dv::AbstractDict, model::AbstractDict; rel_tol::Real)
    dv_id = string(dv["id"])
    diag = response["design_variable_diagnostics"][dv_id]
    h = Float64(diag["step"])
    @test h > 0.0
    model_p = _perturbed_model(model, dv, h)
    model_m = _perturbed_model(model, dv, -h)
    fd = (_first_eigenvalue(model_p) - _first_eigenvalue(model_m)) / (2.0 * h)
    hook = Float64(response["gradient"][dv_id])
    relerr = _relerr(hook, fd)
    @test isfinite(fd)
    @test isfinite(hook)
    @test relerr < rel_tol
    return fd, hook, relerr
end

function _check_modal(results::AbstractDict)
    model = results["model"]
    dvs = Dict{String,Any}[
        Dict("id" => "pcomp1_ply1_t", "type" => "pcomp_ply_thickness", "pids" => [1], "ply_index" => 1),
        Dict("id" => "pcomp1_ply2_theta", "type" => "pcomp_ply_angle", "pids" => [1], "ply_index" => 2),
    ]
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, dvs; mode=1)
    @test response["response"] == "modal_eigenvalue"
    @test response["gradient_backend"] == "tacs_formulation_modal_design_tangent_fd"
    checks = Dict{String,Any}()
    for dv in dvs
        checks[string(dv["id"])] = _check_response(results, response, dv, model; rel_tol=2e-4)
    end
    return checks
end

function _check_buckling(results::AbstractDict)
    model = results["model"]
    dvs = Dict{String,Any}[
        Dict("id" => "pcomp1_ply1_t", "type" => "pcomp_ply_thickness", "pids" => [1], "ply_index" => 1),
        Dict("id" => "pcomp1_ply2_theta", "type" => "pcomp_ply_angle", "pids" => [1], "ply_index" => 2),
    ]
    response = OpenJFEM.buckling_load_factor_design_gradient(results, dvs; mode=1)
    @test response["response"] == "buckling_load_factor"
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    checks = Dict{String,Any}()
    for dv in dvs
        checks[string(dv["id"])] = _check_response(results, response, dv, model; rel_tol=2e-3)
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_pcomp_eigen_ply_")
    sol103_deck = _write_pcomp_eigen_deck(joinpath(tmp, "pcomp_ply_sol103.bdf"), 103)
    sol105_deck = _write_pcomp_eigen_deck(joinpath(tmp, "pcomp_ply_sol105.bdf"), 105)

    sol103_model = OpenJFEM.bdf_to_model(sol103_deck)
    sol103_model["backend"] = "tacs_formulation"
    sol105_model = OpenJFEM.bdf_to_model(sol105_deck)
    sol105_model["backend"] = "tacs_formulation"

    sol103_results = OpenJFEM.solve_model(sol103_model)
    sol105_results = OpenJFEM.solve_model(sol105_model)
    @test sol103_results["backend"] == "tacs_formulation"
    @test sol105_results["backend"] == "tacs_formulation"
    @test sol103_results["sol_type"] == 103
    @test sol105_results["sol_type"] == 105

    modal_checks = _check_modal(sol103_results)
    buckling_checks = _check_buckling(sol105_results)

    println("TACS PCOMP eigen ply sensitivity check passed")
    println("  workdir = ", abspath(tmp))
    for (label, checks) in (("SOL103", modal_checks), ("SOL105", buckling_checks))
        for (dv_id, values) in sort(collect(checks); by=first)
            fd, hook, relerr = values
            println("  ", label, " ", dv_id, " FD = ", fd, " hook = ", hook, " relerr = ", relerr)
        end
    end
    return true
end

exit(main() ? 0 : 1)
