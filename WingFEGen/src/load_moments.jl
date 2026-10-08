# Conservative force/couple transfer to the two load-bearing RBE3 families.
const APPLIED_LOAD_VERSION = "rib_aero_bay_mass_wrenches_v1"
const APPLIED_MOMENT_ROUTING_NOTE = "All aerodynamic forces and moments act at rib-plane external RBE3 centers. All fuel and structural inertia forces and moments act at fuel/mass bay RBE3 centers. Bracketing span weights preserve force and global moment; moved forces add (source position - target position) cross force. Massless bay references add no fuel capacity or CONM2 mass. Inertia loads and all applied couples remain fixed in global axes."

function moment_span_weights(station_ys, y)
    isempty(station_ys)&&throw(ArgumentError("Applied loads require RBE3 reference centers"))
    length(station_ys)==1&&return ((1,1.0),)
    all(diff(station_ys).>0)||throw(ArgumentError("Load target RBE3 centers must have strictly increasing span positions"))
    y<=first(station_ys)&&return ((1,1.0),)
    y>=last(station_ys)&&return ((length(station_ys),1.0),)
    lo=searchsortedlast(station_ys,y)
    t=(y-station_ys[lo])/(station_ys[lo+1]-station_ys[lo])
    return ((lo,1-t),(lo+1,t))
end

"""Transfer complete source wrenches, retaining pure and force-arm contributions."""
function transfer_load_wrenches(positions,records;target_label="load")
    ys=[point[2] for point in positions];n=length(ys)
    forces=fill(AERO_ZERO,n);pure=fill(AERO_ZERO,n);lever=fill(AERO_ZERO,n)
    for s in records
        all(isfinite,s.force)&&all(isfinite,s.moment)&&all(isfinite,s.position)||error("Applied load contains nonfinite components")
        all(iszero,s.force)&&all(iszero,s.moment)&&continue
        isempty(ys)&&throw(ArgumentError("$target_label loads require their RBE3 reference centers; recreate FEM to generate the required connections"))
        for (i,weight) in moment_span_weights(ys,s.position[2])
            forces[i]=forces[i].+weight.*s.force
            pure[i]=pure[i].+weight.*s.moment
            lever[i]=lever[i].+weight.*cross3(s.position.-positions[i],s.force)
        end
    end
    return (force=forces,pure_moment=pure,force_arm_moment=lever,moment=[pure[i].+lever[i] for i in 1:n])
end

function routing_source_diagnostics(original,positions,routed)
    original_force,original_moment=load_resultant(original)
    mapped=[(position=positions[i],force=routed.force[i],moment=routed.moment[i]) for i in eachindex(positions)]
    force,moment=load_resultant(mapped)
    force_error=norm3(force.-original_force);moment_error=norm3(moment.-original_moment)
    force_scale=max(1.,sum((norm3(s.force) for s in original);init=0.))
    moment_scale=max(1.,sum((norm3(s.moment)+norm3(cross3(s.position,s.force)) for s in original);init=0.))
    force_error<=1e-10force_scale&&moment_error<=1e-10moment_scale||error("RBE3 load transfer failed force/moment conservation")
    return Dict{String,Any}("source_count"=>count(s->!all(iszero,s.force)||!all(iszero,s.moment),original),
        "target_count"=>length(positions),"original_force_N"=>collect(original_force),"applied_force_N"=>collect(force),
        "original_moment_origin_Nm"=>collect(original_moment),"applied_moment_origin_Nm"=>collect(moment),
        "force_error_N"=>force_error,"moment_error_Nm"=>moment_error,
        "force_relative_error"=>force_error/force_scale,"moment_relative_error"=>moment_error/moment_scale)
end

