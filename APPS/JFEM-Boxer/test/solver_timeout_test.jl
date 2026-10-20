# julia --project=. APPS/JFEM-Boxer/test/solver_timeout_test.jl OUTPUT
using Test, WingFEGen, OpenJFEM
const W=WingFEGen
const OUTPUT=abspath(only(ARGS));mkpath(OUTPUT)
const APP=dirname(@__DIR__)
const REPO=normpath(joinpath(APP,"..",".."))
const DECK=joinpath(REPO,"utils","examples","precompile","sol101_adjoint_shell.bdf")
const SOURCE=W.imported_source(Dict("name"=>basename(DECK),"text"=>read(DECK,String)))
const MODEL=W.imported_model(OpenJFEM.bdf_to_model(DECK),SOURCE,W.default_params())
with_timeout(minutes)=W.Model((field===:params ? merge(MODEL.params,Dict("jfem.timeout_minutes"=>minutes,"jfem.output_dir"=>OUTPUT)) :
    getfield(MODEL,field) for field in fieldnames(W.Model))...)

@testset "Optional FE and sensitivity timeouts" begin
    @test W.default_params()["jfem.timeout_minutes"]==0
    @test W.read_input(joinpath(APP,"examples","wing_default.toml"))["jfem.timeout_minutes"]==0
    for minutes in (0,30,240)
        params,_=W.normalize_params(Dict("jfem.timeout_minutes"=>minutes))
        @test W.solver_timeout_seconds(params)==60minutes
        path=joinpath(OUTPUT,"timeout_$minutes.toml")
        write(path,W.params_to_toml(params))
        @test W.read_input(path)["jfem.timeout_minutes"]==minutes
    end
    for value in (-1,Inf,NaN,true)
        @test_throws ArgumentError W.solver_timeout_seconds(Dict("jfem.timeout_minutes"=>value))
    end
    @test_throws ArgumentError W.normalize_params(Dict("jfem.timeout_minutes"=>-1))

    # Apply a runtime choice to an imported request without altering the cached
    # authoritative model, source, or another request's settings.
    token="timeout-regression"
    lock(W.IMPORTED_MODELS_LOCK) do;W.IMPORTED_MODELS[token]=MODEL;end
    try
        for minutes in (0,240)
            request=Dict("parameters"=>Dict("model_kind"=>"reference","jfem.timeout_minutes"=>minutes,
                "imported_deck"=>Dict("token"=>token,"signature"=>SOURCE["signature"])))
            applied=W.request_imported_model(request)
            @test applied.params["jfem.timeout_minutes"]==minutes
            @test MODEL.params["jfem.timeout_minutes"]==0
            @test applied.node_ids===MODEL.node_ids
        end
        @test_throws ArgumentError W.request_imported_model(Dict("jfem.timeout_minutes"=>-1,
            "imported_deck"=>Dict("token"=>token)))
    finally
        lock(W.IMPORTED_MODELS_LOCK) do;delete!(W.IMPORTED_MODELS,token);end
    end

    for minutes in (0,240)
        model=with_timeout(minutes)
        job=W.prepare_jfem_job(model,model.params,APP,DECK,"fe_timeout_$minutes")
        job.state=:running;job.started=time()
        W.enforce_job_timeout!(job;now=job.started+121*60)
        @test job.state===:running
        W.enforce_job_timeout!(job;now=job.started+24*60*60)
        @test job.state===(minutes==0 ? :running : :failed)
        minutes==0&&W.kill_job!(job)
    end

    # Check actual owned worker termination, without waiting hours or running a
    # numerical solve. The same monitor is called by start_sensitivity_job.
    for minutes in (0,240)
        model=with_timeout(minutes)
        proc=run(pipeline(`$(Base.julia_cmd()) --startup-file=no -e 'sleep(60)'`;stdout=devnull,stderr=devnull);wait=false)
        job=W.SensitivityJob("sensitivity_timeout_$minutes",OUTPUT,proc,time(),nothing,:running,"",model,
            Dict{String,Any}(),ReentrantLock())
        try
            W.enforce_sensitivity_timeout!(job;now=job.started+121*60)
            @test job.state===:running && process_running(proc)
            W.enforce_sensitivity_timeout!(job;now=job.started+24*60*60)
            @test job.state===(minutes==0 ? :running : :failed)
            minutes==0&&W.cancel_sensitivity_job!(job)
            try wait(proc) catch end
            @test !process_running(proc)
            @test job.state===(minutes==0 ? :cancelled : :failed)
        finally
            process_running(proc)&&kill(proc)
            try wait(proc) catch end
        end
    end
end
