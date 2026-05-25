# experimental/mitc4_3d_kernel.jl
#
# MITC4-3D degenerate-solid Q4 development kernel family. RESEARCH only —
# never default-on. Reached only via JFEM_Q4_KERNEL=mitc4_3d (or _all variants).
# Memory: [[mitc4-3d-rule-out]] — VTP_3wp_strain regresses -35% if forced
# default, so this entire block is gated off by default.
#
# Moved out of FEMKernels.jl 2026-05-25 as part of architectural cleanup
# (phase C2/D1 — quarantine research kernels out of the production hot
# path). Loaded via `include("experimental/mitc4_3d_kernel.jl")` at the
# spot where the functions used to live.

@inline function _mitc4_3d_node_vec(mat::AbstractMatrix, a::Int)
    return SVector{3,Float64}(mat[a,1], mat[a,2], mat[a,3])
end

@inline function _mitc4_3d_jacobian(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
    zeta::Float64,
)
    N = shape_values_quad(xi, eta)
    dNr, dNs = shape_derivs_quad(xi, eta)
    half_h = 0.5*h
    g_r = SVector(0.0, 0.0, 0.0)
    g_s = SVector(0.0, 0.0, 0.0)
    g_z = SVector(0.0, 0.0, 0.0)
    @inbounds for a in 1:4
        x_a = _mitc4_3d_node_vec(coords3d, a)
        n_a = _mitc4_3d_node_vec(directors, a)
        fiber_a = x_a + (zeta*half_h)*n_a
        g_r += dNr[a] * fiber_a
        g_s += dNs[a] * fiber_a
        g_z += (N[a]*half_h) * n_a
    end
    detJ = dot(g_r, cross(g_s, g_z))
    return N, dNr, dNs, g_r, g_s, g_z, detJ
end

@inline function _mitc4_3d_contravariant(
    g_r::SVector{3,Float64},
    g_s::SVector{3,Float64},
    g_z::SVector{3,Float64},
    detJ::Float64,
)
    det_safe = abs(detJ) < 1e-14 ? (detJ < 0.0 ? -1e-14 : 1e-14) : detJ
    gr = cross(g_s, g_z) / det_safe
    gs = cross(g_z, g_r) / det_safe
    gz = cross(g_r, g_s) / det_safe
    return gr, gs, gz, det_safe
end

@inline function _mitc4_3d_grad_from_natural(
    u_r::SVector{3,Float64},
    u_s::SVector{3,Float64},
    u_z::SVector{3,Float64},
    gr::SVector{3,Float64},
    gs::SVector{3,Float64},
    gz::SVector{3,Float64},
)
    return SMatrix{3,3,Float64,9}(
        u_r[1]*gr[1] + u_s[1]*gs[1] + u_z[1]*gz[1],
        u_r[2]*gr[1] + u_s[2]*gs[1] + u_z[2]*gz[1],
        u_r[3]*gr[1] + u_s[3]*gs[1] + u_z[3]*gz[1],
        u_r[1]*gr[2] + u_s[1]*gs[2] + u_z[1]*gz[2],
        u_r[2]*gr[2] + u_s[2]*gs[2] + u_z[2]*gz[2],
        u_r[3]*gr[2] + u_s[3]*gs[2] + u_z[3]*gz[2],
        u_r[1]*gr[3] + u_s[1]*gs[3] + u_z[1]*gz[3],
        u_r[2]*gr[3] + u_s[2]*gs[3] + u_z[2]*gz[3],
        u_r[3]*gr[3] + u_s[3]*gs[3] + u_z[3]*gz[3],
    )
end

"""
    quad4_mitc4_3d_B_displacement(coords3d, directors, h, xi, eta, zeta)

Build the displacement-based 3D small-strain B matrix for the opt-in
degenerate-3D MITC4 development path. Inputs are already in one Cartesian frame
(normally the element-local frame). The returned rows are
`[eps_xx, eps_yy, eps_zz, gamma_xy, gamma_yz, gamma_xz]`.

This helper is intentionally not wired into default assembly yet; it is the
Phase-1 flat-reduction scaffold for `JFEM_Q4_KERNEL=mitc4_3d`.
"""
function quad4_mitc4_3d_B_displacement(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
    zeta::Float64,
)
    B = zeros(6, 24)
    N, dNr, dNs, g_r, g_s, g_z, detJ = _mitc4_3d_jacobian(coords3d, directors, h, xi, eta, zeta)
    gr, gs, gz, det_safe = _mitc4_3d_contravariant(g_r, g_s, g_z, detJ)
    half_h_zeta = 0.5*h*zeta
    half_h = 0.5*h
    e = (SVector(1.0,0.0,0.0), SVector(0.0,1.0,0.0), SVector(0.0,0.0,1.0))

    @inbounds for a in 1:4
        n_a = _mitc4_3d_node_vec(directors, a)
        base = (a-1)*6
        for d in 1:3
            ed = e[d]
            grad_u = _mitc4_3d_grad_from_natural(dNr[a]*ed, dNs[a]*ed, SVector(0.0,0.0,0.0), gr, gs, gz)
            col = base + d
            B[1,col] = grad_u[1,1]
            B[2,col] = grad_u[2,2]
            B[3,col] = grad_u[3,3]
            B[4,col] = grad_u[1,2] + grad_u[2,1]
            B[5,col] = grad_u[2,3] + grad_u[3,2]
            B[6,col] = grad_u[1,3] + grad_u[3,1]
        end
        for d in 1:3
            rvec = cross(e[d], n_a)
            grad_u = _mitc4_3d_grad_from_natural(
                (dNr[a]*half_h_zeta)*rvec,
                (dNs[a]*half_h_zeta)*rvec,
                (N[a]*half_h)*rvec,
                gr, gs, gz,
            )
            col = base + 3 + d
            B[1,col] = grad_u[1,1]
            B[2,col] = grad_u[2,2]
            B[3,col] = grad_u[3,3]
            B[4,col] = grad_u[1,2] + grad_u[2,1]
            B[5,col] = grad_u[2,3] + grad_u[3,2]
            B[6,col] = grad_u[1,3] + grad_u[3,1]
        end
    end
    return B, det_safe
