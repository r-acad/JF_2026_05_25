# Fuel inertia is integrated over the actual loft, independently of FE density.
# Moment coordinates are relative to a nearby origin to avoid cancellation for
# translated wings. Partial filling clips with horizontal BASIC-Z planes.
const FUEL_MASS_GRAVITY = 9.80665
const FUEL_GEOMETRY_LOCK = ReentrantLock()
const FUEL_GEOMETRY_CACHE = Ref{Any}(nothing) # one geometry, bounded case cache

"""Area, first moments and raw second moments of a planar x-z polygon."""
function fuel_polygon_moments(points,origin)
    result=zeros(10);length(points)>=3||return result
    area=mx=mz=qxx=qzz=qxz=0.0
    for i in eachindex(points)
        a,b=points[i],points[mod1(i+1,length(points))]
        x,z=a[1]-origin[1],a[3]-origin[3];u,v=b[1]-origin[1],b[3]-origin[3]
        cross=x*v-u*z
        area+=cross;mx+=(x+u)*cross;mz+=(z+v)*cross
        qxx+=(x*x+x*u+u*u)*cross;qzz+=(z*z+z*v+v*v)*cross
        qxz+=(2x*z+x*v+u*z+2u*v)*cross
    end
    sign=area<0 ? -1.0 : 1.0;area*=sign/2;mx*=sign/6;mz*=sign/6
    qxx*=sign/12;qzz*=sign/12;qxz*=sign/24;y=first(points)[2]-origin[2]
    result.=(area,mx,y*area,mz,qxx,y*y*area,qzz,y*mx,qxz,y*mz)
    return result
end

function fuel_adaptive_moments(f,a,b,tolerance,scale,depth=0)
    nodes=(-.8611363115940526,-.3399810435848563,.3399810435848563,.8611363115940526)
    weights=(.3478548451374538,.6521451548625461,.6521451548625461,.3478548451374538)
    gauss(lo,hi)=begin
        center=(lo+hi)/2;half=(hi-lo)/2;total=zeros(10)
        for i in 1:4;total.+=weights[i].*f(center+half*nodes[i]);end
        total.*half
    end
    whole=gauss(a,b);mid=(a+b)/2;split=gauss(a,mid)+gauss(mid,b)
    maximum(abs.(split-whole)./scale)<=tolerance&&return split
    depth<20||throw(ArgumentError("fuel mass integration did not converge near ETA $a to $b"))
    return fuel_adaptive_moments(f,a,mid,tolerance/2,scale,depth+1)+fuel_adaptive_moments(f,mid,b,tolerance/2,scale,depth+1)
end

