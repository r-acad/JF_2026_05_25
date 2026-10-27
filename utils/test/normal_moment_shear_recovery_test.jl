using Test
module NormalShearApiWorkTests
using Test, OpenJFEM, LinearAlgebra, StaticArrays, ForwardDiff, JSON
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM
const CASES=Any[]

output()=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in ("forces","forces_bilin","stresses","strains"))
function recover(c,u;compact=false)
    result=output()
    if compact
        fields=Dict{Int,Any}()
        S.recover_shell_stresses!(c.model,c.ids,c.X,c.R,u,c.normals,Dict{Int,Float64}(),result;static_fields=fields)
        result["compact_fields"]=fields
    else
        S.recover_shell_stresses!(c.model,c.ids,c.X,c.R,u,c.normals,Dict{Int,Float64}(),result)
    end
    result
end

function make_cases(dir)
    mkpath(dir)
    az=.37;ax=-.29
    rotation=[cos(az) -sin(az) 0.;sin(az) cos(az) 0.;0. 0. 1.]*[1. 0. 0.;0. cos(ax) -sin(ax);0. sin(ax) cos(ax)]
    cdrot=[cos(.23) -sin(.23) 0.;sin(.23) cos(.23) 0.;0. 0. 1.]
    for material in (:isotropic,:symmetric,:coupled), shape in (:skew,:taper), frame in (:theta,:mcid,:rotated_cd), sol in (101,105)
        name=join((material,shape,frame,sol),"_")
        xy=shape===:skew ? [-1. -.5;1. -.5;1.35 .5;-.65 .5] : [-1. -.5;1. -.5;.72 .5;-.86 .5]
        X=hcat(xy,.16*[1.,-1.,1.,-1.])
        G=frame===:rotated_cd ? rotation : Matrix{Float64}(I,3,3)
        X=X*G';cd=frame===:rotated_cd ? 50 : 0
        text="SOL $sol\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,0.\n"
        if cd!=0
            e3=G*cdrot[:,3];e1=G*cdrot[:,1]
            text*="CORD2R,50,0,0.,0.,0.,"*join(e3,",")*"\n+,"*join(e1,",")*"\n"
        end
        if frame===:mcid
            # A physical material axis independent of the element edge.
            text*="CORD2R,60,0,0.,0.,0.,0.,0.,1.\n+,.8,.6,0.\n"
        end
        for i=1:4
            text*="GRID,$i,,"*join(X[i,:],",")*",$cd\n"
            normal=normalize(G*[.035*(-1)^i,.045*(-1)^(i÷2),1.])
            text*="SNORM,$i,0,"*join(normal,",")*"\n"
        end
        angle=frame===:mcid ? "60" : "17."
        offset=frame===:rotated_cd ? ".013" : "0."
        text*="CQUAD4,1,10,1,2,3,4,$angle,$offset\n"
        if material===:isotropic
            text*="MAT1,1,7.0E7,2.6E7,.28,2700.\nPSHELL,10,1,.08,1,1.,1,.71\n"
        else
            text*="MAT8,1,1.35E8,8.5E6,.27,4.8E6,5.1E6,3.2E6,1600.\nPCOMP,10\n"
            text*=material===:symmetric ? "+,1,.02,0.,YES,1,.02,53.,YES\n+,1,.02,53.,YES,1,.02,0.,YES\n" : "+,1,.027,0.,YES,1,.053,53.,YES\n"
        end
        text*="ENDDATA\n"
        path=joinpath(dir,name*".bdf");write(path,text)
        model=OpenJFEM.bdf_to_model(path)
        captured=S.analytic_shell_contexts(model;shear_center_only=false)
        K,ids,coords,ndof,R,_,_,normals,_=captured.assembly
        ctx=only(values(captured.contexts))
        points=[SVector{3}(coords[i,:]) for i=1:4]
        axes=S.shell_element_frame_quad4(points...,S.q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC"))
        center=sum(points)/4;localxy=[dot(p-center,v) for p in points,v in axes[1:2]]
        pq=S.snorm_element_pq(axes...,[ids[i] for i=1:4],normals)
        P=F.quad4_physical_displacement_map(localxy,coords,pq)
        # ctx.transform contains the exact outer material-reference/CD maps;
        # P is the previously established physical-to-projected normal map.
        total=P*ctx.transform
        area=abs(sum(localxy[i,1]*localxy[mod1(i+1,4),2]-localxy[mod1(i+1,4),1]*localxy[i,2] for i=1:4))/2
        push!(CASES,(name=name,model=model,ids=ids,X=coords,R=R,normals=normals,K=Matrix(K),ctx=ctx,total=total,xy=localxy,pq=pq,area=area,material=material))
    end
end

function patterns(c)
    general=1e-3*sin.(collect(1.:24.))
    projected=zeros(24);projected[5:6:24].=1e-3
    [general,c.total\projected,zeros(24)]
end

function physical_checks!()
    @testset "Normal shear is the assembled elastic virtual work" begin
        for c in CASES, (i,u) in enumerate(patterns(c))
            out=recover(c,u);row=only(out["forces"]["quad4"]);q=[row["qx"],row["qy"]]
            @test length(out["forces_bilin"]["quad4"])==5
            @test all([r["qx"],r["qy"]]==q for r in out["forces_bilin"]["quad4"])
            @test all(isfinite,q)
            for gamma in ([1.,0.],[0.,1.],[.4,-.7])
                v=zeros(24);v[4:6:24].=-gamma[2];v[5:6:24].=gamma[1]
                physical=c.total\v
                # This uses the complete actual elastic assembly, not the
                # recovery primitive or a fitted transverse-shear matrix.
                expected=dot(physical,c.K*u)
                @test isapprox(c.area*dot(gamma,q),expected;rtol=3e-9,atol=2e-7)
            end
            if i==3
                @test q==zeros(2)
            end
        end
    end
    @testset "Fixed-geometry Q derivative and exact mixed work" begin
        xy=[-1. -.5;1. -.5;.72 .5;-.86 .5]
        xyz=hcat(xy,.16*[1.,-1.,1.,-1.]);pq=[.1 .02 1.;-.04 .06 1.;.03 -.05 1.;-.02 -.08 1.]
        P=F.quad4_physical_displacement_map(xy,xyz,pq)
        A=[30. 4. 1.;4. 12. -.5;1. -.5 5.];B=.017A
        D=[.7 .08 .03;.08 .3 -.02;.03 -.02 .15];C=[9. 1.2;1.2 4.];h=.2
        u=sin.(collect(1.:24.));v=cos.(collect(1.:24.));area=2.56
        area=abs(sum(xy[i,1]*xy[mod1(i+1,4),2]-xy[mod1(i+1,4),1]*xy[i,2] for i=1:4))/2
        response=(q,a,b,d,c,t)->F.quad4_macneal_mean_shear_resultant(xy,P*q,d,c,t;Cm=a,Bmb=b)
        jac=ForwardDiff.jacobian(q->response(q,A,B,D,C,h),u)
        K=zeros(24,24);F.add_quad4_macneal_shear_rbf!(K,xy,D,C,h;Cm=A,Bmb=B)
        V=zeros(24,2);V[5:6:24,1].=1.;V[4:6:24,2].=-1.
        @test jac≈V'*K*P/area rtol=3e-11 atol=1e-12
        @test jac*v≈(response(u+1e-5v,A,B,D,C,h)-response(u-1e-5v,A,B,D,C,h))/(2e-5) rtol=2e-8 atol=1e-9
        for which in (:A,:B,:D,:Cs,:thickness)
            f=t->response(u,which===:A ? t*A : A,which===:B ? t*B : B,which===:D ? t*D : D,which===:Cs ? t*C : C,which===:thickness ? t*h : h)
            derivative=ForwardDiff.jacobian(t->f(t[1]),[1.])[:,1]
            fd=(f(1+1e-5)-f(1-1e-5))/(2e-5)
            @test all(isfinite,derivative)
            @test derivative≈fd rtol=3e-6 atol=1e-8
        end
    end
    @testset "New Q scope preserves alternative contracts" begin
        c=first(CASES);m=c.model
        @test S._quad4_normal_moment_mean_shear_enabled(m,c.pq,nothing)
        @test !S._quad4_normal_moment_mean_shear_enabled(m,nothing,nothing)
        @test !S._quad4_normal_moment_mean_shear_enabled(m,c.pq,[1.,0.,0.])
        for sol in (103,106)
            mm=copy(m);mm["SOL"]=sol
            @test !S._quad4_normal_moment_mean_shear_enabled(mm,c.pq,nothing)
        end
        mm=deepcopy(m);mm["backend"]="tacs_formulation"
        @test !S._quad4_normal_moment_mean_shear_enabled(mm,c.pq,nothing)
        mm=deepcopy(m);only(values(mm["CSHELLs"]))["TYPE"]="CQUADR"
        @test !S._quad4_normal_moment_mean_shear_enabled(mm,c.pq,nothing)
        for option in ("JFEM_SNORM_DIRECTOR"=>"true","JFEM_Q4_SNORM_TRANSFORM_ONLY"=>"true",
            "JFEM_Q4_WARP_TRANSFORM"=>"false","JFEM_Q4_KERNEL_STATIC"=>"default",
            "JFEM_Q4_MARGUERRE_COUPLING"=>"true","JFEM_Q4_MACNEAL_RIGID_SHEAR_FORCE"=>"true",
            "JFEM_Q4_STATIC_COMPONENT_CS_SCALE"=>".9","JFEM_Q4_MACNEAL_ASPECT_MAX"=>"2.")
            withenv(option) do
                @test !S._quad4_normal_moment_mean_shear_enabled(m,c.pq,nothing)
            end
        end
    end
end

end

@testset "Normal-moment Q recovery uses the actual elastic shear work" begin
    mktempdir() do dir
        NormalShearApiWorkTests.make_cases(dir)
        NormalShearApiWorkTests.physical_checks!()
    end
end
