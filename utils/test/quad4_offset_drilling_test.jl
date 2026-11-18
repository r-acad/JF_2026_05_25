using Test,LinearAlgebra,ForwardDiff,OpenJFEM
module Quad4OffsetDrillingFixture
using Test,LinearAlgebra,ForwardDiff,OpenJFEM
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

function independent_drill(x,Cm,k)
    dn(r,s)=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]/4
    J0=dn(0.,0.)*x;alpha=k*1e-6*Cm[3,3]*4abs(det(J0));D=zeros(eltype(Cm),24,24)
    for (i,(r,s)) in enumerate(((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.)))
        J=dn(r,s)*x;grad=J\dn(r,s);b=zeros(eltype(Cm),24)
        for j=1:4;b[6j-5]=grad[2,j]/2;b[6j-4]=-grad[1,j]/2;end
        b[6i]=1.;D+=alpha*abs(det(J))/max(abs(det(J0)),1e-30)*(b*b')
    end
    D
end
function laws(h,anisotropic)
    Q=anisotropic ? 1e9*[110. 22. 6.;22. 40. -3.;6. -3. 20.] :
        70e9/(1-.3^2)*[1. .3 0.;.3 1. 0.;0. 0. .35]
    h*Q,h^3/12*Q,(5/6)*(70e9/2.6)*h*Matrix{typeof(h)}(I,2,2)
end
function checks()
    shapes=([0. 0.;1. 0.;1. .6;0. .6],
            [0. 0.;.7 0.;1.1 .5;.4 .5],
            [0. 0.;1. 0.;.8 .6;.1 .6])
    for value in (0.,1e-20,-1e-20)
        A=zeros(3,3);A[3,3]=value
        D=F.quad4_grid_drilling_matrix(first(shapes),A;k6rot=1.,h=.003,E_ref=70e9)
        @test isapprox(D,independent_drill(first(shapes),A,1.);rtol=5e-14,atol=0.)
    end
    A=zeros(ForwardDiff.Dual{Nothing,Float64,1},3,3)
    A[3,3]=ForwardDiff.Dual(0.,1.)
    D=F.quad4_grid_drilling_matrix(first(shapes),A;k6rot=1.,h=.003,E_ref=70e9)
    @test all(iszero,ForwardDiff.value.(D))
    @test isapprox(map(v->ForwardDiff.partials(v)[1],D),
        independent_drill(first(shapes),[0. 0. 0.;0. 0. 0.;0. 0. 1.],1.);rtol=5e-14,atol=1e-20)
    tiny=1e-16*first(shapes);A=Matrix{Float64}(I,3,3)
    @test isapprox(F.quad4_grid_drilling_matrix(tiny,A;k6rot=1.),
        independent_drill(tiny,A,1.);rtol=5e-14,atol=1e-20)
    for x in shapes,aniso in (false,true),h in (.0015,.03)
        A,B,Cs=laws(h,aniso)
        zeroK=F.stiffness_quad4_matrices(x,A,B,Cs,h,70e9;k6rot=0.,bending_incomp=true)
        for k in (0.,1.,100.)
            K=F.stiffness_quad4_matrices(x,A,B,Cs,h,70e9;k6rot=k,bending_incomp=true)
            D=independent_drill(x,A,k)
            @test isapprox(F.quad4_grid_drilling_matrix(x,A;k6rot=k),D;rtol=5e-14,atol=1e-13)
            @test isapprox(K-zeroK,D;rtol=2e-9,atol=2e-7)
            for z in (-h/2,h/2)
                Z=Matrix{Float64}(I,24,24)
                for j=1:4;Z[6j-5,6j-1]=z;Z[6j-4,6j-2]=-z;end
                Kz=F.stiffness_quad4_matrices(x,A,B,Cs,h,70e9;
                    k6rot=k,bending_incomp=true,reference_offset=z)
                @test isapprox(Kz,Z'*(K-D)*Z+D;rtol=3e-14,atol=2e-7)
                @test norm(Kz-Kz')<5e-13norm(Kz)
                @test eigmin(Symmetric(Kz))>-5e-13norm(Kz)
                for axis=1:3
                    e=zeros(3);e[axis]=1.;q=zeros(24)
                    for j=1:4;q[6j-5:6j-3]=cross(e,[x[j,1],x[j,2],0.]);q[6j-2:6j]=e;end
                    @test norm(Kz*q)<2e-11norm(Kz)*max(1.,norm(q))
                end
            end
        end
        # Dual thickness jets differentiate the physical constitutive law AND
        # the unshifted GRID-plane penalty. The offset is held physically fixed.
        z=h/2
        kernel(t)=begin a,b,cs=laws(t,aniso);F.stiffness_quad4_matrices(x,a,b,cs,t,70e9;
            k6rot=1.,bending_incomp=true,reference_offset=z) end
        dual=kernel(ForwardDiff.Dual(h,1.));dK=map(v->ForwardDiff.partials(v)[1],dual)
        step=2e-5h;fd=(kernel(h+step)-kernel(h-step))/(2step)
        @test isapprox(dK,fd;rtol=2e-8,atol=1e-3)
    end
end

function fixture(dir,x,h,z,k;Q=Matrix{Float64}(I,3,3))
    path=joinpath(dir,"offset.bdf");xyz=hcat(x,zeros(4))*Q'.+reshape([2.,-1.,.4],1,3)
    open(path,"w") do io
        println(io,"SOL 101\nCEND\nBEGIN BULK\nPARAM,K6ROT,$k\nPARAM,SNORM,0.")
        for j=1:4;println(io,"GRID,",j,",,",join(xyz[j,:],','));end
        println(io,"MAT1,1,7.E10,,.3\nPSHELL,1,1,$h,1,,1\nCQUAD4,1,1,1,2,3,4,0.,$z\nENDDATA")
    end
    model=OpenJFEM.bdf_to_model(path);cap=S.AnalyticShellCapture(model)
    ass=S.assemble_stiffness(model;membrane_incomp=true,sol101_context=true,shell_capture=cap)
    Matrix(ass[1]),model,cap,ass
end
function assembly_checks()
    x=[0. 0.;1. 0.;1. .6;0. .6];h=.003;z=.0015
    a=.31;b=-.27;Q=[cos(b) 0. sin(b);0. 1. 0.;-sin(b) 0. cos(b)]*
        [1. 0. 0.;0. cos(a) -sin(a);0. sin(a) cos(a)]
    T=kron(Matrix{Float64}(I,8,8),Q)
    mktempdir() do dir
        for k in (0.,1.,100.)
            K,m,cap,ass=fixture(dir,x,h,z,k)
            ctx=only(values(cap.contexts))
            @test all(c->get(c.kwargs,:reference_offset,0.)==z,ctx.calls)
            Kr,_,_,_=fixture(dir,x,h,z,k;Q=Q)
            @test isapprox(Kr,T*K*T';rtol=3e-11,atol=2e-6)
            jet=S.analytic_shell_tangent(ctx,(thickness=1.,))
            step=h*2e-5;Kp,_,_,_=fixture(dir,x,h+step,z,k);Km,_,_,_=fixture(dir,x,h-step,z,k)
            @test jet.replay_error<2e-12
            @test isapprox(jet.dKe,(Kp-Km)/(2step);rtol=3e-8,atol=1e-3)
            material=S.analytic_shell_tangent(ctx,(materials=Dict(1=>(E=1.,)),))
            @test isapprox(material.dKe,K/70e9;rtol=5e-12,atol=1e-16)
            # The numerical drilling energy does not enter physical stresses:
            # preload/recovery uses the original physical surface displacement.
            u=1e-4sin.(collect(1.:24.));recovered=Dict{Symbol,Any}()
            S.assemble_geometric_stiffness(m,ass[2],ass[3],ass[5],ass[4],u,ass[8],ass[7];
                geometric_capture=(eid,data)->merge!(recovered,data))
            @test all(isfinite,recovered[:N_gp])
        end
    end
end
end
@testset "Offset physical energy and GRID-plane K6ROT stabilization" begin
    Quad4OffsetDrillingFixture.checks()
    Quad4OffsetDrillingFixture.assembly_checks()
end
