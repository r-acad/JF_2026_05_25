# ===========================================================================
#  geometry.jl - base trapezoid, piecewise-linear edge refinement and lofting
#
#  Global axes (NASTRAN basic system):
#
#       x   aft, along the chord
#       y   towards the tip
#       z   up
#
#  The model is the right-hand semi-span, root at y = root_ref_y.
#
#  A section is placed by
#
#    1. blending adjacent spanwise section ordinates at constant x/c,
#    2. pitching the unit-chord section about `twist_axis_xc` by the local
#       twist,
#    3. scaling by the local chord,
#    4. offsetting to `sweep_ref_xc` of the refined section. Its z follows
#       the dihedralled base reference line, while its x follows both edges.
#
#  Base area, aspect ratio and taper define a projected x-y trapezoid.
#  Perturbation points use that trapezoid's eta and local x/c; straight physical
#  segments join those points. Refinement changes chord, area and MAC but keeps
#  the base projected span. Reported actual metrics are before section twist.
# ===========================================================================

"""
    Wing

Everything the mesh generator needs to evaluate the lofted wing surface.
Angles are stored in radians and the derived planform dimensions are
precomputed.
"""
struct Wing
    root_af::Airfoil
    tip_af::Airfoil
    area::Float64          # actual full wing projected area, before twist
    aspect_ratio::Float64
    taper::Float64
    twist_tip::Float64     # rad
    sweep::Float64         # rad
    sweep_ref::Float64     # x/c
    dihedral::Float64      # rad
    twist_axis::Float64    # x/c
    root_ref_x::Float64
    root_ref_y::Float64
    root_ref_z::Float64
    span::Float64          # full span b
    semispan::Float64      # s = b / 2, projected
    chord_root::Float64
    chord_tip::Float64
    mac::Float64           # mean aerodynamic chord
    base_area::Float64
    base_aspect_ratio::Float64
    base_taper::Float64
    base_chord_root::Float64
    base_chord_tip::Float64
    base_mac::Float64
    leading_etas::Vector{Float64}
    leading_offsets::Vector{Float64} # x displacement from the BASE leading edge
    trailing_etas::Vector{Float64}
    trailing_offsets::Vector{Float64} # x displacement from the BASE trailing edge
    perturbed::Bool
    airfoil_etas::Vector{Float64}
    intermediate_afs::Vector{Airfoil}
    airfoil_interpolation::Symbol
end

"""Linear interpolation of physical edge displacement, independent of root translation."""
function edge_offset(etas::AbstractVector, offsets::AbstractVector, eta::Real)
    i = clamp(searchsortedlast(etas, eta), 1, length(etas) - 1)
    t = (eta - etas[i]) / (etas[i + 1] - etas[i])
    return (1.0 - t) * offsets[i] + t * offsets[i + 1]
end

"""Keep physical polyline corners, independently of editable control handles.

Collinear handles do not constitute geometric kinks and must not force mesh
rows or local triangulation. The tolerance only covers floating-point roundoff
in the ordinate interpolation; it is not a mesh-size/geometric tolerance.
"""
function physical_polyline(etas::AbstractVector, ordinates::AbstractVector)
    keep=Int[]
    for i in eachindex(etas)
        push!(keep,i)
        while length(keep)>=3
            a,b,c=keep[end-2:end]
            t=(etas[b]-etas[a])/(etas[c]-etas[a])
            expected=(1-t)*ordinates[a]+t*ordinates[c]
            roundoff=8eps(max(abs(ordinates[a]),abs(ordinates[b]),abs(ordinates[c])))
            abs(ordinates[b]-expected)<=roundoff || break
            deleteat!(keep,length(keep)-1)
        end
    end
    return Float64[etas[i] for i in keep],Float64[ordinates[i] for i in keep]
end

