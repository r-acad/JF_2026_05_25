using Test, LinearAlgebra, SparseArrays, OpenJFEM

module BucklingSignedIntervalFixture
using LinearAlgebra, SparseArrays, OpenJFEM
function solve_pencil(K, Kg, nd; lower=nothing, upper=nothing)
    n = size(K, 1)
    model = mktempdir() do dir
        path = joinpath(dir, "signed_interval.bdf")
        write(path, "SOL 105\nCEND\nBEGIN BULK\nPARAM,AUTOSPC,NO\n" *
            join(["GRID,$i,,$i.,0.,0." for i in 1:div(n, 6)], "\n") * "\nENDDATA\n")
        OpenJFEM.bdf_to_model(path)
    end
    ids = Dict(i => i for i in 1:div(n, 6))
    X = hcat(Float64.(1:div(n, 6)), zeros(div(n, 6), 2))
    R = [Matrix{Float64}(I, 3, 3) for _ in 1:div(n, 6)]
    OpenJFEM.Solver.solve_buckling(sparse(K), sparse(Kg), n, model, ids, X,
        nothing, R, nd; eigrl_v1=something(lower, 0.), eigrl_v2=something(upper, 0.),
        eigrl_v1_specified=lower !== nothing, eigrl_v2_specified=upper !== nothing,
        return_diagnostics=true)
end
end

@testset "Asymmetric signed intervals do not deflate an excluded branch" begin
    S = OpenJFEM.Solver
    # More excluded roots than the old boundary-retry limit. Run the actual
    # iterative path as well as the bounded symmetric-subset implementation.
    roots = vcat(-collect(.001:.001:.012), collect(1.:12.))
    K = Matrix{Float64}(I,24,24)
    Kg = -Diagonal(1 ./ roots)
    for bound in ("0","600"), reversed in (false,true)
        signed_roots = reversed ? -roots : roots
        signed_Kg = reversed ? -Kg : Kg
        lo,hi = reversed ? (-12.,.0001) : (-.0001,12.)
        withenv("JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF"=>bound,
                "JFEM_SOL105_BOUNDARY_RETRIES"=>"0") do
            vals,modes,diag = BucklingSignedIntervalFixture.solve_pencil(K,signed_Kg,4;
                lower=lo,upper=hi)
            expected = sort(filter(x->lo <= x <= hi,signed_roots);by=abs)[1:4]
            @test isapprox(vals,expected;rtol=1e-9)
            @test diag["signed_branch_targeting"]["complete"]
            @test diag["boundary_targeting"]["excluded_pairs"] == 0
            @test length(diag["eigsolve_requests"]) == 3
            @test all(r["requested_eigenpairs"] <= 4 for r in diag["eigsolve_requests"])
            @test all(S._buckling_original_pencil_residual(K,-signed_Kg,modes[:,j],vals[j])<1e-8
                      for j in eachindex(vals))
        end
    end
end

@testset "Buckling intervals retain the closest admissible signed roots" begin
    S = OpenJFEM.Solver
    # Independent known spectrum: negative factors describe load reversal.
    roots = vcat([.02, -.03, -.08, .09, -.4, .6, -3.2, 4.6, -10., 12., -14., 18.],
                 collect(20.:31.))
    n = length(roots)
    Q = Matrix(qr([sin(.27i*j) + cos(.19i*(j+1)) + (i == j ? 1. : 0.)
                   for i in 1:n, j in 1:n]).Q)
    intervals = ((-1e8, 1e8, 8), (.05, 30., 4), (-30., -.05, 4),
                 (-.1, 30., 6), (-30., .1, 6))
    withenv("JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF" => "600") do
        for rotated in (false, true), scale in (1., 1e-6, 1e6)
            T = rotated ? Q * Diagonal(exp.(range(-4., 4.; length=n))) : Matrix{Float64}(I, n, n)
            K = scale * (T' * T)
            Kg = -scale * (T' * Diagonal(1 ./ roots) * T)
            for (lo, hi, nd) in intervals
                values, modes, diag = BucklingSignedIntervalFixture.solve_pencil(K, Kg, nd;
                    lower=lo, upper=hi)
                admissible = filter(x -> lo <= x <= hi, roots)
                expected = sort(admissible; by=abs)[1:nd]
                @test isapprox(values, expected; rtol=2e-9)
                @test size(modes, 2) == nd
                @test all(S._buckling_original_pencil_residual(K, -Kg, modes[:, j], values[j]) < 1e-8
                          for j in 1:nd)
                @test all(r["requested_eigenpairs"] <= nd for r in diag["eigsolve_requests"])
                @test rank(cholesky(Symmetric(K)).U * modes; rtol=1e-9) == nd
                if lo < 0. < hi
                    target = diag["signed_interval_target"]
                    @test target["sigma"] == 0.
                    @test target["selector"] == "LM"
                    @test target["signed_eigenvalues_preserved"]
                end
            end
        end
    end
end
