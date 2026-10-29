# Steady, symmetric lifting surface loads and conservative RBE3 transfer.
# VortexLattice.jl solves the mean-camber surface, not the wetted loft.

const AERO_ZERO = (0.0, 0.0, 0.0)
const AERO_CACHE_LOCK = ReentrantLock()
const AERO_CACHE = Ref{Any}(nothing) # retain at most the latest model/load set

"""Mean camber point using the selected section and the FE loft's placement."""
function camber_point(w::Wing, eta::Float64, xc::Float64)
    left,right,t=airfoil_blend(w,eta)
    zc=(1-t)*mean_camber(left,xc)+t*mean_camber(right,xc)
    return section_point(w, eta, xc, zc)
end

const VLM_MAX_STRIP_TWIST_DEG = 2.0
const VLM_MAX_PANEL_WARP_DEG = 8.0
const VLM_MAX_CONTROL_NORMAL_ERROR_DEG = 1.0
const VLM_MAX_REFINED_PANELS = 4096

"""Evaluate the real, rotated camber surface at a tensor product of stations."""
function camber_grid(w::Wing, xcs, etas)
    grid = Array{Float64}(undef, 3, length(xcs), length(etas))
    for (j, eta) in enumerate(etas), (i, xc) in enumerate(xcs)
        grid[:, i, j] .= camber_point(w, eta, xc)
    end
    return grid
end

"""Bilinear patch normal before normalization; u is chordwise, v spanwise."""
function vlm_patch_jacobian(corners, u, v)
    a, b, c, d = corners
    du = (1-v) .* (b .- a) .+ v .* (c .- d)
    dv = (1-u) .* (d .- a) .+ u .* (c .- b)
    return cross3(du, dv), norm3(du) * norm3(dv)
end

"""
Validate panel area, edge lengths, orientation and bilinear Jacobians before
normalizing any vector or entering the vortex solver. Geometry checks are
relative to local edge lengths, so tiny cosine panels are not rejected merely
because the rest of the wing is large. The warp measure is the maximum angle
between corner normals, not an angle relative to the global z axis.
"""
function validate_vlm_grid(grid)
    size(grid, 1) == 3 && size(grid, 2) >= 2 && size(grid, 3) >= 2 ||
        throw(ArgumentError("VLM grid must contain at least one four-corner panel"))
    all(isfinite, grid) || throw(ArgumentError("VLM grid contains non-finite coordinates"))
    nc, ns = size(grid, 2)-1, size(grid, 3)-1
    metrics = Matrix{NamedTuple}(undef, nc, ns)
    for j in 1:ns, i in 1:nc
        corners = (Tuple(grid[:, i, j]), Tuple(grid[:, i+1, j]),
                   Tuple(grid[:, i+1, j+1]), Tuple(grid[:, i, j+1]))
        a, b, c, d = corners
        fail(detail) = throw(ArgumentError(
            "Invalid VLM panel at chord index $i, span index $j: $detail. Check the lifting surface edges and section geometry."))
        edge_lengths = (norm3(b .- a), norm3(c .- b), norm3(d .- c), norm3(a .- d))
        scale = maximum(edge_lengths)
        scale > 0 && minimum(edge_lengths) > 1e-12 * scale || fail("collapsed edge")
        # Root-to-tip row order is required by the package's mirror convention.
        min(d[2]-a[2], c[2]-b[2]) > 0 || fail("span rows are reversed or coincident")
        na = cross3(b .- a, c .- a)
        nb = cross3(c .- a, d .- a)
        area = (norm3(na) + norm3(nb)) / 2
        normal_length = norm3(na .+ nb)
        area > 0 && normal_length > 1e-10 * (2area) || fail("zero or cancelling area")
        normal = (na .+ nb) ./ normal_length
        # Checking the four corners bounds the bilinear patch's Jacobian;
        # also inspect the center and the solver's quarter/three-quarter points.
        normals = NTuple{3,Float64}[]
        for (u, v) in ((0.,0.), (1.,0.), (1.,1.), (0.,1.), (0.5,0.5), (0.25,0.5), (0.75,0.5))
            jac, jac_scale = vlm_patch_jacobian(corners, u, v)
            jac_length = norm3(jac)
            jac_scale > 0 && jac_length > 1e-10 * jac_scale || fail("degenerate surface Jacobian")
            sum(jac .* normal) > 1e-10 * jac_scale || fail("folded or inverted surface Jacobian")
            push!(normals, jac ./ jac_length)
        end
        # This is the normal VortexLattice 0.2.3 constructs from its bound
        # segment and collocation point. Validate it before the package divides.
        left = 0.75 .* a .+ 0.25 .* b
        right = 0.75 .* d .+ 0.25 .* c
        control = 0.125 .* (a .+ d) .+ 0.375 .* (b .+ c)
        cn = cross3(control .- right, control .- left)
        norm3(cn) > 1e-10 * norm3(control .- right) * norm3(control .- left) ||
            fail("degenerate bound-vortex/control-point triangle")
        control_normal = cn ./ norm3(cn)
        sum(control_normal .* normal) > 0 || fail("reversed control-point normal")
        warp = maximum(acosd(clamp(sum(n1 .* n2), -1., 1.)) for n1 in normals, n2 in normals)
        control_error = acosd(clamp(sum(control_normal .* last(normals)), -1., 1.))
        metrics[i,j] = (; corners, area, normal, control_normal, warp_deg=warp,
                        control_normal_error_deg=control_error)
    end
    return metrics
