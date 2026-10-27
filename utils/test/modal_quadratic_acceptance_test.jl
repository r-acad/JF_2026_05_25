using Test,LinearAlgebra,SparseArrays,OpenJFEM
module ModalQuadraticAcceptanceFixture
using Test,LinearAlgebra,SparseArrays,OpenJFEM
const S=OpenJFEM.Solver
function solve_pencil(K,M,nd;lower=0.,upper=0.)
 n=size(K,1)
 model=mktempdir() do dir
  p=joinpath(dir,"fixture.bdf");write(p,"SOL 103\nCEND\nBEGIN BULK\nPARAM,AUTOSPC,NO\n"*join(["GRID,$i,,$i.,0.,0." for i=1:div(n,6)],"\n")*"\nENDDATA\n")
  OpenJFEM.bdf_to_model(p)
 end
 ids=Dict(i=>i for i=1:div(n,6));X=hcat(Float64.(1:div(n,6)),zeros(div(n,6),2));R=[Matrix{Float64}(I,3,3) for _=1:div(n,6)]
 S.solve_modes(sparse(K),sparse(M),n,model,ids,X,nothing,R,nd;eigrl_v1=lower,eigrl_v2=upper,return_diagnostics=true)
end
@testset "Modal mass acceptance uses the quadratic-form roundoff scale" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
 M=Q'*Diagonal([1.,2.,3.,4.,5.,0.])*Q
 v=[sin(i) for i=1:n];z=Q'*[0.,0.,0.,0.,0.,1.]
 base=S._sol103_mass_quadratic_roundoff(M,v)
 for mass_scale in (1e-100,1e-24,1.,1e100),D in (eye,Diagonal(exp.(range(-12.,12.;length=n))))
  mass=mass_scale*D*M*D;u=D\v;nullu=D\z
  for mat in (mass,sparse(mass))
   floor=S._sol103_mass_quadratic_roundoff(mat,u)
   @test isapprox(floor/mass_scale,base;rtol=1e-12)
   @test dot(u,mat*u)>floor
   @test abs(dot(nullu,mat*nullu))<=S._sol103_mass_quadratic_roundoff(mat,nullu)
  end
 end
 @test S._sol103_mass_quadratic_roundoff(zeros(n,n),v)==0.
 H=[sin(.27i*j)+cos(.51i*(j+1))+(i==j ? 2. : 0.) for i=1:n,j=1:n]
 K=H'*H+eye;M0=Diagonal([1.,2.,3.,4.,5.,0.])
 condensed=K[1:5,1:5]-K[1:5,6:6]*(K[6:6,6:6]\K[6:6,1:5])
 expected=eigvals(Symmetric(condensed),Symmetric(Matrix(M0[1:5,1:5])))
 for (ks,ms) in ((1e-10,1e-24),(1e-10,1e-30),(1e5,1e12)),D in (eye,Diagonal(exp.(range(-3.,3.;length=n))))
  T=Q*D;a=ks*T'*K*T;b=ms*T'*M0*T
  vals,_,V,d=solve_pencil(a,b,8)
  @test length(vals)==5
  @test d["quadratic_mass_floor_active"]==true
  @test d["mass_acceptance_metric"]=="quadratic_form_roundoff_gamma_2n_plus_2_certified_psd_pencil"
  @test isapprox(vals/(ks/ms),expected;rtol=1e-7)
  @test all(norm(a*V[:,i]-vals[i]*b*V[:,i])/(norm(a*V[:,i])+abs(vals[i])*norm(b*V[:,i]))<1e-7 for i in eachindex(vals))
 end
end

@testset "Near-rigid modes retain their backward-error treatment" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
 for T in (eye,Q)
  a=T'*Diagonal([0.,0.,1.,2.,3.,4.])*T
  vals,_,V,d=withenv("JFEM_SOL103_DENSE_MAX_DOF"=>"0") do
   solve_pencil(a,eye,5)
  end
  @test length(vals)==5
  @test d["quadratic_mass_floor_active"]==true
  @test d["mass_acceptance_metric"]=="quadratic_form_roundoff_gamma_2n_plus_2_certified_psd_pencil"
  @test isapprox(vals,[0.,0.,1.,2.,3.];atol=1e-9,rtol=1e-8)
  @test maximum(norm(a*V[:,i]) for i=1:2)<1e-9
 end
end


@testset "Quadratic mass bound is restricted to certified modal pencils" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 K=Matrix(Diagonal([2.,3.,4.,5.,0.,0.]));K[5,6]=K[6,5]=1.
 M=Matrix(Diagonal([1.,2.,3.,4.,1.,0.]))
 Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
 for T in (eye,Q)
  vals,_,_,d=solve_pencil(T'*K*T,T'*M*T,8)
  @test isapprox(vals,[1.25,4/3,1.5,2.];rtol=1e-8)
  @test d["quadratic_mass_floor_active"]==false
  @test d["mass_acceptance_metric"]=="relative_diagonal_mass_floor_certified_psd_mass"
  @test d["mass_spectrum_classification"]["status"]=="positive_semidefinite"
  @test d["scale_relative_mass_floor_active"]==true
 end
 # A requested frequency range does not alter the physical eligibility.
 for upper in (0.0,1.0)
  vals,_,_,d=solve_pencil(Diagonal([1.,2.,3.,4.,5.,6.]),Diagonal([1.,1.,1.,1.,1.,0.]),8;upper=upper)
  @test isapprox(vals,[1.,2.,3.,4.,5.];rtol=1e-8)
  @test d["quadratic_mass_floor_active"]==true
 end
end

@testset "Unclassified mass retains the legacy acceptance policy" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 withenv("JFEM_SOL103_MASS_RANK_MAX_DOF"=>"0","JFEM_SOL103_DENSE_MAX_DOF"=>"0") do
  vals,_,_,d=solve_pencil(Diagonal([1.,2.,3.,4.,5.,6.]),eye,4)
  @test isapprox(vals,[1.,2.,3.,4.];rtol=1e-8)
  @test d["quadratic_mass_floor_active"]==false
  @test d["scale_relative_mass_floor_active"]==false
  @test d["mass_acceptance_metric"]=="legacy_unclassified_or_indefinite_pencil_policy"
 end
end


end
