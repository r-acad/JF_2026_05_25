# Leading-edge ribs are planes hinged on the unchanged front-spar sections.
# The ordinary line-of-flight mesh retains its original coordinate path.

struct OrientedLeadingEdgeGrid
    lower::Matrix{NTuple{3,Float64}}
    upper::Matrix{NTuple{3,Float64}}
    metadata::Vector{Dict{String,Any}}
end
OrientedLeadingEdgeGrid(lower,upper) = OrientedLeadingEdgeGrid(lower,upper,Dict{String,Any}[])
leading_edge_column_count(stations::OrientedLeadingEdgeGrid) = size(stations.lower,1)-1
leading_edge_skin_points(stations::OrientedLeadingEdgeGrid,::BoxGrid,i::Int,j::Int) =
    (stations.lower[i+1,j+1],stations.upper[i+1,j+1])

"""Common untwisted plan-view reference: the first front-spar path segment."""
function leading_edge_reference(w::Wing,p::AbstractDict)
    spar = spar_geometry(p)
    a,b = spar.front_etas[1:2]
    x(eta) = base_reference_point(w,eta)[1] +
        (spar_xc(w,spar,eta,:front)-w.sweep_ref)*base_chord(w,eta)
    tangent = unit3((x(b)-x(a),(b-a)*w.semispan,0.0))
    angle = Float64(get(p,"leading_edge.rib_angle",90.0))
    s,c = sind(angle),cosd(angle)
    direction = (c*tangent[1]-s*tangent[2],s*tangent[1]+c*tangent[2],0.0)
    return (;spar,tangent,direction,angle,eta_start=a,eta_end=b)
end

"""A missing row inherits the global orientation; overrides use physical rib numbers."""
function leading_edge_rib_setting(p::AbstractDict,rib::Int)
    mode=String(get(p,"leading_edge.rib_orientation","flight_direction"))
    angle=Float64(get(p,"leading_edge.rib_angle",90.0))
    for row in get(p,"leading_edge.rib_orientations",Any[])
        Int(row["rib"])==rib || continue
        return (;mode=String(row["mode"]),angle=Float64(get(row,"angle",angle)),overridden=true)
    end
    return (;mode,angle,overridden=false)
end

function leading_edge_front_eta(g::BoxGrid,j::Int,upper::Bool)
    if isdefined(@__MODULE__,:grid_surface_eta)
        return grid_surface_eta(g,0,j,upper)
    end
    return g.etas[j+1] # Compatibility with pre-master-rib BoxGrid.
end

function leading_edge_rib_plane(g::BoxGrid,p::AbstractDict,j::Int;reference=leading_edge_reference(g.wing,p),setting=nothing)
    if setting===nothing
        rib=findfirst(==(j),g.ribs)
        setting=leading_edge_rib_setting(p,rib===nothing ? 0 : rib)
    end
    lower,upper = grid_point(g,0,j,0),grid_point(g,0,j,g.nh)
    origin = (lower .+ upper)./2
    s,c=sind(setting.angle),cosd(setting.angle)
    tangent=reference.tangent
    direction = setting.mode=="flight_direction" ? (-1.0,0.0,0.0) :
        (c*tangent[1]-s*tangent[2],s*tangent[1]+c*tangent[2],0.0)
    normal = unit3(cross3(direction,upper.-lower))
    norm3(normal)>0.5 || throw(ArgumentError("leading-edge rib plane is undefined at front-spar ETA $(g.etas[j+1])"))
    hinge = unit3(upper.-lower)
    forward = unit3(direction.-sum(direction.*hinge).*hinge)
    return (;origin,direction,normal,vertical=cross3(normal,direction),forward)
end

struct LeadingEdgeIntersectionMiss <: Exception
    message::String
    rib::Int
end
LeadingEdgeIntersectionMiss(message::String)=LeadingEdgeIntersectionMiss(message,0)
Base.showerror(io::IO,e::LeadingEdgeIntersectionMiss)=print(io,e.message)