end

"""
Build the aerodynamic mesh, retaining planform kinks and resolving geometric
twist. Requested counts are minimum resolution: strips exceeding two degrees
of twist are divided, then severely warped patches refine both directions.
All added nodes are sampled on the exact rotated camber surface. This improves
the geometric approximation; it does not extend attached-flow physics to stall.
"""
function vlm_mesh(w::Wing, nc::Int, ns::Int)
    nc >= 1 && ns >= 1 || throw(ArgumentError("VLM panel counts must be positive"))
    base_etas = with_planform_stations(w, sort!(unique(vcat(
        [sinpi(j / (2ns)) for j in 0:ns],w.airfoil_etas))))
    etas = Float64[first(base_etas)]
    for j in 1:length(base_etas)-1
        lo, hi = base_etas[j], base_etas[j+1]
        count = max(1, ceil(Int, abs(rad2deg(twist(w, hi)-twist(w, lo))) /
                                      VLM_MAX_STRIP_TWIST_DEG))
        count == 1 ? push!(etas, hi) :
            append!(etas, vcat([lo + (hi-lo) * k/count for k in 1:count-1], hi))
    end
    xcs = [(1 - cospi(i / nc)) / 2 for i in 0:nc]
    for iteration in 1:12
        (length(xcs)-1) * (length(etas)-1) <= VLM_MAX_REFINED_PANELS ||
            throw(ArgumentError("VLM geometry refinement exceeds $VLM_MAX_REFINED_PANELS panels. Reduce requested resolution or simplify closely spaced lifting surface edge points."))
        grid = camber_grid(w, xcs, etas)
        metrics = validate_vlm_grid(grid)
        warped = findall(p -> p.warp_deg > VLM_MAX_PANEL_WARP_DEG, metrics)
        inaccurate = findall(p -> p.control_normal_error_deg > VLM_MAX_CONTROL_NORMAL_ERROR_DEG, metrics)
        if isempty(warped) && isempty(inaccurate)
            return (; grid, metrics, xcs, etas,
                initial_span_panels=length(base_etas)-1,
                max_strip_twist_deg=maximum(abs(rad2deg(twist(w, etas[j+1])-twist(w, etas[j])))
                                            for j in 1:length(etas)-1))
        end
        # The package takes its control normal from the quarter-chord bound
        # segment. On a warped surface this differs from the bilinear normal
        # at the three-quarter-chord control point. Resolve that discrepancy
        # in chord; span-only refinement cannot remove it. This keeps the
        # established package solver and force directions, with a bounded
        # geometric normal error instead of silently flattening the surface.
        chord_refine = union(warped, inaccurate)
        xcs = sort!(unique(vcat(xcs, [(xcs[I[1]]+xcs[I[1]+1])/2 for I in chord_refine])))
        etas = sort!(unique(vcat(etas, [(etas[I[2]]+etas[I[2]+1])/2 for I in warped])))
    end
    throw(ArgumentError("VLM camber panels remain excessively warped after refinement; check the section and edge geometry"))
end

"""Independent aerodynamic grid (3 x chord points x span points)."""
vlm_grid(w::Wing, nc::Int, ns::Int) = vlm_mesh(w, nc, ns).grid

