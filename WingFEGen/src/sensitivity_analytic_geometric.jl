# Replay the actual native geometric shell operator with exact directional AD.
# Captured fixed geometry/formulation replaces no native quadrature or frame.
const SENSITIVITY_GEOMETRIC_KEYS=Symbol.(split("""
n pid is_pcomp_clt pcomp_is_isotropic is_ortho is_mat2 prop
lc_buf4 lc3 u_elem24 u_elem18 T_buf T18 dofs_buf24 dofs_t3 Kg_global Kg18
kg_nastran_kdjj_iso_branch kg_nastran_kdjj_pcomp_branch kg_flat_dkmq_branch kg_flat_plate_branch
kg_covariant_branch kg_global_ready assumed_transverse warp_preload_map
elem_mitc4_3d_kg_recovery elem_snorm_curvature_kg kg_coupled_projected
kg_compatible_membrane elem_membrane_incomp_kg kg_iso_exact_membrane kg_membrane_selc
slope_membrane_kg curvature_membrane membrane_incomp_center_jacobian kg_material_shear_rotation
elem_is_flat_kg Bmb_kg Bmb_override_t3 snorm_pq_kg coords3d_local_buf4
kg_membrane_recovery_mode kg_covariant_blend covariant_membrane_candidate
N_gp N_res sigma_mem_input stress_mode_label gp_blend_override gp_blend_alpha kg_gp_extrapolate_scale
kg_shell_nxy_auto kg_shell_pcomp_nxy kg_shell_pcomp_nxy_eff kg_shell_pcomp_nxy_compression_only_v
kg_shell_pcomp_nxy_shear_dom_relax_v geom_pshell_iso_warped_kg_scale geom_pshell_iso_skew_kg_scale
kg_trans_mode kg_trans_mode_eff kg_curvature kg_curvature_sign kg_curvature_sign_eff
kg_membrane_shear_center_row kg_consistent_membrane_incomp
principal_shear_yy_factor_eff principal_shear_xy_factor_eff principal_shear_z_factor_eff principal_shear_ratio_min_eff
apply_finite_warp_kg warp_map_for_snorm_kg snorm_relative_pq_kg kg_shell_drill_zero br
"""))

function sensitivity_geometric_capture(native,op,state)
    contexts=Dict{Int,Any}();guard=ReentrantLock()
    callback=function(eid,locals)
        values=Dict(k=>deepcopy(locals[k]) for k in SENSITIVITY_GEOMETRIC_KEYS if haskey(locals,k))
        values[:eid]=eid;values[:model]=op.model
        lock(guard) do;contexts[eid]=values;end
        nothing
    end
    sensitivity_geometric_matrix(native,op,state;physical=true,geometric_capture=callback)
    length(contexts)==length(op.model["CSHELLs"])||error("Native geometric capture omitted a shell element")
    contexts
end