"""Validated base and refined planform dimensions without building airfoils."""
function planform_geometry(p::AbstractDict)
    S, AR, lam = Float64(p["planform.area"]), Float64(p["planform.aspect_ratio"]), Float64(p["planform.taper_ratio"])
    all(isfinite, (S, AR, lam)) && S > 0 && AR > 0 && 0 < lam <= 1 ||
        throw(ArgumentError("base planform area/aspect ratio must be positive and taper must be in (0, 1]"))
    b = sqrt(AR * S)
    cr = 2.0 * S / (b * (1.0 + lam))
    ct = lam * cr
    mac = 2.0 / 3.0 * cr * (1.0 + lam + lam^2) / (1.0 + lam)
    all(x -> isfinite(x) && x > 0, (b, cr, ct, mac)) ||
        throw(ArgumentError("base planform dimensions must be finite and positive"))
    base_c(eta) = cr * (1.0 - (1.0 - lam) * eta)
    function edge(key, baseline)
        points = normalize_planform_points(get(p, key, Any[]), key; nominal=baseline)
        anchors = Dict(0.0 => 0.0, 1.0 => 0.0)
        for point in points
            eta, dxc = point["eta"], point["dxc"]
            anchors[eta] = dxc * base_c(eta)
        end
        etas = sort!(collect(keys(anchors)))
        offsets = [anchors[eta] for eta in etas]
        all(isfinite, offsets) || throw(ArgumentError("$key gives non-finite physical edge locations"))
        etas,offsets=physical_polyline(etas,offsets)
        return etas, offsets, any(!iszero,offsets)
    end
    leading_etas, leading_offsets, le_changed = edge("planform.leading_edge_points", 0.0)
    trailing_etas, trailing_offsets, te_changed = edge("planform.trailing_edge_points", 1.0)
    stations = sort!(unique(vcat(leading_etas, trailing_etas)))
    chords = [base_c(eta) + edge_offset(trailing_etas, trailing_offsets, eta) -
              edge_offset(leading_etas, leading_offsets, eta) for eta in stations]
    for (eta, c) in zip(stations, chords)
        isfinite(c) && c > 0 || throw(ArgumentError(
            "planform leading and trailing edges must leave a positive chord at every eta; chord is $c at eta=$eta"))
    end
    perturbed = le_changed || te_changed
    if perturbed
        c_integral = sum((stations[i+1]-stations[i]) * (chords[i]+chords[i+1])/2 for i in 1:length(stations)-1)
        c2_integral = sum((stations[i+1]-stations[i]) *
            (chords[i]^2+chords[i]*chords[i+1]+chords[i+1]^2)/3 for i in 1:length(stations)-1)
        area, actual_mac = b * c_integral, c2_integral / c_integral
        actual_ar, actual_taper = b^2 / area, last(chords) / first(chords)
        all(x -> isfinite(x) && x > 0, (area, actual_mac, actual_ar, actual_taper)) ||
            throw(ArgumentError("perturbed planform dimensions must be finite and positive"))
        root, tip = first(chords), last(chords)
    else
        # Preserve the exact legacy values when loading an old definition.
        area, actual_mac, actual_ar, actual_taper = S, mac, AR, lam
        root, tip = cr, ct
    end
    return (; area, aspect_ratio=actual_ar, taper=actual_taper, span=b, semispan=b/2,
        chord_root=root, chord_tip=tip, mac=actual_mac,
        base_area=S, base_aspect_ratio=AR, base_taper=lam, base_chord_root=cr,
        base_chord_tip=ct, base_mac=mac, leading_etas, leading_offsets,
        trailing_etas, trailing_offsets, perturbed)
end