function vlm_incidence_warnings(w::Wing, p::AbstractDict)
    alpha = Float64(p["aero.alpha"])
    root = alpha + rad2deg(twist(w,0.0))
    tip = alpha + rad2deg(twist(w,1.0))
    peak = maximum(abs(alpha+rad2deg(twist(w,eta))) for eta in vcat(0.0,w.twist_etas,1.0))
    warnings = String[]
    if peak > 12
        push!(warnings, @sprintf("High local incidence: root %.2f deg, tip %.2f deg, maximum absolute incidence %.2f deg. The twisted geometry is resolved, but VLM still assumes attached flow; these loads are an extrapolation and do not predict separation or stall. The 12 deg warning threshold is not a stall criterion.", root, tip, peak))
    end
    return (; root, tip, warnings)
end

"""Prandtl-Glauert map in wind axes, with the symmetry plane left unchanged.

For beta=sqrt(1-M^2), (x',y',z')=(x,beta*y,beta*z) and
phi'=beta^2*phi turn the linear subsonic potential equation into Laplace's
equation. Thus Gamma=Gamma'/beta^2 and the disturbance velocity transforms
as (u,v,w)=(u'/beta^2,v'/beta,w'/beta). Only the disturbance is scaled: the
freestream remains U. Recover forces with Kutta-Joukowski on the original
vortex segments, and moments with their original lever arms. This avoids
applying a two-dimensional 1/beta multiplier indiscriminately to a finite
wing or to induced drag. See MIT AVL User Primer, Compressibility:
https://web.mit.edu/drela/Public/web/avl/avl_doc.txt
"""
function vlm_pg_map(alpha, mach)
    beta=sqrt(1-mach^2)
    s,c=sincos(alpha)
    to_wind(v)=(c*v[1]+s*v[3],v[2],-s*v[1]+c*v[3])
    to_body(v)=(c*v[1]-s*v[3],v[2],s*v[1]+c*v[3])
    point(v)=to_body((v[1],v[2]/beta,v[3]/beta))
    normal(v)=begin
        n=to_body((v[1],beta*v[2],beta*v[3]));n./norm3(n)
    end
    velocity(v,speed)=to_body((speed+(v[1]-speed)/beta^2,v[2]/beta,v[3]/beta))
    forward(v)=begin
        q=to_wind(v);(q[1],beta*q[2],beta*q[3])
    end
    return (;beta,to_wind,to_body,point,normal,velocity,forward)
end

"""Inviscid span efficiency from full-wing lift and Trefftz-plane induced drag.

This is not the viscous Oswald factor of a fitted total-drag polar. Do not clamp
to one: nonplanar wakes and finite-resolution VLM results need not obey the
ideal planar lifting-line bound. Zero induced drag leaves the ratio undefined.
"""
function inviscid_span_efficiency(cl, cdi, aspect_ratio)
    all(isfinite, (cl,cdi,aspect_ratio)) && cdi > 0 && aspect_ratio > 0 || return nothing
    efficiency=cl^2/(pi*aspect_ratio*cdi)
    return isfinite(efficiency) ? efficiency : nothing
end

