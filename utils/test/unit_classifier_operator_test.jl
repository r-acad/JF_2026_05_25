module UnitClassifierOperatorTests
using Test,LinearAlgebra,StaticArrays,OpenJFEM
const S=OpenJFEM.Solver
function model(dir,scale)
    path=joinpath(dir,"curvature_units_$(scale).bdf")
    open(path,"w") do io
        println(io,"SOL 105\nCEND\nSUBCASE 1\n SPC=1\n LOAD=1\nSUBCASE 2\n SPC=1\n STATSUB(BUCKLING)=1\n METHOD=1\nBEGIN BULK")
        println(io,"PARAM,SNORM,0\nPARAM,K6ROT,1.\nMAT1,1,7.e10,,.31,2700.")
        println(io,"PSHELL,1,1,$(scale*.004),1,,1")
        for i=0:2,j=0:2
            x=.7i;y=.45*(j-1);z=.07*(x/1.4-.5)*(y/.9)
            println(io,"GRID,$(3i+j+1),,$(scale*x),$(scale*y),$(scale*z)")
        end
        for i=0:1,j=0:1
            n=3i+j+1
            println(io,"CQUAD4,$(2i+j+1),1,$n,$(n+3),$(n+4),$(n+1)")
        end
        println(io,"SPC1,1,123456,1,2,3")
        for n=7:9;println(io,"FORCE,1,$n,, $(2.5scale^2),-1.,0.,0.");end
        println(io,"EIGRL,1,0.,,8\nENDDATA")
    end
    OpenJFEM.bdf_to_model(path)
end
@testset "Curved shell K and Kg physical-unit covariance" begin
    mktempdir() do dir
        base_model=model(dir,1.)
        base=OpenJFEM.solve_model(base_model)
        @test S._adjoint_has_active_q4_finite_warp(base_model,base["id_map"],base["node_coords"])
        for scale in (1e-3,1e3,1e6)
            current=OpenJFEM.solve_model(model(dir,scale))
            d=repeat([scale,scale,scale,1.,1.,1.],9)
            for name in ("K","K_eig","Kg")
                K=Matrix(name=="K_eig" ? only(base["buckling"].subcases).K_eig : base[name])
                Q=Matrix(name=="K_eig" ? only(current["buckling"].subcases).K_eig : current[name]) .* (d*d') ./ scale^3
                @test norm(Q-K)/norm(K)<3e-10
                # Diagonal congruence prevents strong rotational blocks from
                # concealing a weak translational/coupling discrepancy.
                w=1 ./ sqrt.(max.(abs.(diag(Matrix(base["K"]))),floatmin(Float64)))
                @test norm((Q-K).*(w*w'))/norm(K.*(w*w'))<3e-9
            end
            @test isapprox(current["eigenvalues"],base["eigenvalues"];rtol=1e-6,atol=0.)
            @test isapprox(current["u_static"]./d,base["u_static"];rtol=3e-9,atol=0.)
        end
    end
end
# A smooth cylindrical director field has resolved rank one even though its
# four sampled positions form a planar facet. This directly exercises the
# actual exact-membrane curvature operator; it is not claimed to activate
# the corner-only assembly selector on a planar facet.
@testset "Activated cylindrical exact-membrane work" begin
    F=OpenJFEM.FEM;radius=5.;theta=.2;width=2radius*sin(theta)
    xy=[-width/2 -.4;width/2 -.4;width/2 .4;-width/2 .4]
    normals=(SVector(-sin(theta),0.,cos(theta)),SVector(sin(theta),0.,cos(theta)),
             SVector(sin(theta),0.,cos(theta)),SVector(-sin(theta),0.,cos(theta)))
    basis=(SVector(1.,0.,0.),SVector(0.,1.,0.),SVector(0.,0.,1.))
    k=S.estimate_quad4_curvature_membrane(xy,normals...,basis...)
    @test isapprox(k,SVector(-1/radius,0.,0.);rtol=3e-15,atol=0.)
    @test S.q4_curvature_is_numerically_cylindrical(k,xy)
    E=7e10;nu=.3;h=.003
    A=E*h/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    D=A*h^2/12;C=5/6*E/(2*(1+nu))*h*Matrix{Float64}(I,2,2)
    kw=(k6rot=1.,membrane_incomp=false,bending_incomp=false,
        exact_membrane_operator=true,exact_membrane_curvature_w_coupling=true)
    K=F.stiffness_quad4_matrices(xy,A,D,C,h,E;kw...,curvature_membrane=k)
    Kflat=F.stiffness_quad4_matrices(xy,A,D,C,h,E;kw...,curvature_membrane=nothing)
    u=zeros(24);u[3:6:24].=1.
    strain=-[k[1],k[2],2k[3]]
    expected=width*.8*dot(strain,A*strain)
    @test expected>0
    @test isapprox(dot(u,K*u),expected;rtol=2e-12,atol=0.)
    @test abs(dot(u,Kflat*u))<=64eps()*norm(Kflat)*dot(u,u)
    for scale in (1e-3,1e3,1e6)
        ks=S.estimate_quad4_curvature_membrane(xy*scale,normals...,basis...)
        @test S.q4_curvature_is_numerically_cylindrical(ks,xy*scale)
        Ks=F.stiffness_quad4_matrices(xy*scale,A*scale,D*scale^3,C*scale,h*scale,E;kw...,curvature_membrane=ks)
        U=Diagonal(repeat([scale,scale,scale,1.,1.,1.],4))
        @test norm(U*Ks*U/scale^3-K)/norm(K)<3e-12
        @test isapprox(dot(U*u,Ks*(U*u))/scale^3,expected;rtol=3e-12,atol=0.)
    end
end
end
