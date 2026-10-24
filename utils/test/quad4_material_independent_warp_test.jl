using Test
module MaterialIndependentWarpFixture
using Test,OpenJFEM,LinearAlgebra
const F=OpenJFEM.FEM

function checks()
    t=.004;E=7.1e10
    # Independent synthetic section laws; coupled law is the exact shift of
    # the same positive membrane/bending energy to an offset reference plane.
    isotropic=E/(1-.29^2)*[1. .29 0.;.29 1. 0.;0. 0. (1-.29)/2]
    anisotropic=[1.45e11 3.8e9 1.7e9;3.8e9 1.2e10 .8e9;1.7e9 .8e9 4.8e9]
    shapes=([0. 0.;1.8 0.;1.8 .7;0. .7],
            [0. 0.;1.8 0.;2.2 .7;.4 .7],
            [0. 0.;1.8 0.;1.5 .7;.2 .7])
    v=normalize([.3,-.7,.2]);ang=.73;V=[0. -v[3] v[2];v[3] 0. -v[1];-v[2] v[1] 0.]
    Q=cos(ang)*I+(1-cos(ang))*v*v'+sin(ang)*V
    for xy in shapes, warp in (0.,.08,.3), C in (isotropic,anisotropic), coupled in (false,true)
        A=t*C;zoff=coupled ? .18t : 0.;B=coupled ? zoff*A : nothing
        D=(t^2/12+zoff^2)*A;Cs=(5/6)*t*[4.1e9 .3e9;.3e9 3.6e9]
        x3=hcat(xy,warp*[1.,-1.,1.,-1.])
        normal=normalize(cross(x3[3,:]-x3[1,:],x3[4,:]-x3[2,:]))
        axis1=x3[2,:]-x3[1,:];axis1=normalize(axis1-dot(axis1,normal)*normal)
        axis2=cross(normal,axis1);center=vec(sum(x3;dims=1))/4
        xy=hcat((x3.-permutedims(center))*axis1,(x3.-permutedims(center))*axis2)
        kw=(Bmb=B,k6rot=1.,membrane_incomp=true,bending_incomp=true,
            coords_3d=x3,bmb_incomp_coupling_mode=:full,kernel_mode="macneal")
        K=F.stiffness_quad4_matrices(xy,A,D,Cs,t,E;kw...,kernel_planar=false)
        Kp=F.stiffness_quad4_matrices(xy,A,D,Cs,t,E;kw...,kernel_planar=true)
        @test isapprox(K,Kp;rtol=5e-13,atol=1e-8)
        @test norm(K-K')<1e-12norm(K)
        ev=eigvals(Symmetric(K));@test minimum(ev)>-1e-12maximum(ev)
        # Section-local coordinates come from the same diagonal mean plane.
        zl=F.quad4_local_z_from_coords3d(x3);local_x=hcat(xy,zl)
        R=zeros(24,6);P=zeros(24,3)
        for i=1:4
            d=6(i-1);x,y,z=local_x[i,:]
            R[d+1:d+3,1:3].=Matrix{Float64}(I,3,3)
            R[d+1:d+3,4:6].=[0. z -y;-z 0. x;y -x 0.]
            R[d+4:d+6,4:6].=Matrix{Float64}(I,3,3)
            P[d+1,:]=[x,0.,y/2];P[d+2,:]=[0.,y,x/2]
        end
        @test norm(K*R)<1e-12norm(K)*norm(R)
        W=F.quad4_finite_warp_displacement_map(xy,x3);W===nothing || (P=W\P)
        area=abs(sum(xy[i,1]*xy[mod1(i+1,4),2]-xy[mod1(i+1,4),1]*xy[i,2] for i=1:4))/2
        @test isapprox(P'*K*P,area*A;rtol=2e-11,atol=1e-7)
        moved=x3*Q'.+permutedims([.4,-.8,.2])
        Kr=F.stiffness_quad4_matrices(xy,A,D,Cs,t,E;
            merge(kw,(coords_3d=moved,))...,kernel_planar=false)
        @test isapprox(K,Kr;rtol=3e-12,atol=1e-7)
    end
end
end
@testset "Material-independent finite-warp interpolation" begin
    MaterialIndependentWarpFixture.checks()
end
