# Separate aerodynamic load paths for modeled movable surfaces. The camber
# pressure solution is unchanged; these functions transfer its complete panel
# resultants conservatively to the appropriate physical structural component.

function add_unboxed_control_references!(reg,g,p,metadata,eid)
    definitions=Dict(s["name"]=>s for s in get(p,"movable_surfaces.items",Any[]))
    references=get!(metadata,"load_references",Any[])
    intervals=max(1,round(Int,reference_length(g.wing)/p["box.rib_pitch"]))*p["mesh.elements_between_ribs"]
    for surface in get(metadata,"surfaces",Any[])
        start=surface["structural_eta_end"];stop=surface["aerodynamic_eta_end"]
        start>=stop-1e-10 && continue
        definition=definitions[surface["name"]];rotation=movable_rotation(g.wing,definition,surface["mesh_deflected"])
        terminal=last(surface["rib_sections"])["perimeter_nodes"]
        edge=definition["edge"]=="trailing" ? 1. : 0.
        stations=movable_distinct_stations(vcat([j/intervals for j in 1:intervals if start+1e-10<j/intervals<stop-1e-10],stop))
        for eta in stations
            xc=rotation.front_spar(eta)+.25*(edge-rotation.front_spar(eta))
            point=rotation.rotate(section_point(g.wing,eta,xc,(zup(g.wing,eta,xc)+zlo(g.wing,eta,xc))/2))
            ref=add_free_node!(reg,point);delete!(reg.index,reg.keys[ref])
            reg.keys[ref]=(-4,ref,0);reg.index[reg.keys[ref]]=ref
            metadata["node_etas"][ref]=eta
            push!(references,Dict("surface"=>surface["name"],"eid"=>eid,"ref"=>ref,
                "nodes"=>copy(terminal),"eta"=>eta,"position"=>collect(point),"massless"=>true))
            eid+=1
        end
    end
    return eid
end

function aerodynamic_references(m)
    main=[(ref=sp.ref,eid=sp.eid,eta=sp.eta,surface="",target_kind="external_rbe3",massless=sp.station<0) for sp in m.rbe3]
    control=[(ref=Int(sp["ref"]),eid=Int(sp["eid"]),eta=Float64(sp["eta"]),surface=String(sp["surface"]),
        target_kind="control_rbe3",massless=get(sp,"massless",false)) for sp in get(m.movable_structure,"load_references",Any[])]
    return vcat(main,control)
end

"""Recover chord fraction in the original lifting-surface section, including twist."""
function aerodynamic_chord_fraction(w,point,eta)
    origin=reference_point(w,eta);c=chord(w,eta);s,co=sincos(twist(w,eta))
    x=(point[1]-origin[1])/c-(w.twist_axis-w.sweep_ref)
    z=(point[3]-origin[3])/c
    return w.twist_axis+co*x-s*z
end

function aerodynamic_control_families(p,metadata)
    references=get(metadata,"load_references",Any[])
    enabled=Set(String(s["name"]) for s in get(metadata,"surfaces",Any[]))
    families=NamedTuple[]
    for definition in get(p,"movable_surfaces.items",Any[])
        definition["name"] in enabled || continue
        refs=sort!([r for r in references if r["surface"]==definition["name"]];by=r->r["eta"])
        isempty(refs) && continue
        push!(families,(definition=definition,refs=refs,etas=Float64[r["eta"] for r in refs]))
    end
    return sort!(families;by=f->(f.definition["eta_start"],f.definition["name"]))
end

function aerodynamic_control_owner(families,eta,xc)
    for family in families
        s=family.definition;a=s["eta_start"];b=s["eta_end"]
        a-1e-10<=eta<=b+1e-10 || continue
        front=movable_chord_coordinate(s,"front_spar",clamp(eta,a,b))
        (s["edge"]=="trailing" ? front-1e-10<=xc<=1+1e-10 : -1e-10<=xc<=front+1e-10) || continue
        return family
    end
    return nothing
end

