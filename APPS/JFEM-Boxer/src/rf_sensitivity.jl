# Full-equilibrium RF assessment/sizing orchestration. This is independent of
# browser preview state; every derivative belongs to an accepted native solve.
const RF_DERIVATIVE_VERSION=1

function rf_json_safe(value)
    value isa Real&&return isfinite(value) ? value : nothing
    value isa AbstractMatrix&&return [rf_json_safe(collect(row)) for row in eachrow(value)]
    value isa AbstractDict&&return Dict(string(k)=>rf_json_safe(v) for (k,v) in value if !startswith(string(k),"_")&&!(v isa Function))
    value isa NamedTuple&&return Dict(string(k)=>rf_json_safe(v) for (k,v) in pairs(value) if !(v isa Function))
    value isa Union{AbstractVector,Tuple}&&return rf_json_safe.(collect(value))
    value isa Function&&return nothing
    value
end

function rf_signatures(m,request=Dict())
    assessment=Dict("policy"=>assessment_policy_payload(m.params),
        "allowables"=>get(m.params,"materials.allowables",Any[]),
        "fixities"=>Dict(k=>v for (k,v) in m.params if occursin("fixity",k)),
        "method"=>get(request,"method","maximum"),"percentile"=>get(request,"percentile",95),
        "cases"=>get(request,"case_ids",Any[]),"version"=>RF_DERIVATIVE_VERSION)
    hashvalue(x)=bytes2hex(SHA.sha256(JSON.json(sensitivity_canonical(x))))
    Dict("equilibrium"=>sensitivity_model_signature(m),
        "assessment"=>hashvalue(assessment),"design"=>hashvalue(Dict("variables"=>get(request,"variables",Any[]),
            "ties"=>get(request,"ties",Any[]),"bounds"=>get(request,"bounds",Any[]),"version"=>RF_DERIVATIVE_VERSION)))
end

"""Materialize inherited local dimensions at their unchanged physical values.
This makes the optimizer map explicit: selecting a local variable cannot
silently change which properties a shared default controls on the next step.
The authored Study and its minimum gauges are not mutated.
"""
function rf_materialized_model(m)
    is_imported_model(m)&&return m
    local_variables=[d for d in sensitivity_catalog(m;allow_semismooth=true)["variables"] if
        (haskey(d,"component_key")||haskey(d,"panel_key"))&&get(d,"inherited",false)]
    isempty(local_variables)&&return m
    parameters=deepcopy(m.params)
    for d in local_variables;sensitivity_set!(parameters,d,d["value"]);end
    sensitivity_model(m,parameters)
end

function rf_design_catalog(m;materialize=true)
    materialize&&(m=rf_materialized_model(m))
    catalog=sensitivity_catalog(m;allow_semismooth=true);variables=Any[]
    for raw in catalog["variables"]
        d=copy(raw);path=d["path"]
        field=length(path)>1 ? string(last(path)) : last(split(get(d,"field_key",string(last(path))),'.'))
        field=="square_side"&&(field="side")
        floors=Float64[]
        if get(d,"unit","")=="m"
            for pid in get(d,"pids",Int[])
                gauge=try property_minimum_gauge(m.params,pid) catch;nothing;end
                gauge===nothing&&continue
                for dimension in get(gauge,"dimensions",Any[])
                    last(split(dimension["field"],'.'))==field&&push!(floors,Float64(dimension["minimum_m"])/d["scale"])
                end
            end
            d["lower_bound"]=isempty(floors) ? Float64(d["value"]) : maximum(floors)
            d["upper_bound"]=max(5Float64(d["value"]),5d["lower_bound"],1e-8)
            d["sizing_variable"]=true
        else
            # Material changes require deliberate selection and explicit bounds;
            # reducing E or density is not an automatic sizing mechanism.
            d["lower_bound"]=Float64(d["value"]);d["upper_bound"]=Float64(d["value"])
            d["sizing_variable"]=false
        end
        d["min"]=d["lower_bound"];d["max"]=d["upper_bound"]
        push!(variables,d)
    end
    cases=[Dict("id"=>c.id,"label"=>c.label,"solution"=>string(get(c.params,"output.solution","101")),
        "available"=>string(get(c.params,"output.solution","101")) in ("101","106")&&
            !get(c.params,"loads.follower_forces",false),
        "reason"=>get(c.params,"loads.follower_forces",false) ? "RF derivatives require fixed-direction loads; follower-load tangents are not enabled" :
            string(get(c.params,"output.solution","101")) in ("101","106") ? "" :
            "RF sizing requires physical SOL101 or supported full-load SOL106 results, rather than normalized eigenmodes")
        for c in load_case_specs(m.params)]
    merge(catalog,Dict("variables"=>variables,"cases"=>cases,"rf_derivative_version"=>RF_DERIVATIVE_VERSION,
        "capabilities"=>Dict("SOL101"=>true,"SOL106"=>true,"fixed_geometry"=>true,
            "frozen_aerodynamics"=>true,"structural_inertia"=>true,"inertia_relief"=>false,
            "aeroelastic_derivatives"=>false,"imported_engineering_criteria"=>false),
        "note"=>"True equilibrium sensitivities of physical RF criteria. No fixed-force preview or finite-difference fallback. Unsupported states remain explicitly unassessed."))
end

