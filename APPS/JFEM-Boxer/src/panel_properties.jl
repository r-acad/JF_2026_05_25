# Sparse user overrides are keyed by physical panel identity, never volatile PID.
const PANEL_SKIN_FIELDS=("kind","thickness","material","face_material","core_material","face_thickness","core_thickness")
const PANEL_BAR_FIELDS=("flange_width","height","flange_thickness","web_thickness","material")
const PANEL_PROPERTY_CONTEXTS=Dict{UInt,Any}()
const PANEL_OVERRIDE_MIGRATIONS=Dict{UInt,Any}()
const PANEL_PROPERTY_LOCK=ReentrantLock()
panel_key(panel)="$(panel.upper ? "upper" : "lower"):bay$(panel.bay):stringer$(panel.stringer):segment$(panel.segment)"

struct PanelOverrideConflict <: Exception
    message::String
    details::Dict{String,Any}
    compatible_rows::Union{Nothing,Vector{Dict{String,Any}}}
    affected_rows::Vector{Dict{String,Any}}
end
Base.showerror(io::IO,error::PanelOverrideConflict)=print(io,error.message)

function panel_override_migration(p)
    lock(PANEL_PROPERTY_LOCK) do
        entry=get(PANEL_OVERRIDE_MIGRATIONS,objectid(p),nothing)
        entry!==nothing&&entry.owner.value===p ? entry.note : nothing
    end
end

function record_panel_override_migration!(p,note)
    lock(PANEL_PROPERTY_LOCK) do
        filter!(entry->entry.second.owner.value!==nothing,PANEL_OVERRIDE_MIGRATIONS)
        PANEL_OVERRIDE_MIGRATIONS[objectid(p)]=(owner=WeakRef(p),note=note)
    end
end

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
                elseif part=="stringer"&&field in ("flange_width","flange_thickness")&&v isa Real&&!(v isa Bool)&&iszero(v)
                    values[field]=0.0
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
        validate_stringer_dimensions(p,Tuple(bar[field] for field in RIB_STIFFENER_FIELDS),"$(row["key"]) stringer")
    end
    nothing
end

function legacy_panel_layout_token(g,layout=stiffened_panel_layout(g))
    # Retained only to authenticate and migrate saved coordinate-based tokens.
    chains=[(key=panel_key(q),path=[grid_point(g,q.column,j,q.upper ? g.nh : 0) for j in q.start_row:q.end_row]) for q in layout.panels]
    boundaries=[grid_point(g,i,j,k) for i in (0,ni(g)) for j in 0:nj(g) for k in (0,g.nh)]
    data=(chains=chains,boundaries=boundaries)
    bytes2hex(SHA.sha256(JSON.json(data)))
end

function panel_layout_token(g,layout)
    # A property belongs to an ordered physical rib bay/stringer, not a GRID
    # coordinate or a meshing row. Compress repeated states so adding mesh or
    # loft stations cannot change identity. Retain the runout side and each
    # physical rib boundary to reject genuine changes of panel membership.
    transitions=Vector{Int}[]
    for i in g.stringer_indices,bay in 1:length(g.ribs)-1
        states=Int[]
        for j in g.ribs[bay]:g.ribs[bay+1]
            side=g.collapsed[i+1,j+1]
            (isempty(states)||last(states)!=side)&&push!(states,side)
        end
        push!(transitions,states)
    end
    chains=[(key=panel_key(q),start_rib=q.start_row==g.ribs[q.bay],
        end_rib=q.end_row==g.ribs[q.bay+1]) for q in layout.panels]
    data=(version=2,rib_count=length(g.ribs),stringer_count=length(g.stringer_indices),
        chains=chains,runout_transitions=transitions)
    bytes2hex(SHA.sha256(JSON.json(data)))
end

function panel_coarse_grid(p)
    w=make_wing(p);xcs,_=chord_stations(w,p);etas,ribs,_=span_stations(w,p)
    stringer_grid(w,p,xcs,etas,ribs,p["mesh.elements_spar_height"])
end

function panel_layout_inputs_equal(p,baseline)
    relevant(key)=any(prefix->startswith(key,prefix),("planform.","airfoil.","loft.","box.","ribs.","mesh."))
    all(key->!relevant(key)||isequal(get(p,key,nothing),get(baseline,key,nothing)),union(keys(p),keys(baseline)))
end

function panel_rib_bay_map(old,new)
    length(old.ribs)==length(new.ribs)&&return Dict(i=>i for i in 1:length(old.ribs)-1)
    result=Dict{Int,Int}()
    for bay in 1:length(old.ribs)-1
        ends=old.etas[old.ribs[bay:bay+1].+1]
        matches=[j for j in 1:length(new.ribs)-1 if all(isapprox.(ends,new.etas[new.ribs[j:j+1].+1];atol=1e-10,rtol=0))]
        length(matches)==1&&(result[bay]=only(matches))
    end
    result
end

