# ModelBuilder.jl
# Functions for building the finite element model from parsed Reference cards.
# This file is included at the top level and has access to the ReferenceParser module.
#
# Contains:
#   transform_geometry!(model) - Transforms grid coordinates from local coordinate systems
#   build_model(cards, cc)     - Constructs the full model dict from parsed cards and case control

using Dates

# Both omitted and explicitly zero MAT8 transverse moduli denote zero
# transverse-shear flexibility. Test the numeric law, not the spelling of
# the input, so card and JSON builds choose the same rigid-shear limit.
@inline mat8_rigid_transverse_shear(mat) =
    iszero(get(mat, "G1Z", 0.0)) && iszero(get(mat, "G2Z", 0.0))

@inline function pcomp_whitney_shear_enabled()
    raw = lowercase(strip(get(ENV, "JFEM_PCOMP_WHITNEY_SHEAR", "true")))
    return raw in ("1", "true", "yes", "on")
end

@inline function laminate_plane_stress_qbar(E1, E2, nu12, G12, theta)
    nu21 = nu12 * E2 / max(E1, 1e-30)
    denom = 1.0 - nu12 * nu21
    Q11 = E1 / denom
    Q22 = E2 / denom
    Q12 = nu12 * E2 / denom
    Q66 = G12

    c = cos(theta)
    s = sin(theta)
    c2 = c^2
    s2 = s^2
    cs = c * s

    Qb = zeros(promote_type(typeof(E1), typeof(E2), typeof(nu12), typeof(G12), typeof(theta)), 3, 3)
    Qb[1,1] = Q11*c2^2 + 2*(Q12 + 2*Q66)*c2*s2 + Q22*s2^2
    Qb[2,2] = Q11*s2^2 + 2*(Q12 + 2*Q66)*c2*s2 + Q22*c2^2
    Qb[1,2] = (Q11 + Q22 - 4*Q66)*c2*s2 + Q12*(c2^2 + s2^2)
    Qb[2,1] = Qb[1,2]
    Qb[1,3] = (Q11 - Q12 - 2*Q66)*cs*c2 + (Q12 - Q22 + 2*Q66)*cs*s2
    Qb[3,1] = Qb[1,3]
    Qb[2,3] = (Q11 - Q12 - 2*Q66)*cs*s2 + (Q12 - Q22 + 2*Q66)*cs*c2
    Qb[3,2] = Qb[2,3]
    Qb[3,3] = (Q11 + Q22 - 2*Q12 - 2*Q66)*c2*s2 + Q66*(c2^2 + s2^2)
    return Qb
end

@inline function laminate_transverse_shear_qbar(G13, G23, theta)
    c = cos(theta)
    s = sin(theta)
    return [
        c^2 * G13 + s^2 * G23   c * s * (G13 - G23);
        c * s * (G13 - G23)     s^2 * G13 + c^2 * G23
    ]
end

function _laminate_corrected_shear(Ash, kappa_x, kappa_y)
    all(k -> isfinite(k) && k > 0, (kappa_x, kappa_y)) ||
        throw(ArgumentError("Laminate shear correction factors must be finite and positive"))
    # Apply the correction to strain and its work-conjugate stress. This
    # congruence preserves elastic energy symmetry/positive definiteness,
    # the prescribed diagonal factors, and the equal-factor scalar limit.
    coupling = sqrt(kappa_x) * sqrt(kappa_y) * (Ash[1,2] + Ash[2,1]) / 2
    return [kappa_x * Ash[1,1] coupling; coupling kappa_y * Ash[2,2]]
end

function _unused_laminate_material_id(mats, pid)
    candidate = Base.Checked.checked_add(900000, pid)
    while haskey(mats, string(candidate))
        candidate = Base.Checked.checked_add(candidate, 1)
    end
    return candidate
end

"""
Energy-equivalent PCOMP transverse shear stiffness.

For each laminate direction, integrate the layer shear-stress profile about
its directional neutral surface, using the physical cylindrical-bending
modulus Qbar[a,a]. Integrate the full inverse ply shear law and symmetrize
the laminate compliance before inversion, preserving reciprocal energy.
Three Gauss points integrate the quartic energy exactly. A homogeneous
layer reduces to (5/6)*h*Qshear.

This convention matches Reference 70.5, independently checked on symmetric
and unsymmetric laminates at two cell sizes. The later 2021.4 Reference Guide
(Transverse Shear Theory, equations 4-8--4-13) describes a different convention:
zero-Poisson bending moduli and symmetrization after the stiffness inversion.
Neither a fitted factor nor a uniform 5/6 replacement is used for a laminate.

The neutral surface makes both free-face shear tractions zero even for an
unsymmetric stack; using z=0 instead violates equilibrium when B is nonzero.
"""
function pcomp_energy_shear(ply_data::AbstractVector, total_t)
    isempty(ply_data) && throw(ArgumentError("Laminate shear needs at least one ply"))
    total_t > 0 || throw(ArgumentError("Laminate thickness must be positive"))
    all(p -> haskey(p,"Qbar") && haskey(p,"Qshear"), ply_data) ||
        throw(ArgumentError("Laminate shear requires physical ply bending and transverse shear laws"))
    T = promote_type(typeof(total_t), eltype(ply_data[1]["Qbar"]),
                     eltype(ply_data[1]["Qshear"]))
    compliance = zeros(T,2,2)
    # A local thickness origin avoids subtracting large squared offsets.
    zref = ply_data[1]["z_bot"]
    gp = (-sqrt(3.0/5.0),0.0,sqrt(3.0/5.0))
    gw = (5.0/9.0,8.0/9.0,5.0/9.0)
    for a in 1:2
        ea=zero(T); first_moment=zero(T)
        for p in ply_data
            t=p["z_top"]-p["z_bot"]; zmid=(p["z_bot"]-zref)+t/2
            ex=p["Qbar"][a,a]
            t > 0 && ex > 0 || throw(ArgumentError("Laminate shear requires positive ply thickness and directional bending modulus"))
            ea += ex*t; first_moment += ex*t*zmid
        end
        neutral=first_moment/ea
        rigidity=zero(T)
        for p in ply_data
            t=p["z_top"]-p["z_bot"]; zmid=(p["z_bot"]-zref)+t/2
            rigidity += p["Qbar"][a,a]*t*((zmid-neutral)^2+t^2/12)
        end
        tau_bottom=zero(T)
        for p in ply_data
            t=p["z_top"]-p["z_bot"]; zb=p["z_bot"]-zref
            ex=p["Qbar"][a,a]; qs=p["Qshear"]
            detq=qs[1,1]*qs[2,2]-qs[1,2]*qs[2,1]
            qs[1,1] > 0 && qs[2,2] > 0 && detq > 0 ||
                throw(ArgumentError("Laminate ply transverse shear law must be positive definite"))
            inverse_row = a==1 ? (qs[2,2]/detq,-qs[1,2]/detq) :
                                 (-qs[2,1]/detq,qs[1,1]/detq)
            energy=zero(T)
            for (x,w) in zip(gp,gw)
                dz=t*(1+x)/2
                tau=tau_bottom+ex*dz*(neutral-zb-dz/2)
                energy += w*t/2*(tau/rigidity)^2
            end
            for b in 1:2
                compliance[a,b] += energy*inverse_row[b]
            end
            tau_bottom += ex*t*(neutral-zb-t/2)
        end
    end
    reciprocal=(compliance[1,2]+compliance[2,1])/2
    detc=compliance[1,1]*compliance[2,2]-reciprocal^2
    detc > 0 || throw(ArgumentError("Laminate shear compliance is singular or indefinite"))
    c11=compliance[2,2]/detc; c22=compliance[1,1]/detc
    c12=-reciprocal/detc
    c11 > 0 && c22 > 0 && c11*c22 > c12^2 ||
        throw(ArgumentError("Energy-equivalent laminate shear stiffness is not positive definite"))
    return [c11 c12; c12 c22]
end

function _laminate_isotropic_membrane(A)
    K=Diagonal([1.0,1.0,sqrt(2.0)])*A*Diagonal([1.0,1.0,sqrt(2.0)])
    J=[.5 .5 0.;.5 .5 0.;0. 0. 0.]
    H=Matrix{Float64}(I,3,3)-J
    isotropic=sum(K.*J)*J+(sum(K.*H)/2)*H
    return norm(K-isotropic) <= 64eps(Float64)*norm(K)
end

"""Stiffest cylindrical membrane direction, with the material axis at isotropy."""
function _laminate_stiffest_axis(A;check_unique=false)
    scale=norm(A)
    scale > 0 || throw(ArgumentError("Laminate membrane stiffness must be positive"))
    _laminate_isotropic_membrane(A) && return 0.0
    # Stationarity of n_i*n_j*A_ijkl*n_k*n_l, in ascending powers of tan(theta).
    # This is Abar16(theta)=0; select the largest directional elastic work.
    p=[A[1,3],A[1,2]+2A[3,3]-A[1,1],3(A[2,3]-A[1,3]),
       A[2,2]-A[1,2]-2A[3,3],-A[2,3]]
    p[abs.(p).<=64eps(Float64)*scale].=0.0
    candidates=[0.0,pi/2]
    # Two projective charts keep roots near pi/2 well conditioned. No angular
    # sampling or rounded angle is used in this section convention.
    for reciprocal in (false,true)
        q=reciprocal ? reverse(p) : copy(p)
        while length(q)>1 && iszero(q[end]);pop!(q);end
        n=length(q)-1;n==0 && continue
        companion=zeros(n,n)
        for j in 1:n-1;companion[j+1,j]=1.0;end
        companion[:,n].=-q[1:n]/q[end]
        for root in eigvals(companion)
            abs(imag(root)) <= 128eps(Float64)*max(1.0,abs(real(root))) || continue
            angle=reciprocal ? atan(1.0,real(root)) : atan(real(root))
            push!(candidates,mod(angle,pi))
        end
    end
    work(theta)=begin c=cos(theta);s=sin(theta);v=[c*c,s*s,2c*s];dot(v,A*v) end
    values=work.(candidates)
    index=argmax(values);angle=candidates[index]
    if check_unique
        # Directions differing by pi/2 describe the same two-axis energy
        # calculation. Other tied maxima have no unique orientation tangent.
        any(i -> abs(values[i]-values[index])<=64eps(Float64)*scale &&
            abs(sin(2(candidates[i]-angle)))>sqrt(eps(Float64)),eachindex(candidates)) &&
            throw(ArgumentError("Legacy laminate shear axis has tied non-equivalent maxima; its orientation derivative is undefined"))
    end
    return angle
end

_laminate_primal(x)=x
_laminate_primal(x::ForwardDiff.Dual)=_laminate_primal(ForwardDiff.value(x))

