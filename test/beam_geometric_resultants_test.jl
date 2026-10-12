using Test, LinearAlgebra, Random
using OpenJFEM
let F=OpenJFEM.Solver.FEM, AD=OpenJFEM.Solver.ForwardDiff
    # Independent quadrature of the second-order section-strain energy.
    # Resultants are N,T,Qy,Qz,My(A),Mz(A); My'=Qz and Mz'=-Qy.
    function energy(q,L,resultants,radius2)
        N,T,Qy,Qz,MyA,MzA=resultants
        v=q[[2,6,8,12]];w=q[[3,5,9,11]].*[1,-1,1,-1]
        du=(q[7]-q[1])/L;dp=(q[10]-q[4])/L
        ans=zero(eltype(q))
        for (xi,weight) in ((-.8611363115940526,.3478548451374538),
                            (-.3399810435848563,.6521451548625461),
                            (.3399810435848563,.6521451548625461),
                            (.8611363115940526,.3478548451374538))
            t=(xi+1)/2;x=t*L
            h1=[(-6t+6t^2)/L,1-4t+3t^2,(6t-6t^2)/L,-2t+3t^2]
            h2=[(-6+12t)/L^2,(-4+6t)/L,(6-12t)/L^2,(-2+6t)/L]
            dv=dot(h1,v);dw=dot(h1,w);ddv=dot(h2,v);ddw=dot(h2,w)
            p=(1-t)*q[4]+t*q[10];My=MyA+Qz*x;Mz=MzA-Qy*x
            ans+=weight*L/2*(N/2*(dv^2+dw^2+radius2*dp^2)-Qy*du*dv-Qz*du*dw+
                Qy/2*p*dw-Qz/2*p*dv+T/2*(dw*ddv-dv*ddw)+
                My/2*(p*ddv-dv*dp)+Mz/2*(p*ddw-dw*dp))
        end
        ans
    end
    @testset "Complete beam prestress and analytic tangents" begin
        rng=MersenneTwister(581092)
        for L in (.07,.5,3.8), mode in 1:7
          @testset "Length $L / resultant $mode" begin
            r=mode<=6 ? Float64[i==mode for i in 1:6] : randn(rng,6)
            N,T,Qy,Qz,My,Mz=r;radius2=.0043
            f=zeros(12);f[7]=N;f[4]=-T;f[2]=-Qy;f[3]=-Qz;f[5]=-My;f[6]=-Mz
            K=F.geometric_stiffness_frame3d(L,f,radius2)
            H=AD.hessian(q->energy(q,L,r,radius2),zeros(12))
            @test K≈H rtol=3e-14 atol=1e-13
            @test issymmetric(K)
            q=randn(rng,12)
            @test dot(q,K*q)/2≈energy(q,L,r,radius2) rtol=3e-13 atol=1e-12
            d=randn(rng,12)
            tangent=AD.derivative(a->dot(q,F.geometric_stiffness_frame3d(L,f+a*d,radius2)*q),0.)
            @test tangent≈dot(q,F.geometric_stiffness_frame3d(L,d,radius2)*q) rtol=3e-13 atol=1e-12
          end
        end
        # Pure moments/torque must not vanish when axial force is zero.
        for keyword in (:torque,:moment_y,:moment_z,:shear_y,:shear_z)
            @test norm(F.geometric_stiffness_frame3d(.5,0.;(keyword=>100.,)...))>0
        end
        K=F.geometric_stiffness_frame3d(.5,-1000.;radius2=.002)
        @test K[4,4]==-4.0 && K[4,10]==4.0
        @test F.geometric_stiffness_frame3d(.5,0.)==zeros(12,12)
    end
end