"""Explain the terminal aerodynamic couple without confusing it with root moment."""
function aerodynamic_terminal_diagnostics(m,loads,params=m.params)
    isempty(m.rbe3)&&return nothing
    last_index=length(m.rbe3);sp=last(m.rbe3);origin=Tuple(m.xyz[3sp.ref-2:3sp.ref])
    index=findfirst(s->s.gid==m.node_ids[sp.ref],loads.stations);index===nothing&&return nothing
    station=loads.stations[index];panels=get(loads,:panels,())
    pure=AERO_ZERO;lever=AERO_ZERO;outside_force=AERO_ZERO;outside_moment=AERO_ZERO
    if !isempty(panels)
        # Replay transfer_aero_loads' rib datum ETA brackets exactly. An angled
        # rib's reference GRID may have a different global-y coordinate.
        etas=[target.eta for target in m.rbe3]
        for panel in panels
            for (j,weight) in moment_span_weights(etas,panel.eta)
                j==last_index||continue
                pure=pure.+weight.*panel.moment
                lever=lever.+weight.*cross3(panel.position.-origin,panel.force)
            end
            if panel.position[2]>origin[2]
                outside_force=outside_force.+panel.force
                outside_moment=outside_moment.+panel.moment.+cross3(panel.position.-origin,panel.force)
            end
        end
    else
        lever=Tuple(get(get(loads,:summary,Dict()),"outboard_transfer_couple_Nm",collect(AERO_ZERO)))
        outside_moment=lever
        outside_force=(0.,0.,Float64(params["loads.lift_total"])*params["loads.load_factor"]*
            (1-lift_fraction(params["loads.distribution"],m.wing,sp.eta)))
    end
    tributary_start=last_index==1 ? 0. : (m.rbe3[last_index-1].eta+sp.eta)/2
    share=1-lift_fraction(params["loads.distribution"],m.wing,tributary_start)
    torque=(0.,Float64(params["loads.torque_y"])*params["loads.load_factor"]*share,0.)
    reconstructed=pure.+lever.+torque
    return Dict{String,Any}("grid"=>station.gid,"eta"=>sp.eta,"position_m"=>collect(origin),
        "force_N"=>collect(station.force),"moment_Nm"=>collect(station.moment),
        "intrinsic_panel_moment_Nm"=>collect(pure),"force_transfer_moment_Nm"=>collect(lever),
        "prescribed_torque_Nm"=>collect(torque),"decomposition_error_Nm"=>norm3(station.moment.-reconstructed),
        "outboard_force_N"=>collect(outside_force),"outboard_moment_about_last_rib_Nm"=>collect(outside_moment),
        "unboxed_span_m"=>max(0.,m.wing.root_ref_y+m.wing.semispan-origin[2]),
        "note"=>isempty(panels) ? "Prescribed loading beyond the final box rib retains its force lever arm at that rib; the final reference is not the aerodynamic tip when End eta is below 1." :
            "Force-transfer moment includes the chordwise/spanwise lever arm from each panel load point to the rib reference. Outboard contribution counts panel load points beyond the final reference; it is not a separate additional load.")
end

