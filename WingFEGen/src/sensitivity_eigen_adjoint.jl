# Discrete eigenvalue adjoints. The analytic path differentiates native element
# energies at the fixed baseline. The explicit legacy path retains operator
# differences for comparison; neither path solves a perturbed equilibrium here.
using LinearAlgebra

function sensitivity_eigen_matrix_check(a,b,label;rtol=1e-9)
    size(a)==size(b)||error("$label changed its operator dimensions")
    relative=norm(a-b)/max(norm(a),norm(b),eps())
    relative<=rtol||error("$label does not replay the baseline native operator (relative difference $relative)")
    relative
end

function sensitivity_mode_analysis(result,index,node_R)
    phi=Float64.(result["_raw_mode_shapes"][:,index])
    for i in values(result["id_map"]),components in (1:3,4:6)
        rows=6(i-1).+components
        phi[rows]=node_R[i]'*phi[rows]
    end
    phi
end

function sensitivity_eigen_mass(native,op)
    physical=native.Solver.assemble_mass(op.model,op.id_map,op.X,op.node_R,op.ndof)
    native.Solver._apply_constraint_congruence(physical,op.rbe3_map;expected_ndof=op.ndof)
end

function sensitivity_geometric_matrix(native,op,state;physical=false,geometric_capture=nothing)
    model=op.model;mapping=op.rbe3_map
    if physical
        # An empty prebuilt map alone is insufficient: native assembly rebuilds
        # it from cards. Keep geometry/formulation intact and remove only MPCs.
        model=copy(model)
        for key in ("RBE1s","RBE2s","RBE3s","RSPLINEs","MPCADDs")
            haskey(model,key)&&(model[key]=empty(model[key]))
        end
        haskey(model,"MPCs")&&(model["MPCs"]=empty(model["MPCs"]))
        pop!(model,"_active_mpc_id",nothing)
        mapping=Dict{Int,Vector{Tuple{Int,Float64}}}()
    end
    cc=model["CASE_CONTROL"]
    buckling_sid=only([sid for (sid,sub) in cc["SUBCASES"] if get(sub,"STATSUB",nothing)!==nothing])
    options=(;snorm_angle_override=native.Solver.sol105_snorm_angle_override(),
        buckling_subcase=buckling_sid,static_load_id=op.load_id)
    geometric_capture===nothing ? native.Solver.assemble_geometric_stiffness(model,op.id_map,op.X,op.node_R,op.ndof,state,
        op.snorm_normals,mapping;options...) : native.Solver.assemble_geometric_stiffness(model,op.id_map,op.X,op.node_R,op.ndof,state,
        op.snorm_normals,mapping;options...,geometric_capture)
end

"""Node supports of the physical geometric-stiffness derivative (before MPCs)."""
function sensitivity_geometric_supports(op)
    supports=[Set{Int}() for _ in 1:div(op.ndof,6)]
    function add(nodes)
        indices=[op.id_map[Int(n)] for n in nodes if haskey(op.id_map,Int(n))]
        for i in indices;union!(supports[i],indices);end
    end
    for key in ("CSHELLs","CSOLIDs"),el in values(get(op.model,key,Dict()))
        add(get(el,"NODES",Int[]))
    end
    for key in ("CBARs","CBEAMs","CRODs","CONRODs"),el in values(get(op.model,key,Dict()))
        add([el["GA"],el["GB"]])
    end
    supports
end

"""Greedy distance-two coloring gives disjoint derivative output supports."""
function sensitivity_support_colors(supports)
    owners=[Int[] for _ in supports]
    for (i,support) in enumerate(supports),j in support;push!(owners[j],i);end
    color=zeros(Int,length(supports));groups=Vector{Int}[]
    for i in sortperm(length.(supports);rev=true)
        isempty(supports[i])&&continue
        unavailable=Set{Int}()
        for j in supports[i],neighbor in owners[j]
            color[neighbor]>0&&push!(unavailable,color[neighbor])
        end
        c=1;while c in unavailable;c+=1;end
        c>length(groups)&&push!(groups,Int[])
        color[i]=c;push!(groups[c],i)
    end
    groups
end

