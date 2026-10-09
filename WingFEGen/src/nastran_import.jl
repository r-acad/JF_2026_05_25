# Imported decks are authoritative models. The Model facade supplies the
# existing viewer/job ID ordering; its placeholder Wing is never regenerated.
is_imported_model(m::Model)=haskey(m.params,"imported.native")
imported_native(m::Model)=m.params["imported.native"]
const IMPORTED_MODELS=Dict{String,Model}()
const IMPORTED_MODELS_LOCK=ReentrantLock()

function imported_source(raw)
    raw isa AbstractDict||throw(ArgumentError("Nastran import needs a name and source text"))
    function filename(value)
        value isa AbstractString||throw(ArgumentError("Imported filenames must be text"))
        entry=replace(String(value),'\\'=>'/')
        isempty(entry)||startswith(entry,"/")||occursin(':',entry)||any(c->Int(c)<32,entry) ? throw(ArgumentError("Use a relative uploaded filename: $(repr(entry))")) : nothing
        all(part->!isempty(part)&&part!=".."&&part!=".",split(entry,'/'))||throw(ArgumentError("Imported filenames cannot traverse directories"))
        return entry
    end
    name=filename(get(raw,"name","imported.bdf"));source=get(raw,"text",nothing)
    source isa AbstractString||throw(ArgumentError("Nastran source text is missing"))
    files=Dict(name=>String(source));includes=get(raw,"includes",Any[])
    includes isa AbstractVector&&length(includes)<=128||throw(ArgumentError("At most 128 uploaded INCLUDE files are allowed"))
    for row in includes
        row isa AbstractDict||throw(ArgumentError("Each INCLUDE needs name and text"))
        key=filename(get(row,"name",""));haskey(files,key)&&throw(ArgumentError("Duplicate uploaded filename $key"))
        value=get(row,"text",nothing);value isa AbstractString||throw(ArgumentError("INCLUDE $key has no text"));files[key]=String(value)
    end
    sum(ncodeunits,values(files))<=32*1024*1024||throw(ArgumentError("Uploaded Nastran source exceeds 32 MiB"))
    any(text->occursin('\0',text),values(files))&&throw(ArgumentError("Nastran source contains a NUL byte"))
    function resolve(key,active=String[])
        key in active&&throw(ArgumentError("Cyclic uploaded INCLUDE: $key"))
        length(active)<10||throw(ArgumentError("Uploaded INCLUDE nesting exceeds ten levels"))
        haskey(files,key)||throw(ArgumentError("Upload the referenced INCLUDE file: $key"))
        out=String[]
        for line in split(replace(files[key],"\r\n"=>"\n"),'\n')
            stripped=strip(line)
            if occursin(r"^INCLUDE(?:\s|,|$)"i,stripped)
                matchline=match(r"^INCLUDE\s*,?\s*(?:'([^']+)'|\"([^\"]+)\"|([^\s$]+))\s*(?:\$.*)?$"i,stripped)
                matchline===nothing&&throw(ArgumentError("Unsupported multiline or malformed INCLUDE: $stripped"))
                relative=filename(strip(something(matchline.captures...)))
                prefix=replace(dirname(key),'\\'=>'/');target=isempty(prefix)||prefix=="." ? relative : filename(prefix*"/"*relative)
                append!(out,resolve(target,vcat(active,key)))
            else
                push!(out,String(line))
            end
        end
        return out
    end
    flattened=join(resolve(name),"\n")
    signature=bytes2hex(SHA.sha256(JSON.json([(key,files[key]) for key in sort!(collect(keys(files)))])))
    return Dict{String,Any}("kind"=>"nastran","name"=>name,"text"=>String(source),"includes"=>deepcopy(includes),"flattened"=>flattened,"signature"=>signature)
end

function imported_case_specs(p)
    [(id=Int(row["id"]),label=String(row["label"]),params=p) for row in p["imported.cases"]]
end

