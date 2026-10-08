# Discrete adjoints of the actual assembled native equations. Parameter samples
# reassemble operators and recover the response at a fixed state: no perturbed
# equilibrium solve is performed in this file.
using LinearAlgebra
using SparseArrays

function sensitivity_preload_subcase(subs,solution)
    solution==103&&return first(values(subs))
    if solution==105
        # The native parser inherits LOAD into the buckling subcase. STATSUB,
        # rather than LOAD presence, identifies the static preload to replay.
        buckling=only([row for row in values(subs) if get(row,"STATSUB",nothing)!==nothing])
        sid=buckling["STATSUB"]
        haskey(subs,sid)||error("Buckling STATSUB $sid does not reference an available preload subcase")
        return subs[sid]
    end
    only([row for row in values(subs) if haskey(row,"LOAD")])
end

function sensitivity_assemble(native, parsed_model; solution=Int(parsed_model["SOL"]),analytic=false)
    S=native.Solver
    model=native._model_with_selected_mpc(parsed_model)
    isempty(get(model,"SPCDs",Any[]))||error("Adjoint operator adapter does not support enforced SPCD displacements")
    all(iszero(Float64(get(row,"D",0.))) for row in get(model,"SPC1s",Any[]))||error("Adjoint operator adapter requires homogeneous supports")
    cc=model["CASE_CONTROL"];subs=cc["SUBCASES"]
    sub=sensitivity_preload_subcase(subs,solution)
    S._subcase_temp_load_sid(sub,cc)===nothing||error("Temperature-dependent adjoint operators are not supported by the wing adapter")
    load_id=solution==103 ? nothing : get(sub,"LOAD",nothing);spc_id=get(sub,"SPC",nothing)
    membrane=solution==105 ? S.sol105_static_membrane_incomp_enabled() : solution==101 ? native._sol101_static_membrane_incomp_enabled(model) : true
    snorm=solution==105 ? S.sol105_snorm_angle_override() : nothing
    shell_capture=analytic ? S.AnalyticShellCapture(model) : nothing
    assembly_options=(;snorm_angle_override=snorm,membrane_incomp=membrane,sol105_context=solution==105,sol101_context=solution==101)
    K,id_map,X,ndof,node_R,max_elem_stiff,rbe3_map,snorm_normals,orig_diag=analytic ?
        S.assemble_stiffness(model;assembly_options...,shell_capture) : S.assemble_stiffness(model;assembly_options...)
    F=S._assemble_applied_force(ndof,model,id_map,X,load_id,node_R,rbe3_map;log_rbe3=false)
    followers=solution==101 ? S._follower_context(ndof,model,id_map,X,load_id,node_R,rbe3_map) : nothing
    A=followers===nothing ? K : K-last(S._follower_load_update(followers,zeros(ndof),1.;linearized=true))
    # A property derivative cannot silently differentiate through a changed
    # automatic support set. The forward partition is checked separately.
    free,fixed=S.compute_free_dofs(K,ndof,model,id_map,spc_id,rbe3_map;allow_factorization_autospc=false)
    return (;model,K,A,F,id_map,X,ndof,node_R,max_elem_stiff,rbe3_map,snorm_normals,orig_diag,load_id,spc_id,free,fixed,followers,shell_capture)
end

function sensitivity_check_operators(base,trial)
    for field in (:id_map,:X,:node_R,:rbe3_map,:free,:fixed,:load_id,:spc_id)
        getproperty(base,field)==getproperty(trial,field)||error("Adjoint perturbation changed $(field); fixed topology/constraint partition is required")
    end
    base.ndof==trial.ndof||error("Adjoint perturbation changed the number of DOFs")
    all(isfinite,nonzeros(trial.A))&&all(isfinite,trial.F)||error("Perturbed operators contain nonfinite entries")
    return nothing
end

