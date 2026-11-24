# Finite-element conversion of beam cross-sections.
#
# PBARL, PBEAML, PBRSECT and PBMSECT sections are converted to PBAR/PBEAM values with a
# finite-element solution on the section, the conversion method of the input format. The method
# was established on six section meshes of the reference solver and on its printed properties
# for 90 library sections:
#   - elements are six-node triangles; the Saint-Venant warping solution on the reference meshes
#     reproduces the printed area, inertias, torsion constant and shear factors to the printed
#     digits;
#   - boundary subdivision: target size h = sqrt(area)/SECTION_SIZE_DIVISOR; a straight outline
#     segment of length L gets N equal edges, N the largest power of two not above L/h (at least
#     one); next to a re-entrant corner the nearest of those edges is cut into 1/4, 1/4, 1/2 of its
#     length and the next one into two halves;
#   - a re-entrant corner is surrounded by four triangles whose interior edges are about as long as
#     the smallest boundary edge at the corner.
# The edge counts of the exported meshes bound the size factor h/sqrt(area) above 0.1159 and at
# most 0.125; the value used, 1/8.3, is the middle of that interval. Over the 85 non-circular
# library sections the torsion constant differs from the reference by 0.17 % rms (0.43 % at most)
# and this spread is the same for every factor in the interval, so the choice inside it is not
# a tuned quantity. The interior triangulation of the reference is unstructured and is not
# reproduced: interior points come from a Delaunay refinement to a graded size field, and that
# difference is what the remaining spread measures.
#
# Section coordinates are (z, y): z along the element z axis (horizontal in the section figures),
# y along the element y axis. I1 = integral y^2, I2 = integral z^2, I12 = integral y z about the
# centroid. Shear factors are the energy-equivalent values of the two Poisson problems with unit
# bending-stress gradients, without Poisson coupling (6/7 for a circle, 5/6 for a rectangle).

const SECTION_SIZE_DIVISOR = 8.3
const SECTION_GRADATION = 0.4
const SECTION_FAN = 4
const SECTION_CIRCLE_EDGES = 32
const SECTION_MINIMUM_ANGLE = 25.0

struct SectionLoop
    points::Vector{NTuple{2,Float64}}
    radius::Float64                  # > 0: the loop is a circle of this radius about `center`
    center::NTuple{2,Float64}
end
SectionLoop(points) = SectionLoop(collect(NTuple{2,Float64}, points), 0.0, (0.0, 0.0))

_sec_cross(a, b) = a[1] * b[2] - a[2] * b[1]
_sec_sub(a, b) = (a[1] - b[1], a[2] - b[2])
_sec_norm(a) = hypot(a[1], a[2])
function _sec_area(points)
    s = 0.0; n = length(points)
    for i in 1:n
        s += _sec_cross(points[i], points[i == n ? 1 : i + 1])
    end
    s / 2
end
_sec_rect(z0, y0, z1, y1) = [(z0, y0), (z1, y0), (z1, y1), (z0, y1)]
_sec_circle(r) = SectionLoop([(r * cos(2pi * k / SECTION_CIRCLE_EDGES), r * sin(2pi * k / SECTION_CIRCLE_EDGES)) for k in 0:SECTION_CIRCLE_EDGES-1], r, (0.0, 0.0))

"Number of dimensions of a library section known to the finite-element conversion, or `nothing`."
function section_library_dimension_count(type::AbstractString)
    type in ("ROD",) && return 1
    type in ("TUBE", "TUBE2", "BAR") && return 2
    type == "HEXA" && return 3
    type in ("BOX", "T", "T1", "T2", "I1", "CHAN", "CHAN1", "CHAN2", "Z", "L", "H", "CROSS", "HAT") && return 4
    type in ("I", "BOX1") && return 6
    nothing
end

