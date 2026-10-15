const IMPORTED_LOAD_VERSION="native_import_v1"

"""Validate saved native geometry without a second, generated-deck parser.

The source signature includes all uploaded files. The recorded topology uses
the native parser's BASIC-coordinate GRID positions and original element IDs.
The baseline deck must also match its atomic export manifest.
"""
function imported_saved_topology_matches(directory,m,record)
    m!==nothing&&is_imported_model(m)||return false
    sensitivity_result_matches_model(record,m)||return false
    get(record,"baseline_topology_signature",nothing)==sensitivity_topology_signature(m)||return false
    metadata=sensitivity_baseline_metadata(directory)
    sensitivity_result_matches_model(metadata,m)||return false
    get(metadata,"baseline_topology_signature",nothing)==sensitivity_topology_signature(m)||return false
    expected=get(get(metadata,"sha256",Dict()),"baseline.bdf",nothing)
    expected isa AbstractString||return false
    path=sensitivity_saved_file(directory,"baseline.bdf",SENSITIVITY_BASELINE_LIMIT)
    bytes2hex(SHA.sha256(read(path)))==expected
end

function imported_sensitivity_catalog(m)
    model=imported_native(m);variables=Dict{String,Any}[]
    active=Set(g.pid for g in m.groups)
    counts=Dict{Int,Int}();material_owners=Dict{Int,Set{Int}}()
    for g in m.groups;counts[g.pid]=get(counts,g.pid,0)+length(g.eids);end
    for (key,prop) in model["PSHELLs"]
        pid=parse(Int,key);pid in active||continue
        mids=haskey(prop,"PLY_DATA") ? unique(Int(p["mid"]) for p in prop["PLY_DATA"]) : [Int(prop["MID"])]
        for mid in mids;push!(get!(material_owners,mid,Set{Int}()),pid);end
    end
    for (key,prop) in model["PBARLs"]
        pid=parse(Int,key);pid in active&&get(prop,"TYPE","") in ("T","BAR","ROD")||continue
        push!(get!(material_owners,Int(prop["MID"]),Set{Int}()),pid)
    end
    function add(id,label,value,unit,pids,field,directions)
        push!(variables,Dict{String,Any}("id"=>id,"label"=>label,"value"=>Float64(value),"unit"=>unit,"pids"=>sort!(collect(pids)),"field_key"=>field,"field_label"=>label,"directions"=>directions,
            "element_count"=>sum(get(counts,pid,0) for pid in pids),"group"=>startswith(id,"reference.MAT1") ? "Imported materials" : "Imported properties"))
    end
    for (key,prop) in sort!(collect(model["PSHELLs"]);by=first)
        pid=parse(Int,key);pid in active||continue
        if haskey(prop,"PLY_DATA")
            plies=prop["PLY_DATA"];total=Float64(prop["T"])
            direction=Dict("thickness"=>1.,"ply_thicknesses"=>[(p["z_top"]-p["z_bot"])/total for p in plies])
            add("reference.PCOMP#$pid#T","PCOMP $pid: proportional total thickness",total,"m",[pid],"shell.thickness",Dict(pid=>direction))
        else
            add("reference.PSHELL#$pid#T","PSHELL $pid: thickness",prop["T"],"m",[pid],"shell.thickness",Dict(pid=>Dict("thickness"=>1.)))
        end
    end
    for (key,prop) in sort!(collect(model["PBARLs"]);by=first)
        pid=parse(Int,key);pid in active||continue
        shape=get(prop,"TYPE","");dims=get(prop,"DIMS",Any[])
        shape in ("T","BAR","ROD")||continue
        for index in eachindex(dims)
            direction=zeros(length(dims));direction[index]=1.
            add("reference.PBARL#$pid#DIM$index","PBARL $pid $shape: dimension $index",dims[index],"m",[pid],"section.dimension$index",Dict(pid=>Dict("dimensions"=>direction)))
        end
    end
    for (key,mat) in sort!(collect(model["MATs"]);by=first)
        (haskey(mat,"E1")||haskey(mat,"G11"))&&continue
        haskey(mat,"E")&&haskey(mat,"NU")||continue
        mid=parse(Int,key);owners=sort!(collect(get(material_owners,mid,Set{Int}())))
        isempty(owners)&&continue
        for (field,nativekey,unit,scale,label) in (("E","E","GPa",1e9,"Elastic modulus"),("nu","NU","1",1.,"Poisson ratio"),("rho","RHO","kg/m3",1.,"Density"))
            directions=Dict{Int,Any}()
            for pid in owners
                directions[pid]=haskey(model["PSHELLs"],string(pid)) ? Dict("materials"=>Dict(mid=>Dict(field=>scale))) : Dict(field=>scale)
            end
            add("reference.MAT1#$mid#$field","MAT1 $mid: $label",get(mat,nativekey,0.)/scale,unit,owners,"material.$field",directions)
        end
    end
    Dict{String,Any}("variables"=>variables,"max_variables"=>length(variables),"cases"=>m.params["imported.cases"],"objectives"=>SENSITIVITY_OBJECTIVES,"solutions"=>sensitivity_solutions(m),"surfaces"=>["z1","z2"],"method"=>"analytic_discrete_adjoint",
        "note"=>"Choose the sensitivity solution independently of the source deck: SOL101 displacement/stress, SOL103 modal eigenvalue, SOL105 buckling factor, or SOL106 final-load displacement. Original loads, masses and constraints are retained; a buckling subcase uses its STATSUB preload case. SOL105 includes the static-preload adjoint. Supported variables include PSHELL thickness, proportional isotropic PCOMP thickness, MAT1 E/nu/density and T/BAR/ROD PBARL dimensions. Material G must satisfy E/(2(1+nu)); E/nu derivatives maintain that isotropic relation. SOL106 uses the exact residual Jacobian of the supported geometric nonlinear branch and requires fixed-direction loads and homogeneous constraints. Unsupported formulations and load tangents report explicit errors; no finite-difference fallback. Imported values must use consistent SI units for the displayed units.")
