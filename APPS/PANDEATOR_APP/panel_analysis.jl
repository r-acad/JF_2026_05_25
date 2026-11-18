# Generated-panel buckling and exact discrete adjoints. All dimensions use the
# generator's consistent N/mm/MPa system. Finite differences are an independent
# validation operation and are never used to construct a reported adjoint.
module PandeatorAnalysis
using LinearAlgebra, SparseArrays
import ForwardDiff, OpenJFEM, WingFEGen, JSON
const W=WingFEGen
const S=OpenJFEM.Solver
const F=S.FEM
const ModelAPI=getfield(parentmodule(@__MODULE__),:PandeatorModel)

getp(m,k,d=nothing)=get(m.params,k,d)
number(x)=x isa Real&&isfinite(x)
spectral_status(no_demand,cluster,approximation)=no_demand ? "no_demand" : cluster ? "cluster" : approximation ? "approximation" : "ok"
function public_value(x)
    x isa AbstractDict&&return Dict(string(k)=>public_value(v) for (k,v) in x if !startswith(string(k),"_")&&!(v isa Function))
    x isa NamedTuple&&return Dict(string(k)=>public_value(v) for (k,v) in pairs(x) if !(v isa Function))
    x isa AbstractMatrix&&return [public_value(collect(row)) for row in eachrow(x)]
    x isa AbstractVector&&return public_value.(x)
    x isa Tuple&&return public_value.(collect(x))
    x isa Real&&return isfinite(x) ? x : nothing
    x
end
function save_json(path,data)
    mkpath(dirname(path));write(path,JSON.json(public_value(data)))
end
function announce(progress,phase,detail;kwargs...)
    progress(merge(Dict{String,Any}("phase"=>phase,"detail"=>detail,"log_message"=>detail),Dict(string(k)=>v for (k,v) in kwargs)))
end

# Only production-kernel inputs are copied, not the assembly's global triplets.
const KG_KEYS=unique(vcat(W.SENSITIVITY_GEOMETRIC_KEYS,Symbol.(split("""
Cm_override Cb_kg Cs_kg Bmb_kg coords3d_local_buf4 kg_coupled_normal_moment
kg_flat_uncoupled_pcomp_assumed kg_projected_snorm_assumed corner_map_kg
kg_reference_offset_differential projected_offset_map_kg offset_grid_preload
zoffs_kg kg_axis_mode_eff flat_pcomp_rect_adini kg_pcomp_axis_mode_override
kg_projected_pcomp_frame kg_normal_moment_differential kg_pshell_differential
"""))))

function capture_geometric(op,u)
    contexts=Dict{Int,Any}();guard=ReentrantLock()
    capture=(eid,locals)->lock(guard) do
        ctx=Dict(k=>deepcopy(locals[k]) for k in KG_KEYS if haskey(locals,k))
        ctx[:eid]=eid;ctx[:model]=op.model
        contexts[eid]=ctx
    end
    kg=W.sensitivity_geometric_matrix(OpenJFEM,op,u;physical=true,geometric_capture=capture,geometric_capture_scope=Val(:full))
    length(contexts)==length(op.model["CSHELLs"])||error("Geometric capture omitted a generated panel shell")
    (;contexts,kg)
end

function shell_law(ctx,elastic,direction,x)
    c=S.analytic_shell_constitutive(ctx[:model],ctx[:pid],direction,x)
    A=S._as_rotate_law(c.Cm,elastic.membrane_rotation)
    B=S._as_rotate_law(c.Bmb,elastic.membrane_rotation)
    D=S._as_rotate_law(c.Cb,elastic.bending_rotation)
    Cs=S._as_rotate_shear(c.Cs,elastic.bending_rotation)
    if x isa AbstractFloat&&iszero(x)
        for (name,actual,predicted) in (("membrane",get(ctx,:Cm_override,nothing),A),
                                      ("bending",get(ctx,:Cb_kg,nothing),D),
                                      ("coupling",get(ctx,:Bmb_kg,nothing),B))
            actual===nothing&&continue
            norm(actual-predicted)<=2e-9max(norm(actual),norm(predicted),eps())||
                throw(ArgumentError("Panel shell $(ctx[:eid]) $name material axes differ between elastic and geometric operators"))
        end
    end
    (;c,A,B,D,Cs)
end