function rf_request(m,raw)
    raw isa AbstractDict||throw(ArgumentError("RF derivative request must be an object"))
    request=Dict{String,Any}(string(k)=>v for (k,v) in raw if k!="parameters"&&k!="params")
    options=get(request,"options",Dict())
    options isa AbstractDict||throw(ArgumentError("RF options must be an object"))
    for field in ("bounds","block_size","method","percentile")
        haskey(request,field)||!haskey(options,field)||(request[field]=options[field])
    end
    operation=String(get(request,"operation","jacobian"))
    operation in ("jacobian","jvp","vjp","directional","optimize","assess")||throw(ArgumentError("Unknown RF derivative operation"))
    request["operation"]=operation
    quantity=String(get(request,"quantity","utilization"))
    quantity in ("utilization","rf","reserve_factor")||throw(ArgumentError("Choose utilization or RF derivatives"))
    request["quantity"]=quantity=="reserve_factor" ? "rf" : quantity
    catalog=rf_design_catalog(m);lookup=Dict(d["id"]=>d for d in catalog["variables"])
    ids=String.(get(request,"variables",String[]))
    operation=="assess"||!isempty(ids)||throw(ArgumentError("Select at least one physical dimension"))
    length(unique(ids))==length(ids)&&all(id->haskey(lookup,id),ids)||throw(ArgumentError("Selected RF variables are duplicated or no longer control this model"))
    request["variables"]=ids
    response_ids=String.(get(request,"response_ids",String[]))
    length(unique(response_ids))==length(response_ids)||throw(ArgumentError("Select distinct physical RF responses"))
    request["response_ids"]=response_ids
    for field in ("direction","weights")
        values=get(request,field,nothing);values===nothing&&continue
        values isa AbstractVector&&all(v->v isa Real&&!(v isa Bool)&&isfinite(v),values)||
            throw(ArgumentError("RF $field must be a vector of finite numbers"))
    end
    cases=load_case_specs(m.params);case_ids=get(request,"case_ids",[c.id for c in cases])
    case_ids isa AbstractVector&&!isempty(case_ids)||throw(ArgumentError("Select at least one load case"))
    length(unique(string.(case_ids)))==length(case_ids)||throw(ArgumentError("RF load case IDs must be distinct"))
    all(id->any(c->string(c.id)==string(id),cases),case_ids)||throw(ArgumentError("A requested RF load case is no longer enabled"))
    all(c->!(string(c.id) in string.(case_ids))||string(get(c.params,"output.solution","101")) in ("101","106"),cases)||
        throw(ArgumentError("RF derivatives require physical SOL101 or supported full-load SOL106 results"))
    operation!="assess"&&any(c->string(c.id) in string.(case_ids)&&get(c.params,"loads.follower_forces",false),cases)&&
        throw(ArgumentError("RF derivatives require fixed-direction loads in SOL101 and SOL106; design-dependent follower-load tangents are not silently omitted"))
    request["case_ids"]=case_ids
    block=Int(get(request,"block_size",32));1<=block<=256||throw(ArgumentError("RF block size must be between 1 and 256"))
    request["block_size"]=block;request["version"]=RF_DERIVATIVE_VERSION
    request
end

function rf_optimization_dimension_updates(design,final_values)
    physical_values=design.P*final_values
    lower=design.P*Float64[variable["lower_bound"] for variable in design.variables]
    upper=design.P*Float64[variable["upper_bound"] for variable in design.variables]
    updates=Dict{String,Any}[]
    for (index,variable) in enumerate(design.physical)
        update=Dict{String,Any}()
        for key in ("id","label","unit","path","pids","component_key","panel_key","field_key","scale")
            haskey(variable,key)&&(update[key]=variable[key])
        end
        initial=Float64(variable["value"])
        optimized=Float64(physical_values[index])
        merge!(update,Dict("initial_value"=>initial,"optimized_value"=>optimized,
            "lower_bound"=>lower[index],"upper_bound"=>upper[index],
            "membership_pids"=>get(variable,"membership_pids",get(variable,"pids",Int[])),
            "change"=>optimized-initial,"change_percent"=>iszero(initial) ? nothing : 100*(optimized/initial-1)))
        push!(updates,update)
    end
    updates
end

"""Install independently verified constraints without reusing stale KKT claims."""
function rf_finalize_optimization_constraints!(result,constraint_policy,verified_constraints;
        tolerance=1e-4,checkpoint=_ -> nothing,progress=_ -> nothing)
    ids=String[row["response_id"] for row in verified_constraints]
    ids==String.(result["response_ids"])||throw(ArgumentError("Final independent RF response membership changed"))
    prior_policy=rf_sizing_constraint_policy(result)
    metadata=rf_optimization_policy_metadata(constraint_policy)
    replacement=rf_sizing_constraint_policy(merge(result,metadata))
    changed=rf_sizing_policy_changed(prior_policy,replacement)
    utilization=Float64[row["utilization"] for row in verified_constraints]
    result["response_ids"]=ids;result["utilizations"]=utilization
    result["feasible"]=maximum(utilization)<=1+tolerance
    result["final_verification"]=Dict("complete"=>true,"maximum_utilization"=>maximum(utilization),
        "feasible"=>result["feasible"],"independent_forward_solve"=>true,
        "certified_bound_response_ids"=>metadata["certified_bound_response_ids"],
        "constraint_revision"=>constraint_policy.revision,"constraint_policy_changed"=>changed,
        "scope"=>"Selected physical criteria and load cases")
    result["converged"]=result["converged"]&&result["feasible"]&&!changed
    result["stationarity_constraint_revision"]=prior_policy.revision
    result["kkt_valid_for_final_constraint_policy"]=!changed
    merge!(result,metadata)
    if changed
        result["termination_reason"]="final_verification_constraint_policy_changed"
        result["multipliers"]=zeros(length(ids));result["penalty"]=1.
        result["best_feasible"]=nothing
        entry=Dict{String,Any}("trigger"=>"independent_final_verification","previous_revision"=>prior_policy.revision,
            "constraint_revision"=>constraint_policy.revision,
            "certified_bound_response_ids"=>metadata["certified_bound_response_ids"],"accepted_design"=>copy(result["design"]))
        push!(result["constraint_policy_history"],entry)
        result["constraint_policy_restarts"]=length(result["constraint_policy_history"])
        added=length(setdiff(replacement.ids,prior_policy.ids))
        message="Final independent verification required $added additional certified conservative plate check(s). Feasibility is reassessed, but stationarity under the new constraint policy is not verified; resume sizing to establish convergence"
        progress(merge(Dict("phase"=>"final_verification","event"=>"constraint_policy_changed",
            "detail"=>message,"log_message"=>message),entry))
        checkpoint(Dict("design"=>copy(result["design"]),"multipliers"=>copy(result["multipliers"]),
            "penalty"=>result["penalty"],"mass_scale"=>result["mass_scale"],"kkt_scale"=>result["kkt_scale"],
            "response_ids"=>ids,"history"=>result["history"],
            "constraint_revision"=>constraint_policy.revision,
            "certified_bound_response_ids"=>metadata["certified_bound_response_ids"],
            "constraint_policy_history"=>result["constraint_policy_history"]))
    end
    result["status"]=result["converged"] ? "complete" : "partial"
    result["maximum_utilization"]=maximum(utilization)
    result["constraint_violation"]=max(0.,maximum(utilization)-1.)
    utilization
