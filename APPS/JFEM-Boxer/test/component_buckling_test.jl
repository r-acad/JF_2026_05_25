# julia --project=. APPS/JFEM-Boxer/test/component_buckling_test.jl <private-output-directory>
using Test, JSON, MsgPack, LinearAlgebra, WingFEGen
const W=WingFEGen
out=abspath(ARGS[1]);mkpath(out)
function component_test_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>4,"mesh.elements_stringer_height"=>2,"airfoil.n_points"=>21,
        "mesh.aero_chord_points"=>11,"fuel.enabled"=>false,"leading_edge.enabled"=>false,
        "aero.enabled"=>false,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "loads.lift_total"=>1.,"output.solution"=>"101","output.n_modes"=>3,"stringers.model"=>"beam"))
    p
end
component_build(p)=W.build_model(first(W.normalize_params(p)))
component_matrix(rows)=reduce(vcat,permutedims.(rows))
function component_fixture(m,name,data)
    dir=joinpath(out,name);mkpath(dir)
    write(joinpath(dir,"params.json"),JSON.json(m.params))
    write(joinpath(dir,"schema.json"),JSON.json(W.schema_payload(m.params,"component-$name.toml")))
    write(joinpath(dir,"properties.json"),JSON.json(W.model_property_definitions(m)))
    write(joinpath(dir,"component_buckling.json"),JSON.json(data))
    open(joinpath(dir,"payload.msgpack"),"w") do io;MsgPack.pack(io,W.mesh_payload(m));end
    open(joinpath(dir,"model.bdf"),"w") do io;W.write_deck(IOContext(io,:full_precision=>true),m);end
