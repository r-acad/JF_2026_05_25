# stress_recovery.jl — Element stress/force/strain recovery

@inline function _stress_entry_public_id(key, entry)
    if entry isa AbstractDict && haskey(entry, "ID")
        value = entry["ID"]
        parsed = tryparse(Int, string(value))
        parsed !== nothing && return parsed
    end
    parsed = tryparse(Int, string(key))
    parsed !== nothing && return parsed
    m = match(r"^-?\d+", string(key))
    m !== nothing && return parse(Int, m.match)
    return 0
end

@inline function _shell_edge_key(a::Int, b::Int)
    return a < b ? (a, b) : (b, a)
end

function _tria3_shell_macro_blend_weights(model)
    edge_counts = Dict{Tuple{Int,Int},Int}()
    weights = Dict{Int,Float64}()

    for (_, el) in get(model, "CSHELLs", Dict())
        nids = Int.(el["NODES"])
        if length(nids) == 3
            edges = ((nids[1], nids[2]), (nids[2], nids[3]), (nids[3], nids[1]))
        elseif length(nids) == 4
            edges = ((nids[1], nids[2]), (nids[2], nids[3]), (nids[3], nids[4]), (nids[4], nids[1]))
        else
            continue
        end
        for (a, b) in edges
            key = _shell_edge_key(a, b)
            edge_counts[key] = get(edge_counts, key, 0) + 1
        end
    end

    for (id, el) in get(model, "CSHELLs", Dict())
        nids = Int.(el["NODES"])
        length(nids) == 3 || continue
        eid = _stress_entry_public_id(id, el)
        shared_edges = 0
        for (a, b) in ((nids[1], nids[2]), (nids[2], nids[3]), (nids[3], nids[1]))
            shared_edges += get(edge_counts, _shell_edge_key(a, b), 0) > 1 ? 1 : 0
        end
        weights[eid] = clamp((shared_edges - 1) / 2, 0.0, 1.0)
    end

    return weights
end

function _blend_tria3_macro_bending_iso!(
    M::AbstractVector,
    s_z1::AbstractVector,
    s_z2::AbstractVector,
    e_z1::AbstractVector,
    e_z2::AbstractVector,
    coords::AbstractMatrix,
    u_elem::AbstractVector,
    E,
    nu,
    h::Float64,
    bend_ratio::Float64,
    macro_weight::Float64,
)
    macro_weight <= 0.0 && return false
    abs(bend_ratio) <= 1e-12 && return false

    M_macro = FEM.tria3_plate_macro_average_moment(coords, u_elem, E, nu, h; bend_ratio=bend_ratio)
    all(isfinite, M_macro) || return false

    M_blend = (1.0 - macro_weight) .* M .+ macro_weight .* M_macro
    D = (Float64(E) / (1.0 - Float64(nu)^2)) .* [1.0 Float64(nu) 0.0; Float64(nu) 1.0 0.0; 0.0 0.0 (1.0-Float64(nu))/2.0]
    kappa = -(12.0 / (bend_ratio * h^3)) .* (D \ M_blend)
    eps_mem = (e_z1 .+ e_z2) ./ 2.0
    z1 = -h / 2.0
    z2 = h / 2.0

    M .= M_blend
    e_z1 .= eps_mem .+ z1 .* kappa
    e_z2 .= eps_mem .+ z2 .* kappa
    s_z1 .= D * e_z1
    s_z2 .= D * e_z2
    return true
end

@inline function _quad4_equilibrium_shear_from_bending(coords::AbstractMatrix, M_corners::AbstractMatrix)
    dNdr = (-0.25, 0.25, 0.25, -0.25)
    dNds = (-0.25, -0.25, 0.25, 0.25)
    J11 = dNdr[1]*coords[1,1] + dNdr[2]*coords[2,1] + dNdr[3]*coords[3,1] + dNdr[4]*coords[4,1]
    J12 = dNdr[1]*coords[1,2] + dNdr[2]*coords[2,2] + dNdr[3]*coords[3,2] + dNdr[4]*coords[4,2]
    J21 = dNds[1]*coords[1,1] + dNds[2]*coords[2,1] + dNds[3]*coords[3,1] + dNds[4]*coords[4,1]
    J22 = dNds[1]*coords[1,2] + dNds[2]*coords[2,2] + dNds[3]*coords[3,2] + dNds[4]*coords[4,2]
    detJ = J11*J22 - J12*J21
    if abs(detJ) < 1e-12
        return nothing
    end
    invJ = [J22 -J12; -J21 J11] / detJ

    deriv_nat(vals) = (
        dNdr[1]*vals[1] + dNdr[2]*vals[2] + dNdr[3]*vals[3] + dNdr[4]*vals[4],
        dNds[1]*vals[1] + dNds[2]*vals[2] + dNds[3]*vals[3] + dNds[4]*vals[4],
    )

    function deriv_phys(vals)
        ddr, dds = deriv_nat(vals)
        grad = invJ * [ddr, dds]
        return grad[1], grad[2]
    end

    mx = view(M_corners, :, 1)
    my = view(M_corners, :, 2)
    dmx_dx, _ = deriv_phys(mx)
    _, dmy_dy = deriv_phys(my)
    return [dmx_dx, dmy_dy]
end

@inline function _quad4_blend_recovered_shear(current_Q::AbstractVector, eq_Q)
    eq_Q === nothing && return collect(current_Q)
    Q_out = [Float64(current_Q[1]), Float64(current_Q[2])]
    for i in 1:2
        eqi = Float64(eq_Q[i])
        !isfinite(eqi) && continue
        if abs(eqi) < abs(Q_out[i])
            Q_out[i] = eqi
        end
    end
    return Q_out
end


