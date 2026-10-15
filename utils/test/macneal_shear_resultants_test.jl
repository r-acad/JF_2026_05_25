using Test, OpenJFEM, LinearAlgebra, ForwardDiff

@testset "Laminate shear resultant is work-conjugate on distorted cells" begin
    F=OpenJFEM.FEM
    A=[30. 4. 1.;4. 12. -0.5;1. -0.5 5.]
    D=[0.7 0.08 0.03;0.08 0.3 -0.02;0.03 -0.02 0.15]
    C=[9. 1.2;1.2 4.]
    h=0.2
    for xy in ([-1. -0.5;1. -0.5;1. 0.5;-1. 0.5],
               [-1. -0.5;1. -0.5;0.6 0.5;-0.8 0.5],
               [-1. -0.5;1. -0.5;1.3 0.5;-0.3 0.5])
        area=abs(sum(xy[i,1]*xy[mod1(i+1,4),2]-xy[mod1(i+1,4),1]*xy[i,2] for i=1:4))/2
        K=zeros(24,24)
        F.add_quad4_macneal_shear_rbf!(K,xy,D,C,h;Cm=A)
        u=sin.(collect(1.:24.))
        q=F.quad4_macneal_mean_shear_resultant(xy,u,D,C,h;Cm=A)
        # Uniform physical shear test motions have no bending curvature;
        # independently differentiate elastic energy in those directions.
        for gamma in ([1.,0.],[0.,1.],[0.4,-0.7])
            v=zeros(24)
            for i=1:4
                v[6(i-1)+4]=-gamma[2]
                v[6(i-1)+5]= gamma[1]
            end
            work=ForwardDiff.derivative(t->dot(u+t*v,K*(u+t*v))/2,0.)
            @test dot(gamma,q)*area ≈ work rtol=1e-11 atol=1e-12
        end
        # Three transverse rigid motions must carry no shear resultants.
        for component=1:3
            rigid=zeros(24)
            for i=1:4
                j=6(i-1)
                rigid[j+3]=component==1 ? 1. : component==2 ? xy[i,2] : -xy[i,1]
                rigid[j+4]=component==2 ? 1. : 0.
                rigid[j+5]=component==3 ? 1. : 0.
            end
            @test norm(F.quad4_macneal_mean_shear_resultant(xy,rigid,D,C,h;Cm=A)) < 1e-12
        end
        @test F.quad4_macneal_mean_shear_resultant(xy,3u,D,C,h;Cm=A) ≈ 3q
        @test F.quad4_macneal_mean_shear_resultant(xy,u,Matrix{Any}(D),Matrix{Any}(C),h;Cm=Matrix{Any}(A)) ≈ q
        # Changing physical transverse compliance changes recovered force.
        derivative=ForwardDiff.derivative(s->F.quad4_macneal_mean_shear_resultant(xy,u,D,s*C,h;Cm=A)[1],1.)
        @test isfinite(derivative) && abs(derivative)>1e-8
        # Derivatives may live only in extension/coupling laws; the other
        # constitutive matrices then remain ordinary Float64 arrays.
        B=0.01A
        for law in (:membrane,:coupling)
            response=s->F.quad4_macneal_mean_shear_resultant(xy,u,D,C,h;
                Cm=law===:membrane ? s*A : A,
                Bmb=law===:coupling ? s*B : B)[1]
            exact=ForwardDiff.derivative(response,1.)
            step=1e-5
            check=(response(1+step)-response(1-step))/(2step)
            @test isfinite(exact)
            @test exact ≈ check rtol=1e-5 atol=1e-9
        end
        # Reusing a workspace after a loaded cell must not leak its forces
        # into a following zero-shear or zero-thickness cell.
        workspace=F.create_macneal_shear_workspace()
        F.quad4_macneal_mean_shear_resultant(xy,u,D,C,h;Cm=A,msws=workspace)
        @test F.quad4_macneal_mean_shear_resultant(xy,u,D,zero(C),h;Cm=A,msws=workspace)==zeros(2)
        F.quad4_macneal_mean_shear_resultant(xy,u,D,C,h;Cm=A,msws=workspace)
        @test F.quad4_macneal_mean_shear_resultant(xy,u,D,C,0.;Cm=A,msws=workspace)==zeros(2)
        if F.quad4_is_axis_aligned_rectangle(xy)
            @test F.quad4_macneal_center_shear_resultant(xy,u,D,C,h;Cm=A) == q
        else
            @test_throws ArgumentError F.quad4_macneal_center_shear_resultant(xy,u,D,C,h;Cm=A)
        end
    end
