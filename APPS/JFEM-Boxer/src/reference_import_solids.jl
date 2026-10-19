"""Exterior solid faces for display; original volume connectivity remains authoritative.

Face cancellation uses all face-node identities, independent of element ordering.
Quadratic tetrahedron faces retain their six nodes and are drawn with four
triangles. This is a display tessellation, never a replacement solver mesh.
"""
function imported_solid_boundary(native,index)
    solids=get(native,"CSOLIDs",Dict());isempty(solids)&&return nothing
    faces=Dict{Tuple,Any}();counts=Dict{Tuple,Int}();elements=Any[];types=Dict{String,Int}()
    for el in sort!(collect(values(solids));by=e->Int(e["ID"]))
        eid=Int(el["ID"]);pid=Int(el["PID"]);nodes=Int.(el["NODES"]);nn=length(nodes)
        all(id->haskey(index,id),nodes)||throw(ArgumentError("Solid element $eid references a missing node"))
        kind=String(get(el,"TYPE","solid"));source_type=String(get(el,"ABAQUS_TYPE",kind));types[source_type]=get(types,source_type,0)+1
        prop=get(get(native,"PSOLIDs",Dict()),string(pid),nothing)
        properties=prop===nothing ? Dict{String,Any}("type"=>"Unassigned solid","pid"=>pid,"display_note"=>"Mesh only: no material or solid section is assigned.") : Dict{String,Any}("type"=>"PSOLID","pid"=>pid,"material"=>imported_material(native,prop["MID"]),"source_property"=>prop)
        push!(elements,Dict("eid"=>eid,"pid"=>pid,"type"=>kind,"source_type"=>source_type,"nodes"=>[index[id]-1 for id in nodes],"properties"=>properties))
        localfaces=if kind=="CTETRA"&&nn in (4,10)
            nn==10 ? [[1,3,2,7,6,5],[1,2,4,5,9,8],[2,3,4,6,10,9],[3,1,4,7,8,10]] : [[1,3,2],[1,2,4],[2,3,4],[3,1,4]]
        elseif kind=="CHEXA"&&nn==8
            [[1,4,3,2],[5,6,7,8],[1,2,6,5],[2,3,7,6],[3,4,8,7],[4,1,5,8]]
        elseif kind=="CPENTA"&&nn==6
            [[1,3,2],[4,5,6],[1,2,5,4],[2,3,6,5],[3,1,4,6]]
        else
            throw(ArgumentError("Solid display does not support $source_type with $nn nodes"))
        end
        for face in localfaces
            # Equal corner nodes alone do not prove conformity: quadratic
            # interfaces must share their midside nodes too. Retain both
            # faces when those degrees of freedom are disconnected.
            key=Tuple(sort(nodes[face]));counts[key]=get(counts,key,0)+1
            haskey(faces,key)||(faces[key]=(eid=eid,pid=pid,nodes=[index[nodes[i]]-1 for i in face]))
        end
    end
    conn=Int[];eids=Int[];pids=Int[];edges=Set{Tuple{Int,Int}}();boundary_count=0
    for (key,face) in sort!(collect(faces);by=x->first(x))
        counts[key]==1||continue;boundary_count+=1;n=face.nodes
        tris=length(n)==6 ? ((1,4,6),(4,2,5),(6,5,3),(4,5,6)) : length(n)==4 ? ((1,2,3),(1,3,4)) : ((1,2,3),)
        for t in tris;append!(conn,n[collect(t)]);push!(eids,face.eid);push!(pids,face.pid);end
        perimeter=length(n)==6 ? n[[1,4,2,5,3,6]] : n
        for i in eachindex(perimeter);a,b=perimeter[i],perimeter[mod1(i+1,length(perimeter))];push!(edges,minmax(a,b));end
    end
    Dict{String,Any}("format"=>"imported-solid-boundary-1","elements"=>elements,
        "triangles"=>Dict("count"=>length(eids),"eids"=>blob_i32(eids),"pids"=>blob_i32(pids),"conn"=>blob_i32(conn)),
        "edges"=>Dict("count"=>length(edges),"conn"=>blob_i32([v for edge in sort!(collect(edges)) for v in edge])),
        "topology_counts"=>Dict("elements"=>length(elements),"boundary_faces"=>boundary_count,"interior_faces"=>count(==(2),values(counts)),"nonmanifold_faces"=>count(>(2),values(counts)),"types"=>types),
        "note"=>"Exterior faces only; picking identifies the original volume element and property. Quadratic faces are tessellated through their midside nodes. Interior faces are hidden, including faces between different properties.")
end
