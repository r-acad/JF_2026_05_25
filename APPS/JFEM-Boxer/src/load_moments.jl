# Conservative force/couple transfer to the two load-bearing RBE3 families.
# This generated-model formulation token also guards fixed section constants:
# the 5 mm² square runout changes stiffness, structural mass and inertia loads
# even when every user parameter and every mesh node remains unchanged.
# Local component property ownership is also versioned so older sensitivity
# scopes cannot be shown as current against the newly split property cards.
# Rib-datum runouts change the generated mesh, stiffness and structural mass.
# Historical studies must not reuse their solved fields as current results.
const APPLIED_LOAD_VERSION = "rib_aero_bay_mass_wrenches_pg_runout5mm2_ribdatum_combinedflanges_tiprbe3_controlpaths_axialactuators_engineflexible_v12"
const APPLIED_MOMENT_ROUTING_NOTE = "Aerodynamic forces and moments retain their assigned main-box or movable-surface RBE3 centers, including massless references beyond each structural tip. Fuel and structural shell/bar inertia forces and moments act at fuel/mass bay RBE3 centers. Engine inertia acts directly at each engine CG and passes through its own attachments; it is never transferred to wing mass bays. Bracketing span weights preserve force and global moment; moved forces add (source position - target position) cross force. Massless bay references add no fuel capacity or CONM2 mass. Inertia loads and all applied couples remain fixed in global axes."

"""Engine dead inertia loads at their actual CGs, preserving the mount load path.

The structural-inertia switch and case acceleration/multiplier apply once.
Engine CONM2 mass remains in the exported model even when this switch is off.
"""
function engine_applied_loads(m::Model;params=m.params)
    acceleration=structure_acceleration(params)
    all(iszero,acceleration)&&return NamedTuple[]
    [(node=Int(engine["cg_node"])-1,gid=m.node_ids[Int(engine["cg_node"])],
        force=Float64(engine["mass_kg"]).*acceleration,moment=AERO_ZERO,
        target_rbe3_eid=nothing)
        for engine in engine_structure_data(m)["engines"] if engine["mass_kg"]>0]
end

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
        routing=aerodynamic_routing(m)
        for panel in panels
            panel_weights=aerodynamic_target_weights(routing,panel.position;eta=panel.eta)
            for (j,weight) in panel_weights
                j==last_index||continue
                pure=pure.+weight.*panel.moment
                lever=lever.+weight.*cross3(panel.position.-origin,panel.force)
            end
            if panel.position[2]>origin[2] && any(j<=length(m.rbe3) for (j,_) in panel_weights)
                outside_force=outside_force.+panel.force
                outside_moment=outside_moment.+panel.moment.+cross3(panel.position.-origin,panel.force)
            end
        end
    else
        lever=last(analytic_outboard_station_moments(m))
        outside_moment=lever
        outside_force=(0.,0.,effective_prescribed_lift(params)*params["loads.load_factor"]*
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
        "unboxed_span_m"=>max(0.,(1-last(m.grid.etas))*m.wing.semispan),
        "reference_is_virtual"=>sp.station<0,"structural_end_eta"=>last(m.grid.etas),
        "note"=>isempty(panels) ? "Prescribed loading beyond the box uses massless RBE3 references tied to the terminal rib. Each unboxed strip retains its force arm about its own reference." :
            "Force-transfer moment includes the chordwise/spanwise lever arm from each panel load point to the rib reference. Outboard contribution counts panel load points beyond the final reference; it is not a separate additional load.")
end