"""Replay the actual resolved Q4 prestress kernel on a canonical panel facet.

This extends the checked Boxer path to full CLT differential/condensed sections;
native recovery, quadrature, assumed-gradient and coordinate pullbacks remain.
Research overrides not represented by this replay are rejected, never replaced.
"""
function geometric_replay(ctx,elastic,direction=Dict(),x=0.;local_state=nothing)
    g(k,d=nothing)=get(ctx,k,d);eid=g(:eid)
    g(:n)==4||throw(ArgumentError("Generated panel adjoints require conforming CQUAD4 facets"))
    g(:kg_global_ready,false)&&throw(ArgumentError("Panel adjoint does not support a global-frame research geometric operator"))
    for key in (:kg_covariant_branch,:elem_mitc4_3d_kg_recovery,:kg_coupled_projected,:kg_reference_offset_differential)
        g(key,false)&&throw(ArgumentError("Panel adjoint cannot replay the selected $key operator; no derivative was approximated"))
    end
    g(:projected_offset_map_kg,nothing)===nothing||throw(ArgumentError("Use the canonical PCOMP reference plane instead of CQUAD4 ZOFFS"))
    any(g(k,1.)!=1 for k in (:principal_shear_yy_factor_eff,:principal_shear_xy_factor_eff,:principal_shear_z_factor_eff))&&
        throw(ArgumentError("Stress-dependent principal-shear research scaling is not differentiable by the canonical panel replay"))
    law=shell_law(ctx,elastic,direction,x);c,A,B,D,Cs=law.c,law.A,law.B,law.D,law.Cs
    u=local_state===nothing ? g(:u_elem24) : local_state
    directional_coupling=eltype(B)<:ForwardDiff.Dual&&any(v->any(!iszero,ForwardDiff.partials(v)),B)
    coupling=g(:Bmb_kg,nothing)===nothing&&!directional_coupling ? nothing : B
    if g(:kg_reference_kdjj_iso_branch,false)
        warp=g(:warp_preload_map,nothing);ue=warp===nothing ? u : warp*u
        K=F.geometric_stiffness_quad4_reference_kdjj_iso(g(:lc_buf4),ue,c.E,c.nu,c.h;
            assumed_transverse=g(:assumed_transverse,false))
    else
        Ngp,Nres,_=if g(:kg_differential_prestress,false)
            F.quad4_differential_membrane_force_field(g(:lc_buf4),u,A,coupling;
                coords_3d=g(:coords3d_local_buf4),
                snorm_pq=g(:kg_coupled_normal_moment,false)&&coupling!==nothing ? g(:snorm_pq_kg) : nothing)
        elseif g(:kg_coupled_condensed,false)
            F.quad4_coupled_membrane_force_field(g(:lc_buf4),u,A,coupling,D,Cs,c.h,c.E;
                bending_incomp=S.solver_env_bool("JFEM_Q4_STATIC_BENDING_INCOMP",true),
                membrane_incomp=S.sol105_static_membrane_incomp_enabled(),
                membrane_incomp_center_jacobian=g(:membrane_incomp_center_jacobian),
                material_shear_rotation=g(:kg_material_shear_rotation),coords_3d=g(:coords3d_local_buf4),
                bend_ratio=g(:br,1.),k6rot=0.,kernel_mode=get(ENV,"JFEM_Q4_KERNEL_STATIC",get(ENV,"JFEM_Q4_KERNEL","macneal")))
        else
            g(:kg_membrane_recovery_mode) in (:tri_aspect,:tri_center_adj,:tri_incident_interp,:tri_diagavg)&&
                throw(ArgumentError("Triangle-recovery research overrides are unsupported by panel sensitivities"))
            selc=g(:kg_membrane_selc,false);enhanced=g(:kg_iso_exact_membrane,false)
            modes=(S.solver_env_bool("JFEM_KG_RECOVERY_CROSS_MEMBRANE_WEIGHTS",false)&&g(:elem_is_flat_kg,false)&&coupling===nothing&&!selc) ? (0.,1.,1.,0.) : nothing
            F.quad4_membrane_force_field(g(:lc_buf4),u,c.E,c.nu,c.h;
                Cm_override=g(:is_pcomp_clt,false) ? A : nothing,Bmb=coupling,
                slope_membrane=g(:slope_membrane_kg),compatible_only=g(:kg_compatible_membrane,false),
                use_incompatible_modes=g(:elem_membrane_incomp_kg,false)&&!enhanced&&!selc,
                use_enhanced_modes=enhanced,curvature_membrane=g(:curvature_membrane),
                membrane_shear_center_row=selc,material_shear_rotation=selc ? 0. : g(:kg_material_shear_rotation,0.),
                membrane_incomp_center_jacobian=g(:membrane_incomp_center_jacobian),mode_weights=modes,
                snorm_pq=g(:snorm_pq_kg),coords_3d=g(:coords3d_local_buf4))
        end
        mode=g(:stress_mode_label,"");occursin("auto_blend",mode)&&
            throw(ArgumentError("Stress-dependent GP auto-blending is unsupported by the panel adjoint"))
        alpha=occursin("pminavg",mode) ? g(:gp_blend_alpha) : mode=="override_blend" ?
            g(:gp_blend_override) : mode=="gauss_extrapolate" ? g(:kg_gp_extrapolate_scale) : nothing
        N=alpha!==nothing ? alpha.*Ngp.+(1-alpha).*transpose(Nres) :
            startswith(mode,"gauss")||mode=="GRID-reference differential quadrature" ? Ngp :
            mode in ("average","shear_average") ? Nres : throw(ArgumentError("Unknown panel prestress recovery mode $mode"))
        sigma=N./c.h
        if g(:is_pcomp_clt,false)
            S.kg_shell_apply_pcomp_nxy_scale!(sigma,g(:kg_shell_pcomp_nxy_eff,g(:kg_shell_pcomp_nxy,1.)),
                g(:kg_shell_pcomp_nxy_compression_only_v,false))
        end
        if g(:kg_reference_kdjj_pcomp_branch,false)
            raw=lowercase(strip(get(ENV,"JFEM_SOL105_PCOMP_KDJJ_FIELD","")))
            usegp=raw=="gp"||(isempty(raw)&&g(:kg_membrane_selc,false))
            field=usegp ? Ngp : repeat(transpose(Nres),4,1)
            K=F.geometric_stiffness_quad4_reference_kdjj_pcomp_field(g(:lc_buf4),field)
        elseif g(:kg_flat_dkmq_branch,false)
            K=F.geometric_stiffness_quad4_plate_dkmq(g(:lc_buf4),sigma,c.h,D,Cs)
        elseif g(:kg_flat_plate_branch,false)
            K=g(:flat_pcomp_rect_adini,false)&&F.quad4_is_axis_aligned_rectangle(g(:lc_buf4)) ?
                F.geometric_stiffness_quad4_plate_adini(g(:lc_buf4),sigma,c.h) :
                F.geometric_stiffness_quad4_plate_dkq(g(:lc_buf4),sigma,c.h,D,Cs)
        else
            K=F.geometric_stiffness_quad4(g(:lc_buf4),sigma,c.h;
                trans_mode=g(:kg_trans_mode_eff),curvature=g(:kg_curvature),curvature_sign=g(:kg_curvature_sign_eff),
                membrane_shear_center_row=g(:kg_membrane_shear_center_row,false),Cm=A,
                membrane_incomp=g(:kg_consistent_membrane_incomp,false)&&!g(:kg_iso_exact_membrane,false),
                membrane_enhanced=g(:kg_iso_exact_membrane,false),material_shear_rotation=g(:kg_material_shear_rotation,0.),
                membrane_incomp_center_jacobian=g(:membrane_incomp_center_jacobian),
                principal_shear_yy_factor=1.,principal_shear_xy_factor=1.,principal_shear_z_factor=1.,
                principal_shear_ratio_min=g(:principal_shear_ratio_min_eff,1.))
            assumed=g(:kg_coupled_condensed,false)||g(:kg_flat_uncoupled_pcomp_assumed,false)||g(:kg_differential_prestress,false)
            if assumed&&g(:kg_trans_mode_eff)===:principal_transverse&&
                    lowercase(strip(get(ENV,"JFEM_KG_SHELL_TRANSVERSE_W_FORM","w")))=="w"&&!S.solver_env_bool("JFEM_KG_SHELL_LOCAL_TRANS_SPLIT",false)
                F.add_quad4_assumed_transverse_gradient_delta!(K,g(:lc_buf4),sigma,c.h)
            end
        end
    end
    if g(:kg_shell_drill_zero,false)
        for dof=6:6:24;K[dof,:].=zero(eltype(K));K[:,dof].=zero(eltype(K));end
    end
    corner=g(:corner_map_kg,nothing)
    if corner!==nothing
        K=transpose(corner)*K*corner
    else
        snorm=g(:snorm_pq_kg,nothing)
        if snorm!==nothing
            if F.quad4_snorm_normal_moment_mode()
                relative=g(:snorm_relative_pq_kg,nothing)
                relative===nothing||F.apply_quad4_snorm_normal_moment_completion!(K,g(:lc_buf4),relative)
            else
                F.apply_quad4_snorm_director_completion!(K,snorm)
            end
        end
        g(:apply_finite_warp_kg,false)&&F.apply_quad4_finite_warp_equilibrium!(K,g(:lc_buf4),g(:coords3d_local_buf4))
    end
    transpose(g(:T_buf))*K*g(:T_buf)
end

function geometric_check(ctx,elastic)
    replay=geometric_replay(ctx,elastic)
    error=norm(replay-ctx[:Kg_global])/max(norm(ctx[:Kg_global]),eps())
    error<=3e-9||throw(ArgumentError("Panel geometric kernel $(ctx[:eid]) failed native parity ($error); no adjoint is reported"))
    error
end

function catalog(m)
    rows=Any[]
    for variable in ModelAPI.panel_variables(m)
        id=variable["id"];label=variable["label"];composite=startswith(id,"scale")
        directions=ModelAPI.panel_property_directions(m,id)
        isempty(directions)&&continue
        value=Float64(getp(m,id,1.))
        push!(rows,Dict("id"=>id,"label"=>label*(composite ? " scale" : ""),"value"=>value,
            "unit"=>composite ? "1" : "mm","min"=>max(value*1e-4,1e-8),"max"=>value*10,
            "pids"=>sort!([pid for (pid,d) in directions if !iszero(get(d,"thickness",0.))||!iszero(get(d,"z0",0.))]),"fixed_topology"=>true))
    end
    Dict("variables"=>rows,"note"=>"Thickness/laminate-scale derivatives retain nodes, connectivity and support frames. Geometry changes rebuild the mesh and are outside this fixed-topology catalog.")
end

function solve_forward(m,directory,tag;progress, cancelled,sol105=true)
    cancelled()&&throw(InterruptException())
    dir=joinpath(directory,tag);mkpath(dir);path=joinpath(dir,"panel.bdf")
    deck=ModelAPI.panel_bdf(m)
    if !sol105
        bulk=split(deck,"BEGIN BULK";limit=2)[2]
        deck="SOL 101\nCEND\nTITLE = Conforming stiffened panel preload\nECHO = NONE\nSUBCASE 1\n  SPC = 10\n  LOAD = 20\n  DISPLACEMENT(PLOT) = ALL\nBEGIN BULK"*bulk
    end
    write(path,deck)
    announce(progress,"forward",sol105 ? "Solving $tag: static preload and SOL105 buckling" : "Solving $tag: static preload only (no unrequested eigenproblem)")
    started=time_ns();parsed=OpenJFEM.bdf_to_model(path);answer=OpenJFEM.solve_model(parsed)
    elapsed=(time_ns()-started)*1e-9
    (;model=m,path,forward=answer,seconds=elapsed)
