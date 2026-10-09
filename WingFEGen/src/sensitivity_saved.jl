# Completed studies are data, not executable serialized models. Discovery and
# import never deserialize model.jls or invoke a solver/mesh rebuild.
function sensitivity_field_descriptor(id)
    id=String(id)
    field=last(split(id,'#'))
    key,label=if startswith(id,"material")&&(endswith(id,".E")||field=="E")
        "material.E","Elastic modulus"
    elseif startswith(id,"material")&&(endswith(id,".nu")||field=="nu")
        "material.nu","Poisson ratio"
    elseif startswith(id,"material")&&(endswith(id,".rho")||field=="rho")
        "material.rho","Material density"
    elseif endswith(id,"face_thickness")
        "shell.face_thickness","Sandwich face thickness"
    elseif endswith(id,"core_thickness")
        "shell.core_thickness","Sandwich core thickness"
    elseif any(endswith(id,f) for f in ("flange_width","flange_thickness","web_thickness","height"))
        f=last(filter(f->endswith(id,f),("flange_width","flange_thickness","web_thickness","height")))
        "section."*f,"T "*replace(f,'_'=>' ')
    elseif id=="properties.spar_cap_side"
        "section.square_side","Square spar cap side"
    else
        "shell.thickness","Shell thickness"
    end
    Dict("field_key"=>key,"field_label"=>label)
end

function sensitivity_variable_label(id,fallback)
    names=("properties.rib_stiffener_"=>"Rib stiffener", "properties.stringer_"=>"Stringer")
    fields=Dict("flange_width"=>"T flange width","height"=>"T overall height",
        "flange_thickness"=>"T flange thickness","web_thickness"=>"T web thickness")
    for (prefix,label) in names
        startswith(id,prefix)||continue
        field=id[length(prefix)+1:end]
        return label*": "*get(fields,field,replace(field,'_'=>' '))
    end
    String(fallback)
end

function sensitivity_scope(m,variables)
    groups=[Dict("pid"=>g.pid,"kind"=>String(g.kind),"name"=>g.name,"eids"=>collect(g.eids)) for g in m.groups]
    scope=Dict{String,Any}("groups"=>groups)
    sensitivity_scope_variables!(scope,variables)
end

function sensitivity_scope_variables!(scope,variables)
    scope["variables"]=Dict{String,Any}()
    for d in variables
        pids=Int.(get(d,"pids",Int[]))
        eids=sort!(unique([Int(eid) for g in scope["groups"] if g["pid"] in pids for eid in g["eids"]]))
        scope["variables"][d["id"]]=Dict("pids"=>pids,"eids"=>eids,"element_count"=>length(eids))
    end
    scope
end

function sensitivity_topology_data(m)
    nodes=sort!([(id=m.node_ids[i],xyz=collect(m.xyz[3i-2:3i])) for i in eachindex(m.node_ids)];by=x->x.id)
    width(g)=g.kind===:quad ? 4 : g.kind===:tria ? 3 : 2
    elements=sort!([(eid=g.eids[i],pid=g.pid,kind=String(g.kind),conn=collect(g.conn[width(g)*(i-1)+1:width(g)*i]))
        for g in m.groups for i in eachindex(g.eids)];by=x->x.eid)
    # Internal connectivity indexes become actual GRID IDs for deck parity.
    elements=[merge(e,(conn=[m.node_ids[i] for i in e.conn],)) for e in elements]
    (nodes=nodes,elements=elements)
end
sensitivity_topology_signature(m)=bytes2hex(SHA.sha256(JSON.json(sensitivity_topology_data(m))))

function sensitivity_saved_directory(params,root)
    path=String(params["jfem.output_dir"])
    abspath(isabspath(path) ? path : joinpath(root,path))
end
sensitivity_same_path(a,b)=Sys.iswindows() ? lowercase(normpath(a))==lowercase(normpath(b)) : normpath(a)==normpath(b)

function sensitivity_saved_run(base,id)
    id isa AbstractString&&occursin(r"^sensitivity_[A-Za-z0-9_]+$",id)||throw(ArgumentError("Choose a saved sensitivity run from the list"))
    isdir(base)||throw(ArgumentError("The configured JFEM output directory does not exist"))
    directory=joinpath(base,id)
    isdir(directory)||throw(ArgumentError("The selected sensitivity run no longer exists"))
    directory=realpath(directory)
    sensitivity_same_path(dirname(directory),realpath(base))||throw(ArgumentError("Saved sensitivity runs must remain inside the configured output directory"))
    directory
end

