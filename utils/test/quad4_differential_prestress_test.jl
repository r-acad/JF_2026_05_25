using Test
module Quad4DifferentialPrestressFixture
using Test,OpenJFEM,LinearAlgebra,ForwardDiff,Random
const F=OpenJFEM.FEM
const S=OpenJFEM.Solver
function derivs(x,r,s)
    # Differentiate the interpolated coordinate map, independently of the
    # element's hand-written shape-derivative implementation.
    shapes(z)=[(1-z[1])*(1-z[2]),(1+z[1])*(1-z[2]),
               (1+z[1])*(1+z[2]),(1-z[1])*(1+z[2])]/4
    dn=ForwardDiff.jacobian(shapes,[r,s])'
    J=dn*x
    J\dn,abs(det(J))
end
function independent(x,u,A,B)
    d0,_=derivs(x,0.,0.);q=1/sqrt(3.);N=zeros(4,3);weights=zeros(4)
    for (i,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
        d,w=derivs(x,r,s);U=reshape(u,6,4)
        grad=U*d';grad0=U*d0'
        eps=[grad[1,1],grad[2,2],grad0[1,2]+grad0[2,1]]
        kap=[grad[5,1],-grad[4,2],2*(grad[5,2]-grad[4,1])-(grad0[5,2]-grad0[4,1])]
        N[i,:].=A*eps+(B===nothing ? zeros(3) : B*kap);weights[i]=w
    end
    N,weights
end
function kernel_checks()
    Random.seed!(7743)
    A=[110e6 18e6 7e6;18e6 48e6 -3e6;7e6 -3e6 21e6]
    B=[500. 90. 30.;90. -200. 40.;30. 40. 80.]
    shapes=([0. 0.;2. 0.;2. 1.;0. 1.],
        [0. 0.;2. .2;2.4 1.2;.4 1.],
        [0. 0.;2. -.2;2.3 .9;-.1 1.2])
    for x in shapes,b in (nothing,B),warped in (false,true)
        xyz=warped ? hcat(x,[.04,-.04,.04,-.04]) : nothing
        u=randn(24)*1e-4;u_copy=copy(u)
        N,average,weights=F.quad4_differential_membrane_force_field(x,u,A,b;coords_3d=xyz)
        map=xyz===nothing ? nothing : F.quad4_finite_warp_displacement_map(x,xyz)
        up=map===nothing ? u : map*u
        expected,w=independent(x,up,A,b)
        @test isapprox(N,expected;rtol=3e-13,atol=1e-9)
        @test isapprox(weights,w;rtol=3e-13)
        @test isapprox(average,vec(expected'*w/sum(w));rtol=3e-13)
        @test u==u_copy
        @test isapprox(F.quad4_differential_membrane_force_field(x,-2u,A,b;coords_3d=xyz)[1],-2N;rtol=3e-13)
        v=randn(24)*1e-4
        Nv=F.quad4_differential_membrane_force_field(x,v,A,b;coords_3d=xyz)[1]
        @test isapprox(F.quad4_differential_membrane_force_field(x,u+v,A,b;coords_3d=xyz)[1],N+Nv;rtol=3e-13,atol=1e-9)
        # Translations and infinitesimal rigid rotations create no prestress,
        # including the finite-warp pullback of non-coplanar nodal translations.
        points=xyz===nothing ? hcat(x,zeros(4)) : xyz
        for omega in ([.03,0.,0.],[0.,-.02,0.],[0.,0.,.04])
            rigid=zeros(24)
            for i=1:4
                rigid[6i-5:6i-3].=[.1,-.2,.3]+cross(omega,points[i,:])
                rigid[6i-2:6i].=omega
            end
            Nr=F.quad4_differential_membrane_force_field(x,rigid,A,b;coords_3d=xyz)[1]
            @test norm(Nr)<1e-7
        end
        # Work of the initial membrane stress through the assumed transverse
        # gradient is the Hessian of its quadratic geometric potential.
        G=F.geometric_stiffness_quad4(x,N,1.)
        F.add_quad4_assumed_transverse_gradient_delta!(G,x,N,1.)
        function potential(v)
            result=zero(eltype(v));q=1/sqrt(3.)
            for (i,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
                dx,_=derivs(x,0.,s);dy,_=derivs(x,r,0.)
                gx=dot(dx[1,:],v);gy=dot(dy[2,:],v)
                result+=weights[i]*(N[i,1]*gx^2+2N[i,3]*gx*gy+N[i,2]*gy^2)/2
            end
            result
        end
        H=ForwardDiff.hessian(potential,zeros(4))
        @test isapprox(G[[3,9,15,21],[3,9,15,21]],H;rtol=3e-12,atol=1e-8)
        @test isapprox(H,H';rtol=1e-13,atol=1e-9)
    end
    for x in shapes,b in (nothing,B)
        eps=[-.001,-.0004,.0002];kap=[.0003,-.0001,.00007];u=zeros(24)
        for i=1:4
            X,Y=x[i,:]
            u[6i-5]=eps[1]*X+eps[3]*Y/2
            u[6i-4]=eps[2]*Y+eps[3]*X/2
            u[6i-1]=kap[1]*X+kap[3]*Y/2
            u[6i-2]=-kap[2]*Y-kap[3]*X/2
        end
        expected=A*eps+(b===nothing ? zeros(3) : b*kap)
        N,average,_=F.quad4_differential_membrane_force_field(x,u,A,b)
        @test isapprox(N,repeat(expected',4);rtol=1e-12)
        @test isapprox(average,expected;rtol=1e-12)
        # Differentiation w.r.t. section data preserves the complete physical
        # A/B coupling, rather than introducing an eigenvalue-dependent factor.
        f(p)=vec(F.quad4_differential_membrane_force_field(x,u,p[1]*A,p[2]*B)[1])
        J=ForwardDiff.jacobian(f,[1.,1.])
        @test isapprox(J[:,1],vec(repeat((A*eps)',4));rtol=1e-12)
        @test isapprox(J[:,2],vec(repeat((B*kap)',4));rtol=1e-12)
    end
end
rx(a)=[1. 0. 0.;0. cosd(a) -sind(a);0. sind(a) cosd(a)]
ry(a)=[cosd(a) 0. sind(a);0. 1. 0.;-sind(a) 0. cosd(a)]
rz(a)=[cosd(a) -sind(a) 0.;sind(a) cosd(a) 0.;0. 0. 1.]
function model_fixture(dir,x,Q,shift,order,offset;sol=105)
    axes=Q*rz(23.); X=(Q*x')'.+shift'
    path=joinpath(dir,"differential.bdf")
    open(path,"w") do io
        println(io,"SOL $sol\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,1.")
        println(io,"CORD2R,501,,0.,0.,0.,",join(axes[:,3],','))
        println(io,"+,",join(axes[:,1],','))
        for i=1:4
            println(io,"GRID,$i,,",join(X[i,:],','))
        end
        println(io,"CQUAD4,1,10,",join(order,','),",501,$offset")
        println(io,"MAT8,1,140000.,9000.,.27,4500.,3800.,2600.,1.")
        println(io,"PCOMP,10\n+,1,.012,0.,YES,1,.008,65.,YES\nENDDATA")
    end
    m=OpenJFEM.bdf_to_model(path);ids=Dict(i=>i for i=1:4)
    R=[Matrix{Float64}(I,3,3) for _=1:4]
    normals=S.compute_snorm_normals(m,ids,X)
    mapping=S.assemble_constraints(m,ids,X,R,Int[],Int[],Float64[])[1]
    m,ids,X,R,normals,mapping
end
function assemble_fixture(args,u)
    m,ids,X,R,normals,mapping=args; captured=Any[]
    G=Matrix(S.assemble_geometric_stiffness(m,ids,X,R,24,u,normals,mapping;
        snorm_angle_override=0.,geometric_capture=(eid,data)->push!(captured,data)))
    G,only(captured)
end
function assembly_checks()
    mktempdir() do dir
        identity=Matrix{Float64}(I,3,3);Q=ry(31.)*rx(47.)
        T=kron(Matrix{Float64}(I,8,8),Q)
        for warp in (0.,.035), offset in (0.,.02)
            x=[0. 0. warp;2. .1 -warp;2.4 1.1 warp;.4 1. -warp]
            u=[1e-4*sin(.7i) for i=1:24]
            base=model_fixture(dir,x,identity,zeros(3),[1,2,3,4],offset)
            G,data=assemble_fixture(base,u)
            @test data[:kg_differential_prestress]
            @test isapprox(G,G';rtol=2e-12,atol=1e-9)
            @test all(isfinite,G)
            shifted=model_fixture(dir,x,Q,[3.,-2.,4.],[1,2,3,4],offset)
            Grot,_=assemble_fixture(shifted,T*u)
            @test isapprox(Grot,T*G*T';rtol=3e-10,atol=1e-9)
            # A cyclic connectivity change preserves the physical section and
            # all global DOFs; MCID keeps the material axes fixed in space.
            cyclic=model_fixture(dir,x,identity,zeros(3),[2,3,4,1],offset)
            Gcyclic,_=assemble_fixture(cyclic,u)
            @test isapprox(Gcyclic,G;rtol=3e-10,atol=1e-9)
            # The optional legacy recovery route remains available, while K
            # and elastic output recovery are independent of this switch.
            old,olddata=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS"=>"false") do
                assemble_fixture(base,u)
            end
            @test !olddata[:kg_differential_prestress]
            @test olddata[:kg_coupled_condensed]
            @test norm(old-G)>1e-8*norm(G)
            # The historical warped opt-in now agrees with the bounded coupled
            # default; an explicit opt-out still selects the legacy field.
            experimental,experimental_data=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"true") do
                assemble_fixture(base,u)
            end
            @test experimental_data[:kg_differential_prestress]
            @test norm(old-experimental)>1e-8*norm(experimental)
            @test experimental == G
            opted_out,opted_data=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"false") do
                assemble_fixture(base,u)
            end
            @test opted_data[:kg_differential_prestress] == (warp == 0.)
            @test opted_out == (warp == 0. ? G : old)
            experimental_rot,_=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"true") do
                assemble_fixture(shifted,T*u)
            end
            @test isapprox(experimental_rot,T*experimental*T';rtol=3e-10,atol=1e-9)
            experimental_cyclic,_=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"true") do
                assemble_fixture(cyclic,u)
            end
            @test isapprox(experimental_cyclic,experimental;rtol=3e-10,atol=1e-9)
            nonlinear=model_fixture(dir,x,identity,zeros(3),[1,2,3,4],offset;sol=106)
            _,nldata=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"true") do
                assemble_fixture(nonlinear,u)
            end
            @test !nldata[:kg_differential_prestress]
        end
    end
end

end
@testset "Compatible differential prestress and geometric work" begin
    Quad4DifferentialPrestressFixture.kernel_checks()
end

@testset "Differential prestress assembly and coordinate invariance" begin
    Quad4DifferentialPrestressFixture.assembly_checks()
end
