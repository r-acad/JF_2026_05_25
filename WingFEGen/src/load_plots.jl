# Spanwise load diagnostics. These are applied-load resultants, not recovered
# shell/beam stresses. All distances use projected global-y semispan.

function plot_polygon_mass(points,normal)
    length(points)>=3||return (0.,AERO_ZERO)
    area=0.;first_moment=zeros(3)
    for i in 2:length(points)-1
        a,b,c=points[1],points[i],points[i+1]
        piece=abs(sum(cross3(b.-a,c.-a).*normal))/2
        area+=piece;first_moment.+=piece.*collect((a.+b.+c)./3)
    end
    return area,area>0 ? Tuple(first_moment./area) : AERO_ZERO
end

function plot_clip_outboard(points,y)
    out=NTuple{3,Float64}[]
    for i in eachindex(points)
        a,b=points[i],points[mod1(i+1,length(points))];ina=a[2]>=y;inb=b[2]>=y
        ina&&push!(out,a)
        if ina!=inb
            t=(y-a[2])/(b[2]-a[2]);push!(out,a.+t.*(b.-a))
        end
    end
    out
end

function plot_strip(lo,hi,force,origin_moment;slope=(0.,1.,0.))
    (;kind=:strip,lo=Float64(lo),hi=Float64(hi),force,origin_moment,slope)
end

plot_source_bounds(source)=extrema(point[2] for point in source.points)
plot_source_bounds(source::StructuralMassSource)=(source.ymin,source.ymax)
plot_source_offset(source)=get(source,:offset,AERO_ZERO)
plot_source_offset(source::StructuralMassSource)=source.offset
plot_source_shift(source)=get(source,:centroid_shift,AERO_ZERO)
plot_source_shift(source::StructuralMassSource)=source.centroid_shift

function structural_source_moments(source,y,side;include_offsets=true)
    lo,hi=plot_source_bounds(source)
    (y>hi||y==hi&&side!="inboard")&&return 0.,AERO_ZERO
    if y<=lo
        center=include_offsets ? source.center : source.center.-plot_source_offset(source)
        return source.mass,source.mass.*center
    elseif source.kind===:line
        a,b=source.points;a[2]>b[2]&&((a,b)=(b,a))
        point=a.+((y-lo)/(hi-lo)).*(b.-a);center=(point.+b)./2
        include_offsets&&(center=center.+plot_source_offset(source))
        mass=source.mass*(hi-y)/(hi-lo)
        return mass,mass.*center
    end
    area,center=plot_polygon_mass(plot_clip_outboard(source.points,y),source.normal)
    mass=source.mass*area/source.area
    return mass,mass.*(center.+plot_source_shift(source))
end

function distributed_source_resultant(source,y,side,acceleration=AERO_ZERO)
    if source.kind===:strip
        lo,hi=source.lo,source.hi;force,moment=source.force,source.origin_moment
        (y>hi||y==hi&&side!="inboard")&&return AERO_ZERO,AERO_ZERO
        y<=lo&&return force,moment
        fraction=(hi-y)/(hi-lo);f=fraction.*force
        return f,fraction.*moment.+cross3(((y-lo)/2).*source.slope,f)
    end
    mass,first_moment=structural_source_moments(source,y,side)
    return mass.*acceleration,cross3(first_moment,acceleration)
end

const STRUCTURE_CUT_LOCK=ReentrantLock()
const STRUCTURE_CUT_CACHE=Ref{Any}(nothing)

"""Sweep span cuts once: sum untouched outboard sources and clip intersections only."""
function structural_cut_integrals(sources::Vector{StructuralMassSource},ys,events;include_offsets=true)
    lock(STRUCTURE_CUT_LOCK) do
        cache=STRUCTURE_CUT_CACHE[]
        if cache===nothing||cache.sources!==sources
            cache=(sources=sources,entries=Dict{UInt,Any}());STRUCTURE_CUT_CACHE[]=cache
        end
        key=hash((ys,sort!(collect(events)),include_offsets));haskey(cache.entries,key)&&return cache.entries[key]
        order=sortperm(sources;by=s->s.ymin);n=length(order)
        suffix_mass=zeros(n+1);suffix_first=fill(AERO_ZERO,n+1)
        for i in n:-1:1
            source=sources[order[i]]
            suffix_mass[i]=suffix_mass[i+1]+source.mass
            center=include_offsets ? source.center : source.center.-source.offset
            suffix_first[i]=suffix_first[i+1].+source.mass.*center
        end
        masses=Float64[];first_moments=NTuple{3,Float64}[];active=Int[];next=1
        for y in ys
            while next<=n&&sources[order[next]].ymin<=y
                push!(active,order[next]);next+=1
            end
            filter!(i->sources[i].ymax>=y,active)
            for side in (y in events ? ("inboard","outboard") : ("cut",))
                mass=suffix_mass[next];moment=suffix_first[next]
                for i in active
                    piece,first=structural_source_moments(sources[i],y,side;include_offsets)
                    mass+=piece;moment=moment.+first
                end
                push!(masses,mass);push!(first_moments,moment)
            end
        end
        result=(mass=masses,first_moment=first_moments)
        length(cache.entries)>=65&&empty!(cache.entries);cache.entries[key]=result
        return result
    end
