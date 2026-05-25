# experimental/hu_washizu_kernel.jl
#
# Hu-Washizu and hybrid-stress Q4 kernel family. RESEARCH only —
# fires when JFEM_Q4_KERNEL=huwashizu OR when stiffness_quad4_matrices is
# called with exact_membrane_operator=true / exact_membrane_curvature_w_coupling=true.
# Neither path is on under default GAME parity defaults.
#
# Members (called via `stiffness_quad4_huwashizu_matrices` dispatcher):
#   stiffness_quad4_membrane_hybrid_stress_matrices
#   stiffness_quad4_bending_hybrid_stress_matrices
#   stiffness_quad4_membrane_bending_hybrid_stress_matrices
#   stiffness_quad4_shear_hybrid_stress_matrices
#   stiffness_quad4_mitc_shear_drill_matrices
#   stiffness_quad4_huwashizu_full_matrices
#   stiffness_quad4_huwashizu_matrices
#   quad4_hybrid_stress_modes! (helper)
#
# Moved out of FEMKernels.jl 2026-05-25 as part of architectural cleanup
# (phase C2/D1 — quarantine research kernels out of the production hot path).
# The dispatcher `stiffness_quad4_matrices` (still in FEMKernels.jl) calls
# these by name; loading order in FEMKernels.jl is preserved via the include.

