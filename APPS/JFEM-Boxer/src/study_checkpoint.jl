# Portable solved Studies contain data only, never executable Julia objects.
import Base64

const STUDY_CHECKPOINT_FORMAT="wingfegen-study-checkpoint-1"
const STUDY_CHECKPOINT_ENCODING="msgpack+gzip+base64"
const STUDY_CHECKPOINT_LIMIT=let mb=tryparse(Int,get(ENV,"JFEM_STUDY_RESULTS_MAX_MB","1024"))
    mb!==nothing&&mb>0&&mb<=typemax(Int)÷(1024*1024) ? mb*1024*1024 : 1024*1024*1024
end
const STUDY_CHECKPOINT_LOCK=ReentrantLock()
const STUDY_CHECKPOINT_STAGES=IdDict{AppState,Dict{String,Any}}()

checkpoint_error(text)=throw(ArgumentError("Study results: "*text))
function checkpoint_base64(value;limit=STUDY_CHECKPOINT_LIMIT)
    value isa AbstractString||checkpoint_error("the embedded binary data are missing")
    ncodeunits(value)<=4cld(limit,3)+4||checkpoint_error("the embedded data exceed the supported size")
    bytes=try Base64.base64decode(value) catch;checkpoint_error("the embedded data are not valid base64");end
    length(bytes)<=limit||checkpoint_error("the embedded data exceed the supported size")
    bytes
end

function checkpoint_unpack(checkpoint;limit=STUDY_CHECKPOINT_LIMIT)
    checkpoint isa AbstractDict&&get(checkpoint,"format",nothing)==STUDY_CHECKPOINT_FORMAT&&
        get(checkpoint,"encoding",nothing)==STUDY_CHECKPOINT_ENCODING||checkpoint_error("unsupported embedded result format")
    compressed=checkpoint_base64(get(checkpoint,"data_base64",nothing);limit)
    get(checkpoint,"sha256",nothing)==bytes2hex(SHA.sha256(compressed))||checkpoint_error("the embedded results failed their checksum")
    stream=CodecZlib.GzipDecompressorStream(IOBuffer(compressed));output=IOBuffer()
    try
        while !eof(stream)
            chunk=read(stream,min(65536,limit-position(output)+1));write(output,chunk)
            position(output)<=limit||checkpoint_error("the expanded results exceed the supported size")
        end
    catch failure
        failure isa ArgumentError&&rethrow()
        checkpoint_error("the embedded results could not be decompressed")
    finally
        close(stream)
    end
    result=try MsgPack.unpack(take!(output)) catch;checkpoint_error("invalid embedded MessagePack results");end
    result isa AbstractDict||checkpoint_error("invalid embedded result container")
    result
end

function checkpoint_parameters(raw)
    raw isa AbstractDict||checkpoint_error("the Study parameters are missing")
    clean=Dict{String,Any}(String(k)=>v for (k,v) in raw if !(k in ("model_kind","imported_deck")))
    params,unknown=normalize_params(clean;validate=false)
    isempty(unknown)||checkpoint_error("unsupported parameters: "*join(sort!(unknown),", "))
    params
end

function checkpoint_params_match(a,b)
    a isa AbstractDict&&b isa AbstractDict||return false
    left,right=checkpoint_parameters(a),checkpoint_parameters(b)
    ignored=Set(("materials.allowables","stringers.euler_fixity_coefficient","stringers.skin_fixity_coefficient",COMPONENT_RF_FIXITY_KEYS...))
    all(SCHEMA) do spec
        key=spec.key
        key in ignored||startswith(key,"view.")||key=="references.items"||is_assessment_parameter(key)||get(left,key,nothing)==get(right,key,nothing)||
            rf_equivalent_controls(left,right,key)
    end
end

checkpoint_bytes(value)=value isa Blob ? value.bytes : value isa AbstractVector{UInt8} ? value : checkpoint_error("a typed mesh/result buffer is invalid")
function checkpoint_i32(value)
    bytes=checkpoint_bytes(value);length(bytes)%4==0||checkpoint_error("an integer buffer has the wrong length")
    Int[ltoh(v) for v in reinterpret(Int32,bytes)]
end
function checkpoint_float_buffer(value,count=nothing)
    bytes=checkpoint_bytes(value);length(bytes)%4==0||checkpoint_error("a result vector has the wrong length")
    count===nothing||length(bytes)==4count||checkpoint_error("a result vector does not match the saved GRID count")
    all(bits->isfinite(reinterpret(Float32,ltoh(bits))),reinterpret(UInt32,bytes))||checkpoint_error("a result vector contains a nonfinite value")
    nothing