end

function imported_sensitivity_deck(m,id,solution="101";modes=10)
    solution=string(solution)
    solution in ("101","103","105","106")||throw(ArgumentError("Imported sensitivity decks support SOL101, SOL103, SOL105 and SOL106"))
    original=imported_native(m);subs=original["CASE_CONTROL"]["SUBCASES"]
    haskey(subs,id)||throw(ArgumentError("Imported subcase $id is missing"));row=subs[id];selected_row=row
    # A buckling companion carries METHOD/STATSUB rather than the load set.
    # Follow its actual preload ownership before selecting the requested solve.
    visited=Set{Int}([Int(id)])
    while get(row,"STATSUB",nothing)!==nothing
        owner=Int(row["STATSUB"])
        owner in visited&&throw(ArgumentError("Cyclic STATSUB ownership in imported subcase $id"))
        haskey(subs,owner)||throw(ArgumentError("Imported subcase $id refers to missing STATSUB $owner"))
        push!(visited,owner);row=subs[owner]
    end
    lines=split(get(m.params,"imported.analysis_deck",m.params["imported.source"]["flattened"]),'\n');bulk=findfirst(line->occursin(r"^\s*BEGIN\s+BULK"i,line),lines)
    bulk===nothing&&throw(ArgumentError("Imported sensitivities require an explicit BEGIN BULK delimiter"))
    body,method,_,_=imported_overlay_bulk(lines[bulk+1:end],imported_analysis_options())
    io=IOBuffer();println(io,"SOL $solution\nCEND\nTITLE = Imported sensitivity baseline\nDISPLACEMENT(PRINT) = ALL\nSTRESS(PRINT) = ALL\nFORCE(PRINT) = ALL\nSPCFORCES(PRINT) = ALL\nSUBCASE 1")
    for key in ("SPC","LOAD","MPC","TEMP","TEMPERATURE")
        value=get(row,key,nothing);value===nothing||println(io,"  $key = $value")
    end
    solution=="106"&&get(row,"NLPARM",nothing)!==nothing&&println(io,"  NLPARM = ",row["NLPARM"])
    solution=="103"&&println(io,"  METHOD = $method")
    if solution=="105"
        println(io,"SUBCASE 2\n  LABEL = Sensitivity buckling\n  STATSUB = 1\n  METHOD = $method")
        for key in ("SPC","MPC")
            value=get(selected_row,key,get(row,key,nothing));value===nothing||println(io,"  $key = $value")
        end
    end
    println(io,"BEGIN BULK");write(io,body)
    solution=="103"&&println(io,"EIGRL,$method,,,",clamp(Int(modes),1,200),",,,,MASS")
    # No arbitrary upper factor cutoff: request the selected number of modes.
    solution=="105"&&println(io,"EIGRL,$method,1.e-6,,",clamp(Int(modes),1,200),",,,,MASS")
    if solution=="106"
        options=imported_analysis_options(get(m.params,"imported.analysis",nothing))
        present=Set{String}()
        for line in split(body,'\n')
            imported_card_name(line)=="PARAM"||continue
            fields=imported_entry_fields([line])
            isempty(fields)||push!(present,uppercase(first(fields)))
        end
        # Retain every explicit source nonlinear control. Supply robust defaults
        # when converting a linear/modal deck, including a sensitivity-grade
        # residual tolerance for a reliable final-state derivative.
        defaults=(("NLLOADSTEPS",options["load_steps"]),("NLMAXITER",options["max_iterations"]),
            ("NLTOL",options["displacement_tolerance"]),("NLRESTOL",min(options["residual_tolerance"],1e-8)),
            ("NLCUTMAX",options["max_cutbacks"]),("NLMETHOD","AUTO"))
        for (name,value) in defaults
            name in present||haskey(original,"PARAM_"*name)||println(io,"PARAM,$name,$value")
        end
    end
    println(io,"ENDDATA");String(take!(io))
