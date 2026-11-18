# Native RF recovery is affine only in primitive forces/stresses/strains.
# Derived maxima, equivalent stresses and eigenvalues belong to RF kernels.
using LinearAlgebra

rfd_get(d,k,default=nothing)=d isa AbstractDict ? get(d,k,get(d,Symbol(k),default)) : hasproperty(d,Symbol(k)) ? getproperty(d,Symbol(k)) : default

function rf_path_value(value,path)
    for key in path
        value=value isa AbstractVector ? value[Int(key)] : rfd_get(value,string(key),nothing)
        value===nothing&&throw(ArgumentError("RF recovery path $(join(string.(path),'.')) is unavailable"))
    end
    value isa Real&&isfinite(value)||throw(ArgumentError("RF recovery feature is not a finite scalar"))
    Float64(value)
end

function rf_feature_descriptor(key)
    quantity=String(rfd_get(key,"quantity","stress"))
    quantity=get(Dict("stresses"=>"stress","strains"=>"strain","forces"=>"force"),quantity,quantity)
    quantity in ("stress","strain","force")||throw(ArgumentError("Unsupported RF recovered quantity $quantity"))
    path=collect(rfd_get(key,"path",Any[]))
    isempty(path)&&throw(ArgumentError("An RF feature requires a primitive recovery path"))
    any(x->String(string(x)) in ("von_mises","major","minor","reserve_factor","utilization"),path)&&
        throw(ArgumentError("RF primitive recovery cannot affine-linearize a nonlinear equivalent/principal quantity; use its component kernel"))
    (case_id=rfd_get(key,"case_id",1),eid=Int(rfd_get(key,"eid",0)),quantity,path,
        native_frame=Bool(rfd_get(key,"native_frame",false)))
end

rf_feature_token(key)=begin d=rf_feature_descriptor(key);(string(d.case_id),d.eid,d.quantity,Tuple(d.path),d.native_frame) end

# A primitive can be almost zero after large signed terms cancel. Bound the
# floating summation error in that primitive's own units, rather than borrowing
# another tensor component's units or accepting an arbitrary absolute floor.
rf_affine_roundoff_bound(offset,influence,state)=128eps(Float64)*(
    abs(offset)+sum(abs(a*u) for (a,u) in zip(influence,state)))
rf_affine_replay_tolerance(actual,predicted,offset,influence,state)=max(
    1e-8max(abs(actual),abs(predicted),1e-12),rf_affine_roundoff_bound(offset,influence,state))

"""Resolve physical EIDs and their view frames once, rather than scanning every
element/group for each requested response on a large model.
"""
function rf_build_recovery_index(native,op,wing)
    frames=Dict{Int,Any}()
    for group in wing.groups,(index,eid) in enumerate(group.eids)
        haskey(frames,eid)&&throw(ArgumentError("Ambiguous physical RF element ID $eid"))
        frames[eid]=(;group,index)
    end
    entries=Dict{Int,Any}()
    for (field,kind) in (("CSHELLs",:shell),("CBARs",:bar),("CBEAMs",:bar),("CRODs",:rod))
        for (id,el) in get(op.model,field,Dict())
            eid=native.Solver._stress_entry_public_id(id,el)
            haskey(entries,eid)&&throw(ArgumentError("Ambiguous native RF element ID $eid"))
            frame=get(frames,eid,(;group=nothing,index=nothing))
            entries[eid]=(;field,kind,id,el,group=frame.group,index=frame.index)
        end
    end
    entries
end

