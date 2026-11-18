# Physical RF response registry and local partials. Input follows the existing
# stress-report transport; output rows are per physical criterion and load case.
# Shared criterion membership is projected to property views after differentiation.

mutable struct RFNativeInputs
    case_id::Any
    records::Any
    feature_keys::Vector{Any}
    feature_values::Vector{Float64}
    capacity_keys::Vector{Any}
    capacity_values::Vector{Float64}
end
RFNativeInputs(case_id,records)=RFNativeInputs(case_id,records,Any[],Float64[],Any[],Float64[])

function rf_path_get(value,path)
    for key in path
        value=key isa Integer&&value isa AbstractVector ? (1<=key<=length(value) ? value[key] : nothing) : rf_get(value,key,nothing)
        value===nothing&&break
    end
    value
end
function rf_record(records,eid)
    rf_get(records,eid,rf_get(records,string(eid),nothing))
end
function rf_feature!(b,eid,quantity,path;nonlinear=false)
    record=rf_record(b.records,eid);value=rf_path_get(rf_get(record,quantity,nothing),path)
    rf_number(value)||throw(ArgumentError("Element $eid has no finite $quantity recovery at $(join(path,'.'))"))
    push!(b.feature_keys,Dict{String,Any}("case_id"=>b.case_id,"eid"=>Int(eid),"quantity"=>quantity,"path"=>collect(path),"frame"=>"view","nonlinear"=>nonlinear))
    push!(b.feature_values,Float64(value));length(b.feature_values)
end
function rf_capacity!(b,value,descriptor)
    rf_number(value)||throw(ArgumentError("Nonfinite RF capacity input"))
    push!(b.capacity_keys,descriptor);push!(b.capacity_values,Float64(value));length(b.capacity_values)
end
rf_capacity_index(b,index)=length(b.feature_values)+index

function rf_policy(input)
    p=rf_get(input,"assessmentPolicy",Dict())
    strength=rf_get(p,"strengthSafetyFactor",rf_get(input,"strengthSafetyFactor",rf_get(input,"assessment.strength_safety_factor",1.5)))
    buckling=rf_get(p,"bucklingPolicyFactor",rf_get(input,"bucklingPolicyFactor",rf_get(input,"assessment.buckling_policy_factor",1.)))
    rf_positive(strength)&&rf_positive(buckling)||throw(ArgumentError("Assessment factors must be finite and positive"))
    (;strength,buckling)
end
function rf_native_cases(input)
    out=Any[];excluded=Any[];selected=string(rf_get(input,"caseId","all"))
    for (id,parent) in rf_entries(rf_get(input,"cases",Dict()))
        selected=="all"||selected==string(id)||continue
        variants=rf_get(parent,"variants",nothing)
        parent_analysis=string(rf_get(parent,"analysis",rf_get(parent,"solution",rf_get(parent,"analysis_type",""))))
        parent_match=match(r"(?:SOL\s*)?(101|103|105|106)",parent_analysis)
        parent_solution=parent_match===nothing ? 0 : parse(Int,parent_match[1])
        for (variant,result) in (variants===nothing ? [("default",parent)] : rf_entries(variants))
            analysis=string(rf_get(result,"analysis",rf_get(result,"solution",rf_get(result,"analysis_type",""))))
            matchsol=match(r"(?:SOL\s*)?(101|103|105|106)",analysis);sol=matchsol===nothing ? 0 : parse(Int,matchsol[1])
            reason=!(sol in (101,106)) ? "Only static SOL101 and fully converged SOL106 assessments are supported" :
                rf_get(result,"matches",false)!==true ? "Results have not been verified against the current model" :
                rf_get(result,"available",true)===false ? "Results are unavailable" :
                rf_get(result,"historical",false) ? "Historical formulation results require reanalysis" :
                rf_get(result,"static",false)!==true ? "No physical static result was returned" : ""
            status=lowercase(string(rf_get(result,"status","complete")))
            occursin(r"fail|cancel|timeout|stop|partial|running|pending|error",status)&&(reason="Analysis is incomplete or unsuccessful")
            conv=rf_get(result,"convergence",nothing)
            if sol==106&&(conv===nothing||rf_get(conv,"converged",false)!==true||rf_get(conv,"full_load",false)!==true||rf_get(conv,"partial",false))
                reason="Nonlinear equilibrium has not converged at full load"
            end
            rf_get(input,"modelDirty",false)&&(reason="The model has unsolved changes")
            rf_get(input,"pendingDrafts",false)&&(reason="Uncommitted model inputs must be resolved before assessment")
            rf_get(input,"running",false)&&(reason="Analysis is still running")
            rf_get(result,"source","")=="disk_results"&&(reason="Stored results lack the required physical recovery provenance")
            isempty(rf_get(result,"validationIssues",Any[]))||(reason="Result validation issues: "*join(rf_get(result,"validationIssues",Any[]),"; "))
            for field in ("signature","meshIdentity")
                expected=rf_get(input,field,nothing)
                expected===nothing||expected==rf_get(result,field,nothing)||(reason="Results belong to a different $field")
            end
            # Catalog enumeration preserves the requested solution identity but
            # does not assert an accepted equilibrium or numerical RF value.
            if rf_get(input,"catalog_only",false)
                reason=sol in (101,106) ? "" : "This solution has no static engineering RF catalogue"
            end
            parent_solution in (103,105)&&(reason="Modal/global-buckling parents are outside the static engineering RF report")
            label=string(rf_get(result,"caseLabel",rf_get(parent,"label","Load case $id")))
            item=Dict{String,Any}("case_id"=>id,"case_key"=>"$id:$variant","label"=>label,"solution"=>sol,"result"=>result,"reason"=>reason,"relevant"=>!(parent_solution in (103,105))&&sol in (0,101,106))
            push!(isempty(reason) ? out : excluded,item)
        end
    end
    present=Set(string(item["case_id"]) for item in vcat(out,excluded))
    for (key,expected) in rf_entries(rf_get(input,"expectedCases",Any[]))
        id=rf_get(expected,"id",key)
        selected=="all"||selected==string(id)||continue
        rf_get(expected,"enabled",true)===false&&continue
        analysis=string(rf_get(expected,"solution",rf_get(expected,"analysis","101")))
        occursin(r"103|105",analysis)&&continue
        string(id) in present&&continue
        push!(excluded,Dict{String,Any}("case_id"=>id,"case_key"=>"$id:missing","label"=>rf_get(expected,"label","Load case $id"),"solution"=>0,"reason"=>"No result has been returned for the required load case","relevant"=>true))
    end
    out,excluded
end

function rf_response(b,id,mode,scope,kernel;derivatives=true,metadata=Dict{String,Any}(),source=nothing,gradient=nothing)
    x=vcat(b.feature_values,b.capacity_values);value=Float64(kernel(x))
    isfinite(value)&&value>=0||throw(ArgumentError("RF utilization is not finite and nonnegative"))
    nf=length(b.feature_values)
    zero_equivalent=iszero(value)&&mode in ("von_mises","principal_strain")
    # Equivalent-stress/strain norms are non-differentiable at the origin.
    # Select their valid zero Clarke subgradient before AD can encounter an
    # undefined hypot(0,0) partial. A separate directional map retains the
    # actual norm response; the zero row is not called an ordinary derivative.
    g=derivatives&&!zero_equivalent ? (gradient===nothing ? ForwardDiff.gradient(kernel,x) : gradient) : zeros(length(x))
    all(isfinite,g)||throw(ArgumentError("RF local derivative is nonfinite"))
    row=Dict{String,Any}("response_id"=>id,"physical_criterion_id"=>scope,"failure_mode"=>mode,
        "case_id"=>b.case_id,"utilization"=>value,"raw_RF"=>value>0 ? inv(value) : nothing,
        "no_demand"=>iszero(value),"status"=>"ok","derivative_status"=>derivatives ? "analytic_local" : "not_requested",
        "feature_keys"=>b.feature_keys,"feature_values"=>b.feature_values,"feature_gradient"=>g[1:nf],
        "capacity_keys"=>b.capacity_keys,"capacity_values"=>b.capacity_values,"capacity_gradient"=>g[nf+1:end],
        "load_basis"=>"LIMIT","_evaluate"=>kernel,"_capacity_source"=>source)
    merge!(row,metadata)
    if mode in ("von_mises","principal_strain","euler_column","stringer_blade","spar_cap_buckling","rib_stiffener_buckling","rib_stiffener_blade")
        row["branch_policy"]="Exact extrema; seed-independent Clarke-average partials at roundoff-scale ties"
        row["gradient_class"]="piecewise_response_with_clarke_ties"
        derivatives&&(row["derivative_status"]="piecewise_smooth")
    end
    if zero_equivalent
        row["gradient_class"]="zero_demand_selected_clarke"
        derivatives&&(row["derivative_status"]="piecewise_smooth")
        row["directional_status"]="exact_one_sided_norm"
        row["_directional"]=v->begin
            length(v)==length(x)||throw(DimensionMismatch("RF directional input has the wrong number of features and capacities"))
            kernel(vcat(v[1:nf],b.capacity_values))
        end
        row["reason"]="Zero equivalent demand has directional derivatives; the returned zero is a subgradient, not a unique ordinary RF derivative"
    end
    row