"""
    make_wing(p) -> Wing

Build the wing from the flat parameter dictionary, deriving the base trapezoid
from area, aspect ratio and taper ratio, then applying nondimensional edge points:

    b  = sqrt(AR * S),   c_root = 2 S / (b (1 + lambda)),   c_tip = lambda c_root
"""
function make_wing(p::AbstractDict)
    root_af = airfoil_from_params(p, "root")
    tip_af = airfoil_from_params(p, "tip")
    stations=normalize_airfoil_stations(get(p,"airfoil.stations",Any[]))

    g = planform_geometry(p)
    return Wing(root_af, tip_af, g.area, g.aspect_ratio, g.taper,
                deg2rad(p["planform.twist_tip"]),
                deg2rad(p["planform.sweep"]),
                p["planform.sweep_ref_xc"],
                deg2rad(p["planform.dihedral"]),
                p["planform.twist_axis_xc"],
                p["planform.root_ref_x"],
                p["planform.root_ref_y"], p["planform.root_ref_z"],
                g.span, g.semispan, g.chord_root, g.chord_tip, g.mac,
                g.base_area, g.base_aspect_ratio, g.base_taper,
                g.base_chord_root, g.base_chord_tip, g.base_mac,
                g.leading_etas, g.leading_offsets, g.trailing_etas,
                g.trailing_offsets, g.perturbed,
                vcat(0.0,[row["eta"] for row in stations],1.0),
                Airfoil[intermediate_airfoil(p,row) for row in stations],
                Symbol(get(p,"airfoil.interpolation","linear")))
end

"""Reference-only base trapezoid with the same airfoils and orientation."""
function base_wing(w::Wing)
    w.perturbed || return w
    return Wing(w.root_af,w.tip_af,w.base_area,w.base_aspect_ratio,w.base_taper,
        w.twist_tip,w.sweep,w.sweep_ref,w.dihedral,w.twist_axis,
        w.root_ref_x,w.root_ref_y,w.root_ref_z,w.span,w.semispan,
        w.base_chord_root,w.base_chord_tip,w.base_mac,
        w.base_area,w.base_aspect_ratio,w.base_taper,w.base_chord_root,w.base_chord_tip,w.base_mac,
        [0.0,1.0],[0.0,0.0],[0.0,1.0],[0.0,0.0],false,
        copy(w.airfoil_etas),copy(w.intermediate_afs),w.airfoil_interpolation)
end

"""Structural skin and aerodynamic surface share the same refined airfoil loft."""
structural_wing(w::Wing)=w

"""Validate spar paths and precompute physical x distances from the base leading edge."""
function spar_geometry(p::AbstractDict)
    S, AR, taper = Float64(p["planform.area"]), Float64(p["planform.aspect_ratio"]), Float64(p["planform.taper_ratio"])
    span=sqrt(S*AR);root=2S/(span*(1+taper))
    c(eta)=root*(1-(1-taper)*eta)
    function edge(which)
        key="box.$(which)_spar_points";baseline=Float64(p["box.$(which)_spar_xc"])
        points=normalize_planform_points(get(p,key,Any[]),key;nominal=baseline)
        anchors=Dict(0.0=>baseline*c(0.0),1.0=>baseline*c(1.0))
        for point in points
            anchors[point["eta"]]=(baseline+point["dxc"])*c(point["eta"])
        end
        etas=sort!(collect(keys(anchors)));positions=[anchors[eta] for eta in etas]
        etas,positions=physical_polyline(etas,positions)
        return etas,positions,any(point->!iszero(point["dxc"]),points)
    end
    front_etas,front_positions,front_changed=edge(:front)
    rear_etas,rear_positions,rear_changed=edge(:rear)
    breakpoints=sort!(unique(vcat(front_etas,rear_etas)))
    all(isfinite,front_positions)&&all(isfinite,rear_positions)||
        throw(ArgumentError("spar point physical coordinates must be finite"))
    aero=planform_geometry(p);end_eta=Float64(p["box.end_eta"])
    stations=sort!(unique(vcat(0.0,end_eta,filter(eta->0<eta<end_eta,
        vcat(breakpoints,aero.leading_etas,aero.trailing_etas)))))
    for eta in stations
        leading=edge_offset(aero.leading_etas,aero.leading_offsets,eta)
        trailing=c(eta)+edge_offset(aero.trailing_etas,aero.trailing_offsets,eta)
        front=front_changed ? edge_offset(front_etas,front_positions,eta) : Float64(p["box.front_spar_xc"])*c(eta)
        rear=rear_changed ? edge_offset(rear_etas,rear_positions,eta) : Float64(p["box.rear_spar_xc"])*c(eta)
        leading<front<rear<trailing || throw(ArgumentError(
            "spar paths must lie strictly inside the refined wing over the modeled box: leading edge < front spar < rear spar < trailing edge; failure at eta=$eta (base x/c: LE=$(leading/c(eta)), front=$(front/c(eta)), rear=$(rear/c(eta)), TE=$(trailing/c(eta)))"))
    end
    return (;front_etas,front_positions,rear_etas,rear_positions,breakpoints,
        perturbed=front_changed||rear_changed,front_perturbed=front_changed,rear_perturbed=rear_changed,
        front_default=Float64(p["box.front_spar_xc"]),rear_default=Float64(p["box.rear_spar_xc"]))
