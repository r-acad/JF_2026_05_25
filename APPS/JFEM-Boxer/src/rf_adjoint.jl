# Multi-response RF derivatives of the actual constrained equilibrium.
# No perturbed decks, property steps or finite-difference fallbacks.
using LinearAlgebra
using SparseArrays

"""Build a checked static RF context and retain the actual residual Jacobian.
SOL106 uses its accepted full-load nonlinear residual, never a SOL101 surrogate.
"""
function rf_derivative_context(native,forward,wing;factorizations=Dict{String,Any}(),progress=(_)->nothing,cancelled=()->false)
    sol=Int(forward["sol_type"]);sol in (101,106)||throw(ArgumentError("RF derivatives require physical SOL101/SOL106 equilibrium"))
    sub=only(forward["subcases"])
    nonlinear=if sol==106
        objective=Dict{String,Any}("type"=>"displacement","node_id"=>first(wing.node_ids),"component"=>"x")
        sensitivity_nonlinear_context(native,forward,wing,objective;analytic=true,context_only=true,progress,cancelled)
    else
        nothing
    end
    op=nonlinear===nothing ? sensitivity_assemble(native,deepcopy(forward["model"]);solution=101,analytic=true) : nonlinear.op
    op.followers===nothing||throw(ArgumentError("RF derivatives require fixed-direction loads; follower-load stiffness and its design tangent are not enabled"))
    get(sub,"temp_load_id",nothing)===nothing||throw(ArgumentError("Thermal RF derivatives are unsupported"))
    op.id_map==sub["id_map"]&&op.X==sub["node_coords"]&&op.node_R==sub["node_R"]||error("RF derivative assembly changed native coordinate ordering")
    Set(op.fixed)==Set(sub["fixed_dofs"])||error("RF derivative automatic support partition differs from the accepted forward solution")
    stiffness_error=norm(op.K-sub["K"])/max(norm(sub["K"]),eps())
    stiffness_error<1e-11||error("RF assembly does not reproduce the accepted forward stiffness ($stiffness_error)")
    u=Float64.(sub["u_analysis"][op.free]);expanded=sensitivity_expand_state(op,op.free,u)
    state_error=norm(expanded-sub["u_analysis"])/max(norm(expanded),eps())
    state_error<1e-11||error("RF native constraint reconstruction mismatch ($state_error)")
    A=nonlinear===nothing ? op.A[op.free,op.free] : nonlinear.A
    b=op.F[op.free]
    residual=nonlinear===nothing ? norm(A*u-b)/max(norm(b),eps()) : nonlinear.diagnostics["forward_replay_residual"]
    residual<1e-6||error("RF forward replay residual is too large ($residual)")
    # Hash exact CSC arrays, partition and frames; load vectors may differ.
    buffer=IOBuffer();Serialization.serialize(buffer,(size(A),A.colptr,A.rowval,A.nzval,op.free,op.fixed,op.node_R,op.rbe3_map))
    signature=bytes2hex(SHA.sha256(take!(buffer)))
    factor=get!(factorizations,signature) do;lu(A);end
    groups=Dict{Int,Vector{Any}}()
    for group in wing.groups;push!(get!(groups,group.pid,Any[]),group);end
    properties=model_property_definitions(wing)
    (;op,wing,u,expanded,independent_state=sensitivity_independent_state(op,u),A,factor,signature,groups,properties,nonlinear,
        properties_by_pid=Dict(p["pid"]=>p for p in properties),recovery_cache=Dict{Any,Any}(),
        recovery_index=rf_build_recovery_index(native,op,wing),recovery_targets=Dict{Int,Any}(),
        design_cache=Dict{Any,Any}(),design_cache_order=Any[],design_cache_bytes=Ref(0),design_cache_limit=64*1024*1024,
        diagnostics=merge(Dict("forward_replay_residual"=>residual,"stiffness_replay_relative_error"=>stiffness_error,
            "constraint_replay_relative_error"=>state_error,"derivative_assembly"=>"analytic_chain_rule","solution"=>sol),
            nonlinear===nothing ? Dict{String,Any}() : nonlinear.diagnostics))
