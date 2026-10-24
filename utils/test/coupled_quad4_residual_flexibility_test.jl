using Test

module CoupledQuad4ResidualFlexibilityFixture
using LinearAlgebra, ForwardDiff, OpenJFEM, Test
const F=OpenJFEM.FEM

function coefficient_map()
    Q=zeros(12,4)
    for (i,(r,s)) in enumerate(zip((-1.,1.,1.,-1.),(-1.,-1.,1.,1.)))
        Q[3i,1]=1.;Q[3i,2]=s
        Q[3i-1,3]=-1.;Q[3i-1,4]=-r
    end
    Q
end

function checks()
    x=[-1. -.5;1. -.5;1. .5;-1. .5]
    A=[2.e7 3.e6 2.e5;3.e6 1.5e7 -1.e5;2.e5 -1.e5 5.e6]
    B=[2.e3 80. 30.;80. -1.5e3 -20.;30. -20. 100.]
    D=[4. 0.8 0.1;0.8 3. -0.05;0.1 -0.05 1.]
    S=[8.e5 0.;0. 5.e5]
    @test minimum(eigvals(Symmetric([A B;B D])))>0
    Q=coefficient_map()
    H=[1. .2 0. 0.;0. 1. .1 0.;0. 0. 1. -.3;.15 0. 0. 1.]
    function flexibility(a,b,d;rigid=false,transfer=H)
        T=promote_type(eltype(a),eltype(b),eltype(d))
        mw=F.create_macneal_shear_workspace(T)
        mw.D_mat .= transfer*pinv(Q)
        F.quad4_natural_shear_flexibility!(mw,x,d,S;Cm=a,Bmb=b,rigid_shear=rigid)
        copy(mw.Z_total)
    end
    # Independent minimization of the directional section energy gives the
    # neutral-surface rigidity; no other extensional channel is released.
    dstar=[D[i,i]-B[i,i]^2/A[i,i] for i=1:2]
    for i=1:2
        e=-B[i,i]/A[i,i]
        @test A[i,i]*e^2+2B[i,i]*e+D[i,i] ≈ dstar[i]
    end
    area=2.;lx2=4.;ly2=1.
    ux=lx2/(12area*dstar[1]);uy=ly2/(12area*dstar[2])
    residual=Diagonal([ux,3ly2/(ly2+39lx2)*ux,uy,3lx2/(lx2+39ly2)*uy])
    physical=Diagonal([1/(area*S[1,1]),3/(area*S[1,1]),1/(area*S[2,2]),3/(area*S[2,2])])
    @test flexibility(A,B,D) ≈ H*(residual+physical)*H' rtol=2e-14
    @test flexibility(A,B,D;rigid=true) ≈ H*residual*H' rtol=2e-14
    @test flexibility(A,-B,D) == flexibility(A,B,D)
    @test minimum(eigvals(Symmetric(flexibility(A,B,D))))>0
    # Changing only the section reference plane leaves its neutral-surface
    # residual rigidity unchanged. Constant-field ABD is not replaced.
    z=0.0003
    @test flexibility(A,B-z*A,D-2z*B+z^2*A) ≈ flexibility(A,B,D) rtol=2e-14
    mw=F.create_macneal_shear_workspace();mw.D_mat .= H*pinv(Q)
    uncoupled=copy(F.quad4_natural_shear_flexibility!(mw,x,D,S))
    @test flexibility(A,zeros(3,3),D) == uncoupled
    # Constitutive sensitivities must include the neutral-surface correction.
    f(t)=sum(flexibility(A,(1+t)*B,D))
    @test ForwardDiff.derivative(f,0.) ≈ (f(1e-5)-f(-1e-5))/(2e-5) rtol=2e-8
    @test_throws ArgumentError flexibility(A,100B,D)

    # A complete coupled element retains rigid motion and its physical ABD
    # constant-strain/curvature patch after the residual correction.
    for xg in (x,[-1. -.5;1. -.5;1.5 .5;-.5 .5])
        K=F.stiffness_quad4_matrices(xg,A,D,S,.002,1.e10;
            Bmb=B,k6rot=0.,kernel_mode="macneal",membrane_incomp=true,
            bending_incomp=true,bmb_incomp_coupling_mode=:full)
        @test norm(K-K')/norm(K)<1e-13
        @test minimum(eigvals(Symmetric(K)))/opnorm(K)>-1e-12
        for ep in ([.1,-.03,.05],[0.,0.,0.]),kap in ([.04,-.02,.01],[0.,0.,0.])
            q=zeros(24)
            for i=1:4
                xx,yy=xg[i,:];p=6(i-1)
                q[p+1]=ep[1]*xx+ep[3]*yy/2
                q[p+2]=ep[2]*yy+ep[3]*xx/2
                q[p+3]=-(kap[1]*xx^2+kap[2]*yy^2+kap[3]*xx*yy)/2
                q[p+4]=-kap[2]*yy-kap[3]*xx/2
                q[p+5]=kap[1]*xx+kap[3]*yy/2
            end
            target=area*(dot(ep,A*ep)+2dot(ep,B*kap)+dot(kap,D*kap))
            @test dot(q,K*q) ≈ target atol=1e-9 rtol=1e-10
        end
    end
end
end

@testset "Coupled quadrilateral neutral-surface residual flexibility" begin
    CoupledQuad4ResidualFlexibilityFixture.checks()
end