function leading_edge_row_label(g::BoxGrid,j::Int)
    rib = findfirst(==(j),g.ribs)
    return rib===nothing ? "leading-edge skin row at front-spar ETA $(g.etas[j+1])" : "leading-edge rib $rib"
end

"""Intersect a rib plane with one normalized nose-to-front-spar loft curve.

Only a unique in-wing intersection is accepted. Breakpoint-aware bracketing
prevents a root finder from silently jumping to a different branch at a kink.
"""
function leading_edge_plane_intersection(w::Wing,reference,plane,f::Float64,upper::Bool,cuts,label)
    surface = upper ? upper_point : lower_point
    function at(eta)
        xc = f==0.0 ? 0.0 : f*spar_surface_xc(w,reference.spar,eta,:front)
        0.0<=xc<=1.0 || return (NaN,(NaN,NaN,NaN))
        point = surface(w,eta,xc)
        return sum(plane.normal.*(point.-plane.origin)),point
    end
    tolerance = 64eps(Float64)*max(w.chord_root,w.semispan,1.0)
    roots = Float64[]
    previous_eta = first(cuts)
    previous = first(at(previous_eta))
    isfinite(previous)&&abs(previous)<=tolerance && push!(roots,previous_eta)
    for eta in cuts[2:end]
        value = first(at(eta))
        if isfinite(value)&&abs(value)<=tolerance
            push!(roots,eta)
        elseif isfinite(value)&&isfinite(previous)&&abs(previous)>tolerance&&signbit(value)!=signbit(previous)
            lo,hi,flo = previous_eta,eta,previous
            for _ in 1:48
                mid = (lo+hi)/2
                fm = first(at(mid))
                isfinite(fm) || throw(LeadingEdgeIntersectionMiss("$label leaves the aerodynamic surface"))
                if abs(fm)<=tolerance/16 || hi-lo<=4eps(Float64)*max(abs(mid),0.01)
                    lo=hi=mid
                    break
                end
                if signbit(fm)==signbit(flo)
                    lo,flo = mid,fm
                else
                    hi=mid
                end
            end
            push!(roots,(lo+hi)/2)
        end
        previous_eta,previous = eta,value
    end
    unique_roots = Float64[]
    for eta in roots
        (isempty(unique_roots)||eta-last(unique_roots)>1e-10) && push!(unique_roots,eta)
    end
    isempty(unique_roots) && throw(LeadingEdgeIntersectionMiss(
        "$label does not intersect the $(f==0.0 ? "nose" : "skin") inside wing ETA 0 to 1"))
    length(unique_roots)==1 || throw(ArgumentError(
        "$label has multiple skin intersections with its angled plane. Adjust the rib angle or front-spar/planform geometry to avoid folded leading-edge bays"))
    eta = only(unique_roots)
    return eta,last(at(eta))
end

function leading_edge_rib_metadata(g,p,rib,requested,effective,plane,nose,reason)
    j=g.ribs[rib]
    return Dict{String,Any}("rib"=>rib,"row_index"=>j,
        "requested_mode"=>requested.mode,"requested_angle"=>requested.angle,
        "effective_mode"=>effective.mode,"effective_angle"=>effective.mode=="flight_direction" ? nothing : effective.angle,
        "overridden"=>requested.overridden,"fallback"=>!isempty(reason),"reason"=>reason,
        "plane_origin"=>collect(plane.origin),"plane_direction"=>collect(plane.direction),
        "plane_normal"=>collect(plane.normal),"plane_vertical"=>collect(plane.vertical),"plane_forward"=>collect(plane.forward),
        "front_lower"=>collect(grid_point(g,0,j,0)),"front_upper"=>collect(grid_point(g,0,j,g.nh)),"nose"=>collect(nose))
end

