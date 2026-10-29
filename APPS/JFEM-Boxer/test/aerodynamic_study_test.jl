using Test,WingFEGen
const W=WingFEGen
const V=W.VortexLattice
function aero_fixture()
    p=W.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","movable_surfaces.items"=>Any[]))
    p
end
small_settings(extra=Dict{String,Any}())=merge(Dict{String,Any}("chord_spacing"=>"uniform","derivatives"=>false,"chord_panels"=>4,"span_panels"=>8,"control_chord_panels"=>1,
    "speed"=>30.,"atmosphere"=>"manual","density"=>1.225,"speed_of_sound"=>340.,"compressibility"=>"incompressible"),extra)
function direct_oracle(p,raw)
    _,w,controls=W.aerodynamic_geometry(p);s=W.aerodynamic_settings(raw,controls);patches=W.aerodynamic_mesh(w,controls,s)
    origin=(w.root_ref_x,w.root_ref_y,w.root_ref_z+W.vertical_shift(w,0.))
    grids=[patch.grid.-reshape(collect(origin),3,1,1) for patch in patches]
    ratios=[zeros(2,size(g,2)-1,size(g,3)-1).+[.5,.75] for g in grids]
    system=V.System(grids;ratios=ratios);refpoint=W.aerodynamic_reference(w,s).-origin
    ref=V.Reference(w.area,w.mac,w.span,collect(refpoint),s["speed"])
    fs=V.Freestream(s["speed"],deg2rad(s["alpha"]),deg2rad(s["beta"]),deg2rad.([s["p"],s["q"],s["r"]]))
    V.steady_analysis!(system,ref,fs;symmetric=false,derivatives=false,surface_id=fill(1,length(grids)),xhat=V.freestream_velocity(fs)/s["speed"])
    # The package Wind moment adapter mixes construction/dynamics signs.
    # Use its independent dimensional Body moment sum, then the physical
    # W-prime axes from the reference convention, before normalization.
    cf,_=V.body_forces(system;frame=V.Wind());_,mb=V.body_forces(system;frame=V.Body())
    Q=W.diagm([-1.,1.,-1.]);lengths=[w.span,w.mac,w.span]
    cm=Q*V.body_to_wind(fs)*Q*(mb.*lengths)./lengths
    return (cf,cm),V.far_field_drag(system)
end
@testset "Full-wing independent VLM and primary package oracle" begin
    p=aero_fixture();p["box.rib_pitch"]=-1.;p["material.E"]="invalid FE input, intentionally ignored"
    before=deepcopy(p)
    for extra in (Dict("alpha"=>5.),Dict("alpha"=>3.,"beta"=>4.,"p"=>.8,"q"=>-.3,"r"=>.2))
        s=small_settings(extra);result=W.run_aerodynamic_study(p,s);c=only(result["cases"])
        (cf,cm),drag=direct_oracle(p,s)
        @test all(isapprox.(c["coefficients"]["wind"]["force"],cf;rtol=1e-9,atol=1e-12))
        @test all(isapprox.(c["coefficients"]["wind"]["moment"],cm;rtol=1e-9,atol=1e-12))
        @test isapprox(c["CDi_trefftz"],drag;rtol=1e-9,atol=1e-12)
        @test c["residual_over_V"]<1e-10
        @test Set(r["side"] for r in c["panels"])==Set(["left","right"])
        @test .7-1e-9<=c["min_panel_aspect_ratio"]<=c["max_panel_aspect_ratio"]<=1.5+1e-9
        for k in 1:3
            @test isapprox(sum(r["force_N"][k] for r in c["panels"]),c["force_N"][k];atol=1e-10)
            @test isapprox(sum(r["force_per_m"][k]*r["width_m"] for r in c["strips"]),c["force_N"][k];atol=1e-10)
            @test isapprox(sum(r["moment_per_m"][k]*r["width_m"] for r in c["strips"]),c["moment_Nm"][k];atol=1e-10)
        end
        for panel in c["panels"]
            @test isapprox(panel["delta_pressure_Pa"]*panel["area_m2"],sum(panel["force_N"].*panel["normal"]);atol=1e-10)
            @test panel["force_wind_N"] ≈ W.aerodynamic_frame_matrices(c["condition"])["wind"]*panel["force_N"]
            @test isapprox(panel["delta_cp"]*c["flight"]["q_Pa"],panel["delta_pressure_Pa"];atol=1e-10)
        end
    end
    @test p==before
    zero=only(W.run_aerodynamic_study(p,small_settings(Dict("alpha"=>0.)))["cases"])
    @test abs(zero["coefficients"]["wind"]["force"][3])<1e-10
    roll=only(W.run_aerodynamic_study(p,small_settings(Dict("alpha"=>0.,"p"=>3.)))["cases"])
    @test roll["coefficients"]["body"]["moment"][1]<0 # roll damping
