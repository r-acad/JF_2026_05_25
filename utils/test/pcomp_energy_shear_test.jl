using Test

module PcompEnergyShearFixture
using Test, LinearAlgebra, OpenJFEM
const FD=OpenJFEM.Solver.ForwardDiff

function stack(angles, thicknesses; offset=0., isotropic=false)
    h=sum(thicknesses); z=-h/2+offset; plies=Any[]
    for (angle,t) in zip(angles,thicknesses)
        theta=deg2rad(angle)
        E1,E2,nu,G = isotropic ? (70e9,70e9,.3,70e9/2.6) : (135e9,8.5e9,.27,4.8e9)
        g1,g2=isotropic ? (G,G) : (5.1e9,3.2e9)
        push!(plies,Dict("Qbar"=>OpenJFEM.laminate_plane_stress_qbar(E1,E2,nu,G,theta),
            "Qshear"=>OpenJFEM.laminate_transverse_shear_qbar(g1,g2,theta),"z_bot"=>z,"z_top"=>z+t))
        z+=t
    end
    plies,h
end

function checks()
    for iso in (false,true), angle in (0.,23.,71.)
        p,h=stack([angle],[.001];isotropic=iso)
        c=OpenJFEM.pcomp_energy_shear(p,h)
        @test isapprox(c,(5/6)*h*p[1]["Qshear"];rtol=3e-15)
        split,hs=stack(fill(angle,7),fill(h/7,7);isotropic=iso)
        @test isapprox(c,OpenJFEM.pcomp_energy_shear(split,hs);rtol=4e-15)
        if iso
            @test isapprox(c,(5/6)*h*(70e9/2.6)*Matrix{Float64}(I,2,2);rtol=3e-15)
        end
    end
    for angles in ([0.,45.,90.,-45.],[0.,45.,-45.,90.,90.,-45.,45.,0.])
        ts=fill(.001/length(angles),length(angles));p,h=stack(angles,ts)
        c=OpenJFEM.pcomp_energy_shear(p,h)
        reversed=[merge(ply,Dict("z_bot"=>-ply["z_top"],"z_top"=>-ply["z_bot"])) for ply in reverse(p)]
        shifted,_=stack(angles,ts;offset=3h)
        @test c == transpose(c)
        @test isposdef(Symmetric(c))
        @test isapprox(c,OpenJFEM.pcomp_energy_shear(reversed,h);rtol=4e-15)
        @test isapprox(c,OpenJFEM.pcomp_energy_shear(shifted,h);rtol=5e-15)
        # Raw shear is isotropic for this balanced stack; energy-equivalent
        # shear nevertheless has nonzero coupling due to the layer locations.
        @test abs(c[1,2]) > .01*sqrt(c[1,1]*c[2,2])
        # Scaling every length scales stiffness linearly, including coupling.
        scaled,sh=stack(angles,3ts)
        @test isapprox(3c,OpenJFEM.pcomp_energy_shear(scaled,sh);rtol=5e-15)
        # A local ply-thickness tangent exercises neutral-axis movement and
        # the full reciprocal-compliance inversion, not only a scale factor.
        function law(x)
            t=ts.+x.*[i==2 ? ts[i] : 0. for i in eachindex(ts)]
            q,hq=stack(angles,t)
            OpenJFEM.pcomp_energy_shear(q,hq)
        end
        analytic=FD.partials.(law(FD.Dual(0.,1.)))
        derivative=map(first,analytic); delta=1e-5
        finite_difference=(law(delta)-law(-delta))/(2delta)
        @test isapprox(derivative,finite_difference;rtol=2e-8)
    end
    # Reject incomplete material data instead of inventing a shear law.
    p,h=stack([0.],[.001]);delete!(p[1],"Qbar")
    @test_throws ArgumentError OpenJFEM.pcomp_energy_shear(p,h)
end
end

@testset "Laminate shear equilibrium and energy invariance" begin
    PcompEnergyShearFixture.checks()
end
