# Aerodynamic jobs own their Julia child process. They never create/change st.model.
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
                job.process===nothing||process_exited(job.process)||kill(job.process)
            end
        end
    end
end
function handle_aerodynamic_study(st,req;action="run")
    try
        if action in ("mesh","run")
            body=JSON.parse(String(req.body));body isa AbstractDict||throw(ArgumentError("Expected aerodynamic request object"))
            params=get(body,"parameters",Dict());settings=get(body,"settings",Dict());signature=get(body,"signature","")
            params isa AbstractDict&&settings isa AbstractDict&&signature isa AbstractString&&sizeof(signature)<=1024*1024||throw(ArgumentError("Invalid aerodynamic request"))
            # Validate geometry/settings without creating any FE topology.
            _,_,controls=aerodynamic_geometry(params);validated=aerodynamic_settings(settings,controls)
            action=="run"&&aerodynamic_conditions(validated,controls)
            return lock(AERODYNAMIC_JOB_LOCK) do
                jobs=get!(()->Dict{String,AerodynamicJob}(),AERODYNAMIC_JOBS,st)
                any(j->j.state=="running",values(jobs))&&return error_response("An aerodynamic job is already running. Wait or cancel it first.";status=409)
                id="aero_"*bytes2hex(rand(UInt8,8));folder=joinpath(st.deck_store_dir,"aerodynamics",id);mkpath(folder)
                input=joinpath(folder,"request.json");write(input,JSON.json(Dict("parameters"=>params,"settings"=>validated,"signature"=>signature,"mesh_only"=>action=="mesh")))
                job=AerodynamicJob(id,"running",nothing,folder,time(),"Starting independent aerodynamic worker",String(signature));jobs[id]=job
                repo=normpath(joinpath(st.root,"..",".."));exe=joinpath(Sys.BINDIR,Base.julia_exename())
                script=joinpath(st.root,"src","aerodynamic_worker.jl")
                cmd=`$exe --startup-file=no --threads=1 --project=$repo -O1 $script $input`
                log=open(joinpath(folder,"worker.log"),"w")
                try;job.process=run(pipeline(cmd;stdout=log,stderr=log);wait=false)
                catch e;job.state="failed";job.message=sprint(showerror,e);rethrow()
                finally;close(log);end
                @async begin
                    wait(job.process)
                    lock(AERODYNAMIC_JOB_LOCK) do
                        if job.state=="running"
                            if success(job.process)&&isfile(joinpath(folder,"result.json"))
                                job.state="done";job.message=action=="mesh" ? "Aerodynamic mesh ready" : "Aerodynamic analysis complete"
                            else
                                job.state="failed"
                                job.message=try String(JSON.parsefile(joinpath(folder,"error.json"))["error"]) catch;"Aerodynamic worker failed. See its worker.log." end
                            end
                        end
                    end
                end
                # Keep bounded in-memory job metadata; results stay in their folders.
                completed=sort([j for j in values(jobs) if j.state!="running"];by=j->j.started)
                for old in completed[1:max(0,length(completed)-8)];delete!(jobs,old.id);end
                json_response(aerodynamic_job_status(job))
            end
        end
        query=HTTP.queryparams(HTTP.URI(req.target));id=get(query,"job","")
        return lock(AERODYNAMIC_JOB_LOCK) do
            jobs=get(AERODYNAMIC_JOBS,st,Dict{String,AerodynamicJob}());haskey(jobs,id)||return error_response("Unknown aerodynamic job";status=404);job=jobs[id]
            if action=="stop"
                if job.state=="running";job.state="cancelled";job.message="Aerodynamic analysis cancelled";job.process===nothing||process_exited(job.process)||kill(job.process);end
            elseif action=="results"
                job.state=="done"||return error_response("Aerodynamic results are not ready";status=409)
                return HTTP.Response(200,["Content-Type"=>"application/json; charset=utf-8","Cache-Control"=>"no-store"],read(joinpath(job.folder,"result.json")))
            end
            json_response(aerodynamic_job_status(job))
        end
    catch e
        error_response(sprint(showerror,e))
    end
end
