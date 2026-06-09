# Guard for SOL103/SOL105 TACS eigen-gradient mode tracking and cluster policy.
#
# Usage:
#   julia --project=. tools/testing/tacs_mode_tracking_policy_check.jl

using Statistics
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_panel_deck(path::AbstractString, sol::Integer)
    sol in (103, 105) || error("Mode-tracking guard only writes SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS SOL", sol, " mode-tracking policy guard")
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
        println(io, "GRID,3,,2.,0.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "GRID,5,,1.,1.,0.")
        println(io, "GRID,6,,2.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,2,2,3,6,5")
        println(io, "PSHELL,1,1,0.018")
        println(io, "PSHELL,2,1,0.024")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        if sol == 105
            println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
            println(io, "FORCE,1,6,0,-1000.,1.,0.,0.")
        end
        println(io, "EIGRL,1,0.,1.0E9,2")
        println(io, "ENDDATA")
    end
    return path
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _thickness_dv(results::AbstractDict)
    t0 = Float64(results["model"]["PSHELLs"]["1"]["T"])
    return Dict{String,Any}(
        "id" => "t_pid1",
        "type" => "shell_thickness",
        "pids" => [1],
        "step" => max(1e-5 * t0, 1e-7),
    )
end

function _check_tracked_response(response::AbstractDict, direct::AbstractDict, dv_id::AbstractString)
    @test response["requested_mode"] == 1
    @test response["mode"] == 2
    @test response["mode_tracking"]["method"] == "mac"
    @test response["mode_tracking"]["selected_mode"] == 2
    @test response["mode_tracking"]["requested_mode"] == 1
    @test Float64(response["value"]) == Float64(direct["value"])
    @test isapprox(
        Float64(response["gradient"][dv_id]),
        Float64(direct["gradient"][dv_id]);
        rtol=1e-11,
        atol=1e-8,
    )
end

function _check_cluster_policy_response(response::AbstractDict, dv_id::AbstractString, diagnostic_key::AbstractString)
    @test response["cluster_detected"] == true
    @test response["cluster_policy"] == "mean"
    @test response["eigen_derivative"] == "cluster_policy_projected_derivative"
    cluster_values = Float64.(response["cluster_gradient_eigenvalues"][dv_id])
    @test length(cluster_values) > 1
    @test isapprox(Float64(response["gradient"][dv_id]), mean(cluster_values); rtol=1e-12, atol=1e-8)
    diagnostics = response["design_variable_diagnostics"][dv_id]
    @test diagnostics["cluster_policy"] == "mean"
    @test isapprox(Float64(diagnostics["selected_eigen_derivative"]), mean(cluster_values); rtol=1e-12, atol=1e-8)
    @test Float64.(diagnostics[diagnostic_key]) == cluster_values
end

function _check_modal(results::AbstractDict)
    dv = _thickness_dv(results)
    dv_id = string(dv["id"])
    modes = OpenJFEM._tacs_tracking_mode_matrix(results, :modal)
    @test size(modes, 2) >= 2
    reference = Vector{Float64}(modes[:, 2])
    direct = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=2)
    tracked = OpenJFEM.modal_eigenvalue_design_gradient(
        results,
        [dv];
        mode=1,
        mode_tracking=Dict{String,Any}(
            "method" => "mac",
            "reference_mode" => reference,
            "candidate_modes" => [1, 2],
        ),
    )
    _check_tracked_response(tracked, direct, dv_id)

    clustered = OpenJFEM.modal_eigenvalue_design_gradient(
        results,
        [dv];
        mode=1,
        cluster_policy=:mean,
        cluster_rel_tol=Inf,
    )
    _check_cluster_policy_response(clustered, dv_id, "cluster_eigenvalue_derivatives")
    return tracked, clustered
end

function _check_buckling(results::AbstractDict)
    dv = _thickness_dv(results)
    dv_id = string(dv["id"])
    modes = OpenJFEM._tacs_tracking_mode_matrix(results, :buckling)
    @test size(modes, 2) >= 2
    reference = Vector{Float64}(modes[:, 2])
    direct = OpenJFEM.buckling_load_factor_design_gradient(results, [dv]; mode=2)
    tracked = OpenJFEM.buckling_load_factor_design_gradient(
        results,
        [dv];
        mode=1,
        mode_tracking=Dict{String,Any}(
            "method" => "mac",
            "reference_mode" => reference,
            "candidate_modes" => [1, 2],
        ),
    )
    _check_tracked_response(tracked, direct, dv_id)

    clustered = OpenJFEM.buckling_load_factor_design_gradient(
        results,
        [dv];
        mode=1,
        cluster_policy=:mean,
        cluster_rel_tol=Inf,
    )
    _check_cluster_policy_response(clustered, dv_id, "cluster_load_factor_derivatives")
    return tracked, clustered
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_mode_tracking_")
    sol103 = _write_panel_deck(joinpath(tmp, "mode_tracking_sol103.bdf"), 103)
    sol105 = _write_panel_deck(joinpath(tmp, "mode_tracking_sol105.bdf"), 105)
    modal_results = _solve(sol103)
    buckling_results = _solve(sol105)

    @test modal_results["backend"] == "tacs_formulation"
    @test buckling_results["backend"] == "tacs_formulation"
    @test modal_results["sol_type"] == 103
    @test buckling_results["sol_type"] == 105

    modal_tracked, modal_clustered = _check_modal(modal_results)
    buckling_tracked, buckling_clustered = _check_buckling(buckling_results)

    println("TACS mode-tracking and cluster-policy guard passed")
    println("  workdir = ", abspath(tmp))
    println("  modal tracked mode       = ", modal_tracked["mode"])
    println("  modal cluster policy     = ", modal_clustered["cluster_policy"])
    println("  buckling tracked mode    = ", buckling_tracked["mode"])
    println("  buckling cluster policy  = ", buckling_clustered["cluster_policy"])
    return true
end

exit(main() ? 0 : 1)