end

function operator_context(forward;need_geometric=true,derivatives=true)
    if !derivatives
        # The baseline/FD forward already assembled and solved these matrices.
        # Recovery does not need a second elastic or geometric assembly.
        model=forward["model"];state=need_geometric ? forward : only(forward["subcases"])
        id_map=forward["id_map"];X=forward["node_coords"];node_R=forward["node_R"];ndof=forward["ndof"]
        K=forward["K"];fixed=sort!(collect(state["fixed_dofs"]));free=setdiff(collect(1:ndof),fixed)
        sub=W.sensitivity_preload_subcase(model["CASE_CONTROL"]["SUBCASES"],need_geometric ? 105 : 101)
        load_id=sub["LOAD"];rbe3_map=get(forward,"rbe3_map",Dict())
        Fload=S._assemble_applied_force(ndof,model,id_map,X,load_id,node_R,rbe3_map;log_rbe3=false)
        snorm=need_geometric ? S.sol105_snorm_angle_override() : nothing
        override=snorm===nothing ? get(ENV,"JFEM_PARAM_SNORM_OVERRIDE_STATIC",get(ENV,"JFEM_PARAM_SNORM_OVERRIDE","")) : string(snorm)
        snorm_model=isempty(strip(override)) ? model : merge(copy(model),Dict("PARAM_SNORM"=>something(tryparse(Float64,override),get(model,"PARAM_SNORM",0.))))
        snorm_normals=S.compute_snorm_normals(snorm_model,id_map,X)
        op=(;model,K,A=K,F=Fload,id_map,X,ndof,node_R,rbe3_map,snorm_normals,load_id,free,fixed)
        u=Float64.(need_geometric ? forward["u_static"] : state["u_analysis"])
        residual=norm((K*u-Fload)[free])/max(norm(Fload[free]),eps())
        residual<=1e-6||error("Native forward static residual is too large ($residual)")
        return (;op,u,geometric=Dict{Int,Any}(),factor=nothing,diagnostics=Dict("preload_residual"=>residual,"reused_forward_operators"=>true))
    end
    op=W.sensitivity_assemble(OpenJFEM,deepcopy(forward["model"]);solution=need_geometric ? 105 : 101,analytic=true)
    for (key,label) in (need_geometric ? (("K","static"),("K_eig","eigen")) : (("K","static"),))
        W.sensitivity_eigen_matrix_check(op.K,forward[key],"Panel $label stiffness";rtol=2e-9)
    end
    state=need_geometric ? forward : only(forward["subcases"])
    Set(op.fixed)==Set(state["fixed_dofs"])||error("Panel adjoint changed the native support partition")
    u=Float64.(need_geometric ? forward["u_static"] : state["u_analysis"])
    state_residual=norm((op.A*u-op.F)[op.free])/max(norm(op.F[op.free]),eps())
    state_residual<=1e-6||error("Panel static preload residual is too large ($state_residual)")
    captured=need_geometric ? capture_geometric(op,u) : (;contexts=Dict{Int,Any}())
    replay=0.
    if need_geometric
        W.sensitivity_eigen_matrix_check(captured.kg,forward["Kg"],"Panel geometric stiffness";rtol=2e-9)
        replay=maximum(geometric_check(ctx,op.shell_capture.contexts[eid]) for (eid,ctx) in captured.contexts)
    end
    (;op,u,geometric=captured.contexts,factor=lu(op.A[op.free,op.free]),
        diagnostics=Dict("preload_residual"=>state_residual,"geometric_kernel_replay_error"=>replay))
end

function physical_modes(forward)
    values=Float64.(forward["eigenvalues"]);raw=Matrix{Float64}(forward["_raw_mode_shapes"])
    values,raw
end
function mode_analysis(ctx,forward,index)
    phi=Float64.(forward["_raw_mode_shapes"][:,index])
    for i in values(ctx.op.id_map),components in (1:3,4:6)
        rows=6(i-1).+components;phi[rows]=transpose(ctx.op.node_R[i])*phi[rows]
    end
    phi
end
function mode_mac(a,b)
    ids=[i for i in eachindex(a) if mod1(i,6)<=3]
    x=a[ids];y=b[ids];den=dot(x,x)*dot(y,y)
    den>0 ? dot(x,y)^2/den : 0.
end

function force_direction(m,variable,op)
    loads=ModelAPI.panel_load_direction(m,variable)
    result=zeros(op.ndof)
    for (id,vector) in loads
        i=op.id_map[Int(id)];result[6i-5:6i-3].=transpose(op.node_R[i])*vector
    end
    result
end

function design_column(m,id,ctx)
    directions=ModelAPI.panel_property_directions(m,id)
    residual=zeros(ctx.op.ndof);elastic=Dict{Int,Any}();geometric=Dict{Int,Any}();maxreplay=0.
    for (eid,shell) in ctx.op.shell_capture.contexts
        direction=get(directions,Int(shell.pid),nothing);direction===nothing&&continue
        tangent=S.analytic_shell_tangent(shell,direction)
        elastic[eid]=tangent;residual[tangent.dofs].+=tangent.dKe*ctx.u[tangent.dofs]
        if haskey(ctx.geometric,eid)
            jet=geometric_replay(ctx.geometric[eid],shell,direction,ForwardDiff.Dual(0.,1.))
            geometric[eid]=map(x->ForwardDiff.partials(x)[1],jet)
        end
        maxreplay=max(maxreplay,tangent.replay_error)
    end
    fp=force_direction(m,id,ctx.op)
    (;directions,elastic,geometric,fp,residual=residual-fp,maxreplay)
end

