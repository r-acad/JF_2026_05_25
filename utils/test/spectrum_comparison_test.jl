module SpectrumComparisonTests
using Test, LinearAlgebra, OpenJFEM

@testset "Signed multiset comparison and explicit extraction domains" begin
    reference = [-12.,-5.,-5.,0.,2.,3.,3.,20.,1e250]
    permutation = [9,5,3,7,1,4,2,8,6]
    result = compare_eigenvalue_spectra(reference,reference[permutation])
    @test result["pass"]
    @test result["ordering_changed"]
    @test length(result["matches"]) == length(reference)
    @test length(unique(row["candidate_index"] for row in result["matches"])) == length(reference)
    @test !compare_eigenvalue_spectra(reference,reference[1:end-1])["pass"]
    @test !compare_eigenvalue_spectra(reference,vcat(reference,[3.]))["pass"]
    @test !compare_eigenvalue_spectra([-1.,2.],[1.,2.])["pass"]
    @test compare_eigenvalue_spectra([2.,3.],[2.02,3.03])["status"] == "numerical_gap"
    @test compare_eigenvalue_spectra([2.,3.],[2.02,3.03])["unmatched_reference"] == []
    @test compare_eigenvalue_spectra([2.,2.],[2.])["status"] == "coverage_or_sign_gap"
    @test !compare_eigenvalue_spectra([200.],[201.])["pass"] # strict <0.5%
    @test compare_eigenvalue_spectra([200.],[prevfloat(201.)])["pass"]
    @test compare_eigenvalue_spectra([1.],[1.];relative_tolerance=0)["pass"]
    @test !compare_eigenvalue_spectra([0.],[1e-20])["pass"]
    @test compare_eigenvalue_spectra([0.],[-1e-12];absolute_tolerance=1e-10,zero_tolerance=1e-10)["pass"]
    @test !compare_eigenvalue_spectra([0.],[-1e-12];absolute_tolerance=1e-10)["pass"]
    @test !compare_eigenvalue_spectra([NaN],[NaN])["pass"]
    @test !compare_eigenvalue_spectra([Inf],[Inf])["pass"]
    @test !compare_eigenvalue_spectra([1+1e-14im],[1.])["pass"]
    @test compare_eigenvalue_spectra([1+0im],[1.])["pass"]
    @test !compare_eigenvalue_spectra([true],[1.])["pass"]
    @test !compare_eigenvalue_spectra([big"1e-1000"],[big"2e-1000"])["pass"]
    @test !compare_eigenvalue_spectra([big(2)^54+1],[big(2)^54])["pass"]
    @test compare_eigenvalue_spectra(BigFloat.([1.,2.]),[2.,1.])["pass"]
    disparate = compare_eigenvalue_spectra([1e-308],[1e308])
    @test !disparate["pass"]
    @test disparate["matches"][1]["relative_error"] === nothing
    @test disparate["matches"][1]["relative_error_unbounded_or_overflowed"]
    @test !compare_eigenvalue_spectra([],[])["pass"]
    @test compare_eigenvalue_spectra([1e-250],[1e-250])["pass"]
    @test compare_eigenvalue_spectra([1e250],[1e250])["pass"]
    @test !compare_eigenvalue_spectra([1e250],[2e250])["pass"]
    r = compare_eigenvalue_spectra([-4.,-4.,1.,2.],[2.,1.];lower=0,upper=2.)
    @test r["pass"]
    @test length(r["excluded_reference"]) == 2
    @test r["excluded_reference"][1]["index"] == 1
    @test r["excluded_reference"][1]["value"] == -4.
    @test r["completeness"] == "not_certified_by_root_lists"
    @test_throws ArgumentError compare_eigenvalue_spectra([1.],[1.];relative_tolerance=-1)
    @test_throws ArgumentError compare_eigenvalue_spectra([1.],[1.];lower=2,upper=1)
    @test_throws ArgumentError compare_eigenvalue_spectra([0.],[0.];lower=big"1e-400")
    @test_throws ArgumentError compare_eigenvalue_spectra([1.],[1.];relative_tolerance=big"1e1000")
    # Greedy nearest-neighbor pairing can leave a matchable root stranded.
    r = compare_eigenvalue_spectra([1.,1.008],[1.004,0.996];relative_tolerance=.005)
    @test r["pass"]
    @test length(r["within_tolerance_matches"]) == 2
    # A finite enormous root remains part of the spectrum, not an infinity.
    @test length(compare_eigenvalue_spectra([1.,1e300],[1.])["unmatched_reference"]) == 1
end

function permutations_of(values)
    length(values) <= 1 && return [values]
    [vcat(values[i],p) for i in eachindex(values)
        for p in permutations_of(values[setdiff(eachindex(values),[i])])]
end