function imported_material(model,mid)
    mat=get(model["MATs"],string(mid),Dict());type=haskey(mat,"E1") ? "MAT8" : haskey(mat,"G11") ? "MAT2" : "MAT1"
    result=Dict{String,Any}("id"=>Int(mid),"MID"=>Int(mid),"name"=>"Material $mid","type"=>type)
    for (source,target) in (("E","E_Pa"),("NU","nu"),("RHO","rho_kg_m3"));haskey(mat,source)&&(result[target]=mat[source]);end
    return result
end

function imported_section(nativeprop)
    shape=String(get(nativeprop,"TYPE","PBAR"));dimensions=Float64.(get(nativeprop,"DIMS",Float64[]))
    section=Dict{String,Any}("type"=>isempty(dimensions) ? "PBAR" : "PBARL","shape"=>shape,"dimensions_m"=>dimensions,"offset_y_m"=>0.,"offset_z_m"=>0.,"placement"=>"Imported native CBAR reference line; original offset cards retained in the solver")
    for (source,target) in (("A","area_m2"),("I1","I1_m4"),("I2","I2_m4"),("J","J_m4"));haskey(nativeprop,source)&&(section[target]=nativeprop[source]);end
    if (shape=="T"&&length(dimensions)==4)||(shape=="ROD"&&length(dimensions)==1)
        section["polygon_yz_m"]=sensitivity_analytic_section(shape,dimensions).polygon
    elseif shape=="BAR"&&length(dimensions)==2
        b,h=dimensions;section["polygon_yz_m"]=[[h/2,-b/2],[h/2,b/2],[-h/2,b/2],[-h/2,-b/2]]
    end
    return section
end

function imported_properties(model,group)
    pid=group.pid
    if group.kind===:bar
        prop=model["PBARLs"][string(pid)]
        return Dict{String,Any}("type"=>isempty(get(prop,"DIMS",[])) ? "PBAR" : "PBARL","pid"=>pid,"material"=>imported_material(model,prop["MID"]),"section"=>imported_section(prop))
    end
    prop=model["PSHELLs"][string(pid)];thickness=Float64(prop["T"])
    if haskey(prop,"PLY_DATA")
        plies=Any[]
        for ply in prop["PLY_DATA"]
            mid=Int(ply["mid"]);t=Float64(ply["z_top"]-ply["z_bot"])
            push!(plies,Dict("material"=>imported_material(model,mid),"thickness_m"=>t,"angle_deg"=>get(ply,"theta",0.)))
        end
        result=Dict{String,Any}("type"=>"PCOMP","pid"=>pid,"thickness_m"=>thickness,"plies"=>plies,"areal_mass_kg_m2"=>sum(p["thickness_m"]*get(p["material"],"rho_kg_m3",0.) for p in plies)+get(prop,"NSM",0.),"construction"=>"Imported laminate (original stacking sequence)","sandwich"=>false)
        if length(plies)==3&&plies[1]["material"]["id"]==plies[3]["material"]["id"]&&isapprox(plies[1]["thickness_m"],plies[3]["thickness_m"];rtol=1e-12)&&plies[1]["angle_deg"]==plies[3]["angle_deg"]
            merge!(result,Dict("sandwich"=>true,"face_thickness_m"=>plies[1]["thickness_m"],"core_thickness_m"=>plies[2]["thickness_m"],"face_material"=>plies[1]["material"],"core_material"=>plies[2]["material"]))
        end
        return result
    end
    mat=imported_material(model,prop["MID"])
    Dict{String,Any}("type"=>"PSHELL","pid"=>pid,"thickness_m"=>thickness,"material"=>mat,"material_id"=>prop["MID"],"areal_mass_kg_m2"=>thickness*get(mat,"rho_kg_m3",0.)+get(prop,"NSM",0.))
end

