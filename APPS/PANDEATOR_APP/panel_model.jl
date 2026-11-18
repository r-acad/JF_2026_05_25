"""Canonical, conforming stiffened-panel geometry and Reference-deck model.

Units are N, mm, MPa and tonne. The skin is a cylindrical extrusion along X;
R=0 is a flat panel. Skin shell normals point inward (+Z at the crown). An
attached flange replaces its underlying skin face with one bonded section.
"""
module PandeatorModel

using LinearAlgebra
using Printf

export PanelModel, normalize_panel_params, build_panel_model, panel_mesh_payload,
       panel_bdf, panel_property_directions, panel_load_direction, panel_variables,
       parse_laminate

struct PanelModel
    params::Dict{String,Any}
    nodes::Vector{Dict{String,Any}}
    elements::Vector{Dict{String,Any}}
    properties::Dict{Int,Dict{String,Any}}
    materials::Dict{Int,Dict{String,Any}}
    frames::Dict{Int,Matrix{Float64}}
    edges::Dict{String,Any}
    regions::Dict{String,Any}
    forces::Dict{Int,Vector{Float64}}
    constraints::Vector{Dict{String,Any}}
    axial_tributaries::Vector{Dict{String,Any}}
    report::Dict{String,Any}
    warnings::Vector{String}
end

const DEFAULTS=Dict{String,Any}(
    "R"=>1000.,"width"=>600.,"length"=>800.,"bladeH"=>40.,"footW"=>50.,
    "nx"=>40,"ny"=>12,"nz"=>6,"nf"=>4,"nModes"=>10,
    "Nx"=>200.,"Ny"=>0.,"Nxy"=>0.,"material_mode"=>"iso",
    "E"=>71000.,"nu"=>.33,"rho"=>2.7e-9,"tSkin"=>2.,"tWeb"=>2.,"tFoot"=>2.,
    "E1"=>140000.,"E2"=>9000.,"nu12"=>.3,"G12"=>5000.,"tply"=>.18,
    "lamSkin"=>"(45/-45/0/90)S","lamWeb"=>"(45/-45/0/90)S","lamFoot"=>"(45/-45/0/90)S",
    "scaleSkin"=>1.,"scaleWeb"=>1.,"scaleFoot"=>1.,"shell_offsets"=>false,
    "boundary_mode"=>"simply_supported","skinMaterial"=>100,"webMaterial"=>100,"footMaterial"=>100,
    "buckling_policy_factor"=>1.)

function _number(value,label)
    value isa Real&&!(value isa Bool)&&isfinite(value)||throw(ArgumentError("$label must be a finite number"))
    result=Float64(value);isfinite(result)||throw(ArgumentError("$label exceeds the supported numerical range"));result
end

