# Discrete adjoint property sensitivities on immutable FE topology.
# Native assembled operators retain warped shells, PCOMP, offset PBARL
# sections and property-dependent body loads.
import Serialization
include("sensitivity_runtime.jl")
include("sensitivity_saved.jl")
include("sensitivity_baseline.jl")
include("sensitivity_analytic_properties.jl")

const SENSITIVITY_OBJECTIVES=Dict(
    "displacement"=>["x","y","z","magnitude"],
    "shell_stress"=>["normal_x","normal_y","shear_xy","von_mises","major","minor"],
    "bar_stress"=>["axial","max","min"],
    "frequency_eigenvalue"=>String[],"buckling_factor"=>String[])

function normalize_sensitivity_settings(raw)
    raw isa AbstractString||throw(ArgumentError("sensitivity.settings must be JSON text"))
    isempty(strip(raw))&&return ""
    ncodeunits(raw)<=1024*1024||throw(ArgumentError("Sensitivity settings exceed 1 MiB"))
    data=try JSON.parse(raw) catch; throw(ArgumentError("Sensitivity settings must contain valid JSON"));end
    data isa AbstractDict||throw(ArgumentError("Sensitivity settings must be an object"))
    allowed=Set(("case_id","objective","variables","relative_step","check_step","derivative_method"))
    all(k->k in allowed,keys(data))||throw(ArgumentError("Unsupported sensitivity setting"))
    vars=get(data,"variables",Any[])
    vars isa AbstractVector&&length(vars)<=4096&&all(x->x isa AbstractString&&ncodeunits(x)<=240,vars)||throw(ArgumentError("Select at most 4096 property variables"))
    objective=get(data,"objective",Dict())
    objective isa AbstractDict&&length(objective)<=8||throw(ArgumentError("Invalid sensitivity objective settings"))
    all(k->k in ("type","node_id","element_id","component","surface","mode"),keys(objective))||throw(ArgumentError("Unsupported sensitivity objective field"))
    haskey(data,"check_step")&&!(data["check_step"] isa Bool)&&throw(ArgumentError("Sensitivity step check must be true or false"))
    get(data,"derivative_method","analytic") in ("analytic","operator_differences")||throw(ArgumentError("Select analytic chain-rule derivatives or legacy operator differences"))
    for (key,lo,hi) in (("case_id",1,49999999),("relative_step",1e-4,.1))
        v=get(data,key,nothing);v in (nothing,"")&&continue
        v isa Real&&!(v isa Bool)&&isfinite(v)&&lo<=v<=hi||throw(ArgumentError("Sensitivity $key is outside its allowed range"))
    end
    return JSON.json(data)
end

function sensitivity_model(m,p)
    register_panel_properties!(p,m.grid)
    Model((f===:params ? p : getfield(m,f) for f in fieldnames(Model))...)
end

function sensitivity_set!(p,d,value)
    path=d["path"];value=Float64(value)*d["scale"]
    if length(path)==4&&path[1]=="properties.panels"
        rows=get!(p,"properties.panels",Any[])
        index=findfirst(row->row["key"]==path[2],rows)
        if index===nothing
            push!(rows,Dict{String,Any}("key"=>path[2],"layout_token"=>d["layout_token"]));index=length(rows)
        end
        get!(rows[index],path[3],Dict{String,Any}())[path[4]]=value
    elseif length(path)==1;p[path[1]]=value
    else;p[path[1]][path[2]][path[3]]=value
    end
    lock(PANEL_PROPERTY_LOCK) do;pop!(PANEL_PROPERTY_CONTEXTS,objectid(p),nothing);end
    return p
end

