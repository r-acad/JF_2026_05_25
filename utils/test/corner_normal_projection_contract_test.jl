using Test
module CornerNormalProjectedContractFixture
using Test, OpenJFEM, LinearAlgebra
const F=OpenJFEM.FEM
@testset "Corner-normal work uses actual projection contract" begin
    A=[130. 17. 6.;17. 65. -4.;6. -4. 28.]
    D=[.22 .03 .01;.03 .13 -.008;.01 -.008 .06]
    B=[.07 .01 -.02;.01 -.04 .005;-.02 .005 .02]
    Cs=[18. 3.;3. 11.]
    xy=[-1. -.6;1. -.6;1. .6;-1. .6]
    xyz=hcat(xy,[.07,-.07,.07,-.07])
    pq=hcat([.12 -.19;-.03 .22;-.17 .08;.09 -.13],ones(4))
    for coupling in (nothing,B),center_only in (false,true)
        kw=(Bmb=coupling,kernel_mode="macneal",bending_incomp=false,
            shear_center_only=center_only,membrane_incomp=true,k6rot=1.)
        primitive=F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,kernel_planar=false)
        P=F.quad4_physical_displacement_map(xy,xyz,pq)
        mapped=F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,
            kernel_planar=false,coords_3d=xyz,snorm_pq=pq)
        @test isapprox(mapped,P'*primitive*P;rtol=5e-13,atol=2e-13)
        @test isapprox(mapped,mapped';rtol=3e-14,atol=3e-14)
        @test minimum(eigvals(Symmetric(mapped)))>=-5e-13*opnorm(mapped)
        selected=F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,
            kernel_planar=true,coords_3d=xyz,snorm_pq=pq)
        @test isapprox(mapped,selected;rtol=5e-13,atol=2e-13)
        for omega in ([1.,0.,0.],[0.,1.,0.],[0.,0.,1.])
            rigid=zeros(24)
            for i=1:4
                rigid[(6i-5):(6i-3)]=cross(omega,xyz[i,:])
                rigid[(6i-2):6i]=omega
            end
            @test norm(mapped*rigid)<=2e-12*opnorm(mapped)*norm(rigid)
        end
        # Same physical work in a length unit 1000 times smaller; E scales
        # inversely with length squared, A/Cs inversely and D directly.
        s=1000.;U=Diagonal([j<=3 ? s : 1. for i=1:4 for j=1:6])
        scaled=F.stiffness_quad4_matrices(s*xy,A/s,s*D,Cs/s,s*.08,150.0/s^2;
            kw...,kernel_planar=false,coords_3d=s*xyz,snorm_pq=pq)
        @test isapprox(U'*scaled*U,s*mapped;rtol=1e-11,atol=1e-9)
    end
    kw=(coords_3d=xyz,snorm_pq=pq,kernel_planar=false,kernel_mode="macneal")
    @test_throws ArgumentError F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,curvature_membrane=[.1,.0,.0])
    @test_throws ArgumentError F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,slope_membrane=zeros(9))
    @test_throws ArgumentError F.stiffness_quad4_matrices(xy,A,D,Cs,.08,150.;kw...,marguerre_warp_to_uz=true)
end
end