end

function checkpoint_expand_groups!(mesh)
    buffers=get(mesh,"imported_buffers",nothing)
    buffers isa AbstractDict||return mesh
    fields=("eids","conn","orient","centers","x","y","z","lengths")
    for group in mesh["groups"]
        offsets=get(group,"binary_offsets",nothing);offsets===nothing&&continue
        axes=get!(group,"axes",Dict{Any,Any}());count=Int(group["count"])
        stride=Int(get(group,"n_per_elem",group["kind"]=="quad" ? 4 : group["kind"]=="tria" ? 3 : 2))
        for (i,key) in enumerate(fields)
            owner=i<=3 ? group : axes
            haskey(owner,key)&&continue
            length_bytes=4count*(key=="eids"||key=="lengths" ? 1 : key=="conn" ? stride : 3)
            bytes=checkpoint_bytes(buffers[key]);offset=Int(offsets[i])
            0<=offset&&offset+length_bytes<=length(bytes)||checkpoint_error("an imported mesh buffer is out of bounds")
            owner[key]=bytes[offset+1:offset+length_bytes]
        end
        properties=group["properties"]
        for owner in vcat(Any[properties],get(properties,"plies",Any[])),key in ("material","face_material","core_material")
            index=get(owner,key,nothing)
            index isa Integer||continue
            0<=index<length(buffers["materials"])||checkpoint_error("an imported material reference is invalid")
            owner[key]=buffers["materials"][index+1]
        end
    end
    mesh
end

function checkpoint_mesh_index(mesh)
    mesh isa AbstractDict&&get(mesh,"format",nothing)=="wingfegen-mesh-1"||checkpoint_error("the saved FEM is missing")
    checkpoint_expand_groups!(mesh)
    nodes=get(mesh,"nodes",nothing);nodes isa AbstractDict||checkpoint_error("the saved GRIDs are missing")
    n=get(nodes,"count",nothing);n isa Integer&&0<n<=typemax(Int32)||checkpoint_error("invalid saved GRID count")
    n=Int(n)
    ids=checkpoint_i32(nodes["ids"])
    length(ids)==n&&length(unique(ids))==n&&all(>(0),ids)||checkpoint_error("saved GRID IDs are invalid")
    checkpoint_float_buffer(nodes["xyz"],3n)
    groups=get(mesh,"groups",nothing);groups isa AbstractVector||checkpoint_error("saved element groups are missing")
    elements=Dict{Int,Int}()
    for group in groups
        group isa AbstractDict||checkpoint_error("invalid element group")
        eids=checkpoint_i32(group["eids"]);conn=checkpoint_i32(group["conn"])
        count=Int(group["count"]);stride=Int(get(group,"n_per_elem",group["kind"]=="quad" ? 4 : group["kind"]=="tria" ? 3 : 2))
        count==length(eids)&&stride>0&&length(conn)==count*stride||checkpoint_error("saved element connectivity is invalid")
        all(i->0<=i<n,conn)&&all(>(0),eids)||checkpoint_error("saved element/GRID references are invalid")
        pid=Int(group["pid"])
        for eid in eids
            haskey(elements,eid)&&elements[eid]!=pid&&checkpoint_error("a saved element has conflicting property IDs")
            elements[eid]=pid
        end
    end
    isempty(elements)&&checkpoint_error("the saved FEM has no elements")
    n,elements
end

function checkpoint_finite_recovery(value)
    value isa AbstractFloat&&return isfinite(value)
    value isa AbstractDict&&return all(checkpoint_finite_recovery,values(value))
    value isa AbstractVector&&return all(checkpoint_finite_recovery,value)
    true
end