function imported_model(native,source,p;cards=Dict())
    ids=sort!([parse(Int,string(key)) for key in keys(native["GRIDs"])])
    isempty(ids)&&throw(ArgumentError("The deck contains no GRID nodes"))
    maximum(ids)<=typemax(Int32)||throw(ArgumentError("Viewer GRID IDs must fit signed Int32"))
    index=Dict(id=>i for (i,id) in enumerate(ids));xyz=Float64[x for id in ids for x in native["GRIDs"][string(id)]["X"]]
    all(isfinite,xyz)||throw(ArgumentError("Imported GRID coordinates must be finite"))
    params=Dict{String,Any}(deepcopy(p));params["fuel.enabled"]=false;params["loads.structure_inertia"]=false
    params["output.title"]=source["name"];params["output.solution"]=string(native["SOL"])
    params["imported.native"]=native;params["imported.source"]=source
    subs=native["CASE_CONTROL"]["SUBCASES"]
    rows=isempty(subs) ? [Dict("id"=>1,"label"=>"Subcase 1")] : [Dict("id"=>Int(sid),"label"=>String(get(row,"LABEL",get(row,"SUBTITLE","Subcase $sid")))) for (sid,row) in sort!(collect(subs);by=x->Int(first(x)))]
    rows=Dict{String,Any}[merge(row,Dict("result_required"=>Int(native["SOL"])!=105||get(get(subs,row["id"],Dict()),"STATSUB",nothing)!==nothing)) for row in rows]
    params["imported.cases"]=rows
    groups=ElemGroup[];lookup=Dict{Tuple{Symbol,Int},ElemGroup}();warnings=String[];unsupported=Dict{String,Int}()
    for (key,family) in (("CSHELLs",:shell),("CBARs",:bar))
        for (keyid,el) in sort!(collect(native[key]);by=x->Int(last(x)["ID"]))
            eid=Int(el["ID"]);pid=Int(el["PID"])
            nodes=family===:bar ? [el["GA"],el["GB"]] : el["NODES"]
            kind=family===:bar ? :bar : length(nodes)==3 ? :tria : length(nodes)==4 ? :quad : :unsupported
            if kind===:unsupported;card=String(el["TYPE"]);unsupported[card]=get(unsupported,card,0)+1;continue;end
            all(id->haskey(index,id),nodes)||throw(ArgumentError("Element $eid references a missing GRID"))
            gr=get!(lookup,(kind,pid)) do
                result=ElemGroup("IMPORTED_$(uppercase(string(kind)))_P$pid",kind,pid);push!(groups,result);result
            end
            push!(gr.eids,eid);append!(gr.conn,[index[id] for id in nodes])
            if kind===:bar
                g0=Int(get(el,"G0",0));v=g0==0 ? Float64.(get(el,"V",get(el,"X",[0.,1.,0.]))) : Float64.(native["GRIDs"][string(g0)]["X"])-Float64.(native["GRIDs"][string(nodes[1])]["X"])
                append!(gr.orient,v)
            end
        end
    end
    visual=Set(("CQUAD4","CQUADR","CTRIA3","CSHEAR","CBAR","RBE3","GRID"))
    for (card,data) in cards
        (startswith(card,"C")||startswith(card,"RBE")||card=="RSPLINE")&&!(card in visual)&&(unsupported[card]=length(data))
    end
    isempty(groups)&&push!(warnings,"No supported shell or CBAR elements are present; GRID locations are retained.")
    any(g->g.kind===:bar,groups)&&push!(warnings,"Beam section/axis glyphs use GRID reference lines and the source orientation vector. OFFT/CD transformations and WA/WB offsets are not represented by these glyphs; native analysis retains their exact source definitions.")
    !isempty(unsupported)&&push!(warnings,"Some cards are retained for solving but lack a full viewport representation: "*join(sort!(collect(keys(unsupported))),", "))
    push!(warnings,"Nastran has no declared unit system. Viewer units assume metres, newtons, kilograms and pascals; no conversion is performed.")
    params["imported.warnings"]=warnings;params["imported.unsupported_visual_cards"]=unsupported
    params["imported.inventory"]=Dict(key=>length(value) for (key,value) in cards)
    wing=make_wing(p);grid=BoxGrid(wing,[.2,.55],[0.,1.],1,[0,1],fill(.2,2,2),fill(.55,2,2),zeros(Int,2,2),Int[])
    spc=sort!(unique([index[Int(gid)] for row in native["SPC1s"] for gid in get(row,"G",get(row,"NODES",Int[])) if haskey(index,Int(gid))]))
    model=Model(params,wing,grid,ids,xyz,[(-2,i,-1) for i in eachindex(ids)],length(ids),groups,RBE3Spider[],spc,Float64[],Int[],0,Int[],Float64[],[("Source",source["name"]),("Analysis","SOL $(native["SOL"])")],[("Native parser","Original identifiers and case control retained",true)])
    return model
