using Test, LinearAlgebra, SparseArrays, Random
include(joinpath(@__DIR__, "..", "..", "src", "solver", "modal_mass_support.jl"))

@testset "Exact mass support preserves finite modes and full stiffness response" begin
    rng = MersenneTwister(103)
    n, r = 60, 12
    support = sort(randperm(rng,n)[1:r])
    B = randn(rng,r,r)
    Ms = B*B' + I
    M = spzeros(n,n); M[support,support] = sparse(Ms)
    # Stored zeros outside the support must not enlarge the iterative space.
    M[1,1] += 0.0
    reduction = _sol103_mass_support(M)
    @test reduction.eligible
    @test reduction.support == support
    @test reduction.C * reduction.C' ≈ Ms rtol=1e-13
    H = randn(rng,n,n); K = H*H' + I
    massless = setdiff(1:n,support)
    condensed = K[support,support] - K[support,massless]*(K[massless,massless]\K[massless,support])
    reference = eigvals(Symmetric(condensed),Symmetric(Ms))
    for alpha in (0.01, 100., 1e5)
        factor = cholesky(Symmetric(sparse(K)+alpha*M))
        op, backmap = _sol103_mass_support_operator(factor,reduction,alpha)
        eye = Matrix{Float64}(I,r,r)
        T = hcat([op(eye[:,j]) for j=1:r]...)
        @test T ≈ T' rtol=1e-12
        eig = eigen(Symmetric(T))
        values = alpha .* (1. ./ eig.values .- 1.)
        @test sort(values) ≈ reference rtol=1e-8
        for j in 1:r
            x = backmap(eig.vectors[:,j])
            @test norm(K*x-values[j]*M*x)/(norm(K*x)+abs(values[j])*norm(M*x)) < 1e-8
        end
        # Retained operator values are not overwritten by a subsequent call.
        first = op(eye[:,1]); saved = copy(first); op(eye[:,2])
        @test first == saved
    end
    # Coordinate unit changes must retain arbitrarily small positive masses.
    D = Diagonal(exp.(range(-40.,40.;length=n)))
    units = _sol103_mass_support(sparse(D*M*D))
    @test units.eligible
    @test units.support == support
    @test units.C*units.C' ≈ (D*M*D)[support,support] rtol=1e-12
    @test !_sol103_mass_support(M;max_support=r-1).eligible
    @test !_sol103_mass_support(M;max_support=0).eligible
    indefinite = copy(M); indefinite[support[1],support[1]] = -1.
    @test !_sol103_mass_support(indefinite).eligible
    singular = spzeros(n,n); singular[support,support] = sparse(ones(r,r))
    @test !_sol103_mass_support(singular).eligible
    full = sparse(Matrix{Float64}(I,n,n))
    @test !_sol103_mass_support(full).eligible
end
