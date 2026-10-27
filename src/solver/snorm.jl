# Axis averaging is established for the ordinary normal-moment work law.
# Preserve directed generation globally when a shared field also reaches a
# legacy frame-tilt, director, higher-order or transform-only research path.
function _snorm_axis_generation_supported(model)
    snorm_director_enabled() && return false
    solver_env_bool("JFEM_Q4_SNORM_TRANSFORM_ONLY",false) && return false
    shells=values(get(model,"CSHELLs",Dict()))
    isempty(shells) && return false
    for el in shells
        n=length(get(el,"NODES",Int[]))
        kind=uppercase(string(get(el,"TYPE",n==3 ? "CTRIA3" : n==4 ? "CQUAD4" : "")))
        if n==4 && kind in ("CQUAD4","CQUADR")
            snorm_curvature_enabled() && FEM.quad4_snorm_normal_moment_mode() || return false
        elseif n==3 && kind in ("CTRIA3","CTRIAR")
            tria3_snorm_normal_moment_enabled() || return false
        else
            return false
        end
    end
    return true
end

# A discrete signature for coordinate finite differences. It contains no
# continuous angle/vector values. Incident identity and a canonical sign
# partition distinguish acceptance/coherence changes without differentiating
# the sign decision. Explicit overrides remove their generated signatures.
function _snorm_axis_branch_signature(nrms,incident,aligned)
    order=sortperm(incident)
    coherent=length(nrms)==1 || aligned!==nrms
    seed=nrms[first(order)]
    partition=coherent ? Tuple(dot(seed,nrms[i])<0 ? -1 : 1 for i in order) : Tuple(1 for i in order)
    return (coherent=coherent,incident=Tuple(incident[i] for i in order),partition=partition)
end

# A generated shell normal represents an axis. On a coherent acute star,
# reverse incident representatives into one hemisphere before averaging.
# Pairwise consistency makes the result independent of which incident normal
# supplies the seed; its remaining overall sign cancels from the slope map.
# Ambiguous or orthogonal stars retain the directed averaging contract.
function _snorm_coherent_axis_normals(nrms)
    seed=first(nrms)
    aligned=map(n->dot(seed,n)<0 ? -n : n,nrms)
    for i in eachindex(aligned), j in 1:i-1
        dot(aligned[i],aligned[j])>0 || return nrms
    end
    return aligned
end

# snorm.jl — SNORM normal averaging for shell elements

