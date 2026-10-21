# Editable family defaults are the minimum dimensions for local sizing. Keep
# enforcement separate from property resolution: never silently clamp a mesh,
# PBARL, or laminate, and never invent sizing bounds for imported properties.
const MINIMUM_SHELL_KEYS=Dict("upper_skin"=>"properties.t_skin_upper",
    "lower_skin"=>"properties.t_skin_lower","spar_web"=>"properties.t_spar_web",
    "rib_web"=>"properties.t_rib_web","leading_edge_skin"=>"leading_edge.t_skin",
    "leading_edge_rib"=>"leading_edge.t_rib")

minimum_gauge_tolerance(value,minimum)=1e-10*max(abs(Float64(value)),abs(Float64(minimum)),1e-12)
function minimum_dimension(field,value,minimum,key;label=field)
    value=Float64(value);minimum=Float64(minimum)
    isfinite(value)&&isfinite(minimum)&&minimum>=0||throw(ArgumentError("$label needs finite dimensions and a nonnegative minimum"))
    tolerance=minimum_gauge_tolerance(value,minimum)
    value+tolerance>=minimum||throw(ArgumentError("$label = $value m is below its minimum $minimum m ($key). Increase the local value or deliberately lower that family minimum."))
    Dict{String,Any}("field"=>String(field),"value_m"=>value,"minimum_m"=>minimum,
        "minimum_key"=>String(key),"at_minimum"=>value<=minimum+tolerance)
end

function minimum_shell_total(p,component)
    key=MINIMUM_SHELL_KEYS[component];floor=Float64(p[key])
    assignment=material_assignment(p,component)
    if assignment["kind"]=="sandwich"
        stackfloor=2Float64(assignment["face_thickness"])+Float64(assignment["core_thickness"])
        if stackfloor>floor
            return stackfloor,"materials.shells#$component#face_thickness + core_thickness"
        end
    end
    floor,key
end

function minimum_shell_dimensions(p,component,definition;prefix="")
    floor,key=minimum_shell_total(p,component)
    dimensions=Dict{String,Any}[minimum_dimension(prefix*"thickness",definition["thickness_m"],floor,key;label="$component total thickness")]
    assignment=material_assignment(p,component)
    if get(definition,"construction","")=="sandwich"&&assignment["kind"]=="sandwich"
        for field in ("face_thickness","core_thickness")
            push!(dimensions,minimum_dimension(prefix*field,definition[field*"_m"],assignment[field],
                "materials.shells#$component#$field";label="$component $field"))
        end
    end
    dimensions
end

function minimum_stringer_dimensions(p,dimensions;prefix="")
    blade_only=shell_stringers(p)&&iszero(dimensions[1])
    out=Dict{String,Any}[]
    for (index,field) in enumerate(RIB_STIFFENER_FIELDS)
        # A zero-width shell blade has no attached flange. Its zero width is
        # allowed only when the editable family width minimum is also zero.
        blade_only&&field=="flange_thickness"&&continue
        push!(out,minimum_dimension(prefix*field,dimensions[index],p["properties.stringer_"*field],
            "properties.stringer_"*field;label="Stringer $field"))
    end
    out
end

function minimum_stiffener_dimensions(p,dimensions)
    [minimum_dimension(field,dimensions[index],p["properties.rib_stiffener_"*field],
        "properties.rib_stiffener_"*field;label="Rib stiffener $field") for (index,field) in enumerate(RIB_STIFFENER_FIELDS)]
end

minimum_stiffener_active(p,rib)=get(component_table_override(p,"rib_stiffener",rib),"enabled",
    get(component_property_row(p,"properties.ribs",rib),"stiffener_enabled",get(p,"properties.rib_stiffeners_enabled",true)))

