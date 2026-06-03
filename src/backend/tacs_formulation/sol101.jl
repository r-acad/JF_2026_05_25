# sol101.jl -- first residual-first TACS-formulation vertical slice.
#
# Scope:
#   SOL101/SOL103/SOL105/SOL106, CQUAD4/CQUADR/CTRIA3 shell models with PSHELL/MAT1 or PCOMP_CLT
#   properties.  The element residual is R_e = K_e u_e and the tangent is K_e.
#   This file deliberately avoids the Nastran-parity assembly switchboard;
#   unsupported model features fail fast so future TACS slices are added
#   explicitly.

using LinearAlgebra
using SparseArrays
using StaticArrays

function _tacs_get(model::AbstractDict, key::AbstractString, default)
    return get(model, key, default)
end

function _tacs_nonempty_group(model::AbstractDict, key::AbstractString)::Bool
    value = get(model, key, nothing)
    value === nothing && return false
    value isa AbstractDict && return !isempty(value)
    value isa AbstractVector && return !isempty(value)
    return false
end

function _tacs_route_label(route_label::AbstractString, allowed_sol_types)
    return isempty(route_label) ? "SOL $(join(allowed_sol_types, "/"))" : route_label
end

function _tacs_validate_shell_slice(model::Dict; allowed_sol_types=(101,), route_label="")
    label = _tacs_route_label(route_label, allowed_sol_types)
    raw_sol_type = get(model, "SOL", get(get(model, "CASE_CONTROL", Dict()), "SOL", 101))
    sol_type = _canonical_sol_type(raw_sol_type)
    sol_type in allowed_sol_types ||
        error("TACS-formulation backend $label route does not support SOL $sol_type.")

    unsupported_groups = String[]
    for key in ("CBARs", "CBEAMs", "CRODs", "CONRODs", "CSOLIDs", "CSHEARs",
                "CELAS1s", "CELAS2s", "CBUSHs", "CONM2s", "CONM1s",
                "CMASS1s", "CMASS2s", "PMASSs", "RBE1s", "RBE2s", "RBE3s",
                "RBARs", "RSPLINEs", "MPCs")
        _tacs_nonempty_group(model, key) && push!(unsupported_groups, key)
    end
    isempty(unsupported_groups) ||
        error("TACS-formulation $label slice supports only CQUAD4/CQUADR/CTRIA3 shell models; unsupported groups present: $(join(unsupported_groups, ", ")).")

    cshells = get(model, "CSHELLs", Dict())
    isempty(cshells) && error("TACS-formulation $label slice requires at least one CQUAD4, CQUADR, or CTRIA3 element.")
    for (eid, el) in cshells
        nids = get(el, "NODES", Any[])
        length(nids) in (3, 4) || error("TACS-formulation $label slice supports CQUAD4/CQUADR/CTRIA3 only; element $eid has $(length(nids)) nodes.")
        pid = string(Int(get(el, "PID", 0)))
        prop = get(get(model, "PSHELLs", Dict()), pid, nothing)
        prop === nothing && error("TACS-formulation $label element $eid references missing shell property $pid.")
        prop_type = uppercase(string(get(prop, "TYPE", "PSHELL")))
        if prop_type == "PSHELL"
            mid = string(Int(get(prop, "MID", 0)))
            mat = get(get(model, "MATs", Dict()), mid, nothing)
            mat === nothing && error("TACS-formulation $label property $pid references missing MAT1 $mid.")
            uppercase(string(get(mat, "TYPE", "MAT1"))) in ("MAT1", "") ||
                error("TACS-formulation $label PSHELL property $pid supports MAT1 only; material $mid has TYPE=$(get(mat, "TYPE", "?"))")
        elseif prop_type == "PCOMP_CLT"
            for key in ("Cm", "Cb", "Cs", "E_ref")
                haskey(prop, key) || error("TACS-formulation $label PCOMP_CLT property $pid is missing CLT field '$key'.")
            end
            get(prop, "T", 0.0) > 0.0 || error("TACS-formulation $label PCOMP_CLT property $pid must have positive total thickness.")
        else
            error("TACS-formulation $label slice supports PSHELL/MAT1 and PCOMP_CLT only; property $pid has TYPE=$(get(prop, "TYPE", "?"))")
        end
    end
    return nothing
end

function _tacs_validate_sol101_slice(model::Dict)
    return _tacs_validate_shell_slice(model; allowed_sol_types=(101,), route_label="SOL101")
end

function _tacs_node_tables(model::Dict)
    ids = sort(collect(keys(model["GRIDs"])), by=x -> parse(Int, string(x)))
    n_nodes = length(ids)
    id_map = Dict(parse(Int, string(k)) => i for (i, k) in enumerate(ids))
    node_R = Vector{Matrix{Float64}}(undef, n_nodes)
    X = zeros(Float64, n_nodes, 3)
    for (_, g) in model["GRIDs"]
        gid = Int(g["ID"])
        idx = id_map[gid]
        X[idx, :] .= Float64.(g["X"])
        cid = Int(get(g, "CD", 0))
        if cid == 0
            node_R[idx] = Matrix{Float64}(I, 3, 3)
        else
            cord = get(get(model, "CORDs", Dict()), string(cid), nothing)
            node_R[idx] = cord === nothing ? Matrix{Float64}(I, 3, 3) :
                Solver._node_dof_rotation(cord, g["X"])
        end
    end
    return id_map, X, n_nodes * 6, node_R
end

function _tacs_mat1_pshell_constitutive(prop::AbstractDict, mat::AbstractDict)
    h = get(prop, "T", 0.0)
    h > 0.0 || error("TACS-formulation PSHELL thickness must be positive.")
    E = Float64(get(mat, "E", 0.0))
    nu = Float64(get(mat, "NU", 0.0))
    G = Float64(get(mat, "G", E / (2.0 * (1.0 + nu))))
    E > 0.0 || error("TACS-formulation MAT1 E must be positive.")
    G > 0.0 || error("TACS-formulation MAT1 G must be positive.")

    q = E / max(1.0 - nu^2, 1e-30)
    Q = q .* [1.0 nu 0.0; nu 1.0 0.0; 0.0 0.0 (1.0 - nu) / 2.0]
    Cm = h .* Q
    Cb = (h^3 / 12.0) .* Q
    ts_t = Float64(get(prop, "TS_T", 5.0 / 6.0))
    Cs = (ts_t * h * G) .* Matrix{Float64}(I, 2, 2)
    return Cm, Cb, Cs, h, E
end

function _tacs_mat1_pshell_thickness_partials(prop::AbstractDict, mat::AbstractDict)
    h = Float64(get(prop, "T", 0.0))
    h > 0.0 || error("TACS-formulation PSHELL thickness must be positive.")
    E = Float64(get(mat, "E", 0.0))
    nu = Float64(get(mat, "NU", 0.0))
    G = Float64(get(mat, "G", E / (2.0 * (1.0 + nu))))
    E > 0.0 || error("TACS-formulation MAT1 E must be positive.")
    G > 0.0 || error("TACS-formulation MAT1 G must be positive.")

    q = E / max(1.0 - nu^2, 1e-30)
    Q = q .* [1.0 nu 0.0; nu 1.0 0.0; 0.0 0.0 (1.0 - nu) / 2.0]
    dCm = Q
    dCb = (h^2 / 4.0) .* Q
    ts_t = Float64(get(prop, "TS_T", 5.0 / 6.0))
    dCs = (ts_t * G) .* Matrix{Float64}(I, 2, 2)
    return dCm, dCb, dCs, h, E
end

function _tacs_ensure_pcomp_reference!(prop::AbstractDict)
    uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PCOMP_CLT" || return prop
    haskey(prop, "T_REF") || (prop["T_REF"] = Float64(get(prop, "T", 0.0)))
    haskey(prop, "Cm_ref") || (prop["Cm_ref"] = Matrix{Float64}(prop["Cm"]))
    haskey(prop, "Cb_ref") || (prop["Cb_ref"] = Matrix{Float64}(prop["Cb"]))
    haskey(prop, "Cs_ref") || (prop["Cs_ref"] = Matrix{Float64}(prop["Cs"]))
    if !haskey(prop, "Bmb_ref")
        Bmb = get(prop, "Bmb", nothing)
        prop["Bmb_ref"] = Bmb === nothing ? nothing : Matrix{Float64}(Bmb)
    end
    return prop
end

