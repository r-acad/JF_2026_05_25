# Explicit FORCE ROT loading and native current-area pressure loading.
# Normal shell/PLOAD pressure follows only SOL106 with LGDISP enabled;
# fixed-direction pressure, moments and body loads retain their contracts.
# Rotation coordinates are the existing nodal rotation-vector DOFs. This does
# not replace the structural element formulation with finite-strain kinematics.

function _follower_context(ndof, model, id_map, X, load_id, node_R, rbe3_map)
    activation = get(model, "PARAM_JFFOLLOW", 0)
    activation in (0, 1) || throw(ArgumentError("PARAM,JFFOLLOW must be 0 or 1"))
    load_id === nothing && return nothing
    scales = _load_sid_scales(model, Int(load_id), 1.0)
    _check_selected_pload4_semantics(model, scales)
    pressures = _follower_pressure_stations(model,id_map,X,node_R,rbe3_map,scales)
    vectors = Dict{Int,Vector{Float64}}()
    for force in get(model, "FORCEs", [])
        activation == 1 || continue
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
    isempty(vectors) && isempty(pressures) && return nothing
    string(get(model,"SOL",101)) in ("101","106") ||
        throw(ArgumentError("PARAM,JFFOLLOW with active FORCE ROT is supported only for SOL101 and SOL106"))
    # Each row/column expansion represents the same flattened MPC transform T:
    # f_reduced=T' f, and K_load,reduced=T' (df/du) T.
    stations = [(gid=gid,index=id_map[gid],force=SVector{3,Float64}(vectors[gid]),
        frame=node_R[id_map[gid]],
        translations=[get(rbe3_map,6(id_map[gid]-1)+k,[(6(id_map[gid]-1)+k,1.0)]) for k in 1:3],
        rotations=[get(rbe3_map,6(id_map[gid]-1)+k+3,[(6(id_map[gid]-1)+k+3,1.0)]) for k in 1:3])
        for gid in sort!(collect(keys(vectors)))]
    return (ndof=ndof,stations=stations,pressures=pressures)
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
    for station in context.pressures
        q=_follower_pressure_dofs(station,u)
        force=scale*_follower_pressure_force(station,q)
        derivative=scale*ForwardDiff.jacobian(v->_follower_pressure_force(station,v),q)
        for a in eachindex(q), (row,row_weight) in station.maps[a]
            delta[row]+=row_weight*(force[a]-scale*station.reference[a])
            for b in eachindex(q), (column,column_weight) in station.maps[b]
                value=row_weight*derivative[a,b]*column_weight
                iszero(value) && continue
                push!(rows,row);push!(cols,column);push!(values,value)
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
            "reference_force_basic"=>collect(station.frame*force),
            "rotation_basic"=>collect(station.frame*theta)))
    end
    pressures=Any[]
    for station in context.pressures
        q=_follower_pressure_dofs(station,u)
        force=scale*_follower_pressure_force(station,q)
        push!(pressures,Dict("kind"=>station.kind,"element_id"=>station.element_id,
            "grid_ids"=>station.nodes,"pressure"=>scale*station.pressure,
            "force_basic"=>[collect(station.frames[i]*view(force,3i-2:3i)) for i in eachindex(station.nodes)]))
    end
    return Dict{String,Any}("enabled"=>true,"force_only"=>isempty(pressures),
        "mode"=>linearized ? "first_order" : isempty(pressures) ? "rotation_vector" : "current_area_pressure",
        "load_scale"=>scale,"tangent"=>"unsymmetric_load_jacobian",
        "forces"=>forces,"pressures"=>pressures,"moments"=>"fixed_in_basic_coordinates",
        "note"=>linearized ? "SOL101 first-order follower-force linearization at zero rotation; no finite-rotation structural analysis." :
            "SOL106 FORCE ROT directions and normal pressure surface geometry update at every trial; the structural formulation is unchanged.")
end