end

"""Map an independent base-trapezoid spar path to its fraction of the refined airfoil."""
function spar_surface_xc(w::Wing,g::NamedTuple,eta::Real,edge::Symbol)
    base_xc=spar_xc(w,g,eta,edge)
    w.perturbed||return base_xc
    leading=edge_offset(w.leading_etas,w.leading_offsets,eta)
    return (base_chord(w,eta)*base_xc-leading)/chord(w,eta)
end

spar_surface_xc(w::Wing,p::AbstractDict,eta::Real,edge::Symbol)=
    spar_surface_xc(w,spar_geometry(p),eta,edge)

spar_breakpoints(p::AbstractDict)=spar_geometry(p).breakpoints

function spar_xc(w::Wing,g::NamedTuple,eta::Real,edge::Symbol)
    edge in (:front,:rear)||throw(ArgumentError("spar edge must be :front or :rear"))
    edge===:front&&!g.front_perturbed&&return g.front_default
    edge===:rear&&!g.rear_perturbed&&return g.rear_default
    etas,positions=edge===:front ? (g.front_etas,g.front_positions) : (g.rear_etas,g.rear_positions)
    return edge_offset(etas,positions,eta)/base_chord(w,eta)
end

function spar_xc(w::Wing,p::AbstractDict,eta::Real,edge::Symbol)
    edge in (:front,:rear)||throw(ArgumentError("spar edge must be :front or :rear"))
    if isempty(get(p,"box.front_spar_points",Any[]))&&isempty(get(p,"box.rear_spar_points",Any[]))
        return Float64(p["box.$(edge)_spar_xc"])
    end
    return spar_xc(w,spar_geometry(p),eta,edge)
end

"""Continuous piecewise stringer path; angles belong to each segment's ending rear point.

Without rear points the legacy global angle and rear-spar datum are retained
exactly. A final implicit tip segment repeats the last explicit angle. At a
kink the local slope is the outgoing (tipward) segment; at the tip it is the
last segment. Root-relative offsets are cumulative, so stringers never jump.
"""
function stringer_path(w::Wing,p::AbstractDict)
    return stringer_path_geometry(p,w.base_chord_root,w.base_chord_tip,w.base_taper,
        w.semispan,w.sweep,w.sweep_ref)
end

function stringer_path(p::AbstractDict)
    g=planform_geometry(p)
    return stringer_path_geometry(p,g.base_chord_root,g.base_chord_tip,g.base_taper,
        g.semispan,deg2rad(p["planform.sweep"]),p["planform.sweep_ref_xc"])
end

