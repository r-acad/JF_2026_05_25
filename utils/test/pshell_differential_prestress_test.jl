using Test
module PShellDifferentialPrestressFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const S=OpenJFEM.Solver
const F=OpenJFEM.FEM

function gradient(x,r,s)
    shapes(z)=[(1-z[1])*(1-z[2]),(1+z[1])*(1-z[2]),
               (1+z[1])*(1+z[2]),(1-z[1])*(1+z[2])]/4
    dn=ForwardDiff.jacobian(shapes,[r,s])'
    J=dn*x
    J\dn,abs(det(J))
end

function fixture(dir,Q;cyclic=false,sol=105,snorm=20.)
    # Two distinct warped facets share an edge. Averaged nodal normals then
    # exercise the ordinary normal-moment map as well as finite warp.
    X=[0. 0. .02; .8 .1 -.015; 1.7 .2 .025;
       .1 .6 -.02; .9 .7 .025; 1.8 .8 -.01]*Q'
    axes=Q*[cosd(19.) -sind(19.) 0.;sind(19.) cosd(19.) 0.;0. 0. 1.]
    path=joinpath(dir,"projected_pshell.bdf")
    open(path,"w") do io
        println(io,"SOL $sol\nCEND\nBEGIN BULK\nPARAM,SNORM,$snorm\nPARAM,K6ROT,1.")
        for i=1:6;println(io,"GRID,$i,,",join(X[i,:],','));end
        println(io,"CORD2R,501,,0.,0.,0.,",join(axes[:,3],','))
        println(io,"+,",join(axes[:,1],','))
        for (eid,ids) in enumerate(([1,2,5,4],[2,3,6,5]))
            order=cyclic ? circshift(ids,-1) : ids
            println(io,"CQUAD4,$eid,10,",join(order,','),",501")
        end
        println(io,"MAT2,1,9.5E10,1.6E10,4.E9,5.5E10,-2.E9,2.2E10")
        println(io,"MAT1,2,7.E10,,.3\nPSHELL,10,1,.006,1,,2\nENDDATA")
    end
    m=OpenJFEM.bdf_to_model(path);ids=Dict(i=>i for i=1:6)
    R=[Matrix{Float64}(I,3,3) for _=1:6]
    normals=S.compute_snorm_normals(m,ids,X)
    mapping=S.assemble_constraints(m,ids,X,R,Int[],Int[],Float64[])[1]
    m,ids,X,R,normals,mapping
end

function assemble(args,u)
    m,ids,X,R,normals,mapping=args;capture=Dict{Int,Any}()
    fields=(:kg_differential_prestress,:kg_pshell_differential,:N_gp,
        :lc_buf4,:coords3d_local_buf4,:u_elem24,:Cm_override,:snorm_pq_kg,:Kg_loc)
    G=Matrix(S.assemble_geometric_stiffness(m,ids,X,R,36,u,normals,mapping;
        geometric_capture=(eid,data)->(capture[eid]=deepcopy(Dict(k=>data[k] for k in fields)))))
    G,capture
end

function checks()
    mktempdir() do dir
        I3=Matrix{Float64}(I,3,3)
        a=.53; b=.31
        Q=[cos(a) -sin(a) 0.;sin(a) cos(a) 0.;0. 0. 1.]*
          [1. 0. 0.;0. cos(b) -sin(b);0. sin(b) cos(b)]
        T=kron(Matrix{Float64}(I,12,12),Q)
        u=1e-4sin.(.61collect(1.:36.))
        for snorm in (0.,20.)
            base=fixture(dir,I3;snorm=snorm)
            G,capture=assemble(base,u)
            @test isapprox(G,G';rtol=2e-12,atol=1e-8)
            for c in values(capture)
                @test c[:kg_pshell_differential]
                @test c[:kg_differential_prestress]
                x=c[:lc_buf4]; xyz=c[:coords3d_local_buf4]
                W=F.quad4_finite_warp_displacement_map(x,xyz)
                up=W===nothing ? c[:u_elem24] : W*c[:u_elem24]
                U=reshape(up,6,4);d0,_=gradient(x,0.,0.)
                q=inv(sqrt(3.));points=((-q,-q),(q,-q),(q,q),(-q,q))
                N=zeros(4,3);weights=zeros(4)
                for (i,(r,s)) in enumerate(points)
                    d,w=gradient(x,r,s);g=U*d';g0=U*d0'
                    N[i,:].=c[:Cm_override]*[g[1,1],g[2,2],g0[1,2]+g0[2,1]]
                    weights[i]=w
                end
                @test isapprox(c[:N_gp],N;rtol=3e-12,atol=1e-8)
                # The transverse block is the Hessian of frozen membrane
                # work through independently differentiated assumed gradients.
                function potential(v)
                    energy=zero(eltype(v))
                    for (i,(r,s)) in enumerate(points)
                        dx,_=gradient(x,0.,s);dy,_=gradient(x,r,0.)
                        gx=dot(dx[1,:],v);gy=dot(dy[2,:],v)
                        energy+=weights[i]*(N[i,1]*gx^2+2N[i,3]*gx*gy+N[i,2]*gy^2)/2
                    end
                    energy
                end
                H=ForwardDiff.hessian(potential,zeros(4))
                P=F.quad4_physical_displacement_map(x,xyz,c[:snorm_pq_kg])
                primitive=P'\c[:Kg_loc]/P
                @test isapprox(primitive[[3,9,15,21],[3,9,15,21]],H;rtol=3e-11,atol=1e-8)
            end
            rotated=fixture(dir,Q;snorm=snorm)
            Gr,_=assemble(rotated,T*u)
            @test isapprox(Gr,T*G*T';rtol=3e-10,atol=1e-8)
            cyclic=fixture(dir,I3;snorm=snorm,cyclic=true)
            Gc,_=assemble(cyclic,u)
            @test isapprox(Gc,G;rtol=3e-10,atol=1e-8)
            legacy,old=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS"=>"false") do
                assemble(base,u)
            end
            @test all(!c[:kg_differential_prestress] for c in values(old))
            @test norm(legacy-G)>1e-8norm(G)
            opted,oldwarp=withenv("JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED"=>"false") do
                assemble(base,u)
            end
            @test all(!c[:kg_differential_prestress] for c in values(oldwarp))
            @test isapprox(opted,legacy;rtol=1e-13,atol=1e-8)
            nl=fixture(dir,I3;snorm=snorm,sol=106)
            _,nonlinear=assemble(nl,u)
            @test all(!c[:kg_differential_prestress] for c in values(nonlinear))
        end
    end
end
end

@testset "Warped anisotropic PSHELL differential work and invariance" begin
    PShellDifferentialPrestressFixture.checks()
end
