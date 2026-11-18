using Test,JSON,OpenJFEM,WingFEGen
const JFEMSensitivityWorker=WingFEGen.JFEMSensitivityWorker
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

@testset "Sizing gradient and actual adjoint work are retained in the main log" begin
    mktempdir() do dir
        worker=JFEMSensitivityWorker
        worker.reset_worker!(dir,dirname(dirname(dirname(@__DIR__))))
        report=(event;kwargs...)->WingFEGen.rf_optimization_gradient_progress(worker.progress,event;
            case_count=2,design_variable_count=3,physical_dimension_count=4,kwargs...)
        report(:preparation)
        report(:mass_ready)
        report(:weights;active_constraint_count=0)
        report(:weights;active_constraint_count=5)
        report(:adjoint_ready;active_constraint_count=5,adjoint_rhs=2)
        state=JSON.parsefile(joinpath(dir,"progress.json"))
        events=state["log_events"]
        @test length(events)==5
        @test [event["sequence"] for event in events]==collect(1:5)
        @test all(event["case_count"]==2&&event["design_variable_count"]==3&&event["physical_dimension_count"]==4 for event in events)
        @test events[1]["event"]=="gradient_preparation"&&occursin("Preparing sizing gradients",events[1]["message"])
        @test events[2]["event"]=="mass_gradient_ready"
        @test events[3]["event"]=="mass_gradient_only"
        @test events[3]["active_constraint_count"]==0
        @test occursin("Current RF adjoint weights are zero; this step uses the structural mass gradient",events[3]["message"])&&occursin("No RF adjoint RHS is required",events[3]["message"])
        @test !occursin("solved",events[3]["message"])&&!haskey(events[3],"adjoint_rhs")
        @test events[4]["phase"]=="adjoint"&&events[4]["active_constraint_count"]==5
        @test events[5]["event"]=="adjoint_gradient_ready"&&events[5]["adjoint_rhs"]==2
        @test occursin("2 adjoint right-hand side(s) solved",events[5]["message"])
        @test worker.worker_stage_category("gradient")=="numerical"
        @test state["stage_category"]=="numerical"
    end
end

@testset "Optimization logs survive polling and reset between worker requests" begin
    mktempdir() do dir
        worker=JFEMSensitivityWorker
        worker.reset_worker!(dir,dirname(dirname(dirname(@__DIR__))))
        worker.progress(Dict("phase"=>"optimization","event"=>"start","log_message"=>"Starting sizing across two cases"))
        first_state=JSON.parsefile(joinpath(dir,"progress.json"))
        @test only(first_state["log_events"])["sequence"]==1
        @test only(first_state["log_events"])["message"]=="Starting sizing across two cases"
        @test !haskey(worker.LAST_PROGRESS[],"log_message")
        worker.progress(merge(worker.LAST_PROGRESS[],Dict("phase"=>"forward","detail"=>"Reading deck")))
        @test worker.WORKER_LOG_SEQUENCE[]==1
        for index in 1:260
            worker.record_worker_log_event!(Dict("iteration"=>index),"optimization","Iteration $index")
        end
        worker.progress(Dict("phase"=>"optimization","detail"=>"Current sizing state"))
        retained=JSON.parsefile(joinpath(dir,"progress.json"))["log_events"]
        @test length(retained)==250
        @test first(retained)["sequence"]==12
        @test last(retained)["sequence"]==261
        @test last(retained)["iteration"]==260
        worker.reset_worker!(dir,dirname(dirname(dirname(@__DIR__))))
        worker.progress(Dict("phase"=>"bootstrap","detail"=>"Next request"))
        @test !haskey(JSON.parsefile(joinpath(dir,"progress.json")),"log_events")
        @test worker.WORKER_LOG_SEQUENCE[]==0
        worker.progress(Dict("phase"=>"optimization","log_message"=>"Next sizing request"))
        @test only(JSON.parsefile(joinpath(dir,"progress.json"))["log_events"])["sequence"]==1
    end
end
