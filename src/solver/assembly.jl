# assembly.jl — Global stiffness matrix assembly
#
# =============================================================================
# Q4 KERNEL DISPATCH OVERVIEW
# =============================================================================
# `assemble_stiffness` iterates every CQUAD4 element and picks ONE of the
# stiffness kernels defined in FEMKernels.jl. The dispatch chain lives around
# line 3570-3744 (K) and 5800-5920 (K_g). This block documents what the chain
# actually does. Update this block when the dispatch logic changes.
#
# Read the file as: "for each element, walk the chain top-down; the first
# branch whose condition is true wins". The fallback `else` at the end is the
# production default (`stiffness_quad4_matrices` / `geometric_stiffness_quad4`).
#
# Per-element K stiffness dispatch (see line ~3570):
#
#  # | Condition                                       | Kernel called                              | Default? | Notes
# ---+-------------------------------------------------+--------------------------------------------+----------+------
#  1 | elem_mitc4_3d_kernel                            | stiffness_quad4_mitc4_3d_{ply,resultant}   | partial  | JFEM_Q4_KERNEL=mitc4_3d, plus non-PCOMP high-skew auto gate
#  2 | elem_shear_center_only && is_iso_ei             | stiffness_quad4_matrices (center+blend)    | ON*      | Iso curved-shell in K_eig path
#  3 | elem_flat_dkmq_branch                           | stiffness_quad4_plate_dkmq_matrices        | OFF      | JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ
#  4 | elem_rect_plate_branch                          | stiffness_quad4_plate_adini_matrices       | OFF      | JFEM_SOL105_EIG_FLAT_PCOMP_RECT_ADINI
#  5 | elem_flat_plate_branch                          | stiffness_quad4_plate_dkq_matrices         | OFF      | JFEM_SOL105_EIG_FLAT_PCOMP_PLATE_BRANCH
#  6 | elem_shear_center_only && is_pcomp_ei (flat)    | stiffness_quad4_matrices (center+blend)    | ON*      | Composite curved-shell in K_eig path
#  7 | elem_curved_iso_blend > 0.0                     | stiffness_quad4_matrices (curved blend)    | partial  | Iso curved blend factor
#  8 | else (fallback)                                 | stiffness_quad4_matrices                   | ON       | Production default — covers everything else
#
# Per-element K_g (geometric) dispatch (see line ~5800):
#
#  # | Condition                                       | Kernel called                              | Default?
# ---+-------------------------------------------------+--------------------------------------------+---------
#  1 | kg_flat_dkmq_branch && is_pcomp_ei              | geometric_stiffness_quad4_plate_dkmq       | OFF (coupled to K#3)
#  2 | elem_rect_plate_branch && is_pcomp_ei           | geometric_stiffness_quad4_plate_adini      | OFF (coupled to K#4)
#  3 | elem_flat_plate_branch                          | geometric_stiffness_quad4_plate_dkq        | OFF (coupled to K#5)
#  4 | JFEM_SOL105_EIG_CURVED_JACOBIAN && coords_3d    | geometric_stiffness_quad4_covariant        | OFF
#  5 | else (fallback)                                 | geometric_stiffness_quad4                  | ON
#
# Live trace (2026-05-22) on HTP_launch GAME deck (10,274 PCOMP CQUAD4) under
# default settings confirms ONLY these 3 kernels actually fire:
#   - stiffness_quad4_matrices       (K, branch #8 fallback)
#   - add_quad4_macneal_shear_rbf!   (internal, called from stiffness_quad4_matrices)
#   - geometric_stiffness_quad4      (K_g, branch #5 fallback)
#
# Everything else in this dispatch chain is RESEARCH / RETAINED — opt-in via
# JFEM_Q4_KERNEL or JFEM_SOL105_EIG_FLAT_PCOMP_* env vars. See FEMKernels.jl
# header banners on each kernel for status and calibration knobs.
#
# *ON in K_eig path only (shear_center_only=true). With JFEM_SOL105_USE_STATIC_K
# default true, K_eig == K_static so branches #2 and #6 reduce to #8.
# =============================================================================

@inline function curved_iso_eig_fullshear_blend()
    raw = get(ENV, "JFEM_CURVED_ISO_EIG_FULLSHEAR_BLEND", "1.0")
    return clamp(something(tryparse(Float64, raw), 1.0), 0.0, 1.0)
end

@inline function curved_pcomp_eig_fullshear_blend()
    raw = get(ENV, "JFEM_CURVED_PCOMP_EIG_FULLSHEAR_BLEND", "1.0")
    return clamp(something(tryparse(Float64, raw), 1.0), 0.0, 1.0)
end

@inline function _bar_bending_inertias(prop)
    I_default = Float64(get(prop, "I", 0.0))
    Iy = haskey(prop, "I2") ? Float64(prop["I2"]) : I_default
    Iz = haskey(prop, "I1") ? Float64(prop["I1"]) : I_default
    return Iy, Iz
end

@inline function q4_geom_normals_nearly_constant(
    n1::SVector{3,Float64},
    n2::SVector{3,Float64},
    n3::SVector{3,Float64},
    n4::SVector{3,Float64};
    tol::Float64=1e-6,
)
    return norm(n1 - n2) <= tol &&
           norm(n1 - n3) <= tol &&
           norm(n1 - n4) <= tol &&
           norm(n2 - n3) <= tol &&
           norm(n2 - n4) <= tol &&
           norm(n3 - n4) <= tol
end

@inline function shell_project_frame_to_normal(
    v1::SVector{3,Float64},
    v2::SVector{3,Float64},
    v3::SVector{3,Float64},
    n::SVector{3,Float64},
)
    v3n = dot(n, v3) < 0.0 ? -n : n
    v1p = v1 - dot(v1, v3n) * v3n
    v1l = norm(v1p)
    if v1l <= 1e-12
        v2p = v2 - dot(v2, v3n) * v3n
        v2l = norm(v2p)
        if v2l <= 1e-12
            return v1, v2, v3
        end
        v1n = SVector{3}(v2p / v2l)
    else
        v1n = SVector{3}(v1p / v1l)
    end
    return v1n, SVector{3}(cross(v3n, v1n)), v3n
end


function build_node_has_line_elements(model, id_map, n_nodes)
    node_has_line = falses(n_nodes)
    for group_name in ("CBARs", "CBEAMs", "CRODs", "CONRODs")
        group = get(model, group_name, Dict())
        for (_, el) in group
            ga = get(id_map, get(el, "GA", 0), 0)
            gb = get(id_map, get(el, "GB", 0), 0)
            ga > 0 && (node_has_line[ga] = true)
            gb > 0 && (node_has_line[gb] = true)
        end
    end
    return node_has_line
end

function build_node_has_frame_elements(model, id_map, n_nodes)
    node_has_frame = falses(n_nodes)
    for group_name in ("CBARs", "CBEAMs")
        group = get(model, group_name, Dict())
        for (_, el) in group
            ga = get(id_map, get(el, "GA", 0), 0)
            gb = get(id_map, get(el, "GB", 0), 0)
            ga > 0 && (node_has_frame[ga] = true)
            gb > 0 && (node_has_frame[gb] = true)
        end
    end
    return node_has_frame
end

@inline function pbeam_station_condensed_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_PBEAM_STATION_CONDENSED", "false")))
    return raw in ("1", "true", "yes", "on")
end

@inline function pbeam_neutral_axis_coupling_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_PBEAM_NEUTRAL_AXIS_COUPLING", "false")))
    return raw in ("1", "true", "yes", "on")
end

@inline function _station_value(st::AbstractDict, key::String, fallback::Float64)
    return Float64(get(st, key, fallback))
end

function _apply_pbeam_neutral_axis_coupling(Ke_loc::AbstractMatrix, prop::AbstractDict)
    pbeam_neutral_axis_coupling_enabled() || return Ke_loc
    n1a = Float64(get(prop, "N1A", 0.0))
    n2a = Float64(get(prop, "N2A", 0.0))
    n1b = Float64(get(prop, "N1B", 0.0))
    n2b = Float64(get(prop, "N2B", 0.0))
    if max(abs(n1a), abs(n2a), abs(n1b), abs(n2b)) <= 0.0
        return Ke_loc
    end
    C = Matrix{Float64}(I, 12, 12)
    C[1, 5] += n2a
    C[1, 6] -= n1a
    C[7, 11] += n2b
    C[7, 12] -= n1b
    return C' * Matrix(Ke_loc) * C
end

function _pbeam_station_condensed_stiffness(L::Float64, prop::AbstractDict, E::Float64, G::Float64)
    pbeam_station_condensed_enabled() || return nothing
    stations_raw = get(prop, "STATIONS", nothing)
    stations_raw isa AbstractVector || return nothing
    length(stations_raw) >= 2 || return nothing

    stations = sort(collect(stations_raw); by=s -> Float64(get(s, "X", 0.0)))
    n = length(stations)
    nd = 6 * n
    K = zeros(Float64, nd, nd)
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))
    active_segments = 0

    for s in 1:(n - 1)
        xa = clamp(Float64(get(stations[s], "X", 0.0)), 0.0, 1.0)
        xb = clamp(Float64(get(stations[s + 1], "X", 1.0)), 0.0, 1.0)
        xb > xa + 1e-10 || continue
        segL = (xb - xa) * L
        segL > 1e-12 || continue

        A = 0.5 * (
            _station_value(stations[s], "A", Float64(get(prop, "A", 0.0))) +
            _station_value(stations[s + 1], "A", Float64(get(prop, "A", 0.0)))
        )
        base_Iy, base_Iz = _bar_bending_inertias(prop)
        I1 = 0.5 * (
            _station_value(stations[s], "I1", base_Iz) +
            _station_value(stations[s + 1], "I1", base_Iz)
        )
        I2 = 0.5 * (
            _station_value(stations[s], "I2", base_Iy) +
            _station_value(stations[s + 1], "I2", base_Iy)
        )
        I12 = 0.5 * (
            _station_value(stations[s], "I12", Float64(get(prop, "I12", 0.0))) +
            _station_value(stations[s + 1], "I12", Float64(get(prop, "I12", 0.0)))
        )
        J = 0.5 * (
            _station_value(stations[s], "J", Float64(get(prop, "J", 0.0))) +
            _station_value(stations[s + 1], "J", Float64(get(prop, "J", 0.0)))
        )

        Iy = I2
        Iz = I1
        As_y = (K1 > 0.0) ? K1 * A : Inf
        As_z = (K2 > 0.0) ? K2 * A : Inf
        Ke_seg = FEM.stiffness_frame3d(segL, A, Iy, Iz, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
        dofs = vcat(((s - 1) * 6 + 1):(s * 6), (s * 6 + 1):((s + 1) * 6))
        for c in 1:12, r in 1:12
            K[dofs[r], dofs[c]] += Ke_seg[r, c]
        end
        active_segments += 1
    end

    active_segments > 0 || return nothing
    boundary = vcat(1:6, (nd - 5):nd)
    if nd == 12
        return K[boundary, boundary]
    end
    internal = collect(7:(nd - 6))
    Kii = K[internal, internal]
    try
        return K[boundary, boundary] - K[boundary, internal] * (Kii \ K[internal, boundary])
    catch
        return nothing
    end
end

@inline function scale_shell_local_drilling_dof!(Ke::AbstractMatrix, local_node::Int, scale::Float64)
    scale == 1.0 && return nothing
    dof = (local_node - 1) * 6 + 6
    n = size(Ke, 1)
    @inbounds for j in 1:n
        Ke[dof, j] *= scale
        Ke[j, dof] *= scale
    end
    return nothing
end

# De-boxed CQUAD4 transform/triplet tail (function barrier, 2026-08-06).
# At the caller, Ke_t is union-typed across the 8-way kernel branch table,
# which made every load in these @fastmath loops box (~826 MB + ~200 MB of
# allocation per 6220-element assembly). The caller concretizes Ke_t to
# Matrix{Float64} exactly once and this barrier transcribes the tail
# verbatim — identical arithmetic, loop order, branch logic, and sparsity
# guards; only the binding types change. The sep_* scratch matrices are
# per-thread buffers and MUST arrive here already tid-resolved.
function _quad4_transform_emit!(
    out_t::Matrix{Float64}, T_t::Matrix{Float64}, tmp_t::Matrix{Float64},
    dofs::Vector{Int},
    Ke_t::Matrix{Float64}, ke_t_global_ready::Bool,
    ei::Int, i1::Int, i2::Int, i3::Int, i4::Int,
    v1::SVector{3,Float64}, v2::SVector{3,Float64}, v3::SVector{3,Float64},
    snorm_transform_only::Bool, snorm_xf_ok::Bool,
    snorm_xf_v3::SVector{3,Float64},
    elem_flat_curved_iso_nodal_geomnormal_transform::Bool,
    elem_static_pcomp_nodal_geomnormal_transform::Bool,
    geom_vec::Vector{SVector{3,Float64}},
    node_R_flat::Array{Float64,3},
    snorm_director::Bool, snorm_has::BitVector,
    snorm_vec::Vector{SVector{3,Float64}},
    all_I::Vector{Int}, all_J::Vector{Int}, all_V::Vector{Float64},
)
    fill!(out_t, 0.0)
    if ke_t_global_ready
        @inbounds @fastmath for jj in 1:24, ii in 1:24
            out_t[ii, jj] = Ke_t[ii, jj]
        end
    else
        fill!(T_t, 0.0)
        @inbounds @fastmath for k in 1:4
            idx = k == 1 ? i1 : k == 2 ? i2 : k == 3 ? i3 : i4
            base = (k-1)*6
                vk1, vk2, vk3 =
                (snorm_transform_only && snorm_xf_ok) ?
                shell_project_frame_to_normal(v1, v2, v3, snorm_xf_v3) :
                (elem_flat_curved_iso_nodal_geomnormal_transform ||
                 elem_static_pcomp_nodal_geomnormal_transform) ?
                shell_project_frame_to_normal(v1, v2, v3, geom_vec[idx]) :
                (v1, v2, v3)
            Rel_t = @SMatrix [vk1[1] vk1[2] vk1[3]; vk2[1] vk2[2] vk2[3]; vk3[1] vk3[2] vk3[3]]
            for rr in 1:3, cc in 1:3
                val = Rel_t[rr,1]*node_R_flat[1,cc,idx] + Rel_t[rr,2]*node_R_flat[2,cc,idx] + Rel_t[rr,3]*node_R_flat[3,cc,idx]
                T_t[base+rr, base+cc] = val
                T_t[base+3+rr, base+3+cc] = val
            end
            if snorm_director && snorm_has[idx]
                # rotational block only: reference this node's rotations to its grid normal.
                # Built from the element's OWN geometric frame (v1,v2,v3) — the frame Ke_t was
                # formed in — not the per-node projected vk frame.
                TR = @SMatrix [T_t[base+4,base+4] T_t[base+4,base+5] T_t[base+4,base+6];
                               T_t[base+5,base+4] T_t[base+5,base+5] T_t[base+5,base+6];
                               T_t[base+6,base+4] T_t[base+6,base+5] T_t[base+6,base+6]]
                TRs = snorm_director_matrix(snorm_vec[idx], v1, v2, v3) * TR
                for rr in 1:3, cc in 1:3
                    T_t[base+3+rr, base+3+cc] = TRs[rr,cc]
                end
            end
        end
        fill!(tmp_t, 0.0)
        @inbounds @fastmath for jj in 1:24, ll in 1:24
            val = T_t[ll, jj]
            if val != 0.0
                for ii in 1:24; tmp_t[ii, jj] += Ke_t[ii, ll] * val; end
            end
        end
        @inbounds @fastmath for jj in 1:24, ll in 1:24
            val = tmp_t[ll, jj]
            if val != 0.0
                for ii in 1:24; out_t[ii, jj] += T_t[ll, ii] * val; end
            end
        end
    end

    for k in 1:4
        idx = k == 1 ? i1 : k == 2 ? i2 : k == 3 ? i3 : i4
        b = (idx-1)*6
        for d in 1:6; dofs[(k-1)*6+d] = b+d; end
    end
    base = (ei-1)*576; cnt = 0
    for cc in 1:24, rr in 1:24
        cnt += 1
        all_I[base+cnt] = dofs[rr]
        all_J[base+cnt] = dofs[cc]
        all_V[base+cnt] = out_t[rr,cc]
    end
    return nothing
end

@inline function q4_flat_iso_eig_membrane_incomp_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_SOL105_EIG_FLAT_ISO_MEMBRANE_INCOMP", "true")))
    return raw in ("1", "true", "yes", "on")
end

@inline function q4_sol105_membrane_incomp_center_jacobian_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_SOL105_MEMBRANE_INCOMP_CENTER_JACOBIAN", "false")))
    return raw in ("1", "true", "yes", "on")
end

@inline function q4_flat_iso_eig_membrane_shear_center_row_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_SOL105_EIG_FLAT_ISO_MEMBRANE_SHEAR_CENTER_ROW", "false")))
    return raw in ("1", "true", "yes", "on")
end


@inline function q4_sol105_flat_iso_dkmq_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_SOL105_EIG_FLAT_ISO_DKMQ", "true")))
    return raw in ("1", "true", "yes", "on")
end

@inline function kg_use_compatible_membrane_stress()
    # Keep legacy behavior unless the user opts into the experimental curved
    # shell formulation. In that branch, Kg should recover membrane resultants
    # from the same compatible field that feeds the covariant surface operator,
    # unless the user explicitly pins the old behavior with JFEM_KG_*.
    if !haskey(ENV, "JFEM_KG_USE_COMPATIBLE_MEMBRANE_STRESS") &&
       q4_eig_curved_jacobian_enabled() &&
       !kg_match_static_membrane_operator_enabled()
        return true
    end
    raw = lowercase(strip(get(ENV, "JFEM_KG_USE_COMPATIBLE_MEMBRANE_STRESS", "false")))
    return raw in ("1", "true", "yes", "on")
end

@inline function kg_quad4_stress_field_mode()
    raw = lowercase(strip(get(ENV, "JFEM_KG_QUAD4_STRESS_FIELD_MODE", "gauss")))
    if raw in ("avg", "average", "mean")
        return :average
    elseif raw in ("gp", "gauss", "field", "gauss_field")
        return :gauss
    else
        return :auto
    end
end

@inline function kg_quad4_consistent_membrane_operator_enabled()
    # If the element stiffness uses statically condensed membrane modes, the
    # SOL105 differential-stiffness operator should use the same condensed
    # displacement-gradient map. This is a formulation-consistency default, not
    # a laminate/test-case correction.
    return solver_env_bool("JFEM_KG_CONSISTENT_MEMBRANE_OPERATOR", true)
end

@inline function kg_quad4_gp_field_avg_ratio_max()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_GP_FIELD_AVG_RATIO_MAX", "0.35"))
    return max(something(tryparse(Float64, raw), 0.35), 0.0)
end

@inline function kg_quad4_auto_avg_shear_ratio_max()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_AVG_SHEAR_RATIO_MAX", "0.02"))
    return clamp(something(tryparse(Float64, raw), 0.02), 0.0, 1.0)
end

@inline function kg_quad4_auto_avg_require_compression()
    return solver_env_bool("JFEM_KG_QUAD4_AUTO_AVG_REQUIRE_COMPRESSION", true)
end

@inline function kg_quad4_auto_avg_require_biaxial_compression()
    return solver_env_bool("JFEM_KG_QUAD4_AUTO_AVG_REQUIRE_BIAXIAL_COMPRESSION", true)
end

@inline function kg_quad4_auto_avg_require_geometry()
    return solver_env_bool("JFEM_KG_QUAD4_AUTO_AVG_REQUIRE_GEOMETRY", false)
end

@inline function kg_quad4_auto_avg_kappa_l_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_AVG_KAPPA_L_MIN", "1.0e-8"))
    return max(something(tryparse(Float64, raw), 1.0e-8), 0.0)
end

@inline function kg_quad4_auto_avg_cyl_ratio_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_AVG_CYL_RATIO_MIN", "0.9"))
    return clamp(something(tryparse(Float64, raw), 0.9), 0.0, 1.0)
end


@inline function kg_quad4_membrane_recovery_mode()
    if !haskey(ENV, "JFEM_KG_QUAD4_MEMBRANE_RECOVERY_MODE") &&
       q4_eig_curved_jacobian_enabled()
        return :covariant
    end
    raw = lowercase(strip(get(ENV, "JFEM_KG_QUAD4_MEMBRANE_RECOVERY_MODE", "planar")))
    if raw in ("covariant", "surface", "cov")
        return :covariant
    elseif raw in ("auto", "curved_auto", "surface_auto")
        return :auto
    elseif raw in ("tri_aspect", "triangle_aspect", "nastran1976", "nastran_tri")
        return :tri_aspect
    elseif raw in ("tri_center", "tri_center_adj", "triangle_center")
        return :tri_center_adj
    elseif raw in ("tri_incident", "tri_incident_interp", "triangle_incident")
        return :tri_incident_interp
    elseif raw in ("tri_diagavg", "triangle_diagavg", "diagavg")
        return :tri_diagavg
    else
        return :planar
    end
end

@inline function kg_quad4_membrane_tri_aspect_switch()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_MEMBRANE_TRI_ASPECT_SWITCH", "2.0"))
    return max(something(tryparse(Float64, raw), 2.0), 1.0)
end

@inline function kg_quad4_covariant_blend()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_COVARIANT_BLEND", "1.0"))
    return clamp(something(tryparse(Float64, raw), 1.0), 0.0, 1.0)
end

@inline function kg_quad4_covariant_auto_kappa_l_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_COVARIANT_AUTO_KAPPA_L_MIN", "0.01"))
    return max(something(tryparse(Float64, raw), 0.01), 0.0)
end

@inline function kg_quad4_covariant_auto_cyl_ratio_max()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_COVARIANT_AUTO_CYL_RATIO_MAX", "0.85"))
    return clamp(something(tryparse(Float64, raw), 0.85), 0.0, 1.0)
end

@inline function kg_quad4_auto_gp_spread_enabled()
    return solver_env_bool("JFEM_KG_QUAD4_AUTO_GP_SPREAD", false)
end

@inline function kg_quad4_auto_gp_spread_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_GP_SPREAD_MIN", "0.5"))
    return max(something(tryparse(Float64, raw), 0.5), 0.0)
end

@inline function kg_quad4_auto_gp_spread_kappa_l_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_GP_SPREAD_KAPPA_L_MIN", "0.05"))
    return max(something(tryparse(Float64, raw), 0.05), 0.0)
end

@inline function kg_quad4_auto_gp_spread_cyl_ratio_min()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_GP_SPREAD_CYL_RATIO_MIN", "0.9"))
    return clamp(something(tryparse(Float64, raw), 0.9), 0.0, 1.0)
end

@inline function kg_quad4_auto_gp_spread_blend_scale()
    raw = strip(get(ENV, "JFEM_KG_QUAD4_AUTO_GP_SPREAD_BLEND_SCALE", "0.0"))
    return max(something(tryparse(Float64, raw), 0.0), 0.0)
end

@inline function kg_quad4_gp_field_blend_override()
    haskey(ENV, "JFEM_KG_QUAD4_GP_FIELD_BLEND") || return nothing
    raw = strip(get(ENV, "JFEM_KG_QUAD4_GP_FIELD_BLEND", ""))
    val = something(tryparse(Float64, raw), 1.0)
    return clamp(val, 0.0, 1.0)
end

@inline function kg_quad4_gp_field_pmin_spread_avg_min()
    raw = solver_env_optional_float("JFEM_KG_QUAD4_GP_FIELD_PMIN_SPREAD_AVG_MIN")
    raw === nothing && return Inf
    return max(raw, 0.0)
end

@inline function kg_quad4_gp_field_pmin_spread_avg_alpha()
    return clamp(solver_env_float("JFEM_KG_QUAD4_GP_FIELD_PMIN_SPREAD_AVG_ALPHA", 0.0), 0.0, 1.0)
end

@inline function kg_quad4_gp_field_extrapolate_scale()
    return max(solver_env_float("JFEM_KG_QUAD4_GP_FIELD_EXTRAPOLATE_SCALE", 1.0), 0.0)
end

@inline function kg_quad4_shear_average_operator_enabled()
    return solver_env_bool("JFEM_KG_QUAD4_SHEAR_AVG_OPERATOR", false)
end

@inline function kg_quad4_shear_average_ratio_min()
    return clamp(solver_env_float("JFEM_KG_QUAD4_SHEAR_AVG_RATIO_MIN", 0.9), 0.0, 1.0)
end

@inline function kg_quad4_shear_average_warp_min()
    return max(solver_env_float("JFEM_KG_QUAD4_SHEAR_AVG_WARP_MIN", 0.0), 0.0)
end

@inline function kg_quad4_shear_average_warp_max()
    return max(solver_env_float("JFEM_KG_QUAD4_SHEAR_AVG_WARP_MAX", 1.0e99), 0.0)
end

@inline function kg_quad4_shear_average_aspect_min()
    return max(solver_env_float("JFEM_KG_QUAD4_SHEAR_AVG_ASPECT_MIN", 1.0), 1.0)
end

@inline function kg_quad4_shear_average_aspect_max()
    return max(solver_env_float("JFEM_KG_QUAD4_SHEAR_AVG_ASPECT_MAX", 1.0e99), 1.0)
end

@inline function kg_quad4_shear_average_geometry_mode()
    raw = lowercase(strip(get(ENV, "JFEM_KG_QUAD4_SHEAR_AVG_GEOM_MODE", "all")))
    return raw in ("any", "or", "either") ? :any : :all
end

@inline function kg_quad4_geometry_gate(
    warp_ratio::Float64,
    aspect_ratio::Float64,
    warp_min::Float64,
    warp_max::Float64,
    aspect_min::Float64,
    aspect_max::Float64,
    mode::Symbol,
)
    upper_ok = warp_ratio <= warp_max && aspect_ratio <= aspect_max
    lower_ok = mode === :any ?
        (warp_ratio >= warp_min || aspect_ratio >= aspect_min) :
        (warp_ratio >= warp_min && aspect_ratio >= aspect_min)
    return upper_ok && lower_ok
end

@inline function kg_quad4_shear_resultant_ratio(N_avg::AbstractVector)
    denom = abs(N_avg[1]) + abs(N_avg[2]) + abs(N_avg[3])
    return denom > 1e-30 ? abs(N_avg[3]) / denom : 0.0
end

# ---- Load-aware shear-kernel selection (SOL105), STATIC side ----------------
#
# MSC Nastran's released CQUAD4 (flat MacNeal RBF transverse shear) and JFEM's
# default MITC4+phi2 shear agree on flat panels and on compression, but diverge
# on WARPED/CURVED elements under SHEAR preload (up to ~46% on the buckling
# eigenvalue). The divergence enters through the STATIC solve: the kernel sets
# u_static, hence the per-element membrane-stress field, hence Kg, hence lambda.
# (The eigenvalue stiffness itself is bit-identical either way — verified.)
#
# Empirical-but-principled criterion, derived from the SOL105 probe POPULATION
# (NOT from the GAME validation set — those are held out for validation):
#   route element e to the flat MacNeal kernel iff BOTH
#     (1) e is non-flat (warp_ratio >= JFEM_SOL105_LOAD_AWARE_WARP_MIN), AND
#     (2) e is shear-dominated:
#           |Nxy| / (|Nx|+|Ny|+|Nxy|) >= JFEM_SOL105_LOAD_AWARE_SHEAR_RATIO_MIN
# The conjunction is what the population separates cleanly: warped+shear probes
# (mean |Nxy| ratio ~0.145-0.171) need the switch; flat+shear cases are already
# correct (excluded by the geometry gate) and curved+mid-shear compression
# (~0.10) sits below the shear gate, so it is left on MITC. Both thresholds are
# population-separation values, documented as a heuristic, not first-principles
# constants. Off by default (JFEM_SOL105_LOAD_AWARE_KERNEL).
@inline sol105_load_aware_kernel_enabled() =
    solver_env_bool("JFEM_SOL105_LOAD_AWARE_KERNEL", false)
@inline sol105_load_aware_shear_ratio_min() =
    clamp(solver_env_float("JFEM_SOL105_LOAD_AWARE_SHEAR_RATIO_MIN", 0.12), 0.0, 1.0)
@inline sol105_load_aware_warp_min() =
    max(solver_env_float("JFEM_SOL105_LOAD_AWARE_WARP_MIN", 1.0e-5), 0.0)


@inline function q4_pcomp_cs_over_cm(Cm, Cs)
    return maximum(abs, Cs) / max(maximum(abs, Cm), 1e-30)
end




"""
    classify_shear_dominant_elements(model, id_map, X, node_R, u_global, snorm_normals) -> Dict{Int,Bool}

Per-CQUAD4 conjunction classification from the static displacement field:
`eid => true` when the element is non-flat AND shear-dominated (see the criterion
above). Reuses the static stress-recovery primitive for the membrane resultant
and the element warp deviation for the geometry gate. Pure geometry/load — no
element id, deck name, or family is consulted.
"""
function classify_shear_dominant_elements(model, id_map, X, node_R, u_global, snorm_normals)
    out = Dict{Int,Bool}()
    haskey(model, "CSHELLs") || return out
    smin = sol105_load_aware_shear_ratio_min()
    wmin = sol105_load_aware_warp_min()
    q4_frame_mode = q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC")

    lc_buf = zeros(4, 2)
    for (id, el) in model["CSHELLs"]
        nids = el["NODES"]
        length(nids) == 4 || continue
        any(x -> get(id_map, x, 0) == 0, nids) && continue
        pid = string(el["PID"]); haskey(model["PSHELLs"], pid) || continue
        prop = model["PSHELLs"][pid]; mid = string(prop["MID"])
        haskey(model["MATs"], mid) || continue
        mat = model["MATs"][mid]
        i1, i2, i3, i4 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]], id_map[nids[4]]
        p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3]); p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
        p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3]); p4 = SVector{3}(X[i4,1], X[i4,2], X[i4,3])
        sr_indices = [i1, i2, i3, i4]
        v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
        v1, v2, v3 = apply_snorm_to_frame(v1, v2, v3, sr_indices, snorm_normals)
        c = (p1 + p2 + p3 + p4) / 4.0
        # geometry gate: out-of-plane warp deviation relative to diagonal length.
        Ldiag = max(norm(p3 - p1), norm(p4 - p2), 1e-12)
        warp_dev = max(abs(dot(p1 - c, v3)), abs(dot(p2 - c, v3)),
                       abs(dot(p3 - c, v3)), abs(dot(p4 - c, v3)))
        warp_ratio = warp_dev / Ldiag
        eid = _stress_entry_public_id(id, el)
        if warp_ratio < wmin
            out[eid] = false
            continue
        end
        # shear gate: per-element membrane shear-resultant ratio from the static
        # field. Uses the local-frame element displacement and stress_strain_quad4
        # (same primitive recover_shell_stresses! uses for the centroid N).
        lc_buf[1,1]=dot(p1-c,v1); lc_buf[1,2]=dot(p1-c,v2)
        lc_buf[2,1]=dot(p2-c,v1); lc_buf[2,2]=dot(p2-c,v2)
        lc_buf[3,1]=dot(p3-c,v1); lc_buf[3,2]=dot(p3-c,v2)
        lc_buf[4,1]=dot(p4-c,v1); lc_buf[4,2]=dot(p4-c,v2)
        Rel_t = vcat(v1', v2', v3')
        u_el = zeros(24)
        for k in 1:4
            idx = id_map[nids[k]]
            u_el[(k-1)*6+1:(k-1)*6+3] = Rel_t * node_R[idx] * u_global[(idx-1)*6+1:(idx-1)*6+3]
            u_el[(k-1)*6+4:(k-1)*6+6] = Rel_t * node_R[idx] * u_global[(idx-1)*6+4:(idx-1)*6+6]
        end
        E_eff = get(mat, "E", get(mat, "E1", 1.0))
        nu_eff = get(mat, "NU", get(mat, "NU12", 0.3))
        snorm_pq_sr = snorm_element_pq(v1, v2, v3, sr_indices, snorm_normals)
        coords3d_sr = [p1[1] p1[2] p1[3];
                       p2[1] p2[2] p2[3];
                       p3[1] p3[2] p3[3];
                       p4[1] p4[2] p4[3]]
        shear_dominant = false
        try
            N, = FEM.stress_strain_quad4(view(lc_buf,1:4,:), u_el,
                E_eff, nu_eff, Float64(prop["T"]), Float64(prop["T"]);
                bend_ratio=get(prop, "BEND_RATIO", 1.0),
                snorm_pq=snorm_pq_sr,
                coords_3d=coords3d_sr)
            shear_dominant = kg_quad4_shear_resultant_ratio(N) >= smin
        catch
            shear_dominant = false
        end
        out[eid] = shear_dominant
    end
    return out
end

@inline function kg_quad4_use_gp_field(
    N_gp::AbstractMatrix,
    N_avg::AbstractVector,
    auto_avg_geom_ok::Bool=false,
)
    mode = kg_quad4_stress_field_mode()
    mode === :gauss && return true
    mode === :average && return false


    if kg_quad4_auto_avg_require_geometry() && !auto_avg_geom_ok
        return true
    end
        if kg_quad4_auto_avg_require_compression()
            min(N_avg[1], N_avg[2]) < 0.0 || return true
            (N_avg[1] + N_avg[2]) < 0.0 || return true
            if kg_quad4_auto_avg_require_biaxial_compression()
                max(N_avg[1], N_avg[2]) < 0.0 || return true
            end
        end
        if kg_quad4_shear_resultant_ratio(N_avg) > kg_quad4_auto_avg_shear_ratio_max()
            return true
        end

    mean_gp_norm = 0.0
    @inbounds for gp in 1:size(N_gp, 1)
        mean_gp_norm += sqrt(N_gp[gp,1]^2 + N_gp[gp,2]^2 + N_gp[gp,3]^2)
    end
    mean_gp_norm /= max(size(N_gp, 1), 1)
    mean_gp_norm <= 1e-12 && return false

    avg_norm = sqrt(N_avg[1]^2 + N_avg[2]^2 + N_avg[3]^2)
    return avg_norm / mean_gp_norm <= kg_quad4_gp_field_avg_ratio_max()
end

@inline function kg_quad4_blend_gp_field!(N_eff::AbstractMatrix, N_gp::AbstractMatrix, N_avg::AbstractVector, alpha::Float64)
    @inbounds for gp in 1:size(N_gp, 1)
        N_eff[gp, 1] = N_avg[1] + alpha * (N_gp[gp, 1] - N_avg[1])
        N_eff[gp, 2] = N_avg[2] + alpha * (N_gp[gp, 2] - N_avg[2])
        N_eff[gp, 3] = N_avg[3] + alpha * (N_gp[gp, 3] - N_avg[3])
    end
    return N_eff
end

@inline function kg_shell_trans_mode()
    # MSC Nastran's CQUAD4 differential stiffness acts on displacement
    # gradients transverse to the local principal membrane-stress directions,
    # not on all three translational components equally. Single-element
    # MATPRN/KDJJ probes confirm this for both flat and warped quads; keep
    # :all as an explicit continuum/geometric-stiffness research option.
    raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_TRANS_DOF_MODE", "principal_transverse")))
    if raw in ("normal_only", "normal", "w_only")
        return :normal_only
    elseif raw in ("principal_transverse", "stress_transverse", "nastran_flat", "nastran")
        return :principal_transverse
    elseif raw in ("curvature", "curvature_coupled", "shell_curvature")
        return :curvature
    else
        return :all
    end
end

@inline function kg_shell_principal_transverse_flat_only_enabled()
    # Default off: warped CQUAD4 KDJJ probes still match the principal
    # transverse operator far better than the older :all fallback.
    return solver_env_bool("JFEM_KG_SHELL_PRINCIPAL_TRANSVERSE_FLAT_ONLY", false)
end

@inline function kg_quad4_iso_nastran_kdjj_mode()
    # Kg operator for flat isotropic (non-PCOMP) CQUAD4: replace the element
    # Kg with the Nastran-KDJJ-exact kernel
    # (FEM.geometric_stiffness_quad4_nastran_kdjj_iso).
    #   off  -> never
    #   skew -> only when the element corner angle deviates from 90deg by more
    #           than JFEM_KG_QUAD4_ISO_NASTRAN_KDJJ_SKEW_MIN_DEG (rectangular
    #           elements keep the legacy operator bit-identically)
    #   all  -> every flat isotropic non-PCOMP CQUAD4 (default: the legacy
    #           operator's element-MEAN stress destroys the per-GP field
    #           variation that gradient-load states live on — KDJJ entry
    #           mismatch 66/69/38% on load_uy/load_shear/aspect_2 vs
    #           0.03% for this kernel; eigen load_uy +54.9%->0.000%,
    #           load_shear -30.4%->0.000%, all previously-exact atomics
    #           unchanged)
    raw = lowercase(strip(get(ENV, "JFEM_KG_QUAD4_ISO_NASTRAN_KDJJ", "all")))
    if raw in ("off", "false", "0", "none")
        return :off
    elseif raw in ("all", "always", "true", "1")
        return :all
    else
        return :skew
    end
end

@inline function kg_quad4_iso_nastran_kdjj_skew_min_deg()
    return max(solver_env_float("JFEM_KG_QUAD4_ISO_NASTRAN_KDJJ_SKEW_MIN_DEG", 2.0), 0.0)
end

@inline function sol105_pcomp_skew_membrane_min_deg()
    # Corner-angle deviation (deg from 90) below which the composite skew-
    # membrane OPERATOR SWAPS (bilinear+hourglass membrane replacing the Wilson
    # incompatible membrane; KDJJ composite Kg replacing the legacy operator)
    # stay OFF and the element keeps the legacy operators bit-identically.
    # These kernels are SKEW corrections calibrated at deviation 20-45 deg;
    # ungated they fired on EVERY flat composite element (93% rectangles on the
    # box guardrail), replacing the element-validated Wilson membrane and the
    # gradient-capable legacy Kg fleet-wide (2026-07-16 canary: -13% on a
    # mild-skew box that the skewed-element fixes never targeted).  Measured
    # threshold sweep on that canary (iter_291, baseline +0.36%): unscoped
    # -13.0%, gate 2 deg -5.1%, gate 10 deg -2.2% -- monotone recovery as the
    # swap is restricted to the deviation range the calibration covers.
    # Default 10.0 = the first nonzero calibration knot band (zb law identity
    # below ~10 deg; hourglass split calibrated at 0/20/45 deg).  The
    # analytic Cm/Bmb frame rotation needs no gate (it vanishes continuously
    # on rectangles: side 1-2 || v1 -> phi = 0).
    return max(solver_env_float("JFEM_SOL105_PCOMP_SKEW_MEMBRANE_MIN_DEG", 10.0), 0.0)
end

@inline function kg_shell_principal_transverse_warp_ratio_max()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_TRANSVERSE_WARP_RATIO_MAX", 1e-6), 0.0)
end

@inline function q4_pcomp_kg_trans_mode_final(
    requested::Symbol,
    is_pcomp_clt::Bool,
    pcomp_is_isotropic::Bool,
    has_bmb::Bool,
    elem_is_flat_kg::Bool,
    flat_pcomp_plate_like_kg::Bool,
    nonflat_pcomp_normal_only_kg::Bool,
    geom_curvature,
)
    pcomp_normal_only = false
    is_saddle = false
    final = requested
    if is_pcomp_clt && !pcomp_is_isotropic && !has_bmb
        # For PCOMP composites without B-coupling, use normal-only geometric
        # stiffness on flat elements when explicitly requested and on
        # non-saddle curved elements. Saddle surfaces keep in-plane terms.
        is_saddle = !elem_is_flat_kg && geom_curvature !== nothing &&
            q4_curvature_gaussian(geom_curvature) < -1e-10
        pcomp_normal_only = elem_is_flat_kg ? flat_pcomp_plate_like_kg :
                             (nonflat_pcomp_normal_only_kg && !is_saddle)
        if pcomp_normal_only
            final = :normal_only
        end
    end
    return final, pcomp_normal_only, is_saddle
end

@inline function kg_shell_principal_shear_yy_factor()
    return solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_YY_FACTOR", 1.0)
end

@inline function kg_shell_principal_shear_xy_factor()
    return solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_XY_FACTOR", 1.0)
end

@inline function kg_shell_principal_shear_z_factor()
    return solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_Z_FACTOR", 1.0)
end

@inline function kg_shell_principal_shear_ratio_min()
    return clamp(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_RATIO_MIN", 1.0), 0.0, 1.0)
end

@inline function kg_shell_principal_shear_warp_min()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_WARP_MIN", 0.0), 0.0)
end

@inline function kg_shell_principal_shear_warp_max()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_WARP_MAX", 1.0e99), 0.0)
end

@inline function kg_shell_principal_shear_aspect_min()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_ASPECT_MIN", 1.0), 1.0)
end

@inline function kg_shell_principal_shear_aspect_max()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_ASPECT_MAX", 1.0e99), 1.0)
end

@inline function kg_shell_principal_shear_geometry_mode()
    raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_PRINCIPAL_SHEAR_GEOM_MODE", "all")))
    return raw in ("any", "or", "either") ? :any : :all
end

@inline function kg_shell_principal_shear_feature_gate()
    raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_PRINCIPAL_SHEAR_FEATURE_GATE", "any")))
    if raw in ("positive", "pos", "tension", "+")
        return :positive
    elseif raw in ("negative", "neg", "compression", "-")
        return :negative
    elseif raw in ("positive_or_gp_pmin_spread", "pos_or_gp_pmin_spread", "positive_or_pmin_spread")
        return :positive_or_gp_pmin_spread
    elseif raw in ("positive_or_gp_nxx_spread", "pos_or_gp_nxx_spread", "positive_or_nxx_spread")
        return :positive_or_gp_nxx_spread
    elseif raw in ("positive_or_gp_spread", "pos_or_gp_spread")
        return :positive_or_gp_spread
    else
        return :any
    end
end

@inline function kg_shell_principal_shear_gp_pmin_spread_min()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_GP_PMIN_SPREAD_MIN", 0.0), 0.0)
end

@inline function kg_shell_principal_shear_gp_nxx_spread_min()
    return max(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_GP_NXX_SPREAD_MIN", 0.0), 0.0)
end

@inline function kg_shell_principal_shear_gp_spread_factor()
    return clamp(solver_env_float("JFEM_KG_SHELL_PRINCIPAL_SHEAR_GP_SPREAD_FACTOR", 1.0), 0.0, 1.0)
end

@inline function kg_shell_curvature_sign()
    raw = strip(get(ENV, "JFEM_KG_SHELL_CURVATURE_SIGN", "1.0"))
    val = something(tryparse(Float64, raw), 1.0)
    return val < 0.0 ? -1.0 : 1.0
end


























@inline function sol105_pcomp_k_macneal_blend_key(band::Int, suffix::String)
    return band <= 1 ?
        "JFEM_SOL105_PCOMP_K_MACNEAL_BLEND_" * suffix :
        "JFEM_SOL105_PCOMP_K_MACNEAL_BLEND$(band)_" * suffix
end

@inline sol105_pcomp_k_macneal_blend_float(band::Int, suffix::String, fallback::Float64) =
    solver_env_float(sol105_pcomp_k_macneal_blend_key(band, suffix), fallback)

@inline sol105_pcomp_k_macneal_blend_int(band::Int, suffix::String, fallback::Int) =
    solver_env_int(sol105_pcomp_k_macneal_blend_key(band, suffix), fallback)

@inline function sol105_pcomp_k_macneal_blend_band_count()
    return clamp(solver_env_int("JFEM_SOL105_PCOMP_K_MACNEAL_BLEND_BAND_COUNT", 1), 1, 16)
end

@inline function sol105_pcomp_k_macneal_blend_band(
    band::Int,
    is_pcomp::Bool,
    is_pcomp_iso::Bool,
    aspect::Float64,
    taper_ratio::Float64,
    h_over_lmax::Float64,
    warp_ratio::Float64,
    kappa_l::Float64,
    pm45_fraction::Float64,
    pm90_fraction::Float64,
    ply_count::Int,
    alpha_inf::Float64,
    beta::Float64,
    gamma::Float64,
    delta::Float64,
)
    blend = clamp(sol105_pcomp_k_macneal_blend_float(band, "VALUE", 0.0), 0.0, 1.0)
    blend > 0.0 || return 0.0
    is_pcomp && !is_pcomp_iso || return 0.0

    aspect_min = max(sol105_pcomp_k_macneal_blend_float(band, "ASPECT_MIN", 1.0), 1.0)
    aspect_max = max(sol105_pcomp_k_macneal_blend_float(band, "ASPECT_MAX", 1.0e99), aspect_min)
    taper_min = max(sol105_pcomp_k_macneal_blend_float(band, "TAPER_MIN", 0.0), 0.0)
    taper_max = max(sol105_pcomp_k_macneal_blend_float(band, "TAPER_MAX", 1.0e99), taper_min)
    h_min = max(sol105_pcomp_k_macneal_blend_float(band, "H_OVER_LMAX_MIN", 0.0), 0.0)
    h_max = max(sol105_pcomp_k_macneal_blend_float(band, "H_OVER_LMAX_MAX", 1.0e99), h_min)
    warp_min = max(sol105_pcomp_k_macneal_blend_float(band, "WARP_MIN", 0.0), 0.0)
    warp_max = max(sol105_pcomp_k_macneal_blend_float(band, "WARP_MAX", 1.0e99), warp_min)
    kappa_min = max(sol105_pcomp_k_macneal_blend_float(band, "KAPPA_L_MIN", 0.0), 0.0)
    kappa_max = max(sol105_pcomp_k_macneal_blend_float(band, "KAPPA_L_MAX", 1.0e99), kappa_min)
    pm45_min = clamp(sol105_pcomp_k_macneal_blend_float(band, "PM45_MIN", 0.0), 0.0, 1.0)
    pm45_max = clamp(max(sol105_pcomp_k_macneal_blend_float(band, "PM45_MAX", 1.0), pm45_min), 0.0, 1.0)
    pm90_min = clamp(sol105_pcomp_k_macneal_blend_float(band, "PM90_MIN", 0.0), 0.0, 1.0)
    pm90_max = clamp(max(sol105_pcomp_k_macneal_blend_float(band, "PM90_MAX", 1.0), pm90_min), 0.0, 1.0)
    ply_min = max(sol105_pcomp_k_macneal_blend_int(band, "PLY_COUNT_MIN", 0), 0)
    ply_max = max(sol105_pcomp_k_macneal_blend_int(band, "PLY_COUNT_MAX", typemax(Int)), ply_min)

    alpha_min = sol105_pcomp_k_macneal_blend_float(band, "ALPHA_MIN", 0.0)
    alpha_max = max(sol105_pcomp_k_macneal_blend_float(band, "ALPHA_MAX", 1.0e99), alpha_min)
    beta_min = sol105_pcomp_k_macneal_blend_float(band, "BETA_MIN", -1.0e99)
    beta_max = max(sol105_pcomp_k_macneal_blend_float(band, "BETA_MAX", 1.0e99), beta_min)
    gamma_min = sol105_pcomp_k_macneal_blend_float(band, "GAMMA_MIN", -1.0e99)
    gamma_max = max(sol105_pcomp_k_macneal_blend_float(band, "GAMMA_MAX", 1.0e99), gamma_min)
    delta_min = sol105_pcomp_k_macneal_blend_float(band, "DELTA_MIN", -1.0e99)
    delta_max = max(sol105_pcomp_k_macneal_blend_float(band, "DELTA_MAX", 1.0e99), delta_min)
    abs_gamma_min = max(sol105_pcomp_k_macneal_blend_float(band, "ABS_GAMMA_MIN", 0.0), 0.0)
    abs_gamma_max = max(sol105_pcomp_k_macneal_blend_float(band, "ABS_GAMMA_MAX", 1.0e99), abs_gamma_min)
    abs_delta_min = max(sol105_pcomp_k_macneal_blend_float(band, "ABS_DELTA_MIN", 0.0), 0.0)
    abs_delta_max = max(sol105_pcomp_k_macneal_blend_float(band, "ABS_DELTA_MAX", 1.0e99), abs_delta_min)

    aspect >= aspect_min || return 0.0
    aspect <= aspect_max || return 0.0
    taper_ratio >= taper_min || return 0.0
    taper_ratio <= taper_max || return 0.0
    h_over_lmax >= h_min || return 0.0
    h_over_lmax <= h_max || return 0.0
    warp_ratio >= warp_min || return 0.0
    warp_ratio <= warp_max || return 0.0
    kappa_l >= kappa_min || return 0.0
    kappa_l <= kappa_max || return 0.0
    pm45_fraction >= pm45_min || return 0.0
    pm45_fraction <= pm45_max || return 0.0
    pm90_fraction >= pm90_min || return 0.0
    pm90_fraction <= pm90_max || return 0.0
    ply_count >= ply_min || return 0.0
    ply_count <= ply_max || return 0.0
    alpha_inf >= alpha_min || return 0.0
    alpha_inf <= alpha_max || return 0.0
    beta >= beta_min || return 0.0
    beta <= beta_max || return 0.0
    gamma >= gamma_min || return 0.0
    gamma <= gamma_max || return 0.0
    delta >= delta_min || return 0.0
    delta <= delta_max || return 0.0
    abs(gamma) >= abs_gamma_min || return 0.0
    abs(gamma) <= abs_gamma_max || return 0.0
    abs(delta) >= abs_delta_min || return 0.0
    abs(delta) <= abs_delta_max || return 0.0
    return blend
end

@inline function sol105_pcomp_k_macneal_blend(
    is_pcomp::Bool,
    is_pcomp_iso::Bool,
    aspect::Float64,
    taper_ratio::Float64,
    h_over_lmax::Float64,
    warp_ratio::Float64,
    kappa_l::Float64,
    pm45_fraction::Float64,
    pm90_fraction::Float64,
    ply_count::Int,
    alpha_inf::Float64,
    beta::Float64,
    gamma::Float64,
    delta::Float64,
)
    best = 0.0
    for band in 1:sol105_pcomp_k_macneal_blend_band_count()
        best = max(best, sol105_pcomp_k_macneal_blend_band(
            band,
            is_pcomp,
            is_pcomp_iso,
            aspect,
            taper_ratio,
            h_over_lmax,
            warp_ratio,
            kappa_l,
            pm45_fraction,
            pm90_fraction,
            ply_count,
            alpha_inf,
            beta,
            gamma,
            delta,
        ))
    end
    return best
end


@inline sol105_geom_pshell_iso_warped_kg_scale_enabled() =
    solver_env_bool("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_SCALE", true)
@inline sol105_geom_pshell_iso_warped_kg_scale_value() =
    solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_SCALE_VALUE", 1.00)
@inline sol105_geom_pshell_iso_warped_kg_warp_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_WARP_MIN", 1.0e-5), 0.0)
@inline sol105_geom_pshell_iso_warped_kg_warp_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_WARP_MAX", 0.001),
        sol105_geom_pshell_iso_warped_kg_warp_min(),
    )
@inline sol105_geom_pshell_iso_warped_kg_aspect_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_ASPECT_MIN", 0.90), 1.0e-6)
@inline sol105_geom_pshell_iso_warped_kg_aspect_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_ASPECT_MAX", 1.10),
        sol105_geom_pshell_iso_warped_kg_aspect_min(),
    )
@inline sol105_geom_pshell_iso_warped_kg_h_over_lmax_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_H_OVER_LMAX_MIN", 0.03), 0.0)
@inline sol105_geom_pshell_iso_warped_kg_h_over_lmax_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_WARPED_KG_H_OVER_LMAX_MAX", 0.08),
        sol105_geom_pshell_iso_warped_kg_h_over_lmax_min(),
    )
@inline sol105_geom_pshell_iso_skew_kg_scale_enabled() =
    solver_env_bool("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_SCALE", true)
@inline sol105_geom_pshell_iso_skew_kg_scale_value() =
    solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_SCALE_VALUE", 1.0)
@inline sol105_geom_pshell_iso_skew_kg_skew_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_SKEW_MIN", 50.0), 0.0)
@inline sol105_geom_pshell_iso_skew_kg_skew_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_SKEW_MAX", 80.0),
        sol105_geom_pshell_iso_skew_kg_skew_min(),
    )
@inline sol105_geom_pshell_iso_skew_kg_warp_max() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_WARP_MAX", 1.0e-8), 0.0)
@inline sol105_geom_pshell_iso_skew_kg_aspect_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_ASPECT_MIN", 0.90), 1.0e-6)
@inline sol105_geom_pshell_iso_skew_kg_aspect_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_ASPECT_MAX", 1.10),
        sol105_geom_pshell_iso_skew_kg_aspect_min(),
    )
@inline sol105_geom_pshell_iso_skew_kg_h_over_lmax_min() =
    max(solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_H_OVER_LMAX_MIN", 0.03), 0.0)
@inline sol105_geom_pshell_iso_skew_kg_h_over_lmax_max() =
    max(
        solver_env_float("JFEM_SOL105_GEOM_PSHELL_ISO_SKEW_KG_H_OVER_LMAX_MAX", 0.08),
        sol105_geom_pshell_iso_skew_kg_h_over_lmax_min(),
    )


@inline function sol105_geom_pshell_iso_warped_kg_scale(
    is_pshell_iso::Bool,
    aspect::Float64,
    warp_ratio::Float64,
    h_over_lmax::Float64,
    scale_value::Float64,
    aspect_min::Float64,
    aspect_max::Float64,
    warp_min::Float64,
    warp_max::Float64,
    h_over_lmax_min::Float64,
    h_over_lmax_max::Float64,
)
    is_pshell_iso || return 1.0
    aspect >= aspect_min && aspect <= aspect_max || return 1.0
    warp_ratio >= warp_min && warp_ratio <= warp_max || return 1.0
    h_over_lmax >= h_over_lmax_min && h_over_lmax <= h_over_lmax_max || return 1.0
    return scale_value
end

@inline function sol105_geom_pshell_iso_skew_kg_scale(
    is_pshell_iso::Bool,
    aspect::Float64,
    warp_ratio::Float64,
    edge_skew::Float64,
    h_over_lmax::Float64,
    scale_value::Float64,
    aspect_min::Float64,
    aspect_max::Float64,
    warp_max::Float64,
    skew_min::Float64,
    skew_max::Float64,
    h_over_lmax_min::Float64,
    h_over_lmax_max::Float64,
)
    is_pshell_iso || return 1.0
    aspect >= aspect_min && aspect <= aspect_max || return 1.0
    warp_ratio <= warp_max || return 1.0
    edge_skew >= skew_min && edge_skew <= skew_max || return 1.0
    h_over_lmax >= h_over_lmax_min && h_over_lmax <= h_over_lmax_max || return 1.0
    return scale_value
end



@inline function q4_static_component_v2_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_V2_MIN", 0.0), 0.0)
end

@inline function q4_static_component_v2_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_V2_MAX", 0.0), 0.0)
end

@inline function q4_static_component_thickness_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_THICKNESS_MIN", 0.0), 0.0)
end

@inline function q4_static_component_thickness_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_THICKNESS_MAX", 0.0), 0.0)
end

@inline function q4_static_component_aspect_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_ASPECT_MIN", 0.0), 0.0)
end

@inline function q4_static_component_aspect_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_ASPECT_MAX", 0.0), 0.0)
end

@inline function q4_static_component_taper_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_TAPER_MIN", 0.0), 0.0)
end

@inline function q4_static_component_taper_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_TAPER_MAX", 0.0), 0.0)
end

@inline function q4_static_component_h_over_l_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_H_OVER_L_MIN", 0.0), 0.0)
end

@inline function q4_static_component_h_over_l_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_H_OVER_L_MAX", 0.0), 0.0)
end

@inline function q4_static_component_warp_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_WARP_MIN", 0.0), 0.0)
end

@inline function q4_static_component_warp_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_WARP_MAX", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_shear_ratio_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_SHEAR_RATIO_MIN", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_shear_ratio_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_SHEAR_RATIO_MAX", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_d16_ratio_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_D16_RATIO_MIN", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_d16_ratio_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_D16_RATIO_MAX", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_b_ratio_min()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_B_RATIO_MIN", 0.0), 0.0)
end

@inline function q4_static_component_pcomp_b_ratio_max()
    return max(solver_env_float("JFEM_Q4_STATIC_COMPONENT_PCOMP_B_RATIO_MAX", 0.0), 0.0)
end

@inline function q4_static_component_range_ok(value::Float64, value_min::Float64, value_max::Float64)
    value_min <= 0.0 && value_max <= 0.0 && return true
    return (value_min <= 0.0 || value >= value_min) &&
           (value_max <= 0.0 || value <= value_max)
end

@inline function q4_static_component_pcomp_range_ok(is_pcomp::Bool, value::Float64,
                                                    value_min::Float64, value_max::Float64)
    value_min <= 0.0 && value_max <= 0.0 && return true
    is_pcomp || return false
    return q4_static_component_range_ok(value, value_min, value_max)
end

function q4_static_component_model_eigrl_v2(model)
    cc = get(model, "CASE_CONTROL", nothing)
    cc isa AbstractDict || return 0.0
    subcases = get(cc, "SUBCASES", nothing)
    subcases isa AbstractDict || return 0.0
    eigrls = get(model, "EIGRLs", nothing)
    eigrls isa AbstractDict || return 0.0
    max_v2 = 0.0
    for sub in values(subcases)
        sub isa AbstractDict || continue
        method_id = get(sub, "METHOD", nothing)
        method_id === nothing && continue
        method_sid = tryparse(Int, string(method_id))
        method_sid === nothing && continue
        eigrl = get(eigrls, string(method_sid), nothing)
        eigrl isa AbstractDict || continue
        max_v2 = max(max_v2, Float64(get(eigrl, "V2", 0.0)))
    end
    return max_v2
end

@inline function q4_static_component_v2_ok(eigrl_v2::Float64,
                                           v2_min::Float64,
                                           v2_max::Float64)
    v2_min <= 0.0 && v2_max <= 0.0 && return true
    eigrl_v2 > 0.0 || return false
    return (v2_min <= 0.0 || eigrl_v2 >= v2_min) &&
           (v2_max <= 0.0 || eigrl_v2 <= v2_max)
end



@inline function kg_quad4_sigma_mean_nxx(sigma_mem_input)
    if sigma_mem_input isa AbstractMatrix
        acc = 0.0
        @inbounds for gp in 1:size(sigma_mem_input, 1)
            acc += sigma_mem_input[gp, 1]
        end
        return acc / max(size(sigma_mem_input, 1), 1)
    else
        return sigma_mem_input[1]
    end
end


@inline function kg_quad4_sigma_principal_min_resultant(sxx::Float64, syy::Float64, sxy::Float64, h::Float64)
    nxx = sxx * h
    nyy = syy * h
    nxy = sxy * h
    mean_n = 0.5 * (nxx + nyy)
    half_d = 0.5 * (nxx - nyy)
    return mean_n - sqrt(half_d * half_d + nxy * nxy)
end

@inline function kg_quad4_sigma_gp_nxx_spread_resultant(sigma_mem_input, h::Float64)
    if sigma_mem_input isa AbstractMatrix
        lo = Inf
        hi = -Inf
        @inbounds for gp in 1:size(sigma_mem_input, 1)
            nxx = sigma_mem_input[gp, 1] * h
            lo = min(lo, nxx)
            hi = max(hi, nxx)
        end
        return isfinite(lo) && isfinite(hi) ? hi - lo : 0.0
    end
    return 0.0
end

@inline function kg_quad4_sigma_gp_pmin_spread_resultant(sigma_mem_input, h::Float64)
    if sigma_mem_input isa AbstractMatrix
        lo = Inf
        hi = -Inf
        @inbounds for gp in 1:size(sigma_mem_input, 1)
            pmin = kg_quad4_sigma_principal_min_resultant(
                sigma_mem_input[gp, 1],
                sigma_mem_input[gp, 2],
                sigma_mem_input[gp, 3],
                h,
            )
            lo = min(lo, pmin)
            hi = max(hi, pmin)
        end
        return isfinite(lo) && isfinite(hi) ? hi - lo : 0.0
    end
    return 0.0
end


@inline function kg_quad4_pid_membrane_effective_scale(pid_scale::Float64,
                                                       sign_gate::Symbol,
                                                       sigma_mem_input,
                                                       h::Float64,
                                                       gp_pmin_spread_min::Float64,
                                                       gp_nxx_spread_min::Float64,
                                                       gp_spread_factor::Float64)
    pid_scale == 1.0 && return 1.0
    nxx = kg_quad4_sigma_mean_nxx(sigma_mem_input)
    if sign_gate === :any
        return pid_scale
    elseif sign_gate === :positive
        return nxx > 0.0 ? pid_scale : 1.0
    elseif sign_gate === :negative
        return nxx < 0.0 ? pid_scale : 1.0
    elseif sign_gate === :positive_or_gp_pmin_spread
        nxx > 0.0 && return pid_scale
        spread_ok = kg_quad4_sigma_gp_pmin_spread_resultant(sigma_mem_input, h) >= gp_pmin_spread_min
        return spread_ok ? 1.0 + (pid_scale - 1.0) * gp_spread_factor : 1.0
    elseif sign_gate === :positive_or_gp_nxx_spread
        nxx > 0.0 && return pid_scale
        spread_ok = kg_quad4_sigma_gp_nxx_spread_resultant(sigma_mem_input, h) >= gp_nxx_spread_min
        return spread_ok ? 1.0 + (pid_scale - 1.0) * gp_spread_factor : 1.0
    elseif sign_gate === :positive_or_gp_spread
        nxx > 0.0 && return pid_scale
        pmin_ok = kg_quad4_sigma_gp_pmin_spread_resultant(sigma_mem_input, h) >= gp_pmin_spread_min
        nxx_ok = kg_quad4_sigma_gp_nxx_spread_resultant(sigma_mem_input, h) >= gp_nxx_spread_min
        return (pmin_ok || nxx_ok) ? 1.0 + (pid_scale - 1.0) * gp_spread_factor : 1.0
    end
    return 1.0
end

@inline function kg_shell_pcomp_nxy_scale()
    return solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SCALE", 1.0)
end

@inline function kg_shell_pcomp_nxy_aspect_scale_enabled()
    return solver_env_bool("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_SCALE", false)
end

@inline function kg_shell_pcomp_nxy_aspect_low()
    return solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_LOW", 0.70)
end

@inline function kg_shell_pcomp_nxy_aspect_high()
    return solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_HIGH", 1.70)
end

@inline function kg_shell_pcomp_nxy_aspect_mid()
    return solver_env_float(
        "JFEM_KG_SHELL_PCOMP_NXY_ASPECT_MID",
        kg_shell_pcomp_nxy_aspect_high(),
    )
end

@inline function kg_shell_pcomp_nxy_aspect_min()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_MIN", 2.5), 1.0)
end

@inline function kg_shell_pcomp_nxy_aspect_peak()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_PEAK", 4.0), 1.0)
end

@inline function kg_shell_pcomp_nxy_aspect_max()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_ASPECT_MAX", 4.0), 1.0)
end

@inline function kg_shell_pcomp_nxy_aspect_mode()
    raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_PCOMP_NXY_ASPECT_MODE", "ramp")))
    return raw in ("band", "window", "tent") ? :band : :ramp
end

@inline function kg_shell_pcomp_nxy_compression_only()
    return solver_env_bool("JFEM_KG_SHELL_PCOMP_NXY_COMPRESSION_ONLY", false)
end

@inline function kg_shell_pcomp_nxy_shear_dom_relax()
    return clamp(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_RELAX", 0.0), 0.0, 1.0)
end

@inline function kg_shell_pcomp_nxy_shear_dom_ratio_min()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_RATIO_MIN", 1.5), 0.0)
end

@inline function kg_shell_pcomp_nxy_shear_dom_ratio_full()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_RATIO_FULL", 4.0), 1e-12)
end

@inline function kg_shell_pcomp_nxy_shear_dom_aspect_min()
    return max(solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_ASPECT_MIN", 1.0), 1.0)
end

@inline function kg_shell_pcomp_nxy_shear_dom_aspect_max()
    return max(
        solver_env_float("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_ASPECT_MAX", 1e30),
        kg_shell_pcomp_nxy_shear_dom_aspect_min(),
    )
end

@inline function kg_shell_pcomp_nxy_shear_dom_compression_only()
    return solver_env_bool("JFEM_KG_SHELL_PCOMP_NXY_SHEAR_DOM_COMPRESSION_ONLY", false)
end

@inline function kg_shell_pcomp_nxy_aspect_scale(aspect::Float64,
                                                low_scale::Float64,
                                                high_scale::Float64,
                                                aspect_min::Float64,
                                                aspect_max::Float64)
    if aspect_max <= aspect_min
        return aspect >= aspect_min ? high_scale : low_scale
    end
    t = clamp((aspect - aspect_min) / (aspect_max - aspect_min), 0.0, 1.0)
    return (1.0 - t) * low_scale + t * high_scale
end

@inline function kg_shell_pcomp_nxy_aspect_scale(aspect::Float64,
                                                mode::Symbol,
                                                low_scale::Float64,
                                                mid_scale::Float64,
                                                high_scale::Float64,
                                                aspect_min::Float64,
                                                aspect_peak::Float64,
                                                aspect_max::Float64)
    if mode === :band
        if aspect <= aspect_min
            return low_scale
        elseif aspect >= aspect_max
            return high_scale
        elseif aspect <= aspect_peak
            denom = max(aspect_peak - aspect_min, 1e-12)
            t = clamp((aspect - aspect_min) / denom, 0.0, 1.0)
            return (1.0 - t) * low_scale + t * mid_scale
        else
            denom = max(aspect_max - aspect_peak, 1e-12)
            t = clamp((aspect - aspect_peak) / denom, 0.0, 1.0)
            return (1.0 - t) * mid_scale + t * high_scale
        end
    end
    return kg_shell_pcomp_nxy_aspect_scale(
        aspect,
        low_scale,
        high_scale,
        aspect_min,
        aspect_max,
    )
end




@inline function q4_mitc4_3d_aspect_skew_min()
    return max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_SKEW_MIN", 0.0), 0.0)
end

@inline function q4_mitc4_3d_aspect_skew_max()
    return max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_SKEW_MAX", 180.0), 0.0)
end

@inline function q4_mitc4_3d_aspect_skew_aspect_min()
    return max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_SKEW_ASPECT_MIN", 0.0), 0.0)
end



@inline function q4_local_max_edge_length(lc::AbstractMatrix)
    p1 = SVector{2,Float64}(lc[1,1], lc[1,2])
    p2 = SVector{2,Float64}(lc[2,1], lc[2,2])
    p3 = SVector{2,Float64}(lc[3,1], lc[3,2])
    p4 = SVector{2,Float64}(lc[4,1], lc[4,2])
    return max(norm(p2 - p1), norm(p3 - p2), norm(p4 - p3), norm(p1 - p4))
end

@inline function q4_mitc4_3d_aspect_geom_ok(
    aspect::Float64,
    warp_ratio::Float64,
    kappa_l::Float64,
    edge_skew::Float64,
    aspect_min::Float64,
    aspect_max::Float64,
    warp_min::Float64,
    warp_max::Float64,
    kappa_l_min::Float64,
    kappa_l_max::Float64,
    skew_min::Float64,
    skew_max::Float64,
    skew_aspect_min::Float64,
)
    skew_gate_ok =
        aspect < skew_aspect_min ||
        (edge_skew >= skew_min && edge_skew <= skew_max)
    return aspect >= aspect_min &&
           aspect <= aspect_max &&
           warp_ratio >= warp_min &&
           warp_ratio <= warp_max &&
           kappa_l >= kappa_l_min &&
           kappa_l <= kappa_l_max &&
           skew_gate_ok
end

@inline function kg_shell_surface_operator_mode()
    if !haskey(ENV, "JFEM_KG_SHELL_SURFACE_OPERATOR") &&
       q4_eig_curved_jacobian_enabled()
        return :covariant
    end
    raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_SURFACE_OPERATOR", "flat")))
    if raw in ("covariant", "surface", "metric")
        return :covariant
    end
    return :flat
end

@inline function kg_shell_nxy_auto_relax()
    return clamp(solver_env_float("JFEM_KG_SHELL_NXY_AUTO_RELAX", 0.0), 0.0, 1.0)
end

@inline function kg_shell_drill_zero_enabled()
    # MSC/Nastran CQUAD4 differential stiffness is a five-DOF shell operator;
    # the drilling direction is stabilized in K, not prestressed in Kg.
    return solver_env_bool("JFEM_KG_SHELL_DRILL_ZERO", true)
end

@inline function kg_shell_nxy_auto_ratio_min()
    return max(solver_env_float("JFEM_KG_SHELL_NXY_AUTO_RATIO_MIN", 1.5), 0.0)
end

@inline function kg_shell_nxy_auto_ratio_full()
    return max(solver_env_float("JFEM_KG_SHELL_NXY_AUTO_RATIO_FULL", 4.0), 1e-12)
end

@inline function kg_shell_nxy_auto_cyl_ratio_max()
    return clamp(solver_env_float("JFEM_KG_SHELL_NXY_AUTO_CYL_RATIO_MAX", 1.0), 0.0, 1.0)
end

@inline function kg_shell_nxy_auto_kappa_l_min()
    return max(solver_env_float("JFEM_KG_SHELL_NXY_AUTO_KAPPA_L_MIN", 0.0), 0.0)
end

@inline function kg_shell_nxy_auto_scale(sxx::Float64, syy::Float64, sxy::Float64,
                                         relax::Float64, ratio_min::Float64, ratio_full::Float64)
    relax <= 0.0 && return 1.0
    denom = abs(sxx) + abs(syy)
    shear_ratio = abs(sxy) / max(denom, 1e-12)
    if ratio_full <= ratio_min
        alpha = shear_ratio >= ratio_min ? 1.0 : 0.0
    else
        alpha = clamp((shear_ratio - ratio_min) / (ratio_full - ratio_min), 0.0, 1.0)
    end
    return max(0.0, 1.0 - relax * alpha)
end

@inline function kg_shell_pcomp_should_scale_nxy(sxx::Float64, syy::Float64, compression_only::Bool)
    return !compression_only || (sxx + syy < 0.0)
end

@inline function kg_shell_apply_pcomp_nxy_scale!(sigma_mem::AbstractMatrix, scale::Float64, compression_only::Bool)
    scale == 1.0 && return
    @inbounds for gp in 1:size(sigma_mem, 1)
        if kg_shell_pcomp_should_scale_nxy(sigma_mem[gp, 1], sigma_mem[gp, 2], compression_only)
            sigma_mem[gp, 3] *= scale
        end
    end
end

@inline function kg_shell_apply_pcomp_nxy_scale!(sigma_mem::AbstractVector, scale::Float64, compression_only::Bool)
    scale == 1.0 && return
    if kg_shell_pcomp_should_scale_nxy(sigma_mem[1], sigma_mem[2], compression_only)
        sigma_mem[3] *= scale
    end
end

@inline function kg_shell_apply_pcomp_nxy_shear_dom_scale!(sigma_mem::AbstractMatrix,
                                                           relax::Float64,
                                                           ratio_min::Float64,
                                                           ratio_full::Float64,
                                                           aspect::Float64,
                                                           aspect_min::Float64,
                                                           aspect_max::Float64,
                                                           compression_only::Bool)
    (relax > 0.0 && aspect >= aspect_min && aspect <= aspect_max) || return
    @inbounds for gp in 1:size(sigma_mem, 1)
        if kg_shell_pcomp_should_scale_nxy(sigma_mem[gp, 1], sigma_mem[gp, 2], compression_only)
            sigma_mem[gp, 3] *= kg_shell_nxy_auto_scale(
                sigma_mem[gp, 1],
                sigma_mem[gp, 2],
                sigma_mem[gp, 3],
                relax,
                ratio_min,
                ratio_full,
            )
        end
    end
end

@inline function kg_shell_apply_pcomp_nxy_shear_dom_scale!(sigma_mem::AbstractVector,
                                                           relax::Float64,
                                                           ratio_min::Float64,
                                                           ratio_full::Float64,
                                                           aspect::Float64,
                                                           aspect_min::Float64,
                                                           aspect_max::Float64,
                                                           compression_only::Bool)
    (relax > 0.0 && aspect >= aspect_min && aspect <= aspect_max) || return
    if kg_shell_pcomp_should_scale_nxy(sigma_mem[1], sigma_mem[2], compression_only)
        sigma_mem[3] *= kg_shell_nxy_auto_scale(
            sigma_mem[1],
            sigma_mem[2],
            sigma_mem[3],
            relax,
            ratio_min,
            ratio_full,
        )
    end
end


"""
    nastran_k6rot_default(model)

The drilling-DOF stabilisation coefficient a deck gets when it declares no
`PARAM,K6ROT`, matching the reference solver.

MSC/Nastran 70.5 has no single global default -- its own delivery source says so
outright (`msc705/nast/del/param.ddl:142-143`: *"K6ROT MUST NOT BE DEFINED HERE
BECAUSE ITS DEFAULT VALUE IS DIFFERENT ACROSS SOLUTION SEQUENCES"*). The value is
declared per subDMAP: `K6ROT=0.` in every linear sequence (`sestatic.dat:44` for
SOL 101, `semodes.dat:46` for 103, `sebuckl.dat:42` for 105, and likewise for
107-112, 114-118, 144-146, 200), and `K6ROT=100.` only in the nonlinear ones
(`nlstatic.dat:67` for SOL 106, `nltran.dat:69` for 129).

OpenJFEM previously defaulted to a flat 100.0 everywhere. On a deck that declares
nothing that silently ran a different problem from the reference -- worth up to
3.5% on the MacNeal hemisphere, where it was mistaken for a formulation gap until
2026-08-04. Matching the reference per sequence removes the discrepancy at its
source. A deck that declares `PARAM,K6ROT` is unaffected, as is the
`JFEM_PARAM_K6ROT*` environment override.
"""
@inline function nastran_k6rot_default(model)
    sol = Int(round(Float64(get(model, "SOL", get(model, "sol_type", 101)))))
    return (sol == 106 || sol == 129) ? 100.0 : 0.0
end

@inline function solver_k6rot(default::Real, shear_center_only::Bool)
    primary_key = shear_center_only ? "JFEM_PARAM_K6ROT_EIG" : "JFEM_PARAM_K6ROT_STATIC"
    raw = get(ENV, primary_key, get(ENV, "JFEM_PARAM_K6ROT", ""))
    default_val = Float64(default)
    if isempty(strip(raw))
        return default_val
    end
    return something(tryparse(Float64, raw), default_val)
end

@inline function shell_transverse_shear_matrix(mat, h::Real, tst::Real, theta::Real=0.0)
    h_eff = Float64(h)
    tst_eff = Float64(tst)
    theta_eff = Float64(theta)
    mtype = get(mat, "TYPE", "")
    if mtype == "MAT8" && haskey(mat, "G12")
        G1Z = Float64(get(mat, "G1Z", 0.0))
        G2Z = Float64(get(mat, "G2Z", 0.0))
        G12 = Float64(get(mat, "G12", 0.0))
        G1Z <= 0.0 && (G1Z = G12)
        G2Z <= 0.0 && (G2Z = G12)
        if abs(theta_eff) > 1e-10
            ct = cos(theta_eff)
            st = sin(theta_eff)
            return tst_eff * h_eff .* [
                ct^2 * G1Z + st^2 * G2Z  ct * st * (G1Z - G2Z);
                ct * st * (G1Z - G2Z)   st^2 * G1Z + ct^2 * G2Z
            ], max(G1Z, G2Z)
        end
        return tst_eff * h_eff .* [G1Z 0.0; 0.0 G2Z], max(G1Z, G2Z)
    elseif mtype == "MAT2" && haskey(mat, "G11")
        Gxz = Float64(get(mat, "G13", 0.0))
        Gyz = Float64(get(mat, "G23", 0.0))
        if Gxz <= 0.0 && Gyz <= 0.0
            Gxz = Float64(get(mat, "G33", 0.0))
            Gyz = Gxz
        elseif Gxz <= 0.0
            Gxz = Gyz
        elseif Gyz <= 0.0
            Gyz = Gxz
        end
        if abs(theta_eff) > 1e-10
            ct = cos(theta_eff)
            st = sin(theta_eff)
            return tst_eff * h_eff .* [
                ct^2 * Gxz + st^2 * Gyz  ct * st * (Gxz - Gyz);
                ct * st * (Gxz - Gyz)   st^2 * Gxz + ct^2 * Gyz
            ], max(Gxz, Gyz)
        end
        return tst_eff * h_eff .* [Gxz 0.0; 0.0 Gyz], max(Gxz, Gyz)
    end

    G_val = Float64(get(mat, "G", 0.0))
    if G_val <= 0.0
        E_val = Float64(get(mat, "E", 0.0))
        nu_val = Float64(get(mat, "NU", 0.0))
        G_val = E_val > 0.0 ? E_val / (2 * (1 + nu_val)) : 0.0
    end
    return tst_eff * h_eff .* [G_val 0.0; 0.0 G_val], G_val
end

@inline function pshell_mid4_bmb_matrix(mat, h::Real, theta::Real=0.0)
    h_eff = Float64(h)
    scale = solver_env_float("JFEM_PSHELL_MID4_BMB_SCALE", 1.0) * h_eff^2 / 4.0
    sign = solver_env_float("JFEM_PSHELL_MID4_BMB_SIGN", 1.0)
    theta_eff = Float64(theta)
    mtype = get(mat, "TYPE", "")
    if mtype == "MAT8" && haskey(mat, "E1")
        E1 = Float64(mat["E1"]); E2 = Float64(mat["E2"])
        nu12 = Float64(mat["NU12"]); G12 = Float64(mat["G12"])
        nu21 = nu12 * E2 / max(E1, 1e-30)
        denom = 1.0 - nu12 * nu21
        Q11 = E1 / denom; Q22 = E2 / denom; Q12 = nu12 * E2 / denom; Q66 = G12
        Q16 = 0.0; Q26 = 0.0
        if abs(theta_eff) > 1e-10
            ct = cos(theta_eff); st = sin(theta_eff); c2 = ct^2; s2 = st^2
            Q11r = Q11*c2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*s2^2
            Q22r = Q11*s2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*c2^2
            Q12r = (Q11+Q22-4*Q66)*c2*s2 + Q12*(c2^2+s2^2)
            Q16 = (Q11-Q12-2*Q66)*ct*st*c2 + (Q12-Q22+2*Q66)*ct*st*s2
            Q26 = (Q11-Q12-2*Q66)*ct*st*s2 + (Q12-Q22+2*Q66)*ct*st*c2
            Q66 = (Q11+Q22-2*Q12-2*Q66)*c2*s2 + Q66*(c2^2+s2^2)
            Q11 = Q11r; Q22 = Q22r; Q12 = Q12r
        end
        return sign * scale .* [Q11 Q12 Q16; Q12 Q22 Q26; Q16 Q26 Q66]
    elseif mtype == "MAT2" && haskey(mat, "G11")
        return sign * scale .* [
            Float64(get(mat, "G11", 0.0)) Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G13", 0.0));
            Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G22", 0.0)) Float64(get(mat, "G23", 0.0));
            Float64(get(mat, "G13", 0.0)) Float64(get(mat, "G23", 0.0)) Float64(get(mat, "G33", 0.0))
        ]
    end
    E_val = Float64(get(mat, "E", 0.0))
    nu_val = Float64(get(mat, "NU", 0.0))
    if E_val <= 0.0
        G_val = Float64(get(mat, "G", 0.0))
        E_val = G_val > 0.0 ? 2.0 * G_val * (1.0 + nu_val) : 0.0
    end
    plane_coeff = E_val / max(1.0 - nu_val^2, 1e-30)
    return sign * scale * plane_coeff .* [
        1.0 nu_val 0.0;
        nu_val 1.0 0.0;
        0.0 0.0 (1.0 - nu_val) / 2.0
    ]
end

@inline function pshell_bending_constitutive_matrix(mat, h::Real, bend_ratio::Real, theta::Real=0.0)
    h_eff = Float64(h)
    br_eff = Float64(bend_ratio)
    Cb = zeros(3, 3)
    (mat === nothing || h_eff <= 0.0 || br_eff <= 1e-12) && return Cb

    coeff = br_eff * h_eff^3 / 12.0
    theta_eff = Float64(theta)
    mtype = get(mat, "TYPE", "")

    if mtype == "MAT8" && haskey(mat, "E1") && haskey(mat, "E2")
        E1 = Float64(mat["E1"])
        E2 = Float64(mat["E2"])
        nu12 = Float64(mat["NU12"])
        G12 = Float64(mat["G12"])
        nu21 = nu12 * E2 / max(E1, 1e-30)
        denom = 1.0 - nu12 * nu21
        Q11 = E1 / denom
        Q22 = E2 / denom
        Q12 = nu12 * E2 / denom
        Q66 = G12
        Q16 = 0.0
        Q26 = 0.0
        if abs(theta_eff) > 1e-10
            ct = cos(theta_eff)
            st = sin(theta_eff)
            c2 = ct^2
            s2 = st^2
            Q11r = Q11*c2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*s2^2
            Q22r = Q11*s2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*c2^2
            Q12r = (Q11+Q22-4*Q66)*c2*s2 + Q12*(c2^2+s2^2)
            Q16 = (Q11-Q12-2*Q66)*ct*st*c2 + (Q12-Q22+2*Q66)*ct*st*s2
            Q26 = (Q11-Q12-2*Q66)*ct*st*s2 + (Q12-Q22+2*Q66)*ct*st*c2
            Q66 = (Q11+Q22-2*Q12-2*Q66)*c2*s2 + Q66*(c2^2+s2^2)
            Q11 = Q11r
            Q22 = Q22r
            Q12 = Q12r
        end
        return coeff .* [Q11 Q12 Q16; Q12 Q22 Q26; Q16 Q26 Q66]
    elseif mtype == "MAT2" && haskey(mat, "G11")
        return coeff .* [
            Float64(get(mat, "G11", 0.0)) Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G13", 0.0));
            Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G22", 0.0)) Float64(get(mat, "G23", 0.0));
            Float64(get(mat, "G13", 0.0)) Float64(get(mat, "G23", 0.0)) Float64(get(mat, "G33", 0.0))
        ]
    end

    E_val = Float64(get(mat, "E", 0.0))
    nu_val = Float64(get(mat, "NU", 0.0))
    if E_val <= 0.0
        G_val = Float64(get(mat, "G", 0.0))
        E_val = G_val > 0.0 ? 2.0 * G_val * (1.0 + nu_val) : 0.0
    end
    plane_coeff = E_val / max(1.0 - nu_val^2, 1e-30)
    return coeff * plane_coeff .* [
        1.0 nu_val 0.0;
        nu_val 1.0 0.0;
        0.0 0.0 (1.0 - nu_val) / 2.0
    ]
end

@inline function pcomp_metric_ratios(prop, theta_rad::Float64)
    Cm_metric = copy(prop["Cm"])
    Cb_metric = copy(prop["Cb"])
    Bmb_metric = haskey(prop, "Bmb") && prop["Bmb"] !== nothing ? copy(prop["Bmb"]) : nothing
    if abs(theta_rad) > 1e-10
        cb = cos(theta_rad); sb = sin(theta_rad)
        c2 = cb^2; s2 = sb^2; cs = cb*sb
        T11 = c2;  T12 = s2;  T13 = cs
        T21 = s2;  T22 = c2;  T23 = -cs
        T31 = -2cs; T32 = 2cs; T33 = c2 - s2
        _rotate_constitutive_3x3!(Cm_metric, T11, T12, T13, T21, T22, T23, T31, T32, T33)
        _rotate_constitutive_3x3!(Cb_metric, T11, T12, T13, T21, T22, T23, T31, T32, T33)
        if Bmb_metric !== nothing
            _rotate_constitutive_3x3!(Bmb_metric, T11, T12, T13, T21, T22, T23, T31, T32, T33)
        end
    end
    shear_ratio = abs(Cm_metric[3,3]) / max(0.5 * (abs(Cm_metric[1,1]) + abs(Cm_metric[2,2])), 1e-30)
    d16_ratio = sqrt(Cb_metric[1,3]^2 + Cb_metric[2,3]^2) / max(maximum(abs.(Cb_metric)), 1e-30)
    b_ratio = Bmb_metric === nothing ? 0.0 : maximum(abs.(Bmb_metric)) / max(maximum(abs.(Cm_metric)), 1e-30)
    return shear_ratio, d16_ratio, b_ratio
end

@inline function pcomp_abs_angle_fraction_from_plies(plies, angle_deg::Float64)
    plies isa AbstractVector || return 0.0
    nplies = length(plies)
    nplies == 0 && return 0.0
    count_angle = 0
    @inbounds for ply in plies
        theta = abs(Float64(get(ply, "theta", 0.0)))
        if abs(theta - angle_deg) <= 1.0e-6
            count_angle += 1
        end
    end
    return count_angle / nplies
end

@inline function pcomp_abs_angle_fraction(prop, angle_deg::Float64)
    return pcomp_abs_angle_fraction_from_plies(get(prop, "PLY_DATA", nothing), angle_deg)
end

@inline function pcomp_ply_thickness_value(ply)
    if haskey(ply, "T")
        return max(Float64(ply["T"]), 0.0)
    elseif haskey(ply, "t")
        return max(Float64(ply["t"]), 0.0)
    elseif haskey(ply, "z_top") && haskey(ply, "z_bot")
        return max(Float64(ply["z_top"]) - Float64(ply["z_bot"]), 0.0)
    end
    return 1.0
end

@inline function pcomp_angle_distance_180(theta_deg::Float64, target_deg::Float64)
    d = mod(theta_deg - target_deg + 90.0, 180.0) - 90.0
    return abs(d)
end

function pcomp_orientation_thickness_descriptors_from_plies(plies; tol_deg::Float64=2.5)
    if !(plies isa AbstractVector) || isempty(plies)
        return (
            frac0=0.0, frac90=0.0, fracp45=0.0, fracm45=0.0,
            fracpm45=0.0, frac090=0.0, pm45_signed=0.0, pm45_balance=0.0,
            orient_cos2=0.0, orient_sin2=0.0, orient_cos4=0.0, orient_sin4=0.0,
        )
    end
    total = 0.0
    f0 = 0.0; f90 = 0.0; fp45 = 0.0; fm45 = 0.0
    c2 = 0.0; s2 = 0.0; c4 = 0.0; s4 = 0.0
    @inbounds for ply in plies
        w = pcomp_ply_thickness_value(ply)
        w > 0.0 || continue
        theta = Float64(get(ply, "theta", get(ply, "THETA", 0.0)))
        total += w
        pcomp_angle_distance_180(theta, 0.0) <= tol_deg && (f0 += w)
        pcomp_angle_distance_180(theta, 90.0) <= tol_deg && (f90 += w)
        pcomp_angle_distance_180(theta, 45.0) <= tol_deg && (fp45 += w)
        pcomp_angle_distance_180(theta, -45.0) <= tol_deg && (fm45 += w)
        th = deg2rad(theta)
        c2 += w * cos(2.0 * th)
        s2 += w * sin(2.0 * th)
        c4 += w * cos(4.0 * th)
        s4 += w * sin(4.0 * th)
    end
    if total <= 0.0
        return (
            frac0=0.0, frac90=0.0, fracp45=0.0, fracm45=0.0,
            fracpm45=0.0, frac090=0.0, pm45_signed=0.0, pm45_balance=0.0,
            orient_cos2=0.0, orient_sin2=0.0, orient_cos4=0.0, orient_sin4=0.0,
        )
    end
    inv_total = 1.0 / total
    frac0 = f0 * inv_total
    frac90 = f90 * inv_total
    fracp45 = fp45 * inv_total
    fracm45 = fm45 * inv_total
    fracpm45 = fracp45 + fracm45
    pm45_signed = fracp45 - fracm45
    return (
        frac0=frac0,
        frac90=frac90,
        fracp45=fracp45,
        fracm45=fracm45,
        fracpm45=fracpm45,
        frac090=frac0 + frac90,
        pm45_signed=pm45_signed,
        pm45_balance=abs(pm45_signed),
        orient_cos2=c2 * inv_total,
        orient_sin2=s2 * inv_total,
        orient_cos4=c4 * inv_total,
        orient_sin4=s4 * inv_total,
    )
end

@inline function pcomp_orientation_thickness_descriptors(prop)
    return pcomp_orientation_thickness_descriptors_from_plies(get(prop, "PLY_DATA", nothing))
end

@inline function pcomp_ply_count_from_plies(plies)
    plies isa AbstractVector || return 0
    return length(plies)
end

@inline function pcomp_ply_count(prop)
    return pcomp_ply_count_from_plies(get(prop, "PLY_DATA", nothing))
end

@inline function pcomp_nemeth_parameters_from_cb(Cb, b_over_lambda::Float64=1.0)
    Cb isa AbstractMatrix || return (0.0, 0.0, 0.0, 0.0)
    size(Cb, 1) >= 3 && size(Cb, 2) >= 3 || return (0.0, 0.0, 0.0, 0.0)
    D11 = Float64(Cb[1, 1])
    D12 = Float64(Cb[1, 2])
    D16 = Float64(Cb[1, 3])
    D22 = Float64(Cb[2, 2])
    D26 = Float64(Cb[2, 3])
    D66 = Float64(Cb[3, 3])
    D11 > 0.0 && D22 > 0.0 || return (0.0, 0.0, 0.0, 0.0)
    sqrt_D11_D22 = sqrt(D11 * D22)
    alpha_inf = b_over_lambda * (D11 / D22)^0.25
    beta = (D12 + 2.0 * D66) / sqrt_D11_D22
    gamma = D16 / (D11^3 * D22)^0.25
    delta = D26 / (D11 * D22^3)^0.25
    if !(isfinite(alpha_inf) && isfinite(beta) && isfinite(gamma) && isfinite(delta))
        return (0.0, 0.0, 0.0, 0.0)
    end
    return (alpha_inf, beta, gamma, delta)
end

@inline function pcomp_nemeth_parameters(prop, b_over_lambda::Float64=1.0)
    prop isa AbstractDict || return (0.0, 0.0, 0.0, 0.0)
    haskey(prop, "Cb") || return (0.0, 0.0, 0.0, 0.0)
    return pcomp_nemeth_parameters_from_cb(prop["Cb"], b_over_lambda)
end

@inline function sol105_smoothstep01(x::Float64)
    t = clamp(x, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

@inline function kg_auto_pcomp_g12_candidate(theta_deg::Float64, shear_ratio::Float64, d16_ratio::Float64,
                                             b_ratio::Float64, kappa_l::Float64, cyl_ratio::Float64)
    if b_ratio > q4_pcomp_kg_auto_g12_b_ratio_max()
        return false
    end
    if shear_ratio < q4_pcomp_kg_auto_g12_shear_ratio_min() && d16_ratio < q4_pcomp_kg_auto_g12_d16_ratio_min()
        return false
    end
    if abs(theta_deg) < q4_pcomp_kg_auto_g12_theta_abs_min() &&
       d16_ratio < q4_pcomp_kg_auto_g12_d16_theta_bypass_min()
        return false
    end
    return kappa_l >= q4_pcomp_kg_auto_g12_kappa_l_min() &&
           cyl_ratio >= q4_pcomp_kg_auto_g12_cyl_ratio_min()
end

@inline function kg_auto_curvature_iso_candidate(kappa_l::Float64, cyl_ratio::Float64, aspect_ratio::Float64)
    return kappa_l >= q4_shell_kg_auto_curvature_iso_kappa_l_min() &&
           cyl_ratio >= q4_shell_kg_auto_curvature_iso_cyl_ratio_min() &&
           aspect_ratio <= q4_shell_kg_auto_curvature_iso_aspect_ratio_max()
end

@inline function kg_auto_curvature_iso_cyl_candidate(kappa_l::Float64, cyl_ratio::Float64, aspect_ratio::Float64)
    return q4_shell_kg_auto_curvature_iso_cyl_enabled() &&
           kappa_l >= q4_shell_kg_auto_curvature_iso_cyl_kappa_l_min() &&
           cyl_ratio <= q4_shell_kg_auto_curvature_iso_cyl_ratio_max() &&
           aspect_ratio <= q4_shell_kg_auto_curvature_iso_aspect_ratio_max()
end

@inline function kg_auto_curvature_pcomp_candidate(theta_deg::Float64, shear_ratio::Float64, d16_ratio::Float64,
                                                   b_ratio::Float64, kappa_l::Float64, cyl_ratio::Float64)
    if b_ratio > q4_pcomp_kg_auto_curvature_b_ratio_max()
        return false
    end
    if shear_ratio < q4_pcomp_kg_auto_curvature_shear_ratio_min() &&
       d16_ratio < q4_pcomp_kg_auto_curvature_d16_ratio_min()
        return false
    end
    if abs(theta_deg) < q4_pcomp_kg_auto_curvature_theta_abs_min() &&
       d16_ratio < q4_pcomp_kg_auto_curvature_d16_theta_bypass_min()
        return false
    end
    return kappa_l >= q4_pcomp_kg_auto_curvature_kappa_l_min() &&
           cyl_ratio >= q4_pcomp_kg_auto_curvature_cyl_ratio_min()
end

# In-place rotation of 3x3 constitutive matrix: C_out = T' * C * T
# where T = [T11 T12 T13; T21 T22 T23; T31 T32 T33] is the strain transformation
@inline function _rotate_constitutive_3x3!(C::Matrix{Float64},
    T11, T12, T13, T21, T22, T23, T31, T32, T33)
    t11 = C[1,1]*T11 + C[1,2]*T21 + C[1,3]*T31
    t12 = C[1,1]*T12 + C[1,2]*T22 + C[1,3]*T32
    t13 = C[1,1]*T13 + C[1,2]*T23 + C[1,3]*T33
    t21 = C[2,1]*T11 + C[2,2]*T21 + C[2,3]*T31
    t22 = C[2,1]*T12 + C[2,2]*T22 + C[2,3]*T32
    t23 = C[2,1]*T13 + C[2,2]*T23 + C[2,3]*T33
    t31 = C[3,1]*T11 + C[3,2]*T21 + C[3,3]*T31
    t32 = C[3,1]*T12 + C[3,2]*T22 + C[3,3]*T32
    t33 = C[3,1]*T13 + C[3,2]*T23 + C[3,3]*T33
    # C = T' * tmp
    C[1,1] = T11*t11 + T21*t21 + T31*t31
    C[1,2] = T11*t12 + T21*t22 + T31*t32
    C[1,3] = T11*t13 + T21*t23 + T31*t33
    C[2,1] = T12*t11 + T22*t21 + T32*t31
    C[2,2] = T12*t12 + T22*t22 + T32*t32
    C[2,3] = T12*t13 + T22*t23 + T32*t33
    C[3,1] = T13*t11 + T23*t21 + T33*t31
    C[3,2] = T13*t12 + T23*t22 + T33*t32
    C[3,3] = T13*t13 + T23*t23 + T33*t33
    return nothing
end

@inline function _node_dof_rotation(cord::AbstractDict, xg)
    u = Float64.(cord["U"])
    v = Float64.(cord["V"])
    w = Float64.(cord["W"])
    R = hcat(u, v, w)
    ctype = uppercase(string(get(cord, "TYPE", "RECTANGULAR")))
    ctype == "RECTANGULAR" && return R

    origin = Float64.(cord["Origin"])
    xloc = R' * (Float64.(xg) - origin)

    if ctype == "CYLINDRICAL"
        theta = atan(xloc[2], xloc[1])
        er = cos(theta) .* u .+ sin(theta) .* v
        et = -sin(theta) .* u .+ cos(theta) .* v
        return hcat(er, et, w)
    elseif ctype == "SPHERICAL"
        rxy = hypot(xloc[1], xloc[2])
        theta = atan(xloc[2], xloc[1])
        phi = atan(rxy, xloc[3])
        er_loc = [sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi)]
        et_loc = [-sin(theta), cos(theta), 0.0]
        ep_loc = [cos(phi) * cos(theta), cos(phi) * sin(theta), -sin(phi)]
        return R * hcat(er_loc, et_loc, ep_loc)
    end

    return R
end

function assemble_stiffness(model; bending_incomp::Bool=true, shear_center_only::Bool=false,
                            membrane_incomp::Bool=true, pcomp_membrane_incomp::Bool=false,
                            snorm_angle_override::Union{Nothing,Float64}=nothing,
                            iso_no_incomp::Bool=false,
                            sol105_context::Bool=false,
                            sol101_context::Bool=false,
                            elem_shear_dominant::Union{Nothing,Dict{Int,Bool}}=nothing)
    # JFEM_Q4_STATIC_BENDING_INCOMP: optional override of the bending
    # incompatible-mode enrichment on the static/pencil assembly path (the
    # eigen path has its own JFEM_SOL105_EIG_BENDING_INCOMP).  Unset by
    # default (argument wins).  Part of the reference-matched element set:
    # the reference CQUAD4 bending is reproduced exactly WITHOUT the
    # rotation-bubble enrichment (see k_extract_boxes_laminates_20260704).
    if !shear_center_only && haskey(ENV, "JFEM_Q4_STATIC_BENDING_INCOMP")
        bending_incomp = solver_env_bool("JFEM_Q4_STATIC_BENDING_INCOMP", bending_incomp)
    end
    # Snapshot every JFEM_* env var for the element loops (lock-free reads
    # on the threaded paths; see FEM.env_snapshot_begin!). Cleared before
    # return; an escaping exception aborts the solve and the next assembly
    # re-snapshots, same exposure as the BLAS-thread pin/restore below.
    FEM.env_snapshot_begin!()
    log_msg("[SOLVER] Indexing...")
    ids = sort(collect(keys(model["GRIDs"])), by=x->parse(Int,x))
    n_nodes = length(ids)
    id_map = Dict(parse(Int, k)=>i for (i,k) in enumerate(ids))
    ndof = n_nodes * 6

    node_R = Vector{Matrix{Float64}}(undef, n_nodes)
    node_coords = zeros(n_nodes, 3)

    for (sid, g) in model["GRIDs"]
        idx = id_map[g["ID"]]
        node_coords[idx, :] = g["X"]
        cid = g["CD"]
        if cid == 0
            node_R[idx] = Matrix(1.0I, 3, 3)
        elseif haskey(model["CORDs"], string(cid))
            c = model["CORDs"][string(cid)]
            node_R[idx] = _node_dof_rotation(c, g["X"])
        else
             node_R[idx] = Matrix(1.0I, 3, 3)
        end
    end

    snorm_override_key = shear_center_only ? "JFEM_PARAM_SNORM_OVERRIDE_EIG" : "JFEM_PARAM_SNORM_OVERRIDE_STATIC"
    snorm_override = isnothing(snorm_angle_override) ?
        get(ENV, snorm_override_key, get(ENV, "JFEM_PARAM_SNORM_OVERRIDE", "")) :
        string(snorm_angle_override)
    snorm_model = model
    if !isempty(strip(snorm_override))
        snorm_model = copy(model)
        snorm_model["PARAM_SNORM"] = something(tryparse(Float64, snorm_override), get(model, "PARAM_SNORM", 0.0))
    end
    snorm_normals = compute_snorm_normals(snorm_model, id_map, node_coords)
    q4_frame_mode = q4_frame_mode_from_env(shear_center_only ? "JFEM_Q4_FRAME_MODE_EIG" : "JFEM_Q4_FRAME_MODE_STATIC")
    pcomp_axis_mode_primary_key = shear_center_only ? "JFEM_Q4_PCOMP_AXIS_MODE_EIG" : "JFEM_Q4_PCOMP_AXIS_MODE_STATIC"
    pcomp_axis_mode = q4_pcomp_axis_mode(pcomp_axis_mode_primary_key)
    pcomp_axis_mode_override = haskey(ENV, pcomp_axis_mode_primary_key) || haskey(ENV, "JFEM_Q4_PCOMP_AXIS_MODE")
    curved_iso_blend = curved_iso_eig_fullshear_blend()
    curved_iso_square_blend = q4_curved_iso_square_fullshear_blend_enabled() ? q4_curved_iso_square_fullshear_blend_value() : 1.0
    curved_iso_square_blend_aspect_ratio_max = q4_curved_iso_square_fullshear_blend_aspect_ratio_max()
    curved_pcomp_blend = curved_pcomp_eig_fullshear_blend()
    flat_pcomp_no_phi2_override = solver_env_optional_bool("JFEM_SOL105_EIG_FLAT_PCOMP_NO_PHI2")
    flat_pcomp_plate_branch = shear_center_only && q4_sol105_flat_pcomp_plate_branch_enabled()
    flat_pcomp_dkmq_branch = (shear_center_only || q4_sol105_flat_pcomp_dkmq_static_enabled()) &&
                             q4_sol105_flat_pcomp_dkmq_enabled()
    flat_pcomp_plate_auto = shear_center_only && q4_sol105_flat_pcomp_plate_auto_enabled()
    flat_pcomp_plate_auto_d16_ratio_max = q4_sol105_flat_pcomp_plate_auto_d16_ratio_max()
    flat_pcomp_plate_auto_shear_ratio_max = q4_sol105_flat_pcomp_plate_auto_shear_ratio_max()
    flat_pcomp_rect_adini = shear_center_only && q4_sol105_flat_pcomp_rect_adini_enabled()
    flat_pcomp_fullshear_selective = solver_env_bool("JFEM_SOL105_EIG_FLAT_PCOMP_FULLSHEAR_SELECTIVE", false)
    flat_pcomp_exact_membrane = shear_center_only && q4_sol105_flat_pcomp_exact_membrane()
    sol101_flat_pcomp_exact_membrane =
        sol101_context && !shear_center_only &&
        solver_env_bool("JFEM_SOL101_Q4_PCOMP_EXACT_MEMBRANE", false)
    sol105_static_pcomp_exact_membrane =
        sol105_context && !shear_center_only &&
        solver_env_bool("JFEM_SOL105_STATIC_PCOMP_EXACT_MEMBRANE", false)
    sol101_flat_iso_exact_membrane =
        sol101_context && !shear_center_only &&
        solver_env_bool("JFEM_SOL101_Q4_ISO_EXACT_MEMBRANE", false)
    flat_pcomp_exact_side_shear = q4_sol105_flat_pcomp_exact_side_shear()
    flat_curved_pcomp_exact_side_shear = q4_sol105_flat_curved_pcomp_exact_side_shear()
    flat_pcomp_exact_side_rotcorr = q4_sol105_flat_pcomp_exact_side_rotcorr()
    flat_iso_exact_side_shear = q4_sol105_flat_iso_exact_side_shear()
    flat_pcomp_auto_g12 = shear_center_only && !pcomp_axis_mode_override && q4_flat_pcomp_auto_g12_enabled()
    flat_pcomp_auto_g12_kappa_l_max = q4_flat_pcomp_auto_g12_kappa_l_max()
    flat_pcomp_auto_g12_cyl_ratio_max = q4_flat_pcomp_auto_g12_cyl_ratio_max()
    curved_iso_eig_membrane_incomp = shear_center_only && q4_curved_iso_eig_auto_membrane_incomp_enabled()
    curved_iso_eig_membrane_incomp_kappa_l_min = q4_curved_iso_eig_auto_membrane_incomp_kappa_l_min()
    curved_iso_eig_membrane_incomp_cyl_ratio_max = q4_curved_iso_eig_auto_membrane_incomp_cyl_ratio_max()
    curved_iso_warp_membrane_incomp = shear_center_only && q4_curved_iso_warp_membrane_incomp_enabled()
    curved_iso_warp_membrane_incomp_ratio_min = q4_curved_iso_warp_membrane_incomp_ratio_min()
    curved_iso_warp_membrane_incomp_kappa_l_max = q4_curved_iso_warp_membrane_incomp_kappa_l_max()
    curved_iso_elongated_membrane_incomp = shear_center_only && q4_curved_iso_elongated_membrane_incomp_enabled()
    curved_iso_elongated_membrane_incomp_aspect_ratio_min = q4_curved_iso_elongated_membrane_incomp_aspect_ratio_min()
    sol101_membrane_incomp_center_jacobian =
        sol101_context && !shear_center_only &&
        solver_env_bool("JFEM_SOL101_Q4_MEMBRANE_INCOMP_CENTER_JACOBIAN", true)
    membrane_incomp_center_jacobian =
        q4_sol105_membrane_incomp_center_jacobian_enabled() ||
        sol101_membrane_incomp_center_jacobian
    flat_iso_eig_membrane_incomp = q4_flat_iso_eig_membrane_incomp_enabled()
    flat_iso_eig_membrane_shear_center_row = q4_flat_iso_eig_membrane_shear_center_row_enabled()
    flat_iso_dkmq_branch = shear_center_only && q4_sol105_flat_iso_dkmq_enabled()
    flat_iso_fullshear_selective_mode = q4_flat_iso_fullshear_selective_mode()
    marguerre_static_coupling =
        !shear_center_only &&
        q4_marguerre_coupling_enabled() &&
        solver_env_bool("JFEM_Q4_MARGUERRE_STATIC_COUPLING", false)
    marguerre_coupling_enabled =
        (shear_center_only && q4_marguerre_coupling_enabled()) ||
        marguerre_static_coupling
    marguerre_static_use_geom_normals =
        marguerre_static_coupling &&
        solver_env_bool("JFEM_Q4_MARGUERRE_STATIC_GEOM_NORMALS", true)
    marguerre_coupling_scale = q4_marguerre_coupling_scale()
    marguerre_coupling_convention = q4_marguerre_coupling_convention()
    marguerre_handover_marker = marguerre_coupling_convention === :handover ? 1.0 : 0.0
    static_component_cm_scale =
        shear_center_only ? 1.0 : solver_env_float("JFEM_Q4_STATIC_COMPONENT_CM_SCALE", 1.0)
    eig_component_cm11_key = "JFEM_Q4_EIG_COMPONENT_CM11_SCALE"
    eig_component_cm22_key = "JFEM_Q4_EIG_COMPONENT_CM22_SCALE"
    eig_component_cm66_key = "JFEM_Q4_EIG_COMPONENT_CM66_SCALE"
    static_component_cm11_scale =
        max(solver_env_float(shear_center_only ? eig_component_cm11_key : "JFEM_Q4_STATIC_COMPONENT_CM11_SCALE", 1.0), 0.0)
    static_component_cm22_scale =
        max(solver_env_float(shear_center_only ? eig_component_cm22_key : "JFEM_Q4_STATIC_COMPONENT_CM22_SCALE", 1.0), 0.0)
    static_component_cm66_scale =
        max(solver_env_float(shear_center_only ? eig_component_cm66_key : "JFEM_Q4_STATIC_COMPONENT_CM66_SCALE", 1.0), 0.0)
    static_component_cb_scale =
        shear_center_only ? 1.0 : solver_env_float("JFEM_Q4_STATIC_COMPONENT_CB_SCALE", 1.0)
    static_component_cs_scale =
        shear_center_only ? 1.0 : solver_env_float("JFEM_Q4_STATIC_COMPONENT_CS_SCALE", 1.0)
    static_component_bmb_scale =
        shear_center_only ? 1.0 : solver_env_float("JFEM_Q4_STATIC_COMPONENT_BMB_SCALE", 1.0)
    static_component_drill_scale =
        shear_center_only ? 1.0 : solver_env_float("JFEM_Q4_STATIC_COMPONENT_DRILL_SCALE", 1.0)
    sol101_line_node_drill_scale =
        sol101_context && !shear_center_only ?
        clamp(solver_env_float("JFEM_SOL101_LINE_NODE_DRILL_SCALE", 0.001), 0.0, 1.0) :
        1.0
    sol101_line_node_drill_sqrt_scale = sqrt(sol101_line_node_drill_scale)
    sol101_pshell_blank_mid3_rigid_shear =
        sol101_context && !shear_center_only &&
        solver_env_bool("JFEM_SOL101_PSHELL_BLANK_MID3_RIGID_SHEAR", true)
    pshell_mid4_bmb_enabled = solver_env_bool("JFEM_PSHELL_MID4_BMB", false)
    pshell_use_mid2_bending = solver_env_bool("JFEM_PSHELL_USE_MID2_BENDING", true)
    sol101_pshell_mat2_cb_scale =
        sol101_context && !shear_center_only ?
        solver_env_float("JFEM_SOL101_PSHELL_MAT2_CB_SCALE", 1.0) :
        1.0
    q4_bmb_incomp_coupling_mode =
        sol101_context && !shear_center_only &&
        !haskey(ENV, "JFEM_Q4_BMB_INCOMP_COUPLING_MODE") ?
        :no_cross : :env
    q4_sol101_membrane_mode_weights_overridden =
        haskey(ENV, "JFEM_SOL101_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS") ||
        haskey(ENV, "JFEM_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS")
    q4_sol101_cross_membrane_weights_enabled =
        sol101_context && !shear_center_only &&
        !q4_sol101_membrane_mode_weights_overridden &&
        solver_env_bool("JFEM_SOL101_Q4_CROSS_MEMBRANE_WEIGHTS_ENABLED", true)
    # SOL105 analogue of the cross/shear-only Wilson membrane condensation.
    # The reference K is one physical operator independent of solution
    # sequence: single-element extractions (k_extract_boxes_laminates_20260704,
    # membrane_hourglass_probe) show the cross/shear-only weights reproduce the
    # Nastran flat CQUAD4 membrane block exactly (Rayleigh ratios 1.000000 on
    # all deformational modes, all laminates, aspect 1-8), while the uniform
    # full-basis condensation errs from -22% (pm45-dominant, aspect 1) to
    # +335% (aspect 8) on the in-plane hourglass channel. Default off pending
    # guard promotion.
    q4_sol105_cross_membrane_weights_enabled =
        sol105_context && !shear_center_only &&
        !q4_sol101_membrane_mode_weights_overridden &&
        solver_env_bool("JFEM_SOL105_Q4_CROSS_MEMBRANE_WEIGHTS", false)
    q4_sol101_cross_membrane_weights_mixed_topology =
        solver_env_bool("JFEM_SOL101_Q4_CROSS_MEMBRANE_WEIGHTS_MIXED_TOPOLOGY", false)
    q4_sol101_cross_membrane_weights_unconstrained_mixed_topology =
        solver_env_bool(
            "JFEM_SOL101_Q4_CROSS_MEMBRANE_WEIGHTS_UNCONSTRAINED_MIXED_TOPOLOGY",
            true,
        )
    q4_sol101_mat2_directional_weights_enabled =
        sol101_context && !shear_center_only &&
        !q4_sol101_membrane_mode_weights_overridden &&
        solver_env_bool("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_ENABLED", false)
    q4_sol101_mat2_directional_aspect_min =
        max(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_ASPECT_MIN", 5.0), 1.0)
    q4_sol101_mat2_directional_warp_max =
        max(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_WARP_MAX", 0.01), 0.0)
    q4_sol101_mat2_directional_h_over_l_max =
        max(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_H_OVER_L_MAX", 0.02), 0.0)
    q4_sol101_mat2_directional_c16_max =
        max(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_C16_MAX", 1e-8), 0.0)
    q4_sol101_mat2_directional_wx =
        clamp(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_WX", 0.20), 0.0, 2.0)
    q4_sol101_mat2_directional_wy =
        clamp(solver_env_float("JFEM_SOL101_Q4_MAT2_DIRECTIONAL_WEIGHTS_WY", 1.00), 0.0, 2.0)
    static_component_v2_min = shear_center_only ? 0.0 : q4_static_component_v2_min()
    static_component_v2_max = shear_center_only ? 0.0 : q4_static_component_v2_max()
    static_component_v2 =
        (static_component_v2_min <= 0.0 && static_component_v2_max <= 0.0) ?
        0.0 : q4_static_component_model_eigrl_v2(model)
    static_component_v2_gate_ok =
        q4_static_component_v2_ok(static_component_v2,
                                  static_component_v2_min,
                                  static_component_v2_max)
    static_component_thickness_min =
        shear_center_only ? 0.0 : q4_static_component_thickness_min()
    static_component_thickness_max =
        shear_center_only ? 0.0 : q4_static_component_thickness_max()
    static_component_aspect_min =
        shear_center_only ? 0.0 : q4_static_component_aspect_min()
    static_component_aspect_max =
        shear_center_only ? 0.0 : q4_static_component_aspect_max()
    static_component_taper_min =
        shear_center_only ? 0.0 : q4_static_component_taper_min()
    static_component_taper_max =
        shear_center_only ? 0.0 : q4_static_component_taper_max()
    static_component_h_over_l_min =
        shear_center_only ? 0.0 : q4_static_component_h_over_l_min()
    static_component_h_over_l_max =
        shear_center_only ? 0.0 : q4_static_component_h_over_l_max()
    static_component_warp_min =
        shear_center_only ? 0.0 : q4_static_component_warp_min()
    static_component_warp_max =
        shear_center_only ? 0.0 : q4_static_component_warp_max()
    static_component_require_pshell_mat2 =
        !shear_center_only &&
        solver_env_bool("JFEM_Q4_STATIC_COMPONENT_REQUIRE_PSHELL_MAT2", false)
    static_component_require_pcomp =
        !shear_center_only &&
        solver_env_bool("JFEM_Q4_STATIC_COMPONENT_REQUIRE_PCOMP", false)
    static_component_pcomp_shear_ratio_min =
        shear_center_only ? 0.0 : q4_static_component_pcomp_shear_ratio_min()
    static_component_pcomp_shear_ratio_max =
        shear_center_only ? 0.0 : q4_static_component_pcomp_shear_ratio_max()
    static_component_pcomp_d16_ratio_min =
        shear_center_only ? 0.0 : q4_static_component_pcomp_d16_ratio_min()
    static_component_pcomp_d16_ratio_max =
        shear_center_only ? 0.0 : q4_static_component_pcomp_d16_ratio_max()
    static_component_pcomp_b_ratio_min =
        shear_center_only ? 0.0 : q4_static_component_pcomp_b_ratio_min()
    static_component_pcomp_b_ratio_max =
        shear_center_only ? 0.0 : q4_static_component_pcomp_b_ratio_max()
    static_pcomp_nodal_geomnormal_transform =
        !shear_center_only &&
        solver_env_bool("JFEM_Q4_STATIC_PCOMP_NODAL_GEOMNORMAL_TRANSFORM", false)
    static_curvature_membrane_geom_normals =
        !shear_center_only &&
        solver_env_bool("JFEM_Q4_CURVATURE_MEMBRANE_STATIC_GEOM_NORMALS", false)
    # Curved-Jacobian fix path #2 (2026-04-21 PM scaffold). When enabled, the
    # per-element block fills a 4×3 coords_3d buffer and passes it to
    # stiffness_quad4_matrices via the `coords_3d` kwarg. The function itself
    # does not yet consume this input — the main Gauss-loop rewrite + NRM
    # kinematic coupling is the remaining work for next session. See
    # project_htp_curved_scaffold_2026_04_21.md in memory.
    curved_jacobian_enabled = q4_curved_jacobian_enabled(shear_center_only)
    # `coords_3d` is a PREREQUISITE, not a feature. Three independent capabilities consume it
    # -- the curved-Jacobian path, the MacNeal warp correction (JFEM_MACNEAL_WARP_ALPHA) and
    # the Marguerre membrane-uz coupling (JFEM_Q4_MARGUERRE_WARP_TO_UZ) -- but it was only
    # ever populated when the curved-Jacobian flag was on. The other two were therefore
    # SILENT NO-OPS under their own flags: setting JFEM_MACNEAL_WARP_ALPHA alone changed
    # nothing, which is measurably how that correction went unexamined long enough for its
    # documented premise to be wrong (2026-07-31: it is the wrong operator, worse at every
    # alpha, and the dominant warp term is bending-drilling, not K[Tz,Tx]).
    # Supply the buffer whenever ANY consumer asks for it.
    #
    # ⛔ WARNING, measured 2026-07-31 once these flags became reachable: supplying coords_3d
    # activates the experimental curved-shell GP-local frame path, and that path VIOLATES
    # RIGID-BODY TRANSLATION on warped elements -- ‖K·t‖/‖K‖ goes from ~2e-17 to 4.6e-3 at
    # warp/L = 0.024 and 3.7e-2 at 0.2, identically for all three consumers. Exact on flat
    # cells, which is why it went unnoticed. NONE of curved-Jacobian / Marguerre / warp-alpha
    # is promotable until the curved-shell path's outstanding "Gauss-loop rewrite + NRM
    # kinematic coupling" lands. Keep all three default OFF.
    warp_alpha_wants_coords3d =
        (tryparse(Float64, strip(get(ENV, "JFEM_MACNEAL_WARP_ALPHA", ""))) !== nothing) &&
        tryparse(Float64, strip(get(ENV, "JFEM_MACNEAL_WARP_ALPHA", ""))) != 0.0
    marguerre_wants_coords3d =
        lowercase(strip(get(ENV, "JFEM_Q4_MARGUERRE_WARP_TO_UZ", ""))) in ("1", "true", "yes", "on")
    # The MacNeal warp multiplier (JFEM_Q4_WARP_TRANSFORM, default ON) also needs coords_3d.
    # It EXCLUDES the curved-shell frame inside the kernel, exactly as Marguerre does, so the
    # rigid-body-translation warning above does not apply to it.
    warp_transform_wants_coords3d =
        !(lowercase(strip(get(ENV, "JFEM_Q4_WARP_TRANSFORM", ""))) in ("0", "false", "no", "off"))
    coords3d_needed = curved_jacobian_enabled || warp_alpha_wants_coords3d ||
                      marguerre_wants_coords3d || warp_transform_wants_coords3d
    q4_kernel_key = shear_center_only ? "JFEM_Q4_KERNEL_EIG" : "JFEM_Q4_KERNEL_STATIC"
    # SOL101 static PCOMP: keep the MITC4-3D aspect route opt-in.
    #
    # The route is useful as a research branch, but on NAPA-derived static
    # high-aspect PCOMP probes its transverse/shear block is too stiff versus
    # Nastran. Disabling the automatic route is a generic element-formulation
    # choice (PCOMP + static analysis branch), not a case-specific calibration:
    # the standard CQUAD4/MacNeal static path gives better extracted-K and
    # displacement parity on thin high-aspect laminates without moving the
    # other local SOL101 feature probes. Users can still opt in explicitly.
    # 2026-07-27 de-calibration Stage 4: the MITC4-3D-aspect auto-selection was
    # a whole-model fingerprint (element-count / aspect-percentile / warp windows
    # fitted to specific validation decks). Both explicit opt-in flags were also
    # code-default false, so this expression evaluated to "macneal" on every
    # model that was not fingerprinted. Collapsed to the single surviving path.
    default_q4_kernel = "macneal"
    q4_kernel_mode_static = lowercase(strip(get(ENV, q4_kernel_key, get(ENV, "JFEM_Q4_KERNEL", default_q4_kernel))))
    mitc4_3d_all_kernel = q4_kernel_mode_static in ("mitc4_3d", "mitc4-3d", "mitc3d")
    mitc4_3d_aspect_kernel = q4_kernel_mode_static in (
        "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect",
    )
    mitc4_3d_kernel = mitc4_3d_all_kernel || mitc4_3d_aspect_kernel
    mitc4_3d_aspect_min = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_MIN", 3.0), 1.0)
    mitc4_3d_aspect_max = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_MAX", 1e30), mitc4_3d_aspect_min)
    mitc4_3d_aspect_warp_min = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_WARP_MIN", 0.0), 0.0)
    mitc4_3d_aspect_warp_max = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_WARP_MAX", 1e30), mitc4_3d_aspect_warp_min)
    mitc4_3d_aspect_kappa_l_min =
        max(
            solver_env_float(
                "JFEM_Q4_MITC4_3D_ASPECT_KAPPA_L_MIN",
                (sol105_context && !shear_center_only) ? 1.0e-6 : 0.0,
            ),
            0.0,
        )
    mitc4_3d_aspect_kappa_l_max = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KAPPA_L_MAX", 1e30), mitc4_3d_aspect_kappa_l_min)
    mitc4_3d_aspect_cyl_ratio_min =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_CYL_RATIO_MIN", 0.0), 0.0)
    mitc4_3d_aspect_cyl_ratio_max =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_CYL_RATIO_MAX", 1e30), mitc4_3d_aspect_cyl_ratio_min)
    mitc4_3d_aspect_skew_min = q4_mitc4_3d_aspect_skew_min()
    mitc4_3d_aspect_skew_max = max(q4_mitc4_3d_aspect_skew_max(), mitc4_3d_aspect_skew_min)
    mitc4_3d_aspect_skew_aspect_min = q4_mitc4_3d_aspect_skew_aspect_min()
    mitc4_3d_aspect_pcomp_only = solver_env_bool("JFEM_Q4_MITC4_3D_ASPECT_PCOMP_ONLY", true)
    sol101_static_mitc4_3d_aspect_h_over_l_max_default =
        (sol101_context && !shear_center_only) ? 0.012 : 1e30
    mitc4_3d_aspect_h_over_l_min =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_H_OVER_L_MIN", 0.0), 0.0)
    mitc4_3d_aspect_h_over_l_max =
        max(
            solver_env_float(
                "JFEM_Q4_MITC4_3D_ASPECT_H_OVER_L_MAX",
                sol101_static_mitc4_3d_aspect_h_over_l_max_default,
            ),
            mitc4_3d_aspect_h_over_l_min,
        )
    mitc4_3d_aspect_h_over_lmax_min =
        max(
            solver_env_float(
                "JFEM_Q4_MITC4_3D_ASPECT_H_OVER_LMAX_MIN",
                (sol105_context && !shear_center_only) ? 0.0135 : 0.0,
            ),
            0.0,
        )
    mitc4_3d_aspect_h_over_lmax_max =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_H_OVER_LMAX_MAX", 1e30),
            mitc4_3d_aspect_h_over_lmax_min)
    mitc4_3d_ply_integration = solver_env_bool("JFEM_Q4_MITC4_3D_PLY_INTEGRATION", true)
    q4_macneal_bending_scale = solver_env_float("JFEM_Q4_MACNEAL_BENDING_SCALE", 1.0)
    q4_macneal_bending_isolated_scale =
        solver_env_float("JFEM_Q4_MACNEAL_BENDING_ISOLATED_SCALE", q4_macneal_bending_scale)
    q4_macneal_curved_bending_scale = solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_SCALE", 1.0)
    q4_macneal_curved_bending_enabled = q4_macneal_curved_bending_scale != 1.0
    q4_macneal_curved_bending_kappa_l_min =
        max(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_KAPPA_L_MIN", 1e-6), 0.0)
    q4_macneal_curved_bending_cyl_ratio_min =
        max(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_CYL_RATIO_MIN", 0.0), 0.0)
    q4_macneal_curved_bending_cyl_ratio_max =
        max(
            solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_CYL_RATIO_MAX", 1.0),
            q4_macneal_curved_bending_cyl_ratio_min,
        )
    q4_macneal_curved_bending_aspect_min =
        max(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_ASPECT_MIN", 1.0), 1.0)
    q4_macneal_curved_bending_aspect_max =
        max(
            solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_ASPECT_MAX", 1.0e99),
            q4_macneal_curved_bending_aspect_min,
        )
    q4_macneal_curved_bending_h_over_lmax_min =
        max(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_H_OVER_LMAX_MIN", 0.0), 0.0)
    q4_macneal_curved_bending_h_over_lmax_max =
        max(
            solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_H_OVER_LMAX_MAX", 1.0e99),
            q4_macneal_curved_bending_h_over_lmax_min,
        )
    q4_macneal_curved_bending_pm45_min =
        clamp(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_PM45_MIN", 0.0), 0.0, 1.0)
    q4_macneal_curved_bending_pm45_max =
        clamp(
            solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_PM45_MAX", 1.0),
            q4_macneal_curved_bending_pm45_min,
            1.0,
        )
    q4_macneal_curved_bending_pm90_min =
        clamp(solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_PM90_MIN", 0.0), 0.0, 1.0)
    q4_macneal_curved_bending_pm90_max =
        clamp(
            solver_env_float("JFEM_Q4_MACNEAL_CURVED_BENDING_PM90_MAX", 1.0),
            q4_macneal_curved_bending_pm90_min,
            1.0,
        )
    q4_macneal_curved_bending_ply_count_min =
        max(solver_env_int("JFEM_Q4_MACNEAL_CURVED_BENDING_PLY_COUNT_MIN", 0), 0)
    q4_macneal_curved_bending_ply_count_max =
        max(
            solver_env_int("JFEM_Q4_MACNEAL_CURVED_BENDING_PLY_COUNT_MAX", typemax(Int)),
            q4_macneal_curved_bending_ply_count_min,
        )
    # MSC Nastran QRG 2024.1 MAT8: blank/zero G1Z and G2Z mean zero
    # transverse-shear flexibility, i.e. the infinite-stiffness limit.
    mat8_blank_ts_rigid_limit = solver_env_bool(
        "JFEM_MAT8_BLANK_TS_RIGID_LIMIT",
        true,
    )
    q4_kernel_needs_surface_flatness =
        q4_kernel_mode_static in ("macneal", "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                  "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect")
    flat_curved_iso_eig_center_only = shear_center_only && q4_flat_curved_iso_eig_center_only_enabled()
    flat_curved_iso_eig_center_only_kappa_l_min = q4_flat_curved_iso_eig_center_only_kappa_l_min()
    flat_curved_iso_eig_center_only_cyl_ratio_max = q4_flat_curved_iso_eig_center_only_cyl_ratio_max()
    flat_curved_iso_exact_membrane_aspect_ratio_max = q4_flat_curved_iso_exact_membrane_aspect_ratio_max()
    flat_curved_iso_geomnormal_frame = shear_center_only && q4_flat_curved_iso_geomnormal_frame_enabled()
    flat_curved_iso_geomnormal_frame_aspect_ratio_min = q4_flat_curved_iso_geomnormal_frame_aspect_ratio_min()
    flat_curved_iso_geomnormal_frame_kappa_l_min = q4_flat_curved_iso_geomnormal_frame_kappa_l_min()
    flat_curved_iso_geomnormal_frame_kappa_l_max = q4_flat_curved_iso_geomnormal_frame_kappa_l_max()
    flat_curved_iso_geomnormal_frame_cyl_ratio_max = q4_flat_curved_iso_geomnormal_frame_cyl_ratio_max()
    flat_curved_iso_nodal_geomnormal_transform = shear_center_only && q4_flat_curved_iso_nodal_geomnormal_transform_enabled()
    flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min = q4_flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min()
    flat_curved_iso_nodal_geomnormal_transform_valence_sum_max = q4_flat_curved_iso_nodal_geomnormal_transform_valence_sum_max()
    curved_iso_geomnormal_frame = q4_curved_iso_geomnormal_frame_enabled()
    curved_iso_geomnormal_frame_aspect_ratio_min = q4_curved_iso_geomnormal_frame_aspect_ratio_min()
    curved_iso_geomnormal_frame_kappa_l_min = q4_curved_iso_geomnormal_frame_kappa_l_min()
    curved_iso_geomnormal_frame_kappa_l_max = q4_curved_iso_geomnormal_frame_kappa_l_max()
    curved_iso_geomnormal_frame_cyl_ratio_max = q4_curved_iso_geomnormal_frame_cyl_ratio_max()
    # DIAGNOSTIC (default OFF): skip the SNORM frame-tilt on elements whose resulting frame would
    # deviate from the element's own normal by more than JFEM_SNORM_ELEM_TILT_GATE degrees. Used to
    # confirm the iter_290 mechanism (junction-transition elements over-tilt the membrane). -2.0 => never.
    snorm_tilt_gate_cos = let g = solver_env_float("JFEM_SNORM_ELEM_TILT_GATE", 0.0); g > 0.0 ? cosd(g) : -2.0 end
    # SNORM-TRANSFORM-ONLY (default OFF): superseded frame/scatter diagnostic.
    # It keeps the basic element in its own frame and references SNORM only in
    # the per-node scatter transform. Retained for historical bisects; the
    # production route is the corner normal-moment map below.
    snorm_transform_only = solver_env_bool("JFEM_Q4_SNORM_TRANSFORM_ONLY", false)
    # SNORM-DIRECTOR (default OFF): superseded rotation-only S-map diagnostic
    # (snorm.jl, snorm_director_matrix). It suppresses element-frame tilt and
    # leaves translations untouched; production uses the normal-moment map.
    snorm_director = snorm_director_enabled()
    # Production route: retain the geometric mean-plane frame, form the
    # unchanged projected basic element, then apply the rigid-exact corner
    # normal-moment equilibrium map before the finite-warp map.
    snorm_curvature = snorm_curvature_enabled()
    flat_curved_pcomp_fullshear = shear_center_only && q4_flat_curved_pcomp_fullshear_enabled()
    flat_curved_pcomp_fullshear_kappa_l_min = q4_flat_curved_pcomp_fullshear_kappa_l_min()
    flat_curved_pcomp_fullshear_cyl_ratio_max = q4_flat_curved_pcomp_fullshear_cyl_ratio_max()
    flat_curved_pcomp_geomnormal_frame = shear_center_only && q4_flat_curved_pcomp_geomnormal_frame_enabled()
    pcomp_auto_global_x = !pcomp_axis_mode_override && q4_pcomp_auto_global_x_enabled()
    pcomp_auto_global_x_shear_ratio_max = q4_pcomp_auto_global_x_shear_ratio_max()
    pcomp_auto_global_x_d16_ratio_max = q4_pcomp_auto_global_x_d16_ratio_max()
    pcomp_auto_global_x_b_ratio_max = q4_pcomp_auto_global_x_b_ratio_max()
    pcomp_auto_global_x_cyl_ratio_min = q4_pcomp_auto_global_x_cyl_ratio_min()
    pcomp_auto_global_x_kappa_l_min = q4_pcomp_auto_global_x_kappa_l_min()

    cshells = model["CSHELLs"]
    cbars = model["CBARs"]
    cbeams = get(model, "CBEAMs", Dict())
    crods = get(model, "CRODs", Dict())
    rbe2s = get(model, "RBE2s", Dict())
    model_has_line_elements = !isempty(cbars) || !isempty(cbeams) || !isempty(crods) || !isempty(get(model, "CONRODs", Dict()))
    model_has_kinematic_constraints =
        !isempty(rbe2s) ||
        !isempty(get(model, "RBE3s", Dict())) ||
        !isempty(get(model, "RSPLINEs", Dict())) ||
        !isempty(get(model, "MPCs", []))
    pshells = model["PSHELLs"]; pbarls = model["PBARLs"]; mats = model["MATs"]
    auto_pcomp_membrane_incomp_model = any(q4_sol105_pcomp_auto_membrane_incomp_candidate, values(pshells))
    k6rot = solver_k6rot(get(model, "PARAM_K6ROT", nastran_k6rot_default(model)), shear_center_only)

    nt = Threads.maxthreadid()
    log_msg("[SOLVER] Computing Element Stiffness ($(Threads.nthreads()) threads)...")
    # Echo the EFFECTIVE drilling stabilisation and where it came from. K6ROT is
    # not part of any benchmark definition and solvers default it differently
    # (MSC/Nastran 70.5 linear sequences: 0.0; MSC.Nastran 2004+ and OpenJFEM:
    # 100.0), so on a deck that declares nothing the two run different problems.
    # That was silent until 2026-08-04, when it turned up as a 3.5% "formulation
    # gap" on the MacNeal hemisphere. Saying it out loud costs one line.
    log_msg(string("[SOLVER] Drilling stabilisation: K6ROT=", k6rot, " (",
                   haskey(model, "PARAM_K6ROT") ? "from the deck's PARAM,K6ROT" :
                       "default for SOL " *
                       string(Int(round(Float64(get(model, "SOL", get(model, "sol_type", 101)))))) *
                       ", matching MSC/Nastran 70.5",
                   ")"))

    # Convert id_map Dict to dense Vector
    if isempty(id_map)
        error("No nodes found in model — is this a standalone BDF or an INCLUDE fragment?")
    end
    max_nid = maximum(keys(id_map))
    id_vec = zeros(Int, max_nid)
    for (nid, idx) in id_map
        id_vec[nid] = idx
    end

    # Convert snorm_normals Dict to arrays
    snorm_vec = fill(SVector(0.0, 0.0, 0.0), n_nodes)
    snorm_has = falses(n_nodes)
    for (idx, nrm) in snorm_normals
        snorm_vec[idx] = nrm
        snorm_has[idx] = true
    end
    auto_global_x_needs_geom = pcomp_auto_global_x && (pcomp_auto_global_x_kappa_l_min > 0.0 || pcomp_auto_global_x_cyl_ratio_min > 0.0)
    needs_geom_normals = auto_global_x_needs_geom ||
                         curved_iso_eig_membrane_incomp || flat_curved_iso_eig_center_only ||
                         curved_iso_geomnormal_frame || q4_kernel_needs_surface_flatness ||
                         mitc4_3d_kernel || q4_macneal_curved_bending_enabled ||
                         marguerre_static_use_geom_normals || static_pcomp_nodal_geomnormal_transform ||
                         static_curvature_membrane_geom_normals
    geom_normals = needs_geom_normals ? compute_geometric_nodal_normals(model, id_map, node_coords) : Dict{Int, SVector{3,Float64}}()
    geom_vec = fill(SVector(0.0, 0.0, 0.0), n_nodes)
    geom_has = falses(n_nodes)
    for (idx, nrm) in geom_normals
        geom_vec[idx] = nrm
        geom_has[idx] = true
    end
    node_has_line = build_node_has_line_elements(model, id_map, n_nodes)
    node_has_frame = build_node_has_frame_elements(model, id_map, n_nodes)

    # Expand higher-order shells (CQUAD8→4×CQUAD4, CTRIA6→4×CTRIA3) into sub-elements
    # that feed into the existing CQUAD4/CTRIA3 pipeline with full accuracy.
    raw_shells = collect(values(cshells))
    shell_list = []
    n_q8_expanded = 0; n_t6_expanded = 0
    for el in raw_shells
        nids = el["NODES"]; n = length(nids)
        if n == 8
            # CQUAD8: corners 1-4, midsides 5-8 (5=mid(1-2), 6=mid(2-3), 7=mid(3-4), 8=mid(4-1))
            # → 4 CQUAD4: [1,5,9,8], [5,2,6,9], [9,6,3,7], [8,9,7,4] with center 9
            # Since there's no center node, use [1,5,6,8], [5,2,6,8] etc → simpler: 4 triangles
            # Actually: split into 4 CQUAD4 using midside nodes as corners:
            #   Q1: [n1, n5, center, n8], Q2: [n5, n2, n6, center], etc.
            # Without a center node, split into 4 CTRIA3 instead (more robust):
            #   T1: [n1, n5, n8], T2: [n5, n2, n6], T3: [n6, n3, n7], T4: [n7, n4, n8]
            #   T5: [n5, n6, n8], T6: [n6, n7, n8]  (center triangles)
            # Standard subdivision: 8-node quad → 6 triangles
            g = nids
            for tri_nodes in [[g[1],g[5],g[8]], [g[5],g[2],g[6]], [g[6],g[3],g[7]], [g[7],g[4],g[8]],
                              [g[5],g[6],g[8]], [g[6],g[7],g[8]]]
                push!(shell_list, Dict(
                    "ID"=>el["ID"],
                    "PID"=>el["PID"],
                    "NODES"=>tri_nodes,
                    "THETA"=>get(el,"THETA",0.0),
                    "MCID"=>get(el,"MCID",0),
                ))
            end
            n_q8_expanded += 1
        elseif n == 6
            # CTRIA6: corners 1-3, midsides 4-6 (4=mid(1-2), 5=mid(2-3), 6=mid(3-1))
            # → 4 CTRIA3: [n1,n4,n6], [n4,n2,n5], [n5,n3,n6], [n4,n5,n6]
            g = nids
            for tri_nodes in [[g[1],g[4],g[6]], [g[4],g[2],g[5]], [g[5],g[3],g[6]], [g[4],g[5],g[6]]]
                push!(shell_list, Dict(
                    "ID"=>el["ID"],
                    "PID"=>el["PID"],
                    "NODES"=>tri_nodes,
                    "THETA"=>get(el,"THETA",0.0),
                    "MCID"=>get(el,"MCID",0),
                ))
            end
            n_t6_expanded += 1
        else
            push!(shell_list, el)
        end
    end
    if n_q8_expanded + n_t6_expanded > 0
        log_msg("[SOLVER] Expanded $n_q8_expanded CQUAD8 + $n_t6_expanded CTRIA6 into sub-elements")
    end
    n_shells = length(shell_list)

    # Pass 1: count QUAD4 and TRIA3 elements
    n_q4 = 0; n_t3 = 0
    for ei in 1:n_shells
        el = shell_list[ei]
        pid = string(el["PID"])
        if !haskey(pshells, pid); continue; end
        prop = pshells[pid]
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        nids = el["NODES"]; n = length(nids)
        valid = true
        for k in 1:n
            nid = nids[k]
            if nid < 1 || nid > max_nid || id_vec[nid] == 0; valid = false; break; end
        end
        if !valid; continue; end
        if n == 4; n_q4 += 1; elseif n == 3; n_t3 += 1; end
    end

    # Pre-allocate QUAD4 flat arrays
    q4_idx     = Matrix{Int}(undef, n_q4, 4)
    q4_h       = Vector{Float64}(undef, n_q4)
    q4_br      = Vector{Float64}(undef, n_q4)
    q4_Eref    = Vector{Float64}(undef, n_q4)
    q4_Cm_flat = zeros(3, 3, n_q4)
    q4_Cb_flat = zeros(3, 3, n_q4)
    q4_Cs_flat = zeros(2, 2, n_q4)
    q4_Cs_raw_flat = zeros(2, 2, n_q4)
    q4_Bmb_flat = zeros(3, 3, n_q4)
    q4_has_Bmb = falses(n_q4)
    q4_is_pcomp = falses(n_q4)
    q4_is_pcomp_isotropic = falses(n_q4)
    q4_pcomp_rigid_shear = falses(n_q4)
    q4_is_isotropic = falses(n_q4)
    q4_pshell_mat2 = falses(n_q4)
    q4_eid_int = zeros(Int, n_q4)
    q4_pid_int = zeros(Int, n_q4)
    q4_pcomp_auto_element_axis_prop = falses(n_q4)
    q4_el_theta = zeros(n_q4)
    q4_el_mcid = zeros(Int, n_q4)
    q4_pshell_blank_mid3 = falses(n_q4)
    q4_pcomp_shear_ratio = zeros(n_q4)
    q4_pcomp_d16_ratio = zeros(n_q4)
    q4_pcomp_b_ratio = zeros(n_q4)
    q4_ply_data = Vector{Any}(undef, n_q4)

    # Pre-allocate TRIA3 arrays
    t3_idx     = Matrix{Int}(undef, n_t3, 3)
    t3_h       = Vector{Float64}(undef, n_t3)
    t3_br      = Vector{Float64}(undef, n_t3)
    t3_tst     = Vector{Float64}(undef, n_t3)
    t3_Eref    = Vector{Float64}(undef, n_t3)
    t3_Cm      = Vector{Matrix{Float64}}(undef, n_t3)
    t3_Cb      = Vector{Matrix{Float64}}(undef, n_t3)
    t3_Cs      = Vector{Matrix{Float64}}(undef, n_t3)
    t3_Bmb     = Vector{Union{Nothing, Matrix{Float64}}}(undef, n_t3)
    t3_is_pcomp = falses(n_t3)
    t3_is_pcomp_isotropic = falses(n_t3)
    t3_is_isotropic = falses(n_t3)
    t3_el_theta = zeros(n_t3)
    t3_el_mcid = zeros(Int, n_t3)

    # Pass 2: fill arrays
    iq4 = 0; it3 = 0
    for ei in 1:n_shells
        el = shell_list[ei]
        pid = string(el["PID"])
        if !haskey(pshells, pid); continue; end
        prop = pshells[pid]
        nids = el["NODES"]
        n = length(nids)
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        is_pcomp_clt = get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "Cm")
        base_mat = mats[mid]
        mat = is_pcomp_clt ? base_mat : _effective_mat1_for_nodes(model, mid, nids)
        bend_mat = mat
        if !is_pcomp_clt && pshell_use_mid2_bending
            mid2 = get(prop, "MID2", 0)
            if mid2 != 0 && haskey(mats, string(mid2))
                bend_candidate = _effective_mat1_for_nodes(model, string(mid2), nids)
                bend_candidate !== nothing && (bend_mat = bend_candidate)
            end
        end
        el_theta = deg2rad(Float64(get(el, "THETA", 0.0)))
        mid3 = get(prop, "MID3", 0)
        pshell_blank_mid3 = !is_pcomp_clt && mid3 == 0
        shear_mat =
            if mid3 != 0 && haskey(mats, string(mid3))
                is_pcomp_clt ? mats[string(mid3)] : _effective_mat1_for_nodes(model, string(mid3), nids)
            else
                mat
            end
        h = prop["T"]
        br = get(prop, "BEND_RATIO", 1.0)
        tst = get(prop, "TS_T", 5.0/6.0)
        pcomp_is_isotropic = is_pcomp_clt && get(prop, "IS_ISOTROPIC", false)
        is_ortho = !is_pcomp_clt && get(mat, "TYPE", "") == "MAT8" && haskey(mat, "E1") && haskey(mat, "E2")
        is_mat2  = !is_pcomp_clt && !is_ortho && get(mat, "TYPE", "") == "MAT2" && haskey(mat, "G11")

        valid = true
        for k in 1:n
            nid = nids[k]
            if nid < 1 || nid > max_nid || id_vec[nid] == 0; valid = false; break; end
        end
        if !valid; continue; end

        local Cm_e::Matrix{Float64}, Cb_e::Matrix{Float64}, Cs_e::Matrix{Float64}
        local Bmb_e::Union{Nothing, Matrix{Float64}}
        local E_ref_e::Float64

        if is_pcomp_clt
            Cm_e = prop["Cm"]; Cb_e = prop["Cb"]; Cs_e = prop["Cs"]
            Bmb_e = get(prop, "Bmb", nothing)
            E_ref_e = n == 4 ? get(prop, "E_ref", mat["E"]) : mat["G"]
            # Store element THETA for per-element material axis rotation
            el_theta_pcomp = el_theta
        elseif is_ortho
            E1 = mat["E1"]; E2 = mat["E2"]; nu12 = mat["NU12"]; G12 = mat["G12"]
            nu21 = nu12 * E2 / max(E1, 1e-30)
            denom = 1.0 - nu12 * nu21
            Q11 = E1/denom; Q22 = E2/denom; Q12 = nu12*E2/denom; Q66 = G12
            Q16 = 0.0; Q26 = 0.0
            if abs(el_theta) > 1e-10
                ct = cos(el_theta); st = sin(el_theta); c2 = ct^2; s2 = st^2
                Q11r = Q11*c2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*s2^2
                Q22r = Q11*s2^2 + 2*(Q12+2*Q66)*c2*s2 + Q22*c2^2
                Q12r = (Q11+Q22-4*Q66)*c2*s2 + Q12*(c2^2+s2^2)
                Q16 = (Q11-Q12-2*Q66)*ct*st*c2 + (Q12-Q22+2*Q66)*ct*st*s2
                Q26 = (Q11-Q12-2*Q66)*ct*st*s2 + (Q12-Q22+2*Q66)*ct*st*c2
                Q66r = (Q11+Q22-2*Q12-2*Q66)*c2*s2 + Q66*(c2^2+s2^2)
                Q11 = Q11r; Q22 = Q22r; Q12 = Q12r; Q66 = Q66r
            end
            Cm_e = h .* [Q11 Q12 Q16; Q12 Q22 Q26; Q16 Q26 Q66]
            Cb_e = br * (h^3/12.0) .* [Q11 Q12 Q16; Q12 Q22 Q26; Q16 Q26 Q66]
            Cs_e, _ = shell_transverse_shear_matrix(shear_mat, h, tst, el_theta)
            Bmb_e = nothing
            E_ref_e = n == 4 ? max(E1, E2) : G12
        elseif is_mat2
            G11 = mat["G11"]; G12m = mat["G12"]; G13 = mat["G13"]
            G22 = mat["G22"]; G23 = mat["G23"]; G33 = mat["G33"]
            Cm_e = h .* [G11 G12m G13; G12m G22 G23; G13 G23 G33]
            Cb_e = br * (h^3/12.0) .* [G11 G12m G13; G12m G22 G23; G13 G23 G33]
            Cs_e, G_shear_ref = shell_transverse_shear_matrix(shear_mat, h, tst, el_theta)
            Bmb_e = nothing
            E_ref_e = n == 4 ? max(G11, G22) : G_shear_ref
        else
            E_val = mat["E"]; nu_val = mat["NU"]
            const_mem = E_val * h / (1 - nu_val^2)
            Cm_e = const_mem .* [1.0 nu_val 0.0; nu_val 1.0 0.0; 0.0 0.0 (1-nu_val)/2]
            const_bend = br * (E_val * h^3) / (12 * (1 - nu_val^2))
            Cb_e = const_bend .* [1.0 nu_val 0.0; nu_val 1.0 0.0; 0.0 0.0 (1-nu_val)/2]
            Cs_e, G_shear_ref = shell_transverse_shear_matrix(shear_mat, h, tst, el_theta)
            Bmb_e = nothing
            E_ref_e = n == 4 ? E_val : G_shear_ref
        end

        if !is_pcomp_clt && br > 1e-12
            Cb_e = pshell_bending_constitutive_matrix(bend_mat, h, br, el_theta)
        end

        if br <= 1e-12
            # A PSHELL/Pcomp membrane-only shell should not retain transverse shear
            # or drilling stabilization; those artificial out-of-plane terms prevent
            # AUTOSPC from reproducing Nastran's membrane-only mechanism handling.
            fill!(Cs_e, 0.0)
        end
        mid4 = get(prop, "MID4", 0)
        if pshell_mid4_bmb_enabled && !is_pcomp_clt && mid4 != 0 && br > 1e-12 && haskey(mats, string(mid4))
            bmb_mat = _effective_mat1_for_nodes(model, string(mid4), nids)
            Bmb_e = pshell_mid4_bmb_matrix(bmb_mat, h, el_theta)
        end

        if n == 4
            iq4 += 1
            i1 = id_vec[nids[1]]; i2 = id_vec[nids[2]]; i3 = id_vec[nids[3]]; i4 = id_vec[nids[4]]
            q4_idx[iq4,1] = i1; q4_idx[iq4,2] = i2; q4_idx[iq4,3] = i3; q4_idx[iq4,4] = i4
            q4_h[iq4] = h; q4_br[iq4] = br; q4_Eref[iq4] = E_ref_e
            q4_eid_int[iq4] = something(tryparse(Int, string(get(el, "ID", 0))), 0)
            q4_pid_int[iq4] = something(tryparse(Int, pid), 0)
            for j in 1:3, i in 1:3
                q4_Cm_flat[i,j,iq4] = Cm_e[i,j]
                q4_Cb_flat[i,j,iq4] = Cb_e[i,j]
            end
            for j in 1:2, i in 1:2
                q4_Cs_flat[i,j,iq4] = Cs_e[i,j]
                q4_Cs_raw_flat[i,j,iq4] = is_pcomp_clt && haskey(prop, "Cs_raw") ? prop["Cs_raw"][i,j] : Cs_e[i,j]
            end
            if Bmb_e !== nothing
                q4_has_Bmb[iq4] = true
                for j in 1:3, i in 1:3; q4_Bmb_flat[i,j,iq4] = Bmb_e[i,j]; end
            end
            if is_pcomp_clt
                q4_is_pcomp[iq4] = true
                q4_ply_data[iq4] = get(prop, "PLY_DATA", nothing)
                q4_is_pcomp_isotropic[iq4] = pcomp_is_isotropic
                q4_pcomp_rigid_shear[iq4] = Bool(get(prop, "TRANSVERSE_SHEAR_RIGID_LIMIT", false))
                q4_pcomp_auto_element_axis_prop[iq4] = q4_sol105_pcomp_auto_membrane_incomp_candidate(prop)
                q4_el_theta[iq4] = el_theta_pcomp
                q4_el_mcid[iq4] = Int(get(el, "MCID", 0))
                q4_pcomp_shear_ratio[iq4], q4_pcomp_d16_ratio[iq4], q4_pcomp_b_ratio[iq4] =
                    pcomp_metric_ratios(prop, el_theta_pcomp)
            else
                q4_ply_data[iq4] = nothing
                q4_is_isotropic[iq4] = !is_ortho && !is_mat2
                q4_pshell_mat2[iq4] = is_mat2
                q4_pshell_blank_mid3[iq4] = pshell_blank_mid3
                q4_el_theta[iq4] = el_theta
                q4_el_mcid[iq4] = Int(get(el, "MCID", 0))
            end
        elseif n == 3
            it3 += 1
            i1 = id_vec[nids[1]]; i2 = id_vec[nids[2]]; i3 = id_vec[nids[3]]
            t3_idx[it3,1] = i1; t3_idx[it3,2] = i2; t3_idx[it3,3] = i3
            t3_h[it3] = h; t3_br[it3] = br; t3_tst[it3] = tst; t3_Eref[it3] = E_ref_e
            t3_Cm[it3] = Cm_e; t3_Cb[it3] = Cb_e; t3_Cs[it3] = Cs_e; t3_Bmb[it3] = Bmb_e
            if is_pcomp_clt
                t3_is_pcomp[it3] = true
                t3_is_pcomp_isotropic[it3] = pcomp_is_isotropic
                t3_el_theta[it3] = el_theta_pcomp
                t3_el_mcid[it3] = Int(get(el, "MCID", 0))
            else
                t3_is_isotropic[it3] = !is_ortho && !is_mat2
            end
        end
    end

    log_msg("[SOLVER] Pre-extracted $n_q4 QUAD4 + $n_t3 TRIA3 elements (from $n_shells total)")

    # Convert node_R to flat 3D array
    node_R_flat = zeros(3, 3, n_nodes)
    for i in 1:n_nodes
        for r in 1:3, c in 1:3
            node_R_flat[r, c, i] = node_R[i][r, c]
        end
    end
    shell_valence = zeros(Int, n_nodes)
    for ei in 1:n_q4
        shell_valence[q4_idx[ei,1]] += 1
        shell_valence[q4_idx[ei,2]] += 1
        shell_valence[q4_idx[ei,3]] += 1
        shell_valence[q4_idx[ei,4]] += 1
    end
    for ei in 1:n_t3
        shell_valence[t3_idx[ei,1]] += 1
        shell_valence[t3_idx[ei,2]] += 1
        shell_valence[t3_idx[ei,3]] += 1
    end
    # --- PARALLEL QUAD4 ASSEMBLY ---
    per_thread_ws = [FEM.create_quad4_workspace() for _ in 1:nt]
    per_thread_ws_alt = [FEM.create_quad4_workspace() for _ in 1:nt]
    # MacNeal-RBF scratch workspace (allocation elimination 2026-08-06). One
    # per thread is sufficient even for the blend branches: the buffers are
    # pure intra-call scratch of add_quad4_macneal_shear_rbf! — nothing
    # escapes a kernel call except values accumulated into ws.Ke, and the
    # center/full pair in each blend branch runs sequentially on one thread.
    per_thread_msws = [FEM.create_macneal_shear_workspace() for _ in 1:nt]

    all_I = Vector{Int}(undef, n_q4 * 576)
    all_J = Vector{Int}(undef, n_q4 * 576)
    all_V = Vector{Float64}(undef, n_q4 * 576)

    prev_blas_threads = LinearAlgebra.BLAS.get_num_threads()
    LinearAlgebra.BLAS.set_num_threads(1)

    sep_T       = [zeros(24,24) for _ in 1:nt]
    sep_tmp     = [zeros(24,24) for _ in 1:nt]
    sep_global  = [zeros(24,24) for _ in 1:nt]
    sep_dofs    = [Vector{Int}(undef, 24) for _ in 1:nt]
    sep_lc      = [zeros(4,2) for _ in 1:nt]
    # Per-thread 4×3 buffer for the 3D corner coords — source for the curved
    # Jacobian integration (fix path #2, env-gated via
    # JFEM_SOL105_EIG_CURVED_JACOBIAN). When the flag is off (default), this
    # buffer is filled but the `coords_3d` kwarg of stiffness_quad4_matrices
    # receives nothing, keeping runtime behavior identical to pre-scaffold.
    sep_coords3d = [zeros(4,3) for _ in 1:nt]
    sep_coords3d_local = [zeros(4,3) for _ in 1:nt]
    sep_directors3d_local = [zeros(4,3) for _ in 1:nt]
    sep_snorm_pq = [zeros(4,2) for _ in 1:nt]
    sep_Cm      = [zeros(3,3) for _ in 1:nt]
    sep_Cb      = [zeros(3,3) for _ in 1:nt]
    sep_Cs      = [zeros(2,2) for _ in 1:nt]
    sep_Bmb     = [zeros(3,3) for _ in 1:nt]
    sep_Ke_blend = [zeros(24,24) for _ in 1:nt]
    # Buffers for the macneal-blend branch's two 24x24 snapshots (the copies
    # are semantically required — Ke_t/Ke_macneal alias workspace Ke fields —
    # only their per-element allocation is not).
    sep_Ke_ref      = [zeros(24,24) for _ in 1:nt]
    sep_Ke_macneal  = [zeros(24,24) for _ in 1:nt]
    q4_use_geom_snorm = falses(n_q4)
    if curved_iso_geomnormal_frame && isempty(snorm_normals)
        for ei in 1:n_q4
            q4_is_isotropic[ei] || continue
            i1 = q4_idx[ei,1]; i2 = q4_idx[ei,2]; i3 = q4_idx[ei,3]; i4 = q4_idx[ei,4]
            (geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]) || continue
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])
            p4 = SVector{3}(node_coords[i4,1], node_coords[i4,2], node_coords[i4,3])
            v1p, v2p, v3p = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
            c_p = (p1 + p2 + p3 + p4) / 4.0
            lc_p = zeros(4,2)
            lc_p[1,1] = dot(p1-c_p, v1p); lc_p[1,2] = dot(p1-c_p, v2p)
            lc_p[2,1] = dot(p2-c_p, v1p); lc_p[2,2] = dot(p2-c_p, v2p)
            lc_p[3,1] = dot(p3-c_p, v1p); lc_p[3,2] = dot(p3-c_p, v2p)
            lc_p[4,1] = dot(p4-c_p, v1p); lc_p[4,2] = dot(p4-c_p, v2p)
            aspect_ratio_p = q4_local_edge_aspect_ratio(lc_p)
            aspect_ratio_p >= curved_iso_geomnormal_frame_aspect_ratio_min || continue
            (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 || continue
            d13_p = p3 - p1
            d24_p = p4 - p2
            v3_geom_raw_p = cross(d13_p, d24_p)
            v3_geom_len_p = norm(v3_geom_raw_p)
            elem_is_flat_p = true
            if v3_geom_len_p > 1e-12
                v3g_p = v3_geom_raw_p / v3_geom_len_p
                max_dev_p = max(abs(dot(p1-c_p, v3g_p)), abs(dot(p2-c_p, v3g_p)),
                                abs(dot(p3-c_p, v3g_p)), abs(dot(p4-c_p, v3g_p)))
                L_diag_p = max(norm(d13_p), norm(d24_p))
                elem_is_flat_p = max_dev_p <
                    max(solver_env_float("JFEM_Q4_FLAT_TOL_REL", 1e-2), 1e-12) *
                    max(L_diag_p, 1e-12)
            end
            geom_curv_p = estimate_quad4_curvature_membrane(
                lc_p, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1p, v2p, v3p
            )
            k1_p, _ = q4_curvature_principal_abs(geom_curv_p)
            kappa_l_p = k1_p * q4_curvature_characteristic_length(lc_p)
            cyl_ratio_p = q4_curvature_cyl_ratio(geom_curv_p)
            if elem_is_flat_p
                if (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 &&
                   kappa_l_p >= flat_curved_iso_geomnormal_frame_kappa_l_min &&
                   kappa_l_p <= flat_curved_iso_geomnormal_frame_kappa_l_max &&
                   cyl_ratio_p <= flat_curved_iso_geomnormal_frame_cyl_ratio_max
                    q4_use_geom_snorm[ei] = true
                end
            elseif kappa_l_p >= curved_iso_geomnormal_frame_kappa_l_min &&
                   kappa_l_p <= curved_iso_geomnormal_frame_kappa_l_max &&
                   cyl_ratio_p <= curved_iso_geomnormal_frame_cyl_ratio_max
                q4_use_geom_snorm[ei] = true
            end
        end
    end
    k_diag_eid_csv_path = strip(get(ENV, "JFEM_K_DIAG_EID_CSV", ""))
    k_diag_enabled = !isempty(k_diag_eid_csv_path)
    k_diag_rows = k_diag_enabled ? Vector{String}(undef, n_q4) : String[]

    # Per-element record of the MacNeal assumed-shear interaction fallback (see
    # `add_quad4_macneal_shear_rbf!`: a synthetic companion of a strongly
    # distorted element can be degenerate, in which case that element silently
    # uses the validated base operator). A plain Vector{Bool} is byte-addressed,
    # so distinct indices are safe to write concurrently from the :static loop;
    # ONE summary line is emitted after the loop -- never per element.
    q4_macneal_interaction_skipped = fill(false, n_q4)

    Threads.@threads :static for ei in 1:n_q4
        tid = Threads.threadid()
        # Clear the kernel's out-of-band report channel for this element; the
        # kernel only ever sets it, so reading it after the (possibly repeated,
        # for the blend branches) kernel calls below ORs them together.
        msws_e = per_thread_msws[tid]
        msws_e.interaction_skipped = false

        i1 = q4_idx[ei,1]; i2 = q4_idx[ei,2]; i3 = q4_idx[ei,3]; i4 = q4_idx[ei,4]

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])
        p4 = SVector{3}(node_coords[i4,1], node_coords[i4,2], node_coords[i4,3])

        v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
        elem_use_geom_snorm = q4_use_geom_snorm[ei]
        snorm_pq_arg = nothing
        if snorm_curvature && !elem_use_geom_snorm &&
           (snorm_has[i1] || snorm_has[i2] || snorm_has[i3] || snorm_has[i4])
            snorm_pq_local = sep_snorm_pq[tid]
            @inbounds for (k, idx) in enumerate((i1, i2, i3, i4))
                if snorm_has[idx]
                    n = snorm_vec[idx]
                    dot(n, v3) < 0.0 && (n = -n)
                    n3 = dot(n, v3)
                    if abs(n3) >= 1e-3
                        snorm_pq_local[k,1] = dot(n, v1) / n3
                        snorm_pq_local[k,2] = dot(n, v2) / n3
                    else
                        snorm_pq_local[k,1] = 0.0
                        snorm_pq_local[k,2] = 0.0
                    end
                else
                    snorm_pq_local[k,1] = 0.0
                    snorm_pq_local[k,2] = 0.0
                end
            end
            FEM.quad4_snorm_pq_has_active_rows(snorm_pq_local) &&
                (snorm_pq_arg = snorm_pq_local)
        end
        elem_snorm_curvature = snorm_pq_arg !== nothing

        # SNORM adjustment
        n_avg = SVector(0.0, 0.0, 0.0); nc = 0
        for idx in (i1, i2, i3, i4)
            if elem_use_geom_snorm
                if geom_has[idx]; n_avg = n_avg + geom_vec[idx]; nc += 1; end
            else
                if snorm_has[idx]; n_avg = n_avg + snorm_vec[idx]; nc += 1; end
            end
        end
        if snorm_curvature && !elem_use_geom_snorm && !elem_snorm_curvature
            # Aligned averaged normals produce an exactly zero pq field. Treat
            # that as no SNORM before the legacy frame-reprojection branch so
            # the full assembled matrix remains bitwise identical, while the
            # independent geometry-normal experiment keeps its original route.
            nc = 0
        end
        # snorm_transform_only: keep the OWN element frame here (membrane/bending use undistorted geometry)
        # and store the element-averaged SNORM normal (snorm_xf_v3) for a UNIFORM per-element transform below.
        snorm_xf_v3 = SVector(0.0, 0.0, 0.0); snorm_xf_ok = false
        if nc > 0
            n_avg_s = n_avg / nc; len_s = norm(n_avg_s)
            if len_s > 1e-12
                v3n = SVector{3}(n_avg_s / len_s)
                if dot(v3n, v3) < 0.0; v3n = -v3n; end
                if snorm_transform_only
                    snorm_xf_v3 = v3n; snorm_xf_ok = true
                elseif !snorm_director && !elem_snorm_curvature &&
                       dot(v3n, v3) >= snorm_tilt_gate_cos  # DIAGNOSTIC gate: skip tilt if it exceeds gate angle
                    v1p = v1 - dot(v1, v3n) * v3n; v1l = norm(v1p)
                    if v1l > 1e-12
                        v1n = SVector{3}(v1p / v1l)
                    else
                        v2p = v2 - dot(v2, v3n) * v3n; v1n = SVector{3}(normalize(v2p))
                    end
                    v1, v2, v3 = v1n, SVector{3}(cross(v3n, v1n)), v3n
                end
            end
        end
        lc = sep_lc[tid]
        c = (p1 + p2 + p3 + p4) / 4.0
        lc[1,1] = dot(p1-c, v1); lc[1,2] = dot(p1-c, v2)
        lc[2,1] = dot(p2-c, v1); lc[2,2] = dot(p2-c, v2)
        lc[3,1] = dot(p3-c, v1); lc[3,2] = dot(p3-c, v2)
        lc[4,1] = dot(p4-c, v1); lc[4,2] = dot(p4-c, v2)
        c3d_local = sep_coords3d_local[tid]
        dirs_local = sep_directors3d_local[tid]
        c3d_local[1,1] = lc[1,1]; c3d_local[1,2] = lc[1,2]; c3d_local[1,3] = dot(p1-c, v3)
        c3d_local[2,1] = lc[2,1]; c3d_local[2,2] = lc[2,2]; c3d_local[2,3] = dot(p2-c, v3)
        c3d_local[3,1] = lc[3,1]; c3d_local[3,2] = lc[3,2]; c3d_local[3,3] = dot(p3-c, v3)
        c3d_local[4,1] = lc[4,1]; c3d_local[4,2] = lc[4,2]; c3d_local[4,3] = dot(p4-c, v3)
        aspect_ratio_ei = q4_local_edge_aspect_ratio(lc)
        taper_ratio_ei = q4_local_opposite_edge_ratio(lc)
        edge_skew_ei = q4_local_edge_skew_angle(lc)

        # Fill the per-thread 4x3 buffer whenever ANY consumer of coords_3d is enabled
        # (curved Jacobian, MacNeal warp correction, or Marguerre) -- see coords3d_needed.
        coords_3d_arg = nothing
        if coords3d_needed
            c3d = sep_coords3d[tid]
            c3d[1,1] = p1[1]; c3d[1,2] = p1[2]; c3d[1,3] = p1[3]
            c3d[2,1] = p2[1]; c3d[2,2] = p2[2]; c3d[2,3] = p2[3]
            c3d[3,1] = p3[1]; c3d[3,2] = p3[2]; c3d[3,3] = p3[3]
            c3d[4,1] = p4[1]; c3d[4,2] = p4[2]; c3d[4,3] = p4[3]
            coords_3d_arg = c3d
        end
        curvature_membrane = nothing
        pcomp_pm45_fraction_selector =
            q4_is_pcomp[ei] ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 45.0) : 0.0
        pcomp_pm90_fraction_selector =
            q4_is_pcomp[ei] ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 90.0) : 0.0
        pcomp_ply_count_selector =
            q4_is_pcomp[ei] ? pcomp_ply_count_from_plies(q4_ply_data[ei]) : 0
        elem_mitc4_3d_candidate =
            mitc4_3d_all_kernel ||
            (mitc4_3d_aspect_kernel &&
             aspect_ratio_ei >= mitc4_3d_aspect_min &&
             aspect_ratio_ei <= mitc4_3d_aspect_max)
        mitc4_3d_use_geom_dirs =
            elem_mitc4_3d_candidate && geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
        marguerre_static_use_geom_dirs =
            marguerre_static_use_geom_normals && geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
        static_curvature_membrane_use_geom_dirs =
            static_curvature_membrane_geom_normals && geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
        has_curv_normals = elem_use_geom_snorm || mitc4_3d_use_geom_dirs ||
                           marguerre_static_use_geom_dirs ||
                           static_curvature_membrane_use_geom_dirs ||
                           (snorm_has[i1] && snorm_has[i2] && snorm_has[i3] && snorm_has[i4])
        use_geom_curv_dirs =
            elem_use_geom_snorm ||
            mitc4_3d_use_geom_dirs ||
            marguerre_static_use_geom_dirs ||
            static_curvature_membrane_use_geom_dirs
        n1_curv = use_geom_curv_dirs ? geom_vec[i1] : snorm_vec[i1]
        n2_curv = use_geom_curv_dirs ? geom_vec[i2] : snorm_vec[i2]
        n3_curv = use_geom_curv_dirs ? geom_vec[i3] : snorm_vec[i3]
        n4_curv = use_geom_curv_dirs ? geom_vec[i4] : snorm_vec[i4]
        if has_curv_normals
            for (row, ncurv) in enumerate((n1_curv, n2_curv, n3_curv, n4_curv))
                nloc = SVector(dot(ncurv, v1), dot(ncurv, v2), dot(ncurv, v3))
                if nloc[3] < 0.0
                    nloc = -nloc
                end
                nlen = norm(nloc)
                if nlen > 1e-12
                    dirs_local[row,1] = nloc[1] / nlen
                    dirs_local[row,2] = nloc[2] / nlen
                    dirs_local[row,3] = nloc[3] / nlen
                else
                    dirs_local[row,1] = 0.0; dirs_local[row,2] = 0.0; dirs_local[row,3] = 1.0
                end
            end
        else
            for row in 1:4
                dirs_local[row,1] = 0.0; dirs_local[row,2] = 0.0; dirs_local[row,3] = 1.0
            end
        end

        slope_membrane = nothing
        if marguerre_coupling_enabled && has_curv_normals
            # Ibrahimbegović 1994 Eq. 6.14 rotation-column coupling. Geometric
            # slopes derived from SNORM-averaged nodal normals via small-angle
            # projection onto the element tangent plane. No tunable scale needed
            # unless explicitly overridden (scale default 1.0).
            slope_raw = estimate_quad4_slope_membrane(
                n1_curv, n2_curv, n3_curv, n4_curv, v1, v2, v3
            )
            if marguerre_coupling_scale != 1.0
                slope_raw = slope_raw * marguerre_coupling_scale
            end
            # Encode convention as trailing element: 0 = jfem_kl, 1 = handover
            slope_membrane = SVector{9,Float64}(
                slope_raw[1], slope_raw[2], slope_raw[3], slope_raw[4],
                slope_raw[5], slope_raw[6], slope_raw[7], slope_raw[8],
                marguerre_handover_marker,
            )
        end

        Cm_local = sep_Cm[tid]; Cb_local = sep_Cb[tid]; Cs_local = sep_Cs[tid]
        for j in 1:3, i in 1:3; Cm_local[i,j] = q4_Cm_flat[i,j,ei]; Cb_local[i,j] = q4_Cb_flat[i,j,ei]; end
        for j in 1:2, i in 1:2; Cs_local[i,j] = q4_Cs_flat[i,j,ei]; end
        Bmb_local = nothing
        if q4_has_Bmb[ei]
            Bmb_local = sep_Bmb[tid]
            for j in 1:3, i in 1:3; Bmb_local[i,j] = q4_Bmb_flat[i,j,ei]; end
        end

        ws_stiff = per_thread_ws[tid]
        # Element-adaptive shear integration for K_eig (shear_center_only=true globally):
        #   Flat orthotropic PCOMP: center-only MITC4 shear to avoid over-stiff thin-laminate buckling modes
        #   Flat isotropic / isotropic PCOMP: normal 2×2 MITC4 + phi2
        #   Curved orthotropic PCOMP: full 2×2 MITC4 (center-only is too soft)
        #   Curved isotropic / isotropic PCOMP: blend center-only with some full MITC4
        # Static K always uses global settings unchanged.
        # Planarity check using GEOMETRIC normal (not SNORM — SNORM is surface-tangent on curved shells,
        # causing dot(pi-c, v3_snorm)≈0 even for curved elements). Diagonal cross product gives true normal.
        d13_geom = p3 - p1; d24_geom = p4 - p2
        v3_geom_raw = cross(d13_geom, d24_geom)
        v3_geom_len = norm(v3_geom_raw)
        local max_dev_ei::Float64
        if v3_geom_len > 1e-12
            v3g = v3_geom_raw / v3_geom_len
            max_dev_ei = max(abs(dot(p1-c, v3g)), abs(dot(p2-c, v3g)),
                             abs(dot(p3-c, v3g)), abs(dot(p4-c, v3g)))
        else
            max_dev_ei = 0.0
        end
        L_diag_ei  = max(norm(d13_geom), norm(d24_geom))  # diagonal length (≈ √2 × edge)
        # JFEM_Q4_FLAT_TOL_REL: relative flatness classification tolerance.
        # Real aerodynamic meshes carry microscopic facet warp (HTP-346: warp/L
        # p50 1.5e-5, max 1.6e-3) that the reference CQUAD4 treats as flat
        # (mean-plane projection with warp corrections); the old strict 1e-6
        # test disabled the identified flat-element stack (cross membrane
        # weights, recovery consistency) on such elements.
        #
        # 2026-07-27: default RAISED 1e-6 -> 1e-2. Measured against Nastran on a
        # purpose-built warp rig (single PCOMP cell, warp/L swept 0 -> 3e-3):
        # Nastran's out-of-plane stiffness is warp-INSENSITIVE (476.39 ->
        # 476.48 over the whole sweep) while JFEM dropped 459 -> 295 (-36 %) the
        # instant warp became nonzero and then stayed flat — a branch
        # discontinuity, because !elem_is_flat flips elem_shear_center_only and
        # skips the MacNeal RBF shear block. With the tolerance relaxed the
        # warped cell reproduces the flat cell exactly at every warp level.
        # 2026-08-03: with the MacNeal warp multiplier in place (JFEM_Q4_WARP_TRANSFORM), the
        # flat/warped KERNEL branch is superseded. MacNeal's construction IS "flat element, then
        # pre/post-multiplier", so once the multiplier exists the flat kernel is correct at every
        # warp and this classifier should not gate it. Leaving it gated left a genuine BRANCH
        # DISCONTINUITY: the membrane block of K drops by 1097 in a single step between warp 0.0570
        # and 0.0575 -- exactly where warp_ratio crosses this 1e-2 -- against a smooth trend of ~30,
        # while the reference is warp-insensitive there. That step was the whole of the remaining
        # membrane error: mem-mem at warp 0.20 falls 1.017e-2 -> 9.02e-5 when it is removed.
        # The comment above records the same class of bug being pushed from 1e-6 to 1e-2 in April,
        # which MOVED the discontinuity rather than removing it. This removes it.
        # Measured: warp 1.089953e-02 -> 3.414193e-03, combined 1.494114e-01 -> 1.014564e-01, every
        # other element-parity axis bit-unchanged.
        flat_tol_rel_default = fem_env_bool_solver_warp_transform() ? 1e30 : 1e-2
        elem_is_flat = max_dev_ei <
            max(solver_env_float("JFEM_Q4_FLAT_TOL_REL", flat_tol_rel_default), 1e-12) *
            max(L_diag_ei, 1e-12)
        warp_ratio_ei = max_dev_ei / max(L_diag_ei, 1e-12)
        # MacNeal-permissive planarity (2026-04-30): the flat MacNeal RBF kernel
        # works correctly on mildly-warped quads as long as warp_ratio is small.
        # The strict `elem_is_flat` test (1e-6 of L) classifies almost all real
        # aerodynamic-mesh elements as non-flat, sending them onto the inferior
        # legacy MITC path. Setting the MacNeal eligibility threshold to 1e-4
        # (0.01% warp) recovers HTP_3wp_disp 511002 from 85.9% rel error to
        # 1.87% with no regression on HTP_launch (2.86% unchanged). Strongly-
        # curved meshes like VTP still need a real curved-aware MacNeal kernel.
        #
        # 2026-07-27: default RAISED 1e-4 -> 1e-2. MacNeal eligibility is tested
        # BEFORE the curvature branch, so cells above this bound never reach it.
        # HTP_launch's mode-hosting cells sit at warp/L = 1.5e-4, just over the
        # old line (elem_kernel_planar = 0 for the mode hosts, 1 for the rest of
        # the deck): JFEM's energy on Nastran's own HTP eigenvector was 2.24x
        # too stiff and drops to 0.906x once they stay on MacNeal.
        macneal_warp_tol = max(solver_env_float("JFEM_Q4_MACNEAL_WARP_TOL", 1e-2), 1e-12)
        # Aspect-ratio gate (2026-05-01): research switch, default off (1e30).
        # Distribution analysis on the GAME meshes showed HTP_launch p90 aspect
        # ratio 10.4 (max 24) vs VTP_launch p99 only 7.7, suggesting a possible
        # discriminator between HTP-breaking and VTP-improving curved elements
        # under MacNeal. Empirical sweep with `JFEM_Q4_MACNEAL_ASPECT_MAX=10`
        # (combined with `KAPPA_L_MAX=1.0`) did NOT cleanly recover the HTP/VTP
        # trade-off — aspect ratio alone is insufficient. Left as an explicit
        # switch for further per-element classifier work.
        macneal_aspect_max = max(solver_env_float("JFEM_Q4_MACNEAL_ASPECT_MAX", 1e30), 1.0)
        # Isotropic-only MacNeal warp tolerance (2026-07-12). Element-level KGG
        # extraction on the warp atomics (single warped iso PSHELL/MAT1 CQUAD4)
        # showed the 1e-4 `macneal_warp_tol` gate flips mildly-warped ISOTROPIC
        # elements off MacNeal onto the legacy MITC path, which over-stiffens
        # them: atomic_warp_0p05/0p5 mode-1 lambda jumps +19.7% over Nastran at
        # warp_ratio > 1e-4, while Nastran is warp-insensitive (~34.29 at all
        # warp levels). Keeping isotropic elements on MacNeal restores -5.29%
        # (matching the flat/tiny-warp cases). The original 1e-4 threshold was
        # tuned for PCOMP curved routing (HTP_3wp_disp), so raise the bound ONLY
        # for genuinely isotropic (non-PCOMP-laminate) elements — PCOMP element
        # eligibility (and hence the HTP/box routing) is byte-identical.
        macneal_warp_tol_iso =
            max(solver_env_float("JFEM_Q4_MACNEAL_WARP_TOL_ISO", 1.0), macneal_warp_tol)
        is_pcomp_ei = q4_is_pcomp[ei]
        is_pcomp_iso_ei = q4_is_pcomp_isotropic[ei]
        is_iso_ei = q4_is_isotropic[ei] || is_pcomp_iso_ei
        elem_macneal_warp_tol_eff =
            (is_iso_ei && !is_pcomp_ei) ? macneal_warp_tol_iso : macneal_warp_tol
        elem_is_macneal_eligible = warp_ratio_ei < elem_macneal_warp_tol_eff &&
                                   aspect_ratio_ei <= macneal_aspect_max
        if flat_curved_iso_geomnormal_frame &&
           q4_is_isotropic[ei] &&
           elem_is_flat &&
           aspect_ratio_ei >= flat_curved_iso_geomnormal_frame_aspect_ratio_min &&
           (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 &&
           geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            iso_geom_curvature_probe = estimate_quad4_curvature_membrane(
                lc, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
            )
            k1_probe, _ = q4_curvature_principal_abs(iso_geom_curvature_probe)
            kappa_l_probe = k1_probe * q4_curvature_characteristic_length(lc)
            cyl_ratio_probe = q4_curvature_cyl_ratio(iso_geom_curvature_probe)
            if kappa_l_probe >= flat_curved_iso_geomnormal_frame_kappa_l_min &&
               kappa_l_probe <= flat_curved_iso_geomnormal_frame_kappa_l_max &&
               cyl_ratio_probe <= flat_curved_iso_geomnormal_frame_cyl_ratio_max
                v3_geom_sum = geom_vec[i1] + geom_vec[i2] + geom_vec[i3] + geom_vec[i4]
                if norm(v3_geom_sum) > 1e-12
                    v3_geom_frame = normalize(v3_geom_sum)
                    if dot(v3_geom_frame, v3) < 0.0
                        v3_geom_frame = -v3_geom_frame
                    end
                    v1, v2, v3 = shell_element_frame_quad4_with_normal(
                        p1, p2, p3, p4, v3_geom_frame, q4_frame_mode
                    )
                    lc[1,1] = dot(p1-c, v1); lc[1,2] = dot(p1-c, v2)
                    lc[2,1] = dot(p2-c, v1); lc[2,2] = dot(p2-c, v2)
                    lc[3,1] = dot(p3-c, v1); lc[3,2] = dot(p3-c, v2)
                    lc[4,1] = dot(p4-c, v1); lc[4,2] = dot(p4-c, v2)
                    aspect_ratio_ei = q4_local_edge_aspect_ratio(lc)
                    taper_ratio_ei = q4_local_opposite_edge_ratio(lc)
                end
            end
        end
        if curved_iso_geomnormal_frame &&
           q4_is_isotropic[ei] &&
           !elem_is_flat &&
           aspect_ratio_ei >= curved_iso_geomnormal_frame_aspect_ratio_min &&
           (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 &&
           geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            iso_geom_curvature_probe = estimate_quad4_curvature_membrane(
                lc, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
            )
            k1_probe, _ = q4_curvature_principal_abs(iso_geom_curvature_probe)
            kappa_l_probe = k1_probe * q4_curvature_characteristic_length(lc)
            cyl_ratio_probe = q4_curvature_cyl_ratio(iso_geom_curvature_probe)
            if kappa_l_probe >= curved_iso_geomnormal_frame_kappa_l_min &&
               kappa_l_probe <= curved_iso_geomnormal_frame_kappa_l_max &&
               cyl_ratio_probe <= curved_iso_geomnormal_frame_cyl_ratio_max
                v3_geom_sum = geom_vec[i1] + geom_vec[i2] + geom_vec[i3] + geom_vec[i4]
                if norm(v3_geom_sum) > 1e-12
                    v3_geom_frame = normalize(v3_geom_sum)
                    if dot(v3_geom_frame, v3) < 0.0
                        v3_geom_frame = -v3_geom_frame
                    end
                    v1, v2, v3 = shell_element_frame_quad4_with_normal(
                        p1, p2, p3, p4, v3_geom_frame, q4_frame_mode
                    )
                    lc[1,1] = dot(p1-c, v1); lc[1,2] = dot(p1-c, v2)
                    lc[2,1] = dot(p2-c, v1); lc[2,2] = dot(p2-c, v2)
                    lc[3,1] = dot(p3-c, v1); lc[3,2] = dot(p3-c, v2)
                    lc[4,1] = dot(p4-c, v1); lc[4,2] = dot(p4-c, v2)
                    aspect_ratio_ei = q4_local_edge_aspect_ratio(lc)
                    taper_ratio_ei = q4_local_opposite_edge_ratio(lc)
                end
            end
        end
        pcomp_geom_curvature = nothing
        iso_geom_curvature = nothing
        iso_corner_curvature = nothing
        if is_pcomp_ei && geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4] &&
           (flat_pcomp_auto_g12 || pcomp_auto_global_x ||
            q4_kernel_needs_surface_flatness || q4_macneal_curved_bending_enabled)
            pcomp_geom_curvature = estimate_quad4_curvature_membrane(
                lc, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
            )
        end
        if (curved_iso_eig_membrane_incomp || flat_curved_iso_eig_center_only) &&
           q4_is_isotropic[ei] &&
           geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            iso_geom_curvature = estimate_quad4_curvature_membrane(
                lc, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
            )
        end
        if flat_iso_dkmq_branch && q4_is_isotropic[ei] && !elem_is_flat
            iso_corner_curvature = estimate_quad4_corner_curvature_membrane(
                lc, p1, p2, p3, p4, v1, v2, v3
            )
        end
        auto_curved_iso_membrane_incomp = false
        auto_warped_iso_membrane_incomp = false
        auto_elongated_iso_membrane_incomp = false
        flat_curved_iso_center_candidate = false
        kappa_l_iso = 0.0
        cyl_ratio_iso = 1.0
        if iso_geom_curvature !== nothing && q4_is_isotropic[ei]
            k1_iso, _ = q4_curvature_principal_abs(iso_geom_curvature)
            kappa_l_iso = k1_iso * q4_curvature_characteristic_length(lc)
            cyl_ratio_iso = q4_curvature_cyl_ratio(iso_geom_curvature)
            auto_curved_iso_membrane_incomp =
                curved_iso_eig_membrane_incomp &&
                kappa_l_iso >= curved_iso_eig_membrane_incomp_kappa_l_min &&
                cyl_ratio_iso <= curved_iso_eig_membrane_incomp_cyl_ratio_max
            auto_warped_iso_membrane_incomp =
                curved_iso_warp_membrane_incomp &&
                !elem_is_flat &&
                warp_ratio_ei >= curved_iso_warp_membrane_incomp_ratio_min &&
                kappa_l_iso <= curved_iso_warp_membrane_incomp_kappa_l_max
            auto_elongated_iso_membrane_incomp =
                curved_iso_elongated_membrane_incomp &&
                !elem_is_flat &&
                aspect_ratio_ei >= curved_iso_elongated_membrane_incomp_aspect_ratio_min
            flat_curved_iso_center_candidate =
                flat_curved_iso_eig_center_only && elem_is_flat &&
                kappa_l_iso >= flat_curved_iso_eig_center_only_kappa_l_min &&
                cyl_ratio_iso <= flat_curved_iso_eig_center_only_cyl_ratio_max
        end
        elem_k6rot = q4_br[ei] <= 1e-12 ? 0.0 : k6rot
        if q4_br[ei] <= 1e-12
            elem_k6rot = 0.0
        elseif shear_center_only &&
           model_has_line_elements &&
           elem_is_flat &&
           q4_is_isotropic[ei] &&
           !flat_curved_iso_center_candidate
            elem_k6rot = 0.0
        end
        elem_drill_scale = q4_br[ei] <= 1e-12 ? 0.0 : 1.0
        if q4_br[ei] <= 1e-12
            elem_drill_scale = 0.0
        end
        # Flat elements on a smoothly curved shell patch can still need curved-shell
        # buckling treatment in K_eig, especially on faceted cylinders.
        flat_pcomp_h_over_l = q4_h[ei] / max(q4_curvature_characteristic_length(lc), 1e-12)
        flat_pcomp_h_over_lmax = q4_h[ei] / max(q4_local_max_edge_length(lc), 1e-12)
        q4_h_over_max_edge = q4_h[ei] / max(q4_local_max_edge_length(lc), 1e-12)
        flat_curved_pcomp_fullshear_candidate = false
        if flat_curved_pcomp_fullshear &&
           elem_is_flat &&
           is_pcomp_ei &&
           !is_pcomp_iso_ei &&
           Bmb_local === nothing &&
           pcomp_geom_curvature !== nothing
            k1_pcomp, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
            kappa_l_pcomp = k1_pcomp * q4_curvature_characteristic_length(lc)
            cyl_ratio_pcomp = q4_curvature_cyl_ratio(pcomp_geom_curvature)
            flat_curved_pcomp_fullshear_candidate =
                kappa_l_pcomp >= flat_curved_pcomp_fullshear_kappa_l_min &&
                cyl_ratio_pcomp <= flat_curved_pcomp_fullshear_cyl_ratio_max
        end
        if flat_curved_pcomp_geomnormal_frame &&
           flat_curved_pcomp_fullshear_candidate &&
           geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            v3_geom_sum = geom_vec[i1] + geom_vec[i2] + geom_vec[i3] + geom_vec[i4]
            if norm(v3_geom_sum) > 1e-12
                v3_geom_frame = normalize(v3_geom_sum)
                if dot(v3_geom_frame, v3) < 0.0
                    v3_geom_frame = -v3_geom_frame
                end
                v1, v2, v3 = shell_element_frame_quad4_with_normal(
                    p1, p2, p3, p4, v3_geom_frame, q4_frame_mode
                )
                lc[1,1] = dot(p1-c, v1); lc[1,2] = dot(p1-c, v2)
                lc[2,1] = dot(p2-c, v1); lc[2,2] = dot(p2-c, v2)
                lc[3,1] = dot(p3-c, v1); lc[3,2] = dot(p3-c, v2)
                lc[4,1] = dot(p4-c, v1); lc[4,2] = dot(p4-c, v2)
                aspect_ratio_ei = q4_local_edge_aspect_ratio(lc)
                taper_ratio_ei = q4_local_opposite_edge_ratio(lc)
                pcomp_geom_curvature = estimate_quad4_curvature_membrane(
                    lc, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                )
            end
        end
        if curvature_membrane === nothing &&
           shear_center_only &&
           flat_curved_pcomp_fullshear_candidate &&
           pcomp_geom_curvature !== nothing &&
           q4_pcomp_d16_ratio[ei] >= q4_pcomp_kg_auto_curvature_d16_ratio_min() &&
           q4_curvature_cyl_ratio(pcomp_geom_curvature) >= 0.2
            # Curved composite facets need the actual geometric membrane-curvature
            # coupling in K_eig. Reusing the globally downscaled shell curvature
            # factor underestimates this term and leaves the curved laminate
            # buckling modes too soft.
            curvature_membrane = pcomp_geom_curvature
        end
        # MacNeal eligibility uses the looser warp-tolerance gate so users can
        # opt mildly-curved elements onto the MacNeal RBF path without changing
        # `elem_is_flat`, which other heuristics still key off of.
        elem_kernel_planar = elem_is_macneal_eligible
        elem_macneal_static_kernel = false
        on_macneal_by_curvature = false
        on_macneal_by_thickness = false
        on_macneal_by_nemeth = false
        kappa_l_kernel = 0.0
        # Load-aware static override: a shear-dominated non-flat element (see
        # classify_shear_dominant_elements) takes the flat MacNeal kernel
        # regardless of the geometry curvature/thickness gate. Reaching the
        # MacNeal RBF shear block also requires shear_center_only=false (set
        # below at the elem_shear_center_only assignment), so both must flip
        # together. Only populated when JFEM_SOL105_LOAD_AWARE_KERNEL is on.
        elem_force_macneal_by_load =
            elem_shear_dominant !== nothing &&
            get(elem_shear_dominant, q4_eid_int[ei], false)
        elem_force_macneal_by_geometry = false
        # Extreme-taper PCOMPs (opposite-edge ratio below the threshold) sit
        # outside every path calibration: the legacy/center-shear paths are
        # measured 6-16x SOFT on them (kjunction closure webs, taper ~0.2),
        # and the flat MacNeal kernel with the fan law (report 3.65) matches
        # the reference within ~2%. Geometry-only discriminator, default off.
        elem_force_macneal_by_extreme_taper =
            solver_env_float("JFEM_SOL105_GEOM_PCOMP_MACNEAL_EXTREME_TAPER_MAX", 0.0) > 0.0 &&
            is_pcomp_ei && !is_pcomp_iso_ei &&
            taper_ratio_ei <= solver_env_float("JFEM_SOL105_GEOM_PCOMP_MACNEAL_EXTREME_TAPER_MAX", 0.0)
        elem_force_macneal_static =
            elem_force_macneal_by_load ||
            elem_force_macneal_by_geometry ||
            elem_force_macneal_by_extreme_taper
        if elem_force_macneal_static
            elem_kernel_planar = true
            elem_macneal_static_kernel = true
        elseif q4_kernel_needs_surface_flatness &&
           elem_is_macneal_eligible &&
           is_pcomp_ei &&
           !is_pcomp_iso_ei &&
            pcomp_geom_curvature !== nothing
            k1_kernel, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
            kappa_l_kernel = k1_kernel * q4_curvature_characteristic_length(lc)
            on_macneal_by_curvature = true
            # 2026-05-25 (default-on): per-element discriminator routes "thick +
            # low-aspect" PCOMP curved elements onto the MacNeal RBF kernel while
            # leaving the thin+high-aspect ones on MITC4+phi2 (whose per-element
            # α gate in FEMKernels.jl handles them). Reason: high-aspect cases
            # (HTP_launch) need MITC4+phi2 softening; moderate-aspect thicker
            # cases (VTP_3wp_strain 511002, K-side -4.54% bias at default) close
            # to Nastran on MacNeal. Both branches together bring the GAME max
            # RQ bias from 6.01% down below 3.00%. Discriminators (all geometry
            # only; respects [[no-test-set-tuning]]):
            #   h/L      ≥ THICK_H_OVER_L_MIN  (default 0.015)
            #   aspect   ≤ THICK_ASPECT_MAX     (default 3.5)
            #   κ_L      ≥ THICK_KAPPA_L_MIN    (default 0.0 — curvature lower bound)
            #   h        ≥ THICK_H_MIN          (default 0.0 — absolute thickness)
            # The κ_L and h bounds default to 0 (no additional gating) and are
            # available for sweeps; the h/L and aspect bounds are the load-bearing
            # discriminators today. Env overrides documented in
            # SOL105_CALIBRATED_CONSTANTS.
            h_over_l_thr = max(
                solver_env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_H_OVER_L_MIN", 0.015),
                0.0,
            )
            aspect_max = max(
                solver_env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_ASPECT_MAX", 3.5),
                1.0,
            )
            kappa_l_min = max(
                solver_env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_KAPPA_L_MIN", 0.0),
                0.0,
            )
            h_min = max(
                solver_env_float("JFEM_Q4_MACNEAL_PCOMP_THICK_H_MIN", 0.0),
                0.0,
            )
            on_macneal_by_thickness =
                flat_pcomp_h_over_l >= h_over_l_thr &&
                aspect_ratio_ei      <= aspect_max  &&
                kappa_l_kernel       >= kappa_l_min &&
                q4_h[ei]             >= h_min
            elem_macneal_static_kernel =
                on_macneal_by_curvature ||
                on_macneal_by_thickness
            elem_kernel_planar = elem_macneal_static_kernel
        end
        # JFEM_Q4_MACNEAL_RIGID_SHEAR_FORCE: research switch (default false)
        # introduced 2026-05-12 after Nastran reverse-engineering showed that
        # disabling the residual-bending-flexibility on transverse shear
        # (i.e., applying rigid_shear) recovers ~92-108% of Nastran's
        # bending+shear block on the single-element probe ladder. Set this
        # env to bypass the PCOMP-only / MAT8-blank gate and apply
        # macneal_rigid_shear on every macneal-eligible Q4. Tested on
        # GAME with TBD outcome.
        elem_macneal_rigid_shear =
            (mat8_blank_ts_rigid_limit &&
             elem_is_flat &&
             elem_kernel_planar &&
             is_pcomp_ei &&
             !is_pcomp_iso_ei &&
             q4_pcomp_rigid_shear[ei] &&
             (q4_kernel_mode_static in ("macneal", "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                        "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect"))) ||
            (sol101_pshell_blank_mid3_rigid_shear &&
             q4_pshell_blank_mid3[ei] &&
             q4_br[ei] > 1e-12 &&
             (q4_kernel_mode_static in ("macneal", "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                        "macneal_all", "mitc4_3d_aspect", "mitc4-3d-aspect",
                                        "mitc3d_aspect", "mitc3d-aspect"))) ||
            (solver_env_bool("JFEM_Q4_MACNEAL_RIGID_SHEAR_FORCE", false) &&
             elem_is_macneal_eligible &&
             (q4_kernel_mode_static in ("macneal", "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                        "macneal_all", "mitc4_3d_aspect", "mitc4-3d-aspect",
                                        "mitc3d_aspect", "mitc3d-aspect")))
        flat_pcomp_reduced_shear = elem_is_flat &&
                                   is_pcomp_ei &&
                                   !is_pcomp_iso_ei &&
                                   !elem_macneal_rigid_shear &&
                                   !flat_curved_pcomp_fullshear_candidate &&
                                   flat_pcomp_h_over_l <= q4_sol105_flat_pcomp_center_only_h_over_l_max()
        if shear_center_only && elem_is_flat && is_pcomp_ei && !is_pcomp_iso_ei
            # Use the exact ply-integrated laminate transverse shear matrix in flat
            # SOL105 eigen stiffness. The generic 5/6 Timoshenko correction is an
            # isotropic surrogate and was depressing the physical first modes of the
            # elementary flat laminate buckling decks.
            use_exact_flat_dkmq =
                flat_pcomp_dkmq_branch &&
                Bmb_local === nothing &&
                maximum(abs, Cb_local) > 1e-30
            if use_exact_flat_dkmq
                # Keep the experimental exact DKMQ branch analytical:
                # use the directly integrated laminate transverse shear matrix
                # without the empirical SOL105 auto shear scaling.
                @inbounds for j in 1:2, i in 1:2
                    Cs_local[i, j] = q4_Cs_raw_flat[i, j, ei]
                end
            else
                @inbounds for j in 1:2, i in 1:2
                    Cs_local[i, j] = q4_Cs_raw_flat[i, j, ei]
                end
            end
        end
        elem_shear_center_only = shear_center_only && (
            !elem_is_flat ||
            flat_curved_iso_center_candidate ||
            flat_pcomp_reduced_shear
        )
        # MacNeal RBF shear block only fires with shear_center_only=false.
        # Both the opt-in load-aware override and the production geometry-only
        # PCOMP route must therefore take the full path.
        if elem_force_macneal_by_load || elem_force_macneal_by_geometry
            elem_shear_center_only = false
        end
        flat_pcomp_no_phi2 = isnothing(flat_pcomp_no_phi2_override) ? true : flat_pcomp_no_phi2_override
        auto_pcomp_element_axis = false
        if is_pcomp_ei && !is_pcomp_iso_ei && q4_pcomp_auto_element_axis_prop[ei] &&
           pcomp_geom_curvature !== nothing
            k1, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
            kappa_l = k1 * q4_curvature_characteristic_length(lc)
            cyl_ratio = q4_curvature_cyl_ratio(pcomp_geom_curvature)
            auto_pcomp_element_axis =
                q4_sol105_pcomp_auto_element_axis_candidate(
                    q4_pcomp_auto_element_axis_prop[ei],
                    kappa_l,
                    cyl_ratio,
                )
        end
        pcomp_axis_mode_eff = pcomp_axis_mode
        if flat_pcomp_auto_g12 && is_pcomp_ei && !is_pcomp_iso_ei &&
           q4_pcomp_shear_ratio[ei] <= pcomp_auto_global_x_shear_ratio_max &&
           q4_pcomp_d16_ratio[ei] <= pcomp_auto_global_x_d16_ratio_max &&
           q4_pcomp_b_ratio[ei] <= pcomp_auto_global_x_b_ratio_max
            pcomp_axis_mode_eff = :g12
        end
        if is_pcomp_ei && pcomp_auto_global_x && !is_pcomp_iso_ei && !elem_is_flat &&
           !auto_pcomp_element_axis &&
           q4_pcomp_shear_ratio[ei] <= pcomp_auto_global_x_shear_ratio_max &&
           q4_pcomp_d16_ratio[ei] <= pcomp_auto_global_x_d16_ratio_max &&
           q4_pcomp_b_ratio[ei] <= pcomp_auto_global_x_b_ratio_max
            if pcomp_auto_global_x_kappa_l_min <= 0.0 && pcomp_auto_global_x_cyl_ratio_min <= 0.0
                pcomp_axis_mode_eff = :global_x
            elseif pcomp_geom_curvature !== nothing
                k1, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
                kappa_l = k1 * q4_curvature_characteristic_length(lc)
                cyl_ratio = q4_curvature_cyl_ratio(pcomp_geom_curvature)
                if kappa_l >= pcomp_auto_global_x_kappa_l_min &&
                   cyl_ratio >= pcomp_auto_global_x_cyl_ratio_min
                    pcomp_axis_mode_eff = :global_x
                end
            end
        end
        elem_material_shear_rotation = 0.0
        if is_pcomp_ei
            # Pass all 4 corners so the rotation function can resolve
            # :warp_switch and keep the K_eig rotation consistent with the
            # Kg rotation for the same element (no 2- vs 4-corner asymmetry).
            beta = shell_pcomp_material_rotation(
                pcomp_axis_mode_eff,
                v1, v2, v3, p1, p2, p3, p4,
                q4_el_theta[ei],
                q4_el_mcid[ei],
                model["CORDs"],
            )
            # Frame-consistency correction for skewed composites (elastic-K membrane
            # defect): the membrane B-matrix is built in the element-local (lc = v1,v2)
            # frame, but the laminate A/Cm is expressed in the material frame.  For an
            # axis-aligned rectangle v1 == global x so they coincide, but on a SKEWED
            # element the lc frame (v1) is rotated from global by the element-frame
            # angle, so A must be rotated by that same angle to stay consistent with the
            # lc-frame B -- otherwise the bilinear Bm_lc' * A_material * Bm_lc is
            # equivalent to using A rotated by the skew angle, giving a spurious A16/A26
            # and an ~80%-off membrane block vs Nastran KGG (which keeps B and A in one
            # consistent frame).  Add the element-frame angle to beta.  Gate
            # JFEM_SOL105_PCOMP_SKEW_MEMBRANE (default ON since 2026-07-28: deterministic 42-deck screen
            # per-case accounting); non-skew (v1 ~ global x) elements are unaffected.
            elem_material_shear_rotation = beta
            if abs(beta) > 1e-10
                cb = cos(beta); sb = sin(beta)
                c2 = cb^2; s2 = sb^2; cs = cb*sb
                T11 = c2;  T12 = s2;  T13 = cs
                T21 = s2;  T22 = c2;  T23 = -cs
                T31 = -2cs; T32 = 2cs; T33 = c2 - s2
                _rotate_constitutive_3x3!(Cm_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                _rotate_constitutive_3x3!(Cb_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                a11 = Cs_local[1,1]; a12 = Cs_local[1,2]; a22 = Cs_local[2,2]
                Cs_local[1,1] = cb^2*a11 + 2*cb*sb*a12 + sb^2*a22
                Cs_local[1,2] = -cb*sb*a11 + (cb^2-sb^2)*a12 + cb*sb*a22
                Cs_local[2,1] = Cs_local[1,2]
                Cs_local[2,2] = sb^2*a11 - 2*cb*sb*a12 + cb^2*a22
                if Bmb_local !== nothing
                    _rotate_constitutive_3x3!(Bmb_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                end
            end
            # Frame-consistency correction for skewed composites (elastic-K MEMBRANE
            # defect): the membrane B-matrix is built in the element-local (lc = v1,v2)
            # frame, but with the raw-THETA axis modes (:element, and :warp_switch on
            # flat quads) the laminate Cm is referenced to the PROJECTED SIDE 1-2 (the
            # CQUAD4 THETA convention), not to v1.  On an axis-aligned rectangle side
            # 1-2 || v1 so they coincide; on a SKEWED element they differ by the
            # in-plane side-1-2 -> v1 angle, so Bm_lc' * Cm * Bm_lc is equivalent to
            # using Cm rotated by that angle -- spurious A16/A26 and an ~80%-off
            # membrane block vs Nastran KGG.  Rotate Cm by the OBJECTIVE in-plane angle
            # (shell_material_rotation_from_g12: projected edge 1-2 measured from v1),
            # NOT a global-axis proxy -- the earlier phi = -atan(v1_y, v1_x) was only
            # valid for elements in the global XY plane with side 1-2 along +X, and
            # mis-rotated vertical/inclined panels (A11<->A22 swap on webs) and
            # violated frame-invariance (2026-07-16 review, confirmed numerically).
            # Apply ONLY when beta came from a raw-THETA path: MCID and :g12/:global_x
            # modes already contain the full element-frame angle (adding more would
            # double-rotate).  Rotate Cm AND Bmb (same membrane-strain frame; matches
            # how the beta block treats them).  Cb/Cs belong to the committed
            # skew-BENDING law.  Gate JFEM_SOL105_PCOMP_SKEW_MEMBRANE (default ON 2026-07-28,
            # guardrail-live).
            # The MEMBRANE (Cm/Bmb) and BENDING (Cb/Cs) halves of this frame
            # correction are gated INDEPENDENTLY.  They share the same phi and the
            # same applicability guards, but must be separable: SKEW_MEMBRANE
            # degrades the Kg w-w block (11.56% -> 30.33% on the 21.8 deg skew
            # ground-truth patch) while CB_FRAME removes the entire material-
            # orientation dependence of the bending block, so the bending fix has to
            # be landable without dragging the membrane rotation along with it.
            # Enabling both reproduces the previous nested behaviour exactly.
            skew_membrane_frame = solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true)
            skew_cb_frame = solver_env_bool("JFEM_SOL105_PCOMP_SKEW_CB_FRAME", false)
            if (skew_membrane_frame || skew_cb_frame) &&
               !is_pcomp_iso_ei && elem_is_flat
                mcid_phi = Int(q4_el_mcid[ei])
                mcid_phi_active = mcid_phi > 0 && model["CORDs"] !== nothing &&
                                  haskey(model["CORDs"], string(mcid_phi))
                if !mcid_phi_active &&
                   pcomp_axis_mode_eff !== :g12 && pcomp_axis_mode_eff !== :global_x
                    phi = shell_material_rotation_from_g12(v1, v2, v3, p1, p2, 0.0)
                    if abs(phi) > 1e-10
                        cbp = cos(phi); sbp = sin(phi)
                        c2p = cbp^2; s2p = sbp^2; csp = cbp*sbp
                        if skew_membrane_frame
                            _rotate_constitutive_3x3!(Cm_local,
                                c2p, s2p, csp, s2p, c2p, -csp, -2csp, 2csp, c2p - s2p)
                            if Bmb_local !== nothing
                                _rotate_constitutive_3x3!(Bmb_local,
                                    c2p, s2p, csp, s2p, c2p, -csp, -2csp, 2csp, c2p - s2p)
                            end
                        end
                        # BENDING frame-consistency (investigation, 2026-07-17):
                        # the bending Bb is built in the same lc frame as Bm,
                        # so Cb (and the transverse-shear Cs) have the same
                        # material-vs-lc frame mismatch the membrane had --
                        # first-order for laminates with large material-frame
                        # D16/D26 (quasi-isotropic stacks; the zb dials cannot
                        # reach it: sweep floor ~10-16%).  Diagnostic opt-in.
                        if skew_cb_frame
                            _rotate_constitutive_3x3!(Cb_local,
                                c2p, s2p, csp, s2p, c2p, -csp, -2csp, 2csp, c2p - s2p)
                            a11 = Cs_local[1,1]; a12 = Cs_local[1,2]; a22 = Cs_local[2,2]
                            Cs_local[1,1] = cbp^2*a11 + 2*cbp*sbp*a12 + sbp^2*a22
                            Cs_local[1,2] = -cbp*sbp*a11 + (cbp^2-sbp^2)*a12 + cbp*sbp*a22
                            Cs_local[2,1] = Cs_local[1,2]
                            Cs_local[2,2] = sbp^2*a11 - 2*cbp*sbp*a12 + cbp^2*a22
                        end
                    end
                end
            end
        elseif !q4_is_isotropic[ei] && q4_el_mcid[ei] > 0
            # PSHELL MAT2/MAT8 elements use the same CQUAD4 THETA/MCID material
            # axis convention as PCOMP. THETA-based PSHELL matrices are already
            # rotated while building the property resultants above; MCID-based
            # PSHELL matrices are unrotated until the element frame is known.
            beta = shell_pcomp_material_rotation(
                :element,
                v1, v2, v3, p1, p2, p3, p4,
                q4_el_theta[ei],
                q4_el_mcid[ei],
                model["CORDs"],
            )
            elem_material_shear_rotation = beta
            if abs(beta) > 1e-10
                cb = cos(beta); sb = sin(beta)
                c2 = cb^2; s2 = sb^2; cs = cb*sb
                T11 = c2;  T12 = s2;  T13 = cs
                T21 = s2;  T22 = c2;  T23 = -cs
                T31 = -2cs; T32 = 2cs; T33 = c2 - s2
                _rotate_constitutive_3x3!(Cm_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                _rotate_constitutive_3x3!(Cb_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                a11 = Cs_local[1,1]; a12 = Cs_local[1,2]; a22 = Cs_local[2,2]
                Cs_local[1,1] = cb^2*a11 + 2*cb*sb*a12 + sb^2*a22
                Cs_local[1,2] = -cb*sb*a11 + (cb^2-sb^2)*a12 + cb*sb*a22
                Cs_local[2,1] = Cs_local[1,2]
                Cs_local[2,2] = sb^2*a11 - 2*cb*sb*a12 + cb^2*a22
                if Bmb_local !== nothing
                    _rotate_constitutive_3x3!(Bmb_local, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                end
            end
        end
        elem_no_phi2 = shear_center_only && elem_is_flat && is_pcomp_ei && !is_pcomp_iso_ei && flat_pcomp_no_phi2
        # Nastran QUAD4 flat-membrane operator for COMPOSITES (identified
        # 2026-07-17, calib_bisector_membrane.jl): per-GP normal strains +
        # CENTER-sampled membrane-shear row, evaluated in the lc
        # (diagonal-bisector) frame with the frame-consistent Cm (the
        # JFEM_SOL105_PCOMP_SKEW_MEMBRANE g12 rotation puts Cm in that frame).
        # This reproduces the Nastran KGG membrane block to 0.00% on
        # parallelogram probes across skew 0-30 deg x aspect 1-5 for both the
        # [0/90/0] and 9-ply quasi-isotropic laminates -- the same
        # selective-center operator the flat-ISO exact membrane already uses
        # (for iso C the frame is irrelevant, which is why iso was already
        # exact).  Supersedes the Wilson membrane AND the hourglass
        # restabilization for these elements.  Gate
        # JFEM_SOL105_PCOMP_MEMBRANE_SELC (default ON 2026-07-28: corpus spec mean 2.62->1.02, zero-stringer controls hold);
        # requires the SKEW_MEMBRANE gate so Cm is in the lc frame, hence the
        # projection frame rotation is 0.
        # JFEM_SOL105_PCOMP_SELC_ALLOW_BMB (default OFF): admit UNSYMMETRIC
        # (Bmb != nothing) laminates to the selective-center exact membrane.
        # The selc operator replaces the MEMBRANE strain sampling only; the
        # membrane-bending coupling block is assembled separately from
        # Bmb_local, so it is preserved.  MR-skin replica DOE 2026-07-22:
        # the legacy membrane on the unsymmetric 90-heavy aspect-5.5 skins is
        # 5.9-12.6% off vs Nastran KGG while bending is 0.5-0.9% -- the gate,
        # not the operator, is the gap (same pattern as the KDJJ Bmb gate).
        # JFEM_Q4_SKEW_MEMBRANE_ALLOW_ISOTROPIC (2026-07-31: PROMOTED, default ON): both skew membrane
        # operators below (SELC and the hourglass restabilization) are gated on
        # `is_pcomp && !is_pcomp_iso`, so a flat ISOTROPIC PSHELL reaches neither and keeps
        # the legacy membrane. Measured on the single-element scoreboard, isotropic skew is
        # the worst remaining distortion axis (whole-matrix 0.33 at 45 deg, membrane block
        # 0.167) -- and this operator's own record is "membrane block 15->0.5% (skew45)",
        # i.e. the same defect it already fixes for laminates. This flag widens the material
        # gate so that claim can be MEASURED on isotropic cells before anything is promoted.
        #
        # PROMOTED 2026-07-31. Measured isotropic membrane block: skew 15/30/45 deg
        # 6.13e-2/1.09e-1/1.67e-1 -> 5.02e-5/1.66e-4/2.42e-4 (656-1200x); taper 0.7/0.5/0.25
        # 2.49e-2/4.89e-2/9.26e-2 -> 1.07e-4/5.07e-4/3.56e-3 (26-232x). Rectangles stay
        # bit-identical. Public benchmark parity: curved_beam 28.21% -> -0.29%, hemisphere
        # -3.98% -> -3.39%. Corpus: BIT-EXACT INERT on all 42 decks (||dK||/||K|| = 0.0000e+00,
        # every deck) because the corpus is PCOMP and already took this path - proven exactly
        # rather than statistically, so no spectrum screen was needed.
        skew_membrane_material_ok =
            (is_pcomp_ei && !is_pcomp_iso_ei) ||
            (solver_env_bool("JFEM_Q4_SKEW_MEMBRANE_ALLOW_ISOTROPIC", true) &&
             q4_is_isotropic[ei])
        elem_pcomp_membrane_selc =
            solver_env_bool("JFEM_SOL105_PCOMP_MEMBRANE_SELC", true) &&
            solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true) &&
            skew_membrane_material_ok && elem_is_flat &&
            (Bmb_local === nothing ||
             solver_env_bool("JFEM_SOL105_PCOMP_SELC_ALLOW_BMB", false))
        if elem_pcomp_membrane_selc
            elem_material_shear_rotation = 0.0
        end
        # Use the exact pointwise membrane field for flat orthotropic laminates.
        # The constitutive rotation already puts the element into the material
        # frame, so no additional center-row shear projection is applied here.
        elem_membrane_shear_center_row =
            (flat_iso_eig_membrane_shear_center_row && elem_is_flat && q4_is_isotropic[ei]) ||
            elem_pcomp_membrane_selc
        bend_const_scale = 1.0
        if q4_macneal_bending_scale != 1.0 &&
           q4_kernel_mode_static in ("macneal", "macneal_all", "macneal-force", "macneal_force",
                                     "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                     "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect")
            bend_const_scale *= q4_macneal_bending_scale
        end
        if q4_macneal_curved_bending_scale != 1.0 &&
           q4_kernel_mode_static in ("macneal", "macneal_all", "macneal-force", "macneal_force",
                                     "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                     "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect") &&
           pcomp_geom_curvature !== nothing
            k1_macneal, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
            kappa_l_macneal = k1_macneal * q4_curvature_characteristic_length(lc)
            cyl_ratio_macneal = q4_curvature_cyl_ratio(pcomp_geom_curvature)
            pcomp_pm45_fraction_curved_bend =
                is_pcomp_ei ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 45.0) : 0.0
            pcomp_pm90_fraction_curved_bend =
                is_pcomp_ei ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 90.0) : 0.0
            pcomp_ply_count_curved_bend =
                is_pcomp_ei ? pcomp_ply_count_from_plies(q4_ply_data[ei]) : 0
            if kappa_l_macneal >= q4_macneal_curved_bending_kappa_l_min &&
               cyl_ratio_macneal >= q4_macneal_curved_bending_cyl_ratio_min &&
               cyl_ratio_macneal <= q4_macneal_curved_bending_cyl_ratio_max &&
               aspect_ratio_ei >= q4_macneal_curved_bending_aspect_min &&
               aspect_ratio_ei <= q4_macneal_curved_bending_aspect_max &&
               flat_pcomp_h_over_lmax >= q4_macneal_curved_bending_h_over_lmax_min &&
               flat_pcomp_h_over_lmax <= q4_macneal_curved_bending_h_over_lmax_max &&
               pcomp_pm45_fraction_curved_bend >= q4_macneal_curved_bending_pm45_min &&
               pcomp_pm45_fraction_curved_bend <= q4_macneal_curved_bending_pm45_max &&
               pcomp_pm90_fraction_curved_bend >= q4_macneal_curved_bending_pm90_min &&
               pcomp_pm90_fraction_curved_bend <= q4_macneal_curved_bending_pm90_max &&
               pcomp_ply_count_curved_bend >= q4_macneal_curved_bending_ply_count_min &&
               pcomp_ply_count_curved_bend <= q4_macneal_curved_bending_ply_count_max
                bend_const_scale *= q4_macneal_curved_bending_scale
            end
        end
        if q4_macneal_bending_isolated_scale != q4_macneal_bending_scale &&
           q4_kernel_mode_static in ("macneal", "macneal_all", "macneal-force", "macneal_force",
                                     "macneal_pcomp", "macneal-pcomp", "macneal_aniso",
                                     "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect") &&
           shell_valence[i1] == 1 && shell_valence[i2] == 1 &&
           shell_valence[i3] == 1 && shell_valence[i4] == 1
            bend_const_scale *= q4_macneal_bending_isolated_scale / max(q4_macneal_bending_scale, 1e-30)
        end
        if bend_const_scale != 1.0
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                Cb_local[ii, jj] *= bend_const_scale
            end
        end
        elem_curved_iso_blend = curved_iso_blend
        if elem_shear_center_only &&
           is_iso_ei &&
           (!elem_is_flat || flat_curved_iso_center_candidate) &&
           aspect_ratio_ei <= curved_iso_square_blend_aspect_ratio_max
            elem_curved_iso_blend = min(elem_curved_iso_blend, curved_iso_square_blend)
        end
        auto_pcomp_membrane_incomp =
            shear_center_only &&
            is_pcomp_ei &&
            auto_pcomp_membrane_incomp_model
        # iso_no_incomp: disable Wilson incompatible modes for isotropic elements
        # (matches Nastran CQUAD4 standard bilinear formulation for eigenvalue K_eig)
        elem_bending_incomp = bending_incomp && !(iso_no_incomp && q4_is_isotropic[ei])
        # pcomp_membrane_incomp=true: add Wilson membrane modes for PCOMP elements in K_eig
        # (softens curved PCOMP K_eig → reduces overestimate; does not affect PSHELL elements)
        elem_membrane_incomp = membrane_incomp || auto_curved_iso_membrane_incomp ||
                               auto_warped_iso_membrane_incomp ||
                               auto_elongated_iso_membrane_incomp ||
                               auto_pcomp_membrane_incomp ||
                               (pcomp_membrane_incomp && is_pcomp_ei) ||
                               (flat_iso_eig_membrane_incomp && elem_is_flat && q4_is_isotropic[ei])
        # Skew-metric anisotropic hourglass membrane restabilization for flat
        # non-isotropic composite CQUAD4 (JFEM_SOL105_PCOMP_SKEW_MEMBRANE).  The
        # Wilson incompatible membrane over-stiffens the skew hourglass modes
        # (element KGG membrane 15% off at skew45); Nastran carries a SPLIT
        # hourglass stiffness.  Replace the Wilson membrane with a full-bilinear +
        # skew-metric hourglass correction (kernel quad4_membrane_hourglass_skew_
        # correction): membrane block 15->0.5% (skew45), 5.4->3.6% (skew20),
        # exact at rectangle.  Requires membrane Wilson OFF so the kernel's
        # membrane is pure bilinear before the correction.
        # SKEW-SCOPED (2026-07-16): the swap replaces the Wilson membrane, which
        # is the element-validated Nastran-matching operator on rectangles --
        # only elements with real corner-angle deviation get the skew kernel;
        # rectangles keep the legacy membrane bit-identically.
        # SUPERSEDED by the selective-center membrane when
        # JFEM_SOL105_PCOMP_MEMBRANE_SELC fires (2026-07-17): that operator is
        # KGG-exact at every skew/aspect, so the hourglass restabilization must
        # stay out of its way.
        elem_membrane_hourglass_skew =
            !elem_pcomp_membrane_selc &&
            solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true) &&
            skew_membrane_material_ok && elem_is_flat &&
            Bmb_local === nothing &&
            abs(90.0 - edge_skew_ei) >= sol105_pcomp_skew_membrane_min_deg()
        if elem_membrane_hourglass_skew || elem_pcomp_membrane_selc
            elem_membrane_incomp = false
        end
        elem_membrane_incomp_scale = 1.0
        # Nastran SOL101 CQUAD4 membrane matrix extractions for MAT1, MAT2,
        # and PCOMP flat quads are reproduced by condensing the cross/shear
        # Wilson membrane modes only. Mildly warped anisotropic quads still use
        # the generic material-regime scale above, but keep the full Wilson
        # basis because the cross/shear-only projection is a flat-operator
        # result. These gates depend on local geometry and constitutive
        # coupling, never deck names or validation families.
        cross_membrane_weights_topology_ok =
            q4_sol101_cross_membrane_weights_mixed_topology ||
            (!model_has_line_elements && !model_has_kinematic_constraints) ||
            (q4_sol101_cross_membrane_weights_unconstrained_mixed_topology &&
             model_has_line_elements && !model_has_kinematic_constraints)
        elem_membrane_incomp_weights =
            ((q4_sol101_cross_membrane_weights_enabled &&
              cross_membrane_weights_topology_ok) ||
             q4_sol105_cross_membrane_weights_enabled) &&
            elem_membrane_incomp &&
            elem_is_flat &&
            Bmb_local === nothing ?
            (0.0, 1.0, 1.0, 0.0) : nothing
        if elem_membrane_incomp_weights === nothing &&
           q4_sol101_mat2_directional_weights_enabled &&
           elem_membrane_incomp &&
           q4_pshell_mat2[ei] &&
           Bmb_local === nothing &&
           aspect_ratio_ei >= q4_sol101_mat2_directional_aspect_min &&
           warp_ratio_ei <= q4_sol101_mat2_directional_warp_max &&
           flat_pcomp_h_over_l <= q4_sol101_mat2_directional_h_over_l_max
            cm_den = sqrt(max(abs(Cm_local[1,1] * Cm_local[2,2]), 1e-30))
            c16_ratio = abs(Cm_local[1,3]) / cm_den
            c26_ratio = abs(Cm_local[2,3]) / cm_den
            if c16_ratio <= q4_sol101_mat2_directional_c16_max &&
               c26_ratio <= q4_sol101_mat2_directional_c16_max
                elem_membrane_incomp_weights = (
                    q4_sol101_mat2_directional_wx,
                    q4_sol101_mat2_directional_wy,
                    q4_sol101_mat2_directional_wx,
                    q4_sol101_mat2_directional_wy,
                )
            end
        end
        # Formal flat symmetric-laminate plate/shell regime:
        # use a DKMQ-style stiffness split (membrane + MITC shear + DKQ bending)
        # when the laminate has no membrane-bending coupling and the geometry is flat.
        elem_flat_dkmq_branch = flat_pcomp_dkmq_branch &&
                                elem_is_flat &&
                                is_pcomp_ei &&
                                !is_pcomp_iso_ei &&
                                !elem_macneal_rigid_shear &&
                                Bmb_local === nothing &&
                                maximum(abs, Cb_local) > 1e-30
        # Experimental flat-laminate plate branch: restrict to regular rectangular
        # quads and low-coupling laminates where the DKQ path has shown cleaner
        # buckling parity on the a500 family without harming the main guardrails.
        elem_flat_plate_auto = flat_pcomp_plate_auto &&
                               elem_is_flat &&
                               is_pcomp_ei &&
                               !is_pcomp_iso_ei &&
                               Bmb_local === nothing &&
                               maximum(abs, Cb_local) > 1e-30 &&
                               FEM.quad4_is_axis_aligned_rectangle(lc) &&
                               q4_pcomp_d16_ratio[ei] <= flat_pcomp_plate_auto_d16_ratio_max &&
                               q4_pcomp_shear_ratio[ei] <= flat_pcomp_plate_auto_shear_ratio_max
        elem_flat_iso_exact_membrane = flat_iso_dkmq_branch &&
                                       !model_has_line_elements &&
                                       is_iso_ei &&
                                       Bmb_local === nothing &&
                                       elem_is_flat &&
                                       !node_has_line[i1] && !node_has_line[i2] &&
                                       !node_has_line[i3] && !node_has_line[i4] &&
                                       geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4] &&
                                       q4_geom_normals_nearly_constant(
                                           geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4]
                                       )
        elem_flat_curved_iso_exact_membrane = flat_iso_dkmq_branch &&
                                              is_iso_ei &&
                                              Bmb_local === nothing &&
                                              flat_curved_iso_center_candidate &&
                                              aspect_ratio_ei <= flat_curved_iso_exact_membrane_aspect_ratio_max
        elem_saddle_iso_exact_membrane = false
        elem_cyl_iso_exact_membrane = flat_iso_dkmq_branch &&
                                      is_iso_ei &&
                                      Bmb_local === nothing &&
                                      !elem_is_flat &&
                                      iso_corner_curvature !== nothing &&
                                      abs(q4_curvature_gaussian(iso_corner_curvature)) <= 1e-10 &&
                                      first(q4_curvature_principal_abs(iso_corner_curvature)) > 1e-8
        elem_iso_exact_membrane =
            elem_flat_iso_exact_membrane || elem_flat_curved_iso_exact_membrane ||
            elem_saddle_iso_exact_membrane || elem_cyl_iso_exact_membrane
        elem_pcomp_exact_membrane = flat_pcomp_exact_membrane &&
                                    !model_has_line_elements &&
                                    !model_has_kinematic_constraints &&
                                    elem_is_flat &&
                                    is_pcomp_ei &&
                                    !is_pcomp_iso_ei &&
                                    Bmb_local === nothing
        elem_sol101_pcomp_exact_membrane =
            sol101_flat_pcomp_exact_membrane &&
            elem_is_flat &&
            is_pcomp_ei &&
            !is_pcomp_iso_ei &&
            Bmb_local === nothing
        elem_sol105_static_pcomp_exact_membrane =
            sol105_static_pcomp_exact_membrane &&
            is_pcomp_ei &&
            !is_pcomp_iso_ei &&
            Bmb_local === nothing &&
            (elem_is_flat ||
             solver_env_bool("JFEM_SOL105_STATIC_PCOMP_EXACT_MEMBRANE_ALLOW_NONFLAT", false))
        elem_sol101_iso_exact_membrane =
            sol101_flat_iso_exact_membrane &&
            elem_is_flat &&
            is_iso_ei &&
            Bmb_local === nothing
        elem_exact_membrane_operator =
            elem_iso_exact_membrane || elem_pcomp_exact_membrane ||
            elem_sol101_pcomp_exact_membrane || elem_sol101_iso_exact_membrane ||
            elem_sol105_static_pcomp_exact_membrane
        # Flat facets on a curved shell patch still need the membrane-to-w
        elem_iso_exact_membrane_curvature_w_coupling =
            elem_cyl_iso_exact_membrane
        if curvature_membrane === nothing && elem_cyl_iso_exact_membrane && iso_corner_curvature !== nothing
            # For developable cylindrical shells, the exact membrane splice needs
            # the actual geometric curvature tensor. The generic SNORM-based
            # curvature filter is often inactive on these coarse barrel patches.
            curvature_membrane = iso_corner_curvature
        end
        elem_flat_plate_branch = (flat_pcomp_plate_branch || elem_flat_plate_auto) &&
                                 elem_is_flat &&
                                 is_pcomp_ei &&
                                 !is_pcomp_iso_ei &&
                                 !elem_macneal_rigid_shear &&
                                 Bmb_local === nothing &&
                                 maximum(abs, Cb_local) > 1e-30
        elem_rect_plate_branch = flat_pcomp_rect_adini && elem_flat_plate_branch && FEM.quad4_is_axis_aligned_rectangle(lc)
        elem_fullshear_selective = flat_pcomp_fullshear_selective &&
                                   elem_is_flat &&
                                   is_pcomp_ei &&
                                   !is_pcomp_iso_ei &&
                                   !elem_shear_center_only &&
                                   Bmb_local === nothing
        elem_flat_iso_fullshear_selective_mode =
            shear_center_only &&
            elem_is_flat &&
            q4_is_isotropic[ei] &&
            !elem_shear_center_only &&
            flat_iso_fullshear_selective_mode != :none ? flat_iso_fullshear_selective_mode : :none
        elem_selective_shear = elem_fullshear_selective || elem_flat_iso_fullshear_selective_mode != :none
        elem_selective_shear_mode =
            elem_flat_iso_fullshear_selective_mode != :none ? elem_flat_iso_fullshear_selective_mode : :all
        pcomp_cs_over_cm_ei = q4_pcomp_cs_over_cm(Cm_local, Cs_local)
        elem_macneal_rbf_flex_mode = :env
        elem_q4_kernel_mode_static = q4_kernel_mode_static
        elem_exact_side_shear = flat_pcomp_exact_side_shear &&
                                elem_is_flat &&
                                is_pcomp_ei &&
                                !is_pcomp_iso_ei &&
                                !elem_shear_center_only &&
                                Bmb_local === nothing
        if !elem_exact_side_shear &&
           flat_curved_pcomp_exact_side_shear &&
           flat_curved_pcomp_fullshear_candidate &&
           !elem_shear_center_only &&
           Bmb_local === nothing
            elem_exact_side_shear = true
        end
        if !elem_exact_side_shear &&
           flat_iso_exact_side_shear &&
           elem_is_flat &&
           is_iso_ei &&
           elem_flat_curved_iso_exact_membrane &&
           Bmb_local === nothing
            elem_exact_side_shear = true
        end
        elem_exact_side_rotcorr = flat_pcomp_exact_side_rotcorr &&
                                  elem_is_flat &&
                                  is_pcomp_ei &&
                                  !is_pcomp_iso_ei &&
                                  !elem_shear_center_only &&
                                  Bmb_local === nothing
        elem_flat_curved_iso_nodal_geomnormal_transform =
            flat_curved_iso_nodal_geomnormal_transform &&
            q4_is_isotropic[ei] &&
            elem_is_flat &&
            elem_flat_curved_iso_exact_membrane &&
            aspect_ratio_ei >= flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min &&
            (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <=
                flat_curved_iso_nodal_geomnormal_transform_valence_sum_max &&
            geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
        elem_static_pcomp_nodal_geomnormal_transform =
            static_pcomp_nodal_geomnormal_transform &&
            is_pcomp_ei &&
            geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
        elem_mitc4_3d_kernel =
            if mitc4_3d_all_kernel
                true
            elseif mitc4_3d_aspect_kernel
                kappa_l_mitc4_3d_aspect = 0.0
                cyl_ratio_mitc4_3d_aspect = 0.0
                if pcomp_geom_curvature !== nothing
                    k1_mitc4_3d_aspect, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
                    kappa_l_mitc4_3d_aspect =
                        k1_mitc4_3d_aspect * q4_curvature_characteristic_length(lc)
                    cyl_ratio_mitc4_3d_aspect =
                        q4_curvature_cyl_ratio(pcomp_geom_curvature)
                end
                q4_mitc4_3d_aspect_geom_ok(
                    aspect_ratio_ei,
                    warp_ratio_ei,
                    kappa_l_mitc4_3d_aspect,
                    edge_skew_ei,
                    mitc4_3d_aspect_min,
                    mitc4_3d_aspect_max,
                    mitc4_3d_aspect_warp_min,
                    mitc4_3d_aspect_warp_max,
                    mitc4_3d_aspect_kappa_l_min,
                    mitc4_3d_aspect_kappa_l_max,
                    mitc4_3d_aspect_skew_min,
                    mitc4_3d_aspect_skew_max,
                    mitc4_3d_aspect_skew_aspect_min,
                ) &&
                cyl_ratio_mitc4_3d_aspect >= mitc4_3d_aspect_cyl_ratio_min &&
                cyl_ratio_mitc4_3d_aspect <= mitc4_3d_aspect_cyl_ratio_max &&
                flat_pcomp_h_over_l >= mitc4_3d_aspect_h_over_l_min &&
                flat_pcomp_h_over_l <= mitc4_3d_aspect_h_over_l_max &&
                flat_pcomp_h_over_lmax >= mitc4_3d_aspect_h_over_lmax_min &&
                flat_pcomp_h_over_lmax <= mitc4_3d_aspect_h_over_lmax_max &&
                (!mitc4_3d_aspect_pcomp_only || is_pcomp_ei)
            else
                false
            end
        elem_macneal_static_kernel &&
            (elem_mitc4_3d_kernel = false)
        if elem_snorm_curvature
            # The common PARAM,SNORM normal-moment map wraps the projected
            # CQUAD4 kernel, including exact-membrane, MIN4 and Hu-Washizu
            # branches. Quarantine standalone plate, 3-D-director, and
            # geometry-normal scatter experiments that bypass that map.
            elem_mitc4_3d_kernel = false
            elem_flat_dkmq_branch = false
            elem_flat_plate_branch = false
            elem_rect_plate_branch = false
            elem_flat_curved_iso_nodal_geomnormal_transform = false
            elem_static_pcomp_nodal_geomnormal_transform = false
            elem_exact_side_shear = false
            elem_exact_side_rotcorr = false
        end
        elem_pcomp_k_macneal_blend = 0.0
        if sol105_context && is_pcomp_ei && !is_pcomp_iso_ei
            kappa_l_kblend = kappa_l_kernel
            if kappa_l_kblend == 0.0 && pcomp_geom_curvature !== nothing
                k1_kblend, _ = q4_curvature_principal_abs(pcomp_geom_curvature)
                kappa_l_kblend = k1_kblend * q4_curvature_characteristic_length(lc)
            end
            alpha_kblend, beta_kblend, gamma_kblend, delta_kblend =
                pcomp_nemeth_parameters_from_cb(
                    @view(q4_Cb_flat[:, :, ei]),
                    1.0 / max(aspect_ratio_ei, 1.0),
                )
            elem_pcomp_k_macneal_blend = sol105_pcomp_k_macneal_blend(
                is_pcomp_ei,
                is_pcomp_iso_ei,
                aspect_ratio_ei,
                taper_ratio_ei,
                flat_pcomp_h_over_lmax,
                warp_ratio_ei,
                kappa_l_kblend,
                pcomp_pm45_fraction_selector,
                pcomp_pm90_fraction_selector,
                pcomp_ply_count_selector,
                alpha_kblend,
                beta_kblend,
                gamma_kblend,
                delta_kblend,
            )
        end
        if k_diag_enabled
            nemeth_alpha_diag = 0.0
            nemeth_beta_diag = 0.0
            nemeth_gamma_diag = 0.0
            nemeth_delta_diag = 0.0
            if is_pcomp_ei
                nemeth_alpha_diag, nemeth_beta_diag, nemeth_gamma_diag, nemeth_delta_diag =
                    pcomp_nemeth_parameters_from_cb(
                        @view(q4_Cb_flat[:, :, ei]),
                        1.0 / max(aspect_ratio_ei, 1.0),
                    )
            end
            pcomp_pm45_diag = is_pcomp_ei ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 45.0) : 0.0
            pcomp_pm90_diag = is_pcomp_ei ? pcomp_abs_angle_fraction_from_plies(q4_ply_data[ei], 90.0) : 0.0
            pcomp_ply_diag = is_pcomp_ei ? pcomp_ply_count_from_plies(q4_ply_data[ei]) : 0
            k_diag_rows[ei] = string(
                shear_center_only ? "eig" : "static", ",",
                q4_eid_int[ei], ",",
                q4_pid_int[ei], ",",
                q4_kernel_mode_static, ",",
                elem_q4_kernel_mode_static, ",",
                elem_kernel_planar ? 1 : 0, ",",
                elem_macneal_static_kernel ? 1 : 0, ",",
                elem_force_macneal_by_geometry ? 1 : 0, ",",
                elem_force_macneal_by_load ? 1 : 0, ",",
                on_macneal_by_curvature ? 1 : 0, ",",
                on_macneal_by_thickness ? 1 : 0, ",",
                on_macneal_by_nemeth ? 1 : 0, ",",
                elem_mitc4_3d_kernel ? 1 : 0, ",",
                0, ",",
                elem_pcomp_k_macneal_blend, ",",
                elem_shear_center_only ? 1 : 0, ",",
                elem_is_flat ? 1 : 0, ",",
                aspect_ratio_ei, ",",
                taper_ratio_ei, ",",
                warp_ratio_ei, ",",
                kappa_l_kernel, ",",
                edge_skew_ei, ",",
                is_pcomp_ei ? 1 : 0, ",",
                is_pcomp_iso_ei ? 1 : 0, ",",
                q4_h[ei], ",",
                flat_pcomp_h_over_l, ",",
                flat_pcomp_h_over_lmax, ",",
                pcomp_pm45_diag, ",",
                pcomp_pm90_diag, ",",
                pcomp_ply_diag, ",",
                q4_pcomp_shear_ratio[ei], ",",
                q4_pcomp_d16_ratio[ei], ",",
                q4_pcomp_b_ratio[ei], ",",
                nemeth_alpha_diag, ",",
                nemeth_beta_diag, ",",
                nemeth_gamma_diag, ",",
                nemeth_delta_diag, ",",
                bend_const_scale, ",",
                pcomp_cs_over_cm_ei,
            )
        end
        elem_static_component_scale_ok =
            static_component_v2_gate_ok &&
            (!static_component_require_pshell_mat2 || q4_pshell_mat2[ei]) &&
            (!static_component_require_pcomp || is_pcomp_ei) &&
            q4_static_component_range_ok(q4_h[ei],
                                         static_component_thickness_min,
                                         static_component_thickness_max) &&
            q4_static_component_range_ok(aspect_ratio_ei,
                                         static_component_aspect_min,
                                         static_component_aspect_max) &&
            q4_static_component_range_ok(taper_ratio_ei,
                                         static_component_taper_min,
                                         static_component_taper_max) &&
            q4_static_component_range_ok(flat_pcomp_h_over_l,
                                         static_component_h_over_l_min,
                                         static_component_h_over_l_max) &&
            q4_static_component_range_ok(warp_ratio_ei,
                                         static_component_warp_min,
                                         static_component_warp_max) &&
            q4_static_component_pcomp_range_ok(is_pcomp_ei,
                                               q4_pcomp_shear_ratio[ei],
                                               static_component_pcomp_shear_ratio_min,
                                               static_component_pcomp_shear_ratio_max) &&
            q4_static_component_pcomp_range_ok(is_pcomp_ei,
                                               q4_pcomp_d16_ratio[ei],
                                               static_component_pcomp_d16_ratio_min,
                                               static_component_pcomp_d16_ratio_max) &&
            q4_static_component_pcomp_range_ok(is_pcomp_ei,
                                               q4_pcomp_b_ratio[ei],
                                               static_component_pcomp_b_ratio_min,
                                               static_component_pcomp_b_ratio_max)
        elem_static_component_cm_scale = elem_static_component_scale_ok ? static_component_cm_scale : 1.0
        elem_static_component_cm11_scale = elem_static_component_scale_ok ? static_component_cm11_scale : 1.0
        elem_static_component_cm22_scale = elem_static_component_scale_ok ? static_component_cm22_scale : 1.0
        elem_static_component_cm66_scale = elem_static_component_scale_ok ? static_component_cm66_scale : 1.0
        elem_static_component_cb_scale = elem_static_component_scale_ok ? static_component_cb_scale : 1.0
        elem_static_component_cs_scale = elem_static_component_scale_ok ? static_component_cs_scale : 1.0
        elem_static_component_bmb_scale = elem_static_component_scale_ok ? static_component_bmb_scale : 1.0
        elem_static_component_drill_scale = elem_static_component_scale_ok ? static_component_drill_scale : 1.0
        if sol101_pshell_mat2_cb_scale != 1.0 &&
           !is_pcomp_ei &&
           q4_pshell_mat2[ei] &&
           q4_pshell_blank_mid3[ei]
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                Cb_local[ii, jj] *= sol101_pshell_mat2_cb_scale
            end
        end
        if elem_static_component_cm_scale != 1.0
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                Cm_local[ii, jj] *= elem_static_component_cm_scale
            end
        end
        if elem_static_component_cm11_scale != 1.0 ||
           elem_static_component_cm22_scale != 1.0 ||
           elem_static_component_cm66_scale != 1.0
            s1 = sqrt(elem_static_component_cm11_scale)
            s2 = sqrt(elem_static_component_cm22_scale)
            s3 = sqrt(elem_static_component_cm66_scale)
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                si = ii == 1 ? s1 : ii == 2 ? s2 : s3
                sj = jj == 1 ? s1 : jj == 2 ? s2 : s3
                Cm_local[ii, jj] *= si * sj
            end
        end
        if elem_static_component_cb_scale != 1.0
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                Cb_local[ii, jj] *= elem_static_component_cb_scale
            end
        end
        if elem_static_component_cs_scale != 1.0
            @inbounds @fastmath for jj in 1:2, ii in 1:2
                Cs_local[ii, jj] *= elem_static_component_cs_scale
            end
        end
        if Bmb_local !== nothing && elem_static_component_bmb_scale != 1.0
            @inbounds @fastmath for jj in 1:3, ii in 1:3
                Bmb_local[ii, jj] *= elem_static_component_bmb_scale
            end
        end
        if elem_static_component_drill_scale != 1.0
            elem_drill_scale *= elem_static_component_drill_scale
        end
        if elem_mitc4_3d_kernel
            if mitc4_3d_ply_integration &&
               is_pcomp_ei &&
               q4_ply_data[ei] !== nothing
                Ke_t = FEM.stiffness_quad4_mitc4_3d_ply_matrices(
                    c3d_local, dirs_local, q4_ply_data[ei], Cs_local,
                    q4_h[ei], q4_Eref[ei];
                    k6rot=elem_k6rot,
                    drill_scale=elem_drill_scale,
                    shear_center_only=elem_shear_center_only,
                    material_rotation=elem_material_shear_rotation,
                    local_bending_scale=bend_const_scale,
                )
            else
                Ke_t = FEM.stiffness_quad4_mitc4_3d_resultant_matrices(
                    c3d_local, dirs_local, Cm_local, Cb_local, Cs_local,
                    q4_h[ei], q4_Eref[ei];
                    k6rot=elem_k6rot,
                    drill_scale=elem_drill_scale,
                    Bmb=Bmb_local,
                    shear_center_only=elem_shear_center_only,
                    bending_incomp=elem_bending_incomp,
                )
            end
        elseif elem_shear_center_only && is_iso_ei
            Ke_center = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                drill_scale=elem_drill_scale,
                ws=ws_stiff, msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=true,
                no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                membrane_incomp_scale=elem_membrane_incomp_scale,
                membrane_incomp_weights=elem_membrane_incomp_weights,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                exact_membrane_operator=elem_exact_membrane_operator,
                exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                exact_side_shear=elem_exact_side_shear,
                exact_side_rotcorr=elem_exact_side_rotcorr,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
            Ke_full = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                drill_scale=elem_drill_scale,
                ws=per_thread_ws_alt[tid], msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=false,
                no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                membrane_incomp_scale=elem_membrane_incomp_scale,
                membrane_incomp_weights=elem_membrane_incomp_weights,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                exact_membrane_operator=elem_exact_membrane_operator,
                exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                exact_side_shear=elem_exact_side_shear,
                exact_side_rotcorr=elem_exact_side_rotcorr,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
            Ke_t = sep_Ke_blend[tid]
            @inbounds @fastmath for jj in 1:24, ii in 1:24
                Ke_t[ii, jj] = (1.0 - elem_curved_iso_blend) * Ke_center[ii, jj] +
                               elem_curved_iso_blend * Ke_full[ii, jj]
            end
        elseif elem_flat_dkmq_branch
            Ke_t = FEM.stiffness_quad4_plate_dkmq_matrices(
                lc, Cm_local, Cb_local, Cs_local, q4_h[ei], q4_Eref[ei];
                k6rot=elem_k6rot,
                drill_scale=elem_drill_scale,
                ws=ws_stiff,
                membrane_incomp=elem_membrane_incomp,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row,
                material_shear_rotation=elem_material_shear_rotation,
            )
        elseif elem_rect_plate_branch
            Ke_t = FEM.stiffness_quad4_plate_adini_matrices(
                lc, Cm_local, Cb_local, Cs_local, q4_h[ei], q4_Eref[ei];
                k6rot=elem_k6rot,
                drill_scale=elem_drill_scale,
                ws=ws_stiff,
                membrane_incomp=elem_membrane_incomp,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row,
                material_shear_rotation=elem_material_shear_rotation,
            )
        elseif elem_flat_plate_branch
            Ke_t = FEM.stiffness_quad4_plate_dkq_matrices(
                lc, Cm_local, Cb_local, Cs_local, q4_h[ei], q4_Eref[ei];
                k6rot=elem_k6rot,
                drill_scale=elem_drill_scale,
                ws=ws_stiff,
                membrane_incomp=elem_membrane_incomp,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row,
                material_shear_rotation=elem_material_shear_rotation,
            )
        elseif elem_shear_center_only && is_pcomp_ei
            if elem_is_flat && !is_pcomp_iso_ei
                Ke_t = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                    q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                    drill_scale=elem_drill_scale,
                    ws=ws_stiff, msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=true,
                    no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                    membrane_incomp_scale=elem_membrane_incomp_scale,
                    membrane_incomp_weights=elem_membrane_incomp_weights,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                    exact_membrane_operator=elem_exact_membrane_operator,
                    exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                    selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                    exact_side_shear=elem_exact_side_shear,
                    exact_side_rotcorr=elem_exact_side_rotcorr,
                    slope_membrane=slope_membrane,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
            elseif curved_pcomp_blend < 1.0
                Ke_center = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                    q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                    drill_scale=elem_drill_scale,
                    ws=ws_stiff, msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=true,
                    no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                    membrane_incomp_scale=elem_membrane_incomp_scale,
                    membrane_incomp_weights=elem_membrane_incomp_weights,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                    exact_membrane_operator=elem_exact_membrane_operator,
                    exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                    selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                    exact_side_shear=elem_exact_side_shear,
                    exact_side_rotcorr=elem_exact_side_rotcorr,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
                Ke_full = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                    q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                    drill_scale=elem_drill_scale,
                    ws=per_thread_ws_alt[tid], msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=false,
                    no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                    membrane_incomp_scale=elem_membrane_incomp_scale,
                    membrane_incomp_weights=elem_membrane_incomp_weights,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                    exact_membrane_operator=elem_exact_membrane_operator,
                    exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                    selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                    exact_side_shear=elem_exact_side_shear,
                    exact_side_rotcorr=elem_exact_side_rotcorr,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
                Ke_t = sep_Ke_blend[tid]
                @inbounds @fastmath for jj in 1:24, ii in 1:24
                    Ke_t[ii, jj] = (1.0 - curved_pcomp_blend) * Ke_center[ii, jj] +
                                   curved_pcomp_blend * Ke_full[ii, jj]
                end
            else
                Ke_t = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                    q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                    drill_scale=elem_drill_scale,
                    ws=ws_stiff, msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=false,
                    no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                    membrane_incomp_scale=elem_membrane_incomp_scale,
                    membrane_incomp_weights=elem_membrane_incomp_weights,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                exact_membrane_operator=elem_exact_membrane_operator,
                exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                exact_side_shear=elem_exact_side_shear,
                exact_side_rotcorr=elem_exact_side_rotcorr,
                slope_membrane=slope_membrane,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
            end
        else
            Ke_t = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                drill_scale=elem_drill_scale,
                ws=ws_stiff, msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp, shear_center_only=elem_shear_center_only,
                no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                membrane_incomp_scale=elem_membrane_incomp_scale,
                membrane_incomp_weights=elem_membrane_incomp_weights,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                exact_membrane_operator=elem_exact_membrane_operator,
                exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                exact_side_shear=elem_exact_side_shear,
                exact_side_rotcorr=elem_exact_side_rotcorr,
                slope_membrane=slope_membrane,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=elem_kernel_planar,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode=elem_q4_kernel_mode_static,
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
        end
        if elem_pcomp_k_macneal_blend > 0.0
            Ke_ref = copyto!(sep_Ke_ref[tid], Ke_t)
            Ke_macneal = FEM.stiffness_quad4_matrices(lc, Cm_local, Cb_local, Cs_local,
                q4_h[ei], q4_Eref[ei]; bend_ratio=q4_br[ei], k6rot=elem_k6rot, Bmb=Bmb_local,
                drill_scale=elem_drill_scale,
                ws=per_thread_ws_alt[tid], msws=per_thread_msws[tid], bending_incomp=elem_bending_incomp,
                shear_center_only=elem_shear_center_only,
                no_phi2=elem_no_phi2, membrane_incomp=elem_membrane_incomp,
                membrane_incomp_scale=elem_membrane_incomp_scale,
                membrane_incomp_weights=elem_membrane_incomp_weights,
                curvature_membrane=curvature_membrane,
                membrane_shear_center_row=elem_membrane_shear_center_row, material_shear_rotation=elem_material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                exact_membrane_operator=elem_exact_membrane_operator,
                exact_membrane_curvature_w_coupling=elem_iso_exact_membrane_curvature_w_coupling,
                selective_shear=elem_selective_shear, selective_shear_mode=elem_selective_shear_mode,
                exact_side_shear=elem_exact_side_shear,
                exact_side_rotcorr=elem_exact_side_rotcorr,
                slope_membrane=slope_membrane,
                coords_3d=coords_3d_arg, snorm_pq=snorm_pq_arg,
                kernel_planar=true,
                macneal_rigid_shear=elem_macneal_rigid_shear,
                bmb_incomp_coupling_mode=q4_bmb_incomp_coupling_mode,
                kernel_mode="macneal_all",
                macneal_rbf_flex_mode=elem_macneal_rbf_flex_mode,
                membrane_hourglass_skew=elem_membrane_hourglass_skew)
            Ke_macneal_ref = copyto!(sep_Ke_macneal[tid], Ke_macneal)
            Ke_t = sep_Ke_blend[tid]
            @inbounds @fastmath for jj in 1:24, ii in 1:24
                Ke_t[ii, jj] =
                    (1.0 - elem_pcomp_k_macneal_blend) * Ke_ref[ii, jj] +
                    elem_pcomp_k_macneal_blend * Ke_macneal_ref[ii, jj]
            end
        end

        q4_macneal_interaction_skipped[ei] = msws_e.interaction_skipped

        ke_t_global_ready = false

        # Concretize Ke_t exactly once (folds the old conditional Matrix()
        # conversion in the drilling-scale block below): the 8-way kernel
        # branch table leaves Ke_t union-typed, which boxed every load in the
        # transform/triplet tail. Every branch produces Matrix{Float64} at
        # runtime, so this is an alias — no copy — on the hot path.
        Ke_m = Ke_t isa Matrix{Float64} ? Ke_t : Matrix{Float64}(Ke_t)

        if sol101_line_node_drill_sqrt_scale != 1.0 &&
           (node_has_frame[i1] || node_has_frame[i2] || node_has_frame[i3] || node_has_frame[i4])
            node_has_frame[i1] && scale_shell_local_drilling_dof!(Ke_m, 1, sol101_line_node_drill_sqrt_scale)
            node_has_frame[i2] && scale_shell_local_drilling_dof!(Ke_m, 2, sol101_line_node_drill_sqrt_scale)
            node_has_frame[i3] && scale_shell_local_drilling_dof!(Ke_m, 3, sol101_line_node_drill_sqrt_scale)
            node_has_frame[i4] && scale_shell_local_drilling_dof!(Ke_m, 4, sol101_line_node_drill_sqrt_scale)
        end

        _quad4_transform_emit!(
            sep_global[tid], sep_T[tid], sep_tmp[tid], sep_dofs[tid],
            Ke_m, ke_t_global_ready,
            ei, i1, i2, i3, i4,
            v1, v2, v3,
            snorm_transform_only, snorm_xf_ok, snorm_xf_v3,
            elem_flat_curved_iso_nodal_geomnormal_transform,
            elem_static_pcomp_nodal_geomnormal_transform,
            geom_vec, node_R_flat,
            snorm_director, snorm_has, snorm_vec,
            all_I, all_J, all_V)
    end

    LinearAlgebra.BLAS.set_num_threads(prev_blas_threads)

    # ONE summary line for the MacNeal interaction fallback (never per element:
    # a production model has 10^5 CQUAD4). Silent when nothing fell back.
    n_macneal_skip = count(q4_macneal_interaction_skipped)
    if n_macneal_skip > 0
        skip_eids = String[]
        for ei in 1:n_q4
            q4_macneal_interaction_skipped[ei] || continue
            push!(skip_eids, string(q4_eid_int[ei]))
            length(skip_eids) >= 10 && break
        end
        log_msg("[SOLVER] MacNeal interaction correction skipped on " *
                "$n_macneal_skip of $n_q4 CQUAD4 (degenerate assumed-shear " *
                "companion); example EIDs: " * join(skip_eids, ", ") *
                (n_macneal_skip > length(skip_eids) ? ", ..." : ""))
    end

    if k_diag_enabled
        try
            mkpath(dirname(k_diag_eid_csv_path))
            open(k_diag_eid_csv_path, "w") do io
                println(io, "analysis,eid,pid,kernel_mode_static,elem_kernel_mode_static,elem_kernel_planar,elem_macneal_static_kernel,elem_force_macneal_by_geometry,elem_force_macneal_by_load,on_macneal_by_curvature,on_macneal_by_thickness,on_macneal_by_nemeth,elem_mitc4_3d_kernel,elem_mitc4_3d_geom_restore,pcomp_k_macneal_blend,elem_shear_center_only,elem_is_flat,aspect,taper,warp,kappa_l_kernel,edge_skew,is_pcomp,pcomp_is_isotropic,h,h_over_l,h_over_lmax,pcomp_pm45_fraction,pcomp_pm90_fraction,pcomp_ply_count,pcomp_shear_ratio,pcomp_d16_ratio,pcomp_b_ratio,pcomp_nemeth_alpha,pcomp_nemeth_beta,pcomp_nemeth_gamma,pcomp_nemeth_delta,bend_const_scale,pcomp_cs_over_cm")
                for row in k_diag_rows
                    println(io, row)
                end
            end
        catch err
            log_msg("[SOLVER] WARNING: failed to write JFEM_K_DIAG_EID_CSV -> $k_diag_eid_csv_path: $err")
        end
    end

    I_idx = Vector{Int}(undef, 0); J_idx = Vector{Int}(undef, 0); V_val = Vector{Float64}(undef, 0)
    est_total = length(all_V) + n_t3*324 + length(cbars)*144 + length(cbeams)*144 + length(crods)*144
    sizehint!(I_idx, est_total); sizehint!(J_idx, est_total); sizehint!(V_val, est_total)
    append!(I_idx, all_I); append!(J_idx, all_J); append!(V_val, all_V)
    all_I = Int[]; all_J = Int[]; all_V = Float64[]

    # --- SEQUENTIAL TRIA3 ASSEMBLY ---
    lc_buf = zeros(3, 2)
    T_buf = zeros(18, 18)
    dofs_t3 = Vector{Int}(undef, 18)
    for ei in 1:n_t3
        i1 = t3_idx[ei,1]; i2 = t3_idx[ei,2]; i3 = t3_idx[ei,3]
        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])
        v1, v2, v3 = shell_element_frame_fast(p1, p2, p3, SVector{3}(0.0,0.0,0.0), 3)

        # SNORM adjustment
        n_avg = SVector(0.0, 0.0, 0.0); nc = 0
        for idx in (i1, i2, i3)
            if snorm_has[idx]; n_avg = n_avg + snorm_vec[idx]; nc += 1; end
        end
        if nc > 0
            n_avg_s = n_avg / nc; len_s = norm(n_avg_s)
            if len_s > 1e-12
                v3n = SVector{3}(n_avg_s / len_s)
                if dot(v3n, v3) < 0.0; v3n = -v3n; end
                if !snorm_director && dot(v3n, v3) >= snorm_tilt_gate_cos  # DIAGNOSTIC gate (K/Kg-consistent)
                    v1p = v1 - dot(v1, v3n) * v3n; v1l = norm(v1p)
                    if v1l > 1e-12
                        v1n = SVector{3}(v1p / v1l)
                    else
                        v2p = v2 - dot(v2, v3n) * v3n; v1n = SVector{3}(normalize(v2p))
                    end
                    v1, v2, v3 = v1n, SVector{3}(cross(v3n, v1n)), v3n
                end
            end
        end

        # PCOMP laminate-axis rotation for TRIA3 follows the element x-axis
        # plus the shell THETA angle, matching Nastran shell convention.
        Cm_t3 = t3_Cm[ei]; Cb_t3 = t3_Cb[ei]; Cs_t3 = t3_Cs[ei]; Bmb_t3 = t3_Bmb[ei]
        if t3_is_pcomp[ei]
            beta = shell_pcomp_material_rotation(
                pcomp_axis_mode,
                v1, v2, v3, p1, p2,
                t3_el_theta[ei],
                t3_el_mcid[ei],
                model["CORDs"],
            )
            if abs(beta) > 1e-10
                Cm_t3 = copy(Cm_t3); Cb_t3 = copy(Cb_t3); Cs_t3 = copy(Cs_t3)
                cb = cos(beta); sb = sin(beta)
                c2 = cb^2; s2 = sb^2; cs = cb*sb
                T11 = c2;  T12 = s2;  T13 = cs
                T21 = s2;  T22 = c2;  T23 = -cs
                T31 = -2cs; T32 = 2cs; T33 = c2 - s2
                _rotate_constitutive_3x3!(Cm_t3, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                _rotate_constitutive_3x3!(Cb_t3, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                a11 = Cs_t3[1,1]; a12 = Cs_t3[1,2]; a22 = Cs_t3[2,2]
                Cs_t3[1,1] = cb^2*a11 + 2*cb*sb*a12 + sb^2*a22
                Cs_t3[1,2] = -cb*sb*a11 + (cb^2-sb^2)*a12 + cb*sb*a22
                Cs_t3[2,1] = Cs_t3[1,2]
                Cs_t3[2,2] = sb^2*a11 - 2*cb*sb*a12 + cb^2*a22
                if Bmb_t3 !== nothing
                    Bmb_t3 = copy(Bmb_t3)
                    _rotate_constitutive_3x3!(Bmb_t3, T11, T12, T13, T21, T22, T23, T31, T32, T33)
                end
            end
        end

        c = (p1 + p2 + p3) / 3.0
        lc_buf[1,1] = dot(p1-c, v1); lc_buf[1,2] = dot(p1-c, v2)
        lc_buf[2,1] = dot(p2-c, v1); lc_buf[2,2] = dot(p2-c, v2)
        lc_buf[3,1] = dot(p3-c, v1); lc_buf[3,2] = dot(p3-c, v2)
        elem_k6rot_t3 = t3_br[ei] <= 1e-12 ? 0.0 : k6rot
        Ke_loc = FEM.stiffness_tria3_matrices(lc_buf, Cm_t3, Cb_t3, Cs_t3,
                    t3_h[ei], t3_Eref[ei]; bend_ratio=t3_br[ei], k6rot=elem_k6rot_t3, Bmb=Bmb_t3)
        if sol101_line_node_drill_sqrt_scale != 1.0 &&
           (node_has_frame[i1] || node_has_frame[i2] || node_has_frame[i3])
            Ke_loc isa Matrix || (Ke_loc = Matrix(Ke_loc))
            node_has_frame[i1] && scale_shell_local_drilling_dof!(Ke_loc, 1, sol101_line_node_drill_sqrt_scale)
            node_has_frame[i2] && scale_shell_local_drilling_dof!(Ke_loc, 2, sol101_line_node_drill_sqrt_scale)
            node_has_frame[i3] && scale_shell_local_drilling_dof!(Ke_loc, 3, sol101_line_node_drill_sqrt_scale)
        end

        Rel_t = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]
        fill!(T_buf, 0.0)
        for k in 1:3
            idx = k == 1 ? i1 : k == 2 ? i2 : i3
            TR = Rel_t * node_R[idx]
            base = (k-1)*6
            T_buf[base+1:base+3, base+1:base+3] = TR
            T_buf[base+4:base+6, base+4:base+6] =
                (snorm_director && snorm_has[idx]) ?
                snorm_director_matrix(snorm_vec[idx], v1, v2, v3) * TR : TR
        end
        Ke = T_buf' * Ke_loc * T_buf

        for k in 1:3
            idx = k == 1 ? i1 : k == 2 ? i2 : i3
            b = (idx-1)*6
            for d in 1:6; dofs_t3[(k-1)*6+d] = b+d; end
        end
        for cc in 1:18, rr in 1:18
            push!(I_idx, dofs_t3[rr]); push!(J_idx, dofs_t3[cc]); push!(V_val, Ke[rr,cc])
        end
    end

    log_msg("[SOLVER] Shell assembly: $n_q4 QUAD4 (parallel) + $n_t3 TRIA3 (sequential), NZ=$(length(I_idx))")
    T_buf = zeros(24, 24)

    # --- CBARS ---
    for (id, bar) in cbars
        pid = string(bar["PID"])
        if !haskey(pbarls, pid); continue; end
        prop = pbarls[pid]
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)

        if norm(v_ref) < 1e-6
             v_ref = SVector(0.0,0.0,1.0)
             if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        fill!(view(T_buf, 1:12, 1:12), 0.0)
        TR1 = Rel_t * node_R[i1]
        TR2 = Rel_t * node_R[i2]
        T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
        T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            T_buf[1:3, 4:6] = -Rel_t * S_wa * node_R[i1]
            T_buf[7:9, 10:12] = -Rel_t * S_wb * node_R[i2]
        end

        Iy, Iz = _bar_bending_inertias(prop)
        Iyz = Float64(get(prop, "I12", 0.0))
        K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
        As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
        As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
        Ke_loc = _pbeam_station_condensed_stiffness(L, prop, mat["E"], mat["G"])
        if isnothing(Ke_loc)
            Ke_loc = FEM.stiffness_frame3d(L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
        end
        Ke_loc = _apply_pbeam_neutral_axis_coupling(Ke_loc, prop)
        # Apply pin flags (PA/PB) via static condensation on local stiffness
        pa = get(bar, "PA", 0); pb = get(bar, "PB", 0)
        if pa != 0 || pb != 0
            Ke_loc_m = Matrix(Ke_loc)
            apply_bar_pin_flags!(Ke_loc_m, pa, pb)
            Ke_loc = Ke_loc_m
        end
        T_sub = view(T_buf, 1:12, 1:12)
        Ke = T_sub' * Ke_loc * T_sub

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Ke[r,c])
        end
    end

    # --- CBEAMs (identical stiffness to CBAR) ---
    for (id, bar) in cbeams
        pid = string(bar["PID"])
        if !haskey(pbarls, pid); continue; end
        prop = pbarls[pid]
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)

        if norm(v_ref) < 1e-6
             v_ref = SVector(0.0,0.0,1.0)
             if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        fill!(view(T_buf, 1:12, 1:12), 0.0)
        TR1 = Rel_t * node_R[i1]
        TR2 = Rel_t * node_R[i2]
        T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
        T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            T_buf[1:3, 4:6] = -Rel_t * S_wa * node_R[i1]
            T_buf[7:9, 10:12] = -Rel_t * S_wb * node_R[i2]
        end

        Iy, Iz = _bar_bending_inertias(prop)
        Iyz = Float64(get(prop, "I12", 0.0))
        K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
        As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
        As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
        Ke_loc = _pbeam_station_condensed_stiffness(L, prop, mat["E"], mat["G"])
        if isnothing(Ke_loc)
            Ke_loc = FEM.stiffness_frame3d(L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
        end
        Ke_loc = _apply_pbeam_neutral_axis_coupling(Ke_loc, prop)
        # Apply pin flags (PA/PB) via static condensation on local stiffness
        pa = get(bar, "PA", 0); pb = get(bar, "PB", 0)
        if pa != 0 || pb != 0
            Ke_loc_m = Matrix(Ke_loc)
            apply_bar_pin_flags!(Ke_loc_m, pa, pb)
            Ke_loc = Ke_loc_m
        end
        T_sub = view(T_buf, 1:12, 1:12)
        Ke = T_sub' * Ke_loc * T_sub

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Ke[r,c])
        end
    end

    # --- CRODS ---
    prods = get(model, "PRODs", Dict())
    for (id, rod) in crods
        pid = string(rod["PID"])
        if !haskey(prods, pid); continue; end
        prop = prods[pid]
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end

        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)

        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        Ke_loc = zeros(12, 12)
        EA_L = mat["E"] * prop["A"] / L
        Ke_loc[1,1] = EA_L; Ke_loc[1,7] = -EA_L; Ke_loc[7,1] = -EA_L; Ke_loc[7,7] = EA_L
        GJ_L = mat["G"] * prop["J"] / L
        Ke_loc[4,4] = GJ_L; Ke_loc[4,10] = -GJ_L; Ke_loc[10,4] = -GJ_L; Ke_loc[10,10] = GJ_L

        fill!(view(T_buf, 1:12, 1:12), 0.0)
        TR1 = Rel_t * node_R[i1]; TR2 = Rel_t * node_R[i2]
        T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
        T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
        T_sub = view(T_buf, 1:12, 1:12)
        Ke = T_sub' * Ke_loc * T_sub

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Ke[r,c])
        end
    end

    # --- CONROD ---
    conrods = get(model, "CONRODs", Dict())
    for (id, rod) in conrods
        mid = string(rod["MID"])
        if !haskey(mats, mid); continue; end
        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])
        mat === nothing && continue
        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)
        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')
        Ke_loc = zeros(12, 12)
        EA_L = mat["E"] * rod["A"] / L
        Ke_loc[1,1] = EA_L; Ke_loc[1,7] = -EA_L; Ke_loc[7,1] = -EA_L; Ke_loc[7,7] = EA_L
        GJ_L = mat["G"] * rod["J"] / L
        Ke_loc[4,4] = GJ_L; Ke_loc[4,10] = -GJ_L; Ke_loc[10,4] = -GJ_L; Ke_loc[10,10] = GJ_L
        fill!(view(T_buf, 1:12, 1:12), 0.0)
        TR1 = Rel_t * node_R[i1]; TR2 = Rel_t * node_R[i2]
        T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
        T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
        T_sub = view(T_buf, 1:12, 1:12)
        Ke = T_sub' * Ke_loc * T_sub
        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Ke[r,c])
        end
    end

    # --- CELAS1 / CELAS2 ---
    celases = get(model, "CELASs", Dict())
    pelases = get(model, "PELASs", Dict())
    n_springs = 0
    for (id, spring) in celases
        local K_spring::Float64
        stype = get(spring, "TYPE", "CELAS1")
        if stype == "CELAS2"
            K_spring = Float64(get(spring, "K", 0.0))
        else
            pid = string(get(spring, "PID", 0))
            if !haskey(pelases, pid); continue; end
            K_spring = Float64(pelases[pid]["K"])
        end
        g1 = spring["G1"]; c1 = spring["C1"]
        g2 = spring["G2"]; c2 = spring["C2"]
        if g1 > 0 && haskey(id_map, g1) && c1 > 0
            i1 = id_map[g1]
            dof1 = (i1-1)*6 + c1
            push!(I_idx, dof1); push!(J_idx, dof1); push!(V_val, K_spring)
            if g2 > 0 && haskey(id_map, g2) && c2 > 0
                i2 = id_map[g2]
                dof2 = (i2-1)*6 + c2
                push!(I_idx, dof2); push!(J_idx, dof2); push!(V_val, K_spring)
                push!(I_idx, dof1); push!(J_idx, dof2); push!(V_val, -K_spring)
                push!(I_idx, dof2); push!(J_idx, dof1); push!(V_val, -K_spring)
            end
            n_springs += 1
        end
    end
    if n_springs > 0
        log_msg("[SOLVER] Springs: $n_springs CELAS1/CELAS2 elements assembled")
    end

    # --- CBUSH (bushing elements: 6-DOF spring between two grids) ---
    cbushes = get(model, "CBUSHs", Dict())
    pbushes = get(model, "PBUSHs", Dict())
    n_bush = 0
    for (id, bush) in cbushes
        pid = string(get(bush, "PID", 0))
        if !haskey(pbushes, pid); continue; end
        prop = pbushes[pid]
        K_vals = get(prop, "K", zeros(6))
        ga = bush["GA"]; gb = get(bush, "GB", 0)
        if !haskey(id_map, ga); continue; end
        i1 = id_map[ga]
        # CBUSH with GA only (grounded spring)
        if gb <= 0 || !haskey(id_map, gb)
            for k in 1:6
                Kk = length(K_vals) >= k ? Float64(K_vals[k]) : 0.0
                if Kk == 0.0; continue; end
                dof1 = (i1-1)*6 + k
                push!(I_idx, dof1); push!(J_idx, dof1); push!(V_val, Kk)
            end
        else
            # CBUSH connecting two grids — diagonal stiffness in each DOF
            i2 = id_map[gb]
            for k in 1:6
                Kk = length(K_vals) >= k ? Float64(K_vals[k]) : 0.0
                if Kk == 0.0; continue; end
                dof1 = (i1-1)*6 + k
                dof2 = (i2-1)*6 + k
                push!(I_idx, dof1); push!(J_idx, dof1); push!(V_val, Kk)
                push!(I_idx, dof2); push!(J_idx, dof2); push!(V_val, Kk)
                push!(I_idx, dof1); push!(J_idx, dof2); push!(V_val, -Kk)
                push!(I_idx, dof2); push!(J_idx, dof1); push!(V_val, -Kk)
            end
        end
        n_bush += 1
    end
    if n_bush > 0
        log_msg("[SOLVER] CBUSH: $n_bush bushing elements assembled")
    end

    # --- DMIG (Direct Matrix Input at Grid points) ---
    dmigs = get(model, "DMIGs", Dict{String,Dict{String,Any}}())
    n_dmig_entries = 0
    for (dmig_name, dmig_data) in dmigs
        is_sym = get(dmig_data, "type", "square") == "symmetric"
        entries = get(dmig_data, "entries", [])
        for (gi, ci, gj, cj, aij) in entries
            if !haskey(id_map, gi) || !haskey(id_map, gj); continue; end
            row_dof = (id_map[gi]-1)*6 + ci
            col_dof = (id_map[gj]-1)*6 + cj
            push!(I_idx, row_dof); push!(J_idx, col_dof); push!(V_val, aij)
            if is_sym && row_dof != col_dof
                push!(I_idx, col_dof); push!(J_idx, row_dof); push!(V_val, aij)
            end
            n_dmig_entries += 1
        end
    end
    if n_dmig_entries > 0
        log_msg("[SOLVER] DMIG: $n_dmig_entries entries from $(length(dmigs)) matrix/matrices injected")
    end

    # --- SOLID ELEMENTS (CTETRA, CHEXA, CPENTA) ---
    csolids = get(model, "CSOLIDs", Dict())
    psolids = get(model, "PSOLIDs", Dict())
    n_tetra = 0; n_hexa = 0; n_penta = 0
    T_buf_solid = zeros(24, 24)
    coords_buf = zeros(8, 3)  # max 8 nodes
    for (id, el) in csolids
        pid = string(el["PID"])
        if !haskey(psolids, pid); continue; end
        prop = psolids[pid]
        nids = el["NODES"]
        nn = length(nids)
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, nids)
        etype = get(el, "TYPE", "")

        # Validate nodes
        valid = true
        for k in 1:nn
            if !haskey(id_map, nids[k]); valid = false; break; end
        end
        if !valid; continue; end

        # Gather coordinates
        for k in 1:nn
            idx = id_map[nids[k]]
            coords_buf[k,1] = node_coords[idx, 1]
            coords_buf[k,2] = node_coords[idx, 2]
            coords_buf[k,3] = node_coords[idx, 3]
        end

        E_mat = Float64(mat["E"]); nu_mat = Float64(mat["NU"])

        local Ke_loc
        local ndof_el::Int
        if etype == "CTETRA" && nn == 4
            Ke_loc = FEM.stiffness_tetra4(view(coords_buf, 1:4, :), E_mat, nu_mat)
            ndof_el = 12; n_tetra += 1
        elseif etype == "CHEXA" && nn == 8
            Ke_loc = FEM.stiffness_hexa8(view(coords_buf, 1:8, :), E_mat, nu_mat)
            ndof_el = 24; n_hexa += 1
        elseif etype == "CPENTA" && nn == 6
            Ke_loc = FEM.stiffness_cpenta6(view(coords_buf, 1:6, :), E_mat, nu_mat)
            ndof_el = 18; n_penta += 1
        else
            continue
        end

        # Transform for displacement coordinate systems (node_R)
        # Solid stiffness is in global coords; transform to node-local: Ke_final = T' * Ke * T
        # T = block_diag(node_R[i1], node_R[i2], ...)
        fill!(view(T_buf_solid, 1:ndof_el, 1:ndof_el), 0.0)
        for k in 1:nn
            idx = id_map[nids[k]]
            r = (k-1)*3
            for a in 1:3, b in 1:3
                T_buf_solid[r+a, r+b] = node_R[idx][a, b]
            end
        end
        T_sub = view(T_buf_solid, 1:ndof_el, 1:ndof_el)
        Ke = T_sub' * Ke_loc * T_sub

        # Build DOF mapping: solid elements use only translational DOFs (1,2,3)
        dofs_solid = Vector{Int}(undef, ndof_el)
        for k in 1:nn
            idx = id_map[nids[k]]
            base = (idx-1)*6
            dofs_solid[(k-1)*3+1] = base + 1
            dofs_solid[(k-1)*3+2] = base + 2
            dofs_solid[(k-1)*3+3] = base + 3
        end

        for c in 1:ndof_el, r in 1:ndof_el
            push!(I_idx, dofs_solid[r]); push!(J_idx, dofs_solid[c]); push!(V_val, Ke[r,c])
        end
    end
    n_solids_total = n_tetra + n_hexa + n_penta
    if n_solids_total > 0
        log_msg("[SOLVER] Solids: $n_tetra CTETRA + $n_hexa CHEXA + $n_penta CPENTA assembled")
    end

    # Save max element stiffness BEFORE constraint processing
    max_elem_stiff = 0.0
    for i in 1:length(V_val)
        if abs(V_val[i]) > max_elem_stiff; max_elem_stiff = abs(V_val[i]); end
    end

    # Compute original diagonal BEFORE MPC redistribution (for AUTOSPC)
    orig_diag = zeros(ndof)
    for k in 1:length(I_idx)
        if I_idx[k] == J_idx[k]
            orig_diag[I_idx[k]] += V_val[k]
        end
    end

    # --- Constraint assembly (RBE2, RBE3, MPC) ---
    rbe3_map, I_idx, J_idx, V_val = assemble_constraints(model, id_map, node_coords, node_R, I_idx, J_idx, V_val)

    actual_nz = length(I_idx)
    log_msg("[SOLVER] Creating Sparse Matrix (NZ: $actual_nz)...")
    K = sparse(I_idx, J_idx, V_val, ndof, ndof)
    # Triplet arrays are dropped for natural collection; the former forced
    # full GC.gc() here cost a measured ~0.6 s per assembly (full-heap mark
    # while the live set is at its largest) and multiplied across
    # reassemblies (temperature subcases, load-aware passes, dKdx, SOL106).
    I_idx = nothing; J_idx = nothing; V_val = nothing

    FEM.env_snapshot_end!()
    return K, id_map, node_coords, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag
end

# =============================================================================
# GEOMETRIC STIFFNESS ASSEMBLY FOR SOL105 LINEAR BUCKLING
# Mirrors assemble_stiffness but builds Kg from SOL101 stress state.
# u_global = displacement solution from SOL101 (in local coord-system DOFs).
# =============================================================================
# Values-only CSC reassembly (perf program deferred item, env-flagged):
# across the buckling subcases of a deck the Kg triplet PATTERN (the I,J
# sequences) is identical — only V changes. On a pattern-cache hit, refill a
# FRESH nzval through a precomputed triplet→nzval slot map instead of
# re-running sparse()'s full sort/merge. Bit-safety: sparse()'s stable
# counting sorts combine duplicates in original triplet order per entry
# (first value assigned, later ones added left-to-right); the slot-map loop
# reproduces exactly that assignment/addition sequence, so nzval is
# bit-identical (gated by suite/battery hashes; -0.0 first-touch handled by
# assignment, not 0.0 + x). colptr/rowval are shared READ-ONLY across
# subcases; nzval is freshly allocated so earlier Kg matrices never mutate.
function _sparse_from_triplets_cached(I_idx, J_idx, V_val, ndof::Int, csc_cache)
    # Default ON 2026-08-06: gate showed the refill is bit-identical
    # (anchor-deck JSON hash equal with the subcase-2 refill active;
    # both-ON suite exactly equal; battery eigen metrics exactly 0).
    use_cache = csc_cache !== nothing &&
                solver_env_bool("JFEM_KG_VALUES_ONLY_CSC", true)
    use_cache || return sparse(I_idx, J_idx, V_val, ndof, ndof)
    key = (length(I_idx), hash(I_idx), hash(J_idx), ndof)
    hit = get(csc_cache, key, nothing)
    if hit === nothing
        Kg = sparse(I_idx, J_idx, V_val, ndof, ndof)
        cp = Kg.colptr
        rv = Kg.rowval
        slots = Vector{Int}(undef, length(I_idx))
        @inbounds for k in eachindex(I_idx)
            j = J_idx[k]
            lo = cp[j]
            hi = cp[j + 1] - 1
            slots[k] = searchsortedfirst(view(rv, lo:hi), I_idx[k]) + lo - 1
        end
        csc_cache[key] = (copy(cp), copy(rv), slots)
        return Kg
    end
    cp, rv, slots = hit
    nz = Vector{Float64}(undef, length(rv))
    filled = falses(length(rv))
    @inbounds for k in eachindex(V_val)
        s = slots[k]
        if filled[s]
            nz[s] += V_val[k]
        else
            nz[s] = V_val[k]
            filled[s] = true
        end
    end
    return SparseMatrixCSC(ndof, ndof, cp, rv, nz)
end

function assemble_geometric_stiffness(model, id_map, node_coords, node_R, ndof, u_global, snorm_normals, rbe3_map;
                                      snorm_angle_override::Union{Nothing,Float64}=nothing,
                                      buckling_subcase=nothing,
                                      static_load_id=nothing,
                                      timings=nothing,
                                      csc_cache=nothing)
    kg_t_total = time_ns()
    kg_timings = Dict{String,Any}()
    kg_t_setup = time_ns()
    FEM.env_snapshot_begin!()
    log_msg("[SOLVER] Assembling Geometric Stiffness Matrix (SOL105)...")
    # JFEM_DUMP_USTATIC: when set to a writable path, dump the SOL101 static
    # displacement solution (u_global, GLOBAL coords per node) as "gid ux uy uz"
    # so it can be compared against a Nastran DISPLACEMENT punch. Debug hook only.
    let ust_path = strip(get(ENV, "JFEM_DUMP_USTATIC", ""))
        if !isempty(ust_path)
            try
                open(ust_path, "w") do io
                    for (gid, idx) in sort(collect(id_map); by = x -> x[2])
                        b = (idx - 1) * 6
                        # u_global is in local (node_R) DOFs; rotate back to global
                        R = node_R[idx]
                        ul = (u_global[b+1], u_global[b+2], u_global[b+3])
                        rl = (u_global[b+4], u_global[b+5], u_global[b+6])
                        ux = R[1,1]*ul[1] + R[2,1]*ul[2] + R[3,1]*ul[3]
                        uy = R[1,2]*ul[1] + R[2,2]*ul[2] + R[3,2]*ul[3]
                        uz = R[1,3]*ul[1] + R[2,3]*ul[2] + R[3,3]*ul[3]
                        rx = R[1,1]*rl[1] + R[2,1]*rl[2] + R[3,1]*rl[3]
                        ry = R[1,2]*rl[1] + R[2,2]*rl[2] + R[3,2]*rl[3]
                        rz = R[1,3]*rl[1] + R[2,3]*rl[2] + R[3,3]*rl[3]
                        println(io, gid, " ", repr(ux), " ", repr(uy), " ", repr(uz),
                                " ", repr(rx), " ", repr(ry), " ", repr(rz))
                    end
                end
                log_msg("[SOLVER] Dumped u_static to $ust_path")
            catch err
                log_msg("[SOLVER] WARNING: JFEM_DUMP_USTATIC failed: $err")
            end
        end
    end

    snorm_override = isnothing(snorm_angle_override) ?
        get(ENV, "JFEM_PARAM_SNORM_OVERRIDE_KG", get(ENV, "JFEM_PARAM_SNORM_OVERRIDE", "")) :
        string(snorm_angle_override)
    if !isempty(strip(snorm_override))
        model = copy(model)
        model["PARAM_SNORM"] = something(tryparse(Float64, snorm_override), get(model, "PARAM_SNORM", 0.0))
    end
    q4_frame_mode = q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_KG")
    kg_compatible_membrane = kg_use_compatible_membrane_stress()
    kg_match_static_membrane_operator = kg_match_static_membrane_operator_enabled()
    membrane_incomp =
        if haskey(ENV, "JFEM_KG_MEMBRANE_INCOMP")
            solver_env_bool("JFEM_KG_MEMBRANE_INCOMP", sol105_static_membrane_incomp_enabled())
        elseif kg_match_static_membrane_operator
            sol105_static_membrane_incomp_enabled()
        else
            solver_env_bool("JFEM_SOL105_EIG_MEMBRANE_INCOMP", false)
        end
    pcomp_membrane_incomp = solver_env_bool("JFEM_SOL105_EIG_PCOMP_MEMBRANE_INCOMP", false)
    # Diagnostic override: recover Kg prestress with PCOMP incompatible modes
    # without changing the static/eigen stiffness assembly path.
    kg_pcomp_membrane_incomp =
        solver_env_bool("JFEM_KG_PCOMP_MEMBRANE_INCOMP", pcomp_membrane_incomp)
    kg_consistent_membrane_operator = kg_quad4_consistent_membrane_operator_enabled()
    kg_pcomp_consistent_membrane_operator =
        solver_env_bool("JFEM_KG_PCOMP_CONSISTENT_MEMBRANE_INCOMP_OPERATOR",
                        kg_consistent_membrane_operator)
    kg_trans_mode = kg_shell_trans_mode()
    kg_principal_transverse_flat_only = kg_shell_principal_transverse_flat_only_enabled()
    kg_principal_transverse_warp_ratio_max = kg_shell_principal_transverse_warp_ratio_max()
    kg_iso_nastran_kdjj_mode_v = kg_quad4_iso_nastran_kdjj_mode()
    kg_iso_nastran_kdjj_skew_min_deg_v = kg_quad4_iso_nastran_kdjj_skew_min_deg()
    kg_principal_shear_yy_factor_v = kg_shell_principal_shear_yy_factor()
    kg_principal_shear_xy_factor_v = kg_shell_principal_shear_xy_factor()
    kg_principal_shear_z_factor_v = kg_shell_principal_shear_z_factor()
    kg_principal_shear_ratio_min_v = kg_shell_principal_shear_ratio_min()
    kg_principal_shear_warp_min_v = kg_shell_principal_shear_warp_min()
    kg_principal_shear_warp_max_v = kg_shell_principal_shear_warp_max()
    kg_principal_shear_aspect_min_v = kg_shell_principal_shear_aspect_min()
    kg_principal_shear_aspect_max_v = kg_shell_principal_shear_aspect_max()
    kg_principal_shear_geom_mode_v = kg_shell_principal_shear_geometry_mode()
    kg_principal_shear_feature_gate_v = kg_shell_principal_shear_feature_gate()
    kg_principal_shear_gp_pmin_spread_min_v = kg_shell_principal_shear_gp_pmin_spread_min()
    kg_principal_shear_gp_nxx_spread_min_v = kg_shell_principal_shear_gp_nxx_spread_min()
    kg_principal_shear_gp_spread_factor_v = kg_shell_principal_shear_gp_spread_factor()
    kg_curvature_sign = kg_shell_curvature_sign()
    sol105_pshell_iso_warped_kg_enabled =
        sol105_geom_pshell_iso_warped_kg_scale_enabled()
    sol105_pshell_iso_warped_kg_scale =
        sol105_geom_pshell_iso_warped_kg_scale_value()
    sol105_pshell_iso_warped_kg_warp_min =
        sol105_geom_pshell_iso_warped_kg_warp_min()
    sol105_pshell_iso_warped_kg_warp_max =
        sol105_geom_pshell_iso_warped_kg_warp_max()
    sol105_pshell_iso_warped_kg_aspect_min =
        sol105_geom_pshell_iso_warped_kg_aspect_min()
    sol105_pshell_iso_warped_kg_aspect_max =
        sol105_geom_pshell_iso_warped_kg_aspect_max()
    sol105_pshell_iso_warped_kg_h_over_lmax_min =
        sol105_geom_pshell_iso_warped_kg_h_over_lmax_min()
    sol105_pshell_iso_warped_kg_h_over_lmax_max =
        sol105_geom_pshell_iso_warped_kg_h_over_lmax_max()
    sol105_pshell_iso_skew_kg_enabled =
        sol105_geom_pshell_iso_skew_kg_scale_enabled()
    sol105_pshell_iso_skew_kg_scale =
        sol105_geom_pshell_iso_skew_kg_scale_value()
    sol105_pshell_iso_skew_kg_skew_min =
        sol105_geom_pshell_iso_skew_kg_skew_min()
    sol105_pshell_iso_skew_kg_skew_max =
        sol105_geom_pshell_iso_skew_kg_skew_max()
    sol105_pshell_iso_skew_kg_warp_max =
        sol105_geom_pshell_iso_skew_kg_warp_max()
    sol105_pshell_iso_skew_kg_aspect_min =
        sol105_geom_pshell_iso_skew_kg_aspect_min()
    sol105_pshell_iso_skew_kg_aspect_max =
        sol105_geom_pshell_iso_skew_kg_aspect_max()
    sol105_pshell_iso_skew_kg_h_over_lmax_min =
        sol105_geom_pshell_iso_skew_kg_h_over_lmax_min()
    sol105_pshell_iso_skew_kg_h_over_lmax_max =
        sol105_geom_pshell_iso_skew_kg_h_over_lmax_max()
    kg_quad4_gp_field_pmin_spread_avg_min_v = kg_quad4_gp_field_pmin_spread_avg_min()
    kg_quad4_gp_field_pmin_spread_avg_alpha_v = kg_quad4_gp_field_pmin_spread_avg_alpha()
    kg_shell_pcomp_nxy = kg_shell_pcomp_nxy_scale()
    kg_shell_pcomp_nxy_aspect = kg_shell_pcomp_nxy_aspect_scale_enabled()
    kg_shell_pcomp_nxy_aspect_mode_v = kg_shell_pcomp_nxy_aspect_mode()
    kg_shell_pcomp_nxy_aspect_low_v = kg_shell_pcomp_nxy_aspect_low()
    kg_shell_pcomp_nxy_aspect_mid_v = kg_shell_pcomp_nxy_aspect_mid()
    kg_shell_pcomp_nxy_aspect_high_v = kg_shell_pcomp_nxy_aspect_high()
    kg_shell_pcomp_nxy_aspect_min_v = kg_shell_pcomp_nxy_aspect_min()
    kg_shell_pcomp_nxy_aspect_peak_v = kg_shell_pcomp_nxy_aspect_peak()
    kg_shell_pcomp_nxy_aspect_max_v = kg_shell_pcomp_nxy_aspect_max()
    kg_shell_pcomp_nxy_compression_only_v = kg_shell_pcomp_nxy_compression_only()
    kg_shell_pcomp_nxy_shear_dom_relax_v = kg_shell_pcomp_nxy_shear_dom_relax()
    kg_shell_pcomp_nxy_shear_dom_ratio_min_v = kg_shell_pcomp_nxy_shear_dom_ratio_min()
    kg_shell_pcomp_nxy_shear_dom_ratio_full_v = kg_shell_pcomp_nxy_shear_dom_ratio_full()
    kg_shell_pcomp_nxy_shear_dom_aspect_min_v = kg_shell_pcomp_nxy_shear_dom_aspect_min()
    kg_shell_pcomp_nxy_shear_dom_aspect_max_v = kg_shell_pcomp_nxy_shear_dom_aspect_max()
    kg_shell_pcomp_nxy_shear_dom_compression_only_v = kg_shell_pcomp_nxy_shear_dom_compression_only()
    q4_kernel_mode_kg = lowercase(strip(get(ENV, "JFEM_Q4_KERNEL_KG", get(ENV, "JFEM_Q4_KERNEL", "macneal"))))
    mitc4_3d_kg_all_kernel = q4_kernel_mode_kg in ("mitc4_3d", "mitc4-3d", "mitc3d")
    mitc4_3d_kg_aspect_kernel = q4_kernel_mode_kg in (
        "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect",
    )
    mitc4_3d_kg_all_consistent =
        mitc4_3d_kg_all_kernel && solver_env_bool("JFEM_Q4_MITC4_3D_KG_COVARIANT", true)
    mitc4_3d_kg_aspect_consistent =
        mitc4_3d_kg_aspect_kernel &&
        solver_env_bool(
            "JFEM_Q4_MITC4_3D_ASPECT_KG_COVARIANT",
            solver_env_bool("JFEM_Q4_MITC4_3D_KG_COVARIANT", true),
        )
    mitc4_3d_kg_recovery_all =
        mitc4_3d_kg_all_consistent && solver_env_bool("JFEM_Q4_MITC4_3D_KG_RECOVERY", false)
    mitc4_3d_kg_recovery_aspect =
        mitc4_3d_kg_aspect_consistent &&
        solver_env_bool(
            "JFEM_Q4_MITC4_3D_ASPECT_KG_RECOVERY",
            solver_env_bool("JFEM_Q4_MITC4_3D_KG_RECOVERY", false),
        )
    mitc4_3d_kg_recovery = mitc4_3d_kg_recovery_all || mitc4_3d_kg_recovery_aspect
    mitc4_3d_aspect_min_base_kg = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_MIN", 3.0), 1.0)
    mitc4_3d_aspect_max_base_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_MAX", 1e30), mitc4_3d_aspect_min_base_kg)
    mitc4_3d_aspect_warp_min_base_kg = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_WARP_MIN", 0.0), 0.0)
    mitc4_3d_aspect_warp_max_base_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_WARP_MAX", 1e30), mitc4_3d_aspect_warp_min_base_kg)
    mitc4_3d_aspect_kappa_l_min_base_kg = max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KAPPA_L_MIN", 0.0), 0.0)
    mitc4_3d_aspect_kappa_l_max_base_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KAPPA_L_MAX", 1e30), mitc4_3d_aspect_kappa_l_min_base_kg)
    mitc4_3d_aspect_skew_min_base_kg = q4_mitc4_3d_aspect_skew_min()
    mitc4_3d_aspect_skew_max_base_kg =
        max(q4_mitc4_3d_aspect_skew_max(), mitc4_3d_aspect_skew_min_base_kg)
    mitc4_3d_aspect_skew_aspect_min_base_kg = q4_mitc4_3d_aspect_skew_aspect_min()
    mitc4_3d_aspect_pcomp_only_base_kg = solver_env_bool("JFEM_Q4_MITC4_3D_ASPECT_PCOMP_ONLY", true)
    mitc4_3d_aspect_min_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_ASPECT_MIN", mitc4_3d_aspect_min_base_kg), 1.0)
    mitc4_3d_aspect_max_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_ASPECT_MAX", mitc4_3d_aspect_max_base_kg), mitc4_3d_aspect_min_kg)
    mitc4_3d_aspect_warp_min_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_WARP_MIN", mitc4_3d_aspect_warp_min_base_kg), 0.0)
    mitc4_3d_aspect_warp_max_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_WARP_MAX", mitc4_3d_aspect_warp_max_base_kg), mitc4_3d_aspect_warp_min_kg)
    mitc4_3d_aspect_kappa_l_min_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_KAPPA_L_MIN", mitc4_3d_aspect_kappa_l_min_base_kg), 0.0)
    mitc4_3d_aspect_kappa_l_max_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_KAPPA_L_MAX", mitc4_3d_aspect_kappa_l_max_base_kg), mitc4_3d_aspect_kappa_l_min_kg)
    mitc4_3d_aspect_skew_min_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_SKEW_MIN", mitc4_3d_aspect_skew_min_base_kg), 0.0)
    mitc4_3d_aspect_skew_max_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_SKEW_MAX", mitc4_3d_aspect_skew_max_base_kg), mitc4_3d_aspect_skew_min_kg)
    mitc4_3d_aspect_skew_aspect_min_kg =
        max(solver_env_float("JFEM_Q4_MITC4_3D_ASPECT_KG_SKEW_ASPECT_MIN", mitc4_3d_aspect_skew_aspect_min_base_kg), 0.0)
    mitc4_3d_aspect_pcomp_only_kg =
        solver_env_bool("JFEM_Q4_MITC4_3D_ASPECT_KG_PCOMP_ONLY", mitc4_3d_aspect_pcomp_only_base_kg)
    kg_surface_operator_mode = kg_shell_surface_operator_mode()
    if mitc4_3d_kg_all_consistent && !haskey(ENV, "JFEM_KG_SHELL_SURFACE_OPERATOR")
        kg_surface_operator_mode = :covariant
    end
    kg_shell_nxy_auto = kg_shell_nxy_auto_relax()
    kg_shell_drill_zero = kg_shell_drill_zero_enabled()
    kg_shell_nxy_auto_ratio_min_v = kg_shell_nxy_auto_ratio_min()
    kg_shell_nxy_auto_ratio_full_v = kg_shell_nxy_auto_ratio_full()
    kg_shell_nxy_auto_cyl_ratio_max_v = kg_shell_nxy_auto_cyl_ratio_max()
    kg_shell_nxy_auto_kappa_l_min_v = kg_shell_nxy_auto_kappa_l_min()
    kg_membrane_recovery_mode = kg_quad4_membrane_recovery_mode()
    kg_covariant_blend = kg_quad4_covariant_blend()
    kg_covariant_auto_kappa_l_min = kg_quad4_covariant_auto_kappa_l_min()
    kg_covariant_auto_cyl_ratio_max = kg_quad4_covariant_auto_cyl_ratio_max()
    kg_shear_avg_operator = kg_quad4_shear_average_operator_enabled()
    kg_shear_avg_ratio_min = kg_quad4_shear_average_ratio_min()
    kg_shear_avg_warp_min = kg_quad4_shear_average_warp_min()
    kg_shear_avg_warp_max = kg_quad4_shear_average_warp_max()
    kg_shear_avg_aspect_min = kg_quad4_shear_average_aspect_min()
    kg_shear_avg_aspect_max = kg_quad4_shear_average_aspect_max()
    kg_shear_avg_geom_mode = kg_quad4_shear_average_geometry_mode()
    kg_auto_gp_spread = kg_quad4_auto_gp_spread_enabled()
    kg_auto_gp_spread_min = kg_quad4_auto_gp_spread_min()
    kg_auto_gp_spread_kappa_l_min = kg_quad4_auto_gp_spread_kappa_l_min()
    kg_auto_gp_spread_cyl_ratio_min = kg_quad4_auto_gp_spread_cyl_ratio_min()
    kg_gp_extrapolate_scale = kg_quad4_gp_field_extrapolate_scale()
    membrane_incomp_center_jacobian = q4_sol105_membrane_incomp_center_jacobian_enabled()
    flat_iso_eig_membrane_incomp = q4_flat_iso_eig_membrane_incomp_enabled()
    flat_iso_eig_membrane_shear_center_row = q4_flat_iso_eig_membrane_shear_center_row_enabled()
    flat_iso_dkmq_branch = q4_sol105_flat_iso_dkmq_enabled()
    flat_curved_iso_eig_center_only = q4_flat_curved_iso_eig_center_only_enabled()
    flat_curved_iso_eig_center_only_kappa_l_min = q4_flat_curved_iso_eig_center_only_kappa_l_min()
    flat_curved_iso_eig_center_only_cyl_ratio_max = q4_flat_curved_iso_eig_center_only_cyl_ratio_max()
    flat_curved_iso_geomnormal_frame = q4_flat_curved_iso_geomnormal_frame_enabled()
    flat_curved_iso_geomnormal_frame_aspect_ratio_min = q4_flat_curved_iso_geomnormal_frame_aspect_ratio_min()
    flat_curved_iso_geomnormal_frame_kappa_l_min = q4_flat_curved_iso_geomnormal_frame_kappa_l_min()
    flat_curved_iso_geomnormal_frame_kappa_l_max = q4_flat_curved_iso_geomnormal_frame_kappa_l_max()
    flat_curved_iso_geomnormal_frame_cyl_ratio_max = q4_flat_curved_iso_geomnormal_frame_cyl_ratio_max()
    flat_curved_iso_nodal_geomnormal_transform = q4_flat_curved_iso_nodal_geomnormal_transform_enabled()
    flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min = q4_flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min()
    flat_curved_iso_nodal_geomnormal_transform_valence_sum_max = q4_flat_curved_iso_nodal_geomnormal_transform_valence_sum_max()
    kg_pcomp_axis_mode = q4_pcomp_kg_axis_mode()
    kg_pcomp_axis_mode_override = haskey(ENV, "JFEM_Q4_PCOMP_KG_AXIS_MODE")
    flat_pcomp_plate_branch = q4_sol105_flat_pcomp_plate_branch_enabled()
    flat_pcomp_dkmq_branch = q4_sol105_flat_pcomp_dkmq_enabled()
    flat_pcomp_plate_auto = q4_sol105_flat_pcomp_plate_auto_enabled()
    flat_pcomp_plate_auto_d16_ratio_max = q4_sol105_flat_pcomp_plate_auto_d16_ratio_max()
    flat_pcomp_plate_auto_shear_ratio_max = q4_sol105_flat_pcomp_plate_auto_shear_ratio_max()
    flat_pcomp_plate_like_kg = q4_sol105_flat_pcomp_plate_like_kg_enabled()
    nonflat_pcomp_normal_only_kg = q4_sol105_nonflat_pcomp_normal_only_kg_enabled()
    flat_pcomp_rect_adini = q4_sol105_flat_pcomp_rect_adini_enabled()
    curved_iso_eig_membrane_incomp = q4_curved_iso_eig_auto_membrane_incomp_enabled()
    curved_iso_eig_membrane_incomp_kappa_l_min = q4_curved_iso_eig_auto_membrane_incomp_kappa_l_min()
    curved_iso_eig_membrane_incomp_cyl_ratio_max = q4_curved_iso_eig_auto_membrane_incomp_cyl_ratio_max()
    curved_iso_warp_membrane_incomp = q4_curved_iso_warp_membrane_incomp_enabled()
    curved_iso_warp_membrane_incomp_ratio_min = q4_curved_iso_warp_membrane_incomp_ratio_min()
    curved_iso_warp_membrane_incomp_kappa_l_max = q4_curved_iso_warp_membrane_incomp_kappa_l_max()
    curved_iso_elongated_membrane_incomp = q4_curved_iso_elongated_membrane_incomp_enabled()
    curved_iso_geomnormal_frame = q4_curved_iso_geomnormal_frame_enabled()
    curved_iso_geomnormal_frame_aspect_ratio_min = q4_curved_iso_geomnormal_frame_aspect_ratio_min()
    curved_iso_geomnormal_frame_kappa_l_min = q4_curved_iso_geomnormal_frame_kappa_l_min()
    curved_iso_geomnormal_frame_kappa_l_max = q4_curved_iso_geomnormal_frame_kappa_l_max()
    curved_iso_geomnormal_frame_cyl_ratio_max = q4_curved_iso_geomnormal_frame_cyl_ratio_max()
    # DIAGNOSTIC (default OFF): mirror of the K-assembly SNORM element-tilt gate (must stay K/Kg-consistent).
    snorm_tilt_gate_cos = let g = solver_env_float("JFEM_SNORM_ELEM_TILT_GATE", 0.0); g > 0.0 ? cosd(g) : -2.0 end
    # SNORM-TRANSFORM-ONLY (default OFF): mirror of the K-assembly flag (must stay K/Kg-consistent).
    snorm_transform_only = solver_env_bool("JFEM_Q4_SNORM_TRANSFORM_ONLY", false)
    # SNORM-DIRECTOR (default OFF): mirror of the K-assembly flag. K and Kg MUST agree on the rotational
    # referencing -- leaving Kg on the element normal while K uses the grid normal puts the two operators
    # in different frames and manufactures a spurious near-zero buckling mode.
    snorm_director = snorm_director_enabled()
    snorm_curvature = snorm_curvature_enabled()
    curved_iso_elongated_membrane_incomp_aspect_ratio_min = q4_curved_iso_elongated_membrane_incomp_aspect_ratio_min()
    kg_flat_pcomp_auto_g12 = !kg_pcomp_axis_mode_override && q4_flat_pcomp_auto_g12_enabled()
    kg_flat_pcomp_auto_g12_kappa_l_max = q4_flat_pcomp_auto_g12_kappa_l_max()
    kg_flat_pcomp_auto_g12_cyl_ratio_max = q4_flat_pcomp_auto_g12_cyl_ratio_max()
    kg_flat_pcomp_auto_g12_shear_ratio_max = q4_pcomp_auto_global_x_shear_ratio_max()
    kg_flat_pcomp_auto_g12_d16_ratio_max = q4_pcomp_auto_global_x_d16_ratio_max()
    kg_flat_pcomp_auto_g12_b_ratio_max = q4_pcomp_auto_global_x_b_ratio_max()
    kg_pcomp_auto_global_x = !kg_pcomp_axis_mode_override && q4_pcomp_auto_global_x_enabled()
    kg_pcomp_auto_global_x_shear_ratio_max = q4_pcomp_auto_global_x_shear_ratio_max()
    kg_pcomp_auto_global_x_d16_ratio_max = q4_pcomp_auto_global_x_d16_ratio_max()
    kg_pcomp_auto_global_x_b_ratio_max = q4_pcomp_auto_global_x_b_ratio_max()
    kg_pcomp_auto_global_x_cyl_ratio_min = q4_pcomp_auto_global_x_cyl_ratio_min()
    kg_pcomp_auto_global_x_kappa_l_min = q4_pcomp_auto_global_x_kappa_l_min()
    kg_pcomp_auto_g12 = !kg_pcomp_axis_mode_override && q4_pcomp_kg_auto_g12_enabled()
    kg_auto_curvature_pcomp = kg_trans_mode !== :curvature && q4_pcomp_kg_auto_curvature_enabled()
    kg_auto_curvature_iso = kg_trans_mode !== :curvature && q4_shell_kg_auto_curvature_iso_enabled()

    cshells = model["CSHELLs"]
    cbars   = model["CBARs"]
    cbeams  = get(model, "CBEAMs", Dict())
    crods   = get(model, "CRODs", Dict())
    conrods = get(model, "CONRODs", Dict())
    model_has_line_elements = !isempty(cbars) || !isempty(cbeams) || !isempty(crods) || !isempty(conrods)
    pshells = model["PSHELLs"]; pbarls = model["PBARLs"]; mats = model["MATs"]
    auto_pcomp_membrane_incomp_model = any(q4_sol105_pcomp_auto_membrane_incomp_candidate, values(pshells))

    n_nodes = length(id_map)
    max_nid = maximum(keys(id_map))
    id_vec = zeros(Int, max_nid)
    for (nid, idx) in id_map; id_vec[nid] = idx; end

    snorm_vec = fill(SVector(0.0, 0.0, 0.0), n_nodes)
    snorm_has = falses(n_nodes)
    snorm_normals_local = isempty(strip(snorm_override)) ? snorm_normals : compute_snorm_normals(model, id_map, node_coords)
    for (idx, nrm) in snorm_normals_local; snorm_vec[idx] = nrm; snorm_has[idx] = true; end
    # 2026-07-27 de-calibration: the GEOM_PCOMP_KG scale family is gone, but its
    # master enable (JFEM_SOL105_GEOM_PCOMP_KG_SCALE) defaulted to TRUE, so this
    # predicate was unconditionally true in every shipped run. Folding it to the
    # default keeps the geometric nodal normals firing for exactly the same
    # element set -- dropping the disjunct instead would have silently switched
    # them OFF, which is NOT neutral.
    geom_normals_local = compute_geometric_nodal_normals(model, id_map, node_coords)
    geom_vec = fill(SVector(0.0, 0.0, 0.0), n_nodes)
    geom_has = falses(n_nodes)
    for (idx, nrm) in geom_normals_local; geom_vec[idx] = nrm; geom_has[idx] = true; end
    node_has_line = build_node_has_line_elements(model, id_map, n_nodes)

    # Convert node_R to flat 3D array
    node_R_flat = zeros(3, 3, n_nodes)
    for i in 1:n_nodes
        for r in 1:3, c in 1:3; node_R_flat[r,c,i] = node_R[i][r,c]; end
    end
    shell_valence = zeros(Int, n_nodes)
    for (_, el) in cshells
        for nid in el["NODES"]
            idx = get(id_map, nid, 0)
            idx > 0 && (shell_valence[idx] += 1)
        end
    end
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()

    # --- QUAD4 geometric stiffness ---
    shell_keys = collect(keys(cshells))
    shell_list = [cshells[k] for k in shell_keys]
    shell_eids = [something(tryparse(Int, string(k)), 0) for k in shell_keys]
    n_shells = length(shell_list)
    # Count and pre-extract QUAD4/TRIA3 elements (same logic as assemble_stiffness)
    n_q4 = 0; n_t3 = 0
    for el in shell_list
        pid = string(el["PID"])
        if !haskey(pshells, pid); continue; end
        prop = pshells[pid]; mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        nids = el["NODES"]; n = length(nids)
        valid = true
        for k in 1:n
            nid = nids[k]
            if nid < 1 || nid > max_nid || id_vec[nid] == 0; valid = false; break; end
        end
        if !valid; continue; end
        if n == 4; n_q4 += 1; elseif n == 3; n_t3 += 1; end
    end

    est_total = n_q4*576 + n_t3*324 + length(cbars)*144 + length(cbeams)*144 + length(crods)*144 + length(conrods)*144
    sizehint!(I_idx, est_total); sizehint!(J_idx, est_total); sizehint!(V_val, est_total)

    # --- Parallel shell Kg assembly ---
    # Per-thread scratch: each Julia thread that may run an iteration gets
    # its own bank of 24×24 / 4×3 / 4×2 buffers so they don't collide.
    # Sized by maxthreadid() (safe upper bound for threadid()); on a 1-thread
    # run each vector has length 1 and the loop executes sequentially with no
    # synchronization overhead.
    nt_kg = Threads.maxthreadid()
    T_buf_tl         = [zeros(24, 24)           for _ in 1:nt_kg]
    lc_buf4_tl       = [zeros(4, 2)             for _ in 1:nt_kg]
    dofs_buf24_tl    = [Vector{Int}(undef, 24)  for _ in 1:nt_kg]
    u_elem24_tl      = [zeros(24)               for _ in 1:nt_kg]
    Kg_global_tl     = [zeros(24, 24)           for _ in 1:nt_kg]
    tmp24a_tl        = [zeros(24, 24)           for _ in 1:nt_kg]
    N_gp_eff_tl      = [zeros(4, 3)             for _ in 1:nt_kg]
    coords3d_buf4_tl = [zeros(4, 3)             for _ in 1:nt_kg]
    coords3d_local_buf4_tl = [zeros(4, 3)       for _ in 1:nt_kg]
    directors3d_local_buf4_tl = [zeros(4, 3)    for _ in 1:nt_kg]

    # Positional-slot COO triplet buffers: element ei owns the fixed slot
    # range (ei-1)*576+1 .. ei*576 (576 = the 24x24 quad maximum; triangles
    # use 324 of it, skipped elements 0, recorded in kg_slot_n). Threads
    # write only their own elements' slots, and the post-loop compaction
    # walks ELEMENT order — so the master triplet stream is identical for
    # every thread count (and bit-identical to the former single-thread
    # concat order). This replaces per-thread push! accumulators whose
    # concat order depended on the schedule (the documented Kg threading
    # nondeterminism; PERF program Phase 1).
    kg_slot_I = Vector{Int}(undef, length(shell_list) * 576)
    kg_slot_J = Vector{Int}(undef, length(shell_list) * 576)
    kg_slot_V = Vector{Float64}(undef, length(shell_list) * 576)
    kg_slot_n = zeros(Int, length(shell_list))

    # Per-thread scalar reductions (summed after the loop).
    diag_Nxx_sum_tl = zeros(nt_kg)
    diag_Nyy_sum_tl = zeros(nt_kg)
    diag_Nxy_sum_tl = zeros(nt_kg)
    diag_count_tl   = zeros(Int, nt_kg)
    n_q4_done_tl    = zeros(Int, nt_kg)
    kg_diag_pid_enabled = solver_env_bool("JFEM_KG_DIAG_PID", false)
    # JFEM_KG_DIAG_EID_CSV: when set to a writable path, the Kg loop dumps
    # per-element membrane forces (Nxx, Nyy, Nxy) to a CSV after Kg assembly.
    # Used to compare σ-recovery across kernel modes for the same external
    # load (see 2026-05-12 entry in SOL105 parity TODO).
    kg_diag_eid_csv_path = strip(get(ENV, "JFEM_KG_DIAG_EID_CSV", ""))
    kg_diag_eid_enabled = !isempty(kg_diag_eid_csv_path)
    kg_diag_subcase = buckling_subcase === nothing ? "" : string(buckling_subcase)
    kg_eid_rows_tl = [NamedTuple[] for _ in 1:nt_kg]
    kg_pid_count_tl = [Dict{Int,Int}() for _ in 1:nt_kg]
    kg_pid_nxx_tl = [Dict{Int,Float64}() for _ in 1:nt_kg]
    kg_pid_nyy_tl = [Dict{Int,Float64}() for _ in 1:nt_kg]
    kg_pid_nxy_tl = [Dict{Int,Float64}() for _ in 1:nt_kg]

    # The per-element kernel only does small (≤24×24) matmuls where BLAS
    # threading is pure overhead. Pin to 1 BLAS thread while the @threads
    # loop is active, then restore so Cholesky/Krylov downstream can still
    # use all cores.
    kg_timings["setup"] = (time_ns() - kg_t_setup) * 1e-9
    kg_t_shells = time_ns()
    _prev_blas_threads_kg = LinearAlgebra.BLAS.get_num_threads()
    LinearAlgebra.BLAS.set_num_threads(1)

    log_msg("[SOLVER] Assembling Kg shells ($(Threads.nthreads()) Julia thread$(Threads.nthreads()==1 ? "" : "s"))")

    Threads.@threads :static for _shell_ei in 1:length(shell_list)
        tid = Threads.threadid()
        el = shell_list[_shell_ei]
        let T_buf         = T_buf_tl[tid],
            lc_buf4       = lc_buf4_tl[tid],
            dofs_buf24    = dofs_buf24_tl[tid],
            u_elem24      = u_elem24_tl[tid],
            Kg_global     = Kg_global_tl[tid],
            tmp24a        = tmp24a_tl[tid],
            N_gp_eff      = N_gp_eff_tl[tid],
            coords3d_buf4 = coords3d_buf4_tl[tid],
            coords3d_local_buf4 = coords3d_local_buf4_tl[tid],
            directors3d_local_buf4 = directors3d_local_buf4_tl[tid],
            _kg_slot_base = (_shell_ei - 1) * 576

        pid = string(el["PID"])
        if !haskey(pshells, pid); continue; end
        prop = pshells[pid]; mid = string(prop["MID"])
        nids = el["NODES"]; n = length(nids)
        if !haskey(mats, mid); continue; end
        is_pcomp_clt = get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "Cm")
        base_mat = mats[mid]
        mat = is_pcomp_clt ? base_mat : _effective_mat1_for_nodes(model, mid, nids)
        h = Float64(prop["T"])
        pcomp_is_isotropic = is_pcomp_clt && get(prop, "IS_ISOTROPIC", false)
        is_ortho = !is_pcomp_clt && get(mat, "TYPE", "") == "MAT8" && haskey(mat, "E1") && haskey(mat, "E2")
        is_mat2  = !is_pcomp_clt && !is_ortho && get(mat, "TYPE", "") == "MAT2" && haskey(mat, "G11")
        is_iso_kg = pcomp_is_isotropic || (!is_pcomp_clt && !is_ortho && !is_mat2)

        valid = true
        for k in 1:n
            nid = nids[k]
            if nid < 1 || nid > max_nid || id_vec[nid] == 0; valid = false; break; end
        end
        if !valid; continue; end

        if n == 4
            # QUAD4 geometric stiffness
            i1 = id_vec[nids[1]]; i2 = id_vec[nids[2]]; i3 = id_vec[nids[3]]; i4 = id_vec[nids[4]]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])
            p4 = SVector{3}(node_coords[i4,1], node_coords[i4,2], node_coords[i4,3])
            d13_geom = p3 - p1
            d24_geom = p4 - p2
            v3_geom_raw = cross(d13_geom, d24_geom)
            v3_geom_len = norm(v3_geom_raw)
            local elem_is_flat_kg::Bool
            if v3_geom_len > 1e-12
                c_geom = (p1 + p2 + p3 + p4) / 4.0
                v3g = v3_geom_raw / v3_geom_len
                max_dev = max(abs(dot(p1-c_geom, v3g)), abs(dot(p2-c_geom, v3g)),
                              abs(dot(p3-c_geom, v3g)), abs(dot(p4-c_geom, v3g)))
                L_diag = max(norm(d13_geom), norm(d24_geom))
                elem_is_flat_kg = max_dev <
                    max(solver_env_float("JFEM_Q4_FLAT_TOL_REL", 1e-2), 1e-12) *
                    max(L_diag, 1e-12)
            else
                elem_is_flat_kg = true
                max_dev = 0.0
                L_diag = max(norm(d13_geom), norm(d24_geom))
            end
            warp_ratio_kg = max_dev / max(L_diag, 1e-12)
            v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
            snorm_pq_kg = if snorm_curvature &&
                             (snorm_has[i1] || snorm_has[i2] || snorm_has[i3] || snorm_has[i4])
                pq = snorm_element_pq(
                    v1, v2, v3, (i1, i2, i3, i4), snorm_normals_local)
                pq !== nothing && FEM.quad4_snorm_pq_has_active_rows(pq) ? pq : nothing
            else
                nothing
            end
            snorm_completion_active_kg = snorm_pq_kg !== nothing
            elem_snorm_curvature_kg = snorm_completion_active_kg
            if snorm_completion_active_kg
                kg_w_form_raw = lowercase(strip(
                    get(ENV, "JFEM_KG_SHELL_TRANSVERSE_W_FORM", "w")))
                if kg_w_form_raw in (
                    "rot", "rotation", "theta",
                    "cross", "wtheta", "w_theta", "sym_cross",
                    "wty", "nastran_cross", "metric_cross",
                )
                    throw(ArgumentError(
                        "JFEM_KG_SHELL_TRANSVERSE_W_FORM=$kg_w_form_raw is an " *
                        "unvalidated rotation-containing geometric-stiffness " *
                        "experiment under nonzero CQUAD4 PARAM,SNORM director " *
                        "completion; use the production 'w' form or PARAM,SNORM,0"
                    ))
                end
            end

            # SNORM adjustment
            n_avg = SVector(0.0, 0.0, 0.0); nc = 0
            for idx in (i1, i2, i3, i4)
                if snorm_has[idx]; n_avg = n_avg + snorm_vec[idx]; nc += 1; end
            end
            if snorm_curvature && !elem_snorm_curvature_kg
                # Canonical aligned zero-pq directors to the no-SNORM frame
                # before any legacy normal-based reprojection.
                nc = 0
            end
            # snorm_transform_only: keep OWN frame here (K/Kg-consistent); store element-averaged SNORM normal
            # for the UNIFORM per-element transform below.
            snorm_xf_v3 = SVector(0.0, 0.0, 0.0); snorm_xf_ok = false
            if nc > 0
                n_avg_s = n_avg / nc; len_s = norm(n_avg_s)
                if len_s > 1e-12
                    v3n = SVector{3}(n_avg_s / len_s)
                    if dot(v3n, v3) < 0.0; v3n = -v3n; end
                    if snorm_transform_only
                        snorm_xf_v3 = v3n; snorm_xf_ok = true
                    elseif !snorm_director && !elem_snorm_curvature_kg &&
                           dot(v3n, v3) >= snorm_tilt_gate_cos  # DIAGNOSTIC gate (K/Kg-consistent)
                        v1p = v1 - dot(v1, v3n) * v3n; v1l = norm(v1p)
                        if v1l > 1e-12
                            v1n = SVector{3}(v1p / v1l)
                        else
                            v2p = v2 - dot(v2, v3n) * v3n; v1n = SVector{3}(normalize(v2p))
                        end
                        v1, v2, v3 = v1n, SVector{3}(cross(v3n, v1n)), v3n
                    end
                end
            end
            if !elem_snorm_curvature_kg && curved_iso_geomnormal_frame &&
               is_iso_kg &&
               !elem_is_flat_kg &&
               (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 &&
               geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
                lc_probe = zeros(4,2)
                c_probe = (p1 + p2 + p3 + p4) / 4.0
                lc_probe[1,1] = dot(p1-c_probe, v1); lc_probe[1,2] = dot(p1-c_probe, v2)
                lc_probe[2,1] = dot(p2-c_probe, v1); lc_probe[2,2] = dot(p2-c_probe, v2)
                lc_probe[3,1] = dot(p3-c_probe, v1); lc_probe[3,2] = dot(p3-c_probe, v2)
                lc_probe[4,1] = dot(p4-c_probe, v1); lc_probe[4,2] = dot(p4-c_probe, v2)
                aspect_ratio_probe = q4_local_edge_aspect_ratio(lc_probe)
                geom_curvature_probe = estimate_quad4_curvature_membrane(
                    lc_probe, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                )
                k1_probe, _ = q4_curvature_principal_abs(geom_curvature_probe)
                kappa_l_probe = k1_probe * q4_curvature_characteristic_length(lc_probe)
                cyl_ratio_probe = q4_curvature_cyl_ratio(geom_curvature_probe)
                if aspect_ratio_probe >= curved_iso_geomnormal_frame_aspect_ratio_min &&
                   kappa_l_probe >= curved_iso_geomnormal_frame_kappa_l_min &&
                   kappa_l_probe <= curved_iso_geomnormal_frame_kappa_l_max &&
                   cyl_ratio_probe <= curved_iso_geomnormal_frame_cyl_ratio_max
                    v3_geom_sum = geom_vec[i1] + geom_vec[i2] + geom_vec[i3] + geom_vec[i4]
                    if norm(v3_geom_sum) > 1e-12
                        v3_geom_frame = normalize(v3_geom_sum)
                        if dot(v3_geom_frame, v3) < 0.0
                            v3_geom_frame = -v3_geom_frame
                        end
                        v1, v2, v3 = shell_element_frame_quad4_with_normal(
                            p1, p2, p3, p4, v3_geom_frame, q4_frame_mode
                        )
                    end
                end
            end
            Rel_t = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]

            # Local coordinates
            c_ctr = (p1 + p2 + p3 + p4) / 4.0
            lc_buf4[1,1] = dot(p1-c_ctr, v1); lc_buf4[1,2] = dot(p1-c_ctr, v2)
            lc_buf4[2,1] = dot(p2-c_ctr, v1); lc_buf4[2,2] = dot(p2-c_ctr, v2)
            lc_buf4[3,1] = dot(p3-c_ctr, v1); lc_buf4[3,2] = dot(p3-c_ctr, v2)
            lc_buf4[4,1] = dot(p4-c_ctr, v1); lc_buf4[4,2] = dot(p4-c_ctr, v2)
            coords3d_local_buf4[1,1] = lc_buf4[1,1]; coords3d_local_buf4[1,2] = lc_buf4[1,2]; coords3d_local_buf4[1,3] = dot(p1-c_ctr, v3)
            coords3d_local_buf4[2,1] = lc_buf4[2,1]; coords3d_local_buf4[2,2] = lc_buf4[2,2]; coords3d_local_buf4[2,3] = dot(p2-c_ctr, v3)
            coords3d_local_buf4[3,1] = lc_buf4[3,1]; coords3d_local_buf4[3,2] = lc_buf4[3,2]; coords3d_local_buf4[3,3] = dot(p3-c_ctr, v3)
            coords3d_local_buf4[4,1] = lc_buf4[4,1]; coords3d_local_buf4[4,2] = lc_buf4[4,2]; coords3d_local_buf4[4,3] = dot(p4-c_ctr, v3)
            aspect_ratio_kg = q4_local_edge_aspect_ratio(lc_buf4)
            taper_ratio_kg = q4_local_opposite_edge_ratio(lc_buf4)
            h_over_lmax_kg = h / max(q4_local_max_edge_length(lc_buf4), 1e-12)
            use_geom_snorm_kg = false
            if !elem_snorm_curvature_kg && curved_iso_geomnormal_frame &&
               is_iso_kg &&
               aspect_ratio_kg >= curved_iso_geomnormal_frame_aspect_ratio_min &&
               (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <= 10 &&
               geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
                geom_curv_probe = estimate_quad4_curvature_membrane(
                    lc_buf4, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                )
                k1_probe, _ = q4_curvature_principal_abs(geom_curv_probe)
                kappa_l_probe = k1_probe * q4_curvature_characteristic_length(lc_buf4)
                cyl_ratio_probe = q4_curvature_cyl_ratio(geom_curv_probe)
                if elem_is_flat_kg
                    use_geom_snorm_kg =
                        kappa_l_probe >= flat_curved_iso_geomnormal_frame_kappa_l_min &&
                        kappa_l_probe <= flat_curved_iso_geomnormal_frame_kappa_l_max &&
                        cyl_ratio_probe <= flat_curved_iso_geomnormal_frame_cyl_ratio_max
                else
                    use_geom_snorm_kg =
                        kappa_l_probe >= curved_iso_geomnormal_frame_kappa_l_min &&
                        kappa_l_probe <= curved_iso_geomnormal_frame_kappa_l_max &&
                        cyl_ratio_probe <= curved_iso_geomnormal_frame_cyl_ratio_max
                end
            end
            if use_geom_snorm_kg
                n_avg_g = geom_vec[i1] + geom_vec[i2] + geom_vec[i3] + geom_vec[i4]
                len_g = norm(n_avg_g)
                if len_g > 1e-12
                    v3n = SVector{3}(n_avg_g / len_g)
                    if dot(v3n, v3) < 0.0
                        v3n = -v3n
                    end
                    v1p = v1 - dot(v1, v3n) * v3n
                    v1l = norm(v1p)
                    if v1l > 1e-12
                        v1n = SVector{3}(v1p / v1l)
                    else
                        v2p = v2 - dot(v2, v3n) * v3n
                        v1n = SVector{3}(normalize(v2p))
                    end
                    v1, v2, v3 = v1n, SVector{3}(cross(v3n, v1n)), v3n
                    lc_buf4[1,1] = dot(p1-c_ctr, v1); lc_buf4[1,2] = dot(p1-c_ctr, v2)
                    lc_buf4[2,1] = dot(p2-c_ctr, v1); lc_buf4[2,2] = dot(p2-c_ctr, v2)
                    lc_buf4[3,1] = dot(p3-c_ctr, v1); lc_buf4[3,2] = dot(p3-c_ctr, v2)
                    lc_buf4[4,1] = dot(p4-c_ctr, v1); lc_buf4[4,2] = dot(p4-c_ctr, v2)
                    coords3d_local_buf4[1,1] = lc_buf4[1,1]; coords3d_local_buf4[1,2] = lc_buf4[1,2]; coords3d_local_buf4[1,3] = dot(p1-c_ctr, v3)
                    coords3d_local_buf4[2,1] = lc_buf4[2,1]; coords3d_local_buf4[2,2] = lc_buf4[2,2]; coords3d_local_buf4[2,3] = dot(p2-c_ctr, v3)
                    coords3d_local_buf4[3,1] = lc_buf4[3,1]; coords3d_local_buf4[3,2] = lc_buf4[3,2]; coords3d_local_buf4[3,3] = dot(p3-c_ctr, v3)
                    coords3d_local_buf4[4,1] = lc_buf4[4,1]; coords3d_local_buf4[4,2] = lc_buf4[4,2]; coords3d_local_buf4[4,3] = dot(p4-c_ctr, v3)
                    aspect_ratio_kg = q4_local_edge_aspect_ratio(lc_buf4)
                    taper_ratio_kg = q4_local_opposite_edge_ratio(lc_buf4)
                end
            end
            edge_skew_kg = q4_local_edge_skew_angle(lc_buf4)
            elem_mitc4_3d_kg_recovery =
                if mitc4_3d_kg_recovery_all
                    true
                elseif mitc4_3d_kg_recovery_aspect
                    kappa_l_mitc4_3d_aspect_kg = 0.0
                    if geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
                        geom_curv_mitc4_kg = estimate_quad4_curvature_membrane(
                            lc_buf4, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                        )
                        k1_mitc4_kg, _ = q4_curvature_principal_abs(geom_curv_mitc4_kg)
                        kappa_l_mitc4_3d_aspect_kg =
                            k1_mitc4_kg * q4_curvature_characteristic_length(lc_buf4)
                    end
                    q4_mitc4_3d_aspect_geom_ok(
                        aspect_ratio_kg,
                        warp_ratio_kg,
                        kappa_l_mitc4_3d_aspect_kg,
                        edge_skew_kg,
                        mitc4_3d_aspect_min_kg,
                        mitc4_3d_aspect_max_kg,
                        mitc4_3d_aspect_warp_min_kg,
                        mitc4_3d_aspect_warp_max_kg,
                        mitc4_3d_aspect_kappa_l_min_kg,
                        mitc4_3d_aspect_kappa_l_max_kg,
                        mitc4_3d_aspect_skew_min_kg,
                        mitc4_3d_aspect_skew_max_kg,
                        mitc4_3d_aspect_skew_aspect_min_kg,
                    ) &&
                    (!mitc4_3d_aspect_pcomp_only_kg || is_pcomp_clt)
                else
                    false
                end
            elem_snorm_curvature_kg && (elem_mitc4_3d_kg_recovery = false)
            mitc4_3d_use_geom_dirs_kg =
                elem_mitc4_3d_kg_recovery && geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            if elem_mitc4_3d_kg_recovery
                for (row, ncurv) in enumerate((
                    mitc4_3d_use_geom_dirs_kg ? geom_vec[i1] : (snorm_has[i1] ? snorm_vec[i1] : v3),
                    mitc4_3d_use_geom_dirs_kg ? geom_vec[i2] : (snorm_has[i2] ? snorm_vec[i2] : v3),
                    mitc4_3d_use_geom_dirs_kg ? geom_vec[i3] : (snorm_has[i3] ? snorm_vec[i3] : v3),
                    mitc4_3d_use_geom_dirs_kg ? geom_vec[i4] : (snorm_has[i4] ? snorm_vec[i4] : v3),
                ))
                    nloc = SVector(dot(ncurv, v1), dot(ncurv, v2), dot(ncurv, v3))
                    if nloc[3] < 0.0
                        nloc = -nloc
                    end
                    nlen = norm(nloc)
                    if nlen > 1e-12
                        directors3d_local_buf4[row,1] = nloc[1] / nlen
                        directors3d_local_buf4[row,2] = nloc[2] / nlen
                        directors3d_local_buf4[row,3] = nloc[3] / nlen
                    else
                        directors3d_local_buf4[row,1] = 0.0
                        directors3d_local_buf4[row,2] = 0.0
                        directors3d_local_buf4[row,3] = 1.0
                    end
                end
            end
            elem_flat_curved_iso_nodal_geomnormal_transform_kg =
                flat_curved_iso_nodal_geomnormal_transform &&
                is_iso_kg &&
                elem_is_flat_kg &&
                use_geom_snorm_kg &&
                aspect_ratio_kg >= flat_curved_iso_nodal_geomnormal_transform_aspect_ratio_min &&
                (shell_valence[i1] + shell_valence[i2] + shell_valence[i3] + shell_valence[i4]) <=
                    flat_curved_iso_nodal_geomnormal_transform_valence_sum_max &&
                geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            iso_auto_curvature_resolution_ok = !is_iso_kg ||
                aspect_ratio_kg <= q4_shell_kg_auto_curvature_iso_aspect_ratio_max()
            iso_geom_curvature_kg = nothing
            iso_corner_curvature_kg = nothing
            kappa_l_iso_kg = 0.0
            cyl_ratio_iso_kg = 1.0
            auto_curved_iso_membrane_incomp_kg = false
            auto_warped_iso_membrane_incomp_kg = false
            auto_elongated_iso_membrane_incomp_kg = false
            if curved_iso_eig_membrane_incomp &&
               !is_pcomp_clt &&
               !is_ortho &&
               !is_mat2 &&
               iso_auto_curvature_resolution_ok &&
               geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
                iso_geom_curvature_kg = estimate_quad4_curvature_membrane(
                    lc_buf4, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                )
                k1_iso_kg, _ = q4_curvature_principal_abs(iso_geom_curvature_kg)
                kappa_l_iso_kg = k1_iso_kg * q4_curvature_characteristic_length(lc_buf4)
                cyl_ratio_iso_kg = q4_curvature_cyl_ratio(iso_geom_curvature_kg)
                auto_curved_iso_membrane_incomp_kg =
                    kappa_l_iso_kg >= curved_iso_eig_membrane_incomp_kappa_l_min &&
                    cyl_ratio_iso_kg <= curved_iso_eig_membrane_incomp_cyl_ratio_max
                auto_warped_iso_membrane_incomp_kg =
                    curved_iso_warp_membrane_incomp &&
                    !elem_is_flat_kg &&
                    warp_ratio_kg >= curved_iso_warp_membrane_incomp_ratio_min &&
                    kappa_l_iso_kg <= curved_iso_warp_membrane_incomp_kappa_l_max
            end
            if flat_iso_dkmq_branch && is_iso_kg && !elem_is_flat_kg
                iso_corner_curvature_kg = estimate_quad4_corner_curvature_membrane(
                    lc_buf4, p1, p2, p3, p4, v1, v2, v3
                )
            end
            auto_elongated_iso_membrane_incomp_kg =
                curved_iso_elongated_membrane_incomp &&
                is_iso_kg &&
                !elem_is_flat_kg &&
                aspect_ratio_kg >= curved_iso_elongated_membrane_incomp_aspect_ratio_min
            elem_membrane_incomp_kg = membrane_incomp || auto_curved_iso_membrane_incomp_kg ||
                                      auto_warped_iso_membrane_incomp_kg ||
                                      auto_elongated_iso_membrane_incomp_kg ||
                                      ((kg_pcomp_membrane_incomp ||
                                        (auto_pcomp_membrane_incomp_model && is_pcomp_clt)) && is_pcomp_clt) ||
                                      (flat_iso_eig_membrane_incomp && elem_is_flat_kg && is_iso_kg)
            curvature_membrane = nothing
            kg_curvature = nothing
            kg_trans_mode_eff = kg_trans_mode
            if kg_trans_mode_eff === :principal_transverse &&
               kg_principal_transverse_flat_only &&
               (!elem_is_flat_kg || warp_ratio_kg > kg_principal_transverse_warp_ratio_max)
                kg_trans_mode_eff = :all
            end
            kg_curvature_sign_eff = kg_curvature_sign
            covariant_membrane_candidate = false
            n1_curv_kg = use_geom_snorm_kg ? geom_vec[i1] : snorm_vec[i1]
            n2_curv_kg = use_geom_snorm_kg ? geom_vec[i2] : snorm_vec[i2]
            n3_curv_kg = use_geom_snorm_kg ? geom_vec[i3] : snorm_vec[i3]
            n4_curv_kg = use_geom_snorm_kg ? geom_vec[i4] : snorm_vec[i4]
            has_curv_normals_kg = use_geom_snorm_kg ||
                                  (snorm_has[i1] && snorm_has[i2] && snorm_has[i3] && snorm_has[i4])
            # Marguerre rotation-membrane slope coupling for K_g σ recovery
            # (Ibrahimbegović 1994 Eq. 6.14). Mirrors the K-assembly side at
            # line ~2803. Activated by JFEM_Q4_MARGUERRE_COUPLING=true. Adds
            # the geometric coupling between θx/θy and in-plane strain to the
            # σ recovery on curved shells. The curvature_membrane (w-DOF
            # Koiter-Donnell) coupling was disabled by default because it
            # produced catastrophic regression — Marguerre on rotation DOFs
            # is the correct counterpart per the existing comment in
            # q4_curvature_membrane_scale().
            slope_membrane_kg = nothing
            # For the Marguerre slope, we look at geom normals directly rather
            # than going through has_curv_normals_kg — the latter is iso-only
            # and would block PCOMP-curved elements (e.g. HTP_launch). The
            # Marguerre coupling needs the geometric surface slope which is
            # equally well-defined for iso and PCOMP.
            marguerre_can_compute = q4_marguerre_coupling_enabled() &&
                geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
            if marguerre_can_compute
                n1m = geom_vec[i1]; n2m = geom_vec[i2]
                n3m = geom_vec[i3]; n4m = geom_vec[i4]
                slope_raw_kg = estimate_quad4_slope_membrane(
                    n1m, n2m, n3m, n4m, v1, v2, v3
                )
                marguerre_scale_kg = q4_marguerre_coupling_scale()
                if marguerre_scale_kg != 1.0
                    slope_raw_kg = slope_raw_kg * marguerre_scale_kg
                end
                marguerre_handover_kg = q4_marguerre_coupling_convention() === :handover ? 1.0 : 0.0
                slope_membrane_kg = SVector{9,Float64}(
                    slope_raw_kg[1], slope_raw_kg[2], slope_raw_kg[3], slope_raw_kg[4],
                    slope_raw_kg[5], slope_raw_kg[6], slope_raw_kg[7], slope_raw_kg[8],
                    marguerre_handover_kg,
                )
            end
            geom_curvature = nothing
            if (kg_trans_mode === :curvature ||
                (kg_pcomp_auto_g12 && is_pcomp_clt && !pcomp_is_isotropic) ||
                (kg_auto_curvature_pcomp && is_pcomp_clt && !pcomp_is_isotropic) ||
                (is_pcomp_clt && !pcomp_is_isotropic) ||
                (kg_auto_curvature_iso && is_iso_kg)) &&
               geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4]
                geom_curvature = estimate_quad4_curvature_membrane(
                    lc_buf4, geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4], v1, v2, v3
                )
            end
            if is_iso_kg && kg_trans_mode !== :curvature && !iso_auto_curvature_resolution_ok
                geom_curvature = nothing
            end
            if kg_trans_mode === :curvature
                kg_curvature = geom_curvature
            end
            if kg_auto_curvature_iso && is_iso_kg && geom_curvature !== nothing
                k1, _ = q4_curvature_principal_abs(geom_curvature)
                kappa_l = k1 * q4_curvature_characteristic_length(lc_buf4)
                cyl_ratio = q4_curvature_cyl_ratio(geom_curvature)
                aspect_ratio = q4_local_edge_aspect_ratio(lc_buf4)
                covariant_membrane_candidate = covariant_membrane_candidate ||
                    (kappa_l >= kg_covariant_auto_kappa_l_min &&
                     cyl_ratio <= kg_covariant_auto_cyl_ratio_max &&
                     aspect_ratio <= q4_shell_kg_auto_curvature_iso_aspect_ratio_max())
                if kg_auto_curvature_iso_cyl_candidate(kappa_l, cyl_ratio, aspect_ratio)
                    kg_trans_mode_eff = :curvature
                    kg_curvature = geom_curvature * q4_shell_kg_auto_curvature_iso_cyl_scale()
                    kg_curvature_sign_eff = q4_shell_kg_auto_curvature_iso_cyl_sign()
                elseif kg_auto_curvature_iso_candidate(kappa_l, cyl_ratio, aspect_ratio)
                    kg_trans_mode_eff = :curvature
                    kg_curvature = geom_curvature * q4_shell_kg_auto_curvature_iso_effective_scale(cyl_ratio, kappa_l)
                    kg_curvature_sign_eff = q4_shell_kg_auto_curvature_iso_sign()
                end
            end
            # Build transformation matrix T (24x24)
            fill!(T_buf, 0.0)
            for k in 1:4
                idx = k == 1 ? i1 : k == 2 ? i2 : k == 3 ? i3 : i4
                base = (k-1)*6
                vk1, vk2, vk3 =
                    (snorm_transform_only && snorm_xf_ok) ?
                    shell_project_frame_to_normal(v1, v2, v3, snorm_xf_v3) :
                    elem_flat_curved_iso_nodal_geomnormal_transform_kg ?
                    shell_project_frame_to_normal(v1, v2, v3, geom_vec[idx]) :
                    (v1, v2, v3)
                Rel_t = @SMatrix [vk1[1] vk1[2] vk1[3]; vk2[1] vk2[2] vk2[3]; vk3[1] vk3[2] vk3[3]]
                for rr in 1:3, cc in 1:3
                    val = Rel_t[rr,1]*node_R_flat[1,cc,idx] + Rel_t[rr,2]*node_R_flat[2,cc,idx] + Rel_t[rr,3]*node_R_flat[3,cc,idx]
                    T_buf[base+rr, base+cc] = val
                    T_buf[base+3+rr, base+3+cc] = val
                end
                if snorm_director && snorm_has[idx]
                    # mirror of the K-assembly transform; same element-frame convention.
                    TR = @SMatrix [T_buf[base+4,base+4] T_buf[base+4,base+5] T_buf[base+4,base+6];
                                   T_buf[base+5,base+4] T_buf[base+5,base+5] T_buf[base+5,base+6];
                                   T_buf[base+6,base+4] T_buf[base+6,base+5] T_buf[base+6,base+6]]
                    TRs = snorm_director_matrix(snorm_vec[idx], v1, v2, v3) * TR
                    for rr in 1:3, cc in 1:3
                        T_buf[base+3+rr, base+3+cc] = TRs[rr,cc]
                    end
                end
            end

            # Extract element displacements in local coordinates
            for k in 1:4
                idx = k == 1 ? i1 : k == 2 ? i2 : k == 3 ? i3 : i4
                b_g = (idx-1)*6
                b_l = (k-1)*6
                for d in 1:6; u_elem24[b_l+d] = 0.0; end
                for d in 1:6
                    ug = u_global[b_g+d]
                    for dd in 1:6; u_elem24[b_l+dd] += T_buf[b_l+dd, b_l+d] * ug; end
                end
            end

            # Get material properties for stress recovery
            E_val = get(mat, "E", 70000.0); nu_val = get(mat, "NU", 0.3)
            t_shell = h

            # For PCOMP, rotate the laminate Cm into the element frame using
            # the shell THETA angle measured from the element x-axis.
            Cm_override = nothing
            Cb_kg = nothing
            Cs_kg = nothing
            Bmb_kg = nothing
            kg_axis_mode_eff = kg_pcomp_axis_mode
            kg_material_shear_rotation = 0.0
            shear_ratio = 0.0
            d16_ratio = 0.0
            b_ratio = 0.0
            if is_pcomp_clt && !pcomp_is_isotropic
                theta_deg_metrics = Float64(get(el, "THETA", 0.0))
                shear_ratio, d16_ratio, b_ratio = pcomp_metric_ratios(prop, deg2rad(theta_deg_metrics))
            end
            kg_flat_curved_iso_exact_membrane = false
            kg_flat_iso_exact_membrane = flat_iso_dkmq_branch &&
                                         !model_has_line_elements &&
                                         is_iso_kg &&
                                         elem_is_flat_kg &&
                                         get(prop, "Bmb", nothing) === nothing &&
                                         !node_has_line[i1] && !node_has_line[i2] &&
                                         !node_has_line[i3] && !node_has_line[i4] &&
                                         geom_has[i1] && geom_has[i2] && geom_has[i3] && geom_has[i4] &&
                                         q4_geom_normals_nearly_constant(
                                             geom_vec[i1], geom_vec[i2], geom_vec[i3], geom_vec[i4]
                                         )
            kg_saddle_iso_exact_membrane = false
            kg_cyl_iso_exact_membrane = flat_iso_dkmq_branch &&
                                        is_iso_kg &&
                                        !elem_is_flat_kg &&
                                        get(prop, "Bmb", nothing) === nothing &&
                                        iso_corner_curvature_kg !== nothing &&
                                        abs(q4_curvature_gaussian(iso_corner_curvature_kg)) <= 1e-10 &&
                                        first(q4_curvature_principal_abs(iso_corner_curvature_kg)) > 1e-8
            if flat_iso_dkmq_branch &&
               is_iso_kg &&
               elem_is_flat_kg &&
               get(prop, "Bmb", nothing) === nothing &&
               iso_geom_curvature_kg !== nothing
                kg_flat_curved_iso_exact_membrane =
                    flat_curved_iso_eig_center_only &&
                    kappa_l_iso_kg >= flat_curved_iso_eig_center_only_kappa_l_min &&
                    cyl_ratio_iso_kg <= flat_curved_iso_eig_center_only_cyl_ratio_max
            end
            kg_iso_exact_membrane =
                kg_flat_iso_exact_membrane || kg_flat_curved_iso_exact_membrane ||
                kg_saddle_iso_exact_membrane || kg_cyl_iso_exact_membrane
            if curvature_membrane === nothing && kg_cyl_iso_exact_membrane && iso_corner_curvature_kg !== nothing
                # Keep the cylindrical exact-membrane branch consistent between
                # the static/eigen stiffness and the geometric stiffness recovery.
                curvature_membrane = iso_corner_curvature_kg
            end
            kg_flat_dkmq_branch = flat_pcomp_dkmq_branch &&
                                  is_pcomp_clt &&
                                  !pcomp_is_isotropic &&
                                  elem_is_flat_kg &&
                                  get(prop, "Bmb", nothing) === nothing &&
                                  maximum(abs, prop["Cb"]) > 1e-30
            # Nastran-KDJJ-exact Kg for flat isotropic (non-PCOMP) CQUAD4.
            # Provably inert on all-PCOMP models (gate requires !is_pcomp_clt),
            # same guardrail class as the high-skew/warp-tol kernel-gate fixes.
            kg_nastran_kdjj_iso_branch =
                kg_iso_nastran_kdjj_mode_v !== :off &&
                is_iso_kg &&
                !is_pcomp_clt &&
                elem_is_flat_kg &&
                get(prop, "Bmb", nothing) === nothing &&
                (kg_iso_nastran_kdjj_mode_v === :all ||
                 abs(90.0 - edge_skew_kg) >= kg_iso_nastran_kdjj_skew_min_deg_v)
            # Nastran-KDJJ-exact Kg for FLAT COMPOSITE (PCOMP, non-isotropic)
            # CQUAD4.  Same bisector-frame component-string operator as the iso
            # branch, but the membrane stress resultant is JFEM's ALREADY-
            # RECOVERED element field (N_res, the resultant) fed in directly --
            # NOT recomputed inside the kernel.  Offline the resultant broadcast
            # to all GPs (no frame rotation -- the recovered N is already in the
            # lc = bisector frame) hits the KDJJ in-plane block at 6.7% (skew20)
            # / 15.1% (skew45), vs 10.7/21.2% for the per-GP N_gp -- the
            # resultant averages out recovery noise the per-GP field carries.
            # Default OFF (JFEM_SOL105_PCOMP_SKEW_MEMBRANE, the composite-skew
            # investigation flag); pairs with the elastic-K skew fixes.
            # SKEW-SCOPED (2026-07-16): the KDJJ composite kernel consumes the
            # element-mean N_res broadcast to all GPs -- correct where the legacy
            # operator's skew SHAPE error dominates (dev >= threshold), but a
            # gradient-state regression on rectangles where the legacy Kg was
            # already ratio-1.00 vs KDJJ.  Rects keep the legacy operator.
            # JFEM_SOL105_PCOMP_SKEW_MEMBRANE_KG=false disables just this branch
            # (attribution sub-gate; default follows the master flag).
            # JFEM_SOL105_PCOMP_KDJJ_MODE=all extends the KDJJ operator to
            # EVERY flat composite (rects included) -- the composite analog of
            # the iso kernel's skew->all promotion: with the SELC-consistent
            # per-GP recovered field, the legacy element-mean operator's
            # gradient-state defect is the thing being replaced (2026-07-17).
            # JFEM_SOL105_PCOMP_KDJJ_ALLOW_BMB (default OFF): admit UNSYMMETRIC
            # (Bmb != nothing) laminates to the Nastran-KDJJ kernel.  The kernel
            # consumes only the recovered membrane resultant field, so the
            # membrane-bending coupling enters through the STATIC solve (already
            # coupled), not the differential-stiffness operator itself.  DOE
            # 2026-07-22: symmetric strongly-orthotropic stacks match Nastran
            # (A=B 0.34%, C exact) while unsymmetric stacks on the LEGACY path
            # miss by 10-33% -- the gate, not the physics, was the gap.
            kg_nastran_kdjj_pcomp_branch =
                solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true) &&
                solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE_KG", false) &&
                is_pcomp_clt &&
                !pcomp_is_isotropic &&
                elem_is_flat_kg &&
                (get(prop, "Bmb", nothing) === nothing ||
                 solver_env_bool("JFEM_SOL105_PCOMP_KDJJ_ALLOW_BMB", false)) &&
                (lowercase(strip(get(ENV, "JFEM_SOL105_PCOMP_KDJJ_MODE", "skew"))) == "all" ||
                 abs(90.0 - edge_skew_kg) >= sol105_pcomp_skew_membrane_min_deg())
            kg_flat_plate_auto = is_pcomp_clt &&
                                 flat_pcomp_plate_auto &&
                                 !pcomp_is_isotropic &&
                                 elem_is_flat_kg &&
                                 get(prop, "Bmb", nothing) === nothing &&
                                 maximum(abs, prop["Cb"]) > 1e-30 &&
                                 FEM.quad4_is_axis_aligned_rectangle(lc_buf4) &&
                                 d16_ratio <= flat_pcomp_plate_auto_d16_ratio_max &&
                                 shear_ratio <= flat_pcomp_plate_auto_shear_ratio_max
            kg_flat_plate_branch = is_pcomp_clt &&
                                   (flat_pcomp_plate_branch || kg_flat_plate_auto) &&
                                   !pcomp_is_isotropic &&
                                   elem_is_flat_kg &&
                                   get(prop, "Bmb", nothing) === nothing &&
                                   maximum(abs, prop["Cb"]) > 1e-30
            if snorm_completion_active_kg
                # An active PARAM,SNORM normal-moment operator must use the
                # matching projected geometric-stiffness route. Standalone
                # KDJJ/DKQ/DKMQ operators do not carry the same normal-moment
                # and finite-warp maps, so quarantine them.
                kg_nastran_kdjj_iso_branch = false
                kg_nastran_kdjj_pcomp_branch = false
                kg_flat_dkmq_branch = false
                kg_flat_plate_branch = false
            end
            if is_pcomp_clt
                theta_deg = Float64(get(el, "THETA", 0.0))
                theta_rad = deg2rad(theta_deg)
                if (kg_flat_pcomp_auto_g12 || kg_pcomp_auto_g12 || kg_auto_curvature_pcomp) &&
                   !get(prop, "IS_ISOTROPIC", false) && geom_curvature !== nothing
                    k1, _ = q4_curvature_principal_abs(geom_curvature)
                    kappa_l = k1 * q4_curvature_characteristic_length(lc_buf4)
                    cyl_ratio = q4_curvature_cyl_ratio(geom_curvature)
                    auto_pcomp_element_axis_kg =
                        !kg_pcomp_axis_mode_override &&
                        q4_sol105_pcomp_auto_element_axis_candidate(prop, kappa_l, cyl_ratio)
                    covariant_membrane_candidate = covariant_membrane_candidate ||
                        (kappa_l >= kg_covariant_auto_kappa_l_min && cyl_ratio <= kg_covariant_auto_cyl_ratio_max)
                    if auto_pcomp_element_axis_kg
                        kg_axis_mode_eff = :element
                    elseif kg_pcomp_auto_global_x &&
                           !elem_is_flat_kg &&
                           shear_ratio <= kg_pcomp_auto_global_x_shear_ratio_max &&
                           d16_ratio <= kg_pcomp_auto_global_x_d16_ratio_max &&
                           b_ratio <= kg_pcomp_auto_global_x_b_ratio_max
                        if kg_pcomp_auto_global_x_kappa_l_min <= 0.0 &&
                           kg_pcomp_auto_global_x_cyl_ratio_min <= 0.0
                            kg_axis_mode_eff = :global_x
                        elseif kappa_l >= kg_pcomp_auto_global_x_kappa_l_min &&
                               cyl_ratio >= kg_pcomp_auto_global_x_cyl_ratio_min
                            kg_axis_mode_eff = :global_x
                        end
                    elseif kg_flat_pcomp_auto_g12 &&
                       shear_ratio <= kg_flat_pcomp_auto_g12_shear_ratio_max &&
                       d16_ratio <= kg_flat_pcomp_auto_g12_d16_ratio_max &&
                       b_ratio <= kg_flat_pcomp_auto_g12_b_ratio_max
                        kg_axis_mode_eff = :g12
                    elseif kg_pcomp_auto_g12 &&
                       kg_auto_pcomp_g12_candidate(theta_deg, shear_ratio, d16_ratio, b_ratio, kappa_l, cyl_ratio)
                        kg_axis_mode_eff = :g12
                    end
                    if kg_auto_curvature_pcomp &&
                       kg_auto_curvature_pcomp_candidate(theta_deg, shear_ratio, d16_ratio, b_ratio, kappa_l, cyl_ratio)
                        kg_trans_mode_eff = :curvature
                        kg_curvature = geom_curvature * q4_pcomp_kg_auto_curvature_scale()
                        kg_curvature_sign_eff = q4_pcomp_kg_auto_curvature_sign()
                    end
                end
                Cm_override = copy(prop["Cm"])
                Bmb_kg = get(prop, "Bmb", nothing) === nothing ? nothing : copy(prop["Bmb"])
                beta_kg = shell_pcomp_kg_rotation(
                    kg_axis_mode_eff,
                    v1, v2, v3, p1, p2, p3, p4,
                    theta_rad,
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
                kg_material_shear_rotation = beta_kg
                if abs(beta_kg) > 1e-10
                    cb = cos(beta_kg); sb = sin(beta_kg)
                    c2 = cb^2; s2 = sb^2; cs = cb*sb
                    _rotate_constitutive_3x3!(Cm_override,
                        c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    if Bmb_kg !== nothing
                        _rotate_constitutive_3x3!(Bmb_kg,
                            c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    end
                end
                # Frame-consistency on the Kg STRESS-RECOVERY side, mirroring the
                # elastic-K membrane fix (0e38bd1).  quad4_membrane_force_field
                # builds the recovery B-matrix in the element-LOCAL (lc = v1,v2
                # bisector) frame; the recovered resultant N = Cm*eps must use a Cm
                # in that SAME frame.  Without this, the skew recovery collapses the
                # membrane shear resultant (skew45: nxy -0.71 -> -0.07) and the
                # KDJJ Kg operator -- which needs nxy ~ -0.82 -- lands at 67% not
                # the ~15% floor.  Same OBJECTIVE in-plane angle and raw-THETA-path
                # scoping as the elastic-K side (g12 projected-edge angle; the earlier
                # -atan(v1_y,v1_x) proxy mis-rotated non-XY-plane panels; MCID and
                # :g12/:global_x betas already contain the frame angle).  Rotate
                # Cm_override AND Bmb_kg (same membrane-strain frame).
                if solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true) &&
                   !pcomp_is_isotropic && elem_is_flat_kg
                    mcid_kg_phi = Int(get(el, "MCID", 0))
                    mcid_kg_phi_active = mcid_kg_phi > 0 && model["CORDs"] !== nothing &&
                                         haskey(model["CORDs"], string(mcid_kg_phi))
                    if !mcid_kg_phi_active &&
                       kg_axis_mode_eff !== :g12 && kg_axis_mode_eff !== :global_x
                        phi_kg = shell_material_rotation_from_g12(v1, v2, v3, p1, p2, 0.0)
                        if abs(phi_kg) > 1e-10
                            cbp = cos(phi_kg); sbp = sin(phi_kg)
                            c2p = cbp^2; s2p = sbp^2; csp = cbp*sbp
                            _rotate_constitutive_3x3!(Cm_override,
                                c2p, s2p, csp, s2p, c2p, -csp, -2csp, 2csp, c2p - s2p)
                            if Bmb_kg !== nothing
                                _rotate_constitutive_3x3!(Bmb_kg,
                                    c2p, s2p, csp, s2p, c2p, -csp, -2csp, 2csp, c2p - s2p)
                            end
                        end
                    end
                end
                if kg_flat_plate_branch || kg_flat_dkmq_branch
                    Cb_kg = copy(prop["Cb"])
                    Cs_kg = copy(prop["Cs"])
                    if abs(beta_kg) > 1e-10
                        cb = cos(beta_kg); sb = sin(beta_kg)
                        c2 = cb^2; s2 = sb^2; cs = cb*sb
                        _rotate_constitutive_3x3!(Cb_kg,
                            c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                        a11 = Cs_kg[1,1]; a12 = Cs_kg[1,2]; a22 = Cs_kg[2,2]
                        Cs_kg[1,1] = cb^2*a11 + 2*cb*sb*a12 + sb^2*a22
                        Cs_kg[1,2] = -cb*sb*a11 + (cb^2-sb^2)*a12 + cb*sb*a22
                        Cs_kg[2,1] = Cs_kg[1,2]
                        Cs_kg[2,2] = sb^2*a11 - 2*cb*sb*a12 + cb^2*a22
                    end
                end
            end
            # Compute membrane resultants from the SOL101 displacement. A
            # caller can still force compatible-only recovery through
            # JFEM_KG_USE_COMPATIBLE_MEMBRANE_STRESS for diagnostic isolation.
            if elem_mitc4_3d_kg_recovery
                Cm_mitc4_3d = if Cm_override === nothing
                    const_mem = E_val / (1 - nu_val^2)
                    (const_mem .* [1 nu_val 0; nu_val 1 0; 0 0 (1-nu_val)/2]) * h
                else
                    Cm_override
                end
                N_gp, N_res, _ = FEM.quad4_mitc4_3d_membrane_force_field(
                    coords3d_local_buf4,
                    directors3d_local_buf4,
                    u_elem24,
                    Cm_mitc4_3d,
                    h;
                    Bmb=Bmb_kg,
                )
            else
                # Recovery-side twin of the SELC membrane (2026-07-17): the
                # SOL101->N recovery must use the SAME operator as the
                # elastic K (per-GP normal strains + CENTER-sampled shear in
                # the lc frame, NO Wilson modes), or gradient fields recover
                # a stress state inconsistent with the stiffness that
                # produced u -- exact on uniform single-element states (why
                # the probes pass) but wrong on real panels (the spurious
                # local-mode mechanism).  Cm_override is already phi-rotated
                # into the lc frame (96a4ff6), so the projection rotation is 0.
                kg_membrane_selc =
                    solver_env_bool("JFEM_SOL105_PCOMP_MEMBRANE_SELC", true) &&
                    solver_env_bool("JFEM_SOL105_PCOMP_SKEW_MEMBRANE", true) &&
                    is_pcomp_clt && !pcomp_is_isotropic && elem_is_flat_kg &&
                    Bmb_kg === nothing
                N_gp, N_res, _ = FEM.quad4_membrane_force_field(
                    lc_buf4, u_elem24, E_val, nu_val, h;
                    Cm_override=Cm_override,
                    Bmb=Bmb_kg,
                    slope_membrane=slope_membrane_kg,
                    compatible_only=kg_compatible_membrane,
                    use_incompatible_modes=elem_membrane_incomp_kg &&
                        !kg_iso_exact_membrane && !kg_membrane_selc,
                    use_enhanced_modes=kg_iso_exact_membrane,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=kg_membrane_selc,
                    material_shear_rotation=kg_membrane_selc ? 0.0 : kg_material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                    # JFEM_KG_RECOVERY_CROSS_MEMBRANE_WEIGHTS (default OFF):
                    # align the Kg stress recovery's Wilson condensation with
                    # the static-K cross/shear-only weights so the recovered
                    # field's consistent nodal forces equal the element
                    # internal forces (report 3.29).  Flat elements only,
                    # mirroring the static-K gate.
                    mode_weights=(solver_env_bool(
                        "JFEM_KG_RECOVERY_CROSS_MEMBRANE_WEIGHTS", false) &&
                        elem_is_flat_kg && Bmb_kg === nothing &&
                        !kg_membrane_selc) ?
                        (0.0, 1.0, 1.0, 0.0) : nothing,
                    snorm_pq=snorm_pq_kg,
                    coords_3d=coords3d_local_buf4,
                )
            end
            if !elem_mitc4_3d_kg_recovery &&
               !elem_snorm_curvature_kg &&
               kg_membrane_recovery_mode in (:tri_aspect, :tri_center_adj, :tri_incident_interp, :tri_diagavg)
                Cm_tri = if Cm_override === nothing
                    const_mem = E_val / (1 - nu_val^2)
                    (const_mem .* [1 nu_val 0; nu_val 1 0; 0 0 (1-nu_val)/2]) * h
                else
                    Cm_override
                end
                N_gp = FEM.quad4_membrane_force_field_triangle_recovery(
                    lc_buf4,
                    u_elem24,
                    Cm_tri,
                    N_res;
                    mode=kg_membrane_recovery_mode,
                    aspect_switch=kg_quad4_membrane_tri_aspect_switch(),
                )
            end
            if !elem_mitc4_3d_kg_recovery &&
               !elem_snorm_curvature_kg &&
               kg_compatible_membrane && kg_membrane_recovery_mode !== :planar && kg_covariant_blend > 0.0
                use_covariant = kg_membrane_recovery_mode === :covariant ||
                    (kg_membrane_recovery_mode === :auto && covariant_membrane_candidate)
                if use_covariant
                    coords3d = zeros(4, 3)
                    u_nodes_global = zeros(4, 3)
                    Cm_cov = if Cm_override === nothing
                        const_mem = E_val / (1 - nu_val^2)
                        (const_mem .* [1 nu_val 0; nu_val 1 0; 0 0 (1-nu_val)/2]) * h
                    else
                        Cm_override
                    end
                    for (kk, idx) in enumerate((i1, i2, i3, i4))
                        coords3d[kk, 1] = node_coords[idx, 1]
                        coords3d[kk, 2] = node_coords[idx, 2]
                        coords3d[kk, 3] = node_coords[idx, 3]
                        bg = (idx - 1) * 6
                        for rr in 1:3
                            u_nodes_global[kk, rr] =
                                node_R[idx][rr,1] * u_global[bg+1] +
                                node_R[idx][rr,2] * u_global[bg+2] +
                                node_R[idx][rr,3] * u_global[bg+3]
                        end
                    end
                    N_gp_cov, N_res_cov, _ = FEM.quad4_membrane_force_field_covariant(
                        coords3d, u_nodes_global, v1, v2, Cm_cov
                    )
                    if kg_covariant_blend >= 1.0
                        N_gp = N_gp_cov
                        N_res = N_res_cov
                    else
                        @inbounds for gp in 1:4, comp in 1:3
                            N_gp[gp, comp] = (1.0 - kg_covariant_blend) * N_gp[gp, comp] + kg_covariant_blend * N_gp_cov[gp, comp]
                        end
                        @inbounds for comp in 1:3
                            N_res[comp] = (1.0 - kg_covariant_blend) * N_res[comp] + kg_covariant_blend * N_res_cov[comp]
                        end
                    end
                end
            end
            gp_blend_override = kg_quad4_gp_field_blend_override()
            auto_avg_geom_ok = false
            auto_avg_curvature = geom_curvature
            if auto_avg_curvature === nothing && has_curv_normals_kg
                auto_avg_curvature = estimate_quad4_curvature_membrane(
                    lc_buf4, n1_curv_kg, n2_curv_kg, n3_curv_kg, n4_curv_kg, v1, v2, v3
                )
            end
            if auto_avg_curvature === nothing && !elem_is_flat_kg
                auto_avg_curvature = estimate_quad4_corner_curvature_membrane(
                    lc_buf4, p1, p2, p3, p4, v1, v2, v3
                )
            end
            if auto_avg_curvature !== nothing
                k1_auto_avg, _ = q4_curvature_principal_abs(auto_avg_curvature)
                kappa_l_auto_avg = k1_auto_avg * q4_curvature_characteristic_length(lc_buf4)
                cyl_ratio_auto_avg = q4_curvature_cyl_ratio(auto_avg_curvature)
                auto_avg_geom_ok =
                    kappa_l_auto_avg >= kg_quad4_auto_avg_kappa_l_min() &&
                    cyl_ratio_auto_avg >= kg_quad4_auto_avg_cyl_ratio_min()
            end
            use_gp_sigma = gp_blend_override === nothing &&
                kg_quad4_use_gp_field(N_gp, N_res, auto_avg_geom_ok)
            stress_mode_label = "average"
            gp_blend_alpha = 0.0
            shear_avg_candidate =
                kg_shear_avg_operator &&
                kg_quad4_shear_resultant_ratio(N_res) >= kg_shear_avg_ratio_min &&
                kg_quad4_geometry_gate(
                    warp_ratio_kg,
                    aspect_ratio_kg,
                    kg_shear_avg_warp_min,
                    kg_shear_avg_warp_max,
                    kg_shear_avg_aspect_min,
                    kg_shear_avg_aspect_max,
                    kg_shear_avg_geom_mode,
                )
            if gp_blend_override === nothing && !use_gp_sigma && kg_auto_gp_spread && geom_curvature !== nothing
                gp_mean_norm = 0.0
                @inbounds for gp in 1:size(N_gp, 1)
                    gp_mean_norm += sqrt(N_gp[gp,1]^2 + N_gp[gp,2]^2 + N_gp[gp,3]^2)
                end
                gp_mean_norm /= max(size(N_gp, 1), 1)
                if gp_mean_norm > 1e-12
                    gp_spread = 0.0
                    @inbounds for gp in 1:size(N_gp, 1)
                        dn1 = N_gp[gp,1] - N_res[1]
                        dn2 = N_gp[gp,2] - N_res[2]
                        dn3 = N_gp[gp,3] - N_res[3]
                        gp_spread = max(gp_spread, sqrt(dn1^2 + dn2^2 + dn3^2) / gp_mean_norm)
                    end
                    k1_gp, _ = q4_curvature_principal_abs(geom_curvature)
                    kappa_l_gp = k1_gp * q4_curvature_characteristic_length(lc_buf4)
                    cyl_ratio_gp = q4_curvature_cyl_ratio(geom_curvature)
                    if gp_spread >= kg_auto_gp_spread_min &&
                       kappa_l_gp >= kg_auto_gp_spread_kappa_l_min &&
                       cyl_ratio_gp >= kg_auto_gp_spread_cyl_ratio_min
                        gp_blend_scale = kg_quad4_auto_gp_spread_blend_scale()
                        if gp_blend_scale > 0.0
                            avg_norm = sqrt(N_res[1]^2 + N_res[2]^2 + N_res[3]^2)
                            avg_ratio = avg_norm / gp_mean_norm
                            gp_blend_alpha = clamp(gp_blend_scale * gp_spread * max(0.0, 1.0 - avg_ratio), 0.0, 1.0)
                        else
                            use_gp_sigma = true
                        end
                    end
                end
            end
            sigma_mem_input = if gp_blend_override !== nothing
                stress_mode_label = "override_blend"
                kg_quad4_blend_gp_field!(N_gp_eff, N_gp, N_res, gp_blend_override) ./ h
            elseif shear_avg_candidate
                stress_mode_label = "shear_average"
                N_res ./ h
            elseif use_gp_sigma
                if stress_mode_label == "average"
                    stress_mode_label = "gauss"
                end
                if kg_gp_extrapolate_scale != 1.0
                    stress_mode_label = "gauss_extrapolate"
                    kg_quad4_blend_gp_field!(N_gp_eff, N_gp, N_res, kg_gp_extrapolate_scale) ./ h
                else
                    N_gp ./ h
                end
            elseif gp_blend_alpha > 0.0
                stress_mode_label = "auto_blend"
                kg_quad4_blend_gp_field!(N_gp_eff, N_gp, N_res, gp_blend_alpha) ./ h
            else
                N_res ./ h
            end
            if kg_quad4_gp_field_pmin_spread_avg_alpha_v > 0.0 &&
               isfinite(kg_quad4_gp_field_pmin_spread_avg_min_v) &&
               sigma_mem_input isa AbstractMatrix &&
               kg_quad4_sigma_gp_pmin_spread_resultant(sigma_mem_input, h) >=
                   kg_quad4_gp_field_pmin_spread_avg_min_v
                gp_weight = 1.0 - kg_quad4_gp_field_pmin_spread_avg_alpha_v
                sigma_mem_input =
                    kg_quad4_blend_gp_field!(N_gp_eff, N_gp, N_res, gp_weight) ./ h
                stress_mode_label *= "_pminavg"
                gp_blend_alpha = gp_weight
            end
            if kg_shell_nxy_auto > 0.0 && geom_curvature !== nothing
                k1_auto, _ = q4_curvature_principal_abs(geom_curvature)
                kappa_l_auto = k1_auto * q4_curvature_characteristic_length(lc_buf4)
                cyl_ratio_auto = q4_curvature_cyl_ratio(geom_curvature)
                # The automatic Nxy relaxation is a curved-shell correction.
                # Keep it inactive on exactly flat geometry even when the env
                # threshold is zero, otherwise flat plates get an artificial
                # 1-relax reduction in shear prestress.
                if kappa_l_auto > max(kg_shell_nxy_auto_kappa_l_min_v, 1e-12) &&
                   cyl_ratio_auto <= kg_shell_nxy_auto_cyl_ratio_max_v
                    if sigma_mem_input isa AbstractMatrix
                        @inbounds for gp in 1:size(sigma_mem_input, 1)
                            sxx = sigma_mem_input[gp, 1]
                            syy = sigma_mem_input[gp, 2]
                            sxy = sigma_mem_input[gp, 3]
                            sigma_mem_input[gp, 3] *= kg_shell_nxy_auto_scale(
                                sxx, syy, sxy,
                                kg_shell_nxy_auto,
                                kg_shell_nxy_auto_ratio_min_v,
                                kg_shell_nxy_auto_ratio_full_v,
                            )
                        end
                    else
                        sigma_mem_input[3] *= kg_shell_nxy_auto_scale(
                            sigma_mem_input[1], sigma_mem_input[2], sigma_mem_input[3],
                            kg_shell_nxy_auto,
                            kg_shell_nxy_auto_ratio_min_v,
                            kg_shell_nxy_auto_ratio_full_v,
                        )
                    end
                end
            end
            if is_pcomp_clt
                kg_shell_pcomp_nxy_eff = kg_shell_pcomp_nxy
                if kg_shell_pcomp_nxy_aspect
                    kg_shell_pcomp_nxy_eff *= kg_shell_pcomp_nxy_aspect_scale(
                        q4_local_edge_aspect_ratio(lc_buf4),
                        kg_shell_pcomp_nxy_aspect_mode_v,
                        kg_shell_pcomp_nxy_aspect_low_v,
                        kg_shell_pcomp_nxy_aspect_mid_v,
                        kg_shell_pcomp_nxy_aspect_high_v,
                        kg_shell_pcomp_nxy_aspect_min_v,
                        kg_shell_pcomp_nxy_aspect_peak_v,
                        kg_shell_pcomp_nxy_aspect_max_v,
                    )
                end
                kg_shell_apply_pcomp_nxy_scale!(
                    sigma_mem_input,
                    kg_shell_pcomp_nxy_eff,
                    kg_shell_pcomp_nxy_compression_only_v,
                )
                kg_shell_apply_pcomp_nxy_shear_dom_scale!(
                    sigma_mem_input,
                    kg_shell_pcomp_nxy_shear_dom_relax_v,
                    kg_shell_pcomp_nxy_shear_dom_ratio_min_v,
                    kg_shell_pcomp_nxy_shear_dom_ratio_full_v,
                    aspect_ratio_kg,
                    kg_shell_pcomp_nxy_shear_dom_aspect_min_v,
                    kg_shell_pcomp_nxy_shear_dom_aspect_max_v,
                    kg_shell_pcomp_nxy_shear_dom_compression_only_v,
                )
            end
            h_over_lmax_kg = h / max(q4_local_max_edge_length(lc_buf4), 1e-12)
            geom_pshell_iso_warped_kg_scale =
                sol105_pshell_iso_warped_kg_enabled ?
                sol105_geom_pshell_iso_warped_kg_scale(
                    !is_pcomp_clt && is_iso_kg,
                    aspect_ratio_kg,
                    warp_ratio_kg,
                    h_over_lmax_kg,
                    sol105_pshell_iso_warped_kg_scale,
                    sol105_pshell_iso_warped_kg_aspect_min,
                    sol105_pshell_iso_warped_kg_aspect_max,
                    sol105_pshell_iso_warped_kg_warp_min,
                    sol105_pshell_iso_warped_kg_warp_max,
                    sol105_pshell_iso_warped_kg_h_over_lmax_min,
                    sol105_pshell_iso_warped_kg_h_over_lmax_max,
                ) : 1.0
            if geom_pshell_iso_warped_kg_scale != 1.0
                sigma_mem_input .*= geom_pshell_iso_warped_kg_scale
            end
            geom_pshell_iso_skew_kg_scale =
                sol105_pshell_iso_skew_kg_enabled ?
                sol105_geom_pshell_iso_skew_kg_scale(
                    !is_pcomp_clt && is_iso_kg,
                    aspect_ratio_kg,
                    warp_ratio_kg,
                    edge_skew_kg,
                    h_over_lmax_kg,
                    sol105_pshell_iso_skew_kg_scale,
                    sol105_pshell_iso_skew_kg_aspect_min,
                    sol105_pshell_iso_skew_kg_aspect_max,
                    sol105_pshell_iso_skew_kg_warp_max,
                    sol105_pshell_iso_skew_kg_skew_min,
                    sol105_pshell_iso_skew_kg_skew_max,
                    sol105_pshell_iso_skew_kg_h_over_lmax_min,
                    sol105_pshell_iso_skew_kg_h_over_lmax_max,
                ) : 1.0
            if geom_pshell_iso_skew_kg_scale != 1.0
                sigma_mem_input .*= geom_pshell_iso_skew_kg_scale
            end
            pcomp_pm45_fraction_kg = is_pcomp_clt ? pcomp_abs_angle_fraction(prop, 45.0) : 0.0
            pcomp_pm90_fraction_kg = is_pcomp_clt ? pcomp_abs_angle_fraction(prop, 90.0) : 0.0
            pcomp_ply_count_kg = is_pcomp_clt ? pcomp_ply_count(prop) : 0
            pcomp_nemeth_alpha_kg, pcomp_nemeth_beta_kg, pcomp_nemeth_gamma_kg, pcomp_nemeth_delta_kg =
                is_pcomp_clt ?
                pcomp_nemeth_parameters(prop, 1.0 / max(aspect_ratio_kg, 1.0)) :
                (0.0, 0.0, 0.0, 0.0)

            principal_shear_geom_ok = kg_quad4_geometry_gate(
                warp_ratio_kg,
                aspect_ratio_kg,
                kg_principal_shear_warp_min_v,
                kg_principal_shear_warp_max_v,
                kg_principal_shear_aspect_min_v,
                kg_principal_shear_aspect_max_v,
                kg_principal_shear_geom_mode_v,
            )
            principal_shear_yy_factor_eff = 1.0
            principal_shear_xy_factor_eff = 1.0
            principal_shear_z_factor_eff = 1.0
            principal_shear_ratio_min_eff = principal_shear_geom_ok ? kg_principal_shear_ratio_min_v : 1.0
            if principal_shear_geom_ok
                principal_shear_yy_factor_eff = kg_quad4_pid_membrane_effective_scale(
                    kg_principal_shear_yy_factor_v,
                    kg_principal_shear_feature_gate_v,
                    sigma_mem_input,
                    h,
                    kg_principal_shear_gp_pmin_spread_min_v,
                    kg_principal_shear_gp_nxx_spread_min_v,
                    kg_principal_shear_gp_spread_factor_v,
                )
                principal_shear_xy_factor_eff = kg_quad4_pid_membrane_effective_scale(
                    kg_principal_shear_xy_factor_v,
                    kg_principal_shear_feature_gate_v,
                    sigma_mem_input,
                    h,
                    kg_principal_shear_gp_pmin_spread_min_v,
                    kg_principal_shear_gp_nxx_spread_min_v,
                    kg_principal_shear_gp_spread_factor_v,
                )
                principal_shear_z_factor_eff = kg_quad4_pid_membrane_effective_scale(
                    kg_principal_shear_z_factor_v,
                    kg_principal_shear_feature_gate_v,
                    sigma_mem_input,
                    h,
                    kg_principal_shear_gp_pmin_spread_min_v,
                    kg_principal_shear_gp_nxx_spread_min_v,
                    kg_principal_shear_gp_spread_factor_v,
                )
            end


            has_bmb_kg = get(prop, "Bmb", nothing) !== nothing
            kg_pcomp_normal_only_diag = false
            kg_saddle_diag = false
            kg_trans_mode_diag, kg_pcomp_normal_only_diag, kg_saddle_diag =
                q4_pcomp_kg_trans_mode_final(
                    kg_trans_mode_eff,
                    is_pcomp_clt,
                    pcomp_is_isotropic,
                    has_bmb_kg,
                    elem_is_flat_kg,
                    flat_pcomp_plate_like_kg,
                    nonflat_pcomp_normal_only_kg,
                    geom_curvature,
                )
            geom_curvature_ok_diag = geom_curvature !== nothing
            geom_kappa_l_diag = 0.0
            geom_cyl_ratio_diag = 1.0
            geom_gaussian_diag = 0.0
            if geom_curvature_ok_diag
                k1_diag, _ = q4_curvature_principal_abs(geom_curvature)
                geom_kappa_l_diag = k1_diag * q4_curvature_characteristic_length(lc_buf4)
                geom_cyl_ratio_diag = q4_curvature_cyl_ratio(geom_curvature)
                geom_gaussian_diag = q4_curvature_gaussian(geom_curvature)
            end

            diag_Nxx_sum_tl[tid] += N_res[1]; diag_Nyy_sum_tl[tid] += N_res[2]; diag_Nxy_sum_tl[tid] += N_res[3]; diag_count_tl[tid] += 1
            if kg_diag_pid_enabled
                pid_int = something(tryparse(Int, pid), 0)
                if pid_int != 0
                    kg_pid_count_tl[tid][pid_int] = get(kg_pid_count_tl[tid], pid_int, 0) + 1
                    kg_pid_nxx_tl[tid][pid_int] = get(kg_pid_nxx_tl[tid], pid_int, 0.0) + N_res[1]
                    kg_pid_nyy_tl[tid][pid_int] = get(kg_pid_nyy_tl[tid], pid_int, 0.0) + N_res[2]
                    kg_pid_nxy_tl[tid][pid_int] = get(kg_pid_nxy_tl[tid], pid_int, 0.0) + N_res[3]
                end
            end
            if kg_diag_eid_enabled
                eid_int = shell_eids[_shell_ei]
                pid_int_e = something(tryparse(Int, pid), 0)
                nin_xx = 0.0
                nin_yy = 0.0
                nin_xy = 0.0
                nin_gp1_xx = 0.0; nin_gp1_yy = 0.0; nin_gp1_xy = 0.0
                nin_gp2_xx = 0.0; nin_gp2_yy = 0.0; nin_gp2_xy = 0.0
                nin_gp3_xx = 0.0; nin_gp3_yy = 0.0; nin_gp3_xy = 0.0
                nin_gp4_xx = 0.0; nin_gp4_yy = 0.0; nin_gp4_xy = 0.0
                if sigma_mem_input isa AbstractMatrix
                    ngp_in = size(sigma_mem_input, 1)
                    @inbounds for gp in 1:ngp_in
                        gxx = sigma_mem_input[gp, 1] * h
                        gyy = sigma_mem_input[gp, 2] * h
                        gxy = sigma_mem_input[gp, 3] * h
                        nin_xx += gxx
                        nin_yy += gyy
                        nin_xy += gxy
                        if gp == 1
                            nin_gp1_xx = gxx; nin_gp1_yy = gyy; nin_gp1_xy = gxy
                        elseif gp == 2
                            nin_gp2_xx = gxx; nin_gp2_yy = gyy; nin_gp2_xy = gxy
                        elseif gp == 3
                            nin_gp3_xx = gxx; nin_gp3_yy = gyy; nin_gp3_xy = gxy
                        elseif gp == 4
                            nin_gp4_xx = gxx; nin_gp4_yy = gyy; nin_gp4_xy = gxy
                        end
                    end
                    inv_ngp_in = 1.0 / max(ngp_in, 1)
                    nin_xx *= inv_ngp_in
                    nin_yy *= inv_ngp_in
                    nin_xy *= inv_ngp_in
                else
                    nin_xx = sigma_mem_input[1] * h
                    nin_yy = sigma_mem_input[2] * h
                    nin_xy = sigma_mem_input[3] * h
                    nin_gp1_xx = nin_xx; nin_gp1_yy = nin_yy; nin_gp1_xy = nin_xy
                    nin_gp2_xx = nin_xx; nin_gp2_yy = nin_yy; nin_gp2_xy = nin_xy
                    nin_gp3_xx = nin_xx; nin_gp3_yy = nin_yy; nin_gp3_xy = nin_xy
                    nin_gp4_xx = nin_xx; nin_gp4_yy = nin_yy; nin_gp4_xy = nin_xy
                end
                push!(kg_eid_rows_tl[tid], (
                    subcase=kg_diag_subcase,
                    eid=eid_int,
                    pid=pid_int_e,
                    stress_mode=stress_mode_label,
                    blend_alpha=gp_blend_override === nothing ? gp_blend_alpha : gp_blend_override,
                    nres_xx=N_res[1],
                    nres_yy=N_res[2],
                    nres_xy=N_res[3],
                    nin_xx=nin_xx,
                    nin_yy=nin_yy,
                    nin_xy=nin_xy,
                    nin_gp1_xx=nin_gp1_xx,
                    nin_gp1_yy=nin_gp1_yy,
                    nin_gp1_xy=nin_gp1_xy,
                    nin_gp2_xx=nin_gp2_xx,
                    nin_gp2_yy=nin_gp2_yy,
                    nin_gp2_xy=nin_gp2_xy,
                    nin_gp3_xx=nin_gp3_xx,
                    nin_gp3_yy=nin_gp3_yy,
                    nin_gp3_xy=nin_gp3_xy,
                    nin_gp4_xx=nin_gp4_xx,
                    nin_gp4_yy=nin_gp4_yy,
                    nin_gp4_xy=nin_gp4_xy,
                    kg_trans_mode=kg_trans_mode_diag,
                    kg_pcomp_normal_only=kg_pcomp_normal_only_diag,
                    kg_saddle=kg_saddle_diag,
                    elem_is_flat=elem_is_flat_kg,
                    aspect=aspect_ratio_kg,
                    warp_ratio=warp_ratio_kg,
                    geom_curvature_ok=geom_curvature_ok_diag,
                    geom_kappa_l=geom_kappa_l_diag,
                    geom_cyl_ratio=geom_cyl_ratio_diag,
                    geom_gaussian=geom_gaussian_diag,
                    is_pcomp=is_pcomp_clt,
                    pcomp_is_isotropic=pcomp_is_isotropic,
                    h_over_lmax=h_over_lmax_kg,
                    pcomp_pm45_fraction=pcomp_pm45_fraction_kg,
                    pcomp_pm90_fraction=pcomp_pm90_fraction_kg,
                    pcomp_ply_count=pcomp_ply_count_kg,
                    pcomp_nemeth_alpha=pcomp_nemeth_alpha_kg,
                    pcomp_nemeth_beta=pcomp_nemeth_beta_kg,
                    pcomp_nemeth_gamma=pcomp_nemeth_gamma_kg,
                    pcomp_nemeth_delta=pcomp_nemeth_delta_kg,
                ))
            end
            n_q4_done_tl[tid] += 1

            # Compute geometric stiffness in local coordinates unless an
            # experimental MATPRN-derived branch returns a basic-frame matrix.
            kg_global_ready = false
            kg_covariant_branch =
                kg_surface_operator_mode === :covariant && !snorm_completion_active_kg
            coords3d_buf4[1,1] = p1[1]; coords3d_buf4[1,2] = p1[2]; coords3d_buf4[1,3] = p1[3]
            coords3d_buf4[2,1] = p2[1]; coords3d_buf4[2,2] = p2[2]; coords3d_buf4[2,3] = p2[3]
            coords3d_buf4[3,1] = p3[1]; coords3d_buf4[3,2] = p3[2]; coords3d_buf4[3,3] = p3[3]
            coords3d_buf4[4,1] = p4[1]; coords3d_buf4[4,2] = p4[2]; coords3d_buf4[4,3] = p4[3]
            if kg_nastran_kdjj_iso_branch
                Kg_loc = FEM.geometric_stiffness_quad4_nastran_kdjj_iso(
                    lc_buf4, u_elem24, E_val, nu_val, h
                )
            elseif kg_nastran_kdjj_pcomp_branch
                # Feed the composite-KDJJ operator JFEM's recovered element
                # membrane resultant N_res (already in the lc = bisector frame).
                # The resultant broadcast to all 4 GPs is the offline-best field
                # (skew45 15.1% vs per-GP 21.2%); NO frame rotation, NO /h *h
                # round-trip -- N_res is already a resultant in the right frame.
                # 2026-07-17: with the SELC-consistent recovery
                # (kg_membrane_selc), the per-GP field no longer carries the
                # Wilson recovery noise that motivated the broadcast, and
                # gradient stress states NEED the per-GP variation (the
                # element-mean field is the iso load_uy/load_shear defect
                # class: +55%/-30% before the per-GP iso kernel).  Env
                # JFEM_SOL105_PCOMP_KDJJ_FIELD=res|gp (default gp when the
                # SELC recovery is active, else res).
                kdjj_field_raw = lowercase(strip(get(ENV, "JFEM_SOL105_PCOMP_KDJJ_FIELD", "")))
                kdjj_use_gp = kdjj_field_raw == "gp" ||
                              (isempty(kdjj_field_raw) && kg_membrane_selc)
                Ngp_kdjj = Matrix{Float64}(undef, 4, 3)
                if kdjj_use_gp
                    @inbounds for gp_i in 1:4, comp in 1:3
                        Ngp_kdjj[gp_i, comp] = N_gp[gp_i, comp]
                    end
                else
                    @inbounds for gp_i in 1:4, comp in 1:3
                        Ngp_kdjj[gp_i, comp] = N_res[comp]
                    end
                end
                Kg_loc = FEM.geometric_stiffness_quad4_nastran_kdjj_pcomp_field(
                    lc_buf4, Ngp_kdjj
                )
            elseif kg_flat_dkmq_branch
                Kg_loc = FEM.geometric_stiffness_quad4_plate_dkmq(
                    lc_buf4, sigma_mem_input, h, Cb_kg === nothing ? prop["Cb"] : Cb_kg, Cs_kg === nothing ? prop["Cs"] : Cs_kg
                )
            elseif flat_pcomp_rect_adini && kg_flat_plate_branch && FEM.quad4_is_axis_aligned_rectangle(lc_buf4)
                Kg_loc = FEM.geometric_stiffness_quad4_plate_adini(
                    lc_buf4, sigma_mem_input, h
                )
            elseif kg_flat_plate_branch
                Kg_loc = FEM.geometric_stiffness_quad4_plate_dkq(
                    lc_buf4, sigma_mem_input, h, Cb_kg, Cs_kg
                )
            elseif kg_covariant_branch
                coords3d_buf4[1,1] = p1[1]; coords3d_buf4[1,2] = p1[2]; coords3d_buf4[1,3] = p1[3]
                coords3d_buf4[2,1] = p2[1]; coords3d_buf4[2,2] = p2[2]; coords3d_buf4[2,3] = p2[3]
                coords3d_buf4[3,1] = p3[1]; coords3d_buf4[3,2] = p3[2]; coords3d_buf4[3,3] = p3[3]
                coords3d_buf4[4,1] = p4[1]; coords3d_buf4[4,2] = p4[2]; coords3d_buf4[4,3] = p4[3]
                covariant_principal_transverse =
                    solver_env_bool("JFEM_KG_COVARIANT_PRINCIPAL_TRANSVERSE", false)
                covariant_projection_raw =
                    lowercase(strip(get(ENV, "JFEM_KG_COVARIANT_TRANS_PROJECTION", "")))
                kg_trans_cov =
                    covariant_projection_raw in ("surface_normal", "normal_projector", "normal") ? :surface_normal :
                    covariant_projection_raw in ("surface_tangent", "tangent_projector", "tangent") ? :surface_tangent :
                    kg_trans_mode_eff === :normal_only ? :normal_only :
                    (covariant_principal_transverse &&
                     kg_trans_mode_eff === :principal_transverse) ? :principal_transverse :
                    :all
                Kg_loc = FEM.geometric_stiffness_quad4_covariant(
                    coords3d_buf4, sigma_mem_input, h, v1, v2;
                    trans_mode=kg_trans_cov,
                    principal_shear_yy_factor=principal_shear_yy_factor_eff,
                    principal_shear_xy_factor=principal_shear_xy_factor_eff,
                    principal_shear_z_factor=principal_shear_z_factor_eff,
                    principal_shear_ratio_min=principal_shear_ratio_min_eff,
                )
            else
                kg_membrane_shear_center_row =
                    flat_iso_eig_membrane_shear_center_row && elem_is_flat_kg && is_iso_kg
                Cm_kg =
                    if Cm_override === nothing
                        const_mem = E_val / (1 - nu_val^2)
                        (const_mem .* [1 nu_val 0; nu_val 1 0; 0 0 (1-nu_val)/2]) * h
                    else
                        Cm_override
                    end
                kg_consistent_membrane_incomp =
                    elem_membrane_incomp_kg &&
                    (is_pcomp_clt ? kg_pcomp_consistent_membrane_operator :
                                    kg_consistent_membrane_operator) &&
                    get(prop, "Bmb", nothing) === nothing &&
                    kg_trans_mode_eff !== :curvature
                kg_trans_mode_eff, _, _ =
                    q4_pcomp_kg_trans_mode_final(
                        kg_trans_mode_eff,
                        is_pcomp_clt,
                        pcomp_is_isotropic,
                        has_bmb_kg,
                        elem_is_flat_kg,
                        flat_pcomp_plate_like_kg,
                        nonflat_pcomp_normal_only_kg,
                        geom_curvature,
                    )
                principal_shear_geom_ok = kg_quad4_geometry_gate(
                    warp_ratio_kg,
                    aspect_ratio_kg,
                    kg_principal_shear_warp_min_v,
                    kg_principal_shear_warp_max_v,
                    kg_principal_shear_aspect_min_v,
                    kg_principal_shear_aspect_max_v,
                    kg_principal_shear_geom_mode_v,
                )
                principal_shear_yy_factor_eff = 1.0
                principal_shear_xy_factor_eff = 1.0
                principal_shear_z_factor_eff = 1.0
                principal_shear_ratio_min_eff = principal_shear_geom_ok ? kg_principal_shear_ratio_min_v : 1.0
                if principal_shear_geom_ok
                    principal_shear_yy_factor_eff = kg_quad4_pid_membrane_effective_scale(
                        kg_principal_shear_yy_factor_v,
                        kg_principal_shear_feature_gate_v,
                        sigma_mem_input,
                        h,
                        kg_principal_shear_gp_pmin_spread_min_v,
                        kg_principal_shear_gp_nxx_spread_min_v,
                        kg_principal_shear_gp_spread_factor_v,
                    )
                    principal_shear_xy_factor_eff = kg_quad4_pid_membrane_effective_scale(
                        kg_principal_shear_xy_factor_v,
                        kg_principal_shear_feature_gate_v,
                        sigma_mem_input,
                        h,
                        kg_principal_shear_gp_pmin_spread_min_v,
                        kg_principal_shear_gp_nxx_spread_min_v,
                        kg_principal_shear_gp_spread_factor_v,
                    )
                    principal_shear_z_factor_eff = kg_quad4_pid_membrane_effective_scale(
                        kg_principal_shear_z_factor_v,
                        kg_principal_shear_feature_gate_v,
                        sigma_mem_input,
                        h,
                        kg_principal_shear_gp_pmin_spread_min_v,
                        kg_principal_shear_gp_nxx_spread_min_v,
                        kg_principal_shear_gp_spread_factor_v,
                    )
                end
                Kg_loc = FEM.geometric_stiffness_quad4(
                    lc_buf4, sigma_mem_input, h;
                    trans_mode=kg_trans_mode_eff,
                    curvature=kg_curvature,
                    curvature_sign=kg_curvature_sign_eff,
                    membrane_shear_center_row=kg_membrane_shear_center_row,
                    Cm=Cm_kg,
                    membrane_incomp=kg_consistent_membrane_incomp && !kg_iso_exact_membrane,
                    membrane_enhanced=kg_iso_exact_membrane,
                    material_shear_rotation=kg_material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                    principal_shear_yy_factor=principal_shear_yy_factor_eff,
                    principal_shear_xy_factor=principal_shear_xy_factor_eff,
                    principal_shear_z_factor=principal_shear_z_factor_eff,
                    principal_shear_ratio_min=principal_shear_ratio_min_eff,
                )
            end

            # Keep SOL105 in the same physical coordinates as the elastic
            # matrix: form projected Kg, then the selected PARAM,SNORM map,
            # then W, and only afterwards scatter through the element frame.
            warp_map_for_snorm_kg =
                if snorm_pq_kg !== nothing &&
                   FEM.quad4_snorm_normal_moment_mode() &&
                   solver_env_bool("JFEM_Q4_WARP_TRANSFORM", true) &&
                   !elem_mitc4_3d_kg_recovery && !kg_covariant_branch
                    FEM.quad4_finite_warp_displacement_map(
                        lc_buf4, coords3d_local_buf4)
                else
                    nothing
                end
            if snorm_pq_kg !== nothing
                if FEM.quad4_snorm_normal_moment_mode()
                    snorm_relative_pq_kg =
                        FEM.quad4_snorm_relative_to_finite_warp_pq(
                            snorm_pq_kg, warp_map_for_snorm_kg)
                    snorm_relative_pq_kg === nothing ||
                        FEM.apply_quad4_snorm_normal_moment_completion!(
                            Kg_loc, lc_buf4, snorm_relative_pq_kg)
                else
                    FEM.apply_quad4_snorm_director_completion!(Kg_loc, snorm_pq_kg)
                end
            end
            if solver_env_bool("JFEM_Q4_WARP_TRANSFORM", true) &&
               !elem_mitc4_3d_kg_recovery && !kg_covariant_branch
                FEM.apply_quad4_finite_warp_equilibrium!(
                    Kg_loc, lc_buf4, coords3d_local_buf4)
            end

            # Transform to global: Kg_global = T' * Kg_loc * T
            if kg_global_ready
                @inbounds @fastmath for jj in 1:24, ii in 1:24
                    Kg_global[ii, jj] = Kg_loc[ii, jj]
                end
            else
                fill!(Kg_global, 0.0); fill!(tmp24a, 0.0)
                @inbounds @fastmath for jj in 1:24, ll in 1:24
                    val = T_buf[ll, jj]
                    if val != 0.0
                        for ii in 1:24; tmp24a[ii, jj] += Kg_loc[ii, ll] * val; end
                    end
                end
                @inbounds @fastmath for jj in 1:24, ll in 1:24
                    val = tmp24a[ll, jj]
                    if val != 0.0
                        for ii in 1:24; Kg_global[ii, jj] += T_buf[ll, ii] * val; end
                    end
                end
            end

            # Optional: zero the drilling-DOF rows/cols of Kg_global.
            # Matches Nastran's 5-DOF-per-node Kg convention (1976 theoretical
            # manual §5.6): CQUAD4 geometric stiffness is not formed on the
            # drilling direction of each node_R frame. Kg_loc already has zero
            # drill rows/cols in element-local coords, but the T_buf transform
            # into the node_R frame can mix rotational contributions from
            # local θx/θy into global θz per node. The gate below removes that
            # leakage when the formulation is not expected to carry any drill
            # contribution in Kg.
            if kg_shell_drill_zero
                @inbounds for k in 1:4
                    d = k*6
                    for r in 1:24; Kg_global[r, d] = 0.0; Kg_global[d, r] = 0.0; end
                end
            end

            # Map DOFs and accumulate triplets
            for k in 1:4
                idx = k == 1 ? i1 : k == 2 ? i2 : k == 3 ? i3 : i4
                b = (idx-1)*6
                for d in 1:6; dofs_buf24[(k-1)*6+d] = b+d; end
            end
            local _k = 0
            @inbounds for cc in 1:24, rr in 1:24
                _k += 1
                kg_slot_I[_kg_slot_base + _k] = dofs_buf24[rr]
                kg_slot_J[_kg_slot_base + _k] = dofs_buf24[cc]
                kg_slot_V[_kg_slot_base + _k] = Kg_global[rr, cc]
            end
            kg_slot_n[_shell_ei] = _k

        elseif n == 3
            # TRIA3 geometric stiffness
            i1 = id_vec[nids[1]]; i2 = id_vec[nids[2]]; i3 = id_vec[nids[3]]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])

            v1, v2, v3 = shell_element_frame_fast(p1, p2, p3, SVector{3}(0.0,0.0,0.0), 3)

            # SNORM adjustment
            n_avg = SVector(0.0, 0.0, 0.0); nc = 0
            for idx in (i1, i2, i3)
                if snorm_has[idx]; n_avg = n_avg + snorm_vec[idx]; nc += 1; end
            end
            if nc > 0
                n_avg_s = n_avg / nc; len_s = norm(n_avg_s)
                if len_s > 1e-12
                    v3n = SVector{3}(n_avg_s / len_s)
                    if dot(v3n, v3) < 0.0; v3n = -v3n; end
                    if !snorm_director && dot(v3n, v3) >= snorm_tilt_gate_cos  # DIAGNOSTIC gate (K/Kg-consistent)
                        v1p = v1 - dot(v1, v3n) * v3n; v1l = norm(v1p)
                        if v1l > 1e-12
                            v1n = SVector{3}(v1p / v1l)
                        else
                            v2p = v2 - dot(v2, v3n) * v3n; v1n = SVector{3}(normalize(v2p))
                        end
                        v1, v2, v3 = v1n, SVector{3}(cross(v3n, v1n)), v3n
                    end
                end
            end

            Rel_t = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]

            # Local coordinates
            c_ctr = (p1 + p2 + p3) / 3.0
            lc3 = zeros(3, 2)
            lc3[1,1] = dot(p1-c_ctr, v1); lc3[1,2] = dot(p1-c_ctr, v2)
            lc3[2,1] = dot(p2-c_ctr, v1); lc3[2,2] = dot(p2-c_ctr, v2)
            lc3[3,1] = dot(p3-c_ctr, v1); lc3[3,2] = dot(p3-c_ctr, v2)

            # Build T (18x18)
            T18 = zeros(18, 18)
            for k in 1:3
                idx = k == 1 ? i1 : k == 2 ? i2 : i3
                TR = Rel_t * node_R[idx]
                base = (k-1)*6
                T18[base+1:base+3, base+1:base+3] = TR
                T18[base+4:base+6, base+4:base+6] =
                    (snorm_director && snorm_has[idx]) ?
                    snorm_director_matrix(snorm_vec[idx], v1, v2, v3) * TR : TR
            end

            # Extract element displacements in local coords
            u_elem18 = zeros(18)
            for k in 1:3
                idx = k == 1 ? i1 : k == 2 ? i2 : i3
                b_g = (idx-1)*6; b_l = (k-1)*6
                for d in 1:6
                    for dd in 1:6; u_elem18[b_l+dd] += T18[b_l+dd, b_l+d] * u_global[b_g+d]; end
                end
            end

            E_val = get(mat, "E", 70000.0); nu_val = get(mat, "NU", 0.3)
            br = get(prop, "BEND_RATIO", 1.0)

            # Use the same shell material-axis definition here as in the main
            # shell formulation, including MCID support for composite CTRIA3.
            Cm_override_t3 = nothing
            if is_pcomp_clt
                Cm_override_t3 = copy(prop["Cm"])
                tri_kg_axis_mode =
                    kg_pcomp_axis_mode === :warp_switch ? :element : kg_pcomp_axis_mode
                beta_kg = shell_pcomp_material_rotation(
                    tri_kg_axis_mode,
                    v1, v2, v3, p1, p2,
                    deg2rad(Float64(get(el, "THETA", 0.0))),
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
                if abs(beta_kg) > 1e-10
                    cb = cos(beta_kg); sb = sin(beta_kg)
                    c2 = cb^2; s2 = sb^2; cs = cb*sb
                    _rotate_constitutive_3x3!(Cm_override_t3,
                        c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                end
            end

            N_res, _, _, _, _, _, _ = FEM.stress_strain_tria3(lc3, u_elem18, E_val, nu_val, h; bend_ratio=br, Cm_override=Cm_override_t3)
            if kg_diag_pid_enabled
                pid_int = something(tryparse(Int, pid), 0)
                if pid_int != 0
                    kg_pid_count_tl[tid][pid_int] = get(kg_pid_count_tl[tid], pid_int, 0) + 1
                    kg_pid_nxx_tl[tid][pid_int] = get(kg_pid_nxx_tl[tid], pid_int, 0.0) + N_res[1]
                    kg_pid_nyy_tl[tid][pid_int] = get(kg_pid_nyy_tl[tid], pid_int, 0.0) + N_res[2]
                    kg_pid_nxy_tl[tid][pid_int] = get(kg_pid_nxy_tl[tid], pid_int, 0.0) + N_res[3]
                end
            end
            sigma_mem = N_res ./ h
            if is_pcomp_clt
                kg_shell_apply_pcomp_nxy_scale!(
                    sigma_mem,
                    kg_shell_pcomp_nxy,
                    kg_shell_pcomp_nxy_compression_only_v,
                )
            end

            Kg_loc = FEM.geometric_stiffness_tria3(
                lc3, sigma_mem, h;
                trans_mode=kg_trans_mode,
                curvature=nothing,
                curvature_sign=kg_curvature_sign,
            )
            Kg18 = T18' * Kg_loc * T18

            # Optional drill-DOF zero (see QUAD4 branch for rationale).
            if kg_shell_drill_zero
                @inbounds for k in 1:3
                    d = k*6
                    for r in 1:18; Kg18[r, d] = 0.0; Kg18[d, r] = 0.0; end
                end
            end

            dofs_t3 = Vector{Int}(undef, 18)
            for k in 1:3
                idx = k == 1 ? i1 : k == 2 ? i2 : i3
                b = (idx-1)*6
                for d in 1:6; dofs_t3[(k-1)*6+d] = b+d; end
            end
            local _k = 0
            @inbounds for cc in 1:18, rr in 1:18
                _k += 1
                kg_slot_I[_kg_slot_base + _k] = dofs_t3[rr]
                kg_slot_J[_kg_slot_base + _k] = dofs_t3[cc]
                kg_slot_V[_kg_slot_base + _k] = Kg18[rr, cc]
            end
            kg_slot_n[_shell_ei] = _k
        end
        end  # let
    end  # Threads.@threads :static for _shell_ei

    # Restore BLAS threads so downstream Cholesky / Krylov can use all cores.
    LinearAlgebra.BLAS.set_num_threads(_prev_blas_threads_kg)

    # Compact the positional slots into the master triplet arrays in ELEMENT
    # order — schedule- and thread-count-independent by construction.
    total_kg_nz = sum(kg_slot_n)
    _kg_off = length(I_idx)
    resize!(I_idx, _kg_off + total_kg_nz)
    resize!(J_idx, _kg_off + total_kg_nz)
    resize!(V_val, _kg_off + total_kg_nz)
    @inbounds for ei in 1:length(shell_list)
        base = (ei - 1) * 576
        for k in 1:kg_slot_n[ei]
            _kg_off += 1
            I_idx[_kg_off] = kg_slot_I[base + k]
            J_idx[_kg_off] = kg_slot_J[base + k]
            V_val[_kg_off] = kg_slot_V[base + k]
        end
    end
    kg_slot_I = nothing; kg_slot_J = nothing; kg_slot_V = nothing

    # Reduce thread-local scalar counters.
    n_q4_done    = sum(n_q4_done_tl)
    diag_Nxx_sum = sum(diag_Nxx_sum_tl)
    diag_Nyy_sum = sum(diag_Nyy_sum_tl)
    diag_Nxy_sum = sum(diag_Nxy_sum_tl)
    diag_count   = sum(diag_count_tl)

    log_msg("[SOLVER] Kg shells: $n_q4 QUAD4 + $n_t3 TRIA3")
    if diag_count > 0
        log_msg("[SOLVER] Kg Q4 avg membrane forces: Nxx=$(round(diag_Nxx_sum/diag_count, digits=4)), Nyy=$(round(diag_Nyy_sum/diag_count, digits=4)), Nxy=$(round(diag_Nxy_sum/diag_count, digits=4))")
    end
    if kg_diag_pid_enabled
        pid_count = Dict{Int,Int}()
        pid_nxx = Dict{Int,Float64}()
        pid_nyy = Dict{Int,Float64}()
        pid_nxy = Dict{Int,Float64}()
        for t in 1:nt_kg
            for (pid, count) in kg_pid_count_tl[t]
                pid_count[pid] = get(pid_count, pid, 0) + count
            end
            for (pid, val) in kg_pid_nxx_tl[t]
                pid_nxx[pid] = get(pid_nxx, pid, 0.0) + val
            end
            for (pid, val) in kg_pid_nyy_tl[t]
                pid_nyy[pid] = get(pid_nyy, pid, 0.0) + val
            end
            for (pid, val) in kg_pid_nxy_tl[t]
                pid_nxy[pid] = get(pid_nxy, pid, 0.0) + val
            end
        end
        rows = NamedTuple{(:pid,:count,:nxx,:nyy,:nxy,:pmin,:pmax),Tuple{Int,Int,Float64,Float64,Float64,Float64,Float64}}[]
        for (pid, count) in pid_count
            count <= 0 && continue
            nxx = get(pid_nxx, pid, 0.0) / count
            nyy = get(pid_nyy, pid, 0.0) / count
            nxy = get(pid_nxy, pid, 0.0) / count
            mean_n = 0.5 * (nxx + nyy)
            half_d = 0.5 * (nxx - nyy)
            radius = sqrt(half_d * half_d + nxy * nxy)
            push!(rows, (pid=pid, count=count, nxx=nxx, nyy=nyy, nxy=nxy,
                         pmin=mean_n - radius, pmax=mean_n + radius))
        end
        sort!(rows; by=r -> r.pmin)
        nshow = min(12, length(rows))
        if nshow > 0
            txt = join([string(r.pid, "(n=", r.count,
                               ",pmin=", round(r.pmin; sigdigits=4),
                               ",pmax=", round(r.pmax; sigdigits=4),
                               ",Nxx=", round(r.nxx; sigdigits=4),
                               ",Nyy=", round(r.nyy; sigdigits=4),
                               ",Nxy=", round(r.nxy; sigdigits=4), ")")
                        for r in rows[1:nshow]], "; ")
            log_msg("[SOLVER] Kg PID most-compressive membrane forces: $txt")
        end
    end
    if kg_diag_eid_enabled
        all_rows = NamedTuple[]
        for t in 1:nt_kg
            append!(all_rows, kg_eid_rows_tl[t])
        end
        sort!(all_rows; by = r -> (r.subcase, r.eid))
        try
            write_header = !isfile(kg_diag_eid_csv_path) || filesize(kg_diag_eid_csv_path) == 0
            open(kg_diag_eid_csv_path, write_header ? "w" : "a") do io
                if write_header
                    println(io, "subcase,eid,pid,stress_mode,blend_alpha,nres_xx,nres_yy,nres_xy,nin_xx,nin_yy,nin_xy,nin_gp1_xx,nin_gp1_yy,nin_gp1_xy,nin_gp2_xx,nin_gp2_yy,nin_gp2_xy,nin_gp3_xx,nin_gp3_yy,nin_gp3_xy,nin_gp4_xx,nin_gp4_yy,nin_gp4_xy,kg_trans_mode,kg_pcomp_normal_only,kg_saddle,elem_is_flat,aspect,warp_ratio,geom_curvature_ok,geom_kappa_l,geom_cyl_ratio,geom_gaussian,is_pcomp,pcomp_is_isotropic,h_over_lmax,pcomp_pm45_fraction,pcomp_pm90_fraction,pcomp_ply_count,pcomp_nemeth_alpha,pcomp_nemeth_beta,pcomp_nemeth_gamma,pcomp_nemeth_delta")
                end
                for r in all_rows
                    println(io, r.subcase, ",", r.eid, ",", r.pid, ",", r.stress_mode, ",", r.blend_alpha, ",",
                            r.nres_xx, ",", r.nres_yy, ",", r.nres_xy, ",",
                            r.nin_xx, ",", r.nin_yy, ",", r.nin_xy, ",",
                            r.nin_gp1_xx, ",", r.nin_gp1_yy, ",", r.nin_gp1_xy, ",",
                            r.nin_gp2_xx, ",", r.nin_gp2_yy, ",", r.nin_gp2_xy, ",",
                            r.nin_gp3_xx, ",", r.nin_gp3_yy, ",", r.nin_gp3_xy, ",",
                            r.nin_gp4_xx, ",", r.nin_gp4_yy, ",", r.nin_gp4_xy, ",",
                            r.kg_trans_mode, ",", r.kg_pcomp_normal_only, ",", r.kg_saddle, ",",
                            r.elem_is_flat, ",", r.aspect, ",", r.warp_ratio, ",",
                            r.geom_curvature_ok, ",", r.geom_kappa_l, ",", r.geom_cyl_ratio, ",",
                            r.geom_gaussian, ",", r.is_pcomp, ",", r.pcomp_is_isotropic, ",",
                            r.h_over_lmax, ",", r.pcomp_pm45_fraction, ",",
                            r.pcomp_pm90_fraction, ",", r.pcomp_ply_count, ",",
                            r.pcomp_nemeth_alpha, ",", r.pcomp_nemeth_beta, ",",
                            r.pcomp_nemeth_gamma, ",", r.pcomp_nemeth_delta)
                end
            end
            log_msg("[SOLVER] Kg per-EID σ dump: $(length(all_rows)) rows → $kg_diag_eid_csv_path")
        catch e
            log_msg("[SOLVER] WARNING: failed to write JFEM_KG_DIAG_EID_CSV → $kg_diag_eid_csv_path: $e")
        end
    end

    kg_timings["shells"] = (time_ns() - kg_t_shells) * 1e-9

    # --- CBAR geometric stiffness ---
    kg_t_bars = time_ns()
    n_bars = 0
    T12 = zeros(12, 12)
    for (id, bar) in cbars
        pid = string(bar["PID"])
        if !haskey(pbarls, pid); continue; end
        prop = pbarls[pid]; mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)
        if norm(v_ref) < 1e-6
            v_ref = SVector(0.0,0.0,1.0)
            if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel = vcat(vx', vy', vz')

        fill!(T12, 0.0)
        TR1 = Rel * node_R[i1]; TR2 = Rel * node_R[i2]
        T12[1:3, 1:3] = TR1; T12[4:6, 4:6] = TR1
        T12[7:9, 7:9] = TR2; T12[10:12, 10:12] = TR2
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            T12[1:3, 4:6] = -Rel * S_wa * node_R[i1]
            T12[7:9, 10:12] = -Rel * S_wb * node_R[i2]
        end

        b1 = (i1-1)*6; b2 = (i2-1)*6
        u_elem = @views vcat(u_global[(b1+1):(b1+6)], u_global[(b2+1):(b2+6)])
        u_bar = T12 * u_elem

        # Compute axial force
        Iy, Iz = _bar_bending_inertias(prop)
        Iyz = Float64(get(prop, "I12", 0.0))
        K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
        As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
        As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
        forces = FEM.forces_frame3d(u_bar, L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
        P = forces["axial"]  # Axial force (positive = tension)
        Kg_loc = FEM.geometric_stiffness_frame3d(L, P)
        Kg_bar = T12' * Kg_loc * T12

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Kg_bar[r,c])
        end
        n_bars += 1
    end

    # --- CBEAM geometric stiffness (identical to CBAR) ---
    n_beams = 0
    for (id, bar) in cbeams
        pid = string(bar["PID"])
        if !haskey(pbarls, pid); continue; end
        prop = pbarls[pid]; mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)
        if norm(v_ref) < 1e-6
            v_ref = SVector(0.0,0.0,1.0)
            if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel = vcat(vx', vy', vz')

        fill!(T12, 0.0)
        TR1 = Rel * node_R[i1]; TR2 = Rel * node_R[i2]
        T12[1:3, 1:3] = TR1; T12[4:6, 4:6] = TR1
        T12[7:9, 7:9] = TR2; T12[10:12, 10:12] = TR2
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            T12[1:3, 4:6] = -Rel * S_wa * node_R[i1]
            T12[7:9, 10:12] = -Rel * S_wb * node_R[i2]
        end

        b1 = (i1-1)*6; b2 = (i2-1)*6
        u_elem = @views vcat(u_global[(b1+1):(b1+6)], u_global[(b2+1):(b2+6)])
        u_bar = T12 * u_elem

        Iy, Iz = _bar_bending_inertias(prop)
        Iyz = Float64(get(prop, "I12", 0.0))
        K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
        As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
        As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
        forces = FEM.forces_frame3d(u_bar, L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
        P = forces["axial"]
        Kg_loc = FEM.geometric_stiffness_frame3d(L, P)
        Kg_bar = T12' * Kg_loc * T12

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Kg_bar[r,c])
        end
        n_beams += 1
    end
    if n_bars + n_beams > 0
        log_msg("[SOLVER] Kg bars: $n_bars CBAR + $n_beams CBEAM")
    end
    kg_timings["bars_beams"] = (time_ns() - kg_t_bars) * 1e-9

    # --- CROD geometric stiffness ---
    kg_t_rods = time_ns()
    prods = get(model, "PRODs", Dict())
    n_rods = 0
    for (id, rod) in crods
        pid = string(rod["PID"])
        if !haskey(prods, pid); continue; end
        prop = prods[pid]; mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])

        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)
        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref)); vy = cross(vz, vx)
        Rel = vcat(vx', vy', vz')

        fill!(T12, 0.0)
        TR1 = Rel * node_R[i1]; TR2 = Rel * node_R[i2]
        T12[1:3, 1:3] = TR1; T12[4:6, 4:6] = TR1
        T12[7:9, 7:9] = TR2; T12[10:12, 10:12] = TR2

        # Axial force P = E*A/L * (u2_x - u1_x) in local coords
        u_rod = zeros(12)
        b1 = (i1-1)*6; b2 = (i2-1)*6
        for d in 1:6
            for dd in 1:6
                u_rod[dd] += T12[dd, d] * u_global[b1+d]
                u_rod[6+dd] += T12[6+dd, 6+d] * u_global[b2+d]
            end
        end
        P = mat["E"] * prop["A"] / L * (u_rod[7] - u_rod[1])

        Kg_loc = FEM.geometric_stiffness_rod(L, P)
        Kg_rod = T12' * Kg_loc * T12

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Kg_rod[r,c])
        end
        n_rods += 1
    end

    # --- CONROD geometric stiffness ---
    n_conrods = 0
    for (id, rod) in conrods
        mid = string(rod["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])
        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)
        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref)); vy = cross(vz, vx)
        Rel = vcat(vx', vy', vz')

        fill!(T12, 0.0)
        TR1 = Rel * node_R[i1]; TR2 = Rel * node_R[i2]
        T12[1:3, 1:3] = TR1; T12[4:6, 4:6] = TR1
        T12[7:9, 7:9] = TR2; T12[10:12, 10:12] = TR2

        u_rod = zeros(12)
        b1 = (i1-1)*6; b2 = (i2-1)*6
        for d in 1:6
            for dd in 1:6
                u_rod[dd] += T12[dd, d] * u_global[b1+d]
                u_rod[6+dd] += T12[6+dd, 6+d] * u_global[b2+d]
            end
        end
        P = mat["E"] * rod["A"] / L * (u_rod[7] - u_rod[1])

        Kg_loc = FEM.geometric_stiffness_rod(L, P)
        Kg_rod = T12' * Kg_loc * T12

        dofs = [(i1-1)*6+k for k in 1:6]
        append!(dofs, [(i2-1)*6+k for k in 1:6])
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r]); push!(J_idx, dofs[c]); push!(V_val, Kg_rod[r,c])
        end
        n_conrods += 1
    end
    if n_rods + n_conrods > 0
        log_msg("[SOLVER] Kg rods: $n_rods CROD + $n_conrods CONROD")
    end
    kg_timings["rods"] = (time_ns() - kg_t_rods) * 1e-9

    # --- SOLID geometric stiffness ---
    kg_t_solids = time_ns()
    csolids_kg = get(model, "CSOLIDs", Dict())
    psolids_kg = get(model, "PSOLIDs", Dict())
    n_tetra_kg = 0; n_hexa_kg = 0; n_penta_kg = 0
    coords_buf_kg = zeros(8, 3)
    T_buf_kg = zeros(24, 24)
    for (id, el) in csolids_kg
        pid = string(el["PID"])
        if !haskey(psolids_kg, pid); continue; end
        prop = psolids_kg[pid]; mid = string(prop["MID"])
        nids = el["NODES"]; nn = length(nids)
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, nids)
        etype = get(el, "TYPE", "")

        valid = true
        for k in 1:nn
            if !haskey(id_map, nids[k]); valid = false; break; end
        end
        if !valid; continue; end

        for k in 1:nn
            idx = id_map[nids[k]]
            coords_buf_kg[k,1] = node_coords[idx,1]
            coords_buf_kg[k,2] = node_coords[idx,2]
            coords_buf_kg[k,3] = node_coords[idx,3]
        end

        E_mat = Float64(mat["E"]); nu_mat = Float64(mat["NU"])
        D = FEM.iso_3d_constitutive(E_mat, nu_mat)

        # Recover centroid stress from static displacement u_global
        local ndof_el::Int
        local B_cen
        if etype == "CTETRA" && nn == 4
            B_cen = FEM.solid_centroid_B_tetra4(view(coords_buf_kg, 1:4, :)); ndof_el = 12
        elseif etype == "CHEXA" && nn == 8
            B_cen = FEM.solid_centroid_B_hexa8(view(coords_buf_kg, 1:8, :)); ndof_el = 24
        elseif etype == "CPENTA" && nn == 6
            B_cen = FEM.solid_centroid_B_cpenta6(view(coords_buf_kg, 1:6, :)); ndof_el = 18
        else
            continue
        end

        # Extract element displacements (translational DOFs, global frame)
        u_el = zeros(ndof_el)
        for k in 1:nn
            idx = id_map[nids[k]]
            u_loc = u_global[(idx-1)*6+1:(idx-1)*6+3]
            u_el[(k-1)*3+1:(k-1)*3+3] = node_R[idx] * u_loc
        end

        stress_vec = D * (B_cen * u_el)

        local Kg_loc
        if etype == "CTETRA"
            Kg_loc = FEM.geometric_stiffness_tetra4(view(coords_buf_kg, 1:4, :), stress_vec)
            n_tetra_kg += 1
        elseif etype == "CHEXA"
            Kg_loc = FEM.geometric_stiffness_hexa8(view(coords_buf_kg, 1:8, :), stress_vec)
            n_hexa_kg += 1
        else
            Kg_loc = FEM.geometric_stiffness_cpenta6(view(coords_buf_kg, 1:6, :), stress_vec)
            n_penta_kg += 1
        end

        # Transform by node_R
        fill!(view(T_buf_kg, 1:ndof_el, 1:ndof_el), 0.0)
        for k in 1:nn
            idx = id_map[nids[k]]; r = (k-1)*3
            for a in 1:3, b in 1:3; T_buf_kg[r+a, r+b] = node_R[idx][a,b]; end
        end
        T_sub = view(T_buf_kg, 1:ndof_el, 1:ndof_el)
        Kg_el = T_sub' * Kg_loc * T_sub

        dofs_solid = Vector{Int}(undef, ndof_el)
        for k in 1:nn
            idx = id_map[nids[k]]; base = (idx-1)*6
            dofs_solid[(k-1)*3+1] = base+1; dofs_solid[(k-1)*3+2] = base+2; dofs_solid[(k-1)*3+3] = base+3
        end
        for c in 1:ndof_el, r in 1:ndof_el
            push!(I_idx, dofs_solid[r]); push!(J_idx, dofs_solid[c]); push!(V_val, Kg_el[r,c])
        end
    end
    n_solids_kg = n_tetra_kg + n_hexa_kg + n_penta_kg
    if n_solids_kg > 0
        log_msg("[SOLVER] Kg solids: $n_tetra_kg CTETRA + $n_hexa_kg CHEXA + $n_penta_kg CPENTA")
    end
    kg_timings["solids"] = (time_ns() - kg_t_solids) * 1e-9

    # --- Constraint redistribution (same as for K) ---
    # The K assembly's merged dependency map arrives as the rbe3_map
    # argument; pass it through so the full RBE/MPC map (incl. per-RBE3
    # pinv solves) is not rebuilt per Kg call. Empty maps are not trusted
    # by the callee and trigger the full build exactly as before.
    kg_t_constraints = time_ns()
    _, I_idx, J_idx, V_val = assemble_constraints(model, id_map, node_coords, node_R, I_idx, J_idx, V_val;
                                                  prebuilt_map=rbe3_map)
    kg_timings["constraint_redistribution"] = (time_ns() - kg_t_constraints) * 1e-9

    kg_t_sparse = time_ns()
    log_msg("[SOLVER] Creating Sparse Kg (NZ: $(length(I_idx)))...")
    Kg = _sparse_from_triplets_cached(I_idx, J_idx, V_val, ndof, csc_cache)
    kg_timings["sparse_build"] = (time_ns() - kg_t_sparse) * 1e-9
    kg_timings["total"] = (time_ns() - kg_t_total) * 1e-9

    if timings !== nothing
        empty!(timings)
        for (k, v) in kg_timings
            timings[string(k)] = v
        end
    end
    FEM.env_snapshot_end!()
    return Kg
end
