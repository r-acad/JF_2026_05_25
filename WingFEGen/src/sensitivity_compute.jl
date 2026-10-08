sensitivity_canonical(v::AbstractDict)=[(String(k),sensitivity_canonical(v[k])) for k in sort!(collect(keys(v));by=string)]
sensitivity_canonical(v::AbstractVector)=sensitivity_canonical.(v)
sensitivity_canonical(v)=v
function sensitivity_definition(params;version=2,omit_empty_panels=true)
    sensitivity_canonical(Dict(k=>v for (k,v) in params if !startswith(k,"sensitivity.")&&
        (version==1||!startswith(k,"view."))&&
        !(version==2&&omit_empty_panels&&k=="properties.panels"&&v isa AbstractVector&&isempty(v))))
end
function sensitivity_model_signature(m;version=2,legacy_empty_panels=false)
    data=(params=sensitivity_definition(m.params;version,omit_empty_panels=!legacy_empty_panels),
        nodes=m.node_ids,xyz=m.xyz,groups=[(g.pid,g.eids,g.conn) for g in m.groups])
    bytes2hex(SHA.sha256(JSON.json(data)))
end

sensitivity_context_get(context,key,default=nothing)=context isa AbstractDict ? get(context,key,default) : hasproperty(context,Symbol(key)) ? getproperty(context,Symbol(key)) : default

# Display rounding only: decks, operator samples and derivatives retain Float64
# precision. Avoid exposing binary tails such as 0.0022110000000000003.
sensitivity_progress_number(value::Real)=abs(value)>=100 ? @sprintf("%.2f",value) : @sprintf("%.8g",value)

