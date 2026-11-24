# Eight-node shell (CQUAD8) stiffness for flat parallelogram elements.
#
# The integration rules below were measured on single-element stiffness
# matrices of the reference solver (squares, rectangles 2:1 and 5:1, a
# 60 degree rhombus, thin and thick, Poisson ratio 0 and 0.33) and reproduce
# those matrices to the printed digits:
#
# * element axes: x bisects the two natural directions and is turned back by
#   45 degrees (the doubly bisected frame of CQUAD8);
# * membrane: every term at 2 x 2 Gauss points, plus one quarter of the extra
#   stiffness the direct strain along x gains with three Gauss points along
#   eta, and the direct strain along y with three points along xi;
# * bending: every term at 2 x 2, plus the extra stiffness of 2 x 3 and 3 x 2
#   points evaluated with the twisting term taken four times;
# * transverse shear: strains sampled at the 2 x 2 points; the flexibility of
#   the samples is 1/(G ts) per unit area plus a part inversely proportional
#   to the bending stiffness, diagonal in the patterns (constant, linear in
#   xi, linear in eta, bilinear) of each strain component;
# * no stiffness about the normal.
#
# Elements that are not flat parallelograms with centred midside nodes are not
# covered by these measurements; `quad8_shell_parallelogram` tells them apart.

const _Q8S_G2 = ((-1/sqrt(3), 1/sqrt(3)), (1.0, 1.0))
const _Q8S_G3 = ((-sqrt(0.6), 0.0, sqrt(0.6)), (5/9, 8/9, 5/9))

"""
    quad8_shell_parallelogram(xyz; tolerance=1e-6) -> Bool

True when the eight nodes (8×3, CQUAD8 order) lie on a flat parallelogram with
each midside node at the middle of its side, within `tolerance` of the longest
side.
"""
function quad8_shell_parallelogram(xyz::AbstractMatrix; tolerance::Float64=1e-6)
    size(xyz) == (8, 3) || return false
    p(k) = SVector(xyz[k, 1], xyz[k, 2], xyz[k, 3])
    scale = max(norm(p(2) - p(1)), norm(p(4) - p(1)))
    scale > 0 || return false
    limit = tolerance*scale
    norm(p(1) + p(3) - p(2) - p(4)) <= limit || return false
    for (m, a, b) in ((5, 1, 2), (6, 2, 3), (7, 3, 4), (8, 4, 1))
        norm(p(m) - (p(a) + p(b))/2) <= limit || return false
    end
    normal = cross(p(2) - p(1), p(4) - p(1))
    return norm(normal) > 1e-12*scale^2
end

"""
    quad8_shell_axes(xyz) -> (R, centre)

Element axes of a flat CQUAD8 as the columns of `R`: the bisector of the two
natural directions at the centre turned by -45 degrees gives x, the normal
G1G2 × G1G4 gives z.
"""
function quad8_shell_axes(xyz::AbstractMatrix)
    p(k) = SVector(xyz[k, 1], xyz[k, 2], xyz[k, 3])
    gxi = (p(2) + p(3) - p(1) - p(4))/4
    geta = (p(3) + p(4) - p(1) - p(2))/4
    ez = normalize(cross(gxi, geta))
    a = normalize(normalize(gxi) + normalize(geta))
    b = cross(ez, a)
    ex = (a - b)/sqrt(2); ey = (a + b)/sqrt(2)
    centre = (p(1) + p(2) + p(3) + p(4))/4
    return hcat(ex, ey, ez), centre
end

# Shape functions and local derivatives at (r, s) for local coordinates xy (8×2).
function _q8s_point(xy::AbstractMatrix, r::Float64, s::Float64)
    N, dr, ds = shape_quad8(r, s)
    j11 = 0.0; j12 = 0.0; j21 = 0.0; j22 = 0.0
    @inbounds for k in 1:8
        j11 += dr[k]*xy[k, 1]; j12 += dr[k]*xy[k, 2]
        j21 += ds[k]*xy[k, 1]; j22 += ds[k]*xy[k, 2]
    end
    detJ = j11*j22 - j12*j21
    dx = zeros(8); dy = zeros(8)
    @inbounds for k in 1:8
        dx[k] = (j22*dr[k] - j12*ds[k])/detJ
        dy[k] = (-j21*dr[k] + j11*ds[k])/detJ
    end
    return N, dx, dy, detJ, (j11, j12, j21, j22)
end

