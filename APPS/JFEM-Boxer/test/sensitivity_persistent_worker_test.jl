# julia --project=. --threads=4 APPS/JFEM-Boxer/test/sensitivity_persistent_worker_test.jl OUTPUT
# Real IPC lifecycle regression; the worker deliberately supplies synthetic data.
# Numerical repeated-run validation uses the unchanged compute_sensitivity path.
using Test,WingFEGen,OpenJFEM,JSON
const W=WingFEGen
length(ARGS)==1||error("Expected an evidence output directory")
const OUTPUT=abspath(ARGS[1]);mkpath(OUTPUT)
const REPO=dirname(Base.active_project());const APP=joinpath(REPO,"APPS","JFEM-Boxer")
const DECK=joinpath(REPO,"utils","examples","precompile","sol101_adjoint_shell.bdf")
const PARAMS=merge(W.default_params(),Dict("jfem.output_dir"=>OUTPUT,"jfem.timeout_minutes"=>0.,"jfem.output_formats"=>"s"))
const MODEL=W.imported_model(OpenJFEM.bdf_to_model(DECK),W.imported_source(Dict("name"=>basename(DECK),"text"=>read(DECK,String))),PARAMS)
const REQUEST=Dict("solution"=>"101","case_id"=>1,"variables"=>["reference.MAT1#1#E"],
    "objective"=>Dict("type"=>"displacement","node_id"=>3,"component"=>"z"),"derivative_method"=>"analytic")
const SCRIPT=joinpath(OUTPUT,"controlled_sensitivity_worker.jl")
write(SCRIPT,raw"""
using JSON
reply(data)=(println("[JFEM_WORKER] ",JSON.json(data));flush(stdout))
reply(Dict("status"=>"ready","runtime"=>Dict("session_id"=>"controlled-$(getpid())","pid"=>getpid())))
for line in eachline(stdin)
    request=JSON.parse(line);get(request,"command","")=="quit"&&break
    output=request["outdir"];sensitivity=request["command"]=="sensitivity"
    action=sensitivity ? read(joinpath(output,"test_action.txt"),String) : split(basename(request["bdf"]),'.')[1]
    write(joinpath(output,"entered.json"),JSON.json(Dict("pid"=>getpid(),"action"=>action)))
    open(joinpath(output,"solver_stdout.log"),"w") do log
        println(log,"Controlled ",request["command"]," ",action);flush(log)
        action=="hold"&&sleep(60)
        action=="crash"&&exit(7)
    end
    failure=action=="failure"
    if sensitivity
        file=failure ? "error.json" : "result.json"
        payload=failure ? Dict("message"=>"Controlled numerical failure") : Dict("status"=>"complete","rows"=>Any[])
        write(joinpath(output,file),JSON.json(payload))
    else
        write(joinpath(output,"controlled.JU.JSON"),JSON.json(Dict("analysis_type"=>"SOL101_STATIC","displacements"=>Any[])))
    end
    reply(Dict("id"=>request["id"],"status"=>failure ? "failed" : "done","exit_code"=>failure ? 1 : 0,
        "message"=>failure ? "Controlled numerical failure" : ""))
end
""")
factory(job,signature)=W.create_solver_worker(job,signature;script=SCRIPT)
function until(predicate;seconds=120.)
    timedwait(predicate,seconds;pollint=.05)===:ok||error("Owned lifecycle test timed out")
end
function await_job(job)
    until(()->job.state!==:running&&job.worker_job.log_done)
    job
end
function sens(action="ok";timeout=0.)
    model=deepcopy(MODEL);model.params["jfem.timeout_minutes"]=timeout
    # Do not add fake settings to the validated production request. Hold worker
    # admission only long enough to publish the controlled worker's sidecar.
    lock(W.SOLVER_WORKER_LOCK) do
        job=W.start_sensitivity_job(model,REQUEST,APP,action;worker_factory=factory)
        write(joinpath(job.outdir,"test_action.txt"),action)
        job
    end
end
function ordinary(action="ok")
    deck=joinpath(OUTPUT,action*".bdf");cp(DECK,deck;force=true)
    job=W.prepare_jfem_job(MODEL,PARAMS,APP,deck,action)
    W.launch_jfem_process!(job;worker_factory=factory)
end
entered(job)=isfile(joinpath(job.outdir,"entered.json"))
suite=@testset "Sensitivity shares the FE worker lifecycle" begin
    try
        first=await_job(sens());@test first.state===:done
        second=await_job(sens());@test second.state===:done
        @test first.proc===second.proc
        @test second.worker_job.progress["worker_reused"]
        @test process_running(second.proc)
        normal=ordinary();until(()->normal.state!==:running&&normal.log_done)
        @test normal.state===:done
        @test normal.proc===second.proc
        again=await_job(sens());@test again.proc===normal.proc
        @test again.state===:done
        W.cancel_sensitivity_job!(first)
        @test first.state===:done && process_running(again.proc)
        failed=await_job(sens("failure"));@test failed.state===:failed
        @test failed.message=="Controlled numerical failure"
        @test failed.proc===again.proc && process_running(failed.proc)
        recovered=await_job(sens());@test recovered.state===:done
        @test recovered.proc===failed.proc

        active=ordinary("hold");until(()->entered(active))
        queued=sens();@test queued.worker_job.proc===nothing
        W.cancel_sensitivity_job!(queued)
        @test queued.state===:cancelled
        @test process_running(active.proc)
        @test !entered(queued)
        W.kill_job!(active);until(()->active.log_done);await_job(queued)
        @test !process_running(active.proc)
        restarted=await_job(sens());@test restarted.state===:done
        @test restarted.proc!==active.proc
        held=sens("hold");until(()->entered(held))
        W.cancel_sensitivity_job!(held);await_job(held)
        @test held.state===:cancelled
        @test !process_running(held.proc)
        restored=await_job(sens());@test restored.state===:done
        @test restored.proc!==held.proc

        crash=await_job(sens("crash"));@test crash.state===:failed
        @test occursin("Persistent solver request failed",crash.message)
        @test !process_running(crash.proc)
        fresh=await_job(sens());@test fresh.state===:done
        @test fresh.proc!==crash.proc
        withenv("JFEM_KRYLOVKIT_THREADS"=>"2") do
            changed=await_job(sens());@test changed.state===:done
            @test changed.proc!==fresh.proc
            @test !process_running(fresh.proc)
        end
        timeout=await_job(sens("hold";timeout=.025))
        @test timeout.state===:failed
        @test occursin("timeout",timeout.message)
        @test timeout.proc===nothing||!process_running(timeout.proc)

        closing=sens("hold");until(()->entered(closing))
        pending=sens()
        W.shutdown_solver_worker!(closing=true);await_job(closing);await_job(pending)
        @test closing.state===:cancelled && pending.state===:cancelled
        @test !process_running(closing.proc)
        rejected=await_job(sens());@test rejected.state===:failed
        @test occursin("closing",rejected.message)
        @test rejected.proc===nothing
        @test isempty(W.SOLVER_PENDING_JOBS)
        W.start_solver_worker_service!()
        final=await_job(sens());@test final.state===:done
    finally
        W.shutdown_solver_worker!()
    end
end
counts=Test.get_test_counts(suite)
write(joinpath(OUTPUT,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes),2))
