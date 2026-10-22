# Physical main-box web compartments and bare cap/rib-stiffener columns.
# Assessment metadata only: these descriptors do not alter the FE problem.

const COMPONENT_RF_FIXITY_KEYS=("properties.spar_web_buckling_fixity","properties.rib_web_buckling_fixity",
    "properties.spar_cap_euler_fixity","properties.rib_stiffener_euler_fixity")

function component_rf_location(group,part,index,rowkey,rowlabel;key="$part:$index",cell_label=rowlabel)
    isrib=group in ("ribwebs","ribstiffeners")
    Dict{String,Any}("group"=>group,"part"=>part,"index"=>index,"rowKey"=>rowkey,"rowLabel"=>rowlabel,
        "columnLabel"=>isrib ? "R$index" : "R$(index)–R$(index+1)","key"=>key,"cellLabel"=>cell_label)
end

function component_rf_faces(m,path)
    surfaces=Dict{Tuple{Symbol,Int},Vector{SkinBucklingFace}}()
    eid_counts=Dict{Int,Int}()
    for group in m.groups,eid in group.eids;eid_counts[eid]=get(eid_counts,eid,0)+1;end
    supports=Dict{Symbol,Dict{Tuple{Int,Int},Int}}(kind=>Dict{Tuple{Int,Int},Int}() for kind in (:rib,:spar,:skin,:stiffener))
    ribnodes=Dict{Int,Set{Int}}();skinnodes=Dict(0=>Set{Int}(),m.grid.nh=>Set{Int}())
    for group in m.groups
        base=component_base_pid(group.pid)
        if group.kind in (:quad,:tria)
            base in (PID_RIB_WEB,PID_SPAR_WEB,PID_SKIN_UPPER,PID_SKIN_LOWER,PID_STRINGER_FLANGE)||continue
            count=group.kind===:quad ? 4 : 3
            for index in eachindex(group.eids)
                nodes=group.conn[count*(index-1)+1:count*index];edges=skin_edges(nodes)
                keys=m.node_keys[nodes]
                if base==PID_RIB_WEB
                    js=unique(key[2] for key in keys);length(js)==1||continue
                    rib=findfirst(==(only(js)),m.grid.ribs);rib===nothing&&continue
                    for edge in edges;supports[:rib][edge]=rib;end
                    union!(get!(ribnodes,rib,Set{Int}()),nodes)
                    identity=(:rib,rib)
                elseif base==PID_SPAR_WEB
                    is=unique(key[1] for key in keys);length(is)==1&&only(is) in (0,ni(m.grid))||continue
                    side=only(is);for edge in edges;supports[:spar][edge]=side;end
                    identity=(:spar,side)
                else
                    ks=unique(key[3] for key in keys);length(ks)==1&&only(ks) in (0,m.grid.nh)||continue
                    side=only(ks);for edge in edges;supports[:skin][edge]=side;end
                    union!(skinnodes[side],nodes);continue
                end
                points=element_points(m,group,index)
                face=(;eid=group.eids[index],pid=group.pid,panel_id=nothing,group,index,nodes,points,
                    area=weight_shell_area(points),edges,center=Tuple(sum(p[k] for p in points)/length(points) for k in 1:3),
                    axes=shell_material_frame(m,group,index;path))
                push!(get!(surfaces,identity,SkinBucklingFace[]),face)
            end
        elseif group.kind===:bar&&base in (PID_SPAR_CAP,PID_RIB_STIFFENER)
            for index in eachindex(group.eids)
                edge=skin_edge(group.conn[2index-1:2index]...);a,b=m.node_keys[edge[1]],m.node_keys[edge[2]]
                if base==PID_SPAR_CAP&&a[3]==b[3]&&a[3] in (0,m.grid.nh)
                    supports[:skin][edge]=a[3]
                elseif base==PID_RIB_STIFFENER&&a[1]==b[1]
                    supports[:stiffener][edge]=a[1]
                end
            end
        end
    end
    (;surfaces,supports,ribnodes,skinnodes,eid_counts)
end

