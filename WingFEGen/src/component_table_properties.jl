# Sparse physical component overrides used by the detached property tables.
# Families 1–7 are reserved for legacy rib/spar and stiffened-panel properties.
const COMPONENT_TABLE_PARTS=("front_upper_cap","front_lower_cap","rear_upper_cap","rear_lower_cap",
    "leading_upper_skin","leading_lower_skin","leading_rib","rib_web","rib_stiffener","front_web","rear_web")
const COMPONENT_SHELL_FIELDS=("thickness","kind","material","face_thickness","core_thickness","face_material","core_material")
component_table_family(component)=findfirst(==(component),COMPONENT_TABLE_PARTS)+7
component_table_part(pid)=8<=pid÷COMPONENT_PID_STRIDE<=18 ? COMPONENT_TABLE_PARTS[pid÷COMPONENT_PID_STRIDE-7] : nothing
component_table_isrib(part)=part in ("leading_rib","rib_web","rib_stiffener")
component_table_iscap(part)=endswith(part,"_cap")
component_table_key(part,index)="$part:$index"
function normalize_component_table_properties(value)
    value isa AbstractVector||throw(ArgumentError("properties.components must be an array of property tables"))
    length(value)<=100001||throw(ArgumentError("properties.components permits at most 100001 rows"))
    result=Dict{String,Any}[];seen=Set{String}()
    for raw in value
        raw isa AbstractDict||throw(ArgumentError("Each component property row must be a table"))
        row=Dict{String,Any}(String(k)=>v for (k,v) in raw)
        key=get(row,"key",nothing);key isa AbstractString||throw(ArgumentError("A component property row needs its physical key"))
        tokens=split(key,':');length(tokens)==2&&tokens[1] in COMPONENT_TABLE_PARTS||throw(ArgumentError("Invalid component property key $key"))
        index=tryparse(Int,tokens[2]);index!==nothing&&1<=index<=100001||throw(ArgumentError("Invalid physical index in $key"))
        key==component_table_key(tokens[1],index)||throw(ArgumentError("Non-canonical component key $key"))
        key in seen&&throw(ArgumentError("Duplicate component property key $key"));push!(seen,key)
        fields=component_table_iscap(tokens[1]) ? ("side","material") : tokens[1]=="rib_stiffener" ? (RIB_STIFFENER_FIELDS...,"material","enabled") : COMPONENT_SHELL_FIELDS
        length(row)>1&&all(k->k=="key"||k in fields,keys(row))||throw(ArgumentError("Unsupported or empty properties for $key"))
        for (field,v) in row
            field=="key"&&continue
            if field=="kind"
                v in ("monolithic","sandwich")||throw(ArgumentError("$key construction must be monolithic or sandwich"))
            elseif field=="enabled"
                v isa Bool||throw(ArgumentError("$key enabled must be true or false"))
            else
                v isa Real&&!(v isa Bool)&&isfinite(v)&&v>0||throw(ArgumentError("$key $field must be a finite positive value"))
                if endswith(field,"material")
                    isinteger(v)||throw(ArgumentError("$key $field must be a material ID"));row[field]=Int(v)
                else;row[field]=Float64(v);end
            end
        end
        push!(result,row)
    end
    sort!(result,by=r->r["key"])
end
function component_table_override(p,part,index)
    key=component_table_key(part,index)
    for row in get(p,"properties.components",Any[]);get(row,"key","")==key&&return row;end
    Dict{String,Any}()
end
component_table_override(p,pid::Integer)=isnothing(component_table_part(pid)) ? Dict{String,Any}() : component_table_override(p,component_table_part(pid),pid%COMPONENT_PID_STRIDE)
function component_table_pid(p,part,index,default)
    isempty(component_table_override(p,part,index)) ? default : component_table_family(part)*COMPONENT_PID_STRIDE+index
end
function validate_component_table_bounds(p,rib_count)
    for row in normalize_component_table_properties(get(p,"properties.components",Any[]))
        part,indextext=split(row["key"],':');index=parse(Int,indextext);limit=component_table_isrib(part) ? rib_count : rib_count-1
        index<=limit||throw(ArgumentError("$(row["key"]) exceeds the current physical rib layout; review component table overrides"))
    end
end
