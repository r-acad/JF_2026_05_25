# Optional load-carrying shells and fittings for the defined movable surfaces.
const MOVABLE_STRUCTURE_DEFAULTS=Dict{String,Any}("surface"=>"","enabled"=>true,
    "skin_material"=>1,"web_material"=>1,"rib_material"=>1,
    "upper_thickness"=>.0015,"lower_thickness"=>.0015,"web_thickness"=>.002,"rib_thickness"=>.0015,
    "span_bays"=>4,"span_elements"=>2,"chord_elements"=>4,"height_elements"=>2,
    "secondary_spar"=>.5,"mesh_deflected"=>false,"end_eta"=>0.,"max_rib_pitch_ratio"=>1.5)
const MOVABLE_ATTACHMENT_DEFAULTS=Dict{String,Any}("surface"=>"","eta"=>.5,"rib"=>1,"spar"=>"rear",
    "kind"=>"hinge","translation_stiffness"=>1e9,"tilt_stiffness"=>1e6,"hinge_stiffness"=>1e4,
    "fitting"=>"idealized","lug_material"=>1,"lug_thickness"=>.003,"lateral_stay"=>false,"actuator"=>false,"actuator_stiffness"=>1e7)
is_movable_pid(pid)=31<=pid÷1_000_000<=35 || pid÷1_000_000==37
movable_structural_end(row,s)=get(row,"end_eta",0.)==0 ? s["eta_end"] : row["end_eta"]
movable_structure_rows(p)=get(p,"movable_structure.surfaces",Any[])
movable_attachments(p)=get(p,"movable_structure.attachments",Any[])
movable_enabled(p)=any(r->get(r,"enabled",false),movable_structure_rows(p))

"""Resolve eta against physical main-box ribs; legacy rib numbers are advisory only."""
function snapped_movable_attachments(p,s,row,rib_etas)
    eligible=findall(eta->s["eta_start"]-1e-12<=eta<=movable_structural_end(row,s)+1e-12,rib_etas)
    aa=filter(a->a["surface"]==s["name"],movable_attachments(p))
    isempty(aa)&&return Dict{String,Any}[]
    isempty(eligible)&&throw(ArgumentError("$(s["name"]): no main-box rib lies inside the movable structural span; extend the surface or add a rib"))
    seen=Set{Int}();out=Dict{String,Any}[]
    for a in aa
        ri=eligible[argmin([abs(rib_etas[i]-a["eta"]) for i in eligible])]
        ri in seen&&throw(ArgumentError("$(s["name"]): multiple attachments snap to main-box rib $ri at eta $(rib_etas[ri]); choose a different rib for each attachment"))
        push!(seen,ri)
        push!(out,merge(copy(a),Dict{String,Any}("requested_eta"=>a["eta"],"eta"=>rib_etas[ri],"rib"=>ri)))
    end
    out
