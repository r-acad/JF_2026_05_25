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
        worker=(process=process,queue=queue,lock=ReentrantLock())
        IMPORT_WORKERS[key]=worker
        worker
    end
end

function imported_run_worker(st,repo,dir,progress)
    worker=imported_worker(st,repo)
    lock(worker.lock) do
        process_running(worker.process)||throw(ArgumentError("Import worker stopped; try Read Nastran again"))
        progress("Starting native parser (first import compiles the parser; later imports reuse it)")
        temporary=joinpath(worker.queue,"request.tmp")
        write(temporary,dir);mv(temporary,joinpath(worker.queue,"request.txt");force=true)
        laststage=""
        while !isfile(joinpath(dir,"done.txt"))
            if !process_running(worker.process)
                detail=read(joinpath(worker.queue,"worker.log"),String)
                throw(ArgumentError("Native parser process stopped. $detail"))
            end
            stagefile=joinpath(dir,"stage.txt")
            if isfile(stagefile)
                stage=read(stagefile,String)
                !isempty(stage)&&stage!=laststage&&(progress(stage);laststage=stage)
            end
            sleep(.1)
        end
        isfile(joinpath(dir,"error.json"))&&throw(ArgumentError("Native Nastran import failed: "*String(JSON.parsefile(joinpath(dir,"error.json"))["error"])))
    end
end

function handle_import_nastran_pick(st,req)
    Sys.iswindows()||return error_response("The server file picker is available on Windows. Enter the full local file path instead.")
    # The app binds only to localhost. A native file dialog preserves the full
    # selected path, which browser File objects deliberately do not expose.
    script="Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Application]::EnableVisualStyles(); \$dialog = New-Object System.Windows.Forms.OpenFileDialog; \$dialog.Title = 'Read Nastran (INCLUDE files are read automatically)'; \$dialog.Filter = 'Nastran files (*.bdf;*.dat;*.nas)|*.bdf;*.dat;*.nas|All files (*.*)|*.*'; if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; [Console]::Write(\$dialog.FileName) }; \$dialog.Dispose()"
    try
        command=Cmd(`powershell.exe -NoProfile -STA -Command $script`;windows_hide=true)
        path=strip(read(command,String))
        json_response(Dict("ok"=>true,"path"=>isempty(path) ? nothing : path,"cancelled"=>isempty(path)))
    catch err
        error_response("Could not open the native file picker: "*describe_error(err)*". Enter the full file path instead.")
    end
end

function handle_import_nastran(st::AppState,req)
    progress=request_progress(st,req)
    try
        started=time();progress("Reading Nastran source and resolving INCLUDE files automatically")
        source=imported_source(JSON.parse(String(req.body)))
        repo,_=find_jfem(st.root;hint=String(st.params["jfem.repo"]));repo===nothing&&throw(ArgumentError("JFEM native parser is unavailable; configure the solver repository"))
        base=joinpath(st.deck_store_dir,"imports");mkpath(base);dir=mktempdir(base;prefix="deck_",cleanup=false)
        Serialization.serialize(joinpath(dir,"input.jls"),(source,st.params))
        imported_run_worker(st,repo,dir,progress)
        progress("Loading imported geometry into the viewer")
        model=Serialization.deserialize(joinpath(dir,"model.jls"));payload=Serialization.deserialize(joinpath(dir,"payload.jls"))
        token=bytes2hex(SHA.sha256(source["signature"]*dir));model.params["imported.token"]=token
        lock(IMPORTED_MODELS_LOCK) do
            length(IMPORTED_MODELS)>=16&&delete!(IMPORTED_MODELS,first(keys(IMPORTED_MODELS)))
            IMPORTED_MODELS[token]=model
        end
        payload["imported_deck"]["token"]=token;payload["generate_seconds"]=time()-started
        payload["model_source"]=Dict(key=>source[key] for key in ("kind","name","text","includes"))
        payload["imported_deck"]["source_file_count"]=source["source_file_count"]
        payload["imported_deck"]["source_bytes"]=source["source_bytes"]
        payload["import_timings"]=JSON.parsefile(joinpath(dir,"timings.json"))
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
