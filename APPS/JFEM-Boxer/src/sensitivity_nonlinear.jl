# Differentiate the actual final-load SOL106 equilibrium. The legacy solver's
# correction matrix K+Kg is generally not its residual Jacobian: d(Kg(u)u)/du
# includes the derivative of the prestress field as well. All state derivatives
# below are local automatic differentiation or exact beam chain rules. The
# energy-consistent shell route uses its actual energy Hessian. Neither route
# needs finite-difference samples or additional forward equilibrium solves.

function sensitivity_nonlinear_supported_model(native,model,objective)
    objective["type"]=="displacement"||throw(ArgumentError("SOL106 analytic sensitivity currently supports final-load displacement only; nonlinear stress recovery is not differentiated"))
    method=lowercase(string(get(model,"PARAM_NLMETHOD","auto")))
    method in ("auto","legacy","legacy_geometric","","formal","green_lagrange","formal_shell_green_lagrange","formal_shell_von_karman","formal_von_karman","formal_shell_vk")||throw(ArgumentError("Unsupported SOL106 nonlinear formulation for analytic sensitivity: $method"))
    for family in ("CSOLIDs","CBEAMs","CRODs","CONRODs","CELAS1s","CELAS2s","CBUSHs")
        isempty(get(model,family,Dict()))||throw(ArgumentError("SOL106 analytic residual replay does not support $family"))
    end
    any(!isempty(get(model,key,Any[])) for key in ("SPCDs",))&&throw(ArgumentError("SOL106 sensitivities require homogeneous supports"))
    all(iszero(Float64(get(row,"D",0.))) for row in get(model,"SPC1s",Any[]))||throw(ArgumentError("SOL106 sensitivities require homogeneous supports"))
    for pid in unique(parse(Int,string(el["PID"])) for el in values(get(model,"CSHELLs",Dict())))
        # The exact state Jacobian needs every shell's material law, even if
        # the selected property belongs to another element family.
        native.Solver.analytic_shell_constitutive(model,pid,Dict(),0.)
    end
    cc=model["CASE_CONTROL"];sub=sensitivity_preload_subcase(cc["SUBCASES"],106)
    native.Solver._subcase_temp_load_sid(sub,cc)===nothing||throw(ArgumentError("SOL106 thermal sensitivity is unsupported"))
    if get(model,"PARAM_JFFOLLOW",0)==1&&get(sub,"LOAD",nothing)!==nothing
        scales=native.Solver._load_sid_scales(model,Int(sub["LOAD"]),1.)
        any(uppercase(String(get(row,"FLLW","")))=="ROT"&&!iszero(get(scales,Int(row["SID"]),0.)) for row in get(model,"FORCEs",Any[]))&&
            throw(ArgumentError("SOL106 follower-load adjoints are not implemented; choose fixed-direction loads"))
    end
    nothing
end

function sensitivity_nonlinear_convergence(sub)
    info=get(sub,"nonlinear_diagnostics",Dict())
    method=get(info,"nonlinear_method","")
    method in ("legacy_geometric","formal_shell_green_lagrange","formal_shell_von_karman","linear_elastic")||throw(ArgumentError("SOL106 adjoint requires a supported nonlinear residual"))
    get(info,"converged",false)&&get(info,"exported_state_accepted",false)&&
        isapprox(get(info,"final_load_scale",0.),1.;atol=1e-12,rtol=0.)&&
        isapprox(get(info,"exported_load_scale",0.),1.;atol=1e-12,rtol=0.)||
        throw(ArgumentError("SOL106 sensitivity requires an accepted converged full-load state; a partial-load checkpoint has no requested full-load derivative"))
    residual=Float64(get(info,"exported_relative_residual",Inf))
    isfinite(residual)&&residual<=1e-6||throw(ArgumentError("SOL106 final residual is too large for sensitivity ($residual); tighten nonlinear convergence tolerances"))
    residual_model=get(info,"residual_model","")
    if method in ("formal_shell_green_lagrange","formal_shell_von_karman")
        residual_model=="formal_internal_force"||throw(ArgumentError("Unsupported formal SOL106 residual model $residual_model"))
        return info,1.
    elseif method=="linear_elastic"
        residual_model=="linear_internal_force"||throw(ArgumentError("Unsupported linear SOL106 residual model $residual_model"))
        return info,1.
    end
    residual_model in ("tangent_operator","secant_geometric")||throw(ArgumentError("Unsupported SOL106 residual model $residual_model"))
    info,residual_model=="secant_geometric" ? .5 : 1.