# =============================================================================
# KERNEL: stiffness_quad4_membrane_hybrid_stress_matrices
# STATUS: RESEARCH / RETAINED - Pian-Tong hybrid stress membrane (DKMQ24-2+).
#         Better accuracy on coarse / distorted meshes. Used by the
#         exact_membrane_operator path inside stiffness_quad4_matrices.
# DISPATCHED FROM: stiffness_quad4_matrices when exact_membrane_operator
#         (gated by JFEM_SOL105_EIG_FLAT_*_EXACT_MEMBRANE, all default false).
# =============================================================================
function stiffness_quad4_membrane_hybrid_stress_matrices(
    coords,
    Cm,
    h;
    curvature_membrane=nothing,
    curvature_w_coupling::Bool=false,
    include_drill_penalty::Bool=true,
)
    Ke = zeros(24, 24)

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))

    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J0 = @SMatrix [
        dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]  dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2];
        dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]  dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    ]

    S_inv = inv(Cm)
    H = zeros(5, 5)
    G = zeros(5, 24)
    area = 0.0

    function fill_stress_mode!(P::AbstractMatrix, xi::Float64, eta::Float64)
        fill!(P, 0.0)
        skew_modes = Vector{SMatrix{2, 2, Float64, 4}}(undef, 5)
        skew_modes[1] = @SMatrix [1.0 0.0; 0.0 0.0]
        skew_modes[2] = @SMatrix [0.0 0.0; 0.0 1.0]
        skew_modes[3] = @SMatrix [0.0 1.0; 1.0 0.0]
        skew_modes[4] = @SMatrix [eta 0.0; 0.0 0.0]
        skew_modes[5] = @SMatrix [0.0 0.0; 0.0 xi]
        @inbounds for a in 1:5
            sigma_mat = J0 * skew_modes[a] * transpose(J0)
            P[1, a] = sigma_mat[1, 1]
            P[2, a] = sigma_mat[2, 2]
            P[3, a] = sigma_mat[1, 2]
        end
        return P
    end

    Bm = zeros(3, 24)
    P = zeros(3, 5)
    tmp3x24 = zeros(3, 24)
    tmp3x5 = zeros(3, 5)

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = abs(detJ)
        if abs_detJ < 1e-12
            abs_detJ = 1e-12
        end
        area += abs_detJ

        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(Bm, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            N_k = 0.25*(1 + (k==2||k==3 ? xi : -xi))*(1 + (k>=3 ? eta : -eta))
            idx = (k - 1) * 6
            Bm[1, idx + 1] = dN_dx
            Bm[2, idx + 2] = dN_dy
            Bm[3, idx + 1] = dN_dy
            Bm[3, idx + 2] = dN_dx
            if curvature_w_coupling && curvature_membrane !== nothing
                Bm[1, idx + 3] = -N_k * curvature_membrane[1]
                Bm[2, idx + 3] = -N_k * curvature_membrane[2]
                Bm[3, idx + 3] = -2.0 * N_k * curvature_membrane[3]
            end
        end

        fill_stress_mode!(P, xi, eta)
        ts_mul!(tmp3x5, S_inv, P)
        ts_mul_At_add!(H, P, tmp3x5, abs_detJ)
        ts_mul_At_add!(G, P, Bm, abs_detJ)
    end

    Kmem = transpose(G) * (H \ G)
    Ke .+= Kmem

    # Minimal drilling regularization tied to the membrane center field to keep
    # the shell operator well-posed without letting drilling dominate.
    dNr0, dNs0 = dNr_c, dNs_c
    detJ0 = J0[1,1] * J0[2,2] - J0[1,2] * J0[2,1]
    inv_det0 = 1.0 / detJ0
    iJ11 = J0[2,2] * inv_det0
    iJ12 = -J0[1,2] * inv_det0
    iJ21 = -J0[2,1] * inv_det0
    iJ22 = J0[1,1] * inv_det0
    b0 = zeros(24)
    for k in 1:4
        dN_dx = iJ11*dNr0[k] + iJ12*dNs0[k]
        dN_dy = iJ21*dNr0[k] + iJ22*dNs0[k]
        idx = (k - 1) * 6
        b0[idx + 1] = -0.5 * dN_dy
        b0[idx + 2] =  0.5 * dN_dx
        b0[idx + 6] = -0.25
    end
    if include_drill_penalty
        k0 = 0.025 * Cm[3, 3]
        @inbounds @fastmath for j in 1:24, i in 1:24
            Ke[i, j] += k0 * area * b0[i] * b0[j]
        end
    end

    return Ke
end

function quad4_hybrid_stress_modes!(P::AbstractMatrix, J0, xi::Float64, eta::Float64)
    fill!(P, 0.0)
    skew_modes = (
        (@SMatrix [1.0 0.0; 0.0 0.0]),
        (@SMatrix [0.0 0.0; 0.0 1.0]),
        (@SMatrix [0.0 1.0; 1.0 0.0]),
        (@SMatrix [eta 0.0; 0.0 0.0]),
        (@SMatrix [0.0 0.0; 0.0 xi]),
    )
    @inbounds for a in 1:5
        sigma_mat = J0 * skew_modes[a] * transpose(J0)
        P[1, a] = sigma_mat[1, 1]
        P[2, a] = sigma_mat[2, 2]
        P[3, a] = sigma_mat[1, 2]
    end
    return P
end

# =============================================================================
# KERNEL: stiffness_quad4_bending_hybrid_stress_matrices
# STATUS: RESEARCH / NO CURRENT CALLERS - Pian-Tong hybrid stress for bending
#         (assumed-moment field). Not currently called from any production or
#         research dispatcher. Retained as a building block for future hybrid
#         stress shell formulations.
# =============================================================================
function stiffness_quad4_bending_hybrid_stress_matrices(coords, Cb)
    Ke = zeros(24, 24)
    maximum(abs, Cb) < 1e-30 && return Ke

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))

    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J0 = @SMatrix [
        dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]  dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2];
        dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]  dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    ]

    S_inv = inv(Cb)
    H = zeros(5, 5)
    G = zeros(5, 24)
    Bb = zeros(3, 24)
    P = zeros(3, 5)
    tmp3x24 = zeros(3, 24)
    tmp3x5 = zeros(3, 5)

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(Bb, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            idx = (k - 1) * 6
            Bb[1, idx + 5] = dN_dx
            Bb[2, idx + 4] = -dN_dy
            Bb[3, idx + 5] = dN_dy
            Bb[3, idx + 4] = -dN_dx
        end

        quad4_hybrid_stress_modes!(P, J0, xi, eta)
        ts_mul!(tmp3x5, S_inv, P)
        ts_mul_At_add!(H, P, tmp3x5, abs_detJ)
        ts_mul_At_add!(G, P, Bb, abs_detJ)
    end

    Ke .+= transpose(G) * (H \ G)
    return Ke
end

# =============================================================================
# KERNEL: stiffness_quad4_membrane_bending_hybrid_stress_matrices
# STATUS: RESEARCH / RETAINED - coupled membrane+bending hybrid stress.
#         Called by stiffness_quad4_huwashizu_matrices.
# =============================================================================
function stiffness_quad4_membrane_bending_hybrid_stress_matrices(coords, Cm, Cb, Bmb=nothing)
    C6 = zeros(6, 6)
    @inbounds for j in 1:3, i in 1:3
        C6[i, j] = Cm[i, j]
        C6[i + 3, j + 3] = Cb[i, j]
        if Bmb !== nothing
            C6[i, j + 3] = Bmb[i, j]
            C6[j + 3, i] = Bmb[i, j]
        end
    end
    maximum(abs, C6) < 1e-30 && return zeros(24, 24)

    S_inv = inv(C6)
    Ke = zeros(24, 24)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))

    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J0 = @SMatrix [
        dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]  dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2];
        dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]  dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    ]

    H = zeros(10, 10)
    G = zeros(10, 24)
    B6 = zeros(6, 24)
    P3 = zeros(3, 5)
    P6 = zeros(6, 10)
    tmp6x10 = zeros(6, 10)

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(B6, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            idx = (k - 1) * 6
            B6[1, idx + 1] = dN_dx
            B6[2, idx + 2] = dN_dy
            B6[3, idx + 1] = dN_dy
            B6[3, idx + 2] = dN_dx
            B6[4, idx + 5] = dN_dx
            B6[5, idx + 4] = -dN_dy
            B6[6, idx + 5] = dN_dy
            B6[6, idx + 4] = -dN_dx
        end

        fill!(P6, 0.0)
        quad4_hybrid_stress_modes!(P3, J0, xi, eta)
        for a in 1:5
            for r in 1:3
                P6[r, a] = P3[r, a]
                P6[r + 3, a + 5] = P3[r, a]
            end
        end
        ts_mul!(tmp6x10, S_inv, P6)
        ts_mul_At_add!(H, P6, tmp6x10, abs_detJ)
        ts_mul_At_add!(G, P6, B6, abs_detJ)
    end

    Ke .+= transpose(G) * (H \ G)
    return Ke
end

# =============================================================================
# KERNEL: stiffness_quad4_mitc_shear_drill_matrices
# STATUS: RESEARCH / RETAINED - standalone MITC4 shear + drilling block, used
#         as a building block in the Hu-Washizu chain.
# DISPATCHED FROM: stiffness_quad4_huwashizu_matrices.
# =============================================================================
function stiffness_quad4_mitc_shear_drill_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    shear_center_only::Bool=false,
    no_phi2::Bool=true,
)
    Ke = zeros(24, 24)
    maximum(abs, Cs) < 1e-30 && maximum(abs, Cm) < 1e-30 && return Ke

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
    Bs_tp = zeros(4, 24)
    Bs_row = zeros(24)

    @inbounds for tp_idx in 1:4
        xi_tp, eta_tp = tying_pts[tp_idx][1], tying_pts[tp_idx][2]
        dNr, dNs = shape_derivs_quad(xi_tp, eta_tp)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        N_tp = SVector(
            0.25*(1.0 - xi_tp)*(1.0 - eta_tp),
            0.25*(1.0 + xi_tp)*(1.0 - eta_tp),
            0.25*(1.0 + xi_tp)*(1.0 + eta_tp),
            0.25*(1.0 - xi_tp)*(1.0 + eta_tp),
        )
        fill!(Bs_row, 0.0)
        if tp_idx <= 2
            for k in 1:4
                idx = (k - 1) * 6
                Bs_row[idx + 3] = dNr[k]
                Bs_row[idx + 4] = -J12 * N_tp[k]
                Bs_row[idx + 5] =  J11 * N_tp[k]
            end
        else
            for k in 1:4
                idx = (k - 1) * 6
                Bs_row[idx + 3] = dNs[k]
                Bs_row[idx + 4] = -J22 * N_tp[k]
                Bs_row[idx + 5] =  J21 * N_tp[k]
            end
        end
        @views copyto!(Bs_tp[tp_idx, :], Bs_row)
    end

    dNr_c = SVector(-0.25, 0.25, 0.25, -0.25)
    dNs_c = SVector(-0.25, -0.25, 0.25, 0.25)
    J11c = dNr_c[1]*coords[1,1]+dNr_c[2]*coords[2,1]+dNr_c[3]*coords[3,1]+dNr_c[4]*coords[4,1]
    J12c = dNr_c[1]*coords[1,2]+dNr_c[2]*coords[2,2]+dNr_c[3]*coords[3,2]+dNr_c[4]*coords[4,2]
    J21c = dNs_c[1]*coords[1,1]+dNs_c[2]*coords[2,1]+dNs_c[3]*coords[3,1]+dNs_c[4]*coords[4,1]
    J22c = dNs_c[1]*coords[1,2]+dNs_c[2]*coords[2,2]+dNs_c[3]*coords[3,2]+dNs_c[4]*coords[4,2]
    detJc = J11c*J22c - J12c*J21c
    abs_detJc = max(abs(detJc), 1e-12)

    phi2_shear = 1.0
    if !shear_center_only && !no_phi2 && PHI2_ALPHA[] > 0.0 && maximum(abs, Cb) > 1e-30
        L_char_sq = max(4.0 * abs_detJc, 1e-30)
        phi2_shear = min(1.0, PHI2_ALPHA[] * h^2 / L_char_sq)
    end

    G_drill = Cm[3,3] / h
    if G_drill < 1e-6
        G_drill = E_ref / (2 * 3.0)
    end
    alpha_drill = drill_scale * (k6rot / 1e5) * G_drill * h

    Bs_cov = zeros(2, 24)
    Cs_cov = zeros(2, 2)
    tmp2x24 = zeros(2, 24)
    Bd = zeros(1, 24)

    function add_shear_at!(r::Float64, s::Float64, weight::Float64)
        dNr, dNs = shape_derivs_quad(r, s)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22*inv_det
        iJ12 = -J12*inv_det
        iJ21 = -J21*inv_det
        iJ22 = J11*inv_det

        w_eta_p = 0.5*(1.0+s)
        w_eta_m = 0.5*(1.0-s)
        w_xi_p = 0.5*(1.0+r)
        w_xi_m = 0.5*(1.0-r)
        fill!(Bs_cov, 0.0)
        for j in 1:24
            Bs_cov[1,j] = w_eta_m*Bs_tp[1,j] + w_eta_p*Bs_tp[2,j]
            Bs_cov[2,j] = w_xi_m*Bs_tp[3,j] + w_xi_p*Bs_tp[4,j]
        end

        t11 = Cs[1,1]*iJ11 + Cs[1,2]*iJ21
        t12 = Cs[1,1]*iJ12 + Cs[1,2]*iJ22
        t21 = Cs[2,1]*iJ11 + Cs[2,2]*iJ21
        t22 = Cs[2,1]*iJ12 + Cs[2,2]*iJ22
        Cs_cov[1,1] = phi2_shear*(iJ11*t11 + iJ21*t21)
        Cs_cov[1,2] = phi2_shear*(iJ11*t12 + iJ21*t22)
        Cs_cov[2,1] = phi2_shear*(iJ12*t11 + iJ22*t21)
        Cs_cov[2,2] = phi2_shear*(iJ12*t12 + iJ22*t22)
        ts_mul!(tmp2x24, Cs_cov, Bs_cov)
        ts_mul_At_add!(Ke, Bs_cov, tmp2x24, weight * abs_detJ)
        return nothing
    end

    if maximum(abs, Cs) >= 1e-30
        if shear_center_only
            add_shear_at!(0.0, 0.0, 4.0)
        else
            for gp in gauss_pts
                add_shear_at!(gp[1], gp[2], 1.0)
            end
        end
    end

    if alpha_drill != 0.0
        @inbounds for gp in gauss_pts
            r, s = gp[1], gp[2]
            dNr, dNs = shape_derivs_quad(r, s)
            J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
            J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
            J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
            J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
            detJ = J11*J22 - J12*J21
            abs_detJ = max(abs(detJ), 1e-12)
            inv_det = 1.0 / detJ
            iJ11 = J22*inv_det
            iJ12 = -J12*inv_det
            iJ21 = -J21*inv_det
            iJ22 = J11*inv_det
            fill!(Bd, 0.0)
            for k in 1:4
                dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
                dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
                N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
                idx = (k - 1) * 6
                Bd[1, idx + 1] = 0.5*dN_dy
                Bd[1, idx + 2] = -0.5*dN_dx
                Bd[1, idx + 6] = N_k
            end
            ts_mul_At_add!(Ke, Bd, Bd, abs_detJ * alpha_drill)
        end
    end

    return Ke
