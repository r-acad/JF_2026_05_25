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
    function add(id,label,value,unit,pids,field,directions)
        push!(variables,Dict{String,Any}("id"=>id,"label"=>label,"value"=>Float64(value),"unit"=>unit,"pids"=>sort!(collect(pids)),"field_key"=>field,"field_label"=>label,"directions"=>directions,
            "element_count"=>sum(length(g.eids) for g in m.groups if g.pid in pids),"group"=>startswith(id,"nastran.MAT1") ? "Imported materials" : "Imported properties"))
    end
    for (key,prop) in sort!(collect(model["PSHELLs"]);by=first)
        pid=parse(Int,key);pid in active||continue
        if haskey(prop,"PLY_DATA")
            plies=prop["PLY_DATA"];total=Float64(prop["T"])
            direction=Dict("thickness"=>1.,"ply_thicknesses"=>[(p["z_top"]-p["z_bot"])/total for p in plies])
            add("nastran.PCOMP#$pid#T","PCOMP $pid: proportional total thickness",total,"m",[pid],"shell.thickness",Dict(pid=>direction))
        else
            add("nastran.PSHELL#$pid#T","PSHELL $pid: thickness",prop["T"],"m",[pid],"shell.thickness",Dict(pid=>Dict("thickness"=>1.)))
        end
    end
    for (key,prop) in sort!(collect(model["PBARLs"]);by=first)
        pid=parse(Int,key);pid in active||continue
        shape=get(prop,"TYPE","");dims=get(prop,"DIMS",Any[])
        shape in ("T","BAR","ROD")||continue
        for index in eachindex(dims)
            direction=zeros(length(dims));direction[index]=1.
            add("nastran.PBARL#$pid#DIM$index","PBARL $pid $shape: dimension $index",dims[index],"m",[pid],"section.dimension$index",Dict(pid=>Dict("dimensions"=>direction)))
        end
    end
    for (key,mat) in sort!(collect(model["MATs"]);by=first)
        (haskey(mat,"E1")||haskey(mat,"G11"))&&continue
        haskey(mat,"E")&&haskey(mat,"NU")||continue
        mid=parse(Int,key);owners=Int[]
        for (pidstring,prop) in model["PSHELLs"]
            pid=parse(Int,pidstring);pid in active||continue
            mids=haskey(prop,"PLY_DATA") ? [Int(p["mid"]) for p in prop["PLY_DATA"]] : [Int(prop["MID"])]
            mid in mids&&push!(owners,pid)
        end
        for (pidstring,prop) in model["PBARLs"]
            pid=parse(Int,pidstring);pid in active&&Int(prop["MID"])==mid&&get(prop,"TYPE","") in ("T","BAR","ROD")&&push!(owners,pid)
        end
        isempty(owners)&&continue
        for (field,nativekey,unit,scale,label) in (("E","E","GPa",1e9,"Elastic modulus"),("nu","NU","1",1.,"Poisson ratio"),("rho","RHO","kg/m3",1.,"Density"))
            directions=Dict{Int,Any}()
            for pid in owners
                directions[pid]=haskey(model["PSHELLs"],string(pid)) ? Dict("materials"=>Dict(mid=>Dict(field=>scale))) : Dict(field=>scale)
            end
            add("nastran.MAT1#$mid#$field","MAT1 $mid: $label",get(mat,nativekey,0.)/scale,unit,owners,"material.$field",directions)
        end
    end
    Dict{String,Any}("variables"=>variables,"max_variables"=>4096,"cases"=>m.params["imported.cases"],"objectives"=>Dict(k=>v for (k,v) in SENSITIVITY_OBJECTIVES if k in ("displacement","shell_stress","bar_stress")),"surfaces"=>["z1","z2"],"method"=>"analytic_discrete_adjoint",
        "note"=>"Imported source cards and loads remain authoritative. Static SOL101 adjoints support PSHELL thickness, proportional symmetric isotropic PCOMP thickness, MAT1 E/nu/density and T/BAR/ROD PBARL dimensions. Material G must satisfy E/(2(1+nu)); E/nu derivatives vary G to maintain that isotropic relation, even if the original card explicitly supplied G. Unsupported formulation, release, offset or property-dependent body-load branches report explicit failed rows; no finite-difference fallback. Imported values must use consistent SI units for the displayed units.")
end

function imported_sensitivity_deck(m,id,solution="101")
    original=imported_native(m);subs=original["CASE_CONTROL"]["SUBCASES"]
    haskey(subs,id)||throw(ArgumentError("Imported subcase $id is missing"));row=subs[id]
    lines=split(m.params["imported.source"]["flattened"],'\n');bulk=findfirst(line->occursin(r"^\s*BEGIN\s+BULK"i,line),lines)
    bulk===nothing&&throw(ArgumentError("Imported sensitivities require an explicit BEGIN BULK delimiter"))
    io=IOBuffer();println(io,"SOL $solution\nCEND\nTITLE = Imported sensitivity baseline\nDISPLACEMENT(PRINT) = ALL\nSTRESS(PRINT) = ALL\nFORCE(PRINT) = ALL\nSPCFORCES(PRINT) = ALL\nSUBCASE 1")
    for key in ("SPC","LOAD","MPC","TEMP","TEMPERATURE","NLPARM")
        value=get(row,key,nothing);value===nothing||println(io,"  $key = $value")
    end
    println(io,"BEGIN BULK");write(io,join(lines[bulk+1:end],"\n"));String(take!(io))
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
    material=startswith(first(tokens),"nastran.MAT1") ? parse(Int,tokens[2]) : nothing
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