function stringer_path_geometry(p,cr,ct,taper,semispan,sweep,sweep_ref)
    baseline=Float64(p["box.rear_spar_xc"])
    points=normalize_planform_points(get(p,"box.rear_spar_points",Any[]),"box.rear_spar_points";nominal=baseline)
    end_eta=Float64(p["box.end_eta"])
    if isempty(points)
        rear_slope=tan(sweep)+(p["box.rear_spar_xc"]-sweep_ref)*(ct-cr)/semispan
        angle=Float64(p["box.stringer_angle"])
        direction=rad2deg(atan(rear_slope))+angle
        isfinite(angle)&&abs(direction)<89||throw(ArgumentError(
            "box.stringer_angle gives a plane at or beyond 89 deg to the span axis"))
        slope=tan(atan(rear_slope)+deg2rad(angle))
        return (;etas=[0.0,1.0],slopes=[slope],offsets=[0.0,slope*semispan],
            kink_etas=[0.0,1.0],kink_offsets=[0.0,slope*semispan],
            angles=[angle],directions=[direction],rear_slopes=[rear_slope],per_point=false,semispan)
    end
    c(eta)=cr*(1-(1-taper)*eta)
    positions=Dict(0.0=>Float64(p["box.rear_spar_xc"])*c(0.0),
                   1.0=>Float64(p["box.rear_spar_xc"])*c(1.0))
    explicit_angles=Dict{Float64,Float64}()
    for point in points
        eta=point["eta"]
        positions[eta]=(baseline+point["dxc"])*c(eta)
        explicit_angles[eta]=point["stringer_angle"]
    end
    etas=sort!(collect(keys(positions)));n=length(etas)-1
    rear_etas,rear_positions=physical_polyline(etas,[positions[eta] for eta in etas])
    nominal_rear=all(point->iszero(point["dxc"]),points)
    slopes=zeros(n);angles=zeros(n);directions=zeros(n);rear_slopes=zeros(n);offsets=zeros(n+1)
    for i in 1:n
        a,b=etas[i],etas[i+1]
        # Use the physical rear segment, not the distance between adjacent
        # editor handles: a redundant handle must not change its datum slope.
        segment=clamp(searchsortedlast(rear_etas,(a+b)/2),1,length(rear_etas)-1)
        ra,rb=rear_etas[segment:segment+1];dy=(rb-ra)*semispan
        dx=dy*tan(sweep)-sweep_ref*(c(rb)-c(ra))+rear_positions[segment+1]-rear_positions[segment]
        rear_slope=nominal_rear ? tan(sweep)+(baseline-sweep_ref)*(ct-cr)/semispan : dx/dy
        datum=atan(rear_slope)
        angle=get(explicit_angles,b,last(points)["stringer_angle"])
        direction=rad2deg(datum)+angle
        if a<end_eta
            isfinite(direction)&&abs(direction)<89||throw(ArgumentError(
                "rear-spar stringer_angle for segment eta=$a to $b gives direction $direction deg; active stringer directions must stay strictly within +/-89 deg of the span axis"))
        end
        slopes[i]=tan(datum+deg2rad(angle));angles[i]=angle;directions[i]=direction;rear_slopes[i]=rear_slope
    end
    # Preserve raw segment/angle metadata for editing, but mesh only real
    # changes in stringer direction, including angle-only rear control points.
    starts=[1]
    for i in 2:n
        previous=slopes[last(starts)]
        abs(slopes[i]-previous)<=8eps(max(abs(slopes[i]),abs(previous))) || push!(starts,i)
    end
    kink_etas=vcat(etas[starts],last(etas));kink_offsets=zeros(length(kink_etas))
    for i in eachindex(starts)
        kink_offsets[i+1]=kink_offsets[i]+slopes[starts[i]]*(kink_etas[i+1]-kink_etas[i])*semispan
    end
    for i in eachindex(etas)
        j=clamp(searchsortedlast(kink_etas,etas[i]),1,length(starts))
        offsets[i]=kink_offsets[j]+slopes[starts[j]]*(etas[i]-kink_etas[j])*semispan
    end
    return (;etas,slopes,offsets,kink_etas,kink_offsets,angles,directions,rear_slopes,per_point=true,semispan)
end

function stringer_segment(path::NamedTuple,eta::Real)
    return clamp(searchsortedlast(path.etas,eta),1,length(path.slopes))
end

stringer_slope(path::NamedTuple,eta::Real)=path.slopes[stringer_segment(path,eta)]
stringer_slope(w::Wing,p::AbstractDict,eta::Real=0.0)=stringer_slope(stringer_path(w,p),eta)

