# loads.jl — Load resolution (FORCE, MOMENT, PLOAD4, GRAV, PLOAD1, LOAD combos)

@inline function _filter_shell_normal_moments_enabled()
    # Compatibility query for callers of the former load-filter option.
    # A nodal moment is a physical load even when the associated drilling
    # rotation is constrained by SPC/AUTOSPC: it must remain in K*u - F.
    if solver_env_bool("JFEM_FILTER_SHELL_NORMAL_MOMENTS", false)
        @warn "JFEM_FILTER_SHELL_NORMAL_MOMENTS is deprecated; shell-normal moments are no longer filtered. Full applied moments are retained for the solve and SPC/AUTOSPC reaction recovery." maxlog=1
    end
    return false
end

function _add_scalar_mass_gravity!(F_acc, model, cm, mass, id_map, node_coords, acceleration)
    isfinite(mass) || throw(ArgumentError("Scalar mass must be finite"))
    endpoints = Tuple{Int,Int,Vector{Float64}}[]
    scalar_acceleration = zeros(2)
    for terminal in 1:2
        gid = Int(get(cm,"G$terminal",0))
        component = Int(get(cm,"C$terminal",0))
        if gid == 0
            push!(endpoints, (0,0,zeros(3)))
            continue
        end
        1 <= component <= 6 || throw(ArgumentError("Scalar mass GRID component must be in 1:6; SPOINT terminals are unsupported"))
        haskey(id_map,gid) || throw(ArgumentError("Scalar mass references missing GRID $gid"))
        idx = id_map[gid]
        grid = get(model["GRIDs"],string(gid),nothing)
        grid === nothing && throw(ArgumentError("Scalar mass references missing GRID $gid"))
        direction = zeros(3); direction[mod1(component,3)] = 1.0
        direction = get_coord_transform(model,Int(get(grid,"CD",0)),direction;
            position=view(node_coords,idx,:))
        push!(endpoints, (idx,component,direction))
        component <= 3 && (scalar_acceleration[terminal] = dot(direction,acceleration))
    end
    endpoints[1][1:2] != endpoints[2][1:2] ||
        throw(ArgumentError("Scalar mass terminals must be distinct"))
    q = mass * (scalar_acceleration[1]-scalar_acceleration[2])
    for terminal in 1:2
        idx,component,direction = endpoints[terminal]
        idx == 0 && continue
        base = (idx-1)*6 + (component <= 3 ? 0 : 3)
        F_acc[base+1:base+3] .+= (terminal == 1 ? q : -q) .* direction
    end
    return nothing
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
    omega2::Real;
    method::Integer=2,
    alpha::AbstractVector=zeros(3),
)
    a1 = _rotation_body_acceleration(p1 .- center, axis, omega2, alpha)
    a2 = _rotation_body_acceleration(p2 .- center, axis, omega2, alpha)
    mass = Float64(mass_per_length) * norm(p2 .- p1)
    f1, f2 = method == 1 ? (mass/2 .* a1, mass/2 .* a2) :
        (mass .* (a1 ./ 3 .+ a2 ./ 6), mass .* (a1 ./ 6 .+ a2 ./ 3))
    dof1 = (Int(idx1) - 1) * 6
    dof2 = (Int(idx2) - 1) * 6
    F_acc[dof1+1:dof1+3] .+= f1
    F_acc[dof2+1:dof2+3] .+= f2
    return
end

@inline _rotation_body_acceleration(r, axis, omega2, alpha) =
    omega2 .* (r .- dot(r,axis) .* axis) .+ cross(alpha,r)

function _solid_body_mass(X, rho)
    n = size(X,1)
    n == 4 && return FEM.nastran_lumped_mass_tetra4(X,Float64(rho))
    n == 6 && return FEM.nastran_lumped_mass_cpenta6(X,Float64(rho))
    n == 8 && return FEM.nastran_lumped_mass_hexa8(X,Float64(rho))
    throw(ArgumentError("Body loads require a supported 4-, 6-, or 8-node solid"))
end

