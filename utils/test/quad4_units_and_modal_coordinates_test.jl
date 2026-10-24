using Test, LinearAlgebra, SparseArrays, OpenJFEM

# Independent geometric similarity, strain patch, and regular-pencil controls.
# No solver-reference outputs or empirical eigenvalue factors are used.
function _q4_physical_field_scale_errors()
 F=OpenJFEM.FEM
 x=[0. 0.;2. .1;2.3 .8;-.2 1.];h=.003;E=70e9;nu=.3
 A=E*h/(1-nu^2)*[1. nu 0.;nu 1. 0.;0 0 (1-nu)/2]
 D=A*h^2/12;Sh=5/6*E/(2*(1+nu))*h*Matrix{Float64}(I,2,2);B=.05h*A
 u=[1e-3*sin(i*.9) for i=1:24]
 # Translation and director rotations transform differently under physical similarity.
 errors=Dict{String,Float64}()
 track(k,a,b)=errors[k]=max(get(errors,k,0.),norm(a-b)/max(norm(b),1e-280))
 for L in (1e-8,1e-6,1e-3,1.,1e3,1e6)
  U=Diagonal([mod(i-1,6)<3 ? L : 1. for i=1:24]);us=U*u;xs=x*L
  track("area",F.quad4_gauss_area_weights(xs)/L^2,F.quad4_gauss_area_weights(x))
  for incompatible in (false,true), enhanced in (false,true)
   n,a,w=F.quad4_membrane_force_field(x,u,E,nu,h;use_incompatible_modes=incompatible,use_enhanced_modes=enhanced)
   ns,aa,ww=F.quad4_membrane_force_field(xs,us,E,nu,h*L;use_incompatible_modes=incompatible,use_enhanced_modes=enhanced)
   track("N_gp",ns/L,n);track("N_average",aa/L,a);track("N_weights",ww/L^2,w)
  end
  r=F.stress_strain_quad4(x,u,E,nu,h,h;recover_corners=true)
  rs=F.stress_strain_quad4(xs,us,E,nu,h*L,h*L;recover_corners=true)
  for (i,pow) in enumerate((1,2,1,0,0,0,0,1,2));track("stress_strain_"*string(i),rs[i]/L^pow,r[i]);end
  for coupled in (false,true)
   bb=coupled ? B : nothing;bbs=coupled ? B*L^2 : nothing
   f=F.quad4_condensed_section_fields(x,u,A,bb,D,Sh,h,E)
   fs=F.quad4_condensed_section_fields(xs,us,A*L,bbs,D*L^3,Sh*L,h*L,E)
   for (key,pow) in ((:N,1),(:M,2),(:eps,0),(:kappa,-1),(:weights,2))
    track("condensed_"*string(key),getproperty(fs,key)/L^pow,getproperty(f,key))
   end
   ng,na,nw=F.quad4_differential_membrane_force_field(x,u,A,bb)
   ngs,nas,nws=F.quad4_differential_membrane_force_field(xs,us,A*L,bbs)
   track("differential_N",ngs/L,ng);track("differential_average",nas/L,na)
  end
  sigma=[-3e7 -1e7 4e6;-2e7 -3e7 6e6;-5e7 -2e7 -8e6;-1e7 -4e7 2e6]
  for incompatible in (false,true),enhanced in (false,true),shear_center in (false,true)
   kg=F.geometric_stiffness_quad4(x,sigma,h;Cm=A,membrane_incomp=incompatible,membrane_enhanced=enhanced,membrane_shear_center_row=shear_center)
   kgs=F.geometric_stiffness_quad4(xs,sigma,h*L;Cm=A*L,membrane_incomp=incompatible,membrane_enhanced=enhanced,membrane_shear_center_row=shear_center)
   track("Kg",U*kgs*U/L^3,kg)
  end
  kg=zeros(24,24);kgs=zeros(24,24)
  F.add_quad4_assumed_transverse_gradient_delta!(kg,x,sigma,h)
  F.add_quad4_assumed_transverse_gradient_delta!(kgs,xs,sigma,h*L)
  track("Kg_assumed_delta",U*kgs*U/L^3,kg)
 end
 # Independent constant membrane strain patch; no reference result involved.
 eps0=[1e-3,-2e-4,3e-4];ua=zeros(24)
 for i=1:4
  ua[6i-5]=eps0[1]*x[i,1]+eps0[3]*x[i,2]/2
  ua[6i-4]=eps0[2]*x[i,2]+eps0[3]*x[i,1]/2
 end
 f=F.quad4_condensed_section_fields(x,ua,A,nothing,D,Sh,h,E)
 track("affine_N",f.N_average,A*eps0)
 target=[1.,-3.,7.];values=[1. 2. 3.;4. 5. 6.;7. 8. 9.;3. 5. 7.]
 for L in (1e-10,1.,1e10)
  w=F.quad4_gauss_area_weights(x*L);v=copy(values)
  F.quad4_preserve_membrane_average!(v,target,w)
  track("preserve_average",vec(v'*w/sum(w)),target)
 end
 errors
end

let F = OpenJFEM.FEM, S = OpenJFEM.Solver
@testset "Q4 physical dimensional congruence" begin
 x=[0. 0.;2. .1;2.3 .8;-.2 1.];h=.003;E=70e9;nu=.3
 A=E*h/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
 D=A*h^2/12;Sh=5/6*E/(2*(1+nu))*h*Matrix{Float64}(I,2,2)
 for kernel in ("macneal","mitc4"),coupled in (false,true)
  B=coupled ? .05h*A : nothing
  K=F.stiffness_quad4_matrices(x,A,D,Sh,h,E;Bmb=B,k6rot=1.,membrane_incomp=true,bending_incomp=true,kernel_mode=kernel)
  for L in (1e-8,1e-6,1e-3,1.,1e3,1e6)
   Bs=B===nothing ? nothing : B*L^2
   Ks=F.stiffness_quad4_matrices(x*L,A*L,D*L^3,Sh*L,h*L,E;Bmb=Bs,k6rot=1.,membrane_incomp=true,bending_incomp=true,kernel_mode=kernel)
   U=Diagonal([mod(i-1,6)<3 ? L : 1.0 for i=1:24])
   @test norm(U*Ks*U/L^3-K)/norm(K)<2e-9
   @test norm(Ks-Ks')/norm(Ks)<1e-12
  end
 end
 for L in (1e-10,1.,1e10)
  @test F._quad4_jacobian_measure(L^2,L,0.,0.,L)==L^2
  @test_throws ArgumentError F._quad4_jacobian_measure(0.,L,L,L,L)
 end
end
@testset "Inertia is invariant under diagonal congruence" begin
 Q=Matrix(qr([sin(i+2j)+cos(2i-j) for i=1:6,j=1:6]).Q)
 A=Q*Diagonal([-7.,-2.,1.,3.,5.,9.])*Q'
 for extent in (0.,5.,15.,30.),order in (1,-1)
  D=Diagonal(exp.(range(-extent,extent;length=6).*order));H=sparse(D*A*D)
  @test S._buckling_sturm_count(H,spzeros(6,6),0.)==2
 end
 @test S._buckling_sturm_count(sparse(Diagonal([1e-200,1e-100,-1e-20,1.,-1e100,1e200])),spzeros(6,6),0.)==2
end
@testset "Only exact joint zero columns can be removed" begin
 A=spzeros(6,6);B=copy(A)
 @test S._sol103_exact_zero_column(A,2)
 A[1,2]=1e-200
 @test !S._sol103_exact_zero_column(A,2)
 @test !S._sol103_exact_zero_column(Matrix(A),2)
 model=Dict{String,Any}("SOL"=>103,"PARAM_AUTOSPC"=>false,"SPC1s"=>Any[])
 ids=Dict(1=>1);X=zeros(1,3);R=[Matrix{Float64}(I,3,3)]
 K=Matrix(Diagonal([4.,2.,6.,8.,10.,12.]));K[1,2]=K[2,1]=1.
 M=Matrix(Diagonal([1.,0.,1.,1.,1.,1.]))
 for c in (1.,1e-6,1e-15)
  U=Diagonal([1.,c,1.,1.,1.,1.]);ks=sparse(U*K*U);ms=sparse(U*M*U)
  values,_,V,d=S.solve_modes(ks,ms,6,model,ids,X,0,R,5;return_diagnostics=true)
  @test values ≈ [3.5,6.,8.,10.,12.] rtol=2e-8
  @test d["massless_free_dofs_removed"]==0
  @test d["quadratic_mass_floor_active"]
  @test maximum(d["eigenpair_relative_residuals"])<1e-6
 end
 K[2,:].=0;K[:,2].=0
 values,_,_,d=S.solve_modes(sparse(K),sparse(M),6,model,ids,X,0,R,5;return_diagnostics=true)
 @test values ≈ [4.,6.,8.,10.,12.] rtol=2e-8
 @test d["massless_free_dofs_removed"]==1
end

@testset "Q4 recovery and prestress dimensional similarity" begin
    for (key, error) in _q4_physical_field_scale_errors()
        @test error < 2e-8
    end
end
end
