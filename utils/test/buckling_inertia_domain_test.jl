using Test
module BucklingInertiaDomainFixture
using Test, LinearAlgebra, SparseArrays, OpenJFEM
const S = OpenJFEM.Solver

@testset "Signed buckling inertia counts branches and multiplicity" begin
    # Six finite roots, including two repeated pairs, plus six infinite roots.
    # The oracle is the prescribed spectrum, not another eigensolver.
    roots = [-5., -2., -2., 3., 3., 9.]
    n = 12
    Q = Matrix(qr([sin(.31i*j) + cos(.13i*(j+1)) +
                   (i == j ? 1. : 0.) for i in 1:n, j in 1:n]).Q)
    for T in (Matrix{Float64}(I,n,n), Q,
              Q * Diagonal(exp.(range(-3.,3.;length=n))))
        K = sparse(T' * T)
        Kg = sparse(-T' * Diagonal(vcat(1. ./ roots, zeros(6))) * T)
        inertia(t) = S._buckling_sturm_count(K, Kg, Float64(t))
        for t in (-10., -4., -1., 0., 1., 4., 10.)
            expected = count(root -> 1. - t/root < 0., roots)
            @test inertia(t) == expected
        end
        for (a,b) in ((0.,4.), (1.,10.), (4.,10.))
            @test inertia(b) - inertia(a) == count(x -> a < x < b, roots)
        end
        for (a,b) in ((-10.,-4.), (-4.,-1.), (-10.,-1.))
            @test inertia(a) - inertia(b) == count(x -> a < x < b, roots)
        end
        @test inertia(-4.) + inertia(4.) == count(x -> -4. < x < 4., roots)
        # The old unrestricted endpoint subtraction is demonstrably wrong.
        @test inertia(-1.) - inertia(-4.) == -2
        @test inertia(4.) - inertia(-4.) == 0
    end
end

@testset "Modal PSD-mass inertia retains its lower-end offset" begin
    K = sparse(Diagonal([-7.,1.,4.,10.,-3.,5.]))
    M = sparse(Diagonal([1.,1.,1.,1.,0.,0.]))
    # A negative finite root and a negative stiff massless coordinate are
    # already present below the nonnegative modal interval.
    nlo = S._buckling_sturm_count(K,-M,-1.)
    nhi = S._buckling_sturm_count(K,-M,6.)
    @test nlo == 2
    @test nhi == 4
    @test nhi - nlo == 2 # exactly the finite roots 1 and 4
end

function solve_pencil(K, Kg)
    n = size(K,1)
    model = mktempdir() do dir
        path = joinpath(dir,"matrix_fixture.bdf")
        write(path,"SOL 105\nCEND\nBEGIN BULK\nPARAM,AUTOSPC,NO\n" *
            join(["GRID,$i,,$i.,0.,0." for i in 1:div(n,6)],"\n") * "\nENDDATA\n")
        OpenJFEM.bdf_to_model(path)
    end
    ids = Dict(i=>i for i in 1:div(n,6))
    X = hcat(Float64.(1:div(n,6)),zeros(div(n,6),2))
    R = [Matrix{Float64}(I,3,3) for _ in 1:div(n,6)]
    S.solve_buckling(sparse(K),sparse(Kg),n,model,ids,X,nothing,R,3;
        eigrl_v1=0.,eigrl_v2=4.,eigrl_v1_specified=true,
        eigrl_v2_specified=true,return_diagnostics=true)
end

@testset "Buckling positive-count diagnostic requires certified elastic K" begin
    withenv("JFEM_SOL105_STURM_COMPLETENESS"=>"true",
            "JFEM_SOL105_DENSE_MAX_DOF"=>"0",
            "JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF"=>"600") do
        for indefinite in (false,true)
            K = Diagonal(vcat([indefinite ? -1. : 1.],ones(23)))
            Kg = -K * Diagonal(1. ./ collect(1.:24.))
            vals,modes,d = solve_pencil(K,Kg)
            @test isapprox(vals,[1.,2.,3.];rtol=2e-10)
            @test all(S._buckling_original_pencil_residual(K,-Kg,
                modes[:,j],vals[j]) < 1e-8 for j in 1:3)
            info = d["sturm_completeness"]
            if indefinite
                @test info["status"] == "not_certified"
                @test info["reason"] == "elastic_pencil_not_positive_definite"
                @test !haskey(info,"sturm_eigs_in_interval")
            else
                @test info["status"] == "informational"
                @test info["sturm_eigs_in_interval"] == 3
                @test info["recovered_in_interval"] == 3
            end
        end
    end
end
end