function fuel_bay_geometry(m::Model,rib::Int)
    w,g,p=m.wing,m.grid,m.params;spar=spar_geometry(p);knots=airfoil_knots(w)
    ja,jb=g.ribs[rib],g.ribs[rib+1];eta_a,eta_b=g.etas[ja+1],g.etas[jb+1]
    mid=(eta_a+eta_b)/2;fs=spar_surface_xc(w,spar,mid,:front);rs=spar_surface_xc(w,spar,mid,:rear)
    origin=Tuple((collect(lower_point(w,mid,(fs+rs)/2))+collect(upper_point(w,mid,(fs+rs)/2)))/2)
    angled=oriented_ribs(g)
    planes=angled ? (main_rib_plane(g,p,ja),main_rib_plane(g,p,jb)) : nothing
    cuts=if angled
        sort!(unique(vcat(0.0,last(g.etas),collect(range(max(0.,eta_a-.1),min(last(g.etas),eta_b+.1);length=25)),
            filter(e->0<e<last(g.etas),vcat(planform_breakpoints(w),w.airfoil_etas,spar.breakpoints,
                g.lower_etas[:,ja+1],g.upper_etas[:,ja+1],g.lower_etas[:,jb+1],g.upper_etas[:,jb+1])))))
    else
        integration=fuel_integration(w,p)
        sort!(unique(vcat(eta_a,eta_b,filter(e->eta_a<e<eta_b,integration.cuts))))
    end
    polygon_cache=Dict{Float64,Vector{NTuple{3,Float64}}}()
    function polygon(eta)
        haskey(polygon_cache,eta)&&return polygon_cache[eta]
        front,rear=spar_surface_xc(w,spar,eta,:front),spar_surface_xc(w,spar,eta,:rear)
        xs=vcat(front,filter(x->front<x<rear,knots),rear)
        points=vcat([lower_point(w,eta,x) for x in xs],[upper_point(w,eta,x) for x in reverse(xs)])
        planes===nothing||(points=fuel_clip_polygon(fuel_clip_polygon(points,planes[1],1),planes[2],-1))
        length(polygon_cache)<256&&(polygon_cache[eta]=points)
        return points
    end
    extent=max(w.base_chord_root,w.semispan*(eta_b-eta_a),1e-3)
    scales=Float64[1,extent,extent,extent,extent^2,extent^2,extent^2,extent^2,extent^2,extent^2]
    approximate=max(w.semispan*(eta_b-eta_a)*w.base_chord_root^2*.2,1e-12)
    function integrate_between(eta_lo,eta_hi,level=Inf)
        isfinite(eta_lo)&&isfinite(eta_hi)&&eta_lo<=eta_hi||throw(ArgumentError("Fuel integration needs finite ascending ETA bounds"))
        lo=max(Float64(eta_lo),first(cuts));hi=min(Float64(eta_hi),last(cuts))
        hi<=lo&&return zeros(10)
        clip=(origin=(0.,0.,Float64(level)),normal=(0.,0.,1.))
        section(eta)=begin
            points=polygon(eta);isfinite(level)&&(points=fuel_clip_polygon(points,clip,-1))
            w.semispan.*fuel_polygon_moments(points,origin)
        end
        total=zeros(10)
        stations=vcat(lo,filter(e->lo<e<hi,cuts),hi)
        for i in 1:length(stations)-1
            a,b=stations[i],stations[i+1]
            total.+=fuel_adaptive_moments(section,a,b,1e-9*approximate*(b-a)/(last(cuts)-first(cuts)),scales)
        end
        return total
    end
    integrate(level=Inf)=integrate_between(first(cuts),last(cuts),level)
    full=integrate();full[1]>0&&all(isfinite,full)||throw(ArgumentError("Fuel bay $rib has invalid integrated moments"))
    center=collect(origin)+full[2:4]/full[1]
    # Conservative height bounds cover the full modeled loft, including twists
    # and angled bays; bisection needs bounds, not an approximate surface mesh.
    heights=[point[3] for eta in unique(vcat(cuts,[(cuts[i]+cuts[i+1])/2 for i in 1:length(cuts)-1])) for point in polygon(eta)]
    isempty(heights)&&throw(ArgumentError("Fuel bay $rib has no finite height bounds"))
    margin=max(maximum(heights)-minimum(heights),extent)
    return (;rib,eta_start=eta_a,eta_end=eta_b,origin,center,full,integrate,integrate_between,cuts,
        zmin=minimum(heights)-margin,zmax=maximum(heights)+margin)
end

function fuel_geometry_bays(m::Model)
    get(m.params,"fuel.enabled",false)||return Any[]
    selection=fuel_bay_selection(m.params,length(m.grid.ribs))
    bounds=(selection.first_rib,selection.last_rib,Tuple(selection.excluded))
    return lock(FUEL_GEOMETRY_LOCK) do
        cached=FUEL_GEOMETRY_CACHE[]
        if cached===nothing||cached.grid!==m.grid||cached.bounds!=bounds
            bays=[fuel_bay_geometry(m,rib) for rib in selection.active]
            FUEL_GEOMETRY_CACHE[]=(grid=m.grid,bounds=bounds,bays=bays,states=Dict{Float64,Any}())
        end
        FUEL_GEOMETRY_CACHE[].bays
    end
