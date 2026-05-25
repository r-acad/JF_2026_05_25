# experimental/plate_kernels.jl
#
# Plate-mode CQUAD4 research kernels: Adini plate, DKQ plate, DKMQ plate
# (stiffness + geometric stiffness overloads), plus the shared
# add_quad4_membrane_translation_geometric! helper.
#
# RESEARCH only — none of these fire under default GAME SOL 105 routing.
# Reached only via JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ / _RECT_ADINI /
# _PLATE_BRANCH env knobs (all default false).
#
# Members:
#   adini_plate_interpolation_inverse
#   stiffness_quad4_plate_adini_matrices
#   geometric_stiffness_quad4_plate_adini (two overloads)
#   add_quad4_plate_dkq_bending!
#   stiffness_quad4_plate_dkq_matrices
#   stiffness_quad4_plate_dkmq_matrices
#   add_quad4_membrane_translation_geometric! (internal helper)
#   geometric_stiffness_quad4_plate_with_edge_relation
#   geometric_stiffness_quad4_plate_dkmq (two overloads)
#   geometric_stiffness_quad4_plate_dkq (two overloads)
#
# Moved out of FEMKernels.jl 2026-05-25 (phase C2/D1).

function adini_plate_interpolation_inverse(coords::AbstractMatrix)
    T = zeros(12, 12)
    @inbounds for a in 1:4
        x = coords[a, 1]
        y = coords[a, 2]
        row = (a - 1) * 3
        T[row + 1, :] .= adini_plate_basis(x, y)
        T[row + 2, :] .= adini_plate_basis_dx(x, y)
        T[row + 3, :] .= adini_plate_basis_dy(x, y)
    end
    try
        return inv(T)
    catch
        return nothing
    end
end

@inline function adini_plate_dof_transform()
    Tqp = zeros(12, 12)
    @inbounds for a in 1:4
        base = (a - 1) * 3
        Tqp[base + 1, base + 1] = 1.0
        Tqp[base + 2, base + 3] = 1.0
        Tqp[base + 3, base + 2] = -1.0
    end
    return Tqp
end

@inline function interp_2x2_gauss_sigma(sigma_mem_gp::AbstractMatrix, xi::Float64, eta::Float64)
    pt = 1.0 / sqrt(3.0)
    lx1 = (pt - xi) / (2.0 * pt)
    lx2 = (xi + pt) / (2.0 * pt)
    ly1 = (pt - eta) / (2.0 * pt)
    ly2 = (eta + pt) / (2.0 * pt)

    w1 = lx1 * ly1
    w2 = lx2 * ly1
    w3 = lx2 * ly2
    w4 = lx1 * ly2

    return SVector(
        w1 * sigma_mem_gp[1, 1] + w2 * sigma_mem_gp[2, 1] + w3 * sigma_mem_gp[3, 1] + w4 * sigma_mem_gp[4, 1],
        w1 * sigma_mem_gp[1, 2] + w2 * sigma_mem_gp[2, 2] + w3 * sigma_mem_gp[3, 2] + w4 * sigma_mem_gp[4, 2],
        w1 * sigma_mem_gp[1, 3] + w2 * sigma_mem_gp[2, 3] + w3 * sigma_mem_gp[3, 3] + w4 * sigma_mem_gp[4, 3],
    )
end

