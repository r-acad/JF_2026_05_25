# loads.jl — Load resolution (FORCE, MOMENT, PLOAD4, GRAV, PLOAD1, LOAD combos)

function _tria3_shell_frame_and_local_coords(Xc::AbstractMatrix)
    p1 = vec(Xc[1, :]); p2 = vec(Xc[2, :]); p3 = vec(Xc[3, :])
    v1_raw = p2 .- p1
    nrm_v1 = norm(v1_raw)
    nrm_v1 <= 1e-30 && return nothing

    n_raw = cross(v1_raw, p3 .- p1)
    nrm_n = norm(n_raw)
    nrm_n <= 1e-30 && return nothing

    v1 = v1_raw ./ nrm_v1
    v3 = n_raw ./ nrm_n
    v2 = cross(v3, v1)
    Rel_t = [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]

    c = (p1 .+ p2 .+ p3) ./ 3
    lc = zeros(3, 2)
    lc[1,1] = dot(p1 .- c, v1); lc[1,2] = dot(p1 .- c, v2)
    lc[2,1] = dot(p2 .- c, v1); lc[2,2] = dot(p2 .- c, v2)
    lc[3,1] = dot(p3 .- c, v1); lc[3,2] = dot(p3 .- c, v2)

    return (Rel_t=Rel_t, lc=lc)
end

function _tria3_shell_isotropic_material(model, el_def)
    pid = string(get(el_def, "PID", 0))
    prop = get(get(model, "PSHELLs", Dict()), pid, nothing)
    prop === nothing && return nothing

    h = Float64(get(prop, "T", 0.0))
    h <= 0 && return nothing

    mid = string(get(prop, "MID", get(prop, "MID1", 0)))
    mat = get(get(model, "MATs", Dict()), mid, nothing)
    mat === nothing && return nothing
    (!haskey(mat, "E") || !haskey(mat, "NU")) && return nothing

    return (E=Float64(mat["E"]), nu=Float64(mat["NU"]), h=h)
end

@inline function _filter_shell_normal_moments_enabled()
    return solver_env_bool("JFEM_FILTER_SHELL_NORMAL_MOMENTS", true)
end

function _shell_normal_moment_filter_data(model, id_map, node_coords)
    n_nodes = length(id_map)
    normal_sum = [zeros(3) for _ in 1:n_nodes]
    node_has_shell = falses(n_nodes)
    node_has_rotational_line = falses(n_nodes)

    for (_, el) in get(model, "CSHELLs", Dict())
        nodes = get(el, "NODES", Int[])
        idxs = [get(id_map, nid, 0) for nid in nodes]
        if isempty(idxs) || any(==(0), idxs)
            continue
        end
        Xc = node_coords[idxs, :]
        normal_vec =
            if length(idxs) == 4
                cross(Xc[3, :] - Xc[1, :], Xc[4, :] - Xc[2, :])
            elseif length(idxs) == 3
                cross(Xc[2, :] - Xc[1, :], Xc[3, :] - Xc[1, :])
            else
                zeros(3)
            end
        norm(normal_vec) <= 1e-30 && continue
        for idx in idxs
            node_has_shell[idx] = true
            normal_sum[idx] .+= normal_vec
        end
    end

    for group_name in ("CBARs", "CBEAMs", "CBUSHs")
        for (_, el) in get(model, group_name, Dict())
            for key in ("GA", "GB", "G1", "G2")
                gid = get(el, key, 0)
                idx = get(id_map, gid, 0)
                idx > 0 && (node_has_rotational_line[idx] = true)
            end
        end
    end

    return normal_sum, node_has_shell, node_has_rotational_line
end

@inline function _filter_shell_normal_moment(
    moment::AbstractVector{<:Real},
    gid,
    id_map,
    normal_sum,
    node_has_shell,
    node_has_rotational_line,
)
    idx = get(id_map, gid, 0)
    if idx <= 0 || idx > length(node_has_shell) ||
       !node_has_shell[idx] || node_has_rotational_line[idx]
        return Vector{Float64}(moment)
    end
    n = normal_sum[idx]
    n_norm = norm(n)
    n_norm <= 1e-30 && return Vector{Float64}(moment)
    nhat = n ./ n_norm
    return Vector{Float64}(moment) .- dot(moment, nhat) .* nhat
end

function _beam_pload1_interval(pload::AbstractDict, L::Real)
    x1_raw = Float64(get(pload, "X1", 0.0))
    x2_raw = Float64(get(pload, "X2", 1.0))
    pscale = uppercase(strip(string(get(pload, "SCALE", ""))))
    if pscale == "LE" || pscale == ""
        xa0, xb0 = x1_raw, x2_raw
    else
        xa0, xb0 = x1_raw * Float64(L), x2_raw * Float64(L)
    end
    xb0 > xa0 || return nothing
    xa = clamp(xa0, 0.0, Float64(L))
    xb = clamp(xb0, 0.0, Float64(L))
    xb > xa || return nothing
    return xa0, xb0, xa, xb
end

function _line_rforce_consistent_endpoint_forces(
    mass_per_length::Real,
    p1::AbstractVector,
    p2::AbstractVector,
    center::AbstractVector,
    axis::AbstractVector,
    omega2::Real,
)
    L = norm(p2 .- p1)
    if L <= 1e-30 || mass_per_length <= 0.0 || omega2 == 0.0
        return nothing
    end
    r1 = Float64.(p1 .- center)
    r2 = Float64.(p2 .- center)
    r1_perp = r1 .- dot(r1, axis) .* axis
    r2_perp = r2 .- dot(r2, axis) .* axis
    coeff = Float64(mass_per_length) * L * Float64(omega2)
    f1 = coeff .* (r1_perp ./ 3.0 .+ r2_perp ./ 6.0)
    f2 = coeff .* (r1_perp ./ 6.0 .+ r2_perp ./ 3.0)
    return f1, f2
end

function _add_line_rforce!(
    F_acc,
    idx1::Integer,
    idx2::Integer,
    p1::AbstractVector,
    p2::AbstractVector,
    mass_per_length::Real,
    center::AbstractVector,
    axis::AbstractVector,
    omega2::Real,
)
    forces = _line_rforce_consistent_endpoint_forces(
        mass_per_length, p1, p2, center, axis, omega2)
    forces === nothing && return
    f1, f2 = forces
    dof1 = (Int(idx1) - 1) * 6
    dof2 = (Int(idx2) - 1) * 6
    F_acc[dof1+1:dof1+3] .+= f1
    F_acc[dof2+1:dof2+3] .+= f2
    return
end

function _beam_pload1_equivalent_local_load_vector(pload::AbstractDict, L::Real, scale::Real=1.0)
    interval = _beam_pload1_interval(pload, L)
    interval === nothing && return zeros(Float64, 12)
    xa0, xb0, xa, xb = interval
    ltype = Int(get(pload, "LOAD_TYPE", 0))
    1 <= ltype <= 6 || return zeros(Float64, 12)

    p1 = Float64(get(pload, "P1", 0.0)) * Float64(scale)
    p2 = Float64(get(pload, "P2", 0.0)) * Float64(scale)
    seg0 = xb0 - xa0
    seg0 > 0.0 || return zeros(Float64, 12)

    f = zeros(Float64, 12)
    mid = 0.5 * (xa + xb)
    half = 0.5 * (xb - xa)
    gp = (-sqrt(3.0 / 5.0), 0.0, sqrt(3.0 / 5.0))
    gw = (5.0 / 9.0, 8.0 / 9.0, 5.0 / 9.0)
    for (g, wgt) in zip(gp, gw)
        x = mid + half * g
        xi = x / Float64(L)
        q = p1 + (p2 - p1) * (x - xa0) / seg0
        w = half * wgt

        Na = 1.0 - xi
        Nb = xi
        if ltype == 1
            f[1] += w * q * Na
            f[7] += w * q * Nb
        elseif ltype == 2 || ltype == 3
            N1 = 1.0 - 3.0 * xi^2 + 2.0 * xi^3
            N2 = Float64(L) * (xi - 2.0 * xi^2 + xi^3)
            N3 = 3.0 * xi^2 - 2.0 * xi^3
            N4 = Float64(L) * (-xi^2 + xi^3)
            if ltype == 2
                f[2] += w * q * N1
                f[6] += w * q * N2
                f[8] += w * q * N3
                f[12] += w * q * N4
            else
                f[3] += w * q * N1
                f[5] -= w * q * N2
                f[9] += w * q * N3
                f[11] -= w * q * N4
            end
        elseif ltype == 4
            f[4] += w * q * Na
            f[10] += w * q * Nb
        elseif ltype == 5
            f[5] += w * q * Na
            f[11] += w * q * Nb
        elseif ltype == 6
            f[6] += w * q * Na
            f[12] += w * q * Nb
        end
    end
    return f
end