end

function imported_mesh_payload(m)
    native=imported_native(m);params=m.params;source=params["imported.source"];index=Dict(id=>i for (i,id) in enumerate(m.node_ids))
    groups=Any[Dict("name"=>gr.name,"kind"=>string(gr.kind),"pid"=>gr.pid,"base_pid"=>0,"base_group"=>gr.name,"card_types"=>Dict(string(eid)=>String(get(native[gr.kind===:bar ? "CBARs" : "CSHELLs"][string(eid)],"TYPE",gr.kind===:bar ? "CBAR" : "shell")) for eid in gr.eids),"count"=>length(gr.eids),"eids"=>blob_i32(gr.eids),"conn"=>blob_i32(gr.conn;offset=-1),"orient"=>blob_f32(gr.orient),"properties"=>imported_properties(native,gr),"axes"=>imported_element_axes(m,gr)) for gr in m.groups]
    emptyspider=Dict("count"=>0,"refs"=>blob_i32(Int[]),"eids"=>blob_i32(Int[]),"lines"=>blob_i32(Int[]),"elements"=>Any[])
    rbe=deepcopy(emptyspider);refs=Int[];eids=Int[];lines=Int[];elements=Any[]
    for (key,el) in get(native,"RBE3s",Dict())
        weights=[row isa NamedTuple ? Dict("wt"=>row.wt,"comps"=>row.comps,"grids"=>row.grids) : row for row in get(el,"WT_GROUPS",Any[])]
        ref=Int(el["REFGRID"]);connected=unique(Int[id for row in weights for id in row["grids"]]);haskey(index,ref)||continue
        filter!(id->haskey(index,id),connected);push!(refs,index[ref]);push!(eids,Int(el["ID"]));append!(lines,Int[i for id in connected for i in (index[ref],index[id])])
        push!(elements,Dict("eid"=>Int(el["ID"]),"ref"=>index[ref]-1,"reference_grid"=>ref,"connected_grids"=>connected,"reference_components"=>string(el["REFC"]),"weight_groups"=>weights))
    end
    merge!(rbe,Dict("count"=>length(refs),"refs"=>blob_i32(refs;offset=-1),"eids"=>blob_i32(eids),"lines"=>blob_i32(lines;offset=-1),"elements"=>elements))
    emptyloads=Dict("stations"=>Any[],"force_stations"=>Any[],"moment_stations"=>Any[],"fuel_stations"=>Any[],"structure_stations"=>Any[],"method"=>"imported","load_application_version"=>IMPORTED_LOAD_VERSION,"note"=>"Original Nastran load cards are authoritative; not wing-generated aerodynamic loads.")
    cases=[Dict("id"=>row["id"],"label"=>row["label"],"loads"=>get(get(params,"imported.loads",Dict()),row["id"],deepcopy(emptyloads))) for row in params["imported.cases"]]
    publicparams=Dict(k=>v for (k,v) in params if !startswith(k,"imported."))
    return Dict{String,Any}("ok"=>true,"format"=>"wingfegen-mesh-1","title"=>source["name"],"model_params"=>publicparams,
        "imported_signature"=>source["signature"],"imported_deck"=>Dict("signature"=>source["signature"],"name"=>source["name"],"solution"=>params["output.solution"],"cases"=>params["imported.cases"],"warnings"=>params["imported.warnings"],"unsupported_visual_cards"=>params["imported.unsupported_visual_cards"],"card_inventory"=>params["imported.inventory"]),
        "nodes"=>Dict("count"=>length(m.node_ids),"n_structural"=>m.n_struct,"ids"=>blob_i32(m.node_ids),"xyz"=>blob_f32(m.xyz)),"groups"=>groups,
        "rbe3"=>rbe,"fuel_rbe3"=>deepcopy(emptyspider),"spc"=>imported_supports(m),
        "aero"=>Dict("count"=>0,"sections"=>Any[],"n_loop"=>0,"xyz"=>blob_f32(Float64[]),"conn"=>blob_i32(Int[]),"n_per_node"=>0,"map"=>blob_i32(Int[]),"weights"=>blob_f32(Float64[])),
        "fuel"=>Dict("enabled"=>false,"bays"=>Any[],"volume_m3"=>0.),"weights"=>Dict("components"=>Any[]),"annotations"=>Dict("ribs"=>Any[],"stringers"=>Any[]),"stiffened_panels"=>Dict("panels"=>Any[]),"load_cases"=>cases,"loads"=>first(cases)["loads"],"bbox"=>bbox_of(m),"info"=>Any[Any[k,v] for (k,v) in m.info],"checks"=>Any[Any[n,d,ok] for (n,d,ok) in m.checks],"checks_pass"=>true)