end
function rf_unavailable(id,mode,scope,case_id,reason;metadata=Dict())
    merge(Dict{String,Any}("response_id"=>id,"physical_criterion_id"=>scope,"failure_mode"=>mode,"case_id"=>case_id,
        "utilization"=>nothing,"raw_RF"=>nothing,"no_demand"=>false,"status"=>"unavailable","derivative_status"=>"unavailable",
        "reason"=>reason,"feature_keys"=>Any[],"feature_values"=>Float64[],"feature_gradient"=>Float64[],
        "capacity_keys"=>Any[],"capacity_values"=>Float64[],"capacity_gradient"=>Float64[]),metadata)
end
function rf_scope_membership(raw,input=Dict())
    pids=Set{Int}();eids=Set{Int}()
    function add!(set,value)
        value===nothing&&return
        id=value isa Integer ? Int(value) : tryparse(Int,string(value))
        id===nothing||id<=0||push!(set,id)
    end
    add!(pids,rf_get(raw,"pid",nothing))
    for pid in rf_get(raw,"property_ids",Any[]);add!(pids,pid);end
    for eid in rf_get(raw,"member_element_ids",Any[]);add!(eids,eid);end
    for entry in vcat(rf_get(raw,"elements",Any[]),rf_get(raw,"bars",Any[]))
        add!(pids,rf_get(entry,"pid",nothing));add!(eids,rf_get(entry,"eid",nothing))
    end
    for station in rf_get(raw,"stations",Any[]),entry in vcat(rf_get(station,"parts",Any[]),rf_get(station,"force_terms",Any[]))
        add!(pids,rf_get(entry,"pid",nothing));add!(eids,rf_get(entry,"eid",nothing))
        for pid in rf_get(entry,"property_ids",Any[]);add!(pids,pid);end
    end
    elements=rf_get(input,"elements",Dict())
    for eid in eids
        group=rf_get(rf_get(elements,eid,nothing),"group",nothing);add!(pids,rf_get(group,"pid",nothing))
    end
    Dict{String,Any}("membership_pids"=>sort!(collect(pids)),"membership_eids"=>sort!(collect(eids)))
end
function rf_public_response(row;include_features=false)
    local_fields=Set(("feature_keys","feature_values","feature_gradient","capacity_keys","capacity_values","capacity_gradient"))
    rf_native_public_safe(Dict{String,Any}(k=>v for (k,v) in row if !startswith(k,"_")&&(include_features||!(k in local_fields))))
end
rf_native_public_safe(value::Real)=isfinite(value) ? value : nothing
rf_native_public_safe(value::AbstractDict)=Dict(string(k)=>rf_native_public_safe(v) for (k,v) in value)
rf_native_public_safe(value::Union{AbstractVector,Tuple})=rf_native_public_safe.(collect(value))
rf_native_public_safe(value)=value

function rf_vm_samples!(b,eid,property;pid=rf_get(property,"pid",0))
    record=rf_record(b.records,eid);stress=rf_get(record,"stress",nothing)
    stress===nothing&&throw(ArgumentError("Element $eid has no stress recovery"))
    if rf_get(property,"type","")=="PSHELL"
        samples=Any[]
        for surface in ("z1","z2")
            # Match the established two-face coverage contract. Recalculate VM
            # from primary stresses so nonlinear equivalent stress is never
            # mistaken for an affine displacement-recovery feature.
            vm=rf_path_get(stress,[surface,"von_mises"])
            rf_number(vm)&&vm>=0||throw(ArgumentError("Both shell-face von Mises samples are required"))
            ids=[rf_feature!(b,eid,"stress",[surface,k]) for k in ("normal_x","normal_y","shear_xy")]
            push!(samples,(;ids,value=rf_vm((b.feature_values[i] for i in ids)...),surface))
        end
        return samples
    end
    recovery=rf_get(stress,"von_mises_recovery",nothing)
    section=rf_get(property,"section",nothing)
    legacy_t=section!==nothing&&rf_get(section,"shape","")=="T"&&(
        (rf_get(recovery,"status","")=="complete"&&rf_get(recovery,"method","") in ("thin_walled_t_section_envelope","fixed_load_thin_walled_t_section_envelope"))||
        (rf_get(recovery,"status","")=="unavailable"&&occursin("thin-wall stress model requires",string(rf_get(recovery,"reason","")))))
    rf_get(recovery,"status","")=="unavailable"&&!legacy_t&&throw(ArgumentError(string(rf_get(recovery,"reason","Equivalent stress unavailable"))))
    if section!==nothing&&rf_get(section,"shape","") in ("T","BAR")
        shape=section["shape"];dims=section["dimensions_m"]
        shape=="T"&&(length(dims)!=4||!(dims[1]>dims[4]>0&&dims[2]>dims[3]>0))&&throw(ArgumentError("Native T equivalent stress requires positive nonoverlapping flange and web dimensions"))
        ids=[rf_feature!(b,eid,"forces",[key]) for key in ("axial","shear_1","shear_2","torque","moment_a1","moment_a2","moment_b1","moment_b2")]
        dids=[rf_capacity!(b,value,Dict("kind"=>"beam_dimension","pid"=>pid,"index"=>i)) for (i,value) in enumerate(dims)]
        j=shape=="T" ? rf_capacity!(b,section["J_m4"],Dict("kind"=>"beam_torsion_constant","pid"=>pid)) : nothing
        values=[b.feature_values[i] for i in ids];J=j===nothing ? 0. : b.capacity_values[j]
        equivalent=rf_beam_equivalent(shape,values,dims,J)
        expected=rf_get(stress,"von_mises",nothing)
        if legacy_t
            # A complete force field is sufficient to apply a changed nominal
            # recovery law. Do not silently replay the obsolete thin-wall VM
            # value, or upgrade distributed/tapered/missing-force records.
            bwidth,height,flange,web=dims;clear=height-flange
            area=bwidth*flange+clear*web;yc=(clear*web*clear/2+bwidth*flange*(clear+flange/2))/area
            i1=web*clear^3/12+clear*web*(yc-clear/2)^2+bwidth*flange^3/12+bwidth*flange*(clear+flange/2-yc)^2
            i2=clear*web^3/12+flange*bwidth^3/12
            all(rf_number(rf_get(section,key,nothing))&&isapprox(section[key],value;rtol=1e-8,atol=0.) for (key,value) in (("area_m2",area),("I1_m4",i1),("I2_m4",i2)))||
                throw(ArgumentError("Legacy T-section force recovery has inconsistent physical area or inertias; rerun the model"))
            recovery=Dict("status"=>"complete","method"=>"finite_thickness_t_nominal_envelope",
                "description"=>"Finite-thickness nominal T-section engineering envelope recomputed from complete solved beam resultants and consistent current section dimensions. Finite VQ/(I b) shear and compatible rectangular-limb Saint-Venant torsion; sharp-junction concentrations, restrained warping and transverse normal stresses excluded. The input records are retained unchanged.",
                "recovered_from_legacy_resultants"=>true)
        else
            rf_number(expected)&&isapprox(equivalent,expected;rtol=1e-8,atol=1e-10)||throw(ArgumentError("Native PBARL force/section equivalent recovery does not replay the solved value"))
        end
        return Any[(;ids,value=equivalent,surface="nominal section envelope",beam=true,shape,dimension_ids=dids,torsion_id=j,recovery)]
    end
    samples=Any[]
    function visit(value,path)
        if value isa AbstractVector
            for (i,item) in enumerate(value);visit(item,[path...;i]);end
            return
        end
        value isa AbstractDict||return
        for (key,item) in pairs(value)
            if string(key)=="von_mises"
                rf_number(item)&&item>=0||throw(ArgumentError("Invalid equivalent stress sample"))
                i=rf_feature!(b,eid,"stress",[path...;"von_mises"];nonlinear=true)
                push!(samples,(;ids=[i],value=Float64(item),surface=join(path,"/")))
            elseif item isa AbstractDict
                visit(item,[path...;string(key)])
            elseif item isa AbstractVector
                visit(item,[path...;string(key)])
            end
        end
    end
    visit(stress,String[]);isempty(samples)&&throw(ArgumentError("No recovered equivalent stress for element $eid"))
    samples
end
function rf_region_elements(input)
    regions=Dict{Int,Any}()
    for (id,element) in rf_entries(rf_get(input,"elements",Dict()))
        group=rf_get(element,"group",Dict());kind=string(rf_get(group,"kind",""))
        kind in ("quad","tria","shell","solid","bar")||continue
        rf_get(group,"name","")=="aero"&&continue
        pid=Int(rf_get(group,"pid",rf_get(rf_get(group,"properties",Dict()),"pid",0)));pid>0||continue
        eid=parse(Int,string(id));property=rf_get(group,"properties",Dict())
        push!(get!(regions,pid,Any[]),(;eid,property,group))
    end
    regions
end

rf_material_region_scope(key,pid)="material_region:$(key):P$(pid)"

