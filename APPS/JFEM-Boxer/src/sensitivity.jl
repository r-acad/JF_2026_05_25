# Discrete adjoint property sensitivities on immutable FE topology.
# Native assembled operators retain warped shells, PCOMP, offset PBARL
# sections and property-dependent body loads.
import Serialization
include("sensitivity_runtime.jl")
include("sensitivity_saved.jl")
include("sensitivity_baseline.jl")
include("sensitivity_analytic_properties.jl")
include("sensitivity_selection.jl")

const SENSITIVITY_OBJECTIVES=Dict(
    "displacement"=>["x","y","z","magnitude"],
    "shell_stress"=>["normal_x","normal_y","shear_xy","von_mises","major","minor"],
    "bar_stress"=>["axial","max","min"],
    "frequency_eigenvalue"=>String[],"buckling_factor"=>String[])

# Saved studies before the explicit solution selector inferred the sequence
# from the response. Preserve that meaning instead of adopting a different FE
# Analysis selection when an old study is reopened.
sensitivity_solution(request)=string(get(request,"solution",
    get(get(request,"objective",Dict()),"type","")=="frequency_eigenvalue" ? "103" :
    get(get(request,"objective",Dict()),"type","")=="buckling_factor" ? "105" : "101"))

function sensitivity_solutions(m)
    imported=is_imported_model(m);cases=load_case_specs(m.params);ids=[s.id for s in cases]
    definitions=(("101","SOL101 · Linear static",["displacement","shell_stress","bar_stress"]),
        ("103","SOL103 · Normal modes",["frequency_eigenvalue"]),
        ("105","SOL105 · Linear buckling",["buckling_factor"]),
        ("106","SOL106 · Nonlinear static",["displacement"]))
    result=Dict{String,Any}()
    for (sol,label,objectives) in definitions
        available=true
        reasons=Dict{String,String}()
        if !imported&&sol in ("105","106")
            for spec in cases
                get(spec.params,"loads.follower_forces",false)||continue
                reasons[string(spec.id)]=sol=="105" ? "SOL105 sensitivities require a fixed-direction preload. Disable follower forces in this load case." :
                    "SOL106 displacement adjoints currently require fixed-direction loads. Disable follower forces in this load case."
            end
        end
        result[sol]=Dict("label"=>label,"available"=>available,"objectives"=>objectives,
            "case_ids"=>[id for id in ids if !haskey(reasons,string(id))],"case_reasons"=>reasons,
            "reason"=>"","note"=>sol=="106" ? "Final-load displacement: one converged SOL106 baseline and one exact residual transpose adjoint. Supported geometric shell/CBAR formulations require fixed-direction loads and homogeneous constraints; unsupported branches report an explicit error." :
                sol=="105" ? "Buckling factor: static preload, eigenproblem and one preload adjoint. The preload remains available in FE Results." :
                sol=="103" ? "Modal eigenvalue: the selected mode of the structural mass and stiffness matrices. No second equilibrium solve is required." :
                "Linear static displacement or stress: one baseline and one shared transpose adjoint.")
    end
    result
end

function normalize_sensitivity_settings(raw)
    raw isa AbstractString||throw(ArgumentError("sensitivity.settings must be JSON text"))
    isempty(strip(raw))&&return ""
    data=try JSON.parse(raw) catch; throw(ArgumentError("Sensitivity settings must contain valid JSON"));end
    data isa AbstractDict||throw(ArgumentError("Sensitivity settings must be an object"))
    allowed=Set(("case_id","solution","objective","variables","relative_step","check_step","derivative_method"))
    all(k->k in allowed,keys(data))||throw(ArgumentError("Unsupported sensitivity setting"))
    vars=get(data,"variables",Any[])
    vars isa AbstractVector&&all(x->x isa AbstractString&&!isempty(x)&&ncodeunits(x)<=240,vars)||throw(ArgumentError("Sensitivity variables must be valid property IDs"))
    objective=get(data,"objective",Dict())
    objective isa AbstractDict&&length(objective)<=8||throw(ArgumentError("Invalid sensitivity objective settings"))
    all(k->k in ("type","node_id","element_id","component","surface","mode"),keys(objective))||throw(ArgumentError("Unsupported sensitivity objective field"))
    sensitivity_solution(data) in ("101","103","105","106")||throw(ArgumentError("Sensitivity analysis supports SOL101, SOL103, SOL105 and SOL106"))
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
    elseif length(path)==3&&path[1]=="properties.components"&&path[2] isa AbstractString
        rows=get!(p,"properties.components",Any[])
        index=findfirst(row->row["key"]==path[2],rows)
        if index===nothing
            push!(rows,Dict{String,Any}("key"=>path[2]));index=length(rows)
        end
        rows[index][path[3]]=value
    elseif length(path)==1;p[path[1]]=value
    else;p[path[1]][path[2]][path[3]]=value
    end
    lock(PANEL_PROPERTY_LOCK) do;pop!(PANEL_PROPERTY_CONTEXTS,objectid(p),nothing);end
    return p