# =============================================================================
# KERNEL: stiffness_quad4_plate_adini_matrices
# STATUS: RESEARCH / RETAINED - classical Adini rectangular plate bending
#         element. Restricted to axis-aligned rectangles (falls back to DKQ
#         otherwise). Useful for purely rectangular thin-plate meshes.
# DISPATCHED FROM: assembly.jl when elem_rect_plate_branch (gated by
#         JFEM_SOL105_EIG_FLAT_PCOMP_RECT_ADINI, default false).
# Geometric counterpart: geometric_stiffness_quad4_plate_adini.
# =============================================================================
function stiffness_quad4_plate_adini_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    ws::Union{Nothing,Quad4Workspace}=nothing,
    membrane_incomp::Bool=true,
    curvature_membrane=nothing,
    membrane_shear_center_row::Bool=false,
    material_shear_rotation::Float64=0.0,
    membrane_assumed_mode::Symbol=:none,
)
    if !quad4_is_axis_aligned_rectangle(coords)
        return stiffness_quad4_plate_dkq_matrices(
            coords, Cm, Cb, Cs, h, E_ref;
            k6rot=k6rot,
            drill_scale=drill_scale,
            ws=ws,
            membrane_incomp=membrane_incomp,
            curvature_membrane=curvature_membrane,
            membrane_shear_center_row=membrane_shear_center_row,
            material_shear_rotation=material_shear_rotation,
            membrane_assumed_mode=membrane_assumed_mode,
        )
    end

    if ws === nothing
        ws = create_quad4_workspace()
    end

    Cb_zero = ws.Cb_buf
    Cs_zero = ws.Cs_buf
    fill!(Cb_zero, 0.0)
    fill!(Cs_zero, 0.0)

    Ke = stiffness_quad4_matrices(
        coords,
        Cm,
        Cb_zero,
        Cs_zero,
        h,
        E_ref;
        k6rot=k6rot,
        drill_scale=drill_scale,
        Bmb=nothing,
        ws=ws,
        bending_incomp=false,
        shear_center_only=true,
        no_phi2=true,
        membrane_incomp=membrane_incomp,
        curvature_membrane=curvature_membrane,
        membrane_shear_center_row=membrane_shear_center_row,
        material_shear_rotation=material_shear_rotation,
        membrane_assumed_mode=membrane_assumed_mode,
    )

    maximum(abs, Cb) < 1e-30 && return Ke

    T_inv = adini_plate_interpolation_inverse(coords)
    T_inv === nothing && return stiffness_quad4_plate_dkq_matrices(
        coords, Cm, Cb, Cs, h, E_ref;
        k6rot=k6rot,
        drill_scale=drill_scale,
        ws=ws,
        membrane_incomp=membrane_incomp,
        curvature_membrane=curvature_membrane,
        membrane_shear_center_row=membrane_shear_center_row,
        material_shear_rotation=material_shear_rotation,
        membrane_assumed_mode=membrane_assumed_mode,
    )

    x_min = minimum(view(coords, :, 1))
    x_max = maximum(view(coords, :, 1))
    y_min = minimum(view(coords, :, 2))
    y_max = maximum(view(coords, :, 2))
    x_mid = 0.5 * (x_min + x_max)
    y_mid = 0.5 * (y_min + y_max)
    hx = 0.5 * (x_max - x_min)
    hy = 0.5 * (y_max - y_min)
    if hx <= 1e-12 || hy <= 1e-12
        return stiffness_quad4_plate_dkq_matrices(
            coords, Cm, Cb, Cs, h, E_ref;
            k6rot=k6rot,
            drill_scale=drill_scale,
            ws=ws,
            membrane_incomp=membrane_incomp,
            curvature_membrane=curvature_membrane,
            membrane_shear_center_row=membrane_shear_center_row,
            material_shear_rotation=material_shear_rotation,
            membrane_assumed_mode=membrane_assumed_mode,
        )
    end

    quad_pts = (
        (-0.8611363115940526, 0.34785484513745385),
        (-0.33998104358485626, 0.6521451548625461),
        (0.33998104358485626, 0.6521451548625461),
        (0.8611363115940526, 0.34785484513745385),
    )

    Kq = zeros(12, 12)
    Bq = zeros(3, 12)
    tmp = zeros(3, 12)
    Tqp = adini_plate_dof_transform()

    @inbounds for (xi, wi) in quad_pts, (eta, wj) in quad_pts
        x = x_mid + hx * xi
        y = y_mid + hy * eta
        jac = hx * hy * wi * wj

        Bq[1, :] .= T_inv' * adini_plate_basis_dxx(x, y)
        Bq[2, :] .= T_inv' * adini_plate_basis_dyy(x, y)
        Bq[3, :] .= T_inv' * (2.0 .* adini_plate_basis_dxy(x, y))

        mul!(tmp, Cb, Bq)
        Kq .+= (Bq' * tmp) .* jac
    end

    Kplate = Tqp' * Kq * Tqp
    plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
    @inbounds for j in 1:12, i in 1:12
        Ke[plate_dofs[i], plate_dofs[j]] += Kplate[i, j]
    end

    return Ke
end

# =============================================================================
# KERNEL: geometric_stiffness_quad4_plate_adini (sigma_mem::Vector overload)
# STATUS: RESEARCH / RETAINED - Adini K_g counterpart, fires only when
#         elem_rect_plate_branch is active (dead under default).
# =============================================================================
function geometric_stiffness_quad4_plate_adini(coords::AbstractMatrix, sigma_mem::AbstractVector, h::Float64)
    sigma_gp = zeros(4, 3)
    @inbounds for gp in 1:4
        sigma_gp[gp, 1] = sigma_mem[1]
        sigma_gp[gp, 2] = sigma_mem[2]
        sigma_gp[gp, 3] = sigma_mem[3]
    end
    return geometric_stiffness_quad4_plate_adini(coords, sigma_gp, h)
end

# Per-GP stress field overload of the above. Same research status.
function geometric_stiffness_quad4_plate_adini(coords::AbstractMatrix, sigma_mem_gp::AbstractMatrix, h::Float64)
    Kg = zeros(24, 24)
    h < 1e-30 && return Kg
    quad4_is_axis_aligned_rectangle(coords) || return geometric_stiffness_quad4(
        coords, sigma_mem_gp, h;
        trans_mode=:normal_only,
        rot_grad_scale=0.0,
        membrane_shear_center_row=false,
    )

    T_inv = adini_plate_interpolation_inverse(coords)
    T_inv === nothing && return geometric_stiffness_quad4(
        coords, sigma_mem_gp, h;
        trans_mode=:normal_only,
        rot_grad_scale=0.0,
        membrane_shear_center_row=false,
    )

    x_min = minimum(view(coords, :, 1))
    x_max = maximum(view(coords, :, 1))
    y_min = minimum(view(coords, :, 2))
    y_max = maximum(view(coords, :, 2))
    x_mid = 0.5 * (x_min + x_max)
    y_mid = 0.5 * (y_min + y_max)
    hx = 0.5 * (x_max - x_min)
    hy = 0.5 * (y_max - y_min)
    if hx <= 1e-12 || hy <= 1e-12
        return Kg
    end

    quad_pts = (
        (-0.8611363115940526, 0.34785484513745385),
        (-0.33998104358485626, 0.6521451548625461),
        (0.33998104358485626, 0.6521451548625461),
        (0.8611363115940526, 0.34785484513745385),
    )

    Kq = zeros(12, 12)
    gx = zeros(12)
    gy = zeros(12)
    Tqp = adini_plate_dof_transform()

    @inbounds for (xi, wi) in quad_pts, (eta, wj) in quad_pts
        x = x_mid + hx * xi
        y = y_mid + hy * eta
        jac = hx * hy * wi * wj

        gx .= T_inv' * adini_plate_basis_dx(x, y)
        gy .= T_inv' * adini_plate_basis_dy(x, y)
        sigma = interp_2x2_gauss_sigma(sigma_mem_gp, xi, eta)
        s_xx = sigma[1]
        s_yy = sigma[2]
        s_xy = sigma[3]

        @inbounds for j in 1:12, i in 1:12
            Kq[i, j] += h * jac * (
                s_xx * gx[i] * gx[j] +
                s_yy * gy[i] * gy[j] +
                s_xy * (gx[i] * gy[j] + gy[i] * gx[j])
            )
        end
    end

    Kplate = Tqp' * Kq * Tqp
    plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
    @inbounds for j in 1:12, i in 1:12
        Kg[plate_dofs[i], plate_dofs[j]] += Kplate[i, j]
    end
    return Kg
end

# =============================================================================
# KERNEL: add_quad4_plate_dkq_bending!
# STATUS: RESEARCH / RETAINED - DKQ bending block, used as a building block
#         in plate_dkmq and plate_dkq kernels.
# =============================================================================
function add_quad4_plate_dkq_bending!(
    Ke::AbstractMatrix,
    coords,
    Cb,
    Cs,
    A_beta_override=nothing,
)
    maximum(abs, Cb) < 1e-30 && return Ke

    A_beta = isnothing(A_beta_override) ? first(dkq_plate_edge_relation(coords, Cb, Cs)) : A_beta_override
    Hct_inv = inv(Cs)
    Hbar = dkq_plate_hbar_matrix(Cb)

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
        edge_c = zeros(4)
        edge_s = zeros(4)
        for e in 1:4
            i, j = ((1, 2), (2, 3), (3, 4), (4, 1))[e]
            dx = coords[j, 1] - coords[i, 1]
            dy = coords[j, 2] - coords[i, 2]
            L = sqrt(dx * dx + dy * dy)
            if L > 1e-12
                edge_c[e] = dx / L
                edge_s[e] = dy / L
            end
        end
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

    Kplate = Kf11 .+ Kbb .+
             (Kf12 .+ Kba) * A_beta .+
             A_beta' * (Kf12' .+ Kba') .+
             A_beta' * (Kf22 .+ Kca) * A_beta

    plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
    @inbounds for j in 1:12, i in 1:12
        Ke[plate_dofs[i], plate_dofs[j]] += Kplate[i, j]
    end

    return Ke
end

# =============================================================================
# KERNEL: stiffness_quad4_plate_dkq_matrices
# STATUS: RESEARCH / RETAINED - classical Batoz DKQ flat-plate bending +
#         MITC shear + compatible membrane. Locking-free for thin plates by
#         construction. Useful for very thin flat composite laminates.
# DISPATCHED FROM: assembly.jl when elem_flat_plate_branch (gated by
#         JFEM_SOL105_EIG_FLAT_PCOMP_PLATE_BRANCH, default false).
# Geometric counterpart: geometric_stiffness_quad4_plate_dkq.
# =============================================================================
function stiffness_quad4_plate_dkq_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    ws::Union{Nothing,Quad4Workspace}=nothing,
    membrane_incomp::Bool=true,
    curvature_membrane=nothing,
    membrane_shear_center_row::Bool=false,
    material_shear_rotation::Float64=0.0,
    membrane_assumed_mode::Symbol=:none,
    )
    if ws === nothing
        ws = create_quad4_workspace()
    end

    Cb_zero = ws.Cb_buf
    Cs_zero = ws.Cs_buf
    fill!(Cb_zero, 0.0)
    fill!(Cs_zero, 0.0)

    Ke = stiffness_quad4_matrices(
        coords,
        Cm,
        Cb_zero,
        Cs_zero,
        h,
        E_ref;
        k6rot=k6rot,
        drill_scale=drill_scale,
        Bmb=nothing,
        ws=ws,
        bending_incomp=false,
        shear_center_only=true,
        no_phi2=true,
        membrane_incomp=membrane_incomp,
        curvature_membrane=curvature_membrane,
        membrane_shear_center_row=membrane_shear_center_row,
        material_shear_rotation=material_shear_rotation,
        membrane_assumed_mode=membrane_assumed_mode,
    )
    return add_quad4_plate_dkq_bending!(Ke, coords, Cb, Cs)
