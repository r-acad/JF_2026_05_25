# Optional load-carrying shells and fittings for the defined movable surfaces.
const MOVABLE_STRUCTURE_DEFAULTS=Dict{String,Any}("surface"=>"","enabled"=>true,
    "skin_material"=>1,"web_material"=>1,"rib_material"=>1,
    "upper_thickness"=>.0015,"lower_thickness"=>.0015,"web_thickness"=>.002,"rib_thickness"=>.0015,
    "span_bays"=>4,"span_elements"=>2,"chord_elements"=>4,"height_elements"=>2,
    "secondary_spar"=>.5,"mesh_deflected"=>false)
const MOVABLE_ATTACHMENT_DEFAULTS=Dict{String,Any}("surface"=>"","eta"=>.5,"rib"=>1,"spar"=>"rear",
    "kind"=>"hinge","translation_stiffness"=>1e9,"tilt_stiffness"=>1e6,"hinge_stiffness"=>1e4)
is_movable_pid(pid)=31<=pid÷1_000_000<=35
movable_structure_rows(p)=get(p,"movable_structure.surfaces",Any[])
movable_attachments(p)=get(p,"movable_structure.attachments",Any[])
movable_enabled(p)=any(r->get(r,"enabled",false),movable_structure_rows(p))

function normalize_movable_structure(value,key)
    attachment=key=="movable_structure.attachments"
    defaults=attachment ? MOVABLE_ATTACHMENT_DEFAULTS : MOVABLE_STRUCTURE_DEFAULTS
    value isa AbstractVector&&length(value)<=(attachment ? 1000 : 100)||throw(ArgumentError("$key must be a bounded table of $(attachment ? 1000 : 100) rows"))
    out=Dict{String,Any}[];seen=Set()
    for raw in value
        raw isa AbstractDict&&all(k->k in keys(defaults),keys(raw))||throw(ArgumentError("$key contains missing or unknown structure fields"))
        row=merge(defaults,raw);name=row["surface"]
        name isa AbstractString&&!isempty(strip(name))&&length(name)<=80||throw(ArgumentError("$key needs a movable-surface name"))
        row["surface"]=strip(name)
        if attachment
            row["kind"] in ("hinge","rigid")||throw(ArgumentError("$name: attachment must be hinge or rigid"))
            row["spar"] in ("front","rear")||throw(ArgumentError("$name: choose front or rear main-box spar"))
            eta=row["eta"];eta isa Real&&!(eta isa Bool)&&isfinite(eta)&&0<=eta<=1||throw(ArgumentError("$name: attachment eta must be between 0 and 1"))
            row["eta"]=Float64(eta);row["rib"]=material_integer(row["rib"],"$name attachment main-box rib")
            for k in ("translation_stiffness","tilt_stiffness","hinge_stiffness")
                v=row[k];v isa Real&&!(v isa Bool)&&isfinite(v)&&(k=="hinge_stiffness" ? v>=0 : v>0)||throw(ArgumentError("$name: $k must be finite and $(k=="hinge_stiffness" ? "nonnegative" : "positive")"))
                row[k]=Float64(v)
            end
            token=(name,eta);token in seen&&throw(ArgumentError("$name has more than one attachment at eta $eta"));push!(seen,token)
        else
            name in seen&&throw(ArgumentError("Only one structure definition is allowed for $name"));push!(seen,name)
            for k in ("enabled","mesh_deflected");row[k] isa Bool||throw(ArgumentError("$name: $k must be on or off"));end
            for k in ("skin_material","web_material","rib_material");row[k]=material_integer(row[k],"$name $k");end
            for k in ("upper_thickness","lower_thickness","web_thickness","rib_thickness");row[k]=material_positive(row[k],"$name $k");end
            for k in ("span_bays","span_elements","chord_elements","height_elements")
                row[k]=material_integer(row[k],"$name $k");row[k]<=100||throw(ArgumentError("$name: $k must be at most 100"))
            end
            v=row["secondary_spar"];v isa Real&&!(v isa Bool)&&isfinite(v)&&0<=v<1||throw(ArgumentError("$name: secondary spar is 0 (none) or a fraction strictly between 0 and 1 of the movable chord"))
            row["secondary_spar"]=Float64(v)
        end
        push!(out,row)
    end
    out
