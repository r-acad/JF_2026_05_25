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

function weight_component(m::Model,id,label,names)
    selected = [gr for gr in m.groups if weight_base_group(gr.name) in names]
    row=Dict{String,Any}("id"=>id,"label"=>label,"groups"=>[gr.name for gr in selected],"count"=>0,
        "kind"=>id in ("stringers","spar_caps","runouts","rib_stiffeners") ? "bar" : "shell",
        "area_m2"=>0.,"length_m"=>0.,"volume_m3"=>0.,"mass_kg"=>0.,"weight_N"=>0.,
        "in_structure"=>true,"in_deck"=>true)
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
            row["mass_kg"]+=area*length_total*bar_material_definition(m.params,gr.pid)["rho"]
        else
            thickness=weight_shell_thickness(m.params,gr.pid)
            area=sum((weight_shell_area(element_points(m,gr,e)) for e in 1:n_elements(gr));init=0.)
            n_elements(gr)>0&&push!(dimensions,thickness)
            row["area_m2"]+=area
            row["volume_m3"]+=area*thickness
            row["mass_kg"]+=area*shell_material_definition(m.params,gr.pid)["areal_mass_kg_m2"]
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
            "note"=>"Optional unconnected FE shells over the full aerodynamic half wing; included in deck mass, separate from structural mass."))
    end
    tank=fuel_summary(m)
    fuel_state=fuel_mass_state(m)
    density=Float64(p["fuel.density"]);fill=fuel_state["fill_fraction"]
    volume=get(tank,"volume_m3",0.)
    capacity=volume*density;fuel_mass=fuel_state["mass_kg"]
    fuel=Dict{String,Any}("enabled"=>tank["enabled"],"density_kg_m3"=>density,"fill_fraction"=>fill,
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
    fuel["bay_note"]="Each bay fills upward to its own horizontal global-Z level at this case's percentage. CONM2 carries its actual mass, center of gravity and inertia; acceleration loads act through its separate fuel RBE3."
    totals=Dict{String,Any}("structure_mass_kg"=>structure,"exported_aero_mass_kg"=>aero_mass,
        "deck_mass_kg"=>structure+aero_mass+fuel_mass,"fuel_mass_kg"=>fuel_mass,"fuel_capacity_mass_kg"=>capacity,
        "loaded_mass_kg"=>structure+fuel_mass)
    for name in ("structure","exported_aero","deck","fuel","fuel_capacity","loaded")
        totals[name*"_weight_N"]=totals[name*"_mass_kg"]*WEIGHT_GRAVITY
    end
    all(value->isfinite(value)&&value>=0,values(totals)) || throw(ArgumentError("mass calculation overflowed or produced an invalid total"))
    return Dict{String,Any}("components"=>rows,"totals"=>totals,"fuel"=>fuel,
        "gravity_m_s2"=>WEIGHT_GRAVITY,"material_density_kg_m3"=>p["material.rho"],
        "materials"=>[material_payload(material) for material in model_material_definitions(m)],
        "scope"=>"Modeled half wing, from the root to the final structural rib",
        "method"=>"FE shell projected midsurface area × sum of ply thickness × assigned density (one ply for PSHELL); PBARL/PBAR area × CBAR effective length × assigned MAT1 density",
        "note"=>"Fuel uses gross tank capacity; structure, equipment and unusable fuel are not deducted. Per-bay CONM2 masses and fuel inertia use the selected case's fill. Include structural inertia applies the same signed acceleration to the dry shell/bar mass using explicit dead forces and section-offset couples. RBE3 constraints and display meshes have no material mass.")
end

function weights_info(m::Model)
    data=weights_payload(m);total=data["totals"]
    rows=Tuple{String,String}[("Dry half-wing structure mass",@sprintf("%.9g kg",total["structure_mass_kg"])),
        ("Fuel FE mass",@sprintf("%.9g kg in per-bay CONM2 elements",total["fuel_mass_kg"])),
        ("Loaded half-wing mass",@sprintf("%.9g kg (structure + fuel)",total["loaded_mass_kg"]))]
    m.params["output.include_aero_shells"] && push!(rows,("Exported deck mass",@sprintf("%.9g kg, including separate unconnected aero shells",total["deck_mass_kg"])))
    rows
end
