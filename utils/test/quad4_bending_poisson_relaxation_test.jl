using Test

module Quad4BendingPoissonRelaxationFixture
using Test,LinearAlgebra,OpenJFEM
const F=OpenJFEM.FEM
function checks()
    # Normalized rotational hourglass fields have no constant curvature or
    # assumed transverse shear. Their Poisson curvature relaxes through the
    # internal coordinates: min_x D*(x^2+2nu*x*y+y^2)=D*(1-nu^2)*y^2.
    E=7e10;h=.003
    for (a,b) in ((1.,.6),(1.,1.),(4.,1.)), nu in (0.,.23,.33,.45)
        x=[0. 0.;a 0.;a b;0. b]
        A=E*h/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
        D=A*h^2/12;S=Matrix{Float64}(I,2,2)*(5/6)*E*h/(2(1+nu))
        K=F.stiffness_quad4_matrices(x,A,D,S,h,E;
            k6rot=0.,kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
        g=[1.,-1.,1.,-1.]/2
        qx=zeros(24);qy=zeros(24)
        for i=1:4;qx[6(i-1)+4]=g[i];qy[6(i-1)+5]=g[i];end
        @test dot(qx,K*qx) ≈ D[2,2]*(1-nu^2)*a/(3b) rtol=2e-12
        @test dot(qy,K*qy) ≈ D[1,1]*(1-nu^2)*b/(3a) rtol=2e-12
        @test abs(dot(qx,K*qy))<2e-12norm(D)
        @test minimum(eigvals(Symmetric(K)))/opnorm(K)>-2e-12
        # Every constant-curvature combination still carries the complete D.
        P=zeros(24,3)
        for i=1:4
            xx,yy=x[i,:];j=6(i-1)
            P[j+3,:]=[-xx^2/2,-yy^2/2,-xx*yy/2]
            P[j+4,:]=[0.,-yy,-xx/2];P[j+5,:]=[xx,0.,yy/2]
        end
        @test P'*K*P ≈ a*b*D rtol=2e-12
    end
end
end

@testset "Quadrilateral bending internal modes retain Poisson relaxation" begin
    Quad4BendingPoissonRelaxationFixture.checks()
end
