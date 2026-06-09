# Smoke check for SOL200-lite KS displacement constraints on the TACS backend.
#
# The DRESP1 KSDISP route maps ATTA to the first grid, ATTB to the component,
# and ATTI to any additional grids included in the KS smooth maximum.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol200_ks_displacement_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_ks_displacement_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL200 KS displacement route check")
        println(io, "DESOBJ(MIN) = 2")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
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
        println(io, "FORCE,1,2,0,25.,0.,0.,1.")
        println(io, "FORCE,1,3,0,25.,0.,0.,1.")
        println(io, "DESVAR,1,TKS,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,KUZ,KSDISP,,,2,3,3")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,1,,1.0E-3")
        println(io, "DOPTPRM,DESMAX,2,CONV1,1.0E-6,DELX,0.2,KSRHO,5000.")
        println(io, "ENDDATA")
    end
    return path
end

function _check_ks_displacement_route(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    opt = model["OPTIMIZATION"]
    families = sort!(string.(get.(opt["responses"], "candidate_response_family", nothing)))
    @test families == ["ks_displacement", "mass"]
    @test opt["responses"][1]["candidate_response_family"] == "ks_displacement"
    @test "ks_displacement" in opt["sol200_lite_readiness"]["supported_execution_response_families"]
    @test isempty(opt["sol200_lite_readiness"]["parsed_but_unexecuted_response_ids"])

    response = opt["responses"][1]
    @test response["atta"] == 2
    @test response["attb"] == 3
    @test Int.(response["atti"]) == [3]

    results = OpenJFEM.solve_model(model)

    @test results["sol_type"] == 200
    @test results["backend"] == "tacs_formulation"
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_mass_static_response"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["route_summary"]["constraint_response_family"] == "ks_displacement"
    @test results["route_summary"]["constraint_grids"] == [2, 3]
    @test results["route_summary"]["constraint_dof"] == 3
    @test results["route_summary"]["constraint_ks_rho"] == 5000.0
    @test results["route_summary"]["constraint_displacement_ref"] == 1.0
    @test results["forward_results"]["sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"

    opt_result = results["optimization"]
    @test opt_result["response_family"] == "ks_displacement"
    @test Float64(opt_result["response_upper_bound"]) == 1.0e-3
    @test Float64(opt_result["response_value"]) <= 1.0e-3 * (1.0 + 1e-8)
    @test Float64(opt_result["final_mass"]) > 0.0

    iterations = opt_result["iterations"]
    @test !isempty(iterations)
    diagnostics = iterations[end]["solver_diagnostics"]
    @test diagnostics["backend"] == "tacs_formulation"
    @test diagnostics["sensitivity"]["response"] == "ks_displacement"
    @test diagnostics["sensitivity"]["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test diagnostics["sensitivity"]["design_variable_type"] == "mixed"
    @test diagnostics["sensitivity"]["ks_rho"] == 5000.0
    @test diagnostics["sensitivity"]["displacement_ref"] == 1.0
    return results, diagnostics
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol200_ks_disp_")
    deck = _write_ks_displacement_sol200_deck(joinpath(tmp, "tacs_ks_displacement_sol200_route.bdf"))
    results, diagnostics = _check_ks_displacement_route(deck)
    println("TACS SOL200 KS displacement route check passed")
    println("  deck                 = ", abspath(deck))
    println("  objective            = ", results["route_summary"]["translated_objective"])
    println("  response family      = ", results["optimization"]["response_family"])
    println("  response value       = ", results["optimization"]["response_value"])
    println("  sensitivity backend  = ", diagnostics["sensitivity"]["gradient_backend"])
    return true
end

exit(main() ? 0 : 1)