function _add_rforce_mass_acceleration!(F_acc,model,id_map,node_coords,center,omega,alpha,scale)
    n = length(id_map)
    rotations = [Matrix{Float64}(I,3,3) for _ in 1:n]
    acceleration = zeros(6n)
    for (gid,idx) in id_map
        grid = get(model["GRIDs"],string(gid),nothing)
        grid === nothing && throw(ArgumentError("RFORCE references missing GRID $gid"))
        R = get_coord_transform(model,Int(get(grid,"CD",0)),Matrix{Float64}(I,3,3);
            position=view(node_coords,idx,:))
        rotations[idx] = R
        r = view(node_coords,idx,:) .- center
        base = (idx-1)*6
        acceleration[base+1:base+3] = R' * (-cross(omega,cross(omega,r))+cross(alpha,r))
        acceleration[base+4:base+6] = R' * alpha
    end
    # WTMASS scales the dynamic mass matrix, not GRAV/RFORCE body-load data.
    mass_model = copy(model)
    mass_model["PARAM_WTMASS"] = 1.0
    load = assemble_mass(mass_model,id_map,node_coords,rotations,6n) * acceleration
    for idx in 1:n
        base = (idx-1)*6; R = rotations[idx]
        F_acc[base+1:base+3] .+= scale .* (R * view(load,base+1:base+3))
        F_acc[base+4:base+6] .+= scale .* (R * view(load,base+4:base+6))
    end
    return nothing
end

