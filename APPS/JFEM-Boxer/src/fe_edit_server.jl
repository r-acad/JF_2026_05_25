# Transactional FE utility workspace. The original source file is never opened
# for writing; the importer validates each candidate before its session advances.

mutable struct FEEditSession
    id::String
    revision::Int
    initial_source::Dict{String,Any}
    source::Dict{String,Any}
    deck::FEEditDeck
    params::Dict{String,Any}
    history::Vector{Dict{String,Any}}
    warnings::Vector{String}
end
const FE_EDIT_SESSIONS=IdDict{Any,FEEditSession}()
const FE_EDIT_LOCK=ReentrantLock()
const FE_EDIT_OWNED_TOKENS=Dict{String,Set{String}}()
const FE_EDIT_PARTS_CACHE=Dict{String,Any}()
const FE_EDIT_OPERATION_CANDIDATES=Dict{String,Dict{String,Any}}()

function fe_edit_public_source(source)
    Dict{String,Any}(key=>deepcopy(source[key]) for key in ("kind","name","text","includes","format") if haskey(source,key))
end

function fe_edit_import_candidate(st,source,params,progress)
    started=time();timings=Dict{String,Any}()
    repo,_=find_jfem(st.root;hint=String(get(params,"jfem.repo","")))
    repo===nothing&&throw(ArgumentError("The native JFEM parser is unavailable. Configure its repository before editing FE geometry."))
    base=joinpath(st.deck_store_dir,"fe_edits");mkpath(base);directory=mktempdir(base;prefix="candidate_",cleanup=false)
    t=time();Serialization.serialize(joinpath(directory,"input.jls"),(source,params));timings["input_capture_seconds"]=time()-t
    wait_timings=imported_run_worker(st,repo,directory,progress)
    merge!(timings,JSON.parsefile(joinpath(directory,"timings.json")),wait_timings)
    t=time();model=Serialization.deserialize(joinpath(directory,"model.jls"));timings["model_restore_seconds"]=time()-t
    token=String(model.params["imported.token"])
    t=time();bytes=read(joinpath(directory,"payload.msgpack"));timings["payload_read_seconds"]=time()-t
    t=time()
    coordinates=Dict(Int(id)=>Tuple(model.xyz[3index-2:3index]) for (index,id) in enumerate(model.node_ids))
    deck=fe_edit_deck(source["name"],source["flattened"];coordinates)
    timings["adapter_reparse_seconds"]=time()-t;timings["candidate_seconds"]=time()-started
    (model=model,token=token,bytes=bytes,deck=deck,timings=timings)
end

function fe_edit_response(session;extra=Dict{String,Any}(),bytes=nothing)
    mesh=Dict{String,Any}("nodes"=>session.deck.nodes,"elements"=>session.deck.elements)
    result=Dict{String,Any}("ok"=>true,"session_id"=>session.id,"revision"=>session.revision,
        "source"=>fe_edit_public_source(session.source),"summary"=>fe_edit_summary(mesh;warnings=session.warnings),
        "can_undo"=>!isempty(session.history),"undo_depth"=>length(session.history))
    pending=get(FE_EDIT_OPERATION_CANDIDATES,session.id,nothing)
    result["operation_coincidences"]=pending!==nothing&&pending["revision"]==session.revision ? pending : nothing
    bytes===nothing||(result["mesh_msgpack_base64"]=HTTP._base64encode(bytes))
    merge!(result,extra);result
end

function fe_edit_commit!(st,session,source,candidate;push_history=true,warnings=session.warnings)
    if push_history
        push!(session.history,deepcopy(session.source))
        length(session.history)>20&&popfirst!(session.history)
    end
    session.source=source;session.deck=candidate.deck;session.revision+=1;session.warnings=String.(warnings)
    pop!(FE_EDIT_PARTS_CACHE,session.id,nothing);pop!(FE_EDIT_OPERATION_CANDIDATES,session.id,nothing)
    lock(IMPORTED_MODELS_LOCK) do
        owned=get!(FE_EDIT_OWNED_TOKENS,session.id,Set{String}())
        protected=Set([candidate.token])
        # Jobs already hold their exact model. Keep their token lookup too,
        # and never evict unrelated imported sources or another edit session.
        for collection in (getproperty(st,:jobs),getproperty(st,:sensitivity_jobs)),job in values(collection)
            getproperty(job,:state) in (:queued,:running)||continue
            token=get(getproperty(job,:model).params,"imported.token",nothing)
            token===nothing||push!(protected,String(token))
        end
        for token in collect(owned)
            token in protected&&continue
            pop!(IMPORTED_MODELS,token,nothing);delete!(owned,token)
        end
        push!(owned,candidate.token)
        IMPORTED_MODELS[candidate.token]=candidate.model
    end
    st.model=candidate.model
    FE_EDIT_SESSIONS[st]=session
    nothing
end

