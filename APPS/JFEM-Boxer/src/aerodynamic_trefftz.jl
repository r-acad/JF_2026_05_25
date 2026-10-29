# Far-wake estimate for the MODELLED straight continuation of a relaxed wake.
# Kroo & Smith (1991), "The Computation of Induced Drag with Nonplanar and
# Deformed Wakes", eq. (2), computational approach 5. Project the TERMINAL
# wake strip geometry into a plane normal to freestream; retain its current
# strip circulation. Grids are already in incompressible solver wind axes;
# their transverse end coordinates define the far section after all straight
# tails have started, and circulation has physical m^2/s units. This is not a claim of a fully resolved wake at infinity.

function aerodynamic_trefftz_cut(grids,strengths,speed,area;fraction=1.)
    panels=Tuple{NTuple{2,Float64},NTuple{2,Float64},Float64,Float64}[]
    nodes=Dict{NTuple{2,Float64},Float64}();xrange=[Inf,-Inf];fractions=Float64[]
    for (g,gamma) in zip(grids,strengths)
        rows=size(g,2)-1
        index=fraction==1 ? rows+1 : clamp(floor(Int,fraction*rows)+1,2,rows)
        for j in axes(g,3)
            xrange[1]=min(xrange[1],g[1,index,j]);xrange[2]=max(xrange[2],g[1,index,j])
            push!(fractions,(g[1,index,j]-g[1,1,j])/(g[1,end,j]-g[1,1,j]))
        end
        for j in eachindex(gamma)
            left=(g[2,index,j],g[3,index,j]);right=(g[2,index,j+1],g[3,index,j+1])
            dy,dz=right.-left;width=hypot(dy,dz)
            center=((left[1]+right[1])/2,(left[2]+right[2])/2)
            push!(panels,(center,(-dz,dy),Float64(gamma[j]),width))
            nodes[left]=get(nodes,left,0.)-gamma[j]
            nodes[right]=get(nodes,right,0.)+gamma[j]
        end
    end
    scale=max(maximum(p[4] for p in panels),maximum(hypot(q...) for q in keys(nodes)),1.)
    tolerance=128eps(Float64)*scale
    maxgamma=maximum(abs(p[3]) for p in panels)
    base=Dict{String,Any}("valid"=>true,"reason"=>nothing,"CDi"=>nothing,
        "requested_row_fraction"=>fraction,"mean_streamwise_fraction"=>sum(fractions)/length(fractions),
        "continuation_start_x_range_m"=>xrange,"strip_count"=>length(panels),
        "nearest_filament_over_strip_width"=>nothing)
    if iszero(maxgamma);base["CDi"]=0.;return base;end
    # Remove only cancellation roundoff at shared wake vertices, not physical
    # weak tip vortices. Each strip still sheds an equal/opposite vortex pair.
    cutoff=64eps(Float64)*maxgamma
    active=[(q,gamma) for (q,gamma) in nodes if abs(gamma)>cutoff]
    drag=0.;nearest=Inf
    for (center,normal,gamma,width) in panels
        abs(gamma)>cutoff||continue
        if width<=tolerance
            base["valid"]=false;base["reason"]="A loaded terminal wake strip has collapsed in the Trefftz projection";return base
        end
        velocity=(0.,0.)
        for (point,strength) in active
            dy,dz=center.-point;r2=dy^2+dz^2
            if r2<=tolerance^2
                base["valid"]=false;base["reason"]="A Trefftz strip midpoint coincides with a loaded wake filament; refine the wake cross-section";return base
            end
            nearest=min(nearest,sqrt(r2)/width)
            factor=strength/(2pi*r2)
            velocity=velocity.+(-factor*dz,factor*dy)
        end
        # D = -rho/2 sum(Gamma * (v,w).(-dz,dy)); qS=rho V^2 S/2.
        drag-=gamma*sum(velocity.*normal)
    end
    cdi=drag/(speed^2*area)
    base["nearest_filament_over_strip_width"]=isfinite(nearest) ? nearest : nothing
    base["raw_CDi"]=isfinite(cdi) ? cdi : nothing
    if !isfinite(cdi)||cdi<=0
        base["valid"]=false;base["reason"]="The loaded terminal wake gives a nonpositive/nonfinite discrete Trefftz estimate; refine wake shape and spacing";return base
    end
    base["CDi"]=cdi
    return base
end

function aerodynamic_relaxed_trefftz(grids,strengths,speed,area)
    terminal=aerodynamic_trefftz_cut(grids,strengths,speed,area)
    earlier=aerodynamic_trefftz_cut(grids,strengths,speed,area;fraction=.8)
    a,b=terminal["CDi"],earlier["CDi"]
    change=a===nothing||b===nothing ? nothing : abs(a-b)/max(abs(a),abs(b),eps(Float64))
    return Dict{String,Any}("model"=>"relaxed_terminal_continuation","valid"=>terminal["valid"],
        "CDi"=>a,"reason"=>terminal["reason"],"terminal_cut"=>terminal,
        "earlier_cut"=>earlier,"relative_cut_change"=>change,
        "method"=>"Discrete Trefftz wake-sheet integral at the relaxed wake end, using current trailing-edge circulation and the model's straight semi-infinite continuation. Unregularized midpoint crossflow kernel; convection core affects the computed wake shape. End-section estimate, not a fully resolved rolled-up far wake.",
        "sensitivity_note"=>"Earlier cut uses the same circulation with a hypothetical straight continuation starting at an earlier wake section. It measures terminal-shape sensitivity; it is not an independent wake-length or grid-convergence test.")
end