function _tacs_shell_constitutive(model::Dict, prop::AbstractDict, el::AbstractDict)
    prop_type = uppercase(string(get(prop, "TYPE", "PSHELL")))
    if prop_type == "PCOMP_CLT"
        _tacs_ensure_pcomp_reference!(prop)
        h = prop["T"]
        href = Float64(get(prop, "T_REF", h))
        href > 0.0 || error("TACS-formulation PCOMP_CLT reference thickness must be positive.")
        ratio = h / href
        ratio > 0.0 || error("TACS-formulation PCOMP_CLT thickness must be positive.")
        Cm = ratio .* Matrix{Float64}(prop["Cm_ref"])
        Cb = ratio^3 .* Matrix{Float64}(prop["Cb_ref"])
        Cs = ratio .* Matrix{Float64}(prop["Cs_ref"])
        Bmb = get(prop, "Bmb_ref", get(prop, "Bmb", nothing))
        Bmb_local = Bmb === nothing ? nothing : ratio^2 .* Matrix{Float64}(Bmb)
        Eref =
            if haskey(prop, "E_ref")
                Float64(prop["E_ref"])
            else
                maximum(abs.(Matrix{Float64}(prop["Cm_ref"]))) / max(Float64(get(prop, "T_REF", 1.0)), 1e-30)
            end
        Eref > 0.0 || (Eref = 1.0)

        beta = deg2rad(Float64(get(el, "THETA", 0.0)))
        if abs(beta) > 1e-12
            FEM.rotate_constitutive_3x3!(Cm, beta)
            FEM.rotate_constitutive_3x3!(Cb, beta)
            FEM.rotate_constitutive_2x2!(Cs, beta)
            Bmb_local !== nothing && FEM.rotate_constitutive_3x3!(Bmb_local, beta)
        end
        return Cm, Cb, Cs, h, Eref, Bmb_local
    end

    mat = model["MATs"][string(Int(prop["MID"]))]
    Cm, Cb, Cs, h, Eref = _tacs_mat1_pshell_constitutive(prop, mat)
    return Cm, Cb, Cs, h, Eref, nothing
end

function _tacs_shell_supports_thickness_derivative(prop::AbstractDict)::Bool
    return uppercase(string(get(prop, "TYPE", "PSHELL"))) in ("PSHELL", "PCOMP_CLT")
end

function _tacs_quad4_local_geometry(p1, p2, p3, p4)
    v1, v2, v3 = Solver.shell_element_frame_quad4(p1, p2, p3, p4, :diag)
    center = 0.25 .* (p1 .+ p2 .+ p3 .+ p4)
    lc = zeros(Float64, 4, 2)
    for (i, p) in enumerate((p1, p2, p3, p4))
        d = p - center
        lc[i, 1] = dot(d, v1)
        lc[i, 2] = dot(d, v2)
    end
    return lc, v1, v2, v3
end

function _tacs_quad4_transform(node_indices, v1, v2, v3, node_R)
    T = zeros(Float64, 24, 24)
    for k in 1:4
        idx = node_indices[k]
        base = (k - 1) * 6
        Rel = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]
        Rn = node_R[idx]
        for rr in 1:3, cc in 1:3
            val = Rel[rr, 1] * Rn[1, cc] + Rel[rr, 2] * Rn[2, cc] + Rel[rr, 3] * Rn[3, cc]
            T[base + rr, base + cc] = val
            T[base + 3 + rr, base + 3 + cc] = val
        end
    end
    return T
end

function _tacs_tria3_local_geometry(p1, p2, p3)
    v1, v2, v3 = Solver.shell_element_frame_fast(p1, p2, p3, SVector{3,Float64}(0.0, 0.0, 0.0), 3)
    center = (p1 .+ p2 .+ p3) ./ 3.0
    lc = zeros(Float64, 3, 2)
    for (i, p) in enumerate((p1, p2, p3))
        d = p - center
        lc[i, 1] = dot(d, v1)
        lc[i, 2] = dot(d, v2)
    end
    return lc, v1, v2, v3
end

function _tacs_shell_transform(node_indices, v1, v2, v3, node_R)
    n = length(node_indices)
    T = zeros(Float64, 6n, 6n)
    Rel = @SMatrix [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]
    for k in 1:n
        idx = node_indices[k]
        base = (k - 1) * 6
        Rn = node_R[idx]
        TR = Rel * Rn
        for rr in 1:3, cc in 1:3
            T[base + rr, base + cc] = TR[rr, cc]
            T[base + 3 + rr, base + 3 + cc] = TR[rr, cc]
        end
    end
    return T
end

function _tacs_shell_dofs(idxs)
    n = length(idxs)
    dofs = Vector{Int}(undef, 6n)
    for k in 1:n
        base_global = (idxs[k] - 1) * 6
        for d in 1:6
            dofs[(k - 1) * 6 + d] = base_global + d
        end
    end
    return dofs
end

function _tacs_quad4_shell_operator(model::Dict, el::AbstractDict, id_map, X, node_R)
    nids = Int.(el["NODES"])
    idxs = [id_map[nid] for nid in nids]
    ps = [SVector{3,Float64}(X[idx, 1], X[idx, 2], X[idx, 3]) for idx in idxs]
    lc, v1, v2, v3 = _tacs_quad4_local_geometry(ps[1], ps[2], ps[3], ps[4])
    prop = model["PSHELLs"][string(Int(el["PID"]))]
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, prop, el)
    Ke_local = FEM.stiffness_quad4_matrices(
        lc, Cm, Cb, Cs, h, Eref;
        Bmb=Bmb,
        k6rot=1.0,
        membrane_incomp=false,
        bending_incomp=false,
        shear_center_only=false,
        selective_shear=true,
        macneal_rigid_shear=false,
    )
    T = _tacs_quad4_transform(idxs, v1, v2, v3, node_R)
    Ke = transpose(T) * Ke_local * T
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    dofs = Vector{Int}(undef, 24)
    for k in 1:4
        base_global = (idxs[k] - 1) * 6
        for d in 1:6
            dofs[(k - 1) * 6 + d] = base_global + d
        end
    end
    return Ke, dofs
end

function _tacs_tria3_shell_operator(model::Dict, el::AbstractDict, id_map, X, node_R)
    nids = Int.(el["NODES"])
    idxs = [id_map[nid] for nid in nids]
    ps = [SVector{3,Float64}(X[idx, 1], X[idx, 2], X[idx, 3]) for idx in idxs]
    lc, v1, v2, v3 = _tacs_tria3_local_geometry(ps[1], ps[2], ps[3])
    prop = model["PSHELLs"][string(Int(el["PID"]))]
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, prop, el)
    Ke_local = FEM.stiffness_tria3_matrices(
        lc, Cm, Cb, Cs, h, Eref;
        bend_ratio=1.0,
        k6rot=1.0,
        Bmb=Bmb,
    )
    T = _tacs_shell_transform(idxs, v1, v2, v3, node_R)
    Ke = transpose(T) * Ke_local * T
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    return Ke, _tacs_shell_dofs(idxs)
end

function _tacs_shell_residual_tangent(model::Dict, el::AbstractDict, id_map, X, node_R)
    n = length(get(el, "NODES", Any[]))
    n == 4 && return _tacs_quad4_shell_residual_tangent(model, el, id_map, X, node_R)
    n == 3 && return _tacs_tria3_shell_operator(model, el, id_map, X, node_R)
    error("TACS-formulation shell residual/tangent supports CQUAD4/CQUADR/CTRIA3 only; got $n nodes.")
end

function _tacs_quad4_shell_residual_tangent(model::Dict, el::AbstractDict, id_map, X, node_R)
    return _tacs_quad4_shell_operator(model, el, id_map, X, node_R)
end

_tacs_quad4_mat1_pshell_residual_tangent(model::Dict, el::AbstractDict, id_map, X, node_R) =
    _tacs_quad4_shell_residual_tangent(model, el, id_map, X, node_R)

