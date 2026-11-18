module RFPlateBoundTests
using Test, LinearAlgebra, ForwardDiff, Random
const REPO=normpath(joinpath(@__DIR__,"..",".."))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_kernels.jl"))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_conservative_buckling.jl"))

function bound_row(N,D;spatial=false)
    n=length(N);capacity=vcat(rf_flat(D),[1.,.25])
    unpack=x->(;N=x[1:3],D=x[n+1:n+9],L=x[n+10],W=x[n+11],
        cells=spatial ? [(;bounds=(0.,.5,0.,1.),N=x[1:3]),(;bounds=(.5,1.,0.,1.),N=x[4:6])] : nothing)
    Dict{String,Any}("feature_values"=>copy(N),"capacity_values"=>capacity,"raw_RF"=>1.,"utilization"=>1.,
        "feature_keys"=>Any[],"capacity_keys"=>Any[],"assessment_factor"=>1.,"fixity_coefficient"=>1.,
        "response_id"=>"plate","basis_id"=>"test","approximation"=>true,"_plate_matrices"=>unpack)
end
@testset "Certified all-mode equivalent-plate bound" begin
    E=70e9;nu=.3;t=.0015;d=E*t^3/(12*(1-nu^2));D=d*[1. nu 0.;nu 1. 0.;0. 0. (1-nu)/2]
    for N in ([1e4,0.,0.],[0.,1e4,0.],[1e4,-2e4,2e3],[0.,0.,1e4],[-1e4,-2e4,2e3])
        row=bound_row(N,D);bound=rf_conservative_plate_response(row)
        pair=rf_solve_plate(1.,.25,D,N)
        @test bound["utilization"]+1e-12>=pair.mu
        @test bound["certified_bound"]
        @test bound["reported_raw_RF"]==1.
        x=vcat(row["feature_values"],row["capacity_values"]);v=[.4,-.3,.2,zeros(9)...,.05,-.02]
        h=1e-5
        # Kernel frozen only for the eigenvector chain; actual direct
        # finite differences recompute the extreme eigenspaces.
        direct=z->begin
            r=copy(row);r["feature_values"]=z[1:3];r["capacity_values"]=z[4:end]
            rf_conservative_plate_response(r)["utilization"]
        end
        fd=(direct(x+h*v)-direct(x-h*v))/(2h)
        g=vcat(bound["feature_gradient"],bound["capacity_gradient"])
        @test isapprox(dot(g,v),fd;rtol=1e-5,atol=1e-7)
    end
    spatial=bound_row([1e4,0.,0.,-1e4,0.,0.],D;spatial=true)
    bound=rf_conservative_plate_response(spatial)
    pair=rf_solve_plate(1.,.25,D,[0.,0.,0.];cells=spatial["_plate_matrices"](vcat(spatial["feature_values"],spatial["capacity_values"])).cells,
        options=Dict("maxDimension"=>81,"tolerance"=>.01))
    @test bound["utilization"]>=pair.mu
    @test bound["utilization"]>0 # zero mean is not zero local compression
    crossing=bound_row([1e4,1e4,0.],D);bound=rf_conservative_plate_response(crossing)
    direction=[1.,-1.,0.,zeros(11)...]
    @test bound["derivative_status"]=="piecewise_smooth"
    @test abs(dot(vcat(bound["feature_gradient"],bound["capacity_gradient"]),direction))<1e-12
    @test bound["_directional"](direction)>0
    reference=rf_conservative_plate_response(bound_row([1e4,-2e4,2e3],D))
    for scale in (1e-100,1e100)
        scaled=rf_conservative_plate_response(bound_row(scale.*[1e4,-2e4,2e3],scale.*D))
        @test scaled["utilization"]≈reference["utilization"] rtol=1e-12
        @test all(isfinite,vcat(scaled["feature_gradient"],scaled["capacity_gradient"]))
    end
    tiny=rf_conservative_plate_response(bound_row([1e-100,0.,0.],diagm([1e-100,2e-100,4e-100])))
    @test tiny["utilization"]≈1/(17pi^2) rtol=1e-12
    @test tiny["_evaluate"](vcat([1e-100,0.,0.],rf_flat(diagm([1e-100,2e-100,4e-100])),[1.,.25]))≈tiny["utilization"]
end

@testset "Adaptive certified policy preserves physical RFs and invalidates cached criteria" begin
    D=diagm([4.,5.,2.])
    baseline=merge(bound_row([1.,0.,0.],D),Dict("approximation"=>false,"converged"=>true,"raw_RF"=>7.))
    policy=RFOptimizationConstraintPolicy()
    initial=only(rf_optimization_policy_responses!(policy,[baseline]))
    @test initial===baseline
    @test policy.revision==0
    cached=merge(Dict("mass"=>1.),rf_optimization_policy_metadata(policy))
    @test rf_optimization_cache_valid([1.],cached,[1.],policy)
    trial=merge(bound_row([2.,0.,0.],D),Dict("approximation"=>true,"converged"=>false,"raw_RF"=>9.))
    certified=only(rf_optimization_policy_responses!(policy,[trial]))
    @test policy.revision==1
    @test policy.bound_ids==Set(["plate"])
    @test certified["certified_bound"]
    @test certified["reported_raw_RF"]==9.
    @test certified["reported_utilization"]==trial["utilization"]
    @test !certified["approximation"]&&certified["converged"]
    @test !rf_optimization_cache_valid([1.],cached,[1.],policy)
    reassessed=only(rf_optimization_policy_responses!(policy,[baseline]))
    @test reassessed["certified_bound"]
    @test reassessed["reported_raw_RF"]==7.
    @test reassessed["utilization"]≈certified["utilization"]/2
    @test policy.revision==1
    @test all(isfinite,vcat(reassessed["feature_gradient"],reassessed["capacity_gradient"]))
    refreshed=merge(Dict("mass"=>1.),rf_optimization_policy_metadata(policy))
    @test rf_optimization_cache_valid([1.],refreshed,[1.],policy)
    @test !rf_optimization_cache_valid([1.],refreshed,[1.1],policy)
    restored=RFOptimizationConstraintPolicy(rf_optimization_policy_metadata(policy))
    @test restored.revision==1&&restored.bound_ids==policy.bound_ids
    @test only(rf_optimization_policy_responses!(restored,[baseline]))["reported_raw_RF"]==7.
    @test_throws ArgumentError rf_optimization_policy_responses!(restored,Any[])
    @test_throws ArgumentError RFOptimizationConstraintPolicy(Dict("constraint_revision"=>-1))
    @test_throws ArgumentError RFOptimizationConstraintPolicy(Dict("constraint_revision"=>1,"certified_bound_response_ids"=>["plate","plate"]))
    @test_throws ArgumentError RFOptimizationConstraintPolicy(Dict("constraint_revision"=>0,"certified_bound_response_ids"=>["plate"]))
    @test_throws ArgumentError RFOptimizationConstraintPolicy(Dict("constraint_revision"=>1,"certified_bound_response_ids"=>String[]))
    invalid=copy(trial);delete!(invalid,"_plate_matrices")
    fresh=RFOptimizationConstraintPolicy()
    @test_throws ArgumentError rf_optimization_policy_responses!(fresh,[invalid])
    @test fresh.revision==0&&isempty(fresh.bound_ids)
end

end # RFPlateBoundTests
