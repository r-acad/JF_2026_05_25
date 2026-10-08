# Gross volume of the shared refined structural/aerodynamic loft, before displacement.
# Physical ribs lie in y = root_ref_y + eta * semispan planes. Sweep/dihedral translate
# these sections and twist rotates them within their planes, preserving area.

function fuel_rib_bounds(p::AbstractDict, rib_count::Int)
    first_rib = Int(p["fuel.start_rib"])
    requested_last = Int(p["fuel.end_rib"])
    last_rib = requested_last == 0 ? rib_count : requested_last
    1 <= first_rib < last_rib <= rib_count || throw(ArgumentError(
        "fuel tank ribs must satisfy 1 <= first < last <= $rib_count; " *
        "got first=$first_rib, last=$last_rib (last=0 selects the final rib)"))
    return first_rib, last_rib
end

"""Dry/vent bays share the bounded physical-bay list syntax of leading-edge gaps."""
function fuel_disabled_bays(value::AbstractString)
    try
        return leading_edge_disabled_bays(value)
    catch error
        error isa ArgumentError || rethrow()
        throw(ArgumentError(replace(error.msg,"leading_edge.disabled_bays"=>"fuel.disabled_bays")))
    end
end
fuel_disabled_bays(value)=throw(ArgumentError("fuel.disabled_bays must be a string such as 2,4-6"))
function fuel_disabled_bays(p::AbstractDict)
    value=get(p,"fuel.disabled_bays","")
    value isa AbstractString||throw(ArgumentError("fuel.disabled_bays must be a string such as 2,4-6"))
    return fuel_disabled_bays(value)
end
function fuel_disabled_bays(p::AbstractDict,rib_count::Integer)
    disabled=fuel_disabled_bays(p)
    if get(p,"fuel.enabled",false)&&!isempty(disabled)
        last(disabled)<rib_count||throw(ArgumentError("fuel.disabled_bays must use physical bays 1 to $(rib_count-1); got bay $(last(disabled))"))
    end
    return disabled
end

"""Selected wet bays and closed contiguous regions, numbered independently of FE rows."""
function fuel_bay_selection(p::AbstractDict,rib_count::Integer)
    first_rib,last_rib=fuel_rib_bounds(p,Int(rib_count));disabled=fuel_disabled_bays(p,rib_count)
    excluded=filter(b->first_rib<=b<last_rib,disabled);dry=Set(excluded)
    active=[b for b in first_rib:last_rib-1 if !(b in dry)]
    regions=Tuple{Int,Int}[]
    for bay in active
        if !isempty(regions)&&last(regions)[2]==bay
            regions[end]=(last(regions)[1],bay+1)
        else
            push!(regions,(bay,bay+1))
        end
    end
    return (;first_rib,last_rib,disabled,excluded,active,regions,
        ignored=filter(b->b<first_rib||b>=last_rib,disabled))
end

"""Exact unit-chord box area of the piecewise linear airfoil tables."""
function airfoil_box_area(af::Airfoil, fs::Real, rs::Real)
    knots = sort!(unique(vcat(Float64[fs, rs],
        filter(x -> fs < x < rs, af.xu), filter(x -> fs < x < rs, af.xl))))
    return sum((knots[i+1] - knots[i]) *
        ((z_upper(af, knots[i]) - z_lower(af, knots[i])) +
         (z_upper(af, knots[i+1]) - z_lower(af, knots[i+1]))) / 2
        for i in 1:length(knots)-1)
end

