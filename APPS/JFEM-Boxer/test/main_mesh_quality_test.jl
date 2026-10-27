using Test, LinearAlgebra, WingFEGen
const MQ = WingFEGen

function main_quality_parameters(;shell=false,angled=false)
    p=merge(MQ.default_params(),Dict{String,Any}(
        "planform.area"=>4.,"planform.aspect_ratio"=>4.,"planform.taper_ratio"=>.85,
        "planform.sweep"=>12.,"planform.dihedral"=>2.,"planform.twist_tip"=>-2.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.5,"box.stringer_pitch"=>.12,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>3,"leading_edge.enabled"=>true,
        "leading_edge.chord_elements"=>5,"leading_edge.rib_orientation"=>"flight_direction",
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","loads.lift_total"=>100.,"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"loads.cases"=>Any[]))
    # Almost coincident with an optional FE subdivision, never with a rib.
    p["box.front_spar_points"]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.38,"dxc"=>.025),Dict("eta"=>1.,"dxc"=>0.)]
    p["box.rear_spar_points"]=[Dict("eta"=>0.,"dxc"=>0.),Dict("eta"=>.375000001,"dxc"=>.015),Dict("eta"=>1.,"dxc"=>0.)]
    if shell
        p["stringers.model"]="shell";p["properties.stringer_flange_width"]=.025
    end
    angled&&(p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>92.,"pitch"=>.5)])
    first(MQ.normalize_params(p))
end

function main_skin_quality(m)
    ratios=Float64[];jacobians=Float64[]
    for group in m.groups
        group.kind in (:quad,:tria)||continue
        MQ.component_base_pid(group.pid) in (MQ.PID_SKIN_UPPER,MQ.PID_SKIN_LOWER,MQ.PID_LE_SKIN)||continue
        n=group.kind==:quad ? 4 : 3
        for e in eachindex(group.eids)
            nodes=group.conn[n*(e-1)+1:n*e];p=[m.xyz[3i-2:3i] for i in nodes]
            edges=[p[i%n+1]-p[i] for i in 1:n];ls=norm.(edges)
            push!(ratios,maximum(ls)/minimum(ls))
            normal=sum(cross(p[i],p[i%n+1]) for i in 1:n);normal/=norm(normal)
            for i in 1:n
                push!(jacobians,dot(cross(edges[i],-edges[mod1(i-1,n)]),normal)/(ls[i]*ls[mod1(i-1,n)]))
            end
        end
    end
    (;aspect=maximum(ratios),jacobian=minimum(jacobians))
end

@testset "Main box and nose retain conforming kinks within quality gates" begin
    # The original two-cell bay leaves an 8.31-degree corner beside the
    # two distinct spar kinks. Keep its valid faces visible with warnings.
    # An explicit span refinement resolves the warning.
    @test MQ.build_model(main_quality_parameters()).mesh_quality["status"]=="warning"
    @test MQ.build_model(main_quality_parameters(;shell=true,angled=true)).mesh_quality["status"]=="warning"
    for shell in (false,true),angled in (false,true)
        p=main_quality_parameters(;shell,angled)
        # Separate valid kink/frame/membership coverage from the intentionally
        # narrow tapered-runout fixture above. Real geometry changes are explicit.
        p["planform.taper_ratio"]=1.;p["mesh.elements_between_ribs"]=3
        for key in ("box.front_spar_points","box.rear_spar_points");p[key][2]["eta"]=.4;end
        m=MQ.build_model(p);g=m.grid
        @test MQ.all_checks_pass(m)
        @test main_skin_quality(m).jacobian>0
        @test main_skin_quality(m).aspect<=15
        # Spar kinks remain exact vertices shared by cap, skin and web. A
        # nearly coincident optional row may align, but no narrow strip is added.
        for (side,eta) in ((0,.4),(MQ.ni(g),.4))
            @test minimum(diff(g.etas))>.02
            ids=[n for (n,key) in enumerate(m.node_keys) if key[1]==side&&
                abs((m.xyz[3n-1]-m.wing.root_ref_y)/m.wing.semispan-eta)<1e-10]
            @test !isempty(ids)
            cap_attached=any(n->any(group->n in group.conn&&group.kind==:bar,m.groups),ids)
            shells_attached=all(n->sum(count(==(n),group.conn) for group in m.groups if group.kind in (:quad,:tria))>=2,ids)
            @test cap_attached
            @test shells_attached
        end
        @test all(eta->eta in g.etas,[row.eta for row in MQ.physical_rib_layout(m.wing,p).physical])
        actual_skins=Set(eid for group in m.groups if group.kind in (:quad,:tria)&&MQ.component_base_pid(group.pid) in
            (MQ.PID_SKIN_UPPER,MQ.PID_SKIN_LOWER,MQ.PID_STRINGER_FLANGE) for eid in group.eids)
        skin_rows=MQ.skin_buckling_payload(m)
        @test Set(e["eid"] for row in skin_rows for e in row["elements"])==actual_skins
        @test all(row->row["status"]=="ready",skin_rows)
        euler_rows=MQ.stringer_euler_payload(m)
        @test all(row->row["membership_complete"],euler_rows)
        components=MQ.component_buckling_payload(m)
        actual_webs=Set(eid for group in m.groups if group.kind in (:quad,:tria)&&MQ.component_base_pid(group.pid) in
            (MQ.PID_SPAR_WEB,MQ.PID_RIB_WEB) for eid in group.eids)
        actual_caps=Set(eid for group in m.groups if group.kind==:bar&&MQ.component_base_pid(group.pid) in
            (MQ.PID_SPAR_CAP,MQ.PID_RIB_STIFFENER) for eid in group.eids)
        @test Set(e["eid"] for row in components["web_panels"] for e in row["elements"])==actual_webs
        @test Set(e["eid"] for row in components["columns"] for station in row["stations"] for e in station["force_terms"])==actual_caps
        @test all(row->row["membership_complete"],components["web_panels"])
    end
end

@testset "Whole-loft anchors redistribute optional rows without moving ribs" begin
    p=main_quality_parameters();p["box.front_spar_points"]=Any[];p["box.rear_spar_points"]=Any[]
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.375000001,"twist"=>-1.),Dict("eta"=>1.,"twist"=>-3.)]
    m=MQ.build_model(p)
    @test .375000001 in m.grid.etas
    @test !(.375 in m.grid.etas)
    @test minimum(diff(m.grid.etas))>.1
    @test MQ.all_checks_pass(m)
    @test main_skin_quality(m).aspect<20
    p["loft.twist_stations"][2]["eta"]=.250000001
    close=MQ.build_model(p)
    @test close.mesh_quality["status"]=="warning"
    @test .250000001 in close.grid.etas
end
