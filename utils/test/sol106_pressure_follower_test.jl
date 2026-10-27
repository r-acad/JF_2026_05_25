module PressureFollowerPhysicalChecks
using Test, OpenJFEM, LinearAlgebra, ForwardDiff
const S=OpenJFEM.Solver
rowvec(X)=vec(permutedims(X))
rowmat(x)=permutedims(reshape(x,3,:))
function rotation(v)
    a=norm(v);n=v/a
    W=[0. -n[3] n[2];n[3] 0. -n[1];-n[2] n[1] 0.]
    Matrix{Float64}(I,3,3)+sin(a)*W+(1-cos(a))*W^2
end
function triangle_balance(X,p)
    F=p/2*cross(X[2,:]-X[1,:],X[3,:]-X[1,:])
    F,cross(vec(sum(X;dims=1))/3,F)
end
function quadrature_work(X,V,p)
    g=sqrt(3/5);points=(-g,0.,g);weights=(5/9,8/9,5/9);work=0.
    for (r,wr) in zip(points,weights),(s,ws) in zip(points,weights)
        N=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]/4
        dr=[-(1-s),1-s,1+s,-(1+s)]/4
        ds=[-(1-r),-(1+r),1+r,1-r]/4
        work+=wr*ws*p*dot(V'*N,cross(X'*dr,X'*ds))
    end
    work
end
function run_checks()
    ts=@testset "Current-area pressure virtual work and load tangent" begin
        Q=rotation([.3,-.2,.5]);translation=[.7,-.3,1.1]
        for X in ([0. 0. 0.;1.4 .1 .2;.3 .9 -.1],
                  [0. 0. 0.;1.4 .1 .2;1.1 .9 -.15;-.2 .7 .3],
                  [0. 0. 0.;1.2 0. 0.;1.2 .8 0.;0. .8 0.])
            n=size(X,1);p=-3.7;f=S._current_area_pressure_force(X,p)
            V=reshape(sin.(1.:3n),n,3)
            b1=triangle_balance(X[1:3,:],p)
            b2=n==3 ? (zeros(3),zeros(3)) : triangle_balance(X[[1,3,4],:],p)
            @test vec(sum(f;dims=1)) ≈ b1[1]+b2[1] atol=2e-14
            @test sum(cross(X[i,:],f[i,:]) for i in 1:n) ≈ b1[2]+b2[2] atol=2e-14
            if n==4
                @test sum(f.*V) ≈ quadrature_work(X,V,p) rtol=2e-14 atol=2e-14
            else
                @test sum(f.*V) ≈ dot(vec(sum(V;dims=1))/3,b1[1]) atol=2e-14
            end
            @test S._current_area_pressure_force(X .+ translation',p) ≈ f atol=2e-14
            @test S._current_area_pressure_force(X*Q' .+ translation',p) ≈ f*Q' atol=2e-14
            @test S._current_area_pressure_force(1000X,p) ≈ 1e6f rtol=2e-14
            @test S._current_area_pressure_force(X,-p) == -f
            x=rowvec(X);fun=y->rowvec(S._current_area_pressure_force(rowmat(y),p))
            J=ForwardDiff.jacobian(fun,x);v=cos.(1.:3n);step=1e-6
            @test J*v ≈ (fun(x+step*v)-fun(x-step*v))/(2step) rtol=2e-9 atol=2e-9
            @test J*repeat(translation,n) ≈ zeros(3n) atol=2e-14
            @test ForwardDiff.jacobian(fun,1000x) ≈ 1000J rtol=2e-14 atol=2e-14
            @test norm(J-J')>1e-3 # Open-face pressure has an unsymmetric load tangent.
        end
        X=[0. 0. 0.;1.3 .1 .05;1.1 .9 -.1;-.2 .8 .2]
        ids=Dict(i=>i for i in 1:4);nd=24
        frames=[rotation([.07i,-.03i,.11i]) for i in 1:4]
        model=Dict{String,Any}("SOL"=>106,"PARAM_LGDISP"=>1,"CSHELLs"=>Dict("7"=>Dict("NODES"=>[1,2,3,4])),
            "PLOAD4s"=>[Dict("TYPE"=>"PLOAD4","SID"=>10,"EID"=>7,"P"=>2.5)],
            "LOAD_COMBOS"=>[Dict("SID"=>30,"S"=>2.,"COMPS"=>[Dict("LID"=>20,"S"=>3.),Dict("LID"=>10,"S"=>-.5)]),
                            Dict("SID"=>20,"S"=>.25,"COMPS"=>[Dict("LID"=>10,"S"=>-4.)])])
        # Shared flattened MPC expansion: local q=T*u, f=T'*f_local, J=T'*J_local*T.
        mapping=Dict(1=>[(7,.4),(13,-.2)],8=>[(2,1.1),(15,.3)])
        context=S._follower_context(nd,model,ids,X,30,frames,mapping)
        @test length(context.pressures)==1
        @test isempty(context.stations)
        station=only(context.pressures)
        @test station.pressure == -17.5 # 2*(3*.25*(-4)-.5)*2.5
        T=zeros(12,nd)
        for a in 1:12,(col,weight) in station.maps[a];T[a,col]+=weight;end
        u=.03sin.(1.:nd);scale=.65;q=T*u
        delta,J=S._follower_load_update(context,u,scale)
        flocal=S._follower_pressure_force(station,q)
        Dlocal=ForwardDiff.jacobian(v->S._follower_pressure_force(station,v),q)
        @test delta ≈ scale*T'*(flocal-station.reference) atol=2e-14
        @test Matrix(J) ≈ scale*T'*Dlocal*T atol=2e-14
        du=cos.(1.:nd);step=1e-6
        fd=(first(S._follower_load_update(context,u+step*du,scale))-first(S._follower_load_update(context,u-step*du,scale)))/(2step)
        @test J*du ≈ fd rtol=2e-9 atol=2e-9
        @test dot(du,delta) ≈ dot(T*du,scale*(flocal-station.reference)) atol=2e-14
        @test first(S._follower_load_update(context,u,0.)) == zeros(nd)
        @test iszero(norm(last(S._follower_load_update(context,u,0.))))
        @test first(S._follower_load_update(context,u,2scale)) ≈ 2delta atol=2e-14
        # A deformed distorted face carries consistent unequal nodal shares;
        # the increment removes precisely the old equal-share reference load.
        @test norm(first(S._follower_load_update(context,zeros(nd),1.)))>1e-3
        meta=S._follower_result_metadata(context,u,scale)
        @test meta["mode"]=="current_area_pressure"
        @test !meta["force_only"]
        @test length(meta["pressures"])==1
        @test norm(S._current_area_pressure_force(X,station.pressure))>0
        simple=deepcopy(model);simple["LOAD_COMBOS"]=Any[]
        simpleX=[0. 0. 0.;1.2 0. 0.;1.2 .8 0.;0. .8 0.]
        identity_frames=fill(Matrix{Float64}(I,3,3),4)
        c=S._follower_context(nd,simple,ids,simpleX,10,identity_frames,Dict())
        @test norm(first(S._follower_load_update(c,zeros(nd),1.)))<2e-15
        for keyvalue in (("SOL",101),("PARAM_LGDISP",-1),("PARAM_LGDISP",0))
            fixed=deepcopy(simple);fixed[keyvalue[1]]=keyvalue[2]
            @test S._follower_context(nd,fixed,ids,X,10,frames,Dict())===nothing
        end
        directed=deepcopy(simple);directed["PLOAD4s"][1]["N"]=[0.,0.,1.]
        @test S._follower_context(nd,directed,ids,X,10,frames,Dict())===nothing
        directed["PLOAD4s"][1]["N"]=zeros(3)
        @test S._follower_context(nd,directed,ids,X,10,frames,Dict())!==nothing
        for pressure in (0.,)
            zero=deepcopy(simple);zero["PLOAD4s"][1]["P"]=pressure
            @test S._follower_context(nd,zero,ids,X,10,frames,Dict())===nothing
        end
        canceled=deepcopy(simple);canceled["LOAD_COMBOS"]=[Dict("SID"=>20,"S"=>1.,"COMPS"=>[Dict("LID"=>10,"S"=>1.),Dict("LID"=>10,"S"=>-1.)])]
        @test S._follower_context(nd,canceled,ids,X,20,frames,Dict())===nothing
        # PLOAD is also follower pressure in native nonlinear analysis.
        for nodes in ([1,2,3],[1,2,3,4])
            pload=deepcopy(simple);pload["PLOAD4s"]=Any[]
            pload["PLOADs"]=[Dict("TYPE"=>"PLOAD","SID"=>10,"P"=>2.5,"NODES"=>nodes)]
            @test length(S._follower_context(nd,pload,ids,X,10,frames,Dict()).pressures)==1
        end
        higher=deepcopy(simple);higher["CSHELLs"]["7"]["NODES"]=[1,2,3,4,1,2,3,4]
        @test_throws ArgumentError S._follower_context(nd,higher,ids,X,10,frames,Dict())
        invalid=deepcopy(simple);invalid["PLOAD4s"][1]["P"]=Inf
        @test_throws ArgumentError S._follower_context(nd,invalid,ids,X,10,frames,Dict())
        missing=deepcopy(simple);missing["CSHELLs"]["7"]["NODES"]=[1,2,3,99]
        @test_throws ArgumentError S._follower_context(nd,missing,ids,X,10,frames,Dict())
        @test S._follower_context(nd,simple,ids,X,nothing,frames,Dict())===nothing
        # Concentrated ROT remains opt-in and composes with pressure.
        mixed=deepcopy(simple);mixed["FORCEs"]=[Dict("SID"=>10,"GID"=>2,"CID"=>0,"Mag"=>3.,"Dir"=>[1.,.2,-.3],"FLLW"=>"ROT")]
        @test isempty(S._follower_context(nd,mixed,ids,X,10,frames,Dict()).stations)
        mixed["PARAM_JFFOLLOW"]=1
        both=S._follower_context(nd,mixed,ids,X,10,frames,Dict())
        @test length(both.stations)==1 && length(both.pressures)==1
        md,mj=S._follower_load_update(both,u,scale)
        fd=(first(S._follower_load_update(both,u+step*du,scale))-first(S._follower_load_update(both,u-step*du,scale)))/(2step)
        @test mj*du ≈ fd rtol=2e-9 atol=2e-9
        mixed["PLOAD4s"]=Any[]
        @test S._follower_result_metadata(S._follower_context(nd,mixed,ids,X,10,frames,Dict()),u,scale)["force_only"]
        mixed["PARAM_JFFOLLOW"]=0
        @test S._follower_context(nd,mixed,ids,X,10,frames,Dict())===nothing
    end
    println("PRESSURE_FOLLOWER_GENERIC_CHECKS_COMPLETE ",Test.get_test_counts(ts));flush(stdout)
    string(Test.get_test_counts(ts))
end
end

PressureFollowerPhysicalChecks.run_checks()
