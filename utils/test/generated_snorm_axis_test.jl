using Test, LinearAlgebra, StaticArrays, OpenJFEM
module GeneratedSnormAxisFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
unit(v)=SVector{3,Float64}(v/norm(v))
projector(v)=v*v'

function star(normals;angle=80.,reverse_elements=false)
    xyz=zeros(1+2length(normals),3);shells=Dict{String,Any}()
    for (i,n) in enumerate(normals)
        a=unit(cross(n,abs(n[1])<.8 ? [1.,0.,0.] : [0.,1.,0.]));b=cross(n,a)
        xyz[2i,:]=a;xyz[2i+1,:]=b
        nodes=reverse_elements ? [1,2i+1,2i] : [1,2i,2i+1]
        shells[string(i)]=Dict("ID"=>i,"TYPE"=>"CTRIA3","NODES"=>nodes)
    end
    model=Dict{String,Any}("CSHELLs"=>shells,"CORDs"=>Dict(),"SNORMs"=>Dict(),"PARAM_SNORM"=>angle)
    return model,Dict(i=>i for i=1:size(xyz,1)),xyz
end

function checks()
    # Normal reversal, incident permutation and coordinate covariance are
    # independent of constitutive coefficients or native case parameters.
    orders=((1,2,3),(1,3,2),(2,1,3),(2,3,1),(3,1,2),(3,2,1))
    rotations=(Matrix{Float64}(I,3,3),[0. -1. 0.;1. 0. 0.;0. 0. 1.],
        Matrix(qr([1. 2. -1.;2. -1. 3.;1. .5 2.]).Q))
    for degrees in (13.,37.,67.,81.)
        n1=unit([0.,sind(degrees),cosd(degrees)]);n2=unit([0.,-sind(degrees),cosd(degrees)])
        normals=[n1,n2,n1];expected=unit(sum(S._snorm_coherent_axis_normals(normals)))
        for Q in rotations, order in orders, bits in 0:7
            transformed=[(iszero(bits & (1<<(i-1))) ? 1. : -1.)*unit(Q*normals[order[i]]) for i=1:3]
            aligned=S._snorm_coherent_axis_normals(transformed);actual=unit(sum(aligned))
            @test projector(actual)≈Q*projector(expected)*Q' atol=3e-15 rtol=3e-15
        end
    end
    # No unproved axis selection on an unbalanced or exactly orthogonal star.
    unbalanced=[unit([1.,0.,0.]),unit([-.5,sqrt(3.)/2,0.]),unit([-.5,-sqrt(3.)/2,0.])]
    orthogonal=[unit([1.,0.,0.]),unit([0.,1.,0.])]
    @test S._snorm_coherent_axis_normals(unbalanced)===unbalanced
    @test S._snorm_coherent_axis_normals(orthogonal)===orthogonal
    acute=[unit([0.,.2,1.]),unit([.1,-.2,1.]),unit([-.1,.1,1.])]
    @test S._snorm_coherent_axis_normals(acute)==acute
    for degrees in (31.,71.)
        normals=[unit([0.,sind(degrees),cosd(degrees)]),unit([0.,-sind(degrees),cosd(degrees)])]
        m,ids,X=star(normals);expected=degrees<45 ? [0.,0.,1.] : [0.,1.,0.]
        directed=S.compute_shell_nodal_normals(m,ids,X,180.)
        geometric=S.compute_geometric_nodal_normals(m,ids,X)
        generated=S.compute_snorm_normals(m,ids,X)
        @test directed==geometric
        @test projector(directed[1])≈Diagonal([0.,0.,1.]) atol=2e-15
        @test projector(generated[1])≈expected*expected' atol=2e-15
        rev,rids,RX=star(normals;reverse_elements=true)
        @test projector(S.compute_snorm_normals(rev,rids,RX)[1])≈projector(generated[1]) atol=2e-15
        meanangle=min(degrees,90-degrees)
        m["PARAM_SNORM"]=meanangle-1
        @test !haskey(S.compute_snorm_normals(m,ids,X),1)
        m["PARAM_SNORM"]=meanangle+1
        @test haskey(S.compute_snorm_normals(m,ids,X),1)
        # Explicit prescribed normals retain their directed value and precedence.
        explicit=unit([.15,.2,1.]);m["SNORMs"]["1"]=Dict("GID"=>1,"CID"=>0,"N"=>collect(explicit))
        @test S.compute_snorm_normals(m,ids,X)[1]≈explicit atol=2e-15
        m["PARAM_SNORM"]=0.
        only_explicit=S.compute_snorm_normals(m,ids,X)
        @test Set(keys(only_explicit))==Set([1]) && only_explicit[1]≈explicit
        m["PARAM_SNORM"]=-1.
        @test isempty(S.compute_snorm_normals(m,ids,X))
    end
    # Exactly coplanar repeated normals lie on the strict zero-degree boundary.
    m,ids,X=star([unit([0.,0.,1.]),unit([0.,0.,1.])])
    @test !haskey(S.compute_shell_nodal_normals(m,ids,X,0.;normal_axes=true),1)
    @test haskey(S.compute_shell_nodal_normals(m,ids,X,0.),1)
end
end
@testset "Generated SNORM coherent axes preserve geometric and explicit contracts" begin
    GeneratedSnormAxisFixture.checks()
end
