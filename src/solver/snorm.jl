# snorm.jl — SNORM normal averaging for shell elements

function compute_shell_nodal_normals(model, id_map, node_coords, angle_deg::Real; label::Union{Nothing,String}=nothing)
    angle = Float64(angle_deg)
    node_nrms = Dict{Int, Vector{SVector{3, Float64}}}()

    for (id, el) in model["CSHELLs"]
        if !haskey(el, "NODES"); continue; end
        nids = el["NODES"]
        n = length(nids)
        if n < 3; continue; end

        if !haskey(id_map, nids[1]) || !haskey(id_map, nids[2]) || !haskey(id_map, nids[3]); continue; end
        i1, i2, i3 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]]

        p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
        p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
        p3 = SVector{3}(node_coords[i3,1], node_coords[i3,2], node_coords[i3,3])

        if n == 4
            if !haskey(id_map, nids[4]); continue; end
            i4 = id_map[nids[4]]
            p4 = SVector{3}(node_coords[i4,1], node_coords[i4,2], node_coords[i4,3])
            nrm_raw = cross(p3 - p1, p4 - p2)
        else
            nrm_raw = cross(p2 - p1, p3 - p1)
        end
        nrm_len = norm(nrm_raw)
        if nrm_len < 1e-30; continue; end
        nrm = SVector{3}(nrm_raw / nrm_len)

        for nid in nids
             if !haskey(id_map, nid); continue; end
             idx = id_map[nid]
             if !haskey(node_nrms, idx); node_nrms[idx] = SVector{3,Float64}[]; end
             push!(node_nrms[idx], nrm)
        end
    end

    avg_normals = Dict{Int, SVector{3,Float64}}()
    cos_chk = cosd(angle)

    for (idx, nrms) in node_nrms
        if length(nrms) == 1
            avg_normals[idx] = nrms[1]
            continue
        end

        avg = sum(nrms)
        len = norm(avg)
        if len < 1e-12; continue; end
        avg = avg / len

        ok = true
        for n in nrms
            if dot(n, avg) < cos_chk; ok = false; break; end
        end

        if ok
            avg_normals[idx] = SVector{3}(avg...)
        end
    end
    if !isnothing(label)
        log_msg("[SOLVER] $label: $(length(avg_normals)) nodes with averaged normals")
    end
    return avg_normals
end

# Returns Dict{Int, SVector{3,Float64}} of averaged normals per node index.
# Does NOT modify node_R (DOF coordinate frames must stay as-is for constraints/RBE3).
# The averaged normals are used to adjust element frames in the assembly loop.
function compute_snorm_normals(model, id_map, node_coords)
    snorm_angle = get(model, "PARAM_SNORM", 0.0)
    if haskey(ENV, "JFEM_PARAM_SNORM_OVERRIDE")
        snorm_angle = something(tryparse(Float64, ENV["JFEM_PARAM_SNORM_OVERRIDE"]), snorm_angle)
    end
    if snorm_angle <= 0.0
        log_msg("[SOLVER] SNORM disabled (angle=$snorm_angle)")
        return Dict{Int, SVector{3,Float64}}()
    end

    return compute_shell_nodal_normals(model, id_map, node_coords, snorm_angle; label="SNORM")
end

function compute_geometric_nodal_normals(model, id_map, node_coords)
    raw = strip(get(ENV, "JFEM_KG_CURVATURE_NORMAL_ANGLE", "180.0"))
    angle_deg = something(tryparse(Float64, raw), 180.0)
    angle_deg <= 0.0 && return Dict{Int, SVector{3,Float64}}()
    return compute_shell_nodal_normals(model, id_map, node_coords, angle_deg)
end