function sensitivity_catalog(m::Model)
    p=m.params;candidates=Dict{String,Any}[]
    context=register_panel_properties!(p,m.grid)
    add(id,label,path,value,unit;scale=1.)=push!(candidates,Dict{String,Any}(
        "id"=>id,"label"=>sensitivity_variable_label(id,label),"path"=>path,"value"=>Float64(value)/scale,"unit"=>unit,"scale"=>scale))
    for spec in SCHEMA
        key=spec.key
        if spec.kind===:float&&(startswith(key,"properties.")||key in ("leading_edge.t_skin","leading_edge.t_rib"))
            add(key,spec.label,Any[key],p[key],"m")
        end
    end
    for (key,indexfield) in (("properties.ribs","rib"),("properties.spar_bays","bay"))
        for (i,row) in enumerate(p[key]),field in sort!(collect(keys(row)))
            field in (indexfield,"stiffener_enabled")&&continue
            add("$key#$(row[indexfield])#$field","$(uppercasefirst(indexfield)) $(row[indexfield]): $field",Any[key,i,field],row[field],"m")
        end
    end
    for (i,row) in enumerate(p["materials.shells"])
        get(row,"kind","")=="sandwich"||continue
        for field in ("face_thickness","core_thickness")
            add("materials.shells#$(row["component"])#$field","$(row["component"]): $field",Any["materials.shells",i,field],row[field],"m")
        end
    end
    for (field,unit,scale) in (("E","GPa",1e9),("nu","1",1.),("rho","kg/m3",1.))
        add("material.$field","$(p["material.name"]): $field",Any["material.$field"],p["material.$field"],unit;scale)
        for (i,row) in enumerate(p["materials.library"])
            add("materials.library#$(row["id"])#$field","$(row["name"]): $field",Any["materials.library",i,field],row[field],unit;scale)
        end
    end
    # Resolve actual property ownership, including sparse panel overrides.
    # No trial values are needed to discover which cards a variable controls.
    definitions=model_property_definitions(m)
    baseline=Dict(d["pid"]=>d for d in definitions);variables=Dict{String,Any}[]
    for d in candidates
        ids=sort!(collect(keys(sensitivity_analytic_property_directions(m,d;properties=definitions))))
        isempty(ids)&&continue
        d["pids"]=ids;d["element_count"]=sum(length(g.eids) for g in m.groups if g.pid in ids)
        d["group"]=startswith(d["id"],"material") ? "Materials" : any(baseline[pid]["kind"]=="bar" for pid in ids) ? "Beam sections" : "Shell properties"
        merge!(d,sensitivity_field_descriptor(d["id"]))
        push!(variables,d)
    end
    # Independent local variables also exist when the current value is inherited.
    # Their exact one-property scope is known without O(panel_count^2) probes.
    for panel in stiffened_panel_layout(m.grid).panels
        haskey(baseline,panel.shell_pid)&&haskey(baseline,panel.stringer_pid)||continue
        key=panel_key(panel);label="P$(panel.id) · $(panel.upper ? "Upper" : "Lower") R$(panel.bay)–R$(panel.bay+1), stringer $(panel.stringer)"
        inherited=inherited_panel_properties(p,panel.upper);override=get(context.rows,panel.id,Dict())
        skin=merge(inherited.skin,get(override,"skin",Dict()));bar=merge(inherited.stringer,get(override,"stringer",Dict()))
        fields=skin["kind"]=="sandwich" ? ("face_thickness","core_thickness") : ("thickness",)
        for (part,field,pid,value) in vcat([( "skin",f,panel.shell_pid,skin[f]) for f in fields],
                [("stringer",f,panel.stringer_pid,bar[f]) for f in RIB_STIFFENER_FIELDS])
            fieldkey=(part=="skin" ? "shell." : "section.")*field
            fieldlabel=part=="skin" ? (field=="thickness" ? "Shell thickness" : "Sandwich "*replace(field,'_'=>' ')) : "T "*replace(field,'_'=>' ')
            push!(variables,Dict{String,Any}("id"=>"properties.panels#$key#$part#$field",
                "label"=>label*": "*fieldlabel,"path"=>Any["properties.panels",key,part,field],
                "value"=>Float64(value),"unit"=>"m","scale"=>1.,"pids"=>[pid],
                "element_count"=>sum(length(g.eids) for g in m.groups if g.pid==pid),
                "group"=>part=="skin" ? "Panel skins" : "Panel stringers",
                "panel_key"=>key,"layout_token"=>context.token,"field_key"=>fieldkey,"field_label"=>fieldlabel,
                "inherited"=>!haskey(get(override,part,Dict()),field)))
        end
    end
    return Dict{String,Any}("variables"=>variables,"max_variables"=>4096,"objectives"=>SENSITIVITY_OBJECTIVES,
        "cases"=>[Dict("id"=>s.id,"label"=>s.label) for s in load_case_specs(p)],
        "surfaces"=>["z1","z2"],"method"=>"discrete_adjoint",
        "note"=>"Fixed nodes, connectivity and property IDs. Every stiffened panel offers independent skin thickness or sandwich face/core dimensions and T-section dimensions, including values inherited from shared defaults. Shared defaults remain separate overlapping variables; do not sum them with panel-local derivatives. Analytic mode uses exact element chain rules with one baseline analysis and a shared static adjoint, without property finite differences. SOL103 uses the chosen case's fuel mass; SOL105 uses its static preload.")
