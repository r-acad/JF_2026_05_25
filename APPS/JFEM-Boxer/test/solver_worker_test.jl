# julia --project=. APPS/JFEM-Boxer/test/solver_worker_test.jl OUTPUT [--native]
# Controlled IPC checks always run; --native also solves tiny real shell cases.
using Test, WingFEGen, OpenJFEM, JSON, SHA
const W=WingFEGen
1<=length(ARGS)<=2 || error("Expected OUTPUT [--native]")
length(ARGS)==1 || ARGS[2]=="--native" || error("Unknown test option")
const OUTPUT=abspath(ARGS[1]);mkpath(OUTPUT)
const APP=dirname(@__DIR__)
const REPO=normpath(joinpath(APP,"..",".."))
const BASE_DECK=read(joinpath(REPO,"__Start here!__","examples","precompile","sol101_adjoint_shell.bdf"),String)
const RECORDS=Any[]

function wait_until(predicate;seconds=120.)
    timedwait(predicate,seconds;pollint=.05)==:ok || error("Worker test timed out after $seconds s")
end
function wait_job(job;seconds=600.)
    try
        wait_until(()->!(job.state in (:running,:queued)) && job.log_done;seconds)
    catch
        W.kill_job!(job;message="Owned test exceeded its deadline",state=:failed)
        rethrow()
    end
    job
end
function make_job(name;deck=BASE_DECK,formats="jrs",timeout=10.,solution="101")
    path=joinpath(OUTPUT,name*".bdf");write(path,deck)
    params=merge(W.default_params(),Dict("output.solution"=>solution,"jfem.output_formats"=>formats,
        "jfem.output_dir"=>OUTPUT,"jfem.timeout_minutes"=>timeout))
    # The viewer model is stable; a bad deck tests solver failure without
    # requiring the viewer parser to accept an unsupported SOL.
    invalid=occursin("SOL 999",deck)
    native=OpenJFEM.bdf_to_model(invalid ? joinpath(REPO,"__Start here!__","examples","precompile","sol101_adjoint_shell.bdf") : path)
    source=W.imported_source(Dict("name"=>basename(path),"text"=>invalid ? BASE_DECK : deck))
    model=W.imported_model(native,source,params)
    W.prepare_jfem_job(model,params,APP,path,name)
end
function save_record(job)
    record=Dict("id"=>job.id,"state"=>String(job.state),"outdir"=>job.outdir,
        "progress"=>W.job_progress(job),"timings"=>W.job_timings(job))
    push!(RECORDS,record)
    write(joinpath(OUTPUT,"jobs.json"),JSON.json(RECORDS))
end