"""Discrete adjoint sensitivities of the complete assembled wing equations.

Only the baseline calls `solve`. Property samples reassemble native operators
at fixed baseline state/adjoint vectors. Central (or bounded one-sided)
differences differentiate those operators, not the solved response. Explicit
callbacks are provided for isolated orchestration tests; there is no implicit
fallback to full-response finite differences.
"""
function compute_sensitivity(m,raw,dir;native=nothing,solve,progress=(data)->nothing,
                             cancelled=()->false,context_builder=nothing,sample_evaluator=nothing)
    native===nothing&&(context_builder===nothing||sample_evaluator===nothing)&&
        throw(ArgumentError("Discrete adjoint sensitivity requires the native assembled-operator backend"))
    request=sensitivity_request(m,raw);catalog=sensitivity_catalog(m)
    lookup=Dict(d["id"]=>d for d in catalog["variables"])
    variables=[lookup[id] for id in request["variables"]]
    spec=only(filter(s->s.id==request["case_id"],load_case_specs(m.params)))
    params=deepcopy(spec.params);params["loads.cases"]=Any[];params["loads.label"]=spec.label
    objective=request["objective"];kind=objective["type"]
    eigen=kind in ("frequency_eigenvalue","buckling_factor")
    sol=kind=="frequency_eigenvalue" ? "103" : kind=="buckling_factor" ? "105" : "101"
    sol=="105"&&get(params,"loads.follower_forces",false)&&throw(ArgumentError("SOL105 sensitivity requires a fixed-direction preload; disable follower forces in the selected case"))
    params["output.solution"]=sol;params["output.n_modes"]=min(24,max(Int(get(objective,"mode",1))+4,6))
    baseline=sensitivity_model(m,params);aero=aerodynamic_loads(baseline);mkpath(dir)
    stencils=[sensitivity_stencil(baseline,d,request["relative_step"]) for d in variables]
    sample_limits=[request["check_step"] ? (s.direction==0 ? 4 : 3) : 2 for s in stencils]
    # A one-sided checked stencil shares its h sample between h and h/2.
    # Count actual operator calls, not nominal perturbation points or solves.
    completed=Ref(0);operator_completed=Ref(0);total=2+sum(sample_limits)
    counts=Dict{String,Any}("forward_solves"=>0,"adjoint_solves"=>0,"eigen_solves"=>0,
        "perturbed_forward_solves"=>0,"operator_evaluations"=>0)
    property_progress=Dict{String,Any}("index"=>0,"total"=>length(variables),"sample"=>0,"samples"=>0)
    timings=Dict{String,Float64}("baseline_deck"=>0.,"baseline_solve"=>0.,"baseline_export"=>0.,
        "adjoint_setup_and_solve"=>0.,"property_decks"=>0.,"property_operators"=>0.)
    started=time()
    function report(detail,phase)
        cancelled()&&error("Sensitivity study cancelled")
        progress(Dict("completed"=>completed[],"total"=>total,"detail"=>detail,"phase"=>phase,
            "unit"=>"stages and operator samples (not solves)","solver_counts"=>copy(counts),
            "operator_samples_completed"=>operator_completed[],"operator_samples_planned"=>sum(sample_limits),
            "property_progress"=>copy(property_progress),"timings_seconds"=>merge(copy(timings),Dict("total"=>time()-started))))
    end
    function deck(p,tag)
        cm=sensitivity_model(m,p);path=joinpath(dir,tag*".bdf")
        open(path,"w") do io
            write_deck(IOContext(io,:full_precision=>true),cm;frozen_load_cases=[(id=1,label=spec.label,params=p,loads=aero)])
        end
        return cm,path
    end
    report("Preparing the single baseline deck (SOL$sol); first compilation may take several minutes","baseline_deck")
    baseline_started=time();stage_started=time();_,path=deck(params,"baseline")
    timings["baseline_deck"]=time()-stage_started
    report("Solving baseline analysis 1/1 (SOL$sol); no property solves will follow","forward")
    stage_started=time();forward=solve(path);timings["baseline_solve"]=time()-stage_started
    baseline_seconds=time()-baseline_started
    counts["forward_solves"]=1;counts["eigen_solves"]=eigen ? 1 : 0
    completed[]+=1
    report("Exporting the solved baseline for ordinary Results; no additional analysis","baseline_export")
    stage_started=time()
    baseline_analysis=sensitivity_export_baseline(native,forward,m,baseline,dir,spec,sol;seconds=baseline_seconds)
    timings["baseline_export"]=time()-stage_started
    base=sensitivity_response(forward,baseline,objective)
    report(kind=="frequency_eigenvalue" ? "Baseline eigenproblem solved; preparing the self-adjoint contraction (no second solve)" : "Baseline solved; preparing and solving shared adjoint equation 1/1","adjoint")
    builder=context_builder===nothing ? (eigen ? sensitivity_eigen_context : sensitivity_static_context) : context_builder
    evaluator=sample_evaluator===nothing ? (eigen ? sensitivity_eigen_sample : sensitivity_static_sample) : sample_evaluator
    stage_started=time()
    context=if context_builder===nothing&&eigen
        Base.invokelatest(builder,native,forward,baseline,objective;
            progress=step->report(get(step,"detail","Preparing eigenvalue adjoint"),"adjoint"),cancelled)
    else
        Base.invokelatest(builder,native,forward,baseline,objective)
    end
    timings["adjoint_setup_and_solve"]=time()-stage_started
    completed[]+=1
    baseline_sample=sensitivity_context_get(context,"baseline_sample")
    baseline_sample isa Real&&isfinite(baseline_sample)||error("Adjoint context did not provide a finite baseline Lagrangian")
    merge!(counts,sensitivity_context_get(context,"solver_counts",Dict()))
    counts["forward_solves"]=1;counts["perturbed_forward_solves"]=0
    diagnostics=sensitivity_context_get(context,"diagnostics",Dict())
    rows=Any[]
    result=Dict{String,Any}("method"=>kind=="frequency_eigenvalue" ? "eigenvalue_adjoint" : "discrete_adjoint",
        "derivative_assembly"=>"semi_analytic_operator_differences","case_id"=>spec.id,"case_label"=>spec.label,
        "solution"=>sol,"objective"=>objective,"request"=>request,"baseline_model_signature"=>sensitivity_model_signature(m),
        "baseline_model_signature_version"=>2,
        "baseline_topology_signature"=>sensitivity_topology_signature(m),"scope"=>sensitivity_scope(m,variables),
        "load_application_version"=>APPLIED_LOAD_VERSION,"result_format_version"=>2,
        "compatibility"=>Dict("model_match"=>true,"topology_match"=>true,"load_application_match"=>true,
            "is_current"=>true,"map_allowed"=>true,"reasons"=>String[],"checked_against"=>"analysis baseline",
            "current_load_application_version"=>APPLIED_LOAD_VERSION),
        "baseline"=>Dict("value"=>base.value,"unit"=>base.unit,"mode"=>base.mode),"baseline_analysis"=>baseline_analysis,"rows"=>rows,
        "solver_counts"=>counts,"timings_seconds"=>timings,"timing_scope"=>"Compute stage only; worker startup is reported separately",
        "operator_samples_planned"=>sum(sample_limits),
        "diagnostics"=>diagnostics,"warnings"=>sensitivity_context_get(context,"warnings",String[]),
        "notes"=>["One baseline analysis. Shared transpose adjoint for static responses and buckling preload; modal eigenvectors supply the self-adjoint eigenvalue contraction. No perturbed forward solves.",
            "Semi-analytic discrete adjoint: native operators and fixed-state response recovery are differenced in each property. Stiffness, mass, structural inertia loads and section offsets retain their native assembly paths.",
            "The smaller operator step is reported when checking is enabled. A large step difference calls for a smaller step or review of an active material/property branch. This is not an independent full-response finite-difference validation.",
            "Normalized derivative = property / baseline response times derivative; undefined at zero baseline. E is measured in GPa. The property-effect map repeats a property's shared scalar response effect on its governed elements; it is not an element-local sensitivity field."])
    sensitivity_json_write(joinpath(dir,"baseline_response.json"),result["baseline"])
    for (index,d) in enumerate(variables)
        stencil=stencils[index];x=d["value"];h=stencil.h
        warning=stencil.warning;samples=Any[];values=Dict{Float64,Float64}(0.0=>Float64(baseline_sample))
        function at(delta)
            haskey(values,delta)&&return values[delta]
            merge!(property_progress,Dict("index"=>index,"sample"=>length(samples)+1,"samples"=>sample_limits[index],
                "id"=>d["id"],"label"=>d["label"],"value"=>x+delta,"value_text"=>sensitivity_progress_number(x+delta),"unit"=>d["unit"]))
            ready=kind=="frequency_eigenvalue" ? "Baseline eigenproblem solved; contraction ready." : "Baseline solved; adjoint solved."
            report("$ready Property $index/$(length(variables)), operator sample $(length(samples)+1)/$(sample_limits[index]): $(d["label"]) = $(sensitivity_progress_number(x+delta)) $(d["unit"]) (assembly only; no additional solve)","operators")
            stage_started=time()
            p=sensitivity_set!(deepcopy(params),d,x+delta);validate_params(p)
            cm,path=deck(p,"variable_$(index)_operator_$(length(samples)+1)")
            deck_seconds=time()-stage_started;timings["property_decks"]+=deck_seconds
            stage_started=time()
            sample=Base.invokelatest(evaluator,native,context,path,cm)
            operator_seconds=time()-stage_started;timings["property_operators"]+=operator_seconds
            for (key,seconds) in sensitivity_context_get(sample,"timings_seconds",Dict())
                timing_key="operator_"*String(key)
                timings[timing_key]=get(timings,timing_key,0.)+Float64(seconds)
            end
            value=sensitivity_context_get(sample,"value")
            value isa Real&&isfinite(value)||error("Adjoint operator contraction is nonfinite")
            sensitivity_context_get(sample,"forward_solves",0)==0||error("A property operator evaluation attempted an unexpected forward solve")
            completed[]+=1;operator_completed[]+=1
            sample_counts=sensitivity_context_get(sample,"solver_counts",Dict("operator_evaluations"=>sensitivity_context_get(sample,"operator_evaluations",1)))
            for (key,increment) in sample_counts
                key in ("forward_solves","perturbed_forward_solves","adjoint_solves","eigen_solves")&&increment!=0&&error("A property sample attempted an unexpected solution ($key)")
                counts[key]=get(counts,key,0)+increment
            end
            entry=Dict("variable_value"=>x+delta,"delta"=>delta,"lagrangian"=>value,"forward_solves"=>0,
                "deck_seconds"=>deck_seconds,"operator_seconds"=>operator_seconds)
            push!(samples,entry);values[delta]=Float64(value)
            sensitivity_json_write(replace(path,".bdf"=>"_operators.json"),sample)
            return Float64(value)
        end
        try
            derivative(step)=stencil.direction==0 ? (at(step)-at(-step))/(2step) :
                stencil.direction*(-3Float64(baseline_sample)+4at(stencil.direction*step)-at(stencil.direction*2step))/(2step)
            coarse=derivative(h);fine=request["check_step"] ? derivative(h/2) : coarse
            estimate=request["check_step"] ? abs(fine-coarse)/max(abs(fine),abs(coarse),abs(base.value)/max(abs(x),h)*1e-10,eps()) : nothing
            estimate!==nothing&&estimate>.05&&(warning*=isempty(warning) ? "Operator step check differs by more than 5%; reduce the step or inspect the response branch" : "; operator step check differs by more than 5%")
            push!(rows,Dict("id"=>d["id"],"label"=>d["label"],"field_key"=>d["field_key"],"field_label"=>d["field_label"],"value"=>x,"unit"=>d["unit"],"pids"=>d["pids"],
                "derivative"=>fine,"derivative_unit"=>base.unit*" / "*d["unit"],"normalized_derivative"=>!iszero(base.value) ? x/base.value*fine : nothing,
                "step"=>h,"step_error"=>estimate,"status"=>isempty(warning) ? "ok" : "warning","warning"=>warning,"samples"=>samples))
        catch error
            cancelled()&&rethrow()
            push!(rows,Dict("id"=>d["id"],"label"=>d["label"],"field_key"=>d["field_key"],"field_label"=>d["field_label"],"value"=>x,"unit"=>d["unit"],"pids"=>d["pids"],
                "derivative"=>nothing,"normalized_derivative"=>nothing,"step_error"=>nothing,"status"=>"failed","warning"=>sprint(showerror,error),"samples"=>samples))
        end
        for key in ("panel_key","field_key","field_label","inherited","layout_token")
            haskey(d,key)&&(last(rows)[key]=d[key])
        end
        sensitivity_json_write(joinpath(dir,"partial_result.json"),result)
    end
    result["status"]=all(r->r["status"]!="failed",rows) ? "complete" : "partial"
    timings["total"]=time()-started;result["operator_samples_completed"]=operator_completed[]
    total=completed[];report("Adjoint study $(result["status"]): $(counts["forward_solves"]) baseline analysis, $(counts["adjoint_solves"]) shared adjoint solves, $(operator_completed[]) property operator samples; zero perturbed forward solves","complete")
    return result
