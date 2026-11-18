# Bounded, matrix-free RF sizing. The evaluator supplies true equilibrium
# derivatives; the fixed-force manual sizing preview is never used here.
using LinearAlgebra

"""Stable conservative KS upper bound and derivative weights.

The sum is deliberately not divided by the constraint count.
"""
function rf_ks(values::AbstractVector;rho::Real=50.)
    isfinite(rho)&&rho>0||throw(ArgumentError("KS sharpness must be finite and positive"))
    isempty(values)&&return (;value=-Inf,weights=Float64[],bound=0.)
    all(isfinite,values)||throw(ArgumentError("KS requires finite utilizations"))
    peak=maximum(values);exponents=exp.(rho.*(values.-peak));total=sum(exponents)
    (;value=peak+log(total)/rho,weights=exponents./total,bound=log(length(values))/rho)
end

function rf_sizing_evaluation(evaluate,x;need_gradient=true)
    result=evaluate(copy(x);need_gradient)
    result isa AbstractDict||throw(ArgumentError("The RF sizing evaluator must return an assessment object"))
    mass=Float64(result["mass"]);isfinite(mass)&&mass>0||throw(ArgumentError("Sizing requires positive finite model mass"))
    u=Float64.(result["utilizations"])
    !isempty(u)&&all(v->isfinite(v)&&v>=0,u)||throw(ArgumentError("Every selected sizing constraint needs a finite nonnegative utilization"))
    get(result,"complete",false)===true||throw(ArgumentError("Sizing stopped: assessment or derivative coverage is incomplete"))
    if need_gradient
        dm=Float64.(result["mass_gradient"])
        length(dm)==length(x)&&all(isfinite,dm)||throw(ArgumentError("Sizing mass gradient does not match design variables"))
        if !haskey(result,"vjp")
            jac=result["jacobian"]
            size(jac)==(length(u),length(x))&&all(isfinite,jac)||throw(ArgumentError("Sizing utilization Jacobian is incomplete"))
        end
    end
    result
end

rf_sizing_vjp(result,w)=haskey(result,"vjp") ? result["vjp"](w) : transpose(result["jacobian"])*w

function rf_sizing_constraint_policy(result)
    revision=get(result,"constraint_revision",0)
    revision isa Integer&&revision>=0||throw(ArgumentError("Sizing constraint revision must be a nonnegative integer"))
    raw=get(result,"certified_bound_response_ids",String[])
    raw isa AbstractVector||throw(ArgumentError("Sizing certified-bound IDs must be an array"))
    ids=String.(raw)
    length(unique(ids))==length(ids)||throw(ArgumentError("Sizing certified-bound IDs must be unique"))
    isempty(ids)==iszero(revision)||throw(ArgumentError("Sizing constraint revision and certified membership are inconsistent"))
    responses=String.(get(result,"response_ids",string.(eachindex(result["utilizations"]))))
    issubset(Set(ids),Set(responses))||throw(ArgumentError("A certified sizing constraint is absent from the response membership"))
    (;revision=Int(revision),ids=Set(ids))
end

function rf_sizing_policy_changed(previous,current)
    current.revision>=previous.revision&&issubset(previous.ids,current.ids)||
        throw(ArgumentError("Sizing constraint revisions and certified-bound membership must be monotonic"))
    if current.revision==previous.revision
        current.ids==previous.ids||throw(ArgumentError("Sizing constraint membership changed without a revision"))
        return false
    end
    current.ids!=previous.ids||throw(ArgumentError("Sizing constraint revision changed without a new certificate"))
    true
end

"""Describe the governing physical constraint across every selected case."""
function rf_sizing_constraint_summary(result)
    utilization=Float64.(result["utilizations"])
    index=argmax(utilization)
    maximum_utilization=utilization[index]
    ids=get(result,"response_ids",string.(eachindex(utilization)))
    rows=get(result,"response_details",get(result,"_rows",Any[]))
    row=length(rows)>=index ? rows[index] : Dict{String,Any}()
    Dict{String,Any}(
        "maximum_utilization"=>maximum_utilization,
        "minimum_rf"=>maximum_utilization>0 ? inv(maximum_utilization) : nothing,
        "critical_response_id"=>string(ids[index]),
        "critical_case_id"=>get(row,"case_id",nothing),
        "critical_case_label"=>get(row,"case_label",""),
        "critical_failure_mode"=>get(row,"failure_mode",""),
        "critical_scope"=>get(row,"label",get(row,"scope",get(row,"physical_criterion_id",string(ids[index])))),
        "critical_property_ids"=>get(row,"membership_pids",Int[]))