end

function rf_optimization_gradient_progress(progress,event;case_count,design_variable_count,
        physical_dimension_count,active_constraint_count=0,adjoint_rhs=0)
    phase="gradient"
    if event===:preparation
        name="gradient_preparation"
        message="Preparing sizing gradients for $design_variable_count independent dimensions ($physical_dimension_count physical dimensions) across $case_count load case(s)"
    elseif event===:mass_ready
        name="mass_gradient_ready"
        message="Structural mass gradient ready for $design_variable_count independent sizing dimensions"
    elseif event===:weights&&iszero(active_constraint_count)
        name="mass_gradient_only"
        message="Current RF adjoint weights are zero; this step uses the structural mass gradient. No RF adjoint RHS is required"
    elseif event===:weights
        phase="adjoint";name="adjoint_gradient_started"
        message="Preparing weighted RF adjoint gradient for $active_constraint_count active constraint(s) across $case_count selected load case(s)"
    elseif event===:adjoint_ready
        phase="adjoint";name="adjoint_gradient_ready"
        message="Weighted RF gradient ready; $adjoint_rhs adjoint right-hand side(s) solved for $active_constraint_count active constraint(s)"
    else
        throw(ArgumentError("Unknown sizing gradient progress event"))
    end
    data=Dict{String,Any}("phase"=>phase,"event"=>name,"detail"=>message,"log_message"=>message,
        "case_count"=>case_count,"design_variable_count"=>design_variable_count,
        "physical_dimension_count"=>physical_dimension_count,"active_constraint_count"=>active_constraint_count)
    event===:adjoint_ready&&(data["adjoint_rhs"]=adjoint_rhs)
    progress(data)
end

