using Test

module Quad4SampledShearVolumeFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F = OpenJFEM.Solver.FEM
const GP = inv(sqrt(3.0))
const P = [1. -GP 0. 0.;1. GP 0. 0.;0. 0. 1. -GP;0. 0. 1. GP]
const CORNERS = ((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))

derivatives(r,s) = [-1+s 1-s 1+s -1-s;-1+r -1-r 1+r 1-r]/4

# Paper sample-force form (MacNeal 1978, Eqs.23--25), independent of
# the production coefficient-stiffness expansion.
function reference_flexibility(xy,C)
    volumes = [sqrt(2abs(det(derivatives(r,s)*xy)))
               for (r,s) in ((0.,-GP),(0.,GP),(-GP,0.),(GP,0.))]
    G = [C[1,1] 0 C[1,2]/2 C[1,2]/2;
         0 C[1,1] C[1,2]/2 C[1,2]/2;
         C[2,1]/2 C[2,1]/2 C[2,2] 0;
         C[2,1]/2 C[2,1]/2 0 C[2,2]]
    V = Diagonal(volumes)
    transform = inv(P)/V
    transform*(G\transpose(transform))
end

# Independent scalar complementary energy in the pair-mean/difference basis.
# This avoids structural matrix shortcuts in the derivative oracle itself.
function reference_energy(xy,C,force)
    volumes = [sqrt(2abs(det(derivatives(r,s)*xy)))
               for (r,s) in ((0.,-GP),(0.,GP),(-GP,0.),(GP,0.))]
    sample_force = (transpose(P)\force)./volumes
    xp=(sample_force[1]+sample_force[2])/sqrt(2)
    xm=(sample_force[1]-sample_force[2])/sqrt(2)
    yp=(sample_force[3]+sample_force[4])/sqrt(2)
    ym=(sample_force[3]-sample_force[4])/sqrt(2)
    detC=C[1,1]*C[2,2]-C[1,2]*C[2,1]
    (C[2,2]*xp*xp-(C[1,2]+C[2,1])*xp*yp+C[1,1]*yp*yp)/detC +
        xm*xm/C[1,1]+ym*ym/C[2,2]
end

function coefficient_flexibility(xy,C;B=zeros(3,3),rigid=false)
    T = eltype(C)
    mw=F.create_macneal_shear_workspace(T)
    Q=zeros(12,4)
    for (k,(r,s)) in enumerate(CORNERS)
        Q[3k,1]=1;Q[3k,2]=s;Q[3k-1,3]=-1;Q[3k-1,4]=-r
    end
    # The dual rotation-field rows give unit work-coordinate transport.
    mw.D_mat .= pinv(Q)
    F.quad4_natural_shear_flexibility!(mw,xy,[19. 2. 1.;2. 31. -1.;1. -1. 7.],C;
        Cm=[170. 21. 3.;21. 110. -2.;3. -2. 47.],Bmb=B,rigid_shear=rigid)
    mw
end

@testset "Published Q4 transverse-shear sample volumes" begin
    geometries=([-1. -.7;1. -.4;1.2 .5;-.8 .8],
                [-1. -.5;.8 -.5;1.2 .5;-.6 .5],
                [-.15 -1.;.12 -.7;.18 1.;-.1 .8])
    for xy in geometries, C in ([8. 0.;0. 3.],[8. 1.7;1.7 3.],[3. -1.2;-1.2 7.])
        mw=coefficient_flexibility(xy,C);expected=reference_flexibility(xy,C)
        @test mw.Zs ≈ expected rtol=3e-12 atol=1e-14
        @test isposdef(Symmetric(mw.Zs))
        force=[.3,-.7,.5,.2]
        energy=dot(force,mw.Zs*force)
        f(s)=dot(force,coefficient_flexibility(xy,s*C).Zs*force)
        @test ForwardDiff.derivative(f,1.) ≈ -energy rtol=2e-11
        @test ForwardDiff.derivative(s -> ForwardDiff.derivative(f,s),1.) ≈ 2energy rtol=2e-10
        coupled=coefficient_flexibility(xy,C;B=[2. .2 0.;.2 -3. .1;0. .1 .5])
        @test coupled.Zs == mw.Zs
        @test coupled.Zb != mw.Zb
        @test iszero(coefficient_flexibility(xy,zeros(2,2);rigid=true).Zs)
    end
    # An aligned material can have a nonzero orientation derivative even
    # though its current off-diagonal shear modulus is exactly zero.
    force=[.4,-.3,.1,.7]
    for xy in (first(geometries),[-1. -.5;1. -.5;1. .5;-1. .5])
        material(angle)=begin
            c,s=cos(angle),sin(angle)
            [9c*c+2s*s 7c*s;7c*s 9s*s+2c*c]
        end
        oriented_energy(angle)=dot(force,coefficient_flexibility(xy,material(angle)).Zs*force)
        exact_energy(angle)=reference_energy(xy,material(angle),force)
        step=1e-5
        @test isapprox(ForwardDiff.derivative(oriented_energy,0.),
              (oriented_energy(step)-oriented_energy(-step))/(2step);rtol=2e-8,atol=1e-10)
        for angle in (0.,.23)
            @test isapprox(oriented_energy(angle),exact_energy(angle);rtol=3e-12)
            @test isapprox(ForwardDiff.derivative(oriented_energy,angle),
                  ForwardDiff.derivative(exact_energy,angle);rtol=3e-11,atol=1e-12)
            @test isapprox(ForwardDiff.derivative(t->ForwardDiff.derivative(oriented_energy,t),angle),
                  ForwardDiff.derivative(t->ForwardDiff.derivative(exact_energy,t),angle);rtol=3e-10,atol=1e-12)
        end
    end
end
end
