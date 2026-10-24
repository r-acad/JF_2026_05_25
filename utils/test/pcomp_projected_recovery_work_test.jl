using Test

module PcompProjectedRecoveryWorkFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver; const F=OpenJFEM.FEM; const AD=S.ForwardDiff

function checks()
    A=[30. 4. 1.;4. 12. -.5;1. -.5 5.]
    D=[.7 .08 .03;.08 .3 -.02;.03 -.02 .15]
    Cs=[9. 1.2;1.2 4.];h=.2
    shapes=([-1. -.5;1. -.5;1. .5;-1. .5],
            [-1. -.5;1. -.5;1.3 .5;-.7 .5],
            [-1. -.5;1. -.5;.7 .5;-.8 .5])
    for X in shapes, warped in (false,true), normal in (false,true)
        xyz=hcat(X,warped ? [.003,-.003,.003,-.003] : zeros(4))
        pq=normal ? [.013 -.008;.009 .006;-.007 .008;-.015 -.006] : nothing
        W=F.quad4_finite_warp_displacement_map(X,xyz)
        P=W===nothing ? Matrix{Float64}(I,24,24) : copy(W)
        if pq!==nothing
            rpq=F.quad4_snorm_relative_to_finite_warp_pq(pq,W)
            P=F.quad4_snorm_normal_moment_displacement_map(X,rpq)*P
        end
        u=.01sin.(collect(1.:24.))
        K=F.stiffness_quad4_matrices(X,A,D,Cs,h,150.;kernel_mode="macneal",
            membrane_incomp=false,membrane_shear_center_row=true,
            kernel_planar=true,k6rot=0.,coords_3d=xyz,snorm_pq=pq)
        fields=F.stress_strain_quad4(X,u,150.,.3,h,h;Cm_override=A,
            Cb_override=D,Cs_override=Cs,compatible_center=true,
            coords_3d=xyz,snorm_pq=pq,recover_corners=true)
        area=abs(sum(X[i,1]*X[mod1(i+1,4),2]-X[i,2]*X[mod1(i+1,4),1] for i=1:4))/2
        V=zeros(24,5)
        for i=1:4
            j=6(i-1);x,y=X[i,:]
            V[j+1,1]=x;V[j+2,2]=y
            V[j+1,3]=y/2;V[j+2,3]=x/2
            V[j+5,4]=1;V[j+4,5]=-1
        end
        work=(P\V)'*K*u/area
        @test isapprox(fields[1],work[1:3];rtol=2e-11,atol=1e-12)
        @test isapprox(fields[3],work[4:5];rtol=2e-11,atol=1e-12)
        @test size(fields[8])==(4,3)
        # Unit compatible strains reproduce the constitutive patch exactly.
        for axis=1:3
            v=P\V[:,axis]
            p=F.stress_strain_quad4(X,v,150.,.3,h,h;Cm_override=A,
                Cb_override=D,Cs_override=Cs,compatible_center=true,
                coords_3d=xyz,snorm_pq=pq)
            @test isapprox(p[1],A[:,axis];rtol=2e-12,atol=1e-12)
        end
        # One constitutive tangent and one arbitrary physical-displacement
        # tangent compare AD arithmetic to independent centered differences.
        response(t)=vcat(F.stress_strain_quad4(X,u.+t.*cos.(1.:24.),150.,.3,h,h;
            Cm_override=A*(1+.2t),Cb_override=D*(1+.3t),Cs_override=Cs*(1+.4t),
            compatible_center=true,coords_3d=xyz,snorm_pq=pq)[[1,2,3]]...)
        dual=response(AD.Dual(0.,1.));derivative=first.(AD.partials.(dual))
        step=1e-6;fd=(response(step)-response(-step))/(2step)
        @test isapprox(derivative,fd;rtol=1e-8,atol=1e-10)
    end
    @test_throws ArgumentError F.stress_strain_quad4(shapes[1],zeros(24),150.,.3,h,h;
        Cm_override=A,Cb_override=D,Cs_override=Cs,Bmb_override=.01A,compatible_center=true)
    mktempdir() do dir
        path=joinpath(dir,"folded_symmetric_laminate.bdf")
        function model_at(E)
            write(path,"""
SOL 101
CEND
BEGIN BULK
PARAM,SNORM,20.
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.1,1.,.002
GRID,4,,.1,1.,-.002
GRID,5,,2.,0.,.02
GRID,6,,2.1,1.,.022
CQUAD4,1,10,1,2,3,4,17.
CQUAD4,2,10,2,5,6,3,17.
MAT1,1,$E,,.3
PCOMP,10
+,1,.005,0.,YES,1,.01,0.,YES
+,1,.005,0.,YES
ENDDATA
""")
            OpenJFEM.bdf_to_model(path)
        end
        model=model_at(70000.);capture=S.AnalyticShellCapture(model)
        assembled=S.assemble_stiffness(model;sol101_context=true,shell_capture=capture)
        K,ids,X,ndof,R,_,_,normals=assembled[1:8]
        u=.001sin.(collect(1.:ndof))
        output()=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in
            ("forces","forces_bilin","stresses","strains"))
        function recover(m;compact=false)
            rows=output();fields=Dict{Int,NTuple{3,Float64}}()
            S.recover_shell_stresses!(m,ids,X,R,u,normals,Dict{Int,Float64}(),rows;
                static_fields=compact ? fields : nothing,
                static_fields_capture=compact ? nothing : fields)
            rows,fields
        end
        base,fields=recover(model);_,compact=recover(model;compact=true)
        @test fields==compact
        @test sort(base["recovery_diagnostics"]["area_mean_transverse_shear_eids"])==[1,2]
        step=.7;minus,_=recover(model_at(70000.0 - step));plus,_=recover(model_at(70000.0 + step))
        stress(rows,eid)=[only(filter(r->r["eid"]==eid,rows["stresses"]["quad4"]))["z2"][k]
            for k in ("normal_x","normal_y","shear_xy")]
        for (eid,ctx) in capture.contexts
            @test !only(ctx.calls).kwargs.membrane_incomp
            @test only(ctx.calls).kwargs.membrane_shear_center_row
            t=S.analytic_shell_stress_tangent(ctx,(materials=Dict(1=>(E=1.,)),),u,ids,X,R,normals)
            @test isapprox(t.features,stress(base,eid);rtol=2e-12,atol=1e-12)
            fd=(stress(plus,eid)-stress(minus,eid))/(2step)
            @test isapprox(t.dfeatures,fd;rtol=2e-8,atol=1e-12)
            @test isapprox(t.dfeatures,t.features/70000.;rtol=2e-12,atol=1e-12)
        end
        # A real orthotropic property also exercises the separate legacy
        # membrane/bending frame policies. Recovery must integrate back to
        # the same physical resultants, without changing that elastic law.
        model_at(70000.)
        text=replace(read(path,String),"MAT1,1,70000.0,,.3"=>"MAT8,1,70000.,23000.,.3,12000.,9000.,7000.")
        write(path,text);aniso=OpenJFEM.bdf_to_model(path)
        @test_throws ArgumentError S.analytic_shell_constitutive(aniso,10)
        @test_throws ArgumentError S.analytic_shell_stress_tangent(
            merge(capture.contexts[1],(model=aniso,)),NamedTuple(),u,ids,X,R,normals)
        ar,af=recover(aniso)
        for row in ar["forces"]["quad4"]
            eid=row["eid"];sr=only(filter(r->r["eid"]==eid,ar["stresses"]["quad4"]))
            s1=[sr["z1"][k] for k in ("normal_x","normal_y","shear_xy")]
            s2=[sr["z2"][k] for k in ("normal_x","normal_y","shear_xy")]
            @test isapprox(.02*(s1+s2)/2,[row[k] for k in ("fx","fy","fxy")];rtol=2e-11,atol=1e-11)
            @test isapprox(-(.02^3/12)*(s2-s1)/.015,[row[k] for k in ("mx","my","mxy")];rtol=2e-11,atol=1e-11)
        end
    end
end
end

@testset "Projected laminate resultants agree with elastic virtual work" begin
    # This fixture checks the optional selective-center operator. Production
    # uses the complete membrane; keep its legacy alternative explicitly tested.
    withenv("JFEM_SOL105_PCOMP_MEMBRANE_SELC"=>"true") do
        PcompProjectedRecoveryWorkFixture.checks()
    end
end
