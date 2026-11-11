# Unit-independent geometry for the FE editing workspace. Source-deck semantics
# (loads, offsets, coordinate systems and material directions) belong to the
# adapter; this layer preserves arbitrary record attributes and reports lineage.
using LinearAlgebra: dot, norm, cross

const FE_EDIT_SHELL_TYPES = Set(("CTRIA3", "CQUAD4"))
const FE_EDIT_LINE_TYPES = Set(("CBAR", "CBEAM", "CROD", "CONROD", "CTUBE"))

function _fe_edit_xyz(value, label)
    length(value) == 3 || throw(ArgumentError("$label needs three coordinates."))
    xyz = Float64[value[1], value[2], value[3]]
    all(isfinite, xyz) || throw(ArgumentError("$label must contain finite values."))
    xyz
end

function _fe_edit_validate(mesh)
    nodes = mesh["nodes"]
    _fe_edit_validate_nodes(nodes)
    _fe_edit_validate_elements(mesh["elements"],nodes)
    _fe_edit_validate_links(get(mesh,"rigid_links",Any[]),nodes)
    nothing
end

function _fe_edit_validate_nodes(nodes)
    for (id, xyz) in nodes
        Int(id) > 0 || throw(ArgumentError("Node IDs must be positive integers."))
        _fe_edit_finite_point(xyz) || throw(ArgumentError("Node $id needs three finite coordinates representable in model units."))
    end
end

function _fe_edit_validate_elements(elements,nodes)
    seen = Set{Int}()
    for record in elements
        id = Int(record["id"])
        id > 0 && !(id in seen) || throw(ArgumentError("Duplicate or invalid element ID $id."))
        push!(seen, id)
        for node in _fe_edit_node_ids(record)
            haskey(nodes, Int(node)) || throw(ArgumentError("Element $id references missing node $node."))
        end
    end
end

function _fe_edit_validate_links(links,nodes)
    for record in links,node in _fe_edit_node_ids(record)
        haskey(nodes,Int(node)) || throw(ArgumentError("Rigid connection $(record["id"]) references missing node $node."))
    end
end

@inline function _fe_edit_finite_point(xyz)
    length(xyz)==3||return false
    for k in 1:3
        value=xyz[k]
        value isa Real&&isfinite(value)&&isfinite(Float64(value))||return false
    end
    true
end

@inline _fe_edit_point_copy(xyz)=Float64[xyz[1],xyz[2],xyz[3]]
@inline function _fe_edit_node_ids(e)
    ids=e["nodes"]
    ids isa Vector{Int} ? ids : Int.(collect(ids))::Vector{Int}
end
@inline _fe_edit_project(xyz,origin,axis)=(xyz[1]-origin[1])*axis[1]+(xyz[2]-origin[2])*axis[2]+(xyz[3]-origin[3])*axis[3]
@inline _fe_edit_signed_distance(xyz,plane)=_fe_edit_project(xyz,plane.origin,plane.normal)

function _fe_edit_element_side(ids,nodes,plane,tol)
    mask=0
    for id in ids
        d=_fe_edit_signed_distance(nodes[id],plane)
        if d>tol
            mask|=1
        elseif d< -tol
            mask|=2
        end
        mask==3&&return mask
    end
    mask
end

function _fe_edit_element_range(ids,nodes,plane)
    lower=Inf;upper=-Inf
    for id in ids
        d=_fe_edit_signed_distance(nodes[id],plane)
        lower=min(lower,d);upper=max(upper,d)
    end
    lower,upper
end

function _fe_edit_remap_nodes!(record,mapping)
    ids=record["nodes"]
    if ids isa Vector{Int}
        for i in eachindex(ids);ids[i]=get(mapping,ids[i],ids[i]);end
    else
        record["nodes"]=[get(mapping,Int(id),Int(id)) for id in ids]
    end
end

function _fe_edit_clone(mesh)
    # Clone each large collection once. Deep-copying the complete mesh first
    # and then replacing these collections doubles both allocations and work.
    result = Dict{String,Any}(String(k) => deepcopy(v) for (k,v) in mesh if k!="nodes"&&k!="elements")
    result["nodes"] = _fe_edit_clone_nodes(mesh["nodes"])
    result["elements"] = _fe_edit_clone_elements(mesh["elements"])
    result
end

_fe_edit_clone_nodes(nodes)=Dict{Int,Vector{Float64}}(Int(id)=>_fe_edit_point_copy(xyz) for (id,xyz) in nodes)
_fe_edit_clone_elements(elements)=Dict{String,Any}[Dict{String,Any}(String(k)=>deepcopy(v) for (k,v) in e) for e in elements]

function _fe_edit_tolerance(mesh, tolerance)
    if tolerance !== nothing
        value = Float64(tolerance)
        isfinite(value) && value > 0 || throw(ArgumentError("The geometry tolerance must be finite and positive in model units."))
        return value
    end
    isempty(mesh["nodes"]) && return 1e-9
    lower = fill(Inf, 3); upper = fill(-Inf, 3); absolute = 0.0
    for xyz in values(mesh["nodes"]), k in 1:3
        value = Float64(xyz[k]); lower[k] = min(lower[k], value); upper[k] = max(upper[k], value)
        absolute = max(absolute, abs(value))
    end
    # Translation-independent scale, with a roundoff floor for remote coordinates.
    max(norm(upper - lower) * 1e-10, eps(max(absolute, 1.0)) * 32, 1e-12)
end

_fe_edit_type(e) = uppercase(String(e["type"]))
_fe_edit_next_node(mesh) = max(Int(get(mesh,"next_node_id",1)),isempty(mesh["nodes"]) ? 1 : maximum(keys(mesh["nodes"])) + 1)
function _fe_edit_next_element(mesh)
    max(Int(get(mesh,"next_element_id",1)),maximum((Int(e["id"]) for key in ("elements", "rigid_links") for e in get(mesh,key,Any[])); init=0) + 1)
end

function _fe_edit_plane(point, normal, side_length)
    origin = _fe_edit_xyz(point, "The plane point")
    n = _fe_edit_xyz(normal, "The plane normal")
    norm(n) > 0 || throw(ArgumentError("The plane normal cannot be zero."))
    n ./= norm(n)
    side = Float64(side_length)
    isfinite(side) && side > 0 || throw(ArgumentError("The cutting-plane side length must be finite and positive."))
    axis = zeros(3); axis[argmin(abs.(n))] = 1.0
    u = cross(n, axis); u ./= norm(u); v = cross(n,u)
    (origin=origin, normal=n, u=u, v=v, half=side/2)
end

function _fe_edit_segment_in_window(a, b, plane, tolerance)
    # Liang–Barsky clipping in the square's two local axes.
    amin = 0.0; amax = 1.0
    for axis in (plane.u, plane.v)
        q = _fe_edit_project(a,plane.origin,axis); delta = _fe_edit_project(b,a,axis)
        if abs(delta) <= tolerance
            abs(q) <= plane.half+tolerance || return false
        else
            lo = (-plane.half-tolerance-q)/delta; hi = (plane.half+tolerance-q)/delta
            amin = max(amin,min(lo,hi)); amax = min(amax,max(lo,hi))
            amin <= amax || return false
        end
    end
    true
end

_fe_edit_inside_window(p, plane, tolerance) =
    abs(_fe_edit_project(p,plane.origin,plane.u)) <= plane.half+tolerance && abs(_fe_edit_project(p,plane.origin,plane.v)) <= plane.half+tolerance

