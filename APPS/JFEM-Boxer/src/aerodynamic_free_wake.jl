# Steady, circulation-coupled free-wake relaxation in incompressible flow.
# Each wake strip carries its CURRENT trailing-edge circulation. Wake columns
# enter the bound-system AIC, rather than treating lagged wake strength as RHS.
# Geometry iterates at fixed downstream stations using midpoint streamline
# tangency and under-relaxation. A straight semi-infinite tail closes each strip.

@inline aerodynamic_wake_point(g,i,j)=VortexLattice.SVector(g[1,i,j],g[2,i,j],g[3,i,j])

function aerodynamic_wake_panels(grids, strengths, core)
    [begin
        nw,ns=size(g,2)-1,size(g,3)-1
        [VortexLattice.WakePanel(aerodynamic_wake_point(g,i,j),
            aerodynamic_wake_point(g,i,j+1),aerodynamic_wake_point(g,i+1,j),
            aerodynamic_wake_point(g,i+1,j+1),core,strengths[k][j]) for i in 1:nw,j in 1:ns]
    end for (k,g) in enumerate(grids)]
end

function aerodynamic_wake_geometry(system,s,w,forward,origin,seed)
    distance=s["wake_length"]*w.span;rows=s["wake_rows"]
    [begin
        te=VortexLattice.trailing_edge_points(surface)
        vlm_checked_size("Free-wake coordinate grid",3,rows+1,length(te))
        g=zeros(3,rows+1,length(te))
        if seed===nothing
            # Quadratic grading resolves the near-wake turn behind deflected
            # controls while retaining the requested total length and row count.
            # Every shared TE vertex gets the same station offsets.
            for j in eachindex(te),i in 0:rows
                g[:,i+1,j].=te[j].+VortexLattice.SVector(distance*(i/rows)^2,0.,0.)
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

# Use one finite-core line integral in the body boundary condition, wake
# convection and load recovery. The last bound span edge and first wake span
# edge cancel analytically; only longitudinal wake filaments remain. Mixing
# the dependency's endpoint core with Rosenhead convection otherwise violates
# the solved body boundary condition near a closely spaced control surface.
function aerodynamic_edge_key(a,b)
    a,b=Tuple(a),Tuple(b)
    isless(b,a) ? (b,a) : (a,b)
end

# Bound-vortex regularization must remain small relative to its discretization.
# For a collocation point whose perpendicular projection lies inside the edge,
# the 0.05 distance ratio gives about 0.25% attenuation in the local infinite-line
# estimate; this is not a bound for projections beyond an endpoint. A shared edge uses
# the minimum radius of all incident panels, so circulation cancellation and
# the body/convective/force velocity fields remain identical. The separately
# specified wake core is retained on wake filaments and caps this small radius.
function aerodynamic_bound_core_map(system;fraction=.05)
    fraction>0&&isfinite(fraction)||throw(ArgumentError("Bound-core distance fraction must be positive and finite"))
    T=NTuple{3,Float64};cores=Dict{Tuple{T,T},Float64}()
    for surface in system.surfaces,p in surface
        x=VortexLattice.controlpoint(p)
        for (a,b) in ((p.rtl,p.rtr),(p.rtr,p.rbr),(p.rbr,p.rbl),(p.rbl,p.rtl))
            edge=b-a;length2=sum(abs2,edge)
            length2>0||throw(ArgumentError("Collapsed bound-vortex edge"))
            distance=norm(x-(a+clamp(dot(x-a,edge)/length2,0.,1.)*edge))
            radius=min(.5sqrt(length2),fraction*distance)
            radius>0||throw(ArgumentError("A collocation point lies on a bound-vortex edge"))
            key=aerodynamic_edge_key(a,b);cores[key]=min(get(cores,key,Inf),radius)
        end
    end
    cores
end

function aerodynamic_bound_influence!(closed,system,core;bound_fraction=.05,bound_cores=nothing)
    cores=bound_cores===nothing ? aerodynamic_bound_core_map(system;fraction=bound_fraction) : bound_cores
    edgecore(a,b)=min(core,cores[aerodynamic_edge_key(a,b)])
    col=0
    for surface in system.surfaces,j in axes(surface,2),i in axes(surface,1)
        p=surface[i,j];col+=1;row=0
        ctop=edgecore(p.rtl,p.rtr);cright=edgecore(p.rtr,p.rbr)
        cleft=edgecore(p.rbl,p.rtl);cbottom=edgecore(p.rbr,p.rbl)
        for receiving in system.surfaces,q in receiving
            row+=1;x=VortexLattice.controlpoint(q)
            v=aerodynamic_core_segment(x,p.rtl,p.rtr,1.,ctop)+
                aerodynamic_core_segment(x,p.rtr,p.rbr,1.,cright)+
                aerodynamic_core_segment(x,p.rbl,p.rtl,1.,cleft)
            i<size(surface,1)&&(v+=aerodynamic_core_segment(x,p.rbr,p.rbl,1.,cbottom))
            closed[row,col]=dot(v,VortexLattice.normal(q))
        end
    end
    closed
end

function aerodynamic_bound_core_range(system,core;bound_cores=nothing)
    cores=bound_cores===nothing ? aerodynamic_bound_core_map(system) : bound_cores;used=Float64[]
    for surface in system.surfaces,j in axes(surface,2),i in axes(surface,1)
        p=surface[i,j]
        for (a,b) in ((p.rtl,p.rtr),(p.rtr,p.rbr),(p.rbl,p.rtl))
            push!(used,min(core,cores[aerodynamic_edge_key(a,b)]))
        end
        i<size(surface,1)&&push!(used,min(core,cores[aerodynamic_edge_key(p.rbr,p.rbl)]))
    end
    collect(extrema(used))
end

function aerodynamic_coupled_wake!(system,grids,closed,rhs,core;bound_data=nothing,threaded=false)
    system.AIC.=closed
    receivers=bound_data===nothing ? [(VortexLattice.controlpoint(p),VortexLattice.normal(p)) for surface in system.surfaces for p in surface] : bound_data.receivers
    columns=bound_data===nothing ? aerodynamic_wake_columns(system) : bound_data.columns
    nodes_by_patch=[[aerodynamic_wake_point(g,i,j) for i in axes(g,2),j in axes(g,3)] for g in grids]
    function column(index)
        k,j,col=columns[index];nodes=nodes_by_patch[k]
        for (row,(x,normal)) in enumerate(receivers)
            velocity=zero(x)
            for i in 1:size(nodes,1)-1
                velocity-=aerodynamic_core_segment(x,nodes[i,j],nodes[i+1,j],1.,core)
                velocity+=aerodynamic_core_segment(x,nodes[i,j+1],nodes[i+1,j+1],1.,core)
            end
            velocity-=aerodynamic_core_tail(x,nodes[end,j],1.,core)
            velocity+=aerodynamic_core_tail(x,nodes[end,j+1],1.,core)
            system.AIC[row,col]+=dot(velocity,normal)
        end
    end
    # Wake columns are disjoint. Keep each receiving point's segment sum in
    # its original order; only sufficiently large column sets use threads.
    work=length(receivers)*sum((size(g,2)-1)*(size(g,3)-1) for g in grids)
    if threaded&&Threads.nthreads()>1&&work>=32768
        Threads.@threads for index in eachindex(columns);column(index);end
    else
        for index in eachindex(columns);column(index);end
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
    if iszero(core)
        n1=norm(r1);n2=norm(r2);den=n1*n2+dot(r1,r2)
        n1>0&&n2>0&&den>0||return zero(point)
        return gamma/(4pi)*(1/n1+1/n2)*v/den
    end
    den=sum(abs2,v)+core^2*sum(abs2,edge)
    den>0||return zero(point)
    gamma/(4pi)*sum(edge.*(r1/sqrt(sum(abs2,r1)+core^2)-r2/sqrt(sum(abs2,r2)+core^2)))/den*v
end
function aerodynamic_core_tail(point,a,gamma,core)
    r=point-a;perp=r[2]^2+r[3]^2
    gamma/(4pi)*(1+r[1]/sqrt(sum(abs2,r)+core^2))/(perp+core^2)*VortexLattice.SVector(0.,-r[3],r[2])
end
function aerodynamic_wake_columns(system)
    columns=NTuple{3,Int}[];offset=0
    for (k,surface) in enumerate(system.surfaces)
        nc,ns=size(surface)
        for j in 1:ns;push!(columns,(k,j,offset+nc*j));end
        offset+=length(surface)
    end
    columns
end

# Geometry, incidence and core radii are fixed throughout one wake solve.
# Retain incidence order so evaluating a new circulation reproduces the
# original edge cancellation exactly, without rebuilding its dictionaries.
function aerodynamic_bound_filament_data(system;bound_fraction=.05)
    cores=aerodynamic_bound_core_map(system;fraction=bound_fraction)
    T=NTuple{3,Float64}
    function geometry(streamwise)
        edges=Dict{Tuple{T,T},Vector{Tuple{Int,Float64}}}()
        function edge(a,b,index)
            a,b=Tuple(a),Tuple(b);sign=1.
            if isless(b,a);a,b=b,a;sign=-1.;end
            push!(get!(()->Tuple{Int,Float64}[],edges,(a,b)),(index,sign))
        end
        index=0
        for surface in system.surfaces,j in axes(surface,2),i in axes(surface,1)
            p=surface[i,j];index+=1
            streamwise||edge(p.rtl,p.rtr,index)
            edge(p.rtr,p.rbr,index)
            !streamwise&&i<size(surface,1)&&edge(p.rbr,p.rbl,index)
            edge(p.rbl,p.rtl,index)
        end
        [(a=VortexLattice.SVector(a),b=VortexLattice.SVector(b),core=cores[(a,b)],terms=terms) for ((a,b),terms) in edges]
    end
    (;cores,full=geometry(false),streamwise=geometry(true),columns=aerodynamic_wake_columns(system),
        receivers=[(VortexLattice.controlpoint(p),VortexLattice.normal(p)) for surface in system.surfaces for p in surface])
end

function aerodynamic_bound_filaments(system;streamwise=false,bound_fraction=.05,bound_data=nothing)
    if bound_data!==nothing
        geometry=streamwise ? bound_data.streamwise : bound_data.full
        segments=Tuple{VortexLattice.SVector{3,Float64},VortexLattice.SVector{3,Float64},Float64,Float64}[]
        sizehint!(segments,length(geometry))
        for e in geometry
            strength=0.
            for (index,sign) in e.terms;strength+=sign*system.Γ[index];end
            iszero(strength)||push!(segments,(e.a,e.b,strength,e.core))
        end
        return segments
    end
    cores=aerodynamic_bound_core_map(system;fraction=bound_fraction)
    T=NTuple{3,Float64};edges=Dict{Tuple{T,T},Float64}()
    function edge(a,b,gamma)
        a,b=Tuple(a),Tuple(b)
        if isless(b,a);a,b=b,a;gamma=-gamma;end
        edges[(a,b)]=get(edges,(a,b),0.)+gamma
    end
    offset=0
    for surface in system.surfaces
        for j in axes(surface,2),i in axes(surface,1)
            panel=surface[i,j]
            gamma=system.Γ[offset+=1];a=panel.rtl;b=panel.rtr;c=panel.rbr;d=panel.rbl
            streamwise||edge(a,b,gamma)
            edge(b,c,gamma)
            !streamwise&&i<size(surface,1)&&edge(c,d,gamma)
            edge(d,a,gamma)
        end
    end
    [(VortexLattice.SVector(a),VortexLattice.SVector(b),v,cores[(a,b)]) for ((a,b),v) in edges if v!=0]
end

function aerodynamic_wake_filaments(system,grids,strengths;streamwise=false,bound_fraction=.05,bound_data=nothing)
    segments=aerodynamic_bound_filaments(system;streamwise,bound_fraction,bound_data)
    T=NTuple{3,Float64};edges=Dict{Tuple{T,T},Float64}();tails=Dict{T,Float64}()
    function edge(a,b,gamma)
        a,b=Tuple(a),Tuple(b)
        if isless(b,a);a,b=b,a;gamma=-gamma;end
        edges[(a,b)]=get(edges,(a,b),0.)+gamma
    end
    for (k,g) in enumerate(grids)
        gamma=strengths[k];ns=length(gamma)
        for j in 1:ns+1
            strength=(j>1 ? gamma[j-1] : 0.)-(j<=ns ? gamma[j] : 0.)
            for i in 1:size(g,2)-1;edge(aerodynamic_wake_point(g,i,j),aerodynamic_wake_point(g,i+1,j),strength);end
            key=Tuple(aerodynamic_wake_point(g,size(g,2),j));tails[key]=get(tails,key,0.)+strength
        end
    end
    append!(segments,[(VortexLattice.SVector(a),VortexLattice.SVector(b),v,Inf) for ((a,b),v) in edges if v!=0])
    rays=[(VortexLattice.SVector(a),v) for (a,v) in tails if v!=0]
    return segments,rays
end

function aerodynamic_wake_velocity(point,segments,rays,core;host=nothing)
    velocity=zero(point)
    for segment in segments
        a,b,gamma=segment
        if host!==nothing
            ((a==host[1]&&b==host[2])||(a==host[2]&&b==host[1]))&&continue
        end
        radius=length(segment)>3 ? min(core,segment[4]) : core
        velocity+=aerodynamic_core_segment(point,a,b,gamma,radius)
    end
    for (a,gamma) in rays;velocity+=aerodynamic_core_tail(point,a,gamma,core);end
    velocity
end

# Preserve the established Kutta-Joukowski recovery: induced velocity at the
# net spanwise bound vortex, prescribed velocity on chordwise legs (as in AVL
# and VortexLattice). Its induced field is exactly the one used by the AIC and
# streamline update. Omit the merged host edge explicitly at its midpoint.
function aerodynamic_wake_properties!(system,ref,known,grids,strengths,speed,core;bound_fraction=.05,bound_data=nothing,velocity_only=false)
    segments,rays=aerodynamic_wake_filaments(system,grids,strengths;bound_fraction,bound_data)
    streamsegments,streamrays=velocity_only ? (nothing,nothing) : aerodynamic_wake_filaments(system,grids,strengths;streamwise=true,bound_fraction,bound_data)
    aerodynamic_properties_from_field!(system,ref,known,segments,rays,streamsegments,streamrays,speed,core;velocity_only)
end

function aerodynamic_properties_from_field!(system,ref,known,segments,rays,streamsegments,streamrays,speed,core;velocity_only=false)
    prescribed(point)=VortexLattice.SVector(speed,0.,0.)+known(point)
    scale=.5ref.V^2*ref.S;offset=0
    for (k,surface) in enumerate(system.surfaces)
        nc,ns=size(surface)
        for j in 1:ns,i in 1:nc
            index=offset+(j-1)*nc+i;panel=surface[i,j];gamma=system.Γ[index]
            netgamma=gamma-(i>1 ? system.Γ[index-1] : 0.)
            point=VortexLattice.top_center(panel)
            velocity=prescribed(point)+aerodynamic_wake_velocity(point,segments,rays,core;host=(panel.rtl,panel.rtr))
            if velocity_only
                all(isfinite,velocity)||error("Nonfinite finite-core force recovery")
                empty=zero(velocity)
                system.properties[k][i,j]=VortexLattice.PanelProperties{Float64}(gamma/ref.V,velocity/ref.V,empty,empty,empty,empty)
                continue
            end
            streamvelocity=prescribed(point)+aerodynamic_wake_velocity(point,streamsegments,streamrays,core)
            all(isfinite,velocity)&&all(isfinite,streamvelocity)||error("Nonfinite finite-core force recovery")
            cfb=netgamma*cross(velocity,VortexLattice.top_vector(panel))/scale
            cfl=gamma*cross(prescribed(VortexLattice.left_center(panel)),VortexLattice.left_vector(panel))/scale
            cfr=gamma*cross(prescribed(VortexLattice.right_center(panel)),VortexLattice.right_vector(panel))/scale
            system.properties[k][i,j]=VortexLattice.PanelProperties{Float64}(gamma/ref.V,velocity/ref.V,cfb,cfl,cfr,streamvelocity)
        end
        offset+=length(surface)
    end
    system.near_field_analysis[]=!velocity_only;system.derivatives[]=false
end
function aerodynamic_shared_wake!(grids,scale)
    groups=Dict{NTuple{3,Int},Vector{Tuple{Int,Int}}}()
    for (k,g) in enumerate(grids),j in axes(g,3)
        key=aerodynamic_wake_origin_key(g[:,1,j],scale)
        push!(get!(()->Tuple{Int,Int}[],groups,key),(k,j))
    end
    for group in values(groups)
        length(group)>1||continue
        k0,j0=first(group)
        all(grids[k][:,2:end,j]==grids[k0][:,2:end,j0] for (k,j) in group)&&continue
        line=sum(grids[k][:,2:end,j] for (k,j) in group)/length(group)
        for (k,j) in group;grids[k][:,2:end,j].=line;end
    end
end
function aerodynamic_wake_targets(system,grids,strengths,known,speed,core;diagnostics=nothing,local_target=false,threaded=false,bound_data=nothing)
    targets=[copy(g) for g in grids];integrated=[copy(g) for g in grids]
    segments,rays=aerodynamic_wake_filaments(system,grids,strengths;bound_data)
    columns=[(k,j) for (k,g) in enumerate(grids) for j in axes(g,3)]
    # Each worker owns one complete column. Reduce summaries in source order
    # so ties and the first failing filament are deterministic. Generic
    # callbacks stay serial unless the caller explicitly enables threading.
    summaries=Vector{Any}(undef,length(columns))
    function column(k,j)
        g=grids[k]
        local alignment,slope_squared,minimum_vx,worst
        alignment=0.;slope_squared=0.;minimum_vx=Inf;worst=nothing
        for i in 1:size(g,2)-1
            point=(aerodynamic_wake_point(g,i,j)+aerodynamic_wake_point(g,i+1,j))/2
            velocity=VortexLattice.SVector(speed,0.,0.)+known(point)+aerodynamic_wake_velocity(point,segments,rays,core)
            minimum_vx=min(minimum_vx,velocity[1]/speed)
            if !all(isfinite,velocity)||velocity[1]<=.05speed
                start=Tuple(g[:,i,j]);finish=Tuple(g[:,i+1,j])
                host(a,b)=(Tuple(a)==start&&Tuple(b)==finish)||(Tuple(b)==start&&Tuple(a)==finish)
                distance=minimum(norm(point-(a+clamp(dot(point-a,b-a)/max(sum(abs2,b-a),eps()),0.,1.)*(b-a))) for (a,b,_) in segments if !host(a,b);init=Inf)
                reason=!all(isfinite,velocity) ? "is nonfinite" : velocity[1]<=0 ? "reverses downstream direction" : "is too slow in the downstream direction for fixed-X marching"
                throw(ArgumentError("Free-wake convection $reason: patch $k, filament $j, row $i, streamwise velocity/V=$(round(velocity[1]/speed;sigdigits=5)) (required >0.05), nearest other filament distance/core=$(round(distance/core;sigdigits=4)). Refine wake spacing/core or check the incidence/control attached-flow assumptions."))
            end
            delta=aerodynamic_wake_point(g,i+1,j)-aerodynamic_wake_point(g,i,j);dx=delta[1];direction=velocity/velocity[1]
            targets[k][:,i+1,j].=aerodynamic_wake_point(g,i,j).+dx.*direction
            integrated[k][:,i+1,j].=aerodynamic_wake_point(integrated[k],i,j).+dx.*direction
            slope_squared+=sum(abs2,aerodynamic_wake_point(targets[k],i+1,j)-aerodynamic_wake_point(g,i+1,j))/dx^2
            defect=norm(delta/norm(delta)-velocity/norm(velocity))
            if defect>alignment
                alignment=defect
                worst=Dict("patch"=>k,"filament"=>j,"row"=>i,"rows"=>size(g,2)-1,
                    "streamwise_step_over_core"=>dx/core,"point"=>collect(point),
                    "velocity_over_V"=>collect(velocity/speed),"segment_direction"=>collect(delta/norm(delta)))
            end
        end
        (;alignment,slope_squared,minimum_vx,worst,count=size(g,2)-1)
    end
    function work(index)
        summaries[index]=try;(ok=true,value=column(columns[index]...),error=nothing);catch error;(ok=false,value=nothing,error);end
    end
    if threaded&&Threads.nthreads()>1
        Threads.@threads for index in eachindex(columns);work(index);end
    else
        for index in eachindex(columns)
            k,j=columns[index]
            summaries[index]=(ok=true,value=column(k,j),error=nothing)
        end
    end
    alignment=0.;slope_squared=0.;count=0;minimum_vx=Inf;worst=nothing
    for result in summaries
        result.ok||throw(result.error)
        summary=result.value
        minimum_vx=min(minimum_vx,summary.minimum_vx)
        slope_squared+=summary.slope_squared;count+=summary.count
        if summary.alignment>alignment;alignment=summary.alignment;worst=summary.worst;end
    end
    displacement=maximum(norm(aerodynamic_wake_point(t,i,j)-aerodynamic_wake_point(g,i,j)) for (g,t) in zip(grids,integrated) for j in axes(g,3) for i in axes(g,2))
    if diagnostics!==nothing
        diagnostics["minimum_streamwise_velocity_over_V"]=min(get(diagnostics,"minimum_streamwise_velocity_over_V",Inf),minimum_vx)
        diagnostics["local_slope_rms"]=sqrt(slope_squared/count)
        worst===nothing||(diagnostics["worst_tangent"]=worst)
    end
    local_target ? targets : integrated,alignment,displacement
end

# The difference of successive integrated defects is the local midpoint
# streamline defect. Both vanish at exactly the same wake, but a near-TE
# error in the integrated proposal otherwise moves every downstream node.
function aerodynamic_wake_local_defect(grids,integrated)
    defects=[zeros(size(g)) for g in grids]
    for (g,t,d) in zip(grids,integrated,defects),j in axes(g,3),i in 2:size(g,2)
        d[:,i,j].=(t[:,i,j]-g[:,i,j])-(t[:,i-1,j]-g[:,i-1,j])
    end
    vcat(vec.(defects)...)
end

function aerodynamic_wake_defect_location(diagnostics)
    hit=get(diagnostics,"worst_tangent",nothing)
    hit===nothing&&return ""
    endpoint=hit["row"]==hit["rows"] ? " (terminal finite-wake segment)" : ""
    " Largest tangency defect: wake patch $(hit["patch"]), filament $(hit["filament"]), row $(hit["row"])/$(hit["rows"])$endpoint; streamwise segment length/core=$(round(hit["streamwise_step_over_core"];sigdigits=4))."
end

# Limited-memory type-II Anderson step (Walker & Ni, SIAM JNA 2011).
# Regularized least squares, bounded extrapolation and explicit history restart
# affect only iteration speed. Physical residuals below remain the stop test.
function aerodynamic_anderson_step!(states,residuals,x,f,beta;depth=6,weights=nothing)
    push!(states,copy(x));push!(residuals,copy(f))
    if length(states)>depth+1;popfirst!(states);popfirst!(residuals);end
    step=beta.*f;m=length(states)-1
    if m>0
        dX=hcat([states[j+1]-states[j] for j in 1:m]...)
        dF=hcat([residuals[j+1]-residuals[j] for j in 1:m]...)
        fit=weights===nothing ? dF : weights.*dF
        rhs=weights===nothing ? f : weights.*f
        regularization=max(norm(fit)*1e-8,1e-14)
        coefficients=vcat(fit,regularization*Matrix{Float64}(I,m,m))\vcat(rhs,zeros(m))
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

# A numerical trust region; the unmodified tangent/target residual still
# determines convergence. Streamwise stations and the trailing edge stay fixed.
function aerodynamic_wake_trust_step(grids,step,core)
    bounded=copy(step);offset=0
    for g in grids
        n=length(g);d=reshape(view(bounded,offset+1:offset+n),size(g));offset+=n
        d[:,1,:].=0.;d[1,:,:].=0.
        for j in axes(g,3),i in 2:size(g,2)
            dx=g[1,i,j]-g[1,i-1,j]
            i<size(g,2)&&(dx=min(dx,g[1,i+1,j]-g[1,i,j]))
            radius=max(2core,.25dx);motion=norm(view(d,:,i,j))
            motion>radius&&(d[:,i,j].*=radius/motion)
        end
    end
    bounded
end

function aerodynamic_wake_collision_message(report)
    message="Wake/body intersection: $(report.count) wake/body crossings"
    isempty(report.samples)&&return message
    hit=first(report.samples)
    location=hit.tail ? "tail" : "row $(hit.row)"
    message*"; wake patch $(hit.patch), filament $(hit.filament), $location crosses body patch $(hit.body_patch), chord $(hit.chord), strip $(hit.strip)"
end

function aerodynamic_free_wake!(system,ref,fs,known,s,w,forward,inverse,origin;
    seed=nothing,frozen=false,body_grids=nothing,threaded=false,velocity_only=false,progress=(stage,done,total)->nothing)
    core=s["wake_core"]*w.mac
    grids=aerodynamic_wake_geometry(system,s,w,forward,origin,seed)
    frozen||aerodynamic_shared_wake!(grids,w.mac)
    bodies=body_grids===nothing ? nothing : aerodynamic_wake_body_triangles(body_grids)
    initialization=Dict{String,Any}("method"=>seed===nothing ? "straight" : "retained wake")
    if bodies!==nothing&&seed===nothing&&!frozen
        initialization=Dict{String,Any}(String(k)=>v for (k,v) in pairs(aerodynamic_seed_clear_wake!(grids,bodies,w.mac;core,side=1,span_smoothing=true)))
        initialization["method"]="collision-aware body clearance"
        progress("Initial wake/body clearance: repaired $(initialization["initial_intersections"]) intersections; $(initialization["remaining_intersections"]) remain",0,s["wake_iterations"])
    end
    function check_clearance(grids)
        bodies===nothing&&return 0
        report=aerodynamic_wake_collisions(grids,bodies;scale=w.mac)
        report.count==0||throw(ArgumentError(aerodynamic_wake_collision_message(report)))
        report.count
    end
    bound_data=aerodynamic_bound_filament_data(system)
    closed=similar(system.AIC)
    aerodynamic_bound_influence!(closed,system,core;bound_cores=bound_data.cores)
    empty_wakes=[Matrix{VortexLattice.WakePanel{Float64}}(undef,0,size(p,2)) for p in system.surfaces]
    rhs=similar(system.w)
    VortexLattice.normal_velocity!(rhs,system.surfaces,empty_wakes,ref,fs;
        additional_velocity=known,Vcp=nothing,symmetric=system.symmetric,
        nwake=zeros(Int,length(empty_wakes)),surface_id=system.surface_id,
        wake_finite_core=falses(length(empty_wakes)),trailing_vortices=trues(length(empty_wakes)),xhat=system.xhat[])
    history=Any[];previous=copy(system.Γ);converged=false;strengths=Vector{Float64}[]
    states=Vector{Float64}[];residuals=Vector{Float64}[];damping=s["wake_relaxation"]
    rejected=0;wake_length=s["wake_length"]*w.span;trial_failures=String[]
    function evaluate(grids)
        check_clearance(grids)
        _,strengths=aerodynamic_coupled_wake!(system,grids,closed,rhs,core;bound_data,threaded)
        diagnostics=Dict{String,Any}()
        targets,alignment,delta=aerodynamic_wake_targets(system,grids,strengths,known,s["speed"],core;diagnostics,threaded,bound_data)
        (;targets,alignment,displacement=delta/wake_length,strengths,gamma=copy(system.Γ),diagnostics)
    end
    if frozen
        check_clearance(grids)
        _,strengths=aerodynamic_coupled_wake!(system,grids,closed,rhs,core;bound_data,threaded)
    else
        current=evaluate(grids)
        for iteration in 1:s["wake_iterations"]
            circulation=maximum(abs,current.gamma-previous)/max(maximum(abs,current.gamma),s["speed"]*w.mac*1e-6)
            equation_residual=maximum(abs,system.AIC*system.Γ-rhs)/s["speed"]
            residual=max(current.alignment,current.displacement,circulation,equation_residual)
            progress("Free wake iteration $iteration: residual $(round(residual;sigdigits=4)) / $(s["wake_tolerance"]) (tangent $(round(current.alignment;sigdigits=3)), displacement $(round(current.displacement;sigdigits=3)), circulation $(round(circulation;sigdigits=3))); $rejected rejected trial(s)",iteration,s["wake_iterations"])
            push!(history,Dict("iteration"=>iteration,"alignment"=>current.alignment,
                "displacement"=>current.displacement,"circulation_change"=>circulation,"equation_residual_over_V"=>equation_residual,"residual"=>residual,"relaxation"=>damping,"rejected_trials"=>rejected,
                "minimum_streamwise_velocity_over_V"=>current.diagnostics["minimum_streamwise_velocity_over_V"],
                "local_slope_rms"=>current.diagnostics["local_slope_rms"],
                "worst_tangent"=>get(current.diagnostics,"worst_tangent",nothing),
                "maximum_abs_circulation_over_VMAC"=>maximum(abs,current.gamma)/(s["speed"]*w.mac)))
            strengths=current.strengths
            if residual<=s["wake_tolerance"];converged=true;break;end
            # An exact coupled circulation solve may differ from the initial
            # straight-wake guess even when no geometric update is necessary.
            # Confirm the unchanged state on the next iteration instead of
            # demanding a numerically meaningless coordinate displacement.
            if iteration<s["wake_iterations"]&&max(current.alignment,current.displacement,equation_residual)<=s["wake_tolerance"]
                previous=current.gamma
                continue
            end
            iteration==s["wake_iterations"]&&throw(ArgumentError(
                "Free wake did not converge after $iteration iterations (residual $(round(residual;sigdigits=4)), tolerance $(s["wake_tolerance"]))."*
                aerodynamic_wake_defect_location(current.diagnostics)*
                " Increase wake iterations or refine the wake resolution/core; previous results are retained."))
            x=vcat(vec.(grids)...);f=vcat([vec(target-g) for (g,target) in zip(grids,current.targets)]...)
            accelerated=get(s,"wake_acceleration","none")=="anderson"
            step=accelerated ? aerodynamic_anderson_step!(states,residuals,x,f,damping) : damping.*f
            step=aerodynamic_wake_trust_step(grids,step,core)
            recent=history[max(1,end-4):end]
            ceiling=1.02maximum(h["local_slope_rms"] for h in recent)
            accepted=false;last_rejection="No admissible trial was evaluated"
            # Ten halvings are insufficient near a tightly rolled-up filament:
            # an admissible neighborhood may be smaller than 1/512 of a trust
            # step. Search to numerical resolution, then try a local proposal
            # before declaring the retained physical state inaccessible.
            directions=accelerated ? 3 : 2
            minimum_motion=64eps(max(1.,maximum(maximum(abs,g) for g in grids)))
            for fallback in 1:directions
                if fallback>1
                    empty!(states);empty!(residuals)
                    local_fallback=fallback==directions
                    proposal=local_fallback ? aerodynamic_wake_local_defect(grids,current.targets) : f
                    step=aerodynamic_wake_trust_step(grids,damping.*proposal,core)
                end
                fraction=1.
                for attempt in 1:32
                    if fraction*maximum(abs,step)<=minimum_motion
                        last_rejection="Trial motion reached floating-point resolution before an admissible update was found"
                        break
                    end
                    trial=deepcopy(grids);offset=0
                    for g in trial
                        n=length(g);g.+=fraction.*reshape(view(step,offset+1:offset+n),size(g));offset+=n
                    end
                    aerodynamic_shared_wake!(trial,w.mac)
                    candidate=nothing
                    try
                        candidate=evaluate(trial)
                    catch error
                        recoverable=error isa SingularException||error isa ArgumentError&&(startswith(error.msg,"Free-wake convection ")||occursin("Wake/body intersection",error.msg))||error isa ErrorException&&error.msg=="Nonfinite circulation in coupled free-wake solve"
                        recoverable||rethrow()
                        last_rejection=sprint(showerror,error)
                        push!(trial_failures,last_rejection)
                    end
                    if candidate!==nothing&&candidate.diagnostics["local_slope_rms"]<=ceiling
                        history[end]["accepted_step_fraction"]=fraction
                        history[end]["accepted_direction"]=fallback
                        previous=current.gamma;grids=trial;current=candidate;accepted=true
                        # Secants use the actual accepted states. A shortened
                        # step still supplies valid information; discarding it
                        # prevents Anderson from learning stiff flow gradients.
                        if fallback>1;empty!(states);empty!(residuals);end
                        break
                    end
                    if candidate!==nothing
                        last_rejection="Trial slope residual $(round(candidate.diagnostics["local_slope_rms"];sigdigits=4)) exceeds the retained-state safeguard $(round(ceiling;sigdigits=4))"
                    end
                    rejected+=1
                    if attempt in (1,4,8,16,24,32)
                        progress("Safeguarding free wake: retrying iteration $(iteration+1), direction $fallback / $directions, trial $attempt, step $(round(fraction/2;sigdigits=3)); retained last valid wake",iteration,s["wake_iterations"])
                    end
                    fraction/=2
                end
                accepted&&break
            end
            if !accepted
                aerodynamic_coupled_wake!(system,grids,closed,rhs,core;bound_data,threaded)
                throw(ArgumentError("Free-wake update could not find a valid step at iteration $iteration (retained residual $(round(residual;sigdigits=4)), tolerance $(s["wake_tolerance"])). Last rejected trial: $last_rejection."*
                    aerodynamic_wake_defect_location(current.diagnostics)*
                    " The last valid wake and previous results were retained; refine the indicated wake region before rerunning."))
            end
        end
    end
    system.wake_finite_core.=true
    aerodynamic_wake_properties!(system,ref,known,grids,strengths,s["speed"],core;bound_data,velocity_only)
    physical(v)=collect(inverse(Tuple(v)).+origin)
    sheets=[Dict("patch"=>k,"lines"=>[[physical(g[:,i,j]) for i in axes(g,2)] for j in axes(g,3)],
        "circulation_m2_s"=>strengths[k]) for (k,g) in enumerate(grids)]
    return Dict("model"=>"relaxed","converged"=>converged,"frozen"=>frozen,
        "iterations"=>length(history),"residual"=>isempty(history) ? nothing : history[end]["residual"],
        "tolerance"=>s["wake_tolerance"],"length_m"=>s["wake_length"]*w.span,"rows"=>s["wake_rows"],
        "trefftz"=>aerodynamic_relaxed_trefftz(grids,strengths,s["speed"],w.area),
        "core_radius_m"=>core,"rejected_trials"=>rejected,"trial_failures"=>trial_failures,"initialization"=>initialization,"final_body_intersections"=>check_clearance(grids),"streamwise_grading"=>"quadratic","first_station_distance_m"=>minimum(g[1,2,j]-g[1,1,j] for g in grids for j in axes(g,3)),"relaxation"=>s["wake_relaxation"],"acceleration"=>get(s,"wake_acceleration","none"),"history"=>history,"sheets"=>sheets,
        "bound_core_distance_fraction"=>.05,
        "bound_core_radius_range_m"=>aerodynamic_bound_core_range(system,core;bound_cores=bound_data.cores),
        "core_model"=>"Rosenhead line integrals with a mesh-scale bound core (0.05 of the minimum incident collocation distance, capped by half edge length and wake core) and the requested wake core; identical AIC, convection and force-recovery field",
        "method"=>"Steady coupled circulation and midpoint streamline relaxation; incompressible physical space, consistent Rosenhead finite-core bound/wake field, fixed trailing-edge attachment and straight semi-infinite far continuation. Not time-accurate UVLM.")
end
