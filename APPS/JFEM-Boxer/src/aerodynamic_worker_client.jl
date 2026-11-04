# One owned aerodynamic process per application. Completed requests leave its
# Julia methods warm; cancelled, failed or source-incompatible workers retire.
mutable struct AerodynamicWorker
    process::Base.Process
    input::Pipe
    replies::Channel{Any}
    signature::Any
    runtime::Dict{String,Any}
    active::Union{Nothing,AerodynamicJob}
    ready::Bool
end
const AERODYNAMIC_WORKERS=WeakKeyDict{Any,AerodynamicWorker}()
const AERODYNAMIC_WORKER_EXIT_REGISTERED=Ref(false)

function close_aerodynamic_worker!(worker)
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
        try process_running(worker.process)&&kill(worker.process) catch end
    end
    try close(worker.input) catch end
    try wait(worker.process) catch end
    try close(worker.replies) catch end
    nothing
end

function stop_aerodynamic_worker!(st;job=nothing)
    worker=lock(AERODYNAMIC_JOB_LOCK) do
        current=get(AERODYNAMIC_WORKERS,st,nothing)
        if current!==nothing&&(job===nothing||current.active===job)
            delete!(AERODYNAMIC_WORKERS,st)
            return current
        end
        nothing
    end
    worker===nothing||close_aerodynamic_worker!(worker)
    nothing
end

function register_aerodynamic_worker_exit!()
    AERODYNAMIC_WORKER_EXIT_REGISTERED[]&&return
    AERODYNAMIC_WORKER_EXIT_REGISTERED[]=true
    atexit() do
        workers=lock(AERODYNAMIC_JOB_LOCK) do
            current=collect(values(AERODYNAMIC_WORKERS));empty!(AERODYNAMIC_WORKERS);current
        end
        foreach(close_aerodynamic_worker!,workers)
    end
end

function create_aerodynamic_worker(st,job,signature;script=joinpath(st.root,"src","aerodynamic_worker.jl"))
    repo=normpath(joinpath(st.root,"..",".."))
    runtime=sensitivity_worker_runtime(repo;select_image=true)
    command=`$(runtime.command) $(runtime.sysimage_args) --startup-file=no --threads=auto --project=$repo -O1 $script --service`
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    input=Pipe();output=Pipe()
    process=try
        open(joinpath(job.folder,"worker.log"),"a") do log
            run(pipeline(setenv(command,Dict{String,String}(ENV);dir=repo);
                stdin=input,stdout=output,stderr=log);wait=false)
        end
    catch
        close(input);close(output);rethrow()
    end
    close(input.out);close(output.in)
    worker=AerodynamicWorker(process,input,Channel{Any}(32),signature,
        Dict{String,Any}(runtime.metadata),job,false)
    Threads.@spawn begin
        try
            for line in eachline(output)
                reply=startswith(line,"[AERO_WORKER] ") ? JSON.parse(chopprefix(line,"[AERO_WORKER] ")) :
                    Dict("status"=>"diagnostic","message"=>line)
                put!(worker.replies,reply)
            end
        catch error
            isopen(worker.replies)&&put!(worker.replies,Dict("status"=>"transport_error","message"=>sprint(showerror,error)))
        finally
            try wait(process) catch end
            try
                isopen(worker.replies)&&put!(worker.replies,Dict("status"=>"stopped","message"=>"Aerodynamic worker exited with code $(process.exitcode)"))
            catch
                # Cancellation may close the queue while its final event is
                # being published. Always release the output pipe as well.
            end
            try close(worker.replies) catch end
            try close(output) catch end
        end
    end
    worker
end

function acquire_aerodynamic_worker(st,job;factory=create_aerodynamic_worker)
    repo=normpath(joinpath(st.root,"..",".."));signature=solver_worker_signature(repo)
    stale=nothing
    worker=lock(AERODYNAMIC_JOB_LOCK) do
        job.state=="running"||throw(InterruptException())
        register_aerodynamic_worker_exit!()
        current=get(AERODYNAMIC_WORKERS,st,nothing)
        if current!==nothing
            if process_running(current.process)&&isopen(current.replies)&&current.signature==signature
                current.active===nothing||error("The aerodynamic worker already has an active request")
                current.active=job;job.process=current.process
                return current
            end
            delete!(AERODYNAMIC_WORKERS,st);stale=current
        end
        nothing
    end
    stale===nothing||close_aerodynamic_worker!(stale)
    worker!==nothing&&return worker
    created=factory(st,job,signature)
    accepted=lock(AERODYNAMIC_JOB_LOCK) do
        if job.state=="running"
            AERODYNAMIC_WORKERS[st]=created;job.process=created.process;true
        else
            false
        end
    end
    if !accepted;close_aerodynamic_worker!(created);throw(InterruptException());end
    created
end

function aerodynamic_worker_reply(worker,job)
    while true
        job.state=="running"||throw(InterruptException())
        isready(worker.replies)&&return take!(worker.replies)
        isopen(worker.replies)&&process_running(worker.process)||error("The aerodynamic worker stopped before completing this request")
        sleep(.02)
    end
end

function run_aerodynamic_job!(st,job,input;mesh_only=false,worker_factory=create_aerodynamic_worker)
    worker=nothing
    try
        worker=acquire_aerodynamic_worker(st,job;factory=worker_factory)
        reused=worker.ready
        while !worker.ready
            reply=aerodynamic_worker_reply(worker,job)
            status=get(reply,"status","")
            if status=="ready"
                worker.ready=true
            elseif status=="diagnostic"
                open(io->println(io,get(reply,"message","")),joinpath(job.folder,"worker.log"),"a")
            else
                error(get(reply,"message","Aerodynamic worker startup failed"))
            end
        end
        lock(AERODYNAMIC_JOB_LOCK) do
            job.state=="running"||throw(InterruptException())
            job.message=reused ? "Reusing the running aerodynamic worker" : "Aerodynamic worker ready"
            println(worker.input,JSON.json(Dict("id"=>job.id,"input"=>input,"reused"=>reused,"runtime"=>worker.runtime)))
            flush(worker.input)
        end
        while true
            reply=aerodynamic_worker_reply(worker,job);status=get(reply,"status","")
            if status=="diagnostic"
                open(io->println(io,get(reply,"message","")),joinpath(job.folder,"worker.log"),"a")
                continue
            end
            status in ("stopped","transport_error")&&error(get(reply,"message","Aerodynamic worker transport failed"))
            get(reply,"id",nothing)==job.id||error("Unexpected aerodynamic worker request identity")
            status=="done"||error(get(reply,"message","Aerodynamic worker failed. See its worker.log."))
            isfile(joinpath(job.folder,"result.json"))||error("The aerodynamic worker did not publish its result")
            lock(AERODYNAMIC_JOB_LOCK) do
                if job.state=="running"
                    worker.active=nothing
                    job.state="done";job.message=mesh_only ? "Aerodynamic mesh ready" : "Aerodynamic analysis complete"
                end
            end
            break
        end
    catch error
        retired=lock(AERODYNAMIC_JOB_LOCK) do
            current=get(AERODYNAMIC_WORKERS,st,nothing)
            owned=current!==nothing&&current.active===job
            owned&&delete!(AERODYNAMIC_WORKERS,st)
            if job.state=="running"
                job.state="failed";job.message=sprint(showerror,error)
            end
            owned ? current : nothing
        end
        # Detach in the same transition that admits a retry. Closing the old
        # process later must never retire a successor request's worker.
        retired===nothing||close_aerodynamic_worker!(retired)
    end
    nothing
end