function _fe_edit_clean_polygon(ids)
    result = Int[]
    for id in ids
        isempty(result) || last(result) != id || continue
        push!(result,id)
    end
    length(result)>1 && first(result)==last(result) && pop!(result)
    result
end

function _fe_edit_area(ids, nodes)
    length(ids) < 3 && return 0.0
    p = nodes[first(ids)]
    sum(norm(cross(nodes[ids[i]]-p,nodes[ids[i+1]]-p))/2 for i in 2:length(ids)-1)
end

function _fe_edit_fragments(ids, nodes, tolerance, eid)
    ids = _fe_edit_clean_polygon(ids)
    length(unique(ids)) == length(ids) || throw(ArgumentError("Element $eid has repeated polygon vertices after cutting; review its connectivity."))
    length(ids) >= 3 || return Vector{Int}[]
    _fe_edit_area(ids,nodes) > tolerance^2 || throw(ArgumentError("The cut would collapse element $eid; move the plane farther from a vertex or reduce the geometry tolerance."))
    length(ids) <= 4 && return [ids]
    # A clipped convex quad has at most five vertices. Choose the fan whose
    # smallest triangle area is largest, avoiding an unnecessarily thin fan.
    best = Vector{Int}[]; best_quality = -Inf
    for anchor in eachindex(ids)
        ordered = circshift(ids,1-anchor)
        trial = [[ordered[1],ordered[i],ordered[i+1]] for i in 2:length(ids)-1]
        quality = minimum(_fe_edit_area(tri,nodes) for tri in trial)
        if quality > best_quality
            best = trial; best_quality = quality
        end
    end
    best_quality > tolerance^2 || throw(ArgumentError("The cut would create a collapsed triangle from element $eid; move the plane or refine that region first."))
    best
end

function _fe_edit_convex_shell(ids,nodes,tolerance,eid)
    length(ids)==3 && return
    p = nodes[ids[1]]
    face_normal = cross(nodes[ids[2]]-p,nodes[ids[3]]-p) + cross(nodes[ids[3]]-p,nodes[ids[4]]-p)
    norm(face_normal)>tolerance^2 || throw(ArgumentError("CQUAD4 $eid is collapsed or self-intersecting; repair it before cutting."))
    signs = [dot(cross(nodes[ids[mod1(i+1,4)]]-nodes[ids[i]],nodes[ids[mod1(i+2,4)]]-nodes[ids[mod1(i+1,4)]]),face_normal) for i in 1:4]
    minimum(signs) >= -tolerance^2*norm(face_normal) || throw(ArgumentError("CQUAD4 $eid is concave or inverted; triangulate or repair it before cutting."))
end

function _fe_edit_sides(elements,nodes,plane,tolerance)
    sides = Dict(key=>Int[] for key in ("positive","negative","coplanar","crossing"))
    for e in elements
        side=_fe_edit_element_side(_fe_edit_node_ids(e),nodes,plane,tolerance)
        key = side==3 ? "crossing" : side==1 ? "positive" : side==2 ? "negative" : "coplanar"
        push!(sides[key],Int(e["id"]))
    end
    sides
end

function _fe_edit_quality_warnings(elements,nodes,changed_ids,tolerance)
    warnings=String[]
    for e in elements
        Int(e["id"]) in changed_ids||continue
        ids=Int.(e["nodes"]);typ=_fe_edit_type(e)
        if typ in FE_EDIT_LINE_TYPES
            length=norm(nodes[ids[2]]-nodes[ids[1]])
            length>10tolerance || push!(warnings,"$typ $(e["id"]) is only $(length) model units long after the cut. Move the plane away from that beam end before solving.")
        elseif typ in FE_EDIT_SHELL_TYPES
            lengths=[norm(nodes[ids[mod1(i+1,Base.length(ids))]]-nodes[ids[i]]) for i in eachindex(ids)]
            minangle=180.0
            for i in eachindex(ids)
                a=nodes[ids[mod1(i-1,Base.length(ids))]]-nodes[ids[i]]
                b=nodes[ids[mod1(i+1,Base.length(ids))]]-nodes[ids[i]]
                denominator=norm(a)*norm(b)
                angle=denominator>0 ? acosd(clamp(dot(a,b)/denominator,-1.,1.)) : 0.0
                minangle=min(minangle,angle)
            end
            ratio=maximum(lengths)/minimum(lengths)
            if minangle<5 || ratio>100 || minimum(lengths)<=10tolerance
                push!(warnings,"$typ $(e["id"]) has a $(round(minangle;digits=2)) degree minimum corner and $(round(ratio;digits=2)) edge ratio after the cut. Move the plane away from the nearby vertex or refine this region before solving.")
            end
        end
    end
    warnings
end

function _fe_edit_rigid_cut_groups(links,physical,positive,negative,coplanar,nodes,plane,tol)
    parents=Dict(i=>i for i in eachindex(links));orphan_owner=Dict{Int,Int}()
    for (index,link) in enumerate(links),id in Int.(link["nodes"])
        id in physical&&continue
        haskey(orphan_owner,id) ? _fe_edit_union!(parents,index,orphan_owner[id]) : (orphan_owner[id]=index)
    end
    groups=Dict{Int,Vector{Int}}()
    for index in eachindex(links)
        push!(get!(groups,_fe_edit_find!(parents,index),Int[]),index)
    end
    positive_links=Set{Int}();retained_links=Set{Int}()
    for group in values(groups)
        refs=Set(Int(id) for index in group for id in links[index]["nodes"])
        footprint=intersect(refs,physical)
        distance(id)=_fe_edit_signed_distance(nodes[id],plane)
        if isempty(footprint)
            pos=any(id->distance(id)>tol,refs);neg=any(id->distance(id)<-tol,refs)
            pos&&!neg&&union!(positive_links,group)
            ambiguous=pos&&neg||!pos&&!neg
        else
            owned=all(id->id in positive,footprint)&&any(id->distance(id)>tol,footprint)
            if owned
                union!(positive_links,group);continue
            end
            stationary=all(id->id in negative||id in coplanar,footprint)&&any(id->distance(id)<-tol,footprint)
            ambiguous=!stationary
        end
        ambiguous||continue
        # A finite cut never detaches an unrelated connection elsewhere on the
        # infinite plane. Intersect actual reference-to-footprint lines here.
        relevant=any(id->abs(distance(id))<=tol&&_fe_edit_inside_window(nodes[id],plane,tol),refs)
        if !relevant
            for index in group
                ids=Int.(links[index]["nodes"]);isempty(ids)&&continue
                a=first(ids);da=distance(a)
                for b in ids[2:end]
                    db=distance(b)
                    if da*db<0
                        p=nodes[a]+(da/(da-db))*(nodes[b]-nodes[a])
                        if _fe_edit_inside_window(p,plane,tol)
                            relevant=true;break
                        end
                    end
                end
                relevant&&break
            end
        end
        relevant&&union!(retained_links,group)
    end
    (positive=positive_links,retained=retained_links)
end

