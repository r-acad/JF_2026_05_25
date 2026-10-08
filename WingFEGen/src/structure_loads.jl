# Explicit structural body forces. These dead FORCE/MOMENT cards work in both
# SOL101 and SOL106 without selecting fuel CONM2 or optional unconnected aero shells.
const STRUCTURE_MASS_LOCK=ReentrantLock()
const STRUCTURE_MASS_CACHE=Ref{Any}(nothing)

# A concrete record keeps geometry kernels and nodal accumulation type-stable.
# The previous Vector{NamedTuple} forced dynamic field lookup for every source
# at every span cut, and allocated temporary vectors for each nodal addition.
struct StructuralMassSource
    kind::Symbol
    nodes::Vector{Int}
    fractions::Vector{Float64}
    points::Vector{NTuple{3,Float64}}
    mass::Float64
    center::NTuple{3,Float64}
    offset::NTuple{3,Float64}
    normal::NTuple{3,Float64}
    area::Float64
    centroid_shift::NTuple{3,Float64}
    ymin::Float64
    ymax::Float64
end
function StructuralMassSource(kind,nodes,fractions,points,mass,center,offset,normal,area,shift)
    lo,hi=extrema(point[2] for point in points)
    StructuralMassSource(kind,nodes,fractions,points,mass,center,offset,normal,area,shift,lo,hi)
end
struct StructuralMassData
    sources::Vector{StructuralMassSource}
    nodal_mass::Vector{Float64}
    nodal_offset_mass::Matrix{Float64}
end

"""Consistent Q4 body-load weights on its projected element plane."""
function quad_body_shape_weights(points,normal)
    weights=zeros(4);signs=((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.))
    for xi in (-inv(sqrt(3.)),inv(sqrt(3.))),eta in (-inv(sqrt(3.)),inv(sqrt(3.)))
        shape=[(1+sx*xi)*(1+sy*eta)/4 for (sx,sy) in signs]
        dx=ntuple(k->sum(signs[i][1]*(1+signs[i][2]*eta)*points[i][k]/4 for i in 1:4),3)
        dy=ntuple(k->sum(signs[i][2]*(1+signs[i][1]*xi)*points[i][k]/4 for i in 1:4),3)
        jac=abs(sum(cross3(dx,dy).*normal));weights.+=jac.*shape
    end
    weights
end

function structural_mass_data(m::Model)::StructuralMassData
    signature=hash(sort!([k=>v for (k,v) in m.params if startswith(k,"properties.")||startswith(k,"material.")||startswith(k,"materials.")||k in ("leading_edge.t_skin","leading_edge.t_rib")];by=first))
    lock(STRUCTURE_MASS_LOCK) do
        cached=STRUCTURE_MASS_CACHE[]
        cached!==nothing&&cached.groups===m.groups&&cached.xyz===m.xyz&&cached.signature==signature&&return cached.data
        sources=StructuralMassSource[]
        for gr in m.groups
            if gr.kind===:bar
                section=section_definition(m.params,gr.pid);density=Float64(bar_material_definition(m.params,gr.pid)["rho"])
                area=Float64(section["area_m2"])
                for e in 1:n_elements(gr)
                    nodes=gr.conn[2*e-1:2*e];points=element_points(m,gr,e);offset=bar_section_offset(m,gr,e)
                    mass=norm3(points[2].-points[1])*area*density
                    shifted=[point.+offset for point in points];center=(shifted[1].+shifted[2])./2
                    # Span cuts follow the beam GRID line; the cross-section
                    # centroid offset contributes its actual force couple.
                    push!(sources,StructuralMassSource(:line,nodes,[.5,.5],points,mass,center,offset,(0.,0.,0.),0.,(0.,0.,0.)))
                end
            else
                areal=Float64(shell_material_definition(m.params,gr.pid)["areal_mass_kg_m2"]);n=gr.kind===:quad ? 4 : 3
                for e in 1:n_elements(gr)
                    nodes=gr.conn[n*(e-1)+1:n*e];points=element_points(m,gr,e)
                    normal=unit3(n==4 ? cross3(points[3].-points[1],points[4].-points[2]) : cross3(points[2].-points[1],points[3].-points[1]))
                    triangles=Tuple{Vector{NTuple{3,Float64}},Float64,NTuple{3,Float64}}[]
                    for ids in (n==4 ? ((1,2,3),(1,3,4)) : ((1,2,3),))
                        tri=[points[i] for i in ids];area=abs(sum(cross3(tri[2].-tri[1],tri[3].-tri[1]).*normal))/2
                        area>0||continue
                        center=ntuple(k->sum(point[k] for point in tri)/3,3)
                        push!(triangles,(tri,area,center))
                    end
                    total_area=sum(t[2] for t in triangles)
                    fractions=n==4 ? quad_body_shape_weights(points,normal)./total_area : fill(1/3,3)
                    consistent_center=ntuple(k->sum(fractions[i]*points[i][k] for i in 1:n),3)
                    triangle_center=ntuple(k->sum(t[2]*t[3][k] for t in triangles)/total_area,3)
                    shift=consistent_center.-triangle_center
                    # Cuts integrate the projected polygon as linear triangles.
                    # A constant first-moment correction accounts for Q4 warpage;
                    # planar elements need no correction. Applied Q4 nodal forces
                    # always use the bilinear shape functions, without diagonal bias.
                    for (points,area,center) in triangles
                        push!(sources,StructuralMassSource(:triangle,nodes,fractions,points,area*areal,center.+shift,(0.,0.,0.),normal,area,shift))
                    end
                end
            end
        end
        nodal_mass=zeros(m.n_struct);offset_mass=zeros(3,m.n_struct)
        for source in sources,(node,fraction) in zip(source.nodes,source.fractions)
            mass=source.mass*fraction;nodal_mass[node]+=mass
            for k in 1:3;offset_mass[k,node]+=mass*source.offset[k];end
        end
        data=StructuralMassData(sources,nodal_mass,offset_mass)
        STRUCTURE_MASS_CACHE[]=(groups=m.groups,xyz=m.xyz,signature=signature,data=data)
        return data
    end
end

structural_mass_sources(m::Model)=structural_mass_data(m).sources

function structure_acceleration(p)
    get(p,"loads.structure_inertia",false)||return (0.,0.,0.)
    factor=WEIGHT_GRAVITY*Float64(p["loads.load_factor"])
    return ntuple(k->factor*Float64(p["loads.fuel_accel_"*("x","y","z")[k]]),3)
end

function structure_applied_loads(m::Model;params=m.params)
    acceleration=structure_acceleration(params);all(iszero,acceleration)&&return NamedTuple[]
    data=structural_mass_data(m)
    return [(node=node-1,gid=m.node_ids[node],force=data.nodal_mass[node].*acceleration,
        moment=cross3(ntuple(k->data.nodal_offset_mass[k,node],3),acceleration))
        for node in 1:m.n_struct if data.nodal_mass[node]>0]
end
