# Analytical Euler-column assessment geometry. These descriptors do not modify
# the FE mesh, material cards, constraints, loads or solver results.
import LinearAlgebra
euler_dot(a,b)=sum(a.*b)
euler_xyz(m,node)=Tuple(m.xyz[3node-2:3node])
struct EulerSectionFace
    eid::Int
    pid::Int
    panel_id::Union{Nothing,Int}
    part::String
    points::Vector{NTuple{3,Float64}}
    center::NTuple{3,Float64}
    radius::Float64
    axes::NTuple{3,NTuple{3,Float64}}
end

"""Intersection of a convex shell face with a plane; no extrapolated section."""
function euler_plane_segment(points,origin,axis;tol=1e-10)
    cuts=NTuple{3,Float64}[]
    distances=[euler_dot(point.-origin,axis) for point in points]
    (minimum(distances)>tol||maximum(distances)<-tol)&&return nothing
    all(d->abs(d)<=tol,distances)&&throw(ArgumentError("A shell lies in the section plane; its column contribution is undefined"))
    for i in eachindex(points)
        j=mod1(i+1,length(points));a,b=points[i],points[j];da,db=distances[i],distances[j]
        abs(da)<=tol&&push!(cuts,a)
        da*db<0&&push!(cuts,a.+(da/(da-db)).*(b.-a))
    end
    unique_cuts=NTuple{3,Float64}[]
    for point in cuts
        all(other->norm3(point.-other)>tol,unique_cuts)&&push!(unique_cuts,point)
    end
    length(unique_cuts)<2&&return nothing
    length(unique_cuts)==2||throw(ArgumentError("A distorted shell has more than one section intersection"))
    (unique_cuts[1],unique_cuts[2])
end

function euler_clip_segment(a,b,origin,transverse,lo,hi;tol=1e-10)
    ya=euler_dot(a.-origin,transverse);yb=euler_dot(b.-origin,transverse)
    dy=yb-ya
    if abs(dy)<=tol
        lo-tol<=ya<=hi+tol||return nothing
        return (a,b)
    end
    t1,t2=minmax((lo-ya)/dy,(hi-ya)/dy)
    t1=max(0.,t1);t2=min(1.,t2)
    t2-t1>tol||return nothing
    (a.+t1.*(b.-a),a.+t2.*(b.-a))
end

"""Centroidal moments of an arbitrarily oriented rectangular strip in y/z."""
function euler_rectangle(length,width,center,tangent,normal)
    area=length*width
    cy,cz=center;ty,tz=tangent;ny,nz=normal
    Dict{String,Any}("area_m2"=>area,"centroid_y_m"=>cy,"centroid_z_m"=>cz,
        "iyy_m4"=>area*(length^2*tz^2+width^2*nz^2)/12,
        "izz_m4"=>area*(length^2*ty^2+width^2*ny^2)/12,
        "iyz_m4"=>area*(length^2*ty*tz+width^2*ny*nz)/12)
end

"""Explicit physical ply stack, retaining its reference-plane eccentricity."""
function euler_shell_section(definition)
    kind=get(definition,"type","")
    if kind=="PSHELL"
        material=definition["material"];thickness=Float64(definition["thickness_m"])
        offset=Float64(get(definition,"shell_offset_m",0.))
        plies=[Dict("material"=>material,"material_id"=>material["id"],"thickness_m"=>thickness,"angle_deg"=>0.)]
    elseif kind=="PCOMP"
        plies=get(definition,"plies",Any[])
        isempty(plies)&&throw(ArgumentError("The laminate has no explicit plies"))
        thickness=sum(Float64(ply["thickness_m"]) for ply in plies)
        isapprox(thickness,Float64(definition["thickness_m"]);rtol=1e-10)||
            throw(ArgumentError("Laminate ply thicknesses do not cover its section"))
        offset=Float64(get(definition,"z0_m",-thickness/2))+thickness/2
    else
        throw(ArgumentError("Unsupported Euler shell section $kind"))
    end
    all(isfinite,(thickness,offset))&&thickness>0||throw(ArgumentError("Invalid Euler shell thickness or offset"))
    # Validate material laws once per property; directional condensation is
    # done at the actual section angle, not an assumed isotropic modulus.
    for ply in plies
        Float64(ply["thickness_m"])>0||throw(ArgumentError("A laminate ply has nonpositive thickness"))
        euler_material_q(ply["material"])
    end
    first_material=first(plies)["material"]
    homogeneous=all(ply->get(ply["material"],"type","")=="MAT1"&&
        ply["material"]["E_Pa"]==get(first_material,"E_Pa",nothing)&&
        ply["material"]["nu"]==get(first_material,"nu",nothing),plies)
    (;thickness,offset,plies,material_ids=unique(Int(ply["material_id"]) for ply in plies),
        homogeneous_young=homogeneous ? Float64(first_material["E_Pa"]) : nothing)
