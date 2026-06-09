# Guard for public TACS eigen-mode continuation helpers.
#
# Usage:
#   julia --project=. tools/testing/tacs_mode_continuation_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_panel_deck(path::AbstractString, sol::Integer)
    sol in (103, 105) || error("Mode-continuation guard only writes SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS SOL", sol, " mode-continuation guard")
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

function _check_continuation(results::AbstractDict, family::Symbol, gradient_hook::Function)
    dv = _thickness_dv(results)
    dv_id = string(dv["id"])

    direct_mode2 = gradient_hook(results, [dv]; mode=2)
    previous_state = OpenJFEM.eigen_mode_tracking_reference(
        results;
        mode=2,
        analysis_family=family,
        candidate_modes=[1, 2],
        minimum_mac=0.5,
    )
    next_state, continuation_diag = OpenJFEM.eigen_mode_continuation_update(
        results,
        previous_state;
        mode=1,
        analysis_family=family,
        candidate_modes=[1, 2],
        minimum_mac=0.5,
    )
    continued = gradient_hook(
        results,
        [dv];
        mode=1,
        mode_tracking=next_state,
    )

    @test previous_state["continuation"] == "previous_solve_mac"
    @test previous_state["reference_mode_index"] == 2
    @test continuation_diag["continuation"] == "previous_solve_mac"
    @test continuation_diag["analysis_family"] == string(family)
    @test continuation_diag["requested_mode"] == 1
    @test continuation_diag["selected_mode"] == 2
    @test Float64(continuation_diag["selected_mac"]) > 0.99
    @test continued["requested_mode"] == 1
    @test continued["mode"] == 2
    @test continued["mode_tracking"]["method"] == "mac"
    @test continued["mode_tracking"]["reference_mode_index"] == 2
    @test isapprox(
        Float64(continued["gradient"][dv_id]),
        Float64(direct_mode2["gradient"][dv_id]);
        rtol=1e-11,
        atol=1e-8,
    )
    return continuation_diag, continued
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_mode_continuation_")
    modal_results = _solve(_write_panel_deck(joinpath(tmp, "mode_continuation_sol103.bdf"), 103))
    buckling_results = _solve(_write_panel_deck(joinpath(tmp, "mode_continuation_sol105.bdf"), 105))

    @test modal_results["backend"] == "tacs_formulation"
    @test buckling_results["backend"] == "tacs_formulation"
    @test modal_results["sol_type"] == 103
    @test buckling_results["sol_type"] == 105
    @test length(modal_results["eigenvalues"]) >= 2
    @test length(buckling_results["eigenvalues"]) >= 2

    modal_diag, modal_continued = _check_continuation(
        modal_results,
        :modal,
        OpenJFEM.modal_eigenvalue_design_gradient,
    )
    buckling_diag, buckling_continued = _check_continuation(
        buckling_results,
        :buckling,
        OpenJFEM.buckling_load_factor_design_gradient,
    )

    println("TACS mode-continuation guard passed")
    println("  workdir = ", abspath(tmp))
    println("  modal selected mode    = ", modal_continued["mode"])
    println("  modal selected MAC     = ", modal_diag["selected_mac"])
    println("  buckling selected mode = ", buckling_continued["mode"])
    println("  buckling selected MAC  = ", buckling_diag["selected_mac"])
    return true
end

exit(main() ? 0 : 1)
