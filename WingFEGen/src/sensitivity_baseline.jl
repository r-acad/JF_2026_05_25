# A sensitivity baseline is a physical solved case. Operator samples are not.
const SENSITIVITY_BASELINE_LIMIT=512*1024*1024

function sensitivity_baseline_metadata(directory)
    manifest=joinpath(directory,"baseline_manifest.json")
    if isfile(manifest)
        path=sensitivity_saved_file(directory,"baseline_manifest.json",1024*1024)
        data=JSON.parsefile(path)
        data isa AbstractDict&&get(data,"format",nothing)=="wingfegen-sensitivity-baseline-1"||error("Invalid sensitivity baseline manifest")
        return data
    end
    # Historical runs are never solved or deserialized to recover their state.
    native=sensitivity_baseline_native_file(directory)
    Dict{String,Any}("available"=>native!==nothing,"historical"=>true,
        "deck_file"=>isfile(joinpath(directory,"baseline.bdf")) ? "baseline.bdf" : nothing,
        "native_file"=>native===nothing ? nothing : basename(native),"results_file"=>nothing,
        "message"=>native===nothing ? "This older run retained its scalar baseline response, but no physical solution fields. Its deck is available; run sensitivity again to retain the full baseline." : "Historical native baseline fields are available; model compatibility must be checked before display.")
end

function sensitivity_baseline_native_file(directory)
    # Do not search variable/operator directories or arbitrary manifest paths.
    for name in ("baseline_native.json","baseline.JU.JSON","baseline.BUCKLING.JSON")
        isfile(joinpath(directory,name))||continue
        path=sensitivity_saved_file(directory,name,SENSITIVITY_BASELINE_LIMIT)
        data=JSON.parsefile(path)
        data isa AbstractDict&&get(data,"analysis_type","") in ("SOL101_STATIC","SOL103_MODES","SOL105_BUCKLING")||continue
        any(haskey(data,key) for key in ("displacements","modes","static_displacements"))&&return path
    end
    nothing
end

function sensitivity_baseline_summary(directory)
    try
        sensitivity_baseline_metadata(directory)
    catch failure
        Dict{String,Any}("available"=>false,"deck_file"=>isfile(joinpath(directory,"baseline.bdf")) ? "baseline.bdf" : nothing,
            "message"=>"Baseline fields are unavailable: "*sprint(showerror,failure))
    end
end

function sensitivity_baseline_payload(source,baseline,data,path,directory,metadata)
    sol=String(metadata["solution"]);id=Int(metadata["case_id"]);label=String(metadata["case_label"])
    job=JfemJob("sensitivity_baseline", "",joinpath(directory,"baseline.bdf"),directory,
        joinpath(directory,"sensitivity.log"),"",baseline,nothing,String[],ReentrantLock(),0.,Float64(get(metadata,"seconds",0.)),:done,0,"")
    selected=sol=="105" ? buckling_case_result(data,1,1) : sol=="101" ? static_case_result(data,1,[1]) : data
    item=jfem_case_results_payload(job,path,selected)
    item["id"]=id;item["physical_case_id"]=id;item["label"]="Sensitivity baseline · "*label*" · SOL"*sol
    item["variant_id"]="sensitivity_"*basename(directory)*"_sol"*sol
    item["source"]="sensitivity_baseline";item["solution"]=sol;item["baseline_analysis"]=metadata
    item["model_params"]=is_imported_model(source) ? imported_public_params(source) : copy(source.params)
    item["analysis_params"]=is_imported_model(baseline) ? imported_public_params(baseline) : copy(baseline.params)
    is_imported_model(source) ? (item["imported_signature"]=source.params["imported.source"]["signature"]) : (item["fuel_mass"]=fuel_mass_state(baseline))
    push!(item["summary"],Any["Sensitivity baseline","Physical case $id: $label; original forward analysis, no operator perturbations"])
    payload=copy(item);payload["load_cases"]=Any[item];payload["load_case_independent"]=false
    payload["model_params"]=copy(item["model_params"])
    payload
end

