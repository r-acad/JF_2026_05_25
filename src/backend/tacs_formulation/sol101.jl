# sol101.jl -- first residual-first TACS-formulation vertical slice.
#
# Scope:
#   SOL101/SOL103/SOL105/SOL106, CQUAD4/CQUADR/CTRIA3 shell models with
#   PSHELL/MAT1, PSHELL/MAT2, PSHELL/MAT8, or PCOMP_CLT properties, plus
#   guarded CROD/CONROD rod, CBAR/CBEAM beam, and CELAS/CBUSH spring slices. The element
#   residual is R_e = K_e u_e and the tangent is K_e.
#   This file deliberately avoids the Nastran-parity assembly switchboard;
#   unsupported model features fail fast so future TACS slices are added
#   explicitly.

using LinearAlgebra
using SparseArrays
using StaticArrays

if !isdefined(@__MODULE__, :TACS_LINEAR_SHELL_STIFFNESS_ROUTE)
    const TACS_LINEAR_SHELL_STIFFNESS_ROUTE = "residual_first_quad4_cquadr_tria3"
end
if !isdefined(@__MODULE__, :TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE)
    const TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE = "native_residual_first_quad4_cquadr_tria3"
end
if !isdefined(@__MODULE__, :TACS_LINEAR_ROD_STIFFNESS_ROUTE)
    const TACS_LINEAR_ROD_STIFFNESS_ROUTE = "residual_first_crod_conrod_sol101_sol103"
end
if !isdefined(@__MODULE__, :TACS_LINEAR_BEAM_STIFFNESS_ROUTE)
    const TACS_LINEAR_BEAM_STIFFNESS_ROUTE = "residual_first_cbar_cbeam_sol101_sol103_sol105"
end
if !isdefined(@__MODULE__, :TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE)
    const TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE = "native_residual_first_cbar_cbeam_operator"
end

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

function _tacs_id_key(raw)::String
    if raw isa Integer
        return string(raw)
    elseif raw isa AbstractString
        return strip(raw)
    else
        return string(Int(raw))
    end
end

function _tacs_route_label(route_label::AbstractString, allowed_sol_types)
    return isempty(route_label) ? "SOL $(join(allowed_sol_types, "/"))" : route_label
end

_tacs_material_design_types() = (
    "material_E", "material_G", "material_NU", "material_RHO",
    "material_ALPHA", "material_TREF",
    "material_E1", "material_E2", "material_G11", "material_G12",
    "material_G13", "material_G22", "material_G23", "material_G33",
    "material_NU12",
)

_tacs_material_stiffness_design_types() = (
    "material_E", "material_G", "material_NU",
    "material_E1", "material_E2", "material_G11", "material_G12",
    "material_G13", "material_G22", "material_G23", "material_G33",
    "material_NU12",
)

function _tacs_material_design_step(mat::AbstractDict, field::AbstractString, mid::Integer)
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    field_key = uppercase(strip(string(field)))
    value0 = Float64(get(mat, field_key, 0.0))
    if mat_type == "MAT2" && field_key in ("G11", "G22", "G33")
        value0 > 0.0 || error("TACS material derivative requires positive MAT2 $field_key for material $mid.")
        return max(1e-6 * value0, 1e-3)
    elseif mat_type == "MAT2" && field_key in ("G12", "G13", "G23")
        return max(1e-6 * max(abs(value0), 1.0), 1e-3)
    elseif field_key in ("E", "G", "E1", "E2", "G12")
        value0 > 0.0 || error("TACS material derivative requires positive $field_key for material $mid.")
        return max(1e-6 * value0, 1e-3)
    elseif field_key == "RHO"
        return max(1e-6 * max(abs(value0), 1.0), 1e-9)
    elseif field_key == "ALPHA"
        return max(1e-6 * max(abs(value0), 1e-5), 1e-10)
    elseif field_key == "TREF"
        return max(1e-6 * max(abs(value0), 1.0), 1e-6)
    else
        -0.49 < value0 < 0.49 || error("TACS material derivative requires $field_key in (-0.49, 0.49) for material $mid.")
        h = min(1e-6, 0.25 * min(value0 + 0.49, 0.49 - value0))
        h > 0.0 || error("TACS material derivative could not choose a positive $field_key perturbation for material $mid.")
        return h
    end
end

function _tacs_material_design_mids(dv::AbstractDict)
    mids = sort!(unique(Int.(collect(get(dv, "mids", Int[])))))
    isempty(mids) && error("TACS material design perturbation requires at least one material id.")
    return mids
end

function _tacs_material_group_design_step(model::AbstractDict, dv::AbstractDict)
    raw_step = get(dv, "step", nothing)
    if raw_step !== nothing
        step = Float64(raw_step)
        step > 0.0 || error("TACS material derivative finite-difference step must be positive; got $step.")
        return step
    end
    field = _tacs_material_design_field(string(get(dv, "type", "")))
    h = Inf
    for mid in _tacs_material_design_mids(dv)
        mat = get(get(model, "MATs", Dict()), string(mid), nothing)
        mat === nothing && error("TACS material derivative could not find material $mid.")
        h = min(h, _tacs_material_design_step(mat, field, mid))
    end
    isfinite(h) && h > 0.0 ||
        error("TACS material derivative could not choose a positive grouped perturbation step.")
    return h
end

function _tacs_validate_shell_slice(
    model::Dict;
    allowed_sol_types=(101,),
    route_label="",
    allow_rods::Bool=false,
    allow_beams::Bool=false,
    allow_springs::Bool=false,
    allow_masses::Bool=false,
    allow_conm1::Bool=false,
    require_shell::Bool=true,
    allow_beam_offsets_releases::Union{Nothing,Bool}=nothing,
    allow_varying_pbeam_stations::Bool=false,
)
    label = _tacs_route_label(route_label, allowed_sol_types)
    raw_sol_type = get(model, "SOL", get(get(model, "CASE_CONTROL", Dict()), "SOL", 101))
    sol_type = _canonical_sol_type(raw_sol_type)
    sol_type in allowed_sol_types ||
        error("TACS-formulation backend $label route does not support SOL $sol_type.")

    unsupported_groups = String[]
    for key in ("CSOLIDs", "CSHEARs",
                "CELAS1s", "CELAS2s",
                "RBE1s", "RBE2s", "RBE3s",
                "RBARs", "RSPLINEs", "MPCs")
        _tacs_nonempty_group(model, key) && push!(unsupported_groups, key)
    end
    if !allow_beams
        for key in ("CBARs", "CBEAMs")
            _tacs_nonempty_group(model, key) && push!(unsupported_groups, key)
        end
    end
    if !allow_masses
        for key in ("CONM1s", "CONM2s", "CMASS1s", "CMASS2s", "PMASSs")
            _tacs_nonempty_group(model, key) && push!(unsupported_groups, key)
        end
    elseif !allow_conm1
        _tacs_nonempty_group(model, "CONM1s") && push!(unsupported_groups, "CONM1s")
    end
    if !allow_rods
        for key in ("CRODs", "CONRODs")
            _tacs_nonempty_group(model, key) && push!(unsupported_groups, key)
        end
    end
    if !allow_springs
        _tacs_nonempty_group(model, "CELASs") && push!(unsupported_groups, "CELASs")
        _tacs_nonempty_group(model, "CBUSHs") && push!(unsupported_groups, "CBUSHs")
    end
    isempty(unsupported_groups) ||
        error("TACS-formulation $label slice supports CQUAD4/CQUADR/CTRIA3 shell models$(allow_rods ? " plus guarded SOL101/SOL103 CROD/CONROD rods" : "")$(allow_beams ? " plus guarded SOL101/SOL103/SOL105 CBAR/CBEAM beams" : "")$(allow_springs ? " plus guarded SOL101/SOL103 CELAS1/CELAS2/CBUSH springs" : "")$(allow_masses ? " plus guarded SOL103 CONM1/CONM2/CMASS point masses" : "") only; unsupported groups present: $(join(unsupported_groups, ", ")).")

    cshells = get(model, "CSHELLs", Dict())
    crods = get(model, "CRODs", Dict())
    conrods = get(model, "CONRODs", Dict())
    cbars = get(model, "CBARs", Dict())
    cbeams = get(model, "CBEAMs", Dict())
    celases = get(model, "CELASs", Dict())
    cbushes = get(model, "CBUSHs", Dict())
    if isempty(cshells)
        if require_shell ||
           !((allow_rods && (!isempty(crods) || !isempty(conrods))) ||
             (allow_beams && (!isempty(cbars) || !isempty(cbeams))) ||
             (allow_springs && (!isempty(celases) || !isempty(cbushes))))
            error("TACS-formulation $label slice requires at least one CQUAD4, CQUADR, CTRIA3, CROD, CONROD, CBAR, CBEAM, CELAS1, CELAS2, or CBUSH element.")
        end
    end
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
            uppercase(string(get(mat, "TYPE", "MAT1"))) in ("MAT1", "MAT1_EQUIV", "MAT2", "MAT8", "") ||
                error("TACS-formulation $label PSHELL property $pid supports MAT1/MAT2/MAT8 only; material $mid has TYPE=$(get(mat, "TYPE", "?"))")
        elseif prop_type == "PCOMP_CLT"
            for key in ("Cm", "Cb", "Cs", "E_ref")
                haskey(prop, key) || error("TACS-formulation $label PCOMP_CLT property $pid is missing CLT field '$key'.")
            end
            get(prop, "T", 0.0) > 0.0 || error("TACS-formulation $label PCOMP_CLT property $pid must have positive total thickness.")
        else
            error("TACS-formulation $label slice supports PSHELL/MAT1, PSHELL/MAT2, PSHELL/MAT8, and PCOMP_CLT only; property $pid has TYPE=$(get(prop, "TYPE", "?"))")
        end
    end
    if allow_rods
        _tacs_validate_rod_slice(model, label)
    end
    if allow_beams
        default_beam_offsets_releases = all(st -> Int(st) in (101, 103, 105), allowed_sol_types)
        beam_offsets_releases =
            allow_beam_offsets_releases === nothing ?
            default_beam_offsets_releases :
            Bool(allow_beam_offsets_releases)
        _tacs_validate_beam_slice(
            model,
            label;
            allow_offsets_releases=beam_offsets_releases,
            allow_varying_pbeam_stations=allow_varying_pbeam_stations,
        )
    end
    if allow_springs
        _tacs_validate_spring_slice(model, label)
    end
    if allow_masses
        _tacs_validate_modal_mass_slice(model, label)
    end
    return nothing
end

function _tacs_validate_sol101_slice(model::Dict)
    return _tacs_validate_shell_slice(model; allowed_sol_types=(101,), route_label="SOL101")
end

function _tacs_validate_mat1_for_line(model::AbstractDict, mid_raw, label::AbstractString, card_type::AbstractString, eid)
    mid = _tacs_id_key(mid_raw)
    mat = get(get(model, "MATs", Dict()), mid, nothing)
    mat === nothing && error("TACS-formulation $label $card_type element $eid references missing MAT1 material $mid.")
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    mat_type in ("MAT1", "MAT1_EQUIV", "") ||
        error("TACS-formulation $label $card_type element $eid supports MAT1/MAT1_EQUIV only; material $mid has TYPE=$(get(mat, "TYPE", "?")).")
    E = Float64(get(mat, "E", 0.0))
    G = Float64(get(mat, "G", 0.0))
    nu = Float64(get(mat, "NU", -1.0))
    E, G, _ = Solver._complete_mat1_triplet(E, G, nu)
    E > 0.0 || error("TACS-formulation $label $card_type element $eid requires positive MAT1 E.")
    G >= 0.0 || error("TACS-formulation $label $card_type element $eid requires nonnegative MAT1 G.")
    return nothing
end

function _tacs_validate_rod_slice(model::Dict, label::AbstractString)
    grids = get(model, "GRIDs", Dict())
    prods = get(model, "PRODs", Dict())
    for (eid, rod) in get(model, "CRODs", Dict())
        pid = _tacs_id_key(get(rod, "PID", 0))
        prop = get(prods, pid, nothing)
        prop === nothing && error("TACS-formulation $label CROD element $eid references missing PROD property $pid.")
        Float64(get(prop, "A", 0.0)) > 0.0 ||
            error("TACS-formulation $label CROD property $pid requires positive area A.")
        Float64(get(prop, "J", 0.0)) >= 0.0 ||
            error("TACS-formulation $label CROD property $pid requires nonnegative torsion constant J.")
        ga = _tacs_id_key(get(rod, "GA", 0))
        gb = _tacs_id_key(get(rod, "GB", 0))
        haskey(grids, ga) || error("TACS-formulation $label CROD element $eid references missing grid $ga.")
        haskey(grids, gb) || error("TACS-formulation $label CROD element $eid references missing grid $gb.")
        _tacs_validate_mat1_for_line(model, get(prop, "MID", 0), label, "CROD", eid)
    end
    for (eid, rod) in get(model, "CONRODs", Dict())
        Float64(get(rod, "A", 0.0)) > 0.0 ||
            error("TACS-formulation $label CONROD element $eid requires positive area A.")
        Float64(get(rod, "J", 0.0)) >= 0.0 ||
            error("TACS-formulation $label CONROD element $eid requires nonnegative torsion constant J.")
        ga = _tacs_id_key(get(rod, "GA", 0))
        gb = _tacs_id_key(get(rod, "GB", 0))
        haskey(grids, ga) || error("TACS-formulation $label CONROD element $eid references missing grid $ga.")
        haskey(grids, gb) || error("TACS-formulation $label CONROD element $eid references missing grid $gb.")
        _tacs_validate_mat1_for_line(model, get(rod, "MID", 0), label, "CONROD", eid)
    end
    return nothing
end

function _tacs_has_nonzero_offset(el::AbstractDict, key::AbstractString)::Bool
    vals = get(el, key, [0.0, 0.0, 0.0])
    vals isa AbstractVector || return false
    return any(v -> abs(Float64(v)) > 1e-14, vals)
end

function _tacs_station_property_value(st::AbstractDict, prop::AbstractDict, field::AbstractString)
    fallback = field == "I1" ? get(prop, "I1", get(prop, "I", 0.0)) : get(prop, field, 0.0)
    return Float64(get(st, field, fallback))
end

function _tacs_beam_station_properties_constant(prop::AbstractDict)
    stations = get(prop, "STATIONS", nothing)
    stations isa AbstractVector || return true
    isempty(stations) && return true
    fields = ("A", "I1", "I2", "I12", "J")
    for field in fields
        ref = _tacs_station_property_value(first(stations), prop, field)
        for st in stations
            val = _tacs_station_property_value(st, prop, field)
            abs(val - ref) <= 1e-10 * max(1.0, abs(ref), abs(val)) ||
                return false
        end
        prop_val = field == "I1" ? Float64(get(prop, "I1", get(prop, "I", ref))) : Float64(get(prop, field, ref))
        abs(prop_val - ref) <= 1e-10 * max(1.0, abs(ref), abs(prop_val)) ||
            return false
    end
    return true
end

function _tacs_beam_sorted_stations(prop::AbstractDict)
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
        if isempty(unique_stations) || abs(Float64(get(st, "X", 0.0)) - Float64(get(last(unique_stations), "X", 0.0))) > 1e-10
            push!(unique_stations, st)
        else
            unique_stations[end] = st
        end
    end
    return unique_stations
end

function _tacs_beam_station_condensed_stiffness(L::Float64, prop::AbstractDict, E::Float64, G::Float64)
    stations = _tacs_beam_sorted_stations(prop)
    length(stations) >= 2 || return nothing
    first_x = Float64(get(first(stations), "X", 0.0))
    last_x = Float64(get(last(stations), "X", 0.0))
    first_x <= 1e-8 && last_x >= 1.0 - 1e-8 ||
        error("TACS-formulation varying PBEAM/PBEAML station stiffness requires stations spanning X=0.0 to X=1.0.")

    n = length(stations)
    nd = 6 * n
    K = zeros(Float64, nd, nd)
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))
    active_segments = 0
    for s in 1:(n - 1)
        xa = Float64(get(stations[s], "X", 0.0))
        xb = Float64(get(stations[s + 1], "X", 1.0))
        seg_frac = xb - xa
        seg_frac > 1e-10 || continue
        segL = seg_frac * L
        A = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "A") +
            _tacs_station_property_value(stations[s + 1], prop, "A")
        )
        I1 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I1") +
            _tacs_station_property_value(stations[s + 1], prop, "I1")
        )
        I2 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I2") +
            _tacs_station_property_value(stations[s + 1], prop, "I2")
        )
        I12 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I12") +
            _tacs_station_property_value(stations[s + 1], prop, "I12")
        )
        J = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "J") +
            _tacs_station_property_value(stations[s + 1], prop, "J")
        )
        A > 0.0 || error("TACS-formulation varying PBEAM/PBEAML station stiffness requires positive segment area.")
        I1 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station stiffness requires nonnegative segment I1.")
        I2 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station stiffness requires nonnegative segment I2.")
        J >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station stiffness requires nonnegative segment J.")
        As_y = K1 > 0.0 ? K1 * A : Inf
        As_z = K2 > 0.0 ? K2 * A : Inf
        Ke_seg = FEM.stiffness_frame3d(segL, A, I2, I1, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
        dofs = vcat(((s - 1) * 6 + 1):(s * 6), (s * 6 + 1):((s + 1) * 6))
        for c in 1:12, r in 1:12
            K[dofs[r], dofs[c]] += Ke_seg[r, c]
        end
        active_segments += 1
    end
    active_segments > 0 || return nothing

    boundary = vcat(1:6, (nd - 5):nd)
    if nd == 12
        Ke = K[boundary, boundary]
    else
        internal = collect(7:(nd - 6))
        Kii = K[internal, internal]
        Ke = K[boundary, boundary] - K[boundary, internal] * (Kii \ K[internal, boundary])
    end
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    return Ke
end

function _tacs_beam_station_condensed_mass(
    L::Float64,
    prop::AbstractDict,
    E::Float64,
    G::Float64,
    rho::Float64,
    nsm::Float64,
)
    stations = _tacs_beam_sorted_stations(prop)
    length(stations) >= 2 || return nothing
    first_x = Float64(get(first(stations), "X", 0.0))
    last_x = Float64(get(last(stations), "X", 0.0))
    first_x <= 1e-8 && last_x >= 1.0 - 1e-8 ||
        error("TACS-formulation varying PBEAM/PBEAML station modal mass requires stations spanning X=0.0 to X=1.0.")

    n = length(stations)
    nd = 6 * n
    K = zeros(Float64, nd, nd)
    M = zeros(Float64, nd, nd)
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))
    active_segments = 0
    for s in 1:(n - 1)
        xa = Float64(get(stations[s], "X", 0.0))
        xb = Float64(get(stations[s + 1], "X", 1.0))
        seg_frac = xb - xa
        seg_frac > 1e-10 || continue
        segL = seg_frac * L
        A = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "A") +
            _tacs_station_property_value(stations[s + 1], prop, "A")
        )
        I1 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I1") +
            _tacs_station_property_value(stations[s + 1], prop, "I1")
        )
        I2 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I2") +
            _tacs_station_property_value(stations[s + 1], prop, "I2")
        )
        I12 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I12") +
            _tacs_station_property_value(stations[s + 1], prop, "I12")
        )
        J = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "J") +
            _tacs_station_property_value(stations[s + 1], prop, "J")
        )
        A > 0.0 || error("TACS-formulation varying PBEAM/PBEAML station modal mass requires positive segment area.")
        I1 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station modal mass requires nonnegative segment I1.")
        I2 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station modal mass requires nonnegative segment I2.")
        J >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station modal mass requires nonnegative segment J.")
        As_y = K1 > 0.0 ? K1 * A : Inf
        As_z = K2 > 0.0 ? K2 * A : Inf
        Ke_seg = FEM.stiffness_frame3d(segL, A, I2, I1, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
        rho_eff = rho + nsm / A
        Me_seg = FEM.nastran_lumped_mass_frame3d(segL, rho_eff, A, J, I2, I1)
        dofs = vcat(((s - 1) * 6 + 1):(s * 6), (s * 6 + 1):((s + 1) * 6))
        for c in 1:12, r in 1:12
            K[dofs[r], dofs[c]] += Ke_seg[r, c]
            M[dofs[r], dofs[c]] += Me_seg[r, c]
        end
        active_segments += 1
    end
    active_segments > 0 || return nothing

    boundary = vcat(1:6, (nd - 5):nd)
    if nd == 12
        Me = M[boundary, boundary]
    else
        internal = collect(7:(nd - 6))
        T = zeros(Float64, nd, length(boundary))
        T[boundary, :] .= Matrix{Float64}(I, length(boundary), length(boundary))
        T[internal, :] .= -(K[internal, internal] \ K[internal, boundary])
        Me = transpose(T) * M * T
    end
    Me .= 0.5 .* (Me .+ transpose(Me))
    return Me
end

function _tacs_beam_station_condensed_geometric_stiffness(
    L::Float64,
    prop::AbstractDict,
    E::Float64,
    G::Float64,
    u_boundary_local::AbstractVector{<:Real},
)
    stations = _tacs_beam_sorted_stations(prop)
    length(stations) >= 2 || return nothing, 0.0
    first_x = Float64(get(first(stations), "X", 0.0))
    last_x = Float64(get(last(stations), "X", 0.0))
    first_x <= 1e-8 && last_x >= 1.0 - 1e-8 ||
        error("TACS-formulation varying PBEAM/PBEAML station Kg requires stations spanning X=0.0 to X=1.0.")
    length(u_boundary_local) == 12 ||
        error("TACS-formulation varying PBEAM/PBEAML station Kg requires a 12-DOF boundary displacement vector.")

    n = length(stations)
    nd = 6 * n
    K = zeros(Float64, nd, nd)
    segment_data = NamedTuple{(:dofs, :segL, :A),Tuple{Vector{Int},Float64,Float64}}[]
    K1 = Float64(get(prop, "K1", 0.0))
    K2 = Float64(get(prop, "K2", 0.0))
    for s in 1:(n - 1)
        xa = Float64(get(stations[s], "X", 0.0))
        xb = Float64(get(stations[s + 1], "X", 1.0))
        seg_frac = xb - xa
        seg_frac > 1e-10 || continue
        segL = seg_frac * L
        A = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "A") +
            _tacs_station_property_value(stations[s + 1], prop, "A")
        )
        I1 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I1") +
            _tacs_station_property_value(stations[s + 1], prop, "I1")
        )
        I2 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I2") +
            _tacs_station_property_value(stations[s + 1], prop, "I2")
        )
        I12 = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "I12") +
            _tacs_station_property_value(stations[s + 1], prop, "I12")
        )
        J = 0.5 * (
            _tacs_station_property_value(stations[s], prop, "J") +
            _tacs_station_property_value(stations[s + 1], prop, "J")
        )
        A > 0.0 || error("TACS-formulation varying PBEAM/PBEAML station Kg requires positive segment area.")
        I1 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station Kg requires nonnegative segment I1.")
        I2 >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station Kg requires nonnegative segment I2.")
        J >= 0.0 || error("TACS-formulation varying PBEAM/PBEAML station Kg requires nonnegative segment J.")
        As_y = K1 > 0.0 ? K1 * A : Inf
        As_z = K2 > 0.0 ? K2 * A : Inf
        Ke_seg = FEM.stiffness_frame3d(segL, A, I2, I1, J, E, G; As_y=As_y, As_z=As_z, I12=I12)
        dofs = collect(vcat(((s - 1) * 6 + 1):(s * 6), (s * 6 + 1):((s + 1) * 6)))
        for c in 1:12, r in 1:12
            K[dofs[r], dofs[c]] += Ke_seg[r, c]
        end
        push!(segment_data, (dofs=dofs, segL=segL, A=A))
    end
    isempty(segment_data) && return nothing, 0.0

    boundary = vcat(1:6, (nd - 5):nd)
    T = zeros(Float64, nd, length(boundary))
    T[boundary, :] .= Matrix{Float64}(I, length(boundary), length(boundary))
    if nd > 12
        internal = collect(7:(nd - 6))
        T[internal, :] .= -(K[internal, internal] \ K[internal, boundary])
    end
    u_station = T * Float64.(u_boundary_local)

    Kg_full = zeros(Float64, nd, nd)
    force_length_sum = 0.0
    length_sum = 0.0
    for seg in segment_data
        q1 = u_station[seg.dofs[1:6]]
        q2 = u_station[seg.dofs[7:12]]
        axial_force = E * seg.A / seg.segL * (q2[1] - q1[1])
        Kg_seg = FEM.geometric_stiffness_frame3d(seg.segL, Float64(axial_force))
        for c in 1:12, r in 1:12
            Kg_full[seg.dofs[r], seg.dofs[c]] += Kg_seg[r, c]
        end
        force_length_sum += axial_force * seg.segL
        length_sum += seg.segL
    end
    Kg = transpose(T) * Kg_full * T
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    axial_force_avg = length_sum > 0.0 ? force_length_sum / length_sum : 0.0
    return Kg, axial_force_avg
end