"""Validate explicit material domains without changing their real property IDs.
Repeated identities, absent recovery geometry and wrong-PID members cannot be
silently trimmed into an apparently complete local strength assessment.
"""
function rf_material_region_specs(input,regions=rf_region_elements(input))
    raw=rf_get(input,"materialRegions",Any[])
    raw isa AbstractVector||throw(ArgumentError("Material regions must be an array"))
    specs=Any[];seen=Dict{String,Int}()
    for region in raw
        region isa AbstractDict||throw(ArgumentError("A material region must be an object"))
        key=rf_get(region,"key",nothing);pid=rf_get(region,"pid",nothing)
        key isa AbstractString&&!isempty(strip(key))||throw(ArgumentError("A material region needs a nonempty key"))
        pid isa Integer&&pid>0||throw(ArgumentError("A material region needs its actual positive property ID"))
        scope=rf_material_region_scope(key,pid);ids=rf_get(region,"member_element_ids",nothing)
        ids isa AbstractVector||throw(ArgumentError("Material region $key needs explicit element IDs"))
        all(id->id isa Integer&&id>0,ids)||throw(ArgumentError("Material region $key has an invalid element ID"))
        declared=Int.(ids);actual=Dict(e.eid=>e for e in get(regions,Int(pid),Any[]))
        reason=isempty(declared) ? "The physical material region has no elements" :
            length(unique(declared))!=length(declared) ? "The physical material region contains duplicate element IDs" :
            rf_get(region,"membership_complete",true)===false ? "The physical material region membership is incomplete" :
            any(id->!haskey(actual,id),declared) ? "A physical material member is missing or belongs to another property" : ""
        if haskey(seen,scope)
            old=specs[seen[scope]]
            specs[seen[scope]]=merge(old,(;reason="Duplicate physical material-region identity"))
            continue
        end
        push!(specs,(;key=String(key),pid=Int(pid),scope,raw=region,eids=declared,
            elements=Any[actual[id] for id in declared if haskey(actual,id)],reason))
        seen[scope]=length(specs)
    end
    specs
end

function rf_material_region_response(input,item,spec;derivatives=true)
    meta=Dict{String,Any}("membership_pids"=>[spec.pid],"membership_eids"=>spec.eids,
        "material_region_key"=>spec.key,"material_region_label"=>rf_get(spec.raw,"label",spec.key),
        "member_kind"=>rf_get(spec.raw,"member_kind","component"))
    if !isempty(spec.reason)
        mode=any(rf_get(e.property,"type","")=="PCOMP" for e in spec.elements) ? "principal_strain" : "von_mises"
        return rf_unavailable("$(spec.scope):$(item["case_key"])",mode,spec.scope,item["case_id"],spec.reason;metadata=meta)
    end
    merge!(rf_material_response(input,item,spec.pid,spec.elements;derivatives,scope_key=spec.key),meta)
end

function rf_material_response(input,item,pid,elements;derivatives=true,scope_key=nothing)
    case_id=item["case_id"];scope=scope_key===nothing ? "material:P$pid" : rf_material_region_scope(scope_key,pid);id="$scope:$(item["case_key"])"
    b=RFNativeInputs(case_id,rf_get(item["result"],"elementResults",rf_get(item["result"],"element_results",Dict())))
    properties=[e.property for e in elements];types=[rf_get(p,"type","") for p in properties]
    ids=sort!(unique(Int(rf_get(p,"material_id",rf_get(rf_get(p,"material",Dict()),"id",0))) for p in properties))
    mode=any(==("PCOMP"),types) ? "principal_strain" : "von_mises"
    try
        policy=rf_policy(input);allowables=rf_get(input,"allowables",Any[])
        if mode=="von_mises"
            length(ids)==1&&only(ids)>0||throw(ArgumentError("A single isotropic material is required"))
            all(rf_get(rf_get(p,"material",Dict()),"type","")=="MAT1" for p in properties)||throw(ArgumentError("Isotropic strength requires MAT1"))
            for p in properties
                mids=unique(Int.(vcat(rf_get(p,"material_ids",Any[]),collect(values(rf_get(p,"material_roles",Dict()))),[rf_get(p,"material_id",0)])))
                length(filter(>(0),mids))<=1||throw(ArgumentError("Different membrane/bending materials require a separate criterion"))
            end
            found=findall(a->rf_get(a,"material_id",0)==only(ids),allowables)
            lim=length(found)==1 ? allowables[only(found)] : Dict()
            limit_reason=length(found)!=1 ? "One material allowable definition is required" : rf_get(lim,"mode","")!="stress"||!rf_positive(rf_get(lim,"stress",nothing)) ? "Positive von Mises stress allowable required" : ""
            sample_groups=[rf_vm_samples!(b,e.eid,e.property;pid) for e in elements]
            peaks=[maximum(s.value for s in samples) for samples in sample_groups]
            method=string(rf_get(input,"method","maximum"));method=="max"&&(method="maximum")
            retained=collect(eachindex(peaks));cutoff=nothing;cutoff_ties=Int[];membership_discontinuous=false
            if method=="trimmed_mean"
                p=rf_get(input,"percentile",95.);0<p<=100||throw(ArgumentError("Percentile must lie in (0,100]"))
                sorted=sort(peaks);r=(length(sorted)-1)*p/100;lo=floor(Int,r)+1;hi=ceil(Int,r)+1
                cutoff=sorted[lo]*(1-(r-floor(r)))+sorted[hi]*(r-floor(r))
                retained=findall(v->v<=cutoff||v-cutoff<=16eps()*max(abs(v),abs(cutoff)),peaks)
                cutoff_ties=findall(v->abs(v-cutoff)<=16eps()*max(abs(v),abs(cutoff)),peaks)
                # Keeping every equal cutoff sample can change the retained
                # count when an arbitrarily small perturbation splits the tie.
                # The resulting mean may jump, so a frozen-member partial is
                # not a Clarke derivative of the recomputed envelope. Reject
                # interior boundary ties conservatively, including equal/no-
                # demand samples; percentile 100 and completed tie blocks are
                # unaffected because every tied sample stays below the cutoff.
                membership_discontinuous=length(cutoff_ties)>1&&length(retained)>lo
            elseif !(method in ("maximum","mean"))
                throw(ArgumentError("Unknown stress envelope method"))
            end
            if !isempty(limit_reason)
                peak=argmax(peaks);face=sample_groups[peak][argmax([s.value for s in sample_groups[peak]])].surface
                envelope=method=="maximum" ? peaks[peak] : sum(peaks[i] for i in retained)/length(retained)
                stats=Dict("maximum"=>peaks[peak],"envelope"=>envelope,"cutoff"=>cutoff,"retained"=>length(retained),"discarded"=>length(elements)-length(retained),"maxEid"=>elements[peak].eid,"maxFace"=>face,"allowable"=>nothing,"recovered"=>length(elements),"total"=>length(elements))
                return rf_unavailable(id,mode,scope,case_id,limit_reason;metadata=Dict("membership_pids"=>[pid],"membership_eids"=>[e.eid for e in elements],"stress_statistics"=>stats,"assessment_factor"=>policy.strength))
            end
            allow=rf_capacity!(b,lim["stress"],Dict("kind"=>"allowable_stress","material_id"=>only(ids)))
            nf=length(b.feature_values)
            sample_value=(x,s)->haskey(s,:beam) ? rf_beam_equivalent(s.shape,[x[i] for i in s.ids],[x[nf+i] for i in s.dimension_ids],s.torsion_id===nothing ? zero(first(x)) : x[nf+s.torsion_id]) : length(s.ids)==1 ? x[only(s.ids)] : rf_vm((x[i] for i in s.ids)...)
            kernel=x->begin
                values=[rf_active_max(sample_value(x,s) for s in samples) for samples in sample_groups]
                demand=method=="maximum" ? rf_active_max(values) : sum(values[i] for i in retained)/length(retained)
                policy.strength*demand/x[nf+allow]
            end
            meta=Dict{String,Any}("membership_pids"=>[pid],"membership_eids"=>[e.eid for e in elements],"envelope_method"=>method,"percentile_cutoff"=>cutoff,"retained_elements"=>[elements[i].eid for i in retained],"assessment_factor"=>policy.strength)
            peak=argmax(peaks);face=sample_groups[peak][argmax([s.value for s in sample_groups[peak]])].surface
            envelope=method=="maximum" ? peaks[peak] : sum(peaks[i] for i in retained)/length(retained)
            meta["stress_statistics"]=Dict("maximum"=>peaks[peak],"envelope"=>envelope,"cutoff"=>cutoff,"retained"=>length(retained),"discarded"=>length(elements)-length(retained),"maxEid"=>elements[peak].eid,"maxFace"=>face,"allowable"=>lim["stress"],"recovered"=>length(elements),"total"=>length(elements))
            methods=Dict{String,Any}()
            for (index,element) in enumerate(elements)
                samples=sample_groups[index]
                recovery=!isempty(samples)&&hasproperty(first(samples),:recovery) ? first(samples).recovery :
                    rf_get(rf_get(rf_record(b.records,element.eid),"stress",Dict()),"von_mises_recovery",nothing)
                rf_get(recovery,"status","")=="complete"||continue
                key=string(rf_get(recovery,"method",""));entry=get!(methods,key,Dict("method"=>key,"description"=>rf_get(recovery,"description",""),"count"=>0));entry["count"]+=1
            end
            meta["recovery_methods"]=collect(values(methods))
            meta["active_branch"]=Dict("element_id"=>elements[peak].eid,"face"=>face,"envelope_method"=>method,"retained_element_ids"=>[elements[i].eid for i in retained])
            method=="trimmed_mean"&&(meta["percentile_derivative_policy"]="Derivative of the explicitly frozen retained-element set; ordering/membership changes are nonsmooth")
            row=rf_response(b,id,mode,scope,kernel;derivatives,metadata=meta,source=(;kind=:material))
            if membership_discontinuous
                row["gradient_class"]="discontinuous_membership"
                row["percentile_membership_status"]="unstable_cutoff_tie"
                row["percentile_cutoff_tied_elements"]=[elements[i].eid for i in cutoff_ties]
                row["conditional_gradient_only"]=true
                row["reason"]="Splitting tied stresses at the percentile cutoff can change the retained count and make the mean discontinuous. The primal RF remains valid, but the frozen-membership partial is unavailable as an optimization gradient. Choose maximum/mean or a percentile outside this tied block."
                derivatives&&(row["derivative_status"]="unavailable")
                pop!(row,"_directional",nothing)
                pop!(row,"directional_status",nothing)
            end
            if any(key["nonlinear"] for key in b.feature_keys)
                # Imported sections/solids retain their actual solved
                # equivalent stresses. Do not discard valid primal RFs just
                # because this recovery needs a new exact nonlinear pullback.
                row["recovery_derivative_supported"]=false
                row["recovery_derivative_reason"]="This element's solved equivalent-stress recovery has no native exact primitive pullback; primal stresses and RFs remain valid"
                if derivatives
                    row["derivative_status"]="unavailable"
                    row["gradient_class"]="unsupported_nonlinear_recovery_pullback"
                end
            end
            return row
        end
        all(==("PCOMP"),types)||throw(ArgumentError("Mixed laminate/nonlaminate property region"))
        plies=rf_get(first(properties),"plies",Any[]);isempty(plies)&&throw(ArgumentError("No explicit laminate plies"))
        mid=Int(rf_get(first(plies),"material_id",0))
        all(rf_get(ply,"material_id",0)==mid&&rf_get(rf_get(ply,"material",Dict()),"type","")=="MAT8" for p in properties for ply in rf_get(p,"plies",Any[]))||throw(ArgumentError("Principal strains require a homogeneous MAT8 laminate"))
        found=findall(a->rf_get(a,"material_id",0)==mid,allowables);length(found)==1||throw(ArgumentError("One strain allowable is required"));lim=allowables[only(found)]
        rf_get(lim,"mode","")=="strain"&&all(rf_positive(rf_get(lim,k,nothing)) for k in ("strain_tension","strain_compression"))||throw(ArgumentError("Both principal-strain limits are required"))
        samples=Any[];sample_details=Any[]
        for e in elements
            rec=rf_get(rf_record(b.records,e.eid),"strain",Dict())
            rf_get(rec,"ply_faces_complete",false)===true&&rf_get(rec,"ply_faces_coordinate_system","")=="ply material 1/2 axes"||throw(ArgumentError("Complete laminate ply-face strain recovery is required"))
            faces=rf_get(rec,"ply_faces",Any[])
            for ply in eachindex(rf_get(e.property,"plies",Any[]))
                index=findfirst(p->Int(rf_get(p,"ply",0))==ply&&Int(rf_get(p,"material_id",0))==mid,faces)
                index===nothing&&throw(ArgumentError("Laminate ply recovery is missing"))
                for side in ("bottom","top")
                    push!(samples,[rf_feature!(b,e.eid,"strain",["ply_faces",index,side,k]) for k in ("e1","e2","g12")])
                    push!(sample_details,Dict("eid"=>e.eid,"ply"=>ply,"face"=>side,"material_id"=>mid))
                end
            end
        end
        t=rf_capacity!(b,lim["strain_tension"],Dict("kind"=>"allowable_strain_tension","material_id"=>mid))
        c=rf_capacity!(b,lim["strain_compression"],Dict("kind"=>"allowable_strain_compression","material_id"=>mid));nf=length(b.feature_values)
        kernel=x->policy.strength*rf_active_max(begin a,z=rf_principal((x[i] for i in s)...);rf_active_max((rf_active_max((zero(a),a))/x[nf+t],rf_active_max((zero(z),-z))/x[nf+c])) end for s in samples)
        candidates=[begin a,z=rf_principal((b.feature_values[i] for i in s)...);tu=max(0.,a)/lim["strain_tension"];cu=max(0.,-z)/lim["strain_compression"];tension=tu>=cu
            merge(sample_details[j],Dict("demand"=>tension ? max(0.,a) : min(0.,z),"allowable"=>lim[tension ? "strain_tension" : "strain_compression"],"utilization"=>policy.strength*max(tu,cu),"component"=>tension ? "Tensile principal strain" : "Compressive principal strain","principal_maximum"=>a,"principal_minimum"=>z))
        end for (j,s) in enumerate(samples)]
        peak=candidates[argmax([s["utilization"] for s in candidates])]
        rf_response(b,id,mode,scope,kernel;derivatives,metadata=Dict("membership_pids"=>[pid],"membership_eids"=>[e.eid for e in elements],"assessment_factor"=>policy.strength,"principal_strain"=>peak),source=(;kind=:material))
    catch err
        err isa InterruptException&&rethrow()
        rf_unavailable(id,mode,scope,case_id,sprint(showerror,err);metadata=Dict("membership_pids"=>[pid],"membership_eids"=>[e.eid for e in elements]))
    end
