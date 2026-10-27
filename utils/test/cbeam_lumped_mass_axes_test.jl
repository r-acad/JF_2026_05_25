using Test,OpenJFEM,LinearAlgebra,Random
@testset "CBEAM lumped centroid and independent NSM line" begin
 mktempdir() do dir
  path=joinpath(dir,"fixture.bdf")
  write(path,"SOL 103\nCEND\nBEGIN BULK\nPARAM,COUPMASS,0\nGRID,1,,0.,0.,0.\nGRID,2,,2.,0.,0.\nCBEAM,1,1,1,2,0.,1.,0.\nPBAR,1,1,2.,.4,.3,.5,4.\nMAT1,1,7.E10,,.3,3.\nENDDATA\n")
  m=OpenJFEM.bdf_to_model(path);p=m["PBARLs"]["1"];p["TYPE"]="PBEAM"
  ids=Dict(1=>1,2=>2);X=[0. 0. 0.;2. 0. 0.];R=[Matrix{Float64}(I,3,3),Matrix{Float64}(I,3,3)]
  mass()=Matrix(OpenJFEM.Solver.assemble_mass(m,ids,X,R,12))
  u=zeros(12);u[1]=u[7]=1.;tw=zeros(12);tw[4]=tw[10]=1.;rz=zeros(12);rz[6]=rz[12]=1.
  rng=MersenneTwister(170)
  for (n1,n2) in ((0.,0.),(.1,-.07)),(m1,m2) in ((0.,0.),(.2,.3))
   p["N1A"]=p["N1B"]=n1;p["N2A"]=p["N2B"]=n2
   p["M1A"]=p["M1B"]=m1;p["M2A"]=p["M2B"]=m2;p["NSM"]=4.
   M=mass()
   @test dot(u,M*u)≈20.
   @test dot(tw,M*tw)≈4.2+12*(n1^2+n2^2)+8*(m1^2+m2^2)
   @test dot(u,M*rz)≈-12n1-8m1 atol=1e-13
   @test M≈M'
   @test minimum(eigvals(Symmetric(M)))>=-1e-13*opnorm(M)
   # Independent endpoint kinetic energy: structural nodal point mass 6,
   # NSM point mass 4, centroidal polar inertia 2.1 at each endpoint.
   for trial in 1:5
    v=randn(rng,12);expected=0.
    for base in (0,6)
     vel=v[base+1:base+3];omega=v[base+4:base+6]
     expected+=6sum(abs2,vel+cross(omega,[0.,n1,n2]))+4sum(abs2,vel+cross(omega,[0.,m1,m2]))+2.1omega[1]^2
    end
    @test dot(v,M*v)≈expected rtol=5e-14
   end
   p["NSM"]=0.;M0=mass();p["NSM"]=-4.;Mminus=mass();p["NSM"]=4.
   @test M+Mminus≈2M0 rtol=2e-14 atol=1e-13
   # Coordinate covariance under independent GRID analysis frames.
   Q=Matrix(qr(randn(rng,3,3)).Q);R[1]=Q;R[2]=Q
   T=kron(Matrix{Float64}(I,4,4),Q);Mr=mass()
   @test Mr≈T'*M*T rtol=2e-14
   R[1]=Matrix{Float64}(I,3,3);R[2]=Matrix{Float64}(I,3,3)
  end
  # Zero-offset NSM has no section polar inertia; centroid displacement
  # continuity is tested at offsets near zero on either side.
  p["N1A"]=p["N1B"]=p["N2A"]=p["N2B"]=0.
  p["M1A"]=p["M1B"]=p["M2A"]=p["M2B"]=0.
  base=mass();@test dot(tw,base*tw)≈4.2
  for delta in (-1e-8,1e-8)
   p["N1A"]=p["N1B"]=delta;Md=mass()
   @test dot(u,Md*rz)≈-12delta atol=1e-15
   @test norm(Md-base)/norm(base)<1e-7
  end
 end
end