suite=@testset "Persistent Boxer FE worker" begin
    try
        if "--native" in ARGS
            @testset "Actual sequential solves retain one PID and independent state" begin
                first=make_job("native_first")
                W.launch_jfem_process!(first);wait_job(first)
                @test first.state===:done
                first.state===:done || error(W.job_log(first))
                pid=first.progress["worker_pid"]
                @test !first.progress["worker_reused"]
                @test process_running(first.proc)
                @test W.job_timings(first)["available"]
                @test W.job_timings(first)["solution_seconds"]>=0
                first_path,first_data=W.find_results_json(first.outdir)
                first_hash=bytes2hex(sha256(read(first_path)))
                save_record(first)

                scaled=replace(BASE_DECK,",100.,0.,0.,-1."=>",200.,0.,0.,-1.")
                second=make_job("native_second";deck=scaled,formats="s")
                W.launch_jfem_process!(second);wait_job(second)
                @test second.state===:done
                @test second.progress["worker_pid"]==pid
                @test second.progress["worker_reused"]
                _,second_data=W.find_results_json(second.outdir)
                @test [r["t3"] for r in second_data["displacements"]] ≈ 2 .* [r["t3"] for r in first_data["displacements"]]
                @test first.outdir!=second.outdir
                @test read(first.bdf,String)==BASE_DECK
                @test read(second.bdf,String)==scaled
                @test bytes2hex(sha256(read(first_path)))==first_hash
                @test any(endswith(".jfem"),readdir(first.outdir))
                @test !any(endswith(".jfem"),readdir(second.outdir))
                @test !any(endswith(".REPORT.md"),readdir(second.outdir))
                @test W.job_timings(second)["available"]
                r1=JSON.parsefile(joinpath(first.outdir,"solver_worker.json"))
                r2=JSON.parsefile(joinpath(second.outdir,"solver_worker.json"))
                @test r1["request_index"]==1 && r2["request_index"]==2
                @test r1["finished_unix"]<=r2["started_unix"]
                @test realpath(r2["project"])==realpath(joinpath(REPO,"Project.toml"))
                @test r2["manifest_sha256"]==bytes2hex(sha256(read(joinpath(REPO,"Manifest.toml"))))
                save_record(second)

                failed=make_job("native_failure";deck=replace(BASE_DECK,"SOL 101"=>"SOL 999"))
                W.launch_jfem_process!(failed);wait_job(failed)
                @test failed.state===:failed
                @test failed.progress["worker_pid"]==pid
                @test occursin("Unsupported solution SOL 999",read(failed.logpath,String))
                save_record(failed)
                recovered=make_job("native_recovered";formats="s")
                W.launch_jfem_process!(recovered);wait_job(recovered)
                @test recovered.state===:done
                @test recovered.progress["worker_pid"]==pid
                _,data=W.find_results_json(recovered.outdir)
                @test data["displacements"]==first_data["displacements"]
                @test process_running(recovered.proc)
                save_record(recovered)

                for (solution,filename) in (("103","sol103_quad_modes.bdf"),
                        ("105","sol105_quad_buckling.bdf"),("106","sol106_quad_nonlinear.bdf"))
                    deck=read(joinpath(REPO,"__Start here!__","examples","precompile",filename),String)
                    mixed=make_job("native_sol"*solution;deck,formats="s",solution)
                    W.launch_jfem_process!(mixed);wait_job(mixed)
                    @test mixed.state===:done
                    mixed.state===:done || error(W.job_log(mixed))
                    @test mixed.progress["worker_pid"]==pid
                    @test mixed.progress["worker_reused"]
                    _,mixed_data=W.find_results_json(mixed.outdir)
                    @test startswith(mixed_data["analysis_type"],"SOL"*solution)
                    timings=W.job_timings(mixed)
                    @test timings["measured_runs"]==1 && !isempty(timings["stages"])
                    @test timings["available"]==(timings["solution_seconds"] isa Real)
                    @test process_running(mixed.proc)
                    save_record(mixed)
                end
                after_mixed=make_job("native_after_mixed";formats="s")
                W.launch_jfem_process!(after_mixed);wait_job(after_mixed)
                @test after_mixed.state===:done
                @test after_mixed.progress["worker_pid"]==pid
                _,after_data=W.find_results_json(after_mixed.outdir)
                @test after_data["displacements"]==first_data["displacements"]
                @test bytes2hex(sha256(read(first_path)))==first_hash
                save_record(after_mixed)
            end
            W.shutdown_solver_worker!()
        end

        @testset "Actual IPC cancellation, queue isolation, crash recovery and shutdown" begin
            script=joinpath(OUTPUT,"controlled_worker.jl")
            write(script,raw"""
using JSON
reply(data)=(println("[JFEM_WORKER] ",JSON.json(data));flush(stdout))
reply(Dict("status"=>"ready","runtime"=>Dict("session_id"=>"controlled-$(getpid())","pid"=>getpid())))
for line in eachline(stdin)
    request=JSON.parse(line);get(request,"command","")=="quit" && break
    output=request["outdir"];name=basename(request["bdf"])
    write(joinpath(output,"entered.json"),JSON.json(Dict("pid"=>getpid(),"started"=>time())))
    open(joinpath(output,"solver_stdout.log"),"w") do log
        println(log,"Controlled request ",name);flush(log)
        if startswith(name,"hold");sleep(60);end
        startswith(name,"crash") && exit(7)
        write(joinpath(output,"controlled.JU.JSON"),JSON.json(Dict("analysis_type"=>"SOL101_STATIC","displacements"=>Any[])))
    end
    reply(Dict("id"=>request["id"],"status"=>"done","exit_code"=>0,"message"=>""))
end
""")
            factory=(job,signature)->W.create_solver_worker(job,signature;script)
            admission=make_job("cancel_during_admission")
            entered=Channel{Nothing}(1)
            lock(W.SOLVER_WORKER_LOCK)
            launching=try
                task=Threads.@spawn begin
                    put!(entered,nothing)
                    W.launch_jfem_process!(admission;worker_factory=factory)
                end
                take!(entered)
                W.kill_job!(admission)
                task
            finally
                unlock(W.SOLVER_WORKER_LOCK)
            end
            fetch(launching);wait_job(admission)
            @test admission.state===:cancelled && admission.log_done
            @test admission.proc===nothing
            @test !haskey(W.SOLVER_PENDING_JOBS,admission)
            save_record(admission)

            active=make_job("hold_active")
            W.launch_jfem_process!(active;worker_factory=factory)
            wait_until(()->isfile(joinpath(active.outdir,"entered.json")))
            pid=active.progress["worker_pid"]
            queued=make_job("queued_cancelled")
            W.launch_jfem_process!(queued;worker_factory=factory)
            @test queued.proc===nothing
            W.kill_job!(queued)
            @test queued.state===:cancelled
            @test process_running(active.proc)
            @test !isfile(joinpath(queued.outdir,"entered.json"))
            W.kill_job!(active);wait_job(active);wait_job(queued)
            @test active.state===:cancelled
            @test !process_running(active.proc)
            save_record(active);save_record(queued)

            next=make_job("after_cancel")
            W.launch_jfem_process!(next;worker_factory=factory);wait_job(next)
            @test next.state===:done
            @test next.progress["worker_pid"]!=pid
            @test !next.progress["worker_reused"]
            @test process_running(next.proc)
            save_record(next)
            crash=make_job("crash_request")
            W.launch_jfem_process!(crash;worker_factory=factory);wait_job(crash)
            @test crash.state===:failed
            @test !process_running(crash.proc)
            @test crash.progress["worker_pid"]==next.progress["worker_pid"]
            save_record(crash)
            restored=make_job("after_crash")
            W.launch_jfem_process!(restored;worker_factory=factory);wait_job(restored)
            @test restored.state===:done
            @test restored.progress["worker_pid"]!=crash.progress["worker_pid"]
            @test process_running(restored.proc)
            W.shutdown_solver_worker!()
            @test !process_running(restored.proc)
            @test W.SOLVER_WORKER[]===nothing
            save_record(restored)

            timeout=make_job("hold_timeout";timeout=.025)
            W.launch_jfem_process!(timeout;worker_factory=factory);wait_job(timeout)
            @test timeout.state===:failed && timeout.cancel_requested
            @test timeout.proc===nothing || !process_running(timeout.proc)
            @test occursin("timeout",timeout.message)
            save_record(timeout)

            # Hold the OS termination after the cancellation ownership check.
            # A later request must never reuse the detached process, even when
            # the delayed stop resumes after that later request has completed.
            late=make_job("hold_late_cancel")
            W.launch_jfem_process!(late;worker_factory=factory)
            wait_until(()->isfile(joinpath(late.outdir,"entered.json")))
            old_worker=W.SOLVER_WORKER[]
            captured=Channel{Nothing}(1);release=Channel{Nothing}(1)
            delayed=Threads.@spawn W.cancel_persistent_solver_job!(late;stop_worker=worker->begin
                put!(captured,nothing);take!(release);W.stop_solver_process!(worker)
            end)
            take!(captured)
            @test W.SOLVER_WORKER[]===nothing
            W.kill_job!(late);wait_job(late)
            replacement=make_job("after_late_cancel")
            W.launch_jfem_process!(replacement;worker_factory=factory);wait_job(replacement)
            @test replacement.state===:done
            @test replacement.progress["worker_pid"]!=late.progress["worker_pid"]
            put!(release,nothing);fetch(delayed)
            @test !process_running(old_worker.process)
            @test process_running(replacement.proc)
            save_record(late);save_record(replacement)

            initial_signature=W.solver_worker_signature(REPO)
            withenv("JFEM_KRYLOVKIT_THREADS"=>"271") do
                @test W.solver_worker_signature(REPO)!=initial_signature
            end

            closing=make_job("hold_closing")
            W.launch_jfem_process!(closing;worker_factory=factory)
            wait_until(()->isfile(joinpath(closing.outdir,"entered.json")))
            closed=Threads.@spawn W.shutdown_solver_worker!(closing=true)
            wait_until(()->!W.SOLVER_ACCEPTING_REQUESTS[])
            rejected=make_job("rejected_during_close")
            W.launch_jfem_process!(rejected;worker_factory=factory);wait_job(rejected)
            fetch(closed);wait_job(closing)
            @test closing.state===:cancelled && !process_running(closing.proc)
            @test rejected.state===:failed && rejected.proc===nothing
            @test !isfile(joinpath(rejected.outdir,"entered.json"))
            @test W.SOLVER_WORKER[]===nothing
            W.shutdown_solver_worker!() # A reset cannot undo permanent closing.
            @test !W.SOLVER_ACCEPTING_REQUESTS[]
            W.start_solver_worker_service!()
            @test W.SOLVER_ACCEPTING_REQUESTS[]
            reopened=make_job("reopened_app")
            W.launch_jfem_process!(reopened;worker_factory=factory);wait_job(reopened)
            @test reopened.state===:done && process_running(reopened.proc)
            save_record(closing);save_record(rejected);save_record(reopened)
        end
    finally
        W.shutdown_solver_worker!()
    end
end
counts=Test.get_test_counts(suite)
write(joinpath(OUTPUT,"summary.json"),JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"native"=>("--native" in ARGS))))