end

rf_response_case(row)=string(rfd_get(row,"case_id",1))
function rf_case_context(contexts,row)
    id=rf_response_case(row)
    get(contexts,id,get(contexts,tryparse(Int,id),nothing))===nothing&&throw(ArgumentError("No accepted equilibrium context for RF case $id"))
    get(contexts,id,get(contexts,tryparse(Int,id),nothing))
end

function rf_response_state_rhs(native,context,row)
    keys=rfd_get(row,"feature_keys",Any[]);coeff=rfd_get(row,"feature_gradient",Float64[])
    length(keys)==length(coeff)||throw(ArgumentError("RF feature/gradient lengths differ"))
    rf_prepare_recovery!(native,context,keys)
    values=rfd_get(row,"feature_values",nothing)
    if values!==nothing
        length(values)==length(keys)||throw(ArgumentError("RF feature value/descriptor lengths differ"))
        for (key,expected) in zip(keys,values)
            actual=rf_feature_influence(native,context,key).value
            isapprox(actual,expected;rtol=1e-8,atol=1e-10max(abs(expected),1e-12))||
                throw(ArgumentError("RF recovery feature does not match its accepted assessment: "*string(key)))
        end
    end
    gradient=zeros(context.op.ndof)
    for (key,weight) in zip(keys,coeff)
        string(rfd_get(key,"case_id",rfd_get(row,"case_id",1)))==rf_response_case(row)||throw(ArgumentError("RF row mixes different equilibrium cases"))
        rf_feature_state_gradient!(gradient,native,context,key,weight)
    end
    sensitivity_reduce_gradient(context.op,gradient)
end

function rf_accumulate!(destination,source::SparseVector,weight=1.)
    for (index,value) in zip(SparseArrays.nonzeroinds(source),nonzeros(source));destination[index]+=weight*value;end
    destination
end
rf_accumulate!(destination,source,weight=1.)=(destination .+= weight.*source)

"""Physical ownership index for explicit (fixed-state) response derivatives.
Equilibrium redistribution is deliberately not restricted by this locality.
"""
function rf_explicit_ownership(native,context,rows,indices)
    keys=Any[]
    for i in indices;append!(keys,rfd_get(rows[i],"feature_keys",Any[]));end
    rf_prepare_recovery!(native,context,keys)
    bypid=Dict{Int,Set{Int}}();global_rows=Set{Int}()
    for i in indices
        row=rows[i]
        for (key,weight) in zip(rfd_get(row,"feature_keys",Any[]),rfd_get(row,"feature_gradient",Float64[]))
            iszero(weight)&&continue
            feature=rf_feature_influence(native,context,key);pid=Int(feature.target.el["PID"])
            push!(get!(bypid,pid,Set{Int}()),i)
        end
        for (key,weight) in zip(rfd_get(row,"capacity_keys",Any[]),rfd_get(row,"capacity_gradient",Float64[]))
            iszero(weight)&&continue
            kind=String(rfd_get(key,"kind",""))
            kind in ("allowable_stress","allowable_strain_tension","allowable_strain_compression","fixed_geometry")&&continue
            pid=Int(rfd_get(key,"pid",0))
            pid>0 ? push!(get!(bypid,pid,Set{Int}()),i) : push!(global_rows,i)
        end
    end
    (;bypid,global_rows)
end

function rf_explicit_candidates(ownership,directions)
    candidates=copy(ownership.global_rows)
    for pid in keys(directions);union!(candidates,get(ownership.bypid,pid,Set{Int}()));end
    candidates
end

function rf_response_state_direction(native,context,row,physical_direction)
    descriptors=rfd_get(row,"feature_keys",Any[]);coefficients=rfd_get(row,"feature_gradient",Float64[])
    length(descriptors)==length(coefficients)||throw(ArgumentError("RF feature/gradient lengths differ"))
    expected=rfd_get(row,"feature_values",nothing);value=0.
    for (k,(key,coefficient)) in enumerate(zip(descriptors,coefficients))
        q=rf_feature_influence(native,context,key)
        expected===nothing||isapprox(q.value,expected[k];rtol=1e-8,atol=1e-10max(abs(expected[k]),1e-12))||
            throw(ArgumentError("RF feature does not replay the accepted assessment"))
        value+=coefficient*dot(q.influence,physical_direction[q.dofs])
    end
    value
