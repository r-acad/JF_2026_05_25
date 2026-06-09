# adjoint.jl — Adjoint sensitivity solver for JFEM
#
# Phase 1: displacement responses, shell_thickness and material_E design variables.
# Phase 2: von Mises stress and shell force responses, explicit derivatives.
#
# Usage:
#   adjoint_results = solve_adjoint(results, adjoint_config_path)
#
# where `results` is the Dict returned by solve_model() for SOL 101.

"""
    parse_adjoint_config(json_path::String) -> Dict

Parse an adjoint_config.json file specifying responses and design variables.
"""
function parse_adjoint_config(json_path::String)
    if !isfile(json_path)
        error("[ADJOINT] Config file not found: $json_path")
    end
    config = JSON.parsefile(json_path)

    if !haskey(config, "responses") || isempty(config["responses"])
        error("[ADJOINT] Config must contain at least one response")
    end
    if !haskey(config, "design_variables") || isempty(config["design_variables"])
        error("[ADJOINT] Config must contain at least one design variable")
    end

    for resp in config["responses"]
        haskey(resp, "id") || error("[ADJOINT] Each response must have an 'id'")
        haskey(resp, "type") || error("[ADJOINT] Response '$(resp["id"])' must have a 'type'")
    end
    for dv in config["design_variables"]
        haskey(dv, "id") || error("[ADJOINT] Each design variable must have an 'id'")
        haskey(dv, "type") || error("[ADJOINT] Design variable '$(dv["id"])' must have a 'type'")
    end

    return config
end

# ============================================================================
# Shell element B-matrix and stress helpers
# ============================================================================

"""
Build Bm (3×ndof_elem) and Bb (3×ndof_elem) at element centroid for QUAD4 or TRIA3.
Returns (Bm, Bb, D) where D = E/(1-nu²) * [1 nu 0; nu 1 0; 0 0 (1-nu)/2].
"""
function _shell_centroid_B_matrices(n_nodes::Int, lc, E::Float64, nu::Float64)
    D = (E / (1 - nu^2)) .* [1.0 nu 0.0; nu 1.0 0.0; 0.0 0.0 (1-nu)/2]
    ndof_elem = n_nodes * 6

    if n_nodes == 4
        # QUAD4: shape derivative at centroid (xi=eta=0)
        dNr = SVector{4}(-0.25, 0.25, 0.25, -0.25)
        dNs = SVector{4}(-0.25, -0.25, 0.25, 0.25)
        J = [dNr'; dNs'] * lc  # 2x2 Jacobian
        invJ = inv(J)
        dN_dxy = invJ * [dNr'; dNs']  # 2x4

        Bm = zeros(3, ndof_elem)
        Bb = zeros(3, ndof_elem)
        for k in 1:4
            idx = (k-1)*6
            Bm[1, idx+1] = dN_dxy[1,k]
            Bm[2, idx+2] = dN_dxy[2,k]
            Bm[3, idx+1] = dN_dxy[2,k]
            Bm[3, idx+2] = dN_dxy[1,k]
            Bb[1, idx+5] = dN_dxy[1,k]
            Bb[2, idx+4] = -dN_dxy[2,k]
            Bb[3, idx+5] = dN_dxy[2,k]
            Bb[3, idx+4] = -dN_dxy[1,k]
        end
    else
        # TRIA3: constant strain, B is constant over element
        x, y = lc[:,1], lc[:,2]
        A = 0.5 * abs(x[1]*(y[2]-y[3]) + x[2]*(y[3]-y[1]) + x[3]*(y[1]-y[2]))
        if A < 1e-12; A = 1e-12; end
        b = [y[2]-y[3], y[3]-y[1], y[1]-y[2]] ./ (2*A)
        c = [x[3]-x[2], x[1]-x[3], x[2]-x[1]] ./ (2*A)

        Bm = zeros(3, ndof_elem)
        Bb = zeros(3, ndof_elem)
        for k in 1:3
            idx = (k-1)*6
            # Membrane: u, v DOFs
            Bm[1, idx+1] = b[k]
            Bm[2, idx+2] = c[k]
            Bm[3, idx+1] = c[k]
            Bm[3, idx+2] = b[k]
            # Bending: rx, ry DOFs
            Bb[1, idx+5] = b[k]
            Bb[2, idx+4] = -c[k]
            Bb[3, idx+5] = c[k]
            Bb[3, idx+4] = -b[k]
        end
    end

    return Bm, Bb, D
end

"""
Compute von Mises stress and its derivative for 2D plane stress.
sigma = [sxx, syy, sxy]
Returns (VM, dVM_dsigma) where dVM_dsigma is a 3-vector.
"""
function _von_mises_plane_stress(sigma)
    s1, s2, s12 = sigma[1], sigma[2], sigma[3]
    VM_sq = s1^2 + s2^2 - s1*s2 + 3*s12^2
    VM = sqrt(max(VM_sq, 1e-30))  # avoid divide-by-zero
    dVM = [2*s1 - s2, 2*s2 - s1, 6*s12] ./ (2*VM)
    return VM, dVM
end

function _pcomp_surface_z(prop, surface)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector && !isempty(ply_data) ||
        error("[ADJOINT] PCOMP stress response requires PLY_DATA.")
    z_bot = minimum(Float64(get(ply, "z_bot", 0.0)) for ply in ply_data)
    z_top = maximum(Float64(get(ply, "z_top", 0.0)) for ply in ply_data)
    token = lowercase(strip(string(surface)))
    return token in ("bottom", "bot", "lower", "z1", "minus") ? z_bot : z_top
end

function _pcomp_surface_ply(prop, surface)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector && !isempty(ply_data) ||
        error("[ADJOINT] PCOMP stress response requires PLY_DATA.")
    z = _pcomp_surface_z(prop, surface)
    z_min = minimum(Float64(get(ply, "z_bot", 0.0)) for ply in ply_data)
    z_max = maximum(Float64(get(ply, "z_top", 0.0)) for ply in ply_data)
    tol = max(abs(z_max - z_min), 1.0) * 1e-10
    if z <= z_min + tol
        return first(ply_data), z
    elseif z >= z_max - tol
        return last(ply_data), z
    end
    for ply in ply_data
        z_bot = Float64(get(ply, "z_bot", 0.0))
        z_top = Float64(get(ply, "z_top", 0.0))
        if z >= z_bot - tol && z <= z_top + tol
            return ply, z
        end
    end
    return last(ply_data), z
end

function _rotate_pcomp_response_qbar(Qbar::AbstractMatrix, ed)
    Q = Matrix{Float64}(Qbar)
    beta = Float64(get(ed, :pcomp_rotation, 0.0))
    if abs(beta) > 1e-12
        cb = cos(beta)
        sb = sin(beta)
        c2 = cb^2
        s2 = sb^2
        cs = cb * sb
        _rotate_constitutive_3x3!(Q, c2, s2, cs, s2, c2, -cs, -2cs, 2cs, c2 - s2)
    end
    return Q
end

function _shell_response_stress_matrix(ed, D_iso::AbstractMatrix, surface)
    if ed.prop_type == "PCOMP_CLT" && haskey(ed.prop, "PLY_DATA")
        ply, z = _pcomp_surface_ply(ed.prop, surface)
        return _rotate_pcomp_response_qbar(ply["Qbar"], ed), z
    end
    z = lowercase(strip(string(surface))) in ("bottom", "bot", "lower", "z1", "minus") ? -ed.h / 2 : ed.h / 2
    return D_iso, z
end

function _shell_response_stress_data(ed, Bm, Bb, D_iso, u_local, surface)
    eps_mem = Bm * u_local
    kappa = Bb * u_local
    D_stress, z = _shell_response_stress_matrix(ed, D_iso, surface)
    sigma = D_stress * (eps_mem .+ z .* kappa)
    VM, dVM_dsigma = _von_mises_plane_stress(sigma)
    return VM, dVM_dsigma, sigma, D_stress, z, eps_mem, kappa
end

function _mat8_plane_stress_q(mat::AbstractDict)
    E1 = Float64(mat["E1"])
    E2 = Float64(mat["E2"])
    nu12 = Float64(mat["NU12"])
    G12 = Float64(mat["G12"])
    nu21 = nu12 * E2 / max(E1, 1e-30)
    denom = 1.0 - nu12 * nu21
    denom > 0.0 || error("[ADJOINT] MAT8 failure response requires 1 - NU12*NU21 > 0.")
    return [
        E1 / denom          nu12 * E2 / denom  0.0;
        nu12 * E2 / denom   E2 / denom         0.0;
        0.0                 0.0                G12
    ]
end

function _pcomp_ply_material(ply::AbstractDict, mats::AbstractDict)
    mid_raw = get(ply, "mid", get(ply, "MID", nothing))
    isnothing(mid_raw) && error("[ADJOINT] PCOMP failure response requires ply material IDs.")
    mat = get(mats, string(Int(mid_raw)), nothing)
    mat === nothing && error("[ADJOINT] PCOMP failure response could not find MAT$(Int(mid_raw)).")
    return mat
end

function _mat8_failure_allowables(mat::AbstractDict)
    uppercase(string(get(mat, "TYPE", ""))) == "MAT8" ||
        error("[ADJOINT] PCOMP ply failure response currently supports MAT8 plies only.")
    XT = Float64(get(mat, "XT", 0.0))
    XC = Float64(get(mat, "XC", 0.0))
    YT = Float64(get(mat, "YT", 0.0))
    YC = Float64(get(mat, "YC", 0.0))
    S = Float64(get(mat, "S", 0.0))
    F12 = Float64(get(mat, "F12", 0.0))
    XT > 0.0 || error("[ADJOINT] MAT8 ply failure response requires positive XT.")
    XC > 0.0 || error("[ADJOINT] MAT8 ply failure response requires positive XC.")
    YT > 0.0 || error("[ADJOINT] MAT8 ply failure response requires positive YT.")
    YC > 0.0 || error("[ADJOINT] MAT8 ply failure response requires positive YC.")
    S > 0.0 || error("[ADJOINT] MAT8 ply failure response requires positive S.")
    return (XT=XT, XC=XC, YT=YT, YC=YC, S=S, F12=F12)
end

function _engineering_strain_transform_matrix(theta::Float64)
    c = cos(theta)
    s = sin(theta)
    c2 = c^2
    s2 = s^2
    cs = c * s
    return [
        c2       s2       cs;
        s2       c2      -cs;
        -2.0*cs  2.0*cs  c2 - s2
    ]
end

function _pcomp_failure_ply_indices(resp, prop)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector && !isempty(ply_data) ||
        error("[ADJOINT] PCOMP failure response requires PLY_DATA.")
    raw = get(resp, "plies", get(resp, "ply", "all"))
    if raw isa AbstractString
        token = lowercase(strip(raw))
        token == "all" && return collect(1:length(ply_data))
        parsed = tryparse(Int, token)
        parsed === nothing && error("[ADJOINT] ks_ply_failure plies must be \"all\" or integer indices.")
        raw = parsed
    end
    if raw isa Integer
        idx = Int(raw)
        1 <= idx <= length(ply_data) ||
            error("[ADJOINT] ks_ply_failure requested ply $idx but property has $(length(ply_data)) plies.")
        return [idx]
    elseif raw isa AbstractVector || raw isa Tuple
        indices = Int.(collect(raw))
        for idx in indices
            1 <= idx <= length(ply_data) ||
                error("[ADJOINT] ks_ply_failure requested ply $idx but property has $(length(ply_data)) plies.")
        end
        return indices
    end
    error("[ADJOINT] ks_ply_failure plies must be \"all\", an integer, or an integer array.")