end

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
            row["fitting"] in ("idealized","shell_lugs")||throw(ArgumentError("$name: choose idealized fittings or triangular shell lugs"))
            for k in ("lateral_stay","actuator");row[k] isa Bool||throw(ArgumentError("$name: $k must be on or off"));end
            row["lug_material"]=material_integer(row["lug_material"],"$name lug material")
            row["lug_thickness"]=material_positive(row["lug_thickness"],"$name lug thickness")
            row["spar"] in ("front","rear")||throw(ArgumentError("$name: choose front or rear main-box spar"))
            eta=row["eta"];eta isa Real&&!(eta isa Bool)&&isfinite(eta)&&0<=eta<=1||throw(ArgumentError("$name: attachment eta must be between 0 and 1"))
            row["eta"]=Float64(eta);row["rib"]=material_integer(row["rib"],"$name attachment main-box rib")
            for k in ("translation_stiffness","tilt_stiffness","hinge_stiffness","actuator_stiffness")
                nonnegative=k in ("hinge_stiffness","actuator_stiffness")
                v=row[k];v isa Real&&!(v isa Bool)&&isfinite(v)&&(nonnegative ? v>=0 : v>0)||throw(ArgumentError("$name: $k must be finite and $(nonnegative ? "nonnegative" : "positive")"))
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
            v=row["end_eta"];v isa Real&&!(v isa Bool)&&isfinite(v)&&0<=v<=1||throw(ArgumentError("$name: structural end eta is 0 (whole surface) or a value in (0,1]"))
            row["end_eta"]=Float64(v)
            v=row["max_rib_pitch_ratio"];v isa Real&&!(v isa Bool)&&isfinite(v)&&v>=1||throw(ArgumentError("$name: maximum rib pitch ratio must be finite and at least 1"))
            row["max_rib_pitch_ratio"]=Float64(v)
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
    stations,ribs,_=span_stations(make_wing(p),p);rib_etas=stations[ribs.+1]
    for r in enabled
        name=r["surface"];haskey(surfaces,name)||throw(ArgumentError("Structure refers to missing movable surface $name; reselect its geometry"))
        for k in ("skin_material","web_material","rib_material");material_definition(p,r[k]);end
        s=surfaces[name];aa=snapped_movable_attachments(p,s,r,rib_etas)
        structural_end=movable_structural_end(r,s)
        s["eta_start"]<structural_end<=s["eta_end"]||throw(ArgumentError("$name: structural end eta must be beyond the surface start and no farther than its aerodynamic end"))
        isempty(aa)&&throw(ArgumentError("$name needs at least one attachment to the main box"))
        for a in aa
            s["eta_start"]<=a["eta"]<=structural_end||throw(ArgumentError("$name: attachment eta is outside the movable structure"))
            a["rib"]<=length(ribs)||throw(ArgumentError("$name: main-box rib $(a["rib"]) does not exist"))
            a["fitting"]=="shell_lugs"&&material_definition(p,a["lug_material"])
            if a["fitting"]=="shell_lugs"&&!a["lateral_stay"]&&a["kind"]=="rigid"
                throw(ArgumentError("$name: a rigid physical lug joint requires lateral RBE2 stays to transfer hinge-axis torque through a geometric lever arm. An axial actuator transfers its force directly through the upper spar-cap nodes and does not require this option."))
            end
        end
        if s["edge"]=="leading"&&p["leading_edge.enabled"]
            throw(ArgumentError("$name: turn off the existing Leading Edge structure before meshing a leading-edge movable surface, to avoid overlapping structures"))
        end
    end
    nothing
end

"""Reject a nonunique static equilibrium; keep geometry, deck export and free-hinge modes available."""
function validate_movable_run(p;solution=String(get(p,"output.solution","101")))
    String(solution) in ("101","105","106")||return nothing
    attachments=movable_attachments(p)
    free=String[]
    for row in movable_structure_rows(p)
        get(row,"enabled",true)||continue
        aa=filter(a->a["surface"]==row["surface"],attachments)
        isempty(aa)&&continue # Geometry validation reports missing connections.
        any(a->a["kind"]=="rigid"||(get(a,"fitting","idealized")=="idealized"&&a["hinge_stiffness"]>0)||(get(a,"actuator",false)&&get(a,"actuator_stiffness",1e7)>0),aa)&&continue
        push!(free,row["surface"])
    end
    isempty(free)||throw(ArgumentError("SOL$solution cannot run with an unrestrained movable-surface hinge: $(join(free,", ")). Select at least one actuator with positive axial stiffness, a finite legacy hinge restraint, or a rigid attachment. The free rotation makes static equilibrium nonunique, even at zero hinge torque. Geometry and deck export remain available; SOL103 preserves the free hinge mode."))
    nothing
end