function _laminate_isotropic_jet(A)
    _laminate_isotropic_membrane(_laminate_primal.(A)) || return false
    eltype(A) <: ForwardDiff.Dual || return true
    return _laminate_isotropic_jet(ForwardDiff.value.(A)) &&
        all(i -> _laminate_isotropic_jet(map(x -> ForwardDiff.partials(x)[i],A)),
            eachindex(ForwardDiff.partials(first(A))))
end

function _laminate_axis_stationarity(A,theta)
    c=cos(theta);s=sin(theta);cs=c*s;d=c*c-s*s
    v=[c*c,s*s,2cs];dv=[-2cs,2cs,2d];ddv=[-2d,2d,-8cs]
    return 2dot(dv,A*v),2dot(ddv,A*v)+2dot(dv,A*dv)
end

function _laminate_differentiable_axis(A)
    primal=_laminate_primal.(A)
    if _laminate_isotropic_membrane(primal)
        _laminate_isotropic_jet(A) || throw(ArgumentError("Legacy laminate shear axis derivative is undefined when an isotropic membrane tensor becomes anisotropic"))
        return zero(first(A))
    end
    angle=_laminate_stiffest_axis(primal;check_unique=true)
    _,curvature=_laminate_axis_stationarity(primal,angle)
    abs(curvature)>64eps(Float64)*norm(primal) ||
        throw(ArgumentError("Legacy laminate shear axis has a flat maximum; its orientation derivative is undefined"))
    lifted=angle+zero(first(A))
    # F(A,theta)=d(Abar11)/dtheta=0 gives dtheta=-Fx/Ftheta. Two
    # Newton lifts propagate first and nested second Dual derivatives while
    # keeping the primal root selected by the physical stiffness maximum.
    for _ in 1:2
        gradient,hessian=_laminate_axis_stationarity(A,lifted)
        lifted-=gradient/hessian
    end
    return lifted
end

"""
Legacy PCOMP section convention: apply the directional energy law in the
stiffest cylindrical membrane frame, then rotate the shear tensor back.

The maximum is defined by the physical laminate A tensor, independently of
element geometry. It is covariant away from a degeneracy. At numerical
isotropy the supplied material frame resolves the tie. This legacy choice
can be discontinuous near a direction crossing and is not a globally smooth
full-tensor homogenization law. `pcomp_energy_shear` remains the fixed-frame
energy primitive for callers that explicitly choose their frame.

Automatic differentiation includes the implicit orientation derivative at a
nondegenerate maximum, through second order. Isotropic tensors with isotropic
tangents keep the material frame. A flat maximum, a non-equivalent maximum
tie, or an anisotropic perturbation of isotropy has no unique derivative and
is rejected explicitly.
"""
function pcomp_legacy_axis_shear(ply_data::AbstractVector,total_t)
    isempty(ply_data) && throw(ArgumentError("Laminate shear needs at least one ply"))
    all(p -> haskey(p,"Qbar") && haskey(p,"Qshear"),ply_data) ||
        throw(ArgumentError("Laminate shear requires physical ply bending and transverse shear laws"))
    A=sum((p["z_top"]-p["z_bot"])*p["Qbar"] for p in ply_data)
    angle=if eltype(A) <: ForwardDiff.Dual
        _laminate_differentiable_axis(A)
    else
        _laminate_stiffest_axis(A)
    end
    # ForwardDiff.iszero tests the primal value only: a zero-valued angle
    # can still carry the orientation derivative needed by the rotations.
    !(angle isa ForwardDiff.Dual) && iszero(angle) &&
        return pcomp_energy_shear(ply_data,total_t)
    c=cos(angle);s=sin(angle);R=[c -s;s c]
    Te=[c*c s*s -c*s;s*s c*c c*s;2c*s -2c*s c*c-s*s]
    rotated=[merge(p,Dict("Qbar"=>Te'*p["Qbar"]*Te,"Qshear"=>R'*p["Qshear"]*R)) for p in ply_data]
    C=R*pcomp_energy_shear(rotated,total_t)*R'
    reciprocal=(C[1,2]+C[2,1])/2
    return [C[1,1] reciprocal;reciprocal C[2,2]]
end

function pcomp_shear_for_convention(ply_data,total_t,convention)
    convention=="legacy_stiffest_axis" && return pcomp_legacy_axis_shear(ply_data,total_t)
    convention=="material_frame" && return pcomp_energy_shear(ply_data,total_t)
    throw(ArgumentError("Unknown laminate shear convention: $convention"))
end

"""Fixed-frame diagonal correction-factor view; use the full tensor for assembly."""
function pcomp_whitney_kappa(ply_data::AbstractVector, total_t)
    isempty(ply_data) && return (5.0/6.0,5.0/6.0)
    cs=pcomp_energy_shear(ply_data,total_t)
    raw=[sum(p["Qshear"][a,a]*(p["z_top"]-p["z_bot"]) for p in ply_data) for a in 1:2]
    return (cs[1,1]/raw[1],cs[2,2]/raw[2])
end

"""
Resolve nested coordinate systems: when a CORD2R has RID != 0, its A/B/C
points are defined in the reference coordinate system RID. Transform them
to basic (global) coordinates and recompute the rotation matrix.
"""
function _coordinate_point_to_basic(cord, point)
    ctype = get(cord, "TYPE", "RECTANGULAR")
    x = Float64.(point)
    if ctype == "CYLINDRICAL"
        r, theta, z = x
        x = [r * cosd(theta), r * sind(theta), z]
    elseif ctype == "SPHERICAL"
        # Reference theta is measured from +Z; phi is the azimuth from +X.
        r, theta, phi = x
        x = [r * sind(theta) * cosd(phi), r * sind(theta) * sind(phi), r * cosd(theta)]
    elseif ctype != "RECTANGULAR"
        throw(ArgumentError("Unknown coordinate system type: $ctype"))
    end
    return cord["Origin"] + cord["U"] * x[1] + cord["V"] * x[2] + cord["W"] * x[3]
end

function resolve_nested_coords!(model)
    cords = model["CORDs"]
    resolved = Set{String}()
    active = Set{String}()

    function grid_point(gid)
        grids = model["GRIDs"]
        key = string(gid)
        haskey(grids, key) || throw(ArgumentError("Coordinate system references missing GRID $gid"))
        grid = grids[key]
        point = get(grid, "X_INPUT", grid["X"])
        cp = get(grid, "CP", 0)
        cp == 0 && return Float64.(point)
        resolve!(string(cp))
        return _coordinate_point_to_basic(cords[string(cp)], point)
    end

    function resolve!(cid_str)
        if cid_str in resolved; return; end
        haskey(cords, cid_str) || throw(ArgumentError("Missing coordinate system $cid_str"))
        cid_str in active && throw(ArgumentError("Cyclic coordinate/GRID dependency involving coordinate system $cid_str"))
        push!(active, cid_str)
        cord = cords[cid_str]
        if haskey(cord, "G1")
            A, B, C = (grid_point(cord[k]) for k in ("G1", "G2", "G3"))
        elseif haskey(cord, "A_raw")
            A, B, C = cord["A_raw"], cord["B_raw"], cord["C_raw"]
            rid = get(cord, "RID", 0)
            if rid != 0
                resolve!(string(rid))
                parent = cords[string(rid)]
                A = _coordinate_point_to_basic(parent, A)
                B = _coordinate_point_to_basic(parent, B)
                C = _coordinate_point_to_basic(parent, C)
            end
        else
            # Programmatic models may supply an already-resolved basic frame.
            get(cord, "RID", 0) == 0 || throw(ArgumentError("Coordinate system $cid_str lacks raw defining points for its RID"))
            A = cord["Origin"]; B = A + cord["W"]; C = A + cord["U"]
        end
        A, u, v, w = ReferenceParser._coordinate_frame(A, B, C, cid_str)
        cord["Origin"] = A
        cord["U"] = u; cord["V"] = v; cord["W"] = w
        delete!(active, cid_str)
        push!(resolved, cid_str)
    end

    for cid_str in keys(cords)
        resolve!(cid_str)
    end
end

function transform_geometry!(model)
    grids = model["GRIDs"]
    cords = model["CORDs"]

    for (sid, g) in grids
        if g["CP"] != 0
            haskey(cords, string(g["CP"])) || throw(ArgumentError("GRID $sid references missing CP $(g["CP"])"))
            c = cords[string(g["CP"])]
            # Retain input coordinates for repeatable transforms and CORD1 GRID references.
            point = get!(g, "X_INPUT") do; copy(g["X"]); end
            g["X"] = _coordinate_point_to_basic(c, point)
        end
    end
end

@inline function _sorted_numeric_dict_values(d::AbstractDict)
    return [d[k] for k in sort!(collect(keys(d)), by=_numericish_key)]
end

@inline function _numericish_key(x)
    sx = string(x)
    parsed = tryparse(Int, sx)
    parsed !== nothing && return parsed
    m = match(r"^-?\d+", sx)
    m !== nothing && return parse(Int, m.match)
    return typemax(Int)
end

function _merge_entity_groups_preserve_ids(groups::AbstractDict...)
    merged = Dict{String,Any}()
    seen_counts = Dict{Int,Int}()

    for group in groups
        for key in sort!(collect(keys(group)), by=_numericish_key)
            entry = group[key]
            original_id = if entry isa AbstractDict && haskey(entry, "ID")
                Int(entry["ID"])
            else
                _numericish_key(key)
            end

            next_count = get(seen_counts, original_id, 0) + 1
            seen_counts[original_id] = next_count

            merged_key = next_count == 1 ? string(original_id) : "$(original_id)__dup$(next_count)"
            while haskey(merged, merged_key)
                next_count += 1
                seen_counts[original_id] = next_count
                merged_key = "$(original_id)__dup$(next_count)"
            end

            merged[merged_key] = entry
        end
    end
    return merged
end

@inline function _sol200_lite_relation_family(relation_kind::Symbol, entity_type_raw, field_raw)
    entity_type = uppercase(strip(string(entity_type_raw)))
    field = uppercase(strip(string(field_raw)))

    if relation_kind == :property
        if entity_type == "PCOMP" && occursin(r"^T[0-9]+$", field)
            return "pcomp_ply_thickness"
        elseif entity_type == "PCOMP" && occursin(r"^THETA[0-9]+$", field)
            return "pcomp_ply_angle"
        elseif entity_type in ("PSHELL", "PCOMP") && field == "T"
            return "shell_thickness"
        elseif entity_type in ("PBAR", "PBARL", "PBEAM", "PBEAML", "PROD") && field == "A"
            return "bar_area"
        end
    elseif relation_kind == :material
        if entity_type == "MAT1" && field == "E"
            return "material_E"
        elseif entity_type == "MAT1" && field == "G"
            return "material_G"
        elseif entity_type == "MAT1" && field == "NU"
            return "material_NU"
        elseif entity_type == "MAT1" && field == "RHO"
            return "material_RHO"
        elseif entity_type == "MAT8" && field == "E1"
            return "material_E1"
        elseif entity_type == "MAT8" && field == "E2"
            return "material_E2"
        elseif entity_type == "MAT8" && field == "G12"
            return "material_G12"
        elseif entity_type == "MAT8" && field == "NU12"
            return "material_NU12"
        elseif entity_type == "MAT8" && field == "RHO"
            return "material_RHO"
        end
    end

    return nothing
