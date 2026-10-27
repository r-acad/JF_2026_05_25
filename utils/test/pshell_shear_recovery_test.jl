using Test
module PshellShearWorkFixture
using Test,OpenJFEM,LinearAlgebra,StaticArrays
const F=OpenJFEM.FEM;const S=OpenJFEM.Solver
function checks()
 mktempdir() do dir
  file=joinpath(dir,"physical_shear.bdf")
  write(file,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,-1.,-.5,0.
GRID,2,,1.,-.5,0.
GRID,3,,1.,.5,0.
GRID,4,,-1.,.5,0.
CQUAD4,1,10,1,2,3,4
MAT1,1,7.E10,2.E10,.29,2700.
PSHELL,10,1,.1,1,1.,1,.25
ENDDATA
""")
  model=OpenJFEM.bdf_to_model(file);prop=model["PSHELLs"]["10"]
  ids=Dict(i=>i for i=1:4);Rs=[Matrix{Float64}(I,3,3) for _=1:4]
  E=7e10;nu=.29;G=2e10;h=.1
  C=E/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
  function recover(X,u)
   normals=S.compute_snorm_normals(model,ids,X)
   output=Dict{String,Any}(key=>Dict("quad4"=>Any[],"tria3"=>Any[]) for key in ("forces","forces_bilin","stresses","strains"))
   S.recover_shell_stresses!(model,ids,X,Rs,u,normals,Dict{Int,Float64}(),output)
   row=only(output["forces"]["quad4"])
   @test output["recovery_diagnostics"]["area_mean_transverse_shear_eids"]==[1]
   @test occursin("Area-mean",output["recovery_diagnostics"]["transverse_shear_location"])
   [row["qx"],row["qy"]]
  end
  shapes=([-1. -.5;1. -.5;1. .5;-1. .5],[-1. -.5;1. -.5;1.4 .5;-.6 .5],[-1. -.5;1. -.5;.7 .5;-.8 .5])
  for xy in shapes, warp in (0.,.025), tst in (.25,5/6), sol in (101,105,106), blank in (false,true)
   X=hcat(xy,warp*[1.,-1.,1.,-1.]);model["SOL"]=sol;prop["TS_T"]=tst;prop["MID3"]=blank ? 0 : 1
   points=[SVector{3}(X[i,:]) for i=1:4]
   axes=S.shell_element_frame_quad4(points...,S.q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC"))
   center=sum(points)/4;localxy=[dot(x-center,v) for x in points,v in axes[1:2]]
   R=reduce(vcat,permutedims.(axes));T=zeros(24,24)
   for i=1:8;T[3i-2:3i,3i-2:3i]=R;end
   W=F.quad4_finite_warp_displacement_map(localxy,X);W===nothing&&(W=Matrix{Float64}(I,24,24))
   area=abs(sum(localxy[i,1]*localxy[mod1(i+1,4),2]-localxy[i,2]*localxy[mod1(i+1,4),1] for i=1:4))/2
   D=h^3/12*C;Cs=tst*h*G*Matrix{Float64}(I,2,2)
   K=F.stiffness_quad4_matrices(localxy,h*C,D,Cs,h,E;k6rot=0.,coords_3d=X,macneal_rigid_shear=blank&&sol in (101,105))
   for pattern in (:unit_shear,:general)
    projected=pattern===:general ? 1e-3sin.(collect(1.:24.)) : zeros(24)
    pattern===:unit_shear && (projected[5:6:24].=1e-3)
    localu=W\projected;q=recover(X,T'*localu)
    pattern===:unit_shear && @test norm(q)>1e-6
    for gamma in ([1.,0.],[0.,1.],[.4,-.7])
     v=zeros(24);v[4:6:24].=-gamma[2];v[5:6:24].=gamma[1]
     @test isapprox(area*dot(gamma,q),dot(W\v,K*localu);rtol=2e-10,atol=1e-8)
    end
   end
  end
  # Unsupported/research constitutive routes must not silently opt in.
  xy=shapes[1];X=hcat(xy,zeros(4));mat=model["MATs"]["1"];model["SOL"]=101
  # Ordinary normal-moment cells now recover the same physical shear work.
  pq=ones(4,2)
  data=S._pshell_macneal_mean_shear_data(model,prop,mat,xy,X,pq,nothing)
  @test data!==nothing
  P=F.quad4_physical_displacement_map(xy,X,pq)
  uq=1e-3*sin.(collect(1.:24.))
  q=F.quad4_macneal_mean_shear_resultant(xy,P*uq,data.D,data.Cs,data.h;
      Cm=data.A,rigid_shear=data.rigid)
  Kn=F.stiffness_quad4_matrices(xy,data.A,data.D,data.Cs,data.h,E;
      k6rot=0.,coords_3d=X,snorm_pq=pq,macneal_rigid_shear=data.rigid)
  for gamma in ([1.,0.],[0.,1.],[.4,-.7])
   v=zeros(24);v[4:6:24].=-gamma[2];v[5:6:24].=gamma[1]
   @test isapprox(2dot(gamma,q),dot(P\v,Kn*uq);rtol=2e-10,atol=1e-8)
  end
  withenv("JFEM_SNORM_DIRECTOR"=>"true") do
   @test S._pshell_macneal_mean_shear_data(model,prop,mat,xy,X,pq,nothing)===nothing
  end
  for setting in ("JFEM_Q4_KERNEL"=>"default","JFEM_Q4_STATIC_COMPONENT_CS_SCALE"=>".5","JFEM_Q4_MACNEAL_RIGID_SHEAR_FORCE"=>"true")
   withenv(setting) do
    @test S._pshell_macneal_mean_shear_data(model,prop,mat,xy,X,nothing,nothing)===nothing
   end
  end
  # Formal SOL106 changes membrane energy, while its transverse-shear
  # law remains the same linear operator. Auto and explicit names must agree.
  model["SOL"]=106;model["PARAM_NLMETHOD"]="auto"
  utest=1e-3*sin.(collect(1.:24.));qauto=recover(X,utest)
  Cs=Float64(prop["TS_T"])*h*G*Matrix{Float64}(I,2,2)
  K=F.stiffness_quad4_matrices(xy,h*C,h^3/12*C,Cs,h,E;
      k6rot=0.,bending_incomp=true,membrane_incomp=true)
  for method in ("formal_shell_green_lagrange","formal_shell_von_karman")
   model["PARAM_NLMETHOD"]=method
   qformal=recover(X,utest)
   @test isapprox(qformal,qauto;rtol=1e-12)
   for gamma in ([1.,0.],[0.,1.],[.4,-.7])
    v=zeros(24);v[4:6:24].=-gamma[2];v[5:6:24].=gamma[1]
    @test isapprox(2dot(gamma,qformal),dot(v,K*utest);rtol=2e-10,atol=1e-8)
   end
  end
 end
end
end
@testset "PSHELL shear output preserves the actual elastic shear work" begin
 PshellShearWorkFixture.checks()
end