end

"""Exact dR/dx_j and physical property directions; no dense design tensor."""
function rf_residual_design_column(native,context,variable;cancelled=()->false)
    buffer=IOBuffer();Serialization.serialize(buffer,variable);token=bytes2hex(SHA.sha256(take!(buffer)))
    haskey(context.design_cache,token)&&return context.design_cache[token].column
    directions=sensitivity_analytic_property_directions(context.wing,variable;properties=context.properties,properties_by_pid=context.properties_by_pid)
    isempty(directions)&&throw(ArgumentError("The selected dimension has no active analytic fixed-geometry property map; a geometry derivative or an active section field is required"))
    force=zeros(context.op.ndof);mass=0.;max_replay=0.
    for (pid,direction) in directions
        isempty(get(direction,"unsupported_reason",""))||throw(ArgumentError(direction["unsupported_reason"]))
        for group in get(context.groups,pid,Any[]),e in 1:n_elements(group)
            cancelled()&&throw(InterruptException())
            if group.kind===:bar
                local_data=sensitivity_analytic_bar(native,context.op,context.wing,group,e,direction,context.expanded)
                get!(direction,"_rf_bar_data",Dict{Int,Any}())[group.eids[e]]=local_data
                direction["area"]=local_data.section.darea;direction["density"]=direction["rho"];direction["offset_y"]=local_data.section.doffset_y
                if get(context.wing.params,"mass.structural_representation","distributed")=="bay_concentrated"
                    points=element_points(context.wing,group,e);L=norm3(points[2].-points[1])
                    rho=bar_material_definition(context.wing.params,pid)["rho"]
                    mass+=L*(rho*local_data.section.darea+local_data.section.area*get(direction,"rho",0.))
                else
                    mass+=local_data.dmass
                end
                max_replay=max(max_replay,local_data.stiffness_replay_relative_error)
            else
                local_data=native.Solver.analytic_shell_tangent(context.op.shell_capture.contexts[group.eids[e]],direction)
                max_replay=max(max_replay,local_data.replay_error)
                points=element_points(context.wing,group,e)
                area=group.kind===:tria ? norm3(cross3(points[2].-points[1],points[3].-points[1]))/2 :
                    sum(quad_body_shape_weights(points,unit3(cross3(points[3].-points[1],points[4].-points[2]))))
                mass+=area*get(direction,"areal_mass",0.)
            end
            force[local_data.dofs].+=local_data.dKe*context.expanded[local_data.dofs]
            nonlinear=rfd_get(context,"nonlinear",nothing)
            if nonlinear!==nothing&&!iszero(nonlinear.coefficient)
                dg=if group.kind===:bar
                    local_data.dKg
                else
                    jet=sensitivity_geometric_shell_replay(native,nonlinear.geometric_contexts[group.eids[e]],direction,
                        native.Solver.ForwardDiff.Dual(0.,1.))
                    map(value->native.Solver.ForwardDiff.partials(value)[1],jet)
                end
                force[local_data.dofs].+=nonlinear.coefficient.*(dg*context.expanded[local_data.dofs])
            end
        end
    end
    loads=sensitivity_analytic_load_tangent(context.wing,directions)
    df=sensitivity_analytic_reduce_load(native,context.op,loads)
    residual=sparse(sensitivity_reduce_gradient(context.op,force).-df[context.op.free])
    mapping_nonsmooth=any(get(d,"property_mapping_nonsmooth",false) for d in values(directions))
    column=(;residual,directions,mass_derivative=mass,max_replay,load_diagnostics=loads.diagnostics,
        property_mapping_nonsmooth=mapping_nonsmooth,
        property_mapping_class=mapping_nonsmooth ? "uniform_clarke_thinnest_skin" : "ordinary")
    bytes=Base.summarysize(column)
    while !isempty(context.design_cache_order)&&context.design_cache_bytes[]+bytes>context.design_cache_limit
        previous=popfirst!(context.design_cache_order);old=pop!(context.design_cache,previous)
        context.design_cache_bytes[]-=old.bytes
    end
    if bytes<=context.design_cache_limit
        context.design_cache[token]=(;column,bytes);push!(context.design_cache_order,token);context.design_cache_bytes[]+=bytes
    end
    column