function fe_edit_initial_model(st,raw,progress)
    params=get(raw,"params",get(raw,"parameters",nothing))
    if params isa AbstractDict
        imported=request_imported_model(params)
        imported!==nothing&&return imported
    end
    if get(raw,"model_source",nothing) isa AbstractDict
        source=imported_source(raw["model_source"])
        return fe_edit_import_candidate(st,source,copy(st.params),progress).model
    end
    if params isa AbstractDict
        normalized,unknown=normalize_params(params)
        progress("Creating the current generated mesh for an independent FE editing copy")
        return build_model(normalized)
    end
    st.model===nothing&&throw(ArgumentError("Create the FEM or read a Nastran model before starting FE editing."))
    st.model
end

function fe_edit_initialize(st,raw,progress)
    model=fe_edit_initial_model(st,raw,progress)
    params=Dict{String,Any}(key=>deepcopy(value) for (key,value) in model.params if !startswith(key,"imported."))
    name="edited_model.bdf";text=""
    if is_imported_model(model)
        source=model.params["imported.source"]
        get(source,"format","reference")=="reference"||throw(ArgumentError("FE editing currently accepts Nastran BDF input. Export the external mesh to Nastran before editing an Abaqus source."))
        name=replace(basename(source["name"]),r"(?i)\.(bdf|dat|nas|pch|fem|bulk)(\.gz)?$"=>"")*"_edited.bdf"
        # Freeze the selected analysis overlay once. It becomes authored source
        # rather than being reapplied to every subsequent geometry operation.
        text=String(get(model.params,"imported.analysis_deck",source["flattened"]))
    else
        progress("Capturing generated properties, connections, supports and load cards")
        io=IOBuffer();write_deck(io,model);text=String(take!(io))
        title=replace(basename(String(get(params,"output.reference_file","wing_box.bdf"))),r"(?i)\.bdf$"=>"")
        name=title*"_edited.bdf"
    end
    coordinates=Dict(Int(id)=>Tuple(model.xyz[3index-2:3index]) for (index,id) in enumerate(model.node_ids))
    deck=fe_edit_deck(name,text;coordinates)
    canonical=fe_edit_render(deck,fe_edit_mesh(deck;copy_geometry=false))
    source=imported_source(Dict("name"=>name,"text"=>canonical,"format"=>"reference"))
    progress("Verifying the independent editing copy with the native parser")
    candidate=fe_edit_import_candidate(st,source,params,progress)
    session=FEEditSession(bytes2hex(SHA.sha256(source["signature"]*string(time_ns()))),0,deepcopy(source),source,candidate.deck,params,Dict{String,Any}[],
        ["FE editing uses the source coordinate units. Original files are preserved; Save edited BDF creates a separate file.","Copies include selected structural and fully contained rigid elements; source loads and boundary conditions are not copied."])
    previous=get(FE_EDIT_SESSIONS,st,nothing)
    if previous!==nothing
        pop!(FE_EDIT_PARTS_CACHE,previous.id,nothing);pop!(FE_EDIT_OPERATION_CANDIDATES,previous.id,nothing)
    end
    fe_edit_commit!(st,session,source,candidate;push_history=false)
    fe_edit_response(session;bytes=candidate.bytes)
end

function fe_edit_session(st,raw)
    session=get(FE_EDIT_SESSIONS,st,nothing)
    session===nothing&&throw(ArgumentError("Start an FE editing copy before using this tool."))
    get(raw,"session_id",session.id)==session.id||throw(ArgumentError("This FE editing session has been replaced. Start from the current model again."))
    Int(get(raw,"revision",session.revision))==session.revision||throw(ArgumentError("The FE editing model changed while this request was prepared. Review the current preview and retry."))
    current=st.model
    current!==nothing&&is_imported_model(current)&&get(current.params["imported.source"],"signature",nothing)==session.source["signature"]||throw(ArgumentError("The displayed model has been replaced since FE editing started. Start a new FE editing copy from the current model."))
    session
end

function fe_edit_mass_membership_guard(deck,action,report,selection)
    affected=Set(Int.(selection))
    union!(affected,Int.(get(report,"split_elements",Int[])))
    isempty(affected)&&return
    for c in deck.records
        if c.kind in ("NSML","NSML1")
            throw(ArgumentError("$(c.kind) set $(fe_edit_field(c,1)) defines a fixed total nonstructural mass over a region. Cutting/copying that region changes its mass allocation. Replace it with explicit per-element NSM or concentrated masses in an exported copy before editing; no operation was committed."))
        elseif c.kind in ("NSM","NSM1")&&uppercase(fe_edit_field(c,2))=="ELEMENT"
            refs=c.kind=="NSM" ? Int[fe_edit_int(fe_edit_field(c,i)) for i in 3:2:length(c.fields)] : fe_edit_expand_ids(c.fields[4:end];label="$(c.kind) element membership")
            overlap=intersect(affected,Set(refs))
            isempty(overlap)||throw(ArgumentError("$(c.kind) set $(fe_edit_field(c,1)) assigns nonstructural mass to edited element IDs $(join(sort!(collect(overlap)),", ")). Its new fragment/copy membership must be specified explicitly. Convert that mass to property NSM or update its membership in an exported copy before editing."))
        end
    end
end