end

@inline function _mitc4_3d_shear_row_at!(
    row::AbstractVector,
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
    zeta::Float64,
    component::Int,
)
    fill!(row, 0.0)
    N, dNr, dNs, g_r, g_s, g_z, detJ = _mitc4_3d_jacobian(coords3d, directors, h, xi, eta, zeta)
    half_h_zeta = 0.5*h*zeta
    half_h = 0.5*h
    e = (SVector(1.0,0.0,0.0), SVector(0.0,1.0,0.0), SVector(0.0,0.0,1.0))
    @inbounds for a in 1:4
        n_a = _mitc4_3d_node_vec(directors, a)
        base = (a-1)*6
        for d in 1:3
            ed = e[d]
            val = component == 1 ? dot(dNr[a]*ed, g_z) : dot(dNs[a]*ed, g_z)
            row[base+d] = val
        end
        for d in 1:3
            rvec = cross(e[d], n_a)
            u_nat = component == 1 ? (dNr[a]*half_h_zeta)*rvec : (dNs[a]*half_h_zeta)*rvec
            u_zeta = (N[a]*half_h)*rvec
            val = component == 1 ? dot(u_nat, g_z) + dot(u_zeta, g_r) :
                                   dot(u_nat, g_z) + dot(u_zeta, g_s)
            row[base+3+d] = val
        end
    end
    return row
end

"""
    quad4_mitc4_3d_shear_tying_rows(coords3d, directors, h, xi, eta; zeta=0.0)

Return the 2x24 MITC4 covariant transverse-shear tying rows at `(xi, eta)`.
Rows are `[gamma_rzeta, gamma_szeta]` before Cartesian shear transformation.
"""
function quad4_mitc4_3d_shear_tying_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64;
    zeta::Float64=0.0,
)
    Bs_tp = zeros(4, 24)
    row = zeros(24)
    tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
    _mitc4_3d_shear_row_at!(row, coords3d, directors, h, tying_pts[1][1], tying_pts[1][2], zeta, 1)
    @views copyto!(Bs_tp[1, :], row)
    _mitc4_3d_shear_row_at!(row, coords3d, directors, h, tying_pts[2][1], tying_pts[2][2], zeta, 1)
    @views copyto!(Bs_tp[2, :], row)
    _mitc4_3d_shear_row_at!(row, coords3d, directors, h, tying_pts[3][1], tying_pts[3][2], zeta, 2)
    @views copyto!(Bs_tp[3, :], row)
    _mitc4_3d_shear_row_at!(row, coords3d, directors, h, tying_pts[4][1], tying_pts[4][2], zeta, 2)
    @views copyto!(Bs_tp[4, :], row)

    Bs = zeros(2, 24)
    w_eta_m = 0.5*(1.0-eta)
    w_eta_p = 0.5*(1.0+eta)
    w_xi_m = 0.5*(1.0-xi)
    w_xi_p = 0.5*(1.0+xi)
    @inbounds for j in 1:24
        Bs[1,j] = w_eta_m*Bs_tp[1,j] + w_eta_p*Bs_tp[2,j]
        Bs[2,j] = w_xi_m*Bs_tp[3,j] + w_xi_p*Bs_tp[4,j]
    end
    return Bs
end

function quad4_mitc4_3d_physical_shear_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
    Bs_tp = zeros(4, 24)
    B, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, tying_pts[1][1], tying_pts[1][2], 0.0)
    @views copyto!(Bs_tp[1, :], B[6, :]) # gamma_xz at A
    B, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, tying_pts[2][1], tying_pts[2][2], 0.0)
    @views copyto!(Bs_tp[2, :], B[6, :]) # gamma_xz at B
    B, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, tying_pts[3][1], tying_pts[3][2], 0.0)
    @views copyto!(Bs_tp[3, :], B[5, :]) # gamma_yz at C
    B, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, tying_pts[4][1], tying_pts[4][2], 0.0)
    @views copyto!(Bs_tp[4, :], B[5, :]) # gamma_yz at D

    Bs = zeros(2, 24)
    w_eta_m = 0.5*(1.0-eta)
    w_eta_p = 0.5*(1.0+eta)
    w_xi_m = 0.5*(1.0-xi)
    w_xi_p = 0.5*(1.0+xi)
    @inbounds for j in 1:24
        Bs[1,j] = w_eta_m*Bs_tp[1,j] + w_eta_p*Bs_tp[2,j]
        Bs[2,j] = w_xi_m*Bs_tp[3,j] + w_xi_p*Bs_tp[4,j]
    end
    return Bs
end