end

# =============================================================================
# KERNEL: stiffness_quad4_plate_dkmq_matrices
# STATUS: RESEARCH / RETAINED - DKMQ flat-plate (Batoz-Katili discrete Mindlin
#         quadrilateral). Same regime as DKQ but with explicit shear correction.
# DISPATCHED FROM: assembly.jl when elem_flat_dkmq_branch (gated by
#         JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ, default false).
# Geometric counterpart: geometric_stiffness_quad4_plate_dkmq.
# =============================================================================
function stiffness_quad4_plate_dkmq_matrices(
    coords,
    Cm,
    Cb,
    Cs,
    h,
    E_ref;
    k6rot=100.0,
    drill_scale::Float64=1.0,
    ws::Union{Nothing,Quad4Workspace}=nothing,
    membrane_incomp::Bool=true,
    curvature_membrane=nothing,
    membrane_shear_center_row::Bool=false,
    material_shear_rotation::Float64=0.0,
    membrane_assumed_mode::Symbol=:none,
)
    if ws === nothing
        ws = create_quad4_workspace()
    end

    Ke = stiffness_quad4_membrane_normal_rot_matrices(
        coords,
        Cm,
        h;
        curvature_membrane=curvature_membrane,
    )
    A_beta, _, _, _ = dkmq_flat_plate_edge_relation(coords, Cb, Cs)
    add_quad4_plate_dkmq_exact_shear!(Ke, coords, Cb, Cs, h)
    return add_quad4_plate_dkq_bending!(Ke, coords, Cb, Cs, A_beta)