function _tacs_validate_beam_slice(
    model::Dict,
    label::AbstractString;
    allow_offsets_releases::Bool=false,
    allow_varying_pbeam_stations::Bool=false,
)
    grids = get(model, "GRIDs", Dict())
    props = get(model, "PBARLs", Dict())
    for (group_name, beams) in (("CBAR", get(model, "CBARs", Dict())),
                                ("CBEAM", get(model, "CBEAMs", Dict())))
        for (eid, beam) in beams
            pid = _tacs_id_key(get(beam, "PID", 0))
            prop = get(props, pid, nothing)
            prop === nothing && error("TACS-formulation $label $group_name element $eid references missing PBAR/PBARL property $pid.")
            prop_type = uppercase(strip(string(get(prop, "TYPE", "PBAR"))))
            if prop_type == "PBEAM" || haskey(prop, "STATIONS")
                station_constant = _tacs_beam_station_properties_constant(prop)
                if !station_constant && !allow_varying_pbeam_stations
                    error("TACS-formulation $label $group_name property $pid has varying PBEAM/PBEAML station data; station condensation is outside the current TACS beam slice.")
                elseif !station_constant
                    (Int(get(beam, "PA", 0)) == 0 && Int(get(beam, "PB", 0)) == 0) ||
                        error("TACS-formulation $label $group_name element $eid has varying PBEAM/PBEAML station data with PA/PB pin releases; that combined beam slice is not guarded yet.")
                    (!_tacs_has_nonzero_offset(beam, "WA") && !_tacs_has_nonzero_offset(beam, "WB")) ||
                        error("TACS-formulation $label $group_name element $eid has varying PBEAM/PBEAML station data with WA/WB offsets; that combined beam slice is not guarded yet.")
                end
            end
            A = Float64(get(prop, "A", 0.0))
            I1 = Float64(get(prop, "I1", get(prop, "I", 0.0)))
            I2 = Float64(get(prop, "I2", get(prop, "I", 0.0)))
            J = Float64(get(prop, "J", 0.0))
            nsm = Float64(get(prop, "NSM", 0.0))
            A > 0.0 || error("TACS-formulation $label $group_name property $pid requires positive area A.")
            I1 >= 0.0 || error("TACS-formulation $label $group_name property $pid requires nonnegative I1.")
            I2 >= 0.0 || error("TACS-formulation $label $group_name property $pid requires nonnegative I2.")
            J >= 0.0 || error("TACS-formulation $label $group_name property $pid requires nonnegative torsion constant J.")
            nsm >= 0.0 || error("TACS-formulation $label $group_name property $pid requires nonnegative NSM.")
            ga = _tacs_id_key(get(beam, "GA", 0))
            gb = _tacs_id_key(get(beam, "GB", 0))
            haskey(grids, ga) || error("TACS-formulation $label $group_name element $eid references missing grid $ga.")
            haskey(grids, gb) || error("TACS-formulation $label $group_name element $eid references missing grid $gb.")
            if !allow_offsets_releases && (Int(get(beam, "PA", 0)) != 0 || Int(get(beam, "PB", 0)) != 0)
                error("TACS-formulation $label $group_name element $eid has PA/PB pin releases; beam releases are not in the first TACS beam slice.")
            end
            if !allow_offsets_releases && (_tacs_has_nonzero_offset(beam, "WA") || _tacs_has_nonzero_offset(beam, "WB"))
                error("TACS-formulation $label $group_name element $eid has WA/WB offsets; beam offsets are not in the first TACS beam slice.")
            end
            _tacs_validate_mat1_for_line(model, get(prop, "MID", 0), label, group_name, eid)
        end
    end
    return nothing
end

function _tacs_spring_stiffness(model::Dict, spring::AbstractDict, label::AbstractString, eid)
    kernel = _tacs_spring_element_kernel(spring)
    k =
        kernel.family == :celas2 ? Float64(get(spring, "K", 0.0)) : begin
            pid = _tacs_id_key(get(spring, "PID", 0))
            prop = get(get(model, "PELASs", Dict()), pid, nothing)
            prop === nothing && error("TACS-formulation $label CELAS1 element $eid references missing PELAS property $pid.")
            Float64(get(prop, "K", 0.0))
        end
    k > 0.0 || error("TACS-formulation $label $(kernel.card_type) element $eid requires positive spring stiffness K.")
    return k
end

function _tacs_validate_spring_slice(model::Dict, label::AbstractString)
    grids = get(model, "GRIDs", Dict())
    for (eid, spring) in get(model, "CELASs", Dict())
        kernel = _tacs_spring_element_kernel(spring)
        _tacs_spring_stiffness(model, spring, label, eid)
        g1 = Int(get(spring, "G1", 0))
        c1 = Int(get(spring, "C1", 0))
        g1 > 0 && haskey(grids, _tacs_id_key(g1)) ||
            error("TACS-formulation $label $(kernel.card_type) element $eid references missing/invalid G1=$g1.")
        1 <= c1 <= 6 ||
            error("TACS-formulation $label $(kernel.card_type) element $eid requires C1 in 1:6.")
        g2 = Int(get(spring, "G2", 0))
        c2 = Int(get(spring, "C2", 0))
        if g2 > 0
            haskey(grids, _tacs_id_key(g2)) ||
                error("TACS-formulation $label $(kernel.card_type) element $eid references missing G2=$g2.")
            1 <= c2 <= 6 ||
                error("TACS-formulation $label $(kernel.card_type) element $eid requires C2 in 1:6 when G2 is present.")
        end
    end
    pbushes = get(model, "PBUSHs", Dict())
    for (eid, bush) in get(model, "CBUSHs", Dict())
        pid = _tacs_id_key(get(bush, "PID", 0))
        prop = get(pbushes, pid, nothing)
        prop === nothing && error("TACS-formulation $label CBUSH element $eid references missing PBUSH property $pid.")
        k_vals = Float64.(collect(get(prop, "K", Float64[])))
        length(k_vals) >= 6 || error("TACS-formulation $label CBUSH property $pid requires six diagonal K values.")
        all(k -> k >= 0.0, k_vals[1:6]) || error("TACS-formulation $label CBUSH property $pid requires nonnegative diagonal K values.")
        any(k -> k > 0.0, k_vals[1:6]) || error("TACS-formulation $label CBUSH property $pid requires at least one positive K value.")
        ga = Int(get(bush, "GA", 0))
        gb = Int(get(bush, "GB", 0))
        ga > 0 && haskey(grids, _tacs_id_key(ga)) ||
            error("TACS-formulation $label CBUSH element $eid references missing/invalid GA=$ga.")
        if gb > 0
            haskey(grids, _tacs_id_key(gb)) ||
                error("TACS-formulation $label CBUSH element $eid references missing GB=$gb.")
        end
    end
    return nothing
end

function _tacs_validate_modal_mass_dof(model::Dict, grids::AbstractDict, gid_raw, comp_raw, label::AbstractString, card_type::AbstractString, eid)
    gid = _tacs_id_key(gid_raw)
    haskey(grids, gid) || error("TACS-formulation $label $card_type element $eid references missing grid $gid.")
    comp = Int(comp_raw)
    1 <= comp <= 6 || error("TACS-formulation $label $card_type element $eid requires component in 1:6.")
    return nothing
end

function _tacs_validate_modal_mass_slice(model::Dict, label::AbstractString)
    grids = get(model, "GRIDs", Dict())
    for (eid, mass) in get(model, "CONM2s", Dict())
        gid = _tacs_id_key(get(mass, "GID", 0))
        haskey(grids, gid) || error("TACS-formulation $label CONM2 element $eid references missing grid $gid.")
        cid = Int(get(mass, "CID", 0))
        cid == 0 || error("TACS-formulation $label CONM2 element $eid currently supports CID=0 offsets only.")
        m = Float64(get(mass, "M", 0.0))
        m > 0.0 || error("TACS-formulation $label CONM2 element $eid requires positive mass.")
        x = Float64.(collect(get(mass, "X", [0.0, 0.0, 0.0])))
        length(x) >= 3 || error("TACS-formulation $label CONM2 element $eid requires a 3-component offset vector.")
        all(isfinite, x[1:3]) || error("TACS-formulation $label CONM2 element $eid has nonfinite offset components.")
        inertia = Float64.(collect(get(mass, "I", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])))
        length(inertia) >= 6 || error("TACS-formulation $label CONM2 element $eid requires six inertia terms.")
        all(isfinite, inertia[1:6]) || error("TACS-formulation $label CONM2 element $eid has nonfinite inertia terms.")
        inertia[1] >= 0.0 && inertia[3] >= 0.0 && inertia[6] >= 0.0 ||
            error("TACS-formulation $label CONM2 element $eid requires nonnegative principal inertia terms.")
    end
    for (eid, mass) in get(model, "CONM1s", Dict())
        gid = _tacs_id_key(get(mass, "GID", 0))
        haskey(grids, gid) || error("TACS-formulation $label CONM1 element $eid references missing grid $gid.")
        cid = Int(get(mass, "CID", 0))
        cid == 0 || error("TACS-formulation $label CONM1 element $eid currently supports CID=0 only.")
        raw_full = get(mass, "M_FULL", nothing)
        m_full = if raw_full === nothing
            diagm(0 => Float64.(collect(get(mass, "M_DIAG", zeros(6)))))
        else
            Matrix{Float64}(raw_full)
        end
        size(m_full, 1) >= 6 && size(m_full, 2) >= 6 ||
            error("TACS-formulation $label CONM1 element $eid requires a 6x6 mass matrix.")
        m6 = m_full[1:6, 1:6]
        all(isfinite, vec(m6)) || error("TACS-formulation $label CONM1 element $eid has nonfinite mass terms.")
        norm(m6 - transpose(m6), Inf) <= 1e-10 * max(norm(m6, Inf), 1.0) ||
            error("TACS-formulation $label CONM1 element $eid requires a symmetric mass matrix.")
        all(d -> d >= 0.0, diag(m6)) ||
            error("TACS-formulation $label CONM1 element $eid requires nonnegative diagonal mass terms.")
        any(d -> d > 0.0, diag(m6)) ||
            error("TACS-formulation $label CONM1 element $eid requires at least one positive diagonal mass term.")
    end
    for (eid, mass) in get(model, "CMASS2s", Dict())
        m = Float64(get(mass, "M", 0.0))
        m > 0.0 || error("TACS-formulation $label CMASS2 element $eid requires positive mass.")
        g1 = Int(get(mass, "G1", 0))
        c1 = Int(get(mass, "C1", 0))
        g1 > 0 && c1 > 0 || error("TACS-formulation $label CMASS2 element $eid requires G1/C1.")
        _tacs_validate_modal_mass_dof(model, grids, g1, c1, label, "CMASS2", eid)
        g2 = Int(get(mass, "G2", 0))
        c2 = Int(get(mass, "C2", 0))
        if g2 > 0 || c2 > 0
            g2 > 0 && c2 > 0 || error("TACS-formulation $label CMASS2 element $eid requires both G2 and C2 when either is present.")
            _tacs_validate_modal_mass_dof(model, grids, g2, c2, label, "CMASS2", eid)
        end
    end
    pmasses = get(model, "PMASSs", Dict())
    for (eid, mass) in get(model, "CMASS1s", Dict())
        pid = _tacs_id_key(get(mass, "PID", 0))
        prop = get(pmasses, pid, nothing)
        prop === nothing && error("TACS-formulation $label CMASS1 element $eid references missing PMASS property $pid.")
        m = Float64(get(prop, "M", 0.0))
        m > 0.0 || error("TACS-formulation $label PMASS property $pid requires positive mass.")
        g1 = Int(get(mass, "G1", 0))
        c1 = Int(get(mass, "C1", 0))
        g1 > 0 && c1 > 0 || error("TACS-formulation $label CMASS1 element $eid requires G1/C1.")
        _tacs_validate_modal_mass_dof(model, grids, g1, c1, label, "CMASS1", eid)
        g2 = Int(get(mass, "G2", 0))
        c2 = Int(get(mass, "C2", 0))
        if g2 > 0 || c2 > 0
            g2 > 0 && c2 > 0 || error("TACS-formulation $label CMASS1 element $eid requires both G2 and C2 when either is present.")
            _tacs_validate_modal_mass_dof(model, grids, g2, c2, label, "CMASS1", eid)
        end
    end
    return nothing
end

_tacs_validate_conm2_slice(model::Dict, label::AbstractString) =
    _tacs_validate_modal_mass_slice(model, label)

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

function _tacs_mat1_line_material(model::Dict, mid_raw, nids::AbstractVector)
    mat = Solver._effective_mat1_for_nodes(model, mid_raw, nids)
    mat === nothing && error("TACS-formulation rod element references missing MAT1 material $mid_raw.")
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    mat_type in ("MAT1", "MAT1_EQUIV", "") ||
        error("TACS-formulation rod element supports MAT1/MAT1_EQUIV only; material $mid_raw has TYPE=$(get(mat, "TYPE", "?")).")
    E = Float64(get(mat, "E", 0.0))
    G = Float64(get(mat, "G", 0.0))
    nu = Float64(get(mat, "NU", -1.0))
    E, G, nu = Solver._complete_mat1_triplet(E, G, nu)
    E > 0.0 || error("TACS-formulation rod element requires positive MAT1 E.")
    G >= 0.0 || error("TACS-formulation rod element requires nonnegative MAT1 G.")
    return (E=E, G=G, nu=nu)
end

function _tacs_rod_frame_and_transform(ga::Integer, gb::Integer, id_map, X, node_R)
    haskey(id_map, ga) || error("TACS-formulation rod element references missing grid $ga.")
    haskey(id_map, gb) || error("TACS-formulation rod element references missing grid $gb.")
    i1, i2 = id_map[ga], id_map[gb]
    p1 = SVector{3,Float64}(X[i1, 1], X[i1, 2], X[i1, 3])
    p2 = SVector{3,Float64}(X[i2, 1], X[i2, 2], X[i2, 3])
    axis = p2 - p1
    L = norm(axis)
    L > 1e-9 || error("TACS-formulation rod element between grids $ga and $gb has near-zero length.")
    vx = axis / L
    ref = abs(vx[3]) < 0.9 ? SVector{3,Float64}(0.0, 0.0, 1.0) : SVector{3,Float64}(0.0, 1.0, 0.0)
    vz = normalize(cross(vx, ref))
    vy = cross(vz, vx)
    Rel_t = vcat(vx', vy', vz')

    T12 = zeros(Float64, 12, 12)
    TR1 = Rel_t * node_R[i1]
    TR2 = Rel_t * node_R[i2]
    T12[1:3, 1:3] = TR1
    T12[4:6, 4:6] = TR1
    T12[7:9, 7:9] = TR2
    T12[10:12, 10:12] = TR2

    dofs = Vector{Int}(undef, 12)
    for d in 1:6
        dofs[d] = (i1 - 1) * 6 + d
        dofs[6 + d] = (i2 - 1) * 6 + d
    end
    return (L=L, T12=T12, dofs=dofs)
end

function _tacs_rod_local_stiffness(L::Real, E::Real, G::Real, A::Real, J::Real)
    Ke = zeros(Float64, 12, 12)
    EA_L = Float64(E) * Float64(A) / Float64(L)
    Ke[1, 1] = EA_L
    Ke[1, 7] = -EA_L
    Ke[7, 1] = -EA_L
    Ke[7, 7] = EA_L
    GJ_L = Float64(G) * Float64(J) / Float64(L)
    Ke[4, 4] = GJ_L
    Ke[4, 10] = -GJ_L
    Ke[10, 4] = -GJ_L
    Ke[10, 10] = GJ_L
    return Ke
end

function _tacs_rod_local_mass(L::Real, rho::Real, A::Real, J::Real)
    return FEM.nastran_lumped_mass_rod(Float64(L), Float64(rho), Float64(A), Float64(J))
end

function _tacs_rod_property_material(model::Dict, rod::AbstractDict)
    kernel = _tacs_rod_element_kernel(rod)
    if kernel.family == :crod
        prods = get(model, "PRODs", Dict())
        pid = _tacs_id_key(get(rod, "PID", 0))
        prop = get(prods, pid, nothing)
        prop === nothing && error("TACS-formulation CROD element references missing PROD property $pid.")
        return (
            kernel=kernel,
            A=Float64(get(prop, "A", 0.0)),
            J=Float64(get(prop, "J", 0.0)),
            NSM=Float64(get(prop, "NSM", 0.0)),
            MID=get(prop, "MID", 0),
        )
    end
    return (
        kernel=kernel,
        A=Float64(get(rod, "A", 0.0)),
        J=Float64(get(rod, "J", 0.0)),
        NSM=Float64(get(rod, "NSM", 0.0)),
        MID=get(rod, "MID", 0),
    )
end

function _tacs_rod_residual_tangent(model::Dict, rod::AbstractDict, id_map, X, node_R)
    pdata = _tacs_rod_property_material(model, rod)
    kernel = pdata.kernel
    ga = Int(get(rod, "GA", 0))
    gb = Int(get(rod, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) rod requires positive GA/GB ids.")
    nids = [ga, gb]
    A, J, mid = pdata.A, pdata.J, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) rod requires positive area A.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) rod requires nonnegative torsion constant J.")
    mat = _tacs_mat1_line_material(model, mid, nids)
    rd = _tacs_rod_frame_and_transform(ga, gb, id_map, X, node_R)
    Ke_loc = _tacs_rod_local_stiffness(rd.L, mat.E, mat.G, A, J)
    return rd.T12' * Ke_loc * rd.T12, rd.dofs
end

function _tacs_rod_area_stiffness_derivative_tangent(model::Dict, rod::AbstractDict, id_map, X, node_R)
    pdata = _tacs_rod_property_material(model, rod)
    kernel = pdata.kernel
    ga = Int(get(rod, "GA", 0))
    gb = Int(get(rod, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) rod stiffness derivative requires positive GA/GB ids.")
    nids = [ga, gb]
    A, J, mid = pdata.A, pdata.J, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) rod stiffness derivative requires positive area A.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) rod stiffness derivative requires nonnegative torsion constant J.")
    mat = _tacs_mat1_line_material(model, mid, nids)
    rd = _tacs_rod_frame_and_transform(ga, gb, id_map, X, node_R)
    dKe_loc = zeros(12, 12)
    kA = mat.E / rd.L
    dKe_loc[1, 1] = kA
    dKe_loc[1, 7] = -kA
    dKe_loc[7, 1] = -kA
    dKe_loc[7, 7] = kA
    return rd.T12' * dKe_loc * rd.T12, rd.dofs
end

function _tacs_rod_mass_tangent(model::Dict, rod::AbstractDict, id_map, X, node_R)
    pdata = _tacs_rod_property_material(model, rod)
    kernel = pdata.kernel
    ga = Int(get(rod, "GA", 0))
    gb = Int(get(rod, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) rod mass requires positive GA/GB ids.")
    nids = [ga, gb]
    A, J, nsm, mid = pdata.A, pdata.J, pdata.NSM, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) rod mass requires positive area A.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass requires nonnegative torsion constant J.")
    nsm >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass requires nonnegative NSM.")
    mat = Solver._effective_mat1_for_nodes(model, mid, nids)
    mat === nothing && error("TACS-formulation $(kernel.card_type) rod mass references missing MAT1 material $mid.")
    rho = Float64(get(mat, "RHO", 0.0))
    rho >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass requires nonnegative material density.")
    rho_eff = rho + nsm / A
    rd = _tacs_rod_frame_and_transform(ga, gb, id_map, X, node_R)
    Me_loc = _tacs_rod_local_mass(rd.L, rho_eff, A, J)
    return rd.T12' * Me_loc * rd.T12, rd.dofs
end

function _tacs_rod_geometric_stiffness_operator(model::Dict, rod::AbstractDict, id_map, X, node_R, u_static::AbstractVector)
    pdata = _tacs_rod_property_material(model, rod)
    kernel = pdata.kernel
    ga = Int(get(rod, "GA", 0))
    gb = Int(get(rod, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) rod Kg requires positive GA/GB ids.")
    nids = [ga, gb]
    A, mid = pdata.A, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) rod Kg requires positive area A.")
    mat = _tacs_mat1_line_material(model, mid, nids)
    rd = _tacs_rod_frame_and_transform(ga, gb, id_map, X, node_R)
    u_elem = Float64.(u_static[rd.dofs])
    u_local = rd.T12 * u_elem
    axial_force = mat.E * A / rd.L * (u_local[7] - u_local[1])
    Kg_loc = FEM.geometric_stiffness_rod(Float64(rd.L), Float64(axial_force))
    return rd.T12' * Kg_loc * rd.T12, rd.dofs, axial_force
end

function _tacs_beam_property_material(model::Dict, beam::AbstractDict)
    kernel = _tacs_beam_element_kernel(beam)
    pid = _tacs_id_key(get(beam, "PID", 0))
    prop = get(get(model, "PBARLs", Dict()), pid, nothing)
    prop === nothing && error("TACS-formulation $(kernel.card_type) beam references missing PBAR/PBARL property $pid.")
    I_default = Float64(get(prop, "I", 0.0))
    return (
        kernel=kernel,
        A=Float64(get(prop, "A", 0.0)),
        Iy=Float64(get(prop, "I2", I_default)),
        Iz=Float64(get(prop, "I1", I_default)),
        J=Float64(get(prop, "J", 0.0)),
        I12=Float64(get(prop, "I12", 0.0)),
        K1=Float64(get(prop, "K1", 0.0)),
        K2=Float64(get(prop, "K2", 0.0)),
        NSM=Float64(get(prop, "NSM", 0.0)),
        MID=get(prop, "MID", 0),
        prop=prop,
    )
end

function _tacs_beam_reference_vector(beam::AbstractDict, ga::Integer, id_map, X)
    i1 = id_map[ga]
    g0 = Int(get(beam, "G0", 0))
    if g0 > 0 && haskey(id_map, g0)
        ig0 = id_map[g0]
        return SVector{3,Float64}(
            X[ig0, 1] - X[i1, 1],
            X[ig0, 2] - X[i1, 2],
            X[ig0, 3] - X[i1, 3],
        )
    end
    v_raw = get(beam, "V", [0.0, 0.0, 1.0])
    length(v_raw) >= 3 || error("TACS-formulation beam element requires a 3-component V orientation vector.")
    return SVector{3,Float64}(Float64(v_raw[1]), Float64(v_raw[2]), Float64(v_raw[3]))
end

function _tacs_beam_frame_and_transform(beam::AbstractDict, id_map, X, node_R)
    ga = Int(get(beam, "GA", 0))
    gb = Int(get(beam, "GB", 0))
    haskey(id_map, ga) || error("TACS-formulation beam element references missing grid $ga.")
    haskey(id_map, gb) || error("TACS-formulation beam element references missing grid $gb.")
    i1, i2 = id_map[ga], id_map[gb]
    p1 = SVector{3,Float64}(X[i1, 1], X[i1, 2], X[i1, 3])
    p2 = SVector{3,Float64}(X[i2, 1], X[i2, 2], X[i2, 3])
    wa, wb, has_offset, p1_eff, p2_eff = Solver.bar_offsets_and_endpoints(beam, p1, p2)
    axis = p2_eff - p1_eff
    L = norm(axis)
    L > 1e-9 || error("TACS-formulation beam element between grids $ga and $gb has near-zero length.")
    vx = axis / L
    v_ref = _tacs_beam_reference_vector(beam, ga, id_map, X)
    if norm(v_ref) < 1e-8 || abs(dot(vx, v_ref) / max(norm(v_ref), 1e-30)) > 0.999
        v_ref = abs(vx[3]) < 0.9 ? SVector{3,Float64}(0.0, 0.0, 1.0) : SVector{3,Float64}(0.0, 1.0, 0.0)
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
        S_wa = Solver.skew3(wa)
        S_wb = Solver.skew3(wb)
        T12[1:3, 4:6] = -Rel_t * S_wa * node_R[i1]
        T12[7:9, 10:12] = -Rel_t * S_wb * node_R[i2]
    end

    dofs = Vector{Int}(undef, 12)
    for d in 1:6
        dofs[d] = (i1 - 1) * 6 + d
        dofs[6 + d] = (i2 - 1) * 6 + d
    end
    return (L=L, T12=T12, dofs=dofs)
end

