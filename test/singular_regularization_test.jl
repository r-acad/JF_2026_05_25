using Test, LinearAlgebra, SparseArrays

module SingularRegularizationTestHarness
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
const SINGULAR_REGULARIZATION = SingularRegularizationTestHarness
regularization_diagnostics() = Dict{String,Any}("linear_solver" => Dict{String,Any}())
function regularization_matrix(K; exponent=-10, maximum_element_stiffness=0.)
    diagnostics = regularization_diagnostics()
    D = SINGULAR_REGULARIZATION._singular_lu_regularization_matrix(
        sparse(K), Float64(maximum_element_stiffness), exponent, diagnostics)
    return D, diagnostics["linear_solver"]
end

const SINGULAR_REGULARIZATION_ENV = (
    "JFEM_SOL101_SINGULAR_SOLVER", "JFEM_SOL101_SINGULAR_LU_REGULARIZATION",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MODE",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_ABS_SHIFT",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_REL_SHIFT",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MIN_EXP",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MAX_EXP",
    "JFEM_SOL101_SINGULAR_LU_REGULARIZATION_EXP_STEP",
)

withenv((key => nothing for key in SINGULAR_REGULARIZATION_ENV)...) do
    @testset "Singular fallback is local and covariant under coordinate scaling" begin
        K = sparse([2. -2. 0.; -2. 2. 0.; 0. 0. 7.])
        D, diagnostics = regularization_matrix(K; maximum_element_stiffness=1e30)
        @test diag(D) ≈ [2e-10, 2e-10, 7e-10] rtol=1e-14
        @test diagnostics["regularization_mode"] == "diagonal"
        @test diagnostics["regularization_shift_source"] == "exponent_diagonal"
        @test isposdef(Symmetric(K+D))
        for units in (1e-20, 1., 1e20)
            scaled_D, _ = regularization_matrix(units*K)
            @test Matrix(scaled_D) ≈ units*Matrix(D) rtol=1e-14
        end
        for scaling in ([1.,1.,1e7], [1e-6,1e3,1e8], [1e3,1e-4,1e-9])
            T = Diagonal(scaling)
            transformed_D, _ = regularization_matrix(T*K*T)
            @test Matrix(transformed_D) ≈ T*D*T rtol=1e-14
            # The entire regularized operator, including the selected spring
            # metric in its nullspace, represents the same physical equations.
            @test Matrix(T*K*T+transformed_D) ≈ T*(K+D)*T rtol=1e-14
        end
    end

    @testset "Actual singular solve reports perturbation and preserves response" begin
        # One compatible mechanism and a flexible independent coordinate.
        # A very stiff remote coordinate must not stiffen that flexible one.
        withenv("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MIN_EXP" => "-10") do
            for remote in (1.,1e15), units in (1e-20,1.,1e20)
                K = units*sparse([1. -1. 0. 0.; -1. 1. 0. 0.;
                                  0. 0. 2. 0.; 0. 0. 0. remote])
                force = units*[1.,-1.,4.,0.]
                diagnostics = regularization_diagnostics()
                _, displacement = SINGULAR_REGULARIZATION._lu_or_regularized_solve(
                    K, force, maximum(abs,diag(K)), diagnostics, "test_lu")
                @test displacement[1]-displacement[2] ≈ 1. rtol=1e-8
                @test displacement[3] ≈ 2. rtol=1e-8
                @test norm(K*displacement-force)/norm(force) < 1e-8
                @test diagnostics["linear_solver"]["used_singular_lu_regularization"]
                @test diagnostics["linear_solver"]["regularization_mode"] == "diagonal"
            end
        end
    end

    @testset "Zero and negative diagonals receive no artificial unit floor" begin
        D, diagnostics = regularization_matrix(Diagonal([0.,-2.,1e-30]))
        @test diag(D) ≈ [0.,2e-10,1e-40] rtol=1e-14
        @test all(diag(D) .>= 0.)
        @test D[1,1] == 0.
        @test diagnostics["regularization_shift_min"] == 0.
    end

    @testset "Explicit global and prescribed shifts retain compatibility" begin
        K = sparse(Diagonal([2.,7.]))
        withenv("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MODE" => "global") do
            D, diagnostics = regularization_matrix(K; maximum_element_stiffness=11.)
            @test diag(D) ≈ fill(11e-10,2) rtol=1e-14
            @test diagnostics["regularization_shift_source"] == "exponent_global"
        end
        withenv("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_REL_SHIFT" => "0.01") do
            D, diagnostics = regularization_matrix(K; maximum_element_stiffness=11.)
            @test diag(D) == fill(.11,2)
            @test diagnostics["regularization_shift_source"] == "explicit_relative"
            withenv("JFEM_SOL101_SINGULAR_LU_REGULARIZATION_ABS_SHIFT" => "0.125") do
                D, diagnostics = regularization_matrix(K)
                @test diag(D) == fill(.125,2)
                @test diagnostics["regularization_shift_source"] == "explicit_absolute"
            end
        end
    end
end
