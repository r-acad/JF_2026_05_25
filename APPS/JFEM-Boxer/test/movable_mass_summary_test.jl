using Test, WingFEGen
const W=WingFEGen

@testset "Movable structure mass is visible and counted exactly once" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.15,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"loads.cases"=>Any[],
        "nonstructural.movable"=>.5))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>.125,"eta_end"=>.875,"front_spar_start"=>.75,"front_spar_end"=>.75,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap",
        "span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap",
        "eta"=>eta,"fitting"=>"shell_lugs","actuator"=>eta==.25)) for eta in (.25,.75)]
    m=W.build_model(first(W.normalize_params(p)))
    weights=W.weights_payload(m);row=only(filter(r->r["id"]=="movable_surfaces",weights["components"]))
    groups=filter(g->W.is_movable_pid(g.pid),m.groups)
    expected=sum(W.weight_shell_area(W.element_points(m,g,e))*W.shell_material_definition(m.params,g.pid)["areal_mass_kg_m2"]
        for g in groups for e in 1:W.n_elements(g))
    expected_nsm=sum(W.weight_shell_area(W.element_points(m,g,e))*.5 for g in groups for e in 1:W.n_elements(g))
    @test row["mass_kg"]≈expected
    @test row["nonstructural_mass_kg"]≈expected_nsm
    @test row["count"]==sum(W.n_elements,groups)
    @test row["surface_names"]==["Flap"]
    @test occursin("included",row["note"])
    @test occursin("hinge fittings",row["note"])
    @test any(g->g.pid÷1_000_000==37,groups)
    @test weights["totals"]["structure_mass_kg"]≈sum(r["mass_kg"] for r in weights["components"] if r["in_structure"])
    @test weights["totals"]["loaded_mass_kg"]≈weights["totals"]["structure_mass_kg"]
    @test weights["totals"]["deck_mass_kg"]≈weights["totals"]["structure_mass_kg"]
    preview=deepcopy(p);preview["movable_structure.surfaces"]=Any[];preview["movable_structure.attachments"]=Any[]
    unstructured=W.weights_payload(W.build_model(first(W.normalize_params(preview))))
    @test !any(r->r["id"]=="movable_surfaces",unstructured["components"])
    @test weights["totals"]["structure_mass_kg"]-unstructured["totals"]["structure_mass_kg"]≈expected
end