end

@inline function _sol200_lite_pcomp_ply_index(field_raw)
    field = uppercase(strip(string(field_raw)))
    m = match(r"^(?:T|THETA)([0-9]+)$", field)
    isnothing(m) && return nothing
    ply_index = tryparse(Int, m.captures[1])
    isnothing(ply_index) || ply_index <= 0 ? nothing : ply_index
end

@inline function _sol200_lite_response_family(rtype_raw)
    rtype = uppercase(strip(string(rtype_raw)))
    if rtype in ("WEIGHT", "MASS")
        return "mass"
    elseif rtype in ("COMP", "COMPLIANCE")
        return "compliance"
    elseif rtype == "DISP"
        return "displacement"
    elseif rtype in ("KSDISP", "KSDISPLACEMENT")
        return "ks_displacement"
    elseif rtype in ("STRESS", "VMSTRS")
        return "von_mises"
    elseif rtype in ("FORCE", "FRFORC")
        return "force"
    elseif rtype in ("MOMENT", "FRMOM")
        return "moment"
    elseif rtype in ("LAMA", "BUCK")
        return "buckling_eigenvalue"
    end
    return nothing
end

function _build_optimization_definition(model::Dict, cc::Dict{String, Any})
    raw_desvars = get(model, "DESVARs", Dict{String, Any}())
    raw_dresps = get(model, "DRESP1s", Dict{String, Any}())
    raw_dconstrs = get(model, "DCONSTRs", Dict{String, Any}())
    raw_dvprels = get(model, "DVPREL1s", Dict{String, Any}())
    raw_dvmrels = get(model, "DVMREL1s", Dict{String, Any}())
    raw_doptprms = get(model, "DOPTPRMs", Dict{String, Any}())

    has_opt_content =
        get(model, "SOL", get(cc, "SOL", 101)) == 200 ||
        !isempty(raw_desvars) || !isempty(raw_dresps) || !isempty(raw_dconstrs) ||
        !isempty(raw_dvprels) || !isempty(raw_dvmrels) || !isempty(raw_doptprms) ||
        haskey(cc, "DESOBJ") || haskey(cc, "DESSUB")

    has_opt_content || return nothing

    design_variables = Dict{String, Any}[]
    for desvar in _sorted_numeric_dict_values(raw_desvars)
        push!(design_variables, Dict(
            "id" => desvar["ID"],
            "label" => get(desvar, "LABEL", ""),
            "x_init" => get(desvar, "XINIT", 0.0),
            "lower_bound" => get(desvar, "XLB", nothing),
            "upper_bound" => get(desvar, "XUB", nothing),
            "move_limit" => get(desvar, "DELX", nothing),
            "discrete_set_id" => get(desvar, "DDVAL", nothing),
        ))
    end

    property_relations = Dict{String, Any}[]
    for relation in _sorted_numeric_dict_values(raw_dvprels)
        push!(property_relations, Dict(
            "id" => relation["ID"],
            "relation_kind" => "property",
            "card_type" => relation["TYPE"],
            "property_id" => relation["PID"],
            "field" => get(relation, "PNAME_FID", nothing),
            "lower_bound" => get(relation, "LOWER_BOUND", nothing),
            "upper_bound" => get(relation, "UPPER_BOUND", nothing),
            "offset" => get(relation, "C0", 0.0),
            "coefficients" => deepcopy(get(relation, "COEFFICIENTS", Any[])),
            "candidate_design_variable_family" => _sol200_lite_relation_family(:property, relation["TYPE"], get(relation, "PNAME_FID", "")),
            "ply_index" => _sol200_lite_pcomp_ply_index(get(relation, "PNAME_FID", "")),
        ))
    end

    material_relations = Dict{String, Any}[]
    for relation in _sorted_numeric_dict_values(raw_dvmrels)
        push!(material_relations, Dict(
            "id" => relation["ID"],
            "relation_kind" => "material",
            "card_type" => relation["TYPE"],
            "material_id" => relation["MID"],
            "field" => get(relation, "PNAME_FID", nothing),
            "lower_bound" => get(relation, "LOWER_BOUND", nothing),
            "upper_bound" => get(relation, "UPPER_BOUND", nothing),
            "offset" => get(relation, "C0", 0.0),
            "coefficients" => deepcopy(get(relation, "COEFFICIENTS", Any[])),
            "candidate_design_variable_family" => _sol200_lite_relation_family(:material, relation["TYPE"], get(relation, "PNAME_FID", "")),
        ))
    end

    responses = Dict{String, Any}[]
    for response in _sorted_numeric_dict_values(raw_dresps)
        push!(responses, Dict(
            "id" => response["ID"],
            "label" => get(response, "LABEL", ""),
            "response_type" => get(response, "RTYPE", ""),
            "property_type" => get(response, "PTYPE", nothing),
            "region" => get(response, "REGION", nothing),
            "atta" => get(response, "ATTA", nothing),
            "attb" => get(response, "ATTB", nothing),
            "atti" => deepcopy(get(response, "ATTI", Any[])),
            "candidate_response_family" => _sol200_lite_response_family(get(response, "RTYPE", "")),
        ))
    end

    constraints = Dict{String, Any}[]
    for constraint in _sorted_numeric_dict_values(raw_dconstrs)
        push!(constraints, Dict(
            "id" => constraint["ID"],
            "response_id" => constraint["RID"],
            "lower_allowable" => get(constraint, "LOWER_ALLOWABLE", nothing),
            "upper_allowable" => get(constraint, "UPPER_ALLOWABLE", nothing),
            "low_frequency" => get(constraint, "LOWFQ", nothing),
            "high_frequency" => get(constraint, "HIGHFQ", nothing),
        ))
    end

    objective = nothing
    if haskey(cc, "DESOBJ")
        objective = Dict(
            "response_id" => cc["DESOBJ"],
            "sense" => uppercase(string(get(cc, "DESOBJ_MODIFIER", "MIN"))),
        )
    end

    subcase_design_selectors = Dict{String, Any}[]
    for sid in sort!(collect(keys(get(cc, "SUBCASES", Dict{Int, Dict{String, Any}}()))))
        sub = cc["SUBCASES"][sid]
        if haskey(sub, "DESSUB")
            push!(subcase_design_selectors, Dict(
                "sid" => sid,
                "dessub" => sub["DESSUB"],
            ))
        end
    end

    unsupported_relations = Any[]
    for relation in vcat(property_relations, material_relations)
        isnothing(relation["candidate_design_variable_family"]) && push!(unsupported_relations, relation["id"])
    end

    unsupported_responses = Any[]
    for response in responses
        isnothing(response["candidate_response_family"]) && push!(unsupported_responses, response["id"])
    end

    parser_supported = isempty(unsupported_relations) && isempty(unsupported_responses)
    parsed_but_unexecuted_material_relations = Any[
        relation["id"] for relation in material_relations
        if !isnothing(relation["candidate_design_variable_family"])
        && !(relation["candidate_design_variable_family"] in ("material_E", "material_G", "material_NU", "material_E1", "material_E2", "material_G12", "material_NU12", "material_RHO"))
    ]
    parsed_but_unexecuted_responses = Any[
        response["id"] for response in responses
        if !isnothing(response["candidate_response_family"]) &&
           !(response["candidate_response_family"] in ("mass", "compliance", "displacement", "ks_displacement", "buckling_eigenvalue", "von_mises"))
    ]

    readiness = Dict(
        "supported" => parser_supported,
        "parser_supported" => parser_supported,
        "execution_supported" => parser_supported &&
            isempty(parsed_but_unexecuted_material_relations) &&
            isempty(parsed_but_unexecuted_responses),
        "unsupported_relation_ids" => unsupported_relations,
        "unsupported_response_ids" => unsupported_responses,
        "parsed_but_unexecuted_material_relation_ids" => parsed_but_unexecuted_material_relations,
        "parsed_but_unexecuted_response_ids" => parsed_but_unexecuted_responses,
        "supported_execution_relation_families" => ["shell_thickness", "bar_area", "pcomp_ply_thickness", "pcomp_ply_angle", "material_E", "material_G", "material_NU", "material_E1", "material_E2", "material_G12", "material_NU12", "material_RHO"],
        "supported_execution_response_families" => ["mass", "compliance", "displacement", "ks_displacement", "buckling_eigenvalue", "von_mises"],
        "execution_scope_note" =>
            "This readiness check is family-level only. Objective sense, constraint structure, and route-specific translation rules are still enforced during SOL 200-lite dispatch.",
    )

    return Dict(
        "sol_type" => 200,
        "objective" => objective,
        "global_design_subcase_selector" => get(cc, "DESSUB", nothing),
        "subcase_design_selectors" => subcase_design_selectors,
        "design_variables" => design_variables,
        "property_relations" => property_relations,
        "material_relations" => material_relations,
        "responses" => responses,
        "constraints" => constraints,
        "optimizer_params" => deepcopy(raw_doptprms),
        "sol200_lite_readiness" => readiness,
    )
end