end

function sensitivity_stencil(m,d,step)
    x=d["value"];h=max(abs(x),d["unit"]=="1" ? .1 : 1e-8)*step
    valid(delta)=try
        validate_params(sensitivity_set!(deepcopy(m.params),d,x+delta));true
    catch;false;end
    if valid(h)&&valid(-h);return (h=h,direction=0,warning="")
    elseif valid(h)&&valid(2h);return (h=h,direction=1,warning="Forward one-sided differences: negative perturbation violates a property bound")
    elseif valid(-h)&&valid(-2h);return (h=h,direction=-1,warning="Backward one-sided differences: positive perturbation violates a property bound")
    end
    throw(ArgumentError("$(d["label"]): the requested step violates property dimensions/material bounds; reduce the relative step"))
end

function sensitivity_mode_snapshot(result,m)
    values=Float64.(result["eigenvalues"]);shapes=result["_raw_mode_shapes"];mapping=result["id_map"]
    rows=Int[]
    # Translation-only MAC avoids mixing metres and radians and excludes
    # dependent RBE3 nodes. Reindex by immutable GRID ID, never solver order.
    for gid in m.node_ids[1:m.n_struct]
        i=get(mapping,gid,0);i>0||error("Eigenvector is missing structural GRID $gid")
        append!(rows,6(i-1).+(1:3))
    end
    vectors=Matrix{Float64}(shapes[rows,:])
    size(vectors,2)==length(values)||error("Eigenvalue/vector coverage mismatch")
    all(isfinite,values)&&all(isfinite,vectors)||error("Eigenpairs contain nonfinite data")
    return (values=values,vectors=vectors)
