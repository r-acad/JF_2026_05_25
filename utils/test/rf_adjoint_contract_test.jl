module RFAdjointContractTests
using Test,LinearAlgebra,SparseArrays,SHA,Serialization
const R=normpath(joinpath(@__DIR__,"..",".."))
include(joinpath(R,"APPS","JFEM-Boxer","src","rf_recovery.jl"))
include(joinpath(R,"APPS","JFEM-Boxer","src","rf_adjoint.jl"))
module FixtureNative
module Solver
_stress_entry_public_id(id,el)=parse(Int,string(id))
function recover_bar_stresses!(model,ids,X,R,u,stress,result;active_load_id=nothing)
    for (id,bar) in model["CBARs"]
        eid=parse(Int,id);i,j=bar["GA"],bar["GB"];E=10.;A=model["areas"][eid]
        value=E*(u[6(j-1)+1]-u[6(i-1)+1])
        push!(result["stresses"]["cbar"],Dict("eid"=>eid,"axial"=>value))
        push!(result["strains"]["cbar"],Dict("eid"=>eid,"axial"=>value/E))
        push!(result["forces"]["cbar"],Dict("eid"=>eid,"axial"=>value*A))
    end
end
end
end
n_elements(g)=length(g.eids)
sensitivity_reduce_gradient(op,gradient)=gradient[op.free]
sensitivity_expand_state(op,free,state)=begin full=zeros(op.ndof);full[free]=state;full end
sensitivity_analytic_property_directions(wing,d;kwargs...)=Dict(parse(Int,d["id"])=>Dict{String,Any}("rho"=>0.,"darea"=>1.))
function sensitivity_analytic_bar(native,op,wing,g,e,direction,u)
    k=10.;ids=[(g.pid-1)*6+i for i=1:12];K=zeros(12,12)
    K[1,1]=K[7,7]=k;K[1,7]=K[7,1]=-k
    du=u[ids];A=wing.params["areas"][g.pid]
    force=A*K*du;dforce=K*du
    (;dofs=ids,dKe=K,section=(;darea=1.,doffset_y=0.),dmass=0.,
        stiffness_replay_relative_error=0.,dforces=dforce,axial_stress=force[7]/A,daxial_stress=0.)
end
function sensitivity_analytic_load_tangent(wing,directions)
    load=zeros(18)
    for pid in keys(directions)
        load[7]+=pid==1 ? .3 : .7;load[13]+=pid==2 ? .2 : 0.
    end
    (;force=load,diagnostics=Dict())
end
sensitivity_analytic_reduce_load(native,op,load)=load.force
function fixture(areas)
    k1,k2=10areas;A=[k1+k2 -k2;-k2 k2]
    F=[.3areas[1]+.7areas[2],100+.2areas[2]];u=A\F;full=zeros(18);full[[7,13]]=u
    groups=[(;pid=i,kind=:bar,eids=[i]) for i=1:2]
    model=Dict{String,Any}("areas"=>areas,"CBARs"=>Dict(string(i)=>Dict("GA"=>i,"GB"=>i+1,"PID"=>i) for i=1:2))
    op=(;ndof=18,id_map=Dict(i=>i for i=1:3),X=zeros(3,3),node_R=[Matrix{Float64}(I,3,3) for _=1:3],
        model,free=[7,13],load_id=1)
    wing=(;groups,params=Dict("areas"=>areas));properties=[Dict("pid"=>i) for i=1:2]
    context=(;op,wing,u,expanded=full,A,factor=lu(A),signature="fixture",groups=Dict(i=>[groups[i]] for i=1:2),
        properties,properties_by_pid=Dict(i=>properties[i] for i=1:2),recovery_cache=Dict{Any,Any}(),
        design_cache=Dict{Any,Any}(),design_cache_order=Any[],design_cache_bytes=Ref(0),design_cache_limit=1000000)
    stresses=[10u[1],10(u[2]-u[1])]
    rows=[Dict{String,Any}("response_id"=>"strength:$i","case_id"=>1,"utilization"=>stresses[i]/300,
        "status"=>"ok","derivative_status"=>"analytic_local","feature_keys"=>[Dict("case_id"=>1,"eid"=>i,"quantity"=>"stress","path"=>["axial"])],
        "feature_values"=>[stresses[i]],"feature_gradient"=>[1/300],"capacity_keys"=>Any[],"capacity_gradient"=>Float64[]) for i=1:2]
    (;context,rows)
