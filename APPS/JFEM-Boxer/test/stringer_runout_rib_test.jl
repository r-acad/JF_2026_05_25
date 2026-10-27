# julia --project=. APPS/JFEM-Boxer/test/stringer_runout_rib_test.jl [private-output-directory]
using Test, LinearAlgebra, JSON, WingFEGen
const W=WingFEGen

function rib_runout_params(;model="beam",angle=-6.,span=3,chord=2,flange=.03,angled=false,pitch=.08,ribpitch=.25)
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.front_spar_xc"=>.20,"box.rear_spar_xc"=>.55,"box.end_eta"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","airfoil.n_points"=>21,
        "box.rib_pitch"=>ribpitch,"box.stringer_pitch"=>pitch,"box.stringer_angle"=>angle,
        "mesh.stringer_runout_ratio"=>.75,"mesh.elements_between_ribs"=>span,
        "mesh.elements_between_stringers"=>chord,"mesh.elements_spar_height"=>2,
        "mesh.elements_stringer_height"=>2,"mesh.aero_chord_points"=>9,
        "stringers.model"=>model,"properties.stringer_flange_width"=>flange,
        "leading_edge.enabled"=>false,"fuel.enabled"=>false,"aero.enabled"=>false,
        "loads.structure_inertia"=>false,"loads.cases"=>Any[],"output.solution"=>"101"))
    angled&&(p["ribs.masters"]=[Dict("eta"=>.5,"mode"=>"rear_spar_angle","angle"=>85.,"pitch"=>ribpitch)])
    p
end

rib_runout_build(p)=W.build_model(first(W.normalize_params(p)))
edge(a,b)=minmax(a,b)
point(m,n)=Tuple(m.xyz[3n-2:3n])
function skin_faces(m)
    panels=Dict(panel.id=>panel for panel in W.stiffened_panel_layout(m.grid).panels)
    [(eid=eid,nodes=group.conn[n*(q-1)+1:n*q],upper=W.component_base_pid(group.pid)==W.PID_SKIN_UPPER||
        W.component_base_pid(group.pid)==W.PID_STRINGER_FLANGE&&panels[W.stiffened_panel_id(group.pid)].upper)
     for group in m.groups if group.kind in (:quad,:tria)&&W.component_base_pid(group.pid) in (W.PID_SKIN_UPPER,W.PID_SKIN_LOWER,W.PID_STRINGER_FLANGE)
     for n in (group.kind===:quad ? 4 : 3,) for (q,eid) in enumerate(group.eids)]
end
function runout_rows(m)
    segments=[(eid=eid,a=group.conn[2q-1],b=group.conn[2q]) for group in m.groups
     if group.kind===:bar&&W.component_base_pid(group.pid)==W.PID_STRINGER_RUNOUT
     for (q,eid) in enumerate(group.eids)]
    next=Dict(segment.a=>segment for segment in segments)
    rows=Any[];visited=Set{Int}()
    for start in segments
        m.node_keys[start.a][3]>=0||continue
        chain=[start];push!(visited,start.eid)
        while haskey(next,last(chain).b)
            following=next[last(chain).b]
            following.eid in visited&&error("Cyclic or overlapping runout connector")
            push!(chain,following);push!(visited,following.eid)
        end
        push!(rows,(eid=start.eid,a=start.a,b=last(chain).b,segments=chain))
    end
    length(visited)==length(segments)||error("A runout connector has no physical-rib start")
    rows
end