function _tacs_beam_residual_tangent(model::Dict, beam::AbstractDict, id_map, X, node_R)
    pdata = _tacs_beam_property_material(model, beam)
    kernel = pdata.kernel
    ga = Int(get(beam, "GA", 0))
    gb = Int(get(beam, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) beam requires positive GA/GB ids.")
    nids = [ga, gb]
    A, Iy, Iz, J = pdata.A, pdata.Iy, pdata.Iz, pdata.J
    A > 0.0 || error("TACS-formulation $(kernel.card_type) beam requires positive area A.")
    Iy >= 0.0 || error("TACS-formulation $(kernel.card_type) beam requires nonnegative I2/Iy.")
    Iz >= 0.0 || error("TACS-formulation $(kernel.card_type) beam requires nonnegative I1/Iz.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) beam requires nonnegative torsion constant J.")
    mat = _tacs_mat1_line_material(model, pdata.MID, nids)
    bd = _tacs_beam_frame_and_transform(beam, id_map, X, node_R)
    As_y = pdata.K1 > 0.0 ? pdata.K1 * A : Inf
    As_z = pdata.K2 > 0.0 ? pdata.K2 * A : Inf
    Ke_station =
        _tacs_beam_station_properties_constant(pdata.prop) ? nothing :
        _tacs_beam_station_condensed_stiffness(Float64(bd.L), pdata.prop, mat.E, mat.G)
    Ke_loc =
        Ke_station === nothing ?
        FEM.stiffness_frame3d(
            Float64(bd.L),
            A,
            Iy,
            Iz,
            J,
            mat.E,
            mat.G;
            As_y=As_y,
            As_z=As_z,
            I12=pdata.I12,
        ) :
        Ke_station
    pa = Int(get(beam, "PA", 0))
    pb = Int(get(beam, "PB", 0))
    if pa != 0 || pb != 0
        Ke_loc = Matrix(Ke_loc)
        Solver.apply_bar_pin_flags!(Ke_loc, pa, pb)
    end
    Ke = bd.T12' * Ke_loc * bd.T12
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    return Ke, bd.dofs
end

function _tacs_beam_mass_tangent(model::Dict, beam::AbstractDict, id_map, X, node_R)
    pdata = _tacs_beam_property_material(model, beam)
    kernel = pdata.kernel
    ga = Int(get(beam, "GA", 0))
    gb = Int(get(beam, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) beam mass requires positive GA/GB ids.")
    nids = [ga, gb]
    A, Iy, Iz, J, nsm = pdata.A, pdata.Iy, pdata.Iz, pdata.J, pdata.NSM
    A > 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires positive area A.")
    Iy >= 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires nonnegative I2/Iy.")
    Iz >= 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires nonnegative I1/Iz.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires nonnegative torsion constant J.")
    nsm >= 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires nonnegative NSM.")
    mat = Solver._effective_mat1_for_nodes(model, pdata.MID, nids)
    mat === nothing && error("TACS-formulation $(kernel.card_type) beam mass references missing MAT1 material $(pdata.MID).")
    rho = Float64(get(mat, "RHO", 0.0))
    rho >= 0.0 || error("TACS-formulation $(kernel.card_type) beam mass requires nonnegative material density.")
    E = Float64(get(mat, "E", 0.0))
    G = Float64(get(mat, "G", 0.0))
    nu = Float64(get(mat, "NU", -1.0))
    E, G, _ = Solver._complete_mat1_triplet(E, G, nu)
    rho_eff = rho + nsm / A
    bd = _tacs_beam_frame_and_transform(beam, id_map, X, node_R)
    Me_station =
        _tacs_beam_station_properties_constant(pdata.prop) ? nothing :
        _tacs_beam_station_condensed_mass(Float64(bd.L), pdata.prop, E, G, rho, nsm)
    Me_loc =
        Me_station === nothing ?
        FEM.nastran_lumped_mass_frame3d(Float64(bd.L), rho_eff, A, J, Iy, Iz) :
        Me_station
    Me = bd.T12' * Me_loc * bd.T12
    Me .= 0.5 .* (Me .+ transpose(Me))
    return Me, bd.dofs
end

function _tacs_beam_geometric_stiffness_operator(model::Dict, beam::AbstractDict, id_map, X, node_R, u_static::AbstractVector)
    pdata = _tacs_beam_property_material(model, beam)
    kernel = pdata.kernel
    ga = Int(get(beam, "GA", 0))
    gb = Int(get(beam, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) beam Kg requires positive GA/GB ids.")
    nids = [ga, gb]
    A, mid = pdata.A, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) beam Kg requires positive area A.")
    mat = _tacs_mat1_line_material(model, mid, nids)
    bd = _tacs_beam_frame_and_transform(beam, id_map, X, node_R)
    u_elem = Float64.(u_static[bd.dofs])
    u_local = bd.T12 * u_elem
    if !_tacs_beam_station_properties_constant(pdata.prop)
        Kg_station, axial_force = _tacs_beam_station_condensed_geometric_stiffness(
            Float64(bd.L),
            pdata.prop,
            mat.E,
            mat.G,
            u_local,
        )
        Kg_station === nothing &&
            error("TACS-formulation $(kernel.card_type) beam Kg could not build varying PBEAM/PBEAML station operator.")
        Kg_loc = Kg_station
    else
        axial_force = mat.E * A / bd.L * (u_local[7] - u_local[1])
        Kg_loc = FEM.geometric_stiffness_frame3d(Float64(bd.L), Float64(axial_force))
    end
    Kg = bd.T12' * Kg_loc * bd.T12
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    return Kg, bd.dofs, axial_force
end

function _tacs_spring_residual_tangent(model::Dict, spring::AbstractDict, id_map)
    kernel = _tacs_spring_element_kernel(spring)
    k = _tacs_spring_stiffness(model, spring, "SOL101", get(spring, "ID", "?"))
    g1 = Int(get(spring, "G1", 0))
    c1 = Int(get(spring, "C1", 0))
    haskey(id_map, g1) && 1 <= c1 <= 6 ||
        error("TACS-formulation $(kernel.card_type) spring references invalid G1/C1.")
    dof1 = (id_map[g1] - 1) * 6 + c1
    g2 = Int(get(spring, "G2", 0))
    c2 = Int(get(spring, "C2", 0))
    if g2 > 0
        haskey(id_map, g2) && 1 <= c2 <= 6 ||
            error("TACS-formulation $(kernel.card_type) spring references invalid G2/C2.")
        dof2 = (id_map[g2] - 1) * 6 + c2
        return [k -k; -k k], [dof1, dof2]
    end
    return reshape([k], 1, 1), [dof1]
end

function _tacs_bush_residual_tangent(model::Dict, bush::AbstractDict, id_map)
    _ = _tacs_spring_element_kernel(merge(Dict{String,Any}("TYPE" => "CBUSH"), bush))
    pid = _tacs_id_key(get(bush, "PID", 0))
    prop = get(get(model, "PBUSHs", Dict()), pid, nothing)
    prop === nothing && error("TACS-formulation CBUSH references missing PBUSH property $pid.")
    k_vals = Float64.(collect(get(prop, "K", zeros(6))))
    length(k_vals) >= 6 || error("TACS-formulation CBUSH property $pid requires six diagonal K values.")
    ga = Int(get(bush, "GA", 0))
    gb = Int(get(bush, "GB", 0))
    haskey(id_map, ga) || error("TACS-formulation CBUSH references missing GA=$ga.")
    i1 = id_map[ga]
    if gb > 0
        haskey(id_map, gb) || error("TACS-formulation CBUSH references missing GB=$gb.")
        i2 = id_map[gb]
        dofs = vcat([(i1 - 1) * 6 + k for k in 1:6], [(i2 - 1) * 6 + k for k in 1:6])
        Ke = zeros(Float64, 12, 12)
        for k in 1:6
            kk = k_vals[k]
            kk == 0.0 && continue
            Ke[k, k] += kk
            Ke[6 + k, 6 + k] += kk
            Ke[k, 6 + k] -= kk
            Ke[6 + k, k] -= kk
        end
        return Ke, dofs
    end
    active = [k for k in 1:6 if k_vals[k] != 0.0]
    dofs = [(i1 - 1) * 6 + k for k in active]
    Ke = zeros(Float64, length(active), length(active))
    for (j, k) in enumerate(active)
        Ke[j, j] = k_vals[k]
    end
    return Ke, dofs
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

function _tacs_mat8_pshell_constitutive(prop::AbstractDict, mat::AbstractDict, el::AbstractDict)
    h = get(prop, "T", 0.0)
    h > 0.0 || error("TACS-formulation PSHELL/MAT8 thickness must be positive.")
    E1 = Float64(get(mat, "E1", 0.0))
    E2 = Float64(get(mat, "E2", 0.0))
    G12 = Float64(get(mat, "G12", 0.0))
    nu12 = Float64(get(mat, "NU12", 0.0))
    E1 > 0.0 || error("TACS-formulation MAT8 E1 must be positive.")
    E2 > 0.0 || error("TACS-formulation MAT8 E2 must be positive.")
    G12 > 0.0 || error("TACS-formulation MAT8 G12 must be positive.")
    -0.49 < nu12 < 0.49 || error("TACS-formulation MAT8 NU12 must be in (-0.49, 0.49).")

    theta = deg2rad(Float64(get(el, "THETA", 0.0)))
    Q = Solver._qbar_plane_stress(E1, E2, nu12, G12, theta)
    G13 = Float64(get(mat, "G1Z", 0.0))
    G23 = Float64(get(mat, "G2Z", 0.0))
    G13 <= 0.0 && (G13 = G12)
    G23 <= 0.0 && (G23 = G12)
    Qs = Solver._qbar_shear(G13, G23, theta)

    Cm = h .* Q
    Cb = (h^3 / 12.0) .* Q
    ts_t = Float64(get(prop, "TS_T", 5.0 / 6.0))
    Cs = (ts_t * h) .* Qs
    Eref = max(E1, E2, G12, G13, G23)
    return Cm, Cb, Cs, h, Eref
end

function _tacs_mat2_pshell_constitutive(prop::AbstractDict, mat::AbstractDict, el::AbstractDict)
    h = get(prop, "T", 0.0)
    h > 0.0 || error("TACS-formulation PSHELL/MAT2 thickness must be positive.")
    Q = [
        Float64(get(mat, "G11", 0.0)) Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G13", 0.0));
        Float64(get(mat, "G12", 0.0)) Float64(get(mat, "G22", 0.0)) Float64(get(mat, "G23", 0.0));
        Float64(get(mat, "G13", 0.0)) Float64(get(mat, "G23", 0.0)) Float64(get(mat, "G33", 0.0))
    ]
    maximum(abs.(Q)) > 0.0 || error("TACS-formulation MAT2 in-plane constitutive matrix is zero.")
    theta = deg2rad(Float64(get(el, "THETA", 0.0)))
    abs(theta) > 1e-12 && FEM.rotate_constitutive_3x3!(Q, theta)

    Gxz = Float64(get(mat, "G13", 0.0))
    Gyz = Float64(get(mat, "G23", 0.0))
    if Gxz <= 0.0 && Gyz <= 0.0
        Gxz = Float64(get(mat, "G33", 0.0))
        Gyz = Gxz
    elseif Gxz <= 0.0
        Gxz = Gyz
    elseif Gyz <= 0.0
        Gyz = Gxz
    end
    Qs = [Gxz 0.0; 0.0 Gyz]
    abs(theta) > 1e-12 && FEM.rotate_constitutive_2x2!(Qs, theta)

    Cm = h .* Q
    Cb = (h^3 / 12.0) .* Q
    ts_t = Float64(get(prop, "TS_T", 5.0 / 6.0))
    Cs = (ts_t * h) .* Qs
    Eref = max(maximum(abs.(Q)), Gxz, Gyz, 1.0)
    return Cm, Cb, Cs, h, Eref
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
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    Cm, Cb, Cs, h, Eref =
        mat_type == "MAT8" ?
        _tacs_mat8_pshell_constitutive(prop, mat, el) :
        mat_type == "MAT2" ?
        _tacs_mat2_pshell_constitutive(prop, mat, el) :
        _tacs_mat1_pshell_constitutive(prop, mat)
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
    ctx = _tacs_shell_element_context(model, el, id_map, X, node_R)
    ctx.kernel.node_count == 4 ||
        error("TACS-formulation quad shell operator received $(ctx.kernel.node_count)-node element.")
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, ctx.property, el)
    Ke_local = FEM.stiffness_quad4_matrices(
        ctx.local_coords, Cm, Cb, Cs, h, Eref;
        Bmb=Bmb,
        k6rot=1.0,
        membrane_incomp=false,
        bending_incomp=false,
        shear_center_only=false,
        selective_shear=true,
        macneal_rigid_shear=false,
    )
    Ke = transpose(ctx.transform) * Ke_local * ctx.transform
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    return Ke, ctx.dofs
end

function _tacs_tria3_shell_operator(model::Dict, el::AbstractDict, id_map, X, node_R)
    ctx = _tacs_shell_element_context(model, el, id_map, X, node_R)
    ctx.kernel.node_count == 3 ||
        error("TACS-formulation CTRIA3 shell operator received $(ctx.kernel.node_count)-node element.")
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, ctx.property, el)
    Ke_local = FEM.stiffness_tria3_matrices(
        ctx.local_coords, Cm, Cb, Cs, h, Eref;
        bend_ratio=1.0,
        k6rot=1.0,
        Bmb=Bmb,
    )
    Ke = transpose(ctx.transform) * Ke_local * ctx.transform
    Ke .= 0.5 .* (Ke .+ transpose(Ke))
    return Ke, ctx.dofs
end

function _tacs_shell_residual_tangent(model::Dict, el::AbstractDict, id_map, X, node_R)
    return _tacs_shell_residual_tangent(_tacs_shell_element_kernel(el), model, el, id_map, X, node_R)
end

function _tacs_shell_residual_tangent(kernel::TACSShellElementKernel, model::Dict, el::AbstractDict, id_map, X, node_R)
    kernel.node_count == 4 && return _tacs_quad4_shell_residual_tangent(model, el, id_map, X, node_R)
    kernel.node_count == 3 && return _tacs_tria3_shell_operator(model, el, id_map, X, node_R)
    error("TACS-formulation shell residual/tangent supports CQUAD4/CQUADR/CTRIA3 only; got $(kernel.node_count) nodes.")
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
    ctx = _tacs_shell_element_context(model, el, id_map, X, node_R)
    ctx.kernel.node_count == 4 ||
        error("TACS-formulation quad shell Kg operator received $(ctx.kernel.node_count)-node element.")
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, ctx.property, el)
    _ = Cb, Cs, Eref

    u_local = ctx.transform * Float64.(u_global[ctx.dofs])
    Bm, Bb = _tacs_quad4_membrane_bending_B_center(ctx.local_coords)
    eps0 = Bm * u_local
    kappa = Bb * u_local
    membrane_resultant = Cm * eps0
    Bmb !== nothing && (membrane_resultant .+= Bmb * kappa)
    sigma_mem = membrane_resultant ./ max(h, 1e-30)

    Kg_local = FEM.geometric_stiffness_quad4(
        ctx.local_coords,
        sigma_mem,
        h;
        Cm=Cm,
        membrane_incomp=false,
        membrane_enhanced=false,
    )
    Kg = transpose(ctx.transform) * Kg_local * ctx.transform
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    return Kg, ctx.dofs, membrane_resultant
end

function _tacs_tria3_shell_geometric_stiffness_operator(
    model::Dict,
    el::AbstractDict,
    id_map,
    X,
    node_R,
    u_global::AbstractVector,
)
    ctx = _tacs_shell_element_context(model, el, id_map, X, node_R)
    ctx.kernel.node_count == 3 ||
        error("TACS-formulation CTRIA3 shell Kg operator received $(ctx.kernel.node_count)-node element.")
    Cm, Cb, Cs, h, Eref, Bmb = _tacs_shell_constitutive(model, ctx.property, el)
    _ = Cb, Cs, Bmb

    u_local = ctx.transform * Float64.(u_global[ctx.dofs])
    mat =
        uppercase(string(get(ctx.property, "TYPE", "PSHELL"))) == "PSHELL" ?
        model["MATs"][string(Int(ctx.property["MID"]))] :
        Dict{String,Any}("E" => Eref, "NU" => 0.3)
    E = Float64(get(mat, "E", Eref))
    nu = Float64(get(mat, "NU", 0.3))
    prop_type = uppercase(string(get(ctx.property, "TYPE", "PSHELL")))
    mat_type =
        prop_type == "PSHELL" ?
        uppercase(string(get(mat, "TYPE", "MAT1"))) :
        ""
    cm_override = (prop_type == "PCOMP_CLT" || mat_type in ("MAT2", "MAT8")) ? Cm : nothing
    membrane_resultant, _, _, _, _, _, _ =
        FEM.stress_strain_tria3(ctx.local_coords, u_local, E, nu, Float64(h); Cm_override=cm_override)
    sigma_mem = membrane_resultant ./ max(Float64(h), 1e-30)

    Kg_local = FEM.geometric_stiffness_tria3(ctx.local_coords, sigma_mem, Float64(h))
    Kg = transpose(ctx.transform) * Kg_local * ctx.transform
    Kg .= 0.5 .* (Kg .+ transpose(Kg))
    return Kg, ctx.dofs, membrane_resultant
end

function _tacs_shell_geometric_stiffness_operator(model::Dict, el::AbstractDict, id_map, X, node_R, u_global::AbstractVector)
    return _tacs_shell_geometric_stiffness_operator(_tacs_shell_element_kernel(el), model, el, id_map, X, node_R, u_global)
end

function _tacs_shell_geometric_stiffness_operator(
    kernel::TACSShellElementKernel,
    model::Dict,
    el::AbstractDict,
    id_map,
    X,
    node_R,
    u_global::AbstractVector,
)
    kernel.node_count == 4 && return _tacs_quad4_shell_geometric_stiffness_operator(model, el, id_map, X, node_R, u_global)
    kernel.node_count == 3 && return _tacs_tria3_shell_geometric_stiffness_operator(model, el, id_map, X, node_R, u_global)
    error("TACS-formulation shell geometric stiffness supports CQUAD4/CQUADR/CTRIA3 only; got $(kernel.node_count) nodes.")
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
    if dv_type == "node_coord"
        grid = Int(get(dv, "grid", get(dv, "gid", 0)))
        comp = _tacs_node_coord_component(dv)
        return "node_coord_GRID$(grid)_C$(comp)"
    end
    pids = join(string.(get(dv, "pids", Any[])), "_")
    eids = join(string.(get(dv, "eids", Any[])), "_")
    ply = haskey(dv, "ply_index") ? "_ply$(Int(dv["ply_index"]))" : ""
    comp = haskey(dv, "component") ? "_C$(Int(dv["component"]))" :
           haskey(dv, "comp") ? "_C$(Int(dv["comp"]))" : ""
    selector = !isempty(pids) ? "_PID$(pids)" : !isempty(eids) ? "_EID$(eids)" : ""
    return "$(dv_type)$(selector)$(ply)$(comp)"
end

function _tacs_node_coord_component(dv::AbstractDict)
    raw = get(dv, "comp", get(dv, "component", get(dv, "axis", nothing)))
    raw === nothing && error("TACS node_coord design variable requires comp/component/axis.")
    return _tacs_coordinate_component(raw)
end

function _tacs_coordinate_step(model::AbstractDict, dv::AbstractDict)
    grid = Int(get(dv, "grid", get(dv, "gid", 0)))
    comp = _tacs_node_coord_component(dv)
    grid > 0 || error("TACS node_coord design variable requires a positive grid/gid.")
    grid_str = string(grid)
    grid_data = get(get(model, "GRIDs", Dict()), grid_str, nothing)
    grid_data === nothing && error("TACS coordinate derivative could not find GRID $grid.")
    coords = Float64.(collect(get(grid_data, "X", Float64[])))
    length(coords) >= 3 || error("TACS coordinate derivative requires GRID $grid to have three coordinates.")
    raw_step = get(dv, "step", nothing)
    if raw_step !== nothing
        step = Float64(raw_step)
        step > 0.0 || error("TACS node_coord finite-difference step must be positive; got $step.")
        return step
    end
    return max(abs(coords[comp]) * 1e-6, 1e-8)
end

function _tacs_model_with_grid_coord_delta(
    model::AbstractDict,
    grid::Integer,
    comp::Integer,
    delta::Real,
)
    m = deepcopy(model)
    grid_str = string(Int(grid))
    grid_data = get(get(m, "GRIDs", Dict()), grid_str, nothing)
    grid_data === nothing && error("TACS coordinate perturbation could not find GRID $grid.")
    coords = Float64.(collect(get(grid_data, "X", Float64[])))
    length(coords) >= 3 || error("TACS coordinate perturbation requires GRID $grid to have three coordinates.")
    coords[Int(comp)] += Float64(delta)
    grid_data["X"] = coords
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_assemble_sol101_coordinate_derivative(
    model::Dict,
    dv::AbstractDict;
    allowed_sol_types=(101,),
    route_label="SOL101 coordinate sensitivity",
)
    allow_rod_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_beam_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_spring_slice = any(s -> Int(s) in (101, 103), allowed_sol_types)
    allow_mass_slice = any(s -> Int(s) == 103, allowed_sol_types)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=allowed_sol_types,
        route_label=route_label,
        allow_rods=allow_rod_slice,
        allow_beams=allow_beam_slice,
        allow_springs=allow_spring_slice,
        allow_masses=allow_mass_slice,
        allow_conm1=allow_mass_slice,
        require_shell=!(allow_rod_slice || allow_beam_slice || allow_spring_slice),
    )
    grid = Int(get(dv, "grid", get(dv, "gid", 0)))
    comp = _tacs_node_coord_component(dv)
    h = _tacs_coordinate_step(model, dv)
    model_p = _tacs_model_with_grid_coord_delta(model, grid, comp, h)
    model_m = _tacs_model_with_grid_coord_delta(model, grid, comp, -h)

    Kp, id_map, X, ndof, node_R, _, _, _, _ =
        _tacs_assemble_sol101(model_p; allowed_sol_types=allowed_sol_types, route_label=route_label)
    Km, id_map_m, _, ndof_m, _, _, _, _, _ =
        _tacs_assemble_sol101(model_m; allowed_sol_types=allowed_sol_types, route_label=route_label)
    ndof == ndof_m || error("TACS coordinate derivative changed ndof for GRID $grid component $comp.")
    length(id_map) == length(id_map_m) || error("TACS coordinate derivative changed GRID map size.")

    dK = (Kp .- Km) ./ (2.0 * h)
    dK = 0.5 .* (dK .+ transpose(dK))
    return dK, id_map, X, ndof, node_R, [h]
end

function _tacs_case_control_subcase(model::AbstractDict, sid::Integer)
    cc = get(model, "CASE_CONTROL", Dict{String,Any}())
    subcases = get(cc, "SUBCASES", Dict{Int,Any}())
    haskey(subcases, Int(sid)) && return subcases[Int(sid)]
    haskey(subcases, string(Int(sid))) && return subcases[string(Int(sid))]
    error("TACS static load sensitivity could not find CASE CONTROL subcase $sid.")
end

function _tacs_result_subcase_sid(results::AbstractDict, subcase_index::Integer=1)
    subcases = get(results, "subcases", Any[])
    idx = Int(subcase_index)
    1 <= idx <= length(subcases) || error("TACS static load sensitivity requested subcase index $idx but only $(length(subcases)) are available.")
    sub = subcases[idx]
    haskey(sub, "sid") && return Int(sub["sid"])
    cc_subcases = get(get(results["model"], "CASE_CONTROL", Dict{String,Any}()), "SUBCASES", Dict{Int,Any}())
    sids = sort!(Int.(parse.(Int, string.(collect(keys(cc_subcases))))))
    1 <= idx <= length(sids) || error("TACS static load sensitivity could not infer subcase id for index $idx.")
    return sids[idx]
end

function _tacs_static_load_ids(model::AbstractDict, sid::Integer)
    cc = get(model, "CASE_CONTROL", Dict{String,Any}())
    sub = _tacs_case_control_subcase(model, sid)
    load_id = get(sub, "LOAD", nothing)
    temp_load_id = Solver._subcase_temp_load_sid(sub, cc)
    return load_id, temp_load_id
end

function _tacs_static_load_vector(
    model::Dict,
    sid::Integer;
    expected_ndof=nothing,
    rbe3_map=Dict{Int,Vector{Tuple{Int,Float64}}}(),
)
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    expected_ndof === nothing || ndof == Int(expected_ndof) ||
        error("TACS static load sensitivity changed ndof from $(Int(expected_ndof)) to $ndof.")
    load_id, temp_load_id = _tacs_static_load_ids(model, sid)
    return Solver._assemble_applied_force(
        ndof,
        model,
        id_map,
        X,
        load_id,
        node_R,
        rbe3_map;
        temp_load_id=temp_load_id,
        log_rbe3=false,
    )
end

function _tacs_static_load_fd_step(model::AbstractDict, dv::AbstractDict, stiffness_steps=Float64[])
    raw_step = get(dv, "step", nothing)
    if raw_step !== nothing
        step = Float64(raw_step)
        step > 0.0 || error("TACS static load finite-difference step must be positive; got $step.")
        return step
    end
    nonzero_steps = abs.(Float64.(collect(stiffness_steps)))
    nonzero_steps = [s for s in nonzero_steps if s > 0.0]
    !isempty(nonzero_steps) && return maximum(nonzero_steps)

    dv_type = string(get(dv, "type", ""))
    if dv_type == "node_coord"
        return _tacs_coordinate_step(model, dv)
    elseif dv_type == "shell_thickness"
        pid_list = Int.(collect(get(dv, "pids", _tacs_sol101_active_shell_pids(model))))
        isempty(pid_list) && (pid_list = _tacs_sol101_active_shell_pids(model))
        isempty(pid_list) && error("TACS static load shell-thickness derivative requires at least one active shell property.")
        h = Inf
        for pid in pid_list
            prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS static load derivative could not find shell property $pid.")
            t0 = Float64(get(prop, "T", 0.0))
            t0 > 0.0 || error("TACS static load derivative requires positive property thickness.")
            h = min(h, max(1e-6 * t0, 1e-8), 0.25 * t0)
        end
        isfinite(h) && h > 0.0 || error("TACS static load derivative could not choose a shell-thickness step.")
        return h
    elseif dv_type in ("pcomp_ply_thickness", "pcomp_ply_angle")
        ply_idx = Int(get(dv, "ply_index", 0))
        ply_idx > 0 || error("TACS static load PCOMP derivative requires a positive ply_index.")
        pid_list = Int.(collect(get(dv, "pids", Int[])))
        if isempty(pid_list)
            for (pid, prop) in get(model, "PSHELLs", Dict())
                uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || continue
                push!(pid_list, Int(parse(Int, string(pid))))
            end
        end
        isempty(pid_list) && error("TACS static load PCOMP derivative requires at least one PCOMP_CLT property.")
        perturb_field = dv_type == "pcomp_ply_thickness" ? :T : :THETA
        h = Inf
        for pid in pid_list
            prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS static load derivative could not find PCOMP property $pid.")
            h = min(h, _tacs_pcomp_ply_step(prop, ply_idx, perturb_field))
        end
        isfinite(h) && h > 0.0 || error("TACS static load derivative could not choose a PCOMP step.")
        return h
    elseif dv_type in _tacs_material_design_types()
        return _tacs_material_group_design_step(model, dv)
    end
    error("TACS static load derivative does not support design variable type '$dv_type'.")
end

