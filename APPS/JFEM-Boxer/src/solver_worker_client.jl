# One directly owned FE worker per server. Requests are serialized; importing
# geometry retains its separate service. FE and sensitivity requests share the
# same package instance and compiled methods, with isolated per-request storage.
mutable struct JfemSolverWorker
    process::Base.Process
    input::Pipe
    replies::Channel{Any}
    bootstrap_log::String
    signature::Any
    runtime::Dict{String,Any}
    active::Union{Nothing,JfemJob}
    ready::Bool
end
const SOLVER_WORKER=Ref{Union{Nothing,JfemSolverWorker}}(nothing)
const SOLVER_WORKER_LOCK=ReentrantLock()
const SOLVER_EXECUTION_LOCK=ReentrantLock()
const SOLVER_PENDING_JOBS=IdDict{JfemJob,Nothing}()
const SOLVER_EXIT_REGISTERED=Ref(false)
const SOLVER_ACCEPTING_REQUESTS=Ref(true)
const SOLVER_SERVICE_CLOSED=Ref(false)

"""Open a new application lifetime after the previous worker has shut down."""
function start_solver_worker_service!()
    lock(SOLVER_WORKER_LOCK) do
        SOLVER_WORKER[]===nothing || error("The solver service is already active")
        any(job->job.state in (:running,:queued),keys(SOLVER_PENDING_JOBS)) &&
            error("The previous solver service has not stopped")
        SOLVER_SERVICE_CLOSED[]=false;SOLVER_ACCEPTING_REQUESTS[]=true
    end
    nothing
end

function solver_worker_signature(repo)
    provenance=WingFEGenBootstrap.JFEMRuntimeImages.JFEMSysimageProvenance
    (realpath(repo),provenance.input_hashes(repo),get(ENV,"WINGFEGEN_JULIA",""),get(ENV,"JFEM_NO_SYSIMAGE",""),
        get(ENV,"JFEM_KRYLOVKIT_THREADS","1")) # Applied by OpenJFEM.__init__.
end

function stop_solver_process!(worker::JfemSolverWorker)
    try
        if process_running(worker.process)
            if Sys.iswindows()
                command=Cmd(["taskkill","/PID",string(getpid(worker.process)),"/T","/F"];windows_hide=true)
                run(pipeline(ignorestatus(command);stdout=devnull,stderr=devnull))
            else
                kill(worker.process)
            end
        end
    catch
        try process_running(worker.process) && kill(worker.process) catch end
    end
    try close(worker.input) catch end
    try wait(worker.process) catch end
    nothing
end

"""Stop owned FE jobs; closing=true permanently rejects new submissions."""
function shutdown_solver_worker!(;closing=false)
    jobs,worker=lock(SOLVER_WORKER_LOCK) do
        SOLVER_ACCEPTING_REQUESTS[]=false
        closing && (SOLVER_SERVICE_CLOSED[]=true)
        current=SOLVER_WORKER[];SOLVER_WORKER[]=nothing
        (collect(keys(SOLVER_PENDING_JOBS)),current)
    end
    try
        for job in jobs;kill_job!(job;message="Application closed; the solver worker was stopped");end
        worker===nothing || stop_solver_process!(worker)
        # Wait for an in-flight acquisition/request to finish its own cleanup.
        lock(SOLVER_EXECUTION_LOCK) do; nothing; end
    finally
        closing || lock(SOLVER_WORKER_LOCK) do
            SOLVER_ACCEPTING_REQUESTS[]=!SOLVER_SERVICE_CLOSED[]
        end
    end
    nothing
end

function cancel_persistent_solver_job!(job;stop_worker=stop_solver_process!)
    get(job.progress,"persistent_worker",false)===true || return false
    worker=lock(SOLVER_WORKER_LOCK) do
        current=SOLVER_WORKER[]
        if current!==nothing && current.active===job
            # Detach before releasing ownership: a delayed OS stop must never
            # target a process already reused by a different request.
            SOLVER_WORKER[]=nothing
            return current
        end
        nothing
    end
    worker===nothing || stop_worker(worker)
    true
end