"""
    solve_vlm(w, p)

Solve the right half wing including the mirrored left wing's induced velocity.
The trailing wake is straight and aligned with the freestream, with semi-infinite
trailing vortices. Panel forces include all three bound-vortex segments; their
different application points produce a panel couple that must survive transfer.
Coefficients describe the unscaled full wing. Physical loads are the modelled
semi-span, multiplied once by the dimensionless loads.load_factor (never by an
extra symmetry factor or an implicit n-g conversion). Prescribed torque uses
the same multiplier. A multiplier of 1.5 converts limit loads to ultimate only
when the defined aerodynamic case already represents limit loads.
"""
function solve_vlm(w::Wing, p::AbstractDict; aerodynamic_mesh=nothing, match_lift=true)
    validate_params(p)
    if match_lift && aircraft_lift_matching(p)
        return solve_vlm_aircraft_lift(w, p; aerodynamic_mesh)
    end
    nc, ns = Int(p["aero.chord_panels"]), Int(p["aero.span_panels"])
    mesh = aerodynamic_mesh === nothing ? vlm_mesh(w, nc, ns) : aerodynamic_mesh
    grid = mesh.grid
    actual_nc = size(grid, 2) - 1
    actual_ns = size(grid, 3) - 1
    # VortexLattice mirrors about y=0. Solve in translated-root coordinates,
    # then return absolute FE positions; translation must not alter loads.
    origin = (w.root_ref_x, w.root_ref_y, w.root_ref_z+vertical_shift(w,0.0))
    local_grid = grid .- reshape(collect(origin),3,1,1)
    condition = flight_condition(p)
    speed, rho = condition["speed_m_s"], condition["density_kg_m3"]
    alpha = deg2rad(p["aero.alpha"])
    mach=condition["Mach"]
    mach <= 0.5 + 8eps(0.5) || throw(ArgumentError("VLM requires Mach <= 0.5 at this case's atmosphere"))
    pg=vlm_pg_map(alpha,mach)
    # Keep the exact established M=0 path. At finite Mach the rotated and
    # compressed lattice is only a solver coordinate system; all exported
    # positions, normals and dimensions remain on the physical camber mesh.
    compressible=pg.beta!=1.0
    solve_grid=compressible ? similar(local_grid) : local_grid
    if compressible
        for j in axes(local_grid,3),i in axes(local_grid,2)
            solve_grid[:,i,j].=pg.forward(view(local_grid,:,i,j))
        end
    end
    ref = VortexLattice.Reference(w.area, w.mac, w.span, [0.0, 0.0, 0.0], speed)
    fs = VortexLattice.Freestream(speed, compressible ? 0.0 : alpha, 0.0, [0.0, 0.0, 0.0])
    # Explicit ratios avoid VortexLattice 0.2.3's uninitialized default array.
    # Control points are mid-span and at 3/4 of each panel chord.
    ratios = zeros(2, actual_nc, actual_ns) .+ [0.5, 0.75]
    system = VortexLattice.System([solve_grid]; ratios = [ratios])
    VortexLattice.steady_analysis!(system, ref, fs;
        symmetric = true, derivatives = false, trailing_vortices = true,
        xhat = VortexLattice.freestream_velocity(fs) / speed)
    all(isfinite, system.Γ) || error("Vortex lattice solve returned non-finite circulation")
    q = 0.5 * rho * speed^2
    scale = q * w.area * Float64(p["loads.load_factor"])
    panels = NamedTuple[]
    coefficient_total=AERO_ZERO
    for (k, (panel, prop)) in enumerate(zip(system.surfaces[1], system.properties[1]))
        i, j = mod1(k, actual_nc), cld(k, actual_nc)
        unmap(v)=compressible ? pg.point(v) : Tuple(v)
        local_center = unmap(VortexLattice.top_center(panel))
        center = local_center .+ origin
        force, moment = AERO_ZERO, AERO_ZERO
        coefficients=(prop.cfb,prop.cfl,prop.cfr)
        if compressible
            gamma=prop.gamma*speed/pg.beta^2
            gamma_bound=(i==1 ? prop.gamma : prop.gamma-system.properties[1][i-1,j].gamma)*speed/pg.beta^2
            velocity=pg.velocity(prop.velocity.*speed,speed)
            freestream=pg.to_body((speed,0.0,0.0))
            # Match VortexLattice's near-field convention: bound segments see
            # the induced velocity, side segments see the freestream only.
            coefficients=(
                gamma_bound.*cross3(velocity,unmap(VortexLattice.top_vector(panel)))./(0.5speed^2*w.area),
                gamma.*cross3(freestream,unmap(VortexLattice.left_vector(panel)))./(0.5speed^2*w.area),
                gamma.*cross3(freestream,unmap(VortexLattice.right_vector(panel)))./(0.5speed^2*w.area))
        end
        for (point, coefficient) in (
            (VortexLattice.top_center(panel), coefficients[1]),
            (VortexLattice.left_center(panel), coefficients[2]),
            (VortexLattice.right_center(panel), coefficients[3]))
            f = Tuple(coefficient .* scale)
            coefficient_total=coefficient_total.+Tuple(coefficient)
            force = force .+ f
            moment = moment .+ cross3(unmap(point) .- local_center, f)
        end
        metric = mesh.metrics[i,j]
        corners, area, normal = metric.corners, metric.area, metric.normal
        # Equivalent panel-average normal traction on the original camber grid.
        # Positive is lower-minus-upper pressure, along the upward panel normal.
        all(isfinite, force) && all(isfinite, moment) && all(isfinite, panel.ncp) ||
            error("Vortex lattice returned non-finite loads or normal at chord panel $i, span panel $j")
        pressure = sum(force .* normal) / area
        isfinite(pressure) || error("Vortex lattice returned non-finite panel pressure")
        push!(panels, (eta = local_center[2] / w.semispan, xc = .75mesh.xcs[i]+.25mesh.xcs[i+1], position = center,
                       force = force, moment = moment, corners = corners,
                       area = area, normal = normal, control_normal = compressible ? pg.normal(panel.ncp) : Tuple(panel.ncp),
                       pressure = pressure, cp = pressure / q))
    end
    cf=2 .* pg.to_wind(coefficient_total)
    total_force, total_moment = load_resultant(panels)
    incidence = vlm_incidence_warnings(w, p)
    cdi=VortexLattice.far_field_drag(system)/pg.beta^4
    aspect_ratio=w.span^2/w.area
    summary = Dict{String,Any}(
        "method" => "vortex_lattice", "engine" => "VortexLattice.jl $(pkgversion(VortexLattice))",
        "panels" => actual_nc * actual_ns, "span_panels" => actual_ns, "chord_panels" => actual_nc,
        "requested_span_panels" => ns, "requested_chord_panels" => nc,
        "geometry_refined" => actual_ns != mesh.initial_span_panels || actual_nc != nc,
        "max_strip_twist_deg" => mesh.max_strip_twist_deg,
        "max_panel_warp_deg" => maximum(p.warp_deg for p in mesh.metrics),
        "max_control_normal_error_deg" => maximum(p.control_normal_error_deg for p in mesh.metrics),
        "incidence_root_deg" => incidence.root, "incidence_tip_deg" => incidence.tip,
        "warnings" => incidence.warnings,
        "validity" => isempty(incidence.warnings) ? "attached_flow_assumed" : "high_incidence_extrapolation",
        "reference_area_m2" => w.area, "reference_mac_m" => w.mac,
        "base_trapezoid_area_m2" => w.base_area,
        "speed_m_s" => speed, "density_kg_m3" => rho, "alpha_deg" => p["aero.alpha"],
        "Mach" => mach, "q_Pa" => q,
        "flight_condition" => condition,
        "lift_matching" => Dict{String,Any}("enabled" => false),
        "compressibility" => "Prandtl-Glauert wind-axis geometry transformation with physical Kutta-Joukowski forces",
        "pg_beta" => pg.beta,
        "load_factor" => p["loads.load_factor"], "load_multiplier_note" => LOAD_MULTIPLIER_NOTE, "CL" => cf[3],
        "CDi" => cdi, "CDi_nearfield" => cf[1],
        "reference_span_m" => w.span, "aspect_ratio" => aspect_ratio,
        "span_efficiency" => inviscid_span_efficiency(cf[3],cdi,aspect_ratio),
        "span_efficiency_note" => "Inviscid span efficiency e = CL^2/(pi AR CDi), with AR = full projected span^2/full reference area and induced CDi from the VLM Trefftz far-wake calculation. CL and CDi describe this selected aerodynamic case before the structural load multiplier. This is not a viscous Oswald factor fitted to a total-drag polar; no profile drag is included. Zero induced drag leaves e undefined. Nonplanar geometry or discretization can produce e above one; values are not clipped.",
        "force_N" => collect(total_force), "moment_Nm" => collect(total_moment),
        "lift_N" => -sin(alpha) * total_force[1] + cos(alpha) * total_force[3],
        "coefficient_basis" => "unscaled full real-planform area and MAC; forces/moments are the scaled right semi-span; edge kinks and twist refinement add panels",
        "limitations" => "Steady symmetric attached flow with linear Prandtl-Glauert subsonic compressibility, limited to Mach 0.5; small-disturbance approximation on a rigid mean-camber surface with a straight freestream wake. No shocks, transonic flow, stall, viscous/profile drag or aeroelastic feedback.",
    )
    return (panels = panels, summary = summary)