end

function imported_analytic_derivative(native,context,m,d,objective)
    imported_derivative_coverage(m,d)
    op=context.op;state=context.expanded;adjoint=sensitivity_expand_state(op,op.free,context.lambda)
    kind=objective["type"];features=sensitivity_response_features(native,op,m,objective,state)
    gradient=sensitivity_feature_response(features,objective;gradient=true).gradient
    ku=explicit=0.;n=0
    # Dead nodal forces and pressure loads do not depend on section/material
    # values at fixed geometry. Mass-dependent cards require their own tangent.
    massloads=any(!isempty(get(op.model,key,Any[])) for key in ("GRAVs","ACCELs","ACCEL1s","RFORCEs"))
    for (pid,direction) in d["directions"]
        changesmass=haskey(direction,"thickness")||haskey(direction,"dimensions")||get(direction,"rho",0.)!=0||any(get(mat,"rho",0.)!=0 for mat in values(get(direction,"materials",Dict())))
        massloads&&changesmass&&throw(ArgumentError("Imported mass-dependent load cards require an analytic load tangent for this property; no derivative was approximated"))
        for gr in m.groups
            gr.pid==pid||continue
            for e in 1:n_elements(gr)
                eid=gr.eids[e]
                if gr.kind===:bar
                    localdata=sensitivity_analytic_bar(native,op,m,gr,e,direction,state)
                    dofs=localdata.dofs;dk=localdata.dKe
                    if kind=="bar_stress"&&eid==objective["element_id"]
                        values=objective["component"]=="axial" ? [localdata.axial_stress] : localdata.stress_features
                        norm(values-features)<=1e-8max(norm(features),1.)||error("Analytic imported beam stress does not replay native objective $eid")
                        derivative=objective["component"]=="axial" ? [localdata.daxial_stress] : localdata.dstress_features
                        explicit+=dot(gradient,derivative)
                    end
                else
                    haskey(op.shell_capture.contexts,eid)||throw(ArgumentError("No exact native shell derivative is available for EID $eid"))
                    ctx=op.shell_capture.contexts[eid];localdata=native.Solver.analytic_shell_tangent(ctx,direction)
                    dofs=localdata.dofs;dk=localdata.dKe
                    if kind=="shell_stress"&&eid==objective["element_id"]
                        prop=op.model["PSHELLs"][string(pid)]
                        imported_stress_fibers_supported(native,prop)
                        response=native.Solver.analytic_shell_stress_tangent(ctx,direction,state,op.id_map,op.X,op.node_R,op.snorm_normals;surface=objective["surface"])
                        norm(response.features-features)<=1e-8max(norm(features),1.)||error("Analytic imported shell stress does not replay native objective $eid")
                        explicit+=dot(gradient,response.dfeatures)
                    end
                end
                ku+=dot(adjoint[dofs],dk*state[dofs]);n+=1
            end
        end
    end
    (value=explicit-ku,elements=n)