function quad4_mitc4_3d_covariant_physical_shear_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    Bs_cov = quad4_mitc4_3d_shear_tying_rows(coords3d, directors, h, xi, eta)
    _, _, _, _, ar, as = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
    t1, t2 = _mitc4_3d_tangent_basis(coords3d, directors, h, xi, eta)
    c1r = dot(ar, t1)
    c1s = dot(as, t1)
    c2r = dot(ar, t2)
    c2s = dot(as, t2)
    scale = 2.0 / max(h, 1e-30)
    Bs = zeros(2, 24)
    @inbounds for j in 1:24
        Bs[1,j] = scale * (c1r*Bs_cov[1,j] + c1s*Bs_cov[2,j])
        Bs[2,j] = scale * (c2r*Bs_cov[1,j] + c2s*Bs_cov[2,j])
    end
    return Bs
end

function quad4_mitc4_3d_covariant_flatdirector_shear_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    _, _, _, g_r, g_s, _, _ = _mitc4_3d_jacobian(coords3d, directors, h, 0.0, 0.0, 0.0)
    n_raw = cross(g_r, g_s)
    n_len = norm(n_raw)
    n = n_len > 1e-30 ? n_raw / n_len : SVector(0.0, 0.0, 1.0)
    flat_dirs = zeros(4, 3)
    @inbounds for a in 1:4
        flat_dirs[a, 1] = n[1]
        flat_dirs[a, 2] = n[2]
        flat_dirs[a, 3] = n[3]
    end
    return quad4_mitc4_3d_covariant_physical_shear_rows(coords3d, flat_dirs, h, xi, eta)
end

@inline function quad4_mitc4_3d_selected_shear_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    mode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_SHEAR_MODE", "covariant")))
    if mode in ("physical", "cartesian", "direct")
        return quad4_mitc4_3d_physical_shear_rows(coords3d, directors, h, xi, eta)
    elseif mode in ("flatdirector", "flat-director", "midnormal", "constant_director")
        return quad4_mitc4_3d_covariant_flatdirector_shear_rows(coords3d, directors, h, xi, eta)
    end
    return quad4_mitc4_3d_covariant_physical_shear_rows(coords3d, directors, h, xi, eta)
end

@inline function _mitc4_3d_surface_area_and_grads(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    N, dNr, dNs, g_r, g_s, _, _ = _mitc4_3d_jacobian(coords3d, directors, h, xi, eta, 0.0)
    g11 = dot(g_r, g_r)
    g12 = dot(g_r, g_s)
    g22 = dot(g_s, g_s)
    detg = g11*g22 - g12*g12
    detg_safe = abs(detg) < 1e-14 ? (detg < 0.0 ? -1e-14 : 1e-14) : detg
    ar = (g22/detg_safe)*g_r + (-g12/detg_safe)*g_s
    as = (-g12/detg_safe)*g_r + (g11/detg_safe)*g_s
    dA = norm(cross(g_r, g_s))
    return N, dNr, dNs, dA, ar, as
end

@inline function _mitc4_3d_strain_row_project(
    B::AbstractMatrix,
    a::SVector{3,Float64},
    b::SVector{3,Float64},
    j::Int,
)
    return a[1]*b[1]*B[1,j] +
           a[2]*b[2]*B[2,j] +
           a[3]*b[3]*B[3,j] +
           0.5*(a[1]*b[2] + a[2]*b[1]) * B[4,j] +
           0.5*(a[2]*b[3] + a[3]*b[2]) * B[5,j] +
           0.5*(a[1]*b[3] + a[3]*b[1]) * B[6,j]
end

@inline function _mitc4_3d_tangent_basis(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
)
    _, _, _, g_r, g_s, _, _ = _mitc4_3d_jacobian(coords3d, directors, h, xi, eta, 0.0)
    n_raw = cross(g_r, g_s)
    n_len = norm(n_raw)
    n = n_len > 1e-30 ? n_raw / n_len : SVector(0.0, 0.0, 1.0)
    e1 = SVector(1.0, 0.0, 0.0)
    e2 = SVector(0.0, 1.0, 0.0)
    t1_raw = e1 - dot(e1, n) * n
    if norm(t1_raw) <= 1e-12
        t1_raw = e2 - dot(e2, n) * n
    end
    t1 = norm(t1_raw) > 1e-30 ? t1_raw / norm(t1_raw) : e1
    t2_raw = cross(n, t1)
    t2 = norm(t2_raw) > 1e-30 ? t2_raw / norm(t2_raw) : e2
    return t1, t2
end

function quad4_mitc4_3d_membrane_bending_rows(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    h::Float64,
    xi::Float64,
    eta::Float64,
    bend_delta::Float64,
)
    B0, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, xi, eta, 0.0)
    Bp, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, xi, eta, bend_delta)
    Bm_z, _ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, xi, eta, -bend_delta)
    Bm = zeros(3, 24)
    Bb = zeros(3, 24)
    mode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_STRAIN_BASIS", "tangent")))
    if mode in ("cartesian", "fixed", "element")
        @inbounds for j in 1:24
            Bm[1,j] = B0[1,j]
            Bm[2,j] = B0[2,j]
            Bm[3,j] = B0[4,j]
            Bb[1,j] = (Bp[1,j] - Bm_z[1,j]) / (h * bend_delta)
            Bb[2,j] = (Bp[2,j] - Bm_z[2,j]) / (h * bend_delta)
            Bb[3,j] = (Bp[4,j] - Bm_z[4,j]) / (h * bend_delta)
        end
    else
        t1, t2 = _mitc4_3d_tangent_basis(coords3d, directors, h, xi, eta)
        @inbounds for j in 1:24
            Bm[1,j] = _mitc4_3d_strain_row_project(B0, t1, t1, j)
            Bm[2,j] = _mitc4_3d_strain_row_project(B0, t2, t2, j)
            Bm[3,j] = 2.0 * _mitc4_3d_strain_row_project(B0, t1, t2, j)
            Bb[1,j] = (_mitc4_3d_strain_row_project(Bp, t1, t1, j) -
                       _mitc4_3d_strain_row_project(Bm_z, t1, t1, j)) / (h * bend_delta)
            Bb[2,j] = (_mitc4_3d_strain_row_project(Bp, t2, t2, j) -
                       _mitc4_3d_strain_row_project(Bm_z, t2, t2, j)) / (h * bend_delta)
            Bb[3,j] = 2.0 * (_mitc4_3d_strain_row_project(Bp, t1, t2, j) -
                             _mitc4_3d_strain_row_project(Bm_z, t1, t2, j)) / (h * bend_delta)
        end
    end
    bmode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_BENDING_MODE", "fiber")))
    if bmode in ("plate", "rotation", "rotgrad", "classical")
        _, dNr, dNs, _, ar, as = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        fill!(Bb, 0.0)
        @inbounds for a in 1:4
            gradN = dNr[a] * ar + dNs[a] * as
            base = (a - 1) * 6
            dNdx = gradN[1]
            dNdy = gradN[2]
            Bb[1, base+5] = dNdx
            Bb[2, base+4] = -dNdy
            Bb[3, base+5] = dNdy
            Bb[3, base+4] = -dNdx
        end
    end
    return Bm, Bb
