# experimental/dkq_dkmq_flat_plate_kernels.jl
#
# DKQ (Discrete Kirchhoff Quad) and DKMQ (DKQ + Mindlin) flat-plate Q4
# research kernels. RESEARCH only — never default-on. Reached only via:
#   - JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ (default off — flat DKMQ K)
#   - JFEM_SOL105_EIG_FLAT_PCOMP_PLATE_BRANCH (default off — flat DKQ K)
#
# Contains: dkq_edge_shape_derivs/_second_derivs, dkq_plate_hbar_matrix,
# dkq_plate_edge_relation, dkmq_side_local_constitutive,
# dkmq_flat_plate_edge_relation, dkmq_plate_side_shear_operator!,
# add_quad4_plate_dkmq_exact_shear!.
#
# Moved out of FEMKernels.jl 2026-05-25 as part of architectural cleanup
# (phase C2/D1 — quarantine research kernels out of the production hot
# path).

@inline function dkq_edge_shape_derivs(xi::Float64, eta::Float64)
    dP_dxi = SVector(
        -xi * (1.0 - eta),
        0.5 * (1.0 - eta^2),
        -xi * (1.0 + eta),
        -0.5 * (1.0 - eta^2),
    )
    dP_deta = SVector(
        -0.5 * (1.0 - xi^2),
        -(1.0 + xi) * eta,
        0.5 * (1.0 - xi^2),
        -(1.0 - xi) * eta,
    )
    return dP_dxi, dP_deta
end

@inline function dkq_edge_shape_second_derivs(xi::Float64, eta::Float64)
    d2P_dxi2 = SVector(
        -(1.0 - eta),
        0.0,
        -(1.0 + eta),
        0.0,
    )
    d2P_deta2 = SVector(
        0.0,
        -(1.0 + xi),
        0.0,
        -(1.0 - xi),
    )
    d2P_dxideta = SVector(
        xi,
        -eta,
        -xi,
        eta,
    )
    return d2P_dxi2, d2P_deta2, d2P_dxideta
end

@inline function dkq_plate_hbar_matrix(Cb::AbstractMatrix)
    Hbar = zeros(2, 6)
    Hbar[1, 1] = Cb[1, 1]
    Hbar[1, 2] = Cb[3, 3]
    Hbar[1, 3] = 2.0 * Cb[1, 3]
    Hbar[1, 4] = Cb[1, 3]
    Hbar[1, 5] = Cb[2, 3]
    Hbar[1, 6] = Cb[1, 2] + Cb[3, 3]
    Hbar[2, 1] = Cb[1, 3]
    Hbar[2, 2] = Cb[2, 3]
    Hbar[2, 3] = Cb[1, 2] + Cb[3, 3]
    Hbar[2, 4] = Cb[3, 3]
    Hbar[2, 5] = Cb[2, 2]
    Hbar[2, 6] = 2.0 * Cb[2, 3]
    return Hbar
end

