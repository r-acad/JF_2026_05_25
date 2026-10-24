using Test, LinearAlgebra, OpenJFEM

@testset "Section equilibrium and analytic shape gradients" begin
    parser=OpenJFEM.ReferenceParser
    dims=[.04,.05,.004,.003]
    section=parser.t_section_warping(dims...)
    @test section.J>0 && -.012<section.N1<-.011
    @test 0<section.K1<1 && 0<section.K2<1
    @test section.relative_change<=1e-4
    # Euler's homogeneous-function identities independently check dimensions
    # and the centroid terms in the implicit derivatives.
    @test dot(collect(section.J_gradient),dims)≈4section.J rtol=1e-7
    @test dot(collect(section.N1_gradient),dims)≈section.N1 rtol=1e-7
    @test abs(dot(collect(section.K1_gradient),dims))<1e-7
    @test abs(dot(collect(section.K2_gradient),dims))<1e-7
    scaled=parser.t_section_warping((1000dims)...)
    @test scaled.J≈section.J*1e12 rtol=1e-7
    @test scaled.N1≈1000section.N1 rtol=1e-7
    @test scaled.K1≈section.K1 rtol=1e-7
    # Independent perturbations verify the exact derivative, never provide
    # the production tangent. The step exceeds sparse-solve roundoff in J.
    for k in 1:4
        step=dims[k]*1e-3
        plus=copy(dims);minus=copy(dims);plus[k]+=step;minus[k]-=step
        p=parser._t_section_warping_mesh(plus...,section.resolution)
        m=parser._t_section_warping_mesh(minus...,section.resolution)
        for (field,gradient) in ((:J,:J_gradient),(:N1,:N1_gradient),(:K1,:K1_gradient),(:K2,:K2_gradient))
            fd=(getproperty(p,field)-getproperty(m,field))/(2step)
            @test isapprox(fd,getproperty(section,gradient)[k];rtol=2e-5)
        end
    end
    # Both zero outstand and zero web height reduce exactly to a rectangle.
    r1=parser.t_section_warping(.04,.05,.004,.04)
    r2=parser.t_section_warping(.04,.05,.05,.003)
    @test r1.J==r2.J
    @test r1.N1==r2.N1==0
    @test r1.K1==r1.K2==r2.K1==r2.K2==5/6
    @test r1.J_gradient===r2.J_gradient===nothing
    square=parser.t_section_warping(1.,1.,.2,1.)
    @test square.J≈.1405770149552 rtol=1e-10
    @test_throws ArgumentError parser.t_section_warping(0.,.05,.004,.003)
    @test_throws ArgumentError parser.t_section_warping(.04,.05,1e-10,.003)
    @test_throws ArgumentError parser.t_section_warping(.04,.05,.004,.041)
end

@testset "Consistent beam mass conserves physical section inertia" begin
    rho,area,length_m=2700.,.0006,2.
    i1,i2=2e-8,4.5e-8
    mass=rho*area*length_m
    M=OpenJFEM.FEM.consistent_mass_frame3d(length_m,rho,area,i1,i2)
    @test M[7,7]≈mass/3
    @test M[1,7]≈mass/6
    @test M[10,10]≈rho*(i1+i2)*length_m/3
    @test minimum(eigvals(Symmetric(M)))>0
    for component in 1:3
        rigid=zeros(12);rigid[component]=rigid[component+6]=1
        @test dot(rigid,M*rigid)≈mass
    end
end