"""
    section_library_loops(type, dims)

Outline of a beam-library section as loops of (z, y) points, the outer loop first. Every
definition was checked against the area and inertias of the reference solver.
Returns `nothing` for a section type without a definition here.
"""
function section_library_loops(type::AbstractString, dims)
    count = section_library_dimension_count(type)
    count === nothing && return nothing
    length(dims) >= count || throw(ArgumentError("section $type needs $count dimensions, got $(length(dims))"))
    d = Float64.(dims[1:count])
    all(x -> isfinite(x) && x > 0, d) || throw(ArgumentError("section $type needs finite positive dimensions, got $d"))
    need(ok, text) = ok || throw(ArgumentError("section $type $d: $text"))
    if type == "ROD"
        return [_sec_circle(d[1])]
    elseif type == "TUBE"
        need(d[2] < d[1], "the inner radius must be smaller than the outer radius")
        return [_sec_circle(d[1]), _sec_circle(d[2])]
    elseif type == "TUBE2"
        need(d[2] < d[1], "the wall thickness must be smaller than the outer radius")
        return [_sec_circle(d[1]), _sec_circle(d[1] - d[2])]
    elseif type == "BAR"
        return [SectionLoop(_sec_rect(-d[1] / 2, -d[2] / 2, d[1] / 2, d[2] / 2))]
    elseif type == "BOX"
        w, h, t1, t2 = d                 # t1: top and bottom walls, t2: side walls
        need(2t1 < h && 2t2 < w, "the walls leave no opening")
        return [SectionLoop(_sec_rect(-w / 2, -h / 2, w / 2, h / 2)), SectionLoop(_sec_rect(-w / 2 + t2, -h / 2 + t1, w / 2 - t2, h / 2 - t1))]
    elseif type == "BOX1"
        w, h, tt, tb, tr, tl = d         # top, bottom, +z side, -z side walls
        need(tt + tb < h && tr + tl < w, "the walls leave no opening")
        return [SectionLoop(_sec_rect(-w / 2, -h / 2, w / 2, h / 2)), SectionLoop(_sec_rect(-w / 2 + tl, -h / 2 + tb, w / 2 - tr, h / 2 - tt))]
    elseif type == "T"
        bf, h, tf, tw = d                # flange on top
        need(tw <= bf && tf <= h, "the web is wider than the flange or the flange thicker than the height")
        return [SectionLoop([(-tw / 2, 0.0), (tw / 2, 0.0), (tw / 2, h - tf), (bf / 2, h - tf), (bf / 2, h), (-bf / 2, h), (-bf / 2, h - tf), (-tw / 2, h - tf)])]
    elseif type == "T2"
        bf, h, tf, tw = d                # flange at the bottom
        need(tw <= bf && tf <= h, "the web is wider than the flange or the flange thicker than the height")
        return [SectionLoop([(-bf / 2, 0.0), (bf / 2, 0.0), (bf / 2, tf), (tw / 2, tf), (tw / 2, h), (-tw / 2, h), (-tw / 2, tf), (-bf / 2, tf)])]
    elseif type == "T1"
        hf, lw, tf, tw = d               # flange of height hf on the +z side, web of length lw
        need(tw <= hf, "the web is thicker than the flange height")
        return [SectionLoop([(0.0, -tw / 2), (lw, -tw / 2), (lw, -hf / 2), (lw + tf, -hf / 2), (lw + tf, hf / 2), (lw, hf / 2), (lw, tw / 2), (0.0, tw / 2)])]
    elseif type == "I"
        H, bb, bt, tw, tfb, tft = d
        need(tfb + tft <= H && tw <= bb && tw <= bt, "the flanges or the web do not fit the height and widths")
        return [SectionLoop([(-bb / 2, 0.0), (bb / 2, 0.0), (bb / 2, tfb), (tw / 2, tfb), (tw / 2, H - tft), (bt / 2, H - tft), (bt / 2, H), (-bt / 2, H),
            (-bt / 2, H - tft), (-tw / 2, H - tft), (-tw / 2, tfb), (-bb / 2, tfb)])]
    elseif type == "I1"
        ov, tw, hw, H = d                # ov: the two flange overhangs together
        need(hw < H, "the web height must be smaller than the total height")
        tf = (H - hw) / 2; b = ov + tw
        return [SectionLoop([(-b / 2, 0.0), (b / 2, 0.0), (b / 2, tf), (tw / 2, tf), (tw / 2, H - tf), (b / 2, H - tf), (b / 2, H), (-b / 2, H),
            (-b / 2, H - tf), (-tw / 2, H - tf), (-tw / 2, tf), (-b / 2, tf)])]
    elseif type == "CHAN"
        bf, h, tw, tf = d                # web on the -z side
        need(2tf <= h && tw <= bf, "the flanges or the web do not fit")
        return [SectionLoop([(0.0, 0.0), (bf, 0.0), (bf, tf), (tw, tf), (tw, h - tf), (bf, h - tf), (bf, h), (0.0, h)])]
    elseif type == "CHAN1"
        ov, tw, hw, H = d
        need(hw < H, "the web height must be smaller than the total height")
        tf = (H - hw) / 2; bf = ov + tw
        return [SectionLoop([(0.0, 0.0), (bf, 0.0), (bf, tf), (tw, tf), (tw, H - tf), (bf, H - tf), (bf, H), (0.0, H)])]
    elseif type == "CHAN2"
        tw, tb, h, b = d                 # two side walls and a bottom web, open towards +y
        need(2tw <= b && tb <= h, "the walls do not fit the width or the web the height")
        return [SectionLoop([(-b / 2, 0.0), (b / 2, 0.0), (b / 2, h), (b / 2 - tw, h), (b / 2 - tw, tb), (-b / 2 + tw, tb), (-b / 2 + tw, h), (-b / 2, h)])]
    elseif type == "Z"
        ov, tw, hw, H = d                # bottom flange towards +z, top flange towards -z
        need(hw < H, "the web height must be smaller than the total height")
        tf = (H - hw) / 2
        return [SectionLoop([(0.0, 0.0), (tw + ov, 0.0), (tw + ov, tf), (tw, tf), (tw, H), (-ov, H), (-ov, H - tf), (0.0, H - tf)])]
    elseif type == "L"
        a, b, t1, t2 = d                 # leg a along z of thickness t1, leg b along y of thickness t2
        need(t2 <= a && t1 <= b, "a leg is thinner than the other leg's thickness")
        return [SectionLoop([(0.0, 0.0), (a, 0.0), (a, t1), (t2, t1), (t2, b), (0.0, b)])]
    elseif type == "H"
        lw, t2, hf, tw = d               # web of length lw between two flanges of height hf, each t2/2 thick
        need(tw <= hf, "the web is thicker than the flange height")
        tf = t2 / 2
        return [SectionLoop([(-lw / 2 - tf, -hf / 2), (-lw / 2, -hf / 2), (-lw / 2, -tw / 2), (lw / 2, -tw / 2), (lw / 2, -hf / 2), (lw / 2 + tf, -hf / 2),
            (lw / 2 + tf, hf / 2), (lw / 2, hf / 2), (lw / 2, tw / 2), (-lw / 2, tw / 2), (-lw / 2, hf / 2), (-lw / 2 - tf, hf / 2)])]
    elseif type == "CROSS"
        la, ta, hv, tv = d               # la: the two arms along z together
        need(ta <= hv, "the arms are thicker than the height")
        a = la / 2 + tv / 2
        return [SectionLoop([(-tv / 2, -hv / 2), (tv / 2, -hv / 2), (tv / 2, -ta / 2), (a, -ta / 2), (a, ta / 2), (tv / 2, ta / 2), (tv / 2, hv / 2), (-tv / 2, hv / 2),
            (-tv / 2, ta / 2), (-a, ta / 2), (-a, -ta / 2), (-tv / 2, -ta / 2)])]
    elseif type == "HAT"
        H, t, wt, wb = d                 # height, thickness, top width, width of each bottom flange
        need(2t < wt && t < H, "the thickness does not fit the top width or the height")
        return [SectionLoop([(-wt / 2 - wb, 0.0), (-wt / 2 + t, 0.0), (-wt / 2 + t, H - t), (wt / 2 - t, H - t), (wt / 2 - t, 0.0), (wt / 2 + wb, 0.0), (wt / 2 + wb, t), (wt / 2, t),
            (wt / 2, H), (-wt / 2, H), (-wt / 2, t), (-wt / 2 - wb, t)])]
    elseif type == "HEXA"
        a, w, h = d                      # points on the z axis, flats of width w - 2a
        need(2a <= w, "the two tapers are wider than the section")
        return [SectionLoop([(-w / 2 + a, -h / 2), (w / 2 - a, -h / 2), (w / 2, 0.0), (w / 2 - a, h / 2), (-w / 2 + a, h / 2), (-w / 2, 0.0)])]
    end
    nothing
