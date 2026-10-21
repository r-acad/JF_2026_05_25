# julia --project=. APPS/JFEM-Boxer/test/minimum_gauge_test.jl <private-output-directory>
using Test, JSON, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);mkpath(out)
function gauge_test_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>2,"airfoil.n_points"=>21,
        "mesh.aero_chord_points"=>11,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "loads.lift_total"=>1.,"output.solution"=>"101","output.n_modes"=>3))
    p
end
gauge_normal(p)=first(W.normalize_params(p))
gauge_build(p)=W.build_model(gauge_normal(p))
function gauge_fixture(m,name)
    dir=joinpath(out,name);mkpath(dir)
    payload=W.mesh_payload(m)
    write(joinpath(dir,"payload.msgpack"),W.MsgPack.pack(payload))
    write(joinpath(dir,"schema.json"),JSON.json(W.schema_payload(m.params,"minimum_gauge_fixture.toml")))
    write(joinpath(dir,"params.json"),JSON.json(m.params))
    write(joinpath(dir,"properties.json"),JSON.json(W.model_property_definitions(m)))
    open(joinpath(dir,"model.bdf"),"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
end
summary=Dict{String,Any}()
checks=@testset "Global minimum gauges and actual generated-property metadata" begin
    p=gauge_test_params();m=gauge_build(p)
    definitions=W.model_property_definitions(m)
    for property in definitions
        gauge=property["minimum_gauge"]
        if W.component_base_pid(property["pid"])==W.PID_STRINGER_RUNOUT
            @test gauge["status"]=="not_applicable"
        else
            @test gauge["status"]=="known"
            @test gauge["at_minimum"]&&!gauge["can_reduce"]
            @test !isempty(gauge["dimensions"])
            @test all(d->d["value_m"]>=d["minimum_m"]-W.minimum_gauge_tolerance(d["value_m"],d["minimum_m"]),gauge["dimensions"])
        end
    end
    for group in m.groups
        @test W.element_properties(m,group)["minimum_gauge"]==W.property_minimum_gauge(m.params,group.pid)
    end
    gauge_fixture(m,"beam")
    baseline_ids=Set(eid for group in m.groups for eid in group.eids)
    for rows in (W.stringer_euler_payload(m),W.stringer_blade_payload(m),W.skin_buckling_payload(m)),row in rows
        @test row["membership_complete"]
        @test !isempty(row["member_element_ids"])
        @test issubset(Set(row["member_element_ids"]),baseline_ids)
    end
    summary["baseline_properties"]=length(definitions)
    for key in (collect(values(W.MINIMUM_SHELL_KEYS))...,W.STRINGER_DIMENSION_KEYS...,
            ("properties.rib_stiffener_"*field for field in W.RIB_STIFFENER_FIELDS)...,"properties.spar_cap_side")
        spec=only(filter(s->s.key==key,W.SCHEMA))
        @test startswith(spec.label,"Minimum ")
        @test occursin("local overrides",spec.help)
    end
    @test only(filter(s->s.key=="stringers.skin_fixity_coefficient",W.SCHEMA)).group=="Shell properties"
    @test only(filter(s->s.key=="stringers.euler_fixity_coefficient",W.SCHEMA)).group=="Beam sections"
    for (part,field,base) in (("front_web","thickness","properties.t_spar_web"),
            ("rear_web","thickness","properties.t_spar_web"),("rib_web","thickness","properties.t_rib_web"),
            ("leading_upper_skin","thickness","leading_edge.t_skin"),("leading_lower_skin","thickness","leading_edge.t_skin"),
            ("leading_rib","thickness","leading_edge.t_rib"),("front_upper_cap","side","properties.spar_cap_side"),
            ("rear_lower_cap","side","properties.spar_cap_side"),
            (("rib_stiffener",field,"properties.rib_stiffener_"*field) for field in W.RIB_STIFFENER_FIELDS)...)
        below=deepcopy(p);below["properties.components"]=[Dict("key"=>"$part:1",field=>.9p[base])]
        @test_throws ArgumentError gauge_normal(below)
        larger=deepcopy(p);larger["properties.components"]=[Dict("key"=>"$part:1",field=>1.1p[base])]
        actual=gauge_normal(larger);pid=W.component_table_family(part)*W.COMPONENT_PID_STRIDE+1
        gauge=W.property_minimum_gauge(actual,pid)
        @test gauge["can_reduce"]&&!gauge["at_minimum"]
    end
    for (table,row) in (("properties.ribs",Dict("rib"=>1,"thickness"=>.001)),
            ("properties.spar_bays",Dict("bay"=>1,"front_thickness"=>.001)),
            (("properties.ribs",Dict("rib"=>1,field=>.9p["properties.rib_stiffener_"*field])) for field in W.RIB_STIFFENER_FIELDS)...)
        below=deepcopy(p);below[table]=[row]
        @test_throws ArgumentError gauge_normal(below)
    end
    context=W.panel_property_context(m.params);panelid=minimum(keys(context.keys));key=context.keys[panelid]
    for (part,field,base) in (("skin","thickness",startswith(key,"upper:") ? "properties.t_skin_upper" : "properties.t_skin_lower"),
            (("stringer",field,"properties.stringer_"*field) for field in W.RIB_STIFFENER_FIELDS)...)
        below=deepcopy(p);below["properties.panels"]=[Dict("key"=>key,"layout_token"=>context.token,part=>Dict(field=>.9p[base]))]
        @test_throws ArgumentError gauge_normal(below)
        larger=deepcopy(p);larger["properties.panels"]=[Dict("key"=>key,"layout_token"=>context.token,part=>Dict(field=>1.1p[base]))]
        actual=gauge_normal(larger)
        pid=part=="stringer" ? W.panel_stringer_pid(panelid) : W.panel_skin_pid(panelid,startswith(key,"upper:"))
        @test W.property_minimum_gauge(actual,pid)["can_reduce"]
        roundtrip=first(W.normalize_params(W.flatten_toml(W.TOML.parse(W.params_to_toml(actual)))))
        @test roundtrip["properties.panels"]==actual["properties.panels"]
    end
    raised=deepcopy(p);raised["properties.components"]=[Dict("key"=>"front_web:1","thickness"=>.0035)]
    raised["properties.t_spar_web"]=.004
    @test_throws ArgumentError gauge_normal(raised)
    raised["properties.t_spar_web"]=.003
    @test gauge_normal(raised)["properties.t_spar_web"]==.003
    # A superseded legacy dimension is inactive and does not override the
    # detached table's authoritative local property.
    superseded=deepcopy(p);superseded["properties.ribs"]=[Dict("rib"=>1,"thickness"=>.001)]
    superseded["properties.components"]=[Dict("key"=>"rib_web:1","thickness"=>.003)]
    @test W.shell_thickness(gauge_normal(superseded),W.component_table_family("rib_web")*W.COMPONENT_PID_STRIDE+1)==.003
    disabled=deepcopy(p);disabled["properties.ribs"]=[Dict("rib"=>1,"stiffener_enabled"=>false,"web_thickness"=>.001)]
    @test gauge_normal(disabled)["properties.ribs"][1]["web_thickness"]==.001
    disabled["properties.components"]=[Dict("key"=>"rib_stiffener:1","enabled"=>false,"flange_thickness"=>.001)]
    @test gauge_normal(disabled)["properties.components"][1]["flange_thickness"]==.001
    disabled["properties.components"][1]["enabled"]=true
    @test_throws ArgumentError gauge_normal(disabled)
    # Composite minima follow the global stack and its actual local layers.
    composite=deepcopy(p)
    assignment=only(filter(r->r["component"]=="spar_web",composite["materials.shells"]))
    merge!(assignment,Dict("kind"=>"sandwich","face_thickness"=>.0005,"core_thickness"=>.004))
    composite=gauge_normal(composite)
    @test W.property_minimum_gauge(composite,W.PID_SPAR_WEB)["at_minimum"]
    for row in (Dict("face_thickness"=>.0004,"core_thickness"=>.01),Dict("face_thickness"=>.002,"core_thickness"=>.003))
        invalid=deepcopy(composite);invalid["properties.components"]=[merge(Dict("key"=>"front_web:1"),row)]
        @test_throws ArgumentError gauge_normal(invalid)
    end
    composite["properties.components"]=[Dict("key"=>"front_web:1","core_thickness"=>.005,"thickness"=>.00001)]
    actual=gauge_normal(composite);pid=W.component_table_family("front_web")*W.COMPONENT_PID_STRIDE+1
    @test W.shell_thickness(actual,pid)≈.006
    @test W.property_minimum_gauge(actual,pid)["can_reduce"]
    legacy=deepcopy(composite);legacy["properties.components"]=Any[];legacy["properties.spar_bays"]=[Dict("bay"=>1,"front_thickness"=>.004)]
    @test_throws ArgumentError gauge_normal(legacy)
    composite["properties.components"]=[Dict("key"=>"front_web:1","kind"=>"monolithic","thickness"=>.004)]
    @test_throws ArgumentError gauge_normal(composite)
    composite["properties.components"]=[Dict("key"=>"front_web:1","kind"=>"monolithic","thickness"=>.005)]
    @test W.property_minimum_gauge(gauge_normal(composite),pid)["at_minimum"]
    # Mixed-material, offset shell flanges include both actual added flange
    # dimensions and selected skin floors; no double-counted total thickness.
    shell=deepcopy(p);shell["stringers.model"]="shell";shell["stringers.shell_offsets"]=true
    only(filter(r->r["component"]=="stringer",shell["materials.bars"]))["material"]=2
    sm=gauge_build(shell)
    for property in W.model_property_definitions(sm)
        base=W.component_base_pid(property["pid"])
        if base==W.PID_STRINGER_FLANGE
            @test property["type"]=="PCOMP"
            @test property["minimum_gauge"]["at_minimum"]
            @test any(d->d["field"]=="underlying_skin.thickness",property["minimum_gauge"]["dimensions"])
        end
    end
    gauge_fixture(sm,"shell_offset")
    @test all(row["applicable"]===false&&!isempty(row["member_element_ids"]) for row in W.stringer_blade_payload(sm))
    runout=deepcopy(p);merge!(runout,Dict("planform.taper_ratio"=>.55,"planform.sweep"=>35.,"mesh.elements_between_ribs"=>4))
    rm=gauge_build(runout)
    failed=filter(row->row["status"]!="ready",W.stringer_euler_payload(rm))
    @test !isempty(failed)
    @test all(row["applicable"]&&row["membership_complete"]===false&&!isempty(row["member_element_ids"]) for row in failed)
    failedskin=filter(row->row["status"]!="ready",W.skin_buckling_payload(rm))
    @test !isempty(failedskin)
    @test all(!isempty(row["member_element_ids"]) for row in failedskin)
    blade=deepcopy(shell);blade["properties.stringer_flange_width"]=0.;blade["properties.stringer_flange_thickness"]=0.
    bm=gauge_build(blade)
    for property in W.model_property_definitions(bm)
        if W.component_base_pid(property["pid"])==W.PID_STRINGER_WEB
            @test property["minimum_gauge"]["at_minimum"]
            @test all(d->d["field"]!="flange_thickness",property["minimum_gauge"]["dimensions"])
        end
    end
    @test W.property_minimum_gauge(Dict("imported.native"=>Dict()),123)["status"]=="not_applicable"
    @test W.property_minimum_gauge(p,W.PID_STRINGER_RUNOUT)["status"]=="not_applicable"
    @test W.minimum_dimension("t",.003*(1-1e-12),.003,"min")["at_minimum"]
    @test_throws ArgumentError W.minimum_dimension("t",.003*(1-1e-8),.003,"min")
    summary["shell_properties"]=length(W.model_property_definitions(sm))
end
counts=Test.get_test_counts(checks)
summary["tests"]=Dict("passed"=>counts.passes+counts.cumulative_passes,"failed"=>counts.fails+counts.cumulative_fails,"errors"=>counts.errors+counts.cumulative_errors)
write(joinpath(out,"backend_summary.json"),JSON.json(summary))
