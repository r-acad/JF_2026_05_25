using Test, LinearAlgebra, TOML, WingFEGen
const RP=WingFEGen

function rib_reference_fixture()
    p=RP.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>48.,"planform.aspect_ratio"=>3.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "box.end_eta"=>.9,"box.rib_pitch"=>1.,"box.stringer_pitch"=>.8,
        "mesh.elements_between_ribs"=>2,"mesh.elements_between_stringers"=>2,
        "mesh.elements_spar_height"=>2,"box.front_spar_xc"=>.2,"box.rear_spar_xc"=>.8,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,
        "loads.cases"=>Any[],"ribs.masters"=>Any[]))
    return p
end

@testset "Rib reference persistence and legacy defaults" begin
    p=rib_reference_fixture()
    old=deepcopy(p);delete!(old,"ribs.plane");delete!(old,"ribs.chords_plane_angle")
    @test RP.canonical_study_parameters(old)
    restored,unknown=RP.restore_study_params(old)
    @test isempty(unknown)
    @test restored["ribs.plane"]=="vertical"
    @test restored["ribs.chords_plane_angle"]==0.
    @test first(RP.normalize_params(old))==first(RP.normalize_params(p))
    p["ribs.plane"]="normal_to_chords_plane";p["ribs.chords_plane_angle"]=8.
    p["ribs.masters"]=[Dict("eta"=>.45,"mode"=>"flight_direction","angle"=>90.,"pitch"=>1.,
        "plane"=>"normal_to_chords_plane","plane_angle"=>-3.)]
    roundtrip,_=RP.normalize_params(RP.flatten_toml(TOML.parse(RP.params_to_toml(p))))
    @test roundtrip["ribs.plane"]==p["ribs.plane"]
    @test roundtrip["ribs.chords_plane_angle"]==8.
    @test roundtrip["ribs.masters"][1]["plane_angle"]==-3.
    for bad in (89.,-89.,NaN,Inf,true)
        @test_throws ArgumentError RP.normalize_params(merge(p,Dict("ribs.chords_plane_angle"=>bad)))
        row=merge(p["ribs.masters"][1],Dict("plane_angle"=>bad))
        @test_throws ArgumentError RP.normalize_rib_tables([row],"ribs.masters")
    end
    @test_throws ArgumentError RP.normalize_params(merge(p,Dict("ribs.plane"=>"unknown")))
end

@testset "Global chords plane applies without masters and preserves closures" begin
    p=rib_reference_fixture();p["planform.dihedral"]=8.
    w=RP.make_wing(p);vertical=RP.physical_rib_layout(w,p)
    p["ribs.plane"]="normal_to_chords_plane";p["ribs.chords_plane_angle"]=8.
    layout=RP.physical_rib_layout(w,p)
    sheet=(0.,-sind(8.),cosd(8.))
    for row in layout.physical[2:end-1]
        plane=RP.main_rib_plane(w,layout,row.eta)
        @test collect(plane.normal)≈[0.,cosd(8.),sind(8.)] atol=1e-12
        @test abs(dot(plane.normal,sheet))<1e-12
    end
    for eta in (0.,p["box.end_eta"])
        @test RP.main_rib_plane(w,layout,eta).normal==(0.,1.,0.)
    end
    p["ribs.masters"]=[Dict("eta"=>.45,"mode"=>"flight_direction","angle"=>90.,"pitch"=>1.,"plane"=>"vertical")]
    overridden=RP.physical_rib_layout(w,p)
    @test collect(RP.main_rib_plane(w,overridden,.45).normal)≈[0.,1.,0.]
    @test 0<RP.main_rib_plane(w,overridden,.225).normal[3]<sind(8.)
    delete!(p["ribs.masters"][1],"plane")
    @test collect(RP.main_rib_plane(w,RP.physical_rib_layout(w,p),.45).normal)≈[0.,cosd(8.),sind(8.)]
    # A zero-inclination reference is precisely the legacy default geometry.
    p=rib_reference_fixture();legacy=RP.build_model(p)
    p["ribs.plane"]="normal_to_chords_plane";zero=RP.build_model(p)
    @test zero.xyz==legacy.xyz
    @test zero.spc==legacy.spc
    @test zero.node_keys==legacy.node_keys
end

@testset "Local tangent uses the true cambered mean surface" begin
    p=rib_reference_fixture()
    merge!(p,Dict("planform.taper_ratio"=>.8,"planform.dihedral"=>6.,"planform.twist_tip"=>-4.,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA4415","ribs.plane"=>"normal_to_midplane"))
    p["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),Dict("eta"=>1.,"shift_percent"=>10.)]
    w=RP.make_wing(p);layout=RP.physical_rib_layout(w,p);e=.45;x=.8;h=2e-6
    mid(e,x)=(RP.upper_point(w,e,x).+RP.lower_point(w,e,x))./2
    dx=(mid(e,x+h).-mid(e,x))./h;de=(mid(e+h,x).-mid(e,x))./h
    expected=normalize(cross(collect(dx),collect(de)))
    sheet=RP.local_midplane_normal(w,e,x)
    @test collect(sheet)≈expected atol=2e-6
    @test abs(sheet[1])>.01 # camber/twist contribute to the local chord tangent
    plane=RP.main_rib_plane(w,layout,e)
    @test abs(dot(plane.normal,expected))<2e-6
    @test abs(dot(plane.normal,plane.direction))<1e-12
    @test norm(collect(plane.origin).-collect(mid(e,x)))<1e-12
end

@testset "Generated ribs, caps, skin nodes and selected supports share the plane" begin
    p=rib_reference_fixture()
    merge!(p,Dict("planform.dihedral"=>8.,"ribs.plane"=>"normal_to_chords_plane","ribs.chords_plane_angle"=>8.,
        "supports.mode"=>"custom","supports.items"=>[Dict("rib"=>2,"target"=>"front_upper","dofs"=>"123")]))
    m=RP.build_model(p);g=m.grid
    @test RP.oriented_ribs(g)
    for j in g.ribs,i in 0:RP.ni(g),k in 0:g.nh
        plane=RP.main_rib_plane(g,p,j);point=RP.grid_point(g,i,j,k)
        @test abs(dot(plane.normal,point.-plane.origin))<1e-8
    end
    @test length(m.spc)==1
    node=only(m.spc);point=m.xyz[3*node-2:3*node]
    selected=RP.main_rib_plane(g,p,g.ribs[2])
    @test abs(dot(selected.normal,point.-selected.origin))<1e-8
    @test m.node_keys[only(m.spc)][2]==g.ribs[2]
    payload=RP.rib_layout_payload(m)
    @test payload["default_plane_reference"]=="normal_to_chords_plane"
    @test payload["ribs"][2]["plane_normal"]≈collect(selected.normal)
end