function eigen_response(m,forward,ctx,index,columns;progress,cancelled)
    lambda=Float64(forward["eigenvalues"][index]);phi=mode_analysis(ctx,forward,index);policy=getp(m,"buckling_policy_factor",1.)
    denominator=dot(phi,forward["Kg"]*phi)
    abs(denominator)>eps()*norm(phi)*norm(forward["Kg"]*phi)||error("Singular panel geometric normalization")
    residual=norm(((ctx.op.K+lambda*forward["Kg"])*phi)[ctx.op.free])/max(norm((ctx.op.K*phi)[ctx.op.free]),eps())
    residual<1e-5||error("Panel mode $index has an unacceptable eigen residual $residual")
    gap=minimum((abs(lambda-v)/max(abs(lambda),abs(v),eps()) for (j,v) in enumerate(forward["eigenvalues"]) if j!=index);init=Inf)
    if gap<=1e-5
        return Dict("id"=>"sol105_mode_$index","label"=>"SOL105 mode $index · RF","kind"=>"sol105","value"=>lambda/policy,"raw_lambda"=>lambda,"unit"=>"RF",
            "status"=>"cluster","method"=>"Native SOL105 eigenproblem","diagnostics"=>Dict("eigen_residual"=>residual,"relative_gap"=>gap),
            "sensitivities"=>Any[],"note"=>"A repeated/near-repeated individual mode has no unique scalar derivative. Refine geometry or assess the whole eigen-subspace; no arbitrary ordered-mode derivative is reported.")
    end
    announce(progress,"adjoint","Preparing mode $index preload adjoint")
    gradient=zeros(ctx.op.ndof)
    for (eid,g) in ctx.geometric
        cancelled()&&throw(InterruptException())
        elastic=ctx.op.shell_capture.contexts[eid];dofs=elastic.dofs;pe=phi[dofs]
        gradient[dofs].+=ForwardDiff.gradient(v->dot(pe,geometric_replay(g,elastic;local_state=g[:T_buf]*v)*pe),ctx.u[dofs])
    end
    adjoint=zeros(ctx.op.ndof);adjoint[ctx.op.free]=transpose(ctx.factor)\(lambda.*gradient[ctx.op.free])
    adjres=norm((transpose(ctx.op.A)*adjoint-lambda.*gradient)[ctx.op.free])/max(norm(lambda.*gradient[ctx.op.free]),eps())
    adjres<1e-7||error("Mode preload adjoint residual $adjres is unacceptable")
    sensitivities=Any[]
    for (id,column) in columns
        kp=gp=0.
        for (eid,tangent) in column.elastic
            pe=phi[tangent.dofs];kp+=dot(pe,tangent.dKe*pe);gp+=dot(pe,column.geometric[eid]*pe)
        end
        value=-(kp+lambda*gp-dot(adjoint,column.residual))/denominator/policy
        push!(sensitivities,Dict("variable_id"=>id,"value"=>value,"adjoint"=>value,"status"=>"ok","method"=>"Exact discrete eigen/preload adjoint"))
    end
    Dict("id"=>"sol105_mode_$index","label"=>"SOL105 mode $index · RF","kind"=>"sol105","value"=>lambda/policy,"raw_lambda"=>lambda,"unit"=>"RF","status"=>"ok",
        "method"=>"Native SOL105 plus one preload adjoint; exact element constitutive AD",
        "diagnostics"=>Dict("eigen_residual"=>residual,"adjoint_residual"=>adjres,"relative_gap"=>gap,"perturbed_forward_solves"=>0),
        "sensitivities"=>sensitivities,"_vector"=>Float64.(forward["_raw_mode_shapes"][:,index]))
end

const FORCE_FIELDS=("fx","fy","fxy","mx","my","mxy")
feature_key(eid,field)=Dict("case_id"=>1,"eid"=>eid,"quantity"=>"force","path"=>[field],"native_frame"=>true)

"""Actual native recovery in element axes; optional exact linear pullbacks."""
function recovery_context(m,ctx;derivatives=false,progress,cancelled)
    wing=(;groups=Any[])
    recovery=(;op=ctx.op,wing,expanded=ctx.u,recovery_cache=Dict{Any,Any}(),
        recovery_index=W.rf_build_recovery_index(OpenJFEM,ctx.op,wing),recovery_targets=Dict{Int,Any}())
    elements=sort(m.elements;by=e->e["eid"]);keys=Any[];values=Float64[]
    for (i,element) in enumerate(elements)
        cancelled()&&throw(InterruptException())
        eid=element["eid"];selected=[feature_key(eid,field) for field in FORCE_FIELDS];append!(keys,selected)
        if derivatives
            W.rf_prepare_recovery!(OpenJFEM,recovery,selected)
            append!(values,[W.rf_feature_influence(OpenJFEM,recovery,k).value for k in selected])
        else
            target=W.rf_recovery_target(OpenJFEM,recovery,eid)
            record=W.rf_recovery_record(OpenJFEM,recovery,target,ctx.u,"force";native_frame=true)
            append!(values,[W.rf_path_value(record,[field]) for field in FORCE_FIELDS])
        end
        (i==1||i==length(elements)||i%50==0)&&announce(progress,"recovery","Recovering panel membrane forces and moments · $i / $(length(elements)) elements")
    end
    (;recovery,elements,keys,values,index=Dict(e["eid"]=>i for (i,e) in enumerate(elements)))
end

law(m,ctx,pid,directions,x)=S.analytic_shell_constitutive(ctx.op.model,pid,get(directions,pid,Dict()),x)
abd(c)=[c.Cm c.Bmb;transpose(c.Bmb) c.Cb]
effective_bending(c)=c.Cb-transpose(c.Bmb)*(c.Cm\c.Bmb)

function section_law(m,ctx,pid,directions,x;component=nothing)
    c=law(m,ctx,pid,directions,x)
    component===nothing&&return abd(c)
    metadata=m.properties[pid]["layers"]
    T=typeof(c.h);A=zeros(T,3,3);B=copy(A);D=copy(A)
    if isempty(c.plies)
        # PSHELL combines only same-material isotropic layers, with the exact
        # centered physical stack retained in the generator metadata.
        z=-c.h/2;direction=get(directions,pid,Dict());dlayers=get(direction,"layers",Any[])
        for (i,p) in enumerate(metadata)
            dt=isempty(dlayers) ? 0. : dlayers[i]["thickness"]
            top=z+p["thickness"]+x*dt
            if p["component"]==component
                Q=c.Cm/c.h;A.+=Q*(top-z);B.+=Q*(top^2-z^2)/2;D.+=Q*(top^3-z^3)/3
            end
            z=top
        end
    else
        length(metadata)==length(c.plies)||error("Physical PCOMP stack membership differs from the generator")
        for (p,source) in zip(c.plies,metadata)
            source["component"]==component||continue
            z=p["z_bot"];top=p["z_top"];Q=p["Qbar"]
            A.+=Q*(top-z);B.+=Q*(top^2-z^2)/2;D.+=Q*(top^3-z^3)/3
        end
    end
    [A B;transpose(B) D]
end

function axial_section_law(H)
    i=[1,4];j=[2,3,5,6]
    H[i,i]-H[i,j]*(H[j,j]\H[j,i])
end

function section_stiffness(m,ctx,directions,x)
    T=typeof(x+0.);K=zeros(T,3,3);quarter=getp(m,"width")/4
    # Three-point integration is exact for each straight facet's quadratic
    # parallel-axis terms; the actual layered reference positions are retained.
    points=(-sqrt(3/5),0.,sqrt(3/5));weights=(5/9,8/9,5/9)
    function integrate!(pid,y0,z0,y1,z1,component)
        width=hypot(y1-y0,z1-z0);width>0||return
        ny=-(z1-z0)/width;nz=(y1-y0)/width
        H=axial_section_law(section_law(m,ctx,pid,directions,x;component))
        for (q,w) in zip(points,weights)
            r=(q+1)/2;y=y0+r*(y1-y0);z=z0+r*(z1-z0)
            transform=[one(x) z y;zero(x) nz ny]
            K.+=width*w/2*(transpose(transform)*H*transform)
        end
    end
    for segment in m.regions["skin_segments"]
        s0,s1=segment["s0"],segment["s1"];pid=segment["pid"]
        stops=sort!(unique([s0,s1,clamp(-quarter,s0,s1),clamp(quarter,s0,s1)]))
        for (a,b) in zip(stops[1:end-1],stops[2:end])
            b>a||continue;inside=abs((a+b)/2)<=quarter
            inside||pid==3||continue
            r0=(a-s0)/(s1-s0);r1=(b-s0)/(s1-s0)
            y0=segment["y0"]+r0*(segment["y1"]-segment["y0"]);z0=segment["z0"]+r0*(segment["z1"]-segment["z0"])
            y1=segment["y0"]+r1*(segment["y1"]-segment["y0"]);z1=segment["z0"]+r1*(segment["z1"]-segment["z0"])
            integrate!(pid,y0,z0,y1,z1,inside ? nothing : "foot")
        end
    end
    getp(m,"bladeH")>0&&integrate!(2,0.,0.,0.,getp(m,"bladeH"),nothing)
    K
end

region_eids(m,name)=name=="skin_full" ? vcat(m.regions["skin_left"]["eids"],m.regions["skin_right"]["eids"]) : m.regions[name]["eids"]
region_width(m,name)=name=="skin_full" ? getp(m,"width") : m.regions[name]["width"]
function region_mean(m,rec,features,name)
    ids=Set(region_eids(m,name));weights=[e["area"] for e in rec.elements if e["eid"] in ids]
    isempty(weights)&&throw(ArgumentError("The $name physical region has no elements"))
    total=sum(weights);out=zeros(eltype(features),6)
    for e in rec.elements
        e["eid"] in ids||continue;i=rec.index[e["eid"]]
        out.+=e["area"]/total.*features[6i-5:6i]
    end
    out
