# Mass accounting for the generated, undeformed FE model, including per-case
# fuel CONM2 mass. Units are SI; displayed weight uses standard g.
const WEIGHT_GRAVITY = 9.80665
const WEIGHT_COMPONENTS = (
    ("upper_skin", "Upper skin", ("UPPER_SKIN", "UPPER_SKIN_RUNOUTS")),
    ("lower_skin", "Lower skin", ("LOWER_SKIN", "LOWER_SKIN_RUNOUTS")),
    ("front_spar", "Front spar web", ("FRONT_SPAR_WEB",)),
    ("rear_spar", "Rear spar web", ("REAR_SPAR_WEB",)),
    ("ribs", "Rib webs", ("RIB_WEBS",)),
    ("rib_stiffeners", "Rib T stiffeners", ("RIB_STIFFENERS",)),
    ("stringers", "T stringers", ("STRINGERS",)),
    ("spar_caps", "Square spar caps", ("SPAR_CAPS",)),
    ("runouts", "Stringer runout bars", ("STRINGER_RUNOUTS",)),
)

"""Projected midsurface shell area, matching native JFEM shell mass geometry.

For a warped CQUAD4 this is half the norm of its diagonal cross product,
equivalent to the polygon area in JFEM's element plane; it is independent of
the arbitrary renderer triangulation. Triangles use their exact planar area.
"""
function weight_shell_area(points)
    length(points) == 3 && return norm3(cross3(points[2] .- points[1],points[3] .- points[1]))/2
    length(points) == 4 && return norm3(cross3(points[3] .- points[1],points[4] .- points[2]))/2
    throw(ArgumentError("shell mass requires three or four corner points"))
end

weight_shell_thickness(p,pid)=shell_thickness(p,pid)

weight_base_group(name::String)=component_base_group(name)

"""Physical shell density moments through thickness, in the native mass convention.
PSHELL NSM follows its uniform thickness; PCOMP NSM lies at its reference plane.
"""
function structural_shell_mass_moments(p,pid)
    property=shell_material_definition(p,pid)
    if property["type"]=="PSHELL"
        m0=property["areal_mass_kg_m2"]
        return (m0,zero(m0),m0*property["thickness_m"]^2/12)
    end
    m0=property["nonstructural_mass_kg_m2"];m1=zero(m0);m2=zero(m0);z=property["z0_m"]
    for ply in property["plies"]
        next=z+ply["thickness_m"];rho=ply["material"]["rho_kg_m3"]
        m0+=rho*(next-z);m1+=rho*(next^2-z^2)/2;m2+=rho*(next^3-z^3)/3;z=next
    end
    (m0,m1,m2)
end

