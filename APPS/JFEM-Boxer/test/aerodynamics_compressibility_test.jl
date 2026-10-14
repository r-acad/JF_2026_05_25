using Test, LinearAlgebra
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
const evidence=Dict{String,Any}()
function params(mach;extra=Dict())
    merge(W.default_params(),Dict{String,Any}("loads.method"=>"vortex_lattice",
        "loads.load_factor"=>1.0,"loads.torque_y"=>0.0,"aero.speed"=>120.0,
        "aero.speed_of_sound"=>(mach==0 ? 1e12 : 120.0/mach),
        "aero.span_panels"=>16,"aero.chord_panels"=>4,
        "planform.sweep"=>0.0,"planform.dihedral"=>0.0,"planform.twist_tip"=>0.0,
        "planform.taper_ratio"=>1.0,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "aero.alpha"=>2.0,"output.solution"=>"101"),extra)
end
@testset "Subsonic Prandtl-Glauert VLM" begin
    lowp=params(0.);low=W.solve_vlm(W.make_wing(lowp),lowp)
    highp=params(.5);high=W.solve_vlm(W.make_wing(highp),highp)
    @test isnothing(W.validate_params(highp))
    @test_throws ArgumentError W.validate_params(params(.50001))
    @test 1 < high.summary["CL"]/low.summary["CL"] < inv(sqrt(.75))
    @test high.summary["CDi"] > low.summary["CDi"] > 0
    # Independent primary reference: MIT AVL 3.52, AR=8 rectangular flat wing,
    # alpha=2 deg, chord cosine 4, span -sine 16, full Sref=16. Matching
    # M=0/M=.5 runs give CL=.16000/.17752 and CDff=.0010484/.0012821.
    # Compare the Mach increment: the two codes have slightly different
    # near-field/wake conventions even in the incompressible baseline.
    # https://web.mit.edu/drela/Public/web/avl/
    @test high.summary["CL"]/low.summary["CL"] ≈ .17752/.16000 rtol=.005
    @test high.summary["CDi"]/low.summary["CDi"] ≈ .0012821/.0010484 rtol=.005
    @test high.summary["pg_beta"] ≈ sqrt(.75)
    @test occursin("Prandtl-Glauert",high.summary["compressibility"])
    @test all(all(isfinite,l.force)&&all(isfinite,l.moment)&&isfinite(l.pressure) for l in high.panels)
    @test all(norm(collect(a.position).-collect(b.position))<1e-12 for (a,b) in zip(low.panels,high.panels))
    @test all(norm(collect(a.control_normal).-collect(b.control_normal))<1e-12 for (a,b) in zip(low.panels,high.panels))
    for mach in (0.,.2999,.3,.3001,.5)
        p=params(mach);result=W.solve_vlm(W.make_wing(p),p)
        evidence[string(mach)]=result.summary
    end
    @test abs(evidence["0.3001"]["CL"]-evidence["0.2999"]["CL"])<1e-4
    # At high aspect ratio and small incidence, the 3D method approaches the
    # two-dimensional Prandtl-Glauert lift-slope increase of 1/sqrt(1-M^2).
    long0=params(0.;extra=Dict("planform.aspect_ratio"=>100.,"aero.alpha"=>.25,"aero.span_panels"=>48))
    long5=params(.5;extra=Dict("planform.aspect_ratio"=>100.,"aero.alpha"=>.25,"aero.span_panels"=>48))
    cl0=W.solve_vlm(W.make_wing(long0),long0).summary["CL"]
    cl5=W.solve_vlm(W.make_wing(long5),long5).summary["CL"]
    @test cl5/cl0 ≈ inv(sqrt(.75)) rtol=.015
    evidence["high_aspect_lift_ratio"]=cl5/cl0
    # Geometry includes sweep, dihedral, twist, camber and translated root.
    complex=params(.5;extra=Dict("planform.sweep"=>20.,"planform.dihedral"=>8.,"planform.twist_tip"=>-5.,
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2410","planform.taper_ratio"=>.5,
        "planform.root_ref_x"=>11.,"planform.root_ref_y"=>-4.,"planform.root_ref_z"=>7.))
    model=W.build_model(complex);loads=W.aerodynamic_loads(model)
    @test loads.summary["force_error_N"]<1e-8
    @test loads.summary["moment_error_Nm"]<1e-7
    @test all(isfinite,loads.summary["force_N"])
    @test all(isfinite,loads.summary["moment_Nm"])
    evidence["translated_transfer"]=loads.summary
    # Ultimate multiplier applies after compressibility and exactly once.
    double=W.solve_vlm(W.make_wing(highp),merge(highp,Dict("loads.load_factor"=>2.0)))
    @test double.summary["force_N"] ≈ 2 .* high.summary["force_N"] rtol=1e-12
    @test double.summary["moment_Nm"] ≈ 2 .* high.summary["moment_Nm"] rtol=1e-12
    @test double.summary["CL"] == high.summary["CL"]
    # Reversal symmetry remains intact through the coordinate transformation.
    negative=W.solve_vlm(W.make_wing(highp),merge(highp,Dict("aero.alpha"=>-2.0)))
    @test negative.summary["CL"] ≈ -high.summary["CL"] rtol=1e-12
    @test negative.summary["CDi"] ≈ high.summary["CDi"] rtol=1e-12
end
if !isempty(ARGS)
    mkpath(ARGS[1]);write(joinpath(ARGS[1],"compressibility_summary.json"),W.JSON.json(evidence,2))
end