function build_model(cards, cc)
    println("[" * Dates.format(Dates.now(), "HH:MM:SS") * "] Constructing Model Data...")

    # Parse PBARL and PBAR, then merge into unified PBARLs dict
    pbarls = haskey(cards,"PBARL") ? ReferenceParser.extract_pbarl(cards["PBARL"]) : Dict()
    pbars  = haskey(cards,"PBAR")  ? ReferenceParser.extract_pbar(cards["PBAR"])   : Dict()
    # Also handle PBAR* (long-field PBAR) - process_cards stores these under "PBAR*"
    if haskey(cards, "PBAR*")
        pbars_long = ReferenceParser.extract_pbar(cards["PBAR*"])
        merge!(pbars, pbars_long)
    end
    # Merge PBAR into PBARLs (PBAR takes precedence if same PID)
    merged_bars = merge(pbarls, pbars)

    # Parse PBEAM/PBEAML and merge into unified bar properties
    pbeams = haskey(cards,"PBEAM") ? ReferenceParser.extract_pbeam(cards["PBEAM"]) : Dict()
    if haskey(cards, "PBEAM*")
        merge!(pbeams, ReferenceParser.extract_pbeam(cards["PBEAM*"]))
    end
    merge!(merged_bars, pbeams)
    pbeamls = haskey(cards,"PBEAML") ? ReferenceParser.extract_pbeaml(cards["PBEAML"]) : Dict()
    merge!(merged_bars, pbeamls)

    # Parse PLOAD2 and merge with PLOAD4
    pload4s = haskey(cards,"PLOAD4") ? ReferenceParser.extract_pload4(cards["PLOAD4"]) : []
    if haskey(cards, "PLOAD2")
        pload2s = ReferenceParser.extract_pload2(cards["PLOAD2"])
        append!(pload4s, pload2s)
    end

    # Parse SPC (non-SPC1) and merge with SPC1
    spc1s = haskey(cards,"SPC1") ? ReferenceParser.extract_spc1(cards["SPC1"]) : []
    if haskey(cards, "SPC")
        spcs = ReferenceParser.extract_spc(cards["SPC"])
        append!(spc1s, spcs)
    end

    # Parse PROD properties
    prods = haskey(cards,"PROD") ? ReferenceParser.extract_prod(cards["PROD"]) : Dict()

    # Parse MAT8, MAT2 and merge with MAT1
    mats = haskey(cards,"MAT1") ? ReferenceParser.extract_mats(cards["MAT1"]) : Dict()
    if haskey(cards, "MAT8")
        mat8s = ReferenceParser.extract_mat8(cards["MAT8"])
        merge!(mats, mat8s)
    end
    if haskey(cards, "MAT2")
        mat2s = ReferenceParser.extract_mat2(cards["MAT2"])
        merge!(mats, mat2s)
    end

    # Parse PELAS properties
    pelases = haskey(cards,"PELAS") ? ReferenceParser.extract_pelas(cards["PELAS"]) : Dict()

    # Parse PCOMP and merge with PSHELL
    # PCOMP uses proper CLT (Classical Laminate Theory) to compute full ABD matrices
    pshells = haskey(cards,"PSHELL") ? ReferenceParser.extract_props_shell(cards["PSHELL"]) : Dict()
    if haskey(cards, "PCOMP")
        pcomps = ReferenceParser.extract_pcomp(cards["PCOMP"])
        for (pid, pc) in pcomps
            if isempty(pc["PLIES"]); continue; end
            total_t = pc["T"]
            if total_t <= 0; continue; end

            # CLT: compute full ABD matrices with z-coordinates
            A = zeros(3, 3)  # membrane stiffness
            B = zeros(3, 3)  # membrane-bending coupling
            D = zeros(3, 3)  # bending stiffness
            z0 = get(pc, "Z0", -total_t / 2.0)  # bottom of laminate
            z_bot = z0
            G12_ref = 0.0  # in-plane shear reference
            Ash = zeros(2, 2)  # transverse shear stiffness before shear correction
            E_max = 0.0  # for drill stiffness reference

            ply_data = []  # store per-ply Qbar and z for stress recovery
            all_plies_isotropic = true
            saw_mat8_ply = false
            all_mat8_plies_rigid_transverse_shear = true
            for ply in pc["PLIES"]
                pmid = string(ply["MID"])
                haskey(mats, pmid) || throw(ArgumentError("PCOMP $pid references missing ply material $pmid"))
                pm = mats[pmid]
                t = ply["T"]; theta = deg2rad(ply["THETA"])
                z_top = z_bot + t

                local G13::Float64, G23::Float64
                if haskey(pm, "E1")  # MAT8
                    all_plies_isotropic = false
                    saw_mat8_ply = true
                    all_mat8_plies_rigid_transverse_shear &= mat8_rigid_transverse_shear(pm)
                    E1 = pm["E1"]; E2 = pm["E2"]; nu12 = pm["NU12"]; G12 = pm["G12"]
                    G13 = Float64(get(pm, "G1Z", 0.0))
                    G23 = Float64(get(pm, "G2Z", 0.0))
                    G13 <= 0.0 && (G13 = G12)
                    G23 <= 0.0 && (G23 = G12)
                else  # MAT1 (isotropic)
                    all_mat8_plies_rigid_transverse_shear = false
                    E1 = pm["E"]; E2 = pm["E"]; nu12 = pm["NU"]; G12 = pm["G"]
                    G13 = G12
                    G23 = G12
                end
                if G12 > G12_ref; G12_ref = G12; end
                if max(E1, E2) > E_max; E_max = max(E1, E2); end

                Qb = laminate_plane_stress_qbar(E1, E2, nu12, G12, theta)
                Qs = laminate_transverse_shear_qbar(G13, G23, theta)

                # CLT integration: A += Qb*(z_top-z_bot), B += Qb*(z_top^2-z_bot^2)/2, D += Qb*(z_top^3-z_bot^3)/3
                A .+= Qb .* (z_top - z_bot)
                B .+= Qb .* (z_top^2 - z_bot^2) / 2.0
                D .+= Qb .* (z_top^3 - z_bot^3) / 3.0
                Ash .+= Qs .* (z_top - z_bot)

                # Store ply data for stress recovery
                push!(ply_data, Dict{String,Any}("Qbar"=>copy(Qb), "z_bot"=>z_bot, "z_top"=>z_top,
                                     "Qshear"=>copy(Qs), "theta"=>ply["THETA"], "mid"=>Int(ply["MID"]),
                                     "sout"=>get(ply, "SOUT", "")))

                z_bot = z_top
            end

            # First-order shear deformation laminate shear stiffness: ply-wise transformed
            # transverse shear integrated through the thickness, then corrected.
            #
            # Two options for the correction:
            #
            # 1. JFEM_PCOMP_WHITNEY_SHEAR=true — energy-equivalent full shear law
            #    from directional neutral surfaces and inverse ply shear
            #    stiffness. A homogeneous layer reduces to 5/6.
            #
            # 2. JFEM_PCOMP_WHITNEY_SHEAR=false — use 5/6 (Reissner).
            ts_t_default = 5.0/6.0
            whitney_on = pcomp_whitney_shear_enabled()
            if whitney_on && length(ply_data) > 0
                Cs_lam = pcomp_legacy_axis_shear(ply_data, total_t)
            else
                Cs_lam = ts_t_default .* Ash
            end


            # Derive equivalent E and nu for stress recovery and drill stiffness
            nu_eq = A[1,1] > 0 ? clamp(A[1,2] / A[1,1], 0.0, 0.49) : 0.3
            E_eq = A[1,1] * (1 - nu_eq^2) / total_t
            G_eq = total_t > 0 ? 0.5 * (Ash[1,1] + Ash[2,2]) / total_t : G12_ref

            # Compute effective density for gravity: sum(rho_ply * t_ply) / total_t
            rho_eff = 0.0
            for ply in pc["PLIES"]
                pmid = string(ply["MID"])
                if haskey(mats, pmid)
                    rho_eff += get(mats[pmid], "RHO", 0.0) * ply["T"]
                end
            end
            if total_t > 0; rho_eff /= total_t; end

            pid_int = pc["PID"]
            synth_mid = _unused_laminate_material_id(mats, pid_int)
            mats[string(synth_mid)] = Dict{String,Any}("MID"=>synth_mid, "E"=>E_eq, "G"=>G_eq, "NU"=>nu_eq, "RHO"=>rho_eff, "TYPE"=>"MAT1_EQUIV")
            # Check if B is effectively zero (symmetric laminate)
            B_max = maximum(abs.(B))
            Bmb = B_max > 1e-10 * maximum(abs.(A)) ? B : nothing

            pshells[pid] = Dict{String,Any}("PID"=>pid_int, "MID"=>synth_mid, "T"=>total_t,
                                "TYPE"=>"PCOMP_CLT",
                                "Cm" => A, "Bmb" => Bmb, "Cb" => D, "Cs" => Cs_lam, "Cs_raw" => copy(Ash), "E_ref" => E_max,
                                "T_REF" => total_t, "Cm_ref" => copy(A), "Bmb_ref" => Bmb === nothing ? nothing : copy(Bmb),
                                "Cb_ref" => copy(D), "Cs_ref" => copy(Cs_lam),
                                "IS_ISOTROPIC" => all_plies_isotropic,
                                "TRANSVERSE_SHEAR_RIGID_LIMIT" => saw_mat8_ply && all_mat8_plies_rigid_transverse_shear,
                                "PLY_DATA" => ply_data,
                                "PCOMP_Z0_DEFAULT"=>get(pc, "Z0_DEFAULT", false), "PCOMP_Z0"=>z0,
                                "PCOMP_LAM"=>get(pc, "LAM", ""), "PCOMP_WHITNEY_SHEAR"=>whitney_on,
                                "PCOMP_SHEAR_CONVENTION"=>"legacy_stiffest_axis",
                                "NSM"=>Float64(get(pc,"NSM",0.0)))
        end
    end

    # Parse PSHEAR and create shear-only shell properties
    if haskey(cards, "PSHEAR")
        pshear_raw = ReferenceParser.extract_pshear(cards["PSHEAR"])
        for (pid, ps) in pshear_raw
            mid = string(ps["MID"])
            if !haskey(mats, mid); continue; end
            mat = mats[mid]
            t = ps["T"]
            G_val = get(mat, "G", 0.0)
            if G_val <= 0 && haskey(mat, "E") && haskey(mat, "NU")
                G_val = mat["E"] / (2.0 * (1.0 + mat["NU"]))
            end
            # Shear-only membrane: only γ_xy component
            Cm_shear = t .* [0.0 0.0 0.0; 0.0 0.0 0.0; 0.0 0.0 G_val]
            Cb_shear = zeros(3, 3)
            Cs_shear = zeros(2, 2)
            pshells[pid] = Dict("PID"=>ps["PID"], "MID"=>ps["MID"], "T"=>t,
                                "TYPE"=>"PCOMP_CLT",
                                "Cm"=>Cm_shear, "Bmb"=>nothing, "Cb"=>Cb_shear, "Cs"=>Cs_shear,
                                "E_ref"=>G_val,
                                "T_REF"=>t, "Cm_ref"=>copy(Cm_shear), "Bmb_ref"=>nothing,
                                "Cb_ref"=>copy(Cb_shear), "Cs_ref"=>copy(Cs_shear))
        end
    end

    # Parse RBAR and convert to RBE2-equivalent constraints
    rbars = haskey(cards,"RBAR") ? ReferenceParser.extract_rbar(cards["RBAR"]) : Dict()
    rbe2s_base = haskey(cards,"RBE2") ? ReferenceParser.extract_rbe2(cards["RBE2"]) : Dict()
    for (rid, rbar) in rbars
        # Determine master/slave: node with independent DOFs (CN) is master
        cna = rbar["CNA"]; cnb = rbar["CNB"]
        if cnb > 0 && cna == 0
            # GB is master (has independent DOFs), GA is slave
            master = rbar["GB"]; slave = rbar["GA"]; cm = cnb
        elseif cna > 0 && cnb == 0
            # GA is master, GB is slave
            master = rbar["GA"]; slave = rbar["GB"]; cm = cna
        else
            # Both have independent DOFs or both blank — default: GA master with 123456
            master = rbar["GA"]; slave = rbar["GB"]; cm = 123456
        end
        rbe2s_base[rid] = Dict("ID"=>rbar["ID"], "GN"=>master, "CM"=>cm, "GM"=>[slave])
    end

    grdset = haskey(cards, "GRDSET") ? ReferenceParser.extract_grdset(cards["GRDSET"]) : Dict{String,Any}()

    # Entity dictionaries intentionally mix IDs, vectors, matrices and strings.
    # An explicit value type avoids repeated widening/copying while Julia's
    # generic Dict constructor discovers those heterogeneous values.
    model = Dict{String,Any}(
        "CASE_CONTROL" => cc,
        "GRIDs"       => haskey(cards,"GRID")   ? ReferenceParser.extract_grid(cards["GRID"]; grdset=grdset) : Dict(),
        "SNORMs"      => haskey(cards,"SNORM") ? ReferenceParser.extract_snorm(cards["SNORM"]) : Dict{String,Any}(),
        "CORDs"       => merge(haskey(cards,"CORD2R") ? ReferenceParser.extract_coords(cards["CORD2R"]; coord_type="RECTANGULAR") : Dict(),
                               haskey(cards,"CORD1R") ? ReferenceParser.extract_coords1(cards["CORD1R"]; coord_type="RECTANGULAR") : Dict(),
                               haskey(cards,"CORD1C") ? ReferenceParser.extract_coords1(cards["CORD1C"]; coord_type="CYLINDRICAL") : Dict(),
                               haskey(cards,"CORD1S") ? ReferenceParser.extract_coords1(cards["CORD1S"]; coord_type="SPHERICAL") : Dict(),
                               haskey(cards,"CORD2C") ? ReferenceParser.extract_coords(cards["CORD2C"]; coord_type="CYLINDRICAL") : Dict(),
                               haskey(cards,"CORD2S") ? ReferenceParser.extract_coords(cards["CORD2S"]; coord_type="SPHERICAL") : Dict()),
        "CSHELLs"     => _merge_entity_groups_preserve_ids(
                               haskey(cards,"CTRIA3") ? ReferenceParser.extract_shells(cards["CTRIA3"]) : Dict(),
                               haskey(cards,"CTRIA6") ? ReferenceParser.extract_shells(cards["CTRIA6"]) : Dict(),
                               haskey(cards,"CQUAD4") ? ReferenceParser.extract_shells(cards["CQUAD4"]) : Dict(),
                               haskey(cards,"CQUADR") ? ReferenceParser.extract_shells(cards["CQUADR"]) : Dict(),
                               haskey(cards,"CQUAD8") ? ReferenceParser.extract_shells(cards["CQUAD8"]) : Dict(),
                               haskey(cards,"CSHEAR") ? ReferenceParser.extract_shells(cards["CSHEAR"]) : Dict()),
        "CBARs"       => haskey(cards,"CBAR")   ? ReferenceParser.extract_cbar(cards["CBAR"]) : Dict(),
        "CBEAMs"      => haskey(cards,"CBEAM")  ? ReferenceParser.extract_cbeam(cards["CBEAM"]) : Dict(),
        "CRODs"       => haskey(cards,"CROD")   ? ReferenceParser.extract_crod(cards["CROD"]) : Dict(),
        "CONRODs"     => haskey(cards,"CONROD") ? ReferenceParser.extract_conrod(cards["CONROD"]) : Dict(),
        "CELASs"      => _merge_entity_groups_preserve_ids(
                               haskey(cards,"CELAS1") ? ReferenceParser.extract_celas1(cards["CELAS1"]) : Dict(),
                               haskey(cards,"CELAS2") ? ReferenceParser.extract_celas2(cards["CELAS2"]) : Dict()),
        "PELASs"      => pelases,
        "CBUSHs"      => haskey(cards,"CBUSH") ? ReferenceParser.extract_cbush(cards["CBUSH"]) : Dict(),
        "PBUSHs"      => haskey(cards,"PBUSH") ? ReferenceParser.extract_pbush(cards["PBUSH"]) : Dict(),
        "CONM2s"      => haskey(cards,"CONM2")  ? ReferenceParser.extract_conm2(cards["CONM2"]) : Dict(),
        "CONM1s"      => haskey(cards,"CONM1")  ? ReferenceParser.extract_conm1(cards["CONM1"]) : Dict(),
        "CMASS1s"     => haskey(cards,"CMASS1") ? ReferenceParser.extract_cmass1(cards["CMASS1"]) : Dict(),
        "CMASS2s"     => haskey(cards,"CMASS2") ? ReferenceParser.extract_cmass2(cards["CMASS2"]) : Dict(),
        "PMASSs"      => haskey(cards,"PMASS")  ? ReferenceParser.extract_pmass(cards["PMASS"]) : Dict(),
        "RBE2s"       => rbe2s_base,
        "RBE1s"       => haskey(cards,"RBE1")   ? ReferenceParser.extract_rbe1(cards["RBE1"]) : Dict(),
        "RSPLINEs"    => haskey(cards,"RSPLINE") ? ReferenceParser.extract_rspline(cards["RSPLINE"]) : Dict(),
        "RBE3s"       => haskey(cards,"RBE3")   ? ReferenceParser.extract_rbe3(cards["RBE3"]) : Dict(),
        "MPCs"        => haskey(cards,"MPC")    ? ReferenceParser.extract_mpc(cards["MPC"]) : [],
        "MPCADDs"     => haskey(cards,"MPCADD") ? ReferenceParser.extract_mpcadd(cards["MPCADD"]) : Dict(),
        "PSHELLs"     => pshells,
        "PBARLs"      => merged_bars,
        "PRODs"       => prods,
        "CSOLIDs"     => _merge_entity_groups_preserve_ids(
                               haskey(cards,"CTETRA") ? ReferenceParser.extract_ctetra(cards["CTETRA"]) : Dict(),
                               haskey(cards,"CHEXA")  ? ReferenceParser.extract_chexa(cards["CHEXA"])   : Dict(),
                               haskey(cards,"CPENTA") ? ReferenceParser.extract_cpenta(cards["CPENTA"]) : Dict()),
        "PSOLIDs"     => haskey(cards,"PSOLID") ? ReferenceParser.extract_psolid(cards["PSOLID"]) : Dict(),
        "MATs"        => mats,
        "MATT1s"      => haskey(cards,"MATT1") ? ReferenceParser.extract_matt1(cards["MATT1"]) : Dict{String,Dict{String,Any}}(),
        "TABLEM1s"    => haskey(cards,"TABLEM1") ? ReferenceParser.extract_tablem1(cards["TABLEM1"]) : Dict{String,Dict{String,Any}}(),
        "FORCEs"      => haskey(cards,"FORCE")  ? ReferenceParser.extract_loads(cards["FORCE"]) : [],
        "MOMENTs"     => haskey(cards,"MOMENT") ? ReferenceParser.extract_moments(cards["MOMENT"]) : [],
        "FORCE1s" => haskey(cards,"FORCE1") ? ReferenceParser.extract_unsupported_directional_loads(cards["FORCE1"],"FORCE1") : [],
        "FORCE2s" => haskey(cards,"FORCE2") ? ReferenceParser.extract_unsupported_directional_loads(cards["FORCE2"],"FORCE2") : [],
        "MOMENT1s" => haskey(cards,"MOMENT1") ? ReferenceParser.extract_unsupported_directional_loads(cards["MOMENT1"],"MOMENT1") : [],
        "MOMENT2s" => haskey(cards,"MOMENT2") ? ReferenceParser.extract_unsupported_directional_loads(cards["MOMENT2"],"MOMENT2") : [],
        "PLOAD4s"     => pload4s,
        "PLOADs"      => haskey(cards,"PLOAD") ? ReferenceParser.extract_pload(cards["PLOAD"]) : [],
        "PLOAD1s"     => haskey(cards,"PLOAD1") ? ReferenceParser.extract_pload1(cards["PLOAD1"]) : [],
        "GRAVs"       => haskey(cards,"GRAV")   ? ReferenceParser.extract_grav(cards["GRAV"]) : [],
        "ACCEL1s"     => haskey(cards,"ACCEL1") ? ReferenceParser.extract_accel1(cards["ACCEL1"]) : [],
        "ACCELs"      => haskey(cards,"ACCEL")  ? ReferenceParser.extract_accel(cards["ACCEL"]) : [],
        "SPCDs"       => haskey(cards,"SPCD")   ? ReferenceParser.extract_spcd(cards["SPCD"]) : [],
        "RFORCEs"     => haskey(cards,"RFORCE") ? ReferenceParser.extract_rforce(cards["RFORCE"]) : [],
        "LOAD_COMBOS" => haskey(cards,"LOAD")   ? ReferenceParser.extract_load_combos(cards["LOAD"]) : [],
        "SPC1s"       => spc1s,
        "SPCADDs"     => haskey(cards,"SPCADD") ? ReferenceParser.extract_spcadd(cards["SPCADD"]) : Dict(),
        "EIGRLs"      => haskey(cards,"EIGRL")  ? ReferenceParser.extract_eigrl(cards["EIGRL"]) : Dict(),
        "NLPARMs"     => haskey(cards,"NLPARM") ? ReferenceParser.extract_nlparm(cards["NLPARM"]) : Dict(),
        "EIGBs"       => haskey(cards,"EIGB")   ? ReferenceParser.extract_eigb(cards["EIGB"]) : Dict(),
        "TEMPs"       => haskey(cards,"TEMP")   ? ReferenceParser.extract_temp(cards["TEMP"]) : Dict{Int,Dict{Int,Float64}}(),
        "TEMPDs"      => haskey(cards,"TEMPD")  ? ReferenceParser.extract_tempd(cards["TEMPD"]) : Dict{Int,Float64}(),
        "DMIGs"       => haskey(cards,"DMIG")   ? ReferenceParser.extract_dmig(cards["DMIG"]) : Dict{String,Dict{String,Any}}(),
        "DESVARs"     => haskey(cards,"DESVAR") ? ReferenceParser.extract_desvar(cards["DESVAR"]) : Dict(),
        "DRESP1s"     => haskey(cards,"DRESP1") ? ReferenceParser.extract_dresp1(cards["DRESP1"]) : Dict(),
        "DVPREL1s"    => haskey(cards,"DVPREL1") ? ReferenceParser.extract_dvprel1(cards["DVPREL1"]) : Dict(),
        "DVMREL1s"    => haskey(cards,"DVMREL1") ? ReferenceParser.extract_dvmrel1(cards["DVMREL1"]) : Dict(),
        "DCONSTRs"    => haskey(cards,"DCONSTR") ? ReferenceParser.extract_dconstr(cards["DCONSTR"]) : Dict(),
        "DOPTPRMs"    => haskey(cards,"DOPTPRM") ? ReferenceParser.extract_doptprm(cards["DOPTPRM"]) : Dict(),
    )

    # Store SOL type from case control
    model["SOL"] = get(cc, "SOL", 101)

    # Extract PARAM cards
    # Some PARAMs have string values (YES/NO/etc.) — detect and preserve them
    string_params = Set(["AUTOSPC", "PRTMAXIM", "OMID", "POSTEXT", "POST", "NOCOMPS",
                         "COUPMASS", "LGDISP", "INREL", "ALTRED", "CHECKOUT",
                         "NLMETHOD", "NLRESMODEL"])
    if haskey(cards, "PARAM")
        for c in cards["PARAM"]
            pname = uppercase(strip(string(ReferenceParser.safe_get(c, 3))))
            raw_val = strip(string(ReferenceParser.safe_get(c, 4, "")))
            if pname in string_params && !isempty(raw_val) && occursin(r"[A-Za-z]", raw_val)
                model["PARAM_$pname"] = uppercase(raw_val)
            else
                pval = ReferenceParser.parse_reference_number(ReferenceParser.safe_get(c, 4), 0.0)
                model["PARAM_$pname"] = pval
            end
        end
    end

    opt = _build_optimization_definition(model, cc)
    if !isnothing(opt)
        model["OPTIMIZATION"] = opt
    end

    return model