"""Raw element mass moments about `origin`, shared by aggregation and tangents.

Returns `(mass, first, second)` with `second = integral(r*r' dm)`, not an inertia
tensor. Signed/zero density moments are supported without mass division or
Float64 conversion. `shell_moments=(m0,m1,m2)` overrides thickness integration;
`bar_properties=(linear_mass,offset,section_second)` overrides bar data, with
global centroid offset and global section second moment *per unit length*.
Native CBAR NSM is distributed uniformly through its section (rho + NSM/A).
"""
function structural_element_mass_moments(m::Model,gr::ElemGroup,e::Int;
        shell_moments=nothing,bar_properties=nothing,origin=zeros(3))
    points=element_points(m,gr,e);p=[collect(point)-origin for point in points]
    if gr.kind===:bar
        a,b=p;d=b-a;length_e=norm3(Tuple(d))
        if bar_properties===nothing
            section=section_definition(m.params,gr.pid);rho=bar_material_definition(m.params,gr.pid)["rho"]
            density=rho+nonstructural_mass_density(m.params,gr.pid)/section["area_m2"]
            x=d/length_e;v=gr.orient[3*e-2:3*e];y=collect(unit3(Tuple(v-sum(x.*v)*x)));z=collect(cross3(Tuple(x),Tuple(y)))
            bar_properties=(linear_mass=density*section["area_m2"],offset=collect(bar_section_offset(m,gr,e)),
                section_second=density*(section["I1_m4"]*(y*y')+section["I2_m4"]*(z*z')))
        end
        mass=length_e*bar_properties.linear_mass;center=(a+b)/2+collect(bar_properties.offset)
        return (mass=mass,first=mass*center,second=mass*(center*center'+d*d'/12)+length_e*bar_properties.section_second)
    end
    m0,m1,m2=shell_moments===nothing ? structural_shell_mass_moments(m.params,gr.pid) : shell_moments
    normal=collect(unit3(length(p)==3 ? cross3(points[2].-points[1],points[3].-points[1]) :
        cross3(points[3].-points[1],points[4].-points[2])))
    nn=normal*normal'
    if length(p)==3
        area=weight_shell_area(points);center=sum(p)/3;covariance=sum((v-center)*(v-center)' for v in p)/12
        return (mass=area*m0,first=area*(m0*center+m1*normal),
            second=area*(m0*(covariance+center*center')+m1*(center*normal'+normal*center')+m2*nn))
    end
    length(p)==4||throw(ArgumentError("structural mass supports shell triangles/quads and bars"))
    scalar=m0+m1+m2+first(origin);mass=zero(scalar);first_moment=zeros(typeof(scalar),3);second=zeros(typeof(scalar),3,3)
    signs=((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))
    # 2x2 Gauss integrates bilinear geometry moments with the projected Jacobian.
    for xi in (-inv(sqrt(3.)),inv(sqrt(3.))),eta in (-inv(sqrt(3.)),inv(sqrt(3.)))
        shape=[(1+sx*xi)*(1+sy*eta)/4 for (sx,sy) in signs]
        dx=ntuple(k->sum(signs[i][1]*(1+signs[i][2]*eta)*p[i][k]/4 for i in 1:4),3)
        dy=ntuple(k->sum(signs[i][2]*(1+signs[i][1]*xi)*p[i][k]/4 for i in 1:4),3)
        jac=abs(sum(cross3(dx,dy).*normal));center=sum(shape[i]*p[i] for i in 1:4)
        mass+=jac*m0;first_moment.+=jac.*(m0*center+m1*normal)
        second.+=jac.*(m0*(center*center')+m1*(center*normal'+normal*center')+m2*nn)
    end
    (mass=mass,first=first_moment,second=second)
end

"""Physical bay ownership, using mesh topology even for swept or angled ribs.
An interior rib's web/stiffeners contribute half to each neighboring bay;
root/tip ribs contribute fully inward. A property is never used as a bay ID.
"""
function structural_element_bay_weights(m::Model,gr::ElemGroup,e::Int)
    n=gr.kind===:bar ? 2 : gr.kind===:tria ? 3 : 4
    rows=[m.node_keys[node][2] for node in gr.conn[n*(e-1)+1:n*e]]
    lo,hi=extrema(rows);ribs=m.grid.ribs;nbays=length(ribs)-1
    rib=findfirst(==(lo),ribs)
    if lo==hi&&rib!==nothing
        rib==1&&return [(1,1.)]
        rib==length(ribs)&&return [(nbays,1.)]
        return [(rib-1,.5),(rib,.5)]
    end
    bay=clamp(searchsortedlast(ribs,lo),1,nbays)
    ribs[bay]<=lo<=hi<=ribs[bay+1]||throw(ArgumentError("Element $(gr.eids[e]) crosses physical rib bays"))
    [(bay,1.)]
end

"""Conserved structural mass/CG/inertia in every physical rib bay.

Existing bay reference GRIDs are reused. Otherwise the loft-volume center is
only a computed display anchor; this function never adds FE nodes or masses.
The central tensor retains shell-layer and beam-section rotary contributions.
"""
function structural_bay_mass_properties(m::Model)
    nbays=length(m.grid.ribs)-1
    spiders=Dict(sp.start_rib=>sp for sp in m.fuel_rbe3)
    references=[haskey(spiders,bay) ? copy(m.xyz[3spiders[bay].ref-2:3spiders[bay].ref]) : collect(fuel_bay_geometry(m,bay).center) for bay in 1:nbays]
    mass=zeros(nbays);first_moment=[zeros(3) for _ in 1:nbays];second=[zeros(3,3) for _ in 1:nbays]
    properties=[Set{Int}() for _ in 1:nbays];counts=zeros(Int,nbays)
    for gr in m.groups,e in 1:n_elements(gr),(bay,fraction) in structural_element_bay_weights(m,gr,e)
        moment=structural_element_mass_moments(m,gr,e;origin=references[bay])
        mass[bay]+=fraction*moment.mass;first_moment[bay].+=fraction.*moment.first;second[bay].+=fraction.*moment.second
        push!(properties[bay],gr.pid);counts[bay]+=1
    end
    result=Dict{String,Any}[]
    for bay in 1:nbays
        ref=references[bay];offset=mass[bay]>0 ? first_moment[bay]/mass[bay] : zeros(3)
        central=second[bay]-mass[bay]*(offset*offset');central=(central+central')/2
        trace=sum(central[i,i] for i in 1:3);inertia=[(i==j ? trace : 0.)-central[i,j] for i in 1:3,j in 1:3]
        sp=get(spiders,bay,nothing)
        push!(result,Dict{String,Any}("index"=>bay,"start_rib"=>bay,"end_rib"=>bay+1,"kind"=>"structural",
            "label"=>"Structural rib bay $bay","mass_kg"=>mass[bay],"reference_m"=>ref,
            "center_of_gravity_m"=>ref+offset,"offset_m"=>offset,"inertia_kg_m2"=>[collect(inertia[i,:]) for i in 1:3],
            "conm2_inertia_kg_m2"=>[inertia[1,1],-inertia[2,1],inertia[2,2],-inertia[3,1],-inertia[3,2],inertia[3,3]],
            "reference_node"=>sp===nothing ? nothing : sp.ref-1,"reference_grid"=>sp===nothing ? nothing : m.node_ids[sp.ref],
            "rbe3_eid"=>sp===nothing ? nothing : sp.eid,"reference_kind"=>sp===nothing ? "computed_bay_center" : "bay_reference_grid",
            "property_ids"=>sort!(collect(properties[bay])),"element_count"=>counts[bay]))
    end
    result
end

structural_inertia_payload(m::Model)=structural_bay_mass_properties(m)

function weight_component(m::Model,id,label,names)
    selected = [gr for gr in m.groups if weight_base_group(gr.name) in names]
    row=Dict{String,Any}("id"=>id,"label"=>label,"groups"=>[gr.name for gr in selected],"count"=>0,
        "kind"=>id in ("stringers","spar_caps","runouts","rib_stiffeners") ? "bar" : "shell",
        "area_m2"=>0.,"length_m"=>0.,"volume_m3"=>0.,"mass_kg"=>0.,"weight_N"=>0.,
        "nonstructural_mass_kg"=>0.,"in_structure"=>true,"in_deck"=>true)
    dimensions=Float64[]
    for gr in selected
        row["count"]+=n_elements(gr)
        if gr.kind===:bar
            area=section_definition(m.params,gr.pid)["area_m2"]
            n_elements(gr)>0&&push!(dimensions,area)
            # Both CBAR ends have the same global section-centroid offset,
            # so the effective endpoint length equals the GRID-to-GRID length.
            length_total=sum((norm3(points[2] .- points[1]) for points in
                (element_points(m,gr,e) for e in 1:n_elements(gr)));init=0.)
            row["length_m"]+=length_total
            row["volume_m3"]+=area*length_total
            row["mass_kg"]+=length_total*bar_mass_per_length(m.params,gr.pid)
            row["nonstructural_mass_kg"]+=length_total*nonstructural_mass_density(m.params,gr.pid)
        else
            thickness=weight_shell_thickness(m.params,gr.pid)
            area=sum((weight_shell_area(element_points(m,gr,e)) for e in 1:n_elements(gr));init=0.)
            n_elements(gr)>0&&push!(dimensions,thickness)
            row["area_m2"]+=area
            row["volume_m3"]+=area*thickness
            row["mass_kg"]+=area*shell_material_definition(m.params,gr.pid)["areal_mass_kg_m2"]
            row["nonstructural_mass_kg"]+=area*nonstructural_mass_density(m.params,gr.pid)
        end
    end
    if !isempty(dimensions)
        key=row["kind"]=="bar" ? "section_area_m2" : "thickness_m"
        denominator=row["kind"]=="bar" ? row["length_m"] : row["area_m2"]
        row[key]=row["volume_m3"]/denominator
        row[key*"_min"]=minimum(dimensions);row[key*"_max"]=maximum(dimensions)
        row["property_count"]=length(unique(gr.pid for gr in selected if !isempty(gr.eids)))
        row["distinct_dimension_count"]=length(unique(dimensions))
        row["dimension_note"]="Scalar is length-weighted bar area or area-weighted shell thickness; minimum/maximum preserve override ranges."
    end
    row["weight_N"]=row["mass_kg"]*WEIGHT_GRAVITY
    row["material_mass_kg"]=row["mass_kg"]-row["nonstructural_mass_kg"]
    return row
end

"""Dry structure, optional exported aero shells, and case-specific fuel CONM2 mass."""
function weights_payload(m::Model)
    p=m.params
    rows=Any[weight_component(m,id,label,names) for (id,label,names) in WEIGHT_COMPONENTS]
    recognized=Set(name for (_,_,names) in WEIGHT_COMPONENTS for name in names)
    for (id,label,names) in (("leading_edge_skins","Leading-edge skins",("LE_UPPER_SKIN","LE_LOWER_SKIN")),
                            ("leading_edge_ribs","Leading-edge ribs",("LE_RIB_WEBS","LE_RIB_NOSE")))
        union!(recognized,names)
        any(gr->weight_base_group(gr.name) in names,m.groups) && push!(rows,weight_component(m,id,label,names))
    end
    all(gr->weight_base_group(gr.name) in recognized,m.groups) || throw(ArgumentError("unclassified structural element group in mass accounting"))
    structure=sum(row["mass_kg"] for row in rows)
    nonstructural=sum(row["nonstructural_mass_kg"] for row in rows)
    aero_mass=0.
    if p["output.include_aero_shells"]
        count=length(m.aero_quads)÷4
        points(e)=[Tuple(m.aero_xyz[3id-2:3id]) for id in m.aero_quads[4*e-3:4*e]]
        area=sum((weight_shell_area(points(e)) for e in 1:count);init=0.)
        thickness=weight_shell_thickness(p,PID_AERO)
        volume=area*thickness;aero_mass=volume*p["material.rho"]
        push!(rows,Dict{String,Any}("id"=>"exported_aero_shells","label"=>"Exported aero shells","kind"=>"shell",
            "groups"=>["AERO_LOFT"],"count"=>count,"area_m2"=>area,"length_m"=>0.,"thickness_m"=>thickness,
            "volume_m3"=>volume,"mass_kg"=>aero_mass,"weight_N"=>aero_mass*WEIGHT_GRAVITY,
            "in_structure"=>false,"in_deck"=>true,
            "note"=>"Optional unconnected FE shells over the full aerodynamic half lifting surface; included in deck mass, separate from structural mass."))
    end
    tank=fuel_summary(m)
    fuel_state=fuel_mass_state(m)
    density=Float64(p["fuel.density"]);fill=fuel_state["fill_fraction"]
    volume=get(tank,"volume_m3",0.)
    capacity=volume*density;fuel_mass=fuel_state["mass_kg"]
    fuel=Dict{String,Any}("enabled"=>tank["enabled"],"density_kg_m3"=>density,"fill_fraction"=>fill,
        "fill_efficiency"=>fuel_state["fill_efficiency"],"gross_volume_m3"=>get(tank,"gross_volume_m3",0.),
        "gross_filled_volume_m3"=>fuel_state["gross_filled_volume_m3"],"filled_volume_m3"=>fuel_state["filled_volume_m3"],
        "volume_m3"=>volume,"capacity_mass_kg"=>capacity,"mass_kg"=>fuel_mass,
        "weight_N"=>fuel_mass*WEIGHT_GRAVITY,"start_rib"=>get(tank,"start_rib",nothing),
        "end_rib"=>get(tank,"end_rib",nothing),"in_deck"=>fuel_mass>0,"fuel_percent"=>100fill)
    bays=Any[]
    if tank["enabled"]
        for bay in fuel_state["bays"]
            bay_volume=bay["volume_m3"]
            bay_capacity=bay_volume*density;bay_mass=bay["mass_kg"]
            push!(bays,merge(copy(bay),Dict{String,Any}(
                "filled_volume_m3"=>bay["filled_volume_m3"],"capacity_mass_kg"=>bay_capacity,
                "mass_kg"=>bay_mass,"weight_N"=>bay_mass*WEIGHT_GRAVITY)))
        end
    end
    fuel["bays"]=bays
    fuel["bay_note"]="Fuel status is a percentage of usable capacity. Each bay fills upward to its own horizontal global-Z level at that percentage of gross geometry; uniform fill efficiency scales volume, mass and inertia without changing the level or CG. CONM2 carries the resulting mass, center of gravity and inertia; acceleration loads act through its separate fuel RBE3."
    totals=Dict{String,Any}("structure_mass_kg"=>structure,"exported_aero_mass_kg"=>aero_mass,
        "nonstructural_mass_kg"=>nonstructural,"material_mass_kg"=>structure-nonstructural,
        "deck_mass_kg"=>structure+aero_mass+fuel_mass,"fuel_mass_kg"=>fuel_mass,"fuel_capacity_mass_kg"=>capacity,
        "loaded_mass_kg"=>structure+fuel_mass)
    for name in ("structure","nonstructural","material","exported_aero","deck","fuel","fuel_capacity","loaded")
        totals[name*"_weight_N"]=totals[name*"_mass_kg"]*WEIGHT_GRAVITY
    end
    all(value->isfinite(value)&&value>=0,values(totals)) || throw(ArgumentError("mass calculation overflowed or produced an invalid total"))
    return Dict{String,Any}("components"=>rows,"totals"=>totals,"fuel"=>fuel,
        "gravity_m_s2"=>WEIGHT_GRAVITY,"material_density_kg_m3"=>p["material.rho"],
        "materials"=>[material_payload(material) for material in model_material_definitions(m)],
        "scope"=>"Modeled half lifting surface, from the root to the final structural rib",
        "method"=>"Shell mass = FE projected midsurface area × (ply mass per area + non-structural surface density). Bar mass = FE length × (section area × material density + non-structural linear density).",
        "note"=>"Fuel usable capacity equals gross wet-bay volume times the uniform fill efficiency factor; no separate structure, equipment or wall-thickness deductions are made. Per-bay CONM2 masses and fuel inertia use the selected case's percentage of usable capacity. Include structural inertia applies the same signed acceleration to the dry shell/bar mass using explicit dead forces and section-offset couples. RBE3 constraints and display meshes have no material mass.")
end

function weights_info(m::Model)
    data=weights_payload(m);total=data["totals"]
    rows=Tuple{String,String}[("Dry half lifting surface mass",@sprintf("%.9g kg (including %.9g kg non-structural)",total["structure_mass_kg"],total["nonstructural_mass_kg"])),
        ("Fuel FE mass",@sprintf("%.9g kg in per-bay CONM2 elements",total["fuel_mass_kg"])),
        ("Loaded half lifting surface mass",@sprintf("%.9g kg (structure + fuel)",total["loaded_mass_kg"]))]
    m.params["output.include_aero_shells"] && push!(rows,("Exported deck mass",@sprintf("%.9g kg, including separate unconnected aero shells",total["deck_mass_kg"])))
    rows
end
