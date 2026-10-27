# Engine inertia is kept separate from the wing's distributed structural mass.
# The engine has an explicitly editable elastic beam and a separate CG mass.
const ENGINE_DEFAULTS=Dict{String,Any}("name"=>"Engine 1","enabled"=>true,
    "x"=>0.,"y"=>1.,"z"=>-1.,"mass"=>1000.,"length"=>3.,
    "front_rib"=>2,"aft_rib"=>2,"aft_xc"=>.55,
    "E"=>70e9,"G"=>26e9,"A"=>.01,"I1"=>1e-4,"I2"=>1e-4,"J"=>2e-4)
const ENGINE_MODEL_NOTE="Two elastic CBAR halves lie along BASIC X, centered at the entered CG, with editable E, G, A, I1, I2 and J. Example stiffness values must be replaced with engine data. The beam material has zero density and NSM: a single CONM2 carries the complete mass at the CG, with uniform slender-line inertia Iy=Iz=mL^2/12 and Ix=0. The CG is the front RBE3 reference, using the upper front-spar cap nodes at the physical ribs immediately inboard and outboard of the selected front rib. The aft beam end is the aft RBE3 reference, using the equivalent lower cap nodes at the adjacent physical ribs about its selected rib plus the nearest existing lower-rib node to the requested x/c. A collinear or nearly collinear patch also uses one cap-direction rotation to preserve every rigid motion and transfer moments. No intermediate mount nodes or RBE2 arms are added. The forward half remains an elastic overhang; pylon flexibility and distributed engine deformation inertia are not inferred from mass or length."

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

"""Case thrusts use engine names, never row positions, and retain signed newtons."""
function normalize_engine_thrust(value)
    value isa AbstractVector&&length(value)<=100||throw(ArgumentError("loads.engine_thrust must be a table of at most 100 engine thrusts"))
    result=Dict{String,Any}[];names=Set{String}()
    for raw in value
        raw isa AbstractDict&&all(k->k in ("engine","thrust_n"),keys(raw))||
            throw(ArgumentError("Each engine thrust must contain only engine and thrust_n"))
        name=get(raw,"engine",nothing);force=get(raw,"thrust_n",0.)
        name isa AbstractString&&!isempty(strip(name))&&length(name)<=80||
            throw(ArgumentError("Each engine thrust needs its engine name"))
        name=strip(name);name in names&&throw(ArgumentError("Thrust for engine $name is repeated"));push!(names,name)
        force isa Real&&!(force isa Bool)&&isfinite(force)||throw(ArgumentError("$name: thrust must be a finite signed value in N"))
        push!(result,Dict{String,Any}("engine"=>name,"thrust_n"=>Float64(force)))
    end
    sort!(result;by=row->row["engine"])
end

"""Retain disabled-engine inputs, but refuse to silently drop renamed/deleted loads."""
function engine_thrust_inputs(p)
    defined=Dict(row["name"]=>row["enabled"] for row in normalize_engines(get(p,"engines.items",Any[])))
    thrusts=normalize_engine_thrust(get(p,"loads.engine_thrust",Any[]))
    for row in thrusts
        haskey(defined,row["engine"])||iszero(row["thrust_n"])||throw(ArgumentError(
            "Engine thrust refers to missing engine $(repr(row["engine"])). Review this load case's engine thrust after renaming or deleting an engine; select the intended engine or clear its thrust."))
        isfinite(row["thrust_n"]*Float64(get(p,"loads.load_factor",1.)))||throw(ArgumentError(
            "$(row["engine"]): thrust times the load multiplier must be finite"))
    end
    Dict(row["engine"]=>row["thrust_n"] for row in thrusts if get(defined,row["engine"],false))
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

"""Choose only the supplemental rotation needed by a collinear RBE3 patch.

Translations on a straight cap line cannot identify rotation about that line.
The generated cap GRID displacement frames are BASIC (only separate movable
hinge GRIDs receive a CD), so the largest BASIC component of the line direction
completes its rank without adding other wing nodes or all three rotations.
"""
function engine_patch_rotation(reg,nodes,label)
    length(nodes)>=2||throw(ArgumentError("$label needs at least two distinct wing nodes"))
    points=[reg.xyz[3n-2:3n] for n in nodes];center=sum(points)/length(points)
    offsets=[p-center for p in points];scale=maximum(norm3(v) for v in offsets)
    scale>1e-12||throw(ArgumentError("$label collapses to one position"))
    covariance=zeros(3,3)
    for v in offsets
        q=v/scale
        covariance.+=q*q'
    end
    axes=LinearAlgebra.eigen(LinearAlgebra.Symmetric(covariance))
    # Dimensionless spread avoids a units-dependent collinearity test. Very
    # slight curvature is not used as an enormous artificial moment lever arm.
    spread=max(0.,axes.values[1]+axes.values[2])/axes.values[3]
    rotation=spread<=1e-6 ? argmax(abs.(axes.vectors[:,3]))+3 : 0
    rotation,spread
