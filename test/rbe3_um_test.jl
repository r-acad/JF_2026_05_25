using Test, OpenJFEM, LinearAlgebra, SparseArrays

const UM_SOLVER = OpenJFEM.Solver

function um_constraint_map(card; coords=[0. 0 0; 1 0 0; 2 0 0], frames=nothing)
    n = size(coords, 1)
    id_map = Dict(i => i for i in 1:n)
    frames === nothing && (frames = Dict(i => Matrix{Float64}(I, 3, 3) for i in 1:n))
    model = Dict{String,Any}("RBE3s" => Dict("41" => card))
    return first(UM_SOLVER.assemble_constraints(
        model, id_map, coords, frames, Int[], Int[], Float64[]))
end

function um_card(; refc=1, groups=[(wt=1., comps=1, grids=[2, 3])], um=[])
    return Dict{String,Any}("ID" => 41, "REFGRID" => 1, "REFC" => refc,
        "WT_GROUPS" => groups, "UM" => um)
end

function um_transformation(map, ndof)
    retained = setdiff(1:ndof, collect(keys(map)))
    T = Matrix{Float64}(I, ndof, ndof)[:, retained]
    columns = Dict(d => j for (j, d) in enumerate(retained))
    for (dependent, pairs) in map, (independent, coefficient) in pairs
        T[dependent, columns[independent]] = coefficient
    end
    return T
end

@testset "RBE3 UM uses the declared dependent set by default" begin
    ordinary = um_card()
    alternate = um_card(um=[(grid=2, comps=1)])
    baseline = um_constraint_map(ordinary)
    @test Set(keys(baseline)) == Set([1])
    @test sort(first.(baseline[1])) == [7, 13]
    @test [Dict(baseline[1])[d] for d in [7, 13]] ≈ [0.5, 0.5]
    # UM changes only elimination coordinates: u1=(u2+u3)/2 becomes u2=2u1-u3.
    for old_setting in (nothing, "true", "false")
        withenv("JFEM_RBE3_USE_UM_DEPENDENT" => old_setting) do
            alternate_map = um_constraint_map(alternate)
            @test Set(keys(alternate_map)) == Set([7])
            @test sort(first.(alternate_map[7])) == [1, 13]
            @test [Dict(alternate_map[7])[d] for d in [1, 13]] ≈ [2., -1.]
            @test um_constraint_map(ordinary) == baseline
        end
    end
    map = um_constraint_map(alternate)
    T = um_transformation(map, 18)
    C = zeros(1, 18); C[1, [1, 7, 13]] .= [1, -.5, -.5]
    @test norm(C * T) < 1e-13
    K = Diagonal(collect(1.:18.))
    f = collect(0.5:0.5:9.)
    q = (T' * K * T) \ (T' * f)
    u = T * q
    lambda = (C * C') \ (C * (f - K * u))
    @test K * u + C' * lambda ≈ f
    @test dot(q, T' * f) ≈ dot(u, f)
    @test dot(q, (T' * K * T) * q) ≈ dot(u, K * u)
    T0 = um_transformation(baseline, 18)
    @test u ≈ T0 * ((T0' * K * T0) \ (T0' * f))
end

@testset "Invalid UM sets fail instead of dropping equations" begin
    for entries in (
        [(grid=999, comps=1)],
        [(grid=2, comps=17)],
        [(grid=2, comps=1), (grid=2, comps=1)],
        [(grid=2, comps=12)],
        [(grid=2, comps=2)],
    )
        @test_throws ArgumentError um_constraint_map(um_card(um=entries))
    end
    @test_throws ArgumentError um_constraint_map(um_card(refc=12,
        groups=[(wt=1., comps=12, grids=[2, 3])], um=[(grid=2, comps=1)]))
    # Two selected x translations cannot eliminate both x and y equations.
    @test_throws ArgumentError um_constraint_map(um_card(refc=12,
        groups=[(wt=1., comps=12, grids=[2, 3])],
        um=[(grid=2, comps=1), (grid=3, comps=1)]))
end

@testset "Six-component UM in rotated GRID displacement frames" begin
    coords = [0. 0 0; 1 .3 .2; -.2 1 .4; .3 -.5 1]
    angle = .63
    Q = [cos(angle) -sin(angle) 0.; sin(angle) cos(angle) 0.; 0. 0. 1.]
    frames = Dict(1 => Q, 2 => Q', 3 => Matrix{Float64}(I, 3, 3), 4 => Q)
    groups = [(wt=1., comps=123456, grids=[2, 3, 4])]
    original = um_constraint_map(um_card(refc=123456, groups=groups);
        coords=coords, frames=frames)
    alternate = um_constraint_map(um_card(refc=123456, groups=groups,
        um=[(grid=2, comps=123456)]); coords=coords, frames=frames)
    @test Set(keys(alternate)) == Set(7:12)
    C = zeros(6, 24)
    for d in 1:6
        C[d, d] = 1
        for (j, coefficient) in original[d]
            C[d, j] -= coefficient
        end
    end
    @test norm(C * um_transformation(alternate, 24), Inf) < 1e-12
end

@testset "UM pivot validation is invariant to row and column units" begin
    A = [2. 1 -1; .5 3 1; 1 -.5 2]
    B = [1. 3; -2 .2; .3 -1]
    expected = -(A \ B)
    @test UM_SOLVER._solve_rbe3_um_dependents(A, B, 41) ≈ expected
    row_units = Diagonal([1e-9, 1e3, 1e9])
    col_units = Diagonal([1e6, 1e-6, 1e2])
    actual = UM_SOLVER._solve_rbe3_um_dependents(row_units * A * col_units,
        row_units * B, 41)
    @test col_units * actual ≈ expected
    @test_throws ArgumentError UM_SOLVER._solve_rbe3_um_dependents(
        [1. 2; 2 4], ones(2, 1), 41)
end