function create_solver_worker(job,signature;script=joinpath(@__DIR__,"solver_worker_process.jl"))
    runtime=sensitivity_worker_runtime(job.repo;select_image=true)
    command=`$(runtime.command) $(runtime.sysimage_args) --startup-file=no --threads=auto --project=$(job.repo) $script $(job.repo)`
    Sys.iswindows() && (command=Cmd(command;windows_hide=true))
    input=Pipe();output=Pipe();boot=joinpath(job.outdir,"solver_bootstrap.log")
    process=try
        open(boot,"w") do log
            run(pipeline(setenv(command,Dict{String,String}(ENV);dir=job.repo);
                stdin=input,stdout=output,stderr=log);wait=false)
        end
    catch
        close(input);close(output);rethrow()
    end
    close(input.out);close(output.in)
    replies=Channel{Any}(16)
    worker=JfemSolverWorker(process,input,replies,boot,signature,Dict{String,Any}(runtime.metadata),job,false)
    Threads.@spawn begin
        try
            for line in eachline(output)
                if startswith(line,"[JFEM_WORKER] ")
                    put!(replies,JSON.parse(chopprefix(line,"[JFEM_WORKER] ")))
                else
                    put!(replies,Dict("status"=>"diagnostic","message"=>line))
                end
            end
        catch error
            put!(replies,Dict("status"=>"transport_error","message"=>sprint(showerror,error)))
        finally
            try wait(process) catch end
            put!(replies,Dict("status"=>"stopped","message"=>"Solver worker exited with code $(process.exitcode)"))
            close(replies);close(output)
        end
    end
    worker
end

function acquire_solver_worker(job;factory=create_solver_worker)
    signature=(solver_worker_signature(job.repo),factory)
    lock(SOLVER_WORKER_LOCK) do
        SOLVER_ACCEPTING_REQUESTS[] || error("The solver service is shutting down")
        worker=SOLVER_WORKER[]
        reused=worker!==nothing && process_running(worker.process) && worker.signature==signature
        if !reused
            worker===nothing || stop_solver_process!(worker)
            worker=factory(job,signature)
            SOLVER_WORKER[]=worker
        end
        worker.active=job
        lock(job.lk) do
            job.proc=worker.process
            job.progress["worker_pid"]=getpid(worker.process)
            job.progress["worker_reused"]=reused
            job.progress["message"]=reused ? "Reusing the running Julia solver" : "Starting Julia and loading the shared solver packages"
        end
        if !SOLVER_EXIT_REGISTERED[]
            atexit(()->shutdown_solver_worker!(closing=true));SOLVER_EXIT_REGISTERED[]=true
        end
        return worker,reused
    end
end

# Copy the full log to the downloadable job log, but bound the in-memory line
# accumulator. Normal structured timing records retain up to 1 MiB for parsing.
function drain_solver_output!(job,path,cursor;final=false)
    isfile(path) || return 0
    data=open(path,"r") do io;seek(io,cursor.offset);read(io,JOB_LOG_BATCH_BYTES);end
    cursor.offset+=length(data)
    isempty(data) && !final && return 0
    lock(job.lk) do
        open(job.logpath,"a") do output
            start=1
            while start<=length(data)
                ending=findnext(==(0x0a),data,start)
                stop=ending===nothing ? length(data) : ending
                write(output,view(data,start:stop))
                lastbyte=ending===nothing ? stop : stop-1
                taken=min(max(0,1024*1024-length(cursor.preview)),max(0,lastbyte-start+1))
                taken>0 && append!(cursor.preview,view(data,start:start+taken-1))
                taken<lastbyte-start+1 && (cursor.shortened=true)
                if ending!==nothing
                    published=record_job_lines!(job,(disk_preview(cursor),))
                    for extra in published[2:end];println(output,extra);end
                    empty!(cursor.preview);cursor.shortened=false
                end
                start=stop+1
            end
            if final && isempty(data) && !isempty(cursor.preview)
                println(output)
                published=record_job_lines!(job,(disk_preview(cursor),))
                for extra in published[2:end];println(output,extra);end
                empty!(cursor.preview);cursor.shortened=false
            end
        end
    end
    length(data)
end

function solver_worker_reply!(job,worker,log,cursor)
    while true
        drain_solver_output!(job,log,cursor)
        job.cancel_requested && return nothing
        enforce_job_timeout!(job)
        job.cancel_requested && return nothing
        if isready(worker.replies)
            reply=take!(worker.replies)
            status=get(reply,"status","")
            if status=="diagnostic"
                append_job_lines!(job,[String(reply["message"])]);continue
            end
            status in ("stopped","transport_error") && error(String(reply["message"]))
            return reply
        end
        (!isopen(worker.replies) || !process_running(worker.process)) && error("The persistent solver worker stopped before completing this request")
        sleep(.05)
    end
end

