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

function handle_import_nastran(st::AppState,req)
    progress=request_progress(st,req)
    try
        source=imported_source(JSON.parse(String(req.body)));progress("import_parser")
        repo,_=find_jfem(st.root;hint=String(st.params["jfem.repo"]));repo===nothing&&throw(ArgumentError("JFEM native parser is unavailable; configure the solver repository"))
        runtime=sensitivity_worker_runtime(repo)
        base=joinpath(st.deck_store_dir,"imports");mkpath(base);dir=mktempdir(base;prefix="deck_",cleanup=false)
        sensitivity_json_write(joinpath(dir,"source.json"),source);sensitivity_json_write(joinpath(dir,"params.json"),st.params)
        command=`$(runtime.command) --startup-file=no --threads=1 --project=$repo $(joinpath(@__DIR__,"nastran_import_worker.jl")) $dir $repo $(st.root)`
        Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
        proc=open(joinpath(dir,"import.log"),"w") do output
            run(pipeline(addenv(command,"OPENBLAS_NUM_THREADS"=>"1");stdout=output,stderr=output);wait=false)
        end
        started=time()
        while process_running(proc)
            if time()-started>300;kill(proc);throw(ArgumentError("Native deck import exceeded five minutes; inspect $(joinpath(dir,"import.log"))"));end
            sleep(.1)
        end
        wait(proc)
        if proc.exitcode!=0
            detail=isfile(joinpath(dir,"error.json")) ? JSON.parsefile(joinpath(dir,"error.json"))["error"] : read(joinpath(dir,"import.log"),String)
            throw(ArgumentError("Native Nastran import failed: $detail"))
        end
        model=Serialization.deserialize(joinpath(dir,"model.jls"));payload=MsgPack.unpack(read(joinpath(dir,"payload.msgpack")))
        token=bytes2hex(SHA.sha256(source["signature"]*dir));model.params["imported.token"]=token
        lock(IMPORTED_MODELS_LOCK) do
            length(IMPORTED_MODELS)>=16&&delete!(IMPORTED_MODELS,first(keys(IMPORTED_MODELS)))
            IMPORTED_MODELS[token]=model
        end
        payload["imported_deck"]["token"]=token;payload["generate_seconds"]=time()-started
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