function dkq_plate_edge_relation(coords, Cb::AbstractMatrix, Cs::AbstractMatrix)
    Hct_inv = inv(Cs)
    Hbar = dkq_plate_hbar_matrix(Cb)

    edge_c = zeros(4)
    edge_s = zeros(4)
    edge_L = zeros(4)
    edge_pairs = ((1, 2), (2, 3), (3, 4), (4, 1))
    @inbounds for e in 1:4
        i, j = edge_pairs[e]
        dx = coords[j, 1] - coords[i, 1]
        dy = coords[j, 2] - coords[i, 2]
        L = sqrt(dx * dx + dy * dy)
        if L <= 1e-12
            continue
        end
        edge_c[e] = dx / L
        edge_s[e] = dy / L
        edge_L[e] = L
    end

    function fill_dkq_point_operators!(Bf_beta, Bf_alpha, Bc_beta, Bc_alpha, xi::Float64, eta::Float64)
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11 * J22 - J12 * J21
        if abs(detJ) < 1e-12
            detJ = detJ < 0.0 ? -1e-12 : 1e-12
        end
        abs_detJ = abs(detJ)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(Bf_beta, 0.0)
        fill!(Bf_alpha, 0.0)
        fill!(Bc_beta, 0.0)
        fill!(Bc_alpha, 0.0)

        d2N_dxideta = (0.25, -0.25, 0.25, -0.25)
        for a in 1:4
            dN_dx = iJ11 * dNr[a] + iJ12 * dNs[a]
            dN_dy = iJ21 * dNr[a] + iJ22 * dNs[a]
            col = (a - 1) * 3
            Bf_beta[1, col + 3] = dN_dx
            Bf_beta[2, col + 2] = -dN_dy
            Bf_beta[3, col + 2] = -dN_dx
            Bf_beta[3, col + 3] = dN_dy

            d2N_xx = 2.0 * iJ11 * iJ12 * d2N_dxideta[a]
            d2N_yy = 2.0 * iJ21 * iJ22 * d2N_dxideta[a]
            d2N_xy = (iJ11 * iJ22 + iJ12 * iJ21) * d2N_dxideta[a]
            Bc_beta[1, col + 3] = Hbar[1, 1] * d2N_xx + Hbar[1, 2] * d2N_yy + Hbar[1, 3] * d2N_xy
            Bc_beta[2, col + 3] = Hbar[2, 1] * d2N_xx + Hbar[2, 2] * d2N_yy + Hbar[2, 3] * d2N_xy
            Bc_beta[1, col + 2] = -(Hbar[1, 4] * d2N_xx + Hbar[1, 5] * d2N_yy + Hbar[1, 6] * d2N_xy)
            Bc_beta[2, col + 2] = -(Hbar[2, 4] * d2N_xx + Hbar[2, 5] * d2N_yy + Hbar[2, 6] * d2N_xy)
        end

        dP_dxi, dP_deta = dkq_edge_shape_derivs(xi, eta)
        d2P_dxi2, d2P_deta2, d2P_dxideta = dkq_edge_shape_second_derivs(xi, eta)
        for e in 1:4
            c = edge_c[e]
            s = edge_s[e]
            dP_dx = iJ11 * dP_dxi[e] + iJ12 * dP_deta[e]
            dP_dy = iJ21 * dP_dxi[e] + iJ22 * dP_deta[e]
            Bf_alpha[1, e] = c * dP_dx
            Bf_alpha[2, e] = s * dP_dy
            Bf_alpha[3, e] = c * dP_dy + s * dP_dx

            d2P_xx = iJ11^2 * d2P_dxi2[e] + iJ12^2 * d2P_deta2[e] + 2.0 * iJ11 * iJ12 * d2P_dxideta[e]
            d2P_yy = iJ21^2 * d2P_dxi2[e] + iJ22^2 * d2P_deta2[e] + 2.0 * iJ21 * iJ22 * d2P_dxideta[e]
            d2P_xy = iJ11 * iJ21 * d2P_dxi2[e] + iJ12 * iJ22 * d2P_deta2[e] +
                     (iJ11 * iJ22 + iJ12 * iJ21) * d2P_dxideta[e]

            Bc_alpha[1, e] =
                Hbar[1, 1] * (c * d2P_xx) +
                Hbar[1, 2] * (c * d2P_yy) +
                Hbar[1, 3] * (c * d2P_xy) +
                Hbar[1, 4] * (s * d2P_xx) +
                Hbar[1, 5] * (s * d2P_yy) +
                Hbar[1, 6] * (s * d2P_xy)
            Bc_alpha[2, e] =
                Hbar[2, 1] * (c * d2P_xx) +
                Hbar[2, 2] * (c * d2P_yy) +
                Hbar[2, 3] * (c * d2P_xy) +
                Hbar[2, 4] * (s * d2P_xx) +
                Hbar[2, 5] * (s * d2P_yy) +
                Hbar[2, 6] * (s * d2P_xy)
        end

        return abs_detJ
    end

    Bf_beta = zeros(3, 12)
    Bf_alpha = zeros(3, 4)
    Bc_beta = zeros(2, 12)
    Bc_alpha = zeros(2, 4)
    tmp3x12 = zeros(3, 12)
    tmp3x4 = zeros(3, 4)
    tmp2x12 = zeros(2, 12)
    tmp2x4 = zeros(2, 4)
    Kf11 = zeros(12, 12)
    Kf12 = zeros(12, 4)
    Kf22 = zeros(4, 4)
    Kbb = zeros(12, 12)
    Kba = zeros(12, 4)
    Kca = zeros(4, 4)

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    @inbounds for gp in gauss_pts
        abs_detJ = fill_dkq_point_operators!(Bf_beta, Bf_alpha, Bc_beta, Bc_alpha, gp[1], gp[2])

        ts_mul!(tmp3x12, Cb, Bf_beta)
        ts_mul_At_add!(Kf11, Bf_beta, tmp3x12, abs_detJ)

        ts_mul!(tmp3x4, Cb, Bf_alpha)
        ts_mul_At_add!(Kf12, Bf_beta, tmp3x4, abs_detJ)
        ts_mul_At_add!(Kf22, Bf_alpha, tmp3x4, abs_detJ)

        ts_mul!(tmp2x4, Hct_inv, Bc_alpha)
        ts_mul!(tmp2x12, Hct_inv, Bc_beta)
        ts_mul_At_add!(Kbb, Bc_beta, tmp2x12, abs_detJ)
        ts_mul_At_add!(Kba, Bc_beta, tmp2x4, abs_detJ)
        ts_mul_At_add!(Kca, Bc_alpha, tmp2x4, abs_detJ)
    end

    Aw = zeros(4, 12)
    Aalpha = zeros(4, 4)
    edge_gp_coords = (
        (SVector(-pt, -1.0), SVector(pt, -1.0)),
        (SVector(1.0, -pt), SVector(1.0, pt)),
        (SVector(pt, 1.0), SVector(-pt, 1.0)),
        (SVector(-1.0, pt), SVector(-1.0, -pt)),
    )
    Bbar_beta = zeros(2, 12)
    Bbar_alpha = zeros(2, 4)
    for e in 1:4
        fill!(Bbar_beta, 0.0)
        fill!(Bbar_alpha, 0.0)
        for gp in edge_gp_coords[e]
            fill_dkq_point_operators!(Bf_beta, Bf_alpha, Bc_beta, Bc_alpha, gp[1], gp[2])
            @inbounds for jj in 1:12, ii in 1:2
                Bbar_beta[ii, jj] += 0.5 * Bc_beta[ii, jj]
            end
            @inbounds for jj in 1:4, ii in 1:2
                Bbar_alpha[ii, jj] += 0.5 * Bc_alpha[ii, jj]
            end
        end

        i, j = edge_pairs[e]
        L = edge_L[e]
        c = edge_c[e]
        s = edge_s[e]
        q1 = L * c
        q2 = L * s
        Aalpha[e, e] = 2.0 * L / 3.0
        @inbounds for col in 1:4
            Aalpha[e, col] -= q1 * (Hct_inv[1, 1] * Bbar_alpha[1, col] + Hct_inv[1, 2] * Bbar_alpha[2, col]) +
                              q2 * (Hct_inv[2, 1] * Bbar_alpha[1, col] + Hct_inv[2, 2] * Bbar_alpha[2, col])
        end

        wi = (i - 1) * 3 + 1
        rxi = (i - 1) * 3 + 2
        ryi = (i - 1) * 3 + 3
        wj = (j - 1) * 3 + 1
        rxj = (j - 1) * 3 + 2
        ryj = (j - 1) * 3 + 3
        Aw[e, wi] += 1.0
        Aw[e, wj] -= 1.0
        Aw[e, rxi] += 0.5 * L * s
        Aw[e, ryi] -= 0.5 * L * c
        Aw[e, rxj] += 0.5 * L * s
        Aw[e, ryj] -= 0.5 * L * c
        @inbounds for col in 1:12
            Aw[e, col] += q1 * (Hct_inv[1, 1] * Bbar_beta[1, col] + Hct_inv[1, 2] * Bbar_beta[2, col]) +
                          q2 * (Hct_inv[2, 1] * Bbar_beta[1, col] + Hct_inv[2, 2] * Bbar_beta[2, col])
        end
    end

    return Aalpha \ Aw, edge_c, edge_s, edge_L
