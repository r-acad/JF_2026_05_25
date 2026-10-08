# Exact element derivative contractions with one shared state/adjoint.
# Only validation tests and the explicitly selected legacy method use FD.
function sensitivity_analytic_prepare(native,context,wing,objective)
    op=sensitivity_context_get(context,"op")
    op.shell_capture===nothing&&error("Analytic sensitivity needs captured native shell contexts")
    groups=Dict{Int,Vector{Any}}()
    for gr in wing.groups;push!(get!(groups,gr.pid,Any[]),gr);end
    expected=Set(eid for gr in wing.groups if gr.kind!==:bar for eid in gr.eids)
    actual=Set(keys(op.shell_capture.contexts))
    expected==actual||error("Analytic wing sensitivities require exactly the structural shells in the generated FEM. Disable optional exported aerodynamic shells before running analytic sensitivities.")
    kind=objective["type"]
    state=kind=="frequency_eigenvalue" ? nothing : kind=="buckling_factor" ? context["state"] : context.expanded
    phi=kind in ("frequency_eigenvalue","buckling_factor") ? context["physical_phi"] : nothing
    adjoint=kind=="frequency_eigenvalue" ? nothing : kind=="buckling_factor" ?
        sensitivity_expand_state(op,op.free,context["adjoint"][op.free]) : sensitivity_expand_state(op,op.free,context.lambda)
    features=kind in ("displacement","shell_stress","bar_stress") ? sensitivity_response_features(native,op,wing,objective,state) : nothing
    feature_gradient=features===nothing ? nothing : sensitivity_feature_response(features,objective;gradient=true).gradient
    geometric_contexts=kind=="buckling_factor" ? get(context,"geometric_contexts",nothing) : nothing
    kind=="buckling_factor"&&geometric_contexts===nothing&&(geometric_contexts=sensitivity_geometric_capture(native,op,state))
    (;op,groups,state,phi,adjoint,objective,features,feature_gradient,geometric_contexts,properties=model_property_definitions(wing),
        stringer_path=stringer_path(wing.grid.wing,wing.params))
end

function sensitivity_analytic_rotate_stress(v,c,s)
    x,y,xy=v
    [c*c*x+s*s*y+2c*s*xy,s*s*x+c*c*y-2c*s*xy,c*s*(y-x)+(c*c-s*s)*xy]
end

function sensitivity_analytic_derivative(native,context,wing,d,cache;cancelled=()->false)
    started=time();op=cache.op;kind=cache.objective["type"]
    directions=sensitivity_analytic_property_directions(wing,d;properties=cache.properties)
    isempty(directions)&&error("Property $(d["label"]) no longer controls an active element")
    ku=kp=mp=gp=explicit=0.;shells=bars=0;max_replay=0.
    for (pid,direction) in directions
        cancelled()&&error("Sensitivity study cancelled")
        for gr in get(cache.groups,pid,Any[]),e in 1:n_elements(gr)
            eid=gr.eids[e]
            if gr.kind===:bar
                local_data=sensitivity_analytic_bar(native,op,wing,gr,e,direction,cache.state)
                dofs=local_data.dofs;dk=local_data.dKe
                direction["area"]=local_data.section.darea;direction["density"]=direction["rho"];direction["offset_y"]=local_data.section.doffset_y
                max_replay=max(max_replay,local_data.stiffness_replay_relative_error);bars+=1
                if cache.phi!==nothing;pe=cache.phi[dofs];mp+=dot(pe,local_data.dMe*pe);end
                kind=="buckling_factor"&&(gp+=dot(cache.phi[dofs],local_data.dKg*cache.phi[dofs]))
                if kind=="bar_stress"&&eid==cache.objective["element_id"]
                    values=cache.objective["component"]=="axial" ? [local_data.axial_stress] : local_data.stress_features
                    deriv=cache.objective["component"]=="axial" ? [local_data.daxial_stress] : local_data.dstress_features
                    norm(values-cache.features)<=1e-8max(norm(cache.features),1.)||error("Analytic beam stress recovery does not replay native objective $eid")
                    explicit+=dot(cache.feature_gradient,deriv)
                end
            else
                shell_context=op.shell_capture.contexts[eid]
                local_data=native.Solver.analytic_shell_tangent(shell_context,direction)
                dofs=local_data.dofs;dk=local_data.dKe
                max_replay=max(max_replay,local_data.replay_error);shells+=1
                if kind=="shell_stress"&&eid==cache.objective["element_id"]
                    response=native.Solver.analytic_shell_stress_tangent(shell_context,direction,cache.state,
                        op.id_map,op.X,op.node_R,op.snorm_normals;surface=cache.objective["surface"])
                    c,s=shell_result_rotation(wing,gr,e;path=cache.stringer_path)
                    values=sensitivity_analytic_rotate_stress(response.features,c,s)
                    deriv=sensitivity_analytic_rotate_stress(response.dfeatures,c,s)
                    norm(values-cache.features)<=1e-8max(norm(cache.features),1.)||error("Analytic shell stress recovery does not replay native objective $eid")
                    explicit+=dot(cache.feature_gradient,deriv)
                end
            end
            cache.state===nothing||(ku+=dot(cache.adjoint[dofs],dk*cache.state[dofs]))
            cache.phi===nothing||(kp+=dot(cache.phi[dofs],dk*cache.phi[dofs]))
        end
    end
    load=sensitivity_analytic_load_tangent(wing,directions)
    df=sensitivity_analytic_reduce_load(native,op,load)
    lf=cache.adjoint===nothing ? 0. : dot(cache.adjoint[op.free],df[op.free])
    value=if kind=="frequency_eigenvalue"
        dm=sensitivity_analytic_shell_mass(native,op,directions)
        wtmass=Float64(get(op.model,"PARAM_WTMASS",1.))
        mp+=wtmass*dot(cache.phi,dm*cache.phi)
        (kp-context["lambda"]*mp)/context["denominator"]
    elseif kind=="buckling_factor"
        gp+=sensitivity_analytic_shell_geometric(native,op,wing,directions,cache.state,cache.phi;contexts=cache.geometric_contexts)
        -(kp+context["lambda"]*gp+lf-ku)/context["denominator"]
    else
        explicit+lf-ku
    end
    isfinite(value)||error("Analytic derivative is nonfinite")
    Dict{String,Any}("value"=>value,"explicit_response"=>explicit,"load_contraction"=>lf,"stiffness_contraction"=>ku,
        "eigen_stiffness_contraction"=>kp,"eigen_mass_contraction"=>mp,"geometric_contraction"=>gp,
        "shell_elements"=>shells,"bar_elements"=>bars,"kernel_replay_relative_error"=>max_replay,
        "seconds"=>time()-started,"forward_solves"=>0,"operator_evaluations"=>0,
        "derivative_assembly"=>"analytic_chain_rule","body_load_diagnostics"=>load.diagnostics)
end