function movable_shell_property(p,pid)
    family,index=divrem(pid,1_000_000);surface_index,station=divrem(index,1000)
    if family==37
        attachments=movable_attachments(p);1<=index<=length(attachments)||throw(ArgumentError("Unknown movable lug property $pid"))
        row=attachments[index];surface=row["surface"];thickness=row["lug_thickness"];material=material_definition(p,row["lug_material"])
        return Dict{String,Any}("type"=>"PSHELL","construction"=>"monolithic","thickness_m"=>thickness,
            "material_id"=>material["id"],"material"=>material_payload(material),"nonstructural_mass_kg_m2"=>0.,
            "areal_mass_kg_m2"=>thickness*material["rho"],"movable_surface"=>surface,"movable_part"=>"hinge lugs",
            "display_label"=>surface*" - hinge lugs - attachment "*string(index),"attachment_eta"=>row["eta"])
    end
    rows=movable_structure_rows(p);1<=surface_index<=length(rows)||throw(ArgumentError("Unknown movable property $pid"))
    row=rows[surface_index];part=("upper skin","lower skin","front spar","secondary spar","rib")[family-30]
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
    front_spar(eta)=movable_chord_coordinate(s,"front_spar",eta)
    h0,h1=movable_hinge_endpoints(w,s);axis=unit3(h1.-h0)
    sine,cosine=sincosd(deflected ? s["deflection"] : 0.)
    rotate(point)=begin v=point.-h0;cross=cross3(axis,v);projection=sum(axis.*v);ntuple(k->h0[k]+cosine*v[k]+sine*cross[k]+(1-cosine)*projection*axis[k],3) end
    unrotate(point)=begin v=point.-h0;cross=cross3(axis,v);projection=sum(axis.*v);ntuple(k->h0[k]+cosine*v[k]-sine*cross[k]+(1-cosine)*projection*axis[k],3) end
    (;hinge,front_spar,h0,h1,axis,rotate,unrotate)
end

function movable_distinct_stations(values)
    sorted=sort!(Float64.(values));out=Float64[]
    for v in sorted
        (isempty(out)||v-last(out)>1e-10)&&push!(out,v)
    end
    out
end

"""Intersect a fitting plane with the actual spar mesh, retaining its connectivity.

New cut GRIDs are massless interpolation references on existing shell edges;
six explicit MPC equations interpolate their displacement and rotation without
adding an elastic member. An existing GRID on the plane is reused directly.
Only real quadrilateral boundary edges are interpolated: an invented diagonal
would not use the four-node shell's actual shape functions. The fitting edge
joins consecutive boundary intersections within the exact fitting plane.
"""
function movable_spar_cut!(reg,quads,origin,normal,free,tol,label)
    position(n)=reg.xyz[3n-2:3n]
    links=Any[];segments=Set{Tuple{Int,Int}}();cache=Dict{NTuple{3,Int},Int}()
    function crossing(n1,n2,d1,d2)
        abs(d1)<=tol&&return n1
        abs(d2)<=tol&&return n2
        t=d1/(d1-d2);point=(1-t).*position(n1).+t.*position(n2)
        key=ntuple(k->round(Int,point[k]/tol),3)
        get!(cache,key) do
            ref=free(point);push!(links,Dict{String,Any}("ref"=>ref,"nodes"=>[n1,n2],"weights"=>[1-t,t],"components"=>123456));ref
        end
    end
    for quad in quads
        d=[sum(normal.*(position(n).-origin)) for n in quad]
        all(x->abs(x)<=tol,d)&&throw(ArgumentError("$label: fitting plane lies along the spar instead of crossing it; change the hinge or spar geometry"))
        hits=Int[]
        for (i,j) in ((1,2),(2,3),(3,4),(4,1))
            if abs(d[i])<=tol&&abs(d[j])<=tol
                append!(hits,(quad[i],quad[j]))
            elseif abs(d[i])<=tol||abs(d[j])<=tol||signbit(d[i])!=signbit(d[j])
                push!(hits,crossing(quad[i],quad[j],d[i],d[j]))
            end
        end
        unique!(hits)
        length(hits)>2&&throw(ArgumentError("$label: a warped spar cell has an ambiguous fitting-plane cut; refine the spar mesh or move the attachment"))
        length(hits)==2&&push!(segments,minmax(hits...))
    end
    isempty(segments)&&throw(ArgumentError("$label: the hinge fitting plane misses the structural spar; move the attachment inward or adjust the hinge line"))
    adjacent=Dict{Int,Set{Int}}()
    for (a,b) in segments;push!(get!(adjacent,a,Set{Int}()),b);push!(get!(adjacent,b,Set{Int}()),a);end
    ends=sort!([n for (n,neighbors) in adjacent if length(neighbors)==1];by=n->position(n)[3])
    length(ends)==2&&all(length(v)<=2 for v in values(adjacent))||throw(ArgumentError("$label: the fitting plane has multiple or branched spar intersections; adjust the hinge or attachment geometry"))
    ordered=Int[first(ends)];previous=0
    while last(ordered)!=last(ends)
        current=last(ordered);next=only(setdiff(adjacent[current],Set([previous])))
        next in ordered&&throw(ArgumentError("$label: closed spar intersection cannot define a lug"))
        push!(ordered,next);previous=current
    end
    length(ordered)==length(adjacent)||throw(ArgumentError("$label: disconnected spar intersections cannot define one lug"))
    ordered,links
