using Test, WingFEGen
const W=WingFEGen
@testset "Schrenk prescribed lift" begin
    for taper in (.25,.5,1.,1.4), e in (0.,.1,.6,1.)
        @test W.lift_fraction("schrenk",taper,e) ≈ .5*(W.lift_fraction("elliptical",taper,e)+W.lift_fraction("chord",taper,e))
    end
    p=W.default_params(); p["loads.distribution"]="schrenk"
    p["planform.trailing_edge_points"]=[Dict("eta"=>.4,"dxc"=>.2)]
    p["box.end_eta"]=.8 # exercise the moment of lift outside the structural end
    p["loads.load_factor"]=3.;p["loads.lift_total"]=7000.
    m=W.build_model(p)
    @test W.lift_fraction("schrenk",m.wing,0.)==0.
    @test W.lift_fraction("schrenk",m.wing,1.)≈1.
    @test sum(f[2] for f in W.analytic_lift_forces(m))≈21000.
    schrenk=W.analytic_lift_forces(m); sc=W.analytic_outboard_couple(m)
    m.params["loads.distribution"]="elliptical"
    ellipse=W.analytic_lift_forces(m); ec=W.analytic_outboard_couple(m)
    m.params["loads.distribution"]="chord"
    chord=W.analytic_lift_forces(m); cc=W.analytic_outboard_couple(m)
    @test all(schrenk[i][2]≈.5*(ellipse[i][2]+chord[i][2]) for i in eachindex(schrenk))
    @test all(isapprox(sc[i],.5*(ec[i]+cc[i]);atol=1e-9) for i in 1:3)
    normalized,unknown=W.normalize_params(Dict("loads.distribution"=>"schrenk"))
    @test isempty(unknown)
    @test normalized["loads.distribution"]=="schrenk"
    @test occursin("schrenk",W.params_to_toml(normalized))
end