end

function region_bending(m,ctx,rec,name,directions,x)
    ids=Set(region_eids(m,name));total=0.;D=zeros(typeof(x+0.),3,3)
    for e in rec.elements
        e["eid"] in ids||continue;w=e["area"];total+=w
        D.+=w.*effective_bending(law(m,ctx,e["pid"],directions,x))
    end
    D/total
end

function column_section_compressions(m,ctx,rec,features,directions,x)
    nx=Int(getp(m,"nx"));total=zeros(typeof(sum(features)+x),nx);quarter=getp(m,"width")/4;L=getp(m,"length")
    nodes=Dict(node["id"]=>node for node in m.nodes)
    function add!(e,axial)
        coordinates=[nodes[id]["x"] for id in e["n"]];a,b=extrema(coordinates)
        width=b-a;width>0||error("A column-member shell has no physical longitudinal extent")
        bay=clamp(floor(Int,(a+b)/2/L*nx)+1,1,nx)
        total[bay]+=axial*e["area"]/width
    end
    for segment in m.regions["skin_segments"]
        s0,s1=segment["s0"],segment["s1"];pid=segment["pid"]
        share=max(0.,min(s1,quarter)-max(s0,-quarter))/(s1-s0)
        for eid in segment["eids"]
            e=rec.elements[rec.index[eid]];i=rec.index[eid];r=features[6i-5:6i]
            axial=r[1]*share
            if pid==3&&share<1
                H=section_law(m,ctx,pid,directions,x);foot=section_law(m,ctx,pid,directions,x;component="foot")
                strain=H\vcat(r[1:3],-r[4:6])
                axial+=(1-share)*dot(foot[1,:],strain)
            end
            add!(e,axial)
        end
    end
    for eid in m.regions["web"]["eids"]
        i=rec.index[eid];add!(rec.elements[i],features[6i-5])
    end
    -total
end
column_compression(m,ctx,rec,features,directions,x)=W.rf_active_max(column_section_compressions(m,ctx,rec,features,directions,x))

# An outstand blade has w=0 at the attached edge; root rotation and its outer
# edge are free natural plate conditions. Sines impose simply supported ends.
# Integer powers span the free-edge direction and full D16/D26 are retained.
function blade_matrices(L,H,D,modes)
    T=eltype(D);B=zeros(T,length(modes),length(modes));G=zeros(T,size(B))
    for (i,(m,n)) in enumerate(modes),(j,(p,k)) in enumerate(modes)
        a=m*pi/L;c=p*pi/L
        terms1=((1,-a*a,n,:sin),(2,n*(n-1)/H^2,n-2,:sin),(3,2a*n/H,n-1,:cos))
        terms2=((1,-c*c,k,:sin),(2,k*(k-1)/H^2,k-2,:sin),(3,2c*k/H,k-1,:cos))
        for (u,cu,pu,tu) in terms1,(v,cv,pv,tv) in terms2
            (iszero(cu)||iszero(cv))&&continue
            xint=tu==tv ? (m==p ? L/2 : 0.) : L/2*(tu==:sin ? W.rf_sc(m,p) : W.rf_sc(p,m))
            B[i,j]+=D[u,v]*cu*cv*xint*H/(pu+pv+1)
        end
        G[i,j]=(m==p ? a*c*L/2*H/(n+k+1) : zero(T))
    end
    (B+transpose(B))/2,G
end

function blade_pair(L,H,D;mmax=5,nmax=6)
    modes=[(m,n) for m in 1:mmax for n in 1:nmax]
    B,G=blade_matrices(L,H,D,modes);C=cholesky(Symmetric(G));E=eigen(Symmetric(C.L\B/C.U))
    q=C.U\E.vectors[:,1];value=E.values[1]
    residual=norm(B*q-value*G*q)/max(norm(B*q),abs(value)*norm(G*q),eps())
    (;value,q,modes,residual,gap=(E.values[2]-value)/max(abs(value),eps()))
end