"""
    enclosed_loft_volume(w, fs, rs, eta_first, eta_last)

Integrate the actual generating loft between two span-normal rib planes.
Normalized section area uses the same station interpolation as the generating
loft. Linear interpolation has an exactly integrable cubic area; cosine blends
use bounded adaptive quadrature between airfoil and planform stations.
"""
function enclosed_loft_volume(w::Wing, fs::Real, rs::Real, eta_first::Real, eta_last::Real;
        section_areas = nothing)
    0 <= eta_first < eta_last <= 1 || throw(ArgumentError("fuel span must satisfy 0 <= first ETA < last ETA <= 1"))
    0 < fs < rs < 1 || throw(ArgumentError("fuel spar bounds must satisfy 0 < front < rear < 1"))
    areas = section_areas === nothing ?
        [airfoil_box_area(af,fs,rs) for af in airfoil_sections(w)] : section_areas
    length(areas)==length(w.airfoil_etas)||throw(ArgumentError("fuel section areas must include every spanwise airfoil"))
    section_area(eta) = begin
        i,t=airfoil_blend_index(w,eta)
        chord(w,Float64(eta))^2*((1-t)*areas[i]+t*areas[i+1])
    end
    cuts = with_planform_stations(w, sort!(unique(vcat(eta_first,eta_last,
        filter(e->eta_first<e<eta_last,w.airfoil_etas)))))
    volume = 0.0
    for i in 1:length(cuts)-1
        volume += w.semispan*fuel_span_integral(w,section_area,cuts[i],cuts[i+1])
    end
    isfinite(volume) && volume > 0 || throw(ArgumentError("fuel loft volume must be finite and positive"))
    return volume
end

"""Piecewise-quadratic primitive of the tabulated unit-chord section height."""
function airfoil_area_primitive(af::Airfoil)
    knots=sort!(unique(vcat(af.xu,af.xl)))
    heights=[z_upper(af,x)-z_lower(af,x) for x in knots]
    areas=zeros(length(knots))
    for i in 1:length(knots)-1
        areas[i+1]=areas[i]+(knots[i+1]-knots[i])*(heights[i]+heights[i+1])/2
    end
    return (;knots,heights,areas)
end

function area_to(profile,x::Real)
    i=clamp(searchsortedlast(profile.knots,x),1,length(profile.knots)-1)
    dx=x-profile.knots[i]
    slope=(profile.heights[i+1]-profile.heights[i])/(profile.knots[i+1]-profile.knots[i])
    return profile.areas[i]+dx*(profile.heights[i]+dx*slope/2)
end

"""Precompute all spar/airfoil crossings required for exact moving-boundary integration."""
function fuel_integration(w::Wing,p::AbstractDict)
    spar=spar_geometry(p)
    if !spar.perturbed&&!w.perturbed
        fs,rs=spar.front_default,spar.rear_default
        return (;spar,cuts=copy(w.airfoil_etas),section_areas=[airfoil_box_area(af,fs,rs) for af in airfoil_sections(w)])
    end
    profiles=[airfoil_area_primitive(af) for af in airfoil_sections(w)]
    knots=airfoil_knots(w)
    stations=sort!(unique(vcat(spar.breakpoints,planform_breakpoints(w),w.airfoil_etas)))
    cuts=copy(stations)
    for edge in (:front,:rear)
        distance(eta)=base_chord(w,eta)*spar_xc(w,spar,eta,edge)-edge_offset(w.leading_etas,w.leading_offsets,eta)
        for i in 1:length(stations)-1
            a,b=stations[i],stations[i+1];ca,cb=chord(w,a),chord(w,b)
            qa,qb=distance(a),distance(b)
            for x in knots
                va,vb=qa-x*ca,qb-x*cb
                if (va<0<vb)||(vb<0<va)
                    eta=a+(b-a)*va/(va-vb)
                    a<eta<b&&push!(cuts,eta)
                end
            end
        end
    end
    return (;spar,cuts=sort!(unique(cuts)),profiles)
end

