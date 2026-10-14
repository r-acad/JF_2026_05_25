# Explicit compact-output markers distinguish omitted vectors from missing data.
function compact_buckling_output(data)
    options=get(data,"output_options",nothing)
    get(data,"mode_shape_status","")=="omitted_compact" ||
        options isa AbstractDict && get(options,"compact",false)===true
end

"""Keep true per-element energy on EIDs, including its state/normalization note."""
function element_energy_contours(m,energy)
    energy isa AbstractDict||return Any[]
    rows=get(energy,"records",Any[]);rows isa AbstractVector||return Any[]
    supported=Set(eid for group in m.groups for eid in group.eids)
    result=Any[]
    for (key,label,unit) in (("deformation_energy","Element deformation energy","J"),("energy_density","Element energy density","J/m³"))
        ids=Int[];values=Float64[]
        for row in rows
            row isa AbstractDict||continue
            id=get(row,"eid",nothing);value=get(row,key,nothing)
            id isa Integer&&id in supported&&value isa Real&&isfinite(value)&&isfinite(Float32(value))||continue
            push!(ids,Int(id));push!(values,Float64(value))
        end
        isempty(values)&&continue
        normalization=string(get(energy,"normalization","See native result normalization"))
        note=normalization*". True element energy; element values are not averaged between adjacent elements. "*
            string(get(energy,"note","Unsupported elements are omitted, never filled with zero."))
        display_unit=is_imported_model(m) ? get(get(energy,"units",Dict()),key,key=="deformation_energy" ? "force · length" : "force / length²") : unit
        push!(result,Dict{String,Any}("name"=>label,"unit"=>display_unit,"location"=>"element","domain"=>"all",
            "ids"=>blob_i32(ids),"values"=>blob_f32(values),"min"=>minimum(values),"max"=>maximum(values),"note"=>note))
    end
    result
end

"""Carry a preload's optional energy through the existing static-result bridge."""
function select_buckling_preload!(selected,state)
    for key in ("static_displacements","static_result");haskey(state,key)&&(selected[key]=state[key]);end
    if haskey(state,"element_energy") && get(selected,"static_result",nothing) isa AbstractDict
        selected["static_result"]=merge(selected["static_result"],Dict("element_energy"=>state["element_energy"]))
    end
    selected
end
