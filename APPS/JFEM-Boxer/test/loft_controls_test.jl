using Test, TOML
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
selected(group)=isempty(ARGS)||group in ARGS

# Independently specified polygon with unequal upper/lower knot spacing, a
# finite trailing-edge gap, and a displaced maximum thickness.
const COORDS="""Test profile
1.0 0.01
0.75 0.04
0.35 0.10
0.10 0.06
0.0 0.0
0.15 -0.025
0.50 -0.04
0.85 -0.02
1.0 -0.01
"""

if selected("xfoil")
@testset "Embedded XFoil single-element coordinates" begin
    profile=W.parse_xfoil_airfoil(COORDS;filename="section one.dat")
    af=W.airfoil_from_profile(profile;expected_source="file")
    @test af.source===:file
    @test profile["filename"]=="section one.dat"
    @test length(profile["raw_sha256"])==64
    @test af.xu==[0.,.1,.35,.75,1.]
    @test af.xl==[0.,.15,.5,.85,1.]
    @test af.zu[end]-af.zl[end]≈.02
    plain=join(split(COORDS,'\n')[2:end],'\n')
    @test W.parse_xfoil_airfoil(plain)["zu"]≈af.zu
    reverse_order=join(reverse(split(strip(plain),'\n')),'\n')
    @test W.parse_xfoil_airfoil(reverse_order)["zu"]≈af.zu
    ises=replace(COORDS,"Test profile\n"=>"Test profile\n-2.0 3.0 -1.0 1.0\n")
    @test W.parse_xfoil_airfoil(ises)["zl"]≈af.zl
    bom=W.parse_xfoil_airfoil("\ufeff"*COORDS)
    @test bom["name"]=="Test profile"
    @test bom["raw_sha256"]!=profile["raw_sha256"]
    lednicer="Test profile\n5 5\n0 0\n.1 .06\n.35 .10\n.75 .04\n1 .01\n0 0\n.15 -.025\n.5 -.04\n.85 -.02\n1 -.01\n"
    @test W.parse_xfoil_airfoil(lednicer)["zu"]≈af.zu
    angle=.31;scale=4.2;offset=(3.,-7.)
    transformed="Rotated profile\n"*join((begin
        x,z=parse.(Float64,split(line));
        "$(offset[1]+scale*(cos(angle)*x-sin(angle)*z)) $(offset[2]+scale*(sin(angle)*x+cos(angle)*z))"
    end for line in split(strip(plain),'\n')),'\n')
    rigid=W.parse_xfoil_airfoil(transformed)
    @test rigid["xu"]≈af.xu atol=2e-14
    @test rigid["zu"]≈af.zu atol=2e-14
    @test_throws ArgumentError W.parse_xfoil_airfoil(COORDS*"999 999\n")
    @test_throws ArgumentError W.parse_xfoil_airfoil(COORDS*"NaN 0\n")
    @test_throws ArgumentError W.parse_xfoil_airfoil("NaN 0\n"*plain)
    @test_throws ArgumentError W.parse_xfoil_airfoil("binary\0header\n"*plain)
    @test_throws ArgumentError W.parse_xfoil_airfoil(COORDS;filename="folder/airfoil.dat")
    @test_throws ArgumentError W.airfoil_from_profile(profile;expected_source="uiuc")
    broken=deepcopy(profile);broken["zl"][3]=.2
    @test_throws ArgumentError W.airfoil_from_profile(broken)
    # Existing database provenance remains strict and distinct.
    uiuc=W.parse_uiuc_airfoil(COORDS;id="test.dat")
    @test W.airfoil_from_profile(uiuc).source===:uiuc
    @test uiuc["source_url"]==W.UIUC_AIRFOIL_URL*"test.dat"
    @test_throws ArgumentError W.airfoil_from_profile(merge(uiuc,Dict("source_url"=>"")))
end
end

function scheduled_params()
    p=W.default_params()
    p["airfoil.root_source"]="file";p["airfoil.root"]="section.dat"
    p["airfoil.root_profile"]=W.JSON.json(W.parse_xfoil_airfoil(COORDS;filename="section.dat"))
    p["airfoil.tip"]="NACA0018"
    p["airfoil.stations"]=[Dict("eta"=>.42,"source"=>"naca","code"=>"NACA4410")]
    p["loft.thickness_stations"]=[Dict("eta"=>1.,"tc"=>.08),Dict("eta"=>0.,"tc"=>.16),Dict("eta"=>.61,"tc"=>.11)]
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>2.),Dict("eta"=>.33,"twist"=>-4.),Dict("eta"=>1.,"twist"=>-1.)]
    return p
end

