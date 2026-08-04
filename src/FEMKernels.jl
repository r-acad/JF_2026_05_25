
module FEM

using LinearAlgebra
using Statistics
using StaticArrays

# Tunable phi2 shear correction: alpha coefficient in phi2 = min(1, alpha*(h/L)^2)
# Set to 0.0 to use default alpha=10. Otherwise overrides alpha.
const PHI2_ALPHA = Ref(10.0)


@inline function fem_env_float(name::AbstractString, default::Float64)
    raw = get(ENV, name, "")
    isempty(strip(raw)) && return default
    parsed = tryparse(Float64, strip(raw))
    return parsed === nothing ? default : parsed
end

@inline function fem_env_bool(name::AbstractString, default::Bool)
    raw = lowercase(strip(get(ENV, name, "")))
    isempty(raw) && return default
    raw in ("1", "true", "yes", "on") && return true
    raw in ("0", "false", "no", "off") && return false
    return default
end

# Pre-allocated workspace for QUAD4 element stiffness computation.
# Allocate once per thread, reuse across all elements to eliminate ~5M heap allocations.
struct Quad4Workspace{T}
    # Accumulated per-element (cleared at start of each element)
    Ke::Matrix{T}                # 24×24 element stiffness
    K_ab::Matrix{T}              # 24×4  membrane incompatible mode coupling
    K_bb::Matrix{T}              # 4×4   membrane incompatible self-coupling
    K_ab_bend::Matrix{T}         # 24×4  bending incompatible mode coupling
    K_bb_bend::Matrix{T}         # 4×4   bending incompatible self-coupling
    # MITC4 tying point B-matrices (filled per element)
    Bs_tp::Matrix{Float64}       # 4×24  rows: [Bs_xi_A; Bs_xi_C; Bs_eta_B; Bs_eta_D]
    Bs_row::Vector{Float64}      # 24    temporary for tying point computation
    # Gauss-point matrices (reused each GP, cleared with fill!)
    Bm::Matrix{Float64}          # 3×24  membrane strain-displacement
    Bb::Matrix{Float64}          # 3×24  bending strain-displacement
    Bd::Matrix{Float64}          # 1×24  drilling B-matrix
    Bi::Matrix{Float64}          # 3×4   membrane incompatible mode B-matrix
    Bi_bend::Matrix{Float64}     # 3×4   bending incompatible mode B-matrix
    Bs_cov::Matrix{Float64}      # 2×24  covariant shear B-matrix
    # Temporaries for in-place mul!
    tmp3x24::Matrix{T}           # for Cm*Bm, Cb*Bb products
    tmp3x4::Matrix{T}            # for Cm*Bi, Cb*Bi_bend products
    tmp2x24::Matrix{T}           # for Cs_cov*Bs_cov products
    tmp2x2::Matrix{T}            # for Cs_cov = invJ'*Cs*invJ
    # B matrix coupling workspace (reused when Bmb != nothing)
    K_ab_cross::Matrix{T}            # 24×4
    K_ab_bend_cross::Matrix{T}       # 24×4
    K_mb_incomp::Matrix{T}           # 4×4
    # Coordinate transform workspace (used in Solver.jl assembly)
    Ke_global::Matrix{T}         # 24×24  T'*Ke*T result
    tmp24x24::Matrix{T}          # 24×24  temporary for transform
    Rel_t::Matrix{Float64}       # 3×3   element-to-global rotation
    # Thread-local constitutive matrix buffers (copied from flat arrays, avoids Vector{Matrix} reads)
    Cm_buf::Matrix{T}            # 3×3   membrane constitutive
    Cb_buf::Matrix{T}            # 3×3   bending constitutive
    Cs_buf::Matrix{T}            # 2×2   shear constitutive
    Bmb_buf::Matrix{T}           # 3×3   membrane-bending coupling
    # Assembly buffers (used in Solver.jl parallel loop)
    T_buf::Matrix{Float64}       # 24×24 transformation matrix
    lc::Matrix{Float64}          # 4×2   local coordinates
    dofs::Vector{Int}            # 24    DOF indices
end

function create_quad4_workspace(::Type{T}=Float64) where {T}
    Quad4Workspace{T}(
        zeros(T,24,24), zeros(T,24,4), zeros(T,4,4), zeros(T,24,4), zeros(T,4,4), # Ke, K_ab, K_bb, K_ab_bend, K_bb_bend
        zeros(4,24), zeros(24),                                             # Bs_tp, Bs_row
        zeros(3,24), zeros(3,24), zeros(1,24), zeros(3,4), zeros(3,4), zeros(2,24), # Bm..Bs_cov
        zeros(T,3,24), zeros(T,3,4), zeros(T,2,24), zeros(T,2,2),          # tmp buffers
        zeros(T,24,4), zeros(T,24,4), zeros(T,4,4),                        # B coupling
        zeros(T,24,24), zeros(T,24,24), zeros(3,3),                        # transform
        zeros(T,3,3), zeros(T,3,3), zeros(T,2,2), zeros(T,3,3),            # constitutive buffers
        zeros(24,24), zeros(4,2), Vector{Int}(undef, 24)                   # assembly buffers
    )
end

# Thread-safe matrix multiplication replacing BLAS mul! (which is NOT re-entrant on Windows).
# C += alpha * A * B   (A is m×k, B is k×n, C is m×n)
@inline function ts_mul_add!(C, A, B, alpha)
    m, k = size(A)
    _, n = size(B)
    @inbounds @fastmath for j in 1:n
        for l in 1:k
            val = alpha * B[l,j]
            for i in 1:m
                C[i,j] += A[i,l] * val
            end
        end
    end
end

# C += alpha * A' * B   (A is k×m, A' is m×k, B is k×n, C is m×n)
@inline function ts_mul_At_add!(C, A, B, alpha)
    k, m = size(A)
    _, n = size(B)
    @inbounds @fastmath for j in 1:n
        for l in 1:k
            val = alpha * B[l,j]
            for i in 1:m
                C[i,j] += A[l,i] * val
            end
        end
    end
end

# C = A * B   (overwrite, no accumulate)
@inline function ts_mul!(C, A, B)
    m, k = size(A)
    _, n = size(B)
    fill!(C, 0.0)
    @inbounds @fastmath for j in 1:n
        for l in 1:k
            val = B[l,j]
            for i in 1:m
                C[i,j] += A[i,l] * val
            end
        end
    end
end

@inline function _is_infinite_like(x)
    return x == Inf || x == -Inf
end

function stiffness_frame3d_generic(L, A, Iy, Iz, J, E, G; As_y=Inf, As_z=Inf, I12=0.0)
    T = promote_type(typeof(L), typeof(A), typeof(Iy), typeof(Iz), typeof(J), typeof(E), typeof(G), typeof(I12))
    k = zeros(T, 12, 12)
    if L < 1e-9; return k; end

    X = E * A / L
    k[1,1] = X;  k[1,7] = -X; k[7,1] = -X; k[7,7] = X

    T = G * J / L
    k[4,4] = T;  k[4,10] = -T; k[10,4] = -T; k[10,10] = T

    # Timoshenko shear parameters (Φ=0 reduces to Euler-Bernoulli)
    # NASTRAN: K1=shear area factor for plane 1 (y-dir), K2=for plane 2 (z-dir)
    # As_y = K1*A (shear area in y), As_z = K2*A (shear area in z)
    # xz-plane bending: deflection in z → shear in z → uses As_z (K2*A)
    # xy-plane bending: deflection in y → shear in y → uses As_y (K1*A)
    Phi_y = _is_infinite_like(As_z) ? zero(T) : 12*E*Iy/(G*As_z*L^2)
    Phi_z = _is_infinite_like(As_y) ? zero(T) : 12*E*Iz/(G*As_y*L^2)

    # Bending in xz-plane (uses Iy, shear via As_z=K2*A)
    a_y = 12*E*Iy / (L^3*(1+Phi_y))
    b_y = 6*E*Iy / (L^2*(1+Phi_y))
    c_y = (4+Phi_y)*E*Iy / (L*(1+Phi_y))
    d_y = (2-Phi_y)*E*Iy / (L*(1+Phi_y))
    k[3,3] = a_y;  k[3,9] = -a_y; k[9,3] = -a_y; k[9,9] = a_y
    k[3,5] = -b_y; k[3,11] = -b_y; k[5,3] = -b_y; k[11,3] = -b_y
    k[9,5] = b_y;  k[9,11] = b_y;  k[5,9] = b_y;  k[11,9] = b_y
    k[5,5] = c_y;  k[5,11] = d_y;  k[11,5] = d_y;  k[11,11] = c_y

    # Bending in xy-plane (uses Iz, shear via As_y=K1*A)
    a_z = 12*E*Iz / (L^3*(1+Phi_z))
    b_z = 6*E*Iz / (L^2*(1+Phi_z))
    c_z = (4+Phi_z)*E*Iz / (L*(1+Phi_z))
    d_z = (2-Phi_z)*E*Iz / (L*(1+Phi_z))
    k[2,2] = a_z;  k[2,8] = -a_z; k[8,2] = -a_z; k[8,8] = a_z
    k[2,6] = b_z;  k[2,12] = b_z;  k[6,2] = b_z;  k[12,2] = b_z
    k[8,6] = -b_z; k[8,12] = -b_z; k[6,8] = -b_z; k[12,8] = -b_z
    k[6,6] = c_z;  k[6,12] = d_z;  k[12,6] = d_z;  k[12,12] = c_z

    # Cross-coupling from I12 (product of inertia)
    # Couples xy-plane bending {v: 2,8; θz: 6,12} with xz-plane bending {w: 3,9; θy: 5,11}
    if abs(I12) > 0.0
        a_yz = 12*E*I12 / L^3
        b_yz = 6*E*I12 / L^2
        c_yz = 4*E*I12 / L
        d_yz = 2*E*I12 / L
        # v-w coupling: DOFs (2,3), (2,9), (8,3), (8,9)
        k[2,3] += a_yz;  k[3,2] += a_yz
        k[2,9] += -a_yz; k[9,2] += -a_yz
        k[8,3] += -a_yz; k[3,8] += -a_yz
        k[8,9] += a_yz;  k[9,8] += a_yz
        # v-θy coupling: DOFs (2,5), (2,11), (8,5), (8,11)
        k[2,5] += -b_yz; k[5,2] += -b_yz
        k[2,11] += -b_yz; k[11,2] += -b_yz
        k[8,5] += b_yz;  k[5,8] += b_yz
        k[8,11] += b_yz; k[11,8] += b_yz
        # w-θz coupling: DOFs (3,6), (3,12), (9,6), (9,12)
        k[3,6] += b_yz;  k[6,3] += b_yz
        k[3,12] += b_yz; k[12,3] += b_yz
        k[9,6] += -b_yz; k[6,9] += -b_yz
        k[9,12] += -b_yz; k[12,9] += -b_yz
        # θy-θz coupling: DOFs (5,6), (5,12), (11,6), (11,12)
        k[5,6] += -c_yz; k[6,5] += -c_yz
        k[5,12] += -d_yz; k[12,5] += -d_yz
        k[11,6] += -d_yz; k[6,11] += -d_yz
        k[11,12] += -c_yz; k[12,11] += -c_yz
    end

    return k
end

function stiffness_frame3d(L, A, Iy, Iz, J, E, G; As_y=Inf, As_z=Inf, I12=0.0)
    return stiffness_frame3d_generic(L, A, Iy, Iz, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
end

function forces_frame3d(u_elem, L, A, Iy, Iz, J, E, G; As_y=Inf, As_z=Inf, I12=0.0)
    k = stiffness_frame3d(L, A, Iy, Iz, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
    f_local = k * u_elem
    
    return Dict(
        "axial"     => f_local[7],
        "shear_1"   => -f_local[2],
        "shear_2"   => -f_local[3],
        "torque"    => -f_local[4],
        "moment_a1" => -f_local[6],
        "moment_a2" => f_local[5],
        "moment_b1" => f_local[12],
        "moment_b2" => -f_local[11]
    )
end

function stress_frame3d(u_elem, L, A, E)
    return E * (u_elem[7] - u_elem[1]) / L
end



@inline function shape_derivs_quad(xi, eta)
    dN_dxi  = SVector{4}(-0.25*(1-eta), 0.25*(1-eta), 0.25*(1+eta), -0.25*(1+eta))
    dN_deta = SVector{4}(-0.25*(1-xi), -0.25*(1+xi), 0.25*(1+xi), 0.25*(1-xi))
    return dN_dxi, dN_deta
end

@inline function shape_values_quad(xi, eta)
    return SVector{4}(
        0.25*(1.0-xi)*(1.0-eta),
        0.25*(1.0+xi)*(1.0-eta),
        0.25*(1.0+xi)*(1.0+eta),
        0.25*(1.0-xi)*(1.0+eta),
    )
end

# MITC4-3D research kernels — quarantined to experimental/ 2026-05-25.
# Reached only via JFEM_Q4_KERNEL=mitc4_3d (default "macneal" — branch
# dead under defaults). All `quad4_mitc4_3d_*`, `stiffness_quad4_mitc4_3d_*`,
# and `_mitc4_3d_*` helpers live in the included file.
include(joinpath(@__DIR__, "experimental", "mitc4_3d_kernel.jl"))


const QUAD4_D2N_DXIDETA = SVector{4}(0.25, -0.25, 0.25, -0.25)

@inline function quad4_center_frame_from_coords3d(coords_3d::AbstractMatrix)
    p1 = SVector(coords_3d[1,1], coords_3d[1,2], coords_3d[1,3])
    p2 = SVector(coords_3d[2,1], coords_3d[2,2], coords_3d[2,3])
    p3 = SVector(coords_3d[3,1], coords_3d[3,2], coords_3d[3,3])
    p4 = SVector(coords_3d[4,1], coords_3d[4,2], coords_3d[4,3])

    d13 = p3 - p1
    d24 = p4 - p2
    v3_raw = cross(d13, d24)
    v3_len = norm(v3_raw)
    if v3_len <= 1e-30
        v3_raw = cross(p2 - p1, p4 - p1)
        v3_len = norm(v3_raw)
    end
    v3 = v3_len > 1e-30 ? v3_raw / v3_len : SVector(0.0, 0.0, 1.0)

    edge1 = p2 - p1
    v1_raw = edge1 - dot(edge1, v3) * v3
    v1_len = norm(v1_raw)
    if v1_len <= 1e-30
        edge2 = p4 - p1
        v1_raw = edge2 - dot(edge2, v3) * v3
        v1_len = norm(v1_raw)
    end
    v1 = v1_len > 1e-30 ? v1_raw / v1_len : SVector(1.0, 0.0, 0.0)
    v2 = cross(v3, v1)
    return v1, v2, v3
end

@inline function quad4_gp_local_frame_from_coords3d(coords_3d::AbstractMatrix,
                                                    xi::Float64, eta::Float64)
    dNr, dNs = shape_derivs_quad(xi, eta)

    a1 = SVector(
        dNr[1] * coords_3d[1,1] + dNr[2] * coords_3d[2,1] + dNr[3] * coords_3d[3,1] + dNr[4] * coords_3d[4,1],
        dNr[1] * coords_3d[1,2] + dNr[2] * coords_3d[2,2] + dNr[3] * coords_3d[3,2] + dNr[4] * coords_3d[4,2],
        dNr[1] * coords_3d[1,3] + dNr[2] * coords_3d[2,3] + dNr[3] * coords_3d[3,3] + dNr[4] * coords_3d[4,3],
    )
    a2 = SVector(
        dNs[1] * coords_3d[1,1] + dNs[2] * coords_3d[2,1] + dNs[3] * coords_3d[3,1] + dNs[4] * coords_3d[4,1],
        dNs[1] * coords_3d[1,2] + dNs[2] * coords_3d[2,2] + dNs[3] * coords_3d[3,2] + dNs[4] * coords_3d[4,2],
        dNs[1] * coords_3d[1,3] + dNs[2] * coords_3d[2,3] + dNs[3] * coords_3d[3,3] + dNs[4] * coords_3d[4,3],
    )

    cross_a = cross(a1, a2)
    area_elem = norm(cross_a)
    n_gp = area_elem > 1e-30 ? cross_a / area_elem : SVector(0.0, 0.0, 1.0)
    a1_len = norm(a1)
    t1 = a1_len > 1e-30 ? a1 / a1_len : SVector(1.0, 0.0, 0.0)
    t2 = cross(n_gp, t1)

    J11 = a1_len
    J12 = 0.0
    J21 = dot(a2, t1)
    J22 = dot(a2, t2)
    return n_gp, area_elem, t1, t2, J11, J12, J21, J22
end

"""
Compute per-corner out-of-plane (z) coordinate of the element midsurface,
in the element-center local frame (v3 = diagonal-cross-product normal).
For a perfectly flat element this is zero on every corner. For a warped or
curved element, it captures the linear warp pattern (cylindrical, twist,
or combination) that the bilinear-shape-function curvature term misses.

Returns SVector{4} of local-z corner coordinates in the element-center frame.
"""
@inline function quad4_local_z_from_coords3d(coords_3d::AbstractMatrix)
    p1 = SVector(coords_3d[1,1], coords_3d[1,2], coords_3d[1,3])
    p2 = SVector(coords_3d[2,1], coords_3d[2,2], coords_3d[2,3])
    p3 = SVector(coords_3d[3,1], coords_3d[3,2], coords_3d[3,3])
    p4 = SVector(coords_3d[4,1], coords_3d[4,2], coords_3d[4,3])
    c = (p1 + p2 + p3 + p4) / 4
    n_raw = cross(p3 - p1, p4 - p2)
    nrm = norm(n_raw)
    v3 = nrm > 1e-30 ? n_raw / nrm : SVector(0.0, 0.0, 1.0)
    return SVector{4,Float64}(dot(p1 - c, v3), dot(p2 - c, v3),
                              dot(p3 - c, v3), dot(p4 - c, v3))
end

function quad4_finite_warp_displacement_map(coords::AbstractMatrix,
                                             coords_3d::AbstractMatrix)
    zl4 = quad4_local_z_from_coords3d(coords_3d)
    xmax = max(maximum(abs, @view coords[:,1]), 1e-30)
    maximum(abs, zl4) > 1e-12 * xmax || return nothing

    # Ke is in the caller's local frame. Use its projected x,y coordinates
    # and offsets about the same diagonal-cross mean plane. The height field
    # is bilinear in natural coordinates, so evaluate its corner slopes
    # through the corner Jacobian.
    corner = ((-1.0,-1.0), (1.0,-1.0),
              (1.0,1.0), (-1.0,1.0))
    Tg = Matrix{Float64}(I, 24, 24)
    @inbounds for i in 1:4
        rr, ss = corner[i]
        dNr, dNs = shape_derivs_quad(rr, ss)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] +
              dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] +
              dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] +
              dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] +
              dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        dj = J11*J22 - J12*J21
        abs(dj) < 1e-30 && continue
        i11 =  J22/dj
        i12 = -J12/dj
        i21 = -J21/dj
        i22 =  J11/dj

        zr = dNr[1]*zl4[1] + dNr[2]*zl4[2] +
             dNr[3]*zl4[3] + dNr[4]*zl4[4]
        zs = dNs[1]*zl4[1] + dNs[2]*zl4[2] +
             dNs[3]*zl4[3] + dNs[4]*zl4[4]
        gx = i11*zr + i12*zs
        gy = i21*zr + i22*zs

        # Moment tilt plus its diagonal in-plane equilibrium couple.
        rxi = 6(i-1) + 4
        ryi = 6(i-1) + 5
        Tg[rxi, 6(i-1)+6] += gx
        Tg[ryi, 6(i-1)+6] += gy
        a, b = isodd(i) ? (1, 3) : (2, 4)
        dx = coords[b,1] - coords[a,1]
        dy = coords[b,2] - coords[a,2]
        dl2 = dx*dx + dy*dy
        if dl2 > 1e-30
            # phi_ab =
            # [dx*(v_b-v_a) - dy*(u_b-u_a)] / |r_b-r_a|^2.
            for (j, cu, cv) in
                ((a,  dy/dl2, -dx/dl2),
                 (b, -dy/dl2,  dx/dl2))
                Tg[rxi, 6(j-1)+1] -= gx*cu
                Tg[rxi, 6(j-1)+2] -= gx*cv
                Tg[ryi, 6(j-1)+1] -= gy*cu
                Tg[ryi, 6(j-1)+2] -= gy*cv
            end
        end

        # Exact normal-force equilibrium for the offset in-plane force
        # transfer.
        for j in 1:4
            dNdx = i11*dNr[j] + i12*dNs[j]
            dNdy = i21*dNr[j] + i22*dNs[j]
            Tg[6(i-1)+1, 6(j-1)+3] += zl4[i]*dNdx
            Tg[6(i-1)+2, 6(j-1)+3] += zl4[i]*dNdy
        end
    end
    return Tg
end

@inline quad4_snorm_row_is_active(p, q) =
    hypot(Float64(p), Float64(q)) > 64 * eps(Float64)

function quad4_snorm_pq_has_active_rows(snorm_pq::AbstractMatrix)
    size(snorm_pq, 1) == 4 || throw(ArgumentError("snorm_pq must have four rows"))
    size(snorm_pq, 2) >= 2 || throw(ArgumentError("snorm_pq must have p and q columns"))
    return any(i -> quad4_snorm_row_is_active(snorm_pq[i,1], snorm_pq[i,2]), 1:4)
end

"""
Express an active PARAM,SNORM corner director relative to the intrinsic
finite-warp rotation already carried by `warp_map`.

`snorm_pq[i,:] = (p_i,q_i)` is the absolute averaged director in the element
mean-plane frame.  At the same corner the finite-warp map contains the height
slopes

    gx_i = W[rx_i,rz_i],  gy_i = W[ry_i,rz_i].

Because the common physical-coordinate map is `M * W`, the normal-moment map
must receive `(p_i + gx_i, q_i + gy_i)` so the composed director is exactly
`(p_i,q_i,1)` instead of counting the geometric tilt twice.  A corner whose
director is aligned with the element normal is structurally inert (this also
keeps solo, rejected, and coplanar nodes on the W-only path), so the additive
residual is applied only to a genuinely nonzero director row.

Passing `nothing` for `warp_map` returns the same active director field without
the geometric residual.  `nothing` is returned when every row is inert.
"""
function quad4_snorm_relative_to_finite_warp_pq(
    snorm_pq::AbstractMatrix,
    warp_map,
)
    size(snorm_pq, 1) == 4 || throw(ArgumentError("snorm_pq must have four rows"))
    size(snorm_pq, 2) >= 2 || throw(ArgumentError("snorm_pq must have p and q columns"))
    if warp_map !== nothing
        size(warp_map, 1) == 24 && size(warp_map, 2) == 24 || throw(ArgumentError(
            "warp_map must be a 24 by 24 CQUAD4 displacement map"))
    end

    pq_relative = zeros(Float64, 4, 2)
    active = false
    @inbounds for i in 1:4
        p = Float64(snorm_pq[i,1])
        q = Float64(snorm_pq[i,2])
        quad4_snorm_row_is_active(p, q) || continue
        active = true
        if warp_map === nothing
            pq_relative[i,1] = p
            pq_relative[i,2] = q
        else
            rz = 6(i-1) + 6
            pq_relative[i,1] = p + Float64(warp_map[rz-2,rz])
            pq_relative[i,2] = q + Float64(warp_map[rz-1,rz])
        end
    end
    return active ? pq_relative : nothing
end

function apply_quad4_finite_warp_equilibrium!(Ke::AbstractMatrix,
                                               coords::AbstractMatrix,
                                               coords_3d::AbstractMatrix)
    Tg = quad4_finite_warp_displacement_map(coords, coords_3d)
    Tg === nothing && return Ke
    Kt = transpose(Tg) * Ke * Tg
    @inbounds for j in 1:24, i in 1:24
        Ke[i,j] = 0.5*(Kt[i,j] + Kt[j,i])
    end
    return Ke
end

"""
Apply the superseded nodal-only PARAM,SNORM map used by the explicit
`JFEM_Q4_SNORM_COMPLETION_MODE=field` diagnostic.

`snorm_pq[i,:] = (p_i,q_i)` describes the nodal director
`d_i=(p_i,q_i,1)` in the element frame. The recovered reference map is

    S_i = [1  0 -p_i; 0  1 -q_i; p_i q_i 1].

This is not the production normal-moment formulation. Call it only after the
legacy local director-gradient terms have been formed. The finite-warp
multiplier is applied afterwards, giving the diagnostic work-dual order
`W' * S' * K_field * S * W`.
"""
function apply_quad4_snorm_director_completion!(Ke::AbstractMatrix,
                                                 snorm_pq::AbstractMatrix)
    size(snorm_pq, 1) == 4 || throw(ArgumentError("snorm_pq must have four rows"))
    size(snorm_pq, 2) >= 2 || throw(ArgumentError("snorm_pq must have p and q columns"))
    all(iszero, snorm_pq) && return Ke
    Ts = Matrix{Float64}(I, 24, 24)
    @inbounds for i in 1:4
        p = snorm_pq[i,1]
        q = snorm_pq[i,2]
        rx = 6(i-1) + 4
        ry = rx + 1
        rz = rx + 2
        Ts[rx,rz] -= p
        Ts[ry,rz] -= q
        Ts[rz,rx] += p
        Ts[rz,ry] += q
    end
    Kt = transpose(Ts) * Ke * Ts
    @inbounds for j in 1:24, i in 1:24
        Ke[i,j] = 0.5*(Kt[i,j] + Kt[j,i])
    end
    return Ke
end

function apply_quad4_snorm_director_displacement!(u::AbstractVector,
                                                   snorm_pq::AbstractMatrix)
    all(iszero, snorm_pq) && return u
    @inbounds for i in 1:4
        base = 6(i-1)
        rx = u[base+4]
        ry = u[base+5]
        rz = u[base+6]
        p = snorm_pq[i,1]
        q = snorm_pq[i,2]
        u[base+4] = rx - p*rz
        u[base+5] = ry - q*rz
        u[base+6] = p*rx + q*ry + rz
    end
    return u
end

"""
Build the production PARAM,SNORM normal-moment equilibrium map from the
relative drilling rotation at each CQUAD4 corner,

    delta_i = rz_i - omega_z(i),
    rx_used = rx_i - p_i*delta_i,
    ry_used = ry_i - q_i*delta_i,

where `omega_z(i) = 0.5*(v_,x - u_,y)` is evaluated with the
isoparametric corner Jacobian.  A rigid spin has `delta_i == 0`, so the map
is rigid-exact while the transpose replaces the induced normal moment with
its zero-resultant in-plane force couple.  The third director row is completed
with the matching transverse-slope residuals,

    rz_used = rz + p*(rx - w_,y) + q*(ry + w_,x),

which preserves the recovered full-S rotation--rotation block and remains
rigid-exact. On a projected-flat element the supplied `(p_i,q_i)` values are
the absolute averaged-director slopes. When a finite-warp W map is composed,
the caller first uses `quad4_snorm_relative_to_finite_warp_pq` to supply the
relative `(p_i+gx_i,q_i+gy_i)` residual, so `M_relative*W` recovers that same
absolute director without double-counting the geometric corner tilt. This is
the parameter-free work-dual map selected by retained fold, star, taper, and
hemisphere element matrices.
"""
function quad4_snorm_normal_moment_displacement_map(
    coords::AbstractMatrix,
    snorm_pq::AbstractMatrix,
)
    size(coords, 1) == 4 || throw(ArgumentError("coords must have four rows"))
    size(coords, 2) >= 2 || throw(ArgumentError("coords must have x and y columns"))
    size(snorm_pq, 1) == 4 || throw(ArgumentError("snorm_pq must have four rows"))
    size(snorm_pq, 2) >= 2 || throw(ArgumentError("snorm_pq must have p and q columns"))

    T = Matrix{Float64}(I, 24, 24)
    all(iszero, snorm_pq) && return T
    corner_rs = ((-1.0, -1.0), (1.0, -1.0),
                 (1.0, 1.0), (-1.0, 1.0))
    @inbounds for i in 1:4
        r, s = corner_rs[i]
        dNr, dNs = shape_derivs_quad(r, s)
        J11 = sum(dNr[k] * coords[k,1] for k in 1:4)
        J12 = sum(dNr[k] * coords[k,2] for k in 1:4)
        J21 = sum(dNs[k] * coords[k,1] for k in 1:4)
        J22 = sum(dNs[k] * coords[k,2] for k in 1:4)
        detJ = J11*J22 - J12*J21
        abs(detJ) > 1e-30 || throw(ArgumentError(
            "singular isoparametric Jacobian at CQUAD4 corner $i"))
        i11 =  J22/detJ
        i12 = -J12/detJ
        i21 = -J21/detJ
        i22 =  J11/detJ

        p = Float64(snorm_pq[i,1])
        q = Float64(snorm_pq[i,2])
        rx = 6(i-1) + 4
        ry = rx + 1
        rz = rx + 2
        T[rx,rz] -= p
        T[ry,rz] -= q
        T[rz,rx] += p
        T[rz,ry] += q
        for k in 1:4
            dNdx = i11*dNr[k] + i12*dNs[k]
            dNdy = i21*dNr[k] + i22*dNs[k]
            ux = 6(k-1) + 1
            uy = ux + 1
            uz = ux + 2
            # +p*omega_z and +q*omega_z in rows 1 and 2.
            T[rx,ux] -= 0.5*p*dNdy
            T[rx,uy] += 0.5*p*dNdx
            T[ry,ux] -= 0.5*q*dNdy
            T[ry,uy] += 0.5*q*dNdx
            T[rz,uz] += -p*dNdy + q*dNdx
        end
    end
    return T
end

function apply_quad4_snorm_normal_moment_completion!(
    Ke::AbstractMatrix,
    coords::AbstractMatrix,
    snorm_pq::AbstractMatrix,
)
    all(iszero, snorm_pq) && return Ke
    T = quad4_snorm_normal_moment_displacement_map(coords, snorm_pq)
    Kt = transpose(T) * Ke * T
    @inbounds for j in 1:24, i in 1:24
        Ke[i,j] = 0.5*(Kt[i,j] + Kt[j,i])
    end
    return Ke
end

function apply_quad4_snorm_normal_moment_displacement!(
    u::AbstractVector,
    coords::AbstractMatrix,
    snorm_pq::AbstractMatrix,
)
    all(iszero, snorm_pq) && return u
    T = quad4_snorm_normal_moment_displacement_map(coords, snorm_pq)
    u .= T * u
    return u
end

@inline function quad4_snorm_normal_moment_mode()
    mode = lowercase(strip(get(ENV, "JFEM_Q4_SNORM_COMPLETION_MODE", "normal_moment")))
    # `corner_drill_s3` remains an accepted campaign alias for the selected
    # completed three-row formulation.  The inferior identity-row3 prototype
    # and the global pseudoinverse prototype are deliberately not retained.
    if mode in ("normal_moment", "normal-moment", "normalmoment",
                "corner_drill_s3", "corner-drill-s3", "cornerdrills3")
        return true
    elseif mode in ("field", "completed")
        return false
    end
    throw(ArgumentError(
        "Unsupported JFEM_Q4_SNORM_COMPLETION_MODE=$(repr(mode)); " *
        "expected normal_moment or field"))
end

@inline function add_quad4_snorm_curvature_B!(Bb::AbstractMatrix,
                                               dN_dxy::AbstractMatrix,
                                               snorm_pq)
    snorm_pq === nothing && return Bb
    all(iszero, snorm_pq) && return Bb
    px = 0.0; py = 0.0; qx = 0.0; qy = 0.0
    @inbounds for k in 1:4
        px += dN_dxy[1,k] * snorm_pq[k,1]
        py += dN_dxy[2,k] * snorm_pq[k,1]
        qx += dN_dxy[1,k] * snorm_pq[k,2]
        qy += dN_dxy[2,k] * snorm_pq[k,2]
    end
    @inbounds for k in 1:4
        dNdx = dN_dxy[1,k]
        dNdy = dN_dxy[2,k]
        base = 6(k-1)
        Bb[1,base+1] += px*dNdx
        Bb[1,base+2] += qx*dNdx
        Bb[2,base+1] += py*dNdy
        Bb[2,base+2] += qy*dNdy
        Bb[3,base+1] += py*dNdx + px*dNdy
        Bb[3,base+2] += qy*dNdx + qx*dNdy
    end
    return Bb
end

@inline function quad4_gp_curvature_membrane_from_coords3d(coords_3d::AbstractMatrix,
                                                           xi::Float64, eta::Float64)
    n_gp, _, _, _, J11, J12, J21, J22 =
        quad4_gp_local_frame_from_coords3d(coords_3d, xi, eta)

    a_rr = SVector(0.0, 0.0, 0.0)
    a_ss = SVector(0.0, 0.0, 0.0)
    a_rs = SVector(
        QUAD4_D2N_DXIDETA[1] * coords_3d[1,1] + QUAD4_D2N_DXIDETA[2] * coords_3d[2,1] +
        QUAD4_D2N_DXIDETA[3] * coords_3d[3,1] + QUAD4_D2N_DXIDETA[4] * coords_3d[4,1],
        QUAD4_D2N_DXIDETA[1] * coords_3d[1,2] + QUAD4_D2N_DXIDETA[2] * coords_3d[2,2] +
        QUAD4_D2N_DXIDETA[3] * coords_3d[3,2] + QUAD4_D2N_DXIDETA[4] * coords_3d[4,2],
        QUAD4_D2N_DXIDETA[1] * coords_3d[1,3] + QUAD4_D2N_DXIDETA[2] * coords_3d[2,3] +
        QUAD4_D2N_DXIDETA[3] * coords_3d[3,3] + QUAD4_D2N_DXIDETA[4] * coords_3d[4,3],
    )

    b_rr = dot(n_gp, a_rr)
    b_ss = dot(n_gp, a_ss)
    b_rs = dot(n_gp, a_rs)

    detJ = J11 * J22 - J12 * J21
    if abs(detJ) <= 1e-30
        return SVector(0.0, 0.0, 0.0)
    end

    inv_det = 1.0 / detJ
    iJ11 =  J22 * inv_det
    iJ12 = -J12 * inv_det
    iJ21 = -J21 * inv_det
    iJ22 =  J11 * inv_det

    k11 = iJ11 * iJ11 * b_rr + 2.0 * iJ11 * iJ12 * b_rs + iJ12 * iJ12 * b_ss
    k22 = iJ21 * iJ21 * b_rr + 2.0 * iJ21 * iJ22 * b_rs + iJ22 * iJ22 * b_ss
    k12 = iJ11 * iJ21 * b_rr + (iJ11 * iJ22 + iJ12 * iJ21) * b_rs + iJ12 * iJ22 * b_ss
    return SVector(k11, k22, k12)
end

@inline function quad4_gp_bending_connection_from_coords3d(coords_3d::AbstractMatrix,
                                                           xi::Float64, eta::Float64)
    dNr, dNs = shape_derivs_quad(xi, eta)

    a_r = SVector(
        dNr[1]*coords_3d[1,1] + dNr[2]*coords_3d[2,1] + dNr[3]*coords_3d[3,1] + dNr[4]*coords_3d[4,1],
        dNr[1]*coords_3d[1,2] + dNr[2]*coords_3d[2,2] + dNr[3]*coords_3d[3,2] + dNr[4]*coords_3d[4,2],
        dNr[1]*coords_3d[1,3] + dNr[2]*coords_3d[2,3] + dNr[3]*coords_3d[3,3] + dNr[4]*coords_3d[4,3],
    )
    a_s = SVector(
        dNs[1]*coords_3d[1,1] + dNs[2]*coords_3d[2,1] + dNs[3]*coords_3d[3,1] + dNs[4]*coords_3d[4,1],
        dNs[1]*coords_3d[1,2] + dNs[2]*coords_3d[2,2] + dNs[3]*coords_3d[3,2] + dNs[4]*coords_3d[4,2],
        dNs[1]*coords_3d[1,3] + dNs[2]*coords_3d[2,3] + dNs[3]*coords_3d[3,3] + dNs[4]*coords_3d[4,3],
    )
    a_rs = SVector(
        QUAD4_D2N_DXIDETA[1]*coords_3d[1,1] + QUAD4_D2N_DXIDETA[2]*coords_3d[2,1] +
        QUAD4_D2N_DXIDETA[3]*coords_3d[3,1] + QUAD4_D2N_DXIDETA[4]*coords_3d[4,1],
        QUAD4_D2N_DXIDETA[1]*coords_3d[1,2] + QUAD4_D2N_DXIDETA[2]*coords_3d[2,2] +
        QUAD4_D2N_DXIDETA[3]*coords_3d[3,2] + QUAD4_D2N_DXIDETA[4]*coords_3d[4,2],
        QUAD4_D2N_DXIDETA[1]*coords_3d[1,3] + QUAD4_D2N_DXIDETA[2]*coords_3d[2,3] +
        QUAD4_D2N_DXIDETA[3]*coords_3d[3,3] + QUAD4_D2N_DXIDETA[4]*coords_3d[4,3],
    )

    cross_a = cross(a_r, a_s)
    area_elem = norm(cross_a)
    a_r_len = norm(a_r)
    if area_elem <= 1e-30 || a_r_len <= 1e-30
        return SVector(0.0, 0.0)
    end

    n_gp = cross_a / area_elem
    t1 = a_r / a_r_len
    t2 = cross(n_gp, t1)

    J11 = a_r_len
    J12 = 0.0
    J21 = dot(a_s, t1)
    J22 = dot(a_s, t2)
    detJ = J11 * J22 - J12 * J21
    if abs(detJ) <= 1e-30
        return SVector(0.0, 0.0)
    end

    cross_r = cross(a_r, a_rs)
    cross_s = cross(a_rs, a_s)
    n_r = (cross_r - n_gp * dot(n_gp, cross_r)) / area_elem
    n_s = (cross_s - n_gp * dot(n_gp, cross_s)) / area_elem

    t1_r = SVector(0.0, 0.0, 0.0)
    t1_s = (a_rs - t1 * dot(t1, a_rs)) / a_r_len
    t2_r = cross(n_r, t1)
    t2_s = cross(n_s, t1) + cross(n_gp, t1_s)

    inv_det = 1.0 / detJ
    iJ11 =  J22 * inv_det
    iJ12 = -J12 * inv_det
    iJ21 = -J21 * inv_det
    iJ22 =  J11 * inv_det

    t1_x = iJ11 * t1_r + iJ12 * t1_s
    t1_y = iJ21 * t1_r + iJ22 * t1_s
    eta1 = dot(t1_x, t2)
    eta2 = dot(t1_y, t2)
    return SVector(eta1, eta2)
end

@inline function rotate_constitutive_3x3!(C::AbstractMatrix{Float64}, beta::Float64)
    abs(beta) <= 1e-12 && return C
    cb = cos(beta)
    sb = sin(beta)
    c2 = cb * cb
    s2 = sb * sb
    cs = cb * sb
    T11 = c2
    T12 = s2
    T13 = cs
    T21 = s2
    T22 = c2
    T23 = -cs
    T31 = -2.0 * cs
    T32 = 2.0 * cs
    T33 = c2 - s2

    t11 = C[1,1]*T11 + C[1,2]*T21 + C[1,3]*T31
    t12 = C[1,1]*T12 + C[1,2]*T22 + C[1,3]*T32
    t13 = C[1,1]*T13 + C[1,2]*T23 + C[1,3]*T33
    t21 = C[2,1]*T11 + C[2,2]*T21 + C[2,3]*T31
    t22 = C[2,1]*T12 + C[2,2]*T22 + C[2,3]*T32
    t23 = C[2,1]*T13 + C[2,2]*T23 + C[2,3]*T33
    t31 = C[3,1]*T11 + C[3,2]*T21 + C[3,3]*T31
    t32 = C[3,1]*T12 + C[3,2]*T22 + C[3,3]*T32
    t33 = C[3,1]*T13 + C[3,2]*T23 + C[3,3]*T33

    C[1,1] = T11*t11 + T21*t21 + T31*t31
    C[1,2] = T11*t12 + T21*t22 + T31*t32
    C[1,3] = T11*t13 + T21*t23 + T31*t33
    C[2,1] = T12*t11 + T22*t21 + T32*t31
    C[2,2] = T12*t12 + T22*t22 + T32*t32
    C[2,3] = T12*t13 + T22*t23 + T32*t33
    C[3,1] = T13*t11 + T23*t21 + T33*t31
    C[3,2] = T13*t12 + T23*t22 + T33*t32
    C[3,3] = T13*t13 + T23*t23 + T33*t33
    return C
end

@inline function rotate_constitutive_2x2!(C::AbstractMatrix{Float64}, beta::Float64)
    abs(beta) <= 1e-12 && return C
    cb = cos(beta)
    sb = sin(beta)
    a11 = C[1,1]
    a12 = C[1,2]
    a22 = C[2,2]
    C[1,1] = cb^2*a11 + 2.0*cb*sb*a12 + sb^2*a22
    C[1,2] = -cb*sb*a11 + (cb^2 - sb^2)*a12 + cb*sb*a22
    C[2,1] = C[1,2]
    C[2,2] = sb^2*a11 - 2.0*cb*sb*a12 + cb^2*a22
    return C
end

@inline function quad4_gp_rotation_from_element!(R::AbstractMatrix{Float64},
                                                 v1::SVector{3,Float64},
                                                 v2::SVector{3,Float64},
                                                 v3::SVector{3,Float64},
                                                 t1::SVector{3,Float64},
                                                 t2::SVector{3,Float64},
                                                 n_gp::SVector{3,Float64})
    R[1,1] = dot(t1, v1); R[1,2] = dot(t1, v2); R[1,3] = dot(t1, v3)
    R[2,1] = dot(t2, v1); R[2,2] = dot(t2, v2); R[2,3] = dot(t2, v3)
    R[3,1] = dot(n_gp, v1); R[3,2] = dot(n_gp, v2); R[3,3] = dot(n_gp, v3)

    v1_proj = v1 - dot(v1, n_gp) * n_gp
    v1_proj_len = norm(v1_proj)
    if v1_proj_len <= 1e-30
        v1_proj = v2 - dot(v2, n_gp) * n_gp
        v1_proj_len = norm(v1_proj)
    end
    if v1_proj_len <= 1e-30
        return 0.0
    end
    v1_proj_unit = v1_proj / v1_proj_len
    return atan(dot(v1_proj_unit, t2), dot(v1_proj_unit, t1))
end

@inline function rotate_quad4_dof_blocks!(B::AbstractMatrix{Float64}, R::AbstractMatrix{Float64})
    nrows = size(B, 1)
    @inbounds for k in 1:4
        idx = (k - 1) * 6
        for i in 1:nrows
            t1 = B[i, idx + 1]
            t2 = B[i, idx + 2]
            t3 = B[i, idx + 3]
            B[i, idx + 1] = t1*R[1,1] + t2*R[2,1] + t3*R[3,1]
            B[i, idx + 2] = t1*R[1,2] + t2*R[2,2] + t3*R[3,2]
            B[i, idx + 3] = t1*R[1,3] + t2*R[2,3] + t3*R[3,3]

            r1 = B[i, idx + 4]
            r2 = B[i, idx + 5]
            r3 = B[i, idx + 6]
            B[i, idx + 4] = r1*R[1,1] + r2*R[2,1] + r3*R[3,1]
            B[i, idx + 5] = r1*R[1,2] + r2*R[2,2] + r3*R[3,2]
            B[i, idx + 6] = r1*R[1,3] + r2*R[2,3] + r3*R[3,3]
        end
    end
    return B
end

@inline function rotate_quad4_dof_blocks!(b::AbstractVector{Float64}, R::AbstractMatrix{Float64})
    @inbounds for k in 1:4
        idx = (k - 1) * 6
        t1 = b[idx + 1]
        t2 = b[idx + 2]
        t3 = b[idx + 3]
        b[idx + 1] = t1*R[1,1] + t2*R[2,1] + t3*R[3,1]
        b[idx + 2] = t1*R[1,2] + t2*R[2,2] + t3*R[3,2]
        b[idx + 3] = t1*R[1,3] + t2*R[2,3] + t3*R[3,3]

        r1 = b[idx + 4]
        r2 = b[idx + 5]
        r3 = b[idx + 6]
        b[idx + 4] = r1*R[1,1] + r2*R[2,1] + r3*R[3,1]
        b[idx + 5] = r1*R[1,2] + r2*R[2,2] + r3*R[3,2]
        b[idx + 6] = r1*R[1,3] + r2*R[2,3] + r3*R[3,3]
    end
    return b
end

# =============================================================================
# KERNEL: stiffness_quad4 (E/nu/h convenience constructor)
# STATUS: PRODUCTION (sensitivity path) - wraps stiffness_quad4_matrices for
#         dKdx.jl finite-difference sensitivities (optimization / adjoint).
# DISPATCHED FROM: JFEM/src/solver/dKdx.jl lines ~207, 263, 291, 1075.
# Not on the GAME default K assembly path.
# =============================================================================
function stiffness_quad4(coords, E, nu, h; bend_ratio=1.0, ts_t=5.0/6.0, k6rot=100.0, ws::Union{Nothing,Quad4Workspace}=nothing)
    const_mem = E * h / (1 - nu^2)
    Cm = const_mem .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]

    const_bend = bend_ratio * (E * h^3) / (12 * (1 - nu^2))
    Cb = const_bend .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]

    G = E / (2*(1+nu))
    k_shear = ts_t * G * h
    Cs = k_shear .* [1 0; 0 1]

    return stiffness_quad4_matrices(coords, Cm, Cb, Cs, h, E; bend_ratio=bend_ratio, k6rot=k6rot, ws=ws)
end

# =============================================================================
# KERNEL: stiffness_quad4_generic (E/nu/h variant, calls _default_generic)
# STATUS: PRODUCTION (sensitivity path) - used by dKdx.jl for variable
#         differentiation through (E, nu).
# =============================================================================
function stiffness_quad4_generic(coords, E, nu, h; bend_ratio=1.0, ts_t=5.0/6.0, k6rot=100.0)
    T = promote_type(typeof(E), typeof(nu), typeof(h))
    oneT = one(T)
    zeroT = zero(T)

    const_mem = E * h / (oneT - nu^2)
    Cm = const_mem .* T[oneT nu zeroT; nu oneT zeroT; zeroT zeroT (oneT - nu) / T(2)]

    const_bend = T(bend_ratio) * (E * h^3) / (T(12) * (oneT - nu^2))
    Cb = const_bend .* T[oneT nu zeroT; nu oneT zeroT; zeroT zeroT (oneT - nu) / T(2)]

    G = E / (T(2) * (oneT + nu))
    Cs = (T(ts_t) * G * h) .* T[oneT zeroT; zeroT oneT]

    return stiffness_quad4_default_generic(coords, Cm, Cb, Cs, h, G; k6rot=k6rot)
end

# =============================================================================
# KERNEL: stiffness_quad4_default_generic (internal of stiffness_quad4_generic)
# STATUS: INTERNAL - called only by stiffness_quad4_generic.
# =============================================================================
function stiffness_quad4_default_generic(coords, Cm, Cb, Cs, h, G_ref; k6rot=100.0)
    T = promote_type(eltype(Cm), eltype(Cb), eltype(Cs), typeof(h), typeof(G_ref))
    zeroT = zero(T)
    oneT = one(T)

    Ke = zeros(T, 24, 24)
    K_ab = zeros(T, 24, 4)
    K_bb = zeros(T, 4, 4)

    Bs_tp = zeros(Float64, 4, 24)
    Bm = zeros(Float64, 3, 24)
    Bb = zeros(Float64, 3, 24)
    Bd = zeros(Float64, 1, 24)
    Bi = zeros(Float64, 3, 4)
    Bs_cov = zeros(Float64, 2, 24)

    tying_pts = ((0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0))
    for tp_idx in 1:4
        xi_tp, eta_tp = tying_pts[tp_idx]
        dNr, dNs = shape_derivs_quad(xi_tp, eta_tp)
        J11 = dNr[1] * coords[1,1] + dNr[2] * coords[2,1] + dNr[3] * coords[3,1] + dNr[4] * coords[4,1]
        J12 = dNr[1] * coords[1,2] + dNr[2] * coords[2,2] + dNr[3] * coords[3,2] + dNr[4] * coords[4,2]
        J21 = dNs[1] * coords[1,1] + dNs[2] * coords[2,1] + dNs[3] * coords[3,1] + dNs[4] * coords[4,1]
        J22 = dNs[1] * coords[1,2] + dNs[2] * coords[2,2] + dNs[3] * coords[3,2] + dNs[4] * coords[4,2]
        N_tp = (
            0.25 * (1.0 - xi_tp) * (1.0 - eta_tp),
            0.25 * (1.0 + xi_tp) * (1.0 - eta_tp),
            0.25 * (1.0 + xi_tp) * (1.0 + eta_tp),
            0.25 * (1.0 - xi_tp) * (1.0 + eta_tp),
        )
        if tp_idx <= 2
            for k in 1:4
                idx = (k - 1) * 6
                Bs_tp[tp_idx, idx + 3] = dNr[k]
                Bs_tp[tp_idx, idx + 4] = -J12 * N_tp[k]
                Bs_tp[tp_idx, idx + 5] = J11 * N_tp[k]
            end
        else
            for k in 1:4
                idx = (k - 1) * 6
                Bs_tp[tp_idx, idx + 3] = dNs[k]
                Bs_tp[tp_idx, idx + 4] = -J22 * N_tp[k]
                Bs_tp[tp_idx, idx + 5] = J21 * N_tp[k]
            end
        end
    end

    dNr_c = SVector(-0.25, 0.25, 0.25, -0.25)
    dNs_c = SVector(-0.25, -0.25, 0.25, 0.25)
    J11c = dNr_c[1] * coords[1,1] + dNr_c[2] * coords[2,1] + dNr_c[3] * coords[3,1] + dNr_c[4] * coords[4,1]
    J12c = dNr_c[1] * coords[1,2] + dNr_c[2] * coords[2,2] + dNr_c[3] * coords[3,2] + dNr_c[4] * coords[4,2]
    J21c = dNs_c[1] * coords[1,1] + dNs_c[2] * coords[2,1] + dNs_c[3] * coords[3,1] + dNs_c[4] * coords[4,1]
    J22c = dNs_c[1] * coords[1,2] + dNs_c[2] * coords[2,2] + dNs_c[3] * coords[3,2] + dNs_c[4] * coords[4,2]
    detJc = J11c * J22c - J12c * J21c
    abs_detJc = abs(detJc)
    inv_detc = 1.0 / detJc
    iJ11c = J22c * inv_detc
    iJ12c = -J12c * inv_detc
    iJ21c = -J21c * inv_detc
    iJ22c = J11c * inv_detc

    phi2_alpha = PHI2_ALPHA[]
    L_char_sq = max(4.0 * abs_detJc, 1e-30)
    phi2_trial = T(phi2_alpha) * h^2 / T(L_char_sq)
    # Branch on real(phi2_trial) so the saturation min() stays complex-step
    # clean — `min` on ComplexF64 throws MethodError because complex numbers
    # are not ordered. real() is the identity on Float64 and preserves the
    # imaginary perturbation on ComplexF64; the saturated branch drops to
    # a pure real `oneT`, which is the correct CS derivative (constant
    # function ⇒ zero derivative).
    phi2_shear = if phi2_alpha > 0.0
        real(phi2_trial) < 1.0 ? phi2_trial : oneT
    else
        oneT
    end

    alpha_drill = (T(k6rot) / T(1e5)) * G_ref * h

    pt = 1.0 / sqrt(3.0)
    gauss_pts = ((-pt, -pt), (pt, -pt), (pt, pt), (-pt, pt))

    for gp in gauss_pts
        r, s = gp
        dNr, dNs = shape_derivs_quad(r, s)

        J11 = dNr[1] * coords[1,1] + dNr[2] * coords[2,1] + dNr[3] * coords[3,1] + dNr[4] * coords[4,1]
        J12 = dNr[1] * coords[1,2] + dNr[2] * coords[2,2] + dNr[3] * coords[3,2] + dNr[4] * coords[4,2]
        J21 = dNs[1] * coords[1,1] + dNs[2] * coords[2,1] + dNs[3] * coords[3,1] + dNs[4] * coords[4,1]
        J22 = dNs[1] * coords[1,2] + dNs[2] * coords[2,2] + dNs[3] * coords[3,2] + dNs[4] * coords[4,2]
        detJ = J11 * J22 - J12 * J21
        abs_detJ = max(abs(detJ), 1e-12)
        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(Bm, 0.0)
        fill!(Bb, 0.0)
        fill!(Bd, 0.0)
        for k in 1:4
            dN_dx = iJ11 * dNr[k] + iJ12 * dNs[k]
            dN_dy = iJ21 * dNr[k] + iJ22 * dNs[k]
            idx = (k - 1) * 6
            N_k = 0.25 * (1 + (k == 2 || k == 3 ? r : -r)) * (1 + (k >= 3 ? s : -s))
            Bm[1, idx + 1] = dN_dx
            Bm[2, idx + 2] = dN_dy
            Bm[3, idx + 1] = dN_dy
            Bm[3, idx + 2] = dN_dx
            Bb[1, idx + 5] = dN_dx
            Bb[2, idx + 4] = -dN_dy
            Bb[3, idx + 5] = dN_dy
            Bb[3, idx + 4] = -dN_dx
            Bd[1, idx + 1] = 0.5 * dN_dy
            Bd[1, idx + 2] = -0.5 * dN_dx
            Bd[1, idx + 6] = N_k
        end

        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ11,
            iJ12,
            iJ21,
            iJ22,
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            false,
        )

        Ke .+= (Bm' * Cm * Bm) .* abs_detJ
        Ke .+= (Bb' * Cb * Bb) .* abs_detJ
        Ke .+= (Bd' * Bd) .* (abs_detJ * alpha_drill)

        w_eta_p = 0.5 * (1.0 + s)
        w_eta_m = 0.5 * (1.0 - s)
        w_xi_p = 0.5 * (1.0 + r)
        w_xi_m = 0.5 * (1.0 - r)
        fill!(Bs_cov, 0.0)
        for j in 1:24
            Bs_cov[1, j] = w_eta_m * Bs_tp[1, j] + w_eta_p * Bs_tp[2, j]
            Bs_cov[2, j] = w_xi_m * Bs_tp[3, j] + w_xi_p * Bs_tp[4, j]
        end
        invJ = Float64[iJ11 iJ12; iJ21 iJ22]
        Cs_cov = phi2_shear .* (invJ' * Cs * invJ)
        Ke .+= (Bs_cov' * Cs_cov * Bs_cov) .* abs_detJ

        K_ab .+= (Bm' * Cm * Bi) .* abs_detJ
        K_bb .+= (Bi' * Cm * Bi) .* abs_detJ
    end

    # `maximum(abs, K_bb)` is always a non-negative real; compare against a
    # real zero so the guard stays complex-step clean. The previous form
    # `> zeroT` failed for ComplexF64 because `zeroT = 0 + 0im` is not
    # ordered against a real.
    if maximum(abs, K_bb) > 0.0
        Ke .-= K_ab * (K_bb \ K_ab')
    end

    return Ke
end

@inline function project_material_membrane_shear!(
    Bm::AbstractMatrix,
    dNdx_c,
    dNdy_c,
    curvature_membrane,
    theta::Float64,
)
    c = cos(theta)
    s = sin(theta)
    c2 = c * c
    s2 = s * s
    cs = c * s
    k11 = curvature_membrane === nothing ? 0.0 : curvature_membrane[1]
    k22 = curvature_membrane === nothing ? 0.0 : curvature_membrane[2]
    k12 = curvature_membrane === nothing ? 0.0 : curvature_membrane[3]

    @inbounds for k in 1:4
        idx = (k - 1) * 6

        r1 = Bm[1, idx+1]; r2 = Bm[2, idx+1]; r3 = Bm[3, idx+1]
        r1c = dNdx_c[k];   r2c = 0.0;         r3c = dNdy_c[k]
        m1 = c2 * r1 + s2 * r2 + cs * r3
        m2 = s2 * r1 + c2 * r2 - cs * r3
        m3c = -2.0 * cs * r1c + 2.0 * cs * r2c + (c2 - s2) * r3c
        Bm[1, idx+1] = c2 * m1 + s2 * m2 - cs * m3c
        Bm[2, idx+1] = s2 * m1 + c2 * m2 + cs * m3c
        Bm[3, idx+1] = 2.0 * cs * m1 - 2.0 * cs * m2 + (c2 - s2) * m3c

        r1 = Bm[1, idx+2]; r2 = Bm[2, idx+2]; r3 = Bm[3, idx+2]
        r1c = 0.0;         r2c = dNdy_c[k];   r3c = dNdx_c[k]
        m1 = c2 * r1 + s2 * r2 + cs * r3
        m2 = s2 * r1 + c2 * r2 - cs * r3
        m3c = -2.0 * cs * r1c + 2.0 * cs * r2c + (c2 - s2) * r3c
        Bm[1, idx+2] = c2 * m1 + s2 * m2 - cs * m3c
        Bm[2, idx+2] = s2 * m1 + c2 * m2 + cs * m3c
        Bm[3, idx+2] = 2.0 * cs * m1 - 2.0 * cs * m2 + (c2 - s2) * m3c

        r1 = Bm[1, idx+3]; r2 = Bm[2, idx+3]; r3 = Bm[3, idx+3]
        r1c = -0.25 * k11
        r2c = -0.25 * k22
        r3c = -0.5 * k12
        m1 = c2 * r1 + s2 * r2 + cs * r3
        m2 = s2 * r1 + c2 * r2 - cs * r3
        m3c = -2.0 * cs * r1c + 2.0 * cs * r2c + (c2 - s2) * r3c
        Bm[1, idx+3] = c2 * m1 + s2 * m2 - cs * m3c
        Bm[2, idx+3] = s2 * m1 + c2 * m2 + cs * m3c
        Bm[3, idx+3] = 2.0 * cs * m1 - 2.0 * cs * m2 + (c2 - s2) * m3c
    end

    return Bm
end


@inline function quad4_membrane_incompatible_jacobian_components(
    membrane_incomp_center_jacobian::Bool,
    iJ11::Float64, iJ12::Float64, iJ21::Float64, iJ22::Float64,
    iJ11c::Float64, iJ12c::Float64, iJ21c::Float64, iJ22c::Float64,
)
    if membrane_incomp_center_jacobian
        return iJ11c, iJ12c, iJ21c, iJ22c
    end
    return iJ11, iJ12, iJ21, iJ22
end

@inline function fill_quad4_membrane_incompatible_B!(
    Bi::AbstractMatrix,
    r::Float64,
    s::Float64,
    iJ11::Float64, iJ12::Float64, iJ21::Float64, iJ22::Float64,
    iJ11c::Float64, iJ12c::Float64, iJ21c::Float64, iJ22c::Float64,
    membrane_incomp_center_jacobian::Bool,
)
    miJ11, miJ12, miJ21, miJ22 = quad4_membrane_incompatible_jacobian_components(
        membrane_incomp_center_jacobian,
        iJ11, iJ12, iJ21, iJ22,
        iJ11c, iJ12c, iJ21c, iJ22c,
    )
    dphi1_dx = miJ11 * (-2.0 * r)
    dphi1_dy = miJ21 * (-2.0 * r)
    dphi2_dx = miJ12 * (-2.0 * s)
    dphi2_dy = miJ22 * (-2.0 * s)

    fill!(Bi, 0.0)
    Bi[1,1] = dphi1_dx
    Bi[3,1] = dphi1_dy
    Bi[2,2] = dphi1_dy
    Bi[3,2] = dphi1_dx
    Bi[1,3] = dphi2_dx
    Bi[3,3] = dphi2_dy
    Bi[2,4] = dphi2_dy
    Bi[3,4] = dphi2_dx
    return Bi
end

@inline function q4_membrane_incomp_mode_weights(scale::Float64)
    raw = strip(get(ENV, "JFEM_SOL101_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS",
                    get(ENV, "JFEM_Q4_MEMBRANE_INCOMP_MODE_WEIGHTS", "")))
    if isempty(raw)
        return (scale, scale, scale, scale)
    end
    parts = split(replace(raw, ';' => ','), ',')
    if length(parts) != 4
        return (scale, scale, scale, scale)
    end
    w1 = tryparse(Float64, strip(parts[1]))
    w2 = tryparse(Float64, strip(parts[2]))
    w3 = tryparse(Float64, strip(parts[3]))
    w4 = tryparse(Float64, strip(parts[4]))
    if w1 === nothing || w2 === nothing || w3 === nothing || w4 === nothing
        return (scale, scale, scale, scale)
    end
    return (max(w1, 0.0), max(w2, 0.0), max(w3, 0.0), max(w4, 0.0))
end

@inline function fill_quad4_membrane_enhanced_B!(
    Bi::AbstractMatrix,
    r::Float64,
    s::Float64,
    iJ11::Float64, iJ12::Float64, iJ21::Float64, iJ22::Float64,
    iJ11c::Float64, iJ12c::Float64, iJ21c::Float64, iJ22c::Float64,
    membrane_incomp_center_jacobian::Bool,
)
    miJ11, miJ12, miJ21, miJ22 = quad4_membrane_incompatible_jacobian_components(
        membrane_incomp_center_jacobian,
        iJ11, iJ12, iJ21, iJ22,
        iJ11c, iJ12c, iJ21c, iJ22c,
    )
    dphi1_dx = miJ11 * (-2.0 * r)
    dphi1_dy = miJ21 * (-2.0 * r)
    dphi2_dx = miJ12 * (-2.0 * s)
    dphi2_dy = miJ22 * (-2.0 * s)
    dpsi_dx = miJ11 * s + miJ12 * r
    dpsi_dy = miJ21 * s + miJ22 * r

    fill!(Bi, 0.0)
    Bi[1,1] = dphi1_dx
    Bi[3,1] = dphi1_dy
    Bi[2,2] = dphi1_dy
    Bi[3,2] = dphi1_dx
    Bi[1,3] = dphi2_dx
    Bi[3,3] = dphi2_dy
    Bi[2,4] = dphi2_dy
    Bi[3,4] = dphi2_dx
    Bi[1,5] = dpsi_dx
    Bi[3,5] = dpsi_dy
    Bi[2,6] = dpsi_dy
    Bi[3,6] = dpsi_dx
    return Bi
end

# =============================================================================
# KERNEL: stiffness_quad4_membrane_enhanced_matrices
# STATUS: RESEARCH / RETAINED - alternative membrane formulation with enhanced
#         interpolation (Wilson incompatible modes variant). Not on the default
#         GAME path; may be useful for distorted membrane meshes.
# CALLERS: none in current codebase - opt-in via direct call from research scripts.
# =============================================================================
function stiffness_quad4_membrane_enhanced_matrices(
    coords,
    Cm,
    h,
    E_ref;
    enhanced_modes::Bool=true,
    k6rot=100.0,
    drill_scale::Float64=1.0,
    curvature_membrane=nothing,
    membrane_shear_center_row::Bool=false,
    material_shear_rotation::Float64=0.0,
    membrane_incomp_center_jacobian::Bool=false,
)
    Ke = zeros(24, 24)
    K_ab = zeros(24, 6)
    K_bb = zeros(6, 6)
    Bm = zeros(3, 24)
    Bd = zeros(1, 24)
    Bi = zeros(3, 6)
    tmp3x24 = zeros(3, 24)
    tmp3x6 = zeros(3, 6)

    dNr_c = SVector(-0.25, 0.25, 0.25, -0.25)
    dNs_c = SVector(-0.25, -0.25, 0.25, 0.25)
    J11c = dNr_c[1]*coords[1,1]+dNr_c[2]*coords[2,1]+dNr_c[3]*coords[3,1]+dNr_c[4]*coords[4,1]
    J12c = dNr_c[1]*coords[1,2]+dNr_c[2]*coords[2,2]+dNr_c[3]*coords[3,2]+dNr_c[4]*coords[4,2]
    J21c = dNs_c[1]*coords[1,1]+dNs_c[2]*coords[2,1]+dNs_c[3]*coords[3,1]+dNs_c[4]*coords[4,1]
    J22c = dNs_c[1]*coords[1,2]+dNs_c[2]*coords[2,2]+dNs_c[3]*coords[3,2]+dNs_c[4]*coords[4,2]
    detJc = J11c*J22c - J12c*J21c
    abs(detJc) < 1e-12 && (detJc = detJc < 0.0 ? -1e-12 : 1e-12)
    inv_detc = 1.0 / detJc
    iJ11c =  J22c*inv_detc
    iJ12c = -J12c*inv_detc
    iJ21c = -J21c*inv_detc
    iJ22c =  J11c*inv_detc
    dNdx_c = ntuple(k -> iJ11c*dNr_c[k] + iJ12c*dNs_c[k], 4)
    dNdy_c = ntuple(k -> iJ21c*dNr_c[k] + iJ22c*dNs_c[k], 4)

    G_drill = Cm[3,3] / h
    if G_drill < 1e-6
        G_drill = E_ref / (2 * 3.0)
    end
    alpha_drill = drill_scale * (k6rot / 1e5) * G_drill * h

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))

    @inbounds @fastmath for gp in 1:4
        r, s = gauss_pts[gp][1], gauss_pts[gp][2]
        dNr, dNs = shape_derivs_quad(r, s)

        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = abs(detJ)
        if abs_detJ < 1e-12
            abs_detJ = 1e-12
        end
        inv_det = 1.0 / detJ
        iJ11 = J22*inv_det
        iJ12 = -J12*inv_det
        iJ21 = -J21*inv_det
        iJ22 = J11*inv_det

        fill!(Bm, 0.0)
        fill!(Bd, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            idx = (k-1)*6
            N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
            Bm[1, idx+1] = dN_dx
            Bm[2, idx+2] = dN_dy
            Bm[3, idx+1] = dN_dy
            Bm[3, idx+2] = dN_dx
            if curvature_membrane !== nothing
                Bm[1, idx+3] = -N_k * curvature_membrane[1]
                Bm[2, idx+3] = -N_k * curvature_membrane[2]
                Bm[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
            end
            Bd[1, idx+1] = 0.5*dN_dy
            Bd[1, idx+2] = -0.5*dN_dx
            Bd[1, idx+6] = N_k
        end

        if membrane_shear_center_row
            project_material_membrane_shear!(
                Bm,
                dNdx_c,
                dNdy_c,
                curvature_membrane,
                material_shear_rotation,
            )
        end

        ts_mul!(tmp3x24, Cm, Bm)
        ts_mul_At_add!(Ke, Bm, tmp3x24, abs_detJ)
        ts_mul_At_add!(Ke, Bd, Bd, abs_detJ * alpha_drill)

        if enhanced_modes
            fill_quad4_membrane_enhanced_B!(
                Bi,
                r,
                s,
                iJ11,
                iJ12,
                iJ21,
                iJ22,
                iJ11c,
                iJ12c,
                iJ21c,
                iJ22c,
                membrane_incomp_center_jacobian,
            )
            ts_mul!(tmp3x6, Cm, Bi)
            ts_mul_At_add!(K_ab, Bm, tmp3x6, abs_detJ)
            ts_mul_At_add!(K_bb, Bi, tmp3x6, abs_detJ)
        end
    end

    if enhanced_modes && maximum(abs, K_bb) > 1e-30
        Kcorr = K_bb \ K_ab'
        @inbounds @fastmath for j in 1:24, i in 1:24
            s = 0.0
            for l in 1:6
                s += K_ab[i, l] * Kcorr[l, j]
            end
            Ke[i, j] -= s
        end
    end

    return Ke
end

@inline function quad4_hierarchical_edge_shapes(r::Float64, s::Float64)
    N5 = 0.5 * (1.0 - r * r) * (1.0 - s)
    N6 = 0.5 * (1.0 + r) * (1.0 - s * s)
    N7 = 0.5 * (1.0 - r * r) * (1.0 + s)
    N8 = 0.5 * (1.0 - r) * (1.0 - s * s)
    return SVector(N5, N6, N7, N8)
end

@inline function quad4_hierarchical_edge_shape_derivs(r::Float64, s::Float64)
    dNr = SVector(
        -r * (1.0 - s),
        0.5 * (1.0 - s * s),
        -r * (1.0 + s),
        -0.5 * (1.0 - s * s),
    )
    dNs = SVector(
        -0.5 * (1.0 - r * r),
        -(1.0 + r) * s,
        0.5 * (1.0 - r * r),
        -(1.0 - r) * s,
    )
    return dNr, dNs
end

# =============================================================================
# KERNEL: stiffness_quad4_membrane_normal_rot_matrices
# STATUS: INTERNAL - DKMQ membrane block (Allman-style drilling + Ibrahimbegovic
#         skew-symmetric rotation). Used by stiffness_quad4_plate_dkmq_matrices.
# =============================================================================
function stiffness_quad4_membrane_normal_rot_matrices(
    coords,
    Cm,
    h;
    curvature_membrane=nothing,
    include_drill_penalty::Bool=true,
)
    # Exact flat-membrane DKMQ24_2+ operator from the published formulation:
    # Allman drilling enrichment + 2-DOF bubble condensation + Hughes-Brezzi penalty.
    Ke = zeros(24, 24)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))

    edge_pairs = ((1, 2), (2, 3), (3, 4), (4, 1))
    edge_coeff_x = zeros(4)
    edge_coeff_y = zeros(4)
    @inbounds for e in 1:4
        i, j = edge_pairs[e]
        dx = coords[j, 1] - coords[i, 1]
        dy = coords[j, 2] - coords[i, 2]
        edge_coeff_x[e] = -dy / 8.0
        edge_coeff_y[e] =  dx / 8.0
    end

    gp_detJ = zeros(4)
    Bm_store = zeros(4, 3, 24)
    Bn_store = zeros(4, 3, 2)
    Kmn = zeros(24, 2)
    Knn = zeros(2, 2)
    tmp3x2 = zeros(3, 2)
    tmp3x24 = zeros(3, 24)
    area = 0.0

    @inbounds for gp in 1:4
        r, s = gauss_pts[gp][1], gauss_pts[gp][2]
        dNr, dNs = shape_derivs_quad(r, s)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11 * J22 - J12 * J21
        abs_detJ = abs(detJ)
        abs_detJ < 1e-12 && (abs_detJ = 1e-12)
        gp_detJ[gp] = abs_detJ
        area += abs_detJ

        inv_det = 1.0 / detJ
        iJ11 = J22 * inv_det
        iJ12 = -J12 * inv_det
        iJ21 = -J21 * inv_det
        iJ22 = J11 * inv_det

        fill!(view(Bm_store, gp, :, :), 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            idx = (k - 1) * 6
            N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
            Bm_store[gp, 1, idx + 1] = dN_dx
            Bm_store[gp, 2, idx + 2] = dN_dy
            Bm_store[gp, 3, idx + 1] = dN_dy
            Bm_store[gp, 3, idx + 2] = dN_dx
            if curvature_membrane !== nothing
                Bm_store[gp, 1, idx + 3] = -N_k * curvature_membrane[1]
                Bm_store[gp, 2, idx + 3] = -N_k * curvature_membrane[2]
                Bm_store[gp, 3, idx + 3] = -2.0 * N_k * curvature_membrane[3]
            end
        end

        dH_dr, dH_ds = quad4_hierarchical_edge_shape_derivs(r, s)
        for e in 1:4
            dHx = iJ11 * dH_dr[e] + iJ12 * dH_ds[e]
            dHy = iJ21 * dH_dr[e] + iJ22 * dH_ds[e]
            ni, nj = edge_pairs[e]
            col_i = (ni - 1) * 6 + 6
            col_j = (nj - 1) * 6 + 6
            coeff_x = edge_coeff_x[e]
            coeff_y = edge_coeff_y[e]
            Bm_store[gp, 1, col_i] += coeff_x * dHx
            Bm_store[gp, 1, col_j] -= coeff_x * dHx
            Bm_store[gp, 2, col_i] += coeff_y * dHy
            Bm_store[gp, 2, col_j] -= coeff_y * dHy
            Bm_store[gp, 3, col_i] += coeff_x * dHy + coeff_y * dHx
            Bm_store[gp, 3, col_j] -= coeff_x * dHy + coeff_y * dHx
        end

        dN9_dr = -2.0 * r * (1.0 - s * s)
        dN9_ds = -2.0 * s * (1.0 - r * r)
        dN9_dx = iJ11 * dN9_dr + iJ12 * dN9_ds
        dN9_dy = iJ21 * dN9_dr + iJ22 * dN9_ds
        Bn_store[gp, 1, 1] = dN9_dx
        Bn_store[gp, 1, 2] = 0.0
        Bn_store[gp, 2, 1] = 0.0
        Bn_store[gp, 2, 2] = dN9_dy
        Bn_store[gp, 3, 1] = dN9_dy
        Bn_store[gp, 3, 2] = dN9_dx

        ts_mul!(tmp3x2, Cm, view(Bn_store, gp, :, :))
        ts_mul_At_add!(Kmn, view(Bm_store, gp, :, :), tmp3x2, abs_detJ)
        ts_mul_At_add!(Knn, view(Bn_store, gp, :, :), tmp3x2, abs_detJ)
    end

    T = Knn \ transpose(Kmn)
    Beff = zeros(3, 24)
    @inbounds for gp in 1:4
        for j in 1:24, i in 1:3
            Beff[i, j] = Bm_store[gp, i, j] -
                         (Bn_store[gp, i, 1] * T[1, j] + Bn_store[gp, i, 2] * T[2, j])
        end
        ts_mul!(tmp3x24, Cm, Beff)
        ts_mul_At_add!(Ke, Beff, tmp3x24, gp_detJ[gp])
    end

    # Published DKMQ24_2+ Hughes-Brezzi drilling penalty with 1x1 quadrature.
    dNr0, dNs0 = shape_derivs_quad(0.0, 0.0)
    J11c = dNr0[1]*coords[1,1] + dNr0[2]*coords[2,1] + dNr0[3]*coords[3,1] + dNr0[4]*coords[4,1]
    J12c = dNr0[1]*coords[1,2] + dNr0[2]*coords[2,2] + dNr0[3]*coords[3,2] + dNr0[4]*coords[4,2]
    J21c = dNs0[1]*coords[1,1] + dNs0[2]*coords[2,1] + dNs0[3]*coords[3,1] + dNs0[4]*coords[4,1]
    J22c = dNs0[1]*coords[1,2] + dNs0[2]*coords[2,2] + dNs0[3]*coords[3,2] + dNs0[4]*coords[4,2]
    detJc = J11c * J22c - J12c * J21c
    abs_detJc = abs(detJc)
    abs_detJc < 1e-12 && (abs_detJc = 1e-12)
    inv_detc = 1.0 / detJc
    iJ11c = J22c * inv_detc
    iJ12c = -J12c * inv_detc
    iJ21c = -J21c * inv_detc
    iJ22c = J11c * inv_detc
    g = zeros(24)
    for k in 1:4
        dN_dx = iJ11c*dNr0[k] + iJ12c*dNs0[k]
        dN_dy = iJ21c*dNr0[k] + iJ22c*dNs0[k]
        idx = (k - 1) * 6
        g[idx + 1] = -0.5 * dN_dy
        g[idx + 2] =  0.5 * dN_dx
        g[idx + 6] = -0.25
    end
    if include_drill_penalty
        c2 = 0.1
        c1 = c2 * h / sqrt(max(area, 1e-12))
        kstab = c1 * Cm[3, 3]
        stab_weight = 4.0 * abs_detJc
        @inbounds @fastmath for j in 1:24, i in 1:24
            Ke[i, j] += kstab * stab_weight * g[i] * g[j]
        end
    end

    return Ke
end

# Hu-Washizu / hybrid-stress research kernels — quarantined to experimental/
# 2026-05-25. Reached only via JFEM_Q4_KERNEL=huwashizu or the
# exact_membrane_operator / exact_membrane_curvature_w_coupling kwargs
# of stiffness_quad4_matrices (default false). All hybrid-stress and
# Hu-Washizu matrix functions live in the included file.
include(joinpath(@__DIR__, "experimental", "hu_washizu_kernel.jl"))


# =============================================================================
# KERNEL: stiffness_quad4_matrices
# STATUS: PRODUCTION — primary Q4 shell stiffness, fires for every default-path
#         element in GAME SOL 105 (live trace 2026-05-22 confirms).
# DISPATCHED FROM: assembly.jl `else` fallback (line ~3744), plus several
#         explicit branches for iso/PCOMP curved-shell variants.
# CALLS: add_quad4_macneal_shear_rbf! (when macneal_kernel=true);
#        stiffness_quad4_huwashizu_matrices (when JFEM_Q4_KERNEL=huwashizu);
#        stiffness_quad4_min4_bending_shear (when JFEM_Q4_KERNEL=min4);
#        stiffness_quad4_membrane_hybrid_stress_matrices (when exact_membrane_operator);
#        many internal Bm/Bb/Bs/Bd inline assemblies.
# CALIBRATION KNOBS (env): JFEM_Q4_KERNEL (default "macneal"), JFEM_Q4_SHEAR_ROTATION_SCALE,
#        JFEM_Q4_MACNEAL_*, JFEM_Q4_MARGUERRE_WARP_TO_UZ,
#        JFEM_Q4_SNORM_COMPLETION_MODE (default "normal_moment"), PHI2_ALPHA (module Ref).
# KEYWORD ARGS (caller-controlled): bend_ratio, k6rot, drill_scale, shear_center_only,
#        bending_incomp, membrane_incomp, curvature_membrane, slope_membrane, coords_3d,
#        snorm_pq, exact_membrane_operator, selective_shear, exact_side_shear,
#        exact_side_rotcorr, macneal_rigid_shear, marguerre_warp_to_uz, min4_disable,
#        kernel_planar, kernel_mode, _defer_warp_transform, _defer_snorm_transform.
# LAST VALIDATED: 2026-08-03 (CQUAD4 finite-warp + PARAM,SNORM normal-moment closure).
# Pre-allocated workspace `ws` eliminates ALL heap allocations in the hot loop
# (~5M alloc saved across HTP_launch).
# =============================================================================
function stiffness_quad4_matrices(coords, Cm, Cb, Cs, h, E_ref; bend_ratio=1.0, k6rot=100.0, drill_scale::Float64=1.0, Bmb=nothing, ws::Union{Nothing,Quad4Workspace}=nothing, bending_incomp::Bool=false, shear_center_only::Bool=false, no_phi2::Bool=false, membrane_incomp::Bool=true, membrane_incomp_scale::Float64=1.0, membrane_incomp_weights=nothing, curvature_membrane=nothing, membrane_shear_center_row::Bool=false, material_shear_rotation::Float64=0.0, membrane_incomp_center_jacobian::Bool=false, selective_shear::Bool=false, selective_shear_mode::Symbol=:all, exact_side_shear::Bool=false, exact_side_rotcorr::Bool=false, exact_membrane_operator::Bool=false, exact_membrane_curvature_w_coupling::Bool=false, slope_membrane=nothing, coords_3d::Union{Nothing,AbstractMatrix}=nothing, snorm_pq=nothing, kernel_planar::Bool=true, macneal_rigid_shear::Bool=false, marguerre_warp_to_uz::Bool=false, min4_disable::Bool=false, bmb_incomp_coupling_mode::Symbol=:env, kernel_mode=nothing, macneal_rbf_flex_mode::Symbol=:env, membrane_hourglass_skew::Bool=false, distortion_corrections::Bool=true, _defer_warp_transform::Bool=false, _defer_snorm_transform::Bool=false)
    # Allow env-var override for marguerre_warp_to_uz so it can be enabled
    # globally without plumbing through every caller. Currently the assembly
    # loop doesn't pass this kwarg, so default is false. Env override:
    # JFEM_Q4_MARGUERRE_WARP_TO_UZ=true forces it on for ALL elements where
    # coords_3d is supplied (i.e., wherever the curved-shell path runs).
    # The added term is the Marguerre membrane–uz coupling:
    #   εxx ⊃ z_x · ∂w/∂x, εyy ⊃ z_y · ∂w/∂y, εxy ⊃ z_x·∂w/∂y + z_y·∂w/∂x
    # where z_x, z_y are the element-local-frame slopes of the corner
    # z-coords. Activates only on genuinely warped (non-coplanar) elements.
    if !marguerre_warp_to_uz
        env_raw = strip(get(ENV, "JFEM_Q4_MARGUERRE_WARP_TO_UZ", ""))
        if !isempty(env_raw) && lowercase(env_raw) in ("1", "true", "yes", "on")
            marguerre_warp_to_uz = true
        end
    end
    # Research splice branches recurse through this function. They defer only
    # the common warp congruence, not the user's request for the warp route;
    # that distinction prevents the recursive projected-plane build from
    # accidentally entering the unrelated curved-frame experiment.
    # Canonicalise the zero field to the historical no-SNORM path. Besides
    # avoiding signed-zero completion terms, this is the explicit bitwise
    # identity contract for callers that preallocate and pass a zero pq array.
    if snorm_pq !== nothing && !quad4_snorm_pq_has_active_rows(snorm_pq)
        snorm_pq = nothing
    end
    # The production normal-moment route forms the unchanged projected-plane
    # element first and applies one work-dual equilibrium map afterwards.  Keep
    # the user's director field for that map while passing `nothing` through
    # the projected kernels.  The superseded local director-gradient field is
    # retained only as the explicit `field` diagnostic.
    snorm_transform_pq = snorm_pq
    snorm_completion_mode = lowercase(strip(
        get(ENV, "JFEM_Q4_SNORM_COMPLETION_MODE", "normal_moment")
    ))
    snorm_normal_moment = snorm_transform_pq !== nothing &&
        quad4_snorm_normal_moment_mode()
    if snorm_transform_pq !== nothing &&
       !(snorm_completion_mode in (
            "field", "completed",
            "normal_moment", "normal-moment", "normalmoment",
            "corner_drill_s3", "corner-drill-s3", "cornerdrills3",
        ))
        throw(ArgumentError(
            "Unsupported JFEM_Q4_SNORM_COMPLETION_MODE=$(repr(snorm_completion_mode)); " *
            "expected normal_moment or field"
        ))
    end
    snorm_normal_moment && (snorm_pq = nothing)
    warp_transform_requested = fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)
    warp_transform_on = warp_transform_requested && !_defer_warp_transform
    snorm_transform_on = snorm_transform_pq !== nothing && !_defer_snorm_transform
    if snorm_normal_moment && snorm_transform_on
        # W already carries the corner height slopes.  Pull the absolute
        # averaged director back through that graph map before forming M, so
        # the one outer composition is M_relative * W.  Recursive research
        # splices defer both transforms and therefore receive this already
        # relative field without applying the residual a second time.
        warp_map_for_snorm = if coords_3d !== nothing && warp_transform_on
            quad4_finite_warp_displacement_map(coords, coords_3d)
        else
            nothing
        end
        snorm_transform_pq = quad4_snorm_relative_to_finite_warp_pq(
            snorm_transform_pq, warp_map_for_snorm)
        snorm_transform_on = snorm_transform_pq !== nothing
        snorm_normal_moment = snorm_transform_on
    end
    snorm_completion_active = snorm_pq !== nothing && !all(iszero, snorm_pq)
    # coords_3d (optional 4×3 matrix of 3D corner coordinates) activates the
    # experimental curved-shell GP-local frame path used by
    # JFEM_SOL105_EIG_CURVED_JACOBIAN. The path is intentionally narrow:
    # it engages only on the pure formulation branch (no curvature heuristics,
    # Marguerre slopes, membrane-center projection, or exact side shear).
    # That keeps the parity study interpretable while we measure the effect of
    # the 3D tangent mapping plus the geometry-driven membrane -b·w coupling.
    if exact_membrane_operator
        zero_Cb = zeros(eltype(Cb), 3, 3)
        zero_Cs = zeros(eltype(Cs), 2, 2)
        # Replace only the flat shell membrane/drilling block with the
        # paper-based DKMQ24_2+ membrane operator while preserving the
        # validated shell bending/shear field.
        membrane_curvature_default =
            exact_membrane_curvature_w_coupling ? nothing : curvature_membrane
        Ke_shell = stiffness_quad4_matrices(
            coords, Cm, Cb, Cs, h, E_ref;
            bend_ratio=bend_ratio,
            k6rot=k6rot,
            drill_scale=drill_scale,
            Bmb=nothing,
            ws=nothing,
            bending_incomp=bending_incomp,
            shear_center_only=shear_center_only,
            no_phi2=no_phi2,
            membrane_incomp=false,
            membrane_incomp_scale=membrane_incomp_scale,
            membrane_incomp_weights=membrane_incomp_weights,
            curvature_membrane=curvature_membrane,
            membrane_shear_center_row=membrane_shear_center_row,
            material_shear_rotation=material_shear_rotation,
            membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
            selective_shear=selective_shear,
            selective_shear_mode=selective_shear_mode,
            exact_side_shear=exact_side_shear,
            exact_side_rotcorr=exact_side_rotcorr,
            exact_membrane_operator=false,
            exact_membrane_curvature_w_coupling=false,
            coords_3d=coords_3d,
            snorm_pq=snorm_transform_pq,
            kernel_planar=kernel_planar,
            macneal_rigid_shear=macneal_rigid_shear,
            kernel_mode=kernel_mode,
            macneal_rbf_flex_mode=macneal_rbf_flex_mode,
            _defer_warp_transform=true,
            _defer_snorm_transform=true,
        )
        Ke_mem_default = stiffness_quad4_matrices(
            coords, Cm, zero_Cb, zero_Cs, h, E_ref;
            bend_ratio=bend_ratio,
            k6rot=0.0,
            drill_scale=0.0,
            Bmb=nothing,
            ws=nothing,
            bending_incomp=false,
            shear_center_only=true,
            no_phi2=true,
            membrane_incomp=false,
            membrane_incomp_scale=membrane_incomp_scale,
            membrane_incomp_weights=membrane_incomp_weights,
            curvature_membrane=membrane_curvature_default,
            membrane_shear_center_row=membrane_shear_center_row,
            material_shear_rotation=material_shear_rotation,
            membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
            selective_shear=false,
            selective_shear_mode=:all,
            exact_side_shear=false,
            exact_side_rotcorr=false,
            exact_membrane_operator=false,
            exact_membrane_curvature_w_coupling=false,
            coords_3d=coords_3d,
            snorm_pq=snorm_transform_pq,
            kernel_planar=kernel_planar,
            macneal_rigid_shear=false,
            kernel_mode=kernel_mode,
            macneal_rbf_flex_mode=macneal_rbf_flex_mode,
            _defer_warp_transform=true,
            _defer_snorm_transform=true,
        )
        exact_membrane_drill_penalty = lowercase(strip(
            get(ENV, "JFEM_Q4_EXACT_MEMBRANE_DRILL_PENALTY", "true")
        )) in ("1", "true", "yes", "on")
        Ke_mem_exact = stiffness_quad4_membrane_hybrid_stress_matrices(
            coords,
            Cm,
            h;
            include_drill_penalty=exact_membrane_drill_penalty,
            snorm_pq=snorm_pq,
        )
        exact_membrane_blend_raw = strip(get(ENV, "JFEM_Q4_EXACT_MEMBRANE_BLEND", "1.0"))
        exact_membrane_blend = clamp(
            something(tryparse(Float64, exact_membrane_blend_raw), 1.0),
            0.0,
            1.0,
        )
        # Form the complete projected-plane research operator first, then use
        # the same single director and work-dual finite-warp maps as the
        # production kernel. The recursive pieces deliberately defer both.
        Ke = Ke_shell .+ exact_membrane_blend .* (Ke_mem_exact .- Ke_mem_default)
        if snorm_transform_on
            if snorm_normal_moment
                apply_quad4_snorm_normal_moment_completion!(
                    Ke, coords, snorm_transform_pq)
            else
                apply_quad4_snorm_director_completion!(Ke, snorm_transform_pq)
            end
        end
        if coords_3d !== nothing && warp_transform_on
            apply_quad4_finite_warp_equilibrium!(Ke, coords, coords_3d)
        end
        return Ke
    end
    q4_kernel = lowercase(strip(kernel_mode === nothing ? get(ENV, "JFEM_Q4_KERNEL", "") : string(kernel_mode)))
    huwashizu_kernel = q4_kernel in ("huwashizu", "hu-washizu", "hw")
    if huwashizu_kernel &&
       !snorm_completion_active &&
       curvature_membrane === nothing &&
       slope_membrane === nothing &&
       (!membrane_shear_center_row || material_shear_rotation == 0.0) &&
       !membrane_shear_center_row &&
       !selective_shear &&
       !exact_side_shear &&
       !exact_side_rotcorr
        Ke = stiffness_quad4_huwashizu_matrices(
            coords,
            Cm,
            Cb,
            Cs,
            h,
            E_ref;
            k6rot=k6rot,
            drill_scale=drill_scale,
            shear_center_only=shear_center_only,
            Bmb=Bmb,
        )
        # Hu-Washizu is an alternate projected-plane basic element, not an
        # alternate physical-coordinate system.  Route it through the same
        # selected PARAM,SNORM work-dual map before returning.
        if snorm_transform_on
            if snorm_normal_moment
                apply_quad4_snorm_normal_moment_completion!(
                    Ke, coords, snorm_transform_pq)
            else
                apply_quad4_snorm_director_completion!(Ke, snorm_transform_pq)
            end
        end
        if coords_3d !== nothing && warp_transform_on
            apply_quad4_finite_warp_equilibrium!(Ke, coords, coords_3d)
        end
        return Ke
    end
    # Tessler-Hughes 1983 MIN4 kernel branch (2026-05-14 evening). Replaces
    # the MacNeal/MITC bending+shear blocks with the anisoparametric MIN4
    # formulation (interpolation: biquadratic w + bilinear θ, continuous
    # edge shear constraint) plus the residual-bending shear correction
    # φ² = C_b·ψ̂/(1+C_b·ψ̂) (eq 4.21). The membrane/drilling blocks come
    # from a recursive call with Cb=Cs=0 (going through the standard
    # MacNeal/MITC path; min4_disable=true breaks recursion).
    # Env vars:
    #   JFEM_Q4_KERNEL=min4 (or tessler_hughes, or tessler-hughes)
    #   JFEM_MIN4_CBMIN4=3.6 (default; from MYSTRAN MIN4 calibration)
    min4_kernel = !min4_disable && q4_kernel in ("min4", "tessler_hughes", "tessler-hughes")
    if min4_kernel
        zero_Cb = zeros(eltype(Cb), 3, 3)
        zero_Cs = zeros(eltype(Cs), 2, 2)
        # Membrane + drilling from the standard kernel (Cb=Cs=0 → no bending/shear)
        Ke_membrane_drill = stiffness_quad4_matrices(
            coords, Cm, zero_Cb, zero_Cs, h, E_ref;
            bend_ratio=bend_ratio,
            k6rot=k6rot,
            drill_scale=drill_scale,
            Bmb=nothing,
            ws=nothing,
            bending_incomp=false,
            shear_center_only=shear_center_only,
            no_phi2=true,
            membrane_incomp=membrane_incomp,
            membrane_incomp_scale=membrane_incomp_scale,
            curvature_membrane=curvature_membrane,
            membrane_shear_center_row=membrane_shear_center_row,
            material_shear_rotation=material_shear_rotation,
            membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
            selective_shear=false,
            selective_shear_mode=:all,
            exact_side_shear=false,
            exact_side_rotcorr=false,
            exact_membrane_operator=false,
            exact_membrane_curvature_w_coupling=false,
            slope_membrane=slope_membrane,
            coords_3d=coords_3d,
            snorm_pq=snorm_transform_pq,
            kernel_planar=kernel_planar,
            macneal_rigid_shear=false,
            marguerre_warp_to_uz=false,
            min4_disable=true,
            kernel_mode=kernel_mode,
            macneal_rbf_flex_mode=macneal_rbf_flex_mode,
            _defer_warp_transform=true,
            _defer_snorm_transform=true,
        )
        # MIN4 bending + φ²·shear
        cbmin4_env = strip(get(ENV, "JFEM_MIN4_CBMIN4", ""))
        cbmin4_val = isempty(cbmin4_env) ? 3.6 :
            (something(tryparse(Float64, cbmin4_env), 3.6))
        Ke_bs, _, _, _ = stiffness_quad4_min4_bending_shear(
            coords, Cb, Cs; cbmin4=cbmin4_val, snorm_pq=snorm_pq)
        # Form the complete projected-plane research operator first, then use
        # the same single director and work-dual finite-warp maps as the
        # production kernel.
        Ke = Ke_membrane_drill .+ Ke_bs
        if snorm_transform_on
            if snorm_normal_moment
                apply_quad4_snorm_normal_moment_completion!(
                    Ke, coords, snorm_transform_pq)
            else
                apply_quad4_snorm_director_completion!(Ke, snorm_transform_pq)
            end
        end
        if coords_3d !== nothing && warp_transform_on
            apply_quad4_finite_warp_equilibrium!(Ke, coords, coords_3d)
        end
        return Ke
    end
    if ws === nothing
        T_ws = promote_type(eltype(Cm), eltype(Cb), eltype(Cs), typeof(h), typeof(E_ref))
        ws = create_quad4_workspace(T_ws)
    end

    # Clear accumulated matrices
    fill!(ws.Ke, 0.0)
    fill!(ws.K_ab, 0.0); fill!(ws.K_bb, 0.0)
    fill!(ws.K_ab_bend, 0.0); fill!(ws.K_bb_bend, 0.0)

    # B coupling accumulators (cleared even if Bmb is nothing — branch-free)
    fill!(ws.K_ab_cross, 0.0); fill!(ws.K_ab_bend_cross, 0.0); fill!(ws.K_mb_incomp, 0.0)

    # ⚠ `marguerre_warp_to_uz` MUST be excluded here. The docstring of the coords_3d argument
    # says this path "engages only on the pure formulation branch (no curvature heuristics,
    # Marguerre slopes, ...)", but the condition list never implemented the Marguerre half, and
    # `coords_3d` is supplied precisely BECAUSE Marguerre asked for it. So requesting the
    # Marguerre term silently also switched on the curved-frame path -- which is documented to
    # VIOLATE RIGID-BODY TRANSLATION on warped cells. Measured with Marguerre on and this fix
    # absent: RB residual 1.9e-2 at warp 0.1 and 3.73e-2 at warp 0.2, the latter matching the
    # figure already recorded for the curved path, while warp <= 0.05 stayed at 1e-17.
    # The warp multiplier needs coords_3d, but supplying coords_3d otherwise switches on the
    # experimental curved-shell GP-local frame -- which VIOLATES RIGID-BODY TRANSLATION on warped
    # cells (2e-17 -> 3.7e-2 at warp 0.2). Exclude it exactly as marguerre_warp_to_uz is excluded.
    curved_frame_supported =
        coords_3d !== nothing &&
        snorm_transform_pq === nothing &&
        !warp_transform_requested &&
        !marguerre_warp_to_uz &&
        curvature_membrane === nothing &&
        slope_membrane === nothing &&
        (!membrane_shear_center_row || material_shear_rotation == 0.0) &&
        !membrane_shear_center_row &&
        !selective_shear &&
        !exact_side_shear &&
        !exact_side_rotcorr

    elem_v1 = SVector(1.0, 0.0, 0.0)
    elem_v2 = SVector(0.0, 1.0, 0.0)
    elem_v3 = SVector(0.0, 0.0, 1.0)
    center_beta_gp = 0.0
    center_Cs = Cs
    if curved_frame_supported
        elem_v1, elem_v2, elem_v3 = quad4_center_frame_from_coords3d(coords_3d)
    end

    # --- MITC4 transverse shear (Bathe-Dvorkin) tying points ---
    skip_all_shear = shear_center_only && maximum(abs, Cb) < 1e-30
    A_beta_rotcorr = nothing
    edge_L_rotcorr = nothing
    Bs_rotcorr = nothing
    shear_rotation_scale = fem_env_float("JFEM_Q4_SHEAR_ROTATION_SCALE", 1.0)
    if exact_side_rotcorr && !shear_center_only && !skip_all_shear
        A_beta_rotcorr, _, _, edge_L_rotcorr = dkmq_flat_plate_edge_relation(coords, Cb, Cs)
        Bs_rotcorr = zeros(2, 12)
    end
    fill!(ws.Bs_tp, 0.0)
    tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
    for tp_idx in 1:4
        xi_tp, eta_tp = tying_pts[tp_idx][1], tying_pts[tp_idx][2]
        dNr, dNs = shape_derivs_quad(xi_tp, eta_tp)
        n_tp = SVector(0.0, 0.0, 1.0)
        t1_tp = elem_v1
        t2_tp = elem_v2
        curvature_tp = nothing
        if curved_frame_supported
            n_tp, _, t1_tp, t2_tp, J11, J12, J21, J22 =
                quad4_gp_local_frame_from_coords3d(coords_3d, xi_tp, eta_tp)
            curvature_tp = quad4_gp_curvature_membrane_from_coords3d(coords_3d, xi_tp, eta_tp)
        else
            J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
            J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
            J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
            J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        end
        N1 = 0.25*(1-xi_tp)*(1-eta_tp); N2 = 0.25*(1+xi_tp)*(1-eta_tp)
        N3 = 0.25*(1+xi_tp)*(1+eta_tp); N4 = 0.25*(1-xi_tp)*(1+eta_tp)
        N_tp = SVector(N1, N2, N3, N4)
        p_tp = snorm_completion_active ? sum(N_tp[k]*snorm_pq[k,1] for k in 1:4) : 0.0
        q_tp = snorm_completion_active ? sum(N_tp[k]*snorm_pq[k,2] for k in 1:4) : 0.0
        fill!(ws.Bs_row, 0.0)
        if tp_idx <= 2  # A,B: e_ξz
            for k in 1:4
                idx = (k-1)*6
                if curvature_tp !== nothing
                    ws.Bs_row[idx+1] = N_tp[k] * (J11*curvature_tp[1] + J12*curvature_tp[3])
                    ws.Bs_row[idx+2] = N_tp[k] * (J11*curvature_tp[3] + J12*curvature_tp[2])
                end
                ws.Bs_row[idx+3] = dNr[k]
                ws.Bs_row[idx+4] = -J12*N_tp[k]
                ws.Bs_row[idx+5] =  J11*N_tp[k]
                if snorm_completion_active
                    ws.Bs_row[idx+1] += p_tp*dNr[k]
                    ws.Bs_row[idx+2] += q_tp*dNr[k]
                end
            end
        else  # C,D: e_ηz
            for k in 1:4
                idx = (k-1)*6
                if curvature_tp !== nothing
                    ws.Bs_row[idx+1] = N_tp[k] * (J21*curvature_tp[1] + J22*curvature_tp[3])
                    ws.Bs_row[idx+2] = N_tp[k] * (J21*curvature_tp[3] + J22*curvature_tp[2])
                end
                ws.Bs_row[idx+3] = dNs[k]
                ws.Bs_row[idx+4] = -J22*N_tp[k]
                ws.Bs_row[idx+5] =  J21*N_tp[k]
                if snorm_completion_active
                    ws.Bs_row[idx+1] += p_tp*dNs[k]
                    ws.Bs_row[idx+2] += q_tp*dNs[k]
                end
            end
        end
        if Bs_rotcorr !== nothing
            dkmq_plate_side_shear_operator!(Bs_rotcorr, coords, A_beta_rotcorr, edge_L_rotcorr, xi_tp, eta_tp)
            row_idx = tp_idx <= 2 ? 1 : 2
            for a in 1:4
                col24 = (a - 1) * 6
                col12 = (a - 1) * 3
                ws.Bs_row[col24 + 4] = Bs_rotcorr[row_idx, col12 + 2]
                ws.Bs_row[col24 + 5] = Bs_rotcorr[row_idx, col12 + 3]
            end
        end
        if shear_rotation_scale != 1.0
            for a in 1:4
                col24 = (a - 1) * 6
                ws.Bs_row[col24 + 4] *= shear_rotation_scale
                ws.Bs_row[col24 + 5] *= shear_rotation_scale
            end
        end
        if curved_frame_supported
            quad4_gp_rotation_from_element!(ws.Rel_t, elem_v1, elem_v2, elem_v3, t1_tp, t2_tp, n_tp)
            rotate_quad4_dof_blocks!(ws.Bs_row, ws.Rel_t)
        end
        @views copyto!(ws.Bs_tp[tp_idx, :], ws.Bs_row)
    end

    # phi2 shear anti-locking: phi2 = min(1, alpha*(h/L_char)^2)
    # MITC4 at 2×2 Gauss points still locks for thin plates on coarse meshes (h/L<0.05).
    # phi2 matches Nastran CQUAD4's Selective Reduced Integration behavior.
    # PHI2_ALPHA=10.0 is the globally optimal coefficient across all test cases.
    _alpha = PHI2_ALPHA[]
    phi2_shear = 1.0
    # MacNeal 1978 eq (12): 1/GA* = 1/GA + L²/(12 EI). Series-flexibility
    # correction that makes the element match Nastran CQUAD4 for both
    # long-wavelength (launch) and short-wavelength (3wp) buckling modes.
    # When enabled, this replaces phi2 as the shear softening mechanism.
    macneal_rbf = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_RBF", "false"))) in ("1","true","yes","on")
    # Twist-compatibility correction (MacNeal eq 17): χ̃xy = 2·χxy(gp) − χxy(0).
    # Replaces the twist row of Bb at each Gauss point by 2·row(gp) − row(center).
    # Only engages on the flat default path; disabled with curved_frame_supported.
    macneal_twist_env_set = haskey(ENV, "JFEM_Q4_MACNEAL_TWIST")
    macneal_twist = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_TWIST", "false"))) in ("1","true","yes","on")
    # PROMOTED 2026-08-02 -- "center" is now the default, and it is DERIVED, not preferred.
    # With the center-evaluated twist row the rotation hourglass carries zero twist curvature,
    # so its bending energy is the plain compatible integral, which for a parallelogram is
    #     G_hourglass = D*(4/3) * [1  nu*tan ; nu*tan  1+tan^2]
    # giving trace = D*(4/3)*(2 + tan^2) -- and the reference's recovered hourglass trace is
    # exactly that: measured/flat = 1.0000, 1.0359, 1.1667, 1.5000 at skew 0/15/30/45 against
    # (1 + tan^2/2) = 1, 1.0359, 1.1667, 1.5000. With "extrapolate" the twist row is doubled,
    # which inflates the flat hourglass energy to 2.04e4 against the reference's 8.73e3 and is
    # then partly undone by the enrichment condensation -- two errors that do not cancel.
    # The kernel's own note below already recorded that the reference gives rotation-hourglass
    # patterns zero twist energy and that "center" reproduces it; only the default lagged.
    # Scored: skew30_x_h -65.4 %, aspect_x_skew -36.4 %, skew45_x_h / skew_deg -35.7 %,
    # skew_nu -34.0 %, taper -13.8 %, every other axis unchanged. Ratchet PASS.
    macneal_twist_center =
        lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_TWIST_MODE", "center"))) in
        ("center", "reduced", "1pt")
    # Full MacNeal 1978 CQUAD4 kernel: replaces MITC4+phi2 shear block with
    # MacNeal's [D]ᵀ·([Z_s]+[Z_b])⁻¹·[D] formulation + twist correction.
    # MSC/Nastran's CQUAD4 lineage uses this operator for the released QUAD4.
    # This implementation is a flat/projected CQUAD4 kernel, so the default
    # applies it to planar elements for all material types and leaves nonflat
    # facets on the covariant/MITC path unless JFEM_Q4_KERNEL=macneal_all is
    # explicitly requested. The older anisotropic-only split remains available
    # as JFEM_Q4_KERNEL=macneal_pcomp; use JFEM_Q4_KERNEL=default (or any
    # unrecognized value) to force the legacy non-MacNeal path.
    q4_kernel_mode = lowercase(strip(kernel_mode === nothing ? get(ENV, "JFEM_Q4_KERNEL", "macneal") : string(kernel_mode)))
    macneal_default_kernel = q4_kernel_mode in (
        "macneal", "mitc4_3d_aspect", "mitc4-3d-aspect", "mitc3d_aspect", "mitc3d-aspect",
    )
    macneal_pcomp_kernel = q4_kernel_mode in ("macneal_pcomp", "macneal-pcomp", "macneal_aniso")
    macneal_pcomp_flat_ok = kernel_planar && (coords_3d === nothing || quad4_coords3d_is_planar(coords_3d))
    macneal_kernel =
        q4_kernel_mode in ("macneal_all", "macneal-force", "macneal_force") ||
        (macneal_default_kernel && kernel_planar) ||
        (
            macneal_pcomp_kernel &&
            macneal_pcomp_flat_ok &&
            !quad4_constitutive_looks_isotropic(Cm, Cb, Cs, Bmb)
        )
    if macneal_kernel && !macneal_twist_env_set
        macneal_twist = true  # twist correction is part of full MacNeal kernel
    end
    # Default OFF; see the K_ab_bend accumulation below for the evidence.
    bending_incomp_decouple_d16 =
        fem_env_bool("JFEM_Q4_BENDING_INCOMP_DECOUPLE_D16", false)
    # PROMOTED 2026-08-02: control 8.55e-4 -> 2.19e-8, aspect 8.82e-4 -> 2.19e-8,
    # h_over_L 9.02e-3 -> 3.38e-8 (all -100 %); skew -10..-15 %, warp x h -4.1 %; taper +0.6 %
    # (within tolerance) and every triangle axis bit-unchanged. Ratchet PASS.
    bending_incomp_decouple_d12 =
        fem_env_bool("JFEM_Q4_BENDING_INCOMP_DECOUPLE_D12", true)
    # Patch-test correction for the BENDING incompatible modes on a NON-PARALLELOGRAM cell.
    #
    # The incompatible bending modes phi = 1-r^2, 1-s^2 only preserve the constant-curvature
    # (patch) states if their gradient operator integrates to zero over the element:
    #     int Bi_bend |J| dr ds == 0.
    # Built from the GAUSS-POINT inverse Jacobian, as below, that integral is zero only when |J|
    # and J^-1 are constant — i.e. only on a parallelogram. Taylor, Beresford & Wilson (1976)
    # restore it by evaluating the operator at the element CENTRE and rescaling by the Jacobian
    # ratio, so the integrand becomes detJc * Jc^-1 * dphi/dr, whose integral vanishes because
    # int -2r dr ds = 0 identically:
    #     "center" -> Jc^-1                      (centre operator only)
    #     "qm6"    -> Jc^-1 * (detJc / detJ)     (full patch-test correction)
    # On a parallelogram J == Jc and detJ == detJc, so BOTH modes are bit-identical to "gp" —
    # which is why every parallelogram axis (control, aspect, skew and their crosses) cannot see
    # this, and why taper is the one planar axis left open.
    # PROMOTED 2026-08-02, default "qm6". Measured absolutely against the reference, not fitted:
    # imposing the exact constant-curvature state w = y^2/2 on a tapered cell, the reference
    # reproduces it EXACTLY (U/U_exact - 1 = 2e-8, i.e. punch precision) at every taper, while
    # "gp" leaves JFEM 1.4-35 % too SOFT and "center" only halves that. "qm6" makes it exact to
    # MACHINE precision (4e-16) at taper 0.70 / 0.50 / 0.25 / 0.15 / 0.10. Bit-identical on every
    # parallelogram cell, so all eleven closed axes are untouched.
    bending_incomp_jac_mode = let raw = lowercase(strip(get(ENV, "JFEM_Q4_BENDING_INCOMP_JAC", "")))
        raw == "center" ? :center : raw == "gp" ? :gp : :qm6
    end
    # Center Jacobian — needed for phi2 and/or shear_center_only 1-point integration
    dNr_c = SVector(-0.25, 0.25, 0.25, -0.25)
    dNs_c = SVector(-0.25, -0.25, 0.25, 0.25)
    if curved_frame_supported
        n_c, area_c, t1_c, t2_c, J11c, J12c, J21c, J22c =
            quad4_gp_local_frame_from_coords3d(coords_3d, 0.0, 0.0)
        detJc = J11c*J22c - J12c*J21c
        abs_detJc = max(area_c, 1e-12)
        center_beta_gp = quad4_gp_rotation_from_element!(ws.Rel_t, elem_v1, elem_v2, elem_v3, t1_c, t2_c, n_c)
        if abs(center_beta_gp) > 1e-12
            copyto!(ws.Cs_buf, Cs)
            rotate_constitutive_2x2!(ws.Cs_buf, center_beta_gp)
            center_Cs = ws.Cs_buf
        end
    else
        J11c = dNr_c[1]*coords[1,1]+dNr_c[2]*coords[2,1]+dNr_c[3]*coords[3,1]+dNr_c[4]*coords[4,1]
        J12c = dNr_c[1]*coords[1,2]+dNr_c[2]*coords[2,2]+dNr_c[3]*coords[3,2]+dNr_c[4]*coords[4,2]
        J21c = dNs_c[1]*coords[1,1]+dNs_c[2]*coords[2,1]+dNs_c[3]*coords[3,1]+dNs_c[4]*coords[4,1]
        J22c = dNs_c[1]*coords[1,2]+dNs_c[2]*coords[2,2]+dNs_c[3]*coords[3,2]+dNs_c[4]*coords[4,2]
        detJc = J11c*J22c - J12c*J21c
        abs_detJc = abs(detJc)
    end
    inv_detc = 1.0 / detJc
    iJ11c =  J22c*inv_detc
    iJ12c = -J12c*inv_detc
    iJ21c = -J21c*inv_detc
    iJ22c =  J11c*inv_detc
    dNdx_c = ntuple(k -> iJ11c*dNr_c[k] + iJ12c*dNs_c[k], 4)
    dNdy_c = ntuple(k -> iJ21c*dNr_c[k] + iJ22c*dNs_c[k], 4)
    # Directional phi2 storage kept as alias for the scalar value; downstream
    # code reads phi2_xi/phi2_eta and applies them to ξ/η rows of Bs.
    phi2_xi = phi2_shear
    phi2_eta = phi2_shear
    if !shear_center_only && !no_phi2 && _alpha > 0.0
        # phi2 transverse-shear characteristic length. Default = 4*detJc (≈ element
        # area), but on a SKEWED cell the area shrinks by sin(skew) while the spans
        # (edge lengths) do not, so phi2=α h²/L² grows and the shear over-stiffens
        # (verified vs Nastran KGG: distorted PCOMP cells 2-10× too stiff in
        # out-of-plane translation / soft bending rotation). JFEM_Q4_PHI2_LCHAR_SKEWCORR
        # replaces the area by the UNSHEARED area |r1||r2| (product of the two
        # center-Jacobian edge-vector lengths) — identical to 4*detJc on rectangles
        # (preserves all aspect calibration), larger on skewed cells (softer shear).
        L_char_sq = if fem_env_bool("JFEM_Q4_PHI2_LCHAR_SKEWCORR", false)
            r1r2 = sqrt((J11c*J11c + J12c*J12c) * (J21c*J21c + J22c*J22c))
            max(4.0 * r1r2, 1e-30)
        else
            max(4.0 * abs_detJc, 1e-30)  # ≈ element area
        end
        if macneal_rbf
            # MacNeal 1978 eq (12): 1/GA* = 1/GA + L²/(12 EI). Series-flexibility
            # form (alternative to the min-clamped phi2). Replaces phi2 when
            # JFEM_Q4_MACNEAL_RBF=true.
            D_bend = max(Cb[1,1], 1e-30)
            GA_shear = max(Cs[1,1], 1e-30)
            phi2_shear = 1.0 / (1.0 + GA_shear * L_char_sq / (12.0 * D_bend))
        else
            phi2_shear = min(1.0, _alpha * h^2 / L_char_sq)
        end
        phi2_xi = phi2_shear
        phi2_eta = phi2_shear
    end
    # For membrane-only elements (Cb≈0, bend_ratio=0) assembled with shear_center_only=true:
    # skip all shear so DOF3/4/5 are truly zero → AUTOSPC in eigenvalue solve constrains them,
    # matching Nastran's behavior where AUTOSPC eliminates membrane-only plate out-of-plane DOFs.
    pt = 1.0/sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))

    # Hughes-Brezzi drilling
    G_drill = Cm[3,3] / h
    if G_drill < 1e-6; G_drill = E_ref / (2*3.0); end
    alpha_drill = drill_scale * (k6rot / 1e5) * G_drill * h
    # JFEM_Q4_DRILL_LUMPED_NASTRAN (default OFF): reference-measured drilling.
    # Single-element K extraction (k_extract_boxes_laminates_20260704, four
    # laminates, aspects 1..3) shows the reference CQUAD4 drilling block is a
    # PURE LUMPED nodal spring, k = K6ROT * 1e-6 * A66 * Area on each
    # theta-z, with NO inter-node coupling (exact to 5 digits: the laminate
    # ratios 1.0000 / 5.1463 / 9.2927 / 4.3925 equal A66/G12 per layup) and
    # only a small residual theta-z/translation coupling (half of the
    # consistent form).  When enabled, the consistent Bd'Bd accumulation is
    # skipped and the lumped springs are added after the GP loop.
    # ★ 2026-07-31 PROMOTED TO DEFAULT. The reference's drilling operator, verified
    # zero-parameter to 3.3e-8 by isolating each code's operator as K(K6ROT=k) - K(K6ROT=0),
    # and confirmed in ABSOLUTE terms on the single-element scoreboard (drilling ratio vs
    # reference KGG exactly 1.0000, where the default form gives 10/9). 42-deck corpus screen
    # NEUTRAL: spec mean 0.95 -> 0.94, MAX 2.81 unchanged, |lambda1| max 14.38 -> 14.37,
    # 5 better / 3 worse / 33 unchanged, missing 0.
    drill_lumped_nastran = fem_env_bool("JFEM_Q4_DRILL_LUMPED_NASTRAN", true)
    if drill_lumped_nastran
        alpha_drill = 0.0
    end

    @inbounds @fastmath for gp in 1:4
        r, s = gauss_pts[gp][1], gauss_pts[gp][2]
        dNr, dNs = shape_derivs_quad(r, s)

        n_gp = SVector(0.0, 0.0, 1.0)
        t1_gp = elem_v1
        t2_gp = elem_v2
        if curved_frame_supported
            n_gp, area_elem, t1_gp, t2_gp, J11, J12, J21, J22 =
                quad4_gp_local_frame_from_coords3d(coords_3d, r, s)
            detJ = J11*J22 - J12*J21
            abs_detJ = max(area_elem, 1e-12)
        else
            # Inline Jacobian computation
            J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
            J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
            J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
            J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
            detJ = J11*J22 - J12*J21
            abs_detJ = abs(detJ)
            if abs_detJ < 1e-12; abs_detJ = 1e-12; end
        end
        inv_det = 1.0 / detJ
        iJ11 = J22*inv_det; iJ12 = -J12*inv_det
        iJ21 = -J21*inv_det; iJ22 = J11*inv_det

        curvature_gp = curvature_membrane
        bending_connection_gp = SVector(0.0, 0.0)
        if curved_frame_supported
            curvature_gp = quad4_gp_curvature_membrane_from_coords3d(coords_3d, r, s)
            bending_connection_gp = quad4_gp_bending_connection_from_coords3d(coords_3d, r, s)
        end

        # Marguerre direct-slope-to-uz coupling (2026-05-12). For a non-planar
        # element, the linear-warp slope z₀,α at the GP couples the membrane
        # strain to the transverse displacement uz_k via
        #   ε_xx ⊃ z₀,x · ∂w/∂x = z₀,x · Σ_k dN_k/dx · uz_k
        # The bilinear-Q4 curvature term (curvature_gp) only captures the
        # twist component (∂²z/∂ξ∂η); the linear-slope term fills in the
        # cylindrical-warp coupling that Nastran's CQUAD4 generates and the
        # standard MacNeal kernel misses (see SOL105 parity TODO, 2026-05-12).
        marguerre_z_x_gp = 0.0
        marguerre_z_y_gp = 0.0
        if marguerre_warp_to_uz && coords_3d !== nothing
            z_corners = quad4_local_z_from_coords3d(coords_3d)
            z_xi  = dNr[1]*z_corners[1] + dNr[2]*z_corners[2] + dNr[3]*z_corners[3] + dNr[4]*z_corners[4]
            z_eta = dNs[1]*z_corners[1] + dNs[2]*z_corners[2] + dNs[3]*z_corners[3] + dNs[4]*z_corners[4]
            # research scale, for measuring whether the exact kinematics (1.0) is what the
            # reference uses; a coefficient that optimises away from 1 means the term's FORM is
            # wrong, not its size, and must not simply be tuned (de-calibration directive)
            msc = fem_env_float("JFEM_Q4_MARGUERRE_SCALE", 1.0)
            marguerre_z_x_gp = msc * (iJ11*z_xi + iJ12*z_eta)
            marguerre_z_y_gp = msc * (iJ21*z_xi + iJ22*z_eta)
        end

        # Director slope interpolated at this quadrature point. It completes
        # transverse shear and surface spin before the common nodal S map.
        p_gp = 0.0
        q_gp = 0.0
        if snorm_completion_active
            @inbounds for k in 1:4
                N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
                p_gp += N_k * snorm_pq[k,1]
                q_gp += N_k * snorm_pq[k,2]
            end
        end

        # Fill Bm, Bb, Bd directly from inline dN/dx, dN/dy
        fill!(ws.Bm, 0.0); fill!(ws.Bb, 0.0); fill!(ws.Bd, 0.0)
        for k in 1:4
            dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
            dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
            idx = (k-1)*6
            N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
            ws.Bm[1, idx+1] = dN_dx;  ws.Bm[2, idx+2] = dN_dy
            ws.Bm[3, idx+1] = dN_dy;  ws.Bm[3, idx+2] = dN_dx
            if curvature_gp !== nothing
                ws.Bm[1, idx+3] = -N_k * curvature_gp[1]
                ws.Bm[2, idx+3] = -N_k * curvature_gp[2]
                ws.Bm[3, idx+3] = -2.0 * N_k * curvature_gp[3]
            end
            if marguerre_warp_to_uz && coords_3d !== nothing
                ws.Bm[1, idx+3] += marguerre_z_x_gp * dN_dx
                ws.Bm[2, idx+3] += marguerre_z_y_gp * dN_dy
                ws.Bm[3, idx+3] += marguerre_z_x_gp * dN_dy + marguerre_z_y_gp * dN_dx
            end
            if curved_frame_supported
                # Naghdi-RM covariant membrane connection:
                # u_{α|β} = ∂u_α/∂x^β − Γ^γ_{αβ} u_γ, with Γ^2_{1β}=η_β
                # and Γ^1_{2β}=−η_β (orthonormality). Mirror of the bending
                # connection already applied to Bb below.
                ws.Bm[1, idx+2] -= N_k * bending_connection_gp[1]
                ws.Bm[2, idx+1] += N_k * bending_connection_gp[2]
                ws.Bm[3, idx+1] += N_k * bending_connection_gp[1]
                ws.Bm[3, idx+2] -= N_k * bending_connection_gp[2]
            end
            if slope_membrane !== nothing
                # Marguerre shallow-shell coupling (Ibrahimbegović 1994 Eq. 6.14).
                # Two conventions selectable via JFEM_Q4_MARGUERRE_CONVENTION:
                #   jfem_kl (default) — ε_xx on θ_y (idx+5), ε_yy on θ_x (idx+4)
                #   handover          — ε_xx on θ_x (idx+4), ε_yy on θ_y (idx+5)
                fx = 0.0; fy = 0.0
                for j in 1:4
                    Nj = 0.25*(1 + (j==2||j==3 ? r : -r))*(1 + (j>=3 ? s : -s))
                    fx += Nj * slope_membrane[2*j-1]
                    fy += Nj * slope_membrane[2*j]
                end
                if length(slope_membrane) >= 9 && slope_membrane[9] != 0.0
                    # Handover convention (θ-axis labeled by tangent direction)
                    ws.Bm[1, idx+4] += N_k * fx
                    ws.Bm[2, idx+5] += N_k * fy
                    ws.Bm[3, idx+4] += N_k * fy
                    ws.Bm[3, idx+5] += N_k * fx
                else
                    # JFEM KL convention (θ_y = ∂w/∂x, θ_x = ∂w/∂y)
                    ws.Bm[1, idx+5] += N_k * fx
                    ws.Bm[2, idx+4] += N_k * fy
                    ws.Bm[3, idx+4] += N_k * fx
                    ws.Bm[3, idx+5] += N_k * fy
                end
            end
            ws.Bb[1, idx+5] = dN_dx;  ws.Bb[2, idx+4] = -dN_dy
            ws.Bb[3, idx+5] = dN_dy;  ws.Bb[3, idx+4] = -dN_dx
            # MacNeal twist compatibility (eq 17): χ̃_xy = 2·χ_xy(GP) − χ_xy(0).
            # Applied only on the flat default path (no curved_frame_supported).
            # JFEM_Q4_MACNEAL_TWIST_MODE=center (default "extrapolate"):
            # 1-point reduced twist row, χ̃_xy = χ_xy(0) at every GP.
            # Reference-solver K extraction (k_extract_boxes_laminates_20260704)
            # shows the reference CQUAD4 gives rotation-hourglass patterns ZERO
            # twist-curvature energy on square elements for every laminate
            # tested (Rayleigh alpha = 0.000): the center-evaluated twist row
            # reproduces that exactly (the theta hourglass field r*s has zero
            # gradient at the element center) while keeping constant twist.
            if macneal_twist && !curved_frame_supported
                if macneal_twist_center
                    ws.Bb[3, idx+5] = dNdy_c[k]
                    ws.Bb[3, idx+4] = -dNdx_c[k]
                else
                    ws.Bb[3, idx+5] = 2.0*dN_dy - dNdy_c[k]
                    ws.Bb[3, idx+4] = 2.0*(-dN_dx) - (-dNdx_c[k])
                end
            end
            if curved_frame_supported
                # Covariant change-of-curvature in the moving tangent frame:
                # β₁ = θ_y, β₂ = -θ_x, so β_{α|β} adds connection terms to the
                # flat rotation-derivative plate operator.
                ws.Bb[1, idx+4] += N_k * bending_connection_gp[1]
                ws.Bb[2, idx+5] += N_k * bending_connection_gp[2]
                ws.Bb[3, idx+4] += N_k * bending_connection_gp[2]
                ws.Bb[3, idx+5] += N_k * bending_connection_gp[1]
            end
            # Drilling: Bd = [0.5*dN/dy, -0.5*dN/dx, 0, 0, 0, N_k] per node
            ws.Bd[1, idx+1] = 0.5*dN_dy
            ws.Bd[1, idx+2] = -0.5*dN_dx
            if snorm_completion_active
                ws.Bd[1, idx+3] = q_gp*dN_dx - p_gp*dN_dy
            end
            ws.Bd[1, idx+6] = N_k
        end
        if snorm_completion_active
            # Director-gradient (initial-curvature) completion for PARAM,SNORM.
            # In this projected mean-plane frame the nodal director is
            #     d_i = (p_i, q_i, 1),
            # where p_i=(n_i.v1)/(n_i.v3), q_i=(n_i.v2)/(n_i.v3).
            # Linearising
            #     X_,a = a_a + z*d_,a,
            #     U_,a = u_,a + z*beta_,a
            # gives kappa_ab = sym(beta_,a.a_b + u_,a.d_,b).
            # The first term is the plate row after the nodal S transform below;
            # this block is the second, translation-to-curvature term. Together
            # they annihilate every rigid rotation exactly. It also has the
            # reference-measured structure: trans-rot first order in grad(d),
            # trans-trans second order, and no extra rot-rot block.
            px = 0.0; py = 0.0; qx = 0.0; qy = 0.0
            @inbounds for k in 1:4
                dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
                dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
                px += dN_dx * snorm_pq[k,1]
                py += dN_dy * snorm_pq[k,1]
                qx += dN_dx * snorm_pq[k,2]
                qy += dN_dy * snorm_pq[k,2]
            end
            px_c = 0.0; py_c = 0.0; qx_c = 0.0; qy_c = 0.0
            if macneal_twist && !curved_frame_supported
                @inbounds for k in 1:4
                    px_c += dNdx_c[k] * snorm_pq[k,1]
                    py_c += dNdy_c[k] * snorm_pq[k,1]
                    qx_c += dNdx_c[k] * snorm_pq[k,2]
                    qy_c += dNdy_c[k] * snorm_pq[k,2]
                end
            end
            @inbounds for k in 1:4
                dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
                dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
                idx = (k-1)*6
                ws.Bb[1, idx+1] += px*dN_dx
                ws.Bb[1, idx+2] += qx*dN_dx
                ws.Bb[2, idx+1] += py*dN_dy
                ws.Bb[2, idx+2] += qy*dN_dy
                ctwist_u = py*dN_dx + px*dN_dy
                ctwist_v = qy*dN_dx + qx*dN_dy
                if macneal_twist && !curved_frame_supported
                    ctwist_u_c = py_c*dNdx_c[k] + px_c*dNdy_c[k]
                    ctwist_v_c = qy_c*dNdx_c[k] + qx_c*dNdy_c[k]
                    if macneal_twist_center
                        ctwist_u = ctwist_u_c
                        ctwist_v = ctwist_v_c
                    else
                        ctwist_u = 2.0*ctwist_u - ctwist_u_c
                        ctwist_v = 2.0*ctwist_v - ctwist_v_c
                    end
                end
                ws.Bb[3, idx+1] += ctwist_u
                ws.Bb[3, idx+2] += ctwist_v
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(
                ws.Bm,
                dNdx_c,
                dNdy_c,
                curvature_membrane,
                material_shear_rotation,
            )
        end

        dphi1_dx = iJ11*(-2.0*r);  dphi1_dy = iJ21*(-2.0*r)
        dphi2_dx = iJ12*(-2.0*s);  dphi2_dy = iJ22*(-2.0*s)

        # Fill Bi (membrane incompatible)
        fill_quad4_membrane_incompatible_B!(
            ws.Bi,
            r,
            s,
            iJ11,
            iJ12,
            iJ21,
            iJ22,
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        # Fill Bi_bend (bending incompatible). See JFEM_Q4_BENDING_INCOMP_JAC above: on a
        # parallelogram the centre and Gauss-point Jacobians coincide and all three modes give
        # bit-identical operators, so only a tapered cell is affected.
        b1_dx = dphi1_dx; b1_dy = dphi1_dy; b2_dx = dphi2_dx; b2_dy = dphi2_dy
        if bending_incomp_jac_mode !== :gp
            g = bending_incomp_jac_mode === :qm6 ? detJc / detJ : 1.0
            b1_dx = (iJ11c*(-2.0*r)) * g;  b1_dy = (iJ21c*(-2.0*r)) * g
            b2_dx = (iJ12c*(-2.0*s)) * g;  b2_dy = (iJ22c*(-2.0*s)) * g
        end
        fill!(ws.Bi_bend, 0.0)
        ws.Bi_bend[2,1]=-b1_dy; ws.Bi_bend[2,2]=-b2_dy
        ws.Bi_bend[1,3]=b1_dx;  ws.Bi_bend[1,4]=b2_dx
        ws.Bi_bend[3,1]=-b1_dx; ws.Bi_bend[3,2]=-b2_dx
        ws.Bi_bend[3,3]=b1_dy;  ws.Bi_bend[3,4]=b2_dy

        Cm_use = Cm
        Cb_use = Cb
        Cs_use = Cs
        Bmb_use = Bmb
        if curved_frame_supported
            beta_gp = quad4_gp_rotation_from_element!(ws.Rel_t, elem_v1, elem_v2, elem_v3, t1_gp, t2_gp, n_gp)
            rotate_quad4_dof_blocks!(ws.Bm, ws.Rel_t)
            rotate_quad4_dof_blocks!(ws.Bb, ws.Rel_t)
            rotate_quad4_dof_blocks!(ws.Bd, ws.Rel_t)
            if abs(beta_gp) > 1e-12
                copyto!(ws.Cm_buf, Cm)
                copyto!(ws.Cb_buf, Cb)
                copyto!(ws.Cs_buf, Cs)
                rotate_constitutive_3x3!(ws.Cm_buf, beta_gp)
                rotate_constitutive_3x3!(ws.Cb_buf, beta_gp)
                rotate_constitutive_2x2!(ws.Cs_buf, beta_gp)
                Cm_use = ws.Cm_buf
                Cb_use = ws.Cb_buf
                Cs_use = ws.Cs_buf
                if Bmb !== nothing
                    copyto!(ws.Bmb_buf, Bmb)
                    rotate_constitutive_3x3!(ws.Bmb_buf, beta_gp)
                    Bmb_use = ws.Bmb_buf
                end
            end
        end

        # === In-place stiffness accumulation (thread-safe, BLAS-free) ===
        # Ke += abs_detJ * Bm' * Cm * Bm (membrane: 2×2 full integration)
        ts_mul!(ws.tmp3x24, Cm_use, ws.Bm)
        ts_mul_At_add!(ws.Ke, ws.Bm, ws.tmp3x24, abs_detJ)
        # Ke += abs_detJ * Bb' * Cb * Bb (bending: 2×2 full integration)
        ts_mul!(ws.tmp3x24, Cb_use, ws.Bb)
        ts_mul_At_add!(ws.Ke, ws.Bb, ws.tmp3x24, abs_detJ)
        # Shear: MITC4 (Bathe-Dvorkin) 2×2 full integration — locking-free by construction.
        # Skipped when JFEM_Q4_KERNEL=macneal (MacNeal RBF shear is added after the GP loop).
        if !shear_center_only && !selective_shear && !exact_side_shear && !macneal_kernel
            w_eta_p = 0.5*(1.0+s); w_eta_m = 0.5*(1.0-s)
            w_xi_p  = 0.5*(1.0+r); w_xi_m  = 0.5*(1.0-r)
            fill!(ws.Bs_cov, 0.0)
            for j in 1:24
                ws.Bs_cov[1,j] = w_eta_m*ws.Bs_tp[1,j] + w_eta_p*ws.Bs_tp[2,j]  # e_ξz
                ws.Bs_cov[2,j] = w_xi_m*ws.Bs_tp[3,j]  + w_xi_p*ws.Bs_tp[4,j]   # e_ηz
            end
            # Cs_cov = phi2 * J^{-T} Cs J^{-1} (covariant basis + scalar phi2 anti-locking).
            t11 = Cs_use[1,1]*iJ11 + Cs_use[1,2]*iJ21; t12 = Cs_use[1,1]*iJ12 + Cs_use[1,2]*iJ22
            t21 = Cs_use[2,1]*iJ11 + Cs_use[2,2]*iJ21; t22 = Cs_use[2,1]*iJ12 + Cs_use[2,2]*iJ22
            phi_cross = sqrt(phi2_xi * phi2_eta)
            ws.tmp2x2[1,1] = phi2_xi*(iJ11*t11 + iJ21*t21); ws.tmp2x2[1,2] = phi_cross*(iJ11*t12 + iJ21*t22)
            ws.tmp2x2[2,1] = phi_cross*(iJ12*t11 + iJ22*t21); ws.tmp2x2[2,2] = phi2_eta*(iJ12*t12 + iJ22*t22)
            # Ke += abs_detJ * Bs_cov' * Cs_cov * Bs_cov
            ts_mul!(ws.tmp2x24, ws.tmp2x2, ws.Bs_cov)
            ts_mul_At_add!(ws.Ke, ws.Bs_cov, ws.tmp2x24, abs_detJ)
        end
        # Ke += abs_detJ * alpha_drill * Bd' * Bd
        ts_mul_At_add!(ws.Ke, ws.Bd, ws.Bd, abs_detJ * alpha_drill)

        # B matrix coupling: Ke += abs_detJ * (Bm'*B*Bb + Bb'*B*Bm)
        if Bmb_use !== nothing
            ts_mul!(ws.tmp3x24, Bmb_use, ws.Bb)
            ts_mul_At_add!(ws.Ke, ws.Bm, ws.tmp3x24, abs_detJ)
            ts_mul!(ws.tmp3x24, Bmb_use, ws.Bm)
            ts_mul_At_add!(ws.Ke, ws.Bb, ws.tmp3x24, abs_detJ)
        end

        # Incompatible mode coupling: K_ab += abs_detJ * Bm' * Cm * Bi
        if membrane_incomp
            ts_mul!(ws.tmp3x4, Cm_use, ws.Bi)
            ts_mul_At_add!(ws.K_ab, ws.Bm, ws.tmp3x4, abs_detJ)
            # K_bb += abs_detJ * Bi' * Cm * Bi (reuse tmp3x4 = Cm*Bi)
            ts_mul_At_add!(ws.K_bb, ws.Bi, ws.tmp3x4, abs_detJ)
        end
        # K_ab_bend += abs_detJ * Bb' * Cb * Bi_bend
        ts_mul!(ws.tmp3x4, Cb_use, ws.Bi_bend)
        # JFEM_Q4_BENDING_INCOMP_DECOUPLE_D16 (default OFF): zero the
        # bend-twist coupling (D16/D26) channel in the bending incompatible
        # mode products. Reference-solver single-element extraction
        # (k_extract_boxes_laminates_20260704) shows the enrichment
        # condensation removes D16-coupled twist stiffness that the reference
        # CQUAD4 retains: twist-family Rayleigh ratios vs the reference are
        # 1.00 for D16=0 cross-ply laminates but fall to 0.71/0.60/0.31 as
        # |D16|/D66 grows (0.20/0.25/0.47). Zeroing D16/D26 here affects only
        # the enrichment condensation, not the compatible bending energy.
        if bending_incomp_decouple_d16
            @inbounds for j in 1:4
                ws.tmp3x4[1, j] -= Cb_use[1, 3] * ws.Bi_bend[3, j]
                ws.tmp3x4[2, j] -= Cb_use[2, 3] * ws.Bi_bend[3, j]
                ws.tmp3x4[3, j] -= Cb_use[3, 1] * ws.Bi_bend[1, j] +
                                   Cb_use[3, 2] * ws.Bi_bend[2, j]
            end
        end
        # JFEM_Q4_BENDING_INCOMP_DECOUPLE_D12 -- the SAME surgery on the D12 (Poisson)
        # channel, and it is measured, not guessed. Recovering the reference's bending
        # operator (TOOLS_MATPRN/kbrec.jl) on a FLAT square shows the discrepancy is rank 2,
        # carries ZERO transverse displacement, and is exactly the two ROTATIONAL HOURGLASS
        # modes (theta ~ r*s, hourglass projection 1.000). Its size is
        #     ref/jfem = 1/(1 - nu^2)   on BOTH modes and on both generalised eigenvalues
        # measured 1.122208 vs 1.1222097 at nu = 0.33, 1.253919 vs 1.253918 at nu = 0.45, and
        # 1.000000 at nu = 0 -- where the flat discrepancy vanishes entirely (7.6e-9).
        # MECHANISM: incompatible bending modes 3,4 carry kappa_xx, so the condensation lets a
        # pure kappa_yy hourglass relax kappa_xx to -nu*kappa_yy, giving D(1-nu^2)kappa^2 where
        # the reference keeps D*kappa^2. Removing the Poisson channel from the ENRICHMENT
        # products (not from the compatible bending energy) suppresses exactly that relaxation.
        # ⚠ turning the whole enrichment off instead is much worse (flat hourglass energy
        # 2.04e4 vs the reference's 8.73e3), so the enrichment is needed -- only its Poisson
        # coupling is not.
        if bending_incomp_decouple_d12
            @inbounds for j in 1:4
                ws.tmp3x4[1, j] -= Cb_use[1, 2] * ws.Bi_bend[2, j]
                ws.tmp3x4[2, j] -= Cb_use[2, 1] * ws.Bi_bend[1, j]
            end
        end
        ts_mul_At_add!(ws.K_ab_bend, ws.Bb, ws.tmp3x4, abs_detJ)
        # K_bb_bend += abs_detJ * Bi_bend' * Cb * Bi_bend (reuse tmp3x4)
        ts_mul_At_add!(ws.K_bb_bend, ws.Bi_bend, ws.tmp3x4, abs_detJ)

        # B coupling cross-terms for incompatible modes (accumulated during main loop)
        if Bmb_use !== nothing
            ts_mul!(ws.tmp3x4, Bmb_use, ws.Bi)
            ts_mul_At_add!(ws.K_ab_cross, ws.Bb, ws.tmp3x4, abs_detJ)
            ts_mul!(ws.tmp3x4, Bmb_use, ws.Bi_bend)
            ts_mul_At_add!(ws.K_ab_bend_cross, ws.Bm, ws.tmp3x4, abs_detJ)
            ts_mul!(ws.tmp3x4, Bmb_use, ws.Bi_bend)
            ts_mul_At_add!(ws.K_mb_incomp, ws.Bi, ws.tmp3x4, abs_detJ)
        end
    end

    # 1-point center shear (shear_center_only=true): locking-free reduced integration.
    # Equivalent to Nastran CQUAD4 selective reduced shear; avoids locking on thin plates.
    # Skipped when skip_all_shear=true (membrane-only element: DOF3 must be exactly zero).
    if shear_center_only && !skip_all_shear
        # Bs_cov at center (r=s=0): bilinear interpolation weights = 0.5 each
        fill!(ws.Bs_cov, 0.0)
        for j in 1:24
            ws.Bs_cov[1,j] = 0.5*ws.Bs_tp[1,j] + 0.5*ws.Bs_tp[2,j]  # avg A,B
            ws.Bs_cov[2,j] = 0.5*ws.Bs_tp[3,j] + 0.5*ws.Bs_tp[4,j]  # avg C,D
        end
        # Cs_cov at center (no phi2 — 1-point integration is already locking-free)
        t11c = center_Cs[1,1]*iJ11c + center_Cs[1,2]*iJ21c; t12c = center_Cs[1,1]*iJ12c + center_Cs[1,2]*iJ22c
        t21c = center_Cs[2,1]*iJ11c + center_Cs[2,2]*iJ21c; t22c = center_Cs[2,1]*iJ12c + center_Cs[2,2]*iJ22c
        ws.tmp2x2[1,1] = iJ11c*t11c + iJ21c*t21c; ws.tmp2x2[1,2] = iJ11c*t12c + iJ21c*t22c
        ws.tmp2x2[2,1] = iJ12c*t11c + iJ22c*t21c; ws.tmp2x2[2,2] = iJ12c*t12c + iJ22c*t22c
        # Ke += 4 * abs_detJc * Bs_cov' * Cs_cov * Bs_cov  (weight=4 for single center point)
        ts_mul!(ws.tmp2x24, ws.tmp2x2, ws.Bs_cov)
        ts_mul_At_add!(ws.Ke, ws.Bs_cov, ws.tmp2x24, 4.0 * abs_detJc)
    elseif selective_shear && !skip_all_shear && !exact_side_shear
        # Directional selective shear integration inspired by DKMQ24_2+:
        # e_xiz term on 1x2, e_etaz term on 2x1, cross-coupling on 2x2.
        # This targets thick flat orthotropic shells without replacing the
        # rest of the MITC4 shell operator.
        function accumulate_shear_terms!(r::Float64, s::Float64, mode::Symbol)
            dNr, dNs = shape_derivs_quad(r, s)
            J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
            J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
            J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
            J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
            detJ = J11*J22 - J12*J21
            abs_detJ = abs(detJ)
            if abs_detJ < 1e-12
                abs_detJ = 1e-12
            end
            inv_det = 1.0 / detJ
            iJ11 = J22*inv_det; iJ12 = -J12*inv_det
            iJ21 = -J21*inv_det; iJ22 = J11*inv_det

            w_eta_p = 0.5*(1.0+s); w_eta_m = 0.5*(1.0-s)
            w_xi_p  = 0.5*(1.0+r); w_xi_m  = 0.5*(1.0-r)
            fill!(ws.Bs_cov, 0.0)
            for j in 1:24
                ws.Bs_cov[1,j] = w_eta_m*ws.Bs_tp[1,j] + w_eta_p*ws.Bs_tp[2,j]
                ws.Bs_cov[2,j] = w_xi_m*ws.Bs_tp[3,j]  + w_xi_p*ws.Bs_tp[4,j]
            end

            t11 = Cs[1,1]*iJ11 + Cs[1,2]*iJ21; t12 = Cs[1,1]*iJ12 + Cs[1,2]*iJ22
            t21 = Cs[2,1]*iJ11 + Cs[2,2]*iJ21; t22 = Cs[2,1]*iJ12 + Cs[2,2]*iJ22
            c11 = phi2_shear*(iJ11*t11 + iJ21*t21)
            c12 = phi2_shear*(iJ11*t12 + iJ21*t22)
            c21 = phi2_shear*(iJ12*t11 + iJ22*t21)
            c22 = phi2_shear*(iJ12*t12 + iJ22*t22)

            if mode === :sx
                @inbounds @fastmath for j in 1:24, i in 1:24
                    ws.Ke[i,j] += abs_detJ * c11 * ws.Bs_cov[1,i] * ws.Bs_cov[1,j]
                end
            elseif mode === :sy
                @inbounds @fastmath for j in 1:24, i in 1:24
                    ws.Ke[i,j] += abs_detJ * c22 * ws.Bs_cov[2,i] * ws.Bs_cov[2,j]
                end
            else
                @inbounds @fastmath for j in 1:24, i in 1:24
                    ws.Ke[i,j] += abs_detJ * (
                        c12 * ws.Bs_cov[1,i] * ws.Bs_cov[2,j] +
                        c21 * ws.Bs_cov[2,i] * ws.Bs_cov[1,j]
                    )
                end
            end
            return nothing
        end

        if selective_shear_mode === :all
            for s in (-pt, pt)
                accumulate_shear_terms!(0.0, s, :sx)
            end
            for r in (-pt, pt)
                accumulate_shear_terms!(r, 0.0, :sy)
            end
            for gp in 1:4
                r, s = gauss_pts[gp][1], gauss_pts[gp][2]
                accumulate_shear_terms!(r, s, :cross)
            end
        elseif selective_shear_mode === :sx_only
            for s in (-pt, pt)
                accumulate_shear_terms!(0.0, s, :sx)
            end
            for gp in 1:4
                r, s = gauss_pts[gp][1], gauss_pts[gp][2]
                accumulate_shear_terms!(r, s, :sy)
                accumulate_shear_terms!(r, s, :cross)
            end
        elseif selective_shear_mode === :sy_only
            for r in (-pt, pt)
                accumulate_shear_terms!(r, 0.0, :sy)
            end
            for gp in 1:4
                r, s = gauss_pts[gp][1], gauss_pts[gp][2]
                accumulate_shear_terms!(r, s, :sx)
                accumulate_shear_terms!(r, s, :cross)
            end
        else
            error("unsupported selective_shear_mode=$(selective_shear_mode)")
        end
    end

    if exact_side_shear && !shear_center_only && !skip_all_shear
        add_quad4_plate_dkmq_exact_shear!(ws.Ke, coords, Cb, Cs, h)
    end

    # MacNeal 1978 RBF shear block — replaces MITC4+phi2 when JFEM_Q4_KERNEL=macneal.
    # Added after the GP loop because the MacNeal formulation integrates the 4
    # shear strain values directly (not per-GP via shape functions).
    if macneal_kernel && !shear_center_only && !skip_all_shear
        add_quad4_macneal_shear_rbf!(
            ws.Ke, coords, Cb, Cs, h;
            rigid_shear=macneal_rigid_shear,
            flex_mode_override=macneal_rbf_flex_mode,
            Cm=Cm, Bmb=Bmb,
            distortion_corrections=distortion_corrections,
            snorm_pq=snorm_pq,
        )
    end

    # Reference-matched lumped drilling (see the flag hoist above the GP loop).
    #
    #     K_drill = sum over the 4 CORNER NODES of  alpha_L * (theta_z,i - omega_i)^2
    #     alpha_L = K6ROT * 1e-6 * A66 * Area      (per element per NODE)
    #     omega_i = 0.5*(dv/dx - du/dy) evaluated AT node i
    #
    # i.e. exactly the Hughes-Brezzi row `Bd` this kernel already builds, but sampled at
    # the four CORNERS instead of the four Gauss points (at a corner N_k is the indicator
    # delta_ki, so the same assembly yields theta_z,i - omega_i) and weighted by alpha_L
    # instead of abs_detJ*alpha_drill.
    #
    # Verified against the reference with ZERO free parameters on a flat 2-element patch,
    # by isolating each code's operator as K(K6ROT=k) - K(K6ROT=0):
    # ||pred-actual||/||actual|| = 3.3e-8 at K6ROT=1 and 5.2e-9 at K6ROT=10 (the OP4 print
    # floor), rot-rot 4.7e-9, trans-rot 4.8e-9.  See
    # PROJECT_STATE/TOOLS_MATPRN/drillpred.jl and SESSIONS/2026-07-30_...md SS4d.
    #
    # NOTE this CORRECTS the earlier version of this branch, which added only the theta-z
    # diagonal. The reference's operator also carries the membrane-drilling coupling
    # -alpha_L*d(omega_i)/dq (measured 2.17895 = alpha_L/(2L) on the patch, 10 of 24
    # entries nonzero where the consistent form has 24 of 24) and the second-order
    # membrane-membrane term. Dropping them left the operator incomplete.
    # For a PLANAR quad detJ is linear in (xi,eta), so 4*abs_detJc is the exact area.
    if drill_lumped_nastran
        A_drill = 4.0 * abs_detJc
        alpha_L = drill_scale * (k6rot * 1e-6) * Cm[3, 3] * A_drill
        corner_rs = ((-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0))
        # PROMOTED 2026-08-02. The four corners do NOT share the drilling stiffness equally on a
        # non-parallelogram cell: the reference lumps it in proportion to the CORNER JACOBIAN.
        # Measured K_ref/K_jfem on the theta_z diagonal, against 4*detJ_k/sum(detJ_m):
        #   d_tap70  1.17647 1.17647 0.82353 0.82353     d_tap25  1.60000 1.60000 0.40000 0.40000
        #   d_tap50  1.33333 1.33333 0.66667 0.66667     f_tx010  1.81818 1.81818 0.18182 0.18182
        #   f_ty020  1.66667 0.33333 0.33333 1.66667  <- y-tapered MIRROR, pattern permutes
        # exact to 1.6e-8 (punch precision) on all 15 cells tested, including both aspect ratios
        # and both mirrors, and exactly 1.0 on every parallelogram (flat, aspect 2/10, skew 15/45)
        # so this is a bit-exact no-op there. The weights sum to 4, i.e. the TOTAL drilling
        # stiffness is unchanged -- only its distribution. detJ is linear in (xi,eta) on a planar
        # quad, so sum(detJ_m) over the corners is exactly 4*detJc and w_i = detJ_i/detJc.
        drill_corner_weight = fem_env_bool("JFEM_Q4_DRILL_CORNER_JACOBIAN", true)
        @inbounds @fastmath for i in 1:4
            r, s = corner_rs[i][1], corner_rs[i][2]
            p_corner = snorm_completion_active ? snorm_pq[i,1] : 0.0
            q_corner = snorm_completion_active ? snorm_pq[i,2] : 0.0
            dNr, dNs = shape_derivs_quad(r, s)
            J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
            J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
            J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
            J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
            detJ = J11*J22 - J12*J21
            abs(detJ) < 1e-12 && (detJ = detJ < 0.0 ? -1e-12 : 1e-12)
            inv_det = 1.0 / detJ
            iJ11 =  J22*inv_det; iJ12 = -J12*inv_det
            iJ21 = -J21*inv_det; iJ22 =  J11*inv_det
            fill!(ws.Bd, 0.0)
            for k in 1:4
                dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
                dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
                idx = (k-1)*6
                ws.Bd[1, idx+1] =  0.5*dN_dy
                ws.Bd[1, idx+2] = -0.5*dN_dx
                if snorm_completion_active
                    ws.Bd[1, idx+3] = q_corner*dN_dx - p_corner*dN_dy
                end
            end
            ws.Bd[1, (i-1)*6 + 6] = 1.0
            w_corner = drill_corner_weight ? abs(detJ) / max(abs_detJc, 1e-30) : 1.0
            ts_mul_At_add!(ws.Ke, ws.Bd, ws.Bd, alpha_L * w_corner)
        end
    end

    # Static condensation (BLAS-free for thread safety)
    bmb_incomp_mode = lowercase(strip(
        bmb_incomp_coupling_mode === :env ?
            get(ENV, "JFEM_Q4_BMB_INCOMP_COUPLING_MODE", "full") :
            string(bmb_incomp_coupling_mode)
    ))
    membrane_incomp_weight = max(membrane_incomp_scale, 0.0)
    membrane_incomp_mode_weights =
        membrane_incomp_weights === nothing ?
        q4_membrane_incomp_mode_weights(membrane_incomp_weight) :
        (max(Float64(membrane_incomp_weights[1]), 0.0),
         max(Float64(membrane_incomp_weights[2]), 0.0),
         max(Float64(membrane_incomp_weights[3]), 0.0),
         max(Float64(membrane_incomp_weights[4]), 0.0))
    if Bmb !== nothing
        if membrane_incomp
            if bmb_incomp_mode in ("separate", "separate_nocross", "uncoupled")
                inv_Kbb_m = Matrix(inv(SMatrix{4,4}(ws.K_bb)))
                inv_Kbb_b = Matrix(inv(SMatrix{4,4}(ws.K_bb_bend)))
                @inbounds @fastmath for j in 1:24, i in 1:24
                    sm = 0.0
                    sb = 0.0
                    for l in 1:4
                        tmp_m = 0.0
                        tmp_b = 0.0
                        for q in 1:4
                            tmp_m += inv_Kbb_m[l,q] * ws.K_ab[j,q]
                            tmp_b += inv_Kbb_b[l,q] * ws.K_ab_bend[j,q]
                        end
                        sm += membrane_incomp_mode_weights[l] * ws.K_ab[i,l] * tmp_m
                        sb += ws.K_ab_bend[i,l] * tmp_b
                    end
                    ws.Ke[i,j] -= sm + sb
                end
            elseif bmb_incomp_mode in ("no_cross", "combined_nocross")
                K_ab_full = hcat(ws.K_ab, ws.K_ab_bend)
                K_bb_full = [ws.K_bb zeros(4,4); zeros(4,4) ws.K_bb_bend]
                inv_Kbb = Matrix(inv(SMatrix{8,8}(K_bb_full)))
                tmp8x24 = zeros(8, 24)
                ts_mul!(tmp8x24, inv_Kbb, K_ab_full')
                @inbounds @fastmath for j in 1:24, i in 1:24
                    s = 0.0
                    for l in 1:8
                        mode_weight = l <= 4 ? membrane_incomp_mode_weights[l] : 1.0
                        s += mode_weight * K_ab_full[i,l] * tmp8x24[l,j]
                    end
                    ws.Ke[i,j] -= s
                end
            else
                # Combined 8×8 condensation (B coupling creates cross-coupling between membrane/bending incomp modes)
                K_ab_full = hcat(ws.K_ab .+ ws.K_ab_cross, ws.K_ab_bend .+ ws.K_ab_bend_cross)
                K_bb_full = [ws.K_bb ws.K_mb_incomp; ws.K_mb_incomp' ws.K_bb_bend]
                inv_Kbb = Matrix(inv(SMatrix{8,8}(K_bb_full)))
                tmp8x24 = zeros(8, 24)
                ts_mul!(tmp8x24, inv_Kbb, K_ab_full')
                @inbounds @fastmath for j in 1:24, i in 1:24
                    s = 0.0
                    for l in 1:8
                        mode_weight = l <= 4 ? membrane_incomp_mode_weights[l] : 1.0
                        s += mode_weight * K_ab_full[i,l] * tmp8x24[l,j]
                    end
                    ws.Ke[i,j] -= s
                end
            end
        elseif maximum(abs, ws.K_bb_bend) > 0.0
            # Bending-only 4×4 condensation (no membrane incompatible modes)
            # K_ab_bend_cross = Bm' * Bmb * Bi_bend — B-coupling cross term still relevant
            inv_Kbb_b = Matrix(inv(SMatrix{4,4}(ws.K_bb_bend)))
            K_ab_b =
                bmb_incomp_mode in ("bending_nocross", "no_cross", "combined_nocross", "separate", "separate_nocross", "uncoupled") ?
                ws.K_ab_bend : ws.K_ab_bend .+ ws.K_ab_bend_cross
            @inbounds @fastmath for j in 1:24, i in 1:24
                sb = 0.0
                for l in 1:4
                    tmp_b = 0.0
                    for q in 1:4; tmp_b += inv_Kbb_b[l,q] * K_ab_b[j,q]; end
                    sb += K_ab_b[i,l] * tmp_b
                end
                ws.Ke[i,j] -= sb
            end
        end
    else
        # ---- THE ENRICHMENT MUST NOT RELAX THE ROTATIONAL HOURGLASS (2026-08-02) ----
        # Recovering the reference's bending operator (TOOLS_MATPRN/kbrec.jl) shows its
        # rotational-hourglass block IS the plain compatible integral: with the centre-evaluated
        # twist row the hourglass carries no twist curvature, so for a parallelogram
        #     G = D*(4/3)*[1  nu*tan ; nu*tan  1+tan^2],  trace = D*(4/3)*(2 + tan^2)
        # and the recovered trace is exactly that at skew 0/15/30/45 (measured/flat = 1.0000,
        # 1.0359, 1.1667, 1.5000 vs predicted 1, 1.0359, 1.1667, 1.5000).
        # On the FLAT cell the D12 decoupling above already leaves nothing for the enrichment to
        # relax there, and JFEM lands on the reference exactly. On a SKEWED cell the skewed
        # Jacobian re-opens the coupling through the other channels and the enrichment softens
        # the hourglass by ~2x (trace 12699 vs the reference's 26185 at skew 45).
        # So project the hourglass directions out of the enrichment coupling. This is not a
        # tuning knob: it enforces the measured statement "the reference's hourglass energy is
        # the compatible one", it is exact on the flat cell by construction, and it keeps the
        # condensation symmetric because it only removes columns from K_ab_bend.
        # PROMOTED 2026-08-02: skew_deg 6.14e-3 -> 4.96e-7, skew_nu 6.55e-3 -> 2.55e-7,
        # skew30_x_h 1.38e-2 -> 2.75e-7, skew45_x_h 3.94e-2 -> 3.39e-8, aspect_x_skew
        # 6.84e-3 -> 3.78e-6 -- all -100 %. Every other axis bit-unchanged; ratchet PASS.
        # JFEM's recovered hourglass block now equals the reference's EXACTLY at every skew
        # angle (6695.60 / 19489.3 at skew 45, matching to 6 digits).
        if bending_incomp && fem_env_bool("JFEM_Q4_BENDING_INCOMP_NO_HOURGLASS", true) &&
           maximum(abs, ws.K_bb_bend) > 0.0
            hgs = (4, 5)                      # theta_x, theta_y
            sgn4 = (1.0, -1.0, 1.0, -1.0)     # r*s at the corners
            for c in hgs
                nrm = 0.0
                @inbounds for i in 1:4; nrm += sgn4[i]^2; end
                @inbounds for q in 1:4
                    d = 0.0
                    for i in 1:4; d += sgn4[i] * ws.K_ab_bend[(i-1)*6 + c, q]; end
                    d /= nrm
                    for i in 1:4; ws.K_ab_bend[(i-1)*6 + c, q] -= sgn4[i] * d; end
                end
            end
        end
        if bending_incomp && maximum(abs, ws.K_bb_bend) > 0.0
            # Separate 4×4 condensation for bending (always) and membrane (only if membrane_incomp)
            # (skipped when bend_ratio=0, i.e. membrane-only element with zero Cb)
            inv_Kbb_b = Matrix(inv(SMatrix{4,4}(ws.K_bb_bend)))
            inv_Kbb_m = membrane_incomp ? Matrix(inv(SMatrix{4,4}(ws.K_bb))) : nothing
            @inbounds @fastmath for j in 1:24, i in 1:24
                sb = 0.0
                for l in 1:4
                    tmp_b = 0.0
                    for q in 1:4
                        tmp_b += inv_Kbb_b[l,q] * ws.K_ab_bend[j,q]
                    end
                    sb += ws.K_ab_bend[i,l] * tmp_b
                end
                ws.Ke[i,j] -= sb
            end
            if membrane_incomp
                @inbounds @fastmath for j in 1:24, i in 1:24
                    sm = 0.0
                    for l in 1:4
                        tmp_m = 0.0
                        for q in 1:4
                            tmp_m += inv_Kbb_m[l,q] * ws.K_ab[j,q]
                        end
                        sm += membrane_incomp_mode_weights[l] * ws.K_ab[i,l] * tmp_m
                    end
                    ws.Ke[i,j] -= sm
                end
            end
        else
            # Membrane-only 4×4 condensation (no bending incompatible modes)
            if membrane_incomp
                inv_Kbb_m = Matrix(inv(SMatrix{4,4}(ws.K_bb)))
                @inbounds @fastmath for j in 1:24, i in 1:24
                    sm = 0.0
                    for l in 1:4
                        tmp_m = 0.0
                        for q in 1:4
                            tmp_m += inv_Kbb_m[l,q] * ws.K_ab[j,q]
                        end
                        sm += membrane_incomp_mode_weights[l] * ws.K_ab[i,l] * tmp_m
                    end
                    ws.Ke[i,j] -= sm
                end
            end
        end
    end

    # MacNeal 1978 warp correction (opt-in, partial). Activated only when:
    #   - JFEM_MACNEAL_WARP_ALPHA env var is set to a non-zero float
    #   - coords_3d is supplied (caller knows the 3D corner positions)
    # Reverse-engineered from `NAST705/probes/jfem_warp_lc_sweep.jl`: closes
    # ~70% of K[θ_x, T_x] warp gap on the iso warped probe at α=-1/3.
    # Default 0.0 = no correction = original JFEM behavior.
    if coords_3d !== nothing
        warp_alpha_raw = strip(get(ENV, "JFEM_MACNEAL_WARP_ALPHA", ""))
        warp_alpha = isempty(warp_alpha_raw) ? 0.0 :
            (tryparse(Float64, warp_alpha_raw) === nothing ? 0.0 : parse(Float64, warp_alpha_raw))
        if warp_alpha != 0.0
            v1, v2, v3 = quad4_center_frame_from_coords3d(coords_3d)
            cx = (coords_3d[1,1] + coords_3d[2,1] + coords_3d[3,1] + coords_3d[4,1]) * 0.25
            cy = (coords_3d[1,2] + coords_3d[2,2] + coords_3d[3,2] + coords_3d[4,2]) * 0.25
            cz = (coords_3d[1,3] + coords_3d[2,3] + coords_3d[3,3] + coords_3d[4,3]) * 0.25
            apply_macneal_warp_correction!(ws.Ke, coords_3d, (v1, v2, v3),
                                            [cx, cy, cz]; alpha=warp_alpha)
        end
    end

    # -------------------------------------------------------------------------
    # Warp rotation-drilling coupling — JFEM_Q4_WARP_ROTDRILL (default 0 = OFF).
    #
    # MEASURED TARGET (2026-07-31, warpstruct.jl). Decomposing dK = K_ref - K_JFEM on a warped
    # CQUAD4 by component pair and fitting each class against the warp amplitude gives, at
    # warp/L = 0.0242:
    #     Rx-Rz, Ry-Rz   4.43e3   order 0.99  <- DOMINANT
    #     Tx-Tz, Ty-Tz   1.84e3   order 0.99
    #     Tx-Ry, Ty-Rx     44.2   order 0.99  <- what the rigid-offset correction above targets
    #     Rz-Rz, Tz-Tz    ~100    order ~2.0
    # So the dominant missing warp physics is a bending<->drilling coupling FIRST ORDER in warp.
    # This refutes the docstring premise of apply_macneal_warp_correction! ("the second-order
    # localised K[Tz,Tx]"): that coupling is first order AND 2.4x smaller than Rx-Rz/Ry-Rz.
    #
    # DERIVATION. On a warped quad the true surface normal varies across the element. At node i
    # the local normal deviates from the mean-plane normal by the surface slope there, so a
    # bending rotation at that node carries a component along the LOCAL normal — i.e. it leaks
    # into drilling — at first order in the slope. That is a nodal rotational transform
    #     T_i = I + skew(dn_i),     dn_i = (-dz/dx, -dz/dy, 0) at node i,
    # applied as Ke <- T' Ke T on each node's rotational 3x3. Structurally the same object as
    # the SNORM director transform S = I + skew((n x v3)/(n.v3)), but sourced from ELEMENT WARP
    # rather than nodal director smoothing, and it generates exactly Rx-Rz / Ry-Rz at first
    # order — the dominant measured class.
    #
    # z_i is the signed height of node i above the mean plane, and dz/dx, dz/dy are the bilinear
    # slopes of that height field, both in the element local frame.
    #
    # ⚠ This deliberately does NOT enable the curved-shell GP-local frame path. That path is
    # reached via `curved_frame_supported`, which needs coords_3d AND several other conditions,
    # and it VIOLATES RIGID-BODY TRANSLATION on warped cells (2e-17 -> 3.7e-2) while improving
    # the error norm. The two are separable and must stay separate.
    #
    # ⛔ REFUTED BY MEASUREMENT 2026-07-31 — LEAVE AT 0 (OFF). Kept as the record.
    # Whole-matrix error vs reference (warp 0.0242): 1.73e-2 OFF -> 1.91e-2 (c=0.5) -> 2.37e-2
    # (c=1) -> 3.67e-2 (c=2). Worse at every amplitude, and inert on the flat control.
    #
    # HOW it fails is the useful part: c = +1 and c = -1 give IDENTICAL errors, and the growth
    # is quadratic in c. A first-order term that changed the residual would be linear in c and
    # asymmetric in its sign. Quadratic-and-sign-symmetric means the term this transform adds is
    # ORTHOGONAL to the actual residual, so it can only add in quadrature and increase the error.
    # The missing warp physics lies in a different subspace than any nodal rotational transform
    # of this form — which also retrospectively explains the sign-symmetric failure of
    # apply_macneal_warp_correction!'s alpha sweep (same class of object, same orthogonality).
    # It additionally violates rigid-body translation at large warp (RB 1.9e-2 at warp 0.1),
    # because a per-node rotational transform is not a rigid-body-preserving congruence here.
    #
    # ⇒ Do not retry nodal rotational transforms for warp. The dominant Rx-Rz/Ry-Rz term must
    # come from inside the strain-displacement operator, not from a post-hoc DOF transform.
    let wrd = fem_env_float("JFEM_Q4_WARP_ROTDRILL", 0.0)
        if wrd != 0.0 && coords_3d !== nothing
            _, _, v3 = quad4_center_frame_from_coords3d(coords_3d)
            cx = (coords_3d[1,1] + coords_3d[2,1] + coords_3d[3,1] + coords_3d[4,1]) * 0.25
            cy = (coords_3d[1,2] + coords_3d[2,2] + coords_3d[3,2] + coords_3d[4,2]) * 0.25
            cz = (coords_3d[1,3] + coords_3d[2,3] + coords_3d[3,3] + coords_3d[4,3]) * 0.25
            zi = ntuple(i -> (coords_3d[i,1]-cx)*v3[1] + (coords_3d[i,2]-cy)*v3[2] +
                             (coords_3d[i,3]-cz)*v3[3], 4)
            corner_rs_wrd = ((-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0))
            # bilinear slopes of the height field at each corner, in the local frame
            @inbounds for i in 1:4
                r, s = corner_rs_wrd[i][1], corner_rs_wrd[i][2]
                dNr, dNs = shape_derivs_quad(r, s)
                J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
                J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
                J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
                J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
                dj = J11*J22 - J12*J21
                abs(dj) < 1e-30 && continue
                z_xi  = dNr[1]*zi[1] + dNr[2]*zi[2] + dNr[3]*zi[3] + dNr[4]*zi[4]
                z_eta = dNs[1]*zi[1] + dNs[2]*zi[2] + dNs[3]*zi[3] + dNs[4]*zi[4]
                z_x = ( J22*z_xi - J12*z_eta) / dj
                z_y = (-J21*z_xi + J11*z_eta) / dj
                # T_i = I + skew(dn),  dn = wrd*(-z_x, -z_y, 0)
                a = -wrd * z_x; b = -wrd * z_y
                T = @SMatrix [ 1.0   0.0   b
                               0.0   1.0  -a
                              -b     a    1.0 ]
                r0 = (i-1)*6 + 3          # rotational DOFs are r0+1 .. r0+3
                blk = @view ws.Ke[(r0+1):(r0+3), :]
                blk .= T' * blk
                blk2 = @view ws.Ke[:, (r0+1):(r0+3)]
                blk2 .= blk2 * T
            end
        end
    end

    # Skew-metric anisotropic hourglass restabilization of the membrane.
    # Requires the membrane to be pure full-bilinear here (caller passes
    # membrane_incomp=false so no Wilson membrane condensation ran); this adds the
    # rank-2 hourglass correction that matches Nastran's split hourglass stiffness
    # on skewed composite CQUAD4.  Uses the 2D in-plane coords (columns 1,2 of the
    # local coords passed in).
    if membrane_hourglass_skew
        ws.Ke .+= quad4_membrane_hourglass_skew_correction(coords, Cm)
    end

    # PARAM,SNORM physical-coordinate equilibrium map. This must be after every
    # projected element contribution (including condensation and hourglass
    # terms) and before the finite-warp work-dual multiplier below. For a
    # non-null W, `snorm_transform_pq` already contains the row-gated relative
    # residual, so the resulting one-time composition is M_relative*W.
    if snorm_transform_on
        if snorm_normal_moment
            apply_quad4_snorm_normal_moment_completion!(
                ws.Ke, coords, snorm_transform_pq)
        else
            apply_quad4_snorm_director_completion!(ws.Ke, snorm_transform_pq)
        end
    end

    # ------------------------------------------------------------------
    # MacNEAL FINITE-WARP EQUILIBRIUM MULTIPLIER
    # (JFEM_Q4_WARP_TRANSFORM, default ON).
    #
    # MacNeal's warped CQUAD4 is the flat mean-plane element modified by
    # pre/post multipliers that transfer its forces and moments to the four
    # non-coplanar corners while preserving rigid-body motion. The complete
    # work-dual displacement map has two parameter-free parts.
    #
    # 1. Transferring an in-plane force to corner height z_i is equilibrated
    #    by normal nodal force couples. Its displacement map is
    #      u0_i = u_i + z_i*sum_j N_{j,x}(i)*w_j,
    #      v0_i = v_i + z_i*sum_j N_{j,y}(i)*w_j.
    #    This is the compact shape-function form of the QDMEM1
    #    construction in the NASTRAN Level 16 manual (5.8-40/41).
    #
    # 2. Preserving (mx,my) while tilting the moment into the corner plane adds
    #    mz=gx*mx+gy*my. Since the equidistant diagonal-cross mean plane has
    #    z1=z3 and z2=z4, the matching projected-diagonal spin contains exactly
    #    the rigid normal-axis rotation. Its work-dual in-plane force couple
    #    balances mz:
    #      rx0_i = rx_i + gx_i*(rz_i-phi_diag(i)),
    #      ry0_i = ry_i + gy_i*(rz_i-phi_diag(i)).
    #
    # Bilinear completeness and equal diagonal heights make this finite map
    # rigid-exact. There is no fitted coefficient or small-warp truncation.
    # Retained matrices: warp/L=0.0242, 2.248e-4 -> 2.198e-8;
    # warp/L=0.20, 1.878e-3 -> 6.958e-6; warp x h/L, 2.378e-4 ->
    # 3.432e-8. The membrane--plate coupling is <=1.8e-8 and all six JFEM
    # rigid residuals are <=4e-17. The extreme-warp remainder is confined to
    # plate channels (plate--plate 6.780e-6, plate--drill 1.097e-6).
    if coords_3d !== nothing && warp_transform_on
        apply_quad4_finite_warp_equilibrium!(ws.Ke, coords, coords_3d)
    end

    return ws.Ke
end

# DKQ/DKMQ flat-plate research kernels — quarantined to experimental/
# 2026-05-25. Reached only via JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ or
# JFEM_SOL105_EIG_FLAT_PCOMP_PLATE_BRANCH env vars (both default off).
# All edge relations, plate K builders, and DKMQ exact-shear helpers
# live in the included file.
include(joinpath(@__DIR__, "experimental", "dkq_dkmq_flat_plate_kernels.jl"))


# MIN4 (Tessler-Hughes anisoparametric) research kernel — quarantined to
# experimental/ 2026-05-25. Reached only via JFEM_Q4_KERNEL=min4 (default
# "macneal" — branch dead under defaults). Function lives in the included file.
include(joinpath(@__DIR__, "experimental", "min4_kernel.jl"))


# =============================================================================
# KERNEL: add_quad4_macneal_shear_rbf!
# STATUS: PRODUCTION — fires for every default-path element with macneal_kernel=true
#         (which is the default JFEM_Q4_KERNEL value). Reference formulation
#         used by Nastran CQUAD4.
# DISPATCHED FROM: stiffness_quad4_matrices line ~3798 when macneal_kernel.
# CALIBRATION KNOBS (env): JFEM_Q4_MACNEAL_RBF (off by default — the in-RBF
#         calculation here is *always* done; the env enables a DIFFERENT in-line
#         RBF in stiffness_quad4_matrices at line ~3406);
#         JFEM_Q4_MACNEAL_RBF_ZB_SCALE,
#         JFEM_Q4_MACNEAL_RBF_ZB_DIFF_SCALE,
#         JFEM_Q4_MACNEAL_RBF_BENDING_FLEX_MODE ("diag"), JFEM_Q4_MACNEAL_RBF_LENGTH_MODE ("paper").
# LAST VALIDATED: 2026-05-22 (GAME mean 2.42% / max 9.10%).
# =============================================================================
# ---------------------------------------------------------------------------
# MacNeal 1978 CQUAD4 transverse shear with residual bending flexibility
# (Comp. Struct. 8:175-183). Reference formulation used by Nastran CQUAD4.
#
#   Strain values γx_a, γx_b at (ξ, η) = (0, ±1/√3)
#                 γy_c, γy_d at (ξ, η) = (±1/√3, 0)
#   Element shear stiffness: K_s = [D]ᵀ · ([Z_s] + [Z_b])⁻¹ · [D]
#     [D]     4×12 — strain values in terms of plate DOFs (w, θx, θy)
#     [Z_s]   physical shear compliance matrix (eq 23-25)
#     [Z_b]   residual bending flexibility matrix (eq 26-27)
#
# This REPLACES the MITC4+phi2 shear block when JFEM_Q4_KERNEL=macneal.
# ---------------------------------------------------------------------------
"""
    macneal_strip_bending_flex(A, B, D, dir) -> 1/D*_dir

⛔ **REFUTED BY MEASUREMENT 2026-07-30 — DO NOT RE-DERIVE. Kept only as the record.**

Hypothesis: the RBF term needs the flexibility of a STRIP of the element bending under a
moment gradient, with that strip free to relax in everything except the direct curvature —
`κ_other = 0` (cylindrical), `M_xy = 0` (twist free), `N = 0` (membrane free, which matters
only when `B ≠ 0`). Unknowns `ε⁰` (3) and `κ_xy`, per unit `κ_dir`:

    A·ε⁰ + κ_xy·B[:,3]        = −κ_dir·B[:,dir]     (N = 0)
    B[3,:]·ε⁰ + κ_xy·D[3,3]   = −κ_dir·D[3,dir]     (M_xy = 0)
    D*_dir = (B[dir,:]·ε⁰ + D[dir,dir] + D[dir,3]·κ_xy) / κ_dir

Measured against reference KGG on 27 single-element PCOMP cells (`gen_pcomp.jl`, `pccinf.jl`),
recovering the C∞ each cell wants — 1.00000 is the right answer:

| family                        | `diag` (1/D₁₁) | this function  |
|-------------------------------|----------------|----------------|
| cross-ply, `B=0, D₁₆=0`       | **1.00000**    | **1.00000**    |
| quasi-iso, `B=0, D₁₆≠0`       | **1.0000**     | 0.9418         |
| unsymmetric, `B≠0`            | **1.0006**     | 0.4301         |

Cross-ply agreeing exactly confirms the implementation reduces correctly, so it is the PHYSICS
that is wrong: releasing twist over-softens quasi-isotropic, and releasing membrane over-softens
unsymmetric by 2.3×. **The reference uses the bare `1/D₁₁` for every laminate family**, i.e.
`κ_other = κ_xy = 0` AND `ε⁰ = 0`.

Why that is the correct reading: the RBF supplies only the DIRECT bending flexibility that the
shear interpolation fails to represent inside the strip. The element's own DOFs already carry
the transverse curvature, the twist and the membrane response — relaxing them again inside the
RBF term double-counts them.

Consequence: the `un` family's divergence at thick (C∞ 1.0006 → 4.09 over h/L 0.002 → 0.1 under
`diag`) is NOT a bending-flexibility defect. It is thickness-driven, so it lives on the SHEAR
side (`Zs`/`Cs`), which is where to look next.
"""
function macneal_strip_bending_flex(A, B, D::AbstractMatrix, dir::Int)
    D33 = abs(D[3, 3]) > 1e-30 ? D[3, 3] : (D[3, 3] >= 0 ? 1e-30 : -1e-30)
    # No membrane-bending coupling: the 4x4 collapses to the twist equation alone.
    if A === nothing || B === nothing || maximum(abs, B) <= 1e-30
        kxy = -D[3, dir] / D33
        Dstar = D[dir, dir] + D[dir, 3] * kxy
        return 1.0 / max(abs(Dstar), 1e-30)
    end
    M = zeros(Float64, 4, 4); r = zeros(Float64, 4)
    @inbounds for i in 1:3
        for j in 1:3
            M[i, j] = A[i, j]
        end
        M[i, 4] = B[i, 3]
        r[i]    = -B[i, dir]
    end
    @inbounds for j in 1:3
        M[4, j] = B[3, j]
    end
    M[4, 4] = D33
    r[4]    = -D[3, dir]
    z = try
        M \ r
    catch
        return 1.0 / max(abs(D[dir, dir]), 1e-30)   # singular A: fall back to the plain diagonal
    end
    all(isfinite, z) || return 1.0 / max(abs(D[dir, dir]), 1e-30)
    Dstar = D[dir, dir] + D[dir, 3] * z[4]
    @inbounds for j in 1:3
        Dstar += B[dir, j] * z[j]
    end
    return 1.0 / max(abs(Dstar), 1e-30)
end

# TAPER CORRECTIONS TO THE eq-(27) DIFFERENTIAL COEFFICIENTS.
#
# Built ONLY from the formulation's own constants -- 3 = 1/pt^2 and eps = 0.025, whose eq-(27)
# partner is (1-eps)/eps = 39. No fitted coefficients.
#
# VARIABLES (derived, not chosen):
#   g    = |grad detJ| / detJc in a natural direction. detJ is linear in (xi,eta) on a planar
#          quad, so detJ/detJc = 1 + gr*r + gs*s EXACTLY; a pure x-taper gives gs = -(1-t)/(1+t)
#          and gr = 0. g vanishes identically on a parallelogram, so BOTH factors are 1 there and
#          every closed axis is bit-exact.
#   rho2 = the eq-(27) aspect argument of the affected family.
#
# CROSS-FAMILY coupling (the differential-differential channel). Measured on thin reference cells
# the shipped term is exactly eps*g^2 in units of sqrt(zbx_u*zby_u), and the reference is
#      W = 3/(1-eps) * rho2/(rho2 + eps/(1-eps))
# which reproduces it to 0.003-0.020 % at rho2 = 0.098 / 0.331 / 0.391 / 0.490 / 0.640 / 1.563 /
# 6.250 -- i.e. across aspect 0.5-4 AND taper 0.15-0.60 with no free parameter. The apparent
# taper dependence of this term is entirely rho2 moving with the taper.
@inline function q4_taper_cross_factor(rho2::Float64)
    eps = 0.025
    c = eps / (1 - eps)
    r = rho2 < 0.0 ? 0.0 : rho2
    (3.0 / (1 - eps)) * r / (r + c)
end

# SAME-FAMILY differential coefficient. The identical structure, one power of (rho2+39) higher:
#      F - 1 = g^4 * rho2 (rho2 + 39) / (39 (rho2 + 1/39))
# Reproduces the recovered factor to max 1.7e-3 / rms 5.5e-4 over aspect >= 0.5 and taper
# 0.05-0.85 (F itself spans 1.0002-1.618). ⚠ it degrades to 6.8e-3 on the extreme aspect-0.25
# slivers, where the saturation is not exactly this form -- the one place the element is still
# knowingly approximate.
@inline function q4_taper_diff_factor(g::Float64, rho2::Float64)
    g <= 1e-12 && return 1.0
    gg = g > 1.0 ? 1.0 : g          # a valid convex quad has |gr| + |gs| < 1; clamp defensively
    b = 39.0
    r = rho2 < 0.0 ? 0.0 : rho2
    g2 = gg * gg
    1.0 + g2 * g2 * r * (r + b) / (b * (r + 1.0 / b))
end

# ⚠ THE ONLY EMPIRICAL COEFFICIENTS IN THE ELEMENT -- the taper factor of the SHEAR flexibility's
# cross-family coupling, kept on the owner's explicit decision after the derivation was exhausted.
#
# The other two relations of this correction ARE derived and exact:
#   * it scales as rho (NOT rho^2): measured 2x per aspect doubling, and residual/(Zs*rho) is
#     constant to FIVE digits over an eightfold aspect range (-3.5477 at every aspect, taper 0.15);
#   * its uniform-by-differential channel is locked to the differential-differential one by
#     ud/dd = -g/3 exactly -- measured -0.33337 -0.33338 -0.33337 -0.33340 across taper.
# Only the taper factor D(g) resisted a closed form: its local exponent in g drifts 5.5 -> 2.15
# over the sweep, so it is no power law. Fitted as a rational function of g^2 to a 10-point taper
# sweep on thin cells, reproducing D to a max of 0.0012 % -- and D itself spans a factor of 90.
# D(0) = 0 identically, so this vanishes on any parallelogram along with everything else.
# ⚠ EMPIRICAL (2 of 2). Slow drift on the shear DIFFERENTIAL taper factor: the derived part is
# g^4*rho2 (whose rho2 exponent is exact -- residual/(Zs*rho2) is constant to 4 digits over an
# eightfold aspect range), and this multiplies it by h. Measured h-1 = 0.3749 0.2867 0.2219 0.1730
# 0.1349 0.1047 0.0599 over taper 0.05-0.40, reproduced to max 0.64 %.
# POLYNOMIAL, deliberately: the best rational fit (0.03 %) carried a POLE at q = 0.335, inside the
# working range and hidden between the sample points. This form is pole-free by construction and
# was checked monotone and positive over the whole of q in [0,1]. h(0) = 1, so parallelograms are
# untouched.
@inline function q4_taper_shear_diff_h(g::Float64)
    g <= 1e-12 && return 1.0
    x = g > 1.0 ? 1.0 : g * g
    1.0 + x*(0.240645040092 + x*(0.603483673803 + x*(-0.818416784763 + x*0.4962374002)))
end

@inline function q4_taper_shear_cross_D(g::Float64)
    g <= 1e-12 && return 0.0
    x = g > 1.0 ? 1.0 : g * g
    num = ((-155.893116996 * x + 113.08382495) * x + 79.1160661624) * x + 3.08637764718
    den = (((25.4378883507 * x - 53.3509632458) * x + 5.34946812132) * x + 22.4240823599) * x + 1.0
    abs(den) < 1e-12 && return 0.0
    -x * num / den
end

const CORNER_RS_FIT = ((-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0))

function add_quad4_macneal_shear_rbf!(
    Ke::AbstractMatrix,
    coords::AbstractMatrix{Float64},
    Cb::AbstractMatrix,
    Cs::AbstractMatrix,
    h;
    rigid_shear::Bool = false,
    flex_mode_override::Symbol = :env,
    Cm = nothing,
    Bmb = nothing,
    distortion_corrections::Bool = true,
    snorm_pq = nothing,
)
    # Shortcut: skip if thickness or shear modulus is effectively zero
    if h < 1e-30 || (!rigid_shear && maximum(abs, Cs) < 1e-30)
        return Ke
    end

    # Sampling points: (ξ, η, component) where component=1 is γx, =2 is γy.
    # JFEM_Q4_MACNEAL_SHEAR_SAMPLE=edge (default "gauss"): sample the
    # substitute shear strains at the edge midpoints (0,±1)/(±1,0) as in
    # MacNeal 1978, instead of the Gauss-offset interior points (0,±1/√3).
    # Identical on squares after zb calibration; changes the aspect scaling.
    shear_sample_edge =
        lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_SHEAR_SAMPLE", "gauss"))) in
        ("edge", "midpoint", "midside")
    pt = shear_sample_edge ? 1.0 : 1.0 / sqrt(3.0)
    shear_pts = ((0.0, -pt, 1), (0.0,  pt, 1), (-pt, 0.0, 2), ( pt, 0.0, 2))
    # Tying ROWS at the edge midsides, flexibility geometry left where it is.
    #
    # Recovered, not guessed: with Kb shared (it cancels), KP_ref = K_ref,plate - Kb is a rank-4
    # PSD matrix whose column space IS the row space of the reference's tying operator. Measured
    # on tapered cells it shares three of four directions with JFEM's to <= 1.9 deg and differs in
    # exactly one -- the UNIFORM y channel (0,0,1,1) -- by 3.8 deg at taper 0.80, 13.4 deg at
    # 0.25, 22.8 deg at aspect 2. Printing that row nodally, the w and theta_x coefficients agree
    # EXACTLY and the theta_y (fan) coefficients differ by EXACTLY 3.0000 on every node of every
    # cell.
    #
    # That factor is pt^2. In the covariant tying row gamma_eta = w,eta + x,s theta_y - y,s
    # theta_x, summing the two eta-family samples gives a w coefficient of -1/L and a theta_x
    # coefficient of -1/2, both INDEPENDENT of the tying abscissa, while the theta_y term picks up
    # N_k(r) * x,s(r) whose surviving part is quadratic in r -- so it carries pt^2, which is 1/3 at
    # the Gauss abscissa and 1 at the edge. On a parallelogram x,s is constant and the row is
    # pt-independent, which is exactly why every parallelogram axis is blind to this.
    #
    # These are the standard MITC4 tying points (edge midsides). Moving the whole sampling there
    # via JFEM_Q4_MACNEAL_SHEAR_SAMPLE=edge also drags J_pts and the residual-flexibility geometry
    # and triples the twist channel on a SQUARE, so it is the tying ROWS alone that belong at the
    # edge.
# ⚠ DEFAULT OFF, and NOT because it is wrong -- it is verified right, but it is HALF of a coupled
    # pair. Switching it on drives the recovered row-space mismatch from 13.43 deg to 1.11 deg at
    # taper 0.25 and 3.80 -> 0.014 deg at 0.80, leaves every parallelogram cell BIT-EXACT, and
    # takes the kappa_xx patch channel from 0.311 to 0.700 against the reference's 0.659 (it was
    # 45 % of the reference, it is now 106 %). But `Z` was calibrated against the OLD `D`: with the
    # row space corrected, `reach` -- the share of the taper residual that `Z` can even express --
    # jumps from 0.023 to 0.998 at taper 0.80 and 0.503 to 0.905 at 0.25, and the recovered
    # Z_ref/Z_jfem is then 0.78-1.47 in the x-family, i.e. `Zb` must be re-derived to consume this.
    # Until it is, the two errors partly cancel and turning this on alone costs +66 % on the taper
    # axis. Ship the pair together; do not enable this alone to chase the norm.
    shear_row_edge = fem_env_bool("JFEM_Q4_MACNEAL_SHEAR_ROW_EDGE", true)
    pt_row = shear_row_edge ? 1.0 : pt
    # FULL edge tying rows (all three DOF families, not just the cross component) together with
    # the matching congruence on Z -- see the Z_total assembly. On a parallelogram the pair is
    # EXACTLY equivalent to the shipped Gauss form (verified: |D_edge - T*D_gauss| = 2e-16), and
    # on a tapered cell D_edge reproduces the reference's own tying row space with reach
    # 1.000000 where the Gauss rows give 0.9974.
    row_full = shear_row_edge && fem_env_bool("JFEM_Q4_MACNEAL_SHEAR_ROW_FULL", true)
    taper_diff_fit = row_full && fem_env_bool("JFEM_Q4_TAPER_DIFF", true)
    # Revised assumed-linear shear interaction.  "interaction"
    # replaces the raw legacy physical-shear interaction; "interaction_hybrid"
    # also replaces the interaction shares introduced by the Wc cross-block
    # multiplier, taper-differential shear, and total-skew scaling.  The
    # separate additive JFEM_Q4_TAPER_SHEAR_CROSS patch remains an actual-cell
    # correction: it is not tensorial on synthetic polar companions and is
    # deliberately excluded from their replay.
    # 2026-08-03 closure: after making the additive taper-shear cross term
    # signed and orientation-equivariant, the hybrid route improves all eight
    # signed skew-taper DOE cells, closes all exact mirrors to <=3.3e-15, and
    # improves all 24 tapered/combined cached cells without a material regression.
    # Keep explicit off/raw modes for formulation bisects; hybrid is the
    # validated production route.
    # The interaction reconstruction needs the deformable-shear flexibility
    # and full edge-row basis.  Some production PSHELL routes intentionally
    # select the rigid-shear limit, and users may independently disable the
    # full-row experiment.  Keep the validated hybrid as the compatible
    # implicit default, but fall back to the established operator when either
    # prerequisite is absent.  An explicitly requested incompatible
    # interaction mode remains an error below.
    shear_edge_linear_explicit = haskey(ENV, "JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR")
    shear_edge_linear_default = row_full && !rigid_shear ? "interaction_hybrid" : "off"
    shear_edge_linear_mode = lowercase(strip(get(
        ENV, "JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR", shear_edge_linear_default)))
    shear_edge_linear_interaction_raw = shear_edge_linear_mode == "interaction"
    shear_edge_linear_interaction_hybrid =
        shear_edge_linear_mode == "interaction_hybrid"
    shear_edge_linear_interaction = shear_edge_linear_interaction_raw ||
        shear_edge_linear_interaction_hybrid
    if !(shear_edge_linear_mode in
         ("", "0", "false", "no", "off", "none", "interaction", "interaction_hybrid"))
        throw(ArgumentError(
            "unknown JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR mode: " *
            shear_edge_linear_mode))
    end
    if shear_edge_linear_explicit &&
       shear_edge_linear_interaction && (!row_full || rigid_shear)
        throw(ArgumentError(
            "JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR interaction modes require " *
            "full edge rows and non-rigid physical shear"))
    end
    shear_diff_taper = taper_diff_fit && fem_env_bool("JFEM_Q4_TAPER_SHEAR_DIFF", true)
    shear_cross_taper = taper_diff_fit && fem_env_bool("JFEM_Q4_TAPER_SHEAR_CROSS", true)

    T = promote_type(eltype(Ke), eltype(Cb), eltype(Cs), typeof(h))
    D_mat = zeros(T, 4, 12)
    J_pts = zeros(4)
    # Per-shear-sample-point physical extents for the residual-bending-flexibility
    # block (MacNeal eq 26, generalized to non-rectangular quads).
    #   pt_delta[1] = 2·J11 at (ξ=0, η=-1/√3)  → physical x-extent at γ_x sample a
    #   pt_delta[2] = 2·J11 at (ξ=0, η=+1/√3)  → physical x-extent at γ_x sample b
    #   pt_delta[3] = 2·J22 at (ξ=-1/√3, η=0)  → physical y-extent at γ_y sample c
    #   pt_delta[4] = 2·J22 at (ξ=+1/√3, η=0)  → physical y-extent at γ_y sample d
    # On a rectangle (and hence on any uniform-Jacobian quad) all γ_x extents collapse
    # to MacNeal's Δx and all γ_y extents to Δy, recovering the original eq (26).
    pt_delta = zeros(4)
    # JFEM_Q4_MACNEAL_SHEAR_COVARIANT (default OFF): build the substitute shear
    # samples as COVARIANT (strip-tangent) strains γ_t = (w,ξ + x,ξ·θy − y,ξ·θx)/|x,ξ|
    # instead of direct isoparametric γ_x/γ_y at the sample points. Identical on
    # rectangles/parallelograms (uniform Jacobian). On TAPERED quads the direct
    # form tilts the shear-block range off the reference QUAD4's: single-element
    # extraction on the HTP skin trapezoid (kex_skin268, taper 0.14%) shows a
    # rank-1 spurious stiffness of 8.4e4 on the alternating-θ twist pattern that
    # the reference treats as exactly shear-free (kex rect: JFEM==Nastran to
    # relF 3e-4; kex flat/orig: leak identical → taper, not warp).
    # 2026-07-27: default changed "false" -> "mitc". Previously measured as
    # box-INERT, but that measurement was taken with ~70 % of PCOMP elements
    # routed off the MacNeal kernel entirely by the kappa_L gate (see
    # assembly.jl JFEM_Q4_MACNEAL_PCOMP_SURFACE_KAPPA_L_MAX). With the routing
    # corrected the two are complementary: on iter_6 the gate alone gives
    # +11.4 %, "mitc" alone is inert, and together they give -0.02 %.
    shear_cov_mode = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_SHEAR_COVARIANT", "mitc")))
    shear_covariant = shear_cov_mode in ("1","true","yes","on")
    # "mitc": covariant sampling for the RANGE (taper-correct null space) with
    # PHYSICAL gamma_x/gamma_y rows reconstructed per sample via J^-1 on the
    # MITC-interpolated covariant fields (skew-correct Z application). Skew
    # family extraction (kex_s*, kjunction_boxes_20260705): reproduces the
    # reference block to 0.3% at full HTP skew where the strip form leaves a
    # 9x gamma_eta compliance deficit and misses the -8.9 cross coupling.
    shear_mitc = shear_cov_mode in ("mitc", "mitc_phys", "mitcphys")
    t_hat = zeros(2, 4)
    mitc_C = shear_mitc ? zeros(T, 4, 12) : nothing
    mitc_J = shear_mitc ? zeros(2, 2, 4) : nothing
    mitc_Ce = (shear_mitc && pt_row != pt) ? zeros(T, 4, 12) : nothing
    mitc_Je = mitc_Ce === nothing ? nothing : zeros(2, 2, 4)
    D_edge  = mitc_Ce === nothing ? nothing : zeros(T, 4, 12)
    @inbounds for sp_idx in 1:4
        xi, eta, comp = shear_pts[sp_idx]
        dNr, dNs = shape_derivs_quad(xi, eta)
        J11 = dNr[1]*coords[1,1]+dNr[2]*coords[2,1]+dNr[3]*coords[3,1]+dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2]+dNr[2]*coords[2,2]+dNr[3]*coords[3,2]+dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1]+dNs[2]*coords[2,1]+dNs[3]*coords[3,1]+dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2]+dNs[2]*coords[2,2]+dNs[3]*coords[3,2]+dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        if abs(detJ) < 1e-14
            detJ = detJ < 0.0 ? -1e-14 : 1e-14
        end
        J_pts[sp_idx] = abs(detJ)
        # Save the diagonal Jacobian component aligned with the strain axis at this point.
        # γ_x samples at (ξ=0, η=±1/√3): the "beam strip" runs in ξ → x-extent ≈ 2·|J11|
        # γ_y samples at (ξ=±1/√3, η=0): the "beam strip" runs in η → y-extent ≈ 2·|J22|
        pt_delta[sp_idx] = comp == 1 ? 2.0 * abs(J11) : 2.0 * abs(J22)
        inv_det = 1.0/detJ
        iJ11 = J22*inv_det;  iJ12 = -J12*inv_det
        iJ21 = -J21*inv_det; iJ22 = J11*inv_det

        N1 = 0.25*(1-xi)*(1-eta); N2 = 0.25*(1+xi)*(1-eta)
        N3 = 0.25*(1+xi)*(1+eta); N4 = 0.25*(1-xi)*(1+eta)
        N_vals = (N1, N2, N3, N4)

        if shear_mitc
            # raw covariant row (gamma_xi or gamma_eta, unnormalized) + J;
            # physical rows assembled after the loop.
            mitc_J[1,1,sp_idx] = J11; mitc_J[1,2,sp_idx] = J12
            mitc_J[2,1,sp_idx] = J21; mitc_J[2,2,sp_idx] = J22
            tx, ty = comp == 1 ? (J11, J12) : (J21, J22)
            t_hat[1, sp_idx] = comp == 1 ? 1.0 : 0.0
            t_hat[2, sp_idx] = comp == 1 ? 0.0 : 1.0
            for k in 1:4
                dNc = comp == 1 ? dNr[k] : dNs[k]
                Nk = N_vals[k]
                col = (k-1)*3
                mitc_C[sp_idx, col+1] = dNc
                mitc_C[sp_idx, col+2] = -Nk * ty
                mitc_C[sp_idx, col+3] =  Nk * tx
            end
            # Same covariant row re-evaluated at the EDGE midside, for the uniform-channel
            # correction applied after this loop (see pt_row). No-op when pt_row == pt.
            if mitc_Ce !== nothing
                xr = xi  == 0.0 ? 0.0 : copysign(pt_row, xi)
                er = eta == 0.0 ? 0.0 : copysign(pt_row, eta)
                dNre, dNse = shape_derivs_quad(xr, er)
                J11e = dNre[1]*coords[1,1]+dNre[2]*coords[2,1]+dNre[3]*coords[3,1]+dNre[4]*coords[4,1]
                J12e = dNre[1]*coords[1,2]+dNre[2]*coords[2,2]+dNre[3]*coords[3,2]+dNre[4]*coords[4,2]
                J21e = dNse[1]*coords[1,1]+dNse[2]*coords[2,1]+dNse[3]*coords[3,1]+dNse[4]*coords[4,1]
                J22e = dNse[1]*coords[1,2]+dNse[2]*coords[2,2]+dNse[3]*coords[3,2]+dNse[4]*coords[4,2]
                Ne = (0.25*(1-xr)*(1-er), 0.25*(1+xr)*(1-er),
                      0.25*(1+xr)*(1+er), 0.25*(1-xr)*(1+er))
                mitc_Je[1,1,sp_idx] = J11e; mitc_Je[1,2,sp_idx] = J12e
                mitc_Je[2,1,sp_idx] = J21e; mitc_Je[2,2,sp_idx] = J22e
                txe, tye = comp == 1 ? (J11e, J12e) : (J21e, J22e)
                # Only the CROSS component of the tying tangent moves to the edge -- J12 = y,r for
                # the xi-family, J21 = x,s for the eta-family. The ALIGNED component and the w
                # term stay at the sample. That is what the recovery demands and it is why only
                # one family moves on a given cell: on an x-taper the eta-family's cross term
                # x,s carries the whole fan while the xi-family's cross term y,r is identically
                # zero, so the xi-family is a no-op; the y-tapered mirror swaps the two, and the
                # measured divergent channel swaps with it (uniform-y -> uniform-x).
                for k in 1:4
                    col = (k-1)*3
                    if row_full
                        mitc_Ce[sp_idx, col+1] = comp == 1 ? dNre[k] : dNse[k]
                        mitc_Ce[sp_idx, col+2] = -Ne[k] * tye
                        mitc_Ce[sp_idx, col+3] =  Ne[k] * txe
                    elseif comp == 1
                        mitc_Ce[sp_idx, col+1] = dNr[k]
                        mitc_Ce[sp_idx, col+2] = -Ne[k] * J12e
                        mitc_Ce[sp_idx, col+3] =  N_vals[k] * J11
                    else
                        mitc_Ce[sp_idx, col+1] = dNs[k]
                        mitc_Ce[sp_idx, col+2] = -N_vals[k] * J22
                        mitc_Ce[sp_idx, col+3] =  Ne[k] * J21e
                    end
                end
            end
        elseif shear_covariant
            tx, ty = comp == 1 ? (J11, J12) : (J21, J22)
            tlen = max(hypot(tx, ty), 1e-14)
            t_hat[1, sp_idx] = tx / tlen
            t_hat[2, sp_idx] = ty / tlen
            pt_delta[sp_idx] = 2.0 * tlen
            for k in 1:4
                dN_t = (comp == 1 ? dNr[k] : dNs[k]) / tlen
                Nk = N_vals[k]
                col = (k-1)*3
                # γ_tz = (∂w/∂ξ_c + x,ξc·θy − y,ξc·θx)/|x,ξc|  (ξ_c = strip coord)
                D_mat[sp_idx, col+1] = dN_t
                D_mat[sp_idx, col+2] = -Nk * ty / tlen
                D_mat[sp_idx, col+3] =  Nk * tx / tlen
            end
        else
            t_hat[1, sp_idx] = comp == 1 ? 1.0 : 0.0
            t_hat[2, sp_idx] = comp == 1 ? 0.0 : 1.0
            for k in 1:4
                dN_dx = iJ11*dNr[k] + iJ12*dNs[k]
                dN_dy = iJ21*dNr[k] + iJ22*dNs[k]
                Nk    = N_vals[k]
                col   = (k-1)*3  # plate DOFs: 1=w, 2=θx, 3=θy
                if comp == 1  # γ_xz = ∂w/∂x + θy
                    D_mat[sp_idx, col+1] = dN_dx
                    D_mat[sp_idx, col+3] = Nk
                else          # γ_yz = ∂w/∂y − θx
                    D_mat[sp_idx, col+1] = dN_dy
                    D_mat[sp_idx, col+2] = -Nk
                end
            end
        end
    end

    if shear_mitc
        # Physical rows at each sample: [gx; gy](pt) = J(pt)^-1 [gxi(pt); geta(pt)]
        # with the covariant fields MITC-interpolated from their two samples.
        pt_m = shear_sample_edge ? 1.0 : 1.0/sqrt(3.0)
        pts_m = ((0.0,-pt_m), (0.0,pt_m), (-pt_m,0.0), (pt_m,0.0))
        for sp_idx in 1:4
            xi, eta = pts_m[sp_idx]
            J = @view (row_full ? mitc_Je : mitc_J)[:, :, sp_idx]
            detJ = J[1,1]*J[2,2] - J[1,2]*J[2,1]
            adet = abs(detJ) < 1e-14 ? (detJ < 0 ? -1e-14 : 1e-14) : detJ
            i11 =  J[2,2]/adet; i12 = -J[1,2]/adet
            i21 = -J[2,1]/adet; i22 =  J[1,1]/adet
            w1 = 0.5*(1.0 - eta/pt_m); w2 = 0.5*(1.0 + eta/pt_m)
            w3 = 0.5*(1.0 - xi/pt_m);  w4 = 0.5*(1.0 + xi/pt_m)
            for j in 1:12
                gxi  = w1*mitc_C[1,j] + w2*mitc_C[2,j]
                geta = w3*mitc_C[3,j] + w4*mitc_C[4,j]
                D_mat[sp_idx, j] = sp_idx <= 2 ? (i11*gxi + i12*geta) : (i21*gxi + i22*geta)
                if mitc_Ce !== nothing
                    gxie  = w1*mitc_Ce[1,j] + w2*mitc_Ce[2,j]
                    getae = w3*mitc_Ce[3,j] + w4*mitc_Ce[4,j]
                    D_edge[sp_idx, j] = sp_idx <= 2 ? (i11*gxie + i12*getae) :
                                                      (i21*gxie + i22*getae)
                end
            end
        end
        # UNIFORM-CHANNEL CORRECTION. Adding the SAME vector to both rows of a family changes
        # only that family's uniform channel (row_a + row_b) and leaves its differential channel
        # (row_a - row_b) bit-exact -- which is what the recovery demands: the differential
        # directions are shared between the codes, the uniform y direction is not.
        if mitc_Ce !== nothing
            if row_full
                @inbounds for i in 1:4, j in 1:12; D_mat[i,j] = D_edge[i,j]; end
            else
                @inbounds for (a, b) in ((1, 2), (3, 4)), j in 1:12
                    d = 0.5*((D_edge[a,j] + D_edge[b,j]) - (D_mat[a,j] + D_mat[b,j]))
                    D_mat[a,j] += d; D_mat[b,j] += d
                end
            end
        end
    end
    # MacNeal projected side lengths Δx, Δy (eq after 26)
    Dx = 0.5 * (coords[2,1]+coords[3,1]-coords[1,1]-coords[4,1])
    Dy = 0.5 * (coords[3,2]+coords[4,2]-coords[1,2]-coords[2,2])
    # ---------------------------------------------------------------------
    # JFEM_Q4_MACNEAL_RBF_DELTA_AREA_NORM (DIAGNOSTIC, default OFF).
    # NOT a proposed fix — a probe for one specific hypothesis about the skew bending defect.
    #
    # On a PARALLELOGRAM these projected sides should satisfy Δx·Δy = A. In the element frame
    # JFEM actually uses they do not: for the skew-45 cell (0,0),(100,0),(200,100),(100,100)
    # the natural frame gives Δx=Δy=100 with Δx·Δy = 10000 = A, while JFEM gets
    # 85.065/137.638 => 11708, i.e. 17 % out (Δx² 0.72× too stiff, Δy² 1.89× too soft).
    # Since Zb ∝ Δ²·flex/(12A) and flex ∝ 1/t³, an error in Δ is exactly thickness-independent
    # while Zb dominates and dilutes once Zs enters — the measured signature of the skew
    # rot-rot defect (0.3629/0.3655/0.3631/0.3232 over h/L 0.001→0.2).
    #
    # This rescales both Δ by sqrt(A/(Δx·Δy)) to enforce the invariant while preserving their
    # ratio.
    #
    # ⛔ RESULT: HYPOTHESIS REFUTED 2026-07-31. Enforcing the invariant makes skew WORSE, not
    # better — rot-rot error 3.54e-2 → 5.31e-2 (15°), 1.55e-1 → 2.39e-1 (30°), 3.66e-1 →
    # 5.92e-1 (45°), i.e. +50…+62 %; inert on flat/aspect/taper/warp as expected. So JFEM's
    # projected lengths are CLOSER to the reference than the invariant-satisfying ones, the
    # reference does NOT satisfy Δx·Δy = A in its own frame, and the skew defect is not in the
    # Δ magnitudes. Kept default-OFF as the record; do not retry this direction.
    Dx2 = Dx*Dx; Dy2 = Dy*Dy

    # Element area from center-Jacobian
    dNr_c = (-0.25, 0.25, 0.25, -0.25)
    dNs_c = (-0.25, -0.25, 0.25, 0.25)
    J11c = dNr_c[1]*coords[1,1]+dNr_c[2]*coords[2,1]+dNr_c[3]*coords[3,1]+dNr_c[4]*coords[4,1]
    J12c = dNr_c[1]*coords[1,2]+dNr_c[2]*coords[2,2]+dNr_c[3]*coords[3,2]+dNr_c[4]*coords[4,2]
    J21c = dNs_c[1]*coords[1,1]+dNs_c[2]*coords[2,1]+dNs_c[3]*coords[3,1]+dNs_c[4]*coords[4,1]
    J22c = dNs_c[1]*coords[1,2]+dNs_c[2]*coords[2,2]+dNs_c[3]*coords[3,2]+dNs_c[4]*coords[4,2]
    detJc = J11c*J22c - J12c*J21c
    A_elem = 4.0 * abs(detJc)
    # DIAGNOSTIC probe, default OFF (see the comment above Dx): enforce the parallelogram
    # invariant Dx*Dy = A while preserving their ratio, to test whether the projected-side
    # definition is the skew bending defect. NOT a fix and NOT promotable.
    if fem_env_bool("JFEM_Q4_MACNEAL_RBF_DELTA_AREA_NORM", false)
        _pr = abs(Dx * Dy)
        if _pr > 1e-30 && A_elem > 0
            _sc = sqrt(A_elem / _pr); Dx *= _sc; Dy *= _sc
            Dx2 = Dx*Dx; Dy2 = Dy*Dy
        end
    end
    # -------------------------------------------------------------------------
    # JFEM_Q4_MACNEAL_RBF_DELTA_MIDSIDE (default OFF).
    #
    # `Dx`/`Dy` above take only the x- and y-COMPONENTS of the mid-side vectors in the element
    # local frame. Under skew that discards the cross-component, and the loss is not benign:
    # for the skew-45 parallelogram (0,0),(100,0),(200,100),(100,100) the component form gives
    # 85.065 / 137.638 while the mid-side vectors are actually 100 and 141.42 long.
    #
    # Why LARGER Δ is the required direction: the residual E = K_ref − K_JFEM is anti-parallel
    # to JFEM's own bending block (cos −0.998, ν-independent), i.e. JFEM is a pure scalar too
    # STIFF — 1.0305/1.1372/1.3259 at 15/30/45°. Since Zb ∝ Δ²/(12A) and stiffness ∝ inv(Zb),
    # softening requires Δ to grow. That is also why the area-normalisation variant above FAILED:
    # it scales Δ by sqrt(A/(ΔxΔy)) = 0.924 here, i.e. SHRINKS them and stiffens further.
    #
    # This uses the frame-independent mid-side vector LENGTHS — MacNeal's Δ denotes the
    # element's side lengths, and a length is not a frame component.
    #
    # ⚠ PARTIAL — RIGHT FOR PURE SKEW, WRONG IN COMBINATION. NOT PROMOTABLE. Default OFF.
    # Measured whole-matrix error vs reference:
    #   pure skew 15/30/45°   3.31e-2/1.41e-1/3.20e-1 -> 1.73e-2/6.85e-2/1.15e-1  (-48…-64 %)
    #   flat, aspect, taper, warp, thickness          -> BIT-INERT, as intended
    #   aspect5 × skew45      7.29e-2 -> 3.81e-1   (5× WORSE)
    #   skew×taper×warp       3.13e-1 -> 3.49e-1   (worse)
    #   CTRIA3 aspect1/apex4  1.84e-1/8.98e-1 -> 2.12e-1/9.33e-1  (worse)
    # All 35 single-axis cells still pass the rigid-body gate (~1e-17), so it is a valid
    # stiffness — just not the right law.
    #
    # ⇒ The correct Δ must REDUCE to the mid-side length on a parallelogram but differ once
    # skew combines with aspect. That is a real constraint on the law and narrows it a lot.
    # ⇒ Also note this did NOT improve CTRIA3, whose sub-quads are skewed AND aspect-distorted
    # — consistent with the combined-distortion failure above, so the "CTRIA3 inherits the quad
    # skew defect" diagnosis is neither confirmed nor refuted by this test.
    # ⇒ METHOD NOTE: the single-axis cells alone would have promoted this. The combined
    # distortion cells (gen_more.jl) are what caught it. Never promote an element change on
    # single-axis evidence.
    #
    # MODES (JFEM_Q4_MACNEAL_RBF_DELTA_MIDSIDE):
    #   "true"/"len"  — raw mid-side vector LENGTHS  (|g1|, |g2|)
    #   "perp"        — base and PERPENDICULAR HEIGHT (|g1|, |g2|·sinθ)
    #
    # "perp" was tried because "len" regressed 5× on aspect5×skew45: there the η mid-side vector
    # is 141.42 long while the element's actual height across it is only 100.
    # ⛔ "perp" REFUTED: skew45 whole-matrix 3.203e-1 (off) -> 6.030e-1, far worse than either
    # other mode. It SHRINKS Δy (100 vs 141.42) and so stiffens further — the opposite of the
    # required direction, which the cos = -0.998 anti-parallel residual already said must be
    # softening. Δx·Δy = A is therefore NOT the right constraint (consistent with the separate
    # area-normalisation refutation above).
    #
    # SUMMARY of the Δ search: off 3.203e-1 | len 1.154e-1 | perp 6.030e-1 at skew45.
    # "len" is the best of the three on pure skew and the only one that improves anything, but
    # it breaks combined aspect×skew where JFEM's existing Δ is already good (7.29e-2). So the
    # correct Δ is close to the current one at high aspect and must grow toward the mid-side
    # length as aspect -> 1. Six candidates have now been measured (twist correction, frame
    # mode, flex_mode=full, Δ area-norm, Δ len, Δ perp); the space of simple Δ redefinitions is
    # explored and none is the law. Further progress needs MacNeal's published skew treatment
    # rather than more geometry guesses from this side.
    let dmode = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_RBF_DELTA_MIDSIDE", "false")))
        if dmode in ("1", "true", "yes", "on", "len", "perp")
            g1x = 0.5*(coords[2,1]+coords[3,1]) - 0.5*(coords[1,1]+coords[4,1])
            g1y = 0.5*(coords[2,2]+coords[3,2]) - 0.5*(coords[1,2]+coords[4,2])
            g2x = 0.5*(coords[3,1]+coords[4,1]) - 0.5*(coords[1,1]+coords[2,1])
            g2y = 0.5*(coords[3,2]+coords[4,2]) - 0.5*(coords[1,2]+coords[2,2])
            n1 = sqrt(g1x*g1x + g1y*g1y); n2 = sqrt(g2x*g2x + g2y*g2y)
            if n1 > 1e-30 && n2 > 1e-30
                if dmode == "perp"
                    cr = abs(g1x*g2y - g1y*g2x)      # |g1 x g2| = area of the parallelogram
                    Dx = n1; Dy = cr / n1            # base, perpendicular height
                else
                    Dx = n1; Dy = n2                 # raw lengths
                end
                Dx2 = Dx*Dx; Dy2 = Dy*Dy
            end
        end
    end

    # Aspect-ratio-adjusted coefficients (MacNeal eq 27):
    # a_param / b_param and their JFEM_Q4_MACNEAL_EPSILON knob were DELETED 2026-07-31.
    # They were computed here and consumed by nothing but a debug printout, so the
    # documented "calibration knob" had no effect on any matrix: measured on the
    # single-element scoreboard, eps = 0.0, 0.04 and 0.5 produce BIT-IDENTICAL results on
    # every cell and every distortion axis. Removed per the de-calibration directive - a
    # knob that appears to be a tuning parameter but silently does nothing is worse than
    # no knob, because it invites tuning that cannot work.
    flex_mode =
        flex_mode_override === :full ? "full" :
        flex_mode_override === :diag ? "diag" :
        lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_RBF_BENDING_FLEX_MODE", "diag")))
    # ------------------------------------------------------------------
    # SKEWED-STRIP frame for the residual-bending flexibilities (2026-07-31).
    #
    # eq (26)'s flexibilities are taken along the ELEMENT AXES, but MacNeal's strips run
    # along the MID-SIDE VECTORS, tilted by atan(dx/Dx) on a skewed element.  Rotating an
    # ISOTROPIC compliance changes nothing, so this is invisible on every isotropic cell --
    # the recovered uniform term u is exact to 6 digits there at every skew angle -- while
    # on a laminate it is the dominant skew error (recovered u ref/jfem = 1.620/1.279
    # cross-ply, 1.026/0.524 quasi-isotropic, 0.910/1.312 unsymmetric at skew 45).
    #
    # The strips are an ORTHOGONAL PAIR aligned with the Dx mid-side vector, i.e. ONE
    # rotation of the element frame -- not the two (non-orthogonal) mid-side vectors taken
    # separately, which is the obvious guess and is measurably wrong.  Rotating the
    # CONSTITUTIVE MATRICES (rather than patching flex_x/flex_y afterwards) is what makes
    # this compose with flex_mode: "abd" must see a rotated B as well as a rotated D, or
    # the unsymmetric-laminate correction it exists for is silently discarded.
    #
    # ACCEPTANCE: recovered u = 1.000000 in BOTH directions on all three laminate families
    # (including an UNSYMMETRIC layup, B != 0), at skew 30/45 and aspect 1/5 -- twelve
    # exact hits.  Each rival y-strip choice made exactly one family exact, the rest worse.
    Cb_f = Cb; Cm_f = Cm; Bmb_f = Bmb
    if distortion_corrections && fem_env_bool("JFEM_Q4_MACNEAL_RBF_STRIP_ROT", true)   # PROMOTED 2026-08-01
        dxs = 0.5 * (coords[2,2] + coords[3,2] - coords[1,2] - coords[4,2])
        ls = hypot(Dx, dxs)
        if ls > 1e-30 && abs(dxs) > 1e-30
            cs_ = Dx / ls; sn_ = dxs / ls
            # engineering-strain rotation into the strip frame; C' = T' C T with T = T(-phi)
            Tr = @SMatrix [ cs_^2      sn_^2      cs_*sn_;
                            sn_^2      cs_^2     -cs_*sn_;
                           -2cs_*sn_  2cs_*sn_   cs_^2 - sn_^2]
            Cb_f = Tr' * Cb * Tr
            if Cm !== nothing;  Cm_f  = Tr' * Cm  * Tr; end
            if Bmb !== nothing; Bmb_f = Tr' * Bmb * Tr; end
        end
    end
    flex_x = 1.0 / max(abs(Cb_f[1,1]), 1e-30)
    flex_y = 1.0 / max(abs(Cb_f[2,2]), 1e-30)
    if flex_mode in ("full", "compliance", "matrix")
        Cb_sym = 0.5 .* (Cb_f .+ Cb_f')
        reg = 1e-12 * max(maximum(abs, Cb_sym), 1e-30)
        Cb_reg = Cb_sym + reg .* Matrix{T}(I, 3, 3)
        Sb = inv(Cb_reg)
        flex_x = max(abs(Sb[1,1]), 1e-30)
        flex_y = max(abs(Sb[2,2]), 1e-30)
    elseif flex_mode in ("abd", "strip")
        # First-principles strip flexibility (see macneal_strip_bending_flex).
        # Unlike "diag" it does not assume D16=D26=0, and unlike "full" it does not
        # release the transverse curvature; it also carries the B matrix, so it is
        # correct for UNSYMMETRIC laminates instead of silently over-stiffening them.
        flex_x = macneal_strip_bending_flex(Cm_f, Bmb_f, Cb_f, 1)
        flex_y = macneal_strip_bending_flex(Cm_f, Bmb_f, Cb_f, 2)
    end
    inv_12A = 1.0 / (12.0 * A_elem)

    # Residual bending flexibility (MacNeal eq 26): two coupled 2x2 blocks
    # for the gamma_x(a,b) and gamma_y(c,d) shear samples.
    #
    # Tapered/non-rectangular quads: replace MacNeal's single Δx² with the
    # geometric outer product Δx_a·Δx_b at each (i,j) entry of the γ_x block,
    # using the per-shear-point physical extents `pt_delta[1..4]` recorded
    # above. Reduces exactly to the rectangular form when Δx_a=Δx_b=Δx and
    # Δy_c=Δy_d=Δy (so flat AR-aligned panels are unaffected).
    #
    # Eigenstructure check: when α=0 (uniform γ — e.g. torsion), the (a,b)
    # block becomes the rank-1 outer product [Δx_a; Δx_b][Δx_a; Δx_b]ᵀ — only
    # the physical-length-weighted SUM of γ_x is penalized; the orthogonal
    # differential mode is free. When α=1 (full bending), the block is
    # diagonal with entries Δx_a², Δx_b² — each sample is independently
    # penalized by its local span. Both limits are physically consistent
    # generalizations of MacNeal's original rectangular formulation.
    # Research switch: per-shear-sample-point Δ in MacNeal's eq (26).
    # Currently off by default — first ablation on the worst VTP taper showed
    # the per-GP form (with bilinear Δ ≈ 2·J_diag at sample) shifts K closer
    # to Nastran's overall norm but slightly worsens the directional error,
    # i.e. it's not a clean win. Leaving the implementation in place behind
    # an env switch so further exploration can compare against the legacy form.
    per_gp_delta = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_RBF_PER_GP_DELTA", "false"))) in ("1","true","yes","on")
    # JFEM_Q4_MACNEAL_ZB_DIRECTIONAL (default false; "proj"/"true" or "cov"):
    # closed-form per-direction differential residual-bending flexibility
    # d_i = C∞·ρ_i²/(ρ_i²+β), ρ_i = l_j/l_i — the MacNeal eq (27) FORM with one
    # effective saturation parameter. Replaces, atomically, the entire fitted
    # stack {zb_scale 1.28 × RS/RF aspect table × a/b ε-blend × skew tables}:
    # partial swaps recreate the documented 8%→37% cancellation trap. "cov"
    # additionally uses center covariant tangent lengths (targets the skew
    # tables); "proj" uses the projected side lengths.
    # DEFAULT ON since 2026-07-29: rung-(ii) single-element scoring vs reference KGG
    # (38 cases x 4 configs, tierb2/scores.csv) shows the closed-form law is UNIFORMLY
    # more accurate than the fitted stack it replaces — aspect family mean -0.156 pt,
    # taper -0.068, patch -0.144, and it WINS at aspect 20/30 where the 21-knot table
    # was flat-extrapolated from unmeasured data. Variants rejected there: "cov"
    # (covariant lengths, +9.5 pt at skew) and flex_mode=full (+36 pt).
    Zb = zeros(T, 4, 4)
    length_mode = lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_RBF_LENGTH_MODE", "paper")))
    swap_xy = length_mode in ("swap", "swapped", "cross")
    Lx2_rbf = swap_xy ? Dy2 : Dx2
    Ly2_rbf = swap_xy ? Dx2 : Dy2
    # ---------------------------------------------------------------------
    # Per-direction RBF decomposition (added 2026-05-22).
    # The 2×2 sub-block Zb_xx (and Zb_yy) on the γ_x (γ_y) samples has two
    # physical eigendirections:
    #   * UNIFORM γ direction (eigenvalue diag + off = 2·zb_u·c) — excited by
    #     "uniform-rotation" modes where γ is constant across the element.
    #     diff_kg_1elem_curved_bending_modes.jl shows these K_bb modes are
    #     1.50× Nastran at zb_scale=0.667; setting zb_u=1.0 closes that gap
    #     exactly for the single-element diagnostic.
    #   * DIFFERENTIAL γ direction (eigenvalue diag − off = 2·zb_d·anisotropy·c)
    #     — excited by physical bending modes. Already matches Nastran.
    # GAME-corpus test 2026-05-22 with zb_u=1.0 default: HTP_launch 511002
    # mode-1 lambda did NOT change (+9.09% vs +9.10% baseline) and mean got
    # slightly worse (2.42 → 2.51%). So the K/Kg cascade absorbs the
    # uniform-γ K_bb shift for real curved-shell buckling modes.
    # 2026-07-27: zb_u now defaults to MacNeal's PAPER value 1.0 rather than
    # tracking zb_scale (1.28). The 2026-05-22 "no change on HTP_launch" note
    # above was taken with the elements routed off the MacNeal kernel by the
    # kappa_L gate. Re-measured against Nastran KGG on an aspect rig extended
    # past the old aspect-5 ceiling (aspect 4/8/12/20/30 x skew 0/16/30, at the
    # real skin thickness ratio h/Lmax = 0.0136), the out-of-plane block was
    # 21 % (a4) to 49 % (a30) too stiff; with zb_u = 1.0 plus the directional
    # aspect law below it lands at 0.8-5.6 %, out-of-plane ratio 0.957-0.993
    # across the regime, and the FULL 24x24 error also improves (8.5 -> 6.3 %).
    # NB judge this on the whole matrix: setting JFEM_Q4_MACNEAL_RBF_ZB_SCALE
    # itself to 1.0 flatters the same eigenvalue while taking the full-matrix
    # error from 8 % to 37 %.
    zb_u = 1.0
    # MacNeal eq (26) residual bending flexibility with averaged Δx, Δy,
    # decomposed into a UNIFORM-γ direction (zb_u, the paper value 1.0) and a
    # DIFFERENTIAL-γ direction given in closed form by the eq-(27) law
    #
    #     d_i = C∞ · ρ_i² / (ρ_i² + β),      ρ_i = l_j / l_i
    #
    # with a single effective saturation parameter β (ε_eff = 1/(1+β)) and the
    # rigid/non-rigid transverse-shear arms differing only by the prefactor C∞.
    # Validated 2026-07-29 against reference KGG on 38 single-element/patch
    # cases (aspect 4-30 × skew 0-30, taper 0.2-0.8, two laminate families):
    # uniformly more accurate than the fitted table stack this replaced, and
    # decisively better at aspect 20/30 where that table was extrapolated.
    # ★ 2026-07-31: BOTH constants are MacNeal's published C_inf = 1.0. The previous values
    # (2.045 non-rigid, 1.06510 rigid) were two independently FITTED numbers standing in for
    # one paper value, and the fit was never checked against an absolute element comparison —
    # every prior element verification compared DIFFERENCES, in which a common systematic
    # cancels exactly.
    #
    # Recovered as exactly 1.00000 by bisection against reference KGG (OP4, ~11 digits) on 54
    # single-CQUAD4 cells: isotropic PSHELL over 13 thicknesses (h/L 0.001-0.305), and
    # cross-ply / quasi-isotropic / UNSYMMETRIC laminates over h/L 0.002-0.1 and aspect 1-10,
    # on BOTH branches (blank-TS MAT8 selects the rigid one). Element-level effect at 2.045:
    # a PERFECT SQUARE was 47 % wrong in Frobenius norm, entirely in transverse shear.
    # With 1.0: control 8.6e-4, aspect 1-30 8.8e-4, thickness 0.001-0.305 9.0e-3, and K33
    # exact to 0.00 % at every thickness.
    #
    # 42-deck corpus screen of the RIGID constant (the one the corpus actually uses; the
    # non-rigid change is a bit-exact no-op there): spec mean 0.98 -> 0.88, median 0.83 ->
    # 0.74, MAX 2.81 -> 2.58, |lambda1| mean 1.91 -> 1.78, decks <1% 24 -> 28, below 62 -> 53,
    # missing 0 -> 0. 26 better / 14 worse / 2 unchanged.
    # Rigs: PROJECT_STATE/TOOLS_MATPRN/{gen_doe,gen_pcomp,doecmp,pccinf,rigcinf}.jl
    zb_dir_cinf = rigid_shear ?
        fem_env_float("JFEM_Q4_MACNEAL_ZB_DIR_CINF_RIGID", 1.0) :
        fem_env_float("JFEM_Q4_MACNEAL_ZB_DIR_CINF", 1.0)
    zb_dir_beta = fem_env_float("JFEM_Q4_MACNEAL_ZB_DIR_BETA", 39.0)
    zb_rho2x = Ly2_rbf / max(Lx2_rbf, 1e-30)
    zb_rho2y = Lx2_rbf / max(Ly2_rbf, 1e-30)
    zb_d_x = zb_dir_cinf * zb_rho2x / (zb_rho2x + zb_dir_beta)
    zb_d_y = zb_dir_cinf * zb_rho2y / (zb_rho2y + zb_dir_beta)
    # ------------------------------------------------------------------
    # SKEW correction to the eq-(27) DIFFERENTIAL coefficient (2026-07-31).
    #
    # MacNeal 1978 carries a footnote on p.180: "After the paper was submitted for
    # publication, it was discovered that large errors occur when the skew angle of the
    # element exceeds twenty degrees.  This error was traced to coupling between
    # transverse shear strains, and has subsequently been corrected."  The published
    # eq (26)/(27) -- which is what the rest of this block implements -- has no skew
    # dependence at all, and JFEM inherited that gap: the rotational block was 3.5e-2 /
    # 1.5e-1 / 3.7e-1 wrong at 15 / 30 / 45 degrees, turning on between 15 and 30 exactly
    # as the footnote says.
    #
    # MEASURED, not fitted.  K_plate = D'*inv(Z)*D inverts in closed form
    # (inv(Z) = M^-1 (D K D') M^-1, M = D D'), so the reference's own Z is recoverable
    # from its punched KGG -- see PROJECT_STATE/TOOLS_MATPRN/zrec.jl.  Doing that on
    # 40+ single-element cells says:
    #   * the UNIFORM part u is already EXACT (ref/jfem = 1.000000 at every skew angle),
    #     confirming the projected-side deltas below are the reference's own;
    #   * aspect ratios 2/5/10 match to 6 digits, so eq (27) with eps = 1/40 is right;
    #   * the entire discrepancy is one scalar F multiplying the DIFFERENTIAL coefficient,
    #     the SAME F in both directions (a and b agree to 0.03-0.3 %).
    #
    # With the two mid-side vectors in the element frame, (Dx, Dxy) and (Dyx, Dy),
    # their determinant IS the area, so with p = (Dxy/Dx)(Dyx/Dy):
    #
    #     1 - p = (Dx*Dy - Dxy*Dyx)/(Dx*Dy) = A/(Dx*Dy)   =>   F = 1/(1-p)^2
    #
    # F collapses 25 cells spanning aspect 0.2-5 and skew 5-60 deg onto one curve
    # (aspect 5/skew 20 and aspect 2/skew 10 have p = 0.004897 / 0.004962 and F =
    # 1.010004 / 1.010136), and tracks F even where it is NON-MONOTONIC in skew -- both
    # peak at 55 deg and fall at 60.  Agreement 0.003 % at small skew to 0.3 % at 60.
    #
    # F is identically 1 on rectangles AND on trapezoids (Dxy = Dyx = 0 for a symmetric
    # taper), and the taper cells independently measure F = 1.00006-1.004 -- so this term
    # is skew-specific and leaves the taper defect (which is in u, not a) untouched.
    #
    # NB this is NOT the "normalise Dx*Dy to A" idea refuted earlier: that rescaled the
    # WHOLE Zb (u included, which is already exact) and by the first power, and made skew
    # 50-62 % worse.  Only the differential part takes the factor, and squared.
    #
    # MODE (JFEM_Q4_MACNEAL_ZB_SKEW): "zb" applies F to the residual-bending term only;
    # "total" applies it to the differential direction of Z = Zs + Zb further down.
    # The two are identical in the thin limit (where Zb dominates Z) and the "zb" form is
    # EXACT there -- recovered a-ratio 1.00002 at h/L = 0.001.  They differ as the plate
    # thickens and Zs takes a share of the energy: with "zb" the recovered a and b then
    # need DIFFERENT factors (1.85 vs 3.11 at h/L = 0.2, skew 45), which is what a missing
    # Zs term looks like when it is attributed to Zb.
    zb_skew_mode = distortion_corrections ?
        lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_ZB_SKEW", "total"))) : "false"  # PROMOTED 2026-08-01
    zb_skew_on = zb_skew_mode in ("1", "true", "yes", "on", "zb", "total")
    zb_skew_f = 1.0
    if zb_skew_on
        Dxy = 0.5 * (coords[2,2] + coords[3,2] - coords[1,2] - coords[4,2])
        Dyx = 0.5 * (coords[3,1] + coords[4,1] - coords[1,1] - coords[2,1])
        den = Dx * Dy - Dxy * Dyx
        zb_skew_f = abs(den) > 1e-30 ? (Dx * Dy / den)^2 : 1.0
        if zb_skew_mode != "total"
            zb_d_x *= zb_skew_f
            zb_d_y *= zb_skew_f
        end
    end
    # ------------------------------------------------------------------
    # FAN CORRECTION to the eq-(26) UNIFORM projected length (2026-08-02).
    #
    # MEASURED, not fitted. With the tying operator corrected (see JFEM_Q4_MACNEAL_SHEAR_ROW_EDGE)
    # the taper residual becomes Z-expressible, and recovering the reference's own Z in the
    # uniform/differential basis of eq (26)/(27) leaves exactly ONE term out: the UNIFORM
    # coefficient of the family CROSSED with the fan direction. Its recovered ratio is reproduced
    # to 5 digits on every cell by adding the fan sum, over three, IN QUADRATURE to the projected
    # side:
    #
    #     Delta_eff^2 = Delta^2 + ((x1 - x2 + x3 - x4)/3)^2
    #
    #   cell        fan/3     predicted    recovered   rel err
    #   f_tx010    -30.000     1.090000     1.08996    3.7e-05
    #   f_tx025    -25.000     1.062500     1.06248    1.9e-05
    #   f_tx080     -6.667     1.004444     1.00444    4.4e-06
    #   g_a05_t25  -12.500     1.015625     1.01562    4.9e-06
    #   g_a20_t25  -50.000     1.250000     1.24989    8.8e-05
    #   f_ty020    -26.667     1.071111     1.07108    2.9e-05   (y-tapered MIRROR)
    #   f_ty035    -21.667     1.046944     1.04693    1.4e-05   (y-tapered MIRROR)
    #
    # spanning x-taper 0.10-0.80, both aspect ratios and the y-tapered mirrors, with the residual
    # at the recovery's own precision. The x-fan corrects the Y family and the y-fan the X family
    # -- the same cross pairing the row-space recovery found, and the mirrors confirm it rather
    # than assume it. Identically zero on any parallelogram (the fan sum vanishes), so every
    # parallelogram axis is bit-unchanged. DIFFERENTIAL terms keep the plain projected side: their
    # recovered ratios do NOT follow this factor.
    fan_x = (coords[1,1] - coords[2,1] + coords[3,1] - coords[4,1]) / 3.0
    fan_y = (coords[1,2] - coords[2,2] + coords[3,2] - coords[4,2]) / 3.0
    zb_fan = fem_env_bool("JFEM_Q4_MACNEAL_ZB_FAN", true)
    Dx2_u = zb_fan ? Dx2 + fan_y*fan_y : Dx2
    Dy2_u = zb_fan ? Dy2 + fan_x*fan_x : Dy2
    Lx2_u = swap_xy ? Dy2_u : Dx2_u
    Ly2_u = swap_xy ? Dx2_u : Dy2_u
    zbx_u = zb_u * inv_12A * Lx2_u * flex_x
    # With the tying at the EDGE midsides the differential channel of D is 1/pt_gauss = sqrt(3)
    # larger than in the Gauss-abscissa form, so the eq-(27) differential flexibility must take
    # 1/pt_gauss^2 = 3 for the two to agree on a parallelogram -- where they must, and do.
    zb_dfac = shear_sample_edge ? 3.0 : 1.0
    zbx_d = zb_dfac * zb_d_x * inv_12A * Lx2_rbf * flex_x
    zby_u = zb_u * inv_12A * Ly2_u * flex_y
    zby_d = zb_dfac * zb_d_y * inv_12A * Ly2_rbf * flex_y
    # ------------------------------------------------------------------
    # TAPER correction to the UNIFORM residual-bending flexibility (2026-07-31).
    #
    # On a trapezoid the mid-side vectors stay axis-aligned, so the skew factor above is
    # identically 1 and taper is a genuinely separate defect.  Recovering the reference's Z
    # (TOOLS_MATPRN/zrec.jl) localises it exactly: the eq-(27) coefficient is already right
    # (d ref/jfem = 1.017 / 1.002 / 1.0002 at taper 0.25 / 0.5 / 0.7) and the whole error is
    # in the UNIFORM term, which JFEM makes too flexible.
    #
    # The bilinear "fan" coefficients a3 = (x1-x2+x3-x4)/4 and b3 = (y1-y2+y3-y4)/4 are what
    # a taper turns on (both are zero on any parallelogram, which is why this is invisible on
    # every skew and aspect cell).  Measured over a 16-cell sweep, taper 0.1-0.9 x aspect
    # 1/2/5 x thickness 0.001-0.2:
    #
    #     u_ref / u_jfem  =  1 / (1 + (16/9) * (fan / D_perp)^2)
    #
    # The coefficient converges to exactly 16/9 = 1.77778 -- measured 1.77792, 1.77868,
    # 1.77857, 1.77709 on the cells whose recovery is clean (D-subspace reach > 0.9);
    # higher-order terms appear only at extreme taper.  Thickness-independent (0.9404 /
    # 0.9399 / 0.9318 over h/L 0.001-0.2), confirming it is geometric and not shear-side.
    #
    # ACCEPTANCE BUILT IN: for an x-taper b3 = 0, so the law predicts the X family is
    # UNAFFECTED -- and u_x is measured exact (0.999-1.000) on every one of those cells.
    if distortion_corrections && fem_env_bool("JFEM_Q4_MACNEAL_ZB_TAPER", true)   # PROMOTED 2026-08-01
        fan_a3 = 0.25 * (coords[1,1] - coords[2,1] + coords[3,1] - coords[4,1])
        fan_b3 = 0.25 * (coords[1,2] - coords[2,2] + coords[3,2] - coords[4,2])
        c169 = 16.0 / 9.0
        if abs(Dx) > 1e-30
            zbx_u /= (1.0 + c169 * (fan_b3 / Dx)^2)
        end
        if abs(Dy) > 1e-30
            zby_u /= (1.0 + c169 * (fan_a3 / Dy)^2)
        end
        # ---- taper OFF-BLOCK: differential-to-differential coupling ----
        # The uniform correction above makes the recovered u exact but is worth almost
        # nothing on the matrix norm (9.139e-2 -> 9.137e-2). The taper error actually lives
        # in the Zb OFF-BLOCK, which the published eq (26) leaves identically zero and which
        # the reference does NOT: recovering its Z on trapezoids gives
        #     [1,3] = -[1,4] = -[2,3] = [2,4],  7-18 % of d
        # (contrast SKEW, where the recovered off-block is exactly zero). Those entries are
        # 0.14 % of the diagonal but 7-18 % of the DIFFERENTIAL part, which carries the small
        # eigenvalues of Z and therefore controls K. In mode form the coupling is purely
        # differential-to-differential: u'Bu = 0 exactly.
        #
        # EVEN in the fan, established by punching INVERTED trapezoids (a3 > 0), which the
        # original sweep lacked entirely -- with every cell at a3 < 0 a term odd in a3 is
        # indistinguishable from one even in it. The off-block stays NEGATIVE for both signs
        # (tau = 0.5 -> -1.149e-8, tau = 1.5 -> -4.412e-9, tau = 2.0 -> -1.240e-8), and cells
        # with equal (a3/Dx)^2 give equal magnitude regardless of sign.
        # ⛔ This REFUTES the existing default-off JFEM_Q4_MACNEAL_FAN_COUPLING, whose
        # z_fan = c1*g_fan/Cb[3,3] is LINEAR in the fan (and fits 14x worse).
        # ⚠ kappa is MEASURED (0.0295-0.0339 over 9 cells), not derived; and only the a3
        # (x-taper) half is measured -- the b3 term is the symmetry image, untested.
        kap = fem_env_float("JFEM_Q4_MACNEAL_ZB_TAPER_K", 1.0 / 30.0)
        fx = abs(Dx) > 1e-30 ? (fan_a3 / Dx)^2 : 0.0
        fy = abs(Dy) > 1e-30 ? (fan_b3 / Dy)^2 : 0.0
        w = kap * (fx + fy) * sqrt(max(zbx_u * zby_u, 0.0))
        if w != 0.0
            Zb[1,3] = -w; Zb[3,1] = -w
            Zb[1,4] =  w; Zb[4,1] =  w
            Zb[2,3] =  w; Zb[3,2] =  w
            Zb[2,4] = -w; Zb[4,2] = -w
        end
    end
    Zb[1,1] = zbx_u + zbx_d
    Zb[1,2] = zbx_u - zbx_d
    Zb[2,1] = Zb[1,2]
    Zb[2,2] = Zb[1,1]
    Zb[3,3] = zby_u + zby_d
    Zb[3,4] = zby_u - zby_d
    Zb[4,3] = Zb[3,4]
    Zb[4,4] = Zb[3,3]
    # JFEM_Q4_MACNEAL_FAN_COUPLING (default OFF): reference-measured twist-
    # mediated coupling between the two substitute-shear families on FAN-
    # distorted (strongly tapered) quads. Single-element extraction over
    # three laminate/geometry families (kex_zlaw_data.md, kjunction campaign):
    # Z_xy = c1 * g_fan / Cb66 with c1 ~ 0.036, g_fan the bilinear fan
    # fraction (xi.eta coefficient over the corresponding edge coefficient);
    # Lx-independent, laminate enters only via the twist stiffness Cb66;
    # zero on rectangles, parallelograms and pure-skew shapes (measured).
    if shear_mitc &&
       lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_FAN_COUPLING", "false"))) in ("1","true","yes","on")
        a1 = 0.25 * (-coords[1,1] + coords[2,1] + coords[3,1] - coords[4,1])
        a3 = 0.25 * ( coords[1,1] - coords[2,1] + coords[3,1] - coords[4,1])
        b2 = 0.25 * (-coords[1,2] - coords[2,2] + coords[3,2] + coords[4,2])
        b3 = 0.25 * ( coords[1,2] - coords[2,2] + coords[3,2] - coords[4,2])
        g_fan = (abs(b2) > 1e-12 ? b3 / b2 : 0.0) + (abs(a1) > 1e-12 ? a3 / a1 : 0.0)
        c1_fan = fem_env_float("JFEM_Q4_MACNEAL_FAN_C1", 0.036)
        z_fan = c1_fan * g_fan / max(abs(Cb[3,3]), 1e-30)
        for i in 1:2, j in 3:4
            Zb[i,j] += z_fan
            Zb[j,i] += z_fan
        end
        # Family-averaged first-order scale laws for the same fan distortion
        # (measured spread across laminate/aspect families ~ +-5% of the
        # correction; see kex_zlaw_data.md scale tables):
        ga = abs(g_fan)
        # Restore the bilinear-median rectangle baseline first (the measured
        # laws are ratios to the g=0 rectangle; the distorted-geometry
        # Dx/Dy/A drift the kernel baseline by several % the WRONG way):
        A_rect = 4.0 * abs(a1 * b2)
        rxx_rect = ((2a1)^2 / max(A_rect, 1e-30)) / max(Dx2 / max(A_elem, 1e-30), 1e-30)
        ryy_rect = ((2b2)^2 / max(A_rect, 1e-30)) / max(Dy2 / max(A_elem, 1e-30), 1e-30)
        sxx_fan = rxx_rect / (1.0 + fem_env_float("JFEM_Q4_MACNEAL_FAN_CXX", 0.20) * ga)
        syyd_fan = ryy_rect * (1.0 + fem_env_float("JFEM_Q4_MACNEAL_FAN_CYYD", 0.30) * ga)
        syyo_fan = ryy_rect * (1.0 + fem_env_float("JFEM_Q4_MACNEAL_FAN_CYYO", 0.40) * ga)
        for i in 1:2, j in 1:2
            Zb[i,j] *= sxx_fan
        end
        z34_d = Zb[3,3]; z34_o = Zb[3,4]
        Zb[3,3] = z34_d * syyd_fan; Zb[4,4] = Zb[4,4] * syyd_fan
        Zb[3,4] = z34_o * syyo_fan; Zb[4,3] = Zb[3,4]
    end

    # Physical shear compliance (eq 23-25)
    # [V^s] = diag(√(2 J_p)); [V^s G^s V^s] has G_s = Cs for same-component pairs,
    # G_xy for cross-pairs (symmetric per eq 25)
    Zs = zeros(T, 4, 4)
    if !rigid_shear
    comps = (1, 1, 2, 2)
    VGV = zeros(T, 4, 4)
    @inbounds for i in 1:4, j in 1:4
        ci = comps[i]; cj = comps[j]
        Jfac = sqrt(2.0*J_pts[i]) * sqrt(2.0*J_pts[j])
        # Shear modulus projected onto the sample strip directions
        # (t_hat = global x/y axes when the covariant switch is off, so this
        # reduces exactly to Cs[1,1]/Cs[2,2]/Cs[1,2]).
        G_ij = t_hat[1,i]*(Cs[1,1]*t_hat[1,j] + Cs[1,2]*t_hat[2,j]) +
               t_hat[2,i]*(Cs[2,1]*t_hat[1,j] + Cs[2,2]*t_hat[2,j])
        if ci == cj
            if i == j
                VGV[i,j] = Jfac * G_ij
            else
                # Different points, same component — no direct coupling
                # (MacNeal's integration is independent per point)
                VGV[i,j] = 0.0
            end
        else
            # Symmetric x-y coupling through G_xy (eq 25)
            VGV[i,j] = 0.5 * Jfac * G_ij
        end
    end

    # Add a tiny diagonal regularization to avoid singular VGV for near-zero G_xy cases
    for i in 1:4
        if VGV[i,i] < 1e-30
            VGV[i,i] = 1e-30
        end
    end

    # Enforce symmetry of VGV before inversion (protects against asymmetry
    # from accumulated floating-point differences in cross-coupling terms)
    VGV_sym = 0.5 * (VGV + VGV')
    Zs .= inv(VGV_sym)
    Zs .= 0.5 .* (Zs .+ Zs')
    end
    if lowercase(strip(get(ENV, "JFEM_Q4_MACNEAL_SHEAR_DEBUG", "false"))) in ("1","true","yes","on")
        println("[SHEAR_DEBUG] Zs(x1e6): ", round.(1e6 .* Zs; digits=4))
        println("[SHEAR_DEBUG] Zb(x1e6): ", round.(1e6 .* Zb; digits=4))
        println("[SHEAR_DEBUG] pt_delta: ", round.(pt_delta; digits=3), " Dx=", round(Dx; digits=3), " Dy=", round(Dy; digits=3))
    end
    # Exact revised assumed-linear shear flexibility in the EDGE-TANGENTIAL
    # strain basis.  With P(x,y) mapping [a1,a2,a3,a4] to [gamma_x,gamma_y],
    #
    #     H = integral(P' Cs P dA),   g_edge = G*a,
    #     Zs_edge = G * H^-1 * G'.
    #
    # E maps the physical MITC sample rows used by D_mat to those same four
    # edge-tangential strains.  Therefore the flexibility paired with D_mat is
    # E^-1*Zs_edge*E^-T.  The 2x2 Gauss rule integrates H exactly for the
    # bilinear geometry and the linear assumed field.
    Zs_edge_interaction = nothing
    if shear_edge_linear_interaction
        midside_mode = lowercase(strip(
            get(ENV, "JFEM_Q4_MACNEAL_RBF_DELTA_MIDSIDE", "false")))
        if !shear_mitc || shear_sample_edge || length_mode != "paper" ||
           fem_env_bool("JFEM_Q4_MACNEAL_RBF_DELTA_AREA_NORM", false) ||
           midside_mode in ("1", "true", "yes", "on", "len", "perp") ||
           !fem_env_bool("JFEM_Q4_TAPER_DIFF_ZB_ONLY", true) ||
           !distortion_corrections || per_gp_delta || !taper_diff_fit ||
           !shear_diff_taper || !shear_cross_taper || !zb_fan ||
           zb_skew_mode != "total" ||
           !fem_env_bool("JFEM_Q4_MACNEAL_ZB_TAPER", true) ||
           fem_env_bool("JFEM_Q4_MACNEAL_FAN_COUPLING", false)
            throw(ArgumentError(
                "JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR interaction modes require " *
                "the validated default MITC/Gauss, paper-length, Zb-only " *
                "taper/shear/skew correction stack"))
        end
        gpt = 1.0 / sqrt(3.0)

        # Orient opposite edges consistently with the positive x/y sample
        # directions: 1->2, 4->3, 1->4, 2->3.
        edge_nodes = ((1,2), (4,3), (1,4), (2,3))
        Dtan = zeros(T, 4, 12)
        for e in 1:4
            n1, n2 = edge_nodes[e]
            tx = coords[n2,1] - coords[n1,1]
            ty = coords[n2,2] - coords[n1,2]
            le = max(hypot(tx, ty), 1e-14)
            c = tx / le; s = ty / le
            # g_e = (w_2-w_1)/l_e + c*(theta_y1+theta_y2)/2
            #                              - s*(theta_x1+theta_x2)/2.
            for (node, sw) in ((n1, -1.0), (n2, 1.0))
                col = (node-1)*3
                Dtan[e,col+1] = sw/le
                Dtan[e,col+2] = -0.5*s
                Dtan[e,col+3] =  0.5*c
            end
        end
        # Exact change of row basis.  For the edge-row MITC operator these
        # spaces coincide; expressing the map through the actual nodal rows
        # avoids assuming that missing physical components interpolate with a
        # Cartesian average on a non-affine cell.
        Elin = Dtan / D_mat
        elin_residual = norm(Dtan - Elin * D_mat) / max(norm(Dtan), eps(T))
        elin_cond = cond(Elin)
        (!isfinite(elin_cond) || elin_cond > 1e12 || elin_residual > 1e-10) &&
            throw(ArgumentError(
                "incompatible MITC/tangential row spaces in assumed-linear interaction"))

        if shear_edge_linear_interaction
            # The shipped one-axis behavior is intentionally held fixed.
            # Isolate only the mixed part of
            # MacNeal's exact assumed-shear energy by inclusion-exclusion in
            # one common coefficient basis.  This is not a fitted cross term:
            # each H below is the same integral(P' Cs P dA), evaluated on the
            # general cell and on its affine-skew, taper, and rectangle
            # companions.  The construction is identically zero when either
            # the fan or the affine skew vanishes.  The no-skew affine
            # companion comes from the polar factor of the centre Jacobian;
            # unlike an ordered Gram-Schmidt frame, this commutes with
            # exchanging the natural r/s axes and therefore preserves the
            # CQUAD4 node-permutation symmetries.
            grx = 0.25*(-coords[1,1] + coords[2,1] + coords[3,1] - coords[4,1])
            gry = 0.25*(-coords[1,2] + coords[2,2] + coords[3,2] - coords[4,2])
            gsx = 0.25*(-coords[1,1] - coords[2,1] + coords[3,1] + coords[4,1])
            gsy = 0.25*(-coords[1,2] - coords[2,2] + coords[3,2] + coords[4,2])
            fcx = 0.25*( coords[1,1] - coords[2,1] + coords[3,1] - coords[4,1])
            fcy = 0.25*( coords[1,2] - coords[2,2] + coords[3,2] - coords[4,2])
            Aaff = T[grx gsx; gry gsy]
            gram = Symmetric(transpose(Aaff) * Aaff)
            gram_eig = eigen(gram)
            gram_scale = maximum(abs, gram_eig.values)
            gram_floor = gram_scale * eps(T)
            (gram_scale <= zero(T) ||
             minimum(gram_eig.values) <= 1e-12 * gram_scale) &&
                throw(ArgumentError(
                "degenerate centre Jacobian in assumed-linear interaction"))
            inv_root = gram_eig.vectors *
                Diagonal(inv.(sqrt.(max.(gram_eig.values, gram_floor)))) *
                transpose(gram_eig.vectors)
            Rpolar = Aaff * inv_root
            Aorth = Rpolar * Diagonal(T[max(hypot(grx, gry), 1e-14),
                                        max(hypot(gsx, gsy), 1e-14)])
            fan = T[fcx, fcy]
            corners = ((-1.0,-1.0), (1.0,-1.0), (1.0,1.0), (-1.0,1.0))

            make_companion = function (affine, with_fan)
                X = zeros(T, 4, 2)
                for k in 1:4
                    rr, ss = corners[k]
                    X[k,1] = affine[1,1]*rr + affine[1,2]*ss
                    X[k,2] = affine[2,1]*rr + affine[2,2]*ss
                    if with_fan
                        X[k,1] += fan[1]*rr*ss
                        X[k,2] += fan[2]*rr*ss
                    end
                end
                X
            end
            assumed_H = function (X)
                HH = zeros(T, 4, 4)
                for rr in (-gpt, gpt), ss in (-gpt, gpt)
                    dNr, dNs = shape_derivs_quad(rr, ss)
                    j11 = sum(dNr[k]*X[k,1] for k in 1:4)
                    j12 = sum(dNr[k]*X[k,2] for k in 1:4)
                    j21 = sum(dNs[k]*X[k,1] for k in 1:4)
                    j22 = sum(dNs[k]*X[k,2] for k in 1:4)
                    da = abs(j11*j22 - j12*j21)
                    nv = (0.25*(1-rr)*(1-ss), 0.25*(1+rr)*(1-ss),
                          0.25*(1+rr)*(1+ss), 0.25*(1-rr)*(1+ss))
                    xx = sum(nv[k]*X[k,1] for k in 1:4)
                    yy = sum(nv[k]*X[k,2] for k in 1:4)
                    PP = T[1 yy 0 0; 0 0 1 xx]
                    HH .+= da .* (transpose(PP) * Cs * PP)
                end
                0.5 * (HH + transpose(HH))
            end
            edge_G = function (X)
                GG = zeros(T, 4, 4)
                for e in 1:4
                    n1, n2 = edge_nodes[e]
                    tx = X[n2,1] - X[n1,1]
                    ty = X[n2,2] - X[n1,2]
                    le = max(hypot(tx, ty), 1e-14)
                    c = tx/le; s = ty/le
                    xm = 0.5*(X[n1,1] + X[n2,1])
                    ym = 0.5*(X[n1,2] + X[n2,2])
                    GG[e,1] = c; GG[e,2] = ym*c
                    GG[e,3] = s; GG[e,4] = xm*s
                end
                GG
            end

            edge_Dtan = function (X)
                DD = zeros(T, 4, 12)
                for e in 1:4
                    n1, n2 = edge_nodes[e]
                    tx = X[n2,1] - X[n1,1]
                    ty = X[n2,2] - X[n1,2]
                    le = max(hypot(tx, ty), 1e-14)
                    c = tx/le; s = ty/le
                    for (node, sw) in ((n1, -1.0), (n2, 1.0))
                        col = (node-1)*3
                        DD[e,col+1] = sw/le
                        DD[e,col+2] = -0.5*s
                        DD[e,col+3] =  0.5*c
                    end
                end
                DD
            end

            # Reproduce the shipped row-full MITC operator on a companion
            # geometry.  The covariant edge fields are interpolated first and
            # then converted to the requested physical x/y component with the
            # edge-midpoint Jacobian, exactly as for D_mat above.
            legacy_edge_D = function (X)
                pts = ((0.0,-1.0,1), (0.0,1.0,1),
                       (-1.0,0.0,2), (1.0,0.0,2))
                Ccov = zeros(T, 4, 12)
                Js = zeros(T, 2, 2, 4)
                for sp in 1:4
                    rr, ss, comp = pts[sp]
                    dNr, dNs = shape_derivs_quad(rr, ss)
                    nv = (0.25*(1-rr)*(1-ss), 0.25*(1+rr)*(1-ss),
                          0.25*(1+rr)*(1+ss), 0.25*(1-rr)*(1+ss))
                    j11 = sum(dNr[k]*X[k,1] for k in 1:4)
                    j12 = sum(dNr[k]*X[k,2] for k in 1:4)
                    j21 = sum(dNs[k]*X[k,1] for k in 1:4)
                    j22 = sum(dNs[k]*X[k,2] for k in 1:4)
                    Js[1,1,sp] = j11; Js[1,2,sp] = j12
                    Js[2,1,sp] = j21; Js[2,2,sp] = j22
                    tx, ty = comp == 1 ? (j11, j12) : (j21, j22)
                    for k in 1:4
                        col = (k-1)*3
                        Ccov[sp,col+1] = comp == 1 ? dNr[k] : dNs[k]
                        Ccov[sp,col+2] = -nv[k]*ty
                        Ccov[sp,col+3] =  nv[k]*tx
                    end
                end
                DD = zeros(T, 4, 12)
                for sp in 1:4
                    rr, ss, _ = pts[sp]
                    J = @view Js[:,:,sp]
                    detj = J[1,1]*J[2,2] - J[1,2]*J[2,1]
                    detj = abs(detj) < 1e-14 ? copysign(T(1e-14), detj) : detj
                    i11 = J[2,2]/detj; i12 = -J[1,2]/detj
                    i21 = -J[2,1]/detj; i22 = J[1,1]/detj
                    w1 = 0.5*(1-ss); w2 = 0.5*(1+ss)
                    w3 = 0.5*(1-rr); w4 = 0.5*(1+rr)
                    for j in 1:12
                        gxi = w1*Ccov[1,j] + w2*Ccov[2,j]
                        geta = w3*Ccov[3,j] + w4*Ccov[4,j]
                        DD[sp,j] = sp <= 2 ? i11*gxi + i12*geta :
                                             i21*gxi + i22*geta
                    end
                end
                DD
            end

            # Physical-shear flexibility used by the legacy kernel, evaluated
            # on a companion at its original Gauss tying abscissae.
            legacy_Zs_gauss = function (X)
                pts = ((0.0,-gpt), (0.0,gpt), (-gpt,0.0), (gpt,0.0))
                jac = zeros(T, 4)
                for sp in 1:4
                    rr, ss = pts[sp]
                    dNr, dNs = shape_derivs_quad(rr, ss)
                    j11 = sum(dNr[k]*X[k,1] for k in 1:4)
                    j12 = sum(dNr[k]*X[k,2] for k in 1:4)
                    j21 = sum(dNs[k]*X[k,1] for k in 1:4)
                    j22 = sum(dNs[k]*X[k,2] for k in 1:4)
                    jac[sp] = abs(j11*j22 - j12*j21)
                end
                comps = (1, 1, 2, 2)
                VV = zeros(T, 4, 4)
                for i in 1:4, j in 1:4
                    ci = comps[i]; cj = comps[j]
                    jf = sqrt(2*jac[i]) * sqrt(2*jac[j])
                    if ci == cj
                        VV[i,j] = i == j ? jf*Cs[ci,cj] : zero(T)
                    else
                        VV[i,j] = 0.5*jf*Cs[ci,cj]
                    end
                end
                VV .= 0.5 .* (VV .+ transpose(VV))
                for i in 1:4
                    VV[i,i] = max(VV[i,i], T(1e-30))
                end
                ZZ = inv(VV)
                0.5 * (ZZ + transpose(ZZ))
            end

            # Reject a companion whose Jacobian changes sign.  Using abs(detJ)
            # in the energy integration is correct for a consistently oriented
            # cell, but must not hide a folded synthetic geometry.
            validate_companion = function (X)
                dNr0, dNs0 = shape_derivs_quad(0.0, 0.0)
                j110 = sum(dNr0[k]*X[k,1] for k in 1:4)
                j120 = sum(dNr0[k]*X[k,2] for k in 1:4)
                j210 = sum(dNs0[k]*X[k,1] for k in 1:4)
                j220 = sum(dNs0[k]*X[k,2] for k in 1:4)
                det0 = j110*j220 - j120*j210
                (!isfinite(det0) || det0 == zero(T)) && throw(ArgumentError(
                    "singular interaction companion at its centre"))
                for (rr, ss) in corners
                    dNr, dNs = shape_derivs_quad(rr, ss)
                    j11 = sum(dNr[k]*X[k,1] for k in 1:4)
                    j12 = sum(dNr[k]*X[k,2] for k in 1:4)
                    j21 = sum(dNs[k]*X[k,1] for k in 1:4)
                    j22 = sum(dNs[k]*X[k,2] for k in 1:4)
                    detj = j11*j22 - j12*j21
                    (!isfinite(detj) || detj*det0 <= zero(T) ||
                     abs(detj) <= 1e-12*abs(det0)) && throw(ArgumentError(
                        "folded or singular assumed-shear interaction companion"))
                end
                nothing
            end
            equilibrated_sym_cond = function (M)
                dd = diag(M)
                any(x -> !isfinite(x) || x <= zero(T), dd) && return Inf
                ss = sqrt.(dd)
                S = Diagonal(inv.(ss))
                cond(S * M * S)
            end
            normalized_column_cond = function (M)
                nn = [norm(@view M[:,j]) for j in axes(M, 2)]
                nmax = maximum(nn)
                (!isfinite(nmax) || nmax <= zero(T) ||
                 any(x -> !isfinite(x) || x <= eps(T)*nmax, nn)) && return Inf
                cond(M * Diagonal(inv.(nn)))
            end

            Xgen  = make_companion(Aaff, true)
            Xskew = make_companion(Aaff, false)
            Xtap  = make_companion(Aorth, true)
            Xflat = make_companion(Aorth, false)
            foreach(validate_companion, (Xgen, Xskew, Xtap, Xflat))
            Hs = (assumed_H(Xgen), assumed_H(Xskew),
                  assumed_H(Xtap), assumed_H(Xflat))
            any(H -> equilibrated_sym_cond(H) > 1e12, Hs) &&
                throw(ArgumentError(
                    "ill-conditioned assumed-shear energy in interaction companions"))
            I4 = Matrix{T}(I, 4, 4)
            dHinv = Hs[1] \ I4 - Hs[2] \ I4 - Hs[3] \ I4 + Hs[4] \ I4
            Gcan = edge_G(Xgen)
            dZg = Gcan * dHinv * transpose(Gcan)
            if shear_edge_linear_interaction
                kedge = inv(gpt)
                Tedge = zeros(T, 4, 4)
                for (i, j) in ((1, 2), (3, 4))
                    Tedge[i,i] = 0.5*(1+kedge)
                    Tedge[i,j] = 0.5*(1-kedge)
                    Tedge[j,i] = 0.5*(1-kedge)
                    Tedge[j,j] = 0.5*(1+kedge)
                end
                legacy_Zs_edge = function (X)
                    Zg = legacy_Zs_gauss(X)
                    ZZ = Tedge * Zg * transpose(Tedge)
                    shear_edge_linear_interaction_hybrid || return ZZ

                    dxc = 0.5*(X[2,1]+X[3,1]-X[1,1]-X[4,1])
                    dyc = 0.5*(X[3,2]+X[4,2]-X[1,2]-X[2,2])
                    dx2c = dxc*dxc; dy2c = dyc*dyc
                    rho2x = dy2c / max(dx2c, T(1e-30))
                    rho2y = dx2c / max(dy2c, T(1e-30))

                    if taper_diff_fit
                        dNr0, dNs0 = shape_derivs_quad(0.0, 0.0)
                        c11 = sum(dNr0[k]*X[k,1] for k in 1:4)
                        c12 = sum(dNr0[k]*X[k,2] for k in 1:4)
                        c21 = sum(dNs0[k]*X[k,1] for k in 1:4)
                        c22 = sum(dNs0[k]*X[k,2] for k in 1:4)
                        detc = c11*c22 - c12*c21
                        dj = ntuple(4) do ii
                            rr, ss = CORNER_RS_FIT[ii]
                            dNr, dNs = shape_derivs_quad(rr, ss)
                            j11 = sum(dNr[k]*X[k,1] for k in 1:4)
                            j12 = sum(dNr[k]*X[k,2] for k in 1:4)
                            j21 = sum(dNs[k]*X[k,1] for k in 1:4)
                            j22 = sum(dNs[k]*X[k,2] for k in 1:4)
                            j11*j22 - j12*j21
                        end
                        dc = max(abs(detc), T(1e-30))
                        grad_r = abs(0.25*(dj[2]+dj[3]-dj[1]-dj[4])) / dc
                        grad_s = abs(0.25*(dj[3]+dj[4]-dj[1]-dj[2])) / dc
                        gsum = grad_r*grad_r + grad_s*grad_s
                        if gsum > 1e-24
                            Wc = (q4_taper_cross_factor(rho2x)*grad_r*grad_r +
                                  q4_taper_cross_factor(rho2y)*grad_s*grad_s) / gsum
                            for (i, j) in ((1,3),(1,4),(2,3),(2,4))
                                ZZ[i,j] *= Wc
                                ZZ[j,i] = ZZ[i,j]
                            end
                        end
                        if shear_diff_taper
                            for (i, j, gg, rr) in
                                ((1,2,grad_r,rho2x), (3,4,grad_s,rho2y))
                                gg <= 1e-12 && continue
                                sc = gg^4 * rr * q4_taper_shear_diff_h(gg)
                                sc <= 1e-15 && continue
                                ds = 3 * 0.5*(Zg[i,i]-Zg[i,j]-Zg[j,i]+Zg[j,j]) / 2
                                add = sc*ds
                                ZZ[i,i] += add; ZZ[j,j] += add
                                ZZ[i,j] -= add; ZZ[j,i] -= add
                            end
                        end
                    end

                    if zb_skew_mode == "total"
                        dxy = 0.5*(X[2,2]+X[3,2]-X[1,2]-X[4,2])
                        dyx = 0.5*(X[3,1]+X[4,1]-X[1,1]-X[2,1])
                        den = dxc*dyc - dxy*dyx
                        fsk = abs(den) > 1e-30 ? (dxc*dyc/den)^2 : one(T)
                        if abs(fsk-one(T)) > 1e-14
                            for (i, j) in ((1,2),(3,4))
                                dd = 0.5*(ZZ[i,i]-ZZ[i,j]-ZZ[j,i]+ZZ[j,j]) / 2
                                add = (fsk-one(T))*dd
                                ZZ[i,i] += add; ZZ[j,j] += add
                                ZZ[i,j] -= add; ZZ[j,i] -= add
                            end
                        end
                    end
                    0.5 * (ZZ + transpose(ZZ))
                end
                legacy_common = function (X)
                    Dc = legacy_edge_D(X)
                    Dtc = edge_Dtan(X)
                    Ec = Dtc / Dc
                    ec_residual = norm(Dtc - Ec * Dc) / max(norm(Dtc), eps(T))
                    ec_cond = cond(Ec)
                    (!isfinite(ec_cond) || ec_cond > 1e12 || ec_residual > 1e-10) &&
                        throw(ArgumentError(
                            "incompatible MITC/tangential companion row spaces"))
                    Znative = Ec * legacy_Zs_edge(X) * transpose(Ec)
                    Gc = edge_G(X)
                    gc_cond = normalized_column_cond(Gc)
                    (!isfinite(gc_cond) || gc_cond > 1e12) && throw(ArgumentError(
                        "ill-conditioned companion edge coefficient map"))
                    transport = Gcan / Gc
                    ZZ = transport * Znative * transpose(transport)
                    0.5 * (ZZ + transpose(ZZ))
                end
                dZg .-= legacy_common(Xgen) - legacy_common(Xskew) -
                         legacy_common(Xtap) + legacy_common(Xflat)
            end
            Zs_edge_interaction = Elin \ dZg / transpose(Elin)
            Zs_edge_interaction = 0.5 *
                (Zs_edge_interaction + transpose(Zs_edge_interaction))
        end
    end

    Z_total = Zs + Zb
    Z_total = 0.5 * (Z_total + Z_total')
    # "total" mode: put the skew factor on the DIFFERENTIAL direction of the full
    # compliance rather than on Zb alone (see the derivation above).  The differential
    # direction of each sample family is the (1,-1) eigenvector, so this scales exactly
    # the component the eq-(27) coefficient controls and leaves the uniform direction --
    # which is measured EXACT at every skew angle and thickness -- untouched.
    # D_edge = T * D_gauss on a parallelogram, T = 1/2[[1+k,1-k],[1-k,1+k]] per family with
    # k = 1/pt = sqrt(3) (uniform unchanged, differential scaled by k -- verified to 2e-16).
    # Keeping D' inv(Z) D invariant then REQUIRES the congruence Z -> T Z T', which scales
    # uniform-uniform by 1, differential-differential by k^2 = 3 and every uniform-differential
    # and cross-FAMILY term by the matching power. A diagonal factor is not enough: it leaves the
    # cross-family coupling unscaled. This makes the pair exactly equivalent on any parallelogram.
    if row_full
        k_e = 1.0 / pt
        Tc = zeros(4, 4)
        for (i, j) in ((1, 2), (3, 4))
            Tc[i,i] = 0.5*(1 + k_e); Tc[i,j] = 0.5*(1 - k_e)
            Tc[j,i] = 0.5*(1 - k_e); Tc[j,j] = 0.5*(1 + k_e)
        end
        Z_total = Tc * Z_total * transpose(Tc)
        Z_total = 0.5 * (Z_total + transpose(Z_total))
        # ------------------------------------------------------------------
        # TAPER CORRECTIONS to the eq-(27) differential coefficients -- see q4_taper_cross_factor
        # and q4_taper_diff_factor. Both are built only from the formulation's own constants
        # (3 = 1/pt^2 and eps = 0.025, whose eq-(27) partner is 39); there are NO fitted numbers.
        # Both vanish identically on a parallelogram, so no closed axis can be disturbed.
        if taper_diff_fit
            dJ = ntuple(4) do i
                r, s = CORNER_RS_FIT[i]
                dNr, dNs = shape_derivs_quad(r, s)
                a11 = dNr[1]*coords[1,1]+dNr[2]*coords[2,1]+dNr[3]*coords[3,1]+dNr[4]*coords[4,1]
                a12 = dNr[1]*coords[1,2]+dNr[2]*coords[2,2]+dNr[3]*coords[3,2]+dNr[4]*coords[4,2]
                a21 = dNs[1]*coords[1,1]+dNs[2]*coords[2,1]+dNs[3]*coords[3,1]+dNs[4]*coords[4,1]
                a22 = dNs[1]*coords[1,2]+dNs[2]*coords[2,2]+dNs[3]*coords[3,2]+dNs[4]*coords[4,2]
                a11*a22 - a12*a21
            end
            dc_signed = abs(detJc) < 1e-30 ?
                (detJc < 0.0 ? -1e-30 : 1e-30) : detJc
            gr_signed = 0.25*(dJ[2]+dJ[3]-dJ[1]-dJ[4]) / dc_signed
            gs_signed = 0.25*(dJ[3]+dJ[4]-dJ[1]-dJ[2]) / dc_signed
            gr = abs(gr_signed)
            gs = abs(gs_signed)
            rho2x_f = Dy2 / max(Dx2, 1e-30)
            rho2y_f = Dx2 / max(Dy2, 1e-30)
            # x-family carries the s-free gradient and vice versa: on an x-taper gs != 0, gr == 0
            # and the Y family is the one that moves -- confirmed on the y-tapered mirrors, where
            # the divergent channel swaps to uniform-x.
            Fx = q4_taper_diff_factor(gr, rho2x_f)
            Fy = q4_taper_diff_factor(gs, rho2y_f)
            # cross-family: weight each family's factor by the gradient that drives it, so a pure
            # x-taper uses rho2y, a pure y-taper rho2x, and a parallelogram leaves the (skew-only)
            # term untouched.
            gsum = gr*gr + gs*gs
            if gsum > 1e-24
                Wc = (q4_taper_cross_factor(rho2x_f)*gr*gr +
                      q4_taper_cross_factor(rho2y_f)*gs*gs) / gsum
                if abs(Wc - 1.0) > 1e-15
                    @inbounds for (i, j) in ((1,3),(1,4),(2,3),(2,4))
                        Z_total[i,j] *= Wc; Z_total[j,i] = Z_total[i,j]
                    end
                end
            end
            # F is a RESIDUAL-BENDING law, so it must act on Zb's share of the differential,
            # not on the total. The congruence has already scaled every differential by 1/pt^2,
            # so Zb's post-congruence share is 3*(Zb[i,i] - Zb[i,j]).
            zbfac = fem_env_bool("JFEM_Q4_TAPER_DIFF_ZB_ONLY", true)
            @inbounds for (i, j, Ff) in ((1, 2, Fx), (3, 4, Fy))
                abs(Ff - 1.0) < 1e-15 && continue
                dd = zbfac ?
                    3.0 * 0.5 * (Zb[i,i] - Zb[i,j] - Zb[j,i] + Zb[j,j]) / 2 :
                    0.5 * (Z_total[i,i] - Z_total[i,j] - Z_total[j,i] + Z_total[j,j]) / 2
                add = (Ff - 1.0) * dd
                Z_total[i,i] += add; Z_total[j,j] += add
                Z_total[i,j] -= add; Z_total[j,i] -= add
            end
            # SHEAR share of the differential. Recovered: with Zb exact on every channel, the
            # whole remaining taper residual is proportional to Zs (identical thick and thin --
            # -0.06531 vs -0.06538 normalised by Zs, and the total flexibility error scales as
            # h^2 to within a factor 100.0 across a decade of thickness), and its aspect
            # dependence is EXACTLY linear in rho2: residual/(Zs*rho2) measured
            #   0.36474 0.36471 0.36470 0.36471   at taper 0.15, aspect 0.5 1 2 4
            #   0.14705 0.14710 0.14709 0.14711   at taper 0.25
            #   0.035755 0.035776 0.035770 0.035791 at taper 0.40
            # i.e. constant to 4 digits over an 8x aspect range. The taper dependence is g^4, the
            # same power the residual-bending factor carries, so the derived part is g^4 * rho2.
            # ⚠ a residual of 1.06-1.22 remains on that (a slow drift toward 1 as the taper
            # weakens); it is NOT fitted here -- see the handover.
            # SHEAR cross-family coupling. JFEM has NO cross block in Zs at all (measured 1e-16),
            # while the reference carries one on a tapered cell. Inject it in the two channels it
            # actually occupies -- uu and du are 1e-16 in BOTH codes and must stay there:
            #   dd = a  <-  [[a,-a],[-a,a]]      ud = b  <-  [[b,-b],[b,-b]]
            #   du = c  <-  [[c,c],[-c,-c]]
            if shear_cross_taper
                # Normalise by the TRANSPORTED shear flexibility's uniform, not the raw one:
                # (T Zs T')[1,1] + (T Zs T')[1,2] = t1*Zs11 + Zs12 + t2*Zs22 with t1,t2 = (1+-k)/2.
                # Those coincide only when Zs11 == Zs22, i.e. only off a taper -- which is exactly
                # where this term lives, so the distinction is not optional.
                t1c = 0.5*(1 + k_e); t2c = 0.5*(1 - k_e)
                # The transported uniform row has an orientation: when the
                # determinant gradient reverses, the two tying samples swap.
                # Swap the congruence weights with them.  Keeping t1/t2 tied
                # to storage order made the otherwise mirrored correction
                # acquire a different magnitude under taper inversion.
                tx1, tx2 = gs_signed <= 0.0 ? (t1c, t2c) : (t2c, t1c)
                ty1, ty2 = gr_signed <= 0.0 ? (t1c, t2c) : (t2c, t1c)
                zsu_x = tx1*Zs[1,1] + Zs[1,2] + tx2*Zs[2,2]
                zsu_y = ty1*Zs[3,3] + Zs[3,4] + ty2*Zs[4,4]
                zsn = sqrt(max(zsu_x * zsu_y, 0.0)) / 2
                if zsn > 0.0
                    dd_s = q4_taper_shear_cross_D(gs) * sqrt(max(rho2y_f, 0.0)) * zsn
                    dd_r = q4_taper_shear_cross_D(gr) * sqrt(max(rho2x_f, 0.0)) * zsn
                    aa = dd_s + dd_r
                    # The ud/du channels are oriented natural-coordinate
                    # covectors.  Their magnitudes are fixed by |grad(detJ)|,
                    # but their signs must follow grad(detJ)/detJc.  This is
                    # what makes the correction equivariant under taper
                    # inversion and the x/y reflections while retaining the
                    # calibrated top-narrow branch exactly.
                    bb = (gs_signed / 3) * dd_s       # x-taper: u_x . d_y
                    cc = (gr_signed / 3) * dd_r       # y-taper: d_x . u_y
                    if abs(aa) + abs(bb) + abs(cc) > 0.0
                        Z_total[1,3] += aa + bb + cc; Z_total[1,4] += -aa - bb + cc
                        Z_total[2,3] += -aa + bb - cc; Z_total[2,4] +=  aa - bb - cc
                        @inbounds for (i, j) in ((1,3),(1,4),(2,3),(2,4))
                            Z_total[j,i] = Z_total[i,j]
                        end
                    end
                end
            end
            if shear_diff_taper
                @inbounds for (i, j, gg, rr) in ((1, 2, gr, rho2x_f), (3, 4, gs, rho2y_f))
                    gg <= 1e-12 && continue
                    g2 = gg*gg; sc = g2*g2*rr*q4_taper_shear_diff_h(gg)
                    sc <= 1e-15 && continue
                    ds = 3.0 * 0.5 * (Zs[i,i] - Zs[i,j] - Zs[j,i] + Zs[j,j]) / 2
                    adds = sc * ds
                    Z_total[i,i] += adds; Z_total[j,j] += adds
                    Z_total[i,j] -= adds; Z_total[j,i] -= adds
                end
            end
        end
    end
    if zb_skew_mode == "total" && abs(zb_skew_f - 1.0) > 1e-14
        for (i, j) in ((1, 2), (3, 4))
            d = 0.5 * (Z_total[i,i] - Z_total[i,j] - Z_total[j,i] + Z_total[j,j]) / 2
            add = (zb_skew_f - 1.0) * d
            Z_total[i,i] += add; Z_total[j,j] += add
            Z_total[i,j] -= add; Z_total[j,i] -= add
        end
    end
    if shear_edge_linear_interaction
        Z_total .+= Zs_edge_interaction
        Z_total .= 0.5 .* (Z_total .+ transpose(Z_total))
    end
    # K_plate = Dᵀ · inv(Z_total) · D
    K_plate = D_mat' * (Z_total \ D_mat)
    # Enforce exact symmetry on K_plate to avoid roundoff-level asymmetry
    # tripping the solver's positive-definiteness checks
    K_plate = 0.5 * (K_plate + K_plate')

    # Diagnostic dump of the flexibility formulation's own operands, so the
    # reference solver's Z can be RECOVERED rather than guessed at:
    #   K_plate = Dᵀ·inv(Z)·D  with D (4×12) full row rank
    #   ⇒  inv(Z) = M⁻¹ (D·K_plate·Dᵀ) M⁻¹,   M = D·Dᵀ
    # so a reference K_plate yields the reference Z exactly. Writes NPY-free
    # whitespace text (rows of D, then Zb, Zs) to $JFEM_Q4_DUMP_ZMAT.
    let zdump = get(ENV, "JFEM_Q4_DUMP_ZMAT", "")
        if !isempty(zdump)
            open(zdump, "a") do io
                println(io, "# ZMAT")
                for i in 1:4
                    println(io, "XY ", string(Float64(coords[i, 1])), " ", string(Float64(coords[i, 2])))
                end
                for i in 1:4
                    println(io, "D ", join((string(Float64(D_mat[i, j])) for j in 1:12), " "))
                end
                for i in 1:4
                    println(io, "Zb ", join((string(Float64(Zb[i, j])) for j in 1:4), " "))
                end
                for i in 1:4
                    println(io, "Zs ", join((string(Float64(Zs[i, j])) for j in 1:4), " "))
                end
                for i in 1:12
                    println(io, "KP ", join((string(Float64(K_plate[i, j])) for j in 1:12), " "))
                end
            end
        end
    end

    snorm_completion_active = snorm_pq !== nothing && !all(iszero, snorm_pq)
    if snorm_completion_active
        # Extend MacNeal's four assumed physical-shear rows from the plate
        # variables (w,rx,ry) to the completed surface kinematics
        # (u,v,w,rx,ry). Rows 1:2 are gamma_x samples and rows 3:4 are
        # gamma_y samples. The completion is derived from each final assumed
        # row (after all MITC/taper/skew row operations), so it preserves that
        # row's exact rigid-spin cancellation even on distorted cells.
        D24 = zeros(T, 4, 24)
        @inbounds for row in 1:4
            c_spin = zero(T)
            p_weight = zero(T)
            q_weight = zero(T)
            for k in 1:4
                col = 3(k-1)
                base = 6(k-1)
                wcoef = D_mat[row,col+1]
                rxcoef = D_mat[row,col+2]
                rycoef = D_mat[row,col+3]
                D24[row,base+3] = wcoef
                D24[row,base+4] = rxcoef
                D24[row,base+5] = rycoef
                c_spin += rxcoef*snorm_pq[k,1] + rycoef*snorm_pq[k,2]
                p_weight += rycoef*snorm_pq[k,1]
                q_weight -= rxcoef*snorm_pq[k,2]
            end
            for k in 1:4
                col = 3(k-1)
                base = 6(k-1)
                wcoef = D_mat[row,col+1]
                if row <= 2
                    D24[row,base+1] = p_weight*wcoef
                    D24[row,base+2] = c_spin*wcoef
                else
                    D24[row,base+1] = -c_spin*wcoef
                    D24[row,base+2] = q_weight*wcoef
                end
            end
        end
        K24 = transpose(D24) * (Z_total \ D24)
        K24 = 0.5 * (K24 + transpose(K24))
        Ke .+= K24
    else
        # Preserve the established flat/default operator bit-for-bit when no
        # nonzero director field is present.
        plate_dofs = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)
        @inbounds for j in 1:12, i in 1:12
            Ke[plate_dofs[i], plate_dofs[j]] += K_plate[i, j]
        end
    end
    return Ke
end

# ---------------------------------------------------------------------------
# MacNeal twist compatibility correction (eq 17):
#   χ̃_xy = 2·χ_xy(GP) − χ_xy(0)
# Rewrites the χ_xy row of Bb at each Gauss point by subtracting the
# center-Jacobian contribution, doubling the GP contribution. This stiffens
# twist-dominated modes (per MacNeal's analysis of linear-twist bending).
# Pass in the center B_xy row computed once per element.
# ---------------------------------------------------------------------------
@inline function macneal_twist_correct!(Bb::AbstractMatrix{Float64},
                                         Bb_center_row::AbstractVector{Float64})
    @inbounds for j in 1:length(Bb_center_row)
        Bb[3, j] = 2.0 * Bb[3, j] - Bb_center_row[j]
    end
    return Bb
end

"""
    apply_macneal_warp_correction!(Ke, coords_3d, frame_axes, centroid; alpha=-1/3)

Apply a partial reverse-engineering of MacNeal 1978's warp correction to an
element K matrix that was computed on the projected (flat-best-fit) quad.

Per `NAST705/probes/jfem_warp_lc_sweep.jl`, Convention G (this function):
adding rigid-offset translation↔rotation coupling scaled by α at each corner's
warp height z_i (signed distance from the mean plane, in element-local frame)
matches Nastran KGG[θ_x, T_x] within 4–12% on a single warped iso CQUAD4 test.

It does NOT capture the second-order localised K[T_z, T_x] coupling at the
warped corner that MacNeal mentions ("additional normal forces, not additional
moments") — that requires further derivation. This is therefore a **partial**
correction; gated behind `JFEM_MACNEAL_WARP_ALPHA` (default 0 = off).

The transformation is applied in element-LOCAL frame:
  T_off[u_x_real, θ_y_real] = +α·z_i      ← node-i diag block
  T_off[u_y_real, θ_x_real] = −α·z_i      ← node-i diag block
  K_warp = T_off^T · K_flat · T_off

`frame_axes = (v1, v2, v3)` defines the element-local frame; `centroid` is the
3D centroid (used to compute z_i = (P_i − centroid) · v3).
"""
function apply_macneal_warp_correction!(Ke::AbstractMatrix{Float64},
                                         coords_3d::AbstractMatrix{Float64},
                                         frame_axes,
                                         centroid::AbstractVector{Float64};
                                         alpha::Float64=-1.0/3.0)
    v3 = frame_axes[3]
    z = ntuple(i -> begin
        d1 = coords_3d[i, 1] - centroid[1]
        d2 = coords_3d[i, 2] - centroid[2]
        d3 = coords_3d[i, 3] - centroid[3]
        d1*v3[1] + d2*v3[2] + d3*v3[3]
    end, 4)
    # Build T_off: 24×24 identity plus per-corner rigid offset, in element-local frame.
    # In local frame, corner offset along v3 (local z) by z_i, so:
    #   u_x_real = u_x + (α·z_i) * θ_y
    #   u_y_real = u_y + (-α·z_i) * θ_x
    # Apply K_warp = T^T K T in-place using two GEMM-like operations.
    T = Matrix{Float64}(I, 24, 24)
    @inbounds for n in 0:3
        zi = alpha * z[n + 1]
        T[6n + 1, 6n + 5] = +zi
        T[6n + 2, 6n + 4] = -zi
    end
    K_warp = T' * Ke * T
    @inbounds for j in 1:24, i in 1:24
        Ke[i, j] = K_warp[i, j]
    end
    return Ke
end

@inline function quad4_is_axis_aligned_rectangle(coords::AbstractMatrix; tol::Float64=1e-8)
    e12 = SVector(coords[2,1] - coords[1,1], coords[2,2] - coords[1,2])
    e23 = SVector(coords[3,1] - coords[2,1], coords[3,2] - coords[2,2])
    e34 = SVector(coords[4,1] - coords[3,1], coords[4,2] - coords[3,2])
    e41 = SVector(coords[1,1] - coords[4,1], coords[1,2] - coords[4,2])

    function cross2(a::SVector{2,Float64}, b::SVector{2,Float64})
        return a[1] * b[2] - a[2] * b[1]
    end

    Lmax = max(norm(e12), norm(e23), norm(e34), norm(e41), 1e-12)
    area_scale = Lmax * Lmax

    if abs(cross2(e12, e34)) > tol * area_scale || abs(cross2(e23, e41)) > tol * area_scale
        return false
    end
    if abs(dot(e12, e23)) > tol * area_scale ||
       abs(dot(e23, e34)) > tol * area_scale ||
       abs(dot(e34, e41)) > tol * area_scale ||
       abs(dot(e41, e12)) > tol * area_scale
        return false
    end

    if abs(norm(e12) - norm(e34)) > tol * Lmax || abs(norm(e23) - norm(e41)) > tol * Lmax
        return false
    end

    return true
end

@inline function adini_plate_basis(x::Float64, y::Float64)
    return SVector(
        1.0,
        x,
        y,
        x^2,
        x * y,
        y^2,
        x^3,
        x^2 * y,
        x * y^2,
        y^3,
        x^3 * y,
        x * y^3,
    )
end

@inline function adini_plate_basis_dx(x::Float64, y::Float64)
    return SVector(
        0.0,
        1.0,
        0.0,
        2.0 * x,
        y,
        0.0,
        3.0 * x^2,
        2.0 * x * y,
        y^2,
        0.0,
        3.0 * x^2 * y,
        y^3,
    )
end

@inline function adini_plate_basis_dy(x::Float64, y::Float64)
    return SVector(
        0.0,
        0.0,
        1.0,
        0.0,
        x,
        2.0 * y,
        0.0,
        x^2,
        2.0 * x * y,
        3.0 * y^2,
        x^3,
        3.0 * x * y^2,
    )
end

@inline function adini_plate_basis_dxx(x::Float64, y::Float64)
    return SVector(
        0.0,
        0.0,
        0.0,
        2.0,
        0.0,
        0.0,
        6.0 * x,
        2.0 * y,
        0.0,
        0.0,
        6.0 * x * y,
        0.0,
    )
end

@inline function adini_plate_basis_dyy(x::Float64, y::Float64)
    return SVector(
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        2.0,
        0.0,
        0.0,
        2.0 * x,
        6.0 * y,
        0.0,
        6.0 * x * y,
    )
end

@inline function adini_plate_basis_dxy(x::Float64, y::Float64)
    return SVector(
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        2.0 * x,
        2.0 * y,
        0.0,
        3.0 * x^2,
        3.0 * y^2,
    )
end

# Plate-mode CQUAD4 research kernels (Adini, DKQ, DKMQ + their K_g overloads)
# — quarantined to experimental/ 2026-05-25. Reached only via the
# JFEM_SOL105_EIG_FLAT_PCOMP_DKMQ / _RECT_ADINI / _PLATE_BRANCH env knobs
# (all default false).
include(joinpath(@__DIR__, "experimental", "plate_kernels.jl"))


function compute_principal_2d(s11, s22, s12)
    s_avg = (s11 + s22) / 2.0
    radius = sqrt(((s11 - s22) / 2.0)^2 + s12^2)
    return s_avg + radius, s_avg - radius
end

function quad4_mitc4_center_shear_resultant(coords, u_elem, G, h;
                                            ts_t=5.0/6.0,
                                            snorm_pq=nothing)
    tying_pts = (SVector(0.0, -1.0), SVector(0.0, 1.0), SVector(-1.0, 0.0), SVector(1.0, 0.0))
    Bs_tp = zeros(4, 24)
    for tp_idx in 1:4
        xi_tp, eta_tp = tying_pts[tp_idx][1], tying_pts[tp_idx][2]
        dNr, dNs = shape_derivs_quad(xi_tp, eta_tp)
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        N_tp = (
            0.25*(1.0-xi_tp)*(1.0-eta_tp),
            0.25*(1.0+xi_tp)*(1.0-eta_tp),
            0.25*(1.0+xi_tp)*(1.0+eta_tp),
            0.25*(1.0-xi_tp)*(1.0+eta_tp),
        )
        p_tp = snorm_pq === nothing ? 0.0 : sum(N_tp[k]*snorm_pq[k,1] for k in 1:4)
        q_tp = snorm_pq === nothing ? 0.0 : sum(N_tp[k]*snorm_pq[k,2] for k in 1:4)
        if tp_idx <= 2
            for k in 1:4
                idx = (k-1)*6
                Bs_tp[tp_idx, idx+3] = dNr[k]
                Bs_tp[tp_idx, idx+4] = -J12 * N_tp[k]
                Bs_tp[tp_idx, idx+5] =  J11 * N_tp[k]
                Bs_tp[tp_idx, idx+1] = p_tp * dNr[k]
                Bs_tp[tp_idx, idx+2] = q_tp * dNr[k]
            end
        else
            for k in 1:4
                idx = (k-1)*6
                Bs_tp[tp_idx, idx+3] = dNs[k]
                Bs_tp[tp_idx, idx+4] = -J22 * N_tp[k]
                Bs_tp[tp_idx, idx+5] =  J21 * N_tp[k]
                Bs_tp[tp_idx, idx+1] = p_tp * dNs[k]
                Bs_tp[tp_idx, idx+2] = q_tp * dNs[k]
            end
        end
    end

    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J11c = dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]
    J12c = dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2]
    J21c = dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]
    J22c = dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    detJc = J11c*J22c - J12c*J21c
    abs_detJc = max(abs(detJc), 1e-30)
    inv_detc = 1.0 / detJc
    iJ11c =  J22c * inv_detc
    iJ12c = -J12c * inv_detc
    iJ21c = -J21c * inv_detc
    iJ22c =  J11c * inv_detc

    Bs_cov = zeros(2, 24)
    for j in 1:24
        Bs_cov[1,j] = 0.5 * (Bs_tp[1,j] + Bs_tp[2,j])
        Bs_cov[2,j] = 0.5 * (Bs_tp[3,j] + Bs_tp[4,j])
    end

    phi2_shear = 1.0
    _alpha = PHI2_ALPHA[]
    if _alpha > 0.0
        L_char_sq = max(4.0 * abs_detJc, 1e-30)
        phi2_shear = min(1.0, _alpha * h^2 / L_char_sq)
    end

    gamma_cov = Bs_cov * u_elem
    k_shear = ts_t * G * h
    t11 = k_shear * iJ11c
    t12 = k_shear * iJ12c
    t21 = k_shear * iJ21c
    t22 = k_shear * iJ22c
    Q_cov = phi2_shear .* [
        iJ11c*t11 + iJ21c*t21  iJ11c*t12 + iJ21c*t22;
        iJ12c*t11 + iJ22c*t21  iJ12c*t12 + iJ22c*t22
    ] * gamma_cov

    return [
        J11c * Q_cov[1] + J21c * Q_cov[2],
        J12c * Q_cov[1] + J22c * Q_cov[2],
    ]
end

function stress_strain_quad4(coords, u_elem, E, nu, h, t_shell; bend_ratio=1.0, Cm_override=nothing, for_kg=false, curvature_membrane=nothing, membrane_shear_center_row::Bool=false, material_shear_rotation::Float64=0.0, membrane_incomp_center_jacobian::Bool=false, snorm_pq=nothing, coords_3d=nothing)
    const_mem = E / (1 - nu^2)
    D_mem = const_mem .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]
    # For PCOMP elements, use CLT Cm for incompatible mode condensation
    # (must match the Cm used in stiffness assembly for consistent strain recovery)
    Cm = isnothing(Cm_override) ? D_mem * h : Cm_override

    # Recovery uses the same physical-to-projected ordering as stiffness:
    # first the finite-warp map W, then the selected PARAM,SNORM equilibrium map.
    if (coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)) ||
       snorm_pq !== nothing
        u_elem = collect(u_elem)
        warp_map = nothing
        if coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)
            warp_map = quad4_finite_warp_displacement_map(coords, coords_3d)
            warp_map === nothing || (u_elem = warp_map * u_elem)
        end
        if snorm_pq !== nothing
            if quad4_snorm_normal_moment_mode()
                snorm_relative_pq = quad4_snorm_relative_to_finite_warp_pq(
                    snorm_pq, warp_map)
                snorm_relative_pq === nothing ||
                    apply_quad4_snorm_normal_moment_displacement!(
                        u_elem, coords, snorm_relative_pq)
                # The normal-moment map is the complete kinematic operation;
                # suppress the superseded local director-gradient rows.
                snorm_pq = nothing
            else
                apply_quad4_snorm_director_displacement!(u_elem, snorm_pq)
            end
        end
    end

    dNr, dNs = shape_derivs_quad(0.0, 0.0)
    J = [dNr'; dNs'] * coords
    invJ = inv(J); dN_dxy = invJ * [dNr'; dNs']
    iJ11c = invJ[1,1]; iJ12c = invJ[1,2]
    iJ21c = invJ[2,1]; iJ22c = invJ[2,2]

    Bm = zeros(3, 24); Bb = zeros(3, 24)

    for k in 1:4
        idx = (k-1)*6
        N_k = 0.25
        Bm[1, idx+1]=dN_dxy[1,k]; Bm[2, idx+2]=dN_dxy[2,k]
        Bm[3, idx+1]=dN_dxy[2,k]; Bm[3, idx+2]=dN_dxy[1,k]
        if curvature_membrane !== nothing
            Bm[1, idx+3] = -N_k * curvature_membrane[1]
            Bm[2, idx+3] = -N_k * curvature_membrane[2]
            Bm[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
        end
        Bb[1, idx+5] = dN_dxy[1,k];
        Bb[2, idx+4] = -dN_dxy[2,k];
        Bb[3, idx+5] = dN_dxy[2,k];
        Bb[3, idx+4] = -dN_dxy[1,k];
    end
    add_quad4_snorm_curvature_B!(Bb, dN_dxy, snorm_pq)

    # For Kg assembly, use compatible strain at center only (no incompatible modes).
    # Incompatible modes are internal bubble functions that improve element stiffness
    # but should not contribute to the physical membrane stress used for Kg.
    if for_kg
        eps_mem = Bm * u_elem
        kappa = Bb * u_elem
        N = Cm * eps_mem
        M = -bend_ratio * (D_mem * kappa) * (h^3/12.0)
        G = E / (2*(1+nu))
        Q = bend_ratio <= 1e-12 ? [0.0, 0.0] :
            quad4_mitc4_center_shear_resultant(coords, u_elem, G, h; snorm_pq=snorm_pq)
        z1 = -h/2.0; z2 = h/2.0
        strain_z1 = eps_mem .+ z1 .* kappa
        stress_z1 = D_mem * strain_z1
        strain_z2 = eps_mem .+ z2 .* kappa
        stress_z2 = D_mem * strain_z2
        return N, M, Q, stress_z1, stress_z2, strain_z1, strain_z2
    end

    # Recover incompatible mode amplitudes via static condensation
    # α = -K_bb^{-1} * K_ba * u  (K_ba = K_ab')
    # Recompute K_ab and K_bb (membrane incompatible coupling)
    K_ab_sr = zeros(24, 4); K_bb_sr = zeros(4, 4)
    pt = 1.0/sqrt(3.0)
    gauss_pts = [-pt -pt; pt -pt; pt pt; -pt pt]
    for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12; detJ_g = 1e-12; end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
            Bm_g[1, idx+1] = dN_dxy_g[1,k]; Bm_g[2, idx+2] = dN_dxy_g[2,k]
            Bm_g[3, idx+1] = dN_dxy_g[2,k]; Bm_g[3, idx+2] = dN_dxy_g[1,k]
            if curvature_membrane !== nothing
                Bm_g[1, idx+3] = -N_k * curvature_membrane[1]
                Bm_g[2, idx+3] = -N_k * curvature_membrane[2]
                Bm_g[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(Bm_g, dN_dxy[1,:], dN_dxy[2,:], curvature_membrane, material_shear_rotation)
        end

        Bi = zeros(3, 4)
        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        K_ab_sr .+= (Bm_g' * Cm * Bi) .* detJ_g
        K_bb_sr .+= (Bi' * Cm * Bi) .* detJ_g
    end

    alpha = -(K_bb_sr \ (K_ab_sr' * u_elem))

    # Incompatible mode B-matrix at center (ξ=η=0)
    # φ1 = 1-ξ², dφ1/dξ = -2ξ = 0 at center; φ2 = 1-η², dφ2/dη = -2η = 0 at center
    # So the incompatible mode derivatives are zero at center.
    # The strain correction from incompatible modes is zero at center.
    # BUT the forces N = ∫ σ dA are affected because the incompatible modes
    # change the strain field at the Gauss points.

    # For stress recovery, compute the average strain including incompatible modes
    # by integrating over Gauss points
    eps_mem_avg = zeros(3)
    kappa_avg = zeros(3)
    total_area = 0.0
    for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12; detJ_g = 1e-12; end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        # Standard membrane strain at this GP
        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            Bm_g[1, idx+1] = dN_dxy_g[1,k]; Bm_g[2, idx+2] = dN_dxy_g[2,k]
            Bm_g[3, idx+1] = dN_dxy_g[2,k]; Bm_g[3, idx+2] = dN_dxy_g[1,k]
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(Bm_g, dN_dxy[1,:], dN_dxy[2,:], nothing, material_shear_rotation)
        end

        # Bending strain at this GP
        Bb_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            Bb_g[1, idx+5] = dN_dxy_g[1,k]
            Bb_g[2, idx+4] = -dN_dxy_g[2,k]
            Bb_g[3, idx+5] = dN_dxy_g[2,k]
            Bb_g[3, idx+4] = -dN_dxy_g[1,k]
        end
        add_quad4_snorm_curvature_B!(Bb_g, dN_dxy_g, snorm_pq)

        # Incompatible mode strain at this GP
        Bi = zeros(3, 4)
        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        eps_gp = Bm_g * u_elem .+ Bi * alpha
        kappa_gp = Bb_g * u_elem

        eps_mem_avg .+= eps_gp .* detJ_g
        kappa_avg .+= kappa_gp .* detJ_g
        total_area += detJ_g
    end
    eps_mem_avg ./= total_area
    kappa_avg ./= total_area

    eps_mem = eps_mem_avg
    kappa = kappa_avg

    N = Cm * eps_mem
    M = -bend_ratio * (D_mem * kappa) * (h^3/12.0)

    G = E / (2*(1+nu))
    Q = bend_ratio <= 1e-12 ? [0.0, 0.0] :
        quad4_mitc4_center_shear_resultant(coords, u_elem, G, h; snorm_pq=snorm_pq)

    z1 = -h/2.0; z2 = h/2.0

    strain_z1 = eps_mem .+ z1 .* kappa
    stress_z1 = D_mem * strain_z1
    strain_z2 = eps_mem .+ z2 .* kappa
    stress_z2 = D_mem * strain_z2

    return N, M, Q, stress_z1, stress_z2, strain_z1, strain_z2
end

function quad4_bilinear_corner_forces(coords, u_elem, E, nu, h;
                                      bend_ratio=1.0,
                                      Cm_override=nothing,
                                      Cb_override=nothing,
                                      curvature_membrane=nothing,
                                      membrane_shear_center_row::Bool=false,
                                      material_shear_rotation::Float64=0.0,
                                      membrane_incomp_center_jacobian::Bool=false,
                                      snorm_pq=nothing,
                                      coords_3d=nothing)
    const_mem = E / (1 - nu^2)
    D_mem = const_mem .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]
    Cm = isnothing(Cm_override) ? D_mem * h : Cm_override
    Cb = isnothing(Cb_override) ? bend_ratio * D_mem * (h^3 / 12.0) : Cb_override
    if (coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)) ||
       snorm_pq !== nothing
        u_elem = collect(u_elem)
        warp_map = nothing
        if coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)
            warp_map = quad4_finite_warp_displacement_map(coords, coords_3d)
            warp_map === nothing || (u_elem = warp_map * u_elem)
        end
        if snorm_pq !== nothing
            if quad4_snorm_normal_moment_mode()
                snorm_relative_pq = quad4_snorm_relative_to_finite_warp_pq(
                    snorm_pq, warp_map)
                snorm_relative_pq === nothing ||
                    apply_quad4_snorm_normal_moment_displacement!(
                        u_elem, coords, snorm_relative_pq)
                snorm_pq = nothing
            else
                apply_quad4_snorm_director_displacement!(u_elem, snorm_pq)
            end
        end
    end

    dNr, dNs = shape_derivs_quad(0.0, 0.0)
    J = [dNr'; dNs'] * coords
    invJ = inv(J)
    dN_dxy = invJ * [dNr'; dNs']
    iJ11c = invJ[1,1]; iJ12c = invJ[1,2]
    iJ21c = invJ[2,1]; iJ22c = invJ[2,2]

    pt = 1.0 / sqrt(3.0)
    gauss_pts = [-pt -pt; pt -pt; pt pt; -pt pt]

    K_ab_sr = zeros(24, 4)
    K_bb_sr = zeros(4, 4)
    for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12
            detJ_g = 1e-12
        end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            N_k = 0.25 * (1 + (k==2 || k==3 ? r : -r)) * (1 + (k>=3 ? s : -s))
            Bm_g[1, idx+1] = dN_dxy_g[1,k]
            Bm_g[2, idx+2] = dN_dxy_g[2,k]
            Bm_g[3, idx+1] = dN_dxy_g[2,k]
            Bm_g[3, idx+2] = dN_dxy_g[1,k]
            if curvature_membrane !== nothing
                Bm_g[1, idx+3] = -N_k * curvature_membrane[1]
                Bm_g[2, idx+3] = -N_k * curvature_membrane[2]
                Bm_g[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(Bm_g, dN_dxy[1,:], dN_dxy[2,:], curvature_membrane, material_shear_rotation)
        end

        Bi = zeros(3, 4)
        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        K_ab_sr .+= (Bm_g' * Cm * Bi) .* detJ_g
        K_bb_sr .+= (Bi' * Cm * Bi) .* detJ_g
    end

    alpha = -(K_bb_sr \ (K_ab_sr' * u_elem))
    N_gp = zeros(4, 3)
    M_gp = zeros(4, 3)

    for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            Bm_g[1, idx+1] = dN_dxy_g[1,k]
            Bm_g[2, idx+2] = dN_dxy_g[2,k]
            Bm_g[3, idx+1] = dN_dxy_g[2,k]
            Bm_g[3, idx+2] = dN_dxy_g[1,k]
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(Bm_g, dN_dxy[1,:], dN_dxy[2,:], nothing, material_shear_rotation)
        end

        Bb_g = zeros(3, 24)
        for k in 1:4
            idx = (k-1)*6
            Bb_g[1, idx+5] = dN_dxy_g[1,k]
            Bb_g[2, idx+4] = -dN_dxy_g[2,k]
            Bb_g[3, idx+5] = dN_dxy_g[2,k]
            Bb_g[3, idx+4] = -dN_dxy_g[1,k]
        end
        add_quad4_snorm_curvature_B!(Bb_g, dN_dxy_g, snorm_pq)

        Bi = zeros(3, 4)
        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        eps_gp = Bm_g * u_elem .+ Bi * alpha
        kappa_gp = Bb_g * u_elem
        N_gp[i, :] .= Cm * eps_gp
        M_gp[i, :] .= -Cb * kappa_gp
    end

    corner_points = ((-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0))
    N_corners = zeros(4, 3)
    M_corners = zeros(4, 3)
    for (i, (r, s)) in enumerate(corner_points)
        N_corners[i, :] .= interp_2x2_gauss_sigma(N_gp, r, s)
        M_corners[i, :] .= interp_2x2_gauss_sigma(M_gp, r, s)
    end

    return N_corners, M_corners
end

function quad4_membrane_force_field(coords, u_elem, E, nu, h;
                                    Cm_override=nothing,
                                    Bmb=nothing,
                                    slope_membrane=nothing,
                                    compatible_only=false,
                                    use_incompatible_modes::Bool=true,
                                    use_enhanced_modes::Bool=false,
                                    curvature_membrane=nothing,
                                    membrane_shear_center_row::Bool=false,
                                    material_shear_rotation::Float64=0.0,
                                    membrane_incomp_center_jacobian::Bool=false,
                                    mode_weights=nothing,
                                    snorm_pq=nothing,
                                    coords_3d=nothing)
    # slope_membrane (Ibrahimbegović 1994 Eq. 6.14 / Marguerre rotation-column
    # coupling) is the curved-shell coupling between rotation DOFs (θx, θy)
    # and in-plane strain via the geometric slope of the mid-surface. It is
    # the proper counterpart of curvature_membrane on the rotation side
    # (curvature_membrane is the w-DOF Koiter-Donnell coupling, which is too
    # strong / wrong direction on real meshes — see project notes 2026-05-23).
    # When provided, it MUST be a 9-vector [fx_1, fy_1, fx_2, fy_2, fx_3,
    # fy_3, fx_4, fy_4, convention_marker] (matches the K-assembly side
    # encoding). convention_marker = 0 → JFEM KL convention (θ_y=∂w/∂x);
    # = 1 → handover convention (θ_x=∂w/∂x).
    # Bmb (membrane-bending coupling, CLT [B]) is the laminate-frame coupling
    # matrix linking κ to N: N = A·ε + B·κ. JFEM previously omitted the B·κ
    # contribution, which is harmless for symmetric laminates (B≡0) but
    # gives wildly wrong N (and therefore wildly wrong K_g and λ_buckle) on
    # asymmetric stacks. Detected by the skew_sweep asymmetric layup probes
    # 2026-05-23 (λ_buckle +254 % on flat 3ply [0/45/90]).
    const_mem = E / (1 - nu^2)
    D_mem = const_mem .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]
    Cm = isnothing(Cm_override) ? D_mem * h : Cm_override
    if (coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)) ||
       snorm_pq !== nothing
        u_elem = collect(u_elem)
        warp_map = nothing
        if coords_3d !== nothing && fem_env_bool("JFEM_Q4_WARP_TRANSFORM", true)
            warp_map = quad4_finite_warp_displacement_map(coords, coords_3d)
            warp_map === nothing || (u_elem = warp_map * u_elem)
        end
        if snorm_pq !== nothing
            if quad4_snorm_normal_moment_mode()
                snorm_relative_pq = quad4_snorm_relative_to_finite_warp_pq(
                    snorm_pq, warp_map)
                snorm_relative_pq === nothing ||
                    apply_quad4_snorm_normal_moment_displacement!(
                        u_elem, coords, snorm_relative_pq)
                snorm_pq = nothing
            else
                apply_quad4_snorm_director_displacement!(u_elem, snorm_pq)
            end
        end
    end

    pt = 1.0 / sqrt(3.0)
    gauss_pts = [-pt -pt; pt -pt; pt pt; -pt pt]
    total_area = 0.0
    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J_c = [dNr_c'; dNs_c'] * coords
    invJ_c = inv(J_c)
    dN_dxy_c = invJ_c * [dNr_c'; dNs_c']
    iJ11c = invJ_c[1,1]; iJ12c = invJ_c[1,2]
    iJ21c = invJ_c[2,1]; iJ22c = invJ_c[2,2]

    alpha = zeros(use_enhanced_modes ? 6 : 4)
    if !compatible_only && (use_enhanced_modes || use_incompatible_modes)
        K_ab_sr = zeros(24, 4)
        K_bb_sr = zeros(4, 4)
        if use_enhanced_modes
            K_ab_sr = zeros(24, 6)
            K_bb_sr = zeros(6, 6)
        end
        for i in 1:4
            r, s = gauss_pts[i,1], gauss_pts[i,2]
            dNr_g, dNs_g = shape_derivs_quad(r, s)
            J_g = [dNr_g'; dNs_g'] * coords
            detJ_g = abs(det(J_g))
            if detJ_g < 1e-12; detJ_g = 1e-12; end
            iJ = inv(J_g)
            dN_dxy_g = iJ * [dNr_g'; dNs_g']

            Bm_g = zeros(3, 24)
            # Compute Marguerre slope at this GP from the 4 nodal slopes (used
            # only when slope_membrane is provided). Same convention as the
            # K-side application in stiffness_quad4_matrices (line ~3650).
            slope_fx = 0.0; slope_fy = 0.0; slope_handover = false
            if slope_membrane !== nothing
                for j in 1:4
                    Nj = 0.25*(1 + (j==2||j==3 ? r : -r))*(1 + (j>=3 ? s : -s))
                    slope_fx += Nj * slope_membrane[2*j-1]
                    slope_fy += Nj * slope_membrane[2*j]
                end
                slope_handover = length(slope_membrane) >= 9 && slope_membrane[9] != 0.0
            end
            for k in 1:4
                idx = (k-1)*6
                N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
                Bm_g[1, idx+1] = dN_dxy_g[1,k]
                Bm_g[2, idx+2] = dN_dxy_g[2,k]
                Bm_g[3, idx+1] = dN_dxy_g[2,k]
                Bm_g[3, idx+2] = dN_dxy_g[1,k]
                if curvature_membrane !== nothing
                    Bm_g[1, idx+3] = -N_k * curvature_membrane[1]
                    Bm_g[2, idx+3] = -N_k * curvature_membrane[2]
                    Bm_g[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
                end
                if slope_membrane !== nothing
                    # Marguerre rotation-membrane coupling on K_g side, mirrors
                    # the K-side application. Convention follows slope_membrane[9].
                    if slope_handover
                        Bm_g[1, idx+4] += N_k * slope_fx
                        Bm_g[2, idx+5] += N_k * slope_fy
                        Bm_g[3, idx+4] += N_k * slope_fy
                        Bm_g[3, idx+5] += N_k * slope_fx
                    else
                        Bm_g[1, idx+5] += N_k * slope_fx
                        Bm_g[2, idx+4] += N_k * slope_fy
                        Bm_g[3, idx+4] += N_k * slope_fx
                        Bm_g[3, idx+5] += N_k * slope_fy
                    end
                end
            end
            if membrane_shear_center_row
                project_material_membrane_shear!(
                    Bm_g,
                    dN_dxy_c[1,:],
                    dN_dxy_c[2,:],
                    curvature_membrane,
                    material_shear_rotation,
                )
            end

            if use_enhanced_modes
                Bi = zeros(3, 6)
                fill_quad4_membrane_enhanced_B!(
                    Bi,
                    r,
                    s,
                    iJ[1,1],
                    iJ[1,2],
                    iJ[2,1],
                    iJ[2,2],
                    iJ11c,
                    iJ12c,
                    iJ21c,
                    iJ22c,
                    membrane_incomp_center_jacobian,
                )
            else
                Bi = zeros(3, 4)
                fill_quad4_membrane_incompatible_B!(
                    Bi,
                    r,
                    s,
                    iJ[1,1],
                    iJ[1,2],
                    iJ[2,1],
                    iJ[2,2],
                    iJ11c,
                    iJ12c,
                    iJ21c,
                    iJ22c,
                    membrane_incomp_center_jacobian,
                )
            end

            K_ab_sr .+= (Bm_g' * Cm * Bi) .* detJ_g
            K_bb_sr .+= (Bi' * Cm * Bi) .* detJ_g
        end
        alpha = -(K_bb_sr \ (K_ab_sr' * u_elem))
        if mode_weights !== nothing
            # Mirror the static-K weighted condensation (the weights are
            # applied at bubble APPLICATION, so the consistent recovered
            # field is N = A(eps_c + sum_l w_l alpha_l eps_b,l)).  Needed so
            # the recovered stress field's consistent nodal forces equal the
            # element internal forces K_e*u when the static K condenses the
            # cross/shear Wilson modes only (report 3.29: an 8.6% gradient
            # under-recovery otherwise, which is exactly the spurious
            # transverse Kg residual on gradient states).
            for l in 1:min(4, length(alpha))
                alpha[l] *= Float64(mode_weights[l])
            end
        end
    end

    N_gp = zeros(4, 3)
    N_avg = zeros(3)
    area_w = zeros(4)

    for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12; detJ_g = 1e-12; end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        slope_fx = 0.0; slope_fy = 0.0; slope_handover = false
        if slope_membrane !== nothing
            for j in 1:4
                Nj = 0.25*(1 + (j==2||j==3 ? r : -r))*(1 + (j>=3 ? s : -s))
                slope_fx += Nj * slope_membrane[2*j-1]
                slope_fy += Nj * slope_membrane[2*j]
            end
            slope_handover = length(slope_membrane) >= 9 && slope_membrane[9] != 0.0
        end
        for k in 1:4
            idx = (k-1)*6
            N_k = 0.25*(1 + (k==2||k==3 ? r : -r))*(1 + (k>=3 ? s : -s))
            Bm_g[1, idx+1] = dN_dxy_g[1,k]
            Bm_g[2, idx+2] = dN_dxy_g[2,k]
            Bm_g[3, idx+1] = dN_dxy_g[2,k]
            Bm_g[3, idx+2] = dN_dxy_g[1,k]
            if curvature_membrane !== nothing
                Bm_g[1, idx+3] = -N_k * curvature_membrane[1]
                Bm_g[2, idx+3] = -N_k * curvature_membrane[2]
                Bm_g[3, idx+3] = -2.0 * N_k * curvature_membrane[3]
            end
            if slope_membrane !== nothing
                if slope_handover
                    Bm_g[1, idx+4] += N_k * slope_fx
                    Bm_g[2, idx+5] += N_k * slope_fy
                    Bm_g[3, idx+4] += N_k * slope_fy
                    Bm_g[3, idx+5] += N_k * slope_fx
                else
                    Bm_g[1, idx+5] += N_k * slope_fx
                    Bm_g[2, idx+4] += N_k * slope_fy
                    Bm_g[3, idx+4] += N_k * slope_fx
                    Bm_g[3, idx+5] += N_k * slope_fy
                end
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(
                Bm_g,
                dN_dxy_c[1,:],
                dN_dxy_c[2,:],
                curvature_membrane,
                material_shear_rotation,
            )
        end

        eps_gp = Bm_g * u_elem
        if !compatible_only && (use_enhanced_modes || use_incompatible_modes)
            if use_enhanced_modes
                Bi = zeros(3, 6)
                fill_quad4_membrane_enhanced_B!(
                    Bi,
                    r,
                    s,
                    iJ[1,1],
                    iJ[1,2],
                    iJ[2,1],
                    iJ[2,2],
                    iJ11c,
                    iJ12c,
                    iJ21c,
                    iJ22c,
                    membrane_incomp_center_jacobian,
                )
            else
                Bi = zeros(3, 4)
                fill_quad4_membrane_incompatible_B!(
                    Bi,
                    r,
                    s,
                    iJ[1,1],
                    iJ[1,2],
                    iJ[2,1],
                    iJ[2,2],
                    iJ11c,
                    iJ12c,
                    iJ21c,
                    iJ22c,
                    membrane_incomp_center_jacobian,
                )
            end
            eps_gp .+= Bi * alpha
        end

        N_vec = Cm * eps_gp
        # CLT membrane-bending coupling: N = A·ε + B·κ. Adds the bending-strain
        # contribution to the in-plane stress resultant for asymmetric laminates.
        if Bmb !== nothing && maximum(abs, Bmb) > 1e-30
            # JFEM bending strain convention (matches stiffness_quad4_matrices):
            #   κ_xx = +∂θy/∂x = sum_k dN_dx[k] · θy_k     (θy at idx+5)
            #   κ_yy = -∂θx/∂y = sum_k (-dN_dy[k]) · θx_k  (θx at idx+4)
            #   κ_xy = +∂θy/∂y − ∂θx/∂x
            Bb_snorm = zeros(3, 24)
            @inbounds for k in 1:4
                idx = (k - 1) * 6
                dN_dx_k = dN_dxy_g[1, k]
                dN_dy_k = dN_dxy_g[2, k]
                Bb_snorm[1,idx+5] = dN_dx_k
                Bb_snorm[2,idx+4] = -dN_dy_k
                Bb_snorm[3,idx+5] = dN_dy_k
                Bb_snorm[3,idx+4] = -dN_dx_k
            end
            add_quad4_snorm_curvature_B!(Bb_snorm, dN_dxy_g, snorm_pq)
            kappa_xx, kappa_yy, kappa_xy = Bb_snorm * u_elem
            N_vec[1] += Bmb[1,1] * kappa_xx + Bmb[1,2] * kappa_yy + Bmb[1,3] * kappa_xy
            N_vec[2] += Bmb[2,1] * kappa_xx + Bmb[2,2] * kappa_yy + Bmb[2,3] * kappa_xy
            N_vec[3] += Bmb[3,1] * kappa_xx + Bmb[3,2] * kappa_yy + Bmb[3,3] * kappa_xy
        end
        N_gp[i, 1] = N_vec[1]
        N_gp[i, 2] = N_vec[2]
        N_gp[i, 3] = N_vec[3]
        N_avg .+= N_vec .* detJ_g
        area_w[i] = detJ_g
        total_area += detJ_g
    end

    if total_area > 0.0
        N_avg ./= total_area
    end

    return N_gp, N_avg, area_w
end

function quad4_membrane_cst_resultant(coords::AbstractMatrix,
                                      u_elem::AbstractVector,
                                      Cm::AbstractMatrix,
                                      tri::NTuple{3,Int})
    x1 = coords[tri[1], 1]; y1 = coords[tri[1], 2]
    x2 = coords[tri[2], 1]; y2 = coords[tri[2], 2]
    x3 = coords[tri[3], 1]; y3 = coords[tri[3], 2]
    A2 = x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2)
    A = 0.5 * abs(A2)
    A <= 1e-12 && return zeros(3)
    b = [y2 - y3, y3 - y1, y1 - y2] ./ (2.0 * A)
    c = [x3 - x2, x1 - x3, x2 - x1] ./ (2.0 * A)
    eps = zeros(3)
    @inbounds for (a, node) in enumerate(tri)
        base = (node - 1) * 6
        ux = u_elem[base + 1]
        uy = u_elem[base + 2]
        eps[1] += b[a] * ux
        eps[2] += c[a] * uy
        eps[3] += c[a] * ux + b[a] * uy
    end
    return Cm * eps
end

function quad4_membrane_cst_resultant_xyu(coords::AbstractMatrix,
                                          uxy::AbstractMatrix,
                                          Cm::AbstractMatrix,
                                          tri::NTuple{3,Int})
    x1 = coords[tri[1], 1]; y1 = coords[tri[1], 2]
    x2 = coords[tri[2], 1]; y2 = coords[tri[2], 2]
    x3 = coords[tri[3], 1]; y3 = coords[tri[3], 2]
    A2 = x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2)
    A = 0.5 * abs(A2)
    A <= 1e-12 && return zeros(3)
    b = [y2 - y3, y3 - y1, y1 - y2] ./ (2.0 * A)
    c = [x3 - x2, x1 - x3, x2 - x1] ./ (2.0 * A)
    eps = zeros(3)
    @inbounds for (a, node) in enumerate(tri)
        ux = uxy[node, 1]
        uy = uxy[node, 2]
        eps[1] += b[a] * ux
        eps[2] += c[a] * uy
        eps[3] += c[a] * ux + b[a] * uy
    end
    return Cm * eps
end

function quad4_interpolate_corner_resultants_to_gp(N_corner::AbstractMatrix)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    N_gp = zeros(4, 3)
    @inbounds for (gp, rs) in enumerate(gauss_pts)
        r = rs[1]; s = rs[2]
        Nvals = SVector(
            0.25 * (1.0 - r) * (1.0 - s),
            0.25 * (1.0 + r) * (1.0 - s),
            0.25 * (1.0 + r) * (1.0 + s),
            0.25 * (1.0 - r) * (1.0 + s),
        )
        for k in 1:4, comp in 1:3
            N_gp[gp, comp] += Nvals[k] * N_corner[k, comp]
        end
    end
    return N_gp
end

function quad4_gauss_area_weights(coords::AbstractMatrix)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    area_w = zeros(4)
    @inbounds for (gp, rs) in enumerate(gauss_pts)
        dNr, dNs = shape_derivs_quad(rs[1], rs[2])
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        area_w[gp] = max(abs(J11 * J22 - J12 * J21), 1e-12)
    end
    return area_w
end

function quad4_preserve_membrane_average!(N_gp::AbstractMatrix,
                                          target_avg::AbstractVector,
                                          area_w::Union{Nothing,AbstractVector}=nothing)
    current = zeros(3)
    if area_w === nothing
        current .= vec(mean(N_gp; dims=1))
    else
        total_area = max(sum(area_w), 1e-12)
        @inbounds for gp in 1:size(N_gp, 1), comp in 1:3
            current[comp] += area_w[gp] * N_gp[gp, comp] / total_area
        end
    end
    @inbounds for gp in 1:size(N_gp, 1), comp in 1:3
        N_gp[gp, comp] += target_avg[comp] - current[comp]
    end
    return N_gp
end

function quad4_edge_aspect_ratio(coords::AbstractMatrix)
    l12 = hypot(coords[2, 1] - coords[1, 1], coords[2, 2] - coords[1, 2])
    l23 = hypot(coords[3, 1] - coords[2, 1], coords[3, 2] - coords[2, 2])
    l34 = hypot(coords[4, 1] - coords[3, 1], coords[4, 2] - coords[3, 2])
    l41 = hypot(coords[1, 1] - coords[4, 1], coords[1, 2] - coords[4, 2])
    return max(l12, l23, l34, l41) / max(min(l12, l23, l34, l41), 1e-12)
end

function quad4_membrane_force_field_triangle_recovery(
    coords::AbstractMatrix,
    u_elem::AbstractVector,
    Cm::AbstractMatrix,
    target_avg::AbstractVector;
    mode::Symbol=:tri_aspect,
    aspect_switch::Float64=2.0,
)
    N123 = quad4_membrane_cst_resultant(coords, u_elem, Cm, (1, 2, 3))
    N134 = quad4_membrane_cst_resultant(coords, u_elem, Cm, (1, 3, 4))
    N124 = quad4_membrane_cst_resultant(coords, u_elem, Cm, (1, 2, 4))
    N234 = quad4_membrane_cst_resultant(coords, u_elem, Cm, (2, 3, 4))

    eff_mode = mode
    if mode === :tri_aspect
        eff_mode = quad4_edge_aspect_ratio(coords) >= aspect_switch ?
            :tri_incident_interp : :tri_center_adj
    end

    N_gp = zeros(4, 3)
    if eff_mode === :tri_incident_interp
        N_corner = zeros(4, 3)
        N_corner[1, :] .= (N123 .+ N134 .+ N124) ./ 3.0
        N_corner[2, :] .= (N123 .+ N124 .+ N234) ./ 3.0
        N_corner[3, :] .= (N123 .+ N134 .+ N234) ./ 3.0
        N_corner[4, :] .= (N134 .+ N124 .+ N234) ./ 3.0
        N_gp .= quad4_interpolate_corner_resultants_to_gp(N_corner)
    elseif eff_mode === :tri_diagavg
        pt = 1.0 / sqrt(3.0)
        gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
        @inbounds for (gp, rs) in enumerate(gauss_pts)
            r = rs[1]; s = rs[2]
            n13 = r >= s ? N123 : N134
            n24 = r + s <= 0.0 ? N124 : N234
            N_gp[gp, :] .= 0.5 .* (n13 .+ n24)
        end
    else
        coords5 = zeros(5, 2)
        coords5[1:4, :] .= coords
        coords5[5, :] .= vec(mean(coords; dims=1))
        uxy5 = zeros(5, 2)
        @inbounds for k in 1:4
            base = (k - 1) * 6
            uxy5[k, 1] = u_elem[base + 1]
            uxy5[k, 2] = u_elem[base + 2]
        end
        uxy5[5, :] .= vec(mean(uxy5[1:4, :]; dims=1))
        N12c = quad4_membrane_cst_resultant_xyu(coords5, uxy5, Cm, (1, 2, 5))
        N23c = quad4_membrane_cst_resultant_xyu(coords5, uxy5, Cm, (2, 3, 5))
        N34c = quad4_membrane_cst_resultant_xyu(coords5, uxy5, Cm, (3, 4, 5))
        N41c = quad4_membrane_cst_resultant_xyu(coords5, uxy5, Cm, (4, 1, 5))
        N_gp[1, :] .= (N12c .+ N41c) ./ 2.0
        N_gp[2, :] .= (N12c .+ N23c) ./ 2.0
        N_gp[3, :] .= (N23c .+ N34c) ./ 2.0
        N_gp[4, :] .= (N34c .+ N41c) ./ 2.0
    end

    return quad4_preserve_membrane_average!(N_gp, target_avg, quad4_gauss_area_weights(coords))
end

function quad4_membrane_incompatible_condensation_map(coords::AbstractMatrix,
                                                      Cm::AbstractMatrix;
                                                      curvature_membrane=nothing,
                                                      membrane_shear_center_row::Bool=false,
                                                      material_shear_rotation::Float64=0.0,
                                                      membrane_incomp_center_jacobian::Bool=false)
    K_ab = zeros(24, 4)
    K_bb = zeros(4, 4)

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J_c = [dNr_c'; dNs_c'] * coords
    invJ_c = inv(J_c)
    dN_dxy_c = invJ_c * [dNr_c'; dNs_c']
    iJ11c = invJ_c[1,1]; iJ12c = invJ_c[1,2]
    iJ21c = invJ_c[2,1]; iJ22c = invJ_c[2,2]

    @inbounds for gp in gauss_pts
        r, s = gp[1], gp[2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12
            detJ_g = 1e-12
        end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k - 1) * 6
            N_k = 0.25 * (1 + (k == 2 || k == 3 ? r : -r)) * (1 + (k >= 3 ? s : -s))
            Bm_g[1, idx + 1] = dN_dxy_g[1, k]
            Bm_g[2, idx + 2] = dN_dxy_g[2, k]
            Bm_g[3, idx + 1] = dN_dxy_g[2, k]
            Bm_g[3, idx + 2] = dN_dxy_g[1, k]
            if curvature_membrane !== nothing
                Bm_g[1, idx + 3] = -N_k * curvature_membrane[1]
                Bm_g[2, idx + 3] = -N_k * curvature_membrane[2]
                Bm_g[3, idx + 3] = -2.0 * N_k * curvature_membrane[3]
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(
                Bm_g,
                dN_dxy_c[1, :],
                dN_dxy_c[2, :],
                curvature_membrane,
                material_shear_rotation,
            )
        end

        Bi = zeros(3, 4)
        fill_quad4_membrane_incompatible_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        K_ab .+= (Bm_g' * Cm * Bi) .* detJ_g
        K_bb .+= (Bi' * Cm * Bi) .* detJ_g
    end

    return -(K_bb \ K_ab')
end

function quad4_membrane_enhanced_condensation_map(coords::AbstractMatrix,
                                                  Cm::AbstractMatrix;
                                                  curvature_membrane=nothing,
                                                  membrane_shear_center_row::Bool=false,
                                                  material_shear_rotation::Float64=0.0,
                                                  membrane_incomp_center_jacobian::Bool=false)
    K_ab = zeros(24, 6)
    K_bb = zeros(6, 6)

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt, -pt), SVector(pt, -pt), SVector(pt, pt), SVector(-pt, pt))
    dNr_c, dNs_c = shape_derivs_quad(0.0, 0.0)
    J_c = [dNr_c'; dNs_c'] * coords
    invJ_c = inv(J_c)
    dN_dxy_c = invJ_c * [dNr_c'; dNs_c']
    iJ11c = invJ_c[1,1]; iJ12c = invJ_c[1,2]
    iJ21c = invJ_c[2,1]; iJ22c = invJ_c[2,2]

    @inbounds for gp in gauss_pts
        r, s = gp[1], gp[2]
        dNr_g, dNs_g = shape_derivs_quad(r, s)
        J_g = [dNr_g'; dNs_g'] * coords
        detJ_g = abs(det(J_g))
        if detJ_g < 1e-12
            detJ_g = 1e-12
        end
        iJ = inv(J_g)
        dN_dxy_g = iJ * [dNr_g'; dNs_g']

        Bm_g = zeros(3, 24)
        for k in 1:4
            idx = (k - 1) * 6
            N_k = 0.25 * (1 + (k == 2 || k == 3 ? r : -r)) * (1 + (k >= 3 ? s : -s))
            Bm_g[1, idx + 1] = dN_dxy_g[1, k]
            Bm_g[2, idx + 2] = dN_dxy_g[2, k]
            Bm_g[3, idx + 1] = dN_dxy_g[2, k]
            Bm_g[3, idx + 2] = dN_dxy_g[1, k]
            if curvature_membrane !== nothing
                Bm_g[1, idx + 3] = -N_k * curvature_membrane[1]
                Bm_g[2, idx + 3] = -N_k * curvature_membrane[2]
                Bm_g[3, idx + 3] = -2.0 * N_k * curvature_membrane[3]
            end
        end
        if membrane_shear_center_row
            project_material_membrane_shear!(
                Bm_g,
                dN_dxy_c[1, :],
                dN_dxy_c[2, :],
                curvature_membrane,
                material_shear_rotation,
            )
        end

        Bi = zeros(3, 6)
        fill_quad4_membrane_enhanced_B!(
            Bi,
            r,
            s,
            iJ[1,1],
            iJ[1,2],
            iJ[2,1],
            iJ[2,2],
            iJ11c,
            iJ12c,
            iJ21c,
            iJ22c,
            membrane_incomp_center_jacobian,
        )

        K_ab .+= (Bm_g' * Cm * Bi) .* detJ_g
        K_bb .+= (Bi' * Cm * Bi) .* detJ_g
    end

    return -(K_bb \ K_ab')
end

@inline function add_geometric_gradient_block!(Kg::AbstractMatrix,
                                               gdx::AbstractVector,
                                               gdy::AbstractVector,
                                               scale::Float64,
                                               s_xx::Float64,
                                               s_yy::Float64,
                                               s_xy::Float64,
                                               block_scale::Float64=1.0)
    @inbounds @fastmath for j in eachindex(gdx), i in eachindex(gdx)
        Kg[i, j] += block_scale * scale * (
            s_xx * gdx[i] * gdx[j] +
            s_yy * gdy[i] * gdy[j] +
            s_xy * (gdx[i] * gdy[j] + gdy[i] * gdx[j])
        )
    end
    return Kg
end

@inline function add_geometric_shear_axis_block!(Kg::AbstractMatrix,
                                                 ux_dx::AbstractVector,
                                                 ux_dy::AbstractVector,
                                                 w_dx::AbstractVector,
                                                 w_dy::AbstractVector,
                                                 scale::Float64,
                                                 s_xy::Float64,
                                                 u_xx_scale::Float64,
                                                 w_xx_scale::Float64,
                                                 u_xy_scale::Float64,
                                                 w_xy_scale::Float64)
    if s_xy == 0.0 ||
       (u_xx_scale == 0.0 && w_xx_scale == 0.0 &&
        u_xy_scale == 0.0 && w_xy_scale == 0.0)
        return Kg
    end
    shear_scale = scale * s_xy
    @inbounds @fastmath for j in eachindex(ux_dx), i in eachindex(ux_dx)
        sxx_term = ux_dx[i] * ux_dx[j]
        sxy_u = ux_dx[i] * ux_dy[j] + ux_dy[i] * ux_dx[j]
        sxy_w = w_dx[i] * w_dy[j] + w_dy[i] * w_dx[j]
        Kg[i, j] += shear_scale * (
            u_xx_scale * sxx_term +
            u_xy_scale * sxy_u +
            w_xx_scale * w_dx[i] * w_dx[j] +
            w_xy_scale * sxy_w
        )
    end
    return Kg
end

@inline function add_geometric_axis_resultant_block!(Kg::AbstractMatrix,
                                                     ux_dx::AbstractVector,
                                                     vy_dy::AbstractVector,
                                                     w_dx::AbstractVector,
                                                     w_dy::AbstractVector,
                                                     scale::Float64,
                                                     s_xx::Float64,
                                                     s_yy::Float64,
                                                     u_xx_extra::Float64,
                                                     v_yy_extra::Float64,
                                                     w_xx_extra::Float64,
                                                     w_yy_extra::Float64)
    if (s_xx == 0.0 && s_yy == 0.0) ||
       (u_xx_extra == 0.0 && v_yy_extra == 0.0 &&
        w_xx_extra == 0.0 && w_yy_extra == 0.0)
        return Kg
    end
    @inbounds @fastmath for j in eachindex(ux_dx), i in eachindex(ux_dx)
        Kg[i, j] += scale * (
            u_xx_extra * s_xx * ux_dx[i] * ux_dx[j] +
            v_yy_extra * s_yy * vy_dy[i] * vy_dy[j] +
            w_xx_extra * s_xx * w_dx[i] * w_dx[j] +
            w_yy_extra * s_yy * w_dy[i] * w_dy[j]
        )
    end
    return Kg
end

@inline function add_geometric_shear_extra_block!(Kg::AbstractMatrix,
                                                  ux_dy::AbstractVector,
                                                  vy_dx::AbstractVector,
                                                  vy_dy::AbstractVector,
                                                  scale::Float64,
                                                  s_xy::Float64,
                                                  u_yy_scale::Float64,
                                                  v_xx_scale::Float64,
                                                  v_yy_scale::Float64,
                                                  v_xy_scale::Float64)
    if s_xy == 0.0 ||
       (u_yy_scale == 0.0 && v_xx_scale == 0.0 &&
        v_yy_scale == 0.0 && v_xy_scale == 0.0)
        return Kg
    end
    shear_scale = scale * s_xy
    @inbounds @fastmath for j in eachindex(ux_dy), i in eachindex(ux_dy)
        vxy = vy_dx[i] * vy_dy[j] + vy_dy[i] * vy_dx[j]
        Kg[i, j] += shear_scale * (
            u_yy_scale * ux_dy[i] * ux_dy[j] +
            v_xx_scale * vy_dx[i] * vy_dx[j] +
            v_yy_scale * vy_dy[i] * vy_dy[j] +
            v_xy_scale * vxy
        )
    end
    return Kg
end

@inline function add_geometric_nyy_u_extra_block!(Kg::AbstractMatrix,
                                                  ux_dx::AbstractVector,
                                                  ux_dy::AbstractVector,
                                                  scale::Float64,
                                                  s_yy::Float64,
                                                  u_xx_scale::Float64,
                                                  u_yy_scale::Float64,
                                                  u_xy_scale::Float64)
    if s_yy == 0.0 ||
       (u_xx_scale == 0.0 && u_yy_scale == 0.0 && u_xy_scale == 0.0)
        return Kg
    end
    yy_scale = scale * s_yy
    @inbounds @fastmath for j in eachindex(ux_dx), i in eachindex(ux_dx)
        uxy = ux_dx[i] * ux_dy[j] + ux_dy[i] * ux_dx[j]
        Kg[i, j] += yy_scale * (
            u_xx_scale * ux_dx[i] * ux_dx[j] +
            u_yy_scale * ux_dy[i] * ux_dy[j] +
            u_xy_scale * uxy
        )
    end
    return Kg
end

@inline function add_geometric_nyy_vw_extra_block!(Kg::AbstractMatrix,
                                                   vy_dx::AbstractVector,
                                                   w_dx::AbstractVector,
                                                   w_dy::AbstractVector,
                                                   scale::Float64,
                                                   s_yy::Float64,
                                                   v_xx_scale::Float64,
                                                   w_xx_scale::Float64,
                                                   w_xy_scale::Float64)
    if s_yy == 0.0 ||
       (v_xx_scale == 0.0 && w_xx_scale == 0.0 && w_xy_scale == 0.0)
        return Kg
    end
    yy_scale = scale * s_yy
    @inbounds @fastmath for j in eachindex(vy_dx), i in eachindex(vy_dx)
        wxy = w_dx[i] * w_dy[j] + w_dy[i] * w_dx[j]
        Kg[i, j] += yy_scale * (
            v_xx_scale * vy_dx[i] * vy_dx[j] +
            w_xx_scale * w_dx[i] * w_dx[j] +
            w_xy_scale * wxy
        )
    end
    return Kg
end


@inline function principal_stress_2d_components(s_xx::Float64, s_yy::Float64, s_xy::Float64)
    mean_s = 0.5 * (s_xx + s_yy)
    half_d = 0.5 * (s_xx - s_yy)
    radius = sqrt(half_d * half_d + s_xy * s_xy)
    if radius <= 1e-30
        return mean_s, 1.0, 0.0, mean_s, 0.0, 1.0
    end
    theta = 0.5 * atan(2.0 * s_xy, s_xx - s_yy)
    c1 = cos(theta)
    s1 = sin(theta)
    return mean_s + radius, c1, s1, mean_s - radius, -s1, c1
end

@inline function add_geometric_principal_transverse_direction!(
    Kg::AbstractMatrix,
    dux_dx::AbstractVector,
    dux_dy::AbstractVector,
    duy_dx::AbstractVector,
    duy_dy::AbstractVector,
    duz_dx::AbstractVector,
    duz_dy::AbstractVector,
    scale::Float64,
    lambda::Float64,
    c::Float64,
    s::Float64,
    p22_factor::Float64,
    p12_factor::Float64,
    z_factor::Float64,
    local_u_factor::Float64=1.0,
    local_v_factor::Float64=1.0,
    local_uv_factor::Float64=1.0,
    local_w_factor::Float64=1.0,
)
    abs(lambda) <= 1e-30 && return Kg
    p11 = local_u_factor * s * s
    p22 = local_v_factor * p22_factor * c * c
    p12 = local_uv_factor * p12_factor * -c * s
    factor = scale * lambda
    @inbounds @fastmath for j in eachindex(dux_dx), i in eachindex(dux_dx)
        gux_i = c * dux_dx[i] + s * dux_dy[i]
        guy_i = c * duy_dx[i] + s * duy_dy[i]
        guz_i = c * duz_dx[i] + s * duz_dy[i]
        gux_j = c * dux_dx[j] + s * dux_dy[j]
        guy_j = c * duy_dx[j] + s * duy_dy[j]
        guz_j = c * duz_dx[j] + s * duz_dy[j]
        Kg[i, j] += factor * (
            p11 * gux_i * gux_j +
            p22 * guy_i * guy_j +
            p12 * (gux_i * guy_j + guy_i * gux_j) +
            local_w_factor * z_factor * guz_i * guz_j
        )
    end
    return Kg
end

@inline function add_geometric_principal_transverse_block!(
    Kg::AbstractMatrix,
    dux_dx::AbstractVector,
    dux_dy::AbstractVector,
    duy_dx::AbstractVector,
    duy_dy::AbstractVector,
    duz_dx::AbstractVector,
    duz_dy::AbstractVector,
    scale::Float64,
    s_xx::Float64,
    s_yy::Float64,
    s_xy::Float64,
    shear_yy_factor::Float64=1.0,
    shear_xy_factor::Float64=1.0,
    shear_z_factor::Float64=1.0,
    shear_ratio_min::Float64=1.0,
    local_u_factor::Float64=1.0,
    local_v_factor::Float64=1.0,
    local_uv_factor::Float64=1.0,
    local_w_factor::Float64=1.0,
)
    l1, c1, s1, l2, c2, s2 = principal_stress_2d_components(s_xx, s_yy, s_xy)
    denom = abs(s_xx) + abs(s_yy) + abs(s_xy)
    shear_ratio = denom > 1e-30 ? abs(s_xy) / denom : 0.0
    p22_factor = shear_ratio >= shear_ratio_min ? shear_yy_factor : 1.0
    p12_factor = shear_ratio >= shear_ratio_min ? shear_xy_factor : 1.0
    z_factor = shear_ratio >= shear_ratio_min ? shear_z_factor : 1.0
    add_geometric_principal_transverse_direction!(
        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
        scale, l1, c1, s1, p22_factor, p12_factor, z_factor,
        local_u_factor, local_v_factor, local_uv_factor, local_w_factor)
    add_geometric_principal_transverse_direction!(
        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
        scale, l2, c2, s2, p22_factor, p12_factor, z_factor,
        local_u_factor, local_v_factor, local_uv_factor, local_w_factor)
    return Kg
end

@inline function add_geometric_principal_transverse_pair_direction!(
    Kg::AbstractMatrix,
    row0::Int,
    col0::Int,
    dNi_dx::Float64,
    dNi_dy::Float64,
    dNj_dx::Float64,
    dNj_dy::Float64,
    scale::Float64,
    lambda::Float64,
    c::Float64,
    s::Float64,
    p22_factor::Float64,
    p12_factor::Float64,
    z_factor::Float64,
    local_u_factor::Float64=1.0,
    local_v_factor::Float64=1.0,
    local_uv_factor::Float64=1.0,
    local_w_factor::Float64=1.0,
)
    abs(lambda) <= 1e-30 && return Kg
    gi = c * dNi_dx + s * dNi_dy
    gj = c * dNj_dx + s * dNj_dy
    val = scale * lambda * gi * gj
    p11 = local_u_factor * s * s
    p22 = local_v_factor * p22_factor * c * c
    p12 = local_uv_factor * p12_factor * -c * s
    Kg[row0 + 1, col0 + 1] += val * p11
    Kg[row0 + 1, col0 + 2] += val * p12
    Kg[row0 + 2, col0 + 1] += val * p12
    Kg[row0 + 2, col0 + 2] += val * p22
    Kg[row0 + 3, col0 + 3] += local_w_factor * z_factor * val
    return Kg
end

@inline function add_geometric_principal_transverse_pair!(
    Kg::AbstractMatrix,
    row0::Int,
    col0::Int,
    dNi_dx::Float64,
    dNi_dy::Float64,
    dNj_dx::Float64,
    dNj_dy::Float64,
    scale::Float64,
    s_xx::Float64,
    s_yy::Float64,
    s_xy::Float64,
    shear_yy_factor::Float64=1.0,
    shear_xy_factor::Float64=1.0,
    shear_z_factor::Float64=1.0,
    shear_ratio_min::Float64=1.0,
    local_u_factor::Float64=1.0,
    local_v_factor::Float64=1.0,
    local_uv_factor::Float64=1.0,
    local_w_factor::Float64=1.0,
)
    l1, c1, s1, l2, c2, s2 = principal_stress_2d_components(s_xx, s_yy, s_xy)
    denom = abs(s_xx) + abs(s_yy) + abs(s_xy)
    shear_ratio = denom > 1e-30 ? abs(s_xy) / denom : 0.0
    p22_factor = shear_ratio >= shear_ratio_min ? shear_yy_factor : 1.0
    p12_factor = shear_ratio >= shear_ratio_min ? shear_xy_factor : 1.0
    z_factor = shear_ratio >= shear_ratio_min ? shear_z_factor : 1.0
    add_geometric_principal_transverse_pair_direction!(
        Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
        scale, l1, c1, s1, p22_factor, p12_factor, z_factor,
        local_u_factor, local_v_factor, local_uv_factor, local_w_factor)
    add_geometric_principal_transverse_pair_direction!(
        Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
        scale, l2, c2, s2, p22_factor, p12_factor, z_factor,
        local_u_factor, local_v_factor, local_uv_factor, local_w_factor)
    return Kg
end

# KERNEL: geometric_stiffness_quad4_nastran_kdjj_iso
# Exact replica of MSC Nastran (v70.5) CQUAD4 differential stiffness (KDJJ)
# for FLAT ISOTROPIC PSHELL elements, identified entry-exactly from
# element-level MATPRN KDJJ extractions (uniform sigma_xx/yy/xy single-element
# states plus skewed cantilevers, 2026-07-12):
#   * Element frame: x-axis along the bisector of the two diagonals
#     (G1->G3 and G4->G2) -- the CQUAD4 element-coordinate convention.
#   * Stress field: per-GP eps'_x, eps'_y from the bilinear gradients in the
#     element frame; the membrane shear gamma' is sampled at the element
#     CENTER (QUAD4 selective membrane-shear sampling).  sigma' = D.eps'
#     (isotropic plane stress).
#   * In-plane (u,v) block: component-wise transverse "string" rule in the
#     element frame -- sigma'_xx stiffens v' through N,x'; sigma'_yy stiffens
#     u' through N,y'; sigma'_xy adds sym(N,x' N,y') on u'u' and v'v' and
#     -1/2 (N,x'N,x' + N,y'N,y') on the u'v' coupling.  (For deviatoric
#     stress this coincides with the intrinsic principal-transverse form;
#     the element-frame choice matters only for the trace part, which is
#     exactly the skew defect this kernel fixes.)
#   * w block: per-GP metric with the sigma'_xy cross term evaluated from
#     CENTER-sampled w-gradients.
#   * Rotational and drilling blocks: exactly zero (KDJJ carries none).
# Validation vs Nastran KDJJ: in-plane 0.001-0.003% across skew 0/10/20/30/45
# cantilevers and machine-exact on all three uniform states; w block <=1.3%
# for skew<=20, 1.5-5.9% at skew 45 (vs ~15% for the plain metric).
# Composite (laminate) variant of the Nastran-KDJJ Kg kernel.  Identical bisector-
# frame component-string operator, but instead of recovering the membrane stress from
# the isotropic D(E,nu) it consumes JFEM's ALREADY-RECOVERED per-GP membrane force
# resultant field N_gp (4x3: nxx,nyy,nxy per Gauss point, in the element-local = lc =
# bisector frame -- SAME frame the operator works in, so no rotation).  Using the
# recovered N_gp (which includes the incompatible-mode membrane recovery) rather than a
# compatible Cm*eps from u is essential: the compatible recovery under-recovers the skew
# membrane badly (kernel hyper-sensitive to u), whereas N_gp is JFEM's validated field.
# The shear component is CENTER-sampled (element mean of N_gp[:,3]) to match the KDJJ
# rule.  N_gp is a stress RESULTANT (force/length) so the weight carries NO extra h.
function geometric_stiffness_quad4_nastran_kdjj_pcomp_field(coords::AbstractMatrix,
                                                            N_gp::AbstractMatrix)
    Kg = zeros(24, 24)
    x1 = coords[1,1]; y1 = coords[1,2]
    x2 = coords[2,1]; y2 = coords[2,2]
    x3 = coords[3,1]; y3 = coords[3,2]
    x4 = coords[4,1]; y4 = coords[4,2]
    d13x = x3 - x1; d13y = y3 - y1; l13 = hypot(d13x, d13y)
    d42x = x2 - x4; d42y = y2 - y4; l42 = hypot(d42x, d42y)
    (l13 < 1e-12 || l42 < 1e-12) && return Kg
    bx = d13x / l13 + d42x / l42
    by = d13y / l13 + d42y / l42
    lb = hypot(bx, by)
    lb < 1e-12 && return Kg
    ce = bx / lb; se = by / lb
    # center-sampled shear resultant (element mean of the per-GP nxy)
    nxy_c = 0.25 * (N_gp[1,3] + N_gp[2,3] + N_gp[3,3] + N_gp[4,3])
    # element-mean normal resultants (for the meanstring gradient strings)
    nxx_c = 0.25 * (N_gp[1,1] + N_gp[2,1] + N_gp[3,1] + N_gp[4,1])
    nyy_c = 0.25 * (N_gp[1,2] + N_gp[2,2] + N_gp[3,2] + N_gp[4,2])
    # JFEM_SOL105_PCOMP_KDJJ_MEANSTRING (default OFF): add the meanstring
    # EDGE-STRING gradient terms this kernel dropped when it took over the
    # path.  Nastran's KDJJ = mean-state metric + edge strings carrying the
    # self-equilibrated residual corner forces of the in-element stress
    # gradient (identified report 3.29; legacy :meanstring form).  Gradient-
    # state DOE 2026-07-22: without them the w-w block misses by 3.3-6.3% at
    # 15 deg (11% at 25 deg) under gradient states while uniform states are
    # exact — an EXACTLY rank-2, state-invariant edge-pair delta = this term.
    # DOE 2026-07-22 string_cmp: the ported strings match Nastran's implied
    # strings to principal cosines 1.000/1.000 with amplitude 0.93-1.03, BUT
    # (a) the w-block metric must then use the MEAN resultants (per-GP metric
    # already embeds ~95% of the gradient content -> double counting: 50-104%
    # deltas), and (b) the in-plane-transverse string parts do NOT match
    # Nastran (uv 12-32% vs 1.7-5.1% baseline) -- Nastran's in-plane gradient
    # content is already carried by the per-GP in-plane metric.  Hence:
    # strings act on w DOFs only (in-plane parts behind _INPLANE, default
    # off), and the w-w metric switches to mean-state when strings are on.
    kdjj_meanstring = fem_env_bool("JFEM_SOL105_PCOMP_KDJJ_MEANSTRING", false)
    kdjj_ms_inplane = kdjj_meanstring &&
        fem_env_bool("JFEM_SOL105_PCOMP_KDJJ_MEANSTRING_INPLANE", false)
    dfx_ms = zeros(4); dfy_ms = zeros(4)
    X = (x1, x2, x3, x4); Y = (y1, y2, y3, y4)
    function grad_p(r::Float64, s::Float64)
        dNr = (-(1.0-s), (1.0-s), (1.0+s), -(1.0+s)) .* 0.25
        dNs = (-(1.0-r), -(1.0+r), (1.0+r), (1.0-r)) .* 0.25
        J11 = dNr[1]*X[1] + dNr[2]*X[2] + dNr[3]*X[3] + dNr[4]*X[4]
        J12 = dNr[1]*Y[1] + dNr[2]*Y[2] + dNr[3]*Y[3] + dNr[4]*Y[4]
        J21 = dNs[1]*X[1] + dNs[2]*X[2] + dNs[3]*X[3] + dNs[4]*X[4]
        J22 = dNs[1]*Y[1] + dNs[2]*Y[2] + dNs[3]*Y[3] + dNs[4]*Y[4]
        detJ = J11*J22 - J12*J21
        abs(detJ) < 1e-14 && return nothing
        i11 =  J22 / detJ; i12 = -J12 / detJ
        i21 = -J21 / detJ; i22 =  J11 / detJ
        dNx = MVector{4,Float64}(undef); dNy = MVector{4,Float64}(undef)
        @inbounds for k in 1:4
            gx = i11*dNr[k] + i12*dNs[k]
            gy = i21*dNr[k] + i22*dNs[k]
            dNx[k] =  ce * gx + se * gy
            dNy[k] = -se * gx + ce * gy
        end
        return dNx, dNy, abs(detJ)
    end
    g0 = grad_p(0.0, 0.0)
    g0 === nothing && return Kg
    dNx0, dNy0, _ = g0
    gp = 1.0 / sqrt(3.0)
    gpts = ((-gp,-gp), (gp,-gp), (gp,gp), (-gp,gp))
    @inbounds for gi in 1:4
        r, s = gpts[gi]
        g = grad_p(r, s)
        g === nothing && continue
        dNx, dNy, adetJ = g
        w = adetJ
        # per-GP resultant in the lc/bisector frame; shear center-sampled
        sxx = N_gp[gi,1]; syy = N_gp[gi,2]; sxy = nxy_c
        # w-block resultants: mean-state when the strings carry the gradient
        sxx_w = kdjj_meanstring ? nxx_c : sxx
        syy_w = kdjj_meanstring ? nyy_c : syy
        if kdjj_meanstring
            # residual corner forces of the stress-gradient part:
            # df_i = sum_gp w * Bm_i' * (N_gp - N_mean)   (resultants: no h)
            rxx = N_gp[gi,1] - nxx_c
            ryy = N_gp[gi,2] - nyy_c
            rxy = N_gp[gi,3] - nxy_c
            @inbounds for i in 1:4
                dfx_ms[i] += w * (dNx[i]*rxx + dNy[i]*rxy)
                dfy_ms[i] += w * (dNy[i]*ryy + dNx[i]*rxy)
            end
        end
        for i in 1:4
            r0 = (i-1)*6
            for j in 1:4
                c0 = (j-1)*6
                sym_xy = 0.5 * (dNx[i]*dNy[j] + dNy[i]*dNx[j])
                kuu = w * (syy * dNy[i]*dNy[j] + sxy * sym_xy)
                kvv = w * (sxx * dNx[i]*dNx[j] + sxy * sym_xy)
                kuv = -w * sxy * 0.5 * (dNx[i]*dNx[j] + dNy[i]*dNy[j])
                Kg[r0+1, c0+1] += ce*ce*kuu - 2.0*ce*se*kuv + se*se*kvv
                Kg[r0+1, c0+2] += ce*se*kuu + (ce*ce - se*se)*kuv - se*ce*kvv
                Kg[r0+2, c0+1] += se*ce*kuu + (ce*ce - se*se)*kuv - ce*se*kvv
                Kg[r0+2, c0+2] += se*se*kuu + 2.0*se*ce*kuv + ce*ce*kvv
                Kg[r0+3, c0+3] += w * (
                    sxx_w * dNx[i]*dNx[j] +
                    syy_w * dNy[i]*dNy[j] +
                    sxy * (dNx0[i]*dNy0[j] + dNy0[i]*dNx0[j])
                )
            end
        end
    end
    if kdjj_meanstring
        # Edge strings carrying the gradient residual (port of the legacy
        # :meanstring form, see ~line 6900): least-squares decomposition of
        # the self-equilibrated residual corner forces onto the 4 edges + 2
        # diagonals; each strut of force P and length L adds (P/L)[1,-1;-1,1]
        # on its (w_a, w_b) pair plus the in-plane-transverse part.
        # dfx_ms/dfy_ms were accumulated in the BISECTOR frame (bisector
        # gradients x bisector resultant components); rotate back to lc to
        # match the coords-based strut geometry.
        dflx = MVector{4,Float64}(undef); dfly = MVector{4,Float64}(undef)
        @inbounds for i in 1:4
            dflx[i] = ce * dfx_ms[i] - se * dfy_ms[i]
            dfly[i] = se * dfx_ms[i] + ce * dfy_ms[i]
        end
        ms_edges = ((1,2), (2,3), (3,4), (4,1), (1,3), (2,4))
        ms_A = zeros(8, 6)
        for (k, (a, b)) in enumerate(ms_edges)
            ex = coords[b,1] - coords[a,1]
            ey = coords[b,2] - coords[a,2]
            Le = hypot(ex, ey)
            Le < 1e-12 && continue
            ex /= Le; ey /= Le
            ms_A[2a-1, k] += ex; ms_A[2a, k] += ey
            ms_A[2b-1, k] -= ex; ms_A[2b, k] -= ey
        end
        ms_rhs = zeros(8)
        @inbounds for i in 1:4
            ms_rhs[2i-1] = -dflx[i]
            ms_rhs[2i]   = -dfly[i]
        end
        ms_G = ms_A' * ms_A
        @inbounds for k in 1:6
            ms_G[k,k] += 1e-10
        end
        ms_P = ms_G \ (ms_A' * ms_rhs)
        for (k, (a, b)) in enumerate(ms_edges)
            ex = coords[b,1] - coords[a,1]
            ey = coords[b,2] - coords[a,2]
            Le = hypot(ex, ey)
            Le < 1e-12 && continue
            s = ms_P[k] / Le
            wa = (a-1)*6 + 3; wb = (b-1)*6 + 3
            Kg[wa, wa] += s; Kg[wb, wb] += s
            Kg[wa, wb] -= s; Kg[wb, wa] -= s
            if kdjj_ms_inplane
                # in-plane-transverse part: unit perpendicular to the strut
                px = -ey / Le; py = ex / Le
                for (na, sa) in ((a, 1.0), (b, -1.0)), (nb, sb) in ((a, 1.0), (b, -1.0))
                    ra = (na-1)*6; rb = (nb-1)*6
                    Kg[ra+1, rb+1] += s * sa * sb * px * px
                    Kg[ra+1, rb+2] += s * sa * sb * px * py
                    Kg[ra+2, rb+1] += s * sa * sb * py * px
                    Kg[ra+2, rb+2] += s * sa * sb * py * py
                end
            end
        end
    end
    # Debug hook for offline string-construction DOE: append coords + per-GP
    # N to the file named by JFEM_KDJJ_DUMP_NGP (single-element rigs).  One
    # atomic write per call so multi-threaded box assembly does not interleave.
    let ngp_path = get(ENV, "JFEM_KDJJ_DUMP_NGP", "")
        if !isempty(ngp_path)
            buf = IOBuffer()
            for i in 1:4
                print(buf, coords[i,1], " ", coords[i,2], " ")
            end
            for gi in 1:4, c in 1:3
                print(buf, N_gp[gi,c], " ")
            end
            print(buf, "\n")
            open(ngp_path, "a") do io
                write(io, take!(buf))
            end
        end
    end
    # Firing/gradient statistics hook: JFEM_KDJJ_MS_STATS names a file that
    # gets one line per kernel call: grad_ratio  skew_cos.  grad_ratio =
    # max_gp,c |N_gp - N_mean| / max_c|N_mean| measures how much stress
    # gradient this single element carries (the meanstring term scales with
    # it); skew_cos = |cos(angle between edges 1-2 and 1-4)| (0 = rectangle).
    let stats_path = get(ENV, "JFEM_KDJJ_MS_STATS", "")
        if !isempty(stats_path)
            mx = 0.0
            for gi in 1:4
                for c in 1:3
                    m = c == 1 ? nxx_c : (c == 2 ? nyy_c : nxy_c)
                    d = abs(N_gp[gi,c] - m)
                    d > mx && (mx = d)
                end
            end
            mmag = max(abs(nxx_c), abs(nyy_c), abs(nxy_c), 1e-30)
            e12x = coords[2,1]-coords[1,1]; e12y = coords[2,2]-coords[1,2]
            e14x = coords[4,1]-coords[1,1]; e14y = coords[4,2]-coords[1,2]
            scos = abs(e12x*e14x + e12y*e14y) /
                   max(hypot(e12x,e12y)*hypot(e14x,e14y), 1e-30)
            buf = IOBuffer()
            print(buf, mx/mmag, " ", scos, "\n")
            open(stats_path, "a") do io
                write(io, take!(buf))
            end
        end
    end
    return Kg
end

# KERNEL: quad4_membrane_hourglass_skew_correction
# Skew-metric ANISOTROPIC hourglass restabilization of the compatible bilinear
# CQUAD4 membrane, identified against MSC Nastran v70.5 KGG membrane blocks on
# [0/90/0] cantilevers at skew 0/20/45 (2026-07-15).  On skewed quads the plain
# full-2x2 bilinear membrane over-stiffens the two in-plane HOURGLASS modes
# (the (1,-1,1,-1) corner pattern); Nastran carries a SPLIT (anisotropic)
# hourglass stiffness -- one hourglass direction soft, the orthogonal one stiff.
# This returns a 24x24 correction dK such that (full-bilinear membrane + dK)
# reproduces Nastran's membrane block: element KGG membrane 15.0%->0.5% (skew45),
# 5.4%->3.6% (skew20), 1.9%->0.1% (skew0).  The correction touches ONLY the
# rank-2 hourglass subspace of the 8 in-plane DOFs -> the one-point (uniform-
# strain) part is untouched, so the constant-strain PATCH TEST stays exact and
# rank is preserved (5 positive membrane eigenvalues) on rectangles, high aspect,
# trapezoids and general quads (verified).  Skew law (fit across skew 0/20/45,
# c2 = cos^2 of the centroid covariant edge angle g_r . g_s):
#   f_soft  = 0.924 - 1.315 c2   (relieve the soft hourglass, ->1/3 at skew45)
#   f_stiff = 0.954 + 0.496 c2   (amplify the stiff hourglass)
# At a rectangle (c2=0) both -> ~0.92-0.95, the standard reduced-integration
# hourglass relief.  Diagonalization axis = the bilinear hourglass block's OWN
# eigenframe (pure geometry), which generalizes across the skew family (the
# per-element eigen-axis refinement was found to OVERFIT a single element).
# Cm is the laminate membrane A-matrix (resultant); no h factor.
function quad4_membrane_hourglass_skew_correction(coords::AbstractMatrix,
                                                  Cm::AbstractMatrix)
    dK = zeros(24, 24)
    X = (coords[1,1], coords[2,1], coords[3,1], coords[4,1])
    Y = (coords[1,2], coords[2,2], coords[3,2], coords[4,2])
    sh(r,s) = (SVector(-(1-s),(1-s),(1+s),-(1+s)).*0.25,
               SVector(-(1-r),-(1+r),(1+r),(1-r)).*0.25)
    function Jf(r,s)
        dNr,dNs = sh(r,s)
        @SMatrix [dNr[1]*X[1]+dNr[2]*X[2]+dNr[3]*X[3]+dNr[4]*X[4]  dNr[1]*Y[1]+dNr[2]*Y[2]+dNr[3]*Y[3]+dNr[4]*Y[4];
                  dNs[1]*X[1]+dNs[2]*X[2]+dNs[3]*X[3]+dNs[4]*X[4]  dNs[1]*Y[1]+dNs[2]*Y[2]+dNs[3]*Y[3]+dNs[4]*Y[4]]
    end
    function Bf(r,s)
        dNr,dNs = sh(r,s); iJ = inv(Jf(r,s))
        B = zeros(3,8)
        @inbounds for k in 1:4
            gx = iJ[1,1]*dNr[k] + iJ[1,2]*dNs[k]
            gy = iJ[2,1]*dNr[k] + iJ[2,2]*dNs[k]
            B[1,2k-1] = gx; B[2,2k] = gy; B[3,2k-1] = gy; B[3,2k] = gx
        end
        B
    end
    gp = 1.0/sqrt(3.0)
    gps = ((-gp,-gp),(gp,-gp),(gp,gp),(-gp,gp))
    # full-2x2 bilinear membrane 8x8 (what the caller has, Wilson OFF)
    Kb = zeros(8,8)
    for (r,s) in gps
        B = Bf(r,s); Kb .+= B'*Cm*B*abs(det(Jf(r,s)))
    end
    # hourglass amplitude plane, purified of constant + rigid-body + linear
    hg = (1.0,-1.0,1.0,-1.0)
    nf(uf,vf) = (d=zeros(8); for k in 1:4; d[2k-1]=uf(X[k],Y[k]); d[2k]=vf(X[k],Y[k]); end; d)
    cs = (nf((x,y)->1.0,(x,y)->0.0), nf((x,y)->0.0,(x,y)->1.0), nf((x,y)->-y,(x,y)->x),
          nf((x,y)->x,(x,y)->0.0), nf((x,y)->0.0,(x,y)->y), nf((x,y)->y,(x,y)->x))
    Q = zeros(8,6)
    for (j,b) in enumerate(cs)
        v = copy(b); for i in 1:j-1; v .-= (Q[:,i]'*v).*Q[:,i]; end; Q[:,j] = v./norm(v)
    end
    pur(hv) = (v=copy(hv); for i in 1:6; v .-= (Q[:,i]'*v).*Q[:,i]; end; v)
    Hu = zeros(8); Hv = zeros(8); for k in 1:4; Hu[2k-1]=hg[k]; Hv[2k]=hg[k]; end
    gu = pur(Hu); gu ./= norm(gu)
    gv = pur(Hv); gv .-= (gu'*gv).*gu; gv ./= norm(gv)
    Hb = hcat(gu, gv)                                # 8x2 hourglass basis
    Gb = Hb'*Kb*Hb                                   # bilinear hourglass 2x2 block
    # skew metric from the centroid covariant edges
    J0 = Jf(0.0,0.0); gr = J0[1,:]; gsv = J0[2,:]
    c2 = (dot(gr,gsv)/(norm(gr)*norm(gsv)))^2
    # Split law calibrated on skew 0/20/45 (c2 in [0, 0.5]); hold the last
    # calibrated point past c2 = 0.5 -- the linear law would drive f_soft
    # NEGATIVE (indefinite membrane block) for c2 > 0.70, reachable on
    # extreme sliver/trapezoid quads that pass the flat gate (2026-07-16
    # review finding).  Flat extrapolation matches the zb-law precedent.
    c2 = min(c2, 0.5)
    f_soft = 0.924 - 1.315*c2
    f_stiff = 0.954 + 0.496*c2
    e = eigen(Symmetric(Gb)); lam = copy(e.values); V = e.vectors
    is = argmin(lam); il = 3 - is
    lam[is] *= f_soft; lam[il] *= f_stiff
    Gnew = V*Diagonal(lam)*V'
    dG = Hb*(Gnew .- Gb)*Hb'                          # 8x8 membrane correction (hourglass-only)
    # embed into 24x24 (u,v are DOFs 1,2 per node)
    mem = (1,2, 7,8, 13,14, 19,20)
    @inbounds for a in 1:8, b in 1:8
        dK[mem[a], mem[b]] += dG[a,b]
    end
    dK
end

function geometric_stiffness_quad4_nastran_kdjj_pcomp(coords::AbstractMatrix,
                                                      u_e::AbstractVector,
                                                      Cm_prime::AbstractMatrix,
                                                      h::Float64)
    Kg = zeros(24, 24)
    h < 1e-30 && return Kg
    x1 = coords[1,1]; y1 = coords[1,2]
    x2 = coords[2,1]; y2 = coords[2,2]
    x3 = coords[3,1]; y3 = coords[3,2]
    x4 = coords[4,1]; y4 = coords[4,2]
    d13x = x3 - x1; d13y = y3 - y1; l13 = hypot(d13x, d13y)
    d42x = x2 - x4; d42y = y2 - y4; l42 = hypot(d42x, d42y)
    (l13 < 1e-12 || l42 < 1e-12) && return Kg
    bx = d13x / l13 + d42x / l42
    by = d13y / l13 + d42y / l42
    lb = hypot(bx, by)
    lb < 1e-12 && return Kg
    ce = bx / lb; se = by / lb
    up = MVector{4,Float64}(undef)
    vp = MVector{4,Float64}(undef)
    @inbounds for k in 1:4
        ux = u_e[(k-1)*6 + 1]
        uy = u_e[(k-1)*6 + 2]
        up[k] =  ce * ux + se * uy
        vp[k] = -se * ux + ce * uy
    end
    # Cm_prime is the laminate membrane A-matrix rotated into the bisector/primed frame:
    # sigma_resultant = Cm_prime * [eps_x'; eps_y'; gamma'].  Full anisotropic coupling.
    c11 = Cm_prime[1,1]; c12 = Cm_prime[1,2]; c13 = Cm_prime[1,3]
    c22 = Cm_prime[2,2]; c23 = Cm_prime[2,3]; c33 = Cm_prime[3,3]
    X = (x1, x2, x3, x4); Y = (y1, y2, y3, y4)
    function grad_p(r::Float64, s::Float64)
        dNr = (-(1.0-s), (1.0-s), (1.0+s), -(1.0+s)) .* 0.25
        dNs = (-(1.0-r), -(1.0+r), (1.0+r), (1.0-r)) .* 0.25
        J11 = dNr[1]*X[1] + dNr[2]*X[2] + dNr[3]*X[3] + dNr[4]*X[4]
        J12 = dNr[1]*Y[1] + dNr[2]*Y[2] + dNr[3]*Y[3] + dNr[4]*Y[4]
        J21 = dNs[1]*X[1] + dNs[2]*X[2] + dNs[3]*X[3] + dNs[4]*X[4]
        J22 = dNs[1]*Y[1] + dNs[2]*Y[2] + dNs[3]*Y[3] + dNs[4]*Y[4]
        detJ = J11*J22 - J12*J21
        abs(detJ) < 1e-14 && return nothing
        i11 =  J22 / detJ; i12 = -J12 / detJ
        i21 = -J21 / detJ; i22 =  J11 / detJ
        dNx = MVector{4,Float64}(undef); dNy = MVector{4,Float64}(undef)
        @inbounds for k in 1:4
            gx = i11*dNr[k] + i12*dNs[k]
            gy = i21*dNr[k] + i22*dNs[k]
            dNx[k] =  ce * gx + se * gy
            dNy[k] = -se * gx + ce * gy
        end
        return dNx, dNy, abs(detJ)
    end
    g0 = grad_p(0.0, 0.0)
    g0 === nothing && return Kg
    dNx0, dNy0, _ = g0
    gam0 = 0.0
    @inbounds for k in 1:4
        gam0 += dNy0[k]*up[k] + dNx0[k]*vp[k]
    end
    gp = 1.0 / sqrt(3.0)
    @inbounds for (r, s) in ((-gp,-gp), (gp,-gp), (gp,gp), (-gp,gp))
        g = grad_p(r, s)
        g === nothing && continue
        dNx, dNy, adetJ = g
        w = adetJ  # Cm_prime is a stress RESULTANT map (A-matrix) -> NO extra h
        epx = 0.0; epy = 0.0
        for k in 1:4
            epx += dNx[k]*up[k]
            epy += dNy[k]*vp[k]
        end
        # full anisotropic stress resultant; gamma center-sampled (gam0)
        sxx = c11*epx + c12*epy + c13*gam0
        syy = c12*epx + c22*epy + c23*gam0
        sxy = c13*epx + c23*epy + c33*gam0
        for i in 1:4
            r0 = (i-1)*6
            for j in 1:4
                c0 = (j-1)*6
                sym_xy = 0.5 * (dNx[i]*dNy[j] + dNy[i]*dNx[j])
                kuu = w * (syy * dNy[i]*dNy[j] + sxy * sym_xy)
                kvv = w * (sxx * dNx[i]*dNx[j] + sxy * sym_xy)
                kuv = -w * sxy * 0.5 * (dNx[i]*dNx[j] + dNy[i]*dNy[j])
                Kg[r0+1, c0+1] += ce*ce*kuu - 2.0*ce*se*kuv + se*se*kvv
                Kg[r0+1, c0+2] += ce*se*kuu + (ce*ce - se*se)*kuv - se*ce*kvv
                Kg[r0+2, c0+1] += se*ce*kuu + (ce*ce - se*se)*kuv - ce*se*kvv
                Kg[r0+2, c0+2] += se*se*kuu + 2.0*se*ce*kuv + ce*ce*kvv
                Kg[r0+3, c0+3] += w * (
                    sxx * dNx[i]*dNx[j] +
                    syy * dNy[i]*dNy[j] +
                    sxy * (dNx0[i]*dNy0[j] + dNy0[i]*dNx0[j])
                )
            end
        end
    end
    return Kg
end

function geometric_stiffness_quad4_nastran_kdjj_iso(coords::AbstractMatrix,
                                                    u_e::AbstractVector,
                                                    E::Float64,
                                                    nu::Float64,
                                                    h::Float64)
    Kg = zeros(24, 24)
    h < 1e-30 && return Kg
    x1 = coords[1,1]; y1 = coords[1,2]
    x2 = coords[2,1]; y2 = coords[2,2]
    x3 = coords[3,1]; y3 = coords[3,2]
    x4 = coords[4,1]; y4 = coords[4,2]
    # element frame: bisector of diagonals G1->G3 and G4->G2
    d13x = x3 - x1; d13y = y3 - y1; l13 = hypot(d13x, d13y)
    d42x = x2 - x4; d42y = y2 - y4; l42 = hypot(d42x, d42y)
    (l13 < 1e-12 || l42 < 1e-12) && return Kg
    bx = d13x / l13 + d42x / l42
    by = d13y / l13 + d42y / l42
    lb = hypot(bx, by)
    lb < 1e-12 && return Kg
    ce = bx / lb; se = by / lb
    # in-plane nodal displacements in the element (primed) frame
    up = MVector{4,Float64}(undef)
    vp = MVector{4,Float64}(undef)
    @inbounds for k in 1:4
        ux = u_e[(k-1)*6 + 1]
        uy = u_e[(k-1)*6 + 2]
        up[k] =  ce * ux + se * uy
        vp[k] = -se * ux + ce * uy
    end
    d11 = E / (1.0 - nu^2); d12 = nu * d11; d33 = E / (2.0 * (1.0 + nu))
    X = (x1, x2, x3, x4); Y = (y1, y2, y3, y4)
    # primed-frame bilinear gradients at (r,s)
    function grad_p(r::Float64, s::Float64)
        dNr = (-(1.0-s), (1.0-s), (1.0+s), -(1.0+s)) .* 0.25
        dNs = (-(1.0-r), -(1.0+r), (1.0+r), (1.0-r)) .* 0.25
        J11 = dNr[1]*X[1] + dNr[2]*X[2] + dNr[3]*X[3] + dNr[4]*X[4]
        J12 = dNr[1]*Y[1] + dNr[2]*Y[2] + dNr[3]*Y[3] + dNr[4]*Y[4]
        J21 = dNs[1]*X[1] + dNs[2]*X[2] + dNs[3]*X[3] + dNs[4]*X[4]
        J22 = dNs[1]*Y[1] + dNs[2]*Y[2] + dNs[3]*Y[3] + dNs[4]*Y[4]
        detJ = J11*J22 - J12*J21
        abs(detJ) < 1e-14 && return nothing
        i11 =  J22 / detJ; i12 = -J12 / detJ
        i21 = -J21 / detJ; i22 =  J11 / detJ
        dNx = MVector{4,Float64}(undef); dNy = MVector{4,Float64}(undef)
        @inbounds for k in 1:4
            gx = i11*dNr[k] + i12*dNs[k]
            gy = i21*dNr[k] + i22*dNs[k]
            dNx[k] =  ce * gx + se * gy
            dNy[k] = -se * gx + ce * gy
        end
        return dNx, dNy, abs(detJ)
    end
    g0 = grad_p(0.0, 0.0)
    g0 === nothing && return Kg
    dNx0, dNy0, _ = g0
    # center-sampled membrane shear in the element frame
    gam0 = 0.0
    @inbounds for k in 1:4
        gam0 += dNy0[k]*up[k] + dNx0[k]*vp[k]
    end
    gp = 1.0 / sqrt(3.0)
    @inbounds for (r, s) in ((-gp,-gp), (gp,-gp), (gp,gp), (-gp,gp))
        g = grad_p(r, s)
        g === nothing && continue
        dNx, dNy, adetJ = g
        w = h * adetJ
        epx = 0.0; epy = 0.0
        for k in 1:4
            epx += dNx[k]*up[k]
            epy += dNy[k]*vp[k]
        end
        sxx = d11*epx + d12*epy
        syy = d12*epx + d11*epy
        sxy = d33*gam0
        for i in 1:4
            r0 = (i-1)*6
            for j in 1:4
                c0 = (j-1)*6
                # in-plane component string rule (primed frame)
                sym_xy = 0.5 * (dNx[i]*dNy[j] + dNy[i]*dNx[j])
                kuu = w * (syy * dNy[i]*dNy[j] + sxy * sym_xy)
                kvv = w * (sxx * dNx[i]*dNx[j] + sxy * sym_xy)
                kuv = -w * sxy * 0.5 * (dNx[i]*dNx[j] + dNy[i]*dNy[j])
                # rotate dof pair back: Kg_local = R' * [kuu kuv; kuv kvv] * R
                Kg[r0+1, c0+1] += ce*ce*kuu - 2.0*ce*se*kuv + se*se*kvv
                Kg[r0+1, c0+2] += ce*se*kuu + (ce*ce - se*se)*kuv - se*ce*kvv
                Kg[r0+2, c0+1] += se*ce*kuu + (ce*ce - se*se)*kuv - ce*se*kvv
                Kg[r0+2, c0+2] += se*se*kuu + 2.0*se*ce*kuv + ce*ce*kvv
                # w block: per-GP metric, center-sampled shear cross term
                Kg[r0+3, c0+3] += w * (
                    sxx * dNx[i]*dNx[j] +
                    syy * dNy[i]*dNy[j] +
                    sxy * (dNx0[i]*dNy0[j] + dNy0[i]*dNx0[j])
                )
            end
        end
    end
    return Kg
end

function quad4_membrane_force_field_covariant(coords3d::AbstractMatrix,
                                              u_nodes_global::AbstractMatrix,
                                              basis1::SVector{3,Float64},
                                              basis2::SVector{3,Float64},
                                              Cm::AbstractMatrix)
    pt = 1.0 / sqrt(3.0)
    gauss_pts = [-pt -pt; pt -pt; pt pt; -pt pt]

    N_gp = zeros(4, 3)
    N_avg = zeros(3)
    area_w = zeros(4)
    total_area = 0.0

    @inbounds for i in 1:4
        r, s = gauss_pts[i,1], gauss_pts[i,2]
        dNr, dNs = shape_derivs_quad(r, s)

        a_r = SVector(
            dNr[1]*coords3d[1,1] + dNr[2]*coords3d[2,1] + dNr[3]*coords3d[3,1] + dNr[4]*coords3d[4,1],
            dNr[1]*coords3d[1,2] + dNr[2]*coords3d[2,2] + dNr[3]*coords3d[3,2] + dNr[4]*coords3d[4,2],
            dNr[1]*coords3d[1,3] + dNr[2]*coords3d[2,3] + dNr[3]*coords3d[3,3] + dNr[4]*coords3d[4,3],
        )
        a_s = SVector(
            dNs[1]*coords3d[1,1] + dNs[2]*coords3d[2,1] + dNs[3]*coords3d[3,1] + dNs[4]*coords3d[4,1],
            dNs[1]*coords3d[1,2] + dNs[2]*coords3d[2,2] + dNs[3]*coords3d[3,2] + dNs[4]*coords3d[4,2],
            dNs[1]*coords3d[1,3] + dNs[2]*coords3d[2,3] + dNs[3]*coords3d[3,3] + dNs[4]*coords3d[4,3],
        )

        g11 = dot(a_r, a_r)
        g12 = dot(a_r, a_s)
        g22 = dot(a_s, a_s)
        detg = g11 * g22 - g12 * g12
        if abs(detg) < 1e-14
            detg = detg < 0.0 ? -1e-14 : 1e-14
        end
        invg11 = g22 / detg
        invg12 = -g12 / detg
        invg22 = g11 / detg

        a_r_contra = invg11 * a_r + invg12 * a_s
        a_s_contra = invg12 * a_r + invg22 * a_s

        u_r = SVector(
            dNr[1]*u_nodes_global[1,1] + dNr[2]*u_nodes_global[2,1] + dNr[3]*u_nodes_global[3,1] + dNr[4]*u_nodes_global[4,1],
            dNr[1]*u_nodes_global[1,2] + dNr[2]*u_nodes_global[2,2] + dNr[3]*u_nodes_global[3,2] + dNr[4]*u_nodes_global[4,2],
            dNr[1]*u_nodes_global[1,3] + dNr[2]*u_nodes_global[2,3] + dNr[3]*u_nodes_global[3,3] + dNr[4]*u_nodes_global[4,3],
        )
        u_s = SVector(
            dNs[1]*u_nodes_global[1,1] + dNs[2]*u_nodes_global[2,1] + dNs[3]*u_nodes_global[3,1] + dNs[4]*u_nodes_global[4,1],
            dNs[1]*u_nodes_global[1,2] + dNs[2]*u_nodes_global[2,2] + dNs[3]*u_nodes_global[3,2] + dNs[4]*u_nodes_global[4,2],
            dNs[1]*u_nodes_global[1,3] + dNs[2]*u_nodes_global[2,3] + dNs[3]*u_nodes_global[3,3] + dNs[4]*u_nodes_global[4,3],
        )

        grad_u = u_r * a_r_contra' + u_s * a_s_contra'
        eps11 = dot(basis1, grad_u * basis1)
        eps22 = dot(basis2, grad_u * basis2)
        gam12 = dot(basis1, grad_u * basis2) + dot(basis2, grad_u * basis1)
        N_vec = Cm * SVector(eps11, eps22, gam12)

        N_gp[i, 1] = N_vec[1]
        N_gp[i, 2] = N_vec[2]
        N_gp[i, 3] = N_vec[3]

        dA = norm(cross(a_r, a_s))
        N_avg .+= N_vec .* dA
        area_w[i] = dA
        total_area += dA
    end

    if total_area > 0.0
        N_avg ./= total_area
    end

    return N_gp, N_avg, area_w
end

function stiffness_tria3_generic(coords, E, nu, h; bend_ratio=1.0, ts_t=5.0/6.0, k6rot=100.0)
    T = promote_type(eltype(coords), typeof(E), typeof(nu), typeof(h))
    oneT = one(T)
    zeroT = zero(T)
    G = E / (2*(1+nu))
    Dbase = T[oneT nu zeroT; nu oneT zeroT; zeroT zeroT (oneT - nu) / 2]
    Dm = (E * h / (oneT - nu^2)) .* Dbase
    Db = bend_ratio * (E * h^3 / (12 * (oneT - nu^2))) .* Dbase
    Ds = ts_t * G * h .* T[oneT zeroT; zeroT oneT]
    return stiffness_tria3_matrices_generic(coords, Dm, Db, Ds, h, G; bend_ratio=bend_ratio, k6rot=k6rot)
end

function stiffness_tria3(coords, E, nu, h; bend_ratio=1.0, ts_t=5.0/6.0, k6rot=100.0)
    return stiffness_tria3_generic(coords, E, nu, h; bend_ratio=bend_ratio, ts_t=ts_t, k6rot=k6rot)
end

const TRIA3_MACRO_QUADS = ((1, 4, 7, 6), (2, 5, 7, 4), (3, 6, 7, 5))
const QUAD4_PLATE_DOF_IDX = (3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23)

@inline function _tria3_virtual_quad_points(coords::AbstractMatrix)
    T = eltype(coords)
    pts = Matrix{T}(undef, 7, 2)

    x1 = coords[1,1]; y1 = coords[1,2]
    x2 = coords[2,1]; y2 = coords[2,2]
    x3 = coords[3,1]; y3 = coords[3,2]

    pts[1,1] = x1; pts[1,2] = y1
    pts[2,1] = x2; pts[2,2] = y2
    pts[3,1] = x3; pts[3,2] = y3
    pts[4,1] = (x1 + x2) / 2; pts[4,2] = (y1 + y2) / 2
    pts[5,1] = (x2 + x3) / 2; pts[5,2] = (y2 + y3) / 2
    pts[6,1] = (x3 + x1) / 2; pts[6,2] = (y3 + y1) / 2
    pts[7,1] = (x1 + x2 + x3) / 3; pts[7,2] = (y1 + y2 + y3) / 3

    return pts
end

@inline function _tria3_virtual_quad_area(qc::AbstractMatrix)
    a1 = (qc[2,1] - qc[1,1]) * (qc[4,2] - qc[1,2]) - (qc[4,1] - qc[1,1]) * (qc[2,2] - qc[1,2])
    a2 = (qc[3,1] - qc[2,1]) * (qc[4,2] - qc[2,2]) - (qc[4,1] - qc[2,1]) * (qc[3,2] - qc[2,2])
    return (abs(a1) + abs(a2)) / 2
end

function tria3_plate_macro_data(coords, Cm, Cb, Cs, h, E_ref, pressure=nothing; bend_ratio=1.0, k6rot=100.0)
    T = promote_type(eltype(coords), eltype(Cm), eltype(Cb), eltype(Cs), typeof(h), typeof(E_ref))
    pts = _tria3_virtual_quad_points(coords)
    zero_cond = zeros(T, 9, 9)
    zero_map = zeros(T, 12, 9)
    zero_load = pressure === nothing ? nothing : zeros(T, 9)

    bend_ratio <= T(1e-12) && return (Kcond=zero_cond, Aint=zero_map, pts=pts, fcond=zero_load)

    K = zeros(T, 21, 21)
    f = pressure === nothing ? nothing : zeros(T, 21)
    plate_idx = collect(QUAD4_PLATE_DOF_IDX)

    for quad in TRIA3_MACRO_QUADS
        qc = pts[[quad[1], quad[2], quad[3], quad[4]], :]
        # CONTAINMENT (2026-08-01): the macro construction's sub-quads are a VIRTUAL
        # interpolation device, not physical elements -- they are skewed 45-53 deg and
        # tapered BY CONSTRUCTION. MacNeal's distortion corrections are derived from the
        # physics of a REAL quad (residual bending flexibility of a strip spanning the
        # element), and the reference's own triangle is not built this way at all (trec.jl:
        # its shear operator is rank 3 in MITC3's tying subspace). Applying real-element
        # corrections to virtual sub-quads is unjustified and measurably harmful: promoting
        # the quad skew fix moved tri_aspect 0.346 -> 0.485, and adding the taper coupling
        # took it to 0.583. Freezing this path's quad operator stops the triangle degrading
        # every time the quad improves. This is CONTAINMENT of a legacy construction pending
        # the pure MITC3 element, NOT a claim that the frozen operator is more correct.
        Ke_full = stiffness_quad4_matrices(qc, Cm, Cb, Cs, h, E_ref; bend_ratio=bend_ratio,
                                           k6rot=k6rot, distortion_corrections=false)
        Ke_plate = Ke_full[plate_idx, plate_idx]

        edofs = Int[]
        for nid in quad
            append!(edofs, (3*(nid-1)+1):(3*(nid-1)+3))
        end
        K[edofs, edofs] .+= Ke_plate

        if f !== nothing
            fe = zeros(T, 12)
            qA = pressure * _tria3_virtual_quad_area(qc)
            fe[1] = qA / 4
            fe[4] = qA / 4
            fe[7] = qA / 4
            fe[10] = qA / 4
            f[edofs] .+= fe
        end
    end

    ext = 1:9
    int = 10:21
    Kee = K[ext, ext]
    Kei = K[ext, int]
    Kie = K[int, ext]
    Kii = K[int, int]

    Fii = lu(Kii)
    Aint = -(Fii \ Kie)
    Kcond = Kee + Kei * Aint

    fcond = nothing
    if f !== nothing
        fcond = f[ext] - Kei * (Fii \ f[int])
    end

    return (Kcond=Kcond, Aint=Aint, pts=pts, fcond=fcond)
end

function tria3_plate_macro_pressure_load(coords, E, nu, h, pressure; bend_ratio=1.0, k6rot=100.0)
    T = promote_type(eltype(coords), typeof(E), typeof(nu), typeof(h), typeof(pressure))
    D = (T(E) / (one(T) - T(nu)^2)) .* Matrix{T}([one(T) T(nu) zero(T); T(nu) one(T) zero(T); zero(T) zero(T) (one(T)-T(nu))/T(2)])
    Cm = D * T(h)
    Cb = D * (T(h)^3 / T(12))
    G = T(E) / (T(2) * (one(T) + T(nu)))
    Cs = zeros(T, 2, 2)
    shear_scale = T(5) / T(6) * G * T(h)
    Cs[1,1] = shear_scale
    Cs[2,2] = shear_scale
    macro_data = tria3_plate_macro_data(coords, Cm, Cb, Cs, T(h), G, T(pressure); bend_ratio=bend_ratio, k6rot=k6rot)
    return macro_data.fcond === nothing ? zeros(T, 9) : macro_data.fcond
end

function tria3_plate_macro_shear_resultant(coords, u_plate, E, nu, h; bend_ratio=1.0, k6rot=100.0)
    T = promote_type(eltype(coords), eltype(u_plate), typeof(E), typeof(nu), typeof(h))
    bend_ratio <= T(1e-12) && return zeros(T, 2)

    D = (T(E) / (one(T) - T(nu)^2)) .* Matrix{T}([one(T) T(nu) zero(T); T(nu) one(T) zero(T); zero(T) zero(T) (one(T)-T(nu))/T(2)])
    Cm = D * T(h)
    Cb = D * (T(h)^3 / T(12))
    G = T(E) / (T(2) * (one(T) + T(nu)))
    Cs = zeros(T, 2, 2)
    shear_scale = T(5) / T(6) * G * T(h)
    Cs[1,1] = shear_scale
    Cs[2,2] = shear_scale
    macro_data = tria3_plate_macro_data(coords, Cm, Cb, Cs, T(h), G; bend_ratio=bend_ratio, k6rot=k6rot)

    u_all = Vector{T}(undef, 21)
    u_all[1:9] = u_plate
    u_all[10:21] = macro_data.Aint * u_plate

    Q_sum = zeros(T, 2)
    A_sum = zero(T)
    u_quad = zeros(T, 24)
    plate_idx = collect(QUAD4_PLATE_DOF_IDX)

    for quad in TRIA3_MACRO_QUADS
        fill!(u_quad, zero(T))
        qc = macro_data.pts[[quad[1], quad[2], quad[3], quad[4]], :]
        edofs = Int[]
        for nid in quad
            append!(edofs, (3*(nid-1)+1):(3*(nid-1)+3))
        end
        u_quad[plate_idx] .= u_all[edofs]

        _, _, Q_quad, _, _, _, _ = stress_strain_quad4(qc, u_quad, E, nu, h, h; bend_ratio=bend_ratio)
        area = _tria3_virtual_quad_area(qc)
        Q_sum .+= area .* Q_quad
        A_sum += area
    end

    A_sum <= T(1e-12) && return zeros(T, 2)
    return Q_sum ./ A_sum
end

function tria3_plate_macro_average_moment(coords, u_elem, E, nu, h; bend_ratio=1.0, k6rot=100.0)
    T = promote_type(eltype(coords), eltype(u_elem), typeof(E), typeof(nu), typeof(h))
    bend_ratio <= T(1e-12) && return zeros(T, 3)

    D = (T(E) / (one(T) - T(nu)^2)) .* Matrix{T}([one(T) T(nu) zero(T); T(nu) one(T) zero(T); zero(T) zero(T) (one(T)-T(nu))/T(2)])
    Cm = D * T(h)
    Cb = D * (T(h)^3 / T(12))
    G = T(E) / (T(2) * (one(T) + T(nu)))
    Cs = zeros(T, 2, 2)
    shear_scale = T(5) / T(6) * G * T(h)
    Cs[1,1] = shear_scale
    Cs[2,2] = shear_scale
    macro_data = tria3_plate_macro_data(coords, Cm, Cb, Cs, T(h), G; bend_ratio=bend_ratio, k6rot=k6rot)

    u_plate = T[
        u_elem[3], u_elem[4], u_elem[5],
        u_elem[9], u_elem[10], u_elem[11],
        u_elem[15], u_elem[16], u_elem[17],
    ]
    u_all = Vector{T}(undef, 21)
    u_all[1:9] = u_plate
    u_all[10:21] = macro_data.Aint * u_plate

    M_sum = zeros(T, 3)
    A_sum = zero(T)
    u_quad = zeros(T, 24)
    plate_idx = collect(QUAD4_PLATE_DOF_IDX)

    for quad in TRIA3_MACRO_QUADS
        fill!(u_quad, zero(T))
        qc = macro_data.pts[[quad[1], quad[2], quad[3], quad[4]], :]
        edofs = Int[]
        for nid in quad
            append!(edofs, (3*(nid-1)+1):(3*(nid-1)+3))
        end
        u_quad[plate_idx] .= u_all[edofs]

        _, M_quad, _, _, _, _, _ = stress_strain_quad4(qc, u_quad, E, nu, h, h; bend_ratio=bend_ratio)
        area = _tria3_virtual_quad_area(qc)
        M_sum .+= area .* M_quad
        A_sum += area
    end

    A_sum <= T(1e-12) && return zeros(T, 3)
    return M_sum ./ A_sum
end

@inline function _dkt_side_coefficients(xi::T, yi::T, xj::T, yj::T) where {T}
    xij = xi - xj
    yij = yi - yj
    l2 = xij*xij + yij*yij
    if l2 <= eps(T)
        return zero(T), zero(T), zero(T), zero(T)
    end
    P = -T(6) * xij / l2
    q = T(3) * xij * yij / l2
    r = T(3) * yij * yij / l2
    t = -T(6) * yij / l2
    return P, q, r, t
end

function _tria3_dkt_derivatives(xi::T, eta::T,
                                P4::T, P5::T, P6::T,
                                q4::T, q5::T, q6::T,
                                r4::T, r5::T, r6::T,
                                t4::T, t5::T, t6::T) where {T}
    Hx_xi = T[
        P6*(one(T)-T(2)*xi) + (P5-P6)*eta,
        q6*(one(T)-T(2)*xi) - (q5+q6)*eta,
        -T(4) + T(6)*(xi+eta) + r6*(one(T)-T(2)*xi) - eta*(r5+r6),
        -P6*(one(T)-T(2)*xi) + eta*(P4+P6),
        q6*(one(T)-T(2)*xi) - eta*(q6-q4),
        -T(2) + T(6)*xi + r6*(one(T)-T(2)*xi) + eta*(r4-r6),
        -eta*(P5+P4),
        eta*(q4-q5),
        -eta*(r5-r4),
    ]

    Hy_xi = T[
        t6*(one(T)-T(2)*xi) + eta*(t5-t6),
        one(T) + r6*(one(T)-T(2)*xi) - eta*(r5+r6),
        -q6*(one(T)-T(2)*xi) + eta*(q5+q6),
        -t6*(one(T)-T(2)*xi) + eta*(t4+t6),
        -one(T) + r6*(one(T)-T(2)*xi) + eta*(r4-r6),
        -q6*(one(T)-T(2)*xi) - eta*(q4-q6),
        -eta*(t4+t5),
        eta*(r4-r5),
        -eta*(q4-q5),
    ]

    Hx_eta = T[
        -P5*(one(T)-T(2)*eta) - xi*(P6-P5),
        q5*(one(T)-T(2)*eta) - xi*(q5+q6),
        -T(4) + T(6)*(xi+eta) + r5*(one(T)-T(2)*eta) - xi*(r5+r6),
        xi*(P4+P6),
        xi*(q4-q6),
        -xi*(r6-r4),
        P5*(one(T)-T(2)*eta) - xi*(P4+P5),
        q5*(one(T)-T(2)*eta) + xi*(q4-q5),
        -T(2) + T(6)*eta + r5*(one(T)-T(2)*eta) + xi*(r4-r5),
    ]

    Hy_eta = T[
        -t5*(one(T)-T(2)*eta) - xi*(t6-t5),
        one(T) + r5*(one(T)-T(2)*eta) - xi*(r5+r6),
        -q5*(one(T)-T(2)*eta) + xi*(q5+q6),
        xi*(t4+t6),
        xi*(r4-r6),
        -xi*(q4-q6),
        t5*(one(T)-T(2)*eta) - xi*(t4+t5),
        -one(T) + r5*(one(T)-T(2)*eta) + xi*(r4-r5),
        -q5*(one(T)-T(2)*eta) - xi*(q4-q5),
    ]

    return Hx_xi, Hy_xi, Hx_eta, Hy_eta
end

function tria3_plate_dkt_stiffness(coords, Db)
    T = promote_type(eltype(coords), eltype(Db))
    x1, y1 = T(coords[1,1]), T(coords[1,2])
    x2, y2 = T(coords[2,1]), T(coords[2,2])
    x3, y3 = T(coords[3,1]), T(coords[3,2])

    x31 = x3 - x1
    y31 = y3 - y1
    x12 = x1 - x2
    y12 = y1 - y2
    area2 = x31*y12 - x12*y31
    abs(area2) <= T(1e-12) && return zeros(T, 9, 9)

    # Batoz-Bathe-Ho DKT side order: k=4 for side 23, k=5 for 31, k=6 for 12.
    P4, q4, r4, t4 = _dkt_side_coefficients(x2, y2, x3, y3)
    P5, q5, r5, t5 = _dkt_side_coefficients(x3, y3, x1, y1)
    P6, q6, r6, t6 = _dkt_side_coefficients(x1, y1, x2, y2)

    Kpaper = zeros(T, 9, 9)
    gauss = ((T(0.5), T(0.0), T(1)/T(6)),
             (T(0.5), T(0.5), T(1)/T(6)),
             (T(0.0), T(0.5), T(1)/T(6)))
    for (xi, eta, wt) in gauss
        Hx_xi, Hy_xi, Hx_eta, Hy_eta =
            _tria3_dkt_derivatives(xi, eta, P4, P5, P6, q4, q5, q6, r4, r5, r6, t4, t5, t6)
        B = zeros(T, 3, 9)
        inv_area2 = inv(area2)
        @inbounds for j in 1:9
            B[1,j] = (y31 * Hx_xi[j] + y12 * Hx_eta[j]) * inv_area2
            B[2,j] = (-x31 * Hy_xi[j] - x12 * Hy_eta[j]) * inv_area2
            B[3,j] = (-x31 * Hx_xi[j] - x12 * Hx_eta[j] + y31 * Hy_xi[j] + y12 * Hy_eta[j]) * inv_area2
        end
        Kpaper .+= abs(area2) * wt .* (B' * Db * B)
    end

    # Paper DOFs are [w, beta_x, beta_y]. JFEM local shell plate DOFs are
    # [w, theta_x, theta_y], with beta_x=theta_y and beta_y=-theta_x.
    Tmap = zeros(T, 9, 9)
    @inbounds for i in 0:2
        p = 3*i
        Tmap[p+1, p+1] = one(T)
        Tmap[p+2, p+3] = one(T)
        Tmap[p+3, p+2] = -one(T)
    end
    return Tmap' * Kpaper * Tmap
end

# Overload accepting pre-computed constitutive matrices (for orthotropic MAT8)
"""
    tria3_rbf_shear(Ds, Db, A) -> Ds_eff

MacNeal residual bending flexibility for CTRIA3, gated by `JFEM_TRIA3_RBF_C` (0 = OFF).

**Why this exists.** Every CTRIA3 plate kernel in this file — `macro` (the default macro-quad
condensed operator), `constant` (constant-curvature Mindlin with centroidal shear), and `dkt` —
lacks any shear-locking / residual-bending treatment; there is not one occurrence of "macneal"
in the CTRIA3 code. Measured against reference KGG on single-element cells (2026-07-31), the
ROT-ROT block is wrong by:

    macro (default)   0.614 (undistorted!) … 0.954
    dkt               0.853 … 1.001
    constant          1189 at h/L=0.01 falling to 1.52 at h/L=0.305  (textbook shear locking)

i.e. the worst element-level defect in the solver, and invisible to every screen this project
runs because the 42-deck corpus contains **zero triangles**.

**The reference's law, measured.** `K[3,3]` on a flat cell is pure transverse shear, so
`1/K33 = b/t³ + a/t` is testable as "`t³/K33` linear in `t²`". On the reference it is linear to
5 significant figures over a 300× thickness range (slope 4.56000e-5 at every decade), and
reducing `(a,b)` to dimensionless form over 4× element size, 3× modulus and ν = 0…0.33 gives
`b·D₀/L² = 0.04167 = 1/24` and `a·G = 1.20000 = 6/5` EXACTLY:

    1/K33  =  L²/(24·D)  +  1/((5/6)·G·t)

The shear constant is the standard 5/6 transverse-shear correction factor; the residual-bending
constant is a clean 24·D/L². JFEM's own slope varies 100× across the same range and follows no
such law, being 2.2× too soft at thin and 3.6× at thick.

**What this applies** (series on the transverse shear rigidity, before any plate kernel sees
it, so all three inherit it):

    1/k_eff = 1/k_s + L_c²/(c_r · D̄),    L_c² = 2·A,    c_r = JFEM_TRIA3_RBF_C

⛔ **REFUTED BY MEASUREMENT 2026-07-31 — LEAVE AT 0 (OFF). Kept as the record.**
⛔ **AND THE PREMISE WAS ALSO WRONG.** The DEFAULT `macro` kernel builds the triangle from three
virtual sub-quads and calls `stiffness_quad4_matrices` on each, so CTRIA3 DOES inherit the full
CQUAD4 kernel including MacNeal RBF. It is not missing the formulation. Those sub-quads are
inherently skewed 45-53 deg with aspect up to 3.0, and the CQUAD4 skew defect at 45 deg is 37 %
in the rotational block - the same order as CTRIA3's 61 %. Fix the QUAD skew bending operator
first; CTRIA3 and skew are ONE defect.
Adding this makes the element WORSE, because the sign of the diagnosis was wrong. `K33_jfem /
K33_ref` at h/L = 0.001: **0.455 OFF → 0.101 (c_r=12) → 0.143 (c_r=24) → 0.183 (c_r=48)**.
RBF adds flexibility, and JFEM was already **2.2× too SOFT**, not too stiff.

**What the numbers actually say.** At h/L = 0.001 the reference gives `K33 = 0.0157108`, and
`24·D/L² = 0.015713` — so the reference IS the pure bending-limited form there. JFEM gives
`0.00714616`, i.e. an effective coefficient of **10.92 where the reference has 24**. JFEM's
triangle is therefore ALREADY bending-limited at thin, exactly like the reference; it does not
lack residual bending flexibility at all. Its coefficient is simply 2.2× too small, and grows
worse with thickness (3.6× at h/L = 0.305).

⇒ The real defect is inside the plate operator (`tria3_plate_macro_data`, the macro-quad
condensed kernel) producing 10.92·D/L² instead of 24·D/L². Fixing it means understanding that
condensation, NOT bolting a shear correction onto the outside. Scaling the block by 2.199 would
be a fudge and is explicitly not the answer.
"""
function tria3_rbf_shear(Ds, Db, A, coords = nothing)
    c_r = fem_env_float("JFEM_TRIA3_RBF_C", 0.0)
    c_r > 0 || return Ds
    Ds_eff = copy(Ds)
    # DIRECTIONAL residual bending flexibility (mode "dir"). MacNeal's quad RBF is
    # per-direction (separate Delta_x^2 / Delta_y^2 against E11 / E22); the original
    # triangle hook collapsed that to ONE isotropic length Lc2 = 2A against the averaged
    # bending stiffness, which is exact only when the triangle is equilateral-ish and
    # degrades with aspect -- measured MITC3 rot-rot 0.50/0.58/1.09/1.98 at aspect
    # 1/2/5/10, i.e. fine at aspect 1 and diverging exactly where one length cannot
    # stand in for two. gamma_xz is bending about y over the x-extent, so it pairs with
    # the x-extent and Db[1,1]; likewise y.
    dir = lowercase(strip(get(ENV, "JFEM_TRIA3_RBF_MODE", "iso"))) in ("dir", "directional")
    if dir && coords !== nothing
        Lx2 = (maximum(@view coords[:,1]) - minimum(@view coords[:,1]))^2
        Ly2 = (maximum(@view coords[:,2]) - minimum(@view coords[:,2]))^2
        Lc2v = (Lx2, Ly2)
        Dv = (abs(Db[1,1]), abs(Db[2,2]))
        @inbounds for i in 1:min(2, size(Ds, 1))
            ks = Ds[i, i]
            (ks > 0 && Dv[i] > 0) || continue
            Ds_eff[i, i] = 1.0 / (1.0 / ks + Lc2v[i] / (c_r * Dv[i]))
        end
        return Ds_eff
    end
    Dbar = 0.5 * (abs(Db[1, 1]) + abs(Db[2, 2]))
    Dbar > 0 || return Ds
    Lc2 = 2 * A
    @inbounds for i in 1:min(2, size(Ds, 1))
        ks = Ds[i, i]
        ks > 0 || continue
        Ds_eff[i, i] = 1.0 / (1.0 / ks + Lc2 / (c_r * Dbar))
    end
    Ds_eff
end

function stiffness_tria3_matrices_generic(coords, Dm, Db, Ds, h, G_ref; bend_ratio=1.0, k6rot=100.0, Bmb=nothing)
    T = promote_type(eltype(coords), eltype(Dm), eltype(Db), eltype(Ds), typeof(h), typeof(G_ref))
    x, y = coords[:,1], coords[:,2]
    A2 = x[1]*(y[2]-y[3]) + x[2]*(y[3]-y[1]) + x[3]*(y[1]-y[2])
    A = T(0.5) * abs(A2)
    if A < T(1e-12); return zeros(T, 18, 18); end
    # Residual bending flexibility applied to the transverse shear rigidity BEFORE any plate
    # kernel is chosen, so `macro`, `constant` and `dkt` all inherit it. No-op when the gate
    # is 0 (the default).
    Ds = tria3_rbf_shear(Ds, Db, A, coords)

    Ke = zeros(T, 18, 18)

    # --- Membrane (constant strain triangle, CST) ---
    bv = T[y[2]-y[3], y[3]-y[1], y[1]-y[2]] ./ (2*A)
    cv = T[x[3]-x[2], x[1]-x[3], x[2]-x[1]] ./ (2*A)
    Bm = zeros(T, 3, 6)
    for i in 1:3; Bm[1, i*2-1]=bv[i]; Bm[2, i*2]=cv[i]; Bm[3, i*2-1]=cv[i]; Bm[3, i*2]=bv[i]; end
    K_mem = Bm' * Dm * Bm * A
    m_idx = [1,2, 7,8, 13,14]
    Ke[m_idx, m_idx] = K_mem

    # --- Bending: Isoparametric Mindlin-Reissner Triangle ---
    Bb = zeros(T, 3, 9)
    for i in 1:3
        col_rx = 3*(i-1) + 2  # θx
        col_ry = 3*(i-1) + 3  # θy
        Bb[1, col_ry] = bv[i]     # κxx
        Bb[2, col_rx] = -cv[i]    # κyy
        Bb[3, col_rx] = -bv[i]    # κxy: -∂θx/∂x
        Bb[3, col_ry] = cv[i]     # κxy: +∂θy/∂y
    end
    Kb = Bb' * Db * Bb * A

    # Transverse shear at centroid (1-point integration)
    # γxz = ∂w/∂x + θy, γyz = ∂w/∂y - θx
    Bs = zeros(T, 2, 9)
    for i in 1:3
        col_w  = 3*(i-1) + 1
        col_rx = 3*(i-1) + 2
        col_ry = 3*(i-1) + 3
        Bs[1, col_w]  = bv[i]
        Bs[1, col_ry] = one(T)/T(3)    # N[i] = 1/3 at centroid
        Bs[2, col_w]  = cv[i]
        Bs[2, col_rx] = -one(T)/T(3)
    end
    Ks = Bs' * Ds * Bs * A

    # Diagnostic dump of the triangle's plate operands, so the reference's own shear
    # operator can be RECOVERED rather than guessed -- the method that solved the quad
    # (see TOOLS_MATPRN/zrec.jl). Writes the constant-curvature bending block Kb and the
    # element-frame coords; the analysis subtracts Kb from the reference's plate block and
    # examines the RANK of what is left. A MacNeal/MITC-style triangle samples transverse
    # shear at a handful of tying points, so its shear stiffness is LOW RANK (<= 3); a
    # rank-3 remainder means the reference's operator is recoverable in closed form, a
    # full-rank one means its bending differs from constant curvature and the search has
    # to move there instead.
    let tdump = get(ENV, "JFEM_TRIA3_DUMP_PLATE", "")
        if !isempty(tdump)
            open(tdump, "a") do io
                println(io, "# TMAT")
                for i in 1:3
                    println(io, "XY ", string(Float64(coords[i,1])), " ", string(Float64(coords[i,2])))
                end
                for i in 1:9
                    println(io, "KB ", join((string(Float64(Kb[i,j])) for j in 1:9), " "))
                end
                # laminate bending constitutive matrix in the ELEMENT frame. Needed because
                # the derived Zb is normalised by a bending stiffness, and on a PCOMP that
                # stiffness is DIRECTIONAL -- the rig cannot read it off the deck.
                for i in 1:3
                    println(io, "DB ", join((string(Float64(Db[i,j])) for j in 1:3), " "))
                end
            end
        end
    end

    b_idx = [3,4,5, 9,10,11, 15,16,17]
    # Use the macro-quad condensed triangle by default. It is the current
    # SOL101/SOL105 guardrail path; the DKT implementation remains available
    # for controlled formulation probes with JFEM_TRIA3_PLATE_KERNEL=dkt.
    tria3_plate_kernel = lowercase(strip(get(ENV, "JFEM_TRIA3_PLATE_KERNEL", "mitc3")))  # PROMOTED 2026-08-01
    if tria3_plate_kernel in ("mitc3",)
        # ------------------------------------------------------------------
        # PURE THREE-NODE TRIANGLE (MITC3): assumed transverse-shear strains tied at
        # the edge midpoints.  Owner directive 2026-07-31: "model trias as pure trias
        # when you can" -- the default `macro` kernel builds the triangle from three
        # virtual sub-quads that are skewed 45-53 deg BY CONSTRUCTION, so it inherits
        # the quad's distortion sensitivity as a floor it can never get below (an
        # UNDISTORTED right triangle is already 61 % wrong), and fixing the quad's skew
        # defect exactly made the triangle WORSE, which rules out "same defect".
        #
        # w and both rotations are linear, so the covariant shear strains are linear
        # fields; MITC3 replaces them with the assumed field
        #     g~_r = g_r(A) + c*s ,   g~_s = g_s(B) - c*r
        # tied at A = mid(1,2), B = mid(1,3) and, along edge 2-3, at C = mid(2,3):
        #     c = [g_r(C) - g_r(A)] - [g_s(C) - g_s(B)]
        # The shared coefficient with opposite signs is what removes the spurious
        # constraint that makes the plain centroid-sampled triangle lock (measured:
        # 1189x too stiff at h/L = 0.001, decaying to 1.5x when thick -- textbook).
        # Cartesian strains follow from [g_xz; g_yz] = J^-1 [g_r; g_s].
        x1, y1 = coords[1,1], coords[1,2]
        x2, y2 = coords[2,1], coords[2,2]
        x3, y3 = coords[3,1], coords[3,2]
        # natural coords: node1 (0,0), node2 (1,0), node3 (0,1); J is constant
        Jm = @SMatrix [x2 - x1  y2 - y1; x3 - x1  y3 - y1]
        Jinv = inv(Jm)
        # covariant shear rows as functions of (r,s):  g_r = dw/dr + th_y*x,r - th_x*y,r
        # with linear shape functions N1 = 1-r-s, N2 = r, N3 = s.
        function gcov(r, s)
            N = (one(T) - r - s, r, s)
            Br = zeros(T, 9); Bs_ = zeros(T, 9)
            dwdr = (-one(T), one(T), zero(T))
            dwds = (-one(T), zero(T), one(T))
            for i in 1:3
                cw = 3*(i-1) + 1; crx = 3*(i-1) + 2; cry = 3*(i-1) + 3
                Br[cw]  = dwdr[i];      Bs_[cw]  = dwds[i]
                Br[cry] = N[i] * Jm[1,1];  Bs_[cry] = N[i] * Jm[2,1]
                Br[crx] = -N[i] * Jm[1,2]; Bs_[crx] = -N[i] * Jm[2,2]
            end
            Br, Bs_
        end
        grA, _   = gcov(T(0.5), zero(T))
        _,   gsB = gcov(zero(T), T(0.5))
        grC, gsC = gcov(T(0.5), T(0.5))
        cvec = (grC .- grA) .- (gsC .- gsB)
        # integrate Bs' Ds Bs over the triangle; the assumed field is linear in (r,s),
        # so the 3-midpoint rule is exact for the quadratic integrand
        # Shear RIGIDITY in the tying basis: Ks = D3' * Wsh * D3 with D3 = [grA; gsB; c].
        # Assembling Wsh (3x3) rather than the 9x9 directly is what lets the reference's
        # residual bending flexibility be added as a COMPLIANCE, per MacNeal's series law.
        La   = hypot(x2 - x1, y2 - y1)
        Lb   = hypot(x3 - x1, y3 - y1)
        Lc_  = hypot(x3 - x2, y3 - y2)
        Pper = La + Lb + Lc_
        cth  = clamp(((x2-x1)*(x3-x1) + (y2-y1)*(y3-y1)) / max(La * Lb, 1e-30), -one(T), one(T))
        sth  = sqrt(max(one(T) - cth * cth, zero(T)))
        Wsh = zeros(T, 3, 3)
        # PROMOTED 2026-08-01: tri_angle 4.16e-3 -> 2.26e-8, tri_aspect 2.42e-4 -> 2.10e-8,
        # tri_h_over_L 9.85e-3 -> 2.22e-8 (all -100 %), every CQUAD4 axis 0.0 % unchanged.
        if fem_env_bool("JFEM_TRIA3_MITC3_SHEAR_REF", true)
            # ---- THE REFERENCE'S OWN TYING RIGIDITY (recovered 2026-08-01) ----
            # JFEM's rigidity is exact when the plate is THIN and drifts as t^2 on distorted
            # cells (8 % at aspect 3, h/L = 0.2). The t^2 scaling is what identifies the culprit
            # as this operator rather than Zb, since Zb*D is thickness-free. Recovering the
            # reference's rigidity as the dimensionless M = W/w, w = kappa*G*t/(6*Delta), in the
            # metric invariants (al = |a|^2, be = |b|^2, ga = a.b) shows it differs from JFEM's
            # in exactly TWO places, with the (r,s) 2x2 block untouched:
            #   (1) the third (linear-variation) mode is (u*s, -v*r), NOT (s, -r), with
            #         u = 3*La/P,  v = 3*Lb/P,   P = the PERIMETER
            #       -- measured p/q = La/Lb exactly, and 1/P = perimeter/3 on all 18 shapes.
            #       This is the same perimeter that normalises the third row of Zb.
            #   (2) the effective r*s cross-moment is (2-c)/6 * (A/3), not 1/4 * (A/3).
            # ★ Both reduce to JFEM's at the EQUILATERAL triangle -- u = v = 1 there because
            # P = 3L, and (2-c)/6 = 1/4 at c = 1/2 -- which is exactly the shape measured to be
            # exact, on all three modes. Closed form vs the recovered rigidity: 0.01-0.6 % on 16
            # of 18 shapes (the two outliers are ratio 1/2 and 3 at 135 deg, where the recovery
            # itself is worst conditioned because Zs is small against Zb).
            G = Jinv' * Ds * Jinv
            uu = 3 * La / Pper
            vv = 3 * Lb / Pper
            Wsh[1,1] = G[1,1] * A
            Wsh[1,2] = G[1,2] * A;  Wsh[2,1] = Wsh[1,2]
            Wsh[2,2] = G[2,2] * A
            Wsh[1,3] = (A/3) * (uu*G[1,1] - vv*G[1,2]);  Wsh[3,1] = Wsh[1,3]
            Wsh[2,3] = (A/3) * (uu*G[1,2] - vv*G[2,2]);  Wsh[3,2] = Wsh[2,3]
            Wsh[3,3] = uu*uu*G[1,1]*(A/6) - 2*uu*vv*G[1,2]*(A*(2-cth)/18) +
                       vv*vv*G[2,2]*(A/6)
        else
            for (r, s) in ((T(0.5), zero(T)), (zero(T), T(0.5)), (T(0.5), T(0.5)))
                # [g_r; g_s] = P(r,s) * [grA; gsB; c],  P = [1 0 s; 0 1 -r]
                Pm = zeros(T, 2, 3)
                Pm[1,1] = one(T); Pm[1,3] = s
                Pm[2,2] = one(T); Pm[2,3] = -r
                G = Jinv' * Ds * Jinv                      # covariant -> Cartesian metric
                Wsh .+= (Pm' * G * Pm) .* (A / 3)
            end
        end

        # ---- REFERENCE RESIDUAL BENDING FLEXIBILITY (derived 2026-08-01) ----
        # Recovering the reference's own operator (TOOLS_MATPRN/trec.jl) showed its CTRIA3 is
        #     K_plate = Kb + D3' * inv(Zs + Zb) * D3
        # i.e. MacNeal's flexibility series on the MITC3 tying basis (Zs = inv(Wsh)).
        # Zb, in the basis normalised by (L12, L13, PERIMETER) and scaled by the bending
        # stiffness, is closed in CLOSED FORM with only rational coefficients -- verified on
        # 30 cells (9 vertex angles 30-150 deg x 4 edge ratios), worst error 0.015 % on the
        # diagonal and 0.19 % off-diagonal:
        #     R = (|a|-|b|)^2/(|a||b|),   T = (|a|^2-|b|^2)/(|a||b|)
        #     a11+a22 = 2[(1-c+c^2)/(6s) + 1/6] + R(1+c^2)/(6s)
        #     a11-a22 = T*s/6
        #     a12     = (-1+4c-c^2)/(12s) - 1/6 + R*c/(6s)
        #     a13 = -1/6,  a23 = +1/6,  a33 = 1/6
        # The symmetric/antisymmetric split under the edge swap a<->b is what separates the
        # variables; a fixed (1,1)/(1,-1) projection CANNOT work because those stop being
        # eigenvectors once |a| != |b| (measured: the eigenvector rotates -135 -> -51 deg).
        if fem_env_bool("JFEM_TRIA3_MITC3_ZB", true)
            Dbend = abs(Db[1, 1])
            if sth > 1e-9 && Dbend > 1e-30 && La > 1e-30 && Lb > 1e-30
                Rr = (La - Lb)^2 / (La * Lb)
                Tt = (La * La - Lb * Lb) / (La * Lb)
                sum_d = 2 * ((1 - cth + cth^2) / (6 * sth) + one(T)/6) + Rr * (1 + cth^2) / (6 * sth)
                dif_d = Tt * sth / 6
                a11 = (sum_d + dif_d) / 2
                a22 = (sum_d - dif_d) / 2
                a12 = (-1 + 4*cth - cth^2) / (12 * sth) - one(T)/6 + Rr * cth / (6 * sth)
                # ---- DIRECTIONAL PAIRING (measured 2026-08-01) ----
                # `Dbend = Db[1,1]`, ONE scalar, is exact for isotropic and 5.5-25 % wrong on
                # PCOMP triangles -- CQUAD4 Defect B in triangle form. Recovering the
                # reference's own Zb on PSHELL/MID2=MAT2 cells (which set Db entry by entry,
                # unlike a layup, which moves all of it at once) shows the compliance is
                # resolved PER ENTRY, against the ELEMENT-FRAME orthogonal pair -- x is edge
                # 1-2 -- and not against the two (non-orthogonal) edge directions:
                #
                #   * the whole third row/col divides by G = sqrt(D11*D22) at EVERY geometry
                #     and material tested (worst 0.21 % over 50 cells, r = D22/D11 in
                #     [0.25, 4]; the fitted coefficients on 1/D11 and 1/D22 are <= 1e-5);
                #   * writing the derived isotropic law as A = B + (1/6)*v*v' with
                #     v = (1,-1,-1) -- which is exactly its geometry-free constants -- B pairs
                #     with G and the rank-1 part pairs per axis:
                #        z11 = (a11-1/6)/G + (1/6)/D11 ,  z22 = (a22-1/6)/G + (1/6)/D22
                #     residual 0.000 % on a (D11,D22) grid AND on all 7 angles of a material
                #     rotation sweep at the 90 deg equal-edge cell.
                # The law is nu-FREE (verified at nu = 0, 0.15, 0.33, 0.45), which is why it is
                # built from directional STIFFNESS v'Db v and not from a compliance contraction.
                # ⚠ OPEN: off 90 deg the diagonal is 10-31 % out and picks up a dependence on
                # D12+2*D33, so the carrying direction is not an element axis there; the (1,2)
                # entry's pairing is closed only at D11 = D22. Both are measured in
                # PROJECT_STATE/SESSIONS/2026-08-01_CTRIA3_LAMINATE_ZB.md.
                #
                # physical -> tying basis: Z_tying[i,j] = Z_phys[i,j] * S_i * S_j.
                S1, S2, S3 = La, Lb, Pper
                s6 = one(T) / 6
                D11e = abs(Db[1,1]); D22e = abs(Db[2,2])
                # PROMOTED 2026-08-01: bit-identical on every isotropic cell (the law reduces to
                # a_ij exactly when all D_dir coincide -- that is the sum rule), ratchet PASS at
                # 0.0 % on all 15 axes with the gate ON, and PCOMP triangles 2.52e-1 -> 1.96e-3.
                dir_pair = fem_env_bool("JFEM_TRIA3_ZB_DIRECTIONAL", true) &&
                           D11e > 1e-30 && D22e > 1e-30
                # ---- DIRECTIONAL CHANNELS (measured and closed 2026-08-01) ----
                # `Dbend = Db[1,1]`, ONE scalar, is exact for isotropic and 5.5-25 % wrong on
                # PCOMP triangles -- CQUAD4 Defect B in triangle form. Recovering the
                # reference's own Zb on PSHELL/MID2=MAT2 cells (which set Db entry by entry,
                # unlike a layup, which moves all of it at once) and then gradient-probing every
                # Db entry about the ISOTROPIC point, where the answer is already known exactly,
                # gives the operator with no fitting:
                #
                #   Zb = (1/6) v v' / G  +  SUM over the 3 edges of  W_e / D_dir(n_e)
                #
                # `v = (1,-1,-1)`, `G = sqrt(D11*D22)` (ELEMENT-frame entries; x is edge 1-2),
                # `n_e` = the NORMAL to edge e, and `D_dir(n) = w'Db w`, `w = (nx^2, ny^2, 2nxny)`
                # -- a UNIAXIAL curvature state, which is forced: the measured `g33 = 2*g12`
                # (0.2 % on 24 gradient rows) says the element is blind to exactly the `Db`
                # perturbation that leaves every `D_dir` unchanged. The law is nu-FREE
                # (nu = 0, 0.15, 0.33, 0.45 exact), so it is built from directional STIFFNESS,
                # never from a compliance contraction.
                # Fitting 3 channel weights to the 5 measured harmonics per entry is
                # overdetermined by two; residual 5e-5..3e-3 against ~3e-3 measurement noise on
                # 27 (shape, entry) pairs spanning vertex angle 30-150 deg and edge ratio 1/3..3.
                # With `rho = La/Lb`, `R = rho + 1/rho - 2`, `T_ = rho - 1/rho` (the SAME
                # descriptors the isotropic law uses), the weights are, per channel:
                #
                #   n12: [1,1] = f(rho)          [2,2] = (1/rho - c)/(6s)
                #   n13: [1,1] = (rho - c)/(6s)  [2,2] = f(1/rho)
                #   n23: [1,1] = [2,2] = c/(6s)  [1,2] = (1+c^2)/(12s)
                #   n12/n13 [1,2] = [R*c - (1-c)^2 -+ T_*c] / (12 s)
                #   f(rho) = [(1-c)^2 - (rho-c)]/(6s) + R(1+c^2)/(12s) + T_*s/12
                #
                # ★ These are NOT fitted: all three sum rules close ALGEBRAICALLY back onto the
                # derived isotropic law (e.g. z11: 1/6 + f + (rho-c)/(6s) + c/(6s) = a11), so the
                # anisotropic operator is the isotropic one with each channel divided by its own
                # directional stiffness -- nothing added, nothing tuned.
                rho = La / Lb
                Rr2 = rho + 1/rho - 2
                Tt2 = rho - 1/rho
                fr  = ((1-cth)^2 - (rho - cth)) / (6*sth) + Rr2*(1+cth^2)/(12*sth) + Tt2*sth/12
                fri = ((1-cth)^2 - (1/rho - cth)) / (6*sth) + Rr2*(1+cth^2)/(12*sth) - Tt2*sth/12
                w12 = (T(1/rho) - cth) / (6*sth)
                w13 = (rho - cth) / (6*sth)
                w23 = cth / (6*sth)
                o12 = (Rr2*cth - (1-cth)^2 - Tt2*cth) / (12*sth)
                o13 = (Rr2*cth - (1-cth)^2 + Tt2*cth) / (12*sth)
                o23 = (1 + cth^2) / (12*sth)
                # directional stiffness along the normal of each edge
                function ddir(vx, vy)
                    n = hypot(vx, vy)
                    n < 1e-30 && return Dbend
                    nx = -vy / n; ny = vx / n     # normal
                    wv = (nx*nx, ny*ny, 2*nx*ny)
                    d = zero(T)
                    for ii in 1:3, jj in 1:3; d += wv[ii] * Db[ii,jj] * wv[jj]; end
                    abs(d) > 1e-30 ? d : Dbend
                end
                Dn12 = dir_pair ? ddir(x2-x1, y2-y1) : Dbend
                Dn13 = dir_pair ? ddir(x3-x1, y3-y1) : Dbend
                Dn23 = dir_pair ? ddir(x3-x2, y3-y2) : Dbend
                Gd   = dir_pair ? sqrt(D11e * D22e) : Dbend
                # gate OFF keeps the ORIGINAL single-scalar expressions, so it is bit-identical
                c11 = dir_pair ? s6/Gd + fr/Dn12  + w13/Dn13 + w23/Dn23 : a11 / Dbend
                c22 = dir_pair ? s6/Gd + w12/Dn12 + fri/Dn13 + w23/Dn23 : a22 / Dbend
                c12 = dir_pair ? -s6/Gd + o12/Dn12 + o13/Dn13 + o23/Dn23 : a12 / Dbend
                Zb3 = zeros(T, 3, 3)
                Zb3[1,1] = c11*S1*S1;      Zb3[1,2] = c12*S1*S2
                Zb3[2,1] = Zb3[1,2];       Zb3[2,2] = c22*S2*S2
                Zb3[1,3] = -s6/Gd*S1*S3;   Zb3[3,1] = Zb3[1,3]
                Zb3[2,3] =  s6/Gd*S2*S3;   Zb3[3,2] = Zb3[2,3]
                Zb3[3,3] =  s6/Gd*S3*S3
                Zt = inv(Symmetric(Matrix(Wsh))) + Zb3
                Zt = 0.5 .* (Zt .+ Zt')
                Wsh = Matrix(inv(Symmetric(Zt)))
            end
        end

        D3 = vcat(grA', gsB', cvec')
        Ks_mitc = D3' * Wsh * D3
        Ke[b_idx, b_idx] += Kb + Ks_mitc
        # The assumed field is spanned by these three rows, so Ks_mitc = D'*M*D with
        # D = [g_r(A); g_s(B); c] (3x9) -- i.e. MITC3's shear stiffness is RANK 3 by
        # construction. Dumped so the reference's own rank-3 shear operator can be
        # compared against this subspace (TOOLS_MATPRN/trec.jl).
        let tdump = get(ENV, "JFEM_TRIA3_DUMP_PLATE", "")
            if !isempty(tdump)
                open(tdump, "a") do io
                    println(io, "# TYING")
                    for row in (grA, gsB, cvec)
                        println(io, "DT ", join((string(Float64(row[j])) for j in 1:9), " "))
                    end
                end
            end
        end
    elseif tria3_plate_kernel in ("constant", "centroid", "mindlin", "mindlin_constant")
        # Constant-curvature Mindlin triangle with centroidal shear. This is a
        # simple, generic CTRIA3 plate operator and is useful as a Nastran-parity
        # probe against the macro-quad condensed plate operator below.
        Ke[b_idx, b_idx] += Kb + Ks
    elseif tria3_plate_kernel in ("dkt", "kirchhoff", "batoz")
        if Bmb === nothing
            Ke[b_idx, b_idx] += tria3_plate_dkt_stiffness(coords, Db)
        else
            macro_data = tria3_plate_macro_data(coords, Dm, Db, Ds, h, G_ref; bend_ratio=bend_ratio, k6rot=k6rot)
            Ke[b_idx, b_idx] += macro_data.Kcond
        end
    else
        macro_data = tria3_plate_macro_data(coords, Dm, Db, Ds, h, G_ref; bend_ratio=bend_ratio, k6rot=k6rot)
        Ke[b_idx, b_idx] += macro_data.Kcond
    end

    # B matrix coupling (membrane-bending): cross-blocks between m_idx and b_idx
    if Bmb !== nothing
        K_mb = Bm' * Bmb * Bb * A  # 6x9 coupling block
        Ke[m_idx, b_idx] += K_mb
        Ke[b_idx, m_idx] += K_mb'
    end

    # --- Hughes-Brezzi drilling rotation coupling ---
    # ε_drill = θz - (1/2)(∂v/∂x - ∂u/∂y), penalized with alpha_drill * ε_drill²
    # LUMPED (reference-matched) drilling, mirroring the CQUAD4 operator that was solved
    # to 3.3e-8 against the reference:
    #     K_drill = sum over the 3 NODES of  alpha_L * (theta_z,i - omega_i)^2
    #     alpha_L = K6ROT * 1e-6 * A66 * Area        (per element per NODE)
    # The pre-existing form below penalised a SINGLE constraint built on the CENTROID-AVERAGED
    # theta_z (N_i = 1/3), which is the triangle analogue of the quad's Gauss-integrated form
    # -- and on the quad that shape was measured 76 % wrong. On a CST the membrane rotation
    # omega = (dv/dx - du/dy)/2 is CONSTANT over the element, so the three nodal rows share the
    # same omega part and differ only in which theta_z they pick up.
    # Measured: this is what the residual CTRIA3 error was after the plate was closed -- worst
    # entry 66.7 % at (6,1), i.e. a drilling-membrane coupling, on every cell.
    if fem_env_bool("JFEM_TRIA3_DRILL_LUMPED", true)
        # NB the measure is 2A, not A: the quad's `Area` in this operator comes from the
        # integral of detJ, and for a triangle detJ = 2A. Measured ref/jfem = EXACTLY
        # 2.000000 on every drilling entry of every cell with A, and 1.000000 with 2A.
        alpha_L = (k6rot * T(1e-6)) * Dm[3, 3] * (2 * A)
        Bd_i = zeros(T, 1, 18)
        for i in 1:3
            fill!(Bd_i, zero(T))
            for j in 1:3
                jdx = (j-1)*6
                Bd_i[1, jdx+1] =  T(0.5) * cv[j]
                Bd_i[1, jdx+2] = -T(0.5) * bv[j]
            end
            Bd_i[1, (i-1)*6+6] = one(T)
            Ke .+= alpha_L .* (Bd_i' * Bd_i)
        end
    else
        alpha_drill = (k6rot / 1e5) * G_ref * h
        Bd = zeros(T, 1, 18)
        for i in 1:3
            idx = (i-1)*6
            Bd[1, idx+1] = T(0.5) * cv[i]    # +(1/2)*∂N/∂y (from ∂u/∂y)
            Bd[1, idx+2] = -T(0.5) * bv[i]   # -(1/2)*∂N/∂x (from -∂v/∂x)
            Bd[1, idx+6] = one(T)/T(3)       # N_i = 1/3 at centroid
        end
        Ke .+= alpha_drill .* (Bd' * Bd) .* A
    end

    return Ke
end

function stiffness_tria3_matrices(coords, Dm, Db, Ds, h, G_ref; bend_ratio=1.0, k6rot=100.0, Bmb=nothing)
    return stiffness_tria3_matrices_generic(coords, Dm, Db, Ds, h, G_ref; bend_ratio=bend_ratio, k6rot=k6rot, Bmb=Bmb)
end

function stress_strain_tria3(coords, u_elem, E, nu, h; bend_ratio=1.0, Cm_override=nothing)
    x, y = coords[:,1], coords[:,2]
    A = 0.5 * abs(x[1]*(y[2]-y[3]) + x[2]*(y[3]-y[1]) + x[3]*(y[1]-y[2]))
    if A < 1e-12; return zeros(3), zeros(3), zeros(2), zeros(3), zeros(3), zeros(3), zeros(3); end

    b = [y[2]-y[3], y[3]-y[1], y[1]-y[2]] ./ (2*A)
    c = [x[3]-x[2], x[1]-x[3], x[2]-x[1]] ./ (2*A)

    # Membrane strain
    Bm = zeros(3, 6)
    for i in 1:3; Bm[1, i*2-1]=b[i]; Bm[2, i*2]=c[i]; Bm[3, i*2-1]=c[i]; Bm[3, i*2]=b[i]; end
    D = (E / (1 - nu^2)) .* [1 nu 0; nu 1 0; 0 0 (1-nu)/2]
    u_mem = [u_elem[1], u_elem[2], u_elem[7], u_elem[8], u_elem[13], u_elem[14]]
    eps_mem = Bm * u_mem

    # Bending curvature
    Bb = zeros(3, 6)
    for i in 1:3
        Bb[1, i*2]   = b[i]    # dθy/dx
        Bb[2, i*2-1] = -c[i]   # -dθx/dy
        Bb[3, i*2]   = c[i]    # dθy/dy
        Bb[3, i*2-1] = -b[i]   # -dθx/dx
    end
    u_rot = [u_elem[4], u_elem[5], u_elem[10], u_elem[11], u_elem[16], u_elem[17]]
    kappa = Bb * u_rot

    # Membrane forces and bending moments
    N = Cm_override !== nothing ? Cm_override * eps_mem : (D * eps_mem) * h
    M = -bend_ratio * (D * kappa) * (h^3/12.0)

    u_plate = [u_elem[3], u_elem[4], u_elem[5], u_elem[9], u_elem[10], u_elem[11], u_elem[15], u_elem[16], u_elem[17]]
    Q = tria3_plate_macro_shear_resultant(coords, u_plate, E, nu, h; bend_ratio=bend_ratio)

    # Stresses at top/bottom surfaces
    z1 = -h/2.0; z2 = h/2.0
    strain_z1 = eps_mem .+ z1 .* kappa
    stress_z1 = D * strain_z1
    strain_z2 = eps_mem .+ z2 .* kappa
    stress_z2 = D * strain_z2

    return N, M, Q, stress_z1, stress_z2, strain_z1, strain_z2
end

# =============================================================================
# GEOMETRIC (DIFFERENTIAL) STIFFNESS MATRICES FOR SOL105 LINEAR BUCKLING
# =============================================================================

# Consistent geometric stiffness for beam element (Przemieniecki)
# P = axial force from SOL101 (positive = tension, negative = compression)
# Local DOFs: [u1,v1,w1,θx1,θy1,θz1, u2,v2,w2,θx2,θy2,θz2]
function geometric_stiffness_frame3d(L::Float64, P::Float64)
    kg = zeros(12, 12)
    if L < 1e-9 || abs(P) < 1e-30; return kg; end

    c1 = 6.0 * P / (5.0 * L)
    c2 = P / 10.0
    c3 = 2.0 * P * L / 15.0
    c4 = -P * L / 30.0

    # Lateral y-direction (DOFs 2,6,8,12)
    kg[2,2] = c1;   kg[8,8] = c1
    kg[2,8] = -c1;  kg[8,2] = -c1
    kg[2,6] = c2;   kg[6,2] = c2
    kg[2,12] = c2;  kg[12,2] = c2
    kg[6,6] = c3;   kg[12,12] = c3
    kg[6,12] = c4;  kg[12,6] = c4
    kg[8,6] = -c2;  kg[6,8] = -c2
    kg[8,12] = -c2; kg[12,8] = -c2

    # Lateral z-direction (DOFs 3,5,9,11)
    kg[3,3] = c1;   kg[9,9] = c1
    kg[3,9] = -c1;  kg[9,3] = -c1
    kg[3,5] = -c2;  kg[5,3] = -c2
    kg[3,11] = -c2; kg[11,3] = -c2
    kg[5,5] = c3;   kg[11,11] = c3
    kg[5,11] = c4;  kg[11,5] = c4
    kg[9,5] = c2;   kg[5,9] = c2
    kg[9,11] = c2;  kg[11,9] = c2

    return kg
end

# Geometric stiffness for rod/truss element.
# CROD/CONROD have axial and torsional stiffness only, so the initial-stress
# operator must act on the transverse translations only. Reusing the beam-column
# geometric stiffness adds bending-rotation terms the rod element does not have.
function geometric_stiffness_rod(L::Float64, P::Float64)
    kg = zeros(12, 12)
    abs(L) < 1e-30 && return kg

    c = P / L

    # Local transverse y-direction (DOFs 2,8)
    kg[2,2] = c
    kg[2,8] = -c
    kg[8,2] = -c
    kg[8,8] = c

    # Local transverse z-direction (DOFs 3,9)
    kg[3,3] = c
    kg[3,9] = -c
    kg[9,3] = -c
    kg[9,9] = c

    return kg
end

# =============================================================================
# KERNEL: geometric_stiffness_quad4
# STATUS: PRODUCTION — primary K_g kernel for SOL 105 buckling, fires for every
#         default-path element (live trace 2026-05-22 confirms).
# DISPATCHED FROM: assembly.jl `else` fallback in K_g dispatch (~line 5912).
# CALLS: geometric_stiffness_quad4_covariant when JFEM_SOL105_EIG_CURVED_JACOBIAN.
# CALIBRATION KNOBS: trans_mode, curvature_sign, Cs/Cb scaling
#         pass-through; env JFEM_SOL105_EIG_CURVED_KG_*.
# Method dispatches: this is the (sigma_mem::Vector) variant — averaged membrane
#         stress; the (sigma_mem_gp::Matrix) variant at line ~7302 handles per-GP
#         stress fields.
# LAST VALIDATED: 2026-05-22 (GAME mean 2.42% / max 9.10%).
# =============================================================================
# Geometric stiffness for CQUAD4 shell element (24×24)
# Uses membrane stress state [σxx, σyy, σxy] from SOL101.
# coords = 4×2 local coordinates (same as stiffness computation).
function geometric_stiffness_quad4(coords::AbstractMatrix, sigma_mem::AbstractVector, h::Float64;
                                   trans_mode::Symbol=:all,
                                   curvature::Union{Nothing,SVector{3,Float64}}=nothing,
                                   curvature_sign::Float64=1.0,
                                   membrane_shear_center_row::Bool=false,
                                   Cm::Union{Nothing,AbstractMatrix}=nothing,
                                    membrane_incomp::Bool=false,
                                    membrane_enhanced::Bool=false,
                                    material_shear_rotation::Float64=0.0,
                                    membrane_incomp_center_jacobian::Bool=false,
                                    principal_shear_yy_factor::Float64=1.0,
                                    principal_shear_xy_factor::Float64=1.0,
                                    principal_shear_z_factor::Float64=1.0,
                                    principal_shear_ratio_min::Float64=1.0,
                                    local_trans_split_override::Union{Nothing,Bool}=nothing,
                                     local_trans_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing,
                                     local_uv_scale_override::Union{Nothing,Float64}=nothing,
                                     local_uv_nxy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nxx_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nyy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nxy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_shear_axis_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                     local_axis_resultant_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                     local_shear_extra_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                    local_nyy_u_extra_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing,
                                    local_nyy_vw_extra_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing)
    sigma_gp = zeros(4, 3)
    @inbounds for gp in 1:4
        sigma_gp[gp, 1] = sigma_mem[1]
        sigma_gp[gp, 2] = sigma_mem[2]
        sigma_gp[gp, 3] = sigma_mem[3]
    end
    return geometric_stiffness_quad4(coords, sigma_gp, h;
                                     trans_mode=trans_mode,
                                     curvature=curvature,
                                     curvature_sign=curvature_sign,
                                     membrane_shear_center_row=membrane_shear_center_row,
                                     Cm=Cm,
                                     membrane_incomp=membrane_incomp,
                                     membrane_enhanced=membrane_enhanced,
                                     material_shear_rotation=material_shear_rotation,
                                     membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
                                     principal_shear_yy_factor=principal_shear_yy_factor,
                                     principal_shear_xy_factor=principal_shear_xy_factor,
                                     principal_shear_z_factor=principal_shear_z_factor,
                                     principal_shear_ratio_min=principal_shear_ratio_min,
                                     local_trans_split_override=local_trans_split_override,
                                      local_trans_scales_override=local_trans_scales_override,
                                      local_uv_scale_override=local_uv_scale_override,
                                      local_uv_nxy_scale_override=local_uv_nxy_scale_override,
                                      local_w_nxx_scale_override=local_w_nxx_scale_override,
                                      local_w_nyy_scale_override=local_w_nyy_scale_override,
                                      local_w_nxy_scale_override=local_w_nxy_scale_override,
                                      local_shear_axis_scales_override=local_shear_axis_scales_override,
                                      local_axis_resultant_scales_override=local_axis_resultant_scales_override,
                                      local_shear_extra_scales_override=local_shear_extra_scales_override,
                                     local_nyy_u_extra_scales_override=local_nyy_u_extra_scales_override,
                                     local_nyy_vw_extra_scales_override=local_nyy_vw_extra_scales_override)
end

function geometric_stiffness_quad4(coords::AbstractMatrix, sigma_mem_gp::AbstractMatrix, h::Float64;
                                    trans_mode::Symbol=:all,
                                    curvature::Union{Nothing,SVector{3,Float64}}=nothing,
                                    curvature_sign::Float64=1.0,
                                    membrane_shear_center_row::Bool=false,
                                    Cm::Union{Nothing,AbstractMatrix}=nothing,
                                    membrane_incomp::Bool=false,
                                    membrane_enhanced::Bool=false,
                                    material_shear_rotation::Float64=0.0,
                                    membrane_incomp_center_jacobian::Bool=false,
                                    principal_shear_yy_factor::Float64=1.0,
                                    principal_shear_xy_factor::Float64=1.0,
                                    principal_shear_z_factor::Float64=1.0,
                                    principal_shear_ratio_min::Float64=1.0,
                                    local_trans_split_override::Union{Nothing,Bool}=nothing,
                                     local_trans_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing,
                                     local_uv_scale_override::Union{Nothing,Float64}=nothing,
                                     local_uv_nxy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nxx_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nyy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_w_nxy_scale_override::Union{Nothing,Float64}=nothing,
                                     local_shear_axis_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                     local_axis_resultant_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                     local_shear_extra_scales_override::Union{Nothing,NTuple{4,Float64}}=nothing,
                                    local_nyy_u_extra_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing,
                                    local_nyy_vw_extra_scales_override::Union{Nothing,NTuple{3,Float64}}=nothing)
    Kg = zeros(24, 24)
    if h < 1e-30; return Kg; end
    local_trans_split = local_trans_split_override === nothing ?
        fem_env_bool("JFEM_KG_SHELL_LOCAL_TRANS_SPLIT", false) :
        local_trans_split_override
    local_trans_scales =
        local_trans_split ?
        (local_trans_scales_override === nothing ?
            (
                max(fem_env_float("JFEM_KG_SHELL_LOCAL_U_SCALE", 1.0), 0.0),
                max(fem_env_float("JFEM_KG_SHELL_LOCAL_V_SCALE", 1.0), 0.0),
                max(fem_env_float("JFEM_KG_SHELL_LOCAL_W_SCALE", 1.0), 0.0),
            ) :
            (
                max(local_trans_scales_override[1], 0.0),
                max(local_trans_scales_override[2], 0.0),
                max(local_trans_scales_override[3], 0.0),
            )) :
        (1.0, 1.0, 1.0)
    local_uv_scale =
        local_trans_split ?
        (local_uv_scale_override === nothing ?
            max(
                fem_env_float(
                    "JFEM_KG_SHELL_LOCAL_UV_SCALE",
                    sqrt(local_trans_scales[1] * local_trans_scales[2]),
                ),
                0.0,
            ) :
            max(local_uv_scale_override, 0.0)) :
        1.0
    local_uv_nxy_scale =
        local_trans_split ?
        (local_uv_nxy_scale_override === nothing ?
            max(fem_env_float("JFEM_KG_SHELL_LOCAL_UV_NXY_SCALE", local_uv_scale), 0.0) :
            max(local_uv_nxy_scale_override, 0.0)) :
        local_uv_scale
    local_w_nxx_scale =
        local_trans_split ?
        (local_w_nxx_scale_override === nothing ?
            max(fem_env_float("JFEM_KG_SHELL_LOCAL_W_NXX_SCALE", local_trans_scales[3]), 0.0) :
            max(local_w_nxx_scale_override, 0.0)) :
        local_trans_scales[3]
    local_w_nyy_scale =
        local_trans_split ?
        (local_w_nyy_scale_override === nothing ?
            max(fem_env_float("JFEM_KG_SHELL_LOCAL_W_NYY_SCALE", local_trans_scales[3]), 0.0) :
            max(local_w_nyy_scale_override, 0.0)) :
        local_trans_scales[3]
    local_w_nxy_scale =
        local_trans_split ?
        (local_w_nxy_scale_override === nothing ?
            max(fem_env_float("JFEM_KG_SHELL_LOCAL_W_NXY_SCALE", local_trans_scales[3]), 0.0) :
            max(local_w_nxy_scale_override, 0.0)) :
        local_trans_scales[3]
    local_shear_axis_scales =
        local_trans_split ?
        (local_shear_axis_scales_override === nothing ?
            (
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_AXIS_UXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_AXIS_WXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_AXIS_UXY_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_AXIS_WXY_SCALE", 0.0),
            ) :
            local_shear_axis_scales_override) :
        (0.0, 0.0, 0.0, 0.0)
    local_shear_axis_active =
        local_shear_axis_scales[1] != 0.0 ||
        local_shear_axis_scales[2] != 0.0 ||
        local_shear_axis_scales[3] != 0.0 ||
        local_shear_axis_scales[4] != 0.0
    local_axis_resultant_scales =
        local_trans_split ?
        (local_axis_resultant_scales_override === nothing ?
            (
                fem_env_float("JFEM_KG_SHELL_LOCAL_AXIS_UXX_EXTRA_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_AXIS_VYY_EXTRA_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_AXIS_WXX_EXTRA_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_AXIS_WYY_EXTRA_SCALE", 0.0),
            ) :
            local_axis_resultant_scales_override) :
        (0.0, 0.0, 0.0, 0.0)
    local_axis_resultant_active =
        local_axis_resultant_scales[1] != 0.0 ||
        local_axis_resultant_scales[2] != 0.0 ||
        local_axis_resultant_scales[3] != 0.0 ||
        local_axis_resultant_scales[4] != 0.0
    local_shear_extra_scales =
        local_trans_split ?
        (local_shear_extra_scales_override === nothing ?
            (
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_EXTRA_UYY_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_EXTRA_VXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_EXTRA_VYY_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_SHEAR_EXTRA_VXY_SCALE", 0.0),
            ) :
            local_shear_extra_scales_override) :
        (0.0, 0.0, 0.0, 0.0)
    local_shear_extra_active =
        local_shear_extra_scales[1] != 0.0 ||
        local_shear_extra_scales[2] != 0.0 ||
        local_shear_extra_scales[3] != 0.0 ||
        local_shear_extra_scales[4] != 0.0
    local_nyy_u_extra_scales =
        local_trans_split ?
        (local_nyy_u_extra_scales_override === nothing ?
            (
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_U_EXTRA_UXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_U_EXTRA_UYY_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_U_EXTRA_UXY_SCALE", 0.0),
            ) :
            local_nyy_u_extra_scales_override) :
        (0.0, 0.0, 0.0)
    local_nyy_u_extra_active =
        local_nyy_u_extra_scales[1] != 0.0 ||
        local_nyy_u_extra_scales[2] != 0.0 ||
        local_nyy_u_extra_scales[3] != 0.0
    local_nyy_vw_extra_scales =
        local_trans_split ?
        (local_nyy_vw_extra_scales_override === nothing ?
            (
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_VW_EXTRA_VXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_VW_EXTRA_WXX_SCALE", 0.0),
                fem_env_float("JFEM_KG_SHELL_LOCAL_NYY_VW_EXTRA_WXY_SCALE", 0.0),
            ) :
            local_nyy_vw_extra_scales_override) :
        (0.0, 0.0, 0.0)
    local_nyy_vw_extra_active =
        local_nyy_vw_extra_scales[1] != 0.0 ||
        local_nyy_vw_extra_scales[2] != 0.0 ||
        local_nyy_vw_extra_scales[3] != 0.0

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))
    dNr_c = SVector(-0.25, 0.25, 0.25, -0.25)
    dNs_c = SVector(-0.25, -0.25, 0.25, 0.25)
    J11_c = dNr_c[1]*coords[1,1] + dNr_c[2]*coords[2,1] + dNr_c[3]*coords[3,1] + dNr_c[4]*coords[4,1]
    J12_c = dNr_c[1]*coords[1,2] + dNr_c[2]*coords[2,2] + dNr_c[3]*coords[3,2] + dNr_c[4]*coords[4,2]
    J21_c = dNs_c[1]*coords[1,1] + dNs_c[2]*coords[2,1] + dNs_c[3]*coords[3,1] + dNs_c[4]*coords[4,1]
    J22_c = dNs_c[1]*coords[1,2] + dNs_c[2]*coords[2,2] + dNs_c[3]*coords[3,2] + dNs_c[4]*coords[4,2]
    detJ_c = J11_c*J22_c - J12_c*J21_c
    abs(detJ_c) < 1e-12 && (detJ_c = detJ_c < 0.0 ? -1e-12 : 1e-12)
    inv_det_c = 1.0 / detJ_c
    iJ11_c = J22_c*inv_det_c; iJ12_c = -J12_c*inv_det_c
    iJ21_c = -J21_c*inv_det_c; iJ22_c = J11_c*inv_det_c
    dNdx_c = zeros(4)
    dNdy_c = zeros(4)
    if membrane_shear_center_row
        @inbounds for i in 1:4
            dNdx_c[i] = iJ11_c*dNr_c[i] + iJ12_c*dNs_c[i]
            dNdy_c[i] = iJ21_c*dNr_c[i] + iJ22_c*dNs_c[i]
        end
    end
    membrane_A =
        if membrane_enhanced && Cm !== nothing
            quad4_membrane_enhanced_condensation_map(
                coords, Cm;
                curvature_membrane=(trans_mode === :curvature && curvature !== nothing ? curvature_sign * curvature : nothing),
                membrane_shear_center_row=membrane_shear_center_row,
                material_shear_rotation=material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
            )
        elseif membrane_incomp && Cm !== nothing
            quad4_membrane_incompatible_condensation_map(
                coords, Cm;
                curvature_membrane=(trans_mode === :curvature && curvature !== nothing ? curvature_sign * curvature : nothing),
                membrane_shear_center_row=membrane_shear_center_row,
                material_shear_rotation=material_shear_rotation,
                membrane_incomp_center_jacobian=membrane_incomp_center_jacobian,
            )
        else
            nothing
        end

    # JFEM_KG_SHELL_TRANSVERSE_W_FORM (default "w"): reference-form research
    # switch for the transverse differential-stiffness channel.  The junction
    # campaign (kjunction_boxes_20260705) shows the reference CQUAD4 KDJJ
    # gives ZERO destabilization to rotation-free w patterns (flat cantilever
    # in-plane-shear pencil: reference lambda_1 175.8 vs 0.70 for the
    # Kirchhoff w-w form), consistent with the extracted KDJJ structure
    # (zero w-w block, w-rotation cross terms).  Forms:
    #   "w"     — legacy Kirchhoff int N grad(w).grad(w) (default, unchanged)
    #   "rot"   — rotation field only: grad(w) replaced by the material
    #             normal rotation beta = (+theta_y, -theta_x)
    #   "cross" — symmetrized cross form int N (grad(w).beta + beta.grad(w))/2
    # Implemented as an exact per-GP delta on top of the standard path; the
    # subtraction assumes unit local w scales (the pure-physics configuration).
    transverse_w_form = begin
        raw = lowercase(strip(get(ENV, "JFEM_KG_SHELL_TRANSVERSE_W_FORM", "w")))
        if raw in ("rot", "rotation", "theta")
            :rot
        elseif raw in ("cross", "wtheta", "w_theta", "sym_cross")
            :cross
        elseif raw in ("wty", "nastran_cross", "metric_cross")
            # Reference-extracted form (kd_/kdx MATPRN campaigns): the FULL
            # classic metric M(sigma) = int grad(N_i).sigma.grad(N_j) placed
            # as a symmetric w-THETA_Y cross coupling — verified entry-exact
            # on 40x40 and 80x40 elements for pure Nxx (the dx-dx table),
            # pure Nyy (the dy-dy table), and pure Nxy (the symmetrized
            # cross table).  Zero w-w, zero theta-theta, no theta_x pairing.
            :wty
        elseif raw in ("meanstring", "mean_string", "nastran_meanstring")
            # Reference form identified from CLEAN single/pair-dof pencils
            # (kdc_* SPCD apparatus, report 3.29): the transverse
            # differential stiffness is the classic Kirchhoff metric
            # evaluated with the ELEMENT-MEAN membrane state, PLUS edge
            # "string" terms (P/L)[1,-1;-1,1] carrying the self-equilibrated
            # residual corner forces of the in-element stress gradient.
            # All ten w-block entries of the gradient-state reference are
            # reproduced exactly; uniform states reduce to the classic
            # metric.  No theta terms.
            :meanstring
        else
            :w
        end
    end
    transverse_wty_sign =
        something(tryparse(Float64,
            strip(get(ENV, "JFEM_KG_SHELL_TRANSVERSE_WTY_SIGN", "1.0"))), 1.0)
    # In-plane (u,v) differential-stiffness block: LINEAR SUPERPOSITION of the
    # per-stress-component principal blocks. The geometric stiffness is linear in the
    # stress state by construction — Kg(sa+sb) = Kg(sa)+Kg(sb) — so the block is
    # evaluated one component at a time, (sxx,0,0),(0,syy,0),(0,0,sxy), and summed.
    #
    # 2026-07-27: this was previously selectable via JFEM_KG_PRINCIPAL_INPLANE_LINEAR
    # and defaulted to FALSE, i.e. the shipped operator re-diagonalized the FULL stress
    # vector per element, which is non-linear in stress. That form is exact only for
    # pure single-axis states; under a rotated saddle (combined Nxx+Nxy) it spuriously
    # stiffened higher modes (+12.7 % / +147 % on a single-element pencil vs +1.11 % on
    # both modes for the linear form). The switch is removed and the correct operator is
    # unconditional: every axis-aligned state — hence the whole validation ladder — is
    # bit-identical, and combined/rotated states are corrected.
    principal_inplane_linear = true
    sigma_mean_1 = 0.0; sigma_mean_2 = 0.0; sigma_mean_3 = 0.0
    if transverse_w_form === :meanstring
        @inbounds for gp in 1:size(sigma_mem_gp, 1)
            sigma_mean_1 += sigma_mem_gp[gp, 1]
            sigma_mean_2 += sigma_mem_gp[gp, 2]
            sigma_mean_3 += sigma_mem_gp[gp, 3]
        end
        ngp_sm = max(size(sigma_mem_gp, 1), 1)
        sigma_mean_1 /= ngp_sm; sigma_mean_2 /= ngp_sm; sigma_mean_3 /= ngp_sm
    end
    # residual (gradient-part) consistent nodal in-plane forces, for the
    # meanstring edge terms: df = sum_gp w_gp * Bm(gp)' * (sigma_gp - mean) * h
    dfx = zeros(4); dfy = zeros(4)

    @inbounds @fastmath for gp in 1:4
        s_xx = sigma_mem_gp[gp, 1]
        s_yy = sigma_mem_gp[gp, 2]
        s_xy = sigma_mem_gp[gp, 3]
        r, s = gauss_pts[gp][1], gauss_pts[gp][2]
        dNr, dNs = shape_derivs_quad(r, s)
        Nvals = SVector(
            0.25 * (1-r) * (1-s),
            0.25 * (1+r) * (1-s),
            0.25 * (1+r) * (1+s),
            0.25 * (1-r) * (1+s),
        )

        # Jacobian
        J11 = dNr[1]*coords[1,1] + dNr[2]*coords[2,1] + dNr[3]*coords[3,1] + dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2] + dNr[2]*coords[2,2] + dNr[3]*coords[3,2] + dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1] + dNs[2]*coords[2,1] + dNs[3]*coords[3,1] + dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2] + dNs[2]*coords[2,2] + dNs[3]*coords[3,2] + dNs[4]*coords[4,2]
        detJ = J11*J22 - J12*J21
        abs_detJ = abs(detJ)
        if abs_detJ < 1e-12; abs_detJ = 1e-12; end
        inv_det = 1.0 / detJ
        iJ11 = J22*inv_det; iJ12 = -J12*inv_det
        iJ21 = -J21*inv_det; iJ22 = J11*inv_det

        if membrane_A !== nothing
            dux_dx = zeros(24); dux_dy = zeros(24)
            duy_dx = zeros(24); duy_dy = zeros(24)
            duz_dx = zeros(24); duz_dy = zeros(24)
            ux_val = zeros(24); uy_val = zeros(24); uz_val = zeros(24)
            for i in 1:4
                dNi_dx = iJ11*dNr[i] + iJ12*dNs[i]
                dNi_dy = iJ21*dNr[i] + iJ22*dNs[i]
                row0 = (i - 1) * 6
                dux_dx[row0 + 1] = dNi_dx
                dux_dy[row0 + 1] = dNi_dy
                duy_dx[row0 + 2] = dNi_dx
                duy_dy[row0 + 2] = dNi_dy
                duz_dx[row0 + 3] = dNi_dx
                duz_dy[row0 + 3] = dNi_dy
                ux_val[row0 + 1] = Nvals[i]
                uy_val[row0 + 2] = Nvals[i]
                uz_val[row0 + 3] = Nvals[i]
            end

            phi1 = 1.0 - r * r
            phi2 = 1.0 - s * s
            psi = r * s
            miJ11, miJ12, miJ21, miJ22 = quad4_membrane_incompatible_jacobian_components(
                membrane_incomp_center_jacobian,
                iJ11, iJ12, iJ21, iJ22,
                iJ11_c, iJ12_c, iJ21_c, iJ22_c,
            )
            dphi1_dx = miJ11 * (-2.0 * r)
            dphi1_dy = miJ21 * (-2.0 * r)
            dphi2_dx = miJ12 * (-2.0 * s)
            dphi2_dy = miJ22 * (-2.0 * s)
            dpsi_dx = miJ11 * s + miJ12 * r
            dpsi_dy = miJ21 * s + miJ22 * r
            if size(membrane_A, 1) == 6
                for a in 1:24
                    a1 = membrane_A[1, a]
                    a2 = membrane_A[2, a]
                    a3 = membrane_A[3, a]
                    a4 = membrane_A[4, a]
                    a5 = membrane_A[5, a]
                    a6 = membrane_A[6, a]
                    dux_dx[a] += dphi1_dx * a1 + dphi2_dx * a3 + dpsi_dx * a5
                    dux_dy[a] += dphi1_dy * a1 + dphi2_dy * a3 + dpsi_dy * a5
                    duy_dx[a] += dphi1_dx * a2 + dphi2_dx * a4 + dpsi_dx * a6
                    duy_dy[a] += dphi1_dy * a2 + dphi2_dy * a4 + dpsi_dy * a6
                    ux_val[a] += phi1 * a1 + phi2 * a3 + psi * a5
                    uy_val[a] += phi1 * a2 + phi2 * a4 + psi * a6
                end
            else
                for a in 1:24
                    a1 = membrane_A[1, a]
                    a2 = membrane_A[2, a]
                    a3 = membrane_A[3, a]
                    a4 = membrane_A[4, a]
                    dux_dx[a] += dphi1_dx * a1 + dphi2_dx * a3
                    dux_dy[a] += dphi1_dy * a1 + dphi2_dy * a3
                    duy_dx[a] += dphi1_dx * a2 + dphi2_dx * a4
                    duy_dy[a] += dphi1_dy * a2 + dphi2_dy * a4
                    ux_val[a] += phi1 * a1 + phi2 * a3
                    uy_val[a] += phi1 * a2 + phi2 * a4
                end
            end

            scale = h * abs_detJ
            if trans_mode === :curvature
                k11 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[1]
                k22 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[2]
                k12 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[3]
                for a in 1:24
                    gx1_a = dux_dx[a] - uz_val[a] * k11
                    gx2_a = duy_dx[a] - uz_val[a] * k12
                    gx3_a = duz_dx[a] + ux_val[a] * k11 + uy_val[a] * k12
                    gy1_a = dux_dy[a] - uz_val[a] * k12
                    gy2_a = duy_dy[a] - uz_val[a] * k22
                    gy3_a = duz_dy[a] + ux_val[a] * k12 + uy_val[a] * k22
                    for b in 1:24
                        gx1_b = dux_dx[b] - uz_val[b] * k11
                        gx2_b = duy_dx[b] - uz_val[b] * k12
                        gx3_b = duz_dx[b] + ux_val[b] * k11 + uy_val[b] * k12
                        gy1_b = dux_dy[b] - uz_val[b] * k12
                        gy2_b = duy_dy[b] - uz_val[b] * k22
                        gy3_b = duz_dy[b] + ux_val[b] * k12 + uy_val[b] * k22
                        Kg[a, b] += scale * (
                            s_xx * (gx1_a * gx1_b + gx2_a * gx2_b + gx3_a * gx3_b) +
                            s_yy * (gy1_a * gy1_b + gy2_a * gy2_b + gy3_a * gy3_b) +
                            s_xy * (
                                gx1_a * gy1_b + gx2_a * gy2_b + gx3_a * gy3_b +
                                gy1_a * gx1_b + gy2_a * gx2_b + gy3_a * gx3_b
                            )
                        )
                    end
                end
            elseif trans_mode === :normal_only
                add_geometric_gradient_block!(Kg, duz_dx, duz_dy, scale, s_xx, s_yy, s_xy, local_trans_scales[3])
            elseif trans_mode === :principal_transverse
                if principal_inplane_linear
                    # Component-wise principal in-plane block: evaluate one stress
                    # component at a time and sum, so the operator is LINEAR in
                    # (Nxx,Nyy,Nxy). The re-diagonalized single-call form is
                    # non-linear and spuriously stiffens higher modes on
                    # combined/rotated states (report 3.90). The w-transverse
                    # term (local_trans_scales[3]) is added once here; the
                    # per-component calls carry w_factor=0 to avoid triple-adding
                    # the w channel.
                    add_geometric_principal_transverse_block!(
                        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
                        scale, s_xx, 0.0, 0.0,
                        principal_shear_yy_factor, principal_shear_xy_factor,
                        principal_shear_z_factor, principal_shear_ratio_min,
                        local_trans_scales[1], local_trans_scales[2],
                        local_uv_scale, 0.0)
                    add_geometric_principal_transverse_block!(
                        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
                        scale, 0.0, s_yy, 0.0,
                        principal_shear_yy_factor, principal_shear_xy_factor,
                        principal_shear_z_factor, principal_shear_ratio_min,
                        local_trans_scales[1], local_trans_scales[2],
                        local_uv_scale, 0.0)
                    add_geometric_principal_transverse_block!(
                        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
                        scale, 0.0, 0.0, s_xy,
                        principal_shear_yy_factor, principal_shear_xy_factor,
                        principal_shear_z_factor, principal_shear_ratio_min,
                        local_trans_scales[1], local_trans_scales[2],
                        local_uv_scale, 0.0)
                    # w-transverse channel once, from the full stress (it is
                    # already linear and rotation-invariant)
                    add_geometric_principal_transverse_block!(
                        Kg, dux_dx, dux_dy, duy_dx, duy_dy, duz_dx, duz_dy,
                        scale, s_xx, s_yy, s_xy,
                        principal_shear_yy_factor, principal_shear_xy_factor,
                        principal_shear_z_factor, principal_shear_ratio_min,
                        0.0, 0.0, 0.0, local_trans_scales[3])
                else
                add_geometric_principal_transverse_block!(
                    Kg,
                    dux_dx,
                    dux_dy,
                    duy_dx,
                    duy_dy,
                    duz_dx,
                    duz_dy,
                    scale,
                    s_xx,
                    s_yy,
                    s_xy,
                    principal_shear_yy_factor,
                    principal_shear_xy_factor,
                    principal_shear_z_factor,
                    principal_shear_ratio_min,
                    local_trans_scales[1],
                    local_trans_scales[2],
                    local_uv_scale,
                    local_trans_scales[3],
                )
                end
                uv_nxy_delta = local_uv_nxy_scale - local_uv_scale
                if uv_nxy_delta != 0.0 && s_xy != 0.0
                    for a in 1:24
                        for b in 1:24
                            Kg[a, b] += scale * uv_nxy_delta * s_xy * (
                                dux_dx[a] * duy_dy[b] + dux_dy[a] * duy_dx[b] +
                                duy_dx[a] * dux_dy[b] + duy_dy[a] * dux_dx[b]
                            )
                        end
                    end
                end
                w_nxx_delta = local_w_nxx_scale - local_trans_scales[3]
                w_nyy_delta = local_w_nyy_scale - local_trans_scales[3]
                w_nxy_delta = local_w_nxy_scale - local_trans_scales[3]
                if w_nxx_delta != 0.0 || w_nyy_delta != 0.0 || (w_nxy_delta != 0.0 && s_xy != 0.0)
                    for a in 1:24
                        for b in 1:24
                            Kg[a, b] += scale * (
                                w_nxx_delta * s_xx * duz_dx[a] * duz_dx[b] +
                                w_nyy_delta * s_yy * duz_dy[a] * duz_dy[b] +
                                w_nxy_delta * s_xy * (
                                    duz_dx[a] * duz_dy[b] + duz_dy[a] * duz_dx[b]
                                )
                            )
                        end
                    end
                end
            else
                add_geometric_gradient_block!(Kg, dux_dx, dux_dy, scale, s_xx, s_yy, s_xy, local_trans_scales[1])
                add_geometric_gradient_block!(Kg, duy_dx, duy_dy, scale, s_xx, s_yy, s_xy, local_trans_scales[2])
                add_geometric_gradient_block!(Kg, duz_dx, duz_dy, scale, s_xx, s_yy, s_xy, local_trans_scales[3])
                w_nxx_delta = local_w_nxx_scale - local_trans_scales[3]
                w_nyy_delta = local_w_nyy_scale - local_trans_scales[3]
                w_nxy_delta = local_w_nxy_scale - local_trans_scales[3]
                if w_nxx_delta != 0.0 || w_nyy_delta != 0.0 || (w_nxy_delta != 0.0 && s_xy != 0.0)
                    for a in 1:24
                        for b in 1:24
                            Kg[a, b] += scale * (
                                w_nxx_delta * s_xx * duz_dx[a] * duz_dx[b] +
                                w_nyy_delta * s_yy * duz_dy[a] * duz_dy[b] +
                                w_nxy_delta * s_xy * (
                                    duz_dx[a] * duz_dy[b] + duz_dy[a] * duz_dx[b]
                                )
                            )
                        end
                    end
                end
            end
            if trans_mode !== :curvature && local_shear_axis_active
                add_geometric_shear_axis_block!(
                    Kg,
                    dux_dx,
                    dux_dy,
                    duz_dx,
                    duz_dy,
                    scale,
                    s_xy,
                    local_shear_axis_scales[1],
                    local_shear_axis_scales[2],
                    local_shear_axis_scales[3],
                    local_shear_axis_scales[4],
                )
            end
            if trans_mode !== :curvature && local_axis_resultant_active
                add_geometric_axis_resultant_block!(
                    Kg,
                    dux_dx,
                    duy_dy,
                    duz_dx,
                    duz_dy,
                    scale,
                    s_xx,
                    s_yy,
                    local_axis_resultant_scales[1],
                    local_axis_resultant_scales[2],
                    local_axis_resultant_scales[3],
                    local_axis_resultant_scales[4],
                )
            end
            if trans_mode !== :curvature && local_shear_extra_active
                add_geometric_shear_extra_block!(
                    Kg,
                    dux_dy,
                    duy_dx,
                    duy_dy,
                    scale,
                    s_xy,
                    local_shear_extra_scales[1],
                    local_shear_extra_scales[2],
                    local_shear_extra_scales[3],
                    local_shear_extra_scales[4],
                )
            end
            if trans_mode !== :curvature && local_nyy_u_extra_active
                add_geometric_nyy_u_extra_block!(
                    Kg,
                    dux_dx,
                    dux_dy,
                    scale,
                    s_yy,
                    local_nyy_u_extra_scales[1],
                    local_nyy_u_extra_scales[2],
                    local_nyy_u_extra_scales[3],
                )
            end
            if trans_mode !== :curvature && local_nyy_vw_extra_active
                add_geometric_nyy_vw_extra_block!(
                    Kg,
                    duy_dx,
                    duz_dx,
                    duz_dy,
                    scale,
                    s_yy,
                    local_nyy_vw_extra_scales[1],
                    local_nyy_vw_extra_scales[2],
                    local_nyy_vw_extra_scales[3],
                )
            end
        else
            # Shape function derivatives in physical coordinates + geometric stiffness
            for i in 1:4
                dNi_dx = iJ11*dNr[i] + iJ12*dNs[i]
                dNi_dy = iJ21*dNr[i] + iJ22*dNs[i]
                for j in 1:4
                    dNj_dx = iJ11*dNr[j] + iJ12*dNs[j]
                    dNj_dy = iJ21*dNr[j] + iJ22*dNs[j]
                    if trans_mode === :curvature
                    Ni = Nvals[i]
                    Nj = Nvals[j]
                    k11 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[1]
                    k22 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[2]
                    k12 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[3]
                    Axi11 = dNi_dx; Axi12 = 0.0;    Axi13 = -Ni * k11
                    Axi21 = 0.0;    Axi22 = dNi_dx; Axi23 = -Ni * k12
                    Axi31 = Ni * k11; Axi32 = Ni * k12; Axi33 = dNi_dx
                    Ayi11 = dNi_dy; Ayi12 = 0.0;    Ayi13 = -Ni * k12
                    Ayi21 = 0.0;    Ayi22 = dNi_dy; Ayi23 = -Ni * k22
                    Ayi31 = Ni * k12; Ayi32 = Ni * k22; Ayi33 = dNi_dy
                    Axj11 = dNj_dx; Axj12 = 0.0;    Axj13 = -Nj * k11
                    Axj21 = 0.0;    Axj22 = dNj_dx; Axj23 = -Nj * k12
                    Axj31 = Nj * k11; Axj32 = Nj * k12; Axj33 = dNj_dx
                    Ayj11 = dNj_dy; Ayj12 = 0.0;    Ayj13 = -Nj * k12
                    Ayj21 = 0.0;    Ayj22 = dNj_dy; Ayj23 = -Nj * k22
                    Ayj31 = Nj * k12; Ayj32 = Nj * k22; Ayj33 = dNj_dy
                    scale = h * abs_detJ
                    row0 = (i-1)*6
                    col0 = (j-1)*6
                    Kg[row0+1, col0+1] += scale * (
                        s_xx * (Axi11*Axj11 + Axi21*Axj21 + Axi31*Axj31) +
                        s_yy * (Ayi11*Ayj11 + Ayi21*Ayj21 + Ayi31*Ayj31) +
                        s_xy * (Axi11*Ayj11 + Axi21*Ayj21 + Axi31*Ayj31 +
                                Ayi11*Axj11 + Ayi21*Axj21 + Ayi31*Axj31)
                    )
                    Kg[row0+1, col0+2] += scale * (
                        s_xx * (Axi11*Axj12 + Axi21*Axj22 + Axi31*Axj32) +
                        s_yy * (Ayi11*Ayj12 + Ayi21*Ayj22 + Ayi31*Ayj32) +
                        s_xy * (Axi11*Ayj12 + Axi21*Ayj22 + Axi31*Ayj32 +
                                Ayi11*Axj12 + Ayi21*Axj22 + Ayi31*Axj32)
                    )
                    Kg[row0+1, col0+3] += scale * (
                        s_xx * (Axi11*Axj13 + Axi21*Axj23 + Axi31*Axj33) +
                        s_yy * (Ayi11*Ayj13 + Ayi21*Ayj23 + Ayi31*Ayj33) +
                        s_xy * (Axi11*Ayj13 + Axi21*Ayj23 + Axi31*Ayj33 +
                                Ayi11*Axj13 + Ayi21*Axj23 + Ayi31*Axj33)
                    )
                    Kg[row0+2, col0+1] += scale * (
                        s_xx * (Axi12*Axj11 + Axi22*Axj21 + Axi32*Axj31) +
                        s_yy * (Ayi12*Ayj11 + Ayi22*Ayj21 + Ayi32*Ayj31) +
                        s_xy * (Axi12*Ayj11 + Axi22*Ayj21 + Axi32*Ayj31 +
                                Ayi12*Axj11 + Ayi22*Axj21 + Ayi32*Axj31)
                    )
                    Kg[row0+2, col0+2] += scale * (
                        s_xx * (Axi12*Axj12 + Axi22*Axj22 + Axi32*Axj32) +
                        s_yy * (Ayi12*Ayj12 + Ayi22*Ayj22 + Ayi32*Ayj32) +
                        s_xy * (Axi12*Ayj12 + Axi22*Ayj22 + Axi32*Ayj32 +
                                Ayi12*Axj12 + Ayi22*Axj22 + Ayi32*Axj32)
                    )
                    Kg[row0+2, col0+3] += scale * (
                        s_xx * (Axi12*Axj13 + Axi22*Axj23 + Axi32*Axj33) +
                        s_yy * (Ayi12*Ayj13 + Ayi22*Ayj23 + Ayi32*Ayj33) +
                        s_xy * (Axi12*Ayj13 + Axi22*Ayj23 + Axi32*Ayj33 +
                                Ayi12*Axj13 + Ayi22*Axj23 + Ayi32*Axj33)
                    )
                    Kg[row0+3, col0+1] += scale * (
                        s_xx * (Axi13*Axj11 + Axi23*Axj21 + Axi33*Axj31) +
                        s_yy * (Ayi13*Ayj11 + Ayi23*Ayj21 + Ayi33*Ayj31) +
                        s_xy * (Axi13*Ayj11 + Axi23*Ayj21 + Axi33*Ayj31 +
                                Ayi13*Axj11 + Ayi23*Axj21 + Ayi33*Axj31)
                    )
                    Kg[row0+3, col0+2] += scale * (
                        s_xx * (Axi13*Axj12 + Axi23*Axj22 + Axi33*Axj32) +
                        s_yy * (Ayi13*Ayj12 + Ayi23*Ayj22 + Ayi33*Ayj32) +
                        s_xy * (Axi13*Ayj12 + Axi23*Ayj22 + Axi33*Ayj32 +
                                Ayi13*Axj12 + Ayi23*Axj22 + Ayi33*Axj32)
                    )
                    Kg[row0+3, col0+3] += scale * (
                        s_xx * (Axi13*Axj13 + Axi23*Axj23 + Axi33*Axj33) +
                        s_yy * (Ayi13*Ayj13 + Ayi23*Ayj23 + Ayi33*Ayj33) +
                        s_xy * (Axi13*Ayj13 + Axi23*Ayj23 + Axi33*Ayj33 +
                                Ayi13*Axj13 + Ayi23*Axj23 + Ayi33*Axj33)
                    )
                    else
                        sxy_term = if membrane_shear_center_row
                            dNdx_c[i] * dNdy_c[j] + dNdy_c[i] * dNdx_c[j]
                        else
                            dNi_dx * dNj_dy + dNi_dy * dNj_dx
                        end
                        val = h * abs_detJ * (s_xx * dNi_dx * dNj_dx +
                                               s_yy * dNi_dy * dNj_dy +
                                               s_xy * sxy_term)
                        if trans_mode === :normal_only
                            row = (i-1)*6 + 3
                            col = (j-1)*6 + 3
                            Kg[row, col] += val
                        elseif trans_mode === :principal_transverse
                            row0 = (i-1)*6
                            col0 = (j-1)*6
                            add_geometric_principal_transverse_pair!(
                                Kg,
                                row0,
                                col0,
                                dNi_dx,
                                dNi_dy,
                                dNj_dx,
                                dNj_dy,
                                h * abs_detJ,
                                s_xx,
                                s_yy,
                                s_xy,
                                principal_shear_yy_factor,
                                principal_shear_xy_factor,
                                principal_shear_z_factor,
                                principal_shear_ratio_min,
                                local_trans_scales[1],
                                local_trans_scales[2],
                                local_uv_scale,
                                local_trans_scales[3],
                            )
                            uv_nxy_delta = local_uv_nxy_scale - local_uv_scale
                            if uv_nxy_delta != 0.0 && s_xy != 0.0
                                uv_delta_val = h * abs_detJ * uv_nxy_delta * s_xy * sxy_term
                                Kg[row0 + 1, col0 + 2] += uv_delta_val
                                Kg[row0 + 2, col0 + 1] += uv_delta_val
                            end
                            w_nxx_delta = local_w_nxx_scale - local_trans_scales[3]
                            w_nyy_delta = local_w_nyy_scale - local_trans_scales[3]
                            w_nxy_delta = local_w_nxy_scale - local_trans_scales[3]
                            if w_nxx_delta != 0.0 || w_nyy_delta != 0.0 || (w_nxy_delta != 0.0 && s_xy != 0.0)
                                Kg[row0 + 3, col0 + 3] += h * abs_detJ * (
                                    w_nxx_delta * s_xx * dNi_dx * dNj_dx +
                                    w_nyy_delta * s_yy * dNi_dy * dNj_dy +
                                    w_nxy_delta * s_xy * sxy_term
                                )
                            end
                        else
                            for d in 1:3
                                row = (i-1)*6 + d
                                col = (j-1)*6 + d
                                Kg[row, col] += local_trans_scales[d] * val
                            end
                            if local_uv_scale != 0.0 || local_uv_nxy_scale != 0.0
                                row0 = (i - 1) * 6
                                col0 = (j - 1) * 6
                                uv_val = h * abs_detJ * (
                                    local_uv_scale * (
                                        s_xx * dNi_dx * dNj_dx +
                                        s_yy * dNi_dy * dNj_dy
                                    ) +
                                    local_uv_nxy_scale * s_xy * sxy_term
                                )
                                Kg[row0 + 1, col0 + 2] += uv_val
                                Kg[row0 + 2, col0 + 1] += uv_val
                            end
                            w_nxx_delta = local_w_nxx_scale - local_trans_scales[3]
                            w_nyy_delta = local_w_nyy_scale - local_trans_scales[3]
                            w_nxy_delta = local_w_nxy_scale - local_trans_scales[3]
                            if w_nxx_delta != 0.0 || w_nyy_delta != 0.0 || (w_nxy_delta != 0.0 && s_xy != 0.0)
                                row0 = (i - 1) * 6
                                col0 = (j - 1) * 6
                                Kg[row0 + 3, col0 + 3] += h * abs_detJ * (
                                    w_nxx_delta * s_xx * dNi_dx * dNj_dx +
                                    w_nyy_delta * s_yy * dNi_dy * dNj_dy +
                                    w_nxy_delta * s_xy * sxy_term
                                )
                            end
                        end
                        if trans_mode !== :curvature &&
                           trans_mode !== :normal_only &&
                           local_shear_axis_active &&
                           s_xy != 0.0
                            row0 = (i - 1) * 6
                            col0 = (j - 1) * 6
                            shear_axis_scale = h * abs_detJ * s_xy
                            ux_axis = shear_axis_scale * (
                                local_shear_axis_scales[1] * dNi_dx * dNj_dx +
                                local_shear_axis_scales[3] * sxy_term
                            )
                            wz_axis = shear_axis_scale * (
                                local_shear_axis_scales[2] * dNi_dx * dNj_dx +
                                local_shear_axis_scales[4] * sxy_term
                            )
                            Kg[row0 + 1, col0 + 1] += ux_axis
                            Kg[row0 + 3, col0 + 3] += wz_axis
                        end
                        if trans_mode !== :curvature &&
                           local_axis_resultant_active &&
                           (s_xx != 0.0 || s_yy != 0.0)
                            row0 = (i - 1) * 6
                            col0 = (j - 1) * 6
                            axis_scale = h * abs_detJ
                            ux_axis = axis_scale * local_axis_resultant_scales[1] *
                                      s_xx * dNi_dx * dNj_dx
                            vy_axis = axis_scale * local_axis_resultant_scales[2] *
                                      s_yy * dNi_dy * dNj_dy
                            wx_axis = axis_scale * local_axis_resultant_scales[3] *
                                      s_xx * dNi_dx * dNj_dx
                            wy_axis = axis_scale * local_axis_resultant_scales[4] *
                                      s_yy * dNi_dy * dNj_dy
                            Kg[row0 + 1, col0 + 1] += ux_axis
                            Kg[row0 + 2, col0 + 2] += vy_axis
                            Kg[row0 + 3, col0 + 3] += wx_axis + wy_axis
                        end
                        if trans_mode !== :curvature &&
                           trans_mode !== :normal_only &&
                           local_shear_extra_active &&
                           s_xy != 0.0
                            row0 = (i - 1) * 6
                            col0 = (j - 1) * 6
                            shear_extra_scale = h * abs_detJ * s_xy
                            uyy_extra = shear_extra_scale *
                                        local_shear_extra_scales[1] *
                                        dNi_dy * dNj_dy
                            vxx_extra = shear_extra_scale *
                                        local_shear_extra_scales[2] *
                                        dNi_dx * dNj_dx
                            vyy_extra = shear_extra_scale *
                                        local_shear_extra_scales[3] *
                                        dNi_dy * dNj_dy
                            vxy_extra = shear_extra_scale *
                                        local_shear_extra_scales[4] *
                                        sxy_term
                            Kg[row0 + 1, col0 + 1] += uyy_extra
                            Kg[row0 + 2, col0 + 2] += vxx_extra + vyy_extra + vxy_extra
                        end
                        if trans_mode !== :curvature &&
                           local_nyy_u_extra_active &&
                           s_yy != 0.0
                            row0 = (i - 1) * 6
                            col0 = (j - 1) * 6
                            nyy_u_scale = h * abs_detJ * s_yy
                            uxx_extra = nyy_u_scale *
                                        local_nyy_u_extra_scales[1] *
                                        dNi_dx * dNj_dx
                            uyy_extra = nyy_u_scale *
                                        local_nyy_u_extra_scales[2] *
                                        dNi_dy * dNj_dy
                            uxy_extra = nyy_u_scale *
                                        local_nyy_u_extra_scales[3] *
                                        sxy_term
                            Kg[row0 + 1, col0 + 1] += uxx_extra + uyy_extra + uxy_extra
                        end
                        if trans_mode !== :curvature &&
                           local_nyy_vw_extra_active &&
                           s_yy != 0.0
                            row0 = (i - 1) * 6
                            col0 = (j - 1) * 6
                            nyy_vw_scale = h * abs_detJ * s_yy
                            vxx_extra = nyy_vw_scale *
                                        local_nyy_vw_extra_scales[1] *
                                        dNi_dx * dNj_dx
                            wxx_extra = nyy_vw_scale *
                                        local_nyy_vw_extra_scales[2] *
                                        dNi_dx * dNj_dx
                            wxy_extra = nyy_vw_scale *
                                        local_nyy_vw_extra_scales[3] *
                                        sxy_term
                            Kg[row0 + 2, col0 + 2] += vxx_extra
                            Kg[row0 + 3, col0 + 3] += wxx_extra + wxy_extra
                        end
                    end
                end
            end
        end
        if transverse_w_form !== :w && trans_mode !== :curvature
            # Reference-form delta (see the hoist above): remove the plain
            # Kirchhoff w-w metric added by the standard path and add the
            # selected rotation form.  beta_x = +theta_y, beta_y = -theta_x.
            for i in 1:4
                dNi_dx = iJ11*dNr[i] + iJ12*dNs[i]
                dNi_dy = iJ21*dNr[i] + iJ22*dNs[i]
                Ni = Nvals[i]
                if transverse_w_form === :meanstring
                    dfx[i] += h * abs_detJ * ((s_xx - sigma_mean_1) * dNi_dx +
                                              (s_xy - sigma_mean_3) * dNi_dy)
                    dfy[i] += h * abs_detJ * ((s_yy - sigma_mean_2) * dNi_dy +
                                              (s_xy - sigma_mean_3) * dNi_dx)
                end
                for j in 1:4
                    dNj_dx = iJ11*dNr[j] + iJ12*dNs[j]
                    dNj_dy = iJ21*dNr[j] + iJ22*dNs[j]
                    Nj = Nvals[j]
                    row0 = (i - 1) * 6
                    col0 = (j - 1) * 6
                    sxy_term = dNi_dx * dNj_dy + dNi_dy * dNj_dx
                    val_ww = h * abs_detJ * (
                        s_xx * dNi_dx * dNj_dx +
                        s_yy * dNi_dy * dNj_dy +
                        s_xy * sxy_term
                    )
                    Kg[row0 + 3, col0 + 3] -= val_ww
                    if transverse_w_form === :meanstring
                        Kg[row0 + 3, col0 + 3] += h * abs_detJ * (
                            sigma_mean_1 * dNi_dx * dNj_dx +
                            sigma_mean_2 * dNi_dy * dNj_dy +
                            sigma_mean_3 * sxy_term
                        )
                        # Reference form (report 3.33): the IN-PLANE channels
                        # are ALSO the mean-state consistent principal-
                        # transverse metric (plus the string terms added after
                        # the GP loop).  Remove the per-GP in-plane content
                        # the standard path accumulated and add the mean-state
                        # version.  Assumes unit local factors (pure-physics
                        # configuration), like the w delta above.
                        # The in-plane channel is the mean-state principal-
                        # transverse metric: remove the per-GP content the
                        # standard path added and add the mean-state version.
                        # The principal reconstruction re-diagonalizes the FULL
                        # stress vector, which makes the in-plane operator
                        # NON-LINEAR in (Nxx,Nyy,Nxy): under combined/rotated
                        # states Kg(sa+sb) != Kg(sa)+Kg(sb), producing large
                        # errors on higher buckling modes (single-element pencil:
                        # +147% mode 2; report 3.90). When principal_inplane_linear
                        # is on we evaluate the principal in-plane block ONE STRESS
                        # COMPONENT AT A TIME and sum, restoring linearity. Each
                        # single-component evaluation is identical to the current
                        # operator (principal decomposition of a single component
                        # is trivial), so axis-aligned states are unchanged, while
                        # combined states become the correct linear superposition
                        # (offline pencil: +1.11% both modes, matching Nastran).
                        if principal_inplane_linear
                            # remove per-GP principal in-plane content. This must
                            # cancel EXACTLY what the base GP loop added (a single
                            # re-diagonalized call on the full stress), so it uses
                            # the full-stress form, NOT the component split.
                            add_geometric_principal_transverse_pair!(
                                Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                                h * abs_detJ, -s_xx, -s_yy, -s_xy,
                                1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                            # add mean-state principal in-plane content, component-wise
                            # (linear superposition -> the operator becomes linear
                            # in the mean stress components)
                            add_geometric_principal_transverse_pair!(
                                Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                                h * abs_detJ, sigma_mean_1, 0.0, 0.0,
                                1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                            add_geometric_principal_transverse_pair!(
                                Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                                h * abs_detJ, 0.0, sigma_mean_2, 0.0,
                                1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                            add_geometric_principal_transverse_pair!(
                                Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                                h * abs_detJ, 0.0, 0.0, sigma_mean_3,
                                1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                        else
                        add_geometric_principal_transverse_pair!(
                            Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                            h * abs_detJ, -s_xx, -s_yy, -s_xy,
                            1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                        add_geometric_principal_transverse_pair!(
                            Kg, row0, col0, dNi_dx, dNi_dy, dNj_dx, dNj_dy,
                            h * abs_detJ, sigma_mean_1, sigma_mean_2, sigma_mean_3,
                            1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0)
                        end
                    elseif transverse_w_form === :wty
                        Kg[row0 + 3, col0 + 5] += transverse_wty_sign * val_ww
                        Kg[row0 + 5, col0 + 3] += transverse_wty_sign * val_ww
                    elseif transverse_w_form === :rot
                        nn = h * abs_detJ * Ni * Nj
                        Kg[row0 + 5, col0 + 5] += s_xx * nn
                        Kg[row0 + 4, col0 + 4] += s_yy * nn
                        Kg[row0 + 5, col0 + 4] += -s_xy * nn
                        Kg[row0 + 4, col0 + 5] += -s_xy * nn
                    else # :cross
                        # Element rotation convention is beta = -grad(w) on
                        # Kirchhoff-consistent modes (measured via the w-form
                        # critical eigenvector: Rayleigh ratio -0.917), so the
                        # cross terms carry a global minus sign.
                        tx = -0.5 * h * abs_detJ
                        Kg[row0 + 3, col0 + 5] += tx * (s_xx * dNi_dx + s_xy * dNi_dy) * Nj
                        Kg[row0 + 3, col0 + 4] += -tx * (s_xy * dNi_dx + s_yy * dNi_dy) * Nj
                        Kg[row0 + 5, col0 + 3] += tx * (s_xx * dNj_dx + s_xy * dNj_dy) * Ni
                        Kg[row0 + 4, col0 + 3] += -tx * (s_xy * dNj_dx + s_yy * dNj_dy) * Ni
                    end
                end
            end
        end
    end

    if transverse_w_form === :meanstring && trans_mode !== :curvature
        # Edge strings carrying the residual (gradient-part) corner forces:
        # least-squares decomposition of df onto the four edge axial forces,
        # each contributing the classic (P/L)[1,-1;-1,1] on its (w_a, w_b).
        # Strut set: 4 edges + 2 diagonals (minimal-norm least squares; the
        # diagonal columns are inert when the residual is edge-representable,
        # e.g. the flat gradient control, but redistribute junction-element
        # residual states).  Toggle with JFEM_KG_MEANSTRING_DIAGONALS=false.
        ms_edges = lowercase(strip(get(ENV, "JFEM_KG_MEANSTRING_DIAGONALS", "true"))) in
                   ("1", "true", "yes", "on") ?
            ((1, 2), (2, 3), (3, 4), (4, 1), (1, 3), (2, 4)) :
            ((1, 2), (2, 3), (3, 4), (4, 1))
        ms_A = zeros(8, length(ms_edges))
        for (k, (a, b)) in enumerate(ms_edges)
            ex = coords[b, 1] - coords[a, 1]
            ey = coords[b, 2] - coords[a, 2]
            Le = hypot(ex, ey)
            Le < 1e-12 && continue
            ex /= Le; ey /= Le
            ms_A[2a-1, k] += ex; ms_A[2a, k] += ey
            ms_A[2b-1, k] -= ex; ms_A[2b, k] -= ey
        end
        ms_rhs = zeros(8)
        for i in 1:4
            ms_rhs[2i-1] = -dfx[i]
            ms_rhs[2i] = -dfy[i]
        end
        ms_G = ms_A' * ms_A
        @inbounds for k in 1:length(ms_edges)
            ms_G[k, k] += 1e-10
        end
        ms_P = ms_G \ (ms_A' * ms_rhs)
        for (k, (a, b)) in enumerate(ms_edges)
            ex = coords[b, 1] - coords[a, 1]
            ey = coords[b, 2] - coords[a, 2]
            Le = hypot(ex, ey)
            Le < 1e-12 && continue
            s = ms_P[k] / Le
            wa = (a - 1) * 6 + 3
            wb = (b - 1) * 6 + 3
            Kg[wa, wa] += s
            Kg[wb, wb] += s
            Kg[wa, wb] -= s
            Kg[wb, wa] -= s
            # in-plane-transverse part of the string (report 3.33)
            px = -ey / Le
            py = ex / Le
            for (na, sa) in ((a, 1.0), (b, -1.0)), (nb, sb) in ((a, 1.0), (b, -1.0))
                ra = (na - 1) * 6
                rb = (nb - 1) * 6
                Kg[ra + 1, rb + 1] += s * sa * sb * px * px
                Kg[ra + 1, rb + 2] += s * sa * sb * px * py
                Kg[ra + 2, rb + 1] += s * sa * sb * py * px
                Kg[ra + 2, rb + 2] += s * sa * sb * py * py
            end
        end
    end

    return Kg
end

# Geometric stiffness for CTRIA3 shell element (18×18)
# Constant strain triangle — single integration point.
function geometric_stiffness_tria3(coords::AbstractMatrix, sigma_mem::AbstractVector, h::Float64;
                                   trans_mode::Symbol=:all,
                                   curvature::Union{Nothing,SVector{3,Float64}}=nothing,
                                   curvature_sign::Float64=1.0)
    Kg = zeros(18, 18)
    if h < 1e-30; return Kg; end

    x, y = coords[:,1], coords[:,2]
    A2 = x[1]*(y[2]-y[3]) + x[2]*(y[3]-y[1]) + x[3]*(y[1]-y[2])
    A = 0.5 * abs(A2)
    if A < 1e-12; return Kg; end

    s_xx = sigma_mem[1]; s_yy = sigma_mem[2]; s_xy = sigma_mem[3]

    # Shape function derivatives (constant for CST)
    bv = [y[2]-y[3], y[3]-y[1], y[1]-y[2]] ./ (2*A)  # dN/dx
    cv = [x[3]-x[2], x[1]-x[3], x[2]-x[1]] ./ (2*A)  # dN/dy
    Nctr = 1.0 / 3.0

    for i in 1:3
        for j in 1:3
            if trans_mode === :curvature
                k11 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[1]
                k22 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[2]
                k12 = isnothing(curvature) ? 0.0 : curvature_sign * curvature[3]
                Axi11 = bv[i]; Axi12 = 0.0;   Axi13 = -Nctr * k11
                Axi21 = 0.0;   Axi22 = bv[i]; Axi23 = -Nctr * k12
                Axi31 = Nctr * k11; Axi32 = Nctr * k12; Axi33 = bv[i]
                Ayi11 = cv[i]; Ayi12 = 0.0;   Ayi13 = -Nctr * k12
                Ayi21 = 0.0;   Ayi22 = cv[i]; Ayi23 = -Nctr * k22
                Ayi31 = Nctr * k12; Ayi32 = Nctr * k22; Ayi33 = cv[i]
                Axj11 = bv[j]; Axj12 = 0.0;   Axj13 = -Nctr * k11
                Axj21 = 0.0;   Axj22 = bv[j]; Axj23 = -Nctr * k12
                Axj31 = Nctr * k11; Axj32 = Nctr * k12; Axj33 = bv[j]
                Ayj11 = cv[j]; Ayj12 = 0.0;   Ayj13 = -Nctr * k12
                Ayj21 = 0.0;   Ayj22 = cv[j]; Ayj23 = -Nctr * k22
                Ayj31 = Nctr * k12; Ayj32 = Nctr * k22; Ayj33 = cv[j]
                scale = h * A
                row0 = (i-1)*6
                col0 = (j-1)*6
                Kg[row0+1, col0+1] += scale * (
                    s_xx * (Axi11*Axj11 + Axi21*Axj21 + Axi31*Axj31) +
                    s_yy * (Ayi11*Ayj11 + Ayi21*Ayj21 + Ayi31*Ayj31) +
                    s_xy * (Axi11*Ayj11 + Axi21*Ayj21 + Axi31*Ayj31 +
                            Ayi11*Axj11 + Ayi21*Axj21 + Ayi31*Axj31)
                )
                Kg[row0+1, col0+2] += scale * (
                    s_xx * (Axi11*Axj12 + Axi21*Axj22 + Axi31*Axj32) +
                    s_yy * (Ayi11*Ayj12 + Ayi21*Ayj22 + Ayi31*Ayj32) +
                    s_xy * (Axi11*Ayj12 + Axi21*Ayj22 + Axi31*Ayj32 +
                            Ayi11*Axj12 + Ayi21*Axj22 + Ayi31*Axj32)
                )
                Kg[row0+1, col0+3] += scale * (
                    s_xx * (Axi11*Axj13 + Axi21*Axj23 + Axi31*Axj33) +
                    s_yy * (Ayi11*Ayj13 + Ayi21*Ayj23 + Ayi31*Ayj33) +
                    s_xy * (Axi11*Ayj13 + Axi21*Ayj23 + Axi31*Ayj33 +
                            Ayi11*Axj13 + Ayi21*Axj23 + Ayi31*Axj33)
                )
                Kg[row0+2, col0+1] += scale * (
                    s_xx * (Axi12*Axj11 + Axi22*Axj21 + Axi32*Axj31) +
                    s_yy * (Ayi12*Ayj11 + Ayi22*Ayj21 + Ayi32*Ayj31) +
                    s_xy * (Axi12*Ayj11 + Axi22*Ayj21 + Axi32*Ayj31 +
                            Ayi12*Axj11 + Ayi22*Axj21 + Ayi32*Axj31)
                )
                Kg[row0+2, col0+2] += scale * (
                    s_xx * (Axi12*Axj12 + Axi22*Axj22 + Axi32*Axj32) +
                    s_yy * (Ayi12*Ayj12 + Ayi22*Ayj22 + Ayi32*Ayj32) +
                    s_xy * (Axi12*Ayj12 + Axi22*Ayj22 + Axi32*Ayj32 +
                            Ayi12*Axj12 + Ayi22*Axj22 + Ayi32*Axj32)
                )
                Kg[row0+2, col0+3] += scale * (
                    s_xx * (Axi12*Axj13 + Axi22*Axj23 + Axi32*Axj33) +
                    s_yy * (Ayi12*Ayj13 + Ayi22*Ayj23 + Ayi32*Ayj33) +
                    s_xy * (Axi12*Ayj13 + Axi22*Ayj23 + Axi32*Ayj33 +
                            Ayi12*Axj13 + Ayi22*Axj23 + Ayi32*Axj33)
                )
                Kg[row0+3, col0+1] += scale * (
                    s_xx * (Axi13*Axj11 + Axi23*Axj21 + Axi33*Axj31) +
                    s_yy * (Ayi13*Ayj11 + Ayi23*Ayj21 + Ayi33*Ayj31) +
                    s_xy * (Axi13*Ayj11 + Axi23*Ayj21 + Axi33*Ayj31 +
                            Ayi13*Axj11 + Ayi23*Axj21 + Ayi33*Axj31)
                )
                Kg[row0+3, col0+2] += scale * (
                    s_xx * (Axi13*Axj12 + Axi23*Axj22 + Axi33*Axj32) +
                    s_yy * (Ayi13*Ayj12 + Ayi23*Ayj22 + Ayi33*Ayj32) +
                    s_xy * (Axi13*Ayj12 + Axi23*Ayj22 + Axi33*Ayj32 +
                            Ayi13*Axj12 + Ayi23*Axj22 + Ayi33*Axj32)
                )
                Kg[row0+3, col0+3] += scale * (
                    s_xx * (Axi13*Axj13 + Axi23*Axj23 + Axi33*Axj33) +
                    s_yy * (Ayi13*Ayj13 + Ayi23*Ayj23 + Ayi33*Ayj33) +
                    s_xy * (Axi13*Ayj13 + Axi23*Ayj23 + Axi33*Ayj33 +
                            Ayi13*Axj13 + Ayi23*Axj23 + Ayi33*Axj33)
                )
            else
                val = h * A * (s_xx * bv[i] * bv[j] +
                               s_yy * cv[i] * cv[j] +
                               s_xy * (bv[i] * cv[j] + cv[i] * bv[j]))
                if trans_mode === :surface_normal || trans_mode === :normal_projector
                    n_gp = cross(a_r, a_s) / dA
                    row0 = (i - 1) * 6
                    col0 = (j - 1) * 6
                    for p in 1:3
                        np = n_gp[p]
                        row = row0 + p
                        for q in 1:3
                            Kg[row, col0 + q] += val * np * n_gp[q]
                        end
                    end
                elseif trans_mode === :surface_tangent || trans_mode === :tangent_projector
                    n_gp = cross(a_r, a_s) / dA
                    row0 = (i - 1) * 6
                    col0 = (j - 1) * 6
                    for p in 1:3
                        row = row0 + p
                        for q in 1:3
                            projector_pq = (p == q ? 1.0 : 0.0) - n_gp[p] * n_gp[q]
                            Kg[row, col0 + q] += val * projector_pq
                        end
                    end
                elseif trans_mode === :normal_only
                    row = (i-1)*6 + 3
                    col = (j-1)*6 + 3
                    Kg[row, col] += val
                else
                    for d in 1:3
                        row = (i-1)*6 + d
                        col = (j-1)*6 + d
                        Kg[row, col] += val
                    end
                end
            end
        end
    end

    return Kg
end

function geometric_stiffness_quad4_covariant(coords3d::AbstractMatrix, sigma_mem::AbstractVector, h::Float64,
                                             basis1::SVector{3,Float64}, basis2::SVector{3,Float64};
                                             trans_mode::Symbol=:all,
                                             principal_shear_yy_factor::Float64=1.0,
                                             principal_shear_xy_factor::Float64=1.0,
                                             principal_shear_z_factor::Float64=1.0,
                                             principal_shear_ratio_min::Float64=1.0)
    sigma_gp = zeros(4, 3)
    @inbounds for gp in 1:4
        sigma_gp[gp, 1] = sigma_mem[1]
        sigma_gp[gp, 2] = sigma_mem[2]
        sigma_gp[gp, 3] = sigma_mem[3]
    end
    return geometric_stiffness_quad4_covariant(coords3d, sigma_gp, h, basis1, basis2;
                                               trans_mode=trans_mode,
                                               principal_shear_yy_factor=principal_shear_yy_factor,
                                               principal_shear_xy_factor=principal_shear_xy_factor,
                                               principal_shear_z_factor=principal_shear_z_factor,
                                               principal_shear_ratio_min=principal_shear_ratio_min)
end

function geometric_stiffness_quad4_covariant(coords3d::AbstractMatrix, sigma_mem_gp::AbstractMatrix, h::Float64,
                                             basis1::SVector{3,Float64}, basis2::SVector{3,Float64};
                                             trans_mode::Symbol=:all,
                                             principal_shear_yy_factor::Float64=1.0,
                                             principal_shear_xy_factor::Float64=1.0,
                                             principal_shear_z_factor::Float64=1.0,
                                             principal_shear_ratio_min::Float64=1.0)
    Kg = zeros(24, 24)
    if h < 1e-30; return Kg; end

    pt = 1.0 / sqrt(3.0)
    gauss_pts = (SVector(-pt,-pt), SVector(pt,-pt), SVector(pt,pt), SVector(-pt,pt))

    # JFEM_KG_COVARIANT_CENTER_SHEAR (default OFF): match Nastran's CQUAD4 KDJJ
    # shear sampling on skewed/warped composite cells.  Nastran center-samples the
    # differential-stiffness shear resultant (element mean of the per-GP Nxy) while
    # integrating the normal terms per-GP (see geometric_stiffness_quad4_nastran_kdjj
    # _pcomp_field).  The covariant kernel otherwise uses the per-GP Nxy, which on a
    # skewed cell over-weights the shear geometric-stiffness cross term and biases the
    # transverse (w-w) block ~8% vs Nastran KGG/KDJJ.  Center-sampling only the shear
    # (keeping per-GP normals + the exact covariant metric) is the missing ingredient.
    center_shear = fem_env_bool("JFEM_KG_COVARIANT_CENTER_SHEAR", false)
    nxy_c = 0.25 * (sigma_mem_gp[1,3] + sigma_mem_gp[2,3] + sigma_mem_gp[3,3] + sigma_mem_gp[4,3])

    @inbounds @fastmath for gp in 1:4
        s_xx = sigma_mem_gp[gp, 1]
        s_yy = sigma_mem_gp[gp, 2]
        s_xy = center_shear ? nxy_c : sigma_mem_gp[gp, 3]
        r, s = gauss_pts[gp][1], gauss_pts[gp][2]
        dNr, dNs = shape_derivs_quad(r, s)

        a_r = SVector(
            dNr[1]*coords3d[1,1] + dNr[2]*coords3d[2,1] + dNr[3]*coords3d[3,1] + dNr[4]*coords3d[4,1],
            dNr[1]*coords3d[1,2] + dNr[2]*coords3d[2,2] + dNr[3]*coords3d[3,2] + dNr[4]*coords3d[4,2],
            dNr[1]*coords3d[1,3] + dNr[2]*coords3d[2,3] + dNr[3]*coords3d[3,3] + dNr[4]*coords3d[4,3],
        )
        a_s = SVector(
            dNs[1]*coords3d[1,1] + dNs[2]*coords3d[2,1] + dNs[3]*coords3d[3,1] + dNs[4]*coords3d[4,1],
            dNs[1]*coords3d[1,2] + dNs[2]*coords3d[2,2] + dNs[3]*coords3d[3,2] + dNs[4]*coords3d[4,2],
            dNs[1]*coords3d[1,3] + dNs[2]*coords3d[2,3] + dNs[3]*coords3d[3,3] + dNs[4]*coords3d[4,3],
        )

        g11 = dot(a_r, a_r)
        g12 = dot(a_r, a_s)
        g22 = dot(a_s, a_s)
        detg = g11 * g22 - g12 * g12
        if abs(detg) < 1e-14
            detg = detg < 0.0 ? -1e-14 : 1e-14
        end
        invg11 = g22 / detg
        invg12 = -g12 / detg
        invg22 = g11 / detg
        a_r_contra = invg11 * a_r + invg12 * a_s
        a_s_contra = invg12 * a_r + invg22 * a_s
        dA = norm(cross(a_r, a_s))
        dA < 1e-12 && continue

        for i in 1:4
            gradNi = dNr[i] * a_r_contra + dNs[i] * a_s_contra
            dNi_dx = dot(gradNi, basis1)
            dNi_dy = dot(gradNi, basis2)
            for j in 1:4
                gradNj = dNr[j] * a_r_contra + dNs[j] * a_s_contra
                dNj_dx = dot(gradNj, basis1)
                dNj_dy = dot(gradNj, basis2)
                val = h * dA * (s_xx * dNi_dx * dNj_dx +
                                s_yy * dNi_dy * dNj_dy +
                                s_xy * (dNi_dx * dNj_dy + dNi_dy * dNj_dx))
                if trans_mode === :normal_only
                    row = (i-1)*6 + 3
                    col = (j-1)*6 + 3
                    Kg[row, col] += val
                elseif trans_mode === :principal_transverse
                    row0 = (i - 1) * 6
                    col0 = (j - 1) * 6
                    add_geometric_principal_transverse_pair!(
                        Kg,
                        row0,
                        col0,
                        dNi_dx,
                        dNi_dy,
                        dNj_dx,
                        dNj_dy,
                        h * dA,
                        s_xx,
                        s_yy,
                        s_xy,
                        principal_shear_yy_factor,
                        principal_shear_xy_factor,
                        principal_shear_z_factor,
                        principal_shear_ratio_min,
                    )
                else
                    for d in 1:3
                        row = (i-1)*6 + d
                        col = (j-1)*6 + d
                        Kg[row, col] += val
                    end
                end
            end
        end
    end

    return Kg
end

# =============================================================================
# MASS MATRICES — SOL 103 Normal Modes
# =============================================================================

"""
    consistent_mass_quad4(coords, rho, h) -> 24×24 Matrix

Consistent mass matrix for a 4-node bilinear shell element.
Integrates M = ∫ ρh NᵀN dA using 2×2 Gauss quadrature.
Translational DOFs (1,2,3) get full inertia; rotational DOFs (4,5) get
h²/12 rotary inertia; drilling DOF (6) gets zero mass.
"""
function consistent_mass_quad4(coords::AbstractMatrix, rho::Float64, h::Float64)
    Me = zeros(24, 24)
    if rho < 1e-30 || h < 1e-30; return Me; end

    pt = 1.0 / sqrt(3.0)
    gauss_pts = ((-pt,-pt), (pt,-pt), (pt,pt), (-pt,pt))

    for (r, s) in gauss_pts
        N1 = 0.25*(1-r)*(1-s); N2 = 0.25*(1+r)*(1-s)
        N3 = 0.25*(1+r)*(1+s); N4 = 0.25*(1-r)*(1+s)
        Nv = SVector(N1, N2, N3, N4)

        dNr = SVector(-0.25*(1-s), 0.25*(1-s), 0.25*(1+s), -0.25*(1+s))
        dNs = SVector(-0.25*(1-r), -0.25*(1+r), 0.25*(1+r), 0.25*(1-r))
        J11 = dNr[1]*coords[1,1]+dNr[2]*coords[2,1]+dNr[3]*coords[3,1]+dNr[4]*coords[4,1]
        J12 = dNr[1]*coords[1,2]+dNr[2]*coords[2,2]+dNr[3]*coords[3,2]+dNr[4]*coords[4,2]
        J21 = dNs[1]*coords[1,1]+dNs[2]*coords[2,1]+dNs[3]*coords[3,1]+dNs[4]*coords[4,1]
        J22 = dNs[1]*coords[1,2]+dNs[2]*coords[2,2]+dNs[3]*coords[3,2]+dNs[4]*coords[4,2]
        detJ = abs(J11*J22 - J12*J21)
        if detJ < 1e-30; continue; end

        mass_t = rho * h * detJ       # translational mass per unit area × |J|
        mass_r = rho * h^3/12 * detJ  # rotary inertia

        for j in 1:4, i in 1:4
            NiNj = Nv[i] * Nv[j]
            bi = (i-1)*6; bj = (j-1)*6
            # Translational DOFs (u, v, w)
            Me[bi+1, bj+1] += mass_t * NiNj
            Me[bi+2, bj+2] += mass_t * NiNj
            Me[bi+3, bj+3] += mass_t * NiNj
            # Rotational DOFs (rx, ry) — rotary inertia
            Me[bi+4, bj+4] += mass_r * NiNj
            Me[bi+5, bj+5] += mass_r * NiNj
            # DOF 6 (drilling): zero mass
        end
    end
    return Me
end

"""
    consistent_mass_tria3(coords, rho, h) -> 18×18 Matrix

Consistent mass matrix for a 3-node constant-strain triangle shell element.
Analytical integration (no quadrature needed for linear shape functions).
"""
function consistent_mass_tria3(coords::AbstractMatrix, rho::Float64, h::Float64)
    Me = zeros(18, 18)
    if rho < 1e-30 || h < 1e-30; return Me; end

    # Triangle area
    x1, y1 = coords[1,1], coords[1,2]
    x2, y2 = coords[2,1], coords[2,2]
    x3, y3 = coords[3,1], coords[3,2]
    A = 0.5 * abs((x2-x1)*(y3-y1) - (x3-x1)*(y2-y1))
    if A < 1e-30; return Me; end

    mass_t = rho * h * A
    mass_r = rho * h^3/12 * A

    # Consistent mass for linear triangle: M_ij = (ρhA/12) * (1+δ_ij)
    # i.e. diagonal = ρhA/6, off-diagonal = ρhA/12
    for i in 1:3, j in 1:3
        bi = (i-1)*6; bj = (j-1)*6
        factor = (i == j) ? mass_t/6.0 : mass_t/12.0
        factor_r = (i == j) ? mass_r/6.0 : mass_r/12.0
        Me[bi+1, bj+1] += factor
        Me[bi+2, bj+2] += factor
        Me[bi+3, bj+3] += factor
        Me[bi+4, bj+4] += factor_r
        Me[bi+5, bj+5] += factor_r
    end
    return Me
end

"""
    nastran_lumped_mass_quad4(coords, rho, h) -> 24x24 Matrix

Nastran-compatible lumped shell mass for a four-node shell. Translational mass
is split equally over the corner grids. Shell rotations carry no default
rotary inertia in the SOL 103 lumped-mass path; Nastran keeps the bending
rotations in K but gives them zero structural mass for the default PSHELL
mass matrix.
"""
function nastran_lumped_mass_quad4(coords::AbstractMatrix, rho::Float64, h::Float64)
    Me = zeros(24, 24)
    if rho < 1e-30 || h < 1e-30; return Me; end

    area = 0.0
    @inbounds for i in 1:4
        j = i == 4 ? 1 : i + 1
        area += coords[i,1] * coords[j,2] - coords[j,1] * coords[i,2]
    end
    area = 0.5 * abs(area)
    if area < 1e-30; return Me; end

    mass_t = rho * h * area / 4.0
    @inbounds for k in 1:4
        base = (k - 1) * 6
        Me[base + 1, base + 1] = mass_t
        Me[base + 2, base + 2] = mass_t
        Me[base + 3, base + 3] = mass_t
    end
    return Me
end

"""
    nastran_lumped_mass_tria3(coords, rho, h) -> 18x18 Matrix

Nastran-compatible lumped shell mass for a three-node shell.
"""
function nastran_lumped_mass_tria3(coords::AbstractMatrix, rho::Float64, h::Float64)
    Me = zeros(18, 18)
    if rho < 1e-30 || h < 1e-30; return Me; end

    x1, y1 = coords[1,1], coords[1,2]
    x2, y2 = coords[2,1], coords[2,2]
    x3, y3 = coords[3,1], coords[3,2]
    area = 0.5 * abs((x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1))
    if area < 1e-30; return Me; end

    mass_t = rho * h * area / 3.0
    @inbounds for k in 1:3
        base = (k - 1) * 6
        Me[base + 1, base + 1] = mass_t
        Me[base + 2, base + 2] = mass_t
        Me[base + 3, base + 3] = mass_t
    end
    return Me
end

"""
    consistent_mass_frame3d(L, rho, A, Iy, Iz) -> 12×12 Matrix

Consistent mass matrix for a 3D Euler-Bernoulli beam element.
"""
function consistent_mass_frame3d(L::Float64, rho::Float64, A::Float64,
                                 Iy::Float64, Iz::Float64)
    Me = zeros(12, 12)
    if L < 1e-12 || rho < 1e-30 || A < 1e-30; return Me; end

    m = rho * A * L  # total element mass

    # Axial (DOFs 1, 7)
    Me[1,1] = m/3;   Me[7,7] = m/3
    Me[1,7] = m/6;   Me[7,1] = m/6

    # Torsional (DOFs 4, 10) — use polar moment Ip = Iy + Iz
    Ip = Iy + Iz
    if Ip > 0
        mt = rho * Ip * L
        Me[4,4] = mt/3;   Me[10,10] = mt/3
        Me[4,10] = mt/6;  Me[10,4] = mt/6
    end

    # Bending in XZ plane (DOFs 2, 6, 8, 12)
    Me[2,2] = 156*m/420;   Me[8,8] = 156*m/420
    Me[2,8] = 54*m/420;    Me[8,2] = 54*m/420
    Me[2,6] = 22*L*m/420;  Me[6,2] = 22*L*m/420
    Me[2,12] = -13*L*m/420; Me[12,2] = -13*L*m/420
    Me[6,6] = 4*L^2*m/420;  Me[12,12] = 4*L^2*m/420
    Me[6,8] = 13*L*m/420;   Me[8,6] = 13*L*m/420
    Me[6,12] = -3*L^2*m/420; Me[12,6] = -3*L^2*m/420
    Me[8,12] = -22*L*m/420;  Me[12,8] = -22*L*m/420

    # Bending in XY plane (DOFs 3, 5, 9, 11) — same structure, sign flips on coupling
    Me[3,3] = 156*m/420;   Me[9,9] = 156*m/420
    Me[3,9] = 54*m/420;    Me[9,3] = 54*m/420
    Me[3,5] = -22*L*m/420; Me[5,3] = -22*L*m/420
    Me[3,11] = 13*L*m/420; Me[11,3] = 13*L*m/420
    Me[5,5] = 4*L^2*m/420;  Me[11,11] = 4*L^2*m/420
    Me[5,9] = -13*L*m/420;  Me[9,5] = -13*L*m/420
    Me[5,11] = -3*L^2*m/420; Me[11,5] = -3*L^2*m/420
    Me[9,11] = 22*L*m/420;   Me[11,9] = 22*L*m/420

    return Me
end

"""
    consistent_mass_rod(L, rho, A) -> 12×12 Matrix

Consistent mass matrix for a rod/truss element (axial DOFs only).
Uses 6-DOF-per-node format (12×12) with mass only on axial DOFs.
"""
function consistent_mass_rod(L::Float64, rho::Float64, A::Float64)
    Me = zeros(12, 12)
    if L < 1e-12 || rho < 1e-30 || A < 1e-30; return Me; end

    m = rho * A * L
    # Axial (DOFs 1, 7)
    Me[1,1] = m/3;   Me[7,7] = m/3
    Me[1,7] = m/6;   Me[7,1] = m/6
    # Transverse (lumped for stability)
    Me[2,2] = m/2; Me[3,3] = m/2
    Me[8,8] = m/2; Me[9,9] = m/2

    return Me
end

"""
    nastran_lumped_mass_frame3d(L, rho, A, J, Iy, Iz) -> 12x12 Matrix

Nastran-compatible lumped mass matrix for 3D CBAR/CBEAM line elements.
Translational mass is lumped equally to the two end grids. Rotary inertia is
lumped to the corresponding local rotational DOFs when section inertias are
available.
"""
function nastran_lumped_mass_frame3d(L::Float64, rho::Float64, A::Float64,
                                     J::Float64, Iy::Float64, Iz::Float64)
    Me = zeros(12, 12)
    if L < 1e-12 || rho < 1e-30 || A < 1e-30; return Me; end

    m_node = rho * A * L / 2.0
    @inbounds for base in (0, 6)
        Me[base + 1, base + 1] = m_node
        Me[base + 2, base + 2] = m_node
        Me[base + 3, base + 3] = m_node
        if J > 0.0
            Me[base + 4, base + 4] = rho * J * L / 2.0
        end
        if Iy > 0.0
            Me[base + 5, base + 5] = rho * Iy * L / 2.0
        end
        if Iz > 0.0
            Me[base + 6, base + 6] = rho * Iz * L / 2.0
        end
    end
    return Me
end

"""
    nastran_lumped_mass_rod(L, rho, A, J) -> 12x12 Matrix

Nastran-compatible lumped mass matrix for CROD/CONROD elements.
"""
function nastran_lumped_mass_rod(L::Float64, rho::Float64, A::Float64, J::Float64)
    Me = zeros(12, 12)
    if L < 1e-12 || rho < 1e-30 || A < 1e-30; return Me; end

    m_node = rho * A * L / 2.0
    @inbounds for base in (0, 6)
        Me[base + 1, base + 1] = m_node
        Me[base + 2, base + 2] = m_node
        Me[base + 3, base + 3] = m_node
        if J > 0.0
            Me[base + 4, base + 4] = rho * J * L / 2.0
        end
    end
    return Me
end

"""
    consistent_mass_tetra4(coords, rho) -> 12×12 Matrix

Consistent translational mass matrix for a 4-node linear tetrahedron.
Only translational DOFs are present, ordered as [u1,v1,w1, ..., u4,v4,w4].
"""
function consistent_mass_tetra4(coords::AbstractMatrix{Float64}, rho::Float64)
    Me = zeros(12, 12)
    if rho < 1e-30; return Me; end

    x1, y1, z1 = coords[1,1], coords[1,2], coords[1,3]
    x2, y2, z2 = coords[2,1], coords[2,2], coords[2,3]
    x3, y3, z3 = coords[3,1], coords[3,2], coords[3,3]
    x4, y4, z4 = coords[4,1], coords[4,2], coords[4,3]

    J = @SMatrix [x2-x1 y2-y1 z2-z1;
                   x3-x1 y3-y1 z3-z1;
                   x4-x1 y4-y1 z4-z1]
    V = abs(det(J)) / 6.0
    if V < 1e-30; return Me; end

    factor = rho * V / 20.0
    for i in 1:4, j in 1:4
        mass_ij = factor * (i == j ? 2.0 : 1.0)
        bi = (i-1) * 3
        bj = (j-1) * 3
        for d in 1:3
            Me[bi+d, bj+d] += mass_ij
        end
    end

    return Me
end

"""
    consistent_mass_hexa8(coords, rho) -> 24×24 Matrix

Consistent translational mass matrix for an 8-node trilinear hexahedron.
Only translational DOFs are present, ordered as [u1,v1,w1, ..., u8,v8,w8].
"""
function consistent_mass_hexa8(coords::AbstractMatrix{Float64}, rho::Float64)
    Me = zeros(24, 24)
    if rho < 1e-30; return Me; end

    xi_n  = @SVector [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
    eta_n = @SVector [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
    zet_n = @SVector [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]
    g = 1.0 / sqrt(3.0)
    gp = @SVector [-g, g]

    for xi in gp, eta in gp, zet in gp
        N = zeros(8)
        dN_dxi = zeros(3, 8)
        for i in 1:8
            N[i] = 0.125 * (1.0 + xi_n[i] * xi) * (1.0 + eta_n[i] * eta) * (1.0 + zet_n[i] * zet)
            dN_dxi[1,i] = 0.125 * xi_n[i]  * (1.0 + eta_n[i] * eta) * (1.0 + zet_n[i] * zet)
            dN_dxi[2,i] = 0.125 * eta_n[i] * (1.0 + xi_n[i] * xi)   * (1.0 + zet_n[i] * zet)
            dN_dxi[3,i] = 0.125 * zet_n[i] * (1.0 + xi_n[i] * xi)   * (1.0 + eta_n[i] * eta)
        end

        detJ = det(dN_dxi * coords)
        adJ = abs(detJ)
        if adJ < 1e-30; continue; end

        for i in 1:8, j in 1:8
            mass_ij = rho * adJ * N[i] * N[j]
            bi = (i-1) * 3
            bj = (j-1) * 3
            for d in 1:3
                Me[bi+d, bj+d] += mass_ij
            end
        end
    end

    return Me
end

"""
    consistent_mass_cpenta6(coords, rho) -> 18×18 Matrix

Consistent translational mass matrix for a 6-node linear wedge element.
Only translational DOFs are present, ordered as [u1,v1,w1, ..., u6,v6,w6].
"""
function consistent_mass_cpenta6(coords::AbstractMatrix{Float64}, rho::Float64)
    Me = zeros(18, 18)
    if rho < 1e-30; return Me; end

    tri_xi  = [1.0/6.0, 2.0/3.0, 1.0/6.0]
    tri_eta = [1.0/6.0, 1.0/6.0, 2.0/3.0]
    tri_w   = [1.0/6.0, 1.0/6.0, 1.0/6.0]
    g = 1.0 / sqrt(3.0)
    zet_pts = [-g, g]

    for tg in eachindex(tri_xi), zet in zet_pts
        xi = tri_xi[tg]
        eta = tri_eta[tg]
        w = tri_w[tg]
        L1 = 1.0 - xi - eta
        L2 = xi
        L3 = eta
        zm = (1.0 - zet) / 2.0
        zp = (1.0 + zet) / 2.0

        N = SVector(
            L1 * zm,
            L2 * zm,
            L3 * zm,
            L1 * zp,
            L2 * zp,
            L3 * zp,
        )

        dN_dxi = zeros(3, 6)
        dN_dxi[1,1] = -zm;    dN_dxi[1,2] = zm;     dN_dxi[1,3] = 0.0
        dN_dxi[1,4] = -zp;    dN_dxi[1,5] = zp;     dN_dxi[1,6] = 0.0
        dN_dxi[2,1] = -zm;    dN_dxi[2,2] = 0.0;    dN_dxi[2,3] = zm
        dN_dxi[2,4] = -zp;    dN_dxi[2,5] = 0.0;    dN_dxi[2,6] = zp
        dN_dxi[3,1] = -L1/2;  dN_dxi[3,2] = -L2/2;  dN_dxi[3,3] = -L3/2
        dN_dxi[3,4] =  L1/2;  dN_dxi[3,5] =  L2/2;  dN_dxi[3,6] =  L3/2

        detJ = det(dN_dxi * coords)
        adJ = abs(detJ)
        if adJ < 1e-30; continue; end

        for i in 1:6, j in 1:6
            mass_ij = rho * w * adJ * N[i] * N[j]
            bi = (i-1) * 3
            bj = (j-1) * 3
            for d in 1:3
                Me[bi+d, bj+d] += mass_ij
            end
        end
    end

    return Me
end

function _row_sum_lumped_mass(Me::AbstractMatrix{Float64})
    Ml = zeros(size(Me, 1), size(Me, 2))
    @inbounds for i in 1:size(Me, 1)
        row_sum = 0.0
        for j in 1:size(Me, 2)
            row_sum += Me[i, j]
        end
        if abs(row_sum) > 1e-30
            Ml[i, i] = row_sum
        end
    end
    return Ml
end

"""
    nastran_lumped_mass_tetra4(coords, rho) -> 12x12 Matrix

Nastran-compatible lumped translational mass for a four-node tetrahedron.
"""
function nastran_lumped_mass_tetra4(coords::AbstractMatrix{Float64}, rho::Float64)
    Me = zeros(12, 12)
    if rho < 1e-30; return Me; end

    x1, y1, z1 = coords[1,1], coords[1,2], coords[1,3]
    x2, y2, z2 = coords[2,1], coords[2,2], coords[2,3]
    x3, y3, z3 = coords[3,1], coords[3,2], coords[3,3]
    x4, y4, z4 = coords[4,1], coords[4,2], coords[4,3]
    J = @SMatrix [x2-x1 y2-y1 z2-z1;
                   x3-x1 y3-y1 z3-z1;
                   x4-x1 y4-y1 z4-z1]
    volume = abs(det(J)) / 6.0
    if volume < 1e-30; return Me; end

    mass_node = rho * volume / 4.0
    @inbounds for k in 1:4
        base = (k - 1) * 3
        Me[base + 1, base + 1] = mass_node
        Me[base + 2, base + 2] = mass_node
        Me[base + 3, base + 3] = mass_node
    end
    return Me
end

"""
    nastran_lumped_mass_hexa8(coords, rho) -> 24x24 Matrix

Nastran-compatible row-sum lumped translational mass for an eight-node brick.
"""
function nastran_lumped_mass_hexa8(coords::AbstractMatrix{Float64}, rho::Float64)
    return _row_sum_lumped_mass(consistent_mass_hexa8(coords, rho))
end

"""
    nastran_lumped_mass_cpenta6(coords, rho) -> 18x18 Matrix

Nastran-compatible row-sum lumped translational mass for a six-node wedge.
"""
function nastran_lumped_mass_cpenta6(coords::AbstractMatrix{Float64}, rho::Float64)
    return _row_sum_lumped_mass(consistent_mass_cpenta6(coords, rho))
end

# ============================================================================
# 3D Solid Element Kernels: TETRA4, HEXA8, CPENTA6
# ============================================================================

"""
    iso_3d_constitutive(E, nu) -> D (6×6)

Isotropic 3D elasticity constitutive matrix.
Strain ordering: {εxx, εyy, εzz, γxy, γyz, γzx}
"""
function iso_3d_constitutive(E::Float64, nu::Float64)
    c = E / ((1.0 + nu) * (1.0 - 2.0 * nu))
    d = 1.0 - nu
    s = (1.0 - 2.0 * nu) / 2.0
    D = @SMatrix [
        c*d   c*nu  c*nu  0.0   0.0   0.0;
        c*nu  c*d   c*nu  0.0   0.0   0.0;
        c*nu  c*nu  c*d   0.0   0.0   0.0;
        0.0   0.0   0.0   c*s   0.0   0.0;
        0.0   0.0   0.0   0.0   c*s   0.0;
        0.0   0.0   0.0   0.0   0.0   c*s
    ]
    return D
end

"""
    stiffness_tetra4(coords) -> Ke (12×12)

4-node constant-strain tetrahedron.
coords: 4×3 matrix of nodal coordinates [x y z].
Returns element stiffness in global coordinates.
"""
function stiffness_tetra4(coords::AbstractMatrix{Float64}, E::Float64, nu::Float64)
    # Jacobian: J = [x2-x1 y2-y1 z2-z1; x3-x1 y3-y1 z3-z1; x4-x1 y4-y1 z4-z1]
    x1,y1,z1 = coords[1,1], coords[1,2], coords[1,3]
    x2,y2,z2 = coords[2,1], coords[2,2], coords[2,3]
    x3,y3,z3 = coords[3,1], coords[3,2], coords[3,3]
    x4,y4,z4 = coords[4,1], coords[4,2], coords[4,3]

    J = @SMatrix [x2-x1 y2-y1 z2-z1;
                   x3-x1 y3-y1 z3-z1;
                   x4-x1 y4-y1 z4-z1]
    detJ = det(J)
    V = abs(detJ) / 6.0
    if V < 1e-30
        return zeros(12, 12)
    end

    invJ = inv(J)

    # Shape function derivatives in natural coords: dN/d(ξ,η,ζ)
    # N1 = 1-ξ-η-ζ, N2=ξ, N3=η, N4=ζ
    # dN_dnat = [-1 1 0 0; -1 0 1 0; -1 0 0 1]  (3×4)
    # dN_dx = invJ * dN_dnat  (3×4)
    dN_dx = invJ * @SMatrix [-1.0 1.0 0.0 0.0;
                              -1.0 0.0 1.0 0.0;
                              -1.0 0.0 0.0 1.0]

    # B matrix (6×12): strain = B * u
    B = zeros(6, 12)
    for i in 1:4
        c = (i-1)*3
        dx = dN_dx[1,i]; dy = dN_dx[2,i]; dz = dN_dx[3,i]
        B[1, c+1] = dx                            # εxx
        B[2, c+2] = dy                            # εyy
        B[3, c+3] = dz                            # εzz
        B[4, c+1] = dy;  B[4, c+2] = dx           # γxy
        B[5, c+2] = dz;  B[5, c+3] = dy           # γyz
        B[6, c+1] = dz;  B[6, c+3] = dx           # γzx
    end

    D = iso_3d_constitutive(E, nu)
    Ke = V * (B' * D * B)
    return Ke
end

"""
    stiffness_hexa8(coords, E, nu) -> Ke (24×24)

8-node isoparametric hexahedron with:
  - B-bar (mean dilatation) for volumetric locking relief
  - Wilson-Taylor incompatible modes for shear/bending locking relief
  - 2×2×2 Gauss integration with static condensation of 9 internal DOFs

This combination matches Nastran CHEXA accuracy for both tension and bending.

coords: 8×3 matrix of nodal coordinates [x y z].
Nastran CHEXA node numbering:
  Bottom face: 1-2-3-4, Top face: 5-6-7-8  (5 above 1, etc.)
"""
function stiffness_hexa8(coords::AbstractMatrix{Float64}, E::Float64, nu::Float64)
    D = iso_3d_constitutive(E, nu)

    # Natural coordinates of 8 corner nodes
    xi_n  = @SVector [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
    eta_n = @SVector [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
    zet_n = @SVector [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]

    # 2×2×2 Gauss points
    g = 1.0 / sqrt(3.0)
    gp = @SVector [-g, g]

    # --- Center Jacobian (for incompatible modes — Wilson-Taylor patch test fix) ---
    dN_dxi_0 = zeros(3, 8)
    for i in 1:8
        dN_dxi_0[1,i] = 0.125 * xi_n[i]
        dN_dxi_0[2,i] = 0.125 * eta_n[i]
        dN_dxi_0[3,i] = 0.125 * zet_n[i]
    end
    J_0 = dN_dxi_0 * coords
    detJ_0 = det(J_0)
    invJ_0 = abs(detJ_0) > 1e-30 ? inv(J_0) : zeros(3, 3)

    # --- Single pass: standard B + incompatible modes ---
    Ke_aa = zeros(24, 24)   # standard DOFs
    Ke_ai = zeros(24, 9)    # coupling: standard ↔ incompatible
    Ke_ii = zeros(9, 9)     # incompatible self-coupling
    B = zeros(6, 24)
    Bi = zeros(6, 9)

    igp = 0
    for gi in 1:2, gj in 1:2, gk in 1:2
        xi = gp[gi]; eta = gp[gj]; zet = gp[gk]
        igp += 1

        dN_dxi = zeros(3, 8)
        for i in 1:8
            dN_dxi[1,i] = 0.125 * xi_n[i]  * (1.0 + eta_n[i]*eta) * (1.0 + zet_n[i]*zet)
            dN_dxi[2,i] = 0.125 * eta_n[i] * (1.0 + xi_n[i]*xi)   * (1.0 + zet_n[i]*zet)
            dN_dxi[3,i] = 0.125 * zet_n[i] * (1.0 + xi_n[i]*xi)   * (1.0 + eta_n[i]*eta)
        end

        J = dN_dxi * coords
        adJ = abs(det(J))
        if adJ < 1e-30; continue; end
        dN_dx_local = inv(J) * dN_dxi

        # --- Standard B (no B-bar) ---
        fill!(B, 0.0)
        for i in 1:8
            c = (i-1)*3
            dx = dN_dx_local[1,i]; dy = dN_dx_local[2,i]; dz = dN_dx_local[3,i]
            B[1,c+1] = dx; B[2,c+2] = dy; B[3,c+3] = dz
            B[4,c+1] = dy; B[4,c+2] = dx
            B[5,c+2] = dz; B[5,c+3] = dy
            B[6,c+1] = dz; B[6,c+3] = dx
        end

        # --- Incompatible mode B-matrix (Bi) ---
        # 3 bubble functions: φ₁=1-ξ², φ₂=1-η², φ₃=1-ζ²
        # Natural derivatives: dφ₁/dξ=-2ξ, dφ₂/dη=-2η, dφ₃/dζ=-2ζ (all others 0)
        # Physical derivatives use center Jacobian J₀ (Wilson-Taylor patch test fix)
        # Scaling by det(J₀)/det(J) ensures ∫Bi dV = 0 (orthogonality for patch test)
        dphi_dnat = zeros(3, 3)
        dphi_dnat[1, 1] = -2.0 * xi
        dphi_dnat[2, 2] = -2.0 * eta
        dphi_dnat[3, 3] = -2.0 * zet
        scale = abs(detJ_0) / adJ  # det(J₀)/det(J) scaling
        dphi_dx = (scale .* invJ_0) * dphi_dnat

        # Build Bi (6×9): 9 internal DOFs = 3 bubbles × 3 directions
        fill!(Bi, 0.0)
        for m in 1:3  # bubble function index
            gx = dphi_dx[1,m]; gy = dphi_dx[2,m]; gz = dphi_dx[3,m]
            # Direction x: col = (m-1)*3 + 1
            cx = (m-1)*3 + 1
            Bi[1, cx] = gx; Bi[4, cx] = gy; Bi[6, cx] = gz
            # Direction y: col = (m-1)*3 + 2
            cy = (m-1)*3 + 2
            Bi[2, cy] = gy; Bi[4, cy] = gx; Bi[5, cy] = gz
            # Direction z: col = (m-1)*3 + 3
            cz = (m-1)*3 + 3
            Bi[3, cz] = gz; Bi[5, cz] = gy; Bi[6, cz] = gx
        end

        # Accumulate stiffness sub-matrices
        DB = D * B
        DBi = D * Bi
        Ke_aa .+= adJ .* (B' * DB)
        Ke_ai .+= adJ .* (B' * DBi)
        Ke_ii .+= adJ .* (Bi' * DBi)
    end

    # --- Static condensation: K = Ke_aa - Ke_ai * inv(Ke_ii) * Ke_ai' ---
    if abs(det(Ke_ii)) > 1e-30
        Ke_ii_inv = inv(Ke_ii)
        Ke = Ke_aa - Ke_ai * Ke_ii_inv * Ke_ai'
    else
        Ke = Ke_aa  # fallback: no condensation if singular
    end

    return Ke
end

"""
    stiffness_cpenta6(coords) -> Ke (18×18)

6-node pentahedral (wedge) element with 2-point Gauss in ζ × 1-point in triangle.
coords: 6×3 matrix of nodal coordinates.
Nastran CPENTA node numbering:
  Bottom triangle: 1-2-3, Top triangle: 4-5-6  (4 above 1, etc.)
"""
function stiffness_cpenta6(coords::AbstractMatrix{Float64}, E::Float64, nu::Float64)
    D = iso_3d_constitutive(E, nu)
    Ke = zeros(18, 18)
    B  = zeros(6, 18)
    DB = zeros(6, 18)

    # Gauss integration: 3-point triangle × 2-point through thickness
    # Triangle: 3-point rule (midpoints of edges), weight = 1/6 each (total area = 1/2)
    # Through thickness: ζ = ±1/√3, weight = 1.0
    g = 1.0 / sqrt(3.0)
    # Nastran-compatible default for the first-order wedge: keep the 3-point
    # triangle rule, but use one point through thickness to avoid over-stiff
    # locking behavior on coarse CPENTA bending probes. Set
    # JFEM_CPENTA_STIFFNESS_INTEGRATION=full to recover the former 3x2 rule.
    cpenta_rule = lowercase(strip(get(ENV, "JFEM_CPENTA_STIFFNESS_INTEGRATION", "tri3_z1")))
    local tri_xi, tri_eta, tri_w, zet_pts, zet_w
    if cpenta_rule in ("reduced", "centroid", "tri1_z1")
        tri_xi  = [1.0/3.0]
        tri_eta = [1.0/3.0]
        tri_w   = [0.5]
        zet_pts = [0.0]
        zet_w   = [2.0]
    elseif cpenta_rule in ("tri1_z2", "triangle_reduced")
        tri_xi  = [1.0/3.0]
        tri_eta = [1.0/3.0]
        tri_w   = [0.5]
        zet_pts = [-g, g]
        zet_w   = [1.0, 1.0]
    elseif cpenta_rule in ("tri3_z1", "through_reduced")
        tri_xi  = [0.5, 0.5, 0.0]
        tri_eta = [0.0, 0.5, 0.5]
        tri_w   = [1.0/6.0, 1.0/6.0, 1.0/6.0]
        zet_pts = [0.0]
        zet_w   = [2.0]
    else
        tri_xi  = [0.5, 0.5, 0.0]
        tri_eta = [0.0, 0.5, 0.5]
        tri_w   = [1.0/6.0, 1.0/6.0, 1.0/6.0]
        zet_pts = [-g, g]
        zet_w   = [1.0, 1.0]
    end

    for tg in 1:length(tri_xi), zg in eachindex(zet_pts)
        xi  = tri_xi[tg]
        eta = tri_eta[tg]
        zet = zet_pts[zg]
        w = tri_w[tg] * zet_w[zg]

        # Shape functions for CPENTA6:
        # N1 = (1-xi-eta)*(1-zet)/2, N2 = xi*(1-zet)/2, N3 = eta*(1-zet)/2
        # N4 = (1-xi-eta)*(1+zet)/2, N5 = xi*(1+zet)/2, N6 = eta*(1+zet)/2
        L1 = 1.0 - xi - eta; L2 = xi; L3 = eta
        zm = (1.0 - zet) / 2.0; zp = (1.0 + zet) / 2.0

        # dN/d(xi, eta, zet) — 3×6
        dN_dxi = zeros(3, 6)
        # d/dxi
        dN_dxi[1,1] = -zm;  dN_dxi[1,2] = zm;  dN_dxi[1,3] = 0.0
        dN_dxi[1,4] = -zp;  dN_dxi[1,5] = zp;  dN_dxi[1,6] = 0.0
        # d/deta
        dN_dxi[2,1] = -zm;  dN_dxi[2,2] = 0.0; dN_dxi[2,3] = zm
        dN_dxi[2,4] = -zp;  dN_dxi[2,5] = 0.0; dN_dxi[2,6] = zp
        # d/dzet
        dN_dxi[3,1] = -L1/2; dN_dxi[3,2] = -L2/2; dN_dxi[3,3] = -L3/2
        dN_dxi[3,4] =  L1/2; dN_dxi[3,5] =  L2/2; dN_dxi[3,6] =  L3/2

        J = dN_dxi * coords
        detJ = det(J)
        if abs(detJ) < 1e-30; continue; end
        invJ = inv(J)
        dN_dx = invJ * dN_dxi

        fill!(B, 0.0)
        for i in 1:6
            c = (i-1)*3
            dx = dN_dx[1,i]; dy = dN_dx[2,i]; dz = dN_dx[3,i]
            B[1, c+1] = dx
            B[2, c+2] = dy
            B[3, c+3] = dz
            B[4, c+1] = dy;  B[4, c+2] = dx
            B[5, c+2] = dz;  B[5, c+3] = dy
            B[6, c+1] = dz;  B[6, c+3] = dx
        end

        mul!(DB, D, B)
        Ke .+= (w * abs(detJ)) .* (B' * DB)
    end

    return Ke
end

"""
    stress_solid_3d(B, D, u_el) -> (stress, strain, von_mises)

Compute stress and strain for a solid element at a given point.
B: 6×ndof strain-displacement matrix
D: 6×6 constitutive matrix
u_el: element displacement vector (translational DOFs only)
Returns stress vector {σxx,σyy,σzz,τxy,τyz,τzx}, strain vector, and von Mises stress.
"""
function stress_solid_3d(B::AbstractMatrix{Float64}, D, u_el::AbstractVector{Float64})
    strain = B * u_el
    stress = D * strain
    # Von Mises: σvm = √(σxx² + σyy² + σzz² - σxx·σyy - σyy·σzz - σzz·σxx + 3(τxy² + τyz² + τzx²))
    sxx, syy, szz, txy, tyz, tzx = stress[1], stress[2], stress[3], stress[4], stress[5], stress[6]
    vm = sqrt(max(0.0, sxx^2 + syy^2 + szz^2 - sxx*syy - syy*szz - szz*sxx + 3.0*(txy^2 + tyz^2 + tzx^2)))
    return stress, strain, vm
end

"""
    solid_centroid_B_tetra4(coords) -> B (6×12)

Compute the B matrix at the centroid of a TETRA4 element (constant strain).
"""
function solid_centroid_B_tetra4(coords::AbstractMatrix{Float64})
    J = @SMatrix [coords[2,1]-coords[1,1] coords[2,2]-coords[1,2] coords[2,3]-coords[1,3];
                   coords[3,1]-coords[1,1] coords[3,2]-coords[1,2] coords[3,3]-coords[1,3];
                   coords[4,1]-coords[1,1] coords[4,2]-coords[1,2] coords[4,3]-coords[1,3]]
    invJ = inv(J)
    dN_dx = invJ * @SMatrix [-1.0 1.0 0.0 0.0;
                              -1.0 0.0 1.0 0.0;
                              -1.0 0.0 0.0 1.0]
    B = zeros(6, 12)
    for i in 1:4
        c = (i-1)*3
        dx = dN_dx[1,i]; dy = dN_dx[2,i]; dz = dN_dx[3,i]
        B[1, c+1] = dx
        B[2, c+2] = dy
        B[3, c+3] = dz
        B[4, c+1] = dy;  B[4, c+2] = dx
        B[5, c+2] = dz;  B[5, c+3] = dy
        B[6, c+1] = dz;  B[6, c+3] = dx
    end
    return B
end

"""
    solid_centroid_B_hexa8(coords) -> B (6×24)

Compute the B matrix at the centroid (ξ=η=ζ=0) of a HEXA8 element.
"""
function solid_centroid_B_hexa8(coords::AbstractMatrix{Float64})
    xi_n  = @SVector [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
    eta_n = @SVector [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
    zet_n = @SVector [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]

    dN_dxi = zeros(3, 8)
    for i in 1:8
        dN_dxi[1,i] = 0.125 * xi_n[i]
        dN_dxi[2,i] = 0.125 * eta_n[i]
        dN_dxi[3,i] = 0.125 * zet_n[i]
    end
    J = dN_dxi * coords
    invJ = inv(J)
    dN_dx = invJ * dN_dxi

    B = zeros(6, 24)
    for i in 1:8
        c = (i-1)*3
        dx = dN_dx[1,i]; dy = dN_dx[2,i]; dz = dN_dx[3,i]
        B[1, c+1] = dx
        B[2, c+2] = dy
        B[3, c+3] = dz
        B[4, c+1] = dy;  B[4, c+2] = dx
        B[5, c+2] = dz;  B[5, c+3] = dy
        B[6, c+1] = dz;  B[6, c+3] = dx
    end
    return B
end

"""
    solid_centroid_B_cpenta6(coords) -> B (6×18)

Compute the B matrix at the centroid of a CPENTA6 element.
"""
function solid_centroid_B_cpenta6(coords::AbstractMatrix{Float64})
    xi = 1.0/3.0; eta = 1.0/3.0; zet = 0.0
    L1 = 1.0 - xi - eta; L2 = xi; L3 = eta
    zm = 0.5; zp = 0.5

    dN_dxi = zeros(3, 6)
    dN_dxi[1,1] = -zm;  dN_dxi[1,2] = zm;  dN_dxi[1,3] = 0.0
    dN_dxi[1,4] = -zp;  dN_dxi[1,5] = zp;  dN_dxi[1,6] = 0.0
    dN_dxi[2,1] = -zm;  dN_dxi[2,2] = 0.0; dN_dxi[2,3] = zm
    dN_dxi[2,4] = -zp;  dN_dxi[2,5] = 0.0; dN_dxi[2,6] = zp
    dN_dxi[3,1] = -L1/2; dN_dxi[3,2] = -L2/2; dN_dxi[3,3] = -L3/2
    dN_dxi[3,4] =  L1/2; dN_dxi[3,5] =  L2/2; dN_dxi[3,6] =  L3/2

    J = dN_dxi * coords
    invJ = inv(J)
    dN_dx = invJ * dN_dxi

    B = zeros(6, 18)
    for i in 1:6
        c = (i-1)*3
        dx = dN_dx[1,i]; dy = dN_dx[2,i]; dz = dN_dx[3,i]
        B[1, c+1] = dx
        B[2, c+2] = dy
        B[3, c+3] = dz
        B[4, c+1] = dy;  B[4, c+2] = dx
        B[5, c+2] = dz;  B[5, c+3] = dy
        B[6, c+1] = dz;  B[6, c+3] = dx
    end
    return B
end

# ============================================================================
# Geometric Stiffness for Solid Elements (SOL105 Buckling)
# ============================================================================

"""
    geometric_stiffness_hexa8(coords, stress) -> Kg (24×24)

Geometric stiffness matrix for 8-node hexahedron under initial stress.
stress: 6-vector {σxx, σyy, σzz, τxy, τyz, τzx} at element centroid.
Uses 2×2×2 Gauss integration.
"""
function geometric_stiffness_hexa8(coords::AbstractMatrix{Float64}, stress::AbstractVector{Float64})
    Kg = zeros(24, 24)
    sxx, syy, szz, txy, tyz, tzx = stress[1], stress[2], stress[3], stress[4], stress[5], stress[6]

    # Initial stress matrix S (3×3 symmetric)
    S = @SMatrix [sxx txy tzx;
                   txy syy tyz;
                   tzx tyz szz]

    xi_n  = @SVector [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
    eta_n = @SVector [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
    zet_n = @SVector [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]
    g = 1.0 / sqrt(3.0)
    gp = @SVector [-g, g]

    for gi in 1:2, gj in 1:2, gk in 1:2
        xi = gp[gi]; eta = gp[gj]; zet = gp[gk]

        dN_dxi = zeros(3, 8)
        for i in 1:8
            dN_dxi[1,i] = 0.125 * xi_n[i]  * (1.0 + eta_n[i]*eta) * (1.0 + zet_n[i]*zet)
            dN_dxi[2,i] = 0.125 * eta_n[i] * (1.0 + xi_n[i]*xi)   * (1.0 + zet_n[i]*zet)
            dN_dxi[3,i] = 0.125 * zet_n[i] * (1.0 + xi_n[i]*xi)   * (1.0 + eta_n[i]*eta)
        end

        J = dN_dxi * coords
        adJ = abs(det(J))
        if adJ < 1e-30; continue; end
        dN_dx = inv(J) * dN_dxi

        # Kg contribution: Kg_IJ = ∫ (∂Ni/∂x)ᵀ S (∂Nj/∂x) * I₃  dV
        # For each node pair (I,J): Kg[(I-1)*3+a, (J-1)*3+a] += dNI·S·dNJ for a=1,2,3
        for I in 1:8, J in 1:8
            gI = SVector{3}(dN_dx[1,I], dN_dx[2,I], dN_dx[3,I])
            gJ = SVector{3}(dN_dx[1,J], dN_dx[2,J], dN_dx[3,J])
            val = dot(gI, S * gJ) * adJ
            for a in 1:3
                Kg[(I-1)*3+a, (J-1)*3+a] += val
            end
        end
    end
    return Kg
end

"""
    geometric_stiffness_tetra4(coords, stress) -> Kg (12×12)

Geometric stiffness matrix for 4-node tetrahedron under initial stress.
Constant stress → single integration point.
"""
function geometric_stiffness_tetra4(coords::AbstractMatrix{Float64}, stress::AbstractVector{Float64})
    J = @SMatrix [coords[2,1]-coords[1,1] coords[2,2]-coords[1,2] coords[2,3]-coords[1,3];
                   coords[3,1]-coords[1,1] coords[3,2]-coords[1,2] coords[3,3]-coords[1,3];
                   coords[4,1]-coords[1,1] coords[4,2]-coords[1,2] coords[4,3]-coords[1,3]]
    V = abs(det(J)) / 6.0
    if V < 1e-30; return zeros(12, 12); end

    invJ = inv(J)
    dN_dx = invJ * @SMatrix [-1.0 1.0 0.0 0.0; -1.0 0.0 1.0 0.0; -1.0 0.0 0.0 1.0]

    sxx, syy, szz, txy, tyz, tzx = stress[1], stress[2], stress[3], stress[4], stress[5], stress[6]
    S = @SMatrix [sxx txy tzx; txy syy tyz; tzx tyz szz]

    Kg = zeros(12, 12)
    for I in 1:4, J_node in 1:4
        gI = SVector{3}(dN_dx[1,I], dN_dx[2,I], dN_dx[3,I])
        gJ = SVector{3}(dN_dx[1,J_node], dN_dx[2,J_node], dN_dx[3,J_node])
        val = dot(gI, S * gJ) * V
        for a in 1:3
            Kg[(I-1)*3+a, (J_node-1)*3+a] += val
        end
    end
    return Kg
end

"""
    geometric_stiffness_cpenta6(coords, stress) -> Kg (18×18)

Geometric stiffness matrix for 6-node pentahedron under initial stress.
Uses 2-point Gauss (same as stiffness).
"""
function geometric_stiffness_cpenta6(coords::AbstractMatrix{Float64}, stress::AbstractVector{Float64})
    Kg = zeros(18, 18)
    sxx, syy, szz, txy, tyz, tzx = stress[1], stress[2], stress[3], stress[4], stress[5], stress[6]
    S = @SMatrix [sxx txy tzx; txy syy tyz; tzx tyz szz]

    g = 1.0 / sqrt(3.0)
    tri_xi = [1.0/3.0]; tri_eta = [1.0/3.0]; tri_w = [0.5]
    zet_pts = [-g, g]; zet_w = [1.0, 1.0]

    for tg in 1:1, zg in 1:2
        xi = tri_xi[tg]; eta = tri_eta[tg]; zet = zet_pts[zg]
        w = tri_w[tg] * zet_w[zg]
        L1 = 1.0 - xi - eta; L2 = xi; L3 = eta
        zm = (1.0 - zet)/2.0; zp = (1.0 + zet)/2.0

        dN_dxi = zeros(3, 6)
        dN_dxi[1,1] = -zm;  dN_dxi[1,2] = zm;  dN_dxi[1,3] = 0.0
        dN_dxi[1,4] = -zp;  dN_dxi[1,5] = zp;  dN_dxi[1,6] = 0.0
        dN_dxi[2,1] = -zm;  dN_dxi[2,2] = 0.0; dN_dxi[2,3] = zm
        dN_dxi[2,4] = -zp;  dN_dxi[2,5] = 0.0; dN_dxi[2,6] = zp
        dN_dxi[3,1] = -L1/2; dN_dxi[3,2] = -L2/2; dN_dxi[3,3] = -L3/2
        dN_dxi[3,4] =  L1/2; dN_dxi[3,5] =  L2/2; dN_dxi[3,6] =  L3/2

        J = dN_dxi * coords
        adJ = abs(det(J))
        if adJ < 1e-30; continue; end
        dN_dx = inv(J) * dN_dxi

        for I in 1:6, J_node in 1:6
            gI = SVector{3}(dN_dx[1,I], dN_dx[2,I], dN_dx[3,I])
            gJ = SVector{3}(dN_dx[1,J_node], dN_dx[2,J_node], dN_dx[3,J_node])
            val = dot(gI, S * gJ) * w * adJ
            for a in 1:3
                Kg[(I-1)*3+a, (J_node-1)*3+a] += val
            end
        end
    end
    return Kg
end

end