end

"Remove repeated points and vertices on a straight line, so that degenerate dimensions give a clean polygon."
function _sec_clean(points, scale)
    p = NTuple{2,Float64}[]
    for q in points
        (isempty(p) || _sec_norm(_sec_sub(q, p[end])) > 1e-12 * scale) && push!(p, q)
    end
    length(p) > 1 && _sec_norm(_sec_sub(p[1], p[end])) <= 1e-12 * scale && pop!(p)
    changed = true
    while changed && length(p) > 3
        changed = false
        for i in eachindex(p)
            a = p[i == 1 ? length(p) : i - 1]; b = p[i]; c = p[i == length(p) ? 1 : i + 1]
            if abs(_sec_cross(_sec_sub(b, a), _sec_sub(c, b))) <= 1e-12 * scale^2
                deleteat!(p, i); changed = true; break
            end
        end
    end
    p
end

# ------------------------------------------------------------------------------------------- seeding
"""
Boundary points of the section following the measured subdivision rule. Returns the seeded loops
(outer loop counter-clockwise, holes clockwise, so that material lies to the left of every edge),
the fan points around re-entrant corners and the target size.
"""
function _sec_seed(loops::Vector{SectionLoop}; divisor=SECTION_SIZE_DIVISOR, fan=SECTION_FAN)
    scale = maximum(maximum(abs, q) for l in loops for q in l.points)
    prepared = SectionLoop[]
    for (i, l) in enumerate(loops)
        pts = l.radius > 0 ? copy(l.points) : _sec_clean(l.points, scale)
        length(pts) >= 3 || throw(ArgumentError("a section outline needs at least three distinct points"))
        (_sec_area(pts) > 0) == (i == 1) || reverse!(pts)
        push!(prepared, SectionLoop(pts, l.radius, l.center))
    end
    area = sum(l.radius > 0 ? (i == 1 ? 1 : -1) * pi * l.radius^2 : _sec_area(l.points) for (i, l) in enumerate(prepared))
    area > 0 || throw(ArgumentError("the section outline encloses no area"))
    h = sqrt(area) / divisor
    seeded = SectionLoop[]; fans = NTuple{2,Float64}[]
    for l in prepared
        if l.radius > 0
            push!(seeded, l); continue
        end
        P = l.points; n = length(P)
        reentrant = [_sec_cross(_sec_sub(P[i], P[i == 1 ? n : i - 1]), _sec_sub(P[i == n ? 1 : i + 1], P[i])) < -1e-14 * area for i in 1:n]
        pts = NTuple{2,Float64}[]
        for i in 1:n
            a = P[i]; b = P[i == n ? 1 : i + 1]; L = _sec_norm(_sec_sub(b, a))
            N = L / h >= 1 ? 2^floor(Int, log2(L / h) + 1e-9) : 1
            t = Float64[k / N for k in 0:N-1]
            if reentrant[i]
                append!(t, (0.25 / N, 0.5 / N)); N >= 2 && push!(t, 1.5 / N)
            end
            if reentrant[i == n ? 1 : i + 1]
                append!(t, (1 - 0.25 / N, 1 - 0.5 / N)); N >= 2 && push!(t, 1 - 1.5 / N)
            end
            for s in sort!(unique!(t))
                0 <= s < 1 - 1e-12 && push!(pts, (a[1] + s * (b[1] - a[1]), a[2] + s * (b[2] - a[2])))
            end
        end
        if fan > 1
            for i in 1:n
                reentrant[i] || continue
                b = P[i]; a = P[i == 1 ? n : i - 1]; c = P[i == n ? 1 : i + 1]
                r = minimum(_sec_norm(_sec_sub(q, b)) for q in pts if _sec_norm(_sec_sub(q, b)) > 0)
                u = _sec_sub(c, b); v = _sec_sub(a, b)
                start = atan(u[2], u[1]); sweep = mod(atan(v[2], v[1]) - start, 2pi)
                for k in 1:fan-1
                    ang = start + sweep * k / fan
                    push!(fans, (b[1] + r * cos(ang), b[2] + r * sin(ang)))
                end
            end
        end
        push!(seeded, SectionLoop(pts, 0.0, (0.0, 0.0)))
    end
    seeded, fans, h