end

function rf_column_response(input,item,raw,mode;derivatives=true)
    scope="$mode:$(rf_get(raw,"key","unknown"))";id="$scope:$(item["case_key"])";case_id=item["case_id"]
    try
        isempty(string(rf_get(raw,"reason","")))||throw(ArgumentError(raw["reason"]))
        rf_get(raw,"membership_complete",true)!==false||throw(ArgumentError("Physical column membership is incomplete"))
        stations=rf_get(raw,"stations",Any[]);isempty(stations)&&throw(ArgumentError("No physical section cuts"))
        b=RFNativeInputs(case_id,rf_get(item["result"],"elementResults",rf_get(item["result"],"element_results",Dict())))
        station_terms=Any[];pids=Int[];eids=Int[]
        for station in stations
            terms=Any[];seen=Set{Int}()
            for term in rf_get(station,"force_terms",Any[])
                eid=Int(term["eid"]);push!(eids,eid)
                if term["kind"]=="beam_axial"
                    eid in seen&&throw(ArgumentError("Beam force is repeated at a section"));push!(seen,eid)
                    push!(terms,([rf_feature!(b,eid,"forces",["axial"])],[1.]))
                elseif term["kind"]=="shell_membrane"
                    coeff=rf_get(term,"coefficients",nothing);length(coeff)==3&&rf_positive(term["width_m"])||throw(ArgumentError("Invalid shell-column force projection"))
                    indices=[rf_feature!(b,eid,"forces",[k]) for k in ("fx","fy","fxy")]
                    push!(terms,(indices,Float64.(coeff).*term["width_m"]))
                else
                    throw(ArgumentError("Unsupported column force source"))
                end
            end
            isempty(terms)&&throw(ArgumentError("No force source for a column section"))
            push!(station_terms,terms)
        end
        part_layouts=Any[]
        for (si,station) in enumerate(stations)
            layouts=Any[]
            for (pi,part) in enumerate(station["parts"])
                haskey(part,"pid")&&push!(pids,Int(part["pid"]))
                if haskey(part,"property_ids");append!(pids,Int.(part["property_ids"]));end
                fields=haskey(part,"axial_matrix") ? ["matrix$i" for i in 1:9] : ["area_m2","centroid_y_m","centroid_z_m","iyy_m4","izz_m4","iyz_m4","young_pa"]
                values=haskey(part,"axial_matrix") ? rf_flat(part["axial_matrix"]) : [rf_get(part,k,0.) for k in fields]
                idx=[rf_capacity!(b,v,Dict("kind"=>"euler_part","station_index"=>si,"part_index"=>pi,"field"=>field,"pid"=>rf_get(part,"pid",0),"eid"=>rf_get(part,"eid",0))) for (field,v) in zip(fields,values)]
                push!(layouts,(;matrix=haskey(part,"axial_matrix"),fields,idx))
            end
            push!(part_layouts,layouts)
        end
        length_i=rf_capacity!(b,raw["length_m"],Dict("kind"=>"fixed_geometry","field"=>"length_m"));rf_positive(raw["length_m"])||throw(ArgumentError("Invalid column length"))
        fixities=rf_get(input,"componentFixities",Dict())
        c=mode=="euler_column" ? rf_get(input,"eulerFixityCoefficient",rf_get(input,"eulerEndFactor",rf_get(raw,"fixity_coefficient",1.))) : rf_get(fixities,mode,rf_get(raw,"fixity_coefficient",1.))
        rf_positive(c)||throw(ArgumentError("Invalid Euler fixity"));factor=rf_policy(input).buckling;nf=length(b.feature_values)
        kernel=x->begin
            ratios=typeof(first(x))[]
            for si in eachindex(stations)
                parts=Any[]
                for layout in part_layouts[si]
                    if layout.matrix;push!(parts,Dict("axial_matrix"=>[x[nf+i] for i in layout.idx]));else
                        push!(parts,Dict(field=>x[nf+i] for (field,i) in zip(layout.fields,layout.idx)))
                    end
                end
                K=rf_section_matrix(parts);ei=rf_weakest_ei(K)
                force=sum(sum(x[i]*v for (i,v) in zip(indices,weights)) for (indices,weights) in station_terms[si])
                push!(ratios,factor*rf_active_max((zero(force),-force))*x[nf+length_i]^2/(c*pi^2*ei))
            end
            rf_active_max(ratios)
        end
        samples=Any[]
        for (i,station) in enumerate(stations)
            K=rf_section_matrix(station["parts"]);ei=rf_weakest_ei(K)
            signed=sum(sum(b.feature_values[j]*weight for (j,weight) in zip(indices,weights)) for (indices,weights) in station_terms[i])
            compression=max(0.,-signed);critical=c*pi^2*ei/raw["length_m"]^2
            push!(samples,Dict("station"=>rf_get(station,"id",i),"stationIndex"=>i-1,"criticalLoad"=>critical,"compressionDemand"=>compression,"assessmentCompressionDemand"=>compression*factor,"signedForce"=>signed,"reserveFactor"=>compression>0 ? critical/compression/factor : nothing,"weakestEI"=>ei,"area"=>sum(rf_get(p,"area_m2",0.) for p in station["parts"]),"centroidY"=>K[1,2]/K[1,1],"centroidZ"=>K[1,3]/K[1,1]))
        end
        governing=filter(s->s["reserveFactor"]!==nothing,samples)
        selected=isempty(governing) ? samples[argmin([s["criticalLoad"] for s in samples])] : governing[argmin([s["reserveFactor"] for s in governing])]
        details=merge(copy(selected),Dict("stations"=>samples,"governingStation"=>isempty(governing) ? nothing : selected["station"],"length"=>raw["length_m"],"endFactor"=>c,"noCompression"=>isempty(governing),"stationCount"=>length(stations)))
        rf_response(b,id,mode,scope,kernel;derivatives,source=(;kind=:column,raw,stations),metadata=Dict("membership_pids"=>sort!(unique(pids)),"membership_eids"=>sort!(unique(eids)),"assessment_factor"=>factor,"fixity_coefficient"=>c,"details"=>details))
    catch err
        err isa InterruptException&&rethrow();rf_unavailable(id,mode,scope,case_id,sprint(showerror,err);metadata=rf_scope_membership(raw,input))
    end
