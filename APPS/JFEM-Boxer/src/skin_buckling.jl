# Actual rib/stringer/spar-bounded skin compartments for an equivalent-plate
# buckling assessment. This metadata does not alter FE stiffness or results.

skin_edge(a,b)=minmax(a,b)
skin_edges(nodes)=[skin_edge(nodes[i],nodes[mod1(i+1,length(nodes))]) for i in eachindex(nodes)]
skin_xyz(m,node)=Tuple(m.xyz[3node-2:3node])
skin_matrix_rows(matrix)=[collect(matrix[i,:]) for i in axes(matrix,1)]
const SkinBucklingFace=NamedTuple{(:eid,:pid,:panel_id,:group,:index,:nodes,:points,:area,:edges,:center,:axes),
    Tuple{Int,Int,Union{Nothing,Int},ElemGroup,Int,Vector{Int},Vector{NTuple{3,Float64}},Float64,
        Vector{Tuple{Int,Int}},NTuple{3,Float64},NTuple{3,NTuple{3,Float64}}}}

"""Rotate the full laminate ABD into the requested in-plane x direction.

Engineering shear is used. Ply angles are relative to the shell material
frame, whereas `angle` locates the panel x projection in that same frame.
"""
function skin_laminate_abd(section,angle)
    abd=zeros(6,6);level=section.offset-section.thickness/2
    for ply in section.plies
        next=level+Float64(ply["thickness_m"])
        theta=deg2rad(Float64(get(ply,"angle_deg",0.)))-angle;c,s=cos(theta),sin(theta)
        transform=[c^2 s^2 c*s;s^2 c^2 -c*s;-2c*s 2c*s c^2-s^2]
        q=transpose(transform)*euler_material_q(ply["material"])*transform
        abd[1:3,1:3].+=q.*(next-level)
        abd[1:3,4:6].+=q.*((next^2-level^2)/2)
        abd[4:6,1:3].+=q.*((next^2-level^2)/2)
        abd[4:6,4:6].+=q.*((next^3-level^3)/3)
        level=next
    end
    (abd+transpose(abd))/2
end

"""Membrane-free effective bending rigidity D*=D-B' A^-1 B, in N m.

For unsymmetric laminates this is an equivalent-plate approximation with
free membrane relaxation, not a fully coupled laminate buckling solution.
Reference-plane offsets cancel through the full section condensation.
"""
function skin_effective_bending(section,angle)
    abd=skin_laminate_abd(section,angle);a=abd[1:3,1:3];b=abd[1:3,4:6];d=abd[4:6,4:6]
    factor=LinearAlgebra.cholesky(LinearAlgebra.Symmetric(a);check=false)
    LinearAlgebra.issuccess(factor)||throw(ArgumentError("The laminate membrane stiffness is singular or indefinite"))
    effective=d-transpose(b)*(factor\b);effective=(effective+transpose(effective))/2
    all(isfinite,effective)&&LinearAlgebra.isposdef(LinearAlgebra.Symmetric(effective))||
        throw(ArgumentError("The effective laminate bending stiffness is singular or indefinite"))
    effective
end

function skin_stress_transform(c,s)
    [c*c s*s 2c*s;s*s c*c -2c*s;-c*s c*s c*c-s*s]
end

function skin_boundary_chain(edges)
    neighbors=Dict{Int,Vector{Int}}()
    for (a,b) in edges
        push!(get!(neighbors,a,Int[]),b);push!(get!(neighbors,b,Int[]),a)
    end
    ends=sort!([node for (node,near) in neighbors if length(near)==1])
    length(ends)==2&&all(length(near)<=2 for near in values(neighbors))||
        throw(ArgumentError("A panel support does not form one open boundary path"))
    chain=[first(ends)];previous=0;current=first(ends)
    while true
        next=filter(!=(previous),neighbors[current]);isempty(next)&&break
        length(next)==1||throw(ArgumentError("A panel support branches"))
        previous,current=current,only(next);push!(chain,current)
        length(chain)<=length(neighbors)||throw(ArgumentError("A panel support contains a loop"))
    end
    length(chain)==length(neighbors)||throw(ArgumentError("A panel support has disconnected pieces"))
    chain
end