function fe_edit_plane_request(raw)
    plane=get(raw,"plane",raw)
    plane isa AbstractDict||throw(ArgumentError("Define a cutting plane by its point, normal direction and side length."))
    point=get(plane,"point",nothing);normal=get(plane,"normal",nothing)
    point===nothing&&throw(ArgumentError("The plane point is missing"));normal===nothing&&throw(ArgumentError("The plane normal is missing"))
    (point=point,normal=normal,side_length=get(plane,"side_length",1.),tolerance=get(plane,"tolerance",nothing))
end

function fe_edit_selected(mesh,raw)
    if haskey(raw,"element_ids");return Int.(raw["element_ids"]);end
    selection=get(raw,"selection",Dict());selection isa AbstractDict||throw(ArgumentError("Choose the cut part to move or copy."))
    plane=fe_edit_plane_request(selection);side=String(get(selection,"kind","positive"))
    if side=="slab"
        second=fe_edit_plane_request(Dict("plane"=>get(selection,"second_plane",Dict())))
        n=_fe_edit_xyz(plane.normal,"Plane normal");n/=norm(n)
        m=_fe_edit_xyz(second.normal,"Second plane normal");m/=norm(m)
        abs(dot(n,m))>=1-1e-8||throw(ArgumentError("A slice needs two parallel cutting planes."))
        separation=dot(_fe_edit_xyz(second.point,"Second plane point")-_fe_edit_xyz(plane.point,"Plane point"),n)
        return fe_select_mesh(mesh;point=plane.point,normal=plane.normal,side="slab",lower=min(0.,separation),upper=max(0.,separation),tolerance=plane.tolerance)
    end
    fe_select_mesh(mesh;point=plane.point,normal=plane.normal,side,tolerance=plane.tolerance)
end

"""Identify physical connected parts, without bridging an ambiguous rigid seam."""
function fe_edit_parts(deck::FEEditDeck;plane=nothing)
    elements=deck.elements;nodes=deck.nodes;n=length(elements);parents=collect(1:n)
    function root(index)
        while parents[index]!=index
            parents[index]=parents[parents[index]];index=parents[index]
        end
        index
    end
    function join(a,b)
        ra=root(a);rb=root(b);ra==rb||(parents[max(ra,rb)]=min(ra,rb))
    end
    owner=Dict{Int,Int}()
    for (index,element) in enumerate(elements),id in element["nodes"]
        if haskey(owner,id);join(index,owner[id]);else;owner[id]=index;end
    end
    links=fe_edit_rigid_links(deck)
    rigidparents=Dict{Int,Int}()
    for link in links,id in link["nodes"];haskey(nodes,id)&&(rigidparents[id]=id);end
    function rigidroot(id)
        while rigidparents[id]!=id
            rigidparents[id]=rigidparents[rigidparents[id]];id=rigidparents[id]
        end
        id
    end
    for link in links
        refs=Int[id for id in link["nodes"] if haskey(rigidparents,id)]
        isempty(refs)&&continue
        for id in refs[2:end]
            a=rigidroot(first(refs));b=rigidroot(id);a==b||(rigidparents[max(a,b)]=min(a,b))
        end
    end
    groups=Dict{Int,Vector{Int}}()
    for id in keys(rigidparents);push!(get!(groups,rigidroot(id),Int[]),id);end
    group_links=Dict{Int,Vector{Int}}()
    for link in links
        firstref=findfirst(id->haskey(rigidparents,id),link["nodes"]);firstref===nothing&&continue
        group=rigidroot(Int(link["nodes"][firstref]));push!(get!(group_links,group,Int[]),Int(link["id"]))
    end
    direction=nothing;origin=nothing;tol=0.
    if plane!==nothing
        spec=fe_edit_plane_request(Dict("plane"=>plane));direction=_fe_edit_xyz(spec.normal,"Plane normal");direction/=norm(direction);origin=_fe_edit_xyz(spec.point,"Plane point")
        tol=_fe_edit_tolerance(Dict("nodes"=>nodes),spec.tolerance)
    end
    excluded=Set{Int}()
    for refs in values(groups)
        physical=Int[id for id in refs if haskey(owner,id)]
        isempty(physical)&&continue
        ambiguous=false
        if direction!==nothing
            distances=[dot(_fe_edit_xyz(nodes[id],"GRID $id")-origin,direction) for id in physical]
            positive=any(>(tol),distances);negative=any(<(-tol),distances)
            ambiguous=positive&&negative||!positive&&!negative
        end
        if ambiguous
            group=rigidroot(first(refs))
            union!(excluded,get(group_links,group,Int[]))
            continue
        end
        firstowner=owner[first(physical)]
        for id in physical[2:end];join(firstowner,owner[id]);end
    end
    components=Dict{Int,Vector{Int}}()
    for index in eachindex(elements);push!(get!(components,root(index),Int[]),index);end
    parts=Dict{String,Any}[];bodyparts=0
    for indices in values(components)
        any(index->length(elements[index]["nodes"])>=2,indices)&&(bodyparts+=1)
        eids=sort!(Int[elements[index]["id"] for index in indices]);ids=Set(Int(id) for index in indices for id in elements[index]["nodes"])
        lo=[minimum(nodes[id][axis] for id in ids) for axis in 1:3];hi=[maximum(nodes[id][axis] for id in ids) for axis in 1:3]
        side="connected"
        if direction!==nothing
            distances=[dot(_fe_edit_xyz(nodes[id],"GRID $id")-origin,direction) for id in ids]
            positive=any(>(tol),distances);negative=any(<(-tol),distances)
            side=positive&&negative ? "crossing" : positive ? "positive" : negative ? "negative" : "coplanar"
        end
        label=side=="positive" ? "Positive cut part" : side=="negative" ? "Negative cut part" : side=="crossing" ? "Connected across cutting plane" : side=="coplanar" ? "Part in cutting plane" : "Connected part"
        push!(parts,Dict("id"=>"part-E$(first(eids))","label"=>label*" · E$(first(eids))","element_ids"=>eids,"element_count"=>length(eids),"node_count"=>length(ids),"bounds"=>Dict("min"=>lo,"max"=>hi),"side"=>side,"requires_cut"=>side=="crossing"))
    end
    sort!(parts;by=part->first(part["element_ids"]))
    if bodyparts>=2
        for part in parts;part["requires_cut"]=false;end
    end
    Dict{String,Any}("parts"=>parts,"part_count"=>length(parts),"structural_part_count"=>bodyparts,"excluded_rigid_ids"=>sort!(collect(excluded)))