end

function _pcomp_failure_z_values(ply::AbstractDict, surface)
    z_bot = Float64(get(ply, "z_bot", 0.0))
    z_top = Float64(get(ply, "z_top", 0.0))
    token = lowercase(strip(string(surface)))
    if token in ("mid", "middle", "center", "centroid")
        return [(z_bot + z_top) / 2.0]
    elseif token in ("top", "upper", "z2", "plus")
        return [z_top]
    elseif token in ("bottom", "bot", "lower", "z1", "minus")
        return [z_bot]
    elseif token in ("both", "all", "surfaces")
        return [z_bot, z_top]
    end
    error("[ADJOINT] ks_ply_failure surface must be mid, top, bottom, or both; got '$surface'.")
end

function _tsai_hill_failure_index(sigma12, allowables)
    s1 = Float64(sigma12[1])
    s2 = Float64(sigma12[2])
    t12 = Float64(sigma12[3])
    X = s1 >= 0.0 ? allowables.XT : allowables.XC
    Y = s2 >= 0.0 ? allowables.YT : allowables.YC
    S = allowables.S
    x2 = X^2
    y2 = Y^2
    s2_allow = S^2
    value = s1^2 / x2 - s1 * s2 / x2 + s2^2 / y2 + t12^2 / s2_allow
    deriv = [
        (2.0 * s1 - s2) / x2,
        -s1 / x2 + 2.0 * s2 / y2,
        2.0 * t12 / s2_allow,
    ]
    return value, deriv
end

function _tsai_wu_failure_index(sigma12, allowables)
    s1 = Float64(sigma12[1])
    s2 = Float64(sigma12[2])
    t12 = Float64(sigma12[3])
    F1, F2, F11, F12, F22, F66 = _tsai_wu_coefficients(allowables)
    value = F1 * s1 + F2 * s2 + F11 * s1^2 + F22 * s2^2 + 2.0 * F12 * s1 * s2 + F66 * t12^2
    deriv = [
        F1 + 2.0 * F11 * s1 + 2.0 * F12 * s2,
        F2 + 2.0 * F22 * s2 + 2.0 * F12 * s1,
        2.0 * F66 * t12,
    ]
    return value, deriv
end

function _tsai_wu_coefficients(allowables)
    F1 = (allowables.XC - allowables.XT) / (allowables.XT * allowables.XC)
    F2 = (allowables.YC - allowables.YT) / (allowables.YT * allowables.YC)
    F11 = 1.0 / (allowables.XT * allowables.XC)
    F22 = 1.0 / (allowables.YT * allowables.YC)
    F66 = 1.0 / (allowables.S^2)
    F12 = allowables.F12
    if abs(F12)^2 >= F11 * F22
        F12 = 0.0
    end
    return F1, F2, F11, F12, F22, F66
end

function _modified_tsai_wu_failure_index(sigma12, allowables)
    s1 = Float64(sigma12[1])
    s2 = Float64(sigma12[2])
    t12 = Float64(sigma12[3])
    F1, F2, F11, F12, F22, F66 = _tsai_wu_coefficients(allowables)
    b = F1 * s1 + F2 * s2
    a = F11 * s1^2 + F22 * s2^2 + 2.0 * F12 * s1 * s2 + F66 * t12^2
    discr = max(b^2 + 4.0 * a, 1e-30)
    root = sqrt(discr)
    value = 0.5 * (b + root)
    db = [F1, F2, 0.0]
    da = [
        2.0 * F11 * s1 + 2.0 * F12 * s2,
        2.0 * F22 * s2 + 2.0 * F12 * s1,
        2.0 * F66 * t12,
    ]
    deriv = 0.5 .* db .+ (b .* db .+ 2.0 .* da) ./ (2.0 * root)
    return value, deriv
end

function _ply_failure_index(criterion::AbstractString, sigma12, allowables)
    if criterion in ("tsai_hill", "tsaihill")
        return _tsai_hill_failure_index(sigma12, allowables)
    elseif criterion in ("tsai_wu", "tsaiwu")
        return _tsai_wu_failure_index(sigma12, allowables)
    elseif criterion in ("modified_tsai_wu", "modified_tsaiwu", "tsai_wu_strength_ratio", "tsaiwu_strength_ratio", "tacs_tsai_wu", "tacs_tsaiwu")
        return _modified_tsai_wu_failure_index(sigma12, allowables)
    end
    error("[ADJOINT] ks_ply_failure currently supports criterion=\"tsai_hill\", \"tsai_wu\", or \"modified_tsai_wu\".")
end

function _ks_ply_failure_items(eids::Vector{Int}, resp, u_global, model, id_map, node_coords, node_R)
    criterion = lowercase(replace(strip(string(get(resp, "criterion", "tsai_hill"))), "-" => "_"))
    criterion in ("tsai_hill", "tsaihill", "tsai_wu", "tsaiwu", "modified_tsai_wu", "modified_tsaiwu", "tsai_wu_strength_ratio", "tsaiwu_strength_ratio", "tacs_tsai_wu", "tacs_tsaiwu") ||
        error("[ADJOINT] ks_ply_failure currently supports criterion=\"tsai_hill\", \"tsai_wu\", or \"modified_tsai_wu\".")
    surface = get(resp, "surface", get(resp, "position", "mid"))
    values = Float64[]
    caches = Any[]
    for eid in eids
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        isnothing(ed) && continue
        ed.prop_type == "PCOMP_CLT" || continue
        ply_data = get(ed.prop, "PLY_DATA", nothing)
        ply_data isa AbstractVector && !isempty(ply_data) || continue

        Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
        u_elem_global = [u_global[ed.dofs[k]] for k in 1:ed.ndof_elem]
        u_local = ed.T_mat * u_elem_global
        eps_mem = Bm * u_local
        kappa = Bb * u_local

        for ply_idx in _pcomp_failure_ply_indices(resp, ed.prop)
            ply = ply_data[ply_idx]
            mat = _pcomp_ply_material(ply, model["MATs"])
            allowables = _mat8_failure_allowables(mat)
            Q12 = _mat8_plane_stress_q(mat)
            theta = deg2rad(Float64(get(ply, "theta", get(ply, "THETA", 0.0)))) +
                    Float64(get(ed, :pcomp_rotation, 0.0))
            T_eps = _engineering_strain_transform_matrix(theta)
            for z in _pcomp_failure_z_values(ply, surface)
                strain_xy = eps_mem .+ z .* kappa
                strain12 = T_eps * strain_xy
                sigma12 = Q12 * strain12
                fi, dfi_dsigma12 = _ply_failure_index(criterion, sigma12, allowables)
                push!(values, fi)
                push!(caches, (
                    ed=ed,
                    Bm=Bm,
                    Bb=Bb,
                    z=z,
                    T_eps=T_eps,
                    Q12=Q12,
                    dfi_dsigma12=dfi_dsigma12,
                    eid=eid,
                    ply_index=ply_idx,
                ))
            end
        end
    end
    isempty(values) && error("[ADJOINT] ks_ply_failure found no PCOMP/MAT8 ply failure samples.")
    return values, caches
end

function _pcomp_response_ply_step(prop::AbstractDict, ply_idx::Integer, perturb_field::Symbol)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector || error("[ADJOINT] PCOMP response derivative requires PLY_DATA.")
    1 <= ply_idx <= length(ply_data) ||
        error("[ADJOINT] PCOMP response derivative requested ply $ply_idx but property has $(length(ply_data)) plies.")
    ply = ply_data[ply_idx]
    if perturb_field == :T
        t_ply = Float64(ply["z_top"] - ply["z_bot"])
        t_ply > 0.0 || error("[ADJOINT] PCOMP ply-thickness response derivative requires positive thickness.")
        return min(max(abs(t_ply) * 1e-6, 1e-10), 0.25 * t_ply)
    end
    theta_deg = Float64(get(ply, "theta", get(ply, "THETA", 0.0)))
    return max(abs(theta_deg) * 1e-6, 1e-5)
end