function _tacs_static_load_design_dependent(dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    return dv_type in ("node_coord", "shell_thickness", "pcomp_ply_thickness",
                       "pcomp_ply_angle", "material_ALPHA", "material_TREF") ||
           dv_type in _tacs_material_stiffness_design_types() ||
           dv_type == "material_RHO"
end

function _tacs_assemble_sol101_load_design_derivative(
    results::AbstractDict,
    dv::AbstractDict;
    stiffness_steps=Float64[],
    subcase_index::Integer=1,
    sid=nothing,
    allowed_sol_types=(101,),
    route_label="SOL101 design-dependent load sensitivity",
)
    model = results["model"]
    allow_rod_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_beam_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_spring_slice = any(s -> Int(s) in (101, 103), allowed_sol_types)
    allow_mass_slice = any(s -> Int(s) == 103, allowed_sol_types)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=allowed_sol_types,
        route_label=route_label,
        allow_rods=allow_rod_slice,
        allow_beams=allow_beam_slice,
        allow_springs=allow_spring_slice,
        allow_masses=allow_mass_slice,
        allow_conm1=allow_mass_slice,
        require_shell=!(allow_rod_slice || allow_beam_slice || allow_spring_slice),
    )
    static_sid = sid === nothing ? _tacs_result_subcase_sid(results, subcase_index) : Int(sid)
    load_id, temp_load_id = _tacs_static_load_ids(model, static_sid)
    ndof = Int(results["ndof"])
    if isnothing(load_id) && isnothing(temp_load_id)
        return zeros(Float64, ndof), Float64[]
    end
    _tacs_static_load_design_dependent(dv) || return zeros(Float64, ndof), Float64[]

    h = _tacs_static_load_fd_step(model, dv, stiffness_steps)
    h > 0.0 || error("TACS static load derivative requires a positive perturbation step.")
    model_p, model_m =
        string(get(dv, "type", "")) == "node_coord" ? begin
            grid = Int(get(dv, "grid", get(dv, "gid", 0)))
            comp = _tacs_node_coord_component(dv)
            (
                _tacs_model_with_grid_coord_delta(model, grid, comp, h),
                _tacs_model_with_grid_coord_delta(model, grid, comp, -h),
            )
        end :
        (
            _tacs_model_with_design_delta(model, dv, h),
            _tacs_model_with_design_delta(model, dv, -h),
    )
    rbe3_map = get(results, "rbe3_map", Dict{Int,Vector{Tuple{Int,Float64}}}())
    Fp = _tacs_static_load_vector(model_p, static_sid; expected_ndof=ndof, rbe3_map=rbe3_map)
    Fm = _tacs_static_load_vector(model_m, static_sid; expected_ndof=ndof, rbe3_map=rbe3_map)
    return (Fp .- Fm) ./ (2.0 * h), [h]
end

function _tacs_gradient_backend_label(contract::TACSSensitivityContract, default_label::AbstractString)
    contract.derivative_method == :adjoint_coordinate_fd && return "tacs_formulation_coordinate_fd"
    contract.derivative_method == :adjoint_coordinate_fd_explicit_stress && return "tacs_formulation_stress_coordinate_fd_adjoint"
    contract.derivative_method == :adjoint_load_fd && return "tacs_formulation_load_fd_adjoint"
    contract.derivative_method == :rayleigh_coordinate_kg_directional_fd && return "tacs_formulation_rayleigh_coordinate_kg_directional_fd"
    contract.derivative_method == :rayleigh_kg_directional_fd && return "tacs_formulation_rayleigh_ad_kg_directional_fd"
    contract.derivative_method == :rayleigh_design_kg_directional_fd && return "tacs_formulation_rayleigh_design_kg_directional_fd"
    contract.derivative_method == :rayleigh_load_kg_directional_fd && return "tacs_formulation_rayleigh_load_kg_directional_fd"
    contract.derivative_method == :modal_coordinate_fd && return "tacs_formulation_modal_coordinate_fd"
    contract.derivative_method == :modal_design_tangent_fd && return "tacs_formulation_modal_design_tangent_fd"
    contract.derivative_method == :modal_mass_design_fd && return "tacs_formulation_modal_mass_design_fd"
    contract.derivative_method == :mass_coordinate_fd && return "tacs_formulation_mass_coordinate_fd"
    contract.derivative_method == :mass_coefficient && return "tacs_formulation_mass_coefficient"
    contract.derivative_method == :mass_independent && return "tacs_formulation_mass_independent"
    return String(default_label)
end

function _tacs_gradient_backend_summary(labels::AbstractVector{<:AbstractString}, fallback::AbstractString)
    isempty(labels) && return String(fallback)
    unique_labels = sort!(unique(String.(labels)))
    length(unique_labels) == 1 && return first(unique_labels)
    any(occursin("modal", label) for label in unique_labels) &&
        return "tacs_formulation_mixed_modal_design_coordinate_fd"
    any(occursin("rayleigh", label) for label in unique_labels) &&
        return "tacs_formulation_mixed_buckling_design_coordinate_fd"
    any(occursin("mass", label) for label in unique_labels) &&
        return "tacs_formulation_mixed_mass_design_coordinate_fd"
    any(occursin("load", label) for label in unique_labels) &&
        return "tacs_formulation_mixed_design_load_fd"
    return "tacs_formulation_mixed_design_tangent_coordinate_fd"
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

function _tacs_pcomp_shear_corrected(Ash::AbstractMatrix, ply_data::AbstractVector, total_t::Float64)
    ts_t_default = 5.0 / 6.0
    Cs_lam =
        pcomp_whitney_shear_enabled() && !isempty(ply_data) ? begin
            kappa_x, kappa_y = pcomp_whitney_kappa(collect(ply_data), total_t)
            [kappa_x * Ash[1,1] kappa_x * Ash[1,2]; kappa_y * Ash[2,1] kappa_y * Ash[2,2]]
        end :
        ts_t_default .* Ash

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

    Cs = _tacs_pcomp_shear_corrected(Ash, perturbed_ply_data, total_t)
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

function _tacs_material_design_field(dv_type::AbstractString)
    dv_type == "material_E" && return "E"
    dv_type == "material_G" && return "G"
    dv_type == "material_NU" && return "NU"
    dv_type == "material_RHO" && return "RHO"
    dv_type == "material_ALPHA" && return "ALPHA"
    dv_type == "material_TREF" && return "TREF"
    dv_type == "material_E1" && return "E1"
    dv_type == "material_E2" && return "E2"
    dv_type == "material_G11" && return "G11"
    dv_type == "material_G12" && return "G12"
    dv_type == "material_G13" && return "G13"
    dv_type == "material_G22" && return "G22"
    dv_type == "material_G23" && return "G23"
    dv_type == "material_G33" && return "G33"
    dv_type == "material_NU12" && return "NU12"
    error("TACS material derivative does not support design variable type '$dv_type'.")
end

function _tacs_model_with_material_fields_delta(model::AbstractDict, mids::AbstractVector{<:Integer}, field::AbstractString, delta::Real)
    m = deepcopy(model)
    field_key = uppercase(strip(string(field)))
    for mid in sort!(unique(Int.(collect(mids))))
        mat = get(get(m, "MATs", Dict()), string(Int(mid)), nothing)
        mat === nothing && error("TACS material derivative could not find material $mid.")
        mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
        if mat_type in ("MAT1", "MAT1_EQUIV")
            field_key in ("E", "G", "NU", "RHO", "ALPHA", "TREF") || error("TACS material derivative supports MAT1 E/G/NU/RHO/ALPHA/TREF only; got $field_key.")
        elseif mat_type == "MAT2"
            field_key in ("G11", "G12", "G13", "G22", "G23", "G33", "RHO") || error("TACS material derivative supports MAT2 G11/G12/G13/G22/G23/G33/RHO only; got $field_key.")
        elseif mat_type == "MAT8"
            field_key in ("E1", "E2", "G12", "NU12", "RHO") || error("TACS material derivative supports MAT8 E1/E2/G12/NU12/RHO only; got $field_key.")
        else
            error("TACS material derivative does not support material $mid TYPE=$(get(mat, "TYPE", "?")).")
        end
        value = Float64(get(mat, field_key, 0.0)) + Float64(delta)
        if mat_type == "MAT2" && field_key in ("G11", "G22", "G33")
            value > 0.0 || error("TACS material derivative produced nonpositive $mat_type $field_key for material $mid.")
        elseif mat_type == "MAT2" && field_key in ("G12", "G13", "G23")
            isfinite(value) || error("TACS material derivative produced nonfinite $mat_type $field_key for material $mid.")
        elseif field_key in ("E", "G", "E1", "E2", "G12")
            value > 0.0 || error("TACS material derivative produced nonpositive $mat_type $field_key for material $mid.")
        elseif field_key == "RHO"
            value >= 0.0 || error("TACS material derivative produced negative $mat_type $field_key for material $mid.")
        elseif field_key in ("ALPHA", "TREF")
            isfinite(value) || error("TACS material derivative produced nonfinite $mat_type $field_key for material $mid.")
        else
            -0.49 < value < 0.49 || error("TACS material derivative produced unsupported $mat_type $field_key=$value for material $mid.")
        end
        mat[field_key] = value
        if field_key == "NU"
            E = Float64(get(mat, "E", 0.0))
            E > 0.0 || error("TACS material derivative requires positive MAT1 E when perturbing NU.")
            mat["G"] = E / (2.0 * (1.0 + value))
        elseif mat_type == "MAT2"
            G11 = Float64(get(mat, "G11", 0.0))
            G12 = Float64(get(mat, "G12", 0.0))
            G33 = Float64(get(mat, "G33", 0.0))
            nu_eq = G11 > 0.0 ? clamp(G12 / G11, 0.0, 0.49) : 0.3
            mat["E"] = G11 > 0.0 ? G11 * (1.0 - nu_eq^2) : 0.0
            mat["G"] = G33
            mat["NU"] = nu_eq
        elseif mat_type == "MAT8"
            field_key == "E1" && (mat["E"] = value)
            field_key == "G12" && (mat["G"] = value)
            field_key == "NU12" && (mat["NU"] = value)
            _tacs_refresh_pcomp_clt_for_material!(m, mid)
        end
    end
    return m
end

function _tacs_model_with_material_field_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    return _tacs_model_with_material_fields_delta(model, [Int(mid)], field, delta)
end

_tacs_beam_sizing_design_types() = ("beam_area", "beam_I1", "beam_I2", "beam_J", "beam_i1", "beam_i2", "beam_j")

function _tacs_is_beam_sizing_design_type(dv_type)
    return lowercase(string(dv_type)) in ("beam_area", "beam_i1", "beam_i2", "beam_j")
end

_tacs_line_static_stiffness_design_types() =
    ("rod_area", "spring_stiffness", "bush_stiffness", _tacs_beam_sizing_design_types()...)

function _tacs_is_line_static_stiffness_design_type(dv_type)
    return string(dv_type) in _tacs_line_static_stiffness_design_types() ||
           _tacs_is_beam_sizing_design_type(dv_type)
end

function _tacs_model_has_line_static_stiffness(model::AbstractDict)
    return _tacs_nonempty_group(model, "CRODs") ||
           _tacs_nonempty_group(model, "CONRODs") ||
           _tacs_nonempty_group(model, "CBARs") ||
           _tacs_nonempty_group(model, "CBEAMs") ||
           _tacs_nonempty_group(model, "CELASs") ||
           _tacs_nonempty_group(model, "CBUSHs")
end

function _tacs_model_has_beam_stiffness(model::AbstractDict)
    return _tacs_nonempty_group(model, "CBARs") ||
           _tacs_nonempty_group(model, "CBEAMs")
end

function _tacs_design_raw(dv::AbstractDict, key::AbstractString)
    haskey(dv, key) && return dv[key]
    sym = Symbol(key)
    haskey(dv, sym) && return dv[sym]
    return nothing
end

function _tacs_design_ints(dv::AbstractDict, key::AbstractString)
    raw = _tacs_design_raw(dv, key)
    raw === nothing && return Int[]
    if raw isa AbstractArray || raw isa Tuple || raw isa AbstractSet
        return Int.(collect(raw))
    end
    return [Int(raw)]
end

_tacs_design_filter(dv::AbstractDict, key::AbstractString) =
    Set{Int}(_tacs_design_ints(dv, key))

_tacs_selected(filter::Set{Int}, value::Integer) = isempty(filter) || Int(value) in filter

function _tacs_entry_public_id(key, entry::AbstractDict)
    raw = get(entry, "ID", key)
    raw isa AbstractString && return parse(Int, strip(raw))
    return Int(raw)
end

function _tacs_group_positive_step(values::AbstractVector{<:Real}, label::AbstractString)
    positive = [Float64(v) for v in values if isfinite(Float64(v)) && Float64(v) > 0.0]
    isempty(positive) && error("TACS $label design perturbation found no positive selected values.")
    h = Inf
    for value in positive
        h = min(h, max(abs(value) * 1e-6, 1e-8), 0.25 * value)
    end
    isfinite(h) && h > 0.0 || error("TACS $label design perturbation could not choose a positive step.")
    return h
end

function _tacs_beam_design_field(dv_type)
    norm_type = lowercase(string(dv_type))
    if norm_type == "beam_area"
        return "A"
    elseif norm_type == "beam_i1"
        return "I1"
    elseif norm_type == "beam_i2"
        return "I2"
    elseif norm_type == "beam_j"
        return "J"
    end
    error("TACS beam sizing design does not support design variable type '$dv_type'.")
end

function _tacs_beam_property_design_value(prop::AbstractDict, field::AbstractString)
    if field == "I1"
        return Float64(get(prop, "I1", get(prop, "I", 0.0)))
    end
    return Float64(get(prop, field, 0.0))
end