"""Consistent nodal force from constant pressure on the current oriented face."""
function _current_area_pressure_force(Y,pressure)
    n=size(Y,1)
    n in (3,4) || throw(ArgumentError("Follower pressure supports three- and four-node faces"))
    result=zeros(promote_type(eltype(Y),typeof(pressure)),n,3)
    if n==3
        normal=cross(view(Y,2,:)-view(Y,1,:),view(Y,3,:)-view(Y,1,:))
        for i in 1:3, a in 1:3
            result[i,a]=pressure*normal[a]/6
        end
    else
        gauss=inv(sqrt(3.0))
        for r in (-gauss,gauss),s in (-gauss,gauss)
            N=((1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s))
            dr=(-(1-s),1-s,1+s,-(1+s))
            ds=(-(1-r),-(1+r),1+r,1-r)
            tangent_r=[sum(dr[i]*Y[i,a] for i in 1:4)/4 for a in 1:3]
            tangent_s=[sum(ds[i]*Y[i,a] for i in 1:4)/4 for a in 1:3]
            normal=cross(tangent_r,tangent_s)
            for i in 1:4,a in 1:3
                result[i,a]+=pressure*N[i]*normal[a]/4
            end
        end
    end
    return result
end

function _follower_pressure_stations(model,id_map,X,node_R,rbe3_map,scales)
    # Native small-strain geometric nonlinear pressure follows the current
    # face, independently of the explicit concentrated-FORCE extension.
    string(get(model,"SOL",101))=="106" && get(model,"PARAM_LGDISP",-1)==1 || return Any[]
    faces=Any[]
    function add_face(card,nodes,eid)
        factor=get(scales,Int(card["SID"]),0.0)
        iszero(factor) && return
        pressure=Float64(card["P"])*factor
        iszero(pressure) && return
        isfinite(pressure) || throw(ArgumentError("Nonfinite follower pressure"))
        n=length(nodes)
        n in (3,4) || throw(ArgumentError("SOL106 normal pressure supports three- and four-node shell faces"))
        all(g->haskey(id_map,g),nodes) || throw(ArgumentError("Follower pressure references a missing GRID"))
        indices=[id_map[g] for g in nodes]
        coordinates=Matrix{Float64}(X[indices,:])
        frames=[node_R[i] for i in indices]
        maps=[get(rbe3_map,6(i-1)+a,[(6(i-1)+a,1.0)]) for i in indices for a in 1:3]
        # The ordinary load resolver supplies equal-share reference forces.
        # Subtract exactly that contribution before adding consistent pressure
        # work, including its nonuniform nodal shares on a distorted Q4.
        normal=n==3 ? cross(coordinates[2,:]-coordinates[1,:],coordinates[3,:]-coordinates[1,:]) :
            cross(coordinates[3,:]-coordinates[1,:],coordinates[4,:]-coordinates[2,:])
        reference=zeros(3n)
        for i in 1:n
            reference[3i-2:3i]=transpose(frames[i])*(pressure/(2n)*normal)
        end
        push!(faces,(kind=String(get(card,"TYPE","PLOAD4")),element_id=eid,nodes=collect(nodes),
            X=coordinates,pressure=pressure,frames=frames,maps=maps,reference=reference))
    end
    for card in get(model,"PLOAD4s",[])
        iszero(get(scales,Int(card["SID"]),0.0)) && continue
        # A prescribed nonzero direction retains its fixed load contract.
        haskey(card,"N") && norm(card["N"])>1e-30 && continue
        eid=Int(card["EID"])
        element=get(get(model,"CSHELLs",Dict()),string(eid),nothing)
        element===nothing && continue # Solid-face pressure is a separate route.
        add_face(card,element["NODES"],eid)
    end
    for card in get(model,"PLOADs",[])
        add_face(card,card["NODES"],nothing)
    end
    return faces
end

function _follower_pressure_force(station,q)
    n=length(station.nodes)
    Y=Matrix{eltype(q)}(station.X)
    for i in 1:n
        Y[i,:]+=station.frames[i]*view(q,3i-2:3i)
    end
    basic=_current_area_pressure_force(Y,station.pressure)
    force=similar(q)
    for i in 1:n
        force[3i-2:3i]=transpose(station.frames[i])*view(basic,i,:)
    end
    return force
end

_follower_pressure_dofs(station,u) =
    [sum(coefficient*u[dof] for (dof,coefficient) in map) for map in station.maps]