end

function rf_response_explicit(native,context,row,variable,directions;capacity_jvp=nothing,capacity_row_jvp=nothing)
    keys=rfd_get(row,"feature_keys",Any[]);gradient=rfd_get(row,"feature_gradient",Float64[])
    explicit=sum(weight*rf_feature_property_jvp(native,context,key,directions) for (key,weight) in zip(keys,gradient) if !iszero(weight);init=0.)
    explicit+rf_response_capacity_explicit(context,row,variable,directions;capacity_jvp,capacity_row_jvp)
end

function rf_response_capacity_explicit(context,row,variable,directions;capacity_jvp=nothing,capacity_row_jvp=nothing)
    explicit=0.
    all(iszero,rfd_get(row,"capacity_gradient",Float64[]))&&return explicit
    if capacity_row_jvp!==nothing
        values=capacity_row_jvp(context,row,variable,directions)
        coefficients=rfd_get(row,"capacity_gradient",Float64[])
        length(values)==length(coefficients)||throw(ArgumentError("RF capacity row derivative length mismatch"))
        return explicit+dot(coefficients,values)
    end
    capacities=rfd_get(row,"capacity_keys",Any[]);weights=rfd_get(row,"capacity_gradient",Float64[])
    length(capacities)==length(weights)||throw(ArgumentError("RF capacity/gradient lengths differ"))
    for (key,weight) in zip(capacities,weights)
        iszero(weight)&&continue
        capacity_jvp===nothing&&throw(ArgumentError("An exact native capacity derivative is required for $(rfd_get(key,"quantity",key))"))
        explicit+=weight*capacity_jvp(context,key,variable,directions)
    end
    explicit
end

function rf_derivative_row_status(row)
    status=String(rfd_get(row,"derivative_status",rfd_get(row,"status","ok")))
    status in ("ok","complete","analytic_local","no_demand","directional_zero_demand","approximate_fixed_basis","approximate","piecewise_smooth") ? status : "unavailable"
end