function _tacs_beam_selected_property_ids(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    props = get(model, "PBARLs", Dict())
    selected_pids = Set{Int}()
    for group_name in ("CBARs", "CBEAMs")
        for (key, beam) in get(model, group_name, Dict())
            eid = _tacs_entry_public_id(key, beam)
            _tacs_selected(eids, eid) || continue
            pid = Int(get(beam, "PID", 0))
            _tacs_selected(pids, pid) || continue
            get(props, string(pid), nothing) isa AbstractDict ||
                error("TACS beam sizing perturbation could not find PBAR/PBARL property $pid.")
            push!(selected_pids, pid)
        end
    end
    return sort!(collect(selected_pids))
end

function _tacs_beam_design_values(model::AbstractDict, dv::AbstractDict)
    field = _tacs_beam_design_field(get(dv, "type", ""))
    props = get(model, "PBARLs", Dict())
    values = Float64[]
    for pid in _tacs_beam_selected_property_ids(model, dv)
        prop = get(props, string(pid), nothing)
        prop isa AbstractDict || error("TACS beam sizing perturbation could not find PBAR/PBARL property $pid.")
        value = _tacs_beam_property_design_value(prop, field)
        value > 0.0 || error("TACS beam sizing perturbation requires positive $field for PBAR/PBARL property $pid.")
        push!(values, value)
    end
    return values
end

function _tacs_set_beam_property_design_value!(prop::AbstractDict, pid::Integer, field::AbstractString, value::Real)
    v = Float64(value)
    v > 0.0 || error("TACS beam sizing perturbation produced nonpositive $field for PBAR/PBARL property $pid.")
    prop[field] = v
    field == "I1" && (prop["I"] = v)
    return prop
end

function _tacs_model_with_beam_property_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    field = _tacs_beam_design_field(get(dv, "type", ""))
    selected_pids = _tacs_beam_selected_property_ids(model, dv)
    isempty(selected_pids) && error("TACS beam sizing perturbation did not select any CBAR/CBEAM properties.")
    m = deepcopy(model)
    props = get(m, "PBARLs", Dict())
    for pid in selected_pids
        prop = get(props, string(pid), nothing)
        prop isa AbstractDict || error("TACS beam sizing perturbation could not find PBAR/PBARL property $pid.")
        current = _tacs_beam_property_design_value(prop, field)
        _tacs_set_beam_property_design_value!(prop, pid, field, current + Float64(delta))
    end
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_rod_area_values(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    values = Float64[]
    prods = get(model, "PRODs", Dict())
    for (key, rod) in get(model, "CRODs", Dict())
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(rod, "PID", 0))
        _tacs_selected(pids, pid) || continue
        prop = get(prods, string(pid), nothing)
        prop === nothing && error("TACS rod_area perturbation could not find PROD property $pid.")
        push!(values, Float64(get(prop, "A", 0.0)))
    end
    for (key, rod) in get(model, "CONRODs", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        push!(values, Float64(get(rod, "A", 0.0)))
    end
    return values
end

function _tacs_model_with_rod_area_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    m = deepcopy(model)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    touched = 0
    for (key, rod) in get(m, "CRODs", Dict())
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(rod, "PID", 0))
        _tacs_selected(pids, pid) || continue
        prop = get(get(m, "PRODs", Dict()), string(pid), nothing)
        prop === nothing && error("TACS rod_area perturbation could not find PROD property $pid.")
        value = Float64(get(prop, "A", 0.0)) + Float64(delta)
        value > 0.0 || error("TACS rod_area perturbation produced nonpositive area for PROD $pid.")
        prop["A"] = value
        touched += 1
    end
    for (key, rod) in get(m, "CONRODs", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        value = Float64(get(rod, "A", 0.0)) + Float64(delta)
        value > 0.0 || error("TACS rod_area perturbation produced nonpositive area for CONROD $eid.")
        rod["A"] = value
        touched += 1
    end
    touched > 0 || error("TACS rod_area perturbation did not select any CROD/CONROD elements.")
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_spring_stiffness_values(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    values = Float64[]
    pelases = get(model, "PELASs", Dict())
    for (key, spring) in get(model, "CELASs", Dict())
        eid = _tacs_entry_public_id(key, spring)
        _tacs_selected(eids, eid) || continue
        kernel = _tacs_spring_element_kernel(spring)
        if kernel.family == :celas1
            pid = Int(get(spring, "PID", 0))
            _tacs_selected(pids, pid) || continue
            prop = get(pelases, string(pid), nothing)
            prop === nothing && error("TACS spring_stiffness perturbation could not find PELAS property $pid.")
            push!(values, Float64(get(prop, "K", 0.0)))
        elseif kernel.family == :celas2
            isempty(pids) || continue
            push!(values, Float64(get(spring, "K", 0.0)))
        end
    end
    return values
end

function _tacs_model_with_spring_stiffness_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    m = deepcopy(model)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    touched = 0
    for (key, spring) in get(m, "CELASs", Dict())
        eid = _tacs_entry_public_id(key, spring)
        _tacs_selected(eids, eid) || continue
        kernel = _tacs_spring_element_kernel(spring)
        if kernel.family == :celas1
            pid = Int(get(spring, "PID", 0))
            _tacs_selected(pids, pid) || continue
            prop = get(get(m, "PELASs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS spring_stiffness perturbation could not find PELAS property $pid.")
            value = Float64(get(prop, "K", 0.0)) + Float64(delta)
            value > 0.0 || error("TACS spring_stiffness perturbation produced nonpositive stiffness for PELAS $pid.")
            prop["K"] = value
            touched += 1
        elseif kernel.family == :celas2
            isempty(pids) || continue
            value = Float64(get(spring, "K", 0.0)) + Float64(delta)
            value > 0.0 || error("TACS spring_stiffness perturbation produced nonpositive stiffness for CELAS2 $eid.")
            spring["K"] = value
            touched += 1
        end
    end
    touched > 0 || error("TACS spring_stiffness perturbation did not select any CELAS1/CELAS2 elements.")
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_bush_components(dv::AbstractDict)
    raw = _tacs_design_raw(dv, "component")
    raw === nothing && (raw = _tacs_design_raw(dv, "comp"))
    raw === nothing && return [1]
    comps =
        raw isa AbstractArray || raw isa Tuple || raw isa AbstractSet ?
        Int.(collect(raw)) :
        [Int(raw)]
    for comp in comps
        1 <= comp <= 6 || error("TACS bush_stiffness component must be in 1:6, got $comp.")
    end
    return sort!(unique(comps))
end

function _tacs_bush_stiffness_values(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    comps = _tacs_bush_components(dv)
    values = Float64[]
    for (key, bush) in get(model, "CBUSHs", Dict())
        eid = _tacs_entry_public_id(key, bush)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(bush, "PID", 0))
        _tacs_selected(pids, pid) || continue
        prop = get(get(model, "PBUSHs", Dict()), string(pid), nothing)
        prop === nothing && error("TACS bush_stiffness perturbation could not find PBUSH property $pid.")
        k_vals = Float64.(collect(get(prop, "K", Float64[])))
        length(k_vals) >= 6 || error("TACS bush_stiffness perturbation requires six PBUSH K values for property $pid.")
        append!(values, k_vals[comps])
    end
    return values
end

function _tacs_model_with_bush_stiffness_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    m = deepcopy(model)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    comps = _tacs_bush_components(dv)
    touched = 0
    for (key, bush) in get(m, "CBUSHs", Dict())
        eid = _tacs_entry_public_id(key, bush)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(bush, "PID", 0))
        _tacs_selected(pids, pid) || continue
        prop = get(get(m, "PBUSHs", Dict()), string(pid), nothing)
        prop === nothing && error("TACS bush_stiffness perturbation could not find PBUSH property $pid.")
        k_vals = Float64.(collect(get(prop, "K", Float64[])))
        length(k_vals) >= 6 || error("TACS bush_stiffness perturbation requires six PBUSH K values for property $pid.")
        for comp in comps
            value = k_vals[comp] + Float64(delta)
            value > 0.0 || error("TACS bush_stiffness perturbation produced nonpositive PBUSH K$comp for property $pid.")
            k_vals[comp] = value
            touched += 1
        end
        prop["K"] = k_vals
    end
    touched > 0 || error("TACS bush_stiffness perturbation did not select any CBUSH/PBUSH components.")
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_conm1_point_mass_components(dv::AbstractDict)
    raw = _tacs_design_raw(dv, "components")
    raw === nothing && (raw = _tacs_design_raw(dv, "component"))
    raw === nothing && (raw = _tacs_design_raw(dv, "comp"))
    raw === nothing && return [1]
    comps =
        raw isa AbstractArray || raw isa Tuple || raw isa AbstractSet ?
        Int.(collect(raw)) :
        [Int(raw)]
    for comp in comps
        1 <= comp <= 6 || error("TACS CONM1 point_mass component must be in 1:6, got $comp.")
    end
    return sort!(unique(comps))
end

function _tacs_conm1_point_mass_term(row_raw, col_raw)
    row = Int(row_raw)
    col = Int(col_raw)
    1 <= row <= 6 || error("TACS CONM1 point_mass matrix row must be in 1:6, got $row.")
    1 <= col <= 6 || error("TACS CONM1 point_mass matrix column must be in 1:6, got $col.")
    return row <= col ? (row, col) : (col, row)
end

function _tacs_conm1_point_mass_term_from_string(raw::AbstractString)
    token = uppercase(strip(raw))
    token = startswith(token, "M") ? token[2:end] : token
    parts = split(token, r"[^0-9]+"; keepempty=false)
    if length(parts) == 1
        chars = collect(parts[1])
        length(chars) == 2 ||
            error("TACS CONM1 point_mass matrix term string '$raw' must look like M12 or 1,2.")
        return _tacs_conm1_point_mass_term(parse(Int, string(chars[1])), parse(Int, string(chars[2])))
    elseif length(parts) == 2
        return _tacs_conm1_point_mass_term(parse(Int, parts[1]), parse(Int, parts[2]))
    end
    error("TACS CONM1 point_mass matrix term string '$raw' must look like M12 or 1,2.")
end

function _tacs_conm1_point_mass_terms_from_raw(raw)
    terms = Tuple{Int,Int}[]
    _push_term!(item) = begin
        if item isa AbstractString
            push!(terms, _tacs_conm1_point_mass_term_from_string(item))
        elseif item isa Pair
            push!(terms, _tacs_conm1_point_mass_term(first(item), last(item)))
        elseif item isa AbstractArray || item isa Tuple
            vals = collect(item)
            length(vals) == 2 ||
                error("TACS CONM1 point_mass matrix term entries must have two components.")
            push!(terms, _tacs_conm1_point_mass_term(vals[1], vals[2]))
        else
            error("TACS CONM1 point_mass matrix term must be a pair, tuple, vector, or string.")
        end
        return nothing
    end

    if raw isa AbstractString || raw isa Pair
        _push_term!(raw)
    elseif raw isa AbstractArray || raw isa Tuple || raw isa AbstractSet
        items = collect(raw)
        if length(items) == 2 && all(item -> !(item isa AbstractArray || item isa Tuple || item isa Pair), items)
            push!(terms, _tacs_conm1_point_mass_term(items[1], items[2]))
        else
            for item in items
                _push_term!(item)
            end
        end
    else
        error("TACS CONM1 point_mass matrix terms must be a pair, tuple, vector, set, or string.")
    end
    isempty(terms) && error("TACS CONM1 point_mass matrix term selector is empty.")
    return sort!(unique(terms))
end

function _tacs_conm1_point_mass_terms(dv::AbstractDict)
    for key in ("component_pairs", "matrix_terms", "terms")
        raw = _tacs_design_raw(dv, key)
        raw === nothing || return _tacs_conm1_point_mass_terms_from_raw(raw)
    end
    row = _tacs_design_raw(dv, "row")
    col = _tacs_design_raw(dv, "col")
    row === nothing && (row = _tacs_design_raw(dv, "i"))
    col === nothing && (col = _tacs_design_raw(dv, "j"))
    if row !== nothing || col !== nothing
        row !== nothing && col !== nothing ||
            error("TACS CONM1 point_mass matrix-term design variable requires both row and col.")
        return [_tacs_conm1_point_mass_term(row, col)]
    end
    return [(comp, comp) for comp in _tacs_conm1_point_mass_components(dv)]
end

function _tacs_conm2_point_inertia_terms(dv::AbstractDict)
    raw = _tacs_design_raw(dv, "terms")
    raw === nothing && (raw = _tacs_design_raw(dv, "term"))
    raw === nothing && (raw = _tacs_design_raw(dv, "components"))
    raw === nothing && (raw = _tacs_design_raw(dv, "component"))
    raw === nothing && (raw = _tacs_design_raw(dv, "comp"))
    raw === nothing && return [1]
    terms =
        raw isa AbstractArray || raw isa Tuple || raw isa AbstractSet ?
        Int.(collect(raw)) :
        [Int(raw)]
    for term in terms
        1 <= term <= 6 || error("TACS CONM2 point_inertia term must be in 1:6, got $term.")
    end
    return sort!(unique(terms))
end

function _tacs_point_mass_values(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    terms = _tacs_conm1_point_mass_terms(dv)
    values = Float64[]
    for (key, mass) in get(model, "CONM1s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        raw_full = get(mass, "M_FULL", nothing)
        if raw_full !== nothing
            m_full = Matrix{Float64}(raw_full)
            size(m_full) == (6, 6) || error("TACS point_mass perturbation requires 6x6 CONM1 M_FULL for element $eid.")
        else
            diag = Float64.(collect(get(mass, "M_DIAG", Float64[])))
            length(diag) >= 6 || error("TACS point_mass perturbation requires CONM1 M_FULL or six M_DIAG values for element $eid.")
            m_full = zeros(Float64, 6, 6)
            for comp in 1:6
                m_full[comp, comp] = diag[comp]
            end
        end
        for (row, col) in terms
            push!(values, m_full[row, col])
            if row != col
                scale = sqrt(abs(m_full[row, row]) * abs(m_full[col, col]))
                scale > 0.0 && push!(values, scale)
            end
        end
    end
    for (key, mass) in get(model, "CONM2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        push!(values, Float64(get(mass, "M", 0.0)))
    end
    for (key, mass) in get(model, "CMASS2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        push!(values, Float64(get(mass, "M", 0.0)))
    end
    selected_pmasses = Set{Int}()
    pmasses = get(model, "PMASSs", Dict())
    for (key, mass) in get(model, "CMASS1s", Dict())
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(mass, "PID", 0))
        _tacs_selected(pids, pid) || continue
        pid in selected_pmasses && continue
        prop = get(pmasses, string(pid), nothing)
        prop === nothing && error("TACS point_mass perturbation could not find PMASS property $pid.")
        push!(values, Float64(get(prop, "M", 0.0)))
        push!(selected_pmasses, pid)
    end
    return values
end

function _tacs_point_inertia_values(model::AbstractDict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    terms = _tacs_conm2_point_inertia_terms(dv)
    values = Float64[]
    for (key, mass) in get(model, "CONM2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        inertia = Float64.(collect(get(mass, "I", Float64[])))
        length(inertia) >= 6 || error("TACS point_inertia perturbation requires six CONM2 inertia terms for element $eid.")
        append!(values, (inertia[term] for term in terms))
    end
    return values
end

function _tacs_model_with_point_mass_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    m = deepcopy(model)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    terms = _tacs_conm1_point_mass_terms(dv)
    touched = 0
    for (key, mass) in get(m, "CONM1s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        raw_full = get(mass, "M_FULL", nothing)
        if raw_full !== nothing
            m_full = Matrix{Float64}(raw_full)
            size(m_full) == (6, 6) || error("TACS point_mass perturbation requires 6x6 CONM1 M_FULL for element $eid.")
        else
            diag = Float64.(collect(get(mass, "M_DIAG", Float64[])))
            length(diag) >= 6 || error("TACS point_mass perturbation requires CONM1 M_FULL or six M_DIAG values for element $eid.")
            m_full = zeros(Float64, 6, 6)
            for comp in 1:6
                m_full[comp, comp] = diag[comp]
            end
        end
        for (row, col) in terms
            value = m_full[row, col] + Float64(delta)
            if row == col
                value > 0.0 || error("TACS point_mass perturbation produced nonpositive CONM1 diagonal mass component M$row$col for element $eid.")
                m_full[row, row] = value
            else
                m_full[row, col] = value
                m_full[col, row] = value
            end
            touched += 1
        end
        mass["M_FULL"] = m_full
        mass["M_DIAG"] = [m_full[i, i] for i in 1:6]
        mass["M"] = m_full[1, 1]
    end
    for (key, mass) in get(m, "CONM2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        value = Float64(get(mass, "M", 0.0)) + Float64(delta)
        value > 0.0 || error("TACS point_mass perturbation produced nonpositive mass for CONM2 $eid.")
        mass["M"] = value
        touched += 1
    end
    for (key, mass) in get(m, "CMASS2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        value = Float64(get(mass, "M", 0.0)) + Float64(delta)
        value > 0.0 || error("TACS point_mass perturbation produced nonpositive mass for CMASS2 $eid.")
        mass["M"] = value
        touched += 1
    end
    selected_pmasses = Set{Int}()
    pmasses = get(m, "PMASSs", Dict())
    for (key, mass) in get(m, "CMASS1s", Dict())
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(mass, "PID", 0))
        _tacs_selected(pids, pid) || continue
        pid in selected_pmasses && continue
        prop = get(pmasses, string(pid), nothing)
        prop === nothing && error("TACS point_mass perturbation could not find PMASS property $pid.")
        value = Float64(get(prop, "M", 0.0)) + Float64(delta)
        value > 0.0 || error("TACS point_mass perturbation produced nonpositive mass for PMASS $pid.")
        prop["M"] = value
        push!(selected_pmasses, pid)
        touched += 1
    end
    touched > 0 || error("TACS point_mass perturbation did not select any CONM1/CONM2/CMASS1/CMASS2 masses.")
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_model_with_point_inertia_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    m = deepcopy(model)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    terms = _tacs_conm2_point_inertia_terms(dv)
    touched = 0
    for (key, mass) in get(m, "CONM2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        inertia = Float64.(collect(get(mass, "I", Float64[])))
        length(inertia) >= 6 || error("TACS point_inertia perturbation requires six CONM2 inertia terms for element $eid.")
        for term in terms
            value = inertia[term] + Float64(delta)
            if term in (1, 3, 6)
                value > 0.0 || error("TACS point_inertia perturbation produced nonpositive principal inertia term $term for CONM2 $eid.")
            end
            inertia[term] = value
            touched += 1
        end
        mass["I"] = inertia
    end
    touched > 0 || error("TACS point_inertia perturbation did not select any CONM2 inertia terms.")
    m["backend"] = JFEM_BACKEND_TACS
    return m
end

function _tacs_line_static_design_step(model::AbstractDict, dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    if dv_type == "rod_area"
        return _tacs_group_positive_step(_tacs_rod_area_values(model, dv), "rod_area")
    elseif dv_type == "spring_stiffness"
        return _tacs_group_positive_step(_tacs_spring_stiffness_values(model, dv), "spring_stiffness")
    elseif dv_type == "bush_stiffness"
        return _tacs_group_positive_step(_tacs_bush_stiffness_values(model, dv), "bush_stiffness")
    elseif _tacs_is_beam_sizing_design_type(dv_type)
        return _tacs_group_positive_step(_tacs_beam_design_values(model, dv), lowercase(dv_type))
    end
    error("TACS line static design step does not support design variable type '$dv_type'.")
end

function _tacs_model_with_design_delta(model::AbstractDict, dv::AbstractDict, delta::Real)
    dv_type = string(get(dv, "type", ""))
    if dv_type == "shell_thickness"
        pid_list = Int.(collect(get(dv, "pids", _tacs_sol101_active_shell_pids(model))))
        isempty(pid_list) && (pid_list = _tacs_sol101_active_shell_pids(model))
        isempty(pid_list) && error("TACS shell-thickness perturbation requires at least one active shell property.")
        m = deepcopy(model)
        for pid in sort!(unique(pid_list))
            prop = get(get(m, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS shell-thickness perturbation could not find shell property $pid.")
            t0 = Float64(get(prop, "T", 0.0))
            _tacs_set_shell_property_thickness!(prop, pid, t0 + Float64(delta))
        end
        m["backend"] = JFEM_BACKEND_TACS
        return m
    elseif dv_type in ("pcomp_ply_thickness", "pcomp_ply_angle")
        ply_idx = Int(get(dv, "ply_index", 0))
        ply_idx > 0 || error("TACS PCOMP ply design perturbation requires a positive ply_index.")
        pid_list = Int.(collect(get(dv, "pids", Int[])))
        if isempty(pid_list)
            for (pid, prop) in get(model, "PSHELLs", Dict())
                uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || continue
                push!(pid_list, Int(parse(Int, string(pid))))
            end
        end
        isempty(pid_list) && error("TACS PCOMP ply design perturbation requires at least one PCOMP_CLT property.")
        m = deepcopy(model)
        perturb_field = dv_type == "pcomp_ply_thickness" ? :T : :THETA
        for pid in pid_list
            prop = get(get(m, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS PCOMP ply perturbation could not find shell property $pid.")
            _tacs_update_pcomp_clt_reference!(prop, m["MATs"], ply_idx, perturb_field, delta)
        end
        m["backend"] = JFEM_BACKEND_TACS
        return m
    elseif dv_type in _tacs_material_design_types()
        m = _tacs_model_with_material_fields_delta(
            model,
            _tacs_material_design_mids(dv),
            _tacs_material_design_field(dv_type),
            delta,
        )
        m["backend"] = JFEM_BACKEND_TACS
        return m
    elseif dv_type == "rod_area"
        return _tacs_model_with_rod_area_delta(model, dv, delta)
    elseif dv_type == "spring_stiffness"
        return _tacs_model_with_spring_stiffness_delta(model, dv, delta)
    elseif dv_type == "bush_stiffness"
        return _tacs_model_with_bush_stiffness_delta(model, dv, delta)
    elseif _tacs_is_beam_sizing_design_type(dv_type)
        return _tacs_model_with_beam_property_delta(model, dv, delta)
    elseif dv_type == "point_mass"
        return _tacs_model_with_point_mass_delta(model, dv, delta)
    elseif dv_type == "point_inertia"
        return _tacs_model_with_point_inertia_delta(model, dv, delta)
    end
    error("TACS design perturbation does not support design variable type '$dv_type'.")
end

function _tacs_material_tangent_fd(model::Dict, el::AbstractDict, id_map, X, node_R, dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    dv_type in _tacs_material_stiffness_design_types() || error("TACS material derivative does not support design variable type '$dv_type'.")
    mids = _tacs_material_design_mids(dv)
    field = _tacs_material_design_field(dv_type)
    h = _tacs_material_group_design_step(model, dv)
    model_p = _tacs_model_with_material_fields_delta(model, mids, field, h)
    model_m = _tacs_model_with_material_fields_delta(model, mids, field, -h)
    Ke_p, dofs = _tacs_shell_residual_tangent(model_p, el, id_map, X, node_R)
    Ke_m, _ = _tacs_shell_residual_tangent(model_m, el, id_map, X, node_R)
    dKe = (Ke_p .- Ke_m) ./ (2.0 * h)
    dKe .= 0.5 .* (dKe .+ transpose(dKe))
    return dKe, dofs, h
end

function _tacs_full_stiffness_design_fd_step(model::AbstractDict, dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    if _tacs_is_line_static_stiffness_design_type(dv_type)
        return _tacs_line_static_design_step(model, dv)
    elseif dv_type in _tacs_material_stiffness_design_types()
        return _tacs_material_group_design_step(model, dv)
    end
    error("TACS full stiffness design derivative does not support design variable type '$dv_type'.")
end

function _tacs_assemble_sol101_full_stiffness_design_derivative(
    model::Dict,
    dv::AbstractDict;
    allowed_sol_types=(101,),
    route_label="SOL101 full stiffness design sensitivity",
)
    h = _tacs_full_stiffness_design_fd_step(model, dv)
    model_p = _tacs_model_with_design_delta(model, dv, h)
    model_m = _tacs_model_with_design_delta(model, dv, -h)
    Kp, id_map, X, ndof, node_R, _, _, _, _ =
        _tacs_assemble_sol101(model_p; allowed_sol_types=allowed_sol_types, route_label=route_label)
    Km, id_map_m, _, ndof_m, _, _, _, _, _ =
        _tacs_assemble_sol101(model_m; allowed_sol_types=allowed_sol_types, route_label=route_label)
    ndof == ndof_m || error("TACS full stiffness design derivative changed ndof for design variable '$(_tacs_design_variable_id(dv))'.")
    length(id_map) == length(id_map_m) ||
        error("TACS full stiffness design derivative changed GRID map size for design variable '$(_tacs_design_variable_id(dv))'.")
    dK = (Kp .- Km) ./ (2.0 * h)
    dK = 0.5 .* (dK .+ transpose(dK))
    return dK, id_map, X, ndof, node_R, [h]
end

function _tacs_assemble_rod_area_stiffness_derivative(model::Dict, dv::AbstractDict, id_map, X, node_R, ndof::Integer)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    I_idx = Vector{Int}()
    J_idx = Vector{Int}()
    V_val = Vector{Float64}()
    nnz_est = 144 * (length(get(model, "CRODs", Dict())) + length(get(model, "CONRODs", Dict())))
    sizehint!(I_idx, nnz_est)
    sizehint!(J_idx, nnz_est)
    sizehint!(V_val, nnz_est)
    touched = 0

    for (key, rod) in get(model, "CRODs", Dict())
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(rod, "PID", 0))
        _tacs_selected(pids, pid) || continue
        dKe, dofs = _tacs_rod_area_stiffness_derivative_tangent(model, rod, id_map, X, node_R)
        touched += 1
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, dKe[r, c])
        end
    end
    for (key, rod) in get(model, "CONRODs", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        dKe, dofs = _tacs_rod_area_stiffness_derivative_tangent(model, rod, id_map, X, node_R)
        touched += 1
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, dKe[r, c])
        end
    end
    touched > 0 || error("TACS rod_area stiffness derivative did not select any CROD/CONROD elements.")
    dK = sparse(I_idx, J_idx, V_val, ndof, ndof)
    return 0.5 .* (dK .+ transpose(dK))
end

function _tacs_assemble_sol101_design_derivative(
    model::Dict,
    dv::AbstractDict;
    allowed_sol_types=(101,),
    route_label="SOL101 design sensitivity",
)
    allow_rod_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_beam_slice = any(s -> Int(s) in (101, 103, 105), allowed_sol_types)
    allow_spring_slice = any(s -> Int(s) in (101, 103), allowed_sol_types)
    allow_mass_slice = any(s -> Int(s) == 103, allowed_sol_types)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=allowed_sol_types,
        route_label=route_label,
        allow_rods=allow_rod_slice,
        allow_beams=allow_beam_slice,
        allow_springs=allow_spring_slice,
        allow_masses=allow_mass_slice,
        allow_conm1=allow_mass_slice,
        require_shell=!(allow_rod_slice || allow_beam_slice || allow_spring_slice),
    )
    dv_type = string(get(dv, "type", ""))
    if dv_type == "node_coord"
        return _tacs_assemble_sol101_coordinate_derivative(
            model,
            dv;
            allowed_sol_types=allowed_sol_types,
            route_label=route_label,
        )
    end
    if dv_type == "rod_area"
        id_map, X, ndof, node_R = _tacs_node_tables(model)
        h = _tacs_line_static_design_step(model, dv)
        dK = _tacs_assemble_rod_area_stiffness_derivative(model, dv, id_map, X, node_R, ndof)
        return dK, id_map, X, ndof, node_R, [h]
    end
    if _tacs_is_line_static_stiffness_design_type(dv_type) ||
       (dv_type in _tacs_material_stiffness_design_types() && _tacs_model_has_line_static_stiffness(model))
        return _tacs_assemble_sol101_full_stiffness_design_derivative(
            model,
            dv;
            allowed_sol_types=allowed_sol_types,
            route_label=route_label,
        )
    end
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    cshells = model["CSHELLs"]
    nnz_est = 576 * length(cshells)
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()
    sizehint!(I_idx, nnz_est); sizehint!(J_idx, nnz_est); sizehint!(V_val, nnz_est)
    steps = Float64[]
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
        elseif dv_type in _tacs_material_stiffness_design_types()
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

function _tacs_default_allow_varying_pbeam_stations(thickness_derivative_pid, allowed_sol_types, route_label)
    thickness_derivative_pid === nothing || return false
    allowed = collect(allowed_sol_types)
    length(allowed) == 1 || return false
    Int(first(allowed)) == 101 || return false
    return string(route_label) == "SOL101"
end

function _tacs_assemble_sol101(
    model::Dict;
    thickness_derivative_pid=nothing,
    allowed_sol_types=(101,),
    route_label="SOL101",
    allow_varying_pbeam_stations=nothing,
)
    raw_sol_type = get(model, "SOL", get(get(model, "CASE_CONTROL", Dict()), "SOL", 101))
    sol_type = _canonical_sol_type(raw_sol_type)
    allow_rod_slice = sol_type in (101, 103, 105) && sol_type in allowed_sol_types
    allow_beam_slice = sol_type in (101, 103, 105) && sol_type in allowed_sol_types
    allow_spring_slice = sol_type in (101, 103) && sol_type in allowed_sol_types
    allow_mass_slice = sol_type == 103 && 103 in allowed_sol_types
    allow_varying_stations =
        allow_varying_pbeam_stations === nothing ?
        _tacs_default_allow_varying_pbeam_stations(thickness_derivative_pid, allowed_sol_types, route_label) :
        Bool(allow_varying_pbeam_stations)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=allowed_sol_types,
        route_label=route_label,
        allow_rods=allow_rod_slice,
        allow_beams=allow_beam_slice,
        allow_springs=allow_spring_slice,
        allow_masses=allow_mass_slice,
        allow_conm1=allow_mass_slice,
        require_shell=!(allow_rod_slice || allow_beam_slice || allow_spring_slice),
        allow_varying_pbeam_stations=allow_varying_stations,
    )
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    cshells = get(model, "CSHELLs", Dict())
    cbars = get(model, "CBARs", Dict())
    cbeams = get(model, "CBEAMs", Dict())
    crods = get(model, "CRODs", Dict())
    conrods = get(model, "CONRODs", Dict())
    celases = get(model, "CELASs", Dict())
    cbushes = get(model, "CBUSHs", Dict())
    nnz_est = 576 * length(cshells) + 144 * (length(cbars) + length(cbeams) + length(crods) + length(conrods)) +
        4 * length(celases) + 144 * length(cbushes)
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
    for (_, beam) in cbars
        Ke, dofs = _tacs_beam_residual_tangent(model, beam, id_map, X, node_R)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    for (_, beam) in cbeams
        Ke, dofs = _tacs_beam_residual_tangent(model, beam, id_map, X, node_R)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    for (_, rod) in crods
        Ke, dofs = _tacs_rod_residual_tangent(model, rod, id_map, X, node_R)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    for (_, rod) in conrods
        Ke, dofs = _tacs_rod_residual_tangent(model, rod, id_map, X, node_R)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    for (_, spring) in celases
        Ke, dofs = _tacs_spring_residual_tangent(model, spring, id_map)
        max_elem_stiff = max(max_elem_stiff, maximum(abs.(Ke)))
        nd = length(dofs)
        for c in 1:nd, r in 1:nd
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, Ke[r, c])
        end
    end
    for (_, bush) in cbushes
        Ke, dofs = _tacs_bush_residual_tangent(model, bush, id_map)
        isempty(dofs) && continue
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

function _tacs_model_without_rods_for_mass(model::Dict)
    m = copy(model)
    m["CRODs"] = Dict{String,Any}()
    m["CONRODs"] = Dict{String,Any}()
    return m
end

function _tacs_model_without_backend_line_elements_for_mass(model::Dict)
    m = _tacs_model_without_rods_for_mass(model)
    m["CBARs"] = Dict{String,Any}()
    m["CBEAMs"] = Dict{String,Any}()
    return m
end

function _tacs_assemble_rod_mass(model::Dict, id_map, X, node_R, ndof::Integer)
    crods = get(model, "CRODs", Dict())
    conrods = get(model, "CONRODs", Dict())
    I_idx = Vector{Int}()
    J_idx = Vector{Int}()
    V_val = Vector{Float64}()
    sizehint!(I_idx, 144 * (length(crods) + length(conrods)))
    sizehint!(J_idx, 144 * (length(crods) + length(conrods)))
    sizehint!(V_val, 144 * (length(crods) + length(conrods)))
    n_rods = 0
    for rod_group in (crods, conrods)
        for (_, rod) in rod_group
            Me, dofs = _tacs_rod_mass_tangent(model, rod, id_map, X, node_R)
            if maximum(abs.(Me)) <= 0.0
                continue
            end
            n_rods += 1
            for c in 1:12, r in 1:12
                push!(I_idx, dofs[r])
                push!(J_idx, dofs[c])
                push!(V_val, Me[r, c])
            end
        end
    end
    M = sparse(I_idx, J_idx, V_val, ndof, ndof)
    wtmass = Float64(get(model, "PARAM_WTMASS", 1.0))
    if wtmass != 1.0 && wtmass > 0.0
        M .*= wtmass
    end
    return M, n_rods
end

function _tacs_assemble_beam_mass(model::Dict, id_map, X, node_R, ndof::Integer)
    cbars = get(model, "CBARs", Dict())
    cbeams = get(model, "CBEAMs", Dict())
    I_idx = Vector{Int}()
    J_idx = Vector{Int}()
    V_val = Vector{Float64}()
    sizehint!(I_idx, 144 * (length(cbars) + length(cbeams)))
    sizehint!(J_idx, 144 * (length(cbars) + length(cbeams)))
    sizehint!(V_val, 144 * (length(cbars) + length(cbeams)))
    n_beams = 0
    for beam_group in (cbars, cbeams)
        for (_, beam) in beam_group
            Me, dofs = _tacs_beam_mass_tangent(model, beam, id_map, X, node_R)
            if maximum(abs.(Me)) <= 0.0
                continue
            end
            n_beams += 1
            for c in 1:12, r in 1:12
                push!(I_idx, dofs[r])
                push!(J_idx, dofs[c])
                push!(V_val, Me[r, c])
            end
        end
    end
    M = sparse(I_idx, J_idx, V_val, ndof, ndof)
    wtmass = Float64(get(model, "PARAM_WTMASS", 1.0))
    if wtmass != 1.0 && wtmass > 0.0
        M .*= wtmass
    end
    return M, n_beams
end

function _tacs_rod_area_mass_derivative_tangent(model::Dict, rod::AbstractDict, id_map, X, node_R)
    pdata = _tacs_rod_property_material(model, rod)
    kernel = pdata.kernel
    ga = Int(get(rod, "GA", 0))
    gb = Int(get(rod, "GB", 0))
    ga > 0 && gb > 0 || error("TACS-formulation $(kernel.card_type) rod mass derivative requires positive GA/GB ids.")
    nids = [ga, gb]
    A, J, nsm, mid = pdata.A, pdata.J, pdata.NSM, pdata.MID
    A > 0.0 || error("TACS-formulation $(kernel.card_type) rod mass derivative requires positive area A.")
    J >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass derivative requires nonnegative torsion constant J.")
    nsm >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass derivative requires nonnegative NSM.")
    mat = Solver._effective_mat1_for_nodes(model, mid, nids)
    mat === nothing && error("TACS-formulation $(kernel.card_type) rod mass derivative references missing MAT1 material $mid.")
    rho = Float64(get(mat, "RHO", 0.0))
    rho >= 0.0 || error("TACS-formulation $(kernel.card_type) rod mass derivative requires nonnegative material density.")
    rd = _tacs_rod_frame_and_transform(ga, gb, id_map, X, node_R)

    dMe_loc = zeros(12, 12)
    dtrans = rho * rd.L / 2.0
    dtorsion = (J > 0.0 && nsm > 0.0) ? -(nsm / (A * A)) * J * rd.L / 2.0 : 0.0
    @inbounds for base in (0, 6)
        dMe_loc[base + 1, base + 1] = dtrans
        dMe_loc[base + 2, base + 2] = dtrans
        dMe_loc[base + 3, base + 3] = dtrans
        dMe_loc[base + 4, base + 4] = dtorsion
    end
    return rd.T12' * dMe_loc * rd.T12, rd.dofs
end

function _tacs_assemble_rod_area_mass_derivative(model::Dict, dv::AbstractDict, id_map, X, node_R, ndof::Integer)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    I_idx = Vector{Int}()
    J_idx = Vector{Int}()
    V_val = Vector{Float64}()
    nnz_est = 144 * (length(get(model, "CRODs", Dict())) + length(get(model, "CONRODs", Dict())))
    sizehint!(I_idx, nnz_est)
    sizehint!(J_idx, nnz_est)
    sizehint!(V_val, nnz_est)
    touched = 0

    for (key, rod) in get(model, "CRODs", Dict())
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(rod, "PID", 0))
        _tacs_selected(pids, pid) || continue
        dMe, dofs = _tacs_rod_area_mass_derivative_tangent(model, rod, id_map, X, node_R)
        touched += 1
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, dMe[r, c])
        end
    end
    for (key, rod) in get(model, "CONRODs", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        dMe, dofs = _tacs_rod_area_mass_derivative_tangent(model, rod, id_map, X, node_R)
        touched += 1
        for c in 1:12, r in 1:12
            push!(I_idx, dofs[r])
            push!(J_idx, dofs[c])
            push!(V_val, dMe[r, c])
        end
    end
    touched > 0 || error("TACS rod_area modal mass derivative did not select any CROD/CONROD elements.")
    dM = sparse(I_idx, J_idx, V_val, ndof, ndof)
    wtmass = Float64(get(model, "PARAM_WTMASS", 1.0))
    if wtmass != 1.0 && wtmass > 0.0
        dM .*= wtmass
    end
    return 0.5 .* (dM .+ transpose(dM))
end

function _tacs_sol103_modal_mass_builder(model::Dict, id_map, X, node_R, ndof::Integer)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(103,),
        route_label="SOL103 modal mass",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        allow_masses=true,
        allow_conm1=true,
        require_shell=false,
        allow_varying_pbeam_stations=true,
    )
    has_shared_mass =
        !isempty(get(model, "CSHELLs", Dict())) ||
        _tacs_model_has_modal_point_mass(model)
    M_shared = if has_shared_mass
        Solver.assemble_mass(_tacs_model_without_backend_line_elements_for_mass(model), id_map, X, node_R, ndof)
    else
        spzeros(ndof, ndof)
    end
    M_rods, n_rods = _tacs_assemble_rod_mass(model, id_map, X, node_R, ndof)
    M_beams, n_beams = _tacs_assemble_beam_mass(model, id_map, X, node_R, ndof)
    M = M_shared + M_rods + M_beams
    if n_rods > 0 || n_beams > 0
        M = 0.5 * (M + transpose(M))
    end
    return M
end

function _tacs_model_has_modal_point_mass(model::AbstractDict)
    return _tacs_nonempty_group(model, "CONM1s") ||
           _tacs_nonempty_group(model, "CONM2s") ||
           _tacs_nonempty_group(model, "CMASS1s") ||
           _tacs_nonempty_group(model, "CMASS2s")
end

function _tacs_model_has_varying_station_beam(model::AbstractDict)
    for group_name in ("CBARs", "CBEAMs")
        for (_, beam) in get(model, group_name, Dict())
            prop = get(get(model, "PBARLs", Dict()), _tacs_id_key(get(beam, "PID", 0)), nothing)
            if prop !== nothing && !_tacs_beam_station_properties_constant(prop)
                return true
            end
        end
    end
    return false
end

function _tacs_sol103_modal_mass_route_label(model::AbstractDict)
    parts = String[]
    if _tacs_nonempty_group(model, "CSHELLs")
        push!(parts, "shared_jfem_shell_mass_" * Solver.sol103_shell_mass_formulation_name(model))
    end
    if _tacs_model_has_modal_point_mass(model)
        push!(parts, "shared_jfem_modal_point_mass")
    end
    if _tacs_nonempty_group(model, "CRODs") || _tacs_nonempty_group(model, "CONRODs")
        push!(parts, "tacs_lumped_crod_conrod_mass")
    end
    if _tacs_nonempty_group(model, "CBARs") || _tacs_nonempty_group(model, "CBEAMs")
        push!(parts, _tacs_model_has_varying_station_beam(model) ? "tacs_guyan_pbeam_station_cbar_cbeam_mass" : "tacs_lumped_cbar_cbeam_mass")
    end
    isempty(parts) && return "zero_mass"
    return join(parts, "_plus_")
end

function _tacs_sol103_linear_stiffness_route_label(model::AbstractDict)
    parts = String[]
    if _tacs_nonempty_group(model, "CSHELLs")
        push!(parts, TACS_LINEAR_SHELL_STIFFNESS_ROUTE)
    end
    if _tacs_nonempty_group(model, "CRODs") || _tacs_nonempty_group(model, "CONRODs")
        push!(parts, TACS_LINEAR_ROD_STIFFNESS_ROUTE)
    end
    if _tacs_nonempty_group(model, "CBARs") || _tacs_nonempty_group(model, "CBEAMs")
        push!(parts, _tacs_model_has_varying_station_beam(model) ? TACS_LINEAR_BEAM_STIFFNESS_ROUTE * "_pbeam_station_stiffness" : TACS_LINEAR_BEAM_STIFFNESS_ROUTE)
    end
    if _tacs_nonempty_group(model, "CELASs") || _tacs_nonempty_group(model, "CBUSHs")
        push!(parts, "residual_first_celas1_celas2_cbush_sol101_sol103")
    end
    isempty(parts) && return TACS_LINEAR_SHELL_STIFFNESS_ROUTE
    return join(parts, "_plus_")
end

function _tacs_sol105_beam_geometric_stiffness_route_label(model::AbstractDict)
    has_beams = _tacs_nonempty_group(model, "CBARs") || _tacs_nonempty_group(model, "CBEAMs")
    has_beams || return "not_active"
    return _tacs_model_has_varying_station_beam(model) ?
        TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE * "_pbeam_station_kg" :
        TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE
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
    has_beams = _tacs_model_has_beam_stiffness(model)
    sol_type = _canonical_sol_type(get(model, "SOL", get(get(model, "CASE_CONTROL", Dict()), "SOL", 105)))
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(105, 106),
        route_label="SOL105/SOL106 Kg",
        allow_rods=true,
        allow_beams=has_beams,
        require_shell=!has_beams,
        allow_beam_offsets_releases=sol_type == 105,
        allow_varying_pbeam_stations=sol_type == 105,
    )
    cshells = get(model, "CSHELLs", Dict())
    crods = get(model, "CRODs", Dict())
    conrods = get(model, "CONRODs", Dict())
    cbars = get(model, "CBARs", Dict())
    cbeams = get(model, "CBEAMs", Dict())
    I_idx = Vector{Int}(); J_idx = Vector{Int}(); V_val = Vector{Float64}()
    nnz_est = 576 * length(cshells) + 144 * (length(crods) + length(conrods) + length(cbars) + length(cbeams))
    sizehint!(I_idx, nnz_est)
    sizehint!(J_idx, nnz_est)
    sizehint!(V_val, nnz_est)
    n_shell = 0
    n_rod = 0
    n_beam = 0
    n_sum = zeros(Float64, 3)
    rod_force_sum = 0.0
    beam_force_sum = 0.0
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
    for rod_group in (crods, conrods)
        for (_, rod) in rod_group
            Kg, dofs, axial_force = _tacs_rod_geometric_stiffness_operator(
                model, rod, id_map, X, node_R, u_static)
            n_rod += 1
            rod_force_sum += axial_force
            for c in 1:12, r in 1:12
                push!(I_idx, dofs[r])
                push!(J_idx, dofs[c])
                push!(V_val, Kg[r, c])
            end
        end
    end
    for beam_group in (cbars, cbeams)
        for (_, beam) in beam_group
            Kg, dofs, axial_force = _tacs_beam_geometric_stiffness_operator(
                model, beam, id_map, X, node_R, u_static)
            n_beam += 1
            beam_force_sum += axial_force
            for c in 1:12, r in 1:12
                push!(I_idx, dofs[r])
                push!(J_idx, dofs[c])
                push!(V_val, Kg[r, c])
            end
        end
    end
    Kg = sparse(I_idx, J_idx, V_val, ndof, ndof)
    if timings isa AbstractDict
        timings["tacs_native_kg_assembly"] = (time_ns() - t_start) * 1e-9
        timings["tacs_native_kg_elements"] = n_shell
        timings["tacs_native_kg_rod_elements"] = n_rod
        timings["tacs_native_kg_beam_elements"] = n_beam
        if n_shell > 0
            timings["tacs_native_kg_avg_Nxx"] = n_sum[1] / n_shell
            timings["tacs_native_kg_avg_Nyy"] = n_sum[2] / n_shell
            timings["tacs_native_kg_avg_Nxy"] = n_sum[3] / n_shell
        end
        if n_rod > 0
            timings["tacs_native_kg_avg_rod_axial_force"] = rod_force_sum / n_rod
        end
        if n_beam > 0
            timings["tacs_native_kg_avg_beam_axial_force"] = beam_force_sum / n_beam
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
        _tacs_assemble_sol101(
            model;
            allowed_sol_types=(103,),
            route_label="SOL103",
            allow_varying_pbeam_stations=true,
        )
    t_asm_K = (time_ns() - t_asm) * 1e-9

    cc = model["CASE_CONTROL"]
    sorted_sids = sort(collect(keys(cc["SUBCASES"])))
    mesh = _build_mesh_output(model, id_map, X)

    t_disp = time_ns()
    results = _solve_sol103(
        model, cc, K, id_map, X, ndof, node_R,
        max_elem_stiff, rbe3_map, orig_diag,
        sorted_sids, mesh;
        modal_mass_builder=_tacs_sol103_modal_mass_builder,
    )
    results["timings"] = Dict{String,Any}(
        "assembly_K" => t_asm_K,
        "assembly_Keig" => 0.0,
        "solve_cases" => (time_ns() - t_disp) * 1e-9,
    )
    results["K"] = K
    results["M"] = _tacs_sol103_modal_mass_builder(model, id_map, X, node_R, ndof)
    results["ndof"] = ndof
    results["node_R"] = node_R
    results["rbe3_map"] = rbe3_map
    results["tacs_formulation_sol103"] = Dict{String,Any}(
        "linear_stiffness" => _tacs_sol103_linear_stiffness_route_label(model),
        "mass" => _tacs_sol103_modal_mass_route_label(model),
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
    return nothing
end

function _solve_tacs_sol105(model::Dict)
    println("\n>>> SOL 105 Linear Buckling Analysis (TACS-formulation backend)")
    has_beams = _tacs_model_has_beam_stiffness(model)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(105,),
        route_label="SOL105",
        allow_rods=true,
        allow_beams=has_beams,
        require_shell=!has_beams,
        allow_varying_pbeam_stations=true,
    )
    _tacs_preflight_sol105_shared_route(model)

    t_asm = time_ns()
    K, id_map, X, ndof, node_R, max_elem_stiff, rbe3_map, snorm_normals, orig_diag =
        _tacs_assemble_sol101(
            model;
            allowed_sol_types=(105,),
            route_label="SOL105",
            allow_varying_pbeam_stations=true,
        )
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
    beam_kg_route = _tacs_sol105_beam_geometric_stiffness_route_label(model)
    results["tacs_formulation_sol105"] = Dict{String,Any}(
        "linear_stiffness" => _tacs_sol103_linear_stiffness_route_label(model),
        "geometric_stiffness" => TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE,
        "rod_geometric_stiffness" => "native_residual_first_crod_conrod_operator",
        "beam_geometric_stiffness" => beam_kg_route,
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
        "linear_stiffness" => TACS_LINEAR_SHELL_STIFFNESS_ROUTE,
        "geometric_stiffness" => TACS_GEOMETRIC_SHELL_STIFFNESS_ROUTE,
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

function _tacs_grid_point(model::AbstractDict, gid_raw)
    gid = _tacs_id_key(gid_raw)
    grid = get(get(model, "GRIDs", Dict()), gid, nothing)
    grid === nothing && error("TACS structural mass could not find GRID $gid.")
    x = Float64.(collect(get(grid, "X", Float64[])))
    length(x) >= 3 || error("TACS structural mass requires GRID $gid to have three coordinates.")
    return SVector{3,Float64}(x[1], x[2], x[3])
end

function _tacs_line_length(model::AbstractDict, ga_raw, gb_raw)
    p1 = _tacs_grid_point(model, ga_raw)
    p2 = _tacs_grid_point(model, gb_raw)
    L = norm(p2 - p1)
    L > 1e-12 || error("TACS structural mass found a near-zero line-element length.")
    return L
end

function _tacs_mat_density(model::AbstractDict, mid_raw)
    mid = _tacs_id_key(mid_raw)
    mat = get(get(model, "MATs", Dict()), mid, nothing)
    mat isa AbstractDict || error("TACS structural mass could not find material $mid.")
    return Float64(get(mat, "RHO", 0.0))
end

function _tacs_structural_mass_rod_value(model::Dict)
    mass = 0.0
    prods = get(model, "PRODs", Dict())
    for (_, rod) in get(model, "CRODs", Dict())
        pid = _tacs_id_key(get(rod, "PID", 0))
        prop = get(prods, pid, nothing)
        prop isa AbstractDict || error("TACS structural mass could not find PROD property $pid.")
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        rho = _tacs_mat_density(model, get(prop, "MID", 0))
        A = Float64(get(prop, "A", 0.0))
        nsm = Float64(get(prop, "NSM", 0.0))
        mass += (rho * A + nsm) * L
    end
    for (_, rod) in get(model, "CONRODs", Dict())
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        rho = _tacs_mat_density(model, get(rod, "MID", 0))
        A = Float64(get(rod, "A", 0.0))
        nsm = Float64(get(rod, "NSM", 0.0))
        mass += (rho * A + nsm) * L
    end
    return mass
end

function _tacs_structural_mass_beam_value(model::Dict)
    mass = 0.0
    props = get(model, "PBARLs", Dict())
    for group_name in ("CBARs", "CBEAMs")
        for (_, beam) in get(model, group_name, Dict())
            pid = _tacs_id_key(get(beam, "PID", 0))
            prop = get(props, pid, nothing)
            prop isa AbstractDict || error("TACS structural mass could not find PBAR/PBARL property $pid.")
            L = _tacs_line_length(model, get(beam, "GA", 0), get(beam, "GB", 0))
            rho = _tacs_mat_density(model, get(prop, "MID", 0))
            A = Float64(get(prop, "A", 0.0))
            nsm = Float64(get(prop, "NSM", 0.0))
            mass += (rho * A + nsm) * L
        end
    end
    return mass
end

function _tacs_structural_mass_point_mass_value(model::Dict)
    mass_total = 0.0
    for (_, mass) in get(model, "CONM2s", Dict())
        mass_total += Float64(get(mass, "M", 0.0))
    end
    for (_, mass) in get(model, "CMASS2s", Dict())
        mass_total += Float64(get(mass, "M", 0.0))
    end
    pmasses = get(model, "PMASSs", Dict())
    for (_, mass) in get(model, "CMASS1s", Dict())
        pid = _tacs_id_key(get(mass, "PID", 0))
        prop = get(pmasses, pid, nothing)
        prop isa AbstractDict || error("TACS structural mass could not find PMASS property $pid.")
        mass_total += Float64(get(prop, "M", 0.0))
    end
    return mass_total
end

function _tacs_structural_mass_value(model::Dict)
    isdefined(@__MODULE__, :_sol200_lite_shell_mass) ||
        error("TACS structural mass gradient requires the shell mass helper to be loaded.")
    return Float64(_sol200_lite_shell_mass(model)) +
           _tacs_structural_mass_rod_value(model) +
           _tacs_structural_mass_beam_value(model) +
           _tacs_structural_mass_point_mass_value(model)
end

function _tacs_pcomp_ply_density_for_mass(model::AbstractDict, prop::AbstractDict, ply_idx::Integer)
    ply_data = get(prop, "PLY_DATA", nothing)
    ply_data isa AbstractVector || error("TACS structural mass PCOMP derivative requires PLY_DATA.")
    1 <= ply_idx <= length(ply_data) ||
        error("TACS structural mass PCOMP derivative requested ply $ply_idx but property has $(length(ply_data)) plies.")
    ply = ply_data[ply_idx]
    mid = Int(get(ply, "mid", get(ply, "MID", 0)))
    mat = get(get(model, "MATs", Dict()), string(mid), nothing)
    mat isa AbstractDict || error("TACS structural mass PCOMP derivative could not find material $mid.")
    rho = Float64(get(mat, "RHO", 1.0))
    return rho > 0.0 ? rho : 1.0
end

function _tacs_structural_mass_shell_thickness_derivative(model::Dict, dv::AbstractDict)
    pid_list = Int.(collect(get(dv, "pids", _tacs_sol101_active_shell_pids(model))))
    isempty(pid_list) && (pid_list = _tacs_sol101_active_shell_pids(model))
    pid_filter = Set(pid_list)
    gradient = 0.0
    for (_, el) in get(model, "CSHELLs", Dict())
        pid = Int(get(el, "PID", 0))
        pid in pid_filter || continue
        prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
        prop isa AbstractDict || error("TACS structural mass derivative could not find shell property $pid.")
        area = Solver._element_area(el["NODES"], model)
        prop_type = uppercase(string(get(prop, "TYPE", "PSHELL")))
        if prop_type == "PCOMP_CLT"
            total_t = Float64(get(prop, "T", 0.0))
            total_t > 0.0 || error("TACS structural mass derivative requires positive PCOMP total thickness.")
            ply_mass_per_area = 0.0
            for (ply_idx, ply) in enumerate(get(prop, "PLY_DATA", Any[]))
                rho = _tacs_pcomp_ply_density_for_mass(model, prop, ply_idx)
                ply_mass_per_area += rho * Float64(ply["z_top"] - ply["z_bot"])
            end
            gradient += area * ply_mass_per_area / total_t
        else
            mid = Int(get(prop, "MID", 0))
            mat = get(get(model, "MATs", Dict()), string(mid), nothing)
            mat isa AbstractDict || error("TACS structural mass derivative could not find material $mid.")
            gradient += area * Float64(get(mat, "RHO", 0.0))
        end
    end
    return gradient
end

function _tacs_structural_mass_pcomp_ply_thickness_derivative(model::Dict, dv::AbstractDict)
    ply_idx = Int(get(dv, "ply_index", 0))
    ply_idx > 0 || error("TACS structural mass PCOMP derivative requires a positive ply_index.")
    pid_list = Int.(collect(get(dv, "pids", Int[])))
    if isempty(pid_list)
        for (pid, prop) in get(model, "PSHELLs", Dict())
            uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || continue
            push!(pid_list, Int(parse(Int, string(pid))))
        end
    end
    pid_filter = Set(pid_list)
    gradient = 0.0
    for (_, el) in get(model, "CSHELLs", Dict())
        pid = Int(get(el, "PID", 0))
        pid in pid_filter || continue
        prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
        prop isa AbstractDict || error("TACS structural mass derivative could not find shell property $pid.")
        uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" ||
            error("TACS structural mass PCOMP derivative requires PCOMP_CLT property $pid.")
        area = Solver._element_area(el["NODES"], model)
        gradient += area * _tacs_pcomp_ply_density_for_mass(model, prop, ply_idx)
    end
    return gradient
end

function _tacs_structural_mass_material_density_derivative(model::Dict, dv::AbstractDict)
    mids = Set(Int.(collect(get(dv, "mids", Int[]))))
    isempty(mids) && error("TACS structural mass material-density derivative requires at least one material id.")
    gradient = 0.0
    for (_, el) in get(model, "CSHELLs", Dict())
        pid = Int(get(el, "PID", 0))
        prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
        prop isa AbstractDict || error("TACS structural mass derivative could not find shell property $pid.")
        area = Solver._element_area(el["NODES"], model)
        prop_type = uppercase(string(get(prop, "TYPE", "PSHELL")))
        if prop_type == "PCOMP_CLT"
            for ply in get(prop, "PLY_DATA", Any[])
                ply_mid = Int(get(ply, "mid", get(ply, "MID", 0)))
                ply_mid in mids || continue
                gradient += area * Float64(ply["z_top"] - ply["z_bot"])
            end
        else
            Int(get(prop, "MID", 0)) in mids || continue
            gradient += area * Float64(get(prop, "T", 0.0))
        end
    end
    prods = get(model, "PRODs", Dict())
    for (_, rod) in get(model, "CRODs", Dict())
        pid = _tacs_id_key(get(rod, "PID", 0))
        prop = get(prods, pid, nothing)
        prop isa AbstractDict || error("TACS structural mass derivative could not find PROD property $pid.")
        Int(get(prop, "MID", 0)) in mids || continue
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        gradient += Float64(get(prop, "A", 0.0)) * L
    end
    for (_, rod) in get(model, "CONRODs", Dict())
        Int(get(rod, "MID", 0)) in mids || continue
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        gradient += Float64(get(rod, "A", 0.0)) * L
    end
    props = get(model, "PBARLs", Dict())
    for group_name in ("CBARs", "CBEAMs")
        for (_, beam) in get(model, group_name, Dict())
            pid = _tacs_id_key(get(beam, "PID", 0))
            prop = get(props, pid, nothing)
            prop isa AbstractDict || error("TACS structural mass derivative could not find PBAR/PBARL property $pid.")
            Int(get(prop, "MID", 0)) in mids || continue
            L = _tacs_line_length(model, get(beam, "GA", 0), get(beam, "GB", 0))
            gradient += Float64(get(prop, "A", 0.0)) * L
        end
    end
    return gradient
end

function _tacs_structural_mass_rod_area_derivative(model::Dict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    gradient = 0.0
    touched = 0
    prods = get(model, "PRODs", Dict())
    for (key, rod) in get(model, "CRODs", Dict())
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(rod, "PID", 0))
        _tacs_selected(pids, pid) || continue
        prop = get(prods, string(pid), nothing)
        prop isa AbstractDict || error("TACS structural mass derivative could not find PROD property $pid.")
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        gradient += _tacs_mat_density(model, get(prop, "MID", 0)) * L
        touched += 1
    end
    for (key, rod) in get(model, "CONRODs", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, rod)
        _tacs_selected(eids, eid) || continue
        L = _tacs_line_length(model, get(rod, "GA", 0), get(rod, "GB", 0))
        gradient += _tacs_mat_density(model, get(rod, "MID", 0)) * L
        touched += 1
    end
    touched > 0 || error("TACS structural mass rod_area derivative did not select any CROD/CONROD elements.")
    return gradient
end

function _tacs_structural_mass_beam_area_derivative(model::Dict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    gradient = 0.0
    touched = 0
    props = get(model, "PBARLs", Dict())
    for group_name in ("CBARs", "CBEAMs")
        for (key, beam) in get(model, group_name, Dict())
            eid = _tacs_entry_public_id(key, beam)
            _tacs_selected(eids, eid) || continue
            pid = Int(get(beam, "PID", 0))
            _tacs_selected(pids, pid) || continue
            prop = get(props, string(pid), nothing)
            prop isa AbstractDict || error("TACS structural mass derivative could not find PBAR/PBARL property $pid.")
            L = _tacs_line_length(model, get(beam, "GA", 0), get(beam, "GB", 0))
            gradient += _tacs_mat_density(model, get(prop, "MID", 0)) * L
            touched += 1
        end
    end
    touched > 0 || error("TACS structural mass beam_area derivative did not select any CBAR/CBEAM elements.")
    return gradient
end

function _tacs_structural_mass_point_mass_derivative(model::Dict, dv::AbstractDict)
    pids = _tacs_design_filter(dv, "pids")
    eids = _tacs_design_filter(dv, "eids")
    gradient = 0.0
    touched = 0
    for (key, mass) in get(model, "CONM2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        gradient += 1.0
        touched += 1
    end
    for (key, mass) in get(model, "CMASS2s", Dict())
        isempty(pids) || continue
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        gradient += 1.0
        touched += 1
    end
    for (key, mass) in get(model, "CMASS1s", Dict())
        eid = _tacs_entry_public_id(key, mass)
        _tacs_selected(eids, eid) || continue
        pid = Int(get(mass, "PID", 0))
        _tacs_selected(pids, pid) || continue
        get(get(model, "PMASSs", Dict()), string(pid), nothing) isa AbstractDict ||
            error("TACS structural mass point_mass derivative could not find PMASS property $pid.")
        gradient += 1.0
        touched += 1
    end
    touched > 0 || error("TACS structural mass point_mass derivative did not select any CONM2/CMASS1/CMASS2 masses.")
    return gradient
end

function _tacs_structural_mass_coordinate_derivative(model::Dict, dv::AbstractDict)
    grid = Int(get(dv, "grid", get(dv, "gid", 0)))
    comp = _tacs_node_coord_component(dv)
    h = _tacs_coordinate_step(model, dv)
    model_p = _tacs_model_with_grid_coord_delta(model, grid, comp, h)
    model_m = _tacs_model_with_grid_coord_delta(model, grid, comp, -h)
    return (_tacs_structural_mass_value(model_p) - _tacs_structural_mass_value(model_m)) / (2.0 * h), h
end

function structural_mass_design_gradient(::TACSFormulationBackend, results::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(101, 103, 105, 106),
        route_label="structural mass sensitivity",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        allow_masses=true,
        require_shell=false,
    )
    response = _tacs_response_function(Dict{String,Any}("type" => "mass"))
    mass_value = _tacs_structural_mass_value(model)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]

    for dv in design_variables
        dv isa AbstractDict || error("TACS structural mass design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(response, dv)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_mass_coefficient")
        push!(backend_labels, backend_label)

        steps = Float64[]
        method = sensitivity_contract.derivative_method
        if method == :mass_coordinate_fd
            gradient, h = _tacs_structural_mass_coordinate_derivative(model, dv)
            gradients[dv_id] = gradient
            push!(steps, h)
        elseif method == :mass_coefficient
            design_family = _tacs_design_family(dv)
            if design_family == :shell_thickness
                gradients[dv_id] = _tacs_structural_mass_shell_thickness_derivative(model, dv)
            elseif design_family == :pcomp_ply_thickness
                gradients[dv_id] = _tacs_structural_mass_pcomp_ply_thickness_derivative(model, dv)
            elseif design_family == :material_rho
                gradients[dv_id] = _tacs_structural_mass_material_density_derivative(model, dv)
            elseif design_family == :rod_area
                gradients[dv_id] = _tacs_structural_mass_rod_area_derivative(model, dv)
            elseif design_family == :beam_area
                gradients[dv_id] = _tacs_structural_mass_beam_area_derivative(model, dv)
            elseif design_family == :point_mass
                gradients[dv_id] = _tacs_structural_mass_point_mass_derivative(model, dv)
            else
                error("TACS structural mass coefficient derivative does not support design family '$design_family'.")
            end
        elseif method == :mass_independent
            gradients[dv_id] = 0.0
        else
            error("TACS structural mass gradient does not support derivative method '$method'.")
        end
        diagnostics[dv_id] = _tacs_design_diagnostics(dv, steps, sensitivity_contract, backend_label)
    end

    return Dict{String,Any}(
        "response" => "mass",
        "value" => mass_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_mass_coefficient"),
        "response_contract" => _tacs_contract_metadata(response),
        "design_variable_diagnostics" => diagnostics,
    )
end

function static_compliance_thickness_gradient(::TACSFormulationBackend, results::AbstractDict; pids=nothing)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    ctx = _tacs_static_response_context(
        results,
        Dict{String,Any}("type" => "compliance");
        required_family=:compliance,
        route_label="TACS static compliance gradient",
    )
    compliance = _tacs_response_value(ctx)

    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))
    gradients = Dict{String,Float64}()
    load_derivative_norms = Dict{String,Float64}()
    for pid in pid_list
        dK, _, _, _, _, _, _, _, _ = _tacs_assemble_sol101(model; thickness_derivative_pid=pid)
        dv = Dict{String,Any}("type" => "shell_thickness", "pids" => [pid])
        dF, _ = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 compliance thickness load sensitivity",
        )
        gradients[string(pid)] = -dot(ctx.u, dK * ctx.u) + 2.0 * dot(ctx.u, dF)
        load_derivative_norms[string(pid)] = norm(dF)
    end
    return Dict{String,Any}(
        "response" => "compliance",
        "value" => compliance,
        "gradient" => gradients,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_element_ad",
        "load_derivative_norms" => load_derivative_norms,
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "sensitivity_contract" => _tacs_contract_metadata(_tacs_sensitivity_contract(ctx.response.contract.family, :shell_thickness)),
        "subcase_index" => 1,
    )
end

function static_compliance_design_gradient(::TACSFormulationBackend, results::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(101,),
        route_label="SOL101 static compliance design gradient",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        require_shell=false,
    )
    ctx = _tacs_static_response_context(
        results,
        Dict{String,Any}("type" => "compliance");
        required_family=:compliance,
        route_label="TACS static compliance design gradient",
    )
    compliance = _tacs_response_value(ctx)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(ctx.response, dv)
        if sensitivity_contract.derivative_method == :adjoint_load_fd
            dK = spzeros(Float64, ctx.ndof, ctx.ndof)
            steps = Float64[]
        else
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        end
        dF, load_steps = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            stiffness_steps=steps,
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 compliance design-dependent load sensitivity",
        )
        gradients[dv_id] = -dot(ctx.u, dK * ctx.u) + 2.0 * dot(ctx.u, dF)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_design_tangent")
        push!(backend_labels, backend_label)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(steps), Float64.(load_steps)),
            sensitivity_contract,
            backend_label,
            load_derivative=dF,
        )
    end

    return Dict{String,Any}(
        "response" => "compliance",
        "value" => compliance,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_design_tangent"),
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
    )
end

function static_displacement_thickness_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict; pids=nothing)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    ctx = _tacs_static_response_context(
        results,
        response;
        required_family=:displacement,
        route_label="TACS static displacement gradient",
    )
    response_value = _tacs_response_value(ctx)
    lambda_full = _tacs_static_adjoint(ctx)

    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))
    gradients = Dict{String,Float64}()
    load_derivative_norms = Dict{String,Float64}()
    for pid in pid_list
        dK, _, _, _, _, _, _, _, _ = _tacs_assemble_sol101(model; thickness_derivative_pid=pid)
        dv = Dict{String,Any}("type" => "shell_thickness", "pids" => [pid])
        dF, _ = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 displacement thickness load sensitivity",
        )
        gradients[string(pid)] = -dot(lambda_full, dK * ctx.u) + dot(lambda_full, dF)
        load_derivative_norms[string(pid)] = norm(dF)
    end
    return Dict{String,Any}(
        "response" => "displacement",
        "grid" => Int(response["grid"]),
        "dof" => Int(response["dof"]),
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_element_ad_adjoint",
        "load_derivative_norms" => load_derivative_norms,
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "sensitivity_contract" => _tacs_contract_metadata(_tacs_sensitivity_contract(ctx.response.contract.family, :shell_thickness)),
        "subcase_index" => 1,
    )
end

function static_displacement_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(101,),
        route_label="SOL101 static displacement design gradient",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        require_shell=false,
    )
    ctx = _tacs_static_response_context(
        results,
        response;
        required_family=:displacement,
        route_label="TACS static displacement design gradient",
    )
    response_value = _tacs_response_value(ctx)
    lambda_full = _tacs_static_adjoint(ctx)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(ctx.response, dv)
        if sensitivity_contract.derivative_method == :adjoint_load_fd
            dK = spzeros(Float64, ctx.ndof, ctx.ndof)
            steps = Float64[]
        else
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        end
        dF, load_steps = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            stiffness_steps=steps,
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 displacement design-dependent load sensitivity",
        )
        gradients[dv_id] = -dot(lambda_full, dK * ctx.u) + dot(lambda_full, dF)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_design_tangent_adjoint")
        push!(backend_labels, backend_label)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(steps), Float64.(load_steps)),
            sensitivity_contract,
            backend_label,
            load_derivative=dF,
        )
    end

    return Dict{String,Any}(
        "response" => "displacement",
        "grid" => Int(response["grid"]),
        "dof" => Int(response["dof"]),
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_design_tangent_adjoint"),
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
    )