function rf_recovery_target(native,context,eid)
    index=rfd_get(context,"recovery_index",nothing)
    index===nothing&&return rf_recovery_target(native,context.op,context.wing,eid)
    get!(context.recovery_targets,eid) do
        haskey(index,eid)||throw(ArgumentError("RF recovery element $eid is absent or unsupported"))
        item=index[eid];nodes=item.kind===:shell ? item.el["NODES"] : [item.el["GA"],item.el["GB"]]
        local_model=copy(context.op.model)
        for field in ("CSHELLs","CBARs","CBEAMs","CRODs","CONRODs")
            local_model[field]=field==item.field ? Dict(item.id=>item.el) : Dict{String,Any}()
        end
        dofs=reduce(vcat,[collect(6(context.op.id_map[node]-1).+(1:6)) for node in nodes])
        (;model=local_model,kind=item.kind,eid,el=item.el,dofs,group=item.group,index=item.index)
    end
end

function rf_recovery_target(native,op,wing,eid)
    found=nothing
    for (field,kind) in (("CSHELLs",:shell),("CBARs",:bar),("CBEAMs",:bar),("CRODs",:rod))
        for (id,el) in get(op.model,field,Dict())
            native.Solver._stress_entry_public_id(id,el)==eid||continue
            found===nothing||throw(ArgumentError("Ambiguous native RF element ID $eid"))
            nodes=kind===:shell ? el["NODES"] : [el["GA"],el["GB"]]
            local_model=copy(op.model)
            for other in ("CSHELLs","CBARs","CBEAMs","CRODs","CONRODs")
                local_model[other]=other==field ? Dict(id=>el) : Dict{String,Any}()
            end
            dofs=reduce(vcat,[collect(6(op.id_map[node]-1).+(1:6)) for node in nodes])
            group=nothing;index=nothing
            for g in wing.groups
                e=findfirst(==(eid),g.eids);e===nothing&&continue
                group=g;index=e;break
            end
            found=(;model=local_model,kind,eid,el,dofs,group,index)
        end
    end
    found===nothing&&throw(ArgumentError("RF recovery element $eid is absent or unsupported"))
    found
end

function rf_recovery_records(native,context,target,state;native_frame=false)
    op=context.op
    kinds=("quad4","tria3","cbar","cbeam","crod","conrod")
    result=Dict{String,Any}(name=>Dict(k=>Any[] for k in kinds) for name in ("forces","stresses","strains","forces_bilin"))
    result["solver_diagnostics"]=Dict{String,Any}();stress=Dict{Int,Float64}()
    if target.kind===:shell
        native.Solver.recover_shell_stresses!(target.model,op.id_map,op.X,op.node_R,state,op.snorm_normals,stress,result)
    else
        native.Solver.recover_bar_stresses!(target.model,op.id_map,op.X,op.node_R,state,stress,result;active_load_id=op.load_id)
    end
    records=Dict{String,Any}()
    for (quantity,bucket) in (("stress","stresses"),("strain","strains"),("force","forces"))
        rows=reduce(vcat,values(result[bucket]);init=Any[])
        matches=filter(row->Int(get(row,"eid",0))==target.eid,rows)
        length(matches)==1||throw(ArgumentError("Native RF recovery returned $(length(matches)) $quantity records for element $(target.eid)"))
        row=deepcopy(only(matches))
        if target.kind===:shell&&!native_frame
            target.group===nothing&&throw(ArgumentError("RF shell $(target.eid) has no physical group/frame"))
            c,s=shell_result_rotation(context.wing,target.group,target.index)
            rotate_shell_results!(row,quantity=="force" ? "forces" : quantity,c,s)
        end
        records[quantity]=row
    end
    records
end

rf_recovery_record(native,context,target,state,quantity;native_frame=false)=
    rf_recovery_records(native,context,target,state;native_frame)[quantity]