end

# =============================================================================
# KERNEL: add_quad4_membrane_translation_geometric!
# STATUS: INTERNAL - geometric-stiffness membrane-translation block used by
#         the plate_dkq / plate_dkmq geometric stiffness variants.
# =============================================================================
function add_quad4_membrane_translation_geometric!(
    Kg::AbstractMatrix,
    coords::AbstractMatrix,
    sigma_mem_gp::AbstractMatrix,
    h::Float64,
)
    h < 1e-30 && return Kg

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (
        (SVector(-pt, -pt), 1),
        (SVector(pt, -pt), 2),
        (SVector(pt, pt), 3),
        (SVector(-pt, pt), 4),
    )

    @inbounds for (gp, gp_idx) in gauss_pts
        xi = gp[1]
        eta = gp[2]
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

        s_xx = sigma_mem_gp[gp_idx, 1]
        s_yy = sigma_mem_gp[gp_idx, 2]
        s_xy = sigma_mem_gp[gp_idx, 3]
        scale = h * abs_detJ
        for j in 1:4
            dNj_dx = iJ11 * dNr[j] + iJ12 * dNs[j]
            dNj_dy = iJ21 * dNr[j] + iJ22 * dNs[j]
            for i in 1:4
                dNi_dx = iJ11 * dNr[i] + iJ12 * dNs[i]
                dNi_dy = iJ21 * dNr[i] + iJ22 * dNs[i]
                val = scale * (
                    s_xx * dNi_dx * dNj_dx +
                    s_yy * dNi_dy * dNj_dy +
                    s_xy * (dNi_dx * dNj_dy + dNi_dy * dNj_dx)
                )
                bi = (i - 1) * 6
                bj = (j - 1) * 6
                Kg[bi + 1, bj + 1] += val
                Kg[bi + 2, bj + 2] += val
            end
        end
    end

    return Kg
