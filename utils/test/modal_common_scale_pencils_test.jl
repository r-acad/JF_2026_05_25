using Test

module ModalCommonScalePencilsFixture
using Test, LinearAlgebra, SparseArrays, OpenJFEM
const S=OpenJFEM.Solver
const RECORDS=Any[]

function solve(K,M,requested)
    n=size(K,1)
    model=Dict{String,Any}("SOL"=>103,"PARAM_AUTOSPC"=>false,"SPC1s"=>Any[])
    ids=Dict(i=>i for i=1:div(n,6))
    X=hcat(Float64.(1:div(n,6)),zeros(div(n,6),2))
    R=[Matrix{Float64}(I,3,3) for _=1:div(n,6)]
    S.solve_modes(sparse(K),sparse(M),n,model,ids,X,0,R,requested;
        return_diagnostics=true,orig_diag=diag(K))
end

function check(K0,M0,T,g,expected,label;requested=length(expected),no_negative=false)
    K=g*(T'*K0*T);M=g*(T'*M0*T)
    vals,_,U,d=solve(K,M,requested)
    record=Dict("label"=>label,"scale"=>g,"expected"=>expected,
        "values"=>vals,"diagnostics"=>d)
    push!(RECORDS,record)
    @test length(vals)==length(expected)
    @test size(U)==(size(K,1),length(expected))
    @test d["massless_free_dofs_removed"]==0
    if length(vals)==length(expected)
        @test isapprox(vals,expected;atol=2e-8,rtol=2e-8)
        @test isapprox(U'*M*U,Matrix{Float64}(I,length(vals),length(vals));atol=2e-8,rtol=2e-8)
        actions=Float64[]
        for j in eachindex(vals)
            u=U[:,j]
            if vals[j]>.5
                push!(actions,norm(K*u-vals[j]*(M*u))/(norm(K*u)+abs(vals[j])*norm(M*u)))
            else
                @test norm(K*u)<=2e-8*opnorm(K,Inf)*norm(u)
            end
        end
        @test maximum(actions;init=0.)<2e-7
        record["positive_action_residuals"]=actions
    end
    no_negative && @test isempty(d["negative_finite_eigenvalues"])
end

function checks()
    withenv("JFEM_SOL103_DENSE_MAX_DOF"=>"0","JFEM_SOL103_MASS_RANK_MAX_DOF"=>"600",
            "JFEM_SOL103_ZERO_SHIFT_COMPAT"=>nothing) do
        @testset "Common matrix units and independent DOF permutation" begin
            n=24;v=Float64.(1:n)
            Q=Matrix{Float64}(I,n,n)-(2/dot(v,v))*(v*v')
            K=Diagonal(vcat([-4.,-4.,0.,0.,1.,1.,2.],collect(3.:19.)))
            M=Diagonal(vcat(ones(20),zeros(4)))
            expected=[0.,0.,1.,1.,2.,3.,4.,5.,6.,7.,8.,9.]
            # Orthogonal change of coordinates isolates common physical-unit
            # scaling from the separate, strongly conditioned Ritz-vector test.
            for g in (1e-36,1e-18,1.,1e18,1e36),permuted in (false,true)
                T=permuted ? Q[:,reverse(1:n)] : Q
                @testset "g=$g permuted=$permuted" begin
                    check(K,M,T,g,expected,permuted ? "permuted" : "original_order")
                end
            end
        end
        @testset "Higher-index infinite chains never become finite roots" begin
            n=6;v=Float64.(1:n)
            Q=Matrix{Float64}(I,n,n)-(2/dot(v,v))*(v*v')
            # det([0 1;1 0]-lambda*[1 0;0 0])=-1 for every lambda.
            # The last two coordinates therefore contain no finite root.
            K=Matrix(Diagonal([2.,3.,4.,5.,0.,0.]));K[5,6]=K[6,5]=1.
            M=Diagonal([1.,2.,3.,4.,1.,0.])
            for g in (1e-36,1.,1e36),T in (Matrix{Float64}(I,n,n),Q,Q[:,reverse(1:n)])
                @testset "constant determinant chain g=$g" begin
                    check(K,M,T,g,[1.25,4/3,1.5,2.],"constant_determinant_chain";
                        requested=8,no_negative=true)
                end
            end
            # A second independent constant-determinant block: -4. Its
            # apparent massive diagonal is not an additional lambda=5 mode.
            K=Matrix(Diagonal([5.,0.,12.,100.,200.,300.]));K[1,2]=K[2,1]=2.
            M=Diagonal([1.,0.,2.,1.,1.,1.])
            for g in (1e-36,1.,1e36),T in (Matrix{Float64}(I,n,n),Q,Q[:,reverse(1:n)])
                @testset "coupled massless chain g=$g" begin
                    check(K,M,T,g,[6.,100.,200.,300.],"coupled_massless_chain";
                        requested=8,no_negative=true)
                end
            end
        end
    end
end
end

@testset "Modal common-scale and infinite-chain invariants" begin
    ModalCommonScalePencilsFixture.checks()
end