end

function imported_element_axes(m,gr)
    centers=Float64[];xs=Float64[];ys=Float64[];zs=Float64[];lengths=Float64[]
    stride=gr.kind===:bar ? 2 : gr.kind===:quad ? 4 : 3
    for e in 1:n_elements(gr)
        points=[Tuple(m.xyz[3i-2:3i]) for i in gr.conn[stride*(e-1)+1:stride*e]]
        x,y,z=if gr.kind===:bar
            x=unit3(points[2].-points[1]);z=unit3(cross3(x,Tuple(gr.orient[3e-2:3e])));(x,cross3(z,x),z)
        else
            shell_geometric_frame(points)
        end
        append!(centers,sum.(eachrow(reduce(hcat,collect.(points))))./stride);append!(xs,x);append!(ys,y);append!(zs,z)
        push!(lengths,minimum(norm3(points[mod1(i+1,stride)].-points[i]) for i in 1:stride))
    end
    note=gr.kind===:bar ? "GRID-reference axes only: OFFT/CD transformations and WA/WB offsets are not displayed; native analysis retains the source beam frame." : "Imported geometric shell axes; source material orientation cards remain unchanged."
    Dict("centers"=>blob_f32(centers),"x"=>blob_f32(xs),"y"=>blob_f32(ys),"z"=>blob_f32(zs),"lengths"=>blob_f32(lengths),"frame_note"=>note)
end

function imported_supports(m)
    index=Dict(id=>i for (i,id) in enumerate(m.node_ids));components=Dict{Int,Set{Char}}()
    for row in imported_native(m)["SPC1s"],gid in row["NODES"]
        haskey(index,gid)||continue;union!(get!(components,index[gid],Set{Char}()),string(row["C"]))
    end
    nodes=sort!(collect(keys(components)));dofs=[join(sort!(collect(components[i]))) for i in nodes]
    Dict("count"=>length(nodes),"nodes"=>blob_i32(nodes;offset=-1),"node_components"=>dofs,"components"=>length(unique(dofs))==1 ? first(dofs) : "mixed","mode"=>"imported","note"=>"Union of source SPC sets; each analysis uses its original case-control SPC selection.","assignments"=>[Dict("node"=>i-1,"grid"=>m.node_ids[i],"components"=>join(sort!(collect(components[i]))),"ribs"=>Int[],"targets"=>["Imported SPC"]) for i in nodes])
end

function imported_prepare_loads!(native,m)
    model=imported_native(m);index=Dict(id=>i for (i,id) in enumerate(m.node_ids));X=permutedims(reshape(m.xyz,3,:));cases=Dict{Int,Any}()
    for (sid,row) in model["CASE_CONTROL"]["SUBCASES"]
        loads=Dict{String,Any}("stations"=>Any[],"force_stations"=>Any[],"moment_stations"=>Any[],"fuel_stations"=>Any[],"structure_stations"=>Any[],"method"=>"imported","load_application_version"=>IMPORTED_LOAD_VERSION,"summary"=>Any[])
        F=zeros(6length(m.node_ids));load=get(row,"LOAD",nothing)
        try
            load===nothing||native.Solver.resolve_loads(model,load,1.,index,Dict{Int,Any}(),X,F)
            for (i,gid) in enumerate(m.node_ids)
                force=F[6i-5:6i-3];moment=F[6i-2:6i]
                record=Dict{String,Any}("gid"=>gid,"node_index"=>i-1,"position"=>m.xyz[3i-2:3i],"eta"=>0.,"target_kind"=>"imported_grid","follower_forces"=>false)
                !iszero(norm(force))&&push!(loads["force_stations"],merge(record,Dict("force"=>force,"moment"=>zeros(3))))
                !iszero(norm(moment))&&push!(loads["moment_stations"],merge(record,Dict("force"=>zeros(3),"moment"=>moment)))
            end
            loads["note"]="Native equivalent applied nodal loads in BASIC axes, before constraint redistribution. Original load-card application remains unchanged."
        catch err
            loads["note"]="Load visualization unavailable: "*sprint(showerror,err)
            push!(m.params["imported.warnings"],"Subcase $sid: "*loads["note"])
        end
        cases[Int(sid)]=loads
    end
    m.params["imported.loads"]=cases
    m