end
summary=Dict{String,Any}("models"=>Any[])
checks=@testset "Physical component buckling metadata" begin
    baseline=nothing;base_model=nothing
    for variant in ("beam","composite","swept","no_stiffeners","no_stringers","shell")
        p=component_test_params()
        variant=="swept"&&merge!(p,Dict("planform.sweep"=>37.,"planform.dihedral"=>9.,"planform.twist_tip"=>-6.,"planform.taper_ratio"=>.6))
        variant=="no_stiffeners"&&(p["properties.rib_stiffeners_enabled"]=false)
        variant=="no_stringers"&&(p["box.stringer_pitch"]=2.)
        variant=="shell"&&(p["stringers.model"]="shell")
        if variant=="composite"
            for component in ("spar_web","rib_web")
                row=only(filter(row->row["component"]==component,p["materials.shells"]))
                merge!(row,Dict("kind"=>"sandwich","face_material"=>1,"core_material"=>3,"face_thickness"=>.0005,"core_thickness"=>.004))
            end
        end
        m=component_build(p);data=W.component_buckling_payload(m)
        elapsed=@elapsed W.component_buckling_payload(m)
        @test all(row["status"]=="ready" for rows in values(data) for row in rows)
        n_ribs=length(m.grid.ribs);n_stringers=length(m.grid.stringer_indices)
        @test count(row->row["kind"]=="spar_web",data["web_panels"])==2(n_ribs-1)
        @test count(row->row["kind"]=="spar_cap",data["columns"])==4(n_ribs-1)
        actual_shell=Dict(eid=>(group,index) for group in m.groups if group.kind in (:quad,:tria)&&W.component_base_pid(group.pid) in (W.PID_SPAR_WEB,W.PID_RIB_WEB) for (index,eid) in enumerate(group.eids))
        actual_bar=Dict(eid=>(group,index) for group in m.groups if group.kind==:bar&&W.component_base_pid(group.pid) in (W.PID_SPAR_CAP,W.PID_RIB_STIFFENER) for (index,eid) in enumerate(group.eids))
        webids=[element["eid"] for row in data["web_panels"] for element in row["elements"]]
        barids=[term["eid"] for row in data["columns"] for station in row["stations"] for term in station["force_terms"]]
        @test Set(webids)==Set(keys(actual_shell));@test length(webids)==length(unique(webids))
        @test Set(barids)==Set(keys(actual_bar));@test length(barids)==length(unique(barids))
        @test sum(row["area_m2"] for row in data["web_panels"])≈sum(W.weight_shell_area(W.element_points(m,group,index)) for (group,index) in values(actual_shell))
        for row in data["web_panels"]
            @test row["membership_complete"]
            @test Set(row["member_element_ids"])==Set(element["eid"] for element in row["elements"])
            @test row["length_m"]≈(row["side_lengths_m"]["upper"]+row["side_lengths_m"]["lower"])/2
            @test row["width_m"]≈(row["side_lengths_m"]["start"]+row["side_lengths_m"]["end"])/2
            rectangles=[];uvarea=0.
            for element in row["elements"]
                vertices=element["normalized_vertices_uv"]
                us=sort!(unique(first.(vertices)));vs=sort!(unique(last.(vertices)))
                @test length(us)==length(vs)==2
                @test all(-1e-12<=value<=1+1e-12 for value in vcat(us,vs))
                @test Set(Tuple.(vertices))==Set((u,v) for u in us for v in vs)
                uvarea+=(last(us)-first(us))*(last(vs)-first(vs));push!(rectangles,(us...,vs...))
                d=component_matrix(element["bending_matrix_Nm"]);@test isposdef(Symmetric(d));@test d≈d'
                group,index=actual_shell[element["eid"]];u,v,n=W.shell_material_frame(m,group,index)
                x=Tuple(row["frame"]["x"]);y=Tuple(row["frame"]["y"])
                # Recover a known global tensor through Boxer material axes,
                # then independently rotate to the equivalent panel frame.
                local_tensor=[-13. 4.;4. 7.];c,s=W.euler_dot(x,u),W.euler_dot(x,v);scale=hypot(c,s);c/=scale;s/=scale
                rotation=[c s;-s c];expected=rotation*local_tensor*rotation'
                transformed=component_matrix(element["stress_transform"])*[-13.,7.,4.]
                @test transformed≈[expected[1,1],expected[2,2],expected[1,2]]
                @test element["area_m2"]≈W.weight_shell_area(W.element_points(m,group,index))
            end
            @test uvarea≈1. atol=2e-12
            for i in eachindex(rectangles),j in 1:i-1
                a,b,c,d=rectangles[i];e,f,g,h=rectangles[j]
                @test max(0.,min(b,f)-max(a,e))*max(0.,min(d,h)-max(c,g))<1e-14
            end
        end
        for row in data["columns"]
            @test row["membership_complete"]
            @test length(row["end_grid_ids"])==2
            @test row["length_m"]≈sum(begin group,index=actual_bar[eid];points=W.element_points(m,group,index);W.norm3(points[2].-points[1]) end for eid in row["member_element_ids"])
            for station in row["stations"]
                part=only(station["parts"]);definition=W.section_definition(m.params,part["pid"]);material=W.bar_material_definition(m.params,part["pid"])
                @test part["area_m2"]≈definition["area_m2"]
                @test component_matrix(part["axial_matrix"])≈Diagonal(material["E"].*[definition["area_m2"],definition["I2_m4"],definition["I1_m4"]])
                @test only(station["force_terms"])["kind"]=="beam_axial"
            end
        end
        for blade in data["blades"]
            @test Set(blade["member_element_ids"])==Set(bar["eid"] for bar in blade["bars"])
            for bar in blade["bars"]
                @test bar["web_height_m"]≈bar["dimensions_m"][2]-bar["dimensions_m"][3]
                @test bar["web_thickness_m"]==bar["dimensions_m"][4]
            end
        end
        if variant in ("no_stiffeners","no_stringers")
            @test count(row->row["kind"]=="rib_web",data["web_panels"])==n_ribs
            @test isempty(data["blades"])
            @test all(row["kind"]=="spar_cap" for row in data["columns"])
        elseif variant!="swept"
            @test count(row->row["kind"]=="rib_web",data["web_panels"])==n_ribs*(n_stringers+1)
            @test length(data["blades"])==n_ribs*n_stringers
        end
        if variant=="beam";baseline=data;base_model=m;end
        variant in ("beam","composite")&&component_fixture(m,variant,data)
        push!(summary["models"],Dict("variant"=>variant,"webs"=>length(data["web_panels"]),"columns"=>length(data["columns"]),"blades"=>length(data["blades"]),"warm_metadata_seconds"=>elapsed))
        println("Component metadata validated: ",variant);flush(stdout)
    end
    # Topological defects must retain exact element membership and cannot
    # become a passing estimate through property grouping or missing results.
    broken=deepcopy(base_model)
    group=first(filter(g->W.component_base_pid(g.pid)==W.PID_SPAR_WEB,broken.groups))
    deleteat!(group.eids,2);deleteat!(group.conn,5:8)
    holes=W.component_buckling_payload(broken)
    @test any(row->row["status"]=="unassessed"&&!isempty(row["member_element_ids"]),holes["web_panels"])
    missing_ribs=deepcopy(base_model);filter!(g->W.component_base_pid(g.pid)!=W.PID_RIB_WEB,missing_ribs.groups)
    missing=W.component_buckling_payload(missing_ribs)
    @test all(row["status"]=="unassessed" for row in missing["columns"] if row["kind"]=="spar_cap")
    duplicate=deepcopy(base_model);group=first(filter(g->W.component_base_pid(g.pid)==W.PID_SPAR_WEB,duplicate.groups));group.eids[2]=group.eids[1]
    @test any(!row["membership_complete"]&&row["status"]=="unassessed" for row in W.component_buckling_payload(duplicate)["web_panels"])
    duplicate=deepcopy(base_model)
    web=first(filter(g->W.component_base_pid(g.pid)==W.PID_SPAR_WEB,duplicate.groups));cap=first(filter(g->W.component_base_pid(g.pid)==W.PID_SPAR_CAP,duplicate.groups))
    cap.eids[1]=web.eids[1];ambiguous=W.component_buckling_payload(duplicate)
    @test any(!row["membership_complete"]&&row["status"]=="unassessed" for row in ambiguous["web_panels"])
    @test any(!row["membership_complete"]&&row["status"]=="unassessed" for row in ambiguous["columns"])
    imported=deepcopy(base_model);imported.params["imported.native"]=Dict()
    @test all(isempty,values(W.component_buckling_payload(imported)))
    # Local blade applicability is independent of positive Euler section EI.
    bar=first(filter(group->W.component_base_pid(group.pid)==W.PID_RIB_STIFFENER,base_model.groups))
    section=W.section_definition(base_model.params,bar.pid);material=W.bar_material_definition(base_model.params,bar.pid)
    @test W.component_rf_blade_bar(section,material,1,bar.pid,.1)["web_height_m"]≈section["dimensions_m"][2]-section["dimensions_m"][3]
    not_t=merge(copy(section),Dict("shape"=>"BAR"));@test_throws ArgumentError W.component_rf_blade_bar(not_t,material,1,bar.pid,.1)
    bad_nu=merge(copy(material),Dict("nu"=>.5));@test_throws ArgumentError W.component_rf_blade_bar(section,bad_nu,1,bar.pid,.1)
    for key in W.COMPONENT_RF_FIXITY_KEYS
        p=component_test_params();p[key]=0.;@test_throws ArgumentError W.validate_params(p)
        p[key]=2.5;W.validate_params(p)
        changed=deepcopy(base_model);changed.params[key]=2.5
        @test W.sensitivity_definition(changed.params)==W.sensitivity_definition(base_model.params)
        data=W.component_buckling_payload(changed)
        expected=key==W.COMPONENT_RF_FIXITY_KEYS[1] ? "spar_web" : key==W.COMPONENT_RF_FIXITY_KEYS[2] ? "rib_web" : key==W.COMPONENT_RF_FIXITY_KEYS[3] ? "spar_cap" : "rib_stiffener"
        @test all(row["fixity_coefficient"]==2.5 for rows in (data["web_panels"],data["columns"]) for row in rows if row["kind"]==expected)
    end
end
counts=Test.get_test_counts(checks)
summary["tests"]=Dict("passed"=>counts.passes+counts.cumulative_passes,"failed"=>counts.fails+counts.cumulative_fails,"errors"=>counts.errors+counts.cumulative_errors)
write(joinpath(out,"backend_summary.json"),JSON.json(summary))