end

rf_sizing_number(value)=value===nothing ? "no demand" : string(round(value;sigdigits=6))

function rf_sizing_constraint_message(summary)
    description="minimum sizing RF $(rf_sizing_number(summary["minimum_rf"])), maximum utilization $(rf_sizing_number(summary["maximum_utilization"]))"
    case_label=summary["critical_case_label"]
    case_id=summary["critical_case_id"]
    if !isempty(string(case_label))
        description*="; governing case $case_label"
    elseif case_id!==nothing
        description*="; governing load case $case_id"
    end
    mode=summary["critical_failure_mode"]
    isempty(string(mode))||(description*="; "*replace(string(mode),'_'=>' '))
    properties=summary["critical_property_ids"]
    isempty(properties)||(description*="; properties "*join(("P$pid" for pid in properties),", "))
    description
end

function rf_sizing_merit(result,mass_scale,multipliers,penalty)
    g=Float64.(result["utilizations"]).-1.;shift=max.(0.,multipliers.+penalty.*g)
    result["mass"]/mass_scale+(sum(abs2,shift)-sum(abs2,multipliers))/(2penalty)
end

function rf_sizing_gradient(result,mass_scale,multipliers,penalty,scales)
    g=Float64.(result["utilizations"]).-1.;weights=max.(0.,multipliers.+penalty.*g)
    scales.*(result["mass_gradient"]./mass_scale.+rf_sizing_vjp(result,weights))
end

function rf_lbfgs_direction(gradient,history)
    q=copy(gradient);coefficients=Float64[]
    for (s,y,inverse) in Iterators.reverse(history)
        a=inverse*dot(s,q);push!(coefficients,a);q.-=a.*y
    end
    if !isempty(history)
        s,y,_=last(history);q.*=dot(s,y)/max(dot(y,y),eps())
    end
    for ((s,y,inverse),a) in zip(history,Iterators.reverse(coefficients))
        q.+=s.*(a-inverse*dot(y,q))
    end
    -q
end

"""Feasible first-order descent scaled to the relative move box.

The selected region may account for little of the full model's mass. Its
normalized objective gradient must determine descent, rather than imposing
arbitrarily tiny dimensional steps whenever curvature history is empty.
"""
function rf_projected_cauchy_direction(gradient,z,lower,upper,limit)
    direction=clamp.(z.-gradient,lower,upper).-z
    relative=maximum(abs.(direction)./limit)
    relative>0&&(direction./=relative)
    direction
end