end

function validate_movable_structure(p)
    surfaces=Dict(s["name"]=>s for s in normalize_movable_surfaces(get(p,"movable_surfaces.items",Any[])))
    rows=normalize_movable_structure(movable_structure_rows(p),"movable_structure.surfaces")
    attachments=normalize_movable_structure(movable_attachments(p),"movable_structure.attachments")
    for a in attachments
        any(r->r["surface"]==a["surface"],rows)||throw(ArgumentError("Attachment refers to missing structure $(a["surface"])"))
    end
    enabled=filter(r->r["enabled"],rows);isempty(enabled)&&return nothing
    get(p,"mass.structural_representation","distributed")=="distributed"||throw(ArgumentError("Movable-surface structures require Distributed structural mass to retain their own mass and hinge dynamics"))
    _,ribs,_=span_stations(make_wing(p),p)
    for r in enabled
        name=r["surface"];haskey(surfaces,name)||throw(ArgumentError("Structure refers to missing movable surface $name; reselect its geometry"))
        for k in ("skin_material","web_material","rib_material");material_definition(p,r[k]);end
        s=surfaces[name];aa=filter(a->a["surface"]==name,attachments)
        isempty(aa)&&throw(ArgumentError("$name needs at least one attachment to the main box"))
        for a in aa
            s["eta_start"]<=a["eta"]<=s["eta_end"]||throw(ArgumentError("$name: attachment eta is outside the movable surface"))
            a["rib"]<=length(ribs)||throw(ArgumentError("$name: main-box rib $(a["rib"]) does not exist"))
        end
        if s["edge"]=="leading"&&p["leading_edge.enabled"]
            throw(ArgumentError("$name: turn off the existing Leading Edge structure before meshing a leading-edge movable surface, to avoid overlapping structures"))
        end
    end
    nothing
end

function movable_shell_property(p,pid)
    family,index=divrem(pid,1_000_000);surface_index,station=divrem(index,1000)
    rows=movable_structure_rows(p);1<=surface_index<=length(rows)||throw(ArgumentError("Unknown movable property $pid"))
    row=rows[surface_index];part=("upper skin","lower skin","hinge web","secondary spar","rib")[family-30]
    thickness=row[("upper_thickness","lower_thickness","web_thickness","web_thickness","rib_thickness")[family-30]]
    material=material_definition(p,row[family<=32 ? "skin_material" : family<=34 ? "web_material" : "rib_material"])
    Dict{String,Any}("type"=>"PSHELL","construction"=>"monolithic","thickness_m"=>thickness,
        "material_id"=>material["id"],"material"=>material_payload(material),"nonstructural_mass_kg_m2"=>0.,
        "areal_mass_kg_m2"=>thickness*material["rho"],"movable_surface"=>row["surface"],"movable_part"=>part,
        "display_label"=>row["surface"]*" · "*part*" · "*(family==35 ? "rib " : "bay ")*string(station))
end

function movable_rotation(w,s,deflected)
    camber(eta,xc)=section_point(w,eta,xc,(zup(w,eta,xc)+zlo(w,eta,xc))/2)
    a,b=s["eta_start"],s["eta_end"]
    hinge(eta)=s["hinge_start"]+(s["hinge_end"]-s["hinge_start"])*(eta-a)/(b-a)
    h0,h1=camber(a,hinge(a)),camber(b,hinge(b));axis=unit3(h1.-h0)
    sine,cosine=sincosd(deflected ? s["deflection"] : 0.)
    rotate(point)=begin v=point.-h0;cross=cross3(axis,v);projection=sum(axis.*v);ntuple(k->h0[k]+cosine*v[k]+sine*cross[k]+(1-cosine)*projection*axis[k],3) end
    (;hinge,h0,h1,axis,rotate)
