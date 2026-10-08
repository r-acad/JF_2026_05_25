# Rib-selected zero-displacement SPCs in the global GRID displacement frame.
const SUPPORT_TARGETS=("front_spar","rear_spar","upper_skin","lower_skin",
    "front_upper","front_lower","rear_upper","rear_lower")

function normalize_support_sets(value)
    value isa AbstractVector||throw(ArgumentError("supports.items must be an array of rib support tables"))
    length(value)<=1000||throw(ArgumentError("supports.items permits at most 1000 support sets"))
    out=Dict{String,Any}[]
    for (index,raw) in enumerate(value)
        raw isa AbstractDict||throw(ArgumentError("supports.items row $index must be a table"))
        all(k->k isa AbstractString||k isa Symbol,keys(raw))||throw(ArgumentError("supports.items row $index has invalid field names"))
        row=Dict(String(k)=>v for (k,v) in raw)
        Set(keys(row))==Set(("rib","target","dofs"))||throw(ArgumentError("supports.items row $index needs exactly rib, target and dofs"))
        rib=row["rib"]
        rib isa Real&&!(rib isa Bool)&&isfinite(rib)&&isinteger(rib)&&1<=rib<=100001||
            throw(ArgumentError("supports.items row $index rib must be a positive integer"))
        target=row["target"]
        target isa AbstractString&&target in SUPPORT_TARGETS||throw(ArgumentError("supports.items row $index target must be one of $(join(SUPPORT_TARGETS,", "))"))
        dofs=row["dofs"]
        (dofs isa AbstractString || dofs isa Integer&&!(dofs isa Bool))||throw(ArgumentError("supports.items row $index dofs must contain global components 1 to 6"))
        components=strip(string(dofs))
        !isempty(components)&&all(c->c in '1':'6',components)||throw(ArgumentError("supports.items row $index dofs must be a nonempty selection of 1,2,3,4,5,6 without separators"))
        push!(out,Dict("rib"=>Int(rib),"target"=>String(target),"dofs"=>join(sort!(unique(collect(components))))))
    end
    return out
end

function validate_support_ribs(rows,rib_count)
    for (index,row) in enumerate(rows)
        row["rib"]<=rib_count||throw(ArgumentError("supports.items row $index selects rib $(row["rib"]), but the current model has $rib_count physical ribs; edit this support set after changing the rib layout"))
    end
    return nothing
end

"""Resolve selectors on the actual shared main-box perimeter at a physical rib."""
function support_assignments(g,node_lookup,p)
    mode=get(p,"supports.mode","root")
    mode in ("root","custom")||throw(ArgumentError("supports.mode must be root or custom"))
    rows=mode=="root" ? [Dict("rib"=>1,"target"=>target,"dofs"=>"123") for target in SUPPORT_TARGETS[1:4]] :
        normalize_support_sets(get(p,"supports.items",Any[]))
    validate_support_ribs(rows,length(g.ribs))
    components=Dict{Int,Set{Char}}();ribs=Dict{Int,Set{Int}}();targets=Dict{Int,Set{String}}()
    for row in rows
        rib=row["rib"];j=g.ribs[rib];target=row["target"]
        locations=if target=="front_spar"
            [(0,k) for k in 0:g.nh]
        elseif target=="rear_spar"
            [(ni(g),k) for k in 0:g.nh]
        elseif target in ("upper_skin","lower_skin")
            [(i,target=="upper_skin" ? g.nh : 0) for i in 0:ni(g)]
        else
            [(startswith(target,"front_") ? 0 : ni(g),endswith(target,"_upper") ? g.nh : 0)]
        end
        for (i,k) in locations
            collapsed=g.collapsed[i+1,j+1]
            column=collapsed<0 ? 0 : collapsed>0 ? ni(g) : i
            node=node_lookup[(column,j,k)]
            union!(get!(components,node,Set{Char}()),row["dofs"])
            push!(get!(ribs,node,Set{Int}()),rib)
            push!(get!(targets,node,Set{String}()),target)
        end
    end
    return [(node=node,components=join(sort!(collect(components[node]))),ribs=sort!(collect(ribs[node])),targets=sort!(collect(targets[node])))
        for node in sort!(collect(keys(components)))]
end

support_assignments(m::Model)=support_assignments(m.grid,Dict(key=>i for (i,key) in enumerate(m.node_keys)),m.params)

function support_description(m)
    mode=get(m.params,"supports.mode","root")
    if mode=="root"
        return "Global translations 123 fixed on the main-box root skin/spar perimeter. Leading-edge extension and rib-interior nodes remain free; shared spar/skin intersections are included."
    elseif isempty(m.spc)
        return "Custom supports: no constrained nodes. The structure is unsupported; a static solution may have rigid-body modes."
    end
    return "Custom rib support sets in global GRID axes: 1=x, 2=y, 3=z, 4=Rx, 5=Ry, 6=Rz. Overlapping sets are united per node. Leading-edge extension and RBE3 reference nodes are excluded."
end

function supports_payload(m)
    assignments=support_assignments(m)
    dofs=[row.components for row in assignments]
    common=isempty(dofs) ? "" : length(unique(dofs))==1 ? first(dofs) : "mixed"
    return Dict{String,Any}("count"=>length(m.spc),"components"=>common,"node_components"=>dofs,
        "mode"=>get(m.params,"supports.mode","root"),"items"=>normalize_support_sets(get(m.params,"supports.items",Any[])),
        "note"=>support_description(m),"nodes"=>blob_i32(m.spc;offset=-1),
        "assignments"=>[Dict("node"=>row.node-1,"grid"=>m.node_ids[row.node],"components"=>row.components,
            "ribs"=>row.ribs,"targets"=>row.targets) for row in assignments])
end