"""Minimize mass with U<=1 and bounds using projected augmented-Lagrangian
L-BFGS and full-reanalysis line searches.

The evaluator returns mass, utilizations, stable response_ids, complete and
(when requested) mass_gradient plus jacobian or a vjp callback.
It must never substitute a fixed-force manual-sizing preview.
An iteration limit or invalid assessment is not labelled convergence.
Convergence requires feasible, complementary dual multipliers and projected
Lagrangian stationarity, relative to the initial scaled mass-gradient norm.
"""
function rf_optimize(evaluate,x0::AbstractVector;lower,upper,
        scales=max.(abs.(Float64.(x0)),1e-6),max_iterations::Int=60,
        inner_iterations::Int=10,move_limit::Real=.2,
        feasibility_tolerance::Real=1e-4,optimality_tolerance::Real=1e-4,
        initial_penalty::Real=1.,max_penalty::Real=1e9,
        memory::Int=8,cancelled=()->false,progress=data->nothing,
        checkpoint=data->nothing,restart=nothing)
    n=length(x0);n>0||throw(ArgumentError("Select at least one sizing variable"))
    length(lower)==length(upper)==length(scales)==n||throw(ArgumentError("Sizing bounds/scales must match variable count"))
    all(isfinite,x0)&&all(isfinite,lower)&&all(isfinite,upper)&&all(isfinite,scales)||throw(ArgumentError("Sizing coordinates and bounds must be finite"))
    all(scales.>0)&&all(lower.<=upper)||throw(ArgumentError("Sizing scales must be positive and bounds ordered"))
    max_iterations>0&&inner_iterations>0&&memory>0||throw(ArgumentError("Sizing iteration counts and memory must be positive"))
    0<move_limit<=1&&feasibility_tolerance>0&&optimality_tolerance>0&&0<initial_penalty<=max_penalty||throw(ArgumentError("Invalid sizing convergence or move controls"))
    lo=Float64.(lower)./scales;hi=Float64.(upper)./scales
    x=clamp.(Float64.(x0),lower,upper);z=x./scales;initial_projected=x!=Float64.(x0)
    cancelled()&&throw(InterruptException())
    current=rf_sizing_evaluation(evaluate,x);evaluations=1
    ids=String.(get(current,"response_ids",string.(eachindex(current["utilizations"]))))
    mass_scale=Float64(current["mass"]);multipliers=zeros(length(ids));penalty=Float64(initial_penalty)
    history=Any[];lbfgs=Tuple{Vector{Float64},Vector{Float64},Float64}[]
    previous_violation=Inf;converged=false;reason="iteration_limit";best_feasible=nothing
    policy=rf_sizing_constraint_policy(current)
    policy_history=restart===nothing ? Any[] : deepcopy(get(restart,"constraint_policy_history",Any[]))
    restart_policy_changed=false
    if restart!==nothing
        get(restart,"response_ids",nothing)==ids||throw(ArgumentError("Sizing restart response membership changed"))
        previous=Float64.(restart["design"])
        previous==x||throw(ArgumentError("Restore the saved sizing design before resuming multipliers"))
        multipliers=Float64.(restart["multipliers"])
        length(multipliers)==length(ids)&&all(v->isfinite(v)&&v>=0,multipliers)||throw(ArgumentError("Invalid saved sizing multipliers"))
        penalty=Float64(restart["penalty"]);0<penalty<=max_penalty||throw(ArgumentError("Invalid saved sizing penalty"))
        mass_scale=Float64(restart["mass_scale"]);isfinite(mass_scale)&&mass_scale>0||throw(ArgumentError("Invalid saved mass scaling"))
        saved_policy=rf_sizing_constraint_policy(merge(Dict("utilizations"=>current["utilizations"]),restart))
        restart_policy_changed=rf_sizing_policy_changed(saved_policy,policy)
        if restart_policy_changed
            multipliers=zeros(length(ids));penalty=Float64(initial_penalty)
        end
    end
    # A local sizing region may be a tiny fraction of the full model's mass.
    # Scale the KKT residuals by its initial objective gradient, rather than
    # accepting small absolute residuals caused by that fixed mass alone.
    kkt_scale=restart===nothing ? max(norm(scales.*current["mass_gradient"]./mass_scale),eps()) :
        Float64(get(restart,"kkt_scale",max(norm(scales.*current["mass_gradient"]./mass_scale),eps())))
    isfinite(kkt_scale)&&kkt_scale>0||throw(ArgumentError("Invalid saved KKT scaling"))
    save_checkpoint!()=checkpoint(Dict("design"=>copy(x),"multipliers"=>copy(multipliers),"penalty"=>penalty,
        "mass_scale"=>mass_scale,"kkt_scale"=>kkt_scale,"response_ids"=>ids,"history"=>history,
        "constraint_revision"=>policy.revision,"certified_bound_response_ids"=>sort!(collect(policy.ids)),
        "constraint_policy_history"=>deepcopy(policy_history)))
    function restart_constraint_policy!(reassessed,iteration,trigger)
        replacement=rf_sizing_constraint_policy(reassessed)
        rf_sizing_policy_changed(policy,replacement)||throw(ArgumentError("A sizing policy restart needs a new certified constraint"))
        previous=policy
        current=reassessed;policy=replacement
        multipliers=zeros(length(ids));penalty=Float64(initial_penalty)
        previous_violation=Inf;best_feasible=nothing;empty!(lbfgs)
        summary=rf_sizing_constraint_summary(current)
        entry=merge(Dict{String,Any}("iteration"=>iteration,"trigger"=>trigger,
            "previous_revision"=>previous.revision,"constraint_revision"=>policy.revision,
            "new_certified_bound_response_ids"=>sort!(collect(setdiff(policy.ids,previous.ids))),
            "certified_bound_response_ids"=>sort!(collect(policy.ids)),"accepted_design"=>copy(x),
            "mass"=>Float64(current["mass"]),"evaluations"=>evaluations,
            "constraint_violation"=>max(0.,maximum(current["utilizations"])-1.)),summary)
        push!(policy_history,entry)
        added=length(entry["new_certified_bound_response_ids"])
        message="Added $added certified conservative plate sizing check(s), advancing constraint policy from revision $(previous.revision) to $(policy.revision); independently reassessed the accepted design and reset constraint multipliers, penalty and L-BFGS history before continuing. "*rf_sizing_constraint_message(summary)
        progress(merge(Dict("phase"=>"optimization","event"=>"constraint_policy_restart",
            "detail"=>message,"log_message"=>message),entry))
        save_checkpoint!()
        nothing
    end
    if restart_policy_changed
        added=length(setdiff(policy.ids,Set(String.(get(restart,"certified_bound_response_ids",String[])))))
        message="Saved sizing policy was superseded by $added newly certified conservative plate check(s); restored dimensions and original mass scale, and reset multipliers and curvature history"
        entry=Dict{String,Any}("iteration"=>0,"trigger"=>"resume_reassessment",
            "previous_revision"=>Int(get(restart,"constraint_revision",0)),"constraint_revision"=>policy.revision,
            "certified_bound_response_ids"=>sort!(collect(policy.ids)),"accepted_design"=>copy(x))
        push!(policy_history,entry)
        progress(merge(Dict("phase"=>"optimization","event"=>"constraint_policy_restart",
            "detail"=>message,"log_message"=>message),entry))
    end
    baseline_summary=rf_sizing_constraint_summary(current)
    baseline_message="Initial structural mass $(rf_sizing_number(current["mass"])) kg; "*rf_sizing_constraint_message(baseline_summary)
    progress(merge(Dict("phase"=>"optimization","event"=>"baseline","detail"=>baseline_message,
        "log_message"=>baseline_message,"mass"=>Float64(current["mass"]),"constraint_count"=>length(ids),
        "design_variable_count"=>n),baseline_summary))
    gradient=zeros(n)
    for iteration in 1:max_iterations
        cancelled()&&throw(InterruptException())
        utilization=Float64.(current["utilizations"]);g=utilization.-1.
        violation=max(0.,maximum(g));gradient=rf_sizing_gradient(current,mass_scale,multipliers,penalty,scales)
        # This shifted multiplier is the dual candidate for the original
        # inequality-constrained problem. The augmented gradient equals the
        # Lagrangian gradient for this candidate, but stationarity alone does
        # not enforce complementary slackness when an old multiplier is large.
        dual=max.(0.,multipliers.+penalty.*g)
        # The Euclidean projected-gradient mapping measures the collective
        # descent of many local dimensions. An infinity norm can declare a
        # large sizing problem stationary when every individually small mass
        # partial is below tolerance but their aggregate improvement is large.
        augmented_pg=norm(z.-clamp.(z.-gradient,lo,hi))
        pg=norm(z.-clamp.(z.-gradient./kkt_scale,lo,hi))
        complementarity=norm(dual.*g,Inf)/kkt_scale
        if violation<=feasibility_tolerance&&(best_feasible===nothing||current["mass"]<best_feasible["mass"])
            best_feasible=Dict("design"=>copy(x),"mass"=>Float64(current["mass"]),"utilizations"=>copy(utilization))
        end
        record=Dict{String,Any}("iteration"=>iteration,"mass"=>Float64(current["mass"]),
            "maximum_utilization"=>maximum(utilization),"constraint_violation"=>violation,
            "projected_gradient_norm"=>pg,"complementarity_norm"=>complementarity,
            "complementarity_residual_norm"=>complementarity*kkt_scale,
            "augmented_projected_gradient_norm"=>augmented_pg,"kkt_scale"=>kkt_scale,
            "penalty"=>penalty,"design"=>copy(x),"evaluations"=>evaluations,
            "constraint_revision"=>policy.revision,"certified_bound_response_ids"=>sort!(collect(policy.ids)),
            "mass_change_kg"=>Float64(current["mass"])-mass_scale,
            "mass_change_percent"=>100*(Float64(current["mass"])/mass_scale-1))
        merge!(record,rf_sizing_constraint_summary(current))
        detail="Sizing iteration $iteration, mass $(rf_sizing_number(current["mass"])) kg, change $(rf_sizing_number(record["mass_change_kg"])) kg; "*rf_sizing_constraint_message(record)
        push!(history,record)
        progress(merge(Dict("phase"=>"optimization","event"=>"iteration","detail"=>detail,"log_message"=>detail),record))
        converged=violation<=feasibility_tolerance&&pg<=optimality_tolerance&&complementarity<=optimality_tolerance
        converged&&(multipliers=dual)
        save_checkpoint!()
        if converged
            reason="feasible_stationary_point"
            message="Sizing convergence passed at iteration $iteration; constraint violation $(rf_sizing_number(violation)), scaled stationarity $(rf_sizing_number(pg)), complementarity $(rf_sizing_number(complementarity))"
            progress(merge(Dict("phase"=>"optimization","event"=>"converged","detail"=>message,"log_message"=>message),record))
            break
        end
        if augmented_pg<=optimality_tolerance&&complementarity>optimality_tolerance
            # Finish a stationary augmented subproblem even if the scheduled
            # inner-iteration count has not elapsed. A slack constraint must
            # release its stale multiplier before mass descent can resume.
            multipliers=dual;empty!(lbfgs)
            gradient=rf_sizing_gradient(current,mass_scale,multipliers,penalty,scales)
            message="Updating constraint multipliers at iteration $iteration to satisfy complementary slackness before continuing mass sizing"
            progress(Dict("phase"=>"optimization","event"=>"multiplier_update","iteration"=>iteration,"detail"=>message,"log_message"=>message))
        end
        limit=move_limit.*max.(abs.(z),1.)
        direction=isempty(lbfgs) ? rf_projected_cauchy_direction(gradient,z,lo,hi,limit) : rf_lbfgs_direction(gradient,lbfgs)
        delta=clamp.(z.+direction,max.(lo,z.-limit),min.(hi,z.+limit)).-z
        if dot(gradient,delta)>=-eps()*max(norm(gradient)*norm(delta),1.)
            empty!(lbfgs);direction=rf_projected_cauchy_direction(gradient,z,lo,hi,limit)
            delta=clamp.(z.+direction,max.(lo,z.-limit),min.(hi,z.+limit)).-z
        end
        base_merit=rf_sizing_merit(current,mass_scale,multipliers,penalty)
        accepted=false;trial_z=z;step=1.;rejected_trials=0
        policy_restarted=false;valid_trials=0;assessment_failures=0
        for line in 1:24
            cancelled()&&throw(InterruptException())
            trial_z=clamp.(z.+step.*delta,lo,hi)
            norm(trial_z-z,Inf)<=1e-13&&break
            candidate=try
                evaluations+=1;rf_sizing_evaluation(evaluate,trial_z.*scales;need_gradient=false)
            catch error
                error isa InterruptException&&rethrow()
                assessment_failures+=1;record["last_rejected_trial"]=sprint(showerror,error);nothing
            end
            if candidate!==nothing
                String.(get(candidate,"response_ids",ids))==ids||throw(ArgumentError("RF membership changed during fixed-topology sizing"))
                candidate_policy=rf_sizing_constraint_policy(candidate)
                if rf_sizing_policy_changed(policy,candidate_policy)
                    # The candidate changed the mathematical constraint. Do not
                    # compare its merit against an accepted state using the old
                    # criterion or keep curvature/dual history from that policy.
                    reassessed=rf_sizing_evaluation(evaluate,x);evaluations+=1
                    String.(get(reassessed,"response_ids",ids))==ids||throw(ArgumentError("RF membership changed during policy reassessment"))
                    rf_sizing_policy_changed(candidate_policy,rf_sizing_constraint_policy(reassessed))
                    restart_constraint_policy!(reassessed,iteration,"line_search_candidate")
                    record["constraint_policy_restarted"]=true
                    policy_restarted=true;break
                end
                valid_trials+=1
                merit=rf_sizing_merit(candidate,mass_scale,multipliers,penalty)
                if merit<=base_merit+1e-4*dot(gradient,trial_z-z)
                    accepted=true;break
                end
            end
            rejected_trials+=1
            step*=.5
        end
        policy_restarted&&continue
        if accepted
            old_z=copy(z);old_gradient=gradient
            z=trial_z;x=z.*scales;current=rf_sizing_evaluation(evaluate,x);evaluations+=1
            String.(get(current,"response_ids",ids))==ids||throw(ArgumentError("RF response ordering changed during sizing"))
            if rf_sizing_policy_changed(policy,rf_sizing_constraint_policy(current))
                restart_constraint_policy!(current,iteration,"accepted_design_derivatives")
                record["constraint_policy_restarted"]=true
                continue
            end
            new_gradient=rf_sizing_gradient(current,mass_scale,multipliers,penalty,scales)
            s=z-old_z;y=new_gradient-old_gradient;curvature=dot(s,y)
            if curvature>1e-10*norm(s)*norm(y)
                push!(lbfgs,(s,y,1/curvature));length(lbfgs)>memory&&popfirst!(lbfgs)
            end
            record["step"]=step
            summary=rf_sizing_constraint_summary(current)
            message="Accepted sizing step $(rf_sizing_number(step)) at iteration $iteration after $rejected_trials rejected trial(s); structural mass $(rf_sizing_number(current["mass"])) kg; "*rf_sizing_constraint_message(summary)
            progress(merge(Dict("phase"=>"optimization","event"=>"step_accepted","iteration"=>iteration,
                "step"=>step,"rejected_trials"=>rejected_trials,"mass"=>Float64(current["mass"]),
                "evaluations"=>evaluations,"detail"=>message,"log_message"=>message),summary))
        else
            if violation<=feasibility_tolerance&&valid_trials==0&&assessment_failures>0
                reason="assessment_limited_line_search"
                message="Sizing stopped at the last assessed feasible design: all $assessment_failures trial assessments failed. "*get(record,"last_rejected_trial","Review the trial assessment before continuing")
                progress(Dict("phase"=>"optimization","event"=>"assessment_limited",
                    "iteration"=>iteration,"rejected_trials"=>rejected_trials,
                    "detail"=>message,"log_message"=>message))
                save_checkpoint!()
                break
            end
            message="Sizing line search found no acceptable step at iteration $iteration after $rejected_trials trial(s); updating the constraint penalty and multipliers"
            progress(Dict("phase"=>"optimization","event"=>"step_rejected","iteration"=>iteration,
                "rejected_trials"=>rejected_trials,"detail"=>message,"log_message"=>message))
        end
        if iteration%inner_iterations==0||!accepted
            g=Float64.(current["utilizations"]).-1.;v=max(0.,maximum(g))
            multipliers=max.(0.,multipliers.+penalty.*g)
            v>feasibility_tolerance&&v>.5previous_violation&&(penalty=min(max_penalty,10penalty))
            previous_violation=v;empty!(lbfgs)
            if !accepted&&penalty>=max_penalty
                reason="line_search_failed";break
            end
        end
    end
    final_u=Float64.(current["utilizations"])
    final_dual=converged ? copy(multipliers) : max.(0.,multipliers.+penalty.*(final_u.-1.))
    final_gradient=converged ? gradient : scales.*(current["mass_gradient"]./mass_scale.+rf_sizing_vjp(current,final_dual))
    final_pg=norm(z.-clamp.(z.-final_gradient./kkt_scale,lo,hi))
    final_complementarity=norm(final_dual.*(final_u.-1.),Inf)/kkt_scale
    summary=rf_sizing_constraint_summary(current)
    message="Sizing search finished after $(length(history)) iteration(s) and $evaluations evaluation(s), termination $reason; mass $(rf_sizing_number(current["mass"])) kg; "*rf_sizing_constraint_message(summary)*". Independent final FE verification follows"
    progress(merge(Dict("phase"=>"optimization","event"=>"search_finished","detail"=>message,"log_message"=>message),summary))
    result=Dict{String,Any}("status"=>converged ? "converged" : "not_converged","converged"=>converged,
        "termination_reason"=>reason,"design"=>copy(x),"mass"=>Float64(current["mass"]),
        "initial_mass"=>mass_scale,"utilizations"=>final_u,"response_ids"=>ids,
        "maximum_utilization"=>maximum(final_u),"feasible"=>maximum(final_u)<=1+feasibility_tolerance,
        "history"=>history,"evaluations"=>evaluations,"best_feasible"=>best_feasible,
        "constraint_revision"=>policy.revision,"certified_bound_response_ids"=>sort!(collect(policy.ids)),
        "constraint_policy_history"=>policy_history,"constraint_policy_restarts"=>length(policy_history),
        "initial_design_projected_to_bounds"=>initial_projected,"method"=>"projected_augmented_lagrangian_lbfgs",
        "multipliers"=>final_dual,"penalty"=>penalty,"mass_scale"=>mass_scale,"kkt_scale"=>kkt_scale,
        "projected_gradient_norm"=>final_pg,"complementarity_norm"=>final_complementarity,
        "augmented_projected_gradient_norm"=>norm(z.-clamp.(z.-final_gradient,lo,hi)),
        "complementarity_residual_norm"=>final_complementarity*kkt_scale,
        "constraint_violation"=>max(0.,maximum(final_u)-1.),
        "verification"=>"Full-equilibrium assessments; independent final replay required",
        "mass_change_kg"=>Float64(current["mass"])-mass_scale,
        "mass_change_percent"=>100*(Float64(current["mass"])/mass_scale-1))
    merge!(result,summary)
    result
end