end

imported_public_params(m)=Dict(k=>v for (k,v) in m.params if !startswith(k,"imported."))

function imported_results_payload(job)
    path,data=find_results_json(job.outdir);path===nothing&&throw(ArgumentError("No native result JSON was produced; inspect the solver log"))
    m=job.model;specs=load_case_specs(m.params);atype=String(get(data,"analysis_type",""));cases=Any[]
    subs=imported_native(m)["CASE_CONTROL"]["SUBCASES"]
    startswith(atype,"SOL105")&&(specs=filter(spec->get(subs[spec.id],"STATSUB",nothing)!==nothing,specs))
    isempty(specs)&&throw(ArgumentError("Native results have no matching source analysis subcase"))
    for spec in specs
        selected=imported_case_result(data,spec.id,subs,[s.id for s in specs])
        item=jfem_case_results_payload(job,path,selected;native_sid=spec.id)
        item["id"]=spec.id;item["label"]=spec.label;item["static_subcase_id"]=spec.id
        if startswith(atype,"SOL105")
            item["static_subcase_id"]=Int(subs[spec.id]["STATSUB"]);item["buckling_subcase_id"]=spec.id
        end
        item["model_params"]=imported_public_params(m);item["imported_signature"]=m.params["imported.source"]["signature"]
        push!(cases,item)
    end
    payload=copy(first(cases));payload["load_cases"]=cases;payload["load_case_independent"]=false
    payload
end

function imported_case_result(data,sid,subs,ids)
    atype=String(get(data,"analysis_type",""))
    (startswith(atype,"SOL101")||startswith(atype,"SOL106"))&&return static_case_result(data,sid,ids)
    selected=copy(data);modes=get(data,"modes",Any[])
    if startswith(atype,"SOL103")
        tagged=all(row->haskey(row,"sid"),modes)
        length(ids)>1&&!tagged&&throw(ArgumentError("Native modal results lack subcase ownership; refusing to mix source cases"))
        selected["modes"]=tagged ? filter(row->Int(row["sid"])==sid,modes) : modes
    elseif startswith(atype,"SOL105")
        preload=Int(subs[sid]["STATSUB"])
        tagged=all(row->haskey(row,"buckling_subcase_id")&&haskey(row,"static_subcase_id"),modes)
        length(ids)>1&&!tagged&&throw(ArgumentError("Native buckling results lack subcase ownership; refusing to mix source cases"))
        selected["modes"]=tagged ? filter(row->Int(row["buckling_subcase_id"])==sid&&Int(row["static_subcase_id"])==preload,modes) : modes
        states=get(data,"static_subcases",Any[])
        if !isempty(states)
            matching=filter(row->get(row,"static_subcase_id",nothing)==preload,states)
            length(matching)==1||throw(ArgumentError("No unique native preload for subcase $preload"))
            selected["static_displacements"]=only(matching)["static_displacements"]
        elseif length(ids)>1
            throw(ArgumentError("Native buckling results lack preload ownership"))
        end
    else
        throw(ArgumentError("Viewport results support native SOL101, SOL103, SOL105 and SOL106; received $atype"))
    end
    selected["eigenvalues"]=[get(row,"eigenvalue",0.) for row in selected["modes"]]
    selected
end
