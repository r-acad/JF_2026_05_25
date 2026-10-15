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
    PShellMat2ProjectionFixture.checks()
end
