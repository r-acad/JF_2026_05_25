# Distributed mass attached to existing structural property cards. Densities
# are independent of material density, thickness and section dimensions.
const NONSTRUCTURAL_COMPONENTS = (
    ("upper_skin", "Upper skins", "kg/m2"),
    ("lower_skin", "Lower skins", "kg/m2"),
    ("spar_web", "Spar webs", "kg/m2"),
    ("rib_web", "Rib webs", "kg/m2"),
    ("leading_edge_skin", "Leading-edge skins", "kg/m2"),
    ("leading_edge_rib", "Leading-edge ribs", "kg/m2"),
    ("stringer", "Stringers", "kg/m"),
    ("spar_cap", "Spar caps", "kg/m"),
    ("rib_stiffener", "Rib stiffeners", "kg/m"),
    ("runout", "Stringer run-out connectors", "kg/m"),
)

function nonstructural_mass_component(pid::Integer)
    base=component_base_pid(pid)
    base in (PID_STRINGER,PID_STRINGER_WEB,PID_STRINGER_FLANGE) && return "stringer"
    base==PID_SPAR_CAP && return "spar_cap"
    base==PID_RIB_STIFFENER && return "rib_stiffener"
    base==PID_STRINGER_RUNOUT && return "runout"
    shell_material_component(pid)
end

function nonstructural_mass_density(p,pid::Integer)
    component=nonstructural_mass_component(pid)
    # Aerodynamic loft shells are an optional, disconnected visualization
    # export. Structural NSM never attaches to that duplicate surface.
    component=="aero" && return 0.0
    key="nonstructural."*component
    value=get(p,key,0.)
    value isa Real && !(value isa Bool) && isfinite(value) && value>=0 ||
        throw(ArgumentError("$key must be a finite, nonnegative mass density"))
    if is_shell_stringer_pid(pid)
        # The existing input remains kg/m. Put it on the web once, including
        # blade-only stringers; the flange carries no second copy of that mass.
        component_base_pid(pid)==PID_STRINGER_FLANGE&&return 0.0
        return Float64(value)*shell_stringer_mass_area_factor(p,pid)
    end
    Float64(value)
end

const SHELL_STRINGER_MASS_GEOMETRY=Dict{UInt,Any}()
const SHELL_STRINGER_MASS_LOCK=ReentrantLock()

"""Convert stringer kg/m to web kg/m2 using each actual panel's mesh area."""
function register_shell_stringer_mass_geometry!(p,groups,xyz,g)
    shell_stringers(p)||return nothing
    existing=lock(SHELL_STRINGER_MASS_LOCK) do
        entry=get(SHELL_STRINGER_MASS_GEOMETRY,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p&&entry.groups.value===groups&&entry.xyz.value===xyz&&entry.grid.value===g
    end
    existing&&return nothing
    areas=Dict{Int,Float64}();attachment_edges=Dict{Int,Set{Tuple{Int,Int}}}()
    skin_nodes=Set(node for group in groups if component_base_pid(group.pid) in (PID_SKIN_UPPER,PID_SKIN_LOWER) for node in group.conn)
    for group in groups
        component_base_pid(group.pid)==PID_STRINGER_WEB||continue
        n=group.kind===:tria ? 3 : 4
        for e in eachindex(group.eids)
            nodes=group.conn[n*(e-1)+1:n*e]
            points=[Tuple(xyz[3node-2:3node]) for node in nodes]
            areas[group.pid]=get(areas,group.pid,0.)+weight_shell_area(points)
            for q in 1:n
                a,b=nodes[q],nodes[mod1(q+1,n)]
                a in skin_nodes&&b in skin_nodes||continue
                push!(get!(attachment_edges,group.pid,Set{Tuple{Int,Int}}()),minmax(a,b))
            end
        end
    end
    factors=Dict{Int,Float64}();lengths=Dict{Int,Float64}()
    for panel in stiffened_panel_layout(g).panels
        pid=panel_stringer_web_pid(panel.id);area=get(areas,pid,0.);area>0||continue
        edges=get(attachment_edges,pid,Set{Tuple{Int,Int}}())
        isempty(edges)&&throw(ArgumentError("shell stringer web property $pid has no shared skin attachment edges"))
        length=sum(norm3(Tuple(xyz[3b-2:3b].-xyz[3a-2:3a])) for (a,b) in edges)
        lengths[pid]=length;factors[pid]=length/area
    end
    lock(SHELL_STRINGER_MASS_LOCK) do
        filter!(pair->pair.second.owner.value!==nothing,SHELL_STRINGER_MASS_GEOMETRY)
        SHELL_STRINGER_MASS_GEOMETRY[objectid(p)]=(owner=WeakRef(p),groups=WeakRef(groups),xyz=WeakRef(xyz),grid=WeakRef(g),factors=factors,lengths=lengths,edges=attachment_edges)
    end
    nothing
end

function shell_stringer_attachment_edges(p)
    lock(SHELL_STRINGER_MASS_LOCK) do
        entry=get(SHELL_STRINGER_MASS_GEOMETRY,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p ? entry.edges : Dict{Int,Set{Tuple{Int,Int}}}()
    end
end

function shell_stringer_attachment_length(p,pid)
    lock(SHELL_STRINGER_MASS_LOCK) do
        entry=get(SHELL_STRINGER_MASS_GEOMETRY,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p ? get(entry.lengths,pid,nothing) : nothing
    end
end

function shell_stringer_mass_area_factor(p,pid)
    factor=lock(SHELL_STRINGER_MASS_LOCK) do
        entry=get(SHELL_STRINGER_MASS_GEOMETRY,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p ? get(entry.factors,pid,nothing) : nothing
    end
    factor!==nothing&&return factor
    b,h,tf,_=panel_stringer_dimensions(p,pid)
    inv(b==0 ? h : h-tf)
end

function validate_nonstructural_mass(p)
    for (component,_,_) in NONSTRUCTURAL_COMPONENTS
        key="nonstructural."*component;value=get(p,key,0.)
        value isa Real && !(value isa Bool) && isfinite(value) && value>=0 ||
            throw(ArgumentError("$key must be finite and nonnegative"))
    end
    nothing
end

bar_mass_per_length(p,pid)=section_definition(p,pid)["area_m2"]*bar_material_definition(p,pid)["rho"]+nonstructural_mass_density(p,pid)
