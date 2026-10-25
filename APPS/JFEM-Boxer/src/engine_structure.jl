# Engine inertia is kept separate from the wing's distributed structural mass.
# The engine has an explicitly editable elastic beam and a separate CG mass.
const ENGINE_DEFAULTS=Dict{String,Any}("name"=>"Engine 1","enabled"=>true,
    "x"=>0.,"y"=>1.,"z"=>-1.,"mass"=>1000.,"length"=>3.,
    "front_rib"=>2,"aft_rib"=>2,"aft_xc"=>.55,
    "E"=>70e9,"G"=>26e9,"A"=>.01,"I1"=>1e-4,"I2"=>1e-4,"J"=>2e-4)
const ENGINE_MODEL_NOTE="Two elastic CBAR halves lie along BASIC X, centered at the entered CG, with editable E, G, A, I1, I2 and J. Example stiffness values must be replaced with engine data. The beam material has zero density and NSM: a single CONM2 carries the complete mass at the CG, with uniform slender-line inertia Iy=Iz=mL^2/12 and Ix=0. Wing-patch RBE3 references and massless RBE2 mounting arms connect the two beam ends. This includes finite beam flexibility and wing coupling; pylon flexibility and distributed engine deformation inertia are not inferred from mass or length."

function normalize_engines(value)
    value isa AbstractVector&&length(value)<=100||throw(ArgumentError("engines.items must be a table of at most 100 engines"))
    result=Dict{String,Any}[];names=Set{String}()
    for raw in value
        raw isa AbstractDict&&all(k->k in keys(ENGINE_DEFAULTS),keys(raw))||throw(ArgumentError("Engine definition contains unknown fields"))
        row=merge(ENGINE_DEFAULTS,raw);name=row["name"]
        name isa AbstractString&&!isempty(strip(name))&&length(name)<=80||throw(ArgumentError("Each engine needs a name of 1 to 80 characters"))
        name=strip(name);name in names&&throw(ArgumentError("Engine name $name is repeated"));push!(names,name);row["name"]=name
        row["enabled"] isa Bool||throw(ArgumentError("$name: enabled must be on or off"))
        for key in ("x","y","z","mass","length","aft_xc","E","G","A","I1","I2","J")
            v=row[key];v isa Real&&!(v isa Bool)&&isfinite(v)||throw(ArgumentError("$name: $key must be finite"));row[key]=Float64(v)
        end
        for key in ("mass","length","E","G","A","I1","I2","J");row[key]>0||throw(ArgumentError("$name: $key must be positive"));end
        0<=row["aft_xc"]<=1||throw(ArgumentError("$name: aft attachment x/c must be between 0 and 1"))
        for key in ("front_rib","aft_rib");row[key]=material_integer(row[key],"$name $key");end
        push!(result,row)
    end
    result
end

function validate_engine_structure(p)
    rows=filter(r->r["enabled"],normalize_engines(get(p,"engines.items",Any[])))
    isempty(rows)&&return nothing
    _,ribs,_=span_stations(make_wing(p),p)
    for r in rows,key in ("front_rib","aft_rib")
        r[key]<=length(ribs)||throw(ArgumentError("$(r["name"]): $key R$(r[key]) does not exist; the wing has $(length(ribs)) physical ribs"))
    end
    nothing
end

engine_structure_data(m)=m.engine_structure
engine_records(m)=get(engine_structure_data(m),"engines",Any[])
engine_element_ids(m)=Int[eid for r in engine_records(m) for eid in vcat(r["rbe3_eids"],r["arm_eids"],r["beam_eids"],[r["mass_eid"]])]

function engine_free_node!(reg,point)
    n=add_free_node!(reg,point);delete!(reg.index,reg.keys[n])
    reg.keys[n]=(-6,-n,-6);reg.index[reg.keys[n]]=n
    n
end

"""Reject translation-only RBE3 patches that cannot recover all rigid motions."""
function validate_engine_patch(reg,nodes,label)
    length(nodes)>=3||throw(ArgumentError("$label needs at least three distinct wing nodes"))
    points=[Tuple(reg.xyz[3n-2:3n]) for n in nodes];origin=first(points)
    lengths=[norm3(p.-origin) for p in points];scale=maximum(lengths)
    scale>1e-12||throw(ArgumentError("$label collapses to one position"))
    direction=(points[argmax(lengths)].-origin)./scale
    maximum(norm3(cross3(direction,(p.-origin)./scale)) for p in points)>1e-8||
        throw(ArgumentError("$label is collinear and cannot transfer all moments; refine the local spar/rib mesh"))
    nothing
end