function sensitivity_buckling_state_gradient(native,op,state,phi;progress=(_)->nothing,cancelled=()->false)
    supports=sensitivity_geometric_supports(op);colors=sensitivity_support_colors(supports)
    gradient=zeros(op.ndof);assemblies=0
    # Each component uses its physical state scale (metres or radians). The
    # native Kg is linear in preload on its smooth branch; central differences
    # also preserve any explicitly nonlinear recovery branch at this state.
    steps=[max(maximum(abs,state[c:6:end];init=0.)*1e-4,1e-8) for c in 1:6]
    for (ordinal,nodes) in enumerate(colors),component in 1:6
        cancelled()&&error("Sensitivity study cancelled")
        h=steps[component];plus=copy(state);minus=copy(state)
        for node in nodes;plus[6(node-1)+component]+=h;minus[6(node-1)+component]-=h;end
        delta=(sensitivity_geometric_matrix(native,op,plus;physical=true)-
            sensitivity_geometric_matrix(native,op,minus;physical=true))*phi/(2h)
        assemblies+=2
        for node in nodes
            # Colors are separated in the OUTPUT vector, not merely in input
            # DOFs. Summing scalar energies per color could not recover these.
            gradient[6(node-1)+component]=sum(phi[6(j-1)+c]*delta[6(j-1)+c] for j in supports[node] for c in 1:6)
        end
        progress(Dict("detail"=>"Buckling preload gradient: color $ordinal/$(length(colors)), component $component/6"))
    end
    # Independent mixed-direction test catches missing neighborhoods, MPC
    # leakage and a nonsmooth formulation switch, without a forward solve.
    direction=[sin(.731i)+cos(.193i) for i in eachindex(state)]
    for c in 1:6;direction[c:6:end].*=steps[c];end
    function directional(scale)
        plus=sensitivity_geometric_matrix(native,op,state.+scale.*direction;physical=true)
        minus=sensitivity_geometric_matrix(native,op,state.-scale.*direction;physical=true)
        dot(phi,(plus-minus)*phi)/(2scale)
    end
    direct=directional(1.);fine=directional(.5);assemblies+=4
    predicted=dot(gradient,direction)
    scale=max(abs(direct),abs(fine),sum(abs.(gradient.*direction))*1e-5,eps())
    relative_error=max(abs(predicted-fine),abs(direct-fine))/scale
    relative_error<=1e-4||throw(ArgumentError("Buckling preload derivative fails its directional consistency check ($relative_error); the active operator may be nonsmooth"))
    gradient,Dict("state_colors"=>length(colors),"geometric_assemblies"=>assemblies,
        "state_gradient_directional_error"=>relative_error,"state_dofs"=>count(!isempty,supports)*6)
end

"""Exact coefficients of an affine physical geometric operator.

Unit states evaluate the operator's linear basis, without perturbing a property
or using a finite-difference step. Independent affine identities at the actual
preload and mixed signed states guard against nonlocal or nonlinear branches.
"""
function sensitivity_buckling_state_gradient_analytic(native,op,state,phi;progress=(_)->nothing,cancelled=()->false)
    supports=sensitivity_geometric_supports(op);colors=sensitivity_support_colors(supports)
    gradient=zeros(op.ndof);zero_state=zeros(op.ndof)
    cancelled()&&error("Sensitivity study cancelled")
    zero_matrix=sensitivity_geometric_matrix(native,op,zero_state;physical=true)
    zero_action=zero_matrix*phi;assemblies=1
    for (ordinal,nodes) in enumerate(colors),component in 1:6
        cancelled()&&error("Sensitivity study cancelled")
        unit_state=zeros(op.ndof)
        for node in nodes;unit_state[6(node-1)+component]=1.;end
        action=sensitivity_geometric_matrix(native,op,unit_state;physical=true)*phi-zero_action
        assemblies+=1
        for node in nodes
            gradient[6(node-1)+component]=sum(phi[6(j-1)+c]*action[6(j-1)+c] for j in supports[node] for c in 1:6)
        end
        progress(Dict("detail"=>"Exact buckling preload influence: color $ordinal/$(length(colors)), component $component/6"))
    end
    mixed=[sin(.731i)+cos(.193i) for i in eachindex(state)]
    for component in 1:6
        # These are independent physical test states, not derivative steps.
        mixed[component:6:end].*=max(maximum(abs,state[component:6:end];init=0.),1e-3)
    end
    q0=dot(phi,zero_action);errors=Float64[]
    for test_state in (state,2.3 .* state,mixed,state .- .71 .* mixed)
        cancelled()&&error("Sensitivity study cancelled")
        actual=dot(phi,sensitivity_geometric_matrix(native,op,test_state;physical=true)*phi)
        predicted=q0+dot(gradient,test_state);assemblies+=1
        scale=max(abs(actual),abs(predicted),sum(abs.(gradient.*test_state))*1e-6,eps())
        push!(errors,abs(actual-predicted)/scale)
    end
    relative_error=maximum(errors)
    relative_error<=1e-8||throw(ArgumentError("Analytic buckling preload requires an affine, element-local geometric operator; its affine replay failed ($relative_error). The active nonlinear recovery branch is unsupported."))
    gradient,Dict("state_gradient_method"=>"exact_unit_influence","state_colors"=>length(colors),
        "geometric_assemblies"=>assemblies,"state_gradient_affine_error"=>relative_error,
        "state_dofs"=>count(!isempty,supports)*6)