"""One combined force and couple per reference, retaining source decomposition."""
function routed_applied_loads(m::Model, loads; params=m.params)
    fuel=fuel_applied_loads(m;params);structure=structure_applied_loads(m;params)
    positions(spiders)=[Tuple(m.xyz[3sp.ref-2:3sp.ref]) for sp in spiders]
    aero_positions=positions(m.rbe3);fuel_positions=positions(m.fuel_rbe3)
    located(s)=(position=Tuple(m.xyz[3s.node+1:3s.node+3]),force=s.force,moment=s.moment)
    rawfuel=located.(fuel);rawstructure=located.(structure)
    sources=(aerodynamic=transfer_load_wrenches(aero_positions,loads.stations;target_label="Aerodynamic"),
        fuel=transfer_load_wrenches(fuel_positions,rawfuel;target_label="Fuel inertia"),
        structure=transfer_load_wrenches(fuel_positions,rawstructure;target_label="Structural inertia"))
    targets=NamedTuple[]
    for (i,sp) in enumerate(m.rbe3)
        push!(targets,(node_index=sp.ref,gid=m.node_ids[sp.ref],eta=sp.eta,position=aero_positions[i],
            force=sources.aerodynamic.force[i],moment=sources.aerodynamic.moment[i],target_kind="external_rbe3",
            target_rbe3_eid=sp.eid,fuel_bay=nothing,massless=false,
            source_forces=(aerodynamic=sources.aerodynamic.force[i],fuel=AERO_ZERO,structure=AERO_ZERO),
            source_moments=(aerodynamic=sources.aerodynamic.moment[i],fuel=AERO_ZERO,structure=AERO_ZERO),
            source_force_arm_moments=(aerodynamic=sources.aerodynamic.force_arm_moment[i],fuel=AERO_ZERO,structure=AERO_ZERO)))
    end
    for (i,sp) in enumerate(m.fuel_rbe3)
        push!(targets,(node_index=sp.ref,gid=m.node_ids[sp.ref],eta=(fuel_positions[i][2]-m.wing.root_ref_y)/m.wing.semispan,
            position=fuel_positions[i],force=sources.fuel.force[i].+sources.structure.force[i],
            moment=sources.fuel.moment[i].+sources.structure.moment[i],target_kind="fuel_rbe3",
            target_rbe3_eid=sp.eid,fuel_bay=sp.start_rib,massless=fuel_reference_is_massless(m,sp),
            source_forces=(aerodynamic=AERO_ZERO,fuel=sources.fuel.force[i],structure=sources.structure.force[i]),
            source_moments=(aerodynamic=AERO_ZERO,fuel=sources.fuel.moment[i],structure=sources.structure.moment[i]),
            source_force_arm_moments=(aerodynamic=AERO_ZERO,fuel=sources.fuel.force_arm_moment[i],structure=sources.structure.force_arm_moment[i])))
    end
    aerodynamic=[merge(s,(moment=AERO_ZERO,)) for s in targets if s.target_kind=="external_rbe3"]
    mass=[merge(s,(moment=AERO_ZERO,)) for s in targets if s.target_kind=="fuel_rbe3"]
    component(name)=[(node=s.node_index-1,gid=s.gid,bay=s.fuel_bay,force=getproperty(s.source_forces,name),moment=AERO_ZERO) for s in mass if !all(iszero,getproperty(s.source_forces,name))]
    diagnostics=Dict{String,Any}("version"=>APPLIED_LOAD_VERSION,"sources"=>Dict(
        "aerodynamic"=>routing_source_diagnostics(loads.stations,aero_positions,sources.aerodynamic),
        "fuel"=>routing_source_diagnostics(rawfuel,fuel_positions,sources.fuel),
        "structure"=>routing_source_diagnostics(rawstructure,fuel_positions,sources.structure)))
    terminal=aerodynamic_terminal_diagnostics(m,loads,params);diagnostics["terminal_aerodynamic"]=terminal
    diagnostics["maximum_target_moment"]=if isempty(targets)
        nothing
    else
        s=targets[argmax([norm3(t.moment) for t in targets])]
        Dict("grid"=>s.gid,"target_kind"=>s.target_kind,"eta"=>s.eta,"magnitude_Nm"=>norm3(s.moment),
            "moment_Nm"=>collect(s.moment),"source_moments_Nm"=>Dict(String(k)=>collect(v) for (k,v) in pairs(s.source_moments)))
    end
    lines=String["Load routing: aerodynamic resultants use rib RBE3s; fuel/structural resultants use bay RBE3s, including force-transfer lever arms."]
    for key in ("aerodynamic","fuel","structure")
        d=diagnostics["sources"][key]
        push!(lines,@sprintf("%s: %d source loads to %d references; force residual %.3g N, origin-moment residual %.3g N m.",key,d["source_count"],d["target_count"],d["force_error_N"],d["moment_error_Nm"]))
    end
    if terminal!==nothing
        v=terminal["moment_Nm"]
        vector_text(values)="["*join(fmt.(values,6),", ")*"]"
        push!(lines,@sprintf("Last aerodynamic reference GRID %d at ETA %.5f: moment %s N m; unboxed span %.5g m.",terminal["grid"],terminal["eta"],vector_text(v),terminal["unboxed_span_m"]))
        push!(lines,"Terminal moment decomposition (N m): panel intrinsic "*vector_text(terminal["intrinsic_panel_moment_Nm"])*", force lever arm "*vector_text(terminal["force_transfer_moment_Nm"])*", prescribed torque "*vector_text(terminal["prescribed_torque_Nm"])*".")
    end
    largest=diagnostics["maximum_target_moment"]
    if largest!==nothing
        push!(lines,@sprintf("Largest applied couple: GRID %d (%s), %s N m.",largest["grid"],largest["target_kind"],fmt(largest["magnitude_Nm"],6)))
        source_text(key)="["*join(fmt.(largest["source_moments_Nm"][key],6),", ")*"]"
        push!(lines,"Largest-couple sources (N m): aerodynamic "*source_text("aerodynamic")*", fuel "*source_text("fuel")*", structure "*source_text("structure")*".")
    end
    diagnostics["log_lines"]=lines
    return (aerodynamic=aerodynamic,fuel=component(:fuel),structure=component(:structure),mass=mass,
        forces=[merge(s,(moment=AERO_ZERO,)) for s in targets],moments=[merge(s,(force=AERO_ZERO,)) for s in targets],diagnostics=diagnostics)
end
