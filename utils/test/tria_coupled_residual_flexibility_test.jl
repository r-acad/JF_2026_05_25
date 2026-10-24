using Test

module TriaCoupledResidualFlexibilityFixture
using Test, LinearAlgebra, ForwardDiff, OpenJFEM
const F = OpenJFEM.FEM

function isotropic(E,nu)
    E/(1-nu^2)*[one(E) nu zero(E);nu one(E) zero(E);zero(E) zero(E) (1-nu)/2]
end

function section(h; orthotropic=false)
    if orthotropic
        C1 = [135. 2.3 0.; 2.3 8.6 0.; 0. 0. 4.8]*1e9
        C2 = [36. 21. 15.; 21. 22. 8.; 15. 8. 17.]*1e9
    else
        C1=isotropic(70e9,.3);C2=isotropic(130e9,.25)
    end
    A=(h/2)*(C1+C2)
    B=(h^2/8)*(C2-C1)
    D=(h^3/24)*(C1+C2)
    Cs=(5h/12)*(C1[3,3]+C2[3,3])*Matrix{typeof(h)}(I,2,2)
    A,B,D,Cs
end

kernel(X,A,B,D,Cs,h)=F.stiffness_tria3_matrices_generic(X,A,D,Cs,h,one(h);Bmb=B,k6rot=0.)