end

@inline function _json_int_key(value)
    return value isa Integer ? Int(value) : parse(Int, string(value))
end

function _normalize_json_int_vector_map(raw::AbstractDict)
    normalized = Dict{Int,Vector{Int}}()
    for (k, v) in raw
        normalized[_json_int_key(k)] = Int.(collect(v))
    end
    return normalized
end

function _normalize_json_temp_map(raw::AbstractDict)
    normalized = Dict{Int,Dict{Int,Float64}}()
    for (sid, values) in raw
        temp_values = Dict{Int,Float64}()
        for (gid, temp) in values
            temp_values[_json_int_key(gid)] = Float64(temp)
        end
        normalized[_json_int_key(sid)] = temp_values
    end
    return normalized
end

function _normalize_json_float_map(raw::AbstractDict)
    normalized = Dict{Int,Float64}()
    for (k, v) in raw
        normalized[_json_int_key(k)] = Float64(v)
    end
    return normalized
end

function _normalize_json_dmig_map(raw::AbstractDict)
    normalized = Dict{String,Dict{String,Any}}()
    for (name, data) in raw
        entries = Tuple{Int,Int,Int,Int,Float64}[]
        for entry in get(data, "entries", [])
            values = collect(entry)
            length(values) < 5 && continue
            push!(entries, (
                _json_int_key(values[1]),
                _json_int_key(values[2]),
                _json_int_key(values[3]),
                _json_int_key(values[4]),
                Float64(values[5]),
            ))
        end
        normalized[string(name)] = Dict{String,Any}(
            "type" => string(get(data, "type", "square")),
            "entries" => entries,
        )
    end
    return normalized
