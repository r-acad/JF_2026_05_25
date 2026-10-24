using Test
module TriangleMeanShearFixture
using Test, LinearAlgebra, StaticArrays, OpenJFEM
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM
blank()=Dict{String,Any}(k=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
function recovered(model,ids,X,Rs,u,normals;kwargs...)
    rows=blank()
    S.recover_shell_stresses!(model,ids,X,Rs,u,normals,Dict{Int,Float64}(),rows;kwargs...)
    row=only(rows["forces"]["tria3"])
    return [row["qx"],row["qy"]],rows
end
function model_file(dir,X,R,mcid,offset)
    lines=["SOL 101","CEND","SPC=1","LOAD=1","BEGIN BULK","PARAM,SNORM,0.","PARAM,K6ROT,100.",
        "MAT8,1,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.",
        "PCOMP,1,,,,,,,","+,1,.001,0.,YES,1,.003,70.,YES"]
    for n in 1:3;push!(lines,"GRID,$n,,"*join(X[n,:],','));end
    z=R*[0.,0.,1.];x=R*[cosd(23.),sind(23.),0.]
    append!(lines,["CORD2R,10,0,0.,0.,0.,"*join(z,','),"+,"*join(x,','),
        "CTRIA3,1,1,1,2,3,"*(mcid ? "10" : "23.")*",$offset",
        "SPC1,1,123456,1","FORCE,1,2,0,1.,0.,0.,1.","ENDDATA"])
    path=joinpath(dir,"mean_shear.bdf");write(path,join(lines,'\n')*"\n")
    OpenJFEM.bdf_to_model(path)
end
function checks()
    axis=normalize([1.,2.,3.]);a=.63
    J=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
    rotation=cos(a)*I+(1-cos(a))*axis*axis'+sin(a)*J
    mktempdir() do dir
        for X0 in ([0. 0. 0.;.8 0. 0.;.1 .6 0.],[0. 0. 0.;1.3 0. 0.;1.8 .4 0.]),
            R in (Matrix{Float64}(I,3,3),rotation), mcid in (false,true),offset in (0.,.003,-.002)
            X=X0*R';model=model_file(dir,X,R,mcid,offset);original=deepcopy(model["PSHELLs"])
            capture=Dict{Int,Any}()
            callback=(eid,pid,dofs,K)->(capture[eid]=(dofs=copy(dofs),K=copy(K)))
            _,ids,X,ndof,Rs,_,mapping,normals,_=S.assemble_stiffness(model;element_capture=callback)
            # A nontrivial displacement exercises membrane, bending, shear,
            # coupling and the signed reference-surface offset simultaneously.
            localu=[.0003sin(.7i)+.0001cos(1.3i) for i=1:18]
            u=zeros(18)
            for n=1:3
                theta=localu[6n-2:6n]
                u[6n-5:6n-3]=R*(localu[6n-5:6n-3]-offset*cross(theta,[0.,0.,1.]))
                u[6n-2:6n]=R*theta
            end
            q,rows=recovered(model,ids,X,Rs,u,normals)
            Ke=capture[1].K;f=Ke*u;normal=R[:,3]
            fw=[dot(normal,f[6n-5:6n-3]) for n=1:3]
            xy=X0[:,1:2];centered=xy.-sum(xy;dims=1)/3
            area=abs(det(hcat(xy[2,:]-xy[1,:],xy[3,:]-xy[1,:])))/2
            expected=transpose(centered)*fw/area
            bound=256eps(Float64)*norm(Ke)*norm(u)*max(norm(centered)/area,1.)
            @test norm(q-expected)<=bound
            @test abs(sum(fw))<=256eps(Float64)*norm(Ke)*norm(u)
            for gamma in ([1.,0.],[0.,1.],[.3,-.7])
                du=zeros(18)
                for n=1:3;du[6n-5:6n-3]=normal*dot(centered[n,:],gamma);end
                @test abs(dot(du,f)-area*dot(gamma,q))<=bound*area*max(norm(gamma),1.)
            end
            @test rows["recovery_diagnostics"]["area_mean_tria3_transverse_shear_eids"]==[1]
            @test occursin("Area-mean",rows["recovery_diagnostics"]["tria3_area_mean_shear_definition"])
            @test !haskey(rows["recovery_diagnostics"],"legacy_tria3_transverse_shear_eids")
            @test model["PSHELLs"]==original
            full=Dict{Int,Any}();compact=Dict{Int,Any}()
            recovered(model,ids,X,Rs,u,normals;static_fields_capture=full)
            S.recover_shell_stresses!(model,ids,X,Rs,u,normals,Dict{Int,Float64}(),blank();static_fields=compact)
            @test full==compact
            # SOL103/105 use the same ordinary elastic recovery at saved u.
            for sol in (103,105)
                m=copy(model);m["SOL"]=sol
                q2,r2=recovered(m,ids,X,Rs,u,normals)
                @test q2==q
            end
            if X0[2,1]==.8 && R==Matrix{Float64}(I,3,3) && !mcid && offset==0.
                guard_checks(model,ids,X,Rs,u,normals)
            end
        end
    end
end
function guard_checks(model,ids,X,Rs,u,normals)
    m=copy(model);m["SOL"]=106
    _,rows=recovered(m,ids,X,Rs,u,normals)
    @test rows["recovery_diagnostics"]["legacy_tria3_transverse_shear_eids"]==[1]
    m=copy(model);m["backend"]="tacs_formulation"
    _,rows=recovered(m,ids,X,Rs,u,normals)
    @test !haskey(rows["recovery_diagnostics"],"area_mean_tria3_transverse_shear_eids")
    for settings in (("JFEM_TRIA3_PLATE_KERNEL"=>"dkt",),("JFEM_SNORM_DIRECTOR"=>"true",))
        withenv(settings...) do
            _,rows=recovered(model,ids,X,Rs,u,normals)
            @test rows["recovery_diagnostics"]["legacy_tria3_transverse_shear_eids"]==[1]
        end
    end
    tilted=Dict(i=>SVector{3}(normalize([.01,0.,1.])) for i=1:3)
    _,rows=recovered(model,ids,X,Rs,u,tilted)
    @test rows["recovery_diagnostics"]["legacy_tria3_transverse_shear_eids"]==[1]
    withenv("JFEM_TRIA3_SNORM_NORMAL_MOMENT"=>"false") do
        _,rows=recovered(model,ids,X,Rs,u,tilted)
        @test rows["recovery_diagnostics"]["legacy_tria3_transverse_shear_eids"]==[1]
    end
    m=copy(model);m["SOL"]=103
    withenv("JFEM_Q4_PCOMP_AXIS_MODE_EIG"=>"global_x") do
        _,rows=recovered(m,ids,X,Rs,u,normals)
        @test rows["recovery_diagnostics"]["legacy_tria3_transverse_shear_eids"]==[1]
    end
end
function primitive_checks()
    xy=[-.2 -.3;.7 -.3;.1 .5];h=.004;E=72e9;nu=.29;G=E/(2(1+nu))
    A=E*h/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    B=.07h*A;D=h^2/12*A;Cs=5/6*G*h*[1. .08;.08 .8]
    u=[.0003sin(.7i)+.0001cos(1.3i) for i=1:18]
    K=F.stiffness_tria3_matrices(xy,A,D,Cs,h,G;k6rot=0.,Bmb=B)
    q=F.tria3_area_mean_shear_resultant(xy,u,K)
    @test q==F.tria3_area_mean_shear_resultant(xy,u,A,D,Cs,h,G;Bmb=B)
    for k6 in (1.,100.,1.e5)
        Kd=F.stiffness_tria3_matrices(xy,A,D,Cs,h,G;k6rot=k6,Bmb=B)
        @test Kd[3:6:18,:]==K[3:6:18,:]
        @test F.tria3_area_mean_shear_resultant(xy,u,Kd)==q
    end
    for i=1:6
        rigid=zeros(18)
        for n=1:3
            if i<=3;rigid[6n-6+i]=1.
            else
                theta=zeros(3);theta[i-3]=1.
                rigid[6n-5:6n-3]=cross(theta,[xy[n,1],xy[n,2],0.])
                rigid[6n-2:6n]=theta
            end
        end
        bound=256eps(Float64)*norm(K)*norm(rigid)*norm(xy)/.36
        @test norm(F.tria3_area_mean_shear_resultant(xy,rigid,K))<=bound
    end
    membrane=zeros(18)
    for n=1:3;membrane[6n-5]=.001xy[n,1];membrane[6n-4]=-.002xy[n,2];end
    @test norm(F.tria3_area_mean_shear_resultant(xy,membrane,K))<=256eps(Float64)*norm(K)*norm(membrane)
    for shift in ([2.,-3.],[1.e5,-2.e5])
        q2=F.tria3_area_mean_shear_resultant(xy.+transpose(shift),u,K)
        @test norm(q2-q)<=256eps(Float64)*norm(K)*norm(u)*max(norm(shift),1.)/.36
    end
    for scale in (.001,1000.)
        us=copy(u);for n=1:3;us[6n-5:6n-3]*=scale;end
        qs=F.tria3_area_mean_shear_resultant(xy*scale,us,A*scale,D*scale^3,Cs*scale,h*scale,G;Bmb=B*scale^2)
        @test isapprox(qs,q*scale;rtol=2e-11,atol=1e-10*scale)
    end
    # Without residual bending compliance, constant assumed shear has the
    # independent constitutive result Cs*gamma.
    withenv("JFEM_TRIA3_MITC3_ZB"=>"false") do
        gamma=[.003,-.002];ua=zeros(18)
        for n=1:3;ua[6n-3]=dot(xy[n,:],gamma);end
        qa=F.tria3_area_mean_shear_resultant(xy,ua,A,D,Cs,h,G;Bmb=B)
        @test isapprox(qa,Cs*gamma;rtol=3e-12)
    end
    @test_throws ArgumentError F.tria3_area_mean_shear_resultant(zeros(3,2),u,K)
    @test_throws DimensionMismatch F.tria3_area_mean_shear_resultant(zeros(4,2),u,K)
end
end
@testset "Triangle work-conjugate area-mean shear" begin
    TriangleMeanShearFixture.primitive_checks()
    TriangleMeanShearFixture.checks()
end