end

"""Prescribed chord-proportional loads follow the real piecewise-linear chord."""
function lift_fraction(kind::AbstractString, w::Wing, eta::Float64)
    kind == "schrenk" && return 0.5 * (lift_fraction("elliptical", w, eta) + lift_fraction("chord", w, eta))
    kind == "chord" && w.perturbed && return chord_area_fraction(w, clamp(eta, 0.0, 1.0))
    return lift_fraction(kind, w.taper, eta)
end

"""Case metadata shared by prescribed loading, VLM, export and the browser."""
function aircraft_lift_summary(p)
    aircraft_lift_matching(p) || return Dict{String,Any}("enabled" => false)
    target = aircraft_half_lift(p)
    return Dict{String,Any}("enabled" => true,
        "aircraft_mass_kg" => Float64(p["loads.aircraft_mass"]),
        "maneuver_factor" => Float64(p["loads.maneuver_factor"]),
        "gravity_m_s2" => AIRCRAFT_LIFT_GRAVITY,
        "target_unscaled_half_lift_N" => target,
        "target_scaled_half_lift_N" => target * Float64(p["loads.load_factor"]),
        "structure_inertia_enabled" => structure_inertia_enabled(p),
        "inertia_acceleration_g" => collect(inertia_acceleration_g(p)),
        "note" => AIRCRAFT_LIFT_NOTE)