"""Cut linear shell/beam elements by a finite square, without mutating `mesh`.

The contract is `nodes => Dict(id => xyz)` and `elements => records` with
`id`, `type`, and ordered `nodes`; arbitrary other fields are preserved.
Unsupported elements crossing the square are rejected. The source adapter
must propagate element-local loads, material axes and beam end conventions
using `report["element_parents"]` and `report["node_provenance"]`.
"""
function fe_cut_mesh(mesh; point, normal, side_length, duplicate_cut_nodes=false, tolerance=nothing)
    _fe_edit_validate(mesh)
    tol = _fe_edit_tolerance(mesh,tolerance); plane = _fe_edit_plane(point,normal,side_length)
    result = _fe_edit_clone(mesh); nodes = result["nodes"]::Dict{Int,Vector{Float64}}
    next_node = _fe_edit_next_node(result); next_element = _fe_edit_next_element(result)
    cache = Dict{Tuple{Int,Int},Int}(); provenance = Dict{Int,Any}(); parents = Dict{Int,Int}()
    cut_nodes = Set{Int}(); split_ids = Int[]; output = Dict{String,Any}[]
    function distance(id)
        d = _fe_edit_signed_distance(nodes[id],plane)
        abs(d)<=tol ? 0.0 : d
    end
    function edge_intersect(a,b)
        da=distance(a); db=distance(b)
        da==0 && return a
        db==0 && return b
        key=minmax(a,b)
        get!(cache,key) do
            fraction=da/(da-db); id=next_node; next_node+=1
            nodes[id]=nodes[a]+fraction*(nodes[b]-nodes[a])
            provenance[id]=Dict("edge"=>[a,b],"fraction"=>fraction)
            id
        end
    end
    function clip(ids,sign)
        clipped=Int[]
        for i in eachindex(ids)
            a=ids[i]; b=ids[mod1(i+1,length(ids))]
            da=sign*distance(a); db=sign*distance(b)
            da>=0 && push!(clipped,a)
            da*db<0 && push!(clipped,edge_intersect(a,b))
        end
        _fe_edit_clean_polygon(clipped)
    end
    for e in result["elements"]
        ids=_fe_edit_node_ids(e); eid=Int(e["id"])
        if _fe_edit_element_side(ids,nodes,plane,tol)!=3
            push!(output,e); continue
        end
        typ=_fe_edit_type(e)
        supported_shell=typ in FE_EDIT_SHELL_TYPES && length(ids)==(typ=="CTRIA3" ? 3 : 4)
        supported_line=typ in FE_EDIT_LINE_TYPES && length(ids)==2
        if !(supported_shell || supported_line)
            # Conservative projected bounding-box exclusion keeps distant,
            # untouched solids/high-order elements byte-preservable.
            overlaps=true
            for axis in (plane.u,plane.v)
                projected=[_fe_edit_project(nodes[id],plane.origin,axis) for id in ids]
                overlaps &= minimum(projected)<=plane.half+tol && maximum(projected)>=-plane.half-tol
            end
            overlaps && throw(ArgumentError("The cutting plane intersects unsupported $typ element $eid. Cut supports CTRIA3/CQUAD4 and linear beams/rods; move or reduce the plane, or convert the intersected solid/high-order region first. No model changes were applied."))
            push!(output,e); continue
        end
        supported_shell && _fe_edit_convex_shell(ids,nodes,tol,eid)
        intersection_ids=Int[]
        edges=supported_line ? [(ids[1],ids[2])] : [(ids[i],ids[mod1(i+1,length(ids))]) for i in eachindex(ids)]
        for (a,b) in edges
            da=distance(a);db=distance(b)
            da==0 && push!(intersection_ids,a)
            db==0 && push!(intersection_ids,b)
            da*db<0 && push!(intersection_ids,edge_intersect(a,b))
        end
        unique!(intersection_ids)
        intersection_points=[nodes[id] for id in intersection_ids]
        length(intersection_points)>2 && throw(ArgumentError("The cut through $typ $eid has more than two intersection points. Its warp is too large for an unambiguous linear cut; triangulate or refine this face first."))
        touches = supported_line ? _fe_edit_inside_window(first(intersection_points),plane,tol) :
            length(intersection_points)==2 && _fe_edit_segment_in_window(intersection_points[1],intersection_points[2],plane,tol)
        if !touches
            # Intersections created speculatively on untouched edges are pruned.
            push!(output,e); continue
        end
        all(p->_fe_edit_inside_window(p,plane,tol),intersection_points) || throw(ArgumentError("The square cutting plane only partly covers $typ element $eid. Increase its side length or move its centre so the complete intersection lies inside the square. No model changes were applied."))
        union!(cut_nodes,intersection_ids); push!(split_ids,eid)
        parts=Vector{Int}[]
        if supported_line
            node=only(intersection_ids)
            push!(parts,[ids[1],node],[node,ids[2]])
        else
            append!(parts,_fe_edit_fragments(clip(ids,1),nodes,tol,eid))
            append!(parts,_fe_edit_fragments(clip(ids,-1),nodes,tol,eid))
        end
        for (index,conn) in enumerate(parts)
            fragment=deepcopy(e)
            new_id=index==1 ? eid : next_element
            index>1 && (next_element+=1)
            fragment["id"]=new_id; fragment["nodes"]=conn
            supported_shell && (fragment["type"]=length(conn)==3 ? "CTRIA3" : "CQUAD4")
            fragment["parent_id"]=get(e,"parent_id",eid)
            parents[new_id]=eid; push!(output,fragment)
        end
    end
    result["elements"]=output
    # Do not retain unused speculative edge intersections outside the square.
    used=Set(Int(id) for e in output for id in e["nodes"])
    for id in collect(keys(provenance))
        id in used && continue
        delete!(nodes,id); delete!(provenance,id)
    end
    sides=_fe_edit_sides(output,nodes,plane,tol)
    duplicate_nodes=Dict{Int,Int}();detached_rigid_nodes=Dict{Int,Int}()
    retained_rigid_ids=Int[];retained_rigid_reference_nodes=Int[]
    if duplicate_cut_nodes
        positive_ids=Set(sides["positive"]); negative_ids=Set(sides["negative"])
        coplanar_ids=Set(sides["coplanar"])
        positive_nodes=Set{Int}();negative_nodes=Set{Int}();coplanar_nodes=Set{Int}();crossing_nodes=Set{Int}()
        for e in output
            eid=Int(e["id"]);ids=_fe_edit_node_ids(e)
            target=eid in positive_ids ? positive_nodes : eid in negative_ids ? negative_nodes : eid in coplanar_ids ? coplanar_nodes : crossing_nodes
            union!(target,ids)
        end
        links=get(result,"rigid_links",Any[])
        physical=isempty(links) ? Set{Int}() : union(positive_nodes,negative_nodes,coplanar_nodes,crossing_nodes)
        ownership=_fe_edit_rigid_cut_groups(links,physical,positive_nodes,negative_nodes,coplanar_nodes,nodes,plane,tol)
        retained_rigid_ids=sort!([Int(links[index]["id"]) for index in ownership.retained])
        retained_rigid_reference_nodes=sort!(collect(Set(Int(id) for index in ownership.retained for id in links[index]["nodes"])))
        retained_refs=Set(retained_rigid_reference_nodes)
        rigid_detach=intersect(positive_nodes,retained_refs)
        boundary=sort!([id for id in intersect(positive_nodes,union(negative_nodes,coplanar_nodes)) if abs(_fe_edit_signed_distance(nodes[id],plane))<=tol && _fe_edit_inside_window(nodes[id],plane,tol)])
        for id in sort!(collect(union(Set(boundary),rigid_detach)))
            duplicate_nodes[id]=next_node; nodes[next_node]=copy(nodes[id]);next_node+=1
            id in rigid_detach&&(detached_rigid_nodes[id]=duplicate_nodes[id])
        end
        union!(cut_nodes,boundary)
        for e in output
            Int(e["id"]) in positive_ids || continue
            _fe_edit_remap_nodes!(e,duplicate_nodes)
        end
        # Retained connections keep all original GRIDs and all original DOF
        # semantics. Positive-owned links follow the same aliases as structure.
        for index in ownership.positive
            _fe_edit_remap_nodes!(links[index],duplicate_nodes)
        end
    end
    result["next_node_id"]=next_node;result["next_element_id"]=next_element
    warnings=_fe_edit_quality_warnings(output,nodes,Set(keys(parents)),tol)
    if !isempty(sides["coplanar"])
        push!(warnings,"$(length(sides["coplanar"])) element(s) lie in the cutting plane and were retained without splitting. Coplanar elements keep the original seam nodes; when seam nodes are duplicated, these elements remain on the original/negative side.")
    end
    if !isempty(retained_rigid_ids)
        push!(warnings,"$(length(retained_rigid_ids)) coplanar or spanning rigid connection(s) remain at their original GRIDs: $(join(retained_rigid_ids,", ")). Positive-side structure uses $(length(detached_rigid_nodes)) separate attachment aliases, including off-plane attachments where required. Translation leaves these retained connections fixed. Review and explicitly equivalence suitable coincident nodes when rebuilding the joint.")
    end
    report=Dict{String,Any}("operation"=>"cut","split_elements"=>split_ids,"element_parents"=>parents,
        "node_provenance"=>provenance,"cut_nodes"=>sort!(collect(cut_nodes)),"duplicate_nodes"=>duplicate_nodes,
        "side_elements"=>sides,"retained_rigid_ids"=>retained_rigid_ids,"retained_rigid_reference_nodes"=>retained_rigid_reference_nodes,
        "detached_rigid_nodes"=>detached_rigid_nodes,"tolerance"=>tol,"plane_point"=>plane.origin,"plane_normal"=>plane.normal,
        "plane_u"=>plane.u,"plane_v"=>plane.v,"side_length"=>2plane.half,"warnings"=>warnings,"coplanar_policy"=>"retain_original_nodes")
    (mesh=result,report=report)