end

function sensitivity_match_mode(snapshot,index,reference=nothing)
    n=length(snapshot.values);n>0||error("No eigenmodes were found inside the requested extraction bounds")
    if reference===nothing
        index<=n||error("Only $n modes were returned; requested mode $index is unavailable")
        chosen=index;mac=1.
    else
        scale=maximum(abs,reference);scale>0||error("Selected mode has no usable structural translations")
        v=reference./scale;nv=sum(abs2,v)
        scores=[begin
            w=snapshot.vectors[:,j];s=maximum(abs,w)
            s>0 ? sum(v.*(w./s))^2/(nv*sum(abs2,w./s)) : 0.
        end for j in 1:n]
        order=sortperm(scores;rev=true);chosen=first(order);mac=scores[chosen]
        mac>=.8||error("Mode tracking lost the baseline branch (best translation MAC=$mac); reduce the step or extract more modes")
        # Buckling vectors are orthogonal in an energy metric, not necessarily
        # in this translation-only Euclidean metric. Distinct nearby bending
        # shapes can therefore both have high MAC. Require the winning shape
        # mismatch to be decisively smaller, instead of a fixed MAC margin.
        if n>1
            first_error=max(0.,1-mac);second_error=max(0.,1-scores[order[2]])
            second_error>1e-8&&first_error<.25second_error||error("Mode tracking is ambiguous between two branches; individual-mode derivatives are not reported")
        end
    end
    value=snapshot.values[chosen]
    value>0||error("The requested eigenvalue is not positive")
    gap=minimum((abs(value-v)/max(abs(value),abs(v),eps()) for (j,v) in enumerate(snapshot.values) if j!=chosen);init=Inf)
    gap>1e-4||error("The selected eigenvalue is repeated or nearly repeated; a unique scalar mode derivative is undefined")
    return (value=value,vector=snapshot.vectors[:,chosen],mode=chosen,mac=mac,gap=gap)