end

# =============================================================================
# KERNEL: geometric_stiffness_quad4_plate_with_edge_relation
# STATUS: INTERNAL - shared core of plate_dkq + plate_dkmq geometric kernels.
#         Edge-relation projection unifies the two formulations.
# =============================================================================
function geometric_stiffness_quad4_plate_with_edge_relation(
    coords::AbstractMatrix,
    sigma_mem_gp::AbstractMatrix,
    h::Float64,
    A_beta::AbstractMatrix,
    edge_c::AbstractVector,
    edge_s::AbstractVector,
    include_membrane_translations::Bool=true,
)
    Kg = zeros(24, 24)
    h < 1e-30 && return Kg

    G_beta = zeros(2, 12)
    G_alpha = zeros(2, 4)
    G_eff = zeros(2, 12)
    K_plate = zeros(12, 12)
    plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (
        (SVector(-pt, -pt), 1),
        (SVector(pt, -pt), 2),
        (SVector(pt, pt), 3),
        (SVector(-pt, pt), 4),
    )

    @inbounds for (gp, gp_idx) in gauss_pts
        xi = gp[1]
        eta = gp[2]
        dNr, dNs = shape_derivs_quad(xi, eta)
        Nvals = SVector(
            0.25 * (1 - xi) * (1 - eta),
            0.25 * (1 + xi) * (1 - eta),
            0.25 * (1 + xi) * (1 + eta),
            0.25 * (1 - xi) * (1 + eta),
        )

        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11 * J22 - J12 * J21
        abs_detJ = abs(detJ)
        abs_detJ < 1e-12 && (abs_detJ = 1e-12)

        fill!(G_beta, 0.0)
        fill!(G_alpha, 0.0)
        for a in 1:4
            col = (a - 1) * 3
            G_beta[1, col + 3] = -Nvals[a]
            G_beta[2, col + 2] = Nvals[a]
        end

        P1 = 0.5 * (1.0 - eta) * (1.0 - xi^2)
        P2 = 0.5 * (1.0 + xi) * (1.0 - eta^2)
        P3 = 0.5 * (1.0 + eta) * (1.0 - xi^2)
        P4 = 0.5 * (1.0 - xi) * (1.0 - eta^2)
        Pvals = (P1, P2, P3, P4)
        for e in 1:4
            G_alpha[1, e] = -edge_c[e] * Pvals[e]
            G_alpha[2, e] = -edge_s[e] * Pvals[e]
        end

        copyto!(G_eff, G_beta)
        for e in 1:4
            for j in 1:12
                coeff = A_beta[e, j]
                if coeff != 0.0
                    G_eff[1, j] += G_alpha[1, e] * coeff
                    G_eff[2, j] += G_alpha[2, e] * coeff
                end
            end
        end

        s_xx = sigma_mem_gp[gp_idx, 1]
        s_yy = sigma_mem_gp[gp_idx, 2]
        s_xy = sigma_mem_gp[gp_idx, 3]
        @inbounds for j in 1:12, i in 1:12
            K_plate[i, j] += h * abs_detJ * (
                s_xx * G_eff[1, i] * G_eff[1, j] +
                s_yy * G_eff[2, i] * G_eff[2, j] +
                s_xy * (G_eff[1, i] * G_eff[2, j] + G_eff[2, i] * G_eff[1, j])
            )
        end
    end

    @inbounds for j in 1:12, i in 1:12
        Kg[plate_dofs[i], plate_dofs[j]] += K_plate[i, j]
    end
    if include_membrane_translations
        add_quad4_membrane_translation_geometric!(Kg, coords, sigma_mem_gp, h)
    end
    return Kg