"""
    stiffness_quad8_shell(xyz; membrane, bending, shear, bending_reference) -> 48×48 Matrix

Stiffness of a flat parallelogram CQUAD8 in the frame of `xyz` (8×3 node
coordinates), degrees of freedom (u, v, w, θx, θy, θz) per node.

`membrane` and `bending` are the 3×3 in-plane and bending matrices in element
axes (`nothing` leaves the part out). `shear` is the transverse shear stiffness
G·ts per unit area, `Inf` when the property has no MID3. `bending_reference`
is the plate bending stiffness that scales the bending-dependent part of the
shear flexibility (D11 of an isotropic plate).
"""
function stiffness_quad8_shell(xyz::AbstractMatrix; membrane=nothing, bending=nothing,
                               shear::Float64=Inf, bending_reference::Float64=0.0)
    quad8_shell_parallelogram(xyz) || throw(ArgumentError("stiffness_quad8_shell requires a flat parallelogram with centred midside nodes"))
    R, centre = quad8_shell_axes(xyz)
    xy = zeros(8, 2)
    @inbounds for k in 1:8
        d = SVector(xyz[k, 1], xyz[k, 2], xyz[k, 3]) - centre
        xy[k, 1] = dot(d, R[:, 1]); xy[k, 2] = dot(d, R[:, 2])
    end
    Kl = zeros(48, 48)
    g2p, g2w = _Q8S_G2; g3p, g3w = _Q8S_G3

    if membrane !== nothing
        A = membrane
        B = zeros(3, 48)
        for r in g2p, s in g2p
            _, dx, dy, detJ, _ = _q8s_point(xy, r, s)
            fill!(B, 0.0)
            @inbounds for k in 1:8
                c = 6(k - 1)
                B[1, c+1] = dx[k]; B[2, c+2] = dy[k]; B[3, c+1] = dy[k]; B[3, c+2] = dx[k]
            end
            Kl .+= detJ .* (B' * A * B)
        end
        # a quarter of the direct-strain excess: x with three points along eta, y with three along xi
        b = zeros(48)
        for (row, modulus) in ((1, A[1, 1]), (2, A[2, 2]))
            for (pr, wr, ps, ws, sign) in (row == 1 ? ((g2p, g2w, g3p, g3w, 1.0), (g2p, g2w, g2p, g2w, -1.0)) :
                                                      ((g3p, g3w, g2p, g2w, 1.0), (g2p, g2w, g2p, g2w, -1.0)))
                for (i, r) in enumerate(pr), (j, s) in enumerate(ps)
                    _, dx, dy, detJ, _ = _q8s_point(xy, r, s)
                    fill!(b, 0.0)
                    @inbounds for k in 1:8
                        b[6(k - 1)+row] = row == 1 ? dx[k] : dy[k]
                    end
                    Kl .+= (0.25*sign*wr[i]*ws[j]*detJ*modulus) .* (b * b')
                end
            end
        end
    end

    if bending !== nothing
        D = bending
        Dx = [D[1, 1] D[1, 2] 0.0; D[1, 2] D[2, 2] 0.0; 0.0 0.0 4D[3, 3]]
        B = zeros(3, 48)
        curvature!(dx, dy) = begin
            fill!(B, 0.0)
            @inbounds for k in 1:8
                c = 6(k - 1)
                B[1, c+5] = dx[k]; B[2, c+4] = -dy[k]; B[3, c+5] = dy[k]; B[3, c+4] = -dx[k]
            end
        end
        for r in g2p, s in g2p
            _, dx, dy, detJ, _ = _q8s_point(xy, r, s)
            curvature!(dx, dy)
            Kl .+= detJ .* (B' * D * B) .- (2detJ) .* (B' * Dx * B)
        end
        for (pr, wr, ps, ws) in ((g2p, g2w, g3p, g3w), (g3p, g3w, g2p, g2w))
            for (i, r) in enumerate(pr), (j, s) in enumerate(ps)
                _, dx, dy, detJ, _ = _q8s_point(xy, r, s)
                curvature!(dx, dy)
                Kl .+= (wr[i]*ws[j]*detJ) .* (B' * Dx * B)
            end
        end

        # transverse shear sampled at the 2 x 2 points
        bending_reference > 0 || throw(ArgumentError("stiffness_quad8_shell needs a positive bending_reference with bending"))
        Bs = zeros(8, 48)
        detJ0 = 0.0; jac = (0.0, 0.0, 0.0, 0.0)
        sample = 0
        for r in g2p, s in g2p
            N, dx, dy, detJ, jj = _q8s_point(xy, r, s)
            detJ0 = detJ; jac = jj
            @inbounds for k in 1:8
                c = 6(k - 1)
                Bs[2sample+1, c+3] = dx[k]; Bs[2sample+1, c+5] = N[k]
                Bs[2sample+2, c+3] = dy[k]; Bs[2sample+2, c+4] = -N[k]
            end
            sample += 1
        end
        rx = detJ0/jac[1]^2; ry = detJ0/jac[4]^2
        # patterns over the samples (-,-), (-,+), (+,-), (+,+): constant, xi, eta, xi eta
        patterns = ((1.0, 1.0, 1.0, 1.0), (-1.0, -1.0, 1.0, 1.0), (-1.0, 1.0, -1.0, 1.0), (1.0, -1.0, -1.0, 1.0))
        sx = (12rx + 1200ry, 9.6rx, 12rx + 400ry, 12rx + 120ry)
        sy = (12ry + 1200rx, 12ry + 400rx, 9.6ry, 12ry + 120rx)
        F = zeros(8, 8)
        base = isfinite(shear) ? 1/(shear*detJ0) : 0.0
        for q in 1:8
            F[q, q] = base
        end
        for (component, stiff) in ((1, sx), (2, sy)), k in 1:4
            f = 1/(stiff[k]*bending_reference)/4
            for a in 1:4, c in 1:4
                F[2(a - 1)+component, 2(c - 1)+component] += f*patterns[k][a]*patterns[k][c]
            end
        end
        Kl .+= Bs' * (F \ Bs)
    end

    T = zeros(48, 48)
    @inbounds for k in 1:8, blk in 0:1
        c = 6(k - 1) + 3blk
        for a in 1:3, bb in 1:3
            T[c+a, c+bb] = R[bb, a]          # local = R' * frame
        end
    end
    K = T' * Kl * T
    return (K + K')/2
end
