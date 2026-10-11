using Test,JSON,TOML
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
row(key,pairs...)=Dict{String,Any}("key"=>key,pairs...)
p=merge(W.default_params(),Dict{String,Any}("planform.area"=>4.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>1.,
    "planform.sweep"=>0.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.12,"box.end_eta"=>.9,
    "mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>41,
    "leading_edge.enabled"=>true,"leading_edge.chord_elements"=>3,"fuel.enabled"=>false,"loads.method"=>"analytic",
    "properties.ribs"=>[Dict("rib"=>2,"thickness"=>.003,"height"=>.038)],
    "properties.spar_bays"=>[Dict("bay"=>1,"front_thickness"=>.004)]))
tests=@testset "Physical component table cards and persistence" begin
    baseline=W.build_model(p)
    p["properties.components"]=[row("front_web:1","thickness"=>.006,"material"=>2),row("rear_web:2","material"=>2),
        row("front_upper_cap:1","side"=>.025,"material"=>2),row("rear_lower_cap:2","side"=>.023),
        row("rib_web:2","material"=>2),row("rib_stiffener:2","height"=>.044,"material"=>2),
        row("leading_upper_skin:1","kind"=>"sandwich","face_material"=>2,"core_material"=>3,"face_thickness"=>.0006,"core_thickness"=>.008),
        row("leading_lower_skin:1","thickness"=>.004),row("leading_rib:2","thickness"=>.005,"material"=>2)]
    normalized,unknown=W.normalize_params(p);@test isempty(unknown)
    m=W.build_model(normalized);@test m.xyz==baseline.xyz;@test W.all_checks_pass(m)
    defs=Dict(d["pid"]=>d for d in W.model_property_definitions(m))
    pid(part,index)=W.component_table_family(part)*W.COMPONENT_PID_STRIDE+index
    @test defs[pid("front_web",1)]["thickness_m"]==.006
    @test defs[pid("front_web",1)]["material_id"]==2
    @test defs[pid("rib_web",2)]["thickness_m"]==.003 # legacy override is still inherited
    @test defs[pid("rib_web",2)]["material_id"]==2
    @test defs[pid("rib_stiffener",2)]["section"]["dimensions_m"][2]==.044
    @test defs[pid("rib_stiffener",2)]["material_id"]==2
    @test defs[pid("front_upper_cap",1)]["section"]["area_m2"]≈.025^2
    @test defs[pid("front_upper_cap",1)]["material_id"]==2
    @test defs[pid("leading_upper_skin",1)]["type"]=="PCOMP"
    @test defs[pid("leading_upper_skin",1)]["thickness_m"]≈.0092
    @test defs[pid("leading_lower_skin",1)]["thickness_m"]==.004
    @test defs[pid("leading_rib",2)]["thickness_m"]==.005
    @test W.weights_payload(m)["totals"]["structure_mass_kg"]>W.weights_payload(baseline)["totals"]["structure_mass_kg"]
    # Every generated override is scoped to its physical bay or rib.
    for g in m.groups
        part=W.component_table_part(g.pid);part===nothing&&continue
        index=g.pid%W.COMPONENT_PID_STRIDE;nn=g.kind===:bar ? 2 : g.kind===:tria ? 3 : 4
        for e in eachindex(g.eids)
            js=[m.node_keys[id][2] for id in g.conn[nn*(e-1)+1:nn*e]]
            @test W.component_table_isrib(part) ? all(==(m.grid.ribs[index]),js) : minimum(js)>=m.grid.ribs[index]&&maximum(js)<=m.grid.ribs[index+1]
        end
    end
    toml=W.params_to_toml(normalized);write(joinpath(out,"components.toml"),toml)
    rt,unknown=W.normalize_params(W.flatten_toml(TOML.parse(toml)));@test isempty(unknown);@test rt["properties.components"]==normalized["properties.components"]
    jr,unknown=W.normalize_params(JSON.parse(JSON.json(normalized)));@test isempty(unknown);@test jr["properties.components"]==normalized["properties.components"]
    @test W.model_property_definitions(W.build_model(rt))==W.model_property_definitions(m)
    text=sprint(io->W.write_deck(IOContext(io,:full_precision=>true),m));write(joinpath(out,"components.bdf"),text)
    @test occursin("PBARL",text)&&occursin("PCOMP",text)&&occursin("PSHELL",text)
    vars=W.sensitivity_catalog(m)["variables"]
    cap=only(filter(v->v["id"]=="properties.components#front_upper_cap:1#side",vars))
    @test cap["pids"]==[pid("front_upper_cap",1)]
    shared=only(filter(v->v["id"]=="properties.spar_cap_side",vars));@test !(pid("front_upper_cap",1) in shared["pids"])
    @test pid("front_web",1) in only(filter(v->v["id"]=="properties.components#front_web:1#thickness",vars))["pids"]
    for bad in ([row("front_web:0","thickness"=>.004)],[row("rib_web:2","thickness"=>-.004)],[row("rib_web:2","unknown"=>1.)],[row("front_web:1","material"=>1.2)])
        @test_throws ArgumentError W.normalize_component_table_properties(bad)
    end
    @test_throws ArgumentError W.normalize_params(merge(p,Dict("properties.components"=>[row("front_web:999","thickness"=>.002)])))
    @test_throws ArgumentError W.normalize_params(merge(p,Dict("properties.components"=>[row("rib_stiffener:1","height"=>.001)])))
    write(joinpath(out,"params.json"),JSON.json(normalized));write(joinpath(out,"schema.json"),JSON.json(W.schema_payload(normalized,"components.toml")))
    write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
end
counts=Test.get_test_counts(tests);write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
