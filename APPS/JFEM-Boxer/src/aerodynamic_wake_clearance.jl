# Geometric wake/body checks use the physical aerodynamic panel corners, not
# the quarter-chord bound vortices. Coordinates must share the wind frame.
# These checks do not change the body, solve a collision response, or relax the
# free-wake convergence criteria. The seed is only a collision-free initial guess.

struct AerodynamicWakeBodyTriangle
    a::VortexLattice.SVector{3,Float64}
    e1::VortexLattice.SVector{3,Float64}
    e2::VortexLattice.SVector{3,Float64}
    lo::VortexLattice.SVector{3,Float64}
    hi::VortexLattice.SVector{3,Float64}
    patch::Int
    chord::Int
    strip::Int
    half::Int
    boundary_edges::NTuple{3,Bool}
end

function aerodynamic_wake_body_triangles(body_grids)
    point(g,i,j)=VortexLattice.SVector{3,Float64}(g[:,i,j])
    triangles=AerodynamicWakeBodyTriangle[]
    for (patch,g) in enumerate(body_grids),j in 1:size(g,3)-1,i in 1:size(g,2)-1
        a,b,c,d=point(g,i,j),point(g,i+1,j),point(g,i+1,j+1),point(g,i,j+1)
        for (half,vertices) in enumerate(((a,b,c),(a,c,d)))
            p,q,r=vertices;e1=q-p;e2=r-p
            norm(cross(e1,e2))>eps(Float64)*max(norm(e1)*norm(e2),eps())||continue
            # Barycentric coordinate u/v/w == 0 identifies the opposite edge.
            # Internal mesh edges belong to the physical sheet's interior.
            boundary=half==1 ? (false,j==1,i==size(g,2)-1) :
                (i==1,false,j==size(g,3)-1)
            push!(triangles,AerodynamicWakeBodyTriangle(p,e1,e2,min.(p,q,r),max.(p,q,r),
                patch,i,j,half,boundary))
        end
    end
    # Adjacent aerodynamic patches often split one physical lifting sheet.
    # A matching complete edge on both patches is interior, not a free edge.
    # Nonconforming partial-edge (T-junction) contacts are deliberately not
    # inferred here: their overlap needs explicit physical-surface topology.
    if !isempty(triangles)
        lo=reduce((a,b)->min.(a,b),(t.lo for t in triangles))
        hi=reduce((a,b)->max.(a,b),(t.hi for t in triangles))
        tolerance=max(norm(hi-lo)*1e-10,1e-11)
        keypoint(p)=ntuple(i->round(p[i]/tolerance),3)
        edges=Dict{Tuple{NTuple{3,Float64},NTuple{3,Float64}},Vector{Tuple{Int,Int}}}()
        for (index,t) in enumerate(triangles)
            a,b,c=t.a,t.a+t.e1,t.a+t.e2
            for (edge,(p,q)) in enumerate(((a,c),(a,b),(b,c)))
                t.boundary_edges[edge]||continue
                pkey,qkey=keypoint(p),keypoint(q)
                key=isless(pkey,qkey) ? (pkey,qkey) : (qkey,pkey)
                push!(get!(()->Tuple{Int,Int}[],edges,key),(index,edge))
            end
        end
        for matches in values(edges)
            length(unique(triangles[index].patch for (index,_) in matches))>1||continue
            for (index,edge) in matches
                t=triangles[index];boundary=ntuple(i->i==edge ? false : t.boundary_edges[i],3)
                triangles[index]=AerodynamicWakeBodyTriangle(t.a,t.e1,t.e2,t.lo,t.hi,
                    t.patch,t.chord,t.strip,t.half,boundary)
            end
        end
    end
    triangles
end

