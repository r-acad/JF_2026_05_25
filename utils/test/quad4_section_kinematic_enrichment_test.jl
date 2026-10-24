using Test

module Quad4SectionKinematicsFixture
using Test,LinearAlgebra,ForwardDiff,OpenJFEM
const F=OpenJFEM.FEM
function checks()
    h=.004
    # Independently chosen extensional and bending laws. D is deliberately
    # not proportional to A, including nonzero physical bend/twist coupling.
    A=1e7*[7. 1.4 0.;1.4 3. 0.;0. 0. 1.8]
    D=[18. 5. 1.1;5. 8. -.7;1.1 -.7 4.]
    S=Matrix{Float64}(I,2,2)*1e6
    for (a,b) in ((1.,1.),(1.,.6),(8.,.1),(.1,8.))
        x=[0. 0.;a 0.;a b;0. b]
        ws=F.create_quad4_workspace()
        K=F.stiffness_quad4_matrices(x,A,D,S,h,1.;ws=ws,
            k6rot=0.,kernel_mode="macneal",membrane_incomp=true,
            bending_incomp=true,bmb_incomp_coupling_mode=:full)
        @test ws.section_kinematic[]
        qx=zeros(24);qy=zeros(24);g=[1.,-1.,1.,-1.]/2
        for i=1:4;qx[6(i-1)+4]=g[i];qy[6(i-1)+5]=g[i];end
        # Integrate the physical D energy with the A-derived Poisson shape:
        # kappa_x=-r*kappa_y, r=A12/A11 (and the exchanged direction).
        rx=A[1,2]/A[1,1];ry=A[1,2]/A[2,2]
        ex=(D[2,2]-2D[1,2]*rx+D[1,1]*rx^2)*a/(3b)
        ey=(D[1,1]-2D[1,2]*ry+D[2,2]*ry^2)*b/(3a)
        @test dot(qx,K*qx) ≈ ex rtol=1e-10
        @test dot(qy,K*qy) ≈ ey rtol=1e-10
        @test abs(dot(qx,K*qy))<1e-9norm(D)
        @test minimum(eigvals(Symmetric(K)))>=-3e-12opnorm(K)
        @test norm(K-K')<=3e-12norm(K)
        P=zeros(24,3)
        for i=1:4
            xx,yy=x[i,:];j=6(i-1)
            P[j+3,:]=[-xx^2/2,-yy^2/2,-xx*yy/2]
            P[j+4,:]=[0.,-yy,-xx/2];P[j+5,:]=[xx,0.,yy/2]
        end
        # Compatible curvature retains every D entry; internal coordinates
        # vanish for that patch even when the sectional laws differ.
        @test P'*K*P ≈ a*b*D rtol=1e-9
        @test norm(ws.enrichment_bending*P)<1e-10norm(P)
        @test ws.K_bb_bend_shape*ws.enrichment_bending ≈ -ws.K_ab_bend_shape' rtol=1e-12
        # D-stationarity is intentionally a different formulation here.
        @test norm(ws.K_bb_bend*ws.enrichment_bending+ws.K_ab_bend')>1e-3norm(ws.K_ab_bend)
        legacy=withenv("JFEM_Q4_SECTION_KINEMATIC_ENRICHMENT"=>"false") do
            F.stiffness_quad4_matrices(x,A,D,S,h,1.;k6rot=0.,kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
        end
        @test dot(qx,(K-legacy)*qx)>0
        # A homogeneous through-thickness material is the common limit.
        Dh=A*h^2/12
        homogeneous=F.stiffness_quad4_matrices(x,A,Dh,S,h,1.;k6rot=0.,kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
        oldhomogeneous=withenv("JFEM_Q4_SECTION_KINEMATIC_ENRICHMENT"=>"false") do
            F.stiffness_quad4_matrices(x,A,Dh,S,h,1.;k6rot=0.,kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
        end
        @test homogeneous ≈ oldhomogeneous rtol=2e-12
    end
    # Differentiate A, D and B independently through the kinematic map.
    # A closed rectangular polynomial energy supplies the independent target.
    a=1.3;b=.7;x=[0. 0.;a 0.;a b;0. b]
    q=zeros(24);g=[1.,-1.,1.,-1.]/2
    for i=1:4;q[6(i-1)+2]=g[i];q[6(i-1)+4]=-g[i];end
    function energy(p)
        z=zero(p[1]);A=[p[1] p[2] z;p[2] p[3] z;z z z+1.8]
        D=[p[4] p[5] z+1.1;p[5] p[6] z-.7;z+1.1 z-.7 z+4.]
        B=[z+.2 p[7] z;p[7] z+.3 z;z z z+.15]
        K=F.stiffness_quad4_matrices(x,A,D,S,h,1.;Bmb=B,k6rot=0.,
            kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
        return dot(q,K*q)
    end
    function exact(p)
        r=p[2]/p[1]
        (p[3]-p[2]^2/p[1]+p[6]-2p[5]*r+p[4]*r^2+
            2(.3-2p[7]*r+.2r^2))*a/(3b)
    end
    p=[7.,1.4,3.,18.,5.,8.,.1]
    @test energy(p) ≈ exact(p) rtol=2e-11
    g_actual=ForwardDiff.gradient(energy,p)
    g_exact=ForwardDiff.gradient(exact,p)
    for i in eachindex(p)
        @test g_actual[i] ≈ g_exact[i] rtol=2e-10 atol=2e-11
    end
end
end
@testset "Section kinematics use A and retain full physical ABD energy" begin
    Quad4SectionKinematicsFixture.checks()
end