function run_persistent_solver_job!(job;worker_factory=create_solver_worker,command="run",completion=finish_jfem_process!)
    worker=nothing;cursor=JobDiskCursor();log="";exitcode=1;failure_reason=""
    try
        lock(SOLVER_EXECUTION_LOCK) do
            job.cancel_requested && return
            try
                worker,reused=acquire_solver_worker(job;factory=worker_factory)
                job.cancel_requested && (stop_solver_process!(worker);return)
                if !worker.ready
                    log=worker.bootstrap_log
                    reply=solver_worker_reply!(job,worker,log,cursor)
                    reply===nothing && return
                    get(reply,"status","")=="ready" || error("Unexpected solver startup response")
                    merge!(worker.runtime,Dict{String,Any}(reply["runtime"]));worker.ready=true
                    while drain_solver_output!(job,log,cursor;final=true)>0;yield();end
                end
                job.cancel_requested && return
                lock(job.lk) do
                    job.progress["worker_session_id"]=worker.runtime["session_id"]
                    job.progress["worker_runtime"]=copy(worker.runtime)
                end
                append_job_lines!(job,["[Worker] $(reused ? "Reusing" : "Ready") Julia PID $(getpid(worker.process)); session $(worker.runtime["session_id"])"])
                if command=="sensitivity"
                    sensitivity_json_write(joinpath(job.outdir,"runtime.json"),worker.runtime)
                end
                request=Dict("command"=>command,"id"=>job.outdir,"bdf"=>job.bdf,"outdir"=>job.outdir,
                    "formats"=>String(job.model.params["jfem.output_formats"]),
                    "environment"=>Dict(k=>v for (k,v) in ENV if startswith(k,"JFEM_")))
                log=joinpath(job.outdir,"solver_stdout.log");cursor=JobDiskCursor()
                println(worker.input,JSON.json(request));flush(worker.input)
                reply=solver_worker_reply!(job,worker,log,cursor)
                reply===nothing && return
                get(reply,"id",nothing)==job.outdir || error("Solver worker replied for another run")
                exitcode=Int(get(reply,"exit_code",1))
                message=String(get(reply,"message",""))
                exitcode==0 || (failure_reason=message)
                isempty(message) || append_job_lines!(job,["[Worker] "*message])
                lock(job.lk) do
                    job.progress["worker_runtime"]=get(reply,"runtime",worker.runtime)
                end
            catch error
                exitcode=1
                failure_reason="Persistent solver request failed: "*sprint(showerror,error)
                append_job_lines!(job,[failure_reason])
                worker===nothing || stop_solver_process!(worker)
            finally
                job.cancel_requested && worker!==nothing && stop_solver_process!(worker)
                isempty(log) || (while drain_solver_output!(job,log,cursor;final=true)>0;yield();end)
                lock(SOLVER_WORKER_LOCK) do
                    worker===nothing || (worker.active=nothing)
                end
            end
        end
    catch error
        exitcode=1
        failure_reason="Solver worker could not start: "*sprint(showerror,error)
        append_job_lines!(job,[failure_reason])
    finally
        try completion(job,exitcode;failure_reason) finally
            job.log_done=true
            lock(SOLVER_WORKER_LOCK) do;delete!(SOLVER_PENDING_JOBS,job);end
        end
    end
    nothing
end

"""Submit a run immediately; one persistent Julia process executes requests serially."""
function launch_jfem_process!(job::JfemJob;worker_factory=create_solver_worker,command="run",completion=finish_jfem_process!)
    admitted=lock(SOLVER_WORKER_LOCK) do
        lock(job.lk) do
            if job.cancel_requested
                job.log_done=true
                return :cancelled
            end
            SOLVER_ACCEPTING_REQUESTS[] || return :closed
            job.started=time();job.state=:running
            merge!(job.progress,Dict("persistent_worker"=>true,"stage"=>"startup",
                "stage_started"=>job.started,"stage_category"=>"preparation","stage_state"=>"started",
                "compilation_live"=>"not_separable","message"=>"Waiting for the solver worker; analyses run one at a time"))
            SOLVER_PENDING_JOBS[job]=nothing
            :accepted
        end
    end
    if admitted===:cancelled
        completion===finish_jfem_process! || completion(job,1;failure_reason=job.message)
        return job
    end
    if admitted===:closed
        lock(job.lk) do
            job.started=time();job.finished=job.started;job.state=:failed;job.exitcode=1;job.log_done=true
            job.message="The application is closing; no new solver request was started"
            job.progress["phase"]="failed";job.progress["message"]=job.message
        end
        append_job_lines!(job,[job.message])
        completion===finish_jfem_process! || completion(job,1;failure_reason=job.message)
        return job
    end
    Threads.@spawn run_persistent_solver_job!(job;worker_factory,command,completion)
    Threads.@spawn begin
        while job.state===:running;sleep(.25);enforce_job_timeout!(job);end
    end
    job
end