# Moller-Trumbore with a strict physical-quad interior. The diagonal introduced
# by triangulation is included; excluding it would leave a hole in a flat panel.
# Exterior patch edges are excluded so free-edge grazing is not mistaken for
# penetration. Internal mesh edges and matching patch boundaries are included,
# as are segment endpoints; the caller separately excludes TE attachment points.
function aerodynamic_wake_triangle_intersection(a,b,triangle,tolerance)
    edge=b-a
    any(max.(a,b).<triangle.lo.-tolerance)&&return nothing
    any(min.(a,b).>triangle.hi.+tolerance)&&return nothing
    h=cross(edge,triangle.e2);det=dot(triangle.e1,h)
    abs(det)>1e-12*norm(edge)*norm(triangle.e1)*norm(triangle.e2)||return nothing
    s=a-triangle.a;u=dot(s,h)/det;q=cross(s,triangle.e1)
    v=dot(edge,q)/det;w=1-u-v;btol=1e-10
    min(u,v,w)>=-btol||return nothing
    any(boundary&&value<=btol for (boundary,value) in zip(triangle.boundary_edges,(u,v,w)))&&return nothing
    t=dot(triangle.e2,q)/det
    dt=tolerance/max(norm(edge),tolerance)
    -dt<=t<=1+dt||return nothing
    a+clamp(t,0.,1.)*edge
end

"""Count streamwise wake segments penetrating physical body-panel interiors.

An intersection shared by triangles or consecutive wake segments is counted once
per filament/location. Semi-infinite +X tails are checked to the last body extent.
`segment_count` counts finite streamwise segments; `tail_segment_count` counts
tails with body geometry downstream. `samples` contains bounded diagnostics.
"""
function aerodynamic_wake_collisions(grids,triangles;scale=1.0,max_samples=8)
    tolerance=max(abs(Float64(scale))*1e-8,1e-10)
    hits=0;segments=0;tails=0;samples=NamedTuple[]
    isempty(triangles)&&return (count=0,segment_count=sum((size(g,2)-1)*size(g,3) for g in grids),tail_segment_count=0,samples=samples)
    bodylo=reduce((a,b)->min.(a,b),(t.lo for t in triangles))
    bodyhi=reduce((a,b)->max.(a,b),(t.hi for t in triangles))
    for (patch,g) in enumerate(grids),j in axes(g,3)
        attachment=VortexLattice.SVector{3,Float64}(g[:,1,j]);locations=typeof(attachment)[]
        for i in 1:size(g,2)
            tail=i==size(g,2)
            a=VortexLattice.SVector{3,Float64}(g[:,i,j])
            if tail
                bodyhi[1]>a[1]+tolerance||continue
                tails+=1;b=VortexLattice.SVector(bodyhi[1]+tolerance,a[2],a[3])
            else
                segments+=1;b=VortexLattice.SVector{3,Float64}(g[:,i+1,j])
            end
            any(max.(a,b).<bodylo.-tolerance)&&continue
            any(min.(a,b).>bodyhi.+tolerance)&&continue
            for triangle in triangles
                location=aerodynamic_wake_triangle_intersection(a,b,triangle,tolerance)
                location===nothing&&continue
                norm(location-attachment)<=tolerance&&continue
                any(norm(location-other)<=tolerance for other in locations)&&continue
                push!(locations,location);hits+=1
                length(samples)<max_samples&&push!(samples,(patch=patch,filament=j,row=i,tail=tail,
                    body_patch=triangle.patch,chord=triangle.chord,strip=triangle.strip,
                    point=Tuple(location)))
            end
        end
    end
    (count=hits,segment_count=segments,tail_segment_count=tails,samples=samples)
end

# Endpoints of the intersection of a triangle with a constant-Y plane. They
# suffice to bound its piecewise-linear upper envelope in the X/Z plane.
function aerodynamic_wake_section_points(triangle,y,tolerance)
    points=typeof(triangle.a)[]
    vertices=(triangle.a,triangle.a+triangle.e1,triangle.a+triangle.e2)
    for i in 1:3
        a=vertices[i];b=vertices[mod1(i+1,3)]
        abs(a[2]-y)<=tolerance&&push!(points,a)
        dy=b[2]-a[2]
        abs(dy)>tolerance||continue
        f=(y-a[2])/dy
        0<=f<=1&&push!(points,a+f*(b-a))
    end
    points
