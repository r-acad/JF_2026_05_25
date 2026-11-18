module RFSizingOptimizerTests
using Test, LinearAlgebra, SparseArrays
const REPO=normpath(joinpath(@__DIR__,"..",".."))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_conservative_buckling.jl"))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_optimization.jl"))
include(joinpath(REPO,"APPS","JFEM-Boxer","src","rf_sensitivity.jl"))

@testset "Conservative KS and derivative weights" begin
    u=[.2,1.01,.7];r=rf_ks(u;rho=30.)
    @test maximum(u)<=r.value<=maximum(u)+r.bound+1e-14
    @test sum(r.weights)≈1
    v=[.1,-.4,.3];h=1e-6
    @test (rf_ks(u+h*v;rho=30.).value-rf_ks(u-h*v;rho=30.).value)/(2h)≈dot(r.weights,v) rtol=1e-7
    @test rf_ks([1000.,999.];rho=100.).value≈1000.
    @test_throws ArgumentError rf_ks([NaN])
end

function two_sections(x;need_gradient=true)
    result=Dict{String,Any}("mass"=>2x[1]+x[2],"utilizations"=>[1/x[1],4/x[2]^2],
        "response_ids"=>["axial_strength","plate_buckling"],"complete"=>true)
    if need_gradient
        result["mass_gradient"]=[2.,1.]
        result["jacobian"]=[-1/x[1]^2 0.;0. -8/x[2]^3]
    end
    result
end
@testset "RF sizing constrained analytical optimum" begin
    result=rf_optimize(two_sections,[2.,3.];lower=[.5,.5],upper=[5.,5.],
        max_iterations=180,inner_iterations=5,feasibility_tolerance=1e-5,optimality_tolerance=1e-5)
    @show result["status"] result["mass"] result["maximum_utilization"] result["evaluations"]
    @test result["converged"]
    @test result["feasible"]
    @test result["design"]≈[1.,2.] rtol=3e-4
    @test result["mass"]≈4. rtol=2e-4
    matrix_free=(x;need_gradient=true)->begin
        r=two_sections(x;need_gradient)
        if need_gradient
            j=pop!(r,"jacobian");r["vjp"]=w->j'*w
        end
        r
    end
    other=rf_optimize(matrix_free,[2.,3.];lower=[.5,.5],upper=[5.,5.],
        max_iterations=180,inner_iterations=5,feasibility_tolerance=1e-5,optimality_tolerance=1e-5)
    @test other["design"]≈result["design"]
    @test_throws InterruptException rf_optimize(two_sections,[2.,3.];lower=[.5,.5],upper=[5.,5.],cancelled=()->true)
    invalid=(x;need_gradient=true)->merge(two_sections(x;need_gradient),Dict("complete"=>false))
    @test_throws ArgumentError rf_optimize(invalid,[2.,3.];lower=[.5,.5],upper=[5.,5.])
    saved=Ref{Any}(nothing)
    limited=rf_optimize(two_sections,[2.,3.];lower=[.5,.5],upper=[5.,5.],
        max_iterations=2,checkpoint=data->saved[]=deepcopy(data))
    @test !limited["converged"]
    @test saved[]!==nothing
    resumed=rf_optimize(two_sections,saved[]["design"];lower=[.5,.5],upper=[5.,5.],
        max_iterations=180,inner_iterations=5,feasibility_tolerance=1e-5,
        optimality_tolerance=1e-5,restart=saved[])
    @test resumed["converged"]
    @test resumed["design"]≈[1.,2.] rtol=3e-4
    bad_restart=merge(saved[],Dict("response_ids"=>["changed"]))
    @test_throws ArgumentError rf_optimize(two_sections,saved[]["design"];
        lower=[.5,.5],upper=[5.,5.],restart=bad_restart)
    projected=rf_optimize(two_sections,[.1,.1];lower=[1.,2.],upper=[5.,5.],
        max_iterations=1)
    @test projected["initial_design_projected_to_bounds"]
    @test projected["design"]≈[1.,2.]
end