function checkpoint_validate_results(results,mesh,params,n,elements;imported=false,analysis=nothing)
    results isa AbstractDict&&get(results,"format",nothing)=="wingfegen-results-1"||checkpoint_error("the original solver result envelope is missing")
    get(results,"node_count",nothing)==n||checkpoint_error("the saved results and FEM have different GRID counts")
    expected_version=String(get(get(mesh,"loads",Dict()),"load_application_version",imported ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION))
    expected_version==(imported ? IMPORTED_LOAD_VERSION : APPLIED_LOAD_VERSION)||checkpoint_error("the saved model uses a historical load/formulation version; rerun it before saving synchronized results")
    signature=imported ? get(mesh,"imported_signature",get(mesh["imported_deck"],"signature",nothing)) : nothing
    imported||checkpoint_params_match(get(results,"source_model_params",get(results,"model_params",nothing)),params)||checkpoint_error("the results belong to a different Study definition")
    available=Ref(0);caseids=Set(s.id for s in load_case_specs(params))
    function record(item,parent_version;case_id=nothing)
        item isa AbstractDict||checkpoint_error("invalid saved result case")
        get(item,"node_count",n)==n||checkpoint_error("a saved case has a different GRID count")
        get(item,"historical",false)&&checkpoint_error("historical result cases cannot be saved as synchronized")
        version=get(item,"load_application_version",parent_version)
        version==expected_version||checkpoint_error("a saved case uses a different load/formulation version")
        if imported
            get(item,"imported_signature",get(results,"imported_signature",nothing))==signature||checkpoint_error("an imported result belongs to another deck")
            imported_analysis_options(get(item,"imported_analysis",get(results,"imported_analysis",nothing)))==imported_analysis_options(analysis)||checkpoint_error("an imported result belongs to different analysis settings")
        elseif haskey(item,"source_model_params")
            checkpoint_params_match(item["source_model_params"],params)||checkpoint_error("a saved case belongs to another Study")
        end
        if !imported&&case_id!==nothing
            case_id in caseids||checkpoint_error("a saved result refers to a load case outside this Study")
        end
        if get(item,"available",true)!==false
            available[]+=1
            static=get(item,"static",nothing)
            if static!==nothing
                checkpoint_float_buffer(static["disp"],3n)
                haskey(static,"rotation")&&static["rotation"]!==nothing&&checkpoint_float_buffer(static["rotation"],3n)
            end
            for mode in get(item,"modes",Any[])
                checkpoint_float_buffer(mode["shape"],3n)
                haskey(mode,"rotation")&&mode["rotation"]!==nothing&&checkpoint_float_buffer(mode["rotation"],3n)
            end
            recovery=get(item,"element_results",Dict())
            recovery isa AbstractDict||checkpoint_error("invalid element recovery data")
            for (key,value) in recovery
                eid=tryparse(Int,String(key));eid!==nothing&&haskey(elements,eid)||checkpoint_error("element recovery refers to an element outside the saved FEM")
                value isa AbstractDict||checkpoint_error("invalid element recovery record")
                checkpoint_finite_recovery(value)||checkpoint_error("element recovery contains a nonfinite value")
            end
            for contour in get(item,"contours",Any[])
                contour_ids=get(contour,"ids",nothing)
                if contour_ids!==nothing
                    eids=checkpoint_i32(contour_ids);all(e->haskey(elements,e),eids)||checkpoint_error("a contour refers to an element outside the saved FEM")
                    checkpoint_float_buffer(contour["values"],length(eids))
                else
                    checkpoint_float_buffer(contour["values"])
                end
            end
        end
        for variant in get(item,"variants",Any[]);record(variant,version;case_id);end
    end
    cases=get(results,"load_cases",Any[])
    if isempty(cases)
        record(results,get(results,"load_application_version",nothing))
    else
        physical_case_ids=Int[]
        for item in cases
            id=Int(get(item,"physical_case_id",get(item,"id",0)));id>0||checkpoint_error("a saved load case has no identity")
            id in physical_case_ids&&checkpoint_error("duplicate saved physical load case")
            push!(physical_case_ids,id);record(item,get(results,"load_application_version",nothing);case_id=id)
        end
    end
    available[]>0||checkpoint_error("there are no available results to save")
    nothing
end

function checkpoint_import_source(raw,mesh)
    raw isa AbstractDict&&get(raw,"kind",nothing)=="reference"&&get(raw,"text",nothing) isa AbstractString||checkpoint_error("imported results need their embedded original model source")
    source=imported_source(raw)
    source["signature"]==mesh["imported_signature"]||checkpoint_error("the embedded imported source differs from the solved deck")
    source
end