end
@testset "Symmetric PG parity with established half-wing solver" begin
    p=aero_fixture();s=small_settings(Dict("compressibility"=>"prandtl_glauert","alpha"=>5.))
    p["aero.alpha"]=5.;p["aero.speed"]=30.;p["aero.density"]=1.225;p["aero.speed_of_sound"]=340.;p["aero.atmosphere"]="manual";p["loads.load_factor"]=1.
    p["aero.chord_panels"]=4;p["aero.span_panels"]=8
    _,w,controls=W.aerodynamic_geometry(p);settings=W.aerodynamic_settings(s,controls)
    patch=only(filter(p->p.side=="right",W.aerodynamic_mesh(w,controls,settings)))
    mesh=(grid=patch.grid,metrics=patch.metrics,xcs=patch.xis,etas=patch.etas,initial_span_panels=8,max_strip_twist_deg=0.)
    old=W.solve_vlm(w,p;aerodynamic_mesh=mesh);new=only(W.run_aerodynamic_study(p,s)["cases"])
    @test isapprox(new["coefficients"]["wind"]["force"][3],old.summary["CL"];rtol=1e-8)
    @test isapprox(new["CDi_trefftz"],old.summary["CDi"];rtol=1e-8)
    @test all(isapprox.(new["force_N"],2 .*collect(old.summary["force_N"]);rtol=1e-8,atol=1e-10))
end
@testset "Aerodynamic controls, mirroring, sweeps and provenance" begin
    p=aero_fixture();p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Control A","kind"=>"flap","edge"=>"trailing","eta_start"=>.25,"eta_end"=>.75,
        "hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#ffcc00")]
    control(right,left=right,pair="symmetric")=Dict("Control A"=>Dict("source"=>"override","enabled"=>true,"pairing"=>pair,"right"=>right,"left"=>left))
    base=small_settings(Dict("alpha"=>0.,"controls"=>control(0.)))
    transported=W.aerodynamic_settings(W.JSON.parse(W.JSON.json(base)),W.normalize_movable_surfaces(p["movable_surfaces.items"]))
    @test transported["controls"]["Control A"]["right"]==0.
    up=only(W.run_aerodynamic_study(p,merge(base,Dict("controls"=>control(10.))))["cases"])
    @test up["coefficients"]["wind"]["force"][3]>.1
    @test abs(up["coefficients"]["body"]["moment"][1])<1e-10
    asymmetric=only(W.run_aerodynamic_study(p,merge(base,Dict("controls"=>control(10.,-10.,"antisymmetric"))))["cases"])
    @test abs(asymmetric["coefficients"]["wind"]["force"][3])<1e-9
    @test abs(asymmetric["coefficients"]["body"]["moment"][1])>.01
    @test any(!isempty(r["control"]) for r in asymmetric["panels"])
    sweep=W.run_aerodynamic_study(p,merge(base,Dict("mode"=>"sweep","sweeps"=>[Dict("variable"=>"alpha","start"=>-2.,"stop"=>4.,"count"=>3),Dict("variable"=>"control:Control A","start"=>0.,"stop"=>5.,"count"=>2)])))
    @test length(sweep["cases"])==6
    @test [c["condition"]["alpha"] for c in sweep["cases"]]==[-2.,-2.,1.,1.,4.,4.]
    @test sweep["geometry"]["movable_surfaces.items"][1]["deflection"]==0.
    @test sweep["version"]==W.AERODYNAMIC_STUDY_VERSION
    @test_throws ArgumentError W.run_aerodynamic_study(p,merge(base,Dict("mode"=>"sweep","sweeps"=>[Dict("variable"=>"alpha","start"=>0.,"stop"=>5.,"count"=>101),Dict("variable"=>"beta","start"=>0.,"stop"=>5.,"count"=>2)])))
    @test_throws ArgumentError W.run_aerodynamic_study(p,merge(base,Dict("speed"=>200.)))
    @test_throws ArgumentError W.run_aerodynamic_study(p,merge(base,Dict("controls"=>control(50.))))
    translated=deepcopy(p);translated["planform.root_ref_x"]=20.;translated["planform.root_ref_y"]=-5.;translated["planform.root_ref_z"]=7.
    moved=only(W.run_aerodynamic_study(translated,merge(base,Dict("controls"=>control(10.))))["cases"])
    @test all(isapprox.(moved["force_N"],up["force_N"];rtol=1e-9,atol=1e-9))
    @test all(isapprox.(moved["moment_Nm"],up["moment_Nm"];rtol=1e-9,atol=1e-9))
    finite=merge(base,Dict("alpha"=>3.,"beta"=>2.,"p"=>1.,"r"=>.5,"compressibility"=>"prandtl_glauert"))
    full=only(W.run_aerodynamic_study(p,finite)["cases"])
    half=only(W.run_aerodynamic_study(p,merge(finite,Dict("density"=>.6125)))["cases"])
    @test all(isapprox.(half["force_N"],.5 .* full["force_N"];rtol=1e-10,atol=1e-10))
    @test all(isapprox.(half["coefficients"]["wind"]["force"],full["coefficients"]["wind"]["force"];rtol=1e-10,atol=1e-12))
    @test full["residual_over_V"]<1e-10
    @test_throws ArgumentError W.run_aerodynamic_study(aero_fixture(),small_settings(Dict("chord_panels"=>16,"span_panels"=>40,"mode"=>"sweep","sweeps"=>[Dict("variable"=>"alpha","start"=>0.,"stop"=>5.,"count"=>101)])))