end

@inline function dkmq_side_local_constitutive(c::Float64, s::Float64, Cb::AbstractMatrix, Cs::AbstractMatrix)
    # Exact side-local constitutive transformation from the composite DKMQ24 paper.
    Rb = @SMatrix [
        c^2       s^2        2.0*c*s;
        s^2       c^2       -2.0*c*s;
       -c*s       c*s        c^2 - s^2
    ]
    Rs = @SMatrix [
        c   s;
       -s   c
    ]
    Cb_loc = Matrix(Rb * SMatrix{3,3}(Cb) * transpose(Rb))
    Cs_loc = Matrix(Rs * SMatrix{2,2}(Cs) * transpose(Rs))
    return Cb_loc, Cs_loc
end

function dkmq_flat_plate_edge_relation(coords::AbstractMatrix, Cb::AbstractMatrix, Cs::AbstractMatrix)
    A_beta = zeros(4, 12)
    edge_c = zeros(4)
    edge_s = zeros(4)
    edge_L = zeros(4)
    edge_pairs = ((1, 2), (2, 3), (3, 4), (4, 1))

    @inbounds for e in 1:4
        i, j = edge_pairs[e]
        dx = coords[j, 1] - coords[i, 1]
        dy = coords[j, 2] - coords[i, 2]
        L = sqrt(dx * dx + dy * dy)
        L <= 1e-12 && continue

        c = dx / L
        s = dy / L
        edge_c[e] = c
        edge_s[e] = s
        edge_L[e] = L

        Cb_loc, Cs_loc = dkmq_side_local_constitutive(c, s, Cb, Cs)
        # DKMQ24 (Katili-Maknun-Batoz-Ibrahimbegović 2018, Comp. Struct. 202)
        # eq (69) — per-side hierarchical-rotation locking coefficient:
        #
        #   κ_k = ( Hs_inv_k[2,1] · Hb_k[3,2] + Hs_inv_k[2,2] · Hb_k[2,2] ) · 12 / L_k²
        #
        # The paper's index convention follows its [Rk1] rotation matrix
        # (which has S²_k in the [1,1] position). JFEM's [Rb] has C²_k in
        # the [1,1] position — i.e. transposed. The two conventions assign
        # the "along-side" axis to opposite indices. Mapping: paper's
        # Hb_k[2,2] corresponds to JFEM's Cb_loc[1,1] (along-side D_ss).
        # Likewise paper's Hs_inv_k[2,2] is JFEM's Hs_loc_inv[1,1] and
        # paper's Hs_inv_k[2,1] · Hb_k[3,2] is JFEM's Hs_loc_inv[1,2] ·
        # Cb_loc[3,1]. The off-diagonal coupling term captures bending-twist
        # interaction in unbalanced composite layups; it vanishes for any
        # orthotropic material aligned with the side (and for iso).
        #
        # Iso reduction (eq 72) is recovered when Cs_loc is diagonal and
        # Cb_loc has zero twist-bending coupling: κ = Db/Ds · 12/L².
        det_Cs_loc = Cs_loc[1,1]*Cs_loc[2,2] - Cs_loc[1,2]*Cs_loc[2,1]
        Hs_inv_11 = abs(det_Cs_loc) > 1e-30 ? Cs_loc[2,2] / det_Cs_loc : 1.0 / max(abs(Cs_loc[1,1]), 1e-30)
        Hs_inv_12 = abs(det_Cs_loc) > 1e-30 ? -Cs_loc[1,2] / det_Cs_loc : 0.0
        Hb_along  = Cb_loc[1, 1]   # paper's Hb_k[2,2] = D_ss
        Hb_couple = Cb_loc[3, 1]   # paper's Hb_k[3,2] = bending-twist coupling
        phi = (Hs_inv_12 * Hb_couple + Hs_inv_11 * Hb_along) * 12.0 / (L * L)
        if !isfinite(phi) || phi < 0.0
            # Fallback to iso form if the layup-coupling term flips sign in a
            # non-physical way (e.g. anti-symmetric layup with negative D_ss)
            Db = max(abs(Cb_loc[1, 1]), 1e-30)
            Ds = max(abs(Cs_loc[1, 1]), 1e-30)
            phi = 12.0 * Db / (L * L * Ds)
        end
        scale = 1.5 / (L * (1.0 + phi))
        rot = 0.5 * L * scale

        coli = (i - 1) * 3
        colj = (j - 1) * 3

        A_beta[e, coli + 1] += scale
        A_beta[e, colj + 1] -= scale

        # beta_t = c*theta_y - s*theta_x in the present plate kinematics.
        A_beta[e, coli + 2] +=  rot * s
        A_beta[e, coli + 3] += -rot * c
        A_beta[e, colj + 2] +=  rot * s
        A_beta[e, colj + 3] += -rot * c
    end

    return A_beta, edge_c, edge_s, edge_L