function _tacs_quad4_membrane_bending_B_center(lc::AbstractMatrix)
    dNr, dNs = FEM.shape_derivs_quad(0.0, 0.0)
    J11 = dNr[1] * lc[1,1] + dNr[2] * lc[2,1] + dNr[3] * lc[3,1] + dNr[4] * lc[4,1]
    J12 = dNr[1] * lc[1,2] + dNr[2] * lc[2,2] + dNr[3] * lc[3,2] + dNr[4] * lc[4,2]
    J21 = dNs[1] * lc[1,1] + dNs[2] * lc[2,1] + dNs[3] * lc[3,1] + dNs[4] * lc[4,1]
    J22 = dNs[1] * lc[1,2] + dNs[2] * lc[2,2] + dNs[3] * lc[3,2] + dNs[4] * lc[4,2]
    detJ = J11 * J22 - J12 * J21
    abs(detJ) > 1e-14 || error("TACS-formulation SOL105 Kg recovery found a singular CQUAD4 Jacobian.")
    inv_det = 1.0 / detJ
    iJ11 =  J22 * inv_det
    iJ12 = -J12 * inv_det
    iJ21 = -J21 * inv_det
    iJ22 =  J11 * inv_det

    Bm = zeros(Float64, 3, 24)
    Bb = zeros(Float64, 3, 24)
    for k in 1:4
        dNdx = iJ11 * dNr[k] + iJ12 * dNs[k]
        dNdy = iJ21 * dNr[k] + iJ22 * dNs[k]
        base = (k - 1) * 6
        Bm[1, base + 1] = dNdx
        Bm[2, base + 2] = dNdy
        Bm[3, base + 1] = dNdy
        Bm[3, base + 2] = dNdx
        Bb[1, base + 5] = dNdx
        Bb[2, base + 4] = -dNdy
        Bb[3, base + 5] = dNdy
        Bb[3, base + 4] = -dNdx
    end
    return Bm, Bb
end

function _tacs_quad4_shell_geometric_stiffness_operator(
    model::Dict,
    el::AbstractDict,
    id_map,
    X,
    node_R,
    u_global::AbstractVector,
)
    nids = Int.(el["NODES"])
    idxs = [id_map[nid] for nid in nids]
    ps = [SVector{3,Float64}(X[idx, 1], X[idx, 2], X[idx, 3]) for idx in idxs]
    lc, v1, v2, v3 = _tacs_quad4_local_geometry(ps[1], ps[2], ps[3], ps[4])
    prop = model["PSHELLs"][string(Int(el["PID"]))]
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, prop, el)
    _ = Cb, Cs, Eref
    T = _tacs_quad4_transform(idxs, v1, v2, v3, node_R)
    dofs = Vector{Int}(undef, 24)
    for k in 1:4
        base_global = (idxs[k] - 1) * 6
        for d in 1:6
            dofs[(k - 1) * 6 + d] = base_global + d
        end
    end

    u_local = T * Float64.(u_global[dofs])
    Bm, Bb = _tacs_quad4_membrane_bending_B_center(lc)
    eps0 = Bm * u_local
    kappa = Bb * u_local
    membrane_resultant = Cm * eps0
    Bmb !== nothing && (membrane_resultant .+= Bmb * kappa)
    sigma_mem = membrane_resultant ./ max(h, 1e-30)

    Kg_local = FEM.geometric_stiffness_quad4(
        lc,
        sigma_mem,
        h;
        Cm=Cm,
        membrane_incomp=false,
        membrane_enhanced=false,
        membrane_assumed_mode=:none,
    )
    Kg = transpose(T) * Kg_local * T
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    return Kg, dofs, membrane_resultant
end

function _tacs_tria3_shell_geometric_stiffness_operator(
    model::Dict,
    el::AbstractDict,
    id_map,
    X,
    node_R,
    u_global::AbstractVector,
)
    nids = Int.(el["NODES"])
    idxs = [id_map[nid] for nid in nids]
    ps = [SVector{3,Float64}(X[idx, 1], X[idx, 2], X[idx, 3]) for idx in idxs]
    lc, v1, v2, v3 = _tacs_tria3_local_geometry(ps[1], ps[2], ps[3])
    prop = model["PSHELLs"][string(Int(el["PID"]))]
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, prop, el)
    _ = Cb, Cs, Bmb
    T = _tacs_shell_transform(idxs, v1, v2, v3, node_R)
    dofs = _tacs_shell_dofs(idxs)

    u_local = T * Float64.(u_global[dofs])
    mat =
        uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL" ?
        model["MATs"][string(Int(prop["MID"]))] :
        Dict{String,Any}("E" => Eref, "NU" => 0.3)
    E = Float64(get(mat, "E", Eref))
    nu = Float64(get(mat, "NU", 0.3))
    cm_override = uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PCOMP_CLT" ? Cm : nothing
    membrane_resultant, _, _, _, _, _, _ =
        FEM.stress_strain_tria3(lc, u_local, E, nu, Float64(h); Cm_override=cm_override)
    sigma_mem = membrane_resultant ./ max(Float64(h), 1e-30)

    Kg_local = FEM.geometric_stiffness_tria3(lc, sigma_mem, Float64(h))
    Kg = transpose(T) * Kg_local * T
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    return Kg, dofs, membrane_resultant
end

function _tacs_shell_geometric_stiffness_operator(model::Dict, el::AbstractDict, id_map, X, node_R, u_global::AbstractVector)
    n = length(get(el, "NODES", Any[]))
    n == 4 && return _tacs_quad4_shell_geometric_stiffness_operator(model, el, id_map, X, node_R, u_global)
    n == 3 && return _tacs_tria3_shell_geometric_stiffness_operator(model, el, id_map, X, node_R, u_global)
    error("TACS-formulation shell geometric stiffness supports CQUAD4/CQUADR/CTRIA3 only; got $n nodes.")
end

function _tacs_quad4_shell_thickness_tangent(model::Dict, el::AbstractDict, id_map, X, node_R)
    pid = string(Int(get(el, "PID", 0)))
    prop = model["PSHELLs"][pid]
    _tacs_shell_supports_thickness_derivative(prop) ||
        error("TACS-formulation thickness derivatives are not implemented for property $pid TYPE=$(get(prop, "TYPE", "?")).")
    _tacs_ensure_pcomp_reference!(prop)
    t0 = Float64(get(prop, "T", 0.0))
    t0 > 0.0 || error("TACS-formulation shell thickness must be positive.")
    dt = max(1e-6 * t0, 1e-8)

    model_p = deepcopy(model)
    model_m = deepcopy(model)
    for (m, t) in ((model_p, t0 + dt), (model_m, t0 - dt))
        p = m["PSHELLs"][pid]
        p["T"] = t
        p["Z1"] = -0.5 * t
        p["Z2"] = 0.5 * t
    end
    Ke_p, dofs = _tacs_shell_residual_tangent(model_p, el, id_map, X, node_R)
    Ke_m, _ = _tacs_shell_residual_tangent(model_m, el, id_map, X, node_R)
    return (Ke_p .- Ke_m) ./ (2.0 * dt), dofs
end

function _tacs_shell_thickness_tangent_ad(model::Dict, el::AbstractDict, id_map, X, node_R)
    pid = string(Int(get(el, "PID", 0)))
    prop = model["PSHELLs"][pid]
    _tacs_shell_supports_thickness_derivative(prop) ||
        error("TACS-formulation AD thickness derivatives are not implemented for property $pid TYPE=$(get(prop, "TYPE", "?")).")
    _tacs_ensure_pcomp_reference!(prop)
    t0 = Float64(get(prop, "T", 0.0))
    t0 > 0.0 || error("TACS-formulation shell thickness must be positive.")

    Ke0, dofs = _tacs_shell_residual_tangent(model, el, id_map, X, node_R)
    jac = ForwardDiff.jacobian(x -> begin
        m = deepcopy(model)
        p = m["PSHELLs"][pid]
        t = x[1]
        p["T"] = t
        if uppercase(string(get(p, "TYPE", "PSHELL"))) == "PSHELL"
            p["Z1"] = -0.5 * t
            p["Z2"] = 0.5 * t
        else
            _tacs_ensure_pcomp_reference!(p)
        end
        Ke, _ = _tacs_shell_residual_tangent(m, el, id_map, X, node_R)
        return vec(Ke)
    end, [t0])
    dKe = reshape(jac[:, 1], size(Ke0))
    dKe .= 0.5 .* (dKe .+ transpose(dKe))
    return dKe, dofs
end

_tacs_quad4_shell_thickness_tangent_ad(model::Dict, el::AbstractDict, id_map, X, node_R) =
    _tacs_shell_thickness_tangent_ad(model, el, id_map, X, node_R)

_tacs_quad4_mat1_pshell_thickness_tangent(model::Dict, el::AbstractDict, id_map, X, node_R) =
    _tacs_shell_thickness_tangent_ad(model, el, id_map, X, node_R)

_tacs_element_residual(Ke::AbstractMatrix, ue::AbstractVector) = Ke * ue
_tacs_global_residual(K::AbstractMatrix, u::AbstractVector) = K * u

function _tacs_design_variable_id(dv::AbstractDict)
    raw = get(dv, "id", nothing)
    !isnothing(raw) && return string(raw)
    dv_type = string(get(dv, "type", "design"))
    pids = join(string.(get(dv, "pids", Any[])), "_")
    ply = haskey(dv, "ply_index") ? "_ply$(Int(dv["ply_index"]))" : ""
    return isempty(pids) ? dv_type * ply : "$(dv_type)_PID$(pids)$(ply)"