end

@testset "Physical winglet aspect ratios, wakes, budgets and derivatives" begin
    p=aero_fixture();p["loft.vertical_shift_stations"]=[Dict("eta"=>e,"shift_percent"=>z) for (e,z) in ((0.,0.),(.8,0.),(1.,45.))]
    stages=String[];mesh=only(W.run_aerodynamic_study(p,small_settings(Dict("max_panels"=>4096));mesh_only=true,progress=(s,d,t)->push!(stages,s))["cases"])
    @test .7-1e-9<=mesh["min_panel_aspect_ratio"]<=mesh["max_panel_aspect_ratio"]<=1.5+1e-9
    @test any(occursin("3D mesh quality",s) for s in stages)
    @test all(.7-1e-9<=q["aspect_ratio_min"]<=q["aspect_ratio_max"]<=1.5+1e-9 for q in mesh["panels"])
    @test !any(minimum(c[2] for c in q["corners"])<3.2-1e-8&&maximum(c[2] for c in q["corners"])>3.2+1e-8 for q in mesh["panels"] if q["side"]=="right")
    @test all(isapprox(sqrt(sum(abs2,mesh["wake_direction"])),1.;atol=1e-12) for _ in 1:1)
    @test all(isapprox(v[1],.75;atol=1e-10) for v in mesh["wake_origins"])
    @test_throws ArgumentError W.run_aerodynamic_study(p,small_settings(Dict("max_panels"=>16));mesh_only=true)
    simple=aero_fixture();settings=small_settings(Dict("derivatives"=>true,"chord_panels"=>2,"span_panels"=>3,"alpha"=>4.,"p"=>.2))
    solved=only(W.run_aerodynamic_study(simple,settings)["cases"]);ds=solved["derivatives"]["rows"]
    @test Set(d["variable"] for d in ds)==Set(["alpha","beta","p","q","r","speed","altitude"])
    da=only(filter(d->d["variable"]=="alpha",ds));dp=only(filter(d->d["variable"]=="p",ds))
    @test 3<da["coefficients"]["wind"]["force"][3]<7
    @test dp["coefficients"]["body"]["moment"][1]<0
    @test all(iszero,only(filter(d->d["variable"]=="altitude",ds))["coefficients"]["wind"]["force"])
    h=.0005;plus=only(W.run_aerodynamic_study(simple,merge(settings,Dict("derivatives"=>false,"alpha"=>4+rad2deg(h))))["cases"])
    minus=only(W.run_aerodynamic_study(simple,merge(settings,Dict("derivatives"=>false,"alpha"=>4-rad2deg(h))))["cases"])
    @test isapprox(da["coefficients"]["wind"]["force"][3],(plus["coefficients"]["wind"]["force"][3]-minus["coefficients"]["wind"]["force"][3])/(2h);rtol=1e-5)
    for d in ds,frame in ("body","wind","stability"),kind in ("force","moment");@test all(isfinite,d["coefficients"][frame][kind]);end
end

@testset "Independent controls and derivative envelope" begin
    p=aero_fixture();p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Flap","kind"=>"flap","edge"=>"trailing","eta_start"=>0.,"eta_end"=>1.,"hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#ffcc00")]
    raw=small_settings(Dict("derivatives"=>true,"chord_panels"=>2,"span_panels"=>3,"alpha"=>4.,"controls"=>Dict("Flap"=>Dict("source"=>"override","enabled"=>true,"pairing"=>"independent","right"=>5.,"left"=>5.))))
    rows=only(W.run_aerodynamic_study(p,raw)["cases"])["derivatives"]["rows"]
    right=only(filter(d->d["variable"]=="control:Flap",rows));left=only(filter(d->d["variable"]=="control_left:Flap",rows))
    @test length(rows)==9
    @test right["coefficients"]["wind"]["force"][3]>0
    @test isapprox(right["coefficients"]["wind"]["force"][3],left["coefficients"]["wind"]["force"][3];rtol=1e-7)
    @test isapprox(right["coefficients"]["body"]["moment"][1],-left["coefficients"]["body"]["moment"][1];rtol=1e-7)
    bound=small_settings(Dict("derivatives"=>true,"chord_panels"=>2,"span_panels"=>3,"alpha"=>30.,"atmosphere"=>"isa1976","speed"=>.5W.isa1976(0.)["speed_of_sound_m_s"]))
    ds=only(W.run_aerodynamic_study(aero_fixture(),bound)["cases"])["derivatives"]["rows"]
    @test only(filter(d->d["variable"]=="alpha",ds))["method"]=="one-sided at analysis bound"
    @test only(filter(d->d["variable"]=="speed",ds))["method"]=="one-sided at analysis bound"
    @test only(filter(d->d["variable"]=="altitude",ds))["method"]=="one-sided at analysis bound"
    @test all(all(isfinite,d["coefficients"]["wind"]["force"]) for d in ds)
end