end

"""Classify elements without editing; crossing elements are never silently selected."""
function fe_classify_mesh(mesh;point,normal,tolerance=nothing)
    _fe_edit_validate(mesh);tol=_fe_edit_tolerance(mesh,tolerance)
    plane=_fe_edit_plane(point,normal,1.0)
    _fe_edit_sides(mesh["elements"],mesh["nodes"],plane,tol)
end

function _fe_edit_clipped_segment(a,b,plane,tol)
    lower=0.0;upper=1.0
    for axis in (plane.u,plane.v)
        q=_fe_edit_project(a,plane.origin,axis);delta=_fe_edit_project(b,a,axis)
        if abs(delta)<=tol
            abs(q)<=plane.half+tol||return nothing
        else
            left=(-plane.half-q)/delta;right=(plane.half-q)/delta
            lower=max(lower,min(left,right));upper=min(upper,max(left,right))
            lower<=upper||return nothing
        end
    end
    (a+lower.*(b-a),a+upper.*(b-a))
end

"""Return the actual finite-plane intersections of linear shell/beam geometry.

No IDs or coordinates are changed. Segments are clipped to the square; point
intersections (including beams) are returned separately. Unsupported curved
or solid element intersections are reported, rather than drawing a fictitious
straight-edge contour. Coplanar shell outlines and on-plane edges are included.
"""
function fe_cut_intersections(mesh;point,normal,side_length,tolerance=nothing)
    _fe_edit_validate(mesh);tol=_fe_edit_tolerance(mesh,tolerance)
    plane=_fe_edit_plane(point,normal,side_length)
    nodes=mesh["nodes"]
    segments=Vector{Vector{Float64}}[];points=Vector{Float64}[]
    intersected=Set{Int}();partial=Set{Int}();unsupported=Set{Int}()
    segment_keys=Set{Tuple{NTuple{3,Int},NTuple{3,Int}}}();point_keys=Set{NTuple{3,Int}}()
    key(p)=ntuple(k->round(Int,(p[k]-plane.origin[k])/tol),3)
    function addpoint(p,eid)
        _fe_edit_inside_window(p,plane,tol)||return
        k=key(p)
        k in point_keys||(push!(point_keys,k);push!(points,p))
        push!(intersected,eid)
    end
    function addsegment(a,b,eid)
        clipped=_fe_edit_clipped_segment(a,b,plane,tol);clipped===nothing&&return
        p,q=clipped
        if norm(p-q)<=tol
            addpoint(p,eid);return
        end
        ka=key(p);kb=key(q);segment_key=isless(ka,kb) ? (ka,kb) : (kb,ka)
        segment_key in segment_keys||(push!(segment_keys,segment_key);push!(segments,[p,q]))
        push!(intersected,eid)
        (!_fe_edit_inside_window(a,plane,tol)||!_fe_edit_inside_window(b,plane,tol))&&push!(partial,eid)
    end
    for e in mesh["elements"]
        ids=_fe_edit_node_ids(e);eid=Int(e["id"])
        isempty(ids)&&continue
        lower,upper=_fe_edit_element_range(ids,nodes,plane)
        (lower>tol||upper< -tol)&&continue
        typ=_fe_edit_type(e)
        ds=[_fe_edit_signed_distance(nodes[id],plane) for id in ids]
        shell=typ in FE_EDIT_SHELL_TYPES&&length(ids)==(typ=="CTRIA3" ? 3 : 4)
        line=typ in FE_EDIT_LINE_TYPES&&length(ids)==2
        if !(shell||line)
            if any(>(tol),ds)&&any(<(-tol),ds)
                overlaps=all(axis->begin
                    projected=[_fe_edit_project(nodes[id],plane.origin,axis) for id in ids]
                    minimum(projected)<=plane.half+tol&&maximum(projected)>=-plane.half-tol
                end,(plane.u,plane.v))
                overlaps&&push!(unsupported,eid)
            elseif length(ids)==1&&abs(first(ds))<=tol
                addpoint(_fe_edit_point_copy(nodes[first(ids)]),eid)
            end
            continue
        end
        edges=line ? [(1,2)] : [(i,mod1(i+1,length(ids))) for i in eachindex(ids)]
        intersections=Vector{Float64}[]
        for (ia,ib) in edges
            a=ids[ia];b=ids[ib];da=abs(ds[ia])<=tol ? 0.0 : ds[ia];db=abs(ds[ib])<=tol ? 0.0 : ds[ib]
            if da==0&&db==0
                addsegment(_fe_edit_point_copy(nodes[a]),_fe_edit_point_copy(nodes[b]),eid)
            else
                da==0&&push!(intersections,_fe_edit_point_copy(nodes[a]));db==0&&push!(intersections,_fe_edit_point_copy(nodes[b]))
                da*db<0&&push!(intersections,_fe_edit_point_copy(nodes[a])+(da/(da-db)).*(_fe_edit_point_copy(nodes[b])-_fe_edit_point_copy(nodes[a])))
            end
        end
        unique_points=Vector{Float64}[]
        for p in intersections
            any(q->norm(p-q)<=tol,unique_points)||push!(unique_points,p)
        end
        if length(unique_points)==2
            addsegment(unique_points[1],unique_points[2],eid)
        elseif length(unique_points)==1
            addpoint(only(unique_points),eid)
        elseif length(unique_points)>2
            # A warped quad may meet a plane in multiple disjoint branches.
            # Do not invent a contour by joining those points in arbitrary order.
            push!(unsupported,eid)
        end
    end
    warnings=String[]
    isempty(partial)||push!(warnings,"$(length(partial)) element intersection(s) extend beyond the finite square. The preview is clipped; enlarge the plane before cutting those elements.")
    isempty(unsupported)||push!(warnings,"$(length(unsupported)) intersected solid, higher-order or strongly warped element(s) cannot be represented by a unique supported linear-shell cutting contour: $(join(sort!(collect(unsupported)),", ")).")
    Dict{String,Any}("segments"=>segments,"points"=>points,"intersected_elements"=>sort!(collect(intersected)),
        "partial_elements"=>sort!(collect(partial)),"unsupported_elements"=>sort!(collect(unsupported)),"warnings"=>warnings,
        "tolerance"=>tol,"plane_point"=>plane.origin,"plane_normal"=>plane.normal,"plane_u"=>plane.u,"plane_v"=>plane.v,"side_length"=>2plane.half)