"""Generated sizing bounds, in metres, for the actual property and its geometry."""
function property_minimum_gauge(p,pid::Integer;definition=nothing)
    not_applicable(reason)=Dict{String,Any}("status"=>"not_applicable","at_minimum"=>false,
        "can_reduce"=>false,"dimensions"=>Any[],"reason"=>reason)
    haskey(p,"imported.native")&&return not_applicable("Imported properties have no user-defined family minimum gauge.")
    if is_movable_pid(pid)
        family,index=divrem(pid,1_000_000);surface_index=index÷1000
        rows=movable_structure_rows(p)
        1<=surface_index<=length(rows)||throw(ArgumentError("Unknown movable property $pid"))
        row=rows[surface_index]
        field=("upper_thickness","lower_thickness","web_thickness","web_thickness","rib_thickness")[family-30]
        property=definition===nothing ? movable_shell_property(p,pid) : definition
        dimension=minimum_dimension("thickness",property["thickness_m"],row[field],
            "movable_structure.surfaces#$(row["surface"])#$field";label="$(row["surface"]) $field")
        return Dict{String,Any}("status"=>"known","at_minimum"=>dimension["at_minimum"],
            "can_reduce"=>!dimension["at_minimum"],"dimensions"=>[dimension])
    end
    base=component_base_pid(pid)
    dimensions=if base==PID_STRINGER||base in (PID_STRINGER_WEB,PID_STRINGER_FLANGE)
        result=minimum_stringer_dimensions(p,panel_stringer_dimensions(p,pid))
        if base==PID_STRINGER_FLANGE
            # The attached footprint is one physical shell. Both its added
            # flange and its chosen supporting skin must be non-reducible.
            property=definition===nothing ? shell_material_definition(p,pid) : definition
            skinpid=Int(property["underlying_skin_pid"])
            skin=shell_material_definition(p,skinpid)
            append!(result,minimum_shell_dimensions(p,shell_material_component(skinpid),skin;prefix="underlying_skin."))
            flange=shell_stringer_added_flange(p,pid)
            assignment=material_assignment(p,"stringer_flange")
            if flange.composite&&assignment["kind"]=="sandwich"
                face=Float64(assignment["face_thickness"])
                # A family with zero flange width may retain a zero/inactive
                # total minimum while individual panels add valid flanges.
                # Do not invent a positive core floor from that inactive total;
                # shell_stringer_added_flange still requires actual core > 0.
                corefloor=max(0.,Float64(p["properties.stringer_flange_thickness"])-2face)
                push!(result,minimum_dimension("added_flange.face_thickness",face,face,
                    "materials.shells#stringer_flange#face_thickness"))
                push!(result,minimum_dimension("added_flange.core_thickness",flange.thickness-2face,corefloor,
                    "properties.stringer_flange_thickness - 2*face_thickness"))
            end
        end
        result
    elseif base==PID_RIB_STIFFENER
        minimum_stiffener_dimensions(p,rib_stiffener_dimensions(p,pid==PID_RIB_STIFFENER ? 0 : pid%COMPONENT_PID_STRIDE))
    elseif base==PID_SPAR_CAP
        property=definition===nothing ? section_definition(p,pid) : get(definition,"section",definition)
        [minimum_dimension("side",property["dimensions_m"][1],p["properties.spar_cap_side"],"properties.spar_cap_side";label="Spar cap side")]
    elseif base in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_SPAR_WEB,PID_RIB_WEB,PID_LE_SKIN,PID_LE_RIB)
        property=definition===nothing ? shell_material_definition(p,pid) : definition
        minimum_shell_dimensions(p,shell_material_component(pid),property)
    else
        return not_applicable("This property is not controlled by a structural family minimum gauge.")
    end
    at_minimum=all(d->d["at_minimum"],dimensions)
    Dict{String,Any}("status"=>"known","at_minimum"=>at_minimum,"can_reduce"=>!at_minimum,"dimensions"=>dimensions)
end

# Validate sparse input without reconstructing a panel grid: layout identity
# remains the responsibility of register_panel_properties!, and every active
# geometric dimension is checked before that geometry is built.
function validate_minimum_shell_override(p,component,row=Dict();legacy_total=nothing)
    assignment=merge(material_assignment(p,component),row)
    if assignment["kind"]=="monolithic"
        thickness=get(row,"thickness",legacy_total===nothing ? p[MINIMUM_SHELL_KEYS[component]] : legacy_total)
        definition=Dict("thickness_m"=>thickness,"construction"=>"monolithic")
    else
        face=Float64(assignment["face_thickness"]);core=Float64(assignment["core_thickness"])
        # Match existing ownership exactly: detached sandwich tables own
        # face/core; only legacy rib/spar total overrides own core indirectly.
        !haskey(row,"core_thickness")&&legacy_total!==nothing&&(core=Float64(legacy_total)-2face)
        definition=Dict("thickness_m"=>2face+core,"construction"=>"sandwich",
            "face_thickness_m"=>face,"core_thickness_m"=>core)
    end
    minimum_shell_dimensions(p,component,definition)
    nothing
end

function validate_minimum_gauges(p)
    haskey(p,"imported.native")&&return nothing
    for component in keys(MINIMUM_SHELL_KEYS);validate_minimum_shell_override(p,component);end
    for row in get(p,"properties.panels",Any[])
        upper=startswith(row["key"],"upper:")
        try
            validate_minimum_shell_override(p,upper ? "upper_skin" : "lower_skin",get(row,"skin",Dict()))
            actual=merge(inherited_panel_properties(p,upper).stringer,get(row,"stringer",Dict()))
            minimum_stringer_dimensions(p,Tuple(actual[field] for field in RIB_STIFFENER_FIELDS))
        catch error
            throw(ArgumentError("Panel $(row["key"]): "*sprint(showerror,error)))
        end
    end
    for row in get(p,"properties.ribs",Any[])
        validate_minimum_shell_override(p,"rib_web",component_table_override(p,"rib_web",row["rib"]);legacy_total=get(row,"thickness",nothing))
        minimum_stiffener_active(p,row["rib"])&&minimum_stiffener_dimensions(p,rib_stiffener_dimensions(p,row["rib"]))
    end
    for row in get(p,"properties.spar_bays",Any[]), (part,field) in (("front_web","front_thickness"),("rear_web","rear_thickness"))
        validate_minimum_shell_override(p,"spar_web",component_table_override(p,part,row["bay"]);legacy_total=get(row,field,nothing))
    end
    for row in get(p,"properties.components",Any[])
        part,indextext=split(row["key"],':');index=parse(Int,indextext)
        if component_table_iscap(part)
            haskey(row,"side")&&minimum_dimension("side",row["side"],p["properties.spar_cap_side"],"properties.spar_cap_side";label=row["key"])
        elseif part=="rib_stiffener"
            minimum_stiffener_active(p,index)&&minimum_stiffener_dimensions(p,rib_stiffener_dimensions(p,index))
        else
            component=part in ("front_web","rear_web") ? "spar_web" : part=="rib_web" ? "rib_web" : part=="leading_rib" ? "leading_edge_rib" : "leading_edge_skin"
            legacy=part=="rib_web" ? get(component_property_row(p,"properties.ribs",index),"thickness",nothing) :
                part in ("front_web","rear_web") ? get(component_property_row(p,"properties.spar_bays",index),part=="front_web" ? "front_thickness" : "rear_thickness",nothing) : nothing
            validate_minimum_shell_override(p,component,row;legacy_total=legacy)
        end
    end
    nothing
end
