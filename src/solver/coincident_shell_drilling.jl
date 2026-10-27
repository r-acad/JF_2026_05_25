# A coincident relative joint can distribute one inactive shell drilling
# coordinate over several GRIDs after MPC elimination. Per-GRID GPST alone
# cannot see this null direction. This extension removes only that coordinate
# gauge; it never adds a physical stay or constrains any translation.
function _coincident_shell_drilling_autospc!(fixed_dofs, spc_dofs, K, model, id_map)
    entries=NTuple{3,Any}[]
    joints=get(model,"RBE2s",Dict());grids=get(model,"GRIDs",Dict())
    (isempty(joints)||isempty(grids)||isempty(get(model,"CSHELLs",Dict())))&&return entries
    # Explicit drilling stiffness and direct mass operators require their
    # original coordinates, even when their coefficients happen to be small.
    get(model,"PARAM_K6ROT",0)>0&&return entries
    !isempty(get(model,"DMIGs",Dict()))&&return entries
    any(key->something(tryparse(Float64,get(ENV,key,"")),0.)>0,
        ("JFEM_PARAM_K6ROT","JFEM_PARAM_K6ROT_STATIC","JFEM_PARAM_K6ROT_EIG"))&&return entries
    adjacent=Dict{Int,Set{Int}}();external_joints=Any[]
    for joint in values(joints)
        components=Set(c for c in string(joint["CM"]) if isdigit(c))
        if !(all(c->c in components,"123")&&count(c->c in components,"456")>=2)
            push!(external_joints,joint);continue
        end
        master=Int(joint["GN"]);haskey(grids,string(master))||continue
        a=grids[string(master)]["X"]
        for raw in joint["GM"]
            slave=Int(raw);haskey(grids,string(slave))||continue
            b=grids[string(slave)]["X"]
            if norm(a-b)>64eps(Float64)*max(norm(a),norm(b),1.)
                push!(external_joints,joint);continue
            end
            push!(get!(adjacent,master,Set{Int}()),slave)
            push!(get!(adjacent,slave,Set{Int}()),master)
        end
    end
    isempty(adjacent)&&return entries
    candidates=Set(keys(adjacent));blocked=Set{Int}()
    # Only shell-supported joint tips qualify. In particular, do not discard
    # an independent rotor inertia, a beam rotation, a prescribed moment, or
    # a coordinate used by a different interpolation/load-transfer relation.
    grid_keys=Set(("G","GID","GA","GB","G1","G2","GN","GM","NODES","REFGRID","grids","GRID","GRIDS"))
    function mark(value,key="")
        if key in ("INDEP","DEP","UM")
            foreach(pair->mark(first(pair),"G"),value)
        elseif key in grid_keys
            if value isa Integer
                value in candidates&&push!(blocked,Int(value))
            elseif value isa AbstractVector||value isa Tuple
                foreach(v->mark(v,key),value)
            end
        elseif value isa AbstractDict||value isa NamedTuple
            for (k,v) in pairs(value);mark(v,string(k));end
        elseif value isa AbstractVector||value isa Tuple
            foreach(v->mark(v),value)
        end
    end
    for table in ("CBARs","CBEAMs","CRODs","CONRODs","CTUBEs","CSOLIDs",
                  "CONM1s","CONM2s","CMASS1s","CMASS2s","CELASs",
                  "CBUSHs","RBE1s","RBE3s","RSPLINEs","MPCs","MOMENTs")
        mark(get(model,table,Dict()))
    end
    mark(external_joints)
    normals=Dict(g=>Vector{Vector{Float64}}() for g in candidates)
    for shell in values(model["CSHELLs"])
        nodes=shell["NODES"];touch=filter(n->n in candidates,nodes);isempty(touch)&&continue
        points=[Float64.(grids[string(n)]["X"]) for n in nodes]
        raw=cross(points[2]-points[1],points[3]-points[1]);length_normal=norm(raw)
        length_normal>0||begin union!(blocked,touch);continue end
        normal=raw/length_normal
        scale=maximum(norm(point-points[1]) for point in points)
        if any(point->abs(dot(point-points[1],normal))>1e-11*scale,points)
            union!(blocked,touch);continue
        end
        for node in touch;push!(normals[node],normal);end
    end
    visited=Set{Int}()
    tolerance=min(autospc_gpst_relative_threshold(model),512eps(Float64))
    for seed in sort!(collect(candidates))
        seed in visited&&continue
        group=Int[];pending=[seed]
        while !isempty(pending)
            node=pop!(pending);node in visited&&continue
            push!(visited,node);push!(group,node);append!(pending,adjacent[node])
        end
        any(n->n in blocked||isempty(normals[n]),group)&&continue
        sort!(group)
        frames=Dict{Int,Matrix{Float64}}()
        cords=get(model,"CORDs",Dict())
        for node in group
            grid=grids[string(node)];cid=get(grid,"CD",0)
            if cid==0
                frames[node]=Matrix{Float64}(I,3,3)
            elseif haskey(cords,string(cid))
                frames[node]=_node_dof_rotation(cords[string(cid)],grid["X"])
            end
        end
        length(frames)==length(group)||continue
        group_set=Set(group)
        group_joints=[joint for joint in values(joints) if joint["GN"] in group_set&&all(n->n in group_set,joint["GM"])]
        # Repeat after each gauge choice so a degenerate eigenbasis cannot
        # select the same pivot twice or remove too many coordinates.
        for _ in 1:3length(group)
            dofs=[6(id_map[n]-1)+c for n in group for c in 4:6 if !(6(id_map[n]-1)+c in fixed_dofs)]
            isempty(dofs)&&break
            block=Matrix(K[dofs,dofs]);decomposition=eigen(Symmetric((block+block')/2))
            reference=maximum(abs,decomposition.values);reference>0||break
            columns=K[:,dofs];column_reference=norm(columns)
            column_reference>0||break
            removed=false
            for j in eachindex(decomposition.values)
                ratio=abs(decomposition.values[j])/reference;ratio<=tolerance||continue
                v=decomposition.vectors[:,j]
                residual=norm(columns*v)/column_reference
                rotation=Dict(n=>zeros(3) for n in group)
                for (i,dof) in enumerate(dofs)
                    node=group[findfirst(n->id_map[n]==(dof-1)÷6+1,group)]
                    rotation[node][mod1(dof,6)-3]=v[i]
                end
                # The null vector is in independent coordinates. Restore the
                # eliminated RBE2 rotations before checking physical shell
                # normals, including joints with different GRID CD frames.
                for _ in eachindex(group),joint in group_joints
                    master=Int(joint["GN"])
                    for slave in joint["GM"]
                        mapped=frames[slave]'*frames[master]*rotation[master]
                        for c in string(joint["CM"])
                            c in '4':'6'||continue
                            rotation[slave][Int(c-'3')]=mapped[Int(c-'3')]
                        end
                    end
                end
                pure_drilling=true;normal_mismatch=0.
                for node in group
                    r=rotation[node];norm(r)<1e-10&&continue
                    r=frames[node]*r
                    mismatch=maximum(norm(cross(r,normal))/norm(r) for normal in normals[node])
                    normal_mismatch=max(normal_mismatch,mismatch)
                    if mismatch>1e-8
                        pure_drilling=false;break
                    end
                end
                pure_drilling||continue
                # Finite-precision GRID coordinates can tilt nominally planar
                # fitting triangles by ~1e-9 radians. Permit only the operator
                # cancellation error supported by that measured misalignment;
                # exactly planar geometry retains the machine-precision bound.
                # Rotational self-energy must still vanish at machine precision,
                # so a finite soft spring is never removed by this allowance.
                residual<=max(tolerance,normal_mismatch)||continue
                pivot=dofs[argmax(abs.(v))];push!(fixed_dofs,pivot)
                spc_dofs===nothing||push!(spc_dofs,pivot)
                node=only(filter(n->id_map[n]==(pivot-1)÷6+1,group))
                push!(entries,(node,mod1(pivot,6),ratio));removed=true;break
            end
            removed||break
        end
    end
    entries
end
