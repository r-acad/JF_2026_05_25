using Test, TOML, WingFEGen, OpenJFEM
const W=WingFEGen
function hinge_parameters()
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.rib_pitch"=>.25,"box.stringer_pitch"=>.2,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "output.solution"=>"101","output.n_modes"=>6))
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.1,"eta_end"=>.9,
        "hinge_start"=>.7,"hinge_end"=>.7,"front_spar_start"=>.75,"front_spar_end"=>.75,"deflection"=>20.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap","span_bays"=>2,"span_elements"=>1,"chord_elements"=>2,"height_elements"=>2,"end_eta"=>.8))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap","eta"=>eta,"rib"=>rib,
        "fitting"=>"shell_lugs","actuator"=>true,"box_lateral_stay"=>false,"movable_lateral_stay"=>false)) for (eta,rib) in ((.25,2),(.75,4))]
    first(W.normalize_params(p))
end
@testset "Separate control spar, true hinge and physical lugs" begin
    p=hinge_parameters();m=W.build_model(p);@test W.all_checks_pass(m);d=W.movable_structure_data(m);surface=only(d["surfaces"])
    @test surface["structural_eta_end"]==.8
    @test surface["aerodynamic_eta_end"]==.9
    @test all(r->.1<=r["eta"]<=.8,surface["rib_sections"])
    @test all(a->a["eta"] in surface["rib_etas"],d["attachments"])
    @test all(a->isapprox(a["origin"][1],.45;atol=1e-12),d["attachments"])
    @test all(r->isapprox(m.xyz[3r["front_upper"]-2],.5;atol=1e-12),surface["rib_sections"])
    @test length(W.movable_coordinate_records(m))==3 # hinge plus one axial frame per actuator
    @test only(filter(r->r["id"]==first(d["attachments"])["cid"],W.movable_coordinate_records(m)))["x"]==[0.,1.,0.]
    lugs=filter(g->startswith(g.name,"MOVABLE_HINGE_LUGS"),m.groups)
    @test length(lugs)==2
    @test sum(length(g.eids) for g in lugs)==8
    @test all(g->W.movable_shell_property(p,g.pid)["thickness_m"]==.003,lugs)
    @test all(g->W.property_minimum_gauge(p,g.pid)["at_minimum"],lugs)
    @test all(g->all(isfinite,Iterators.flatten(W.shell_material_frame(m,g,1))),lugs)
    @test all(a->!haskey(a,"lateral_links")&&!haskey(a,"lateral_stay"),d["attachments"])
    @test !any(c->occursin("LATERAL_STAYS",c["name"]),W.movable_connection_payload(m))
    @test all(r->!(r["ref"] in r["nodes"]),d["load_references"])
    @test all(r->length(r["nodes"])>=4,d["load_references"])
    @test isfinite(W.weights_payload(m)["totals"]["structure_mass_kg"])
    @test length(W.mesh_payload(m)["movable_structure"]["load_references"])==length(d["load_references"])
    restored,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p))))
    @test W.build_model(restored).xyz==m.xyz
    q=deepcopy(p);q["movable_structure.surfaces"][1]["end_eta"]=.95;@test_throws ArgumentError W.build_model(q)
    q=deepcopy(p);q["movable_surfaces.items"][1]["hinge_start"]=q["movable_surfaces.items"][1]["hinge_end"]=.75
    # A hinge exactly on a spar GRID reuses that GRID and omits collapsed
    # triangles; no coincident free node or zero-area shell is introduced.
    qm=W.build_model(q)
    @test all(a->a["surface_ref"] in a["surface_nodes"],qm.movable_structure["attachments"])
    q=deepcopy(p);q["movable_structure.attachments"][2]["rib"]=2
    @test W.movable_structure_data(W.build_model(q))["attachments"][2]["rib"]==4 # eta overrides a stale manual rib
    q=deepcopy(p);q["movable_structure.surfaces"][1]["mesh_deflected"]=true;rotated=W.build_model(q)
    @test all(a->a["origin"]==d["attachments"][1]["origin"],W.movable_structure_data(rotated)["attachments"][1:1])
    @test isapprox(W.weights_payload(rotated)["totals"]["structure_mass_kg"],W.weights_payload(m)["totals"]["structure_mass_kg"];rtol=1e-10)
end