"""Exact structural tank volume for independently moving front/rear spar paths."""
function enclosed_loft_volume(w::Wing,p::AbstractDict,eta_first::Real,eta_last::Real;integration=nothing)
    0<=eta_first<eta_last<=1||throw(ArgumentError("fuel span must satisfy 0 <= first ETA < last ETA <= 1"))
    data=integration===nothing ? fuel_integration(w,p) : integration
    if !data.spar.perturbed&&!w.perturbed
        return enclosed_loft_volume(w,data.spar.front_default,data.spar.rear_default,eta_first,eta_last;section_areas=data.section_areas)
    end
    function area(eta)
        fs=spar_surface_xc(w,data.spar,eta,:front);rs=spar_surface_xc(w,data.spar,eta,:rear)
        0<fs<rs<1||throw(ArgumentError("fuel spar bounds must lie inside the refined airfoil at eta=$eta"))
        i,t=airfoil_blend_index(w,eta)
        ar=area_to(data.profiles[i],rs)-area_to(data.profiles[i],fs)
        at=area_to(data.profiles[i+1],rs)-area_to(data.profiles[i+1],fs)
        return chord(w,eta)^2*((1-t)*ar+t*at)
    end
    cuts=vcat(Float64(eta_first),filter(eta->eta_first<eta<eta_last,data.cuts),Float64(eta_last))
    volume=0.0
    for i in 1:length(cuts)-1
        volume+=w.semispan*fuel_span_integral(w,area,cuts[i],cuts[i+1])
    end
    isfinite(volume)&&volume>0||throw(ArgumentError("fuel loft volume must be finite and positive"))
    return volume
end

function fuel_summary(m::Model)
    p, g = m.params, m.grid
    enabled = Bool(p["fuel.enabled"])
    result = Dict{String,Any}(
        "enabled" => enabled, "bays" => Any[],
        "rib_count" => length(g.ribs),
        "scope" => "Gross geometric volume in the modeled half wing",
        "method" => m.wing.airfoil_interpolation===:linear ?
            "Exact integration of the refined airfoil loft between independent base-reference spar paths and physical rib planes" :
            "Adaptive cosine-loft integration of exact tabulated airfoil sections (relative quadrature tolerance 1e-11)",
        "note" => "Dry / vent bays are excluded. Structure, equipment, unusable fuel and wall thickness are not deducted. Per-case fuel adds CONM2 mass, CG/inertia and fuel-only acceleration loads through wet-bay RBE3 elements.")
    enabled || return result
    first_rib, last_rib = fuel_rib_bounds(p, length(g.ribs))
    selection=fuel_bay_selection(p,length(g.ribs))
    eta_first, eta_last = g.etas[g.ribs[first_rib]+1], g.etas[g.ribs[last_rib]+1]
    geometry=fuel_geometry_bays(m);volume=0.0
    result["method"]="Exact tabulated polygon moments clipped by physical rib planes, with adaptive span integration (relative moment error target 1e-9)"
    for bay in geometry
        rib=bay.rib
        lo,hi=(g.etas[g.ribs[r]+1] for r in (rib,rib+1))
        bay_volume=bay.full[1];volume+=bay_volume
        push!(result["bays"],Dict{String,Any}("index"=>rib,"start_rib"=>rib,"end_rib"=>rib+1,
            "eta_start"=>lo,"eta_end"=>hi,"volume_m3"=>bay_volume,"volume_litres"=>1000bay_volume))
    end
    merge!(result, Dict{String,Any}(
        "start_rib" => first_rib, "end_rib" => last_rib,
        "eta_start" => eta_first, "eta_end" => eta_last,
        "disabled_bays"=>selection.disabled,"excluded_bays"=>selection.excluded,"ignored_bays"=>selection.ignored,
        "active_bays"=>selection.active,"active_bay_count"=>length(selection.active),
        "regions"=>[Dict("start_rib"=>a,"end_rib"=>b) for (a,b) in selection.regions],
        "volume_m3" => volume, "volume_litres" => 1000volume,
        "mirrored_volume_m3" => 2volume, "mirrored_volume_litres" => 2000volume))
    return result
end