function analytic_response_specs(m,ctx,rec;progress,cancelled)
    specs=Any[];features=rec.values;policy=getp(m,"buckling_policy_factor",1.)
    common=["Preload membrane resultants and moments are recovered by the native FE solver in each physical element's local axes.",
        "Capacity and demand are LIMIT quantities; reported RF = critical LIMIT multiplier / buckling policy factor ($policy).",
        "These are elementary analytical sizing idealizations, not the full curved shell SOL105 eigenproblem."]
    getp(m,"boundary_mode")=="clamped"&&push!(common,"The FE model uses clamped boundaries; the elementary analytical criteria retain simply supported/pinned boundaries. Their boundary restraint is less stiff, but homogenization and curvature differences prevent claiming a universal bound on the complete FE result.")
    plate_regions=getp(m,"bladeH")>0 ? ("skin_left","skin_right") : ("skin_full",)
    for name in plate_regions
        cancelled()&&throw(InterruptException());D=region_bending(m,ctx,rec,name,Dict(),0.);N=-region_mean(m,rec,features,name)[1:3]
        # Remove only component-level floating summation noise from the state
        # classification (for example 1e-13 N/mm transverse compression in a
        # pure tensile patch). The actual response pullback remains unrounded.
        noise=128eps(Float64)*maximum(abs,N;init=0.)
        N=[abs(value)<=noise ? 0. : value for value in N]
        L=getp(m,"length");width=region_width(m,name)
        announce(progress,"analytical","Assessing $name with the Boxer biaxial/shear Ritz plate")
        pair=W.rf_solve_plate(L,width,W.rf_flat(D),N;options=Dict("maxDimension"=>256,"truncatedFallback"=>true))
        no_demand=isempty(pair.modes)||pair.mu<=pair.resolution
        frozen=pair.modes;q=pair.q
        kernel=function(values,directions,x)
            d=region_bending(m,ctx,rec,name,directions,x);n=-region_mean(m,rec,values,name)[1:3]
            W.rf_plate_bending_quadratic(L,width,W.rf_flat(d),frozen,q)/W.rf_plate_geometric_quadratic(L,width,n,frozen,q)/policy
        end
        status=spectral_status(no_demand,!no_demand&&size(pair.cluster,2)>1,pair.approximation)
        push!(specs,(;id=name,label=replace(titlecase(replace(name,"_"=>" ")),"Skin"=>"Skin panel buckling"),
            value=no_demand ? 999. : 1/pair.mu/policy,raw=no_demand ? nothing : 1/pair.mu,
            status,kernel,no_demand,diagnostics=Dict("plate_residual"=>pair.residual,"relative_gap"=>pair.gap/max(pair.mu,eps()),
                "basis_terms"=>length(pair.modes),"converged"=>pair.converged,"truncated"=>pair.approximation,
                "basis_history"=>pair.history,"length_mm"=>L,"width_mm"=>width,"membrane_N_per_mm"=>N,"Dstar_Nmm"=>D),
            method=pair.method,assumptions=vcat(common,["Area-weighted equivalent membrane resultants and D* = D - Bᵀ A⁻¹ B; thickness variation is homogenized across the assessed plate.",
                name=="skin_full" ? "Without an actual web/stringer, the plate spans the full skin width. A flange-only doubler does not create an artificial internal support line." : "Each local half-panel idealizes its actual stringer line as a simple support; flexible stringer/global behavior is assessed separately by SOL105 and the column criterion.",
                "Flat developed-width simply supported rectangular plate; curvature membrane stiffening and elastic adjoining-member restraint are not included in this elementary criterion."])))
    end
    if getp(m,"bladeH")>0
        section_demands=column_section_compressions(m,ctx,rec,features,Dict(),0.);compression=maximum(section_demands)
        section_tolerance=256eps(Float64)*max(maximum(abs,section_demands),1.)*length(section_demands)
        critical_sections=findall(d->compression-d<=section_tolerance,section_demands)
        K=section_stiffness(m,ctx,Dict(),0.);EI=W.rf_weakest_ei(K);L=getp(m,"length")
        kernel=(values,directions,x)->pi^2*W.rf_weakest_ei(section_stiffness(m,ctx,directions,x))/(L^2*column_compression(m,ctx,rec,values,directions,x)*policy)
        nd=compression<=0
        condensed=K[2:3,2:3]-K[2:3,1]*transpose(K[2:3,1])/K[1,1]
        bending_values=eigvals(Symmetric(condensed))
        bending_gap=(bending_values[2]-bending_values[1])/max(abs(bending_values[1]),eps())
        push!(specs,(;id="stiffened_column",label="Stringer + associated skin · Euler column",value=nd ? 999. : kernel(features,Dict(),0.),
            raw=nd ? nothing : pi^2*EI/(L^2*compression),status=nd ? "no_demand" : bending_gap<=1e-8 ? "cluster" : "ok",kernel,no_demand=nd,
            method="Condensed full-ABD section energy and Euler pinned-column buckling",
            diagnostics=Dict("length_mm"=>L,"compression_N"=>compression,"span_average_compression_N"=>sum(section_demands)/length(section_demands),
                "sections"=>[Dict("index"=>i,"x0_mm"=>(i-1)*L/length(section_demands),"x1_mm"=>i*L/length(section_demands),"compression_N"=>d) for (i,d) in enumerate(section_demands)],
                "critical_section_indices"=>critical_sections,"critical_section_index"=>length(critical_sections)==1 ? only(critical_sections) : nothing,
                "weakest_EI_Nmm2"=>EI,"section_matrix"=>K,"relative_gap"=>bending_gap,"effective_length_coefficient"=>1.),
            assumptions=vcat(common,["The actual web and full added flange plus nearest half of each adjacent skin panel form the associated column (skin s between -b/4 and b/4).",
                "Physical laminate z positions, membrane/bending coupling, faceted curvature and parallel-axis terms are retained; all other plate generalized strains are condensed before assembling the section.",
                "Pinned effective length equals actual panel/stringer length, with coefficient 1. Demand is the greatest compressive recovered section force along the span, evaluated per longitudinal mesh bay by integrating physical membrane resultants times actual tributary width; the span average is retained only as a diagnostic.",
                "Outside the associated skin width, only added-flange ply forces are included. Equal critical sections are checked for equality of total design derivatives; unequal active derivatives yield a declared nonsmooth subgradient rather than a classical gradient.",
                "This Euler criterion addresses flexural column instability only; torsional and flexural-torsional/warping failure are separate modes not represented by this elementary RF."])))
        D=effective_bending(law(m,ctx,2,Dict(),0.));mean=region_mean(m,rec,features,"web");demand=-mean[1];H=getp(m,"bladeH")
        isotropic=getp(m,"material_mode")=="iso";pair=isotropic ? nothing : blade_pair(L,H,D)
        capacity=isotropic ? .425*pi^2*D[1,1]/H^2 : pair.value
        if !isotropic
            coarse=blade_pair(L,H,D;mmax=4,nmax=5)
            relative_change=abs(coarse.value-pair.value)/pair.value
        else
            relative_change=0.
        end
        kernel=function(values,directions,x)
            d=effective_bending(law(m,ctx,2,directions,x));load=-region_mean(m,rec,values,"web")[1]
            critical=if isotropic
                .425*pi^2*d[1,1]/H^2
            else
                B,G=blade_matrices(L,H,d,pair.modes);dot(pair.q,B*pair.q)/dot(pair.q,G*pair.q)
            end
            critical/load/policy
        end
        nd=demand<=0
        push!(specs,(;id="stringer_blade",label="Stringer free-blade local instability",value=nd ? 999. : capacity/demand/policy,
            raw=nd ? nothing : capacity/demand,status=nd ? "no_demand" : !isotropic&&pair.gap<=1e-5 ? "cluster" : relative_change>.005 ? "approximation" : "ok",kernel,no_demand=nd,
            method=isotropic ? "Boxer isotropic outstand plate k = 0.425" : "Full orthotropic free-edge polynomial/sine Ritz outstand",
            diagnostics=Dict("height_mm"=>H,"critical_Nx_N_per_mm"=>capacity,"compression_N_per_mm"=>demand,
                "basis_terms"=>isotropic ? 0 : length(pair.modes),"basis_relative_change"=>relative_change,
                "relative_gap"=>isotropic ? Inf : pair.gap,"eigen_residual"=>isotropic ? 0. : pair.residual),
            assumptions=vcat(common,["Actual mean axial web membrane stress is the demand; the free blade is an outstand with simply supported longitudinal ends and a simply supported attached edge.",
                isotropic ? "The isotropic long-outstand coefficient is 0.425, matching the elementary Boxer criterion." : "Full membrane-free orthotropic D* including D16/D26; an explicit finite Ritz basis and its refinement change are reported."])))
    end
    specs
end

function analytical_responses(m,ctx,rec,columns;derivatives=false,progress,cancelled)
    responses=Any[]
    for spec in analytic_response_specs(m,ctx,rec;progress,cancelled)
        cancelled()&&throw(InterruptException());sensitivities=Any[];diagnostics=copy(spec.diagnostics);response_status=spec.status
        if derivatives&&!spec.no_demand&&spec.status!="cluster"
            announce(progress,"adjoint","Solving analytical response adjoint · $(spec.label)")
            weights=ForwardDiff.gradient(v->spec.kernel(v,Dict(),0.),rec.values);gradient=zeros(ctx.op.ndof)
            for (key,weight) in zip(rec.keys,weights)
                iszero(weight)&&continue
                W.rf_feature_state_gradient!(gradient,OpenJFEM,rec.recovery,key,weight)
            end
            psi=zeros(ctx.op.ndof);psi[ctx.op.free]=transpose(ctx.factor)\gradient[ctx.op.free]
            residual=norm((transpose(ctx.op.A)*psi-gradient)[ctx.op.free])/max(norm(gradient[ctx.op.free]),eps())
            residual<1e-7||error("Analytical response adjoint residual is too large ($residual)")
            diagnostics["adjoint_residual"]=residual;diagnostics["perturbed_forward_solves"]=0
            for (id,column) in columns
                cancelled()&&throw(InterruptException())
                dq=[W.rf_feature_property_jvp(OpenJFEM,rec.recovery,k,column.directions) for k in rec.keys]
                explicit=ForwardDiff.derivative(x->spec.kernel(rec.values.+x.*dq,column.directions,x),0.)
                value=explicit-dot(psi,column.residual)
                if spec.id=="stiffened_column"&&length(diagnostics["critical_section_indices"])>1
                    # This audit uses the exact linearized state equation,
                    # not a perturbed equilibrium solve. The reported value
                    # above remains the adjoint. It checks whether a tied
                    # max-section has a unique derivative in this catalog.
                    du=zeros(ctx.op.ndof);du[ctx.op.free]=-(ctx.factor\column.residual[ctx.op.free])
                    total_features=copy(dq)
                    for (i,key) in enumerate(rec.keys)
                        q=W.rf_feature_influence(OpenJFEM,rec.recovery,key)
                        total_features[i]+=dot(q.influence,du[q.dofs])
                    end
                    seed=ForwardDiff.Dual(0.,1.)
                    trial=column_section_compressions(m,ctx,rec,rec.values.+seed.*total_features,column.directions,seed)
                    slopes=[ForwardDiff.partials(v)[1] for v in trial]
                    active=slopes[diagnostics["critical_section_indices"]]
                    spread=maximum(active)-minimum(active)
                    tolerance=1e-7max(maximum(abs,active),abs(diagnostics["compression_N"])/abs(m.params[id])*1e-6,1e-10)
                    audits=get!(diagnostics,"critical_section_derivative_audit",Dict{String,Any}())
                    audits[id]=Dict("section_derivatives_N_per_unit"=>slopes,"active_spread"=>spread,
                        "tolerance"=>tolerance,"unique_in_design_direction"=>spread<=tolerance)
                    spread>tolerance&&(response_status="subgradient")
                end
                push!(sensitivities,Dict("variable_id"=>id,"value"=>value,"adjoint"=>value,"status"=>spec.status,
                    "method"=>"Exact discrete recovery/preload adjoint; stationary capacity Rayleigh derivative"))
            end
            if response_status=="subgradient"
                for row in sensitivities
                    row["status"]="subgradient";row["method"]="Selected Clarke-average adjoint subgradient at tied critical sections"
                    row["reason"]="Active critical sections have different total design derivatives; there is no unique classical gradient."
                end
            end
        end
        push!(responses,Dict("id"=>spec.id,"label"=>spec.label,"kind"=>"analytical","value"=>spec.value,"display_value"=>min(999.,spec.value),"raw_lambda"=>spec.raw,"unit"=>"RF",
            "status"=>response_status,"method"=>spec.method,"assumptions"=>spec.assumptions,"diagnostics"=>diagnostics,
            "display_capped"=>(!spec.no_demand&&spec.raw/getp(m,"buckling_policy_factor",1.)>999),
            "sensitivities"=>sensitivities,"note"=>spec.no_demand ? "999 is the no-compression/no-demand display sentinel, not a differentiable capacity." : "Analytical elementary-part assessment; compare with SOL105 as a separate idealization."))
    end
    responses