end

function rf_blade_response(input,item,raw,mode;derivatives=true)
    scope="$mode:$(rf_get(raw,"key","unknown"))";id="$scope:$(item["case_key"])";case_id=item["case_id"]
    try
        isempty(string(rf_get(raw,"reason","")))||throw(ArgumentError(raw["reason"]))
        bars=rf_get(raw,"bars",Any[]);isempty(bars)&&throw(ArgumentError("No physical blade bars"))
        length(unique(Int(bar["eid"]) for bar in bars))==length(bars)||throw(ArgumentError("Duplicate blade bar"))
        b=RFNativeInputs(case_id,rf_get(item["result"],"elementResults",rf_get(item["result"],"element_results",Dict())))
        stress_ids=Any[];units=rf_get(item["result"],"stress_units","Pa")
        for bar in bars
            eid=Int(bar["eid"]);record=rf_record(b.records,eid);stress=rf_get(record,"stress",Dict())
            u=lowercase(string(rf_get(record,"stress_units",units)));scale=startswith(u,"gpa") ? 1e9 : startswith(u,"mpa") ? 1e6 : startswith(u,"kpa") ? 1e3 : startswith(u,"pa") ? 1. : throw(ArgumentError("Unrecognized bar stress units"))
            paths=haskey(stress,"axial_end_a")||haskey(stress,"axial_end_b") ? ["axial_end_a","axial_end_b"] : ["axial"]
            push!(stress_ids,([rf_feature!(b,eid,"stress",[k]) for k in paths],scale))
        end
        capacities=Any[]
        for (i,bar) in enumerate(bars)
            rf_get(bar,"material_type","MAT1")=="MAT1"||throw(ArgumentError("Blade equation requires MAT1"))
            fields=["young_pa","poisson","web_height_m","web_thickness_m"]
            vals=[bar[k] for k in fields];rf_positive(vals[1])&&-1<vals[2]<.5&&rf_positive(vals[3])&&rf_positive(vals[4])||throw(ArgumentError("Invalid blade material or geometry"))
            push!(capacities,[rf_capacity!(b,v,Dict("kind"=>"blade_field","bar_index"=>i,"pid"=>bar["pid"],"field"=>field)) for (field,v) in zip(fields,vals)])
        end
        nf=length(b.feature_values);factor=rf_policy(input).buckling
        kernel=x->begin
            mean=sum(sum(x[i] for i in ids)/length(ids)*scale for (ids,scale) in stress_ids)/length(stress_ids)
            critical=rf_active_min(rf_blade_capacity((x[nf+i] for i in ids)...) for ids in capacities)
            factor*rf_active_max((zero(mean),-mean))/critical
        end
        mean=sum(sum(b.feature_values[i] for i in ids)/length(ids)*scale for (ids,scale) in stress_ids)/length(stress_ids)
        criticals=[rf_blade_capacity((b.capacity_values[i] for i in ids)...) for ids in capacities];selected=argmin(criticals);bar=bars[selected]
        details=Dict("criticalStress"=>criticals[selected],"compressionDemand"=>max(0.,-mean),"averageStress"=>mean,"clearHeight"=>bar["web_height_m"],"thickness"=>bar["web_thickness_m"],"young"=>bar["young_pa"],"poisson"=>bar["poisson"],"coefficient"=>.425,"sourceCount"=>length(bars),"criticalEid"=>bar["eid"],"criticalPid"=>bar["pid"],"noCompression"=>mean>=0)
        rf_response(b,id,mode,scope,kernel;derivatives,source=(;kind=:blade,raw,bars),metadata=Dict("membership_pids"=>sort!(unique(Int(bar["pid"]) for bar in bars)),"membership_eids"=>Int[bar["eid"] for bar in bars],"assessment_factor"=>factor,"details"=>details))
    catch err
        err isa InterruptException&&rethrow();rf_unavailable(id,mode,scope,case_id,sprint(showerror,err);metadata=rf_scope_membership(raw,input))
    end
end

