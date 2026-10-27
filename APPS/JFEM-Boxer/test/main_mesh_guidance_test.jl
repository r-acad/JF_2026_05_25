using Test, WingFEGen
const W=WingFEGen
function guidance_parameters()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.14,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>21,
        "leading_edge.enabled"=>false,"fuel.enabled"=>false,"loads.cases"=>Any[],
        "loads.structure_inertia"=>false))
end
captured_mesh_error(p)=try W.build_model(p);nothing catch e;e end

@testset "Physical guidance accompanies short-feature skin and spar patches" begin
    p=guidance_parameters();m=W.build_model(p)
    @test W.all_checks_pass(m)
    @test isempty(W.main_mesh_quality_issues((;xyz=m.xyz,keys=m.node_keys),m.grid,m.params,m.groups))
    for key in ("box.front_spar_points","box.rear_spar_points")
        p[key]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.5005,"dxc"=>.02),Dict("eta"=>1.,"dxc"=>0.)]
    end
    snapshot=deepcopy(p);warning_model=W.build_model(p);quality=warning_model.mesh_quality
    @test quality["status"]=="warning"
    @test quality["analysis_allowed"]
    issues=quality["issues"]
    @test p==snapshot
    @test any(i->occursin("skin",lowercase(i["component"])),issues)
    @test any(i->occursin("spar",lowercase(i["component"])),issues)
    @test sum(i["count"] for i in issues)>1
    @test all(i->i["rib_start"]==2&&i["rib_end"]==3,issues)
    @test all(i->!isempty(i["element_ids"]),issues)
    text=quality["message"]
    for expected in ("R2-R3","spar point 2","0.5005","0.500 mm","Structure / Spars","Structure / Ribs","elements between stringers","spar-height elements")
        @test occursin(expected,text)
    end
    @test all(i->i["severity"]=="warning",issues)
    @test length(unique(a["id"] for a in quality["actions"]))==length(quality["actions"])
    @test any(c->c["nearest_rib"]==2&&c["rib_eta"]==.5,Iterators.flatten(i["nearby_controls"] for i in issues))
    # An explicit user-level alignment removes the short geometric feature;
    # it is never done automatically by the generator.
    aligned=deepcopy(p)
    for key in ("box.front_spar_points","box.rear_spar_points");aligned[key][2]["eta"]=.5;end
    corrected=W.build_model(aligned)
    @test W.all_checks_pass(corrected)
    @test p==snapshot
    @test isempty(W.main_mesh_quality_issues((;xyz=corrected.xyz,keys=corrected.node_keys),corrected.grid,corrected.params,corrected.groups))
end

@testset "Quality metrics include obtuse, inverted and collapsed faces" begin
    reg=(;xyz=[0.,0.,0.,1.,0.,0.,1.,1.,0.,0.,1.,0.])
    square=W.main_shell_quality(reg,[1,2,3,4])
    @test square.valid&&square.minimum_angle==90&&square.maximum_angle==90&&square.edge_ratio==1
    @test !W.main_shell_quality(reg,[1,3,2,4]).valid
    collapsed=(;xyz=[0.,0.,0.,1.,0.,0.,2.,0.,0.])
    @test !W.main_shell_quality(collapsed,[1,2,3]).valid
    slender=(;xyz=[0.,0.,0.,1.,0.,0.,0.,.05,0.])
    metric=W.main_shell_quality(slender,[1,2,3])
    @test metric.minimum_angle<10&&metric.edge_ratio>15
    obtuse=(;xyz=[0.,0.,0.,1.,0.,0.,1.99,.1,0.,0.,1.,0.])
    @test W.main_shell_quality(obtuse,[1,2,3,4]).maximum_angle>170
end

@testset "Close whole-loft stations remain exact and warn without blocking" begin
    @test parse(Float64,W.mesh_eta_label(.4185798815789473))==.4185798815789473
    p=guidance_parameters()
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.500000001,"twist"=>1.),Dict("eta"=>1.,"twist"=>0.)]
    model=W.build_model(p)
    @test .500000001 in model.grid.etas
    @test .5 in model.grid.etas
    @test model.mesh_quality["status"]=="warning"
    @test occursin("Twist station 2",model.mesh_quality["message"])
    @test all(i->!i["inverted_or_collapsed"],model.mesh_quality["issues"])
end

@testset "Invalid shell topology remains fatal" begin
    p=guidance_parameters();m=W.build_model(p);groups=deepcopy(m.groups)
    group=first(filter(g->g.kind===:quad&&W.component_base_pid(g.pid)==W.PID_SKIN_UPPER,groups))
    group.conn[2],group.conn[3]=group.conn[3],group.conn[2]
    failure=try W.validate_main_mesh_quality((;xyz=m.xyz,keys=m.node_keys),m.grid,p,groups);nothing catch e;e end
    @test failure isa W.MeshQualityError
    @test any(i->i["severity"]=="error"&&i["inverted_or_collapsed"],failure.issues)
    @test occursin("Mesh generation stopped",sprint(showerror,failure))
    @test m.mesh_quality["status"]=="ok"
end

@testset "Quality responses distinguish invalid geometry from usable warnings" begin
    error=W.MeshQualityError("Collapsed face",[Dict{String,Any}("ratio"=>Inf,
        "nested"=>Dict("angles"=>[NaN,-Inf,25.]))])
    response=W.mesh_quality_error_response(error)
    body=W.JSON.parse(String(response.body))
    @test response.status==422
    @test body["code"]=="mesh_quality"
    @test body["issues"][1]["ratio"]===nothing
    @test body["issues"][1]["nested"]["angles"]==[nothing,nothing,25.]
    p=guidance_parameters();m=W.build_model(p)
    app=dirname(dirname(pathof(W)))
    mktempdir() do temporary
        state=W.AppState(app,joinpath(app,"examples","wing_default.toml");deck_store_dir=temporary)
        state.model=m;state.params=copy(p);previous=state.params
        invalid=deepcopy(p)
        invalid["box.rear_spar_points"]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.5005,"dxc"=>.02),Dict("eta"=>1.,"dxc"=>0.)]
        request=W.HTTP.Request("POST","/api/generate",["Content-Type"=>"application/json"],W.JSON.json(invalid))
        failure=W.handle_generate(state,request)
        @test failure.status==200
        @test state.model!==m
        @test state.model.mesh_quality["status"]=="warning"
        @test state.model.mesh_quality["analysis_allowed"]
        @test previous==p
    end
end