end

"""Trim actual VLM lift, retaining the solved forces and couples (no load rescaling).

The scalar root is the wind-axis half-wing lift before the final structural
load multiplier. Each trial recomputes the circulation and wake direction at
its angle of attack. Reuse the geometric mesh, and solve only at unit design
multiplier so zero or negative multipliers cannot affect the aerodynamic trim.
The finite +/-30 degree bracket prevents unbounded incidence searches; the
normal attached-flow warning still applies above 12 degrees local incidence.
"""
function solve_vlm_aircraft_lift(w::Wing, p::AbstractDict; aerodynamic_mesh=nothing)
    mesh = aerodynamic_mesh === nothing ? vlm_mesh(w, Int(p["aero.chord_panels"]), Int(p["aero.span_panels"])) : aerodynamic_mesh
    trial = copy(p)
    trial["loads.load_factor"] = 1.0
    target = aircraft_half_lift(p)
    tolerance = max(1e-6, abs(target)*1e-8)
    evaluations = 0
    function evaluate(alpha)
        trial["aero.alpha"] = alpha
        result = solve_vlm(w, trial; aerodynamic_mesh=mesh, match_lift=false)
        evaluations += 1
        residual = Float64(result.summary["lift_N"]) - target
        isfinite(residual) || throw(ArgumentError("Aircraft lift matching returned non-finite VLM lift at $alpha degrees"))
        return result, residual
    end
    initial = Float64(p["aero.alpha"])
    alpha = clamp(initial, -30.0, 30.0)
    solution, residual = evaluate(alpha)
    if abs(residual) > tolerance
        lo, hi = -30.0, 30.0
        lower, flo = evaluate(lo)
        upper, fhi = evaluate(hi)
        if abs(flo) <= tolerance
            solution, residual, alpha = lower, flo, lo
        elseif abs(fhi) <= tolerance
            solution, residual, alpha = upper, fhi, hi
        else
            signbit(flo) != signbit(fhi) || throw(ArgumentError(@sprintf(
                "Cannot match aircraft half-wing lift %.6g N: VLM gives %.6g N at -30 deg and %.6g N at +30 deg. Change aircraft mass/load factor, speed or geometry. VLM does not predict stall.", target, target+flo, target+fhi)))
            # Bracketed secant with a bisection safeguard. Never extrapolate
            # outside the aerodynamic bracket or silently scale the pressure.
            for iteration in 1:40
                candidate = (lo*fhi-hi*flo)/(fhi-flo)
                margin = 1e-4*(hi-lo)
                alpha = isfinite(candidate) && lo+margin < candidate < hi-margin ? candidate : (lo+hi)/2
                solution, residual = evaluate(alpha)
                abs(residual) <= tolerance && break
                if signbit(residual) == signbit(flo)
                    lo, flo = alpha, residual
                else
                    hi, fhi = alpha, residual
                end
            end
            abs(residual) <= tolerance || throw(ArgumentError(@sprintf(
                "Aircraft lift matching did not converge: target %.6g N, residual %.6g N after %d VLM solutions", target, residual, evaluations)))
        end
    end
    multiplier = Float64(p["loads.load_factor"])
    panels = [merge(panel, (force=multiplier.*panel.force, moment=multiplier.*panel.moment,
        pressure=multiplier*panel.pressure, cp=multiplier*panel.cp)) for panel in solution.panels]
    summary = copy(solution.summary)
    for key in ("force_N", "moment_Nm")
        summary[key] = multiplier .* summary[key]
    end
    summary["lift_N"] *= multiplier
    summary["load_factor"] = multiplier
    summary["lift_matching"] = merge(aircraft_lift_summary(p), Dict{String,Any}(
        "alpha_initial_deg" => initial, "alpha_solved_deg" => alpha,
        "achieved_unscaled_half_lift_N" => target + residual,
        "residual_N" => residual, "iterations" => evaluations,
        "trim_angle_bounds_deg" => [-30.0, 30.0], "lift_axis" => "wind"))
    return (;panels, summary)
end

