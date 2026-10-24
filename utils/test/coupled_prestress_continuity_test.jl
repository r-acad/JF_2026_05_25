using Test

module CoupledPrestressContinuityFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver

function checks()
    mktempdir() do dir
        path=joinpath(dir,"laminate.bdf")
        write(path,"""
SOL 105
CEND
BEGIN BULK
PARAM,SNORM,0.
GRID,1,,0.,0.,0.
GRID,2,,2.,0.,0.
GRID,3,,2.,1.,0.
GRID,4,,0.,1.,0.
CQUAD4,1,10,1,2,3,4
MAT8,1,140000.,9000.,.27,4500.,3800.,2600.,1.
PCOMP,10,-.01
+,1,.02,19.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(path)
        ids=Dict(i=>i for i=1:4)
        X=[0. 0. 0.;2. 0. 0.;2. 1. 0.;0. 1. 0.]
        R=[Matrix{Float64}(I,3,3) for _=1:4]
        normals=S.compute_snorm_normals(model,ids,X)
        mapping=S.assemble_constraints(model,ids,X,R,Int[],Int[],Float64[])[1]
        # Affine membrane fields have uniform, known prestress. A vanishing
        # laminate B matrix must not remove the assumed transverse gradient.
        for strain in ([-.001,0.,0.],[0.,-.001,0.],[-.001,-.0003,.0004])
            u=zeros(24)
            for i=1:4
                u[6i-5]=strain[1]*X[i,1]+strain[3]*X[i,2]/2
                u[6i-4]=strain[2]*X[i,2]+strain[3]*X[i,1]/2
            end
            kg(m)=Matrix(S.assemble_geometric_stiffness(m,ids,X,R,24,u,normals,mapping;
                snorm_angle_override=0.))
            G0=kg(model)
            for magnitude in (1e-5,1e-7,1e-9)
                coupled=deepcopy(model)
                property=coupled["PSHELLs"]["10"]
                property["Bmb"]=magnitude*property["Cm"]
                G=kg(coupled)
                w=[3,9,15,21]
                @test isapprox(G[w,w],G0[w,w];rtol=1e-6,atol=1e-10)
                @test norm(G-G') <= 1e-12*max(norm(G),1.)
                @test all(isfinite,G)
            end
        end
    end
end
end

@testset "Coupled laminate prestress interpolation is continuous" begin
    CoupledPrestressContinuityFixture.checks()
end