"""Blocked physical-response Jacobian. Matrices use utilization unless requested.

Each valid block reuses the checked case factorization; unavailable cells carry
NaN and a reason, never fabricated zeros. `block_sink` can stream matrix blocks.
"""
function rf_response_jacobian(native,contexts,responses,variables;capacity_jvp=nothing,capacity_row_jvp=nothing,measure="utilization",block_size=32,
        cancelled=()->false,progress=(_)->nothing,block_sink=nothing,retain_matrix=true)
    measure in ("utilization","reserve_factor")||throw(ArgumentError("RF derivative measure must be utilization or reserve_factor"))
    block_size>0||throw(ArgumentError("RF derivative block size must be positive"))
    M=length(responses);N=length(variables);J=retain_matrix ? fill(NaN,M,N) : nothing
    reasons=Dict{String,Any}();solves=0;complete=true;mapping_classes=Dict{String,String}()
    for start in 1:block_size:M
        stop=min(M,start+block_size-1);cancelled()&&throw(InterruptException())
        block=fill(NaN,stop-start+1,N);grouped=Dict{String,Vector{Int}}()
        for i in start:stop
            status=rf_derivative_row_status(responses[i])
            if status=="unavailable";reasons[string(i)]=rfd_get(responses[i],"reason","Response derivative unavailable");continue;end
            push!(get!(grouped,rf_response_case(responses[i]),Int[]),i)
        end
        for (_,indices) in grouped
            context=rf_case_context(contexts,responses[first(indices)]);good=Int[];rhs=Vector{Float64}[]
            for i in indices
                try;push!(rhs,rf_response_state_rhs(native,context,responses[i]));push!(good,i)
                catch failure;reasons[string(i)]=sprint(showerror,failure);end
            end
            isempty(good)&&continue
            B=hcat(rhs...);lambda=adjoint(context.factor)\B;solves+=length(good)
            residual=norm(transpose(context.A)*lambda-B)/max(norm(B),eps())
            residual<1e-8||error("RF adjoint block failed residual verification ($residual)")
            for (j,variable) in enumerate(variables)
                cancelled()&&throw(InterruptException())
                column=try rf_residual_design_column(native,context,variable;cancelled) catch failure
                    for i in good;reasons["$i:$j"]=sprint(showerror,failure);end;nothing
                end
                column===nothing&&continue
                mapping_classes[string(j)]=rfd_get(column,"property_mapping_class","ordinary")
                for (k,i) in enumerate(good)
                    try
                        value=rf_response_explicit(native,context,responses[i],variable,column.directions;capacity_jvp,capacity_row_jvp)-dot(view(lambda,:,k),column.residual)
                        if measure=="reserve_factor"
                            u=Float64(rfd_get(responses[i],"utilization",NaN))
                            u>0||throw(ArgumentError("No finite RF derivative at zero demand; use utilization"))
                            value=-value/u^2
                        end
                        block[i-start+1,j]=value
                    catch failure;reasons["$i:$j"]=sprint(showerror,failure);end
                end
            end
        end
        complete&=all(isfinite,block)
        retain_matrix&&(J[start:stop,:].=block)
        block_sink===nothing||block_sink(start,stop,block)
        progress(Dict("phase"=>"rf_derivatives","completed"=>stop,"total"=>M,"adjoint_rhs"=>solves))
    end
    Dict{String,Any}("jacobian"=>J,"measure"=>measure,"rows"=>responses,"variables"=>variables,
        "reasons"=>reasons,"complete"=>complete,"shape"=>[M,N],"retained_matrix"=>retain_matrix,
        "property_mapping_class"=>mapping_classes,
        "adjoint_rhs"=>solves,"factorizations"=>length(unique(context.signature for context in values(contexts))),
        "method"=>"analytic_equilibrium_adjoint","perturbed_forward_solves"=>0)
end

"""J*v with one tangent RHS per case and exact local explicit chains."""
function rf_jvp(native,contexts,responses,variables,direction;capacity_jvp=nothing,capacity_row_jvp=nothing,cancelled=()->false)
    length(variables)==length(direction)||throw(ArgumentError("RF design direction has wrong length"))
    result=fill(NaN,length(responses));reasons=Dict{String,Any}()
    for id in unique(rf_response_case(row) for row in responses)
        indices=findall(row->rf_response_case(row)==id,responses);context=rf_case_context(contexts,responses[first(indices)])
        residual=zeros(length(context.u));explicit=zeros(length(indices))
        valid=[rf_derivative_row_status(responses[i])!="unavailable" for i in indices]
        for (k,i) in enumerate(indices)
            valid[k]||(reasons[string(i)]=rfd_get(responses[i],"reason","Response derivative unavailable"))
        end
        position=Dict(i=>k for (k,i) in enumerate(indices))
        ownership=rf_explicit_ownership(native,context,responses,[i for (k,i) in enumerate(indices) if valid[k]])
        for (variable,weight) in zip(variables,direction)
            iszero(weight)&&continue;cancelled()&&throw(InterruptException())
            column=rf_residual_design_column(native,context,variable;cancelled);rf_accumulate!(residual,column.residual,weight)
            for i in rf_explicit_candidates(ownership,column.directions)
                k=position[i];valid[k]||continue
                try;explicit[k]+=weight*rf_response_explicit(native,context,responses[i],variable,column.directions;capacity_jvp,capacity_row_jvp)
                catch failure;valid[k]=false;reasons[string(i)]=sprint(showerror,failure);end
            end
        end
        tangent=-(context.factor\residual)
        physical_direction=sensitivity_expand_state(context.op,context.op.free,tangent)
        for (k,i) in enumerate(indices)
            valid[k]||continue
            try;result[i]=rf_response_state_direction(native,context,responses[i],physical_direction)+explicit[k]
            catch failure;reasons[string(i)]=sprint(showerror,failure);end
        end
    end
    (;values=result,reasons,method="analytic_equilibrium_tangent")