function sensitivity_expand_state(op,free,values)
    u=zeros(op.ndof);u[free]=values
    for (dependent,pairs) in op.rbe3_map
        all(!haskey(op.rbe3_map,index) for (index,_) in pairs)||error("Adjoint adapter requires flattened native constraint maps")
        u[dependent]=sum(weight*u[index] for (index,weight) in pairs)
    end
    return u
end

function sensitivity_reduce_gradient(op,gradient)
    reduced=copy(gradient)
    for (dependent,pairs) in op.rbe3_map
        for (index,weight) in pairs;reduced[index]+=weight*gradient[dependent];end
        reduced[dependent]=0.
    end
    return reduced[op.free]
end

# Native congruence has already redistributed dependent DOFs. Keep only free
# entries in this vector, so a sparse matrix-vector product equals A[free,free]*u
# without copying the sparse free-free matrix for every property sample.
function sensitivity_independent_state(op,values)
    state=zeros(op.ndof);state[op.free]=values;return state
end
function sensitivity_operator_residual(op,independent_state)
    (op.F-op.A*independent_state)[op.free]
end

function sensitivity_recovery_target(native,op,objective)
    kind=objective["type"]
    if kind=="displacement"
        return (model=op.model,dofs=collect(6(op.id_map[objective["node_id"]]-1).+(1:3)))
    end
    key=kind=="shell_stress" ? "CSHELLs" : "CBARs";eid=objective["element_id"]
    chosen=only([(id,el) for (id,el) in op.model[key] if native.Solver._stress_entry_public_id(id,el)==eid])
    local_model=copy(op.model);local_model[key]=Dict(first(chosen)=>last(chosen))
    nodes=kind=="shell_stress" ? last(chosen)["NODES"] : [last(chosen)["GA"],last(chosen)["GB"]]
    dofs=reduce(vcat,[collect(6(op.id_map[id]-1).+(1:6)) for id in nodes])
    return (model=local_model,dofs=dofs)
end

function sensitivity_response_features(native,op,wing,objective,u,target=sensitivity_recovery_target(native,op,objective))
    kind=objective["type"]
    if kind=="displacement"
        row=op.id_map[objective["node_id"]];return op.node_R[row]*u[6(row-1).+(1:3)]
    end
    result=Dict{String,Any}("forces"=>Dict("cbar"=>Any[],"quad4"=>Any[],"tria3"=>Any[]),
        "forces_bilin"=>Dict("quad4"=>Any[],"tria3"=>Any[]),"stresses"=>Dict("cbar"=>Any[],"quad4"=>Any[],"tria3"=>Any[]),
        "strains"=>Dict("cbar"=>Any[],"quad4"=>Any[],"tria3"=>Any[]),"solver_diagnostics"=>Dict{String,Any}())
    stress=Dict{Int,Float64}();eid=objective["element_id"]
    if kind=="shell_stress"
        native.Solver.recover_shell_stresses!(target.model,op.id_map,op.X,op.node_R,u,op.snorm_normals,stress,result)
        row=only(vcat(result["stresses"]["quad4"],result["stresses"]["tria3"]))
        data=Dict{String,Any}(k=>deepcopy(v) for (k,v) in row if k!="eid")
        group=only(filter(g->eid in g.eids,wing.groups));index=findfirst(==(eid),group.eids)
        c,s=shell_result_rotation(wing,group,index;path=stringer_path(wing.grid.wing,wing.params))
        rotate_shell_results!(data,"stress",c,s);fiber=data[objective["surface"]]
        return Float64[fiber["normal_x"],fiber["normal_y"],fiber["shear_xy"]]
    end
    native.Solver.recover_bar_stresses!(target.model,op.id_map,op.X,op.node_R,u,stress,result;active_load_id=op.load_id)
    # Native recovery also iterates CBEAMs; WingFEGen currently emits CBAR only.
    row=only(filter(r->r["eid"]==eid,result["stresses"]["cbar"]))
    objective["component"]=="axial"&&return [Float64(row["axial"])]
    force=only(filter(r->r["eid"]==eid,result["forces"]["cbar"]))
    group=only(filter(g->eid in g.eids,wing.groups));section=section_definition(wing.params,group.pid)
    return Float64[row["axial"]-force["moment_$(ending)1"]*point[1]/section["I1_m4"]-
        force["moment_$(ending)2"]*point[2]/section["I2_m4"] for ending in ("a","b") for point in section["polygon_yz_m"]]