end

function sensitivity_response(result,m,objective;reference=nothing)
    kind=objective["type"]
    if kind in ("frequency_eigenvalue","buckling_factor")
        matched=sensitivity_match_mode(sensitivity_mode_snapshot(result,m),objective["mode"],reference)
        return merge(matched,(unit=kind=="frequency_eigenvalue" ? "rad²/s²" : "1",))
    end
    sub=only(result["subcases"])
    diagnostics=get(sub,"solver_diagnostics",Dict())
    residual=get(get(diagnostics,"linear_solver",Dict()),"relative_residual",0.)
    residual isa Real&&isfinite(residual)&&residual<1e-6||error("The forward solution residual is too large for a reliable sensitivity")
    if kind=="displacement"
        row=only(filter(r->r["grid_id"]==objective["node_id"],sub["displacements"]))
        key=objective["component"]
        value=key=="magnitude" ? sqrt(sum(abs2(row[k]) for k in ("t1","t2","t3"))) : row[Dict("x"=>"t1","y"=>"t2","z"=>"t3")[key]]
        unit="m"
    else
        eid=objective["element_id"];stress=sub["stresses"]
        rows=kind=="bar_stress" ? get(stress,"cbar",Any[]) : vcat(get(stress,"quad4",Any[]),get(stress,"tria3",Any[]))
        row=only(filter(r->r["eid"]==eid,rows))
        if kind=="shell_stress"
            data=Dict{String,Any}(k=>deepcopy(v) for (k,v) in row if k!="eid")
            complete_shell_principals!(data)
            group=only(filter(g->eid in g.eids,m.groups));element=findfirst(==(eid),group.eids)
            c,s=shell_result_rotation(m,group,element;path=stringer_path(m.grid.wing,m.params))
            rotate_shell_results!(data,"stress",c,s)
            value=data[objective["surface"]][objective["component"]]
        elseif objective["component"]=="axial"
            value=row["axial"]
        else
            group=only(filter(g->eid in g.eids,m.groups));section=section_definition(m.params,group.pid)
            force=only(filter(r->r["eid"]==eid,sub["forces"]["cbar"]))
            samples=[row["axial"]-force["moment_$(ending)1"]*point[1]/section["I1_m4"]-
                force["moment_$(ending)2"]*point[2]/section["I2_m4"] for ending in ("a","b") for point in section["polygon_yz_m"]]
            value=objective["component"]=="max" ? maximum(samples) : minimum(samples)
        end
        unit="Pa"
    end
    value isa Real&&isfinite(value)||error("The selected objective is missing or nonfinite")
    return (value=Float64(value),unit=unit,vector=nothing,mode=nothing,mac=nothing,gap=nothing)