end

"""Cap intersections at the immediately adjacent physical ribs, never FE rows."""
function engine_cap_nodes(reg,g,row,kind,upper)
    ri=row[kind*"_rib"];side=upper ? "upper" : "lower"
    1<ri<length(g.ribs)||throw(ArgumentError(
        "$(row["name"]): $kind attachment at R$ri needs one physical rib inboard and one outboard. Choose an interior rib: intermediate mesh nodes and the nominal-rib cap node are not substituted for adjacent ribs."))
    rows=Int[g.ribs[ri-1],g.ribs[ri+1]];k=upper ? g.nh : 0
    nodes=Int[get(reg.index,(0,jj,k),0) for jj in rows]
    all(>(0),nodes)&&length(unique(nodes))==2||throw(ArgumentError(
        "$(row["name"]): $kind attachment at R$ri cannot find distinct $side front-spar cap nodes at physical ribs R$(ri-1) and R$(ri+1). Check the spar mesh before defining this attachment."))
    nodes,rows
end

function engine_mount_interpolation!(mount,reg,row)
    rotation,spread=engine_patch_rotation(reg,mount["nodes"],"$(row["name"]) $(mount["kind"]) attachment at R$(mount["rib"])")
    groups=Any[Dict{String,Any}("weight"=>1.,"components"=>123,"nodes"=>copy(mount["nodes"]))]
    # Only cap nodes supply the missing rotation, also when the aft rib point
    # lies on that cap. The added lower-rib point keeps its translation role.
    rotation>0&&push!(groups,Dict{String,Any}("weight"=>1.,"components"=>rotation,"nodes"=>copy(mount["cap_nodes"])))
    mount["components"]=123;mount["rotation_component"]=rotation
    mount["transverse_spread_ratio"]=spread;mount["weight_groups"]=groups
    mount["patch_note"]*=rotation>0 ? "; translations plus BASIC rotation $(rotation-3) on the two adjacent-rib cap nodes to resolve a collinear/near-collinear cap line" : "; translations only"
    mount
end

function engine_front_mount!(reg,g,row)
    ri=row["front_rib"];j=g.ribs[ri];nodes,rows=engine_cap_nodes(reg,g,row,"front",true)
    mount=Dict{String,Any}("kind"=>"front","rib"=>ri,"eta"=>g.etas[j+1],
        "xc"=>g.upper_xcs[1,j+1],"actual_xc"=>g.upper_xcs[1,j+1],
        "position_m"=>collect(grid_point(g,0,j,g.nh)),"nodes"=>nodes,"cap_nodes"=>copy(nodes),
        "cap_span_indices"=>rows,"cap_ribs"=>[ri-1,ri+1],"inboard_cap_nodes"=>nodes[1:1],"outboard_cap_nodes"=>nodes[2:2],
        "patch_note"=>"Upper front-spar cap nodes at the immediately adjacent physical ribs R$(ri-1) and R$(ri+1); intermediate mesh nodes and the nominal-rib node are excluded")
    engine_mount_interpolation!(mount,reg,row)
end

function engine_aft_mount!(reg,g,row)
    ri=row["aft_rib"];j=g.ribs[ri];xc=row["aft_xc"];cap_nodes,rows=engine_cap_nodes(reg,g,row,"aft",false)
    # Use an existing lower-skin node on the physical rib. Duplicate logical
    # stringer columns at a runout map to the same cap node; deduplicate them.
    candidates=Tuple{Int,Int,Float64}[];seen=Set{Int}()
    for i in 0:ni(g)
        side=g.collapsed[i+1,j+1];column=side<0 ? 0 : side>0 ? ni(g) : i
        node=get(reg.index,(column,j,0),0)
        node>0&&!(node in seen)||continue
        push!(seen,node);push!(candidates,(node,column,g.lower_xcs[column+1,j+1]))
    end
    isempty(candidates)&&throw(ArgumentError("$(row["name"]): aft attachment R$ri has no existing lower-surface rib nodes"))
    chosen=candidates[argmin([abs(c[3]-xc) for c in candidates])]
    node,column,actual_xc=chosen;nodes=unique(vcat(cap_nodes,node))
    mount=Dict{String,Any}("kind"=>"aft","rib"=>ri,"eta"=>g.etas[j+1],"xc"=>xc,"actual_xc"=>actual_xc,
        "position_m"=>reg.xyz[3node-2:3node],"nodes"=>nodes,"cap_nodes"=>copy(cap_nodes),
        "cap_span_indices"=>rows,"cap_ribs"=>[ri-1,ri+1],"inboard_cap_nodes"=>cap_nodes[1:1],"outboard_cap_nodes"=>cap_nodes[2:2],
        "rib_node"=>node,"rib_column"=>column,
        "patch_note"=>"Lower front-spar cap nodes at the immediately adjacent physical ribs R$(ri-1) and R$(ri+1), plus the nominal rib's existing lower-surface node nearest the requested x/c; intermediate cap mesh nodes are excluded")
    engine_mount_interpolation!(mount,reg,row)
