# Master ribs define actual planes and a rear-spar arc-length station coordinate.
# Empty intermediate tables retain the existing span-normal mesh exactly.

"""Resolve persistent spar identities in the untwisted reference plan.

Rear ETA is a dependent coordinate. Preserve the direction convention and pitch;
never retarget a deleted identity to the point that happens to replace its index.
"""
function resolve_master_spar_links(p::AbstractDict)
    rows=normalize_rib_tables(deepcopy(get(p,"ribs.masters",Any[])),"ribs.masters";end_eta=p["box.end_eta"])
    any(r->haskey(r,"spar_link"),rows)||return rows
    q=copy(p);apply_point_angle_constraints!(q)
    s=sqrt(q["planform.area"]*q["planform.aspect_ratio"])/2
    cr=q["planform.area"]/(s*(1+q["planform.taper_ratio"]))
    chord(e)=cr*(1-(1-q["planform.taper_ratio"])*e)
    xy(e,offset,edge)=(e*s*tand(q["planform.sweep"])+(q["box.$(edge)_spar_xc"]+offset-q["planform.sweep_ref_xc"])*chord(e),e*s)
    rear=deepcopy(get(q,"box.rear_spar_points",Any[]))
    isempty(rear)||sort!(rear;by=r->r["eta"])
    (isempty(rear)||first(rear)["eta"]>0)&&pushfirst!(rear,Dict("eta"=>0.,"dxc"=>0.))
    last(rear)["eta"]<1&&push!(rear,Dict("eta"=>1.,"dxc"=>0.))
    cross2(a,b)=a[1]*b[2]-a[2]*b[1]
    for row in rows
        haskey(row,"spar_link")||continue
        link=row["spar_link"];edge=link["edge"]
        target=findfirst(r->get(r,"point_id",nothing)==link["point_id"],q["box.$(edge)_spar_points"])
        if target===nothing;delete!(row,"spar_link");continue;end
        point=q["box.$(edge)_spar_points"][target];te=point["eta"]
        0<te<q["box.end_eta"]||throw(ArgumentError("linked spar point must remain strictly inside the box; unlink the master before moving the point to a closure"))
        if edge=="rear";row["eta"]=te;continue;end
        position=xy(te,point["dxc"],edge);candidates=Float64[]
        for i in 2:length(rear)
            a,b=rear[i-1],rear[i];pa,pb=xy(a["eta"],a["dxc"],"rear"),xy(b["eta"],b["dxc"],"rear")
            segment=pb.-pa;t=unit3((segment[1],segment[2],0.));sn,cs=sincosd(row["angle"])
            d=row["mode"]=="flight_direction" ? (-1.,0.) : (cs*t[1]-sn*t[2],sn*t[1]+cs*t[2])
            den=cross2(segment,d);abs(den)>1e-14||continue
            offset=position.-pa;u=cross2(offset,d)/den;distance=cross2(segment,offset)/den
            e=a["eta"]+u*(b["eta"]-a["eta"])
            0<=u<=1&&distance>=-1e-10&&0<e<q["box.end_eta"]&&push!(candidates,e)
        end
        isempty(candidates)&&throw(ArgumentError("linked master cannot reach its front-spar point with the selected direction; change its direction or unlink it"))
        row["eta"]=candidates[argmin(abs.(candidates.-row["eta"]))]
    end
    return normalize_rib_tables(rows,"ribs.masters";end_eta=q["box.end_eta"])
end

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
    rows=resolve_master_spar_links(p)
    arc=rear_spar_arc(w,p);end_eta=Float64(p["box.end_eta"])
    masters=vcat([Dict{String,Any}("eta"=>0.0,"mode"=>"flight_direction","angle"=>90.0,"pitch"=>Float64(p["box.rib_pitch"]))],rows,
        [Dict{String,Any}("eta"=>end_eta,"mode"=>"flight_direction","angle"=>90.0,"pitch"=>0.0)])
    master_etas=Float64[row["eta"] for row in masters]
    all(diff(master_etas).>1e-10)||throw(ArgumentError("master rear-spar ETA anchors must be distinct and at least 1e-10 apart, including root and final closures"))
    distances=rear_arc_length.(Ref(arc),master_etas)
    directions=[master_rib_direction(arc,row["eta"],row["mode"],row["angle"]) for row in masters]
    deltas=[atan(d[2],-d[1]) for d in directions]
    plane_tilts=[get(row,"plane","vertical")=="normal_to_midplane" ? 1.0 : 0.0 for row in masters]
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
    return (;arc,masters,master_etas,distances,deltas,plane_tilts,physical,legacy)
end

function rib_row_direction(layout,eta::Real)
    layout.legacy&&return (-1.0,0.0,0.0)
    delta=edge_offset(layout.distances,layout.deltas,rear_arc_length(layout.arc,eta))
    return (-cos(delta),sin(delta),0.0)
end

"""Local chord-sheet normal, including twist, dihedral and loft Z translation."""
function local_midplane_normal(w::Wing,eta::Real,xc::Real)
    e=Float64(eta);x=Float64(xc)
    chord_axis=section_point(w,e,1.,0.).-section_point(w,e,0.,0.)
    # One-sided at linear loft anchors, matching the outboard slope convention.
    h=1e-7;lo=e<1-h ? e : max(0.,e-h);hi=e<1-h ? min(1.,e+h) : e
    span_axis=(section_point(w,hi,x,0.).-section_point(w,lo,x,0.))./(hi-lo)
    return unit3(cross3(chord_axis,span_axis))
end

"""Plane at the rear mid-surface datum; secondary tilt blends between masters."""
function main_rib_plane(w::Wing,layout,eta::Real)
    xc=spar_surface_xc(w,layout.arc.spar,eta,:rear)
    lower,upper=lower_point(w,Float64(eta),xc),upper_point(w,Float64(eta),xc)
    origin=(lower.+upper)./2;direction=rib_row_direction(layout,eta)
    vertical=unit3(cross3(direction,(0.,0.,1.)))
    fraction=edge_offset(layout.distances,layout.plane_tilts,rear_arc_length(layout.arc,eta))
    normal=vertical
    if fraction>0
        local_normal=local_midplane_normal(w,eta,xc)
        tilted=unit3(cross3(direction,local_normal))
        sum(tilted.*vertical)<0&&(tilted=(-1.).*tilted)
        normal=unit3((1-fraction).*vertical.+fraction.*tilted)
    end
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
    length(found)==1||throw(ArgumentError("$label $(isempty(found) ? "does not intersect the lifting surface" : "has multiple intersections") inside the box span; adjust master rib angles/positions to avoid crossing or leaving the surface"))
    eta=only(found);return eta,curve(eta)
end