function engine_front_mount!(reg,g,row)
    ri=row["front_rib"];j=g.ribs[ri]
    # One vertical spar line alone cannot resolve all three rotations. Use the
    # actual adjacent spar cell(s), with the requested rib as the mount center.
    rows=max(0,j-1):min(length(g.etas)-1,j+1)
    nodes=unique(Int[node!(reg,g,0,jj,k) for jj in rows for k in 0:g.nh])
    point=(grid_point(g,0,j,0).+grid_point(g,0,j,g.nh))./2
    validate_engine_patch(reg,nodes,"$(row["name"]) front-spar attachment at R$ri")
    Dict{String,Any}("kind"=>"front","rib"=>ri,"eta"=>g.etas[j+1],
        "xc"=>(g.lower_xcs[1,j+1]+g.upper_xcs[1,j+1])/2,
        "position_m"=>collect(point),"nodes"=>nodes,"components"=>123,
        "patch_note"=>"Front-spar cells immediately adjoining the selected physical rib; translations only")
end

function engine_aft_mount!(reg,g,row)
    ri=row["aft_rib"];j=g.ribs[ri];xc=row["aft_xc"]
    xcs=[(g.lower_xcs[i+1,j+1]+g.upper_xcs[i+1,j+1])/2 for i in 0:ni(g)]
    xcs[1]-1e-12<=xc<=xcs[end]+1e-12||throw(ArgumentError(
        "$(row["name"]): aft attachment x/c=$xc lies outside the structural box at R$ri (front $(xcs[1]), rear $(xcs[end])). Choose a point between the spars; no attachment is silently moved."))
    # Collapsed run-out columns share real nodes. Keep distinct columns before
    # bracketing the attachment; the patch stays a nonzero rib-web rectangle.
    columns=Int[0]
    for i in 1:ni(g);xcs[i+1]-xcs[last(columns)+1]>1e-12&&push!(columns,i);end
    length(columns)>=2||throw(ArgumentError("$(row["name"]): aft attachment rib has no chordwise extent"))
    ii=clamp(searchsortedlast(xcs[columns.+1],xc),1,length(columns)-1);a,b=columns[ii],columns[ii+1]
    t=clamp((xc-xcs[a+1])/(xcs[b+1]-xcs[a+1]),0.,1.)
    mid(i)=(grid_point(g,i,j,0).+grid_point(g,i,j,g.nh))./2
    point=(1-t).*mid(a).+t.*mid(b)
    nodes=unique(Int[node!(reg,g,i,j,k) for i in (a,b) for k in 0:g.nh])
    validate_engine_patch(reg,nodes,"$(row["name"]) aft attachment at R$ri")
    Dict{String,Any}("kind"=>"aft","rib"=>ri,"eta"=>g.etas[j+1],"xc"=>xc,
        "position_m"=>collect(point),"nodes"=>nodes,"components"=>123,
        "patch_note"=>"Actual rib-web cell columns bracketing the requested x/c; translations only")
end

"""Wing patches -> mount references -> beam ends; the elastic beam CG stays free."""
function add_engine_structure!(reg,g,p,eid)
    data=Dict{String,Any}("engines"=>Any[],"note"=>ENGINE_MODEL_NOTE)
    used_materials=Set(material["id"] for material in material_definitions(p));next_mid=90_000_001
    for (index,row) in enumerate(normalize_engines(get(p,"engines.items",Any[])))
        row["enabled"]||continue
        front=engine_front_mount!(reg,g,row);aft=engine_aft_mount!(reg,g,row)
        norm3(Tuple(aft["position_m"]-front["position_m"]))>1e-10*max(row["length"],1.)||
            throw(ArgumentError("$(row["name"]): front and aft mounts coincide; choose distinct attachment locations"))
        for mount in (front,aft)
            mount["ref"]=engine_free_node!(reg,mount["position_m"]);mount["eid"]=eid;eid+=1
        end
        center=[row["x"],row["y"],row["z"]];cg=engine_free_node!(reg,center)
        a=engine_free_node!(reg,center+[-row["length"]/2,0.,0.]);b=engine_free_node!(reg,center+[row["length"]/2,0.,0.])
        arm_eids=[eid,eid+1];eid+=2
        beam_eids=[eid,eid+1];mass_eid=eid+2;eid+=3
        while next_mid in used_materials;next_mid+=1;end
        mid=next_mid;push!(used_materials,mid);next_mid+=1
        inertia=row["mass"]*row["length"]^2/12
        isfinite(inertia)||throw(ArgumentError("$(row["name"]): engine mass/length overflowed the inertia calculation"))
        push!(data["engines"],Dict{String,Any}("name"=>row["name"],"cg_node"=>cg,
            "mass_kg"=>row["mass"],"length_m"=>row["length"],"center_of_gravity_m"=>center,
            "axis"=>[1.,0.,0.],"inertia_kg_m2"=>[[0.,0.,0.],[0.,inertia,0.],[0.,0.,inertia]],
            "conm2_inertia_kg_m2"=>[0.,0.,inertia,0.,0.,inertia],"mass_eid"=>mass_eid,
            "rbe3_eids"=>[front["eid"],aft["eid"]],"arm_eids"=>arm_eids,
            "beam_eids"=>beam_eids,"beam_nodes"=>[a,cg,b],"mounts"=>[front,aft],
            "pid"=>39_000_000+index,"mid"=>mid,"E"=>row["E"],"G"=>row["G"],"A"=>row["A"],
            "I1"=>row["I1"],"I2"=>row["I2"],"J"=>row["J"],"orientation"=>[0.,1.,0.],
            "representation"=>"flexible_beam_lumped_cg_mass","note"=>ENGINE_MODEL_NOTE))
    end
    eid,data
