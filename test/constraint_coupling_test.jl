using Test, LinearAlgebra, SparseArrays

# Exercise the production graph and elimination code without importing the
# complete element/solver stack when this targeted test is run on its own.
module CoupledConstraintTestHarness
using LinearAlgebra, SparseArrays
log_msg(message) = nothing
include(joinpath(@__DIR__, "..", "src", "solver", "constraints.jl"))
end
const COUPLED_SOLVER = CoupledConstraintTestHarness

function coupling_matrices(graph, ndof)
    dependent = sort!(collect(keys(graph)))
    retained = setdiff(1:ndof, dependent)
    flat, diagnostics = COUPLED_SOLVER._flatten_constraint_dependency_map(graph)
    C = zeros(length(dependent), ndof)
    for (i, dof) in enumerate(dependent)
        C[i, dof] = 1
        for (next, coefficient) in graph[dof]
            C[i, next] -= coefficient
        end
    end
    T = Matrix{Float64}(I, ndof, ndof)[:, retained]
    columns = Dict(dof => j for (j, dof) in enumerate(retained))
    for dof in dependent, (next, coefficient) in flat[dof]
        T[dof, columns[next]] += coefficient
    end
    return flat, diagnostics, C, T, retained
end

@testset "Invertible coupled constraints retain all original equations" begin
    graph = Dict(1 => [(2, .25), (3, 1.)], 2 => [(1, .5), (4, 2.)])
    flat, diagnostics, C, T, retained = coupling_matrices(graph, 4)
    expected = [1. -.25; -.5 1.] \ [1. 0; 0 2.]
    @test T[1:2, :] ≈ expected
    @test norm(C * T, Inf) < 1e-14
    @test Set(keys(flat)) == Set(keys(graph))
    @test all(next ∉ keys(graph) for pairs in values(flat) for (next, _) in pairs)
    @test diagnostics["resolved_cyclic_blocks"] == 1
    @test diagnostics["resolved_cyclic_dofs"] == 2
    @test diagnostics["largest_cyclic_block"] == 2
    # Verify actual production matrix redistribution, virtual work and the
    # full saddle-point equilibrium solution, not merely graph coefficients.
    K = Diagonal([2., 3., 4., 5.])
    f = [1., -3., 2., .7]
    redistributed = COUPLED_SOLVER._apply_constraint_congruence(K, graph)
    @test Matrix(redistributed[retained, retained]) ≈ T' * K * T
    q = (T' * K * T) \ (T' * f)
    u = T * q
    exact = [Matrix(K) C'; C zeros(2, 2)] \ vcat(f, zeros(2))
    @test u ≈ exact[1:4]
    @test dot(q, T' * f) ≈ dot(u, f)
    @test dot(q, T' * K * T * q) ≈ dot(u, K * u)
    reversed_graph = Dict(pair for pair in reverse(collect(graph)))
    @test first(COUPLED_SOLVER._flatten_constraint_dependency_map(reversed_graph)) == flat
end

@testset "Multiple coupled blocks and nested references" begin
    graph = Dict(1 => [(2, .25), (3, 1.)], 2 => [(1, .5), (4, 2.)],
                 3 => [(4, .2), (5, .3)], 4 => [(3, .4), (6, 2.)],
                 5 => [(7, 3.)])
    flat, diagnostics, C, T, _ = coupling_matrices(graph, 7)
    @test norm(C * T, Inf) < 1e-13
    @test diagnostics["resolved_cyclic_blocks"] == 2
    @test diagnostics["resolved_cyclic_dofs"] == 4
    @test diagnostics["largest_cyclic_block"] == 2
    @test all(next in [6, 7] for pairs in values(flat) for (next, _) in pairs)
end

@testset "Self coupling, homogeneous blocks and ordinary row preservation" begin
    graph = Dict(1 => [(1, .2), (2, 2.)],
                 3 => [(4, .5)], 4 => [(3, .5)],
                 5 => [(7, 3.), (6, 0.), (7, -1.), (8, 1e-18)])
    flat, diagnostics, C, T, _ = coupling_matrices(graph, 8)
    @test flat[1] == [(2, 2.5)]
    @test haskey(flat, 3) && isempty(flat[3])
    @test haskey(flat, 4) && isempty(flat[4])
    @test flat[5] == graph[5]
    @test norm(C * T, Inf) < 1e-14
    @test diagnostics["resolved_cyclic_blocks"] == 2
    ordinary = Dict(1 => [(2, 3.), (3, 0.), (2, -1.), (4, 1e-18)])
    unchanged, info = COUPLED_SOLVER._flatten_constraint_dependency_map(ordinary)
    @test unchanged == ordinary
    @test info["resolved_cyclic_blocks"] == 0
    @test info["changed_dependent_dofs"] == 0
end

@testset "Singular cycles fail explicitly" begin
    graph = Dict(1 => [(2, 1.)], 2 => [(3, 1.)], 3 => [(1, 1.)])
    error = try
        COUPLED_SOLVER._flatten_constraint_dependency_map(graph)
        nothing
    catch err
        err
    end
    @test error isa ArgumentError
    @test occursin("MPC/RBE dependency cycle detected: 1 -> 2 -> 3 -> 1",
                   sprint(showerror, error))
    @test occursin("singular", sprint(showerror, error))
    @test_throws ArgumentError COUPLED_SOLVER._flatten_constraint_dependency_map(
        Dict(1 => [(1, 1.), (2, 3.)]))
end

@testset "Bounded sparse congruence preserves assembled operators" begin
    graph = Dict(1 => [(2, .25), (3, 1.)], 2 => [(1, .5), (4, 2.)],
                 5 => [(6, .5)], 6 => [(5, .5)])
    _, _, _, T, retained = coupling_matrices(graph, 8)
    A = reshape(sin.(collect(1.:64.)), 8, 8)
    for matrix in (A' * A + Diagonal(collect(1.:8.)), A)
        ii, jj, vv = findnz(sparse(matrix))
        # Repeated element contributions, exact zeros and cancelling entries
        # must give the same physical operator after aggregation and T' K T.
        ii = vcat(ii, ii, [1, 1, 8]); jj = vcat(jj, jj, [1, 1, 8])
        vv = vcat(vv ./ 2, vv ./ 2, [4., -4., 0.])
        ii0, jj0, vv0 = copy(ii), copy(jj), copy(vv)
        _, ri, rj, rv = COUPLED_SOLVER._redistribute_constraint_triplets(graph, ii, jj, vv)
        reference = sparse(ri, rj, rv, 8, 8)
        for skip_zeros in (false, true)
            flat, ci, cj, cv = COUPLED_SOLVER._redistribute_constraint_triplets(
                graph, ii, jj, vv; skip_zeros, triplet_budget=1)
            actual = sparse(ci, cj, cv, 8, 8)
            @test Matrix(actual) ≈ Matrix(reference)
            @test Matrix(actual[retained, retained]) ≈ T' * matrix * T
            @test nnz(actual) <= length(rv)
            @test flat == first(COUPLED_SOLVER._flatten_constraint_dependency_map(graph))
        end
        @test ii == ii0 && jj == jj0 && vv == vv0
    end
    # A retained target may have no element entry of its own.
    graph = Dict(1 => [(15, 2.)])
    _, ii, jj, vv = COUPLED_SOLVER._redistribute_constraint_triplets(
        graph, [1, 1], [1, 1], [2., 3.]; triplet_budget=1)
    @test sparse(ii, jj, vv, 15, 15)[15, 15] == 20.
end
