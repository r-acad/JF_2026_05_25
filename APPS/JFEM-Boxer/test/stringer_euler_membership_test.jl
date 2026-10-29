# Geometry ownership is independent of the applicability of the rib-to-rib
# Euler end restraints. Runout sections must not invalidate the whole model.
using Test, JSON, WingFEGen
const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
function membership_params()
    p=W.default_params()
    merge!(p,Dict("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.rib_pitch"=>.5,
        "box.stringer_pitch"=>.08,"mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>4,"mesh.elements_stringer_height"=>2,"airfoil.n_points"=>21,
        "mesh.aero_chord_points"=>11,"loads.cases"=>Any[],"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"aero.enabled"=>false,
        "loads.lift_total"=>1.,"output.solution"=>"101","stringers.model"=>"beam"))
    p
end
function check_membership(m,rows)
    by_eid=Dict(eid=>g for g in m.groups for eid in g.eids)
    for row in rows
        @test row["membership_complete"]
        @test !isempty(row["stations"])
        own=Set(eid for g in m.groups if W.component_base_pid(g.pid) in
            (W.PID_STRINGER,W.PID_STRINGER_WEB,W.PID_STRINGER_FLANGE)&&
            W.stiffened_panel_id(g.pid)==row["panel_id"] for eid in g.eids)
        section=Set(term["eid"] for s in row["stations"] for term in s["force_terms"])
        @test Set(row["member_element_ids"])==union(own,section)
        @test all(haskey(by_eid,eid) for eid in row["member_element_ids"])
        @test any(W.component_base_pid(by_eid[eid].pid) in
            (W.PID_SKIN_UPPER,W.PID_SKIN_LOWER,W.PID_STRINGER_FLANGE) for eid in section)
        @test all(by_eid[term["eid"]].pid==term["pid"] for s in row["stations"] for term in s["force_terms"])
        @test row["length_m"]>0
        if row["end_restraints_complete"]
            @test row["status"]=="ready"
            @test isempty(row["reason"])
            @test row["start_support"]==row["end_support"]=="rib"
        else
            @test row["status"]=="unassessed"
            @test row["applicable"]
            @test occursin("defined runout-end restraint",row["reason"])
            @test "runout" in (row["start_support"],row["end_support"])
        end
    end
end
summary=Any[]
checks=@testset "Euler geometry membership survives unsupported end restraints" begin
    @testset "Terminal spar partitions at oblique end ribs" begin
        edge=(a=(1.,0.,0.),b=(.5,1.,0.))
        origin=(.2,.05,0.);axis=(.2,1.,0.)
        @test_throws ArgumentError W.euler_path_intersection([edge],origin,axis)
        point=W.euler_path_intersection([edge],origin,axis;extend_ends=true)
        @test abs(W.euler_dot(point.-origin,axis))<1e-12
        @test point[2]<0 # Partition reference only; never a shell extrapolation.
        @test all(isapprox.(W.euler_path_intersection(W.euler_edge_index([edge]),origin,axis;extend_ends=true),point))
        inside=(.2,.5,0.)
        @test W.euler_path_intersection([edge],inside,axis)==W.euler_path_intersection([edge],inside,axis;extend_ends=true)
        # Ambiguous physical crossings must still fail closed.
        folded=[(a=(0.,0.,0.),b=(1.,1.,0.)),(a=(1.,1.,0.),b=(0.,2.,0.))]
        @test_throws ArgumentError W.euler_path_intersection(folded,(.5,1.,0.),(1.,0.,0.);extend_ends=true)
    end
    for name in ("beam_flat","beam_swept","beam_runout","shell_flat","shell_blade","shell_swept","shell_runout")
        p=membership_params()
        startswith(name,"shell")&&(p["stringers.model"]="shell")
        name=="shell_blade"&&merge!(p,Dict("properties.stringer_flange_width"=>0.,"properties.stringer_flange_thickness"=>0.))
        (endswith(name,"swept")||endswith(name,"runout"))&&merge!(p,Dict("planform.sweep"=>35.,"planform.dihedral"=>7.,"planform.twist_tip"=>-4.))
        endswith(name,"runout")&&merge!(p,Dict("planform.taper_ratio"=>.55,"mesh.elements_between_ribs"=>4))
        m=W.build_model(first(W.normalize_params(p)))
        rows=W.stringer_euler_payload(m);check_membership(m,rows)
        compact=W.stringer_euler_payload(m;compact=true)
        @test [r["member_element_ids"] for r in rows]==[r["member_element_ids"] for r in compact]
        @test [r["status"] for r in rows]==[r["status"] for r in compact]
        failed=filter(r->r["status"]!="ready",rows)
        # A geometric runout may now stop on a physical rib. Availability
        # follows the actual end supports, rather than the fixture's name.
        @test length(failed)==count(r->r["start_support"]=="runout"||r["end_support"]=="runout",rows)
        push!(summary,Dict("name"=>name,"rows"=>length(rows),"ready"=>length(rows)-length(failed),
            "complete_membership"=>count(r->r["membership_complete"],rows),"runout_end_restraint_unavailable"=>length(failed)))
        if name=="beam_flat"
            # Missing geometry remains a genuine coverage error; no blanket
            # 'complete' flag is allowed merely because IDs are known.
            filter!(g->W.component_base_pid(g.pid)!=W.PID_SKIN_UPPER,m.groups)
            damaged=W.stringer_euler_payload(m)
            @test all(!r["membership_complete"]&&isempty(r["stations"])&&
                occursin("not covered",r["reason"]) for r in damaged if r["skin"]=="upper")
            @test all(r["status"]=="ready"&&r["membership_complete"] for r in damaged if r["skin"]=="lower")
        end
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"membership_summary.json"),JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"coverage"=>summary)))
