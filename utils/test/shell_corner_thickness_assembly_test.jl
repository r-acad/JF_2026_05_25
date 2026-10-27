using Test
module ShellCornerThicknessAssemblyFixture
using Test,LinearAlgebra,OpenJFEM
const S=OpenJFEM.Solver;const F=OpenJFEM.FEM
function fixture(path;ti=[.0018,.0027,.0045,.0033],h=.003,rotation=Matrix{Float64}(I,3,3),cyclic=0,offset=0.,warp=0.)
    x=[-.25 -.15 warp;.25 -.15 -warp;.25 .15 warp;-.25 .15 -warp]*rotation'
    order=circshift(collect(1:4),-cyclic)
    lines=["SOL 105","CEND","SUBCASE 1"," SPC=1"," LOAD=1",
        "SUBCASE 2"," METHOD=2"," SPC=1"," STATSUB(BUCKLING)=1","BEGIN BULK",
        "PARAM,SNORM,0.","PARAM,K6ROT,1.","PARAM,COUPMASS,1",
        "MAT1,1,7.E10,,.33,2700.","PSHELL,1,1,$h,1,,1,,.8"]
    for i in 1:4;push!(lines,"GRID,$i,,$(x[i,1]),$(x[i,2]),$(x[i,3])");end
    push!(lines,"CQUAD4,1,1,$(join(order,',')),0.,$offset")
    ti===nothing || push!(lines,"+,,0,$(join(ti[order],','))")
    append!(lines,["SPC1,1,123456,1,4","FORCE,1,2,0,1.,-1.,0.,0.","EIGRL,2,0.,,2","ENDDATA"])
    write(path,join(lines,'\n')*"\n");OpenJFEM.bdf_to_model(path)
end
function assemble(model)
    captures=Dict{Int,Any}()
    a=S.assemble_stiffness(model;snorm_angle_override=0.,sol105_context=true,
        element_capture=(eid,pid,dofs,ke)->(captures[eid]=(dofs=copy(dofs),K=copy(ke))))
    K,ids,X,nd,R,_,mapping,normals,_=a
    M=S.assemble_modal_mass(model,ids,X,R,nd)
    (K=Matrix(K),M=Matrix(M),ids=ids,X=X,nd=nd,R=R,mapping=mapping,normals=normals,capture=captures[1])
