using Test
module Quad4AffineHourglassFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver
const F=S.FEM

function patch_checks()
    shapes=([0. 0.;1. 0.;1. .5;0. .5],
            [0. 0.;1. 0.;1.3 .5;.3 .5],
            [0. 0.;1. 0.;.7 .5;.1 .5])
    for xy in shapes, angle in (0.,pi/6,-pi/5)
        q=OpenJFEM.laminate_plane_stress_qbar(135e9,8.5e9,.27,4.8e9,angle)
        h=.002;A=h*q;D=h^3/12*q
        C=(5h/6)*OpenJFEM.laminate_transverse_shear_qbar(5.1e9,3.2e9,angle)
        K=F.stiffness_quad4_matrices(xy,A,D,C,h,135e9;
            k6rot=0.,kernel_mode="macneal",bending_incomp=true,
            membrane_incomp=false,membrane_shear_center_row=true)
        P=zeros(24,3);R=zeros(24,3)
        for i=1:4
            x,y=xy[i,:];j=6(i-1)
            P[j+3,:]=[-x*x/2,-y*y/2,-x*y/2]
            P[j+4,:]=[0.,-y,-x/2];P[j+5,:]=[x,0.,y/2]
            R[j+3,:]=[1.,y,-x];R[j+4,2]=1.;R[j+5,3]=1.
        end
        area=abs(sum(xy[i,1]*xy[mod1(i+1,4),2]-xy[mod1(i+1,4),1]*xy[i,2] for i=1:4))/2
        # Three exact constant-curvature fields and their mutual work terms.
        @test norm(P'*K*P-area*D)<2e-10norm(area*D)
        @test norm(K*R)<2e-12norm(K)*norm(R)
        @test norm(K-K')<2e-12norm(K)

        # Geometry-dual hourglass: orthogonality is invariant under any
        # nonsingular affine change of projected coordinates, including shear.
        function gamma(x)
            dr,ds=F.shape_derivs_quad(0.,0.)
            derivatives=([dr';ds']*x)\[dr';ds']
            h4=[1.,-1.,1.,-1.]
            h4-(h4'x[:,1])*derivatives[1,:]-(h4'x[:,2])*derivatives[2,:]
        end
        g=gamma(xy)
        @test norm(hcat(ones(4),xy)'*g)<2e-14norm(g)
        @test isapprox(dot([1.,-1.,1.,-1.],g),4.;atol=2e-14)
        transformed=xy*[.7 .4;-.2 1.3].+[2. -3.]
        @test isapprox(gamma(transformed),g;rtol=2e-14,atol=2e-14)
    end
end

@testset "Quadrilateral affine hourglass patch" begin
    patch_checks()
end
end