end

function movable_distinct_stations(values)
    sorted=sort!(Float64.(values));out=Float64[]
    for v in sorted
        (isempty(out)||v-last(out)>1e-10)&&push!(out,v)
    end
    out
end

"""Add independently meshed closed shells and bearing fittings; no aerodynamic loads are rerouted."""
function add_movable_structure!(reg,g,p,groups,eid)
    metadata=Dict{String,Any}("surfaces"=>Any[],"attachments"=>Any[],"node_etas"=>Dict{Int,Float64}())
    surfaces=Dict(s["name"]=>s for s in get(p,"movable_surfaces.items",Any[]));w=g.wing
    for (si,row) in enumerate(movable_structure_rows(p))
        row["enabled"]||continue
        s=surfaces[row["surface"]];a,b=s["eta_start"],s["eta_end"]
        rot=movable_rotation(w,s,row["mesh_deflected"]);aa=filter(r->r["surface"]==s["name"],movable_attachments(p))
        rib_etas=collect(range(a,b;length=row["span_bays"]+1))
        etas=movable_distinct_stations(vcat(collect(range(a,b;length=row["span_bays"]*row["span_elements"]+1)),rib_etas,
            [r["eta"] for r in aa],filter(t->a<t<b,g.etas),filter(t->a<t<b,loft_control_etas(w))))
        us=sort!(unique(vcat(collect(range(0.,1.;length=row["chord_elements"]+1)),row["secondary_spar"]>0 ? [row["secondary_spar"]] : Float64[])))
        nh=row["height_elements"];edge=s["edge"]=="trailing" ? 1. : 0.
        for eta in etas
            main=spar_surface_xc(w,spar_geometry(p),eta,s["edge"]=="trailing" ? :rear : :front)
            h=rot.hinge(eta)
            (s["edge"]=="trailing" ? h>=main-1e-9 : h<=main+1e-9)||throw(ArgumentError("$(s["name"]): hinge overlaps the main torsion box at eta $eta; move it outside the adjacent spar"))
        end
        localnodes=Dict{NTuple{3,Int},Int}();points=Dict{NTuple{3,Int},Int}();tol=max(w.mac,1.)*1e-11
        function node(i,j,k)
            get!(localnodes,(i,j,k)) do
                eta=etas[j+1];xc=rot.hinge(eta)+(edge-rot.hinge(eta))*us[i+1]
                lo,up=lower_point(w,eta,xc),upper_point(w,eta,xc);point=rot.rotate(lo.+(k/nh).*(up.-lo))
                key=ntuple(t->round(Int,point[t]/tol),3)
                get!(points,key) do
                    idx=length(reg.keys)+1;sentinel=(-3,idx,si);push!(reg.keys,sentinel);append!(reg.xyz,point);reg.index[sentinel]=idx;idx
                end
            end
        end
        caches=Dict{Tuple{Int,Int,Symbol},Any}()
        function shell(family,station,conn)
            nodes=unique(collect(conn));length(nodes)<3&&return
            kind=length(nodes)==3 ? :tria : :quad
            pid=family*1_000_000+si*1000+station
            name=("MOVABLE_UPPER_SKIN","MOVABLE_LOWER_SKIN","MOVABLE_HINGE_WEB","MOVABLE_SPAR_WEB","MOVABLE_RIB_WEBS")[family-30]
            gr=get!(caches,(family,station,kind)) do
                group=ElemGroup(name*(kind===:tria ? "_TRIAS" : "")*"_P"*string(pid),kind,pid);push!(groups,group);group
            end
            push!(gr.eids,eid);append!(gr.conn,nodes);eid+=1
        end
        for j in 0:length(etas)-2
            bay=clamp(searchsortedlast(rib_etas,(etas[j+1]+etas[j+2])/2),1,length(rib_etas)-1)
            for i in 0:length(us)-2
                shell(31,bay,(node(i,j,nh),node(i+1,j,nh),node(i+1,j+1,nh),node(i,j+1,nh)))
                shell(32,bay,(node(i,j,0),node(i,j+1,0),node(i+1,j+1,0),node(i+1,j,0)))
            end
            for i in unique(vcat([0,length(us)-1],row["secondary_spar"]>0 ? [findfirst(==(row["secondary_spar"]),us)-1] : Int[])),k in 0:nh-1
                shell(i==0 ? 33 : 34,bay,(node(i,j,k),node(i,j,k+1),node(i,j+1,k+1),node(i,j+1,k)))
            end
        end
        for (ri,eta) in enumerate(rib_etas),i in 0:length(us)-2,k in 0:nh-1
            j=argmin(abs.(etas.-eta))-1
            shell(35,ri,(node(i,j,k),node(i+1,j,k),node(i+1,j,k+1),node(i,j,k+1)))
        end
        for ((i,j,k),n) in localnodes;metadata["node_etas"][n]=etas[j+1];end
        push!(metadata["surfaces"],Dict("name"=>s["name"],"nodes"=>sort!(collect(values(points))),"eta_stations"=>etas,"rib_etas"=>rib_etas,"mesh_deflected"=>row["mesh_deflected"]))
        for attachment in aa
            eta=attachment["eta"];j=argmin(abs.(etas.-eta))-1
            fitting_nodes=unique([node(0,j,k) for k in 0:nh])
            # The virtual fitting lies on the straight rigid hinge axis. A
            # rigid local arm transfers loads to the curved shell cut if needed.
            t=(eta-a)/(b-a);center=rot.h0.+t.*(rot.h1.-rot.h0)
            free(point)=begin idx=add_free_node!(reg,point);old=reg.keys[idx];delete!(reg.index,old);reg.keys[idx]=(-4,idx,si);reg.index[reg.keys[idx]]=idx;idx end
            boxref,moveref=free(center),free(center)
            jr=g.ribs[attachment["rib"]];column=attachment["spar"]=="front" ? 0 : ni(g)
            # The two chord-adjacent columns provide a full-rank translation
            # cloud; a single line of spar nodes cannot define every rotation.
            # A run-out can merge the adjacent column into this spar. Search
            # inward for a genuinely separate column, keeping the cloud full rank.
            candidates=column==0 ? (1:ni(g)) : (ni(g)-1:-1:0)
            spar_lower=node!(reg,g,column,jr,0)
            neighbor=first(i for i in candidates if node!(reg,g,i,jr,0)!=spar_lower)
            boxnodes=unique(vcat([node!(reg,g,column,jr,k) for k in 0:g.nh],[node!(reg,g,neighbor,jr,k) for k in (0,g.nh)]))
            rec=merge(copy(attachment),Dict{String,Any}("box_ref"=>boxref,"surface_ref"=>moveref,
                "box_nodes"=>boxnodes,"surface_nodes"=>fitting_nodes,"origin"=>collect(center),"axis"=>collect(rot.axis)))
            for key in ("box_rbe3_eid","surface_rbe2_eid","joint_eid");rec[key]=eid;eid+=1;end
            rec["pid"]=36_000_000+length(metadata["attachments"])+1
            rec["cid"]=80_000_000+length(metadata["attachments"])+1
            push!(metadata["attachments"],rec)
        end
    end
    # Keep generated topology separate from input/Study parameters.
    return eid,metadata