end

function euler_material_q(material)
    kind=get(material,"type","")
    if kind=="MAT1"
        e1=e2=Float64(material["E_Pa"]);nu=Float64(material["nu"]);g=e1/(2*(1+nu))
    elseif kind=="MAT8"
        e1=Float64(material["E1_Pa"]);e2=Float64(material["E2_Pa"])
        nu=Float64(material["nu12"]);g=Float64(material["G12_Pa"])
    else
        throw(ArgumentError("Unsupported Euler laminate material $kind"))
    end
    all(isfinite,(e1,e2,nu,g))&&min(e1,e2,g)>0&&1-nu^2*e2/e1>0||
        throw(ArgumentError("The laminate plane-stress material law is not positive definite"))
    den=1-nu^2*e2/e1
    [e1/den nu*e2/den 0.;nu*e2/den e2/den 0.;0. 0. g]
end

"""Directional CLT law, retaining axial extension/bending and their coupling.

The four transverse/shear membrane and curvature degrees of freedom are
statically condensed together, not ply by ply. The remaining [A B; B D]
refers to the original shell GRID plane. Engineering shear is used.
CLT reference: NASA RP-1351, Basic Mechanics of Laminated Composite Plates,
https://ntrs.nasa.gov/citations/19950009349 .
"""
function euler_laminate_axial(section,angle)
    if section.homogeneous_young!==nothing
        t,o=section.thickness,section.offset
        return section.homogeneous_young.*[t t*o;t*o t^3/12+t*o^2]
    end
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
    # Nondimensionalize curvature for stable condensation of thin skins.
    scale=LinearAlgebra.Diagonal([1.,1.,1.,1/section.thickness,1/section.thickness,1/section.thickness])
    normalized=scale*abd*scale;retained=[1,4];free=[2,3,5,6]
    factor=LinearAlgebra.cholesky(LinearAlgebra.Symmetric(normalized[free,free]);check=false)
    LinearAlgebra.issuccess(factor)||throw(ArgumentError("The laminate section law is singular or indefinite"))
    reduced=normalized[retained,retained]-normalized[retained,free]*(factor\normalized[free,retained])
    unscale=LinearAlgebra.Diagonal([1.,section.thickness]);reduced=unscale*reduced*unscale
    reduced=(reduced+transpose(reduced))/2
    all(isfinite,reduced)&&reduced[1,1]>0&&reduced[2,2]-reduced[1,2]^2/reduced[1,1]>0||
        throw(ArgumentError("The condensed laminate column law is not positive definite"))
    reduced
end

"""Integrate an eccentric laminate strip in [epsilon, d-epsilon/dy, d-epsilon/dz]."""
function euler_strip_matrix(law,width,center,tangent,normal,projection=1.)
    v=[1.,center[1],center[2]];t=[0.,tangent[1],tangent[2]];n=[0.,normal[1],normal[2]]
    a,b,d=law[1,1],law[1,2],law[2,2];p=projection
    # A cut through an oblique shell has thickness t/p. Its axial strain
    # projection is p^2, yielding p^3*A, p^2*B and p*D in the section energy.
    width*(p^3*a*(v*transpose(v)+(width^2/12)*(t*transpose(t)))+
        p^2*b*(v*transpose(n)+n*transpose(v))+p*d*(n*transpose(n)))
end