end

"""Whether a fuel-bay reference carries only loads, without a tank mass property."""
function fuel_reference_is_massless(m::Model,sp::FuelBaySpider)
    get(m.params,"fuel.enabled",false)||return true
    return !(sp.start_rib in fuel_bay_selection(m.params,length(m.grid.ribs)).active)
end

"""Generate fuel spiders, or massless equivalents when dry structure needs targets."""
function add_fuel_references!(m::Model)
    isempty(m.fuel_rbe3)||return m
    bays=fuel_geometry_bays(m)
    if isempty(bays)
        needs_inertia=any(spec->get(spec.params,"loads.structure_inertia",false)&&
            !iszero(spec.params["loads.load_factor"])&&any(axis->!iszero(get(spec.params,"loads.fuel_accel_"*axis,0.)),("x","y","z")),load_case_specs(m.params))
        needs_inertia||return m
        selection=get(m.params,"fuel.enabled",false) ? fuel_bay_selection(m.params,length(m.grid.ribs)) : nothing
        ribs=selection===nothing ? (1:length(m.grid.ribs)-1) : (selection.first_rib:selection.last_rib-1)
        bays=[fuel_bay_geometry(m,rib) for rib in ribs]
    end
    eid=maximum(vcat([0],[e for group in m.groups for e in group.eids],[sp.eid for sp in m.rbe3]))+1
    for bay in bays
        rows=(m.grid.ribs[bay.rib],m.grid.ribs[bay.rib+1]);columns=ni(m.grid)
        # Connect only the two rib/skin intersection curves. Interior rib and
        # spar-web height nodes must not become independent fuel attachments.
        connected=[n for n in 1:m.n_struct if 0<=m.node_keys[n][1]<=columns&&
            m.node_keys[n][2] in rows&&m.node_keys[n][3] in (0,m.grid.nh)]
        length(connected)>=3||throw(ArgumentError("Fuel bay $(bay.rib) needs independent skin-intersection nodes on both bounding ribs"))
        ref=length(m.node_ids)+1;push!(m.node_ids,ref);append!(m.xyz,bay.center);push!(m.node_keys,(-2,-ref,-2))
        push!(m.fuel_rbe3,FuelBaySpider(eid,eid+1,ref,connected,bay.rib,bay.rib+1));eid+=2
    end
    return m
end

fuel_case_percent(p)=Float64(get(p,"loads.fuel_percent",100*get(p,"fuel.fill_fraction",1.)))

function fuel_filled_moments(bay,percent)
    percent==0&&return (moments=zeros(10),level=nothing)
    percent==100&&return (moments=bay.full,level=nothing)
    target=bay.full[1]*percent/100;lo,hi=bay.zmin,bay.zmax
    moments=bay.full;level=(lo+hi)/2
    for iteration in 1:48
        level=(lo+hi)/2;moments=bay.integrate(level)
        abs(moments[1]-target)<=2e-9*bay.full[1]&&return (;moments,level)
        moments[1]<target ? (lo=level) : (hi=level)
    end
    abs(moments[1]-target)<=1e-7*bay.full[1]||throw(ArgumentError("Fuel bay $(bay.rib) fill-level solve did not converge"))
    return (;moments,level)
end