function check_runout_model(m;expected_side=nothing,expected_eta=nothing,projected_area=.35)
    g=m.grid;faces=skin_faces(m);connectors=runout_rows(m)
    @test W.all_checks_pass(m)
    @test !isempty(connectors)
    counts=Dict{Tuple{Int,Int},Int}()
    for face in faces
        @test length(face.nodes)==length(unique(face.nodes))
        @test W.weight_shell_area([point(m,n) for n in face.nodes])>1e-12
        for (a,b) in zip(face.nodes,circshift(face.nodes,-1))
            counts[edge(a,b)]=get(counts,edge(a,b),0)+1
        end
    end
    @test all(count<=2 for count in values(counts))
    # The exterior has no holes or duplicate overlapping flange/skin sheets.
    # This rectangular fixture has exactly .35 m² projected area on each side.
    for upper in (false,true)
        area=sum(abs(sum(point(m,a)[1]*point(m,b)[2]-point(m,b)[1]*point(m,a)[2]
                    for (a,b) in zip(face.nodes,circshift(face.nodes,-1))))/2
                 for face in faces if face.upper==upper)
        @test area≈projected_area atol=2e-11
    end
    summary=Any[]
    for connector in connectors
        ka,kb=m.node_keys[connector.a],m.node_keys[connector.b]
        @test ka[1] in g.stringer_indices
        @test ka[2] in g.ribs
        @test kb[1] in (0,W.ni(g))
        @test kb[2]==ka[2]+1  # first skin mesh row after the physical rib
        @test kb[3]==ka[3]
        @test kb[3] in (0,g.nh)
        # Local spar corners can split a connector into a conforming chain;
        # its physical endpoints and retirement rib remain unchanged.
        @test all(haskey(counts,edge(segment.a,segment.b)) for segment in connector.segments)
        @test norm(collect(point(m,connector.b).-point(m,connector.a)))>1e-10
        plane=W.main_rib_plane(g,m.params,ka[2])
        @test abs(sum(plane.normal.*(point(m,connector.a).-plane.origin)))<1e-10
        expected_side===nothing||(@test kb[1]==(expected_side<0 ? 0 : W.ni(g)))
        expected_eta===nothing||(@test g.etas[ka[2]+1]≈expected_eta atol=1e-12)
        ordinal=findfirst(==(ka[1]),g.stringer_indices)
        push!(summary,Dict("stringer"=>ordinal,"upper"=>ka[3]==g.nh,"rib"=>findfirst(==(ka[2]),g.ribs),
            "start_eta"=>g.etas[ka[2]+1],"end_eta"=>g.etas[kb[2]+1],"side"=>kb[1]==0 ? "front" : "rear"))
        # No normal T beam or shell web continues outboard of this rib on
        # the retired physical stringer line; root-only connectors are valid.
        for group in m.groups
            W.component_base_pid(group.pid) in (W.PID_STRINGER,W.PID_STRINGER_WEB)||continue
            for node in group.conn
                key=m.node_keys[node]
                key[1]==ka[1]||continue
                @test key[2]<=ka[2]
            end
        end
    end
    # The fixed connector retains the requested square area and inertias.
    section=W.section_definition(m.params,W.PID_STRINGER_RUNOUT)
    @test section["type"]=="PBAR"
    @test section["area_m2"]≈5e-6 rtol=1e-14
    @test section["I1_m4"]≈(5e-6)^2/12 rtol=1e-14
    @test section["I2_m4"]≈(5e-6)^2/12 rtol=1e-14
    @test section["J_m4"]≈.1406*(5e-6)^2 rtol=1e-14
    layout=W.stiffened_panel_layout(g)
    @test all(panel.start_row in g.ribs&&panel.end_row in g.ribs for panel in layout.panels)
    # The old interior support tip joined compartments into unsupported
    # polygons. Every generated compartment here must have a closed supported
    # boundary, exactly covering the one physical skin/flange layer.
    compartments=W.skin_buckling_payload(m)
    @test !isempty(compartments)
    @test all(row["status"]=="ready" for row in compartments)
    ids=[element["eid"] for row in compartments for element in row["elements"]]
    @test length(ids)==length(unique(ids))
    @test Set(ids)==Set(face.eid for face in faces)
    @test all(row["length_m"]>0&&row["width_m"]>0 for row in compartments)
    columns=W.stringer_euler_payload(m)
    @test all(row["start_support"]=="rib"&&row["end_support"]=="rib" for row in columns)
    return summary
