function request_imported_model(raw)
    raw isa AbstractDict||return nothing
    value=get(get(raw,"parameters",raw),"imported_deck",nothing);value===nothing&&return nothing
    value isa AbstractDict||throw(ArgumentError("Invalid imported deck handle"))
    token=get(value,"token",nothing);token isa AbstractString||throw(ArgumentError("Imported deck token is missing; read the deck again"))
    lock(IMPORTED_MODELS_LOCK) do
        haskey(IMPORTED_MODELS,token)||throw(ArgumentError("Imported deck is no longer in this server session; read the saved source again"))
        IMPORTED_MODELS[token]
    end
end

const IMPORT_WORKERS=Dict{String,Any}()
const IMPORT_WORKERS_LOCK=ReentrantLock()
const IMPORT_PREPARATIONS=Dict{String,Dict{String,Any}}()
const IMPORT_PREPARATIONS_LOCK=ReentrantLock()

function imported_worker(st,repo)
    lock(IMPORT_WORKERS_LOCK) do
        key=abspath(repo)*"\n"*st.deck_store_dir
        existing=get(IMPORT_WORKERS,key,nothing)
        existing!==nothing&&process_running(existing.process)&&return existing
        runtime=sensitivity_worker_runtime(repo)
        base=joinpath(st.deck_store_dir,"imports");mkpath(base)
        queue=mktempdir(base;prefix="worker_",cleanup=false)
        # Imports do no numerical solve. -O0 reduces first-use parser/viewer
        # compilation while still reusing the native package's compiled cache.
        command=`$(runtime.command) --startup-file=no -O0 --threads=1 --project=$repo $(joinpath(@__DIR__,"nastran_import_worker.jl")) --serve $queue $repo $(st.root)`
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        process=open(joinpath(queue,"worker.log"),"w") do output
            run(pipeline(addenv(command,"OPENBLAS_NUM_THREADS"=>"1","JFEM_SUPPRESS_THREAD_HINT"=>"1");stdout=output,stderr=output);wait=false)
        end
        worker=(process=process,queue=queue,lock=ReentrantLock(),started=time())
        IMPORT_WORKERS[key]=worker
        worker
    end
end

function imported_run_worker(st,repo,dir,progress)
    worker=imported_worker(st,repo)
    waiting=time()
    islocked(worker.lock)&&progress("Waiting for the importer preparation to finish; no analysis is running")
    lock(worker.lock) do
        process_running(worker.process)||throw(ArgumentError("Import worker stopped; try Read Nastran again"))
        warm=isfile(joinpath(worker.queue,"ready.txt"))
        progress(warm ? "Using the ready native parser" : "Starting the native parser; loading its package cache")
        temporary=joinpath(worker.queue,"request.tmp")
        write(joinpath(dir,"queued_at.txt"),string(time()))
        write(temporary,dir);mv(temporary,joinpath(worker.queue,"request.txt");force=true)
        laststage=""
        while !isfile(joinpath(dir,"done.txt"))
            if !process_running(worker.process)
                detail=read(joinpath(worker.queue,"worker.log"),String)
                throw(ArgumentError("Native parser process stopped. $detail"))
            end
            stagefile=joinpath(dir,"stage.txt")
            isfile(stagefile)||(stagefile=joinpath(worker.queue,"bootstrap_stage.txt"))
            if isfile(stagefile)
                stage=read(stagefile,String)
                !isempty(stage)&&stage!=laststage&&(progress(stage);laststage=stage)
            end
            sleep(.1)
        end
        isfile(joinpath(dir,"error.json"))&&throw(ArgumentError("Native Nastran import failed: "*String(JSON.parsefile(joinpath(dir,"error.json"))["error"])))
        return Dict("worker_wait_seconds"=>time()-waiting,"worker_was_ready"=>warm)
    end
end