end
@testset "RF exact equilibrium products" begin
    x=[2.,3.];f=fixture(x);contexts=Dict("1"=>f.context);vars=[Dict("id"=>string(i)) for i=1:2]
    result=rf_response_jacobian(FixtureNative,contexts,f.rows,vars;block_size=1)
    @test result["complete"]
    J=result["jacobian"]
    # Axial equilibrium: N1=F1+F2, N2=F2. These expressions include
    # the area-dependent self-weight surrogate and its remote effect.
    expected=[(.3*2-(100+.3*2+.9*3))/(2^2*300) .9/(2*300);
        0. -100/(3^2*300)]
    @test isapprox(J,expected;rtol=1e-12,atol=1e-15)
    # Same strength expressed through N/A must include BOTH the fixed-state
    # force derivative and explicit section denominator, without double count.
    force_rows=deepcopy(f.rows)
    for (i,row) in enumerate(force_rows)
        stress=row["feature_values"][1];area=x[i];force=stress*area
        row["feature_keys"][1]["quantity"]="forces";row["feature_values"]=[force]
        row["feature_gradient"]=[1/(area*300)]
        row["capacity_keys"]=[Dict("pid"=>i)];row["capacity_gradient"]=[-force/(area^2*300)]
    end
    capacity=(context,row,variable,directions)->[parse(Int,variable["id"])==row["capacity_keys"][1]["pid"] ? 1. : 0.]
    forced=rf_response_jacobian(FixtureNative,contexts,force_rows,vars;capacity_row_jvp=capacity)
    @test forced["complete"]&&isapprox(forced["jacobian"],J;rtol=1e-12,atol=1e-15)
    blocks=Any[]
    streamed=rf_response_jacobian(FixtureNative,contexts,f.rows,vars;retain_matrix=false,block_size=1,
        block_sink=(a,b,block)->push!(blocks,copy(block)))
    @test streamed["jacobian"]===nothing&&streamed["shape"]==[2,2]
    @test isapprox(reduce(vcat,blocks),J;rtol=1e-12,atol=1e-15)
    v=[.25,-.4];w=[.2,.8]
    tangent=rf_jvp(FixtureNative,contexts,f.rows,vars,v)
    pullback=rf_vjp(FixtureNative,contexts,f.rows,vars,w)
    @test isapprox(tangent.values,J*v;rtol=1e-12)
    @test isapprox(pullback.values,transpose(J)*w;rtol=1e-12)
    @test isapprox(dot(w,tangent.values),dot(v,pullback.values);rtol=1e-12)
    exact=rf_directional(FixtureNative,contexts,f.rows,vars,v)
    @test isapprox(exact.values,J*v;rtol=1e-12)
    @test pullback.adjoint_rhs==1
    @test !iszero(J[1,2])
    h=1e-5
    numeric=hcat([(getindex.(fixture(x+h*[j==i for j=1:2]).rows,"utilization")-
        getindex.(fixture(x-h*[j==i for j=1:2]).rows,"utilization"))/(2h) for i=1:2]...)
    @test isapprox(J,numeric;rtol=1e-8,atol=1e-12)
    rf=rf_response_jacobian(FixtureNative,contexts,f.rows,vars;measure="reserve_factor")
    @test isapprox(rf["jacobian"],-Diagonal(1 ./ getindex.(f.rows,"utilization").^2)*J;rtol=1e-12)
    # At a genuine maximum crossing, the selected Clarke product is linear,
    # while the actual one-sided derivative follows the competing branch.
    a2=3.;F2=100+.2a2;a1=a2*(F2+.7a2)/(F2-.3a2);crossing=fixture([a1,a2])
    row=deepcopy(first(crossing.rows));row["feature_keys"]=vcat(getindex.(crossing.rows,"feature_keys")...)
    row["feature_values"]=vcat(getindex.(crossing.rows,"feature_values")...)
    row["feature_gradient"]=[1/600,1/600];row["_directional"]=v->max(v[1],v[2])/300
    cx=Dict("1"=>crossing.context);v=[1.,-1.]
    derivative=rf_directional(FixtureNative,cx,[row],vars,v)
    h=1e-6;perturbed=fixture([a1,a2]+h*v)
    one_sided=(maximum(getindex.(perturbed.rows,"utilization"))-maximum(getindex.(crossing.rows,"utilization")))/h
    @test derivative.local_directional_hook==[true]
    @test derivative.projected_pencil==[false]
    @test isapprox(only(derivative.values),one_sided;rtol=2e-6)
    # A spectral maximum uses the same mathematical directional operation but
    # has explicit projected-pencil provenance, unlike a generic max envelope.
    spectral=merge(row,Dict("cluster_size"=>2))
    spectral_derivative=rf_directional(FixtureNative,cx,[spectral],vars,v)
    @test spectral_derivative.projected_pencil==[true]
    @test spectral_derivative.local_directional_hook==[true]
    @test spectral_derivative.values≈derivative.values
    # Zero-demand equivalent norms have selected-zero Clarke gradients, while
    # their one-sided derivatives are positive in either nonzero direction.
    zero_row=deepcopy(first(f.rows));zero_row["utilization"]=0.
    zero_row["feature_gradient"]=[0.];zero_row["_directional"]=d->abs(d[1])/300
    zero_row["gradient_class"]="zero_demand_selected_clarke"
    zero_row["directional_status"]="exact_one_sided_norm"
    v=[.25,-.4]
    zero_jv=rf_jvp(FixtureNative,contexts,[zero_row],vars,v)
    positive=rf_directional(FixtureNative,contexts,[zero_row],vars,v)
    negative=rf_directional(FixtureNative,contexts,[zero_row],vars,-v)
    @test only(zero_jv.values)==0.
    @test only(positive.values)>0.
    @test positive.projected_pencil==[false]
    @test positive.local_directional_hook==[true]
    @test positive.derivative_class==["exact_one_sided_norm"]
    @test positive.values≈negative.values
    numerical=abs(first(fixture(x+1e-6v).rows)["utilization"]-first(f.rows)["utilization"])/1e-6
    @test only(positive.values)≈numerical rtol=2e-6
end

end # RFAdjointContractTests