function rf_plate_response(input,item,raw,mode;derivatives=true,frozen_modes=nothing)
    scope="$mode:$(rf_get(raw,"key","unknown"))";id="$scope:$(item["case_key"])";case_id=item["case_id"]
    try
        isempty(string(rf_get(raw,"reason","")))||throw(ArgumentError(raw["reason"]))
        rf_get(raw,"membership_complete",true)!==false||throw(ArgumentError("Incomplete physical plate membership"))
        elements=rf_get(raw,"elements",Any[]);isempty(elements)&&throw(ArgumentError("No physical plate elements"))
        length(unique(Int(e["eid"]) for e in elements))==length(elements)||throw(ArgumentError("Duplicate plate ownership"))
        area=sum(e["area_m2"] for e in elements);rf_positive(area)||throw(ArgumentError("Invalid panel area"))
        b=RFNativeInputs(case_id,rf_get(item["result"],"elementResults",rf_get(item["result"],"element_results",Dict())))
        feature_ids=[[rf_feature!(b,e["eid"],"forces",[k]) for k in ("fx","fy","fxy")] for e in elements]
        D_indices=Any[]
        for (i,e) in enumerate(elements)
            rf_positive(e["area_m2"])&&rf_positive(e["thickness_m"])||throw(ArgumentError("Invalid physical plate thickness/area"))
            push!(D_indices,[rf_capacity!(b,v,Dict("kind"=>"plate_bending","element_index"=>i,"pid"=>e["pid"],"eid"=>e["eid"],"matrix_index"=>j)) for (j,v) in enumerate(rf_flat(e["bending_matrix_Nm"]))])
        end
        li=rf_capacity!(b,raw["length_m"],Dict("kind"=>"fixed_geometry","field"=>"length_m"));wi=rf_capacity!(b,raw["width_m"],Dict("kind"=>"fixed_geometry","field"=>"width_m"))
        nf=length(b.feature_values);spatial=mode!="skin_buckling";bounds=Any[]
        if spatial
            for e in elements
                vertices=e["normalized_vertices_uv"];length(vertices)==4||throw(ArgumentError("Web face needs four normalized vertices"))
                us=[p[1] for p in vertices];vs=[p[2] for p in vertices];u0,u1=extrema(us);v0,v1=extrema(vs)
                all(min(abs(u-u0),abs(u-u1))<=1e-10&&min(abs(v-v0),abs(v-v1))<=1e-10 for (u,v) in vertices)||throw(ArgumentError("Web face does not form a mapped rectangle"))
                push!(bounds,(max(0.,u0),min(1.,u1),max(0.,v0),min(1.,v1)))
            end
            rf_validate_tiling([(;bounds=v,N=[0.,0.,0.]) for v in bounds])
        end
        weights=[e["area_m2"]/area for e in elements];transforms=[rf_matrix(e["stress_transform"]) for e in elements]
        function matrices(x)
            D=[sum(weights[i]*x[nf+D_indices[i][j]] for i in eachindex(elements)) for j in 1:9]
            loads=[-(transforms[i]*[x[j] for j in feature_ids[i]]) for i in eachindex(elements)]
            N=[sum(weights[i]*loads[i][j] for i in eachindex(elements)) for j in 1:3]
            cells=spatial ? [(;bounds=bounds[i],N=loads[i]) for i in eachindex(elements)] : nothing
            (;L=x[nf+li],W=x[nf+wi],D,N,cells)
        end
        x=vcat(b.feature_values,b.capacity_values);a=matrices(x)
        pair=rf_solve_plate(a.L,a.W,a.D,a.N;cells=a.cells,options=rf_get(input,"plateOptions",Dict()),frozen_modes)
        c=mode=="skin_buckling" ? rf_get(input,"skinFixityCoefficient",rf_get(raw,"fixity_coefficient",1.)) : rf_get(rf_get(input,"componentFixities",Dict()),mode,rf_get(raw,"fixity_coefficient",1.))
        rf_positive(c)||throw(ArgumentError("Plate fixity must be positive"));factor=rf_policy(input).buckling
        resolved=isempty(pair.modes)||((pair.converged||pair.approximation)&&pair.mu>pair.resolution)
        kernel=if isempty(pair.modes)
            v->zero(first(v))
        else
            # q is the accepted physical eigenvector. Its derivative cancels
            # by stationarity, so this Rayleigh quotient has the exact local
            # derivative without AD through Cholesky/eigenvalue iterations.
            Q=hasproperty(pair,:cluster) ? copy(pair.cluster) : reshape(copy(pair.q),:,1);modes=pair.modes
            v->begin
                z=matrices(v);B,G=rf_plate_matrices(z.L,z.W,z.D,z.N,modes;cells=z.cells)
                factor/c*sum(dot(q,G*q)/dot(q,B*q) for q in eachcol(Q))/size(Q,2)
            end
        end
        assessed_history=[merge(h,Dict("reserveFactor"=>rf_get(h,"reserveFactor",nothing)===nothing ? nothing : h["reserveFactor"]*c/factor)) for h in pair.history]
        meta=Dict{String,Any}("membership_pids"=>sort!(unique(Int(e["pid"]) for e in elements)),"membership_eids"=>Int[e["eid"] for e in elements],
            "assessment_factor"=>factor,"fixity_coefficient"=>c,"basis_id"=>join(["$(m),$(n)" for (m,n) in pair.modes],";"),"selected_modes"=>[collect(mode) for mode in pair.modes],"basis_size"=>length(pair.modes),
            "converged"=>pair.converged,"approximation"=>pair.approximation,"eigenpair_residual"=>pair.residual,"eigenvalue_gap"=>pair.gap,"convergence_error"=>isfinite(pair.error) ? pair.error : nothing,"method"=>pair.method,"basis_history"=>assessed_history,
            "source_basis_m"=>hasproperty(pair,:sourceBasisM) ? pair.sourceBasisM : nothing,"source_basis_n"=>hasproperty(pair,:sourceBasisN) ? pair.sourceBasisN : nothing,
            "source_basis_size"=>hasproperty(pair,:sourceBasisM) ? pair.sourceBasisM*pair.sourceBasisN : nothing,
            "basis_stage"=>pair.approximation ? "truncated" : isempty(pair.history) ? "exact" : rf_get(last(pair.history),"stage","geometry"),
            "target_tolerance"=>rf_get(rf_get(input,"plateOptions",Dict()),"tolerance",.005),"mode_limit"=>rf_get(rf_get(input,"plateOptions",Dict()),"maxDimension",spatial ? 256 : 1024))
        average_stress=[sum(weights[i]*(transforms[i]*b.feature_values[feature_ids[i]])[j]/elements[i]["thickness_m"] for i in eachindex(elements)) for j in 1:3]
        meta["details"]=Dict("averageStressX"=>average_stress[1],"averageStressY"=>average_stress[2],"averageShear"=>average_stress[3],"membraneResultants"=>-a.N,"length"=>a.L,"width"=>a.W,"fixityCoefficient"=>c,"sourceCount"=>length(elements),"noDestabilizingLoad"=>isempty(pair.modes),"method"=>pair.method,"basisM"=>pair.basisM,"basisN"=>pair.basisN,"basisSize"=>length(pair.modes),"convergenceError"=>isfinite(pair.error) ? pair.error : nothing,"approximation"=>pair.approximation,"history"=>assessed_history,
            "modeM"=>startswith(pair.method,"Exact")&&!isempty(pair.modes) ? last(pair.modes)[1] : nothing,"modeN"=>startswith(pair.method,"Exact")&&!isempty(pair.modes) ? last(pair.modes)[2] : nothing)
        local_gradient=zeros(length(x))
        if derivatives&&resolved&&!isempty(pair.modes)
            Q=hasproperty(pair,:cluster) ? pair.cluster : reshape(pair.q,:,1);modes=pair.modes
            for q in eachcol(Q)
                den=rf_plate_bending_quadratic(a.L,a.W,a.D,modes,q);scale=factor/c/den/size(Q,2)
                dB=ForwardDiff.gradient(v->rf_plate_bending_quadratic(a.L,a.W,v,modes,q),a.D)
                for i in eachindex(elements)
                    dG=ForwardDiff.gradient(v->rf_plate_geometric_quadratic(a.L,a.W,v,modes,q;bounds=spatial ? bounds[i] : nothing),[0.,0.,0.])
                    weightsG=spatial ? 1. : weights[i]
                    local_gradient[feature_ids[i]].+=-scale*weightsG.*(transpose(transforms[i])*dG)
                    for j in 1:9;local_gradient[nf+D_indices[i][j]]+=-scale*pair.mu*weights[i]*dB[j];end
                end
                length_gradient=ForwardDiff.gradient(v->begin
                    num=spatial ? sum(rf_plate_geometric_quadratic(v[1],v[2],cell.N,modes,q;bounds=cell.bounds) for cell in a.cells) : rf_plate_geometric_quadratic(v[1],v[2],a.N,modes,q)
                    factor/c*num/rf_plate_bending_quadratic(v[1],v[2],a.D,modes,q)/size(Q,2)
                end,[a.L,a.W])
                local_gradient[nf+li]+=length_gradient[1];local_gradient[nf+wi]+=length_gradient[2]
            end
        end
        row=if resolved
            rf_response(b,id,mode,scope,kernel;derivatives,source=(;kind=:plate,raw,elements),metadata=meta,gradient=local_gradient)
        else
            # An indefinite membrane tensor can need shorter waves than the
            # retained basis resolves. Its largest retained Rayleigh quotient
            # may be negative: that is neither negative utilization nor proof
            # of zero demand. Keep the unresolved physical context for a
            # conservative bound, without passing that quotient to rf_response.
            merge(rf_unavailable(id,mode,scope,case_id,"The selected plate basis has no converged, numerically resolved positive critical root";metadata=meta),
                Dict("feature_keys"=>b.feature_keys,"feature_values"=>b.feature_values,
                    "capacity_keys"=>b.capacity_keys,"capacity_values"=>b.capacity_values,
                    "_capacity_source"=>(;kind=:plate,raw,elements),"_evaluate"=>kernel))
        end
        row["_plate_matrices"]=matrices
        row["membrane_recovery_complete"]=true
        if resolved
            row["utilization"]=factor/c*pair.mu
            row["raw_RF"]=row["utilization"]>0 ? inv(row["utilization"]) : nothing
        end
        if !resolved
            row["lower_bound_RF"]=rf_plate_lower_bound(a.L,a.W,a.D,a.N;cells=a.cells,factor,fixity=c)
            row["bound_method"]="Conservative bending/principal-membrane-load and rectangular Poincare bound; not a resolved eigenvalue"
        elseif isempty(pair.modes)
            row["utilization"]=0.;row["raw_RF"]=nothing;row["no_demand"]=true
        elseif pair.approximation
            row["derivative_status"]="approximate_fixed_basis";row["reason"]="Unconverged truncated Ritz approximation can overestimate capacity"
        elseif pair.mu>0&&hasproperty(pair,:cluster)&&size(pair.cluster,2)>1
            row["derivative_status"]="piecewise_smooth";row["reason"]="Repeated or near-repeated plate root: eigenspace-average Clarke subgradient; exact directional derivative is available separately"
        elseif pair.mu>0&&pair.gap<=1e-8max(abs(pair.mu),eps())
            row["derivative_status"]="piecewise_smooth";row["reason"]="Closely spaced simple plate root: ordinary derivative retained, with a small spectral gap"
        end
        if resolved&&!isempty(pair.modes)
            Q=hasproperty(pair,:cluster) ? pair.cluster : reshape(pair.q,:,1)
            row["cluster_size"]=size(Q,2);row["gradient_class"]=size(Q,2)>1 ? "clarke_eigenspace_average" : "ordinary_simple_eigenvalue"
            row["directional_available"]=true
            row["_directional"]=direction->begin
                length(direction)==length(x)||throw(ArgumentError("RF local directional vector has wrong length"))
                projected=ForwardDiff.jacobian(v->begin
                    z=matrices(x+only(v)*direction);B,G=rf_plate_matrices(z.L,z.W,z.D,z.N,pair.modes;cells=z.cells)
                    vec(transpose(Q)*(G-pair.mu*B)*Q)
                end,[0.])
                h=reshape(vec(projected),size(Q,2),size(Q,2))
                factor/c*eigmax(Symmetric((h+transpose(h))/2))
            end
        end
        row
    catch err
        err isa InterruptException&&rethrow();rf_unavailable(id,mode,scope,case_id,sprint(showerror,err);metadata=rf_scope_membership(raw,input))
    end
end