end

function write_engine_structure(io,m)
    isempty(engine_records(m))&&return nothing
    banner!(io,"Engine elastic beams, CG masses and RBE3 attachment distribution")
    comment!(io,ENGINE_MODEL_NOTE)
    for r in engine_records(m)
        comment!(io,r["name"]*": mass "*string(r["mass_kg"])*" kg, length "*string(r["length_m"])*" m")
        for mount in r["mounts"]
            card!(io,"RBE3",Any[mount["eid"],nothing,m.node_ids[mount["ref"]],123456,1.,123,m.node_ids[mount["nodes"]]...])
        end
        for (eid,node,mount) in zip(r["arm_eids"],r["beam_nodes"][[1,3]],r["mounts"])
            card!(io,"RBE2",(eid,m.node_ids[mount["ref"]],123456,m.node_ids[node]))
        end
        card!(io,"MAT1",(r["mid"],r["E"],r["G"],nothing,0.))
        card!(io,"PBAR",(r["pid"],r["mid"],r["A"],r["I1"],r["I2"],r["J"],0.))
        for (eid,a,b) in zip(r["beam_eids"],r["beam_nodes"][1:2],r["beam_nodes"][2:3])
            card!(io,"CBAR",(eid,r["pid"],m.node_ids[a],m.node_ids[b],0.,1.,0.))
        end
        card!(io,"CONM2",Any[r["mass_eid"],m.node_ids[r["cg_node"]],0,r["mass_kg"],0.,0.,0.,nothing,r["conm2_inertia_kg_m2"]...])
    end
    nothing
end

function engine_connection_payload(m)
    collections=[Dict{String,Any}("name"=>name,"card"=>card,"point_mass"=>card=="CONM2","elements"=>Any[])
        for (name,card) in (("ENGINE_ATTACHMENTS","RBE3"),("ENGINE_BEAMS","CBAR"),("ENGINE_MASSES","CONM2"),("ENGINE_MOUNT_ARMS","RBE2"))]
    add(i,eid,nodes,props)=push!(collections[i]["elements"],Dict("eid"=>eid,"type"=>collections[i]["card"],"nodes"=>nodes.-1,"properties"=>props))
    for r in engine_records(m)
        properties=Dict{String,Any}("Engine"=>r["name"],"Mass kg"=>r["mass_kg"],"Length m"=>r["length_m"],"Role"=>"Engine attachment")
        beam_properties=merge(properties,Dict("Role"=>"Elastic engine beam with concentrated CG mass",
            "PID"=>r["pid"],"MID"=>r["mid"],"E Pa"=>r["E"],"G Pa"=>r["G"],"Area m2"=>r["A"],"I1 m4"=>r["I1"],"I2 m4"=>r["I2"],"J m4"=>r["J"]))
        for mount in r["mounts"]
            add(1,mount["eid"],vcat(mount["ref"],mount["nodes"]),merge(properties,Dict("Attachment"=>mount["kind"],"Rib"=>mount["rib"],"x/c"=>mount["xc"],"Interpolation"=>mount["patch_note"])))
        end
        for (eid,node,mount) in zip(r["arm_eids"],r["beam_nodes"][[1,3]],r["mounts"])
            add(4,eid,[mount["ref"],node],merge(properties,Dict("Role"=>"Massless rigid mounting arm")))
        end
        for (eid,a,b) in zip(r["beam_eids"],r["beam_nodes"][1:2],r["beam_nodes"][2:3])
            add(2,eid,[a,b],beam_properties)
        end
        add(3,r["mass_eid"],[r["cg_node"]],merge(properties,Dict("Role"=>"Engine concentrated CG mass","Inertia kg m2"=>r["inertia_kg_m2"])))
    end
    filter(c->!isempty(c["elements"]),collections)
end

function engine_structure_payload(m)
    data=deepcopy(engine_structure_data(m));data["node_indices_zero_based"]=true
    for r in get(data,"engines",Any[])
        r["cg_grid"]=m.node_ids[r["cg_node"]];r["cg_node"]-=1;r["beam_nodes"].-=1
        for mount in r["mounts"];mount["ref"]-=1;mount["nodes"].-=1;end
    end
    data
end