end

# =============================================================================
# KERNEL: stiffness_quad4_shear_hybrid_stress_matrices
# STATUS: RESEARCH / RETAINED - assumed-stress shear formulation. Used by the
#         Hu-Washizu shear-hybrid mode.
# =============================================================================
function stiffness_quad4_shear_hybrid_stress_matrices(coords, Cs)
    Ke = zeros(24, 24)
    maximum(abs, Cs) < 1e-30 && return Ke

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))

    area = 0.0
    xi_moment = 0.0
    eta_moment = 0.0
    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        dA = max(abs(J11*J22 - J12*J21), 1e-12)
        area += dA
        xi_moment += xi * dA
        eta_moment += eta * dA
    end
    xi_bar = xi_moment / max(area, 1e-30)
    eta_bar = eta_moment / max(area, 1e-30)

    S_inv = inv(Cs)
    H = zeros(4, 4)
    G = zeros(4, 24)
    Bs = zeros(2, 24)
    P = zeros(2, 4)
    tmp2x4 = zeros(2, 4)

    @inbounds for gp in gauss_pts
        xi, eta = gp[1], gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(Bs, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            N_k = 0.25*(1 + (k==2||k==3 ? xi : -xi))*(1 + (k>=3 ? eta : -eta))
            idx = (k - 1) * 6
            Bs[1, idx + 3] = dN_dx
            Bs[1, idx + 5] = N_k
            Bs[2, idx + 3] = dN_dy
            Bs[2, idx + 4] = -N_k
        end

        fill!(P, 0.0)
        P[1, 1] = 1.0
        P[2, 2] = 1.0
        P[1, 3] = eta - eta_bar
        P[2, 4] = xi - xi_bar
        ts_mul!(tmp2x4, S_inv, P)
        ts_mul_At_add!(H, P, tmp2x4, abs_detJ)
        ts_mul_At_add!(G, P, Bs, abs_detJ)
    end

    Ke .+= transpose(G) * (H \ G)
    return Ke
end

@inline function quad4_hw_shape_factor(coords)
    J11, J12, J21, J22 = quad4_center_jacobian_entries(coords)
    g11 = J11*J11 + J12*J12
    g12 = J11*J21 + J12*J22
    g22 = J21*J21 + J22*J22
    tr = g11 + g22
    disc = sqrt(max((g11 - g22)^2 + 4.0*g12^2, 0.0))
    lam_min = max(0.5 * (tr - disc), 1e-30)
    lam_max = max(0.5 * (tr + disc), lam_min)
    return sqrt(lam_max / lam_min)
end

@inline function quad4_center_jacobian_entries(coords)
    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J11 = dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]
    J12 = dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2]
    J21 = dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]
    J22 = dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    return J11, J12, J21, J22
