using Test, LinearAlgebra, SparseArrays

# Exercise the production solve helpers without loading a complete model or
# relying on private decks, exported matrices, or a reference executable.
module LUEquilibriumQualityHarness
using LinearAlgebra, SparseArrays
using OpenJFEM.Solver: @solver_stage, _measure_solver_stage, _timed_factorization
log_msg(message) = nothing
solver_env_bool(key, default) = haskey(ENV, key) ?
    lowercase(strip(ENV[key])) in ("1", "true", "yes", "on") : default
function solver_env_float(key, default)
    value = tryparse(Float64, get(ENV, key, ""))
    return value === nothing ? default : value
end
function solver_env_int(key, default)
    value = tryparse(Int, get(ENV, key, ""))
    return value === nothing ? default : value
end
include(joinpath(@__DIR__, "..", "src", "solver", "boundary_conditions.jl"))
end
const LU_QUALITY = LUEquilibriumQualityHarness
lu_quality_diagnostics() = Dict{String,Any}("linear_solver" => Dict{String,Any}())

const LU_QUALITY_ENV = (
    "JFEM_SOL101_AUTO_LSMR_RESIDUAL_REL_MAX",
    "JFEM_SOL101_SINGULAR_SOLVER", "JFEM_SOL101_SINGULAR_LU_REGULARIZATION",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MODE",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_ABS_SHIFT",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_REL_SHIFT",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MIN_EXP",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MAX_EXP",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_EXP_STEP",
)

withenv((key => nothing for key in LU_QUALITY_ENV)...) do
    @testset "Accurate LU is unchanged and refinement uses original equations" begin
        K = sparse([4. -1. 0.; -1. 3. -1.; 0. -1. 2.])
        f = [1., 2., -1.]
        factor = lu(K)
        exact_float = factor \ f
        diagnostics = lu_quality_diagnostics()
        _, u = LU_QUALITY._lu_or_regularized_solve(K, f, 4., diagnostics, "quality_test")
        @test u == exact_float
        record = only(diagnostics["linear_solver"]["equilibrium_candidates"])
        @test record["accepted"]
        @test record["refinement_steps"] == 0
        @test !get(diagnostics["linear_solver"], "used_singular_lu_regularization", false)
        diagnostics = lu_quality_diagnostics()
        accepted, refined = LU_QUALITY._checked_lu_candidate(
            K, f, factor, exact_float .+ [.01, -.02, .03], diagnostics, "perturbed")
        @test accepted
        @test norm(K * refined - f) / norm(f) < 1e-14
        record = only(diagnostics["linear_solver"]["equilibrium_candidates"])
        @test record["initial_relative_residual"] > record["threshold"]
        @test record["refinement_steps"] == 1
        for invalid in (NaN, Inf, -Inf)
            diagnostics = lu_quality_diagnostics()
            accepted, _ = LU_QUALITY._checked_lu_candidate(
                K, f, factor, [invalid, 0., 0.], diagnostics, "nonfinite")
            @test !accepted
            @test !only(diagnostics["linear_solver"]["equilibrium_candidates"])["finite_displacements"]
        end
    end

    @testset "Finite ill-conditioned LU cannot silently report equilibrium" begin
        # The Hilbert matrix is a synthetic Gram matrix, with a load having a
        # substantial component in its almost-null subspace. Factorization can
        # succeed while a finite solution fails the original force equations.
        n = 12
        K = sparse([1. / (i + j - 1) for i in 1:n, j in 1:n])
        f = [isodd(i) ? 1. : -1. for i in 1:n]
        raw = lu(K) \ f
        @test all(isfinite, raw)
        @test norm(K * raw - f) / norm(f) > LU_QUALITY._auto_lsmr_residual_threshold()
        diagnostics = lu_quality_diagnostics()
        @test_throws ArgumentError LU_QUALITY._lu_or_regularized_solve(
            K, f, 1., diagnostics, "hilbert")
        records = diagnostics["linear_solver"]["equilibrium_candidates"]
        @test length(records) > 1
        @test first(records)["candidate"] == "hilbert"
        @test all(r -> !r["accepted"] && r["refinement_steps"] <= 2, records)
    end

    @testset "Compatible and incompatible singular loads are distinguished" begin
        K = sparse([1. -1.; -1. 1.])
        diagnostics = lu_quality_diagnostics()
        f = [1., -1.]
        _, u = LU_QUALITY._lu_or_regularized_solve(K, f, 1., diagnostics, "balanced")
        @test u[1] - u[2] ≈ 1. rtol=1e-10
        @test norm(K * u - f) / norm(f) < 1e-10
        @test diagnostics["linear_solver"]["regularization_shift_exponent"] == -14
        @test last(diagnostics["linear_solver"]["equilibrium_candidates"])["accepted"]
        for scale in (1e-12, 1., 1e12)
            diagnostics = lu_quality_diagnostics()
            @test_throws ArgumentError LU_QUALITY._lu_or_regularized_solve(
                scale * K, scale * [1., 1.], scale, diagnostics, "unbalanced")
            records = diagnostics["linear_solver"]["equilibrium_candidates"]
            @test length(records) == length(LU_QUALITY._singular_lu_regularization_exponents())
            @test all(r -> !r["accepted"] && r["relative_residual"] >= .99, records)
        end
        withenv("JFEM_SOL101_SINGULAR_LU_REGULARIZATION" => "false") do
            @test_throws ArgumentError LU_QUALITY._lu_or_regularized_solve(
                K, f, 1., lu_quality_diagnostics(), "disabled_regularization")
        end
    end

    @testset "A cached factor cannot hide an incompatible subsequent load" begin
        withenv("JFEM_LINEAR_CACHE_MIN_NDOF" => "0") do
            K = sparse([1. -1. 0. 0. 0. 0.; -1. 1. 0. 0. 0. 0.;
                0. 0. 2. 0. 0. 0.; 0. 0. 0. 3. 0. 0.;
                0. 0. 0. 0. 4. 0.; 0. 0. 0. 0. 0. 5.])
            model = Dict{String,Any}("SOL" => 101)
            rigid = Dict{Int,Vector{Tuple{Int,Float64}}}()
            cache = LU_QUALITY.create_linear_solve_cache()
            key = LU_QUALITY._linear_solve_cache_key(K, 6, model, nothing, rigid)
            diagnostics = lu_quality_diagnostics()
            factor, _ = LU_QUALITY._lu_or_regularized_solve(
                K, [1., -1., 0., 0., 0., 0.], 5., diagnostics, "first_load")
            cache[key] = LU_QUALITY.LinearSolveCacheEntry(collect(1:6), Int[], Set{Int}(),
                Set{Int}(), Int[], Float64[], K, nothing, factor, diagnostics)
            ids = Dict(1 => 1)
            node_frames = Dict{Int,Matrix{Float64}}()
            balanced = [2., -2., 1., 0., 0., 0.]
            u, _, _, d = LU_QUALITY.apply_bc_and_solve(K, 6, model, ids,
                balanced, node_frames, rigid, 5., diag(K); linear_cache=cache)
            @test norm(K * u - balanced) / norm(balanced) < 1e-10
            @test d["linear_solver"]["cache_hit"]
            @test only(d["linear_solver"]["equilibrium_candidates"])["accepted"]
            @test_throws ArgumentError LU_QUALITY.apply_bc_and_solve(K, 6, model, ids,
                [1., 1., 0., 0., 0., 0.], node_frames, rigid, 5., diag(K); linear_cache=cache)
        end
    end
end
