# Steady, circulation-coupled free-wake relaxation in incompressible flow.
# Each wake strip carries its CURRENT trailing-edge circulation. Wake columns
# enter the bound-system AIC, rather than treating lagged wake strength as RHS.
# Geometry iterates at fixed downstream stations using midpoint streamline
# tangency and under-relaxation. A straight semi-infinite tail closes each strip.

function aerodynamic_wake_panels(grids, strengths, core)
    [begin
        nw,ns=size(g,2)-1,size(g,3)-1
        [VortexLattice.WakePanel(VortexLattice.SVector{3}(g[:,i,j]),
            VortexLattice.SVector{3}(g[:,i,j+1]),VortexLattice.SVector{3}(g[:,i+1,j]),
            VortexLattice.SVector{3}(g[:,i+1,j+1]),core,strengths[k][j]) for i in 1:nw,j in 1:ns]
    end for (k,g) in enumerate(grids)]
end

function aerodynamic_wake_geometry(system,s,w,forward,origin,seed)
    distance=s["wake_length"]*w.span;rows=s["wake_rows"]
    [begin
        te=VortexLattice.trailing_edge_points(surface);g=zeros(3,rows+1,length(te))
        if seed===nothing
            # Mild downstream grading resolves the near wake without very long
            # first cells. Every shared TE vertex gets the same station offsets.
            for j in eachindex(te),i in 0:rows
                g[:,i+1,j].=te[j].+VortexLattice.SVector(distance*(i/rows)^1.3,0.,0.)
            end
        else
            lines=seed[k]["lines"]
            length(lines)==length(te)&&all(length(line)==rows+1 for line in lines)||
                throw(ArgumentError("Frozen wake topology differs from the base case"))
            for j in eachindex(te),i in 1:rows+1
                g[:,i,j].=forward(Tuple(lines[j][i]).-origin)
            end
            # Control perturbations must remain attached to the current TE.
            for j in eachindex(te);g[:,1,j].=te[j];end
        end
        all(all(diff(g[1,:,j]).>0) for j in axes(g,3))||
            throw(ArgumentError("Wake streamwise stations fold back; reduce incidence/rates or use a relaxed derivative"))
        g
    end for (k,surface) in enumerate(system.surfaces)]
end

function aerodynamic_coupled_wake!(system,grids,closed,rhs,core)
    units=aerodynamic_wake_panels(grids,[ones(size(g,3)-1) for g in grids],core)
    system.AIC.=closed
    offset=0
    for (k,surface) in enumerate(system.surfaces)
        nc,ns=size(surface)
        for j in 1:ns
            col=offset+nc*j;strip=view(units[k],:,j:j);row=0
            for (receiver,other) in enumerate(system.surfaces),panel in other
                row+=1
                velocity=VortexLattice.induced_velocity(VortexLattice.controlpoint(panel),strip;
                    finite_core=system.surface_id[k]!=system.surface_id[receiver],trailing_vortices=true)
                system.AIC[row,col]+=sum(velocity.*VortexLattice.normal(panel))
            end
        end
        offset+=length(surface)
    end
    system.w.=rhs;system.Γ.=system.AIC\rhs
    all(isfinite,system.Γ)||error("Nonfinite circulation in coupled free-wake solve")
    strengths=Vector{Float64}[];offset=0
    for surface in system.surfaces
        nc,ns=size(surface);push!(strengths,[system.Γ[offset+nc*j] for j in 1:ns]);offset+=length(surface)
    end
    wakes=aerodynamic_wake_panels(grids,strengths,core)
    system.wakes.=wakes;system.nwake.=size.(wakes,1)
    return wakes,strengths
end

# The package's endpoint core formula is singular at an exact filament
# midpoint. Convect with the analytic Rosenhead-regularized Biot-Savart line
# integral instead. It is finite at endpoints/on-axis, tends to the classical
# kernel off-core, and gives zero self-velocity for a straight filament.
function aerodynamic_core_segment(point,a,b,gamma,core)
    r1=point-a;r2=point-b;edge=b-a;v=cross(r1,r2)
    den=sum(abs2,v)+core^2*sum(abs2,edge)
    den>0||return zero(point)
    gamma/(4pi)*sum(edge.*(r1/sqrt(sum(abs2,r1)+core^2)-r2/sqrt(sum(abs2,r2)+core^2)))/den*v
end
function aerodynamic_core_tail(point,a,gamma,core)
    r=point-a;perp=r[2]^2+r[3]^2
    gamma/(4pi)*(1+r[1]/sqrt(sum(abs2,r)+core^2))/(perp+core^2)*VortexLattice.SVector(0.,-r[3],r[2])
