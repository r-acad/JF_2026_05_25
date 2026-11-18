using Test, JSON
# Runs the actual image workload in the shared package environment. No custom
# image or subprocess is needed; all workload outputs live in mktempdir scopes.
records=include(joinpath(@__DIR__,"..","julia_tools","sensitivity_precompile_workload.jl"))
checks=@testset "Shared image warms scalar and RF sensitivity paths" begin
    @test Set(row["kind"] for row in records)==Set(["imported","generated","rf"])
    @test all(row->row["status"]=="complete"&&row["finite_derivatives"],records)
    generated=only(filter(row->row["kind"]=="generated",records))
    @test generated["variables"]==6
    @test generated["has_shells"]&&generated["has_bars"]
    @test generated["solver_counts"]["forward_solves"]==1
    @test generated["solver_counts"]["perturbed_forward_solves"]==0
    rf=only(filter(row->row["kind"]=="rf",records))
    @test rf["has_shells"]&&rf["has_bars"]&&rf["structural_inertia"]
    @test rf["native_report_json"]&&rf["production_worker_entry"]
    @test rf["sol106_consistent_residual"]&&rf["sol106_method"]=="legacy_geometric"
    @test Set(rf["follower_derivatives_rejected_before_solve"])==Set(["101","106"])
    @test rf["child_processes"]==0&&rf["temporary_outputs"]
    @test Set(row["operation"] for row in rf["operations"])==Set(["jacobian","jvp","vjp","directional","optimize"])
    @test all(row->row["complete"]&&row["finite_derivatives"]&&row["production_worker_entry"],rf["operations"])
    @test only(filter(row->row["operation"]=="optimize",rf["operations"]))["independent_final_verification"]
    @test "von_mises" in rf["failure_modes"]
    @test any(id->occursin("#upper:",id)&&endswith(id,"#skin#thickness"),rf["variable_ids"])
    @test "material.E" in rf["variable_ids"]
    worker=WingFEGen.JFEMSensitivityWorker
    @test parentmodule(worker)===WingFEGen
    @test worker.GENERATOR_MODULE===WingFEGen
    @test worker.NATIVE_MODULE[]===nothing
    @test worker.DIRECTORY[]==""&&worker.REPOSITORY[]==""
end
if !isempty(ARGS)
    out=abspath(only(ARGS));mkpath(out)
    write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"records"=>records)))
end