end

# =============================================================================
# KERNEL: geometric_stiffness_quad4_plate_dkmq (sigma_mem::Vector overload)
# STATUS: RESEARCH / RETAINED - plate DKMQ K_g counterpart, fires only when
#         elem_flat_dkmq_branch is active (dead under default).
# =============================================================================
function geometric_stiffness_quad4_plate_dkmq(coords::AbstractMatrix, sigma_mem::AbstractVector, h::Float64,
                                              Cb::AbstractMatrix, Cs::AbstractMatrix)
    sigma_gp = zeros(4, 3)
    @inbounds for gp in 1:4
        sigma_gp[gp, 1] = sigma_mem[1]
        sigma_gp[gp, 2] = sigma_mem[2]
        sigma_gp[gp, 3] = sigma_mem[3]
    end
    return geometric_stiffness_quad4_plate_dkmq(coords, sigma_gp, h, Cb, Cs)
end

# Per-GP overload - same research status.
function geometric_stiffness_quad4_plate_dkmq(coords::AbstractMatrix, sigma_mem_gp::AbstractMatrix, h::Float64,
                                              Cb::AbstractMatrix, Cs::AbstractMatrix)
    if h < 1e-30 || maximum(abs, Cb) < 1e-30
        return zeros(24, 24)
    end
    A_beta, edge_c, edge_s, _ = dkmq_flat_plate_edge_relation(coords, Cb, Cs)
    return geometric_stiffness_quad4_plate_with_edge_relation(coords, sigma_mem_gp, h, A_beta, edge_c, edge_s)
end

# =============================================================================
# KERNEL: geometric_stiffness_quad4_plate_dkq (sigma_mem::Vector overload)
# STATUS: RESEARCH / RETAINED - plate DKQ K_g counterpart, fires only when
#         elem_flat_plate_branch is active (dead under default).
# =============================================================================
function geometric_stiffness_quad4_plate_dkq(coords::AbstractMatrix, sigma_mem::AbstractVector, h::Float64,
                                             Cb::AbstractMatrix, Cs::AbstractMatrix)
    sigma_gp = zeros(4, 3)
    @inbounds for gp in 1:4
        sigma_gp[gp, 1] = sigma_mem[1]
        sigma_gp[gp, 2] = sigma_mem[2]
        sigma_gp[gp, 3] = sigma_mem[3]
    end
    return geometric_stiffness_quad4_plate_dkq(coords, sigma_gp, h, Cb, Cs)
end

# Per-GP overload - same research status.
function geometric_stiffness_quad4_plate_dkq(coords::AbstractMatrix, sigma_mem_gp::AbstractMatrix, h::Float64,
                                             Cb::AbstractMatrix, Cs::AbstractMatrix)
    A_beta, edge_c, edge_s, _ = dkq_plate_edge_relation(coords, Cb, Cs)
    return geometric_stiffness_quad4_plate_with_edge_relation(coords, sigma_mem_gp, h, A_beta, edge_c, edge_s)
end