function recover_shell_stresses!(model, id_map, X, node_R, u_global, snorm_normals, stresses, results_json)
    lc_buf = zeros(4,2)
    q4_frame_mode = q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC")
    pcomp_axis_mode = q4_pcomp_axis_mode("JFEM_Q4_PCOMP_AXIS_MODE_STATIC")
    membrane_incomp_center_jacobian = q4_sol105_membrane_incomp_center_jacobian_enabled()
    tria3_macro_blend = _tria3_shell_macro_blend_weights(model)

    for (id, el) in model["CSHELLs"]
        eid = _stress_entry_public_id(id, el)
        pid = string(el["PID"])
        if !haskey(model["PSHELLs"], pid); continue; end
        prop = model["PSHELLs"][pid]
        mid = string(prop["MID"])
        if !haskey(model["MATs"], mid); continue; end
        mat = model["MATs"][mid]

        nids = el["NODES"]; n = length(nids)
        if any(x->get(id_map,x,0)==0, nids); continue; end

        local N, M, Q, s_z1, s_z2, e_z1, e_z2, elem_key
        quad4_bilin_rows = Any[]
        stress_ok = true

        if n==4
            i1, i2, i3, i4 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]], id_map[nids[4]]
            p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
            p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
            p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3])
            p4 = SVector{3}(X[i4,1], X[i4,2], X[i4,3])
            sr_indices = [i1, i2, i3, i4]

            v1, v2, v3 = shell_element_frame_quad4(p1, p2, p3, p4, q4_frame_mode)
            v1, v2, v3 = apply_snorm_to_frame(v1, v2, v3, sr_indices, snorm_normals)
            c = (p1+p2+p3+p4)/4.0
            lc_buf[1,1]=dot(p1-c,v1); lc_buf[1,2]=dot(p1-c,v2)
            lc_buf[2,1]=dot(p2-c,v1); lc_buf[2,2]=dot(p2-c,v2)
            lc_buf[3,1]=dot(p3-c,v1); lc_buf[3,2]=dot(p3-c,v2)
            lc_buf[4,1]=dot(p4-c,v1); lc_buf[4,2]=dot(p4-c,v2)
            curvature_membrane = nothing

            Rel_t = vcat(v1', v2', v3')
            u_el = zeros(24)
            for k=1:4
                idx = id_map[nids[k]]
                u_el[(k-1)*6+1:(k-1)*6+3] = Rel_t * node_R[idx] * u_global[(idx-1)*6+1:(idx-1)*6+3]
                u_el[(k-1)*6+4:(k-1)*6+6] = Rel_t * node_R[idx] * u_global[(idx-1)*6+4:(idx-1)*6+6]
            end
            br = get(prop, "BEND_RATIO", 1.0)
            clt_Cm = nothing
            clt_Cb = nothing
            material_shear_rotation = 0.0
            membrane_shear_center_row = false
            if get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "Cm")
                clt_Cm = copy(prop["Cm"])
                clt_Cb = haskey(prop, "Cb") ? copy(prop["Cb"]) : nothing
                theta_rad = deg2rad(Float64(get(el, "THETA", 0.0)))
                beta = shell_pcomp_material_rotation(
                    pcomp_axis_mode,
                    v1, v2, v3, p1, p2,
                    theta_rad,
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
                material_shear_rotation = beta
                if abs(beta) > 1e-10
                    cb = cos(beta); sb = sin(beta)
                    c2 = cb^2; s2 = sb^2; cs = cb*sb
                    _rotate_constitutive_3x3!(clt_Cm, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    if clt_Cb !== nothing
                        _rotate_constitutive_3x3!(clt_Cb, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    end
                end
            end
            try
                N, M, Q, s_z1, s_z2, e_z1, e_z2 = FEM.stress_strain_quad4(view(lc_buf,1:4,:), u_el, mat["E"], mat["NU"], Float64(prop["T"]), Float64(prop["T"]);
                    bend_ratio=br,
                    Cm_override=clt_Cm,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=membrane_shear_center_row,
                    material_shear_rotation=material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian)
                N_corners, M_corners = FEM.quad4_bilinear_corner_forces(view(lc_buf,1:4,:), u_el, mat["E"], mat["NU"], Float64(prop["T"]);
                    bend_ratio=br,
                    Cm_override=clt_Cm,
                    Cb_override=clt_Cb,
                    curvature_membrane=curvature_membrane,
                    membrane_shear_center_row=membrane_shear_center_row,
                    material_shear_rotation=material_shear_rotation,
                    membrane_incomp_center_jacobian=membrane_incomp_center_jacobian)
                Q_out = if clt_Cm === nothing && curvature_membrane === nothing && abs(br) > 1e-12
                    _quad4_blend_recovered_shear(Q, _quad4_equilibrium_shear_from_bending(view(lc_buf,1:4,:), M_corners))
                else
                    collect(Q)
                end
                # Nastran's bilinear shell-force output keeps twisting moment
                # constant across the QUAD4 corner rows.
                M_corners[:, 3] .= M[3]
                Q .= Q_out
                push!(quad4_bilin_rows, Dict(
                    "eid" => eid,
                    "grid_id" => "CEN/4",
                    "fx" => N[1], "fy" => N[2], "fxy" => N[3],
                    "mx" => M[1], "my" => M[2], "mxy" => M[3],
                    "qx" => Q_out[1], "qy" => Q_out[2],
                ))
                for k in 1:4
                    push!(quad4_bilin_rows, Dict(
                        "eid" => eid,
                        "grid_id" => nids[k],
                        "fx" => N_corners[k, 1], "fy" => N_corners[k, 2], "fxy" => N_corners[k, 3],
                        "mx" => M_corners[k, 1], "my" => M_corners[k, 2], "mxy" => M_corners[k, 3],
                        "qx" => Q_out[1], "qy" => Q_out[2],
                    ))
                end
            catch e
                @warn "Stress recovery failed for QUAD4 $eid: $e"
                stress_ok = false
            end
            elem_key = "quad4"
        elseif n==3
            i1, i2, i3 = id_map[nids[1]], id_map[nids[2]], id_map[nids[3]]
            p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
            p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
            p3 = SVector{3}(X[i3,1], X[i3,2], X[i3,3])
            p4=SVector(0.0,0.0,0.0)
            sr_indices = [i1, i2, i3]

            v1, v2, v3 = shell_element_frame_fast(p1, p2, p3, p4, 3)
            v1, v2, v3 = apply_snorm_to_frame(v1, v2, v3, sr_indices, snorm_normals)
            c = (p1+p2+p3)/3.0
            lc_buf[1,1]=dot(p1-c,v1); lc_buf[1,2]=dot(p1-c,v2)
            lc_buf[2,1]=dot(p2-c,v1); lc_buf[2,2]=dot(p2-c,v2)
            lc_buf[3,1]=dot(p3-c,v1); lc_buf[3,2]=dot(p3-c,v2)
            Rel_t = vcat(v1', v2', v3')
            u_el = zeros(18)
            for k=1:3
                idx = id_map[nids[k]]
                u_el[(k-1)*6+1:(k-1)*6+3] = Rel_t * node_R[idx] * u_global[(idx-1)*6+1:(idx-1)*6+3]
                u_el[(k-1)*6+4:(k-1)*6+6] = Rel_t * node_R[idx] * u_global[(idx-1)*6+4:(idx-1)*6+6]
            end
            br = get(prop, "BEND_RATIO", 1.0)
            clt_Cm = nothing
            clt_Cb = nothing
            if get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "Cm")
                clt_Cm = copy(prop["Cm"])
                clt_Cb = haskey(prop, "Cb") ? copy(prop["Cb"]) : nothing
                beta = shell_pcomp_material_rotation(
                    pcomp_axis_mode,
                    v1, v2, v3, p1, p2,
                    deg2rad(Float64(get(el, "THETA", 0.0))),
                    Int(get(el, "MCID", 0)),
                    model["CORDs"],
                )
                if abs(beta) > 1e-10
                    cb = cos(beta); sb = sin(beta)
                    c2 = cb^2; s2 = sb^2; cs = cb*sb
                    _rotate_constitutive_3x3!(clt_Cm, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    if clt_Cb !== nothing
                        _rotate_constitutive_3x3!(clt_Cb, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2-s2)
                    end
                end
            end
            try
                N, M, Q, s_z1, s_z2, e_z1, e_z2 = FEM.stress_strain_tria3(view(lc_buf,1:3,:), u_el, mat["E"], mat["NU"], Float64(prop["T"]); bend_ratio=br, Cm_override=clt_Cm)
                macro_weight = get(tria3_macro_blend, eid, 0.0)
                if macro_weight > 0.0 && clt_Cm === nothing && haskey(mat, "E") && haskey(mat, "NU")
                    _blend_tria3_macro_bending_iso!(
                        M, s_z1, s_z2, e_z1, e_z2,
                        view(lc_buf,1:3,:), u_el,
                        mat["E"], mat["NU"], Float64(prop["T"]),
                        Float64(br), macro_weight,
                    )
                end
            catch e
                @warn "Stress recovery failed for TRIA3 $eid: $e"
                stress_ok = false
            end
            elem_key = "tria3"
        else
            continue
        end

        if !stress_ok; continue; end

        eps_mem_out = (e_z1 .+ e_z2) ./ 2.0
        kappa_nast_out = (e_z1 .- e_z2) ./ prop["T"]

        is_pcomp = get(prop, "TYPE", "") == "PCOMP_CLT" && haskey(prop, "PLY_DATA")
        if is_pcomp
            t_total = prop["T"]
            eps_mem = (e_z1 .+ e_z2) ./ 2.0
            kappa = (e_z2 .- e_z1) ./ t_total
            Cm_eff = clt_Cm === nothing ? prop["Cm"] : clt_Cm
            Cb_eff = clt_Cb === nothing ? prop["Cb"] : clt_Cb
            N = Cm_eff * eps_mem
            M = -Cb_eff * kappa

            ply_data = prop["PLY_DATA"]
            vm_max = 0.0
            s_z1_out = zeros(3)
            s_z2_out = zeros(3)
            e_z1_out = zeros(3)
            e_z2_out = zeros(3)
            for (ip, pd) in enumerate(ply_data)
                Qbar = pd["Qbar"]
                z_mid = (pd["z_bot"] + pd["z_top"]) / 2.0
                strain_ply = eps_mem .+ z_mid .* kappa
                stress_ply = Qbar * strain_ply
                vm_ply = sqrt(stress_ply[1]^2 - stress_ply[1]*stress_ply[2] + stress_ply[2]^2 + 3*stress_ply[3]^2)
                if vm_ply > vm_max; vm_max = vm_ply; end
                if ip == 1; s_z1_out .= stress_ply; e_z1_out .= strain_ply; end
                if ip == length(ply_data); s_z2_out .= stress_ply; e_z2_out .= strain_ply; end
            end
            s_z1 = s_z1_out
            s_z2 = s_z2_out
            e_z1 = e_z1_out
            e_z2 = e_z2_out
            stresses[eid] = vm_max
        else
            stresses[eid] = FEM.compute_principal_2d(s_z1[1], s_z1[2], s_z1[3])[1]
        end

        push!(results_json["forces"][elem_key], Dict("eid" => eid, "fx" => N[1], "fy" => N[2], "fxy" => N[3], "mx" => M[1], "my" => M[2], "mxy" => M[3], "qx" => Q[1], "qy" => Q[2]))
        if elem_key == "quad4" && !isempty(quad4_bilin_rows)
            append!(results_json["forces_bilin"]["quad4"], quad4_bilin_rows)
        end

        make_stress_entry(s, t) = Dict("fiber_dist" => t, "normal_x" => s[1], "normal_y" => s[2], "shear_xy" => s[3], "von_mises" => sqrt(s[1]^2-s[1]*s[2]+s[2]^2+3*s[3]^2), "major" => 0.0, "minor" => 0.0)
        make_strain_entry(e, t) = Dict("fiber_dist" => t, "normal_x" => e[1], "normal_y" => e[2], "shear_xy" => e[3], "major" => 0.0, "minor" => 0.0)

        push!(results_json["stresses"][elem_key], Dict("eid" => eid, "z1" => make_stress_entry(s_z1, -prop["T"]/2), "z2" => make_stress_entry(s_z2, prop["T"]/2)))
        push!(results_json["strains"][elem_key], Dict("eid" => eid, "z1" => make_strain_entry(eps_mem_out, 0.0), "z2" => make_strain_entry(kappa_nast_out, -1.0)))
    end
end

@inline function _stress_beam_station_property_value(st::AbstractDict, prop::AbstractDict, field::AbstractString)
    fallback = field == "I1" ? get(prop, "I1", get(prop, "I", 0.0)) : get(prop, field, 0.0)
    return Float64(get(st, field, fallback))
end

function _stress_beam_sorted_stations(prop::AbstractDict)
    stations_raw = get(prop, "STATIONS", nothing)
    stations_raw isa AbstractVector || return Dict{String,Any}[]
    stations = Dict{String,Any}[]
    for st in stations_raw
        st isa AbstractDict || continue
        x = clamp(Float64(get(st, "X", 0.0)), 0.0, 1.0)
        push!(stations, Dict{String,Any}(string(k) => v for (k, v) in st))
        stations[end]["X"] = x
    end
    sort!(stations; by=s -> Float64(get(s, "X", 0.0)))
    unique_stations = Dict{String,Any}[]
    for st in stations
        if isempty(unique_stations) ||
           abs(Float64(get(st, "X", 0.0)) - Float64(get(last(unique_stations), "X", 0.0))) > 1e-10
            push!(unique_stations, st)
        else
            unique_stations[end] = st
        end
    end
    return unique_stations
end

function _stress_beam_station_properties_constant(prop::AbstractDict)
    stations = get(prop, "STATIONS", nothing)
    stations isa AbstractVector || return true
    length(stations) >= 2 || return true
    for field in ("A", "I1", "I2", "I12", "J")
        ref = _stress_beam_station_property_value(first(stations), prop, field)
        for st in stations
            val = _stress_beam_station_property_value(st, prop, field)
            abs(val - ref) <= 1e-10 * max(1.0, abs(ref), abs(val)) || return false
        end
        prop_val = field == "I1" ? Float64(get(prop, "I1", get(prop, "I", ref))) : Float64(get(prop, field, ref))
        abs(prop_val - ref) <= 1e-10 * max(1.0, abs(ref), abs(prop_val)) || return false
    end
    return true
end

function _stress_beam_station_section(st::AbstractDict, prop::AbstractDict)
    I1 = _stress_beam_station_property_value(st, prop, "I1")
    I2 = _stress_beam_station_property_value(st, prop, "I2")
    return (
        A = _stress_beam_station_property_value(st, prop, "A"),
        Iy = I2,
        Iz = I1,
        I12 = _stress_beam_station_property_value(st, prop, "I12"),
        J = _stress_beam_station_property_value(st, prop, "J"),
    )
end

function _stress_beam_recovery_points(prop::AbstractDict, station)
    value(field::AbstractString) = Float64(get(station isa AbstractDict ? station : prop, field, get(prop, field, 0.0)))
    return [
        (value("C1"), value("C2")),
        (value("D1"), value("D2")),
        (value("E1"), value("E2")),
        (value("F1"), value("F2")),
    ]
end

function _stress_beam_station_condensed_force_recovery(
    L::Float64,
    prop::AbstractDict,
    E::Float64,
    G::Float64,
    u_boundary_local::AbstractVector{<:Real},
)
    stations = _stress_beam_sorted_stations(prop)
    length(stations) >= 2 || return nothing
    first_x = Float64(get(first(stations), "X", 0.0))
    last_x = Float64(get(last(stations), "X", 0.0))
    first_x <= 1e-8 && last_x >= 1.0 - 1e-8 ||
        error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires stations spanning X=0.0 to X=1.0.")
    length(u_boundary_local) == 12 ||
        error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires a 12-DOF boundary displacement vector.")

    n = length(stations)
    nd = 6 * n
    K = zeros(Float64, nd, nd)
    segment_data = NamedTuple{(:dofs, :Ke),Tuple{Vector{Int},Matrix{Float64}}}[]
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))

    for s in 1:(n - 1)
        xa = Float64(get(stations[s], "X", 0.0))
        xb = Float64(get(stations[s + 1], "X", 1.0))
        seg_frac = xb - xa
        seg_frac > 1e-10 || continue
        segL = seg_frac * L
        sec_a = _stress_beam_station_section(stations[s], prop)
        sec_b = _stress_beam_station_section(stations[s + 1], prop)
        A = 0.5 * (sec_a.A + sec_b.A)
        Iy = 0.5 * (sec_a.Iy + sec_b.Iy)
        Iz = 0.5 * (sec_a.Iz + sec_b.Iz)
        I12 = 0.5 * (sec_a.I12 + sec_b.I12)
        J = 0.5 * (sec_a.J + sec_b.J)
        A > 0.0 || error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires positive segment area.")
        Iy >= 0.0 || error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires nonnegative segment I2/Iy.")
        Iz >= 0.0 || error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires nonnegative segment I1/Iz.")
        J >= 0.0 || error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations requires nonnegative segment J.")
        As_y = K1 > 0.0 ? K1 * A : Inf
        As_z = K2 > 0.0 ? K2 * A : Inf
        Ke_seg = Matrix{Float64}(FEM.stiffness_frame3d(segL, A, Iy, Iz, J, E, G; As_y=As_y, As_z=As_z, I12=I12))
        dofs = collect(vcat(((s - 1) * 6 + 1):(s * 6), (s * 6 + 1):((s + 1) * 6)))
        for c in 1:12, r in 1:12
            K[dofs[r], dofs[c]] += Ke_seg[r, c]
        end
        push!(segment_data, (dofs=dofs, Ke=Ke_seg))
    end
    isempty(segment_data) && return nothing

    boundary = vcat(1:6, (nd - 5):nd)
    T = zeros(Float64, nd, length(boundary))
    T[boundary, :] .= Matrix{Float64}(I, length(boundary), length(boundary))
    if nd > 12
        internal = collect(7:(nd - 6))
        T[internal, :] .= -(K[internal, internal] \ K[internal, boundary])
    end
    u_station = T * Float64.(u_boundary_local)

    first_seg = first(segment_data)
    last_seg = last(segment_data)
    f_first = first_seg.Ke * u_station[first_seg.dofs]
    f_last = last_seg.Ke * u_station[last_seg.dofs]
    f_local = zeros(Float64, 12)
    f_local[1:6] .= f_first[1:6]
    f_local[7:12] .= f_last[7:12]
    return (
        f_local = f_local,
        station_a = first(stations),
        station_b = last(stations),
        section_a = _stress_beam_station_section(first(stations), prop),
        section_b = _stress_beam_station_section(last(stations), prop),
    )
end

function recover_bar_stresses!(
    model,
    id_map,
    X,
    node_R,
    u_global,
    stresses,
    results_json;
    active_load_id=nothing,
    active_load_scale::Float64=1.0,
)
    @inline function frame_force_dict_from_local(f_local)
        return Dict(
            "axial" => f_local[7],
            "shear_1" => -f_local[2],
            "shear_2" => -f_local[3],
            "torque" => -f_local[4],
            "moment_a1" => -f_local[6],
            "moment_a2" => f_local[5],
            "moment_b1" => f_local[12],
            "moment_b2" => -f_local[11],
        )
    end

    @inline function surface_stress_sign(prop)
        section_type = uppercase(string(get(prop, "TYPE", "")))
        return section_type in ("ROD", "TUBE", "TUBE2") ? 1.0 : -1.0
    end

    @inline function recover_surface_stress(prop, m1, m2, yj, zj, Iy, Iz, I12_sr)
        sigma = if abs(Iz*Iy - I12_sr^2) > 1e-30
            ((m1*Iy - m2*I12_sr)*yj + (m2*Iz - m1*I12_sr)*zj) / (Iz*Iy - I12_sr^2)
        else
            m1*yj/max(Iz, 1e-30) + m2*zj/max(Iy, 1e-30)
        end
        return surface_stress_sign(prop) * sigma
    end

    for (id, bar) in model["CBARs"]
        eid = _stress_entry_public_id(id, bar)
        pid = string(bar["PID"])
        if !haskey(model["PBARLs"], pid); continue; end
        prop = model["PBARLs"][pid]
        mid = string(prop["MID"])
        if !haskey(model["MATs"], mid); continue; end

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
        p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, X)

        if norm(v_ref) < 1e-6
             v_ref = SVector(0.0,0.0,1.0)
             if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        TR1 = Rel_t * node_R[i1]
        TR2 = Rel_t * node_R[i2]
        u_el = zeros(12)
        u_el[1:3] = TR1 * u_global[(i1-1)*6+1:(i1-1)*6+3]
        u_el[4:6] = TR1 * u_global[(i1-1)*6+4:(i1-1)*6+6]
        u_el[7:9] = TR2 * u_global[(i2-1)*6+1:(i2-1)*6+3]
        u_el[10:12] = TR2 * u_global[(i2-1)*6+4:(i2-1)*6+6]
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            θ_glob_A = node_R[i1] * u_global[(i1-1)*6+4:(i1-1)*6+6]
            θ_glob_B = node_R[i2] * u_global[(i2-1)*6+4:(i2-1)*6+6]
            u_el[1:3] -= Rel_t * S_wa * θ_glob_A
            u_el[7:9] -= Rel_t * S_wb * θ_glob_B
        end

        pa = Int(get(bar, "PA", 0))
        pb = Int(get(bar, "PB", 0))
        fixed_end_load = _beam_pload1_local_load_vector_for_sid(
            model, eid, active_load_id, L, active_load_scale)

        station_recovery = nothing
        if !_stress_beam_station_properties_constant(prop)
            if has_offset || pa != 0 || pb != 0
                error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations with WA/WB offsets or PA/PB releases is not guarded yet.")
            end
            if norm(fixed_end_load) > 1e-12
                error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations with PLOAD1 fixed-end loads is not guarded yet.")
            end
            station_recovery = _stress_beam_station_condensed_force_recovery(
                Float64(L), prop, Float64(mat["E"]), Float64(mat["G"]), u_el)
        end

        if station_recovery === nothing
            Iy, Iz = _bar_bending_inertias(prop)
            Iyz = Float64(get(prop, "I12", 0.0))
            K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
            As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
            As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
            Ke_loc = FEM.stiffness_frame3d(L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
            if pa != 0 || pb != 0
                Ke_loc = Matrix(Ke_loc)
                apply_bar_pin_flags!(Ke_loc, pa, pb)
            end
            forces = frame_force_dict_from_local(Ke_loc * u_el - fixed_end_load)
            A_bar = Float64(prop["A"])
            section_a = (A=A_bar, Iy=Float64(Iy), Iz=Float64(Iz), I12=Float64(Iyz))
            section_b = section_a
            station_a = nothing
            station_b = nothing
        else
            forces = frame_force_dict_from_local(station_recovery.f_local)
            section_a = station_recovery.section_a
            section_b = station_recovery.section_b
            station_a = station_recovery.station_a
            station_b = station_recovery.station_b
        end

        sig_axial_a = (abs(section_a.A) > 1e-30) ? forces["axial"]/section_a.A : 0.0
        sig_axial_b = (abs(section_b.A) > 1e-30) ? forces["axial"]/section_b.A : 0.0
        sig_axial = abs(sig_axial_a) >= abs(sig_axial_b) ? sig_axial_a : sig_axial_b
        axial_strain = mat["E"] > 0 ? sig_axial / mat["E"] : 0.0
        axial_strain_a = mat["E"] > 0 ? sig_axial_a / mat["E"] : 0.0
        axial_strain_b = mat["E"] > 0 ? sig_axial_b / mat["E"] : 0.0
        stresses[eid] = abs(sig_axial)
        push!(results_json["forces"]["cbar"], Dict("eid" => eid, "axial" => forces["axial"], "shear_1" => forces["shear_1"], "shear_2" => forces["shear_2"], "torque" => forces["torque"], "moment_a1" => forces["moment_a1"], "moment_a2" => forces["moment_a2"], "moment_b1" => forces["moment_b1"], "moment_b2" => forces["moment_b2"]))

        end_a = Dict{String,Float64}()
        end_b = Dict{String,Float64}()
        for (j, (yj, zj)) in enumerate(_stress_beam_recovery_points(prop, station_a))
            end_a["p$j"] = recover_surface_stress(prop, forces["moment_a1"], forces["moment_a2"], yj, zj, section_a.Iy, section_a.Iz, section_a.I12)
        end
        for (j, (yj, zj)) in enumerate(_stress_beam_recovery_points(prop, station_b))
            end_b["p$j"] = recover_surface_stress(prop, forces["moment_b1"], forces["moment_b2"], yj, zj, section_b.Iy, section_b.Iz, section_b.I12)
        end
        stress_entry = Dict("eid"=>eid, "end_a"=>end_a, "end_b"=>end_b, "axial"=>sig_axial)
        strain_entry = Dict("eid"=>eid, "axial"=>axial_strain)
        if station_recovery !== nothing
            stress_entry["axial_end_a"] = sig_axial_a
            stress_entry["axial_end_b"] = sig_axial_b
            strain_entry["axial_end_a"] = axial_strain_a
            strain_entry["axial_end_b"] = axial_strain_b
        end
        push!(results_json["stresses"]["cbar"], stress_entry)
        push!(results_json["strains"]["cbar"], strain_entry)
    end

    # --- CBEAMs (identical recovery to CBAR) ---
    for (id, bar) in get(model, "CBEAMs", Dict())
        eid = _stress_entry_public_id(id, bar)
        pid = string(bar["PID"])
        if !haskey(model["PBARLs"], pid); continue; end
        prop = model["PBARLs"][pid]
        mid = string(prop["MID"])
        if !haskey(model["MATs"], mid); continue; end

        if !haskey(id_map, bar["GA"]) || !haskey(id_map, bar["GB"]); continue; end
        i1, i2 = id_map[bar["GA"]], id_map[bar["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [bar["GA"], bar["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
        p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])

        wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(bar, p1, p2)
        L = norm(p2_eff - p1_eff)
        if L < 1e-9; continue; end
        vx = normalize(p2_eff - p1_eff)
        v_ref = resolve_bar_vref(bar, p1, id_map, X)

        if norm(v_ref) < 1e-6
             v_ref = SVector(0.0,0.0,1.0)
             if abs(dot(vx, v_ref)) > 0.9; v_ref = SVector(0.0,1.0,0.0); end
        end
        vz = normalize(cross(vx, v_ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        TR1 = Rel_t * node_R[i1]
        TR2 = Rel_t * node_R[i2]
        u_el = zeros(12)
        u_el[1:3] = TR1 * u_global[(i1-1)*6+1:(i1-1)*6+3]
        u_el[4:6] = TR1 * u_global[(i1-1)*6+4:(i1-1)*6+6]
        u_el[7:9] = TR2 * u_global[(i2-1)*6+1:(i2-1)*6+3]
        u_el[10:12] = TR2 * u_global[(i2-1)*6+4:(i2-1)*6+6]
        if has_offset
            S_wa = skew3(wa); S_wb = skew3(wb)
            θ_glob_A = node_R[i1] * u_global[(i1-1)*6+4:(i1-1)*6+6]
            θ_glob_B = node_R[i2] * u_global[(i2-1)*6+4:(i2-1)*6+6]
            u_el[1:3] -= Rel_t * S_wa * θ_glob_A
            u_el[7:9] -= Rel_t * S_wb * θ_glob_B
        end

        pa = Int(get(bar, "PA", 0))
        pb = Int(get(bar, "PB", 0))
        fixed_end_load = _beam_pload1_local_load_vector_for_sid(
            model, eid, active_load_id, L, active_load_scale)

        station_recovery = nothing
        if !_stress_beam_station_properties_constant(prop)
            if has_offset || pa != 0 || pb != 0
                error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations with WA/WB offsets or PA/PB releases is not guarded yet.")
            end
            if norm(fixed_end_load) > 1e-12
                error("SOL101 beam stress recovery for varying PBEAM/PBEAML stations with PLOAD1 fixed-end loads is not guarded yet.")
            end
            station_recovery = _stress_beam_station_condensed_force_recovery(
                Float64(L), prop, Float64(mat["E"]), Float64(mat["G"]), u_el)
        end

        if station_recovery === nothing
            Iy, Iz = _bar_bending_inertias(prop)
            Iyz = Float64(get(prop, "I12", 0.0))
            K1 = get(prop, "K1", 0.0); K2 = get(prop, "K2", 0.0)
            As_y = (K1 > 0.0) ? K1 * prop["A"] : Inf
            As_z = (K2 > 0.0) ? K2 * prop["A"] : Inf
            Ke_loc = FEM.stiffness_frame3d(L, prop["A"], Iy, Iz, prop["J"], mat["E"], mat["G"]; As_y=As_y, As_z=As_z, I12=Iyz)
            if pa != 0 || pb != 0
                Ke_loc = Matrix(Ke_loc)
                apply_bar_pin_flags!(Ke_loc, pa, pb)
            end
            forces = frame_force_dict_from_local(Ke_loc * u_el - fixed_end_load)
            A_bar = Float64(prop["A"])
            section_a = (A=A_bar, Iy=Float64(Iy), Iz=Float64(Iz), I12=Float64(Iyz))
            section_b = section_a
            station_a = nothing
            station_b = nothing
        else
            forces = frame_force_dict_from_local(station_recovery.f_local)
            section_a = station_recovery.section_a
            section_b = station_recovery.section_b
            station_a = station_recovery.station_a
            station_b = station_recovery.station_b
        end

        sig_axial_a = (abs(section_a.A) > 1e-30) ? forces["axial"]/section_a.A : 0.0
        sig_axial_b = (abs(section_b.A) > 1e-30) ? forces["axial"]/section_b.A : 0.0
        sig_axial = abs(sig_axial_a) >= abs(sig_axial_b) ? sig_axial_a : sig_axial_b
        axial_strain = mat["E"] > 0 ? sig_axial / mat["E"] : 0.0
        axial_strain_a = mat["E"] > 0 ? sig_axial_a / mat["E"] : 0.0
        axial_strain_b = mat["E"] > 0 ? sig_axial_b / mat["E"] : 0.0
        stresses[eid] = abs(sig_axial)
        push!(results_json["forces"]["cbar"], Dict("eid" => eid, "axial" => forces["axial"], "shear_1" => forces["shear_1"], "shear_2" => forces["shear_2"], "torque" => forces["torque"], "moment_a1" => forces["moment_a1"], "moment_a2" => forces["moment_a2"], "moment_b1" => forces["moment_b1"], "moment_b2" => forces["moment_b2"]))

        end_a = Dict{String,Float64}()
        end_b = Dict{String,Float64}()
        for (j, (yj, zj)) in enumerate(_stress_beam_recovery_points(prop, station_a))
            end_a["p$j"] = recover_surface_stress(prop, forces["moment_a1"], forces["moment_a2"], yj, zj, section_a.Iy, section_a.Iz, section_a.I12)
        end
        for (j, (yj, zj)) in enumerate(_stress_beam_recovery_points(prop, station_b))
            end_b["p$j"] = recover_surface_stress(prop, forces["moment_b1"], forces["moment_b2"], yj, zj, section_b.Iy, section_b.Iz, section_b.I12)
        end
        stress_entry = Dict("eid"=>eid, "end_a"=>end_a, "end_b"=>end_b, "axial"=>sig_axial)
        strain_entry = Dict("eid"=>eid, "axial"=>axial_strain)
        if station_recovery !== nothing
            stress_entry["axial_end_a"] = sig_axial_a
            stress_entry["axial_end_b"] = sig_axial_b
            strain_entry["axial_end_a"] = axial_strain_a
            strain_entry["axial_end_b"] = axial_strain_b
        end
        push!(results_json["stresses"]["cbar"], stress_entry)
        push!(results_json["strains"]["cbar"], strain_entry)
    end
end

function recover_rod_stresses!(model, id_map, X, node_R, u_global, stresses, results_json)
    # CROD recovery
    crods = get(model, "CRODs", Dict())
    prods = get(model, "PRODs", Dict())
    for (id, rod) in crods
        eid = _stress_entry_public_id(id, rod)
        pid = string(rod["PID"])
        if !haskey(prods, pid); continue; end
        prop = prods[pid]
        mid = string(prop["MID"])
        if !haskey(model["MATs"], mid); continue; end

        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])
        mat === nothing && continue

        p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
        p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)
        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')

        u_el = zeros(12)
        u_el[1:3] = Rel_t * node_R[i1] * u_global[(i1-1)*6+1:(i1-1)*6+3]
        u_el[4:6] = Rel_t * node_R[i1] * u_global[(i1-1)*6+4:(i1-1)*6+6]
        u_el[7:9] = Rel_t * node_R[i2] * u_global[(i2-1)*6+1:(i2-1)*6+3]
        u_el[10:12] = Rel_t * node_R[i2] * u_global[(i2-1)*6+4:(i2-1)*6+6]

        axial_force = mat["E"] * prop["A"] / L * (u_el[7] - u_el[1])
        torque = mat["G"] * prop["J"] / L * (u_el[10] - u_el[4])
        axial_stress = prop["A"] > 0 ? axial_force / prop["A"] : 0.0
        torsional_stress = prop["J"] > 0 && haskey(prop, "C") && prop["C"] > 0 ? torque * prop["C"] / prop["J"] : 0.0
        stresses[eid] = abs(axial_stress)
        axial_strain = mat["E"] > 0 ? axial_stress / mat["E"] : 0.0
        push!(results_json["forces"]["crod"], Dict("eid" => eid, "axial" => axial_force, "torque" => torque))
        push!(results_json["stresses"]["crod"], Dict("eid" => eid, "axial" => axial_stress, "torsional" => torsional_stress))
        push!(results_json["strains"]["crod"], Dict("eid" => eid, "axial" => axial_strain, "torsional" => mat["G"] > 0 ? torsional_stress / mat["G"] : 0.0))
    end

    # CONROD recovery
    conrods = get(model, "CONRODs", Dict())
    for (id, rod) in conrods
        eid = _stress_entry_public_id(id, rod)
        mid = string(rod["MID"])
        if !haskey(model["MATs"], mid); continue; end
        if !haskey(id_map, rod["GA"]) || !haskey(id_map, rod["GB"]); continue; end
        i1, i2 = id_map[rod["GA"]], id_map[rod["GB"]]
        mat = _effective_mat1_for_nodes(model, mid, [rod["GA"], rod["GB"]])
        mat === nothing && continue
        p1 = SVector{3}(X[i1,1], X[i1,2], X[i1,3])
        p2 = SVector{3}(X[i2,1], X[i2,2], X[i2,3])
        L = norm(p2-p1)
        if L < 1e-9; continue; end
        vx = normalize(p2-p1)
        ref = abs(vx[3]) < 0.9 ? SVector(0.0,0.0,1.0) : SVector(0.0,1.0,0.0)
        vz = normalize(cross(vx, ref))
        vy = cross(vz, vx)
        Rel_t = vcat(vx', vy', vz')
        u_el = zeros(12)
        u_el[1:3] = Rel_t * node_R[i1] * u_global[(i1-1)*6+1:(i1-1)*6+3]
        u_el[4:6] = Rel_t * node_R[i1] * u_global[(i1-1)*6+4:(i1-1)*6+6]
        u_el[7:9] = Rel_t * node_R[i2] * u_global[(i2-1)*6+1:(i2-1)*6+3]
        u_el[10:12] = Rel_t * node_R[i2] * u_global[(i2-1)*6+4:(i2-1)*6+6]
        axial_force = mat["E"] * rod["A"] / L * (u_el[7] - u_el[1])
        torque = mat["G"] * rod["J"] / L * (u_el[10] - u_el[4])
        axial_stress = rod["A"] > 0 ? axial_force / rod["A"] : 0.0
        torsional_stress = rod["J"] > 0 && rod["C"] > 0 ? torque * rod["C"] / rod["J"] : 0.0
        stresses[eid] = abs(axial_stress)
        axial_strain = mat["E"] > 0 ? axial_stress / mat["E"] : 0.0
        push!(results_json["forces"]["conrod"], Dict("eid" => eid, "axial" => axial_force, "torque" => torque))
        push!(results_json["stresses"]["conrod"], Dict("eid" => eid, "axial" => axial_stress, "torsional" => torsional_stress))
        push!(results_json["strains"]["conrod"], Dict("eid" => eid, "axial" => axial_strain, "torsional" => mat["G"] > 0 ? torsional_stress / mat["G"] : 0.0))
    end
end

function recover_spring_forces!(model, id_map, u_global, stresses, results_json)
    celases = get(model, "CELASs", Dict())
    pelases = get(model, "PELASs", Dict())
    for (id, spring) in celases
        eid = _stress_entry_public_id(id, spring)
        if get(spring, "TYPE", "CELAS1") == "CELAS2"
            K_spring = Float64(get(spring, "K", 0.0))
        else
            pid = string(get(spring, "PID", 0))
            if !haskey(pelases, pid); continue; end
            K_spring = Float64(pelases[pid]["K"])
        end
        g1 = spring["G1"]; c1 = spring["C1"]
        g2 = spring["G2"]; c2 = spring["C2"]
        u1 = 0.0; u2 = 0.0
        if g1 > 0 && haskey(id_map, g1) && c1 > 0
            u1 = u_global[(id_map[g1]-1)*6 + c1]
        end
        if g2 > 0 && haskey(id_map, g2) && c2 > 0
            u2 = u_global[(id_map[g2]-1)*6 + c2]
        end
        spring_force = K_spring * (u1 - u2)
        stresses[eid] = abs(spring_force)
        push!(results_json["forces"]["celas1"], Dict("eid" => eid, "force" => spring_force))
        push!(results_json["stresses"]["celas1"], Dict("eid" => eid, "force" => spring_force))
        push!(results_json["strains"]["celas1"], Dict("eid" => eid, "deformation" => u1 - u2))
    end
end

function recover_solid_stresses!(model, id_map, X, node_R, u_global, stresses, results_json)
    csolids = get(model, "CSOLIDs", Dict())
    psolids = get(model, "PSOLIDs", Dict())
    mats = model["MATs"]
    coords_buf = zeros(8, 3)

    for (id, el) in csolids
        eid = _stress_entry_public_id(id, el)
        pid = string(el["PID"])
        if !haskey(psolids, pid); continue; end
        prop = psolids[pid]
        nids = el["NODES"]
        nn = length(nids)
        mid = string(prop["MID"])
        if !haskey(mats, mid); continue; end
        mat = _effective_mat1_for_nodes(model, mid, nids)
        etype = get(el, "TYPE", "")

        valid = true
        for k in 1:nn
            if !haskey(id_map, nids[k]); valid = false; break; end
        end
        if !valid; continue; end

        # Gather coordinates
        for k in 1:nn
            idx = id_map[nids[k]]
            coords_buf[k,1] = X[idx,1]; coords_buf[k,2] = X[idx,2]; coords_buf[k,3] = X[idx,3]
        end

        # Extract element displacements (translational DOFs only, in global coords)
        ndof_el = nn * 3
        u_el = zeros(ndof_el)
        for k in 1:nn
            idx = id_map[nids[k]]
            u_local = u_global[(idx-1)*6+1:(idx-1)*6+3]
            u_glob = node_R[idx] * u_local
            u_el[(k-1)*3+1:(k-1)*3+3] = u_glob
        end

        E_mat = Float64(mat["E"]); nu_mat = Float64(mat["NU"])
        D = FEM.iso_3d_constitutive(E_mat, nu_mat)

        # Compute B at centroid and recover stress
        local B_cen
        local elem_key::String
        if etype == "CTETRA" && nn == 4
            B_cen = FEM.solid_centroid_B_tetra4(view(coords_buf, 1:4, :))
            elem_key = "ctetra"
        elseif etype == "CHEXA" && nn == 8
            B_cen = FEM.solid_centroid_B_hexa8(view(coords_buf, 1:8, :))
            elem_key = "chexa"
        elseif etype == "CPENTA" && nn == 6
            B_cen = FEM.solid_centroid_B_cpenta6(view(coords_buf, 1:6, :))
            elem_key = "cpenta"
        else
            continue
        end

        stress_vec, strain_vec, vm = FEM.stress_solid_3d(B_cen, D, u_el)
        stresses[eid] = vm

        # Corner stress recovery for CHEXA8 (at 8 corner nodes)
        corner_stresses = []
        if etype == "CHEXA" && nn == 8
            xi_corners  = [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
            eta_corners = [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
            zet_corners = [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]
            xi_n  = [-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0,-1.0]
            eta_n = [-1.0,-1.0, 1.0, 1.0,-1.0,-1.0, 1.0, 1.0]
            zet_n = [-1.0,-1.0,-1.0,-1.0, 1.0, 1.0, 1.0, 1.0]
            coords_view = view(coords_buf, 1:8, :)
            for ci in 1:8
                xi = xi_corners[ci]; eta = eta_corners[ci]; zet = zet_corners[ci]
                dN_dxi = zeros(3, 8)
                for i in 1:8
                    dN_dxi[1,i] = 0.125*xi_n[i]*(1+eta_n[i]*eta)*(1+zet_n[i]*zet)
                    dN_dxi[2,i] = 0.125*eta_n[i]*(1+xi_n[i]*xi)*(1+zet_n[i]*zet)
                    dN_dxi[3,i] = 0.125*zet_n[i]*(1+xi_n[i]*xi)*(1+eta_n[i]*eta)
                end
                J = dN_dxi * coords_view
                if abs(det(J)) < 1e-30; continue; end
                dN_dx = inv(J) * dN_dxi
                B_corner = zeros(6, 24)
                for i in 1:8
                    c = (i-1)*3
                    dx=dN_dx[1,i]; dy=dN_dx[2,i]; dz=dN_dx[3,i]
                    B_corner[1,c+1]=dx; B_corner[2,c+2]=dy; B_corner[3,c+3]=dz
                    B_corner[4,c+1]=dy; B_corner[4,c+2]=dx
                    B_corner[5,c+2]=dz; B_corner[5,c+3]=dy
                    B_corner[6,c+1]=dz; B_corner[6,c+3]=dx
                end
                s_c, _, vm_c = FEM.stress_solid_3d(B_corner, D, u_el)
                push!(corner_stresses, Dict("grid"=>nids[ci], "sxx"=>s_c[1],"syy"=>s_c[2],"szz"=>s_c[3],
                    "txy"=>s_c[4],"tyz"=>s_c[5],"tzx"=>s_c[6],"von_mises"=>vm_c))
            end
        end

        stress_entry = Dict{String,Any}(
            "eid" => eid,
            "sxx" => stress_vec[1], "syy" => stress_vec[2], "szz" => stress_vec[3],
            "txy" => stress_vec[4], "tyz" => stress_vec[5], "tzx" => stress_vec[6],
            "von_mises" => vm
        )
        if !isempty(corner_stresses); stress_entry["corners"] = corner_stresses; end
        push!(results_json["stresses"][elem_key], stress_entry)
        push!(results_json["strains"][elem_key], Dict(
            "eid" => eid,
            "exx" => strain_vec[1], "eyy" => strain_vec[2], "ezz" => strain_vec[3],
            "gxy" => strain_vec[4], "gyz" => strain_vec[5], "gzx" => strain_vec[6]
        ))
    end
end
