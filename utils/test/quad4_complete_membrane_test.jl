using Test
module Quad4CompleteMembraneFixture
using Test, OpenJFEM, LinearAlgebra
const S=OpenJFEM.Solver

# Independent stationary enhanced-strain energy. In particular, the integration
# measure is kept in the oracle: a constant stress must do zero work against
# every internal mode on distorted as well as affine quadrilaterals.
function reference(x,A)
    d(r,s)=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]/4
    J0=d(0.,0.)*x;H=zeros(12,12);mean_internal=zeros(3,4)
    for r in (-1/sqrt(3.),1/sqrt(3.)),s in (-1/sqrt(3.),1/sqrt(3.))
        dn=d(r,s);J=dn*x;g=J\dn
        enhanced=(J0\[-2r 0.;0. -2s])*(det(J0)/det(J))
        strain=zeros(3,12)
        for i=1:4
            strain[1,2i-1]=g[1,i];strain[2,2i]=g[2,i]
            strain[3,2i-1]=g[2,i];strain[3,2i]=g[1,i]
        end
        for j=1:2
            strain[1,8+2j-1]=enhanced[1,j];strain[3,8+2j-1]=enhanced[2,j]
            strain[2,8+2j]=enhanced[2,j];strain[3,8+2j]=enhanced[1,j]
        end
        H+=det(J)*strain'*A*strain;mean_internal+=det(J)*strain[:,9:12]
    end
    @test norm(mean_internal)<1e-14 # geometric zero, independent of stiffness scale
    H[1:8,1:8]-H[1:8,9:12]*(H[9:12,9:12]\H[9:12,1:8])
end

function model(dir,x,laminate)
    path=joinpath(dir,"quadrilateral.bdf")
    text="SOL 101\nCEND\nBEGIN BULK\nPARAM,K6ROT,0.\nPARAM,SNORM,0.\n"
    for i=1:4;text*="GRID,$i,,"*join(x[i,:],",")*",0.\n";end
    text*="CQUAD4,1,10,1,2,3,4,0.\n"
    if laminate
        text*="MAT8,1,7.E10,1.5E10,.28,5.E9,4.E9,3.E9,1600.\nPCOMP,10\n+,1,.003,0.,YES\n"
    else
        text*="MAT1,1,7.E10,,.28,2700.\nPSHELL,10,1,.003,1,,1\n"
    end
    write(path,text*"ENDDATA\n");m=OpenJFEM.bdf_to_model(path)
    C=laminate ? OpenJFEM.laminate_plane_stress_qbar(7e10,1.5e10,.28,5e9,0.) :
        (7e10/(1-.28^2))*[1. .28 0.;.28 1. 0.;0. 0. (1-.28)/2]
    m,.003C
end

function checks()
    @test !S.q4_selective_center_membrane_enabled(true,true,nothing)
    @test S.sol105_static_membrane_incomp_enabled()
    shapes=([0. 0.;2. 0.;2. .7;0. .7],
            [0. 0.;2. 0.;2.8 .7;.8 .7],
            [0. 0.;2. 0.;1.7 .7;.3 .7])
    dofs=[6(i-1)+j for i=1:4 for j=1:2]
    mktempdir() do dir
        for x in shapes, laminate in (false,true)
            m,A=model(dir,x,laminate);expected=reference(x,A)
            # Recovered prestress must do exactly the work of the same
            # condensed membrane operator, including distorted cells.
            u=zeros(24);u[dofs]=[.013,-.004,-.006,.008,.003,.011,-.009,.002]
            N,_,weights=OpenJFEM.FEM.quad4_membrane_force_field(x,u,7e10,.28,.003;
                Cm_override=A,use_incompatible_modes=true)
            forces=zeros(8)
            q=1/sqrt(3.);points=((-q,-q),(q,-q),(q,q),(-q,q))
            for (ig,(r,s)) in enumerate(points)
                dn=[-(1-s) 1-s 1+s -(1+s);-(1-r) -(1+r) 1+r 1-r]/4
                g=(dn*x)\dn
                for i=1:4
                    forces[2i-1]+=weights[ig]*(g[1,i]*N[ig,1]+g[2,i]*N[ig,3])
                    forces[2i]+=weights[ig]*(g[2,i]*N[ig,2]+g[1,i]*N[ig,3])
                end
            end
            @test forces≈expected*u[dofs] rtol=3e-12
            K0=nothing
            for sol in (101,103,105)
                m["SOL"]=sol
                K,=S.assemble_stiffness(m;sol101_context=sol==101,
                    sol105_context=sol==105,membrane_incomp=sol==105 ? S.sol105_static_membrane_incomp_enabled() : true)
                @test isapprox(Matrix(K[dofs,dofs]),expected;rtol=3e-12,atol=1e-6)
                @test norm(K-K')<3e-13norm(K)
                if K0===nothing;K0=K;else;@test isapprox(K,K0;rtol=3e-12,atol=1e-6);end
            end
            P=zeros(8,3);R=zeros(8,3)
            for i=1:4
                a,b=x[i,:];P[2i-1,:]=[a,0.,b/2];P[2i,:]=[0.,b,a/2]
                R[2i-1,:]=[1.,0.,-b];R[2i,:]=[0.,1.,a]
            end
            area=abs(sum(x[i,1]*x[mod1(i+1,4),2]-x[mod1(i+1,4),1]*x[i,2] for i=1:4))/2
            actual=Matrix(K0[dofs,dofs])
            @test isapprox(P'*actual*P,area*A;rtol=2e-12,atol=1e-6)
            @test norm(actual*R)<2e-13norm(actual)*norm(R)
            ev=eigvals(Symmetric(actual));@test count(>(1e-10maximum(ev)),ev)==5
            # Arbitrary proper rigid rotation and translation of the model.
            v=normalize([.3,-.7,.2]);angle=.73;V=[0. -v[3] v[2];v[3] 0. -v[1];-v[2] v[1] 0.]
            Q=cos(angle)*I+(1-cos(angle))*v*v'+sin(angle)*V
            moved=deepcopy(m);moved["SOL"]=101
            for g in values(moved["GRIDs"]);g["X"]=Q*g["X"].+[.4,-.8,.2];end
            Kr,=S.assemble_stiffness(moved;sol101_context=true,membrane_incomp=true)
            T=kron(Matrix{Float64}(I,8,8),Q)
            @test isapprox(Matrix(Kr),T*Matrix(K0)*T';rtol=3e-12,atol=1e-6)
        end
    end
end
end

@testset "Complete quadrilateral membrane and constant-stress patch" begin
    Quad4CompleteMembraneFixture.checks()
end
