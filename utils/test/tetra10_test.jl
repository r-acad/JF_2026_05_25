using Test

module QuadraticSolidFixture
using Test, LinearAlgebra, StaticArrays
include(joinpath(@__DIR__,"..","..","src","FEMKernels.jl"))
const F = FEM
isdefined(F,:stiffness_tetra10) || Base.include(F,joinpath(@__DIR__,"..","..","src","tetra10.jl"))

const EDGES = ((1,2),(2,3),(1,3),(1,4),(2,4),(3,4))
function tetra(corners)
    X = zeros(10,3); X[1:4,:] .= corners
    for (n,(i,j)) in enumerate(EDGES); X[n+4,:] .= (corners[i,:]+corners[j,:])/2; end
    X
end
displacements(X,A) = vec(permutedims(X*A'))
function rigid_vectors(X)
    R=zeros(3size(X,1),6)
    for i in axes(X,1)
        x,y,z=X[i,:]; c=3(i-1)
        R[c+1,1]=1;R[c+2,2]=1;R[c+3,3]=1
        R[c+2,4]=-z;R[c+3,4]=y
        R[c+1,5]=z;R[c+3,5]=-x
        R[c+1,6]=-y;R[c+2,6]=x
    end
    R
end
function exact_mass(X,rho)
    # Independent barycentric monomial integrals: detJ*prod(alpha!)/(sum(alpha)+3)!.
    terms = Vector{Vector{Tuple{Float64,NTuple{4,Int}}}}()
    for i in 1:4
        push!(terms,[(2.0,ntuple(k->k==i ? 2 : 0,4)),(-1.0,ntuple(k->k==i ? 1 : 0,4))])
    end
    for (i,j) in EDGES;push!(terms,[(4.0,ntuple(k->k==i||k==j ? 1 : 0,4))]);end
    detJ=det(permutedims(X[2:4,:].-X[1,:]'))
    scalar=zeros(10,10)
    for i in 1:10,j in 1:10,(a,p) in terms[i],(b,q) in terms[j]
        alpha=p.+q
        scalar[i,j]+=rho*detJ*a*b*prod(factorial.(alpha))/factorial(sum(alpha)+3)
    end
    kron(scalar,Matrix{Float64}(I,3,3))
end

@testset "Full quadratic TETRA10 interpolation and energy" begin
    X=tetra([0. 0. 0.;2. 0. 0.;0. 3. 0.;0. 0. 4.]); V=4.; E=210e9;nu=.29
    natural=tetra([0. 0. 0.;1. 0. 0.;0. 1. 0.;0. 0. 1.])
    for i in 1:10
        N,dN=F._tetra10_shape(natural[i,1],natural[i,2],natural[i,3])
        @test N ≈ [j==i ? 1.0 : 0.0 for j in 1:10] atol=2e-15
        @test sum(N)≈1.0
        @test norm(sum(dN;dims=2)) < 2e-15
    end
    K=F.stiffness_tetra10(X,E,nu);R=rigid_vectors(X)
    @test size(K)==(30,30)
    @test issymmetric(K)
    @test norm(K*R) < 2e-14*norm(K)*norm(R)
    roots=eigvals(Symmetric(K));@test count(x->abs(x)<maximum(roots)*1e-10,roots)==6
    @test roots[7]>maximum(roots)*1e-4
    A=[.002 .001 -.0004;-.0002 -.0007 .0003;.0008 -.0006 .0011]
    u=displacements(X,A);strain=[A[1,1],A[2,2],A[3,3],A[1,2]+A[2,1],A[2,3]+A[3,2],A[3,1]+A[1,3]]
    D=F.iso_3d_constitutive(E,nu)
    @test F.solid_centroid_B_tetra10(X)*u≈strain rtol=2e-14
    @test dot(u,K*u)≈V*dot(strain,D*strain) rtol=2e-14
    q=zeros(30);q[1:3:end].=X[:,1].^2
    @test dot(q,K*q)≈1.6V*D[1,1] rtol=2e-14
    @test norm(K[13:30,13:30])>0
    # An affine transformation with skew and rotation must retain patch accuracy.
    affine=[1. .2 -.1;.3 1.1 .05;.1 -.15 .9];Xs=X*affine'.+[.4 -.2 1.]
    Ks=F.stiffness_tetra10(Xs,E,nu);us=displacements(Xs,A)
    @test dot(us,Ks*us)≈V*det(affine)*dot(strain,D*strain) rtol=3e-14
    @test norm(Ks*rigid_vectors(Xs)) < 2e-14*norm(Ks)*norm(rigid_vectors(Xs))
    curved=copy(X);curved[5,:].+=[.03,.04,-.02];curved[9,:].+=[-.02,.01,.05]
    Kc=F.stiffness_tetra10(curved,E,nu)
    @test all(isfinite,Kc)
    @test eigmin(Symmetric(Kc))>-norm(Kc)*1e-13
    @test norm(Kc*rigid_vectors(curved))<2e-14*norm(Kc)*norm(rigid_vectors(curved))
    @test F.solid_centroid_B_tetra10(curved)*displacements(curved,A)≈strain rtol=2e-14
    inverted=copy(X);inverted[:,1].*=-1
    @test_throws DomainError F.stiffness_tetra10(inverted,E,nu)
    @test_throws DomainError F.consistent_mass_tetra10(inverted,1.)
    @test_throws DimensionMismatch F.stiffness_tetra10(X[1:4,:],E,nu)
    @test_throws ArgumentError F.stiffness_tetra10(X,E,.5)
    @test_throws ArgumentError F.stiffness_tetra10(X,-E,nu)
end

@testset "Consistent quadratic mass and initial stress" begin
    X=tetra([0. 0. 0.;2. 0. 0.;0. 3. 0.;0. 0. 4.]);rho=7850.;V=4.;E=210e9;nu=.29
    M=F.consistent_mass_tetra10(X,rho)
    @test issymmetric(M)
    @test M≈exact_mass(X,rho) rtol=3e-14
    @test eigmin(Symmetric(M))>0
    for axis in 1:3
        t=zeros(30);t[axis:3:end].=1
        @test dot(t,M*t)≈rho*V rtol=3e-14
        @test sum(M[axis,axis:3:end])≈-rho*V/20 rtol=3e-14
    end
    curved=copy(X);curved[5,:].+=[.03,.04,-.02]
    @test eigmin(Symmetric(F.consistent_mass_tetra10(curved,rho)))>0
    @test_throws ArgumentError F.consistent_mass_tetra10(X,-1.)
    stress=[1.1e6,.7e6,.3e6,.1e6,-.05e6,.02e6]
    Kg=F.geometric_stiffness_tetra10(X,stress)
    @test issymmetric(Kg)
    @test eigmin(Symmetric(Kg))>-norm(Kg)*1e-13
    @test norm(Kg*rigid_vectors(X)[:,1:3])<1e-14*norm(Kg)
    @test F.geometric_stiffness_tetra10(X,-stress)≈-Kg
    D=F.iso_3d_constitutive(E,nu);strain=D\stress
    A=[strain[1] strain[4]/2 strain[6]/2;strain[4]/2 strain[2] strain[5]/2;strain[6]/2 strain[5]/2 strain[3]]
    @test F.geometric_stiffness_tetra10(X,displacements(X,A),E,nu)≈Kg rtol=2e-14
    q=zeros(30);q[1:3:end].=X[:,1].^2
    @test dot(q,F.geometric_stiffness_tetra10(X,[2.,0.,0.,0.,0.,0.])*q)≈3.2V rtol=2e-14
    @test norm(F.geometric_stiffness_tetra10(X,q,E,nu)-F.geometric_stiffness_tetra10(X,D*(F.solid_centroid_B_tetra10(X)*q)))>1e-3
    @test_throws DimensionMismatch F.geometric_stiffness_tetra10(X,zeros(12),E,nu)
end

@testset "C3D8 mean-dilatation without incompatible modes" begin
    X=[0. 0. 0.;2. 0. 0.;2. 3. 0.;0. 3. 0.;0. 0. 4.;2. 0. 4.;2. 3. 4.;0. 3. 4.]
    E=70e9;nu=.3;A=[.002 .001 -.0004;-.0002 -.0007 .0003;.0008 -.0006 .0011]
    strain=[A[1,1],A[2,2],A[3,3],A[1,2]+A[2,1],A[2,3]+A[3,2],A[3,1]+A[1,3]];D=F.iso_3d_constitutive(E,nu);u=displacements(X,A)
    K=F.stiffness_hexa8_abaqus(X,E,nu);full=F.stiffness_hexa8_full(X,E,nu;mean_dilatation=false)
    @test issymmetric(K)
    @test dot(u,K*u)≈24dot(strain,D*strain) rtol=2e-14
    @test dot(u,full*u)≈24dot(strain,D*strain) rtol=2e-14
    @test norm(K*rigid_vectors(X))<2e-14*norm(K)*norm(rigid_vectors(X))
    roots=eigvals(Symmetric(K));@test count(x->abs(x)<maximum(roots)*1e-10,roots)==6
    @test norm(full-K)>norm(K)*1e-3
    @test eigmin(Symmetric(full-K))>-norm(K)*1e-13
    distorted=copy(X);distorted[7,:].+=[.2,.3,-.1]
    @test eigmin(Symmetric(F.stiffness_hexa8_abaqus(distorted,E,.499)))>-norm(K)*1e-10
    @test F.solid_centroid_B_hexa8_abaqus(distorted)*displacements(distorted,A)≈strain rtol=2e-14
    @test norm(F.solid_centroid_B_hexa8_abaqus(distorted)-F.solid_centroid_B_hexa8(distorted))>1e-4
    @test F.solid_centroid_B_hexa8_abaqus(X)≈F.solid_centroid_B_hexa8(X) rtol=2e-14 atol=1e-16
    inverted=copy(X);inverted[:,1].*=-1
    @test_throws DomainError F.stiffness_hexa8_abaqus(inverted,E,nu)
end
end