function panel_stringer_map(old,new)
    length(old.stringer_indices)==length(new.stringer_indices)&&return Dict(i=>i for i in eachindex(old.stringer_indices))
    # Changed line counts can renumber every stringer. Match only an unchanged
    # normalized root anchor, never the nearest line or its ordinal number.
    anchor(g,i)=(g.lower_xcs[i+1,1],g.upper_xcs[i+1,1])
    result=Dict{Int,Int}()
    for (index,i) in enumerate(old.stringer_indices)
        matches=[j for (j,k) in enumerate(new.stringer_indices) if all(isapprox.(anchor(old,i),anchor(new,k);atol=1e-10,rtol=0))]
        length(matches)==1&&(result[index]=only(matches))
    end
    result
end

function panel_span_identity(g,panel)
    firstrow,lastrow=g.ribs[panel.bay:panel.bay+1]
    lo,hi=g.etas[firstrow+1],g.etas[lastrow+1]
    ((g.etas[panel.start_row+1]-lo)/(hi-lo),(g.etas[panel.end_row+1]-lo)/(hi-lo))
end

function panel_skin_membership(g,layout,panel;stringers=nothing)
    # Physical skin ownership ends at active stringer lines/spars. Shell
    # subdivisions and flange-edge columns are deliberately absent.
    signatures=Tuple{Int,Int}[]
    mapped(i)=i in (0,-1) ? i : stringers===nothing ? i : get(stringers,i,-2)
    for row in panel.start_row:panel.end_row-1
        active=[i for (i,column) in enumerate(g.stringer_indices) if haskey(layout.bars,(column,row,panel.upper))]
        index=findfirst(==(panel.stringer),active)
        index===nothing&&return [(-2,-2)]
        pair=(mapped(index==1 ? 0 : panel.stringer),mapped(index==length(active) ? -1 : active[index+1]))
        (isempty(signatures)||last(signatures)!=pair)&&push!(signatures,pair)
    end
    signatures
end

"""Carry authenticated local properties onto demonstrably identical components.

The active baseline authenticates old tokens. Each skin footprint and stringer
segment is then assessed independently, so unrelated runouts do not invalidate
all properties. Ambiguous/disappeared parts are never reassigned or discarded:
the caller receives a reviewable conflict with compatible and affected rows.
Workspace imports authenticate their own saved geometry instead of this bridge.
"""
function migrate_legacy_panel_overrides!(p,previous)
    previous===nothing&&return p
    is_imported_model(previous)&&return p
    overrides=get(p,"properties.panels",Any[])
    isempty(overrides)&&return p
    layout=stiffened_panel_layout(previous.grid)
    token=panel_layout_token(previous.grid,layout)
    authenticated=all(row->get(row,"layout_token",nothing)==token,overrides)
    if !authenticated
        legacy=legacy_panel_layout_token(previous.grid,layout)
        all(row->get(row,"layout_token",nothing) in (token,legacy),overrides)||return p
    end
    if panel_layout_inputs_equal(p,previous.params)
        for row in overrides;row["layout_token"]=token;end
        return p
    end
    target=panel_coarse_grid(p);targetlayout=stiffened_panel_layout(target)
    targettoken=panel_layout_token(target,targetlayout)
    if targettoken==token
        for row in overrides;row["layout_token"]=token;end
        return p
    end
    oldpanels=Dict(panel_key(q)=>q for q in layout.panels)
    newpanels=Dict(panel_key(q)=>q for q in targetlayout.panels)
    bays=panel_rib_bay_map(previous.grid,target);strings=panel_stringer_map(previous.grid,target)
    compatible=Dict{String,Any}[];affected=Dict{String,Any}[]
    for row in overrides
        key=row["key"];old=get(oldpanels,key,nothing);new=nothing;reason=""
        if old===nothing
            reason="The saved panel is absent from the baseline model."
        elseif !haskey(bays,old.bay)
            reason="R$(old.bay)-R$(old.bay+1) no longer has the same two physical rib boundaries after the rib count changed."
        elseif !haskey(strings,old.stringer)
            reason="Stringer $(old.stringer) has no unique unchanged root anchor after the stringer count changed; its number must not be reused for another line."
        else
            targetkey="$(old.upper ? "upper" : "lower"):bay$(bays[old.bay]):stringer$(strings[old.stringer]):segment$(old.segment)"
            new=get(newpanels,targetkey,nothing)
            if new===nothing
                reason="The stringer no longer spans this rib bay: its runout or active segment changed."
            elseif !all(isapprox.(panel_span_identity(previous.grid,old),panel_span_identity(target,new);atol=1e-10,rtol=0))
                reason="The normal stringer segment no longer has the same extent between its two ribs."
            end
        end
        accepted=Dict{String,Any}("key"=>new===nothing ? key : panel_key(new),"layout_token"=>targettoken)
        parts=String[];reasons=String[]
        for part in ("skin","stringer")
            haskey(row,part)||continue
            problem=reason
            if isempty(problem)&&part=="skin"&&panel_skin_membership(previous.grid,layout,old;stringers=strings)!=panel_skin_membership(target,targetlayout,new)
                problem="The associated skin footprint has different bounding stringers/spars after the runout change."
            end
            if isempty(problem)
                accepted[part]=deepcopy(row[part])
            else
                push!(parts,part);push!(reasons,part*": "*problem)
            end
        end
        length(accepted)>2&&push!(compatible,accepted)
        isempty(parts)||push!(affected,Dict("key"=>key,"parts"=>parts,"reason"=>join(reasons," "),"row"=>deepcopy(row)))
    end
    sort!(compatible;by=row->row["key"])
    if !isempty(affected)
        details=Dict{String,Any}("can_reconcile"=>true,
            "old_rib_count"=>length(previous.grid.ribs),"new_rib_count"=>length(target.ribs),
            "old_stringer_count"=>length(previous.grid.stringer_indices),"new_stringer_count"=>length(target.stringer_indices),
            "old_panel_count"=>length(layout.panels),"new_panel_count"=>length(targetlayout.panels),
            "compatible_count"=>length(compatible),"affected_count"=>length(affected),
            "compatible_part_count"=>sum(count(part->haskey(row,part),("skin","stringer")) for row in compatible;init=0),
            "affected_part_count"=>sum(length(row["parts"]) for row in affected;init=0),
            "target_layout_token"=>targettoken)
        firstreason=first(affected)
        message="$(length(affected)) panel override row(s) need review; $(length(compatible)) compatible row(s) can be retained. "*
            "$(firstreason["key"]): $(firstreason["reason"]) Review the listed affected properties, or cancel to keep all saved values unchanged."
        throw(PanelOverrideConflict(message,details,compatible,affected))
    end
    p["properties.panels"]=compatible
    record_panel_override_migration!(p,Dict("status"=>"retained","row_count"=>length(compatible),
        "message"=>"Retained $(length(compatible)) individual panel property row(s) after the layout change: their physical stringer segments and affected skin footprints still match.",
        "source_layout_token"=>token,"target_layout_token"=>targettoken))
    return p