function euler_path_intersection(edges,origin,axis)
    hits=NTuple{3,Float64}[]
    for edge in edges
        a,b=edge.a,edge.b;da=euler_dot(a.-origin,axis);db=euler_dot(b.-origin,axis)
        abs(da)<=1e-10&&push!(hits,a)
        da*db<0&&push!(hits,a.+(da/(da-db)).*(b.-a))
        abs(db)<=1e-10&&push!(hits,b)
    end
    unique_hits=NTuple{3,Float64}[]
    for point in hits
        all(other->norm3(point.-other)>1e-8,unique_hits)&&push!(unique_hits,point)
    end
    length(unique_hits)==1||throw(ArgumentError("The adjacent stringer/spar does not have one intersection inside this rib bay"))
    only(unique_hits)
end

euler_edge_index(edges)=euler_face_index([(a=edge.a,b=edge.b,points=[edge.a,edge.b]) for edge in edges])
euler_path_intersection(index::EulerFaceIndex,origin,axis)=
    euler_path_intersection(euler_section_candidates(index,origin,axis,axis,0.,0.),origin,axis)

function euler_beam_parts(m,edge,origin,axis,y,z)
    gr=edge.group;index=edge.element;definition=section_definition(m.params,gr.pid)
    get(definition,"shape","")=="T"||throw(ArgumentError("Only actual T-section beam stringers are supported"))
    material=bar_material_definition(m.params,gr.pid);young=Float64(material["E"])
    b,h,tf,tw=definition["dimensions_m"];v=Tuple(gr.orient[3index-2:3index])
    local_y=unit3(v.-euler_dot(v,axis).*axis);local_z=cross3(axis,local_y)
    n=(euler_dot(local_y,y),euler_dot(local_y,z));t=(euler_dot(local_z,y),euler_dot(local_z,z))
    parts=Dict{String,Any}[]
    # The outer flange face lies on the FE GRID path. Decomposing the exact
    # T into two rectangles includes its centroid offset without overlap.
    for (width,height,level,name) in ((b,tf,-tf/2,"flange"),(tw,h-tf,-tf-(h-tf)/2,"web"))
        part=euler_rectangle(width,height,(level*n[1],level*n[2]),t,n)
        merge!(part,Dict("eid"=>gr.eids[index],"pid"=>gr.pid,"part"=>name,
            "young_pa"=>young,"material_young_pa"=>young,"projection_factor"=>1.,"material_id"=>material["id"]))
        push!(parts,part)
    end
    parts
end

function euler_shell_part(face,section,ends,origin,axis,y,z;laws=Dict{Tuple{Int,Float64},Matrix{Float64}}())
    a,b=ends;width=norm3(b.-a);width>1e-12||return nothing
    u,v,n=face.axes;ax=euler_dot(axis,u);ay=euler_dot(axis,v);projection=hypot(ax,ay)
    projection>1e-5||throw(ArgumentError("A contributing shell is normal to the column axis"))
    tangent=(euler_dot((b.-a)./width,y),euler_dot((b.-a)./width,z))
    normal=(euler_dot(n,y)/projection,euler_dot(n,z)/projection)
    center=(euler_dot((a.+b)./2 .- origin,y)+section.offset*normal[1]/projection,
        euler_dot((a.+b)./2 .- origin,z)+section.offset*normal[2]/projection)
    part=euler_rectangle(width,section.thickness/projection,center,tangent,normal)
    reference_center=(euler_dot((a.+b)./2 .- origin,y),euler_dot((a.+b)./2 .- origin,z))
    law=get!(laws,(face.pid,atan(ay,ax))) do
        euler_laminate_axial(section,atan(ay,ax))
    end
    matrix=euler_strip_matrix(law,width,reference_center,tangent,normal,projection)
    merge!(part,Dict("eid"=>face.eid,"pid"=>face.pid,"part"=>face.part,
        "axial_matrix"=>[collect(matrix[i,:]) for i in 1:3],
        "projection_factor"=>projection,"material_ids"=>section.material_ids,
        "thickness_m"=>section.thickness,"offset_m"=>section.offset))
    force=Dict{String,Any}("eid"=>face.eid,"pid"=>face.pid,"kind"=>"shell_membrane",
        "width_m"=>width,"coefficients"=>[ax^2/projection,ay^2/projection,2ax*ay/projection])
    (;part,force,interval=minmax(euler_dot(a.-origin,y),euler_dot(b.-origin,y)))
