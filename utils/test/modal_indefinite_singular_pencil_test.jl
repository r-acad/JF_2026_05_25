using Test, LinearAlgebra, SparseArrays, OpenJFEM

module ModalIndefiniteSingularPencilFixture
using Test, LinearAlgebra, SparseArrays, OpenJFEM
const S = OpenJFEM.Solver

function run_pencil(K, M, requested)
    model=Dict{String,Any}("SOL"=>103,"PARAM_AUTOSPC"=>false,"SPC1s"=>Any[])
    ids=Dict(1=>1); X=zeros(1,3); R=[Matrix{Float64}(I,3,3)]
    withenv("JFEM_SOL103_DENSE_MAX_DOF"=>"0", "JFEM_SOL103_BLOCK_SIZE"=>"2") do
        S.solve_modes(sparse(K),sparse(M),6,model,ids,X,0,R,requested;
            return_diagnostics=true,orig_diag=diag(K))
    end
end

function check_modes(K,M,reference; negative=nothing, factor_backend="positive_mass_shift_lu", singular_coordinates=1)
    values,frequency,vectors,diagnostics=run_pencil(K,M,length(reference))
    @test length(values)==length(reference)
    @test values≈reference rtol=2e-8 atol=1e-9
    @test frequency≈sqrt.(reference)./(2pi) rtol=2e-8 atol=1e-9
    @test diagnostics["eigen_cache"]["factor_backend"]==factor_backend
    factor_backend=="positive_mass_shift_lu" && @test diagnostics["solver_backend"]=="shifted_lu_arnoldi"
    @test diagnostics["inertia_origin"]["used"]
    @test diagnostics["massless_free_dofs_removed"]==0
    @test diagnostics["singular_mass_coordinates_retained"]==singular_coordinates
    @test length(diagnostics["eigenpair_relative_residuals"])==length(reference)
    @test maximum(diagnostics["eigenpair_relative_residuals"])<1e-8
    @test vectors'*M*vectors≈Matrix{Float64}(I,length(reference),length(reference)) atol=2e-8
    for j in eachindex(values)
        @test norm(K*vectors[:,j]-values[j]*M*vectors[:,j])≤1e-7*norm(vectors[:,j])
    end
    if negative!==nothing
        @test any(x->isapprox(x,negative;rtol=1e-7,atol=1e-8),diagnostics["negative_finite_eigenvalues"])
        @test diagnostics["negative_finite_spectrum_complete"]==false
    else
        @test isempty(diagnostics["negative_finite_eigenvalues"])
    end
end

function checks()
    M=Diagonal([1.,0.,2.,1.,1.,1.])
    # The negative, massless stiffness is an infinite pencil root. No
    # alpha*M shift can make K SPD; finite roots remain exactly 4 and 6.
    check_modes(Diagonal([4.,-5.,12.,100.,200.,300.]),M,[4.,6.])
    # A stiff massless coordinate must be eliminated algebraically, rather
    # than fixed: the Schur complement is 5-2*(-1/4)*2=6, not 5.
    K=Matrix(Diagonal([5.,-4.,14.,100.,200.,300.]));K[1,2]=K[2,1]=2.
    check_modes(K,M,[6.,7.])
    # Repeated finite roots require independent eigenvectors, not two
    # copies of the same scalar-Arnoldi direction.
    K[3,3]=12.
    check_modes(K,M,[6.,6.])
    # A genuine negative finite eigenvalue is residual-checked and reported
    # as an instability diagnostic; it is never assigned a real frequency.
    K=Diagonal([-3.,-5.,8.,16.,200.,300.])
    check_modes(K,M,[4.,16.];negative=-3.)
    # A positive shift can admit Cholesky despite a negative finite root.
    # Its negative inertia still must be subtracted from completeness counts.
    check_modes(Diagonal([-.1,4.,6.,100.,200.,300.]),Matrix{Float64}(I,6,6),[4.,6.];
        negative=-.1,factor_backend="positive_mass_shift_cholesky",singular_coordinates=0)
    # A massless coordinate with zero K diagonal is not stiffness-free if
    # its column couples: this 2x2 block has determinant -4 independent of
    # lambda, hence only infinite roots. Fixing DOF2 would invent lambda5.
    K=Matrix(Diagonal([5.,0.,12.,100.,200.,300.]));K[1,2]=K[2,1]=2.
    check_modes(K,M,[6.,100.])
    # A shared nontrivial K/M nullspace cannot be cured by an exact shift.
    # LU must fail rather than introducing invented mass or stiffness.
    shared=sparse([1. 1.;1. 1.])
    @test_throws ErrorException S._sol103_shifted_factorization(shared,shared,1e-12,1e-12,0.)
    # Ordinary positive-definite pencils retain the original factor route.
    _,_,_,_,attempts=S._sol103_shifted_factorization(sparse(Diagonal([4.,12.])),sparse(Diagonal([1.,2.])),1e-12,1e-12,0.)
    @test attempts[end]["factor_backend"]=="positive_mass_shift_cholesky"
end
end

@testset "Finite modes of indefinite stiffness and singular mass" begin
    ModalIndefiniteSingularPencilFixture.checks()
end