end

function aerodynamic_plot_sources(m,loads)
    sources=NamedTuple[];w,p=m.wing,m.params
    if isempty(loads.panels)
        stations=loads.stations
        for (i,s) in enumerate(stations)
            lo=i==1 ? w.root_ref_y : (stations[i-1].position[2]+s.position[2])/2
            hi=i==length(stations) ? w.root_ref_y+w.semispan : (s.position[2]+stations[i+1].position[2])/2
            push!(sources,plot_strip(lo,hi,s.force,s.moment.+cross3(s.position,s.force)))
        end
    else
        for panel in loads.panels
            lo,hi=extrema(c[2] for c in panel.corners)
            a=[c for c in panel.corners if isapprox(c[2],lo;atol=1e-10)];b=[c for c in panel.corners if isapprox(c[2],hi;atol=1e-10)]
            slope=ntuple(k->(sum(c[k] for c in b)/length(b)-sum(c[k] for c in a)/length(a))/(hi-lo),3)
            push!(sources,plot_strip(lo,hi,panel.force,panel.moment.+cross3(panel.position,panel.force);slope))
        end
        torque=Float64(p["loads.torque_y"])*p["loads.load_factor"];shares=station_load_shares(m)
        for (i,s) in enumerate(loads.stations)
            lo=i==1 ? w.root_ref_y : (loads.stations[i-1].position[2]+s.position[2])/2
            hi=i==length(loads.stations) ? w.root_ref_y+w.semispan : (s.position[2]+loads.stations[i+1].position[2])/2
            torque==0||push!(sources,plot_strip(lo,hi,AERO_ZERO,(0.,torque*shares[i],0.);slope=AERO_ZERO))
        end
    end
    sources
end

const FUEL_PLOT_CACHE=Ref{Any}(nothing)

function fuel_plot_sources(m,etas)
    state=fuel_mass_state(m);sources=NamedTuple[];p=m.params;w=m.wing
    acceleration=ntuple(k->FUEL_MASS_GRAVITY*p["loads.load_factor"]*p["loads.fuel_accel_"*("x","y","z")[k]],3)
    all(iszero,acceleration)&&return sources
    lock(FUEL_GEOMETRY_LOCK) do
        cache=FUEL_PLOT_CACHE[]
        if cache===nothing||cache.xyz!==m.xyz
            cache=(xyz=m.xyz,entries=Dict{UInt,Any}());FUEL_PLOT_CACHE[]=cache
        end
        key=hash((etas,acceleration,[k=>v for (k,v) in sort!(collect(p);by=first) if startswith(k,"fuel.")||k=="loads.fuel_percent"]))
        haskey(cache.entries,key)&&return cache.entries[key]
        geometry=fuel_geometry_bays(m);rows=Dict(row["index"]=>row for row in state["bays"])
        for bay in geometry
            row=rows[bay.rib];row["mass_kg"]>0||continue
            bins=NamedTuple[];level=something(row["fill_level_z_m"],Inf)
            for i in 1:length(etas)-1
                moments=bay.integrate_between(etas[i],etas[i+1],level);moments[1]>0||continue
                center=Tuple(collect(bay.origin)+moments[2:4]/moments[1])
                push!(bins,(lo=etas[i],hi=etas[i+1],mass=moments[1]*p["fuel.density"],center=center))
            end
            # Enforce the already integrated bay mass and first moment within
            # quadrature tolerance, preserving its exact CONM2 deck wrench.
            total=sum(bin.mass for bin in bins);total>0||error("Fuel distribution integration lost bay $(bay.rib)")
            center=ntuple(k->sum(bin.mass*bin.center[k] for bin in bins)/total,3)
            shift=Tuple(row["center_of_gravity_m"]).-center
            for bin in bins
                force=(bin.mass*row["mass_kg"]/total).*acceleration
                # Distributed view represents physical fuel mass. The separate
                # exact FE curves show its conservative bay-reference transfer.
                force_center=bin.center.+shift
                push!(sources,plot_strip(w.root_ref_y+w.semispan*bin.lo,w.root_ref_y+w.semispan*bin.hi,force,cross3(force_center,force)))
            end
        end
        length(cache.entries)>=65&&empty!(cache.entries)
        cache.entries[key]=sources
        return sources
    end
end

