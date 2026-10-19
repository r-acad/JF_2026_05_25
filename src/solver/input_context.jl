# Shared non-solving coordinate, constraint and load-selection context.
# Import workers and the numerical solver consume these identical definitions.

@inline function _node_dof_rotation(cord::AbstractDict, xg)
    u = Float64.(cord["U"])
    v = Float64.(cord["V"])
    w = Float64.(cord["W"])
    R = hcat(u, v, w)
    ctype = uppercase(string(get(cord, "TYPE", "RECTANGULAR")))
    ctype == "RECTANGULAR" && return R

    origin = Float64.(cord["Origin"])
    xloc = R' * (Float64.(xg) - origin)

    if ctype == "CYLINDRICAL"
        theta = atan(xloc[2], xloc[1])
        er = cos(theta) .* u .+ sin(theta) .* v
        et = -sin(theta) .* u .+ cos(theta) .* v
        return hcat(er, et, w)
    elseif ctype == "SPHERICAL"
        rxy = hypot(xloc[1], xloc[2])
        # Reference spherical components are radius, polar angle, azimuth.
        # Their unit vectors form a right-handed basis in that order.
        theta = atan(rxy, xloc[3])
        phi = atan(xloc[2], xloc[1])
        er_loc = [sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)]
        et_loc = [cos(theta) * cos(phi), cos(theta) * sin(phi), -sin(theta)]
        ep_loc = [-sin(phi), cos(phi), 0.0]
        return R * hcat(er_loc, et_loc, ep_loc)
    end

    return R
end

function get_coord_transform(model, cid, vec; position=nothing)
    if cid == 0; return vec; end
    haskey(model["CORDs"], string(cid)) ||
        throw(ArgumentError("Load references undefined coordinate system CID=$cid"))
    cord = model["CORDs"][string(cid)]
    # Body acceleration/rotation vectors use rectangular components of CID;
    # point forces and moments use its basis at the loaded point.
    R = isnothing(position) ? hcat(cord["U"], cord["V"], cord["W"]) :
        _node_dof_rotation(cord, position)
    return R * vec
end

"""Resolve the selected SPC/SPC1 sets with SPCADD selection precedence.

Keep one resolver for static/eigen partitions and boundary-condition exports.
SPCADD members must name SPC/SPC1 sets, not other SPCADD entries. Unsupported
nested references and missing sets must not silently lose constraints.
"""
function selected_spc_sets(model, spc_id)
    sets=Set{Int}()
    (spc_id===nothing||Int(spc_id)==0)&&return sets
    available=Set(Int(row["SID"]) for row in get(model,"SPC1s",[]))
    combinations=get(model,"SPCADDs",Dict());sid=Int(spc_id)
    children=get(combinations,sid,get(combinations,string(sid),nothing))
    if children===nothing
        sid in available||throw(ArgumentError("Selected SPC references undefined SPC/SPC1 set $sid"))
        push!(sets,sid)
    else
        isempty(children)&&throw(ArgumentError("SPCADD $sid contains no referenced SPC sets"))
        for child in children
            leaf=Int(child)
            (haskey(combinations,leaf)||haskey(combinations,string(leaf)))&&throw(ArgumentError("SPCADD $sid references SPCADD $leaf; nested or cyclic SPCADD entries are unsupported. Members must name SPC/SPC1 sets."))
            leaf in available||throw(ArgumentError("SPCADD $sid references undefined SPC/SPC1 set $leaf"))
            push!(sets,leaf)
        end
    end
    sets
end

"""Accumulate direct and nested LOAD coefficients, rejecting cyclic references."""
function _load_sid_scales(model, load_id, scale=1.0; include_zero::Bool=false)
    totals = Dict{Int,Float64}()
    load_id === nothing && return totals
    path = Int[]
    function visit(sid, factor)
        isfinite(factor) || throw(ArgumentError("Nonfinite LOAD scale for SID $sid"))
        !include_zero && iszero(factor) && return
        sid in path && throw(ArgumentError("Cyclic LOAD combination: " * join([path;sid], " -> ")))
        totals[sid] = get(totals,sid,0.0) + factor
        push!(path,sid)
        try
            for combo in get(model,"LOAD_COMBOS",[])
                Int(combo["SID"]) == sid || continue
                for child in combo["COMPS"]
                    visit(Int(child["LID"]),factor * Float64(combo["S"]) * Float64(child["S"]))
                end
            end
        finally
            pop!(path)
        end
    end
    visit(Int(load_id),Float64(scale))
    include_zero || filter!(pair -> !iszero(last(pair)),totals)
    return totals
end

function _assert_nonlinear_prescribed_supported(model, load_id, spc_id)
    sets=selected_spc_sets(model,spc_id)
    for entry in get(model,"SPC1s",[])
        Int(entry["SID"]) in sets || continue
        iszero(Float64(get(entry,"D",0.))) || throw(ArgumentError(
            "SOL106 prescribed motion from a nonzero SPC is unsupported; use SOL101 or SOL105 static preload. The imposed motion must not be silently ignored."))
    end
    scales=_load_sid_scales(model,load_id;include_zero=true)
    prescribed=Dict{Tuple{Int,Int},Float64}()
    for entry in get(model,"SPCDs",[])
        sid=Int(entry["SID"]);haskey(scales,sid)||continue
        key=(Int(entry["GID"]),Int(entry["C"]))
        prescribed[key]=get(prescribed,key,0.)+scales[sid]*Float64(entry["D"])
    end
    all(iszero,values(prescribed)) || throw(ArgumentError(
        "SOL106 prescribed motion from a selected SPCD load is unsupported; use SOL101 or SOL105 static preload. The imposed motion must not be silently ignored."))
    nothing
end
