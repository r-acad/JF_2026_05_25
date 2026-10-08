# Physical rib / rib-bay overrides. Editable rows remain independent of shell
# refinement; generated property IDs retain the component's base family.
const RIB_STIFFENER_FIELDS=("flange_width","height","flange_thickness","web_thickness")
const RIB_STIFFENER_DEFAULTS=(.03,.032,.002,.002)
const COMPONENT_PID_STRIDE=1_000_000

function normalize_component_properties(value,key::AbstractString)
    key in ("properties.ribs","properties.spar_bays")||throw(ArgumentError("unknown component property table $key"))
    value isa AbstractVector||throw(ArgumentError("$key must be an array of property tables"))
    length(value)<=100001||throw(ArgumentError("$key permits at most 100001 property rows"))
    ribs=key=="properties.ribs";indexkey=ribs ? "rib" : "bay"
    allowed=ribs ? Set((indexkey,"thickness","stiffener_enabled",RIB_STIFFENER_FIELDS...)) : Set((indexkey,"front_thickness","rear_thickness"))
    seen=Set{Int}();out=Dict{String,Any}[]
    for (index,raw) in enumerate(value)
        raw isa AbstractDict||throw(ArgumentError("$key row $index must be a table"))
        all(k->k isa AbstractString||k isa Symbol,keys(raw))||throw(ArgumentError("$key row $index has invalid field names"))
        row=Dict(String(k)=>v for (k,v) in raw)
        all(k->k in allowed,keys(row))||throw(ArgumentError("$key row $index contains an unsupported property"))
        id=get(row,indexkey,nothing)
        id isa Real&&!(id isa Bool)&&isfinite(id)&&isinteger(id)&&1<=id<=100001||
            throw(ArgumentError("$key row $index $indexkey must be a positive integer"))
        id=Int(id);id in seen&&throw(ArgumentError("$key has more than one row for $indexkey $id; combine its properties in one row"))
        push!(seen,id);row[indexkey]=id
        length(row)>1||throw(ArgumentError("$key $indexkey $id needs at least one property override"))
        for (field,v) in row
            field==indexkey&&continue
            if field=="stiffener_enabled"
                v isa Bool||throw(ArgumentError("$key $indexkey $id stiffener_enabled must be true or false"))
            else
                v isa Real&&!(v isa Bool)&&isfinite(v)&&v>0||throw(ArgumentError("$key $indexkey $id $field must be a finite positive length in metres"))
                row[field]=Float64(v)
            end
        end
        push!(out,row)
    end
    return sort!(out,by=row->row[indexkey])
end

function validate_t_section_dimensions(dimensions,label)
    b,h,tf,tw=dimensions
    all(v->v isa Real&&!(v isa Bool)&&isfinite(v)&&v>0,dimensions)||throw(ArgumentError("$label dimensions must be finite positive lengths in metres"))
    tf<h&&tw<b||throw(ArgumentError("$label requires flange thickness < overall height and web thickness < flange width"))
    return nothing
end

function rib_stiffener_dimensions(p::AbstractDict,rib::Integer=0)
    defaults=ntuple(i->Float64(get(p,"properties.rib_stiffener_"*RIB_STIFFENER_FIELDS[i],RIB_STIFFENER_DEFAULTS[i])),4)
    rib==0&&return defaults
    row=component_property_row(p,"properties.ribs",rib)
    return ntuple(i->Float64(get(row,RIB_STIFFENER_FIELDS[i],defaults[i])),4)
end

function validate_rib_stiffener_defaults(p::AbstractDict)
    enabled=get(p,"properties.rib_stiffeners_enabled",true)
    enabled isa Bool||throw(ArgumentError("properties.rib_stiffeners_enabled must be true or false"))
    validate_t_section_dimensions(rib_stiffener_dimensions(p),"Default rib T stiffener")
    for row in normalize_component_properties(get(p,"properties.ribs",Any[]),"properties.ribs")
        dims=ntuple(i->get(row,RIB_STIFFENER_FIELDS[i],rib_stiffener_dimensions(p)[i]),4)
        validate_t_section_dimensions(dims,"Rib $(row["rib"]) T stiffener")
    end
    return nothing
end

function validate_component_property_bounds(p::AbstractDict,rib_count::Integer)
    for (key,indexkey,limit) in (("properties.ribs","rib",rib_count),("properties.spar_bays","bay",rib_count-1))
        for row in normalize_component_properties(get(p,key,Any[]),key)
            row[indexkey]<=limit||throw(ArgumentError("$key selects $indexkey $(row[indexkey]), but the generated layout has $limit physical $(indexkey)s; edit the property table after changing the rib layout"))
        end
    end
    validate_rib_stiffener_defaults(p)
    return nothing
end

function component_property_row(p::AbstractDict,key::String,index::Integer)
    indexkey=key=="properties.ribs" ? "rib" : "bay"
    for row in get(p,key,Any[])
        get(row,indexkey,0)==index&&return row
    end
    return Dict{String,Any}()
end

