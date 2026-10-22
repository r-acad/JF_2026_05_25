using Test, Random, LinearAlgebra, JSON
include(joinpath(@__DIR__,"..","..","src","solver","beam_stress_envelope.jl"))
out=abspath(only(ARGS));mkpath(out)
function t_property(b=.04,h=.05,tf=.002,tw=.002)
    hw=h-tf;af=b*tf;aw=hw*tw;yc=(aw*hw/2+af*(hw+tf/2))/(af+aw)
    Dict{String,Any}("TYPE"=>"T","DIMS"=>[b,h,tf,tw],"A"=>af+aw,
        "I1"=>tw*hw^3/12+aw*(hw/2-yc)^2+b*tf^3/12+af*(hw+tf/2-yc)^2,
        "I2"=>hw*tw^3/12+tf*b^3/12,"J"=>(hw*tw^3+b*tf^3)/3)
end
forces(;n=0.,vy=0.,vz=0.,t=0.,ma1=0.,ma2=0.,mb1=0.,mb2=0.)=Dict{String,Any}(
    "axial"=>n,"shear_1"=>vy,"shear_2"=>vz,"torque"=>t,
    "moment_a1"=>ma1,"moment_a2"=>ma2,"moment_b1"=>mb1,"moment_b2"=>mb2)
checks=@testset "Thin-walled T equivalent-stress envelope" begin
    p=t_property();b,h,tf,tw=p["DIMS"];hw=h-tf
    yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/p["A"];yf=hw+tf/2
    vm(f;kw...)=beam_t_stress_envelope(p,f;kw...)["von_mises"]
    @test vm(forces())==0
    @test vm(forces(n=1234.))≈1234/p["A"]
    @test vm(forces(n=-1234.))≈1234/p["A"]
    @test vm(forces(ma1=23.))≈23*max(yc,h-yc)/p["I1"]
    @test vm(forces(mb2=-17.))≈17*b/(2p["I2"])
    @test vm(forces(t=11.))≈sqrt(3)*11*max(tf,tw)/p["J"]
    vy=13.;webtau=vy*yc^2/(2p["I1"]);flangetau=vy*(yf-yc)*b/(2p["I1"])
    @test vm(forces(vy=vy))≈sqrt(3)*max(webtau,flangetau)
    vz=19.;torquebound=vz*(yf-yc)
    @test vm(forces(vz=vz))≈sqrt(3)*max(vz*tw^2/(8p["I2"])+torquebound*tw/p["J"],vz*b^2/(8p["I2"])+torquebound*tf/p["J"])
    f=forces(n=-1200.,vy=13.,vz=-19.,t=11.,ma1=23.,mb1=-7.,ma2=-17.,mb2=5.)
    r=beam_t_stress_envelope(p,f);meta=r["von_mises_recovery"]
    @test meta["status"]=="complete"
    @test occursin("different points",meta["description"])
    @test r["von_mises"]≈hypot(meta["normal_bound"],sqrt(3)*meta["combined_shear_bound"])
    @test vm(Dict(k=>-v for (k,v) in f))==vm(f)
    @test vm(Dict(k=>.07v for (k,v) in f))≈.07vm(f)
    # Independently sample signed thin-wall fields, either torsional surface,
    # both element ends and mixed signs. The envelope must bound every sample.
    rng=MersenneTwister(2451)
    for sample in 1:30
        n,vy,vz,t,ma1,ma2,mb1,mb2=randn(rng,8).*[1000.,20.,20.,2.,30.,30.,30.,30.]
        applied=forces(;n,vy,vz,t,ma1,ma2,mb1,mb2);bound=vm(applied)
        for (m1,m2) in ((ma1,ma2),(mb1,mb2)),q in range(0.,1.;length=21),surface in (-1.,1.)
            y=hw*q;z=surface*tw/2
            sigma=n/p["A"]-m1*(y-yc)/p["I1"]-m2*z/p["I2"]
            tau=vy*(yc*y-y^2/2)/p["I1"]+surface*(t-vz*(yf-yc))*tw/p["J"]
            @test hypot(sigma,sqrt(3)*tau)<=bound*(1+1e-12)
            z=b*(q-.5)
            for side in (-1.,1.)
                sigma=n/p["A"]-m1*(yf+side*tf/2-yc)/p["I1"]-m2*z/p["I2"]
                tau=vy*(yf-yc)*(b/2-abs(z))/p["I1"]+vz*(b^2/8-z^2/2)/p["I2"]+surface*(t-vz*(yf-yc))*tf/p["J"]
                @test hypot(sigma,sqrt(3)*tau)<=bound*(1+1e-12)
            end
        end
    end
    for key in keys(f)
        bad=copy(f);delete!(bad,key);r=beam_t_stress_envelope(p,bad)
        @test !haskey(r,"von_mises")
        @test occursin(key,r["von_mises_recovery"]["reason"])
        bad[key]=NaN;@test !haskey(beam_t_stress_envelope(p,bad),"von_mises")
    end
    for bad in (merge(p,Dict("TYPE"=>"PBAR")),t_property(.04,.05,.008,.002),
                t_property(.04,.05,.002,.01),merge(p,Dict("A"=>1.01p["A"])),
                merge(p,Dict("J"=>.99p["J"])),merge(p,Dict("I12"=>1e-9)),
                merge(p,Dict("DIMS"=>[NaN,h,tf,tw])))
        r=beam_t_stress_envelope(bad,f)
        @test !haskey(r,"von_mises")
        @test r["von_mises_recovery"]["status"]=="unavailable"
    end
    for kwargs in ((material_type="MAT8",),(varying_section=true,),(distributed_loading=true,))
        @test !haskey(beam_t_stress_envelope(p,f;kwargs...),"von_mises")
    end
    write(joinpath(out,"analytic_t_envelope.json"),JSON.json(Dict("property"=>p,"forces"=>f,"stress"=>beam_t_stress_envelope(p,f))))
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"analytic_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