end

# ------------------------------------------------------------------------------------- triangulation
function _sec_inside(loops, q)
    c = false
    for l in loops
        P = l.points; n = length(P)
        for i in 1:n
            a = P[i]; b = P[i == n ? 1 : i + 1]
            if (a[2] > q[2]) != (b[2] > q[2]) && q[1] < (b[1] - a[1]) * (q[2] - a[2]) / (b[2] - a[2]) + a[1]
                c = !c
            end
        end
    end
    c
end

_sec_orient(a, b, c) = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
function _sec_incircle(a, b, c, d)
    ax = a[1] - d[1]; ay = a[2] - d[2]; bx = b[1] - d[1]; by = b[2] - d[2]; cx = c[1] - d[1]; cy = c[2] - d[2]
    (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay) + (cx * cx + cy * cy) * (ax * by - bx * ay)
end

mutable struct _SecTriangulation
    points::Vector{NTuple{2,Float64}}     # three enclosing points, then the section points (normalized)
    triangles::Vector{NTuple{3,Int}}
    alive::Vector{Bool}
end

# Coordinates are normalized by the caller to a box of size about one. Point k of the section is
# index k + 3 here; indices 1 to 3 are the enclosing triangle.
_sec_triangulation() = _SecTriangulation([(-3000.0, -3000.0), (3000.0, -3000.0), (0.0, 3000.0)], [(1, 2, 3)], [true])

"Insert point `p` (index into `tri.points`) by the Bowyer-Watson cavity. Returns the new triangle indices, empty when the point cannot be placed."
function _sec_insert!(tri::_SecTriangulation, p::Int)
    P = tri.points; q = P[p]
    bad = Int[]
    for (i, t) in enumerate(tri.triangles)
        tri.alive[i] || continue
        _sec_incircle(P[t[1]], P[t[2]], P[t[3]], q) > 1e-13 && push!(bad, i)
    end
    isempty(bad) && return Int[]
    for attempt in 1:8
        edges = Dict{Tuple{Int,Int},Int}()
        for i in bad
            t = tri.triangles[i]
            for (a, b) in ((t[1], t[2]), (t[2], t[3]), (t[3], t[1]))
                if haskey(edges, (b, a))
                    delete!(edges, (b, a))
                else
                    edges[(a, b)] = i
                end
            end
        end
        degenerate = [i for ((a, b), i) in edges if _sec_orient(P[a], P[b], q) <= 1e-14]
        if isempty(degenerate)
            for i in bad
                tri.alive[i] = false
            end
            created = Int[]
            for (a, b) in keys(edges)
                push!(tri.triangles, (a, b, p)); push!(tri.alive, true); push!(created, length(tri.triangles))
            end
            return created
        end
        # A triangle whose cavity edge does not see the point is kept out of the cavity.
        bad = setdiff(bad, degenerate)
        isempty(bad) && return Int[]
    end
    Int[]
