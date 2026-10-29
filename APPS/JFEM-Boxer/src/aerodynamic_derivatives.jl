# Numerical stability/control derivatives of the SAME physical force recovery
# as the base study (PG, sideslip, rates, density and dimensional references).
# Fix topology across each stencil to avoid differentiating the mesh generator.
function aerodynamic_recontrol(w,patches,s)
    map(patches) do patch
        grid=similar(patch.grid)
        for (j,e) in enumerate(patch.etas),(i,xi) in enumerate(patch.xis)
            z=vcat(0.,[movable_chord_coordinate(c,"front_spar",e) for c in patch.active],1.)
            k=min(floor(Int,xi)+1,length(z)-1);t=xi-(k-1);xc=(1-t)*z[k]+t*z[k+1]
            v=camber_point(w,e,xc)
            for (idx,row) in enumerate(patch.active)
                idx in patch.split_boundaries&&((row["edge"]=="trailing"&&last(patch.zone_range)<=idx)||(row["edge"]=="leading"&&first(patch.zone_range)>idx))&&continue
                c=s["controls"][row["name"]]
                v=aerodynamic_control_point(w,row,e,xc,v,aerodynamic_motion_angle(w,row,patch.side,c))
            end
            grid[:,i,j].=v
        end
        patch.side=="left"&&(grid[2,:,:].=2w.root_ref_y.-grid[2,:,:])
        merge(patch,(grid=grid,metrics=validate_vlm_grid(grid)))
    end
end

function aerodynamic_derivatives(w,controls,patches,s,base;progress=(stage,done,total)->nothing)
    # Derivative coordinates: angles in radians; p_hat=p*b/(2V),
    # q_hat=q*MAC/(2V), r_hat=r*b/(2V); speed m/s and altitude m.
    variables=[(key=key,unit="rad^-1",step=1e-3,scale=180/pi,lo=-30.,hi=30.) for key in ("alpha","beta")]
    append!(variables,[(key=key,unit="per nondimensional rate",step=1e-3,scale=rad2deg(2s["speed"]/length),lo=-360.,hi=360.)
        for (key,length) in (("p",w.span),("q",w.mac),("r",w.span))])
    push!(variables,(key="speed",unit="(m/s)^-1",step=max(.001,.001s["speed"]),scale=1.,lo=.01,hi=.5base["flight"]["speed_of_sound_m_s"]))
    push!(variables,(key="altitude",unit="m^-1",step=1.,scale=1.,lo=-5000.,hi=86000.))
    for c in controls
        command=s["controls"][c["name"]];command["enabled"]||continue
        for key in vcat("control:"*c["name"],command["pairing"]=="independent" ? ["control_left:"*c["name"]] : String[])
            push!(variables,(key=key,unit="rad^-1",step=1e-3,scale=180/pi,lo=-45.,hi=45.))
        end
    end
    rows=Any[]
    for (i,v) in enumerate(variables)
        progress("Computing derivatives: $(v.key) ($i / $(length(variables)))",i-1,length(variables))
        left=startswith(v.key,"control_left:");control=left||startswith(v.key,"control:")
        name=control ? v.key[(left ? 14 : 9):end] : ""
        center=control ? s["controls"][name][left ? "left" : "right"] : s[v.key]
        low=max(v.lo,center-v.step*v.scale);high=min(v.hi,center+v.step*v.scale)
        # At the Mach envelope an altitude perturbation can reduce sound speed.
        # Use a valid one-sided stencil rather than fail an otherwise valid base.
        if v.key=="altitude"&&s["atmosphere"]=="isa1976"
            for side in ("low","high")
                value=side=="low" ? low : high
                flight=flight_condition(Dict{String,Any}("aero.atmosphere"=>s["atmosphere"],"aero.altitude"=>value,"aero.speed"=>s["speed"]))
                if flight["Mach"]>.5+8eps(.5);side=="low" ? (low=center) : (high=center);end
            end
        end
        high>low||throw(ArgumentError("No valid finite-difference stencil for $(v.key)"))
        function sample(value)
            value==center&&return base
            t=deepcopy(s)
            if control
                c=t["controls"][name];c[left ? "left" : "right"]=value
                if !left&&(c["source"]=="geometry"||c["pairing"]!="independent");c["left"]=c["source"]=="geometry"||c["pairing"]=="symmetric" ? value : -value;end
            else;t[v.key]=value;end
            seed=get(base,"wake",nothing)
            if seed!==nothing&&s["wake_derivatives"]=="relaxed";t["wake_tolerance"]=min(s["wake_tolerance"],1e-5);end
            return aerodynamic_solve(w,control ? aerodynamic_recontrol(w,patches,t) : patches,t;
                wake_seed=seed===nothing ? nothing : seed["sheets"],
                frozen_wake=seed!==nothing&&s["wake_derivatives"]=="frozen",progress)
        end
        minus=sample(low);plus=sample(high);delta=(high-low)/v.scale
        coefficients=Dict(frame=>Dict(kind=>(plus["coefficients"][frame][kind].-minus["coefficients"][frame][kind])./delta
            for kind in ("force","force_components","moment")) for frame in ("body","aerodynamic","wind","stability"))
        finite_difference(key)=begin
            a=plus[key];b=minus[key];base[key] isa Real&&a isa Real&&b isa Real&&isfinite(a)&&isfinite(b) ? (a-b)/delta : nothing
        end
        push!(rows,Dict("variable"=>v.key,"unit"=>v.unit,"step"=>v.step,"stencil_width"=>delta,
            "method"=>(low<center<high ? "central" : "one-sided at analysis bound"),"coefficients"=>coefficients,
            "CDi_trefftz"=>finite_difference("CDi_trefftz"),"span_efficiency"=>finite_difference("span_efficiency")))
    end
    return Dict("wake_tolerance"=>s["wake_model"]=="relaxed"&&s["wake_derivatives"]=="relaxed" ? min(s["wake_tolerance"],1e-5) : nothing,
        "wake_policy"=>s["wake_model"]=="relaxed" ? s["wake_derivatives"] : "straight",
        "method"=>(s["wake_model"]=="relaxed" ? (s["wake_derivatives"]=="frozen" ? "Finite relaxed-wake geometry frozen in construction C during derivative perturbations; trailing-edge attachment follows control motion and the infinite continuation follows freestream. Circulation remains fully coupled. " : "Wake geometry independently re-relaxed for each perturbation with tolerance min(user tolerance, 1e-5), retaining the specified iteration cap. ") : "Straight-wake derivative. ")*(s["wake_model"]=="relaxed" ? "Trefftz drag/efficiency derivatives evaluate the terminal cross-section and straight far continuation with the selected wake policy; check terminal-shape sensitivity and refinement. " : "")*"Two-point finite differences on fixed base topology; central except at analysis bounds. Angles/control commands per radian; rates use Body B p*b/(2V), q*MAC/(2V), r*b/(2V), including when output coefficients are in S or W-prime. Speed and altitude hold all other dimensional inputs fixed. Geometry-source control derivatives perturb the shared authored hinge angle on both halves. Analysis overrides follow selected pairing; independent left commands have separate derivatives. Physical hinge motion and any fixed/control split remain consistent with the base topology. Moment/rate reference and fixed stability alpha0 match the base result; A and W-prime follow perturbed alpha/beta. Body/A/S force entries are signed CX/CY/CZ; W-prime shows positive CDi/CY/CL. force_components always uses signed frame components. Quasi-steady derivatives only: no alpha-dot, beta-dot, acceleration, frequency or unsteady-wake derivatives.","rows"=>rows)
end
