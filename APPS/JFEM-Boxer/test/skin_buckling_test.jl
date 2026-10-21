# julia --project=. APPS/JFEM-Boxer/test/skin_buckling_test.jl <private-output-directory> [existing-Euler-recovery-directory]
using Test, JSON, LinearAlgebra, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);mkpath(out)
function skin_test_params()
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
skin_build(p)=W.build_model(first(W.normalize_params(p)))
skin_matrix(rows)=reduce(vcat,permutedims.(rows))
function skin_stack(materials,thicknesses,angles;offset=0.)
    t=sum(thicknesses)
    W.euler_shell_section(Dict("type"=>"PCOMP","thickness_m"=>t,"z0_m"=>offset-t/2,
        "plies"=>[Dict("material"=>m,"material_id"=>m["id"],"thickness_m"=>h,"angle_deg"=>a)
            for (m,h,a) in zip(materials,thicknesses,angles)]))
end
coverage=Any[]
checks=@testset "Skin compartment geometry, stresses and laminate bending" begin
    e=70e9;nu=.3;t=.003
    iso=Dict("type"=>"MAT1","id"=>1,"E_Pa"=>e,"nu"=>nu)
    q=e/(1-nu^2).*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    for angle in (0.,.23,pi/2),offset in (0.,-.007,.001)
        section=skin_stack([iso],[t],[0.];offset)
        @test W.skin_effective_bending(section,angle)≈q.*t^3/12 rtol=5e-12
    end
    ortho=Dict("type"=>"MAT8","id"=>9,"E1_Pa"=>130e9,"E2_Pa"=>9e9,"G12_Pa"=>5e9,"nu12"=>.28)
    aligned=W.skin_effective_bending(skin_stack([ortho],[t],[0.]),0.)
    @test aligned≈W.euler_material_q(ortho).*t^3/12 rtol=1e-12
    rotated=W.skin_effective_bending(skin_stack([ortho],[t],[0.]),pi/2)
    @test rotated[1,1]≈aligned[2,2] rtol=1e-12
    @test rotated[2,2]≈aligned[1,1] rtol=1e-12
    for angle in (.17,.71)
        stack=skin_stack([ortho,iso,ortho],[.001,.002,.0008],[0.,0.,43.])
        moved=skin_stack([ortho,iso,ortho],[.001,.002,.0008],[0.,0.,43.];offset=.012)
        abd=W.skin_laminate_abd(stack,angle)
        expected=abd[4:6,4:6]-abd[4:6,1:3]*(abd[1:3,1:3]\abd[1:3,4:6])
        @test W.skin_effective_bending(stack,angle)≈expected rtol=1e-12
        @test W.skin_effective_bending(moved,angle)≈expected rtol=3e-11
        @test isposdef(Symmetric(expected))
        c,s=cos(angle),sin(angle);transform=W.skin_stress_transform(c,s)
        stress=[-17.,3.,2.];tensor=[stress[1] stress[3];stress[3] stress[2]]
        axes=[c s;-s c];rotated=axes*tensor*transpose(axes)
        @test transform*stress≈[rotated[1,1],rotated[2,2],rotated[1,2]]
        @test W.skin_stress_transform(c,-s)*(transform*stress)≈stress
    end
    baseline=nothing;beam_model=nothing;shell_rows=nothing
    for kind in ("beam","swept","runout","shell_mixed","shell_offset","no_stringers","angled_ribs")
        p=skin_test_params()
        kind=="swept"&&merge!(p,Dict("planform.sweep"=>35.,"planform.dihedral"=>7.,"planform.twist_tip"=>-4.))
        kind=="runout"&&merge!(p,Dict("planform.sweep"=>35.,"planform.dihedral"=>7.,"planform.twist_tip"=>-4.,"planform.taper_ratio"=>.55,"mesh.elements_between_ribs"=>4))
        if startswith(kind,"shell")
            p["stringers.model"]="shell";p["stringers.shell_offsets"]=kind=="shell_offset"
            only(filter(row->row["component"]=="stringer",p["materials.bars"]))["material"]=2
            upper=only(filter(row->row["component"]=="upper_skin",p["materials.shells"]))
            merge!(upper,Dict("kind"=>"sandwich","face_material"=>1,"core_material"=>3,"face_thickness"=>.0005,"core_thickness"=>.004))
        end
        kind=="no_stringers"&&(p["box.stringer_pitch"]=2.)
        kind=="angled_ribs"&&(p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>85.,"pitch"=>.5)])
        m=skin_build(p);rows=W.skin_buckling_payload(m)
        elapsed=@elapsed W.skin_buckling_payload(m)
        @test !isempty(rows)
        @test length(unique(row["key"] for row in rows))==length(rows)
        ready=filter(row->row["status"]=="ready",rows)
        @test !isempty(ready)
        kind=="runout"||(@test length(ready)==length(rows))
        all_ids=[element["eid"] for row in ready for element in row["elements"]]
        @test length(all_ids)==length(unique(all_ids))
        actual=Dict(eid=>(group,index) for group in m.groups if group.kind in (:quad,:tria)&&W.component_base_pid(group.pid) in (W.PID_SKIN_UPPER,W.PID_SKIN_LOWER,W.PID_STRINGER_FLANGE) for (index,eid) in enumerate(group.eids))
        if kind!="runout"
            @test Set(all_ids)==Set(keys(actual))
            @test sum(row["area_m2"] for row in rows)≈sum(W.weight_shell_area(W.element_points(m,group,index)) for (group,index) in values(actual))
        end
        for row in ready
            left=first(row["boundary_labels"])
            @test row["strip_index"]==(startswith(left,"S") ? parse(Int,left[2:end])+1 : 1)
            @test row["length_m"]≈(row["side_lengths_m"]["left"]+row["side_lengths_m"]["right"])/2
            @test row["width_m"]≈(row["side_lengths_m"]["inboard"]+row["side_lengths_m"]["outboard"])/2
            @test row["area_m2"]≈sum(element["area_m2"] for element in row["elements"])
            @test row["max_normal_deviation_deg"]>=0&&row["skew_angle_deg"]>=0
            frame=row["frame"];axes=hcat(frame["x"],frame["y"],frame["normal"])
            @test transpose(axes)*axes≈Matrix{Float64}(I,3,3) atol=1e-12
            for element in row["elements"]
                group,index=actual[element["eid"]]
                @test element["area_m2"]≈W.weight_shell_area(W.element_points(m,group,index))
                @test isposdef(Symmetric(skin_matrix(element["bending_matrix_Nm"])))
                u,v,_=W.shell_material_frame(m,group,index)
                c,s=sum(frame["x"].*u),sum(frame["x"].*v);projection=hypot(c,s);c/=projection;s/=projection
                @test skin_matrix(element["stress_transform"])≈W.skin_stress_transform(c,s) atol=1e-12
                if kind in ("beam","swept","runout","no_stringers","angled_ribs")
                    e=m.params["material.E"];nu=m.params["material.nu"];h=element["thickness_m"]
                    expected=e*h^3/(12*(1-nu^2)).*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
                    @test skin_matrix(element["bending_matrix_Nm"])≈expected rtol=1e-11
                end
            end
        end
        if kind=="beam"
            baseline=rows;beam_model=m
            @test length(rows)==16
            for skin in ("upper","lower"),bay in 1:2
                block=filter(row->row["skin"]==skin&&row["rib_bay"]==bay,rows)
                @test [row["label"] for row in block]==["Front spar–S1","S1–S2","S2–S3","S3–Rear spar"]
                @test all(row["length_m"]≈.5 for row in block)
                @test first(block)["property_ids"]==block[2]["property_ids"] # two real strips may share a property
            end
            @test W.sensitivity_model_signature(m)==W.sensitivity_model_signature(skin_build(merge(p,Dict("stringers.skin_fixity_coefficient"=>2.))))
            @test_throws ArgumentError W.normalize_params(merge(p,Dict("stringers.skin_fixity_coefficient"=>0.)))
            @test_throws ArgumentError W.normalize_params(merge(p,Dict("stringers.skin_fixity_coefficient"=>NaN)))
        elseif kind=="swept"
            @test any(row["length_m"]>.5 for row in rows)
            @test any(row["skew_angle_deg"]>20 for row in rows)
        elseif kind=="runout"
            @test any(row["status"]=="unassessed" for row in rows)
        elseif kind=="shell_mixed"
            shell_rows=rows
            @test any(length(element["material_ids"])>1 for row in rows for element in row["elements"])
        elseif kind=="shell_offset"
            @test [row["key"] for row in rows]==[row["key"] for row in shell_rows]
            for (row,other) in zip(rows,shell_rows),(element,other_element) in zip(row["elements"],other["elements"])
                @test element["eid"]==other_element["eid"]
                @test skin_matrix(element["bending_matrix_Nm"])≈skin_matrix(other_element["bending_matrix_Nm"]) rtol=1e-10
            end
        elseif kind=="no_stringers"
            @test isempty(W.stiffened_panel_layout(m.grid).panels)
            @test length(rows)==4
            @test all(row["label"]=="Front spar–Rear spar" for row in rows)
        end
        if kind in ("beam","shell_offset","no_stringers")
            dir=joinpath(out,kind);mkpath(dir)
            payload=W.mesh_payload(m)
            @test payload["stiffened_panels"]["skin_buckling_panels"]==rows
            write(joinpath(dir,"payload.msgpack"),W.MsgPack.pack(payload))
            write(joinpath(dir,"schema.json"),JSON.json(W.schema_payload(m.params,"skin_fixture.toml")))
            write(joinpath(dir,"params.json"),JSON.json(m.params))
            open(joinpath(dir,"model.bdf"),"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
        end
        write(joinpath(out,kind*"_skin_panels.json"),JSON.json(rows))
        push!(coverage,Dict("kind"=>kind,"compartments"=>length(rows),"ready"=>length(ready),"elements"=>length(all_ids),"seconds"=>elapsed,
            "reasons"=>unique(row["reason"] for row in rows if row["status"]!="ready")))
        println(JSON.json(last(coverage)));flush(stdout)
    end
    # A missing skin face creates an unsupported boundary, not an apparently safe panel.
    m=deepcopy(beam_model);group=first(g for g in m.groups if g.kind===:quad&&W.component_base_pid(g.pid)==W.PID_SKIN_UPPER)
    deleteat!(group.eids,1);deleteat!(group.conn,1:4)
    damaged=W.skin_buckling_payload(m)
    @test any(row["status"]=="unassessed"&&occursin("hole",row["reason"]) for row in damaged)
    m=deepcopy(beam_model);group=first(g for g in m.groups if g.kind===:quad&&W.component_base_pid(g.pid)==W.PID_SKIN_UPPER)
    push!(m.groups,deepcopy(group))
    @test any(row["status"]=="unassessed"&&occursin("duplicated",row["reason"]) for row in W.skin_buckling_payload(m))
    m.params["imported.native"]=nothing
    @test isempty(W.skin_buckling_payload(m))
    if length(ARGS)>1
        previous=abspath(ARGS[2])
        for name in ("axial_euler_fixture.json","axial_sol106_euler_fixture.json")
            fixture=JSON.parsefile(joinpath(previous,"beam",name));cases=fixture["cases"]
            for case in cases;case["stress_units"]="Pa";case["force_units"]="N/m";end
            checks=Any[]
            for panel in baseline,case in cases
                integral=zeros(3)
                for element in panel["elements"]
                    record=case["element_results"][string(element["eid"])];forces=record["forces"]
                    localforce=[forces["fx"],forces["fy"],forces["fxy"]]
                    @test all(isfinite,localforce)
                    integral.+=element["area_m2"].*(skin_matrix(element["stress_transform"])*localforce)
                end
                push!(checks,Dict("key"=>panel["key"],"case_id"=>case["case_id"],"membrane_N_per_m"=>collect(integral/panel["area_m2"])))
            end
            write(joinpath(out,replace(name,"euler"=>"skin")),JSON.json(Dict("skinBucklingPanels"=>baseline,"cases"=>cases,"membrane_checks"=>checks,
                "recovery_provenance"=>"Reused unchanged generated-beam FE-model recovery; skin plate assessment does not modify solver inputs or results")))
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"backend_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"coverage"=>coverage)))