end

function sensitivity_feature_response(features,objective;gradient=false)
    all(isfinite,features)||error("Objective recovery returned nonfinite values")
    kind=objective["type"];component=objective["component"];coeff=zeros(length(features))
    if kind=="displacement"
        if component=="magnitude"
            value=norm(features);gradient&&value<=1e-14&&error("Displacement magnitude is nondifferentiable at zero; select a signed component")
            value>0&&(coeff.=features./value)
        else
            index=Dict("x"=>1,"y"=>2,"z"=>3)[component];value=features[index];coeff[index]=1.
        end
    elseif kind=="shell_stress"
        x,y,xy=features
        if component=="von_mises"
            value=sqrt(max(0.,x*x+y*y-x*y+3xy*xy))
            gradient&&value<=1e-12&&error("von Mises stress is nondifferentiable at zero; select a signed stress component")
            value>0&&(coeff.=[2x-y,2y-x,6xy]./(2value))
        elseif component in ("major","minor")
            radius=hypot((x-y)/2,xy);sign=component=="major" ? 1. : -1.
            gradient&&radius<=1e-10max(abs(x),abs(y),abs(xy),1.)&&error("Repeated principal stresses have no unique individual adjoint gradient; select a stress component")
            value=(x+y)/2+sign*radius
            radius>0&&(coeff.=[.5+sign*(x-y)/(4radius),.5-sign*(x-y)/(4radius),sign*xy/radius])
        else
            index=Dict("normal_x"=>1,"normal_y"=>2,"shear_xy"=>3)[component];value=features[index];coeff[index]=1.
        end
    else
        index=component=="max" ? argmax(features) : component=="min" ? argmin(features) : 1
        value=features[index];coeff[index]=1.
    end
    return (value=Float64(value),gradient=coeff)
end

