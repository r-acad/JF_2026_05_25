# Aerodynamic jobs share an owned warm VLM process per application. They never
# create or change st.model, and cancellation retires only their own worker.
mutable struct AerodynamicJob
    id::String
    state::String
    process::Any
    folder::String
    started::Float64
    message::String
    signature::String
end
const AERODYNAMIC_JOB_LOCK=ReentrantLock()
const AERODYNAMIC_JOBS=WeakKeyDict{Any,Dict{String,AerodynamicJob}}()
include("aerodynamic_worker_client.jl")

function aerodynamic_job_status(job)
    progress=try JSON.parsefile(joinpath(job.folder,"progress.json")) catch;Dict("stage"=>job.message,"done"=>0,"total"=>1) end
    Dict{String,Any}("id"=>job.id,"state"=>job.state,"message"=>job.message,"progress"=>progress,
        "seconds"=>round(time()-job.started;digits=2),"signature"=>job.signature)
end
function stop_aerodynamic_jobs!(st)
    lock(AERODYNAMIC_JOB_LOCK) do
        for job in values(get(AERODYNAMIC_JOBS,st,Dict{String,AerodynamicJob}()))
            if job.state=="running"
                job.state="cancelled";job.message="Aerodynamic analysis cancelled"
            end
        end
    end
    stop_aerodynamic_worker!(st)
end
function handle_aerodynamic_study(st,req;action="run")
    try
        if action in ("mesh","run")
            body=JSON.parse(String(req.body));body isa AbstractDict||throw(ArgumentError("Expected aerodynamic request object"))
            params=get(body,"parameters",Dict());settings=get(body,"settings",Dict());signature=get(body,"signature","")
            params isa AbstractDict&&settings isa AbstractDict&&signature isa AbstractString||throw(ArgumentError("Invalid aerodynamic request"))
            # Validate geometry/settings without creating any FE topology.
            _,_,controls=aerodynamic_geometry(params);validated=aerodynamic_settings(settings,controls)
            action=="run"&&aerodynamic_conditions(validated,controls)
            return lock(AERODYNAMIC_JOB_LOCK) do
                jobs=get!(()->Dict{String,AerodynamicJob}(),AERODYNAMIC_JOBS,st)
                any(j->j.state=="running",values(jobs))&&return error_response("An aerodynamic job is already running. Wait or cancel it first.";status=409)
                id="aero_"*bytes2hex(rand(UInt8,8));folder=joinpath(st.deck_store_dir,"aerodynamics",id);mkpath(folder)
                input=joinpath(folder,"request.json");write(input,JSON.json(Dict("parameters"=>params,"settings"=>validated,"signature"=>signature,"mesh_only"=>action=="mesh")))
                job=AerodynamicJob(id,"running",nothing,folder,time(),"Preparing aerodynamic worker; the first request may compile Julia methods",String(signature));jobs[id]=job
                Threads.@spawn run_aerodynamic_job!(st,job,input;mesh_only=action=="mesh")
                # Keep bounded in-memory job metadata; results stay in their folders.
                completed=sort([j for j in values(jobs) if j.state!="running"];by=j->j.started)
                for old in completed[1:max(0,length(completed)-8)];delete!(jobs,old.id);end
                json_response(aerodynamic_job_status(job))
            end
        end
        query=HTTP.queryparams(HTTP.URI(req.target));id=get(query,"job","")
        response=lock(AERODYNAMIC_JOB_LOCK) do
            jobs=get(AERODYNAMIC_JOBS,st,Dict{String,AerodynamicJob}());haskey(jobs,id)||return error_response("Unknown aerodynamic job";status=404);job=jobs[id]
            if action=="stop"
                if job.state=="running"
                    job.state="cancelled";job.message="Aerodynamic analysis cancelled"
                    stop_aerodynamic_worker!(st;job)
                end
            elseif action=="results"
                job.state=="done"||return error_response("Aerodynamic results are not ready";status=409)
                return joinpath(job.folder,"result.json")
            end
            json_response(aerodynamic_job_status(job))
        end
        # Large completed sweeps must not hold the job/status lock during I/O.
        response isa AbstractString ? HTTP.Response(200,["Content-Type"=>"application/json; charset=utf-8","Cache-Control"=>"no-store"],read(response)) : response
    catch e
        error_response(sprint(showerror,e))
    end
end
