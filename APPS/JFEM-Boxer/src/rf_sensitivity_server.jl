# RF jobs use the existing serialized persistent FE worker and cancellation
# ownership. No second project, package depot or Julia environment is created.
const RF_PRIMAL_TASK_LOCK=ReentrantLock()
const RF_PRIMAL_TASKS=Dict{String,Bool}()
const RF_PRIMAL_EARLY_CANCEL=Dict{String,Float64}()

function rf_prune_early_cancel!(now=time())
    for (key,stamp) in collect(RF_PRIMAL_EARLY_CANCEL)
        now-stamp>120&&delete!(RF_PRIMAL_EARLY_CANCEL,key)
    end
    while length(RF_PRIMAL_EARLY_CANCEL)>512
        oldest=first(keys(RF_PRIMAL_EARLY_CANCEL))
        for key in keys(RF_PRIMAL_EARLY_CANCEL)
            RF_PRIMAL_EARLY_CANCEL[key]<RF_PRIMAL_EARLY_CANCEL[oldest]&&(oldest=key)
        end
        delete!(RF_PRIMAL_EARLY_CANCEL,oldest)
    end
end

"""Evaluate already recovered fields with the authoritative native RF kernels.
No model build, aerodynamic analysis or FE solve occurs on this route."""
function handle_rf_assessment(st,req)
    key="";registered=false
    try
        raw=JSON.parse(String(req.body));raw isa AbstractDict||throw(ArgumentError("RF assessment needs an input object"))
        input=get(raw,"input",raw);input isa AbstractDict||throw(ArgumentError("Invalid RF assessment input"))
        get(input,"catalog_only",false)&&throw(ArgumentError("Use the response catalog for draft enumeration; solved assessments require actual provenance"))
        id=String(get(raw,"request_id",string(objectid(req),"_",time_ns())))
        ncodeunits(id)<=300||throw(ArgumentError("Invalid RF request identifier"))
        key=string(objectid(st),":",id)
        lock(RF_PRIMAL_TASK_LOCK) do
            rf_prune_early_cancel!()
            haskey(RF_PRIMAL_TASKS,key)&&throw(ArgumentError("Duplicate RF assessment request"))
            RF_PRIMAL_TASKS[key]=haskey(RF_PRIMAL_EARLY_CANCEL,key)
            pop!(RF_PRIMAL_EARLY_CANCEL,key,nothing)
            registered=true
        end
        cancelled=()->lock(RF_PRIMAL_TASK_LOCK) do;get(RF_PRIMAL_TASKS,key,false);end
        result=rf_report_assessment(input;cancelled,progress=_ -> yield())
        result["request_id"]=id
        json_response(rf_json_safe(result))
    catch failure
        error_response("RF assessment: "*describe_error(failure))
    finally
        registered&&lock(RF_PRIMAL_TASK_LOCK) do;pop!(RF_PRIMAL_TASKS,key,nothing);end
    end
end

function handle_rf_assessment_cancel(st,req)
    try
        raw=JSON.parse(String(req.body));id=String(get(raw,"request_id",""))
        key=string(objectid(st),":",id)
        active=lock(RF_PRIMAL_TASK_LOCK) do
            if !haskey(RF_PRIMAL_TASKS,key)
                RF_PRIMAL_EARLY_CANCEL[key]=time();rf_prune_early_cancel!();return false
            end
            RF_PRIMAL_TASKS[key]=true;true
        end
        json_response(Dict("ok"=>true,"active"=>active))
    catch failure
        error_response("Cancel RF assessment: "*describe_error(failure))
    end
end

function rf_http_request(req)
    raw=JSON.parse(String(req.body));raw isa AbstractDict||throw(ArgumentError("RF request must be an object"))
    values=get(raw,"parameters",get(raw,"params",nothing))
    values isa AbstractDict||throw(ArgumentError("RF analysis needs the current Study parameters"))
    (haskey(values,"imported_deck")||get(values,"model_kind","")=="reference"||haskey(values,"imported.source"))&&
        throw(ArgumentError("Imported models require physical RF criterion membership and verified imported-load derivatives; a generated wing will not be substituted"))
    params,unknown=normalize_params(values)
    isempty(unknown)||throw(ArgumentError("Unknown RF Study parameter: "*join(unknown,", ")))
    params,Dict{String,Any}(string(k)=>v for (k,v) in raw)
end

function rf_http_model(st,params;progress=_ -> nothing)
    m=st.model
    m!==nothing&&is_imported_model(m)&&throw(ArgumentError("Imported models require physical RF criterion membership and verified imported-load derivatives; a generated wing will not be substituted"))
    if m!==nothing&&!is_imported_model(m)&&sensitivity_definition(m.params)==sensitivity_definition(params)
        return sensitivity_model(m,params)
    end
    migrate_legacy_panel_overrides!(params,m)
    build_model(params;progress)
end

function handle_rf_catalog(st,req)
    try
        params,raw=rf_http_request(req);m=rf_http_model(st,params;progress=request_progress(st,req))
        return json_response(Dict("ok"=>true,"catalog"=>rf_json_safe(rf_assessment_catalog(m,raw))))
    catch failure
        failure isa PanelOverrideConflict&&return panel_override_error_response(failure)
        failure isa MeshQualityError&&return mesh_quality_error_response(failure)
        return error_response("RF response catalog: "*describe_error(failure))
    end
end

