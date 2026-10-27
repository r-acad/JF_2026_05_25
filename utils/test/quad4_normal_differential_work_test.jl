using Test
module NormalMomentDifferentialWorkFixture
using Test, OpenJFEM, LinearAlgebra
const F=OpenJFEM.FEM

# Direct scalar kinematics and strains; no production map or strain routine.
function gradients(xy,r,s)
    dr=.25 .* [-(1-s),1-s,1+s,-(1+s)]
    ds=.25 .* [-(1-r),-(1+r),1+r,1-r]
    D=permutedims(hcat(dr,ds))
    (D*xy)\D
end
function scalar_normal_action(xy,pq,u)
    v=copy(u)
    for (i,(r,s)) in enumerate(((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.)))
        d=gradients(xy,r,s);p,q=pq[i,1],pq[i,2]
        spin=(dot(d[1,:],u[2:6:end])-dot(d[2,:],u[1:6:end]))/2
        delta=u[6i]-spin
        v[6i-2]=u[6i-2]-p*delta
        v[6i-1]=u[6i-1]-q*delta
        v[6i]=u[6i]+p*(u[6i-2]-dot(d[2,:],u[3:6:end]))+
                         q*(u[6i-1]+dot(d[1,:],u[3:6:end]))
    end
    v
end
function membrane_oracle(xy,u,A)
    d0=gradients(xy,0.,0.)
    gamma=dot(d0[2,:],u[1:6:end])+dot(d0[1,:],u[2:6:end])
    q=inv(sqrt(3.));out=zeros(4,3)
    for (j,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
        d=gradients(xy,r,s)
        out[j,:]=A*[dot(d[1,:],u[1:6:end]),dot(d[2,:],u[2:6:end]),gamma]
    end
    out
end
@testset "Normal-moment transport preserves uncoupled differential work" begin
    A=[130. 17. 6.;17. 65. -4.;6. -4. 28.]
    trans=[6i+j for i=0:3 for j=1:3]
    R=Matrix{Float64}(I,24,24)[trans,:]
    pq=hcat([.17 -.21;.09 .31;-.24 .08;.11 -.16],ones(4))
    geometries=([-1. -.6;1. -.6;1. .6;-1. .6],
                [-1. -.5;1. -.4;1.3 .7;-.7 .6],
                [-1. -.7;1.2 -.5;.8 .9;-.6 .6])
    for xy0 in geometries,scale in (.2,3.)
        xy=scale*xy0
        M=F.quad4_snorm_normal_moment_displacement_map(xy,pq)
        u=sin.(collect(1.:24.))*.003
        @test isapprox(M*u,scalar_normal_action(xy,pq,u);rtol=2e-14,atol=1e-15)
        @test R*M==R
        expected=membrane_oracle(xy,u,A)
        @test isapprox(F.quad4_differential_membrane_force_field(xy,u,A,nothing)[1],expected;rtol=3e-14,atol=1e-14)
        @test isapprox(F.quad4_differential_membrane_force_field(xy,M*u,A,nothing)[1],expected;rtol=3e-14,atol=1e-14)
        # Every symmetric TT-only metric, including signed/compressive work,
        # has this exact congruence identity independently of interpolation.
        H=reshape(cos.(collect(1.:144.)),12,12);H=(H+H')/2
        G=R'*H*R
        @test M'*G*M==G
        for omega in ([1.,0.,0.],[0.,1.,0.],[0.,0.,1.])
            rigid=zeros(24)
            for i=1:4
                rigid[(6i-5):(6i-3)]=cross(omega,[xy[i,1],xy[i,2],0.])
                rigid[(6i-2):6i]=omega
            end
            @test isapprox(M*rigid,rigid;rtol=2e-14,atol=2e-14)
        end
        aligned=hcat(zeros(4,2),ones(4))
        @test !F.quad4_snorm_pq_has_active_rows(aligned)
        @test F.quad4_snorm_pq_has_active_rows(pq)
        @test F.quad4_snorm_normal_moment_displacement_map(xy,aligned)==Matrix{Float64}(I,24,24)
        for zsign in (-1.,1.)
            xyz=hcat(xy,zsign*scale*[.018,-.018,.018,-.018])
            W=F.quad4_finite_warp_displacement_map(xy,xyz)
            @test W!==nothing
            P=F.quad4_physical_displacement_map(xy,xyz,pq)
            @test isapprox(R*P,R*W;rtol=2e-14,atol=2e-14)
            @test isapprox(P'*G*P,W'*G*W;rtol=5e-14,atol=5e-14)
            @test isapprox(membrane_oracle(xy,P*u,A),membrane_oracle(xy,W*u,A);rtol=5e-14,atol=2e-14)
            n=F.quad4_differential_membrane_force_field(xy,u,A,nothing;coords_3d=xyz)[1]
            @test isapprox(n,membrane_oracle(xy,W*u,A);rtol=5e-14,atol=2e-14)
        end
    end
    # The proof is deliberately uncoupled. Normal-moment transport can change
    # curvature; dropping it from a nonzero-B field is not licensed here.
    xy=first(geometries);u=sin.(collect(1.:24.))*.003
    M=F.quad4_snorm_normal_moment_displacement_map(xy,pq)
    B=[.3 .1 -.2;.1 -.4 .05;-.2 .05 .2]
    @test norm(F.quad4_differential_membrane_force_field(xy,M*u,A,B)[1]-
               F.quad4_differential_membrane_force_field(xy,u,A,B)[1])>1e-6
end
end

module NormalDifferentialScopeFixture
using Test, OpenJFEM
const S=OpenJFEM.Solver
@testset "Normal-moment differential dispatch domain" begin
    eligible=S.kg_quad4_normal_moment_differential_enabled
    @test eligible(true,false,true)
    @test eligible(true,true,false)
    @test eligible(true,true,true)
    @test !eligible(false,false,true)
    @test !eligible(false,true,false)
    @test !eligible(true,false,false) # separate anisotropic PSHELL material-frame scope
    @test !eligible(true,true,false;Bmb=zeros(3,3))
    @test !eligible(true,false,true;Bmb=true) # MID4 coupling sentinel
    @test !eligible(true,true,false;kernel_mode="mitc4")
    for flag in (:director,:transform_only,:use_geom,:mitc,:curved_transform,:alternate_plate)
        @test !eligible(true,true,false;(flag=>true,)...)
    end
    @test !eligible(true,true,false;normal_moment=false)
    @test !eligible(true,true,false;curvature=zeros(3))
    @test !eligible(true,true,false;slope=zeros(3))
    @test !eligible(true,true,false;surface_mode=:covariant)
    @test !eligible(true,true,false;surface_mode=:unrecognized)
    @test !eligible(true,true,false;trans_mode=:all)
    @test !eligible(true,true,false;trans_mode=:normal_only)
end
end