end

function movable_connection_payload(m)
    collections=[Dict{String,Any}("name"=>"MOVABLE_BOX_FITTINGS","card"=>"RBE3","point_mass"=>false,"elements"=>Any[]),
        Dict{String,Any}("name"=>"MOVABLE_SURFACE_FITTINGS","card"=>"RBE2","point_mass"=>false,"elements"=>Any[]),
        Dict{String,Any}("name"=>"MOVABLE_HINGES","card"=>"CBUSH","point_mass"=>false,"elements"=>Any[]),
        Dict{String,Any}("name"=>"MOVABLE_RIGID_ATTACHMENTS","card"=>"RBE2","point_mass"=>false,"elements"=>Any[])]
    for a in movable_structure_data(m)["attachments"]
        properties=merge(copy(a),Dict("surface"=>a["surface"],"hinge_axis"=>a["axis"],"hinge_rotation_component"=>4,
            "axis_system"=>a["cid"],"stiffness_units"=>"translations N/m; rotations Nm/rad"))
        for (i,eid,nodes,type) in ((1,a["box_rbe3_eid"],vcat(a["box_ref"],a["box_nodes"]),"RBE3"),
                (2,a["surface_rbe2_eid"],vcat(a["surface_ref"],a["surface_nodes"]),"RBE2"),
                (a["kind"]=="rigid" ? 4 : 3,a["joint_eid"],[a["box_ref"],a["surface_ref"]],a["kind"]=="rigid" ? "RBE2" : "CBUSH"))
            push!(collections[i]["elements"],Dict("eid"=>eid,"type"=>type,"nodes"=>nodes.-1,"properties"=>properties))
        end
    end
    filter(c->!isempty(c["elements"]),collections)
