using Test,LinearAlgebra,OpenJFEM
let F=OpenJFEM.FEM
@testset "Corner-thickness section energy and inertia" begin
    xy=[-.25 -.15;.25 -.15;.25 .15;-.25 .15]
    ti=[.0018,.0027,.0045,.0033];area=.15
    for ortho in (false,true),angle in (0.,.37)
        E=ortho ? 145e9 : 70e9;E2=ortho ? 7.6e9 : E;nu=ortho ? .3 : .33
        G=ortho ? 3.6e9 : E/(2(1+nu));den=1-nu^2*E2/E
        C=[E/den nu*E2/den 0;nu*E2/den E2/den 0;0 0 G]
        F.rotate_constitutive_3x3!(C,angle)
        h=.003;Cs=Matrix{Float64}(I,2,2)*(G*h*5/6)
        p=F.quad4_variable_thickness_packet(xy,h*C,h^3*C/12,Cs,h,E,ti;k6rot=1.)
        @test norm(p.K-p.K')<=1e-12*norm(p.K)
        @test minimum(eigvals(Symmetric(p.K)))>=-1e-12*opnorm(p.K)
        for hr in (.001,.007)
            q=F.quad4_variable_thickness_packet(xy,hr*C,hr^3*C/12,Cs*(hr/h),hr,E,ti;k6rot=1.)
            @test q.K≈p.K rtol=3e-12
            @test q.Kshear≈p.Kshear rtol=3e-12
        end
        for j in 1:6
            u=zeros(24);t=zeros(3);r=zeros(3)
            j<=3 ? (t[j]=1) : (r[j-3]=1)
            for i in 1:4
                u[6i-5:6i-3]=t+cross(r,[xy[i,1],xy[i,2],0.])
                u[6i-2:6i]=r
            end
            @test norm(p.K*u)<=3e-12*norm(p.K)*max(norm(u),1)
            f=F.quad4_variable_thickness_fields(p,u)
            nscale=sqrt(sum((norm(g.A)*norm(g.Bm))^2 for g in p.fields))*max(norm(u),1)
            mscale=sqrt(sum((norm(g.D)*norm(g.Bb))^2 for g in p.fields))*max(norm(u),1)
            @test norm(f.N)<=128eps(Float64)*nscale
            @test norm(f.M)<=128eps(Float64)*mscale
        end
        e=[-.0003,.0001,.0002];u=zeros(24)
        for i in 1:4
            x,y=xy[i,:];u[6i-5]=e[1]*x+e[3]*y/2;u[6i-4]=e[2]*y+e[3]*x/2
        end
        @test dot(u,p.K*u)≈area*sum(ti)/4*dot(e,C*e) rtol=3e-12
        kg,N=F.quad4_variable_thickness_geometric(xy,u,h*C,h,ti)
        w=zeros(24);grad=[.4,-.7]
        for i in 1:4;w[6i-3]=dot(grad,xy[i,:]);end
        expected=sum(f.weight*f.t for f in p.fields)*
            (grad[1]^2*(C*e)[1]+grad[2]^2*(C*e)[2]+2prod(grad)*(C*e)[3])
        @test dot(w,kg*w)≈expected rtol=3e-12
        @test all(N[i,:]≈p.fields[i].t*(C*e) for i in 1:4)
        rho=ortho ? 1599. : 2700.;nsm=.8
        m=F.quad4_variable_thickness_mass(xy,ti,rho;nsm=nsm)
        m0=F.quad4_variable_thickness_mass(xy,ti,rho)
        for j in 1:3
            v=zeros(24);v[j:6:end].=1
            @test dot(v,m*v)≈area*(rho*sum(ti)/4+nsm) rtol=1e-13
            @test dot(v,(m-m0)*v)≈area*nsm rtol=1e-13
        end
        @test iszero(norm(m[4:6:end,:]))
        @test iszero(norm(m[5:6:end,:]))
        for hu in (.002,.006)
            q=F.quad4_variable_thickness_packet(xy,h*C,h^3*C/12,Cs,h,E,fill(hu,4);k6rot=1.)
            k=F.stiffness_quad4_matrices(xy,hu*C,hu^3*C/12,Cs*(hu/h),hu,E;
                k6rot=1.,kernel_planar=true,kernel_mode="macneal",membrane_incomp=true,bending_incomp=true)
            @test q.K≈k rtol=3e-12
        end
    end
    @test_throws ArgumentError F.quad4_variable_thickness_packet(xy,ones(3,3),ones(3,3),ones(2,2),.003,1.,[.001,0.,.001,.001])
end
end
