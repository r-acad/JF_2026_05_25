using Test,LinearAlgebra,SparseArrays,OpenJFEM
module ModalMassRankFixture
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
@testset "Bounded modal PSD rank is invariant to coordinate units and nullspace rotations" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
 for scale in (1e-18,1.,1e18),units in (eye,Diagonal(exp.(range(-8.,8.;length=n)))),rotation in (eye,Q)
  T=rotation*units;M=scale*T'*Diagonal([1.,2.,3.,4.,5.,0.])*T
  signature=S._sol103_small_mass_signature(M)
  @test signature.status===:positive_semidefinite
  @test signature.rank==5
  @test signature.nullity==1
 end
 @test S._sol103_small_mass_signature(Diagonal(10. .^(-12:5:13))).rank==6
 # Very small but resolved positive eigenvalues are retained. Unit disparity
 # alone cannot create a nullspace after the diagonal congruence.
 for smallest in (1e-8,1e-10,1e-12,1e-13),rotation in (eye,Q)
  M=rotation'*Diagonal([1.,2.,3.,4.,5.,smallest])*rotation
  signature=S._sol103_small_mass_signature(M)
  @test signature.status===:positive_semidefinite
  @test signature.rank==6
  @test signature.minimum_eigenvalue>signature.tolerance
 end
 @test S._sol103_small_mass_signature(Diagonal([1e-300,1e-180,1e-20,1.,1e20,1e300])).rank==6
 @test S._sol103_small_mass_signature([1. 2.;2. 1.]).status===:indefinite

 @test S._sol103_small_mass_signature(Diagonal([-1.,1.,1.])).status===:indefinite
 @test S._sol103_small_mass_signature(eye;max_dof=5).status===:outside_bound
 @test S._sol103_small_mass_signature(zeros(6,6)).rank==0
 @test S._sol103_small_mass_signature(fill(NaN,6,6)).status===:nonfinite
end
@testset "Hidden massless stiff direction does not require a fictitious finite mode" begin
 n=6;eye=Matrix{Float64}(I,n,n)
 H=[sin(.27i*j)+cos(.51i*(j+1))+(i==j ? 2. : 0.) for i=1:n,j=1:n]
 K0=H'*H+eye;M0=Diagonal([1.,2.,3.,4.,5.,0.])
 condensed=K0[1:5,1:5]-K0[1:5,6:6]*(K0[6:6,6:6]\K0[6:6,1:5])
 expected=eigvals(Symmetric(condensed),Symmetric(Matrix(M0[1:5,1:5])))
 Q=Matrix(qr([sin(.31i*j)+cos(.13i*(j+1))+(i==j ? 1. : 0.) for i=1:n,j=1:n]).Q)
 for units in (eye,Diagonal(exp.(range(-3.,3.;length=n)))),rotation in (eye,Q),nd in (2,5,8)
  T=rotation*units;K=T'*K0*T;M=T'*M0*T
  values,freqs,modes,diagnostics=solve_pencil(K,M,nd)
  count_expected=min(nd,5)
  @test length(values)==count_expected
  @test isapprox(values,expected[1:count_expected];rtol=1e-7)
  @test diagnostics["mass_spectrum_classification"]["rank"]==5
  @test diagnostics["mass_spectrum_classification"]["nullity"]==1
  @test isapprox(modes'*M*modes,Matrix{Float64}(I,count_expected,count_expected);atol=1e-7)
  @test all(norm(K*modes[:,i]-values[i]*M*modes[:,i])/(norm(K*modes[:,i])+values[i]*norm(M*modes[:,i]))<1e-7 for i=1:count_expected)
 end
 # A regular indefinite pencil may have fewer finite roots than rank(M).
 # Its coupled massless direction must retain the interval-based fallback.
 Kindex=Matrix(Diagonal([2.,3.,4.,5.,0.,0.]));Kindex[5,6]=Kindex[6,5]=1.
 Mindex=Matrix(Diagonal([1.,2.,3.,4.,1.,0.]))
 index_values,_,_,index_diagnostics=solve_pencil(Kindex,Mindex,8)
 @test isapprox(index_values,[1.25,4/3,1.5,2.];rtol=1e-8)
 @test index_diagnostics["mass_spectrum_classification"]["rank"]==5
 @test index_diagnostics["eigen_cache"]["factor_backend"]=="positive_mass_shift_lu"
 # A completely massless but stiff model has no finite natural modes.
 empty_values,_,empty_vectors,empty_diagnostics=solve_pencil(eye,zeros(n,n),8)
 @test isempty(empty_values)
 @test size(empty_vectors)==(n,0)
 @test empty_diagnostics["solver_backend"]=="no_finite_mass"
 @test occursin("no positive mass directions",empty_diagnostics["failure_reason"])
 # Frequency-band selection is still certified by the interval inertia.
 lower=sqrt((expected[2]+expected[3])/2)/(2pi);upper=sqrt((expected[4]+expected[5])/2)/(2pi)
 values,_,_,_=solve_pencil(Q'*K0*Q,Q'*M0*Q,8;lower=lower,upper=upper)
 @test isapprox(values,expected[3:4];rtol=1e-7)
end
end