function component_rf_compartments(surface,support)
    owners=Dict{Tuple{Int,Int},Vector{Int}}()
    for (index,face) in enumerate(surface),edge in face.edges;push!(get!(owners,edge,Int[]),index);end
    adjacency=[Int[] for _ in surface]
    for (edge,ids) in owners
        haskey(support,edge)&&continue
        for i in ids,j in ids;i==j||push!(adjacency[i],j);end
    end
    seen=falses(length(surface));components=Vector{Int}[]
    for seed in eachindex(surface)
        seen[seed]&&continue
        queue=[seed];seen[seed]=true;component=Int[]
        while !isempty(queue)
            current=pop!(queue);push!(component,current)
            for next in adjacency[current];seen[next]&&continue;seen[next]=true;push!(queue,next);end
        end
        push!(components,component)
    end
    (;owners,components)
end

function component_rf_web_geometry!(row,m,items,chosen,owners,support,axis_index,sections,laws)
    row["membership_complete"]||throw(ArgumentError("A web element ID is duplicated"))
    boundary=Dict{Tuple{Symbol,Int},Vector{Tuple{Int,Int}}}();boundary_edges=Set{Tuple{Int,Int}}()
    for face in items,edge in face.edges
        ids=owners[edge]
        length(ids)<=2||throw(ArgumentError("The web contains a non-manifold shared edge"))
        haskey(support,edge)&&length(ids)==2&&count(in(chosen),ids)==2&&
            throw(ArgumentError("A stiffener terminates inside this web compartment; a four-supported-edge plate is unavailable"))
        if length(ids)==1||haskey(support,edge)&&count(in(chosen),ids)==1
            label=get(support,edge,nothing)
            label===nothing&&throw(ArgumentError("The web has a hole or an edge without a modeled rib, spar, skin or stiffener support"))
            push!(boundary_edges,edge);push!(get!(boundary,label,Tuple{Int,Int}[]),edge)
        end
    end
    ends=sort!([label for label in keys(boundary) if first(label)==:end];by=last)
    sides=sort!([label for label in keys(boundary) if first(label)==:side];by=last)
    length(ends)==2&&length(sides)==2||throw(ArgumentError("The web compartment does not have exactly four supported boundary paths"))
    row["kind"]=="spar_web"&&ends[2][2]!=ends[1][2]+1&&
        throw(ArgumentError("The spar web is not bounded by adjacent actual ribs"))
    chains=Dict(label=>skin_boundary_chain(edges) for (label,edges) in boundary)
    degrees=Dict{Int,Int}()
    for edge in boundary_edges,node in edge;degrees[node]=get(degrees,node,0)+1;end
    all(==(2),values(degrees))||throw(ArgumentError("The web boundary is not one simple closed loop"))
    for ending in ends,side in sides
        length(intersect(Set((first(chains[ending]),last(chains[ending]))),Set((first(chains[side]),last(chains[side])))))==1||
            throw(ArgumentError("The four web support paths do not meet at four distinct corners"))
    end
    lengths=Dict(label=>sum(norm3(skin_xyz(m,b).-skin_xyz(m,a)) for (a,b) in edges) for (label,edges) in boundary)
    start,stop=ends;lower,upper=sides
    a=(lengths[lower]+lengths[upper])/2;b=(lengths[start]+lengths[stop])/2
    all(isfinite,(a,b))&&min(a,b)>0||throw(ArgumentError("The web has zero or invalid dimensions"))
    normal=zeros(3);origin=zeros(3);total_area=0.
    for face in items
        face.area>0&&isfinite(face.area)||throw(ArgumentError("A web element has zero or invalid area"))
        normal.+=face.area.*last(face.axes);origin.+=face.area.*face.center;total_area+=face.area
    end
    n=unit3(Tuple(normal));norm3(n)>.5||throw(ArgumentError("The web normals cancel"))
    midpoint(label)=(skin_xyz(m,first(chains[label])).+skin_xyz(m,last(chains[label])))./2
    direction=midpoint(stop).-midpoint(start);x=unit3(direction.-euler_dot(direction,n).*n)
    norm3(x)>.5||throw(ArgumentError("The web longitudinal direction is undefined"))
    y=cross3(n,x);height_direction=midpoint(upper).-midpoint(lower)
    upward=euler_dot(y,height_direction)>0
    # Arc coordinates retain all actual span/chord refinement and align each
    # through-height cell in an explicit equivalent-rectangle parameter map.
    fractions=Dict{Tuple{Symbol,Int},Dict{Int,Float64}}()
    for side in sides
        chain=chains[side]
        m.node_keys[first(chain)][axis_index]>m.node_keys[last(chain)][axis_index]&&(chain=reverse(chain))
        values=Dict(m.node_keys[first(chain)][axis_index]=>0.);distance=0.
        for i in 2:length(chain)
            distance+=norm3(skin_xyz(m,chain[i]).-skin_xyz(m,chain[i-1]))
            values[m.node_keys[chain[i]][axis_index]]=distance/lengths[side]
        end
        fractions[side]=values
    end
    Set(keys(fractions[lower]))==Set(keys(fractions[upper]))||throw(ArgumentError("Opposite web edges do not share the same through-height mesh stations"))
    uv=Dict(index=>(fractions[lower][index]+fractions[upper][index])/2 for index in keys(fractions[lower]))
    row["length_m"]=a;row["width_m"]=b;row["area_m2"]=total_area
    row["side_lengths_m"]=Dict("lower"=>lengths[lower],"upper"=>lengths[upper],"start"=>lengths[start],"end"=>lengths[stop])
    row["frame"]=Dict("origin_m"=>collect(origin./total_area),"x"=>collect(x),"y"=>collect(y),"normal"=>collect(n))
    row["skew_angle_deg"]=abs(asind(clamp(euler_dot(unit3(direction),unit3(height_direction)),-1.,1.)))
    row["max_normal_deviation_deg"]=maximum(acosd(clamp(euler_dot(last(face.axes),n),-1.,1.)) for face in items)
    end_label(label)=row["kind"]=="spar_web" ? "R$(label[2])" : label[2]==0 ? "Front spar" :
        label[2]==ni(m.grid) ? "Rear spar" : "Stiffener $(something(findfirst(==(label[2]),m.grid.stringer_indices),0))"
    row["boundary_labels"]=Dict("start"=>end_label(start),"end"=>end_label(stop),"lower"=>"Lower skin","upper"=>"Upper skin")
    if row["kind"]=="rib_web"
        label=end_label(start)*"–"*end_label(stop)
        location=only(row["locations"]);location["rowLabel"]=label;location["cellLabel"]=label
        row["label"]=label*" · "*location["columnLabel"]
    end
    row["mapping"]="Equivalent rectangle: mean opposite-boundary normalized arc coordinate and mesh through-height fraction; y follows the right-handed panel frame"
    for face in items
        u,v,z=face.axes;euler_dot(z,n)>0||throw(ArgumentError("The web is folded or has inconsistent element normals"))
        c,s=euler_dot(x,u),euler_dot(x,v);projection=hypot(c,s)
        projection>1e-5||throw(ArgumentError("A web shell is normal to its panel longitudinal direction"))
        c/=projection;s/=projection
        section=get!(sections,face.pid) do;euler_shell_section(shell_material_definition(m.params,face.pid));end
        effective=get!(laws,(face.pid,atan(s,c))) do;skin_effective_bending(section,atan(s,c));end
        vertices=[begin
            key=m.node_keys[node];haskey(uv,key[axis_index])||throw(ArgumentError("A web node has no supported boundary coordinate"))
            height=key[3]/m.grid.nh;[uv[key[axis_index]],upward ? height : 1-height]
        end for node in face.nodes]
        push!(row["elements"],Dict("eid"=>face.eid,"pid"=>face.pid,"area_m2"=>face.area,
            "thickness_m"=>section.thickness,"material_ids"=>section.material_ids,
            "stress_transform"=>skin_matrix_rows(skin_stress_transform(c,s)),"bending_matrix_Nm"=>skin_matrix_rows(effective),
            "normalized_vertices_uv"=>vertices,
            "projected_vertices_m"=>[[euler_dot(point.-Tuple(origin./total_area),x),euler_dot(point.-Tuple(origin./total_area),y)] for point in face.points]))
    end
    sort!(row["elements"];by=item->item["eid"]);row["status"]="ready"
