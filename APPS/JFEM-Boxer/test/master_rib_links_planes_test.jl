using Test, TOML, WingFEGen
const W=WingFEGen
function fixture()
    p=W.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>48.,"planform.aspect_ratio"=>3.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"box.end_eta"=>.9,"box.rib_pitch"=>1.,
        "box.stringer_pitch"=>.8,"mesh.elements_between_ribs"=>2,
        "mesh.elements_between_stringers"=>2,"mesh.elements_spar_height"=>2,
        "box.front_spar_xc"=>.2,"box.rear_spar_xc"=>.8,"aero.enabled"=>false,
        "leading_edge.enabled"=>false,"fuel.enabled"=>false,
        "box.front_spar_points"=>[Dict{String,Any}("eta"=>.42,"dxc"=>0.,"point_id"=>"front_test")],
        "ribs.masters"=>[Dict{String,Any}("eta"=>.3,"mode"=>"flight_direction","angle"=>90.,"pitch"=>1.,
            "spar_link"=>Dict("edge"=>"front","point_id"=>"front_test"))]))
    p
end
@testset "Persistent spar identities and serialization" begin
    p=fixture();n,_=W.normalize_params(p)
    @test n["ribs.masters"][1]["eta"]==.42
    @test p["ribs.masters"][1]["eta"]==.3
    n["box.front_spar_points"][1]["eta"]=.52
    n["box.front_spar_points"][1]["dxc"]=.04
    pushfirst!(n["box.front_spar_points"],Dict("eta"=>.2,"dxc"=>0.))
    n,_=W.normalize_params(n)
    @test n["ribs.masters"][1]["eta"]==.52
    n["ribs.masters"][1]["mode"]="rear_spar_angle";n["ribs.masters"][1]["angle"]=80.
    n,_=W.normalize_params(n)
    @test isapprox(n["ribs.masters"][1]["eta"],.52-(.8-.24)*4*tand(10)/6;atol=1e-12)
    roundtrip,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(n))))
    @test roundtrip["ribs.masters"][1]["spar_link"]==n["ribs.masters"][1]["spar_link"]
    @test isapprox(roundtrip["ribs.masters"][1]["eta"],n["ribs.masters"][1]["eta"];atol=1e-12)
    old=n["ribs.masters"][1]["eta"]
    filter!(r->get(r,"point_id",nothing)!="front_test",n["box.front_spar_points"])
    n,_=W.normalize_params(n)
    @test !haskey(n["ribs.masters"][1],"spar_link")
    @test n["ribs.masters"][1]["eta"]==round(old;sigdigits=5)
end
@testset "Master plane normal to shifted local midplane" begin
    p=fixture();delete!(p["ribs.masters"][1],"spar_link")
    p["ribs.masters"][1]["eta"]=.5
    p["loft.vertical_shift_stations"]=[Dict("eta"=>0.,"shift_percent"=>0.),Dict("eta"=>1.,"shift_percent"=>10.)]
    p["ribs.masters"][1]["plane"]="normal_to_midplane"
    p,_=W.normalize_params(p);m=W.build_model(p);g=m.grid
    layout=W.physical_rib_layout(g.wing,p);plane=W.main_rib_plane(g.wing,layout,.5)
    @test isapprox(plane.normal[3]/plane.normal[2],.1;atol=1e-8)
    @test abs(sum(plane.normal.*W.local_midplane_normal(g.wing,.5,.8)))<1e-10
    j=findfirst(e->abs(e-.5)<1e-12,g.etas)-1
    @test abs(g.upper_etas[end,j+1]-g.lower_etas[end,j+1])>1e-4
    for (r,jr) in enumerate(g.ribs),i in 0:W.ni(g),k in 0:g.nh
        plane=W.main_rib_plane(g,p,jr);point=W.grid_point(g,i,jr,k)
        @test abs(sum(plane.normal.*(point.-plane.origin)))<1e-8
    end
    @test abs(W.main_rib_plane(g,p,first(g.ribs)).normal[3])<1e-14
    @test abs(W.main_rib_plane(g,p,last(g.ribs)).normal[3])<1e-14
    p["ribs.masters"][1]["plane"]="vertical";v=W.build_model(p)
    @test all(abs(W.main_rib_plane(v.grid,p,jr).normal[3])<1e-14 for jr in v.grid.ribs)
end
@testset "Matched lift and wing inertia use the same maneuver factor" begin
    p=fixture();merge!(p,Dict("loads.match_aircraft_lift"=>true,"loads.aircraft_mass"=>5000.,
        "loads.maneuver_factor"=>3.,"loads.load_factor"=>1.5,"loads.structure_inertia"=>false,
        "loads.fuel_accel_z"=>-.123,"loads.fuel_accel_x"=>.2,"fuel.enabled"=>true,"loads.fuel_percent"=>50.))
    p,_=W.normalize_params(p);m=W.build_model(p)
    @test W.inertia_acceleration_g(p)==(.2,0.,-3.)
    @test W.structure_inertia_enabled(p)
    dry=sum(r.mass for r in W.structural_mass_sources(m));fuel=W.fuel_mass_state(m)
    structure=W.structure_applied_loads(m);fuelloads=W.fuel_applied_loads(m;state=fuel)
    @test isapprox(sum(r.force[3] for r in structure),-dry*3*9.80665*1.5;rtol=1e-12)
    @test isapprox(sum(r.force[3] for r in fuelloads),-fuel["mass_kg"]*3*9.80665*1.5;rtol=1e-12)
    aero=W.aerodynamic_loads(m);plots=W.spanwise_load_data(m,aero)
    expected=(5000/2-dry-fuel["mass_kg"])*3*9.80665*1.5
    @test isapprox(plots["applied_force_N"][3],expected;rtol=1e-10)
    @test isapprox(aero.summary["lift_N"],5000*3*9.80665*1.5/2;rtol=1e-12)
    p["loads.maneuver_factor"]=-2.;@test W.inertia_acceleration_g(p)[3]==2.
    p["loads.match_aircraft_lift"]=false
    @test W.inertia_acceleration_g(p)[3]==-.123
    @test !W.structure_inertia_enabled(p)
end