function _add_concentrated_rforce!(F_acc,model,id_map,node_coords,center,omega,alpha,scale,method)
    for (group, mass_function) in (("CONM2s",_conm2_mass_basic),("CONM1s",_conm1_mass_basic))
        for (_,cm) in get(model,group,Dict())
            gid = Int(cm["GID"])
            haskey(id_map,gid) || throw(ArgumentError("$group references missing GRID $gid"))
            idx = id_map[gid]; position = view(node_coords,idx,:)
            M = mass_function(model,cm,position)
            r = position .- center
            # METHOD=2 applies the grid acceleration through the full matrix;
            # it deliberately does not accelerate a CONM2 offset separately.
            acceleration = vcat(-cross(omega,cross(omega,r)) + cross(alpha,r),alpha)
            if method == 2
                load = M * acceleration
            elseif group == "CONM2s"
                offset, frame = _conm2_offset_frame(model,cm,position)
                mass = Float64(cm["M"])
                force = -mass .* cross(omega,cross(omega,r+offset))
                # Remove the parallel-axis contribution from the grid block.
                offset_inertia = mass .* (dot(offset,offset) .* Matrix{Float64}(I,3,3) - offset*offset')
                inertia_cg = M[4:6,4:6] - offset_inertia
                moment = cross(offset,force) - cross(omega,inertia_cg*omega)
                load = vcat(force,moment) + M * vcat(cross(alpha,r),alpha)
            else
                norm(M[1:3,4:6]) <= 64eps(Float64)*max(norm(M),1.0) ||
                    throw(ArgumentError("RFORCE METHOD=1 does not support translation/rotation-coupled CONM1; use METHOD=2"))
                force = -cross(omega,M[1:3,1:3]*cross(omega,r))
                moment = -cross(omega,M[4:6,4:6]*omega)
                load = vcat(force,moment) + M * vcat(cross(alpha,r),alpha)
            end
            base = (idx-1)*6
            F_acc[base+1:base+6] .+= scale .* load
        end
    end
    return nothing
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
    sid_int in visited && throw(ArgumentError("Cyclic LOAD combination at SID=$sid_int"))
    push!(visited, sid_int)
    try
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
    return f
    finally
        delete!(visited, sid_int)
    end
end

function _accel1_data(model, card, id_map)
    cid = get(card,"CID",0)
    cid isa Integer && cid >= 0 || throw(ArgumentError("ACCEL1 CID must be a nonnegative integer"))
    a = get(card,"A",nothing)
    a isa Real && isfinite(a) || throw(ArgumentError("ACCEL1 A must be finite"))
    n = get(card,"N",nothing)
    n isa AbstractVector && length(n) == 3 && all(v -> v isa Real && isfinite(v),n) && any(!iszero,n) ||
        throw(ArgumentError("ACCEL1 N must contain three finite, nonzero-vector components"))
    grids = get(card,"GRIDS",nothing)
    grids isa AbstractVector && !isempty(grids) &&
        all(g -> g isa Integer && g > 0 && haskey(id_map,g),grids) ||
        throw(ArgumentError("ACCEL1 GRIDS must list existing positive integer GRID IDs"))
    if cid != 0
        cord = get(get(model,"CORDs",Dict()),string(cid),nothing)
        cord !== nothing || throw(ArgumentError("ACCEL1 references undefined CID=$cid"))
        get(cord,"TYPE","RECTANGULAR") == "RECTANGULAR" ||
            throw(ArgumentError("ACCEL1 currently requires a rectangular acceleration CID"))
    end
    return cid, Float64(a), Float64.(n), unique(grids)
end

function _guard_accel1_context(model, card, id_map)
    _accel1_data(model,card,id_map)
    get(model,"SOL",get(get(model,"CASE_CONTROL",Dict()),"SOL",101)) in (101,105) ||
        throw(ArgumentError("ACCEL1 is currently supported only for SOL101/SOL105 static loads"))
    get(model,"PARAM_WTMASS",1.0) == 1.0 ||
        throw(ArgumentError("ACCEL1 with nonunit WTMASS requires independently verified load scaling"))
    _selected_direct_matrix(model,"M2GG") === nothing ||
        throw(ArgumentError("ACCEL1 with an external M2GG mass contribution is unsupported"))
    all(g -> get(g,"SEID",0) == 0, values(model["GRIDs"])) ||
        throw(ArgumentError("ACCEL1 does not support superelements"))
    for key in ("CMASS1s","CMASS2s"), cm in values(get(model,key,Dict())), t in 1:2
        get(cm,"G$t",0) == 0 && continue
        get(cm,"C$t",0) in 1:6 ||
            throw(ArgumentError("ACCEL1 scalar-point mass exclusion is unsupported; GRID-connected scalar masses require components 1:6"))
    end
    return nothing
end

function _check_selected_acceleration_loads(model, sid, scale, id_map, path=Int[])
    isfinite(scale) || throw(ArgumentError("Acceleration LOAD scale must be finite"))
    iszero(scale) && return nothing
    sid in path && throw(ArgumentError("Cyclic LOAD combination: " * join([path;sid]," -> ")))
    push!(path,sid)
    try
        any(c -> Int(c["SID"]) == sid,get(model,"ACCELs",[])) &&
            throw(ArgumentError("Selected ACCEL SID=$sid is unsupported; its spatial acceleration table must not be silently omitted"))
        cards = [c for c in get(model,"ACCEL1s",[]) if Int(c["SID"]) == sid]
        if !isempty(cards)
            # MSC QRG ACCEL1 requires its SID to be distinct from any other load entry.
            owners = length(cards)
            for key in ("FORCEs","MOMENTs","GRAVs","RFORCEs","PLOADs","PLOAD1s","PLOAD4s","SPCDs","LOAD_COMBOS")
                owners += count(c -> Int(c["SID"]) == sid,get(model,key,[]))
            end
            owners == 1 || throw(ArgumentError("ACCEL1 SID=$sid must be unique among load entries"))
            _guard_accel1_context(model,only(cards),id_map)
        end
        for combo in get(model,"LOAD_COMBOS",[])
            Int(combo["SID"]) == sid || continue
            for sub in combo["COMPS"]
                _check_selected_acceleration_loads(model,Int(sub["LID"]),
                    scale*combo["S"]*sub["S"],id_map,path)
            end
        end
    finally
        pop!(path)
    end
    return nothing
end

function _accel1_mass_context(model,id_map,node_coords)
    n = length(id_map)
    rotations = [Matrix{Float64}(I,3,3) for _ in 1:n]
    for (gid,idx) in id_map
        grid = model["GRIDs"][string(gid)]
        rotations[idx] = get_coord_transform(model,Int(get(grid,"CD",0)),Matrix{Float64}(I,3,3);
            position=view(node_coords,idx,:))
    end
    return (rotations=rotations,mass=assemble_mass(model,id_map,node_coords,rotations,6n))
end

function _add_accel1_load!(F_acc, model, card, scale, id_map, node_coords, mass_cache=nothing)
    iszero(scale) && return nothing
    cid, factor, direction, grids = _accel1_data(model,card,id_map)
    n = length(id_map)
    acceleration = zeros(6n)
    basic = factor .* get_coord_transform(model,cid,direction)
    all(isfinite,basic) || throw(ArgumentError("ACCEL1 acceleration overflows"))
    context = mass_cache === nothing ? nothing : mass_cache[]
    if context === nothing
        context = _accel1_mass_context(model,id_map,node_coords)
        mass_cache === nothing || (mass_cache[] = context)
    end
    rotations = context.rotations
    for gid in grids
        idx = id_map[gid]; base = 6(idx-1)
        acceleration[base+1:base+3] = rotations[idx]' * basic
    end
    # ACCEL1 prescribes translational acceleration only at its listed GRIDs.
    # Form the physical unreduced mass load before ordinary CD/MPC load mapping;
    # off-diagonal mass terms can also load an unlisted GRID or rotational DOF.
    load = context.mass * acceleration
    all(isfinite,load) && all(isfinite,scale .* load) ||
        throw(ArgumentError("ACCEL1 mass load is nonfinite"))
    for idx in 1:n
        base = 6(idx-1); R = rotations[idx]
        F_acc[base+1:base+3] .+= scale .* (R * view(load,base+1:base+3))
        F_acc[base+4:base+6] .+= scale .* (R * view(load,base+4:base+6))
    end
    return nothing
end

function resolve_loads(model, sid, scale, id_map, elem_map, node_coords, F_acc)
    _filter_shell_normal_moments_enabled() # Warn once only for an explicit retired option.
    if !isempty(get(model,"ACCEL1s",[])) || !isempty(get(model,"ACCELs",[]))
        # Capability preflight precedes accumulation, including nested LOADs.
        _check_selected_acceleration_loads(model,Int(sid),scale,id_map)
    end
    return _resolve_loads!(model, Int(sid), scale, id_map, elem_map, node_coords,
                          F_acc, Int[], Ref{Any}(nothing))
end

function _resolve_loads!(model, sid::Int, scale, id_map, elem_map, node_coords,
                         F_acc, load_path::Vector{Int}, accel_mass_cache=nothing)
    sid in load_path && throw(ArgumentError("Cyclic LOAD combination: " * join([load_path; sid], " -> ")))
    push!(load_path, sid)
    try
    for card in get(model,"ACCEL1s",[])
        Int(card["SID"]) == sid || continue
        _add_accel1_load!(F_acc,model,card,scale,id_map,node_coords,accel_mass_cache)
    end
    raw_forces = Dict{Int, Vector{Float64}}()
    add_force = (gid, vec) -> begin
        if !haskey(raw_forces, gid); raw_forces[gid] = zeros(6); end
        raw_forces[gid] .+= vec
    end
    for frc in model["FORCEs"]; if Int(frc["SID"]) == sid
        idx = get(id_map, frc["GID"], 0)
        idx == 0 && continue
        global_dir = get_coord_transform(model, Int(frc["CID"]), frc["Dir"];
                                         position=view(node_coords, idx, :))
        add_force(frc["GID"], zeros(6)); raw_forces[frc["GID"]][1:3] .+= global_dir * frc["Mag"] * scale
    end; end

    for mom in model["MOMENTs"]; if Int(mom["SID"]) == sid
        idx = get(id_map, mom["GID"], 0)
        idx == 0 && continue
        global_dir = get_coord_transform(model, Int(mom["CID"]), mom["Dir"];
                                         position=view(node_coords, idx, :))
        moment_vec = global_dir * mom["Mag"] * scale
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
                area > 1e-30 || continue
                if haskey(pload, "N")
                    dir_vec = pload["N"]
                    n_dir = norm(dir_vec)
                    if n_dir > 1e-30
                        load_dir = dir_vec ./ n_dir
                        cid = get(pload, "CID", 0)
                        if cid != 0
                            load_dir = get_coord_transform(model, cid, load_dir;
                                position=vec(sum(Xc; dims=1)) ./ length(nids))
                        end
                    else
                        load_dir = normalize(normal_vec)
                    end
                else
                    load_dir = normalize(normal_vec)
                end
                # 2026-08-05: CTRIA3 pressure lumping is the same equal-share
                # force rule as every other face (A*p/n per node, no nodal
                # moments), matching the reference solver. The former special
                # path routed transverse pressure through the removed macro-quad
                # condensation, which added a partial nodal-moment component the
                # reference does not produce.
                tf = area * pload["P"] * scale
                f_node = load_dir .* (tf / length(nids))
                for idx in nids; dof = (idx-1)*6; F_acc[dof+1:dof+3] .+= f_node; end
            end
        elseif haskey(get(model, "CSOLIDs", Dict()), string(eid))
            # Solid face identification follows G1/G3 (diagonally opposite
            # corners), or G1/G4 (TETRA corner excluded from the loaded face).
            el_def = model["CSOLIDs"][string(eid)]
            el_nodes = el_def["NODES"]
            nn = length(el_nodes)
            g1 = get(pload, "G1", 0); g3 = get(pload, "G3", 0)
            local face_nids::Vector{Int}
            if nn == 8 || (nn == 6 && g3 > 0)
                faces = nn == 8 ?
                    ((1,2,3,4),(5,6,7,8),(1,2,6,5),(2,3,7,6),(3,4,8,7),(4,1,5,8)) :
                    ((1,2,5,4),(2,3,6,5),(3,1,4,6))
                face_nids = Int[]
                for face_idx in faces
                    fn = Int[el_nodes[k] for k in face_idx]
                    i1 = findfirst(==(g1), fn)
                    i3 = findfirst(==(g3), fn)
                    if i1 !== nothing && i3 !== nothing && abs(i1 - i3) == 2
                        face_nids = fn
                        break
                    end
                end
                isempty(face_nids) && throw(ArgumentError("PLOAD4 EID=$eid requires diagonally opposite face corners G1/G3"))
            elseif nn == 4
                (g3 in el_nodes && g1 in el_nodes && g1 != g3) ||
                    throw(ArgumentError("PLOAD4 CTETRA EID=$eid requires G1 on the face and G4 opposite the face"))
                face_nids = Int[n for n in el_nodes if n != g3]
            elseif nn == 6
                g1 in el_nodes || throw(ArgumentError("PLOAD4 CPENTA EID=$eid requires a face corner G1"))
                face_nids = g1 in el_nodes[1:3] ? Int.(el_nodes[1:3]) : Int.(el_nodes[4:6])
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
            area > 1e-30 || continue
            load_dir = normalize(normal_vec)
            # Positive solid pressure points into the element, regardless of
            # the face's indexing orientation.
            all_idxs = [get(id_map, n, 0) for n in el_nodes]
            any(==(0), all_idxs) && continue
            face_center = vec(sum(Xf; dims=1)) ./ nf
            interior = vec(sum(node_coords[all_idxs, :]; dims=1)) ./ nn
            dot(load_dir, interior .- face_center) < 0.0 && (load_dir = -load_dir)
            direction = get(pload, "N", [0.0, 0.0, 0.0])
            if norm(direction) > 1e-30
                load_dir = get_coord_transform(model, get(pload, "CID", 0), normalize(direction);
                    position=face_center)
            end
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
            grav_vec = (grav["A"] * scale) .* get_coord_transform(
                model, get(grav, "CID", 0), grav["N"])

            # CONM2 concentrated masses (with offset moment)
            for (_, cm) in get(model, "CONM2s", Dict())
                gid = cm["GID"]
                haskey(id_map,gid) || throw(ArgumentError("CONM2 references missing GRID $gid"))
                if haskey(id_map, gid)
                    m = Float64(cm["M"])
                    isfinite(m) || throw(ArgumentError("CONM2 mass must be finite"))
                    f_mass = m .* grav_vec
                    idx = id_map[gid]; dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= f_mass
                    # Offset moment: M = m * cross(offset, g)
                    offset, _ = _conm2_offset_frame(model, cm, view(node_coords, idx, :))
                    if norm(offset) > 1e-30
                        moment = m .* cross(offset, grav_vec)
                        F_acc[dof+4:dof+6] .+= moment
                    end
                end
            end

            # Full CONM1 tensor, including translation/rotation coupling and CID.
            for (_, cm) in get(model, "CONM1s", Dict())
                gid = cm["GID"]
                haskey(id_map,gid) || throw(ArgumentError("CONM1 references missing GRID $gid"))
                idx = id_map[gid]; dof = (idx-1)*6
                block = _conm1_mass_basic(model,cm,view(node_coords,idx,:))
                F_acc[dof+1:dof+6] .+= block[:,1:3] * grav_vec
            end

            # CMASS2 scalar masses (direct value)
            for (_, cm) in get(model, "CMASS2s", Dict())
                _add_scalar_mass_gravity!(F_acc,model,cm,Float64(cm["M"]),id_map,node_coords,grav_vec)
            end

            # CMASS1 scalar masses (via PMASS property)
            pmasses = get(model, "PMASSs", Dict())
            for (_, cm) in get(model, "CMASS1s", Dict())
                pid = string(get(cm, "PID", 0))
                pm = get(pmasses, pid, nothing)
                pm === nothing && throw(ArgumentError("CMASS1 references missing PMASS $pid"))
                _add_scalar_mass_gravity!(F_acc,model,cm,Float64(pm["M"]),id_map,node_coords,grav_vec)
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

            # Rod element mass: (rho * A + NSM) * L (CROD and CONROD)
            for rodset in [get(model, "CRODs", Dict()), get(model, "CONRODs", Dict())]
                for (_, rod) in rodset
                    local A_rod, mid_rod, nsm_rod
                    if haskey(rod, "MID")  # CONROD
                        A_rod = get(rod, "A", 0.0)
                        nsm_rod = get(rod, "NSM", 0.0)
                        mid_rod = string(rod["MID"])
                    else  # CROD
                        pid = string(get(rod, "PID", 0))
                        prop = get(get(model, "PRODs", Dict()), pid, nothing)
                        if prop === nothing; continue; end
                        A_rod = get(prop, "A", 0.0)
                        nsm_rod = get(prop, "NSM", 0.0)
                        mid_rod = string(get(prop, "MID", 0))
                    end
                    mat = get(mats_m, mid_rod, nothing)
                    if mat === nothing; continue; end
                    rho = get(mat, "RHO", 0.0)
                    if rho <= 0 && nsm_rod <= 0; continue; end
                    ga, gb = rod["GA"], rod["GB"]
                    if !haskey(id_map, ga) || !haskey(id_map, gb); continue; end
                    i1, i2 = id_map[ga], id_map[gb]
                    L = norm(node_coords[i2,:] - node_coords[i1,:])
                    total_mass = (rho * A_rod + nsm_rod) * L
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
                mass_block = _solid_body_mass(Matrix(view(coords_grav,1:nn,:)),rho)
                for (k,idx) in enumerate(idxs)
                    dof = (idx-1)*6
                    mass_node = mass_block[3k-2,3k-2]
                    F_acc[dof+1:dof+3] .+= mass_node .* grav_vec
                end
            end
        end
    end

    # --- RFORCE (centrifugal body force) ---
    # F_node = m_node * ω² * r_perp, where ω = 2π*A*norm(R).
    # r_perp = position - (position · axis_unit) * axis_unit (perpendicular from axis)
    for rforce in get(model, "RFORCEs", [])
        if Int(rforce["SID"]) == sid
            A_rf = Float64(rforce["A"])
            racc = Float64(get(rforce,"RACC",0.0))
            # Parsed BDF cards default to METHOD=1. Keep the existing direct
            # dictionary API's consistent-line convention when METHOD is absent.
            method = Int(get(rforce,"METHOD",2))
            method in (1,2) || throw(ArgumentError("RFORCE METHOD must be 1 or 2"))
            Int(get(rforce,"MB",0)) == 0 && Int(get(rforce,"IDRF",0)) == 0 ||
                throw(ArgumentError("RFORCE superelement MB and IDRF selection are unsupported"))
            isfinite(A_rf) && isfinite(racc) || throw(ArgumentError("RFORCE A and RACC must be finite"))
            r_axis = get_coord_transform(model, get(rforce, "CID", 0), rforce["R"])
            length(r_axis) == 3 && all(isfinite,r_axis) || throw(ArgumentError("RFORCE requires a finite rotation vector"))
            r_norm = norm(r_axis)
            axis = r_norm > 0.0 ? r_axis ./ r_norm : zeros(3)
            omega = 2.0 * pi * A_rf * r_norm  # convert rev/time to rad/time
            alpha_raw = (2.0*pi*racc) .* r_axis
            alpha = scale .* alpha_raw
            # LOAD coefficients scale the resulting force, including its sign.
            omega2 = omega^2 * scale

            # Rotation center
            g_center = Int(get(rforce,"G",0))
            center = zeros(3)
            if g_center != 0
                haskey(id_map,g_center) || throw(ArgumentError("RFORCE references missing rotation GRID $g_center"))
                ic = id_map[g_center]
                center = node_coords[ic, :]
            end

            if r_norm == 0.0 || (A_rf == 0.0 && racc == 0.0); continue; end
            if haskey(rforce,"METHOD") && method == 2
                _add_rforce_mass_acceleration!(F_acc,model,id_map,node_coords,center,
                    (2.0*pi*A_rf) .* r_axis,alpha_raw,scale)
                continue
            end
            coupled_shells = !isempty(get(model,"CSHELLs",Dict())) &&
                sol103_shell_mass_formulation(model) === :coupled_consistent
            coupled_lines_or_solids = any(!isempty(get(model,key,Dict())) for key in
                ("CBARs","CBEAMs","CRODs","CONRODs","CSOLIDs")) &&
                _sol103_param_enabled(get(model,"PARAM_COUPMASS",false),false)
            if method == 1 && (coupled_shells || coupled_lines_or_solids)
                throw(ArgumentError("RFORCE METHOD=1 requires lumped mass; use METHOD=2 with COUPMASS>0"))
            end
            for group in ("CMASS1s","CMASS2s")
                isempty(get(model,group,Dict())) ||
                    throw(ArgumentError("RFORCE with scalar CMASS elements requires explicit METHOD=2"))
            end
            _add_concentrated_rforce!(F_acc,model,id_map,node_coords,center,
                (2.0*pi*A_rf) .* r_axis,alpha_raw,scale,method)

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
                nsm = Float64(get(prop,"NSM",0.0))
                if rho <= 0 && nsm <= 0; continue; end
                idxs_rf = [get(id_map, n, 0) for n in nids_rf]
                if any(x->x==0, idxs_rf); continue; end
                Xrf = node_coords[idxs_rf, :]
                if nn == 3
                    area = 0.5 * norm(cross(Xrf[2,:]-Xrf[1,:], Xrf[3,:]-Xrf[1,:]))
                else
                    area = 0.5 * norm(cross(Xrf[3,:]-Xrf[1,:], Xrf[4,:]-Xrf[2,:]))
                end
                mass_per_node = (rho * get(prop, "T", 0.0) + nsm) * area / nn
                for (li, idx) in enumerate(idxs_rf)
                    pos = node_coords[idx, :] .- center
                    f_centrifugal = mass_per_node .* _rotation_body_acceleration(pos,axis,omega2,alpha)
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
                mass_block = _solid_body_mass(Xrf,rho)
                for (k,idx) in enumerate(idxs_rf)
                    mass_node = mass_block[3k-2,3k-2]
                    pos = node_coords[idx,:] .- center
                    force = mass_node .* _rotation_body_acceleration(pos,axis,omega2,alpha)
                    dof = (idx-1)*6
                    F_acc[dof+1:dof+3] .+= force
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
                        F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2;method=method,alpha=alpha)
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
                    F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2;method=method,alpha=alpha)
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
                    F_acc, i1, i2, p1, p2, mass_per_length, center, axis, omega2;method=method,alpha=alpha)
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
    if !isempty(node_temps) || haskey(tempd_map, sid)
        _assert_supported_shell_thermal_load(model, sid, scale)
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
            elseif nn == 6
                _add_cpenta_thermal_load!(F_acc, idxs_th, Xth, sig_th)
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
            for sub in c["COMPS"]
                _resolve_loads!(model, Int(sub["LID"]), scale * c["S"] * sub["S"],
                    id_map, elem_map, node_coords, F_acc, load_path, accel_mass_cache)
            end
        end
    end
    finally
        pop!(load_path)
    end