end

"""J^T*w with one weighted adjoint RHS per participating case."""
function rf_vjp(native,contexts,responses,variables,weights;capacity_jvp=nothing,capacity_row_jvp=nothing,cancelled=()->false)
    length(responses)==length(weights)||throw(ArgumentError("RF response weights have wrong length"))
    gradient=zeros(length(variables));solves=0
    for id in unique(rf_response_case(row) for row in responses)
        indices=findall(i->rf_response_case(responses[i])==id&&!iszero(weights[i]),eachindex(responses));isempty(indices)&&continue
        context=rf_case_context(contexts,responses[first(indices)])
        ownership=rf_explicit_ownership(native,context,responses,indices)
        combined=Dict{Any,Tuple{Any,Float64}}()
        for i in indices
            rf_derivative_row_status(responses[i])=="unavailable"&&throw(ArgumentError("Weighted RF response $i is unassessed"))
            row=responses[i];keys=rfd_get(row,"feature_keys",Any[]);coeff=rfd_get(row,"feature_gradient",Float64[])
            length(keys)==length(coeff)||throw(ArgumentError("RF feature/gradient lengths differ"))
            expected=rfd_get(row,"feature_values",nothing)
            for (k,(key,partial)) in enumerate(zip(keys,coeff))
                if expected!==nothing
                    q=rf_feature_influence(native,context,key).value
                    isapprox(q,expected[k];rtol=1e-8,atol=1e-10max(abs(expected[k]),1e-12))||throw(ArgumentError("Weighted RF feature does not replay its accepted assessment"))
                end
                token=rf_feature_token(key);old=get(combined,token,(key,0.))
                combined[token]=(key,old[2]+weights[i]*partial)
            end
        end
        physical=zeros(context.op.ndof);features_by_pid=Dict{Int,Vector{Any}}()
        for (key,partial) in values(combined)
            iszero(partial)&&continue
            rf_feature_state_gradient!(physical,native,context,key,partial)
            pid=Int(rf_feature_influence(native,context,key).target.el["PID"])
            push!(get!(features_by_pid,pid,Any[]),(key,partial))
        end
        rhs=sensitivity_reduce_gradient(context.op,physical)
        lambda=adjoint(context.factor)\rhs;solves+=1
        norm(transpose(context.A)*lambda-rhs)/max(norm(rhs),eps())<1e-8||error("RF weighted adjoint residual failed")
        for (j,variable) in enumerate(variables)
            cancelled()&&throw(InterruptException());column=rf_residual_design_column(native,context,variable;cancelled)
            explicit=0.
            for pid in Base.keys(column.directions),(key,partial) in get(features_by_pid,pid,Any[])
                explicit+=partial*rf_feature_property_jvp(native,context,key,column.directions)
            end
            for i in rf_explicit_candidates(ownership,column.directions)
                explicit+=weights[i]*rf_response_capacity_explicit(context,responses[i],variable,column.directions;capacity_jvp,capacity_row_jvp)
            end
            gradient[j]+=explicit-dot(lambda,column.residual)
        end
    end
    (;values=gradient,adjoint_rhs=solves,method="analytic_equilibrium_weighted_adjoint")
end