function component_base_pid(pid::Integer)
    family=pid÷COMPONENT_PID_STRIDE
    family==1&&return PID_RIB_WEB
    family==2&&return PID_RIB_STIFFENER
    family in (3,4)&&return PID_SPAR_WEB
    family==5&&return PID_SKIN_UPPER
    family==6&&return PID_SKIN_LOWER
    family==7&&return PID_STRINGER
    return Int(pid)
end

component_base_group(name::AbstractString)=replace(replace(String(name),r"_KINKS$"=>""),r"_P[0-9]+$"=>"")

"""Resolve physical component overrides once, before generating any elements."""
function resolved_component_properties(p::AbstractDict,rib_count::Integer)
    validate_component_property_bounds(p,rib_count)
    ribrows=Dict(row["rib"]=>row for row in normalize_component_properties(get(p,"properties.ribs",Any[]),"properties.ribs"))
    bayrows=Dict(row["bay"]=>row for row in normalize_component_properties(get(p,"properties.spar_bays",Any[]),"properties.spar_bays"))
    tr=shell_thickness(p,PID_RIB_WEB);ts=shell_thickness(p,PID_SPAR_WEB)
    dimensions=rib_stiffener_dimensions(p);enabled=get(p,"properties.rib_stiffeners_enabled",true)
    ribs=map(1:rib_count) do rib
        row=get(ribrows,rib,Dict{String,Any}());thickness=Float64(get(row,"thickness",tr))
        dims=ntuple(i->Float64(get(row,RIB_STIFFENER_FIELDS[i],dimensions[i])),4)
        (;rib,thickness,stiffener_enabled=get(row,"stiffener_enabled",enabled),dimensions=dims,
            web_pid=thickness==tr ? PID_RIB_WEB : COMPONENT_PID_STRIDE+rib,
            stiffener_pid=dims==dimensions ? PID_RIB_STIFFENER : 2COMPONENT_PID_STRIDE+rib)
    end
    bays=map(1:rib_count-1) do bay
        row=get(bayrows,bay,Dict{String,Any}())
        front=Float64(get(row,"front_thickness",ts));rear=Float64(get(row,"rear_thickness",ts))
        (;bay,front_thickness=front,rear_thickness=rear,
            front_pid=front==ts ? PID_SPAR_WEB : 3COMPONENT_PID_STRIDE+bay,
            rear_pid=rear==ts ? PID_SPAR_WEB : 4COMPONENT_PID_STRIDE+bay)
    end
    return (;ribs,bays)
end

resolved_component_properties(m::Model)=resolved_component_properties(m.params,length(m.grid.ribs))

function nominal_shell_thickness(p::AbstractDict,pid::Integer)
    family,index=divrem(pid,COMPONENT_PID_STRIDE)
    if family in (PANEL_UPPER_FAMILY,PANEL_LOWER_FAMILY)
        row=panel_property_override(p,pid,"skin")
        haskey(row,"thickness")&&return Float64(row["thickness"])
    end
    family==1&&return Float64(get(component_property_row(p,"properties.ribs",index),"thickness",p["properties.t_rib_web"]))
    family in (3,4)&&return Float64(get(component_property_row(p,"properties.spar_bays",index),family==3 ? "front_thickness" : "rear_thickness",p["properties.t_spar_web"]))
    pid=component_base_pid(pid)
    key=pid==PID_SKIN_UPPER ? "properties.t_skin_upper" : pid==PID_SKIN_LOWER ? "properties.t_skin_lower" :
        pid==PID_SPAR_WEB ? "properties.t_spar_web" : pid==PID_RIB_WEB ? "properties.t_rib_web" :
        pid==PID_LE_SKIN ? "leading_edge.t_skin" : pid==PID_LE_RIB ? "leading_edge.t_rib" :
        pid==PID_AERO ? "output.t_aero_shell" : nothing
    key===nothing&&throw(ArgumentError("no shell thickness for PID $pid"))
    return Float64(p[key])
end

shell_thickness(p::AbstractDict,pid::Integer)=shell_material_definition(p,pid)["thickness_m"]

"""Actual referenced property cards, shared by deck, reports and payloads."""
function model_property_definitions(m::Model)
    register_panel_properties!(m.params,m.grid)
    entries=Dict{Int,Dict{String,Any}}()
    for group in m.groups
        isempty(group.eids)&&continue
        haskey(entries,group.pid)&&continue
        entry=Dict{String,Any}("pid"=>group.pid,"base_pid"=>component_base_pid(group.pid),"kind"=>group.kind==:bar ? "bar" : "shell")
        if group.kind==:bar
            entry["section"]=section_definition(m.params,group.pid)
            material=bar_material_definition(m.params,group.pid)
            entry["material_id"]=material["id"];entry["material"]=material_payload(material)
        else
            merge!(entry,shell_material_definition(m.params,group.pid))
        end
        entries[group.pid]=entry
    end
    return [entries[pid] for pid in sort!(collect(keys(entries)))]
end

"""A default family retains its familiar group name; only overrides add a PID suffix."""
function property_group!(groups,cache,name,kind,pid,default_pid)
    return get!(cache,pid) do
        group=ElemGroup(pid==default_pid ? name : name*"_P"*string(pid),kind,pid)
        push!(groups,group);group
    end
end