end

@testset "Planar laminate recovery selects the physical shear law" begin
    F=OpenJFEM.FEM;S=OpenJFEM.Solver
    mktempdir() do dir
        deck=joinpath(dir,"laminate.bdf")
        write(deck,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,-1.,-0.5,0.
GRID,2,,1.,-0.5,0.
GRID,3,,0.7,0.5,0.
GRID,4,,-0.7,0.5,0.
CQUAD4,1,10,1,2,3,4
MAT8,1,1.0E7,7.0E6,0.25,3.0E6,2.0E6,1.3E6,1000.
PCOMP,10
+,1,0.05,0.,YES,1,0.05,90.,YES
+,1,0.05,90.,YES,1,0.05,0.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(deck)
        xy=[-1. -0.5;1. -0.5;0.7 0.5;-0.7 0.5]
        X=hcat(xy,zeros(4));ids=Dict(i=>i for i=1:4)
        R=[Matrix{Float64}(I,3,3) for _=1:4]
        normals=S.compute_snorm_normals(model,ids,X)
        u=1e-3*sin.(collect(1.:24.))
        output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[])
            for key in ("forces","forces_bilin","stresses","strains"))
        S.recover_shell_stresses!(model,ids,X,R,u,normals,Dict{Int,Float64}(),output)
        @test length(output["forces"]["quad4"]) == 1
        @test output["recovery_diagnostics"]["area_mean_transverse_shear_eids"] == [1]
        property=model["PSHELLs"]["10"]
        expected=F.quad4_macneal_mean_shear_resultant(xy,u,property["Cb"],property["Cs"],property["T"];
            Cm=property["Cm"],Bmb=property["Bmb"])
        row=only(output["forces"]["quad4"])
        @test [row["qx"],row["qy"]] ≈ expected rtol=1e-10
        @test all(isfinite(row[k]) for k in ("fx","fy","fxy","mx","my","mxy","qx","qy"))
        function has_mean_recovery()
            fields=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[])
                for key in ("forces","forces_bilin","stresses","strains"))
            S.recover_shell_stresses!(model,ids,X,R,u,normals,Dict{Int,Float64}(),fields)
            !isempty(get(get(fields,"recovery_diagnostics",Dict()),"area_mean_transverse_shear_eids",Int[]))
        end
        # Alternate assembly operators must keep their existing recovery
        # until equivalence with the physical mean operator is established.
        switches=["JFEM_Q4_MACNEAL_RIGID_SHEAR_FORCE"=>"true",
                  "JFEM_Q4_MACNEAL_ASPECT_MAX"=>"1.0"]
        append!(switches,[key=>"0.5" for key in (
            "JFEM_Q4_MACNEAL_BENDING_SCALE","JFEM_Q4_MACNEAL_CURVED_BENDING_SCALE",
            "JFEM_Q4_MACNEAL_BENDING_ISOLATED_SCALE","JFEM_Q4_STATIC_COMPONENT_CM_SCALE",
            "JFEM_Q4_STATIC_COMPONENT_CM11_SCALE","JFEM_Q4_STATIC_COMPONENT_CM22_SCALE",
            "JFEM_Q4_STATIC_COMPONENT_CM66_SCALE","JFEM_Q4_STATIC_COMPONENT_CB_SCALE",
            "JFEM_Q4_STATIC_COMPONENT_CS_SCALE","JFEM_Q4_STATIC_COMPONENT_BMB_SCALE")])
        for setting in switches
            withenv(setting) do
                @test !has_mean_recovery()
            end
        end
        for sol in (103,106)
            model["SOL"]=sol
            @test !has_mean_recovery()
        end
    end
end