function compute_rf_optimization(m,request,directory,design;native,solve,progress=_ -> nothing,cancelled=()->false)
    options=get(request,"options",Dict());frozen_loads=Dict{String,Any}()
    evaluations=Ref(0);last_design=Ref{Any}(nothing);cached=Ref{Any}(nothing)
    initial_ids=Ref{Any}(nothing);constraint_policy=RFOptimizationConstraintPolicy(get(request,"restart",nothing))
    base_request=merge(request,Dict("operation"=>"jacobian","quantity"=>"utilization"))
    cases=[case for case in load_case_specs(m.params) if string(case.id) in string.(request["case_ids"])]
    case_descriptions=[Dict("id"=>case.id,"label"=>case.label,"solution"=>string(get(case.params,"output.solution","101"))) for case in cases]
    start_message="Minimum-mass sizing started with $(length(design.variables)) independent dimensions, $(length(design.physical)) physical dimensions and $(length(cases)) load case(s). All selected RF checks use one shared structural design"
    progress(Dict("phase"=>"optimization","event"=>"start","detail"=>start_message,"log_message"=>start_message,
        "design_variable_count"=>length(design.variables),"physical_dimension_count"=>length(design.physical),
        "case_ids"=>request["case_ids"]))
    for case in case_descriptions
        message="Sizing includes load case $(case["id"]), $(case["label"]), SOL$(case["solution"]); every selected strength and buckling check is enforced for this case"
        progress(Dict("phase"=>"optimization","event"=>"case_included","case_id"=>case["id"],
            "case_label"=>case["label"],"detail"=>message,"log_message"=>message))
    end
    function add_derivatives!(result,state)
        gradient_progress=(event;kwargs...)->rf_optimization_gradient_progress(progress,event;
            case_count=length(cases),design_variable_count=length(design.variables),
            physical_dimension_count=length(design.physical),kwargs...)
        gradient_progress(:preparation)
        contexts=state.contexts
        if isempty(contexts)
            factorizations=Dict{String,Any}()
            for (id,case) in state.forwards
                contexts[id]=rf_derivative_context(native,case.forward,case.wing;factorizations)
            end
        end
        same_state_bases=Dict{String,Any}()
        for row in state.rows
            modes=get(row,"selected_modes",nothing)
            modes===nothing||isempty(modes)||(same_state_bases[row["response_id"]]=[Tuple(Int.(mode)) for mode in modes])
        end
        assessment=state.derivatives_ready ?
            state.assessment : rf_assessment_values(state.input;derivatives=true,frozen_bases=same_state_bases,progress,cancelled)
        lookup=Dict(r["response_id"]=>r for r in assessment["responses"])
        rows=rf_optimization_responses([lookup[id] for id in result["response_ids"]],constraint_policy.bound_ids;discover=false)
        all(rf_derivative_row_status(r)!="unavailable" for r in rows)||
            throw(ArgumentError("A selected RF has no unique supported derivative; inspect its branch or basis status"))
        first_context=first(values(contexts))
        mass_gradient=Float64[rf_residual_design_column(native,first_context,v;cancelled).mass_derivative for v in design.physical]
        result["mass_gradient"]=transpose(design.P)*mass_gradient
        gradient_progress(:mass_ready)
        result["vjp"]=weights->begin
            active=count(value->!iszero(value),weights)
            gradient_progress(:weights;active_constraint_count=active)
            r=rf_vjp(native,contexts,rows,design.physical,weights;
                capacity_row_jvp=rf_capacity_callback,cancelled)
            active>0&&gradient_progress(:adjoint_ready;active_constraint_count=active,adjoint_rhs=r.adjoint_rhs)
            transpose(design.P)*r.values
        end
        result["_contexts"]=contexts;result["_rows"]=rows;result
    end
    function evaluate(x;need_gradient=true)
        cancelled()&&throw(InterruptException())
        if rf_optimization_cache_valid(last_design[],cached[],x,constraint_policy)
            need_gradient&&!haskey(cached[],"mass_gradient")&&add_derivatives!(cached[],cached[]["_evaluation"])
            return cached[]
        end
        params=deepcopy(m.params);physical_values=design.P*x
        for (variable,value) in zip(design.physical,physical_values);sensitivity_set!(params,variable,value);end
        validate_params(params);candidate=sensitivity_model(m,params)
        evaluations[]+=1;dir=joinpath(directory,"design_$(lpad(evaluations[],5,'0'))")
        message="Evaluating sizing design $(evaluations[]) across $(length(cases)) load case(s)"
        progress(Dict("phase"=>"optimization","event"=>"evaluation_started","evaluation"=>evaluations[],
            "detail"=>message,"log_message"=>message))
        # Every changed design reselects and verifies its critical plate modes.
        # A frozen basis is used only when differentiating this identical state.
        state=rf_evaluate_design(candidate,base_request,dir;native,solve,progress,cancelled,frozen_loads,
            derivatives=need_gradient)
        rows=rf_optimization_policy_responses!(constraint_policy,state.rows)
        all(r["status"]=="ok" for r in rows)||throw(ArgumentError("Sizing requires complete selected RF coverage: "*join(unique(string(get(r,"reason","Unavailable assessment")) for r in rows if r["status"]!="ok"),"; ")))
        any(get(r,"approximation",false)||get(r,"converged",true)===false for r in rows)&&
            throw(ArgumentError("A selected plate RF is approximate; refine its basis before optimizing this constraint"))
        ids=String[r["response_id"] for r in rows]
        initial_ids[]===nothing ? (initial_ids[]=ids) : initial_ids[]==ids||throw(ArgumentError("Physical RF membership changed during sizing"))
        mass=weights_payload(candidate;include_mass_properties=false)["totals"]["structure_mass_kg"]
        result=Dict{String,Any}("mass"=>mass,"utilizations"=>Float64[r["utilization"] for r in rows],
            "response_ids"=>ids,"complete"=>true,"_parameters"=>params,"_rows"=>rows,"_directory"=>dir,"_evaluation"=>state)
        merge!(result,rf_optimization_policy_metadata(constraint_policy))
        summary=rf_sizing_constraint_summary(result)
        message="Sizing design $(evaluations[]) assessed, structural mass $(rf_sizing_number(mass)) kg; "*rf_sizing_constraint_message(summary)
        progress(merge(Dict("phase"=>"optimization","event"=>"evaluation_completed","evaluation"=>evaluations[],
            "mass"=>mass,"constraint_count"=>length(rows),"detail"=>message,"log_message"=>message),summary))
        if need_gradient
            add_derivatives!(result,state)
        end
        last_design[]=copy(x);cached[]=result;result
    end
    lower=Float64[v["lower_bound"] for v in design.variables]
    upper=Float64[v["upper_bound"] for v in design.variables]
    x0=Float64[v["value"] for v in design.variables]
    checkpoint=data->sensitivity_json_write(joinpath(directory,"sizing_checkpoint.json"),rf_json_safe(data))
    result=rf_optimize(evaluate,x0;lower,upper,
        max_iterations=Int(get(options,"max_iterations",60)),inner_iterations=Int(get(options,"inner_iterations",5)),
        move_limit=Float64(get(options,"move_limit",.2)),
        feasibility_tolerance=Float64(get(options,"tolerance",1e-4)),
        optimality_tolerance=Float64(get(options,"optimality_tolerance",1e-4)),
        progress,cancelled,checkpoint,restart=get(request,"restart",nothing))
    final_x=result["design"];final_params=deepcopy(m.params)
    for (variable,value) in zip(design.physical,design.P*final_x);sensitivity_set!(final_params,variable,value);end
    # Independent final forward solve. Never reuse a line-search RF estimate or
    # a merely compatible browser result as final verification.
    final_model=sensitivity_model(m,final_params)
    verification_message="Independently solving and reassessing the final sizing design across all $(length(cases)) selected load case(s)"
    progress(Dict("phase"=>"final_verification","event"=>"verification_started",
        "detail"=>verification_message,"log_message"=>verification_message))
    verified=rf_evaluate_design(final_model,base_request,joinpath(directory,"final_verification");
        native,solve,progress,cancelled,frozen_loads,derivatives=false)
    verified_constraints=rf_optimization_policy_responses!(constraint_policy,verified.rows)
    all(r["status"]=="ok" for r in verified_constraints)||throw(ArgumentError("Final design has an unassessed RF; optimization is not verified"))
    tolerance=Float64(get(options,"tolerance",1e-4))
    utilization=rf_finalize_optimization_constraints!(result,constraint_policy,verified_constraints;
        tolerance,checkpoint,progress)
    final_summary=rf_sizing_constraint_summary(Dict("utilizations"=>utilization,
        "response_ids"=>[row["response_id"] for row in verified_constraints],"_rows"=>verified_constraints))
    merge!(result,final_summary)
    verified_message=result["final_verification"]["feasible"] ? "passed" : "completed with RF constraints below the target"
    final_message="Final independent verification $verified_message. Structural mass $(rf_sizing_number(result["mass"])) kg, change $(rf_sizing_number(result["mass_change_kg"])) kg; "*rf_sizing_constraint_message(final_summary)
    progress(merge(Dict("phase"=>"final_verification","event"=>"verification_completed",
        "detail"=>final_message,"log_message"=>final_message,"mass"=>result["mass"],
        "constraint_count"=>length(verified_constraints)),final_summary))
    merge!(result,Dict("format"=>"jfem-rf-sizing-1","operation"=>"optimize","quantity"=>"utilization",
        "variables"=>design.variables,"optimized_params"=>final_params,"responses"=>[rf_public_response(r) for r in verified.rows],
        "dimension_updates"=>rf_optimization_dimension_updates(design,final_x),"load_cases"=>case_descriptions,
        "optimization_constraints"=>[rf_public_response(r) for r in verified_constraints],
        "property_envelopes"=>rf_property_envelopes(verified.rows),
        "signatures"=>rf_signatures(m,request),"mass_label"=>"Structural mass including fixed non-structural mass",
        "model_modified"=>false,"study_saved"=>false,"metadata"=>Dict("full_equilibrium_evaluations"=>evaluations[],
            "fixed_force_estimate"=>false,"method"=>result["method"],
            "load_case_policy"=>"One shared design must satisfy every selected RF constraint in every selected load case")))
    sensitivity_json_write(joinpath(directory,"optimized_parameters.json"),final_params)
    rf_json_safe(result)
