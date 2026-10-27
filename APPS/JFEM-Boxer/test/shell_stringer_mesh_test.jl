using Test, LinearAlgebra, JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

function small_shell_params()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_stringer_height"=>2,"fuel.enabled"=>false,
        "loads.cases"=>Any[],"stringers.model"=>"shell"))
end

function footprint_check(m)
    skinsets=Set(Tuple(sort(group.conn[n*(e-1)+1:n*e])) for group in m.groups
        if group.kind in (:quad,:tria)&&W.component_base_pid(group.pid) in (W.PID_SKIN_UPPER,W.PID_SKIN_LOWER)
        for n in (group.kind===:quad ? 4 : 3,) for e in eachindex(group.eids))
    for group in m.groups
        W.component_base_pid(group.pid)==W.PID_STRINGER_FLANGE||continue
        n=group.kind===:quad ? 4 : 3
        for e in eachindex(group.eids)
            @test !(Tuple(sort(group.conn[n*(e-1)+1:n*e])) in skinsets)
        end
    end
end

suite=@testset "Conforming shell stringer mesh" begin
    p=small_shell_params();m=W.build_model(p)
    @test W.all_checks_pass(m)
    @test all(g.kind!==:bar||W.component_base_pid(g.pid)!=W.PID_STRINGER for g in m.groups)
    @test any(W.component_base_pid(g.pid)==W.PID_STRINGER_WEB for g in m.groups)
    @test any(W.component_base_pid(g.pid)==W.PID_STRINGER_FLANGE for g in m.groups)
    footprint_check(m)
    # Every shell blade rail is the requested inward extrusion; skin base
    # nodes are shared, and no blade interior node enters a rigid spider.
    interior=Set(n for group in m.groups if W.component_base_pid(group.pid)==W.PID_STRINGER_WEB
        for n in group.conn if m.node_keys[n][3]<0)
    @test isempty(intersect(interior,Set(n for spider in m.rbe3 for n in spider.dep)))
    depth=p["properties.stringer_height"]-p["properties.stringer_flange_thickness"]
    for node in interior
        i,j,_=m.node_keys[node];point=Tuple(m.xyz[3node-2:3node])
        distances=[norm(collect(point.-W.grid_point(m.grid,i,j,k))) for k in (0,m.grid.nh)]
        @test any(isapprox(minimum(distances),depth*q/2;atol=1e-10) for q in 1:2)
    end
    blade=W.build_model(merge(p,Dict("properties.stringer_flange_width"=>0.,"mesh.elements_stringer_height"=>3)))
    @test W.all_checks_pass(blade)
    @test !any(W.component_base_pid(g.pid)==W.PID_STRINGER_FLANGE for g in blade.groups)
    @test sum(length(g.eids) for g in blade.groups if W.component_base_pid(g.pid)==W.PID_STRINGER_WEB)==
        3sum(length(g.eids) for g in m.groups if W.component_base_pid(g.pid)==W.PID_STRINGER_WEB)÷2
    footprint_check(blade)
    vertical=W.build_model(merge(p,Dict("stringers.orientation"=>"coordinate_axis","stringers.axis"=>"z","stringers.axis_cid"=>0)))
    @test W.all_checks_pass(vertical)
    skin=first(filter(g->W.component_base_pid(g.pid)==W.PID_SKIN_UPPER,m.groups))
    _,_,axis=W.shell_material_frame(m,skin,1)
    localaxis=W.build_model(merge(p,Dict("stringers.orientation"=>"coordinate_axis","stringers.axis"=>"z","stringers.axis_cid"=>first(skin.eids))))
    @test W.all_checks_pass(localaxis)
    for group in localaxis.groups
        W.component_base_pid(group.pid)==W.PID_STRINGER_WEB||continue
        for e in eachindex(group.eids)
            points=W.element_points(localaxis,group,e)
            @test norm(collect(W.cross3(points[4].-points[1],axis)))<1e-12
        end
    end
    @test_throws ArgumentError W.build_model(merge(p,Dict("stringers.orientation"=>"coordinate_axis","stringers.axis"=>"y","stringers.axis_cid"=>0)))
    # This flanged runout leaves valid 2.9-degree skin wedges and must warn.
    # Retain valid retiring-line/connector coverage with the explicitly
    # blade-only variant, which does not introduce those narrow flange strips.
    taper_params=merge(p,Dict("planform.area"=>8.,"planform.aspect_ratio"=>4.,
        "planform.taper_ratio"=>.4,"planform.sweep"=>12.,"planform.twist_tip"=>-2.,"box.rib_pitch"=>.6))
    @test W.build_model(taper_params).mesh_quality["status"]=="warning"
    tapered=W.build_model(merge(taper_params,Dict("properties.stringer_flange_width"=>0.)))
    @test W.all_checks_pass(tapered)
    @test any(!isempty(g.eids)&&g.pid==W.PID_STRINGER_RUNOUT for g in tapered.groups)
    footprint_check(tapered)
    angled=W.build_model(merge(p,Dict("ribs.masters"=>[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>85.,"pitch"=>.25)])))
    @test W.all_checks_pass(angled)
    footprint_check(angled)
    kinked=W.build_model(merge(p,Dict("ribs.masters"=>[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>85.,"pitch"=>.25)],
        "box.front_spar_points"=>[Dict("eta"=>.35,"dxc"=>.015)],"nonstructural.stringer"=>.37)))
    @test W.all_checks_pass(kinked)
    footprint_check(kinked)
    @test !isempty(W.physical_annotations(kinked)["stringers"])
    @test W.weights_payload(kinked)["totals"]["nonstructural_mass_kg"]≈.37sum(row["stringer_length_m"] for row in W.stiffened_panels_payload(kinked)["panels"]) rtol=1e-12
    kink_axis=W.build_model(merge(kinked.params,Dict("stringers.orientation"=>"coordinate_axis","stringers.axis"=>"z","stringers.axis_cid"=>0)))
    @test W.all_checks_pass(kink_axis)
    for (node,base) in kink_axis.grid.shell_columns.blade_bases
        delta=Tuple(kink_axis.xyz[3node-2:3node]).-base
        @test hypot(delta[1],delta[2])<1e-12
    end
    kink_skins=[g for g in kinked.groups if g.kind===:tria&&W.component_base_pid(g.pid)==W.PID_SKIN_UPPER]
    kink_cids=sort!([id for group in kink_skins for id in group.eids])
    for cid in (first(kink_cids),last(kink_cids))
        selected=W.build_model(merge(kinked.params,Dict("stringers.orientation"=>"coordinate_axis","stringers.axis"=>"z","stringers.axis_cid"=>cid)))
        @test W.all_checks_pass(selected)
        source=only(filter(group->cid in group.eids,selected.groups));element=findfirst(==(cid),source.eids)
        _,_,exported_axis=W.shell_material_frame(selected,source,element)
        for (node,base) in selected.grid.shell_columns.blade_bases
            delta=Tuple(selected.xyz[3node-2:3node]).-base
            @test norm(collect(W.cross3(delta,exported_axis)))<1e-12
        end
    end
    @test_throws ArgumentError W.build_model(merge(p,Dict("properties.stringer_flange_width"=>.3)))
    # Changing bay dimensions uses a common union of footprint and blade
    # height nodes, retaining the physical panel token and exact dimensions.
    panels=W.stiffened_panels_payload(m);row=first(panels["panels"])
    override=Dict("key"=>row["key"],"layout_token"=>panels["layout_token"],
        "stringer"=>Dict("flange_width"=>.045,"height"=>.045))
    stepped_params=merge(p,Dict("properties.panels"=>[override]))
    @test W.build_model(stepped_params).mesh_quality["status"]=="warning" # 33:1 strips at the width transition
    stepped=W.build_model(merge(stepped_params,Dict("mesh.elements_between_ribs"=>6)))
    @test W.all_checks_pass(stepped)
    footprint_check(stepped)
    @test W.stiffened_panels_payload(stepped)["layout_token"]==panels["layout_token"]
    if !isempty(ARGS)
        for (name,model) in (("shell",m),("blade",blade))
            directory=joinpath(ARGS[1],"frontend",name);mkpath(directory)
            write(joinpath(directory,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(model)))
            write(joinpath(directory,"schema.json"),JSON.json(W.schema_payload(model.params,"shell_stringer_fixture.toml")))
            write(joinpath(directory,"params.json"),JSON.json(model.params))
        end
    end
end

if !isempty(ARGS)
    mkpath(ARGS[1])
    counts=Test.get_test_counts(suite)
    open(joinpath(ARGS[1],"shell_stringer_mesh_summary.json"),"w") do io
        JSON.print(io,Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes),2)
    end
end