end

function sensitivity_request(m,raw)
    raw isa AbstractDict||throw(ArgumentError("Sensitivity request must be an object"))
    normalize_sensitivity_settings(JSON.json(raw))
    request=Dict{String,Any}(String(k)=>v for (k,v) in raw)
    case=get(request,"case_id",1);case isa Integer&&!(case isa Bool)||throw(ArgumentError("Select a load case"))
    spec=findfirst(s->s.id==case,load_case_specs(m.params));spec===nothing&&throw(ArgumentError("The selected load case is not enabled"))
    vars=get(request,"variables",Any[]);!isempty(vars)&&length(unique(vars))==length(vars)||throw(ArgumentError("Select 1 to 4096 distinct property variables"))
    catalog=sensitivity_catalog(m);available=Dict(d["id"]=>d for d in catalog["variables"])
    all(id->haskey(available,id),vars)||throw(ArgumentError("A selected property is no longer active on this mesh; refresh the sensitivity setup"))
    obj=Dict{String,Any}(get(request,"objective",Dict()));kind=get(obj,"type","")
    haskey(SENSITIVITY_OBJECTIVES,kind)||throw(ArgumentError("Select a sensitivity objective"))
    if kind=="displacement"
        get(obj,"node_id",0) in m.node_ids||throw(ArgumentError("Objective node ID is not in this model"))
        get(obj,"component","") in SENSITIVITY_OBJECTIVES[kind]||throw(ArgumentError("Choose displacement x, y, z or magnitude"))
    elseif kind in ("shell_stress","bar_stress")
        eid=get(obj,"element_id",0);g=findfirst(g->eid in g.eids,m.groups)
        g!==nothing&&(kind=="bar_stress" ? m.groups[g].kind==:bar : m.groups[g].kind in (:quad,:tria))||throw(ArgumentError("Choose an element of the objective's type"))
        get(obj,"component","") in SENSITIVITY_OBJECTIVES[kind]||throw(ArgumentError("Choose a supported stress component"))
        if kind=="shell_stress";get!(obj,"surface","z1") in ("z1","z2")||throw(ArgumentError("Choose shell fiber z1 or z2"));end
    else
        mode=get(obj,"mode",1);mode isa Integer&&!(mode isa Bool)&&1<=mode<=20||throw(ArgumentError("Mode must be 1 to 20"));obj["mode"]=mode
    end
    request["objective"]=obj;request["case_id"]=case
    request["derivative_method"]=get(request,"derivative_method","analytic")
    step=get(request,"relative_step",.01)
    request["derivative_method"]=="analytic"&&(step===nothing||step=="")&&(step=.01)
    step isa Real&&!(step isa Bool)&&isfinite(step)&&1e-4<=step<=.1||throw(ArgumentError("Set a sensitivity step between 0.01% and 10%"))
    request["relative_step"]=Float64(step);request["check_step"]=get(request,"check_step",true)
    if request["derivative_method"]=="operator_differences"
        for id in vars;sensitivity_stencil(m,available[id],request["relative_step"]);end
    end
    return request
end

mutable struct SensitivityJob
    id::String
    outdir::String
    proc::Union{Nothing,Base.Process}
    started::Float64
    finished::Union{Nothing,Float64}
    state::Symbol
    message::String
    model::Model
    request::Dict{String,Any}
    lk::ReentrantLock
end

