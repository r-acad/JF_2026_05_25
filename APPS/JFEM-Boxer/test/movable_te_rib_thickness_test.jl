using Test, LinearAlgebra, WingFEGen, OpenJFEM
const W=WingFEGen
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)

function te_parameters()
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.end_eta"=>1.,"box.rib_pitch"=>.25,
        "box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>2,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic",
        "loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "leading_edge.enabled"=>false))
    p["movable_surfaces.items"]=[Dict("name"=>name,"kind"=>kind,"edge"=>edge,"eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>hinge,"hinge_end"=>hinge,"front_spar_start"=>front,"front_spar_end"=>front,
        "hinge_z_start"=>0.,"hinge_z_end"=>0.,"deflection"=>0.,"color"=>"#29b6d1")
        for (name,kind,edge,hinge,front) in (("Flap","flap","trailing",.7,.78),("Slat","slat","leading",.15,.1))]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>name,
        "span_bays"=>4,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>2,
        "rib_material"=>2,"rib_thickness"=>.0012)) for name in ("Flap","Slat")]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>name,
        "eta"=>eta,"spar"=>spar,"fitting"=>"shell_lugs","actuator"=>true,"lug_thickness"=>thickness,
        "lateral_stay"=>true,"box_lateral_stay"=>false,"movable_lateral_stay"=>false)) for (name,spar,eta,thickness) in
        (("Flap","rear",.25,.003),("Flap","rear",.75,.004),("Slat","front",.25,.005),("Slat","front",.75,.006))]
    first(W.normalize_params(p))
end

suite=@testset "TE rib thickness controls each attachment without lateral stays" begin
    p=te_parameters()
    @test all(!haskey(a,"lateral_stay") for a in p["movable_structure.attachments"])
    @test !haskey(W.MOVABLE_ATTACHMENT_DEFAULTS,"lateral_stay")
    m=W.build_model(p);@test W.all_checks_pass(m)
    aa=m.movable_structure["attachments"]
    @test all(!haskey(a,"lateral_links")&&!haskey(a,"lateral_stay") for a in aa)
    payload=W.movable_connection_payload(m)
    @test !any(occursin("LATERAL",c["name"]) for c in payload)
    affected=Dict{Int,Int}()
    for (index,a) in enumerate(aa)
        surface_index=findfirst(s->s["surface"]==a["surface"],p["movable_structure.surfaces"])
        ribpid=35_000_000+1000surface_index+a["master_rib_index"]
        input_index=findfirst(r->r["surface"]==a["surface"]&&r["eta"]==a["requested_eta"],p["movable_structure.attachments"])
        t=p["movable_structure.attachments"][input_index]["lug_thickness"]
        for pid in (a["lug_pid"],ribpid)
            affected[pid]=input_index
            property=W.movable_shell_property(p,pid)
            @test property["thickness_m"]==t
            @test property["attachment_index"]==input_index
            @test property["thickness_source"]=="TE rib thickness"
            @test W.property_minimum_gauge(p,pid)["dimensions"][1]["minimum_key"]=="movable_structure.attachments#$input_index#lug_thickness"
            @test property["material_id"]==(pid==ribpid ? 2 : 1)
        end
        lug=only(filter(g->g.pid==a["lug_pid"],m.groups))
        @test a["box_ref"] in lug.conn
        @test a["surface_ref"] in lug.conn
    end
    for g in m.groups
        g.pid÷1_000_000==35&&!haskey(affected,g.pid)||continue
        @test W.movable_shell_property(p,g.pid)["thickness_m"]==.0012
        @test !get(W.movable_shell_property(p,g.pid),"attachment_rib",false)
    end
    file=joinpath(out,"te_ribs_without_stays.bdf");W.write_reference(m,file;large_field=true)
    parsed=OpenJFEM.bdf_to_model(file)
    @test length(parsed["RBE2s"])==length(aa)
    @test Set(Int(r["ID"]) for r in values(parsed["RBE2s"]))==Set(a["joint_eid"] for a in aa)
    for (pid,index) in affected
        @test parsed["PSHELLs"][string(pid)]["T"]≈p["movable_structure.attachments"][index]["lug_thickness"]
    end
    # One edited attachment changes only its two triangle fans and its own rib.
    changed=deepcopy(p);changed["movable_structure.attachments"][1]["lug_thickness"]*=1.5
    n=W.build_model(changed);@test n.xyz==m.xyz
    actual=Set(g.pid for g in m.groups if W.is_movable_pid(g.pid)&&
        W.movable_shell_property(p,g.pid)["thickness_m"]!=W.movable_shell_property(changed,g.pid)["thickness_m"])
    @test actual==Set(pid for (pid,index) in affected if index==1)
    expected_mass=0.
    for g in m.groups
        g.pid in actual||continue
        delta=W.movable_shell_property(changed,g.pid)["areal_mass_kg_m2"]-W.movable_shell_property(p,g.pid)["areal_mass_kg_m2"]
        expected_mass+=delta*sum(W.weight_shell_area(W.element_points(m,g,e)) for e in eachindex(g.eids))
    end
    @test W.weights_payload(n)["totals"]["structure_mass_kg"]-W.weights_payload(m)["totals"]["structure_mass_kg"]≈expected_mass rtol=1e-9
    duplicate=deepcopy(p);duplicate["movable_structure.attachments"][2]["eta"]=.26
    @test_throws r"multiple attachments snap" W.build_model(duplicate)
    write(joinpath(out,"summary.json"),W.JSON.json(Dict("passed"=>true,"attachments"=>length(aa),
        "affected_properties"=>affected,"mass_increase_kg"=>expected_mass,"nodes"=>length(m.node_ids))))
end
counts=Test.get_test_counts(suite)
println("TE rib assertions: ",counts.passes+counts.cumulative_passes)