end

function _tacs_pcomp_ply_step(prop::AbstractDict, ply_idx::Integer, perturb_field::Symbol)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector || error("TACS PCOMP ply derivative requires PLY_DATA.")
    1 <= ply_idx <= length(ply_data) || error("TACS PCOMP ply derivative requested ply $ply_idx but property has $(length(ply_data)) plies.")
    ply = ply_data[ply_idx]
    if perturb_field == :T
        t_ply = Float64(ply["z_top"] - ply["z_bot"])
        t_ply > 0.0 || error("TACS PCOMP ply-thickness derivative requires positive ply thickness.")
        return min(max(abs(t_ply) * 1e-6, 1e-10), 0.25 * t_ply)
    else
        theta_deg = Float64(get(ply, "theta", get(ply, "THETA", 0.0)))
        return max(abs(theta_deg) * 1e-6, 1e-5)
    end
end

function _tacs_pcomp_shear_corrected(Ash::AbstractMatrix, ply_data::AbstractVector, total_t::Float64, mats::AbstractDict)
    ts_t_default = 5.0 / 6.0
    ts_t_raw = strip(get(ENV, "JFEM_PCOMP_TS_T", ""))
    ts_t_parsed = isempty(ts_t_raw) ? nothing : tryparse(Float64, ts_t_raw)
    Cs_lam =
        ts_t_parsed !== nothing ? ts_t_parsed .* Ash :
        pcomp_whitney_shear_enabled() && !isempty(ply_data) ? begin
            kappa_x, kappa_y = pcomp_whitney_kappa(collect(ply_data), total_t)
            [kappa_x * Ash[1,1] kappa_x * Ash[1,2]; kappa_y * Ash[2,1] kappa_y * Ash[2,2]]
        end :
        ts_t_default .* Ash

    saw_mat8_ply = false
    all_mat8_plies_blank_transverse_shear = true
    for ply in ply_data
        mid_raw = get(ply, "mid", get(ply, "MID", nothing))
        isnothing(mid_raw) && continue
        mat = get(mats, string(Int(mid_raw)), nothing)
        isnothing(mat) && continue
        if haskey(mat, "E1")
            saw_mat8_ply = true
            all_mat8_plies_blank_transverse_shear &=
                Bool(get(mat, "G1Z_BLANK", false)) && Bool(get(mat, "G2Z_BLANK", false))
        else
            all_mat8_plies_blank_transverse_shear = false
        end
    end

    rigid_ts_disable = lowercase(strip(get(ENV, "JFEM_PCOMP_RIGID_TS_DISABLE", ""))) in ("1", "true", "yes", "on")
    if !rigid_ts_disable && saw_mat8_ply && all_mat8_plies_blank_transverse_shear
        cs_scale_env = strip(get(ENV, "JFEM_PCOMP_RIGID_TS_CS_SCALE", ""))
        cs_factor_env = strip(get(ENV, "JFEM_PCOMP_RIGID_TS_CS_FACTOR", ""))
        if !isempty(cs_factor_env)
            Cs_factor = something(tryparse(Float64, cs_factor_env), 3.57)
            Cs_lam = Cs_factor .* Cs_lam
        else
            Cs_scale = isempty(cs_scale_env) ? 2.5 : something(tryparse(Float64, cs_scale_env), 2.5)
            Cs_lam = Cs_scale .* Ash
        end
    end
    return Cs_lam
end

function _tacs_recompute_pcomp_clt(prop::AbstractDict, mats::AbstractDict; perturb_ply::Int=0, perturb_field::Symbol=:T, perturb_delta::Float64=0.0)
    ply_data = prop["PLY_DATA"]
    n_plies = length(ply_data)
    ply_t = [Float64(ply_data[k]["z_top"] - ply_data[k]["z_bot"]) for k in 1:n_plies]
    ply_theta = [deg2rad(Float64(ply_data[k]["theta"])) for k in 1:n_plies]

    if 1 <= perturb_ply <= n_plies
        if perturb_field == :T
            ply_t[perturb_ply] += perturb_delta
        elseif perturb_field == :THETA
            ply_theta[perturb_ply] += perturb_delta
        end
    end

    total_t = sum(ply_t)
    total_t > 0.0 || error("TACS PCOMP ply perturbation produced nonpositive total thickness.")
    z_bot = -0.5 * total_t
    A = zeros(3, 3)
    B = zeros(3, 3)
    D = zeros(3, 3)
    Ash = zeros(2, 2)
    perturbed_ply_data = Any[]

    for k in 1:n_plies
        t = ply_t[k]
        t > 0.0 || error("TACS PCOMP ply perturbation produced nonpositive thickness for ply $k.")
        theta = ply_theta[k]
        z_top = z_bot + t
        ply = ply_data[k]
        pdata = Solver._pcomp_ply_material_data(ply, mats)
        if !isnothing(pdata)
            Qb = Solver._qbar_plane_stress(pdata.E1, pdata.E2, pdata.nu12, pdata.G12, theta)
            Qs = Solver._qbar_shear(pdata.G13, pdata.G23, theta)
        else
            Qb = Float64.(ply["Qbar"])
            Qs = Float64.(ply["Qshear"])
        end

        A .+= Qb .* (z_top - z_bot)
        B .+= Qb .* (z_top^2 - z_bot^2) / 2.0
        D .+= Qb .* (z_top^3 - z_bot^3) / 3.0
        Ash .+= Qs .* (z_top - z_bot)
        push!(perturbed_ply_data, Dict(
            "Qbar" => copy(Qb),
            "Qshear" => copy(Qs),
            "z_bot" => z_bot,
            "z_top" => z_top,
            "theta" => rad2deg(theta),
            "mid" => get(ply, "mid", get(ply, "MID", nothing)),
            "sout" => get(ply, "sout", get(ply, "SOUT", "")),
        ))
        z_bot = z_top
    end

    Cs = _tacs_pcomp_shear_corrected(Ash, perturbed_ply_data, total_t, mats)
    Bmb = maximum(abs.(B)) > 1e-10 * maximum(abs.(A); init=1.0) ? B : nothing
    return A, Bmb, D, Cs, total_t, perturbed_ply_data, Ash
end

function _tacs_update_pcomp_clt_reference!(
    prop::AbstractDict,
    mats::AbstractDict,
    ply_idx::Integer,
    perturb_field::Symbol,
    delta_user::Real,
)
    uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" ||
        error("TACS PCOMP ply derivative requires a PCOMP_CLT property.")
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector || error("TACS PCOMP ply derivative requires PLY_DATA.")
    1 <= ply_idx <= length(ply_data) || error("TACS PCOMP ply derivative requested ply $ply_idx but property has $(length(ply_data)) plies.")

    delta_for_clt = perturb_field == :THETA ? deg2rad(Float64(delta_user)) : Float64(delta_user)
    Cm, Bmb, Cb, Cs, total_t, perturbed_ply_data, Ash = _tacs_recompute_pcomp_clt(
        prop,
        mats;
        perturb_ply=Int(ply_idx),
        perturb_field=perturb_field,
        perturb_delta=delta_for_clt,
    )

    prop["T"] = total_t
    prop["T_REF"] = total_t
    prop["Cm"] = Cm
    prop["Bmb"] = Bmb
    prop["Cb"] = Cb
    prop["Cs"] = Cs
    prop["Cm_ref"] = copy(Cm)
    prop["Bmb_ref"] = Bmb === nothing ? nothing : copy(Bmb)
    prop["Cb_ref"] = copy(Cb)
    prop["Cs_ref"] = copy(Cs)
    prop["Cs_raw"] = copy(Ash)
    prop["PLY_DATA"] = perturbed_ply_data
    return prop
end

function _tacs_refresh_pcomp_clt_for_material!(model::AbstractDict, mid::Integer)
    mats = get(model, "MATs", Dict())
    for (_, prop_any) in get(model, "PSHELLs", Dict())
        prop = prop_any::AbstractDict
        uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || continue
        ply_data = get(prop, "PLY_DATA", Any[])
        any(ply -> Int(get(ply, "mid", get(ply, "MID", -1))) == Int(mid), ply_data) || continue
        Cm, Bmb, Cb, Cs, total_t, refreshed_ply_data, Ash =
            _tacs_recompute_pcomp_clt(prop, mats)
        prop["T"] = total_t
        prop["T_REF"] = total_t
        prop["Cm"] = Cm
        prop["Bmb"] = Bmb
        prop["Cb"] = Cb
        prop["Cs"] = Cs
        prop["Cm_ref"] = copy(Cm)
        prop["Bmb_ref"] = Bmb === nothing ? nothing : copy(Bmb)
        prop["Cb_ref"] = copy(Cb)
        prop["Cs_ref"] = copy(Cs)
        prop["Cs_raw"] = copy(Ash)
        prop["PLY_DATA"] = refreshed_ply_data
    end
    return model
