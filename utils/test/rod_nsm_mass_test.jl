using Test
module RodNonstructuralLineFixture
using Test,OpenJFEM,LinearAlgebra
const S=OpenJFEM.Solver
function checks()
    mktempdir() do dir
        for family in ("CROD","CONROD"),coupled in (0,1),A in (0.,2.),rho in (0.,3.)
            card=family=="CROD" ? "CROD,1,1,1,2\nPROD,1,1,$A,.5,,4.\n" : "CONROD,1,1,2,1,$A,.5,,4.\n"
            path=joinpath(dir,"rod.bdf")
            write(path,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,$coupled\nGRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\n"*card*"MAT1,1,7.e10,,.3,$rho\nENDDATA\n")
            model=OpenJFEM.bdf_to_model(path);ids=Dict(1=>1,2=>2);X=[0. 0. 0.;2. 0. 0.];Id=Matrix{Float64}(I,3,3)
            M=Matrix(S.assemble_mass(model,ids,X,[Id,Id],12));mass=2*(rho*A+4.)
            @test M[[1,7],[1,7]] ≈ (coupled==1 ? mass/12*[5. 1.;1. 5.] : mass/2*Id[1:2,1:2])
            @test M[2,2] == M[8,8] == mass/2
            @test all(iszero,M[[4,5,6,10,11,12],:])
            for d=1:3
                q=zeros(12);q[d]=q[d+6]=1.;@test dot(q,M*q) ≈ mass
            end
            @test M==M'
            @test minimum(eigvals(Symmetric(M)))>=-1e-12
            # A unit increase of NSM contributes one mass/length, regardless
            # of structural density or area, including the pure-NSM case.
            if family=="CROD"
                model["PRODs"]["1"]["NSM"]=5.
            else
                model["CONRODs"]["1"]["NSM"]=5.
            end
            increment=Matrix(S.assemble_mass(model,ids,X,[Id,Id],12))-M
            expected=zeros(12,12)
            expected[[1,7],[1,7]]=coupled==1 ? (2/12)*[5. 1.;1. 5.] : [1. 0.;0. 1.]
            for d in (2,3,8,9);expected[d,d]=1.;end
            @test isapprox(increment,expected;rtol=2e-14,atol=2e-14)
            # Signed NSM remains a signed mass increment when the total
            # mass is positive; it must not be discarded by an NSM > 0 guard.
            if A==2. && rho==3.
                property=family=="CROD" ? model["PRODs"]["1"] : model["CONRODs"]["1"]
                property["NSM"]=0.
                Mzero=Matrix(S.assemble_mass(model,ids,X,[Id,Id],12))
                property["NSM"]=-1.
                Mnegative=Matrix(S.assemble_mass(model,ids,X,[Id,Id],12))
                @test isapprox(Mnegative-Mzero,-expected;rtol=2e-14,atol=2e-14)
                @test all(iszero,Mnegative[[4,5,6,10,11,12],:])
                @test minimum(eigvals(Symmetric(Mnegative)))>=-1e-12
                for d=1:3
                    q=zeros(12);q[d]=q[d+6]=1.
                    @test isapprox(dot(q,Mnegative*q),2*(rho*A-1.);rtol=2e-14)
                end
            end
            if family=="CROD"
                model["PRODs"]["1"]["NSM"]=4.
            else
                model["CONRODs"]["1"]["NSM"]=4.
            end
            angle=.41;Q=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]
            T=kron(Matrix{Float64}(I,4,4),Q)
            @test S.assemble_mass(model,ids,X,[Q,Q],12) ≈ T'*M*T rtol=1e-13
        end
    end
end
@testset "Rod NSM is an independent line mass including zero area" begin
    checks()
end
end