function start_rf_sensitivity_job(model,request,root,id;worker_factory=create_solver_worker)
    config=rf_request(model,request);config["rf_analysis"]=true
    repo,_=find_jfem(root;hint=String(model.params["jfem.repo"]))
    repo===nothing&&throw(ArgumentError("JFEM solver repository was not found"))
    base=model.params["jfem.output_dir"];base=isabspath(base) ? base : abspath(joinpath(root,base));mkpath(base)
    dir=mktempdir(base;prefix="rf_sensitivity_"*Dates.format(Dates.now(),"yyyymmdd_HHMMSS_"),cleanup=false)
    Serialization.serialize(joinpath(dir,"model.jls"),model)
    sensitivity_json_write(joinpath(dir,"request.json"),config)
    job=SensitivityJob(String(id),dir,nothing,time(),nothing,:running,"Waiting for the shared Julia solver",model,config,ReentrantLock())
    proxy=JfemJob(String(id),"RF derivatives",joinpath(dir,"baseline.bdf"),dir,joinpath(dir,"sensitivity.log"),
        repo,model,nothing,String[],ReentrantLock(),job.started,nothing,:queued,0,"")
    job.worker_job=proxy
    completion=(proxy,code;failure_reason="")->finish_sensitivity_worker_request!(job,proxy,code;failure_reason)
    launch_jfem_process!(proxy;worker_factory,command="sensitivity",completion)
    job
end

function handle_rf_start(st,req;start_job=start_rf_sensitivity_job)
    lock(st.job_lock)
    try
        any(j.state===:running for j in values(st.jobs))&&throw(ArgumentError("Wait for the current FE analysis before starting RF derivatives"))
        any(j.state===:running for j in values(st.sensitivity_jobs))&&throw(ArgumentError("A derivative job is already running"))
        params,raw=rf_http_request(req);m=rf_http_model(st,params;progress=request_progress(st,req))
        all_checks_pass(m)||throw(ArgumentError("Correct the FEM connectivity checks before RF differentiation"))
        st.job_counter+=1;id="rf"*string(st.job_counter)
        job=start_job(m,raw,st.root,id);st.sensitivity_jobs[id]=job
        json_response(Dict("ok"=>true,"id"=>id,"job"=>id,"state"=>"running","outdir"=>job.outdir))
    catch failure
        failure isa PanelOverrideConflict&&return panel_override_error_response(failure)
        failure isa MeshQualityError&&return mesh_quality_error_response(failure)
        error_response("RF derivatives: "*describe_error(failure))
    finally
        unlock(st.job_lock)
    end
end

function rf_http_job(st,req;post=false)
    raw=post ? JSON.parse(String(req.body)) : HTTP.queryparams(HTTP.URI(req.target))
    id=String(get(raw,"id",get(raw,"job","")))
    haskey(st.sensitivity_jobs,id)||throw(ArgumentError("Unknown RF analysis job"))
    job=st.sensitivity_jobs[id]
    get(job.request,"rf_analysis",false)===true||throw(ArgumentError("The selected job is not an RF analysis"))
    job
end

function handle_rf_status(st,req)
    try
        job=rf_http_job(st,req);enforce_sensitivity_timeout!(job)
        data=lock(job.lk) do
            Dict{String,Any}("ok"=>true,"id"=>job.id,"state"=>String(job.state),"message"=>job.message,
                "seconds"=>(something(job.finished,time())-job.started),"outdir"=>job.outdir)
        end
        path=joinpath(job.outdir,"progress.json")
        if isfile(path);try data["progress"]=JSON.parse(SensitivityFileIO.read_text(path)) catch;end;end
        if job.worker_job!==nothing;data["worker"]=copy(job.worker_job.progress);end
        json_response(data)
    catch failure
        error_response("RF analysis status: "*describe_error(failure))
    end
end

function handle_rf_cancel(st,req)
    try
        job=rf_http_job(st,req;post=true)
        write(joinpath(job.outdir,"cancel.requested"),"cancel")
        cancel_sensitivity_job!(job;message="RF analysis cancelled")
        json_response(Dict("ok"=>true,"id"=>job.id,"state"=>String(job.state)))
    catch failure
        error_response("Cancel RF analysis: "*describe_error(failure))
    end
end

function handle_rf_result(st,req)
    try
        job=rf_http_job(st,req);job.state===:running&&throw(ArgumentError("RF analysis is still running"))
        path=joinpath(job.outdir,"result.json")
        if !isfile(path)
            ep=joinpath(job.outdir,"error.json")
            detail=isfile(ep) ? get(JSON.parsefile(ep),"message",job.message) : job.message
            throw(ArgumentError(detail))
        end
        result=JSON.parse(SensitivityFileIO.read_text(path))
        json_response(Dict("ok"=>true,"id"=>job.id,"result"=>result))
    catch failure
        error_response("RF analysis result: "*describe_error(failure))
    end
end

function handle_rf_download(st,req)
    try
        job=rf_http_job(st,req);q=HTTP.queryparams(HTTP.URI(req.target))
        name=String(get(q,"file","jacobian.csv"))
        name in ("jacobian.csv","jacobian.f64","jacobian_metadata.json","optimized_parameters.json","sizing_checkpoint.json")||
            throw(ArgumentError("Unknown RF export"))
        path=joinpath(job.outdir,name);isfile(path)||throw(ArgumentError("The requested RF export is not available"))
        # Let HTTP own and stream the file handle; a dense Jacobian can be much
        # larger than the application heap. servefile also supports range/HEAD
        # requests and closes its source when transfer completes or aborts.
        response=HTTP.servefile(req,path;redirect_canonical=false,cache_control="no-store")
        HTTP.setheader(response,"Content-Disposition"=>"attachment; filename=\"$name\"")
        response
    catch failure
        error_response("RF export: "*describe_error(failure))
    end
end