function study_checkpoint_create(raw;limit=STUDY_CHECKPOINT_LIMIT)
    params=checkpoint_parameters(raw["parameters"])
    mesh=MsgPack.unpack(checkpoint_base64(get(raw,"mesh_base64",nothing);limit))
    results=MsgPack.unpack(checkpoint_base64(get(raw,"results_base64",nothing);limit))
    n,elements=checkpoint_mesh_index(mesh);imported=haskey(mesh,"imported_deck")
    checkpoint_params_match(mesh["model_params"],params)||checkpoint_error("the FEM and current Study are not synchronized")
    source=imported ? checkpoint_import_source(get(raw,"imported_source",nothing),mesh) : nothing
    checkpoint_validate_results(results,mesh,params,n,elements;imported,analysis=imported ? get(raw["imported_source"],"analysis",nothing) : nothing)
    # Restored typed binary tags must remain MessagePack bin objects.
    packed=MsgPack.pack(restore_payload_binary(Dict("mesh"=>mesh,"results"=>results,"parameters"=>params,
        "imported_source_signature"=>source===nothing ? nothing : source["signature"])))
    length(packed)<=limit||checkpoint_error("the complete saved results exceed the supported size")
    compressed=transcode(CodecZlib.GzipCompressor,packed)
    Dict("format"=>STUDY_CHECKPOINT_FORMAT,"encoding"=>STUDY_CHECKPOINT_ENCODING,
        "data_base64"=>Base64.base64encode(compressed),"sha256"=>bytes2hex(SHA.sha256(compressed)),
        "compressed_bytes"=>length(compressed),"uncompressed_bytes"=>length(packed))
end

function checkpoint_equal(a,b)
    a==b&&return true
    if a isa Number&&b isa Number
        return !(a isa Integer&&b isa Integer)&&isfinite(a)&&isfinite(b)&&isapprox(a,b;rtol=1e-10,atol=0)
    elseif a isa AbstractDict&&b isa AbstractDict
        ignored=("allowables","minimum_gauge","axes","placement")
        ka=Set(k for k in keys(a) if !(k in ignored));kb=Set(k for k in keys(b) if !(k in ignored))
        return ka==kb&&all(k->checkpoint_equal(a[k],b[k]),ka)
    elseif a isa AbstractVector&&b isa AbstractVector
        return length(a)==length(b)&&all(checkpoint_equal(x,y) for (x,y) in zip(a,b))
    end
    false
end

function checkpoint_validate_model(mesh,m;imported_mesh=nothing)
    checkpoint_i32(mesh["nodes"]["ids"])==m.node_ids||checkpoint_error("the saved GRID IDs do not match the reconstructed Study")
    checkpoint_bytes(mesh["nodes"]["xyz"])==blob_f32(m.xyz).bytes||checkpoint_error("the saved GRID coordinates differ from the reconstructed Study")
    expected=imported_mesh===nothing ? [Dict("pid"=>g.pid,"kind"=>String(g.kind),"eids"=>blob_i32(g.eids),
        "conn"=>blob_i32(g.conn;offset=-1),"properties"=>element_properties(m,g)) for g in m.groups if !isempty(g.eids)] : checkpoint_expand_groups!(imported_mesh)["groups"]
    actual=mesh["groups"]
    length(actual)==length(expected)||checkpoint_error("the saved element groups differ from the reconstructed Study")
    for (a,b) in zip(actual,expected)
        a["pid"]==b["pid"]&&a["kind"]==b["kind"]&&checkpoint_bytes(a["eids"])==checkpoint_bytes(b["eids"])&&
            checkpoint_bytes(a["conn"])==checkpoint_bytes(b["conn"])||checkpoint_error("saved element IDs, properties or connectivity differ from the reconstructed Study")
        checkpoint_equal(a["properties"],b["properties"])||checkpoint_error("a saved FE section or material differs from the current formulation")
        a["properties"]=b["properties"]
    end
    nothing
end

function checkpoint_import_model(st,params,source)
    temporary=AppState((field===:params ? copy(params) : field===:model ? nothing : getfield(st,field) for field in fieldnames(AppState))...)
    input=Dict{String,Any}(source)
    input["materials.allowables"]=params["materials.allowables"]
    for key in ASSESSMENT_FACTOR_KEYS;input[key]=params[key];end
    response=handle_import_reference(temporary,HTTP.Request("POST","/api/import_reference",[],JSON.json(input)))
    response.status==200||checkpoint_error("the saved deck could not be reconstructed: "*String(response.body))
    model=temporary.model;model===nothing&&checkpoint_error("the saved deck has no reconstructed model")
    model=imported_analysis_model(model,get(source,"analysis",nothing))
    mesh=MsgPack.unpack(response.body)
    token=mesh["imported_deck"]["token"]
    lock(IMPORTED_MODELS_LOCK) do;IMPORTED_MODELS[token]=model;end
    mesh["imported_deck"]["analysis"]=imported_analysis_options(get(source,"analysis",nothing))
    model,mesh