function sensitivity_saved_file(directory,name,limit)
    path=joinpath(directory,name)
    isfile(path)||throw(ArgumentError("Saved sensitivity run has no $name"))
    sensitivity_same_path(dirname(realpath(path)),realpath(directory))||throw(ArgumentError("Saved sensitivity file points outside its run directory"))
    filesize(path)<=limit||throw(ArgumentError("Saved sensitivity $name exceeds the supported size"))
    path
end

function sensitivity_read_result(directory)
    path=sensitivity_saved_file(directory,"result.json",64*1024*1024)
    result=JSON.parsefile(path)
    result isa AbstractDict&&get(result,"status","") in ("complete","partial")||throw(ArgumentError("This run has no completed sensitivity result"))
    rows=get(result,"rows",nothing)
    rows isa AbstractVector&&1<=length(rows)<=4096||throw(ArgumentError("Saved sensitivity rows are invalid"))
    get(result,"objective",nothing) isa AbstractDict||throw(ArgumentError("Saved sensitivity objective is invalid"))
    for row in rows
        row isa AbstractDict&&get(row,"id",nothing) isa AbstractString||throw(ArgumentError("Saved sensitivity row is invalid"))
        for key in ("derivative","normalized_derivative","value")
            value=get(row,key,nothing)
            value===nothing||(value isa Real&&!(value isa Bool)&&isfinite(value))||throw(ArgumentError("Saved sensitivity $key is not finite"))
        end
        pids=get(row,"pids",Int[])
        pids isa AbstractVector&&length(pids)<=10000&&all(p->p isa Integer&&!(p isa Bool)&&p>0,pids)||throw(ArgumentError("Saved property IDs are invalid"))
        row["label"]=sensitivity_variable_label(row["id"],get(row,"label",row["id"]))
        for (key,value) in sensitivity_field_descriptor(row["id"])
            get!(row,key,value)
        end
    end
    length(unique(row["id"] for row in rows))==length(rows)||throw(ArgumentError("Saved sensitivity variables are duplicated"))
    result
end

function sensitivity_saved_list(params,root)
    base=sensitivity_saved_directory(params,root);runs=Any[];skipped=0
    if isdir(base)
        for id in readdir(base)
            occursin(r"^sensitivity_[A-Za-z0-9_]+$",id)||continue
            try
                directory=sensitivity_saved_run(base,id)
                isfile(joinpath(directory,"result.json"))||continue
                result=sensitivity_read_result(directory)
                modified=stat(joinpath(directory,"result.json")).mtime
                push!(runs,Dict("id"=>id,"label"=>id,"modified_at"=>Dates.format(Dates.unix2datetime(modified),dateformat"yyyy-mm-ddTHH:MM:SS")*"Z",
                    "status"=>result["status"],"case_label"=>get(result,"case_label","Load case"),"objective"=>result["objective"],
                    "baseline"=>get(result,"baseline",nothing),"baseline_analysis"=>sensitivity_baseline_summary(directory),"method"=>get(result,"method","unknown"),"variable_count"=>length(result["rows"])))
            catch
                skipped+=1
            end
        end
    end
    sort!(runs;by=r->r["modified_at"],rev=true)
    Dict("runs"=>runs,"output_dir"=>base,"skipped_unreadable"=>skipped)
end

function sensitivity_deck_topology(directory)
    path=sensitivity_saved_file(directory,"baseline.bdf",64*1024*1024)
    nodes=NamedTuple[];elements=NamedTuple[]
    number(raw)=parse(Float64,replace(strip(raw),r"(?<=[0-9.])([+-][0-9]+)$"=>s"e\1"))
    open(path,"r") do io
      for line in eachline(io)
        isempty(strip(line))&&continue
        startswith(lstrip(line),'$')&&continue
        occursin(r"^(GRID|CQUAD4|CTRIA3|CBAR)(,|[ \t])",line)||continue
        fields=occursin(',',line) ? strip.(split(line,',';keepempty=true)) : [strip(line[i:min(i+7,lastindex(line))]) for i in 1:8:lastindex(line)]
        card=first(fields)
        if card=="GRID"
            length(fields)>=6||error("Incomplete GRID in saved baseline")
            fields[3] in ("","0")||error("Saved baseline uses an unsupported GRID coordinate system")
            push!(nodes,(id=parse(Int,fields[2]),xyz=number.(fields[4:6])))
        elseif card in ("CQUAD4","CTRIA3","CBAR")
            count=card=="CQUAD4" ? 4 : card=="CTRIA3" ? 3 : 2
            length(fields)>=3+count||error("Incomplete element in saved baseline")
            push!(elements,(eid=parse(Int,fields[2]),pid=parse(Int,fields[3]),kind=card=="CQUAD4" ? "quad" : card=="CTRIA3" ? "tria" : "bar",conn=parse.(Int,fields[4:3+count])))
        end
      end
    end
    isempty(nodes)&&error("No GRID entries in saved baseline")
    isempty(elements)&&error("No supported elements in saved baseline")
    length(unique(n.id for n in nodes))==length(nodes)||error("Duplicate GRID IDs in saved baseline")
    length(unique(e.eid for e in elements))==length(elements)||error("Duplicate element IDs in saved baseline")
    (nodes=sort!(nodes;by=n->n.id),elements=sort!(elements;by=e->e.eid))