end

function register_panel_properties!(p,g;layout=stiffened_panel_layout(g))
    token=panel_layout_token(g,layout);keys=Dict(q.id=>panel_key(q) for q in layout.panels)
    reverse=Dict(value=>id for (id,value) in keys);rows=Dict{Int,Any}()
    overrides=get(p,"properties.panels",Any[])
    legacy=any(row->get(row,"layout_token",nothing)!=token,overrides) ? legacy_panel_layout_token(g,layout) : nothing
    for row in overrides
        get(row,"layout_token",nothing) in (token,legacy)||throw(PanelOverrideConflict(
            "Panel properties refer to an earlier layout, but its matching baseline is not available. Reopen the original saved Study before changing geometry so compatible properties can be identified. No overrides were removed.",
            Dict{String,Any}("can_reconcile"=>false,"affected_count"=>length(overrides),"compatible_count"=>0),nothing,
            [Dict{String,Any}("key"=>r["key"],"parts"=>[part for part in ("skin","stringer") if haskey(r,part)],
                "reason"=>"The original layout could not be authenticated.","row"=>deepcopy(r)) for r in overrides]))
        id=get(reverse,row["key"],nothing)
        id===nothing&&throw(ArgumentError("Panel $(row["key"]) no longer exists. Reset obsolete panel overrides before generating this layout."))
        rows[id]=row
    end
    # Do not partially migrate rows if another override fails authentication.
    for row in overrides;row["layout_token"]=token;end
    flange_skins=Dict{Int,Vector{Int}}()
    if shell_stringers(p)
        for panel in layout.panels
            candidates=Int[]
            for j in panel.start_row:panel.end_row-1,i in (panel.column-1,panel.column)
                id=layout.skins[panel.upper][i+1,j+1]
                push!(candidates,id==0 ? (panel.upper ? PID_SKIN_UPPER : PID_SKIN_LOWER) : panel_skin_pid(id,panel.upper))
            end
            flange_skins[panel.id]=sort!(unique(candidates))
        end
    end
    context=(;token,keys,rows,flange_skins)
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

"""A shell blade omits its flange; beam stringers retain the existing T rules."""
function validate_stringer_dimensions(p,dimensions,label="Stringer")
    if !shell_stringers(p)
        return validate_t_section_dimensions(dimensions,label)
    end
    b,h,tf,tw=dimensions
    b isa Real&&!(b isa Bool)&&isfinite(b)&&b>=0||throw(ArgumentError("$label flange width must be finite and nonnegative"))
    all(v->v isa Real&&!(v isa Bool)&&isfinite(v)&&v>0,(h,tw))||throw(ArgumentError("$label height and web thickness must be finite positive lengths in metres"))
    tf isa Real&&!(tf isa Bool)&&isfinite(tf)&&tf>=0||throw(ArgumentError("$label flange thickness must be finite and nonnegative"))
    b==0&&return nothing
    tf>0||throw(ArgumentError("$label flange thickness must be positive when its flange width is nonzero"))
    tf<h&&tw<b||throw(ArgumentError("$label requires flange thickness < overall height and web thickness < flange width, or flange width = 0 for a shell blade"))
    nothing
end
