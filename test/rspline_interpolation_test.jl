using Test, LinearAlgebra, SparseArrays

module RSplineTestHarness
using LinearAlgebra, SparseArrays
log_msg(message) = nothing
solver_env_bool(key, default) = default
solver_env_float(key, default) = default
include(joinpath(@__DIR__, "..", "src", "parsing", "ReferenceParser.jl"))
include(joinpath(@__DIR__, "..", "src", "solver", "constraints.jl"))
end
const RSPL = RSplineTestHarness

# Independent strain-energy integration, using the second derivatives of
# cubic Hermite displacement fields rather than the production beam matrix.
function rspline_integrated_energy_matrix(x, dl)
    n = size(x, 1)
    total = sum(norm(x[i+1, :] - x[i, :]) for i in 1:n-1)
    inertia = (dl * total)^2 / 8
    K = zeros(6n, 6n)
    for i in 1:n-1
        dx = x[i+1, :] - x[i, :]; L = norm(dx); axis = dx / L
        seed = abs(axis[1]) < .8 ? [1., 0., 0.] : [0., 1., 0.]
        ey = normalize(cross(axis, seed)); ez = cross(axis, ey)
        R = vcat(axis', ey', ez'); T = kron(Matrix{Float64}(I, 4, 4), R)
        Ke = zeros(12, 12)
        for z in (-inv(sqrt(3.)), inv(sqrt(3.)))
            t = (z+1)/2
            B = zeros(4, 12)
            B[1, [1, 7]] = [-1., 1.] / L
            B[2, [4, 10]] = [-1., 1.] / L
            ddh = [(-6+12t)/L^2, (-4+6t)/L, (6-12t)/L^2, (-2+6t)/L]
            B[3, [2, 6, 8, 12]] = ddh
            B[4, [3, 5, 9, 11]] = ddh .* [1., -1., 1., -1.]
            Ke += (L/2) * B' * Diagonal([1., inertia, inertia, inertia]) * B
        end
        d = 6(i-1)+1:6(i+1)
        K[d, d] += T' * Ke * T
    end
    return K
end

function rspline_rigid_fields(x)
    Q = zeros(6size(x, 1), 6)
    for i in axes(x, 1), j in 1:3
        axis = Matrix{Float64}(I, 3, 3)[:, j]
        Q[6(i-1) .+ (1:3), j] = axis
        Q[6(i-1) .+ (1:3), j+3] = cross(axis, x[i, :])
        Q[6(i-1) .+ (4:6), j+3] = axis
    end
    return Q
end

@testset "RSPLINE straight cubic bending and linear axial/torsion" begin
    x = [0. 0 0; .5 0 0; 2. 0 0]
    expected = [ .75 0 0 0 0 0 .25 0 0 0 0 0;
                  0 .84375 0 0 0 .28125 0 .15625 0 0 0 -.09375;
                  0 0 .84375 0 -.28125 0 0 0 .15625 0 .09375 0;
                  0 0 0 .75 0 0 0 0 0 .25 0 0;
                  0 0 .5625 0 .1875 0 0 0 -.5625 0 -.3125 0;
                  0 -.5625 0 0 0 .1875 0 .5625 0 0 0 -.3125 ]
    for dl in (.001, .01, .1, .5, 2.)
        M, dep = RSPL._rspline_interpolation(x, [1, 3], dl)
        @test dep == [2]
        @test M ≈ expected rtol=2e-13 atol=2e-14
    end
end

@testset "RSPLINE curved ordered tube: stationarity, objectivity and units" begin
    x = [0. 0 0; .4 .2 .1; 1.2 .1 .3; 1.7 -.25 .4; 2.5 .5 -.2]
    ind = [1, 3, 5]; dep = [2, 4]
    ii = [6(i-1)+c for i in ind for c in 1:6]
    dd = [6(i-1)+c for i in dep for c in 1:6]
    Q = rspline_rigid_fields(x)
    angle = .61; R = [cos(angle) -sin(angle) 0.; sin(angle) cos(angle) 0.; 0. 0. 1.]
    for dl in (.01, .1, .5)
        M, _ = RSPL._rspline_interpolation(x, ind, dl)
        K = rspline_integrated_energy_matrix(x, dl)
        @test norm(K[dd, dd]*M + K[dd, ii]) / norm(K[dd, ii]) < 2e-12
        @test norm(M*Q[ii, :] - Q[dd, :]) / norm(Q[dd, :]) < 2e-12
        moved, _ = RSPL._rspline_interpolation(x .+ [3. -2. 4.], ind, dl)
        @test moved ≈ M rtol=3e-12 atol=1e-12
        rotated, _ = RSPL._rspline_interpolation(x*R', ind, dl)
        @test rotated ≈ kron(Matrix{Float64}(I, 4, 4), R)*M*kron(Matrix{Float64}(I, 6, 6), R') rtol=3e-12 atol=1e-12
        for length_scale in (1e-6, 1e6)
            scaled, _ = RSPL._rspline_interpolation(length_scale*x, ind, dl)
            S = Diagonal(repeat([length_scale, length_scale, length_scale, 1., 1., 1.], 2))
            U = Diagonal(repeat([length_scale, length_scale, length_scale, 1., 1., 1.], 3))
            @test inv(S)*scaled*U ≈ M rtol=3e-12 atol=1e-12
        end
    end
    thin, _ = RSPL._rspline_interpolation(x, ind, .01)
    thick, _ = RSPL._rspline_interpolation(x, ind, .5)
    @test norm(thin-thick) > .1 # D/L matters for the curved path.
    # Reversing the same ordered path is a relabeling, not a different tube.
    reversemap, _ = RSPL._rspline_interpolation(reverse(x; dims=1), ind, .1)
    M, _ = RSPL._rspline_interpolation(x, ind, .1)
    @test reversemap ≈ M[vcat(7:12, 1:6), vcat(13:18, 7:12, 1:6)] rtol=2e-12 atol=1e-12
end

@testset "RSPLINE parser retains Gi/Ci positions and small GRID IDs" begin
    parser = RSPL.ReferenceParser
    lines = ["RSPLINE,91,.1,1,2,2,3,,4", "+,123,5"]
    rsp = parser.extract_rspline(parser.process_cards(lines)["RSPLINE"])["91"]
    @test rsp["GRIDS"] == [1, 2, 3, 4, 5]
    @test rsp["COMPONENTS"] == [0, 2, 0, 123, 0]
    @test rsp["INDEP_GRIDS"] == [1, 3, 5]
    @test rsp["DEP"] == [(2, 2), (4, 1), (4, 2), (4, 3)]
    tagged = ["RSPLINE,91,.1,1,2,2,3,,4,+PATH", "+PATH,123,5"]
    @test parser.extract_rspline(parser.process_cards(tagged)["RSPLINE"])["91"] == rsp
    fields = ["91", ".1", "1", "2", "2", "3", "", "4", "123", "5"]
    for width in (8, 16)
        per_line = width == 8 ? 8 : 4
        physical = String[]
        for i in 1:per_line:length(fields)
            name = i == 1 ? (width == 8 ? "RSPLINE" : "RSPLINE*") : (width == 8 ? "+" : "*")
            push!(physical, rpad(name, 8)*join(lpad(v, width) for v in fields[i:min(i+per_line-1, end)]))
        end
        @test parser.extract_rspline(parser.process_cards(physical)["RSPLINE"])["91"] == rsp
    end
    for bad in ("RSPLINE,92,.1,1,2,22,3", "RSPLINE,92,0.,1,2,2,3", "RSPLINE,92,.1,1,2,2")
        @test_throws ArgumentError parser.extract_rspline(parser.process_cards([bad])["RSPLINE"])
    end
end

@testset "RSPLINE component frames, partial rows and virtual work" begin
    x = [0. 0 0; .4 .2 .1; 1.2 .1 .3; 1.7 -.25 .4; 2.5 .5 -.2]
    rsp = Dict("GRIDS"=>collect(1:5), "COMPONENTS"=>[0, 2, 0, 123, 0], "DL"=>.1)
    R = [0. -1 0; 1 0 0; 0 0 1.]
    frames = [R, Matrix{Float64}(I, 3, 3), Matrix{Float64}(I, 3, 3), R, Matrix{Float64}(I, 3, 3)]
    ids = Dict(i=>i for i in 1:5)
    graph = RSPL._rspline_constraint_rows(rsp, 1, ids, x, frames)
    @test Set(keys(graph)) == Set([8, 19, 20, 21])
    M, _ = RSPL._rspline_interpolation(x, [1, 3, 5], .1)
    Q = zeros(30, 30)
    for i in 1:5, block in (1:3, 4:6)
        d = 6(i-1) .+ block; Q[d, d] = frames[i]
    end
    ii = vcat(1:6, 13:18, 25:30); dd = vcat(7:12, 19:24)
    expected = Q[dd, dd]' * M * Q[ii, ii]
    for d in sort!(collect(keys(graph)))
        row = zeros(30)
        for (j, v) in graph[d]; row[j] = v; end
        @test row[ii] ≈ expected[findfirst(==(d), dd), :] rtol=1e-13 atol=1e-14
    end
    model = Dict("RSPLINEs"=>Dict("1"=>rsp))
    actual, _, _, _ = RSPL.assemble_constraints(model, ids, x, frames, Int[], Int[], Float64[])
    @test actual == graph
    # A real constrained spring system checks load redistribution and work.
    dependent = sort!(collect(keys(graph))); retained = setdiff(1:30, dependent)
    T = Matrix{Float64}(I, 30, 30)[:, retained]
    for d in dependent, (j, v) in graph[d]; T[d, findfirst(==(j), retained)] += v; end
    K = Diagonal(collect(1.:30.)); f = sin.(collect(1.:30.))
    C = zeros(length(dependent), 30)
    for (a, d) in enumerate(dependent)
        C[a, d] = 1
        for (j, v) in graph[d]; C[a, j] -= v; end
    end
    reduced = RSPL._apply_constraint_congruence(K, graph)
    @test Matrix(reduced[retained, retained]) ≈ T'*K*T
    u = T*((T'*K*T)\(T'*f))
    lagrange = [Matrix(K) C'; C zeros(length(dependent), length(dependent))] \ vcat(f, zeros(length(dependent)))
    @test u ≈ lagrange[1:30]
    @test dot(u, K*u) ≈ dot(u, f)
    @test norm(C*u) < 1e-13
end

@testset "RSPLINE invalid path metadata fails explicitly" begin
    x = [0. 0 0; .5 0 0; 1. 0 0]
    for dl in (0., -1., Inf, NaN)
        @test_throws ArgumentError RSPL._rspline_interpolation(x, [1, 3], dl)
    end
    @test_throws ArgumentError RSPL._rspline_interpolation(x, [1, 2], .1)
    @test_throws ArgumentError RSPL._rspline_interpolation(x, [3, 1], .1)
    @test_throws ArgumentError RSPL._rspline_interpolation([0. 0 0; 0 0 0; 1 0 0; 2 0 0], [1, 2, 4], .1)
    @test_throws ArgumentError RSPL._rspline_constraint_rows(Dict("INDEP_GRIDS"=>[1, 3], "DEP"=>[(2, 2)]), 1,
        Dict(i=>i for i in 1:3), x, fill(Matrix{Float64}(I, 3, 3), 3))
end

@testset "RSPLINE coincident stations use the zero-length tube limit" begin
    compact = [0. 0 0; .4 .2 .1; 1.2 .1 .3; 2.5 .5 -.2]
    M, _ = RSPL._rspline_interpolation(compact, [1, 4], .1)
    # Repeated endpoints and one repeated internal dependent station.
    x = compact[[1, 1, 2, 2, 3, 4, 4], :]
    expanded, dep = RSPL._rspline_interpolation(x, [1, 7], .1)
    @test dep == [2, 3, 4, 5, 6]
    @test expanded[1:6, :] == hcat(Matrix{Float64}(I, 6, 6), zeros(6, 6))
    @test expanded[7:12, :] ≈ M[1:6, :]
    @test expanded[13:18, :] ≈ M[1:6, :]
    @test expanded[19:24, :] ≈ M[7:12, :]
    @test expanded[25:30, :] == hcat(zeros(6, 6), Matrix{Float64}(I, 6, 6))
    Q = rspline_rigid_fields(x)
    @test expanded * Q[vcat(1:6, 37:42), :] ≈ Q[7:36, :]
end
