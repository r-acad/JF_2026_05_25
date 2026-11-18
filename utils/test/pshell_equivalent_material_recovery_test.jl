using Test, OpenJFEM, LinearAlgebra

module PShellEquivalentMaterialRecoveryFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver

function checks()
    mktempdir() do dir
        deck=joinpath(dir,"aliases.bdf")
        write(deck,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,1.,.5,0.
GRID,4,,-1.,.5,0.
CQUAD4,1,1,1,2,3,4
MAT1,1,7.E10,,.3,2700.
MAT1,2,7.E10,,.3,1000.
MAT1,3,7.E10,,.3,8000.
PSHELL,1,1,.01,1,1.,1,.8333333333333333
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(deck)
        prop=model["PSHELLs"]["1"]
        @test S._pshell_equivalent_mat1_law(model,1,2)
        @test S._pshell_equivalent_mat1_law(model,1,3)
        @test !S._pshell_local_constitutive_gap(prop,model)
        prop["MID2"]=2;prop["MID3"]=3
        # The shared derivative guard retains independent material IDs. An
        # elastic alias at this state need not remain equal under a material
        # perturbation, so recovery opts in explicitly instead.
        @test S._pshell_local_constitutive_gap(prop,model)
        @test !S._pshell_local_constitutive_gap(prop,model;equivalent_materials=true)
        ids=Dict(i=>i for i=1:4);Rs=[Matrix{Float64}(I,3,3) for _=1:4]
        function recover(X,u)
            output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in ("forces","forces_bilin","stresses","strains"))
            normals=S.compute_snorm_normals(model,ids,X)
            S.recover_shell_stresses!(model,ids,X,Rs,u,normals,Dict{Int,Float64}(),output)
            output
        end
        for skew in (0.,.4),warp in (0.,.03),offset in (0.,.02,-.02)
            X=[-1. -.5 warp;1. -.5 -warp;1.0+skew .5 warp;-1.0+skew .5 -warp]
            model["CSHELLs"]["1"]["ZOFFS"]=offset
            u=1e-4sin.(collect(1.:24.))
            prop["MID2"]=1;prop["MID3"]=1;shared=recover(X,u)
            prop["MID2"]=2;prop["MID3"]=3;aliases=recover(X,u)
            for key in ("forces","forces_bilin","stresses","strains")
                @test shared[key]==aliases[key]
            end
            @test length(aliases["stresses"]["quad4"])==1
        end
        # Equality of IDs/nominal E never authorizes a different shear law,
        # thermal law, anisotropic law or membrane/bending coupling.
        saved=model["MATs"]["3"]["G"]
        model["MATs"]["3"]["G"]=saved/2
        @test S._pshell_local_constitutive_gap(prop,model;equivalent_materials=true)
        model["MATs"]["3"]["G"]=saved
        model["_active_temp_sid"]=1
        @test S._pshell_local_constitutive_gap(prop,model;equivalent_materials=true)
        delete!(model,"_active_temp_sid")
        prop["MID4"]=2
        @test S._pshell_local_constitutive_gap(prop,model;equivalent_materials=true)
        prop["MID4"]=0
        anisotropic=deepcopy(model)
        anisotropic["MATs"]=Dict{String,Any}(model["MATs"])
        anisotropic["MATs"]["2"]=Dict{String,Any}(model["MATs"]["2"])
        anisotropic["MATs"]["2"]["TYPE"]="MAT2"
        @test S._pshell_local_constitutive_gap(prop,anisotropic;equivalent_materials=true)

        # An explicit compatible-only bending experiment retains its old
        # corner law. Derive that law independently from bilinear rotation
        # gradients; an unconditional condensed correction would fail here.
        prop["MID2"]=1;prop["MID3"]=1
        model["CSHELLs"]["1"]["ZOFFS"]=0.
        X=[-1. -.5 0.;1. -.5 0.;1. .5 0.;-1. .5 0.]
        u=1e-4sin.(collect(1.:24.))
        E=model["MATs"]["1"]["E"];nu=model["MATs"]["1"]["NU"];h=prop["T"]
        D=E*h^3/(12*(1-nu^2))*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
        function compatible_moment(r,s)
            dr=[-(1-s),1-s,1+s,-(1+s)]/4
            ds=[-(1-r),-(1+r),1+r,1-r]/4
            g=([dr';ds']*X[:,1:2])\[dr';ds']
            kappa=[sum(g[1,k]*u[6k-1] for k=1:4),
                  -sum(g[2,k]*u[6k-2] for k=1:4),
                   sum(g[2,k]*u[6k-1]-g[1,k]*u[6k-2] for k=1:4)]
            -D*kappa
        end
        oracle=reduce(vcat,permutedims.([compatible_moment(r,s) for (r,s) in ((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))]))
        oracle[:,3].=compatible_moment(0.,0.)[3]
        corner_matrix(output)=reduce(vcat,[permutedims([row[k] for k in ("mx","my","mxy")]) for row in output["forces_bilin"]["quad4"] if row["grid_id"] isa Int])
        active=corner_matrix(recover(X,u))
        disabled=withenv("JFEM_Q4_STATIC_BENDING_INCOMP"=>"false") do
            corner_matrix(recover(X,u))
        end
        @test isapprox(disabled,oracle;rtol=2e-12,atol=1e-9) && !isapprox(active,oracle;rtol=1e-6,atol=1e-9)
    end
end
end

@testset "Equal MAT1 material aliases preserve physical PSHELL recovery" begin
    PShellEquivalentMaterialRecoveryFixture.checks()
end