end

# Max-envelope dilation along connected TE polylines. Only existing patch
# adjacency and identical TE vertices connect rays; nearby detached flaps never
# become neighbors merely because they are close in space. Attenuation along a
# chain multiplies, giving exp(-TE arclength/distance) from each seed source.
function aerodynamic_smooth_wake_seed!(grids,side,distance)
    isempty(grids)&&return
    rows=size(first(grids),2)
    all(size(g,2)==rows for g in grids)||throw(ArgumentError("Wake seed smoothing requires matching downstream station counts"))
    lookup=Dict{NTuple{3,Float64},Int}();points=VortexLattice.SVector{3,Float64}[]
    indices=Vector{Int}[]
    for g in grids
        ids=Int[]
        for j in axes(g,3)
            p=Tuple(g[:,1,j]);index=get!(lookup,p) do
                push!(points,VortexLattice.SVector{3,Float64}(p));length(points)
            end
            push!(ids,index)
        end
        push!(indices,ids)
    end
    heights=zeros(rows,length(points));neighbors=[Tuple{Int,Float64}[] for _ in points]
    for (g,ids) in zip(grids,indices)
        for (j,id) in enumerate(ids),i in 2:rows
            heights[i,id]=max(heights[i,id],side*(g[3,i,j]-g[3,1,j]))
        end
        for j in 1:length(ids)-1
            a,b=ids[j],ids[j+1];a==b&&continue
            attenuation=exp(-norm(points[a]-points[b])/distance)
            push!(neighbors[a],(b,attenuation));push!(neighbors[b],(a,attenuation))
        end
    end
    queue=findall(j->any(>(0),view(heights,:,j)),axes(heights,2));queued=falses(length(points))
    queued[queue].=true;head=1
    while head<=length(queue)
        index=queue[head];head+=1;queued[index]=false
        for (neighbor,attenuation) in neighbors[index]
            changed=false
            for i in 2:rows
                required=attenuation*heights[i,index]
                if required>heights[i,neighbor]+8eps(max(abs(required),1.))
                    heights[i,neighbor]=required;changed=true
                end
            end
            if changed&&!queued[neighbor];push!(queue,neighbor);queued[neighbor]=true;end
        end
    end
    for (g,ids) in zip(grids,indices),(j,id) in enumerate(ids),i in 2:rows
        g[3,i,j]=g[3,1,j]+side*heights[i,id]
    end
    nothing
end