function leading_edge_rib_curve(g,p,rib,setting,reference,cuts)
    j=g.ribs[rib];w=g.wing
    plane=leading_edge_rib_plane(g,p,j;reference,setting)
    label="leading-edge rib $rib"
    rowcuts=sort!(unique(vcat(cuts,leading_edge_front_eta(g,j,false),leading_edge_front_eta(g,j,true))))
    cache=Dict{Tuple{Float64,Bool},Tuple{Float64,NTuple{3,Float64}}}()
    function intersection(f,side)
        f==1.0 && return leading_edge_front_eta(g,j,side),grid_point(g,0,j,side ? g.nh : 0)
        f==0.0 && (side=false)
        return get!(cache,(f,side)) do
            try
                leading_edge_plane_intersection(w,reference,plane,f,side,rowcuts,label)
            catch e
                e isa LeadingEdgeIntersectionMiss && throw(LeadingEdgeIntersectionMiss(e.message,rib))
                rethrow()
            end
        end
    end
    nose_eta,nose=intersection(0.0,false)
    sum(plane.forward.*(nose.-plane.origin))>1e-10*w.chord_root ||
        throw(ArgumentError("$label points away from the nose for this front-spar geometry; adjust its angle"))
    norm3(upper_point(w,nose_eta,0.).-lower_point(w,nose_eta,0.))<=1e-9*w.chord_root ||
        throw(ArgumentError("leading-edge structure requires upper/lower airfoil surfaces to meet at the nose"))
    return (;plane,intersection,nose)
end