function plot_point_index(stations)
    sorted=sort(collect(stations);by=s->s.position[2]);n=length(sorted);force=zeros(3,n+1);moment=zeros(3,n+1)
    for i in n:-1:1
        force[:,i].=force[:,i+1].+collect(sorted[i].force)
        moment[:,i].=moment[:,i+1].+collect(sorted[i].moment.+cross3(sorted[i].position,sorted[i].force))
    end
    return (ys=[s.position[2] for s in sorted],force=force,moment=moment)
end

function plot_point_resultant(index,y,side)
    i=side=="inboard" ? searchsortedfirst(index.ys,y) : searchsortedlast(index.ys,y)+1
    return Tuple(index.force[:,i]),Tuple(index.moment[:,i])
end

function plot_resultant_arrays(m,ys,events,evaluate)
    w=m.wing;result=Dict{String,Any}("eta"=>Float64[],"y_m"=>Float64[],"side"=>String[],
        "shear_z_N"=>Float64[],"bending_x_Nm"=>Float64[],"torque_y_Nm"=>Float64[])
    for y in ys,side in (y in events ? ("inboard","outboard") : ("cut",))
        eta=(y-w.root_ref_y)/w.semispan;reference=section_point(w,eta,Float64(m.params["rbe3.ref_xc"]),0.)
        force,origin_moment=evaluate(y,side);moment=origin_moment.-cross3(reference,force)
        push!(result["eta"],eta);push!(result["y_m"],y);push!(result["side"],side)
        push!(result["shear_z_N"],force[3]);push!(result["bending_x_Nm"],moment[1]);push!(result["torque_y_Nm"],moment[2])
    end
    result
end