end

"""Wing-cap interpolation connects directly to the engine CG and aft end."""
function add_engine_structure!(reg,g,p,eid)
    data=Dict{String,Any}("engines"=>Any[],"note"=>ENGINE_MODEL_NOTE)
    used_materials=Set(material["id"] for material in material_definitions(p));next_mid=90_000_001
    for (index,row) in enumerate(normalize_engines(get(p,"engines.items",Any[])))
        row["enabled"]||continue
        front=engine_front_mount!(reg,g,row);aft=engine_aft_mount!(reg,g,row)
        center=[row["x"],row["y"],row["z"]];cg=engine_free_node!(reg,center)
        a=engine_free_node!(reg,center+[-row["length"]/2,0.,0.]);b=engine_free_node!(reg,center+[row["length"]/2,0.,0.])
        for (mount,reference) in ((front,cg),(aft,b))
            mount["ref"]=reference;mount["reference_position_m"]=reg.xyz[3reference-2:3reference]
            mount["eid"]=eid;eid+=1
        end
        arm_eids=Int[]
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
            fields=Any[mount["eid"],nothing,m.node_ids[mount["ref"]],123456]
            for group in mount["weight_groups"]
                append!(fields,Any[group["weight"],group["components"],m.node_ids[group["nodes"]]...])
            end
            card!(io,"RBE3",fields)
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
        for (name,card) in (("ENGINE_ATTACHMENTS","RBE3"),("ENGINE_BEAMS","CBAR"),("ENGINE_MASSES","CONM2"))]
    add(i,eid,nodes,props)=push!(collections[i]["elements"],Dict("eid"=>eid,"type"=>collections[i]["card"],"nodes"=>nodes.-1,"properties"=>props))
    for r in engine_records(m)
        properties=Dict{String,Any}("Engine"=>r["name"],"Mass kg"=>r["mass_kg"],"Length m"=>r["length_m"],"Role"=>"Engine attachment")
        beam_properties=merge(properties,Dict("Role"=>"Elastic engine beam with concentrated CG mass",
            "PID"=>r["pid"],"MID"=>r["mid"],"E Pa"=>r["E"],"G Pa"=>r["G"],"Area m2"=>r["A"],"I1 m4"=>r["I1"],"I2 m4"=>r["I2"],"J m4"=>r["J"]))
        for mount in r["mounts"]
            add(1,mount["eid"],vcat(mount["ref"],mount["nodes"]),merge(properties,Dict("Attachment"=>mount["kind"],"Rib"=>mount["rib"],
                "Requested x/c"=>mount["xc"],"Actual x/c"=>mount["actual_xc"],"Reference"=>(mount["kind"]=="front" ? "Engine CG" : "Aft beam end"),"Adjacent cap ribs"=>mount["cap_ribs"],
                "Independent translation components"=>123,
                "reference_grid"=>m.node_ids[mount["ref"]],"reference_components"=>123456,
                "weight_groups"=>[Dict("wt"=>group["weight"],"comps"=>group["components"],"grids"=>m.node_ids[group["nodes"]]) for group in mount["weight_groups"]],
                "Supplemental rotation component"=>mount["rotation_component"],"Interpolation"=>mount["patch_note"])))
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
        for mount in r["mounts"]
            mount["reference_grid"]=m.node_ids[mount["ref"]];mount["ref"]-=1
            for key in ("nodes","cap_nodes","inboard_cap_nodes","outboard_cap_nodes");mount[key].-=1;end
            haskey(mount,"rib_node")&&(mount["rib_node"]-=1)
            for group in mount["weight_groups"];group["nodes"].-=1;end
        end
    end
    data
end