end

function study_checkpoint_restore(st,raw;build_generated=p->build_model(p;summaries=false),build_imported=checkpoint_import_model)
    packed=checkpoint_unpack(raw["checkpoint"]);params=checkpoint_parameters(raw["parameters"])
    mesh=packed["mesh"];results=packed["results"]
    checkpoint_params_match(packed["parameters"],params)&&checkpoint_params_match(mesh["model_params"],params)||checkpoint_error("the saved results belong to a different Study definition")
    n,elements=checkpoint_mesh_index(mesh);imported=haskey(mesh,"imported_deck")
    checkpoint_validate_results(results,mesh,params,n,elements;imported,analysis=imported ? get(get(raw,"imported_source",Dict()),"analysis",nothing) : nothing)
    if imported
        source=get(raw,"imported_source",nothing);record=checkpoint_import_source(source,mesh)
        record["signature"]==packed["imported_source_signature"]||checkpoint_error("the imported source checkpoint identity differs")
        model,fresh=build_imported(st,params,source)
        checkpoint_validate_model(mesh,model;imported_mesh=fresh)
        mesh["imported_deck"]=fresh["imported_deck"]
    else
        model=build_generated(params)
        checkpoint_validate_model(mesh,model)
        metadata=rf_section_update(model,deepcopy(params))
        mesh["stiffened_panels"]=metadata["stiffened_panels"];mesh["component_buckling"]=metadata["component_buckling"]
    end
    mesh["model_params"]=copy(params);mesh["assessment_policy"]=assessment_policy_payload(params)
    materials=get(mesh,"materials",nothing)
    materials isa AbstractDict&&(materials["allowables"]=deepcopy(get(params,"materials.allowables",Any[])))
    token=bytes2hex(SHA.sha256(string(time_ns(),objectid(model),rand(UInt))))
    lock(STUDY_CHECKPOINT_LOCK) do
        # One pending browser transaction per server; replacing it releases the
        # earlier candidate instead of accumulating large historical FEMs.
        STUDY_CHECKPOINT_STAGES[st]=Dict("token"=>token,"created"=>time(),"model"=>model,
            "previous_model"=>st.model,"previous_params"=>st.params,"params"=>copy(params))
    end
    restore_payload_binary(Dict("ok"=>true,"mesh"=>mesh,"results"=>results,"restore_token"=>token))
end

function checkpoint_finish!(st,token;commit=false)
    token isa AbstractString||checkpoint_error("the restore transaction is missing")
    lock(STUDY_CHECKPOINT_LOCK) do
        pending=get(STUDY_CHECKPOINT_STAGES,st,nothing)
        pending!==nothing&&pending["token"]==token||checkpoint_error("the restore transaction expired or was replaced")
        if commit
            st.model===pending["previous_model"]||checkpoint_error("another operation changed the server model during restoration")
            st.params===pending["previous_params"]||checkpoint_error("another operation changed the server Study during restoration")
            st.model=pending["model"];st.params=pending["params"]
        end
        delete!(STUDY_CHECKPOINT_STAGES,st)
    end
    Dict("ok"=>true)
end

function handle_study_checkpoint_create(st,req)
    try
        raw=JSON.parse(String(req.body);dicttype=Dict{String,Any})
        json_response(Dict("ok"=>true,"checkpoint"=>study_checkpoint_create(raw)))
    catch failure;error_response(describe_error(failure));end
end
function handle_study_checkpoint_restore(st,req)
    try
        raw=JSON.parse(String(req.body);dicttype=Dict{String,Any})
        msgpack_response(study_checkpoint_restore(st,raw))
    catch failure;error_response(describe_error(failure));end
end
function handle_study_checkpoint_commit(st,req)
    try
        raw=JSON.parse(String(req.body);dicttype=Dict{String,Any})
        json_response(checkpoint_finish!(st,get(raw,"token",nothing);commit=true))
    catch failure;error_response(describe_error(failure));end
end
function handle_study_checkpoint_discard(st,req)
    try
        raw=JSON.parse(String(req.body);dicttype=Dict{String,Any})
        json_response(checkpoint_finish!(st,get(raw,"token",nothing)))
    catch failure;error_response(describe_error(failure));end
end