end

function _tacs_model_with_pcomp_ply_delta(
    model::AbstractDict,
    pid::Integer,
    ply_idx::Integer,
    dv_type::AbstractString,
    delta_user::Real,
)
    m = deepcopy(model)
    prop = get(get(m, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("TACS PCOMP ply perturbation could not find shell property $pid.")
    perturb_field =
        string(dv_type) == "pcomp_ply_thickness" ? :T :
        string(dv_type) == "pcomp_ply_angle" ? :THETA :
        error("TACS PCOMP ply perturbation does not support design variable type '$dv_type'.")
    _tacs_update_pcomp_clt_reference!(prop, m["MATs"], Int(ply_idx), perturb_field, delta_user)
    return m
end

function _tacs_pcomp_ply_tangent_fd(
    model::Dict,
    el::AbstractDict,
    id_map,
    X,
    node_R,
    dv::AbstractDict,
)
    pid = Int(get(el, "PID", 0))
    pid_list = Set(Int.(collect(get(dv, "pids", [pid]))))
    pid in pid_list || return nothing
    prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
    prop === nothing && error("TACS PCOMP ply derivative could not find property $pid.")
    uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" ||
        error("TACS PCOMP ply derivative requires PCOMP_CLT; property $pid has TYPE=$(get(prop, "TYPE", "?")).")
    ply_idx = Int(get(dv, "ply_index", 0))
    perturb_field =
        string(get(dv, "type", "")) == "pcomp_ply_thickness" ? :T :
        string(get(dv, "type", "")) == "pcomp_ply_angle" ? :THETA :
        error("TACS PCOMP ply derivative does not support design variable type '$(get(dv, "type", "?"))'.")
    h = _tacs_pcomp_ply_step(prop, ply_idx, perturb_field)

    model_p = _tacs_model_with_pcomp_ply_delta(model, pid, ply_idx, string(dv["type"]), h)
    model_m = _tacs_model_with_pcomp_ply_delta(model, pid, ply_idx, string(dv["type"]), -h)
    Ke_p, dofs = _tacs_shell_residual_tangent(model_p, el, id_map, X, node_R)
    Ke_m, _ = _tacs_shell_residual_tangent(model_m, el, id_map, X, node_R)
    dKe = (Ke_p .- Ke_m) ./ (2.0 * h)
    dKe .= 0.5 .* (dKe .+ transpose(dKe))
    return dKe, dofs, h
end

_tacs_quad4_pcomp_ply_tangent_fd(model::Dict, el::AbstractDict, id_map, X, node_R, dv::AbstractDict) =
    _tacs_pcomp_ply_tangent_fd(model, el, id_map, X, node_R, dv)

function _tacs_model_with_material_field_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = get(get(m, "MATs", Dict()), string(Int(mid)), nothing)
    mat === nothing && error("TACS material derivative could not find material $mid.")
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    field_key = uppercase(strip(string(field)))
    if mat_type in ("MAT1", "MAT1_EQUIV")
        field_key in ("E", "G", "NU") || error("TACS material derivative supports MAT1 E/G/NU only; got $field_key.")
    elseif mat_type == "MAT8"
        field_key in ("E1", "E2", "G12", "NU12") || error("TACS material derivative supports MAT8 E1/E2/G12/NU12 only; got $field_key.")
    else
        error("TACS material derivative does not support material $mid TYPE=$(get(mat, "TYPE", "?")).")
    end
    value = Float64(get(mat, field_key, 0.0)) + Float64(delta)
    if field_key in ("E", "G", "E1", "E2", "G12")
        value > 0.0 || error("TACS material derivative produced nonpositive $mat_type $field_key for material $mid.")
    else
        -0.49 < value < 0.49 || error("TACS material derivative produced unsupported $mat_type $field_key=$value for material $mid.")
    end
    mat[field_key] = value
    if field_key == "NU"
        E = Float64(get(mat, "E", 0.0))
        E > 0.0 || error("TACS material derivative requires positive MAT1 E when perturbing NU.")
        mat["G"] = E / (2.0 * (1.0 + value))
    elseif mat_type == "MAT8"
        field_key == "E1" && (mat["E"] = value)
        field_key == "G12" && (mat["G"] = value)
        field_key == "NU12" && (mat["NU"] = value)
        _tacs_refresh_pcomp_clt_for_material!(m, mid)
    end
    return m
end

function _tacs_material_tangent_fd(model::Dict, el::AbstractDict, id_map, X, node_R, dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    dv_type in ("material_E", "material_G", "material_NU", "material_E1", "material_E2", "material_G12", "material_NU12") || error("TACS material derivative does not support design variable type '$dv_type'.")
    mid = Int(first(collect(get(dv, "mids", Int[]))))
    mat = get(get(model, "MATs", Dict()), string(mid), nothing)
    mat === nothing && error("TACS material derivative could not find material $mid.")
    field =
        dv_type == "material_E" ? "E" :
        dv_type == "material_G" ? "G" :
        dv_type == "material_NU" ? "NU" :
        dv_type == "material_E1" ? "E1" :
        dv_type == "material_E2" ? "E2" :
        dv_type == "material_G12" ? "G12" :
        "NU12"
    value0 = Float64(get(mat, field, 0.0))
    if field in ("E", "G", "E1", "E2", "G12")
        value0 > 0.0 || error("TACS material derivative requires positive $field for material $mid.")
        h = max(1e-6 * value0, 1e-3)
    else
        -0.49 < value0 < 0.49 || error("TACS material derivative requires $field in (-0.49, 0.49) for material $mid.")
        h = min(1e-6, 0.25 * min(value0 + 0.49, 0.49 - value0))
        h > 0.0 || error("TACS material derivative could not choose a positive $field perturbation for material $mid.")
    end
    model_p = _tacs_model_with_material_field_delta(model, mid, field, h)
    model_m = _tacs_model_with_material_field_delta(model, mid, field, -h)
    Ke_p, dofs = _tacs_shell_residual_tangent(model_p, el, id_map, X, node_R)
    Ke_m, _ = _tacs_shell_residual_tangent(model_m, el, id_map, X, node_R)
    dKe = (Ke_p .- Ke_m) ./ (2.0 * h)
    dKe .= 0.5 .* (dKe .+ transpose(dKe))
    return dKe, dofs, h
end

function _tacs_assemble_sol101_design_derivative(
    model::Dict,
    dv::AbstractDict;
    allowed_sol_types=(101,),
    route_label="SOL101 design sensitivity",
)
    _tacs_validate_shell_slice(model; allowed_sol_types=allowed_sol_types, route_label=route_label)
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    cshells = model["CSHELLs"]
    nnz_est = 576 * length(cshells)
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()
    sizehint!(I_idx, nnz_est); sizehint!(J_idx, nnz_est); sizehint!(V_val, nnz_est)
    steps = Float64[]
    dv_type = string(get(dv, "type", ""))
    pid_filter = Set(Int.(collect(get(dv, "pids", Int[]))))

    for (_, el) in cshells
        pid = Int(get(el, "PID", 0))
        isempty(pid_filter) || pid in pid_filter || continue
        local tangent
        if dv_type == "shell_thickness"
            tangent = _tacs_shell_thickness_tangent_ad(model, el, id_map, X, node_R)
        elseif dv_type in ("pcomp_ply_thickness", "pcomp_ply_angle")
            tangent = _tacs_pcomp_ply_tangent_fd(model, el, id_map, X, node_R, dv)
            tangent === nothing && continue
        elseif dv_type in ("material_E", "material_G", "material_NU", "material_E1", "material_E2", "material_G12", "material_NU12")
            tangent = _tacs_material_tangent_fd(model, el, id_map, X, node_R, dv)
        else
            error("TACS design derivative does not support design variable type '$dv_type'.")
        end
        Ke, dofs = tangent[1], tangent[2]
        length(tangent) >= 3 && push!(steps, Float64(tangent[3]))
        nd = length(dofs)
        for c in 1:nd, r in 1:nd
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    K = sparse(I_idx, J_idx, V_val, ndof, ndof)
    return K, id_map, X, ndof, node_R, steps
end

function _tacs_assemble_sol101(model::Dict; thickness_derivative_pid=nothing, allowed_sol_types=(101,), route_label="SOL101")
    _tacs_validate_shell_slice(model; allowed_sol_types=allowed_sol_types, route_label=route_label)
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    cshells = model["CSHELLs"]
    nnz_est = 576 * length(cshells)
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()
    sizehint!(I_idx, nnz_est); sizehint!(J_idx, nnz_est); sizehint!(V_val, nnz_est)
    max_elem_stiff = 0.0
    for (_, el) in cshells
        use_thickness_derivative =
            thickness_derivative_pid !== nothing &&
            Int(get(el, "PID", 0)) == Int(thickness_derivative_pid)
        Ke, dofs =
            use_thickness_derivative ?
            _tacs_shell_thickness_tangent_ad(model, el, id_map, X, node_R) :
            _tacs_shell_residual_tangent(model, el, id_map, X, node_R)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        nd = length(dofs)
        for c in 1:nd, r in 1:nd
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    K = sparse(I_idx, J_idx, V_val, ndof, ndof)
    orig_diag = collect(diag(K))
    rbe3_map = Dict{Int,Vector{Tuple{Int,Float64}}}()
    snorm_normals = Dict{Int,SVector{3,Float64}}()
    return K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag
end

function _tacs_assemble_sol105_geometric_stiffness(
    model::Dict,
    id_map,
    X,
    node_R,
    ndof::Integer,
    u_static::AbstractVector,
    snorm_normals,
    rbe3_map;
    snorm_angle_override=nothing,
    buckling_subcase=nothing,
    static_load_id=nothing,
    timings=nothing,
)
    _ = snorm_normals, rbe3_map, snorm_angle_override, buckling_subcase, static_load_id
    t_start = time_ns()
    _tacs_validate_shell_slice(model; allowed_sol_types=(105, 106), route_label="SOL105/SOL106 Kg")
    cshells = get(model, "CSHELLs", Dict())
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()
    sizehint!(I_idx, 576 * length(cshells))
    sizehint!(J_idx, 576 * length(cshells))
    sizehint!(V_val, 576 * length(cshells))
    n_shell = 0
    n_sum = zeros(Float64, 3)
    for (_, el) in cshells
        Kg, dofs, membrane_resultant =
            _tacs_shell_geometric_stiffness_operator(model, el, id_map, X, node_R, u_static)
        n_shell += 1
        n_sum .+= membrane_resultant
        nd = length(dofs)
        for c in 1:nd, r in 1:nd
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Kg[r, c])
        end
    end
    Kg = sparse(I_idx, J_idx, V_val, ndof, ndof)
    if timings isa AbstractDict
        timings["tacs_native_kg_assembly"] = (time_ns() - t_start) * 1e-9
        timings["tacs_native_kg_elements"] = n_shell
        if n_shell > 0
            timings["tacs_native_kg_avg_Nxx"] = n_sum[1] / n_shell
            timings["tacs_native_kg_avg_Nyy"] = n_sum[2] / n_shell
            timings["tacs_native_kg_avg_Nxy"] = n_sum[3] / n_shell
        end
    end
    return Kg
end

function _solve_tacs_sol101(model::Dict)
    println("\n>>> SOL 101 Linear Static Analysis (TACS-formulation backend)")
    t_asm = time_ns()
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag =
        _tacs_assemble_sol101(model)
    t_asm_K = (time_ns() - t_asm) * 1e-9
    cc = model["CASE_CONTROL"]
    sorted_sids = sort(collect(keys(cc["SUBCASES"])))
    mesh = _build_mesh_output(model, id_map, X)
    t_disp = time_ns()
    results = _solve_sol101(
        model, cc, K, id_map, X, ndof, node_R,
        max_elem_stiff, rbe3_map, snorm_normals, orig_diag,
        sorted_sids, mesh,
    )
    results["timings"] = Dict{String,Any}(
        "assembly_K" => t_asm_K,
        "assembly_Keig" => 0.0,
        "solve_cases" => (time_ns() - t_disp) * 1e-9,
    )
    return results
end

function _solve_tacs_sol103(model::Dict)
    println("\n>>> SOL 103 Normal Modes Analysis (TACS-formulation backend)")
    t_asm = time_ns()
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, _, orig_diag =
        _tacs_assemble_sol101(model; allowed_sol_types=(103,), route_label="SOL103")
    t_asm_K = (time_ns() - t_asm) * 1e-9

    cc = model["CASE_CONTROL"]
    sorted_sids = sort(collect(keys(cc["SUBCASES"])))
    mesh = _build_mesh_output(model, id_map, X)

    t_disp = time_ns()
    results = _solve_sol103(
        model, cc, K, id_map, X, ndof, node_R,
        max_elem_stiff, rbe3_map, orig_diag,
        sorted_sids, mesh,
    )
    results["timings"] = Dict{String,Any}(
        "assembly_K" => t_asm_K,
        "assembly_Keig" => 0.0,
        "solve_cases" => (time_ns() - t_disp) * 1e-9,
    )
    results["K"] = K
    results["ndof"] = ndof
    results["node_R"] = node_R
    results["rbe3_map"] = rbe3_map
    results["tacs_formulation_sol103"] = Dict{String,Any}(
        "linear_stiffness" => "residual_first_quad4_tria3",
        "mass" => "shared_jfem_mass",
        "eigensolver" => "shared_sol103",
    )
    return results
end

function _tacs_preflight_sol105_shared_route(model::Dict)
    cc = model["CASE_CONTROL"]
    if _model_has_temperature_dependent_mat1(model)
        for (_, sub) in get(cc, "SUBCASES", Dict())
            if !isnothing(Solver._subcase_temp_load_sid(sub, cc))
                error("TACS-formulation SOL105 currently does not support temperature-dependent MAT1 reassembly.")
            end
        end
    end
    if !Solver.sol105_static_membrane_incomp_enabled() &&
       Solver.sol105_static_membrane_incomp_auto_load_enabled()
        error("TACS-formulation SOL105 currently requires a fixed static membrane-incomp setting; disable JFEM_SOL105_STATIC_MEMBRANE_INCOMP_AUTO_LOAD or enable JFEM_SOL105_STATIC_MEMBRANE_INCOMP.")
    end
    return nothing
end

function _solve_tacs_sol105(model::Dict)
    println("\n>>> SOL 105 Linear Buckling Analysis (TACS-formulation backend)")
    _tacs_validate_shell_slice(model; allowed_sol_types=(105,), route_label="SOL105")
    _tacs_preflight_sol105_shared_route(model)

    t_asm = time_ns()
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag =
        _tacs_assemble_sol101(model; allowed_sol_types=(105,), route_label="SOL105")
    t_asm_K = (time_ns() - t_asm) * 1e-9

    cc = model["CASE_CONTROL"]
    sorted_sids = sort(collect(keys(cc["SUBCASES"])))
    mesh = _build_mesh_output(model, id_map, X)
    sol105_snorm_angle = Solver.sol105_snorm_angle_override()

    t_disp = time_ns()
    results = _solve_sol105(
        model, cc, K, K, id_map, X, ndof, node_R,
        max_elem_stiff, rbe3_map, snorm_normals, orig_diag,
        sorted_sids, sol105_snorm_angle, mesh;
        geometric_stiffness_builder=_tacs_assemble_sol105_geometric_stiffness,
    )
    existing_timings = get(results, "timings", Dict{String,Any}())
    merged_timings = Dict{String,Any}()
    if existing_timings isa AbstractDict
        for (k, v) in existing_timings
            merged_timings[string(k)] = v
        end
    end
    merge!(merged_timings, Dict{String,Any}(
        "assembly_K" => t_asm_K,
        "assembly_Keig" => 0.0,
        "solve_cases" => (time_ns() - t_disp) * 1e-9,
    ))
    results["timings"] = merged_timings
    results["tacs_formulation_sol105"] = Dict{String,Any}(
        "linear_stiffness" => "residual_first_quad4_tria3",
        "geometric_stiffness" => "native_residual_first_quad4_tria3",
        "eig_stiffness" => "same_as_static_tangent",
    )
    return results
end

function _tacs_preflight_sol106_shared_route(model::Dict)
    cc = model["CASE_CONTROL"]
    if _model_has_temperature_dependent_mat1(model)
        for (_, sub) in get(cc, "SUBCASES", Dict())
            if !isnothing(Solver._subcase_temp_load_sid(sub, cc))
                error("TACS-formulation SOL106 currently does not support temperature-dependent MAT1 reassembly.")
            end
        end
    end
    return nothing
end

function _tacs_sol106_formal_requested(model::Dict)
    nl_method_raw = lowercase(strip(string(get(model, "PARAM_NLMETHOD", "auto"))))
    return nl_method_raw in ("formal", "formal_shell_von_karman", "formal_von_karman", "formal_shell_vk")
end

function _tacs_evaluate_sol106_nonlinear_state(
    K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
    snorm_normals, rbe3_map; residual_model::Symbol=:tangent_operator)
    return Solver._evaluate_nonlinear_state(
        K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
        snorm_normals, rbe3_map;
        residual_model=residual_model,
        geometric_stiffness_builder=_tacs_assemble_sol105_geometric_stiffness,
    )
end

function _tacs_evaluate_sol106_formal_nonlinear_state(
    K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
    snorm_normals, rbe3_map; residual_model::Symbol=:tangent_operator)
    return Solver._evaluate_nonlinear_state_formal(
        K_linear, F_applied, ndof, model, id_map, X, spc_id, node_R, u_state,
        snorm_normals, rbe3_map,
    )
end

function _solve_tacs_sol106(model::Dict)
    println("\n>>> SOL 106 Nonlinear Static Analysis (TACS-formulation backend)")
    _tacs_validate_shell_slice(model; allowed_sol_types=(106,), route_label="SOL106")
    _tacs_preflight_sol106_shared_route(model)

    t_asm = time_ns()
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag =
        _tacs_assemble_sol101(model; allowed_sol_types=(106,), route_label="SOL106")
    t_asm_K = (time_ns() - t_asm) * 1e-9

    cc = model["CASE_CONTROL"]
    sorted_sids = sort(collect(keys(cc["SUBCASES"])))
    mesh = _build_mesh_output(model, id_map, X)
    sol106_snorm_angle = nothing
    formal_requested = _tacs_sol106_formal_requested(model)
    nonlinear_state_builder = formal_requested ?
        _tacs_evaluate_sol106_formal_nonlinear_state :
        _tacs_evaluate_sol106_nonlinear_state

    t_disp = time_ns()
    results = _solve_sol106(
        model, cc, K, id_map, X, ndof, node_R,
        max_elem_stiff, rbe3_map, snorm_normals, orig_diag,
        sorted_sids, sol106_snorm_angle, mesh;
        geometric_stiffness_builder=_tacs_assemble_sol105_geometric_stiffness,
        nonlinear_state_builder=nonlinear_state_builder,
    )
    existing_timings = get(results, "timings", Dict{String,Any}())
    merged_timings = Dict{String,Any}()
    if existing_timings isa AbstractDict
        for (k, v) in existing_timings
            merged_timings[string(k)] = v
        end
    end
    merge!(merged_timings, Dict{String,Any}(
        "assembly_K" => t_asm_K,
        "assembly_Keig" => 0.0,
        "solve_cases" => (time_ns() - t_disp) * 1e-9,
    ))
    results["timings"] = merged_timings
    results["tacs_formulation_sol106"] = Dict{String,Any}(
        "linear_stiffness" => "residual_first_quad4_tria3",
        "geometric_stiffness" => "native_residual_first_quad4_tria3",
        "nonlinear_route" => "backend_nonlinear_state_callback",
        "state_callback" => formal_requested ? "tacs_formulation_formal_shell_von_karman" : "tacs_formulation_tangent_operator",
    )
    return results
end

function _tacs_sol101_active_shell_pids(model::AbstractDict)
    pids = Set{Int}()
    for (_, el) in get(model, "CSHELLs", Dict())
        push!(pids, Int(get(el, "PID", 0)))
    end
    return sort!(collect(pids))
end

function static_compliance_thickness_gradient(::TACSFormulationBackend, results::AbstractDict; pids=nothing)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("TACS static compliance gradient requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("TACS static compliance gradient requires stored analysis displacement vector.")
    K = results["K"]
    compliance = dot(u, K * u)

    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))
    gradients = Dict{String,Float64}()
    for pid in pid_list
        dK, _, _, _, _, _, _, _, _ = _tacs_assemble_sol101(model; thickness_derivative_pid=pid)
        gradients[string(pid)] = -dot(u, dK * u)
    end
    return Dict{String,Any}(
        "response" => "compliance",
        "value" => compliance,
        "gradient" => gradients,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_element_ad",
        "subcase_index" => 1,
    )
end

function static_compliance_design_gradient(::TACSFormulationBackend, results::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("TACS static compliance design gradient requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("TACS static compliance design gradient requires stored analysis displacement vector.")
    K = results["K"]
    compliance = dot(u, K * u)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        gradients[dv_id] = -dot(u, dK * u)
        diag = Dict{String,Any}(
            "type" => string(get(dv, "type", "")),
            "pids" => Int.(collect(get(dv, "pids", Int[]))),
            "gradient_backend" => "tacs_formulation_design_tangent",
        )
        haskey(dv, "ply_index") && (diag["ply_index"] = Int(dv["ply_index"]))
        !isempty(steps) && (diag["step"] = maximum(steps))
        string(get(dv, "type", "")) == "pcomp_ply_angle" && (diag["angle_unit"] = "degree")
        diagnostics[dv_id] = diag
    end

    return Dict{String,Any}(
        "response" => "compliance",
        "value" => compliance,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => "tacs_formulation_design_tangent",
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
    )
end

function static_displacement_thickness_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict; pids=nothing)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    string(get(response, "type", "")) == "displacement" ||
        error("TACS static displacement gradient requires a displacement response spec.")
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("TACS static displacement gradient requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("TACS static displacement gradient requires stored analysis displacement vector.")

    id_map = results["id_map"]
    X = results["node_coords"]
    node_R = results["node_R"]
    ndof = Int(results["ndof"])
    response_value = Solver.evaluate_response(response, u, model, id_map, ndof, X, node_R)
    dr_du_full = Solver.compute_dr_du(response, u, model, id_map, ndof, X, node_R)
    fixed_dofs = Int.(get(subcase, "fixed_dofs", Int[]))
    free_dofs = sort!(collect(setdiff(1:ndof, fixed_dofs)))
    K_ff = results["K"][free_dofs, free_dofs]
    lambda_f = cholesky(Symmetric(K_ff)) \ dr_du_full[free_dofs]
    lambda_full = zeros(Float64, ndof)
    lambda_full[free_dofs] = lambda_f

    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))
    gradients = Dict{String,Float64}()
    for pid in pid_list
        dK, _, _, _, _, _, _, _, _ = _tacs_assemble_sol101(model; thickness_derivative_pid=pid)
        gradients[string(pid)] = -dot(lambda_full, dK * u)
    end
    return Dict{String,Any}(
        "response" => "displacement",
        "grid" => Int(response["grid"]),
        "dof" => Int(response["dof"]),
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_element_ad_adjoint",
        "subcase_index" => 1,
    )
end

function static_displacement_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    string(get(response, "type", "")) == "displacement" ||
        error("TACS static displacement design gradient requires a displacement response spec.")
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("TACS static displacement design gradient requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("TACS static displacement design gradient requires stored analysis displacement vector.")

    id_map = results["id_map"]
    X = results["node_coords"]
    node_R = results["node_R"]
    ndof = Int(results["ndof"])
    response_value = Solver.evaluate_response(response, u, model, id_map, ndof, X, node_R)
    dr_du_full = Solver.compute_dr_du(response, u, model, id_map, ndof, X, node_R)
    fixed_dofs = Int.(get(subcase, "fixed_dofs", Int[]))
    free_dofs = sort!(collect(setdiff(1:ndof, fixed_dofs)))
    K_ff = results["K"][free_dofs, free_dofs]
    lambda_f = cholesky(Symmetric(K_ff)) \ dr_du_full[free_dofs]
    lambda_full = zeros(Float64, ndof)
    lambda_full[free_dofs] = lambda_f

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        gradients[dv_id] = -dot(lambda_full, dK * u)
        diag = Dict{String,Any}(
            "type" => string(get(dv, "type", "")),
            "pids" => Int.(collect(get(dv, "pids", Int[]))),
            "gradient_backend" => "tacs_formulation_design_tangent_adjoint",
        )
        haskey(dv, "ply_index") && (diag["ply_index"] = Int(dv["ply_index"]))
        !isempty(steps) && (diag["step"] = maximum(steps))
        string(get(dv, "type", "")) == "pcomp_ply_angle" && (diag["angle_unit"] = "degree")
        diagnostics[dv_id] = diag
    end

    return Dict{String,Any}(
        "response" => "displacement",
        "grid" => Int(response["grid"]),
        "dof" => Int(response["dof"]),
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => "tacs_formulation_design_tangent_adjoint",
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
    )
end

function static_ks_von_mises_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    string(get(response, "type", "")) == "ks_von_mises" ||
        error("TACS static stress gradient requires a ks_von_mises response spec.")
    subcases = get(results, "subcases", Any[])
    isempty(subcases) && error("TACS static stress gradient requires at least one SOL101 subcase result.")
    subcase = subcases[1]
    u = Float64.(get(subcase, "u_analysis", get(subcase, "raw_displacement", Float64[])))
    isempty(u) && error("TACS static stress gradient requires stored analysis displacement vector.")

    id_map = results["id_map"]
    X = results["node_coords"]
    node_R = results["node_R"]
    ndof = Int(results["ndof"])
    response_value = Solver.evaluate_response(response, u, model, id_map, ndof, X, node_R)
    dr_du_full = Solver.compute_dr_du(response, u, model, id_map, ndof, X, node_R)
    fixed_dofs = Int.(get(subcase, "fixed_dofs", Int[]))
    free_dofs = sort!(collect(setdiff(1:ndof, fixed_dofs)))
    K_ff = results["K"][free_dofs, free_dofs]
    lambda_f = cholesky(Symmetric(K_ff)) \ dr_du_full[free_dofs]
    lambda_full = zeros(Float64, ndof)
    lambda_full[free_dofs] = lambda_f

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        explicit = Solver.compute_dr_dx_explicit(response, dv, model, id_map, X, node_R, u, ndof)
        explicit_value = sum(Float64(v) for v in values(explicit))
        gradients[dv_id] = explicit_value - dot(lambda_full, dK * u)
        diag = Dict{String,Any}(
            "type" => string(get(dv, "type", "")),
            "pids" => Int.(collect(get(dv, "pids", Int[]))),
            "gradient_backend" => "tacs_formulation_stress_adjoint_design_tangent",
            "explicit_derivative" => explicit_value,
        )
        haskey(dv, "ply_index") && (diag["ply_index"] = Int(dv["ply_index"]))
        !isempty(steps) && (diag["step"] = maximum(steps))
        string(get(dv, "type", "")) == "pcomp_ply_angle" && (diag["angle_unit"] = "degree")
        diagnostics[dv_id] = diag
    end

    return Dict{String,Any}(
        "response" => "ks_von_mises",
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => "tacs_formulation_stress_adjoint_design_tangent",
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
        "ks_rho" => Float64(get(response, "rho", 50.0)),
        "sigma_ref" => Float64(get(response, "sigma_ref", 1.0)),
    )
end

function _tacs_model_with_shell_property_thickness(model::AbstractDict, pid::Integer, value::Real)
    m = deepcopy(model)
    prop = get(get(m, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("TACS thickness perturbation could not find shell property $pid.")
    t = Float64(value)
    t > 0.0 || error("TACS thickness perturbation requires positive thickness; got $t for property $pid.")
    prop["T"] = t
    if uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL"
        prop["Z1"] = -0.5 * t
        prop["Z2"] = 0.5 * t
    else
        _tacs_ensure_pcomp_reference!(prop)
    end
    m["backend"] = JFEM_BACKEND_TACS
    m["SOL"] = 105
    if haskey(m, "CASE_CONTROL")
        m["CASE_CONTROL"]["SOL"] = 105
    end
    return m
end

function _tacs_sol105_static_displacement_thickness_derivative(
    results::AbstractDict,
    dK::AbstractMatrix,
)
    ndof = Int(results["ndof"])
    u_static = Float64.(get(results, "u_static", Float64[]))
    length(u_static) == ndof ||
        error("TACS buckling gradient requires stored SOL105 static displacement vector.")
    fixed_dofs = sort!(Int.(collect(get(results, "fixed_dofs", Set{Int}()))))
    free_dofs = sort!(collect(setdiff(1:ndof, fixed_dofs)))
    isempty(free_dofs) && error("TACS buckling gradient found no free DOFs.")

    K = results["K"]
    K_ff = K[free_dofs, free_dofs]
    rhs = -(dK * u_static)[free_dofs]
    du = zeros(Float64, ndof)
    du[free_dofs] = cholesky(Symmetric(K_ff)) \ rhs
    return du
end

function _tacs_sol105_geometric_stiffness_directional_derivative(
    results::AbstractDict,
    pid::Integer,
    du_static_dt::AbstractVector,
    step::Float64,
)
    model = results["model"]
    prop = get(get(model, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("TACS buckling gradient could not find shell property $pid.")
    t0 = Float64(get(prop, "T", 0.0))
    t0 > 0.0 || error("TACS buckling gradient requires positive property thickness.")
    h = step > 0.0 ? step : max(1e-6 * t0, 1e-8)
    t0 - h > 0.0 || (h = 0.5 * t0)

    u_static = Float64.(results["u_static"])
    du = Float64.(du_static_dt)
    id_map = results["id_map"]
    X = results["node_coords"]
    node_R = results["node_R"]
    ndof = Int(results["ndof"])
    snorm_normals = get(results, "snorm_normals", Dict{Int,SVector{3,Float64}}())
    rbe3_map = get(results, "rbe3_map", Dict{Int,Vector{Tuple{Int,Float64}}}())

    model_p = _tacs_model_with_shell_property_thickness(model, pid, t0 + h)
    model_m = _tacs_model_with_shell_property_thickness(model, pid, t0 - h)
    Kg_p = _tacs_assemble_sol105_geometric_stiffness(
        model_p,
        id_map,
        X,
        node_R,
        ndof,
        u_static .+ h .* du,
        snorm_normals,
        rbe3_map,
    )
    Kg_m = _tacs_assemble_sol105_geometric_stiffness(
        model_m,
        id_map,
        X,
        node_R,
        ndof,
        u_static .- h .* du,
        snorm_normals,
        rbe3_map,
    )
    return (Kg_p .- Kg_m) ./ (2.0 * h), h
end

function buckling_load_factor_thickness_gradient(::TACSFormulationBackend, results::AbstractDict; pids=nothing, mode::Integer=1)
    Int(get(results, "sol_type", 0)) == 105 ||
        error("TACS buckling load-factor gradient requires SOL105 results.")
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    mode_idx = Int(mode)
    1 <= mode_idx <= length(eigenvalues) ||
        error("TACS buckling load-factor gradient requested mode $mode_idx but only $(length(eigenvalues)) modes are available.")

    model = results["model"]
    _tacs_validate_shell_slice(model; allowed_sol_types=(105,), route_label="SOL105 buckling sensitivity")
    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))

    phi = Vector{Float64}(results["_raw_mode_shapes"][:, mode_idx])
    Kg = results["Kg"]
    lambda0 = eigenvalues[mode_idx]
    denom = dot(phi, -Kg * phi)
    abs(denom) > 1e-30 ||
        error("TACS buckling load-factor gradient found a near-zero eigenvector normalization denominator.")

    gradients = Dict{String,Float64}()
    directional_steps = Dict{String,Float64}()
    for pid in pid_list
        prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
        prop === nothing && error("TACS buckling load-factor gradient could not find shell property $pid.")
        _tacs_shell_supports_thickness_derivative(prop) ||
            error("TACS buckling load-factor thickness gradient does not support property $pid TYPE=$(get(prop, "TYPE", "?")).")
        t0 = Float64(get(prop, "T", 0.0))
        t0 > 0.0 || error("TACS buckling load-factor gradient requires positive property thickness.")
        dK, _, _, _, _, _, _, _, _ = _tacs_assemble_sol101(
            model;
            thickness_derivative_pid=pid,
            allowed_sol_types=(105,),
            route_label="SOL105 buckling sensitivity",
        )
        du_dt = _tacs_sol105_static_displacement_thickness_derivative(results, dK)
        dKg, h = _tacs_sol105_geometric_stiffness_directional_derivative(
            results,
            pid,
            du_dt,
            max(1e-6 * t0, 1e-8),
        )
        gradients[string(pid)] = dot(phi, (dK + lambda0 * dKg) * phi) / denom
        directional_steps[string(pid)] = h
    end

    return Dict{String,Any}(
        "response" => "buckling_load_factor",
        "mode" => mode_idx,
        "value" => eigenvalues[mode_idx],
        "gradient" => gradients,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_rayleigh_ad_kg_directional_fd",
        "directional_steps" => directional_steps,
        "eigen_derivative" => "rayleigh_current_mode_total_derivative",
    )
end
