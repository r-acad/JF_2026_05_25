using Test, JSON, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);base=JSON.parsefile(joinpath(out,"beam","params.json"))
build_gauge_edge(p)=W.build_model(first(W.normalize_params(p)))
checks=@testset "Panel-only sandwich flanges and movable minimum gauges" begin
    p=deepcopy(base);p["stringers.model"]="shell"
    p["properties.stringer_flange_width"]=0.;p["properties.stringer_flange_thickness"]=0.
    blade=build_gauge_edge(p);context=W.panel_property_context(blade.params);id=minimum(keys(context.keys))
    p["properties.panels"]=[Dict("key"=>context.keys[id],"layout_token"=>context.token,"stringer"=>Dict("flange_width"=>.03,"flange_thickness"=>.002))]
    push!(p["materials.shells"],Dict("component"=>"stringer_flange","kind"=>"sandwich","material"=>1,
        "face_material"=>1,"core_material"=>3,"face_thickness"=>.0005,"core_thickness"=>.01))
    m=build_gauge_edge(p)
    property=only(filter(x->W.component_base_pid(x["pid"])==W.PID_STRINGER_FLANGE,W.model_property_definitions(m)))
    @test property["type"]=="PCOMP"
    @test property["added_flange_thickness_m"]==.002
    gauge=property["minimum_gauge"]
    @test gauge["status"]=="known"&&gauge["can_reduce"]&&!gauge["at_minimum"]
    core=only(filter(d->d["field"]=="added_flange.core_thickness",gauge["dimensions"]))
    @test core["minimum_m"]==0.
    @test core["value_m"]≈.001
    @test only(filter(d->d["field"]=="added_flange.face_thickness",gauge["dimensions"]))["minimum_m"]==.0005
    invalid=deepcopy(p);invalid["properties.panels"][1]["stringer"]["flange_thickness"]=.0009
    @test_throws ArgumentError W.model_property_definitions(build_gauge_edge(invalid))
    # Surface-specific gauges are inherited unchanged by all physical bays and
    # ribs; unlike imported cards, these four user-owned lower bounds are known.
    p=deepcopy(base)
    p["movable_surfaces.items"]=[Dict("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.1,"eta_end"=>.9,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>20.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Flap","span_bays"=>2,
        "span_elements"=>1,"chord_elements"=>2,"height_elements"=>1,
        "upper_thickness"=>.0011,"lower_thickness"=>.0012,"web_thickness"=>.0013,"rib_thickness"=>.0014))]
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Flap","eta"=>eta,"rib"=>rib)) for (eta,rib) in ((.25,1),(.75,3))]
    m=build_gauge_edge(p);properties=filter(x->W.is_movable_pid(x["pid"]),W.model_property_definitions(m))
    @test !isempty(properties)
    @test length(unique(x["pid"]÷1_000_000 for x in properties))==5
    for property in properties
        gauge=property["minimum_gauge"]
        @test gauge["status"]=="known"&&gauge["at_minimum"]&&!gauge["can_reduce"]
        dimension=only(gauge["dimensions"])
        @test dimension["value_m"]==dimension["minimum_m"]==property["thickness_m"]
        @test startswith(dimension["minimum_key"],"movable_structure.surfaces#Flap#")
        group=first(g for g in m.groups if g.pid==property["pid"])
        @test W.element_properties(m,group)["minimum_gauge"]==gauge
    end
    @test W.property_minimum_gauge(Dict("imported.native"=>Dict()),first(properties)["pid"])["status"]=="not_applicable"
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"edge_summary.json"),JSON.json(Dict("passed"=>counts.passes+counts.cumulative_passes,"failed"=>counts.fails+counts.cumulative_fails,"errors"=>counts.errors+counts.cumulative_errors)))