end

function fe_edit_parts_key(plane)
    if plane===nothing
        nothing
    else
        spec=fe_edit_plane_request(Dict("plane"=>plane))
        (Tuple(Float64.(spec.point)),Tuple(Float64.(spec.normal)),Float64(spec.side_length),spec.tolerance)
    end
end

function fe_edit_cached_parts(session;plane=nothing)
    key=fe_edit_parts_key(plane)
    cached=get(FE_EDIT_PARTS_CACHE,session.id,nothing)
    if cached!==nothing&&cached.revision==session.revision&&cached.key==key
        return cached.parts
    end
    result=fe_edit_parts(session.deck;plane)
    FE_EDIT_PARTS_CACHE[session.id]=(revision=session.revision,key=key,parts=result)
    result
end

function fe_edit_operation_groups(session,raw)
    pending=get(FE_EDIT_OPERATION_CANDIDATES,session.id,nothing)
    pending!==nothing&&pending["revision"]==session.revision&&get(raw,"operation_id",nothing)==pending["operation_id"]||throw(ArgumentError("Those operation-created overlaps no longer match this editing revision. Review the latest move/copy overlap list before merging."))
    tolerance=Float64(get(raw,"tolerance",pending["tolerance"]))
    tolerance==Float64(pending["tolerance"])||throw(ArgumentError("Use the tolerance of the reviewed operation-created overlap list; changing it requires a new review."))
    allowed=Set((min(Int(pair[1]),Int(pair[2])),max(Int(pair[1]),Int(pair[2]))) for pair in pending["pairs"])
    for group in get(raw,"groups",Any[])
        group isa AbstractDict||throw(ArgumentError("Choose an explicit retained node for each operation-created overlap group."))
        ids=unique(Int.(group["nodes"]));master=Int(get(group,"retained_node",0));master in ids||throw(ArgumentError("The retained node must belong to its reviewed overlap group."))
        matching=findfirst(candidate->issubset(Set(ids),Set(vcat(Int.(candidate["nodes"]),Int.(get(candidate,"anchor_nodes",Int[]))))),pending["candidate_groups"])
        matching===nothing&&throw(ArgumentError("The selected nodes do not belong to the reviewed operation-created overlap candidates."))
        affected=Set(Int.(pending["candidate_groups"][matching]["affected_nodes"]))
        count(id->!(id in affected),ids)<=1||throw(ArgumentError("Existing coincident anchor nodes must remain separate. Choose one existing anchor and the operation-created nodes to attach to it."))
        any(id->id in affected,ids)||throw(ArgumentError("This group contains no nodes affected by the reviewed move/copy operation."))
        for id in ids
            id==master&&continue
            (min(id,master),max(id,master)) in allowed||throw(ArgumentError("Nodes $id and $master are an existing or unrelated coincidence, not a reviewed overlap created by this operation."))
        end
    end
    pending
end

function fe_edit_retained_rigid_notes(text,report,action,revision)
    retained=sort!(unique(Int.(get(report,"retained_rigid_ids",Int[]))))
    isempty(retained)&&return text
    aliases=get(report,"detached_rigid_nodes",get(report,"duplicate_nodes",Dict{Int,Int}()))
    mapping=sort!(collect(aliases);by=first)
    rows=String["\$ FE Utilities $(action) revision $(revision): retained $(length(retained)) rigid connection(s) on original GRIDs.",
        "\$ Their source connectivity and DOFs are unchanged; $(length(mapping)) structural GRID alias(es) detach the edited part."]
    for start in 1:12:min(length(retained),120)
        push!(rows,"\$ Retained rigid IDs: "*join(retained[start:min(start+11,length(retained),120)],", "))
    end
    for start in 1:8:min(length(mapping),120)
        push!(rows,"\$ Structural aliases (original -> new): "*join(["$(first(pair)) -> $(last(pair))" for pair in mapping[start:min(start+7,length(mapping),120)]],", "))
    end
    length(retained)>120&&push!(rows,"\$ Additional retained IDs omitted from this summary: $(length(retained)-120).")
    length(mapping)>120&&push!(rows,"\$ Additional structural aliases omitted from this summary: $(length(mapping)-120).")
    push!(rows,"\$ Review these retained joints before solving or equivalencing coincident nodes; aliases have no inherited permanent GRID constraints.")
    notes=join(rows,"\n")*"\n"
    occursin(r"^[ \t]*ENDDATA\b"im,text) ? replace(text,r"^[ \t]*ENDDATA\b"im=>matched->notes*matched;count=1) : text*(endswith(text,"\n") ? "" : "\n")*notes