"""Prepare parser methods only after Read Nastran is opened, without a solve."""
function handle_import_nastran_prepare(st,req)
    try
        repo,_=find_jfem(st.root;hint=String(st.params["jfem.repo"]))
        repo===nothing&&throw(ArgumentError("Configure the JFEM repository before importing a deck"))
        key=abspath(repo)*"\n"*st.deck_store_dir
        worker=lock(IMPORT_WORKERS_LOCK) do;get(IMPORT_WORKERS,key,nothing);end
        if req.method=="POST"
            worker=imported_worker(st,repo)
            lock(IMPORT_PREPARATIONS_LOCK) do
                if !haskey(IMPORT_PREPARATIONS,worker.queue)
                    record=Dict{String,Any}("state"=>"preparing","stage"=>"Starting import-only parser preparation","started"=>time(),"seconds"=>0.)
                    IMPORT_PREPARATIONS[worker.queue]=record
                    @async try
                        directory=mktempdir(dirname(worker.queue);prefix="preparation_",cleanup=false)
                        # One tiny shell warms parsing/model/serialization paths.
                        # It never assembles K, solves, or changes the open Study.
                        source=imported_source(Dict("name"=>"importer_preparation.bdf","text"=>
                            "SOL 101\nCEND\nSPC=1\nLOAD=2\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,1.,1.,0.\nGRID,4,,0.,1.,0.\nCQUAD4,1,1,1,2,3,4\nPSHELL,1,1,.01\nMAT1,1,7.E10,,.3,2700.\nSPC1,1,123456,1\nFORCE,2,3,0,1.,0.,0.,1.\nENDDATA\n"))
                        Serialization.serialize(joinpath(directory,"input.jls"),(source,default_params()))
                        report=stage->lock(IMPORT_PREPARATIONS_LOCK) do;record["stage"]=stage;end
                        imported_run_worker(st,repo,directory,report)
                        lock(IMPORT_PREPARATIONS_LOCK) do
                            record["state"]="ready";record["stage"]="Importer ready";record["seconds"]=time()-record["started"]
                            record["timings"]=JSON.parsefile(joinpath(directory,"timings.json"))
                        end
                    catch err
                        lock(IMPORT_PREPARATIONS_LOCK) do
                            record["state"]="failed";record["stage"]=describe_error(err);record["seconds"]=time()-record["started"]
                        end
                    end
                end
            end
        end
        record=lock(IMPORT_PREPARATIONS_LOCK) do
            worker===nothing||!process_running(worker.process) ? nothing : get(IMPORT_PREPARATIONS,worker.queue,nothing)
        end
        record===nothing&&return json_response(Dict("ok"=>true,"state"=>"not_started","seconds"=>0.))
        response=lock(IMPORT_PREPARATIONS_LOCK) do
            result=copy(record);result["state"]=="preparing"&&(result["seconds"]=time()-result["started"]);result
        end
        response["ok"]=true;json_response(response)
    catch err
        error_response("Importer preparation: "*describe_error(err))
    end
end

"""Browse files on this computer without a detached desktop dialog.

An ownerless Windows OpenFileDialog can remain hidden behind the browser,
leaving its HTTP request waiting indefinitely. Listing local paths in the app
keeps cancellation/navigation visible and retains automatic INCLUDE access.
"""
function imported_directory_listing(raw;default_directory=homedir(),all_files=false,offset=0,limit=500)
    directory=strip(String(raw));isempty(directory)&&(directory=default_directory)
    length(directory)<=32767&&!occursin('\0',directory)||throw(ArgumentError("Invalid folder path"))
    directory=abspath(expanduser(directory));isfile(directory)&&(directory=dirname(directory))
    isdir(directory)||throw(ArgumentError("Folder does not exist or is unavailable: $directory"))
    entries=Dict{String,Any}[]
    for path in readdir(directory;join=true,sort=false)
        info=try stat(path) catch;continue;end
        folder=isdir(info)
        folder||all_files||lowercase(splitext(path)[2]) in (".bdf",".dat",".nas",".bulk",".blk")||continue
        push!(entries,Dict("name"=>basename(path),"path"=>path,"directory"=>folder,"bytes"=>folder ? nothing : info.size))
    end
    sort!(entries;by=row->(!row["directory"],lowercase(row["name"])))
    count=length(entries);offset=clamp(Int(offset),0,count);limit=clamp(Int(limit),1,1000)
    drives=if Sys.iswindows()
        bits=ccall((:GetLogicalDrives,"kernel32"),UInt32,())
        [string(Char(Int('A')+i),":\\") for i in 0:25 if bits & (UInt32(1)<<i)!=0]
    else;["/"];end
    parent=dirname(directory)
    Dict("ok"=>true,"directory"=>directory,"parent"=>parent==directory ? nothing : parent,
        "drives"=>drives,"entries"=>entries[offset+1:min(count,offset+limit)],"offset"=>offset,
        "total"=>count,"next_offset"=>offset+limit<count ? offset+limit : nothing)
