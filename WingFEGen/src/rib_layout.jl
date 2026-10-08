# Master ribs define actual planes and a rear-spar arc-length station coordinate.
# Empty intermediate tables retain the existing span-normal mesh exactly.

"""Untwisted rear-spar reference path, including sweep, dihedral and spar kinks."""
function rear_spar_arc(w::Wing,p::AbstractDict)
    spar=spar_geometry(p)
    point(eta)=begin
        x,y,z=base_reference_point(w,eta)
        (x+(spar_xc(w,spar,eta,:rear)-w.sweep_ref)*base_chord(w,eta),y,z)
    end
    etas=copy(spar.rear_etas);points=point.(etas);lengths=zeros(length(etas))
    for i in 2:length(etas)
        lengths[i]=lengths[i-1]+norm3(points[i].-points[i-1])
    end
    return (;spar,etas,points,lengths)
end
rear_arc_length(arc,eta::Real)=edge_offset(arc.etas,arc.lengths,eta)
rear_arc_eta(arc,distance::Real)=edge_offset(arc.lengths,arc.etas,distance)

function master_rib_direction(arc,eta::Real,mode::AbstractString,angle::Real)
    mode=="flight_direction"&&return (-1.0,0.0,0.0)
    # Datum convention is isolated here for consistent backend/editor use.
    segment=clamp(searchsortedfirst(arc.etas,eta)-1,1,length(arc.etas)-1)
    tangent=unit3((arc.points[segment+1][1]-arc.points[segment][1],arc.points[segment+1][2]-arc.points[segment][2],0.0))
    s,c=sincos(deg2rad(angle))
    direction=(c*tangent[1]-s*tangent[2],s*tangent[1]+c*tangent[2],0.0)
    delta=atan(direction[2],-direction[1])
    abs(delta)<deg2rad(85)||throw(ArgumentError("master rib at rear-spar ETA $eta points away from the front spar or is within 5 degrees of spanwise; adjust its angle"))
    return direction
end

"""Physical ribs, with exact master anchors and interpolated secondary orientations."""
function physical_rib_layout(w::Wing,p::AbstractDict)
    rows=normalize_rib_tables(get(p,"ribs.masters",Any[]),"ribs.masters";end_eta=p["box.end_eta"])
    arc=rear_spar_arc(w,p);end_eta=Float64(p["box.end_eta"])
    masters=vcat([Dict{String,Any}("eta"=>0.0,"mode"=>"flight_direction","angle"=>90.0,"pitch"=>Float64(p["box.rib_pitch"]))],rows,
        [Dict{String,Any}("eta"=>end_eta,"mode"=>"flight_direction","angle"=>90.0,"pitch"=>0.0)])
    master_etas=Float64[row["eta"] for row in masters]
    all(diff(master_etas).>1e-10)||throw(ArgumentError("master rear-spar ETA anchors must be distinct and at least 1e-10 apart, including root and final closures"))
    distances=rear_arc_length.(Ref(arc),master_etas)
    directions=[master_rib_direction(arc,row["eta"],row["mode"],row["angle"]) for row in masters]
    deltas=[atan(d[2],-d[1]) for d in directions]
    physical=NamedTuple[];legacy=isempty(rows)
    for interval in 1:length(masters)-1
        length_interval=legacy ? end_eta*reference_length(w) : distances[interval+1]-distances[interval]
        ratio=length_interval/masters[interval]["pitch"]
        isfinite(ratio)&&ratio<=100000||throw(ArgumentError("rib pitch requests more than 100000 bays in one master interval; increase the pitch"))
        nb=max(1,round(Int,ratio))
        length(physical)+nb<=100001||throw(ArgumentError("master layout requests more than 100000 physical rib bays"))
        for k in 0:nb-1
            t=k/nb;distance=(1-t)*distances[interval]+t*distances[interval+1]
            eta=k==0 ? master_etas[interval] : legacy ? end_eta*t : rear_arc_eta(arc,distance)
            delta=(1-t)*deltas[interval]+t*deltas[interval+1]
            direction=(-cos(delta),sin(delta),0.0)
            push!(physical,(eta=eta,arc=distance,master=k==0,master_index=k==0 ? interval : 0,
                interval=interval,mode=k==0 ? masters[interval]["mode"] : "interpolated",angle=k==0 ? masters[interval]["angle"] : rad2deg(delta),
                pitch=masters[interval]["pitch"],delta=delta,direction=direction))
        end
    end
    push!(physical,(eta=end_eta,arc=last(distances),master=true,master_index=length(masters),interval=length(masters)-1,
        mode="flight_direction",angle=90.0,pitch=0.0,delta=0.0,direction=(-1.0,0.0,0.0)))
    return (;arc,masters,master_etas,distances,deltas,physical,legacy)
end

function rib_row_direction(layout,eta::Real)
    layout.legacy&&return (-1.0,0.0,0.0)
    delta=edge_offset(layout.distances,layout.deltas,rear_arc_length(layout.arc,eta))
    return (-cos(delta),sin(delta),0.0)
end

"""Plane through both rear-spar skin points with the requested horizontal direction."""
function main_rib_plane(w::Wing,layout,eta::Real)
    xc=spar_surface_xc(w,layout.arc.spar,eta,:rear)
    lower,upper=lower_point(w,Float64(eta),xc),upper_point(w,Float64(eta),xc)
    origin=(lower.+upper)./2;direction=rib_row_direction(layout,eta)
    normal=unit3(cross3(direction,upper.-lower))
    norm3(normal)>0.5||throw(ArgumentError("main rib plane is undefined at rear-spar ETA $eta"))
    return (;origin,direction,normal,lower,upper,eta=Float64(eta),scale=max(w.semispan,w.chord_root,1.0))
end

"""Unique root on a curve within the closed structural span, without clipping."""
function rib_curve_intersection(curve,plane,cuts,label)
    tolerance=2e-12*plane.scale
    value(eta)=sum(plane.normal.*(curve(eta).-plane.origin))
    roots=Float64[];a=first(cuts);fa=value(a)
    isfinite(fa)&&abs(fa)<=tolerance&&push!(roots,a)
    for b in cuts[2:end]
        fb=value(b)
        if isfinite(fb)&&abs(fb)<=tolerance
            push!(roots,b)
        elseif isfinite(fa)&&isfinite(fb)&&abs(fa)>tolerance&&signbit(fa)!=signbit(fb)
            lo,hi,flo=a,b,fa
            for _ in 1:48
                mid=(lo+hi)/2;fm=value(mid)
                if abs(fm)<=tolerance/32;lo=hi=mid;break;end
                if signbit(fm)==signbit(flo);lo,flo=mid,fm;else;hi=mid;end
            end
            push!(roots,(lo+hi)/2)
        end
        a,fa=b,fb
    end
    found=Float64[]
    for eta in roots
        (isempty(found)||eta-last(found)>1e-9)&&push!(found,eta)
    end
    length(found)==1||throw(ArgumentError("$label $(isempty(found) ? "does not intersect the wing" : "has multiple intersections") inside the box span; adjust master rib angles/positions to avoid crossing or leaving the surface"))
    eta=only(found);return eta,curve(eta)
end
