# Thin-sheet geometric interference checks. Input grids contain the actual
# transformed camber-panel corners in construction coordinates, not vortices.
function aerodynamic_triangle_overlap(a,b,normal)
    drop=argmax(abs.(normal));keep=filter(!=(drop),1:3)
    project(p)=VortexLattice.SVector(p[keep[1]],p[keep[2]])
    cross2(u,v)=u[1]*v[2]-u[2]*v[1]
    orientation=sign(cross2(project(b[2]-b[1]),project(b[3]-b[1])))
    polygon=collect(a)
    for edge in 1:3
        isempty(polygon)&&break
        p,q=project(b[edge]),project(b[mod1(edge+1,3)])
        output=typeof(polygon)();previous=last(polygon)
        dp=orientation*cross2(q-p,project(previous)-p)
        for current in polygon
            dc=orientation*cross2(q-p,project(current)-p)
            (dc>=0)!=(dp>=0)&&push!(output,previous+(current-previous)*(dp/(dp-dc)))
            dc>=0&&push!(output,current)
            previous=current;dp=dc
        end
        polygon=output
    end
    length(polygon)>=3||return (area=0.,points=polygon)
    origin=first(polygon)
    area=abs(sum(dot(cross(polygon[i]-origin,polygon[mod1(i+1,length(polygon))]-origin),normal) for i in eachindex(polygon)))/2
    (;area,points=polygon)
end

"""Report genuine crossings/overlap between different physical body patches.

`count` counts intersecting patch pairs, not triangulation-dependent edge hits.
Shared boundaries and zero-area grazing contacts are permitted. This is a
geometry diagnostic: callers may preview an invalid model, but must not solve it.
"""
function aerodynamic_body_interference(patches)
    triangles=aerodynamic_wake_body_triangles([p.grid for p in patches])
    empty_report()=Dict{String,Any}("valid"=>true,"count"=>0,
        "count_semantics"=>"intersecting physical patch pairs","message"=>"",
        "contacts"=>Any[],"affected_surfaces"=>String[],"candidate_triangle_pairs"=>0)
    isempty(triangles)&&return empty_report()
    lo=reduce((a,b)->min.(a,b),(t.lo for t in triangles));hi=reduce((a,b)->max.(a,b),(t.hi for t in triangles))
    tolerance=max(norm(hi-lo)*1e-9,1e-10)
    normals=[normalize(cross(t.e1,t.e2)) for t in triangles]
    vertices=[(t.a,t.a+t.e1,t.a+t.e2) for t in triangles]
    pairs=Dict{Tuple{Int,Int},Dict{String,Any}}();candidates=0
    function record!(i,j,point,kind;area=0.)
        pair=minmax(triangles[i].patch,triangles[j].patch)
        info=get!(pairs,pair) do
            Dict{String,Any}("points"=>typeof(point)[],"coplanar_area_m2"=>0.,"kinds"=>Set{String}())
        end
        any(norm(point-other)<=tolerance for other in info["points"])||push!(info["points"],point)
        push!(info["kinds"],kind);info["coplanar_area_m2"]+=area
    end
    # Sweep the widest spatial axis before the exact 3D bounds/triangle tests.
    # This avoids comparing every triangle pair in large separated patches.
    sweep_axis=argmax(hi-lo)
    order=sortperm(eachindex(triangles);by=i->triangles[i].lo[sweep_axis])
    for position in 1:length(order)-1
        i=order[position]
        a=triangles[i];va=vertices[i];na=normals[i]
        for next_position in position+1:length(order)
            j=order[next_position]
            triangles[j].lo[sweep_axis]>a.hi[sweep_axis]+tolerance&&break
            b=triangles[j];a.patch==b.patch&&continue
            any(a.hi.<b.lo.-tolerance)&&continue
            any(b.hi.<a.lo.-tolerance)&&continue
            candidates+=1;vb=vertices[j];nb=normals[j]
            da=map(p->dot(p-va[1],na),vb);db=map(p->dot(p-vb[1],nb),va)
            (minimum(da)>tolerance||maximum(da)<-tolerance||minimum(db)>tolerance||maximum(db)<-tolerance)&&continue
            if norm(cross(na,nb))<1e-9&&maximum(abs,da)<tolerance
                overlap=aerodynamic_triangle_overlap(va,vb,na)
                overlap.area>16tolerance^2||continue
                for (index,p) in enumerate(overlap.points)
                    record!(i,j,p,"coplanar overlap";area=index==1 ? overlap.area : 0.)
                end
                continue
            end
            for (source,target,points) in ((i,j,va),(j,i,vb)),edge in 1:3
                p,q=points[edge],points[mod1(edge+1,3)]
                hit=aerodynamic_wake_triangle_intersection(p,q,triangles[target],tolerance)
                hit===nothing&&continue
                # A source vertex merely touching a sheet is not penetration.
                min(norm(hit-p),norm(hit-q))>tolerance||continue
                record!(source,target,hit,"crossing")
            end
        end
    end
    isempty(pairs)&&return merge(empty_report(),Dict("candidate_triangle_pairs"=>candidates))
    contacts=Any[];affected=Set{String}()
    for ((a,b),info) in sort!(collect(pairs);by=first)
        pa,pb=patches[a],patches[b];points=info["points"]
        sa=String(pa.element_name);sb=String(pb.element_name)
        push!(affected,sa);push!(affected,sb)
        extent=maximum((norm(p-q) for p in points for q in points);init=0.)
        push!(contacts,Dict("patch_a"=>a,"patch_b"=>b,"surface_a"=>sa,"surface_b"=>sb,
            "region_a"=>String(pa.name),"region_b"=>String(pb.name),
            "side"=>pa.side==pb.side ? String(pa.side) : "both",
            "point_m"=>collect(first(points)),"intersection_length_m"=>extent,
            "length_definition"=>"maximum distance between detected intersection points",
            "contact_point_count"=>length(points),"kinds"=>sort!(collect(info["kinds"])),
            "coplanar_overlap_area_m2"=>info["coplanar_area_m2"]))
    end
    labels=join(["$(c["surface_a"]) / $(c["surface_b"]) ($(c["side"]))" for c in contacts[1:min(end,8)]],"; ")
    Dict{String,Any}("valid"=>false,"count"=>length(pairs),
        "count_semantics"=>"intersecting physical patch pairs","contacts"=>contacts,
        "affected_surfaces"=>sort!(collect(affected)),"candidate_triangle_pairs"=>candidates,
        "message"=>"Aerodynamic surfaces intersect: $labels. Correct the control end clearances or geometry before running the analysis.")
end
