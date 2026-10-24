using Test, LinearAlgebra, OpenJFEM

module PShellMat2ProjectionFixture
using Test, LinearAlgebra, OpenJFEM
const S = OpenJFEM.Solver
const C = 1e9 .* [110.0 20.0 5.0;20.0 70.0 3.0;5.0 3.0 30.0]
const h = .02

function frame(x)
    z=normalize(cross(x[3,:]-x[1,:],x[4,:]-x[2,:]))
    a=normalize(normalize(x[3,:]-x[1,:])-normalize(x[4,:]-x[2,:]))
    reduce(vcat,permutedims.((a,cross(z,a),z)))
end
function material_frame(x,theta)
    R=frame(x);z=R[3,:];a=normalize(x[2,:]-x[1,:]);b=cross(z,a)
    mx=cosd(theta)*a+sind(theta)*b
    reduce(vcat,permutedims.((mx,cross(z,mx),z)))
end
function local_constitutive(R,Rm)
    P=(Rm*R')[1:2,1:2];L=zeros(3,3)
    for k=1:3
        e=zeros(3);e[k]=1;E=P*[e[1] e[3]/2;e[3]/2 e[2]]*P'
        L[:,k]=[E[1,1],E[2,2],2E[1,2]]
    end
    h*L'*C*L
end
# Independent engineering-strain interpolation; no production shape/frame
# helper is used for this energy oracle.
function strain(x,r,s)
    d=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]/4
    J=d*x;g=J\d;B=zeros(3,8)
    B[1,1:2:8]=g[1,:];B[2,2:2:8]=g[2,:]
    B[3,1:2:8]=g[2,:];B[3,2:2:8]=g[1,:]
    B,det(J)