end

fe_preview_cut_segments(mesh;kwargs...)=fe_cut_intersections(mesh;kwargs...)

"""Select a complete half-space or a complete slab in signed-distance units."""
function fe_select_mesh(mesh;point,normal,side="positive",lower=nothing,upper=nothing,tolerance=nothing)
    side=lowercase(String(side))
    if side in ("positive","negative","coplanar","crossing")
        return fe_classify_mesh(mesh;point,normal,tolerance)[side]
    end
    side=="slab"||throw(ArgumentError("Select positive, negative, coplanar, crossing, or slab."))
    _fe_edit_validate(mesh);tol=_fe_edit_tolerance(mesh,tolerance);plane=_fe_edit_plane(point,normal,1.0)
    lower!==nothing&&upper!==nothing||throw(ArgumentError("A slab selection needs both lower and upper signed distances."))
    lo=Float64(lower);hi=Float64(upper)
    isfinite(lo)&&isfinite(hi)&&lo<hi||throw(ArgumentError("The slab lower distance must be smaller than its upper distance."))
    selected=Int[]
    for e in mesh["elements"]
        all(id->lo-tol<=dot(_fe_edit_xyz(mesh["nodes"][id],"Node $id")-plane.origin,plane.normal)<=hi+tol,e["nodes"])&&push!(selected,Int(e["id"]))
    end
    selected
end

function _fe_edit_selection(mesh,element_ids)
    selected=Set(Int.(collect(element_ids)))
    isempty(selected) && throw(ArgumentError("Select at least one element or cut part first."))
    known=Set(Int(e["id"]) for e in mesh["elements"])
    missing=setdiff(selected,known)
    isempty(missing) || throw(ArgumentError("The selection refers to missing element IDs: $(join(sort!(collect(missing)),", "))."))
    selected
end

_fe_edit_selected_nodes(mesh,selected)=_fe_edit_selected_nodes_impl(mesh["elements"],get(mesh,"rigid_links",Any[]),selected)
function _fe_edit_selected_nodes_impl(elements,links,selected)
    nodes=Set(id for e in elements if Int(e["id"]) in selected for id in _fe_edit_node_ids(e))
    isempty(links)&&return (nodes=nodes,auxiliary_nodes=Int[])
    physical=Set(id for e in elements for id in _fe_edit_node_ids(e))
    incidence=Dict{Int,Vector{Int}}()
    for (index,link) in enumerate(links),id in Int.(link["nodes"])
        id in physical&&continue
        push!(get!(incidence,id,Int[]),index)
    end
    visited=Set{Int}();auxiliary=Int[]
    # A connected component of orphan reference/auxiliary nodes has one complete
    # physical footprint. Include it only when that entire footprint is selected.
    # This handles nested rigid spiders without repeated full-model rescans.
    for initial in keys(incidence)
        initial in visited&&continue
        pending=Int[initial];component=Int[];footprint=Set{Int}();seen_links=Set{Int}();cursor=1
        push!(visited,initial)
        while cursor<=length(pending)
            id=pending[cursor];cursor+=1;push!(component,id)
            for index in incidence[id]
                index in seen_links&&continue
                push!(seen_links,index)
                for ref in Int.(links[index]["nodes"])
                    if ref in physical
                        push!(footprint,ref)
                    elseif !(ref in visited)
                        push!(visited,ref);push!(pending,ref)
                    end
                end
            end
        end
        if !isempty(footprint)&&all(id->id in nodes,footprint)
            union!(nodes,component);append!(auxiliary,component)
        end
    end
    (nodes=nodes,auxiliary_nodes=sort!(auxiliary))
end

"""Selected element nodes plus rigid auxiliary nodes with a wholly selected footprint."""
function fe_selected_node_closure(mesh,element_ids)
    _fe_edit_validate(mesh)
    _fe_edit_selected_nodes(mesh,_fe_edit_selection(mesh,element_ids))
end

function _fe_edit_translation(;vector=nothing,direction=nothing,distance=nothing)
    if vector!==nothing
        direction===nothing && distance===nothing || throw(ArgumentError("Use a translation vector or a direction and distance, not both."))
        return _fe_edit_xyz(vector,"The translation vector")
    end
    direction!==nothing && distance!==nothing || throw(ArgumentError("Specify a translation vector, or a direction and distance."))
    v=_fe_edit_xyz(direction,"The translation direction"); magnitude=norm(v)
    magnitude>0 || throw(ArgumentError("The translation direction cannot be zero."))
    d=Float64(distance);isfinite(d)||throw(ArgumentError("The translation distance must be finite."))
    (d/magnitude).*v
end