end

function sensitivity_nonlinear_context(native,forward,wing,objective;analytic=true,progress=(_)->nothing,cancelled=()->false)
    analytic||throw(ArgumentError("SOL106 sensitivity requires analytic derivatives; operator differences are not supported"))
    Int(forward["sol_type"])==106||error("Nonlinear adjoint requires actual SOL106 forward results")
    sensitivity_nonlinear_supported_model(native,forward["model"],objective)
    sub=only(forward["subcases"]);info,coefficient=sensitivity_nonlinear_convergence(sub)
    op=sensitivity_assemble(native,deepcopy(forward["model"]);solution=106,analytic=true)
    expected_shells=Set(eid for gr in wing.groups if gr.kind!==:bar for eid in gr.eids)
    expected_shells==Set(keys(op.shell_capture.contexts))||throw(ArgumentError("SOL106 analytic sensitivity requires every native shell to belong to the sensitivity model; optional exported aerodynamic shells are unsupported"))
    native.Solver._follower_context(op.ndof,op.model,op.id_map,op.X,op.load_id,op.node_R,op.rbe3_map)===nothing||
        throw(ArgumentError("SOL106 follower-load adjoints are not implemented; choose fixed-direction loads"))
    op.id_map==sub["id_map"]&&op.X==sub["node_coords"]&&op.node_R==sub["node_R"]||error("Nonlinear adjoint changed forward coordinate ordering")
    Set(op.fixed)==Set(sub["fixed_dofs"])||error("Nonlinear forward automatic support partition differs from analytic partition")
    matrix_error=sensitivity_eigen_matrix_check(op.K,sub["K"],"SOL106 linear stiffness";rtol=1e-11)
    u=Float64.(sub["u_analysis"][op.free]);expanded=sensitivity_expand_state(op,op.free,u)
    state_error=norm(expanded-sub["u_analysis"])/max(norm(expanded),eps())
    state_error<1e-11||error("Nonlinear native constraint reconstruction mismatch ($state_error)")
    independent_state=sensitivity_independent_state(op,u)
    if info["nonlinear_method"] in ("formal_shell_green_lagrange","formal_shell_von_karman","linear_elastic")
        return sensitivity_nonlinear_formal_context(native,forward,wing,objective,op,info,u,expanded,
            independent_state,matrix_error,state_error;cancelled)
    end
    contexts=sensitivity_geometric_capture(native,op,expanded);AD=native.Solver.ForwardDiff
    ii=Int[];jj=Int[];gv=Float64[];jv=Float64[];max_replay=0.;elements=0
    function add!(dofs,G,J)
        for b in eachindex(dofs),a in eachindex(dofs)
            push!(ii,dofs[a]);push!(jj,dofs[b]);push!(gv,G[a,b]);push!(jv,J[a,b])
        end
        elements+=1
    end
    for ctx in values(contexts)
        cancelled()&&error("Sensitivity study cancelled")
        max_replay=max(max_replay,sensitivity_geometric_shell_check(native,ctx))
        dofs=ctx[ctx[:n]==4 ? :dofs_buf24 : :dofs_t3];T=ctx[ctx[:n]==4 ? :T_buf : :T18]
        ue=expanded[dofs];G=sensitivity_geometric_shell_replay(native,ctx)
        J=AD.jacobian(v->sensitivity_geometric_shell_replay(native,ctx;local_state=T*v)*v,ue)
        add!(dofs,G,J)
        elements%25==0&&progress(Dict("detail"=>"Exact nonlinear residual Jacobian: $elements elements"))
    end
    for gr in wing.groups
        gr.kind===:bar||continue
        for e in 1:n_elements(gr)
            cancelled()&&error("Sensitivity study cancelled")
            bar=sensitivity_analytic_bar(native,op,wing,gr,e,Dict{String,Any}(),expanded)
            ue=expanded[bar.dofs];J=copy(bar.Kg)
            for (component,unit) in zip(bar.force_components,bar.kg_force_units)
                J .+= (unit*ue)*transpose(vec(bar.force_gradient[component,:]))
            end
            add!(bar.dofs,bar.Kg,J)
        end
    end
    Gphysical=sparse(ii,jj,gv,op.ndof,op.ndof)
    Jphysical=sparse(ii,jj,jv,op.ndof,op.ndof)
    G=native.Solver._apply_constraint_congruence(Gphysical,op.rbe3_map;expected_ndof=op.ndof)
    geometric_error=sensitivity_eigen_matrix_check(G,forward["Kg"],"SOL106 geometric residual";rtol=2e-9)
    J=op.K+coefficient*native.Solver._apply_constraint_congruence(Jphysical,op.rbe3_map;expected_ndof=op.ndof)
    residual=(op.K*independent_state+coefficient*G*independent_state-op.F)[op.free]
    forward_residual=norm(residual)/max(norm(op.F[op.free]),eps())
    forward_residual<=1e-6||error("Nonlinear analytic operators do not reproduce converged equilibrium ($forward_residual)")
    target=sensitivity_recovery_target(native,op,objective)
    features=sensitivity_response_features(native,op,wing,objective,expanded,target)
    response=sensitivity_feature_response(features,objective;gradient=true)
    expected=sensitivity_response(forward,wing,objective).value
    isapprox(response.value,expected;rtol=1e-9,atol=1e-12)||error("Nonlinear objective does not match displayed forward displacement")
    gradient=zeros(op.ndof);row=op.id_map[objective["node_id"]]
    gradient[target.dofs]=transpose(op.node_R[row])*response.gradient
    rhs=sensitivity_reduce_gradient(op,gradient);A=J[op.free,op.free]
    lambda=transpose(A)\rhs
    adjoint_residual=norm(transpose(A)*lambda-rhs)/max(norm(rhs),eps())
    adjoint_residual<1e-8||error("Nonlinear transpose adjoint did not converge ($adjoint_residual)")
    diagnostics=Dict{String,Any}("forward_replay_residual"=>forward_residual,"adjoint_relative_residual"=>adjoint_residual,
        "stiffness_replay_relative_error"=>matrix_error,"geometric_replay_relative_error"=>geometric_error,
        "constraint_replay_relative_error"=>state_error,"kernel_replay_relative_error"=>max_replay,
        "nonlinear_method"=>info["nonlinear_method"],"residual_model"=>info["residual_model"],
        "final_load_scale"=>info["final_load_scale"],"exported_state_accepted"=>true,
        "residual_jacobian"=>"exact_element_chain_rule","iteration_matrix_is_residual_jacobian"=>false,
        "jacobian_nonsymmetry"=>norm(A-transpose(A))/max(norm(A),eps()),
        "load_step_count"=>get(info,"load_step_count",nothing))
    (;op,objective,u,lambda,expanded,independent_state,coefficient,geometric_contexts=contexts,
        baseline=response.value,baseline_sample=response.value-dot(lambda,residual),unit="m",diagnostics,
        solver_counts=Dict("forward_solves"=>1,"adjoint_solves"=>1,"eigen_solves"=>0,"operator_evaluations"=>1))