end

function static_ks_displacement_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(101,),
        route_label="SOL101 static KS displacement design gradient",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        require_shell=false,
    )
    ctx = _tacs_static_response_context(
        results,
        response;
        required_family=:ks_displacement,
        route_label="TACS static KS displacement design gradient",
    )
    response_value = _tacs_response_value(ctx)
    lambda_full = _tacs_static_adjoint(ctx)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    for dv in design_variables
        dv isa AbstractDict || error("TACS KS displacement design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(ctx.response, dv)
        if sensitivity_contract.derivative_method == :adjoint_load_fd
            dK = spzeros(Float64, ctx.ndof, ctx.ndof)
            steps = Float64[]
        else
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        end
        dF, load_steps = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            stiffness_steps=steps,
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 KS displacement design-dependent load sensitivity",
        )
        gradients[dv_id] = -dot(lambda_full, dK * ctx.u) + dot(lambda_full, dF)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_ks_displacement_design_tangent_adjoint")
        push!(backend_labels, backend_label)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(steps), Float64.(load_steps)),
            sensitivity_contract,
            backend_label,
            load_derivative=dF,
        )
    end

    return Dict{String,Any}(
        "response" => "ks_displacement",
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_ks_displacement_design_tangent_adjoint"),
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
    )
end

function static_ks_von_mises_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(101,),
        route_label="SOL101 static stress gradient",
        allow_beams=true,
        require_shell=false,
    )
    ctx = _tacs_static_response_context(
        results,
        response;
        required_family=:ks_von_mises,
        route_label="TACS static stress gradient",
    )
    response_value = _tacs_response_value(ctx)
    lambda_full = _tacs_static_adjoint(ctx)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(ctx.response, dv)
        if sensitivity_contract.derivative_method == :adjoint_load_fd
            dK = spzeros(Float64, ctx.ndof, ctx.ndof)
            steps = Float64[]
        else
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
        end
        dF, load_steps = _tacs_assemble_sol101_load_design_derivative(
            results,
            dv;
            stiffness_steps=steps,
            subcase_index=ctx.subcase_index,
            allowed_sol_types=(101,),
            route_label="SOL101 stress design-dependent load sensitivity",
        )
        explicit_value =
            sensitivity_contract.derivative_method == :adjoint_load_fd ? 0.0 :
            _tacs_response_explicit_design_derivative(ctx, dv)
        gradients[dv_id] = explicit_value - dot(lambda_full, dK * ctx.u) + dot(lambda_full, dF)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_stress_adjoint_design_tangent")
        push!(backend_labels, backend_label)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(steps), Float64.(load_steps)),
            sensitivity_contract,
            backend_label;
            explicit_derivative=explicit_value,
            load_derivative=dF,
        )
    end

    return Dict{String,Any}(
        "response" => "ks_von_mises",
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_stress_adjoint_design_tangent"),
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
        "ks_rho" => Float64(get(response, "rho", 50.0)),
        "sigma_ref" => Float64(get(response, "sigma_ref", 1.0)),
    )