end
function oracle(x,Rm)
    R=frame(x);xy=((x.-sum(x;dims=1)/4)*R')[:,1:2]
    A=local_constitutive(R,Rm);Bc,_=strain(xy,0.,0.);K=zeros(8,8)
    for r in (-1/sqrt(3.),1/sqrt(3.)),s in (-1/sqrt(3.),1/sqrt(3.))
        B,j=strain(xy,r,s);B[3,:]=Bc[3,:];K+=B'*A*B*j
    end
    K,R,xy,A
end
function assemble(dir,x,theta;mcid=false,connectivity=[1,2,3,4],Rm=material_frame(x,theta))
    path=joinpath(dir,"mat2.bdf")
    open(path,"w") do io
        print(io,"SOL 101\nCEND\nBEGIN BULK\nPARAM,K6ROT,0.\nPARAM,SNORM,0.\n")
        for k=1:4;println(io,join(["GRID",k,"",x[k,:]...],','));end
        println(io,"MAT2,1,1.1E11,2.E10,5.E9,7.E10,3.E9,3.E10")
        println(io,"MAT1,2,7.E10,,.3\nPSHELL,1,1,.02,1,,2")
        if mcid
            println(io,join(["CORD2R",100,0,0.,0.,0.,Rm[3,:]...],','))
            println(io,join(["+",Rm[1,:]...],','))
        end
        println(io,join(["CQUAD4",1,1,connectivity...,mcid ? 100 : Float64(theta)],','))
        println(io,"ENDDATA")
    end
    model=OpenJFEM.bdf_to_model(path);capture=S.AnalyticShellCapture(model)
    assembled=S.assemble_stiffness(model;membrane_incomp=true,sol101_context=true,shell_capture=capture)
    ids=assembled[2];dofs=[6(ids[i]-1)+j for i=1:4 for j=1:6]
    Matrix(assembled[1][dofs,dofs]),model,capture,assembled
end
function checks()
    select=S.q4_pshell_mat2_membrane_projection
    @test select(true,0.)
    @test !select(false,0.)
    @test !select(true,1e-4)
    @test !select(true,0.;Bmb=zeros(3,3))
    @test !select(true,0.;snorm_pq=ones(4,2))
    @test !select(true,0.;curvature_membrane=zeros(3))
    @test !select(true,0.;kernel_mode="mitc4_3d")
    @test !withenv("JFEM_Q4_PSHELL_MAT2_MEMBRANE_SELC"=>"0") do;select(true,0.);end
    uv=[6(i-1)+j for i=1:4 for j=1:2]
    shapes=([0. 0.;2. 0.;2. 1.;0. 1.],
            [0. 0.;1.5 0.;2.1 .8;.6 .8],
            [0. 0.;1.2 0.;.85 1.1;.15 1.1])
    angle=.43;tilt=[1. 0. 0.;0. cos(angle) -sin(angle);0. sin(angle) cos(angle)]
    mktempdir() do dir
        for (index,shape) in enumerate(shapes),theta in (0.,23.)
            x=hcat(shape,zeros(4));index==3 && (x=x*tilt')
            Rm=material_frame(x,theta);expected,R,xy,A=oracle(x,Rm)
            K,model,capture,assembled=assemble(dir,x,theta;Rm=Rm)
            T=kron(Matrix{Float64}(I,8,8),R);localK=T*K*T'
            @test isapprox(localK[uv,uv],expected;rtol=2e-12,atol=1e-7)
            @test norm(K-K')<3e-13norm(K)
            @test eigmin(Symmetric(K))>-2e-13norm(K)
            @test_throws ArgumentError S.analytic_shell_constitutive(model,1)
            for axis=1:3
                e=zeros(3);e[axis]=1.;u=zeros(24);q=zeros(24)
                for k=1:4
                    u[6k-5:6k-3]=e;q[6k-5:6k-3]=cross(e,x[k,:]);q[6k-2:6k]=e
                end
                @test norm(K*u)<3e-13norm(K)
                @test norm(K*q)<3e-13norm(K)*max(norm(x),1.)
            end
            # Constant affine strains reproduce the exact continuum energy.
            area=sum(strain(xy,r,s)[2] for r in (-1/sqrt(3.),1/sqrt(3.)),s in (-1/sqrt(3.),1/sqrt(3.)))
            for eps in ([1.,0.,0.],[0.,1.,0.],[0.,0.,1.],[.3,-.2,.7])
                u=[v for k=1:4 for v in (eps[1]*xy[k,1]+eps[3]*xy[k,2]/2,eps[2]*xy[k,2]+eps[3]*xy[k,1]/2)]
                @test isapprox(dot(u,expected*u),area*dot(eps,A*eps);rtol=2e-13)
            end
            if index==2 && theta==23.
                Km,_,_,_=assemble(dir,x,theta;mcid=true,Rm=Rm)
                @test isapprox(Km,K;rtol=2e-12)
                Kp,_,_,_=assemble(dir,x,theta;mcid=true,Rm=Rm,connectivity=[2,3,4,1])
                @test isapprox((T*Kp*T')[uv,uv],expected;rtol=2e-12)
                # Inspect the actual Kg preload recovery, not a surrogate.
                u=1e-3sin.(collect(1.:24.));captured=Dict{Symbol,Any}()
                S.assemble_geometric_stiffness(model,assembled[2],assembled[3],assembled[5],assembled[4],u,assembled[8],assembled[7];
                    geometric_capture=(eid,data)->merge!(captured,data))
                @test captured[:kg_mat2_membrane_selc]
                @test captured[:kg_membrane_selc]
                @test isapprox(captured[:Cm_override],A;rtol=2e-13)
                ul=T*u;Bc,_=strain(xy,0.,0.)
                for (gp,(r,s)) in enumerate(((-1/sqrt(3.),-1/sqrt(3.)),(1/sqrt(3.),-1/sqrt(3.)),(1/sqrt(3.),1/sqrt(3.)),(-1/sqrt(3.),1/sqrt(3.))))
                    B,_=strain(xy,r,s);B[3,:]=Bc[3,:]
                    @test isapprox(captured[:N_gp][gp,:],A*B*ul[uv];rtol=2e-12,atol=1e-6)
                end
            end
        end
    end
end
end

@testset "Planar MAT2 membrane material frame and variational projection" begin
    # Keep the independently derived legacy energy as an explicit option.
    withenv("JFEM_Q4_PSHELL_MAT2_MEMBRANE_SELC"=>"true") do
        PShellMat2ProjectionFixture.checks()
    end
end


module PShellMat2CompleteFixture
using Test, LinearAlgebra, OpenJFEM
using ..PShellMat2ProjectionFixture: frame, material_frame, local_constitutive, strain, assemble
const S=OpenJFEM.Solver

# Independent 12-coordinate energy before the four internal coordinates are
# statically condensed. The Jacobian ratio makes every enhanced field mean-zero.
function complete_reference(x,A)
    dn(r,s)=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]/4
    J0=dn(0.,0.)*x;H=zeros(12,12);fields=[];weights=Float64[]
    q=1/sqrt(3.)
    for (r,s) in ((-q,-q),(q,-q),(q,q),(-q,q))
        d=dn(r,s);J=d*x;g=J\d
        enhanced=(J0\[-2r 0.;0. -2s])*(det(J0)/det(J))
        B=zeros(3,12)
        for k=1:4
            B[1,2k-1]=g[1,k];B[2,2k]=g[2,k]
            B[3,2k-1]=g[2,k];B[3,2k]=g[1,k]
        end
        for k=1:2
            B[1,8+2k-1]=enhanced[1,k];B[3,8+2k-1]=enhanced[2,k]
            B[2,8+2k]=enhanced[2,k];B[3,8+2k]=enhanced[1,k]
        end
        H+=det(J)*B'*A*B;push!(fields,B);push!(weights,det(J))
    end
    P=vcat(Matrix{Float64}(I,8,8),-(H[9:12,9:12]\H[9:12,1:8]))
    P'*H*P,P,fields,weights
end

function checks()
    @test !S.q4_pshell_mat2_membrane_projection(true,0.)
    @test S.q4_pshell_material_frame(true,0.)
    @test !S.q4_pshell_material_frame(false,0.)
    @test !S.q4_pshell_material_frame(true,1e-4)
    @test !S.q4_pshell_material_frame(true,0.;Bmb=zeros(3,3))
    @test !S.q4_pshell_material_frame(true,0.;snorm_pq=ones(4,2))
    @test !S.q4_pshell_material_frame(true,0.;curvature_membrane=zeros(3))
    @test !S.q4_pshell_material_frame(true,0.;kernel_mode="mitc4_3d")
    @test withenv("JFEM_Q4_PSHELL_MAT2_MEMBRANE_SELC"=>"true") do
        S.q4_pshell_mat2_membrane_projection(true,0.)
    end
    uv=[6(k-1)+j for k=1:4 for j=1:2]
    shapes=([0. 0.;2. 0.;2. 1.;0. 1.],
            [0. 0.;1.5 0.;2.1 .8;.6 .8],
            [0. 0.;1.2 0.;.85 1.1;.15 1.1])
    angle=.43;tilt=[1. 0. 0.;0. cos(angle) -sin(angle);0. sin(angle) cos(angle)]
    mktempdir() do dir
        for (index,shape) in enumerate(shapes),theta in (0.,23.)
            x=hcat(shape,zeros(4));index==3 && (x=x*tilt')
            Rm=material_frame(x,theta);R=frame(x);xy=((x.-sum(x;dims=1)/4)*R')[:,1:2]
            A=local_constitutive(R,Rm);expected,P,fields,weights=complete_reference(xy,A)
            K,model,capture,assembled=assemble(dir,x,theta;Rm=Rm)
            T=kron(Matrix{Float64}(I,8,8),R);localK=T*K*T'
            @test isapprox(localK[uv,uv],expected;rtol=3e-12,atol=1e-6)
            call=only(only(values(capture.contexts)).calls)
            @test call.kwargs[:membrane_incomp]
            @test !call.kwargs[:membrane_shear_center_row]
            @test norm(K-K')<3e-13norm(K)
            @test eigmin(Symmetric(K))>-2e-13norm(K)
            @test count(>(1e-10opnorm(expected)),eigvals(Symmetric(expected)))==5
            for axis=1:3
                e=zeros(3);e[axis]=1.;u=zeros(24);r=zeros(24)
                for k=1:4
                    u[6k-5:6k-3]=e;r[6k-5:6k-3]=cross(e,x[k,:]);r[6k-2:6k]=e
                end
                @test norm(K*u)<3e-13norm(K)
                @test norm(K*r)<3e-13norm(K)*max(norm(x),1.)
            end
            for eps in ([1.,0.,0.],[0.,1.,0.],[0.,0.,1.],[.3,-.2,.7])
                u=[v for k=1:4 for v in (eps[1]*xy[k,1]+eps[3]*xy[k,2]/2,eps[2]*xy[k,2]+eps[3]*xy[k,1]/2)]
                @test isapprox(dot(u,expected*u),sum(weights)*dot(eps,A*eps);rtol=2e-12)
                @test norm((P*u)[9:12])<2e-12norm(u)
            end
            # Shared material orientation with exact stationary force recovery.
            u=1e-3sin.(collect(1.:24.));captured=Dict{Symbol,Any}()
            S.assemble_geometric_stiffness(model,assembled[2],assembled[3],assembled[5],assembled[4],u,assembled[8],assembled[7];
                geometric_capture=(eid,data)->merge!(captured,data))
            @test captured[:kg_pshell_material_frame]
            @test !captured[:kg_mat2_membrane_selc]
            @test !captured[:kg_membrane_selc]
            @test isapprox(captured[:Cm_override],A;rtol=2e-13)
            ul=T*u;complete=P*ul[uv];forces=zeros(8)
            @test !captured[:elem_membrane_incomp_kg]
            for gp=1:4
                n=A*fields[gp]*complete
                # The established differential-prestress default uses compatible
                # strains here; the independent elastic work oracle uses the
                # fully condensed Wilson coordinates below.
                nc=A*fields[gp][:,1:8]*ul[uv]
                @test isapprox(captured[:N_gp][gp,:],nc;rtol=3e-12,atol=1e-6)
                forces+=weights[gp]*fields[gp][:,1:8]'*n
            end
            @test isapprox(forces,expected*ul[uv];rtol=3e-12,atol=1e-6)
            withenv("JFEM_KG_MEMBRANE_INCOMP"=>"true") do
                enhanced=Dict{Symbol,Any}()
                S.assemble_geometric_stiffness(model,assembled[2],assembled[3],assembled[5],assembled[4],u,assembled[8],assembled[7];
                    geometric_capture=(eid,data)->merge!(enhanced,data))
                @test enhanced[:elem_membrane_incomp_kg]
                for gp=1:4
                    n=A*fields[gp]*complete
                    @test isapprox(enhanced[:N_gp][gp,:],n;rtol=3e-12,atol=1e-6)
                end
            end
            if index==2 && theta==23.
                Km,_,_,_=assemble(dir,x,theta;mcid=true,Rm=Rm)
                @test isapprox(Km,K;rtol=3e-12)
                Kp,_,_,_=assemble(dir,x,theta;mcid=true,Rm=Rm,connectivity=[2,3,4,1])
                @test isapprox((T*Kp*T')[uv,uv],expected;rtol=3e-12)
                for sol in (103,105,106)
                    model["SOL"]=sol
                    Ksol,=S.assemble_stiffness(model;membrane_incomp=true,sol101_context=false,sol105_context=sol==105)
                    @test isapprox(Matrix(Ksol),K;rtol=3e-12,atol=1e-6)
                end
            end
        end
    end
end
end

@testset "Planar MAT2 complete membrane basis and material-frame recovery" begin
    PShellMat2CompleteFixture.checks()
end

using Test
module PShellGeometricRepresentationFixture
using Test,OpenJFEM,LinearAlgebra,ForwardDiff
const S=OpenJFEM.Solver
const h=.02
rx(a)=[1. 0. 0.;0. cosd(a) -sind(a);0. sind(a) cosd(a)]
ry(a)=[cosd(a) 0. sind(a);0. 1. 0.;-sind(a) 0. cosd(a)]
function frame(x)
    z=normalize(cross(x[3,:]-x[1,:],x[4,:]-x[2,:]))
    a=normalize(normalize(x[3,:]-x[1,:])-normalize(x[4,:]-x[2,:]))
    reduce(vcat,permutedims.((a,cross(z,a),z)))
end
function material_frame(x,theta)
    R=frame(x);z=R[3,:];a=normalize(x[2,:]-x[1,:]);b=cross(z,a)
    mx=cosd(theta)*a+sind(theta)*b
    reduce(vcat,permutedims.((mx,cross(z,mx),z)))
end
function law(kind)
    if kind in (:iso,:iso_mat2)
        E=7e10;nu=.3;C=E/(1-nu^2)*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
        card="MAT1,1,$E,,$nu,2500."
    elseif kind in (:ortho,:ortho_mat2)
        E1=145e9;E2=7.6e9;nu=.3;G=3.6e9;den=1-nu^2*E2/E1
        C=[E1/den nu*E2/den 0.;nu*E2/den E2/den 0.;0. 0. G]
        card="MAT8,1,$E1,$E2,$nu,$G,$G,$G,2500."
    else
        C=1e9*[120. 8. 4.;8. 20. 2.;4. 2. 5.];card=""
    end
    if kind in (:general,:iso_mat2,:ortho_mat2)
        card="MAT2,1,"*join((C[1,1],C[1,2],C[1,3],C[2,2],C[2,3],C[3,3],2500.),',')
    end
    C,card
end
function constitutive(C,R,Rm)
    P=(Rm*R')[1:2,1:2];L=zeros(3,3)
    for k=1:3
        e=zeros(3);e[k]=1;E=P*[e[1] e[3]/2;e[3]/2 e[2]]*P'
        L[:,k]=[E[1,1],E[2,2],2E[1,2]]
    end
    h*L'*C*L
end
function fixture(dir,x,kind,theta,u;Q=Matrix{Float64}(I,3,3),shift=zeros(3),order=[1,2,3,4],mcid=false)
    X=x*Q'.+shift';Rm=material_frame(x,theta)*Q';C,card=law(kind)
    path=joinpath(dir,"pshell.bdf")
    open(path,"w") do io
        println(io,"SOL 105\nCEND\nBEGIN BULK\nPARAM,SNORM,0.\nPARAM,K6ROT,0.")
        for i=1:4;println(io,"GRID,$i,,",join(X[i,:],','));end
        println(io,card,"\nMAT1,2,7.E10,,.3,2500.\nPSHELL,1,1,$h,1,,2")
        if mcid
            println(io,"CORD2R,501,,0.,0.,0.,",join(Rm[3,:],','));println(io,"+,",join(Rm[1,:],','))
        end
        println(io,"CQUAD4,1,1,",join(order,','),",",mcid ? "501" : string(theta),"\nENDDATA")
    end
    model=OpenJFEM.bdf_to_model(path)
    ass=S.assemble_stiffness(model;membrane_incomp=true,sol105_context=true)
    K,ids,coords,ndof,nodeR,_,mapping,normals,_=ass
    Tg=kron(Matrix{Float64}(I,8,8),Q);state=Tg*u;data=Dict{Symbol,Any}()
    Kg=S.assemble_geometric_stiffness(model,ids,coords,nodeR,ndof,state,normals,mapping;
        geometric_capture=(eid,c)->merge!(data,c))
    Matrix(K),Matrix(Kg),data,X,Rm,C
end
function derivs(x,r,s)
    shapes(z)=[(1-z[1])*(1-z[2]),(1+z[1])*(1-z[2]),(1+z[1])*(1+z[2]),(1-z[1])*(1+z[2])]/4
    dn=ForwardDiff.jacobian(shapes,[r,s])';J=dn*x
    J\dn,abs(det(J))
end
function checks()
    shapes=([0. 0. 0.;2. 0. 0.;2. 1. 0.;0. 1. 0.],
        [0. 0. 0.;1.5 0. 0.;2.1 .8 0.;.6 .8 0.],
        [0. 0. 0.;1.2 0. 0.;.85 1.1 0.;.15 1.1 0.])
    u=1e-4*sin.(collect(1.:24.));q=1/sqrt(3.);uv=[6(i-1)+j for i=1:4 for j=1:2]
    Q=ry(31.)*rx(47.);Tg=kron(Matrix{Float64}(I,8,8),Q)
    mktempdir() do dir
        for x in shapes,kind in (:general,:ortho,:iso)
            K,G,data,X,Rm,C=fixture(dir,x,kind,23.,u)
            @test data[:kg_pshell_material_frame]
            @test data[:kg_differential_prestress]
            @test !data[:kg_mat2_membrane_selc]
            R=frame(X);T=kron(Matrix{Float64}(I,8,8),R);xy=((X.-sum(X;dims=1)/4)*R')[:,1:2]
            A=constitutive(C,R,Rm);ul=reshape(T*u,6,4);d0,_=derivs(xy,0.,0.)
            N=zeros(4,3);weights=zeros(4)
            for (i,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
                d,weights[i]=derivs(xy,r,s);du=ul*d';dc=ul*d0'
                N[i,:]=A*[du[1,1],du[2,2],dc[1,2]+dc[2,1]]
            end
            @test isapprox(data[:N_gp],N;rtol=3e-12,atol=1e-7)
            function potential(v)
                energy=zero(eltype(v))
                for (i,(r,s)) in enumerate(((-q,-q),(q,-q),(q,q),(-q,q)))
                    dx,_=derivs(xy,0.,s);dy,_=derivs(xy,r,0.)
                    gx=dot(dx[1,:],v);gy=dot(dy[2,:],v)
                    energy+=weights[i]*(N[i,1]*gx^2+2N[i,3]*gx*gy+N[i,2]*gy^2)/2
                end
                energy
            end
            H=ForwardDiff.hessian(potential,zeros(4));Gl=T*G*T'
            @test isapprox(Gl[[3,9,15,21],[3,9,15,21]],H;rtol=3e-11,atol=1e-7)
            @test isapprox(G,G';rtol=2e-12,atol=1e-8)
            Kr,Gr,_,_,_,_=fixture(dir,x,kind,23.,u;Q=Q,shift=[3.,-2.,4.])
            @test isapprox(Kr,Tg*K*Tg';rtol=3e-11,atol=1e-6)
            @test isapprox(Gr,Tg*G*Tg';rtol=3e-11,atol=1e-7)
            Km,Gm,_,_,_,_=fixture(dir,x,kind,23.,u;mcid=true)
            @test isapprox(Km,K;rtol=3e-11,atol=1e-6)
            @test isapprox(Gm,G;rtol=3e-11,atol=1e-7)
            Kc,Gc,_,_,_,_=fixture(dir,x,kind,23.,u;mcid=true,order=[2,3,4,1])
            @test isapprox(Kc,K;rtol=3e-11,atol=1e-6)
            @test isapprox(Gc,G;rtol=3e-11,atol=1e-7)
            if kind != :general
                Km2,Gm2,_,_,_,_=fixture(dir,x,kind==:iso ? :iso_mat2 : :ortho_mat2,23.,u)
                @test isapprox(Km2,K;rtol=3e-11,atol=1e-6)
                @test isapprox(Gm2,G;rtol=3e-11,atol=1e-7)
            end
        end
    end
end
end
@testset "Ordinary planar PSHELL geometric work and material representations" begin
    PShellGeometricRepresentationFixture.checks()
end
