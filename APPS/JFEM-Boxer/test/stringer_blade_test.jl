# julia --project=. APPS/JFEM-Boxer/test/stringer_blade_test.jl <private-output-directory> [existing-Euler-recovery-directory]
using Test, JSON, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);mkpath(out)
function blade_test_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>1,"mesh.elements_stringer_height"=>2,"airfoil.n_points"=>21,
        "mesh.aero_chord_points"=>11,"fuel.enabled"=>false,"leading_edge.enabled"=>false,
        "aero.enabled"=>false,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "loads.lift_total"=>1.,"output.solution"=>"101","output.n_modes"=>3,"stringers.model"=>"beam"))
    p
end
blade_build(p)=W.build_model(first(W.normalize_params(p)))
coverage=Any[]
checks=@testset "Stringer free-web metadata follows physical PBARL T members" begin
    for kind in ("beam","swept","shell")
        p=blade_test_params()
        kind=="swept"&&merge!(p,Dict("planform.sweep"=>35.,"planform.dihedral"=>7.,"planform.twist_tip"=>-4.,"planform.taper_ratio"=>.55,"mesh.elements_between_ribs"=>4))
        kind=="shell"&&(p["stringers.model"]="shell")
        m=blade_build(p);rows=W.stringer_blade_payload(m)
        @test !isempty(rows)
        @test length(unique(row["key"] for row in rows))==length(rows)
        @test length(rows)==length(W.stiffened_panel_layout(m.grid).panels)
        elapsed=@elapsed W.stringer_blade_payload(m)
        if kind=="shell"
            @test all(row["status"]=="unassessed"&&isempty(row["bars"])&&occursin("shell",row["reason"]) for row in rows)
        else
            @test all(row["status"]=="ready" for row in rows)
            actual=Set(eid for g in m.groups if g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_STRINGER for eid in g.eids)
            emitted=[bar["eid"] for row in rows for bar in row["bars"]]
            @test Set(emitted)==actual
            @test length(emitted)==length(actual)
            @test isempty(intersect(Set(emitted),Set(eid for g in m.groups if W.component_base_pid(g.pid)==W.PID_STRINGER_RUNOUT for eid in g.eids)))
            for row in rows
                @test row["length_m"]≈sum(bar["length_m"] for bar in row["bars"])
                @test row["length_m"]>0
                for bar in row["bars"]
                    group=only(g for g in m.groups if bar["eid"] in g.eids)
                    index=findfirst(==(bar["eid"]),group.eids);points=W.element_points(m,group,index)
                    @test bar["length_m"]≈W.norm3(points[2].-points[1])
                    @test bar["web_height_m"]≈p["properties.stringer_height"]-p["properties.stringer_flange_thickness"]
                    @test bar["web_thickness_m"]==p["properties.stringer_web_thickness"]
                    @test bar["young_pa"]==p["material.E"]
                    @test bar["poisson"]==p["material.nu"]
                    @test bar["source"]=="PBARL"&&bar["section_shape"]=="T"&&bar["material_type"]=="MAT1"
                    @test bar["pid"]==group.pid==row["pid"]
                end
            end
        end
        if kind=="swept"
            runouts=filter(row->row["start_kind"]=="runout"||row["end_kind"]=="runout",rows)
            @test !isempty(runouts)
            @test all(row["status"]=="ready" for row in runouts)
        elseif kind=="beam"
            payload=W.mesh_payload(m)
            @test payload["stiffened_panels"]["blade_columns"]==rows
            dir=joinpath(out,kind);mkpath(dir)
            write(joinpath(dir,"payload.msgpack"),W.MsgPack.pack(payload))
            write(joinpath(dir,"schema.json"),JSON.json(W.schema_payload(m.params,"blade_fixture.toml")))
            write(joinpath(dir,"params.json"),JSON.json(m.params))
            open(joinpath(dir,"model.bdf"),"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
            # Sparse physical-panel overrides must be used, not shared defaults.
            firstrow=first(rows);firstpanel=first(payload["stiffened_panels"]["panels"])
            p["properties.panels"]=[Dict("key"=>firstpanel["key"],"layout_token"=>payload["stiffened_panels"]["layout_token"],
                "stringer"=>Dict("height"=>.045,"flange_thickness"=>.003,"web_thickness"=>.0015,"material"=>2))]
            overridden=W.stringer_blade_payload(blade_build(p));changed=only(filter(row->row["key"]==firstrow["key"],overridden))
            @test all(bar["web_height_m"]≈.042&&bar["web_thickness_m"]==.0015&&bar["material_id"]==2&&bar["young_pa"]==210e9 for bar in changed["bars"])
            @test all(all(bar["material_id"]==1 for bar in row["bars"]) for row in overridden if row["key"]!=firstrow["key"])
            # Blade eligibility does not depend on skin or Euler-column coverage.
            filter!(g->W.component_base_pid(g.pid)∉(W.PID_SKIN_UPPER,W.PID_SKIN_LOWER),m.groups)
            @test W.stringer_blade_payload(m)==rows
            group=first(g for g in m.groups if g.kind===:bar&&W.component_base_pid(g.pid)==W.PID_STRINGER)
            old=group.conn[2];group.conn[2]=group.conn[1]
            broken=only(filter(row->row["pid"]==group.pid,W.stringer_blade_payload(m)))
            @test broken["status"]=="unassessed"&&isempty(broken["bars"])&&occursin("zero",broken["reason"])
            group.conn[2]=old
            push!(m.groups,group)
            duplicate=only(filter(row->row["pid"]==group.pid,W.stringer_blade_payload(m)))
            @test duplicate["status"]=="unassessed"&&occursin("more than once",duplicate["reason"])
            pop!(m.groups)
            @test isempty(W.stringer_blade_payload(m;layout=(panels=NamedTuple[],)))
            m.params["imported.native"]=nothing
            @test isempty(W.stringer_blade_payload(m))
        end
        write(joinpath(out,kind*"_blade_columns.json"),JSON.json(rows))
        push!(coverage,Dict("kind"=>kind,"segments"=>length(rows),"ready"=>count(row->row["status"]=="ready",rows),
            "members"=>sum(length(row["bars"]) for row in rows),"seconds"=>elapsed))
    end
    if length(ARGS)>1
        old=abspath(ARGS[2]);params=JSON.parsefile(joinpath(old,"beam","params.json"))
        m=blade_build(params);rows=W.stringer_blade_payload(m)
        for name in ("axial_euler_fixture.json","axial_sol106_euler_fixture.json")
            fixture=JSON.parsefile(joinpath(old,"beam",name))
            cases=fixture["cases"]
            for case in cases;case["stress_units"]="Pa";end
            means=Any[]
            for row in rows,case in cases
                values=Float64[]
                for bar in row["bars"]
                    record=case["element_results"][string(bar["eid"])];stress=record["stress"]
                    @test isfinite(stress["axial"])
                    if haskey(stress,"axial_end_a")||haskey(stress,"axial_end_b")
                        @test haskey(stress,"axial_end_a")&&haskey(stress,"axial_end_b")
                        @test stress["axial_end_a"]≈stress["axial_end_b"]
                        @test stress["axial"]≈(stress["axial_end_a"]+stress["axial_end_b"])/2
                    end
                    area=W.section_definition(m.params,bar["pid"])["area_m2"]
                    @test stress["axial"]≈record["forces"]["axial"]/area rtol=1e-10
                    push!(values,stress["axial"])
                end
                push!(means,Dict("panel_id"=>row["panel_id"],"case_id"=>case["case_id"],"mean_axial_stress_pa"=>sum(values)/length(values)))
            end
            @test any(row["mean_axial_stress_pa"]<0 for row in means)
            if length(cases)==3
                for panel in rows
                    vals=[only(filter(row->row["panel_id"]==panel["panel_id"]&&row["case_id"]==i,means))["mean_axial_stress_pa"] for i in 1:3]
                    @test vals[1]≈-vals[2] rtol=1e-10 atol=1e-8
                    @test vals[3]≈2vals[1] rtol=1e-10 atol=1e-8
                end
            end
            filename=replace(name,"euler"=>"blade")
            write(joinpath(out,filename),JSON.json(Dict("stringerBlades"=>rows,"cases"=>cases,"mean_checks"=>means,
                "recovery_provenance"=>"Reused unchanged FE-model recovery; blade postprocessing does not modify the solver")))
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"backend_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"coverage"=>coverage)))
println(JSON.json(coverage))