function compute_shell_nodal_normals(model, id_map, node_coords, angle_deg::Real; label::Union{Nothing,String}=nothing, corner_tangents::Bool=false, normal_axes::Bool=false, branch_trace=nothing)
    angle = Float64(angle_deg)
    node_nrms = Dict{Int, Vector{SVector{3, Float64}}}()
    branch_trace===nothing || empty!(branch_trace)
    node_keys = branch_trace===nothing || !normal_axes ? nothing : Dict{Int,Vector{Tuple{String,Int}}}()

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

        # A bilinear Q4 has a distinct surface tangent plane at each corner.
        # Triangles and explicitly requested mean-plane geometry keep their
        # constant normal. Average unit incident tangent normals at each GRID.
        corners = n == 4 && corner_tangents ? (p1,p2,p3,p4) : nothing
        for (corner_index,nid) in enumerate(nids)
             if !haskey(id_map, nid); continue; end
             idx = id_map[nid]
             if !haskey(node_nrms, idx); node_nrms[idx] = SVector{3,Float64}[]; end
             corner_normal = nrm
             if corners !== nothing
                 p = corners[corner_index]
                 tangent_normal = cross(corners[mod1(corner_index+1,4)]-p,
                                        corners[mod1(corner_index-1,4)]-p)
                 tangent_length = norm(tangent_normal)
                 tangent_length > 1e-30 || continue
                 corner_normal = SVector{3}(tangent_normal/tangent_length)
             end
             push!(node_nrms[idx], corner_normal)
             node_keys===nothing || push!(get!(node_keys,idx,Tuple{String,Int}[]),(string(id),corner_index))
        end
    end

    avg_normals = Dict{Int, SVector{3,Float64}}()
    cos_chk = cosd(angle)

    for (idx, nrms) in node_nrms
        if length(nrms) == 1
            avg_normals[idx] = nrms[1]
            node_keys===nothing || (branch_trace[idx]=_snorm_axis_branch_signature(nrms,node_keys[idx],nrms))
            continue
        end

        averaging_normals = normal_axes ? _snorm_coherent_axis_normals(nrms) : nrms
        avg = sum(averaging_normals)
        len = norm(avg)
        if len < 1e-12; continue; end
        avg = avg / len

        ok = true
        for n in averaging_normals
            # PARAM,SNORM specifies a strictly smaller acceptance angle. The
            # geometric-curvature provider keeps its prior directed contract.
            rejected = normal_axes ? dot(n,avg)<=cos_chk : dot(n,avg)<cos_chk
            if rejected; ok = false; break; end
        end

        if ok
            avg_normals[idx] = SVector{3}(avg...)
            node_keys===nothing || (branch_trace[idx]=_snorm_axis_branch_signature(nrms,node_keys[idx],averaging_normals))
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
function compute_snorm_normals(model, id_map, node_coords; angle_deg=nothing, branch_trace=nothing)
    branch_trace===nothing || empty!(branch_trace)
    snorm_angle = angle_deg===nothing ? get(model,"PARAM_SNORM",0.0) : angle_deg
    if haskey(ENV,"JFEM_PARAM_SNORM_OVERRIDE")
        snorm_angle=something(tryparse(Float64,ENV["JFEM_PARAM_SNORM_OVERRIDE"]),snorm_angle)
    end
    if snorm_angle < 0.0
        log_msg("[SOLVER] SNORM disabled, including explicit normals (angle=$snorm_angle)")
        return Dict{Int,SVector{3,Float64}}()
    end
    axis_scope = _snorm_axis_generation_supported(model)
    normals = snorm_angle > 0.0 ?
        compute_shell_nodal_normals(model,id_map,node_coords,snorm_angle;label="SNORM",corner_tangents=true,
            normal_axes=axis_scope,branch_trace=axis_scope ? branch_trace : nothing) :
        Dict{Int,SVector{3,Float64}}()
    explicit=get(model,"SNORMs",Dict())
    isempty(explicit) && return normals

    # Prescribed normals override the generated field without its acceptance
    # angle. They apply only to the ordinary triangle/quadrilateral shells.
    eligible=Set{Int}();ignored_shell_nodes=Set{Int}()
    incident=Dict{Int,Vector{Any}}()
    for el in values(get(model,"CSHELLs",Dict()))
        nodes=get(el,"NODES",Int[])
        kind=uppercase(string(get(el,"TYPE",length(nodes)==3 ? "CTRIA3" : length(nodes)==4 ? "CQUAD4" : "")))
        target=kind in ("CQUAD4","CQUADR","CTRIA3","CTRIAR") ? eligible : ignored_shell_nodes
        union!(target,nodes)
        if target===eligible
            for gid in nodes
                push!(get!(incident,gid,Any[]),el)
            end
        end
    end
    for record in values(explicit)
        gid=Int(record["GID"])
        haskey(id_map,gid) || throw(ArgumentError("SNORM references undefined GRID $gid"))
        gid in eligible || continue
        # Higher-order shells currently expand into ordinary sub-elements.
        # A shared explicit normal cannot yet be excluded from those children.
        gid in ignored_shell_nodes && throw(ArgumentError(
            "Explicit SNORM at GRID $gid shared by ordinary and higher-order/shear shells is unsupported"))
        cid=Int(get(record,"CID",0));vector=Float64.(record["N"])
        length(vector)==3 && all(isfinite,vector) ||
            throw(ArgumentError("Active SNORM $gid requires three finite components"))
        scale=maximum(abs,vector)
        scale>0 || throw(ArgumentError("Active SNORM $gid has a zero normal vector"))
        cid>=0 && (cid==0 || haskey(model["CORDs"],string(cid))) ||
            throw(ArgumentError("SNORM $gid references undefined coordinate system CID=$cid"))
        idx=id_map[gid]
        position=SVector{3}(node_coords[idx,1],node_coords[idx,2],node_coords[idx,3])
        # Scaling before this orthogonal transform avoids overflow; normalization
        # is completed in BASIC after evaluating a curvilinear CID at the GRID.
        basic=get_coord_transform(model,cid,vector/scale;position=position)
        magnitude=norm(basic)
        isfinite(magnitude) && magnitude>0 ||
            throw(ArgumentError("Active SNORM $gid has an invalid transformed normal"))
        normal=SVector{3,Float64}(basic/magnitude)
        for el in incident[gid]
            nodes=el["NODES"];eid=get(el,"ID","unknown")
            length(nodes) in (3,4) || throw(ArgumentError("Unsupported explicit SNORM shell EID=$eid"))
            all(n->haskey(id_map,n),nodes) || throw(ArgumentError("SNORM incident shell EID=$eid references an undefined GRID"))
            points=[SVector{3}(node_coords[id_map[n],1],node_coords[id_map[n],2],node_coords[id_map[n],3]) for n in nodes]
            geometric=length(nodes)==4 ? cross(points[3]-points[1],points[4]-points[2]) : cross(points[2]-points[1],points[3]-points[1])
            geometric_length=norm(geometric)
            geometric_length>0 || throw(ArgumentError("SNORM incident shell EID=$eid has a degenerate normal"))
            # The current normal-moment map represents slopes n1/n3,n2/n3.
            # Never silently discard a prescribed direction outside its domain.
            abs(dot(normal,geometric))/geometric_length>=1e-3 || throw(ArgumentError(
                "Explicit SNORM at GRID $gid is too close to the tangent plane of shell EID=$eid for the supported normal-moment map"))
        end
        normals[idx]=normal
        branch_trace===nothing || delete!(branch_trace,idx)
    end
    return normals
