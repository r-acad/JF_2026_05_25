using Test
module RectangleKernel
include(joinpath(@__DIR__,"..","..","..","src","solver","beam_stress_envelope.jl"))
end
const K=RectangleKernel
@testset "Rectangular cap conservative equivalent stress" begin
    function section(b,h)
        Dict("TYPE"=>"BAR","DIMS"=>[b,h],"A"=>b*h,"I1"=>b*h^3/12,"I2"=>h*b^3/12)
    end
    forces()=Dict(key=>0. for key in ("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2"))
    for (b,h) in ((.02,.02),(.01,.03),(.03,.01))
        p=section(b,h);f=forces();f["axial"]=100.
        @test isapprox(K.beam_t_stress_envelope(p,f)["von_mises"],100/(b*h))
        f["axial"]=0.;f["moment_b1"]=2.
        @test isapprox(K.beam_t_stress_envelope(p,f)["von_mises"],2h/(2p["I1"]))
        f["moment_b1"]=0.;f["torque"]=1.
        @test isapprox(K.beam_t_stress_envelope(p,f)["von_mises"],sqrt(3)*5/(max(b,h)*min(b,h)^2))
        @test K.beam_t_stress_envelope(p,f)["von_mises"]>sqrt(3)/(.208*max(b,h)*min(b,h)^2)
        @test isapprox(K.beam_t_stress_envelope(section(1.1b,1.1h),f)["von_mises"],K.beam_t_stress_envelope(p,f)["von_mises"]/1.1^3)
        f["shear_1"]=100.;f["shear_2"]=-200.;f["moment_a2"]=-3.
        result=K.beam_t_stress_envelope(p,f)
        @test result["von_mises"]>=result["von_mises_recovery"]["normal_bound"]
        @test result["von_mises_recovery"]["status"]=="complete"
        @test K.beam_t_stress_envelope(p,f;distributed_loading=true)["von_mises_recovery"]["status"]=="unavailable"
        @test K.beam_t_stress_envelope(p,f;varying_section=true)["von_mises_recovery"]["status"]=="unavailable"
        @test K.beam_t_stress_envelope(p,f;material_type="MAT8")["von_mises_recovery"]["status"]=="unavailable"
        delete!(f,"shear_1")
        @test K.beam_t_stress_envelope(p,f)["von_mises_recovery"]["status"]=="unavailable"
    end
end