end

function _add_cpenta_thermal_load!(F_acc, idxs, coords, thermal_stress)
    g = inv(sqrt(3.0))
    for (r,s) in ((1/6,1/6),(2/3,1/6),(1/6,2/3)), z in (-g,g)
        dN = FEM._cpenta6_dN(r,s,z)
        J = dN * coords
        jacobian = abs(det(J))
        jacobian > 1e-30 || continue
        gradient = J \ dN
        coefficient = thermal_stress * jacobian / 6.0
        for k in 1:6, d in 1:3
            F_acc[6(idxs[k]-1)+d] += coefficient * gradient[d,k]
        end
    end
    return F_acc
end

function _assert_supported_shell_thermal_load(model, temp_sid, scale)
    isnothing(temp_sid) && return nothing
    sid = Int(temp_sid)
    (haskey(get(model, "TEMPs", Dict()), sid) ||
     haskey(get(model, "TEMPDs", Dict()), sid)) ||
        throw(ArgumentError("Selected thermal load $sid has no defined TEMP or TEMPD field"))
    iszero(scale) && return nothing
    for family in ("RBE2s", "RBE3s"), (eid, rigid) in get(model, family, Dict())
        alpha = Float64(get(rigid, "ALPHA", 0.0))
        isfinite(alpha) || throw(ArgumentError(
            "$family element $eid has non-finite ALPHA for thermal load $sid"))
        iszero(alpha) || throw(ArgumentError(
            "$family thermal expansion is unsupported (element $eid, thermal load $sid); rigid constraint thermal offsets are not implemented"))
    end
    for (eid, el) in get(model, "CSHELLs", Dict())
        pid = string(get(el, "PID", 0))
        prop = get(get(model, "PSHELLs", Dict()), pid, nothing)
        prop === nothing && continue
        is_laminate = get(prop, "TYPE", "") == "PCOMP_CLT"
        nids = get(el, "NODES", Int[])
        mids = is_laminate ?
            [get(ply, "mid", get(ply, "MID", 0)) for ply in get(prop, "PLY_DATA", [])] :
            [get(prop, field, 0) for field in ("MID", "MID2", "MID3", "MID4")]
        for mid in mids
            mat = _effective_mat1_for_nodes(model, mid, nids; temp_sid=sid)
            mat === nothing && continue
            anisotropic = get(mat, "TYPE", "") in ("MAT2", "MAT8") || haskey(mat, "E1") || haskey(mat, "G11")
            (is_laminate || anisotropic) || continue
            family = is_laminate ? "PCOMP" : "anisotropic PSHELL"
            for field in ("ALPHA", "A1", "A2", "A3", "A12")
                alpha = Float64(get(mat, field, 0.0))
                isfinite(alpha) || throw(ArgumentError(
                    "$family $pid material $mid has non-finite $field for thermal load $sid"))
                iszero(alpha) && continue
                # The equivalent MAT1 has no laminate expansion tensor or
                # thermal bending resultant. PCOMP TREF provenance is also
                # unavailable, so even a zero temperature is not proof of
                # zero thermal strain. Refuse the unsupported active path.
                throw(ArgumentError("$family thermal expansion is unsupported (element $eid, property $pid, material $mid, thermal load $sid); equivalent MAT1 cannot represent anisotropic thermal resultants"))
            end
        end
    end
    return nothing