end

function euler_full_coverage(intervals,lo,hi)
    stop=lo;tol=max(1e-8,1e-6*(hi-lo))
    for (a,b) in sort(intervals)
        a>stop+tol&&return false
        stop=max(stop,b)
    end
    stop>=hi-tol
end

"""Lossless section-energy aggregation for compact browser transport."""
function euler_compact_parts(parts)
    matrix=zeros(3,3);area=0.;materials=Set{Int}();properties=Set{Int}()
    for part in parts
        a=Float64(part["area_m2"]);area+=a
        push!(properties,Int(part["pid"]))
        if haskey(part,"material_ids");union!(materials,Int.(part["material_ids"]))
        else;push!(materials,Int(part["material_id"]));end
        if haskey(part,"axial_matrix")
            for i in 1:3,j in 1:3;matrix[i,j]+=part["axial_matrix"][i][j];end
        else
            y,z,e=part["centroid_y_m"],part["centroid_z_m"],part["young_pa"]
            matrix.+=e.*[a a*y a*z;a*y part["izz_m4"]+a*y^2 part["iyz_m4"]+a*y*z;
                a*z part["iyz_m4"]+a*y*z part["iyy_m4"]+a*z^2]
        end
    end
    Any[Dict{String,Any}("area_m2"=>area,"axial_matrix"=>[collect(matrix[i,:]) for i in 1:3],
        "material_ids"=>sort!(collect(materials)),"property_ids"=>sort!(collect(properties)))]
end