end
function aerodynamic_wake_filaments(system,grids,strengths)
    T=NTuple{3,Float64};edges=Dict{Tuple{T,T},Float64}();tails=Dict{T,Float64}()
    function edge(a,b,gamma)
        a,b=Tuple(a),Tuple(b)
        if isless(b,a);a,b=b,a;gamma=-gamma;end
        edges[(a,b)]=get(edges,(a,b),0.)+gamma
    end
    offset=0
    for surface in system.surfaces
        for panel in surface
            gamma=system.Γ[offset+=1];a=panel.rtl;b=panel.rtr;c=panel.rbr;d=panel.rbl
            edge(a,b,gamma);edge(b,c,gamma);edge(c,d,gamma);edge(d,a,gamma)
        end
    end
    for (k,g) in enumerate(grids)
        gamma=strengths[k];ns=length(gamma)
        for j in 1:ns;edge(g[:,1,j],g[:,1,j+1],gamma[j]);end
        for j in 1:ns+1
            strength=(j>1 ? gamma[j-1] : 0.)-(j<=ns ? gamma[j] : 0.)
            for i in 1:size(g,2)-1;edge(g[:,i,j],g[:,i+1,j],strength);end
            key=Tuple(g[:,end,j]);tails[key]=get(tails,key,0.)+strength
        end
    end
    segments=[(VortexLattice.SVector(a),VortexLattice.SVector(b),v) for ((a,b),v) in edges if v!=0]
    rays=[(VortexLattice.SVector(a),v) for (a,v) in tails if v!=0]
    return segments,rays
end
function aerodynamic_shared_wake!(grids,scale)
    groups=Dict{NTuple{3,Int},Vector{Tuple{Int,Int}}}()
    for (k,g) in enumerate(grids),j in axes(g,3)
        key=Tuple(round.(Int,g[:,1,j]./(1e-9*scale)))
        push!(get!(()->Tuple{Int,Int}[],groups,key),(k,j))
    end
    for group in values(groups)
        length(group)>1||continue
        line=sum(grids[k][:,:,j] for (k,j) in group)/length(group)
        for (k,j) in group;grids[k][:,:,j].=line;end
    end
end
function aerodynamic_wake_targets(system,grids,strengths,known,speed,core)
    targets=deepcopy(grids);alignment=0.;displacement=0.
    segments,rays=aerodynamic_wake_filaments(system,grids,strengths)
    for (k,g) in enumerate(grids),j in axes(g,3),i in 1:size(g,2)-1
        point=VortexLattice.SVector{3}((g[:,i,j]+g[:,i+1,j])/2)
        velocity=VortexLattice.SVector(speed,0.,0.)+known(point)
        for (a,b,gamma) in segments;velocity+=aerodynamic_core_segment(point,a,b,gamma,core);end
        for (a,gamma) in rays;velocity+=aerodynamic_core_tail(point,a,gamma,core);end
        all(isfinite,velocity)&&velocity[1]>.05speed||throw(ArgumentError(
            "Free-wake convection reverses or becomes singular; reduce incidence/rates, increase vortex core, or shorten the relaxed wake"))
        delta=g[:,i+1,j]-g[:,i,j];dx=delta[1];direction=velocity/velocity[1]
        targets[k][:,i+1,j].=targets[k][:,i,j].+dx.*direction
        alignment=max(alignment,norm(cross(delta,velocity))/(norm(delta)*norm(velocity)))
    end
    for (g,t) in zip(grids,targets),j in axes(g,3),i in axes(g,2)
        displacement=max(displacement,norm(t[:,i,j]-g[:,i,j]))
    end
    return targets,alignment,displacement
end

# Limited-memory type-II Anderson step (Walker & Ni, SIAM JNA 2011).
# Regularized least squares, bounded extrapolation and explicit history restart
# affect only iteration speed. Physical residuals below remain the stop test.
function aerodynamic_anderson_step!(states,residuals,x,f,beta;depth=6)
    push!(states,copy(x));push!(residuals,copy(f))
    if length(states)>depth+1;popfirst!(states);popfirst!(residuals);end
    step=beta.*f;m=length(states)-1
    if m>0
        dX=hcat([states[j+1]-states[j] for j in 1:m]...)
        dF=hcat([residuals[j+1]-residuals[j] for j in 1:m]...)
        regularization=max(norm(dF)*1e-8,1e-14)
        coefficients=vcat(dF,regularization*Matrix{Float64}(I,m,m))\vcat(f,zeros(m))
        if all(isfinite,coefficients)&&norm(coefficients)<1e4
            candidate=step-(dX+beta*dF)*coefficients
            bound=5maximum(abs,f)
            if all(isfinite,candidate)&&bound>0
                step=candidate.*min(1.,bound/max(maximum(abs,candidate),eps()))
            end
        end
    end
    step
end

