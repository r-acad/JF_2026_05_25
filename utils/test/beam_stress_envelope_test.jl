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
checks=@testset "Finite-thickness nominal T equivalent-stress envelope" begin
    p=t_property();b,h,tf,tw=p["DIMS"];hw=h-tf
    yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/p["A"];yf=hw+tf/2
    vm(f;kw...)=beam_t_stress_envelope(p,f;kw...)["von_mises"]
    @test vm(forces())==0
    @test vm(forces(n=1234.))≈1234/p["A"]
    @test vm(forces(n=-1234.))≈1234/p["A"]
    @test vm(forces(ma1=23.))≈23*max(yc,h-yc)/p["I1"]
    @test vm(forces(mb2=-17.))≈17*b/(2p["I2"])
    nominalJ=beam_rectangle_torsion_constant(b,tf)+beam_rectangle_torsion_constant(tw,hw)
    @test vm(forces(t=11.))≈sqrt(3)*11*max(tf,tw)/nominalJ
    vy=13.;webtau=vy*yc^2/(2p["I1"]);flangetau=vy*(yf-yc)*b/(2p["I1"])
    @test vm(forces(vy=vy))≈sqrt(3)*max(webtau,flangetau)
    vz=19.;torquebound=vz*(yf-yc)
    webHorizontalQ=(tf*(b*b-tw*tw)+h*tw*tw)/(8h)
    @test vm(forces(vz=vz))≈sqrt(3)*max(vz*webHorizontalQ/p["I2"]+torquebound*tw/nominalJ,vz*b^2/(8p["I2"])+torquebound*tf/nominalJ)
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
    for bad in (merge(p,Dict("TYPE"=>"PBAR")),merge(p,Dict("A"=>1.01p["A"])),
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
    # Valid thick rectangular limbs remain assessed. Independent signed
    # samples include the vertical flange component and central strip shear,
    # in addition to the old thin-wall field above. The claim is a bound for
    # this nominal engineering model, not singular 3-D junction stresses.
    for dimensions in ((.03,.032,.004,.0015),(.04,.05,.008,.002),(.04,.05,.002,.01),(.04,.05,.015,.02))
        pp=t_property(dimensions...);bb,hh,ff,ww=dimensions;clear=hh-ff
        A=pp["A"];yc=(clear*ww*clear/2+bb*ff*(clear+ff/2))/A;flangeY=clear+ff/2
        nominal=beam_rectangle_torsion_constant(bb,ff)+beam_rectangle_torsion_constant(ww,clear)
        for trial in 1:8
            N,V1,V2,T,M1,M2=randn(rng,6).*[1000.,20.,20.,2.,30.,30.]
            force=forces(n=N,vy=V1,vz=V2,t=T,ma1=M1,ma2=M2,mb1=-M1,mb2=M2)
            result=beam_t_stress_envelope(pp,force);bound=result["von_mises"]
            @test result["von_mises_recovery"]["method"]=="finite_thickness_t_nominal_envelope"
            for q in range(0.,1.;length=17),side in (-1.,1.),endSign in (-1.,1.)
                y=clear*q;z=side*ww/2
                sigma=N/A-endSign*M1*(y-yc)/pp["I1"]-M2*z/pp["I2"]
                horizontal=V2*(ff*(bb^2-ww^2)+hh*ww^2)/(8hh*pp["I2"])
                vertical=V1*(yc*y-y^2/2)/pp["I1"]
                twist=(T-V2*(flangeY-yc))/nominal
                @test sqrt(sigma^2+3*(abs(vertical)+abs(horizontal)+abs(twist)*ww)^2)<=bound*(1+1e-12)
                y=clear+ff*q;z=bb*(q-.5)
                sigma=N/A-endSign*M1*(y-yc)/pp["I1"]-M2*z/pp["I2"]
                vertical=V1*((hh-yc)^2-(y-yc)^2)/(2pp["I1"])
                horizontal=V1*(flangeY-yc)*(bb/2-abs(z))/pp["I1"]+V2*(bb^2/8-z^2/2)/pp["I2"]
                @test sqrt(sigma^2+3*(abs(vertical)+abs(horizontal)+abs(twist)*ff)^2)<=bound*(1+1e-12)
            end
        end
    end
    # Elasticity-series rectangle values and unit scaling, independently
    # compared with a much longer reference series over all aspect ratios.
    for ratio in (.001,.01,.1,.25,.5,1.)
        reference=ratio^3/3*(1-192ratio/pi^5*sum(tanh(k*pi/(2ratio))/k^5 for k in 1:2:1999))
        @test beam_rectangle_torsion_constant(1.,ratio)≈reference rtol=2e-9
        @test beam_rectangle_torsion_constant(ratio,1.)==beam_rectangle_torsion_constant(1.,ratio)
        @test beam_rectangle_torsion_constant(1000.,1000ratio)≈1e12reference rtol=2e-9
    end
end
counts=Test.get_test_counts(checks)
write(joinpath(out,"analytic_summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