function leading_edge_effective_grid(g,p,layout,chord_stations,requested,effective,reasons)
    n=size(chord_stations,1)-1;w=g.wing
    lower=Matrix{NTuple{3,Float64}}(undef,size(chord_stations));upper=similar(lower)
    isempty(layout.active_bays) && return OrientedLeadingEdgeGrid(lower,upper)
    rows=sort!(unique(vcat([collect(g.ribs[bay]:g.ribs[bay+1]) for bay in layout.active_bays]...)))
    reference=leading_edge_reference(w,p)
    metadata=Dict{String,Any}[]
    # Preserve the old all-flight coordinate arithmetic exactly, including
    # legacy models whose schema predates the per-rib override table.
    ordinary=all(effective[rib].mode=="flight_direction" for rib in layout.active_ribs) &&
        all(leading_edge_front_eta(g,j,side)==g.etas[j+1] for j in rows for side in (false,true))
    if ordinary
        for j in rows,i in 0:n
            lower[i+1,j+1],upper[i+1,j+1]=leading_edge_skin_points(chord_stations,g,i,j)
        end
        for rib in layout.active_ribs
            j=g.ribs[rib];plane=leading_edge_rib_plane(g,p,j;reference,setting=effective[rib])
            push!(metadata,leading_edge_rib_metadata(g,p,rib,requested[rib],effective[rib],plane,lower[1,j+1],get(reasons,rib,"")))
        end
        return OrientedLeadingEdgeGrid(lower,upper,metadata)
    end
    cuts=sort!(unique(vcat(collect(range(0.,1.,length=65)),planform_breakpoints(w),reference.spar.breakpoints)))
    curves=Dict(rib=>leading_edge_rib_curve(g,p,rib,effective[rib],reference,cuts) for rib in layout.active_ribs)
    fractions=collect(range(0.,1.,length=33))
    # Trigger missing-surface fallback on physical ribs before interpolating
    # shell-only rows. Additional fractions are checked lazily during meshing.
    for rib in layout.active_ribs,f in fractions,side in (false,true)
        curves[rib].intersection(f,side)
    end
    function row_point(j,f,side)
        physical=findfirst(==(j),g.ribs)
        physical!==nothing && return curves[physical].intersection(f,side)
        bay=searchsortedlast(g.ribs,j)
        a,b=g.ribs[bay],g.ribs[bay+1]
        rear_weight=(g.etas[j+1]-g.etas[a+1])/(g.etas[b+1]-g.etas[a+1])
        front_a,front_b=leading_edge_front_eta(g,a,side),leading_edge_front_eta(g,b,side)
        front_b-front_a>1e-12 || throw(ArgumentError("leading-edge bay $bay has collapsed or reversed front-spar attachment stations"))
        front_weight=(leading_edge_front_eta(g,j,side)-front_a)/(front_b-front_a)
        -1e-10<=front_weight<=1+1e-10 || throw(ArgumentError("leading-edge bay $bay has a front-spar mesh row outside its physical ribs"))
        # Shared rear-anchor weight at the nose; actual front attachment
        # weight at the spar. Their convex blend preserves both boundaries.
        weight=(1-f)*rear_weight+f*clamp(front_weight,0.,1.)
        eta_a=first(curves[bay].intersection(f,side))
        eta_b=first(curves[bay+1].intersection(f,side))
        eta=(1-weight)*eta_a+weight*eta_b
        f==1.0 && return leading_edge_front_eta(g,j,side),grid_point(g,0,j,side ? g.nh : 0)
        xc=f==0.0 ? 0.0 : f*spar_surface_xc(w,reference.spar,eta,:front)
        0.0<=eta<=1.0 && 0.0<=xc<=1.0 || throw(ArgumentError("interpolated leading-edge skin in bay $bay leaves the aerodynamic surface"))
        surface=side ? upper_point : lower_point
        return eta,surface(w,eta,xc)
    end
    lower_order=zeros(length(fractions),length(rows));upper_order=similar(lower_order)
    for (row,j) in enumerate(rows)
        for i in 0:n
            f=chord_stations[i+1,j+1]/chord_stations[end,j+1]
            _,lower[i+1,j+1]=row_point(j,f,false)
            _,upper[i+1,j+1]=row_point(j,f,true)
        end
        for (i,f) in enumerate(fractions)
            lower_order[i,row]=first(row_point(j,f,false))
            upper_order[i,row]=first(row_point(j,f,true))
        end
    end
    for row in 2:length(rows),side in (lower_order,upper_order)
        any(side[:,row].-side[:,row-1].<=1e-11) && throw(ArgumentError(
            "leading-edge ribs/skin rows cross or collapse between rows $(rows[row-1]) and $(rows[row]); adjust the per-rib angles or master-rib geometry"))
    end
    # Only physical ribs are planes; interpolated shell rows need not be.
    for index in 2:length(layout.active_ribs)
        ra,rb=layout.active_ribs[index-1:index]
        a,b=g.ribs[ra]+1,g.ribs[rb]+1
        pa,pb=curves[ra].plane,curves[rb].plane
        before=vcat(lower[:,a],upper[:,a]);after=vcat(lower[:,b],upper[:,b])
        tolerance=1e-12*max(w.semispan,w.chord_root,1.0)
        all(sum(pa.normal.*(point.-pa.origin))>tolerance for point in after) &&
            all(sum(pb.normal.*(point.-pb.origin))< -tolerance for point in before) ||
            throw(ArgumentError("leading-edge rib planes $ra and $rb cross; adjust their individual angles or the master-rib geometry"))
    end
    for rib in layout.active_ribs
        curve=curves[rib]
        push!(metadata,leading_edge_rib_metadata(g,p,rib,requested[rib],effective[rib],curve.plane,curve.nose,get(reasons,rib,"")))
    end
    return OrientedLeadingEdgeGrid(lower,upper,metadata)
end

