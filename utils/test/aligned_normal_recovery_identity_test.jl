using Test, LinearAlgebra, StaticArrays, OpenJFEM

module AlignedNormalRecoveryIdentityFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM

function fixture(dir,kind)
    xy=[-1. -.5;1. -.5;.7 .5;-.8 .5]
    X=hcat(xy,zeros(4))
    path=joinpath(dir,"aligned_normal_"*string(kind)*".bdf")
    open(path,"w") do io
        print(io,"SOL 101\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\n")
        for i=1:4;println(io,join(["GRID",i,"",X[i,:]...],','));end
        print(io,"CQUAD4,1,10,1,2,3,4\n")
        if kind in (:pcomp,:pcomp_legacy)
            print(io,"MAT8,1,1.0E7,7.0E6,.25,3.0E6,2.0E6,1.3E6,1000.\n")
            print(io,"PCOMP,10\n+,1,.05,0.,YES,1,.05,90.,YES\n+,1,.05,90.,YES,1,.05,0.,YES\n")
        else
            print(io,"MAT1,1,7.E10,2.E10,.29,2700.\nPSHELL,10,1,.1,1,1.,1,.25\n")
        end
        print(io,"ENDDATA\n")
    end
    model=OpenJFEM.bdf_to_model(path)
    if kind===:ti4
        model["CSHELLs"]["1"]["CORNER_THICKNESSES"]=[.07,.1,.13,.09]
        model["CSHELLs"]["1"]["TFLAG"]=0
    elseif kind===:pcomp_legacy
        model["SOL"]=106
        model["PARAM_NLMETHOD"]="legacy"
    end
    model,xy,X
end

function recover(model,X,u,normals)
    ids=Dict(i=>i for i=1:4)
    Rs=[Matrix{Float64}(I,3,3) for _=1:4]
    output=Dict{String,Any}(key=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[])
                           for key in ("forces","forces_bilin","stresses","strains"))
    captured=Dict{Int,Any}()
    S.recover_shell_stresses!(model,ids,X,Rs,u,normals,Dict{Int,Float64}(),output;
                             static_fields_capture=captured)
    output,captured
end

function checks()
    ids=Dict(i=>i for i=1:4)
    absent=Dict{Int,SVector{3,Float64}}()
    mktempdir() do dir
        for kind in (:pshell,:ti4,:pcomp,:pcomp_legacy)
            model,xy,X=fixture(dir,kind)
            points=[SVector{3}(X[i,:]) for i=1:4]
            v1,v2,v3=S.shell_element_frame_quad4(points...,S.q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC"))
            aligned=Dict(i=>v3 for i=1:4)
            pq=S.snorm_element_pq(v1,v2,v3,1:4,aligned)
            @test size(pq)==(4,3)
            @test all(iszero,pq[:,1:2]) && all(==(1.),pq[:,3])
            @test !S.snorm_quad4_field_is_active(pq,points,v1,v3)
            @test F.quad4_physical_displacement_map(xy,X,pq)==Matrix{Float64}(I,24,24)
            # Compare complete output and captured fields for nontrivial states,
            # so a changed mean-versus-center Q route cannot hide behind zero work.
            for u in (1e-3*sin.(collect(1.:24.)),1e-3*cos.(collect(1.:24.)))
                none=recover(model,X,u,absent)
                yes=recover(model,X,u,aligned)
                @test isequal(none,yes)
                @test none[1]["recovery_diagnostics"]["area_mean_transverse_shear_eids"]==[1]
            end
            # Exercise actual generated normal selection, not only a hand-built map.
            model["PARAM_SNORM"]=0.
            K0=first(S.assemble_stiffness(model))
            model["PARAM_SNORM"]=20.
            generated=S.compute_snorm_normals(model,ids,X)
            @test length(generated)==4
            K1=first(S.assemble_stiffness(model))
            @test isequal(K0,K1)
            @test isequal(recover(model,X,1e-3*sin.(collect(1.:24.)),absent),
                          recover(model,X,1e-3*sin.(collect(1.:24.)),generated))
        end

        # Acceptance is physically meaningful on a warped cell even with zero
        # p/q: it removes the old corner moment tilt. Never discard this field.
        model,xy,X=fixture(dir,:ti4)
        Xw=hcat(xy,.025*[1.,-1.,1.,-1.])
        points=[SVector{3}(Xw[i,:]) for i=1:4]
        v1,v2,v3=S.shell_element_frame_quad4(points...,S.q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC"))
        center=sum(points)/4
        localxy=[dot(p-center,v) for p in points,v in (v1,v2)]
        accepted=hcat(zeros(4,2),ones(4))
        @test !F.quad4_snorm_pq_has_active_rows(accepted)
        @test S.snorm_quad4_field_is_active(accepted,points,v1,v3)
        W=F.quad4_finite_warp_displacement_map(localxy,Xw)
        P=F.quad4_physical_displacement_map(localxy,Xw,accepted)
        @test W!==nothing && norm(P-W)>1e-8
        @test F.quad4_snorm_corner_warp_map(localxy,Xw,zeros(4,3))===nothing
        aligned=Dict(i=>v3 for i=1:4)
        @test S._pshell_rectangular_anisotropic_recovery_data(
            model,model["PSHELLs"]["10"],model["CSHELLs"]["1"],ids,Xw,aligned;
            corner_thickness=true)===nothing
        @test_throws ArgumentError recover(model,Xw,1e-3*sin.(collect(1.:24.)),aligned)
        tilted=Dict(i=>SVector{3,Float64}(.05,-.02,1.) for i=1:4)
        @test S._pshell_rectangular_anisotropic_recovery_data(
            model,model["PSHELLs"]["10"],model["CSHELLs"]["1"],ids,X,tilted;
            corner_thickness=true)===nothing
    end
end
end

@testset "Aligned planar normal metadata preserves recovery and active-warp guards" begin
    AlignedNormalRecoveryIdentityFixture.checks()
end
