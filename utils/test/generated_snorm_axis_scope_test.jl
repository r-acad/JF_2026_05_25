using Test
module GeneratedSnormAxisScopeFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
unit(v)=SVector{3,Float64}(v/norm(v))

function fixture(;quadrilaterals=false)
    normals=[unit([0.,sind(71.),cosd(71.)]),unit([0.,-sind(71.),cosd(71.)])]
    points=[SVector(0.,0.,0.)];shells=Dict{String,Any}()
    for (i,n) in enumerate(normals)
        a=unit(cross(n,SVector(1.,0.,0.)));b=cross(n,a)
        start=length(points)+1
        if quadrilaterals
            append!(points,[a,a+b,b]);nodes=[1,start,start+1,start+2]
        else
            append!(points,[a,b]);nodes=[1,start,start+1]
        end
        shells[string(i)]=Dict("ID"=>i,"TYPE"=>(quadrilaterals ? "CQUAD4" : "CTRIA3"),"NODES"=>nodes)
    end
    model=Dict{String,Any}("CSHELLs"=>shells,"CORDs"=>Dict(),"SNORMs"=>Dict(),"PARAM_SNORM"=>80.)
    return model,Dict(i=>i for i=1:length(points)),reduce(vcat,permutedims.(points))
end

function checks()
    for quad in (false,true)
        m,ids,X=fixture(;quadrilaterals=quad);trace=Dict{Int,Any}(999=>:stale)
        @test S._snorm_axis_generation_supported(m)
        generated=S.compute_snorm_normals(m,ids,X;branch_trace=trace)
        @test Set(keys(trace))==Set(keys(generated))
        @test trace[1].coherent && length(trace[1].partition)==2 && prod(trace[1].partition)==-1
        @test all(x->x isa NamedTuple,values(trace))
        reordered=deepcopy(m);reordered["CSHELLs"]=Dict(reverse(collect(m["CSHELLs"])))
        second=Dict{Int,Any}();S.compute_snorm_normals(reordered,ids,X;branch_trace=second)
        @test second==trace
        Q=[0. -1. 0.;1. 0. 0.;0. 0. 1.]
        S.compute_snorm_normals(m,ids,X*Q';branch_trace=second)
        @test second==trace
        directed=S.compute_shell_nodal_normals(m,ids,X,80.;corner_tangents=true)
        options=["JFEM_SNORM_DIRECTOR"=>"1","JFEM_Q4_SNORM_TRANSFORM_ONLY"=>"1"]
        append!(options,quad ? ["JFEM_Q4_SNORM_CURVATURE"=>"0","JFEM_Q4_SNORM_COMPLETION_MODE"=>"field"] : ["JFEM_TRIA3_SNORM_NORMAL_MOMENT"=>"0"])
        for option in options
            withenv(option) do
                @test !S._snorm_axis_generation_supported(m)
                actual=S.compute_snorm_normals(m,ids,X;branch_trace=second)
                @test actual==directed
                @test isempty(second)
            end
        end
        explicit=unit([.1,.15,1.]);m["SNORMs"]["1"]=Dict("GID"=>1,"CID"=>0,"N"=>collect(explicit))
        actual=S.compute_snorm_normals(m,ids,X;branch_trace=second)
        @test actual[1]≈explicit && !haskey(second,1)
        m["PARAM_SNORM"]=0.;S.compute_snorm_normals(m,ids,X;branch_trace=second)
        @test isempty(second)
        m["PARAM_SNORM"]=-1.;@test isempty(S.compute_snorm_normals(m,ids,X;branch_trace=second)) && isempty(second)
    end
    mixed,ids,X=fixture(;quadrilaterals=true)
    mixed["CSHELLs"]["3"]=Dict("TYPE"=>"CTRIA3","NODES"=>[1,2,3])
    directed=S.compute_shell_nodal_normals(mixed,ids,X,80.;corner_tangents=true)
    withenv("JFEM_TRIA3_SNORM_NORMAL_MOMENT"=>"0") do
        @test !S._snorm_axis_generation_supported(mixed)
        @test S.compute_snorm_normals(mixed,ids,X)==directed
    end
    higher=deepcopy(mixed);higher["CSHELLs"]["4"]=Dict("TYPE"=>"CQUAD8","NODES"=>collect(1:8))
    @test !S._snorm_axis_generation_supported(higher)
    # Canonical partition signatures do not depend on seed, incident order,
    # common normal reversal, or a proper rotation away from transitions.
    n=[unit([0.,.9,.4]),unit([0.,-.9,.4]),unit([.1,.85,.4])]
    incident_keys=[("8",1),("2",1),("11",3)]
    signature=S._snorm_axis_branch_signature(n,incident_keys,S._snorm_coherent_axis_normals(n))
    for order in ([1,2,3],[3,1,2],[2,3,1]),sgn in (-1.,1.)
        v=sgn.*n[order]
        @test S._snorm_axis_branch_signature(v,incident_keys[order],S._snorm_coherent_axis_normals(v))==signature
    end
end
end
@testset "Generated SNORM axes preserve legacy consumers and discrete traces" begin
    GeneratedSnormAxisScopeFixture.checks()
end