end

include("movable_rib_layout.jl")

"""Add movable shells, physical/idealized fittings and separate aerodynamic load references."""
function add_movable_structure!(reg,g,p,groups,eid)
    metadata=Dict{String,Any}("surfaces"=>Any[],"attachments"=>Any[],"load_references"=>Any[],"node_etas"=>Dict{Int,Float64}())
    surfaces=Dict(s["name"]=>s for s in get(p,"movable_surfaces.items",Any[]));w=g.wing
    for (si,row) in enumerate(movable_structure_rows(p))
        row["enabled"]||continue
        s=surfaces[row["surface"]];a,b=s["eta_start"],movable_structural_end(row,s)
        rot=movable_rotation(w,s,row["mesh_deflected"]);aa=snapped_movable_attachments(p,s,row,g.etas[g.ribs.+1])
        aa=movable_attachment_planes(g,s,row,rot,aa)
        rib_layout=movable_master_rib_layout(a,b,row,aa);rib_etas=[r["eta"] for r in rib_layout]
        etas=movable_distinct_stations(vcat([lo+(hi-lo)*k/row["span_elements"] for (lo,hi) in zip(rib_etas[1:end-1],rib_etas[2:end]) for k in 0:row["span_elements"]],
            filter(t->a<t<b,g.etas),filter(t->a<t<b,loft_control_etas(w))))
        us=sort!(unique(vcat(collect(range(0.,1.;length=row["chord_elements"]+1)),row["secondary_spar"]>0 ? [row["secondary_spar"]] : Float64[])))
        nh=row["height_elements"];edge=s["edge"]=="trailing" ? 1. : 0.
        rib_node_etas=movable_rib_eta_grid(w,s,row,rot,rib_layout,aa,us,nh)
        actual_eta(i,j,k)=begin
            eta=etas[j+1];bay=clamp(searchsortedlast(rib_etas,eta),1,length(rib_etas)-1)
            t=(eta-rib_etas[bay])/(rib_etas[bay+1]-rib_etas[bay])
            (1-t)*rib_node_etas[i+1,bay,k+1]+t*rib_node_etas[i+1,bay+1,k+1]
        end
        for eta in unique(vcat(etas,[actual_eta(i,j,k) for i in 0:length(us)-1 for j in 0:length(etas)-1 for k in 0:nh]))
            main=spar_surface_xc(w,spar_geometry(p),eta,s["edge"]=="trailing" ? :rear : :front)
            h=rot.front_spar(eta)
            (s["edge"]=="trailing" ? h>=main-1e-9 : h<=main+1e-9)||throw(ArgumentError("$(s["name"]): control front spar overlaps the main torsion box at eta $eta; move it outside the adjacent spar"))
        end
        localnodes=Dict{NTuple{3,Int},Int}();points=Dict{NTuple{3,Int},Int}();tol=max(w.mac,1.)*1e-11
        function node(i,j,k)
            get!(localnodes,(i,j,k)) do
                eta=actual_eta(i,j,k);xc=rot.front_spar(eta)+(edge-rot.front_spar(eta))*us[i+1]
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
        free(point)=begin
            idx=add_free_node!(reg,point);old=reg.keys[idx];delete!(reg.index,old)
            reg.keys[idx]=(-4,idx,si);reg.index[reg.keys[idx]]=idx;idx
        end
        rib_sections=Any[]
        for (ri,eta) in enumerate(rib_etas)
            j=argmin(abs.(etas.-eta))-1
            perimeter=unique(vcat([node(i,j,k) for i in 0:length(us)-1 for k in (0,nh)],
                [node(i,j,k) for i in (0,length(us)-1) for k in 0:nh]))
            push!(rib_sections,Dict("eta"=>eta,"front_lower"=>node(0,j,0),"front_upper"=>node(0,j,nh),
                "edge_lower"=>node(length(us)-1,j,0),"edge_upper"=>node(length(us)-1,j,nh),"perimeter_nodes"=>perimeter,
                "lower_nodes"=>[node(i,j,0) for i in 0:length(us)-1],"upper_nodes"=>[node(i,j,nh) for i in 0:length(us)-1],
                "master_attachment"=>rib_layout[ri]["attachment"],"gap_refinement"=>get(rib_layout[ri],"gap_refinement",false)))
            # The aerodynamic reference follows the actual oriented section,
            # not a disconnected constant-eta airfoil point.
            point=sum(reg.xyz[3n-2:3n] for n in perimeter)./length(perimeter)
            reference_eta=sum(actual_eta(i,j,k) for i in 0:length(us)-1 for k in (0,nh))/(2length(us))
            ref=free(point);metadata["node_etas"][ref]=reference_eta
            push!(metadata["load_references"],Dict("surface"=>s["name"],"eid"=>eid,"ref"=>ref,
                "nodes"=>perimeter,"eta"=>reference_eta,"rib_eta"=>eta,"position"=>collect(point)));eid+=1
        end
        for ((i,j,k),n) in localnodes;metadata["node_etas"][n]=actual_eta(i,j,k);end
        push!(metadata["surfaces"],Dict("name"=>s["name"],"nodes"=>sort!(collect(values(points))),
            "eta_stations"=>etas,"rib_etas"=>rib_etas,"rib_sections"=>rib_sections,"rib_layout"=>rib_layout,"nominal_rib_pitch_eta"=>(b-a)/row["span_bays"],"max_rib_pitch_ratio"=>row["max_rib_pitch_ratio"],"mesh_deflected"=>row["mesh_deflected"],
            "structural_eta_start"=>a,"structural_eta_end"=>b,
            "aerodynamic_eta_start"=>s["eta_start"],"aerodynamic_eta_end"=>s["eta_end"]))
        for (ai,attachment) in enumerate(aa)
            eta=attachment["eta"];j=argmin(abs.(etas.-eta))-1
            fitting_nodes=unique([node(0,j,k) for k in 0:nh])
            # The main rib anchors the lug plane. A swept hinge generally meets
            # that plane at a different span position than the rib datum itself.
            center=attachment["hinge_center"]
            jr=g.ribs[attachment["rib"]];column=attachment["spar"]=="front" ? 0 : ni(g)
            base=[node!(reg,g,column,jr,k) for k in 0:g.nh]
            plane_normal=attachment["plane_normal"]
            interpolation_links=Any[];hinge_eta=attachment["hinge_eta"];underside_fitting=nothing
            if attachment["fitting"]=="shell_lugs"
                main_quads=[(node!(reg,g,column,j,k),node!(reg,g,column,j+1,k),node!(reg,g,column,j+1,k+1),node!(reg,g,column,j,k+1)) for j in 0:nj(g)-1 for k in 0:g.nh-1]
                base,main_links=movable_spar_cut!(reg,main_quads,center,plane_normal,free,tol,"$(s["name"]) main-box lug at rib $(attachment["rib"])")
                if attachment["underside_lug"]
                    underside_fitting=movable_underside_fitting(reg,[node(i,j,0) for i in 0:length(us)-1],[node(i,j,nh) for i in 0:length(us)-1],
                        center,plane_normal,"$(s["name"]) underside fitting at rib $(attachment["rib"])")
                    fitting_nodes=underside_fitting.foot_nodes
                end
                append!(interpolation_links,main_links)
                for link in interpolation_links;link["eid"]=eid;eid+=1;end
            end
            boxref,moveref=free(center),free(center)
            knee=underside_fitting!==nothing&&underside_fitting.knee_point!==nothing ? free(underside_fitting.knee_point) : 0
            knee>0&&(metadata["node_etas"][knee]=(rot.unrotate(underside_fitting.knee_point)[2]-w.root_ref_y)/w.semispan)
            metadata["node_etas"][boxref]=metadata["node_etas"][moveref]=hinge_eta
            candidates=column==0 ? (1:ni(g)) : (ni(g)-1:-1:0)
            neighbor=first(i for i in candidates if node!(reg,g,i,jr,0)!=base[1])
            boxnodes=unique(vcat(base,[node!(reg,g,neighbor,jr,k) for k in (0,g.nh)]))
            rec=merge(copy(attachment),Dict{String,Any}("box_ref"=>boxref,"surface_ref"=>moveref,
                "box_nodes"=>boxnodes,"surface_nodes"=>fitting_nodes,"origin"=>collect(center),"axis"=>collect(rot.axis),
                "lateral_links"=>Any[],"lug_eids"=>Int[],"interpolation_links"=>interpolation_links,
                "hinge_eta"=>hinge_eta,"lug_plane_normal"=>collect(plane_normal),"lug_orientation"=>s["kind"]=="flap"&&!attachment["underside_lug"] ? "flight direction" : "normal to hinge",
                "control_lug_attachment"=>attachment["underside_lug"] ? "lower skin" : "front spar","master_rib_index"=>argmin(abs.(rib_etas.-eta))))
            rec["lug_shape"]=underside_fitting===nothing ? "front-spar fan" : underside_fitting.shape
            knee>0&&(rec["lug_knee_node"]=knee)
            if attachment["fitting"]=="shell_lugs"
                pid=37_000_000+findfirst(r->r["surface"]==s["name"]&&r["eta"]==attachment["requested_eta"],movable_attachments(p))
                lug=ElemGroup("MOVABLE_HINGE_LUGS_P"*string(pid),:tria,pid)
                main_triangles=[(n1,n2,boxref) for (n1,n2) in zip(base[1:end-1],base[2:end])]
                control_triangles=underside_fitting===nothing ? [(n1,n2,moveref) for (n1,n2) in zip(fitting_nodes[1:end-1],fitting_nodes[2:end])] :
                    [ntuple(i->triangle[i]==0 ? moveref : triangle[i]==-1 ? knee : triangle[i],3) for triangle in underside_fitting.triangles]
                for (side,triangles) in (("main box",main_triangles),("movable surface",control_triangles))
                    for (n1,n2,tip) in triangles
                        p1=reg.xyz[3n1-2:3n1];p2=reg.xyz[3n2-2:3n2];p3=reg.xyz[3tip-2:3tip]
                        area2=sqrt(sum(abs2,cross3(p2.-p1,p3.-p1)))
                        area2>tol*max(sqrt(sum(abs2,p2.-p1)),tol)||throw(ArgumentError("$(s["name"]): $side hinge lug at eta $eta has zero area. Separate the true hinge line from the control front spar and main-box spar, or use idealized fittings."))
                        push!(lug.eids,eid);push!(rec["lug_eids"],eid);append!(lug.conn,(n1,n2,tip));eid+=1
                        for n in (n1,n2)
                            point=reg.xyz[3n-2:3n];reference=side=="main box" ? point : rot.unrotate(point)
                            get!(metadata["node_etas"],n,(reference[2]-w.root_ref_y)/w.semispan)
                        end
                    end
                end
                push!(groups,lug);rec["lug_pid"]=pid
                if attachment["lateral_stay"]
                    nr=attachment["rib"]<length(g.ribs) ? attachment["rib"]+1 : attachment["rib"]-1
                    nr>=1||throw(ArgumentError("$(s["name"]): a lateral stay needs a neighboring main-box rib"))
                    rj=argmin(abs.(rib_etas.-eta));next=rj<length(rib_etas) ? rj+1 : rj-1
                    next>=1||throw(ArgumentError("$(s["name"]): a lateral stay needs a neighboring movable rib"))
                    targets=(node!(reg,g,column,g.ribs[nr],g.nh),node(0,argmin(abs.(etas.-rib_etas[next]))-1,nh))
                    for (tip,target) in zip((boxref,moveref),targets)
                        # The hinge tip is independent. Only translations of the
                        # adjacent upper-cap node are dependent on this arm.
                        push!(rec["lateral_links"],Dict("eid"=>eid,"ref"=>tip,"node"=>target,"components"=>123));eid+=1
                    end
                end
            else
                for key in ("box_rbe3_eid","surface_rbe2_eid");rec[key]=eid;eid+=1;end
            end
            rec["joint_eid"]=eid;eid+=1
            rec["pid"]=36_000_000+length(metadata["attachments"])+1
            rec["cid"]=80_000_000+si;rec["frame_origin"]=collect(rot.h0)
            eid=add_movable_actuator!(reg,rec,node!(reg,g,ni(g),jr,g.nh),node(0,j,nh),length(metadata["attachments"])+1,eid)
            push!(metadata["attachments"],rec)
        end
    end
    dependent=Dict{Int,String}(r.node=>"structural constraint" for r in support_assignments(g,reg.index,p) if any(c->c in r.components,"123"))
    for a in metadata["attachments"]
        if a["fitting"]=="idealized"
            for n in a["surface_nodes"]
                haskey(dependent,n)&&throw(ArgumentError("$(a["surface"]): attachments share a dependent fitting node; choose separate ribs"))
                dependent[n]="idealized fitting"
            end
        end
    end
    for a in metadata["attachments"],link in a["lateral_links"]
        n=link["node"]
        haskey(dependent,n)&&throw(ArgumentError("$(a["surface"]): lateral stays share an upper-cap node with a structural constraint, another stay or fitting. Use distinct unconstrained adjacent ribs or disable one lateral stay."))
        dependent[n]="lateral stay"
    end
    # Keep generated topology separate from input/Study parameters.
    return eid,metadata
