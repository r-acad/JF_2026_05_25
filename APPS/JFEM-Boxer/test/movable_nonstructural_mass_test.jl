# julia --project=. APPS/JFEM-Boxer/test/movable_nonstructural_mass_test.jl SCRATCH
using Test, LinearAlgebra, TOML, MsgPack, WingFEGen, OpenJFEM
const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)

tests=@testset "Movable shell NSM and new skin defaults" begin
    p=W.default_params()
    for key in ("properties.t_skin_upper","properties.t_skin_lower","leading_edge.t_skin","output.t_aero_shell")
        @test p[key]==.001
    end
    @test W.MOVABLE_STRUCTURE_DEFAULTS["upper_thickness"]==.001
    @test W.MOVABLE_STRUCTURE_DEFAULTS["lower_thickness"]==.001
    @test p["nonstructural.movable"]==0.
    @test only(filter(s->s.key=="nonstructural.movable",W.SCHEMA)).unit=="kg/m2"
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>true,
        "loads.fuel_accel_x"=>.2,"loads.fuel_accel_y"=>-.1,"loads.fuel_accel_z"=>-1.,
        "fuel.enabled"=>false,"loads.cases"=>Any[],"leading_edge.enabled"=>true))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing",
        "eta_start"=>.1,"eta_end"=>.9,"front_spar_start"=>.75,"front_spar_end"=>.75,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap",
        "span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap",
        "eta"=>eta,"fitting"=>"shell_lugs","actuator"=>true)) for eta in (.25,.75)]
    build(x)=W.build_model(first(W.normalize_params(x)))
    m0=build(p)
    # Existing actual skin gauges remain editable; changing defaults is not a clamp.
    saved=deepcopy(m0.params);saved["properties.t_skin_upper"]=.0007
    saved["movable_structure.surfaces"][1]["upper_thickness"]=.0006
    restored=first(W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(saved)))))
    @test restored["properties.t_skin_upper"]==.0007
    @test restored["movable_structure.surfaces"][1]["upper_thickness"]==.0006
    p=deepcopy(m0.params);p["nonstructural.movable"]=.5
    p["nonstructural.leading_edge_skin"]=.7;p["nonstructural.leading_edge_rib"]=.9
    m=build(p)
    @test m.xyz==m0.xyz
    @test all(a.conn==b.conn for (a,b) in zip(m.groups,m0.groups))
    @test Set(g.pid÷1_000_000 for g in m.groups if W.is_movable_pid(g.pid))==Set([31,32,33,34,35,37])
    expected=0.;movable_expected=0.
    for g in m.groups
        g.kind===:bar&&continue
        area=sum(W.weight_shell_area(W.element_points(m,g,e)) for e in 1:W.n_elements(g))
        nsm=W.nonstructural_mass_density(p,g.pid)
        expected+=area*nsm
        if W.is_movable_pid(g.pid)
            movable_expected+=area*.5
            @test nsm==.5
            props=W.element_properties(m,g);base=W.element_properties(m0,g)
            @test props["nonstructural_mass_kg_m2"]==.5
            @test props["areal_mass_kg_m2"]-base["areal_mass_kg_m2"]≈.5
            @test props["thickness_m"]==base["thickness_m"]
        end
    end
    @test movable_expected>0
    weights=W.weights_payload(m);base=W.weights_payload(m0)
    @test weights["totals"]["nonstructural_mass_kg"]≈expected rtol=1e-12
    @test weights["totals"]["structure_mass_kg"]-base["totals"]["structure_mass_kg"]≈expected rtol=1e-12
    f0=sum(collect(x.force) for x in W.structure_applied_loads(m0))
    f1=sum(collect(x.force) for x in W.structure_applied_loads(m))
    @test f1-f0≈expected.*collect(W.structure_acceleration(p)) rtol=1e-10
    path=joinpath(out,"movable_nsm.bdf")
    open(path,"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
    deck=OpenJFEM.bdf_to_model(path)
    for (pid,prop) in deck["PSHELLs"]
        id=parse(Int,pid)
        W.is_movable_pid(id)&&(@test prop["NSM"]==.5)
    end
    bad=deepcopy(p);bad["nonstructural.movable"]=-.1
    @test_throws ArgumentError W.normalize_params(bad)
    @test W.nonstructural_mass_density(p,W.PID_AERO)==0.
    write(joinpath(out,"evidence.json"),W.JSON.json(Dict("expected_added_mass_kg"=>expected,
        "movable_added_mass_kg"=>movable_expected,"nodes"=>length(m.node_ids),"deck"=>path)))
    write(joinpath(out,"schema.json"),W.JSON.json(W.schema_payload(m0.params,"Numeric-entry test fixture")))
    write(joinpath(out,"payload.msgpack"),MsgPack.pack(W.mesh_payload(m0)))
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