function stringer_offset(path::NamedTuple,eta::Real)
    # Preserve the old multiplication order for unchanged, straight stringers.
    length(path.kink_etas)==2&&return path.slopes[1]*eta*path.semispan
    i=clamp(searchsortedlast(path.kink_etas,eta),1,length(path.kink_etas)-1)
    return path.kink_offsets[i]+stringer_slope(path,path.kink_etas[i])*(eta-path.kink_etas[i])*path.semispan
end

stringer_offset(w::Wing,p::AbstractDict,eta::Real)=stringer_offset(stringer_path(w,p),eta)

"""Chord of the unmodified base trapezoid at eta in [0, 1]."""
base_chord(w::Wing, eta::Real) = w.base_chord_root * (1.0 - (1.0 - w.base_taper) * eta)
"""Actual local chord at the non-dimensional span station eta in [0, 1]."""
chord(w::Wing, eta::Real) = w.perturbed ? base_chord(w, eta) +
    edge_offset(w.trailing_etas, w.trailing_offsets, eta) -
    edge_offset(w.leading_etas, w.leading_offsets, eta) : base_chord(w, eta)

"""All leading/trailing-edge breakpoints, including the root and tip."""
planform_breakpoints(w::Wing) = sort!(unique(vcat(w.leading_etas, w.trailing_etas)))

"""Global x of an untwisted refined leading/trailing edge (:leading or :trailing)."""
function planform_edge_x(w::Wing, eta::Real, edge::Symbol)
    edge in (:leading, :trailing) || throw(ArgumentError("edge must be :leading or :trailing"))
    baseline, etas, offsets = edge === :leading ?
        (0.0, w.leading_etas, w.leading_offsets) : (1.0, w.trailing_etas, w.trailing_offsets)
    return base_reference_point(w, eta)[1] + (baseline - w.sweep_ref) * base_chord(w, eta) +
        edge_offset(etas, offsets, eta)
end

"""Integral of actual local chord with respect to eta, from 0 to eta in [0, 1]."""
function chord_integral(w::Wing, eta::Real)
    isfinite(eta) && 0 <= eta <= 1 || throw(ArgumentError("chord integral eta must be in [0, 1]"))
    if !w.perturbed
        return w.base_chord_root * (eta - (1-w.base_taper)*eta^2/2)
    end
    stations = planform_breakpoints(w)
    value = 0.0
    for i in 1:length(stations)-1
        a, b = stations[i], min(eta, stations[i+1])
        b > a || break
        value += (b-a) * (chord(w,a)+chord(w,b))/2
        b == eta && break
    end
    return value
end

chord_area_fraction(w::Wing, eta::Real) = chord_integral(w, eta) / chord_integral(w, 1.0)

"""
    twist(w, eta)

Local geometric twist in radians, linear from the root to the tip.
"""
twist(w::Wing, eta::Float64) = w.twist_tip * eta

"""Point on the swept and dihedralled BASE trapezoid datum at span station eta."""
function base_reference_point(w::Wing, eta::Real)
    y = eta * w.semispan
    return (w.root_ref_x + y * tan(w.sweep), w.root_ref_y + y,
            w.root_ref_z + y * tan(w.dihedral))
end

"""
    reference_point(w, eta) -> (x, y, z)

Point at sweep_ref of the refined untwisted section. Its y/z follow the base
datum; its x follows the refined chord. Root reference inputs locate the BASE
datum, which remains available through `base_reference_point`.
"""
function reference_point(w::Wing, eta::Real)
    xr, yr, zr = base_reference_point(w, eta)
    w.perturbed || return (xr, yr, zr)
    le = edge_offset(w.leading_etas, w.leading_offsets, eta)
    te = edge_offset(w.trailing_etas, w.trailing_offsets, eta)
    return (xr + (1-w.sweep_ref)*le + w.sweep_ref*te, yr, zr)
end

"""
    reference_length(w)

Legacy span/height station measure from root to tip (projected span corrected
for dihedral). Rib counts remain stable as sweep or edge perturbations change.
"""
reference_length(w::Wing) = w.semispan * sqrt(1.0 + tan(w.dihedral)^2)

