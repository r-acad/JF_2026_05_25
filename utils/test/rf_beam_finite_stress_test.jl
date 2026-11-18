module RFFiniteTStressTests
using Test,LinearAlgebra,ForwardDiff
const ROOT=normpath(joinpath(@__DIR__,"..",".."))
include(joinpath(ROOT,"src","solver","beam_stress_envelope.jl"))
include(joinpath(ROOT,"APPS","JFEM-Boxer","src","rf_kernels.jl"))
include(joinpath(ROOT,"APPS","JFEM-Boxer","src","rf_native_assessment.jl"))
function section_property(d)
    b,h,tf,tw=d;hw=h-tf;A=b*tf+hw*tw;yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/A
    Dict{String,Any}("TYPE"=>"T","DIMS"=>d,"A"=>A,
        "I1"=>tw*hw^3/12+hw*tw*(yc-hw/2)^2+b*tf^3/12+b*tf*(hw+tf/2-yc)^2,
        "I2"=>hw*tw^3/12+tf*b^3/12,"J"=>(hw*tw^3+b*tf^3)/3)
end
const FORCE_KEYS=("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2")
@testset "Finite-thickness nominal T RF derivatives and legacy resultants" begin
    f=[-1300.,21.,-11.,1.7,17.,-23.,-3.,11.];forces=Dict(zip(FORCE_KEYS,f))
    for d in ([.03,.032,.004,.0015],[.04,.05,.002,.01],[.04,.05,.015,.02],[.04,.05,.002,.002])
        p=section_property(d);native=beam_t_stress_envelope(p,forces)
        kernel=(dims,force)->rf_beam_equivalent("T",force,dims,p["J"])
        @test kernel(d,f)≈native["von_mises"] rtol=2e-14
        dg=ForwardDiff.gradient(x->kernel(x,f),d);fg=ForwardDiff.gradient(x->kernel(d,x),f)
        for i in eachindex(d)
            step=d[i]*1e-5;plus=copy(d);minus=copy(d);plus[i]+=step;minus[i]-=step
            fd=(beam_t_stress_envelope(section_property(plus),forces)["von_mises"]-beam_t_stress_envelope(section_property(minus),forces)["von_mises"])/(2step)
            @test dg[i]≈fd rtol=2e-7 atol=1e-3
        end
        for i in eachindex(f)
            step=abs(f[i])*1e-5;plus=copy(f);minus=copy(f);plus[i]+=step;minus[i]-=step
            fd=(beam_t_stress_envelope(p,Dict(zip(FORCE_KEYS,plus)))["von_mises"]-beam_t_stress_envelope(p,Dict(zip(FORCE_KEYS,minus)))["von_mises"])/(2step)
            @test fg[i]≈fd rtol=2e-7 atol=1e-3
        end
    end
    # The old thickness ratio threshold is not a constitutive discontinuity.
    d=[.03,.032,.003,.0015];g=ForwardDiff.derivative(t->rf_beam_equivalent("T",f,[d[1],d[2],t,d[4]],section_property(d)["J"]),d[3])
    step=1e-8;plus=copy(d);minus=copy(d);plus[3]+=step;minus[3]-=step
    fd=(beam_t_stress_envelope(section_property(plus),forces)["von_mises"]-beam_t_stress_envelope(section_property(minus),forces)["von_mises"])/(2step)
    @test g≈fd rtol=2e-7
    d=[.03,.032,.004,.0015];p=section_property(d)
    property=Dict("type"=>"PBARL","section"=>Dict("shape"=>"T","dimensions_m"=>d,"area_m2"=>p["A"],"I1_m4"=>p["I1"],"I2_m4"=>p["I2"],"J_m4"=>p["J"]))
    for metadata in (Dict("status"=>"unavailable","method"=>"thin_walled_t_section_envelope","reason"=>"The thin-wall stress model requires flange thickness/full width and web thickness/clear height no greater than 0.10."),
                     Dict("status"=>"complete","method"=>"thin_walled_t_section_envelope"))
        record=Dict("forces"=>forces,"stress"=>Dict("von_mises"=>1.,"von_mises_recovery"=>metadata));before=deepcopy(record)
        sample=only(rf_vm_samples!(RFNativeInputs(1,Dict("1"=>record)),1,property;pid=7000068))
        @test sample.value≈beam_t_stress_envelope(p,forces)["von_mises"]
        @test sample.recovery["recovered_from_legacy_resultants"]===true
        @test record==before
    end
    for reason in ("Distributed beam loading requires interior force/stress recovery","Varying section needs interior recovery")
        record=Dict("forces"=>forces,"stress"=>Dict("von_mises_recovery"=>Dict("status"=>"unavailable","method"=>"thin_walled_t_section_envelope","reason"=>reason)))
        @test_throws ArgumentError rf_vm_samples!(RFNativeInputs(1,Dict("1"=>record)),1,property;pid=7000068)
    end
end
end