"""Initialize penetrating filaments above/below the downstream body envelope.

The initial straight rays can cut a separately meshed, deflected control surface.
A deterministic ramp clears the actual body cross-section at each ray's Y
coordinate, then becomes level past the last obstacle. All streamwise stations
and trailing-edge attachments remain exact. Unobstructed rays are untouched.
No input grid is changed unless the complete candidate passes the collision check.
`side=+1` selects the upper geometric branch and `side=-1` the lower branch;
neither geometric choice substitutes for the subsequent flow-convergence check.
Optional `span_smoothing=true` spreads offset conservatively along connected TE
polylines. It still rejects geometrically incompatible branches; it never moves
an attachment to cross a neighboring surface.
"""
function aerodynamic_seed_clear_wake!(grids,triangles,scale;core,side=1,span_smoothing=false)
    side in (-1,1)||throw(ArgumentError("Wake clearance side must be +1 (above) or -1 (below)"))
    before=aerodynamic_wake_collisions(grids,triangles;scale=scale,max_samples=typemax(Int))
    before.count==0&&return (initial_intersections=0,remaining_intersections=0,
        modified_filaments=0,max_offset=0.,segment_count=before.segment_count,
        side=side,span_smoothing=span_smoothing)
    tolerance=max(abs(Float64(scale))*1e-8,1e-10)
    clearance=max(abs(Float64(core)),abs(Float64(scale))*1e-5,1e-8)
    candidate=deepcopy(grids)
    obstructed=Set((hit.patch,hit.filament) for hit in before.samples)
    # Patch boundaries may duplicate one physical TE vertex. Use the same seed
    # for every copy so the initialization does not tear shared wake filaments.
    starts=Set(Tuple(grids[k][:,1,j]) for (k,j) in obstructed)
    modified=0;maxoffset=0.
    for (k,g) in enumerate(candidate),j in axes(g,3)
        Tuple(g[:,1,j]) in starts||continue
        origin=VortexLattice.SVector{3,Float64}(g[:,1,j])
        slope=0.;lastx=origin[1];height=0.
        for triangle in triangles
            triangle.lo[2]-tolerance<=origin[2]<=triangle.hi[2]+tolerance||continue
            triangle.hi[1]>origin[1]+tolerance||continue
            for p in aerodynamic_wake_section_points(triangle,origin[2],tolerance)
                dx=p[1]-origin[1]
                dx>tolerance||continue
                needed=side*(p[3]-origin[3])+clearance
                slope=max(slope,needed/dx);height=max(height,needed)
                lastx=max(lastx,p[1])
            end
        end
        slope>0||throw(ArgumentError("Wake/body intersection: no upstream-clear seed could be constructed"))
        # Keep the ramp exactly linear until a grid station beyond all obstacles;
        # flattening between stations could otherwise cut through an envelope.
        stop=findfirst(x->x>=lastx+tolerance,view(g,1,:,j))
        stop===nothing&&(stop=size(g,2))
        rampend=g[1,stop,j]-origin[1]
        # A short finite wake's straight tail must also clear any body geometry
        # beyond its last station; raise the endpoint before that tail begins.
        slope=max(slope,height/max(rampend,tolerance))
        for i in 2:size(g,2)
            offset=slope*min(g[1,i,j]-origin[1],rampend)
            g[3,i,j]=origin[3]+side*max(offset,side*(g[3,i,j]-origin[3]))
            maxoffset=max(maxoffset,abs(g[3,i,j]-grids[k][3,i,j]))
        end
        modified+=1
    end
    after=aerodynamic_wake_collisions(candidate,triangles;scale=scale)
    if span_smoothing
        smoothing_length=max(2abs(Float64(core)),.1abs(Float64(scale)),tolerance)
        # Raising neighboring rays can move a previously lower clear ray through
        # a body. Repair that ray to its full envelope, then conservatively dilate
        # again. Each repaired ray remains above/below all body sections forever;
        # therefore at most the number of distinct rays can require repair.
        for _ in 1:sum(size(g,3) for g in candidate)
            aerodynamic_smooth_wake_seed!(candidate,side,smoothing_length)
            after=aerodynamic_wake_collisions(candidate,triangles;scale=scale)
            after.count==0&&break
            aerodynamic_seed_clear_wake!(candidate,triangles,scale;core,side,span_smoothing=false)
        end
        after=aerodynamic_wake_collisions(candidate,triangles;scale=scale)
        modified=sum(any(g[3,:,j].!=old[3,:,j]) for (g,old) in zip(candidate,grids) for j in axes(g,3))
        maxoffset=maximum(maximum(abs.(g[3,:,:].-old[3,:,:])) for (g,old) in zip(candidate,grids))
    end
    if after.count>0
        firsthit=first(after.samples)
        throw(ArgumentError("Wake/body intersection: clearance initialization retained $(after.count) penetrations (wake patch $(firsthit.patch), filament $(firsthit.filament), row $(firsthit.row), body patch $(firsthit.body_patch)); refine near-wake stations or revise overlapping geometry"))
    end
    for (g,newgrid) in zip(grids,candidate);g.=newgrid;end
    (initial_intersections=before.count,remaining_intersections=after.count,
        modified_filaments=modified,max_offset=maxoffset,segment_count=after.segment_count,
        side=side,span_smoothing=span_smoothing)
end