end

function _normalize_json_matt1_map(raw::AbstractDict)
    normalized = Dict{String,Dict{String,Any}}()
    for (mid, data) in raw
        entry = Dict{String,Any}("MID" => _json_int_key(get(data, "MID", mid)))
        for key in ("E_TABLE", "G_TABLE", "NU_TABLE", "RHO_TABLE", "ALPHA_TABLE")
            value = get(data, key, nothing)
            if !isnothing(value)
                tid = _json_int_key(value)
                tid > 0 && (entry[key] = tid)
            end
        end
        normalized[string(mid)] = entry
    end
    return normalized
end

function _normalize_json_tablem1_map(raw::AbstractDict)
    normalized = Dict{String,Dict{String,Any}}()
    for (tid, data) in raw
        points = Dict{String,Float64}[]
        for point in get(data, "POINTS", Any[])
            x = get(point, "X", nothing)
            y = get(point, "Y", nothing)
            if x isa Number && y isa Number
                push!(points, Dict("X" => Float64(x), "Y" => Float64(y)))
            end
        end
        sort!(points, by = p -> p["X"])
        normalized[string(tid)] = Dict{String,Any}(
            "TID" => _json_int_key(get(data, "TID", tid)),
            "POINTS" => points,
        )
    end
    return normalized
end