end
@testset "Corner-thickness parser and production operators" begin
mktempdir() do dir
    model=fixture(joinpath(dir,"variable.bdf"));a=assemble(model)
    h=.003;E=70e9;nu=.33;G=E/(2(1+nu));C=E/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    xy=[-.25 -.15;.25 -.15;.25 .15;-.25 .15];ti=[.0018,.0027,.0045,.0033]
    p=F.quad4_variable_thickness_packet(xy,h*C,h^3*C/12,Matrix{Float64}(I,2,2)*G*h*5/6,h,E,ti;k6rot=1.)
    @test a.K≈p.K rtol=4e-12
    @test a.capture.K≈p.K rtol=4e-12
    @test a.M≈F.quad4_variable_thickness_mass(xy,ti,2700.;nsm=.8) rtol=4e-12
    u=sin.(collect(1.:24.))*.001
    @test .5dot(u,a.capture.K*u)≈.5dot(u,p.K*u) rtol=4e-12
    up=zeros(24)
    for i in 1:4;up[6i-5]=-.001xy[i,1]+.0003xy[i,2];up[6i-4]=.0002xy[i,1];end
    kg=S.assemble_geometric_stiffness(model,a.ids,a.X,a.R,a.nd,up,a.normals,a.mapping;
        snorm_angle_override=0.,buckling_subcase=2,static_load_id=1)
    expected,_=F.quad4_variable_thickness_geometric(xy,up,h*C,h,ti)
    @test Matrix(kg)≈expected rtol=5e-12
    for shift in 1:3
        ac=assemble(fixture(joinpath(dir,"cyclic$shift.bdf");cyclic=shift))
        @test ac.K≈a.K rtol=5e-12
        @test ac.M≈a.M rtol=5e-12
    end
    q=[.3,-.4,.5];q/=norm(q);ang=.71;Q=[0. -q[3] q[2];q[3] 0. -q[1];-q[2] q[1] 0.]
    R=Matrix{Float64}(I,3,3)+sin(ang)*Q+(1-cos(ang))*(Q*Q)
    ar=assemble(fixture(joinpath(dir,"rotation.bdf");rotation=R));T=kron(Matrix{Float64}(I,8,8),R)
    @test ar.K≈T*a.K*T' rtol=5e-12
    @test ar.M≈T*a.M*T' rtol=5e-12
    # Warp is a single work-conjugate map. Rigid motions, changes of basic
    # coordinates and cyclic connectivity must preserve the complete operator.
    for warp in (-.006,.006),offset in (0.,.002)
        mw=fixture(joinpath(dir,"warped.bdf");warp=warp,offset=offset);aw=assemble(mw)
        @test aw.K≈aw.K' rtol=4e-12
        for j in 1:6
            ur=zeros(24);tr=zeros(3);omega=zeros(3)
            j<=3 ? (tr[j]=1) : (omega[j-3]=1)
            for i in 1:4
                ur[6i-5:6i-3]=tr+cross(omega,aw.X[i,:]);ur[6i-2:6i]=omega
            end
            @test norm(aw.K*ur)<=3e-12*norm(aw.K)*max(norm(ur),1)
        end
        mr=fixture(joinpath(dir,"warped_rot.bdf");warp=warp,offset=offset,rotation=R);arw=assemble(mr)
        @test arw.K≈T*aw.K*T' rtol=5e-12
        @test arw.M≈T*aw.M*T' rtol=5e-12
        gw=Matrix(S.assemble_geometric_stiffness(mw,aw.ids,aw.X,aw.R,aw.nd,u,aw.normals,aw.mapping;snorm_angle_override=0.))
        gr=Matrix(S.assemble_geometric_stiffness(mr,arw.ids,arw.X,arw.R,arw.nd,T*u,arw.normals,arw.mapping;snorm_angle_override=0.))
        @test gr≈T*gw*T' rtol=5e-11 atol=1e-8
        for shift in 1:3
            mc=fixture(joinpath(dir,"warped_cyclic.bdf");warp=warp,offset=offset,cyclic=shift);ac=assemble(mc)
            @test ac.K≈aw.K rtol=5e-12
            gc=Matrix(S.assemble_geometric_stiffness(mc,ac.ids,ac.X,ac.R,ac.nd,u,ac.normals,ac.mapping;snorm_angle_override=0.))
            @test gc≈gw rtol=5e-11 atol=1e-8
        end
        # The nonuniform section tends to the ordinary warped shell as all
        # four corner values approach a common positive thickness.
        uniform=assemble(fixture(joinpath(dir,"warped_uniform.bdf");warp=warp,offset=offset,ti=fill(.004,4)))
        regular=assemble(fixture(joinpath(dir,"warped_regular.bdf");warp=warp,offset=offset,ti=nothing,h=.004))
        @test uniform.K≈regular.K rtol=3e-12
        @test uniform.M≈regular.M rtol=3e-12
    end
    for hnew in (.002,.004)
        au=assemble(fixture(joinpath(dir,"uniform$hnew.bdf");ti=fill(hnew,4)))
        ac=assemble(fixture(joinpath(dir,"constant$hnew.bdf");ti=nothing,h=hnew))
        @test au.K≈ac.K rtol=2e-12
        @test au.M≈ac.M rtol=2e-12
    end
    for key in ("GRAVs","RFORCEs","TEMPs","TEMPDs"),uniform in (false,true)
        bad=deepcopy(model);bad[key]=[1]
        uniform && (bad["CSHELLs"]["1"]["CORNER_THICKNESSES"]=fill(.004,4))
        @test_throws ArgumentError S.shell_corner_thickness_model_data(bad,bad["PSHELLs"]["1"],bad["CSHELLs"]["1"])
    end
    bad=deepcopy(model);bad["SOL"]=106
    @test_throws ArgumentError S.shell_corner_thickness_model_data(bad,bad["PSHELLs"]["1"],bad["CSHELLs"]["1"])
    blank=deepcopy(model);blank["CSHELLs"]["1"]["CORNER_THICKNESSES"]=fill(nothing,4);blank["GRAVs"]=[1]
    @test S.shell_corner_thickness_model_data(blank,blank["PSHELLs"]["1"],blank["CSHELLs"]["1"])===nothing
    @test S.shell_variable_thickness_domain(model,model["PSHELLs"]["1"],model["CSHELLs"]["1"],xy+[0. 0.;0. 0.;.02 0.;0. 0.])!==nothing
    @test_throws ArgumentError S.shell_variable_thickness_domain(model,model["PSHELLs"]["1"],model["CSHELLs"]["1"],xy[[1,3,2,4],:])
    xyz=hcat(xy,[0.,0.,.001,0.])
    @test S.shell_variable_thickness_domain(model,model["PSHELLs"]["1"],model["CSHELLs"]["1"],xy,xyz)!==nothing
end
end
end