end

# The membrane energy is linear in its constitutive matrix. Consequently its
# exact material/property derivative is the same energy gradient evaluated with
# dCm, rather than a property perturbation or a second equilibrium solution.
function sensitivity_nonlinear_formal_elements(native,op;cancelled=()->false)
    S=native.Solver;contexts=Dict{Int,Any}()
    support=S._automatic_shell_energy_support(op.model,op.id_map,op.X,op.snorm_normals)
    support.supported||throw(ArgumentError("Formal SOL106 analytic sensitivity is outside the supported planar isotropic shell scope: $(support.reason)"))
    for (key,el) in get(op.model,"CSHELLs",Dict())
        cancelled()&&error("Sensitivity study cancelled")
        eid=parse(Int,string(key));pid=parse(Int,string(el["PID"]))
        prop=op.model["PSHELLs"][string(pid)]
        get(prop,"TYPE","")!="PCOMP_CLT"||throw(ArgumentError("Formal SOL106 analytic sensitivity currently requires isotropic PSHELL properties"))
        iszero(Float64(get(el,"ZOFFS",0.)))||throw(ArgumentError("Formal SOL106 analytic sensitivity does not support shell offsets"))
        nodes=el["NODES"];n=length(nodes)
        n in (3,4)||throw(ArgumentError("Formal SOL106 analytic sensitivity requires CQUAD4 or CTRIA3"))
        indices=[op.id_map[node] for node in nodes]
        points=[S.SVector{3,Float64}(op.X[i,:]) for i in indices]
        n==4&&!S._quad4_is_coplanar(points...)&&throw(ArgumentError("Formal SOL106 analytic sensitivity requires planar shell elements (EID $eid)"))
        frame=n==4 ? S.shell_element_frame_quad4(points...,S.q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC")) :
            S.shell_element_frame_fast(points[1],points[2],points[3],points[3],3)
        v1,v2,v3=S.apply_snorm_to_frame(frame...,indices,op.snorm_normals)
        R=Matrix(vcat(v1',v2',v3'));center=sum(points)/n
        coords=[dot(point-center,v) for point in points,v in (v1,v2)]
        T=zeros(6n,6n)
        for (a,index) in enumerate(indices),shift in (0,3)
            rows=6(a-1).+((1:3).+shift)
            T[rows,rows]=R*op.node_R[index]
        end
        dofs=vcat([6(index-1).+collect(1:6) for index in indices]...)
        state=S.analytic_shell_constitutive(op.model,pid,Dict(),0.)
        contexts[eid]=(;pid,dofs,coords,transform=T,n,Cm=state.Cm)
    end
    contexts
end

function sensitivity_nonlinear_formal_context(native,forward,wing,objective,op,info,u,expanded,
        independent_state,matrix_error,state_error;cancelled=()->false)
    linear=info["nonlinear_method"]=="linear_elastic"
    contexts=linear ? Dict{Int,Any}() : sensitivity_nonlinear_formal_elements(native,op;cancelled)
    state=linear ? native.Solver._evaluate_nonlinear_state_linear(op.K,op.F,op.ndof,op.model,op.id_map,
        op.spc_id,independent_state,op.rbe3_map) :
        native.Solver._evaluate_nonlinear_state_formal(op.K,op.F,op.ndof,op.model,op.id_map,
            op.X,op.spc_id,op.node_R,expanded,op.snorm_normals,op.rbe3_map)
    geometric_error=sensitivity_eigen_matrix_check(state.Kg,forward["Kg"],"SOL106 energy Hessian";rtol=2e-9)
    linear&&!iszero(norm(state.Kg))&&error("Linear SOL106 residual has a nonzero geometric tangent")
    residual=state.residual_vector[op.free]
    forward_residual=norm(residual)/max(norm(op.F[op.free]),eps())
    forward_residual<=1e-6||error("Formal nonlinear analytic operators do not reproduce converged equilibrium ($forward_residual)")
    target=sensitivity_recovery_target(native,op,objective)
    features=sensitivity_response_features(native,op,wing,objective,expanded,target)
    response=sensitivity_feature_response(features,objective;gradient=true)
    expected=sensitivity_response(forward,wing,objective).value
    isapprox(response.value,expected;rtol=1e-9,atol=1e-12)||error("Formal nonlinear objective does not match displayed forward displacement")
    gradient=zeros(op.ndof);row=op.id_map[objective["node_id"]]
    gradient[target.dofs]=transpose(op.node_R[row])*response.gradient
    rhs=sensitivity_reduce_gradient(op,gradient);A=state.K_eff[op.free,op.free]
    lambda=transpose(A)\rhs
    adjoint_residual=norm(transpose(A)*lambda-rhs)/max(norm(rhs),eps())
    adjoint_residual<1e-8||error("Formal nonlinear transpose adjoint did not converge ($adjoint_residual)")
    diagnostics=Dict{String,Any}("forward_replay_residual"=>forward_residual,"adjoint_relative_residual"=>adjoint_residual,
        "stiffness_replay_relative_error"=>matrix_error,"geometric_replay_relative_error"=>geometric_error,
        "constraint_replay_relative_error"=>state_error,"kernel_replay_relative_error"=>0.,
        "nonlinear_method"=>info["nonlinear_method"],"residual_model"=>info["residual_model"],
        "final_load_scale"=>info["final_load_scale"],"exported_state_accepted"=>true,
        "residual_jacobian"=>linear ? "exact_linear_stiffness" : "exact_energy_hessian","iteration_matrix_is_residual_jacobian"=>true,
        "jacobian_nonsymmetry"=>norm(A-transpose(A))/max(norm(A),eps()),
        "load_step_count"=>get(info,"load_step_count",nothing))
    (;op,objective,u,lambda,expanded,independent_state,coefficient=1.,geometric_contexts=contexts,
        baseline=response.value,baseline_sample=response.value-dot(lambda,residual),unit="m",diagnostics,
        solver_counts=Dict("forward_solves"=>1,"adjoint_solves"=>1,"eigen_solves"=>0,"operator_evaluations"=>1))
end

function sensitivity_nonlinear_formal_force_derivative(native,context,eid,direction)
    S=native.Solver;ctx=context.geometric_contexts[eid]
    seeded=S.analytic_shell_constitutive(context.op.model,ctx.pid,direction,S.ForwardDiff.Dual(0.,1.))
    dCm=map(value->S.ForwardDiff.partials(value)[1],seeded.Cm)
    ulocal=ctx.transform*context.expanded[ctx.dofs]
    energy=ctx.n==4 ? S._formal_vk_quad4_extra_energy : S._formal_vk_tria3_extra_energy
    dforce=S.ForwardDiff.gradient(v->energy(ctx.coords,v,dCm),ulocal)
    ctx.transform'*dforce
end

function sensitivity_nonlinear_derivative(native,context,wing,d;cancelled=()->false)
    started=time();op=context.op;imported=is_imported_model(wing)
    imported&&imported_derivative_coverage(wing,d)
    directions=imported ? d["directions"] : sensitivity_analytic_property_directions(wing,d)
    isempty(directions)&&error("Selected property controls no active element")
    if imported
        # Imported body-load derivatives need their own card-preserving tangent.
        any(!isempty(get(op.model,key,Any[])) for key in ("GRAVs","ACCELs","ACCEL1s","RFORCEs"))&&
            throw(ArgumentError("Imported SOL106 mass-dependent loads are outside the analytic sensitivity scope"))
    end
    formal=context.diagnostics["nonlinear_method"] in ("formal_shell_green_lagrange","formal_shell_von_karman")
    linear=context.diagnostics["nonlinear_method"]=="linear_elastic"
    adjoint=sensitivity_expand_state(op,op.free,context.lambda);ku=gu=0.;n=0;max_replay=0.
    for gr in wing.groups
        direction=sensitivity_pid_direction(directions,gr.pid);direction===nothing&&continue
        for e in 1:n_elements(gr)
            cancelled()&&error("Sensitivity study cancelled")
            eid=gr.eids[e]
            if gr.kind===:bar
                localdata=sensitivity_analytic_bar(native,op,wing,gr,e,direction,context.expanded)
                dofs=localdata.dofs;dk=localdata.dKe;dg=(formal||linear) ? nothing : localdata.dKg
                if !imported
                    direction["area"]=localdata.section.darea;direction["density"]=get(direction,"rho",0.);direction["offset_y"]=localdata.section.doffset_y
                end
                max_replay=max(max_replay,localdata.stiffness_replay_relative_error)
            else
                localdata=native.Solver.analytic_shell_tangent(op.shell_capture.contexts[eid],direction)
                dofs=localdata.dofs;dk=localdata.dKe;max_replay=max(max_replay,localdata.replay_error)
                if linear
                    dg=nothing
                elseif formal
                    dg=nothing
                    gu+=dot(adjoint[dofs],sensitivity_nonlinear_formal_force_derivative(native,context,eid,direction))
                else
                    dual=sensitivity_geometric_shell_replay(native,context.geometric_contexts[eid],direction,native.Solver.ForwardDiff.Dual(0.,1.))
                    dg=map(x->native.Solver.ForwardDiff.partials(x)[1],dual)
                end
            end
            ku+=dot(adjoint[dofs],dk*context.expanded[dofs])
            dg===nothing||(gu+=dot(adjoint[dofs],dg*context.expanded[dofs]));n+=1
        end
    end
    lf=0.;load_diagnostics=Dict{String,Any}()
    if !imported
        load=sensitivity_analytic_load_tangent(wing,directions);df=sensitivity_analytic_reduce_load(native,op,load)
        lf=dot(context.lambda,df[op.free]);load_diagnostics=load.diagnostics
    end
    value=lf-ku-context.coefficient*gu
    isfinite(value)||error("Nonlinear analytic derivative is nonfinite")
    Dict{String,Any}("value"=>value,"seconds"=>time()-started,"elements"=>n,"stiffness_contraction"=>ku,
        "geometric_residual_contraction"=>context.coefficient*gu,"load_contraction"=>lf,
        "kernel_replay_relative_error"=>max_replay,"forward_solves"=>0,"operator_evaluations"=>0,
        "derivative_assembly"=>"analytic_chain_rule","body_load_diagnostics"=>load_diagnostics)
end
