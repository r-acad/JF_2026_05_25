# The library shifts interior ring vertices one quarter into the next chord
# cell, but closes a sheet on its physical trailing edge. At the side of a
# cutout those rules disagree even when the physical mesh is conforming.

"""
    aerodynamic_conform_vortex_interfaces!(surfaces, patches; grids)

Join vortex vertices on physically shared, overlapping fixed-wing span edges.
`surfaces` must already contain the library-generated SurfacePanel records;
`grids` must be in the same coordinate system (including any wind rotation or
compressibility transform). Patch material coordinates identify the topology.

A physical trailing-edge vertex, or the endpoint where a shared fixed edge
separates into a deflected control, takes precedence over an interior
quarter-cell vertex. Every incident ring is updated, including its bound-vortex center.
Collocation points, normals, physical grids, panel chord and core are preserved.
This must run after panel conversion and before influence-matrix assembly: the
library's high-level steady_analysis! regenerates and overwrites these records.
"""
function aerodynamic_conform_vortex_interfaces!(surfaces,patches;grids=[p.grid for p in patches])
    length(surfaces)==length(patches)==length(grids)||throw(ArgumentError("Vortex interface surface/grid counts differ"))
    edges=Dict{Tuple{String,Float64},Vector{Tuple{Int,Int}}}()
    scale=1.
    for (k,p) in enumerate(patches)
        size(surfaces[k])==(size(grids[k],2)-1,size(grids[k],3)-1)||throw(ArgumentError("Vortex interface panel/grid dimensions differ"))
        scale=max(scale,maximum(abs,grids[k]))
        p.element_name=="fixed wing"||continue
        size(p.chord_coordinates)==size(grids[k])[2:3]||throw(ArgumentError("Vortex interface material coordinates do not match grid"))
        for j in (1,length(p.etas))
            push!(get!(()->Tuple{Int,Int}[],edges,(p.side,Float64(p.etas[j]))),(k,j))
        end
    end
    tolerance=64eps(Float64)*scale
    locations=Tuple{Int,Int,Int}[];indices=Dict{Tuple{Int,Int,Int},Int}();parents=Int[]
    physical_ends=Set{Int}()
    function vertex(k,i,j)
        get!(indices,(k,i,j)) do
            push!(locations,(k,i,j));push!(parents,length(parents)+1);length(parents)
        end
    end
    function root(i)
        while parents[i]!=i
            parents[i]=parents[parents[i]];i=parents[i]
        end
        i
    end
    # Only span edges with positive chord overlap are connected. Single-point
    # contacts between otherwise disconnected fixed sheets are not welded.
    for boundary in values(edges),a in eachindex(boundary),b in a+1:length(boundary)
        ka,ja=boundary[a];kb,jb=boundary[b];ka==kb&&continue
        xa=view(patches[ka].chord_coordinates,:,ja);xb=view(patches[kb].chord_coordinates,:,jb)
        min(last(xa),last(xb))>max(first(xa),first(xb))+1e-12||continue
        ia=ib=1;matches=Tuple{Int,Int}[]
        while ia<=length(xa)&&ib<=length(xb)
            if abs(xa[ia]-xb[ib])<=1e-12
                if norm(view(grids[ka],:,ia,ja)-view(grids[kb],:,ib,jb))<=tolerance
                    push!(matches,(ia,ib))
                end
                ia+=1;ib+=1
            elseif xa[ia]<xb[ib]
                ia+=1
            else
                ib+=1
            end
        end
        for (m,(ia,ib)) in enumerate(matches)
            preceding=m>1&&matches[m-1]==(ia-1,ib-1)
            following=m<length(matches)&&matches[m+1]==(ia+1,ib+1)
            preceding||following||continue
            va=vertex(ka,ia,ja);vb=vertex(kb,ib,jb);parents[root(vb)]=root(va)
            # A sealed control can remain in one chordwise sheet while its
            # span-end geometry separates aft of the hinge. The common fixed
            # edge then ends at the hinge even though neither array ends there.
            # Its physical endpoint has the same authority as a sheet TE.
            if preceding&&!following&&ia<length(xa)&&ib<length(xb)&&abs(xa[ia+1]-xb[ib+1])<=1e-12
                push!(physical_ends,va);push!(physical_ends,vb)
            end
        end
    end
    groups=Dict{Int,Vector{Int}}()
    for i in eachindex(locations);push!(get!(()->Int[],groups,root(i)),i);end
    function current(location)
        k,i,j=location;surface=surfaces[k];nc,ns=size(surface)
        i<=nc ? (j==1 ? surface[i,1].rtl : surface[i,ns].rtr) :
                (j==1 ? surface[nc,1].rbl : surface[nc,ns].rbr)
    end
    replacements=Dict{Tuple{Int,Int,Int},VortexLattice.SVector{3,Float64}}()
    before=0.;corrected=0;changed_instances=0
    for members in values(groups)
        length(members)>1||continue
        old=[current(locations[i]) for i in members]
        gap=maximum(norm(a-b) for a in old for b in old);before=max(before,gap)
        terminal=findfirst(i->begin k,row,_=locations[i];row==size(grids[k],2);end,members)
        physical_end=terminal===nothing ? findfirst(in(physical_ends),members) : terminal
        target=if physical_end!==nothing
            k,i,j=locations[members[physical_end]]
            VortexLattice.SVector{3,Float64}(view(grids[k],:,i,j))
        else
            gap<=tolerance||throw(ArgumentError("Nonconforming interior vortex rows on a shared fixed-wing edge; refine the common chord mesh"))
            first(old)
        end
        anychanged=false
        for (m,v) in zip(members,old)
            v==target&&continue
            replacements[locations[m]]=target;changed_instances+=1;anychanged=true
        end
        corrected+=anychanged
    end
    updated=Set{Tuple{Int,Int,Int}}()
    for ((k,row,column),_) in replacements
        nc,ns=size(surfaces[k])
        for i in (row-1,row),j in (column-1,column)
            1<=i<=nc&&1<=j<=ns&&push!(updated,(k,i,j))
        end
    end
    for (k,i,j) in updated
        p=surfaces[k][i,j]
        rtl=get(replacements,(k,i,j),p.rtl);rtr=get(replacements,(k,i,j+1),p.rtr)
        rbl=get(replacements,(k,i+1,j),p.rbl);rbr=get(replacements,(k,i+1,j+1),p.rbr)
        ratio=.5 # The aerodynamic study uses midpoint bound-force locations.
        rtc=(1-ratio)*rtl+ratio*rtr;rbc=(1-ratio)*rbl+ratio*rbr
        surfaces[k][i,j]=VortexLattice.SurfacePanel(rtl,rtc,rtr,rbl,rbc,rbr,p.rcp,p.ncp,p.core_size,p.chord)
    end
    after=0.
    for members in values(groups)
        points=[current(locations[i]) for i in members]
        after=max(after,maximum(norm(a-b) for a in points for b in points))
    end
    Dict("shared_vertex_groups"=>length(groups),"corrected_vertices"=>corrected,
        "corrected_vertex_instances"=>changed_instances,"updated_panels"=>length(updated),
        "maximum_gap_before_m"=>before,"maximum_gap_after_m"=>after)
end
