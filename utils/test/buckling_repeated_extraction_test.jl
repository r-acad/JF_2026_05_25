using Test
module BucklingRepeatedExtractionFixture
using Test, LinearAlgebra, SparseArrays, OpenJFEM
const S=OpenJFEM.Solver
function model_context(n)
    model=mktempdir() do dir
        path=joinpath(dir,"matrix_fixture.bdf")
        write(path,"SOL 105\nCEND\nBEGIN BULK\nPARAM,AUTOSPC,NO\n"*
            join(["GRID,$i,,$i.,0.,0." for i=1:div(n,6)],"\n")*"\nENDDATA\n")
        OpenJFEM.bdf_to_model(path)
    end
    ids=Dict(i=>i for i=1:div(n,6));X=hcat(Float64.(collect(1:div(n,6))),zeros(div(n,6),2))
    R=[Matrix{Float64}(I,3,3) for _=1:div(n,6)]
    model,ids,X,R
end
function solve_pencil(K,Kg,nd;lower=nothing,upper=nothing)
    n=size(K,1);model,ids,X,R=model_context(n)
    S.solve_buckling(sparse(K),sparse(Kg),n,model,ids,X,nothing,R,nd;
        eigrl_v1=lower===nothing ? 0. : Float64(lower),
        eigrl_v2=upper===nothing ? 0. : Float64(upper),
        eigrl_v1_specified=lower!==nothing,eigrl_v2_specified=upper!==nothing,
        return_diagnostics=true)
end
function checks()
    n=24
    starts=hcat([S._deterministic_buckling_start_vector(n,i) for i=1:12]...)
    @test rank(starts)==12
    @test starts==hcat([S._deterministic_buckling_start_vector(n,i) for i=1:12]...)
    # Sixfold multiplicity exceeds the old four-function starting span.
    spectrum=vcat([2.,3.],fill(5.,6),[8.,9.],collect(11.:24.))
    Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
    for rotated in (false,true),scaled in (false,true)
        T=(rotated ? Q : Matrix{Float64}(I,n,n))*(scaled ? Diagonal(exp.(range(-8.,8.;length=n))) : I)
        K=T'*T;Kg=-(T'*Diagonal(1 ./ spectrum)*T)
        for (nd,lower,upper) in ((7,nothing,nothing),(8,0.,10.),(4,4.,6.),(3,4.,Inf))
            values,vectors,diag=solve_pencil(K,Kg,nd;lower=lower,upper=isfinite(something(upper,Inf)) ? upper : nothing)
            expected=filter(x->(lower===nothing||x>=lower)&&(upper===nothing||x<=upper),spectrum)[1:nd]
            @test values≈expected rtol=2e-10
            @test size(vectors,2)==nd
            whitened=cholesky(Symmetric(K)).U*vectors
            for j in axes(whitened,2);whitened[:,j]./=norm(whitened[:,j]);end
            @test rank(whitened;rtol=1e-9)==nd
            @test whitened'*whitened≈Matrix{Float64}(I,nd,nd) atol=1e-8
            @test all(r["requested_eigenpairs"]<=nd for r in diag["eigsolve_requests"])
            @test all(get(r,"candidate_pairs_examined",0)<=nd for r in diag["solver_attempts"])
            @test any(get(r,"algorithm","")=="SymmetricSubset" for r in diag["eigsolve_requests"])
            @test all(S._buckling_original_pencil_residual(K,-Kg,vectors[:,j],values[j])<1e-8 for j=1:nd)
        end
    end
end
@testset "Bounded buckling extraction retains repeated eigenspaces" begin
    withenv("JFEM_SOL105_BLOCK_LANCZOS"=>nothing,"JFEM_SOL105_BLOCK_SIZE"=>nothing,
            "JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF"=>"600") do
        checks()
    end
end
end

