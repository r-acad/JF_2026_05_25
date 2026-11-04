# Numerical stability/control derivatives of the SAME physical force recovery
# as the base study (PG, sideslip, rates, density and dimensional references).
# Fix topology across each stencil to avoid differentiating the mesh generator.
function aerodynamic_recontrol(w,patches,s)
    map(patches) do patch
        grid=similar(patch.grid)
        for (j,e) in enumerate(patch.etas),(i,xi) in enumerate(patch.xis)
            z=vcat(0.,[movable_chord_coordinate(c,"front_spar",e) for c in patch.active],1.)
            k=min(floor(Int,xi)+1,length(z)-1);t=xi-(k-1)
            xc=hasproperty(patch,:chord_coordinates) ? patch.chord_coordinates[i,j] : (1-t)*z[k]+t*z[k+1]
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

function aerodynamic_derivatives(w,controls,patches,s,base;work=nothing,progress=(stage,done,total)->nothing)
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
    rows=Any[];remeshed_controls=String[];unavailable=Any[]
    bump!(key)=work===nothing ? nothing : (work[key]=get(work,key,0)+1)
    work===nothing||(work["derivative_variables"]=get(work,"derivative_variables",0)+length(variables))
    for (i,v) in enumerate(variables)
        progress("Computing derivatives: $(v.key) ($i / $(length(variables)))",i-1,length(variables))
        left=startswith(v.key,"control_left:");control=left||startswith(v.key,"control:")
        name=control ? v.key[(left ? 14 : 9):end] : ""
        center=control ? s["controls"][name][left ? "left" : "right"] : s[v.key]
        low=max(v.lo,center-v.step*v.scale);high=min(v.hi,center+v.step*v.scale)
        function control_command(value)
            c=copy(s["controls"][name]);c[left ? "left" : "right"]=value
            if !left&&(c["source"]=="geometry"||c["pairing"]!="independent");c["left"]=c["source"]=="geometry"||c["pairing"]=="symmetric" ? value : -value;end
            c
        end
        # A neutral offset-hinge sheet is physically continuous. Its moving
        # perturbations must open the real seam instead of stretching a fixed
        # panel across the gap. Other derivatives retain the base topology.
        row=control ? only(filter(c->c["name"]==name,controls)) : nothing
        sides=left ? ("left",) : control&&s["controls"][name]["pairing"]=="independent"&&s["controls"][name]["source"]!="geometry" ? ("right",) : ("left","right")
        transition=control&&aerodynamic_control_gap(w,row)&&any(
            iszero(aerodynamic_motion_angle(w,row,side,s["controls"][name]))!=iszero(aerodynamic_motion_angle(w,row,side,control_command(value)))
            for side in sides for value in (low,high))
        if transition&&s["wake_model"]=="relaxed"&&s["wake_derivatives"]=="frozen"
            reason="An offset-hinge control stencil crosses neutral motion and changes wake-sheet topology; a frozen base wake cannot be attached to that control stencil. Select relaxed wake derivatives to evaluate this control."
            push!(unavailable,Dict("variable"=>v.key,"reason"=>reason));push!(base["warnings"],v.key*": "*reason)
            bump!("unavailable_derivative_variables")
            continue
        end
        transition&&push!(remeshed_controls,v.key)
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
            if value==center;bump!("derivative_base_reuses");return base;end
            # With a manual atmosphere altitude is metadata only: density,
            # sound speed, geometry, dimensional velocity and all coefficients
            # remain exactly unchanged. Preserve the row without two solves.
            if v.key=="altitude"&&s["atmosphere"]=="manual"
                bump!("inactive_derivative_reuses");return base
            end
            t=deepcopy(s)
            if control
                t["controls"][name]=control_command(value)
            else;t[v.key]=value;end
            seed=transition ? nothing : get(base,"wake",nothing)
            if s["wake_model"]=="relaxed"&&s["wake_derivatives"]=="relaxed";t["wake_tolerance"]=min(s["wake_tolerance"],1e-5);end
            sample_mesh=transition ? aerodynamic_mesh(w,controls,t;progress) : control ? aerodynamic_recontrol(w,patches,t) : patches
            interference=control ? aerodynamic_body_interference(sample_mesh) : get(base,"geometry_interference",nothing)
            transition&&!interference["valid"]&&return nothing
            bump!("derivative_solves")
            return aerodynamic_solve(w,sample_mesh,t;
                coefficients_only=true,geometry_interference=interference,
                wake_seed=seed===nothing ? nothing : seed["sheets"],
                frozen_wake=seed!==nothing&&s["wake_derivatives"]=="frozen",progress)
        end
        minus=sample(low);plus=sample(high);delta=(high-low)/v.scale
        if minus===nothing||plus===nothing
            reason="A neutral offset-hinge control perturbation intersects another physical sheet. Revise control end clearances or hinge geometry before using this control derivative."
            push!(unavailable,Dict("variable"=>v.key,"reason"=>reason));push!(base["warnings"],v.key*": "*reason)
            bump!("unavailable_derivative_variables")
            continue
        end
        coefficients=Dict(frame=>Dict(kind=>(plus["coefficients"][frame][kind].-minus["coefficients"][frame][kind])./delta
            for kind in ("force","force_components","moment")) for frame in ("body","aerodynamic","wind","stability"))
        finite_difference(key)=begin
            a=plus[key];b=minus[key];base[key] isa Real&&a isa Real&&b isa Real&&isfinite(a)&&isfinite(b) ? (a-b)/delta : nothing
        end
        push!(rows,Dict("variable"=>v.key,"unit"=>v.unit,"step"=>v.step,"stencil_width"=>delta,
            "method"=>(low<center<high ? "central" : "one-sided at analysis bound"),"coefficients"=>coefficients,
            "CDi_trefftz"=>finite_difference("CDi_trefftz"),"span_efficiency"=>finite_difference("span_efficiency")))
    end
    return Dict("remeshed_control_stencils"=>remeshed_controls,"unavailable"=>unavailable,
        "wake_tolerance"=>s["wake_model"]=="relaxed"&&s["wake_derivatives"]=="relaxed" ? min(s["wake_tolerance"],1e-5) : nothing,
        "wake_policy"=>s["wake_model"]=="relaxed" ? s["wake_derivatives"] : "straight",
        "method"=>(s["wake_model"]=="relaxed" ? (s["wake_derivatives"]=="frozen" ? "Finite relaxed-wake geometry frozen in construction C during derivative perturbations; trailing-edge attachment follows control motion and the infinite continuation follows freestream. Circulation remains fully coupled. " : "Wake geometry independently re-relaxed for each perturbation with tolerance min(user tolerance, 1e-5), retaining the specified iteration cap. ") : "Straight-wake derivative. ")*(s["wake_model"]=="relaxed" ? "Trefftz drag/efficiency derivatives evaluate the terminal cross-section and straight far continuation with the selected wake policy; check terminal-shape sensitivity and refinement. " : "")*"Two-point finite differences; neutral offset-hinge control stencils are remeshed, while other stencils retain fixed base topology. Central except at analysis bounds. Unavailable control stencils are listed with their reason. Angles/control commands per radian; rates use Body B p*b/(2V), q*MAC/(2V), r*b/(2V), including when output coefficients are in S or W-prime. Speed and altitude hold all other dimensional inputs fixed. Geometry-source control derivatives perturb the shared authored hinge angle on both halves. Analysis overrides follow selected pairing; independent left commands have separate derivatives. Physical hinge motion and fixed/control splits follow the actual perturbed geometry; a neutral offset-hinge transition cannot reuse a frozen base wake. Moment/rate reference and fixed stability alpha0 match the base result; A and W-prime follow perturbed alpha/beta. Body/A/S force entries are signed CX/CY/CZ; W-prime shows positive CDi/CY/CL. force_components always uses signed frame components. Quasi-steady derivatives only: no alpha-dot, beta-dot, acceleration, frequency or unsteady-wake derivatives.","rows"=>rows)
end
