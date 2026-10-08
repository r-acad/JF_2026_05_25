# Explicit OpenJFEM concentrated-force follower extension. Only FORCE cards
# marked FLLW=ROT participate; moments, pressures and body loads remain dead.
# Rotation coordinates are the existing nodal rotation-vector DOFs. This does
# not replace the structural element formulation with finite-strain kinematics.

function _follower_context(ndof, model, id_map, X, load_id, node_R, rbe3_map)
    activation = get(model, "PARAM_JFFOLLOW", 0)
    activation in (0, 1) || throw(ArgumentError("PARAM,JFFOLLOW must be 0 or 1"))
    (activation == 0 || load_id === nothing) && return nothing
    scales = _load_sid_scales(model, Int(load_id), 1.0)
    vectors = Dict{Int,Vector{Float64}}()
    for force in get(model, "FORCEs", [])
        uppercase(String(get(force,"FLLW",""))) == "ROT" || continue
        scale = get(scales, Int(force["SID"]), 0.0)
        iszero(scale) && continue
        gid = Int(force["GID"])
        haskey(id_map,gid) || throw(ArgumentError("Follower FORCE references missing GRID $gid"))
        i = id_map[gid]
        basic = get_coord_transform(model,Int(get(force,"CID",0)),force["Dir"];
            position=view(X,i,:)) * (Float64(force["Mag"])*scale)
        all(isfinite,basic) || throw(ArgumentError("Follower FORCE at GRID $gid is nonfinite"))
        get!(vectors,gid,zeros(3)) .+= node_R[i]'*basic
    end
    filter!(entry->!iszero(norm(last(entry))),vectors)
    isempty(vectors) && return nothing
    string(get(model,"SOL",101)) in ("101","106") ||
        throw(ArgumentError("PARAM,JFFOLLOW with active FORCE ROT is supported only for SOL101 and SOL106"))
    # Each row/column expansion represents the same flattened MPC transform T:
    # f_reduced=T' f, and K_load,reduced=T' (df/du) T.
    stations = [(gid=gid,index=id_map[gid],force=SVector{3,Float64}(vectors[gid]),
        frame=node_R[id_map[gid]],
        translations=[get(rbe3_map,6(id_map[gid]-1)+k,[(6(id_map[gid]-1)+k,1.0)]) for k in 1:3],
        rotations=[get(rbe3_map,6(id_map[gid]-1)+k+3,[(6(id_map[gid]-1)+k+3,1.0)]) for k in 1:3])
        for gid in sort!(collect(keys(vectors)))]
    return (ndof=ndof,stations=stations)
end

function _rotate_follower_vector(theta, force)
    angle2 = dot(theta,theta)
    # Analytic small-angle branch is also well defined for ForwardDiff duals.
    if angle2 < 1e-10
        a = one(angle2)-angle2/6+angle2^2/120-angle2^3/5040
        b = one(angle2)/2-angle2/24+angle2^2/720-angle2^3/40320
    else
        angle=sqrt(angle2)
        a=sin(angle)/angle
        b=(one(angle)-cos(angle))/angle2
    end
    turn=cross(theta,force)
    return force+a*turn+b*cross(theta,turn)
end

_follower_rotation(station,u) = SVector{3,Float64}(
    [sum(coefficient*u[dof] for (dof,coefficient) in map) for map in station.rotations])

"""Applied-force change from the undeformed load and its exact load Jacobian."""
function _follower_load_update(context,u,scale; linearized::Bool=false)
    delta=zeros(context.ndof)
    rows=Int[];cols=Int[];values=Float64[]
    for station in context.stations
        theta=_follower_rotation(station,u)
        force=scale*station.force
        if linearized
            current=force+cross(theta,force)
            derivative=[0.0 force[3] -force[2]; -force[3] 0.0 force[1]; force[2] -force[1] 0.0]
        else
            current=_rotate_follower_vector(theta,force)
            derivative=ForwardDiff.jacobian(t->_rotate_follower_vector(t,force),theta)
        end
        for a in 1:3
            for (row,row_weight) in station.translations[a]
                delta[row] += row_weight*(current[a]-force[a])
                for b in 1:3, (column,column_weight) in station.rotations[b]
                    value=row_weight*derivative[a,b]*column_weight
                    iszero(value) && continue
                    push!(rows,row);push!(cols,column);push!(values,value)
                end
            end
        end
    end
    return delta,sparse(rows,cols,values,context.ndof,context.ndof)
end

function _follower_result_metadata(context,u,scale; linearized::Bool=false)
    forces=Any[]
    for station in context.stations
        theta=_follower_rotation(station,u)
        force=scale*station.force
        current=linearized ? force+cross(theta,force) : _rotate_follower_vector(theta,force)
        push!(forces,Dict("grid_id"=>station.gid,"force_basic"=>collect(station.frame*current),
            "rotation_basic"=>collect(station.frame*theta)))
    end
    return Dict{String,Any}("enabled"=>true,"force_only"=>true,
        "mode"=>linearized ? "first_order" : "rotation_vector",
        "load_scale"=>scale,"tangent"=>"unsymmetric_load_jacobian",
        "forces"=>forces,"moments"=>"fixed_in_basic_coordinates",
        "note"=>linearized ? "SOL101 first-order follower-force linearization at zero rotation; no finite-rotation structural analysis." :
            "SOL106 FORCE directions rotate with nodal rotation vectors at every trial; structural geometric formulation is unchanged.")
end