end

function rf_selected_variables(m,request)
    lookup=Dict(d["id"]=>copy(d) for d in rf_design_catalog(m)["variables"])
    variables=[lookup[id] for id in request["variables"]]
    bounds=get(request,"bounds",Any[])
    bounds isa AbstractDict&&(bounds=[merge(Dict("id"=>string(id)),value) for (id,value) in bounds])
    for row in bounds
        id=String(row["id"]);haskey(lookup,id)||throw(ArgumentError("Unknown bounded design variable $id"))
        d=lookup[id];lo=Float64(get(row,"min",get(row,"lower_bound",d["lower_bound"])))
        hi=Float64(get(row,"max",get(row,"upper_bound",d["upper_bound"])))
        all(isfinite,(lo,hi))&&0<=lo<=hi||throw(ArgumentError("Sizing bounds must be finite, nonnegative and ordered"))
        lo+1e-12max(1.,abs(lo))>=d["lower_bound"]||throw(ArgumentError("A sizing bound cannot reduce the Study minimum gauge for $id"))
        d["lower_bound"]=lo;d["upper_bound"]=hi;d["min"]=lo;d["max"]=hi
    end
    variables
end

"""Explicit tied-variable map. Ratios are positive and units must agree."""
function rf_design_map(variables,ties=Any[])
    N=length(variables);lookup=Dict(d["id"]=>i for (i,d) in enumerate(variables))
    assigned=falses(N);columns=Any[];ii=Int[];jj=Int[];values=Float64[]
    for (k,tie) in enumerate(ties)
        members=get(tie,"members",Any[]);!isempty(members)||throw(ArgumentError("A tied group needs member dimensions"))
        unit=nothing;value=nothing;lo=-Inf;hi=Inf;column=length(columns)+1
        for member in members
            id=member isa AbstractString ? member : member["id"]
            haskey(lookup,id)||throw(ArgumentError("Tied dimension $id is not selected"))
            i=lookup[id];assigned[i]&&throw(ArgumentError("Dimension $id belongs to more than one tied group"))
            d=variables[i];ratio=member isa AbstractString ? 1. : Float64(get(member,"ratio",1.))
            isfinite(ratio)&&ratio>0||throw(ArgumentError("Tied dimension ratios must be positive"))
            unit===nothing ? (unit=d["unit"]) : unit==d["unit"]||throw(ArgumentError("Tied dimensions need matching units"))
            v=d["value"]/ratio;value===nothing ? (value=v) : isapprox(value,v;rtol=1e-10,atol=1e-14)||throw(ArgumentError("Starting dimensions do not satisfy the selected tie ratios"))
            lo=max(lo,d["lower_bound"]/ratio);hi=min(hi,d["upper_bound"]/ratio)
            push!(ii,i);push!(jj,column);push!(values,ratio);assigned[i]=true
        end
        lo<=hi||throw(ArgumentError("Tied dimensions have incompatible bounds"))
        push!(columns,Dict("id"=>String(get(tie,"id","tie_$k")),"label"=>String(get(tie,"label","Tied group $k")),
            "value"=>value,"unit"=>unit,"lower_bound"=>lo,"upper_bound"=>hi,"min"=>lo,"max"=>hi,"members"=>members))
    end
    for (i,d) in enumerate(variables)
        assigned[i]&&continue
        push!(ii,i);push!(jj,length(columns)+1);push!(values,1.);push!(columns,d)
    end
    (;physical=variables,variables=columns,P=sparse(ii,jj,values,N,length(columns)))