end

function sensitivity_catalog(m::Model)
    is_imported_model(m)&&return imported_sensitivity_catalog(m)
    p=m.params;candidates=Dict{String,Any}[]
    context=register_panel_properties!(p,m.grid)
    add(id,label,path,value,unit;scale=1.)=push!(candidates,Dict{String,Any}(
        "id"=>id,"label"=>sensitivity_variable_label(id,label),"path"=>path,"value"=>Float64(value)/scale,"unit"=>unit,"scale"=>scale))
    for spec in SCHEMA
        key=spec.key
        # Shell width/height move GRID points; flange thickness changes blade
        # depth. Those require shape derivatives, outside this fixed-grid API.
        shell_stringers(p)&&key in ("properties.stringer_flange_width","properties.stringer_height","properties.stringer_flange_thickness")&&continue
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
        directions=sensitivity_analytic_property_directions(m,d;properties=definitions)
        any(!isempty(get(direction,"unsupported_reason","")) for direction in values(directions))&&continue
        ids=sort!(collect(keys(directions)))
        isempty(ids)&&continue
        d["pids"]=ids;d["element_count"]=sum(length(g.eids) for g in m.groups if g.pid in ids)
        d["group"]=startswith(d["id"],"material") ? "Materials" : any(baseline[pid]["kind"]=="bar" for pid in ids) ? "Beam sections" : "Shell properties"
        merge!(d,sensitivity_field_descriptor(d["id"]))
        push!(variables,d)
    end
    # Physical spar-bay and rib identities are permanent, including inherited
    # values. Resolve their dimensions directly from the actual property card;
    # this also covers effective sandwich cores inherited from legacy totals.
    element_counts=Dict{Int,Int}()
    for g in m.groups;element_counts[g.pid]=get(element_counts,g.pid,0)+length(g.eids);end
    for property in definitions
        pid=property["pid"];part=component_table_part(pid);part===nothing&&continue
        index=pid%COMPONENT_PID_STRIDE;key=component_table_key(part,index)
        override=component_table_override(p,pid)
        label=uppercasefirst(replace(part,'_'=>' '))*" "*(component_table_isrib(part) ? "R$index" : "R$(index)–R$(index+1)")
        fields=component_table_iscap(part) ? [("side",first(property["section"]["dimensions_m"]))] :
            part=="rib_stiffener" ? collect(zip(RIB_STIFFENER_FIELDS,property["section"]["dimensions_m"])) :
            property["type"]=="PCOMP" ? [("face_thickness",property["face_thickness_m"]),("core_thickness",property["core_thickness_m"])] :
            [("thickness",property["thickness_m"])]
        for (field,value) in fields
            id="properties.components#$key#$field";descriptor=sensitivity_field_descriptor(id)
            push!(variables,merge(Dict{String,Any}("id"=>id,"label"=>label*": "*descriptor["field_label"],
                "path"=>Any["properties.components",key,field],"value"=>Float64(value),"unit"=>"m","scale"=>1.,
                "pids"=>[pid],"element_count"=>element_counts[pid],"component_key"=>key,
                "group"=>"Component "*(property["kind"]=="bar" ? "sections" : "shells"),
                "inherited"=>!haskey(override,field)),descriptor))
        end
    end
    flange_dependents=Dict{Int,Vector{Dict{String,Any}}}()
    for property in definitions
        get(property,"combined_flange",false)||continue
        for skinpid in property["underlying_skin_candidates"]
            push!(get!(flange_dependents,skinpid,Dict{String,Any}[]),property)
        end
    end
    # Independent local variables also exist when the current value is inherited.
    # Their exact one-property scope is known without O(panel_count^2) probes.
    for panel in stiffened_panel_layout(m.grid).panels
        stringer_pid=shell_stringers(p) ? panel_stringer_web_pid(panel.id) : panel.stringer_pid
        haskey(baseline,panel.shell_pid)&&haskey(baseline,stringer_pid)||continue
        key=panel_key(panel);label="P$(panel.id) · $(panel.upper ? "Upper" : "Lower") R$(panel.bay)–R$(panel.bay+1), stringer $(panel.stringer)"
        inherited=inherited_panel_properties(p,panel.upper);override=get(context.rows,panel.id,Dict())
        skin=merge(inherited.skin,get(override,"skin",Dict()));bar=merge(inherited.stringer,get(override,"stringer",Dict()))
        fields=skin["kind"]=="sandwich" ? ("face_thickness","core_thickness") : ("thickness",)
        for (part,field,pid,value) in vcat([( "skin",f,panel.shell_pid,skin[f]) for f in fields],
                [("stringer",f,stringer_pid,bar[f]) for f in (shell_stringers(p) ? ("web_thickness",) : RIB_STIFFENER_FIELDS)])
            fieldkey=(part=="skin" ? "shell." : "section.")*field
            fieldlabel=part=="skin" ? (field=="thickness" ? "Shell thickness" : "Sandwich "*replace(field,'_'=>' ')) : (shell_stringers(p) ? "Shell stringer " : "T ")*replace(field,'_'=>' ')
            variable=Dict{String,Any}("id"=>"properties.panels#$key#$part#$field",
                "label"=>label*": "*fieldlabel,"path"=>Any["properties.panels",key,part,field],
                "value"=>Float64(value),"unit"=>"m","scale"=>1.,"pids"=>[pid],
                "element_count"=>element_counts[pid],
                "group"=>part=="skin" ? "Panel skins" : "Panel stringers",
                "panel_key"=>key,"layout_token"=>context.token,"field_key"=>fieldkey,"field_label"=>fieldlabel,
                "inherited"=>!haskey(get(override,part,Dict()),field))
            if shell_stringers(p)&&part=="skin"
                scoped=vcat([baseline[pid]],get(flange_dependents,pid,Dict{String,Any}[]))
                directions=sensitivity_analytic_property_directions(m,variable;properties=scoped)
                any(!isempty(get(direction,"unsupported_reason","")) for direction in values(directions))&&continue
                variable["pids"]=sort!(collect(keys(directions)))
                variable["element_count"]=sum(get(element_counts,id,0) for id in variable["pids"])
            end
            push!(variables,variable)
        end
    end
    selection=sensitivity_selection_metadata(m,variables)
    return Dict{String,Any}("variables"=>variables,"max_variables"=>length(variables),"objectives"=>SENSITIVITY_OBJECTIVES,"solutions"=>sensitivity_solutions(m),
        "selection_replacements"=>selection.replacements,"selection_aliases"=>selection.aliases,
        "cases"=>[Dict("id"=>s.id,"label"=>s.label) for s in load_case_specs(p)],
        "surfaces"=>["z1","z2"],"method"=>"discrete_adjoint",
        "note"=>"Fixed nodes, connectivity and property IDs. Every stiffened panel, spar-web bay, upper/lower front/rear spar-cap bay, rib web/stiffener and leading-edge skin bay/rib offers independent section or shell dimensions, including inherited defaults. Component-family selections expand to local bay/rib derivatives, including overridden values; material and panel selections retain their original scope. Analytic mode uses exact element chain rules with one baseline analysis and a shared static adjoint, without property finite differences. SOL103 uses the chosen case's fuel mass; SOL105 uses its static preload."*
            (shell_stringers(p) ? " Shell stringers expose web thickness and material variables. Flange width, overall height and flange thickness change blade/skin geometry and are excluded from fixed-mesh property sensitivities. Skin variables also affect the combined flange that inherits that skin. Independent thickness variables at a tied thinnest-skin boundary are omitted because the minimum is not differentiable; shared thickness changes remain available. Combined PCOMP flanges require explicit operator differences; exact adjoints do not yet support their unsymmetric or offset laminate coupling." : ""))
