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
    base==PID_STRINGER && return "stringer"
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
    Float64(value)
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