function sensitivity_export_baseline(native,forward,source,baseline,directory,spec,solution;seconds=0.)
    native isa Module&&isdefined(native,:export_results)||return Dict{String,Any}("available"=>false,"message"=>"This analysis adapter does not export native baseline fields")
    exportdir=joinpath(directory,"baseline_results");mkpath(exportdir)
    Base.invokelatest(getfield(native,:export_results),forward,"baseline.bdf",exportdir;
        export_json=true,export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
    path,data=find_results_json(exportdir);path===nothing&&error("Native baseline export produced no ordinary result fields")
    # Keep one portable, unambiguous native file at the run root as well.
    sensitivity_json_write(joinpath(directory,"baseline_native.json"),data)
    metadata=Dict{String,Any}("format"=>"wingfegen-sensitivity-baseline-1","available"=>true,
        "case_id"=>spec.id,"case_label"=>spec.label,"solution"=>solution,"seconds"=>seconds,
        "variant_id"=>"sensitivity_"*basename(directory)*"_sol"*solution,
        "deck_file"=>"baseline.bdf","native_file"=>"baseline_native.json","results_file"=>"baseline_results.msgpack",
        "baseline_model_signature"=>sensitivity_model_signature(source),"baseline_model_signature_version"=>2,
        "baseline_topology_signature"=>sensitivity_topology_signature(source),"load_application_version"=>is_imported_model(source) ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION,
        "message"=>"Original solved baseline; no additional forward solve and no operator perturbation fields.")
    payload=sensitivity_baseline_payload(source,baseline,data,path,directory,metadata)
    payload["available"]===true||error("Native baseline has no displayable solution")
    temporary=joinpath(directory,"baseline_results.msgpack.tmp")
    write(temporary,MsgPack.pack(payload));mv(temporary,joinpath(directory,"baseline_results.msgpack");force=true)
    metadata["sha256"]=Dict(file=>bytes2hex(SHA.sha256(read(joinpath(directory,file)))) for file in ("baseline.bdf","baseline_native.json","baseline_results.msgpack"))
    sensitivity_json_write(joinpath(directory,"baseline_manifest.json"),metadata)
    metadata
end

function sensitivity_baseline_file(directory,kind)
    kind in ("deck","results","native")||throw(ArgumentError("Choose deck, results or native baseline download"))
    name=kind=="deck" ? "baseline.bdf" : kind=="results" ? "baseline_results.msgpack" : nothing
    path=name===nothing ? sensitivity_baseline_native_file(directory) : sensitivity_saved_file(directory,name,SENSITIVITY_BASELINE_LIMIT)
    path===nothing&&throw(ArgumentError("This run has no saved physical baseline result"))
    metadata=sensitivity_baseline_metadata(directory);checksums=get(metadata,"sha256",Dict())
    expected=get(checksums,basename(path),nothing)
    expected===nothing||bytes2hex(SHA.sha256(read(path)))==expected||throw(ArgumentError("The saved baseline $(basename(path)) no longer matches its manifest"))
    path
end

function sensitivity_baseline_load(directory,model;result=nothing)
    model===nothing&&throw(ArgumentError("Create the matching FEM before showing a sensitivity baseline"))
    metadata=sensitivity_baseline_metadata(directory)
    get(metadata,"available",false)===true||throw(ArgumentError(get(metadata,"message","This run has no saved baseline fields")))
    record=haskey(metadata,"baseline_model_signature") ? metadata : result
    record isa AbstractDict&&sensitivity_result_matches_model(record,model)||throw(ArgumentError("The baseline model definition differs from the current FEM; open its matching Study before displaying it"))
    matches=is_imported_model(model) ? imported_saved_topology_matches(directory,model,record) : sensitivity_topology_matches(model,sensitivity_deck_topology(directory))
    matches||throw(ArgumentError("The baseline GRID coordinates, element connectivity or properties differ from the current FEM"))
    if isfile(joinpath(directory,"baseline_results.msgpack"))
        payload=unpack_view_payload(read(sensitivity_baseline_file(directory,"results")))
    else
        # Compatibility with historical exports, using only validated data.
        record===nothing&&error("Historical baseline has no case metadata")
        id=Int(record["case_id"]);spec=only(filter(s->s.id==id,load_case_specs(model.params)))
        sol=String(record["solution"]);params=deepcopy(spec.params);params["loads.cases"]=Any[];params["output.solution"]=sol
        baseline=sensitivity_model(model,params);path=sensitivity_baseline_file(directory,"native")
        metadata=merge(metadata,Dict("case_id"=>id,"case_label"=>spec.label,"solution"=>sol))
        payload=sensitivity_baseline_payload(model,baseline,JSON.parsefile(path),path,directory,metadata)
    end
    historical=get(record,"load_application_version",nothing)!=(is_imported_model(model) ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION)
    payload["compatibility"]=Dict("model_match"=>true,"topology_match"=>true,"map_allowed"=>true,"is_current"=>!historical,"load_application_match"=>!historical)
    payload["historical"]=historical
    payload["message"]=historical ? "Historical sensitivity baseline: these solved fields retain their original aerodynamic model and load application convention; rerun the analysis for the current formulation." : "Original sensitivity baseline solution."
    for item in payload["load_cases"]
        get!(item,"analysis_params",copy(item["model_params"]))
        item["model_params"]=is_imported_model(model) ? imported_public_params(model) : copy(model.params)
        item["compatibility"]=copy(payload["compatibility"]);item["historical"]=historical
        item["baseline_analysis"]=metadata;item["message"]=payload["message"]
    end
    payload
end
