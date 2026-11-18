using Test, LinearAlgebra, WingFEGen
const W=WingFEGen

function mass_report_fixture()
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.15,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>true,"fuel.start_rib"=>2,"fuel.end_rib"=>4,
        "loads.fuel_percent"=>60.,"leading_edge.enabled"=>true,"loads.cases"=>Any[],
        "nonstructural.movable"=>.5,"nonstructural.leading_edge_skin"=>.7,
        "nonstructural.leading_edge_rib"=>.9,
        "engines.items"=>[Dict("name"=>"Engine","x"=>-.4,"y"=>1.4,"z"=>-1.2,
            "mass"=>300.,"length"=>2.4,"front_rib"=>3,"aft_rib"=>3,"aft_xc"=>.55)]))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>.125,"eta_end"=>.875,"front_spar_start"=>.75,"front_spar_end"=>.75,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap",
        "span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap",
        "eta"=>eta,"fitting"=>"shell_lugs","actuator"=>eta==.25)) for eta in (.25,.75)]
    p
end

tensor(row)=reduce(vcat,permutedims.(row["inertia_kg_m2"]))

@testset "Leading-edge and control mass properties in reports" begin
    m=W.build_model(first(W.normalize_params(mass_report_fixture())))
    report=W.weights_payload(m)
    totals=report["totals"]
    components=filter(row->row["in_structure"]&&row["mass_kg"]>0,report["components"])
    properties=Dict(row["id"]=>row for row in report["mass_properties"])
    leading=filter(row->row["id"] in ("leading_edge_skins","leading_edge_ribs"),components)
    controls=only(filter(row->row["id"]=="movable_surfaces",components))
    @test totals["leading_edge_mass_kg"]≈sum(row["mass_kg"] for row in leading)>0
    @test totals["control_surface_mass_kg"]≈controls["mass_kg"]>0
    @test totals["leading_edge_weight_N"]≈W.WEIGHT_GRAVITY*totals["leading_edge_mass_kg"]
    @test totals["control_surface_weight_N"]≈W.WEIGHT_GRAVITY*totals["control_surface_mass_kg"]
    @test totals["structure_mass_kg"]≈sum(row["mass_kg"] for row in components)
    @test properties["structure"]["mass_kg"]≈totals["structure_mass_kg"]
    @test properties["movable_surfaces"]["mass_kg"]≈totals["control_surface_mass_kg"]
    @test properties["leading_edge_structure"]["mass_kg"]≈totals["leading_edge_mass_kg"]
    @test properties["loaded"]["mass_kg"]≈totals["loaded_mass_kg"]
    @test all(isfinite,Iterators.flatten(properties["loaded"]["inertia_kg_m2"]))

    # Independently combine the named component centers and central tensors.
    dry=properties["structure"]
    first_moment=sum(row["mass_kg"]*properties[row["id"]]["center_of_gravity_m"] for row in components)
    @test dry["center_of_gravity_m"]≈first_moment/totals["structure_mass_kg"]
    inertia=zeros(3,3)
    for row in components
        component=properties[row["id"]]
        delta=component["center_of_gravity_m"]-dry["center_of_gravity_m"]
        inertia.+=tensor(component)+row["mass_kg"]*(dot(delta,delta)*I-delta*delta')
    end
    @test tensor(dry)≈inertia rtol=2e-12 atol=1e-10

    # Whole-model moments include the offset engine and the selected fuel fill.
    loaded_parts=vcat([dry],W.engine_structure_data(m)["engines"],W.fuel_mass_state(m)["bays"])
    mass=sum(row["mass_kg"] for row in loaded_parts)
    center=sum(row["mass_kg"]*row["center_of_gravity_m"] for row in loaded_parts)/mass
    loaded_inertia=zeros(3,3)
    for row in loaded_parts
        delta=row["center_of_gravity_m"]-center
        loaded_inertia.+=tensor(row)+row["mass_kg"]*(dot(delta,delta)*I-delta*delta')
    end
    @test properties["loaded"]["center_of_gravity_m"]≈center
    @test tensor(properties["loaded"])≈loaded_inertia rtol=2e-12 atol=1e-10

    # Bay-display integration must conserve the full nose/control structure too.
    bays=W.structural_bay_mass_properties(m)
    @test sum(row["mass_kg"] for row in bays)≈totals["structure_mass_kg"]
    @test sum(row["mass_kg"]*row["center_of_gravity_m"] for row in bays)≈first_moment
    bay_inertia=zeros(3,3)
    for row in bays
        delta=row["center_of_gravity_m"]-dry["center_of_gravity_m"]
        bay_inertia.+=tensor(row)+row["mass_kg"]*(dot(delta,delta)*I-delta*delta')
    end
    @test tensor(dry)≈bay_inertia rtol=2e-12 atol=1e-10
    quick=W.weights_payload(m;include_mass_properties=false)
    @test quick["totals"]==totals
    @test isempty(quick["mass_properties"])
    @test any(row->row[1]=="Included leading-edge structure",W.weights_info(m))
    @test any(row->row[1]=="Included control-surface structure",W.weights_info(m))

    # Geometry previews have zero material mass until FE structure is defined.
    p=deepcopy(m.params)
    p["movable_structure.surfaces"]=Any[]
    p["movable_structure.attachments"]=Any[]
    preview=W.weights_payload(W.build_model(first(W.normalize_params(p))))
    @test preview["totals"]["control_surface_mass_kg"]==0
    @test !any(row->row["id"]=="movable_surfaces",preview["mass_properties"])
    @test totals["structure_mass_kg"]-preview["totals"]["structure_mass_kg"]≈controls["mass_kg"]
    if !isempty(ARGS)
        output=abspath(only(ARGS));mkpath(output)
        write(joinpath(output,"weights.json"),W.JSON.json(report))
    end
end