end

"""
    stiffness_quad4_mitc4_3d_resultant_matrices(...)

Opt-in development stiffness for `JFEM_Q4_KERNEL=mitc4_3d`. This is a
degenerate-3D kinematic shell using the new director-based B-matrix, integrated
against JFEM's existing shell resultants (`Cm/Cb/Cs/Bmb`). It is intentionally a
bridge implementation: enough to run probes and compare mode sets before adding
ply-by-ply through-thickness material callbacks.
"""
# =============================================================================
# KERNEL: stiffness_quad4_mitc4_3d_resultant_matrices
# STATUS: RESEARCH / RETAINED — director-based 3D degenerate-shell formulation
#         (Bathe MITC4-3D). Last evaluated 2026-05-22 as global default →
#         REJECTED (VTP_3wp_strain regressed −35%) but PARTIAL POSITIVE on
#         HTP_3wp_strain (MAC 0.149 → 0.907). On master roadmap as future
#         capability — DO NOT DELETE.
# DISPATCHED FROM: assembly.jl line ~3589 when elem_mitc4_3d_kernel (i.e.
#         JFEM_Q4_KERNEL=mitc4_3d, default "macneal" — branch DEAD under default).
# CALIBRATION KNOBS (env, all opt-in): JFEM_Q4_MITC4_3D_SHEAR_MODE ("covariant"),
#         JFEM_Q4_MITC4_3D_STRAIN_BASIS ("tangent"),
#         JFEM_Q4_MITC4_3D_BENDING_MODE ("fiber"), JFEM_Q4_MITC4_3D_SHEAR_RBF,
#         JFEM_Q4_MITC4_3D_SHEAR_SCALE / _MEMBRANE_SCALE / _BENDING_SCALE /
#         _DRILL_SCALE / _BENDING_ZETA_DELTA.
# RELATED: stiffness_quad4_mitc4_3d_ply_matrices (composite ply integration);
#         many helper functions in FEMKernels.jl:252-660 (jacobians, B-matrices,
#         shear tying rows, frame builders).
# =============================================================================
function stiffness_quad4_mitc4_3d_resultant_matrices(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    Bmb=nothing,
    shear_center_only::Bool=false,
    bending_incomp::Bool=false,
)
    Ke = zeros(24, 24)
    h < 1e-30 && return Ke
    membrane_scale = fem_env_float("JFEM_Q4_MITC4_3D_MEMBRANE_SCALE", 1.0)
    bending_scale = fem_env_float("JFEM_Q4_MITC4_3D_BENDING_SCALE", 1.0)
    shear_scale = fem_env_float("JFEM_Q4_MITC4_3D_SHEAR_SCALE", 1.0)
    drill_scale_diag = fem_env_float("JFEM_Q4_MITC4_3D_DRILL_SCALE", 1.0)
    bend_delta = min(max(abs(fem_env_float("JFEM_Q4_MITC4_3D_BENDING_ZETA_DELTA", 1e-4)), 1e-8), 1.0)
    shear_mode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_SHEAR_MODE", "covariant")))
    macneal_shear = shear_mode in ("macneal", "rbf", "macneal_rbf", "plate_rbf")

    # Phase 5c: in-place MacNeal-1978-style residual-bending-flexibility
    # softening applied to Cs BEFORE the MITC covariant tying assembly. This
    # keeps the MITC4 tying-point kinematics (unlike `SHEAR_MODE=macneal`,
    # which substitutes the entire shear block) and only attenuates the
    # transverse-shear stiffness by a per-element constant in each direction.
    # Designed to counter the bending-block over-stiffness diagnosed in
    # MITC4_3D_DERIVATION_NOTES.md §"2026-05-20 Phase 5b" (the covariant
    # MITC4 tying pumps spurious stiffness into the θ_x, θ_y DOFs through
    # the rotation-gradient coupling on curved geometry).
    #
    # Opt-in via:
    #   JFEM_Q4_MITC4_3D_SHEAR_RBF = true
    #   JFEM_Q4_MITC4_3D_SHEAR_RBF_SCALE = ζ   (default 1.0, matches MacNeal eq 26)
    use_rbf_corr = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_SHEAR_RBF", "false"))) in ("1","true","yes","on")
    rbf_scale_user = fem_env_float("JFEM_Q4_MITC4_3D_SHEAR_RBF_SCALE", 1.0)
    Cs_eff = Cs
    if use_rbf_corr && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
        # Element-centre covariant in-plane tangent vectors g_r = ∂x/∂ξ,
        # g_s = ∂x/∂η for the natural-coordinate metric components and the
        # physical spans L_x, L_y. NOTE: _mitc4_3d_surface_area_and_grads
        # returns the *contravariant* bases (a^α = g^{αβ} g_β), which have
        # 1/length units — using those here was the silent bug that left
        # the RBF correction effectively inert in earlier drafts. Always
        # take the covariant g_r, g_s from `_mitc4_3d_jacobian` directly.
        _, _, _, g_r0, g_s0, _, _ = _mitc4_3d_jacobian(coords3d, directors, h, 0.0, 0.0, 0.0)
        L_x_sq = 4.0 * (g_r0[1]^2 + g_r0[2]^2 + g_r0[3]^2)    # (2·|g_r|)²
        L_y_sq = 4.0 * (g_s0[1]^2 + g_s0[2]^2 + g_s0[3]^2)    # physical spans
        flex_x = 1.0 / max(abs(Cb[1,1]), 1e-30)
        flex_y = 1.0 / max(abs(Cb[2,2]), 1e-30)
        # MacNeal 1978 eq 26: per-direction residual-bending compliance added
        # to the shear compliance. MacNeal's original form is
        #   Z_b[α,α] = L_α² / (12·Cb_αα)
        # with NO element-area factor — MacNeal's Δx,Δy are the physical spans
        # along the strain axis. Earlier drafts of this block divided by
        # `A_elem`, which is dimensionally invalid (Cs·Z_b becomes 1/area) and
        # silently produced sx≈1 (no attenuation) on all square elements (see
        # MITC4_3D_DERIVATION_NOTES.md §"2026-05-20 Phase 5c").
        # The total shear compliance is 1/Cs + Z_b; the corrected shear
        # stiffness is Cs_eff[α,α] = Cs[α,α] · s_α with
        #   s_α = 1 / (1 + Cs[α,α] · Z_b[α,α]).
        Zb_x = rbf_scale_user * L_x_sq * flex_x / 12.0
        Zb_y = rbf_scale_user * L_y_sq * flex_y / 12.0
        sx = 1.0 / (1.0 + abs(Cs[1,1]) * Zb_x)
        sy = 1.0 / (1.0 + abs(Cs[2,2]) * Zb_y)
        # Apply: Cs_eff = diag(√sx, √sy) · Cs · diag(√sx, √sy) so the diagonals
        # scale by sx/sy directly and the cross term by sqrt(sx·sy).
        sqx, sqy = sqrt(sx), sqrt(sy)
        Cs_eff = [sx*Cs[1,1]      sqx*sqy*Cs[1,2];
                  sqx*sqy*Cs[2,1] sy*Cs[2,2]]
    end

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))

    tmp3x24 = zeros(3, 24)
    tmp2x24 = zeros(2, 24)
    tmp3x4 = zeros(3, 4)
    Bm = zeros(3, 24)
    Bb = zeros(3, 24)
    Bs = zeros(2, 24)
    Bd = zeros(1, 24)
    Bi_bend = zeros(3, 4)
    K_ab_bend = zeros(24, 4)
    K_bb_bend = zeros(4, 4)

    G_drill = h > 0.0 ? Cm[3,3] / h : 0.0
    if G_drill < 1e-6
        G_drill = E_ref / (2 * 3.0)
    end
    alpha_drill = drill_scale * (k6rot / 1e5) * G_drill * h

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        _, _, _, dA, ar, as = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        dA = max(dA, 1e-12)
        dphi1 = (-2.0 * xi) * ar
        dphi2 = (-2.0 * eta) * as

        Bm_new, Bb_new = quad4_mitc4_3d_membrane_bending_rows(
            coords3d, directors, h, xi, eta, bend_delta
        )
        Bm .= Bm_new
        Bb .= Bb_new
        fill!(Bd, 0.0)
        fill!(Bi_bend, 0.0)

        if membrane_scale != 0.0
            ts_mul!(tmp3x24, Cm, Bm)
            ts_mul_At_add!(Ke, Bm, tmp3x24, dA * membrane_scale)
        end
        if bending_scale != 0.0
            ts_mul!(tmp3x24, Cb, Bb)
            ts_mul_At_add!(Ke, Bb, tmp3x24, dA * bending_scale)
        end
        if Bmb !== nothing
            ts_mul!(tmp3x24, Bmb, Bb)
            ts_mul_At_add!(Ke, Bm, tmp3x24, dA * sqrt(abs(membrane_scale * bending_scale)))
            ts_mul!(tmp3x24, Bmb, Bm)
            ts_mul_At_add!(Ke, Bb, tmp3x24, dA * sqrt(abs(membrane_scale * bending_scale)))
        end

        if !macneal_shear && !shear_center_only && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
            Bs .= quad4_mitc4_3d_selected_shear_rows(coords3d, directors, h, xi, eta)
            ts_mul!(tmp2x24, Cs_eff, Bs)
            ts_mul_At_add!(Ke, Bs, tmp2x24, dA * shear_scale)
        end

        if bending_incomp && bending_scale != 0.0
            Bi_bend[2,1] = -dphi1[2]
            Bi_bend[2,2] = -dphi2[2]
            Bi_bend[1,3] =  dphi1[1]
            Bi_bend[1,4] =  dphi2[1]
            Bi_bend[3,1] = -dphi1[1]
            Bi_bend[3,2] = -dphi2[1]
            Bi_bend[3,3] =  dphi1[2]
            Bi_bend[3,4] =  dphi2[2]
            ts_mul!(tmp3x4, Cb, Bi_bend)
            ts_mul_At_add!(K_ab_bend, Bb, tmp3x4, dA * bending_scale)
            ts_mul_At_add!(K_bb_bend, Bi_bend, tmp3x4, dA * bending_scale)
        end

        N, dNr, dNs, _, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        for a in 1:4
            gradN = dNr[a]*ar + dNs[a]*as
            base = (a-1)*6
            Bd[1, base+1] = 0.5*gradN[2]
            Bd[1, base+2] = -0.5*gradN[1]
            Bd[1, base+6] = N[a]
        end
        ts_mul_At_add!(Ke, Bd, Bd, dA * alpha_drill * drill_scale_diag)
    end

    if macneal_shear && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
        coords2d = zeros(4, 2)
        K_shear = zeros(24, 24)
        @inbounds for a in 1:4
            coords2d[a, 1] = coords3d[a, 1]
            coords2d[a, 2] = coords3d[a, 2]
        end
        add_quad4_macneal_shear_rbf!(K_shear, coords2d, Cb, Cs, h)
        @inbounds @fastmath for j in 1:24, i in 1:24
            Ke[i, j] += shear_scale * K_shear[i, j]
        end
    elseif shear_center_only && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
        _, _, _, dA, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, 0.0, 0.0)
        Bs .= quad4_mitc4_3d_selected_shear_rows(coords3d, directors, h, 0.0, 0.0)
        ts_mul!(tmp2x24, Cs, Bs)
        ts_mul_At_add!(Ke, Bs, tmp2x24, 4.0 * max(dA, 1e-12) * shear_scale)
    end

    if bending_incomp && maximum(abs, K_bb_bend) > 0.0
        inv_Kbb_b = Matrix(inv(SMatrix{4,4}(K_bb_bend)))
        @inbounds @fastmath for j in 1:24, i in 1:24
            sb = 0.0
            for l in 1:4
                tmp_b = 0.0
                for q in 1:4
                    tmp_b += inv_Kbb_b[l,q] * K_ab_bend[j,q]
                end
                sb += K_ab_bend[i,l] * tmp_b
            end
            Ke[i,j] -= sb
        end
    end

    return Ke
