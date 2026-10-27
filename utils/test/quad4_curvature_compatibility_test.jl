using Test
module Quad4CurvatureCompatibilityFixture
using Test, OpenJFEM, LinearAlgebra, ForwardDiff
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

@testset "Cubic Kirchhoff curvature and coupled initial stress" begin
    A=[120. 15. 7.;15. 55. -3.;7. -3. 24.]
    B=[.8 .1 .3;.1 -.4 -.2;.3 -.2 .15]
    q=inv(sqrt(3.))
    for a in (.3,1.2), b in (.4,.9)
        xy=[-a -b;a -b;a b;-a b]
        # Differentiate physical polynomial fields, independently of the
        # element interpolation. The cubic cross terms expose the missing
        # curvature that constant-curvature and affine-rotation tests miss.
        for w in (z->z[1]^2*z[2], z->z[1]*z[2]^2,
                  z->.2z[1]^2-.3z[2]^2+.4z[1]*z[2],
                  z->.3z[1]^2*z[2]-.7z[1]*z[2]^2+.2z[1]*z[2])
            u=zeros(24)
            for i=1:4
                g=ForwardDiff.gradient(w,xy[i,:])
                u[6i-3]=w(xy[i,:]);u[6i-2]=-g[2];u[6i-1]=g[1]
            end
            expected=zeros(4,3)
            for (j,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
                H=ForwardDiff.hessian(w,[a*r,b*s])
                expected[j,:]=B*[H[1,1],H[2,2],2H[1,2]]
            end
            N,average,weights=F.quad4_differential_membrane_force_field(xy,u,A,B)
            @test isapprox(N,expected;rtol=2e-13,atol=1e-14)
            @test isapprox(average,vec(expected'*weights/sum(weights));atol=1e-14)
            deriv=ForwardDiff.derivative(t->sum(abs2,F.quad4_differential_membrane_force_field(xy,u,A,t*B)[1]),1.)
            @test isapprox(deriv,2sum(abs2,expected);rtol=3e-13)
            for height in (-.02,.02)
                xyz=hcat(xy,[height,-height,height,-height])
                W=F.quad4_finite_warp_displacement_map(xy,xyz)
                physical=W\u
                projected=F.quad4_differential_membrane_force_field(xy,physical,A,B;coords_3d=xyz)[1]
                @test isapprox(projected,expected;rtol=3e-13,atol=1e-14)
            end
        end
    end
end

function patch(path,Q;cyclic=0)
    xyz=reduce(vcat,([x y .03x*y] for y in (-1.,0.,1.) for x in (-1.,0.,1.)))*Q'
    axes=Q*[cos(.37) -sin(.37) 0.;sin(.37) cos(.37) 0.;0. 0. 1.]
    open(path,"w") do io
        println(io,"SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,20.\nPARAM,K6ROT,1.")
        println(io,"CORD2R,501,,0.,0.,0.,",join(axes[:,3],','),"\n+,",join(axes[:,1],','))
        for i=1:9;println(io,"GRID,$i,,",join(xyz[i,:],','));end
        for (eid,order) in enumerate(([1,2,5,4],[2,3,6,5],[4,5,8,7],[5,6,9,8]))
            println(io,"CQUAD4,$eid,10,",join(circshift(order,-cyclic),','),",501")
        end
        println(io,"MAT8,1,140000.,9000.,.27,4500.,3800.,2600.,1.")
        println(io,"PCOMP,10\n+,1,.012,0.,YES,1,.008,65.,YES\nENDDATA")
    end
    model=OpenJFEM.bdf_to_model(path)
    _,ids,X,ndof,R,_,mapping,normals,_=S.assemble_stiffness(model;sol105_context=true)
    (model,ids,X,ndof,R,mapping,normals)
end
function geometric(data,u)
    model,ids,X,ndof,R,mapping,normals=data
    flags=Tuple{Bool,Bool}[]
    G=Matrix(S.assemble_geometric_stiffness(model,ids,X,R,ndof,u,normals,mapping;
        geometric_capture=(eid,d)->push!(flags,(d[:kg_differential_prestress],d[:snorm_pq_kg]!==nothing))))
    G,flags
end
@testset "Coupled normal-moment patch geometric work" begin
    mktempdir() do dir
        eye=Matrix{Float64}(I,3,3)
        Q=[cos(.61) 0. sin(.61);0. 1. 0.;-sin(.61) 0. cos(.61)]
        T=kron(Matrix{Float64}(I,18,18),Q)
        u=sin.(collect(1.:54.))*.0001
        base=patch(joinpath(dir,"base.bdf"),eye);G,flags=geometric(base,u)
        @test length(flags)==4
        @test all(first,flags)
        @test any(last,flags)
        @test isapprox(G,G';rtol=3e-12,atol=1e-12)
        scaled,_=geometric(base,-2u)
        @test isapprox(scaled,-2G;rtol=3e-12,atol=1e-12)
        rotated,_=geometric(patch(joinpath(dir,"rotated.bdf"),Q),T*u)
        @test isapprox(rotated,T*G*T';rtol=5e-10,atol=1e-10)
        cyclic,_=geometric(patch(joinpath(dir,"cyclic.bdf"),eye;cyclic=1),u)
        @test isapprox(cyclic,G;rtol=5e-10,atol=1e-10)
    end
end

@testset "Eccentric isotropic laminate sensitivity scope" begin
    prop=Dict{String,Any}("TYPE"=>"PCOMP_CLT","IS_ISOTROPIC"=>true,"Bmb"=>ones(3,3))
    model=Dict{String,Any}("CSHELLs"=>Dict("1"=>Dict("NODES"=>[1,2,3,4],"PID"=>1)),"PSHELLs"=>Dict("1"=>prop))
    @test S._buckling_local_rhs_has_operator_gap(model)
    prop["Bmb"]=nothing
    @test !S._buckling_local_rhs_has_operator_gap(model)
end
end