end

function fe_edit_equivalence_guard(deck,mapping)
    gridcards=Dict(fe_edit_int(fe_edit_field(c,1))=>c for c in deck.records if c.kind=="GRID")
    for (old,retained) in mapping
        c=gridcards[old];master=gridcards[retained]
        for (i,label) in ((6,"displacement coordinate system CD"),(7,"permanent constraints PS"),(8,"superelement SEID"))
            fe_edit_int(fe_edit_field(c,i))==fe_edit_int(fe_edit_field(master,i))||throw(ArgumentError("Nodes $old and $retained have different $label. Keep them separate or align their GRID definitions explicitly before equivalence."))
        end
    end
    prescribed=Dict{Tuple{Int,Int,Char},Float64}()
    permanent=Dict{Int,Set{Char}}()
    for (id,c) in gridcards
        components=Set(ch for ch in fe_edit_field(c,7) if ch in '1':'6')
        isempty(components)||union!(get!(permanent,get(mapping,id,id),Set{Char}()),components)
    end
    function constraint(sid,id,components,value)
        new=get(mapping,id,id)
        for dof in components
            dof in '1':'6'||continue
            dof in get(permanent,new,Set{Char}())&&abs(value)>1e-14&&throw(ArgumentError("Equivalence would prescribe a nonzero displacement on permanently constrained GRID $new, DOF $dof. Review GRID PS and the SPC cards before merging."))
            key=(sid,new,dof)
            if haskey(prescribed,key)&&!isapprox(prescribed[key],value;rtol=1e-12,atol=1e-14)
                throw(ArgumentError("Equivalence would assign conflicting prescribed displacements to GRID $new, DOF $dof, SPC set $sid. Resolve those source boundary conditions before merging."))
            end
            prescribed[key]=value
        end
    end
    for c in deck.records
        if c.kind in ("SPC","SPCD")
            for i in 2:3:length(c.fields)
                id=fe_edit_int(fe_edit_field(c,i));id>0&&constraint(fe_edit_int(c.fields[1]),id,fe_edit_field(c,i+1),fe_edit_real(fe_edit_field(c,i+2)))
            end
        elseif c.kind=="SPC1"
            for id in fe_edit_grid_ids(c);constraint(fe_edit_int(c.fields[1]),id,c.fields[2],0.);end
        elseif c.kind=="MPC"
            seen=Dict{Tuple{Int,String},Int}()
            for i in 2:3:length(c.fields)
                id=fe_edit_int(fe_edit_field(c,i));id>0||continue
                key=(get(mapping,id,id),fe_edit_field(c,i+1))
                haskey(seen,key)&&seen[key]!=id&&throw(ArgumentError("Equivalence would combine two terms of MPC set $(c.fields[1]) at GRID $(key[1]), DOF $(key[2]), potentially cancelling its equation. Review that MPC before merging."))
                seen[key]=id
            end
        elseif c.kind in ("FORCE1","MOMENT1","FORCE2","MOMENT2")
            old=Int[fe_edit_int(fe_edit_field(c,i)) for i in (c.kind in ("FORCE1","MOMENT1") ? (4:5) : (4:7))]
            length(unique(get(mapping,id,id) for id in old))<length(unique(old))&&throw(ArgumentError("Equivalence would collapse the direction-defining nodes of $(c.kind) set $(c.fields[1]). Keep them separate or replace the load direction with an explicit vector."))
        end
    end
    fe_edit_check_remap(deck,mapping)
end

function fe_edit_movement_guard(deck,mesh,report)
    moved=Set(Int.(get(report,"moved_nodes",Int[])))
    isempty(moved)&&return
    for c in deck.records
        ids=fe_edit_grid_ids(c);isempty(ids)&&continue
        if c.kind in ("CORD1R","CORD1C","CORD1S")
            present=count(id->id in moved,ids)
            0<present<length(ids)&&throw(ArgumentError("The translation would change coordinate system $(c.fields[1]) by moving only some defining GRID nodes. Select all its defining nodes or convert that coordinate system to a fixed CORD2 definition first."))
        elseif c.kind in ("CBUSH","CGAP")&&fe_edit_orientation_grid(c)>0
            # CBAR/CBEAM directions were frozen before this guard. Other
            # connector types retain their type-specific orientation review.
            ends=FE_EDIT_ELEMENT_NODES[c.kind];body=Int[fe_edit_int(fe_edit_field(c,i)) for i in ends]
            any(id->id in moved,body)&&!(fe_edit_orientation_grid(c) in moved)&&throw(ArgumentError("$(c.kind) $(c.fields[1]) uses an orientation GRID outside the moving part. Convert G0 to an explicit orientation vector or move its complete reference region."))
        elseif c.kind in ("FORCE1","MOMENT1","FORCE2","MOMENT2")
            directionids=Int[fe_edit_int(fe_edit_field(c,i)) for i in (c.kind in ("FORCE1","MOMENT1") ? (4:5) : (4:7))]
            present=count(id->id in moved,directionids)
            0<present<length(directionids)&&throw(ArgumentError("$(c.kind) load set $(c.fields[1]) defines its direction using nodes on both moving and stationary parts. Use an explicit FORCE/MOMENT direction or move the complete direction-defining reference before translating."))
        end
    end