@testset "Local sizing with a large fixed mass" begin
    localized=(x;need_gradient=true)->begin
        result=Dict{String,Any}("mass"=>369.0 + .4*(x[1]-1.0),
            "utilizations"=>[7.9/x[1]^3],"response_ids"=>["local_column"],"complete"=>true)
        if need_gradient
            result["mass_gradient"]=[.4]
            result["jacobian"]=reshape([-23.7/x[1]^4],1,1)
        end
        result
    end
    sized=rf_optimize(localized,[1.];lower=[1.],upper=[5.],max_iterations=60,inner_iterations=5)
    @test sized["converged"]
    @test sized["feasible"]
    @test isapprox(only(sized["design"]),cbrt(7.9);rtol=3e-4)
    @test length(sized["history"])<=60

    linear=(x;need_gradient=true)->begin
        result=Dict{String,Any}("mass"=>369.0 + dot([.4,.6,.8],x.-1.),
            "utilizations"=>[.25],"response_ids"=>["noncritical"],"complete"=>true)
        if need_gradient
            result["mass_gradient"]=[.4,.6,.8]
            result["jacobian"]=zeros(1,3)
        end
        result
    end
    bounds=rf_optimize(linear,[3.,4.,2.];lower=ones(3),upper=fill(5.,3),max_iterations=60,inner_iterations=5)
    @test bounds["converged"]
    @test bounds["design"]==ones(3)
    @test bounds["mass"]==369.
    @test length(bounds["history"])<=60

    gradient=[1.,1.,-1.];z=[1.,2.,5.];limit=[.2,.4,1.]
    direction=rf_projected_cauchy_direction(gradient,z,ones(3),fill(5.,3),limit)
    @test dot(gradient,direction)<0
    @test direction[1]==direction[3]==0.
    @test maximum(abs.(direction)./limit)<=1+eps()
end

@testset "Large matrix-free sizing needs collective stationarity" begin
    n=10_000
    many_dimensions=(x;need_gradient=true)->begin
        result=Dict{String,Any}("mass"=>10_000.0+sum(x),"utilizations"=>[.1],
            "response_ids"=>["noncritical"],"complete"=>true)
        if need_gradient
            result["mass_gradient"]=ones(n)
            result["vjp"]=weights->zeros(n)
        end
        result
    end
    sized=rf_optimize(many_dimensions,fill(2.,n);lower=ones(n),upper=fill(3.,n))
    @test sized["converged"]
    @test sized["feasible"]
    @test sized["design"]==ones(n)
    @test sized["mass"]==20_000.
    @test 1<length(sized["history"])<=60
end

function localized_panel(x;need_gradient=true)
    result=Dict{String,Any}("mass"=>369.302+.46*(x[1]-1.),
        "utilizations"=>[7.8969/x[1]^2.5],"response_ids"=>["panel_buckling"],"complete"=>true)
    if need_gradient
        result["mass_gradient"]=[.46]
        result["jacobian"]=reshape([-2.5*7.8969/x[1]^3.5],1,1)
    end
    result
end

@testset "Localized sizing requires complementary KKT multipliers" begin
    sized=rf_optimize(localized_panel,[1.];lower=[1.],upper=[5.])
    optimum=7.8969^.4
    @test sized["converged"]
    @test sized["feasible"]
    @test only(sized["design"])≈optimum rtol=1e-4
    @test sized["mass"]≈369.302+.46*(optimum-1.) rtol=1e-7
    @test only(sized["utilizations"])≈1. atol=1e-4
    @test sized["projected_gradient_norm"]<=1e-4
    @test sized["complementarity_norm"]<=1e-4
    final=localized_panel(sized["design"])
    gradient=final["mass_gradient"]./sized["mass_scale"]+rf_sizing_vjp(final,sized["multipliers"])
    @test norm(gradient)/sized["kkt_scale"]<=1e-4
    @test norm(sized["multipliers"].*(final["utilizations"].-1.),Inf)/sized["kkt_scale"]<=1e-4

    # Manufacture a feasible stationary augmented subproblem with a slack
    # constraint and a stale positive multiplier. It is not a KKT point.
    x=[3.1];assessment=localized_panel(x);g=only(assessment["utilizations"])-1.
    mass_scale=369.302
    dual=-(only(assessment["mass_gradient"])/mass_scale)/only(assessment["jacobian"])
    restart=Dict("design"=>x,"response_ids"=>["panel_buckling"],
        "multipliers"=>[dual-g],"penalty"=>1.,"mass_scale"=>mass_scale)
    @test g<-.5
    @test only(rf_sizing_gradient(assessment,mass_scale,restart["multipliers"],1.,[1.]))≈0. atol=1e-15
    stopped=rf_optimize(localized_panel,x;lower=[1.],upper=[5.],scales=[1.],max_iterations=1,restart)
    @test !stopped["converged"]
    @test stopped["termination_reason"]=="iteration_limit"
    @test first(stopped["history"])["augmented_projected_gradient_norm"]<1e-14
    @test first(stopped["history"])["complementarity_norm"]>1.
    @test only(stopped["design"])<only(x)
    recovered=rf_optimize(localized_panel,x;lower=[1.],upper=[5.],scales=[1.],restart)
    @test recovered["converged"]
    @test only(recovered["design"])≈optimum rtol=1e-4
    @test only(recovered["utilizations"])≈1. atol=1e-4
