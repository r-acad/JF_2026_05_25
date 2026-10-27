using Test
module TriaComponentNeutralFlexibilityFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F=OpenJFEM.FEM

function section(h)
    lower=[122. 5.1 9.3;5.1 17.2 4.7;9.3 4.7 11.8]*1e9
    upper=[39. 14.2 -8.1;14.2 82. -11.7;-8.1 -11.7 24.3]*1e9
    # Independent exact thickness integrals of two equal-thickness layers.
    A=(lower+upper)*(h/2)
    B=(upper-lower)*(h*h/8)
    D=(lower+upper)*(h^3/24)
    Cs=[4.2 .3;.3 3.6]*(5e9*h/6)
    A,B,D,Cs
end
kernel(X,A,B,D,Cs,h)=F.stiffness_tria3_matrices_generic(
    X,A,D,Cs,h,one(h);Bmb=B,k6rot=0.)

function checks()
    h=.006
    A,B,D,Cs=section(h)
    neutral=F.tria3_component_neutral_bending(A,B,D)
    @test neutral !== nothing
    @test neutral == neutral'
    @test F.tria3_component_neutral_bending(A,-B,D)==neutral
    for factor in (1e-9,1.,1e9)
        @test isapprox(F.tria3_component_neutral_bending(factor*A,factor*B,factor*D),
            factor*neutral;rtol=2e-14)
    end
    # Every component is unchanged by moving the section reference surface.
    for z in (-.7h,.2h,.53h)
        shifted=F.tria3_component_neutral_bending(A,B-z*A,D-2z*B+z*z*A)
        @test isapprox(shifted,neutral;rtol=2e-14)
    end
    # Undefined neutral channels are an explicit fallback, not huge stiffness.
    aa=copy(A);bb=copy(B);aa[1,3]=aa[3,1]=0.
    @test F.tria3_component_neutral_bending(aa,bb,D)===nothing
    bb[1,3]=bb[3,1]=0.
    reduced=F.tria3_component_neutral_bending(aa,bb,D)
    @test reduced[1,3]==D[1,3]
    @test reduced[3,1]==D[3,1]

    positive=[2. .3 -.2;.3 4. .1;-.2 .1 1.]
    negative=[1. 2. 0.;2. 1. 0.;0. 0. 1.]
    singular=[1. 1. 0.;1. 1. 0.;0. 0. 1.]
    for factor in (1e-30,1.,1e30)
        @test F.tria3_positive_flexibility(factor*positive)
        @test !F.tria3_positive_flexibility(factor*negative)
        @test !F.tria3_positive_flexibility(factor*singular)
    end
    @test !F.tria3_positive_flexibility([Inf 0. 0.;0. 1. 0.;0. 0. 1.])
    @test !F.tria3_positive_flexibility([1. NaN 0.;NaN 1. 0.;0. 0. 1.])

    m=[1,2,7,8,13,14];b=[3,4,5,9,10,11,15,16,17]
    for X in ([0. 0.;.9 0.;.23 .71],
              [0. 0.;.14 0.;.93 .46],
              [0. 0.;.92 0.;.83 .37],
              [0. 0.;.73 0.;-.29 .11])
        K=kernel(X,A,B,D,Cs,h)
        @test isapprox(K,K';rtol=2e-13)
        @test minimum(eigvals(Symmetric(K))) >= -3e-12*opnorm(K)
        # A positive compatible ABD law and positive residual energy must
        # leave all six physical rigid-body motions in the kernel.
        for axis in 1:3, rotation in (false,true)
            e=zeros(3);e[axis]=1.
            u=zeros(18)
            for n in 1:3
                point=[X[n,1],X[n,2],0.]
                u[6n-5:6n-3]=rotation ? cross(e,point) : e
                rotation && (u[6n-2:6n]=e)
            end
            @test norm(K*u)<=3e-11*opnorm(K)*norm(u)
        end
        # Stack reversal changes only the compatible membrane/bending sign.
        reversed=kernel(X,A,-B,D,Cs,h)
        @test reversed[b,b]==K[b,b]
        @test reversed[m,m]==K[m,m]
        @test reversed[m,b]==-K[m,b]
        # Geometric/material changes preserve physical energy units.
        for factor in (.03,7.)
            @test isapprox(kernel(X,factor*A,factor*B,factor*D,factor*Cs,h),
                factor*K;rtol=2e-10)
        end
        scale=4.3;As,Bs,Ds,Css=section(scale*h)
        L=Diagonal(repeat([scale,scale,scale,1.,1.,1.],3))
        @test isapprox(L'*kernel(scale*X,As,Bs,Ds,Css,scale*h)*L,
            scale^3*K;rtol=2e-10)
        u=.001*cos.(1.:18.)
        energy(t)=begin aa,bb,dd,ss=section(t);dot(u,kernel(X,aa,bb,dd,ss,t)*u) end
        exact=ForwardDiff.derivative(energy,h);step=1e-4h
        finite=(energy(h+step)-energy(h-step))/(2step)
        @test isfinite(exact)
        @test isapprox(exact,finite;rtol=5e-6)
        # Reference-surface congruence is checked at high precision to avoid
        # subtracting nearly dependent plate modes in ordinary precision.
        setprecision(256) do
            x=BigFloat.(X);aa=BigFloat.(A);bb=BigFloat.(B);dd=BigFloat.(D);ss=BigFloat.(Cs);hh=BigFloat(h)
            original=kernel(x,aa,bb,dd,ss,hh)
            H=zeros(BigFloat,18,18)
            for n in 0:2;H[6n+1,6n+5]=1;H[6n+2,6n+4]=-1;end
            for z in (-.31hh,.27hh)
                shifted=kernel(x,aa,bb-z*aa,dd-2z*bb+z*z*aa,ss,hh)
                transform=Matrix{BigFloat}(I,18,18)+z*H
                @test isapprox(transform'*shifted*transform,original;rtol=big"1e-52")
            end
        end
    end
end
end
@testset "Triangle component neutral residual energy" begin
    TriaComponentNeutralFlexibilityFixture.checks()
end