using Test,LinearAlgebra,OpenJFEM
@testset "Repeated signed intervals and bounded fallback policy" begin
    S=OpenJFEM.Solver;T=BucklingRepeatedExtractionFixture
    n=24;I24=Matrix{Float64}(I,n,n)
    roots=vcat([-2.,-3.],fill(-5.,6),collect(-8.:-1.:-23.))
    K=I24;Kg=-Diagonal(1 ./ roots)
    for (lo,hi) in ((nothing,-4.),(-6.,-4.)),nd in (3,5)
        vals,modes,d=T.solve_pencil(K,Kg,nd;lower=lo,upper=hi)
        @test vals≈fill(-5.,nd) rtol=2e-10
        @test rank(modes;rtol=1e-9)==nd
        @test all(S._buckling_original_pencil_residual(K,-Kg,modes[:,j],vals[j])<1e-8 for j=1:nd)
        @test any(get(r,"metric","")=="elastic" for r in d["eigsolve_requests"])
        @test all(r["requested_eigenpairs"]<=nd for r in d["eigsolve_requests"])
    end
    # Indefinite elastic matrices have no admissible SPD whitening. Preserve
    # the scalar fallback and its original-pencil residual checks.
    K=Diagonal(vcat([-1.],ones(23)));Kg=-K*Diagonal(1 ./ collect(1.:24.))
    vals,modes,d=T.solve_pencil(K,Kg,3)
    @test vals≈[1.,2.,3.] rtol=2e-10
    @test any(get(r,"block_error",nothing)!==nothing for r in d["solver_attempts"])
    @test any(get(r,"algorithm","")=="Arnoldi" for r in d["eigsolve_requests"])
    @test all(S._buckling_original_pencil_residual(K,-Kg,modes[:,j],vals[j])<1e-8 for j=1:3)
    # The configurable automatic work bound must not force a block on larger
    # jobs. Explicit opt-in remains available under the original API.
    withenv("JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF"=>"0") do
        vals,_,d=T.solve_pencil(I24,-Diagonal(1 ./ collect(1.:24.)),3)
        @test vals≈[1.,2.,3.] rtol=2e-10
        @test all(get(r,"algorithm","")=="Arnoldi" for r in d["eigsolve_requests"])
    end
end

@testset "Signed magnitude ties and empty-row embedding" begin
    S=OpenJFEM.Solver;F=BucklingRepeatedExtractionFixture
    withenv("JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF"=>"600") do
        roots=vcat(fill(2.,4),fill(-2.,4),[3.,-3.],collect(4.:17.))
        K=Matrix{Float64}(I,24,24);Kg=-Diagonal(1 ./ roots)
        vals,modes,d=F.solve_pencil(K,Kg,5)
        @test isapprox(abs.(vals),fill(2.,5);rtol=2e-10)
        @test 1<=count(>(0.),vals)<=4
        @test rank(modes;rtol=1e-9)==5
        @test all(S._buckling_original_pencil_residual(K,-Kg,modes[:,j],vals[j])<1e-8 for j=1:5)
        request=only(filter(r->get(r,"algorithm","")=="SymmetricSubset",d["eigsolve_requests"]))
        @test request["eigenvectors_requested"]==5
        @test request["eigenvalue_only_candidates"]==10
        roots=vcat([2.,3.],fill(5.,6),collect(8.:17.))
        K=Diagonal(vcat(ones(18),zeros(6)))
        Kg=-Diagonal(vcat(1 ./ roots,zeros(6)))
        vals,modes,d=F.solve_pencil(K,Kg,7)
        @test isapprox(vals,roots[1:7];rtol=2e-10)
        @test size(modes)==(24,7)
        @test all(iszero,modes[19:24,:])
        @test rank(modes;rtol=1e-9)==7
        @test all(S._buckling_original_pencil_residual(K,-Kg,modes[:,j],vals[j])<1e-8 for j=1:7)
        @test all(r["requested_eigenpairs"]<=7 for r in d["eigsolve_requests"])
    end
end
