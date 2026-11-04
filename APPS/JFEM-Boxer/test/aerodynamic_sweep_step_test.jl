using Test, WingFEGen
const SS=WingFEGen
row(a,b,step)=Dict{String,Any}("variable"=>"alpha","start"=>a,"stop"=>b,"step"=>step)
settings(rows)=SS.aerodynamic_settings(Dict{String,Any}("mode"=>"sweep","sweeps"=>rows),Any[])

@testset "Prescribed sweep steps retain the first station beyond End" begin
    for (a,b,h,expected) in ((0.,1.,.25,[0.,.25,.5,.75,1.]),
            (0.,1.,.3,[0.,.3,.6,.9,1.2]),(1.,0.,-.3,[1.,.7,.4,.1,-.2]),
            (1.,1.,.3,[1.]),(0.,.3,.1,[0.,.1,.2,.3]),(0.,1e-20,1.,[0.,1.]))
        s=settings([row(a,b,h)])
        values=collect(SS.aerodynamic_sweep_values(only(s["sweeps"])))
        @test values≈expected
        @test length(values)==SS.aerodynamic_sweep_count(only(s["sweeps"]))
        @test !haskey(only(s["sweeps"]),"count")
        cases=SS.aerodynamic_conditions(s,Any[])
        @test [c["alpha"] for c in cases]≈expected
    end
    # A legacy Study retains its exact count definition and endpoint.
    old=Dict{String,Any}("variable"=>"alpha","start"=>0.,"stop"=>1.,"count"=>4)
    s=settings([old]);@test collect(SS.aerodynamic_sweep_values(old))≈[0.,1/3,2/3,1.]
    @test only(s["sweeps"])["count"]==4
    beta=Dict{String,Any}("variable"=>"beta","start"=>0.,"stop"=>1.,"step"=>.6)
    cases=SS.aerodynamic_conditions(settings([row(0.,1.,.4),beta]),Any[])
    @test length(cases)==12
    @test maximum(c["alpha"] for c in cases)≈1.2
    @test maximum(c["beta"] for c in cases)≈1.2
    for bad in (row(0.,1.,0.),row(0.,1.,-.1),row(1.,0.,.1),row(0.,1.,Inf),
            row(0.,1.,NaN),row(0.,1.,true),row(0.,1.,1e-300),
            merge(row(0.,1.,.1),Dict("count"=>3)))
        @test_throws ArgumentError settings([bad])
    end
end
