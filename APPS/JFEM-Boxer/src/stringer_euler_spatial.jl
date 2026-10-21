# Conservative spatial pruning for Euler section cuts. A plane/slab query
# returns a superset of intersecting faces; exact polygon cutting remains the
# geometry authority. In particular, faces across a rib boundary are retained
# whenever a swept section can reach them.
struct EulerFaceBounds
    center::NTuple{3,Float64}
    half::NTuple{3,Float64}
end

struct EulerFaceNode
    bounds::EulerFaceBounds
    left::Int
    right::Int
    first::Int
    last::Int
end

struct EulerFaceIndex{T}
    faces::Vector{T}
    bounds::Vector{EulerFaceBounds}
    order::Vector{Int}
    nodes::Vector{EulerFaceNode}
    root::Int
end

function euler_face_bounds(points)
    isempty(points)&&throw(ArgumentError("A section candidate face has no geometry"))
    all(p->length(p)==3&&all(isfinite,p),points)||throw(ArgumentError("A section candidate face has invalid coordinates"))
    lo=ntuple(k->minimum(Float64(p[k]) for p in points),3)
    hi=ntuple(k->maximum(Float64(p[k]) for p in points),3)
    center=ntuple(k->lo[k]/2+hi[k]/2,3)
    half=ntuple(k->hi[k]/2-lo[k]/2,3)
    all(isfinite,center)&&all(isfinite,half)||throw(ArgumentError("Section candidate bounds exceed the numeric range"))
    EulerFaceBounds(center,half)
end

function euler_face_union(bounds,order,first,last)
    lo=ntuple(k->minimum(bounds[order[i]].center[k]-bounds[order[i]].half[k] for i in first:last),3)
    hi=ntuple(k->maximum(bounds[order[i]].center[k]+bounds[order[i]].half[k] for i in first:last),3)
    EulerFaceBounds(ntuple(k->lo[k]/2+hi[k]/2,3),ntuple(k->hi[k]/2-lo[k]/2,3))
end

"""Build a reusable AABB tree over actual shell faces, without rib-row assumptions."""
function euler_face_index(faces;leaf_size::Integer=8)
    leaf_size>0||throw(ArgumentError("Euler face-index leaf size must be positive"))
    owned=collect(faces);bounds=[euler_face_bounds(face.points) for face in owned]
    order=collect(eachindex(owned));nodes=EulerFaceNode[]
    function branch(first,last)
        box=euler_face_union(bounds,order,first,last)
        node=length(nodes)+1;push!(nodes,EulerFaceNode(box,0,0,first,last))
        if last-first+1>leaf_size
            spans=ntuple(k->maximum(bounds[order[i]].center[k] for i in first:last)-minimum(bounds[order[i]].center[k] for i in first:last),3)
            axis=argmax(spans)
            sort!(view(order,first:last);by=i->(bounds[i].center[axis],i))
            middle=(first+last)÷2
            left=branch(first,middle);right=branch(middle+1,last)
            nodes[node]=EulerFaceNode(box,left,right,first,last)
        end
        node
    end
    root=isempty(owned) ? 0 : branch(firstindex(owned),lastindex(owned))
    EulerFaceIndex(owned,bounds,order,nodes,root)
end

function euler_bounds_overlap(box::EulerFaceBounds,origin,axis,transverse,lo,hi,tol)
    # Relative coordinates reduce cancellation for models translated far from
    # the origin. Expand intervals only by roundoff-scale uncertainty and the
    # polygon cutter's geometric tolerance; never shrink a candidate interval.
    d=ntuple(k->box.center[k]-origin[k],3)
    plane=sum(axis[k]*d[k] for k in 1:3)
    radius=sum(abs(axis[k])*box.half[k] for k in 1:3)
    pad=tol+64eps(Float64)*sum(abs(axis[k])*(abs(box.center[k])+abs(origin[k])+box.half[k]) for k in 1:3)
    abs(plane)>radius+pad&&return false
    along=sum(transverse[k]*d[k] for k in 1:3)
    width=sum(abs(transverse[k])*box.half[k] for k in 1:3)
    pad=tol+64eps(Float64)*(abs(lo)+abs(hi)+sum(abs(transverse[k])*(abs(box.center[k])+abs(origin[k])+box.half[k]) for k in 1:3))
    along-width<=hi+pad&&along+width>=lo-pad
end

"""Faces possibly intersecting a section plane and its half-panel transverse slab.

The input order is preserved, so changing tree leaf size cannot change the
section summation order. Optional statistics support performance verification.
"""
function euler_section_candidates(index::EulerFaceIndex,origin,axis,y,lo,hi;tol=1e-10,stats=nothing)
    all(v->length(v)==3&&all(isfinite,v),(origin,axis,y))&&all(isfinite,(lo,hi,tol))&&lo<=hi&&tol>=0||
        throw(ArgumentError("The Euler section query has invalid geometry or bounds"))
    sum(abs2,axis)>0&&sum(abs2,y)>0||throw(ArgumentError("Euler section axes must be nonzero"))
    index.root==0&&return similar(index.faces,0)
    pending=Int[index.root];selected=Int[];visited=0;tested=0
    while !isempty(pending)
        node=index.nodes[pop!(pending)];visited+=1
        euler_bounds_overlap(node.bounds,origin,axis,y,lo,hi,tol)||continue
        if node.left==0
            for position in node.first:node.last
                id=index.order[position];tested+=1
                euler_bounds_overlap(index.bounds[id],origin,axis,y,lo,hi,tol)&&push!(selected,id)
            end
        else
            push!(pending,node.right,node.left)
        end
    end
    sort!(selected)
    if stats!==nothing
        stats[:visited_nodes]=visited;stats[:tested_faces]=tested;stats[:candidate_faces]=length(selected)
    end
    index.faces[selected]
end