end

function handle_import_nastran_browse(st,req)
    try
        query=HTTP.queryparams(HTTP.URI(req.target))
        offset=tryparse(Int,get(query,"offset","0"));offset===nothing&&throw(ArgumentError("Invalid folder page"))
        json_response(imported_directory_listing(get(query,"path","");default_directory=st.root,
            all_files=get(query,"all","0")=="1",offset))
    catch err
        error_response("Browse local files: "*describe_error(err)*". You can also paste the main deck path directly.")
    end
end

function handle_import_nastran(st::AppState,req)
    progress=request_progress(st,req)
    try
        started=time();progress("Reading Nastran source and resolving INCLUDE files automatically")
        source=imported_source(JSON.parse(String(req.body)));source_seconds=time()-started
        repo,_=find_jfem(st.root;hint=String(st.params["jfem.repo"]));repo===nothing&&throw(ArgumentError("JFEM native parser is unavailable; configure the solver repository"))
        base=joinpath(st.deck_store_dir,"imports");mkpath(base);dir=mktempdir(base;prefix="deck_",cleanup=false)
        t=time();Serialization.serialize(joinpath(dir,"input.jls"),(source,st.params));capture_seconds=time()-t
        wait_timings=imported_run_worker(st,repo,dir,progress)
        progress("Loading imported geometry into the viewer")
        t=time();model=Serialization.deserialize(joinpath(dir,"model.jls"));payload=Serialization.deserialize(joinpath(dir,"payload.jls"));restore_seconds=time()-t
        token=bytes2hex(SHA.sha256(source["signature"]*dir));model.params["imported.token"]=token
        lock(IMPORTED_MODELS_LOCK) do
            length(IMPORTED_MODELS)>=16&&delete!(IMPORTED_MODELS,first(keys(IMPORTED_MODELS)))
            IMPORTED_MODELS[token]=model
        end
        payload["imported_deck"]["token"]=token;payload["generate_seconds"]=time()-started
        payload["model_source"]=Dict(key=>source[key] for key in ("kind","name","text","includes"))
        payload["imported_deck"]["source_file_count"]=source["source_file_count"]
        payload["imported_deck"]["source_bytes"]=source["source_bytes"]
        timings=merge(JSON.parsefile(joinpath(dir,"timings.json")),wait_timings,
            Dict("source_seconds"=>source_seconds,"source_capture_seconds"=>capture_seconds,"server_restore_seconds"=>restore_seconds,
                "server_seconds_before_encoding"=>time()-started))
        payload["import_timings"]=timings
        progress("Import timing: source $(round(source_seconds;digits=2)) s; parser/viewport $(round(timings["worker_seconds"];digits=2)) s; worker wait $(round(wait_timings["worker_wait_seconds"];digits=2)) s; restore $(round(restore_seconds;digits=2)) s")
        st.model=model;progress("done")
        return msgpack_response(payload)
    catch err
        return error_response("Read Nastran: "*describe_error(err))
    end
end

function imported_written_deck(st,model)
    base=joinpath(st.deck_store_dir,"imported_decks");mkpath(base)
    dir=mktempdir(base;prefix="deck_",cleanup=false);path=joinpath(dir,basename(model.params["imported.source"]["name"]))
    write(path,model.params["imported.source"]["flattened"])
    publicparams=Dict(k=>v for (k,v) in model.params if !startswith(k,"imported."))
    snapshot=preserve_deck!(st,path,publicparams;source="Imported Nastran source",imported_signature=model.params["imported.source"]["signature"])
    return path,snapshot
end

function handle_imported_nastran(st,model;run=false,start_job=start_jfem_job)
    path,snapshot=imported_written_deck(st,model)
    response=Dict{String,Any}("ok"=>true,"path"=>path,"deck"=>path,"deck_text"=>snapshot["deck_text"],"deck_lines"=>snapshot["lines"],"deck_metadata"=>deck_metadata(snapshot),"solution"=>"SOL "*model.params["output.solution"],"imported_signature"=>model.params["imported.source"]["signature"])
    if run
        st.job_counter+=1;id="job"*string(st.job_counter)
        job=start_job(model,model.params,st.root,path,id);st.jobs[id]=job
        merge!(response,Dict("job"=>id,"out_dir"=>job.outdir,"repo"=>job.repo,"command"=>job.cmdline,"runs"=>Any[]))
    end
    return json_response(response)
end