function checks()
    @test F.tria3_neutral_strip_rigidity(4.,2.,3.) == 2.
    @test_throws ArgumentError F.tria3_neutral_strip_rigidity(0.,2.,3.)
    @test_throws ArgumentError F.tria3_neutral_strip_rigidity(4.,4.,3.)
    @test_throws ArgumentError F.tria3_neutral_strip_rigidity(4.,Inf,3.)
    for (a,b,d) in ((4.,2.,3.),(2e9,3e5,8e3),(7e-9,-2e-12,9e-15))
        f(x)=F.tria3_neutral_strip_rigidity(a*(1+.2x),b*(1-.3x),d*(1+.4x))
        @test isapprox(ForwardDiff.derivative(f,0.),.4d+.6b^2/a+.2b^2/a;rtol=2e-14)
        eps=-b/a
        @test isapprox(a*eps^2+2b*eps+d,f(0.);rtol=2e-14)
    end
    for orthotropic in (false,true), shape in ([0. 0.;.8 0.;.1 .6],[0. 0.;.08 0.;.8 .6])
        h=.004
        A,B,D,Cs=section(h;orthotropic=orthotropic)
        K=kernel(shape,A,B,D,Cs,h)
        @test isapprox(K,K';rtol=1e-13)
        @test minimum(eigvals(Symmetric(K))) >= -2e-12*opnorm(K)
        for i in 1:3, rotational in (false,true)
            dir=zeros(3);dir[i]=1.;u=zeros(18)
            for n in 1:3
                point=[shape[n,1],shape[n,2],0.]
                u[6n-5:6n-3]=rotational ? cross(dir,point) : dir
                rotational && (u[6n-2:6n]=dir)
            end
            @test norm(K*u) <= 3e-12*opnorm(K)*norm(u)
        end
        # Material and length units preserve the physical energy.
        factor=7.3
        @test isapprox(kernel(shape,factor*A,factor*B,factor*D,factor*Cs,h),factor*K;rtol=2e-10)
        scale=9.;As,Bs,Ds,Css=section(scale*h;orthotropic=orthotropic)
        L=Diagonal(repeat([scale,scale,scale,1.,1.,1.],3))
        @test isapprox(L'*kernel(scale*shape,As,Bs,Ds,Css,scale*h)*L,scale^3*K;rtol=2e-10)
        # The strip flexibility is even in B; only compatible cross blocks change.
        Km=kernel(shape,A,-B,D,Cs,h)
        m=[1,2,7,8,13,14];b=[3,4,5,9,10,11,15,16,17]
        @test K[b,b] == Km[b,b]
        @test K[m,m] == Km[m,m]
        @test K[m,b] == -Km[m,b]
        @test kernel(shape,A,nothing,D,Cs,h) == kernel(shape,A,zero(B),D,Cs,h)
        # B may carry the only dual seed. At B=0 residual flexibility is even,
        # while the compatible membrane/bending cross block has a finite slope.
        for seed in (0.,.7)
            dual=ForwardDiff.Dual(seed,1.)
            kd=kernel(shape,A,dual*B,D,Cs,h)
            derivative=map(v->ForwardDiff.partials(v)[1],kd)
            step=1e-4
            finite=(kernel(shape,A,(seed+step)*B,D,Cs,h)-kernel(shape,A,(seed-step)*B,D,Cs,h))/(2step)
            @test isapprox(derivative,finite;rtol=4e-6)
            if seed==0
                @test iszero(norm(derivative[b,b]))
                @test isapprox(derivative[m,b],K[m,b];rtol=2e-14)
            end
        end
        # Reference-plane translation is a congruence, not a new physical beam.
        # High precision separates this identity from ill-conditioned tying inverses.
        setprecision(256) do
            x=BigFloat.(shape);aa=BigFloat.(A);bb=BigFloat.(B);dd=BigFloat.(D);ss=BigFloat.(Cs);hh=BigFloat(h)
            original=kernel(x,aa,bb,dd,ss,hh)
            H=zeros(BigFloat,18,18)
            for n in 0:2;H[6n+1,6n+5]=1;H[6n+2,6n+4]=-1;end
            for z in (-.37hh,.13hh,.61hh)
                shifted=kernel(x,aa,bb-z*aa,dd-2z*bb+z^2*aa,ss,hh)
                transform=Matrix{BigFloat}(I,18,18)+z*H
                @test isapprox(transform'*shifted*transform,original;rtol=big"1e-55")
            end
            # Exact differential of the same congruence: dK/dz=-H'K-KH.
            dualz=ForwardDiff.Dual(zero(hh),one(hh))
            kd=kernel(x,aa,bb-dualz*aa,dd-2dualz*bb+dualz^2*aa,ss,hh)
            derivative=map(v->ForwardDiff.partials(v)[1],kd)
            @test isapprox(derivative,-H'*original-original*H;rtol=big"1e-52")
        end
        # Constitutive thickness derivatives propagate through the same kernel.
        u=.001sin.(collect(1.:18.))
        energy(t)=begin a,b,d,s=section(t;orthotropic=orthotropic);dot(u,kernel(shape,a,b,d,s,t)*u) end
        exact=ForwardDiff.derivative(energy,h);step=1e-4h
        check=(energy(h+step)-energy(h-step))/(2step)
        @test isfinite(exact)
        @test isapprox(exact,check;rtol=3e-6)
    end
end
end

@testset "Coupled triangle neutral-surface residual bending flexibility" begin
    TriaCoupledResidualFlexibilityFixture.checks()
end


using Test

module TriaCoupledRecoveryFixture
using Test,LinearAlgebra,StaticArrays,OpenJFEM
const S=OpenJFEM.Solver

function checks()
    mktempdir() do dir
        deck=joinpath(dir,"coupled_triangle.bdf")
        write(deck,join(["SOL 101","CEND","SPC=1","LOAD=1","BEGIN BULK",
            "PARAM,K6ROT,100.","PARAM,SNORM,0.",
            "GRID,1,,0.,0.,0.","GRID,2,,.8,0.,0.","GRID,3,,.1,.6,0.",
            "CTRIA3,1,1,1,2,3,23.",
            "MAT8,1,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.",
            "PCOMP,1,,,,,,,","+,1,.001,0.,YES,1,.003,70.,YES",
            "SPC1,1,123456,1","FORCE,1,2,0,1.,0.,0.,1.","ENDDATA"],'\n')*"\n")
        base=OpenJFEM.bdf_to_model(deck)
        property=base["PSHELLs"]["1"]
        A=zeros(3,3);B=zeros(3,3);D=zeros(3,3)
        for ply in property["PLY_DATA"]
            mat=base["MATs"][string(ply["mid"])]
            Q=OpenJFEM.laminate_plane_stress_qbar(mat["E1"],mat["E2"],mat["NU12"],mat["G12"],deg2rad(ply["theta"]+23.))
            lower,upper=ply["z_bot"],ply["z_top"]
            A+=Q*(upper-lower);B+=Q*(upper^2-lower^2)/2;D+=Q*(upper^3-lower^3)/3
        end
        axis=normalize([1.,2.,3.]);angle=.63
        crossmat=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
        rotation=cos(angle)*I+(1-cos(angle))*axis*axis'+sin(angle)*crossmat
        for R in (Matrix{Float64}(I,3,3),rotation)
            model=deepcopy(base)
            for node in values(model["GRIDs"]);node["X"]=R*node["X"];end
            _,ids,X,ndof,node_R,_,mapping,normals,_=S.assemble_stiffness(model;snorm_angle_override=0.)
            for (eps,kap) in (([.0002,0.,0.],zeros(3)),(zeros(3),[0.,-.003,0.]),
                    ([.0002,-.0001,.0003],[.003,-.002,.004]))
                u=zeros(ndof)
                for (nid,i) in ids
                    x,y,z=base["GRIDs"][string(nid)]["X"]
                    u[6i-5:6i-3]=R*[eps[1]*x+eps[3]*y/2,eps[2]*y+eps[3]*x/2,0.]
                    u[6i-2:6i]=R*[-kap[2]*y-kap[3]*x/2,kap[1]*x+kap[3]*y/2,0.]
                end
                rows=Dict{String,Any}(k=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
                S.recover_shell_stresses!(model,ids,X,node_R,u,normals,Dict{Int,Float64}(),rows)
                force=only(rows["forces"]["tria3"])
                @test isapprox([force[k] for k in ("fx","fy","fxy")],A*eps+B*kap;rtol=3e-11,atol=1e-10)
                @test isapprox([force[k] for k in ("mx","my","mxy")],-B'*eps-D*kap;rtol=3e-11,atol=1e-10)
                # Integrating the ply face stresses gives the same coupled
                # force/moment law. The unrelated Q estimator is not asserted.
                expectedN=zeros(3);expectedM=zeros(3)
                for ply in property["PLY_DATA"]
                    mat=base["MATs"][string(ply["mid"])]
                    Q=OpenJFEM.laminate_plane_stress_qbar(mat["E1"],mat["E2"],mat["NU12"],mat["G12"],deg2rad(ply["theta"]+23.))
                    lo,hi=ply["z_bot"],ply["z_top"]
                    expectedN+=Q*((hi-lo)*eps+(hi^2-lo^2)/2*kap)
                    expectedM-=Q*((hi^2-lo^2)/2*eps+(hi^3-lo^3)/3*kap)
                end
                @test isapprox([force[k] for k in ("fx","fy","fxy")],expectedN;rtol=3e-11,atol=1e-10)
                @test isapprox([force[k] for k in ("mx","my","mxy")],expectedM;rtol=3e-11,atol=1e-10)
            end
        end
    end
end
end

@testset "Coupled triangle membrane and bending resultants" begin
    TriaCoupledRecoveryFixture.checks()
end


using Test
module TriaCoupledRecoverySupplement
using Test,LinearAlgebra,StaticArrays,OpenJFEM
const S=OpenJFEM.Solver
function checks()
    mktempdir() do dir
        axis=normalize([1.,2.,3.]);a=.63
        J=[0. -axis[3] axis[2];axis[3] 0. -axis[1];-axis[2] axis[1] 0.]
        rotated=cos(a)*I+(1-cos(a))*axis*axis'+sin(a)*J
        X0=[0. 0. 0.;.8 0. 0.;.1 .6 0.]
        for R in (Matrix{Float64}(I,3,3),rotated),mcid in (false,true),offset in (0.,.003,-.002)
            X=X0*R';zaxis=R*[0.,0.,1.];xaxis=R*[cosd(23.),sind(23.),0.]
            lines=["SOL 101","CEND","SPC=1","LOAD=1","BEGIN BULK",
                "PARAM,SNORM,0.","MAT8,1,1.35E11,8.5E9,.27,4.8E9,5.1E9,3.2E9,1600.",
                "PCOMP,1,,,,,,,","+,1,.001,0.,YES,1,.003,70.,YES"]
            for n in 1:3;push!(lines,"GRID,$n,,"*join(X[n,:],','));end
            append!(lines,["CORD2R,10,0,0.,0.,0.,"*join(zaxis,','),"+,"*join(xaxis,','),
                "CTRIA3,1,1,1,2,3,"*(mcid ? "10" : "23.")*",$offset",
                "SPC1,1,123456,1","FORCE,1,2,0,1.,0.,0.,1.","ENDDATA"])
            path=joinpath(dir,"triangle.bdf");write(path,join(lines,'\n')*"\n")
            model=OpenJFEM.bdf_to_model(path);prop=model["PSHELLs"]["1"];before=deepcopy(prop)
            eps=[.0002,-.0001,.0003];kap=[.003,-.002,.004];u=zeros(18)
            for n in 1:3
                x,y=X0[n,1:2]
                theta=[-kap[2]*y-kap[3]*x/2,kap[1]*x+kap[3]*y/2,0.]
                surface=[eps[1]*x+eps[3]*y/2,eps[2]*y+eps[3]*x/2,0.]
                u[6n-5:6n-3]=R*(surface-offset*cross(theta,[0.,0.,1.]))
                u[6n-2:6n]=R*theta
            end
            ids=Dict(n=>n for n=1:3);node_R=[Matrix{Float64}(I,3,3) for n=1:3];normals=Dict{Int,SVector{3,Float64}}()
            blank()=Dict{String,Any}(k=>Dict{String,Any}("quad4"=>Any[],"tria3"=>Any[]) for k in ("forces","forces_bilin","stresses","strains"))
            rows=blank();captured=Dict{Int,Any}();compact=Dict{Int,Any}()
            S.recover_shell_stresses!(model,ids,X,node_R,u,normals,Dict{Int,Float64}(),rows;static_fields_capture=captured)
            S.recover_shell_stresses!(model,ids,X,node_R,u,normals,Dict{Int,Float64}(),blank();static_fields=compact)
            @test captured==compact
            @test prop==before
            expectedN=zeros(3);expectedM=zeros(3)
            for ply in prop["PLY_DATA"]
                mat=model["MATs"][string(ply["mid"])]
                Q=OpenJFEM.laminate_plane_stress_qbar(mat["E1"],mat["E2"],mat["NU12"],mat["G12"],deg2rad(ply["theta"]+23.))
                lo,hi=ply["z_bot"],ply["z_top"]
                expectedN+=Q*((hi-lo)*eps+(hi^2-lo^2)/2*kap)
                expectedM-=Q*((hi^2-lo^2)/2*eps+(hi^3-lo^3)/3*kap)
            end
            force=only(rows["forces"]["tria3"])
            @test isapprox([force[k] for k in ("fx","fy","fxy")],expectedN;rtol=3e-11,atol=1e-10)
            @test isapprox([force[k] for k in ("mx","my","mxy")],expectedM;rtol=3e-11,atol=1e-10)
        end
    end
end
end
@testset "Triangle coupled recovery coordinate frames and reference offsets" begin
    TriaCoupledRecoverySupplement.checks()
end
