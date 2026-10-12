using Test

module MacnealTaperEnergyContinuityFixture
using Test, LinearAlgebra, OpenJFEM, ForwardDiff
const F=OpenJFEM.Solver.FEM

function section(h, orthotropic, coupled)
    E1=orthotropic ? 135e9 : 70e9; E2=orthotropic ? 8.5e9 : E1
    nu=.27; G=orthotropic ? 4.8e9 : E1/(2(1+nu))
    Q=OpenJFEM.laminate_plane_stress_qbar(E1,E2,nu,G,.37)
    R=[cos(.37) -sin(.37);sin(.37) cos(.37)]
    shear=orthotropic ? [5.1e9 0.;0. 3.2e9] : G*Matrix{Float64}(I,2,2)
    (A=h*Q,B=coupled ? .1h^2*Q : nothing,D=h^3/12*Q,Cs=(5/6)*h*(R'*shear*R))
end

function shear(X,h,orthotropic,coupled)
    c=section(h,orthotropic,coupled);K=zeros(typeof(h),24,24)
    workspace=F.create_macneal_shear_workspace(typeof(h))
    F.add_quad4_macneal_shear_rbf!(K,X,c.D,c.Cs,h;Cm=c.A,Bmb=c.B,msws=workspace)
    K,copy(workspace.Z_total)
end

function full(X,h,orthotropic,coupled)
    c=section(h,orthotropic,coupled)
    F.stiffness_quad4_matrices(X,c.A,c.D,c.Cs,h,orthotropic ? 135e9 : 70e9;
        Bmb=c.B,kernel_mode="macneal",membrane_incomp=false,bending_incomp=true)
end

function run_checks()
    affine=[0. 0.;.02 .004;.022 .014;.002 .010]
    fan=[.001,-.0004];signs=[1.,-1.,1.,-1.]
    geometry(scale)=affine+scale*signs*fan'
    for (orthotropic,coupled) in ((false,false),(true,false),(true,true))
        h=.001;c=section(h,orthotropic,coupled)
        B=c.B===nothing ? zeros(3,3) : c.B
        @test minimum(eigvals(Symmetric([c.A B;B c.D])))>0
        K0,Z0=shear(geometry(0.),h,orthotropic,coupled)
        @test minimum(eigvals(Symmetric(Z0)))>0
        for scale in (1.,.1,.01,1e-4,1e-6)
            X=geometry(scale);Ks,Z=shear(X,h,orthotropic,coupled)
            @test minimum(eigvals(Symmetric(Z)))>0
            @test minimum(eigvals(Symmetric(Ks)))>=-2e-12*norm(Ks)
            if scale<=1e-4
                @test norm(Ks-K0)/norm(K0)<3scale
            end
        end
        for (X,twist_representable) in ((geometry(0.),false),(geometry(1.),false),
                ([0. 0.;.02 0.;.02 .01;0. .01],true))
            K=full(X,h,orthotropic,coupled)
            @test minimum(eigvals(Symmetric(K)))>=-2e-12*norm(K)
            rb=zeros(24,6)
            for i in 1:4,j in 1:3
                e=zeros(3);e[j]=1
                rb[6(i-1)+1:6(i-1)+3,j]=e
                rb[6(i-1)+1:6(i-1)+3,j+3]=cross(e,[X[i,1],X[i,2],0.])
                rb[6(i-1)+4:6i,j+3]=e
            end
            @test all(norm(K*rb[:,j])<2e-12*norm(K)*norm(rb[:,j]) for j in 1:6)
            area=abs(sum(X[i,1]*X[mod1(i+1,4),2]-X[mod1(i+1,4),1]*X[i,2] for i in 1:4))/2
            patches=[([.0007,-.0003,.0004],zeros(3))]
            # w=x*y is a bilinear FE field on a Cartesian rectangle. On a
            # general skew cell it includes quadratic natural-coordinate
            # terms, so it is not an exact constant-curvature patch there.
            twist_representable && append!(patches,
                [(zeros(3),[0.,0.,.002]),([.0007,-.0003,.0004],[0.,0.,.002])])
            for (epsilon,kappa) in patches
                u=zeros(24)
                for i in 1:4
                    x,y=X[i,:]
                    u[6(i-1)+1]=epsilon[1]*x+.5epsilon[3]*y
                    u[6(i-1)+2]=epsilon[2]*y+.5epsilon[3]*x
                    u[6(i-1)+3]=-.5kappa[3]*x*y
                    u[6(i-1)+4]=-.5kappa[3]*x
                    u[6(i-1)+5]=.5kappa[3]*y
                end
                expected=area*(dot(epsilon,c.A*epsilon)+dot(kappa,c.D*kappa)+2dot(epsilon,B*kappa))
                @test isapprox(dot(u,K*u),expected;rtol=2e-10)
            end
        end
        # The changed arithmetic is shared by production and forward AD;
        # verify a physical thickness derivative, without a clipped spectrum.
        X=geometry(1.);step=1e-8
        original=first(shear(X,h,orthotropic,coupled))
        for shift in 1:3
            # A cyclic node renumbering plus the corresponding quarter-turn
            # element basis describes the same physical strain energy.
            perm=circshift(collect(1:4),shift)
            dofs=vcat([collect(6(i-1)+1:6i) for i in perm]...)
            co=round(cos(-shift*pi/2));si=round(sin(-shift*pi/2))
            Q=[co -si;si co]
            C=[co^2 si^2 -co*si;si^2 co^2 co*si;2co*si -2co*si co^2-si^2]
            R=zeros(6,6);R[1:2,1:2]=Q;R[3,3]=1.;R[4:5,4:5]=Q;R[6,6]=1.
            T=kron(Matrix{Float64}(I,4,4),R)
            rotated=zeros(24,24)
            F.add_quad4_macneal_shear_rbf!(rotated,X[perm,:]*Q,C'*c.D*C,Q'*c.Cs*Q,h;
                Cm=C'*c.A*C,Bmb=c.B===nothing ? nothing : C'*c.B*C)
            @test isapprox(rotated,T'*original[dofs,dofs]*T;rtol=2e-11)
        end
        dual=first(shear(X,ForwardDiff.Dual(h,1.),orthotropic,coupled))
        analytic=map(v->ForwardDiff.partials(v)[1],dual)
        fd=(first(shear(X,h+step,orthotropic,coupled))-first(shear(X,h-step,orthotropic,coupled)))/(2step)
        @test isapprox(analytic,fd;rtol=3e-7)
    end
end
end

@testset "MacNeal taper correction preserves energy and affine limit" begin
    MacnealTaperEnergyContinuityFixture.run_checks()
end