end

function sensitivity_request(m,raw)
    raw isa AbstractDict||throw(ArgumentError("Sensitivity request must be an object"))
    normalize_sensitivity_settings(JSON.json(raw))
    request=Dict{String,Any}(String(k)=>v for (k,v) in raw)
    case=get(request,"case_id",1);case isa Integer&&!(case isa Bool)||throw(ArgumentError("Select a load case"))
    spec=findfirst(s->s.id==case,load_case_specs(m.params));spec===nothing&&throw(ArgumentError("The selected load case is not enabled"))
    vars=get(request,"variables",Any[]);!isempty(vars)&&length(unique(vars))==length(vars)||throw(ArgumentError("Select at least one distinct property variable"))
    catalog=sensitivity_catalog(m);available=Dict(d["id"]=>d for d in catalog["variables"])
    vars=sensitivity_expand_selection(catalog,vars)
    all(id->haskey(available,id),vars)||throw(ArgumentError("A selected property is no longer active on this mesh; refresh the sensitivity setup"))
    request["variables"]=vars
    obj=Dict{String,Any}(get(request,"objective",Dict()));kind=get(obj,"type","")
    haskey(SENSITIVITY_OBJECTIVES,kind)||throw(ArgumentError("Select a sensitivity objective"))
    solution=sensitivity_solution(request);options=catalog["solutions"][solution]
    options["available"]||throw(ArgumentError(options["reason"]))
    kind in options["objectives"]||throw(ArgumentError("Objective $kind is not available for SOL$solution. Select a compatible objective."))
    case in options["case_ids"]||throw(ArgumentError(get(options["case_reasons"],string(case),"The selected case is not available for SOL$solution sensitivity")))
    request["solution"]=solution
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
    if request["derivative_method"]=="analytic"&&any(get(property,"combined_flange",false)&&property["type"]=="PCOMP" for property in model_property_definitions(m))
        throw(ArgumentError("Exact analytic sensitivities do not yet support combined PCOMP attached flanges (different skin/flange materials, composite construction, or inward offsets). Primal analyses retain their full coupling. Choose the explicit operator-differences method for supported linear sensitivity cases, or use same-material centered monolithic flanges."))
    end
    is_imported_model(m)&&request["derivative_method"]!="analytic"&&throw(ArgumentError("Imported-deck sensitivities require analytic derivatives"))
    solution=="106"&&request["derivative_method"]!="analytic"&&throw(ArgumentError("SOL106 sensitivities require the analytic nonlinear displacement adjoint"))
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