end

@inline function quad4_hw_T0(J11::Float64, J12::Float64, J21::Float64, J22::Float64, a::Float64, b::Float64)
    return @SMatrix [
        J11*J11       J21*J21       a*J11*J21;
        J12*J12       J22*J22       a*J12*J22;
        b*J11*J12     b*J21*J22     J11*J22 + J12*J21
    ]
end

@inline function quad4_hw_Ttilde(J11::Float64, J12::Float64, J21::Float64, J22::Float64)
    return @SMatrix [
        J11 J21;
        J12 J22
    ]
end

@inline function quad4_constitutive_looks_isotropic(Cm, Cb, Cs, Bmb)
    Bmb !== nothing && maximum(abs, Bmb) > 1e-10 && return false
    cm_scale = max(maximum(abs, Cm), 1e-30)
    cb_scale = max(maximum(abs, Cb), 1e-30)
    cs_scale = max(maximum(abs, Cs), 1e-30)
    tol = 1e-6
    cm_iso =
        abs(Cm[1,1] - Cm[2,2]) <= tol * cm_scale &&
        abs(Cm[1,3]) <= tol * cm_scale &&
        abs(Cm[2,3]) <= tol * cm_scale &&
        abs(Cm[3,3] - 0.5*(Cm[1,1] - Cm[1,2])) <= 1e-5 * cm_scale
    cb_iso =
        cb_scale <= 1e-20 ||
        (
            abs(Cb[1,1] - Cb[2,2]) <= tol * cb_scale &&
            abs(Cb[1,3]) <= tol * cb_scale &&
            abs(Cb[2,3]) <= tol * cb_scale &&
            abs(Cb[3,3] - 0.5*(Cb[1,1] - Cb[1,2])) <= 1e-5 * cb_scale
        )
    cs_iso =
        abs(Cs[1,1] - Cs[2,2]) <= tol * cs_scale &&
        abs(Cs[1,2]) <= tol * cs_scale &&
        abs(Cs[2,1]) <= tol * cs_scale
    return cm_iso && cb_iso && cs_iso