function compute_imported_sensitivity(m,raw,dir;native,solve,progress,cancelled)
    request=sensitivity_request(m,raw);objective=request["objective"]
    objective["type"] in ("displacement","shell_stress","bar_stress")||throw(ArgumentError("Imported-deck sensitivity currently supports static displacement and stress objectives"))
    request["derivative_method"]=="analytic"||throw(ArgumentError("Imported-deck sensitivities use exact analytic adjoints; legacy operator differences are not available"))
    catalog=imported_sensitivity_catalog(m);lookup=Dict(d["id"]=>d for d in catalog["variables"]);variables=[lookup[id] for id in request["variables"]]
    spec=only(filter(row->row.id==request["case_id"],load_case_specs(m.params)));mkpath(dir)
    counts=Dict{String,Any}("forward_solves"=>0,"adjoint_solves"=>0,"eigen_solves"=>0,"perturbed_forward_solves"=>0,"operator_evaluations"=>0,"finite_difference_samples"=>0,"analytic_property_derivatives"=>0)
    completed=Ref(0);started=time()
    report(detail,phase)=begin
        cancelled()&&error("Sensitivity study cancelled")
        progress(Dict("completed"=>completed[],"total"=>2+length(variables),"detail"=>detail,"phase"=>phase,"solver_counts"=>copy(counts)))
    end
    report("Solving imported SOL101 baseline 1/1 with selected original subcase $(spec.id)","forward")
    path=joinpath(dir,"baseline.bdf");write(path,imported_sensitivity_deck(m,spec.id))
    forward=solve(path);counts["forward_solves"]=1;completed[]+=1
    baseline_native=deepcopy(forward["model"]);p=copy(m.params);p["imported.native"]=baseline_native;p["output.solution"]="101"
    baseline=Model((field===:params ? p : getfield(m,field) for field in fieldnames(Model))...)
    metadata=sensitivity_export_baseline(native,forward,m,baseline,dir,spec,"101";seconds=time()-started)
    base=sensitivity_response(forward,baseline,objective)
    report("Solving the shared imported-model transpose adjoint 1/1","adjoint")
    context=sensitivity_static_context(native,forward,baseline,objective;analytic=true);counts["adjoint_solves"]=1;counts["operator_evaluations"]=1;completed[]+=1
    rows=Any[];result=Dict{String,Any}("method"=>"analytic_discrete_adjoint","derivative_assembly"=>"analytic_chain_rule","case_id"=>spec.id,"case_label"=>spec.label,"solution"=>"101","objective"=>objective,"request"=>request,
        "baseline_model_signature"=>sensitivity_model_signature(m),"baseline_model_signature_version"=>2,"baseline_topology_signature"=>sensitivity_topology_signature(m),"scope"=>sensitivity_scope(m,variables),"load_application_version"=>IMPORTED_LOAD_VERSION,"result_format_version"=>2,"imported_signature"=>m.params["imported.source"]["signature"],
        "compatibility"=>Dict("model_match"=>true,"topology_match"=>true,"load_application_match"=>true,"is_current"=>true,"map_allowed"=>true,"reasons"=>String[],"current_load_application_version"=>IMPORTED_LOAD_VERSION),
        "baseline"=>Dict("value"=>base.value,"unit"=>base.unit,"mode"=>nothing),"baseline_analysis"=>metadata,"rows"=>rows,"solver_counts"=>counts,"diagnostics"=>context.diagnostics,"operator_samples_planned"=>0,"warnings"=>String[],"notes"=>["Original selected Nastran load and constraint sets. One baseline and one shared adjoint; no perturbed forward solutions or finite-difference samples."])
    for (i,d) in enumerate(variables)
        report("Analytic imported property $i/$(length(variables)): $(d["label"])","analytic_derivatives")
        row=Dict{String,Any}(key=>d[key] for key in ("id","label","value","unit","pids","field_key","field_label"));row["derivative_unit"]=base.unit*" / "*d["unit"];row["step_error"]=nothing
        try
            sample=imported_analytic_derivative(native,context,baseline,d,objective)
            merge!(row,Dict("derivative"=>sample.value,"normalized_derivative"=>iszero(base.value) ? nothing : d["value"]*sample.value/base.value,"status"=>"ok","warning"=>"","elements"=>sample.elements));counts["analytic_property_derivatives"]+=1
        catch err
            merge!(row,Dict("derivative"=>nothing,"normalized_derivative"=>nothing,"status"=>"failed","warning"=>sprint(showerror,err)))
        end
        push!(rows,row);completed[]+=1;sensitivity_json_write(joinpath(dir,"partial_result.json"),result)
    end
    result["status"]=all(row->row["status"]=="ok",rows) ? "complete" : "partial";result["timings_seconds"]=Dict("total"=>time()-started)
    report("Imported analytic adjoint $(result["status"]): one baseline, one adjoint, zero finite differences","complete")
    result
end