end

function sensitivity_topology_matches(m,saved)
    current=sensitivity_topology_data(m)
    length(current.nodes)==length(saved.nodes)&&current.elements==saved.elements||return false
    all(a.id==b.id&&all(isapprox.(a.xyz,b.xyz;rtol=2e-12,atol=2e-12)) for (a,b) in zip(current.nodes,saved.nodes))
end

function sensitivity_result_matches_model(result,m)
    m===nothing&&return false
    saved=get(result,"baseline_model_signature",nothing)
    saved isa AbstractString||return false
    version=get(result,"baseline_model_signature_version",1)
    version isa Integer&&!(version isa Bool)&&version in (1,2)||return false
    saved==sensitivity_model_signature(m;version)&&return true
    version==2&&saved==sensitivity_model_signature(m;version,legacy_empty_panels=true)&&return true
    # Added empty metadata/default containers do not change an older model.
    # Test subsets, including both absent together; never drop actual overrides.
    isempty_default(value)=value isa AbstractString ? (isempty(strip(value))||try
        decoded=JSON.parse(value);decoded===nothing||((decoded isa AbstractDict||decoded isa AbstractVector)&&isempty(decoded))
        catch;false;end) : value===nothing||((value isa AbstractDict||value isa AbstractVector)&&isempty(value))
    optional=[key for key in (version==1 ? ("view.drawings","properties.panels") : ("properties.panels",)) if haskey(m.params,key)&&isempty_default(m.params[key])]
    for bits in 1:(2^length(optional)-1)
        params=copy(m.params)
        for (i,key) in enumerate(optional);!iszero(bits&(1<<(i-1)))&&delete!(params,key);end
        saved==sensitivity_model_signature(sensitivity_model(m,params);version)&&return true
    end
    false
end

function sensitivity_saved_load(params,root,id;model=nothing)
    directory=sensitivity_saved_run(sensitivity_saved_directory(params,root),id)
    result=sensitivity_read_result(directory);reasons=String[]
    model_match=sensitivity_result_matches_model(result,model)
    topology_match=false;scope=nothing
    try
        if haskey(params,"imported.source")
            topology_match=imported_saved_topology_matches(directory,model,result)
            scope=model===nothing ? get(result,"scope",nothing) : sensitivity_scope(model,result["rows"])
        else
            saved=sensitivity_deck_topology(directory)
            groups=Any[]
            for (pid,kind) in unique((e.pid,e.kind) for e in saved.elements)
                push!(groups,Dict("pid"=>pid,"kind"=>kind,"eids"=>[e.eid for e in saved.elements if e.pid==pid&&e.kind==kind]))
            end
            scope=sensitivity_scope_variables!(Dict{String,Any}("groups"=>groups),result["rows"])
            topology_match=model!==nothing&&sensitivity_topology_matches(model,saved)
        end
    catch error
        push!(reasons,"The saved table is available; element mapping is unavailable: "*sprint(showerror,error))
    end
    load_version=haskey(params,"imported.native") ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION
    load_match=get(result,"load_application_version",nothing)==load_version
    model_match||push!(reasons,model===nothing ? "Create the current FEM to check saved-result compatibility; the saved table is available now." : "The saved study definition differs from the current FEM.")
    topology_match||push!(reasons,"The saved element topology and coordinates have not been confirmed on the current FEM.")
    load_match||push!(reasons,"Historical result: this study uses a different or unrecorded inertia-moment application convention. Its values have not been recalculated.")
    compatibility=Dict("model_match"=>model_match,"topology_match"=>topology_match,"load_application_match"=>load_match,
        "is_current"=>model_match&&topology_match&&load_match,"map_allowed"=>model_match&&topology_match,
        "reasons"=>reasons,"current_load_application_version"=>load_version)
    result["scope"]=scope;result["compatibility"]=compatibility;result["source_path"]=joinpath(directory,"result.json")
    result["baseline_analysis"]=sensitivity_baseline_summary(directory)
    Dict("result"=>result,"source_path"=>result["source_path"],"compatibility"=>compatibility,"scope"=>scope)
end
