# Sparse user overrides are keyed by physical panel identity, never volatile PID.
const PANEL_SKIN_FIELDS=("kind","thickness","material","face_material","core_material","face_thickness","core_thickness")
const PANEL_BAR_FIELDS=("flange_width","height","flange_thickness","web_thickness","material")
const PANEL_PROPERTY_CONTEXTS=Dict{UInt,Any}()
const PANEL_PROPERTY_LOCK=ReentrantLock()
panel_key(panel)="$(panel.upper ? "upper" : "lower"):bay$(panel.bay):stringer$(panel.stringer):segment$(panel.segment)"

function normalize_panel_properties(value)
    out=Dict{String,Any}[];seen=Set{String}()
    for raw in material_rows(value,"properties.panels",100000)
        all(k->k in ("key","layout_token","skin","stringer"),keys(raw))||throw(ArgumentError("Panel override has an unsupported field"))
        key=get(raw,"key",nothing)
        key isa AbstractString&&occursin(r"^(upper|lower):bay[1-9][0-9]*:stringer[1-9][0-9]*:segment[1-9][0-9]*$",key)||throw(ArgumentError("Panel override needs a physical panel key from the current FEM"))
        key in seen&&throw(ArgumentError("Duplicate panel override $key"));push!(seen,key)
        row=Dict{String,Any}("key"=>String(key))
        for (part,fields) in (("skin",PANEL_SKIN_FIELDS),("stringer",PANEL_BAR_FIELDS))
            data=get(raw,part,Dict());data===nothing&&(data=Dict())
            data isa AbstractDict||throw(ArgumentError("$key $part must be a property table"))
            all(k->String(k) in fields,keys(data))||throw(ArgumentError("$key $part contains an unsupported field"))
            values=Dict{String,Any}()
            for (name,v) in data
                field=String(name)
                (v===nothing||(v isa AbstractString&&isempty(strip(v))))&&continue
                if field=="kind"
                    v in ("monolithic","sandwich")||throw(ArgumentError("$key skin kind must be monolithic or sandwich"));values[field]=String(v)
                elseif endswith(field,"material")
                    values[field]=material_integer(v,"$key $part $field")
                else
                    values[field]=material_positive(v,"$key $part $field (metres)")
                end
            end
            isempty(values)||(row[part]=values)
        end
        length(row)==1&&continue
        token=get(raw,"layout_token",nothing)
        token isa AbstractString&&occursin(r"^[a-f0-9]{64}$",token)||throw(ArgumentError("$key needs the current panel layout token; regenerate the FEM before editing panel properties"))
        row["layout_token"]=String(token);push!(out,row)
    end
    sort!(out;by=r->r["key"])
end

function inherited_panel_properties(p,upper)
    skin=Dict{String,Any}(k=>v for (k,v) in material_assignment(p,upper ? "upper_skin" : "lower_skin") if k!="component")
    skin["thickness"]=Float64(p[upper ? "properties.t_skin_upper" : "properties.t_skin_lower"])
    bar=Dict{String,Any}(field=>Float64(p["properties.stringer_"*field]) for field in PANEL_BAR_FIELDS if field!="material")
    bar["material"]=material_assignment(p,"stringer";shell=false)["material"]
    (;skin,stringer=bar)
end

function validate_panel_properties(p)
    ids=Set(row["id"] for row in material_definitions(p))
    for row in normalize_panel_properties(get(p,"properties.panels",Any[]))
        inherited=inherited_panel_properties(p,startswith(row["key"],"upper:"))
        skin=merge(inherited.skin,get(row,"skin",Dict()));bar=merge(inherited.stringer,get(row,"stringer",Dict()))
        for field in ("material","face_material","core_material")
            skin[field] in ids||throw(ArgumentError("$(row["key"]) skin $field selects missing material $(skin[field])"))
        end
        bar["material"] in ids||throw(ArgumentError("$(row["key"]) stringer selects missing material $(bar["material"])"))
        validate_t_section_dimensions(Tuple(bar[field] for field in RIB_STIFFENER_FIELDS),"$(row["key"]) stringer")
    end
    nothing
end

function panel_layout_token(g,layout)
    # Physical anchor paths protect against renumbering or changed runout ends.
    # Chord-only shell refinement is intentionally absent from this identity.
    chains=[(key=panel_key(q),path=[grid_point(g,q.column,j,q.upper ? g.nh : 0) for j in q.start_row:q.end_row]) for q in layout.panels]
    boundaries=[grid_point(g,i,j,k) for i in (0,ni(g)) for j in 0:nj(g) for k in (0,g.nh)]
    data=(chains=chains,boundaries=boundaries)
    bytes2hex(SHA.sha256(JSON.json(data)))
end

function register_panel_properties!(p,g;layout=stiffened_panel_layout(g))
    token=panel_layout_token(g,layout);keys=Dict(q.id=>panel_key(q) for q in layout.panels)
    reverse=Dict(value=>id for (id,value) in keys);rows=Dict{Int,Any}()
    for row in get(p,"properties.panels",Any[])
        get(row,"layout_token",nothing)==token||throw(ArgumentError("Panel overrides belong to a different geometry or rib/stringer/runout layout. Reset panel overrides, create the FEM, then define them on the new layout."))
        id=get(reverse,row["key"],nothing)
        id===nothing&&throw(ArgumentError("Panel $(row["key"]) no longer exists. Reset obsolete panel overrides before generating this layout."))
        rows[id]=row
    end
    context=(;token,keys,rows)
    lock(PANEL_PROPERTY_LOCK) do
        filter!(entry->entry.second.owner.value!==nothing,PANEL_PROPERTY_CONTEXTS)
        PANEL_PROPERTY_CONTEXTS[objectid(p)]=(owner=WeakRef(p),context=context)
    end
    context
end

function panel_property_context(p)
    context=lock(PANEL_PROPERTY_LOCK) do
        entry=get(PANEL_PROPERTY_CONTEXTS,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p ? entry.context : nothing
    end
    context!==nothing&&return context
    # A deserialized model usually registers its existing grid first. Bare
    # parameter/property callers can reconstruct just the grid deterministically.
    w=make_wing(p);xcs,_=chord_stations(w,p);etas,ribs,_=span_stations(w,p)
    g=refine_stringer_bays(stringer_grid(w,p,xcs,etas,ribs,p["mesh.elements_spar_height"]),get(p,"mesh.elements_between_stringers",1))
    register_panel_properties!(p,g)
end

function panel_property_override(p,pid,part)
    id=stiffened_panel_id(pid)
    (id===nothing||isempty(get(p,"properties.panels",Any[])))&&return Dict{String,Any}()
    row=get(panel_property_context(p).rows,id,Dict())
    get(row,part,Dict{String,Any}())
end

function panel_stringer_dimensions(p,pid)
    row=panel_property_override(p,pid,"stringer")
    Tuple(Float64(get(row,field,p["properties.stringer_"*field])) for field in RIB_STIFFENER_FIELDS)
end
