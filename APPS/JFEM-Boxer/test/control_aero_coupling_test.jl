# julia --project=. --startup-file=no APPS/JFEM-Boxer/test/control_aero_coupling_test.jl OUTPUT
using Test, LinearAlgebra, Random, WingFEGen, OpenJFEM
const W=WingFEGen;const N=OpenJFEM
const OUT=abspath(only(ARGS));mkpath(OUT)
function control_parameters()
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>.8,
        "planform.sweep"=>15.,"planform.dihedral"=>4.,"planform.twist_tip"=>-3.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>17,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>100.,"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.1,
        "eta_end"=>.9,"hinge_start"=>.65,"hinge_end"=>.65,"front_spar_start"=>.7,"front_spar_end"=>.7,
        "deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap","end_eta"=>.6,
        "span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap","eta"=>eta,"rib"=>rib)) for (eta,rib) in ((.25,2),(.55,3))]
    return p
end
build(p)=W.build_model(first(W.normalize_params(p)))
point(m,ref)=Tuple(m.xyz[3ref-2:3ref])
tests=@testset "Independent movable aerodynamic load paths" begin
    m=build(control_parameters());routing=W.aerodynamic_routing(m)
    control=get(m.movable_structure,"load_references",Any[]);virtual=filter(r->get(r,"massless",false),control)
    @test W.all_checks_pass(m)
    @test length(virtual)>0
    @test last(virtual)["eta"]==.9
    terminal=last(only(m.movable_structure["surfaces"])["rib_sections"])["perimeter_nodes"]
    @test all(r->Set(r["nodes"])==Set(terminal),virtual)
    @test length(unique(r.eid for r in routing.refs))==length(routing.refs)
    for (eta,xc,expected) in ((.5,.8,"control_rbe3"),(.8,.8,"control_rbe3"),(.5,.4,"external_rbe3"),(.95,.8,"external_rbe3"))
        p=W.camber_point(m.wing,eta,xc)
        @test W.aerodynamic_chord_fraction(m.wing,p,eta)≈xc atol=1e-12
        targets=W.aerodynamic_target_weights(routing,p)
        @test sum(last,targets)≈1.
        @test all(routing.refs[j].target_kind==expected for (j,_) in targets)
    end
    rng=MersenneTwister(2317);u=randn(rng,length(m.xyz));rot=randn(rng,length(m.xyz))
    points=[W.camber_point(m.wing,eta,xc) for (eta,xc) in ((.35,.82),(.8,.85),(.45,.3),(.98,.9))]
    panels=[(eta=(p[2]-m.wing.root_ref_y)/m.wing.semispan,position=p,force=Tuple(randn(rng,3)),moment=(0.,0.,0.)) for p in points]
    stations=W.transfer_aero_loads(m,panels);source=W.load_resultant(panels);target=W.load_resultant(stations)
    @test collect(source[1])≈collect(target[1]) atol=1e-12
    @test collect(source[2])≈collect(target[2]) atol=1e-12
    displacement=W.aerodynamic_point_displacements(m,points,u,rot)
    source_work=sum(dot(p.force,d) for (p,d) in zip(panels,displacement))
    target_work=sum(dot(s.force,u[3s.node_index-2:3s.node_index])+dot(s.moment,rot[3s.node_index-2:3s.node_index]) for s in stations)
    @test source_work≈target_work atol=1e-12
    load=(stations=stations,panels=panels,summary=Dict())
    routed=W.routed_applied_loads(m,load)
    for station in stations
        force=only(filter(s->s.gid==station.gid,routed.forces));moment=only(filter(s->s.gid==station.gid,routed.moments))
        @test all(isapprox.(force.force,station.force))
        @test all(isapprox.(moment.moment,station.moment))
    end
    # A control-only force stays entirely on controls through the final deck path.
    control_load=W.transfer_aero_loads(m,panels[1:2]);mapped=W.routed_applied_loads(m,(stations=control_load,panels=panels[1:2],summary=Dict()))
    @test all(all(iszero,s.force) for s in mapped.forces if s.target_kind=="external_rbe3")
    @test any(!all(iszero,s.force) for s in mapped.forces if s.target_kind=="control_rbe3")
    @test all(isapprox.(W.load_resultant([(position=s.position,force=s.force,moment=t.moment) for (s,t) in zip(mapped.forces,mapped.moments)])[2],W.load_resultant(panels[1:2])[2]))
    mask=W.aerodynamic_reference_point_mask(m);stride=length(m.aero_map)÷length(mask);ncontrol=0
    for a in eachindex(mask)
        p=Tuple(m.aero_xyz[3a-2:3a]);eta=(p[2]-m.wing.root_ref_y)/m.wing.semispan
        owner=W.aerodynamic_control_owner(routing.families,eta,W.aerodynamic_chord_fraction(m.wing,p,eta))
        owner===nothing && continue
        ncontrol+=1;@test mask[a]==1
        refs=Set(Int(r["ref"]) for r in owner.refs)
        @test all(m.aero_map[stride*(a-1)+k] in refs for k in 1:stride)
        # Independently reproduce the browser's point-specific rotation arm.
        du=zeros(3)
        for k in 1:stride
            j=m.aero_map[stride*(a-1)+k];w=m.aero_weights[stride*(a-1)+k]
            du.+=w.*(u[3j-2:3j].+cross(rot[3j-2:3j],collect(p).-collect(point(m,j))))
        end
        @test du≈collect(only(W.aerodynamic_point_displacements(m,[p],u,rot))) atol=1e-12
    end
    @test ncontrol>0
    prescribed=W.aerodynamic_loads(m)
    @test all(s.gid in Set(m.node_ids[sp.ref] for sp in m.rbe3) for s in prescribed.stations)
    @test occursin("No chordwise pressure distribution",prescribed.summary["limitations"])
    deck=joinpath(OUT,"control_coupling.bdf");W.write_reference(m,deck;large_field=true);parsed=N.bdf_to_model(deck);rbe3s=Dict(Int(r["ID"])=>r for r in values(parsed["RBE3s"]))
    @test all(haskey(rbe3s,r["eid"]) for r in control)
    @test all(all(g in m.node_ids[terminal] for g in Iterators.flatten(group.grids for group in rbe3s[r["eid"]]["WT_GROUPS"])) for r in virtual)
    p=control_parameters();p["loads.method"]="vortex_lattice";p["aero.chord_panels"]=4;p["aero.span_panels"]=8
    vm=build(p);vlm=W.aerodynamic_loads(vm)
    @test vlm.summary["force_error_N"]<1e-8
    @test vlm.summary["moment_error_Nm"]<1e-8
    @test any(!all(iszero,s.force) for s in W.routed_applied_loads(vm,vlm).forces if s.target_kind=="control_rbe3")
    @test occursin("undeflected",vlm.summary["control_loading_note"])
    payload=W.load_payload(vlm;model=vm)["vlm"]
    @test length(payload["vertex_bindings"])==4length(vlm.panels)
    @test length(payload["load_bindings"])==length(vlm.panels)
    vrouting=W.aerodynamic_routing(vm)
    for (panel,bindings) in zip(vlm.panels,payload["load_bindings"])
        expected=Dict(vrouting.refs[j].ref-1=>weight for (j,weight) in W.aerodynamic_target_weights(vrouting,panel.position) if weight>0)
        @test Dict(b["node_index"]=>b["weight"] for b in bindings)==expected
    end
    # Prescribed torque remains a main-box input even with additional references.
    vm.params["loads.torque_y"]=17.;with_torque=W.compute_aerodynamic_loads(vm)
    @test with_torque.summary["moment_error_Nm"]<1e-8
    @test !isempty(W.aerodynamic_plot_sources(vm,with_torque))
    native_deck=joinpath(OUT,"control_vlm_static.bdf");W.write_reference(vm,native_deck;large_field=true)
    native=N.solve_model(N.bdf_to_model(native_deck))
    displacements=only(native["subcases"])["displacements"]
    by_grid=Dict(r["grid_id"]=>r for r in displacements)
    translation(ref)=[by_grid[vm.node_ids[ref]][k] for k in ("t1","t2","t3")]
    rotation(ref)=[by_grid[vm.node_ids[ref]][k] for k in ("r1","r2","r3")]
    control_refs=vm.movable_structure["load_references"]
    physical=filter(r->!get(r,"massless",false),control_refs);terminal_ref=last(physical)["ref"]
    @test norm(translation(terminal_ref))>0
    for reference in filter(r->get(r,"massless",false),control_refs)
        ref=reference["ref"]
        expected=translation(terminal_ref)+cross(rotation(terminal_ref),collect(point(vm,ref)).-collect(point(vm,terminal_ref)))
        @test translation(ref)≈expected rtol=1e-7 atol=1e-10
        @test rotation(ref)≈rotation(terminal_ref) rtol=1e-7 atol=1e-10
    end
    write(joinpath(OUT,"native_displacement.json"),W.JSON.json(Dict("control_terminal_displacement_m"=>translation(terminal_ref),
        "control_terminal_rotation_rad"=>rotation(terminal_ref),"grid"=>vm.node_ids[terminal_ref],
        "solver"=>"JFEM SOL101","deck"=>basename(native_deck))))
    physical_parameters=deepcopy(p)
    for definition in physical_parameters["movable_surfaces.items"]
        definition["front_spar_start"]=definition["front_spar_end"]=.75
        definition["hinge_start"]=definition["hinge_end"]=.7
    end
    for (i,attachment) in enumerate(physical_parameters["movable_structure.attachments"])
        attachment["fitting"]="shell_lugs";attachment["lateral_stay"]=true;attachment["actuator"]=i==1
    end
    physical_model=build(physical_parameters)
    physical_deck=joinpath(OUT,"physical_hinge_vlm_static.bdf");W.write_reference(physical_model,physical_deck;large_field=true)
    physical_input=N.bdf_to_model(physical_deck);physical_result=N.solve_model(physical_input)
    result_case=only(physical_result["subcases"])
    physical_rows=Dict(r["grid_id"]=>r for r in result_case["displacements"])
    motion(ref,keys)=[physical_rows[physical_model.node_ids[ref]][key] for key in keys]
    tu(ref)=motion(ref,("t1","t2","t3"));tr(ref)=motion(ref,("r1","r2","r3"))
    joint_results=Any[]
    for attachment in physical_model.movable_structure["attachments"]
        axis=attachment["axis"];delta_t=tu(attachment["surface_ref"])-tu(attachment["box_ref"])
        delta_r=tr(attachment["surface_ref"])-tr(attachment["box_ref"])
        @test norm(cross(axis,[0.,1.,0.]))>.1 # genuinely swept/dihedral hinge frame
        @test norm(delta_t)<1e-9
        @test norm(cross(delta_r,axis))<1e-9
        push!(joint_results,Dict("axis"=>axis,"translation_difference_m"=>delta_t,"relative_rotation_rad"=>delta_r,
            "hinge_angle_rad"=>dot(delta_r,axis),"actuator"=>attachment["actuator"]))
    end
    @test any(abs(j["hinge_angle_rad"])>1e-8 for j in joint_results if j["actuator"])
    physical_loads=W.aerodynamic_loads(physical_model);applied=W.routed_applied_loads(physical_model,physical_loads)
    @test any(!all(iszero,s.force) for s in applied.forces if s.target_kind=="control_rbe3")
    reactions=[(position=point(physical_model,findfirst(==(r["grid_id"]),physical_model.node_ids)),
        force=Tuple(r[k] for k in ("t1","t2","t3")),moment=Tuple(r[k] for k in ("r1","r2","r3"))) for r in result_case["spc_forces"]]
    reaction_force,reaction_moment=W.load_resultant(reactions);load_force,load_moment=W.load_resultant(physical_loads.stations)
    @test norm(collect(reaction_force.+load_force))/max(1.,norm(collect(load_force)))<1e-6
    @test norm(collect(reaction_moment.+load_moment))/max(1.,norm(collect(load_moment)))<1e-6
    write(joinpath(OUT,"physical_hinge_native.json"),W.JSON.json(Dict("solver"=>"JFEM SOL101","deck"=>basename(physical_deck),
        "joints"=>joint_results,"force_balance_N"=>collect(reaction_force.+load_force),"moment_balance_Nm"=>collect(reaction_moment.+load_moment))))
end
counts=Test.get_test_counts(tests);write(joinpath(OUT,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