function sensitivity_json_write(path,data)
    tmp=path*".tmp";write(tmp,JSON.json(data));mv(tmp,path;force=true)
end

function start_sensitivity_job(model,request,root,id)
    config=sensitivity_request(model,request)
    repo,_=find_jfem(root;hint=String(model.params["jfem.repo"]))
    repo===nothing&&throw(ArgumentError("JFEM solver repository was not found"))
    runtime=sensitivity_worker_runtime(repo)
    base=model.params["jfem.output_dir"];base=isabspath(base) ? base : abspath(joinpath(root,base));mkpath(base)
    dir=mktempdir(base;prefix="sensitivity_"*Dates.format(Dates.now(),"yyyymmdd_HHMMSS_"),cleanup=false)
    Serialization.serialize(joinpath(dir,"model.jls"),model)
    sensitivity_json_write(joinpath(dir,"request.json"),config)
    sensitivity_json_write(joinpath(dir,"runtime.json"),runtime.metadata)
    job=SensitivityJob(String(id),dir,nothing,time(),nothing,:running,"Starting sensitivity worker",model,config,ReentrantLock())
    command=`$(runtime.command) --startup-file=no --threads=1 --project=$repo $(joinpath(@__DIR__,"sensitivity_worker.jl")) $dir $repo`
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    output=open(joinpath(dir,"sensitivity.log"),"w")
    try
        job.proc=run(pipeline(addenv(command,"OPENBLAS_NUM_THREADS"=>"1","JULIA_NUM_THREADS"=>"1");stdout=output,stderr=output);wait=false)
    finally;close(output);end
    Threads.@spawn begin
        timeout=60clamp(Int(model.params["jfem.timeout_minutes"]),1,120)
        while process_running(job.proc)
            sleep(.25)
            if time()-job.started>timeout
                cancel_sensitivity_job!(job;message="Sensitivity study exceeded its $(timeout÷60)-minute budget",state=:failed);break
            end
        end
        try wait(job.proc) catch end
        lock(job.lk) do
            if job.state===:running
                job.state=job.proc.exitcode==0&&isfile(joinpath(dir,"result.json")) ?
                    (get(JSON.parsefile(joinpath(dir,"result.json")),"status","")=="partial" ? :partial : :done) : :failed
                job.message=job.state===:done ? "Sensitivity study completed" : job.state===:partial ? "Sensitivity study completed with unavailable derivatives; inspect the affected rows" : "Sensitivity worker failed; inspect its log"
                if job.state===:failed&&isfile(joinpath(dir,"error.json"))
                    try job.message=String(JSON.parsefile(joinpath(dir,"error.json"))["message"]) catch end
                end
            end
            job.finished=time()
        end
    end
    return job
end

function cancel_sensitivity_job!(job;message="Sensitivity study cancelled",state=:cancelled)
    lock(job.lk) do
        job.state===:running||return job
        job.state=state;job.message=message;job.finished=time()
        # This is the directly owned worker process, never a global process search.
        if job.proc!==nothing&&process_running(job.proc)
            try kill(job.proc) catch error;process_running(job.proc)&&rethrow(error);end
        end
    end
    return job
end

function sensitivity_status(job)
    lock(job.lk) do
        result=Dict{String,Any}("id"=>job.id,"state"=>String(job.state),"message"=>job.message,
            "seconds"=>(job.finished===nothing ? time() : job.finished)-job.started,
            "outdir"=>job.outdir,"request"=>job.request)
        if isfile(joinpath(job.outdir,"baseline_manifest.json"))
            try result["baseline_analysis"]=sensitivity_baseline_metadata(job.outdir) catch end
        end
        for (key,file) in (("progress","progress.json"),("result","result.json"),("error","error.json"))
            path=joinpath(job.outdir,file)
            if isfile(path)
                try result[key]=JSON.parsefile(path) catch end
            end
        end
        log=joinpath(job.outdir,"sensitivity.log")
        if isfile(log)
            result["log"]=open(log,"r") do io
                seekend(io);bytes=position(io);seek(io,max(0,bytes-16384));String(read(io))
            end
        else;result["log"]="";end
        return result
    end
end