"""Sum forces and right-hand moments about the global origin."""
function load_resultant(loads)
    force, moment = AERO_ZERO, AERO_ZERO
    for load in loads
        force = force .+ load.force
        moment = moment .+ load.moment .+ cross3(load.position, load.force)
    end
    return force, moment
end

"""
    transfer_aero_loads(m, panels)

Identify the modeled control footprint containing the panel application point,
then linearly distribute its resultant between that component's bracketing RBE3
reference stations. Other panels use the main-box references. At reference r_j, add w_j F and
w_j [M_panel + (r_panel-r_j) x F]. Thus both force and moment about every origin
are conserved, including pitching torque from chordwise offsets and camber.
Panels beyond the last structural rib use massless outboard RBE3 references
attached to that rib, retaining the unboxed wing tip moment arm.
"""
function transfer_aero_loads(m::Model, panels)
    isempty(m.rbe3) && throw(ArgumentError("aerodynamic transfer requires RBE3 reference nodes"))
    routing=aerodynamic_routing(m);references=routing.refs
    positions=[Tuple(m.xyz[3sp.ref-2:3sp.ref]) for sp in references]
    forces=fill(AERO_ZERO,length(references));moments=copy(forces)
    for panel in panels
        for (j,weight) in aerodynamic_target_weights(routing,panel.position;eta=panel.eta)
            forces[j]=forces[j].+weight.*panel.force
            moments[j]=moments[j].+weight.*(panel.moment.+cross3(panel.position.-positions[j],panel.force))
        end
    end
    return [(node_index=sp.ref,gid=m.node_ids[sp.ref],eta=sp.eta,position=positions[j],force=forces[j],moment=moments[j])
        for (j,sp) in enumerate(references)]
end

"""Integrate a prescribed strip's force-arm moment about a reference GRID."""
function analytic_strip_moment(m::Model,eta_lo,eta_hi,origin)
    eta_hi>eta_lo || return AERO_ZERO
    total = effective_prescribed_lift(m.params) * m.params["loads.load_factor"]
    total == 0 && return AERO_ZERO
    kind = String(m.params["loads.distribution"])
    cuts = vcat(eta_lo, filter(eta->eta_lo<eta<eta_hi,
        sort!(unique(vcat(planform_breakpoints(m.wing),m.wing.vertical_shift_etas)))), eta_hi)
    nodes = (0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363)
    weights = (0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763)
    moment = AERO_ZERO
    for i in 1:length(cuts)-1
        lo, hi = asin(cuts[i]), asin(cuts[i+1])
        mid, half = (lo + hi) / 2, (hi - lo) / 2
        for (node, weight) in zip(nodes, weights), sign in (-1, 1)
            theta = mid + sign * half * node
            eta, cosine = sincos(theta)
            ellipse_density = (4 / pi) * cosine
            chord_density = m.wing.perturbed ? chord(m.wing, eta) / chord_integral(m.wing, 1.0) :
                2 * (1 - (1 - m.wing.taper) * eta) / (1 + m.wing.taper)
            density = kind == "elliptical" ? ellipse_density : kind == "chord" ? chord_density :
                kind == "schrenk" ? 0.5 * (ellipse_density + chord_density) : 1.0
            position = section_point(m.wing, eta, Float64(m.params["rbe3.ref_xc"]), 0.0)
            force = (0.0, 0.0, total * density * cosine * half * weight)
            moment = moment .+ cross3(position .- origin, force)
        end
    end
    return moment
end

"""Continuous load outside the physical box, about its final physical rib."""
function analytic_outboard_couple(m::Model)
    physical=filter(sp->sp.station>=0,m.rbe3)
    isempty(physical) && return AERO_ZERO
    sp=last(physical)
    return analytic_strip_moment(m,sp.eta,1.,Tuple(m.xyz[3sp.ref-2:3sp.ref]))
end

"""Carry each unboxed tributary strip at its own RBE3 without losing its arm."""
function analytic_outboard_station_moments(m::Model)
    isempty(m.rbe3) && return NTuple{3,Float64}[]
    physical=filter(sp->sp.station>=0,m.rbe3)
    isempty(physical) && return fill(AERO_ZERO,length(m.rbe3))
    start=last(physical).eta
    etas=[sp.eta for sp in m.rbe3]
    return [begin
        lo=max(start,i==1 ? 0. : (etas[i-1]+sp.eta)/2)
        hi=i==length(etas) ? 1. : (sp.eta+etas[i+1])/2
        analytic_strip_moment(m,lo,hi,Tuple(m.xyz[3sp.ref-2:3sp.ref]))
    end for (i,sp) in enumerate(m.rbe3)]
