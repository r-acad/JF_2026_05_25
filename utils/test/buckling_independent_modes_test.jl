using Test, LinearAlgebra, SparseArrays, OpenJFEM

@testset "Buckling Ritz directions and repeated eigenspaces" begin
    S = OpenJFEM.Solver
    # A large-factor Ritz root may be returned twice with slightly different
    # values and vectors. It must consume one output slot, not two.
    K = Diagonal([1., 2., 3., 4.])
    vectors = [1. 1. 0. 0.; 0. 0. 1. 0.; 0. 5e-7 0. 0.; 0. 0. 0. 1.]
    values = [5e5, 5e5 * (1 + 4e-8), 5e5, 7e5]
    roots, modes, added = S._buckling_merge_unique_eigenpairs(
        K, Float64[], zeros(4, 0), values, vectors; positive_definite=true)
    @test roots == [5e5, 5e5, 7e5]
    @test added == 3
    @test rank(modes) == 3
    # A retry can return a different linear combination of a repeated pair.
    r, m, n = S._buckling_merge_unique_eigenpairs(K, roots, modes,
        [5e5], reshape([1., 2., 0., 0.], 4, 1); positive_definite=true)
    @test r == roots
    @test m == modes
    @test n == 0

    # Physical-coordinate vectors can be almost parallel yet represent two
    # independent elastic modes; a MAC-only duplicate filter would lose one.
    Kscaled = Diagonal([1., 1e16])
    directions = [1. 1.; 1e-8 -1e-8]
    @test abs(dot(directions[:,1], Kscaled * directions[:,2])) < 1e-14
    r, m, n = S._buckling_merge_unique_eigenpairs(Kscaled, Float64[],
        zeros(2, 0), [3., 3.], directions; positive_definite=true)
    @test r == [3., 3.]
    @test n == 2
    @test rank(m; rtol=1e-10) == 2

    # Values alone are never a multiplicity filter, including a tightly
    # clustered but distinct pair.
    r, m, n = S._buckling_merge_unique_eigenpairs(Matrix{Float64}(I, 2, 2),
        Float64[], zeros(2, 0), [1., 1. + 1e-8], Matrix{Float64}(I, 2, 2))
    @test r == [1., 1. + 1e-8]
    @test n == 2
    @test m == Matrix{Float64}(I, 2, 2)

    # LU/indefinite pencils have independent isotropic directions: zero
    # elastic energy does not imply zero displacement or a repeated vector.
    Kindef = Diagonal([1., 1., -1.])
    directions = [1. 1.; 0. 1.; 0. 1.]
    @test Kindef * directions == 2 .* ((Kindef / 2) * directions)
    r, m, n = S._buckling_merge_unique_eigenpairs(Kindef, Float64[],
        zeros(3, 0), [2., 2.], directions)
    @test r == [2., 2.]
    @test n == 2
    @test rank(m) == 2

    # Early shifted searches may have no factor of elastic K. Use the SPD
    # shifted matrix itself, rather than treating it as a certificate for K.
    shifted_metric = Diagonal([1., 2., 3.])
    shift = (M=shifted_metric, reduced=false, factor_backend="cholesky")
    metric, certified = S._buckling_independence_metric(Kindef, "lu", shift)
    @test metric === shifted_metric
    @test certified
    r, m, n = S._buckling_merge_unique_eigenpairs(metric, Float64[], zeros(3, 0),
        [2., 2., 2.], hcat(directions, directions[:, 2]); positive_definite=certified)
    @test n == 2
    @test rank(m) == 2
    @test S._buckling_independence_metric(K, "cholesky", shift) == (K, true)
    @test S._buckling_independence_metric(Kindef, "lu", nothing) == (Kindef, false)
    @test S._buckling_independence_metric(Kindef, "lu",
        merge(shift, (reduced=true,))) == (Kindef, false)
    @test S._buckling_independence_metric(Kindef, "lu",
        merge(shift, (factor_backend="lu",))) == (Kindef, false)
end