function _pcomp_response_update_ply_data!(
    prop::AbstractDict,
    mats::AbstractDict,
    ply_idx::Integer,
    perturb_field::Symbol,
    delta_user::Real,
)
    ply_data = prop["PLY_DATA"]
    n_plies = length(ply_data)
    ply_t = [Float64(ply_data[k]["z_top"] - ply_data[k]["z_bot"]) for k in 1:n_plies]
    ply_theta = [deg2rad(Float64(get(ply_data[k], "theta", get(ply_data[k], "THETA", 0.0)))) for k in 1:n_plies]
    delta = perturb_field == :THETA ? deg2rad(Float64(delta_user)) : Float64(delta_user)
    if 1 <= ply_idx <= n_plies
        if perturb_field == :T
            ply_t[ply_idx] += delta
        elseif perturb_field == :THETA
            ply_theta[ply_idx] += delta
        end
    end

    total_t = sum(ply_t)
    total_t > 0.0 || error("[ADJOINT] PCOMP response perturbation produced nonpositive total thickness.")
    z_bot = -0.5 * total_t
    A = zeros(3, 3)
    B = zeros(3, 3)
    D = zeros(3, 3)
    Ash = zeros(2, 2)
    updated_ply_data = Any[]
    for k in 1:n_plies
        t = ply_t[k]
        t > 0.0 || error("[ADJOINT] PCOMP response perturbation produced nonpositive thickness for ply $k.")
        theta = ply_theta[k]
        z_top = z_bot + t
        ply = ply_data[k]
        pdata = _pcomp_ply_material_data(ply, mats)
        if isnothing(pdata)
            Qb = Matrix{Float64}(ply["Qbar"])
            Qs = Matrix{Float64}(ply["Qshear"])
        else
            Qb = _qbar_plane_stress(pdata.E1, pdata.E2, pdata.nu12, pdata.G12, theta)
            Qs = _qbar_shear(pdata.G13, pdata.G23, theta)
        end
        A .+= Qb .* (z_top - z_bot)
        B .+= Qb .* (z_top^2 - z_bot^2) / 2.0
        D .+= Qb .* (z_top^3 - z_bot^3) / 3.0
        Ash .+= Qs .* (z_top - z_bot)
        push!(updated_ply_data, Dict(
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

    Bmb = maximum(abs.(B)) > 1e-10 * max(maximum(abs.(A)), 1.0) ? B : nothing
    prop["T"] = total_t
    prop["T_REF"] = total_t
    prop["Cm"] = A
    prop["Bmb"] = Bmb
    prop["Cb"] = D
    prop["Cs"] = (5.0 / 6.0) .* Ash
    prop["Cs_raw"] = copy(Ash)
    prop["Cm_ref"] = copy(A)
    prop["Bmb_ref"] = Bmb === nothing ? nothing : copy(Bmb)
    prop["Cb_ref"] = copy(D)
    prop["Cs_ref"] = copy(prop["Cs"])
    prop["PLY_DATA"] = updated_ply_data
    return prop
end

function _pcomp_response_model_with_ply_delta(
    model::AbstractDict,
    pid::Integer,
    ply_idx::Integer,
    dv_type::AbstractString,
    delta_user::Real,
)
    m = deepcopy(model)
    prop = get(get(m, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("[ADJOINT] PCOMP response perturbation could not find shell property $pid.")
    perturb_field =
        string(dv_type) == "pcomp_ply_thickness" ? :T :
        string(dv_type) == "pcomp_ply_angle" ? :THETA :
        error("[ADJOINT] PCOMP response perturbation does not support design variable type '$dv_type'.")
    _pcomp_response_update_ply_data!(prop, m["MATs"], Int(ply_idx), perturb_field, delta_user)
    return m
end

function _pcomp_von_mises_explicit_fd(resp, dv, model, id_map, node_coords, node_R, u_global, ndof, ed)
    dv_type = string(get(dv, "type", ""))
    perturb_field = dv_type == "pcomp_ply_thickness" ? :T : :THETA
    ply_idx = Int(get(dv, "ply_index", 0))
    prop = ed.prop
    h = _pcomp_response_ply_step(prop, ply_idx, perturb_field)
    model_p = _pcomp_response_model_with_ply_delta(model, parse(Int, ed.pid_str), ply_idx, dv_type, h)
    model_m = _pcomp_response_model_with_ply_delta(model, parse(Int, ed.pid_str), ply_idx, dv_type, -h)
    r_plus = evaluate_response(resp, u_global, model_p, id_map, ndof, node_coords, node_R)
    r_minus = evaluate_response(resp, u_global, model_m, id_map, ndof, node_coords, node_R)
    return (r_plus - r_minus) / (2.0 * h)
end

function _pcomp_ply_failure_explicit_fd(resp, dv, model, id_map, node_coords, node_R, u_global, ndof, pid::Integer)
    dv_type = string(get(dv, "type", ""))
    perturb_field =
        dv_type == "pcomp_ply_thickness" ? :T :
        dv_type == "pcomp_ply_angle" ? :THETA :
        error("[ADJOINT] PCOMP failure response derivative does not support design variable type '$dv_type'.")
    ply_idx = Int(get(dv, "ply_index", 0))
    prop = get(get(model, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("[ADJOINT] PCOMP failure response derivative could not find shell property $pid.")
    uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || return 0.0
    h = _pcomp_response_ply_step(prop, ply_idx, perturb_field)
    model_p = _pcomp_response_model_with_ply_delta(model, Int(pid), ply_idx, dv_type, h)
    model_m = _pcomp_response_model_with_ply_delta(model, Int(pid), ply_idx, dv_type, -h)
    r_plus = evaluate_response(resp, u_global, model_p, id_map, ndof, node_coords, node_R)
    r_minus = evaluate_response(resp, u_global, model_m, id_map, ndof, node_coords, node_R)
    return (r_plus - r_minus) / (2.0 * h)
end

function _failure_strength_field(dv_type::AbstractString)
    token = uppercase(strip(replace(lowercase(dv_type), "material_" => "")))
    token in ("XT", "XC", "YT", "YC", "S", "F12") ||
        error("[ADJOINT] ks_ply_failure strength derivative does not support design variable type '$dv_type'.")
    return token
end

function _failure_strength_step(mat::AbstractDict, field::AbstractString)
    value = Float64(get(mat, field, 0.0))
    if field == "F12"
        E1 = Float64(get(mat, "E1", 0.0))
        E2 = Float64(get(mat, "E2", 0.0))
        if E1 > 0.0 && E2 > 0.0
            allowables = _mat8_failure_allowables(mat)
            _, _, F11, _, F22, _ = _tsai_wu_coefficients(allowables)
            return max(abs(value) * 1e-6, sqrt(F11 * F22) * 1e-6)
        end
        return max(abs(value) * 1e-6, 1e-18)
    end
    value > 0.0 || error("[ADJOINT] MAT8 strength derivative requires positive $field.")
    return min(max(abs(value) * 1e-6, 1e-3), 0.25 * value)
end

function _failure_strength_model_with_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = get(get(m, "MATs", Dict()), string(Int(mid)), nothing)
    mat === nothing && error("[ADJOINT] MAT8 strength derivative could not find material $mid.")
    uppercase(string(get(mat, "TYPE", ""))) == "MAT8" ||
        error("[ADJOINT] ks_ply_failure strength derivative supports MAT8 materials only.")
    value = Float64(get(mat, field, 0.0)) + Float64(delta)
    if field != "F12"
        value > 0.0 || error("[ADJOINT] MAT8 strength perturbation produced nonpositive $field.")
    end
    mat[field] = value
    return m
end

function _failure_strength_explicit_fd(resp, dv, model, id_map, node_coords, node_R, u_global, ndof, mid::Integer)
    dv_type = string(get(dv, "type", ""))
    field = _failure_strength_field(dv_type)
    mat = get(get(model, "MATs", Dict()), string(Int(mid)), nothing)
    mat === nothing && error("[ADJOINT] MAT8 strength derivative could not find material $mid.")
    h = _failure_strength_step(mat, field)
    model_p = _failure_strength_model_with_delta(model, Int(mid), field, h)
    model_m = _failure_strength_model_with_delta(model, Int(mid), field, -h)
    r_plus = evaluate_response(resp, u_global, model_p, id_map, ndof, node_coords, node_R)
    r_minus = evaluate_response(resp, u_global, model_m, id_map, ndof, node_coords, node_R)
    return (r_plus - r_minus) / (2.0 * h)
end

"""
    _ks_aggregate(g::AbstractVector{<:Real}; rho::Real = 50.0) -> (ks_value, weights)

Kreisselmeier–Steinhauser aggregation of a constraint vector. Returns the
scalar smooth-max and the softmax weight vector w = exp(ρ(g - g_max)) / Σ.

  KS(g) = g_max + (1/ρ) ln(Σ_i exp(ρ (g_i - g_max)))
  dKS/dg_i = w_i

This is the numerically stable form (subtracting g_max before exp) that
TACS, OpenMDAO and ParOpt all use. As ρ → ∞, KS → max(g). For typical
stress-constraint use ρ ∈ [25, 200]; the default 50 is a TACS-style
sweet spot for ~1000-element shells.
"""
function _ks_aggregate(g::AbstractVector{<:Real}; rho::Real = 50.0)
    isempty(g) && return 0.0, Float64[]
    g_max = maximum(g)
    e = [exp(rho * (gi - g_max)) for gi in g]
    s = sum(e)
    ks_value = g_max + log(s) / rho
    w = e ./ s
    return ks_value, w
end

function _int_vector_from_response(value)
    if value isa AbstractVector || value isa Tuple
        return Int.(collect(value))
    end
    return [Int(value)]
end

function _ks_displacement_entries(resp, model, id_map)
    raw_grids =
        haskey(resp, "grids") ? resp["grids"] :
        haskey(resp, "grid") ? [resp["grid"]] :
        sort!(Int.(parse.(Int, string.(collect(keys(get(model, "GRIDs", Dict())))))))
    grids = _int_vector_from_response(raw_grids)
    raw_dofs =
        haskey(resp, "dofs") ? resp["dofs"] :
        haskey(resp, "components") ? resp["components"] :
        haskey(resp, "dof") ? [resp["dof"]] :
        [3]
    dofs = _int_vector_from_response(raw_dofs)
    isempty(grids) && error("[ADJOINT] ks_displacement response requires at least one GRID.")
    isempty(dofs) && error("[ADJOINT] ks_displacement response requires at least one dof/component.")

    entries = Int[]
    for grid in grids
        haskey(id_map, grid) || error("[ADJOINT] GRID $grid not found for ks_displacement response.")
        idx = id_map[grid]
        for dof in dofs
            1 <= dof <= 6 || error("[ADJOINT] ks_displacement dof must be in 1:6; got $dof.")
            push!(entries, (idx - 1) * 6 + dof)
        end
    end
    return entries
end

function _ks_displacement_data(resp, u_global, model, id_map)
    entries = _ks_displacement_entries(resp, model, id_map)
    rho = Float64(get(resp, "rho", 50.0))
    rho > 0.0 || error("[ADJOINT] ks_displacement rho must be positive.")
    scale = Float64(get(resp, "scale", 1.0))
    ref = Float64(get(resp, "displacement_ref", get(resp, "ref", 1.0)))
    ref > 0.0 || error("[ADJOINT] ks_displacement displacement_ref/ref must be positive.")
    values = [scale * Float64(u_global[dof]) / ref for dof in entries]
    ks_value, weights = _ks_aggregate(values; rho=rho)
    return ks_value, weights, entries, scale, ref
end

"""
    _ks_resolve_eids(resp, model) -> Vector{Int}

Resolve the EID list from a `ks_von_mises` response definition. Accepts
either an explicit `eids` array or the sentinel `"all"`, which expands to
every supported shell/beam EID in the model.
"""
function _ks_resolve_eids(resp, model)
    raw = get(resp, "eids", nothing)
    if raw === nothing
        error("[ADJOINT] ks_von_mises response requires `eids` (array or \"all\")")
    end
    if raw isa AbstractString && lowercase(strip(raw)) == "all"
        ids = Int[]
        for group_name in ("CSHELLs", "CBARs", "CBEAMs")
            for (key, el) in get(model, group_name, Dict())
                push!(ids, _stress_entry_public_id(key, el))
            end
        end
        return sort!(unique(ids))
    end
    # Accept both numeric and string EIDs in the input array. JSON-driven
    # adjoint configs sometimes serialise integer EIDs as strings.
    return Int[(x isa AbstractString ? parse(Int, x) : Int(x)) for x in raw]
end

function _beam_lookup(eid::Int, model)
    eid_str = string(eid)
    beam = get(get(model, "CBARs", Dict()), eid_str, nothing)
    beam !== nothing && return beam
    beam = get(get(model, "CBEAMs", Dict()), eid_str, nothing)
    beam !== nothing && return beam
    for group_name in ("CBARs", "CBEAMs")
        for (key, candidate) in get(model, group_name, Dict())
            _stress_entry_public_id(key, candidate) == eid && return candidate
        end
    end
    return nothing
end

function _beam_response_list(raw, default_values::Vector{T}) where {T}
    raw === nothing && return copy(default_values)
    values =
        raw isa AbstractString ? begin
            token = lowercase(strip(raw))
            token in ("all", "both") && return copy(default_values)
            [token]
        end :
        (raw isa AbstractVector || raw isa Tuple) ? collect(raw) :
        [raw]
    parsed = T[]
    for value in values
        if T === String
            push!(parsed, lowercase(strip(string(value))))
        else
            push!(parsed, value isa AbstractString ? parse(T, strip(value)) : T(value))
        end
    end
    return parsed
end

function _beam_stress_sample_specs(resp; default_all::Bool=true)
    ends_raw = get(resp, "beam_ends", get(resp, "beam_end", nothing))
    points_raw = get(resp, "beam_points", get(resp, "beam_point", nothing))
    default_ends = default_all ? ["a", "b"] : ["a"]
    default_points = default_all ? [1, 2, 3, 4] : [1]
    ends = _beam_response_list(ends_raw, default_ends)
    points = _beam_response_list(points_raw, default_points)
    specs = Any[]
    for e in ends
        end_token = lowercase(strip(string(e)))
        end_token in ("a", "end_a", "ga", "1") && (end_token = "a")
        end_token in ("b", "end_b", "gb", "2") && (end_token = "b")
        end_token in ("a", "b") || error("[ADJOINT] beam_end must be a/b/both; got '$e'.")
        for p in points
            p_int = Int(p)
            1 <= p_int <= 4 || error("[ADJOINT] beam_point must be in 1:4; got $p_int.")
            push!(specs, (beam_end=end_token, beam_point=p_int))
        end
    end
    isempty(specs) && error("[ADJOINT] beam stress response selected no beam stress samples.")
    return specs
end

@inline function _beam_frame_force_dict_from_local(f_local)
    return (
        axial=f_local[7],
        shear_1=-f_local[2],
        shear_2=-f_local[3],
        torque=-f_local[4],
        moment_a1=-f_local[6],
        moment_a2=f_local[5],
        moment_b1=f_local[12],
        moment_b2=-f_local[11],
    )
end

@inline function _beam_surface_stress_sign(prop)
    section_type = uppercase(string(get(prop, "TYPE", "")))
    return section_type in ("ROD", "TUBE", "TUBE2") ? 1.0 : -1.0
end

function _beam_surface_force_coefficients(prop, sample, A::Float64, Iy::Float64, Iz::Float64, I12::Float64)
    coeff = zeros(Float64, 12)
    coeff[7] += 1.0 / max(A, 1e-30)
    pts = (
        (Float64(get(prop, "C1", 0.0)), Float64(get(prop, "C2", 0.0))),
        (Float64(get(prop, "D1", 0.0)), Float64(get(prop, "D2", 0.0))),
        (Float64(get(prop, "E1", 0.0)), Float64(get(prop, "E2", 0.0))),
        (Float64(get(prop, "F1", 0.0)), Float64(get(prop, "F2", 0.0))),
    )
    yj, zj = pts[Int(sample.beam_point)]
    bend_sign = _beam_surface_stress_sign(prop)
    denom = Iz * Iy - I12^2
    c_m1 = 0.0
    c_m2 = 0.0
    if abs(denom) > 1e-30
        c_m1 = bend_sign * (Iy * yj - I12 * zj) / denom
        c_m2 = bend_sign * (-I12 * yj + Iz * zj) / denom
    else
        c_m1 = bend_sign * yj / max(Iz, 1e-30)
        c_m2 = bend_sign * zj / max(Iy, 1e-30)
    end
    if sample.beam_end == "a"
        coeff[6] += -c_m1
        coeff[5] += c_m2
    else
        coeff[12] += c_m1
        coeff[11] += -c_m2
    end
    return coeff
end

function _get_beam_element_data(eid::Int, model, id_map, node_coords, node_R, resp=nothing)
    beam = _beam_lookup(eid, model)
    beam === nothing && return nothing
    pid_str = string(Int(get(beam, "PID", 0)))
    prop = get(get(model, "PBARLs", Dict()), pid_str, nothing)
    prop === nothing && return nothing
    prop_type = uppercase(strip(string(get(prop, "TYPE", "PBAR"))))
    if prop_type == "PBEAM" || haskey(prop, "STATIONS")
        error("[ADJOINT] beam stress sensitivities currently support constant PBAR/PBARL-style CBAR/CBEAM properties only.")
    end
    mid_str = string(Int(get(prop, "MID", 0)))
    mat = _effective_mat1_for_nodes(model, mid_str, [Int(get(beam, "GA", 0)), Int(get(beam, "GB", 0))])
    mat === nothing && return nothing
    ga = Int(get(beam, "GA", 0))
    gb = Int(get(beam, "GB", 0))
    haskey(id_map, ga) && haskey(id_map, gb) || return nothing
    node_coords === nothing && (node_coords = _rebuild_node_coords(model, id_map))
    node_R === nothing && error("[ADJOINT] beam stress response requires node rotation matrices.")
    i1, i2 = id_map[ga], id_map[gb]
    p1 = SVector{3,Float64}(node_coords[i1, 1], node_coords[i1, 2], node_coords[i1, 3])
    p2 = SVector{3,Float64}(node_coords[i2, 1], node_coords[i2, 2], node_coords[i2, 3])
    wa, wb, has_offset, p1_eff, p2_eff = bar_offsets_and_endpoints(beam, p1, p2)
    axis = p2_eff - p1_eff
    L = norm(axis)
    L > 1e-9 || return nothing
    vx = axis / L
    v_ref = resolve_bar_vref(beam, p1, id_map, node_coords)
    if norm(v_ref) < 1e-6
        v_ref = SVector{3,Float64}(0.0, 0.0, 1.0)
        abs(dot(vx, v_ref)) > 0.9 && (v_ref = SVector{3,Float64}(0.0, 1.0, 0.0))
    end
    vz = normalize(cross(vx, v_ref))
    vy = cross(vz, vx)
    Rel_t = vcat(vx', vy', vz')

    T12 = zeros(Float64, 12, 12)
    TR1 = Rel_t * node_R[i1]
    TR2 = Rel_t * node_R[i2]
    T12[1:3, 1:3] = TR1
    T12[4:6, 4:6] = TR1
    T12[7:9, 7:9] = TR2
    T12[10:12, 10:12] = TR2
    if has_offset
        T12[1:3, 4:6] = -Rel_t * skew3(wa) * node_R[i1]
        T12[7:9, 10:12] = -Rel_t * skew3(wb) * node_R[i2]
    end
    dofs = Vector{Int}(undef, 12)
    for d in 1:6
        dofs[d] = (i1 - 1) * 6 + d
        dofs[6 + d] = (i2 - 1) * 6 + d
    end
    Iy, Iz = _bar_bending_inertias(prop)
    I12 = Float64(get(prop, "I12", 0.0))
    A = Float64(get(prop, "A", 0.0))
    J = Float64(get(prop, "J", 0.0))
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))
    As_y = K1 > 0.0 ? K1 * A : Inf
    As_z = K2 > 0.0 ? K2 * A : Inf
    Ke_loc = FEM.stiffness_frame3d(
        L, A, Iy, Iz, J, Float64(mat["E"]), Float64(mat["G"]);
        As_y=As_y,
        As_z=As_z,
        I12=I12,
    )
    pa = Int(get(beam, "PA", 0))
    pb = Int(get(beam, "PB", 0))
    if pa != 0 || pb != 0
        Ke_loc = Matrix(Ke_loc)
        apply_bar_pin_flags!(Ke_loc, pa, pb)
    end
    active_load_id = resp === nothing ? nothing : get(resp, "active_load_id", get(resp, "load_id", nothing))
    active_load_scale = resp === nothing ? 1.0 : Float64(get(resp, "active_load_scale", get(resp, "load_scale", 1.0)))
    fixed_end_load = _beam_pload1_local_load_vector_for_sid(model, eid, active_load_id, L, active_load_scale)
    return (
        eid=eid,
        beam=beam,
        prop=prop,
        mat=mat,
        pid_str=pid_str,
        mid_str=mid_str,
        A=A,
        Iy=Iy,
        Iz=Iz,
        I12=I12,
        L=L,
        Ke_loc=Matrix{Float64}(Ke_loc),
        fixed_end_load=Vector{Float64}(fixed_end_load),
        T12=T12,
        dofs=dofs,
        ndof_elem=12,
    )
end

function _beam_stress_sample_value_and_cache(bd, sample, u_global, resp)
    u_elem_global = [Float64(u_global[d]) for d in bd.dofs]
    u_local = bd.T12 * u_elem_global
    f_local = bd.Ke_loc * u_local - bd.fixed_end_load
    coeff = _beam_surface_force_coefficients(bd.prop, sample, bd.A, bd.Iy, bd.Iz, bd.I12)
    normal = dot(coeff, f_local)
    vm = sqrt(normal^2 + 1e-30)
    dvm_dnormal = normal / vm
    response = Dict{String,Any}(
        "type" => "von_mises",
        "eid" => bd.eid,
        "surface" => get(resp, "surface", "top"),
        "beam_end" => sample.beam_end,
        "beam_point" => sample.beam_point,
    )
    haskey(resp, "load_id") && (response["load_id"] = resp["load_id"])
    haskey(resp, "active_load_id") && (response["active_load_id"] = resp["active_load_id"])
    haskey(resp, "load_scale") && (response["load_scale"] = resp["load_scale"])
    haskey(resp, "active_load_scale") && (response["active_load_scale"] = resp["active_load_scale"])
    cache = (
        kind=:beam,
        response=response,
        bd=bd,
        coeff=coeff,
        normal_stress=normal,
        dvm_dnormal=dvm_dnormal,
        f_local=f_local,
        sample=sample,
    )
    return vm, cache
end

"""
    _ks_vm_per_element(eids, surface, u_global, model, id_map, node_coords, node_R)
        -> (VM_vec, per_element_cache)

Evaluate per-element von Mises stress at the requested surface for the
given EID list. Returns the stress vector plus a cache of element data
(ed, B-matrices, σ, dVM_dσ) so the adjoint pass can reuse them without
re-fetching geometry/material.

Elements that cannot be resolved (missing PID, etc.) get VM=0 and a
nothing cache slot — the KS weight on those entries will be vanishingly
small.
"""
function _ks_vm_per_element(eids::Vector{Int}, surface::AbstractString,
                            u_global, model, id_map, node_coords, node_R,
                            response_spec=nothing)
    VM_vec = Float64[]
    caches = Any[]
    sizehint!(VM_vec, length(eids))
    sizehint!(caches, length(eids))
    resp = response_spec === nothing ? Dict{String,Any}("type" => "ks_von_mises", "surface" => surface) : response_spec
    for eid in eids
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        if ed !== nothing
            Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
            u_elem_global = [u_global[ed.dofs[k]] for k in 1:ed.ndof_elem]
            u_local = ed.T_mat * u_elem_global
            VM, dVM_dsigma, sigma, D_stress, z, eps_mem, kappa =
                _shell_response_stress_data(ed, Bm, Bb, D, u_local, surface)
            push!(VM_vec, VM)
            push!(caches, (kind=:shell, response=Dict{String,Any}("type" => "von_mises", "eid" => eid, "surface" => surface),
                           ed=ed, Bm=Bm, Bb=Bb, D=D_stress, sigma=sigma, dVM_dsigma=dVM_dsigma,
                           eps_mem=eps_mem, kappa=kappa, z=z))
            continue
        end
        bd = _get_beam_element_data(eid, model, id_map, node_coords, node_R, resp)
        if bd !== nothing
            for sample in _beam_stress_sample_specs(resp; default_all=true)
                vm, cache = _beam_stress_sample_value_and_cache(bd, sample, u_global, resp)
                push!(VM_vec, vm)
                push!(caches, cache)
            end
            continue
        end
        push!(VM_vec, 0.0)
        push!(caches, nothing)
    end
    return VM_vec, caches
end

"""
Look up the shell element data (coords, E, nu, h, T matrix, DOF indices)
needed for stress response evaluation at element `eid`.
Returns a NamedTuple or nothing if element not found.
"""
function _get_shell_element_data(eid::Int, model, id_map, node_coords, node_R)
    eid_str = string(eid)
    if !haskey(model["CSHELLs"], eid_str); return nothing; end
    el = model["CSHELLs"][eid_str]
    pid_str = string(el["PID"])
    pshells = model["PSHELLs"]
    if !haskey(pshells, pid_str); return nothing; end
    prop = pshells[pid_str]
    prop_type = uppercase(string(get(prop, "TYPE", "PSHELL")))
    mid_str = string(prop["MID"])
    mats = model["MATs"]
    if !haskey(mats, mid_str); return nothing; end
    mat = mats[mid_str]

    nids = el["NODES"]
    n_nodes = length(nids)
    if !all(n -> haskey(id_map, n), nids); return nothing; end
    idxs = [id_map[n] for n in nids]

    h = Float64(prop["T"])
    E = Float64(mat["E"])
    nu = Float64(mat["NU"])

    # Build coordinates and local frame
    ps = [SVector{3}(node_coords[idx,1], node_coords[idx,2], node_coords[idx,3]) for idx in idxs]
    if n_nodes == 4
        v1, v2, v3 = shell_element_frame_fast(ps[1], ps[2], ps[3], ps[4], 4)
    else
        v1, v2, v3 = shell_element_frame_fast(ps[1], ps[2], ps[3], SVector{3}(0.0,0.0,0.0), 3)
    end

    pcomp_rotation = 0.0
    if prop_type == "PCOMP_CLT"
        theta_rad = deg2rad(Float64(get(el, "THETA", 0.0)))
        mcid = Int(get(el, "MCID", 0))
        mode = q4_pcomp_axis_mode("JFEM_Q4_PCOMP_AXIS_MODE_STATIC")
        pcomp_rotation =
            n_nodes == 4 ?
            shell_pcomp_material_rotation(mode, v1, v2, v3, ps[1], ps[2], ps[3], ps[4], theta_rad, mcid, model["CORDs"]) :
            shell_pcomp_material_rotation(mode, v1, v2, v3, ps[1], ps[2], theta_rad, mcid, model["CORDs"])
    end

    c_center = sum(ps) / n_nodes
    lc = zeros(n_nodes, 2)
    for k in 1:n_nodes
        dp = ps[k] - c_center
        lc[k,1] = dot(dp, v1); lc[k,2] = dot(dp, v2)
    end

    # Rotation matrix
    ndof_elem = n_nodes * 6
    T_mat = zeros(ndof_elem, ndof_elem)
    Rel = [v1[1] v1[2] v1[3]; v2[1] v2[2] v2[3]; v3[1] v3[2] v3[3]]
    for k in 1:n_nodes
        TR = Rel * node_R[idxs[k]]
        base = (k-1)*6
        T_mat[base+1:base+3, base+1:base+3] = TR
        T_mat[base+4:base+6, base+4:base+6] = TR
    end

    # Global DOF indices
    dofs = Vector{Int}(undef, ndof_elem)
    for k in 1:n_nodes
        base_g = (idxs[k]-1)*6; base_e = (k-1)*6
        for d in 1:6; dofs[base_e+d] = base_g+d; end
    end

    return (n_nodes=n_nodes, lc=lc, E=E, nu=nu, h=h, T_mat=T_mat, dofs=dofs,
            idxs=idxs, pid_str=pid_str, mid_str=mid_str, ndof_elem=ndof_elem,
            prop=prop, prop_type=prop_type, pcomp_rotation=pcomp_rotation)
end

# ============================================================================
# Response evaluation
# ============================================================================

"""
    evaluate_response(resp, u_global, model, id_map, ndof, node_coords, node_R) -> Float64

Evaluate the scalar response function value.
Supports: displacement, von_mises, shell_force_nx/ny/nxy, shell_moment_mx/my.
"""
function evaluate_response(resp, u_global, model, id_map, ndof, node_coords=nothing, node_R=nothing)
    rtype = resp["type"]

    if rtype == "displacement"
        grid = Int(resp["grid"]); dof = Int(resp["dof"])
        idx = id_map[grid]
        return u_global[(idx-1)*6 + dof]

    elseif rtype == "von_mises"
        eid = Int(resp["eid"])
        surface = get(resp, "surface", "top")  # "top" or "bottom"
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        if ed !== nothing
            Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
            u_elem_global = [u_global[ed.dofs[i]] for i in 1:ed.ndof_elem]
            u_local = ed.T_mat * u_elem_global

            VM, _, _, _, _, _, _ = _shell_response_stress_data(ed, Bm, Bb, D, u_local, surface)
            return VM
        end

        bd = _get_beam_element_data(eid, model, id_map, node_coords, node_R, resp)
        bd !== nothing || error("[ADJOINT] Element $eid not found for von_mises response")
        sample = first(_beam_stress_sample_specs(resp; default_all=false))
        VM, _ = _beam_stress_sample_value_and_cache(bd, sample, u_global, resp)
        return VM

    elseif startswith(rtype, "shell_force_") || startswith(rtype, "shell_moment_")
        eid = Int(resp["eid"])
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        isnothing(ed) && error("[ADJOINT] Element $eid not found for $rtype response")

        Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
        u_elem_global = [u_global[ed.dofs[i]] for i in 1:ed.ndof_elem]
        u_local = ed.T_mat * u_elem_global

        if startswith(rtype, "shell_force_")
            Cm = D * ed.h
            eps_mem = Bm * u_local
            N = Cm * eps_mem
            comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3
            return N[comp]
        else  # shell_moment_
            Cb = D * (ed.h^3 / 12.0)
            kappa = Bb * u_local
            M = -Cb * kappa
            comp = rtype == "shell_moment_mx" ? 1 : 2
            return M[comp]
        end

    elseif rtype == "ks_displacement"
        ks_value, _, _, _, _ = _ks_displacement_data(resp, u_global, model, id_map)
        return ks_value

    elseif rtype == "ks_von_mises"
        # KS-aggregated von Mises stress over a list of shell EIDs.
        # Inspired by TACS TACSKSFailure. Reduces a per-element stress
        # constraint family to a single differentiable scalar, suitable
        # for SOL 200-lite DCONSTR upper bounds.
        eids = _ks_resolve_eids(resp, model)
        surface = get(resp, "surface", "top")
        rho = Float64(get(resp, "rho", 50.0))
        sigma_ref = Float64(get(resp, "sigma_ref", 1.0))
        VM_vec, _ = _ks_vm_per_element(eids, surface, u_global, model,
                                       id_map, node_coords, node_R, resp)
        ks_value, _ = _ks_aggregate(VM_vec ./ sigma_ref; rho=rho)
        return ks_value
    elseif rtype == "ks_ply_failure"
        eids = _ks_resolve_eids(resp, model)
        rho = Float64(get(resp, "rho", 50.0))
        failure_ref = Float64(get(resp, "failure_ref", get(resp, "ref", 1.0)))
        failure_ref > 0.0 || error("[ADJOINT] ks_ply_failure failure_ref/ref must be positive.")
        values, _ = _ks_ply_failure_items(eids, resp, u_global, model,
                                          id_map, node_coords, node_R)
        ks_value, _ = _ks_aggregate(values ./ failure_ref; rho=rho)
        return ks_value
    else
        error("[ADJOINT] Unsupported response type: $rtype")
    end
end

# ============================================================================
# dr/du computation (adjoint RHS)
# ============================================================================

"""
    compute_dr_du(resp, u_global, model, id_map, ndof, node_coords, node_R) -> Vector{Float64}

Compute dr/du — the adjoint RHS vector.
"""
function compute_dr_du(resp, u_global, model, id_map, ndof, node_coords=nothing, node_R=nothing)
    rtype = resp["type"]

    if rtype == "displacement"
        grid = Int(resp["grid"]); dof = Int(resp["dof"])
        idx = id_map[grid]
        dr_du = zeros(ndof)
        dr_du[(idx-1)*6 + dof] = 1.0
        return dr_du

    elseif rtype == "von_mises"
        eid = Int(resp["eid"])
        surface = get(resp, "surface", "top")
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        if ed !== nothing
            Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
            u_elem_global = [u_global[ed.dofs[i]] for i in 1:ed.ndof_elem]
            u_local = ed.T_mat * u_elem_global

            _, dVM_dsigma, _, D_stress, z, _, _ =
                _shell_response_stress_data(ed, Bm, Bb, D, u_local, surface)

            B_combined = Bm .+ z .* Bb
            dr_du_local = (dVM_dsigma' * D_stress * B_combined)'
            dr_du_elem = ed.T_mat' * dr_du_local

            dr_du = zeros(ndof)
            for i in 1:ed.ndof_elem
                dr_du[ed.dofs[i]] += dr_du_elem[i]
            end
            return dr_du
        end

        bd = _get_beam_element_data(eid, model, id_map, node_coords, node_R, resp)
        bd !== nothing || error("[ADJOINT] Element $eid not found")
        sample = first(_beam_stress_sample_specs(resp; default_all=false))
        _, cache = _beam_stress_sample_value_and_cache(bd, sample, u_global, resp)
        dVM_du_local = (cache.dvm_dnormal .* cache.coeff' * bd.Ke_loc)'
        dr_du_elem = bd.T12' * dVM_du_local
        dr_du = zeros(ndof)
        for i in 1:bd.ndof_elem
            dr_du[bd.dofs[i]] += dr_du_elem[i]
        end
        return dr_du

    elseif startswith(rtype, "shell_force_")
        eid = Int(resp["eid"])
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        isnothing(ed) && error("[ADJOINT] Element $eid not found")

        Bm, _, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
        Cm = D * ed.h
        comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3

        # dN_comp/du_local = Cm[comp,:] * Bm
        dr_du_local = (Cm[comp,:]' * Bm)'  # ndof_elem vector
        dr_du_elem = ed.T_mat' * dr_du_local

        dr_du = zeros(ndof)
        for i in 1:ed.ndof_elem
            dr_du[ed.dofs[i]] += dr_du_elem[i]
        end
        return dr_du

    elseif startswith(rtype, "shell_moment_")
        eid = Int(resp["eid"])
        ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
        isnothing(ed) && error("[ADJOINT] Element $eid not found")

        _, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
        Cb = D * (ed.h^3 / 12.0)
        comp = rtype == "shell_moment_mx" ? 1 : 2

        # M = -Cb * kappa = -Cb * Bb * u_local
        # dM_comp/du_local = -Cb[comp,:] * Bb
        dr_du_local = -(Cb[comp,:]' * Bb)'
        dr_du_elem = ed.T_mat' * dr_du_local

        dr_du = zeros(ndof)
        for i in 1:ed.ndof_elem
            dr_du[ed.dofs[i]] += dr_du_elem[i]
        end
        return dr_du

    elseif rtype == "ks_displacement"
        _, weights, entries, scale, ref = _ks_displacement_data(resp, u_global, model, id_map)
        dr_du = zeros(ndof)
        for (i, dof) in enumerate(entries)
            dr_du[dof] += weights[i] * scale / ref
        end
        return dr_du

    elseif rtype == "ks_von_mises"
        # dKS/du = Σ_i w_i · dVM_i/du / σ_ref
        # where w_i are the softmax weights from _ks_aggregate.
        eids = _ks_resolve_eids(resp, model)
        surface = get(resp, "surface", "top")
        rho = Float64(get(resp, "rho", 50.0))
        sigma_ref = Float64(get(resp, "sigma_ref", 1.0))
        VM_vec, caches = _ks_vm_per_element(eids, surface, u_global, model,
                                            id_map, node_coords, node_R, resp)
        _, w = _ks_aggregate(VM_vec ./ sigma_ref; rho=rho)

        dr_du = zeros(ndof)
        for (i, cache) in enumerate(caches)
            isnothing(cache) && continue
            w[i] == 0.0 && continue
            scale = w[i] / sigma_ref
            if get(cache, :kind, :shell) == :beam
                bd = cache.bd
                dVM_du_local = (cache.dvm_dnormal .* cache.coeff' * bd.Ke_loc)'
                dVM_du_elem = bd.T12' * dVM_du_local
                for k in 1:bd.ndof_elem
                    dr_du[bd.dofs[k]] += scale * dVM_du_elem[k]
                end
            else
                ed = cache.ed
                B_combined = cache.Bm .+ cache.z .* cache.Bb
                dVM_du_local = (cache.dVM_dsigma' * cache.D * B_combined)'
                dVM_du_elem = ed.T_mat' * dVM_du_local
                for k in 1:ed.ndof_elem
                    dr_du[ed.dofs[k]] += scale * dVM_du_elem[k]
                end
            end
        end
        return dr_du

    elseif rtype == "ks_ply_failure"
        eids = _ks_resolve_eids(resp, model)
        rho = Float64(get(resp, "rho", 50.0))
        failure_ref = Float64(get(resp, "failure_ref", get(resp, "ref", 1.0)))
        failure_ref > 0.0 || error("[ADJOINT] ks_ply_failure failure_ref/ref must be positive.")
        values, caches = _ks_ply_failure_items(eids, resp, u_global, model,
                                               id_map, node_coords, node_R)
        _, w = _ks_aggregate(values ./ failure_ref; rho=rho)

        dr_du = zeros(ndof)
        for (i, cache) in enumerate(caches)
            w[i] == 0.0 && continue
            ed = cache.ed
            B_combined = cache.Bm .+ cache.z .* cache.Bb
            dfi_dstrain_xy = cache.T_eps' * (cache.Q12' * cache.dfi_dsigma12)
            dfi_du_local = (dfi_dstrain_xy' * B_combined)'
            dfi_du_elem = ed.T_mat' * dfi_du_local
            scale = w[i] / failure_ref
            for k in 1:ed.ndof_elem
                dr_du[ed.dofs[k]] += scale * dfi_du_elem[k]
            end
        end
        return dr_du

    else
        error("[ADJOINT] Unsupported response type for dr/du: $rtype")
    end
end

# ============================================================================
# dr/dx|explicit — stress depends directly on design variables
# ============================================================================

function _beam_design_field_from_dv(dv_type)
    norm_type = lowercase(string(dv_type))
    norm_type == "beam_area" && return "A"
    norm_type == "beam_i1" && return "I1"
    norm_type == "beam_i2" && return "I2"
    norm_type == "beam_j" && return "J"
    return nothing
end

function _beam_property_value(prop::AbstractDict, field::AbstractString)
    field == "I1" && return Float64(get(prop, "I1", get(prop, "I", 0.0)))
    return Float64(get(prop, field, 0.0))
end

function _beam_selected_pids_for_dv(model, dv)
    raw_pids = get(dv, "pids", nothing)
    if raw_pids !== nothing && !isempty(raw_pids)
        return sort!(unique(Int.(collect(raw_pids))))
    end
    raw_eids = get(dv, "eids", nothing)
    eid_filter = raw_eids === nothing ? Set{Int}() : Set{Int}(Int.(collect(raw_eids)))
    pids = Set{Int}()
    for group_name in ("CBARs", "CBEAMs")
        for (key, beam) in get(model, group_name, Dict())
            eid = _stress_entry_public_id(key, beam)
            isempty(eid_filter) || eid in eid_filter || continue
            push!(pids, Int(get(beam, "PID", 0)))
        end
    end
    return sort!(collect(pids))
end

function _beam_model_with_property_delta(model, pid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    prop = get(get(m, "PBARLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("[ADJOINT] beam stress derivative could not find PBAR/PBARL property $pid.")
    value = _beam_property_value(prop, field) + Float64(delta)
    value > 0.0 || error("[ADJOINT] beam stress derivative produced nonpositive $field for property $pid.")
    prop[field] = value
    field == "I1" && (prop["I"] = value)
    return m
end

function _beam_model_with_material_delta(model, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = get(get(m, "MATs", Dict()), string(Int(mid)), nothing)
    mat === nothing && error("[ADJOINT] beam stress derivative could not find material $mid.")
    value = Float64(get(mat, field, 0.0)) + Float64(delta)
    field in ("E", "G") && value <= 0.0 &&
        error("[ADJOINT] beam stress derivative produced nonpositive MAT1 $field for material $mid.")
    field == "NU" && !(-0.49 < value < 0.49) &&
        error("[ADJOINT] beam stress derivative produced unsupported MAT1 NU=$value for material $mid.")
    mat[field] = value
    field == "NU" && haskey(mat, "E") && (mat["G"] = Float64(mat["E"]) / (2.0 * (1.0 + value)))
    return m
end

function _beam_response_fd_step(value::Real)
    v = Float64(value)
    v > 0.0 || return max(abs(v) * 1e-6, 1e-8)
    return min(max(abs(v) * 1e-6, 1e-12), 0.25 * v)
end

function _beam_response_explicit_fd(resp, dv, model, id_map, node_coords, node_R, u_global, ndof)
    dv_type = string(get(dv, "type", ""))
    field = _beam_design_field_from_dv(dv_type)
    if field !== nothing
        result = Dict{String,Float64}()
        for pid in _beam_selected_pids_for_dv(model, dv)
            prop = get(get(model, "PBARLs", Dict()), string(pid), nothing)
            prop === nothing && continue
            h = _beam_response_fd_step(_beam_property_value(prop, field))
            model_p = _beam_model_with_property_delta(model, pid, field, h)
            model_m = _beam_model_with_property_delta(model, pid, field, -h)
            r_plus = evaluate_response(resp, u_global, model_p, id_map, ndof, node_coords, node_R)
            r_minus = evaluate_response(resp, u_global, model_m, id_map, ndof, node_coords, node_R)
            result["PID_$(pid)"] = (r_plus - r_minus) / (2.0 * h)
        end
        return isempty(result) ? _zero_explicit_groups(dv) : result
    elseif dv_type in ("material_E", "material_G", "material_NU")
        result = Dict{String,Float64}()
        field = dv_type == "material_E" ? "E" : dv_type == "material_G" ? "G" : "NU"
        for mid in Int.(collect(get(dv, "mids", Int[])))
            mat = get(get(model, "MATs", Dict()), string(mid), nothing)
            mat === nothing && continue
            value0 = Float64(get(mat, field, 0.0))
            h = field == "NU" ? min(max(abs(value0) * 1e-6, 1e-8), 0.25 * min(value0 + 0.49, 0.49 - value0)) :
                max(abs(value0) * 1e-6, 1e-3)
            h > 0.0 || continue
            model_p = _beam_model_with_material_delta(model, mid, field, h)
            model_m = _beam_model_with_material_delta(model, mid, field, -h)
            r_plus = evaluate_response(resp, u_global, model_p, id_map, ndof, node_coords, node_R)
            r_minus = evaluate_response(resp, u_global, model_m, id_map, ndof, node_coords, node_R)
            result["MID_$(mid)"] = (r_plus - r_minus) / (2.0 * h)
        end
        return isempty(result) ? _zero_explicit_groups(dv) : result
    elseif dv_type == "node_coord"
        grid = Int(get(dv, "grid", get(dv, "gid", 0)))
        comp = Int(get(dv, "comp", get(dv, "component", 0)))
        grid_str = string(grid)
        haskey(model["GRIDs"], grid_str) || return _zero_explicit_groups(dv)
        coords_arr = model["GRIDs"][grid_str]["X"]
        x0 = Float64(coords_arr[comp])
        h = max(abs(x0) * 1e-6, 1e-8)
        coords_arr[comp] = x0 + h
        r_plus = evaluate_response(resp, u_global, model, id_map, ndof, _rebuild_node_coords(model, id_map), node_R)
        coords_arr[comp] = x0 - h
        r_minus = evaluate_response(resp, u_global, model, id_map, ndof, _rebuild_node_coords(model, id_map), node_R)
        coords_arr[comp] = x0
        return Dict{String,Float64}("GRID_$(grid)_$(comp)" => (r_plus - r_minus) / (2.0 * h))
    end
    return _zero_explicit_groups(dv)
end

"""
    compute_dr_dx_explicit(resp, dv, model, id_map, node_coords, node_R, u_global, ndof) -> Dict{String, Float64}

Compute dr/dx|explicit for stress/force responses.
For displacement responses, this is zero.
Returns per-group dict (same structure as dKdx_u_per_group).
"""
function compute_dr_dx_explicit(resp, dv, model, id_map, node_coords, node_R, u_global, ndof)
    rtype = resp["type"]
    dv_type = dv["type"]

    # Displacement responses have no explicit derivative
    if rtype in ("displacement", "ks_displacement")
        return _zero_explicit_groups(dv)
    end

    # KS-aggregated stress: delegate per-EID to the single-element path and
    # combine via softmax weights. Recursion is safe — each recursive call has
    # type="von_mises" (a single-EID response).
    if rtype == "ks_von_mises"
        eids = _ks_resolve_eids(resp, model)
        surface = get(resp, "surface", "top")
        rho = Float64(get(resp, "rho", 50.0))
        sigma_ref = Float64(get(resp, "sigma_ref", 1.0))
        VM_vec, caches = _ks_vm_per_element(eids, surface, u_global, model,
                                            id_map, node_coords, node_R, resp)
        _, w = _ks_aggregate(VM_vec ./ sigma_ref; rho=rho)

        accumulated = _zero_explicit_groups(dv)
        for (i, cache) in enumerate(caches)
            isnothing(cache) && continue
            w[i] == 0.0 && continue
            part = compute_dr_dx_explicit(cache.response, dv, model, id_map,
                                          node_coords, node_R, u_global, ndof)
            scale = w[i] / sigma_ref
            for (k, v) in part
                accumulated[k] = get(accumulated, k, 0.0) + scale * v
            end
        end
        return accumulated
    end

    if rtype == "ks_ply_failure"
        strength_dv_types = (
            "material_XT", "material_XC", "material_YT", "material_YC", "material_S", "material_F12",
            "material_xt", "material_xc", "material_yt", "material_yc", "material_s", "material_f12",
        )
        if dv_type in strength_dv_types
            result = _zero_explicit_groups(dv)
            for mid in dv["mids"]
                mid_int = Int(mid)
                mat = get(get(model, "MATs", Dict()), string(mid_int), nothing)
                if mat === nothing || uppercase(string(get(mat, "TYPE", ""))) != "MAT8"
                    result["MID_$(mid_int)"] = 0.0
                    continue
                end
                result["MID_$(mid_int)"] = _failure_strength_explicit_fd(
                    resp, dv, model, id_map, node_coords, node_R, u_global, ndof, mid_int,
                )
            end
            return result
        end
        if !(dv_type == "pcomp_ply_thickness" || dv_type == "pcomp_ply_angle")
            return _zero_explicit_groups(dv)
        end
        result = _zero_explicit_groups(dv)
        for pid in dv["pids"]
            pid_int = Int(pid)
            prop = get(get(model, "PSHELLs", Dict()), string(pid_int), nothing)
            if prop === nothing || uppercase(string(get(prop, "TYPE", ""))) != "PCOMP_CLT"
                result["PID_$(pid_int)"] = 0.0
                continue
            end
            ply_idx = Int(get(dv, "ply_index", 0))
            ply_data = get(prop, "PLY_DATA", nothing)
            if !(ply_data isa AbstractVector) || ply_idx < 1 || ply_idx > length(ply_data)
                result["PID_$(pid_int)"] = 0.0
                continue
            end
            result["PID_$(pid_int)"] = _pcomp_ply_failure_explicit_fd(
                resp, dv, model, id_map, node_coords, node_R, u_global, ndof, pid_int,
            )
        end
        return result
    end

    # Only stress/force responses on shells have explicit thickness derivatives
    if !(startswith(rtype, "von_mises") || startswith(rtype, "shell_force_") || startswith(rtype, "shell_moment_"))
        return _zero_explicit_groups(dv)
    end

    eid = Int(resp["eid"])
    ed = _get_shell_element_data(eid, model, id_map, node_coords, node_R)
    if isnothing(ed)
        bd = _get_beam_element_data(eid, model, id_map, node_coords, node_R, resp)
        bd === nothing && return _zero_explicit_groups(dv)
        return _beam_response_explicit_fd(resp, dv, model, id_map, node_coords, node_R, u_global, ndof)
    end

    Bm, Bb, D = _shell_centroid_B_matrices(ed.n_nodes, ed.lc, ed.E, ed.nu)
    u_elem_global = [u_global[ed.dofs[i]] for i in 1:ed.ndof_elem]
    u_local = ed.T_mat * u_elem_global
    eps_mem = Bm * u_local
    kappa = Bb * u_local

    result = Dict{String, Float64}()

    if dv_type == "shell_thickness"
        pids = Set(string.(dv["pids"]))
        # Element must belong to one of the DVs PIDs
        if !(ed.pid_str in pids)
            return _zero_explicit_groups(dv)
        end

        h = ed.h
        if rtype == "von_mises"
            surface = get(resp, "surface", "top")
            z = surface == "bottom" ? -h/2 : h/2
            sigma = D * (eps_mem .+ z .* kappa)
            _, dVM_dsigma = _von_mises_plane_stress(sigma)
            # dsigma/dh|explicit = D * (dz/dh * kappa) = D * (±1/2 * kappa)
            dz_dh = surface == "bottom" ? -0.5 : 0.5
            dsigma_dh = D * (dz_dh .* kappa)
            dr_dh = dot(dVM_dsigma, dsigma_dh)

        elseif startswith(rtype, "shell_force_")
            comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3
            # N = D*h * eps_mem → dN/dh = D * eps_mem
            dN_dh = D * eps_mem
            dr_dh = dN_dh[comp]

        elseif startswith(rtype, "shell_moment_")
            comp = rtype == "shell_moment_mx" ? 1 : 2
            # M = -D * (h³/12) * kappa → dM/dh = -D * (3h²/12) * kappa = -D * h²/4 * kappa
            dM_dh = -D * (h^2 / 4.0) .* kappa
            dr_dh = dM_dh[comp]
        else
            dr_dh = 0.0
        end

        result["PID_$(ed.pid_str)"] = dr_dh
        # Fill zeros for other PIDs in this DV
        for pid in dv["pids"]
            key = "PID_$(string(Int(pid)))"
            if !haskey(result, key); result[key] = 0.0; end
        end

    elseif dv_type == "material_E"
        mids = Set(string.(dv["mids"]))
        if !(ed.mid_str in mids)
            return _zero_explicit_groups(dv)
        end

        E = ed.E; h = ed.h

        if rtype == "von_mises"
            surface = get(resp, "surface", "top")
            z = surface == "bottom" ? -h/2 : h/2
            sigma = D * (eps_mem .+ z .* kappa)
            _, dVM_dsigma = _von_mises_plane_stress(sigma)
            # dsigma/dE|explicit = dD/dE * (eps_mem + z*kappa) = sigma/E
            dsigma_dE = sigma / E
            dr_dE = dot(dVM_dsigma, dsigma_dE)

        elseif startswith(rtype, "shell_force_")
            comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3
            # N = D*h * eps_mem → dN/dE = (D/E)*h * eps_mem = N/E
            N = D * h * eps_mem
            dr_dE = N[comp] / E

        elseif startswith(rtype, "shell_moment_")
            comp = rtype == "shell_moment_mx" ? 1 : 2
            M = -D * (h^3/12.0) * kappa
            dr_dE = M[comp] / E
        else
            dr_dE = 0.0
        end

        result["MID_$(ed.mid_str)"] = dr_dE
        for mid in dv["mids"]
            key = "MID_$(string(Int(mid)))"
            if !haskey(result, key); result[key] = 0.0; end
        end

    elseif dv_type == "material_NU"
        mids = Set(string.(dv["mids"]))
        if !(ed.mid_str in mids)
            return _zero_explicit_groups(dv)
        end

        E = ed.E; nu = ed.nu; h = ed.h
        # dD/dnu via FD (D matrix depends on nu in a complex way)
        delta_nu = max(abs(nu) * 1e-6, 1e-8)
        D_plus = (E / (1 - (nu+delta_nu)^2)) .* [1.0 nu+delta_nu 0.0; nu+delta_nu 1.0 0.0; 0.0 0.0 (1-(nu+delta_nu))/2]
        D_minus = (E / (1 - (nu-delta_nu)^2)) .* [1.0 nu-delta_nu 0.0; nu-delta_nu 1.0 0.0; 0.0 0.0 (1-(nu-delta_nu))/2]
        dD_dnu = (D_plus - D_minus) / (2.0 * delta_nu)

        if rtype == "von_mises"
            surface = get(resp, "surface", "top")
            z = surface == "bottom" ? -h/2 : h/2
            sigma = D * (eps_mem .+ z .* kappa)
            _, dVM_dsigma = _von_mises_plane_stress(sigma)
            dsigma_dnu = dD_dnu * (eps_mem .+ z .* kappa)
            dr_dnu = dot(dVM_dsigma, dsigma_dnu)

        elseif startswith(rtype, "shell_force_")
            comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3
            dN_dnu = dD_dnu * h * eps_mem
            dr_dnu = dN_dnu[comp]

        elseif startswith(rtype, "shell_moment_")
            comp = rtype == "shell_moment_mx" ? 1 : 2
            dM_dnu = -dD_dnu * (h^3/12.0) * kappa
            dr_dnu = dM_dnu[comp]
        else
            dr_dnu = 0.0
        end

        result["MID_$(ed.mid_str)"] = dr_dnu
        for mid in dv["mids"]
            key = "MID_$(string(Int(mid)))"
            if !haskey(result, key); result[key] = 0.0; end
        end

    elseif dv_type == "bar_area"
        return _zero_explicit_groups(dv)

    elseif dv_type == "pcomp_ply_thickness" || dv_type == "pcomp_ply_angle"
        pids = Set(string.(dv["pids"]))
        if !(ed.pid_str in pids); return _zero_explicit_groups(dv); end
        prop = get(model["PSHELLs"], ed.pid_str, nothing)
        if isnothing(prop) || get(prop, "TYPE", "") != "PCOMP_CLT"
            return _zero_explicit_groups(dv)
        end
        ply_idx = Int(dv["ply_index"])
        if !haskey(prop, "PLY_DATA") || ply_idx > length(prop["PLY_DATA"])
            return _zero_explicit_groups(dv)
        end

        if rtype == "von_mises"
            dr_dx = _pcomp_von_mises_explicit_fd(
                resp, dv, model, id_map, node_coords, node_R, u_global, ndof, ed,
            )
            result["PID_$(ed.pid_str)"] = dr_dx
            for pid in dv["pids"]
                key = "PID_$(string(Int(pid)))"
                if !haskey(result, key); result[key] = 0.0; end
            end
            return result
        end

        perturb_field = dv_type == "pcomp_ply_thickness" ? :T : :THETA
        h = ed.h
        mats = model["MATs"]
        dv_method = get_dv_method(dv)

        local dCm, dCb
        if dv_method == :laminate_exact
            clt_deriv = _pcomp_exact_constitutive_derivative(prop, mats, ply_idx, perturb_field)
            if isnothing(clt_deriv)
                dv_method = :clt_fd
            else
                dCm = clt_deriv[1]
                dCb = clt_deriv[3]
            end
        end

        if dv_method == :clt_fd
            ply = prop["PLY_DATA"][ply_idx]
            if perturb_field == :T
                t_ply = Float64(ply["z_top"] - ply["z_bot"])
                delta = max(abs(t_ply) * 1e-6, 1e-12)
            else
                theta_ply = deg2rad(Float64(ply["theta"]))
                delta = max(abs(theta_ply) * 1e-6, 1e-6)
            end

            Cm_p, _, Cb_p, _ = _recompute_clt(prop, mats; perturb_ply=ply_idx, perturb_field=perturb_field, perturb_delta=delta)
            Cm_m, _, Cb_m, _ = _recompute_clt(prop, mats; perturb_ply=ply_idx, perturb_field=perturb_field, perturb_delta=-delta)
            dCm = (Cm_p - Cm_m) / (2.0 * delta)
            dCb = (Cb_p - Cb_m) / (2.0 * delta)
        elseif dv_method != :laminate_exact
            error("[ADJOINT] Unsupported explicit-response backend '$dv_method' for PCOMP ply design variable")
        end

        D_eff = dCm / max(h, 1e-30)

        if rtype == "von_mises"
            surface = get(resp, "surface", "top")
            z = surface == "bottom" ? -h/2 : h/2
            sigma = (prop["Cm"] / max(h, 1e-30)) * (eps_mem .+ z .* kappa)
            _, dVM_dsigma = _von_mises_plane_stress(sigma)
            dsigma_dx = D_eff * (eps_mem .+ z .* kappa)
            dr_dx = dot(dVM_dsigma, dsigma_dx)
        elseif startswith(rtype, "shell_force_")
            comp = rtype == "shell_force_nx" ? 1 : rtype == "shell_force_ny" ? 2 : 3
            dN = dCm * eps_mem
            dr_dx = dN[comp]
        elseif startswith(rtype, "shell_moment_")
            comp = rtype == "shell_moment_mx" ? 1 : 2
            dM = -dCb * kappa
            dr_dx = dM[comp]
        else
            dr_dx = 0.0
        end

        result["PID_$(ed.pid_str)"] = dr_dx
        for pid in dv["pids"]
            key = "PID_$(string(Int(pid)))"
            if !haskey(result, key); result[key] = 0.0; end
        end

    elseif dv_type == "node_coord"
        # Stress depends on geometry (B matrices) — use FD on response evaluation
        grid = Int(dv["grid"]); comp = Int(dv["comp"])
        grid_str = string(grid)
        if !haskey(model["GRIDs"], grid_str)
            return _zero_explicit_groups(dv)
        end

        coords_arr = model["GRIDs"][grid_str]["X"]
        x0 = Float64(coords_arr[comp])
        delta = max(abs(x0) * 1e-6, 1e-8)

        # Check if this node is connected to the response element
        eid = Int(resp["eid"])
        el = get(model["CSHELLs"], string(eid), nothing)
        if isnothing(el) || !(grid in el["NODES"])
            # Node not connected to response element — no explicit dependence
            return _zero_explicit_groups(dv)
        end

        # FD on response at perturbed geometry (fixed u)
        coords_arr[comp] = x0 + delta
        r_plus = evaluate_response(resp, u_global, model, id_map, ndof,
            _rebuild_node_coords(model, id_map), node_R)
        coords_arr[comp] = x0 - delta
        r_minus = evaluate_response(resp, u_global, model, id_map, ndof,
            _rebuild_node_coords(model, id_map), node_R)
        coords_arr[comp] = x0  # restore

        dr_dx = (r_plus - r_minus) / (2.0 * delta)
        result["GRID_$(grid)_$(comp)"] = dr_dx

    else
        return _zero_explicit_groups(dv)
    end

    return result
end

"""Rebuild node_coords matrix from model GRIDs (for FD on geometry)."""
function _rebuild_node_coords(model, id_map)
    n_nodes = length(id_map)
    X = zeros(n_nodes, 3)
    for (sid, g) in model["GRIDs"]
        idx = id_map[g["ID"]]
        X[idx, :] = g["X"]
    end
    return X
end

function _zero_explicit_groups(dv)
    dv_type = dv["type"]
    result = Dict{String, Float64}()
    if dv_type in ("shell_thickness", "bar_area", "pcomp_ply_thickness", "pcomp_ply_angle",
                   "beam_area", "beam_I1", "beam_I2", "beam_J", "beam_i1", "beam_i2", "beam_j")
        for pid in get(dv, "pids", Int[]); result["PID_$(string(Int(pid)))"] = 0.0; end
    elseif dv_type in ("material_E", "material_G", "material_NU",
                       "material_XT", "material_XC", "material_YT", "material_YC", "material_S", "material_F12",
                       "material_xt", "material_xc", "material_yt", "material_yc", "material_s", "material_f12")
        for mid in get(dv, "mids", Int[]); result["MID_$(string(Int(mid)))"] = 0.0; end
    elseif dv_type == "node_coord"
        grid = Int(dv["grid"]); comp = Int(dv["comp"])
        result["GRID_$(grid)_$(comp)"] = 0.0
    elseif dv_type == "topology_density"
        for eid in get(dv, "eids", Int[]); result["EID_$(string(Int(eid)))"] = 0.0; end
    end
    return result
end

# ============================================================================
# Design variable value extraction
# ============================================================================

function get_design_variable_values(dv, model)
    dv_type = dv["type"]
    values = Dict{String, Float64}()

    if dv_type == "shell_thickness"
        pshells = model["PSHELLs"]
        for pid in dv["pids"]
            pid_str = string(Int(pid))
            if haskey(pshells, pid_str)
                values["PID_$pid_str"] = pshells[pid_str]["T"]
            end
        end
    elseif dv_type == "material_E"
        mats = model["MATs"]
        for mid in dv["mids"]
            mid_str = string(Int(mid))
            if haskey(mats, mid_str)
                values["MID_$mid_str"] = mats[mid_str]["E"]
            end
        end
    elseif dv_type == "material_NU"
        mats = model["MATs"]
        for mid in dv["mids"]
            mid_str = string(Int(mid))
            if haskey(mats, mid_str)
                values["MID_$mid_str"] = mats[mid_str]["NU"]
            end
        end
    elseif dv_type == "bar_area"
        pbarls = get(model, "PBARLs", Dict())
        for pid in dv["pids"]
            pid_str = string(Int(pid))
            if haskey(pbarls, pid_str)
                values["PID_$pid_str"] = pbarls[pid_str]["A"]
            end
        end
    elseif dv_type == "pcomp_ply_thickness"
        pshells = model["PSHELLs"]
        ply_idx = Int(dv["ply_index"])
        for pid in dv["pids"]
            pid_str = string(Int(pid))
            prop = get(pshells, pid_str, nothing)
            if !isnothing(prop) && haskey(prop, "PLY_DATA") && ply_idx <= length(prop["PLY_DATA"])
                ply = prop["PLY_DATA"][ply_idx]
                values["PID_$pid_str"] = Float64(ply["z_top"] - ply["z_bot"])
            end
        end
    elseif dv_type == "pcomp_ply_angle"
        pshells = model["PSHELLs"]
        ply_idx = Int(dv["ply_index"])
        for pid in dv["pids"]
            pid_str = string(Int(pid))
            prop = get(pshells, pid_str, nothing)
            if !isnothing(prop) && haskey(prop, "PLY_DATA") && ply_idx <= length(prop["PLY_DATA"])
                values["PID_$pid_str"] = Float64(prop["PLY_DATA"][ply_idx]["theta"])
            end
        end
    elseif dv_type == "node_coord"
        grid = Int(dv["grid"]); comp = Int(dv["comp"])
        grid_str = string(grid)
        if haskey(model["GRIDs"], grid_str)
            values["GRID_$(grid)_$(comp)"] = Float64(model["GRIDs"][grid_str]["X"][comp])
        end
    elseif dv_type == "topology_density"
        densities = dv["densities"]
        for eid in dv["eids"]
            eid_str = string(Int(eid))
            values["EID_$eid_str"] = Float64(get(densities, eid_str, 1.0))
        end
    end

    return values
end

# ============================================================================
# Main adjoint solver
# ============================================================================

"""
    solve_adjoint(results::Dict, adjoint_config_path::String) -> Dict

Run adjoint sensitivity analysis on SOL 101 results.
"""
function solve_adjoint(results::Dict, adjoint_config_path::String)
    if results["sol_type"] != 101
        error("[ADJOINT] Adjoint solver requires SOL 101 results (got SOL $(results["sol_type"]))")
    end

    config = parse_adjoint_config(adjoint_config_path)
    responses = config["responses"]
    design_vars = config["design_variables"]

    model = results["model"]
    id_map = results["id_map"]
    X = results["node_coords"]
    K = results["K"]
    ndof = results["ndof"]
    node_R = results["node_R"]

    n_resp = length(responses)
    n_dv = length(design_vars)
    log_msg("[ADJOINT] Starting adjoint sensitivity analysis: $n_resp responses × $n_dv design variables")

    subcases = results["subcases"]
    all_adjoint_results = Dict{Int, Dict}()

    for sc in subcases
        sid = sc["sid"]
        u_global = sc["u_analysis"]
        fixed_dofs_sc = sc["fixed_dofs"]

        subcase_responses = filter(r -> get(r, "subcase", 1) == sid, responses)
        if isempty(subcase_responses); continue; end

        log_msg("[ADJOINT] Subcase $sid: $(length(subcase_responses)) responses")

        free_dofs = sort(collect(setdiff(1:ndof, fixed_dofs_sc)))
        K_ff = K[free_dofs, free_dofs]
        log_msg("[ADJOINT] Factorizing K_ff ($(length(free_dofs)) free DOFs)...")
        K_fact = cholesky(Symmetric(K_ff))

        sensitivities = Dict{String, Dict{String, Dict{String, Float64}}}()
        response_values = Dict{String, Float64}()

        for resp in subcase_responses
            resp_id = resp["id"]
            log_msg("[ADJOINT]   Response: $resp_id ($(resp["type"]))")

            # Evaluate response value
            r_value = evaluate_response(resp, u_global, model, id_map, ndof, X, node_R)
            response_values[resp_id] = r_value

            # Compute adjoint RHS: dr/du
            dr_du_full = compute_dr_du(resp, u_global, model, id_map, ndof, X, node_R)

            # Solve adjoint equation
            dr_du_f = dr_du_full[free_dofs]
            lambda_f = K_fact \ dr_du_f
            lambda_full = zeros(ndof)
            lambda_full[free_dofs] = lambda_f

            # Compute sensitivities for each design variable
            sensitivities[resp_id] = Dict{String, Dict{String, Float64}}()
            for dv in design_vars
                dv_id = dv["id"]

                # Implicit part: -lambda^T * dK/dx * u (per group)
                dKdx_u_groups = compute_dKdx_u_per_group(dv, model, id_map, X, node_R, u_global, ndof)

                # Explicit part: dr/dx|explicit (per group)
                dr_dx_explicit = compute_dr_dx_explicit(resp, dv, model, id_map, X, node_R, u_global, ndof)

                # Total: dr/dx = dr/dx|explicit + lambda^T * (dF/dx - dK/dx * u)
                # dF/dx = 0 for all current DV types
                group_sens = Dict{String, Float64}()
                for (group_label, dKdx_u_vec) in dKdx_u_groups
                    implicit = -dot(lambda_full, dKdx_u_vec)
                    explicit = get(dr_dx_explicit, group_label, 0.0)
                    group_sens[group_label] = explicit + implicit
                end
                sensitivities[resp_id][dv_id] = group_sens
            end
        end

        dv_values = Dict{String, Dict{String, Float64}}()
        for dv in design_vars
            dv_values[dv["id"]] = get_design_variable_values(dv, model)
        end

        all_adjoint_results[sid] = Dict(
            "sensitivities" => sensitivities,
            "response_values" => response_values,
            "design_variable_values" => dv_values,
        )
    end

    if length(all_adjoint_results) == 1
        return first(values(all_adjoint_results))
    end
    return all_adjoint_results
end

"""
    export_adjoint_json(adjoint_results::Dict, output_path::String)

Write adjoint sensitivity results to a JSON file.
"""
function export_adjoint_json(adjoint_results::Dict, output_path::String)
    open(output_path, "w") do f
        JSON.print(f, adjoint_results, 2)
    end
    log_msg("[ADJOINT] Results written to: $output_path")
end
