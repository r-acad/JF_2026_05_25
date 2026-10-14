# Shared component dimension controls are family-selection aliases for new
# analyses. Each effective variable still owns one physical property card.
function sensitivity_selection_metadata(m,variables)
    locals=filter(d->haskey(d,"component_key"),variables)
    replacements=Dict{String,Vector{String}}()
    aliases=Dict{String,Any}()
    function add(id,parts,field,label;index=nothing,note="")
        fields=field isa AbstractString ? (field,) : field
        ids=String[]
        for d in locals
            part,number=split(d["component_key"],':')
            part in parts&&(index===nothing||parse(Int,number)==index)||continue
            get(d,"field_key","") in fields&&push!(ids,d["id"])
        end
        isempty(ids)&&return
        replacements[id]=ids
        metadata=Dict{String,Any}("label"=>label,"component_parts"=>collect(parts),
            "field_key"=>(length(fields)==1 ? only(fields) : "shell.total_thickness"),"field_keys"=>collect(fields),
            "note"=>isempty(note) ? "Select every active local dimension in this family, including overridden values." : note)
        index===nothing||(metadata["index"]=index)
        aliases[id]=metadata
    end
    for (id,parts,label) in (
        ("properties.t_spar_web",("front_web","rear_web"),"All spar-web bays"),
        ("properties.t_rib_web",("rib_web",),"All rib webs"),
        ("leading_edge.t_skin",("leading_upper_skin","leading_lower_skin"),"All leading-edge skin bays"),
        ("leading_edge.t_rib",("leading_rib",),"All leading-edge ribs"))
        # A total-thickness control changes a sandwich core at fixed faces.
        # Treat the old control as a family selection, including local overrides.
        add(id,parts,("shell.thickness","shell.core_thickness"),label*": Shell thickness / sandwich core at fixed faces";
            note="Select every active bay/rib, including overrides: monolithic shell thickness or sandwich core thickness at fixed face thicknesses.")
    end
    add("properties.spar_cap_side",("front_upper_cap","front_lower_cap","rear_upper_cap","rear_lower_cap"),
        "section.square_side","All spar-cap bays: Square side")
    for field in RIB_STIFFENER_FIELDS
        add("properties.rib_stiffener_"*field,("rib_stiffener",),"section."*field,
            "All rib stiffeners: "*replace(field,'_'=>' '))
    end
    for (component,parts,label) in (
        ("spar_web",("front_web","rear_web"),"All spar-web bays"),
        ("rib_web",("rib_web",),"All rib webs"),
        ("leading_edge_skin",("leading_upper_skin","leading_lower_skin"),"All leading-edge skin bays"),
        ("leading_edge_rib",("leading_rib",),"All leading-edge ribs"))
        for field in ("face_thickness","core_thickness")
            add("materials.shells#$component#$field",parts,"shell."*field,
                label*": Sandwich "*replace(field,'_'=>' '))
        end
    end
    # Legacy sparse rows select only their own physical location. A legacy
    # sandwich total changes the core at fixed faces; make that mapping explicit.
    function legacy_thickness(id,part,index,label)
        core=any(d->d["component_key"]==component_table_key(part,index)&&get(d,"field_key","")=="shell.core_thickness",locals)
        field=core ? "shell.core_thickness" : "shell.thickness"
        note=core ? "Legacy total thickness selects this sandwich core thickness at fixed face thicknesses." :
            "Select the local shell thickness at this physical location, including an overridden value."
        add(id,(part,),field,label;index,note)
    end
    for row in get(m.params,"properties.ribs",Any[])
        rib=row["rib"]
        haskey(row,"thickness")&&legacy_thickness("properties.ribs#$rib#thickness","rib_web",rib,"Rib $rib: Local thickness")
        for field in RIB_STIFFENER_FIELDS
            haskey(row,field)&&add("properties.ribs#$rib#$field",("rib_stiffener",),"section."*field,
                "Rib $rib stiffener: "*replace(field,'_'=>' ');index=rib)
        end
    end
    for row in get(m.params,"properties.spar_bays",Any[])
        bay=row["bay"]
        for (field,part) in (("front_thickness","front_web"),("rear_thickness","rear_web"))
            haskey(row,field)&&legacy_thickness("properties.spar_bays#$bay#$field",part,bay,
                "$(uppercasefirst(replace(part,'_'=>' '))) bay $bay: Local thickness")
        end
    end
    (;replacements,aliases)
end

"""Expand family aliases to independent component dimensions, once per ID.

Material and panel selections are preserved. Imported catalogues without a
replacement map keep their original IDs. Applying this twice is idempotent.
"""
function sensitivity_expand_selection(catalog,variables)
    replacements=get(catalog,"selection_replacements",Dict())
    ids=String[];seen=Set{String}()
    for id in variables,target in get(replacements,String(id),[String(id)])
        target=String(target)
        target in seen&&continue
        push!(seen,target);push!(ids,target)
    end
    limit=Int(get(catalog,"max_variables",4096))
    length(ids)<=limit||throw(ArgumentError("Selected component families expand to $(length(ids)) independent property variables; select at most $limit local variables"))
    ids
end
