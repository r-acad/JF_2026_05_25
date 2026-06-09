# Smoke check for SOL200-lite smooth-min buckling aggregation on TACS backend.
#
# SOL200 buckling keeps first-mode sizing by default. A deck can opt into the
# guarded smooth-min multimode buckling gradient by providing DOPTPRM,KSRHO.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol200_buckling_ks_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_buckling_ks_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 buckling KS route check")
        println(io, "DESOBJ(MAX) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
        println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "DESVAR,1,TBUCK,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,LAM,LAMA")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,100.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2,KSRHO,0.01")
        println(io, "DOPTPRM,BUCKM1,1,BUCKM2,2,BUCKPOL,MEAN")
        println(io, "ENDDATA")
    end
    return path
end

function _write_buckling_mode_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 buckling selected-mode route check")
        println(io, "DESOBJ(MAX) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
        println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "DESVAR,1,TBUCK,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,LAM,LAMA")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,100.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2,BUCKMODE,2")
        println(io, "DOPTPRM,BUCKPOL,MAX,BUCKTRK,1,BUCKWIN,1")
        println(io, "DOPTPRM,BUCKMAC,0.0")
        println(io, "ENDDATA")
    end
    return path
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol200_buckling_ks_")
    deck = _write_buckling_ks_sol200_deck(joinpath(tmp, "buckling_ks_sol200.bdf"))
    selected_mode_deck = _write_buckling_mode_sol200_deck(joinpath(tmp, "buckling_mode_sol200.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    selected_mode_model = OpenJFEM.bdf_to_model(selected_mode_deck)
    selected_mode_model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    selected_mode_results = OpenJFEM.solve_model(selected_mode_model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["route_summary"]["translated_objective"] == "max_buckling"
    @test results["route_summary"]["buckling_aggregation"] == "smooth_min_load_factor"
    @test results["route_summary"]["buckling_aggregation_opt_in"] == "DOPTPRM_KSRHO"
    @test results["route_summary"]["buckling_ks_rho"] == 0.01
    @test results["route_summary"]["buckling_modes"] == [1, 2]
    @test results["route_summary"]["buckling_mode_selection"] == "DOPTPRM_BUCKM"
    @test results["route_summary"]["buckling_cluster_policy"] == "mean"
    @test results["forward_results"]["sol_type"] == 105
    @test results["forward_results"]["backend"] == "tacs_formulation"
    @test !isempty(results["forward_results"]["eigenvalues"])

    iterations = results["optimization"]["iterations"]
    @test length(iterations) == 1
    iter = iterations[1]
    @test iter["buckling_aggregation"] == "smooth_min_load_factor"
    @test iter["buckling_ks_rho"] == 0.01
    diagnostics = iter["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    sensitivity = diagnostics["sensitivity"]
    @test sensitivity["response"] == "buckling_ks_load_factor"
    @test sensitivity["aggregation"] == "smooth_min_load_factor"
    @test sensitivity["rho"] == 0.01
    @test sensitivity["gradient_backend"] == "tacs_formulation_buckling_ks_weighted_rayleigh"
    @test sensitivity["modes"] == [1, 2]
    @test length(keys(sensitivity["mode_weights"])) == length(sensitivity["modes"])
    @test Float64(sensitivity["mode_weights"]["2"]) > 0.0
    @test sensitivity["cluster_policy"] == "mean"
    @test isfinite(Float64(iter["objective"]))

    @test selected_mode_results["sol_type"] == 200
    @test selected_mode_results["backend"] == "tacs_formulation"
    @test selected_mode_results["route_summary"]["translated_objective"] == "max_buckling"
    @test selected_mode_results["route_summary"]["buckling_aggregation"] == "first_mode"
    @test selected_mode_results["route_summary"]["buckling_mode"] == 2
    @test selected_mode_results["route_summary"]["buckling_mode_selection"] == "DOPTPRM_BUCKMODE"
    @test selected_mode_results["route_summary"]["buckling_cluster_policy"] == "max"
    @test selected_mode_results["route_summary"]["buckling_mode_tracking"] == "previous_solve_mac"
    @test selected_mode_results["route_summary"]["buckling_mode_tracking_candidate_window"] == 1
    selected_iter = selected_mode_results["optimization"]["iterations"][1]
    selected_sensitivity = selected_iter["solver_diagnostics"]["sensitivity"]
    @test selected_iter["buckling_mode"] == 2
    @test selected_iter["buckling_cluster_policy"] == "max"
    @test selected_iter["buckling_mode_tracking"]["method"] == "mac"
    @test selected_iter["buckling_mode_tracking"]["state_initialized"] == true
    @test selected_iter["buckling_mode_tracking"]["selected_mode"] == 2
    @test selected_sensitivity["response"] == "buckling_load_factor"
    @test selected_sensitivity["requested_mode"] == 2
    @test selected_sensitivity["mode"] == 2
    @test selected_sensitivity["cluster_policy"] == "max"
    @test isapprox(
        Float64(selected_iter["objective"]),
        Float64(selected_mode_results["forward_results"]["eigenvalues"][2]);
        rtol=1e-12,
        atol=1e-8,
    )

    println("TACS SOL200 buckling KS route check passed")
    println("  deck                  = ", abspath(deck))
    println("  selected mode deck    = ", abspath(selected_mode_deck))
    println("  aggregation           = ", results["route_summary"]["buckling_aggregation"])
    println("  ks rho                = ", results["route_summary"]["buckling_ks_rho"])
    println("  ks modes              = ", results["route_summary"]["buckling_modes"])
    println("  objective             = ", iter["objective"])
    println("  sensitivity backend   = ", sensitivity["gradient_backend"])
    println("  selected objective    = ", selected_iter["objective"])
    println("  selected mode         = ", selected_sensitivity["mode"])
    println("  mode weights          = ", sensitivity["mode_weights"])
end

main()