function _beam_pload1_local_load_vector_for_sid(
    model::AbstractDict,
    eid::Integer,
    sid,
    L::Real,
    scale::Real=1.0,
    visited::Set{Int}=Set{Int}(),
)
    isnothing(sid) && return zeros(Float64, 12)
    sid_int = Int(sid)
    sid_int in visited && return zeros(Float64, 12)
    push!(visited, sid_int)
    f = zeros(Float64, 12)
    for pload in get(model, "PLOAD1s", [])
        if Int(get(pload, "SID", 0)) == sid_int && Int(get(pload, "EID", 0)) == Int(eid)
            f .+= _beam_pload1_equivalent_local_load_vector(pload, L, scale)
        end
    end
    for combo in get(model, "LOAD_COMBOS", [])
        if Int(get(combo, "SID", 0)) == sid_int
            combo_scale = Float64(scale) * Float64(get(combo, "S", 1.0))
            for sub in get(combo, "COMPS", [])
                f .+= _beam_pload1_local_load_vector_for_sid(
                    model, eid, Int(sub["LID"]), L,
                    combo_scale * Float64(get(sub, "S", 1.0)),
                    visited,
                )
            end
        end
    end
    delete!(visited, sid_int)
    return f
end

function resolve_loads(model, sid, scale, id_map, elem_map, node_coords, F_acc)
    raw_forces = Dict{Int, Vector{Float64}}()
    add_force = (gid, vec) -> begin
        if !haskey(raw_forces, gid); raw_forces[gid] = zeros(6); end
        raw_forces[gid] .+= vec
    end
    filter_shell_normal_moments = _filter_shell_normal_moments_enabled()
    shell_moment_filter =
        filter_shell_normal_moments ?
        _shell_normal_moment_filter_data(model, id_map, node_coords) :
        nothing

    for frc in model["FORCEs"]; if Int(frc["SID"]) == sid
        global_dir = get_coord_transform(model, Int(frc["CID"]), frc["Dir"])
        add_force(frc["GID"], zeros(6)); raw_forces[frc["GID"]][1:3] .+= global_dir * frc["Mag"] * scale
    end; end

    for mom in model["MOMENTs"]; if Int(mom["SID"]) == sid
        global_dir = get_coord_transform(model, Int(mom["CID"]), mom["Dir"])
        moment_vec = global_dir * mom["Mag"] * scale
        if shell_moment_filter !== nothing
            moment_vec = _filter_shell_normal_moment(
                moment_vec, mom["GID"], id_map, shell_moment_filter...)
        end
        add_force(mom["GID"], zeros(6)); raw_forces[mom["GID"]][4:6] .+= moment_vec
    end; end

    for pload in model["PLOAD4s"]; if Int(pload["SID"]) == sid
        eid = pload["EID"]
        if haskey(model["CSHELLs"], string(eid))
            el_def = model["CSHELLs"][string(eid)]
            nids = [get(id_map, n, 0) for n in el_def["NODES"]]
            if !any(x->x==0, nids)
                Xc = node_coords[nids, :]
                v1 = Xc[2,:] - Xc[1,:]; v2 = Xc[3,:] - Xc[1,:]
                normal_vec = (length(nids) == 4) ? cross(Xc[3,:] - Xc[1,:], Xc[4,:] - Xc[2,:]) : cross(v1, v2)
                area = 0.5 * norm(normal_vec)
                if haskey(pload, "N")
                    dir_vec = pload["N"]
                    n_dir = norm(dir_vec)
                    if n_dir > 1e-30
                        load_dir = dir_vec ./ n_dir
                    else
                        load_dir = normalize(normal_vec)
                    end
                    cid = get(pload, "CID", 0)
                    if cid != 0
                        load_dir = get_coord_transform(model, cid, load_dir)
                    end
                else
                    load_dir = normalize(normal_vec)
                end
                handled_tria3_pressure = false
                if length(nids) == 3
                    mat_data = _tria3_shell_isotropic_material(model, el_def)
                    frame = _tria3_shell_frame_and_local_coords(Xc)
                    if mat_data !== nothing && frame !== nothing
                        tf = area * pload["P"] * scale
                        local_dir = frame.Rel_t * load_dir

                        if abs(local_dir[3]) > 1e-12
                            f_plate = FEM.tria3_plate_macro_pressure_load(frame.lc, mat_data.E, mat_data.nu, mat_data.h, pload["P"] * scale * local_dir[3])
                            for (k, idx) in enumerate(nids)
                                dof = (idx-1)*6
                                f_loc = [0.0, 0.0, f_plate[(k-1)*3+1]]
                                # The condensed CTRIA3 pressure vector correlates with MSC/Nastran
                                # only through the primary local plate-rotation component; applying
                                # the second component over-rotates the validated pressure decks.
                                m_loc = [f_plate[(k-1)*3+2], 0.0, 0.0]
                                F_acc[dof+1:dof+3] .+= frame.Rel_t' * f_loc
                                F_acc[dof+4:dof+6] .+= frame.Rel_t' * m_loc
                            end
                            handled_tria3_pressure = true
                        end

                        local_inplane = [local_dir[1], local_dir[2], 0.0]
                        if norm(local_inplane) > 1e-12
                            f_inplane = frame.Rel_t' * (local_inplane .* (tf / 3))
                            for idx in nids
                                dof = (idx-1)*6
                                F_acc[dof+1:dof+3] .+= f_inplane
                            end
                            handled_tria3_pressure = true
                        end
                    end
                end

                if !handled_tria3_pressure
                    tf = area * pload["P"] * scale
                    f_node = load_dir .* (tf / length(nids))
                    for idx in nids; dof = (idx-1)*6; F_acc[dof+1:dof+3] .+= f_node; end
                end
            end
        elseif haskey(get(model, "CSOLIDs", Dict()), string(eid))
            # PLOAD4 on solid element face
            # For solids, PLOAD4 applies pressure on a face defined by G1/G3 corner nodes
            # or defaults to face 1 (first 4 nodes for CHEXA, first 3 for CTETRA)
            el_def = model["CSOLIDs"][string(eid)]
            el_nodes = el_def["NODES"]
            nn = length(el_nodes)
            # Determine face nodes from G1,G3 (if specified) or default to face 1
            g1 = get(pload, "G1", 0); g3 = get(pload, "G3", 0)
            local face_nids::Vector{Int}
            if g1 > 0 && g3 > 0 && nn == 8
                # CHEXA: find face containing both G1 and G3
                hexa_faces = [[1,2,3,4],[5,6,7,8],[1,2,6,5],[2,3,7,6],[3,4,8,7],[4,1,5,8]]
                face_nids = el_nodes[hexa_faces[1]]  # default
                for face_idx in hexa_faces
                    fn = el_nodes[face_idx]
                    if g1 in fn && g3 in fn; face_nids = fn; break; end
                end
            elseif g1 > 0 && nn == 4
                # CTETRA: find face containing G1
                tet_faces = [[1,2,3],[1,2,4],[2,3,4],[1,3,4]]
                face_nids = el_nodes[tet_faces[1]]
                for face_idx in tet_faces
                    fn = el_nodes[face_idx]
                    if g1 in fn; face_nids = fn; break; end
                end
            elseif nn == 8
                face_nids = el_nodes[[1,2,3,4]]  # default: bottom face
            elseif nn == 4
                face_nids = el_nodes[[1,2,3]]
            elseif nn == 6
                face_nids = el_nodes[[1,2,3]]  # bottom triangle
            else
                continue
            end
            idxs = [get(id_map, n, 0) for n in face_nids]
            if any(x->x==0, idxs); continue; end
            Xf = node_coords[idxs, :]
            nf = length(face_nids)
            if nf == 4
                normal_vec = cross(Xf[3,:]-Xf[1,:], Xf[4,:]-Xf[2,:])
                area = 0.5 * norm(normal_vec)
            elseif nf == 3
                normal_vec = cross(Xf[2,:]-Xf[1,:], Xf[3,:]-Xf[1,:])
                area = 0.5 * norm(normal_vec)
            else
                continue
            end
            load_dir = norm(normal_vec) > 1e-30 ? normalize(normal_vec) : [0.0,0.0,0.0]
            tf = area * pload["P"] * scale
            f_node = load_dir .* (tf / nf)
            for idx in idxs; dof = (idx-1)*6; F_acc[dof+1:dof+3] .+= f_node; end
        end
    end; end

    # --- PLOAD (uniform pressure on 3/4 grid points) ---
    for pload in get(model, "PLOADs", [])
        if Int(pload["SID"]) == sid
            pnodes = pload["NODES"]
            idxs = [get(id_map, n, 0) for n in pnodes]
            if !any(x->x==0, idxs)
                Xp = node_coords[idxs, :]
                np = length(pnodes)
                if np == 3
                    nrm = cross(Xp[2,:]-Xp[1,:], Xp[3,:]-Xp[1,:])
                    area = 0.5 * norm(nrm)
                elseif np == 4
                    nrm = cross(Xp[3,:]-Xp[1,:], Xp[4,:]-Xp[2,:])
                    area = 0.5 * norm(nrm)
                else
                    continue
                end
                load_dir = norm(nrm) > 1e-30 ? normalize(nrm) : [0.0,0.0,0.0]
                tf = area * pload["P"] * scale
                f_node = load_dir .* (tf / np)
                for idx in idxs; dof = (idx-1)*6; F_acc[dof+1:dof+3] .+= f_node; end
            end
        end
    end

    # --- GRAV (gravity/acceleration body forces) ---
    for grav in get(model, "GRAVs", [])
        if Int(grav["SID"]) == sid
            dir_raw = grav["N"]
            n_dir = norm(dir_raw)
            grav_dir = n_dir > 1e-30 ? dir_raw ./ n_dir : [0.0, 0.0, 0.0]
            accel = grav["A"] * scale
            grav_vec = grav_dir .* accel

            # CONM2 concentrated masses (with offset moment)
            for (_, cm) in get(model, "CONM2s", Dict())
                gid = cm["GID"]
                if haskey(id_map, gid)
                    m = cm["M"]
                    f_mass = m .* grav_vec
                    idx = id_map[gid]; dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= f_mass
                    # Offset moment: M = m * cross(offset, g)
                    offset = get(cm, "X", [0.0, 0.0, 0.0])
                    if norm(offset) > 1e-30
                        moment = m .* cross(offset, grav_vec)
                        F_acc[dof+4:dof+6] .+= moment
                    end
                end
            end

            # CONM1 concentrated masses (use M diagonal for translational gravity)
            for (_, cm) in get(model, "CONM1s", Dict())
                gid = cm["GID"]
                if haskey(id_map, gid)
                    f_mass = cm["M"] .* grav_vec
                    idx = id_map[gid]; dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= f_mass
                end
            end

            # CMASS2 scalar masses (direct value)
            for (_, cm) in get(model, "CMASS2s", Dict())
                g1 = get(cm, "G1", 0)
                c1 = get(cm, "C1", 0)
                if g1 > 0 && haskey(id_map, g1) && c1 >= 1 && c1 <= 3
                    idx = id_map[g1]; dof = (idx-1)*6
                    F_acc[dof + c1] += cm["M"] * grav_vec[c1]
                end
            end

            # CMASS1 scalar masses (via PMASS property)
            pmasses = get(model, "PMASSs", Dict())
            for (_, cm) in get(model, "CMASS1s", Dict())
                pid = string(get(cm, "PID", 0))
                pm = get(pmasses, pid, nothing)
                if pm === nothing; continue; end
                g1 = get(cm, "G1", 0)
                c1 = get(cm, "C1", 0)
                if g1 > 0 && haskey(id_map, g1) && c1 >= 1 && c1 <= 3
                    idx = id_map[g1]; dof = (idx-1)*6
                    F_acc[dof + c1] += pm["M"] * grav_vec[c1]
                end
            end

            # Shell element mass: rho * t * area, distributed to element nodes
            mats_m = model["MATs"]
            for (_, el) in get(model, "CSHELLs", Dict())
                if !haskey(el, "NODES"); continue; end
                nids = el["NODES"]; nn = length(nids)
                pid = string(get(el, "PID", 0))
                prop = get(model["PSHELLs"], pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_m, mid, nothing)
                rho = mat !== nothing ? get(mat, "RHO", 0.0) : 0.0
                nsm_shell = get(prop, "NSM", 0.0)
                if rho <= 0 && nsm_shell <= 0; continue; end
                idxs = [get(id_map, n, 0) for n in nids]
                if any(x->x==0, idxs); continue; end
                Xc = node_coords[idxs, :]
                if nn == 3
                    v1 = Xc[2,:] - Xc[1,:]; v2 = Xc[3,:] - Xc[1,:]
                    area = 0.5 * norm(cross(v1, v2))
                else
                    d13 = Xc[3,:] - Xc[1,:]; d24 = Xc[4,:] - Xc[2,:]
                    area = 0.5 * norm(cross(d13, d24))
                end
                nsm_area = get(prop, "NSM", 0.0)  # non-structural mass per unit area
                total_mass = (rho * get(prop, "T", 0.0) + nsm_area) * area
                f_per_node = (total_mass / nn) .* grav_vec
                for nid in nids
                    if haskey(id_map, nid)
                        dof = (id_map[nid]-1)*6
                        F_acc[dof+1:dof+3] .+= f_per_node
                    end
                end
            end

            # Bar element mass: (rho * A + NSM) * L, distributed to 2 nodes
            for (_, bar) in get(model, "CBARs", Dict())
                pid = string(get(bar, "PID", 0))
                prop = get(model["PBARLs"], pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_m, mid, nothing)
                if mat === nothing; continue; end
                rho = get(mat, "RHO", 0.0)
                nsm = get(prop, "NSM", 0.0)
                if rho <= 0 && nsm <= 0; continue; end
                ga, gb = bar["GA"], bar["GB"]
                if !haskey(id_map, ga) || !haskey(id_map, gb); continue; end
                i1, i2 = id_map[ga], id_map[gb]
                L = norm(node_coords[i2,:] - node_coords[i1,:])
                mass_per_length = rho * get(prop, "A", 0.0) + nsm
                total_mass = mass_per_length * L
                f_per_node = (total_mass / 2) .* grav_vec
                for (nid, idx) in [(ga, i1), (gb, i2)]
                    dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= f_per_node
                end
            end

            # Beam element mass: (rho * A + NSM) * L, distributed to 2 nodes (CBEAM)
            for (_, bar) in get(model, "CBEAMs", Dict())
                pid = string(get(bar, "PID", 0))
                prop = get(model["PBARLs"], pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_m, mid, nothing)
                if mat === nothing; continue; end
                rho = get(mat, "RHO", 0.0)
                nsm = get(prop, "NSM", 0.0)
                if rho <= 0 && nsm <= 0; continue; end
                ga, gb = bar["GA"], bar["GB"]
                if !haskey(id_map, ga) || !haskey(id_map, gb); continue; end
                i1, i2 = id_map[ga], id_map[gb]
                L = norm(node_coords[i2,:] - node_coords[i1,:])
                mass_per_length = rho * get(prop, "A", 0.0) + nsm
                total_mass = mass_per_length * L
                f_per_node = (total_mass / 2) .* grav_vec
                for (nid, idx) in [(ga, i1), (gb, i2)]
                    dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= f_per_node
                end
            end

            # Rod element mass: rho * A * L (CROD and CONROD)
            for rodset in [get(model, "CRODs", Dict()), get(model, "CONRODs", Dict())]
                for (_, rod) in rodset
                    local A_rod, mid_rod
                    if haskey(rod, "MID")  # CONROD
                        A_rod = get(rod, "A", 0.0)
                        mid_rod = string(rod["MID"])
                    else  # CROD
                        pid = string(get(rod, "PID", 0))
                        prop = get(get(model, "PRODs", Dict()), pid, nothing)
                        if prop === nothing; continue; end
                        A_rod = get(prop, "A", 0.0)
                        mid_rod = string(get(prop, "MID", 0))
                    end
                    mat = get(mats_m, mid_rod, nothing)
                    if mat === nothing; continue; end
                    rho = get(mat, "RHO", 0.0)
                    if rho <= 0; continue; end
                    ga, gb = rod["GA"], rod["GB"]
                    if !haskey(id_map, ga) || !haskey(id_map, gb); continue; end
                    i1, i2 = id_map[ga], id_map[gb]
                    L = norm(node_coords[i2,:] - node_coords[i1,:])
                    total_mass = rho * A_rod * L
                    f_per_node = (total_mass / 2) .* grav_vec
                    for idx in [i1, i2]
                        dof = (idx-1)*6
                        F_acc[dof+1:dof+3] .+= f_per_node
                    end
                end
            end

            # Solid element mass: rho * V, distributed to element nodes
            psolids_m = get(model, "PSOLIDs", Dict())
            coords_grav = zeros(8, 3)
            for (_, el) in get(model, "CSOLIDs", Dict())
                if !haskey(el, "NODES"); continue; end
                nids = el["NODES"]; nn = length(nids)
                pid = string(get(el, "PID", 0))
                prop = get(psolids_m, pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_m, mid, nothing)
                if mat === nothing; continue; end
                rho = get(mat, "RHO", 0.0)
                if rho <= 0; continue; end
                idxs = [get(id_map, n, 0) for n in nids]
                if any(x->x==0, idxs); continue; end
                for k in 1:nn; coords_grav[k,:] = node_coords[idxs[k],:]; end
                # Compute volume
                local V_el::Float64
                if nn == 4  # CTETRA
                    J = [coords_grav[2,j]-coords_grav[1,j] for j in 1:3]'
                    J = vcat(J, [coords_grav[3,j]-coords_grav[1,j] for j in 1:3]')
                    J = vcat(J, [coords_grav[4,j]-coords_grav[1,j] for j in 1:3]')
                    V_el = abs(det(J)) / 6.0
                elseif nn == 8  # CHEXA (approximate: 2×2×2 Gauss)
                    V_el = 0.0
                    xi_n = [-1,1,1,-1,-1,1,1,-1]; eta_n = [-1,-1,1,1,-1,-1,1,1]; zet_n = [-1,-1,-1,-1,1,1,1,1]
                    g = 1.0/sqrt(3.0); gpts = [-g, g]
                    for gi in gpts, gj in gpts, gk in gpts
                        dN = zeros(3, 8)
                        for i in 1:8
                            dN[1,i] = 0.125*xi_n[i]*(1+eta_n[i]*gj)*(1+zet_n[i]*gk)
                            dN[2,i] = 0.125*eta_n[i]*(1+xi_n[i]*gi)*(1+zet_n[i]*gk)
                            dN[3,i] = 0.125*zet_n[i]*(1+xi_n[i]*gi)*(1+eta_n[i]*gj)
                        end
                        V_el += abs(det(dN * coords_grav[1:8,:]))
                    end
                elseif nn == 6  # CPENTA (approximate)
                    J1 = [coords_grav[2,j]-coords_grav[1,j] for j in 1:3]'
                    J1 = vcat(J1, [coords_grav[3,j]-coords_grav[1,j] for j in 1:3]')
                    J1 = vcat(J1, [coords_grav[4,j]-coords_grav[1,j] for j in 1:3]')
                    V_el = abs(det(J1)) / 6.0
                    J2 = [coords_grav[5,j]-coords_grav[4,j] for j in 1:3]'
                    J2 = vcat(J2, [coords_grav[6,j]-coords_grav[4,j] for j in 1:3]')
                    J2 = vcat(J2, [coords_grav[3,j]-coords_grav[4,j] for j in 1:3]')
                    V_el += abs(det(J2)) / 6.0
                    J3 = [coords_grav[2,j]-coords_grav[5,j] for j in 1:3]'
                    J3 = vcat(J3, [coords_grav[3,j]-coords_grav[5,j] for j in 1:3]')
                    J3 = vcat(J3, [coords_grav[4,j]-coords_grav[5,j] for j in 1:3]')
                    V_el += abs(det(J3)) / 6.0
                else
                    continue
                end
                total_mass = rho * V_el
                f_per_node = (total_mass / nn) .* grav_vec
                for nid in nids
                    if haskey(id_map, nid)
                        dof = (id_map[nid]-1)*6
                        F_acc[dof+1:dof+3] .+= f_per_node
                    end
                end
            end
        end
    end

    # --- RFORCE (centrifugal body force) ---
    # F_node = m_node * ω² * r_perp  where ω = 2π*A (A in rev/unit time)
    # r_perp = position - (position · axis_unit) * axis_unit (perpendicular from axis)
    for rforce in get(model, "RFORCEs", [])
        if Int(rforce["SID"]) == sid
            A_rf = rforce["A"] * scale
            r_axis = rforce["R"]
            r_norm = norm(r_axis)
            if r_norm < 1e-30 || A_rf == 0.0; continue; end
            axis = r_axis ./ r_norm
            omega = 2.0 * pi * A_rf  # convert rev/time to rad/time
            omega2 = omega^2

            # Rotation center
            g_center = rforce["G"]
            center = zeros(3)
            if g_center > 0 && haskey(id_map, g_center)
                ic = id_map[g_center]
                center = node_coords[ic, :]
            end

            # Apply to all mass-carrying elements (shells, bars, rods, solids)
            mats_rf = model["MATs"]

            # Shell elements
            for (_, el) in get(model, "CSHELLs", Dict())
                if !haskey(el, "NODES"); continue; end
                nids_rf = el["NODES"]; nn = length(nids_rf)
                if nn < 3 || nn > 4; continue; end
                pid = string(get(el, "PID", 0))
                prop = get(model["PSHELLs"], pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_rf, mid, nothing)
                rho = mat !== nothing ? get(mat, "RHO", 0.0) : 0.0
                if rho <= 0; continue; end
                idxs_rf = [get(id_map, n, 0) for n in nids_rf]
                if any(x->x==0, idxs_rf); continue; end
                Xrf = node_coords[idxs_rf, :]
                if nn == 3
                    area = 0.5 * norm(cross(Xrf[2,:]-Xrf[1,:], Xrf[3,:]-Xrf[1,:]))
                else
                    area = 0.5 * norm(cross(Xrf[3,:]-Xrf[1,:], Xrf[4,:]-Xrf[2,:]))
                end
                mass_per_node = rho * get(prop, "T", 0.0) * area / nn
                for (li, idx) in enumerate(idxs_rf)
                    pos = node_coords[idx, :] .- center
                    proj = dot(pos, axis) * axis
                    r_perp = pos .- proj
                    f_centrifugal = mass_per_node * omega2 .* r_perp
                    dof = (idx-1)*6
                    F_acc[dof+1] += f_centrifugal[1]
                    F_acc[dof+2] += f_centrifugal[2]
                    F_acc[dof+3] += f_centrifugal[3]
                end
            end

            # Solid elements
            psolids_rf = get(model, "PSOLIDs", Dict())
            for (_, el) in get(model, "CSOLIDs", Dict())
                if !haskey(el, "NODES"); continue; end
                nids_rf = el["NODES"]; nn = length(nids_rf)
                pid = string(get(el, "PID", 0))
                prop = get(psolids_rf, pid, nothing)
                if prop === nothing; continue; end
                mid = string(get(prop, "MID", 0))
                mat = get(mats_rf, mid, nothing)
                if mat === nothing; continue; end
                rho = get(mat, "RHO", 0.0)
                if rho <= 0; continue; end
                idxs_rf = [get(id_map, n, 0) for n in nids_rf]
                if any(x->x==0, idxs_rf); continue; end
                Xrf = node_coords[idxs_rf, :]
                # Approximate volume (same as GRAV calculation)
                V_el = 0.0
                if nn == 4
                    J_rf = vcat([Xrf[2,j]-Xrf[1,j] for j in 1:3]', [Xrf[3,j]-Xrf[1,j] for j in 1:3]', [Xrf[4,j]-Xrf[1,j] for j in 1:3]')
                    V_el = abs(det(J_rf))/6.0
                elseif nn == 8
                    xi_n_rf = [-1,1,1,-1,-1,1,1,-1]; eta_n_rf = [-1,-1,1,1,-1,-1,1,1]; zet_n_rf = [-1,-1,-1,-1,1,1,1,1]
                    g_rf = 1.0/sqrt(3.0); gpts_rf = [-g_rf, g_rf]
                    for gi in gpts_rf, gj in gpts_rf, gk in gpts_rf
                        dN = zeros(3,8)
                        for i in 1:8
                            dN[1,i]=0.125*xi_n_rf[i]*(1+eta_n_rf[i]*gj)*(1+zet_n_rf[i]*gk)
                            dN[2,i]=0.125*eta_n_rf[i]*(1+xi_n_rf[i]*gi)*(1+zet_n_rf[i]*gk)
                            dN[3,i]=0.125*zet_n_rf[i]*(1+xi_n_rf[i]*gi)*(1+eta_n_rf[i]*gj)
                        end
                        V_el += abs(det(dN * Xrf))
                    end
                end
                mass_per_node = rho * V_el / nn
                for idx in idxs_rf
                    pos = node_coords[idx, :] .- center
                    proj = dot(pos, axis) * axis
                    r_perp = pos .- proj
                    f_cf = mass_per_node * omega2 .* r_perp
                    dof = (idx-1)*6
                    F_acc[dof+1] += f_cf[1]; F_acc[dof+2] += f_cf[2]; F_acc[dof+3] += f_cf[3]
                end
            end

            # Two-node line elements. The centrifugal acceleration is linear
            # along a straight element, so use the consistent two-node
            # equivalent translational loads rather than endpoint lumping.
            props_rf = get(model, "PBARLs", Dict())
            for group_name in ("CBARs", "CBEAMs")
                for (_, bar) in get(model, group_name, Dict())
                    pid = string(get(bar, "PID", 0))
                    prop = get(props_rf, pid, nothing)
                    prop === nothing && continue
                    mid = string(get(prop, "MID", 0))
                    mat = get(mats_rf, mid, nothing)
                    mat === nothing && continue
                    rho = Float64(get(mat, "RHO", 0.0))
                    area = Float64(get(prop, "A", 0.0))
                    nsm = Float64(get(prop, "NSM", 0.0))
                    mass_per_length = rho * area + nsm
                    mass_per_length > 0.0 || continue
                    ga, gb = get(bar, "GA", 0), get(bar, "GB", 0)
                    (haskey(id_map, ga) && haskey(id_map, gb)) || continue
                    i1, i2 = id_map[ga], id_map[gb]
                    p1 = view(node_coords, i1, :)
                    p2 = view(node_coords, i2, :)
                    _add_line_rforce!(
                        F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2)
                end
            end

            prods_rf = get(model, "PRODs", Dict())
            for (_, rod) in get(model, "CRODs", Dict())
                pid = string(get(rod, "PID", 0))
                prop = get(prods_rf, pid, nothing)
                prop === nothing && continue
                mid = string(get(prop, "MID", 0))
                mat = get(mats_rf, mid, nothing)
                mat === nothing && continue
                rho = Float64(get(mat, "RHO", 0.0))
                area = Float64(get(prop, "A", 0.0))
                nsm = Float64(get(prop, "NSM", 0.0))
                mass_per_length = rho * area + nsm
                mass_per_length > 0.0 || continue
                ga, gb = get(rod, "GA", 0), get(rod, "GB", 0)
                (haskey(id_map, ga) && haskey(id_map, gb)) || continue
                i1, i2 = id_map[ga], id_map[gb]
                p1 = view(node_coords, i1, :)
                p2 = view(node_coords, i2, :)
                _add_line_rforce!(
                    F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2)
            end

            for (_, rod) in get(model, "CONRODs", Dict())
                mid = string(get(rod, "MID", 0))
                mat = get(mats_rf, mid, nothing)
                mat === nothing && continue
                rho = Float64(get(mat, "RHO", 0.0))
                area = Float64(get(rod, "A", 0.0))
                nsm = Float64(get(rod, "NSM", 0.0))
                mass_per_length = rho * area + nsm
                mass_per_length > 0.0 || continue
                ga, gb = get(rod, "GA", 0), get(rod, "GB", 0)
                (haskey(id_map, ga) && haskey(id_map, gb)) || continue
                i1, i2 = id_map[ga], id_map[gb]
                p1 = view(node_coords, i1, :)
                p2 = view(node_coords, i2, :)
                _add_line_rforce!(
                    F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2)
            end
        end
    end

    # --- PLOAD1 (distributed load on bar elements) ---
    for pload in get(model, "PLOAD1s", [])
        if Int(pload["SID"]) == sid
            eid = pload["EID"]
            bar = nothing
            for (bid, b) in get(model, "CBARs", Dict())
                if parse(Int, bid) == eid; bar = b; break; end
            end
            if bar === nothing
                for (bid, b) in get(model, "CBEAMs", Dict())
                    if parse(Int, bid) == eid; bar = b; break; end
                end
            end
            if bar === nothing; continue; end
            ga, gb = bar["GA"], bar["GB"]
            if !haskey(id_map, ga) || !haskey(id_map, gb); continue; end
            i1, i2 = id_map[ga], id_map[gb]
            p1g = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2g = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            L = norm(p2g - p1g)
            if L < 1e-9; continue; end
            vx = normalize(p2g - p1g)
            vref = resolve_bar_vref(bar, p1g, id_map, node_coords)
            if norm(vref) < 1e-6 || abs(dot(vx, vref) / max(norm(vref), 1e-30)) > 0.999
                vref = abs(vx[3]) < 0.9 ? SVector(0.0, 0.0, 1.0) : SVector(0.0, 1.0, 0.0)
            end
            # Keep PLOAD1 local axes aligned with CBAR/CBEAM stiffness and recovery.
            vz = normalize(cross(vx, vref))
            vy = cross(vz, vx)

            f_local = _beam_pload1_equivalent_local_load_vector(pload, L, scale)
            if any(!=(0.0), f_local)
                for (base, idx) in ((0, i1), (6, i2))
                    dof = (idx - 1) * 6
                    f_trans = f_local[base + 1] .* vx .+
                              f_local[base + 2] .* vy .+
                              f_local[base + 3] .* vz
                    f_moment = f_local[base + 4] .* vx .+
                               f_local[base + 5] .* vy .+
                               f_local[base + 6] .* vz
                    F_acc[dof+1:dof+3] .+= f_trans
                    F_acc[dof+4:dof+6] .+= f_moment
                end
            end
            continue

#=
            # PLOAD1 TYPE: 1=FX, 2=FY, 3=FZ, 4=MX, 5=MY, 6=MZ (element local)
            ltype = pload["LOAD_TYPE"]
            x1_raw = pload["X1"]; p1_val = pload["P1"] * scale
            x2_raw = pload["X2"]; p2_val = pload["P2"] * scale
            # SCALE: "FR"=fractional (X1,X2 in 0-1), "LE"/""=actual distance
            pscale = uppercase(get(pload, "SCALE", ""))
            if pscale == "LE" || pscale == ""
                seg_L = x2_raw - x1_raw
            else  # "FR" — fractional
                seg_L = (x2_raw - x1_raw) * L
            end
            if seg_L < 1e-12; continue; end

            # Equivalent nodal forces for linear distribution p(x) = p1 + (p2-p1)*x/L_seg
            f_a_mag = seg_L * (2*p1_val + p2_val) / 6
            f_b_mag = seg_L * (p1_val + 2*p2_val) / 6

            if ltype >= 1 && ltype <= 3
                # Force load in element local direction
                local_dir = ltype == 1 ? vx : (ltype == 2 ? vy : vz)
                # Transverse moments (only for forces perpendicular to bar axis)
                if ltype >= 2  # transverse
                    m_a_mag = seg_L^2 * (3*p1_val + 2*p2_val) / 60
                    m_b_mag = -seg_L^2 * (2*p1_val + 3*p2_val) / 60
                    if ltype == 2  # FY → moment about Z (vz)
                        F_acc[(i1-1)*6+1:(i1-1)*6+3] .+= f_a_mag .* local_dir
                        F_acc[(i2-1)*6+1:(i2-1)*6+3] .+= f_b_mag .* local_dir
                        F_acc[(i1-1)*6+4:(i1-1)*6+6] .+= m_a_mag .* vz
                        F_acc[(i2-1)*6+4:(i2-1)*6+6] .+= m_b_mag .* vz
                    else  # FZ → moment about Y (vy, negated sign)
                        F_acc[(i1-1)*6+1:(i1-1)*6+3] .+= f_a_mag .* local_dir
                        F_acc[(i2-1)*6+1:(i2-1)*6+3] .+= f_b_mag .* local_dir
                        F_acc[(i1-1)*6+4:(i1-1)*6+6] .+= (-m_a_mag) .* vy
                        F_acc[(i2-1)*6+4:(i2-1)*6+6] .+= (-m_b_mag) .* vy
                    end
                else  # axial (ltype==1): no moments
                    F_acc[(i1-1)*6+1:(i1-1)*6+3] .+= f_a_mag .* local_dir
                    F_acc[(i2-1)*6+1:(i2-1)*6+3] .+= f_b_mag .* local_dir
                end
            elseif ltype >= 4 && ltype <= 6
                # Moment load in element local direction
                local_dir = ltype == 4 ? vx : (ltype == 5 ? vy : vz)
                F_acc[(i1-1)*6+4:(i1-1)*6+6] .+= f_a_mag .* local_dir
                F_acc[(i2-1)*6+4:(i2-1)*6+6] .+= f_b_mag .* local_dir
            end
=#
        end
    end

    if get(model, "_disable_thermal_in_resolve_loads", false)
        nothing
    else
    # --- Thermal loads (TEMP/TEMPD) ---
    # F_thermal = Σ_elem ∫ B' * D * ε₀ dA  where ε₀ = [α*ΔT, α*ΔT, 0] for shells
    temps_map = get(model, "TEMPs", Dict{Int,Dict{Int,Float64}}())
    tempd_map = get(model, "TEMPDs", Dict{Int,Float64}())
    node_temps = get(temps_map, sid, Dict{Int,Float64}())
    default_temp = get(tempd_map, sid, 0.0)
    if !isempty(node_temps) || default_temp != 0.0
        mats_th = model["MATs"]
        # Shell thermal loads
        for (_, el) in get(model, "CSHELLs", Dict())
            if !haskey(el, "NODES"); continue; end
            nids_th = el["NODES"]; nn = length(nids_th)
            if nn != 3 && nn != 4; continue; end
            pid = string(get(el, "PID", 0))
            prop = get(model["PSHELLs"], pid, nothing)
            if prop === nothing; continue; end
            mid = string(get(prop, "MID", 0))
            mat = get(mats_th, mid, nothing)
            if mat === nothing; continue; end
            alpha_th = get(mat, "ALPHA", 0.0); tref = get(mat, "TREF", 0.0)
            if alpha_th == 0.0; continue; end
            E_th = mat["E"]; nu_th = mat["NU"]; h_th = Float64(get(prop, "T", 0.0))
            if h_th <= 0 || E_th <= 0; continue; end

            # Average ΔT at element nodes
            dT_avg = 0.0
            for nid in nids_th
                dT_avg += get(node_temps, nid, default_temp) - tref
            end
            dT_avg /= nn
            if abs(dT_avg) < 1e-30; continue; end

            idxs_th = [get(id_map, n, 0) for n in nids_th]
            if any(x->x==0, idxs_th); continue; end
            Xth = node_coords[idxs_th, :]

            # Thermal membrane force: Nx = Ny = E*h*α*ΔT/(1-ν)
            N_th = E_th * h_th * alpha_th * dT_avg / (1.0 - nu_th) * scale

            if nn == 3
                # CTRIA3: constant strain → F = A * Bm' * [Nx; Ny; 0]
                v1 = Xth[2,:]-Xth[1,:]; v2 = Xth[3,:]-Xth[1,:]
                A2 = norm(cross(v1, v2))  # 2*area in 3D
                if A2 < 1e-30; continue; end
                # For flat triangle in 3D, the thermal force distributes equally
                # Total thermal force = 0 (self-equilibrating) but creates expansion
                # The equivalent nodal forces for membrane thermal strain:
                # F_node_i = (A/3) * Bm_i' * [Nx; Ny; 0] where Bm_i are shape function gradients
                # For uniform N_th, this gives: F_xi = N_th * (y_j - y_k)/2, F_yi = N_th * (x_k - x_j)/2
                # But in 3D we need to project to element local frame
                # Simplified: distribute as equal in-plane expansion force per node = N_th * perimeter_contribution
                # Actually for self-equilibrating thermal loads, the net force is zero on unconstrained elements
                # The thermal load only produces forces at constrained boundaries
                # Apply using the global normal-tangent decomposition:
                e1 = normalize(v1); e3 = normalize(cross(v1,v2)); e2 = cross(e3,e1)
                area = A2/2
                # Local membrane B-matrix for constant strain triangle:
                # Project nodes to local 2D
                lx = [0.0, dot(Xth[2,:]-Xth[1,:],e1), dot(Xth[3,:]-Xth[1,:],e1)]
                ly = [0.0, dot(Xth[2,:]-Xth[1,:],e2), dot(Xth[3,:]-Xth[1,:],e2)]
                b = [ly[2]-ly[3], ly[3]-ly[1], ly[1]-ly[2]] ./ (2*area)
                c_l = [lx[3]-lx[2], lx[1]-lx[3], lx[2]-lx[1]] ./ (2*area)
                # F_local = area * [b[i]*Nx + 0; c_l[i]*Ny + 0] for each node i (2 DOFs per node)
                for i in 1:3
                    # Thermal force in local x: area * b[i] * Nx + area * 0 * Nxy
                    fx_local = area * b[i] * N_th
                    fy_local = area * c_l[i] * N_th
                    # Transform local 2D force to global 3D
                    f_global = fx_local .* e1 .+ fy_local .* e2
                    dof = (idxs_th[i]-1)*6
                    F_acc[dof+1] += f_global[1]
                    F_acc[dof+2] += f_global[2]
                    F_acc[dof+3] += f_global[3]
                end
            elseif nn == 4
                # CQUAD4: use same approach with 2-triangle decomposition
                v13 = Xth[3,:]-Xth[1,:]; v24 = Xth[4,:]-Xth[2,:]
                normal_q = cross(v13, v24)
                A_q = 0.5 * norm(normal_q)
                if A_q < 1e-30; continue; end
                # Simplified: distribute thermal force equally to 4 nodes
                # For uniform N_th, the net force is zero (self-equilibrating)
                # Each node gets F = (A/4) * gradient_contribution
                e1 = normalize(Xth[2,:]-Xth[1,:]); e3 = normalize(normal_q); e2 = cross(e3,e1)
                # Bilinear quad thermal: use 2x2 Gauss integration of Bm'*N₀
                # Simplified: 4 equal sub-triangles centered approach
                for tri in [[1,2,3],[1,3,4]]
                    i1,i2,i3 = tri
                    v1t = Xth[i2,:]-Xth[i1,:]; v2t = Xth[i3,:]-Xth[i1,:]
                    A2t = norm(cross(v1t, v2t)); areat = A2t/2
                    if areat < 1e-30; continue; end
                    e1t = normalize(v1t); e3t = normalize(cross(v1t,v2t)); e2t = cross(e3t,e1t)
                    lxt = [0.0, dot(v1t,e1t), dot(v2t,e1t)]
                    lyt = [0.0, dot(v1t,e2t), dot(v2t,e2t)]
                    bt = [lyt[2]-lyt[3], lyt[3]-lyt[1], lyt[1]-lyt[2]] ./ (2*areat)
                    ct = [lxt[3]-lxt[2], lxt[1]-lxt[3], lxt[2]-lxt[1]] ./ (2*areat)
                    for (li, gi) in enumerate([i1,i2,i3])
                        fx_l = areat * bt[li] * N_th
                        fy_l = areat * ct[li] * N_th
                        f_g = fx_l .* e1t .+ fy_l .* e2t
                        dof = (idxs_th[gi]-1)*6
                        F_acc[dof+1] += f_g[1]; F_acc[dof+2] += f_g[2]; F_acc[dof+3] += f_g[3]
                    end
                end
            end
        end

        # Solid element thermal loads
        for (_, el) in get(model, "CSOLIDs", Dict())
            if !haskey(el, "NODES"); continue; end
            nids_th = el["NODES"]; nn = length(nids_th)
            pid = string(get(el, "PID", 0))
            prop = get(get(model, "PSOLIDs", Dict()), pid, nothing)
            if prop === nothing; continue; end
            mid = string(get(prop, "MID", 0))
            mat = get(mats_th, mid, nothing)
            if mat === nothing; continue; end
            alpha_th = get(mat, "ALPHA", 0.0); tref = get(mat, "TREF", 0.0)
            if alpha_th == 0.0; continue; end
            E_th = mat["E"]; nu_th = mat["NU"]

            dT_avg = 0.0
            for nid in nids_th; dT_avg += get(node_temps, nid, default_temp) - tref; end
            dT_avg /= nn
            if abs(dT_avg) < 1e-30; continue; end

            idxs_th = [get(id_map, n, 0) for n in nids_th]
            if any(x->x==0, idxs_th); continue; end
            Xth = node_coords[idxs_th, :]

            # Thermal strain: ε₀ = α*ΔT * {1, 1, 1, 0, 0, 0}
            # Thermal stress: σ₀ = D * ε₀ = E*α*ΔT/(1-2ν) * {1, 1, 1, 0, 0, 0} (for isotropic)
            # F = ∫ B' * σ₀ dV = V * B_centroid' * σ₀
            sig_th = E_th * alpha_th * dT_avg / (1.0 - 2.0*nu_th) * scale
            eps_0 = [sig_th, sig_th, sig_th, 0.0, 0.0, 0.0]

            if nn == 4  # CTETRA
                B = FEM.solid_centroid_B_tetra4(view(Xth, 1:4, :))
                J = [Xth[2,j]-Xth[1,j] for j in 1:3]'
                J = vcat(J, [Xth[3,j]-Xth[1,j] for j in 1:3]')
                J = vcat(J, [Xth[4,j]-Xth[1,j] for j in 1:3]')
                V = abs(det(J))/6.0
                F_th = V .* (B' * eps_0)
                for k in 1:4
                    dof = (idxs_th[k]-1)*6
                    for d in 1:3; F_acc[dof+d] += F_th[(k-1)*3+d]; end
                end
            elseif nn == 8  # CHEXA
                B = FEM.solid_centroid_B_hexa8(view(Xth, 1:8, :))
                # Approximate volume using centroid Jacobian
                xi_n = [-1,1,1,-1,-1,1,1,-1]; eta_n = [-1,-1,1,1,-1,-1,1,1]; zet_n = [-1,-1,-1,-1,1,1,1,1]
                dN = zeros(3,8)
                for i in 1:8; dN[1,i]=0.125*xi_n[i]; dN[2,i]=0.125*eta_n[i]; dN[3,i]=0.125*zet_n[i]; end
                V = 8.0 * abs(det(dN * Xth))  # 8 = volume of reference cube
                F_th = V .* (B' * eps_0)
                for k in 1:8
                    dof = (idxs_th[k]-1)*6
                    for d in 1:3; F_acc[dof+d] += F_th[(k-1)*3+d]; end
                end
            end
        end
    end

    end

    # Apply all point forces directly to their grids.
    for (gid, f_vec) in raw_forces
        if haskey(id_map, gid); idx = id_map[gid]; dof = (idx-1)*6; F_acc[dof+1:dof+6] .+= f_vec; end
    end

    for c in model["LOAD_COMBOS"]
        if Int(c["SID"]) == sid
            for sub in c["COMPS"]; resolve_loads(model, Int(sub["LID"]), scale * c["S"] * sub["S"], id_map, elem_map, node_coords, F_acc); end
        end
    end
end

function resolve_thermal_loads(model, temp_sid, scale, id_map, elem_map, node_coords, F_acc; node_R=nothing)
    temp_sid = isnothing(temp_sid) ? nothing : Int(temp_sid)
    node_temps, default_temp = _temperature_field_for_sid(model, temp_sid)
    if isempty(node_temps) && default_temp == 0.0
        return
    end

    mats_th = model["MATs"]

    if node_R !== nothing
        T_buf = zeros(12, 12)

        for (_, bar) in get(model, "CBARs", Dict())
            pid = string(get(bar, "PID", 0))
            prop = get(get(model, "PBARLs", Dict()), pid, nothing)
            prop === nothing && continue
            ga = get(bar, "GA", 0)
            gb = get(bar, "GB", 0)
            (ga > 0 && gb > 0 && haskey(id_map, ga) && haskey(id_map, gb)) || continue

            mat = _effective_mat1_for_nodes(model, get(prop, "MID", 0), [ga, gb]; temp_sid=temp_sid)
            mat === nothing && continue
            alpha_th = Float64(get(mat, "ALPHA", 0.0))
            E_th = Float64(get(mat, "E", 0.0))
            tref = Float64(get(mat, "TREF", 0.0))
            (alpha_th != 0.0 && E_th > 0.0) || continue

            i1, i2 = id_map[ga], id_map[gb]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
            L = norm(p2_eff - p1_eff)
            L < 1e-9 && continue

            dT_avg = _average_temperature_for_nodes([ga, gb], node_temps, default_temp) - tref
            abs(dT_avg) < 1e-30 && continue

            vx = normalize(p2_eff - p1_eff)
            v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)
            if norm(v_ref) < 1e-6
                v_ref = SVector(0.0, 0.0, 1.0)
                abs(dot(vx, v_ref)) > 0.9 && (v_ref = SVector(0.0, 1.0, 0.0))
            end
            vz = normalize(cross(vx, v_ref))
            vy = cross(vz, vx)
            Rel_t = vcat(vx', vy', vz')

            fill!(view(T_buf, 1:12, 1:12), 0.0)
            TR1 = Rel_t * node_R[i1]
            TR2 = Rel_t * node_R[i2]
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
            if has_offset
                S_wa = skew3(wa); S_wb = skew3(wb)
                T_buf[1:3, 4:6] = -Rel_t * S_wa * node_R[i1]
                T_buf[7:9, 10:12] = -Rel_t * S_wb * node_R[i2]
            end

            nth = E_th * Float64(get(prop, "A", 0.0)) * alpha_th * dT_avg * scale
            abs(nth) < 1e-30 && continue
            f_loc = zeros(12)
            f_loc[1] = -nth
            f_loc[7] = nth
            f_glob = view(T_buf, 1:12, 1:12)' * f_loc
            dofs = [(i1-1)*6+k for k in 1:6]
            append!(dofs, [(i2-1)*6+k for k in 1:6])
            for k in 1:12
                F_acc[dofs[k]] += f_glob[k]
            end
        end

        for (_, bar) in get(model, "CBEAMs", Dict())
            pid = string(get(bar, "PID", 0))
            prop = get(get(model, "PBARLs", Dict()), pid, nothing)
            prop === nothing && continue
            ga = get(bar, "GA", 0)
            gb = get(bar, "GB", 0)
            (ga > 0 && gb > 0 && haskey(id_map, ga) && haskey(id_map, gb)) || continue

            mat = _effective_mat1_for_nodes(model, get(prop, "MID", 0), [ga, gb]; temp_sid=temp_sid)
            mat === nothing && continue
            alpha_th = Float64(get(mat, "ALPHA", 0.0))
            E_th = Float64(get(mat, "E", 0.0))
            tref = Float64(get(mat, "TREF", 0.0))
            (alpha_th != 0.0 && E_th > 0.0) || continue

            i1, i2 = id_map[ga], id_map[gb]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
            L = norm(p2_eff - p1_eff)
            L < 1e-9 && continue

            dT_avg = _average_temperature_for_nodes([ga, gb], node_temps, default_temp) - tref
            abs(dT_avg) < 1e-30 && continue

            vx = normalize(p2_eff - p1_eff)
            v_ref = resolve_bar_vref(bar, p1, id_map, node_coords)
            if norm(v_ref) < 1e-6
                v_ref = SVector(0.0, 0.0, 1.0)
                abs(dot(vx, v_ref)) > 0.9 && (v_ref = SVector(0.0, 1.0, 0.0))
            end
            vz = normalize(cross(vx, v_ref))
            vy = cross(vz, vx)
            Rel_t = vcat(vx', vy', vz')

            fill!(view(T_buf, 1:12, 1:12), 0.0)
            TR1 = Rel_t * node_R[i1]
            TR2 = Rel_t * node_R[i2]
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
            if has_offset
                S_wa = skew3(wa); S_wb = skew3(wb)
                T_buf[1:3, 4:6] = -Rel_t * S_wa * node_R[i1]
                T_buf[7:9, 10:12] = -Rel_t * S_wb * node_R[i2]
            end

            nth = E_th * Float64(get(prop, "A", 0.0)) * alpha_th * dT_avg * scale
            abs(nth) < 1e-30 && continue
            f_loc = zeros(12)
            f_loc[1] = -nth
            f_loc[7] = nth
            f_glob = view(T_buf, 1:12, 1:12)' * f_loc
            dofs = [(i1-1)*6+k for k in 1:6]
            append!(dofs, [(i2-1)*6+k for k in 1:6])
            for k in 1:12
                F_acc[dofs[k]] += f_glob[k]
            end
        end

        prods = get(model, "PRODs", Dict())
        for (_, rod) in get(model, "CRODs", Dict())
            pid = string(get(rod, "PID", 0))
            prop = get(prods, pid, nothing)
            prop === nothing && continue
            ga = get(rod, "GA", 0)
            gb = get(rod, "GB", 0)
            (ga > 0 && gb > 0 && haskey(id_map, ga) && haskey(id_map, gb)) || continue

            mat = _effective_mat1_for_nodes(model, get(prop, "MID", 0), [ga, gb]; temp_sid=temp_sid)
            mat === nothing && continue
            alpha_th = Float64(get(mat, "ALPHA", 0.0))
            E_th = Float64(get(mat, "E", 0.0))
            tref = Float64(get(mat, "TREF", 0.0))
            (alpha_th != 0.0 && E_th > 0.0) || continue

            i1, i2 = id_map[ga], id_map[gb]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            L = norm(p2 - p1)
            L < 1e-9 && continue

            dT_avg = _average_temperature_for_nodes([ga, gb], node_temps, default_temp) - tref
            abs(dT_avg) < 1e-30 && continue

            vx = normalize(p2 - p1)
            ref = abs(vx[3]) < 0.9 ? SVector(0.0, 0.0, 1.0) : SVector(0.0, 1.0, 0.0)
            vz = normalize(cross(vx, ref))
            vy = cross(vz, vx)
            Rel_t = vcat(vx', vy', vz')

            fill!(view(T_buf, 1:12, 1:12), 0.0)
            TR1 = Rel_t * node_R[i1]; TR2 = Rel_t * node_R[i2]
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2

            nth = E_th * Float64(get(prop, "A", 0.0)) * alpha_th * dT_avg * scale
            abs(nth) < 1e-30 && continue
            f_loc = zeros(12)
            f_loc[1] = -nth
            f_loc[7] = nth
            f_glob = view(T_buf, 1:12, 1:12)' * f_loc
            dofs = [(i1-1)*6+k for k in 1:6]
            append!(dofs, [(i2-1)*6+k for k in 1:6])
            for k in 1:12
                F_acc[dofs[k]] += f_glob[k]
            end
        end

        for (_, rod) in get(model, "CONRODs", Dict())
            ga = get(rod, "GA", 0)
            gb = get(rod, "GB", 0)
            (ga > 0 && gb > 0 && haskey(id_map, ga) && haskey(id_map, gb)) || continue

            mat = _effective_mat1_for_nodes(model, get(rod, "MID", 0), [ga, gb]; temp_sid=temp_sid)
            mat === nothing && continue
            alpha_th = Float64(get(mat, "ALPHA", 0.0))
            E_th = Float64(get(mat, "E", 0.0))
            tref = Float64(get(mat, "TREF", 0.0))
            (alpha_th != 0.0 && E_th > 0.0) || continue

            i1, i2 = id_map[ga], id_map[gb]
            p1 = SVector{3}(node_coords[i1,1], node_coords[i1,2], node_coords[i1,3])
            p2 = SVector{3}(node_coords[i2,1], node_coords[i2,2], node_coords[i2,3])
            L = norm(p2 - p1)
            L < 1e-9 && continue

            dT_avg = _average_temperature_for_nodes([ga, gb], node_temps, default_temp) - tref
            abs(dT_avg) < 1e-30 && continue

            vx = normalize(p2 - p1)
            ref = abs(vx[3]) < 0.9 ? SVector(0.0, 0.0, 1.0) : SVector(0.0, 1.0, 0.0)
            vz = normalize(cross(vx, ref))
            vy = cross(vz, vx)
            Rel_t = vcat(vx', vy', vz')

            fill!(view(T_buf, 1:12, 1:12), 0.0)
            TR1 = Rel_t * node_R[i1]; TR2 = Rel_t * node_R[i2]
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2

            nth = E_th * Float64(get(rod, "A", 0.0)) * alpha_th * dT_avg * scale
            abs(nth) < 1e-30 && continue
            f_loc = zeros(12)
            f_loc[1] = -nth
            f_loc[7] = nth
            f_glob = view(T_buf, 1:12, 1:12)' * f_loc
            dofs = [(i1-1)*6+k for k in 1:6]
            append!(dofs, [(i2-1)*6+k for k in 1:6])
            for k in 1:12
                F_acc[dofs[k]] += f_glob[k]
            end
        end
    end

    for (_, el) in get(model, "CSHELLs", Dict())
        if !haskey(el, "NODES"); continue; end
        nids_th = el["NODES"]; nn = length(nids_th)
        if nn != 3 && nn != 4; continue; end
        pid = string(get(el, "PID", 0))
        prop = get(model["PSHELLs"], pid, nothing)
        if prop === nothing; continue; end
        mid = string(get(prop, "MID", 0))
        mat = _effective_mat1_for_nodes(model, mid, nids_th; temp_sid=temp_sid)
        if mat === nothing
            mat = get(mats_th, mid, nothing)
        end
        if mat === nothing; continue; end
        alpha_th = get(mat, "ALPHA", 0.0); tref = get(mat, "TREF", 0.0)
        if alpha_th == 0.0; continue; end
        E_th = mat["E"]; nu_th = mat["NU"]; h_th = Float64(get(prop, "T", 0.0))
        if h_th <= 0 || E_th <= 0; continue; end

        dT_avg = _average_temperature_for_nodes(nids_th, node_temps, default_temp) - tref
        if abs(dT_avg) < 1e-30; continue; end

        idxs_th = [get(id_map, n, 0) for n in nids_th]
        if any(x->x==0, idxs_th); continue; end
        Xth = node_coords[idxs_th, :]
        N_th = E_th * h_th * alpha_th * dT_avg / (1.0 - nu_th) * scale

        if nn == 3
            v1 = Xth[2,:]-Xth[1,:]; v2 = Xth[3,:]-Xth[1,:]
            A2 = norm(cross(v1, v2))
            if A2 < 1e-30; continue; end
            e1 = normalize(v1); e3 = normalize(cross(v1,v2)); e2 = cross(e3,e1)
            area = A2/2
            lx = [0.0, dot(Xth[2,:]-Xth[1,:],e1), dot(Xth[3,:]-Xth[1,:],e1)]
            ly = [0.0, dot(Xth[2,:]-Xth[1,:],e2), dot(Xth[3,:]-Xth[1,:],e2)]
            b = [ly[2]-ly[3], ly[3]-ly[1], ly[1]-ly[2]] ./ (2*area)
            c_l = [lx[3]-lx[2], lx[1]-lx[3], lx[2]-lx[1]] ./ (2*area)
            for i in 1:3
                fx_local = area * b[i] * N_th
                fy_local = area * c_l[i] * N_th
                f_global = fx_local .* e1 .+ fy_local .* e2
                dof = (idxs_th[i]-1)*6
                F_acc[dof+1] += f_global[1]
                F_acc[dof+2] += f_global[2]
                F_acc[dof+3] += f_global[3]
            end
        elseif nn == 4
            v13 = Xth[3,:]-Xth[1,:]; v24 = Xth[4,:]-Xth[2,:]
            normal_q = cross(v13, v24)
            A_q = 0.5 * norm(normal_q)
            if A_q < 1e-30; continue; end
            for tri in [[1,2,3],[1,3,4]]
                i1,i2,i3 = tri
                v1t = Xth[i2,:]-Xth[i1,:]; v2t = Xth[i3,:]-Xth[i1,:]
                A2t = norm(cross(v1t, v2t)); areat = A2t/2
                if areat < 1e-30; continue; end
                e1t = normalize(v1t); e3t = normalize(cross(v1t,v2t)); e2t = cross(e3t,e1t)
                lxt = [0.0, dot(v1t,e1t), dot(v2t,e1t)]
                lyt = [0.0, dot(v1t,e2t), dot(v2t,e2t)]
                bt = [lyt[2]-lyt[3], lyt[3]-lyt[1], lyt[1]-lyt[2]] ./ (2*areat)
                ct = [lxt[3]-lxt[2], lxt[1]-lxt[3], lxt[2]-lxt[1]] ./ (2*areat)
                for (li, gi) in enumerate([i1,i2,i3])
                    fx_l = areat * bt[li] * N_th
                    fy_l = areat * ct[li] * N_th
                    f_g = fx_l .* e1t .+ fy_l .* e2t
                    dof = (idxs_th[gi]-1)*6
                    F_acc[dof+1] += f_g[1]
                    F_acc[dof+2] += f_g[2]
                    F_acc[dof+3] += f_g[3]
                end
            end
        end
    end

    for (_, el) in get(model, "CSOLIDs", Dict())
        if !haskey(el, "NODES"); continue; end
        nids_th = el["NODES"]; nn = length(nids_th)
        pid = string(get(el, "PID", 0))
        prop = get(get(model, "PSOLIDs", Dict()), pid, nothing)
        if prop === nothing; continue; end
        mid = string(get(prop, "MID", 0))
        mat = _effective_mat1_for_nodes(model, mid, nids_th; temp_sid=temp_sid)
        if mat === nothing
            mat = get(mats_th, mid, nothing)
        end
        if mat === nothing; continue; end
        alpha_th = get(mat, "ALPHA", 0.0); tref = get(mat, "TREF", 0.0)
        if alpha_th == 0.0; continue; end
        E_th = mat["E"]; nu_th = mat["NU"]

        dT_avg = _average_temperature_for_nodes(nids_th, node_temps, default_temp) - tref
        if abs(dT_avg) < 1e-30; continue; end

        idxs_th = [get(id_map, n, 0) for n in nids_th]
        if any(x->x==0, idxs_th); continue; end
        Xth = node_coords[idxs_th, :]

        sig_th = E_th * alpha_th * dT_avg / (1.0 - 2.0*nu_th) * scale
        eps_0 = [sig_th, sig_th, sig_th, 0.0, 0.0, 0.0]

        if nn == 4
            B = FEM.solid_centroid_B_tetra4(view(Xth, 1:4, :))
            J = [Xth[2,j]-Xth[1,j] for j in 1:3]'
            J = vcat(J, [Xth[3,j]-Xth[1,j] for j in 1:3]')
            J = vcat(J, [Xth[4,j]-Xth[1,j] for j in 1:3]')
            V = abs(det(J))/6.0
            F_th = V .* (B' * eps_0)
            for k in 1:4
                dof = (idxs_th[k]-1)*6
                for d in 1:3
                    F_acc[dof+d] += F_th[(k-1)*3+d]
                end
            end
        elseif nn == 8
            B = FEM.solid_centroid_B_hexa8(view(Xth, 1:8, :))
            xi_n = [-1,1,1,-1,-1,1,1,-1]
            eta_n = [-1,-1,1,1,-1,-1,1,1]
            zet_n = [-1,-1,-1,-1,1,1,1,1]
            dN = zeros(3,8)
            for i in 1:8
                dN[1,i] = 0.125 * xi_n[i]
                dN[2,i] = 0.125 * eta_n[i]
                dN[3,i] = 0.125 * zet_n[i]
            end
            V = 8.0 * abs(det(dN * Xth))
            F_th = V .* (B' * eps_0)
            for k in 1:8
                dof = (idxs_th[k]-1)*6
                for d in 1:3
                    F_acc[dof+d] += F_th[(k-1)*3+d]
                end
            end
        end
    end
end

# RBE3 rigid body coefficient
function _rbe3_rb_coeff(comp_dof::Int, ref_dof::Int, dx::Float64, dy::Float64, dz::Float64)
    if comp_dof == ref_dof; return 1.0; end
    if comp_dof <= 3 && ref_dof >= 4
        if comp_dof == 1
            if ref_dof == 5; return dz; end
            if ref_dof == 6; return -dy; end
        elseif comp_dof == 2
            if ref_dof == 4; return -dz; end
            if ref_dof == 6; return dx; end
        elseif comp_dof == 3
            if ref_dof == 4; return dy; end
            if ref_dof == 5; return -dx; end
        end
    end
    return 0.0
end