end

function resolve_thermal_loads(model, temp_sid, scale, id_map, elem_map, node_coords, F_acc; node_R=nothing)
    temp_sid = isnothing(temp_sid) ? nothing : Int(temp_sid)
    _assert_supported_shell_thermal_load(model, temp_sid, scale)
    node_temps, default_temp = _temperature_field_for_sid(model, temp_sid)
    if isempty(node_temps) && !haskey(get(model, "TEMPDs", Dict()), temp_sid)
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
            # The accumulator is in basic coordinates; its caller applies
            # GRID CD rotations once after all load families are combined.
            TR1 = Rel_t
            TR2 = Rel_t
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
            if has_offset
                S_wa = skew3(wa); S_wb = skew3(wb)
                T_buf[1:3, 4:6] = -Rel_t * S_wa
                T_buf[7:9, 10:12] = -Rel_t * S_wb
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
            TR1 = Rel_t
            TR2 = Rel_t
            T_buf[1:3, 1:3] = TR1; T_buf[4:6, 4:6] = TR1
            T_buf[7:9, 7:9] = TR2; T_buf[10:12, 10:12] = TR2
            if has_offset
                S_wa = skew3(wa); S_wb = skew3(wb)
                T_buf[1:3, 4:6] = -Rel_t * S_wa
                T_buf[7:9, 10:12] = -Rel_t * S_wb
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
            TR1 = Rel_t; TR2 = Rel_t
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
            TR1 = Rel_t; TR2 = Rel_t
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
        elseif nn == 6
            _add_cpenta_thermal_load!(F_acc, idxs_th, Xth, sig_th)
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
