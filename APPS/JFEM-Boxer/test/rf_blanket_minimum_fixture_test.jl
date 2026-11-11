# Native section-response fixtures for blanket minimum sizing after analysis.
# julia --project=. APPS/JFEM-Boxer/test/rf_blanket_minimum_fixture_test.jl PRIVATE_OUTPUT
using Test, JSON, WingFEGen
const W=WingFEGen
length(ARGS)==1 || error("Provide a private output directory")
out=abspath(only(ARGS));mkpath(out)
@testset "Blanket minimum section updates preserve physical membership" begin
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,
        "fuel.enabled"=>false,"leading_edge.enabled"=>true,"loads.cases"=>Any[],
        "loads.method"=>"analytic","loads.lift_total"=>100.,"output.solution"=>"101",
        "stringers.model"=>"beam"))
    initial=W.build_model(first(W.normalize_params(p)))
    panels=W.stiffened_panel_layout(initial.grid).panels
    selected=[first(filter(r->r.upper&&r.bay==1,panels)),first(filter(r->!r.upper&&r.bay==1,panels))]
    token=W.panel_layout_token(initial.grid,W.stiffened_panel_layout(initial.grid))
    p["properties.panels"]=[Dict("key"=>W.panel_key(row),"layout_token"=>token,
        "skin"=>Dict("thickness"=>.0018),"stringer"=>Dict("height"=>.035,"web_thickness"=>.0018)) for row in selected]
    push!(p["properties.panels"],Dict("key"=>W.panel_key(last(panels)),"layout_token"=>token,
        "skin"=>Dict("thickness"=>.006),"stringer"=>Dict("height"=>.06,"web_thickness"=>.006)))
    p["properties.ribs"]=[Dict("rib"=>1,"thickness"=>.0018,"height"=>.035),Dict("rib"=>2,"thickness"=>.006,"height"=>.06)]
    p["properties.spar_bays"]=[Dict("bay"=>1,"front_thickness"=>.0018,"rear_thickness"=>.006)]
    p["properties.components"]=[Dict("key"=>"front_web:1","thickness"=>.0018),Dict("key"=>"rear_web:1","thickness"=>.006),
        Dict("key"=>"rib_web:1","thickness"=>.0018),Dict("key"=>"rib_web:2","thickness"=>.006),
        Dict("key"=>"front_upper_cap:1","side"=>.021),Dict("key"=>"rear_upper_cap:1","side"=>.04),
        Dict("key"=>"rib_stiffener:1","height"=>.035),Dict("key"=>"rib_stiffener:2","height"=>.06),
        Dict("key"=>"leading_upper_skin:1","thickness"=>.0018),Dict("key"=>"leading_lower_skin:1","thickness"=>.006),
        Dict("key"=>"leading_rib:1","thickness"=>.0018)]
    m=W.build_model(first(W.normalize_params(p)));baseline=deepcopy(m.params);xyz=copy(m.xyz)
    keys=["properties.t_skin_upper","properties.t_skin_lower","properties.t_spar_web","properties.t_rib_web",
        "properties.spar_cap_side","properties.stringer_height","properties.stringer_web_thickness",
        "properties.rib_stiffener_height","leading_edge.t_skin","leading_edge.t_rib"]
    values=[.003,.003,.003,.003,.025,.04,.003,.04,.003,.003]
    changed=deepcopy(baseline);stages=Any[]
    for (key,value) in zip(keys,values)
        changed[key]=value
        # Independent expected floor construction. Browser production code
        # performs reconciliation; native validation verifies its final sizes.
        for row in changed["properties.panels"]
            if key in keys[1:2]&&startswith(row["key"],key==keys[1] ? "upper:" : "lower:")
                haskey(get(row,"skin",Dict()),"thickness")&&(row["skin"]["thickness"]=max(row["skin"]["thickness"],value))
            elseif startswith(key,"properties.stringer_")
                field=replace(key,"properties.stringer_"=>"");haskey(get(row,"stringer",Dict()),field)&&(row["stringer"][field]=max(row["stringer"][field],value))
            end
        end
        for row in changed["properties.ribs"]
            field=key=="properties.t_rib_web" ? "thickness" : key=="properties.rib_stiffener_height" ? "height" : ""
            haskey(row,field)&&(row[field]=max(row[field],value))
        end
        if key=="properties.t_spar_web"
            for row in changed["properties.spar_bays"],field in ("front_thickness","rear_thickness");haskey(row,field)&&(row[field]=max(row[field],value));end
        end
        for row in changed["properties.components"]
            part=first(split(row["key"],':'))
            field=(key==keys[3]&&part in ("front_web","rear_web") || key==keys[4]&&part=="rib_web" || key==keys[9]&&part in ("leading_upper_skin","leading_lower_skin") || key==keys[10]&&part=="leading_rib") ? "thickness" :
                key==keys[5]&&endswith(part,"_cap") ? "side" : key==keys[8]&&part=="rib_stiffener" ? "height" : ""
            haskey(row,field)&&(row[field]=max(row[field],value))
        end
        normalized=first(W.normalize_params(changed));response=W.rf_section_update(m,normalized)
        @test response["fixed_geometry"]
        @test response["stiffened_panels"]["layout_token"]==token
        @test m.xyz==xyz
        @test m.params==baseline
        push!(stages,Dict("key"=>key,"value"=>value,"parameters"=>deepcopy(normalized),"response"=>response))
    end
    write(joinpath(out,"schema.json"),JSON.json(W.schema_payload(baseline,"blanket-minimum-fixture.toml")))
    write(joinpath(out,"params.json"),JSON.json(baseline))
    write(joinpath(out,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
    write(joinpath(out,"stages.json"),JSON.json(stages))
    write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"stages"=>length(stages),"source_model_unchanged"=>true)))
end