end

"""Independent full-response finite differences, retained for validation only.

The GUI and worker use compute_sensitivity (discrete adjoint), never this route.

`solve` receives a retained BDF path and returns native solve_model results.
This injection keeps the generator independent of the public solver module.
"""
function compute_sensitivity_fd_validation(m,raw,dir;solve,progress=(data)->nothing,cancelled=()->false)
    request=sensitivity_request(m,raw);catalog=sensitivity_catalog(m)
    lookup=Dict(d["id"]=>d for d in catalog["variables"])
    variables=[lookup[id] for id in request["variables"]]
    spec=only(filter(s->s.id==request["case_id"],load_case_specs(m.params)))
    params=deepcopy(spec.params);params["loads.cases"]=Any[];params["loads.label"]=spec.label
    objective=request["objective"];kind=objective["type"]
    sol=kind=="frequency_eigenvalue" ? "103" : kind=="buckling_factor" ? "105" : "101"
    sol=="105"&&get(params,"loads.follower_forces",false)&&throw(ArgumentError("SOL105 sensitivity requires a fixed-direction preload; disable follower forces in the selected case"))
    params["output.solution"]=sol;params["output.n_modes"]=min(24,max(Int(get(objective,"mode",1))+4,6))
    baseline=sensitivity_model(m,params);aero=aerodynamic_loads(baseline)
    completed=Ref(0);total=1+length(variables)*(request["check_step"] ? 4 : 2)
    function run(p,tag;reference=nothing)
        cancelled()&&error("Sensitivity study cancelled")
        progress(Dict("completed"=>completed[],"total"=>total,"detail"=>"Solving $tag (SOL$sol)"))
        cm=sensitivity_model(m,p);path=joinpath(dir,tag*".bdf")
        frozen=[(id=1,label=spec.label,params=p,loads=aero)]
        open(path,"w") do io
            write_deck(IOContext(io,:full_precision=>true),cm;frozen_load_cases=frozen)
        end
        answer=sensitivity_response(solve(path),cm,objective;reference)
        completed[]+=1
        sensitivity_json_write(joinpath(dir,tag*"_response.json"),Dict("value"=>answer.value,"unit"=>answer.unit,"mode"=>answer.mode,"mac"=>answer.mac,"relative_gap"=>isfinite(something(answer.gap,Inf)) ? answer.gap : nothing))
        return answer
    end
    base=run(params,"baseline");rows=Any[]
    result=Dict{String,Any}("method"=>"central_finite_difference","case_id"=>spec.id,"case_label"=>spec.label,
        "solution"=>sol,"objective"=>objective,"request"=>request,"baseline_model_signature"=>sensitivity_model_signature(m),
        "baseline"=>Dict("value"=>base.value,"unit"=>base.unit,"mode"=>base.mode),"rows"=>rows,
        "notes"=>["End-to-end JFEM forward solves on fixed nodes, connectivity and property IDs. Property-dependent section offsets, structural body loads and mass are updated.",
            "Signed derivative d(response)/d(variable). E variables are measured in GPa. Normalized derivative = variable / baseline response × derivative; absent for zero baseline response.",
            "The smaller-step derivative is reported when step checking is enabled. Step error compares h and h/2 derivatives; large differences indicate nonlinear response, card precision or inadequate step choice.",
            "Eigenvalue branches use translation MAC on structural nodes. Repeated or ambiguously tracked modes are rejected. Stress objectives use the displayed element axes and one fixed element/component/fiber; PCOMP z1/z2 are outer ply midpoint values. Beam max/min uses both ends and actual section polygon vertices. Magnitudes and extrema can be nonsmooth at zero or branch changes. No contour field is generated."])
    for (index,d) in enumerate(variables)
        stencil=sensitivity_stencil(baseline,d,request["relative_step"]);x=d["value"];h=stencil.h
        warning=stencil.warning;samples=Any[];values=Dict{Float64,Float64}(0.0=>base.value)
        function at(delta)
            haskey(values,delta)&&return values[delta]
            p=sensitivity_set!(deepcopy(params),d,x+delta);validate_params(p)
            answer=run(p,"variable_$(index)_sample_$(length(samples)+1)";reference=base.vector)
            push!(samples,Dict("variable_value"=>x+delta,"delta"=>delta,"response"=>answer.value,"mode"=>answer.mode,"mac"=>answer.mac))
            values[delta]=answer.value
        end
        try
            derivative(step)=stencil.direction==0 ? (at(step)-at(-step))/(2step) :
                stencil.direction*(-3base.value+4at(stencil.direction*step)-at(stencil.direction*2step))/(2step)
            coarse=derivative(h);fine=request["check_step"] ? derivative(h/2) : coarse
            error_estimate=request["check_step"] ? abs(fine-coarse)/max(abs(fine),abs(coarse),abs(base.value)/max(abs(x),h)*1e-10,eps()) : nothing
            error_estimate!==nothing&&error_estimate>.05&&(warning*=isempty(warning) ? "Step check differs by more than 5%; adjust the step before using this derivative" : "; step check differs by more than 5%")
            push!(rows,Dict("id"=>d["id"],"label"=>d["label"],"value"=>x,"unit"=>d["unit"],"pids"=>d["pids"],
                "derivative"=>fine,"derivative_unit"=>base.unit*" / "*d["unit"],"normalized_derivative"=>!iszero(base.value) ? x/base.value*fine : nothing,
                "step"=>h,"step_error"=>error_estimate,"status"=>isempty(warning) ? "ok" : "warning","warning"=>warning,"samples"=>samples))
        catch error
            cancelled()&&rethrow()
            push!(rows,Dict("id"=>d["id"],"label"=>d["label"],"value"=>x,"unit"=>d["unit"],"pids"=>d["pids"],
                "derivative"=>nothing,"normalized_derivative"=>nothing,"step_error"=>nothing,"status"=>"failed","warning"=>sprint(showerror,error),"samples"=>samples))
        end
        sensitivity_json_write(joinpath(dir,"partial_result.json"),result)
    end
    result["status"]=all(r->r["status"]!="failed",rows) ? "complete" : "partial"
    progress(Dict("completed"=>completed[],"total"=>completed[],"detail"=>"Sensitivity study "*result["status"]))
    return result
end