end

# Sparse tie-map multiplication must not let 0*NaN spread an unavailable
# derivative into unrelated independent columns.
function rf_chain_jacobian(J,P::SparseMatrixCSC)
    out=zeros(size(J,1),size(P,2));rows=rowvals(P);values=nonzeros(P)
    for k in axes(P,2),entry in nzrange(P,k)
        out[:,k].+=values[entry].*view(J,:,rows[entry])
    end
    out
end

function rf_native_input(m,case_records;request=Dict(),metadata=nothing)
    elements=Dict{String,Any}()
    for g in m.groups
        isempty(g.eids)&&continue
        group=Dict("name"=>g.name,"kind"=>String(g.kind),"pid"=>g.pid,"properties"=>element_properties(m,g))
        for (i,eid) in enumerate(g.eids)
            elements[string(eid)]=Dict("group"=>group,"points"=>[collect(p) for p in element_points(m,g,i)])
        end
    end
    if metadata===nothing
        metadata=Dict("eulerColumns"=>stringer_euler_payload(m;compact=false),
            "stringerBlades"=>stringer_blade_payload(m),"skinBucklingPanels"=>skin_buckling_payload(m),
            "componentBuckling"=>component_buckling_payload(m))
    end
    merge(Dict{String,Any}("elements"=>elements,"cases"=>case_records,
        "allowables"=>get(m.params,"materials.allowables",Any[]),
        "response_ids"=>get(request,"response_ids",String[]),
        "method"=>get(request,"method","maximum"),"percentile"=>get(request,"percentile",95),
        "assessmentPolicy"=>Dict("strengthSafetyFactor"=>m.params["assessment.strength_safety_factor"],
            "bucklingPolicyFactor"=>m.params["assessment.buckling_policy_factor"]),
        "eulerFixityCoefficient"=>get(m.params,"stringers.euler_fixity_coefficient",1.),
        "skinFixityCoefficient"=>get(m.params,"stringers.skin_fixity_coefficient",1.)),metadata)
end

function rf_assessment_catalog(m,request=Dict())
    cases=Dict(string(c.id)=>Dict("analysis"=>"SOL$(get(c.params,"output.solution","101"))","static"=>true,"matches"=>true,"elementResults"=>Dict(),"label"=>c.label)
        for c in load_case_specs(m.params) if string(get(c.params,"output.solution","101")) in ("101","106"))
    input=rf_native_input(m,cases;request)
    input["catalog_only"]=true
    assessment=rf_assessment_values(input;derivatives=false)
    responses=[merge(rf_public_response(r),Dict("id"=>r["response_id"],"label"=>get(r,"label",r["physical_criterion_id"]),
        "mode"=>r["failure_mode"],"status"=>"not_analyzed")) for r in assessment["responses"]]
    merge(rf_design_catalog(m),Dict("responses"=>responses,"signatures"=>rf_signatures(m,request)))
end