"""Translate a selection while retaining crossing rigid connections at their original GRIDs.

Shared physical element nodes still require explicit `detach_shared`. Selected
attachment nodes of a crossing rigid link get independent aliases; the source
rigid link and all its original coordinates remain unchanged for joint review.
"""
function fe_translate_mesh(mesh,element_ids;vector=nothing,direction=nothing,distance=nothing,detach_shared=false)
    _fe_edit_validate(mesh); selected=_fe_edit_selection(mesh,element_ids)
    delta=_fe_edit_translation(;vector,direction,distance)
    result=_fe_edit_clone(mesh);nodes=result["nodes"]::Dict{Int,Vector{Float64}}
    elements=result["elements"]::Vector{Dict{String,Any}}
    closure=_fe_edit_selected_nodes(result,selected);moved=closure.nodes
    shared=Set(id for e in elements if !(Int(e["id"]) in selected) for id in _fe_edit_node_ids(e) if id in moved)
    duplicate_nodes=Dict{Int,Int}()
    !isempty(shared) && !detach_shared && throw(ArgumentError("The selected part shares $(length(shared)) node(s) with unselected elements. Enable detach shared nodes or cut with duplicated seam nodes before translating."))
    retained=Int[];moving_links=Int[];links=get(result,"rigid_links",Any[])
    for (index,rigid) in enumerate(links)
        refs=Int.(rigid["nodes"]); present=count(id->id in moved,refs)
        if 0<present<length(refs)
            push!(retained,index)
        elseif present>0
            push!(moving_links,index)
        end
    end
    retained_refs=Set(Int(id) for index in retained for id in links[index]["nodes"])
    rigid_detach=intersect(moved,retained_refs)
    detached_rigid_nodes=Dict{Int,Int}()
    next_node=_fe_edit_next_node(result)
    for id in sort!(collect(union(shared,rigid_detach)))
        duplicate_nodes[id]=next_node;nodes[next_node]=copy(nodes[id]);next_node+=1
        id in rigid_detach&&(detached_rigid_nodes[id]=duplicate_nodes[id])
    end
    if !isempty(duplicate_nodes)
        for e in elements
            Int(e["id"]) in selected || continue
            _fe_edit_remap_nodes!(e,duplicate_nodes)
        end
        for index in moving_links
            _fe_edit_remap_nodes!(links[index],duplicate_nodes)
        end
    end
    actual=Set(get(duplicate_nodes,id,id) for id in moved)
    for id in actual
        nodes[id].+=delta
    end
    result["next_node_id"]=next_node
    retained_ids=sort!([Int(links[index]["id"]) for index in retained]);warnings=String[]
    isempty(retained)||push!(warnings,"$(length(retained)) crossing rigid connection(s) remain at their original GRIDs: $(join(retained_ids,", ")). $(length(detached_rigid_nodes)) selected structural attachment node(s) were aliased before translation. The original joint coordinates, DOFs, nodal loads and supports remain on the original GRIDs; review and explicitly equivalence suitable coincident nodes when rebuilding the joint.")
    (mesh=result,report=Dict{String,Any}("operation"=>"translate","selected_elements"=>sort!(collect(selected)),
        "moved_nodes"=>sort!(collect(actual)),"auxiliary_nodes"=>closure.auxiliary_nodes,"duplicate_nodes"=>duplicate_nodes,
        "created_nodes"=>sort!(collect(values(duplicate_nodes))),
        "detached_rigid_nodes"=>detached_rigid_nodes,"retained_rigid_ids"=>retained_ids,
        "retained_rigid_reference_nodes"=>sort!(collect(retained_refs)),"warnings"=>warnings,"vector"=>delta))
end

"""Find selectable physical element components, ignoring rigid connections."""
function fe_structural_components(mesh)
    _fe_edit_validate(mesh)
    _fe_edit_structural_components(mesh["elements"],mesh["nodes"])
end

function _fe_edit_structural_components(elements,nodes)
    parents=Dict(Int(e["id"])=>Int(e["id"]) for e in elements);owner=Dict{Int,Int}()
    for e in elements,id in _fe_edit_node_ids(e)
        eid=Int(e["id"])
        haskey(owner,id) ? _fe_edit_union!(parents,eid,owner[id]) : (owner[id]=eid)
    end
    grouped=Dict{Int,Vector{Int}}();element_nodes=Dict(Int(e["id"])=>_fe_edit_node_ids(e) for e in elements)
    for eid in sort!(collect(keys(parents)))
        push!(get!(grouped,_fe_edit_find!(parents,eid),Int[]),eid)
    end
    parts=Dict{String,Any}[];element_part=Dict{Int,Int}()
    for (index,eids) in enumerate(sort!(collect(values(grouped));by=first))
        ids=sort!(collect(Set(id for eid in eids for id in element_nodes[eid])))
        lower=[minimum(Float64(nodes[id][k]) for id in ids) for k in 1:3]
        upper=[maximum(Float64(nodes[id][k]) for id in ids) for k in 1:3]
        push!(parts,Dict{String,Any}("id"=>index,"element_ids"=>eids,"node_ids"=>ids,
            "element_count"=>length(eids),"node_count"=>length(ids),"bounds"=>Dict("min"=>lower,"max"=>upper)))
        for eid in eids; element_part[eid]=index; end
    end
    Dict{String,Any}("parts"=>parts,"element_part"=>element_part,"rigid_connections_included"=>false)
end

"""Copy selected elements `count` times at successive multiples of a translation."""
function fe_copy_mesh(mesh,element_ids;vector=nothing,direction=nothing,distance=nothing,count=1)
    _fe_edit_validate(mesh);selected=_fe_edit_selection(mesh,element_ids)
    count isa Integer && 1<=count<=1000 || throw(ArgumentError("The number of copies must be an integer from 1 to 1000."))
    delta=_fe_edit_translation(;vector,direction,distance)
    result=_fe_edit_clone(mesh);nodes=result["nodes"]::Dict{Int,Vector{Float64}}
    originals=[e for e in result["elements"] if Int(e["id"]) in selected]
    closure=_fe_edit_selected_nodes(result,selected)
    source_nodes=sort!(collect(closure.nodes))
    node_set=Set(source_nodes);rigids=Any[]
    for rigid in get(result,"rigid_links",Any[])
        refs=Int.(rigid["nodes"]);present=Base.count(id->id in node_set,refs)
        0<present<length(refs) && throw(ArgumentError("Rigid connection $(rigid["id"]) crosses the copied selection. Include its whole connected region or remove that connection before copying."))
        present>0 && push!(rigids,rigid)
    end
    next_node=_fe_edit_next_node(result);next_element=_fe_edit_next_element(result)
    copies=Any[];parents=Dict{Int,Int}();new_elements=Int[]
    for index in 1:count
        mapping=Dict{Int,Int}()
        for id in source_nodes
            mapping[id]=next_node;nodes[next_node]=nodes[id]+index.*delta;next_node+=1
        end
        element_map=Dict{Int,Int}()
        for e in originals
            copy_record=deepcopy(e);eid=next_element;next_element+=1
            element_map[Int(e["id"])]=eid;parents[eid]=Int(e["id"]);push!(new_elements,eid)
            copy_record["id"]=eid;copy_record["nodes"]=[mapping[Int(id)] for id in e["nodes"]]
            copy_record["parent_id"]=get(e,"parent_id",Int(e["id"]))
            push!(result["elements"],copy_record)
        end
        rigid_map=Dict{Int,Int}()
        for rigid in rigids
            copied=deepcopy(rigid);eid=next_element;next_element+=1
            rigid_map[Int(rigid["id"])]=eid;copied["id"]=eid;copied["nodes"]=[mapping[Int(id)] for id in rigid["nodes"]]
            push!(result["rigid_links"],copied)
        end
        push!(copies,Dict("index"=>index,"node_map"=>mapping,"element_map"=>element_map,"rigid_map"=>rigid_map))
    end
    result["next_node_id"]=next_node;result["next_element_id"]=next_element
    warnings=norm(delta)==0 ? ["Copy spacing is zero: the new structure overlaps the source. Review operation coincidences before merging; equivalence must not create duplicate structural elements."] : String[]
    (mesh=result,report=Dict{String,Any}("operation"=>"copy","copies"=>copies,"new_elements"=>new_elements,
        "created_nodes"=>sort!([Int(id) for copy in copies for id in values(copy["node_map"])]),"warnings"=>warnings,
        "element_parents"=>parents,"selected_elements"=>sort!(collect(selected)),"auxiliary_nodes"=>closure.auxiliary_nodes,"vector"=>delta,"count"=>count))
end

function _fe_edit_find!(parents,id)
    root=id
    while parents[root]!=root
        root=parents[root]
    end
    while parents[id]!=id
        next=parents[id];parents[id]=root;id=next
    end
    root
end

function _fe_edit_union!(parents,a,b)
    ra=_fe_edit_find!(parents,a);rb=_fe_edit_find!(parents,b)
    ra==rb || (parents[max(ra,rb)]=min(ra,rb))
end