end

@testset "Several load cases constrain one shared sizing design" begin
    function maneuver_cases(x;need_gradient=true,indices=[1,2])
        capacities=[2x[1]+x[2],x[1]+2x[2]]
        details=[Dict("response_id"=>"positive_maneuver","case_id"=>1,"case_label"=>"Positive maneuver",
                "failure_mode"=>"skin_buckling","membership_pids"=>[101]),
            Dict("response_id"=>"negative_maneuver","case_id"=>2,"case_label"=>"Negative maneuver",
                "failure_mode"=>"euler_column","membership_pids"=>[102,103])]
        result=Dict{String,Any}("mass"=>sum(x),"utilizations"=>[3/capacities[i] for i in indices],
            "response_ids"=>[details[i]["response_id"] for i in indices],
            "response_details"=>details[indices],"complete"=>true)
        if need_gradient
            jacobian=[-6/capacities[1]^2 -3/capacities[1]^2;
                -3/capacities[2]^2 -6/capacities[2]^2]
            result["mass_gradient"]=[1.,1.]
            result["jacobian"]=jacobian[indices,:]
        end
        result
    end
    events=Any[]
    combined=rf_optimize(maneuver_cases,[2.4,1.7];lower=fill(.25,2),upper=fill(4.,2),
        scales=ones(2),max_iterations=180,inner_iterations=5,
        progress=event->push!(events,deepcopy(event)))
    @test combined["converged"]
    @test combined["design"]≈[1.,1.] rtol=5e-4
    @test combined["mass"]≈2. rtol=3e-4
    @test all(combined["utilizations"].<=1+1e-4)
    @test combined["minimum_rf"]≈1. atol=2e-4
    @test combined["critical_case_id"] in (1,2)
    for index in 1:2
        single=(x;need_gradient=true)->maneuver_cases(x;need_gradient,indices=[index])
        sized=rf_optimize(single,[2.4,1.7];lower=fill(.25,2),upper=fill(4.,2),
            scales=ones(2),max_iterations=180,inner_iterations=5)
        @test sized["converged"]
        @test sized["mass"]<combined["mass"]-.1
    end
    @test rf_sizing_constraint_summary(maneuver_cases([2.,1.]))["critical_case_id"]==2
    @test rf_sizing_constraint_summary(maneuver_cases([1.,2.]))["critical_case_id"]==1
    @test any(event->get(event,"event","")=="baseline",events)
    @test any(event->get(event,"event","")=="step_accepted",events)
    @test any(event->get(event,"event","")=="converged",events)
    @test get(last(events),"event","")=="search_finished"
    @test all(event->haskey(event,"log_message"),events)
    @test all(row->haskey(row,"critical_case_id")&&haskey(row,"minimum_rf")&&haskey(row,"mass_change_kg"),combined["history"])
    @test occursin("Negative maneuver",rf_sizing_constraint_message(rf_sizing_constraint_summary(maneuver_cases([2.,1.]))))
end