"""One combined force and couple per reference, retaining source decomposition."""
function routed_applied_loads(m::Model, loads; params=m.params)
    fuel=fuel_applied_loads(m;params);structure=structure_applied_loads(m;params);engines=engine_applied_loads(m;params)
    positions(spiders)=[Tuple(m.xyz[3sp.ref-2:3sp.ref]) for sp in spiders]
    aero_refs=aerodynamic_references(m);aero_positions=positions(aero_refs);fuel_positions=positions(m.fuel_rbe3)
    located(s)=(position=Tuple(m.xyz[3s.node+1:3s.node+3]),force=s.force,moment=s.moment)
    rawfuel=located.(fuel);rawstructure=located.(structure);rawengines=located.(engines)
    sources=(aerodynamic=assigned_aerodynamic_wrenches(m,loads.stations,aero_refs),
        fuel=transfer_load_wrenches(fuel_positions,rawfuel;target_label="Fuel inertia"),
        structure=transfer_load_wrenches(fuel_positions,rawstructure;target_label="Structural inertia"))
    targets=NamedTuple[]
    for (i,sp) in enumerate(aero_refs)
        push!(targets,(node_index=sp.ref,gid=m.node_ids[sp.ref],eta=sp.eta,position=aero_positions[i],
            force=sources.aerodynamic.force[i],moment=sources.aerodynamic.moment[i],target_kind=sp.target_kind,
            target_rbe3_eid=sp.eid,fuel_bay=nothing,massless=sp.massless,
            source_forces=(aerodynamic=sources.aerodynamic.force[i],fuel=AERO_ZERO,structure=AERO_ZERO,engine=AERO_ZERO),
            source_moments=(aerodynamic=sources.aerodynamic.moment[i],fuel=AERO_ZERO,structure=AERO_ZERO,engine=AERO_ZERO),
            source_force_arm_moments=(aerodynamic=sources.aerodynamic.force_arm_moment[i],fuel=AERO_ZERO,structure=AERO_ZERO,engine=AERO_ZERO)))
    end
    for (i,sp) in enumerate(m.fuel_rbe3)
        push!(targets,(node_index=sp.ref,gid=m.node_ids[sp.ref],eta=(fuel_positions[i][2]-m.wing.root_ref_y)/m.wing.semispan,
            position=fuel_positions[i],force=sources.fuel.force[i].+sources.structure.force[i],
            moment=sources.fuel.moment[i].+sources.structure.moment[i],target_kind="fuel_rbe3",
            target_rbe3_eid=sp.eid,fuel_bay=sp.start_rib,massless=bay_reference_is_massless(m,sp),
            source_forces=(aerodynamic=AERO_ZERO,fuel=sources.fuel.force[i],structure=sources.structure.force[i],engine=AERO_ZERO),
            source_moments=(aerodynamic=AERO_ZERO,fuel=sources.fuel.moment[i],structure=sources.structure.moment[i],engine=AERO_ZERO),
            source_force_arm_moments=(aerodynamic=AERO_ZERO,fuel=sources.fuel.force_arm_moment[i],structure=sources.structure.force_arm_moment[i],engine=AERO_ZERO)))
    end
    for load in engines
        point=Tuple(m.xyz[3load.node+1:3load.node+3])
        push!(targets,(node_index=load.node+1,gid=load.gid,eta=(point[2]-m.wing.root_ref_y)/m.wing.semispan,
            position=point,force=load.force,moment=load.moment,target_kind="engine_mass",
            target_rbe3_eid=load.target_rbe3_eid,fuel_bay=nothing,massless=false,
            source_forces=(aerodynamic=AERO_ZERO,fuel=AERO_ZERO,structure=AERO_ZERO,engine=load.force),
            source_moments=(aerodynamic=AERO_ZERO,fuel=AERO_ZERO,structure=AERO_ZERO,engine=load.moment),
            source_force_arm_moments=(aerodynamic=AERO_ZERO,fuel=AERO_ZERO,structure=AERO_ZERO,engine=AERO_ZERO)))
    end
    aerodynamic=[merge(s,(moment=AERO_ZERO,)) for s in targets if s.target_kind in ("external_rbe3","control_rbe3")]
    mass=[merge(s,(moment=AERO_ZERO,)) for s in targets if s.target_kind in ("fuel_rbe3","engine_mass")]
    component(name)=[(node=s.node_index-1,gid=s.gid,bay=s.fuel_bay,force=getproperty(s.source_forces,name),moment=AERO_ZERO) for s in mass if !all(iszero,getproperty(s.source_forces,name))]
    diagnostics=Dict{String,Any}("version"=>APPLIED_LOAD_VERSION,"sources"=>Dict(
        "aerodynamic"=>routing_source_diagnostics(loads.stations,aero_positions,sources.aerodynamic),
        "fuel"=>routing_source_diagnostics(rawfuel,fuel_positions,sources.fuel),
        "structure"=>routing_source_diagnostics(rawstructure,fuel_positions,sources.structure),
        "engine"=>routing_source_diagnostics(rawengines,[s.position for s in rawengines],
            (force=[s.force for s in rawengines],moment=[s.moment for s in rawengines]))))
    terminal=aerodynamic_terminal_diagnostics(m,loads,params);diagnostics["terminal_aerodynamic"]=terminal
    diagnostics["maximum_target_moment"]=if isempty(targets)
        nothing
    else
        s=targets[argmax([norm3(t.moment) for t in targets])]
        Dict("grid"=>s.gid,"target_kind"=>s.target_kind,"eta"=>s.eta,"magnitude_Nm"=>norm3(s.moment),
            "moment_Nm"=>collect(s.moment),"source_moments_Nm"=>Dict(String(k)=>collect(v) for (k,v) in pairs(s.source_moments)))
    end
    lines=String["Load routing: aerodynamic resultants retain their assigned main/control RBE3s; fuel/structural resultants use bay RBE3s, including force-transfer lever arms; engine inertia acts directly at each engine CG."]
    for key in ("aerodynamic","fuel","structure","engine")
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
        push!(lines,"Largest-couple sources (N m): aerodynamic "*source_text("aerodynamic")*", fuel "*source_text("fuel")*", structure "*source_text("structure")*", engine "*source_text("engine")*".")
    end
    diagnostics["log_lines"]=lines
    return (aerodynamic=aerodynamic,fuel=component(:fuel),structure=component(:structure),engine=component(:engine),mass=mass,
        forces=[merge(s,(moment=AERO_ZERO,)) for s in targets],moments=[merge(s,(force=AERO_ZERO,)) for s in targets],diagnostics=diagnostics)
end
