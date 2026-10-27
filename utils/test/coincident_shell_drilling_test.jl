using Test, LinearAlgebra, SparseArrays, OpenJFEM
const DRILLING=OpenJFEM.Solver

function coincident_drilling_fixture(;units=1.,finite_stiffness=0.)
    n=normalize([1.,2.,3.]);u=normalize(cross(n,[0.,0.,1.]));v=cross(n,u)
    grids=Dict(string(i)=>Dict("ID"=>i,"CD"=>0,"X"=>x) for (i,x) in enumerate([zeros(3),zeros(3),u,v]))
    model=Dict{String,Any}("SOL"=>103,"GRIDs"=>grids,"CORDs"=>Dict(),
        "RBE2s"=>Dict("1"=>Dict("ID"=>1,"GN"=>1,"GM"=>[2],"CM"=>12356)),
        "CSHELLs"=>Dict("1"=>Dict("NODES"=>[1,3,4]),"2"=>Dict("NODES"=>[2,3,4])))
    K=Matrix{Float64}(I,24,24);P=I(3)-n*n'
    local_K=zeros(6,6);local_K[1:3,1:3].=P;local_K[4:6,4:6].=P
    T=Matrix{Float64}(I,6,6);T[5,5]=T[6,6]=0.;T[5,2]=T[6,3]=1.
    local_K=T'*local_K*T
    K[[4,5,6,10,11,12],[4,5,6,10,11,12]].=local_K
    null=normalize(vcat(n,n[1]));dofs=[4,5,6,10]
    K[dofs,dofs].+=finite_stiffness*(null*null')
    return units*sparse(K),model,Dict(i=>i for i in 1:4),Set([11,12]),dofs,null
end

@testset "Coincident shell joint removes only a drilling coordinate gauge" begin
    for units in (1e-20,1.,1e20)
        K,model,ids,fixed,dofs,null=coincident_drilling_fixture(;units)
        before=copy(fixed)
        entries=DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids)
        @test length(entries)==1
        @test length(setdiff(fixed,before))==1
        @test all(mod1(d,6)>3 for d in setdiff(fixed,before))
        free=setdiff(1:24,collect(fixed))
        @test isposdef(Symmetric(Matrix(K[free,free])))
        # A balanced elastic load is unaffected by choosing the drilling gauge.
        load=zeros(24);load[1]=units;load[dofs].=units.*(I(4)-null*null')*[1.,-.5,.7,.2]
        response=zeros(24);response[free]=K[free,free]\load[free]
        @test norm(K*response-load)<=1e-12*norm(load)
        @test response[1]≈1.
        @test isempty(DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids))
    end
    for modification in (
        model->(model["GRIDs"]["2"]["X"]=[0.,0.,.01]),
        model->(model["RBE2s"]["1"]["CM"]=123),
        model->(model["CONM2s"]=Dict("1"=>Dict("GID"=>1,"M"=>1.,"I"=>ones(6)))),
        model->(model["CBARs"]=Dict("1"=>Dict("GA"=>1,"GB"=>3))),
        model->(model["RBE3s"]=Dict("1"=>Dict("REFGRID"=>3,"WT_GROUPS"=>[(wt=1.,comps=123,grids=[1,2])]))),
        model->(model["MPCs"]=[Dict("TERMS"=>[Dict("G"=>1,"C"=>4,"A"=>1.)])]),
        model->(model["MOMENTs"]=[Dict("GID"=>1,"Mag"=>1.)]),
        model->(model["CELASs"]=Dict("1"=>Dict("G1"=>1,"G2"=>3))),
        model->(model["RSPLINEs"]=Dict("1"=>Dict("GRIDS"=>[1,3]))),
        model->(model["RBE1s"]=Dict("1"=>Dict("INDEP"=>[(1,4)],"DEP"=>[(3,4)]))),
        model->(model["RBE3s"]=Dict("1"=>Dict("REFGRID"=>3,"WT_GROUPS"=>Any[],"UM"=>[(1,4)]))),
        model->(model["RBE2s"]["2"]=Dict("ID"=>2,"GN"=>1,"GM"=>[3],"CM"=>123456)),
        model->(model["PARAM_K6ROT"]=1e-20),
        model->(model["DMIGs"]=Dict("MASS"=>Dict())),
        model->(model["CSHELLs"]["2"]["NODES"]=[2,3,1]))
        K,model,ids,fixed,_,_=coincident_drilling_fixture();modification(model);before=copy(fixed)
        @test isempty(DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids))
        @test fixed==before
    end
    K,model,ids,fixed,_,_=coincident_drilling_fixture(;finite_stiffness=1e-8)
    @test isempty(DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids))
    # GRID rounding perturbs a normal by 1e-9 while leaving zero drilling
    # self-energy at floating-point precision. The cancellation residual must
    # be bounded by that measured normal mismatch, not a generic larger cutoff.
    for stiffness in (0.,1e-8)
        K,model,ids,fixed,dofs,null=coincident_drilling_fixture(;finite_stiffness=stiffness)
        n=normalize([1.,2.,3.]);model["GRIDs"]["4"]["X"].+=1e-9.*n
        K[3,dofs].=1e-11.*null;K[dofs,3].=1e-11.*null
        entries=DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids)
        @test length(entries)==(stiffness==0 ? 1 : 0)
    end
    # A real free hinge involves translational motion of the structure. Build
    # a positive-semidefinite elastic operator with that mixed null direction.
    K,model,ids,fixed,dofs,null=coincident_drilling_fixture()
    K[dofs,dofs].+=null*null';K[1,dofs].=-null;K[dofs,1].=-null
    physical_mode=zeros(24);physical_mode[1]=1.;physical_mode[dofs].=null
    @test norm(K*physical_mode)<1e-12
    @test isempty(DRILLING._coincident_shell_drilling_autospc!(fixed,nothing,K,model,ids))
end