end

function imported_stress_fibers_supported(native,prop)
    get(prop,"TYPE","")=="PCOMP_CLT"||native.Solver._pshell_stress_fibers_are_default(prop)||throw(ArgumentError("Analytic imported shell stress with explicit PSHELL Z1/Z2 fibers is unsupported, including explicit fibers equal to +/-T/2; no derivative was approximated"))
    nothing
end

"""Reject a partial derivative when an affected native owner is not represented.

The forward stiffness includes hidden element families too. A baseline replay
cannot detect an omitted *derivative* contribution, so check all native owners.
"""
function imported_derivative_coverage(m,d)
    model=imported_native(m);tokens=split(d["id"],'#')
    material=startswith(first(tokens),"reference.MAT1") ? parse(Int,tokens[2]) : nothing
    visible=Set(eid for g in m.groups for eid in g.eids)
    for (family,properties) in (("CSHELLs","PSHELLs"),("CBARs","PBARLs"),("CBEAMs","PBARLs"),("CRODs","PRODs"),("CONRODs",""),("CSOLIDs","PSOLIDs"))
        for el in values(get(model,family,Dict()))
            eid=Int(el["ID"]);pid=Int(get(el,"PID",0))
            prop=isempty(properties) ? el : get(get(model,properties,Dict()),string(pid),Dict())
            mids=haskey(prop,"PLY_DATA") ? [Int(p["mid"]) for p in prop["PLY_DATA"]] : Int[Int(prop[key]) for key in ("MID","MID2","MID3","MID4") if get(prop,key,nothing) isa Integer]
            affected=material===nothing ? pid in d["pids"] : material in mids
            affected||continue
            family in ("CSHELLs","CBARs")&&eid in visible&&haskey(d["directions"],pid)&&continue
            throw(ArgumentError("$(d["label"]) also affects native $(get(el,"TYPE",family)) EID $eid, which lacks a supported analytic derivative. No partial contribution was reported."))
        end
    end
    nothing
end

"""Differentiate the selected native modal pencil at its solved eigenvector.

Element tangents remain in physical analysis coordinates. Expanding the mode
before contraction applies the same fixed MPC congruence as native assembly;
no property perturbations or additional eigenproblems are evaluated here.
"""
function imported_modal_derivative(native,context,m,d;cancelled=()->false)
    imported_derivative_coverage(m,d)
    op=context["op"];phi=context["physical_phi"];kp=mp=0.;n=0;replay=0.
    mass_directions=Dict{Int,Any}()
    for (pid,direction) in d["directions"]
        cancelled()&&error("Sensitivity study cancelled")
        for gr in m.groups
            gr.pid==pid||continue
            for e in 1:n_elements(gr)
                eid=gr.eids[e]
                if gr.kind===:bar
                    localdata=sensitivity_analytic_bar(native,op,m,gr,e,direction)
                    pe=phi[localdata.dofs];mp+=dot(pe,localdata.dMe*pe)
                    replay=max(replay,localdata.stiffness_replay_relative_error)
                else
                    haskey(op.shell_capture.contexts,eid)||throw(ArgumentError("No exact native shell derivative is available for EID $eid"))
                    localdata=native.Solver.analytic_shell_tangent(op.shell_capture.contexts[eid],direction)
                    pe=phi[localdata.dofs];replay=max(replay,localdata.replay_error)
                    moments=Float64.(collect(localdata.dmass_moments))
                    prop=op.model["PSHELLs"][string(pid)]
                    # Native PSHELL consistent mass spreads fixed NSM through
                    # the section thickness. PCOMP instead places it at z=0.
                    if get(prop,"TYPE","")!="PCOMP_CLT"
                        moments[3]+=Float64(get(prop,"NSM",0.))*Float64(prop["T"])*Float64(get(direction,"thickness",0.))/6
                    end
                    candidate=Dict("mass_moments"=>Tuple(moments))
                    haskey(mass_directions,pid)&&mass_directions[pid]!=candidate&&error("Native shell mass tangent varies unexpectedly within property $pid")
                    mass_directions[pid]=candidate
                end
                kp+=dot(pe,localdata.dKe*pe);n+=1
            end
        end
    end
    dm=sensitivity_analytic_shell_mass(native,op,mass_directions)
    mp+=Float64(get(op.model,"PARAM_WTMASS",1.))*dot(phi,dm*phi)
    value=(kp-context["lambda"]*mp)/context["denominator"]
    isfinite(value)||error("Imported modal derivative is nonfinite")
    (value=value,elements=n,stiffness_contraction=kp,mass_contraction=mp,kernel_replay_relative_error=replay)
