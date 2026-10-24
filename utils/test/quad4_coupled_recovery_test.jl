using Test
module Quad4CoupledRecoveryFixture
using Test,OpenJFEM,LinearAlgebra,Random
const F=OpenJFEM.FEM
@testset "Coupled section recovery uses the elastic kinematic energy" begin
    Random.seed!(207)
    h=.012;E=70e9
    A=[100e6 15e6 6e6;15e6 50e6 2e6;6e6 2e6 25e6]
    D=A*h^2/12
    B=h.*[1e6 -.4e6 .2e6;-.4e6 -.6e6 .1e6;.2e6 .1e6 .4e6]
    Cs=zeros(2,2)
    shapes=([0.0 0;1 0;1 1;0 1],
            [0.0 0;1 0;1.4 1;.4 1],
            [0.0 0;1 0;1.3 1;.15 .85])
    for x in shapes, membrane in (true,false), bending in (true,false)
        for geometry in (:flat,:warped,:directors), distortion in (false,true)
            xyz=geometry===:flat ? nothing : hcat(x,[.01,-.01,.01,-.01])
            pq=geometry===:directors ? [.01 .02;-.01 .01; .02 -.01;-.02 -.02] : nothing
            options=(bending_incomp=bending,membrane_incomp=membrane,
                coords_3d=xyz,snorm_pq=pq,kernel_mode="macneal",
                k6rot=0.0,drill_scale=0.0,distortion_corrections=distortion)
            u=randn(24).*1e-4
            k=F.stiffness_quad4_matrices(x,A,D,Cs,h,E;Bmb=B,options...)
            fields=F.quad4_condensed_section_fields(x,u,A,B,D,Cs,h,E;options...)
            @test all(isfinite,fields.N)
            @test norm(fields.section_force-k*u) / max(norm(k*u),1.0) < 2e-10
            work=fields.section_kinematic ? fields.shape_internal_work : fields.internal_work
            membrane && @test norm(work[1:4])/max(norm(k*u),1.0) < 2e-10
            bending && @test norm(work[5:8])/max(norm(k*u),1.0) < 2e-10
            energy=sum(fields.weights[i]*(dot(fields.eps[i,:],fields.N[i,:])+
                dot(fields.kappa[i,:],fields.M[i,:])) for i in 1:4)
            @test isapprox(energy,dot(u,k*u);rtol=2e-10,atol=1e-10)
            N,Na,w=F.quad4_coupled_membrane_force_field(x,u,A,B,D,Cs,h,E;options...)
            @test N==fields.N
            @test Na==fields.N_average
            @test w==fields.weights
        end
    end
    # The production kinematic maps depend on A, so changing D at fixed u
    # preserves strains and N while changing M by exactly the added D*kappa.
    x=shapes[2];u=randn(24).*1e-4
    n1=F.quad4_condensed_section_fields(x,u,A,B,D,Cs,h,E;k6rot=0.0)
    n2=F.quad4_condensed_section_fields(x,u,A,B,2D,Cs,h,E;k6rot=0.0)
    @test n1.section_kinematic && n2.section_kinematic
    @test isapprox(n1.N,n2.N;rtol=2e-12)
    @test isapprox(n1.kappa,n2.kappa;rtol=2e-12)
    @test isapprox(n2.M-n1.M,n1.kappa*D';rtol=2e-12)
    # Explicit stationary legacy mode remains available and is tested separately.
    old1=F.quad4_condensed_section_fields(x,u,A,B,D,Cs,h,E;k6rot=0.0,distortion_corrections=false)
    old2=F.quad4_condensed_section_fields(x,u,A,B,2D,Cs,h,E;k6rot=0.0,distortion_corrections=false)
    @test !old1.section_kinematic && !old2.section_kinematic
    @test norm(old1.N-old2.N)>1e-6*norm(old1.N)
    result=F.stress_strain_quad4(x,u,E,.3,h,h;Cm_override=A,
        Bmb_override=B,Cb_override=D,Cs_override=Cs,coupled_condensed=true,
        recover_corners=true,recover_shear=false)
    @test isapprox(result[1],n1.N_average)
    @test isapprox(result[2],-n1.M_average)
    @test isapprox(result[6],n1.eps_average-h/2*n1.kappa_average)
    @test isapprox(result[7],n1.eps_average+h/2*n1.kappa_average)
    for (i,(r,s)) in enumerate(((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.)))
        @test isapprox(result[8][i,:],F.interp_2x2_gauss_sigma(n1.N,r,s))
        @test isapprox(result[9][i,:],-F.interp_2x2_gauss_sigma(n1.M,r,s))
    end
    # Pure constant membrane strain generates a real laminate bending moment B'eps.
    # The former A-only/uncoupled recovery incorrectly returned zero moment here.
    ua=zeros(24);strain=[.001,-.0002,.0003]
    for i in 1:4
        ua[6i-5]=strain[1]*x[i,1]+strain[3]/2*x[i,2]
        ua[6i-4]=strain[2]*x[i,2]+strain[3]/2*x[i,1]
    end
    ra=F.stress_strain_quad4(x,ua,E,.3,h,h;Cm_override=A,
        Bmb_override=B,Cb_override=D,Cs_override=Cs,coupled_condensed=true,
        recover_shear=false)
    @test isapprox(ra[1],A*strain;rtol=2e-12)
    @test isapprox(ra[2],-B'*strain;rtol=2e-12)
    @test isapprox(ra[6],strain;rtol=2e-12)
    @test isapprox(ra[7],strain;rtol=2e-12)
end
end