end

function movable_connection_payload(m)
    definitions=(("MOVABLE_BOX_FITTINGS","RBE3"),("MOVABLE_SURFACE_FITTINGS","RBE2"),
        ("MOVABLE_HINGES","CBUSH"),("MOVABLE_RIGID_ATTACHMENTS","RBE2"),
        ("MOVABLE_LATERAL_STAYS","RBE2"),("MOVABLE_AERO_LOADS","RBE3"),("MOVABLE_REVOLUTE_JOINTS","RBE2"),
        ("MOVABLE_LUG_INTERPOLATION","MPC"))
    collections=[Dict{String,Any}("name"=>name,"card"=>card,"point_mass"=>false,"elements"=>Any[]) for (name,card) in definitions]
    add(i,eid,nodes,properties)=push!(collections[i]["elements"],Dict("eid"=>eid,"type"=>definitions[i][2],"nodes"=>nodes.-1,"properties"=>properties))
    for a in movable_structure_data(m)["attachments"]
        properties=merge(copy(a),Dict("surface"=>a["surface"],"hinge_axis"=>a["axis"],"hinge_rotation_component"=>4,
            "axis_system"=>a["cid"],"stiffness_units"=>"translations N/m; rotations Nm/rad"))
        if a["fitting"]=="idealized"
            add(1,a["box_rbe3_eid"],vcat(a["box_ref"],a["box_nodes"]),properties)
            add(2,a["surface_rbe2_eid"],vcat(a["surface_ref"],a["surface_nodes"]),properties)
        end
        physical_hinge=a["fitting"]=="shell_lugs"&&a["kind"]=="hinge"
        physical_hinge&&(properties["Relative joined components"]="12356";properties["Released hinge component"]=4)
        add(a["kind"]=="rigid" ? 4 : physical_hinge ? 7 : 3,a["joint_eid"],[a["box_ref"],a["surface_ref"]],properties)
        haskey(a,"actuator_eid")&&add(3,a["actuator_eid"],a["actuator_nodes"],merge(properties,Dict(
            "Role"=>"Axial actuator; only local K1","pid"=>a["actuator_pid"],"axis_system"=>a["actuator_cid"],
            "K1_N_per_m"=>a["K1_N_per_m"],"stiffness_units"=>"axial translation N/m")))
        for link in a["lateral_links"];add(5,link["eid"],[link["ref"],link["node"]],merge(properties,link));end
        for link in get(a,"interpolation_links",Any[])
            add(8,link["eid"],vcat(link["ref"],link["nodes"]),merge(properties,link,Dict("Role"=>"Spar-edge interpolation for planar hinge lug")))
        end
    end
    for r in get(movable_structure_data(m),"load_references",Any[])
        add(6,r["eid"],vcat(r["ref"],r["nodes"]),Dict("surface"=>r["surface"],"Role"=>"Movable aerodynamic load distribution","eta"=>r["eta"]))
    end
    filter(c->!isempty(c["elements"]),collections)
