using Test, TOML, WingFEGen, OpenJFEM
const W=WingFEGen;const N=OpenJFEM
out=isempty(ARGS) ? mktempdir() : abspath(first(ARGS));mkpath(out)
function parameters()
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "output.solution"=>"101","output.n_modes"=>6))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.1,"eta_end"=>.9,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>20.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap","span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>1))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap","eta"=>eta,"rib"=>rib)) for (eta,rib) in ((.25,1),(.75,3))]
    p
end
build(p)=W.build_model(first(W.normalize_params(p)))
function deck(m,name;tipload=false)
    path=joinpath(out,name*".bdf");W.write_reference(m,path;large_field=true)
    if tipload
        nodes=only(W.movable_structure_data(m)["surfaces"])["nodes"]
        tip=nodes[argmax([m.xyz[3n-1]+m.xyz[3n-2]/100 for n in nodes])]
        write(path,replace(read(path,String),"ENDDATA"=>"FORCE,1,$(m.node_ids[tip]),0,100.,0.,0.,1.\nENDDATA"))
    end
    path,N.bdf_to_model(path)
end
reports=Any[]
tests=@testset "Movable-surface structure, fittings and analysis" begin
    p=parameters();m=build(p)
    @test W.all_checks_pass(m)
    @test length(W.movable_structure_data(m)["attachments"])==2
    movable=filter(g->W.is_movable_pid(g.pid),m.groups)
    @test length(unique(g.pid for g in movable if startswith(g.name,"MOVABLE_UPPER_SKIN")))==3 # two master ribs plus fixed span-end closures
    @test all(g->W.shell_thickness(m.params,g.pid)>0,movable)
    @test all(g->all(isfinite,Iterators.flatten(W.shell_material_frame(m,g,1))),movable)
    payload=W.mesh_payload(m)
    @test length(payload["movable_structure"]["surfaces"])==1
    @test length(payload["imported_connections"])==4
    @test length(filter(c->c["id"]>=80_000_000,payload["coordinate_systems"]["systems"]))==1
    @test !any(k->startswith(k,"generated."),keys(payload["model_params"]))
    @test all(g->haskey(g,"display_label"),filter(g->W.is_movable_pid(g["pid"]),payload["groups"]))
    saved=W.params_to_toml(m.params);restored,unknown=W.normalize_params(W.flatten_toml(TOML.parse(saved)))
    @test isempty(unknown)
    for key in ("movable_structure.surfaces","movable_structure.attachments");@test restored[key]==m.params[key];end
    @test W.build_model(restored).xyz==m.xyz
    neutral=parameters();neutral["movable_structure.surfaces"][1]["enabled"]=false;base=build(neutral)
    @test length(m.xyz)>length(base.xyz)
    @test W.weights_payload(m)["totals"]["structure_mass_kg"]>W.weights_payload(base)["totals"]["structure_mass_kg"]
    @test isempty(W.movable_structure_data(base)["attachments"])
    @test W.movable_distinct_stations([.3,.3+eps(.3),.7])==[.3,.7]
    # Coincident neutral hinge cuts have intentionally separate box/surface
    # GRIDs, whereas repeated nodes within one surface remain an error.
    touching=deepcopy(p);touching["movable_surfaces.items"][1]["hinge_start"]=.55;touching["movable_surfaces.items"][1]["hinge_end"]=.55
    @test W.all_checks_pass(build(touching))
    deflected=deepcopy(p);deflected["movable_structure.surfaces"][1]["mesh_deflected"]=true;dm=build(deflected)
    @test dm.xyz!=m.xyz
    @test [a["origin"] for a in W.movable_structure_data(dm)["attachments"]]==[a["origin"] for a in W.movable_structure_data(m)["attachments"]]
    @test W.weights_payload(dm)["totals"]["structure_mass_kg"]≈W.weights_payload(m)["totals"]["structure_mass_kg"] rtol=1e-10
    bad=deepcopy(p);bad["movable_structure.attachments"][1]["eta"]=.74;@test_throws ArgumentError build(bad) # both requests snap to one rib
    stale=deepcopy(p);stale["movable_structure.attachments"][1]["rib"]=99
    @test W.movable_structure_data(build(stale))["attachments"][1]["rib"]==2
    bad=deepcopy(p);bad["movable_structure.surfaces"][1]["skin_material"]=99;@test_throws ArgumentError build(bad)
    bad=deepcopy(p);empty!(bad["movable_structure.attachments"]);@test_throws ArgumentError build(bad)
    bad=deepcopy(p);bad["mass.structural_representation"]="bay_concentrated";@test_throws ArgumentError build(bad)
    bad=deepcopy(p);bad["movable_surfaces.items"][1]["hinge_start"]=.3;@test_throws ArgumentError build(bad)
    slat=deepcopy(p);s=slat["movable_surfaces.items"][1];s["edge"]="leading";s["hinge_start"]=s["hinge_end"]=.15
    for a in slat["movable_structure.attachments"];a["spar"]="front";end
    @test W.all_checks_pass(build(slat))
    q=deepcopy(p);q["movable_structure.surfaces"][1]["skin_material"]=2;steel=build(q)
    @test W.shell_material_definition(steel.params,first(movable).pid)["material_id"]==2
    for (name,kind,kh) in (("soft_hinge","hinge",1e3),("restrained_hinge","hinge",1e5),("rigid","rigid",1e4))
        q=deepcopy(p);for a in q["movable_structure.attachments"];a["kind"]=kind;a["hinge_stiffness"]=kh;end
        model=build(q);path,parsed=deck(model,name;tipload=true)
        @test length(parsed["RBE3s"])==length(model.rbe3)+2+length(W.movable_structure_data(model)["load_references"])
        @test length(parsed["RBE2s"])==(kind=="rigid" ? 4 : 2)
        @test length(parsed["CBUSHs"])==(kind=="rigid" ? 0 : 2)
        if kind=="hinge"
            @test all(prop->prop["K"][4]==kh,values(parsed["PBUSHs"]))
        end
        forward=N.solve_model(parsed)
        nodes=only(W.movable_structure_data(model)["surfaces"])["nodes"];tip=nodes[argmax([model.xyz[3n-1]+model.xyz[3n-2]/100 for n in nodes])]
        response=W.sensitivity_response(forward,model,Dict("type"=>"displacement","node_id"=>model.node_ids[tip],"component"=>"z"))
        @test isfinite(response.value)&&response.value>0
        q["output.solution"]="103";modal=build(q);modalpath,modalinput=deck(modal,name*"_modal")
        modes=N.solve_model(modalinput)
        eigen=W.sensitivity_response(modes,modal,Dict("type"=>"frequency_eigenvalue","mode"=>1))
        @test isfinite(eigen.value)&&eigen.value>0
        push!(reports,Dict("name"=>name,"static_displacement_m"=>response.value,"first_modal_eigenvalue"=>eigen.value,"deck"=>path,"modal_deck"=>modalpath))
    end
    @test reports[1]["static_displacement_m"]>reports[2]["static_displacement_m"]>reports[3]["static_displacement_m"]
    @test reports[1]["first_modal_eigenvalue"]<reports[2]["first_modal_eigenvalue"]
end
counts=Test.get_test_counts(tests);write(joinpath(out,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"analyses"=>reports)))