"""Find retained-master-bounded coincidence groups with a spatial hash.

Every group can be merged to its smallest-ID master without exceeding the
tolerance. A chain of near-neighbours is partitioned rather than proposing a
group whose far end would move too far. Only nearby hash cells are searched;
groups and master/member pairs have linear-size output for superimposed copies.
"""
function fe_equivalence_candidates(mesh;tolerance,node_ids=nothing)
    tol=_fe_edit_tolerance(mesh,tolerance);nodes=mesh["nodes"]
    ids=node_ids===nothing ? sort!(Int.(collect(keys(nodes)))) : sort!(unique(Int.(collect(node_ids))))
    all(id->haskey(nodes,id),ids)||throw(ArgumentError("The equivalence search includes an unknown node."))
    isempty(ids) && return Dict{String,Any}("groups"=>Vector{Int}[],"pairs"=>Vector{Int}[],"tolerance"=>tol,"candidate_nodes"=>0)
    origin=_fe_edit_xyz(nodes[first(ids)],"The hash origin");width=tol/sqrt(3.0)
    buckets=Dict{NTuple{3,Int},Vector{Int}}();keys_by_id=Dict{Int,NTuple{3,Int}}()
    for id in ids
        xyz=nodes[id]
        key=ntuple(k->floor(Int,(Float64(xyz[k])-origin[k])/width),3)
        keys_by_id[id]=key
        bucket=get!(buckets,key,Int[])
        push!(bucket,id)
    end
    tol2=tol^2;remaining=Set(ids);groups=Vector{Int}[]
    for master in ids
        master in remaining||continue
        delete!(remaining,master);group=Int[master];key=keys_by_id[master]
        for dx in -2:2,dy in -2:2,dz in -2:2
            neighbour=(key[1]+dx,key[2]+dy,key[3]+dz)
            for id in get(buckets,neighbour,Int[])
                id in remaining||continue
                sum((Float64(nodes[master][k])-Float64(nodes[id][k]))^2 for k in 1:3)<=tol2 || continue
                push!(group,id);delete!(remaining,id)
            end
        end
        length(group)>1&&push!(groups,sort!(group))
    end
    pairs=[[first(group),id] for group in groups for id in group[2:end]]
    Dict{String,Any}("groups"=>groups,"pairs"=>pairs,"tolerance"=>tol,"candidate_nodes"=>sum(length,groups;init=0),
        "group_count"=>length(groups),"searched_nodes"=>length(ids),"hash_cells"=>length(buckets))
end