end

function movable_coordinate_records(m)
    [begin
        x=Tuple(a["axis"]);y=unit3(cross3(abs(x[3])<.9 ? (0.,0.,1.) : (1.,0.,0.),x));z=cross3(x,y)
        Dict{String,Any}("id"=>a["cid"],"type"=>"RECTANGULAR","card"=>"CORD2R","origin"=>a["origin"],
            "x"=>collect(x),"y"=>collect(y),"z"=>collect(z),"usage"=>coordinate_usage_record(),
            "properties"=>Dict("Role"=>"Movable-surface attachment; x along hinge","Surface"=>a["surface"],"Reference ID"=>0,"Reference type"=>"RECTANGULAR"))
    end for a in movable_structure_data(m)["attachments"]]
end

function movable_structure_data(m)
    m.movable_structure
end

function write_movable_attachments(io,m)
    for a in movable_structure_data(m)["attachments"]
        comment!(io,a["surface"]*": "*a["kind"]*" attachment, main-box rib "*string(a["rib"])*" / "*a["spar"]*" spar")
        origin=Tuple(a["origin"]);x=Tuple(a["axis"]);y=unit3(cross3(abs(x[3])<.9 ? (0.,0.,1.) : (1.,0.,0.),x));z=cross3(x,y)
        card!(io,"CORD2R",(a["cid"],0,origin...,(origin.+z)...,(origin.+x)...))
        card!(io,"RBE3",Any[a["box_rbe3_eid"],nothing,m.node_ids[a["box_ref"]],123456,1.,123,m.node_ids[a["box_nodes"]]...])
        card!(io,"RBE2",Any[a["surface_rbe2_eid"],m.node_ids[a["surface_ref"]],123456,m.node_ids[a["surface_nodes"]]...])
        if a["kind"]=="rigid"
            card!(io,"RBE2",(a["joint_eid"],m.node_ids[a["box_ref"]],123456,m.node_ids[a["surface_ref"]]))
        else
            kt,kr,kh=a["translation_stiffness"],a["tilt_stiffness"],a["hinge_stiffness"]
            card!(io,"PBUSH",(a["pid"],"K",kt,kt,kt,kh,kr,kr))
            card!(io,"CBUSH",(a["joint_eid"],a["pid"],m.node_ids[a["box_ref"]],m.node_ids[a["surface_ref"]],nothing,nothing,nothing,a["cid"]))
        end
    end
end