end

function imported_buckling_context(native,forward,m,objective;cancelled=()->false)
    model=forward["model"]
    subs=model["CASE_CONTROL"]["SUBCASES"]
    eig=only([sub for sub in values(subs) if get(sub,"STATSUB",nothing)!==nothing])
    preload=subs[eig["STATSUB"]]
    all(get(eig,key,nothing)==get(preload,key,nothing) for key in ("SPC","MPC"))||throw(ArgumentError("Imported buckling sensitivities require matching preload and eigenproblem constraint selections; distinct original SPC/MPC selections were preserved but are unsupported by this adjoint context"))
    for family in ("CBEAMs","CRODs","CONRODs","CSOLIDs")
        isempty(get(model,family,Dict()))||throw(ArgumentError("Imported buckling preload derivatives do not yet cover native $family; no partial preload gradient was reported"))
    end
    for (family,kind) in (("CSHELLs",:shell),("CBARs",:bar))
        visible=Set(eid for gr in m.groups if (gr.kind===:bar)==(kind===:bar) for eid in gr.eids)
        native_ids=Set(Int(el["ID"]) for el in values(get(model,family,Dict())))
        visible==native_ids||throw(ArgumentError("Imported buckling requires every native $family element in the analytic preload context"))
    end
    follower=get(model,"PARAM_JFFOLLOW",0)!=0||any(get(force,"FLLW","")=="ROT" for force in get(model,"FORCEs",Any[]))
    follower&&throw(ArgumentError("Imported SOL105 sensitivity requires a fixed-direction preload; follower loads are unsupported"))
    sensitivity_eigen_context(native,forward,m,objective;analytic=true,cancelled)
end

"""Exact explicit elastic/geometric derivative plus the shared preload adjoint."""
function imported_buckling_derivative(native,context,m,d;cancelled=()->false)
    imported_derivative_coverage(m,d)
    op=context["op"];phi=context["physical_phi"];state=context["state"]
    adjoint=sensitivity_expand_state(op,op.free,context["adjoint"][op.free])
    kp=gp=ku=0.;n=0
    massloads=any(!isempty(get(op.model,key,Any[])) for key in ("GRAVs","ACCELs","ACCEL1s","RFORCEs"))
    for (pid,direction) in d["directions"]
        cancelled()&&error("Sensitivity study cancelled")
        changesmass=haskey(direction,"thickness")||haskey(direction,"dimensions")||get(direction,"rho",0.)!=0||any(get(mat,"rho",0.)!=0 for mat in values(get(direction,"materials",Dict())))
        massloads&&changesmass&&throw(ArgumentError("Imported mass-dependent preload cards require an analytic load tangent for this property; no derivative was approximated"))
        for gr in m.groups
            gr.pid==pid||continue
            for e in 1:n_elements(gr)
                eid=gr.eids[e]
                localdata=if gr.kind===:bar
                    sensitivity_analytic_bar(native,op,m,gr,e,direction,state)
                else
                    haskey(op.shell_capture.contexts,eid)||throw(ArgumentError("No exact native shell derivative is available for EID $eid"))
                    native.Solver.analytic_shell_tangent(op.shell_capture.contexts[eid],direction)
                end
                dofs=localdata.dofs;pe=phi[dofs]
                kp+=dot(pe,localdata.dKe*pe)
                ku+=dot(adjoint[dofs],localdata.dKe*state[dofs])
                gr.kind===:bar&&(gp+=dot(pe,localdata.dKg*pe))
                n+=1
            end
        end
    end
    gp+=sensitivity_analytic_shell_geometric(native,op,m,d["directions"],state,phi;contexts=context["geometric_contexts"])
    value=-(kp+context["lambda"]*gp-ku)/context["denominator"]
    isfinite(value)||error("Imported buckling derivative is nonfinite")
    (value=value,elements=n,stiffness_contraction=kp,geometric_contraction=gp,preload_adjoint_contraction=ku)