"""Parse explicit, repeated and symmetric laminate notation without evaluation."""
function parse_laminate(value)
    s=filter(c->!isspace(c),replace(String(value),'−'=>'-'))
    isempty(s)&&throw(ArgumentError("Laminate notation is empty"))
    chars=collect(s);i=Ref(1);n=length(chars)
    function sequence(nested=false)
        out=Float64[]
        while i[]<=n
            c=chars[i[]]
            if c in ('/',',');i[]+=1;continue;end
            if c==')'
                nested||throw(ArgumentError("Unexpected ')' in laminate notation"))
                i[]+=1;return out
            end
            count=1
            if c!='('
                rest=join(chars[i[]:end]);m=match(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?",rest)
                m===nothing&&throw(ArgumentError("Invalid laminate token near '$rest'"))
                i[]+=length(m.match)
                if i[]<=n&&chars[i[]]=='('
                    occursin(r"^\d+$",m.match)||throw(ArgumentError("A ply-group repeat must be a positive integer"))
                    count=parse(Int,m.match);1<=count<=512||throw(ArgumentError("Ply-group repeat must be between 1 and 512"))
                else
                    angle=parse(Float64,m.match);isfinite(angle)||throw(ArgumentError("Ply angles must be finite"))
                    push!(out,angle);length(out)<=512||throw(ArgumentError("A laminate is limited to 512 explicit plies"));continue
                end
            end
            i[]+=1;group=sequence(true)
            isempty(group)&&throw(ArgumentError("An empty ply group is invalid"))
            group=repeat(group,count)
            if i[]<=n&&chars[i[]] in ('S','s','$')
                suffix=chars[i[]];i[]+=1
                group=vcat(group,reverse(suffix=='$' ? group[1:end-1] : group))
            end
            append!(out,group);length(out)<=512||throw(ArgumentError("A laminate is limited to 512 explicit plies"))
        end
        nested&&throw(ArgumentError("Unclosed '(' in laminate notation"))
        out
    end
    angles=sequence();isempty(angles)&&throw(ArgumentError("Laminate notation contains no plies"));angles
end

function normalize_panel_params(input::AbstractDict)
    p=deepcopy(DEFAULTS)
    for (key,value) in input;p[string(key)]=value;end
    supplied=Set(string(key) for key in keys(input))
    mode=lowercase(String("material_mode" in supplied ? p["material_mode"] : get(p,"mat",p["material_mode"])))
    mode in ("comp","composite","mat8")&&(mode="composite")
    mode in ("iso","isotropic","mat1")&&(mode="iso")
    mode in ("iso","composite")||throw(ArgumentError("Material mode must be iso or composite"));p["material_mode"]=mode
    for key in ("R","width","length","bladeH","footW","Nx","Ny","Nxy","E","nu","rho","tSkin","tWeb","tFoot","E1","E2","nu12","G12","tply","scaleSkin","scaleWeb","scaleFoot","buckling_policy_factor")
        p[key]=_number(p[key],key)
    end
    p["R"]>=0||throw(ArgumentError("Radius R must be positive, or zero for a flat panel"))
    p["width"]>0&&p["length"]>0||throw(ArgumentError("Panel width and length must be positive"))
    0<=p["footW"]<=p["width"]||throw(ArgumentError("Attached flange width must lie between zero and panel width"))
    p["bladeH"]>=0||throw(ArgumentError("Blade height must be nonnegative; zero creates an unstiffened panel"))
    if p["R"]>0
        p["width"]/(2p["R"])<pi/2||throw(ArgumentError("Panel arc must span less than half a cylinder; increase R or reduce arc width"))
        p["bladeH"]<p["R"]||throw(ArgumentError("The inward blade reaches the cylinder axis; reduce blade height or increase R"))
    end
    p["rho"]>=0||throw(ArgumentError("Density must be nonnegative"))
    p["buckling_policy_factor"]>0||throw(ArgumentError("Buckling policy factor must be positive"))
    for key in ("nx","ny","nz","nf","nModes","skinMaterial","webMaterial","footMaterial")
        value=_number(p[key],key);isinteger(value)&&value>=1||throw(ArgumentError("$key must be a positive integer"));p[key]=Int(value)
    end
    p["nx"]<=1000&&p["ny"]<=500&&p["nz"]<=200&&p["nf"]<=500||throw(ArgumentError("Mesh counts exceed the supported panel-generator limits"))
    p["nModes"]<=100||throw(ArgumentError("Requested buckling modes must not exceed 100"))
    p["shell_offsets"] isa Bool||throw(ArgumentError("shell_offsets must be true or false"))
    p["boundary_mode"]=lowercase(String(p["boundary_mode"]))
    p["boundary_mode"] in ("simply_supported","clamped")||throw(ArgumentError("Boundary mode must be simply_supported or clamped"))
    for suffix in ("Skin","Web","Foot")
        p["scale"*suffix]>0||throw(ArgumentError("Laminate thickness scales must be positive"))
        p["lam"*suffix]=String(p["lam"*suffix])
    end
    if mode=="iso"
        p["E"]>0&&-1<p["nu"]<.5||throw(ArgumentError("Isotropic material needs E > 0 and -1 < nu < 0.5"))
        p["tSkin"]>0||throw(ArgumentError("Skin thickness must be positive"))
        p["bladeH"]==0||p["tWeb"]>0||throw(ArgumentError("Web thickness must be positive"))
        p["footW"]==0||p["tFoot"]>0||throw(ArgumentError("Additional flange thickness must be positive, or set flange width to zero"))
    else
        p["E1"]>0&&p["E2"]>0&&p["G12"]>0&&1-p["nu12"]^2*p["E2"]/p["E1"]>0||throw(ArgumentError("Orthotropic material requires positive stable elastic constants"))
        p["tply"]>0||throw(ArgumentError("Ply thickness must be positive"))
        parse_laminate(p["lamSkin"])
        p["bladeH"]==0||parse_laminate(p["lamWeb"])
        p["footW"]==0||parse_laminate(p["lamFoot"])
    end
    p
end

function _materials(p)
    default=p["material_mode"]=="iso" ? Dict{String,Any}("id"=>100,"type"=>"MAT1","E"=>p["E"],"nu"=>p["nu"],"rho"=>p["rho"]) :
        Dict{String,Any}("id"=>100,"type"=>"MAT8","E1"=>p["E1"],"E2"=>p["E2"],"nu12"=>p["nu12"],"G12"=>p["G12"],"G13"=>p["G12"],"G23"=>p["G12"],"rho"=>p["rho"])
    out=Dict(100=>default)
    for raw in get(p,"materials",Any[])
        material=Dict{String,Any}(string(k)=>v for (k,v) in pairs(raw));id=Int(get(material,"id",0));id>0||throw(ArgumentError("Material IDs must be positive"))
        kind=uppercase(String(get(material,"type","MAT1")));kind in ("MAT1","MAT8")||throw(ArgumentError("Panel materials must be MAT1 or MAT8"));material["type"]=kind
        fields=kind=="MAT1" ? ("E","nu","rho") : ("E1","E2","nu12","G12","rho")
        for key in fields;material[key]=_number(get(material,key,key=="rho" ? 0. : nothing),"material $id $key");end
        if kind=="MAT1"
            material["E"]>0&&-1<material["nu"]<.5||throw(ArgumentError("Material $id has invalid isotropic constants"))
        else
            material["E1"]>0&&material["E2"]>0&&material["G12"]>0&&1-material["nu12"]^2*material["E2"]/material["E1"]>0||throw(ArgumentError("Material $id has invalid orthotropic constants"))
            material["G13"]=_number(get(material,"G13",material["G12"]),"G13");material["G23"]=_number(get(material,"G23",material["G12"]),"G23")
            material["G13"]>0&&material["G23"]>0||throw(ArgumentError("Material $id requires positive transverse shear moduli G13 and G23"))
        end
        material["rho"]>=0||throw(ArgumentError("Material density must be nonnegative"));out[id]=material
    end
    for key in ("skinMaterial","webMaterial","footMaterial");haskey(out,p[key])||throw(ArgumentError("$key selects missing material $(p[key])"));end
    active=String["skinMaterial"]
    p["bladeH"]>0&&push!(active,"webMaterial");p["footW"]>0&&push!(active,"footMaterial")
    p["material_mode"]=="iso"&&any(key->out[p[key]]["type"]=="MAT8",active)&&
        throw(ArgumentError("Select composite mode to use an orthotropic MAT8 panel material"))
    out
end

function _q11(material,angle)
    material["type"]=="MAT1"&&return material["E"]/(1-material["nu"]^2)
    den=1-material["nu12"]^2*material["E2"]/material["E1"]
    q11=material["E1"]/den;q22=material["E2"]/den;q12=material["nu12"]*material["E2"]/den;q66=material["G12"]
    c=cosd(angle);s=sind(angle)
    q11*c^4+2(q12+2q66)*s^2*c^2+q22*s^4
end

function _component_layers(p,part,materials)
    suffix=part=="skin" ? "Skin" : part=="web" ? "Web" : "Foot"
    mid=p[part=="skin" ? "skinMaterial" : part=="web" ? "webMaterial" : "footMaterial"]
    material=materials[mid]
    if p["material_mode"]=="iso"&&material["type"]=="MAT1"
        return [Dict{String,Any}("material_id"=>mid,"thickness"=>p["t"*suffix],"angle"=>0.,"component"=>part,"role"=>part)]
    end
    [Dict{String,Any}("material_id"=>mid,"thickness"=>p["tply"]*p["scale"*suffix],"angle"=>angle,"component"=>part,"role"=>part) for angle in parse_laminate(p["lam"*suffix])]
end

function _properties(p,materials)
    skin=_component_layers(p,"skin",materials)
    web=p["bladeH"]>0 ? _component_layers(p,"web",materials) : Dict{String,Any}[]
    foot=p["footW"]>0 ? _component_layers(p,"foot",materials) : Dict{String,Any}[]
    out=Dict{Int,Dict{String,Any}}()
    for (pid,component,layers) in ((1,"skin",skin),(2,"web",web),(3,"combined",vcat(deepcopy(skin),foot)))
        (pid==2&&isempty(web)||pid==3&&isempty(foot))&&continue
        thickness=sum(layer["thickness"] for layer in layers)
        centered=pid!=3||!p["shell_offsets"]
        z0=centered ? -thickness/2 : -sum(layer["thickness"] for layer in skin)/2
        same_iso=all(layer->materials[layer["material_id"]]["type"]=="MAT1"&&layer["material_id"]==first(layers)["material_id"],layers)
        kind=same_iso&&centered ? "PSHELL" : "PCOMP"
        out[pid]=Dict{String,Any}("pid"=>pid,"component"=>component,"type"=>kind,"layers"=>layers,"plies"=>layers,
            "thickness"=>thickness,"z0"=>z0,"zoffs"=>0.,"reference_offset"=>z0+thickness/2,
            "A11"=>sum(_q11(materials[layer["material_id"]],layer["angle"])*layer["thickness"] for layer in layers),
            "areal_mass"=>sum(materials[layer["material_id"]]["rho"]*layer["thickness"] for layer in layers),
            "combined_flange"=>pid==3,"underlying_skin_pid"=>pid==3 ? 1 : nothing,
            "material_id"=>first(layers)["material_id"],"normal"=>pid==2 ? [0.,-1.,0.] : [0.,0.,1.])
        all(isfinite(out[pid][key]) for key in ("thickness","z0","A11","areal_mass"))&&out[pid]["A11"]>0||
            throw(ArgumentError("Section $pid overflows its physical thickness, stiffness or mass law"))
    end
    out
end

function _surface(p,s)
    iszero(p["R"])&&return [0.,s,0.]
    theta=s/p["R"];half=sin(theta/2);[0.,p["R"]*sin(theta),(2half)*(p["R"]*half)]
end

function _rigid_row(node,frame,dof,origin,scale)
    axis=frame[:,mod1(dof,3)]
    dof<=3 ? vcat(axis,cross((Float64[node["x"],node["y"],node["z"]].-origin)./scale,axis)) : vcat(zeros(3),axis)
end

function _constraints(p,nodes,frames,edges)
    sets=Dict{Int,Set{Int}}();sources=Dict{Int,Set{String}}()
    function add(ids,dofs,kind)
        for id in unique(ids);union!(get!(sets,id,Set{Int}()),dofs);push!(get!(sources,id,Set{String}()),kind);end
    end
    perimeter=unique(vcat(edges["edgeX0"],edges["edgeX1"],edges["edgeY0"],edges["edgeY1"]))
    add(perimeter,[1],"skin_normal")
    add(vcat(edges["webX0"],edges["webX1"]),[2],"web_fork")
    if p["boundary_mode"]=="clamped"
        add(perimeter,[5,6],"skin_clamped_rotation")
        add(vcat(edges["webX0"],edges["webX1"]),[4,6],"web_clamped_rotation")
    end
    origin=[sum(node[key] for node in nodes)/length(nodes) for key in ("x","y","z")]
    scale=max(p["length"],p["width"],p["bladeH"],1.)
    rows=[_rigid_row(nodes[id],frames[nodes[id]["cd"]],dof,origin,scale) for (id,dofs) in sets for dof in dofs]
    matrix=reduce(vcat,(reshape(row,1,6) for row in rows))
    rankof(A)=rank(A;rtol=1e-9)
    physical_rank=rankof(matrix);anchors=Any[]
    for id in unique([edges["c00"],edges["cL0"],edges["c01"],edges["cL1"]]),dof in (3,2)
        dof in get(sets,id,Set{Int}())&&continue
        trial=vcat(matrix,reshape(_rigid_row(nodes[id],frames[nodes[id]["cd"]],dof,origin,scale),1,6))
        if rankof(trial)>rankof(matrix)
            add([id],[dof],"rigid_motion_anchor");push!(anchors,Dict("nid"=>id,"dof"=>dof));matrix=trial
        end
        rankof(matrix)==6&&break
    end
    rankof(matrix)==6||throw(ArgumentError("Selected supports cannot eliminate all six rigid-body motions"))
    result=[Dict{String,Any}("nid"=>id,"components"=>sort!(collect(dofs)),"sources"=>sort!(collect(sources[id]))) for (id,dofs) in sort!(collect(sets);by=first)]
    result,Dict{String,Any}("physical_rigid_rank"=>physical_rank,"final_rigid_rank"=>6,"anchors"=>anchors,
        "description"=>p["boundary_mode"]=="clamped" ? "Clamped skin perimeter and fork-supported/clamped web ends; rank-minimal membrane anchors" : "Simply supported skin perimeter and fork-supported stringer ends; rotations free; rank-minimal membrane anchors",
        "component_basis"=>"CD1 outward normal, CD2 tangent, CD3 axial X; rotations use the same right-handed frame",
        "membrane_note"=>"Skin tangential/axial displacement is not restrained edge-wide. Only rank-required point anchors suppress rigid motion.")
end

function _loads(p,nodes,skin,web,stations,strip_pids,properties)
    force=Dict{Int,Vector{Float64}}();tributaries=Dict{String,Any}[]
    add(id,f)=(get!(force,id,zeros(3)).+=f)
    for j in 1:length(stations)-1
        a=_surface(p,stations[j]);b=_surface(p,stations[j+1]);span=norm(b-a)
        for endpoint in (j,j+1)
            push!(tributaries,Dict{String,Any}("nid0"=>skin[1,endpoint],"nidL"=>skin[end,endpoint],"pid"=>strip_pids[j],"length_weight"=>span/2))
        end
        # Consistent polygon-edge traction: integral t ds = endpoint delta.
        for endpoint in (j,j+1)
            add(skin[1,endpoint],-.5p["Nxy"].*(b-a));add(skin[end,endpoint],.5p["Nxy"].*(b-a))
        end
    end
    if size(web,2)>1
        for k in 1:size(web,2)-1,endpoint in (k,k+1)
            push!(tributaries,Dict{String,Any}("nid0"=>web[1,endpoint],"nidL"=>web[end,endpoint],"pid"=>2,"length_weight"=>p["bladeH"]/p["nz"]/2))
        end
    end
    total=sum(properties[row["pid"]]["A11"]*row["length_weight"] for row in tributaries)
    isfinite(total)&&total>0||throw(ArgumentError("Panel axial section stiffness must be finite and positive"))
    axial=p["Nx"]*p["width"]
    isfinite(axial)||throw(ArgumentError("Axial load resultant exceeds the supported numerical range"))
    for row in tributaries
        value=axial*(properties[row["pid"]]["A11"]*row["length_weight"]/total)
        add(row["nid0"],[value,0.,0.]);add(row["nidL"],[-value,0.,0.])
    end
    for i in 1:p["nx"],endpoint in (i,i+1)
        dx=p["length"]/p["nx"]/2
        add(skin[endpoint,1],[-p["Nxy"]*dx,p["Ny"]*dx,0.])
        add(skin[endpoint,end],[p["Nxy"]*dx,-p["Ny"]*dx,0.])
    end
    all(f->all(isfinite,f),values(force))||throw(ArgumentError("Applied panel loads exceed the supported numerical range"))
    filter!(pair->norm(last(pair))>0,force)
    resultant=zeros(3);moment=zeros(3)
    for (id,f) in force;resultant.+=f;moment.+=cross([nodes[id]["x"],nodes[id]["y"],nodes[id]["z"]],f);end
    all(isfinite,resultant)&&all(isfinite,moment)||throw(ArgumentError("Applied load resultants overflow; reduce the geometry/load scale"))
    force,tributaries,Dict{String,Any}("total_axial_resultant_N"=>axial,"axial_section_A11_N"=>total,
        "net_force_N"=>resultant,"net_moment_Nmm"=>moment,
        "definition"=>"Nx times developed skin width is the total axial end resultant, shared by actual FE section A11 tributaries. Ny is balanced BASIC-Y chordwise edge compression; Nxy is a balanced complementary membrane shear traction.",
        "curvature_note"=>"On a curved panel, BASIC-Y Ny has both local normal and tangential components. No hidden radial pressure is added; analytical checks use recovered membrane loads.")
end

function build_panel_model(input::AbstractDict)
    p=normalize_panel_params(input);materials=_materials(p);properties=_properties(p,materials);warnings=String[]
    half=p["width"]/2;foot=p["footW"]/2
    if foot>0
        left=foot<half ? collect(range(-half,-foot;length=p["ny"]+1)) : [-foot]
        middle=sort!(unique!(vcat(collect(range(-foot,foot;length=p["nf"]+1)),[0.])))
        right=foot<half ? collect(range(foot,half;length=p["ny"]+1)) : [foot]
        stations=sort!(unique!(vcat(left,middle,right)))
        isodd(p["nf"])&&push!(warnings,"An exact center rail was inserted across the odd flange subdivision count to connect the web conformingly.")
    else
        stations=collect(range(-half,half;length=2p["ny"]+1))
    end
    crown=findfirst(iszero,stations);crown===nothing&&error("Missing crown rail")
    nodes=Dict{String,Any}[];elements=Dict{String,Any}[];frames=Dict{Int,Matrix{Float64}}()
    skin=Matrix{Int}(undef,p["nx"]+1,length(stations));web=Matrix{Int}(undef,p["nx"]+1,p["bladeH"]>0 ? p["nz"]+1 : 0)
    for (j,s) in enumerate(stations)
        theta=iszero(p["R"]) ? 0. : s/p["R"]
        frames[1000+j]=hcat([0.,sin(theta),-cos(theta)],[0.,cos(theta),sin(theta)],[1.,0.,0.])
    end
    function node!(x,y,z,cd,s)
        all(isfinite,(x,y,z))||throw(ArgumentError("Panel node coordinates exceed the supported numerical range"))
        id=length(nodes)+1;push!(nodes,Dict{String,Any}("id"=>id,"x"=>x,"y"=>y,"z"=>z,"cd"=>cd,"s"=>s));id
    end
    for i in 1:p["nx"]+1,j in eachindex(stations)
        r=_surface(p,stations[j]);skin[i,j]=node!((i-1)*p["length"]/p["nx"],r[2],r[3],1000+j,stations[j])
    end
    if p["bladeH"]>0
        for i in 1:p["nx"]+1
            web[i,1]=skin[i,crown]
            for k in 1:p["nz"];web[i,k+1]=node!((i-1)*p["length"]/p["nx"],0.,k*p["bladeH"]/p["nz"],1000+crown,0.);end
        end
    end
    strip_pids=[foot>0&&stations[j]>=-foot-1e-12&&stations[j+1]<=foot+1e-12 ? 3 : 1 for j in 1:length(stations)-1]
    region_ids=Dict("skin_left"=>Int[],"skin_right"=>Int[],"footprint"=>Int[],"web"=>Int[])
    ratios=Float64[]
    function shell!(pid,ids,component)
        xyz=[Float64[nodes[id][key] for key in ("x","y","z")] for id in ids]
        area=norm(cross(xyz[3]-xyz[1],xyz[4]-xyz[2]))/2
        lengths=[norm(xyz[mod1(k+1,4)]-xyz[k]) for k in 1:4]
        isfinite(area)&&area>0&&all(isfinite,lengths)&&minimum(lengths)>0||throw(ArgumentError("The generated mesh contains a collapsed or numerically invalid shell"))
        push!(ratios,maximum(lengths)/minimum(lengths))
        eid=length(elements)+1
        push!(elements,Dict{String,Any}("eid"=>eid,"pid"=>pid,"n"=>ids,"nodes"=>ids,"component"=>component,"area"=>area,"zoffs"=>0.));eid
    end
    for i in 1:p["nx"],j in 1:length(stations)-1
        pid=strip_pids[j];eid=shell!(pid,[skin[i,j],skin[i+1,j],skin[i+1,j+1],skin[i,j+1]],pid==3 ? "combined" : "skin")
        push!(region_ids[(stations[j]+stations[j+1])/2<0 ? "skin_left" : "skin_right"],eid)
        pid==3&&push!(region_ids["footprint"],eid)
    end
    for i in 1:p["nx"],k in 1:size(web,2)-1
        push!(region_ids["web"],shell!(2,[web[i,k],web[i+1,k],web[i+1,k+1],web[i,k+1]],"web"))
    end
    maximum(ratios)>15&&push!(warnings,"Largest shell edge ratio is $(round(maximum(ratios);digits=2)); refine the long mesh direction to bring it below 15.")
    edges=Dict{String,Any}("edgeX0"=>vec(skin[1,:]),"edgeX1"=>vec(skin[end,:]),"edgeY0"=>vec(skin[:,1]),"edgeY1"=>vec(skin[:,end]),
        "webX0"=>size(web,2)>0 ? vec(web[1,:]) : Int[],"webX1"=>size(web,2)>0 ? vec(web[end,:]) : Int[],
        "footX0"=>[skin[1,j] for j in eachindex(stations) if foot>0&&abs(stations[j])<=foot+1e-12],
        "footX1"=>[skin[end,j] for j in eachindex(stations) if foot>0&&abs(stations[j])<=foot+1e-12],
        "c00"=>skin[1,1],"c01"=>skin[1,end],"cL0"=>skin[end,1],"cL1"=>skin[end,end],"crownX0"=>skin[1,crown],"crownX1"=>skin[end,crown])
    constraints,bc_report=_constraints(p,nodes,frames,edges)
    forces,tributaries,load_report=_loads(p,nodes,skin,web,stations,strip_pids,properties)
    regions=Dict{String,Any}(name=>Dict{String,Any}("eids"=>ids,"length"=>p["length"],"width"=>name in ("skin_left","skin_right") ? half : name=="footprint" ? p["footW"] : p["bladeH"]) for (name,ids) in region_ids)
    for (name,indices) in (("skin_left",1:crown-1),("skin_right",crown:length(stations)-1))
        regions[name]["strips"]=[Dict{String,Any}("pid"=>strip_pids[j],"developed_width"=>stations[j+1]-stations[j],"chord_width"=>norm(_surface(p,stations[j+1])-_surface(p,stations[j]))) for j in indices]
    end
    regions["skin_segments"]=[Dict{String,Any}("s0"=>stations[j],"s1"=>stations[j+1],"pid"=>strip_pids[j],
        "y0"=>_surface(p,stations[j])[2],"z0"=>_surface(p,stations[j])[3],"y1"=>_surface(p,stations[j+1])[2],"z1"=>_surface(p,stations[j+1])[3],
        "eids"=>[elements[(i-1)*(length(stations)-1)+j]["eid"] for i in 1:p["nx"]]) for j in 1:length(stations)-1]
    mass=sum(element["area"]*properties[element["pid"]]["areal_mass"] for element in elements)
    isfinite(mass)||throw(ArgumentError("Panel mass exceeds the supported numerical range"))
    report=Dict{String,Any}("boundary"=>bc_report,"loads"=>load_report,"mass_tonne"=>mass,"mass_tonnes"=>mass,"mass_kg"=>1000mass,
        "max_edge_ratio"=>maximum(ratios),"transverse_stations_mm"=>stations,"skin_grid"=>[vec(skin[i,:]) for i in axes(skin,1)],"web_grid"=>[vec(web[i,:]) for i in axes(web,1)],
        "mesh_counts"=>Dict("along_length"=>p["nx"],"outside_each_half"=>p["ny"],"blade_height"=>p["bladeH"]>0 ? p["nz"] : 0,"flange_width"=>count(==(3),strip_pids),"skin_width"=>length(stations)-1),
        "model_version"=>"boxer_conforming_bonded_flange_v1",
        "units"=>Dict("length"=>"mm","force"=>"N","stress"=>"MPa","density"=>"tonne/mm3","mass"=>"tonne"),
        "mesh_philosophy"=>"Exact flange footprint rails, one combined skin/flange shell layer, shared web-base nodes and a geometry-fixed thickness design map, matching Boxer shell-stringer construction.",
        "height_reference"=>"bladeH is actual blade height measured from the skin reference rail, not an overall T height; thickness edits do not move web nodes.",
        "analysis_allowed"=>!isempty(forces))
    PanelModel(p,nodes,elements,properties,materials,frames,edges,regions,forces,constraints,tributaries,report,warnings)
end

function panel_variables(m::PanelModel)
    p=m.params;composite=p["material_mode"]=="composite"
    [Dict{String,Any}("id"=>composite ? "scale"*suffix : "t"*suffix,"label"=>label,"unit"=>composite ? "scale" : "mm",
        "value"=>p[composite ? "scale"*suffix : "t"*suffix],"active"=>active,"fixed_topology"=>true)
        for (suffix,label,active) in (("Skin","Skin thickness",true),("Web","Blade/web thickness",p["bladeH"]>0),("Foot","Additional attached-flange thickness",p["footW"]>0)) if active]
end

"""Exact property directions, including the inherited skin and reference shift."""
function panel_property_directions(m::PanelModel,variable_id::AbstractString)
    variable=String(variable_id);available=Dict(row["id"]=>row for row in panel_variables(m))
    haskey(available,variable)&&available[variable]["active"]||throw(ArgumentError("Unknown or inactive panel thickness variable '$variable'"))
    component=endswith(variable,"Skin") ? "skin" : endswith(variable,"Web") ? "web" : "foot"
    scale=startswith(variable,"scale")
    out=Dict{Int,Dict{String,Any}}()
    for (pid,property) in m.properties
        dlayer=[Dict{String,Any}("material_id"=>layer["material_id"],"angle"=>0.,"thickness"=>layer["component"]==component ? (scale ? layer["thickness"]/m.params[variable] : 1.) : 0.) for layer in property["layers"]]
        dt=sum(layer["thickness"] for layer in dlayer)
        ds=sum((dlayer[i]["thickness"] for i in eachindex(dlayer) if property["layers"][i]["component"]=="skin");init=0.)
        z0=pid==3&&m.params["shell_offsets"] ? -ds/2 : -dt/2
        out[pid]=Dict{String,Any}("type"=>property["type"],"thickness"=>dt,"t"=>dt,"z0"=>z0,"zoffs"=>0.,"layers"=>dlayer,"plies"=>dlayer,
            "ply_thicknesses"=>Float64[layer["thickness"] for layer in dlayer],"materials"=>Dict{Int,Any}(),
            "A11"=>sum(_q11(m.materials[property["layers"][i]["material_id"]],property["layers"][i]["angle"])*dlayer[i]["thickness"] for i in eachindex(dlayer)))
    end
    out
end

"""BASIC nodal dF/dx at fixed mesh, including section-stiffness load allocation."""
function panel_load_direction(m::PanelModel,variable_id::AbstractString)
    d=panel_property_directions(m,variable_id)
    total=sum(m.properties[row["pid"]]["A11"]*row["length_weight"] for row in m.axial_tributaries)
    dtotal=sum(d[row["pid"]]["A11"]*row["length_weight"] for row in m.axial_tributaries)
    result=Dict{Int,Vector{Float64}}();axial=m.params["Nx"]*m.params["width"]
    for row in m.axial_tributaries
        value=axial*(row["length_weight"]/total)*(d[row["pid"]]["A11"]-m.properties[row["pid"]]["A11"]*(dtotal/total))
        get!(result,row["nid0"],zeros(3))[1]+=value;get!(result,row["nidL"],zeros(3))[1]-=value
    end
    result
end

function panel_mesh_payload(m::PanelModel)
    arrows=Any[];bcs=Any[]
    for (nid,force) in sort!(collect(m.forces);by=first)
        node=m.nodes[nid];push!(arrows,Dict("nid"=>nid,"pos"=>[node["x"],node["y"],node["z"]],"dir"=>force/norm(force),"mag"=>norm(force)))
    end
    for constraint in m.constraints
        nid=constraint["nid"];node=m.nodes[nid];frame=m.frames[node["cd"]];dofs=constraint["components"]
        kind=dofs==[1] ? "radial" : dofs==[2] ? "hoop2" : dofs==[3] ? "axial3" : "pin23"
        push!(bcs,Dict("nid"=>nid,"pos"=>[node["x"],node["y"],node["z"]],"kind"=>kind,"normal"=>frame[:,1],
            "dirs"=>[frame[:,dof] for dof in dofs if dof<=3],"dofs"=>dofs,"components"=>join(dofs),"sources"=>constraint["sources"],"label"=>join(constraint["sources"],", ")))
    end
    geometry=Dict{String,Any}("nodes"=>m.nodes,"quads"=>m.elements,"R"=>m.params["R"],"edges"=>m.edges,
        "counts"=>Dict("nNodes"=>length(m.nodes),"nQuads"=>length(m.elements)),"properties"=>[m.properties[id] for id in sort!(collect(keys(m.properties)))])
    Dict{String,Any}("params"=>m.params,"parameters"=>m.params,"bdf"=>panel_bdf(m;require_load=false),"geometry"=>geometry,"loadbc"=>Dict("arrows"=>arrows,"bcs"=>bcs,"size"=>hypot(m.params["length"],m.params["width"],m.params["bladeH"]),"R"=>m.params["R"]),
        "report"=>m.report,"model_report"=>m.report,"mass_tonnes"=>m.report["mass_tonnes"],"warnings"=>m.warnings,"variables"=>panel_variables(m),
        "catalog"=>Dict("variables"=>panel_variables(m),"scope"=>"Generated fixed-topology shell thicknesses; geometry and material-constant edits require a new model."))
end

_field(value)=value===nothing ? "" : value isa AbstractFloat ? begin
    s=@sprintf("%.16g",value);occursin(r"[.eE]",s) ? s : s*"."
end : string(value)

"""Write one canonical SOL105 deck. Zero preload is never silently replaced."""
function panel_bdf(m::PanelModel;require_load=true)
    require_load&&isempty(m.forces)&&throw(ArgumentError("SOL105 requires a nonzero preload; define Nx, Ny or Nxy before analyzing"))
    io=IOBuffer()
    function card(name,fields...)
        values=Any[fields...]
        if isempty(values);println(io,name);return;end
        for first in 1:8:length(values)
            println(io,first==1 ? name : "+",",",join(_field.(values[first:min(first+7,end)]),","))
        end
    end
    println(io,"SOL 105\nCEND\nTITLE = Conforming stiffened panel\nECHO = NONE\nSUBCASE 1\n  SUBTITLE = LIMIT static preload\n  SPC = 10\n  LOAD = 20\nSUBCASE 2\n  SUBTITLE = Linear buckling\n  SPC = 10\n  STATSUB = 1\n  METHOD = 30\n  DISPLACEMENT(PLOT) = ALL\nBEGIN BULK\nPARAM,POST,-1\nPARAM,AUTOSPC,YES")
    println(io,"\$ One combined skin/flange layer; CD1 outward, CD2 tangent, CD3 axial.")
    println(io,"\$ Ny is balanced BASIC-Y chordwise compression; no artificial preload.")
    for cid in sort!(collect(keys(m.frames)))
        frame=m.frames[cid];card("CORD2R",cid,0,0.,0.,0.,1.,0.,0.,frame[1,1],frame[2,1],frame[3,1])
    end
    for mid in sort!(collect(keys(m.materials)))
        material=m.materials[mid]
        material["type"]=="MAT1" ? card("MAT1",mid,material["E"],nothing,material["nu"],material["rho"]) :
            card("MAT8",mid,material["E1"],material["E2"],material["nu12"],material["G12"],material["G13"],material["G23"],material["rho"])
    end
    for pid in sort!(collect(keys(m.properties)))
        property=m.properties[pid]
        if property["type"]=="PSHELL"
            mid=property["material_id"];card("PSHELL",pid,mid,property["thickness"],mid,1.,mid)
        else
            fields=Any[pid,property["z0"],0.,nothing,nothing,nothing,nothing,nothing]
            for layer in property["layers"];append!(fields,[layer["material_id"],layer["thickness"],layer["angle"],"YES"]);end
            card("PCOMP",fields...)
        end
    end
    for node in m.nodes;card("GRID",node["id"],0,node["x"],node["y"],node["z"],node["cd"]);end
    for element in m.elements;card("CQUAD4",element["eid"],element["pid"],element["n"]...,0.);end
    grouped=Dict{String,Vector{Int}}()
    for constraint in m.constraints;push!(get!(grouped,join(constraint["components"]),Int[]),constraint["nid"]);end
    for components in sort!(collect(keys(grouped)));card("SPC1",10,components,sort!(grouped[components])...);end
    for (nid,force) in sort!(collect(m.forces);by=first)
        mag=norm(force);card("FORCE",20,nid,0,mag,(force/mag)...)
    end
    card("EIGRL",30,nothing,nothing,m.params["nModes"])
    println(io,"ENDDATA");String(take!(io))
end

end # module PandeatorModel