function sensitivity_static_context(native,forward,wing,objective;analytic=false)
    Int(forward["sol_type"])==101||error("Static adjoint requires SOL101 forward results")
    sub=only(forward["subcases"]);op=sensitivity_assemble(native,deepcopy(forward["model"]);solution=101,analytic)
    get(sub,"temp_load_id",nothing)===nothing||error("Thermal adjoint recovery is unsupported")
    op.id_map==sub["id_map"]&&op.X==sub["node_coords"]&&op.node_R==sub["node_R"]||error("Adjoint assembly changed forward coordinate ordering")
    Set(op.fixed)==Set(sub["fixed_dofs"])||error("Forward automatic support partition differs from adjoint partition")
    matrix_error=norm(op.K-sub["K"])/max(norm(sub["K"]),eps())
    matrix_error<1e-11||error("Adjoint reassembly does not reproduce the native forward stiffness ($matrix_error)")
    u=Float64.(sub["u_analysis"][op.free]);expanded=sensitivity_expand_state(op,op.free,u)
    state_error=norm(expanded-sub["u_analysis"])/max(norm(expanded),eps())
    state_error<1e-11||error("Native constraint reconstruction mismatch ($state_error)")
    A=op.A[op.free,op.free];F=op.F[op.free]
    forward_residual=norm(A*u-F)/max(norm(F),eps())
    forward_residual<1e-6||error("Adjoint operators do not reproduce forward equilibrium ($forward_residual)")
    target=sensitivity_recovery_target(native,op,objective)
    features=sensitivity_response_features(native,op,wing,objective,expanded,target)
    response=sensitivity_feature_response(features,objective;gradient=true)
    expected=sensitivity_response(forward,wing,objective).value
    isapprox(response.value,expected;rtol=1e-9,atol=1e-10)||error("Adjoint recovery does not match displayed forward response")
    # Recovery is affine in the element's state. Native unit-vector recovery
    # extracts its exact influence coefficients; nonlinear scalar measures use
    # their analytic chain rule. No displacement perturbation size is involved.
    zero_state=zeros(op.ndof);offset=sensitivity_response_features(native,op,wing,objective,zero_state,target)
    columns=zeros(length(features),length(target.dofs))
    for (j,dof) in enumerate(target.dofs)
        zero_state[dof]=1.;columns[:,j]=sensitivity_response_features(native,op,wing,objective,zero_state,target).-offset;zero_state[dof]=0.
    end
    recovery_error=norm(offset+columns*expanded[target.dofs]-features)/max(norm(features),1e-12)
    recovery_error<1e-8||error("Native objective recovery is not reproduced by its local affine influence matrix ($recovery_error)")
    if objective["type"]=="bar_stress"&&objective["component"] in ("max","min")
        active=findall(value->abs(value-response.value)<=1e-9max(maximum(abs,features),1.),features)
        chosen=findfirst(!iszero,response.gradient)
        for index in active
            norm(columns[index,:]-columns[chosen,:])<=1e-9max(norm(columns[chosen,:]),1.)||error("Tied beam stress extrema have different state gradients; select axial stress or another element")
        end
    end
    gradient=zeros(op.ndof);gradient[target.dofs]=transpose(columns)*response.gradient
    rhs=sensitivity_reduce_gradient(op,gradient)
    lambda=transpose(A)\rhs
    adjoint_residual=norm(transpose(A)*lambda-rhs)/max(norm(rhs),eps())
    adjoint_residual<1e-8||error("Adjoint transpose solve did not converge ($adjoint_residual)")
    diagnostics=Dict("forward_replay_residual"=>forward_residual,"adjoint_relative_residual"=>adjoint_residual,
        "stiffness_replay_relative_error"=>matrix_error,"constraint_replay_relative_error"=>state_error,
        "recovery_influence_relative_error"=>recovery_error,
        "unsymmetric_follower_tangent"=>op.followers!==nothing,"response_influence_columns"=>length(target.dofs))
    baseline_sample=response.value+dot(lambda,F-A*u)
    independent_state=sensitivity_independent_state(op,u)
    return (;op,objective,u,lambda,expanded,independent_state,baseline=response.value,baseline_sample,unit=objective["type"]=="displacement" ? "m" : "Pa",diagnostics,
        solver_counts=Dict("forward_solves"=>1,"adjoint_solves"=>1,"eigen_solves"=>0,"operator_evaluations"=>1))
end

function sensitivity_static_sample(native,context,bdf,wing)
    started=time();parsed=native.bdf_to_model(bdf);parse_seconds=time()-started
    started=time();op=sensitivity_assemble(native,parsed;solution=101);assembly_seconds=time()-started
    sensitivity_check_operators(context.op,op)
    # The exact partition/map checks above make this fixed physical state
    # reusable, including RBE3 dependents and unsymmetric follower tangents.
    started=time();features=sensitivity_response_features(native,op,wing,context.objective,context.expanded)
    response=sensitivity_feature_response(features,context.objective).value
    recovery_seconds=time()-started;started=time()
    residual=sensitivity_operator_residual(op,context.independent_state)
    correction=dot(context.lambda,residual)
    return Dict("value"=>response+correction,"explicit_response"=>response,"adjoint_residual_contraction"=>correction,
        "operator_residual_norm"=>norm(residual),"forward_solves"=>0,"operator_evaluations"=>1,
        "timings_seconds"=>Dict("parse"=>parse_seconds,"assembly"=>assembly_seconds,
            "recovery"=>recovery_seconds,"contraction"=>time()-started))
end
