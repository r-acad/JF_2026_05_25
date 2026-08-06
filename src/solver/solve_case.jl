# solve_case.jl — Subcase solver orchestrator

function _assemble_applied_force(ndof, model, id_map, X, load_id, node_R, rbe3_map;
                                 load_scale::Float64=1.0,
                                 temp_load_id=nothing,
                                 log_rbe3::Bool=true)
    F_applied = zeros(ndof)
    if !isnothing(load_id)
        elem_map = Dict{Int, Any}()
        F_global_accum = zeros(ndof)
        had_disable = haskey(model, "_disable_thermal_in_resolve_loads")
        prev_disable = had_disable ? model["_disable_thermal_in_resolve_loads"] : nothing
        model["_disable_thermal_in_resolve_loads"] = true
        try
            resolve_loads(model, Int(load_id), load_scale, id_map, elem_map, X, F_global_accum)
        finally
            if had_disable
                model["_disable_thermal_in_resolve_loads"] = prev_disable
            else
                delete!(model, "_disable_thermal_in_resolve_loads")
            end
        end
        resolve_thermal_loads(model, temp_load_id, load_scale, id_map, elem_map, X, F_global_accum; node_R=node_R)
        for i in 1:length(id_map)
            idx = (i-1)*6
            F_applied[idx+1:idx+3] = node_R[i]' * view(F_global_accum, idx+1:idx+3)
            F_applied[idx+4:idx+6] = node_R[i]' * view(F_global_accum, idx+4:idx+6)
        end
    elseif !isnothing(temp_load_id)
        elem_map = Dict{Int, Any}()
        F_global_accum = zeros(ndof)
        resolve_thermal_loads(model, temp_load_id, load_scale, id_map, elem_map, X, F_global_accum; node_R=node_R)
        for i in 1:length(id_map)
            idx = (i-1)*6
            F_applied[idx+1:idx+3] = node_R[i]' * view(F_global_accum, idx+1:idx+3)
            F_applied[idx+4:idx+6] = node_R[i]' * view(F_global_accum, idx+4:idx+6)
        end
    end

    if !isempty(rbe3_map)
        n_force_redist = 0
        for (dep_dof, pairs) in rbe3_map
            f_dep = F_applied[dep_dof]
            if abs(f_dep) > 1e-30
                for (ind_dof, coeff) in pairs
                    F_applied[ind_dof] += f_dep * coeff
                end
                F_applied[dep_dof] = 0.0
                n_force_redist += 1
            end
        end
        if n_force_redist > 0 && log_rbe3
            log_msg("[SOLVER] RBE3: Redistributed forces from $n_force_redist dependent DOFs")
        end
    end
    return F_applied
end

function _deterministic_buckling_start_vector(n::Int, ordinal::Int)
    seed = buckling_rng_seed()
    v = Vector{Float64}(undef, n)
    phase = 0.137 * (seed + 1) + 0.731 * ordinal
    @inbounds for i in 1:n
        x = i + phase
        v[i] = sin(0.7548776662466927 * x) + 0.5 * cos(1.246979603717467 * x)
    end
    return v
end

function _buckling_raw_csv_cell(x)
    replace(string(x), "," => ";", "\n" => " ", "\r" => " ")
end

function _write_buckling_raw_eigen_csv(eigenvalues::AbstractVector, path::AbstractString;
                                       buckling_subcase=nothing,
                                       static_subcase=nothing,
                                       backend="",
                                       phase="pre_positive_filter",
                                       requested_modes::Int=0,
                                       requested_modes_internal::Int=0,
                                       eigrl_v1::Float64=0.0,
                                       eigrl_v2::Float64=0.0,
                                       positive_tol::Float64=1e-10)
    isempty(strip(path)) && return
    try
        dir = dirname(path)
        if !isempty(dir) && dir != "." && !isdir(dir)
            mkpath(dir)
        end
        vals = collect(Float64, eigenvalues)
        abs_rank = Dict{Int,Int}()
        for (rank, idx) in enumerate(sortperm(abs.(vals)))
            abs_rank[idx] = rank
        end
        has_range = (eigrl_v1 != 0.0 || eigrl_v2 != 0.0) && eigrl_v2 > eigrl_v1
        range_abs_tol = max(solver_env_float("JFEM_SOL105_RANGE_ABS_TOL", 0.0), 0.0)
        range_rel_tol = max(solver_env_float("JFEM_SOL105_RANGE_REL_TOL", 0.0), 0.0)
        v1_positive_eff = max(eigrl_v1, positive_tol)
        v2_eff = has_range ? eigrl_v2 + max(range_abs_tol, abs(eigrl_v2) * range_rel_tol) : eigrl_v2
        write_header = !isfile(path) || filesize(path) == 0
        open(path, write_header ? "w" : "a") do io
            if write_header
                println(io, "phase,buckling_subcase,static_subcase,backend,raw_index,abs_rank,lambda,abs_lambda,is_positive,in_signed_eigrl_range,in_positive_eigrl_range,eigrl_v1,eigrl_v2,eigrl_v2_eff,requested_modes,requested_modes_internal")
            end
            for (i, lam) in enumerate(vals)
                in_signed_range = !has_range || (lam >= eigrl_v1 && lam <= v2_eff)
                in_positive_range = lam > positive_tol && (!has_range || (lam >= v1_positive_eff && lam <= v2_eff))
                println(io,
                    _buckling_raw_csv_cell(phase), ",",
                    _buckling_raw_csv_cell(buckling_subcase === nothing ? "" : buckling_subcase), ",",
                    _buckling_raw_csv_cell(static_subcase === nothing ? "" : static_subcase), ",",
                    _buckling_raw_csv_cell(backend), ",",
                    i, ",", abs_rank[i], ",", lam, ",", abs(lam), ",",
                    lam > positive_tol, ",", in_signed_range, ",", in_positive_range, ",",
                    eigrl_v1, ",", eigrl_v2, ",", v2_eff, ",",
                    requested_modes, ",", requested_modes_internal)
            end
        end
        log_msg("[BUCKLING] Raw signed eigenvalue trace: $(length(vals)) rows -> $path")
    catch e
        log_msg("[BUCKLING] WARNING: failed to write JFEM_BUCKLING_RAW_EIGEN_CSV -> $path: $(sprint(showerror, e))")
    end
    return
end

# 2026-07-27 (strip Stage 1, Pass B): REMOVED the bounded signed-magnitude auto-selector
# (`_sol105_signedmag_auto_high_pm45_selector`), its 19 threshold accessors and the
# `_sol105_descriptor_quantile` helper that served only them — 223 lines. The selector was a
# whole-model DECK FINGERPRINT: aspect 5.0-6.6 AND h/Lmax 0.0130-0.0145 AND pm45 0.40-0.48 AND
# pm90 0.20-0.25 AND ply_count == 9 exactly AND >= 250 matching PCOMP quads. On a match it
# switched the buckling output to |lambda| ordering, i.e. it changed which eigenvalue a matching
# model reports as mode 1. Nastran has no such concept.
function _build_results_from_state(ndof, model, id_map, X, node_R, u_global, residual_vector,
                                   snorm_normals, solver_diagnostics;
                                   active_load_id=nothing,
                                   active_load_scale::Float64=1.0)
    results_json = Dict(
        "displacements" => [],
        "spc_forces" => [],
        "forces" => Dict("cbar" => [], "quad4" => [], "tria3" => [], "crod" => [], "conrod" => [], "celas1" => []),
        "forces_bilin" => Dict("quad4" => [], "tria3" => []),
        "stresses" => Dict("cbar" => [], "quad4" => [], "tria3" => [], "crod" => [], "conrod" => [], "celas1" => [], "ctetra" => [], "chexa" => [], "cpenta" => []),
        "strains" => Dict("cbar" => [], "quad4" => [], "tria3" => [], "crod" => [], "conrod" => [], "celas1" => [], "ctetra" => [], "chexa" => [], "cpenta" => []),
        "solver_diagnostics" => solver_diagnostics,
    )

    u_out = zeros(ndof)
    sorted_nodes = sort(collect(keys(id_map)))
    for nid in sorted_nodes
        idx = id_map[nid]
        base = (idx - 1) * 6
        u_loc = view(u_global, base+1:base+6)

        t_glob = node_R[idx] * u_loc[1:3]
        r_glob = node_R[idx] * u_loc[4:6]

        u_out[base+1:base+3] = t_glob
        u_out[base+4:base+6] = r_glob

        push!(results_json["displacements"], Dict(
            "grid_id" => nid,
            "t1" => t_glob[1], "t2" => t_glob[2], "t3" => t_glob[3],
            "r1" => r_glob[1], "r2" => r_glob[2], "r3" => r_glob[3],
        ))

        r_loc = view(residual_vector, base+1:base+6)
        r_reac_glob = vcat(node_R[idx] * r_loc[1:3], node_R[idx] * r_loc[4:6])
        if norm(r_reac_glob) > 1e-20
            push!(results_json["spc_forces"], Dict(
                "grid_id" => nid,
                "t1" => r_reac_glob[1], "t2" => r_reac_glob[2], "t3" => r_reac_glob[3],
                "r1" => r_reac_glob[4], "r2" => r_reac_glob[5], "r3" => r_reac_glob[6],
            ))
        end
    end

    spc_fx = isempty(results_json["spc_forces"]) ? 0.0 : sum(s["t1"] for s in results_json["spc_forces"])
    spc_fy = isempty(results_json["spc_forces"]) ? 0.0 : sum(s["t2"] for s in results_json["spc_forces"])
    spc_fz = isempty(results_json["spc_forces"]) ? 0.0 : sum(s["t3"] for s in results_json["spc_forces"])
    solver_diagnostics["equilibrium"] = Dict(
        "spc_reaction_sum" => Dict("fx" => spc_fx, "fy" => spc_fy, "fz" => spc_fz),
        "residual" => sqrt(spc_fx^2 + spc_fy^2 + spc_fz^2),
        "relative_residual" => 0.0,
    )

    stresses = Dict{Int, Float64}()
    skip_stress_recovery =
        lowercase(strip(get(ENV, "JFEM_SKIP_STRESS_RECOVERY", "false"))) in ("1", "true", "yes", "on")
    if skip_stress_recovery
        results_json["stress_recovery_skipped"] = true
    else
        recover_shell_stresses!(model, id_map, X, node_R, u_global, snorm_normals, stresses, results_json)
        recover_bar_stresses!(
            model, id_map, X, node_R, u_global, stresses, results_json;
            active_load_id=active_load_id,
            active_load_scale=active_load_scale,
        )
        recover_rod_stresses!(model, id_map, X, node_R, u_global, stresses, results_json)
        recover_spring_forces!(model, id_map, u_global, stresses, results_json)
        recover_solid_stresses!(model, id_map, X, node_R, u_global, stresses, results_json)
    end

    return u_out, stresses, results_json
end

@inline function _quad4_is_coplanar(p1::SVector{3,Float64}, p2::SVector{3,Float64},
                                    p3::SVector{3,Float64}, p4::SVector{3,Float64};
                                    tol::Float64=1e-8)
    n = cross(p2 - p1, p3 - p1)
    nn = norm(n)
    nn <= 1e-12 && return false
    return abs(dot(p4 - p1, n / nn)) <= tol * max(norm(p2-p1), norm(p3-p1), norm(p4-p1), 1.0)
end

function _formal_von_karman_shell_supported(model, id_map, X)
    return _formal_von_karman_shell_support_report(model, id_map, X).supported
end

function _formal_von_karman_shell_support_report(model, id_map, X)
    has_shell = false
    total_shell_count = 0
    quad4_count = 0
    tria3_count = 0
    planar_quad_count = 0
    warped_quad_count = 0
    for (_, el) in get(model, "CSHELLs", Dict())
        nids = get(el, "NODES", Int[])
        n = length(nids)
        n in (3, 4) || return (
            supported=false,
            support_class="unsupported",
            unsupported_reason="unsupported_shell_node_count_$n",
            total_shell_count=total_shell_count,
            quad4_count=quad4_count,
            tria3_count=tria3_count,
            planar_quad_count=planar_quad_count,
            warped_quad_count=warped_quad_count,
        )
        any(nid -> !haskey(id_map, nid), nids) && return (
            supported=false,
            support_class="unsupported",
            unsupported_reason="missing_grid_reference",
            total_shell_count=total_shell_count,
            quad4_count=quad4_count,
            tria3_count=tria3_count,
            planar_quad_count=planar_quad_count,
            warped_quad_count=warped_quad_count,
        )
        pid = string(get(el, "PID", 0))
        haskey(model["PSHELLs"], pid) || return (
            supported=false,
            support_class="unsupported",
            unsupported_reason="missing_pshell_property",
            total_shell_count=total_shell_count,
            quad4_count=quad4_count,
            tria3_count=tria3_count,
            planar_quad_count=planar_quad_count,
            warped_quad_count=warped_quad_count,
        )
        prop = model["PSHELLs"][pid]
        if get(prop, "TYPE", "") == "PCOMP_CLT"
            haskey(prop, "Cm") || return (
                supported=false,
                support_class="unsupported",
                unsupported_reason="missing_pcomp_clt_membrane_matrix",
                total_shell_count=total_shell_count,
                quad4_count=quad4_count,
                tria3_count=tria3_count,
                planar_quad_count=planar_quad_count,
                warped_quad_count=warped_quad_count,
            )
        else
            mid = string(get(prop, "MID", 0))
            haskey(model["MATs"], mid) || return (
                supported=false,
                support_class="unsupported",
                unsupported_reason="missing_material",
                total_shell_count=total_shell_count,
                quad4_count=quad4_count,
                tria3_count=tria3_count,
                planar_quad_count=planar_quad_count,
                warped_quad_count=warped_quad_count,
            )
        end
        total_shell_count += 1
        if n == 4
            quad4_count += 1
            i1, i2, i3, i4 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]], id_map[nids[4]]
            p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
            p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
            p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3])
            p4 = SVector{3}(X[i4,1], X[i4,2], X[i4,3])
            if _quad4_is_coplanar(p1, p2, p3, p4)
                planar_quad_count += 1
            else
                warped_quad_count += 1
            end
        else
            tria3_count += 1
        end
        has_shell = true
    end
    has_shell || return (
        supported=false,
        support_class="unsupported",
        unsupported_reason="no_shell_elements",
        total_shell_count=0,
        quad4_count=0,
        tria3_count=0,
        planar_quad_count=0,
        warped_quad_count=0,
    )
    return (
        supported=true,
        support_class=warped_quad_count > 0 ? "warped_fallback" : "planar",
        unsupported_reason="",
        total_shell_count=total_shell_count,
        quad4_count=quad4_count,
        tria3_count=tria3_count,
        planar_quad_count=planar_quad_count,
        warped_quad_count=warped_quad_count,
    )
end