"""Actual section cuts and force-integration weights, grouped by physical bay."""
function stringer_euler_payload(m::Model;layout=stiffened_panel_layout(m.grid),compact=false)
    is_imported_model(m)&&return Any[]
    isempty(layout.panels)&&return Any[]
    panels=Dict(p.id=>p for p in layout.panels)
    edges=Dict{Int,Vector{Any}}();spar_edges=Dict{Tuple{Int,Bool,Bool},Vector{Any}}()
    faces=Dict{Tuple{Int,Bool},Vector{EulerSectionFace}}();sections=Dict{Int,Any}()
    laws=Dict{Tuple{Int,Float64},Matrix{Float64}}()
    path=stringer_path(m.grid.wing,m.params)
    for gr in m.groups
        base=component_base_pid(gr.pid);panel_id=stiffened_panel_id(gr.pid)
        if gr.kind===:bar
            part=component_table_part(gr.pid)
            for e in eachindex(gr.eids)
                a,b=gr.conn[2*e-1:2*e];edge=(a=euler_xyz(m,a),b=euler_xyz(m,b),nodes=(a,b),group=gr,element=e)
                if base==PID_STRINGER&&haskey(panels,panel_id)
                    push!(get!(edges,panel_id,Any[]),edge)
                elseif part in ("front_upper_cap","front_lower_cap","rear_upper_cap","rear_lower_cap")
                    key=(gr.pid%COMPONENT_PID_STRIDE,occursin("upper",part),startswith(part,"front"))
                    push!(get!(spar_edges,key,Any[]),edge)
                end
            end
        elseif base in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_STRINGER_WEB,PID_STRINGER_FLANGE)
            upper=base==PID_SKIN_UPPER||base in (PID_STRINGER_WEB,PID_STRINGER_FLANGE)&&haskey(panels,panel_id)&&panels[panel_id].upper
            for e in eachindex(gr.eids)
                count=gr.kind===:quad ? 4 : 3;nodes=gr.conn[count*(e-1)+1:count*e]
                firstrow=minimum(m.node_keys[node][2] for node in nodes)
                bay=haskey(panels,panel_id) ? panels[panel_id].bay : clamp(searchsortedlast(m.grid.ribs,firstrow),1,length(m.grid.ribs)-1)
                part=base==PID_STRINGER_WEB ? "web" : base==PID_STRINGER_FLANGE ? "combined_flange" : "skin"
                points=element_points(m,gr,e);center=Tuple(sum(p[k] for p in points)/length(points) for k in 1:3)
                radius=maximum(norm3(point.-center) for point in points)
                face=EulerSectionFace(gr.eids[e],gr.pid,panel_id,part,points,center,radius,shell_material_frame(m,gr,e;path))
                push!(get!(faces,(bay,upper),EulerSectionFace[]),face)
            end
        end
    end
    if shell_stringers(m.params)
        register_shell_stringer_mass_geometry!(m.params,m.groups,m.xyz,m.grid)
        for panel in layout.panels
            for (a,b) in get(shell_stringer_attachment_edges(m.params),panel_stringer_web_pid(panel.id),Set{Tuple{Int,Int}}())
                push!(get!(edges,panel.id,Any[]),(a=euler_xyz(m,a),b=euler_xyz(m,b),nodes=(a,b),group=nothing,element=0))
            end
        end
    end
    # Spars bound the skin even if their cap bars have been removed. The
    # grid contains the actual perturbed/oriented spar surface coordinates.
    for bay in 1:length(m.grid.ribs)-1,upper in (true,false),front in (true,false)
        key=(bay,upper,front)
        isempty(get(spar_edges,key,Any[]))||continue
        i=front ? 0 : ni(m.grid);k=upper ? m.grid.nh : 0
        spar_edges[key]=Any[(a=grid_point(m.grid,i,j,k),b=grid_point(m.grid,i,j+1,k))
            for j in m.grid.ribs[bay]:m.grid.ribs[bay+1]-1]
    end
    column_edges=Dict{Tuple{Bool,Int},Vector{Any}}()
    for panel in layout.panels
        append!(get!(column_edges,(panel.upper,panel.column),Any[]),get(edges,panel.id,Any[]))
    end
    boundary_edges=Dict((upper,front)=>Any[edge for bay in 1:length(m.grid.ribs)-1
        for edge in get(spar_edges,(bay,upper,front),Any[])] for upper in (true,false),front in (true,false))
    column_indices=Dict(key=>euler_edge_index(items) for (key,items) in column_edges)
    boundary_indices=Dict(key=>euler_edge_index(items) for (key,items) in boundary_edges)
    # A normal cut near a swept internal rib can enter a neighboring bay.
    # Use actual neighboring faces/properties, never extrapolate this bay's
    # skin or substitute its thickness for a different physical region.
    face_indices=Dict(upper=>euler_face_index(EulerSectionFace[face for ((bay,side),items) in faces if side==upper for face in items]) for upper in (true,false))
    members_by_panel=Dict{Int,Vector{Int}}()
    for group in m.groups
        component_base_pid(group.pid) in (PID_STRINGER,PID_STRINGER_WEB,PID_STRINGER_FLANGE)||continue
        id=stiffened_panel_id(group.pid)
        id===nothing||append!(get!(members_by_panel,id,Int[]),group.eids)
    end
    rows=Dict{String,Any}[]
    for panel in layout.panels
        member_ids=Set(get(members_by_panel,panel.id,Int[]))
        row=Dict{String,Any}("panel_id"=>panel.id,"key"=>panel_key(panel),"skin"=>panel.upper ? "upper" : "lower",
            "rib_bay"=>panel.bay,"stringer"=>panel.stringer,"segment"=>panel.segment,
            "pid"=>shell_stringers(m.params) ? panel_stringer_web_pid(panel.id) : panel.stringer_pid,
            "length_m"=>0.,"fixity_coefficient"=>Float64(get(m.params,"stringers.euler_fixity_coefficient",1.)),
            "stations"=>Any[],"status"=>"unassessed","reason"=>"",
            "member_element_ids"=>Int[],"membership_complete"=>false,"applicable"=>true,
            "method"=>"Euler column; actual local section cuts and full rib-to-rib path length; free transverse laminate relaxation; oblique thin-strip projection")
        push!(rows,row)
        try
            panel.start_row==m.grid.ribs[panel.bay]&&panel.end_row==m.grid.ribs[panel.bay+1]||
                throw(ArgumentError("Stringer run-out segments do not have two rib end restraints"))
            current=get(edges,panel.id,Any[]);isempty(current)&&throw(ArgumentError("The stringer has no physical beam or blade attachment path"))
            row["length_m"]=sum(norm3(edge.b.-edge.a) for edge in current)
            row["length_m"]>1e-10||throw(ArgumentError("The rib-to-rib stringer length is zero"))
            for (index,edge) in enumerate(sort(current;by=edge->(edge.a[2]+edge.b[2])/2))
                origin=(edge.a.+edge.b)./2;axis=unit3(edge.b.-edge.a);axis[2]<0&&(axis=-1 .* axis)
                firstrow=min(m.node_keys[edge.nodes[1]][2],m.node_keys[edge.nodes[2]][2])
                firstrow=clamp(firstrow,panel.start_row,panel.end_row-1)
                eta=(m.grid.etas[firstrow+1]+m.grid.etas[firstrow+2])/2
                xc=(panel.upper ? m.grid.upper_xcs : m.grid.lower_xcs)[panel.column+1,firstrow+1]
                normal=-1 .* shell_stringer_inward(m.grid.wing,eta,xc,panel.upper)
                z=unit3(normal.-euler_dot(normal,axis).*axis);y=cross3(z,axis)
                active=[i for i in m.grid.stringer_indices if haskey(layout.bars,(i,firstrow,panel.upper))]
                position=findfirst(==(panel.column),active);position===nothing&&throw(ArgumentError("Stringer adjacency is unavailable at a section"))
                left=position==1 ? boundary_indices[(panel.upper,true)] : column_indices[(panel.upper,active[position-1])]
                right=position==length(active) ? boundary_indices[(panel.upper,false)] : column_indices[(panel.upper,active[position+1])]
                a=euler_path_intersection(left,origin,axis);b=euler_path_intersection(right,origin,axis)
                lo,hi=minmax(euler_dot(a.-origin,y)/2,euler_dot(b.-origin,y)/2)
                lo< -1e-10&&hi>1e-10||throw(ArgumentError("Adjacent skin boundaries do not bracket the stringer"))
                station=Dict{String,Any}("id"=>index,"origin_m"=>collect(origin),"axis"=>collect(axis),
                    "section_y"=>collect(y),"section_z"=>collect(z),"left_width_m"=>-lo,"right_width_m"=>hi,
                    "parts"=>Any[],"force_terms"=>Any[])
                coverage=Tuple{Float64,Float64}[];web_found=false
                if edge.group!==nothing
                    append!(station["parts"],euler_beam_parts(m,edge,origin,axis,y,z))
                    push!(station["force_terms"],Dict("eid"=>edge.group.eids[edge.element],"pid"=>edge.group.pid,"kind"=>"beam_axial"))
                    push!(member_ids,edge.group.eids[edge.element])
                end
                for face in euler_section_candidates(face_indices[panel.upper],origin,axis,y,lo,hi)
                    face.part=="web"&&panels[face.panel_id].column!=panel.column&&continue
                    # Reject whole face bounding spheres before allocating
                    # polygon cuts; most bay faces miss this local section.
                    delta=face.center.-origin
                    abs(euler_dot(delta,axis))>face.radius+1e-10&&continue
                    transverse=euler_dot(delta,y)
                    (transverse+face.radius<lo||transverse-face.radius>hi)&&continue
                    intersection=euler_plane_segment(face.points,origin,axis);intersection===nothing&&continue
                    clipped=euler_clip_segment(intersection...,origin,y,lo,hi);clipped===nothing&&continue
                    section=get!(sections,face.pid) do
                        euler_shell_section(shell_material_definition(m.params,face.pid))
                    end
                    cut=euler_shell_part(face,section,clipped,origin,axis,y,z;laws);cut===nothing&&continue
                    push!(station["parts"],cut.part);push!(station["force_terms"],cut.force)
                    push!(member_ids,face.eid)
                    face.part=="web" ? (web_found=true) : push!(coverage,cut.interval)
                end
                edge.group===nothing&&!web_found&&throw(ArgumentError("The shell stringer web does not intersect its section"))
                euler_full_coverage(coverage,lo,hi)||throw(ArgumentError("The full half-width skin strip is not covered by this rib-bay mesh section"))
                compact&&(station["parts"]=euler_compact_parts(station["parts"]))
                push!(row["stations"],station)
            end
            row["status"]="ready"
            row["membership_complete"]=true
        catch failure
            failure isa ArgumentError||rethrow()
            row["reason"]=sprint(showerror,failure)
            empty!(row["stations"])
        end
        row["member_element_ids"]=sort!(collect(member_ids))
    end
    rows
end