end

function static_ks_ply_failure_design_gradient(::TACSFormulationBackend, results::AbstractDict, response::AbstractDict, design_variables::AbstractVector)
    model = results["model"]
    _tacs_validate_sol101_slice(model)
    ctx = _tacs_static_response_context(
        results,
        response;
        required_family=:ks_ply_failure,
        route_label="TACS static ply-failure gradient",
    )
    response_value = _tacs_response_value(ctx)
    lambda_full = _tacs_static_adjoint(ctx)

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    for dv in design_variables
        dv isa AbstractDict || error("TACS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(ctx.response, dv)
        if sensitivity_contract.derivative_method == :explicit_failure_strength
            dK = spzeros(Float64, ctx.ndof, ctx.ndof)
            steps = Float64[]
            dF = zeros(Float64, ctx.ndof)
            load_steps = Float64[]
        else
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(model, dv)
            dF, load_steps = _tacs_assemble_sol101_load_design_derivative(
                results,
                dv;
                stiffness_steps=steps,
                subcase_index=ctx.subcase_index,
                allowed_sol_types=(101,),
                route_label="SOL101 ply-failure design-dependent load sensitivity",
            )
        end
        explicit_value = _tacs_response_explicit_design_derivative(ctx, dv)
        gradients[dv_id] = explicit_value - dot(lambda_full, dK * ctx.u) + dot(lambda_full, dF)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_ply_failure_adjoint_design_tangent")
        push!(backend_labels, backend_label)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(steps), Float64.(load_steps)),
            sensitivity_contract,
            backend_label;
            explicit_derivative=explicit_value,
            load_derivative=dF,
        )
    end

    return Dict{String,Any}(
        "response" => "ks_ply_failure",
        "value" => response_value,
        "gradient" => gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_ply_failure_adjoint_design_tangent"),
        "response_contract" => _tacs_contract_metadata(ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "subcase_index" => 1,
        "ks_rho" => Float64(get(response, "rho", 50.0)),
        "failure_ref" => Float64(get(response, "failure_ref", get(response, "ref", 1.0))),
        "criterion" => string(get(response, "criterion", "tsai_hill")),
    )
end

function _tacs_set_shell_property_thickness!(prop::AbstractDict, pid::Integer, value::Real)
    t = Float64(value)
    t > 0.0 || error("TACS thickness perturbation requires positive thickness; got $t for property $pid.")
    prop["T"] = t
    if uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL"
        prop["Z1"] = -0.5 * t
        prop["Z2"] = 0.5 * t
    else
        _tacs_ensure_pcomp_reference!(prop)
    end
    return prop
end

function _tacs_model_with_shell_property_thickness(model::AbstractDict, pid::Integer, value::Real; sol_type=105)
    m = deepcopy(model)
    prop = get(get(m, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("TACS thickness perturbation could not find shell property $pid.")
    _tacs_set_shell_property_thickness!(prop, pid, value)
    m["backend"] = JFEM_BACKEND_TACS
    m["SOL"] = Int(sol_type)
    if haskey(m, "CASE_CONTROL")
        m["CASE_CONTROL"]["SOL"] = Int(sol_type)
    end
    return m
end

function _tacs_sol103_mass_matrix(model::Dict)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(103,),
        route_label="SOL103 modal mass sensitivity",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        allow_masses=true,
        allow_conm1=true,
        require_shell=false,
    )
    id_map, X, ndof, node_R = _tacs_node_tables(model)
    M = _tacs_sol103_modal_mass_builder(model, id_map, X, node_R, ndof)
    return M, id_map, X, ndof, node_R
end

function _tacs_modal_design_raw_step(dv::AbstractDict)
    raw_step = get(dv, "step", nothing)
    raw_step === nothing && return nothing
    step = Float64(raw_step)
    step > 0.0 || error("TACS modal finite-difference step must be positive; got $step.")
    return step
end

function _tacs_modal_mass_fd_step(model::AbstractDict, dv::AbstractDict, stiffness_steps=Float64[])
    raw = _tacs_modal_design_raw_step(dv)
    raw !== nothing && return raw
    !isempty(stiffness_steps) && return maximum(abs.(Float64.(stiffness_steps)))

    dv_type = string(get(dv, "type", ""))
    if dv_type == "node_coord"
        return _tacs_coordinate_step(model, dv)
    elseif dv_type == "shell_thickness"
        pid_list = Int.(collect(get(dv, "pids", _tacs_sol101_active_shell_pids(model))))
        isempty(pid_list) && (pid_list = _tacs_sol101_active_shell_pids(model))
        isempty(pid_list) && error("TACS modal shell-thickness mass derivative requires at least one active shell property.")
        h = Inf
        for pid in pid_list
            prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS modal shell-thickness mass derivative could not find property $pid.")
            t0 = Float64(get(prop, "T", 0.0))
            t0 > 0.0 || error("TACS modal shell-thickness mass derivative requires positive thickness.")
            h = min(h, max(1e-6 * t0, 1e-8), 0.25 * t0)
        end
        isfinite(h) && h > 0.0 ||
            error("TACS modal shell-thickness mass derivative could not choose a positive perturbation.")
        return h
    elseif dv_type == "pcomp_ply_thickness"
        ply_idx = Int(get(dv, "ply_index", 0))
        ply_idx > 0 || error("TACS modal PCOMP ply mass derivative requires a positive ply_index.")
        pid_list = Int.(collect(get(dv, "pids", Int[])))
        if isempty(pid_list)
            for (pid, prop) in get(model, "PSHELLs", Dict())
                uppercase(string(get(prop, "TYPE", ""))) == "PCOMP_CLT" || continue
                push!(pid_list, Int(parse(Int, string(pid))))
            end
        end
        isempty(pid_list) && error("TACS modal PCOMP ply mass derivative requires at least one PCOMP_CLT property.")
        h = Inf
        for pid in pid_list
            prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
            prop === nothing && error("TACS modal PCOMP ply mass derivative could not find property $pid.")
            h = min(h, _tacs_pcomp_ply_step(prop, ply_idx, :T))
        end
        isfinite(h) && h > 0.0 ||
            error("TACS modal PCOMP ply mass derivative could not choose a positive perturbation.")
        return h
    elseif dv_type == "material_RHO"
        return _tacs_material_group_design_step(model, dv)
    elseif dv_type == "rod_area"
        return _tacs_line_static_design_step(model, dv)
    elseif _tacs_is_beam_sizing_design_type(dv_type)
        return _tacs_line_static_design_step(model, dv)
    elseif dv_type == "point_mass"
        return _tacs_group_positive_step(_tacs_point_mass_values(model, dv), "point_mass")
    elseif dv_type == "point_inertia"
        return _tacs_group_positive_step(_tacs_point_inertia_values(model, dv), "point_inertia")
    end
    return 0.0
end

function _tacs_sol103_mass_design_dependent(dv::AbstractDict)
    dv_type = string(get(dv, "type", ""))
    return dv_type in ("node_coord", "shell_thickness", "pcomp_ply_thickness", "material_RHO", "rod_area", "point_mass", "point_inertia") ||
           _tacs_is_beam_sizing_design_type(dv_type)
end

function _tacs_assemble_sol103_mass_design_derivative(
    model::Dict,
    dv::AbstractDict;
    step=nothing,
    stiffness_steps=Float64[],
)
    M0, id_map, X, ndof, node_R = _tacs_sol103_mass_matrix(model)
    _tacs_sol103_mass_design_dependent(dv) ||
        return spzeros(Float64, ndof, ndof), id_map, X, ndof, node_R, Float64[]

    dv_type = string(get(dv, "type", ""))
    if dv_type == "node_coord"
        grid = Int(get(dv, "grid", get(dv, "gid", 0)))
        comp = _tacs_node_coord_component(dv)
        h = step === nothing ? _tacs_modal_mass_fd_step(model, dv, stiffness_steps) : Float64(step)
        h > 0.0 || error("TACS modal coordinate mass derivative requires a positive perturbation.")
        model_p = _tacs_model_with_grid_coord_delta(model, grid, comp, h)
        model_m = _tacs_model_with_grid_coord_delta(model, grid, comp, -h)
        Mp, id_map_p, X_p, ndof_p, node_R_p = _tacs_sol103_mass_matrix(model_p)
        Mm, id_map_m, _, ndof_m, _ = _tacs_sol103_mass_matrix(model_m)
        ndof_p == ndof_m == ndof ||
            error("TACS modal coordinate mass derivative changed ndof for GRID $grid component $comp.")
        length(id_map_p) == length(id_map_m) == length(id_map) ||
            error("TACS modal coordinate mass derivative changed GRID map size.")
        dM = (Mp .- Mm) ./ (2.0 * h)
        dM = 0.5 .* (dM .+ transpose(dM))
        return dM, id_map_p, X_p, ndof_p, node_R_p, [h]
    end
    if dv_type == "rod_area"
        h = step === nothing ? _tacs_modal_mass_fd_step(model, dv, stiffness_steps) : Float64(step)
        h > 0.0 || error("TACS modal rod_area mass derivative requires a positive diagnostic perturbation.")
        dM = _tacs_assemble_rod_area_mass_derivative(model, dv, id_map, X, node_R, ndof)
        return dM, id_map, X, ndof, node_R, [h]
    end

    h = step === nothing ? _tacs_modal_mass_fd_step(model, dv, stiffness_steps) : Float64(step)
    h > 0.0 || error("TACS modal mass derivative requires a positive perturbation for design variable '$(_tacs_design_variable_id(dv))'.")
    model_p = _tacs_model_with_design_delta(model, dv, h)
    model_m = _tacs_model_with_design_delta(model, dv, -h)
    Mp, id_map_p, X_p, ndof_p, node_R_p = _tacs_sol103_mass_matrix(model_p)
    Mm, id_map_m, _, ndof_m, _ = _tacs_sol103_mass_matrix(model_m)
    ndof_p == ndof_m == ndof ||
        error("TACS modal mass derivative changed ndof for design variable '$(_tacs_design_variable_id(dv))'.")
    length(id_map_p) == length(id_map_m) == length(id_map) ||
        error("TACS modal mass derivative changed GRID map size for design variable '$(_tacs_design_variable_id(dv))'.")
    dM = (Mp .- Mm) ./ (2.0 * h)
    dM = 0.5 .* (dM .+ transpose(dM))
    _ = M0
    return dM, id_map_p, X_p, ndof_p, node_R_p, [h]
end

function _tacs_sol103_analysis_modes(results::AbstractDict, mode_list::AbstractVector{<:Integer})
    raw_modes = get(results, "_raw_mode_shapes", zeros(Float64, 0, 0))
    isempty(mode_list) && return zeros(Float64, size(raw_modes, 1), 0)
    maximum(mode_list) <= size(raw_modes, 2) ||
        error("TACS modal clustered sensitivity requested mode $(maximum(mode_list)) but only $(size(raw_modes, 2)) modes are stored.")
    node_R = results["node_R"]
    id_map = results["id_map"]
    modes_analysis = isdefined(@__MODULE__, :_sol103_global_to_analysis_modes) ?
        _sol103_global_to_analysis_modes(raw_modes, id_map, node_R) :
        raw_modes
    return Matrix{Float64}(modes_analysis[:, Int.(mode_list)])
end

function modal_eigenvalue_design_gradient(
    ::TACSFormulationBackend,
    results::AbstractDict,
    design_variables::AbstractVector;
    mode::Integer=1,
    cluster_policy=:current_mode,
    cluster_rel_tol::Real=1e-8,
    cluster_abs_tol::Real=1e-10,
    mode_tracking=nothing,
)
    Int(get(results, "sol_type", 0)) == 103 ||
        error("TACS modal eigenvalue design gradient requires SOL103 results.")
    selected_mode, tracking_diag = _tacs_resolve_tracked_mode(
        results;
        mode=mode,
        mode_tracking=mode_tracking,
        analysis_family=:modal,
    )
    modal_ctx = _tacs_modal_response_context(results; mode=selected_mode)
    policy = _tacs_cluster_policy(cluster_policy)
    cluster_rel = Float64(cluster_rel_tol)
    cluster_abs = Float64(cluster_abs_tol)

    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(103,),
        route_label="SOL103 modal design sensitivity",
        allow_rods=true,
        allow_beams=true,
        allow_springs=true,
        allow_masses=true,
        allow_conm1=true,
        require_shell=false,
    )

    gradients = Dict{String,Float64}()
    frequency_gradients = Dict{String,Float64}()
    cluster_gradient_eigenvalues = Dict{String,Vector{Float64}}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    cluster_modes = _tacs_eigenvalue_cluster_modes(
        Float64.(get(results, "eigenvalues", Float64[])),
        modal_ctx.mode;
        rel_tol=cluster_rel,
        abs_tol=cluster_abs,
    )
    cluster_phi = length(cluster_modes) > 1 ? _tacs_sol103_analysis_modes(results, cluster_modes) : zeros(Float64, 0, 0)

    for dv in design_variables
        dv isa AbstractDict || error("TACS modal design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(modal_ctx.response, dv)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_modal_design_tangent")
        push!(backend_labels, backend_label)

        design_family = _tacs_design_family(dv)
        if design_family in (:material_rho, :point_mass, :point_inertia)
            dK = spzeros(Float64, size(modal_ctx.K, 1), size(modal_ctx.K, 2))
            stiffness_steps = Float64[]
        else
            dK, _, _, _, _, stiffness_steps = _tacs_assemble_sol101_design_derivative(
                model,
                dv;
                allowed_sol_types=(103,),
                route_label="SOL103 modal design sensitivity",
            )
        end

        mass_step = isempty(stiffness_steps) ? nothing : maximum(abs.(stiffness_steps))
        dM, _, _, _, _, mass_steps = _tacs_assemble_sol103_mass_design_derivative(
            model,
            dv;
            step=mass_step,
            stiffness_steps=stiffness_steps,
        )

        current_dlambda = dot(modal_ctx.phi, (dK - modal_ctx.value * dM) * modal_ctx.phi) / modal_ctx.denominator
        cluster_values = nothing
        frequency_gradients[dv_id] =
            modal_ctx.value > 0.0 ? current_dlambda / (4.0 * pi * sqrt(modal_ctx.value)) : NaN
        if length(cluster_modes) > 1
            cluster_values = _tacs_modal_cluster_projected_derivatives(
                cluster_phi,
                dK,
                dM,
                modal_ctx.M,
                modal_ctx.value;
                route_label="SOL103 modal clustered sensitivity",
            )
            cluster_gradient_eigenvalues[dv_id] = cluster_values
        end
        dlambda =
            cluster_values === nothing ?
            Float64(current_dlambda) :
            _tacs_select_cluster_derivative(cluster_values, current_dlambda; policy=policy)
        gradients[dv_id] = dlambda
        frequency_gradients[dv_id] =
            modal_ctx.value > 0.0 ? dlambda / (4.0 * pi * sqrt(modal_ctx.value)) : NaN
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            vcat(Float64.(stiffness_steps), Float64.(mass_steps)),
            sensitivity_contract,
            backend_label,
        )
        diagnostics[dv_id]["generalized_mass"] = modal_ctx.denominator
        diagnostics[dv_id]["current_mode_derivative"] = Float64(current_dlambda)
        diagnostics[dv_id]["selected_eigen_derivative"] = Float64(dlambda)
        diagnostics[dv_id]["cluster_policy"] = string(policy)
        if length(cluster_modes) > 1
            diagnostics[dv_id]["cluster_eigenvalue_derivatives"] = cluster_gradient_eigenvalues[dv_id]
            diagnostics[dv_id]["cluster_policy_derivative"] = Float64(dlambda)
        end
    end

    return Dict{String,Any}(
        "response" => "modal_eigenvalue",
        "requested_mode" => Int(mode),
        "mode" => modal_ctx.mode,
        "value" => modal_ctx.value,
        "frequency" => modal_ctx.frequency,
        "gradient" => gradients,
        "frequency_gradient" => frequency_gradients,
        "cluster_modes" => cluster_modes,
        "cluster_gradient_eigenvalues" => cluster_gradient_eigenvalues,
        "cluster_policy" => string(policy),
        "cluster_tolerances" => Dict{String,Float64}("rel_tol" => cluster_rel, "abs_tol" => cluster_abs),
        "cluster_detected" => length(cluster_modes) > 1,
        "mode_tracking" => tracking_diag,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_modal_design_tangent"),
        "response_contract" => _tacs_contract_metadata(modal_ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "eigen_derivative" =>
            length(cluster_modes) > 1 && policy != :current_mode ?
            "cluster_policy_projected_derivative" :
            "rayleigh_current_mode_total_derivative",
        "normalization" => "analysis_frame_generalized_mass",
    )
end

function _tacs_sol105_static_displacement_design_derivative(
    results::AbstractDict,
    dK::AbstractMatrix;
    dF=nothing,
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
    load_tangent =
        dF === nothing ? zeros(Float64, ndof) : Float64.(collect(dF))
    length(load_tangent) == ndof ||
        error("TACS buckling preload derivative requires dF length $ndof; got $(length(load_tangent)).")
    rhs = (load_tangent .- dK * u_static)[free_dofs]
    du = zeros(Float64, ndof)
    du[free_dofs] = cholesky(Symmetric(K_ff)) \ rhs
    return du
end

_tacs_sol105_static_displacement_thickness_derivative(results::AbstractDict, dK::AbstractMatrix) =
    _tacs_sol105_static_displacement_design_derivative(results, dK)

function _tacs_sol105_static_subcase_sid(results::AbstractDict)
    diagnostics = get(results, "solver_diagnostics", Any[])
    if !isempty(diagnostics)
        first_diag = diagnostics[1]
        haskey(first_diag, "static_subcase") && return Int(first_diag["static_subcase"])
    end
    buckling = get(results, "buckling", nothing)
    if buckling !== nothing && hasproperty(buckling, :subcases) && !isempty(getproperty(buckling, :subcases))
        first_subcase = first(getproperty(buckling, :subcases))
        hasproperty(first_subcase, :static_subcase_id) && return Int(getproperty(first_subcase, :static_subcase_id))
    end
    return 1
end

function _tacs_sol105_static_load_design_derivative(
    results::AbstractDict,
    dv::AbstractDict;
    stiffness_steps=Float64[],
)
    static_sid = _tacs_sol105_static_subcase_sid(results)
    return _tacs_assemble_sol101_load_design_derivative(
        results,
        dv;
        stiffness_steps=stiffness_steps,
        sid=static_sid,
        allowed_sol_types=(105,),
        route_label="SOL105 static preload design-dependent load sensitivity",
    )
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

function _tacs_sol105_geometric_stiffness_coordinate_derivative(
    results::AbstractDict,
    dv::AbstractDict,
    du_static_dx::AbstractVector,
    step::Float64,
)
    model = results["model"]
    grid = Int(get(dv, "grid", get(dv, "gid", 0)))
    comp = _tacs_node_coord_component(dv)
    h = step > 0.0 ? step : _tacs_coordinate_step(model, dv)
    h > 0.0 || error("TACS buckling coordinate derivative requires a positive finite-difference step.")

    u_static = Float64.(results["u_static"])
    du = Float64.(du_static_dx)
    length(u_static) == length(du) ||
        error("TACS buckling coordinate derivative requires matching static displacement derivative length.")
    snorm_normals = get(results, "snorm_normals", Dict{Int,SVector{3,Float64}}())
    rbe3_map = get(results, "rbe3_map", Dict{Int,Vector{Tuple{Int,Float64}}}())

    model_p = _tacs_model_with_grid_coord_delta(model, grid, comp, h)
    model_m = _tacs_model_with_grid_coord_delta(model, grid, comp, -h)
    id_map_p, X_p, ndof_p, node_R_p = _tacs_node_tables(model_p)
    id_map_m, X_m, ndof_m, node_R_m = _tacs_node_tables(model_m)
    ndof_p == ndof_m == length(u_static) ||
        error("TACS buckling coordinate derivative changed ndof for GRID $grid component $comp.")

    Kg_p = _tacs_assemble_sol105_geometric_stiffness(
        model_p,
        id_map_p,
        X_p,
        node_R_p,
        ndof_p,
        u_static .+ h .* du,
        snorm_normals,
        rbe3_map,
    )
    Kg_m = _tacs_assemble_sol105_geometric_stiffness(
        model_m,
        id_map_m,
        X_m,
        node_R_m,
        ndof_m,
        u_static .- h .* du,
        snorm_normals,
        rbe3_map,
    )
    return (Kg_p .- Kg_m) ./ (2.0 * h), h
end

function _tacs_sol105_geometric_stiffness_design_derivative(
    results::AbstractDict,
    dv::AbstractDict,
    du_static_dx::AbstractVector,
    step::Float64,
)
    h = Float64(step)
    h > 0.0 || error("TACS buckling design derivative requires a positive finite-difference step.")

    u_static = Float64.(results["u_static"])
    du = Float64.(du_static_dx)
    length(u_static) == length(du) ||
        error("TACS buckling design derivative requires matching static displacement derivative length.")
    id_map = results["id_map"]
    X = results["node_coords"]
    node_R = results["node_R"]
    ndof = Int(results["ndof"])
    snorm_normals = get(results, "snorm_normals", Dict{Int,SVector{3,Float64}}())
    rbe3_map = get(results, "rbe3_map", Dict{Int,Vector{Tuple{Int,Float64}}}())

    model_p = _tacs_model_with_design_delta(results["model"], dv, h)
    model_m = _tacs_model_with_design_delta(results["model"], dv, -h)
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

function buckling_load_factor_thickness_gradient(
    ::TACSFormulationBackend,
    results::AbstractDict;
    pids=nothing,
    mode::Integer=1,
    cluster_policy=:current_mode,
    cluster_rel_tol::Real=1e-8,
    cluster_abs_tol::Real=1e-10,
    mode_tracking=nothing,
)
    Int(get(results, "sol_type", 0)) == 105 ||
        error("TACS buckling load-factor gradient requires SOL105 results.")
    selected_mode, tracking_diag = _tacs_resolve_tracked_mode(
        results;
        mode=mode,
        mode_tracking=mode_tracking,
        analysis_family=:buckling,
    )
    buckling_ctx = _tacs_buckling_response_context(results; mode=selected_mode)
    policy = _tacs_cluster_policy(cluster_policy)
    cluster_rel = Float64(cluster_rel_tol)
    cluster_abs = Float64(cluster_abs_tol)

    model = results["model"]
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(105,),
        route_label="SOL105 buckling sensitivity",
        allow_rods=true,
    )
    pid_list =
        pids === nothing ? _tacs_sol101_active_shell_pids(model) :
        sort!(unique(Int.(collect(pids))))

    gradients = Dict{String,Float64}()
    cluster_gradient_eigenvalues = Dict{String,Vector{Float64}}()
    directional_steps = Dict{String,Float64}()
    current_mode_derivatives = Dict{String,Float64}()
    selected_eigen_derivatives = Dict{String,Float64}()
    cluster_modes = _tacs_eigenvalue_cluster_modes(
        Float64.(get(results, "eigenvalues", Float64[])),
        buckling_ctx.mode;
        rel_tol=cluster_rel,
        abs_tol=cluster_abs,
    )
    cluster_phi =
        length(cluster_modes) > 1 ?
        Matrix{Float64}(results["_raw_mode_shapes"][:, cluster_modes]) :
        zeros(Float64, 0, 0)
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
        dv = Dict{String,Any}("type" => "shell_thickness", "pids" => [pid])
        dF, _ = _tacs_sol105_static_load_design_derivative(
            results,
            dv;
            stiffness_steps=[max(1e-6 * t0, 1e-8)],
        )
        du_dt = _tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)
        dKg, h = _tacs_sol105_geometric_stiffness_directional_derivative(
            results,
            pid,
            du_dt,
            max(1e-6 * t0, 1e-8),
        )
        current_derivative = dot(buckling_ctx.phi, (dK + buckling_ctx.value * dKg) * buckling_ctx.phi) / buckling_ctx.denominator
        selected_derivative = Float64(current_derivative)
        if length(cluster_modes) > 1
            cluster_gradient_eigenvalues[string(pid)] = _tacs_buckling_cluster_projected_derivatives(
                cluster_phi,
                dK,
                dKg,
                results["Kg"],
                buckling_ctx.value;
                route_label="SOL105 buckling clustered thickness sensitivity",
            )
            selected_derivative = _tacs_select_cluster_derivative(
                cluster_gradient_eigenvalues[string(pid)],
                current_derivative;
                policy=policy,
            )
        end
        gradients[string(pid)] = selected_derivative
        current_mode_derivatives[string(pid)] = Float64(current_derivative)
        selected_eigen_derivatives[string(pid)] = Float64(selected_derivative)
        directional_steps[string(pid)] = h
    end

    return Dict{String,Any}(
        "response" => "buckling_load_factor",
        "requested_mode" => Int(mode),
        "mode" => buckling_ctx.mode,
        "value" => buckling_ctx.value,
        "gradient" => gradients,
        "cluster_modes" => cluster_modes,
        "cluster_gradient_eigenvalues" => cluster_gradient_eigenvalues,
        "cluster_policy" => string(policy),
        "cluster_tolerances" => Dict{String,Float64}("rel_tol" => cluster_rel, "abs_tol" => cluster_abs),
        "cluster_detected" => length(cluster_modes) > 1,
        "mode_tracking" => tracking_diag,
        "design_variable_type" => "shell_thickness",
        "gradient_backend" => "tacs_formulation_rayleigh_ad_kg_directional_fd",
        "response_contract" => _tacs_contract_metadata(buckling_ctx.response),
        "sensitivity_contract" => _tacs_contract_metadata(_tacs_sensitivity_contract(buckling_ctx.response.contract.family, :shell_thickness)),
        "directional_steps" => directional_steps,
        "current_mode_derivative" => current_mode_derivatives,
        "selected_eigen_derivative" => selected_eigen_derivatives,
        "eigen_derivative" =>
            length(cluster_modes) > 1 && policy != :current_mode ?
            "cluster_policy_projected_derivative" :
            "rayleigh_current_mode_total_derivative",
    )
