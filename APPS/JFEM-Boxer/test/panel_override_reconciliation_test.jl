using Test, JSON, WingFEGen
const W=WingFEGen

function reconciliation_fixture()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>8.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>.4,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "box.rib_pitch"=>.4,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "fuel.enabled"=>false,"loads.cases"=>Any[]))
    wing=W.make_wing(p)
    p["box.stringer_pitch"]=(p["box.rear_spar_xc"]-p["box.front_spar_xc"])*wing.chord_root/9
    p
end

function override_all_stringers!(p,m)
    layout=W.stiffened_panel_layout(m.grid);token=W.panel_layout_token(m.grid,layout)
    p["properties.panels"]=[Dict{String,Any}("key"=>W.panel_key(panel),"layout_token"=>token,
        "stringer"=>Dict("material"=>2)) for panel in layout.panels]
end

function changed_rear_spar(p,value)
    q=deepcopy(p);q["box.rear_spar_points"]=[Dict("eta"=>.5,"dxc"=>value,"stringer_angle"=>0.)];q
end

failure(f)=try f();nothing catch error;error end
suite=@testset "Component-specific panel override reconciliation" begin
    p=reconciliation_fixture();m=W.build_model(p);override_all_stringers!(p,m)
    oldlayout=W.stiffened_panel_layout(m.grid);oldtoken=W.panel_layout_token(m.grid,oldlayout)
    same=deepcopy(p);same["loads.load_factor"]*=1.1
    @test W.panel_layout_inputs_equal(same,m.params)
    rows_before=deepcopy(same["properties.panels"])
    W.migrate_legacy_panel_overrides!(same,m)
    @test same["properties.panels"]==rows_before
    wider=changed_rear_spar(p,.025);grid=W.panel_coarse_grid(wider);layout=W.stiffened_panel_layout(grid)
    @test W.panel_layout_token(grid,layout)!=oldtoken
    @test Set(W.panel_key.(oldlayout.panels)) ⊆ Set(W.panel_key.(layout.panels))
    original=deepcopy(wider["properties.panels"])
    W.migrate_legacy_panel_overrides!(wider,m)
    @test length(wider["properties.panels"])==length(original)
    @test all(row["stringer"]["material"]==2 for row in wider["properties.panels"])
    @test W.register_panel_properties!(wider,grid).token==W.panel_layout_token(grid,layout)
    @test W.panel_override_migration(wider)["row_count"]==length(original)
    # An adjacent runout changes a skin footprint without changing its stringer.
    newbykey=Dict(W.panel_key(q)=>q for q in layout.panels)
    changed=first(q for q in oldlayout.panels if W.panel_skin_membership(m.grid,oldlayout,q)!=W.panel_skin_membership(grid,layout,newbykey[W.panel_key(q)]))
    mixed=changed_rear_spar(p,.025)
    selected=only(filter(row->row["key"]==W.panel_key(changed),mixed["properties.panels"]))
    selected["skin"]=Dict("thickness"=>.004)
    saved=deepcopy(mixed["properties.panels"])
    baseline_before=deepcopy(m.params)
    conflict=failure(()->W.migrate_legacy_panel_overrides!(mixed,m))
    @test conflict isa W.PanelOverrideConflict
    @test mixed["properties.panels"]==saved
    @test m.params==baseline_before
    @test length(conflict.affected_rows)==1
    @test only(conflict.affected_rows)["parts"]==["skin"]
    retained=only(filter(row->row["key"]==W.panel_key(changed),conflict.compatible_rows))
    @test retained["stringer"]["material"]==2
    @test !haskey(retained,"skin")
    response=W.panel_override_error_response(conflict);body=JSON.parse(String(response.body))
    @test response.status==409
    @test body["code"]=="panel_override_conflict"
    @test body["can_reconcile"]
    @test body["details"]["affected_part_count"]==1
    @test body["affected_rows"][1]["row"]["skin"]["thickness"]==.004
    approved=deepcopy(mixed);approved["properties.panels"]=deepcopy(conflict.compatible_rows)
    @test W.register_panel_properties!(approved,grid).token==W.panel_layout_token(grid,layout)

    narrower=changed_rear_spar(p,-.025);saved=deepcopy(narrower["properties.panels"])
    conflict=failure(()->W.migrate_legacy_panel_overrides!(narrower,m))
    @test conflict isa W.PanelOverrideConflict
    @test !isempty(conflict.compatible_rows)&&!isempty(conflict.affected_rows)
    @test length(conflict.compatible_rows)+length(conflict.affected_rows)==length(saved)
    @test narrower["properties.panels"]==saved
    @test all(occursin("runout",row["reason"]) for row in conflict.affected_rows)

    renumbered=deepcopy(p);renumbered["box.front_spar_xc"]+=.0001
    conflict=failure(()->W.migrate_legacy_panel_overrides!(renumbered,m))
    @test conflict isa W.PanelOverrideConflict
    @test conflict.details["old_stringer_count"]==8&&conflict.details["new_stringer_count"]==7
    @test all(occursin("root anchor",row["reason"]) for row in conflict.affected_rows)
    @test isempty(conflict.compatible_rows)

    # Added rib/line indices can shift; unchanged exact anchors map explicitly.
    addedrib=deepcopy(m.grid);push!(addedrib.ribs,1);sort!(addedrib.ribs)
    baymap=W.panel_rib_bay_map(m.grid,addedrib)
    @test !haskey(baymap,1)
    @test baymap[2]==3
    addedline=deepcopy(m.grid);push!(addedline.stringer_indices,1);sort!(addedline.stringer_indices)
    linemap=W.panel_stringer_map(m.grid,addedline)
    @test all(linemap[i]==i+1 for i in eachindex(m.grid.stringer_indices))

    unauthenticated=deepcopy(p);unauthenticated["properties.panels"][1]["layout_token"]=repeat("f",64)
    before=deepcopy(unauthenticated["properties.panels"])
    W.migrate_legacy_panel_overrides!(unauthenticated,m)
    @test unauthenticated["properties.panels"]==before
    error=failure(()->W.register_panel_properties!(unauthenticated,m.grid))
    @test error isa W.PanelOverrideConflict
    @test !error.details["can_reconcile"]&&error.compatible_rows===nothing
end

# Optional first argument: write the generated-fixture test summary as JSON.
if !isempty(ARGS)
    counts=Test.get_test_counts(suite);n=counts.passes+counts.cumulative_passes
    write(ARGS[1],JSON.json(Dict("passed"=>true,"assertions"=>n)))
end