end

function compute_geometric_nodal_normals(model, id_map, node_coords)
    raw = strip(get(ENV, "JFEM_KG_CURVATURE_NORMAL_ANGLE", "180.0"))
    angle_deg = something(tryparse(Float64, raw), 180.0)
    angle_deg <= 0.0 && return Dict{Int, SVector{3,Float64}}()
    return compute_shell_nodal_normals(model, id_map, node_coords, angle_deg)
end

# --- PARAM,SNORM nodal directors and normal-moment equilibrium ----------------
#
# `snorm_element_pq` carries absolute nodal tangent slopes and an accepted-row
# marker. On a warped Q4, the full physical map combines translational
# finite-warp equilibrium with the absolute normal-moment map once. An aligned
# accepted row clears the old corner moment tilt; missing or rejected normals
# retain the ordinary finite-warp row. Planar normals reduce to the existing
# normal-moment map. Two-column explicit kernel fields retain their established
# relative-to-warp contract. The work-dual map is shared by elastic stiffness,
# prestress, recovery and reference-plane offsets.
@inline snorm_director_enabled() = solver_env_bool("JFEM_SNORM_DIRECTOR", false)

# A triangle retains its geometric frame. Accepted nodal directors act through
# a work-dual normal-moment map, just as for a quadrilateral. Tilting one mean
# frame loses rigid-spin exactness and gives adjacent shells different drilling
# null directions. Keep the historical route only for explicit diagnostics.
@inline tria3_snorm_normal_moment_enabled() =
    solver_env_bool("JFEM_TRIA3_SNORM_NORMAL_MOMENT", true) && !snorm_director_enabled()

function tria3_snorm_element_pq(v1, v2, v3, indices, snorm_normals)
    tria3_snorm_normal_moment_enabled() || return nothing
    length(indices) == 3 || throw(ArgumentError("Expected three triangle nodes"))
    any(i -> haskey(snorm_normals, i), indices) || return nothing
    pq = zeros(3, 2)
    for (k, idx) in enumerate(indices)
        haskey(snorm_normals, idx) || continue
        normal = snorm_normals[idx]
        dot(normal, v3) < 0 && (normal = -normal)
        n3 = dot(normal, v3)
        abs(n3) < 1e-3 && continue
        pq[k, 1] = dot(normal, v1) / n3
        pq[k, 2] = dot(normal, v2) / n3
        # Coplanar/solo rows must remain exactly inert after frame roundoff.
        abs(pq[k, 1]) < 1e-14 && (pq[k, 1] = 0.0)
        abs(pq[k, 2]) < 1e-14 && (pq[k, 2] = 0.0)
    end
    return pq
end