end

function compute_imported_sensitivity(m,raw,dir;native,solve,progress,cancelled)
    request=sensitivity_request(m,raw);objective=request["objective"];sol=request["solution"]
    sol in ("101","103","105","106")||throw(ArgumentError("Imported sensitivities support SOL101, SOL103, SOL105 and SOL106"))
    modal=sol=="103";buckling=sol=="105";nonlinear=sol=="106"
    (modal ? objective["type"]=="frequency_eigenvalue" : buckling ? objective["type"]=="buckling_factor" : objective["type"] in ("displacement","shell_stress","bar_stress"))||throw(ArgumentError("The selected objective does not match imported SOL$sol"))
    request["derivative_method"]=="analytic"||throw(ArgumentError("Imported-deck sensitivities use exact analytic adjoints; legacy operator differences are not available"))
    catalog=imported_sensitivity_catalog(m);lookup=Dict(d["id"]=>d for d in catalog["variables"]);variables=[lookup[id] for id in request["variables"]]
    spec=only(filter(row->row.id==request["case_id"],load_case_specs(m.params)));mkpath(dir)
    counts=Dict{String,Any}("forward_solves"=>0,"adjoint_solves"=>0,"eigen_solves"=>0,"perturbed_forward_solves"=>0,"operator_evaluations"=>0,"finite_difference_samples"=>0,"analytic_property_derivatives"=>0)
    completed=Ref(0);started=time()
    report(detail,phase)=begin
        cancelled()&&error("Sensitivity study cancelled")
        progress(Dict("completed"=>completed[],"total"=>2+length(variables),"detail"=>detail,"phase"=>phase,"solver_counts"=>copy(counts)))
    end
    report("Solving imported SOL$sol baseline 1/1 with selected original subcase $(spec.id)","forward")
    modes=min(24,max(Int(get(objective,"mode",1))+4,6))
    path=joinpath(dir,"baseline.bdf");write(path,imported_sensitivity_deck(m,spec.id,sol;modes))
    nonlinear&&sensitivity_nonlinear_supported_model(native,native.bdf_to_model(path),objective)
    forward=solve(path);counts["forward_solves"]=1;completed[]+=1
    baseline_native=deepcopy(forward["model"]);p=copy(m.params);p["imported.native"]=baseline_native;p["output.solution"]=sol
    baseline=Model((field===:params ? p : getfield(m,field) for field in fieldnames(Model))...)
    metadata=sensitivity_export_baseline(native,forward,m,baseline,dir,spec,sol;seconds=time()-started)
    base=sensitivity_response(forward,baseline,objective)
    report(modal ? "Preparing native modal self-adjoint contraction; no second solve" : "Solving the shared imported-model transpose adjoint 1/1","adjoint")
    context=if modal
        sensitivity_eigen_context(native,forward,baseline,objective;analytic=true,cancelled)
    elseif buckling
        imported_buckling_context(native,forward,baseline,objective;cancelled)
    elseif nonlinear
        sensitivity_nonlinear_context(native,forward,baseline,objective;analytic=true,cancelled)
    else
        sensitivity_static_context(native,forward,baseline,objective;analytic=true)
    end
    counts["adjoint_solves"]=modal ? 0 : 1;counts["eigen_solves"]=modal||buckling ? 1 : 0
    counts["operator_evaluations"]=modal ? 2 : 1
    merge!(counts,sensitivity_context_get(context,"solver_counts",Dict()));completed[]+=1
    notes=modal ? ["Original selected Reference constraints and native mass formulation. One modal baseline; exact element stiffness and mass derivatives contracted with its eigenvector. No extra adjoint solve, perturbed eigenproblems or finite-difference samples."] : buckling ?
        ["Original selected Reference preload and eigenproblem. One baseline containing the static preload and buckling eigenproblem, plus one shared preload adjoint. Exact elastic and geometric property derivatives include the changed preload state. No perturbed forward solves or finite-difference samples."] : nonlinear ?
        ["Original selected Reference load and constraint sets. One converged full-load SOL106 baseline and one transpose adjoint of the exact residual R(u)=K*u+c*Kg(u)*u-F. The adjoint uses the derivative of that residual, including the state dependence of Kg. No perturbed forward solves or finite-difference samples."] :
        ["Original selected Reference load and constraint sets. One baseline and one shared adjoint; no perturbed forward solutions or finite-difference samples."]
    rows=Any[];result=Dict{String,Any}("method"=>modal ? "analytic_eigenvalue_adjoint" : nonlinear ? "analytic_nonlinear_adjoint" : "analytic_discrete_adjoint","derivative_assembly"=>"analytic_chain_rule","case_id"=>spec.id,"case_label"=>spec.label,"solution"=>sol,"objective"=>objective,"request"=>request,
        "baseline_model_signature"=>sensitivity_model_signature(m),"baseline_model_signature_version"=>2,"baseline_topology_signature"=>sensitivity_topology_signature(m),"scope"=>sensitivity_scope(m,variables),"load_application_version"=>IMPORTED_LOAD_VERSION,"result_format_version"=>2,"imported_signature"=>m.params["imported.source"]["signature"],
        "compatibility"=>Dict("model_match"=>true,"topology_match"=>true,"load_application_match"=>true,"is_current"=>true,"map_allowed"=>true,"reasons"=>String[],"current_load_application_version"=>IMPORTED_LOAD_VERSION),
        "baseline"=>Dict("value"=>base.value,"unit"=>base.unit,"mode"=>base.mode),"baseline_analysis"=>metadata,"rows"=>rows,"solver_counts"=>counts,"diagnostics"=>sensitivity_context_get(context,"diagnostics",Dict()),"operator_samples_planned"=>0,"operator_samples_completed"=>0,"warnings"=>String[],"notes"=>notes)
    checkpoint=sensitivity_result_checkpoint(dir,result)
    sensitivity_checkpointed(checkpoint) do
    for (i,d) in enumerate(variables)
        report("Analytic imported property $i/$(length(variables)): $(d["label"])","analytic_derivatives")
        row=Dict{String,Any}(key=>d[key] for key in ("id","label","value","unit","pids","field_key","field_label"));row["derivative_unit"]=base.unit*" / "*d["unit"];row["step_error"]=nothing
        try
            sample=modal ? imported_modal_derivative(native,context,baseline,d;cancelled) : buckling ?
                imported_buckling_derivative(native,context,baseline,d;cancelled) : nonlinear ?
                sensitivity_nonlinear_derivative(native,context,baseline,d;cancelled) : imported_analytic_derivative(native,context,baseline,d,objective)
            value=sensitivity_context_get(sample,"value")
            merge!(row,Dict("derivative"=>value,"normalized_derivative"=>iszero(base.value) ? nothing : d["value"]*value/base.value,"status"=>"ok","warning"=>"","elements"=>sensitivity_context_get(sample,"elements",nothing)));counts["analytic_property_derivatives"]+=1
            modal&&(row["diagnostics"]=Dict(key=>sensitivity_context_get(sample,key) for key in ("stiffness_contraction","mass_contraction","kernel_replay_relative_error")))
            buckling&&(row["diagnostics"]=Dict(key=>sensitivity_context_get(sample,key) for key in ("stiffness_contraction","geometric_contraction","preload_adjoint_contraction")))
        catch err
            cancelled()&&rethrow()
            merge!(row,Dict("derivative"=>nothing,"normalized_derivative"=>nothing,"status"=>"failed","warning"=>sprint(showerror,err)))
        end
        push!(rows,row);completed[]+=1;checkpoint()
    end
    result["status"]=all(row->row["status"]=="ok",rows) ? "complete" : "partial";result["timings_seconds"]=Dict("total"=>time()-started)
    report("Imported SOL$sol analytic sensitivity $(result["status"]): one baseline, $(counts["adjoint_solves"]) adjoint solves, zero finite differences","complete")
    result
    end
end
