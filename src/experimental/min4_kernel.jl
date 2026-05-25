# experimental/min4_kernel.jl
#
# Tessler-Hughes 1983 MIN4 anisoparametric Q4 plate bending + transverse
# shear. RESEARCH only — never default-on. Reached only via
# JFEM_Q4_KERNEL=min4 (default "macneal"). MYSTRAN-aligned formulation
# (Bill Case, MIT-licensed).
#
# Moved out of FEMKernels.jl 2026-05-25 as part of architectural cleanup
# (phase C2/D1 — quarantine research kernels out of the production hot
# path).

# ---------------------------------------------------------------------------
# Tessler-Hughes 1983 MIN4 — anisoparametric Q4 plate bending + transverse shear.
#
# Reference: A. Tessler & T.J.R. Hughes, "An Improved Treatment Of Transverse
# Shear In The Mindlin-Type Four-Node Quadrilateral Element", CMAME 39 (1983)
# pp 311-335. Also see MYSTRAN's QPLT2/MIN4SH/BBMIN4/BSMIN4/CALC_PHI_SQ
# (Bill Case, MIT-licensed open-source NASTRAN clone).
#
# Algorithm:
#   * w (out-of-plane) interpolated biquadratic-serendipity; mid-side w_5..w_8
#     are eliminated via "continuous shear edge constraint" (γ_sz),_s = 0.
#     Result: bilinear PSH for w plus enrichments NXSH, NYSH multiplying
#     the corner rotations.
#   * θx, θy interpolated bilinearly.
#   * Bending B-matrix uses ONLY [P],_x, [P],_y (no enrichment, eq 6.2).
#   * Shear B-matrix uses [P],_x/y on w and [Nx]/[Ny] enrichments + PSH on θ
#     (eqs 5.6, 6.2).
#   * Shear correction factor φ² = C_b·ψ̂/(1+C_b·ψ̂)  (eq 4.21)
#     ψ̂ = BENSUM/SHRSUM (ratio of bending to shear stiffness diagonals).
#     C_b is an element constant ~O(1); MYSTRAN uses 3.6 (env-overridable).
#   * φ² scales ONLY the transverse-shear block, leaving Kb untouched.
#
# This function returns ONLY the bending + (φ²·shear) contributions to the
# 24×24 element matrix, embedded at the (uz, rx, ry) DOFs of each node. The
# caller is responsible for combining with a membrane+drilling kernel.
# Membrane/drilling can be obtained by calling stiffness_quad4_matrices with
# Cb=0, Cs=0.
# ---------------------------------------------------------------------------
# =============================================================================
# KERNEL: stiffness_quad4_min4_bending_shear
# STATUS: RESEARCH / RETAINED - Tessler-Hughes 1983 MIN4 anisoparametric
#         bending+shear (biquadratic w + bilinear theta, eq 4.21 phi^2). Used when
#         JFEM_Q4_KERNEL=min4 (off by default). MYSTRAN-aligned formulation.
# CALIBRATION KNOBS: JFEM_MIN4_CBMIN4 (default 3.6).
# =============================================================================
function stiffness_quad4_min4_bending_shear(
    coords::AbstractMatrix{Float64},
    Cb::AbstractMatrix{Float64},
    Cs::AbstractMatrix{Float64};
    cbmin4::Float64 = 3.6,
    iord_bending::Int = 2,
    iord_shear::Int = 3,
)
    # Side differences: XSD[i] = X[i] - X[i+1] (i=1..4, wrap at 4→1).
    # Matches MYSTRAN convention (BD_CQUAD computes XSD/YSD that way; see JAC2D).
    X1, X2, X3, X4 = coords[1,1], coords[2,1], coords[3,1], coords[4,1]
    Y1, Y2, Y3, Y4 = coords[1,2], coords[2,2], coords[3,2], coords[4,2]
    XSD = SVector(X1 - X2, X2 - X3, X3 - X4, X4 - X1)
    YSD = SVector(Y1 - Y2, Y2 - Y3, Y3 - Y4, Y4 - Y1)

    # Gauss quadrature points and weights
    function gauss_1d(n::Int)
        if n == 2
            g = 1.0 / sqrt(3.0)
            return SVector(-g, g), SVector(1.0, 1.0)
        elseif n == 3
            g = sqrt(3.0/5.0)
            return SVector(-g, 0.0, g), SVector(5.0/9.0, 8.0/9.0, 5.0/9.0)
        else
            error("Unsupported Gauss order: $n (expected 2 or 3)")
        end
    end
    gp_b, gw_b = gauss_1d(iord_bending)
    gp_s, gw_s = gauss_1d(iord_shear)

    # Helpers: at given (ssi, ssj) return PSH, DPSHX, DNXSHX, DNYSHX, DETJ
    function shape_data(ssi::Float64, ssj::Float64)
        # Bilinear shapes and ξ,η-derivatives
        PSH = SVector(
            0.25*(1.0 - ssi)*(1.0 - ssj),
            0.25*(1.0 + ssi)*(1.0 - ssj),
            0.25*(1.0 + ssi)*(1.0 + ssj),
            0.25*(1.0 - ssi)*(1.0 + ssj),
        )
        DPSHG = @SMatrix [
            -0.25*(1.0 - ssj)   0.25*(1.0 - ssj)   0.25*(1.0 + ssj)  -0.25*(1.0 + ssj);
            -0.25*(1.0 - ssi)  -0.25*(1.0 + ssi)   0.25*(1.0 + ssi)   0.25*(1.0 - ssi)
        ]
        # Jacobian (MYSTRAN JAC2D convention)
        J11 = (-(1.0 - ssj)*XSD[1] + (1.0 + ssj)*XSD[3]) / 4.0
        J12 = (-(1.0 - ssj)*YSD[1] + (1.0 + ssj)*YSD[3]) / 4.0
        J21 = ( (1.0 - ssi)*XSD[4] - (1.0 + ssi)*XSD[2]) / 4.0
        J22 = ( (1.0 - ssi)*YSD[4] - (1.0 + ssi)*YSD[2]) / 4.0
        DETJ = J11*J22 - J12*J21
        inv_detj = 1.0 / DETJ
        # Inverse Jacobian
        JI11 =  J22 * inv_detj
        JI12 = -J12 * inv_detj
        JI21 = -J21 * inv_detj
        JI22 =  J11 * inv_detj
        JI = @SMatrix [JI11 JI12; JI21 JI22]
        DPSHX = JI * DPSHG
        # Tessler-Hughes constrained shapes NXSH, NYSH from MIN4SH:
        # virgin midside biquadratic shapes N5..N8
        XM  = 1.0 - ssi
        XP  = 1.0 + ssi
        YM  = 1.0 - ssj
        YP  = 1.0 + ssj
        X2M = 1.0 - ssi*ssi
        Y2M = 1.0 - ssj*ssj
        N5  = X2M*YM/2.0
        N6  = Y2M*XP/2.0
        N7  = X2M*YP/2.0
        N8  = Y2M*XM/2.0
        N5X = -ssi*YM;   N6X = Y2M/2.0;   N7X = -ssi*YP;  N8X = -Y2M/2.0
        N5Y = -X2M/2.0;  N6Y = -ssj*XP;   N7Y = X2M/2.0;  N8Y = -ssj*XM
        NXSH = SVector(
            (-YSD[4]*N8 + YSD[1]*N5)/8.0,
            (-YSD[1]*N5 + YSD[2]*N6)/8.0,
            (-YSD[2]*N6 + YSD[3]*N7)/8.0,
            (-YSD[3]*N7 + YSD[4]*N8)/8.0,
        )
        NYSH = SVector(
            (-XSD[4]*N8 + XSD[1]*N5)/8.0,
            (-XSD[1]*N5 + XSD[2]*N6)/8.0,
            (-XSD[2]*N6 + XSD[3]*N7)/8.0,
            (-XSD[3]*N7 + XSD[4]*N8)/8.0,
        )
        DNXSHG = @SMatrix [
            (-YSD[4]*N8X + YSD[1]*N5X)/8.0  (-YSD[1]*N5X + YSD[2]*N6X)/8.0  (-YSD[2]*N6X + YSD[3]*N7X)/8.0  (-YSD[3]*N7X + YSD[4]*N8X)/8.0;
            (-YSD[4]*N8Y + YSD[1]*N5Y)/8.0  (-YSD[1]*N5Y + YSD[2]*N6Y)/8.0  (-YSD[2]*N6Y + YSD[3]*N7Y)/8.0  (-YSD[3]*N7Y + YSD[4]*N8Y)/8.0
        ]
        DNYSHG = @SMatrix [
            (-XSD[4]*N8X + XSD[1]*N5X)/8.0  (-XSD[1]*N5X + XSD[2]*N6X)/8.0  (-XSD[2]*N6X + XSD[3]*N7X)/8.0  (-XSD[3]*N7X + XSD[4]*N8X)/8.0;
            (-XSD[4]*N8Y + XSD[1]*N5Y)/8.0  (-XSD[1]*N5Y + XSD[2]*N6Y)/8.0  (-XSD[2]*N6Y + XSD[3]*N7Y)/8.0  (-XSD[3]*N7Y + XSD[4]*N8Y)/8.0
        ]
        DNXSHX = JI * DNXSHG
        DNYSHX = JI * DNYSHG
        return PSH, DPSHX, DNXSHX, DNYSHX, DETJ
    end

    # --- Bending stiffness Kb (8×8) ---
    Kb = MMatrix{8, 8, Float64}(zeros(8, 8))
    Cb_static = SMatrix{3, 3, Float64}(Cb)
    for i in eachindex(gp_b)
        for j in eachindex(gp_b)
            PSH, DPSHX, _, _, DETJ = shape_data(gp_b[i], gp_b[j])
            # BBMIN4: 3×8 bending B (DOFs per node: θx, θy)
            BB = MMatrix{3, 8, Float64}(zeros(3, 8))
            @inbounds for jj in 1:4
                col_tx = 2*jj - 1
                col_ty = 2*jj
                BB[1, col_tx] = 0.0
                BB[2, col_tx] = -DPSHX[2, jj]
                BB[3, col_tx] = -DPSHX[1, jj]
                BB[1, col_ty] =  DPSHX[1, jj]
                BB[2, col_ty] =  0.0
                BB[3, col_ty] =  DPSHX[2, jj]
            end
            intfac = DETJ * gw_b[i] * gw_b[j]
            BB_static = SMatrix{3, 8, Float64}(BB)
            Kb .+= intfac .* (transpose(BB_static) * Cb_static * BB_static)
        end
    end

    # --- Shear stiffness Ks (12×12) ---
    Ks = MMatrix{12, 12, Float64}(zeros(12, 12))
    Cs_static = SMatrix{2, 2, Float64}(Cs)
    for i in eachindex(gp_s)
        for j in eachindex(gp_s)
            PSH, DPSHX, DNXSHX, DNYSHX, DETJ = shape_data(gp_s[i], gp_s[j])
            # BSMIN4: 2×12 shear B (DOFs per node: uz, θx, θy)
            BS = MMatrix{2, 12, Float64}(zeros(2, 12))
            @inbounds for jj in 1:4
                col_uz = 3*jj - 2
                col_tx = 3*jj - 1
                col_ty = 3*jj
                BS[1, col_uz] =  DPSHX[1, jj]
                BS[2, col_uz] =  DPSHX[2, jj]
                BS[1, col_tx] = -DNXSHX[1, jj]
                BS[2, col_tx] = -DNXSHX[2, jj] - PSH[jj]
                BS[1, col_ty] =  DNYSHX[1, jj] + PSH[jj]
                BS[2, col_ty] =  DNYSHX[2, jj]
            end
            intfac = DETJ * gw_s[i] * gw_s[j]
            BS_static = SMatrix{2, 12, Float64}(BS)
            Ks .+= intfac .* (transpose(BS_static) * Cs_static * BS_static)
        end
    end

    # φ² shear correction
    bensum = 0.0
    @inbounds for k in 1:8
        bensum += Kb[k, k]
    end
    # Shear diagonal rotation DOFs only: positions 2,3,5,6,8,9,11,12
    shrsum = Ks[2,2] + Ks[3,3] + Ks[5,5] + Ks[6,6] + Ks[8,8] + Ks[9,9] + Ks[11,11] + Ks[12,12]
    if abs(shrsum) < 1e-30
        phi_sq = 1.0
    else
        psi_hat = bensum / shrsum
        phi_sq  = cbmin4 * psi_hat / (1.0 + cbmin4 * psi_hat)
    end

    # Embed into 24×24 (JFEM DOF order [ux,uy,uz,rx,ry,rz] per node).
    # Bending DOFs: rx, ry of each node → 4,5,10,11,16,17,22,23
    # Shear DOFs: uz, rx, ry of each node → 3,4,5,9,10,11,15,16,17,21,22,23
    IDB = SVector{8,Int}(4, 5, 10, 11, 16, 17, 22, 23)
    IDS = SVector{12,Int}(3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
    Ke = zeros(24, 24)
    @inbounds for j in 1:8, i in 1:8
        Ke[IDB[i], IDB[j]] += Kb[i, j]
    end
    @inbounds for j in 1:12, i in 1:12
        Ke[IDS[i], IDS[j]] += phi_sq * Ks[i, j]
    end

    return Ke, bensum, shrsum, phi_sq
end
