using Test, LinearAlgebra, SparseArrays

module LocalAUTOSPCTestHarness
using LinearAlgebra, SparseArrays
using OpenJFEM.Solver: @solver_stage, _measure_solver_stage, _timed_factorization
log_msg(message) = nothing
solver_env_bool(key, default) = haskey(ENV, key) ?
    lowercase(strip(ENV[key])) in ("1", "true", "yes", "on") : default
function solver_env_float(key, default)
    value = tryparse(Float64, get(ENV, key, ""))
    return value === nothing ? default : value
end
include(joinpath(@__DIR__, "..", "..", "src", "solver", "boundary_conditions.jl"))
end
const LOCAL_AUTOSPC = LocalAUTOSPCTestHarness

function local_autospc_stages(K; fixed=Set{Int}(), model=Dict{String,Any}("SOL" => 101))
    ndof = size(K, 1)
    ids = Dict(100 + i => i for i in 1:div(ndof, 6))
    diagonal = LOCAL_AUTOSPC._diagonal_autospc!(fixed, nothing, K, ndof, model, ids)
    directional = LOCAL_AUTOSPC.gpst_enabled() ?
        LOCAL_AUTOSPC._grid_point_singularity_autospc!(fixed, nothing, K, ndof, model, ids) : nothing
    return fixed, diagonal, directional
end

const LOCAL_AUTOSPC_ENV = (
    "JFEM_AUTOSPC_TRANS_REL", "JFEM_AUTOSPC_ROT_REL", "JFEM_AUTOSPC_GPST_REL",
    "JFEM_AUTOSPC_GRID_POINT_SINGULARITY", "JFEM_AUTOSPC_GRID_POINT_SINGULARITY_TRANS",
    "JFEM_AUTOSPC_NEGATIVE_DIAGONAL", "JFEM_AUTOSPC_AUDIT_CSV",
)

withenv((key => nothing for key in LOCAL_AUTOSPC_ENV)...) do
    @testset "AUTOSPC is independent of remote stiffness and unit scale" begin
        # A change of dependent coordinates can amplify one region of T'KT by
        # orders of magnitude. It cannot turn an unrelated valid grid into SPCs.
        for remote in (1., 1e15), units in (1e-20, 1., 1e20)
            K = units * Diagonal(vcat([1., 2., 3., 2., 3., 4.], fill(remote, 6)))
            fixed, diagonal, directional = local_autospc_stages(K)
            @test isempty(fixed)
            @test diagonal["dofs"] == 0
            @test directional["dofs"] == 0
            @test !diagonal["global_stiffness_cutoff"]
        end
        # Explicit UM-style dependent-coordinate reparameterisation followed by
        # exact congruence preserves the response of an uncoupled flexible grid.
        K = Matrix{Float64}(I, 18, 18)
        T = Matrix{Float64}(I, 18, 18)[:, 1:12]
        T[13:18, 7:12] .= 1e7 .* Matrix{Float64}(I, 6, 6)
        reduced = T' * K * T
        fixed, _, _ = local_autospc_stages(reduced)
        force = vcat(ones(6), zeros(6))
        @test isempty(fixed)
        @test (reduced \ force)[1:6] == ones(6)
    end

    @testset "Local principal singularities are still constrained" begin
        normal = normalize([1., 2., 3.])
        for units in (1e-20, 1., 1e20)
            K = Matrix{Float64}(I, 12, 12)
            K[1:3, 1:3] .= I(3) - normal * normal'
            K[7:12, 7:12] .*= 1e15
            fixed, diagonal, directional = local_autospc_stages(units .* K)
            @test fixed == Set([3])
            @test diagonal["dofs"] == 0
            @test directional["translational_dofs"] == 1
            @test directional["rotational_dofs"] == 0
        end
        fixed, diagonal, directional = local_autospc_stages(Diagonal([1., 1e-12, 1., 1., 1., 1.]))
        @test fixed == Set([2])
        @test diagonal["dofs"] == 0
        @test directional["dofs"] == 1
        # Deck and explicit GPST thresholds retain their precedence.
        K = Diagonal([1., 1e-7, 1., 1., 1., 1.])
        model = Dict{String,Any}("SOL" => 101, "PARAM_EPZERO" => 1e-6)
        @test first(local_autospc_stages(K; model)) == Set([2])
        withenv("JFEM_AUTOSPC_GPST_REL" => "1e-9") do
            @test isempty(first(local_autospc_stages(K; model)))
        end
    end

    @testset "Exact zeros and existing negative-diagonal policy are reported" begin
        K = Diagonal([0., 2., -3., 1., 1., 1.])
        fixed, diagonal, _ = local_autospc_stages(K)
        @test fixed == Set([1, 3])
        @test diagonal["zero_diagonal_dofs"] == 1
        @test diagonal["negative_diagonal_dofs"] == 1
        @test diagonal["local_relative_dofs"] == 0
        withenv("JFEM_AUTOSPC_NEGATIVE_DIAGONAL" => "false") do
            fixed, diagonal, _ = local_autospc_stages(K)
            @test fixed == Set([1])
            @test diagonal["negative_diagonal_dofs"] == 0
        end
    end

    @testset "Explicitly disabled GPST uses local diagonal fallback" begin
        withenv("JFEM_AUTOSPC_GRID_POINT_SINGULARITY" => "false") do
            K = Diagonal(vcat([1., 1e-10, 1., 1., 1e-10, 1.], fill(1e15, 6)))
            fixed, diagonal, directional = local_autospc_stages(K)
            @test fixed == Set([2, 5])
            @test diagonal["local_relative_dofs"] == 2
            @test directional === nothing
            withenv("JFEM_AUTOSPC_TRANS_REL" => "1e-12", "JFEM_AUTOSPC_ROT_REL" => "1e-12") do
                @test isempty(first(local_autospc_stages(K)))
            end
            # A prescribed coordinate is not a reference stiffness for the
            # remaining unconstrained components of its grid.
            K = Diagonal([1e15, 1., 1., 1., 1., 1.])
            @test first(local_autospc_stages(K; fixed=Set([1]))) == Set([1])
        end
        withenv("JFEM_AUTOSPC_GRID_POINT_SINGULARITY_TRANS" => "false") do
            K = Diagonal([1., 1e-10, 1., 1., 1e-10, 1.])
            fixed, diagonal, directional = local_autospc_stages(K)
            @test fixed == Set([2, 5])
            @test diagonal["translational_dofs"] == 1
            @test diagonal["rotational_dofs"] == 0
            @test directional["rotational_dofs"] == 1
        end
    end
end