# ============================================================================
# Build model from raw JSON (no pre-computed derived quantities)
# ============================================================================
"""
    build_model_from_json(raw::Dict) -> Dict

Build a solver-ready model Dict from a raw JSON model (as produced by bdf_to_json.jl).
Performs all derivation that `build_model` does:
  - Complete MAT1 E/G/NU/RHO, add MAT8 compat fields, compute MAT2 equivalent
  - Compute PBARL section properties from TYPE + DIMS
  - Compute PCOMP CLT matrices, create synthetic materials
  - Convert RBAR to RBE2
  - Merge SPC into SPC1
  - Resolve coordinate systems & transform geometry
"""
function build_model_from_json(raw::AbstractDict)
    println("[" * Dates.format(Dates.now(), "HH:MM:SS") * "] Building model from raw JSON...")
    cc = Dict{String,Any}(raw["case_control"])
    params = get(raw, "parameters", Dict())
    bd = get(raw, "bulk_data", Dict())

    # Normalize SUBCASES keys from String to Int (JSON round-trip converts Int keys to String)
    if haskey(cc, "SUBCASES")
        old_subs = cc["SUBCASES"]
        new_subs = Dict{Int, Any}()
        for (k, v) in old_subs
            int_key = _json_int_key(k)
            # Also convert values within subcase to proper types
            sub_dict = Dict{String, Any}()
            for (sk, sv) in v
                sub_dict[string(sk)] = sv
            end
            new_subs[int_key] = sub_dict
        end
        cc["SUBCASES"] = new_subs
    end

    spcadds = _normalize_json_int_vector_map(get(bd, "SPCADD", Dict()))
    mpcadds = _normalize_json_int_vector_map(get(bd, "MPCADD", Dict()))
    temps = _normalize_json_temp_map(get(bd, "TEMP", Dict()))
    tempds = _normalize_json_float_map(get(bd, "TEMPD", Dict()))
    dmigs = _normalize_json_dmig_map(get(bd, "DMIG", Dict()))
    matt1s = _normalize_json_matt1_map(get(bd, "MATT1", Dict()))
    tablem1s = _normalize_json_tablem1_map(get(bd, "TABLEM1", Dict()))

    # --- Materials: complete/derive from raw ---
    mats = Dict{String,Any}()

    # MAT1: complete missing E/G/NU
    for (mid, m) in get(bd, "MAT1", Dict())
        E  = get(m, "E", nothing);  if E isa Number; E = Float64(E); end
        G  = get(m, "G", nothing);  if G isa Number; G = Float64(G); end
        nu = get(m, "NU", nothing); if nu isa Number; nu = Float64(nu); end
        if !isnothing(E) && E > 0 && !isnothing(G) && G > 0 && isnothing(nu)
            nu = E / (2*G) - 1.0
        elseif !isnothing(E) && E > 0 && !isnothing(nu) && nu >= 0 && (isnothing(G) || G <= 0)
            G = E / (2*(1+nu))
        elseif !isnothing(G) && G > 0 && !isnothing(nu) && nu >= 0 && (isnothing(E) || E <= 0)
            E = 2*G*(1+nu)
        end
        if isnothing(E) || E <= 0; E = 0.0; end
        if isnothing(G) || G <= 0; G = 0.0; end
        if isnothing(nu) || nu < 0; nu = 0.3; end
        mats[string(Int(m["MID"]))] = Dict{String,Any}(
            "MID"=>Int(m["MID"]),
            "E"=>E,
            "G"=>G,
            "NU"=>nu,
            "RHO"=>Float64(get(m, "RHO", 0.0)),
            "ALPHA"=>Float64(get(m, "ALPHA", 0.0)),
            "TREF"=>Float64(get(m, "TREF", 0.0)),
        )
    end

    # MAT8: add compatibility fields
    for (mid, m) in get(bd, "MAT8", Dict())
        mats[string(Int(m["MID"]))] = Dict{String,Any}(
            "MID"=>Int(m["MID"]), "TYPE"=>"MAT8",
            "E1"=>Float64(m["E1"]), "E2"=>Float64(m["E2"]), "NU12"=>Float64(m["NU12"]),
            "G12"=>Float64(m["G12"]),
            "G1Z"=>Float64(get(m, "G1Z", 0.0)), "G2Z"=>Float64(get(m, "G2Z", 0.0)),
            "G1Z_BLANK"=>Bool(get(m, "G1Z_BLANK", false)),
            "G2Z_BLANK"=>Bool(get(m, "G2Z_BLANK", false)),
            "RHO"=>Float64(get(m, "RHO", 0.0)),
            "A1"=>Float64(get(m, "A1", 0.0)),
            "A2"=>Float64(get(m, "A2", 0.0)),
            "TREF"=>Float64(get(m, "TREF", 0.0)),
            "XT"=>Float64(get(m, "XT", 0.0)),
            "XC"=>Float64(get(m, "XC", 0.0)),
            "YT"=>Float64(get(m, "YT", 0.0)),
            "YC"=>Float64(get(m, "YC", 0.0)),
            "S"=>Float64(get(m, "S", 0.0)),
            "GE"=>Float64(get(m, "GE", 0.0)),
            "F12"=>Float64(get(m, "F12", 0.0)),
            "STRN"=>Float64(get(m, "STRN", 0.0)),
            "E"=>Float64(m["E1"]), "G"=>Float64(m["G12"]), "NU"=>Float64(m["NU12"]),
        )
    end

    # MAT2: compute equivalent
    for (mid, m) in get(bd, "MAT2", Dict())
        G11 = Float64(m["G11"]); G12 = Float64(m["G12"]); G33 = Float64(m["G33"])
        nu_eq = G11 > 0 ? clamp(G12 / G11, 0.0, 0.49) : 0.3
        E_eq  = G11 > 0 ? G11 * (1 - nu_eq^2) : 0.0
        mats[string(Int(m["MID"]))] = Dict{String,Any}(
            "MID"=>Int(m["MID"]), "TYPE"=>"MAT2",
            "G11"=>G11, "G12"=>G12, "G13"=>Float64(m["G13"]),
            "G22"=>Float64(m["G22"]), "G23"=>Float64(m["G23"]), "G33"=>G33,
            "RHO"=>Float64(get(m, "RHO", 0.0)),
            "A1"=>Float64(get(m, "A1", 0.0)), "A2"=>Float64(get(m, "A2", 0.0)),
            "A3"=>Float64(get(m, "A3", get(m, "A12", 0.0))),
            "TREF"=>Float64(get(m, "TREF", 0.0)),
            "E"=>E_eq, "G"=>G33, "NU"=>nu_eq,
        )
    end

    # --- Properties ---
    pshells = Dict{String,Any}()

    # PSHELL: apply defaults
    for (pid, p) in get(bd, "PSHELL", Dict())
        mid2_val = get(p, "MID2", nothing)
        mid2_blank = isnothing(mid2_val) || mid2_val == 0
        pshells[pid] = Dict{String,Any}(
            "PID"=>Int(p["PID"]), "MID"=>Int(p["MID"]), "T"=>Float64(p["T"]),
            "MID2"=> mid2_blank ? 0 : Int(mid2_val),
            "MID3"=> Int(get(p, "MID3", 0)),
            "MID4"=> Int(get(p, "MID4", 0)),
            "BEND_RATIO"=> mid2_blank ? 0.0 : Float64(get(p, "BEND_RATIO", 1.0)),
            "TS_T"=> Float64(get(p, "TS_T", 5.0/6.0)),
            "NSM"=> Float64(get(p, "NSM", 0.0)),
            "Z1"=> Float64(get(p, "Z1", -0.5 * Float64(p["T"]))),
            "Z2"=> Float64(get(p, "Z2",  0.5 * Float64(p["T"]))),
            "Z1_DEFAULT"=> !haskey(p, "Z1") || get(p, "Z1_DEFAULT", false),
            "Z2_DEFAULT"=> !haskey(p, "Z2") || get(p, "Z2_DEFAULT", false),
        )
    end

    # PCOMP → CLT computation
    for (pid, pc) in get(bd, "PCOMP", Dict())
        plies_raw = pc["PLIES"]
        lam_field = get(pc, "LAM", "")
        is_sym = uppercase(string(lam_field)) == "SYM"

        # Expand SYM
        plies = copy(plies_raw)
        if is_sym && !isempty(plies)
            for i in length(plies_raw):-1:1
                push!(plies, plies_raw[i])
            end
        end

        total_t = sum(Float64(p["T"]) for p in plies; init=0.0)
        if total_t <= 0; continue; end

        z0_raw = get(pc, "Z0", nothing)
        z0_default = isnothing(z0_raw) || get(pc, "Z0_DEFAULT", false)
        z0 = z0_default ? -total_t / 2.0 : Float64(z0_raw)

        # CLT: compute ABD matrices
        A_mat = zeros(3, 3); B_mat = zeros(3, 3); D_mat = zeros(3, 3); Ash = zeros(2, 2)
        z_bot = z0
        G12_ref = 0.0; E_max = 0.0
        ply_data = []
        all_plies_isotropic = true
        saw_mat8_ply = false
        all_mat8_plies_rigid_transverse_shear = true

        for ply in plies
            pmid = string(Int(ply["MID"]))
            haskey(mats, pmid) || throw(ArgumentError("PCOMP $pid references missing ply material $pmid"))
            pm = mats[pmid]
            t = Float64(ply["T"]); theta = deg2rad(Float64(ply["THETA"]))
            z_top = z_bot + t

            local G13::Float64, G23::Float64
            if haskey(pm, "E1")  # MAT8
                all_plies_isotropic = false
                saw_mat8_ply = true
                all_mat8_plies_rigid_transverse_shear &= mat8_rigid_transverse_shear(pm)
                E1 = Float64(pm["E1"]); E2 = Float64(pm["E2"])
                nu12 = Float64(pm["NU12"]); G12 = Float64(pm["G12"])
                G13 = Float64(get(pm, "G1Z", 0.0)); G23 = Float64(get(pm, "G2Z", 0.0))
                G13 <= 0.0 && (G13 = G12); G23 <= 0.0 && (G23 = G12)
            else
                all_mat8_plies_rigid_transverse_shear = false
                E1 = Float64(pm["E"]); E2 = E1; nu12 = Float64(pm["NU"]); G12 = Float64(pm["G"])
                G13 = G12; G23 = G12
            end
            if G12 > G12_ref; G12_ref = G12; end
            if max(E1, E2) > E_max; E_max = max(E1, E2); end

            Qb = laminate_plane_stress_qbar(E1, E2, nu12, G12, theta)
            Qs = laminate_transverse_shear_qbar(G13, G23, theta)

            A_mat .+= Qb .* (z_top - z_bot)
            B_mat .+= Qb .* (z_top^2 - z_bot^2) / 2.0
            D_mat .+= Qb .* (z_top^3 - z_bot^3) / 3.0
            Ash   .+= Qs .* (z_top - z_bot)

            push!(ply_data, Dict("Qbar"=>copy(Qb), "z_bot"=>z_bot, "z_top"=>z_top,
                "Qshear"=>copy(Qs), "theta"=>Float64(ply["THETA"]), "mid"=>Int(ply["MID"]),
                "sout"=>get(ply, "SOUT", "")))
            z_bot = z_top
        end

        # First-order shear deformation laminate shear stiffness. Keep this
        # path consistent with the card-based PCOMP builder above:
        # The default integrates the full ply-stack-dependent shear compliance;
        # JFEM_PCOMP_WHITNEY_SHEAR=false restores 5/6.
        ts_t_default2 = 5.0/6.0
        whitney_on2 = pcomp_whitney_shear_enabled()
        if whitney_on2 && length(ply_data) > 0
            Cs_lam = pcomp_legacy_axis_shear(ply_data, total_t)
        else
            Cs_lam = ts_t_default2 .* Ash
        end
        nu_eq = A_mat[1,1] > 0 ? clamp(A_mat[1,2] / A_mat[1,1], 0.0, 0.49) : 0.3
        E_eq = A_mat[1,1] * (1 - nu_eq^2) / total_t
        G_eq = total_t > 0 ? 0.5 * (Ash[1,1] + Ash[2,2]) / total_t : G12_ref

        rho_eff = 0.0
        for ply in plies
            pmid = string(Int(ply["MID"]))
            if haskey(mats, pmid); rho_eff += Float64(get(mats[pmid], "RHO", 0.0)) * Float64(ply["T"]); end
        end
        if total_t > 0; rho_eff /= total_t; end

        pid_int = Int(pc["PID"])
        synth_mid = _unused_laminate_material_id(mats, pid_int)
        mats[string(synth_mid)] = Dict{String,Any}(
            "MID"=>synth_mid, "E"=>E_eq, "G"=>G_eq, "NU"=>nu_eq, "RHO"=>rho_eff, "TYPE"=>"MAT1_EQUIV")

        B_max = maximum(abs.(B_mat))
        Bmb = B_max > 1e-10 * maximum(abs.(A_mat)) ? B_mat : nothing

        pshells[pid] = Dict{String,Any}(
            "PID"=>pid_int, "MID"=>synth_mid, "T"=>total_t,
            "TYPE"=>"PCOMP_CLT",
            "Cm"=>A_mat, "Bmb"=>Bmb, "Cb"=>D_mat, "Cs"=>Cs_lam, "Cs_raw"=>copy(Ash), "E_ref"=>E_max,
            "T_REF"=>total_t, "Cm_ref"=>copy(A_mat), "Bmb_ref"=>Bmb === nothing ? nothing : copy(Bmb),
            "Cb_ref"=>copy(D_mat), "Cs_ref"=>copy(Cs_lam),
            "IS_ISOTROPIC"=>all_plies_isotropic,
            "TRANSVERSE_SHEAR_RIGID_LIMIT"=>saw_mat8_ply && all_mat8_plies_rigid_transverse_shear,
            "PLY_DATA"=>ply_data,
            "PCOMP_Z0_DEFAULT"=>z0_default, "PCOMP_Z0"=>z0,
            "PCOMP_LAM"=>lam_field, "PCOMP_WHITNEY_SHEAR"=>whitney_on2,
            "PCOMP_SHEAR_CONVENTION"=>"legacy_stiffest_axis",
            "NSM"=>Float64(get(pc,"NSM",0.0)))
    end

    # PBARL → compute section properties (delegate to existing function)
    merged_bars = Dict{String,Any}()
    for (pid, p) in get(bd, "PBAR", Dict())
        merged_bars[pid] = Dict{String,Any}(
            "PID"=>Int(p["PID"]), "MID"=>Int(p["MID"]),
            "A"=>Float64(get(p, "A", 0.0)), "I"=>Float64(get(p, "I", get(p, "I1", 0.0))),
            "I1"=>Float64(get(p, "I1", 0.0)), "I2"=>Float64(get(p, "I2", 0.0)),
            "I12"=>Float64(get(p, "I12", 0.0)), "J"=>Float64(get(p, "J", 0.0)),
            "NSM"=>Float64(get(p, "NSM", 0.0)), "TYPE"=>string(get(p, "TYPE", "PBAR")),
            "K1"=>Float64(get(p, "K1", 0.0)), "K2"=>Float64(get(p, "K2", 0.0)),
            "C1"=>Float64(get(p, "C1", 0.0)), "C2"=>Float64(get(p, "C2", 0.0)),
            "D1"=>Float64(get(p, "D1", 0.0)), "D2"=>Float64(get(p, "D2", 0.0)),
            "E1"=>Float64(get(p, "E1", 0.0)), "E2"=>Float64(get(p, "E2", 0.0)),
            "F1"=>Float64(get(p, "F1", 0.0)), "F2"=>Float64(get(p, "F2", 0.0)),
        )
    end
    # Dimension-defined sections use one computation for deck and JSON inputs.
    # In particular, retain the PBEAML neutral/shear-axis distinction.
    for family in ("PBARL", "PBEAML"), (pid,p) in get(bd,family,Dict())
        type_str=uppercase(string(get(p,"TYPE","ROD")))
        dims=Float64.(get(p,"DIMS",Float64[]))
        card=Any[family,"",Int(p["PID"]),Int(p["MID"]),get(p,"GROUP",""),type_str]
        family=="PBEAML" && append!(card,fill("",4))
        append!(card,dims); push!(card,Float64(get(p,"NSM",0.0)))
        parsed=family=="PBEAML" ? ReferenceParser.extract_pbeaml([card]) : ReferenceParser.extract_pbarl([card])
        merge!(merged_bars,parsed)
    end
    for (pid, p) in get(bd, "PBEAM", Dict())
        # Preserve station data and the neutral/shear-axis offsets in this
        # already-parsed input route, just as bdf_to_model does.
        merged_bars[pid] = merge(Dict{String,Any}(p), Dict{String,Any}(
            "PID"=>Int(p["PID"]), "MID"=>Int(p["MID"]),
            "A"=>Float64(get(p, "A", 0.0)), "I"=>Float64(get(p, "I", get(p, "I1", 0.0))),
            "I1"=>Float64(get(p, "I1", 0.0)), "I2"=>Float64(get(p, "I2", 0.0)),
            "I12"=>Float64(get(p, "I12", 0.0)), "J"=>Float64(get(p, "J", 0.0)),
            "NSM"=>Float64(get(p, "NSM", 0.0)), "TYPE"=>string(get(p, "TYPE", "PBEAM")),
            "K1"=>Float64(get(p, "K1", 0.0)), "K2"=>Float64(get(p, "K2", 0.0)),
            "C1"=>Float64(get(p, "C1", 0.0)), "C2"=>Float64(get(p, "C2", 0.0)),
            "D1"=>Float64(get(p, "D1", 0.0)), "D2"=>Float64(get(p, "D2", 0.0)),
            "E1"=>Float64(get(p, "E1", 0.0)), "E2"=>Float64(get(p, "E2", 0.0)),
            "F1"=>Float64(get(p, "F1", 0.0)), "F2"=>Float64(get(p, "F2", 0.0)),
        ))
    end

    # --- Constraints ---
    rbe2s = Dict{String,Any}()
    for (id, r) in get(bd, "RBE2", Dict())
        rbe2s[id] = r
    end
    # RBAR → RBE2
    for (id, rbar) in get(bd, "RBAR", Dict())
        cna = get(rbar, "CNA", 0); cnb = get(rbar, "CNB", 0)
        if cnb > 0 && cna == 0
            master = rbar["GB"]; slave = rbar["GA"]; cm = cnb
        elseif cna > 0 && cnb == 0
            master = rbar["GA"]; slave = rbar["GB"]; cm = cna
        else
            master = rbar["GA"]; slave = rbar["GB"]; cm = 123456
        end
        rbe2s[id] = Dict{String,Any}("ID"=>rbar["ID"], "GN"=>master, "CM"=>cm, "GM"=>[slave])
    end

    # Merge SPC + SPC1
    spc1s = Vector{Any}(collect(get(bd, "SPC1", [])))
    for s in get(bd, "SPC", [])
        push!(spc1s, s)
    end

    # PSHEAR → shell-like entry
    for (pid, ps) in get(bd, "PSHEAR", Dict())
        mid_str = string(ps["MID"])
        if !haskey(mats, mid_str); continue; end
        mat = mats[mid_str]; t = Float64(ps["T"])
        G_val = Float64(get(mat, "G", 0.0))
        if G_val <= 0 && haskey(mat, "E") && haskey(mat, "NU")
            G_val = Float64(mat["E"]) / (2.0 * (1.0 + Float64(mat["NU"])))
        end
        Cm_shear = t .* [0.0 0.0 0.0; 0.0 0.0 0.0; 0.0 0.0 G_val]
        pshells[pid] = Dict{String,Any}("PID"=>Int(ps["PID"]), "MID"=>Int(ps["MID"]), "T"=>t,
            "TYPE"=>"PCOMP_CLT", "Cm"=>Cm_shear, "Bmb"=>nothing,
            "Cb"=>zeros(3,3), "Cs"=>zeros(2,2), "E_ref"=>G_val,
            "T_REF"=>t, "Cm_ref"=>copy(Cm_shear), "Bmb_ref"=>nothing,
            "Cb_ref"=>zeros(3,3), "Cs_ref"=>zeros(2,2))
    end

    # --- Coordinate systems: compute rotation from raw A, B, C ---
    cords = Dict{String,Any}()
    for (card_name, coord_type) in (("CORD2R", "RECTANGULAR"), ("CORD2C", "CYLINDRICAL"),
                                   ("CORD2S", "SPHERICAL"), ("CORD1R", "RECTANGULAR"),
                                   ("CORD1C", "CYLINDRICAL"), ("CORD1S", "SPHERICAL"))
        for (cid, cord) in get(bd, card_name, Dict())
            if startswith(card_name, "CORD1")
                cords[cid] = Dict{String,Any}("TYPE"=>coord_type,
                    "G1"=>Int(cord["G1"]), "G2"=>Int(cord["G2"]), "G3"=>Int(cord["G3"]))
                continue
            end
            A_pt = Float64.(cord["A"]); B_pt = Float64.(cord["B"]); C_pt = Float64.(cord["C"])
            # resolve_nested_coords! below computes the basic frame after RID conversion.
            cords[cid] = Dict{String,Any}(
                "TYPE"=>coord_type,
                "RID"=>Int(get(cord, "RID", 0)),
                "A_raw"=>copy(A_pt), "B_raw"=>copy(B_pt), "C_raw"=>copy(C_pt))
        end
    end

    # --- Build model dict ---
    model = Dict{String,Any}(
        "CASE_CONTROL" => cc,
        "GRIDs"       => get(bd, "GRID", Dict()),
        "CORDs"       => cords,
        "SNORMs"      => ReferenceParser.normalize_snorm_map(get(bd,"SNORM",Dict())),
        "CSHELLs"     => _merge_entity_groups_preserve_ids(
                               get(bd, "CTRIA3", Dict()), get(bd, "CTRIA6", Dict()),
                               get(bd, "CQUAD4", Dict()), get(bd, "CQUADR", Dict()), get(bd, "CQUAD8", Dict()),
                               get(bd, "CSHEAR", Dict())),
        "CBARs"       => get(bd, "CBAR", Dict()),
        "CBEAMs"      => get(bd, "CBEAM", Dict()),
        "CRODs"       => get(bd, "CROD", Dict()),
        "CONRODs"     => get(bd, "CONROD", Dict()),
        "CELASs"      => _merge_entity_groups_preserve_ids(get(bd, "CELAS1", Dict()), get(bd, "CELAS2", Dict())),
        "PELASs"      => get(bd, "PELAS", Dict()),
        "CBUSHs"      => get(bd, "CBUSH", Dict()),
        "PBUSHs"      => get(bd, "PBUSH", Dict()),
        "CONM2s"      => get(bd, "CONM2", Dict()),
        "CONM1s"      => get(bd, "CONM1", Dict()),
        "CMASS1s"     => get(bd, "CMASS1", Dict()),
        "CMASS2s"     => get(bd, "CMASS2", Dict()),
        "PMASSs"      => get(bd, "PMASS", Dict()),
        "RBE2s"       => rbe2s,
        "RBE1s"       => get(bd, "RBE1", Dict()),
        "RSPLINEs"    => get(bd, "RSPLINE", Dict()),
        "RBE3s"       => get(bd, "RBE3", Dict()),
        "MPCs"        => get(bd, "MPC", []),
        "MPCADDs"     => mpcadds,
        "PSHELLs"     => pshells,
        "PBARLs"      => merged_bars,
        "PRODs"       => get(bd, "PROD", Dict()),
        "CSOLIDs"     => _merge_entity_groups_preserve_ids(get(bd, "CTETRA", Dict()), get(bd, "CHEXA", Dict()), get(bd, "CPENTA", Dict())),
        "PSOLIDs"     => get(bd, "PSOLID", Dict()),
        "MATs"        => mats,
        "MATT1s"      => matt1s,
        "TABLEM1s"    => tablem1s,
        "FORCEs"      => get(bd, "FORCE", []),
        "MOMENTs"     => get(bd, "MOMENT", []),
        "FORCE1s" => [ReferenceParser.normalize_unsupported_directional_load(c,"FORCE1") for c in get(bd,"FORCE1",[])],
        "FORCE2s" => [ReferenceParser.normalize_unsupported_directional_load(c,"FORCE2") for c in get(bd,"FORCE2",[])],
        "MOMENT1s" => [ReferenceParser.normalize_unsupported_directional_load(c,"MOMENT1") for c in get(bd,"MOMENT1",[])],
        "MOMENT2s" => [ReferenceParser.normalize_unsupported_directional_load(c,"MOMENT2") for c in get(bd,"MOMENT2",[])],
        "PLOAD4s"     => vcat(collect(get(bd, "PLOAD4", [])), collect(get(bd, "PLOAD2", []))),
        "PLOADs"      => get(bd, "PLOAD", []),
        "PLOAD1s"     => get(bd, "PLOAD1", []),
        "GRAVs"       => get(bd, "GRAV", []),
        "ACCEL1s"     => [ReferenceParser.normalize_accel1(c) for c in get(bd,"ACCEL1",[])],
        "ACCELs"      => [merge(Dict{String,Any}(c), Dict("TYPE"=>"ACCEL",
            "SID"=>ReferenceParser._acceleration_integer(get(c,"SID",nothing),"ACCEL SID";minimum=1)))
            for c in get(bd,"ACCEL",[])],
        "RFORCEs"     => get(bd, "RFORCE", []),
        "LOAD_COMBOS" => get(bd, "LOAD", []),
        "SPCDs"       => get(bd, "SPCD", []),
        "SPC1s"       => spc1s,
        "SPCADDs"     => spcadds,
        "EIGRLs"      => get(bd, "EIGRL", Dict()),
        "NLPARMs"     => Dict(string(k) => ReferenceParser.normalize_nlparm(v) for (k,v) in get(bd, "NLPARM", Dict())),
        "EIGBs"       => get(bd, "EIGB", Dict()),
        "TEMPs"       => temps,
        "TEMPDs"      => tempds,
        "DMIGs"       => dmigs,
        "DESVARs"     => get(bd, "DESVAR", Dict()),
        "DRESP1s"     => get(bd, "DRESP1", Dict()),
        "DVPREL1s"    => get(bd, "DVPREL1", Dict()),
        "DVMREL1s"    => get(bd, "DVMREL1", Dict()),
        "DCONSTRs"    => get(bd, "DCONSTR", Dict()),
        "DOPTPRMs"    => get(bd, "DOPTPRM", Dict()),
    )

    model["SOL"] = get(cc, "SOL", 101)
    haskey(raw,"abaqus_import") && (model["abaqus_import"]=deepcopy(raw["abaqus_import"]))

    # Add parameters
    for (k, v) in params
        model["PARAM_$k"] = v
    end

    # Resolve coordinate systems and transform geometry
    resolve_nested_coords!(model)
    transform_geometry!(model)

    opt = _build_optimization_definition(model, cc)
    if !isnothing(opt)
        model["OPTIMIZATION"] = opt
    end

    return model
end
