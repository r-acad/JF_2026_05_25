using Test, OpenJFEM, LinearAlgebra, SparseArrays

module AssemblyComputeBarrierFixture
using Test, OpenJFEM, LinearAlgebra, SparseArrays
const S = OpenJFEM.Solver

function congruence(map, rows, cols, vals, n)
    T = Matrix{Float64}(I, n, n)
    for (dependent, terms) in map
        T[dependent,:] .= 0
        for (independent, weight) in terms
            T[dependent,independent] += weight
        end
    end
    T' * Matrix(sparse(rows,cols,vals,n,n)) * T
end

@testset "Constraint entry support and exact congruence" begin
    # Dependencies outside matrix support must still be flattened for load
    # transfer, while preserving triplet order, duplicates and explicit zeros.
    map = Dict(7=>[(8,2.)], 8=>[(1,.25),(2,.75)])
    rows = [1,1,2,3]; cols = [2,2,1,3]; vals = [2.,-1.,3.,0.]
    flat, ri, ci, vi = S._redistribute_constraint_triplets(map,rows,cols,vals)
    @test flat[7] == [(1,.5),(2,1.5)]
    @test ri === rows && ci === cols && vi === vals
    @test sparse(ri,ci,vi,8,8) ≈ congruence(flat,rows,cols,vals,8)
    @test_throws ArgumentError S._redistribute_constraint_triplets(map,rows,cols,vals;triplet_budget=0)

    # A single-terminal constraint is not an identity mapping. Exercise row,
    # column, and two-sided dependency terms, repeated targets and empty rows.
    for active_map in (Dict(4=>[(2,1.)]),
                       Dict(4=>[(1,.25),(2,.75)],5=>[(2,-1.),(2,.5)]),
                       Dict(4=>Tuple{Int,Float64}[]))
        rr=[1,4,2,4,5,3]; cc=[4,1,4,4,4,3]; vv=[2.,3.,-1.,4.,7.,0.]
        for skip in (false,true), budget in (100_000_000,1)
            flattened,i,j,v = S._redistribute_constraint_triplets(
                active_map,rr,cc,vv;skip_zeros=skip,triplet_budget=budget)
            @test sparse(i,j,v,5,5) ≈ congruence(flattened,rr,cc,vv,5)
            skip && @test all(!iszero,v)
        end
    end
    _,ri,ci,vi = S._redistribute_constraint_triplets(map,rows,cols,vals;skip_zeros=true)
    @test all(!iszero,vi)
    @test sparse(ri,ci,vi,8,8) ≈ congruence(flat,rows,cols,vals,8)
    @test S._redistribute_constraint_triplets(map,Int[],Int[],Float64[])[2:4] == (Int[],Int[],Float64[])
end

@testset "Disjoint operator retains dependent load transfer" begin
    # Auxiliary load centers have no element stiffness of their own, but their
    # applied forces must still transfer through the flattened constraint map.
    graph = Dict(7=>[(8,2.)], 8=>[(1,.25),(2,.75)])
    rows = [1,1,2,2,3]; cols = [1,2,1,2,3]; vals = [2.,1.,1.,3.,4.]
    flat, ri, ci, vi = S._redistribute_constraint_triplets(graph,rows,cols,vals)
    @test ri === rows && ci === cols && vi === vals
    transform = Matrix{Float64}(I,12,12)
    for (dependent, terms) in flat
        transform[dependent,:] .= 0
        for (independent, coefficient) in terms
            transform[dependent,independent] += coefficient
        end
    end
    K = Matrix(sparse(rows,cols,vals,12,12))
    @test transform' * K * transform == K
    force_card(gid, direction, magnitude) = Dict{String,Any}(
        "SID"=>1, "GID"=>gid, "CID"=>0, "Dir"=>direction, "Mag"=>magnitude)
    model = Dict{String,Any}(
        "FORCEs"=>[force_card(10,[1.,0.,0.],2.),
                   force_card(20,[1.,0.,0.],8.),
                   force_card(20,[0.,1.,0.],-4.)],
        "MOMENTs"=>Any[], "PLOAD4s"=>Any[], "LOAD_COMBOS"=>Any[])
    rotations = [Matrix{Float64}(I,3,3) for _ in 1:2]
    args = (12,model,Dict(10=>1,20=>2),zeros(2,3),1,rotations,flat)
    force = zeros(12); force[1]=2.; force[7]=8.; force[8]=-4.
    actual = S._assemble_applied_force(args...;log_rbe3=false)
    @test actual == transform' * force
    @test actual[1:2] == [5.,9.]
    @test actual[7:8] == [0.,0.]
    @test !haskey(model,"_disable_thermal_in_resolve_loads")
    @test S._assemble_applied_force(args...;load_scale=2.,log_rbe3=false) == 2actual
    q = collect(1.:12.)
    @test dot(actual,q) == dot(force,transform*q)
    model["_disable_thermal_in_resolve_loads"] = false
    S._assemble_applied_force(args...;log_rbe3=false)
    @test model["_disable_thermal_in_resolve_loads"] === false
end

@testset "Shell geometric transform preserves full congruence" begin
    # Full matrices deliberately include translation/rotation coupling, so a
    # block-diagonal-only optimization cannot pass this test.
    A=[sin(3i+7j) for i in 1:24,j in 1:24]
    K=A+A'
    for T in (Matrix{Float64}(I,24,24),zeros(24,24),
              [i==j ? 1. : (mod(i+j,4)==0 ? .1*cos(2i+j) : 0.) for i in 1:24,j in 1:24])
        C=fill(NaN,24,24); scratch=fill(NaN,24,24)
        result=S._transform_shell_geometric_stiffness!(C,scratch,K,T)
        @test result === C
        @test C ≈ T'*K*T atol=3e-14 rtol=3e-14
        @test C ≈ C' atol=3e-14 rtol=3e-14
        # The existing triplet arithmetic is preserved on repeat calls and
        # both caller-owned buffers are reset instead of accumulating history.
        saved=copy(C)
        S._transform_shell_geometric_stiffness!(C,scratch,K,T)
        @test C == saved
    end
end
end