end

function analyze_once(m,directory,tag;variables=String[],derivatives=false,sol105=true,analytical=true,mode_count=3,progress,cancelled)
    baseline=solve_forward(m,directory,tag;progress,cancelled,sol105)
    ctx=operator_context(baseline.forward;need_geometric=sol105,derivatives)
    columns=Dict{String,Any}()
    if derivatives
        for id in variables
            announce(progress,"derivatives","Assembling exact native property and load derivatives · $id")
            columns[id]=design_column(m,id,ctx)
        end
    end
    responses=Any[]
    if sol105
        returned=length(baseline.forward["eigenvalues"])
        if returned<max(mode_count,Int(getp(m,"nModes")))
            announce(progress,"warning","Native SOL105 returned $returned / $(getp(m,"nModes")) requested modes, with $mode_count selected response slots; missing selected modes remain explicitly unavailable")
        end
        for index in 1:mode_count
            if index>returned
                push!(responses,Dict("id"=>"sol105_mode_$index","label"=>"SOL105 mode $index · RF","kind"=>"sol105","value"=>nothing,
                    "raw_lambda"=>nothing,"unit"=>"RF","status"=>"unavailable","method"=>"Native SOL105 extraction coverage",
                    "note"=>"The selected mode was not returned by the native extraction; no RF or derivative is fabricated.",
                    "diagnostics"=>Dict("requested_response_mode"=>index,"native_returned_modes"=>returned),"sensitivities"=>Any[]))
                continue
            end
            if derivatives
                push!(responses,eigen_response(m,baseline.forward,ctx,index,columns;progress,cancelled))
            else
                lambda=baseline.forward["eigenvalues"][index]
                push!(responses,Dict("id"=>"sol105_mode_$index","label"=>"SOL105 mode $index · RF","kind"=>"sol105","value"=>lambda/getp(m,"buckling_policy_factor",1.),
                    "raw_lambda"=>lambda,"unit"=>"RF","status"=>"ok","method"=>"Native SOL105 eigenproblem","sensitivities"=>Any[],
                    "_vector"=>Float64.(baseline.forward["_raw_mode_shapes"][:,index])))
            end
        end
    end
    if analytical
        recovery=recovery_context(m,ctx;derivatives,progress,cancelled)
        append!(responses,analytical_responses(m,ctx,recovery,columns;derivatives,progress,cancelled))
    end
    (;responses,baseline,ctx)
end

function matched_response(base,trial)
    if base["kind"]!="sol105"
        item=findfirst(r->r["id"]==base["id"],trial.responses)
        item===nothing&&return nothing
        return (;response=trial.responses[item],mac=1.,mode=nothing,ambiguous=false)
    end
    _,modes=physical_modes(trial.baseline.forward)
    size(modes,2)>0||return nothing
    scores=[mode_mac(base["_vector"],modes[:,i]) for i in axes(modes,2)]
    order=sortperm(scores;rev=true);j=first(order);score=scores[j]
    lambda=trial.baseline.forward["eigenvalues"][j]
    second=length(order)>1 ? scores[order[2]] : 0.
    response=Dict("value"=>lambda/getp(trial.baseline.model,"buckling_policy_factor",1.),"status"=>"ok","raw_lambda"=>lambda)
    (;response,mac=score,mode=j,ambiguous=score<.8||score-second<.05)
end