function fuel_info(m::Model)
    summary = fuel_summary(m)
    summary["enabled"] || return Tuple{String,String}[]
    return Tuple{String,String}[
        ("Fuel tank ribs", @sprintf("%d to %d of %d (ETA %.6g to %.6g)",
            summary["start_rib"], summary["end_rib"], summary["rib_count"],
            summary["eta_start"], summary["eta_end"])),
        ("Fuel gross half-wing volume", @sprintf("%.9g m3 (%.9g L)", summary["volume_m3"], summary["volume_litres"])),
        ("Fuel wet / dry bays", "$(summary["active_bay_count"]) wet / $(length(summary["excluded_bays"])) dry in the selected tank range"),
        ("Fuel dry / vent bay IDs", isempty(summary["disabled_bays"]) ? "None" : join(summary["disabled_bays"],", ") * (isempty(summary["ignored_bays"]) ? "" : " (outside-range exclusions retained and ignored: " * join(summary["ignored_bays"],", ") * ")")),
        ("Fuel mirrored-pair volume", @sprintf("%.9g m3 (%.9g L), assuming two identical tanks", summary["mirrored_volume_m3"], summary["mirrored_volume_litres"])),
        ("Fuel volume basis", summary["method"]),
        ("Fuel volume exclusions", summary["note"]),
    ]
end

"""Bounded chord sampling preserving the strongest features of every section table.

Greedy subdivision chooses the largest interpolation error across all stations'
upper/lower ordinates. This affects display only; volume integration always
uses every original airfoil breakpoint. Near-identical knots are merged to
avoid zero-area display triangles after coordinate quantization.
"""
function fuel_display_sections(w::Wing,fs,rs;max_points=129)
    candidates=sort!(vcat(Float64[fs,rs],
        filter(x->fs<x<rs,airfoil_knots(w))))
    knots=Float64[fs]
    for x in candidates
        x-last(knots)>1e-9 && rs-x>1e-9 && push!(knots,x)
    end
    push!(knots,rs)
    ordinates=[[surface(af,x) for x in knots] for af in airfoil_sections(w) for surface in (z_lower,z_upper)]
    length(knots)<=max_points && return knots,ordinates
    function interval(a,b)
        best=0;error=-1.
        for i in a+1:b-1
            t=(knots[i]-knots[a])/(knots[b]-knots[a])
            deviation=maximum(abs(z[i]-((1-t)*z[a]+t*z[b])) for z in ordinates)
            deviation>error && (best=i;error=deviation)
        end
        (a=a,b=b,index=best,error=error)
    end
    segments=[interval(1,length(knots))];selected=Int[1,length(knots)]
    while length(selected)<max_points
        index=argmax([s.error for s in segments]);segment=segments[index]
        segment.index==0 && break
        push!(selected,segment.index)
        segments[index]=interval(segment.a,segment.index)
        push!(segments,interval(segment.index,segment.b))
    end
    sort!(selected)
    return knots[selected],map(z->z[selected],ordinates)
end

"""Closed outward-oriented display loft, at most 129 chord by 65 nominal span rows.

Its exact bounding rib planes and any additional aerodynamic or spar kink rows are
retained. Display density is independent of FE refinement and source-airfoil
density; it has no FE mass or stiffness.
"""
function fuel_surface(m::Model; summary=fuel_summary(m))
    summary["enabled"] || return nothing
    regions=get(summary,"regions",[Dict("start_rib"=>summary["start_rib"],"end_rib"=>summary["end_rib"])])
    isempty(regions)&&return nothing
    xyz=Float64[];conn=Int[]
    for region in regions
        a,b=region["start_rib"],region["end_rib"]
        segment=merge(summary,Dict("start_rib"=>a,"end_rib"=>b,
            "eta_start"=>m.grid.etas[m.grid.ribs[a]+1],"eta_end"=>m.grid.etas[m.grid.ribs[b]+1]))
        surface=fuel_surface_segment(m,segment);offset=length(xyz)÷3
        append!(xyz,surface.xyz);append!(conn,surface.conn.+offset)
    end
    return (xyz=xyz,conn=conn,eta_start=summary["eta_start"],eta_end=summary["eta_end"])
end