function aerodynamic_routing(m)
    refs=aerodynamic_references(m)
    return (wing=m.wing,refs=refs,by_node=Dict(r.ref=>i for (i,r) in enumerate(refs)),
        main_etas=[sp.eta for sp in m.rbe3],families=aerodynamic_control_families(m.params,m.movable_structure))
end

"""Unique component ownership followed by span interpolation within that component."""
function aerodynamic_target_weights(routing,point;eta=(point[2]-routing.wing.root_ref_y)/routing.wing.semispan,xc=nothing)
    chord_fraction=xc===nothing ? aerodynamic_chord_fraction(routing.wing,point,eta) : xc
    family=aerodynamic_control_owner(routing.families,eta,chord_fraction)
    family===nothing && return moment_span_weights(routing.main_etas,eta)
    return Tuple((routing.by_node[Int(family.refs[j]["ref"])],weight) for (j,weight) in moment_span_weights(family.etas,eta))
end

"""Explicit viewer attachment avoids mixing coincident main/control span stations."""
function aerodynamic_point_bindings(m,points)
    routing=aerodynamic_routing(m)
    return [[Dict("node_index"=>routing.refs[j].ref-1,"gid"=>m.node_ids[routing.refs[j].ref],"weight"=>weight)
        for (j,weight) in aerodynamic_target_weights(routing,point) if weight>0] for point in points]
end

function bind_control_aero_points!(mapping,weights,xyz,w,p,metadata,aero_etas,nloop)
    families=aerodynamic_control_families(p,metadata)
    isempty(families) && return nothing
    stride=length(mapping)÷(length(xyz)÷3)
    for (row,eta) in enumerate(aero_etas),chord_index in 1:nloop
        point=(row-1)*nloop+chord_index;position=Tuple(xyz[3point-2:3point])
        family=aerodynamic_control_owner(families,eta,aerodynamic_chord_fraction(w,position,eta))
        family===nothing && continue
        offset=stride*(point-1);brackets=moment_span_weights(family.etas,eta)
        for k in 1:stride;mapping[offset+k]=Int(first(family.refs)["ref"]);weights[offset+k]=0.;end
        for (k,(j,weight)) in enumerate(brackets);mapping[offset+k]=Int(family.refs[j]["ref"]);weights[offset+k]=weight;end
    end
    return nothing
end

"""Identify loft points whose rotations use individual RBE3 force-transfer arms."""
function aerodynamic_reference_point_mask(m)
    isempty(m.aero_xyz) && return Int[]
    references=Set(r.ref for r in aerodynamic_references(m));stride=length(m.aero_map)÷(length(m.aero_xyz)÷3)
    return Int[all(m.aero_weights[stride*(a-1)+k]==0 || m.aero_map[stride*(a-1)+k] in references for k in 1:stride)
        for a in 1:length(m.aero_xyz)÷3]
end

"""Keep already assigned aerodynamic station GRIDs; never remap a control to the main box."""
function assigned_aerodynamic_wrenches(m,stations,refs=aerodynamic_references(m))
    positions=[Tuple(m.xyz[3r.ref-2:3r.ref]) for r in refs];by_gid=Dict(m.node_ids[r.ref]=>i for (i,r) in enumerate(refs))
    force=fill(AERO_ZERO,length(refs));pure=copy(force);lever=copy(force)
    for station in stations
        all(isfinite,station.force)&&all(isfinite,station.moment)&&all(isfinite,station.position)||throw(ArgumentError("Aerodynamic load contains nonfinite components"))
        haskey(by_gid,station.gid)||throw(ArgumentError("Aerodynamic load GRID $(station.gid) has no generated load reference"))
        i=by_gid[station.gid];force[i]=force[i].+station.force;pure[i]=pure[i].+station.moment
        lever[i]=lever[i].+cross3(station.position.-positions[i],station.force)
    end
    return (force=force,pure_moment=pure,force_arm_moment=lever,moment=[pure[i].+lever[i] for i in eachindex(refs)])
end