if selected("serialization")
@testset "Legacy geometry and offline study round trip" begin
    p=W.default_params();w=W.make_wing(p)
    @test isempty(w.thickness_envelopes)
    for eta in (0.,.17,.5,1.),xc in (.03,.3,.72,1.)
        left,right,t=W.airfoil_blend(w,eta)
        @test W.zup(w,eta,xc)==(1-t)*W.z_upper(left,xc)+t*W.z_upper(right,xc)
        @test W.zlo(w,eta,xc)==(1-t)*W.z_lower(left,xc)+t*W.z_lower(right,xc)
        @test W.twist(w,eta)==deg2rad(p["planform.twist_tip"])*eta
    end
    legacy=Dict("planform.twist_tip"=>-7.)
    migrated,_=W.normalize_params(legacy)
    @test W.twist(W.make_wing(migrated),.6)==deg2rad(-7.)*.6
    @test isempty(migrated["loft.twist_stations"])
    scheduled,_=W.normalize_params(scheduled_params())
    # Embed a local file also at an intermediate station and tip.
    file=W.parse_xfoil_airfoil(COORDS;filename="intermediate.dat")
    push!(scheduled["airfoil.stations"],Dict("eta"=>.7,"source"=>"file","code"=>file["id"],"profile"=>file))
    scheduled["airfoil.tip_source"]="file";scheduled["airfoil.tip"]="tip.dat"
    scheduled["airfoil.tip_profile"]=W.JSON.json(W.parse_xfoil_airfoil(COORDS;filename="tip.dat"))
    saved=W.params_to_toml(scheduled)
    restored,unknown=W.normalize_params(W.flatten_toml(TOML.parse(saved)))
    @test isempty(unknown)
    for key in ("loft.thickness_stations","loft.twist_stations","loft.thickness_interpolation","loft.twist_interpolation","airfoil.stations","airfoil.root_profile","airfoil.tip_profile")
        @test restored[key]==scheduled[key]
    end
    before,after=W.make_wing(scheduled),W.make_wing(restored)
    @test W.airfoil_section(after,3).source===:file
    for eta in (0.,.17,.42,.61,.7,.9,1.)
        @test W.upper_point(before,eta,.36)==W.upper_point(after,eta,.36)
    end
end
end

if selected("schedules")
@testset "Independent shape, thickness and twist schedules" begin
    for shape in ("linear","cosine"),thickness in ("linear","cosine"),twists in ("linear","cosine")
        p=scheduled_params();p["airfoil.interpolation"]=shape
        p["loft.thickness_interpolation"]=thickness;p["loft.twist_interpolation"]=twists
        w=W.make_wing(p)
        @test W.structural_wing(w)===w
        # Compare the precomputed upper envelope against a brute-force maximum
        # at every union knot; peaks can switch between different x/c locations.
        for eta in range(0.,1.;length=31)
            left,right,t=W.airfoil_blend(w,eta)
            knots=sort!(unique(vcat(left.xu,left.xl,right.xu,right.xl)))
            actual=maximum(W.zup(w,eta,x)-W.zlo(w,eta,x) for x in knots)
            i,_=W.airfoil_blend_index(w,eta)
            original=maximum((1-t)*(W.z_upper(left,x)-W.z_lower(left,x))+t*(W.z_upper(right,x)-W.z_lower(right,x)) for x in knots)
            @test W.maximum_section_gap(w.thickness_envelopes[i],t)≈original rtol=3e-14
            expected=W.loft_scalar(w.thickness_etas,w.thickness_values,Symbol(thickness),eta)
            @test actual≈expected rtol=3e-14
            for x in (.05,.3,.56,.89)
                midpoint=((1-t)*(W.z_upper(left,x)+W.z_lower(left,x))+t*(W.z_upper(right,x)+W.z_lower(right,x)))/2
                @test (W.zup(w,eta,x)+W.zlo(w,eta,x))/2≈midpoint atol=3e-17
            end
        end
        @test rad2deg(W.twist(w,.33))≈-4
        weight=twists=="cosine" ? (1-cospi(.25))/2 : .25
        @test rad2deg(W.twist(w,.33*.25))≈2*(1-weight)-4weight
        target=thickness=="cosine" ? .16*(1-(1-cospi(.25))/2)+.11*(1-cospi(.25))/2 : .16*.75+.11*.25
        @test W.loft_scalar(w.thickness_etas,w.thickness_values,w.thickness_interpolation,.61*.25)≈target
        no_thickness=copy(p);no_thickness["loft.thickness_stations"]=Any[]
        old=W.make_wing(no_thickness)
        @test W.camber_point(w,.23,.37)==W.camber_point(old,.23,.37)
        @test all(e->e in W.with_planform_stations(w,[0.,1.]),(.33,.61))
        @test all(e->e in W.vlm_mesh(w,2,4).etas,(.33,.61))
    end
    p=scheduled_params();p["loft.twist_stations"]=[Dict("eta"=>.3,"twist"=>3.)]
    p["loft.thickness_stations"]=[Dict("eta"=>.4,"tc"=>.12)]
    w=W.make_wing(p)
    @test all(eta->W.twist(w,eta)==deg2rad(3.),(0.,.2,.7,1.))
    @test all(eta->W.loft_scalar(w.thickness_etas,w.thickness_values,:linear,eta)==.12,(0.,.2,.7,1.))
    p["loft.twist_stations"]=[Dict("eta"=>0.,"twist"=>0.),Dict("eta"=>.5,"twist"=>18.),Dict("eta"=>1.,"twist"=>0.)]
    @test !isempty(W.vlm_incidence_warnings(W.make_wing(p),p).warnings)
