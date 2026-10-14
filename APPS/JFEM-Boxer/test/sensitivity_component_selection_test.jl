using Test, JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
function selection_parameters()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.15,
        "mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "leading_edge.enabled"=>true,"leading_edge.chord_elements"=>2,
        "loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[]))
end
localid(part,index,field)="properties.components#$part:$index#$field"
request_for(m,ids)=Dict("case_id"=>1,"variables"=>ids,
    "objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z"))
tests=@testset "Component family selections become independent physical variables" begin
    p=selection_parameters();before=deepcopy(p);m=W.build_model(p);c=W.sensitivity_catalog(m)
    locals=filter(d->haskey(d,"component_key"),c["variables"])
    nr=length(m.grid.ribs);@test nr>=3
    selected_aliases=["properties.t_spar_web","properties.t_rib_web","properties.spar_cap_side",
        "leading_edge.t_skin","leading_edge.t_rib",["properties.rib_stiffener_"*f for f in W.RIB_STIFFENER_FIELDS]...]
    expected=Set(d["id"] for d in locals)
    @test Set(W.sensitivity_expand_selection(c,selected_aliases))==expected
    @test all(d->length(d["pids"])==1,locals)
    @test Set(c["selection_replacements"]["properties.t_spar_web"])==Set(localid(part,i,"thickness") for part in ("front_web","rear_web") for i in 1:nr-1)
    @test Set(c["selection_replacements"]["properties.spar_cap_side"])==Set(localid(part,i,"side") for part in W.COMPONENT_TABLE_PARTS if W.component_table_iscap(part) for i in 1:nr-1)
    @test Set(c["selection_replacements"]["properties.t_rib_web"])==Set(localid("rib_web",i,"thickness") for i in 1:nr)
    for (id,targets) in c["selection_replacements"]
        @test !isempty(targets)&&length(unique(targets))==length(targets)
        @test all(target->target in expected,targets)
        @test haskey(c["selection_aliases"],id)
    end
    panel=first(d["id"] for d in c["variables"] if haskey(d,"panel_key"))
    unchanged=["material.E","material.rho","properties.t_skin_upper",panel]
    raw=request_for(m,vcat(selected_aliases,unchanged,[first(locals)["id"]]));raw_before=deepcopy(raw)
    effective=W.sensitivity_request(m,raw)
    @test Set(effective["variables"])==union(expected,Set(unchanged))
    @test length(effective["variables"])==length(expected)+length(unchanged)
    @test W.sensitivity_request(m,effective)==effective
    @test raw==raw_before&&p==before
    @test all(!haskey(c["selection_replacements"],id) for id in unchanged)
    @test_throws ArgumentError W.sensitivity_request(m,request_for(m,[selected_aliases[1],selected_aliases[1]]))
    @test_throws ArgumentError W.sensitivity_request(m,request_for(m,[localid("front_web",nr+1,"thickness")]))
    # Families still include dimensions after every property overrides its default.
    detached=deepcopy(p)
    for d in locals;W.sensitivity_set!(detached,d,1.05*d["value"]);end
    dm=W.build_model(detached);dc=W.sensitivity_catalog(dm)
    @test dm.xyz==m.xyz
    @test [(g.pid,g.eids,g.conn) for g in dm.groups]==[(g.pid,g.eids,g.conn) for g in m.groups]
    @test all(!d["inherited"] for d in dc["variables"] if haskey(d,"component_key"))
    @test !any(d->d["id"]=="properties.t_spar_web",dc["variables"])
    @test Set(W.sensitivity_request(dm,request_for(dm,selected_aliases))["variables"])==expected
    # Sparse legacy dimensions refer to precisely one physical location.
    legacy=deepcopy(p)
    legacy["properties.ribs"]=[Dict("rib"=>2,"thickness"=>.018,"height"=>.021)]
    legacy["properties.spar_bays"]=[Dict("bay"=>1,"front_thickness"=>.020,"rear_thickness"=>.019)]
    lm=W.build_model(legacy);lc=W.sensitivity_catalog(lm)
    for (alias,target) in (("properties.ribs#2#thickness",localid("rib_web",2,"thickness")),
        ("properties.ribs#2#height",localid("rib_stiffener",2,"height")),
        ("properties.spar_bays#1#front_thickness",localid("front_web",1,"thickness")),
        ("properties.spar_bays#1#rear_thickness",localid("rear_web",1,"thickness")))
        @test lc["selection_replacements"][alias]==[target]
        @test W.sensitivity_request(lm,request_for(lm,[alias]))["variables"]==[target]
    end
    # Fully sandwich component families: total thickness means core at fixed faces.
    sp=deepcopy(legacy)
    for row in sp["materials.shells"];row["kind"]="sandwich";end
    sm=W.build_model(sp);sc=W.sensitivity_catalog(sm)
    for (alias,parts) in (("properties.t_spar_web",("front_web","rear_web")),
        ("properties.t_rib_web",("rib_web",)),("leading_edge.t_skin",("leading_upper_skin","leading_lower_skin")),
        ("leading_edge.t_rib",("leading_rib",)))
        @test Set(sc["selection_replacements"][alias])==Set(localid(part,i,"core_thickness") for part in parts for i in 1:(W.component_table_isrib(part) ? nr : nr-1))
        @test occursin("fixed face",sc["selection_aliases"][alias]["note"])
    end
    @test sc["selection_replacements"]["properties.ribs#2#thickness"]==[localid("rib_web",2,"core_thickness")]
    @test occursin("fixed face",sc["selection_aliases"]["properties.ribs#2#thickness"]["note"])
    for field in ("face_thickness","core_thickness")
        @test Set(sc["selection_replacements"]["materials.shells#spar_web#$field"])==Set(localid(part,i,field) for part in ("front_web","rear_web") for i in 1:nr-1)
        @test !haskey(sc["selection_replacements"],"materials.shells#upper_skin#$field")
    end
    # One sandwich override in an otherwise monolithic family must not leave a bay out.
    mixed=deepcopy(p);mixed["properties.components"]=[Dict("key"=>"front_web:1","kind"=>"sandwich","core_thickness"=>.008)]
    mm=W.build_model(mixed);mc=W.sensitivity_catalog(mm)
    mixed_ids=Set(localid(part,i,part=="front_web"&&i==1 ? "core_thickness" : "thickness") for part in ("front_web","rear_web") for i in 1:nr-1)
    @test Set(mc["selection_replacements"]["properties.t_spar_web"])==mixed_ids
    @test Set(W.sensitivity_request(mm,request_for(mm,["properties.t_spar_web"]))["variables"])==mixed_ids
    @test localid("front_web",1,"face_thickness") in mc["selection_replacements"]["materials.shells#spar_web#face_thickness"]
    inactive=merge(deepcopy(p),Dict("leading_edge.enabled"=>false,"properties.rib_stiffeners_enabled"=>false))
    ic=W.sensitivity_catalog(W.build_model(inactive))
    @test all(!startswith(id,"leading_edge.")&&!startswith(id,"properties.rib_stiffener_") for id in keys(ic["selection_replacements"]))
    @test W.sensitivity_expand_selection(Dict(),["imported.foo","material.E"])==["imported.foo","material.E"]
    @test_throws ArgumentError W.sensitivity_expand_selection(Dict("selection_replacements"=>Dict("all"=>["v$i" for i in 1:4097])),["all"])
    # A JSON round trip retains exact effective worker-request IDs.
    write(joinpath(out,"effective_request.json"),JSON.json(effective))
    @test W.sensitivity_request(m,JSON.parsefile(joinpath(out,"effective_request.json")))==effective
    write(joinpath(out,"selection_catalogs.json"),JSON.json(Dict("baseline"=>c,"overridden"=>dc,"sandwich"=>sc,"mixed"=>mc)))
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"selection_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