"""Response derivative along a design direction, including a clustered pencil.

Jv/J^T w above are linear products of the explicitly selected gradient (or
Clarke subgradient). At an eigenvalue crossing the true directional derivative
is not a linear map; an explicit local hook evaluates the projected pencil.
Other nonsmooth rows retain their declared selected generalized-gradient
product, identified in `derivative_class`; it is not silently called an exact
one-sided derivative.
"""
function rf_directional(native,contexts,responses,variables,direction;capacity_jvp=nothing,capacity_row_jvp=nothing,
        measure="utilization",cancelled=()->false)
    length(variables)==length(direction)||throw(ArgumentError("RF design direction has wrong length"))
    measure in ("utilization","reserve_factor")||throw(ArgumentError("Invalid RF derivative measure"))
    values=fill(NaN,length(responses));reasons=Dict{String,Any}();used_hook=falses(length(responses));pencil=falses(length(responses));classes=fill("unavailable",length(responses))
    for id in unique(rf_response_case(row) for row in responses)
        indices=findall(row->rf_response_case(row)==id,responses);context=rf_case_context(contexts,responses[first(indices)])
        residual=zeros(length(context.u));columns=Dict{Int,Any}()
        for (j,variable) in enumerate(variables)
            iszero(direction[j])&&continue;cancelled()&&throw(InterruptException())
            column=rf_residual_design_column(native,context,variable;cancelled)
            columns[j]=column;rf_accumulate!(residual,column.residual,direction[j])
        end
        tangent=-(context.factor\residual)
        full_tangent=sensitivity_expand_state(context.op,context.op.free,tangent)
        for i in indices
            cancelled()&&throw(InterruptException());row=responses[i]
            try
                rf_derivative_row_status(row)!="unavailable"||throw(ArgumentError(rfd_get(row,"reason","Response derivative unavailable")))
                keys=rfd_get(row,"feature_keys",Any[]);rf_prepare_recovery!(native,context,keys)
                dq=[begin q=rf_feature_influence(native,context,key);dot(q.influence,full_tangent[q.dofs]) end for key in keys]
                dc=zeros(length(rfd_get(row,"capacity_keys",Any[])))
                for (j,column) in columns
                    variable=variables[j];weight=direction[j]
                    for (k,key) in enumerate(keys)
                        dq[k]+=weight*rf_feature_property_jvp(native,context,key,column.directions)
                    end
                    if !isempty(dc)
                        if capacity_row_jvp!==nothing
                            dc .+= weight.*capacity_row_jvp(context,row,variable,column.directions)
                        elseif capacity_jvp!==nothing
                            dc .+= weight.*[capacity_jvp(context,key,variable,column.directions) for key in row["capacity_keys"]]
                        else
                            throw(ArgumentError("Exact capacity derivative is required for RF directional evaluation"))
                        end
                    end
                end
                hook=rfd_get(row,"_directional",nothing)
                mapping_nonsmooth=any(rfd_get(column,"property_mapping_nonsmooth",false) for column in Base.values(columns))
                value=if hook===nothing
                    classes[i]=mapping_nonsmooth ? "selected_property_clarke_product" : String(rfd_get(row,"gradient_class","selected_gradient_product"))
                    dot(rfd_get(row,"feature_gradient",Float64[]),dq)+dot(rfd_get(row,"capacity_gradient",Float64[]),dc)
                else
                    used_hook[i]=true
                    pencil[i]=Int(rfd_get(row,"cluster_size",0))>0||String(rfd_get(row,"gradient_class",""))=="clarke_eigenspace_average"
                    classes[i]=mapping_nonsmooth ? (pencil[i] ? "selected_property_clarke_with_projected_pencil" : "selected_property_clarke_with_local_directional") :
                        String(rfd_get(row,"directional_status",pencil[i] ? "exact_projected_pencil" : "exact_local_directional"))
                    hook(vcat(dq,dc))
                end
                if measure=="reserve_factor"
                    u=Float64(rfd_get(row,"utilization",NaN));u>0||throw(ArgumentError("No finite RF directional derivative at zero demand; use utilization"))
                    value=-value/u^2
                end
                values[i]=value
            catch failure
                reasons[string(i)]=sprint(showerror,failure)
            end
        end
    end
    (;values,reasons,measure,projected_pencil=pencil,local_directional_hook=used_hook,derivative_class=classes,method="analytic_equilibrium_directional")
end
