using Test, LinearAlgebra, SparseArrays, OpenJFEM

# EIGRL V1=0., V2 blank, ND: the ND lowest positive factors, plus the
# load-reversal factors in (-B, 0). B = 0.9 * lowest positive factor when the
# positive branch fills ND, 0.9 * largest positive factor when it is exhausted.
module BucklingZeroLowerFixture
using LinearAlgebra, SparseArrays, OpenJFEM
function solve(roots, nd; n=24, upper=nothing, stiffness=ones(length(roots)))
    model = mktempdir() do dir
        path = joinpath(dir, "zero_lower.bdf")
        write(path, "SOL 105\nCEND\nBEGIN BULK\nPARAM,AUTOSPC,NO\n" *
            join(["GRID,$i,,$i.,0.,0." for i in 1:div(n, 6)], "\n") * "\nENDDATA\n")
        OpenJFEM.bdf_to_model(path)
    end
    # Mode i has elastic stiffness k_i and geometric stiffness k_i/root_i.
    k = ones(n); k[1:length(roots)] .= stiffness
    inverse = zeros(n); inverse[1:length(roots)] .= stiffness ./ roots
    K = sparse(Diagonal(k)); Kg = sparse(-Diagonal(inverse))
    ids = Dict(i => i for i in 1:div(n, 6))
    X = hcat(Float64.(1:div(n, 6)), zeros(div(n, 6), 2))
    R = [Matrix{Float64}(I, 3, 3) for _ in 1:div(n, 6)]
    OpenJFEM.Solver.solve_buckling(K, Kg, n, model, ids, X, nothing, R, nd;
        eigrl_v1=0.0, eigrl_v2=something(upper, 0.0), eigrl_v1_specified=true,
        eigrl_v2_specified=upper !== nothing, eigrl_nd_specified=true, return_diagnostics=true)
end
end

@testset "EIGRL V1=0 load-reversal window" begin
    solve = BucklingZeroLowerFixture.solve
    # ND filled: only the negative factor above -0.9*10 joins the positive branch.
    values, modes, diag = solve([10., 20., 30., 40., 50., 60., -5., -9.5, -50.], 4)
    @test isapprox(values, [-5., 10., 20., 30., 40.]; rtol=1e-9)
    @test size(modes, 2) == 5
    @test diag["zero_lower_window"]["status"] == "complete"
    @test !diag["zero_lower_window"]["positive_branch_exhausted"]
    # ND filled, empty window: one inertia count, no second eigen-solve.
    values, _, diag = solve([10., 20., 30., 40., 50., -9.5, -50.], 4)
    @test isapprox(values, [10., 20., 30., 40.]; rtol=1e-9)
    @test diag["zero_lower_window"]["status"] == "empty"
    # Positive branch exhausted before ND: the window reaches 0.9 * largest positive factor.
    values, _, diag = solve([10., 1000., -500., -899., -901., -2000.], 4)
    @test isapprox(values, [10., -500., -899., 1000.]; rtol=1e-9)
    @test diag["zero_lower_window"]["positive_branch_exhausted"]
    # An explicit upper bound keeps the ordinary positive interval.
    values, _, diag = solve([10., 20., 30., -5.], 4; upper=100.)
    @test isapprox(values, [10., 20., 30.]; rtol=1e-9)
    @test !haskey(diag, "zero_lower_window")
    # A stiff (membrane-like) mode gives a far but finite factor: 1e12 with elastic
    # stiffness 1e10. It must be returned although the partial solver stops short
    # and although its eigenpair residual is necessarily larger than a near root's.
    # A factor whose geometric stiffness is below one single-precision unit of the
    # elastic stiffness (here 1e22, ceiling 2^23*1e10/0.1 = 8.4e17) is not finite.
    values, _, diag = solve([10., 1.0e12, 1.0e22], 4; stiffness=[1., 1.0e10, 1.0e10])
    @test length(values) == 2
    @test isapprox(values[1], 10.; rtol=1e-9)
    @test isapprox(values[2], 1.0e12; rtol=1e-6)
    @test isapprox(diag["zero_lower_window"]["finite_factor_ceiling"], 2.0^23 * 1.0e10 / 0.1; rtol=1e-12)
end