end

function component_web_buckling_payload(m,data)
    rows=Dict{String,Any}[];sections=Dict{Int,Any}();laws=Dict{Tuple{Int,Float64},Matrix{Float64}}()
    for (identity,surface) in sort!(collect(data.surfaces);by=first)
        kind,number=identity;is_spar=kind==:spar
        support=Dict{Tuple{Int,Int},Tuple{Symbol,Int}}()
        for face in surface,edge in face.edges
            if haskey(data.supports[:skin],edge);support[edge]=(:side,data.supports[:skin][edge]);end
            ending=is_spar ? get(data.supports[:rib],edge,nothing) : get(data.supports[:spar],edge,get(data.supports[:stiffener],edge,nothing))
            ending===nothing||(support[edge]=(:end,ending))
        end
        topology=component_rf_compartments(surface,support);axis_index=is_spar ? 2 : 1
        sort!(topology.components;by=indices->minimum(m.node_keys[node][axis_index] for index in indices for node in surface[index].nodes))
        segments=Dict{Tuple{String,Int},Int}()
        for (strip,indices) in enumerate(topology.components)
            items=surface[indices];first_index=minimum(m.node_keys[node][axis_index] for face in items for node in face.nodes)
            index=is_spar ? clamp(searchsortedlast(m.grid.ribs,first_index),1,length(m.grid.ribs)-1) : number
            part=is_spar ? (number==0 ? "front_web" : "rear_web") : "rib_web"
            key=is_spar ? "$part:$index" : "$part:$index:strip:$strip"
            segment=get(segments,(part,index),0)+1;segments[(part,index)]=segment
            is_spar&&segment>1&&(key*="-segment-$segment")
            rowlabel=is_spar ? (number==0 ? "Front spar" : "Rear spar") : "Web strip $strip"
            location=component_rf_location(is_spar ? "sparwebs" : "ribwebs",part,index,is_spar ? part : "$part:strip$strip",rowlabel;key)
            row=Dict{String,Any}("key"=>key,"kind"=>is_spar ? "spar_web" : "rib_web","label"=>"$rowlabel · $(location["columnLabel"])",
                "part"=>part,"rib_bay"=>is_spar ? index : nothing,"rib"=>is_spar ? nothing : index,"strip_index"=>strip,
                "locations"=>[location],"property_ids"=>sort!(unique(face.pid for face in items)),
                "member_element_ids"=>sort!(unique(face.eid for face in items)),"membership_complete"=>all(data.eid_counts[face.eid]==1 for face in items),
                "applicable"=>true,"status"=>"unassessed","reason"=>"","length_m"=>0.,"width_m"=>0.,"elements"=>Any[],
                "fixity_coefficient"=>Float64(get(m.params,is_spar ? COMPONENT_RF_FIXITY_KEYS[1] : COMPONENT_RF_FIXITY_KEYS[2],1.)),
                "result_frame"=>"Boxer shell material axes after element_results_payload rotation",
                "method"=>"Equivalent rectangular supported web plate; actual connected support paths; membrane-free laminate bending rigidity; spatial element membrane resultants")
            push!(rows,row)
            try
                component_rf_web_geometry!(row,m,items,Set(indices),topology.owners,support,axis_index,sections,laws)
            catch failure
                failure isa ArgumentError||rethrow();row["reason"]=sprint(showerror,failure);empty!(row["elements"])
            end
        end
    end
    rows