function aerodynamic_free_wake!(system,ref,fs,known,s,w,forward,inverse,origin;
    seed=nothing,frozen=false,progress=(stage,done,total)->nothing)
    core=s["wake_core"]*w.mac
    grids=aerodynamic_wake_geometry(system,s,w,forward,origin,seed)
    frozen||aerodynamic_shared_wake!(grids,w.mac)
    closed=similar(system.AIC)
    VortexLattice.influence_coefficients!(closed,system.surfaces;symmetric=system.symmetric,
        surface_id=system.surface_id,trailing_vortices=falses(length(system.surfaces)))
    empty_wakes=[Matrix{VortexLattice.WakePanel{Float64}}(undef,0,size(p,2)) for p in system.surfaces]
    rhs=similar(system.w)
    VortexLattice.normal_velocity!(rhs,system.surfaces,empty_wakes,ref,fs;
        additional_velocity=known,Vcp=nothing,symmetric=system.symmetric,
        nwake=zeros(Int,length(empty_wakes)),surface_id=system.surface_id,
        wake_finite_core=falses(length(empty_wakes)),trailing_vortices=trues(length(empty_wakes)),xhat=system.xhat[])
    history=Any[];previous=copy(system.Γ);converged=false;strengths=Vector{Float64}[]
    states=Vector{Float64}[];residuals=Vector{Float64}[];damping=s["wake_relaxation"];last_residual=Inf
    for iteration in 1:(frozen ? 1 : s["wake_iterations"])
        progress("Relaxing free wake: iteration $iteration / $(s["wake_iterations"])",iteration-1,s["wake_iterations"])
        wakes,strengths=aerodynamic_coupled_wake!(system,grids,closed,rhs,core)
        frozen&&break
        targets,alignment,delta=aerodynamic_wake_targets(system,grids,strengths,known,s["speed"],core)
        circulation=maximum(abs,system.Γ-previous)/max(maximum(abs,system.Γ),s["speed"]*w.mac*1e-6)
        displacement=delta/(s["wake_length"]*w.span)
        residual=max(alignment,displacement,circulation)
        progress("Free wake iteration $iteration: residual $(round(residual;sigdigits=4)) / $(s["wake_tolerance"]) (tangent $(round(alignment;sigdigits=3)), displacement $(round(displacement;sigdigits=3)), circulation $(round(circulation;sigdigits=3)))",iteration,s["wake_iterations"])
        push!(history,Dict("iteration"=>iteration,"alignment"=>alignment,
            "displacement"=>displacement,"circulation_change"=>circulation,"residual"=>residual,"relaxation"=>damping))
        if residual<=s["wake_tolerance"];converged=true;break;end
        iteration==s["wake_iterations"]&&throw(ArgumentError(
            "Free wake did not converge after $iteration iterations (residual $(round(residual;sigdigits=4)), tolerance $(s["wake_tolerance"])). Increase iterations, reduce relaxation, or refine wake length/resolution/core; previous results are retained."))
        previous.=system.Γ
        if get(s,"wake_acceleration","none")=="anderson"
            if residual>1.5last_residual
                empty!(states);empty!(residuals);damping=max(.01,damping/2)
            end
            x=vcat(vec.(grids)...);f=vcat([vec(target-g) for (g,target) in zip(grids,targets)]...)
            step=aerodynamic_anderson_step!(states,residuals,x,f,damping)
            offset=0
            for g in grids
                n=length(g);g.+=reshape(view(step,offset+1:offset+n),size(g));offset+=n
            end
        else
            for (g,target) in zip(grids,targets);g.+=damping.*(target.-g);end
        end
        last_residual=residual
        aerodynamic_shared_wake!(grids,w.mac)
    end
    system.wake_finite_core.=false
    VortexLattice.near_field_forces!(system.properties,system.surfaces,system.wakes,ref,fs,system.Γ;
        dΓdt=nothing,additional_velocity=known,Vh=nothing,Vv=nothing,symmetric=system.symmetric,
        nwake=system.nwake,surface_id=system.surface_id,wake_finite_core=system.wake_finite_core,
        wake_shedding_locations=nothing,trailing_vortices=system.trailing_vortices,xhat=system.xhat[])
    system.near_field_analysis[]=true;system.derivatives[]=false
    physical(v)=collect(inverse(Tuple(v)).+origin)
    sheets=[Dict("patch"=>k,"lines"=>[[physical(g[:,i,j]) for i in axes(g,2)] for j in axes(g,3)],
        "circulation_m2_s"=>strengths[k]) for (k,g) in enumerate(grids)]
    return Dict("model"=>"relaxed","converged"=>converged,"frozen"=>frozen,
        "iterations"=>length(history),"residual"=>isempty(history) ? nothing : history[end]["residual"],
        "tolerance"=>s["wake_tolerance"],"length_m"=>s["wake_length"]*w.span,"rows"=>s["wake_rows"],
        "trefftz"=>aerodynamic_relaxed_trefftz(grids,strengths,s["speed"],w.area),
        "core_radius_m"=>core,"relaxation"=>s["wake_relaxation"],"acceleration"=>get(s,"wake_acceleration","none"),"history"=>history,"sheets"=>sheets,
        "method"=>"Steady coupled circulation and midpoint streamline relaxation; incompressible physical space, Rosenhead finite-core convection, fixed trailing-edge attachment and straight semi-infinite far continuation. Not time-accurate UVLM.")
end