end

function movable_grid_frames(m)
    Dict(n=>a["cid"] for a in movable_structure_data(m)["attachments"] if a["fitting"]=="shell_lugs" for n in (a["box_ref"],a["surface_ref"]))
end
function movable_coordinate_records(m)
    attachments=movable_structure_data(m)["attachments"]
    frames=[begin
        x=Tuple(a["axis"]);y=unit3(cross3(abs(x[3])<.9 ? (0.,0.,1.) : (1.,0.,0.),x));z=cross3(x,y)
        usage=coordinate_usage_record();usage["grid_cd"]=2count(r->r["cid"]==a["cid"]&&r["fitting"]=="shell_lugs",attachments)
        coordinate_usage!(Dict{String,Any}("id"=>a["cid"],"type"=>"RECTANGULAR","card"=>"CORD2R","origin"=>a["frame_origin"],
            "x"=>collect(x),"y"=>collect(y),"z"=>collect(z),
            "properties"=>Dict{String,Any}("Role"=>"Movable-surface hinge axis; x along hinge","Surface"=>a["surface"],"Reference ID"=>0,"Reference type"=>"RECTANGULAR")),usage)
    end for a in unique(a->a["cid"],attachments)]
    append!(frames,[movable_actuator_coordinates(a) for a in attachments if haskey(a,"actuator_eid")])
    frames
