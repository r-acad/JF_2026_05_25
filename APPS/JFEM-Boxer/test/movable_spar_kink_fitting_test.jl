using Test, LinearAlgebra, WingFEGen
const W=WingFEGen

@testset "Oblique fitting intersects actual kink triangles" begin
    reg=W.NodeRegistry()
    # Vertical spar with a genuine chordwise kink at the middle station.
    for point in ([0.,0.,0.],[.1,.5,0.],[0.,1.,0.],[0.,0.,1.],[.1,.5,1.],[0.,1.,1.])
        W.add_free_node!(reg,point)
    end
    faces=[[1,2,5],[1,5,4],[2,3,6],[2,6,5]]
    origin=[0.,.35,0.];normal=[-.3,1.,0.];free(point)=W.add_free_node!(reg,point)
    chain,links=W.movable_spar_cut!(reg,faces,origin,normal,free,1e-11,"kink fixture")
    expected_eta=.35/.94;expected_x=.2expected_eta
    @test length(chain)==3 # Includes the real triangle diagonal intersection.
    @test all(isapprox(reg.xyz[3n-2],expected_x;atol=1e-12) for n in chain)
    @test all(isapprox(reg.xyz[3n-1],expected_eta;atol=1e-12) for n in chain)
    @test isapprox(reg.xyz[3first(chain)],0.;atol=1e-12)
    @test isapprox(reg.xyz[3last(chain)],1.;atol=1e-12)
    edges=Set(minmax(face[i],face[mod1(i+1,length(face))]) for face in faces for i in eachindex(face))
    for link in links
        @test minmax(link["nodes"]...) in edges
        @test sum(link["weights"])≈1
        @test reg.xyz[3link["ref"]-2:3link["ref"]]≈sum(weight.*reg.xyz[3node-2:3node] for (weight,node) in zip(link["weights"],link["nodes"]))
    end
end

@testset "Generated hinged control uses actual main-spar mesh edges" begin
  for pitch in (.2,1.)
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,"planform.taper_ratio"=>1.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.rib_pitch"=>.25,"box.stringer_pitch"=>pitch,"mesh.elements_between_ribs"=>2,"mesh.elements_spar_height"=>2,
        "box.rear_spar_points"=>[Dict("eta"=>.43,"dxc"=>-.035),Dict("eta"=>.67,"dxc"=>.02)],
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"loads.method"=>"analytic","loads.lift_total"=>1.,"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"loads.cases"=>Any[]))
    p["movable_surfaces.items"]=[Dict("name"=>"Control","kind"=>"aileron","edge"=>"trailing","eta_start"=>.05,"eta_end"=>.95,
        "hinge_start"=>.71,"hinge_end"=>.81,"front_spar_start"=>.83,"front_spar_end"=>.85,"hinge_z_start"=>0.,"hinge_z_end"=>.5,"deflection"=>0.,"color"=>"#29b6d1")]
    p["movable_structure.surfaces"]=[merge(W.MOVABLE_STRUCTURE_DEFAULTS,Dict("surface"=>"Control","span_bays"=>4,"span_elements"=>2,"chord_elements"=>4,"height_elements"=>2))]
    # Vary hinge height so the normal fitting plane cuts the real spar faces
    # instead of coinciding with a pre-existing vertical rib/spar edge.
    p["movable_structure.attachments"]=[merge(W.MOVABLE_ATTACHMENT_DEFAULTS,Dict("surface"=>"Control","eta"=>.67,"fitting"=>"shell_lugs","actuator"=>true))]
    # The real kink at .67 sits only .005 before a physical rib at .675.
    # Its coarse 370-mm chord cell has a .774-degree corner: warn while
    # retaining the model, then refine the long direction without moving geometry.
    @test W.build_model(first(W.normalize_params(p))).mesh_quality["status"]=="warning"
    p["mesh.elements_between_stringers"]=4
    m=W.build_model(first(W.normalize_params(p)))
    @test W.all_checks_pass(m)
    rear_faces=Vector{Int}[]
    for group in m.groups
        group.kind in (:quad,:tria)&&W.component_base_pid(group.pid)==W.PID_SPAR_WEB||continue
        nn=group.kind===:quad ? 4 : 3
        for index in eachindex(group.eids)
            nodes=group.conn[nn*(index-1)+1:nn*index]
            all(n->m.node_keys[n][1]==W.ni(m.grid),nodes)&&push!(rear_faces,nodes)
        end
    end
    @test any(length(face)==3 for face in rear_faces)
    edges=Set(minmax(face[i],face[mod1(i+1,length(face))]) for face in rear_faces for i in eachindex(face))
    joint=only(m.movable_structure["attachments"])
    @test !isempty(joint["interpolation_links"])
    for link in joint["interpolation_links"]
        @test minmax(link["nodes"]...) in edges
        point=m.xyz[3link["ref"]-2:3link["ref"]]
        @test abs(dot(point-joint["origin"],joint["lug_plane_normal"]))<1e-9
        @test point≈sum(weight.*m.xyz[3node-2:3node] for (weight,node) in zip(link["weights"],link["nodes"]))
    end
  end
end
