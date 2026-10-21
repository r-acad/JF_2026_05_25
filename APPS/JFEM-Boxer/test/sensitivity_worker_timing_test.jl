using Test,JSON,OpenJFEM
include(joinpath(@__DIR__,"..","src","sensitivity_worker_core.jl"))
length(ARGS)<=1 || error("Usage: sensitivity_worker_timing_test.jl [fixture.json] (run under the containing solver project)")
@testset "Sensitivity bootstrap and measured timing contract" begin
    mktempdir() do dir
        worker=JFEMSensitivityWorker
        worker.reset_worker!(dir,dirname(dirname(dirname(@__DIR__))))
        Base.invokelatest() do
        for (phase,category) in (("bootstrap","preparation"),("baseline_parse","preparation"),
                ("forward","numerical"),("adjoint","numerical"),("operators","numerical"),
                ("analytic_derivatives","numerical"),("baseline_export","export"),("future_unknown","preparation"))
            worker.progress(Dict("phase"=>phase,"detail"=>phase))
            p=JSON.parsefile(joinpath(dir,"progress.json"))
            @test p["stage_category"]==category
            @test p["compilation_live"]=="not_separable"
        end
        @test worker.measured_worker_stage(()->42,"generator_load")==42
        measured=worker.WORKER_TIMINGS["generator_load"]
        @test measured["seconds"]==measured["wall_seconds"]
        @test measured["compile_seconds"]==measured["compilation_seconds"]
        @test measured["execution_seconds"]===nothing || measured["execution_seconds"]+measured["compilation_seconds"]≈measured["wall_seconds"]
        @test measured["category"]=="preparation"
        result=worker.measured_native_baseline(OpenJFEM) do
            OpenJFEM._pipeline_detail_measure!("assembly","Synthetic helper assembly") do
                Dict("timings"=>Dict("assembly_K"=>0.))
            end
        end
        @test result["timings"]["assembly_K"]==0.
        baseline=worker.WORKER_TIMINGS["baseline_analysis"]
        native=worker.WORKER_TIMINGS["native_analysis"]
        @test baseline["category"]=="numerical"
        @test baseline["wall_seconds"]==native["measured_wall_seconds"]
        @test length(native["stages"])==2
        @test sum(r["exclusive"]["wall_seconds"] for r in native["stages"])≈baseline["wall_seconds"]
        worker.store_worker_stage("overlap",Dict("wall_seconds"=>1.,"compilation_seconds"=>2.,
            "recompilation_seconds"=>.1,"execution_seconds"=>nothing,"gc_seconds"=>0.))
        @test worker.WORKER_TIMINGS["overlap"]["execution_seconds"]===nothing
        worker.progress(Dict("phase"=>"complete","detail"=>"Timing helper regression complete",
            "timings_seconds"=>Dict("adjoint_setup_and_solve"=>.1)))
        complete=JSON.parsefile(joinpath(dir,"progress.json"))
        @test complete["stage_state"]=="completed"
        @test complete["timings_seconds"]["adjoint_setup_and_solve"]==.1
        @test occursin("inclusive wall",complete["timing_scope"])
        if !isempty(ARGS)
            mkpath(dirname(abspath(ARGS[1])))
            write(ARGS[1],JSON.json(Dict("origin"=>"Measured timing helper regression; no sensitivity model solve.","sensitivity"=>complete),2))
        end
        end
    end
end