end

function movable_structure_data(m)
    m.movable_structure
end

function write_movable_attachments(io,m)
    written_frames=Set{Int}()
    for a in movable_structure_data(m)["attachments"]
        comment!(io,a["surface"]*": "*a["kind"]*" attachment, main-box rib "*string(a["rib"])*" / "*a["spar"]*" spar")
        origin=Tuple(a["frame_origin"]);x=Tuple(a["axis"]);y=unit3(cross3(abs(x[3])<.9 ? (0.,0.,1.) : (1.,0.,0.),x));z=cross3(x,y)
        if !(a["cid"] in written_frames)
            card!(io,"CORD2R",(a["cid"],0,origin...,(origin.+z)...,(origin.+x)...));push!(written_frames,a["cid"])
        end
        if a["fitting"]=="idealized"
            card!(io,"RBE3",Any[a["box_rbe3_eid"],nothing,m.node_ids[a["box_ref"]],123456,1.,123,m.node_ids[a["box_nodes"]]...])
            card!(io,"RBE2",Any[a["surface_rbe2_eid"],m.node_ids[a["surface_ref"]],123456,m.node_ids[a["surface_nodes"]]...])
        end
        for link in get(a,"interpolation_links",Any[])
            # All interpolation GRIDs and parent shell GRIDs are in BASIC.
            # MPC avoids the rigid least-squares rotation fit of an RBE3.
            for component in 1:6
                n1,n2=link["nodes"];w1,w2=link["weights"]
                # MPC reserves the last field of the parent record and the
                # first/last fields of every continuation record.
                fields=Any[80_000_001,m.node_ids[link["ref"]],component,1.,m.node_ids[n1],component,-w1,nothing,
                    nothing,m.node_ids[n2],component,-w2,nothing,nothing,nothing,nothing]
                card!(io,"MPC",fields)
            end
        end
        for link in a["lateral_links"]
            card!(io,"RBE2",(link["eid"],m.node_ids[link["ref"]],link["components"],m.node_ids[link["node"]]))
        end
        if a["kind"]=="rigid"
            card!(io,"RBE2",(a["joint_eid"],m.node_ids[a["box_ref"]],123456,m.node_ids[a["surface_ref"]]))
        elseif a["fitting"]=="shell_lugs"
            # Both GRID displacement frames share x along the true hinge.
            # Join relative 12356 only: no aircraft DOF is grounded by an SPC.
            card!(io,"RBE2",(a["joint_eid"],m.node_ids[a["box_ref"]],12356,m.node_ids[a["surface_ref"]]))
        else
            kt,kr,kh=a["translation_stiffness"],a["tilt_stiffness"],a["hinge_stiffness"]
            card!(io,"PBUSH",(a["pid"],"K",kt,kt,kt,kh,kr,kr))
            card!(io,"CBUSH",(a["joint_eid"],a["pid"],m.node_ids[a["box_ref"]],m.node_ids[a["surface_ref"]],nothing,nothing,nothing,a["cid"]))
        end
        write_movable_actuator(io,m,a)
    end
    for r in get(movable_structure_data(m),"load_references",Any[])
        card!(io,"RBE3",Any[r["eid"],nothing,m.node_ids[r["ref"]],123456,1.,123,m.node_ids[r["nodes"]]...])
    end
end