@testset "Sizing property comparison preserves physical tied dimensions" begin
    variables=[Dict{String,Any}("id"=>"skin_a","label"=>"Upper skin","unit"=>"mm","value"=>1.5,
            "lower_bound"=>1.5,"upper_bound"=>6.,"path"=>["properties.panels","a","skin","thickness"],"pids"=>[101]),
        Dict{String,Any}("id"=>"skin_b","label"=>"Lower skin","unit"=>"mm","value"=>3.,
            "lower_bound"=>3.,"upper_bound"=>9.,"path"=>["properties.panels","b","skin","thickness"],"pids"=>[102])]
    design=rf_design_map(variables,[Dict("id"=>"paired_skins","members"=>[
        Dict("id"=>"skin_a","ratio"=>1.),Dict("id"=>"skin_b","ratio"=>2.)])])
    updates=rf_optimization_dimension_updates(design,[2.123456789123])
    @test length(updates)==2
    @test updates[1]["initial_value"]==1.5
    @test updates[2]["initial_value"]==3.
    @test updates[1]["optimized_value"]==2.123456789123
    @test updates[2]["optimized_value"]==4.246913578246
    @test [row["lower_bound"] for row in updates]==[1.5,3.]
    @test [row["upper_bound"] for row in updates]==[4.5,9.]
    @test updates[1]["membership_pids"]==[101]
    @test updates[2]["path"]==variables[2]["path"]
    @test updates[1]["change"]==2.123456789123-1.5
end

function promoting_plate(revision=Ref(0))
    function assess(x;need_gradient=true)
        x[1]<1.8&&(revision[]=1)
        demand=revision[]==0 ? .25 : 3.
        result=Dict{String,Any}("mass"=>10+x[1],"utilizations"=>[demand/x[1]],
            "response_ids"=>["plate"],"complete"=>true,"constraint_revision"=>revision[],
            "certified_bound_response_ids"=>revision[]==0 ? String[] : ["plate"])
        if need_gradient
            result["mass_gradient"]=[1.]
            result["jacobian"]=reshape([-demand/x[1]^2],1,1)
        end
        result
    end
end

@testset "Adaptive certificate promotion restarts the accepted constraint state" begin
    events=Any[]
    sized=rf_optimize(promoting_plate(),[2.];lower=[.5],upper=[5.],scales=[1.],
        max_iterations=180,inner_iterations=5,progress=event->push!(events,deepcopy(event)))
    @test sized["converged"]
    @test sized["feasible"]
    @test only(sized["design"])≈3. rtol=3e-4
    @test sized["mass_scale"]==12.
    @test sized["constraint_revision"]==1
    @test sized["certified_bound_response_ids"]==["plate"]
    @test sized["constraint_policy_restarts"]==1
    restart=only(sized["constraint_policy_history"])
    @test restart["accepted_design"]==[2.]
    @test restart["constraint_violation"]≈.5
    @test restart["trigger"]=="line_search_candidate"
    @test restart["previous_revision"]==0&&restart["constraint_revision"]==1
    @test any(event->get(event,"event","")=="constraint_policy_restart",events)
    @test all(row->haskey(row,"constraint_revision"),sized["history"])
    @test all(row->row["constraint_revision"]==1,sized["history"][2:end])
    @test sized["best_feasible"]["design"][1]>=3-1e-3

    # A checkpoint taken exactly at the promotion must contain the newly
    # certified policy and reassessed accepted design, with no stale duals.
    saved=Ref{Any}(nothing)
    stopped=rf_optimize(promoting_plate(),[2.];lower=[.5],upper=[5.],scales=[1.],
        max_iterations=1,checkpoint=data->saved[]=deepcopy(data))
    @test !stopped["converged"]
    @test stopped["design"]==[2.]
    @test !stopped["feasible"]
    @test saved[]["constraint_revision"]==1
    @test saved[]["certified_bound_response_ids"]==["plate"]
    @test saved[]["design"]==[2.]
    @test saved[]["multipliers"]==[0.]
    @test saved[]["penalty"]==1.
    resumed=rf_optimize(promoting_plate(Ref(1)),saved[]["design"];
        lower=[.5],upper=[5.],scales=[1.],max_iterations=180,inner_iterations=5,restart=saved[])
    @test resumed["converged"]
    @test only(resumed["design"])≈3. rtol=3e-4
    @test resumed["constraint_policy_restarts"]==1
    @test resumed["mass_scale"]==12.
    @test_throws ArgumentError rf_optimize(promoting_plate(Ref(1)),saved[]["design"];
        lower=[.5],upper=[5.],restart=merge(saved[],Dict("certified_bound_response_ids"=>["absent"])))

    # Independent reassessment on resume may discover another certificate.
    # Original objective scaling survives, but the saved penalty/duals do not.
    old=merge(saved[],Dict("constraint_revision"=>0,"certified_bound_response_ids"=>String[],
        "constraint_policy_history"=>Any[],"multipliers"=>[100.],"penalty"=>100.))
    resumed_events=Any[]
    newer=rf_optimize(promoting_plate(Ref(1)),[2.];lower=[.5],upper=[5.],scales=[1.],
        max_iterations=1,restart=old,progress=event->push!(resumed_events,deepcopy(event)))
    @test first(newer["history"])["penalty"]==1.
    @test newer["mass_scale"]==12.
    @test any(event->get(event,"trigger","")=="resume_reassessment",resumed_events)