end

@inline function quad4_coords3d_is_planar(coords_3d::AbstractMatrix)
    p1 = SVector{3,Float64}(coords_3d[1,1], coords_3d[1,2], coords_3d[1,3])
    p2 = SVector{3,Float64}(coords_3d[2,1], coords_3d[2,2], coords_3d[2,3])
    p3 = SVector{3,Float64}(coords_3d[3,1], coords_3d[3,2], coords_3d[3,3])
    p4 = SVector{3,Float64}(coords_3d[4,1], coords_3d[4,2], coords_3d[4,3])
    d21 = p2 - p1
    d31 = p3 - p1
    d41 = p4 - p1
    n = cross(d21, d31)
    nrm = norm(n)
    if nrm < 1e-24
        n = cross(d21, d41)
        nrm = norm(n)
    end
    nrm < 1e-24 && return true
    max_dev = max(abs(dot(d21, n)), abs(dot(d31, n)), abs(dot(d41, n))) / nrm
    L = max(norm(d21), norm(d31), norm(d41), 1e-12)
    return max_dev <= 1e-6 * L
end

# =============================================================================
# KERNEL: stiffness_quad4_huwashizu_full_matrices
# STATUS: RESEARCH / RETAINED — mixed Hu-Washizu variational formulation
#         (independent stress, strain, displacement fields). Theoretically a
#         strong cure for shear/volumetric locking; basis of high-performance
#         shell elements in TACS and similar codes. Tested 2026-05-22 as GAME
#         alternative → regressed (single calibration tried, not exhaustive).
#         Retained for future calibration work. DO NOT DELETE without revisiting.
# DISPATCHED FROM: stiffness_quad4_huwashizu_matrices when JFEM_Q4_KERNEL=huwashizu.
# CALIBRATION KNOBS: n_extra (mixed-mode count, default 11);
#         JFEM_Q4_HUWASHIZU_SHEAR_MODE ("hybrid"/"stress"/"huwashizu").
# CHAIN: this is the "full" HW. The dispatcher stiffness_quad4_huwashizu_matrices
#         wraps it and combines with MITC shear/drilling for the partial-HW path.
# =============================================================================
function stiffness_quad4_huwashizu_full_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    Bmb=nothing;
    n_extra::Int=11,
    k_extra::Int=0,
)
    C8 = zeros(8, 8)
    @inbounds for j in 1:3, i in 1:3
        C8[i, j] = Cm[i, j]
        C8[i + 3, j + 3] = Cb[i, j]
        if Bmb !== nothing
            C8[i, j + 3] = Bmb[i, j]
            C8[j + 3, i] = Bmb[i, j]
        end
    end
    @inbounds for j in 1:2, i in 1:2
        C8[i + 6, j + 6] = Cs[i, j]
    end
    maximum(abs, C8) < 1e-30 && return zeros(24, 24)

    n_use = clamp(n_extra, 0, 11)
    k_use = clamp(k_extra, 0, 6)
    nstrain = 14 + n_use + k_use
    hw_b_shear_mode = lowercase(strip(get(ENV, "JFEM_HW_B_SHEAR", "direct")))
    use_mitc_cov_shear = hw_b_shear_mode in ("mitc", "mitc_cov", "ans", "covariant")

    pt3 = sqrt(3.0 / 5.0)
    gauss_pts = (
        SVector(-pt3, -pt3, 25.0/81.0), SVector(0.0, -pt3, 40.0/81.0), SVector(pt3, -pt3, 25.0/81.0),
        SVector(-pt3,  0.0, 40.0/81.0), SVector(0.0,  0.0, 64.0/81.0), SVector(pt3,  0.0, 40.0/81.0),
        SVector(-pt3,  pt3, 25.0/81.0), SVector(0.0,  pt3, 40.0/81.0), SVector(pt3,  pt3, 25.0/81.0),
    )

    area = 0.0
    xi_moment = 0.0
    eta_moment = 0.0
    @inbounds for gp in gauss_pts
        xi, eta, wgt = gp[1], gp[2], gp[3]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        dA = wgt * max(abs(J11*J22 - J12*J21), 1e-12)
        area += dA
        xi_moment += xi * dA
        eta_moment += eta * dA
    end
    xi_bar = xi_moment / max(area, 1e-30)
    eta_bar = eta_moment / max(area, 1e-30)
    cshape = quad4_hw_shape_factor(coords)
    J11_0, J12_0, J21_0, J22_0 = quad4_center_jacobian_entries(coords)
    j0 = max(abs(J11_0*J22_0 - J12_0*J21_0), 1e-12)
    T_sigma = quad4_hw_T0(Float64(J11_0), Float64(J12_0), Float64(J21_0), Float64(J22_0), 2.0, 1.0)
    T_epsilon = quad4_hw_T0(Float64(J11_0), Float64(J12_0), Float64(J21_0), Float64(J22_0), 1.0, 2.0)
    T_tilde = quad4_hw_Ttilde(Float64(J11_0), Float64(J12_0), Float64(J21_0), Float64(J22_0))

    H = zeros(nstrain, nstrain)
    F = zeros(nstrain, 14)
    G = zeros(14, 24)
    B8 = zeros(8, 24)
    Nsig = zeros(8, 14)
    Neps = zeros(8, nstrain)
    tmp8xn = zeros(8, nstrain)
    Bs_tp_hw = zeros(4, 24)
    if use_mitc_cov_shear
        tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
        Bs_row_hw = zeros(24)
        @inbounds for tp_idx in 1:4
            xi_tp, eta_tp = tying_pts[tp_idx][1], tying_pts[tp_idx][2]
            dNr_tp, dNs_tp = shape_derivs_quad(xi_tp, eta_tp)
            J11_tp = dNr_tp[1]*coords[1,1] + dNr_tp[2]*coords[2,1] + dNr_tp[3]*coords[3,1] + dNr_tp[4]*coords[4,1]
            J12_tp = dNr_tp[1]*coords[1,2] + dNr_tp[2]*coords[2,2] + dNr_tp[3]*coords[3,2] + dNr_tp[4]*coords[4,2]
            J21_tp = dNs_tp[1]*coords[1,1] + dNs_tp[2]*coords[2,1] + dNs_tp[3]*coords[3,1] + dNs_tp[4]*coords[4,1]
            J22_tp = dNs_tp[1]*coords[1,2] + dNs_tp[2]*coords[2,2] + dNs_tp[3]*coords[3,2] + dNs_tp[4]*coords[4,2]
            N_tp = SVector(
                0.25*(1.0 - xi_tp)*(1.0 - eta_tp),
                0.25*(1.0 + xi_tp)*(1.0 - eta_tp),
                0.25*(1.0 + xi_tp)*(1.0 + eta_tp),
                0.25*(1.0 - xi_tp)*(1.0 + eta_tp),
            )
            fill!(Bs_row_hw, 0.0)
            if tp_idx <= 2
                for k in 1:4
                    idx = (k - 1) * 6
                    Bs_row_hw[idx + 3] = dNr_tp[k]
                    Bs_row_hw[idx + 4] = -J12_tp * N_tp[k]
                    Bs_row_hw[idx + 5] =  J11_tp * N_tp[k]
                end
            else
                for k in 1:4
                    idx = (k - 1) * 6
                    Bs_row_hw[idx + 3] = dNs_tp[k]
                    Bs_row_hw[idx + 4] = -J22_tp * N_tp[k]
                    Bs_row_hw[idx + 5] =  J21_tp * N_tp[k]
                end
            end
            @views copyto!(Bs_tp_hw[tp_idx, :], Bs_row_hw)
        end
    end

    @inbounds for gp in gauss_pts
        xi, eta, wgt = gp[1], gp[2], gp[3]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        dA = wgt * max(abs(detJ), 1e-12)
        jscale = j0 / max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(B8, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            N_k = 0.25*(1 + (k==2||k==3 ? xi : -xi))*(1 + (k>=3 ? eta : -eta))
            idx = (k - 1) * 6
            B8[1, idx + 1] = dN_dx
            B8[2, idx + 2] = dN_dy
            B8[3, idx + 1] = dN_dy
            B8[3, idx + 2] = dN_dx
            B8[4, idx + 5] = dN_dx
            B8[5, idx + 4] = -dN_dy
            B8[6, idx + 5] = dN_dy
            B8[6, idx + 4] = -dN_dx
            B8[7, idx + 3] = dN_dx
            B8[7, idx + 5] = N_k
            B8[8, idx + 3] = dN_dy
            B8[8, idx + 4] = -N_k
        end
        if use_mitc_cov_shear
            w_eta_p = 0.5*(1.0 + eta)
            w_eta_m = 0.5*(1.0 - eta)
            w_xi_p = 0.5*(1.0 + xi)
            w_xi_m = 0.5*(1.0 - xi)
            for j in 1:24
                B8[7, j] = w_eta_m*Bs_tp_hw[1, j] + w_eta_p*Bs_tp_hw[2, j]
                B8[8, j] = w_xi_m*Bs_tp_hw[3, j] + w_xi_p*Bs_tp_hw[4, j]
            end
        end

        fill!(Nsig, 0.0)
        for i in 1:8
            Nsig[i, i] = 1.0
        end
        Nmb_sigma_in = @SMatrix [
            eta - eta_bar  0.0;
            0.0            xi - xi_bar;
            0.0            0.0
        ]
        Ns_sigma_in = @SMatrix [
            eta - eta_bar  0.0;
            0.0            xi - xi_bar
        ]
        Nmb_sigma = T_sigma * Nmb_sigma_in
        Ns_sigma = T_tilde * Ns_sigma_in
        for a in 1:2
            for r0 in 1:3
                Nsig[r0, 8 + a] = Nmb_sigma[r0, a]
                Nsig[r0 + 3, 10 + a] = Nmb_sigma[r0, a]
            end
            for r0 in 1:2
                Nsig[r0 + 6, 12 + a] = Ns_sigma[r0, a]
            end
        end

        fill!(Neps, 0.0)
        for i in 1:8
            Neps[i, i] = 1.0
        end
        Nmb_epsilon = T_epsilon * Nmb_sigma_in
        Ns_epsilon = T_tilde * Ns_sigma_in
        for a in 1:2
            for r0 in 1:3
                Neps[r0, 8 + a] = Nmb_epsilon[r0, a]
                Neps[r0 + 3, 10 + a] = Nmb_epsilon[r0, a]
            end
            for r0 in 1:2
                Neps[r0 + 6, 12 + a] = Ns_epsilon[r0, a]
            end
        end
        col = 15
        if n_use > 0
            Mm_n = @SMatrix [
                xi  0.0 0.0 0.0 xi*eta 0.0    0.0    (xi^2 - cshape)*eta 0.0                       eta^2*xi 0.0;
                0.0 eta 0.0 0.0 0.0    xi*eta 0.0    0.0                    (eta^2 - cshape)*xi 0.0      xi^2*eta;
                0.0 0.0 xi  eta 0.0    0.0    xi*eta 0.0                    0.0                       0.0      0.0
            ]
            Mm_enriched = jscale .* (T_epsilon * Mm_n)
            for a in 1:n_use
                Neps[1, col] = Mm_enriched[1, a]
                Neps[2, col] = Mm_enriched[2, a]
                Neps[3, col] = Mm_enriched[3, a]
                col += 1
            end
        end
        if k_use > 0
            Mb_k = @SMatrix [
                xi  0.0 xi*eta 0.0    xi^2*eta 0.0;
                0.0 eta 0.0    xi*eta 0.0      eta^2*xi;
                0.0 0.0 0.0    0.0    0.0      0.0
            ]
            Mb_enriched = jscale .* (T_epsilon * Mb_k)
            for a in 1:k_use
                Neps[4, col] = Mb_enriched[1, a]
                Neps[5, col] = Mb_enriched[2, a]
                Neps[6, col] = Mb_enriched[3, a]
                col += 1
            end
        end

        ts_mul!(tmp8xn, C8, Neps)
        ts_mul_At_add!(H, Neps, tmp8xn, dA)
        ts_mul_At_add!(F, Neps, Nsig, -dA)
        ts_mul_At_add!(G, Nsig, B8, dA)
    end

    S_eff = transpose(F) * (H \ F)
    return transpose(G) * (S_eff \ G)
end

# =============================================================================
# KERNEL: stiffness_quad4_huwashizu_matrices
# STATUS: RESEARCH / RETAINED — Hu-Washizu dispatcher. Combines stiffness_quad4_huwashizu_full_matrices
#         (mixed full kernel) with MITC4 shear/drilling and hybrid-stress
#         add-ons. Reached only via JFEM_Q4_KERNEL=huwashizu (off by default).
# DISPATCHED FROM: stiffness_quad4_matrices line ~3154 when huwashizu_kernel.
# CALLS: stiffness_quad4_huwashizu_full_matrices, stiffness_quad4_mitc_shear_drill_matrices,
#         stiffness_quad4_membrane_bending_hybrid_stress_matrices,
#         stiffness_quad4_shear_hybrid_stress_matrices.
# CALIBRATION KNOBS: JFEM_Q4_HUWASHIZU_SHEAR_MODE, k6rot, drill_scale, Bmb.
# =============================================================================
function stiffness_quad4_huwashizu_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    shear_center_only::Bool=false,
    Bmb=nothing,
)
    hw_form = lowercase(strip(get(ENV, "JFEM_HW_FORM", "full")))
    hw_shear_mode = lowercase(strip(get(ENV, "JFEM_HW_SHEAR", "hybrid")))
    if hw_form in ("full", "wg", "wagner")
        n_raw = tryparse(Int, strip(get(ENV, "JFEM_HW_N", "11")))
        k_raw = tryparse(Int, strip(get(ENV, "JFEM_HW_K", "0")))
        Ke = stiffness_quad4_huwashizu_full_matrices(
            coords,
            Cm,
            Cb,
            Cs,
            Bmb;
            n_extra=n_raw === nothing ? 11 : n_raw,
            k_extra=k_raw === nothing ? 0 : k_raw,
        )
        Ke .+= stiffness_quad4_mitc_shear_drill_matrices(
            coords,
            Cm,
            Cb,
            zeros(eltype(Cs), 2, 2),
            h,
            E_ref;
            k6rot=k6rot,
            drill_scale=drill_scale,
            shear_center_only=shear_center_only,
            no_phi2=true,
        )
    else
        Ke = stiffness_quad4_membrane_bending_hybrid_stress_matrices(coords, Cm, Cb, Bmb)
        if hw_shear_mode in ("hybrid", "stress", "huwashizu")
            Ke .+= stiffness_quad4_shear_hybrid_stress_matrices(coords, Cs)
            Ke .+= stiffness_quad4_mitc_shear_drill_matrices(
                coords,
                Cm,
                Cb,
                zeros(eltype(Cs), 2, 2),
                h,
                E_ref;
                k6rot=k6rot,
                drill_scale=drill_scale,
                shear_center_only=shear_center_only,
                no_phi2=true,
            )
        else
            Ke .+= stiffness_quad4_mitc_shear_drill_matrices(
                coords,
                Cm,
                Cb,
                Cs,
                h,
                E_ref;
                k6rot=k6rot,
                drill_scale=drill_scale,
                shear_center_only=shear_center_only,
                no_phi2=true,
            )
        end
    end
    return Ke
end