# --- PARAM SNORM as a nodal-director referencing of the rotational DOFs -------
#
# At a grid whose averaged shell normal n differs from an attached element's own
# normal v3, the reference formulation references that element's nodal rotations
# to n instead of v3.  Substituting
#
#     theta_used = S * theta,      S = I + skew( (n x v3) / (n . v3) )
#
# into the element operators (equivalently Ke <- S' Ke S on that node's
# rotational 3x3) reproduces the reference's per-element SNORM stiffness change to
# <1e-3 relative on the creased-patch and dome rigs, and is EXACTLY the identity
# when n == v3.
#
# Two properties, both measured against the reference:
#   * the transformed physical rotation rows annihilate d (note: S itself does NOT
#     annihilate n -- S*n = d; it is the ROWS of S, i.e. what the element's
#     operators contract with theta, that kill rotation about d ~ n). So rotation
#     about the averaged normal produces no element deformation and adjacent facets
#     share one fictitious direction instead of each having its own.
#   * the drilling penalty alpha*(v3'theta)^2 becomes alpha*(d'theta)^2 with
#     d = n/(n.v3), i.e. alpha/(n.v3)^2 about n.  Predicted 898.68 vs 898.60
#     measured on the 20-degree patch.
#
# This replaces the element-frame TILT below, which rotates v1/v2 as well and so
# corrupts the membrane response (the tilt moves lambda1 the wrong way: -0.99%
# and -3.08% at 20/30 degrees where the reference gives +0.81% and +1.12%).
#
# ⛔ NOT PROMOTABLE AS IT STANDS — but the operator ABOVE IS CORRECT; what is
# missing is a SECOND term. See SESSIONS/2026-07-30_SNORM_PARSER_BUG_OPERATOR_CONFIRMED.md.
#
# Under mesh refinement the reference's SNORM effect VANISHES (-2.65 -> -0.78 ->
# -0.24 % on the MacNeal hemisphere at 4x4/8x8/16x16) while this operator's GROWS
# (-47 -> -61 -> -67 %). The 2026-07-29 reading of that — "S is too low-order in
# alpha, re-derive the alpha-dependence" — is REFUTED: the reference-KGG reader it
# relied on was dropping ~43 % of every punch. With a correct reader
# (PROJECT_STATE/TOOLS_MATPRN/) the reference's own director reads back off the
# FAILING deck at ratio 1.0000 and 0.00-0.07 deg at all 12 probes, and both rows of
# S are confirmed. So: do NOT re-derive and do NOT tune S.
#
# The real gap: on the same mesh the reference's SNORM change is 2.2-2.6x LARGER
# than this one and only 73 % of it is the congruence K0*S (this code's is 100 %),
# yet the reference's physical effect is 20x smaller. The missing 27 % is
# STABILISING and is the same order as the congruence. Ruled out by measurement:
# the drilling operator (both codes are K6ROT-insensitive), rigid-body consistency,
# warp, cell taper, unequal element areas, any nodal translational transform, and
# print precision (the deficit is thickness-independent over a 100x range).
# Prime untested hypothesis: the reference also re-forms the element with the
# smoothed director field, adding the initial-curvature terms of a genuinely curved
# shell element — invisible on every rig where only one node per element carries a
# director, which is true of all the older rigs and false on the hemisphere.
@inline snorm_director_enabled() = solver_env_bool("JFEM_SNORM_DIRECTOR", false)


# S in the element frame, for a node whose averaged normal is `n`.
# Returns the identity whenever the node normal coincides with the element
# normal, so unshared and coplanar nodes are structurally inert.
@inline function snorm_director_matrix(n::SVector{3,Float64},
                                       v1::SVector{3,Float64},
                                       v2::SVector{3,Float64},
                                       v3::SVector{3,Float64})
    n3 = dot(n, v3)
    # n is only ever this close to the element plane if PARAM SNORM was set wide
    # enough to defeat its own half-angle refusal; leave those nodes alone.
    if abs(n3) < 1e-3
        return @SMatrix [1.0 0.0 0.0; 0.0 1.0 0.0; 0.0 0.0 1.0]
    end
    a = dot(n, v1) / n3
    b = dot(n, v2) / n3
    return @SMatrix [1.0 0.0 -a; 0.0 1.0 -b; a b 1.0]
end

# Apply SNORM: adjust element frame using averaged normals at element nodes.
# Returns modified (v1, v2, v3) with v3 tilted toward averaged surface normal.
function apply_snorm_to_frame(v1::SVector{3,Float64}, v2::SVector{3,Float64}, v3::SVector{3,Float64},
                               indices::Vector{Int}, snorm_normals::Dict{Int, SVector{3,Float64}})
    if isempty(snorm_normals) || snorm_director_enabled(); return v1, v2, v3; end

    n_avg = SVector(0.0, 0.0, 0.0)
    n_count = 0
    for idx in indices
        if haskey(snorm_normals, idx)
            n_avg = n_avg + snorm_normals[idx]
            n_count += 1
        end
    end
    if n_count == 0; return v1, v2, v3; end

    n_avg = n_avg / n_count
    len = norm(n_avg)
    if len < 1e-12; return v1, v2, v3; end
    v3_new = SVector{3}(n_avg / len)

    # Ensure v3_new is on same side as original v3
    if dot(v3_new, v3) < 0.0; v3_new = -v3_new; end

    # Recompute v1 by projecting original v1 onto plane perpendicular to new v3
    v1_proj = v1 - dot(v1, v3_new) * v3_new
    v1_len = norm(v1_proj)
    if v1_len > 1e-12
        v1_new = SVector{3}(v1_proj / v1_len)
    else
        # v1 was parallel to new v3, use v2 instead
        v2_proj = v2 - dot(v2, v3_new) * v3_new
        v1_new = SVector{3}(normalize(v2_proj))
    end
    v2_new = SVector{3}(cross(v3_new, v1_new))

    return v1_new, v2_new, v3_new
end
