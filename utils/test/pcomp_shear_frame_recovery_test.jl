using Test

module PcompShearFrameRecoveryFixture
using Test, LinearAlgebra, OpenJFEM
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver

function checks()
    mktempdir() do dir
        deck=joinpath(dir,"rotated_shear.bdf")
        write(deck,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,.7,.5,0.
GRID,4,,-.7,.5,0.
CQUAD4,1,10,1,2,3,4
MAT8,1,1.E7,7.E6,.25,3.E6,2.E6,.3E6,1000.
PCOMP,10
+,1,.05,0.,YES,1,.05,45.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(deck)
        xy=[-1. -.5;1. -.5;.7 .5;-.7 .5]
        X=hcat(xy,zeros(4));ids=Dict(i=>i for i=1:4)
        R=[Matrix{Float64}(I,3,3) for _=1:4]
        normals=S.compute_snorm_normals(model,ids,X)
        u=1e-3sin.(collect(1.:24.))
        p=model["PSHELLs"]["10"]
        @test p["Bmb"] !== nothing && norm(p["Bmb"])>0
        for sol in (101,105,106), beta in (0.0,-0.61,0.43,1.13)
            model["SOL"]=sol
            model["CSHELLs"]["1"]["THETA"]=rad2deg(beta)
            output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[])
                for key in ("forces","forces_bilin","stresses","strains"))
            S.recover_shell_stresses!(model,ids,X,R,u,normals,Dict{Int,Float64}(),output)
            A=F.rotate_constitutive_3x3!(copy(p["Cm"]),beta)
            B=F.rotate_constitutive_3x3!(copy(p["Bmb"]),beta)
            D=F.rotate_constitutive_3x3!(copy(p["Cb"]),beta)
            c,s=cos(beta),sin(beta);Q=[c -s;s c]
            C=Q*p["Cs"]*Q'
            expected=F.quad4_macneal_mean_shear_resultant(xy,u,D,C,p["T"];Cm=A,Bmb=B)
            row=only(output["forces"]["quad4"])
            section=F.quad4_condensed_section_fields(xy,u,A,B,D,C,p["T"],1.0;k6rot=0.0)
            @test isapprox([row["fx"],row["fy"],row["fxy"]],section.N_average;rtol=2e-10)
            @test isapprox([row["mx"],row["my"],row["mxy"]],-section.M_average;rtol=2e-10)
            @test [row["qx"],row["qy"]] ≈ expected rtol=2e-10
            @test all(isfinite(row[k]) for k in ("fx","fy","fxy","mx","my","mxy","qx","qy"))
        end
    end
end
end

@testset "Rotated laminate shear recovery matches physical constitutive axes" begin
    PcompShearFrameRecoveryFixture.checks()
end