function sensitivity_geometric_shell_replay(native,ctx,direction=Dict(),x=0.;local_state=nothing)
    S=native.Solver;F=S.FEM;g(k,default=nothing)=get(ctx,k,default)
    eid=g(:eid);pid=parse(Int,string(g(:pid)));c=S.analytic_shell_constitutive(g(:model),pid,direction,x)
    isclt=g(:is_pcomp_clt);n=g(:n);T=g(n==4 ? :T_buf : :T18)
    u=local_state===nothing ? g(n==4 ? :u_elem24 : :u_elem18) : local_state
    cm=isclt ? c.Cm : nothing
    reject(message)=throw(ArgumentError("Analytic geometric shell $eid: $message"))
    (g(:is_ortho,false)||g(:is_mat2,false))&&reject("only isotropic MAT1 shell layers are supported")
    isclt&&!g(:pcomp_is_isotropic,false)&&reject("an anisotropic laminate requires its own material-axis derivative")
    if n==3
        N=first(F.stress_strain_tria3(g(:lc3),u,c.E,c.nu,c.h;bend_ratio=g(:br,1.),Cm_override=cm,
            Bmb=g(:Bmb_override_t3)===nothing ? nothing : c.Bmb))
        sigma=N./c.h
        isclt&&S.kg_shell_apply_pcomp_nxy_scale!(sigma,g(:kg_shell_pcomp_nxy),g(:kg_shell_pcomp_nxy_compression_only_v))
        K=F.geometric_stiffness_tria3(g(:lc3),sigma,c.h;trans_mode=g(:kg_trans_mode),curvature=nothing,curvature_sign=g(:kg_curvature_sign))
    elseif g(:kg_nastran_kdjj_iso_branch,false)
        warp=g(:warp_preload_map);ue=warp===nothing ? u : warp*u
        K=F.geometric_stiffness_quad4_nastran_kdjj_iso(g(:lc_buf4),ue,c.E,c.nu,c.h;assumed_transverse=g(:assumed_transverse,false))
    else
        for key in (:kg_nastran_kdjj_pcomp_branch,:kg_flat_dkmq_branch,:kg_flat_plate_branch,:kg_covariant_branch,
                :kg_global_ready,:elem_mitc4_3d_kg_recovery,:kg_coupled_projected)
            g(key,false)&&reject("unsupported resolved native branch $key")
        end
        g(:kg_membrane_recovery_mode) in (:tri_aspect,:tri_center_adj,:tri_incident_interp,:tri_diagavg)&&reject("triangle-based Q4 stress recovery is unsupported")
        (g(:kg_compatible_membrane)&&g(:kg_covariant_blend,0.)>0&&g(:kg_membrane_recovery_mode)!==:planar&&
            (g(:kg_membrane_recovery_mode)===:covariant||g(:covariant_membrane_candidate,false)))&&reject("covariant stress blending is unsupported")
        g(:kg_shell_nxy_auto,0.)!=0&&reject("automatic shear relaxation is unsupported")
        g(:kg_shell_pcomp_nxy_shear_dom_relax_v,0.)!=0&&reject("shear-dominant laminate relaxation is unsupported")
        (g(:geom_pshell_iso_warped_kg_scale,1.)!=1||g(:geom_pshell_iso_skew_kg_scale,1.)!=1)&&reject("thickness-gated geometric calibration is unsupported")
        any(g(k,1.)!=1 for k in (:principal_shear_yy_factor_eff,:principal_shear_xy_factor_eff,:principal_shear_z_factor_eff))&&reject("stress-dependent principal shear calibration is unsupported")
        selc=g(:kg_membrane_selc,false);enhanced=g(:kg_iso_exact_membrane,false)
        modes=(S.solver_env_bool("JFEM_KG_RECOVERY_CROSS_MEMBRANE_WEIGHTS",false)&&g(:elem_is_flat_kg)&&g(:Bmb_kg)===nothing&&!selc) ? (0.,1.,1.,0.) : nothing
        Ngp,Nres,_=F.quad4_membrane_force_field(g(:lc_buf4),u,c.E,c.nu,c.h;
            Cm_override=cm,Bmb=g(:Bmb_kg)===nothing ? nothing : c.Bmb,
            slope_membrane=g(:slope_membrane_kg),compatible_only=g(:kg_compatible_membrane),
            use_incompatible_modes=g(:elem_membrane_incomp_kg)&&!enhanced&&!selc,use_enhanced_modes=enhanced,
            curvature_membrane=g(:curvature_membrane),membrane_shear_center_row=selc,
            material_shear_rotation=selc ? 0. : g(:kg_material_shear_rotation),
            membrane_incomp_center_jacobian=g(:membrane_incomp_center_jacobian),mode_weights=modes,
            snorm_pq=g(:snorm_pq_kg),coords_3d=g(:coords3d_local_buf4))
        mode=g(:stress_mode_label)
        # Preserve resolved native GP/average selection and fixed blend weights.
        # Auto blending derives a weight from the stresses, so it must not be frozen.
        occursin("auto_blend",mode)&&reject("stress-dependent automatic GP blending is unsupported")
        alpha=occursin("pminavg",mode) ? g(:gp_blend_alpha) :
            mode=="override_blend" ? g(:gp_blend_override) :
            mode=="gauss_extrapolate" ? g(:kg_gp_extrapolate_scale) : nothing
        N=alpha!==nothing ? alpha.*Ngp.+(1-alpha).*transpose(Nres) :
            startswith(mode,"gauss") ? Ngp : mode in ("average","shear_average") ? Nres : reject("unknown stress-field mode $mode")
        sigma=N./c.h
        isclt&&S.kg_shell_apply_pcomp_nxy_scale!(sigma,g(:kg_shell_pcomp_nxy_eff),g(:kg_shell_pcomp_nxy_compression_only_v))
        K=F.geometric_stiffness_quad4(g(:lc_buf4),sigma,c.h;
            trans_mode=g(:kg_trans_mode_eff),curvature=g(:kg_curvature),curvature_sign=g(:kg_curvature_sign_eff),
            membrane_shear_center_row=g(:kg_membrane_shear_center_row),Cm=c.Cm,
            membrane_incomp=g(:kg_consistent_membrane_incomp)&&!enhanced,membrane_enhanced=enhanced,
            material_shear_rotation=g(:kg_material_shear_rotation),membrane_incomp_center_jacobian=g(:membrane_incomp_center_jacobian),
            principal_shear_yy_factor=g(:principal_shear_yy_factor_eff),principal_shear_xy_factor=g(:principal_shear_xy_factor_eff),
            principal_shear_z_factor=g(:principal_shear_z_factor_eff),principal_shear_ratio_min=g(:principal_shear_ratio_min_eff))
    end
    if n==4
        snorm=g(:snorm_pq_kg)
        if snorm!==nothing
            if F.quad4_snorm_normal_moment_mode()
                relative=g(:snorm_relative_pq_kg);relative===nothing||F.apply_quad4_snorm_normal_moment_completion!(K,g(:lc_buf4),relative)
            else
                F.apply_quad4_snorm_director_completion!(K,snorm)
            end
        end
        g(:apply_finite_warp_kg,false)&&F.apply_quad4_finite_warp_equilibrium!(K,g(:lc_buf4),g(:coords3d_local_buf4))
    end
    result=T'*K*T
    if g(:kg_shell_drill_zero,false)
        for d in 6:6:6n;result[d,:].=0;result[:,d].=0;end
    end
    result