end
end

if selected("fuel")
@testset "Fuel volume follows thickness and schedule validation" begin
    p=W.default_params();p["airfoil.root"]="NACA0012";p["airfoil.tip"]="NACA0012";p["airfoil.interpolation"]="linear"
    p["box.front_spar_xc"]=.15;p["box.rear_spar_xc"]=.65
    w=W.make_wing(p);base=W.enclosed_loft_volume(w,.15,.65,0.,1.)
    tc=maximum(W.zup(w,0.,x)-W.zlo(w,0.,x) for x in W.airfoil_knots(w))
    p["loft.thickness_stations"]=[Dict("eta"=>0.,"tc"=>2tc)]
    scaled=W.make_wing(p)
    @test W.enclosed_loft_volume(scaled,.15,.65,0.,1.)≈2base rtol=3e-12
    p["loft.thickness_stations"]=[Dict("eta"=>0.,"tc"=>tc),Dict("eta"=>1.,"tc"=>2tc)]
    varying=W.make_wing(p)
    cr,ct=w.chord_root,w.chord_tip;d=ct-cr
    # Integral c(eta)^2 * (1+eta) analytically, independent of quadrature.
    expected=w.semispan*W.airfoil_box_area(w.root_af,.15,.65)*(1.5cr^2+(5/3)*cr*d+(7/12)*d^2)
    @test W.enclosed_loft_volume(varying,.15,.65,0.,1.)≈expected rtol=3e-12
    @test W.enclosed_loft_volume(varying,p,0.,1.)≈expected rtol=3e-12
    for rows in ([Dict("eta"=>-.1,"tc"=>.12)], [Dict("eta"=>.5,"tc"=>0.)], [Dict("eta"=>.5,"tc"=>1.1)], [Dict("eta"=>.5,"tc"=>.12),Dict("eta"=>.5,"tc"=>.14)], [Dict("eta"=>true,"tc"=>.12)])
        @test_throws ArgumentError W.normalize_loft_stations(rows,"loft.thickness_stations")
    end
    @test_throws ArgumentError W.normalize_loft_stations([Dict("eta"=>.5,"twist"=>45.)],"loft.twist_stations")
    @test_throws ArgumentError W.normalize_loft_stations([Dict("eta"=>.5,"twist"=>NaN)],"loft.twist_stations")
    @test_throws ArgumentError W.normalize_loft_stations([Dict("eta"=>i/101,"tc"=>.12) for i in 1:101],"loft.thickness_stations")
    p["loft.twist_interpolation"]="spline"
    @test_throws ArgumentError W.normalize_params(p)
end
end

if selected("integration")
@testset "Generated structural, aerodynamic and fuel surfaces share loft" begin
    p=scheduled_params()
    p["airfoil.n_points"]=21
    p["box.rib_pitch"]=20.;p["box.stringer_pitch"]=5.
    p["mesh.elements_between_ribs"]=1;p["mesh.elements_between_stringers"]=1
    p["mesh.elements_spar_height"]=1;p["mesh.aero_chord_points"]=11
    p["leading_edge.enabled"]=false;p["properties.rib_stiffeners_enabled"]=false
    p["fuel.enabled"]=true;p["fuel.start_rib"]=1;p["fuel.end_rib"]=2
    model=W.build_model(W.normalize_params(p)[1]);g=model.grid;w=model.wing
    @test all(eta->eta in g.etas,(.33,.61))
    # The registry records (i,j,k) for every structured structural node.
    for (id,key) in enumerate(model.node_keys[1:model.n_struct])
        i,j,k=key
        k in (0,g.nh) || continue
        expected=W.grid_point(g,i,j,k)
        @test model.xyz[3id-2:3id]≈collect(expected) atol=1e-12
    end
    summary=W.fuel_summary(model)
    tank=W.fuel_surface_segment(model,summary)
    @test tank!==nothing
    # Every displayed tank vertex lies on one of the same scaled/rotated
    # airfoil surfaces; invert the section's rigid placement to recover x/c.
    for i in 1:39:length(tank.xyz)
        point=tank.xyz[i:i+2];eta=(point[2]-w.root_ref_y)/w.semispan
        xr,_,zr=W.reference_point(w,eta);c=W.chord(w,eta);s,cth=sincos(W.twist(w,eta))
        x=(point[1]-xr)/c-(w.twist_axis-w.sweep_ref);z=(point[3]-zr)/c
        xc=w.twist_axis+cth*x-s*z;zc=s*x+cth*z
        @test min(abs(zc-W.zup(w,eta,xc)),abs(zc-W.zlo(w,eta,xc)))<2e-12
    end
end
end