end

# =============================================================================
# KERNEL: stiffness_quad4_mitc4_3d_ply_matrices
# STATUS: RESEARCH / RETAINED — MITC4-3D variant with explicit ply-by-ply
#         through-thickness integration (composite PCOMP). Sister of
#         stiffness_quad4_mitc4_3d_resultant_matrices. Same status — rejected as
#         global default, retained per master roadmap. DO NOT DELETE.
# DISPATCHED FROM: assembly.jl line ~3576 when mitc4_3d_ply_integration && is_pcomp.
# CALIBRATION KNOBS: same set as the resultant variant (JFEM_Q4_MITC4_3D_*).
# =============================================================================
function stiffness_quad4_mitc4_3d_ply_matrices(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    ply_data,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    shear_center_only::Bool=false,
    material_rotation::Float64=0.0,
    local_bending_scale::Float64=1.0,
)
    Ke = zeros(24, 24)
    h < 1e-30 && return Ke
    if ply_data === nothing || isempty(ply_data)
        return Ke
    end
    ply_scale = fem_env_float("JFEM_Q4_MITC4_3D_PLY_SCALE", 1.0)
    membrane_scale = fem_env_float("JFEM_Q4_MITC4_3D_MEMBRANE_SCALE", 1.0)
    bending_scale = fem_env_float("JFEM_Q4_MITC4_3D_BENDING_SCALE", 1.0) * local_bending_scale
    shear_scale = fem_env_float("JFEM_Q4_MITC4_3D_SHEAR_SCALE", 1.0)
    drill_scale_diag = fem_env_float("JFEM_Q4_MITC4_3D_DRILL_SCALE", 1.0)
    bend_delta = min(max(abs(fem_env_float("JFEM_Q4_MITC4_3D_BENDING_ZETA_DELTA", 1e-4)), 1e-8), 1.0)
    shear_mode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_SHEAR_MODE", "covariant")))
    macneal_shear = shear_mode in ("macneal", "rbf", "macneal_rbf", "plate_rbf")
    ply_split = fem_env_bool("JFEM_Q4_MITC4_3D_PLY_SPLIT", false) ||
                membrane_scale != 1.0 || bending_scale != 1.0

    # Phase 5c — residual-bending-flexibility softening of the covariant
    # shear, mirrored from `stiffness_quad4_mitc4_3d_resultant_matrices`.
    # Opt-in via JFEM_Q4_MITC4_3D_SHEAR_RBF=true (default off). Cb_eff is
    # reconstructed once from the ply stack via the standard CLT identity
    #   D_ij = Σ_k (1/3)·(z_top^3 − z_bot^3)·Q̄_k_ij.
    # See MITC4_3D_DERIVATION_NOTES.md §"2026-05-20 Phase 5c" for derivation.
    use_rbf_corr = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_SHEAR_RBF", "false"))) in ("1","true","yes","on")
    rbf_scale_user = fem_env_float("JFEM_Q4_MITC4_3D_SHEAR_RBF_SCALE", 1.0)
    Cs_eff = Cs
    if use_rbf_corr && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30 &&
       ply_data !== nothing && !isempty(ply_data)
        _, _, _, g_r, g_s, _, _ = _mitc4_3d_jacobian(coords3d, directors, h, 0.0, 0.0, 0.0)
        L_x_sq = 4.0 * (g_r[1]^2 + g_r[2]^2 + g_r[3]^2)
        L_y_sq = 4.0 * (g_s[1]^2 + g_s[2]^2 + g_s[3]^2)
        Cb_eff_11 = 0.0
        Cb_eff_22 = 0.0
        for ply in ply_data
            z_bot = Float64(ply["z_bot"])
            z_top = Float64(ply["z_top"])
            (z_top - z_bot) <= 0.0 && continue
            Qbar = ply["Qbar"]
            local_Q = Qbar
            if abs(material_rotation) > 1e-12
                Qb_copy = copy(Qbar)
                rotate_constitutive_3x3!(Qb_copy, material_rotation)
                local_Q = Qb_copy
            end
            factor = (z_top^3 - z_bot^3) / 3.0
            Cb_eff_11 += factor * local_Q[1, 1]
            Cb_eff_22 += factor * local_Q[2, 2]
        end
        flex_x = 1.0 / max(abs(Cb_eff_11), 1e-30)
        flex_y = 1.0 / max(abs(Cb_eff_22), 1e-30)
        Zb_x = rbf_scale_user * L_x_sq * flex_x / 12.0
        Zb_y = rbf_scale_user * L_y_sq * flex_y / 12.0
        sx = 1.0 / (1.0 + abs(Cs[1, 1]) * Zb_x)
        sy = 1.0 / (1.0 + abs(Cs[2, 2]) * Zb_y)
        sqx, sqy = sqrt(sx), sqrt(sy)
        Cs_eff = [sx*Cs[1,1]      sqx*sqy*Cs[1,2];
                  sqx*sqy*Cs[2,1] sy*Cs[2,2]]
    end

    pt = 1.0 / sqrt(3.0)
    gp2 = (SVector(-pt, 1.0), SVector(pt, 1.0))
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))

    tmp3x24 = zeros(3, 24)
    tmp2x24 = zeros(2, 24)
    Bps = zeros(3, 24)
    Bm = zeros(3, 24)
    Bb = zeros(3, 24)
    Bs = zeros(2, 24)
    Bd = zeros(1, 24)

    G_drill = E_ref / (2 * 3.0)
    alpha_drill = drill_scale * (k6rot / 1e5) * G_drill * h

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        if ply_split
            Bm_new, Bb_new = quad4_mitc4_3d_membrane_bending_rows(
                coords3d, directors, h, xi, eta, bend_delta
            )
            Bm .= Bm_new
            Bb .= Bb_new
        end
        _, _, _, dA_mid, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        for ply in ply_data
            z_bot = Float64(ply["z_bot"])
            z_top = Float64(ply["z_top"])
            z_mid = 0.5 * (z_bot + z_top)
            z_half = 0.5 * (z_top - z_bot)
            z_half <= 0.0 && continue
            Qbar = copy(ply["Qbar"])
            if abs(material_rotation) > 1e-12
                rotate_constitutive_3x3!(Qbar, material_rotation)
            end
            for gz in gp2
                z_phys = z_mid + z_half * gz[1]
                scale = max(dA_mid, 1e-12) * gz[2] * z_half * ply_scale
                fill!(Bps, 0.0)
                if ply_split
                    mfac = sqrt(max(membrane_scale, 0.0))
                    bfac = sqrt(max(bending_scale, 0.0))
                    for j in 1:24
                        Bps[1,j] = mfac * Bm[1,j] + bfac * z_phys * Bb[1,j]
                        Bps[2,j] = mfac * Bm[2,j] + bfac * z_phys * Bb[2,j]
                        Bps[3,j] = mfac * Bm[3,j] + bfac * z_phys * Bb[3,j]
                    end
                else
                    zeta = 2.0 * z_phys / h
                    B3, detJ = quad4_mitc4_3d_B_displacement(coords3d, directors, h, xi, eta, zeta)
                    scale = abs(detJ) * gz[2] * (2.0 * z_half / h) * ply_scale
                    mode = lowercase(strip(get(ENV, "JFEM_Q4_MITC4_3D_STRAIN_BASIS", "tangent")))
                    if mode in ("cartesian", "fixed", "element")
                        for j in 1:24
                            Bps[1,j] = B3[1,j]
                            Bps[2,j] = B3[2,j]
                            Bps[3,j] = B3[4,j]
                        end
                    else
                        t1, t2 = _mitc4_3d_tangent_basis(coords3d, directors, h, xi, eta)
                        for j in 1:24
                            Bps[1,j] = _mitc4_3d_strain_row_project(B3, t1, t1, j)
                            Bps[2,j] = _mitc4_3d_strain_row_project(B3, t2, t2, j)
                            Bps[3,j] = 2.0 * _mitc4_3d_strain_row_project(B3, t1, t2, j)
                        end
                    end
                end
                ts_mul!(tmp3x24, Qbar, Bps)
                ts_mul_At_add!(Ke, Bps, tmp3x24, scale)
            end
        end

        if !macneal_shear && !shear_center_only && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
            _, _, _, dA, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
            Bs .= quad4_mitc4_3d_selected_shear_rows(coords3d, directors, h, xi, eta)
            ts_mul!(tmp2x24, Cs_eff, Bs)
            ts_mul_At_add!(Ke, Bs, tmp2x24, max(dA, 1e-12) * shear_scale)
        end

        N, dNr, dNs, _, ar, as = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        fill!(Bd, 0.0)
        for a in 1:4
            gradN = dNr[a]*ar + dNs[a]*as
            base = (a-1)*6
            Bd[1, base+1] = 0.5*gradN[2]
            Bd[1, base+2] = -0.5*gradN[1]
            Bd[1, base+6] = N[a]
        end
        _, _, _, dA, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        ts_mul_At_add!(Ke, Bd, Bd, max(dA, 1e-12) * alpha_drill * drill_scale_diag)
    end

    if macneal_shear && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
        coords2d = zeros(4, 2)
        Cb_eff = zeros(3, 3)
        K_shear = zeros(24, 24)
        @inbounds for a in 1:4
            coords2d[a, 1] = coords3d[a, 1]
            coords2d[a, 2] = coords3d[a, 2]
        end
        for ply in ply_data
            z_bot = Float64(ply["z_bot"])
            z_top = Float64(ply["z_top"])
            z_mid = 0.5 * (z_bot + z_top)
            z_half = 0.5 * (z_top - z_bot)
            z_half <= 0.0 && continue
            Qbar = copy(ply["Qbar"])
            if abs(material_rotation) > 1e-12
                rotate_constitutive_3x3!(Qbar, material_rotation)
            end
            @inbounds for j in 1:3, i in 1:3
                Cb_eff[i, j] += (z_top^3 - z_bot^3) / 3.0 * Qbar[i, j]
            end
        end
        add_quad4_macneal_shear_rbf!(K_shear, coords2d, Cb_eff, Cs, h)
        @inbounds @fastmath for j in 1:24, i in 1:24
            Ke[i, j] += shear_scale * K_shear[i, j]
        end
    elseif shear_center_only && shear_scale != 0.0 && maximum(abs, Cs) >= 1e-30
        _, _, _, dA, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, 0.0, 0.0)
        Bs .= quad4_mitc4_3d_selected_shear_rows(coords3d, directors, h, 0.0, 0.0)
        ts_mul!(tmp2x24, Cs, Bs)
        ts_mul_At_add!(Ke, Bs, tmp2x24, 4.0 * max(dA, 1e-12) * shear_scale)
    end

    return Ke