end

function sensitivity_geometric_shell_check(native,ctx)
    actual=ctx[ctx[:n]==4 ? :Kg_global : :Kg18]
    replay=sensitivity_geometric_shell_replay(native,ctx)
    mismatch=norm(replay-actual)/max(norm(actual),eps())
    mismatch<=2e-9||error("Analytic geometric shell $(ctx[:eid]) does not replay the native operator ($mismatch)")
    mismatch
end

"""Explicit fixed-preload shell contribution phi' (dKg/dp) phi, before MPCs."""
function sensitivity_analytic_shell_geometric(native,op,wing,directions,state,physical_phi;contexts=nothing)
    contexts===nothing&&(contexts=sensitivity_geometric_capture(native,op,state))
    value=0.;AD=native.Solver.ForwardDiff
    for ctx in values(contexts)
        direction=sensitivity_pid_direction(directions,parse(Int,string(ctx[:pid])));direction===nothing&&continue
        sensitivity_geometric_shell_check(native,ctx)
        dofs=ctx[ctx[:n]==4 ? :dofs_buf24 : :dofs_t3];phi=physical_phi[dofs]
        kd=sensitivity_geometric_shell_replay(native,ctx,direction,AD.Dual(0.,1.))
        value+=AD.partials(dot(phi,kd*phi))[1]
    end
    value
end

"""Exact preload adjoint RHS from element-local native energy derivatives."""
function sensitivity_buckling_state_gradient_captured(native,op,wing,state,phi;progress=(_)->nothing,cancelled=()->false)
    contexts=sensitivity_geometric_capture(native,op,state);AD=native.Solver.ForwardDiff
    gradient=zeros(op.ndof);max_replay=0.;bars=0
    for (ordinal,ctx) in enumerate(values(contexts))
        cancelled()&&error("Sensitivity study cancelled")
        max_replay=max(max_replay,sensitivity_geometric_shell_check(native,ctx))
        dofs=ctx[ctx[:n]==4 ? :dofs_buf24 : :dofs_t3];T=ctx[ctx[:n]==4 ? :T_buf : :T18];pe=phi[dofs]
        energy=v->dot(pe,sensitivity_geometric_shell_replay(native,ctx;local_state=T*v)*pe)
        gradient[dofs].+=AD.gradient(energy,state[dofs])
        ordinal%25==0&&progress(Dict("detail"=>"Analytic buckling shell preload derivative $ordinal/$(length(contexts))"))
    end
    for gr in wing.groups
        gr.kind===:bar||continue
        for e in 1:n_elements(gr)
            cancelled()&&error("Sensitivity study cancelled")
            bar=sensitivity_analytic_bar(native,op,wing,gr,e,Dict{String,Any}(),state)
            gradient[bar.dofs].+=sensitivity_analytic_bar_preload_gradient(bar,phi);bars+=1
        end
    end
    all(isfinite,gradient)||error("Analytic buckling preload gradient contains nonfinite values")
    gradient,Dict("state_gradient_method"=>"analytic_local_energy","geometric_assemblies"=>1,
        "state_gradient_replay_error"=>max_replay,"state_shell_elements"=>length(contexts),"state_bar_elements"=>bars,
        "state_dofs"=>count(!iszero,gradient)),contexts
end