isdefined(@__MODULE__,:SensitivityFileIO)||include("sensitivity_io.jl")
function sensitivity_json_write(path,data)
    SensitivityFileIO.write_text(path,JSON.json(data))
end

function finish_sensitivity_job!(job;monitor_error=nothing)
    lock(job.lk) do
        try
            if job.state===:running
                monitor_error===nothing||throw(monitor_error)
                path=joinpath(job.outdir,"result.json")
                job.state=job.proc.exitcode==0&&isfile(path) ?
                    (get(JSON.parse(SensitivityFileIO.read_text(path)),"status","")=="partial" ? :partial : :done) : :failed
                job.message=job.state===:done ? "Sensitivity study completed" : job.state===:partial ?
                    "Sensitivity study completed with unavailable derivatives; inspect the affected rows" : "Sensitivity worker failed; inspect its log"
                if job.state===:failed&&isfile(joinpath(job.outdir,"error.json"))
                    job.message=String(JSON.parse(SensitivityFileIO.read_text(joinpath(job.outdir,"error.json")))["message"])
                end
            end
        catch failure
            job.state=:failed
            job.message="Sensitivity result/status could not be read: "*sprint(showerror,failure)*". Inspect sensitivity.log for the original worker error."
        finally
            job.finished===nothing&&(job.finished=time())
        end
    end
    job
end

function start_sensitivity_job(model,request,root,id)
    config=sensitivity_request(model,request)
    repo,_=find_jfem(root;hint=String(model.params["jfem.repo"]))
    repo===nothing&&throw(ArgumentError("JFEM solver repository was not found"))
    runtime=sensitivity_worker_runtime(repo;select_image=true)
    base=model.params["jfem.output_dir"];base=isabspath(base) ? base : abspath(joinpath(root,base));mkpath(base)
    dir=mktempdir(base;prefix="sensitivity_"*Dates.format(Dates.now(),"yyyymmdd_HHMMSS_"),cleanup=false)
    Serialization.serialize(joinpath(dir,"model.jls"),model)
    sensitivity_json_write(joinpath(dir,"request.json"),config)
    sensitivity_json_write(joinpath(dir,"runtime.json"),runtime.metadata)
    job=SensitivityJob(String(id),dir,nothing,time(),nothing,:running,"Starting sensitivity worker",model,config,ReentrantLock())
    command=`$(runtime.command) $(runtime.sysimage_args) --startup-file=no --threads=1 --project=$repo $(joinpath(@__DIR__,"sensitivity_worker.jl")) $dir $repo`
    Sys.iswindows()&&(command=Cmd(command;windows_hide=true))
    output=open(joinpath(dir,"sensitivity.log"),"w")
    try
        job.proc=run(pipeline(addenv(command,"OPENBLAS_NUM_THREADS"=>"1","JULIA_NUM_THREADS"=>"1");stdout=output,stderr=output);wait=false)
    finally;close(output);end
    Threads.@spawn begin
        monitor_error=nothing
        try
            timeout=60clamp(Int(model.params["jfem.timeout_minutes"]),1,120)
            while process_running(job.proc)
                sleep(.25)
                if time()-job.started>timeout
                    cancel_sensitivity_job!(job;message="Sensitivity study exceeded its $(timeout÷60)-minute budget",state=:failed);break
                end
            end
            try wait(job.proc) catch end
        catch failure
            monitor_error=failure
        finally
            finish_sensitivity_job!(job;monitor_error)
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
                try result[key]=JSON.parse(SensitivityFileIO.read_text(path)) catch end
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