end

function quad4_mitc4_3d_membrane_force_field(
    coords3d::AbstractMatrix,
    directors::AbstractMatrix,
    u_elem::AbstractVector,
    Cm,
    h;
    Bmb=nothing,
)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))
    bend_delta = min(max(abs(fem_env_float("JFEM_Q4_MITC4_3D_BENDING_ZETA_DELTA", 1e-4)), 1e-8), 1.0)
    N_gp = zeros(4, 3)
    N_avg = zeros(3)
    area_w = zeros(4)
    Bm = zeros(3, 24)
    Bb = zeros(3, 24)
    eps_m = zeros(3)
    kappa = zeros(3)
    total_area = 0.0

    @inbounds for (igp, gp) in enumerate(gauss_pts)
        xi, eta = gp[1], gp[2]
        _, _, _, dA, _, _ = _mitc4_3d_surface_area_and_grads(coords3d, directors, h, xi, eta)
        dA = max(dA, 1e-12)

        Bm_new, Bb_new = quad4_mitc4_3d_membrane_bending_rows(
            coords3d, directors, h, xi, eta, bend_delta
        )
        Bm .= Bm_new
        Bb .= Bb_new
        fill!(eps_m, 0.0)
        fill!(kappa, 0.0)
        for j in 1:24
            eps_m[1] += Bm[1,j] * u_elem[j]
            eps_m[2] += Bm[2,j] * u_elem[j]
            eps_m[3] += Bm[3,j] * u_elem[j]
            if Bmb !== nothing
                kappa[1] += Bb[1,j] * u_elem[j]
                kappa[2] += Bb[2,j] * u_elem[j]
                kappa[3] += Bb[3,j] * u_elem[j]
            end
        end

        for i in 1:3
            val = 0.0
            for j in 1:3
                val += Cm[i,j] * eps_m[j]
                if Bmb !== nothing
                    val += Bmb[i,j] * kappa[j]
                end
            end
            N_gp[igp, i] = val
            N_avg[i] += val * dA
        end
        area_w[igp] = dA
        total_area += dA
    end

    if total_area > 1e-30
        @inbounds for i in 1:3
            N_avg[i] /= total_area
        end
    end
    return N_gp, N_avg, area_w
end