"""Per-case CONM2 properties. Product-of-inertia fields use Nastran's positive products."""
function fuel_mass_state(m::Model;params=m.params)
    percent=fuel_case_percent(params);0<=percent<=100||throw(ArgumentError("Fuel percentage must be between 0 and 100"))
    density=Float64(params["fuel.density"])
    geometry,fills=lock(FUEL_GEOMETRY_LOCK) do
        geometry=fuel_geometry_bays(m)
        isempty(geometry)&&return (geometry,Any[])
        states=FUEL_GEOMETRY_CACHE[].states
        # Models contain at most 65 cases; repeated interactive percentage edits
        # must not retain all historical fill integrations indefinitely.
        !haskey(states,percent)&&length(states)>=65&&delete!(states,first(keys(states)))
        fills=get!(states,percent) do
            [fuel_filled_moments(bay,percent) for bay in geometry]
        end
        return geometry,fills
    end
    rows=Dict{String,Any}[]
    for (index,bay) in enumerate(geometry)
        filled=fills[index];v=filled.moments;volume=v[1];mass=density*volume
        cg=volume>0 ? collect(bay.origin)+v[2:4]/volume : copy(bay.center)
        q=volume>0 ? [v[5] v[8] v[9];v[8] v[6] v[10];v[9] v[10] v[7]]-v[2:4]*v[2:4]'/volume : zeros(3,3)
        inertia=density.*[q[2,2]+q[3,3],q[1,2],q[1,1]+q[3,3],q[1,3],q[2,3],q[1,1]+q[2,2]]
        tensor=[[inertia[1],-inertia[2],-inertia[4]],[-inertia[2],inertia[3],-inertia[5]],[-inertia[4],-inertia[5],inertia[6]]]
        spider=isempty(m.fuel_rbe3) ? nothing : m.fuel_rbe3[index]
        push!(rows,Dict{String,Any}("index"=>bay.rib,"start_rib"=>bay.rib,"end_rib"=>bay.rib+1,
            "eta_start"=>bay.eta_start,"eta_end"=>bay.eta_end,"volume_m3"=>bay.full[1],
            "filled_volume_m3"=>volume,"mass_kg"=>mass,"capacity_mass_kg"=>density*bay.full[1],
            "center_of_gravity_m"=>cg,"reference_m"=>copy(bay.center),"offset_m"=>cg-bay.center,
            "inertia_kg_m2"=>tensor,"conm2_inertia_kg_m2"=>inertia,"fill_level_z_m"=>filled.level,
            "reference_node"=>spider===nothing ? nothing : spider.ref-1,
            "reference_grid"=>spider===nothing ? nothing : m.node_ids[spider.ref],
            "rbe3_eid"=>spider===nothing ? nothing : spider.eid,"conm2_eid"=>spider===nothing ? nothing : spider.mass_eid))
    end
    mass=sum((r["mass_kg"] for r in rows);init=0.);volume=sum((r["filled_volume_m3"] for r in rows);init=0.)
    return Dict{String,Any}("enabled"=>get(params,"fuel.enabled",false),"fuel_percent"=>percent,
        "fill_fraction"=>percent/100,"density_kg_m3"=>density,"mass_kg"=>mass,"filled_volume_m3"=>volume,
        "bays"=>rows,"in_deck"=>mass>0,"method"=>"Each bay fills upward to its own horizontal BASIC-Z level; exact polygon moments and adaptive span integration")
end

function fuel_applied_loads(m::Model;params=m.params,state=fuel_mass_state(m;params))
    acceleration=FUEL_MASS_GRAVITY.*Float64[get(params,"loads.fuel_accel_x",0.),get(params,"loads.fuel_accel_y",0.),get(params,"loads.fuel_accel_z",-1.)]
    factor=Float64(params["loads.load_factor"]);loads=NamedTuple[]
    for row in state["bays"]
        row["mass_kg"]>0||continue
        force=Tuple(factor*row["mass_kg"].*acceleration);moment=cross3(Tuple(row["offset_m"]),force)
        push!(loads,(node=row["reference_node"],gid=row["reference_grid"],bay=row["index"],force=force,moment=moment))
    end
    return loads
end

fuel_states_differ(m::Model)=get(m.params,"fuel.enabled",false)&&any(sp->!fuel_reference_is_massless(m,sp),m.fuel_rbe3)&&length(unique(fuel_case_percent(spec.params) for spec in load_case_specs(m.params)))>1
