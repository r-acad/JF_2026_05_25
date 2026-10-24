using Test, OpenJFEM, LinearAlgebra

@testset "Rod and solid coupled inertia" begin
    F=OpenJFEM.FEM; S=OpenJFEM.Solver
    m=2700*.002*.4
    M=F.reference_coupled_mass_rod(.4,2700.,.002)
    @test M[[1,7],[1,7]] ≈ m/12*[5. 1.;1. 5.]
    @test M[2,2] == M[8,8] == m/2
    @test all(iszero,M[[4,5,6,10,11,12],:])
    @test minimum(eigvals(Symmetric(M))) >= -32eps(Float64)*norm(M)
    for d in 1:3
        q=zeros(12);q[d]=q[d+6]=1
        @test dot(q,M*q) ≈ m
    end
    mktempdir() do dir
        # A unit cube has an exact tensor-product mass integral. Verify the
        # production PARAM dispatch, conservation and nodal-CD congruence.
        nodes=[0. 0. 0.;1. 0. 0.;1. 1. 0.;0. 1. 0.;
               0. 0. 1.;1. 0. 1.;1. 1. 1.;0. 1. 1.]
        for coupled in (0,1)
            grids=join(["GRID,$i,,"*join(nodes[i,:],",") for i in 1:8],"\n")
            p=joinpath(dir,"solid.bdf")
            write(p,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,$coupled\n"*
                grids*"\nCHEXA,1,1,1,2,3,4,5,6\n+,7,8\n"*
                "PSOLID,1,1\nMAT1,1,70.e9,,.3,2700.\nENDDATA\n")
            model=OpenJFEM.bdf_to_model(p)
            _,ids,X,nd,R=S.assemble_stiffness(model)
            mass=S.assemble_mass(model,ids,X,R,nd)
            expected=zeros(8,8)
            for i in 1:8,j in 1:8
                expected[i,j]=coupled==0 ? (i==j ? 2700/8 : 0) :
                    2700*prod(nodes[i,d]==nodes[j,d] ? 1/3 : 1/6 for d in 1:3)
            end
            @test Matrix(mass[1:6:end,1:6:end]) ≈ expected rtol=1e-13
            @test sum(mass[1:6:end,1:6:end]) ≈ 2700
            angle=.39;Q=[cos(angle) -sin(angle) 0.;sin(angle) cos(angle) 0.;0. 0. 1.]
            RR=[Q for _ in 1:8];T=kron(Matrix{Float64}(I,16,16),Q)
            @test S.assemble_mass(model,ids,X,RR,nd) ≈ T'*mass*T rtol=1e-13
        end
    end
end