end

evidence=Dict{String,Any}()
checks=@testset "Stringer runouts terminate at the preceding physical rib" begin
    # Independent straight-line geometry: root margin .095, clearance .060,
    # transverse drift tan(6°). The event eta=.333 lies in the .25-.50 bay.
    threshold_eta=(.095-.75*.08)/tand(6.)
    @test .25<threshold_eta<.5
    for side in (-1,1),kind in ("beam","shell","blade")
        reference=nothing
        for (span,chord) in ((1,1),(3,2),(5,3))
            p=rib_runout_params(model=kind=="beam" ? "beam" : "shell",flange=kind=="blade" ? 0. : .03,
                angle=side*6.,span=span,chord=chord)
            m=rib_runout_build(p);rows=check_runout_model(m;expected_side=side,expected_eta=.25)
            @test length(rows)==2
            expected_stringer=side<0 ? 1 : 3
            @test all(row["stringer"]==expected_stringer for row in rows)
            signature=sort([(row["stringer"],row["upper"],row["rib"],row["side"]) for row in rows])
            reference===nothing ? (reference=signature) : (@test signature==reference)
            evidence["$(kind)_$(side)_$(span)x$(chord)"]=rows
        end
    end
    for side in (-1,1),kind in ("beam","shell")
        m=rib_runout_build(rib_runout_params(model=kind,angle=side*6.,angled=true))
        @test W.oriented_ribs(m.grid)
        rows=check_runout_model(m;expected_side=side)
        @test all(row["rib"]==2 for row in rows)
        evidence["angled_$(kind)_$side"]=rows
    end
    # Several strings may reach a spar within the same bay, including the
    # first bay. None may retain an unsupported normal section inside it.
    for side in (-1,1),kind in ("beam","shell")
        m=rib_runout_build(rib_runout_params(model=kind,angle=side*16.,pitch=.05,ribpitch=.5,span=4,chord=2,flange=.02))
        rows=check_runout_model(m;expected_side=side)
        @test count(row->row["rib"]==1,rows)>=4
        evidence["simultaneous_$(kind)_$side"]=rows
    end
    # Equality is not below the clearance limit. Crossing just after the
    # .50 rib retires the normal section at that rib, not the preceding one.
    for side in (-1,1)
        angle=side*atand((.095-.75*.08)/.5)
        rows=check_runout_model(rib_runout_build(rib_runout_params(angle=angle));expected_side=side,expected_eta=.5)
        evidence["exact_threshold_rib_$side"]=rows
    end
    p=rib_runout_params(angle=0.,pitch=.07);p["mesh.stringer_runout_ratio"]=1.
    constant=rib_runout_build(p)
    @test W.all_checks_pass(constant)
    @test isempty(runout_rows(constant))
    @test all(iszero,constant.grid.collapsed[constant.grid.stringer_indices.+1,:])
    # A local spar excursion can cross the threshold and return before the
    # next rib. Geometry anchors must catch it even with one span cell/bay.
    for kind in ("beam","shell")
        p=rib_runout_params(model=kind,angle=0.,span=1,chord=2)
        p["box.front_spar_points"]=[Dict("eta"=>.2,"dxc"=>0.),Dict("eta"=>.4,"dxc"=>.04),Dict("eta"=>.6,"dxc"=>0.)]
        rows=check_runout_model(rib_runout_build(p);expected_side=-1,expected_eta=.25,projected_area=.35-.04*(.6-.2)/2)
        evidence["local_spar_excursion_$kind"]=rows
    end
end

if !isempty(ARGS)
    mkpath(ARGS[1]);counts=Test.get_test_counts(checks)
    write(joinpath(ARGS[1],"rib_datum_runout_test_summary.json"),JSON.json(Dict("passed"=>true,
        "assertions"=>counts.passes+counts.cumulative_passes,"models"=>evidence),2))
end