function fuel_surface_segment(m::Model,summary)
    summary["enabled"] || return nothing
    oriented_ribs(m.grid)&&return angled_fuel_surface(m,summary)
    w,p = m.grid.wing,m.params
    fs,rs = p["box.front_spar_xc"],p["box.rear_spar_xc"]
    spars=spar_geometry(p)
    first_eta,last_eta = summary["eta_start"],summary["eta_end"]
    variable=spars.perturbed||w.perturbed
    boundaries=sort!(unique(vcat(first_eta,last_eta,filter(eta->first_eta<eta<last_eta,
        vcat(spars.breakpoints,planform_breakpoints(w),w.airfoil_etas)))))
    if variable
        fs=minimum(spar_surface_xc(w,spars,eta,:front) for eta in boundaries)
        rs=maximum(spar_surface_xc(w,spars,eta,:rear) for eta in boundaries)
    end
    knots,ordinates=fuel_display_sections(w,fs,rs)
    intervals = max(2,ceil(Int,64*(last_eta-first_eta)))
    etas=sort!(unique(vcat(collect(range(first_eta,last_eta;length=intervals+1)),boundaries)))
    nx,ny = length(knots),length(etas)
    xyz=Vector{Float64}(undef,6nx*ny);conn=Int[]
    sizehint!(conn,12*((nx-1)*(ny-1)+(nx-1)+(ny-1)))
    offset=0
    for eta in etas
        station,weight=airfoil_blend_index(w,eta)
        c=chord(w,eta);s,cth=sincos(twist(w,eta));xr,yr,zr=reference_point(w,eta)
        front=spar_surface_xc(w,spars,eta,:front);rear=spar_surface_xc(w,spars,eta,:rear)
        for (i,base_xc) in enumerate(knots), k in 1:2
            xc=variable ? front+(base_xc-fs)/(rs-fs)*(rear-front) : base_xc
            zc=variable ? (k==1 ? zlo(w,eta,xc) : zup(w,eta,xc)) :
                (1-weight)*ordinates[2(station-1)+k][i]+weight*ordinates[2station+k][i]
            xi=(xc-w.twist_axis)*cth+zc*s+(w.twist_axis-w.sweep_ref)
            ze=-(xc-w.twist_axis)*s+zc*cth
            xyz[offset+1]=xr+c*xi;xyz[offset+2]=yr;xyz[offset+3]=zr+c*ze
            offset+=3
        end
    end
    node(j,i,k) = 2*(j*nx+i)+k+1
    quad(a,b,c,d) = append!(conn,(a,b,c,a,c,d))
    for j in 0:ny-2, i in 0:nx-2
        quad(node(j,i,1),node(j,i+1,1),node(j+1,i+1,1),node(j+1,i,1))
        quad(node(j,i,0),node(j+1,i,0),node(j+1,i+1,0),node(j,i+1,0))
    end
    for j in 0:ny-2
        quad(node(j,0,0),node(j,0,1),node(j+1,0,1),node(j+1,0,0))
        quad(node(j,nx-1,0),node(j+1,nx-1,0),node(j+1,nx-1,1),node(j,nx-1,1))
    end
    for i in 0:nx-2
        quad(node(0,i,0),node(0,i+1,0),node(0,i+1,1),node(0,i,1))
        quad(node(ny-1,i,0),node(ny-1,i,1),node(ny-1,i+1,1),node(ny-1,i+1,0))
    end
    return (xyz=xyz,conn=conn,eta_start=first_eta,eta_end=last_eta)
end

"""Clip an exact loft cross-section polygon to one side of a rib plane."""
function fuel_clip_polygon(points,plane,sign)
    isempty(points)&&return points
    result=NTuple{3,Float64}[];previous=last(points)
    before=sign*sum(plane.normal.*(previous.-plane.origin))
    for point in points
        after=sign*sum(plane.normal.*(point.-plane.origin))
        if (before>=0)!=(after>=0)
            t=before/(before-after);push!(result,Tuple(previous.+t.*(point.-previous)))
        end
        after>=0&&push!(result,point)
        previous,before=point,after
    end
    return result
end

function fuel_clipped_section_area(w,spar,eta,first_plane,last_plane,knots)
    fs,rs=spar_surface_xc(w,spar,eta,:front),spar_surface_xc(w,spar,eta,:rear)
    xs=vcat(fs,filter(x->fs<x<rs,knots),rs)
    points=vcat([lower_point(w,eta,x) for x in xs],[upper_point(w,eta,x) for x in reverse(xs)])
    points=fuel_clip_polygon(fuel_clip_polygon(points,first_plane,1),last_plane,-1)
    length(points)>=3||return 0.0
    origin=first(points);area=0.0
    for i in eachindex(points)
        a=points[i].-origin;b=points[mod1(i+1,length(points))].-origin
        area+=a[1]*b[3]-a[3]*b[1]
    end
    return abs(area)/2