function spanwise_load_data(m::Model, loads)
    p, w = m.params, m.wing
    q = 0.5 * p["aero.density"] * p["aero.speed"]^2
    eta, ys, widths, chords, lifts = (Float64[] for _ in 1:5)
    lows, highs = Float64[], Float64[]
    if !isempty(loads.panels)
        strips = Dict{Tuple{Float64,Float64},NTuple{3,Float64}}()
        for panel in loads.panels
            bounds = extrema(c[2] for c in panel.corners)
            strips[bounds] = get(strips, bounds, AERO_ZERO) .+ panel.force
        end
        alpha = deg2rad(p["aero.alpha"])
        for ((lo,hi), force) in sort!(collect(strips); by=first)
            center = (lo+hi)/2; e = (center-w.root_ref_y)/w.semispan
            push!(eta,e); push!(ys,center); push!(widths,hi-lo)
            push!(chords,chord(w,e)); push!(lifts,-sin(alpha)*force[1]+cos(alpha)*force[3])
            push!(lows,(lo-w.root_ref_y)/w.semispan); push!(highs,(hi-w.root_ref_y)/w.semispan)
        end
        coefficient_note = "VLM wind-axis lift: (-sin(alpha)*Fx + cos(alpha)*Fz)/(q*projected strip width). Includes the dimensionless load multiplier; differs from the unscaled whole-wing CL."
    else
        # Exact bin integrals of the prescribed distribution preserve total
        # lift even at an elliptical tip; the plotted value is a bin average.
        total = Float64(p["loads.lift_total"]) * p["loads.load_factor"]
        for i in 1:100
            lo,hi = (i-1)/100, i/100; e = (lo+hi)/2
            share = lift_fraction(p["loads.distribution"],w,hi)-lift_fraction(p["loads.distribution"],w,lo)
            push!(eta,e); push!(ys,w.root_ref_y+e*w.semispan); push!(widths,(hi-lo)*w.semispan)
            push!(chords,chord(w,e)); push!(lifts,total*share); push!(lows,lo); push!(highs,hi)
        end
        coefficient_note = "Equivalent coefficient from prescribed global-z lift/(q*projected strip width), using this case's speed and density. Includes the dimensionless load multiplier; this is not a solved aerodynamic section coefficient."
    end
    distribution = Dict{String,Any}("eta"=>eta,"eta_lo"=>lows,"eta_hi"=>highs,"y_m"=>ys,
        "strip_width_m"=>widths,"chord_m"=>chords,"strip_lift_N"=>lifts,
        "lift_N_per_m"=>lifts ./ widths,"cl_chord_m"=>lifts ./ (q .* widths),
        "q_Pa"=>q,"total_lift_N"=>sum(lifts),"note"=>coefficient_note)

    located(load)=(position=Tuple(m.xyz[3load.node+1:3load.node+3]),force=load.force,moment=load.moment)
    applied=routed_applied_loads(m,loads)
    couples=Dict(key=>[merge(s,(moment=getproperty(s.source_moments,Symbol(key)),)) for s in applied.moments]
        for key in ("aerodynamic","fuel","structure"))
    points=Dict("aerodynamic"=>vcat(applied.aerodynamic,couples["aerodynamic"]),
        "fuel"=>vcat(located.(applied.fuel),couples["fuel"]),
        "structure"=>vcat(located.(applied.structure),couples["structure"]))
    stations=vcat(values(points)...);acceleration=structure_acceleration(p)
    structure=all(iszero,acceleration) ? NamedTuple[] : structural_mass_sources(m)
    aero=aerodynamic_plot_sources(m,loads)
    events=Set{Float64}(first(s.points)[2] for s in structure if all(p->p[2]==first(s.points)[2],s.points))
    fuel_cuts=lock(FUEL_GEOMETRY_LOCK) do
        reduce(vcat,(bay.cuts for bay in fuel_geometry_bays(m));init=Float64[])
    end
    source_ys=vcat(collect(events),[s.lo for s in aero],[s.hi for s in aero])
    etas=sort!(unique(vcat(collect(range(0.,1.;length=101)),m.grid.etas[m.grid.ribs.+1],fuel_cuts,(source_ys.-w.root_ref_y)./w.semispan)))
    fuel=fuel_plot_sources(m,etas)
    sources=Dict("aerodynamic"=>aero,"structure"=>structure,"fuel"=>fuel)
    ys=sort!(unique(vcat(w.root_ref_y.+w.semispan.*etas,source_ys)))
    components=Dict{String,Any}();fe=Dict{String,Any}()
    point_events=Set(s.position[2] for s in stations);fe_ys=sort!(unique(vcat(ys,collect(point_events))))
    for key in ("aerodynamic","structure","fuel")
        if key=="structure"&&!isempty(structure)
            integrals=structural_cut_integrals(structure,ys,events);cut=Ref(0)
            components[key]=plot_resultant_arrays(m,ys,events,(y,side)->begin
                cut[]+=1;i=cut[]
                (integrals.mass[i].*acceleration,cross3(integrals.first_moment[i],acceleration))
            end)
        else
            components[key]=plot_resultant_arrays(m,ys,events,(y,side)->begin
            force,moment=AERO_ZERO,AERO_ZERO
            for source in sources[key]
                f,moment0=distributed_source_resultant(source,y,side,key=="structure" ? acceleration : AERO_ZERO)
                force=force.+f;moment=moment.+moment0
            end
            (force,moment)
        end)
        end
        index=plot_point_index(points[key])
        fe[key]=plot_resultant_arrays(m,fe_ys,point_events,(y,side)->begin
            plot_point_resultant(index,y,side)
        end)
    end
    for data in (components,fe)
        total=deepcopy(data["aerodynamic"])
        for key in ("shear_z_N","bending_x_Nm","torque_y_Nm");total[key]=data["aerodynamic"][key].+data["structure"][key].+data["fuel"][key];end
        data["total"]=total
    end
    resultants=components["total"];force,moment=load_resultant(stations)
    reference = section_point(w,0.0,Float64(p["rbe3.ref_xc"]),0.0)
    return Dict{String,Any}("distribution"=>distribution,"resultants"=>resultants,"components"=>components,"fe_resultants"=>fe,
        "box_end_eta"=>last(m.grid.etas),"semispan_m"=>w.semispan,"root_ref_y_m"=>w.root_ref_y,"reference_xc"=>p["rbe3.ref_xc"],
        "reference_note"=>"Moments about the refined wing's swept/twisted chord-line point at the RBE3 reference x/c at each cut; components remain global x/y/z.",
        "sign_note"=>"Outboard applied-load resultant: positive shear is global +z, bending is right-hand +x, torque is right-hand +y. The balancing internal cut action has opposite sign. At a station, inboard includes its applied load and outboard excludes it.",
        "resultant_note"=>"Exact FE point loads shows only the written RBE3 loads: aerodynamic FORCE/MOMENT at rib references and combined fuel/structural inertia FORCE/MOMENT at bay references, including moved-force lever arms. Distributed view instead reconstructs the original physical aerodynamic strips, filled fuel volume and structural mass at their actual centroids. It does not add the transfer couples a second time. Both views preserve each source's complete root force and moment. No spline smoothing. Unboxed aerodynamic loading extends beyond the final rib only in the distributed source view. These are applied-load diagrams, not recovered stresses.",
        "moment_routing_note"=>APPLIED_MOMENT_ROUTING_NOTE,
        "structure_inertia"=>get(p,"loads.structure_inertia",false),"structure_inertia_migration_note"=>get(p,"structure_inertia_migration_note",""),
        "units"=>Dict("eta"=>"1","y_m"=>"m","cl_chord_m"=>"m","shear_z_N"=>"N","bending_x_Nm"=>"N m","torque_y_Nm"=>"N m"),
        "applied_force_N"=>collect(force),"applied_moment_origin_Nm"=>collect(moment),
        "root_moment_Nm_about_reference"=>collect(moment .- cross3(reference,force)))
end