"""
    section_point(w, eta, xc, zc) -> (x, y, z)

Map a unit-chord section coordinate pair `(xc, zc)` at span station `eta` into
the global system. Positive twist raises the leading edge.
"""
function section_point(w::Wing, eta::Float64, xc::Float64, zc::Float64)
    th = twist(w, eta)
    c = chord(w, eta)
    s, cth = sincos(th)
    xa = w.twist_axis
    # Pitch about the twist axis, then shift so the reference line sits at
    # sweep_ref_xc of the untwisted chord.
    xi = (xc - xa) * cth + zc * s + (xa - w.sweep_ref)
    ze = -(xc - xa) * s + zc * cth
    xr, yr, zr = reference_point(w, eta)
    return (xr + c * xi, yr, zr + c * ze)
end

"""
    zup(w, eta, xc)

Upper surface z/c of the lofted section at span station `eta`, obtained by
blending its adjacent airfoils at constant chord fraction.
"""
function zup(w::Wing, eta::Float64, xc::Float64)
    left,right,t=airfoil_blend(w,eta)
    return (1-t)*z_upper(left,xc)+t*z_upper(right,xc)
end

"""
    zlo(w, eta, xc)

Lower surface z/c of the lofted section at span station `eta`.
"""
function zlo(w::Wing, eta::Float64, xc::Float64)
    left,right,t=airfoil_blend(w,eta)
    return (1-t)*z_lower(left,xc)+t*z_lower(right,xc)
end

"""Adjacent section index and bounded blend weight, with zero cosine slope at anchors."""
function airfoil_blend_index(w::Wing,eta::Real)
    e=clamp(Float64(eta),0.0,1.0)
    i=clamp(searchsortedlast(w.airfoil_etas,e),1,length(w.airfoil_etas)-1)
    t=(e-w.airfoil_etas[i])/(w.airfoil_etas[i+1]-w.airfoil_etas[i])
    return i,w.airfoil_interpolation===:cosine ? (1-cospi(t))/2 : t
end

airfoil_section(w::Wing,i::Int)=i==1 ? w.root_af : i==length(w.airfoil_etas) ? w.tip_af : w.intermediate_afs[i-1]
airfoil_sections(w::Wing)=vcat(w.root_af,w.intermediate_afs,w.tip_af)
airfoil_knots(w::Wing)=sort!(unique(vcat((vcat(af.xu,af.xl) for af in airfoil_sections(w))...)))
function airfoil_blend(w::Wing,eta::Real)
    i,t=airfoil_blend_index(w,eta)
    return airfoil_section(w,i),airfoil_section(w,i+1),t
end

"""
    upper_point(w, eta, xc)

Point on the upper aerodynamic surface at `(eta, xc)`.
"""
upper_point(w::Wing, eta::Float64, xc::Float64) =
    section_point(w, eta, xc, zup(w, eta, xc))

"""
    lower_point(w, eta, xc)

Point on the lower aerodynamic surface at `(eta, xc)`.
"""
lower_point(w::Wing, eta::Float64, xc::Float64) =
    section_point(w, eta, xc, zlo(w, eta, xc))

"""
    box_height(w, eta, xc)

Distance between the lower and upper surfaces at `(eta, xc)`, that is the
structural height available to a spar or a rib at that station.
"""
function box_height(w::Wing, eta::Float64, xc::Float64)
    pl = lower_point(w, eta, xc)
    pu = upper_point(w, eta, xc)
    return norm3(pu .- pl)
end

# --- small vector helpers --------------------------------------------------

cross3(a, b) = (a[2] * b[3] - a[3] * b[2],
                a[3] * b[1] - a[1] * b[3],
                a[1] * b[2] - a[2] * b[1])

norm3(a) = sqrt(a[1]^2 + a[2]^2 + a[3]^2)

function unit3(a)
    n = norm3(a)
    n < 1.0e-14 && return (0.0, 0.0, 0.0)
    return (a[1] / n, a[2] / n, a[3] / n)
end