"""Per-physical-rib settings, with explicit flight fallback for a missed surface."""
function leading_edge_mesh_stations(g::BoxGrid,p::AbstractDict,layout)
    chord_stations=leading_edge_chord_stations(g,Int(p["leading_edge.chord_elements"]))
    requested=Dict(rib=>leading_edge_rib_setting(p,rib) for rib in layout.active_ribs)
    effective=copy(requested);reasons=Dict{Int,String}()
    # A late miss at an additional mesh fraction restarts from the physical
    # boundaries, so no rows retain geometry from a superseded rib setting.
    for _ in 0:length(layout.active_ribs)
        try
            return leading_edge_effective_grid(g,p,layout,chord_stations,requested,effective,reasons)
        catch e
            e isa LeadingEdgeIntersectionMiss || rethrow()
            rib=e.rib
            if !haskey(effective,rib) || effective[rib].mode=="flight_direction"
                throw(ArgumentError("$(e.message). A flight-direction rib also cannot attach to this master-rib/front-spar section; revise the underlying geometry"))
            end
            effective[rib]=merge(effective[rib],(;mode="flight_direction"))
            reasons[rib]="$(e.message); using flight direction for this physical rib"
        end
    end
    error("leading-edge fallback did not converge")
end

function leading_edge_stored_metadata(m::Model)
    return hasproperty(m,:le_rib_metadata) ? m.le_rib_metadata : Dict{String,Any}[]
end

function leading_edge_effective_rib_plane(m::Model,j::Int)
    row=findfirst(record->record["row_index"]==j,leading_edge_stored_metadata(m))
    if row!==nothing
        record=leading_edge_stored_metadata(m)[row]
        return (;origin=Tuple(record["plane_origin"]),direction=Tuple(record["plane_direction"]),
            normal=Tuple(record["plane_normal"]),vertical=Tuple(record["plane_vertical"]),forward=Tuple(record["plane_forward"]))
    end
    return leading_edge_rib_plane(m.grid,m.params,j)
end

"""Requested/effective settings and exact generated rib elements for red display."""
function leading_edge_orientation_metadata(m::Model)
    records=deepcopy(leading_edge_stored_metadata(m))
    byrow=Dict(record["row_index"]=>record for record in records)
    for record in records
        record["eids"]=Int[];record["nodes"]=Int[]
    end
    for group in m.groups
        group.pid==PID_LE_RIB || continue
        nn=group.kind==:tria ? 3 : 4
        for e in 1:n_elements(group)
            ids=group.conn[nn*(e-1)+1:nn*e]
            row=m.node_keys[first(ids)][2]
            haskey(byrow,row) || continue
            push!(byrow[row]["eids"],group.eids[e])
            append!(byrow[row]["nodes"],ids.-1)
        end
    end
    for record in records
        sort!(unique!(record["eids"]));sort!(unique!(record["nodes"]))
    end
    return records
end

"""Reject folded discrete shells in addition to the continuous row-order check."""
function validate_oriented_le_elements(m::Model)
    ordinary=!(isdefined(@__MODULE__,:oriented_ribs) && oriented_ribs(m.grid)) &&
        all(get(record,"effective_mode","flight_direction")=="flight_direction" for record in leading_edge_stored_metadata(m))
    ordinary && return
    for group in m.groups
        group.pid in (PID_LE_SKIN,PID_LE_RIB) || continue
        for e in 1:n_elements(group)
            points = element_points(m,group,e)
            corners = length(points)==3 ? ((1,2,3),) : ((1,2,3),(2,3,4),(3,4,1),(4,1,2))
            normals = [cross3(points[b].-points[a],points[c].-points[a]) for (a,b,c) in corners]
            all(norm3(n)>1e-16*m.wing.chord_root^2 for n in normals) &&
                all(sum(first(normals).*n)>0 for n in normals) || throw(ArgumentError(
                    "angled leading-edge shell EID $(group.eids[e]) is folded or collapsed. Adjust the rib angle, geometry, or mesh refinement"))
            if group.pid==PID_LE_RIB
                nn=group.kind==:tria ? 3 : 4
                j=m.node_keys[group.conn[nn*(e-1)+1]][2]
                plane=leading_edge_effective_rib_plane(m,j)
                all(sum(n.*plane.normal)<0 for n in normals) || throw(ArgumentError(
                    "$(leading_edge_row_label(m.grid,j)) reverses inside the wing; adjust its angle or the front-spar geometry"))
            end
        end
    end
end