function rf_case_forward(source,spec,directory;native,solve,frozen_load=nothing,progress=_ -> nothing,cancelled=()->false)
    cancelled()&&throw(InterruptException())
    params=deepcopy(spec.params);params["loads.cases"]=Any[];params["loads.label"]=spec.label
    solution=string(get(params,"output.solution","101"))
    solution in ("101","106")||throw(ArgumentError("RF derivatives require physical SOL101/SOL106 equilibrium; case $(spec.id) requests SOL$solution"))
    candidate=sensitivity_model(source,params);loads=frozen_load===nothing ? aerodynamic_loads(candidate) : frozen_load
    mkpath(directory);path=joinpath(directory,"baseline.bdf")
    message="Solving LIMIT load case $(spec.id), $(spec.label), SOL$solution"
    progress(Dict("phase"=>"forward","event"=>"case_solve_started","case_id"=>spec.id,
        "case_label"=>spec.label,"detail"=>message,"log_message"=>message))
    open(path,"w") do io
        write_deck(IOContext(io,:full_precision=>true),candidate;frozen_load_cases=[(id=1,label=spec.label,params,loads)])
    end
    forward=solve(path)
    cancelled()&&throw(InterruptException())
    # Only fields required for RF assessment are exported. No VTK, HTML report,
    # eigenmodes, screenshots or unrelated output is requested.
    exportdir=joinpath(directory,"fields");mkpath(exportdir)
    Base.invokelatest(native.export_results,forward,"baseline.bdf",exportdir;export_json=true,
        export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
    result_path,data=find_results_json(exportdir);result_path===nothing&&error("RF baseline produced no physical recovered fields")
    selected=static_case_result(data,1,[1])
    proxy=JfemJob("rf_baseline",spec.label,path,directory,joinpath(directory,"solver.log"),"",
        candidate,nothing,String[],ReentrantLock(),time(),time(),:done,0,"")
    payload=jfem_case_results_payload(proxy,result_path,selected)
    get(payload,"available",false)===true||throw(ArgumentError("RF baseline result recovery is unavailable"))
    convergence=get(payload,"convergence",nothing)
    if solution=="106"
        convergence isa AbstractDict&&get(convergence,"converged",false)&&get(convergence,"full_load",false)&&!get(convergence,"partial",true)||
            throw(ArgumentError("SOL106 RF derivatives require an accepted converged full-load equilibrium"))
    end
    records=Dict{String,Any}("analysis"=>"SOL$solution","static"=>true,"matches"=>true,"status"=>"complete",
        "available"=>true,"elementResults"=>payload["element_results"],"label"=>spec.label)
    convergence===nothing||(records["convergence"]=convergence)
    message="Recovered displacements, element forces, stresses and strains for load case $(spec.id), $(spec.label)"
    progress(Dict("phase"=>"forward","event"=>"case_solve_completed","case_id"=>spec.id,
        "case_label"=>spec.label,"detail"=>message,"log_message"=>message))
    (;wing=candidate,forward,records,loads)
end

function rf_evaluate_design(m,request,directory;native,solve,progress=_ -> nothing,cancelled=()->false,
        frozen_loads=Dict{String,Any}(),frozen_bases=Dict(),derivatives=true)
    specs=[c for c in load_case_specs(m.params) if string(c.id) in string.(request["case_ids"])]
    records=Dict{String,Any}();contexts=Dict{String,Any}();factors=Dict{String,Any}();forwards=Dict{String,Any}()
    for spec in specs
        id=string(spec.id);case=rf_case_forward(m,spec,joinpath(directory,"case_$id");native,solve,
            frozen_load=get(frozen_loads,id,nothing),progress,cancelled)
        records[id]=case.records;frozen_loads[id]=case.loads;forwards[id]=case
        derivatives&&(contexts[id]=rf_derivative_context(native,case.forward,case.wing;factorizations=factors,progress,cancelled))
    end
    progress(Dict("phase"=>"rf_assessment","detail"=>"Evaluating physical strength and buckling criteria"))
    input=rf_native_input(m,records;request)
    assessment=rf_assessment_values(input;derivatives,frozen_bases,progress,cancelled)
    rows=assessment["responses"]
    selected=String.(get(request,"response_ids",String[]))
    if !isempty(selected)
        lookup=Dict(r["response_id"]=>r for r in rows)
        all(id->haskey(lookup,id),selected)||throw(ArgumentError("RF response membership changed; refresh the response catalog"))
        rows=[lookup[id] for id in selected]
    end
    isempty(rows)&&throw(ArgumentError("No physical RF responses match this request"))
    isempty(selected)||Set(selected)==Set(r["response_id"] for r in rows)||throw(ArgumentError("RF response membership changed; refresh the response catalog"))
    (;assessment,rows,contexts,input,frozen_loads,forwards,derivatives_ready=derivatives)
end

rf_capacity_callback(context,row,variable,directions)=rf_capacity_jvp(context.wing,row,variable;
    properties=context.properties_by_pid,directions)

"""Property minima are projections of physical responses, not duplicate
optimization constraints. References point to the canonical Jacobian rows."""
function rf_property_envelopes(rows)
    memberships=Dict{Int,Vector{Int}}()
    for (i,row) in enumerate(rows),pid in get(row,"membership_pids",Int[])
        push!(get!(memberships,Int(pid),Int[]),i)
    end
    summaries=Any[]
    for pid in sort!(collect(keys(memberships)))
        indices=unique(memberships[pid])
        available=[i for i in indices if get(rows[i],"status","unavailable")=="ok"&&get(rows[i],"utilization",nothing) isa Real]
        unavailable=setdiff(indices,available)
        isempty(available)&&begin
            push!(summaries,Dict("pid"=>pid,"status"=>"unassessed","raw_RF"=>nothing,"utilization"=>nothing,
                "response_ids"=>[rows[i]["response_id"] for i in indices]));continue
        end
        peak=maximum(rows[i]["utilization"] for i in available)
        ties=[i for i in available if abs(rows[i]["utilization"]-peak)<=1e-10max(abs(peak),1e-12)]
        governing=first(ties);row=rows[governing]
        push!(summaries,Dict("pid"=>pid,"status"=>isempty(unavailable) ? "complete" : "unassessed",
            "raw_RF"=>isempty(unavailable)&&peak>0 ? inv(peak) : nothing,
            "utilization"=>isempty(unavailable) ? peak : nothing,"no_demand"=>isempty(unavailable)&&iszero(peak),
            "critical_case"=>row["case_id"],"critical_mode"=>row["failure_mode"],
            "governing_response_id"=>row["response_id"],"response_row_index"=>governing,
            "gradient_status"=>isempty(unavailable) ? (length(ties)>1 ? "active_set_tie" : get(row,"derivative_status","unavailable")) : "unavailable",
            "competing_response_ids"=>[rows[i]["response_id"] for i in ties],
            "unavailable_response_ids"=>[rows[i]["response_id"] for i in unavailable],
            "response_ids"=>[rows[i]["response_id"] for i in indices]))
    end
    summaries
end

function rf_matrix_export(directory,J,responses,variables;quantity="utilization")
    sink=rf_matrix_sink(directory,responses,variables;quantity)
    try
        sink.push_block(1,length(responses),J);sink.finish()
    catch
        sink.finish(;complete=false);rethrow()
    end
end

function compute_rf_sensitivity(m,raw,directory;native,solve,progress=_ -> nothing,cancelled=()->false)
    source=m;m=rf_materialized_model(m)
    request=rf_request(m,raw);mkpath(directory);started=time()
    is_imported_model(m)&&throw(ArgumentError("Imported RF engineering criteria need physical membership metadata; imported models are not silently assessed"))
    physical=rf_selected_variables(m,request);design=rf_design_map(physical,get(request,"ties",Any[]))
    if request["operation"]=="optimize"
        result=compute_rf_optimization(m,request,directory,design;native,solve,progress,cancelled)
        result["source_study_signatures"]=rf_signatures(source,request)
        return result
    end
    evaluation=rf_evaluate_design(m,request,directory;native,solve,progress,cancelled,
        derivatives=request["operation"]!="assess")
    rows=evaluation.rows
    result=Dict{String,Any}("format"=>"jfem-rf-sensitivity-1","operation"=>request["operation"],
        "quantity"=>request["quantity"],"responses"=>[merge(rf_public_response(r),Dict("id"=>r["response_id"],
            "label"=>get(r,"label",r["physical_criterion_id"]),"mode"=>r["failure_mode"],"rf"=>r["raw_RF"])) for r in rows],
        "variables"=>design.variables,"signatures"=>rf_signatures(source,request),
        "analysis_signatures"=>rf_signatures(m,request),"request"=>request,
        "property_envelopes"=>rf_property_envelopes(rows),
        "metadata"=>Dict("load_basis"=>"LIMIT","derivative_method"=>"analytic_equilibrium",
            "fixed_force_estimate"=>false,"derivative_version"=>RF_DERIVATIVE_VERSION,
            "scope"=>"Selected physical criteria and load cases",
            "all_eligible_responses"=>isempty(request["response_ids"]),
            "gradient_class"=>"Classical derivative on smooth branches; selected Clarke subgradient at reported ties or eigenclusters"))
    measure=request["quantity"]=="rf" ? "reserve_factor" : "utilization"
    if request["operation"]=="jacobian"
        streaming=length(rows)*length(physical)>1_000_000
        sink=rf_matrix_sink(directory,rows,design.variables;quantity=request["quantity"],
            provenance=Dict("study_signatures"=>result["signatures"],"analysis_signatures"=>result["analysis_signatures"],
                "derivative_version"=>RF_DERIVATIVE_VERSION,"request"=>request))
        derivative=try
            if streaming
                emit=(start,stop,block)->sink.push_block(start,stop,rf_chain_jacobian(block,design.P))
                rf_response_jacobian(native,evaluation.contexts,rows,physical;
                    capacity_row_jvp=rf_capacity_callback,measure,block_size=request["block_size"],cancelled,progress,
                    retain_matrix=false,block_sink=emit)
            else
                answer=rf_response_jacobian(native,evaluation.contexts,rows,physical;
                    capacity_row_jvp=rf_capacity_callback,measure,block_size=request["block_size"],cancelled,progress)
                answer["jacobian"]=rf_chain_jacobian(answer["jacobian"],design.P)
                sink.push_block(1,length(rows),answer["jacobian"]);answer
            end
        catch
            sink.finish(;complete=false);rethrow()
        end
        result["matrix_file"]=sink.finish(;derivative_complete=derivative["complete"])
        result["jacobian"]=streaming ? nothing : derivative["jacobian"]
        result["matrix_preview"]=streaming ? sink.preview : nothing
        result["reasons"]=derivative["reasons"];result["complete"]=derivative["complete"]
        result["metadata"]["physical_property_mapping_class"]=get(derivative,"property_mapping_class",Dict())
        result["metadata"]["adjoint_rhs"]=derivative["adjoint_rhs"];result["metadata"]["factorizations"]=derivative["factorizations"]
    elseif request["operation"] in ("jvp","directional")
        direction=Float64.(get(request,"direction",ones(length(design.variables))))
        length(direction)==length(design.variables)||throw(ArgumentError("The RF design direction has the wrong length"))
        method=request["operation"]=="directional" ? rf_directional : rf_jvp
        product=method(native,evaluation.contexts,rows,physical,design.P*direction;
            capacity_row_jvp=rf_capacity_callback,cancelled)
        values=collect(product.values)
        request["quantity"]=="rf"&&(values=[r["utilization"] isa Real&&r["utilization"]>0 ? -v/r["utilization"]^2 : NaN for (r,v) in zip(rows,values)])
        result["values"]=values;result["reasons"]=product.reasons;result["complete"]=all(isfinite,values)
        if hasproperty(product,:derivative_class)
            result["derivative_class"]=product.derivative_class
            for (row,class) in zip(result["responses"],product.derivative_class);row["derivative_class"]=class;end
        end
        if request["quantity"]=="rf"
            for (i,value) in enumerate(values)
                isfinite(value)||(result["reasons"][string(i)]=get(result["reasons"],string(i),"No finite RF derivative at zero demand; select utilization"))
            end
        end
    elseif request["operation"]=="vjp"
        weights=Float64.(get(request,"weights",ones(length(rows))))
        length(weights)==length(rows)||throw(ArgumentError("RF response weights have the wrong length"))
        request["quantity"]=="rf"&&(weights=[iszero(w) ? 0. : r["utilization"] isa Real&&r["utilization"]>0 ? -w/r["utilization"]^2 : throw(ArgumentError("A nonzero-weight unloaded response has no finite RF gradient; choose utilization")) for (r,w) in zip(rows,weights)])
        product=rf_vjp(native,evaluation.contexts,rows,physical,weights;capacity_row_jvp=rf_capacity_callback,cancelled)
        result["values"]=transpose(design.P)*product.values;result["complete"]=true
        result["metadata"]["adjoint_rhs"]=product.adjoint_rhs
    else
        result["complete"]=all(r["status"]=="ok" for r in rows)
    end
    result["seconds"]=time()-started;result["status"]=result["complete"] ? "complete" : "partial"
    rf_json_safe(result)
end