@inline _fe_edit_distance2(a,b)=(a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2
function _fe_edit_spatial_key(point,origin,width)
    ntuple(3) do k
        scaled=(point[k]-origin[k])/width
        isfinite(scaled)&&abs(scaled)<typemax(Int)/4||throw(ArgumentError("The coincidence tolerance is too small for the model coordinate range; increase it in model units."))
        floor(Int,scaled)
    end
end

"""Find only coincidences introduced by this move/copy, never global old duplicates.

Groups contain one reviewed stationary survivor and affected nodes, or nodes
from different new-copy cohorts. Nodes in one rigid-motion cohort are never
implicitly merged through a shared anchor. Alternative stationary survivors
are listed separately; they are not included in `nodes`. Ambiguous affected
nodes are left unmerged and reported for explicit review.
"""
function fe_operation_equivalence_candidates(before,after,report;tolerance=nothing)
    tol=_fe_edit_tolerance(after,tolerance)
    _fe_edit_operation_candidates(before["nodes"],after["nodes"],report,tol)
end

function _fe_edit_operation_candidates(before_nodes,after_nodes,report,tol)
    operation=String(get(report,"operation",""));cohorts=Dict{Int,Int}();origins=Dict{Int,Int}()
    if operation=="translate"
        inverse=Dict(Int(new)=>Int(old) for (old,new) in get(report,"duplicate_nodes",Dict()))
        for id in Int.(get(report,"moved_nodes",Int[]))
            cohorts[id]=1;origins[id]=get(inverse,id,id)
        end
    elseif operation=="copy"
        for (index,copy) in enumerate(get(report,"copies",Any[])),(old,new) in copy["node_map"]
            cohorts[Int(new)]=index;origins[Int(new)]=Int(old)
        end
    else
        for id in Int.(get(report,"created_nodes",Int[]));cohorts[id]=id;origins[id]=id;end
    end
    affected=sort!(collect(keys(cohorts)));created=sort!([id for id in affected if !haskey(before_nodes,id)])
    all(id->haskey(after_nodes,id),affected)||throw(ArgumentError("The operation coincidence scope refers to a node missing from the current mesh."))
    emptyresult=Dict{String,Any}("groups"=>Any[],"pairs"=>Vector{Int}[],"affected_nodes"=>affected,"created_nodes"=>created,
        "ambiguous_affected_nodes"=>Int[],"unresolved_affected_count"=>0,"candidate_nodes"=>0,"group_count"=>0,"tolerance"=>tol,"warnings"=>String[])
    isempty(affected)&&return emptyresult
    width=tol/sqrt(3.0);origin=after_nodes[first(affected)];tol2=tol^2;affected_set=Set(affected)
    stationary=Dict{NTuple{3,Int},Vector{Int}}();moving=Dict{NTuple{3,Int},Vector{Int}}()
    for (id,point) in after_nodes
        target=Int(id) in affected_set ? moving : stationary
        push!(get!(target,_fe_edit_spatial_key(point,origin,width),Int[]),Int(id))
    end
    function nearby(buckets,point)
        cell=_fe_edit_spatial_key(point,origin,width);ids=Int[]
        for dx in -2:2,dy in -2:2,dz in -2:2
            key=(cell[1]+dx,cell[2]+dy,cell[3]+dz)
            for id in get(buckets,key,Int[])
                _fe_edit_distance2(point,after_nodes[id])<=tol2&&push!(ids,id)
            end
        end
        sort!(ids)
    end
    skipped_preexisting=0
    function eligible(a,b)
        a==b&&return false
        if haskey(before_nodes,a)&&haskey(before_nodes,b)&&_fe_edit_distance2(before_nodes[a],before_nodes[b])<=tol2
            skipped_preexisting+=1;return false
        end
        haskey(cohorts,a)&&haskey(cohorts,b)&&cohorts[a]==cohorts[b]&&return false
        true
    end
    pending=Set(affected);blocked=Set{Int}();groups=Any[];pairs=Vector{Int}[]
    reviewed_members=Dict{Tuple{Int,NTuple{3,Int}},Vector{Int}}()
    function already_reviewed_neighbour(id)
        cell=_fe_edit_spatial_key(after_nodes[id],origin,width);cohort=cohorts[id]
        for dx in -2:2,dy in -2:2,dz in -2:2
            key=(cohort,(cell[1]+dx,cell[2]+dy,cell[3]+dz))
            for previous in get(reviewed_members,key,Int[])
                _fe_edit_distance2(after_nodes[id],after_nodes[previous])<=tol2&&return true
            end
        end
        false
    end
    multiple_cohorts=length(Set(values(cohorts)))>1
    for id in affected
        id in pending||continue
        anchors=[anchor for anchor in nearby(stationary,after_nodes[id]) if eligible(id,anchor)]
        master=isempty(anchors) ? id : first(anchors)
        members=Int[];used_cohorts=Set{Int}();ambiguous=Int[]
        if isempty(anchors)
            delete!(pending,id)
            multiple_cohorts||continue
            if already_reviewed_neighbour(id)
                push!(blocked,id);continue
            end
            push!(members,id);push!(used_cohorts,cohorts[id])
        end
        for candidate in nearby(moving,after_nodes[master])
            candidate in pending||continue
            eligible(master,candidate)||begin
                if master in affected_set&&cohorts[master]==cohorts[candidate]
                    push!(blocked,candidate);push!(ambiguous,candidate);delete!(pending,candidate)
                end
                continue
            end
            if cohorts[candidate] in used_cohorts||already_reviewed_neighbour(candidate)
                push!(blocked,candidate);push!(ambiguous,candidate);delete!(pending,candidate);continue
            end
            push!(members,candidate);push!(used_cohorts,cohorts[candidate]);delete!(pending,candidate)
        end
        nodes=isempty(anchors) ? sort!(members) : sort!(vcat(master,members))
        length(nodes)>1||continue
        # Every alternative survivor must fit the complete reviewed group.
        alternatives=Int[]
        for anchor in anchors
            all(member->_fe_edit_distance2(after_nodes[anchor],after_nodes[member])<=tol2&&eligible(anchor,member),members)&&push!(alternatives,anchor)
        end
        maxdistance=sqrt(maximum(_fe_edit_distance2(after_nodes[master],after_nodes[node]) for node in nodes))
        group=Dict{String,Any}("id"=>length(groups)+1,"nodes"=>nodes,"retained_node"=>master,"max_distance"=>maxdistance,
            "affected_nodes"=>sort!(members),"anchor_nodes"=>alternatives,"ambiguous"=>length(alternatives)>1||!isempty(ambiguous),
            "ambiguous_affected_nodes"=>sort!(ambiguous))
        push!(groups,group)
        for member in members
            cell=_fe_edit_spatial_key(after_nodes[member],origin,width)
            push!(get!(reviewed_members,(cohorts[member],cell),Int[]),member)
        end
        append!(pairs,[[master,node] for node in nodes if node!=master])
        for anchor in alternatives
            anchor==master&&continue
            append!(pairs,[[anchor,node] for node in members])
        end
    end
    warnings=String[]
    isempty(blocked)||push!(warnings,"$(length(blocked)) affected node(s) were left out of automatic coincidence groups because merging them through a shared survivor could also merge pre-existing nodes from the same rigid-motion region. Review these alternatives explicitly; they remain separate.")
    ambiguous_anchors=count(group->length(group["anchor_nodes"])>1,groups)
    ambiguous_anchors==0||push!(warnings,"$ambiguous_anchors coincidence group(s) have several existing stationary survivor choices. Only the explicitly selected survivor may be merged with the affected nodes; the other existing nodes remain separate.")
    Dict{String,Any}("groups"=>groups,"pairs"=>pairs,"affected_nodes"=>affected,"created_nodes"=>created,
        "ambiguous_affected_nodes"=>sort!(collect(blocked)),"unresolved_affected_count"=>length(blocked),
        "candidate_nodes"=>sum(length(group["nodes"]) for group in groups;init=0),"group_count"=>length(groups),
        "skipped_preexisting_pairs"=>skipped_preexisting,"tolerance"=>tol,"warnings"=>warnings,
        "operation"=>operation,"cohorts"=>cohorts,"source_nodes"=>origins)
end

"""Merge explicitly chosen near-coincident node pairs, transactionally.

The lowest node ID in each transitive group is retained. A chain is rejected
if any member lies farther than the tolerance from that master. Element
collapse and repeated/self-connected rigid references are always rejected.
"""
function fe_merge_nodes(mesh,pairs;tolerance,retained_nodes=Int[])
    _fe_edit_validate(mesh);tol=_fe_edit_tolerance(mesh,tolerance);nodes=mesh["nodes"]
    parents=Dict(Int(id)=>Int(id) for id in keys(nodes))
    for pair in pairs
        length(pair)==2||throw(ArgumentError("Each equivalence pair needs exactly two node IDs."))
        a,b=Int.(pair)
        haskey(nodes,a)&&haskey(nodes,b)||throw(ArgumentError("Equivalence pair $a/$b references a missing node."))
        norm(_fe_edit_xyz(nodes[a],"Node $a")-_fe_edit_xyz(nodes[b],"Node $b"))<=tol || throw(ArgumentError("Nodes $a and $b are farther apart than the equivalence tolerance."))
        _fe_edit_union!(parents,a,b)
    end
    retained_by_root=Dict{Int,Int}()
    for retained in unique(Int.(collect(retained_nodes)))
        haskey(nodes,retained)||throw(ArgumentError("The selected retained node $retained does not exist."))
        root=_fe_edit_find!(parents,retained)
        haskey(retained_by_root,root)&&retained_by_root[root]!=retained&&throw(ArgumentError("One equivalence group has more than one selected survivor. Keep a single retained node for that group."))
        retained_by_root[root]=retained
    end
    mapping=Dict(id=>get(retained_by_root,_fe_edit_find!(parents,id),_fe_edit_find!(parents,id)) for id in keys(parents))
    for (id,master) in mapping
        norm(_fe_edit_xyz(nodes[id],"Node $id")-_fe_edit_xyz(nodes[master],"Node $master"))<=tol || throw(ArgumentError("The transitive equivalence group containing node $id extends beyond the tolerance from master $master. Reduce the tolerance or select smaller groups."))
    end
    result=_fe_edit_clone(mesh)
    structural_signatures=Dict{Any,Tuple{Any,Int}}()
    for key in ("elements","rigid_links"),e in get(result,key,Any[])
        old=Int.(e["nodes"]);conn=[mapping[id] for id in old]
        if length(unique(conn))<length(unique(old))
            throw(ArgumentError("Equivalence would collapse or self-connect $(get(e,"type",key)) $(e["id"]). Keep those nodes separate or remove the conflicting element/rigid connection first. No model changes were applied."))
        end
        e["nodes"]=conn
        if key=="elements"&&(_fe_edit_type(e) in FE_EDIT_SHELL_TYPES||_fe_edit_type(e) in FE_EDIT_LINE_TYPES)
            family=(_fe_edit_type(e),Int(get(e,"pid",0)))
            oldsignature=(family,Tuple(sort(old)));newsignature=(family,Tuple(sort(conn)))
            if haskey(structural_signatures,newsignature)
                previous,previous_eid=structural_signatures[newsignature]
                previous==oldsignature||throw(ArgumentError("Equivalence would superimpose structural elements $previous_eid and $(e["id"]) with the same type/property/connectivity, introducing duplicate stiffness or mass. Move or remove the overlapping copy before merging; no model changes were applied."))
            else
                structural_signatures[newsignature]=(oldsignature,Int(e["id"]))
            end
        end
        if key=="elements" && _fe_edit_type(e) in FE_EDIT_SHELL_TYPES && _fe_edit_area(conn,result["nodes"])<=tol^2
            throw(ArgumentError("Equivalence would collapse shell element $(e["id"]). Reduce the tolerance or exclude its nodes."))
        end
    end
    merged=Dict(id=>master for (id,master) in mapping if id!=master)
    for id in keys(merged)
        delete!(result["nodes"],id)
    end
    (mesh=result,report=Dict{String,Any}("operation"=>"equivalence","node_map"=>merged,"merged_nodes"=>length(merged),"retained_nodes"=>sort!(collect(values(retained_by_root))),"tolerance"=>tol))
end