end

function component_rf_blade_bar(definition,material,eid,pid,member_length)
    get(definition,"type","")=="PBARL"&&get(definition,"shape","")=="T"||
        throw(ArgumentError("The free-web check requires an actual PBARL T section"))
    b,h,tf,tw=Float64.(definition["dimensions_m"]);nu=Float64(material["nu"]);young=Float64(material["E"])
    all(isfinite,(b,h,tf,tw,nu,young,member_length))&&min(b,h,tf,tw,young,member_length)>0&&-1<nu<.5&&h>tf||
        throw(ArgumentError("The T free web has invalid dimensions, material or member length"))
    Dict("eid"=>eid,"pid"=>pid,"length_m"=>member_length,"source"=>"PBARL","section_shape"=>"T",
        "dimensions_m"=>[b,h,tf,tw],"web_height_m"=>h-tf,"web_thickness_m"=>tw,"young_pa"=>young,
        "poisson"=>nu,"material_id"=>Int(material["id"]),"material_type"=>"MAT1")
end

function component_column_buckling_payload(m,data)
    members=Dict{Tuple{Symbol,Int,Int,Int},Vector{Tuple{ElemGroup,Int}}}()
    for group in m.groups
        group.kind===:bar||continue;base=component_base_pid(group.pid)
        base in (PID_SPAR_CAP,PID_RIB_STIFFENER)||continue
        for index in eachindex(group.eids)
            a,b=m.node_keys[group.conn[2index-1]],m.node_keys[group.conn[2index]]
            identity=if base==PID_SPAR_CAP
                bay=clamp(searchsortedlast(m.grid.ribs,min(a[2],b[2])),1,length(m.grid.ribs)-1)
                (:cap,a[1],a[3],bay)
            else
                rib=findfirst(==(a[2]),m.grid.ribs);rib===nothing&&continue
                (:stiffener,a[1],rib,0)
            end
            push!(get!(members,identity,Tuple{ElemGroup,Int}[]),(group,index))
        end
    end
    rows=Dict{String,Any}[];blades=Dict{String,Any}[]
    for (identity,items) in sort!(collect(members);by=first)
        kind,position,height,bay=identity;iscap=kind==:cap;rib=iscap ? nothing : height
        ordinal=iscap ? 0 : something(findfirst(==(position),m.grid.stringer_indices),0)
        part=iscap ? (position==0 ? "front" : "rear")*(height==0 ? "_lower_cap" : "_upper_cap") : "rib_stiffener"
        index=iscap ? bay : rib;key=iscap ? "$part:$index" : "$part:$index:stringer:$ordinal"
        rowlabel=iscap ? titlecase(replace(part,'_'=>' ')) : "Stiffener $ordinal"
        location=component_rf_location(iscap ? "sparcaps" : "ribstiffeners",part,index,iscap ? part : "$part:$ordinal",rowlabel;key)
        eids=[group.eids[element] for (group,element) in items];pids=sort!(unique(group.pid for (group,element) in items))
        row=Dict{String,Any}("key"=>key,"kind"=>iscap ? "spar_cap" : "rib_stiffener","label"=>"$rowlabel · $(location["columnLabel"])",
            "part"=>part,"rib_bay"=>iscap ? index : nothing,"rib"=>rib,"stringer"=>ordinal,"locations"=>[location],
            "pid"=>length(pids)==1 ? only(pids) : nothing,"property_ids"=>pids,"member_element_ids"=>sort!(unique(eids)),
            "membership_complete"=>all(data.eid_counts[eid]==1 for eid in eids),"applicable"=>true,"length_m"=>0.,"stations"=>Any[],
            "status"=>"unassessed","reason"=>"","fixity_coefficient"=>Float64(get(m.params,iscap ? COMPONENT_RF_FIXITY_KEYS[3] : COMPONENT_RF_FIXITY_KEYS[4],1.)),
            "method"=>"Bare-member elastic Euler column; actual section centroidal principal bending stiffness and full modeled support-to-support path; no tributary skin or web stiffness credit")
        push!(rows,row)
        blade=iscap ? nothing : merge(copy(row),Dict{String,Any}("bars"=>Any[],"kind"=>"rib_stiffener_blade",
            "method"=>"Elastic isotropic long outstand plate; supported T flange junction and free web tip; arithmetic mean of signed bar axial stresses"))
        blade===nothing||push!(blades,blade)
        try
            row["membership_complete"]||throw(ArgumentError("A column element ID occurs more than once"))
            edges=[skin_edge(group.conn[2element-1:2element]...) for (group,element) in items]
            chain=skin_boundary_chain(edges);endnodes=(first(chain),last(chain))
            if iscap
                levels=sort([m.node_keys[node][2] for node in endnodes])
                levels==m.grid.ribs[bay:bay+1]||throw(ArgumentError("The cap does not span two adjacent actual ribs"))
                all(any(node in get(data.ribnodes,r,Set{Int}()) for node in endnodes) for r in bay:bay+1)||
                    throw(ArgumentError("The cap endpoints have no modeled rib-web support"))
            else
                sort([m.node_keys[node][3] for node in endnodes])==[0,m.grid.nh]||
                    throw(ArgumentError("The rib stiffener does not span the full skin-to-skin height"))
                all(any(node in data.skinnodes[k] for node in endnodes) for k in (0,m.grid.nh))||
                    throw(ArgumentError("The rib stiffener endpoints have no modeled skin support"))
            end
            length_m=sum(norm3(skin_xyz(m,b).-skin_xyz(m,a)) for (a,b) in edges)
            length_m>1e-10&&isfinite(length_m)||throw(ArgumentError("The column has zero or invalid length"))
            row["length_m"]=length_m;row["end_grid_ids"]=m.node_ids[collect(endnodes)]
            for (station,(group,element)) in enumerate(items)
                definition=section_definition(m.params,group.pid);material=bar_material_definition(m.params,group.pid)
                get(material,"type","MAT1")=="MAT1"||throw(ArgumentError("The bare beam-column check requires isotropic beam material"))
                young=Float64(material["E"]);area=Float64(definition["area_m2"])
                i1=Float64(definition["I1_m4"]);i2=Float64(definition["I2_m4"])
                all(isfinite,(young,area,i1,i2))&&min(young,area,i1,i2)>0||throw(ArgumentError("The column section has invalid axial or bending stiffness"))
                points=element_points(m,group,element);member_length=norm3(points[2].-points[1]);axis=unit3(points[2].-points[1])
                v=Tuple(group.orient[3element-2:3element]);y=unit3(v.-euler_dot(v,axis).*axis);z=cross3(axis,y)
                partrow=Dict{String,Any}("eid"=>group.eids[element],"pid"=>group.pid,"part"=>part,"area_m2"=>area,
                    "axial_matrix"=>[[young*area,0.,0.],[0.,young*i2,0.],[0.,0.,young*i1]],
                    "material_ids"=>[Int(material["id"])],"source_section"=>definition)
                push!(row["stations"],Dict("id"=>station,"origin_m"=>collect((points[1].+points[2])./2),"axis"=>collect(axis),
                    "section_y"=>collect(y),"section_z"=>collect(z),"parts"=>[partrow],
                    "force_terms"=>[Dict("eid"=>group.eids[element],"pid"=>group.pid,"kind"=>"beam_axial")]))
                if blade!==nothing
                    try
                        push!(blade["bars"],component_rf_blade_bar(definition,material,group.eids[element],group.pid,member_length))
                    catch failure
                        failure isa ArgumentError||rethrow()
                        blade["reason"]=sprint(showerror,failure)
                    end
                end
            end
            row["status"]="ready"
            if blade!==nothing
                blade["length_m"]=length_m
                isempty(blade["reason"]) ? (blade["status"]="ready") : empty!(blade["bars"])
            end
        catch failure
            failure isa ArgumentError||rethrow();row["reason"]=sprint(showerror,failure);empty!(row["stations"])
            if blade!==nothing;blade["reason"]=row["reason"];empty!(blade["bars"]);end
        end
    end
    (;columns=rows,blades)
end

function component_buckling_payload(m::Model)
    is_imported_model(m)&&return Dict("web_panels"=>Any[],"columns"=>Any[],"blades"=>Any[])
    data=component_rf_faces(m,stringer_path(m.grid.wing,m.params));columns=component_column_buckling_payload(m,data)
    Dict("web_panels"=>component_web_buckling_payload(m,data),"columns"=>columns.columns,"blades"=>columns.blades)
end