"""One baseline plus independent complete +/- forward solves for validation.

The gradient includes design-dependent EA-weighted preload allocation. Ordered
eigenvalues are never blindly differenced: physical translation MAC tracks each
simple mode; ambiguous or repeated branches are explicitly not validated.
"""
function panel_analyze(m;directory,variables=String[],derivatives=false,sol105=true,analytical=true,
                       validate_fd=false,fd_steps=[1e-3,5e-4],mode_count=3,fd_tolerance=.005,
                       buckling_policy_factor=nothing,progress=_ -> nothing,cancelled=()->false)
    sol105||analytical||throw(ArgumentError("Select SOL105 and/or analytical assessment"))
    validate_fd&&(derivatives=true)
    selected=variables===nothing ? String[] : String.(variables);available=Set(v["id"] for v in ModelAPI.panel_variables(m))
    isempty(selected)&&derivatives&&(selected=sort!(collect(available)))
    all(id->id in available,selected)||throw(ArgumentError("Select only active generated-panel gauge/stack-scale variables"))
    1<=mode_count<=100||throw(ArgumentError("Selected SOL105 response mode count must lie between 1 and 100"))
    0<fd_tolerance<1||throw(ArgumentError("Finite difference tolerance must lie between 0 and 1"))
    if buckling_policy_factor!==nothing
        buckling_policy_factor>0||throw(ArgumentError("Buckling policy factor must be positive"))
        p=copy(m.params);p["buckling_policy_factor"]=buckling_policy_factor;m=ModelAPI.build_panel_model(p)
    end
    mkpath(directory);started=time_ns()
    baseline=analyze_once(m,directory,"baseline";variables=selected,derivatives,sol105,analytical,mode_count,progress,cancelled)
    if derivatives
        for response in baseline.responses,id in selected
            any(row->row["variable_id"]==id,response["sensitivities"])&&continue
            state=response["status"]
            status=state=="cluster" ? "clustered" : state=="no_demand" ? "no_demand" : "unavailable"
            reason=status=="clustered" ? "A repeated/near-repeated active eigenvalue has no unique classical scalar gradient." :
                status=="no_demand" ? "999 is a display sentinel for no destabilizing demand; it is not a differentiable RF." : "No classical derivative was established for this response."
            push!(response["sensitivities"],Dict("variable_id"=>id,"value"=>nothing,"adjoint"=>nothing,"status"=>status,
                "method"=>"Classical scalar gradient unavailable","reason"=>reason))
        end
    end
    validation=Any[];forward_count=1;steps=Float64[]
    if validate_fd
        steps=sort!(unique(Float64.(fd_steps));rev=true)
        !isempty(steps)&&all(h->0<h<.1,steps)||throw(ArgumentError("FD relative steps must be positive and below 0.1"))
        for id in selected,h in steps
            x=Float64(m.params[id]);delta=h*abs(x);delta>0||throw(ArgumentError("A relative FD step requires a nonzero design variable"))
            pair=Any[]
            for sign in (-1,1)
                cancelled()&&throw(InterruptException());p=deepcopy(m.params);p[id]=x+sign*delta
                trial_model=ModelAPI.build_panel_model(p)
                [(n["id"],n["x"],n["y"],n["z"],n["cd"]) for n in trial_model.nodes]==[(n["id"],n["x"],n["y"],n["z"],n["cd"]) for n in m.nodes]||error("FD variable unexpectedly changed geometry")
                [e["n"] for e in trial_model.elements]==[e["n"] for e in m.elements]||error("FD variable unexpectedly changed connectivity")
                label="fd_$(id)_$(replace(string(h),'.'=>'_'))_$(sign<0 ? "minus" : "plus")"
                announce(progress,"validation","Independent full forward validation · $id · relative step $h · $(sign<0 ? "minus" : "plus")")
                trial=analyze_once(trial_model,directory,label;sol105,analytical,mode_count,progress,cancelled)
                save_json(joinpath(dirname(trial.baseline.path),"responses.json"),trial.responses)
                push!(pair,trial);forward_count+=1
            end
            for response in baseline.responses
                derivative=findfirst(row->row["variable_id"]==id,response["sensitivities"])
                entry=derivative===nothing ? nothing : response["sensitivities"][derivative]
                if entry===nothing||!number(get(entry,"value",nothing))||get(entry,"status","")=="subgradient"
                    push!(validation,Dict("response_id"=>response["id"],"variable_id"=>id,"step_relative"=>h,"step_absolute"=>delta,
                        "adjoint"=>nothing,"finite_difference"=>nothing,"relative_error"=>nothing,"absolute_error"=>nothing,
                        "matched_mode"=>nothing,"mac"=>nothing,"status"=>entry===nothing ? "unavailable" : get(entry,"status","unavailable"),
                        "selected_subgradient"=>entry===nothing ? nothing : get(entry,"status","")=="subgradient" ? entry["value"] : nothing,
                        "reason"=>entry===nothing ? "The selected response/variable pair has no classical gradient." : get(entry,"reason","No classical gradient is available.")))
                    continue
                end
                minus=matched_response(response,pair[1]);plus=matched_response(response,pair[2])
                if minus===nothing||plus===nothing
                    push!(validation,Dict("response_id"=>response["id"],"variable_id"=>id,"step_relative"=>h,"step_absolute"=>delta,
                        "adjoint"=>entry["value"],"finite_difference"=>nothing,"relative_error"=>nothing,"absolute_error"=>nothing,
                        "matched_mode"=>nothing,"mac"=>nothing,"status"=>"unavailable","reason"=>"A perturbed response or a tracked mode was not returned."))
                    continue
                end
                expected=entry["value"]
                finite=(plus.response["value"]-minus.response["value"])/(2delta)
                absolute=abs(finite-expected);relative=absolute/max(abs(finite),abs(expected),1e-10)
                ambiguous=minus.ambiguous||plus.ambiguous
                small_tolerance=1e-7*max(abs(response["value"])/abs(x),1e-10)
                status=ambiguous ? "ambiguous_mode" : relative<=fd_tolerance||absolute<=small_tolerance ? "passed" : "failed"
                push!(validation,Dict("response_id"=>response["id"],"variable_id"=>id,"step_relative"=>h,"step_absolute"=>delta,
                    "adjoint"=>expected,"finite_difference"=>ambiguous ? nothing : finite,"relative_error"=>ambiguous ? nothing : relative,"absolute_error"=>ambiguous ? nothing : absolute,
                    "matched_mode"=>Dict("minus"=>minus.mode,"plus"=>plus.mode),"mac"=>min(minus.mac,plus.mac),
                    "small_derivative_absolute_tolerance"=>small_tolerance,"status"=>status))
            end
        end
    end
    for response in baseline.responses,id in selected
        rows=sort!([row for row in validation if row["response_id"]==response["id"]&&row["variable_id"]==id&&number(row["finite_difference"])];by=row->row["step_relative"],rev=true)
        for i in 2:length(rows)
            previous=rows[i-1];row=rows[i]
            difference=abs(previous["finite_difference"]-row["finite_difference"])
            stability=difference/max(abs(previous["finite_difference"]),abs(row["finite_difference"]),row["small_derivative_absolute_tolerance"])
            row["step_refinement_relative_change"]=stability
            row["step_refinement_stable"]=stability<=fd_tolerance||difference<=row["small_derivative_absolute_tolerance"]
            !row["step_refinement_stable"]&&row["status"]=="passed"&&(row["status"]="step_not_stable")
        end
    end
    sensitivity_rows=Any[]
    for response in baseline.responses,row in response["sensitivities"]
        row["response_id"]=response["id"];id=row["variable_id"]
        row["normalized"]=number(row["value"])&&number(response["value"])&&response["value"]!=0 ? row["value"]*m.params[id]/response["value"] : nothing
        row["unit"]=startswith(id,"scale") ? "RF / scale" : "RF / mm"
        push!(sensitivity_rows,row)
    end
    expected_derivatives=derivatives ? length(baseline.responses)*length(selected) : 0
    expected_validation=validate_fd ? expected_derivatives*length(steps) : 0
    passed=count(row->row["status"]=="passed",validation)
    failed=count(row->row["status"] in ("failed","step_not_stable"),validation)
    available=count(row->number(row["value"])&&row["status"]!="subgradient",sensitivity_rows)
    coverage=Dict("derivatives"=>Dict("expected"=>expected_derivatives,"available"=>available,"unavailable"=>expected_derivatives-available),
        "validation"=>Dict("expected"=>expected_validation,"reported"=>length(validation),"passed"=>passed,"failed"=>failed,
            "unavailable"=>length(validation)-passed-failed))
    length(validation)==expected_validation||error("Validation coverage mismatch: expected $expected_validation rows, recorded $(length(validation))")
    answer=Dict{String,Any}("ok"=>true,"responses"=>baseline.responses,"sensitivities"=>sensitivity_rows,"validation"=>validation,"coverage"=>coverage,
        "bdf_path"=>baseline.baseline.path,"eigenvalues"=>sol105 ? Float64.(baseline.baseline.forward["eigenvalues"]) : Float64[],
        "catalog"=>catalog(m),"model_report"=>m.report,"mass_tonnes"=>m.report["mass_tonnes"],"variables"=>selected,
        "diagnostics"=>merge(copy(baseline.ctx.diagnostics),Dict("forward_solves"=>forward_count,"fd_is_independent"=>true,
            "native_requested_sol105_modes"=>sol105 ? Int(getp(m,"nModes")) : 0,
            "native_returned_sol105_modes"=>sol105 ? length(baseline.baseline.forward["eigenvalues"]) : 0,
            "requested_sol105_response_modes"=>sol105 ? mode_count : 0,
            "missing_sol105_response_modes"=>sol105 ? max(0,mode_count-length(baseline.baseline.forward["eigenvalues"])) : 0,
            "buckling_policy_factor"=>getp(m,"buckling_policy_factor",1.),"preload_load_derivatives_included"=>true,
            "finite_difference_tolerance"=>fd_tolerance,"elapsed_seconds"=>(time_ns()-started)*1e-9)),
        "_forward"=>baseline.baseline.forward)
    save_json(joinpath(directory,"panel_analysis.json"),answer)
    announce(progress,"complete","Panel assessment complete · $(length(baseline.responses)) responses · $(length(sensitivity_rows)) derivatives · $(length(validation)) independent FD comparisons")
    answer
end

export panel_analyze,public_value
end # module