end

function sensitivity_eigen_context(native,result,wing,objective;progress=(_)->nothing,cancelled=()->false,analytic=false)
    kind=objective["type"];sol=kind=="frequency_eigenvalue" ? 103 : 105
    selected=sensitivity_response(result,wing,objective)
    op=sensitivity_assemble(native,result["model"];solution=sol,analytic)
    op.id_map==result["id_map"]||error("Eigenvalue adapter changed the native GRID ordering")
    # Native SOL103 exports its eigenpairs and model but does not retain K.
    # Its assembled pencil is verified below against the actual eigenvector.
    haskey(result,"K")&&sensitivity_eigen_matrix_check(op.K,result["K"],"Eigenvalue static stiffness")
    physical_phi=sensitivity_mode_analysis(result,selected.mode,op.node_R)
    phi=zeros(op.ndof);phi[op.free]=physical_phi[op.free]
    reconstructed_phi=sensitivity_expand_state(op,op.free,phi[op.free])
    mode_constraint_error=norm(reconstructed_phi-physical_phi)/max(norm(physical_phi),eps())
    mode_constraint_error<1e-9||error("The selected mode does not obey its reconstructed native MPC/support partition ($mode_constraint_error)")
    lambda=selected.value;diagnostics=Dict{String,Any}("forward_solves"=>1,"perturbed_forward_solves"=>0,
        "adjoint_solves"=>0,"operator_assemblies"=>1,"selected_mode"=>selected.mode,
        "relative_eigenvalue_gap"=>isfinite(selected.gap) ? selected.gap : nothing,
        "mode_constraint_replay_relative_error"=>mode_constraint_error)
    ctx=Dict{String,Any}("kind"=>kind,"op"=>op,"phi"=>phi,"physical_phi"=>physical_phi,
        "lambda"=>lambda,"diagnostics"=>diagnostics,"baseline"=>selected,
        "solver_counts"=>Dict("forward_solves"=>1,"perturbed_forward_solves"=>0,"adjoint_solves"=>0,"eigen_solves"=>1,"operator_evaluations"=>2))
    if sol==103
        mass=sensitivity_eigen_mass(native,op);denominator=dot(phi,mass*phi)
        denominator>0||error("The selected mode has zero or negative generalized mass")
        # Both native eigensolvers symmetrize the assembled pencil. Quadratic
        # contractions already use that symmetric part; replay must do so too.
        elastic=(op.K*phi+op.K'*phi)./2;inertial=(mass*phi+mass'*phi)./2
        residual=norm((elastic-lambda.*inertial)[op.free])/max(norm(elastic[op.free]),eps())
        residual<1e-5||error("The selected eigenvector does not match the assembled modal pencil ($residual)")
        ctx["denominator"]=denominator;ctx["mass"]=mass;diagnostics["eigen_residual"]=residual
        ctx["baseline_sample"]=dot(phi,(op.K-lambda.*mass)*phi)/denominator
        diagnostics["operator_assemblies"]+=1
        return ctx
    end
    sensitivity_eigen_matrix_check(op.K,result["K_eig"],"Buckling eigen stiffness")
    state=Float64.(result["u_static"])
    Set(op.fixed)==Set(result["fixed_dofs"])||error("Buckling preload automatic support partition changed")
    expanded=sensitivity_expand_state(op,op.free,state[op.free])
    norm(expanded-state)<=1e-10max(norm(state),eps())||error("Buckling preload constraint reconstruction differs from the baseline")
    forward_residual=norm(op.A[op.free,op.free]*state[op.free]-op.F[op.free])/max(norm(op.F[op.free]),eps())
    forward_residual<1e-6||error("Buckling preload replay does not satisfy equilibrium ($forward_residual)")
    kg=sensitivity_geometric_matrix(native,op,state)
    sensitivity_eigen_matrix_check(kg,result["Kg"],"Buckling geometric stiffness")
    denominator=dot(phi,kg*phi)
    abs(denominator)>eps()*norm(phi)*norm(kg*phi)||error("The selected buckling mode has a singular geometric denominator")
    elastic=(op.K*phi+op.K'*phi)./2;geometric=(kg*phi+kg'*phi)./2
    residual=norm((elastic+lambda.*geometric)[op.free])/max(norm(elastic[op.free]),eps())
    residual<1e-5||error("The selected eigenvector does not match the assembled buckling pencil ($residual)")
    physical_kg=sensitivity_geometric_matrix(native,op,state;physical=true)
    replay=native.Solver._apply_constraint_congruence(physical_kg,op.rbe3_map;expected_ndof=op.ndof)
    constraint_error=sensitivity_eigen_matrix_check(replay,kg,"Physical geometric stiffness MPC congruence")
    if analytic
        gradient,details,geometric_contexts=sensitivity_buckling_state_gradient_captured(native,op,wing,state,physical_phi;progress,cancelled)
        ctx["geometric_contexts"]=geometric_contexts
    else
        gradient,details=sensitivity_buckling_state_gradient(native,op,state,physical_phi;progress,cancelled)
    end
    rhs=native.Solver._adjoint_reduce_rhs(lambda.*gradient,op.rbe3_map)
    adjoint=zeros(op.ndof);adjoint[op.free]=op.A[op.free,op.free]'\rhs[op.free]
    adjoint_residual=norm((op.A'*adjoint-rhs)[op.free])/max(norm(rhs[op.free]),eps())
    adjoint_residual<1e-7||error("Buckling preload adjoint did not converge ($adjoint_residual)")
    merge!(diagnostics,details);diagnostics["adjoint_solves"]=1
    diagnostics["operator_assemblies"]+=details["geometric_assemblies"]+2
    diagnostics["eigen_residual"]=residual;diagnostics["adjoint_residual"]=adjoint_residual
    diagnostics["forward_replay_residual"]=forward_residual;diagnostics["constraint_replay_relative_error"]=constraint_error
    ctx["denominator"]=denominator;ctx["state"]=state;ctx["adjoint"]=adjoint
    ctx["baseline_sample"]=-(dot(phi,(op.K+lambda.*kg)*phi)+
        dot(adjoint[op.free],op.F[op.free]-op.A[op.free,op.free]*state[op.free]))/denominator
    ctx["solver_counts"]["adjoint_solves"]=1
    ctx["solver_counts"]["operator_evaluations"]=diagnostics["operator_assemblies"]
    ctx
end

function sensitivity_eigen_sample(native,ctx,path,wing)
    kind=ctx["kind"];sol=kind=="frequency_eigenvalue" ? 103 : 105
    op=sensitivity_assemble(native,native.bdf_to_model(path);solution=sol)
    sensitivity_check_operators(ctx["op"],op)
    phi=ctx["phi"];lambda=ctx["lambda"];denominator=ctx["denominator"]
    if sol==103
        mass=sensitivity_eigen_mass(native,op)
        value=dot(phi,(op.K-lambda.*mass)*phi)/denominator
    else
        state=ctx["state"];kg=sensitivity_geometric_matrix(native,op,state)
        # L = -(phi'(Ke+lambda Kg)phi + psi'(F-Ks u))/phi'Kg phi.
        # Holding u, phi and psi fixed differentiates both explicit material
        # terms and the static equilibrium dependency with one adjoint solve.
        free=op.free
        correction=dot(ctx["adjoint"][free],op.F[free]-op.A[free,free]*state[free])
        value=-(dot(phi,(op.K+lambda.*kg)*phi)+correction)/denominator
    end
    isfinite(value)||error("The eigenvalue adjoint contraction is nonfinite")
    Dict{String,Any}("value"=>value,"operator_assemblies"=>2,"operator_evaluations"=>2,"forward_solves"=>0)
end