end

@testset "Assessment-only failed searches do not repeat unchanged feasible designs" begin
    calls=Ref(0);events=Any[]
    function assessment_boundary(x;need_gradient=true)
        calls[]+=1
        x[1]<1.0&&throw(ArgumentError("Missing physical membrane coverage in trial"))
        result=Dict{String,Any}("mass"=>100+x[1],"utilizations"=>[.25],"response_ids"=>["plate"],"complete"=>true)
        if need_gradient
            result["mass_gradient"]=[1.];result["jacobian"]=zeros(1,1)
        end
        result
    end
    result=rf_optimize(assessment_boundary,[1.];lower=[.5],upper=[2.],max_iterations=60,
        progress=event->push!(events,deepcopy(event)))
    @test !result["converged"]
    @test result["feasible"]
    @test result["termination_reason"]=="assessment_limited_line_search"
    @test result["design"]==[1.]
    @test length(result["history"])==1
    @test result["evaluations"]==25
    @test calls[]==25
    @test any(event->get(event,"event","")=="assessment_limited"&&occursin("membrane coverage",event["detail"]),events)
end

@testset "Independent final certificates invalidate only the superseded KKT claim" begin
    baseline=(x;need_gradient=true)->Dict{String,Any}("mass"=>x[1],"utilizations"=>[.25],
        "response_ids"=>["plate"],"complete"=>true,"mass_gradient"=>[1.],"jacobian"=>zeros(1,1))
    search=rf_optimize(baseline,[1.];lower=[1.],upper=[2.])
    @test search["converged"]
    for utilization in (.5,2.)
        result=deepcopy(search);saved=Ref{Any}(nothing);events=Any[]
        policy=RFOptimizationConstraintPolicy(1,Set(["plate"]))
        verified=[Dict("response_id"=>"plate","utilization"=>utilization)]
        rf_finalize_optimization_constraints!(result,policy,verified;
            checkpoint=data->saved[]=deepcopy(data),progress=event->push!(events,deepcopy(event)))
        @test !result["converged"]
        @test result["status"]=="partial"
        @test result["termination_reason"]=="final_verification_constraint_policy_changed"
        @test result["utilizations"]==[utilization]
        @test result["maximum_utilization"]==utilization
        @test result["feasible"]==(utilization<=1)
        @test result["final_verification"]["feasible"]==result["feasible"]
        @test result["constraint_violation"]==max(0.,utilization-1)
        @test result["stationarity_constraint_revision"]==0
        @test result["constraint_revision"]==1
        @test !result["kkt_valid_for_final_constraint_policy"]
        @test result["multipliers"]==[0.]
        @test result["best_feasible"]===nothing
        @test saved[]["constraint_revision"]==1
        @test saved[]["certified_bound_response_ids"]==["plate"]
        @test get(only(events),"event","")=="constraint_policy_changed"
    end
    unchanged=deepcopy(search)
    rf_finalize_optimization_constraints!(unchanged,RFOptimizationConstraintPolicy(),
        [Dict("response_id"=>"plate","utilization"=>.2)])
    @test unchanged["converged"]&&unchanged["kkt_valid_for_final_constraint_policy"]
    @test unchanged["utilizations"]==[.2]&&unchanged["maximum_utilization"]==.2
    @test_throws ArgumentError rf_finalize_optimization_constraints!(deepcopy(search),RFOptimizationConstraintPolicy(),
        [Dict("response_id"=>"another","utilization"=>.2)])
end

end # RFSizingOptimizerTests