@testset "Assignment agrees with exhaustive small independent oracle" begin
    # Exhaustive permutations provide an independent minimax oracle rather
    # than another implementation of augmenting-path matching.
    for reference in ([1.,1.008,1.02],[2.,3.,4.],[-4.,-3.,-2.]),
            candidate in permutations_of(reference .* [1.001,1.007,.999])
        possible = permutations_of(collect(1:3))
        oracle = minimum(maximum(abs(candidate[p[i]]-reference[i])/(.005*abs(reference[i])) for i in 1:3) for p in possible)
        r = compare_eigenvalue_spectra(reference,candidate)
        @test maximum(row["normalized_error"] for row in r["matches"]) ≈ oracle rtol=1e-14
        @test r["pass"] == (oracle < 1)
        @test length(r["matches"]) == 3
    end
    for candidate in permutations_of([1.,1.,2.,3.])
        r = compare_eigenvalue_spectra([1.,1.,2.,3.],candidate)
        @test r["pass"]
        @test length(r["matches"]) == 4
    end
end

@testset "Repeated eigenmodes compare as subspaces" begin
    U = Matrix{Float64}(I,6,6)[:,1:3]
    rotation = Matrix(qr([sin(i+2j) + (i==j ? 2. : 0.) for i in 1:3,j in 1:3]).Q)
    V = U*rotation*Diagonal([-1e-12,4.,1e12])
    r = compare_eigenspaces(U,V)
    @test r["pass"]
    @test r["maximum_sine_angle"] < 1e-12
    @test compare_eigenspaces(U,1e308*U*rotation)["pass"]
    @test compare_eigenspaces(U,1e-310*U*rotation)["pass"]
    @test !compare_eigenspaces(U,V[:,1:2])["pass"]
    @test !compare_eigenspaces(U,hcat(U[:,1],U[:,1],U[:,3]))["pass"]
    @test !compare_eigenspaces(U,Matrix{Float64}(I,6,6)[:,2:4])["pass"]
    # An SPD energy metric preserves independent modes under highly
    # nonuniform DOF units, even when Euclidean columns are nearly parallel.
    T = [1. 1.;0. 1e-9]
    K = inv(T)'*inv(T)
    @test compare_eigenspaces(T,T*rotation[1:2,1:2];metric=K)["pass"]
    @test_throws PosDefException compare_eigenspaces(U,U;metric=Diagonal([1.,1.,1.,1.,1.,-1.]))
    @test_throws DimensionMismatch compare_eigenspaces(U,U[1:5,:])
    @test !compare_eigenspaces(zeros(6,0),zeros(6,0))["pass"]
    # Independent but different repeated-mode subspaces must never pass.
    for angle in (.001,.1,1.)
        W = copy(U); W[:,3] = [0.,0.,cos(angle),sin(angle),0.,0.]
        @test !compare_eigenspaces(U,W)["pass"]
    end
end

@testset "Original-pencil residuals do not certify missing roots" begin
    A = Diagonal([0.,2.,6.,0.]); B = Diagonal([1.,1.,2.,0.])
    U = Matrix{Float64}(I,4,4)
    for common_scale in (1e-100,1.,1e100), mode_scale in (1e-50,-1.,1e50)
        r = eigenpair_diagnostics(common_scale*A,common_scale*B,[0.,2.,3.],mode_scale*U[:,1:3])
        @test r["pass"]
        @test r["completeness"] == "not_certified_by_residuals"
    end
    r = eigenpair_diagnostics(A,B,[1.],U[:,4:4])
    @test !r["pass"]
    @test r["pairs"][1]["reason"] == "common_nullspace"
    @test !eigenpair_diagnostics(A,B,[2.1],U[:,2:2])["pass"]
    @test !eigenpair_diagnostics(A,B,[Inf],U[:,4:4])["pass"]
    @test !eigenpair_diagnostics(A,B,[0.],zeros(4,1))["pass"]
    @test eigenpair_diagnostics(A,B,[2.],U[:,2:2])["pass"] # only one valid root
    # Finite large actions must not create a zero residual by overflowing the
    # denominator to infinity. Both sides of this pencil are exactly known.
    @test !eigenpair_diagnostics(reshape([1e308],1,1),ones(1,1),[1.2e308],ones(1,1))["pass"]
    @test eigenpair_diagnostics(reshape([1e308],1,1),ones(1,1),[1e308],ones(1,1))["pass"]
    @test !eigenpair_diagnostics(ones(1,1),reshape([1e308],1,1),[1e308],ones(1,1))["pass"]
    Q = Matrix(qr([sin(i+2j)+(i==j ? 2. : 0.) for i in 1:4,j in 1:4]).Q)
    Ar = Q'*Diagonal([0.,2.,3.,5.])*Q
    rigid = Q'*[1.,0.,0.,0.]
    @test eigenpair_diagnostics(Ar,Matrix{Float64}(I,4,4),[0.],reshape(rigid,4,1))["pass"]
    singular = Q'*Diagonal([1.,2.,3.,0.])*Q
    nullmode = reshape(Q'*[0.,0.,0.,1.],4,1)
    joint = eigenpair_diagnostics(singular,singular,[1e30],nullmode)
    @test !joint["pass"]
    @test joint["pairs"][1]["reason"] == "common_nullspace"
    infinite = eigenpair_diagnostics(Matrix{Float64}(I,4,4),singular,[1e30],nullmode)
    @test !infinite["pass"]
    @test infinite["pairs"][1]["reason"] == "unresolved_B_action"
end

end
