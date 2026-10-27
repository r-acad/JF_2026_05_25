using Test
module OrthogonalTriangleResidualFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F=OpenJFEM.FEM

function make_flexibility(P,La,Lb,c,s,Dnormal)
    back=[1. 0.;c s]
    H=back*P*back'
    scale=6*(La/Lb)*s*Dnormal
    # A separate positive third channel, with arbitrary work coupling.
    q=[-.13,.21];z=1.7
    Z=zeros(3,3);Z[1:2,1:2]=H.*([La,Lb]*[La,Lb]')/scale+q*q'/z
    Z[1:2,3]=q;Z[3,1:2]=q;Z[3,3]=z
    Z
end

function orthogonal_block(Z,La,Lb,c,s,Dnormal)
    scale=6*(La/Lb)*s*Dnormal
    H=scale*(Z[1:2,1:2]-Z[1:2,3]*Z[3,1:2]'/Z[3,3])./([La,Lb]*[La,Lb]')
    Q=[1. 0.;-c/s 1/s]
    Q*H*Q'
end

@testset "Orthogonal residual complementary energy" begin
    for c in (-.4,0.,.6), lengths in ((.03,1.2),(1.,.7),(3.,7.)),
        a in (-.2,1e-5,.3,2.), b in (-1.1,.02,.8)
        La,Lb=lengths;s=sqrt(1-c*c);d=.7;normal=2.3
        P=[a b;b d];Z=make_flexibility(P,La,Lb,c,s,normal);saved=copy(Z)
        changed=F.tria3_guard_bending_flexibility!(Z,La,Lb,c,s,normal)
        got=orthogonal_block(Z,La,Lb,c,s,normal)
        @test isapprox(got[2,2],d;rtol=2e-8,atol=2e-10)
        @test got[1,1]>=1e-4-3e-10
        @test got[1,2]^2 <= .85*got[1,1]*got[2,2]+2e-10
        @test isposdef(Symmetric(Z))
        @test Z[3,:]==saved[3,:]
        @test Z[:,3]==saved[:,3]
        if a>=1e-4 && b*b<=.85*a*d
            @test !changed
            @test Z==saved
        else
            @test changed
            @test isapprox(got[1,1],max(a,1e-4);rtol=2e-6,atol=3e-10)
        end
    end
    # Differentiation stays valid away from the documented clipping boundaries.
    function energy(scale)
        Z=scale*make_flexibility([-.2 .6;.6 .7],.8,.3,-.2,sqrt(.96),4.)
        F.tria3_guard_bending_flexibility!(Z,.8,.3,-.2,sqrt(.96),4/scale)
        v=[.4,-.1,.2];dot(v,Z*v)
    end
    @test isapprox(ForwardDiff.derivative(energy,1.),energy(1.);rtol=1e-10)
end
end

module TriaResidualPhysicalFrameFixture
using Test, LinearAlgebra, OpenJFEM
const F=OpenJFEM.FEM
function section(h)
    lower=[122. 5.1 9.3;5.1 17.2 4.7;9.3 4.7 11.8]*1e9
    upper=[39. 14.2 -8.1;14.2 82. -11.7;-8.1 -11.7 24.3]*1e9
    ((lower+upper)*h/2,(upper-lower)*h^2/8,
        (lower+upper)*h^3/24,[4.2 .3;.3 3.6]*(5e9*h/6))
end
function global_kernel(X,material_axis,h)
    x=X[2,:]-X[1,:];x/=norm(x)
    z=cross(x,X[3,:]-X[1,:]);z/=norm(z);y=cross(z,x)
    R=vcat(x',y',z');coords=(X.-X[1,:]')*R[1:2,:]'
    angle=atan(dot(material_axis,y),dot(material_axis,x))
    A,B,D,C=section(h)
    for M in (A,B,D);F.rotate_constitutive_3x3!(M,angle);end
    F.rotate_constitutive_2x2!(C,angle)
    K=F.stiffness_tria3_matrices_generic(coords,A,D,C,h,1.;Bmb=B,k6rot=0.)
    T=kron(Matrix{Float64}(I,6,6),R)
    T'*K*T
end
@testset "Ordered triangle residual in a rotated physical frame" begin
    axis=[cos(.73),sin(.73),0.];v=normalize([.3,-.7,.4])
    H=[0. -v[3] v[2];v[3] 0. -v[1];-v[2] v[1] 0.]
    rotation=exp(.81H);T=kron(Matrix{Float64}(I,6,6),rotation)
    for X in ([0. 0. 0.;.9 0. 0.;.2 .4 0.],
              [0. 0. 0.;.13 0. 0.;-.23 .83 0.],
              [0. 0. 0.;.004 0. 0.;.9 .3 0.])
        K=global_kernel(X,axis,.006)
        rotated=global_kernel(X*rotation'.+[1.7 -2.4 .3],rotation*axis,.006)
        @test isapprox(rotated,T*K*T';rtol=3e-10)
        @test minimum(eigvals(Symmetric(K)))>=-3e-12*opnorm(K)
        for direction in ([1.,0,0],[0.,1,0],[0.,0,1]), spin in (false,true)
            u=zeros(18)
            for n in 1:3
                u[6n-5:6n-3]=spin ? cross(direction,X[n,:]) : direction
                spin && (u[6n-2:6n]=direction)
            end
            @test norm(K*u)<=4e-11*opnorm(K)*norm(u)
        end
    end
end
end