end

"""Adaptive Gauss integration with an error budget in volume units."""
function fuel_adaptive_integral(f,a,b,tolerance,depth=0)
    nodes=(-0.8611363115940526,-0.3399810435848563,0.3399810435848563,0.8611363115940526)
    weights=(0.3478548451374538,0.6521451548625461,0.6521451548625461,0.3478548451374538)
    gauss(lo,hi)=begin
        center=(lo+hi)/2;half_width=(hi-lo)/2
        half_width*sum(weights[i]*f(center+half_width*nodes[i]) for i in 1:4)
    end
    whole=gauss(a,b);mid=(a+b)/2;split=gauss(a,mid)+gauss(mid,b)
    if abs(split-whole)<=tolerance
        return split
    end
    depth<18||throw(ArgumentError("fuel volume integration did not meet its tolerance near ETA $a to $b; refine the master-rib layout or airfoil"))
    return fuel_adaptive_integral(f,a,mid,tolerance/2,depth+1)+fuel_adaptive_integral(f,mid,b,tolerance/2,depth+1)
end

"""Keep the exact linear fast path and resolve smooth cosine blends to tight tolerance."""
function fuel_span_integral(w::Wing,f,a,b)
    mid=(a+b)/2;half=(b-a)/2
    w.airfoil_interpolation===:linear && return half*(f(mid-half/sqrt(3))+f(mid+half/sqrt(3)))
    scale=max(abs(f(a)),abs(f(mid)),abs(f(b)),1e-12)*(b-a)
    return fuel_adaptive_integral(f,a,b,1e-11*scale)
end

"""Volume between adjacent angled ribs, independent of FE/display density."""
function angled_fuel_bay_volume(m::Model,rib::Int)
    g,w=m.grid,m.wing;cache=g.rib_layout.fuel_cache
    return get!(cache,(rib,rib+1)) do
        ja,jb=g.ribs[rib],g.ribs[rib+1]
        a,b=main_rib_plane(g,m.params,ja),main_rib_plane(g,m.params,jb)
        knots=airfoil_knots(w)
        eta_lo=max(0.0,minimum(vcat(g.lower_etas[:,ja+1],g.upper_etas[:,ja+1]))-0.01)
        eta_hi=min(last(g.etas),maximum(vcat(g.lower_etas[:,jb+1],g.upper_etas[:,jb+1]))+0.01)
        # Full sections are clipped, not approximated by FE quadrilaterals.
        # Include all possible boundary curves in the integration interval;
        # dense chord samples catch extrema between the structural columns.
        cuts=rib_intersection_cuts(w,g.rib_layout,last(g.etas))
        for plane in (a,b),f in range(0.0,1.0;length=33),upper in (false,true)
            curve(eta)=begin
                fs=spar_surface_xc(w,g.rib_layout.arc.spar,eta,:front);rs=spar_surface_xc(w,g.rib_layout.arc.spar,eta,:rear)
                (upper ? upper_point : lower_point)(w,eta,fs+f*(rs-fs))
            end
            eta,_=rib_curve_intersection(curve,plane,cuts,"fuel boundary rib")
            eta_lo=min(eta_lo,eta);eta_hi=max(eta_hi,eta)
        end
        scale=max(w.semispan*(eta_hi-eta_lo)*w.chord_root^2*0.2,1e-8)
        # Integrate the full modeled span, retaining the sampled boundary
        # extrema as cuts rather than using them to truncate the domain.
        stations=sort!(unique(vcat(0.0,last(g.etas),collect(range(eta_lo,eta_hi;length=17)),filter(e->0<e<last(g.etas),
            vcat(planform_breakpoints(w),w.airfoil_etas,g.rib_layout.arc.spar.breakpoints,g.lower_etas[:,ja+1],g.upper_etas[:,ja+1],g.lower_etas[:,jb+1],g.upper_etas[:,jb+1])))))
        area(eta)=w.semispan*fuel_clipped_section_area(w,g.rib_layout.arc.spar,eta,a,b,knots)
        total=sum(fuel_adaptive_integral(area,stations[i],stations[i+1],1e-9*scale*(stations[i+1]-stations[i])/last(g.etas)) for i in 1:length(stations)-1)
        isfinite(total)&&total>0||throw(ArgumentError("angled fuel bay $rib has nonpositive or nonfinite volume"))
        total
    end