end

"""
    section_mesh(loops) -> (nodes, triangles, info)

Six-node triangle mesh of a section. `triangles` holds corner nodes 1-3 and the midside nodes of
edges 1-2, 2-3 and 3-1. Midside nodes of a circular outline lie on the circle.
"""
function section_mesh(loops::Vector{SectionLoop}; divisor=SECTION_SIZE_DIVISOR, gradation=SECTION_GRADATION, fan=SECTION_FAN, maximum_points=20000)
    seeded, fans, h = _sec_seed(loops; divisor, fan)
    for restart in 1:40
        result = _sec_mesh_seeded(seeded, fans, h, gradation, maximum_points)
        result isa Tuple && return (result[1], result[2], merge(result[3], (target_size=h, boundary_splits=restart - 1)))
        # A boundary edge that the Delaunay triangulation does not contain is halved (not seen on
        # any measured section; it keeps the mesher from failing on unusual outlines).
        loop, edge = result
        P = seeded[loop].points; n = length(P)
        a = P[edge]; b = P[edge == n ? 1 : edge + 1]
        mid = seeded[loop].radius > 0 ? begin
            c = seeded[loop].center; m = ((a[1] + b[1]) / 2 - c[1], (a[2] + b[2]) / 2 - c[2]); r = seeded[loop].radius / _sec_norm(m)
            (c[1] + m[1] * r, c[2] + m[2] * r)
        end : ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
        insert!(P, edge + 1, mid)
    end
    throw(ArgumentError("the section outline could not be meshed: boundary edges remain missing after repeated subdivision"))
end