"""Rigid-exact CTRIA3 normal-moment displacement map.

With constant triangle gradients, omega = (v,x-u,y)/2 and delta=rz-omega:
rx_used=rx-p*delta; ry_used=ry-q*delta;
rz_used=rz+p*(rx-w,y)+q*(ry+w,x).
Its transpose converts normal moments into zero-resultant force couples.
Independent folded/rotated reference matrices select this map without fitted
parameters. Constitutive tangents use the same fixed-geometry congruence.
"""
function tria3_snorm_normal_moment_displacement_map(coords, pq)
    size(coords, 1) == 3 && size(coords, 2) >= 2 ||
        throw(ArgumentError("Expected three triangle x/y coordinates"))
    size(pq) == (3, 2) || throw(ArgumentError("Expected three director slope pairs"))
    M = Matrix{Float64}(I, 18, 18)
    all(iszero, pq) && return M
    x1, y1 = coords[1, 1], coords[1, 2]
    x2, y2 = coords[2, 1], coords[2, 2]
    x3, y3 = coords[3, 1], coords[3, 2]
    twice_area = (x2-x1)*(y3-y1)-(x3-x1)*(y2-y1)
    abs(twice_area) > 1e-30 || throw(ArgumentError("Degenerate CTRIA3 normal-moment map"))
    dx = ((y2-y3)/twice_area, (y3-y1)/twice_area, (y1-y2)/twice_area)
    dy = ((x3-x2)/twice_area, (x1-x3)/twice_area, (x2-x1)/twice_area)
    for i in 1:3
        p, q = pq[i, 1], pq[i, 2]
        rx = 6(i-1)+4; ry = rx+1; rz = rx+2
        M[rx, rz] -= p; M[ry, rz] -= q
        M[rz, rx] += p; M[rz, ry] += q
        for j in 1:3
            ux = 6(j-1)+1; uy = ux+1; uz = ux+2
            M[rx, ux] -= 0.5p*dy[j]; M[rx, uy] += 0.5p*dx[j]
            M[ry, ux] -= 0.5q*dy[j]; M[ry, uy] += 0.5q*dx[j]
            M[rz, uz] += -p*dy[j]+q*dx[j]
        end
    end
    return M
end

# Production PARAM,SNORM route. The historical function name is retained to
# avoid churn in assembly and adjoint guards; FEMKernels selects the
# normal-moment formulation.
@inline function snorm_curvature_enabled()
    return solver_env_bool("JFEM_Q4_SNORM_CURVATURE", true) &&
           !solver_env_bool("JFEM_Q4_SNORM_TRANSFORM_ONLY", false) &&
           !snorm_director_enabled()
end

function snorm_element_pq(v1::SVector{3,Float64},
                          v2::SVector{3,Float64},
                          v3::SVector{3,Float64},
                          indices,
                          snorm_normals::Dict{Int,SVector{3,Float64}})
    snorm_curvature_enabled() || return nothing
    length(indices) == 4 || return nothing
    any(i -> haskey(snorm_normals, i), indices) || return nothing
    # The third column records an accepted geometric normal, including an
    # exactly aligned one. A zero slope alone cannot distinguish an aligned
    # accepted director from a missing/rejected director.
    pq = zeros(4, 3)
    @inbounds for k in 1:4
        idx = indices[k]
        haskey(snorm_normals, idx) || continue
        n = snorm_normals[idx]
        dot(n, v3) < 0.0 && (n = -n)
        n3 = dot(n, v3)
        abs(n3) < 1e-3 && continue
        pq[k,3] = 1.0
        pq[k,1] = dot(n, v1) / n3
        pq[k,2] = dot(n, v2) / n3
    end
    return pq
end


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
    if isempty(snorm_normals) || snorm_director_enabled() ||
       (length(indices) == 4 && snorm_curvature_enabled()) ||
       (length(indices) == 3 && tria3_snorm_normal_moment_enabled())
        return v1, v2, v3
    end

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

# Preserve the historical no-field dispatch for an aligned planar element,
# while retaining accepted zero slopes on a genuinely warped element.
function snorm_quad4_field_is_active(pq,points,v1,v3)
    FEM.quad4_snorm_pq_has_active_rows(pq) && return true
    size(pq,2)>=3 && any(i->pq[i,3]>0,1:4) || return false
    center=sum(points)/4
    heights=maximum(abs(dot(p-center,v3)) for p in points)
    xscale=max(maximum(abs(dot(p-center,v1)) for p in points),1e-30)
    return heights>1e-12*xscale
end