end

function fe_edit_operation(st,raw,progress)
    action=String(get(raw,"action","context"))
    action=="initialize"&&return fe_edit_initialize(st,raw,progress)
    if action=="context"&&!haskey(FE_EDIT_SESSIONS,st)
        m=st.model
        return Dict("ok"=>true,"initialized"=>false,"summary"=>(m===nothing ? nothing : Dict("nodes"=>length(m.node_ids),"bounds"=>bbox_of(m))))
    end
    session=fe_edit_session(st,raw)
    if action=="node_coordinates"
        ids=get(raw,"node_ids",nothing)
        ids isa AbstractVector&&1<=length(ids)<=1000||throw(ArgumentError("Request between 1 and 1000 GRID identifiers to pick exact model coordinates."))
        requested=unique(Int.(ids));missing=filter(id->!haskey(session.deck.nodes,id),requested)
        isempty(missing)||throw(ArgumentError("GRID identifiers $(join(missing,", ")) are not in the current FE editing copy. Pick a node on the current model."))
        coordinates=Dict(string(id)=>collect(session.deck.nodes[id]) for id in requested)
        return Dict{String,Any}("ok"=>true,"session_id"=>session.id,"revision"=>session.revision,
            "nodes"=>[Dict("id"=>id,"xyz"=>coordinates[string(id)]) for id in requested],"node_coordinates"=>coordinates)
    elseif action in ("parts","part_at_element")
        result=fe_edit_cached_parts(session;plane=get(raw,"plane",nothing))
        response=merge(Dict{String,Any}("ok"=>true,"session_id"=>session.id,"revision"=>session.revision),result)
        if action=="part_at_element"
            id=Int(get(raw,"element_id",get(raw,"eid",0)))
            index=findfirst(part->id in part["element_ids"],result["parts"])
            index===nothing&&throw(ArgumentError("Element $id is not in the current physical FE model. Pick a shell, beam or mass element in the current editing copy."))
            part=result["parts"][index];blocked=part["requires_cut"]
            response["part"]=part;response["element_ids"]=blocked ? Int[] : part["element_ids"];response["requires_cut"]=blocked
            if blocked;response["warning"]="The picked region is still connected across the cutting plane. Cut with duplicated seam nodes first, or explicitly detach shared boundary nodes before translating a plane-side selection.";end
        end
        return response
    end
    action=="context"&&return fe_edit_response(session;extra=Dict("initialized"=>true))
    if action=="export"
        return fe_edit_response(session;extra=Dict("name"=>session.source["name"],"deck_text"=>session.source["flattened"]))
    end
    started=time();timings=Dict{String,Any}()
    readonly=action in ("preview","cut_preview","candidates")
    t=time();mesh=readonly ? Dict{String,Any}("nodes"=>session.deck.nodes,"elements"=>session.deck.elements) : fe_edit_mesh(session.deck;copy_geometry=false);timings["mesh_capture_seconds"]=time()-t
    if action in ("preview","cut_preview")
        compact=action=="cut_preview"||Bool(get(raw,"compact",false))
        plane=fe_edit_plane_request(raw)
        sides=compact ? Dict() : fe_classify_mesh(mesh;point=plane.point,normal=plane.normal,tolerance=plane.tolerance)
        selected=compact ? Int[] : haskey(raw,"selection") ? fe_edit_selected(mesh,raw) : sides["positive"]
        intersections=fe_cut_intersections(mesh;point=plane.point,normal=plane.normal,side_length=plane.side_length,tolerance=plane.tolerance)
        second_intersections=Dict{String,Any}("segments"=>Any[],"intersected_elements"=>Int[],"warnings"=>String[])
        selection=get(raw,"selection",Dict())
        if get(selection,"kind",nothing)=="slab"
            second=fe_edit_plane_request(Dict("plane"=>get(selection,"second_plane",Dict())))
            second_intersections=fe_cut_intersections(mesh;point=second.point,normal=second.normal,side_length=second.side_length,tolerance=second.tolerance)
        end
        extra=Dict{String,Any}("plane"=>get(raw,"plane",raw),"side_elements"=>sides,"selected_element_ids"=>selected,
            "cut_segments"=>intersections["segments"],"intersected_element_ids"=>intersections["intersected_elements"],"cut_warnings"=>get(intersections,"warnings",String[]),
            "second_cut_segments"=>second_intersections["segments"],"second_intersected_element_ids"=>second_intersections["intersected_elements"],"second_cut_warnings"=>get(second_intersections,"warnings",String[]))
        if compact
            return merge(Dict{String,Any}("ok"=>true,"session_id"=>session.id,"revision"=>session.revision,
                "warnings"=>vcat(extra["cut_warnings"],extra["second_cut_warnings"])),extra)
        end
        return fe_edit_response(session;extra)
    elseif action=="candidates"
        result=fe_equivalence_candidates(mesh;tolerance=get(raw,"tolerance",nothing))
        groups=Any[]
        for ids in result["groups"]
            retained=minimum(ids);maxdistance=maximum(norm(_fe_edit_xyz(mesh["nodes"][id],"Node")-_fe_edit_xyz(mesh["nodes"][retained],"Node")) for id in ids)
            push!(groups,Dict("nodes"=>ids,"retained_node"=>retained,"max_distance"=>maxdistance))
        end
        return fe_edit_response(session;extra=Dict("candidate_groups"=>groups,"candidate_nodes"=>result["candidate_nodes"],"tolerance"=>result["tolerance"]))
    elseif action in ("undo","reset")
        action=="undo"&&isempty(session.history)&&throw(ArgumentError("There is no preceding FE edit to undo."))
        source=deepcopy(action=="undo" ? last(session.history) : session.initial_source)
        progress("Validating the restored editing snapshot")
        candidate=fe_edit_import_candidate(st,source,session.params,progress)
        action=="undo"&&pop!(session.history)
        action=="reset"&&empty!(session.history)
        fe_edit_commit!(st,session,source,candidate;push_history=false)
        return fe_edit_response(session;bytes=candidate.bytes)
    end
    progress("Editing the selected FE geometry")
    t=time();result=if action=="cut"
        plane=fe_edit_plane_request(raw)
        fe_cut_mesh(mesh;point=plane.point,normal=plane.normal,side_length=plane.side_length,duplicate_cut_nodes=Bool(get(raw,"duplicate_nodes",false)),tolerance=plane.tolerance)
    elseif action in ("translate","copy")
        ids=fe_edit_selected(mesh,raw)
        if action=="translate"
            fe_translate_mesh(mesh,ids;vector=get(raw,"vector",nothing),direction=get(raw,"direction",nothing),distance=get(raw,"distance",nothing),detach_shared=Bool(get(raw,"detach_shared",false)))
        else
            Bool(get(raw,"copy_loads",false))&&throw(ArgumentError("Copying loads or boundary conditions is not supported. Copies carry structure only; recreate their analysis cards explicitly."))
            fe_copy_mesh(mesh,ids;vector=get(raw,"vector",nothing),direction=get(raw,"direction",nothing),distance=get(raw,"distance",nothing),count=Int(get(raw,"count",1)))
        end
    elseif action=="equivalence"
        reviewed=haskey(raw,"operation_id") ? fe_edit_operation_groups(session,raw) : nothing
        groups=get(raw,"groups",Any[]);pairs=Any[]
        retained=Int[]
        for group in groups
            ids=group isa AbstractDict ? group["nodes"] : group
            length(ids)>1||continue
            master=group isa AbstractDict&&haskey(group,"retained_node") ? Int(group["retained_node"]) : minimum(Int.(ids))
            master in Int.(ids)||throw(ArgumentError("The retained equivalence node must belong to its selected group."))
            group isa AbstractDict&&haskey(group,"retained_node")&&push!(retained,master)
            append!(pairs,[[master,Int(id)] for id in ids if Int(id)!=master])
        end
        isempty(pairs)&&throw(ArgumentError("Select at least one reviewed candidate group to merge."))
        fe_merge_nodes(mesh,pairs;tolerance=reviewed===nothing ? get(raw,"tolerance",nothing) : reviewed["tolerance"],retained_nodes=retained)
    else
        throw(ArgumentError("Unknown FE editing action $action"))
    end
    timings["geometry_seconds"]=time()-t
    edited=result.mesh;report=result.report;mapping=get(report,"node_map",Dict{Int,Int}())
    t=time()
    conversions=fe_edit_preserve_beam_orientations!(session.deck,edited)
    if !isempty(conversions)
        report["beam_orientation_conversions"]=conversions
        warnings=get!(report,"warnings",String[])
        push!(warnings,"$(length(conversions)) affected CBAR/CBEAM orientation(s) were preserved as explicit BASIC vectors. Source orientation GRIDs remain available; offset flags, end offsets and releases retain their authored values.")
    end
    if action in ("cut","copy")
        selected=action=="copy" ? fe_edit_selected(mesh,raw) : Int[]
        fe_edit_mass_membership_guard(session.deck,action,report,selected)
    end
    action=="equivalence"&&fe_edit_equivalence_guard(session.deck,mapping)
    action=="translate"&&fe_edit_movement_guard(session.deck,edited,report)
    copies=get(report,"copies",Any[])
    if action=="copy"
        originalselected=Set(Int.(get(report,"selected_elements",get(raw,"element_ids",fe_edit_selected(mesh,raw)))))
        copiednodes=isempty(copies) ? Set{Int}() : Set(Int.(collect(keys(first(copies)["node_map"]))))
        for c in session.deck.records
            c.kind in ("CBUSH","CGAP")||continue
            fe_edit_int(fe_edit_field(c,1)) in originalselected||continue
            g0=fe_edit_orientation_grid(c)
            g0>0&&!(g0 in copiednodes)&&throw(ArgumentError("$(c.kind) $(c.fields[1]) uses orientation GRID $g0 outside the copied slice. Convert it to an explicit orientation vector or include that GRID's attached structure before copying."))
        end
    end
    timings["source_semantics_seconds"]=time()-t
    progress("Rebuilding the edited source deck")
    t=time()
    text=fe_edit_render(session.deck,edited;node_mapping=mapping,element_parents=get(report,"element_parents",Dict{Int,Int}()),node_provenance=get(report,"node_provenance",Dict()),duplicate_nodes=get(report,"duplicate_nodes",Dict{Int,Int}()),copied_node_maps=[row["node_map"] for row in copies],copied_element_maps=[row["element_map"] for row in copies])
    text=fe_edit_retained_rigid_notes(text,report,action,session.revision+1)
    timings["deck_render_seconds"]=time()-t
    t=time();source=imported_source(Dict("name"=>session.source["name"],"text"=>text,"format"=>"reference"));timings["source_capture_seconds"]=time()-t
    progress("Checking the edited deck, properties, connections and source analysis")
    t=time();candidate=fe_edit_import_candidate(st,source,session.params,progress);timings["native_verification_seconds"]=time()-t;timings["native_import"]=candidate.timings
    coincidence=nothing
    if action in ("translate","copy")
        progress("Checking only overlaps created by this operation")
        t=time();coincidence=fe_operation_equivalence_candidates(mesh,edited,report;tolerance=get(raw,"coincidence_tolerance",nothing));timings["operation_overlap_seconds"]=time()-t
        coincidence["candidate_groups"]=get(coincidence,"candidate_groups",get(coincidence,"groups",Any[]))
        coincidence["group_count"]=length(coincidence["candidate_groups"])
        coincidence["node_count"]=length(Set(Int(id) for group in coincidence["candidate_groups"] for id in group["nodes"]))
        coincidence["affected_node_count"]=length(Set(Int(id) for group in coincidence["candidate_groups"] for id in group["affected_nodes"]))
        coincidence["operation_affected_node_count"]=length(get(coincidence,"affected_nodes",Int[]))
        coincidence["created_node_count"]=length(get(coincidence,"created_nodes",Int[]))
        # Freeze the reviewed groups/pairs. No full meshes, coordinate maps or
        # unneeded per-node cohort dictionaries survive this request.
        for key in ("cohorts","source_nodes","affected_nodes","created_nodes");pop!(coincidence,key,nothing);end
        coincidence["revision"]=session.revision+1;coincidence["operation"]=action
        coincidence["operation_id"]=bytes2hex(SHA.sha256(session.id*string(session.revision+1)*source["signature"]*action))
    end
    part_result=nothing
    if action=="cut"
        progress("Identifying the connected cut parts")
        t=time();part_result=fe_edit_parts(candidate.deck;plane=get(raw,"plane",nothing));timings["parts_seconds"]=time()-t
    end
    warnings=copy(session.warnings)
    append!(warnings,String.(get(report,"warnings",String[])))
    if action=="cut"&&!isempty(get(report,"duplicate_nodes",Dict()))
        push!(warnings,"Duplicated seam nodes detach the positive cut side. Loads and supports on existing seam nodes remain on the original side; review that boundary before solving.")
    end
    fe_edit_commit!(st,session,source,candidate;warnings=unique(warnings))
    coincidence===nothing||(FE_EDIT_OPERATION_CANDIDATES[session.id]=coincidence)
    extra=Dict{String,Any}("operation"=>action,"report"=>report)
    if part_result!==nothing
        merge!(extra,part_result)
        FE_EDIT_PARTS_CACHE[session.id]=(revision=session.revision,key=fe_edit_parts_key(get(raw,"plane",nothing)),parts=part_result)
    end
    timings["operation_seconds"]=time()-started;extra["timings"]=timings
    progress("FE edit timing: geometry $(round(timings["geometry_seconds"];digits=2)) s; source $(round(timings["deck_render_seconds"];digits=2)) s; native verification $(round(timings["native_verification_seconds"];digits=2)) s; parts $(round(get(timings,"parts_seconds",0.);digits=2)) s")
    t=time();response=fe_edit_response(session;bytes=candidate.bytes,extra=extra);timings["response_prepare_seconds"]=time()-t
    timings["mesh_payload_bytes"]=length(candidate.bytes);timings["source_bytes"]=sizeof(text);timings["operation_seconds"]=time()-started
    response
end

function handle_fe_edit(st,req)
    progress=request_progress(st,req)
    try
        raw=JSON.parse(String(req.body));raw isa AbstractDict||throw(ArgumentError("Expected an FE editing request object"))
        result=lock(FE_EDIT_LOCK) do
            fe_edit_operation(st,raw,progress)
        end
        haskey(result,"mesh_msgpack_base64")&&progress("Encoding the verified edited mesh for the browser")
        started=time();response=json_response(result);encoded=time()-started
        push!(response.headers,"X-FE-Edit-Encode-Seconds"=>string(encoded))
        progress("done");response
    catch err
        error_response("FE editing: "*describe_error(err))
    end
end