end

@inline function dkmq_plate_side_shear_operator!(
    Bs::AbstractMatrix,
    coords::AbstractMatrix,
    A_beta::AbstractMatrix,
    edge_L::AbstractVector,
    xi::Float64,
    eta::Float64,
)
    dNr, dNs = shape_derivs_quad(xi, eta)
    J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
    J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
    J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
    J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
    detJ = J11 * J22 - J12 * J21
    if abs(detJ) < 1e-12
        detJ = detJ < 0.0 ? -1e-12 : 1e-12
    end
    abs_detJ = abs(detJ)
    inv_det = 1.0 / detJ
    iJ11 = J22 * inv_det
    iJ12 = -J12 * inv_det
    iJ21 = -J21 * inv_det
    iJ22 = J11 * inv_det

    # Exact DKMQ side shear interpolation:
    # Bs = Bs4Δ * A_n, with side signs from the plate/shell derivation.
    c5 = 0.25 * (1.0 - eta) * edge_L[1]
    c6 = 0.25 * (1.0 + xi) * edge_L[2]
    c7 = -0.25 * (1.0 + eta) * edge_L[3]
    c8 = -0.25 * (1.0 - xi) * edge_L[4]

    @inbounds for j in 1:12
        Bs[1, j] =
            iJ11 * (c5 * A_beta[1, j] + c7 * A_beta[3, j]) +
            iJ12 * (c6 * A_beta[2, j] + c8 * A_beta[4, j])
        Bs[2, j] =
            iJ21 * (c5 * A_beta[1, j] + c7 * A_beta[3, j]) +
            iJ22 * (c6 * A_beta[2, j] + c8 * A_beta[4, j])
    end
    return abs_detJ
