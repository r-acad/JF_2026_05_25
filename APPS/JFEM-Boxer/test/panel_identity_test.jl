using Test, JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen

function identity_params()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.08,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>1,
        "fuel.enabled"=>false,"loads.cases"=>Any[]))
end

function identity_grid(p)
    w=W.make_wing(p);xcs,_=W.chord_stations(w,p);etas,ribs,_=W.span_stations(w,p)
    coarse=W.stringer_grid(w,p,xcs,etas,ribs,p["mesh.elements_spar_height"])
    W.shell_stringers(p) ? W.shell_stringer_grid(coarse,p) :
        W.refine_stringer_bays(coarse,p["mesh.elements_between_stringers"])
end

@testset "Physical panel identity and authenticated legacy migration" begin
    p=identity_params();m=W.build_model(p);g=m.grid
    layout=W.stiffened_panel_layout(g);token=W.panel_layout_token(g,layout)
    legacy=W.legacy_panel_layout_token(g,layout)
    @test token!=legacy
    override=Dict{String,Any}("key"=>W.panel_key(first(layout.panels)),"layout_token"=>token,
        "skin"=>Dict("thickness"=>.004),"stringer"=>Dict("material"=>2))
    p["properties.panels"]=[override]
    for change in (Dict("planform.twist_tip"=>.1),Dict("planform.dihedral"=>1.),
            Dict("planform.sweep"=>.1),Dict("mesh.elements_between_ribs"=>7),
            Dict("mesh.elements_between_stringers"=>3),
            Dict("loft.thickness_stations"=>[Dict("eta"=>0.,"tc"=>.12),Dict("eta"=>.37,"tc"=>.13),Dict("eta"=>1.,"tc"=>.12)]),
            Dict("stringers.model"=>"shell","properties.stringer_flange_width"=>.04),
            Dict("stringers.model"=>"shell","properties.stringer_flange_width"=>0.))
        edited=merge(deepcopy(p),change);grid=identity_grid(edited)
        context=W.register_panel_properties!(edited,grid)
        @test context.token==token
        @test only(values(context.rows))["skin"]["thickness"]==.004
        @test only(values(context.rows))["stringer"]["material"]==2
    end
    for change in (Dict("box.rib_pitch"=>.25),Dict("box.stringer_pitch"=>.06))
        edited=merge(deepcopy(p),change)
        @test_throws W.PanelOverrideConflict W.register_panel_properties!(edited,identity_grid(edited))
    end
    # Equal active-panel keys alone are insufficient: runout side is identity.
    front=deepcopy(g);rear=deepcopy(g);i=first(g.stringer_indices)
    front.collapsed[i+1,g.ribs[2]+2:end].=-1
    rear.collapsed[i+1,g.ribs[2]+2:end].=1
    lf=W.stiffened_panel_layout(front);lr=W.stiffened_panel_layout(rear)
    @test W.panel_key.(lf.panels)==W.panel_key.(lr.panels)
    @test W.panel_layout_token(front,lf)!=W.panel_layout_token(rear,lr)

    saved=deepcopy(p);saved["properties.panels"][1]["layout_token"]=legacy
    normalized,_=W.normalize_params(JSON.parse(JSON.json(saved)))
    reopened=W.build_model(normalized)
    @test only(reopened.params["properties.panels"])["layout_token"]==token
    @test only(reopened.params["properties.panels"])["skin"]["thickness"]==.004
    @test only(saved["properties.panels"])["layout_token"]==legacy

    edited=deepcopy(saved);edited["planform.twist_tip"]=.1
    @test_throws W.PanelOverrideConflict W.register_panel_properties!(edited,identity_grid(edited))
    W.migrate_legacy_panel_overrides!(edited,m)
    @test only(edited["properties.panels"])["layout_token"]==token
    @test W.register_panel_properties!(edited,identity_grid(edited)).token==token
    incompatible=deepcopy(saved);incompatible["box.rib_pitch"]=.25
    @test_throws W.PanelOverrideConflict W.migrate_legacy_panel_overrides!(incompatible,m)

    invalid=deepcopy(saved)
    other=deepcopy(only(invalid["properties.panels"]));other["key"]=W.panel_key(last(layout.panels));other["layout_token"]=repeat("f",64)
    push!(invalid["properties.panels"],other)
    before=deepcopy(invalid["properties.panels"])
    W.migrate_legacy_panel_overrides!(invalid,m)
    @test invalid["properties.panels"]==before
    @test_throws W.PanelOverrideConflict W.register_panel_properties!(invalid,g)
    @test invalid["properties.panels"]==before
end

# Optional private saved-study fixture; no private model is distributed here.
if !isempty(ARGS)
    @testset "Existing saved study" begin
        saved=JSON.parsefile(ARGS[1]);p,_=W.normalize_params(saved["parameters"])
        original=deepcopy(p["properties.panels"])
        bare=deepcopy(p);bare["properties.panels"]=Any[];grid=identity_grid(bare)
        @test all(row->row["layout_token"]==W.legacy_panel_layout_token(grid),original)
        model=W.build_model(p);token=W.panel_layout_token(model.grid,W.stiffened_panel_layout(model.grid))
        @test all(row->row["layout_token"]==token,model.params["properties.panels"])
        @test length(original)==length(model.params["properties.panels"])
        for field in ("key","skin","stringer")
            @test [get(row,field,nothing) for row in original]==[get(row,field,nothing) for row in model.params["properties.panels"]]
        end
        edited=deepcopy(model.params);edited["planform.twist_tip"]+=.01
        @test W.register_panel_properties!(edited,identity_grid(edited)).token==token
    end
end
