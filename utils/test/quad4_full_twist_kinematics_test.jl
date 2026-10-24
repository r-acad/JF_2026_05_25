using Test

module Quad4FullTwistKinematicsFixture
using Test,LinearAlgebra,ForwardDiff
using OpenJFEM
const FEM=OpenJFEM.FEM

function laws(p)
    z=zero(p[1]);A=[p[1] p[2] z+.5;p[2] p[3] z-.2;z+.5 z-.2 z+1.8]
    D=[p[4] p[5] z+1.1;p[5] p[6] z-.7;z+1.1 z-.7 z+4.]
    B=[z+.2 p[7] z+.03;p[7] z+.3 z-.02;z+.03 z-.02 z+.15]
    return A,B,D
end
function natural_derivatives(x,r,s)
    dn=[-(1-s) (1-s) (1+s) -(1+s);-(1-r) -(1+r) (1+r) (1-r)]/4
    j=dn*x
    return j\dn,inv(j),det(j)
end
function independent_fields(x,r,s)
    dn,j,detj=natural_derivatives(x,r,s);dc,jc,detc=natural_derivatives(x,0.,0.)
    bm=zeros(3,24);bb=zeros(3,24)
    for i=1:4
        b=6(i-1)
        bm[1,b+1]=dn[1,i];bm[2,b+2]=dn[2,i];bm[3,b+1]=dn[2,i];bm[3,b+2]=dn[1,i]
        bb[1,b+5]=dn[1,i];bb[2,b+4]=-dn[2,i];bb[3,b+5]=dn[2,i];bb[3,b+4]=-dn[1,i]
    end
    a=jc[:,1]*(-2r)*detc/detj;b=jc[:,2]*(-2s)*detc/detj
    im=[a[1] b[1] 0. 0.;0. 0. a[2] b[2];a[2] b[2] a[1] b[1]]
    ib=[0. 0. a[1] b[1];-a[2] -b[2] 0. 0.;-a[1] -b[1] a[2] b[2]]
    return bm,bb,im,ib,detj
end
function independent_energy(x,p,q)
    A,B,D=laws(p);T=eltype(A);qm=zeros(T,24,4);qb=zeros(T,24,4);hm=zeros(T,4,4);hb=zeros(T,4,4)
    gauss=(-inv(sqrt(3.)),inv(sqrt(3.)))
    for r in gauss,s in gauss
        bm,bb,im,ib,w=independent_fields(x,r,s)
        qm+=bm'*A*im*w;qb+=bb'*A*ib*w;hm+=im'*A*im*w;hb+=ib'*A*ib*w
    end
    pm=-(hm\qm');pb=-(hb\qb');energy=zero(p[1])
    for r in gauss,s in gauss
        bm,bb,im,ib,w=independent_fields(x,r,s)
        e=(bm+im*pm)*q;k=(bb+ib*pb)*q
        energy+=(dot(e,A*e)+2dot(e,B*k)+dot(k,D*k))*w
    end
    return energy
end
function kernel(x,p)
    A,B,D=laws(p)
    FEM.stiffness_quad4_matrices(x,A,D,Matrix{Float64}(I,2,2)*1e6,.004,1.;
        Bmb=B,k6rot=0.,membrane_incomp=true,bending_incomp=true,kernel_mode="macneal")
end
@testset "Full compatible twist shares the A-derived physical section field" begin
    p=[7.,1.4,3.,18.,5.,8.,.1]
    shapes=([0. 0.;1. 0.;1.5 .6;.5 .6],[-.1 0.;1.2 .05;1.1 .7;.1 .6],[-2. -.2;1. -.2;2. .2;-1. .2])
    for x in shapes
        q=zeros(24);g=[1.,-1.,1.,-1.]/2
        for i=1:4;q[6(i-1)+1]=.2g[i];q[6(i-1)+2]=g[i];q[6(i-1)+4]=-.7g[i];q[6(i-1)+5]=.3g[i];end
        K=kernel(x,p)
        @test dot(q,K*q)≈independent_energy(x,p,q) rtol=1e-9 atol=1e-10
        @test norm(K-K')<2e-12norm(K)
        @test minimum(eigvals(Symmetric(K)))>=-3e-12opnorm(K)
        R=zeros(24,6)
        for i=1:4
            xx,yy=x[i,:];b=6(i-1)
            R[b+1,1]=R[b+2,2]=R[b+3,3]=1
            R[b+3,4]=yy;R[b+4,4]=1;R[b+3,5]=-xx;R[b+5,5]=1
            R[b+1,6]=-yy;R[b+2,6]=xx;R[b+6,6]=1
        end
        @test norm(K*R)<3e-11norm(K)*norm(R)
        A,B,D=laws(p);area=sum(independent_fields(x,r,s)[5] for r in (-inv(sqrt(3.)),inv(sqrt(3.))),s in (-inv(sqrt(3.)),inv(sqrt(3.))))
        patch=zeros(24,6)
        for i=1:4
            xx,yy=x[i,:];b=6(i-1)
            patch[b+1,1]=xx;patch[b+2,2]=yy;patch[b+1,3]=yy/2;patch[b+2,3]=xx/2
            patch[b+3,4:6]=[-xx^2/2,-yy^2/2,-xx*yy/2]
            patch[b+4,4:6]=[0.,-yy,-xx/2];patch[b+5,4:6]=[xx,0.,yy/2]
        end
        @test patch'*K*patch≈area*[A B;B D] rtol=2e-10 atol=2e-10
        ga=ForwardDiff.gradient(t->dot(q,kernel(x,t)*q),p)
        ge=ForwardDiff.gradient(t->independent_energy(x,t,q),p)
        for i=eachindex(p);@test ga[i]≈ge[i] rtol=2e-8 atol=2e-9;end
    end
end

@testset "Automatic full twist preserves explicit research choices" begin
    x=[0. 0.;1. 0.;1.4 .6;.4 .6];A=[7. 1.4 .5;1.4 3. -.2;.5 -.2 1.8];D=[18. 5. 1.1;5. 8. -.7;1.1 -.7 4.];B=.02A;S=1e6Matrix{Float64}(I,2,2)
    kwargs=(Bmb=B,k6rot=0.,membrane_incomp=true,bending_incomp=true,kernel_mode="macneal")
    automatic=FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...)
    full=withenv("JFEM_Q4_MACNEAL_TWIST"=>"false") do
        FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...)
    end
    @test automatic==full
    projected=FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...,coupled_projected=true)
    projected_explicit=withenv("JFEM_Q4_MACNEAL_TWIST"=>"true") do
        FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...,coupled_projected=true)
    end
    @test projected==projected_explicit
    withenv("JFEM_Q4_SECTION_KINEMATIC_ENRICHMENT"=>"false") do
        legacy=FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...)
        explicit=withenv("JFEM_Q4_MACNEAL_TWIST"=>"true") do
            FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...)
        end
        @test legacy==explicit
    end
    withenv("JFEM_Q4_MACNEAL_TWIST"=>"false") do
        @test_throws ArgumentError FEM.stiffness_quad4_matrices(x,A,D,S,.004,1.;kwargs...,coupled_projected=true)
    end
end

end
