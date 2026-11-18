# RF specializations belong to the same shared image as the FE solver and all
# apps. This workload never launches a child process or reads a user Study.

"""Exercise real RF kernels, Jacobian/products and the production worker entry.

`model` is the small authored isotropic shell/PBARL wing from the ordinary
generated-sensitivity workload. Every deck, serialized request and result stays
under `output`, whose caller owns a temporary directory.
"""
function run_rf_precompile_workload(W, model, output, solve)
    repository=normpath(joinpath(@__DIR__,"..",".."))
    mkpath(output)
    parameters=deepcopy(model.params)
    parameters["output.solution"]="101"
    parameters["loads.cases"]=Any[]
    parameters["loads.structure_inertia"]=true
    parameters["loads.fuel_accel_z"]=-1.
    parameters["stringers.model"]="beam"
    candidate=W.sensitivity_model(model,parameters)
    W.all_checks_pass(candidate)||error("RF warm-up FEM checks failed")
    catalog=W.rf_design_catalog(candidate)
    selected=String[]
    for (part,field) in (("skin","thickness"),("stringer","web_thickness"))
        index=findfirst(row->startswith(row["id"],"properties.panels#")&&endswith(row["id"],"#$part#$field"),catalog["variables"])
        index===nothing&&error("RF warm-up lacks an independent $part $field")
        push!(selected,catalog["variables"][index]["id"])
    end
    upper=findfirst(row->occursin("#upper:",row["id"])&&endswith(row["id"],"#skin#thickness"),catalog["variables"])
    upper===nothing&&error("RF warm-up lacks an independent upper-skin thickness")
    push!(selected,catalog["variables"][upper]["id"])
    known=Set(row["id"] for row in catalog["variables"])
    for id in ("material.E",)
        id in known&&push!(selected,id)
    end
    request=W.rf_request(candidate,Dict("operation"=>"jacobian","quantity"=>"utilization",
        "variables"=>selected,"case_ids"=>[1]))
    follower_rejected=String[]
    for solution in ("101","106")
        follower_params=deepcopy(candidate.params)
        follower_params["output.solution"]=solution
        follower_params["nonlinear.method"]="legacy_geometric"
        follower_params["loads.follower_forces"]=true
        follower=W.sensitivity_model(candidate,follower_params)
        rejected=try
            W.rf_request(follower,Dict("operation"=>"jacobian","variables"=>selected[1:1],"case_ids"=>[1]))
            false
        catch failure
            failure isa ArgumentError&&occursin("follower",lowercase(sprint(showerror,failure)))
        end
        rejected||error("SOL$solution follower-force RF derivatives must be rejected before an FE solve")
        push!(follower_rejected,solution)
    end
    state=W.rf_evaluate_design(candidate,request,joinpath(output,"native_context");
        native=Main.OpenJFEM,solve)
    rows=state.rows
    all(row->row["status"]=="ok",rows)||error("RF warm-up has an unassessed physical criterion")
    chosen=Any[]
    for mode in unique(row["failure_mode"] for row in rows)
        eligible=filter(row->row["failure_mode"]==mode&&W.rf_derivative_row_status(row)!="unavailable"&&
            !get(row,"approximation",false),rows)
        isempty(eligible)&&continue
        positive=findfirst(row->get(row,"utilization",0.)>1e-12,eligible)
        push!(chosen,eligible[positive===nothing ? 1 : positive])
    end
    isempty(chosen)&&error("RF warm-up did not find any differentiable physical responses")
    ids=String[row["response_id"] for row in chosen]

    # Use the exact named production solve callback and JSON/serialization
    # request path. A different anonymous callback leaves a separate top-level
    # specialization to compile when the persistent worker is first used.
    worker=Base.invokelatest(getfield,W,:JFEMSensitivityWorker)
    runner=Base.invokelatest(getfield,worker,:run_sensitivity_worker)
    previous_blas=W.LinearAlgebra.BLAS.get_num_threads()
    results=Dict{String,Any}[]
    nonlinear_verified=false
    try
        for operation in ("jacobian","jvp","vjp","directional")
            directory=joinpath(output,"worker_"*operation);mkpath(directory)
            raw=Dict{String,Any}("rf_analysis"=>true,"operation"=>operation,"quantity"=>"utilization",
                "variables"=>selected,"response_ids"=>ids,"case_ids"=>[1],"block_size"=>8)
            operation in ("jvp","directional")&&(raw["direction"]=fill(.1,length(selected)))
            operation=="vjp"&&(raw["weights"]=fill(1/length(ids),length(ids)))
            W.Serialization.serialize(joinpath(directory,"model.jls"),candidate)
            W.sensitivity_json_write(joinpath(directory,"request.json"),raw)
            ok=Base.invokelatest(runner,directory,repository;
                runtime=Dict{String,Any}("precompile_workload"=>true,"child_process"=>false))
            ok||error("RF production-worker $operation warm-up failed: "*
                read(joinpath(directory,"error.json"),String))
            result=W.JSON.parsefile(joinpath(directory,"result.json"))
            get(result,"complete",false)||error("RF $operation warm-up returned partial derivative coverage")
            values=operation=="jacobian" ? reduce(vcat,result["jacobian"]) : result["values"]
            all(value->value isa Real&&isfinite(value),values)||error("RF $operation warm-up returned unavailable derivatives")
            get(result["metadata"],"fixed_force_estimate",true)===false||error("RF warm-up must use equilibrium derivatives")
            push!(results,Dict("operation"=>operation,"complete"=>true,"finite_derivatives"=>true,
                "responses"=>length(result["responses"]),"variables"=>length(result["variables"]),
                "production_worker_entry"=>true))
        end

        # Also compile the bounded sizing service and independent final-check
        # path. A single strength constraint is sufficient for this tiny image
        # workload; this is not an engineering sizing/optimality benchmark.
        material=findfirst(row->row["failure_mode"]=="von_mises"&&get(row,"utilization",0.)>0,chosen)
        material===nothing&&error("RF sizing warm-up needs a finite material-strength response")
        directory=joinpath(output,"worker_optimize");mkpath(directory)
        raw=Dict{String,Any}("rf_analysis"=>true,"operation"=>"optimize","quantity"=>"utilization",
            "variables"=>selected[1:1],"response_ids"=>[chosen[material]["response_id"]],"case_ids"=>[1],
            "options"=>Dict("max_iterations"=>1,"inner_iterations"=>1,"move_limit"=>.1))
        W.Serialization.serialize(joinpath(directory,"model.jls"),candidate)
        W.sensitivity_json_write(joinpath(directory,"request.json"),raw)
        Base.invokelatest(runner,directory,repository;
            runtime=Dict{String,Any}("precompile_workload"=>true,"child_process"=>false))||
            error("RF sizing warm-up failed: "*read(joinpath(directory,"error.json"),String))
        optimized=W.JSON.parsefile(joinpath(directory,"result.json"))
        get(optimized["final_verification"],"complete",false)||error("RF sizing warm-up lacks independent final verification")
        push!(results,Dict("operation"=>"optimize","complete"=>true,
            "finite_derivatives"=>true,"production_worker_entry"=>true,
            "independent_final_verification"=>true,"optimality_benchmark"=>false))

        # The accepted SOL106 residual context has different dispatch from
        # scalar nonlinear sensitivity and from a SOL101 RF baseline. Exercise
        # that exact production branch, without substituting a linear solve.
        nonlinear_params=deepcopy(candidate.params)
        nonlinear_params["output.solution"]="106"
        nonlinear_params["nonlinear.method"]="legacy_geometric"
        nonlinear_params["nonlinear.load_steps"]=2
        nonlinear_params["loads.load_factor"]=.05
        nonlinear=W.sensitivity_model(candidate,nonlinear_params)
        upper_variable=catalog["variables"][upper]
        upper_strength=findfirst(row->row["failure_mode"]=="von_mises"&&
            !isempty(intersect(get(row,"membership_pids",Int[]),upper_variable["pids"])),rows)
        upper_strength===nothing&&error("SOL106 RF warm-up needs an upper-skin strength response")
        directory=joinpath(output,"worker_sol106");mkpath(directory)
        raw=Dict{String,Any}("rf_analysis"=>true,"operation"=>"jacobian","quantity"=>"utilization",
            "variables"=>[upper_variable["id"]],"response_ids"=>[rows[upper_strength]["response_id"]],"case_ids"=>[1])
        W.Serialization.serialize(joinpath(directory,"model.jls"),nonlinear)
        W.sensitivity_json_write(joinpath(directory,"request.json"),raw)
        Base.invokelatest(runner,directory,repository;
            runtime=Dict{String,Any}("precompile_workload"=>true,"child_process"=>false))||
            error("SOL106 RF warm-up failed: "*read(joinpath(directory,"error.json"),String))
        nonlinear_result=W.JSON.parsefile(joinpath(directory,"result.json"))
        get(nonlinear_result,"complete",false)||error("SOL106 RF warm-up returned partial derivative coverage")
        all(value->value isa Real&&isfinite(value),reduce(vcat,nonlinear_result["jacobian"]))||
            error("SOL106 RF warm-up returned unavailable derivatives")
        all(row->string(row["solution"])=="106"&&get(row,"nonlinear_demand_estimate",false),
            nonlinear_result["responses"])||error("RF warm-up did not retain its accepted SOL106 demand context")
        exported=W.JSON.parsefile(joinpath(directory,"case_1","fields","baseline.NONLINEAR.JSON"))
        get(exported,"analysis_type","")=="SOL106_NONLINEAR_STATIC"||error("SOL106 RF warm-up exported a different analysis")
        diagnostics=only(exported["subcases"])["nonlinear_diagnostics"]
        get(diagnostics,"nonlinear_method","")=="legacy_geometric"&&
            get(diagnostics,"converged",false)&&get(diagnostics,"exported_state_accepted",false)&&
            get(diagnostics,"termination_reason","")=="full_load_converged"&&
            isapprox(get(diagnostics,"final_load_scale",0.),1.;atol=1e-12)||
            error("SOL106 RF warm-up did not reach an accepted full-load nonlinear equilibrium")
        nonlinear_verified=true
    finally
        # The shared image must not retain a temporary request directory or a
        # cancelled/finished run as the next user's production worker state.
        Base.invokelatest() do
            worker.DIRECTORY[]="";worker.REPOSITORY[]="";worker.WORKER_STARTED[]=0.
            worker.LAST_PROGRESS[]=Dict{String,Any}();empty!(worker.WORKER_TIMINGS)
            empty!(worker.WORKER_LOG_EVENTS);worker.WORKER_LOG_SEQUENCE[]=0
            worker.WORKER_STAGE[]="bootstrap";worker.NATIVE_MODULE[]=nothing
        end
        W.LinearAlgebra.BLAS.set_num_threads(previous_blas)
    end

    # Exercise the actual browser JSON contract and native postprocessing route,
    # reusing solved fields. This step performs no extra FE solve.
    input=W.JSON.parse(W.JSON.json(W.rf_json_safe(state.input)))
    inputfile=joinpath(output,"input.toml");write(inputfile,W.params_to_toml(candidate.params))
    app=W.AppState(joinpath(repository,"APPS","JFEM-Boxer"),inputfile;
        deck_store_dir=joinpath(output,"decks"))
    app.model=candidate
    response=W.handle_rf_assessment(app,W.HTTP.Request("POST","/api/rf_assessment",
        ["Content-Type"=>"application/json"],W.JSON.json(Dict("input"=>input,
            "request_id"=>"shared-image-rf-warmup"))))
    response.status==200||error("Native RF report warm-up returned HTTP $(response.status): "*String(response.body))
    report=W.JSON.parse(String(response.body))
    get(report,"ok",false)||error("Native RF report warm-up did not succeed")
    Dict{String,Any}("kind"=>"rf","status"=>"complete","finite_derivatives"=>true,
        "variables"=>length(selected),"variable_ids"=>selected,"responses"=>length(ids),"operations"=>results,
        "failure_modes"=>sort!(unique(String[row["failure_mode"] for row in chosen])),
        "native_report_json"=>true,"production_worker_entry"=>true,"child_processes"=>0,
        "sol106_consistent_residual"=>nonlinear_verified,"sol106_method"=>"legacy_geometric",
        "follower_derivatives_rejected_before_solve"=>follower_rejected,
        "temporary_outputs"=>true,"has_shells"=>any(group->group.kind in (:quad,:tria),candidate.groups),
        "has_bars"=>any(group->group.kind===:bar,candidate.groups),"structural_inertia"=>true)
end