end

function buckling_load_factor_design_gradient(
    ::TACSFormulationBackend,
    results::AbstractDict,
    design_variables::AbstractVector;
    mode::Integer=1,
    cluster_policy=:current_mode,
    cluster_rel_tol::Real=1e-8,
    cluster_abs_tol::Real=1e-10,
    mode_tracking=nothing,
)
    Int(get(results, "sol_type", 0)) == 105 ||
        error("TACS buckling load-factor design gradient requires SOL105 results.")
    selected_mode, tracking_diag = _tacs_resolve_tracked_mode(
        results;
        mode=mode,
        mode_tracking=mode_tracking,
        analysis_family=:buckling,
    )
    buckling_ctx = _tacs_buckling_response_context(results; mode=selected_mode)
    policy = _tacs_cluster_policy(cluster_policy)
    cluster_rel = Float64(cluster_rel_tol)
    cluster_abs = Float64(cluster_abs_tol)

    model = results["model"]
    has_beams = _tacs_model_has_beam_stiffness(model)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(105,),
        route_label="SOL105 buckling design sensitivity",
        allow_rods=true,
        allow_beams=has_beams,
        require_shell=!has_beams,
    )

    gradients = Dict{String,Float64}()
    cluster_gradient_eigenvalues = Dict{String,Vector{Float64}}()
    diagnostics = Dict{String,Any}()
    backend_labels = String[]
    directional_steps = Dict{String,Float64}()
    cluster_modes = _tacs_eigenvalue_cluster_modes(
        Float64.(get(results, "eigenvalues", Float64[])),
        buckling_ctx.mode;
        rel_tol=cluster_rel,
        abs_tol=cluster_abs,
    )
    cluster_phi =
        length(cluster_modes) > 1 ?
        Matrix{Float64}(results["_raw_mode_shapes"][:, cluster_modes]) :
        zeros(Float64, 0, 0)

    for dv in design_variables
        dv isa AbstractDict || error("TACS buckling design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        sensitivity_contract = _tacs_sensitivity_contract(buckling_ctx.response, dv)
        backend_label = _tacs_gradient_backend_label(sensitivity_contract, "tacs_formulation_rayleigh_design_tangent")
        push!(backend_labels, backend_label)

        design_family = _tacs_design_family(dv)
        current_derivative = nothing
        cluster_values = nothing
        if design_family == :node_coord
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(
                model,
                dv;
                allowed_sol_types=(105,),
                route_label="SOL105 buckling coordinate sensitivity",
            )
            dF, load_steps = _tacs_sol105_static_load_design_derivative(
                results,
                dv;
                stiffness_steps=steps,
            )
            du_dx = _tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)
            all_steps = vcat(Float64.(steps), Float64.(load_steps))
            h0 = isempty(all_steps) ? _tacs_coordinate_step(model, dv) : maximum(all_steps)
            dKg, h = _tacs_sol105_geometric_stiffness_coordinate_derivative(results, dv, du_dx, h0)
            current_derivative = dot(buckling_ctx.phi, (dK + buckling_ctx.value * dKg) * buckling_ctx.phi) / buckling_ctx.denominator
            if length(cluster_modes) > 1
                cluster_values = _tacs_buckling_cluster_projected_derivatives(
                    cluster_phi,
                    dK,
                    dKg,
                    results["Kg"],
                    buckling_ctx.value;
                    route_label="SOL105 buckling clustered coordinate sensitivity",
                )
            end
            directional_steps[dv_id] = h
            diagnostics[dv_id] = _tacs_design_diagnostics(
                dv,
                vcat([h], Float64.(load_steps)),
                sensitivity_contract,
                backend_label,
                load_derivative=dF,
            )
        elseif sensitivity_contract.derivative_method == :rayleigh_load_kg_directional_fd
            ndof = Int(results["ndof"])
            dK = spzeros(Float64, ndof, ndof)
            dF, load_steps = _tacs_sol105_static_load_design_derivative(
                results,
                dv;
                stiffness_steps=Float64[],
            )
            isempty(load_steps) &&
                error("TACS buckling inertial-preload sensitivity could not determine a load perturbation step for design variable '$dv_id'.")
            du_dx = _tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)
            dKg, h = _tacs_sol105_geometric_stiffness_design_derivative(results, dv, du_dx, maximum(Float64.(load_steps)))
            current_derivative = dot(buckling_ctx.phi, (dK + buckling_ctx.value * dKg) * buckling_ctx.phi) / buckling_ctx.denominator
            if length(cluster_modes) > 1
                cluster_values = _tacs_buckling_cluster_projected_derivatives(
                    cluster_phi,
                    dK,
                    dKg,
                    results["Kg"],
                    buckling_ctx.value;
                    route_label="SOL105 buckling clustered inertial-preload sensitivity",
                )
            end
            directional_steps[dv_id] = h
            diagnostics[dv_id] = _tacs_design_diagnostics(
                dv,
                vcat([h], Float64.(load_steps)),
                sensitivity_contract,
                backend_label,
                load_derivative=dF,
            )
        elseif design_family == :shell_thickness
            pid_list = sort!(unique(Int.(collect(get(dv, "pids", _tacs_sol101_active_shell_pids(model))))))
            isempty(pid_list) && (pid_list = _tacs_sol101_active_shell_pids(model))
            for pid in pid_list
                prop = get(get(model, "PSHELLs", Dict()), string(pid), nothing)
                prop === nothing && error("TACS buckling load-factor design gradient could not find shell property $pid.")
                _tacs_shell_supports_thickness_derivative(prop) ||
                    error("TACS buckling load-factor thickness gradient does not support property $pid TYPE=$(get(prop, "TYPE", "?")).")
                t0 = Float64(get(prop, "T", 0.0))
                t0 > 0.0 || error("TACS buckling load-factor gradient requires positive property thickness.")
            end

            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(
                model,
                dv;
                allowed_sol_types=(105,),
                route_label="SOL105 buckling grouped shell-thickness sensitivity",
            )
            dF, load_steps = _tacs_sol105_static_load_design_derivative(
                results,
                dv;
                stiffness_steps=steps,
            )
            du_dt = _tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)
            all_steps = vcat(Float64.(steps), Float64.(load_steps))
            h0 = isempty(all_steps) ? _tacs_static_load_fd_step(model, dv, Float64[]) : maximum(all_steps)
            dKg, h = _tacs_sol105_geometric_stiffness_design_derivative(results, dv, du_dt, h0)
            current_derivative = dot(buckling_ctx.phi, (dK + buckling_ctx.value * dKg) * buckling_ctx.phi) / buckling_ctx.denominator
            if length(cluster_modes) > 1
                cluster_values = _tacs_buckling_cluster_projected_derivatives(
                    cluster_phi,
                    dK,
                    dKg,
                    results["Kg"],
                    buckling_ctx.value;
                    route_label="SOL105 buckling clustered shell-thickness sensitivity",
                )
            end
            directional_steps[dv_id] = h
            diagnostics[dv_id] = _tacs_design_diagnostics(
                dv,
                vcat([h], Float64.(load_steps)),
                sensitivity_contract,
                backend_label;
                load_derivative=dF,
            )
        elseif sensitivity_contract.derivative_method == :rayleigh_design_kg_directional_fd
            dK, _, _, _, _, steps = _tacs_assemble_sol101_design_derivative(
                model,
                dv;
                allowed_sol_types=(105,),
                route_label="SOL105 buckling design sensitivity",
            )
            isempty(steps) &&
                error("TACS buckling design gradient could not determine a perturbation step for design variable '$dv_id'.")
            dF, load_steps = _tacs_sol105_static_load_design_derivative(
                results,
                dv;
                stiffness_steps=steps,
            )
            du_dx = _tacs_sol105_static_displacement_design_derivative(results, dK; dF=dF)
            all_steps = vcat(Float64.(steps), Float64.(load_steps))
            dKg, h = _tacs_sol105_geometric_stiffness_design_derivative(results, dv, du_dx, maximum(all_steps))
            current_derivative = dot(buckling_ctx.phi, (dK + buckling_ctx.value * dKg) * buckling_ctx.phi) / buckling_ctx.denominator
            if length(cluster_modes) > 1
                cluster_values = _tacs_buckling_cluster_projected_derivatives(
                    cluster_phi,
                    dK,
                    dKg,
                    results["Kg"],
                    buckling_ctx.value;
                    route_label="SOL105 buckling clustered design sensitivity",
                )
            end
            directional_steps[dv_id] = h
            diagnostics[dv_id] = _tacs_design_diagnostics(
                dv,
                vcat([h], Float64.(load_steps)),
                sensitivity_contract,
                backend_label,
                load_derivative=dF,
            )
        else
            error("TACS buckling load-factor design gradient does not yet support design family '$design_family'.")
        end
        current_derivative === nothing &&
            error("TACS buckling load-factor design gradient did not compute a derivative for design variable '$dv_id'.")
        selected_derivative =
            cluster_values === nothing ?
            Float64(current_derivative) :
            _tacs_select_cluster_derivative(cluster_values, current_derivative; policy=policy)
        gradients[dv_id] = selected_derivative
        diagnostics[dv_id]["current_mode_derivative"] = Float64(current_derivative)
        diagnostics[dv_id]["selected_eigen_derivative"] = Float64(selected_derivative)
        diagnostics[dv_id]["cluster_policy"] = string(policy)
        if cluster_values !== nothing
            cluster_gradient_eigenvalues[dv_id] = Float64.(collect(cluster_values))
            diagnostics[dv_id]["cluster_load_factor_derivatives"] = cluster_gradient_eigenvalues[dv_id]
            diagnostics[dv_id]["cluster_policy_derivative"] = Float64(selected_derivative)
        end
    end

    return Dict{String,Any}(
        "response" => "buckling_load_factor",
        "requested_mode" => Int(mode),
        "mode" => buckling_ctx.mode,
        "value" => buckling_ctx.value,
        "gradient" => gradients,
        "cluster_modes" => cluster_modes,
        "cluster_gradient_eigenvalues" => cluster_gradient_eigenvalues,
        "cluster_policy" => string(policy),
        "cluster_tolerances" => Dict{String,Float64}("rel_tol" => cluster_rel, "abs_tol" => cluster_abs),
        "cluster_detected" => length(cluster_modes) > 1,
        "mode_tracking" => tracking_diag,
        "design_variable_type" => "mixed",
        "gradient_backend" => _tacs_gradient_backend_summary(backend_labels, "tacs_formulation_rayleigh_design_tangent"),
        "response_contract" => _tacs_contract_metadata(buckling_ctx.response),
        "design_variable_diagnostics" => diagnostics,
        "directional_steps" => directional_steps,
        "eigen_derivative" =>
            length(cluster_modes) > 1 && policy != :current_mode ?
            "cluster_policy_projected_derivative" :
            "rayleigh_current_mode_total_derivative",
    )
end

function _tacs_buckling_ks_mode_list(results::AbstractDict, modes)
    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    isempty(eigenvalues) && error("TACS buckling KS gradient requires at least one SOL105 eigenvalue.")
    mode_list =
        modes === nothing ? collect(1:length(eigenvalues)) :
        modes isa Integer ? [Int(modes)] :
        Int.(collect(modes))
    isempty(mode_list) && error("TACS buckling KS gradient requires at least one selected mode.")
    mode_list = sort!(unique(mode_list))
    for mode in mode_list
        1 <= mode <= length(eigenvalues) ||
            error("TACS buckling KS gradient requested mode $mode but only $(length(eigenvalues)) modes are available.")
    end
    return mode_list
end

function _tacs_buckling_ks_value_weights(eigenvalues::AbstractVector{<:Real}, mode_list::AbstractVector{<:Integer}, rho::Real)
    rho_f = Float64(rho)
    rho_f > 0.0 || error("TACS buckling KS gradient requires positive rho; got $rho_f.")
    values = Float64[Float64(eigenvalues[mode]) for mode in mode_list]
    lambda_min = minimum(values)
    raw = exp.(-rho_f .* (values .- lambda_min))
    raw_sum = sum(raw)
    raw_sum > 0.0 || error("TACS buckling KS gradient encountered zero aggregation weights.")
    weights = raw ./ raw_sum
    ks_value = lambda_min - log(raw_sum) / rho_f
    return ks_value, values, weights
end

function buckling_load_factor_ks_design_gradient(
    ::TACSFormulationBackend,
    results::AbstractDict,
    design_variables::AbstractVector;
    modes=nothing,
    rho::Real=50.0,
    cluster_policy=:current_mode,
    cluster_rel_tol::Real=1e-8,
    cluster_abs_tol::Real=1e-10,
)
    Int(get(results, "sol_type", 0)) == 105 ||
        error("TACS buckling load-factor KS gradient requires SOL105 results.")
    model = results["model"]
    has_beams = _tacs_model_has_beam_stiffness(model)
    _tacs_validate_shell_slice(
        model;
        allowed_sol_types=(105,),
        route_label="SOL105 buckling KS design sensitivity",
        allow_rods=true,
        allow_beams=has_beams,
        require_shell=!has_beams,
    )

    eigenvalues = Float64.(get(results, "eigenvalues", Float64[]))
    mode_list = _tacs_buckling_ks_mode_list(results, modes)
    ks_value, selected_values, weights = _tacs_buckling_ks_value_weights(eigenvalues, mode_list, rho)
    policy = _tacs_cluster_policy(cluster_policy)
    cluster_rel = Float64(cluster_rel_tol)
    cluster_abs = Float64(cluster_abs_tol)
    response = _tacs_response_function(Dict{String,Any}(
        "type" => "buckling_ks_load_factor",
        "modes" => mode_list,
        "rho" => Float64(rho),
    ))

    gradients = Dict{String,Float64}()
    diagnostics = Dict{String,Any}()
    for dv in design_variables
        dv isa AbstractDict || error("TACS buckling KS design gradient entries must be dictionaries.")
        dv_id = _tacs_design_variable_id(dv)
        gradients[dv_id] = 0.0
        sensitivity_contract = _tacs_sensitivity_contract(response, dv)
        diagnostics[dv_id] = _tacs_design_diagnostics(
            dv,
            Float64[],
            sensitivity_contract,
            "tacs_formulation_buckling_ks_weighted_rayleigh",
        )
        diagnostics[dv_id]["mode_diagnostics"] = Dict{String,Any}()
    end

    mode_gradients = Dict{String,Any}()
    mode_gradient_backends = String[]
    for (idx, mode) in enumerate(mode_list)
        mode_response = buckling_load_factor_design_gradient(
            TACSFormulationBackend(),
            results,
            design_variables;
            mode=mode,
            cluster_policy=policy,
            cluster_rel_tol=cluster_rel,
            cluster_abs_tol=cluster_abs,
        )
        mode_key = string(mode)
        mode_gradients[mode_key] = deepcopy(mode_response["gradient"])
        push!(mode_gradient_backends, string(mode_response["gradient_backend"]))
        for dv in design_variables
            dv_id = _tacs_design_variable_id(dv)
            mode_gradient = Float64(mode_response["gradient"][dv_id])
            gradients[dv_id] += weights[idx] * mode_gradient
            diagnostics[dv_id]["mode_diagnostics"][mode_key] = Dict{String,Any}(
                "mode" => mode,
                "value" => Float64(mode_response["value"]),
                "weight" => weights[idx],
                "gradient" => mode_gradient,
                "gradient_backend" => string(mode_response["gradient_backend"]),
                "directional_step" => get(get(mode_response, "directional_steps", Dict{String,Any}()), dv_id, nothing),
                "cluster_policy" => get(mode_response, "cluster_policy", string(policy)),
                "cluster_detected" => Bool(get(mode_response, "cluster_detected", false)),
            )
        end
    end
    base_backend = _tacs_gradient_backend_summary(mode_gradient_backends, "tacs_formulation_rayleigh_design_tangent")

    return Dict{String,Any}(
        "response" => "buckling_ks_load_factor",
        "aggregation" => "smooth_min_load_factor",
        "value" => ks_value,
        "rho" => Float64(rho),
        "modes" => mode_list,
        "mode_values" => Dict(string(mode_list[i]) => selected_values[i] for i in eachindex(mode_list)),
        "mode_weights" => Dict(string(mode_list[i]) => weights[i] for i in eachindex(mode_list)),
        "cluster_policy" => string(policy),
        "cluster_tolerances" => Dict{String,Float64}("rel_tol" => cluster_rel, "abs_tol" => cluster_abs),
        "gradient" => gradients,
        "mode_gradients" => mode_gradients,
        "design_variable_type" => "mixed",
        "gradient_backend" => "tacs_formulation_buckling_ks_weighted_rayleigh",
        "base_gradient_backend" => base_backend,
        "response_contract" => _tacs_contract_metadata(response),
        "design_variable_diagnostics" => diagnostics,
        "eigen_derivative" => "ks_weighted_rayleigh_current_mode_total_derivative",
        "known_limitations" => ["no_exact_repeated_eigenvalue_subspace_derivative"],
    )
end