end

"""Surface-conforming display envelope bounded by the actual selected rib planes."""
function angled_fuel_surface(m,summary)
    g,w=m.grid,m.wing;spar=g.rib_layout.arc.spar
    ja,jb=g.ribs[summary["start_rib"]],g.ribs[summary["end_rib"]]
    planes=(main_rib_plane(g,m.params,ja),main_rib_plane(g,m.params,jb))
    cuts=rib_intersection_cuts(w,g.rib_layout,last(g.etas));fractions=collect(range(0.0,1.0;length=65));nx=length(fractions);ny=33
    bounds=zeros(nx,2,2)
    for (edge,plane) in enumerate(planes),(i,f) in enumerate(fractions),side in 1:2
        curve(eta)=begin
            fs=spar_surface_xc(w,spar,eta,:front);rs=spar_surface_xc(w,spar,eta,:rear)
            (side==1 ? lower_point : upper_point)(w,eta,fs+f*(rs-fs))
        end
        bounds[i,side,edge],_=rib_curve_intersection(curve,plane,cuts,"fuel display boundary")
    end
    xyz=Float64[];conn=Int[]
    for j in 0:ny-1,(i,f) in enumerate(fractions),side in 1:2
        t=j/(ny-1);eta=(1-t)*bounds[i,side,1]+t*bounds[i,side,2]
        fs=spar_surface_xc(w,spar,eta,:front);rs=spar_surface_xc(w,spar,eta,:rear)
        append!(xyz,(side==1 ? lower_point : upper_point)(w,eta,fs+f*(rs-fs)))
    end
    node(j,i,k)=2*(j*nx+i)+k+1
    quad(a,b,c,d)=append!(conn,(a,b,c,a,c,d))
    for j in 0:ny-2,i in 0:nx-2
        quad(node(j,i,1),node(j,i+1,1),node(j+1,i+1,1),node(j+1,i,1))
        quad(node(j,i,0),node(j+1,i,0),node(j+1,i+1,0),node(j,i+1,0))
    end
    for j in 0:ny-2
        quad(node(j,0,0),node(j,0,1),node(j+1,0,1),node(j+1,0,0))
        quad(node(j,nx-1,0),node(j+1,nx-1,0),node(j+1,nx-1,1),node(j,nx-1,1))
    end
    for i in 0:nx-2
        quad(node(0,i,0),node(0,i+1,0),node(0,i+1,1),node(0,i,1))
        quad(node(ny-1,i,0),node(ny-1,i,1),node(ny-1,i+1,1),node(ny-1,i+1,0))
    end
    return (xyz=xyz,conn=conn,eta_start=summary["eta_start"],eta_end=summary["eta_end"])
end

function fuel_payload(m::Model)
    result = fuel_summary(m)
    result["mass_state"]=fuel_mass_state(m)
    surface = fuel_surface(m;summary=result)
    surface === nothing && return result
    result["surface"] = Dict{String,Any}("xyz"=>blob_f32(surface.xyz),
        "conn"=>blob_i32(surface.conn;offset=-1),"count"=>length(surface.conn)÷3,"n_per_elem"=>3,
        "eta_start"=>surface.eta_start,"eta_end"=>surface.eta_end,
        "note"=>"Undeformed gross tank envelope between the selected ribs, front/rear spars and generating skins. Display triangulation approximates the curved loft; capacity and fuel moments use exact tabulated section polygons with adaptive span integration. Each case adds its own fuel CONM2 mass, CG, inertia and fuel-only acceleration loads.")
    return result
end