function _sec_mesh_seeded(seeded, fans, h, gradation, maximum_points)
    boundary = NTuple{2,Float64}[]; loop_of = Int[]; next_of = Int[]
    for (k, l) in enumerate(seeded)
        start = length(boundary) + 1; n = length(l.points)
        for i in 1:n
            push!(boundary, l.points[i]); push!(loop_of, k); push!(next_of, i == n ? start : start + i)
        end
    end
    nb = length(boundary)
    lo = (minimum(p[1] for p in boundary), minimum(p[2] for p in boundary)); hi = (maximum(p[1] for p in boundary), maximum(p[2] for p in boundary))
    centre = ((lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2); scale = max(hi[1] - lo[1], hi[2] - lo[2])
    normal(p) = ((p[1] - centre[1]) / scale, (p[2] - centre[2]) / scale)
    points = vcat(boundary, fans)
    tri = _sec_triangulation()
    for p in eachindex(points)
        push!(tri.points, normal(points[p]))
        isempty(_sec_insert!(tri, p + 3)) && throw(ArgumentError("section mesher: a boundary point could not be inserted (coincident outline points?)"))
    end
    blen = [_sec_norm(_sec_sub(boundary[next_of[i]], boundary[i])) for i in 1:nb]
    bmid = [((boundary[i][1] + boundary[next_of[i]][1]) / 2, (boundary[i][2] + boundary[next_of[i]][2]) / 2) for i in 1:nb]
    sizeat(q) = minimum(blen[i] + gradation * max(_sec_norm(_sec_sub(bmid[i], q)) - blen[i] / 2, 0.0) for i in 1:nb)
    real(i) = (t = tri.triangles[i]; t[1] > 3 && t[2] > 3 && t[3] > 3)
    none = (0.0, (0.0, 0.0), 0.0)
    # Score of a triangle with its circumcentre and the target size there; zero when the triangle
    # needs no point or cannot take one.
    function score(i)
        real(i) || return none
        t = tri.triangles[i]; a = points[t[1]-3]; b = points[t[2]-3]; c = points[t[3]-3]
        area = _sec_orient(a, b, c) / 2
        area > 1e-18 * scale^2 || return none
        _sec_inside(seeded, ((a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3)) || return none
        la = _sec_norm(_sec_sub(b, c)); lb = _sec_norm(_sec_sub(c, a)); lc = _sec_norm(_sec_sub(a, b))
        R = la * lb * lc / (4area)
        aa = a[1]^2 + a[2]^2; bb = b[1]^2 + b[2]^2; cc = c[1]^2 + c[2]^2
        d = 2 * (a[1] * (b[2] - c[2]) + b[1] * (c[2] - a[2]) + c[1] * (a[2] - b[2]))
        q = ((aa * (b[2] - c[2]) + bb * (c[2] - a[2]) + cc * (a[2] - b[2])) / d, (aa * (c[1] - b[1]) + bb * (a[1] - c[1]) + cc * (b[1] - a[1])) / d)
        _sec_inside(seeded, q) || return none
        for e in 1:nb       # a new point must not lie in the diametral circle of a boundary edge
            _sec_norm(_sec_sub(bmid[e], q)) < blen[e] / 2 && return none
        end
        s = sizeat(q)
        angle = asind(min(1.0, min(la, lb, lc) / (2R)))
        value = max(R * sqrt(3) / s, angle < SECTION_MINIMUM_ANGLE ? SECTION_MINIMUM_ANGLE / max(angle, 1e-9) : 0.0)
        value > 1 ? (value, q, s) : none
    end
    scores = [score(i) for i in eachindex(tri.triangles)]
    while length(points) < maximum_points
        best = 0; value = 1.0
        for i in eachindex(scores)
            tri.alive[i] && scores[i][1] > value && (best = i; value = scores[i][1])
        end
        best == 0 && break
        _, q, s = scores[best]
        if minimum(_sec_norm(_sec_sub(p, q)) for p in points) <= 0.3s
            scores[best] = none; continue
        end
        push!(points, q); push!(tri.points, normal(q))
        created = _sec_insert!(tri, length(tri.points))
        if isempty(created)
            pop!(points); pop!(tri.points); scores[best] = none; continue
        end
        resize!(scores, length(tri.triangles))
        for i in created
            scores[i] = score(i)
        end
    end
    triangles = NTuple{3,Int}[]
    for i in eachindex(tri.triangles)
        (tri.alive[i] && real(i)) || continue
        t = tri.triangles[i] .- 3; a = points[t[1]]; b = points[t[2]]; c = points[t[3]]
        _sec_orient(a, b, c) > 1e-18 * scale^2 || continue
        _sec_inside(seeded, ((a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3)) && push!(triangles, t)
    end
    edges = Set{Tuple{Int,Int}}()
    for t in triangles, (a, b) in ((t[1], t[2]), (t[2], t[3]), (t[3], t[1]))
        push!(edges, (min(a, b), max(a, b)))
    end
    for i in 1:nb
        j = next_of[i]
        if !((min(i, j), max(i, j)) in edges)
            k = loop_of[i]; start = findfirst(==(k), loop_of)
            return (k, i - start + 1)
        end
    end
    # six-node triangles
    nodes = copy(points); mids = Dict{Tuple{Int,Int},Int}(); tri6 = NTuple{6,Int}[]
    onloop(a, b) = a <= nb && b <= nb && (next_of[a] == b || next_of[b] == a) ? loop_of[a] : 0
    function midside(a, b)
        get!(mids, (min(a, b), max(a, b))) do
            m = ((nodes[a][1] + nodes[b][1]) / 2, (nodes[a][2] + nodes[b][2]) / 2)
            k = onloop(a, b)
            if k > 0 && seeded[k].radius > 0
                c = seeded[k].center; v = _sec_sub(m, c); r = seeded[k].radius / _sec_norm(v)
                m = (c[1] + v[1] * r, c[2] + v[2] * r)
            end
            push!(nodes, m); length(nodes)
        end
    end
    for t in triangles
        push!(tri6, (t[1], t[2], t[3], midside(t[1], t[2]), midside(t[2], t[3]), midside(t[3], t[1])))
    end
    (nodes, tri6, (elements=length(tri6), nodes=length(nodes), boundary_edges=nb))
end

# -------------------------------------------------------------------------------------- properties
# Degree-four rule on the triangle (area coordinates, weights summing to one).
const _SEC_RULE = let a1 = 0.445948490915965, w1 = 0.223381589678011, a2 = 0.091576213509771, w2 = 0.109951743655322
    ((a1, a1, 1 - 2a1, w1), (a1, 1 - 2a1, a1, w1), (1 - 2a1, a1, a1, w1), (a2, a2, 1 - 2a2, w2), (a2, 1 - 2a2, a2, w2), (1 - 2a2, a2, a2, w2))
end

function _sec_shape(l1, l2, l3)
    N = (l1 * (2l1 - 1), l2 * (2l2 - 1), l3 * (2l3 - 1), 4l1 * l2, 4l2 * l3, 4l3 * l1)
    d1 = (4l1 - 1, 0.0, -(4l3 - 1), 4l2, -4l2, 4(l3 - l1))
    d2 = (0.0, 4l2 - 1, -(4l3 - 1), 4l1, 4(l3 - l2), -4l1)
    N, d1, d2
end

"""
    section_properties_from_mesh(nodes, triangles)

Area, centroid, inertias, torsion constant, shear factors, shear-centre offsets and warping
constant of a six-node triangle mesh. `N1`, `N2` are the coordinates of the centroid relative to
the shear centre along y and z (the PBEAM convention).
"""
function section_properties_from_mesh(nodes::Vector{NTuple{2,Float64}}, triangles::Vector{NTuple{6,Int}})
    n = length(nodes)
    A = 0.0; Sz = 0.0; Sy = 0.0; Izz = 0.0; Iyy = 0.0; Izy = 0.0
    quad = Vector{Tuple{NTuple{6,Float64},NTuple{6,Float64},NTuple{6,Float64},Float64,Float64,Float64}}()
    sizehint!(quad, 6length(triangles))
    for t in triangles
        z = ntuple(k -> nodes[t[k]][1], 6); y = ntuple(k -> nodes[t[k]][2], 6)
        for (l1, l2, l3, w) in _SEC_RULE
            N, d1, d2 = _sec_shape(l1, l2, l3)
            j11 = sum(d1 .* z); j12 = sum(d1 .* y); j21 = sum(d2 .* z); j22 = sum(d2 .* y)
            det = j11 * j22 - j12 * j21
            det > 0 || throw(ArgumentError("section mesh: an element is inverted"))
            dA = w * det / 2
            gz = ntuple(k -> (j22 * d1[k] - j12 * d2[k]) / det, 6)
            gy = ntuple(k -> (-j21 * d1[k] + j11 * d2[k]) / det, 6)
            zq = sum(N .* z); yq = sum(N .* y)
            push!(quad, (N, gz, gy, zq, yq, dA))
            A += dA; Sz += dA * zq; Sy += dA * yq; Izz += dA * zq * zq; Iyy += dA * yq * yq; Izy += dA * zq * yq
        end
    end
    zc = Sz / A; yc = Sy / A
    I2 = Izz - A * zc^2; I1 = Iyy - A * yc^2; I12 = Izy - A * zc * yc
    rows = Int[]; cols = Int[]; vals = Float64[]
    f = zeros(n); qz = zeros(n); qy = zeros(n); an = zeros(n)
    index = 0
    for t in triangles
        ke = zeros(6, 6)
        for _ in 1:6
            index += 1
            N, gz, gy, zq, yq, dA = quad[index]
            z = zq - zc; y = yq - yc
            for a in 1:6
                f[t[a]] += dA * (gz[a] * y - gy[a] * z)
                qz[t[a]] += dA * z * N[a]; qy[t[a]] += dA * y * N[a]; an[t[a]] += dA * N[a]
                for b in 1:6
                    ke[a, b] += dA * (gz[a] * gz[b] + gy[a] * gy[b])
                end
            end
        end
        for a in 1:6, b in 1:6
            push!(rows, t[a]); push!(cols, t[b]); push!(vals, ke[a, b])
        end
    end
    used = sort!(unique!([k for t in triangles for k in t]))
    position = zeros(Int, n); position[used] .= 1:length(used)
    K = sparse(position[rows], position[cols], vals, length(used), length(used))
    rhs = hcat(f[used], qz[used], qy[used])
    solution = zeros(length(used), 3)
    solution[2:end, :] = cholesky(Symmetric(K[2:end, 2:end])) \ rhs[2:end, :]
    w = solution[:, 1]; phi = solution[:, 2]; chi = solution[:, 3]
    fu = f[used]; qzu = qz[used]; qyu = qy[used]; anu = an[used]
    J = I1 + I2 - dot(w, fu)
    wbar = w .- dot(w, anu) / A
    Iwz = dot(wbar, qzu); Iwy = dot(wbar, qyu)
    # warping about the shear centre: w_S = wbar + N1*z - N2*y with zero first moments
    N1, N2 = [I2 -I12; I12 -I1] \ [-Iwz, -Iwy]
    wfull = zeros(n); wfull[used] = wbar
    CW = 0.0; index = 0
    for t in triangles, _ in 1:6
        index += 1
        N, _, _, zq, yq, dA = quad[index]
        ws = sum(N[a] * wfull[t[a]] for a in 1:6) + N1 * (zq - zc) - N2 * (yq - yc)
        CW += dA * ws^2
    end
    # shear factors: unit bending-stress gradients for a shear force along y and along z
    D = I1 * I2 - I12^2
    gyv = (I2 .* qyu .- I12 .* qzu) ./ D; psy = (I2 .* chi .- I12 .* phi) ./ D
    gzv = (I1 .* qzu .- I12 .* qyu) ./ D; psz = (I1 .* phi .- I12 .* chi) ./ D
    K1 = 1 / (A * dot(gyv, psy)); K2 = 1 / (A * dot(gzv, psz))
    (A=A, zc=zc, yc=yc, I1=I1, I2=I2, I12=I12, J=J, K1=K1, K2=K2, N1=N1, N2=N2, CW=CW, elements=length(triangles), nodes=length(used))
end

"""
    section_properties(loops)

Finite-element properties of a section given by its outline loops. For circular outlines the area,
inertias and torsion constant are the exact values (the reference agrees to five digits).
"""
function section_properties(loops::Vector{SectionLoop}; kwargs...)
    nodes, triangles, info = section_mesh(loops; kwargs...)
    p = section_properties_from_mesh(nodes, triangles)
    if all(l -> l.radius > 0, loops) && all(l -> l.center == (0.0, 0.0), loops)
        ro = loops[1].radius; ri = length(loops) > 1 ? loops[2].radius : 0.0
        I = pi * (ro^4 - ri^4) / 4
        p = merge(p, (A=pi * (ro^2 - ri^2), zc=0.0, yc=0.0, I1=I, I2=I, I12=0.0, J=2I, N1=0.0, N2=0.0, CW=0.0))
    else
        if all(l -> l.radius == 0, loops)
            # Area, centroid and inertias of a polygonal outline are taken from the outline itself
            # (the mesh integrates them exactly too, to round-off of a sum over the elements).
            p = merge(p, _sec_polygon_moments(loops))
        end
        # The interior mesh does not share the symmetry of the outline, so quantities that the
        # symmetry makes zero come out as round-off of the discretisation (a relative 1e-7).
        # They are set to the exact zero that the outline implies.
        mirror_z, mirror_y, point = _sec_symmetry(loops, p.zc, p.yc)
        (mirror_z || mirror_y) && (p = merge(p, (I12=0.0,)))
        (mirror_z || point) && (p = merge(p, (N2=0.0,)))     # shear centre on the axis z = zc
        (mirror_y || point) && (p = merge(p, (N1=0.0,)))     # shear centre on the axis y = yc
    end
    merge(p, (target_size=info.target_size, boundary_edges=info.boundary_edges, boundary_splits=info.boundary_splits))
end

"Exact area, centroid and centroidal second moments of polygon loops (outer loop first, the others holes)."
function _sec_polygon_moments(loops)
    A = 0.0; Sz = 0.0; Sy = 0.0; Izz = 0.0; Iyy = 0.0; Izy = 0.0
    for (i, l) in enumerate(loops)
        P = l.points; n = length(P)
        a = 0.0; sz = 0.0; sy = 0.0; izz = 0.0; iyy = 0.0; izy = 0.0
        for k in 1:n
            z1, y1 = P[k]; z2, y2 = P[k == n ? 1 : k + 1]
            c = z1 * y2 - z2 * y1
            a += c / 2; sz += (z1 + z2) * c / 6; sy += (y1 + y2) * c / 6
            izz += (z1^2 + z1 * z2 + z2^2) * c / 12; iyy += (y1^2 + y1 * y2 + y2^2) * c / 12
            izy += (z1 * y2 + 2z1 * y1 + 2z2 * y2 + z2 * y1) * c / 24
        end
        s = (i == 1 ? 1.0 : -1.0) * sign(a)        # the outer loop adds, a hole removes, whatever its direction
        A += s * a; Sz += s * sz; Sy += s * sy; Izz += s * izz; Iyy += s * iyy; Izy += s * izy
    end
    zc = Sz / A; yc = Sy / A
    (A=A, zc=zc, yc=yc, I1=Iyy - A * yc^2, I2=Izz - A * zc^2, I12=Izy - A * zc * yc)
end

"""
Symmetries of the outline about its centroid: mirror in z (about the line z = zc), mirror in y
(about the line y = yc) and point symmetry. Every vertex must have its image among the vertices.
"""
function _sec_symmetry(loops, zc, yc)
    points = [q for l in loops for q in l.points]
    scale = maximum(maximum(abs, (q[1] - zc, q[2] - yc)) for q in points)
    has(q) = any(p -> abs(p[1] - q[1]) <= 1e-9 * scale && abs(p[2] - q[2]) <= 1e-9 * scale, points)
    (all(q -> has((2zc - q[1], q[2])), points), all(q -> has((q[1], 2yc - q[2])), points), all(q -> has((2zc - q[1], 2yc - q[2])), points))
end

const _section_library_cache = Dict{Tuple{String,Vector{Float64}},NamedTuple}()
const _section_library_cache_lock = ReentrantLock()
const _section_library_cache_limit = 4096

"""
    section_library_properties(type, dims)

Finite-element properties of a library section, or `nothing` when the type has no outline
definition. The section shape is solved once at unit scale and cached; results are scaled.
"""
function section_library_properties(type::AbstractString, dims)
    count = section_library_dimension_count(type)
    count === nothing && return nothing
    d = Float64.(dims[1:min(count, length(dims))])
    length(d) == count && all(x -> isfinite(x) && x > 0, d) || throw(ArgumentError("section $type needs $count finite positive dimensions, got $(collect(dims))"))
    scale = maximum(d)
    key = (String(type), d ./ scale)
    unit = lock(_section_library_cache_lock) do
        if !haskey(_section_library_cache, key) && length(_section_library_cache) >= _section_library_cache_limit
            delete!(_section_library_cache, first(keys(_section_library_cache)))
        end
        get!(() -> section_properties(section_library_loops(type, key[2])), _section_library_cache, key)
    end
    merge(unit, (A=unit.A * scale^2, zc=unit.zc * scale, yc=unit.yc * scale, I1=unit.I1 * scale^4, I2=unit.I2 * scale^4, I12=unit.I12 * scale^4,
        J=unit.J * scale^4, N1=unit.N1 * scale, N2=unit.N2 * scale, CW=unit.CW * scale^6, target_size=unit.target_size * scale))
end