@testset "Relative hinge deck: local axes and actuator selection" begin
    p=hinge_parameters();p["movable_structure.attachments"][2]["actuator"]=false
    m=W.build_model(p);data=W.movable_structure_data(m)
    path=joinpath(mktempdir(),"physical_hinges.bdf");W.write_reference(m,path;large_field=true)
    deck=OpenJFEM.bdf_to_model(path)
    grids=Dict(Int(g["ID"])=>g for g in values(deck["GRIDs"]))
    rigid=Dict(Int(g["ID"])=>g for g in values(deck["RBE2s"]))
    for a in data["attachments"]
        @test grids[m.node_ids[a["box_ref"]]]["CD"]==a["cid"]
        @test grids[m.node_ids[a["surface_ref"]]]["CD"]==a["cid"]
        @test rigid[a["joint_eid"]]["CM"]==12356
        @test rigid[a["joint_eid"]]["GN"]==m.node_ids[a["box_ref"]]
        @test rigid[a["joint_eid"]]["GM"]==[m.node_ids[a["surface_ref"]]]

    end
    @test length(deck["RBE2s"])==length(data["attachments"])
    @test length(deck["CBUSHs"])==1
    @test only(values(deck["PBUSHs"]))["K"]==[1e7,0.,0.,0.,0.,0.]
    @test only(filter(r->r["id"]==first(data["attachments"])["cid"],W.movable_coordinate_records(m)))["usage"]["grid_cd"]==4
    dependent=[(Int(n),c) for r in values(deck["RBE2s"]) for n in r["GM"] for c in string(r["CM"])]
    @test length(unique(dependent))==length(dependent)
    # Optional display-only aero shells must not reuse connection/actuator IDs.
    p["output.include_aero_shells"]=true;overlay=W.build_model(p)
    path=joinpath(mktempdir(),"hinges_with_aero.bdf");W.write_reference(overlay,path)
    parsed=OpenJFEM.bdf_to_model(path)
    types=("CSHELLs","CBARs","CBEAMs","RBE2s","RBE3s","CBUSHs","CONM2s")
    ids=[Int(e["ID"]) for kind in types for e in values(get(parsed,kind,Dict()))]
    expected=vcat([id for g in overlay.groups for id in g.eids],[r.eid for r in overlay.rbe3],
        [e["eid"] for group in W.movable_connection_payload(overlay) for e in group["elements"]])
    @test length(unique(ids))==length(ids)
    @test all(in(Set(ids)),expected)
    @test length(ids)==length(expected)+div(length(overlay.aero_quads),4)

end

@testset "Physical torque arm and free-hinge run preflight" begin
    p=hinge_parameters()
    q=deepcopy(p)
    @test W.all_checks_pass(W.build_model(q)) # cap-to-cap actuator has a physical torque arm without a stay
    q["movable_structure.attachments"][1]["kind"]="rigid";q["movable_structure.attachments"][1]["actuator"]=false
    @test W.all_checks_pass(W.build_model(q))
    free=deepcopy(p)
    for a in free["movable_structure.attachments"];a["actuator"]=false;end
    m=W.build_model(free);@test W.all_checks_pass(m)
    for solution in ("101","105","106");@test_throws ArgumentError W.validate_movable_run(free;solution);end
    @test W.validate_movable_run(free;solution="103")===nothing
    # Job and sensitivity entry points must fail before allocating output or a worker.
    work=mktempdir();outdir=joinpath(work,"must_not_be_created")
    m.params["jfem.output_dir"]=outdir
    error=try W.prepare_jfem_job(m,m.params,work,joinpath(work,"missing.bdf"),"free_hinge";outdir);nothing catch e;e end
    @test error isa ArgumentError
    @test occursin("unrestrained movable-surface hinge",sprint(showerror,error))
    @test !ispath(outdir)
    request=Dict{String,Any}("case_id"=>1,"solution"=>"101","variables"=>["material.E"],
        "objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z"))
    worker_created=Ref(false)
    factory=(args...;kwargs...)->(worker_created[]=true;error("A rejected free-hinge job must not create a worker"))
    error=try W.start_sensitivity_job(m,request,work,"free_hinge";worker_factory=factory);nothing catch e;e end
    @test error isa ArgumentError
    @test occursin("unrestrained movable-surface hinge",sprint(showerror,error))
    @test !worker_created[]
    @test !ispath(outdir)
    modal=merge(request,Dict("solution"=>"103","objective"=>Dict("type"=>"frequency_eigenvalue","mode"=>1)))
    @test W.sensitivity_request(m,modal)["solution"]=="103"
    path=joinpath(mktempdir(),"free_hinge_for_external_analysis.bdf")
    @test W.write_reference(m,path)!==nothing
    @test isfile(path)
    free["movable_structure.attachments"][1]["hinge_stiffness"]=0.
    free["movable_structure.attachments"][1]["actuator"]=true
    @test W.all_checks_pass(W.build_model(free))
    free["movable_structure.attachments"][1]["fitting"]="idealized"
    free["movable_structure.attachments"][1]["hinge_stiffness"]=1e4
    @test W.validate_movable_run(free;solution="101")===nothing
end