function _formal_shell_membrane_constitutive(prop, el, mat, v1, v2, v3, p1, p2; tri::Bool=false)
    if get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "Cm")
        Cm = copy(prop["Cm"])
        beta =
            if tri
                shell_pcomp_material_rotation(
                    q4_pcomp_axis_mode("JFEM_Q4_PCOMP_AXIS_MODE_STATIC"),
                    v1, v2, v3, p1, p2,
                    deg2rad(Float64(get(el, "THETA", 0.0))),
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
            else
                theta_rad = deg2rad(Float64(get(el, "THETA", 0.0)))
                shell_pcomp_material_rotation(
                    q4_pcomp_axis_mode("JFEM_Q4_PCOMP_AXIS_MODE_STATIC"),
                    v1, v2, v3, p1, p2, theta_rad,
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
            end
        if abs(beta) > 1e-10
            cb = cos(beta); sb = sin(beta)
            c2 = cb^2; s2 = sb^2; cs = cb * sb
            _rotate_constitutive_3x3!(Cm, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
        end
        return Cm
    end

    h = Float64(get(prop, "T", 0.0))
    E = Float64(get(mat, "E", 0.0))
    nu = Float64(get(mat, "NU", 0.0))
    const_mem = E / max(1 - nu^2, 1e-12)
    return (const_mem .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]) * h
end

function _nonlinear_internal_force(K_linear, Kg, u_state; residual_model::Symbol=:tangent_operator)
    linear_force = K_linear * u_state
    geometric_force = Kg * u_state
    internal_force =
        if residual_model === :secant_geometric
            linear_force .+ 0.5 .* geometric_force
        else
            linear_force .+ geometric_force
        end
    return internal_force, linear_force, geometric_force
end

function _nonlinear_residual_metrics(K_linear, Kg, K_eff, F_applied, ndof, model, id_map, spc_id, rbe3_map, u_state;
                                     residual_model::Symbol=:tangent_operator)
    free_dofs, fixed_dofs, bc_diagnostics = compute_free_dofs(
        K_eff, ndof, model, id_map, spc_id, rbe3_map; return_diagnostics=true)
    internal_force, linear_force, geometric_force = _nonlinear_internal_force(
        K_linear, Kg, u_state; residual_model=residual_model)
    residual = internal_force - F_applied
    active_dofs = isempty(free_dofs) ? collect(1:ndof) : free_dofs
    residual_norm = norm(residual[active_dofs])
    internal_force_norm = norm(internal_force[active_dofs])
    linear_force_norm = norm(linear_force[active_dofs])
    geometric_force_norm = norm(geometric_force[active_dofs])
    force_norm = norm(F_applied[active_dofs])
    relative_residual = residual_norm / max(force_norm, 1e-30)
    return (
        residual_vector=residual,
        residual_norm=residual_norm,
        relative_residual=relative_residual,
        internal_force_norm=internal_force_norm,
        linear_force_norm=linear_force_norm,
        geometric_force_norm=geometric_force_norm,
        free_dofs=free_dofs,
        fixed_dofs=fixed_dofs,
        bc_diagnostics=bc_diagnostics,
    )
end

function _evaluate_nonlinear_state(K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
                                   snorm_normals, rbe3_map;
                                   residual_model::Symbol=:tangent_operator,
                                   geometric_stiffness_builder=nothing)
    Kg =
        geometric_stiffness_builder === nothing ?
        assemble_geometric_stiffness(model, id_map, X, node_R, ndof, u_state, snorm_normals, rbe3_map) :
        geometric_stiffness_builder(model, id_map, X, node_R, ndof, u_state, snorm_normals, rbe3_map)
    K_eff = K_linear + Kg
    residual = _nonlinear_residual_metrics(
        K_linear, Kg, K_eff, F_applied, ndof, model, id_map, spc_id, rbe3_map, u_state;
        residual_model=residual_model)
    return (
        Kg=Kg,
        K_eff=K_eff,
        residual_vector=residual.residual_vector,
        residual_norm=residual.residual_norm,
        relative_residual=residual.relative_residual,
        internal_force_norm=residual.internal_force_norm,
        linear_force_norm=residual.linear_force_norm,
        geometric_force_norm=residual.geometric_force_norm,
        free_dofs=residual.free_dofs,
        fixed_dofs=residual.fixed_dofs,
        bc_diagnostics=residual.bc_diagnostics,
    )
end

function _formal_vk_quad4_extra_energy(coords::AbstractMatrix, u_loc::AbstractVector{T}, Cm::AbstractMatrix) where {T}
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (-pt, -pt, pt, -pt, pt, pt, -pt, pt)
    energy_extra = zero(T)

    for gp in 1:4
        r = gauss_pts[2gp-1]
        s = gauss_pts[2gp]
        dNr, dNs = FEM.shape_derivs_quad(r, s)
        J = [dNr'; dNs'] * coords
        detJ = max(abs(det(J)), T(1e-12))
        dN = inv(J) * [dNr'; dNs']

        ux = zero(T); uy = zero(T); vx = zero(T); vy = zero(T); wx = zero(T); wy = zero(T)
        for a in 1:4
            base = (a-1) * 6
            dNx = dN[1, a]
            dNy = dN[2, a]
            ux += dNx * u_loc[base+1]
            uy += dNy * u_loc[base+1]
            vx += dNx * u_loc[base+2]
            vy += dNy * u_loc[base+2]
            wx += dNx * u_loc[base+3]
            wy += dNy * u_loc[base+3]
        end

        eps_lin = [ux, vy, uy + vx]
        half = T(0.5)
        eps_nl = [half * wx^2, half * wy^2, wx * wy]
        N_lin = Cm * eps_lin
        N_tot = Cm * (eps_lin + eps_nl)
        energy_extra += (half * dot(eps_lin + eps_nl, N_tot) - half * dot(eps_lin, N_lin)) * detJ
    end

    return energy_extra
end

function _formal_vk_tria3_extra_energy(coords::AbstractMatrix, u_loc::AbstractVector{T}, Cm::AbstractMatrix) where {T}
    x1, y1 = coords[1,1], coords[1,2]
    x2, y2 = coords[2,1], coords[2,2]
    x3, y3 = coords[3,1], coords[3,2]
    area2 = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
    area = abs(area2) / 2.0
    area < 1e-12 && return zero(T)

    dNdx = [(y2 - y3) / area2, (y3 - y1) / area2, (y1 - y2) / area2]
    dNdy = [(x3 - x2) / area2, (x1 - x3) / area2, (x2 - x1) / area2]

    ux = zero(T); uy = zero(T); vx = zero(T); vy = zero(T); wx = zero(T); wy = zero(T)
    for a in 1:3
        base = (a-1) * 6
        ux += dNdx[a] * u_loc[base+1]
        uy += dNdy[a] * u_loc[base+1]
        vx += dNdx[a] * u_loc[base+2]
        vy += dNdy[a] * u_loc[base+2]
        wx += dNdx[a] * u_loc[base+3]
        wy += dNdy[a] * u_loc[base+3]
    end

    eps_lin = [ux, vy, uy + vx]
    half = T(0.5)
    eps_nl = [half * wx^2, half * wy^2, wx * wy]
    N_lin = Cm * eps_lin
    N_tot = Cm * (eps_lin + eps_nl)
    return area * (half * dot(eps_lin + eps_nl, N_tot) - half * dot(eps_lin, N_lin))
end

function _formal_vk_quad4_extra_local(coords::AbstractMatrix, u_loc::AbstractVector, Cm::AbstractMatrix)
    energy_fun = u -> _formal_vk_quad4_extra_energy(coords, u, Cm)
    f_loc = ForwardDiff.gradient(energy_fun, u_loc)
    K_loc = ForwardDiff.hessian(energy_fun, u_loc)
    K_loc .= 0.5 .* (K_loc .+ K_loc')
    energy_extra = energy_fun(u_loc)
    return f_loc, K_loc, energy_extra
end

function _formal_vk_tria3_extra_local(coords::AbstractMatrix, u_loc::AbstractVector, Cm::AbstractMatrix)
    energy_fun = u -> _formal_vk_tria3_extra_energy(coords, u, Cm)
    f_loc = ForwardDiff.gradient(energy_fun, u_loc)
    K_loc = ForwardDiff.hessian(energy_fun, u_loc)
    K_loc .= 0.5 .* (K_loc .+ K_loc')
    energy_extra = energy_fun(u_loc)
    return f_loc, K_loc, energy_extra
end

function _formal_vk_accumulate_local_contribution!(I_idx::Vector{Int}, J_idx::Vector{Int}, V_val::Vector{Float64},
                                                   f_extra::Vector{Float64}, dofs::Vector{Int},
                                                   f_glob::AbstractVector, K_glob::AbstractMatrix)
    for a in eachindex(dofs)
        f_extra[dofs[a]] += f_glob[a]
    end
    for cidx in eachindex(dofs), ridx in eachindex(dofs)
        val = K_glob[ridx, cidx]
        abs(val) <= 0.0 && continue
        push!(I_idx, dofs[ridx])
        push!(J_idx, dofs[cidx])
        push!(V_val, val)
    end
end

function _formal_vk_tria3_global_contribution(prop, el, mat, tri_indices::NTuple{3,Int},
                                              tri_points::NTuple{3,SVector{3,Float64}},
                                              node_R, u_state, snorm_normals;
                                              constitutive_tri::Bool=true,
                                              constitutive_edge::Tuple{SVector{3,Float64},SVector{3,Float64}}=(tri_points[1], tri_points[2]))
    i1, i2, i3 = tri_indices
    p1, p2, p3 = tri_points
    v1, v2, v3 = shell_element_frame_fast(p1, p2, p3, p3, 3)
    v1, v2, v3 = apply_snorm_to_frame(v1, v2, v3, [i1, i2, i3], snorm_normals)
    Rel_t = Matrix(vcat(v1', v2', v3'))
    c = (p1 + p2 + p3) / 3.0
    lc = zeros(3, 2)
    lc[1,1] = dot(p1-c, v1); lc[1,2] = dot(p1-c, v2)
    lc[2,1] = dot(p2-c, v1); lc[2,2] = dot(p2-c, v2)
    lc[3,1] = dot(p3-c, v1); lc[3,2] = dot(p3-c, v2)
    u_loc = zeros(18)
    T_buf = zeros(18, 18)
    for (k, idx) in enumerate((i1, i2, i3))
        base = (k-1) * 6
        TR = Rel_t * node_R[idx]
        T_buf[base+1:base+3, base+1:base+3] .= TR
        T_buf[base+4:base+6, base+4:base+6] .= TR
        u_loc[base+1:base+3] .= TR * u_state[(idx-1)*6+1:(idx-1)*6+3]
        u_loc[base+4:base+6] .= TR * u_state[(idx-1)*6+4:(idx-1)*6+6]
    end

    ref_p1, ref_p2 = constitutive_edge
    Cm = _formal_shell_membrane_constitutive(prop, el, mat, v1, v2, v3, ref_p1, ref_p2; tri=constitutive_tri)
    f_loc, K_loc, e_extra = _formal_vk_tria3_extra_local(lc, u_loc, Cm)
    f_glob = T_buf' * f_loc
    K_glob = T_buf' * K_loc * T_buf
    dofs = vcat([(idx-1)*6 .+ collect(1:6) for idx in (i1, i2, i3)]...)
    return dofs, f_glob, K_glob, e_extra
end

function _assemble_formal_shell_von_karman_extra(model, id_map, X, node_R, ndof, u_state, snorm_normals)
    I_idx = Int[]
    J_idx = Int[]
    V_val = Float64[]
    f_extra = zeros(ndof)
    q4_frame_mode = q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC")
    energy_extra = 0.0
    shell_count = 0
    warped_quad_fallback_count = 0
    warped_quad_split_triangle_count = 0

    for (_, el) in get(model, "CSHELLs", Dict())
        pid = string(get(el, "PID", 0))
        haskey(model["PSHELLs"], pid) || continue
        prop = model["PSHELLs"][pid]
        nids = get(el, "NODES", Int[])
        any(nid -> !haskey(id_map, nid), nids) && continue
        n = length(nids)

        if n == 4
            i1, i2, i3, i4 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]], id_map[nids[4]]
            p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
            p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
            p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3])
            p4 = SVector{3}(X[i4,1], X[i4,2], X[i4,3])
            mid = string(get(prop, "MID", 0))
            mat = _effective_mat1_for_nodes(model, mid, nids)
            if _quad4_is_coplanar(p1, p2, p3, p4)
                v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
                v1, v2, v3 = apply_snorm_to_frame(v1, v2, v3, [i1, i2, i3, i4], snorm_normals)
                Rel_t = Matrix(vcat(v1', v2', v3'))
                c = (p1 + p2 + p3 + p4) / 4.0
                lc = zeros(4, 2)
                lc[1,1]=dot(p1-c,v1); lc[1,2]=dot(p1-c,v2)
                lc[2,1]=dot(p2-c,v1); lc[2,2]=dot(p2-c,v2)
                lc[3,1]=dot(p3-c,v1); lc[3,2]=dot(p3-c,v2)
                lc[4,1]=dot(p4-c,v1); lc[4,2]=dot(p4-c,v2)
                u_loc = zeros(24)
                T_buf = zeros(24, 24)
                for (k, idx) in enumerate((i1, i2, i3, i4))
                    base = (k-1) * 6
                    TR = Rel_t * node_R[idx]
                    T_buf[base+1:base+3, base+1:base+3] .= TR
                    T_buf[base+4:base+6, base+4:base+6] .= TR
                    u_loc[base+1:base+3] .= TR * u_state[(idx-1)*6+1:(idx-1)*6+3]
                    u_loc[base+4:base+6] .= TR * u_state[(idx-1)*6+4:(idx-1)*6+6]
                end
                Cm = _formal_shell_membrane_constitutive(prop, el, mat, v1, v2, v3, p1, p2; tri=false)
                f_loc, K_loc, e_extra = _formal_vk_quad4_extra_local(lc, u_loc, Cm)
                energy_extra += e_extra
                f_glob = T_buf' * f_loc
                K_glob = T_buf' * K_loc * T_buf
                dofs = vcat([(idx-1)*6 .+ collect(1:6) for idx in (i1, i2, i3, i4)]...)
                _formal_vk_accumulate_local_contribution!(I_idx, J_idx, V_val, f_extra, dofs, f_glob, K_glob)
            else
                warped_quad_fallback_count += 1
                constitutive_edge = (p1, p2)
                for (tri_indices, tri_points) in (
                    ((i1, i2, i3), (p1, p2, p3)),
                    ((i1, i3, i4), (p1, p3, p4)),
                )
                    dofs, f_glob, K_glob, e_extra = _formal_vk_tria3_global_contribution(
                        prop, el, mat, tri_indices, tri_points, node_R, u_state, snorm_normals;
                        constitutive_tri=false,
                        constitutive_edge=constitutive_edge,
                    )
                    energy_extra += e_extra
                    _formal_vk_accumulate_local_contribution!(I_idx, J_idx, V_val, f_extra, dofs, f_glob, K_glob)
                    warped_quad_split_triangle_count += 1
                end
            end
            shell_count += 1
        elseif n == 3
            i1, i2, i3 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]]
            p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
            p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
            p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3])
            mid = string(get(prop, "MID", 0))
            mat = get(model["MATs"], mid, Dict{String,Any}())
            dofs, f_glob, K_glob, e_extra = _formal_vk_tria3_global_contribution(
                prop, el, mat, (i1, i2, i3), (p1, p2, p3), node_R, u_state, snorm_normals;
                constitutive_tri=true,
                constitutive_edge=(p1, p2),
            )
            energy_extra += e_extra
            _formal_vk_accumulate_local_contribution!(I_idx, J_idx, V_val, f_extra, dofs, f_glob, K_glob)
            shell_count += 1
        end
    end

    K_extra = sparse(I_idx, J_idx, V_val, ndof, ndof)
    K_extra = 0.5 * (K_extra + K_extra')
    return f_extra, K_extra, Dict(
        "shell_count" => shell_count,
        "warped_quad_fallback_count" => warped_quad_fallback_count,
        "warped_quad_split_triangle_count" => warped_quad_split_triangle_count,
        "extra_energy" => energy_extra,
        "operator_nnz" => nnz(K_extra),
        "operator_norm" => nnz(K_extra) == 0 ? 0.0 : norm(K_extra.nzval),
        "operator_backend" => "forwarddiff_hessian",
    )
end

function _evaluate_nonlinear_state_formal(K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
                                          snorm_normals, rbe3_map)
    f_extra, K_extra, formal_diag = _assemble_formal_shell_von_karman_extra(
        model, id_map, X, node_R, ndof, u_state, snorm_normals)
    K_eff = K_linear + K_extra
    free_dofs, fixed_dofs, bc_diagnostics = compute_free_dofs(
        K_eff, ndof, model, id_map, spc_id, rbe3_map; return_diagnostics=true)
    linear_force = K_linear * u_state
    internal_force = linear_force + f_extra
    residual_vector = internal_force - F_applied
    active_dofs = isempty(free_dofs) ? collect(1:ndof) : free_dofs
    residual_norm = norm(residual_vector[active_dofs])
    force_norm = norm(F_applied[active_dofs])
    relative_residual = residual_norm / max(force_norm, 1e-30)
    nonlinear_force_norm = norm(f_extra[active_dofs])
    linear_strain_energy = 0.5 * dot(u_state, linear_force)
    internal_energy = linear_strain_energy + formal_diag["extra_energy"]
    potential_energy = internal_energy - dot(F_applied, u_state)
    return (
        Kg=K_extra,
        K_eff=K_eff,
        residual_vector=residual_vector,
        residual_norm=residual_norm,
        relative_residual=relative_residual,
        internal_force_norm=norm(internal_force[active_dofs]),
        linear_force_norm=norm(linear_force[active_dofs]),
        geometric_force_norm=nonlinear_force_norm,
        nonlinear_force_norm=nonlinear_force_norm,
        linear_strain_energy=linear_strain_energy,
        internal_energy=internal_energy,
        potential_energy=potential_energy,
        free_dofs=free_dofs,
        fixed_dofs=fixed_dofs,
        bc_diagnostics=bc_diagnostics,
        formal_diagnostics=formal_diag,
    )
end

_state_field(state, name::Symbol, default) =
    name in propertynames(state) ? getproperty(state, name) : default

@inline function _metric_reduced(after::Real, before::Real; rtol::Float64=1e-12, atol::Float64=1e-30)
    slack = max(atol, rtol * max(abs(before), abs(after), 1.0))
    return after <= before + slack
end

@inline function _normalized_residual_improvement(current_relative_residual::Real,
                                                  trial_relative_residual::Real)
    current = max(Float64(current_relative_residual), eps(Float64))
    return (Float64(current_relative_residual) - Float64(trial_relative_residual)) / current
end

@inline function _step_contraction_cost(step_scale::Real)
    return max(-log2(max(Float64(step_scale), eps(Float64))), 0.0)
end

@inline function _formal_cleanup_improvement_sufficient(current_relative_residual::Real,
                                                        trial_relative_residual::Real,
                                                        step_scale::Real,
                                                        efficiency_lambda::Float64)
    improvement = _normalized_residual_improvement(current_relative_residual, trial_relative_residual)
    return improvement >= efficiency_lambda * _step_contraction_cost(step_scale)
end

@inline function _line_search_merit(state)
    residual_norm = Float64(state.residual_norm)
    return 0.5 * residual_norm * residual_norm
end

@inline function _line_search_merit_directional_derivative(state)
    residual_norm = Float64(state.residual_norm)
    return -(residual_norm * residual_norm)
end

function _step_growth_quality(step_records)
    if isempty(step_records)
        return (
            eligible=false,
            all_full_step_iterations=false,
            monotone_residual_acceptance=false,
            used_best_available_trial=false,
            max_line_search_backtracks=0,
            max_accepted_trial_index=0,
        )
    end

    all_full_step_iterations = true
    monotone_residual_acceptance = true
    used_best_available_trial = false
    max_line_search_backtracks = 0
    max_accepted_trial_index = 0

    for iter in step_records
        all_full_step_iterations &= Float64(get(iter, "accepted_step_scale", 0.0)) >= 0.99
        monotone_residual_acceptance &= (
            Bool(get(iter, "residual_reduced", false)) ||
            String(get(iter, "accepted_by", "")) == "residual_tolerance"
        )
        used_best_available_trial |= Bool(get(iter, "used_best_available_trial", false))
        max_line_search_backtracks = max(
            max_line_search_backtracks,
            max(length(get(iter, "line_search_trials", Any[])) - 1, 0),
        )
        max_accepted_trial_index = max(max_accepted_trial_index, Int(get(iter, "accepted_trial_index", 0)))
    end

    eligible =
        all_full_step_iterations &&
        monotone_residual_acceptance &&
        !used_best_available_trial &&
        max_line_search_backtracks == 0

    return (
        eligible=eligible,
        all_full_step_iterations=all_full_step_iterations,
        monotone_residual_acceptance=monotone_residual_acceptance,
        used_best_available_trial=used_best_available_trial,
        max_line_search_backtracks=max_line_search_backtracks,
        max_accepted_trial_index=max_accepted_trial_index,
    )
end

function _cutback_recovery_quality(initial_relative_residual::Real, final_relative_residual::Real,
                                   attempted_increment::Real, requested_increment::Real)
    safe_initial = max(Float64(initial_relative_residual), 1e-30)
    safe_final = max(Float64(final_relative_residual), 1e-30)
    safe_attempted = max(Float64(attempted_increment), 1e-30)
    reference_ratio = max(Float64(requested_increment) / safe_attempted, 1.0)
    contraction_ratio = max(safe_initial / safe_final, 1.0)
    proposed_ratio = sqrt(contraction_ratio)
    bracket_midpoint_ratio = sqrt(reference_ratio)
    accepted_ratio = min(bracket_midpoint_ratio, max(1.0, proposed_ratio))
    return (
        contraction_ratio=contraction_ratio,
        reference_ratio=reference_ratio,
        bracket_midpoint_ratio=bracket_midpoint_ratio,
        proposed_ratio=proposed_ratio,
        accepted_ratio=accepted_ratio,
    )
end

function _solve_nonlinear_correction(K_eff, residual_rhs, ndof, model, id_map, spc_id, rbe3_map;
                                     free_dofs=nothing, fixed_dofs=nothing, bc_diagnostics=nothing)
    reused_state_partition = !(isnothing(free_dofs) || isnothing(fixed_dofs) || isnothing(bc_diagnostics))
    if !reused_state_partition
        free_dofs, fixed_dofs, bc_diagnostics = compute_free_dofs(
            K_eff, ndof, model, id_map, spc_id, rbe3_map; return_diagnostics=true)
    end
    correction = zeros(ndof)

    if isempty(free_dofs)
        return correction, Dict{String,Any}(
            "backend" => "empty_system",
            "free_dofs" => 0,
            "fixed_dofs" => length(fixed_dofs),
            "rhs_norm" => 0.0,
            "relative_residual" => 0.0,
            "bc_partition" => bc_diagnostics,
            "reused_state_partition" => reused_state_partition,
        )
    end

    K_ff = K_eff[free_dofs, free_dofs]
    K_ff = 0.5 * (K_ff + K_ff')
    rhs_ff = residual_rhs[free_dofs]
    backend = "direct_cholesky"
    used_lu_fallback = false

    delta_ff = if norm(rhs_ff) <= 1e-30
        zeros(length(free_dofs))
    else
        try
            cholesky(Symmetric(K_ff)) \ rhs_ff
        catch
            backend = "direct_lu"
            used_lu_fallback = true
            lu(K_ff) \ rhs_ff
        end
    end

    correction[free_dofs] = delta_ff
    if !isempty(rbe3_map)
        for (dep_dof, pairs) in rbe3_map
            correction[dep_dof] = sum(coeff * correction[ind_dof] for (ind_dof, coeff) in pairs)
        end
    end

    solve_residual = K_ff * delta_ff - rhs_ff
    rel_residual = norm(solve_residual) / max(norm(rhs_ff), 1e-30)
    diagnostics = Dict{String,Any}(
        "backend" => backend,
        "used_lu_fallback" => used_lu_fallback,
        "free_dofs" => length(free_dofs),
        "fixed_dofs" => length(fixed_dofs),
        "rhs_norm" => norm(rhs_ff),
        "residual_norm" => norm(solve_residual),
        "relative_residual" => rel_residual,
        "bc_partition" => bc_diagnostics,
        "reused_state_partition" => reused_state_partition,
    )
    return correction, diagnostics
end

function solve_case(K, ndof, model, id_map, X, load_id, spc_id, node_R;
                    max_elem_stiff=0.0,
                    rbe3_map=Dict{Int,Vector{Tuple{Int,Float64}}}(),
                    snorm_normals=Dict{Int,SVector{3,Float64}}(),
                    orig_diag=Float64[],
                    load_scale::Float64=1.0,
                    temp_load_id=nothing,
                    linear_cache=nothing,
                    build_results::Bool=true)
    F_applied = _assemble_applied_force(
        ndof, model, id_map, X, load_id, node_R, rbe3_map;
        load_scale=load_scale,
        temp_load_id=temp_load_id,
        log_rbe3=true,
    )

    # SPCD enforced displacements (selected by the LOAD set, Nastran
    # semantics; the dof must also be SPC'd).  Applied as the equivalent
    # load on the free set (F -= K[:,s]*u_s), with the prescribed values
    # scattered into u_global after the solve.
    spcd_entries = Tuple{Int,Float64}[]
    for e in get(model, "SPCDs", [])
        e isa AbstractDict || continue
        Int(get(e, "SID", -1)) == Int(load_id) || continue
        g = Int(get(e, "GID", 0))
        haskey(id_map, g) || continue
        d = Int(get(e, "C", 0))
        1 <= d <= 6 || continue
        push!(spcd_entries, ((id_map[g] - 1) * 6 + d,
                             Float64(get(e, "D", 0.0)) * load_scale))
    end
    F_resid = F_applied
    if !isempty(spcd_entries)
        F_applied = copy(F_applied)
        for (dof, val) in spcd_entries
            val == 0.0 && continue
            F_applied .-= Vector(K[:, dof]) .* val
        end
        log_msg("[SOLVER] SPCD: $(length(spcd_entries)) enforced displacement(s) applied (load set $load_id)")
    end

    # Safe _spc_id mutation: preserve any prior value and restore via
    # try/finally so that an exception in apply_bc_and_solve does not leak
    # the temporary key into shared `model` state. (Phase B1 hygiene
    # per architectural-cleanup 2026-05-24.)
    prev_spc_id = get(model, "_spc_id", nothing)
    had_prev_spc_id = haskey(model, "_spc_id")
    model["_spc_id"] = spc_id
    local u_global, fixed_dofs, solver_diagnostics
    try
        u_global, fixed_dofs, _, solver_diagnostics = apply_bc_and_solve(
            K, ndof, model, id_map, F_applied, node_R, rbe3_map, max_elem_stiff, orig_diag;
            linear_cache=linear_cache)
    finally
        if had_prev_spc_id
            model["_spc_id"] = prev_spc_id
        else
            delete!(model, "_spc_id")
        end
    end

    if !isempty(spcd_entries)
        for (dof, val) in spcd_entries
            if dof in fixed_dofs
                u_global[dof] = val
            else
                log_msg("[SOLVER] WARNING: SPCD on unconstrained dof $dof ignored (dof must be in the SPC set)")
            end
        end
    end

    # Callers that only need the displacement field (e.g. the SOL 105 static
    # reference solve feeding Kg) skip stress recovery and result-row
    # building entirely — previously computed unconditionally and discarded
    # (measured pure waste, PERF_AUDIT_SOL105_2026_08_05 item 9).
    if !build_results
        return nothing, nothing, nothing, u_global, fixed_dofs
    end

    R = K * u_global - F_resid
    u_out, stresses, results_json = _build_results_from_state(
        ndof, model, id_map, X, node_R, u_global, R, snorm_normals, solver_diagnostics;
        active_load_id=load_id,
        active_load_scale=Float64(load_scale),
    )

    return u_out, stresses, results_json, u_global, fixed_dofs
end

function solve_nonlinear_static(K_linear, ndof, model, id_map, X, load_id, spc_id, node_R;
                                load_steps::Int=4,
                                max_iter::Int=8,
                                tol::Float64=1e-6,
                                relaxation::Float64=1.0,
                                residual_tol::Float64=1e-6,
                                residual_model::Symbol=:tangent_operator,
                                nonlinear_method::Symbol=:auto,
                                line_search_max_backtracks::Int=6,
                                line_search_reduction::Float64=0.5,
                                max_cutbacks::Int=6,
                                cutback_reduction::Float64=0.5,
                                step_growth::Float64=1.25,
                                max_elem_stiff=0.0,
                                rbe3_map=Dict{Int,Vector{Tuple{Int,Float64}}}(),
                                snorm_normals=Dict{Int,SVector{3,Float64}}(),
                                orig_diag=Float64[],
                                temp_load_id=nothing,
                                geometric_stiffness_builder=nothing,
                                nonlinear_state_builder=nothing)
    load_steps = max(load_steps, 1)
    max_iter = max(max_iter, 1)
    relaxation = clamp(relaxation, 1e-3, 1.0)
    residual_tol = max(residual_tol, 1e-12)
    residual_model = residual_model in (:secant_geometric, :tangent_operator) ? residual_model : :tangent_operator
    formal_support = _formal_von_karman_shell_support_report(model, id_map, X)
    formal_supported = formal_support.supported
    nonlinear_method =
        if nonlinear_method === :formal_shell_von_karman
            formal_supported || error("[SOLVER] PARAM_NLMETHOD=formal_shell_von_karman requested, but the model is outside the currently supported flat-shell subset")
            :formal_shell_von_karman
        else
            :legacy_geometric
        end
    line_search_max_backtracks = max(line_search_max_backtracks, 0)
    line_search_reduction = clamp(line_search_reduction, 0.1, 0.9)
    max_cutbacks = max(max_cutbacks, 0)
    cutback_reduction = clamp(cutback_reduction, 0.1, 0.9)
    step_growth = max(step_growth, 1.0)
    formal_armijo_c1 = 1e-4
    near_converged_residual_band = 5.0 * residual_tol
    near_converged_efficiency_lambda = 1e-3

    u_committed = zeros(ndof)
    load_history = Any[]
    final_bundle = nothing
    final_state_summary = nothing
    nominal_increment = 1.0 / load_steps
    next_increment = nominal_increment
    current_load_scale = 0.0
    accepted_step = 0
    terminated_early = false
    state_evaluation_count = 0
    correction_partition_reuse_count = 0
    accepted_state_reuse_count = 0
    step_growth_applied_count = 0
    evaluate_state = nonlinear_state_builder !== nothing ?
        (u_state, F_step) -> nonlinear_state_builder(
            K_linear, F_step, ndof, model, id_map, X, spc_id, node_R,
            u_state, snorm_normals, rbe3_map;
            residual_model=residual_model,
        ) :
        nonlinear_method === :formal_shell_von_karman ?
        (u_state, F_step) -> _evaluate_nonlinear_state_formal(
            K_linear, F_step, ndof, model, id_map, X, spc_id, node_R, u_state, snorm_normals, rbe3_map
        ) :
        (u_state, F_step) -> _evaluate_nonlinear_state(
            K_linear, F_step, ndof, model, id_map, X, spc_id, node_R, u_state, snorm_normals, rbe3_map;
            residual_model=residual_model,
            geometric_stiffness_builder=geometric_stiffness_builder,
        )

    while current_load_scale < 1.0 - 1e-12
        remaining = 1.0 - current_load_scale
        attempted_increment = min(next_increment, remaining)
        requested_increment = attempted_increment
        recovery_reference_increment = requested_increment
        attempted_scale = current_load_scale + attempted_increment
        cutback_count = 0
        attempt_history = Any[]
        step_start_state = copy(u_committed)
        step_accepted = false

        while !step_accepted
            F_step = _assemble_applied_force(
                ndof, model, id_map, X, load_id, node_R, rbe3_map;
                load_scale=attempted_scale,
                temp_load_id=temp_load_id,
                log_rbe3=false,
            )
            u_iter = copy(step_start_state)
            step_records = Any[]
            step_converged = false
            final_rel_change = Inf
            final_rel_residual = Inf
            final_relative_incremental_work = Inf
            initial_rel_residual = Inf
            last_accepted_state = nothing
            for iter in 1:max_iter
                current_state = evaluate_state(u_iter, F_step)
                state_evaluation_count += 1
                if iter == 1
                    initial_rel_residual = current_state.relative_residual
                end

                residual_rhs = -current_state.residual_vector
                delta_u, correction_diagnostics = _solve_nonlinear_correction(
                    current_state.K_eff, residual_rhs, ndof, model, id_map, spc_id, rbe3_map,
                    free_dofs=current_state.free_dofs,
                    fixed_dofs=current_state.fixed_dofs,
                    bc_diagnostics=current_state.bc_diagnostics,
                )
                if get(correction_diagnostics, "reused_state_partition", false)
                    correction_partition_reuse_count += 1
                end

                line_search_trials = Any[]
                accepted_alpha = 0.0
                accepted_candidate = copy(u_iter)
                accepted_state = nothing
                accepted_reason = "rejected"
                accepted_trial_index = 0
                best_accepted_alpha = 0.0
                best_accepted_candidate = copy(u_iter)
                best_accepted_state = nothing
                best_accepted_reason = "rejected"
                best_accepted_trial_index = 0
                best_accepted_score = nothing
                best_accepted_is_residual_based = false
                best_alpha = 0.0
                best_candidate = copy(u_iter)
                best_state = nothing
                best_metric = Inf
                best_trial_index = 0
                alpha = relaxation
                current_potential = _state_field(current_state, :potential_energy, nothing)
                directional_derivative = dot(current_state.residual_vector, delta_u)
                current_line_search_merit = _line_search_merit(current_state)
                line_search_merit_directional_derivative = _line_search_merit_directional_derivative(current_state)

                for ls_trial in 1:(line_search_max_backtracks + 1)
                    candidate = u_iter .+ alpha .* delta_u
                    candidate_state = evaluate_state(candidate, F_step)
                    state_evaluation_count += 1
                    candidate_rel_change = norm(alpha .* delta_u) / max(norm(candidate), 1e-30)
                    candidate_formal = _state_field(candidate_state, :formal_diagnostics, Dict{String,Any}())
                    candidate_potential = _state_field(candidate_state, :potential_energy, nothing)
                    candidate_merit = _line_search_merit(candidate_state)
                    armijo_satisfied = false
                    if nonlinear_method === :formal_shell_von_karman &&
                       !(isnothing(current_potential) || isnothing(candidate_potential)) &&
                       directional_derivative < 0.0
                        armijo_satisfied =
                            candidate_potential <= current_potential + formal_armijo_c1 * alpha * directional_derivative
                    end
                    residual_reduced = _metric_reduced(candidate_state.relative_residual, current_state.relative_residual)
                    internal_force_reduced = _metric_reduced(candidate_state.internal_force_norm, current_state.internal_force_norm)
                    potential_reduced =
                        if isnothing(current_potential) || isnothing(candidate_potential)
                            missing
                        else
                            _metric_reduced(candidate_potential, current_potential)
                        end
                    acceptance_reason =
                        if candidate_state.relative_residual <= residual_tol
                            "residual_tolerance"
                        elseif residual_reduced
                            "residual_reduction"
                        elseif armijo_satisfied
                            "armijo"
                        else
                            "rejected"
                        end
                    push!(line_search_trials, Dict(
                        "trial" => ls_trial,
                        "step_scale" => alpha,
                        "merit" => candidate_merit,
                        "relative_change" => candidate_rel_change,
                        "internal_force_norm" => candidate_state.internal_force_norm,
                        "linear_force_norm" => candidate_state.linear_force_norm,
                        "geometric_force_norm" => candidate_state.geometric_force_norm,
                        "potential_energy" => isnothing(candidate_potential) ? missing : candidate_potential,
                        "armijo_satisfied" => armijo_satisfied,
                        "formal_operator_nnz" => get(candidate_formal, "operator_nnz", 0),
                        "formal_operator_norm" => get(candidate_formal, "operator_norm", 0.0),
                        "formal_extra_energy" => get(candidate_formal, "extra_energy", 0.0),
                        "formal_shell_count" => get(candidate_formal, "shell_count", 0),
                        "residual_norm" => candidate_state.residual_norm,
                        "relative_residual" => candidate_state.relative_residual,
                        "residual_reduced" => residual_reduced,
                        "internal_force_reduced" => internal_force_reduced,
                        "potential_reduced" => potential_reduced,
                        "acceptance_reason" => acceptance_reason,
                        "kg_nnz" => nnz(candidate_state.Kg),
                        "kg_norm" => norm(candidate_state.Kg.nzval),
                    ))

                    if best_state === nothing || candidate_merit < best_metric
                        best_alpha = alpha
                        best_candidate = copy(candidate)
                        best_state = candidate_state
                        best_metric = candidate_merit
                        best_trial_index = ls_trial
                    end

                    if acceptance_reason != "rejected"
                        if nonlinear_method === :formal_shell_von_karman
                            near_converged_cleanup_active =
                                current_state.relative_residual <= near_converged_residual_band
                            if acceptance_reason == "residual_tolerance"
                                accepted_alpha = alpha
                                accepted_candidate = candidate
                                accepted_state = candidate_state
                                accepted_reason = acceptance_reason
                                accepted_trial_index = ls_trial
                                break
                            elseif residual_reduced
                                candidate_score = (
                                    Float64(candidate_state.relative_residual),
                                    -Float64(alpha),
                                    Int(ls_trial),
                                )
                                if ls_trial == 1
                                    accepted_alpha = alpha
                                    accepted_candidate = candidate
                                    accepted_state = candidate_state
                                    accepted_reason = acceptance_reason
                                    accepted_trial_index = ls_trial
                                    break
                                elseif near_converged_cleanup_active
                                    if _formal_cleanup_improvement_sufficient(
                                           current_state.relative_residual,
                                           candidate_state.relative_residual,
                                           alpha,
                                           near_converged_efficiency_lambda,
                                       )
                                        accepted_alpha = alpha
                                        accepted_candidate = candidate
                                        accepted_state = candidate_state
                                        accepted_reason = acceptance_reason
                                        accepted_trial_index = ls_trial
                                        break
                                    elseif best_accepted_state === nothing
                                        best_accepted_alpha = alpha
                                        best_accepted_candidate = copy(candidate)
                                        best_accepted_state = candidate_state
                                        best_accepted_reason = acceptance_reason
                                        best_accepted_trial_index = ls_trial
                                    end
                                elseif !best_accepted_is_residual_based ||
                                       isnothing(best_accepted_score) ||
                                       candidate_score < best_accepted_score
                                    best_accepted_alpha = alpha
                                    best_accepted_candidate = copy(candidate)
                                    best_accepted_state = candidate_state
                                    best_accepted_reason = acceptance_reason
                                    best_accepted_trial_index = ls_trial
                                    best_accepted_score = candidate_score
                                    best_accepted_is_residual_based = true
                                end
                            elseif !best_accepted_is_residual_based && best_accepted_state === nothing
                                best_accepted_alpha = alpha
                                best_accepted_candidate = copy(candidate)
                                best_accepted_state = candidate_state
                                best_accepted_reason = acceptance_reason
                                best_accepted_trial_index = ls_trial
                            end
                        else
                            accepted_alpha = alpha
                            accepted_candidate = candidate
                            accepted_state = candidate_state
                            accepted_reason = acceptance_reason
                            accepted_trial_index = ls_trial
                            break
                        end
                    end

                    alpha *= line_search_reduction
                end

                if accepted_state === nothing &&
                   nonlinear_method === :formal_shell_von_karman &&
                   best_accepted_state !== nothing
                    accepted_alpha = best_accepted_alpha
                    accepted_candidate = best_accepted_candidate
                    accepted_state = best_accepted_state
                    accepted_reason = best_accepted_reason
                    accepted_trial_index = best_accepted_trial_index
                elseif accepted_state === nothing
                    accepted_alpha = best_alpha
                    accepted_candidate = best_candidate
                    accepted_state = best_state
                    accepted_reason = "best_available_trial"
                    accepted_trial_index = best_trial_index
                end

                u_iter .= accepted_candidate
                last_accepted_state = accepted_state
                rel_change = norm(accepted_alpha .* delta_u) / max(norm(u_iter), 1e-30)
                reference_work = max(abs(dot(u_iter, F_step)), 1e-30)
                relative_incremental_work =
                    abs(dot(accepted_alpha .* delta_u, current_state.residual_vector)) / reference_work
                final_rel_change = rel_change
                final_rel_residual = accepted_state.relative_residual
                final_relative_incremental_work = relative_incremental_work
                current_formal = _state_field(current_state, :formal_diagnostics, Dict{String,Any}())
                accepted_formal = _state_field(accepted_state, :formal_diagnostics, Dict{String,Any}())
                accepted_residual_reduced = _metric_reduced(accepted_state.relative_residual, current_state.relative_residual)
                accepted_internal_force_reduced = _metric_reduced(accepted_state.internal_force_norm, current_state.internal_force_norm)
                accepted_potential = _state_field(accepted_state, :potential_energy, nothing)
                accepted_potential_reduced =
                    if isnothing(current_potential) || isnothing(accepted_potential)
                        missing
                    else
                        _metric_reduced(accepted_potential, current_potential)
                    end
                push!(step_records, Dict(
                    "iteration" => iter,
                    "load_scale" => attempted_scale,
                    "load_increment" => attempted_increment,
                    "relative_change" => rel_change,
                    "directional_derivative" => directional_derivative,
                    "line_search_merit_before" => current_line_search_merit,
                    "line_search_merit_directional_derivative" => line_search_merit_directional_derivative,
                    "correction_rhs_norm" => norm(residual_rhs),
                    "correction_solver" => correction_diagnostics,
                    "internal_force_norm_before" => current_state.internal_force_norm,
                    "linear_force_norm_before" => current_state.linear_force_norm,
                    "geometric_force_norm_before" => current_state.geometric_force_norm,
                    "potential_energy_before" => isnothing(current_potential) ? missing : current_potential,
                    "formal_operator_nnz_before" => get(current_formal, "operator_nnz", 0),
                    "formal_operator_norm_before" => get(current_formal, "operator_norm", 0.0),
                    "formal_extra_energy_before" => get(current_formal, "extra_energy", 0.0),
                    "formal_shell_count_before" => get(current_formal, "shell_count", 0),
                    "residual_norm_before" => current_state.residual_norm,
                    "relative_residual_before" => current_state.relative_residual,
                    "internal_force_norm_after" => accepted_state.internal_force_norm,
                    "linear_force_norm_after" => accepted_state.linear_force_norm,
                    "geometric_force_norm_after" => accepted_state.geometric_force_norm,
                    "potential_energy_after" => let pe = _state_field(accepted_state, :potential_energy, nothing)
                        isnothing(pe) ? missing : pe
                    end,
                    "formal_operator_nnz_after" => get(accepted_formal, "operator_nnz", 0),
                    "formal_operator_norm_after" => get(accepted_formal, "operator_norm", 0.0),
                    "formal_extra_energy_after" => get(accepted_formal, "extra_energy", 0.0),
                    "formal_shell_count_after" => get(accepted_formal, "shell_count", 0),
                    "residual_norm_after" => accepted_state.residual_norm,
                    "relative_residual_after" => accepted_state.relative_residual,
                    "accepted_step_scale" => accepted_alpha,
                    "accepted_trial_index" => accepted_trial_index,
                    "accepted_by" => accepted_reason,
                    "used_best_available_trial" => accepted_reason == "best_available_trial",
                    "line_search_merit_after" => _line_search_merit(accepted_state),
                    "relative_incremental_work" => relative_incremental_work,
                    "line_search_selection_policy" => nonlinear_method === :formal_shell_von_karman ?
                        "prefer_non_worsening_residual_then_larger_armijo_step" :
                        "first_acceptable_trial",
                    "near_converged_cleanup_gate_active" =>
                        nonlinear_method === :formal_shell_von_karman &&
                        current_state.relative_residual <= near_converged_residual_band,
                    "near_converged_cleanup_efficiency_lambda" =>
                        nonlinear_method === :formal_shell_von_karman ? near_converged_efficiency_lambda : 0.0,
                    "minimum_merit_trial_index" => best_trial_index,
                    "minimum_merit_step_scale" => best_alpha,
                    "minimum_merit_value" => best_metric,
                    "minimum_acceptable_trial_index" =>
                        nonlinear_method === :formal_shell_von_karman && best_accepted_state !== nothing ?
                        best_accepted_trial_index :
                        accepted_trial_index,
                    "minimum_acceptable_step_scale" =>
                        nonlinear_method === :formal_shell_von_karman && best_accepted_state !== nothing ?
                        best_accepted_alpha :
                        accepted_alpha,
                    "accepted_is_minimum_merit_trial" => accepted_trial_index == best_trial_index,
                    "accepted_is_minimum_acceptable_trial" =>
                        accepted_trial_index ==
                        (nonlinear_method === :formal_shell_von_karman && best_accepted_state !== nothing ?
                         best_accepted_trial_index :
                         accepted_trial_index),
                    "residual_reduced" => accepted_residual_reduced,
                    "internal_force_reduced" => accepted_internal_force_reduced,
                    "potential_reduced" => accepted_potential_reduced,
                    "line_search_trials" => line_search_trials,
                    "kg_nnz" => nnz(accepted_state.Kg),
                    "kg_norm" => norm(accepted_state.Kg.nzval),
                ))

                log_msg("[SOLVER] NL target=$(round(attempted_scale, sigdigits=4)) iter $iter: rel_change=$(round(rel_change, sigdigits=4)), rel_res_before=$(round(current_state.relative_residual, sigdigits=4)), rel_res_after=$(round(accepted_state.relative_residual, sigdigits=4)), alpha=$(round(accepted_alpha, sigdigits=4))")

                if accepted_state.relative_residual < residual_tol &&
                   (rel_change < tol || relative_incremental_work < tol)
                    step_converged = true
                    break
                end
            end

            reused_final_state = last_accepted_state !== nothing
            final_state = if reused_final_state
                accepted_state_reuse_count += 1
                last_accepted_state
            else
                state_evaluation_count += 1
                evaluate_state(u_iter, F_step)
            end
            final_solver_diagnostics = Dict{String,Any}(
                "backend" => "nonlinear_postprocess",
                "bc_partition" => final_state.bc_diagnostics,
                "residual_norm" => final_state.residual_norm,
                "relative_residual" => final_state.relative_residual,
            )
            u_out, stresses, sub_res = _build_results_from_state(
                ndof, model, id_map, X, node_R, u_iter, final_state.residual_vector, snorm_normals, final_solver_diagnostics;
                active_load_id=load_id,
                active_load_scale=Float64(attempted_scale),
            )
            recovery_relative_change = 0.0
            final_rel_residual = final_state.relative_residual
            step_converged = step_converged || (
                final_rel_residual < residual_tol &&
                (final_rel_change < tol || final_relative_incremental_work < tol)
            )
            attempt_termination_reason = step_converged ? "converged" :
                ((cutback_count < max_cutbacks && attempted_increment > 1e-12) ? "cutback_retry" : "cutback_exhausted")

            attempt_record = Dict(
                "attempt" => cutback_count + 1,
                "load_scale" => attempted_scale,
                "load_increment" => attempted_increment,
                "cutback_count" => cutback_count,
                "converged" => step_converged,
                "iterations" => step_records,
                "initial_relative_residual" => initial_rel_residual,
                "final_relative_change" => final_rel_change,
                "final_relative_residual" => final_rel_residual,
                "final_relative_incremental_work" => final_relative_incremental_work,
                "recovery_relative_change" => recovery_relative_change,
                "reused_final_state" => reused_final_state,
                "termination_reason" => attempt_termination_reason,
            )
            push!(attempt_history, attempt_record)

            if step_converged
                accepted_step += 1
                current_load_scale = attempted_scale
                u_committed .= u_iter
                final_bundle = (u_out, stresses, sub_res, copy(u_committed), final_state.fixed_dofs, final_state.Kg)
                final_state_summary = final_state
                remaining_after_accept = max(1.0 - current_load_scale, 0.0)
                tiny_increment_threshold = max(1e-12, nominal_increment * 1e-4)
                tiny_increment_step = attempted_increment <= tiny_increment_threshold
                growth_quality = _step_growth_quality(step_records)
                fast_convergence = growth_quality.eligible
                next_increment_reason = "nominal_schedule"
                candidate_next_increment = nominal_increment
                cutback_recovery_quality = nothing
                push!(load_history, Dict(
                    "step" => accepted_step,
                    "load_scale" => current_load_scale,
                    "load_increment" => attempted_increment,
                    "accepted" => true,
                    "converged" => true,
                    "cutback_count" => cutback_count,
                    "attempts" => attempt_history,
                    "iterations" => step_records,
                    "initial_relative_residual" => initial_rel_residual,
                    "final_relative_change" => final_rel_change,
                    "final_relative_residual" => final_rel_residual,
                    "final_relative_incremental_work" => final_relative_incremental_work,
                    "recovery_relative_change" => recovery_relative_change,
                    "reused_final_state" => reused_final_state,
                    "termination_reason" => "converged",
                    "fast_convergence" => fast_convergence,
                    "growth_eligible" => growth_quality.eligible,
                    "growth_all_full_step_iterations" => growth_quality.all_full_step_iterations,
                    "growth_monotone_residual_acceptance" => growth_quality.monotone_residual_acceptance,
                    "growth_used_best_available_trial" => growth_quality.used_best_available_trial,
                    "growth_max_line_search_backtracks" => growth_quality.max_line_search_backtracks,
                    "growth_max_accepted_trial_index" => growth_quality.max_accepted_trial_index,
                    "tiny_increment_step" => tiny_increment_step,
                ))
                if cutback_count > 0
                    cutback_recovery_quality = _cutback_recovery_quality(
                        initial_rel_residual,
                        final_rel_residual,
                        attempted_increment,
                        requested_increment,
                    )
                    recovered_increment = attempted_increment * cutback_recovery_quality.accepted_ratio
                    candidate_next_increment = min(nominal_increment, recovered_increment)
                    next_increment_reason =
                        candidate_next_increment > attempted_increment + 1e-12 ?
                        "cutback_recovery" :
                        "nominal_schedule"
                elseif fast_convergence && step_growth > 1.0
                    candidate_next_increment = max(nominal_increment, attempted_increment * step_growth)
                    next_increment_reason = "fast_convergence_growth"
                else
                    candidate_next_increment = nominal_increment
                    next_increment_reason = "nominal_schedule"
                end
                next_increment = min(remaining_after_accept, candidate_next_increment)
                if next_increment_reason == "fast_convergence_growth" && next_increment > nominal_increment + 1e-12
                    step_growth_applied_count += 1
                    load_history[end]["step_growth_applied"] = true
                else
                    load_history[end]["step_growth_applied"] = false
                end
                load_history[end]["next_load_increment"] = next_increment
                load_history[end]["next_increment_reason"] = next_increment_reason
                load_history[end]["next_increment_ratio"] =
                    attempted_increment > 0.0 ? next_increment / attempted_increment : 0.0
                load_history[end]["recovery_reference_increment"] = recovery_reference_increment
                if cutback_count > 0
                    load_history[end]["recovery_reference_ratio"] =
                        attempted_increment > 0.0 ? recovery_reference_increment / attempted_increment : 0.0
                    load_history[end]["cutback_recovery_contraction_ratio"] =
                        cutback_recovery_quality === nothing ? 1.0 : cutback_recovery_quality.contraction_ratio
                    load_history[end]["cutback_recovery_proposed_ratio"] =
                        cutback_recovery_quality === nothing ? 1.0 : cutback_recovery_quality.proposed_ratio
                    load_history[end]["cutback_recovery_accepted_ratio"] =
                        cutback_recovery_quality === nothing ? 1.0 : cutback_recovery_quality.accepted_ratio
                end
                step_accepted = true
            elseif cutback_count < max_cutbacks && attempted_increment > 1e-12
                recovery_reference_increment = attempted_increment
                attempted_increment *= cutback_reduction
                attempted_scale = current_load_scale + attempted_increment
                cutback_count += 1
                log_msg("[SOLVER] NL cutback: retrying with reduced load increment $(round(attempted_increment, sigdigits=4)) (target scale $(round(attempted_scale, sigdigits=4)))")
            else
                accepted_step += 1
                u_committed .= u_iter
                final_bundle = (u_out, stresses, sub_res, copy(u_committed), final_state.fixed_dofs, final_state.Kg)
                final_state_summary = final_state
                push!(load_history, Dict(
                    "step" => accepted_step,
                    "load_scale" => attempted_scale,
                    "load_increment" => attempted_increment,
                    "accepted" => false,
                    "converged" => false,
                    "cutback_count" => cutback_count,
                    "attempts" => attempt_history,
                    "iterations" => step_records,
                    "initial_relative_residual" => initial_rel_residual,
                    "final_relative_change" => final_rel_change,
                    "final_relative_residual" => final_rel_residual,
                    "final_relative_incremental_work" => final_relative_incremental_work,
                    "recovery_relative_change" => recovery_relative_change,
                    "reused_final_state" => reused_final_state,
                    "terminated_early" => true,
                    "termination_reason" => "cutback_exhausted",
                    "tiny_increment_step" => attempted_increment <= max(1e-12, nominal_increment * 1e-4),
                ))
                terminated_early = true
                step_accepted = true
            end
        end

        if terminated_early
            break
        end
    end

    isnothing(final_bundle) && error("[SOLVER] Nonlinear static solve did not produce any iterate")
    u_out, stresses, sub_res, u_analysis, fixed_dofs, Kg = final_bundle
    final_formal_diagnostics = isnothing(final_state_summary) ?
        Dict{String,Any}() :
        _state_field(final_state_summary, :formal_diagnostics, Dict{String,Any}())
    final_potential_energy = isnothing(final_state_summary) ? nothing :
        _state_field(final_state_summary, :potential_energy, nothing)
    final_internal_energy = isnothing(final_state_summary) ? nothing :
        _state_field(final_state_summary, :internal_energy, nothing)
    line_search_acceptance_counts = Dict(
        "residual_tolerance" => 0,
        "residual_reduction" => 0,
        "armijo" => 0,
        "best_available_trial" => 0,
    )
    line_search_trial_count = 0
    line_search_backtrack_count = 0
    iterations_with_residual_reduction = 0
    iterations_with_internal_force_reduction = 0
    iterations_with_potential_reduction = 0
    iterations_with_nonminimum_merit_acceptance = 0
    iterations_with_nonminimum_acceptable_acceptance = 0
    iterations_with_minimum_acceptable_distinct_from_minimum_merit = 0
    max_minimum_merit_trial_gap = 0
    max_minimum_acceptable_trial_gap = 0
    max_minimum_acceptable_vs_merit_trial_gap = 0
    tiny_increment_threshold = max(1e-12, nominal_increment * 1e-4)
    tiny_increment_step_count = 0
    tiny_increment_cutback_step_count = 0
    tiny_increment_nominal_recovery_count = 0
    tiny_increment_plateau_count = 0
    tiny_increment_plateaus = Any[]
    max_consecutive_tiny_increment_steps = 0
    max_consecutive_tiny_cutback_steps = 0
    current_tiny_increment_streak = 0
    current_tiny_cutback_streak = 0
    current_tiny_plateau_start_step = 0
    current_tiny_plateau_end_step = 0
    current_tiny_plateau_entry_load_scale = 0.0
    current_tiny_plateau_exit_load_scale = 0.0
    current_tiny_plateau_entry_increment = 0.0
    current_tiny_plateau_exit_increment = 0.0
    current_tiny_plateau_exit_next_increment = 0.0
    current_tiny_plateau_exit_next_reason = ""
    current_tiny_plateau_cutback_step_count = 0
    current_tiny_plateau_max_cutback_recovery_ratio = 0.0
    current_tiny_plateau_max_recovery_reference_ratio = 0.0
    current_tiny_plateau_iteration_count = 0
    current_tiny_plateau_line_search_trial_count = 0
    current_tiny_plateau_line_search_backtrack_count = 0
    current_tiny_plateau_residual_satisfied_retry_count = 0
    current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio = Inf
    max_next_increment_ratio = 0.0
    max_cutback_recovery_ratio = 0.0
    max_cutback_recovery_contraction_ratio = 0.0
    max_cutback_recovery_proposed_ratio = 0.0
    max_tiny_increment_recovery_ratio = 0.0
    tiny_increment_plateau_iteration_count = 0
    tiny_increment_plateau_line_search_trial_count = 0
    tiny_increment_plateau_line_search_backtrack_count = 0
    tiny_increment_plateau_residual_satisfied_retry_count = 0
    residual_satisfied_retry_count = 0
    tiny_increment_residual_satisfied_retry_count = 0
    min_residual_satisfied_retry_relative_change_ratio = Inf
    min_tiny_increment_residual_satisfied_retry_relative_change_ratio = Inf
    max_tiny_plateau_iteration_count = 0
    max_tiny_plateau_line_search_trial_count = 0
    max_tiny_plateau_line_search_backtrack_count = 0
    max_tiny_plateau_residual_satisfied_retry_count = 0
    for step in load_history
        accepted = get(step, "accepted", false)
        is_tiny_step = accepted && Float64(get(step, "load_increment", Inf)) <= tiny_increment_threshold
        is_tiny_cutback_step = is_tiny_step && Int(get(step, "cutback_count", 0)) > 0
        step_number = Int(get(step, "step", 0))
        step_load_scale = Float64(get(step, "load_scale", 0.0))
        step_load_increment = Float64(get(step, "load_increment", 0.0))
        step_next_increment = Float64(get(step, "next_load_increment", 0.0))
        step_next_increment_reason = String(get(step, "next_increment_reason", ""))
        step_next_increment_ratio =
            accepted && haskey(step, "next_increment_ratio") ?
            Float64(get(step, "next_increment_ratio", 0.0)) :
            0.0
        step_recovery_reference_ratio =
            accepted && haskey(step, "recovery_reference_ratio") ?
            Float64(get(step, "recovery_reference_ratio", 0.0)) :
            0.0
        step_iteration_count = 0
        step_line_search_trial_count = 0
        step_line_search_backtrack_count = 0
        step_residual_satisfied_retry_count = 0
        step_min_residual_satisfied_retry_relative_change_ratio = Inf
        for attempt in get(step, "attempts", Any[])
            iter_records = get(attempt, "iterations", Any[])
            step_iteration_count += length(iter_records)
            for iter_record in iter_records
                n_trials = length(get(iter_record, "line_search_trials", Any[]))
                step_line_search_trial_count += n_trials
                step_line_search_backtrack_count += max(n_trials - 1, 0)
            end
            if String(get(attempt, "termination_reason", "")) == "cutback_retry" &&
               Float64(get(attempt, "final_relative_residual", Inf)) < residual_tol
                step_residual_satisfied_retry_count += 1
                step_min_residual_satisfied_retry_relative_change_ratio = min(
                    step_min_residual_satisfied_retry_relative_change_ratio,
                    Float64(get(attempt, "final_relative_change", Inf)) / max(tol, 1e-30),
                )
            end
        end
        residual_satisfied_retry_count += step_residual_satisfied_retry_count
        if isfinite(step_min_residual_satisfied_retry_relative_change_ratio)
            min_residual_satisfied_retry_relative_change_ratio = min(
                min_residual_satisfied_retry_relative_change_ratio,
                step_min_residual_satisfied_retry_relative_change_ratio,
            )
        end

        if is_tiny_step
            current_tiny_increment_streak += 1
            if current_tiny_increment_streak == 1
                tiny_increment_plateau_count += 1
                current_tiny_plateau_start_step = step_number
                current_tiny_plateau_entry_load_scale = max(step_load_scale - step_load_increment, 0.0)
                current_tiny_plateau_entry_increment = step_load_increment
                current_tiny_plateau_cutback_step_count = 0
                current_tiny_plateau_max_cutback_recovery_ratio = 0.0
                current_tiny_plateau_max_recovery_reference_ratio = 0.0
                current_tiny_plateau_iteration_count = 0
                current_tiny_plateau_line_search_trial_count = 0
                current_tiny_plateau_line_search_backtrack_count = 0
                current_tiny_plateau_residual_satisfied_retry_count = 0
                current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio = Inf
            end
            current_tiny_plateau_end_step = step_number
            current_tiny_plateau_exit_load_scale = step_load_scale
            current_tiny_plateau_exit_increment = step_load_increment
            current_tiny_plateau_exit_next_increment = step_next_increment
            current_tiny_plateau_exit_next_reason = step_next_increment_reason
            is_tiny_cutback_step && (current_tiny_plateau_cutback_step_count += 1)
            current_tiny_plateau_iteration_count += step_iteration_count
            current_tiny_plateau_line_search_trial_count += step_line_search_trial_count
            current_tiny_plateau_line_search_backtrack_count += step_line_search_backtrack_count
            current_tiny_plateau_residual_satisfied_retry_count += step_residual_satisfied_retry_count
            if isfinite(step_min_residual_satisfied_retry_relative_change_ratio)
                current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio = min(
                    current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio,
                    step_min_residual_satisfied_retry_relative_change_ratio,
                )
            end
            if step_next_increment_reason == "cutback_recovery"
                current_tiny_plateau_max_cutback_recovery_ratio = max(
                    current_tiny_plateau_max_cutback_recovery_ratio,
                    step_next_increment_ratio,
                )
            end
            current_tiny_plateau_max_recovery_reference_ratio = max(
                current_tiny_plateau_max_recovery_reference_ratio,
                step_recovery_reference_ratio,
            )
            max_consecutive_tiny_increment_steps = max(max_consecutive_tiny_increment_steps, current_tiny_increment_streak)
        else
            if current_tiny_increment_streak > 0
                push!(tiny_increment_plateaus, Dict(
                    "start_step" => current_tiny_plateau_start_step,
                    "end_step" => current_tiny_plateau_end_step,
                    "step_count" => current_tiny_increment_streak,
                    "cutback_step_count" => current_tiny_plateau_cutback_step_count,
                    "nominal_recovery_exit" => current_tiny_plateau_exit_next_reason == "nominal_schedule",
                    "entry_load_scale" => current_tiny_plateau_entry_load_scale,
                    "exit_load_scale" => current_tiny_plateau_exit_load_scale,
                    "entry_load_increment" => current_tiny_plateau_entry_increment,
                    "exit_load_increment" => current_tiny_plateau_exit_increment,
                    "exit_next_increment" => current_tiny_plateau_exit_next_increment,
                    "exit_next_increment_reason" => current_tiny_plateau_exit_next_reason,
                    "max_cutback_recovery_ratio" => current_tiny_plateau_max_cutback_recovery_ratio,
                    "max_recovery_reference_ratio" => current_tiny_plateau_max_recovery_reference_ratio,
                    "iteration_count" => current_tiny_plateau_iteration_count,
                    "line_search_trial_count" => current_tiny_plateau_line_search_trial_count,
                    "line_search_backtrack_count" => current_tiny_plateau_line_search_backtrack_count,
                    "residual_satisfied_retry_count" => current_tiny_plateau_residual_satisfied_retry_count,
                    "min_residual_satisfied_retry_relative_change_ratio" =>
                        isfinite(current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio) ?
                        current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio : 0.0,
                    "load_scale_span" => max(current_tiny_plateau_exit_load_scale - current_tiny_plateau_entry_load_scale, 0.0),
                ))
                tiny_increment_plateau_iteration_count += current_tiny_plateau_iteration_count
                tiny_increment_plateau_line_search_trial_count += current_tiny_plateau_line_search_trial_count
                tiny_increment_plateau_line_search_backtrack_count += current_tiny_plateau_line_search_backtrack_count
                tiny_increment_plateau_residual_satisfied_retry_count += current_tiny_plateau_residual_satisfied_retry_count
                max_tiny_plateau_iteration_count = max(max_tiny_plateau_iteration_count, current_tiny_plateau_iteration_count)
                max_tiny_plateau_line_search_trial_count = max(max_tiny_plateau_line_search_trial_count, current_tiny_plateau_line_search_trial_count)
                max_tiny_plateau_line_search_backtrack_count = max(max_tiny_plateau_line_search_backtrack_count, current_tiny_plateau_line_search_backtrack_count)
                max_tiny_plateau_residual_satisfied_retry_count = max(max_tiny_plateau_residual_satisfied_retry_count, current_tiny_plateau_residual_satisfied_retry_count)
            end
            current_tiny_increment_streak = 0
            current_tiny_plateau_start_step = 0
            current_tiny_plateau_end_step = 0
            current_tiny_plateau_entry_load_scale = 0.0
            current_tiny_plateau_exit_load_scale = 0.0
            current_tiny_plateau_entry_increment = 0.0
            current_tiny_plateau_exit_increment = 0.0
            current_tiny_plateau_exit_next_increment = 0.0
            current_tiny_plateau_exit_next_reason = ""
            current_tiny_plateau_cutback_step_count = 0
            current_tiny_plateau_max_cutback_recovery_ratio = 0.0
            current_tiny_plateau_max_recovery_reference_ratio = 0.0
            current_tiny_plateau_iteration_count = 0
            current_tiny_plateau_line_search_trial_count = 0
            current_tiny_plateau_line_search_backtrack_count = 0
            current_tiny_plateau_residual_satisfied_retry_count = 0
            current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio = Inf
        end

        if is_tiny_cutback_step
            current_tiny_cutback_streak += 1
        else
            current_tiny_cutback_streak = 0
        end
        max_consecutive_tiny_cutback_steps = max(max_consecutive_tiny_cutback_steps, current_tiny_cutback_streak)

        if accepted && haskey(step, "next_increment_ratio")
            max_next_increment_ratio = max(max_next_increment_ratio, Float64(get(step, "next_increment_ratio", 0.0)))
        end
        if accepted && get(step, "next_increment_reason", "") == "cutback_recovery" && haskey(step, "next_increment_ratio")
            ratio = Float64(get(step, "next_increment_ratio", 0.0))
            max_cutback_recovery_ratio = max(max_cutback_recovery_ratio, ratio)
            if haskey(step, "cutback_recovery_contraction_ratio")
                max_cutback_recovery_contraction_ratio = max(
                    max_cutback_recovery_contraction_ratio,
                    Float64(get(step, "cutback_recovery_contraction_ratio", 0.0)),
                )
            end
            if haskey(step, "cutback_recovery_proposed_ratio")
                max_cutback_recovery_proposed_ratio = max(
                    max_cutback_recovery_proposed_ratio,
                    Float64(get(step, "cutback_recovery_proposed_ratio", 0.0)),
                )
            end
            is_tiny_step && (max_tiny_increment_recovery_ratio = max(max_tiny_increment_recovery_ratio, ratio))
        end

        if get(step, "accepted", false) &&
           Float64(get(step, "load_increment", Inf)) <= tiny_increment_threshold
            tiny_increment_step_count += 1
            Int(get(step, "cutback_count", 0)) > 0 && (tiny_increment_cutback_step_count += 1)
            step_next_increment_reason == "nominal_schedule" &&
                (tiny_increment_nominal_recovery_count += 1)
            tiny_increment_residual_satisfied_retry_count += step_residual_satisfied_retry_count
            if isfinite(step_min_residual_satisfied_retry_relative_change_ratio)
                min_tiny_increment_residual_satisfied_retry_relative_change_ratio = min(
                    min_tiny_increment_residual_satisfied_retry_relative_change_ratio,
                    step_min_residual_satisfied_retry_relative_change_ratio,
                )
            end
        end
        for attempt in get(step, "attempts", Any[])
            for iter_record in get(attempt, "iterations", Any[])
                reason = String(get(iter_record, "accepted_by", ""))
                if haskey(line_search_acceptance_counts, reason)
                    line_search_acceptance_counts[reason] += 1
                end
                get(iter_record, "residual_reduced", false) === true && (iterations_with_residual_reduction += 1)
                get(iter_record, "internal_force_reduced", false) === true && (iterations_with_internal_force_reduction += 1)
                get(iter_record, "potential_reduced", false) === true && (iterations_with_potential_reduction += 1)
                accepted_trial_idx = Int(get(iter_record, "accepted_trial_index", 0))
                minimum_merit_trial_idx = Int(get(iter_record, "minimum_merit_trial_index", accepted_trial_idx))
                minimum_acceptable_trial_idx = Int(get(iter_record, "minimum_acceptable_trial_index", accepted_trial_idx))
                accepted_trial_idx != minimum_merit_trial_idx &&
                    (iterations_with_nonminimum_merit_acceptance += 1)
                accepted_trial_idx != minimum_acceptable_trial_idx &&
                    (iterations_with_nonminimum_acceptable_acceptance += 1)
                minimum_acceptable_trial_idx != minimum_merit_trial_idx &&
                    (iterations_with_minimum_acceptable_distinct_from_minimum_merit += 1)
                max_minimum_merit_trial_gap = max(
                    max_minimum_merit_trial_gap,
                    abs(minimum_merit_trial_idx - accepted_trial_idx),
                )
                max_minimum_acceptable_trial_gap = max(
                    max_minimum_acceptable_trial_gap,
                    abs(minimum_acceptable_trial_idx - accepted_trial_idx),
                )
                max_minimum_acceptable_vs_merit_trial_gap = max(
                    max_minimum_acceptable_vs_merit_trial_gap,
                    abs(minimum_acceptable_trial_idx - minimum_merit_trial_idx),
                )
                n_trials = length(get(iter_record, "line_search_trials", Any[]))
                line_search_trial_count += n_trials
                line_search_backtrack_count += max(n_trials - 1, 0)
            end
        end
    end
    if current_tiny_increment_streak > 0
        push!(tiny_increment_plateaus, Dict(
            "start_step" => current_tiny_plateau_start_step,
            "end_step" => current_tiny_plateau_end_step,
            "step_count" => current_tiny_increment_streak,
            "cutback_step_count" => current_tiny_plateau_cutback_step_count,
            "nominal_recovery_exit" => current_tiny_plateau_exit_next_reason == "nominal_schedule",
            "entry_load_scale" => current_tiny_plateau_entry_load_scale,
            "exit_load_scale" => current_tiny_plateau_exit_load_scale,
            "entry_load_increment" => current_tiny_plateau_entry_increment,
            "exit_load_increment" => current_tiny_plateau_exit_increment,
            "exit_next_increment" => current_tiny_plateau_exit_next_increment,
            "exit_next_increment_reason" => current_tiny_plateau_exit_next_reason,
            "max_cutback_recovery_ratio" => current_tiny_plateau_max_cutback_recovery_ratio,
            "max_recovery_reference_ratio" => current_tiny_plateau_max_recovery_reference_ratio,
            "iteration_count" => current_tiny_plateau_iteration_count,
            "line_search_trial_count" => current_tiny_plateau_line_search_trial_count,
            "line_search_backtrack_count" => current_tiny_plateau_line_search_backtrack_count,
            "residual_satisfied_retry_count" => current_tiny_plateau_residual_satisfied_retry_count,
            "min_residual_satisfied_retry_relative_change_ratio" =>
                isfinite(current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio) ?
                current_tiny_plateau_min_residual_satisfied_retry_relative_change_ratio : 0.0,
            "load_scale_span" => max(current_tiny_plateau_exit_load_scale - current_tiny_plateau_entry_load_scale, 0.0),
        ))
        tiny_increment_plateau_iteration_count += current_tiny_plateau_iteration_count
        tiny_increment_plateau_line_search_trial_count += current_tiny_plateau_line_search_trial_count
        tiny_increment_plateau_line_search_backtrack_count += current_tiny_plateau_line_search_backtrack_count
        tiny_increment_plateau_residual_satisfied_retry_count += current_tiny_plateau_residual_satisfied_retry_count
        max_tiny_plateau_iteration_count = max(max_tiny_plateau_iteration_count, current_tiny_plateau_iteration_count)
        max_tiny_plateau_line_search_trial_count = max(max_tiny_plateau_line_search_trial_count, current_tiny_plateau_line_search_trial_count)
        max_tiny_plateau_line_search_backtrack_count = max(max_tiny_plateau_line_search_backtrack_count, current_tiny_plateau_line_search_backtrack_count)
        max_tiny_plateau_residual_satisfied_retry_count = max(max_tiny_plateau_residual_satisfied_retry_count, current_tiny_plateau_residual_satisfied_retry_count)
    end
    converged = !terminated_early && !isempty(load_history) && current_load_scale >= 1.0 - 1e-12 &&
        all(get(step, "converged", false) for step in load_history)
    sub_res["nonlinear_diagnostics"] = Dict(
        "scheme" => nonlinear_method === :formal_shell_von_karman ?
            "formal_shell_von_karman_line_search" :
            "experimental_geometric_residual_line_search",
        "nonlinear_method" => String(nonlinear_method),
        "load_steps" => load_history,
        "requested_load_step_count" => load_steps,
        "load_step_count" => length(load_history),
        "accepted_load_step_count" => count(step -> get(step, "accepted", false), load_history),
        "base_load_increment" => nominal_increment,
        "max_iterations_per_step" => max_iter,
        "tolerance" => tol,
        "residual_tolerance" => residual_tol,
        "residual_model" => nonlinear_method === :formal_shell_von_karman ? "formal_internal_force" : String(residual_model),
        "correction_tangent_model" => nonlinear_method === :formal_shell_von_karman ? "formal_consistent_tangent" : "linear_plus_geometric",
        "relaxation" => relaxation,
        "line_search_max_backtracks" => line_search_max_backtracks,
        "line_search_reduction" => line_search_reduction,
        "max_cutbacks" => max_cutbacks,
        "cutback_reduction" => cutback_reduction,
        "step_growth" => step_growth,
        "formal_shell_supported" => formal_supported,
        "formal_support_class" => formal_support.support_class,
        "formal_support_unsupported_reason" =>
            isempty(formal_support.unsupported_reason) ? missing : formal_support.unsupported_reason,
        "formal_support_total_shell_count" => formal_support.total_shell_count,
        "formal_support_quad4_count" => formal_support.quad4_count,
        "formal_support_tria3_count" => formal_support.tria3_count,
        "formal_support_planar_quad_count" => formal_support.planar_quad_count,
        "formal_support_warped_quad_count" => formal_support.warped_quad_count,
        "final_formal_diagnostics" => final_formal_diagnostics,
        "final_potential_energy" => isnothing(final_potential_energy) ? missing : final_potential_energy,
        "final_internal_energy" => isnothing(final_internal_energy) ? missing : final_internal_energy,
        "state_evaluation_count" => state_evaluation_count,
        "correction_partition_reuse_count" => correction_partition_reuse_count,
        "accepted_state_reuse_count" => accepted_state_reuse_count,
        "step_growth_applied_count" => step_growth_applied_count,
        "line_search_acceptance_counts" => line_search_acceptance_counts,
        "line_search_trial_count" => line_search_trial_count,
        "line_search_backtrack_count" => line_search_backtrack_count,
        "iterations_with_residual_reduction" => iterations_with_residual_reduction,
        "iterations_with_internal_force_reduction" => iterations_with_internal_force_reduction,
        "iterations_with_potential_reduction" => iterations_with_potential_reduction,
        "iterations_with_nonminimum_merit_acceptance" => iterations_with_nonminimum_merit_acceptance,
        "iterations_with_nonminimum_acceptable_acceptance" => iterations_with_nonminimum_acceptable_acceptance,
        "iterations_with_minimum_acceptable_distinct_from_minimum_merit" =>
            iterations_with_minimum_acceptable_distinct_from_minimum_merit,
        "max_minimum_merit_trial_gap" => max_minimum_merit_trial_gap,
        "max_minimum_acceptable_trial_gap" => max_minimum_acceptable_trial_gap,
        "max_minimum_acceptable_vs_merit_trial_gap" => max_minimum_acceptable_vs_merit_trial_gap,
        "tiny_increment_threshold" => tiny_increment_threshold,
        "tiny_increment_step_count" => tiny_increment_step_count,
        "tiny_increment_cutback_step_count" => tiny_increment_cutback_step_count,
        "tiny_increment_nominal_recovery_count" => tiny_increment_nominal_recovery_count,
        "tiny_increment_plateau_count" => tiny_increment_plateau_count,
        "tiny_increment_plateaus" => tiny_increment_plateaus,
        "tiny_increment_plateau_iteration_count" => tiny_increment_plateau_iteration_count,
        "tiny_increment_plateau_line_search_trial_count" => tiny_increment_plateau_line_search_trial_count,
        "tiny_increment_plateau_line_search_backtrack_count" => tiny_increment_plateau_line_search_backtrack_count,
        "tiny_increment_plateau_residual_satisfied_retry_count" => tiny_increment_plateau_residual_satisfied_retry_count,
        "max_consecutive_tiny_increment_steps" => max_consecutive_tiny_increment_steps,
        "max_consecutive_tiny_cutback_steps" => max_consecutive_tiny_cutback_steps,
        "max_tiny_plateau_iteration_count" => max_tiny_plateau_iteration_count,
        "max_tiny_plateau_line_search_trial_count" => max_tiny_plateau_line_search_trial_count,
        "max_tiny_plateau_line_search_backtrack_count" => max_tiny_plateau_line_search_backtrack_count,
        "max_tiny_plateau_residual_satisfied_retry_count" => max_tiny_plateau_residual_satisfied_retry_count,
        "max_next_increment_ratio" => max_next_increment_ratio,
        "max_cutback_recovery_ratio" => max_cutback_recovery_ratio,
        "max_cutback_recovery_contraction_ratio" => max_cutback_recovery_contraction_ratio,
        "max_cutback_recovery_proposed_ratio" => max_cutback_recovery_proposed_ratio,
        "max_tiny_increment_recovery_ratio" => max_tiny_increment_recovery_ratio,
        "residual_satisfied_retry_count" => residual_satisfied_retry_count,
        "tiny_increment_residual_satisfied_retry_count" => tiny_increment_residual_satisfied_retry_count,
        "min_residual_satisfied_retry_relative_change_ratio" =>
            isfinite(min_residual_satisfied_retry_relative_change_ratio) ?
            min_residual_satisfied_retry_relative_change_ratio : 0.0,
        "min_tiny_increment_residual_satisfied_retry_relative_change_ratio" =>
            isfinite(min_tiny_increment_residual_satisfied_retry_relative_change_ratio) ?
            min_tiny_increment_residual_satisfied_retry_relative_change_ratio : 0.0,
        "converged" => converged,
        "termination_reason" => converged ? "full_load_converged" :
            (terminated_early ? "cutback_exhausted" : "stopped_before_full_load"),
        "final_load_scale" => current_load_scale,
        "final_relative_change" => isempty(load_history) ? Inf : get(last(load_history), "final_relative_change", Inf),
        "final_relative_residual" => isempty(load_history) ? Inf : get(last(load_history), "final_relative_residual", Inf),
        "final_relative_incremental_work" =>
            isempty(load_history) ? Inf : get(last(load_history), "final_relative_incremental_work", Inf),
        "final_kg_nnz" => nnz(Kg),
        "final_kg_norm" => norm(Kg.nzval),
    )
    return u_out, stresses, sub_res, u_analysis, fixed_dofs, Kg
end

# =============================================================================
# SOL105 BUCKLING EIGENVALUE SOLVER
# Solves: [K + lambda * Kg] * phi = 0  →  K*phi = lambda*(-Kg)*phi
# =============================================================================
function _buckling_krylovdim(nev_request::Int, n_free::Int)
    factor = max(solver_env_float("JFEM_SOL105_KRYLOV_DIM_FACTOR", 2.0), 1.0)
    offset = max(solver_env_int("JFEM_SOL105_KRYLOV_DIM_OFFSET", 20), 0)
    min_dim = max(solver_env_int("JFEM_SOL105_KRYLOV_DIM_MIN", 40), 1)
    kd = max(ceil(Int, factor * nev_request) + offset, min_dim, nev_request + 2)
    return min(kd, n_free)
end

function _buckling_krylovtol()
    return max(solver_env_float("JFEM_SOL105_KRYLOV_TOL", 1e-12), 0.0)
end

function _buckling_krylovmaxiter()
    return max(solver_env_int("JFEM_SOL105_KRYLOV_MAXITER", 1000), 1)
end

# Largest free-DOF count for which the dense symmetric-definite eigensolver is
# used as the primary buckling strategy.
#
# Historically this was 4000: every system at or below 4000 DOFs was solved
# densely (full spectrum). That made the dense path the de-facto default for the
# entire validation corpus and let it dominate strategy selection. We are not
# interested in optimizing tiny cases, so the dense path is now only a fast exact
# oracle for *small* systems; everything larger goes straight to the iterative
# shift-invert Lanczos/Krylov path with an active Sturm completeness check.
#
# Default 200 (env-overridable via JFEM_SOL105_DENSE_MAX_DOF). 200 keeps the
# dense path for genuinely small benchmark/unit cases (where it is both faster
# and an exact reference) while routing real structures to the iterative solver.
# Set to 0 to disable the dense path entirely (force iterative for all sizes).
function _buckling_dense_max_dof()
    return max(solver_env_int("JFEM_SOL105_DENSE_MAX_DOF", 200), 0)
end

# Sturm / inertia count for the buckling pencil (K + lambda*Kg) phi = 0 with K SPD.
# Returns the negative inertia of M(sigma) = K + sigma*Kg, i.e. the number of
# NEGATIVE eigenvalues of M(sigma).
#
# IMPORTANT — use as a DIFFERENCE, not an absolute count. When Kg is indefinite
# (load-reversal modes give negative lambda), the absolute negative-inertia has a
# constant offset, but the DIFFERENCE
#       _buckling_sturm_count(K, Kg, b) - _buckling_sturm_count(K, Kg, a)
# is EXACTLY the number of buckling eigenvalues lambda in the half-open interval
# (a, b]. This was verified numerically against a known indefinite spectrum. So
# range counts use sturm(v2)-sturm(v1), and the positive-mode count uses
# sturm(b)-sturm(0+). Never compare a single sturm(sigma) to a mode count.
#
# Returns the count, or `nothing` if the inertia could not be computed (so callers
# treat it as "unknown" and fall back to the non-Sturm behaviour). Pure-Julia:
# uses a dense symmetric eigenvalue sign count for small systems (exact), and a
# sparse CHOLMOD LDLᵀ pivot-sign inertia for larger ones (Sylvester's law of
# inertia: the count of negative pivots equals the number of negative
# eigenvalues, invariant under the fill-reducing permutation CHOLMOD applies).
#
# NOTE on the CHOLMOD accessor: the inertia is `count(<(0), diag(F))` on the
# Factor itself. `diag(F.D)` does NOT work — `F.D` is a CHOLMOD `FactorComponent`
# that is not indexable (it throws CanonicalIndexError), and an earlier version
# of this code hit that, fell through to a dense `lu(Matrix(M))` fallback, and
# densified the 26k-60k+ sparse pencil into tens of GB — which is what made the
# Sturm check appear to "hang" on large models. There is no dense fallback now:
# the sparse LDLᵀ is the right algorithm and is fast (≈1.5 s/shift at 60k DOF).
function _buckling_sturm_count(K_ff, Kg_ff, sigma::Float64;
                               reuse::Union{Nothing,Base.RefValue{Any}}=nothing,
                               factor_out::Union{Nothing,Base.RefValue{Any}}=nothing)
    n = size(K_ff, 1)
    n == 0 && return 0
    try
        M = K_ff + sigma * Kg_ff
        # Enforce exact symmetry only when the sum is not already exactly
        # symmetric: for symmetric inputs 0.5*(M+M') is value-identical
        # (0.5*(x+x) == x in IEEE) and only costs two nnz-sized temporaries
        # (~170 MB per count at CRM-class sizes).
        issymmetric(M) || (M = 0.5 * (M + M'))
        if n <= 600
            # Exact: count negative eigenvalues of the (small) dense symmetric M.
            evs = eigvals(Symmetric(Matrix(M)))
            return count(<(0.0), evs)
        else
            # Sparse symmetric-indefinite inertia via CHOLMOD LDLᵀ pivot signs.
            # The sparsity pattern of K + sigma*Kg is sigma-independent, so a
            # caller-held Factor (`reuse`) skips the symbolic analysis on every
            # count after the first. The inertia is permutation-invariant
            # (Sylvester's law), so factor reuse cannot change the integer
            # result even if a fresh analysis would pick another ordering.
            #
            # `factor_out` (ShiftFactor fusion): request a FRESH factorization
            # whose Factor object is handed back to the caller for reuse as a
            # shift-invert solve operator — never routed through `reuse`, so a
            # later in-place refactorization cannot corrupt it.
            local F
            if factor_out !== nothing
                F = ldlt(M)
                factor_out[] = F
            elseif reuse !== nothing && reuse[] !== nothing
                # Julia's ldlt/ldlt! pin CHOLMOD to SIMPLICIAL mode, whose
                # numeric refactorization recomputes column patterns from the
                # ACTUAL matrix — so refactoring into a reuse factor is
                # pattern-safe by construction (verified empirically both
                # pattern directions). This try/catch covers the cases that
                # DO throw — dimension mismatch (CHOLMODException) and
                # singular pencils (ZeroPivotException) — by falling back to
                # a fresh analysis instead of silently disabling the
                # certificate for the subcase.
                F = try
                    ldlt!(reuse[], M)
                catch
                    ldlt(M)
                end
                reuse[] = F
            else
                F = ldlt(M)
                reuse !== nothing && (reuse[] = F)
            end
            return count(<(0.0), diag(F))
        end
    catch
        reuse !== nothing && (reuse[] = nothing)
        return nothing
    end
end

function solve_buckling(K, Kg, ndof, model, id_map, X, spc_id, node_R, num_modes;
                        rbe3_map=Dict{Int,Vector{Tuple{Int,Float64}}}(),
                        max_elem_stiff=0.0, orig_diag=Float64[],
                        eigrl_v1::Float64=0.0, eigrl_v2::Float64=0.0,
                        eigen_cache=nothing,
                        buckling_subcase=nothing,
                        static_subcase=nothing,
                        sol105_options=nothing,
                        return_diagnostics::Bool=false)

    opts = sol105_options === nothing ? from_env() : sol105_options
    t_buckling_total = time_ns()
    buckling_timings = Dict{String,Any}()
    log_msg("[BUCKLING] Computing free DOFs...")
    t_prepare_context = time_ns()
    eigen_ctx, eigen_cache_hit = prepare_eigen_solve_context(
        K, ndof, model, id_map, spc_id, rbe3_map; eigen_cache=eigen_cache)
    buckling_timings["prepare_context"] = (time_ns() - t_prepare_context) * 1e-9
    free_dofs = eigen_ctx.free_dofs
    fixed_dofs = eigen_ctx.fixed_dofs
    bc_diagnostics = eigen_ctx.bc_diagnostics
    n_free = length(free_dofs)
    log_msg("[BUCKLING] Free DOFs: $n_free, Fixed DOFs: $(length(fixed_dofs))")
    if eigen_cache_hit
        log_msg("[BUCKLING] Reusing eigen BC partition cache: Fixed DOFs=$(length(fixed_dofs)), Free DOFs=$n_free")
    end
    diagnostics = Dict{String,Any}(
        "bc_partition" => deepcopy(bc_diagnostics),
        "requested_modes" => num_modes,
        "requested_modes_internal" => 0,
        "free_dofs" => n_free,
        "fixed_dofs" => length(fixed_dofs),
        "eigrl_range" => Dict("v1" => eigrl_v1, "v2" => eigrl_v2),
        "eigen_cache" => Dict{String,Any}(
            "enabled" => eigen_cache !== nothing,
            "cache_hit" => eigen_cache_hit,
            "factorization_cache_hit" => false,
        ),
        "solver_backend" => "unsolved",
        "solver_attempts" => Any[],
        "returned_modes" => 0,
    )
    if solver_env_bool("JFEM_SOL105_STORE_EIGEN_PARTITION", false)
        diagnostics["free_dof_indices"] = copy(free_dofs)
        diagnostics["fixed_dof_indices"] = sort!(collect(fixed_dofs))
    end

    t_slice = time_ns()
    K_ff  = eigen_ctx.K_ff
    Kg_ff = Kg[free_dofs, free_dofs]
    buckling_timings["slice_free_matrices"] = (time_ns() - t_slice) * 1e-9
    # JFEM_DUMP_ELEMENT_MATRICES: dump the FULL (pre-BC) global K and Kg, plus the
    # DOF->(grid,component) map. For a single-element model this is exactly the
    # 24x24 element K and Kg, for entry-by-entry comparison against Nastran's
    # MATPRN KGG/KDJJ. Debug hook only; no-op when unset.
    let em_prefix = strip(get(ENV, "JFEM_DUMP_ELEMENT_MATRICES", ""))
        if !isempty(em_prefix)
            try
                em_sparse = solver_env_bool("JFEM_DUMP_ELEMENT_MATRICES_SPARSE", false)
                dump_dense = (path, M) -> begin
                    Md = Matrix(M)
                    open(path, "w") do io
                        for r in 1:size(Md, 1)
                            for c in 1:size(Md, 2)
                                c > 1 && print(io, " ")
                                print(io, repr(Md[r, c]))
                            end
                            println(io)
                        end
                    end
                end
                # Sparse triplet dump (header "<nrows> <ncols> <nnz>" then "i j v")
                # for large assembled g-set matrices (box has ~45k DOF).
                dump_sparse = (path, M) -> begin
                    S = SparseArrays.sparse(M)
                    I, J, V = SparseArrays.findnz(S)
                    open(path, "w") do io
                        println(io, size(S, 1), " ", size(S, 2), " ", length(V))
                        for k in 1:length(V)
                            println(io, I[k], " ", J[k], " ", repr(V[k]))
                        end
                    end
                end
                dump_em = em_sparse ? dump_sparse : dump_dense
                dump_em(em_prefix * "_K.txt", K)
                dump_em(em_prefix * "_Kg.txt", Kg)
                open(em_prefix * "_dofmap.txt", "w") do io
                    for (gid, idx) in sort(collect(id_map); by = x -> x[2])
                        for comp in 1:6
                            println(io, (idx - 1) * 6 + comp, " ", gid, " ", comp)
                        end
                    end
                end
                log_msg("[BUCKLING] Dumped element matrices to $(em_prefix)_K/_Kg/_dofmap.txt (ndof=$(size(K,1)))")
            catch err
                log_msg("[BUCKLING] WARNING: JFEM_DUMP_ELEMENT_MATRICES failed: $err")
            end
        end
    end

    t_symmetry = time_ns()
    Kg_norm_inf = max(norm(Kg_ff, Inf), 1e-30)
    # K_ff is symmetrized once when the eigen solve context is prepared/cached.
    # Only Kg changes per buckling subcase, so keep the per-subcase symmetry work
    # focused there.
    K_asym_rel = 0.0
    Kg_asym_rel = norm(Kg_ff - Kg_ff', Inf) / Kg_norm_inf
    diagnostics["matrix_asymmetry"] = Dict(
        "K_inf_rel" => K_asym_rel,
        "Kg_inf_rel" => Kg_asym_rel,
    )
    asym_warn_rel = solver_env_float("JFEM_MATRIX_ASYMMETRY_WARN_REL", 1e-10)
    if K_asym_rel > asym_warn_rel || Kg_asym_rel > asym_warn_rel
        log_msg("[BUCKLING] Matrix asymmetry before symmetrization: K=$(K_asym_rel), Kg=$(Kg_asym_rel)")
    end

    # Symmetrize after recording diagnostics; the generalized buckling solver
    # expects the conservative symmetric Hessian pair.
    Kg_ff = 0.5 * (Kg_ff + Kg_ff')
    buckling_timings["symmetry_checks"] = (time_ns() - t_symmetry) * 1e-9
    # JFEM_DUMP_PENCIL: when set to a writable path prefix, dump the free-reduced
    # K_ff and Kg_ff (dense) so the buckling pencil can be solved offline for
    # operator research on small models. Writes <prefix>_Kff.txt / _Kgff.txt as
    # whitespace matrices. Debug hook only; no effect when unset.
    let dump_prefix = strip(get(ENV, "JFEM_DUMP_PENCIL", ""))
        if !isempty(dump_prefix)
            try
                # Per-subcase filenames: successive buckling subcases must never
                # overwrite each other's dump (the _dofs.txt file is written last
                # and marks that subcase's dump complete).
                dump_prefix = buckling_subcase === nothing ? dump_prefix :
                    dump_prefix * "_sc$(buckling_subcase)"
                sparse_dump = solver_env_bool("JFEM_DUMP_PENCIL_SPARSE", false)
                dump_dense_matrix = (path, M) -> begin
                    Kd = Matrix(M)
                    open(path, "w") do io
                        for r in 1:size(Kd, 1)
                            for c in 1:size(Kd, 2)
                                c > 1 && print(io, " ")
                                print(io, repr(Kd[r, c]))
                            end
                            println(io)
                        end
                    end
                end
                # Sparse triplet dump (I J V) for large systems: header line
                # "<nrows> <ncols> <nnz>" then one "i j v" per nonzero.
                dump_sparse_matrix = (path, M) -> begin
                    S = SparseArrays.sparse(M)
                    I, J, V = SparseArrays.findnz(S)
                    open(path, "w") do io
                        println(io, size(S, 1), " ", size(S, 2), " ", length(V))
                        for k in 1:length(V)
                            println(io, I[k], " ", J[k], " ", repr(V[k]))
                        end
                    end
                end
                dump_pencil_matrix = sparse_dump ? dump_sparse_matrix : dump_dense_matrix
                dump_pencil_matrix(dump_prefix * "_Kff.txt", K_ff)
                dump_pencil_matrix(dump_prefix * "_Kgff.txt", Kg_ff)
                open(dump_prefix * "_dofs.txt", "w") do io
                    for gd in free_dofs
                        node0 = div(gd - 1, 6)
                        comp = ((gd - 1) % 6) + 1
                        println(io, gd, " ", node0 + 1, " ", comp)
                    end
                end
                log_msg("[BUCKLING] Dumped pencil to $(dump_prefix)_Kff.txt / _Kgff.txt / _dofs.txt (n_free=$n_free)")
            catch err
                log_msg("[BUCKLING] WARNING: JFEM_DUMP_PENCIL failed: $err")
            end
        end
    end
    start_vector_ordinal = Ref(0)
    next_start_vector() = begin
        start_vector_ordinal[] += 1
        _deterministic_buckling_start_vector(n_free, start_vector_ordinal[])
    end

    # When EIGRL range is specified, request extra modes to allow filtering.
    # For dense systems (≤4000 DOFs), all eigenvalues are computed anyway — return 3× modes
    # so the comparison can use subset matching to skip spurious bar/shell modes.
    has_range = (eigrl_v1 != 0.0 || eigrl_v2 != 0.0) && eigrl_v2 > eigrl_v1
    return_all_range = has_range && solver_env_bool("JFEM_SOL105_RETURN_ALL_IN_RANGE", false)
    nd_limited_range_output = has_range && !return_all_range
    dense_max_dof = _buckling_dense_max_dof()
    will_use_dense = n_free <= dense_max_dof

    # Positivity floor and effective range bounds, shared by the adaptive-nev
    # ladder test, the range filter, and the certificate machinery below.
    # V1 is clamped to >+tol so a negative V1 (commonly -1e-4 in MSC decks)
    # does not re-admit non-positive roots after the positivity filter.
    positive_tol = 1e-10
    v1_eff = has_range ? max(eigrl_v1, positive_tol) : 0.0
    range_abs_tol = max(solver_env_float("JFEM_SOL105_RANGE_ABS_TOL", 0.0), 0.0)
    range_rel_tol = max(solver_env_float("JFEM_SOL105_RANGE_REL_TOL", 0.0), 0.0)
    v2_eff = has_range ? eigrl_v2 + max(range_abs_tol, abs(eigrl_v2) * range_rel_tol) : 0.0
    range_mode_factor_default = 8.0
    range_mode_factor = max(solver_env_float("JFEM_SOL105_RANGE_MODE_FACTOR", range_mode_factor_default), 1.0)
    num_modes_request = has_range ? ceil(Int, num_modes * range_mode_factor) :
                        (will_use_dense ? num_modes * 3 : num_modes)

    # Clamp num_modes to system size
    max_modes = max(n_free - 2, 1)
    if num_modes_request > max_modes
        log_msg("[BUCKLING] Reducing num_modes_request from $num_modes_request to $max_modes (system size limit)")
        num_modes_request = max_modes
    end
    diagnostics["requested_modes_internal"] = num_modes_request
    diagnostics["range_mode_factor"] = has_range ? range_mode_factor : nothing
    diagnostics["range_nd_limited_output"] = nd_limited_range_output

    log_msg("[BUCKLING] Solving eigenvalue problem ($num_modes modes, $n_free DOFs)...")

    local eigenvalues, eigenvectors
    solved = false
    t_eigen_search = time_ns()

    # ShiftFactor fusion (perf program Phase 3.3, env-flagged): one CHOLMOD
    # LDLᵀ of M(σ) = K + σ·Kg per shift serves BOTH as the shift-invert
    # solve operator AND the Sturm inertia certificate at σ. Certificate
    # factors kept here (bounded, most-recent-two) are consumed by shifted
    # searches at the same σ (the completeness pass-1 shift IS the
    # certificate bound b, so the recovery solve then costs no
    # factorization at all).
    shift_factor_fusion = solver_env_bool("JFEM_SOL105_SHIFT_FACTOR_FUSION", false)
    sturm_factor_cache = Dict{Float64,Any}()
    sturm_factor_order = Float64[]
    function keep_sturm_factor!(sigma::Float64, F)
        F === nothing && return
        haskey(sturm_factor_cache, sigma) && return
        while length(sturm_factor_order) >= 2
            delete!(sturm_factor_cache, popfirst!(sturm_factor_order))
        end
        sturm_factor_cache[sigma] = F
        push!(sturm_factor_order, sigma)
        return
    end

    function attempt_shifted_buckling_search(sigma::Float64, attempt_name::String;
                                            modes_request_override::Union{Nothing,Int}=nothing,
                                            force_full_request::Bool=false)
        push!(diagnostics["solver_attempts"], Dict("name" => attempt_name, "status" => "attempted", "sigma" => sigma))
        try
            log_msg("[BUCKLING] Range-targeted shift-invert at sigma=$sigma ...")
            B = -Kg_ff
            M = K_ff - sigma * B
            M = 0.5 * (M + M')

            # AUTOSPC=NO decks can leave free dofs with no stiffness in either
            # K or Kg (zero row/col in M for EVERY sigma) - UMFPACK then throws
            # SingularException(0) and the whole range augmentation dies (HTP
            # iter_346: all shifts fail on both subcases). Detect and eliminate
            # those dofs from the shifted factorization; eigenvectors get zeros
            # there on re-embedding.
            M_dg = abs.(diag(M))
            m_ref = maximum(M_dg)
            live_dofs = findall(M_dg .> 1e-14 * max(m_ref, 1.0))
            reduced = length(live_dofs) < size(M, 1)
            if reduced
                log_msg("[BUCKLING] shift-invert: eliminating $(size(M,1) - length(live_dofs)) zero-stiffness dofs")
                M = M[live_dofs, live_dofs]
                B = B[live_dofs, live_dofs]
            end

            local factor_backend, M_factor
            if shift_factor_fusion && !reduced && haskey(sturm_factor_cache, sigma)
                # A certificate at exactly this σ already factored M: reuse
                # its LDLᵀ as the solve operator — zero factorization cost.
                factor_backend = "ldlt_cached"
                M_factor = sturm_factor_cache[sigma]
            elseif shift_factor_fusion && !reduced
                # LDLᵀ-first: one factorization yields the solve operator and
                # a reusable certificate factor at σ. CHOLMOD LDLᵀ is
                # simplicial with NO pivoting of any kind, so an
                # accidentally-tiny pivot (a dof whose diagonal cancels near
                # σ — the local-crippling condition) silently degrades the
                # solve by up to ~11 digits without throwing: reject factors
                # whose pivot spread exceeds sqrt(eps) and fall back to the
                # proven cholesky→LU ladder (the σ-jitter retry upstream
                # handles shifts landing exactly on eigenvalues).
                factor_backend = "ldlt"
                M_factor = try
                    ldlt(M)
                catch
                    nothing
                end
                if M_factor !== nothing
                    dM = abs.(diag(M_factor))
                    if minimum(dM) < sqrt(eps(Float64)) * maximum(dM)
                        M_factor = nothing   # numerically untrustworthy pivots
                    end
                end
                if M_factor === nothing
                    factor_backend = "cholesky"
                    M_factor = try
                        cholesky(M)
                    catch
                        factor_backend = "lu"
                        lu(M)
                    end
                else
                    keep_sturm_factor!(sigma, M_factor)
                end
            else
                factor_backend = "cholesky"
                M_factor =
                    try
                        cholesky(M)
                    catch
                        factor_backend = "lu"
                        lu(M)
                    end
            end

            nd_limited_range_augmentation =
                nd_limited_range_output &&
                solver_env_bool("JFEM_SOL105_RANGE_AUGMENTATION_ND_LIMIT", true) &&
                !force_full_request
            range_aug_buffer_default = 40
            range_aug_buffer = max(solver_env_int("JFEM_SOL105_RANGE_AUGMENTATION_BUFFER", range_aug_buffer_default), 0)
            local_num_modes_request = modes_request_override === nothing ?
                num_modes_request :
                min(max(modes_request_override, num_modes), max_modes)
            shifted_modes_request = nd_limited_range_augmentation ?
                min(local_num_modes_request, max(num_modes + range_aug_buffer, num_modes)) :
                local_num_modes_request
            shifted_modes_request = min(shifted_modes_request, n_free - 1)
            nev_request = min(shifted_modes_request + 5, n_free - 1)
            kd = _buckling_krylovdim(nev_request, n_free)
            krylov_tol = _buckling_krylovtol()
            krylov_maxiter = _buckling_krylovmaxiter()
            start_vec = next_start_vector()
            reduced && (start_vec = start_vec[live_dofs])
            vals_kk, vecs_kk, info = eigsolve(
                x -> M_factor \ (B * x), start_vec, nev_request, :LM;
                krylovdim=kd, maxiter=krylov_maxiter, tol=krylov_tol, eager=true)

            actual_lambdas = Float64[]
            actual_vecs = Vector{Float64}[]
            for (i, theta) in enumerate(vals_kk)
                theta_r = real(theta)
                theta_i = abs(imag(theta))
                if theta_i > 1e-6 * max(abs(theta_r), 1e-20) || abs(theta_r) < 1e-14
                    continue
                end
                lam = sigma + 1.0 / theta_r
                if abs(lam) > 1e-6
                    push!(actual_lambdas, lam)
                    push!(actual_vecs, real.(vecs_kk[i]))
                end
            end

            if isempty(actual_lambdas)
                diagnostics["solver_attempts"][end] = Dict(
                    "name" => attempt_name,
                    "status" => "no_valid_eigenvalues",
                    "sigma" => sigma,
                    "converged" => info.converged,
                    "factorization" => factor_backend,
                )
                return nothing
            end

            perm = sortperm(abs.(actual_lambdas .- sigma))
            n_out = min(shifted_modes_request, length(perm))
            lambdas = [actual_lambdas[perm[i]] for i in 1:n_out]
            vecs = hcat([actual_vecs[perm[i]] for i in 1:n_out]...)
            if reduced
                vecs_full = zeros(Float64, length(M_dg), size(vecs, 2))
                vecs_full[live_dofs, :] = vecs
                vecs = vecs_full
            end

            diagnostics["solver_attempts"][end] = Dict(
                "name" => attempt_name,
                "status" => "succeeded",
                "sigma" => sigma,
                "returned_modes" => n_out,
                "requested_modes_internal" => shifted_modes_request,
                "requested_modes_override" => modes_request_override,
                "force_full_request" => force_full_request,
                "nd_limited_range_output" => nd_limited_range_augmentation,
                "range_augmentation_buffer" => range_aug_buffer,
                "krylovdim" => kd,
                "krylov_tol" => krylov_tol,
                "krylov_maxiter" => krylov_maxiter,
                "converged" => info.converged,
                "factorization" => factor_backend,
            )
            return lambdas, vecs
        catch e
            diagnostics["solver_attempts"][end] = Dict(
                "name" => attempt_name,
                "status" => "failed",
                "sigma" => sigma,
                "error" => sprint(showerror, e),
            )
            log_msg("[BUCKLING] Range-targeted shift-invert failed: $(sprint(showerror, e))")
            # A shift landing on (or numerically near) a pencil eigenvalue makes
            # K - sigma*B (numerically) singular (LinearAlgebra.SingularException).
            # Retry with progressively larger inward jitters instead of abandoning
            # the range augmentation. HTP 511002: sigma = EIGRL v2 = 0.6 sits 7e-4
            # from a clustered mode (0.5996); a 0.3% jitter stays inside the
            # cluster, so the ladder steps 2% and 5% inward as well.
            if e isa LinearAlgebra.SingularException && !occursin("_jitter", attempt_name)
                for (tag, frac) in (("_jitter1", 3.0e-3), ("_jitter2", 2.0e-2), ("_jitter3", 5.0e-2))
                    sigma_j = sigma * (1.0 - frac) - 1.0e-9
                    res = attempt_shifted_buckling_search(sigma_j, attempt_name * tag;
                        modes_request_override=modes_request_override,
                        force_full_request=force_full_request)
                    res === nothing || return res
                end
            end
            return nothing
        end
    end

    function merge_unique_eigenpairs(base_vals::Vector{Float64}, base_vecs::AbstractMatrix,
                                     add_vals::Vector{Float64}, add_vecs::AbstractMatrix;
                                     rel_tol::Float64=1e-4, abs_tol::Float64=1e-8)
        merged_vals = copy(base_vals)
        merged_vec_cols = [Vector{Float64}(base_vecs[:, i]) for i in 1:size(base_vecs, 2)]
        added = 0
        for j in eachindex(add_vals)
            lam = Float64(add_vals[j])
            duplicate = any(existing ->
                abs(existing - lam) <= max(abs_tol, rel_tol * max(abs(existing), abs(lam), 1.0)),
                merged_vals)
            if duplicate
                continue
            end
            push!(merged_vals, lam)
            push!(merged_vec_cols, Vector{Float64}(add_vecs[:, j]))
            added += 1
        end
        merged_vecs = isempty(merged_vec_cols) ? zeros(Float64, size(base_vecs, 1), 0) : hcat(merged_vec_cols...)
        return merged_vals, merged_vecs, added
    end

    function range_augmentation_sigmas(range_idx_current)
        raw = strip(get(ENV, "JFEM_SOL105_RANGE_AUGMENTATION_SIGMAS", ""))
        sigmas = Float64[]
        if !isempty(raw)
            for part in split(raw, ",")
                sigma = tryparse(Float64, strip(part))
                sigma === nothing && continue
                if sigma >= eigrl_v1 && sigma <= eigrl_v2
                    push!(sigmas, sigma)
                end
            end
        elseif solver_env_bool("JFEM_SOL105_RANGE_AUGMENTATION_MULTI", false)
            count_raw = strip(get(ENV, "JFEM_SOL105_RANGE_AUGMENTATION_MULTI_COUNT", "4"))
            n_mid = tryparse(Int, count_raw)
            n_mid = n_mid === nothing ? 4 : clamp(n_mid, 1, 12)
            positives = [eigenvalues[i] for i in range_idx_current if eigenvalues[i] > max(eigrl_v1, 0.0)]
            low = isempty(positives) ? max(eigrl_v1, eps(Float64)) : maximum(positives)
            low = max(low, eps(Float64))
            front_factor_raw = strip(get(ENV, "JFEM_SOL105_RANGE_AUGMENTATION_FRONT_FACTOR", "1.25"))
            front_factor = tryparse(Float64, front_factor_raw)
            front_factor = front_factor === nothing ? 1.25 : clamp(front_factor, 1.01, 10.0)
            front = min(eigrl_v2, low * front_factor)
            if front > low * (1.0 + 1e-8)
                push!(sigmas, front)
            end
            if eigrl_v2 > front * (1.0 + 1e-8)
                ratio = (eigrl_v2 / front)^(1.0 / n_mid)
                for k in 1:n_mid
                    push!(sigmas, front * ratio^k)
                end
            else
                push!(sigmas, eigrl_v2)
            end
        else
            push!(sigmas, eigrl_v2)
        end

        push!(sigmas, eigrl_v2)
        sort!(sigmas)
        unique_sigmas = Float64[]
        for sigma in sigmas
            if sigma < eigrl_v1 || sigma > eigrl_v2
                continue
            end
            if isempty(unique_sigmas) ||
               abs(sigma - unique_sigmas[end]) > max(1e-8, 1e-6 * max(abs(sigma), abs(unique_sigmas[end]), 1.0))
                push!(unique_sigmas, sigma)
            end
        end
        return unique_sigmas
    end

    # Strategy 1: Dense symmetric-definite eigensolver for SMALL systems only.
    # K is positive definite after SPC elimination, so solve the Cholesky-reduced
    # symmetric problem C*y = θ*y with C = L⁻¹*B*L⁻ᵀ, θ = 1/λ, B = -Kg.
    # Gated by _buckling_dense_max_dof() (default 200, was 4000) — larger systems
    # use the iterative shift-invert Lanczos/Krylov path below, which is then
    # checked for completeness with a Sturm inertia count.
    if will_use_dense
        push!(diagnostics["solver_attempts"], Dict("name" => "dense_symmetric_definite", "status" => "attempted"))
        try
            log_msg("[BUCKLING] Using dense symmetric-definite eigensolver ($n_free DOFs)...")
            Kd = Matrix(K_ff)
            Bgd = Matrix(-Kg_ff)
            K_factor = cholesky(Symmetric(Kd))
            L = Matrix(K_factor.L)
            C = L \ (Bgd / L')
            C = 0.5 * (C + C')
            theta_vals, theta_vecs = eigen(Symmetric(C))
            valid = findall(x -> isfinite(x) && abs(x) > 1e-12, theta_vals)
            if !isempty(valid)
                thetas = theta_vals[valid]
                lambdas = 1.0 ./ thetas
                vecs = K_factor.U \ theta_vecs[:, valid]
                perm = sortperm(abs.(lambdas))
                # Dense solves already computed the whole spectrum. For ranged
                # SOL105 extraction, keep it until the positive/range filter
                # below; indefinite prestress can put many load-reversal roots
                # ahead of the requested positive branch in |lambda| ordering.
                n_out = has_range ? length(perm) : min(num_modes_request, length(perm))
                eigenvalues = real.(lambdas[perm[1:n_out]])
                eigenvectors = real.(vecs[:, perm[1:n_out]])
                solved = true
                diagnostics["solver_backend"] = "dense_symmetric_definite"
                diagnostics["solver_attempts"][end] = Dict("name" => "dense_symmetric_definite", "status" => "succeeded", "returned_modes" => n_out)
                log_msg("[BUCKLING] Dense symmetric-definite eigensolver converged ($n_out modes)")
            else
                diagnostics["solver_attempts"][end] = Dict("name" => "dense_symmetric_definite", "status" => "no_valid_eigenvalues")
                log_msg("[BUCKLING] Dense symmetric-definite eigensolver: no valid eigenvalues found")
            end
        catch e
            diagnostics["solver_attempts"][end] = Dict("name" => "dense_symmetric_definite", "status" => "failed", "error" => sprint(showerror, e))
            log_msg("[BUCKLING] Dense symmetric-definite eigensolver failed: $e")
        end

        if !solved
            push!(diagnostics["solver_attempts"], Dict("name" => "dense_generalized", "status" => "attempted"))
            try
                log_msg("[BUCKLING] Fallback dense generalized eigensolver ($n_free DOFs)...")
                Kd = Matrix(K_ff)
                Bgd = Matrix(-Kg_ff)
                all_vals, all_vecs = eigen(Kd, Bgd)
                valid = findall(x -> isfinite(x) && isreal(x) && abs(real(x)) > 1e-6, all_vals)
                if !isempty(valid)
                    lambdas = real.(all_vals[valid])
                    vecs = real.(all_vecs[:, valid])
                    perm = sortperm(abs.(lambdas))
                    n_out = has_range ? length(perm) : min(num_modes_request, length(perm))
                    eigenvalues = lambdas[perm[1:n_out]]
                    eigenvectors = vecs[:, perm[1:n_out]]
                    solved = true
                    diagnostics["solver_backend"] = "dense_generalized"
                    diagnostics["solver_attempts"][end] = Dict("name" => "dense_generalized", "status" => "succeeded", "returned_modes" => n_out)
                    log_msg("[BUCKLING] Fallback dense generalized eigensolver converged ($n_out modes)")
                else
                    diagnostics["solver_attempts"][end] = Dict("name" => "dense_generalized", "status" => "no_valid_eigenvalues")
                    log_msg("[BUCKLING] Fallback dense generalized eigensolver: no valid eigenvalues found")
                end
            catch e
                diagnostics["solver_attempts"][end] = Dict("name" => "dense_generalized", "status" => "failed", "error" => sprint(showerror, e))
                log_msg("[BUCKLING] Fallback dense generalized eigensolver failed: $e")
            end
        end
    end

    # Strategy 2: KrylovKit inverse iteration (pure Julia, no Fortran deps)
    # Generalized problem: K*x = λ*B*x where B = -Kg
    # Zero-shift inverse iteration: K⁻¹*B*x = θ*x where θ = 1/λ
    # Largest |θ| from KrylovKit → smallest |λ| (lowest buckling load)
    if !solved
        push!(diagnostics["solver_attempts"], Dict("name" => "krylov_inverse_iteration", "status" => "attempted"))
        try
            log_msg("[BUCKLING] Using KrylovKit inverse iteration ($n_free DOFs)...")
            B = -Kg_ff

            # Factorize K (Cholesky when SPD, LU fallback otherwise).
            K_factor, factor_cache_hit = ensure_eigen_solve_factorization!(eigen_ctx)
            diagnostics["eigen_cache"]["factorization_cache_hit"] = factor_cache_hit
            diagnostics["eigen_cache"]["factor_backend"] = eigen_ctx.factor_backend
            if factor_cache_hit
                log_msg("[BUCKLING] Reusing eigen K factorization cache ($(eigen_ctx.factor_backend))")
            else
                log_msg("[BUCKLING] K factorization succeeded ($(eigen_ctx.factor_backend))")
            end

            # Request extra eigenvalues for robustness. Buckling modes on aircraft
            # shell structures often have nearly-degenerate pairs (symmetric/
            # antisymmetric about a plane of near-symmetry); tight tol + eager=false
            # ensures consistent ordering of those pairs across formulation changes.
            nev_full = min(num_modes_request + 5, n_free - 1)
            krylov_tol = _buckling_krylovtol()
            krylov_maxiter = _buckling_krylovmaxiter()

            # Adaptive nev (perf program Phase 3.2, env-flagged): range decks
            # inflate the request to ~8x ND although the output is capped at
            # ND — most of that Krylov space is provably discarded work. The
            # escalation ladder starts near ND + buffer and stops as soon as
            # the CONVERGED spectrum either holds >= ND positive in-range
            # roots or contains a positive root strictly ABOVE the range:
            # zero-shift inverse iteration enumerates by |lambda|, so a
            # converged positive root beyond V2 proves every positive root
            # below it was recovered. A rung that converges fewer than its
            # request escalates unconditionally (unconverged trailing Ritz
            # values invert to huge fake "bracketing" roots). Guards: only
            # ND-limited output (RETURN_ALL_IN_RANGE inspects the full
            # range), and only while the Sturm safety net — the
            # certificate-first gate or the completeness augmentation — is
            # env-armed to catch the converged-subset caveat; otherwise the
            # ladder collapses to the full request. One start vector serves
            # every rung, so ordinal consumption matches the flag-OFF run
            # exactly and an escalated final rung IS today's solve.
            # NOTE bounded_signed_magnitude_output is constant false since
            # the 2026-07-27 signed-magnitude strip and is defined AFTER
            # this block; the ladder's positive-only count is sound only
            # while that remains true — hoist it into the guard if the
            # signed-magnitude selector is ever reintroduced.
            # Promoted to default ON 2026-08-06: two consecutive clean
            # 42-deck fabric runs (retained spectra within 4e-14 of the
            # full-request baseline, parity row-identical, zero margin-rule
            # violations), suite values exactly equal, 20-repeat stability
            # exact-zero. Opt out with JFEM_SOL105_ADAPTIVE_NEV=false.
            adaptive_nev = has_range && nd_limited_range_output && !will_use_dense &&
                           solver_env_bool("JFEM_SOL105_ADAPTIVE_NEV", true) &&
                           (solver_env_bool("JFEM_SOL105_CERT_FIRST_AUGMENTATION", true) ||
                            solver_env_bool("JFEM_SOL105_RANGE_COMPLETENESS_AUGMENT", true))
            nev_ladder = if adaptive_nev
                nev_buf = max(solver_env_int("JFEM_SOL105_ADAPTIVE_NEV_BUFFER",
                                             max(num_modes, 8)), 1)
                sort(unique([min(num_modes + nev_buf, nev_full),
                             min(4 * num_modes + 5, nev_full),
                             nev_full]))
            else
                [nev_full]
            end

            # K⁻¹*B operator: find largest magnitude eigenvalues θ = 1/λ
            # tol tightened from 1e-10 → 1e-13 (2026-04-21): HTP_launch has mode-1/2
            # pairs separated by <0.1%; loose convergence lets order wobble between
            # solver runs and between formulation changes, masking as a "bug".
            # Symmetric Lanczos via Cholesky congruence (perf program Phase
            # 3.4, env-flagged, default OFF): with K = Pᵀ L Lᵀ P SPD, the
            # operator S = L⁻¹ (P B Pᵀ) L⁻ᵀ is SYMMETRIC with the same
            # eigenvalues θ as K⁻¹B, so KrylovKit can run real Lanczos
            # (ishermitian=true) instead of general Arnoldi: three-term
            # recurrence, real tridiagonal Ritz problem, no complex-pair
            # filtering. Eigenvectors map back as u = Pᵀ L⁻ᵀ y. The L
            # extraction works on a COPY of the K factor — sparse(F.L) can
            # convert a supernodal factor in place, which would change the
            # rounding of every later F \ b for the shared cached factor.
            symm_ctx = nothing
            if solver_env_bool("JFEM_SOL105_SYMM_LANCZOS", false) &&
               eigen_ctx.factor_backend == "cholesky"
                symm_ctx = try
                    Fc = copy(K_factor)
                    pperm = Fc.p
                    LT = LowerTriangular(sparse(Fc.L))
                    (LT, pperm, B[pperm, pperm])
                catch err
                    log_msg("[BUCKLING] symmetric-Lanczos congruence unavailable ($(sprint(showerror, err))); using Arnoldi")
                    nothing
                end
            end

            local vals_kk, vecs_kk, info
            nev_request = nev_ladder[end]
            kd = _buckling_krylovdim(nev_request, n_free)
            adaptive_attempts = Any[]
            ladder_start_vec = next_start_vector()
            for (rung_i, nev_try) in enumerate(nev_ladder)
                nev_request = nev_try
                kd = _buckling_krylovdim(nev_request, n_free)
                if symm_ctx !== nothing
                    LTs, pperm, Bp = symm_ctx
                    vals_kk, vecs_kk, info = eigsolve(
                        y -> LTs \ (Bp * (LTs' \ y)), ladder_start_vec, nev_request, :LM;
                        krylovdim=kd, maxiter=krylov_maxiter, tol=krylov_tol,
                        eager=true, ishermitian=true)
                else
                    vals_kk, vecs_kk, info = eigsolve(
                        x -> K_factor \ (B * x), ladder_start_vec, nev_request, :LM;
                        krylovdim=kd, maxiter=krylov_maxiter, tol=krylov_tol, eager=true)
                end
                if rung_i == length(nev_ladder)
                    adaptive_nev && push!(adaptive_attempts, Dict{String,Any}(
                        "nev" => nev_try, "kd" => kd,
                        "converged" => info.converged, "pos_in_range" => -1,
                        "brackets_above_v2" => false, "decision" => "final"))
                    break
                end
                pos_in_range = 0
                brackets = false
                if info.converged >= nev_try
                    for theta in vals_kk[1:min(info.converged, length(vals_kk))]
                        theta_r = real(theta)
                        (abs(imag(theta)) > 1e-6 * max(abs(theta_r), 1e-20) ||
                         abs(theta_r) < 1e-14) && continue
                        lam = 1.0 / theta_r
                        # mirror the θ→λ conversion floor exactly, so the
                        # ladder never counts a root the output would drop
                        (lam > positive_tol && abs(lam) > 1e-6) || continue
                        # hysteresis: clear V2 by 1e-6 rel to count as
                        # bracketing (decision-boundary robustness)
                        lam > v2_eff + max(1e-6 * abs(v2_eff), 1e-12) && (brackets = true)
                        v1_eff <= lam <= v2_eff && (pos_in_range += 1)
                    end
                end
                sufficient = pos_in_range >= num_modes || brackets
                push!(adaptive_attempts, Dict{String,Any}(
                    "nev" => nev_try, "kd" => kd, "converged" => info.converged,
                    "pos_in_range" => pos_in_range, "brackets_above_v2" => brackets,
                    "decision" => sufficient ? "sufficient" : "escalated"))
                if sufficient
                    log_msg("[BUCKLING] adaptive nev: rung $rung_i (nev=$nev_try, converged=$(info.converged)) sufficient ($pos_in_range in-range, brackets=$brackets)")
                    break
                end
                log_msg("[BUCKLING] adaptive nev: rung $rung_i (nev=$nev_try, converged=$(info.converged)) insufficient ($pos_in_range in-range) — escalating")
            end
            isempty(adaptive_attempts) ||
                (diagnostics["adaptive_nev"] = adaptive_attempts)

            # Congruence back-map: eigsolve returned y-space vectors;
            # u = Pᵀ L⁻ᵀ y restores pencil eigenvectors (θ values unchanged).
            if symm_ctx !== nothing
                LTs, pperm, _ = symm_ctx
                vecs_kk = [begin
                    u = zeros(Float64, n_free)
                    u[pperm] = LTs' \ real.(y)
                    u
                end for y in vecs_kk]
                diagnostics["symm_lanczos"] = true
            end

            log_msg("[BUCKLING] KrylovKit returned $(length(vals_kk)) eigenvalues (converged=$(info.converged))")

            # Convert θ → λ = 1/θ
            actual_lambdas = Float64[]
            actual_vecs = Vector{Float64}[]
            for (i, theta) in enumerate(vals_kk)
                theta_r = real(theta)
                theta_i = abs(imag(theta))
                # Skip complex and near-zero eigenvalues
                if theta_i > 1e-6 * max(abs(theta_r), 1e-20) || abs(theta_r) < 1e-14
                    continue
                end
                lam = 1.0 / theta_r
                if abs(lam) > 1e-6
                    push!(actual_lambdas, lam)
                    push!(actual_vecs, real.(vecs_kk[i]))
                end
            end
            if !isempty(actual_lambdas)
                perm = sortperm(abs.(actual_lambdas))
                n_out = min(num_modes_request, length(perm))
                eigenvalues = [actual_lambdas[perm[i]] for i in 1:n_out]
                eigenvectors = hcat([actual_vecs[perm[i]] for i in 1:n_out]...)
                solved = true
                diagnostics["solver_backend"] = "krylov_inverse_iteration"
                diagnostics["solver_attempts"][end] = Dict(
                    "name" => "krylov_inverse_iteration",
                    "status" => "succeeded",
                    "returned_modes" => n_out,
                    "converged" => info.converged,
                    "krylovdim" => kd,
                    "krylov_tol" => krylov_tol,
                    "krylov_maxiter" => krylov_maxiter,
                )
                log_msg("[BUCKLING] KrylovKit converged ($n_out modes)")
                if solver_env_bool("JFEM_BUCKLING_LOG_RAW_EIGENVALUES", false)
                    for lam in eigenvalues
                        log_msg("[BUCKLING]   θ=$(1.0/lam) → λ=$lam")
                    end
                end
                # Diagnostic: residual + Sturm count (env-gated, single case use).
                # JFEM_DEBUG_STURM_SIGMAS=0.1,0.5,1.0,1.2 → print Sturm counts
                # Residuals are always logged when the flag is set.
                if solver_env_bool("JFEM_DEBUG_BUCKLING", false)
                    # Residual per mode: ||K u - λ (-Kg) u|| / ||K u||
                    B_op = -Kg_ff
                    for m in 1:n_out
                        u_m = eigenvectors[:, m]
                        Ku  = K_ff * u_m
                        Bu  = B_op * u_m
                        lam = eigenvalues[m]
                        nrm_Ku = norm(Ku)
                        rel_res = norm(Ku - lam * Bu) / max(nrm_Ku, 1e-30)
                        log_msg("[BUCKLING][DBG] mode $m: λ=$lam, ||r||/||Ku||=$(rel_res)")
                    end
                    sigmas_env = get(ENV, "JFEM_DEBUG_STURM_SIGMAS", "")
                    if !isempty(strip(sigmas_env))
                        for s_str in split(sigmas_env, ",")
                            sigma = tryparse(Float64, strip(s_str))
                            isnothing(sigma) && continue
                            M = K_ff + sigma * Kg_ff
                            M = 0.5 * (M + M')
                            try
                                F = lu(M)
                                n_neg = count(d -> d < 0.0, diag(F.U))
                                log_msg("[BUCKLING][DBG] Sturm count at σ=$sigma: $n_neg negative diag(U) ⇒ ≈$n_neg eigenvalues below σ")
                            catch e
                                log_msg("[BUCKLING][DBG] Sturm count at σ=$sigma: LU failed ($(sprint(showerror, e)))")
                            end
                        end
                    end
                end
            else
                diagnostics["solver_attempts"][end] = Dict("name" => "krylov_inverse_iteration", "status" => "no_valid_eigenvalues", "converged" => info.converged)
                log_msg("[BUCKLING] KrylovKit: no valid real eigenvalues found")
            end
        catch e
            diagnostics["solver_attempts"][end] = Dict("name" => "krylov_inverse_iteration", "status" => "failed", "error" => sprint(showerror, e))
            log_msg("[BUCKLING] KrylovKit inverse iteration failed: $(sprint(showerror, e))")
        end
    end

    # Strategy 3: KrylovKit with shift near first mode (refine if Strategy 2 failed)
    if !solved
        push!(diagnostics["solver_attempts"], Dict("name" => "krylov_shifted", "status" => "attempted"))
        try
            log_msg("[BUCKLING] Fallback: KrylovKit with small shift...")
            B = -Kg_ff
            sigma = 1.0  # small positive shift

            M = K_ff - sigma * B
            M = 0.5 * (M + M')
            local M_factor
            try
                M_factor = cholesky(M)
            catch
                M_factor = lu(M)
            end

            nev_request = min(num_modes_request + 5, n_free - 1)
            kd = _buckling_krylovdim(nev_request, n_free)
            krylov_tol = _buckling_krylovtol()
            krylov_maxiter = _buckling_krylovmaxiter()
            vals_kk, vecs_kk, info = eigsolve(
                x -> M_factor \ (B * x), next_start_vector(), nev_request, :LM;
                krylovdim=kd, maxiter=krylov_maxiter, tol=krylov_tol, eager=true)

            actual_lambdas = Float64[]
            actual_vecs = Vector{Float64}[]
            for (i, theta) in enumerate(vals_kk)
                theta_r = real(theta)
                if abs(imag(theta)) > 1e-6 * max(abs(theta_r), 1e-20) || abs(theta_r) < 1e-14
                    continue
                end
                lam = sigma + 1.0 / theta_r
                if abs(lam) > 1e-6
                    push!(actual_lambdas, lam)
                    push!(actual_vecs, real.(vecs_kk[i]))
                end
            end
            if !isempty(actual_lambdas)
                perm = sortperm(abs.(actual_lambdas))
                n_out = min(num_modes_request, length(perm))
                eigenvalues = [actual_lambdas[perm[i]] for i in 1:n_out]
                eigenvectors = hcat([actual_vecs[perm[i]] for i in 1:n_out]...)
                solved = true
                diagnostics["solver_backend"] = "krylov_shifted"
                diagnostics["solver_attempts"][end] = Dict(
                    "name" => "krylov_shifted",
                    "status" => "succeeded",
                    "returned_modes" => n_out,
                    "converged" => info.converged,
                    "krylovdim" => kd,
                    "krylov_tol" => krylov_tol,
                    "krylov_maxiter" => krylov_maxiter,
                )
                log_msg("[BUCKLING] Fallback KrylovKit converged ($n_out modes)")
            end
        catch e
            diagnostics["solver_attempts"][end] = Dict("name" => "krylov_shifted", "status" => "failed", "error" => sprint(showerror, e))
            log_msg("[BUCKLING] Fallback KrylovKit failed: $(sprint(showerror, e))")
        end
    end

    if !solved
        log_msg("[BUCKLING] ERROR: All eigenvalue solvers failed")
        diagnostics["solver_backend"] = "failed"
        buckling_timings["eigensolver_search"] = (time_ns() - t_eigen_search) * 1e-9
        buckling_timings["total"] = (time_ns() - t_buckling_total) * 1e-9
        diagnostics["timings"] = buckling_timings
        return return_diagnostics ? (Float64[], zeros(ndof, 0), diagnostics) : (Float64[], zeros(ndof, 0))
    end
    buckling_timings["eigensolver_search"] = (time_ns() - t_eigen_search) * 1e-9
    t_postprocess = time_ns()

    # Post-process eigenvalues for Nastran-style SOL105 reporting.
    #
    # If EIGRL has no V1/V2 bounds, MSC/Nastran reports signed real buckling
    # roots in extraction order, which is effectively increasing |lambda| for
    # the extraction used here. Keeping only positive roots in that case hides
    # tensile-direction roots printed by Nastran and can move the first reported
    # eigenvalue by orders of magnitude on probe decks.
    #
    # If an explicit bounded range is present, keep the historical compression
    # design behavior: positive load factors in [max(V1,+tol), V2]. This
    # preserves the GAME SOL105 range semantics and avoids re-admitting negative
    # load-reversal modes through common decks with V1=-1e-4.
    n_found = length(eigenvalues)
    log_msg("[BUCKLING] Found $n_found eigenvalues (raw, pre-filter)")

    # (positive_tol is defined once, up with the range bounds.)
    raw_eigen_csv_path = strip(get(ENV, "JFEM_BUCKLING_RAW_EIGEN_CSV", ""))
    if !isempty(raw_eigen_csv_path)
        _write_buckling_raw_eigen_csv(eigenvalues, raw_eigen_csv_path;
            buckling_subcase=buckling_subcase,
            static_subcase=static_subcase,
            backend=get(diagnostics, "solver_backend", ""),
            phase="pre_positive_filter",
            requested_modes=num_modes,
            requested_modes_internal=num_modes_request,
            eigrl_v1=eigrl_v1,
            eigrl_v2=eigrl_v2,
            positive_tol=positive_tol)
        diagnostics["raw_eigen_csv"] = raw_eigen_csv_path
    end
    # 2026-07-27 (strip Stage 1): ALL signed-magnitude output conventions are disabled.
    # Both of them reported |lambda| for negative roots and ordered the spectrum by |lambda|,
    # which silently changes which eigenvalue is reported as mode 1. Nastran does neither: its
    # Lanczos returns the roots found in the EIGRL range, ordered by lambda ascending, sign
    # intact. The bounded variant was armed by `_sol105_signedmag_auto_high_pm45_selector`, a
    # whole-model deck fingerprint (aspect 5.0-6.6 AND h/Lmax 0.0130-0.0145 AND pm45 0.40-0.48
    # AND pm90 0.20-0.25 AND ply_count == 9 exactly AND >= 250 matching quads).
    # The selector and its 14 threshold accessors are removed in the follow-up pass.
    signed_unbounded_output = false
    signedmag_auto_info = Dict{String,Any}(
        "selector" => "removed_2026_07_27",
        "enabled" => false,
        "active" => false,
    )
    bounded_signed_magnitude_manual = false
    bounded_signed_magnitude_output = false
    if bounded_signed_magnitude_output && Bool(get(signedmag_auto_info, "active", false)) &&
       !bounded_signed_magnitude_manual
        log_msg("[BUCKLING] Bounded signed-magnitude output auto-enabled by PCOMP geometry selector: " *
                "$(get(signedmag_auto_info, "matching_pcomp_quads", 0))/" *
                "$(get(signedmag_auto_info, "total_pcomp_quads", 0)) matching PCOMP quads " *
                "(high+/-45=$(get(signedmag_auto_info, "matching_high_pm45_pcomp_quads", 0)), " *
                "balanced=$(get(signedmag_auto_info, "matching_balanced_pcomp_quads", 0)), " *
                "balanced_global=$(get(signedmag_auto_info, "balanced_global_active", false)))")
    elseif has_range && Bool(get(signedmag_auto_info, "enabled", false)) &&
           solver_env_bool("JFEM_SOL105_BOUNDED_SIGNED_MAGNITUDE_AUTO_DEBUG", false)
        log_msg("[BUCKLING] Bounded signed-magnitude selector inactive: " *
                "high+/-45=$(get(signedmag_auto_info, "matching_high_pm45_pcomp_quads", 0)), " *
                "balanced=$(get(signedmag_auto_info, "matching_balanced_pcomp_quads", 0)), " *
                "balanced_global=$(get(signedmag_auto_info, "balanced_global_active", false)), " *
                "aggregate=$(get(signedmag_auto_info, "aggregate_descriptors", Dict{String,Any}()))")
    end
    diagnostics["bounded_signed_magnitude_selector"] = merge(
        Dict{String,Any}(
            "manual" => bounded_signed_magnitude_manual,
            "output" => bounded_signed_magnitude_output,
        ),
        signedmag_auto_info,
    )
    # 2026-07-27 (strip Stage 1): signed-magnitude output is DISABLED unconditionally.
    # It reported |lambda| for negative roots and sorted by |lambda|, which changes WHICH
    # eigenvalue is called mode 1. Nastran's Lanczos reports the roots it finds in the EIGRL
    # range, ordered by lambda ascending — so that is what we do. The two auto-selectors that
    # used to switch this on were whole-model deck fingerprints (aspect/ply-count/h-L windows
    # with a >=250 matching-quad count); they are removed with the rest of the machinery.
    signed_magnitude_output = false
    valid_idx = findall(x -> isfinite(x) && x > positive_tol, eigenvalues)
    if length(valid_idx) < n_found
        dropped = n_found - length(valid_idx)
        if signed_magnitude_output
            log_msg("[BUCKLING] Dropped $dropped near-zero/non-finite eigenvalues")
        else
            log_msg("[BUCKLING] Dropped $dropped non-positive eigenvalues (bounded compression range)")
        end
    end

    # Apply EIGRL V1/V2 range filter if specified (v1_eff/v2_eff are the
    # hoisted effective bounds shared with the adaptive-nev ladder).
    if has_range
        range_idx = bounded_signed_magnitude_output ?
            filter(i -> abs(eigenvalues[i]) >= v1_eff && abs(eigenvalues[i]) <= v2_eff, valid_idx) :
            filter(i -> eigenvalues[i] >= v1_eff && eigenvalues[i] <= v2_eff, valid_idx)
        range_kind = bounded_signed_magnitude_output ? "signed-magnitude" : "positive"
        if v2_eff > eigrl_v2
            log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2] with upper tolerance -> $v2_eff: $(length(range_idx)) of $(length(valid_idx)) $range_kind eigenvalues in range")
        else
            log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: $(length(range_idx)) of $(length(valid_idx)) $range_kind eigenvalues in range")
        end
        valid_idx = range_idx
        diagnostics["bounded_signed_magnitude_output"] = bounded_signed_magnitude_output

        # Sturm counts, shared by the certificate-first augmentation gate
        # below and the completeness augmentation: each count is a full
        # sparse LDL' of K + sigma*Kg — the dominant eigen-phase cost at
        # production sizes — and the symbolic analysis is additionally
        # shared across sigmas via sturm_reuse (the pattern is
        # sigma-independent). Cached, so whichever consumer runs first pays;
        # every later consumer at the same sigma is free. The reuse factor
        # is seeded from (and written back to) the per-deck eigen cache, so
        # the SECOND buckling subcase of a deck skips the symbolic analysis
        # entirely — inertia counts are permutation-invariant (Sylvester),
        # so cross-subcase reuse cannot change any integer result. Under
        # ShiftFactor fusion, counts instead keep their fresh Factor for
        # reuse as shift-invert operators, and a fused shifted solve can
        # prime a count for free (sturm_prime_count).
        sturm_reuse = Base.RefValue{Any}(eigen_ctx.sturm_factor)
        sturm_cache = Dict{Float64,Union{Int,Nothing}}()
        sturm_at(sig::Float64) = get!(sturm_cache, sig) do
            if shift_factor_fusion && haskey(sturm_factor_cache, sig)
                # a fused shifted solve already factored M(σ) (bit-identical
                # construction, audited): its pivot signs ARE the count
                Int(count(<(0.0), diag(sturm_factor_cache[sig])))
            elseif shift_factor_fusion
                fo = Base.RefValue{Any}(nothing)
                c = _buckling_sturm_count(K_ff, Kg_ff, sig; factor_out=fo)
                # keep only operator-grade factors: an accidentally-tiny
                # unpivoted LDLᵀ pivot is fine for the (pre-existing) count
                # semantics but would silently degrade a reused SOLVE
                if fo[] !== nothing
                    dF = abs.(diag(fo[]))
                    minimum(dF) >= sqrt(eps(Float64)) * maximum(dF) &&
                        keep_sturm_factor!(sig, fo[])
                end
                c
            else
                c = _buckling_sturm_count(K_ff, Kg_ff, sig; reuse=sturm_reuse)
                eigen_ctx.sturm_factor = sturm_reuse[]
                c
            end
        end

        # Sturm gap over the reported positive range, evaluated against the
        # CURRENT eigenvalues/valid_idx state at call time (pre- or
        # post-augmentation). Returns nothing when no certificate can be
        # formed (no positive roots, inertia unavailable).
        function current_range_sturm_gap()
            a_bound = max(eigrl_v1, positive_tol)
            pos_vals = sort!([eigenvalues[i] for i in valid_idx if eigenvalues[i] > positive_tol])
            isempty(pos_vals) && return nothing
            # ---------------------------------------------------------------
            # Completeness is only meaningful UP TO THE HIGHEST ROOT WE REPORT.
            #
            # The iterative extraction requests ~8x ND modes but the output is capped at
            # ND (see the EIGRL-ND cap below). Bounding this check by the highest
            # RECOVERED root therefore demands completeness over (v1, lambda_32] while
            # only (v1, lambda_4] is ever emitted: any root the Krylov solve did not
            # converge to between lambda_ND and lambda_max leaves a PERMANENT positive
            # gap, so the loop re-shifts to its budget on every narrow-EIGRL deck and
            # cannot ever close. Measured cost of that: 2917 s of a 2928 s solve
            # (99.6 %), for eigenvalues identical to the loop-disabled run.
            #
            # Bounding by the ND-th root instead gives the standard, SATISFIABLE
            # certificate -- "no eigenvalue was missed below the last root reported" --
            # which is exactly the guarantee that matters and terminates.
            cap_to_reported = solver_env_bool("JFEM_SOL105_COMPLETENESS_TO_REPORTED", true)
            n_report = cap_to_reported ? min(max(num_modes, 1), length(pos_vals)) : length(pos_vals)
            b_bound = pos_vals[n_report] * (1.0 + 1e-6)
            b_bound > a_bound || return nothing
            sc_b = sturm_at(b_bound)
            # Lower-bound short-circuit: with no positive V1 the lower
            # bound sits at +tol, and a PD-certified K_ff (its Cholesky
            # succeeded) has inertia 0 there by construction — skip a
            # full LDL' factorization for a count that cannot be nonzero.
            sc_a = if a_bound <= positive_tol && eigrl_v1 <= 0.0 &&
                      eigen_ctx.factor_backend == "cholesky"
                0
            else
                sturm_at(a_bound)
            end
            (sc_a === nothing || sc_b === nothing) && return nothing
            expected = max(sc_b - sc_a, 0)
            found = count(i -> begin
                    v = eigenvalues[i]
                    v > positive_tol && v >= a_bound - eps(Float64) && v <= b_bound + eps(Float64)
                end, valid_idx)
            return Dict{String,Any}(
                "interval" => [a_bound, b_bound],
                "sturm_eigs_in_interval" => expected,
                "recovered_in_interval" => found,
                "gap" => expected - found,
                "sturm_lower" => sc_a,
                "sturm_upper" => sc_b,
            )
        end

        # Zero-shift inverse iteration naturally favors the smallest-|lambda| roots.
        # When a buckling range upper bound is present, augment the in-range spectrum
        # with a targeted shift-invert search near V2 so upper-branch modes are not
        # missed behind lower-|lambda| or negative clusters.
        if !will_use_dense
            # --- Gate: should we run the augmentation at all? ---
            # Safe auto-skip: Strategy 2 has already produced eigenvalues BOTH
            # above V2 and below V1, AND returned enough in-range modes. That
            # proves the zero-shift search spanned the range (no "upper-branch
            # modes hiding behind low-|λ| clusters" can exist). Augmentation
            # would only rediscover duplicates. This branch is intentionally
            # strict so that the GAME validation suite (where Strategy 2 only
            # reaches near zero) never takes it — parity preserved by default.
            #
            # Env opt-out: users may set JFEM_SOL105_SKIP_RANGE_AUGMENTATION=true
            # to force-skip even when the auto gate wouldn't — trades
            # in-range spectrum completeness for ~30-50% faster eigensolves.
            env_skip_aug = solver_env_bool("JFEM_SOL105_SKIP_RANGE_AUGMENTATION", false)
            explicit_aug_sigmas = !isempty(strip(get(ENV, "JFEM_SOL105_RANGE_AUGMENTATION_SIGMAS", "")))
            # Default ON (2026-04-29): the zero-shift inverse iteration only finds
            # smallest-|λ| roots, which for bending-dominant prestress (e.g. 3-point
            # bending) are spurious low/negative modes near 0, NOT the physical
            # buckling modes higher up in the [V1,V2] range. Without this shift-
            # invert near V2 the solver returns the wrong spectrum and reports
            # "no positive modes". The auto-skip gate below still prevents
            # redundant work when zero-shift already brackets the range.
            range_aug_requested =
                solver_env_bool("JFEM_SOL105_RANGE_AUGMENTATION", true) ||
                solver_env_bool("JFEM_SOL105_RANGE_AUGMENTATION_MULTI", false) ||
                explicit_aug_sigmas
            spans_above_V2 = any(v -> real(v) > eigrl_v2, eigenvalues)
            spans_below_V1 = any(v -> real(v) < eigrl_v1, eigenvalues)
            sufficient_in_range = length(range_idx) >= num_modes_request
            auto_skip_aug = spans_above_V2 && spans_below_V1 && sufficient_in_range

            # Certificate-first gate (perf program Phase 3.1). Promoted to
            # default ON 2026-08-06 after the full protocol: two consecutive
            # clean 42-deck fabric runs flag-ON (eigen_score exactly 0 vs
            # flag-OFF, parity 83/83 within 1%, zero margin-rule violations)
            # plus the public suite field-diff (values exactly equal,
            # verdicts identical). Opt out with
            # JFEM_SOL105_CERT_FIRST_AUGMENTATION=false: before paying
            # the V2-targeted shifted eigsolve, ask the Sturm certificate
            # whether the zero-shift pass already recovered every root up to
            # the ND-th reported one. When >= ND positive in-range roots
            # exist AND the inertia count over (a, lambda_ND*(1+1e-6)]
            # equals the recovered count, the ND-capped output is provably
            # invariant to skipping the augmentation: it could only add
            # duplicates below the cap (excluded by gap==0) or roots above
            # it (removed by the cap). Guards: ND-limited output only
            # (RETURN_ALL_IN_RANGE inspects the full range) and
            # positive-branch output only (the certificate counts positive
            # roots, so signed-magnitude decks keep today's behavior). The
            # recovered_from_empty rescue class fails the >=ND guard and is
            # untouched. The counts stay cached (sturm_cache above), so the
            # completeness section below re-certifies for free.
            cert_first = solver_env_bool("JFEM_SOL105_CERT_FIRST_AUGMENTATION", true)
            cert_skip_aug = false
            cert_gap_info = nothing
            cert_wall = 0.0
            if cert_first && range_aug_requested && !env_skip_aug && !auto_skip_aug &&
               nd_limited_range_output && !bounded_signed_magnitude_output
                t_cert = time_ns()
                n_pos_in_range = count(i -> eigenvalues[i] > positive_tol, valid_idx)
                if n_pos_in_range >= num_modes
                    cert_gap_info = current_range_sturm_gap()
                    cert_skip_aug = cert_gap_info !== nothing &&
                                    Int(get(cert_gap_info, "gap", 1)) <= 0
                end
                cert_wall = (time_ns() - t_cert) * 1e-9
            end
            do_augmentation = range_aug_requested &&
                              !(env_skip_aug || auto_skip_aug || cert_skip_aug)

            if !do_augmentation
                reason = !range_aug_requested ? "not_requested" :
                         (env_skip_aug ? "env_override" :
                          (auto_skip_aug ? "auto_brackets" : "certificate_complete"))
                log_msg("[BUCKLING] Skipping range-targeted shift-invert ($reason, $(length(range_idx)) in-range modes already)")
                diagnostics["range_augmentation"] = Dict{String,Any}(
                    "status" => "skipped",
                    "reason" => reason,
                    "requested" => range_aug_requested,
                    "in_range_modes_from_strategy2" => length(range_idx),
                )
                cert_gap_info !== nothing &&
                    (diagnostics["range_augmentation"]["certificate"] = cert_gap_info)
                buckling_timings["range_augmentation"] = cert_wall
            else
                t_aug_start = time_ns()
                aug_added = 0
                aug_result = "no_shifted_modes"
                aug_shift_count = 0
                aug_details = Any[]
                sigmas = range_augmentation_sigmas(valid_idx)
                for (isigma, sigma) in enumerate(sigmas)
                    shifted_modes = attempt_shifted_buckling_search(
                        sigma,
                        isigma == length(sigmas) && sigma == eigrl_v2 ?
                            "krylov_range_shifted" :
                            "krylov_range_shifted_mid",
                    )
                    shifted_modes === nothing && continue
                    aug_shift_count += 1
                    shifted_eigenvalues, shifted_eigenvectors = shifted_modes
                    # Match the main filter: positive-only by default, or signed
                    # magnitudes when explicitly requested for bounded ranges.
                    shifted_valid_idx = bounded_signed_magnitude_output ?
                        findall(x -> abs(x) > positive_tol, shifted_eigenvalues) :
                        findall(x -> x > positive_tol, shifted_eigenvalues)
                    shifted_range_idx = bounded_signed_magnitude_output ?
                        filter(i -> abs(shifted_eigenvalues[i]) >= max(eigrl_v1, positive_tol) && abs(shifted_eigenvalues[i]) <= v2_eff, shifted_valid_idx) :
                        filter(i -> shifted_eigenvalues[i] >= max(eigrl_v1, positive_tol) && shifted_eigenvalues[i] <= v2_eff, shifted_valid_idx)
                    if !isempty(shifted_range_idx)
                        shifted_vals = shifted_eigenvalues[shifted_range_idx]
                        shifted_vecs = shifted_eigenvectors[:, shifted_range_idx]
                        base_in_range = length(valid_idx)
                        if isempty(valid_idx)
                            eigenvalues = shifted_vals
                            eigenvectors = shifted_vecs
                            valid_idx = collect(eachindex(eigenvalues))
                            diagnostics["solver_backend"] = "krylov_range_shifted"
                            added = length(valid_idx)
                            aug_added += added
                            aug_result = "recovered_from_empty"
                            log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: recovered $(length(valid_idx)) in-range eigenvalues with targeted shift sigma=$sigma")
                        else
                            eigenvalues, eigenvectors, added = merge_unique_eigenpairs(
                                eigenvalues, eigenvectors, shifted_vals, shifted_vecs)
                            valid_idx = bounded_signed_magnitude_output ?
                                findall(x -> abs(x) > positive_tol && abs(x) >= max(eigrl_v1, positive_tol) && abs(x) <= v2_eff, eigenvalues) :
                                findall(x -> x > positive_tol && x >= max(eigrl_v1, positive_tol) && x <= v2_eff, eigenvalues)
                            aug_added += added
                            if added > 0
                                diagnostics["solver_backend"] = "$(diagnostics["solver_backend"])+range_shifted"
                                aug_result = "augmented"
                                log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: augmented in-range spectrum from $base_in_range to $(length(valid_idx)) modes with targeted shift sigma=$sigma")
                            elseif aug_result == "no_shifted_modes"
                                aug_result = "no_new_modes"
                                log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: targeted shift sigma=$sigma added no new in-range eigenvalues")
                            end
                        end
                        push!(aug_details, Dict(
                            "sigma" => sigma,
                            "shifted_in_range_modes" => length(shifted_range_idx),
                            "added_modes" => added,
                            "in_range_modes_after" => length(valid_idx),
                        ))
                    elseif isempty(valid_idx)
                        aug_result = "no_in_range_modes_found"
                        log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: targeted shift sigma=$sigma found no in-range eigenvalues, using all $(length(valid_idx))")
                    else
                        push!(aug_details, Dict(
                            "sigma" => sigma,
                            "shifted_in_range_modes" => 0,
                            "added_modes" => 0,
                            "in_range_modes_after" => length(valid_idx),
                        ))
                    end
                end
                if aug_shift_count == 0 && isempty(range_idx)
                    aug_result = "no_shifted_modes_empty_range"
                    log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: no eigenvalues in range, using all $(length(valid_idx))")
                end
                diagnostics["range_augmentation"] = Dict{String,Any}(
                    "status" => "ran",
                    "result" => aug_result,
                    "added_modes" => aug_added,
                    "sigmas" => sigmas,
                    "shift_count" => aug_shift_count,
                    "shifts" => aug_details,
                    "wall_seconds" => (time_ns() - t_aug_start) * 1e-9,
                )
                # When the certificate-first gate ran but could not certify
                # (gap > 0 or < ND recovered), record what it saw — the flag-ON
                # rescue path is the one place augmentation still pays.
                cert_gap_info !== nothing &&
                    (diagnostics["range_augmentation"]["pre_certificate"] = cert_gap_info)
                buckling_timings["range_augmentation"] =
                    diagnostics["range_augmentation"]["wall_seconds"]
            end
        end

        # (The Sturm cache and current_range_sturm_gap are defined above the
        # range augmentation so the certificate-first gate shares them; the
        # informational diagnostic further down is in a sibling scope and
        # carries its own local reuse Ref.)

        # If the iterative extraction is still missing roots below the highest
        # root it recovered, use the Sturm count as an honest completeness
        # certificate and increase the local shifted-solve budget. This is a
        # numerical recovery step only: it does not use case names, groups,
        # stresses, or reference answers, and it runs before any reporting cap.
        if !will_use_dense &&
           solver_env_bool("JFEM_SOL105_RANGE_COMPLETENESS_AUGMENT", true) &&
           !isempty(valid_idx)

            function range_completeness_sigmas(a_bound::Float64, b_bound::Float64, n_sigmas::Int)
                sigmas = Float64[b_bound]
                if n_sigmas > 1
                    for k in 1:(n_sigmas - 1)
                        sigma = a_bound + (b_bound - a_bound) * (k / n_sigmas)
                        push!(sigmas, sigma)
                    end
                end
                unique_sigmas = Float64[]
                for sigma in sigmas
                    if sigma < eigrl_v1 || sigma > v2_eff
                        continue
                    end
                    if isempty(unique_sigmas) ||
                       all(s -> abs(s - sigma) > max(1e-8, 1e-6 * max(abs(s), abs(sigma), 1.0)),
                           unique_sigmas)
                        push!(unique_sigmas, sigma)
                    end
                end
                return unique_sigmas
            end

            t_complete_start = time_ns()
            max_passes = max(solver_env_int("JFEM_SOL105_RANGE_COMPLETENESS_MAX_PASSES", 2), 0)
            max_shifts = max(solver_env_int("JFEM_SOL105_RANGE_COMPLETENESS_MAX_SHIFTS", 4), 1)
            completion_buffer = max(solver_env_int("JFEM_SOL105_RANGE_COMPLETENESS_BUFFER", 8), 0)
            completion_details = Any[]
            completion_status = "not_needed"
            completion_added = 0
            for pass in 1:max_passes
                gap_info = current_range_sturm_gap()
                if gap_info === nothing
                    completion_status = "sturm_unavailable"
                    break
                end
                gap = Int(get(gap_info, "gap", 0))
                if gap <= 0
                    completion_status = pass == 1 ? "already_complete" : "completed"
                    push!(completion_details, merge(gap_info, Dict{String,Any}(
                        "pass" => pass,
                        "status" => completion_status,
                    )))
                    break
                end
                interval = gap_info["interval"]
                a_bound = Float64(interval[1])
                b_bound = Float64(interval[2])
                expected = Int(get(gap_info, "sturm_eigs_in_interval", length(valid_idx)))
                request_override = min(max_modes, max(num_modes_request, expected + completion_buffer))
                sigmas = range_completeness_sigmas(
                    a_bound, b_bound, pass == 1 ? 1 : max_shifts)
                pass_added = 0
                for sigma in sigmas
                    shifted_modes = attempt_shifted_buckling_search(
                        sigma,
                        "krylov_range_completeness";
                        modes_request_override=request_override,
                        force_full_request=true,
                    )
                    shifted_modes === nothing && continue
                    shifted_eigenvalues, shifted_eigenvectors = shifted_modes
                        shifted_valid_idx = bounded_signed_magnitude_output ?
                            findall(x -> abs(x) > positive_tol, shifted_eigenvalues) :
                            findall(x -> x > positive_tol, shifted_eigenvalues)
                        shifted_range_idx = bounded_signed_magnitude_output ?
                            filter(i ->
                                abs(shifted_eigenvalues[i]) >= max(eigrl_v1, positive_tol) &&
                                abs(shifted_eigenvalues[i]) <= v2_eff,
                                shifted_valid_idx) :
                            filter(i ->
                                shifted_eigenvalues[i] >= max(eigrl_v1, positive_tol) &&
                                shifted_eigenvalues[i] <= v2_eff,
                                shifted_valid_idx)
                    isempty(shifted_range_idx) && continue
                    shifted_vals = shifted_eigenvalues[shifted_range_idx]
                    shifted_vecs = shifted_eigenvectors[:, shifted_range_idx]
                    if isempty(valid_idx)
                        eigenvalues = shifted_vals
                        eigenvectors = shifted_vecs
                        valid_idx = collect(eachindex(eigenvalues))
                        added = length(valid_idx)
                    else
                        eigenvalues, eigenvectors, added = merge_unique_eigenpairs(
                            eigenvalues, eigenvectors, shifted_vals, shifted_vecs)
                        valid_idx = bounded_signed_magnitude_output ?
                            findall(x ->
                                abs(x) > positive_tol &&
                                abs(x) >= max(eigrl_v1, positive_tol) &&
                                abs(x) <= v2_eff,
                                eigenvalues) :
                            findall(x ->
                                x > positive_tol &&
                                x >= max(eigrl_v1, positive_tol) &&
                                x <= v2_eff,
                                eigenvalues)
                    end
                    pass_added += added
                    completion_added += added
                    if added > 0
                        diagnostics["solver_backend"] =
                            "$(diagnostics["solver_backend"])+range_complete"
                        log_msg("[BUCKLING] EIGRL range [$eigrl_v1, $eigrl_v2]: Sturm recovery added $added mode(s) at sigma=$sigma ($(length(valid_idx)) in range)")
                    end
                end
                post_gap = current_range_sturm_gap()
                push!(completion_details, Dict{String,Any}(
                    "pass" => pass,
                    "pre" => gap_info,
                    "post" => post_gap,
                    "requested_modes_internal" => request_override,
                    "sigmas" => sigmas,
                    "added_modes" => pass_added,
                ))
                if post_gap !== nothing && Int(get(post_gap, "gap", 0)) <= 0
                    completion_status = "completed"
                    break
                elseif pass_added == 0
                    completion_status = "stalled"
                else
                    completion_status = "partial"
                end
            end
            diagnostics["range_completeness_augmentation"] = Dict{String,Any}(
                "status" => completion_status,
                "added_modes" => completion_added,
                "max_passes" => max_passes,
                "max_shifts" => max_shifts,
                "details" => completion_details,
                "wall_seconds" => (time_ns() - t_complete_start) * 1e-9,
            )
        end
    end

    # --- Sturm inertia diagnostic (iterative paths only) -------------------
    #
    # Reports the inertia (Sturm) count of the (K, -Kg) pencil over the band the
    # iterative solve recovered. The EXACT number of pencil eigenvalues in a
    # half-open interval (a, b] is the difference
    #     _buckling_sturm_count(K, Kg, b) - _buckling_sturm_count(K, Kg, a).
    # (See the helper's docstring — never compare a single absolute count.)
    #
    # This is INFORMATIONAL, not a pass/fail completeness verdict. The Sturm
    # difference counts every pencil eigenvalue in the band, including spurious
    # low-energy modes (drilling, localized mechanisms, near-singular DOFs) that
    # JFEM's localization & cluster filters deliberately drop, so the count is
    # PRE-filter while the reported spectrum is POST-filter — `pencil > reported`
    # is normal and does not indicate a missed physical mode. An earlier version
    # emitted a complete/incomplete verdict from this difference and consequently
    # cried "incomplete" on every realistic model; the verdict was removed.
    # The count is recorded for diagnostics / offline analysis.
    completeness_enabled = solver_env_bool("JFEM_SOL105_STURM_COMPLETENESS", false)
    # The Sturm count needs an indefinite inertia factorization of M(sigma) at two
    # shifts. For n <= 600 that is a dense eigvals; above that it is a sparse
    # CHOLMOD LDLᵀ, which is fast (≈1.5 s/shift at 60k DOF) now that the inertia is
    # read correctly via diag(F) — see _buckling_sturm_count. The DOF gate is now
    # only a safety valve for pathologically large models; above the ceiling we
    # record "skipped_too_large" rather than block the solve. Override with
    # JFEM_SOL105_STURM_MAX_DOF (default 200000; 0 = never skip on size).
    sturm_max_dof = max(solver_env_int("JFEM_SOL105_STURM_MAX_DOF", 200_000), 0)
    sturm_too_large = sturm_max_dof > 0 && n_free > sturm_max_dof
    if completeness_enabled && !will_use_dense && sturm_too_large && !isempty(valid_idx)
        diagnostics["sturm_completeness"] = Dict{String,Any}(
            "status" => "skipped_too_large",
            "n_free" => n_free,
            "sturm_max_dof" => sturm_max_dof,
        )
        log_msg("[BUCKLING][STURM] completeness check skipped: $n_free DOF exceeds JFEM_SOL105_STURM_MAX_DOF=$sturm_max_dof (sparse inertia factorization too costly). Set JFEM_SOL105_STURM_MAX_DOF=0 to force it.")
    end
    if completeness_enabled && !will_use_dense && !sturm_too_large && !isempty(valid_idx)
        t_sturm = time_ns()
        pos_tol_c = positive_tol
        # Interval to certify: "did the iterative solve skip any eigenvalue BELOW
        # the highest one it returned?" That is the genuine completeness question.
        # We certify (a_bound, max-found], NOT (V1, V2]: a SOL105 EIGRL commonly
        # carries a loose upper sentinel V2 (e.g. 1e8) while ND asks for only the
        # lowest few modes, so the full (V1,V2] window legitimately contains
        # hundreds of modes the solve was never asked to extract — counting those
        # as "missing" is a false alarm. The lower bound is V1 (clamped to +tol)
        # for a bounded range, else +tol.
        a_bound = has_range ? max(eigrl_v1, pos_tol_c) : pos_tol_c
        pos_vals = filter(x -> x > pos_tol_c, eigenvalues[valid_idx])
        b_bound = isempty(pos_vals) ? a_bound : maximum(pos_vals) * (1.0 + 1e-6)
        found_in_band = count(i -> begin
                v = eigenvalues[i]
                v > pos_tol_c && v >= a_bound - eps(Float64) && v <= b_bound + eps(Float64)
            end, valid_idx)
        if b_bound > a_bound
            # Local symbolic-reuse Ref (this block is outside the completeness
            # branch's scope): the second count reuses the first's analysis.
            sturm_info_reuse = Base.RefValue{Any}(nothing)
            sc_b = _buckling_sturm_count(K_ff, Kg_ff, b_bound; reuse=sturm_info_reuse)
            sc_a = _buckling_sturm_count(K_ff, Kg_ff, a_bound; reuse=sturm_info_reuse)
            if sc_a !== nothing && sc_b !== nothing
                expected = sc_b - sc_a
                gap = expected - found_in_band
                # IMPORTANT — this is an INFORMATIONAL inertia count, not a
                # pass/fail verdict. The Sturm difference counts EVERY eigenvalue
                # of the (K, -Kg) pencil in (a, b], including spurious low-energy
                # modes (drilling / localized mechanisms / near-singular DOFs the
                # eigen partition leaves in) that JFEM's localization & cluster
                # filters intentionally DROP from the reported spectrum. So
                # `expected` is a PRE-filter count while `found_in_band` is
                # POST-filter; `expected > found` is the normal, correct case and
                # does NOT mean the iterative solve missed a physical mode. There
                # is no reliable way at this layer to separate "Krylov skipped a
                # mode" from "a filter removed a spurious mode", so we record the
                # counts for diagnostics and do not emit a complete/incomplete
                # verdict. (The earlier verdict cried "incomplete" on every real
                # model for exactly this reason.)
                diagnostics["sturm_completeness"] = Dict{String,Any}(
                    "status" => "informational",
                    "interval" => [a_bound, b_bound],
                    "sturm_eigs_in_interval" => expected,
                    "recovered_in_interval" => found_in_band,
                    "sturm_minus_recovered" => gap,
                    "sturm_lower" => sc_a,
                    "sturm_upper" => sc_b,
                    "wall_seconds" => (time_ns() - t_sturm) * 1e-9,
                )
                log_msg("[BUCKLING][STURM] inertia: $expected pencil eigenvalue(s) in ($a_bound, $b_bound], $found_in_band recovered before output filters.")
            else
                diagnostics["sturm_completeness"] = Dict{String,Any}(
                    "status" => "unavailable",
                    "reason" => "inertia_count_failed",
                )
                log_msg("[BUCKLING][STURM] inertia count unavailable; proceeding.")
            end
        end
        buckling_timings["sturm_completeness"] = (time_ns() - t_sturm) * 1e-9
    end

    # Sort by lambda ascending — Nastran's root order. Never by |lambda|.
    sorted_idx = valid_idx[sortperm(eigenvalues[valid_idx])]

    # 2026-07-27 (strip Stage 1): the localization filter and its rescue windows are GONE.
    # It discarded eigenvalues whose elastic strain energy was concentrated in few elements
    # (top-element share > 12 %, top-10 share > 40 %) and then re-admitted specific ones via
    # three descriptor windows keyed on ply_count == 9 / == 11 with h/L bands 0.0003 wide —
    # i.e. deck fingerprints deciding which eigenvalue is reported as mode 1. Nastran applies
    # no such test. Measured: with the filter ON, 6 of 42 corpus decks were MISSING a Nastran
    # mode; with it OFF, 1. The filter introduced to fix mode selection WAS the defect.
    # Removed here: ~887 lines of thresholds, keep/reject windows and energy-share
    # machinery. The spectrum is now reported as found: see `sorted_idx` above.

    # By default, honor EIGRL ND even when V1/V2 is present. Range augmentation
    # may discover many more in-range roots than MSC reports for an ND-limited
    # deck; returning all of them is useful for completeness diagnostics but
    # makes first-N parity and exported mode numbering drift away from Nastran.
    #
    # Opt in to the expanded diagnostic output with
    # JFEM_SOL105_RETURN_ALL_IN_RANGE=true. The hard cap avoids accidentally
    # exporting a huge mode set from a broad range.
    if has_range
        if return_all_range
            cap_raw = strip(get(ENV, "JFEM_SOL105_RETURN_ALL_IN_RANGE_MAX", "256"))
            cap = tryparse(Int, cap_raw)
            cap = cap === nothing ? 256 : clamp(cap, 1, max(length(sorted_idx), 1))
            n_out = min(length(sorted_idx), cap)
            diagnostics["range_output"] = Dict{String,Any}(
                "mode" => "all_in_range",
                "available_in_range_modes" => length(sorted_idx),
                "cap" => cap,
            )
        else
            n_out = min(num_modes, length(sorted_idx))
            diagnostics["range_output"] = Dict{String,Any}(
                "mode" => "eigrl_nd",
                "available_in_range_modes" => length(sorted_idx),
                "requested_modes" => num_modes,
            )
        end
    else
        n_out = min(num_modes_request, length(sorted_idx))
    end
    if n_out == 0
        log_msg("[BUCKLING] WARNING: No valid eigenvalues found")
        diagnostics["solver_backend"] = "no_valid_modes"
        buckling_timings["postprocess_filter_expand"] = (time_ns() - t_postprocess) * 1e-9
        buckling_timings["total"] = (time_ns() - t_buckling_total) * 1e-9
        diagnostics["timings"] = buckling_timings
        return return_diagnostics ? (Float64[], zeros(ndof, 0), diagnostics) : (Float64[], zeros(ndof, 0))
    end

    # 2026-07-27 (strip Stage 1): the spectral-gap CLUSTER FILTER is GONE. It skipped low
    # modes ahead of a detected eigenvalue gap so that a denser higher cluster would be
    # reported instead — another rule choosing which eigenvalue is mode 1, with no counterpart
    # in Nastran, which returns the roots its Lanczos finds in the EIGRL range. Removed with it:
    # the 11 CLUSTER_FILTER_* thresholds and the n_skip re-cap branch.
    output_sorted_idx = sorted_idx[1:n_out]

    final_eigenvalues = bounded_signed_magnitude_output ?
        abs.(eigenvalues[output_sorted_idx]) :
        eigenvalues[output_sorted_idx]
    final_eigenvectors = eigenvectors[:, output_sorted_idx]

    # Expand to full DOF set
    t_expand_modes = time_ns()
    mode_shapes = zeros(ndof, n_out)
    for m in 1:n_out
        mode_shapes[free_dofs, m] = final_eigenvectors[:, m]
    end

    # Recover RBE3 dependent DOFs
    for (dep_dof, pairs) in rbe3_map
        for m in 1:n_out
            u_avg = 0.0
            for (ind_dof, coeff) in pairs
                u_avg += coeff * mode_shapes[ind_dof, m]
            end
            mode_shapes[dep_dof, m] = u_avg
        end
    end

    # Transform mode shapes to global coordinates via node_R
    mode_shapes_global = zeros(ndof, n_out)
    sorted_nodes = sort(collect(keys(id_map)))
    for nid in sorted_nodes
        idx = id_map[nid]; base = (idx-1)*6
        R = node_R[idx]
        for m in 1:n_out
            u1 = mode_shapes[base + 1, m]
            u2 = mode_shapes[base + 2, m]
            u3 = mode_shapes[base + 3, m]
            r1 = mode_shapes[base + 4, m]
            r2 = mode_shapes[base + 5, m]
            r3 = mode_shapes[base + 6, m]
            mode_shapes_global[base + 1, m] = R[1, 1] * u1 + R[1, 2] * u2 + R[1, 3] * u3
            mode_shapes_global[base + 2, m] = R[2, 1] * u1 + R[2, 2] * u2 + R[2, 3] * u3
            mode_shapes_global[base + 3, m] = R[3, 1] * u1 + R[3, 2] * u2 + R[3, 3] * u3
            mode_shapes_global[base + 4, m] = R[1, 1] * r1 + R[1, 2] * r2 + R[1, 3] * r3
            mode_shapes_global[base + 5, m] = R[2, 1] * r1 + R[2, 2] * r2 + R[2, 3] * r3
            mode_shapes_global[base + 6, m] = R[3, 1] * r1 + R[3, 2] * r2 + R[3, 3] * r3
        end
    end

    # Normalize mode shapes (max component = 1.0)
    for m in 1:n_out
        max_val = maximum(abs.(mode_shapes_global[:, m]))
        if max_val > 1e-30
            mode_shapes_global[:, m] ./= max_val
        end
    end
    buckling_timings["expand_modes"] = (time_ns() - t_expand_modes) * 1e-9

    log_msg("[BUCKLING] Eigenvalues (buckling load factors):")
    for (i, lam) in enumerate(final_eigenvalues)
        log_msg("  Mode $i: lambda = $(round(lam, digits=6))")
    end

    diagnostics["returned_modes"] = n_out

    # Phase A2 (architectural-cleanup 2026-05-24): expose the pre-filter
    # eigenvalue set + per-mode filter decisions to the caller via the
    # diagnostics dict. Cheap (eigenvalues only — no expansion). The caller
    # (`_solve_sol105`) lifts these into BucklingSubcaseResult.raw_eigenvalues
    # / .filter_decisions so off-line MAC analysis can see what the filters
    # dropped without re-running with JFEM_BUCKLING_RAW_OUTPUT=true.
    #
    # raw_eigenvalues is in ASCENDING order over sorted_idx (the validity-
    # passed eigenspectrum the post-filter selection runs against).
    # filter_decisions[i] is the verdict for raw_eigenvalues[i]:
    #   :kept  — eigenvalue made it into final_eigenvalues
    #   :dropped — eigenvalue was filtered (localization, cluster, range, or num_modes cap)
    raw_eigenvalues = Float64.(eigenvalues[sorted_idx])
    kept_set = Set{Int}(output_sorted_idx)
    filter_decisions = [idx in kept_set ? :kept : :dropped for idx in sorted_idx]
    diagnostics["raw_eigenvalues"] = raw_eigenvalues
    diagnostics["filter_decisions"] = filter_decisions
    diagnostics["raw_to_sorted_index"] = collect(sorted_idx)
    diagnostics["kept_indices_in_sorted"] = [findfirst(==(i), sorted_idx) for i in output_sorted_idx]

    buckling_timings["postprocess_filter_expand"] = (time_ns() - t_postprocess) * 1e-9
    buckling_timings["total"] = (time_ns() - t_buckling_total) * 1e-9
    diagnostics["timings"] = buckling_timings
    return return_diagnostics ? (final_eigenvalues, mode_shapes_global, diagnostics) : (final_eigenvalues, mode_shapes_global)
end

# =============================================================================
# SOL103 MASS MATRIX ASSEMBLY
# =============================================================================
@inline function _sol103_param_enabled(raw, default::Bool)
    if raw isa AbstractString
        token = uppercase(strip(raw))
        isempty(token) && return default
        return !(token in ("NO", "N", "FALSE", "F", "OFF", "0", "NONE"))
    elseif raw isa Number
        return abs(Float64(raw)) > 1e-12
    elseif raw === nothing
        return default
    end
    return Bool(raw)
end

@inline function sol103_shell_mass_formulation(model)
    if haskey(ENV, "JFEM_SOL103_SHELL_MASS")
        raw = lowercase(strip(ENV["JFEM_SOL103_SHELL_MASS"]))
        if raw in ("consistent", "coupled", "coupmass", "full")
            return :coupled_consistent
        elseif raw in ("lumped", "nastran", "nastran_lumped", "diagonal", "default")
            return :nastran_lumped
        else
            @warn "Ignoring unknown JFEM_SOL103_SHELL_MASS value; using Nastran lumped shell mass" value=ENV["JFEM_SOL103_SHELL_MASS"]
            return :nastran_lumped
        end
    end
    if haskey(model, "PARAM_COUPMASS")
        return _sol103_param_enabled(get(model, "PARAM_COUPMASS", false), false) ?
            :coupled_consistent : :nastran_lumped
    end
    # 2026-08-05 de-calibration: the reference solver's cardless default is
    # lumped mass (PARAM,COUPMASS,-1). The previous coupled-consistent cardless
    # default silently diverged from both the reference and from JFEM's own
    # explicit COUPMASS handling above; on cardless single-element SOL 103
    # probes it inflated first shell modes by +18..+19% (registry-corpus run
    # CORPUS_REGISTRY_PARITY_2026_08_05). Forcing lumped reproduces the
    # reference first modes to full F06 print precision.
    return solver_env_bool("JFEM_SOL103_SHELL_COUPLED_MASS_DEFAULT", false) ?
        :coupled_consistent : :nastran_lumped
end

@inline function sol103_shell_mass_formulation_name(model)
    return string(sol103_shell_mass_formulation(model))
end

function assemble_mass(model, id_map, node_coords, node_R, ndof)
    log_msg("[SOLVER] Assembling Mass Matrix (SOL103)...")
    n_nodes = length(id_map)
    max_nid = maximum(keys(id_map))
    id_vec = zeros(Int, max_nid)
    for (nid, idx) in id_map; id_vec[nid] = idx; end

    # Flat node_R for transformation
    node_R_flat = zeros(3, 3, n_nodes)
    for i in 1:n_nodes
        for r in 1:3, c in 1:3; node_R_flat[r,c,i] = node_R[i][r,c]; end
    end

    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()

    pshells = model["PSHELLs"]; mats = model["MATs"]
    pbarls = get(model, "PBARLs", Dict())
    prods = get(model, "PRODs", Dict())
    cshells = model["CSHELLs"]; cbars = model["CBARs"]
    cbeams = get(model, "CBEAMs", Dict()); crods = model["CRODs"]
    conrods = get(model, "CONRODs", Dict())
    csolids = get(model, "CSOLIDs", Dict())
    psolids = get(model, "PSOLIDs", Dict())
    conm2s = get(model, "CONM2s", Dict())

    T_buf = zeros(24, 24)
    Me_global = zeros(24, 24)
    tmp24 = zeros(24, 24)
    dofs_buf24 = Vector{Int}(undef, 24)
    lc_buf4 = zeros(4, 2)
    coords_buf_solid = zeros(8, 3)
    T_buf_solid = zeros(24, 24)
    dofs_buf_solid = Vector{Int}(undef, 24)
    shell_mass_formulation = sol103_shell_mass_formulation(model)
    log_msg("[SOLVER] SOL103 shell mass formulation: $(shell_mass_formulation)")

    # --- Shell elements ---
    for (_, el) in cshells
        pid = string(el["PID"])
        !haskey(pshells, pid) && continue
        prop = pshells[pid]; mid = string(prop["MID"])
        !haskey(mats, mid) && continue
        nids = el["NODES"]; n = length(nids)
        mat = _effective_mat1_for_nodes(model, mid, nids)
        h = Float64(prop["T"])
        rho = Float64(get(mat, "RHO", 0.0))
        nsm = Float64(get(prop, "NSM", 0.0))  # non-structural mass per unit area
        # Skip if no mass source at all
        (rho < 1e-30 && nsm < 1e-30) && continue
        # Effective mass/area = rho*h + NSM. Pass equivalent rho to kernel: rho_eff = (rho*h + NSM)/h
        rho_eff = h > 1e-30 ? (rho * h + nsm) / h : rho

        valid = true
        for k in 1:n
            nid = nids[k]
            (nid < 1 || nid > max_nid || id_vec[nid] == 0) && (valid = false; break)
        end
        !valid && continue

        if n == 4
            i1,i2,i3,i4 = id_vec[nids[1]], id_vec[nids[2]], id_vec[nids[3]], id_vec[nids[4]]
            p1 = SVector{3}(node_coords[i1,:])
            p2 = SVector{3}(node_coords[i2,:])
            p3 = SVector{3}(node_coords[i3,:])
            p4 = SVector{3}(node_coords[i4,:])
            v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, :bisect)
            Rel_t = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]

            c_ctr = (p1+p2+p3+p4)/4.0
            for k in 1:4
                pk = k==1 ? p1 : k==2 ? p2 : k==3 ? p3 : p4
                lc_buf4[k,1] = dot(pk-c_ctr, v1); lc_buf4[k,2] = dot(pk-c_ctr, v2)
            end

            Me_loc = shell_mass_formulation === :coupled_consistent ?
                FEM.consistent_mass_quad4(lc_buf4, rho_eff, h) :
                FEM.nastran_lumped_mass_quad4(lc_buf4, rho_eff, h)

            # Build T (24×24)
            fill!(T_buf, 0.0)
            for k in 1:4
                idx = k==1 ? i1 : k==2 ? i2 : k==3 ? i3 : i4
                base = (k-1)*6
                TR = Rel_t * node_R[idx]
                for rr in 1:3, cc in 1:3
                    T_buf[base+rr, base+cc] = TR[rr,cc]
                    T_buf[base+3+rr, base+3+cc] = TR[rr,cc]
                end
            end

            # Me_global = T' * Me_loc * T
            fill!(Me_global, 0.0); fill!(tmp24, 0.0)
            @inbounds for jj in 1:24, ll in 1:24
                val = T_buf[ll, jj]
                val == 0.0 && continue
                for ii in 1:24; tmp24[ii, jj] += Me_loc[ii, ll] * val; end
            end
            @inbounds for jj in 1:24, ll in 1:24
                val = tmp24[ll, jj]
                val == 0.0 && continue
                for ii in 1:24; Me_global[ii, jj] += T_buf[ll, ii] * val; end
            end

            for k in 1:4
                idx = k==1 ? i1 : k==2 ? i2 : k==3 ? i3 : i4
                b = (idx-1)*6
                for d in 1:6; dofs_buf24[(k-1)*6+d] = b+d; end
            end
            for c in 1:24, r in 1:24
                push!(I_idx, dofs_buf24[r]); push!(J_idx, dofs_buf24[c]); push!(V_val, Me_global[r,c])
            end

        elseif n == 3
            i1,i2,i3 = id_vec[nids[1]], id_vec[nids[2]], id_vec[nids[3]]
            p1 = SVector{3}(node_coords[i1,:])
            p2 = SVector{3}(node_coords[i2,:])
            p3 = SVector{3}(node_coords[i3,:])
            v1, v2, v3 = shell_element_frame_fast(p1, p2, p3, p3, 3)
            Rel_t = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]

            c_ctr = (p1+p2+p3)/3.0
            lc3 = zeros(3,2)
            for k in 1:3
                pk = k==1 ? p1 : k==2 ? p2 : p3
                lc3[k,1] = dot(pk-c_ctr, v1); lc3[k,2] = dot(pk-c_ctr, v2)
            end

            Me_loc = shell_mass_formulation === :coupled_consistent ?
                FEM.consistent_mass_tria3(lc3, rho_eff, h) :
                FEM.nastran_lumped_mass_tria3(lc3, rho_eff, h)

            T18 = zeros(18, 18)
            for k in 1:3
                idx = k==1 ? i1 : k==2 ? i2 : i3
                base = (k-1)*6
                TR = Rel_t * node_R[idx]
                for rr in 1:3, cc in 1:3
                    T18[base+rr, base+cc] = TR[rr,cc]
                    T18[base+3+rr, base+3+cc] = TR[rr,cc]
                end
            end
            Me18 = T18' * Me_loc * T18

            dofs_t3 = Vector{Int}(undef, 18)
            for k in 1:3
                idx = k==1 ? i1 : k==2 ? i2 : i3
                b = (idx-1)*6
                for d in 1:6; dofs_t3[(k-1)*6+d] = b+d; end
            end
            for c in 1:18, r in 1:18
                push!(I_idx, dofs_t3[r]); push!(J_idx, dofs_t3[c]); push!(V_val, Me18[r,c])
            end
        end
    end

    # --- CBAR elements ---
    for (_, bar) in cbars
        ga, gb = bar["GA"], bar["GB"]
        (!haskey(id_map, ga) || !haskey(id_map, gb)) && continue
        i1, i2 = id_map[ga], id_map[gb]
        pid = string(bar["PID"])
        !haskey(pbarls, pid) && continue
        prop = pbarls[pid]; mid = string(prop["MID"])
        !haskey(mats, mid) && continue
        mat = _effective_mat1_for_nodes(model, mid, [ga, gb])
        rho = Float64(get(mat, "RHO", 0.0))
        nsm_bar = Float64(get(prop, "NSM", 0.0))  # non-structural mass per unit length
        (rho < 1e-30 && nsm_bar < 1e-30) && continue

        p1 = SVector{3}(node_coords[i1,:]); p2 = SVector{3}(node_coords[i2,:])
        L = norm(p2 - p1)
        L < 1e-12 && continue

        A_bar = Float64(get(prop, "A", 0.0))
        Iy = Float64(get(prop, "I2", get(prop, "Iy", 0.0)))
        Iz = Float64(get(prop, "I1", get(prop, "Iz", 0.0)))
        J = Float64(get(prop, "J", 0.0))

        # Effective density: rho_eff = rho + NSM/A (NSM is mass per unit length)
        rho_bar = A_bar > 1e-30 ? rho + nsm_bar / A_bar : rho
        Me_loc = FEM.nastran_lumped_mass_frame3d(L, rho_bar, A_bar, J, Iy, Iz)

        # Transformation
        e1 = (p2 - p1) / L
        vbar = haskey(bar, "V") ? SVector{3}(Float64.(bar["V"])) : SVector(0.0, 0.0, 1.0)
        e2_raw = vbar - dot(vbar, e1)*e1
        e2_len = norm(e2_raw)
        e2 = e2_len > 1e-12 ? e2_raw/e2_len : SVector(0.0, 1.0, 0.0)
        e3 = cross(e1, e2)
        Rel_t = @SMatrix [e1[1] e1[2] e1[3]; e2[1] e2[2] e2[3]; e3[1] e3[2] e3[3]]

        T12 = zeros(12, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            base = (k-1)*6
            TR = Rel_t * node_R[idx]
            for rr in 1:3, cc in 1:3
                T12[base+rr, base+cc] = TR[rr,cc]
                T12[base+3+rr, base+3+cc] = TR[rr,cc]
            end
        end
        Me12 = T12' * Me_loc * T12

        dofs12 = Vector{Int}(undef, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            b = (idx-1)*6
            for d in 1:6; dofs12[(k-1)*6+d] = b+d; end
        end
        for c in 1:12, r in 1:12
            push!(I_idx, dofs12[r]); push!(J_idx, dofs12[c]); push!(V_val, Me12[r,c])
        end
    end

    # --- CROD elements ---
    for (_, rod) in crods
        ga, gb = rod["GA"], rod["GB"]
        (!haskey(id_map, ga) || !haskey(id_map, gb)) && continue
        i1, i2 = id_map[ga], id_map[gb]
        pid = string(rod["PID"])
        !haskey(prods, pid) && continue
        prop = prods[pid]; mid = string(prop["MID"])
        !haskey(mats, mid) && continue
        mat = _effective_mat1_for_nodes(model, mid, [ga, gb])
        rho = Float64(get(mat, "RHO", 0.0))
        nsm_rod = Float64(get(prop, "NSM", 0.0))  # non-structural mass per unit length
        (rho < 1e-30 && nsm_rod < 1e-30) && continue

        p1 = SVector{3}(node_coords[i1,:]); p2 = SVector{3}(node_coords[i2,:])
        L = norm(p2 - p1)
        L < 1e-12 && continue
        A_rod = Float64(get(prop, "A", 0.0))
        J_rod = Float64(get(prop, "J", 0.0))

        # Effective density: rho_eff = rho + NSM/A
        rho_rod = A_rod > 1e-30 ? rho + nsm_rod / A_rod : rho
        Me_loc = FEM.nastran_lumped_mass_rod(L, rho_rod, A_rod, J_rod)

        e1 = (p2 - p1) / L
        e2 = abs(e1[3]) < 0.9 ? normalize(cross(e1, SVector(0.0,0.0,1.0))) : normalize(cross(e1, SVector(1.0,0.0,0.0)))
        e3 = cross(e1, e2)
        Rel_t = @SMatrix [e1[1] e1[2] e1[3]; e2[1] e2[2] e2[3]; e3[1] e3[2] e3[3]]

        T12 = zeros(12, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            base = (k-1)*6
            TR = Rel_t * node_R[idx]
            for rr in 1:3, cc in 1:3
                T12[base+rr, base+cc] = TR[rr,cc]
                T12[base+3+rr, base+3+cc] = TR[rr,cc]
            end
        end
        Me12 = T12' * Me_loc * T12

        dofs12 = Vector{Int}(undef, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            b = (idx-1)*6
            for d in 1:6; dofs12[(k-1)*6+d] = b+d; end
        end
        for c in 1:12, r in 1:12
            push!(I_idx, dofs12[r]); push!(J_idx, dofs12[c]); push!(V_val, Me12[r,c])
        end
    end

    # --- CONROD elements (rod with integrated properties, no PROD card) ---
    for (_, rod) in conrods
        ga, gb = rod["GA"], rod["GB"]
        (!haskey(id_map, ga) || !haskey(id_map, gb)) && continue
        i1, i2 = id_map[ga], id_map[gb]

        mid = string(rod["MID"])
        !haskey(mats, mid) && continue
        mat = _effective_mat1_for_nodes(model, mid, [ga, gb])
        rho = Float64(get(mat, "RHO", 0.0))
        rho < 1e-30 && continue

        p1 = SVector{3}(node_coords[i1,:]); p2 = SVector{3}(node_coords[i2,:])
        L = norm(p2 - p1)
        L < 1e-12 && continue
        A_rod = Float64(get(rod, "A", 0.0))

        # Add non-structural mass (NSM) per unit length
        nsm = Float64(get(rod, "NSM", 0.0))

        J_rod = Float64(get(rod, "J", 0.0))
        Me_loc = FEM.nastran_lumped_mass_rod(L, rho, A_rod, J_rod)

        # Add NSM contribution (lumped at both ends, translational only)
        if nsm > 0
            nsm_total = nsm * L
            for d in [1, 2, 3]
                Me_loc[d, d] += nsm_total / 2.0
                Me_loc[6+d, 6+d] += nsm_total / 2.0
            end
        end

        e1 = (p2 - p1) / L
        e2 = abs(e1[3]) < 0.9 ? normalize(cross(e1, SVector(0.0,0.0,1.0))) : normalize(cross(e1, SVector(1.0,0.0,0.0)))
        e3 = cross(e1, e2)
        Rel_t = @SMatrix [e1[1] e1[2] e1[3]; e2[1] e2[2] e2[3]; e3[1] e3[2] e3[3]]

        T12 = zeros(12, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            base = (k-1)*6
            TR = Rel_t * node_R[idx]
            for rr in 1:3, cc in 1:3
                T12[base+rr, base+cc] = TR[rr,cc]
                T12[base+3+rr, base+3+cc] = TR[rr,cc]
            end
        end
        Me12 = T12' * Me_loc * T12

        dofs12 = Vector{Int}(undef, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            b = (idx-1)*6
            for d in 1:6; dofs12[(k-1)*6+d] = b+d; end
        end
        for c in 1:12, r in 1:12
            push!(I_idx, dofs12[r]); push!(J_idx, dofs12[c]); push!(V_val, Me12[r,c])
        end
    end

    # --- CBEAM elements (same mass formulation as CBAR) ---
    for (_, beam) in cbeams
        ga, gb = beam["GA"], beam["GB"]
        (!haskey(id_map, ga) || !haskey(id_map, gb)) && continue
        i1, i2 = id_map[ga], id_map[gb]
        pid = string(beam["PID"])
        !haskey(pbarls, pid) && continue
        prop = pbarls[pid]; mid = string(prop["MID"])
        !haskey(mats, mid) && continue
        mat = _effective_mat1_for_nodes(model, mid, [ga, gb])
        rho = Float64(get(mat, "RHO", 0.0))
        nsm_beam = Float64(get(prop, "NSM", 0.0))
        (rho < 1e-30 && nsm_beam < 1e-30) && continue

        p1 = SVector{3}(node_coords[i1,:]); p2 = SVector{3}(node_coords[i2,:])
        L = norm(p2 - p1)
        L < 1e-12 && continue

        A_beam = Float64(get(prop, "A", 0.0))
        Iy = Float64(get(prop, "I2", get(prop, "Iy", 0.0)))
        Iz = Float64(get(prop, "I1", get(prop, "Iz", 0.0)))
        J = Float64(get(prop, "J", 0.0))

        # Effective density including NSM
        rho_beam = A_beam > 1e-30 ? rho + nsm_beam / A_beam : rho
        # CBEAM lumped mass includes torsional inertia, unlike CBAR -- the
        # two elements' reference spectra prove their respective conventions.
        Me_loc = FEM.nastran_lumped_mass_frame3d(L, rho_beam, A_beam, J, Iy, Iz;
                                                 torsion_inertia=true)

        # Transformation
        e1 = (p2 - p1) / L
        vbar = haskey(beam, "V") ? SVector{3}(Float64.(beam["V"])) : SVector(0.0, 0.0, 1.0)
        e2_raw = vbar - dot(vbar, e1)*e1
        e2_len = norm(e2_raw)
        e2 = e2_len > 1e-12 ? e2_raw/e2_len : SVector(0.0, 1.0, 0.0)
        e3 = cross(e1, e2)
        Rel_t = @SMatrix [e1[1] e1[2] e1[3]; e2[1] e2[2] e2[3]; e3[1] e3[2] e3[3]]

        T12 = zeros(12, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            base = (k-1)*6
            TR = Rel_t * node_R[idx]
            for rr in 1:3, cc in 1:3
                T12[base+rr, base+cc] = TR[rr,cc]
                T12[base+3+rr, base+3+cc] = TR[rr,cc]
            end
        end
        Me12 = T12' * Me_loc * T12

        dofs12 = Vector{Int}(undef, 12)
        for k in 1:2
            idx = k==1 ? i1 : i2
            b = (idx-1)*6
            for d in 1:6; dofs12[(k-1)*6+d] = b+d; end
        end
        for c in 1:12, r in 1:12
            push!(I_idx, dofs12[r]); push!(J_idx, dofs12[c]); push!(V_val, Me12[r,c])
        end
    end

    # --- SOLID elements ---
    for (_, el) in csolids
        pid = string(el["PID"])
        !haskey(psolids, pid) && continue
        prop = psolids[pid]
        mid = string(prop["MID"])
        !haskey(mats, mid) && continue

        nids = el["NODES"]
        nn = length(nids)
        etype = get(el, "TYPE", "")
        mat = _effective_mat1_for_nodes(model, mid, nids)
        rho = Float64(get(mat, "RHO", 0.0))
        rho < 1e-30 && continue

        valid = true
        for k in 1:nn
            nid = nids[k]
            if !haskey(id_map, nid)
                valid = false
                break
            end
        end
        !valid && continue

        for k in 1:nn
            idx = id_map[nids[k]]
            coords_buf_solid[k,1] = node_coords[idx,1]
            coords_buf_solid[k,2] = node_coords[idx,2]
            coords_buf_solid[k,3] = node_coords[idx,3]
        end

        local Me_loc
        local ndof_el::Int
        if etype == "CTETRA" && nn == 4
            Me_loc = FEM.nastran_lumped_mass_tetra4(view(coords_buf_solid, 1:4, :), rho)
            ndof_el = 12
        elseif etype == "CHEXA" && nn == 8
            Me_loc = FEM.nastran_lumped_mass_hexa8(view(coords_buf_solid, 1:8, :), rho)
            ndof_el = 24
        elseif etype == "CPENTA" && nn == 6
            Me_loc = FEM.nastran_lumped_mass_cpenta6(view(coords_buf_solid, 1:6, :), rho)
            ndof_el = 18
        else
            continue
        end

        fill!(view(T_buf_solid, 1:ndof_el, 1:ndof_el), 0.0)
        for k in 1:nn
            idx = id_map[nids[k]]
            base = (k - 1) * 3
            TR = node_R[idx]
            for rr in 1:3, cc in 1:3
                T_buf_solid[base + rr, base + cc] = TR[rr, cc]
            end
        end
        T_sub = view(T_buf_solid, 1:ndof_el, 1:ndof_el)
        Me = T_sub' * Me_loc * T_sub

        for k in 1:nn
            idx = id_map[nids[k]]
            base = (idx - 1) * 6
            dofs_buf_solid[(k - 1) * 3 + 1] = base + 1
            dofs_buf_solid[(k - 1) * 3 + 2] = base + 2
            dofs_buf_solid[(k - 1) * 3 + 3] = base + 3
        end

        for c in 1:ndof_el, r in 1:ndof_el
            push!(I_idx, dofs_buf_solid[r]); push!(J_idx, dofs_buf_solid[c]); push!(V_val, Me[r,c])
        end
    end

    # --- CONM2 concentrated mass ---
    for (_, cm) in conm2s
        gid = cm["GID"]
        !haskey(id_map, gid) && continue
        idx = id_map[gid]
        m = Float64(cm["M"])
        m < 1e-30 && continue
        base = (idx-1)*6

        # CONM2 offset vector (X1, X2, X3) in basic coordinate system
        x_off = get(cm, "X", [0.0, 0.0, 0.0])
        x1, x2, x3 = Float64(x_off[1]), Float64(x_off[2]), Float64(x_off[3])
        has_offset = (abs(x1) + abs(x2) + abs(x3)) > 1e-30

        # Translational mass (diagonal 3×3)
        for d in 1:3
            push!(I_idx, base+d); push!(J_idx, base+d); push!(V_val, m)
        end

        # Rotational inertia (if provided)
        inertia = get(cm, "I", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        I11, I21, I22, I31, I32, I33 = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
        if length(inertia) >= 6
            I11, I21, I22, I31, I32, I33 = Float64.(inertia)
        end

        # Parallel axis theorem: transfer inertia from CG offset to grid point
        # I_total = I_cg + m * [y²+z², -xy, -xz; -xy, x²+z², -yz; -xz, -yz, x²+y²]
        if has_offset
            I11 += m * (x2^2 + x3^2)
            I22 += m * (x1^2 + x3^2)
            I33 += m * (x1^2 + x2^2)
            I21 -= m * x1 * x2
            I31 -= m * x1 * x3
            I32 -= m * x2 * x3
        end

        # Diagonal rotational inertia
        if abs(I11) > 0; push!(I_idx, base+4); push!(J_idx, base+4); push!(V_val, I11); end
        if abs(I22) > 0; push!(I_idx, base+5); push!(J_idx, base+5); push!(V_val, I22); end
        if abs(I33) > 0; push!(I_idx, base+6); push!(J_idx, base+6); push!(V_val, I33); end

        # Off-diagonal rotational inertia (symmetric)
        if abs(I21) > 0
            push!(I_idx, base+4); push!(J_idx, base+5); push!(V_val, I21)
            push!(I_idx, base+5); push!(J_idx, base+4); push!(V_val, I21)
        end
        if abs(I31) > 0
            push!(I_idx, base+4); push!(J_idx, base+6); push!(V_val, I31)
            push!(I_idx, base+6); push!(J_idx, base+4); push!(V_val, I31)
        end
        if abs(I32) > 0
            push!(I_idx, base+5); push!(J_idx, base+6); push!(V_val, I32)
            push!(I_idx, base+6); push!(J_idx, base+5); push!(V_val, I32)
        end

        # Translation-rotation coupling from offset (Nastran CONM2 formulation)
        # Couples translational DOFs to rotational DOFs via mass × offset
        if has_offset
            # M_tr = m * [0, z, -y; -z, 0, x; y, -x, 0]  (skew-symmetric)
            coupling = [( 0.0,    m*x3,  -m*x2),   # row 4 couples to DOFs 1,2,3
                        (-m*x3,   0.0,    m*x1),   # row 5
                        ( m*x2,  -m*x1,   0.0 )]   # row 6
            for r in 1:3
                for c in 1:3
                    val = coupling[r][c]
                    abs(val) < 1e-30 && continue
                    push!(I_idx, base+3+r); push!(J_idx, base+c); push!(V_val, val)
                    push!(I_idx, base+c); push!(J_idx, base+3+r); push!(V_val, val)
                end
            end
        end
    end

    # --- CONM1 concentrated mass (full 6×6 diagonal mass matrix) ---
    conm1s = get(model, "CONM1s", Dict())
    for (_, cm) in conm1s
        gid = cm["GID"]
        !haskey(id_map, gid) && continue
        idx = id_map[gid]
        base = (idx-1)*6
        raw_full = get(cm, "M_FULL", nothing)
        if raw_full === nothing
            m_diag = get(cm, "M_DIAG", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
            for d in 1:min(6, length(m_diag))
                if abs(m_diag[d]) > 1e-30
                    push!(I_idx, base+d); push!(J_idx, base+d); push!(V_val, Float64(m_diag[d]))
                end
            end
        else
            m_full = Matrix{Float64}(raw_full)
            n = min(6, size(m_full, 1), size(m_full, 2))
            for r in 1:n, c in 1:n
                val = m_full[r, c]
                abs(val) > 1e-30 || continue
                push!(I_idx, base+r); push!(J_idx, base+c); push!(V_val, val)
            end
        end
    end

    # --- CMASS2 scalar mass (mass value on the card itself) ---
    cmass2s = get(model, "CMASS2s", Dict())
    for (_, cm) in cmass2s
        mass = Float64(get(cm, "M", 0.0))
        abs(mass) < 1e-30 && continue
        g1 = get(cm, "G1", 0); c1 = get(cm, "C1", 0)
        if g1 > 0 && c1 > 0 && haskey(id_map, g1)
            dof1 = (id_map[g1]-1)*6 + c1
            push!(I_idx, dof1); push!(J_idx, dof1); push!(V_val, mass)
        end
        g2 = get(cm, "G2", 0); c2 = get(cm, "C2", 0)
        if g2 > 0 && c2 > 0 && haskey(id_map, g2)
            dof2 = (id_map[g2]-1)*6 + c2
            push!(I_idx, dof2); push!(J_idx, dof2); push!(V_val, mass)
        end
    end

    # --- CMASS1 scalar mass (mass value from PMASS property) ---
    cmass1s = get(model, "CMASS1s", Dict())
    pmasses = get(model, "PMASSs", Dict())
    for (_, cm) in cmass1s
        pid = string(get(cm, "PID", 0))
        pm = get(pmasses, pid, nothing)
        pm === nothing && continue
        mass = Float64(get(pm, "M", 0.0))
        abs(mass) < 1e-30 && continue
        g1 = get(cm, "G1", 0); c1 = get(cm, "C1", 0)
        if g1 > 0 && c1 > 0 && haskey(id_map, g1)
            dof1 = (id_map[g1]-1)*6 + c1
            push!(I_idx, dof1); push!(J_idx, dof1); push!(V_val, mass)
        end
        g2 = get(cm, "G2", 0); c2 = get(cm, "C2", 0)
        if g2 > 0 && c2 > 0 && haskey(id_map, g2)
            dof2 = (id_map[g2]-1)*6 + c2
            push!(I_idx, dof2); push!(J_idx, dof2); push!(V_val, mass)
        end
    end

    log_msg("[SOLVER] Mass matrix: $(length(V_val)) triplets assembled")
    M = sparse(I_idx, J_idx, V_val, ndof, ndof)

    # Apply WTMASS parameter (unit conversion: weight-density → mass-density)
    # Nastran: M_effective = M * WTMASS  (default WTMASS = 1.0)
    # Common: WTMASS = 1/g = 0.00259 (lb-in-s), 0.001 (kg-mm-s → tonnes)
    wtmass = Float64(get(model, "PARAM_WTMASS", 1.0))
    if wtmass != 1.0 && wtmass > 0.0
        log_msg("[SOLVER] Applying WTMASS = $wtmass to mass matrix")
        M .*= wtmass
    end

    return M
end

# =============================================================================
# SOL103 NORMAL MODES EIGENVALUE SOLVER
# Solves: K*phi = omega^2 * M * phi
# =============================================================================
function solve_modes(K, M, ndof, model, id_map, X, spc_id, node_R, num_modes;
                     rbe3_map=Dict{Int,Vector{Tuple{Int,Float64}}}(),
                     max_elem_stiff=0.0, orig_diag=Float64[],
                     eigrl_v1::Float64=0.0, eigrl_v2::Float64=0.0,
                     eigrl_norm::AbstractString="MASS",
                     eigen_cache=nothing,
                     return_diagnostics::Bool=false)

    log_msg("[MODES] Computing free DOFs...")
    eigen_ctx, eigen_cache_hit = prepare_eigen_solve_context(
        K, ndof, model, id_map, spc_id, rbe3_map; eigen_cache=eigen_cache)
    free_dofs = eigen_ctx.free_dofs
    fixed_dofs = eigen_ctx.fixed_dofs
    bc_diagnostics = eigen_ctx.bc_diagnostics
    n_free = length(free_dofs)
    log_msg("[MODES] Free DOFs: $n_free, Fixed DOFs: $(length(fixed_dofs))")
    if eigen_cache_hit
        log_msg("[MODES] Reusing eigen BC partition cache: Fixed DOFs=$(length(fixed_dofs)), Free DOFs=$n_free")
    end
    diagnostics = Dict{String,Any}(
        "bc_partition" => deepcopy(bc_diagnostics),
        "requested_modes" => num_modes,
        "requested_modes_internal" => 0,
        "free_dofs" => n_free,
        "fixed_dofs" => length(fixed_dofs),
        "eigrl_range" => Dict("v1" => eigrl_v1, "v2" => eigrl_v2),
        "eigrl_norm" => uppercase(strip(eigrl_norm)),
        "eigen_cache" => Dict{String,Any}(
            "enabled" => eigen_cache !== nothing,
            "cache_hit" => eigen_cache_hit,
            "factorization_cache_hit" => false,
        ),
        "solver_backend" => "unsolved",
        "solver_attempts" => Any[],
        "returned_modes" => 0,
    )

    K_ff = eigen_ctx.K_ff
    M_ff = M[free_dofs, free_dofs]
    M_ff = 0.5 * (M_ff + M_ff')

    # Nastran's SOL 103 READ/Lanczos path can work with massless-but-stiff
    # coordinates (for example shell bending rotations): they remain in KXX,
    # while MXX is singular. Only genuinely unsupported massless coordinates
    # should be removed. The remaining singular-M cases are sent to the
    # shift-invert solver below, which applies K\ M without requiring M to be
    # positive definite.
    mass_diag = abs.(diag(M_ff))
    mass_scale = isempty(mass_diag) ? 0.0 : maximum(mass_diag)
    mass_tol = max(mass_scale * 1.0e-12, 1.0e-30)
    stiff_diag = abs.(diag(K_ff))
    stiff_scale = isempty(stiff_diag) ? 0.0 : maximum(stiff_diag)
    stiff_tol = max(stiff_scale * 1.0e-12, 1.0e-20)
    massless_idx = findall(<=(mass_tol), mass_diag)
    # 2026-08-05: drop ONLY massless coordinates that are also stiffness-free
    # (true mechanisms). The former unconditional `component == 6` clause was
    # a shell-drilling-era heuristic that SPC'd every massless r3; on a bar
    # along x, r3 is a genuine bending rotation with real stiffness, and
    # constraining it locked the t2 bending plane (CBAR modal probe modes
    # 29159/169952 instead of the reference's 2582.69/68528.4 pair). The
    # reference retains massless-but-stiff coordinates; so does the
    # shift-invert path below, which condenses them exactly. Shell drilling
    # at K6ROT=0 is already caught by the zero-stiffness clause or AUTOSPC.
    drop_mass_idx = [i for i in massless_idx if stiff_diag[i] <= stiff_tol]
    keep_mass_idx = isempty(drop_mass_idx) ? collect(1:n_free) : setdiff(collect(1:n_free), drop_mass_idx)
    mass_filter_removed = length(drop_mass_idx)
    if mass_filter_removed > 0
        removed_dofs = free_dofs[drop_mass_idx]
        free_dofs = free_dofs[keep_mass_idx]
        fixed_dofs = vcat(fixed_dofs, removed_dofs)
        K_ff = K_ff[keep_mass_idx, keep_mass_idx]
        M_ff = M_ff[keep_mass_idx, keep_mass_idx]
        n_free = length(free_dofs)
        diagnostics["free_dofs"] = n_free
        diagnostics["fixed_dofs"] = length(fixed_dofs)
        diagnostics["massless_free_dofs_removed"] = mass_filter_removed
        diagnostics["massless_free_dof_tolerance"] = mass_tol
        diagnostics["massless_zero_stiffness_dof_tolerance"] = stiff_tol
        log_msg("[MODES] AUTOSPC massless zero-stiffness filter removed $mass_filter_removed DOFs (mass tol=$(round(mass_tol; sigdigits=4)), stiffness tol=$(round(stiff_tol; sigdigits=4)))")
        if n_free == 0
            log_msg("[MODES] ERROR: No dynamic DOFs remain after massless-DOF filtering")
            diagnostics["solver_backend"] = "failed"
            return return_diagnostics ? (Float64[], Float64[], zeros(ndof, 0), diagnostics) : (Float64[], Float64[], zeros(ndof, 0))
        end
    else
        diagnostics["massless_free_dofs_removed"] = 0
        diagnostics["massless_free_dof_tolerance"] = mass_tol
        diagnostics["massless_zero_stiffness_dof_tolerance"] = stiff_tol
    end
    mass_diag = abs.(diag(M_ff))
    singular_mass = any(<=(mass_tol), mass_diag)
    singular_mass_retained = count(<=(mass_tol), mass_diag)
    diagnostics["singular_mass_coordinates_retained"] = singular_mass_retained
    if singular_mass
        log_msg("[MODES] Retaining $singular_mass_retained massless stiff DOFs for shift-invert modal solve")
    end

    # All remaining dynamic DOFs can carry modes after SPC/AUTOSPC filtering.
    # The old n_free-2 cap hid valid roots in small verification decks such as
    # two-DOF rod chains, while doing nothing useful for production-size models.
    num_modes_request = min(max(num_modes * 3, 1), n_free)
    diagnostics["requested_modes_internal"] = num_modes_request

    log_msg("[MODES] Solving eigenvalue problem ($num_modes modes, $n_free DOFs)...")

    local eigenvalues, eigenvectors
    solved = false

    # Strategy 1: Dense eigensolver for small/medium systems
    if n_free <= 4000 && !singular_mass
        push!(diagnostics["solver_attempts"], Dict("name" => "dense_symmetric_definite", "status" => "attempted"))
        try
            log_msg("[MODES] Using dense symmetric-definite eigensolver ($n_free DOFs)...")
            Kd = Matrix(K_ff); Md = Matrix(M_ff)
            vals, vecs = eigen(Symmetric(Kd), Symmetric(Md))
            # Filter: positive real eigenvalues (ω²)
            valid = findall(x -> isfinite(x) && x > 1e-6, vals)
            if !isempty(valid)
                n_out = min(num_modes_request, length(valid))
                eigenvalues = vals[valid[1:n_out]]
                eigenvectors = vecs[:, valid[1:n_out]]
                solved = true
                diagnostics["solver_backend"] = "dense_symmetric_definite"
                diagnostics["solver_attempts"][end] = Dict("name" => "dense_symmetric_definite", "status" => "succeeded", "returned_modes" => n_out)
                log_msg("[MODES] Dense eigensolver converged ($n_out modes)")
            end
        catch e
            diagnostics["solver_attempts"][end] = Dict("name" => "dense_symmetric_definite", "status" => "failed", "error" => sprint(showerror, e))
            log_msg("[MODES] Dense eigensolver failed: $e")
        end
    elseif n_free <= 4000
        push!(diagnostics["solver_attempts"], Dict("name" => "dense_symmetric_definite", "status" => "skipped", "reason" => "singular_mass"))
    end

    # Strategy 2: KrylovKit shift-invert for larger systems
    if !solved
        push!(diagnostics["solver_attempts"], Dict("name" => "krylov_shift_invert", "status" => "attempted"))
        try
            log_msg("[MODES] Using KrylovKit shift-invert ($n_free DOFs)...")
            K_factor = nothing
            factor_cache_hit = false
            factor_backend = "cholesky"
            if mass_filter_removed == 0
                K_factor, factor_cache_hit = ensure_eigen_solve_factorization!(eigen_ctx)
                factor_backend = eigen_ctx.factor_backend
                if factor_cache_hit
                    log_msg("[MODES] Reusing eigen K factorization cache ($(eigen_ctx.factor_backend))")
                else
                    log_msg("[MODES] K factorization succeeded ($(eigen_ctx.factor_backend))")
                end
            else
                K_factor = try
                    cholesky(Symmetric(K_ff))
                catch e
                    if e isa LinearAlgebra.PosDefException ||
                       e isa LinearAlgebra.SingularException ||
                       e isa LinearAlgebra.ZeroPivotException
                        factor_backend = "lu"
                        lu(K_ff)
                    else
                        rethrow(e)
                    end
                end
                log_msg("[MODES] K factorization succeeded ($factor_backend, mass-filtered)")
            end
            diagnostics["eigen_cache"]["factorization_cache_hit"] = factor_cache_hit
            diagnostics["eigen_cache"]["factor_backend"] = factor_backend
            nev = min(num_modes_request + 5, n_free - 1)
            kd = min(max(2*nev + 10, 30), n_free)

            # Start vector: DETERMINISTIC, not randn. A random start vector can
            # land with near-zero overlap on one member of an exactly degenerate
            # mode pair, and the Krylov space then never resolves it — the
            # documented "CBAR probe intermittently returned 4 of 6 modes, about
            # one run in five" behaviour, whose 1-in-5 cadence is the signature
            # of the draw rather than of an algorithmic bug. It was also the last
            # run-to-run non-determinism in the solver (the CRM SOL 103 rows of
            # the public suite wobbled at the 1e-15 level between identical
            # runs, which is why suite gates had to judge verdicts rather than
            # bytes). SOL 105 has used this generator since the deterministic
            # threading work; SOL 103 now shares it.
            #
            # Determinism alone only makes the outcome REPRODUCIBLE, so the
            # completeness guard below turns "silently miss a degenerate
            # partner" into "detect and recover it".
            modal_start_ordinal = Ref(0)
            next_modal_start() = begin
                modal_start_ordinal[] += 1
                _deterministic_buckling_start_vector(n_free, modal_start_ordinal[])
            end

            # K⁻¹M operator: largest θ = 1/ω² → smallest ω
            vals_kk, vecs_kk, info = eigsolve(
                x -> K_factor \ (M_ff * x), next_modal_start(), nev, :LM;
                krylovdim=kd, maxiter=500, tol=1e-10, eager=true)

            harvest_modes(vals, vecs) = begin
                osq = Float64[]
                vs = Vector{Float64}[]
                for (i, theta) in enumerate(vals)
                    theta_r = real(theta)
                    theta_r < 1e-14 && continue
                    abs(imag(theta)) > 1e-6 * abs(theta_r) && continue
                    omega_sq = 1.0 / theta_r
                    omega_sq > 1e-6 || continue
                    push!(osq, omega_sq)
                    push!(vs, real.(vecs[i]))
                end
                (osq, vs)
            end
            actual_omegas_sq, actual_vecs = harvest_modes(vals_kk, vecs_kk)

            # --- Completeness guard (Sturm inertia over the reported band) ----
            # The pencil (K - ω²M) has exactly as many eigenvalues below σ as
            # K - σM has negative inertia, so _buckling_sturm_count applies
            # verbatim with Kg := -M and σ := ω². If the certificate says roots
            # are missing below the highest one we would report — the signature
            # of a dropped degenerate partner — retry from a different
            # deterministic start vector and merge. The guard can only ADD
            # modes: values already found are never perturbed, so decks that
            # pass today cannot regress.
            if solver_env_bool("JFEM_SOL103_COMPLETENESS_GUARD", true) &&
               !isempty(actual_omegas_sq)
                mass_neg = -M_ff
                sturm_reuse_modal = Base.RefValue{Any}(nothing)
                max_tries = max(solver_env_int("JFEM_SOL103_COMPLETENESS_TRIES", 2), 0)
                guard_log = Any[]
                for attempt in 1:max_tries
                    sorted_osq = sort(actual_omegas_sq)
                    n_report = min(max(num_modes_request, 1), length(sorted_osq))
                    b_bound = sorted_osq[n_report] * (1.0 + 1e-6)
                    sc_b = _buckling_sturm_count(K_ff, mass_neg, b_bound;
                                                 reuse=sturm_reuse_modal)
                    sc_b === nothing && break
                    found = count(<=(b_bound), actual_omegas_sq)
                    gap = sc_b - found
                    push!(guard_log, Dict{String,Any}(
                        "attempt" => attempt, "omega_sq_bound" => b_bound,
                        "sturm_below" => sc_b, "recovered" => found, "gap" => gap))
                    gap <= 0 && break
                    log_msg("[MODES] completeness guard: Sturm reports $sc_b root(s) below ω²=$b_bound but $found recovered — retrying from start vector $(modal_start_ordinal[] + 1)")
                    v2, w2, _ = eigsolve(
                        x -> K_factor \ (M_ff * x), next_modal_start(),
                        min(nev + gap, n_free - 1), :LM;
                        krylovdim=kd, maxiter=500, tol=1e-10, eager=true)
                    osq2, vs2 = harvest_modes(v2, w2)
                    added = 0
                    for (o, v) in zip(osq2, vs2)
                        if all(x -> abs(x - o) > 1e-8 * max(abs(x), abs(o), 1.0),
                               actual_omegas_sq)
                            push!(actual_omegas_sq, o); push!(actual_vecs, v)
                            added += 1
                        end
                    end
                    log_msg("[MODES] completeness guard: recovered $added additional mode(s)")
                    added == 0 && break
                end
                isempty(guard_log) ||
                    (diagnostics["completeness_guard"] = guard_log)
            end
            if !isempty(actual_omegas_sq)
                perm = sortperm(actual_omegas_sq)
                n_out = min(num_modes_request, length(perm))
                eigenvalues = [actual_omegas_sq[perm[i]] for i in 1:n_out]
                eigenvectors = hcat([actual_vecs[perm[i]] for i in 1:n_out]...)
                solved = true
                diagnostics["solver_backend"] = "krylov_shift_invert"
                diagnostics["solver_attempts"][end] = Dict("name" => "krylov_shift_invert", "status" => "succeeded", "returned_modes" => n_out, "converged" => info.converged)
                log_msg("[MODES] KrylovKit converged ($n_out modes)")
            end
        catch e
            diagnostics["solver_attempts"][end] = Dict("name" => "krylov_shift_invert", "status" => "failed", "error" => sprint(showerror, e))
            log_msg("[MODES] KrylovKit failed: $(sprint(showerror, e))")
        end
    end

    if !solved
        log_msg("[MODES] ERROR: All eigenvalue solvers failed")
        diagnostics["solver_backend"] = "failed"
        return return_diagnostics ? (Float64[], Float64[], zeros(ndof, 0), diagnostics) : (Float64[], Float64[], zeros(ndof, 0))
    end

    n_out = length(eigenvalues)
    frequencies = sqrt.(abs.(eigenvalues)) ./ (2π)

    # --- EIGRL V1/V2 frequency range filtering ---
    # V1 and V2 are frequency bounds in Hz (Nastran convention)
    has_range = (eigrl_v1 > 0.0 || eigrl_v2 > 0.0)
    if has_range
        v1 = eigrl_v1 > 0.0 ? eigrl_v1 : 0.0
        v2 = eigrl_v2 > 0.0 ? eigrl_v2 : Inf
        range_idx = findall(f -> f >= v1 && f <= v2, frequencies)
        if !isempty(range_idx)
            log_msg("[MODES] EIGRL frequency filter: V1=$v1 Hz, V2=$v2 Hz → $(length(range_idx)) modes in range")
            eigenvalues = eigenvalues[range_idx]
            frequencies = frequencies[range_idx]
            eigenvectors = eigenvectors[:, range_idx]
            n_out = length(eigenvalues)
        else
            log_msg("[MODES] WARNING: No modes found in frequency range [$v1, $v2] Hz, returning all $(n_out) modes")
        end
    end

    # --- Trim to requested number of modes ---
    if n_out > num_modes
        log_msg("[MODES] Trimming from $n_out to $num_modes requested modes")
        eigenvalues = eigenvalues[1:num_modes]
        frequencies = frequencies[1:num_modes]
        eigenvectors = eigenvectors[:, 1:num_modes]
        n_out = num_modes
    end

    # Expand to full DOF set
    mode_shapes = zeros(ndof, n_out)
    for m in 1:n_out
        mode_shapes[free_dofs, m] = eigenvectors[:, m]
    end

    # Transform to global coordinates
    mode_shapes_global = zeros(ndof, n_out)
    sorted_nodes = sort(collect(keys(id_map)))
    for nid in sorted_nodes
        idx = id_map[nid]; base = (idx-1)*6
        for m in 1:n_out
            u_loc = mode_shapes[base+1:base+6, m]
            mode_shapes_global[base+1:base+3, m] = node_R[idx] * u_loc[1:3]
            mode_shapes_global[base+4:base+6, m] = node_R[idx] * u_loc[4:6]
        end
    end

    norm_mode = uppercase(strip(eigrl_norm))
    isempty(norm_mode) && (norm_mode = "MASS")
    if norm_mode != "MASS" && norm_mode != "MAX"
        log_msg("[MODES] WARNING: Unsupported EIGRL NORM=$norm_mode, using MASS normalization")
        norm_mode = "MASS"
    end

    # Normalize mode shapes according to the requested EIGRL NORM.
    for m in 1:n_out
        if norm_mode == "MAX"
            max_val = maximum(abs.(mode_shapes_global[:, m]))
            if max_val > 1e-30
                mode_shapes_global[:, m] ./= max_val
            end
        else
            phi = mode_shapes[free_dofs, m]  # use analysis-frame eigenvector
            gen_mass = dot(phi, M_ff * phi)
            if gen_mass > 1e-30
                scale = 1.0 / sqrt(gen_mass)
                mode_shapes_global[:, m] .*= scale
            else
                max_val = maximum(abs.(mode_shapes_global[:, m]))
                if max_val > 1e-30
                    mode_shapes_global[:, m] ./= max_val
                end
            end
        end
    end

    log_msg("[MODES] Natural frequencies:")
    for (i, f) in enumerate(frequencies)
        log_msg("  Mode $i: f = $(round(f, digits=4)) Hz (ω² = $(round(eigenvalues[i], sigdigits=6)))")
    end

    diagnostics["returned_modes"] = n_out
    diagnostics["returned_modes"] = n_out
    return return_diagnostics ? (eigenvalues, frequencies, mode_shapes_global, diagnostics) : (eigenvalues, frequencies, mode_shapes_global)
end