"""All declared physical criteria, once per case, with local utilization partials.
Production RFs and optimization share this native evaluator. `_` fields are
in-process derivative contexts and must be removed from JSON with
`rf_public_response`.
"""
function rf_assessment_values(input;derivatives=true,frozen_bases=Dict(),progress=(_)->nothing,cancelled=()->false)
    cases,excluded=rf_native_cases(input);responses=Any[];regions=rf_region_elements(input)
    material_regions=rf_material_region_specs(input,regions)
    wanted=Set(string.(rf_get(input,"response_ids",String[])))
    requested(id)=(isempty(wanted)&&!rf_get(input,"restrict_responses",false))||id in wanted
    last_progress=Ref(time())
    active_case=Ref{Any}(nothing)
    function record!(f,id)
        cancelled()&&throw(InterruptException())
        row=f();item=active_case[]
        item===nothing||merge!(row,Dict("case_key"=>item["case_key"],"case_label"=>item["label"],"solution"=>item["solution"],"nonlinear_demand_estimate"=>item["solution"]==106))
        push!(responses,row)
        if length(responses)%16==0||time()-last_progress[]>1.
            progress(Dict("phase"=>"native_rf_assessment","completed"=>length(responses),"detail"=>"Assessed $(length(responses)) physical RF/case responses; latest $id"))
            last_progress[]=time()
        end
    end
    for item in cases
        active_case[]=item
        for pid in sort!(collect(keys(regions)))
            requested("material:P$pid:$(item["case_key"])")||continue
            record!(() -> rf_material_response(input,item,pid,regions[pid];derivatives),"material:P$pid")
        end
        for spec in material_regions
            requested("$(spec.scope):$(item["case_key"])")||continue
            record!(() -> rf_material_region_response(input,item,spec;derivatives),spec.scope)
        end
        for raw in rf_get(input,"eulerColumns",Any[])
            requested("euler_column:$(rf_get(raw,"key","unknown")):$(item["case_key"])")||continue
            record!(() -> rf_column_response(input,item,raw,"euler_column";derivatives),"euler_column:$(rf_get(raw,"key","unknown"))")
        end
        for raw in rf_get(input,"stringerBlades",Any[])
            requested("stringer_blade:$(rf_get(raw,"key","unknown")):$(item["case_key"])")||continue
            rf_get(raw,"applicable",true)===false&&continue
            record!(() -> rf_blade_response(input,item,raw,"stringer_blade";derivatives),"stringer_blade:$(rf_get(raw,"key","unknown"))")
        end
        for raw in rf_get(input,"skinBucklingPanels",Any[])
            id="skin_buckling:$(rf_get(raw,"key","unknown")):$(item["case_key"])"
            requested(id)||continue
            record!(() -> rf_plate_response(input,item,raw,"skin_buckling";derivatives,frozen_modes=get(frozen_bases,id,nothing)),id)
        end
        components=rf_get(input,"componentBuckling",Dict())
        for raw in rf_get(components,"web_panels",Any[])
            rf_get(raw,"applicable",true)===false&&continue
            mode=rf_get(raw,"kind","")=="spar_web" ? "spar_web_buckling" : "rib_web_buckling";id="$mode:$(rf_get(raw,"key","unknown")):$(item["case_key"])"
            requested(id)||continue
            record!(() -> rf_plate_response(input,item,raw,mode;derivatives,frozen_modes=get(frozen_bases,id,nothing)),id)
        end
        for raw in rf_get(components,"columns",Any[])
            rf_get(raw,"applicable",true)===false&&continue
            mode=rf_get(raw,"kind","")=="spar_cap" ? "spar_cap_buckling" : "rib_stiffener_buckling"
            requested("$mode:$(rf_get(raw,"key","unknown")):$(item["case_key"])")||continue
            record!(() -> rf_column_response(input,item,raw,mode;derivatives),"$mode:$(rf_get(raw,"key","unknown"))")
        end
        for raw in rf_get(components,"blades",Any[])
            requested("rib_stiffener_blade:$(rf_get(raw,"key","unknown")):$(item["case_key"])")||continue
            rf_get(raw,"applicable",true)===false&&continue
            record!(() -> rf_blade_response(input,item,raw,"rib_stiffener_blade";derivatives),"rib_stiffener_blade:$(rf_get(raw,"key","unknown"))")
        end
    end
    ids=[r["response_id"] for r in responses];length(unique(ids))==length(ids)||throw(ArgumentError("Duplicate physical RF response IDs"))
    for id in setdiff(wanted,Set(ids))
        push!(responses,rf_unavailable(id,"unknown",id,nothing,"Requested physical response or eligible load case is unavailable"))
    end
    Dict{String,Any}("version"=>1,"responses"=>responses,"included_cases"=>[Dict(k=>v for (k,v) in c if k!="result") for c in cases],"excluded_cases"=>[Dict(k=>v for (k,v) in c if k!="result") for c in excluded],
        "complete"=>!isempty(cases)&&!any(rf_get(item,"relevant",true) for item in excluded)&&all(r["status"]=="ok" for r in responses),"assessment_policy"=>Dict("strengthSafetyFactor"=>rf_policy(input).strength,"bucklingPolicyFactor"=>rf_policy(input).buckling))
end

# Exact capacity/property chain. Geometry in the physical assessment is frozen;
# the section/ABD law is reevaluated with one Dual directional seed. No property
# perturbation, meshing, operator assembly or FE solve is performed here.
function rf_material_seed(material,direction,e)
    out=Dict{String,Any}(string(k)=>v for (k,v) in pairs(material))
    if rf_get(material,"type","")=="MAT1"
        out["E_Pa"]=material["E_Pa"]+e*rf_get(direction,"E",0.)
        out["nu"]=material["nu"]+e*rf_get(direction,"nu",0.)
    else
        for key in ("E1_Pa","E2_Pa","G12_Pa","nu12");out[key]=material[key]+zero(e);end
    end
    out
end
function rf_material_q(material)
    if material["type"]=="MAT1"
        E1=E2=material["E_Pa"];nu=material["nu"];G=E1/(2*(1+nu))
    else
        E1,E2,nu,G=(material[k] for k in ("E1_Pa","E2_Pa","nu12","G12_Pa"))
    end
    den=1-nu^2*E2/E1;z=zero(E1+E2+nu+G)
    [E1/den nu*E2/den z;nu*E2/den E2/den z;z z G]
end
function rf_section_seed(property,direction,e;offset_direction=0.)
    dt=rf_get(direction,"thickness",0.);t=property["thickness_m"]+e*dt
    materials=rf_get(direction,"materials",Dict())
    if property["type"]=="PSHELL"
        mid=Int(property["material_id"]);mat=rf_material_seed(property["material"],get(materials,mid,Dict()),e)
        plies=[Dict{String,Any}("material"=>mat,"thickness_m"=>t,"angle_deg"=>0.)]
        offset=rf_get(property,"shell_offset_m",0.)+e*offset_direction
    else
        dplies=rf_get(direction,"ply_thicknesses",zeros(length(property["plies"])))
        length(dplies)==length(property["plies"])||throw(ArgumentError("Laminate capacity direction has incomplete ply membership"))
        plies=[Dict{String,Any}("material"=>rf_material_seed(ply["material"],get(materials,Int(ply["material_id"]),Dict()),e),
            "thickness_m"=>ply["thickness_m"]+e*dplies[i],"angle_deg"=>rf_get(ply,"angle_deg",0.)) for (i,ply) in enumerate(property["plies"])]
        # The supplied property map may select an explicitly declared Clarke
        # average at a tied supporting-skin thickness. Preserve its complete
        # ply and reference-plane direction rather than reconstructing a
        # different active branch from the design variable.
        center_direction=haskey(direction,"z0") ? direction["z0"]+dt/2 : offset_direction
        offset=rf_get(property,"z0_m",-property["thickness_m"]/2)+property["thickness_m"]/2+e*center_direction
    end
    homogeneous=all(ply->ply["material"]["type"]=="MAT1"&&rf_primal(ply["material"]["E_Pa"])==rf_primal(first(plies)["material"]["E_Pa"])&&rf_primal(ply["material"]["nu"])==rf_primal(first(plies)["material"]["nu"]),plies)
    (;thickness=t,offset,plies,homogeneous_young=homogeneous ? first(plies)["material"]["E_Pa"] : nothing)
end
function rf_section_abd(section,angle)
    abd=zeros(typeof(section.thickness),6,6);level=section.offset-section.thickness/2
    for ply in section.plies
        top=level+ply["thickness_m"];theta=deg2rad(ply["angle_deg"])-angle;c,s=cos(theta),sin(theta)
        transform=[c*c s*s c*s;s*s c*c -c*s;-2c*s 2c*s c*c-s*s]
        q=transpose(transform)*rf_material_q(ply["material"])*transform
        abd[1:3,1:3].+=q.*(top-level);abd[1:3,4:6].+=q.*((top^2-level^2)/2)
        abd[4:6,1:3].+=q.*((top^2-level^2)/2);abd[4:6,4:6].+=q.*((top^3-level^3)/3);level=top
    end
    (abd+transpose(abd))/2
end
function rf_effective_bending(section,angle)
    abd=rf_section_abd(section,angle);A=abd[1:3,1:3];B=abd[1:3,4:6];D=abd[4:6,4:6]
    effective=D-transpose(B)*(A\B);(effective+transpose(effective))/2
end
function rf_axial_law(section,angle)
    if section.homogeneous_young!==nothing
        t,o=section.thickness,section.offset
        return section.homogeneous_young.*[t t*o;t*o t^3/12+t*o*o]
    end
    abd=rf_section_abd(section,angle);s=Diagonal([one(section.thickness),one(section.thickness),one(section.thickness),1/section.thickness,1/section.thickness,1/section.thickness])
    normalized=s*abd*s;retained=[1,4];free=[2,3,5,6]
    reduced=normalized[retained,retained]-normalized[retained,free]*(normalized[free,free]\normalized[free,retained])
    u=Diagonal([one(section.thickness),section.thickness]);reduced=u*reduced*u
    (reduced+transpose(reduced))/2
end
function rf_strip_energy(law,width,center,tangent,normal,projection;tangent_dyad=nothing)
    v=[1.,center...];t=[0.,tangent...];n=[0.,normal...];p=projection
    tt=tangent_dyad===nothing ? t*transpose(t) : [0. 0. 0.;0. tangent_dyad[1,1] tangent_dyad[1,2];0. tangent_dyad[2,1] tangent_dyad[2,2]]
    width*(p^3*law[1,1]*(v*transpose(v)+width^2/12*tt)+
        p^2*law[1,2]*(v*transpose(n)+n*transpose(v))+p*law[2,2]*(n*transpose(n)))