"""Skin faces partitioned by actual shared support edges, independent of PID ownership."""
function skin_buckling_payload(m::Model;layout=nothing)
    is_imported_model(m)&&return Any[]
    layout===nothing&&(layout=stiffened_panel_layout(m.grid))
    panels=Dict(panel.id=>panel for panel in layout.panels)
    faces=Dict(true=>SkinBucklingFace[],false=>SkinBucklingFace[])
    path=stringer_path(m.grid.wing,m.params)
    for group in m.groups
        group.kind in (:quad,:tria)||continue
        base=component_base_pid(group.pid)
        base in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_STRINGER_FLANGE)||continue
        panel_id=stiffened_panel_id(group.pid)
        upper=base==PID_SKIN_UPPER||base==PID_STRINGER_FLANGE&&haskey(panels,panel_id)&&panels[panel_id].upper
        count=group.kind===:quad ? 4 : 3
        for index in eachindex(group.eids)
            nodes=group.conn[count*(index-1)+1:count*index]
            points=element_points(m,group,index)
            area=weight_shell_area(points)
            push!(faces[upper],(;eid=group.eids[index],pid=group.pid,panel_id,group,index,nodes,points,area,
                edges=skin_edges(nodes),center=Tuple(sum(p[k] for p in points)/length(points) for k in 1:3),
                axes=shell_material_frame(m,group,index;path)))
        end
    end
    sections=Dict{Int,Any}();laws=Dict{Tuple{Int,Float64},Matrix{Float64}}()
    rows=Dict{String,Any}[]
    for upper in (false,true)
        surface=faces[upper];isempty(surface)&&continue
        eid_counts=Dict{Int,Int}()
        for face in surface;eid_counts[face.eid]=get(eid_counts,face.eid,0)+1;end
        edge_faces=Dict{Tuple{Int,Int},Vector{Int}}()
        for (index,face) in enumerate(surface),edge in face.edges
            push!(get!(edge_faces,edge,Int[]),index)
        end
        support=Dict{Tuple{Int,Int},Tuple{Symbol,Int}}()
        support_columns=Dict{Tuple{Symbol,Int},Int}((:spar,0)=>0,(:spar,1)=>ni(m.grid))
        function mark!(edge,label)
            haskey(edge_faces,edge)||(return)
            previous=get(support,edge,label)
            previous==label||throw(ArgumentError("Conflicting support identities on skin edge $edge"))
            support[edge]=label
        end
        for group in m.groups
            base=component_base_pid(group.pid);panel_id=stiffened_panel_id(group.pid)
            if group.kind===:bar&&base==PID_STRINGER&&haskey(panels,panel_id)
                panel=panels[panel_id];panel.upper==upper||continue
                label=(:stringer,panel.stringer);support_columns[label]=panel.column
                for index in eachindex(group.eids);mark!(skin_edge(group.conn[2index-1:2index]...),label);end
            elseif group.kind in (:quad,:tria)&&base in (PID_RIB_WEB,PID_SPAR_WEB,PID_STRINGER_WEB)
                count=group.kind===:quad ? 4 : 3
                if base==PID_STRINGER_WEB
                    haskey(panels,panel_id)||continue
                    panel=panels[panel_id];panel.upper==upper||continue
                    support_columns[(:stringer,panel.stringer)]=panel.column
                end
                for index in eachindex(group.eids),edge in skin_edges(group.conn[count*(index-1)+1:count*index])
                    haskey(edge_faces,edge)||continue
                    ka,kb=m.node_keys[edge[1]],m.node_keys[edge[2]]
                    label=if base==PID_STRINGER_WEB
                        (:stringer,panels[panel_id].stringer)
                    elseif base==PID_SPAR_WEB
                        ka[1]==kb[1]&&ka[1] in (0,ni(m.grid)) ? (:spar,ka[1]==0 ? 0 : 1) : nothing
                    else
                        rib=ka[2]==kb[2] ? findfirst(==(ka[2]),m.grid.ribs) : nothing
                        rib===nothing ? nothing : (:rib,rib)
                    end
                    label===nothing||mark!(edge,label)
                end
            elseif group.kind===:bar&&base==PID_SPAR_CAP
                for index in eachindex(group.eids)
                    edge=skin_edge(group.conn[2index-1:2index]...);ka,kb=m.node_keys[edge[1]],m.node_keys[edge[2]]
                    ka[1]==kb[1]&&ka[1] in (0,ni(m.grid))&&mark!(edge,(:spar,ka[1]==0 ? 0 : 1))
                end
            end
        end
        adjacency=[Int[] for _ in surface]
        for (edge,owners) in edge_faces
            haskey(support,edge)&&continue
            for i in owners,j in owners;i==j||push!(adjacency[i],j);end
        end
        visited=falses(length(surface));compartments=Vector{Int}[]
        for seed in eachindex(surface)
            visited[seed]&&continue
            component=Int[];queue=[seed];visited[seed]=true
            while !isempty(queue)
                index=pop!(queue);push!(component,index)
                for next in adjacency[index]
                    visited[next]&&continue;visited[next]=true;push!(queue,next)
                end
            end
            push!(compartments,component)
        end
        # Stable physical ordering independent of element IDs and refinement.
        sort!(compartments;by=component->(minimum(minimum(m.node_keys[node][2] for node in surface[i].nodes) for i in component),
            minimum(minimum(m.node_keys[node][1] for node in surface[i].nodes) for i in component)))
        strip_segments=Dict{Tuple{Int,Int},Int}()
        for component in compartments
            chosen=Set(component);items=surface[component]
            firstrow=minimum(minimum(m.node_keys[node][2] for node in face.nodes) for face in items)
            bay=clamp(searchsortedlast(m.grid.ribs,firstrow),1,length(m.grid.ribs)-1)
            firstcolumn=minimum(minimum(m.node_keys[node][1] for node in face.nodes) for face in items)
            strip=searchsortedlast(m.grid.stringer_indices,firstcolumn)+1
            segment=get(strip_segments,(bay,strip),0)+1;strip_segments[(bay,strip)]=segment
            skin=upper ? "upper" : "lower"
            row=Dict{String,Any}("key"=>"$(skin):bay$(bay):skinstrip$(strip):segment$(segment)","skin"=>skin,"rib_bay"=>bay,
                "strip_index"=>strip,"segment"=>segment,"label"=>"Skin strip $strip","boundary_labels"=>String[],
                "property_ids"=>sort!(unique(face.pid for face in items)),
                "member_element_ids"=>sort!(unique(face.eid for face in items)),
                "membership_complete"=>all(eid_counts[face.eid]==1 for face in items),"applicable"=>true,
                "panel_ids"=>sort!(unique(Int(face.panel_id) for face in items if face.panel_id!==nothing)),
                "status"=>"unassessed","reason"=>"","length_m"=>0.,"width_m"=>0.,"elements"=>Any[],
                "fixity_coefficient"=>Float64(something(get(m.params,"stringers.skin_fixity_coefficient",1.),1.)),
                "result_frame"=>"Boxer shell material axes after element_results_payload rotation",
                "method"=>"Equivalent rectangular skin plate; averaged opposite actual 3D support-path lengths; local laminate membrane-free bending rigidity")
            push!(rows,row)
            try
                all(eid_counts[face.eid]==1 for face in items)||throw(ArgumentError("A skin element ID is duplicated in the compartment mesh"))
                boundary=Dict{Tuple{Symbol,Int},Vector{Tuple{Int,Int}}}();boundary_edges=Set{Tuple{Int,Int}}()
                for face in items,edge in face.edges
                    owners=edge_faces[edge]
                    length(owners)<=2||throw(ArgumentError("The skin contains a non-manifold shared edge"))
                    haskey(support,edge)&&length(owners)==2&&count(in(chosen),owners)==2&&
                        throw(ArgumentError("The skin compartment contains a terminating internal support; runout-merging regions need a separate plate model"))
                    if length(owners)==1||haskey(support,edge)&&count(in(chosen),owners)==1
                        push!(boundary_edges,edge)
                        label=get(support,edge,nothing)
                        label===nothing&&throw(ArgumentError("The skin compartment has a hole or an edge without a rib, stringer or spar support"))
                        push!(get!(boundary,label,Tuple{Int,Int}[]),edge)
                    end
                end
                ribs=sort!([label for label in keys(boundary) if label[1]==:rib];by=last)
                longitudinal=sort!([label for label in keys(boundary) if label[1]!=:rib];by=label->support_columns[label])
                length(ribs)==2&&length(longitudinal)==2||throw(ArgumentError("The skin compartment is not four-sided; runout-merging regions need a separate plate model"))
                ribs[2][2]==ribs[1][2]+1&&ribs[1][2]==bay||throw(ArgumentError("The skin compartment is not bounded by two adjacent ribs"))
                chains=Dict(label=>skin_boundary_chain(edges) for (label,edges) in boundary)
                degrees=Dict{Int,Int}()
                for edge in boundary_edges,node in edge;degrees[node]=get(degrees,node,0)+1;end
                all(==(2),values(degrees))||throw(ArgumentError("The skin boundary is not one simple closed loop"))
                for rib in ribs,long in longitudinal
                    length(intersect(Set((first(chains[rib]),last(chains[rib]))),Set((first(chains[long]),last(chains[long])))))==1||
                        throw(ArgumentError("The four panel support paths do not meet at four distinct corners"))
                end
                lengths=Dict(label=>sum(norm3(skin_xyz(m,b).-skin_xyz(m,a)) for (a,b) in edges) for (label,edges) in boundary)
                left,right=longitudinal;inboard,outboard=ribs
                a=(lengths[left]+lengths[right])/2;b=(lengths[inboard]+lengths[outboard])/2
                all(isfinite,(a,b))&&min(a,b)>0||throw(ArgumentError("The skin panel has a zero or invalid dimension"))
                normal=zeros(3);origin=zeros(3);total_area=0.
                for face in items
                    face.area>0&&isfinite(face.area)||throw(ArgumentError("The skin contains a zero or invalid shell area"))
                    normal.+=face.area.*last(face.axes);origin.+=face.area.*face.center;total_area+=face.area
                end
                n=unit3(Tuple(normal));norm3(n)>.5||throw(ArgumentError("The skin normals cancel across this compartment"))
                midpoint(label)=(skin_xyz(m,first(chains[label])).+skin_xyz(m,last(chains[label])))./2
                direction=midpoint(outboard).-midpoint(inboard);x=unit3(direction.-euler_dot(direction,n).*n)
                norm3(x)>.5||throw(ArgumentError("The panel span direction is undefined"))
                y=cross3(n,x)
                row["length_m"]=a;row["width_m"]=b
                row["area_m2"]=total_area
                row["side_lengths_m"]=Dict("left"=>lengths[left],"right"=>lengths[right],"inboard"=>lengths[inboard],"outboard"=>lengths[outboard])
                row["frame"]=Dict("origin_m"=>collect(origin./total_area),"x"=>collect(x),"y"=>collect(y),"normal"=>collect(n))
                chord=unit3(midpoint(right).-midpoint(left))
                row["skew_angle_deg"]=abs(asind(clamp(euler_dot(unit3(direction),chord),-1.,1.)))
                row["max_normal_deviation_deg"]=maximum(acosd(clamp(euler_dot(last(face.axes),n),-1.,1.)) for face in items)
                labeltext(label)=label[1]==:spar ? (label[2]==0 ? "Front spar" : "Rear spar") : "S$(label[2])"
                row["boundary_labels"]=[labeltext(left),labeltext(right)]
                row["label"]=join(row["boundary_labels"],"–")
                for face in items
                    u,v,z=face.axes
                    euler_dot(z,n)>0||throw(ArgumentError("The compartment is folded or has inconsistent shell normals"))
                    c,s=euler_dot(x,u),euler_dot(x,v);projection=hypot(c,s)
                    projection>1e-5||throw(ArgumentError("A shell is normal to the panel span direction"))
                    c/=projection;s/=projection
                    section=get!(sections,face.pid) do;euler_shell_section(shell_material_definition(m.params,face.pid));end
                    effective=get!(laws,(face.pid,atan(s,c))) do;skin_effective_bending(section,atan(s,c));end
                    push!(row["elements"],Dict("eid"=>face.eid,"pid"=>face.pid,"area_m2"=>face.area,
                        "thickness_m"=>section.thickness,"material_ids"=>section.material_ids,
                        "stress_transform"=>skin_matrix_rows(skin_stress_transform(c,s)),
                        "bending_matrix_Nm"=>skin_matrix_rows(effective)))
                end
                sort!(row["elements"];by=element->element["eid"])
                row["status"]="ready"
            catch failure
                failure isa ArgumentError||rethrow()
                row["reason"]=sprint(showerror,failure);empty!(row["elements"])
            end
        end
    end
    rows
end