"""Prepare all requested primitive features of an element in one recovery pass
per coordinate basis vector. Stress/force/strain quantities share these calls.
"""
function rf_prepare_recovery!(native,context,keys)
    grouped=Dict{Tuple{Int,Bool},Vector{Any}}()
    for key in keys
        token=rf_feature_token(key);haskey(context.recovery_cache,token)&&continue
        d=rf_feature_descriptor(key);group=get!(grouped,(d.eid,d.native_frame),Any[])
        any(k->rf_feature_token(k)==token,group)||push!(group,key)
    end
    for ((eid,native_frame),selected) in grouped
        target=rf_recovery_target(native,context,eid)
        descriptors=rf_feature_descriptor.(selected)
        values(records)=[rf_path_value(records[d.quantity],d.path) for d in descriptors]
        zero_state=zeros(context.op.ndof)
        offset=values(rf_recovery_records(native,context,target,zero_state;native_frame))
        matrix=zeros(length(selected),length(target.dofs))
        for (j,dof) in enumerate(target.dofs)
            zero_state[dof]=1.;matrix[:,j]=values(rf_recovery_records(native,context,target,zero_state;native_frame)).-offset;zero_state[dof]=0.
        end
        actual=values(rf_recovery_records(native,context,target,context.expanded;native_frame))
        predicted=offset+matrix*context.expanded[target.dofs]
        scaled=values(rf_recovery_records(native,context,target,.37context.expanded;native_frame))
        for (i,key) in enumerate(selected)
            influence=view(matrix,i,:);state=context.expanded[target.dofs]
            tolerance=rf_affine_replay_tolerance(actual[i],predicted[i],offset[i],influence,state)
            scaled_prediction=offset[i]+.37dot(influence,state)
            scaled_tolerance=rf_affine_replay_tolerance(scaled[i],scaled_prediction,offset[i],influence,.37state)
            abs(actual[i]-predicted[i])<=tolerance&&abs(scaled[i]-scaled_prediction)<=scaled_tolerance||
                throw(ArgumentError("RF primitive recovery is not affine for element $eid, path $(descriptors[i].path)"))
            context.recovery_cache[rf_feature_token(key)]=(;value=actual[i],offset=offset[i],influence=vec(matrix[i,:]),
                dofs=target.dofs,target,descriptor=descriptors[i],roundoff_bound=rf_affine_roundoff_bound(offset[i],influence,state),
                replay_absolute_error=abs(actual[i]-predicted[i]),replay_tolerance=tolerance,
                replay_error=abs(actual[i]-predicted[i])/max(abs(actual[i]),1e-12))
        end
    end
    context
end

"""Exact unit-state influence of one primitive recovery scalar, cached per case.

This is not displacement finite differencing: native linear recovery is replayed
on its zero state and the exact element coordinate basis. A full-state and scaled
state replay guard rejects any quantity that is not actually affine.
"""
function rf_feature_influence(native,context,key)
    token=rf_feature_token(key)
    get!(context.recovery_cache,token) do
        d=rf_feature_descriptor(key);target=rf_recovery_target(native,context,d.eid)
        recover(u)=rf_path_value(rf_recovery_record(native,context,target,u,d.quantity;native_frame=d.native_frame),d.path)
        zero_state=zeros(context.op.ndof);offset=recover(zero_state)
        influence=zeros(length(target.dofs))
        for (j,dof) in enumerate(target.dofs)
            zero_state[dof]=1.;influence[j]=recover(zero_state)-offset;zero_state[dof]=0.
        end
        value=recover(context.expanded);predicted=offset+dot(influence,context.expanded[target.dofs])
        state=context.expanded[target.dofs]
        tolerance=rf_affine_replay_tolerance(value,predicted,offset,influence,state)
        abs(value-predicted)<=tolerance||throw(ArgumentError("RF native recovery is not affine for element $(d.eid), path $(d.path)"))
        scaled=recover(.37context.expanded)
        scaled_prediction=offset+.37dot(influence,state)
        abs(scaled-scaled_prediction)<=rf_affine_replay_tolerance(scaled,scaled_prediction,offset,influence,.37state)||
            throw(ArgumentError("RF quantity $(d.path) is nonlinear; a primitive component pullback is required"))
        (;value,offset,influence,dofs=target.dofs,target,descriptor=d,
            roundoff_bound=rf_affine_roundoff_bound(offset,influence,state),replay_absolute_error=abs(value-predicted),
            replay_tolerance=tolerance,replay_error=abs(value-predicted)/max(abs(value),1e-12))
    end