end

"""Add the prescribed right-hand global-y torque at RBE3 reference grids."""
function add_prescribed_torque(m::Model, stations)
    torque = Float64(get(m.params, "loads.torque_y", 0.0)) * m.params["loads.load_factor"]
    torque == 0 && return stations
    shares = station_load_shares(m)
    by_gid=Dict(m.node_ids[sp.ref]=>shares[j] for (j,sp) in enumerate(m.rbe3))
    return [merge(s,(moment=s.moment.+(0.0,torque*get(by_gid,s.gid,0.0),0.0),)) for s in stations]
end

function compute_aerodynamic_loads(m::Model)
    torque = Float64(get(m.params, "loads.torque_y", 0.0)) * m.params["loads.load_factor"]
    if m.params["loads.method"] == "vortex_lattice"
        solution = solve_vlm(m.wing, m.params)
        stations = add_prescribed_torque(m, transfer_aero_loads(m, solution.panels))
        f, moment = load_resultant(stations)
        pf, pm = load_resultant(solution.panels)
        solution.summary["force_error_N"] = norm3(f .- pf)
        solution.summary["moment_error_Nm"] = norm3(moment .- pm .- (0.0, torque, 0.0))
        solution.summary["moment_Nm"] = collect(moment)
        solution.summary["prescribed_torque_y_Nm"] = torque
        solution.summary["control_loading_note"] = "Loads are routed using the modeled control footprint; the VLM pressure solution still uses the continuous, undeflected camber surface. Preset control deflection and elastic motion do not recompute aerodynamic pressures."
        solution.summary["transfer"] = "Each VLM panel resultant goes to its modeled control-surface RBE3s when its application point lies in that footprint; otherwise to main-box RBE3s. Massless references cover unboxed tips. Force and moment are conserved; prescribed global-y torque remains on main-box references."
        return (stations = stations, panels = solution.panels, summary = solution.summary)
    end
    by_gid = Dict(m.node_ids[sp.ref] => sp for sp in m.rbe3)
    stations = [(node_index = by_gid[gid].ref, gid = gid, eta = eta,
                 position = Tuple(m.xyz[3by_gid[gid].ref-2:3by_gid[gid].ref]),
                 force = (0.0, 0.0, fz), moment = AERO_ZERO)
                for (gid, fz, eta) in analytic_lift_forces(m)]
    outboard_couple = analytic_outboard_couple(m)
    strip_moments=analytic_outboard_station_moments(m)
    stations=[merge(s,(moment=strip_moments[i],)) for (i,s) in enumerate(stations)]
    stations = add_prescribed_torque(m, stations)
    f, moment = load_resultant(stations)
    summary = Dict{String,Any}(
        "method" => "analytic", "engine" => "Prescribed lift distribution",
        "flight_condition" => flight_condition(m.params),
        "distribution" => m.params["loads.distribution"],
        "lift_matching" => aircraft_lift_summary(m.params),
        "lift_N" => f[3], "load_factor" => m.params["loads.load_factor"],
        "load_multiplier_note" => LOAD_MULTIPLIER_NOTE,
        "force_N" => collect(f), "moment_Nm" => collect(moment),
        "prescribed_torque_y_Nm" => torque,
        "outboard_transfer_couple_Nm" => collect(outboard_couple),
        "force_error_N" => 0.0, "moment_error_Nm" => 0.0,
        "limitations" => "Prescribed vertical station forces and global-y torque act on main-box references. No chordwise pressure distribution is specified, so no control-surface share is invented. Use VLM for separate control loading. Massless outboard RBE3s retain unboxed-strip moment arms; no aerodynamic solve",
    )
    return (stations = stations, panels = NamedTuple[], summary = summary)
end

"""Return selected loads; cache only the latest model, with threaded-server locking."""
function aerodynamic_loads(m::Model)
    fingerprint = hash(m.params)
    return lock(AERO_CACHE_LOCK) do
        cached = AERO_CACHE[]
        if cached !== nothing && cached.model === m && cached.fingerprint == fingerprint
            return cached.loads
        end
        loads = compute_aerodynamic_loads(m)
        AERO_CACHE[] = (model = m, fingerprint = fingerprint, loads = loads)
        return loads
    end
end

# Compatibility for callers that display only the vertical component.
lift_forces(m::Model) = [(s.gid, s.force[3], s.eta) for s in aerodynamic_loads(m).stations]