end
function rf_capacity_offset_direction(wing,property,variable)
    rf_get(property,"combined_flange",false)&&rf_get(wing.params,"stringers.shell_offsets",false)||return 0.
    -.5*sensitivity_owned_derivative(wing.params,property["pid"],variable,"stringer","flange_thickness","properties.stringer_flange_thickness")
end
function rf_group_element(wing,eid)
    for g in wing.groups
        index=findfirst(==(eid),g.eids);index===nothing||return g,index
    end
    throw(ArgumentError("Capacity source element $eid is absent from the current model"))
end
rf_vector_direction(f)=vec(ForwardDiff.jacobian(x->rf_flat(f(only(x))),[0.]))

function rf_euler_part_values(wing,part,station,property,direction,variable,e)
    group,index=rf_group_element(wing,Int(part["eid"]))
    if group.kind===:bar
        section=property["section"];dd=rf_get(direction,"dimensions",zeros(length(section["dimensions_m"])))
        dimensions=[v+e*d for (v,d) in zip(section["dimensions_m"],dd)]
        E=property["material"]["E_Pa"]+e*rf_get(direction,"E",0.)
        if haskey(part,"source_section")
            # Bare-member metadata is about the section centroid in the local
            # principal axes and deliberately credits no adjacent shell.
            sd=sensitivity_analytic_section(section,dd)
            A=sd.area+e*sd.darea;i1=sd.I1+e*sd.dI1;i2=sd.I2+e*sd.dI2;z=zero(E)
            return Dict{String,Any}("area_m2"=>A,"axial_matrix"=>[E*A z z;z E*i2 z;z z E*i1])
        end
        axis=Tuple(station["axis"]);y=Tuple(station["section_y"]);z=Tuple(station["section_z"])
        v=Tuple(group.orient[3index-2:3index]);local_y=unit3(v.-euler_dot(v,axis).*axis);local_z=cross3(axis,local_y)
        n=(euler_dot(local_y,y),euler_dot(local_y,z));t=(euler_dot(local_z,y),euler_dot(local_z,z))
        shape=section["shape"]
        width,height,level=if shape=="BAR"
            tw,h=dimensions;(tw,h,-h/2)
        elseif shape=="T"
            b,h,tf,tw=dimensions;part["part"]=="flange" ? (b,tf,-tf/2) : (tw,h-tf,-tf-(h-tf)/2)
        else
            throw(ArgumentError("Unsupported Euler beam section shape $shape"))
        end
        A=width*height
        return Dict{String,Any}("area_m2"=>A,"centroid_y_m"=>level*n[1],"centroid_z_m"=>level*n[2],
            "iyy_m4"=>A*(width^2*t[2]^2+height^2*n[2]^2)/12,
            "izz_m4"=>A*(width^2*t[1]^2+height^2*n[1]^2)/12,
            "iyz_m4"=>A*(width^2*t[1]*t[2]+height^2*n[1]*n[2])/12,"young_pa"=>E)
    end
    offset_direction=rf_capacity_offset_direction(wing,property,variable)
    section=rf_section_seed(property,direction,e;offset_direction)
    axis=Tuple(station["axis"]);y=Tuple(station["section_y"]);z=Tuple(station["section_z"])
    u,v,n=shell_material_frame(wing,group,index;path=stringer_path(wing.grid.wing,wing.params))
    ax=euler_dot(axis,u);ay=euler_dot(axis,v);projection=hypot(ax,ay)
    normal=(euler_dot(n,y)/projection,euler_dot(n,z)/projection)
    baseline_offset=rf_get(part,"offset_m",0.)
    center=(part["centroid_y_m"]-baseline_offset*normal[1]/projection,part["centroid_z_m"]-baseline_offset*normal[2]/projection)
    width=part["area_m2"]*projection/property["thickness_m"]
    # Retain the actual cut-segment dyad from its recorded rectangle moments.
    # cross(shell_normal,axis) would silently flatten a warped shell's actual
    # face intersection and differentiate a different section geometry.
    moment=[part["izz_m4"] part["iyz_m4"];part["iyz_m4"] part["iyy_m4"]]
    nn=[normal[1]^2 normal[1]*normal[2];normal[1]*normal[2] normal[2]^2]
    tangent_dyad=(12/part["area_m2"]*moment-(property["thickness_m"]/projection)^2*nn)/width^2
    law=rf_axial_law(section,atan(ay,ax));matrix=rf_strip_energy(law,width,center,(0.,0.),normal,projection;tangent_dyad)
    Dict{String,Any}("area_m2"=>width*section.thickness/projection,"axial_matrix"=>matrix)
end

"""Directional physical-capacity inputs per selected UI dimension.
The return vector is d(capacity_values)/dx in the row's exact key order.
Unrecognized active primitive mappings fail explicitly, never become zero.
"""
function rf_capacity_jvp(wing,response,variable;properties=model_property_definitions(wing),directions=nothing)
    isempty(response["capacity_keys"])&&return Float64[]
    bypid=properties isa AbstractDict ? properties : Dict(Int(p["pid"])=>p for p in properties)
    directions===nothing&&(directions=sensitivity_analytic_property_directions(wing,variable;properties=collect(values(bypid)),properties_by_pid=bypid))
    for direction in values(directions)
        isempty(string(rf_get(direction,"unsupported_reason","")))||throw(ArgumentError(direction["unsupported_reason"]))
    end
    source=rf_get(response,"_capacity_source",nothing);cache=Dict{Any,Any}();out=zeros(length(response["capacity_keys"]))
    for (index,key) in enumerate(response["capacity_keys"])
        kind=key["kind"];pid=Int(rf_get(key,"pid",0));direction=get(directions,pid,nothing)
        if kind in ("allowable_stress","allowable_strain_tension","allowable_strain_compression","fixed_geometry")
            continue
        elseif kind in ("beam_dimension","beam_torsion_constant")
            direction===nothing&&continue
            property=bypid[pid];section=property["section"];dd=rf_get(direction,"dimensions",zeros(length(section["dimensions_m"])))
            out[index]=kind=="beam_dimension" ? dd[Int(key["index"])] : get!(cache,(:beam_J,pid)) do
                sensitivity_analytic_section(section,dd).dJ
            end
        elseif kind=="blade_field"
            direction===nothing&&continue
            bar=source.bars[Int(key["bar_index"])];dims=bar["dimensions_m"];dd=rf_get(direction,"dimensions",zeros(length(dims)));field=key["field"]
            out[index]=field=="young_pa" ? rf_get(direction,"E",0.) : field=="poisson" ? rf_get(direction,"nu",0.) :
                field=="web_height_m" ? (bar["section_shape"]=="BAR" ? dd[2] : dd[2]-dd[3]) : field=="web_thickness_m" ? (bar["section_shape"]=="BAR" ? dd[1] : dd[4]) : throw(ArgumentError("Unknown blade capacity primitive $field"))
        elseif kind=="plate_bending"
            direction===nothing&&continue
            ei=Int(key["element_index"]);element=source.elements[ei]
            gradient=get!(cache,(:plate,pid,ei)) do
                T=rf_flat(element["stress_transform"]);angle=atan(T[3],T[1]-T[2])/2
                property=bypid[pid];offset_direction=rf_capacity_offset_direction(wing,property,variable)
                actual=rf_flat(element["bending_matrix_Nm"])
                replay=rf_flat(rf_effective_bending(rf_section_seed(property,direction,0.;offset_direction),angle))
                norm(actual-replay)<=1e-8max(norm(actual),1.)||throw(ArgumentError("Plate capacity law does not replay physical element $(element["eid"])"))
                rf_vector_direction(e->rf_effective_bending(rf_section_seed(property,direction,e;offset_direction),angle))
            end
            out[index]=gradient[Int(key["matrix_index"])]
        elseif kind=="euler_part"
            si,pi=Int(key["station_index"]),Int(key["part_index"]);part=source.stations[si]["parts"][pi]
            haskey(part,"pid")||throw(ArgumentError("Compacted Euler metadata has lost physical property ownership; request compact=false"))
            direction===nothing&&continue
            tangents=get!(cache,(:euler,si,pi)) do
                property=bypid[pid];station=source.stations[si]
                f=e->rf_euler_part_values(wing,part,station,property,direction,variable,e)
                baseline=f(0.)
                if haskey(part,"axial_matrix")
                    actual=rf_flat(part["axial_matrix"]);replay=rf_flat(baseline["axial_matrix"])
                    norm(actual-replay)<=1e-8max(norm(actual),1.)||throw(ArgumentError("Euler capacity law does not replay physical section $si/$pi"))
                    gradient=rf_vector_direction(e->f(e)["axial_matrix"])
                    Dict("matrix$i"=>gradient[i] for i in 1:9)
                else
                    fields=["area_m2","centroid_y_m","centroid_z_m","iyy_m4","izz_m4","iyz_m4","young_pa"]
                    all(isapprox(baseline[field],part[field];rtol=1e-8,atol=1e-14) for field in fields)||throw(ArgumentError("Euler beam rectangle does not replay physical section $si/$pi"))
                    Dict(field=>ForwardDiff.derivative(e->f(e)[field],0.) for field in fields)
                end
            end
            out[index]=tangents[key["field"]]
        else
            throw(ArgumentError("Unsupported capacity derivative primitive $kind"))
        end
    end
    out
end