end

function rf_feature_state_gradient!(gradient,native,context,key,weight)
    iszero(weight)&&return gradient
    q=rf_feature_influence(native,context,key)
    gradient[q.dofs].+=weight.*q.influence
    gradient
end

"""Explicit primitive recovery derivative at fixed physical displacement."""
function rf_feature_property_jvp(native,context,key,directions)
    q=rf_feature_influence(native,context,key);target=q.target;d=q.descriptor
    pid=Int(target.el["PID"]);direction=get(directions,pid,nothing)
    direction===nothing&&return 0.
    if target.kind===:bar
        target.group===nothing&&throw(ArgumentError("RF bar $(d.eid) has no editable section ownership"))
        b=get!(get!(direction,"_rf_bar_data",Dict{Int,Any}()),d.eid) do
            sensitivity_analytic_bar(native,context.op,context.wing,target.group,target.index,direction,context.expanded)
        end
        field=String(only(d.path))
        if d.quantity=="force"
            component=Dict("axial"=>(7,1.),"shear_1"=>(2,-1.),"shear_2"=>(3,-1.),"torque"=>(4,-1.),
                "moment_a1"=>(6,-1.),"moment_a2"=>(5,1.),"moment_b1"=>(12,1.),"moment_b2"=>(11,-1.))
            haskey(component,field)||throw(ArgumentError("Unsupported bar force RF feature $field"))
            i,sign=component[field];return sign*b.dforces[i]
        elseif field in ("axial","axial_end_a","axial_end_b")
            return d.quantity=="stress" ? b.daxial_stress : begin
                material=bar_material_definition(context.wing.params,pid);E=get(material,"E_Pa",get(material,"E",nothing))
                E isa Real&&E>0||throw(ArgumentError("Bar strain recovery requires a positive elastic modulus"))
                (b.daxial_stress-b.axial_stress*get(direction,"E",0.)/E)/E
            end
        end
        throw(ArgumentError("Unsupported bar primitive RF feature $(d.path); use force-based capacity kernel"))
    elseif target.kind===:shell
        return rf_shell_feature_property_jvp(native,context,q,direction)
    end
    throw(ArgumentError("Explicit RF recovery derivative unsupported for $(target.kind)"))
end

function rf_shell_feature_property_jvp(native,context,q,direction)
    d=q.descriptor;op=context.op;ctx=op.shell_capture.contexts[d.eid]
    # The full generalized recovery jet is shared with plate/Euler demands.
    isdefined(native.Solver,:analytic_shell_recovery_tangent)||throw(ArgumentError("Native generalized shell RF recovery derivative is unavailable"))
    tangent=get!(get!(direction,"_rf_shell_recovery",Dict{Int,Any}()),d.eid) do
        native.Solver.analytic_shell_recovery_tangent(ctx,direction,context.expanded,op.id_map,op.X,op.node_R,op.snorm_normals)
    end
    quantity=d.quantity=="force" ? "forces" : d.quantity
    record=deepcopy(tangent.value[quantity]);delta=deepcopy(tangent.derivative[quantity])
    if !d.native_frame
        c,s=shell_result_rotation(context.wing,q.target.group,q.target.index)
        rotate_shell_results!(record,quantity,c,s);rotate_shell_results!(delta,quantity,c,s)
    end
    value=rf_path_value(record,d.path);derivative=rf_path_value(delta,d.path)
    tolerance=max(1e-8max(abs(value),abs(q.value),1e-12),rfd_get(q,"roundoff_bound",0.))
    abs(value-q.value)<=tolerance||throw(ArgumentError("Generalized shell RF recovery does not replay element $(d.eid), feature $(d.path): native=$(q.value), analytic=$value, absolute tolerance=$tolerance"))
    derivative
end