end

# =============================================================================
# KERNEL: add_quad4_plate_dkmq_exact_shear!
# STATUS: RESEARCH / RETAINED - DKMQ exact side-shear add-on. Used internally
#         by stiffness_quad4_matrices when exact_side_shear=true (kwarg, gated
#         by JFEM_SOL105_EIG_FLAT_PCOMP_EXACT_SIDE_SHEAR, default false).
# =============================================================================
function add_quad4_plate_dkmq_exact_shear!(
    Ke::AbstractMatrix,
    coords::AbstractMatrix,
    Cb::AbstractMatrix,
    Cs::AbstractMatrix,
    h::Float64,
)
    if h < 1e-30 || maximum(abs, Cs) < 1e-30
        return Ke
    end

    A_beta, _, _, edge_L = dkmq_flat_plate_edge_relation(coords, Cb, Cs)
    Bs = zeros(2, 12)
    K_plate = zeros(12, 12)
    pt = 1.0 / sqrt(3.0)

    # DKMQ24_2+ selective integration of the shear rows:
    # b_sx with 1x2, b_sy with 2x1, and any shear-coupling cross-term with 2x2.
    row1_pts = ((0.0, -pt, 2.0), (0.0, pt, 2.0))
    row2_pts = ((-pt, 0.0, 2.0), (pt, 0.0, 2.0))
    full_pts = (
        (-pt, -pt, 1.0),
        (pt, -pt, 1.0),
        (pt, pt, 1.0),
        (-pt, pt, 1.0),
    )

    c11 = Cs[1, 1]
    c22 = Cs[2, 2]
    c12 = Cs[1, 2]
    c21 = Cs[2, 1]

    @inbounds for (xi, eta, weight) in row1_pts
        abs_detJ = dkmq_plate_side_shear_operator!(Bs, coords, A_beta, edge_L, xi, eta)
        for j in 1:12, i in 1:12
            K_plate[i, j] += h * weight * abs_detJ * c11 * Bs[1, i] * Bs[1, j]
        end
    end

    @inbounds for (xi, eta, weight) in row2_pts
        abs_detJ = dkmq_plate_side_shear_operator!(Bs, coords, A_beta, edge_L, xi, eta)
        for j in 1:12, i in 1:12
            K_plate[i, j] += h * weight * abs_detJ * c22 * Bs[2, i] * Bs[2, j]
        end
    end

    if abs(c12) > 1e-14 || abs(c21) > 1e-14
        @inbounds for (xi, eta, weight) in full_pts
            abs_detJ = dkmq_plate_side_shear_operator!(Bs, coords, A_beta, edge_L, xi, eta)
            for j in 1:12, i in 1:12
                K_plate[i, j] += h * weight * abs_detJ * (
                    c12 * Bs[1, i] * Bs[2, j] +
                    c21 * Bs[2, i] * Bs[1, j]
                )
            end
        end
    end

    plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
    @inbounds for j in 1:12, i in 1:12
        Ke[plate_dofs[i], plate_dofs[j]] += K_plate[i, j]
    end
    return Ke
end
