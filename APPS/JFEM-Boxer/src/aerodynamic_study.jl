# Independent full-wing VLM studies. No Model, FE grid, materials or loads required.
const AERODYNAMIC_STUDY_VERSION="full_wing_edge_wake_v7"
const AERODYNAMIC_MAX_PANELS=4096
const AERODYNAMIC_MAX_SAMPLES=101
const AERODYNAMIC_MAX_RETAINED_PANELS=120000
aerodynamic_geometry_key(k)=startswith(k,"planform.")||startswith(k,"airfoil.")||startswith(k,"loft.")||k=="movable_surfaces.items"
aerodynamic_plain(v::AbstractDict)=Dict{String,Any}(String(k)=>aerodynamic_plain(x) for (k,x) in v)
aerodynamic_plain(v::AbstractVector)=map(aerodynamic_plain,v)
aerodynamic_plain(v::AbstractString)=String(v)
aerodynamic_plain(v)=v

function aerodynamic_geometry(flat::AbstractDict)
    p=default_params();input=round_coordinate_inputs(flat)
    for (key,value) in input
        aerodynamic_geometry_key(key)||continue
        haskey(SCHEMA_BY_KEY,key)||throw(ArgumentError("Unknown aerodynamic geometry input $key"))
        spec=SCHEMA_BY_KEY[key]
        p[key]=spec.kind===:planformpoints ? normalize_planform_points(value,key;nominal=point_nominal(p,key)) : coerce_value(spec,value)
    end
    for key in ("planform.area","planform.aspect_ratio")
        p[key]>0&&isfinite(p[key])||throw(ArgumentError("$key must be positive and finite"))
    end
    for spec in SCHEMA
        aerodynamic_geometry_key(spec.key)&&spec.kind===:float&&(!isfinite(p[spec.key]))&&throw(ArgumentError("$(spec.key) must be finite"))
    end
    0<p["planform.taper_ratio"]<=1||throw(ArgumentError("Taper must be greater than zero and at most one"))
    abs(p["planform.sweep"])<=60&&abs(p["planform.dihedral"])<=30||throw(ArgumentError("VLM supports sweep within +/-60 and dihedral within +/-30 degrees"))
    apply_point_angle_constraints!(p)
    w=make_wing(p)
    w.span^2/w.area>=2||throw(ArgumentError("VLM requires actual aspect ratio at least 2"))
    return p,w,normalize_movable_surfaces(p["movable_surfaces.items"])
end

function aerodynamic_settings(raw::AbstractDict,controls)
    raw=aerodynamic_plain(raw)
    defaults=Dict{String,Any}("stability_alpha"=>0.,"derivatives"=>true,"mode"=>"single","alpha"=>5.,"beta"=>0.,"p"=>0.,"q"=>0.,"r"=>0.,
        "speed"=>70.,"atmosphere"=>"isa1976","altitude"=>0.,"density"=>1.225,"speed_of_sound"=>340.294,"compressibility"=>"prandtl_glauert",
        "chord_panels"=>8,"span_panels"=>16,"control_chord_panels"=>3,
        "chord_spacing"=>"cosine","span_spacing"=>"cosine","max_panels"=>2048,
        "max_strip_twist"=>2.,"max_panel_warp"=>8.,"max_normal_error"=>1.,
        "wake_model"=>"straight","wake_acceleration"=>"anderson","wake_length"=>3.,"wake_rows"=>16,"wake_iterations"=>100,
        "wake_tolerance"=>.002,"wake_relaxation"=>.25,"wake_core"=>.02,"wake_derivatives"=>"frozen",
        "reference"=>[nothing,nothing,nothing],"controls"=>Dict{String,Any}(),"sweeps"=>Any[])
    all(k->haskey(defaults,k),keys(raw))||throw(ArgumentError("Unknown aerodynamic study setting"))
    s=merge(defaults,Dict{String,Any}(raw))
    s["derivatives"] isa Bool||throw(ArgumentError("Derivatives must be true or false"))
    s["mode"] in ("single","sweep")||throw(ArgumentError("Choose single condition or sweep"))
    s["atmosphere"] in ("isa1976","manual")||throw(ArgumentError("Choose ISA 1976 or manual atmosphere"))
    s["compressibility"] in ("prandtl_glauert","incompressible")||throw(ArgumentError("Choose Prandtl-Glauert or incompressible flow"))
    s["wake_acceleration"] in ("none","anderson")||throw(ArgumentError("Choose plain or Anderson-accelerated wake relaxation"))
    s["wake_model"] in ("straight","relaxed")||throw(ArgumentError("Choose a straight or relaxed free wake"))
    s["wake_derivatives"] in ("frozen","relaxed")||throw(ArgumentError("Choose frozen or re-relaxed wake derivatives"))
    s["wake_model"]=="relaxed"&&s["compressibility"]!="incompressible"&&throw(ArgumentError("Relaxed free wakes require Incompressible flow; Prandtl-Glauert is available with straight wakes"))
    for (key,lo,hi) in (("stability_alpha",-30.,30.),("alpha",-30.,30.),("beta",-30.,30.),("p",-360.,360.),("q",-360.,360.),("r",-360.,360.),
        ("speed",.01,1000.),("altitude",-5000.,86000.),("density",1e-8,100.),("speed_of_sound",1.,2000.),
        ("wake_length",.25,10.),("wake_tolerance",1e-5,.02),("wake_relaxation",.05,.8),("wake_core",.001,.2),
        ("max_strip_twist",.25,10.),("max_panel_warp",1.,30.),("max_normal_error",.1,5.))
        value=s[key];value isa Real&&!(value isa Bool)&&isfinite(value)&&lo<=value<=hi||throw(ArgumentError("$key must be between $lo and $hi"));s[key]=Float64(value)
    end
    for (key,lo,hi) in (("wake_rows",4,80),("wake_iterations",2,300),("chord_panels",1,80),("span_panels",2,160),("control_chord_panels",1,30),("max_panels",16,AERODYNAMIC_MAX_PANELS))
        value=s[key];value isa Real&&!(value isa Bool)&&isinteger(value)&&lo<=value<=hi||throw(ArgumentError("$key must be an integer between $lo and $hi"));s[key]=Int(value)
    end
    all(k->s[k] in ("uniform","cosine"),("chord_spacing","span_spacing"))||throw(ArgumentError("Mesh spacing must be uniform or cosine"))
    s["reference"] isa AbstractVector&&length(s["reference"])==3&&all(v->v===nothing||v isa Real&&!(v isa Bool)&&isfinite(v),s["reference"])||throw(ArgumentError("Moment/rate reference requires three finite coordinates or Auto values"))
    s["controls"] isa AbstractDict||throw(ArgumentError("Control settings must be a table"))
    names=Set(c["name"] for c in controls);all(n->n in names,keys(s["controls"]))||throw(ArgumentError("A study control no longer exists in the geometry; refresh its control list"))
    clean=Dict{String,Any}()
    for c in controls
        v=get(s["controls"],c["name"],Dict{String,Any}());v isa AbstractDict&&all(k->k in ("enabled","pairing","right","left","source"),keys(v))||throw(ArgumentError("Invalid control settings"))
        source=get(v,"source","geometry");source in ("geometry","override")||throw(ArgumentError("Choose geometry motion or analysis override"))
        pairing=get(v,"pairing",c["kind"]=="aileron" ? "antisymmetric" : "symmetric")
        pairing in ("symmetric","antisymmetric","independent")||throw(ArgumentError("Choose symmetric, antisymmetric or independent control halves"))
        enabled=get(v,"enabled",true);enabled isa Bool||throw(ArgumentError("Control enabled must be true or false"))
        right=get(v,"right",c["deflection"]);left=pairing=="symmetric" ? right : pairing=="antisymmetric" ? -right : get(v,"left",c["deflection"])
        if source=="geometry";right=left=c["deflection"];pairing="symmetric";end
        all(x->x isa Real&&!(x isa Bool)&&isfinite(x)&&abs(x)<=45,(right,left))||throw(ArgumentError("Aerodynamic control deflections must be within +/-45 degrees"))
        clean[c["name"]]=Dict("source"=>source,"enabled"=>enabled,"pairing"=>pairing,"right"=>Float64(right),"left"=>Float64(left))
    end
    s["controls"]=clean
    sweeps=s["sweeps"];sweeps isa AbstractVector&&length(sweeps)<=3||throw(ArgumentError("Use at most three sweep variables"))
    used=Set{String}()
    for sweep in sweeps
        sweep isa AbstractDict&&Set(keys(sweep))==Set(["variable","start","stop","count"])||throw(ArgumentError("A sweep needs variable, start, stop and count"))
        key=sweep["variable"];key isa AbstractString||throw(ArgumentError("Invalid sweep variable"))
        (key in ("alpha","beta","p","q","r","speed","altitude")||startswith(key,"control:")&&key[9:end] in names||startswith(key,"control_left:")&&key[14:end] in names)||throw(ArgumentError("Unknown sweep variable $key"))
        key in used&&throw(ArgumentError("Each sweep variable may appear once"));push!(used,key)
        all(k->sweep[k] isa Real&&!(sweep[k] isa Bool)&&isfinite(sweep[k]),("start","stop","count"))&&isinteger(sweep["count"])&&2<=sweep["count"]<=101||throw(ArgumentError("Sweep bounds must be finite and count an integer from 2 to 101"))
    end
    s["mode"]=="sweep"&&isempty(sweeps)&&throw(ArgumentError("Add at least one sweep variable"))
    return s
end

function aerodynamic_conditions(settings,controls)
    cases=[deepcopy(settings)]
    if settings["mode"]=="sweep"
        for sweep in settings["sweeps"]
            length(cases)*Int(sweep["count"])<=AERODYNAMIC_MAX_SAMPLES||throw(ArgumentError("Sweep requests more than $AERODYNAMIC_MAX_SAMPLES conditions"))
            next=Dict{String,Any}[]
            for c in cases,value in range(sweep["start"],sweep["stop"];length=Int(sweep["count"]))
                v=deepcopy(c);key=sweep["variable"]
                if startswith(key,"control_left:")
                    name=key[14:end];v["controls"][name]["source"]="override";v["controls"][name]["pairing"]="independent";v["controls"][name]["left"]=value
                elseif startswith(key,"control:")
                    v["controls"][key[9:end]]["source"]="override";v["controls"][key[9:end]]["right"]=value
                else;v[key]=value;end
                push!(next,aerodynamic_settings(v,controls))
            end
            cases=next
        end
    end
    return cases
end

aerodynamic_spacing(t,kind)=kind=="cosine" ? (1-cospi(t))/2 : t
function aerodynamic_control_point(w,row,eta,xc,point,angle)
    cut=movable_chord_coordinate(row,"front_spar",eta)
    active=row["edge"]=="trailing" ? xc>=cut-1e-12 : xc<=cut+1e-12
    (!active||iszero(angle))&&return point
    movable_kinematics(w,row;angle).transform(point)
end

# A boundary not lying on the physical hinge moves relative to the fixed skin.
# Give the control and fixed part separate sheets so a gap is never replaced
# by a stretched fixed panel. Split even at zero angle to keep stencil topology.
function aerodynamic_control_gap(w,row)
    motion=movable_kinematics(w,row)
    any(range(row["eta_start"],row["eta_end"];length=9)) do eta
        p=camber_point(w,eta,movable_chord_coordinate(row,"front_spar",eta))
        norm3(cross3(motion.axis,p.-motion.h0))>1e-8*max(1.,chord(w,eta))
    end
end
function aerodynamic_motion_angle(w,row,side,c)
    c["enabled"]||return 0.
    c["source"]=="geometry" ? c[side] : aerodynamic_command_angle(w,row,side,c[side])
end

# Bound BOTH opposite edge pairs in physical 3D coordinates, including loft rise.
function aerodynamic_aspect(m)
    a,b,c,d=m.corners
    chord=(norm3(b.-a),norm3(c.-d));span=(norm3(d.-a),norm3(c.-b))
    return (minimum(span)/maximum(chord),maximum(span)/minimum(chord))
end

# Bounded cosine edge grading keeps finite cells and a manageable panel budget.
# Uniform chord grids need gentler grading to retain their 0.7 lower aspect bound.
function aerodynamic_span_fraction(t,kind;cosine_chord=true)
    kind=="cosine"||return t
    blend=cosine_chord ? .65 : .15
    (1-blend)*t+blend*(1-cospi(t))/2
end

function aerodynamic_mesh(w,controls,s;progress=(stage,done,total)->nothing)
    # Full-chord span patches permit local chord density without introducing
    # artificial trailing wakes at internal chord/hinge boundaries.
    boundaries=with_planform_stations(w,sort!(unique(vcat(0.,1.,w.airfoil_etas,loft_control_etas(w),
        [c[k] for c in controls for k in ("eta_start","eta_end")]))))
    patches=NamedTuple[];total=0
    spacing(t,kind)=kind=="cosine" ? (1-cospi(t))/2 : t
    cosine=s["chord_spacing"]=="cosine"
    function band(side,a,b,depth=0,component=nothing)
        depth<=12||throw(ArgumentError("Cannot meet VLM panel aspect ratio 0.7-1.5 near eta $a; simplify closely spaced loft/control stations"))
        mid=(a+b)/2
        active=sort([c for c in controls if c["eta_start"]<mid<c["eta_end"]];by=c->c["front_spar_start"])
        zone(e)=vcat(0.,[movable_chord_coordinate(c,"front_spar",e) for c in active],1.)
        seams=Set(i for i in eachindex(active) if aerodynamic_control_gap(w,active[i]))
        if component===nothing
            groups=UnitRange{Int}[];firstzone=1
            for i in eachindex(active)
                if i in seams;push!(groups,firstzone:i);firstzone=i+1;end
            end
            push!(groups,firstzone:length(active)+1)
            if length(groups)>1;for group in groups;band(side,a,b,depth,group);end;return;end
            component=only(groups)
        end
        element_name="fixed wing"
        for idx in seams
            row=active[idx]
            if row["edge"]=="trailing" ? first(component)>idx : last(component)<=idx
                element_name="control: "*row["name"]
            end
        end
        function point(e,xi)
            z=zone(e);k=min(floor(Int,xi)+1,length(z)-1);t=xi-(k-1);xc=(1-t)*z[k]+t*z[k+1]
            v=camber_point(w,e,xc)
            for (idx,row) in enumerate(active)
                idx in seams&&((row["edge"]=="trailing"&&last(component)<=idx)||(row["edge"]=="leading"&&first(component)>idx))&&continue
                c=s["controls"][row["name"]];angle=aerodynamic_motion_angle(w,row,side,c)
                v=aerodynamic_control_point(w,row,e,xc,v,angle)
            end
            return v
        end
        # Integrate physical arc length / local chord. Steep winglets receive
        # rows according to their actual height, not their projected eta width.
        samples=collect(range(a,b;length=65));arc=[0.];weighted=[0.]
        for (u,v) in zip(samples[1:end-1],samples[2:end])
            ds=norm3(camber_point(w,v,.5).-camber_point(w,u,.5));e=(u+v)/2
            density=s["span_spacing"]=="cosine" ? 1+.15*cospi(e)^8 : 1.
            density+=.15*sum(exp(-abs(e-k)/.025) for k in boundaries[2:end-1];init=0.)
            push!(arc,last(arc)+ds);push!(weighted,last(weighted)+ds/chord(w,e)*density)
        end
        last(arc)>0||throw(ArgumentError("Collapsed aerodynamic span interval"))
        inverse(t)=begin
            q=t*last(weighted);i=clamp(searchsortedlast(weighted,q),1,length(samples)-1)
            samples[i]+(samples[i+1]-samples[i])*(q-weighted[i])/(weighted[i+1]-weighted[i])
        end
        minwidths=[minimum(zone(e)[i+1]-zone(e)[i] for e in (a,mid,b)) for i in 1:length(zone(mid))-1]
        minimum(minwidths)>1e-8||throw(ArgumentError("Aerodynamic hinge zones cross or collapse"))
        h=min(1/s["chord_panels"],last(arc)/(max(1,s["span_panels"]*(b-a))*chord(w,mid)))
        for row in active
            i=row["edge"]=="leading" ? 1 : length(minwidths)
            i in component&&(h=min(h,minwidths[i]/s["control_chord_panels"]))
        end
        h=min(h,minimum(minwidths[component]))
        for iteration in 1:10
            counts=[max(1,ceil(Int,width/h-1e-10)) for width in minwidths]
            # Resolve control loading/hinge gradients with 25% more chord cells
            # than the base wing zoning, and at least one extra cell per control.
            controlzones=Set(row["edge"]=="leading" ? 1 : length(minwidths) for row in active)
            for i in intersect(controlzones,Set(component))
                counts[i]=max(counts[i]+1,ceil(Int,1.25counts[i]))
            end
            if !cosine
                # Extra control cells must also refine wider adjacent zones.
                # Otherwise their incompatible chord scales cannot satisfy
                # both aspect bounds, however often the span band is split.
                cellwidth=minimum(minwidths[i]/counts[i] for i in component)
                for i in component
                    counts[i]=max(counts[i],ceil(Int,minwidths[i]/cellwidth-1e-10))
                end
            end
            xis=vcat([i-1+spacing(k/counts[i],s["chord_spacing"]) for i in component for k in 0:counts[i]-1],Float64(last(component)))
            # Actual cell width differs slightly after rounding hinge-zone counts.
            actualh=minimum(minwidths[i]*(spacing((k+1)/counts[i],s["chord_spacing"])-spacing(k/counts[i],s["chord_spacing"])) for i in component for k in 0:counts[i]-1)
            n=max(1,ceil(Int,last(weighted)/actualh/(cosine ? 1.3 : 1.)))
            for attempt in 1:5
                predicted=total+(length(xis)-1)*n
                predicted<=s["max_panels"]||throw(ArgumentError("Quality-constrained full-wing mesh exceeds $(s["max_panels"]) panels; increase Maximum full-wing panels or reduce base/control density. Span/chord aspect upper bound is 1.5; true cosine spacing permits ratios below 0.7."))
                spans=[inverse(aerodynamic_span_fraction(j/n,s["span_spacing"];cosine_chord=cosine)) for j in 0:n];grid=Array{Float64}(undef,3,length(xis),length(spans))
                for (j,e) in enumerate(spans),(i,xi) in enumerate(xis);grid[:,i,j].=point(e,xi);end
                if side=="left";grid=grid[:,:,end:-1:1];grid[2,:,:].=2w.root_ref_y.-grid[2,:,:];end
                metrics=validate_vlm_grid(grid);ratios=aerodynamic_aspect.(metrics)
                lo=minimum(first,ratios);hi=maximum(last,ratios)
                aspectok=(cosine||lo>=.7-1e-9)&&hi<=1.5+1e-9
                geometryok=maximum(m.warp_deg for m in metrics)<=s["max_panel_warp"]&&
                    maximum(m.control_normal_error_deg for m in metrics)<=s["max_normal_error"]&&
                    maximum(abs(rad2deg(twist(w,spans[j+1])-twist(w,spans[j]))) for j in 1:n)<=s["max_strip_twist"]
                progress("Checking 3D mesh quality: $side, $(length(metrics)) panels in span patch ($total accepted)",0,1)
                if aspectok&&geometryok
                    total+=length(metrics)
                    push!(patches,(grid=grid,metrics=metrics,xis=xis,etas=side=="left" ? reverse(spans) : spans,side=side,
                        element_name=element_name,zone_range=component,split_boundaries=copy(seams),name=side*" / chord zones $(first(component)):$(last(component)) / "*(isempty(active) ? "fixed wing" : join([c["name"] for c in active]," + ")),active=active))
                    return
                end
                geometryok||break
                if !cosine&&hi/lo>1.5/.7*(1+1e-8)
                    # Taper, hinge sweep or loft curvature changes cell scales
                    # too much across this band; use smaller full-chord patches.
                    split=inverse(.5);band(side,a,split,depth+1,component);band(side,split,b,depth+1,component);return
                end
                lower=max(1,ceil(Int,n*hi/1.5-1e-8));upper=cosine ? typemax(Int) : floor(Int,n*lo/.7+1e-8)
                if lower>upper;break;end
                next=cosine ? max(lower,ceil(Int,n*hi/1.35)) : clamp(round(Int,n*sqrt(lo*hi)/sqrt(.7*1.5)),lower,upper)
                next==n&&break;n=next
            end
            # A short band or geometric curvature needs finer chord cells too.
            h/=(iteration<4 ? 1.35 : 1.6)
        end
        split=inverse(.5);band(side,a,split,depth+1,component);band(side,split,b,depth+1,component)
    end
    for side in ("left","right"),(a,b) in zip(boundaries[1:end-1],boundaries[2:end]);band(side,a,b);end
    return patches
end

function aerodynamic_reference(w,s)
    auto=section_point(w,0.,.25,0.)
    return ntuple(k->s["reference"][k]===nothing ? auto[k] : Float64(s["reference"][k]),3)
end

function aerodynamic_mesh_payload(patches,w,s)
    panels=Any[];id=0
    for (patchno,patch) in enumerate(patches),j in axes(patch.metrics,2),i in axes(patch.metrics,1)
        m=patch.metrics[i,j];id+=1
        eta=(patch.etas[j]+patch.etas[j+1])/2
        z=vcat(0.,[movable_chord_coordinate(c,"front_spar",eta) for c in patch.active],1.)
        at(xi)=begin k=min(floor(Int,xi)+1,length(z)-1);t=xi-(k-1);(1-t)*z[k]+t*z[k+1];end
        xc=(at(patch.xis[i])+at(patch.xis[i+1]))/2
        control=findfirst(c->c["edge"]=="trailing" ? xc>=movable_chord_coordinate(c,"front_spar",eta) : xc<=movable_chord_coordinate(c,"front_spar",eta),patch.active)
        push!(panels,Dict("id"=>id,"patch"=>patchno,"strip"=>j,"chord"=>i,"side"=>patch.side,"region"=>patch.name,
            "chord_fraction"=>xc,"control"=>control===nothing ? "" : patch.active[control]["name"],
            "corners"=>[collect(c) for c in m.corners],"normal"=>collect(m.normal),"area_m2"=>m.area,
            "aspect_ratio_min"=>first(aerodynamic_aspect(m)),"aspect_ratio_max"=>last(aerodynamic_aspect(m)),
            "position"=>[sum(c[k] for c in m.corners)/4 for k in 1:3],"eta"=>eta))
    end
    return Dict{String,Any}("panels"=>panels,"panel_count"=>length(panels),"patch_count"=>length(patches),
        "wake_model"=>s["wake_model"],"chord_spacing"=>s["chord_spacing"],"aspect_policy"=>(cosine=s["chord_spacing"]=="cosine";cosine ? "True cosine per hinge region; maximum 1.5 enforced, minimum 0.7 advisory" : "Uniform: physical span/chord ratios 0.7-1.5"),
        "reference_frames"=>aerodynamic_frame_geometry(s),"stability_alpha_deg"=>s["stability_alpha"],
        "vector_frame"=>"construction C: X aft, Y right, Z up; origin at selected reference for moments/rates",
        "reference"=>collect(aerodynamic_reference(w,s)),"area_m2"=>w.area,"span_m"=>w.span,"mac_m"=>w.mac,
        "min_panel_aspect_ratio"=>minimum(first(aerodynamic_aspect(m)) for p in patches for m in p.metrics),
        "max_panel_aspect_ratio"=>maximum(last(aerodynamic_aspect(m)) for p in patches for m in p.metrics),
        "wake_origins"=>unique([collect(p.grid[:,end,j]) for p in patches for j in axes(p.grid,3)]),
        "wake_direction"=>[cosd(s["alpha"])*cosd(s["beta"]),-sind(s["beta"]),sind(s["alpha"])*cosd(s["beta"])],
        "max_warp_deg"=>maximum(m.warp_deg for p in patches for m in p.metrics),
        "max_normal_error_deg"=>maximum(m.control_normal_error_deg for p in patches for m in p.metrics))
end

function aerodynamic_solve(w,patches,s;wake_seed=nothing,frozen_wake=false,progress=(stage,done,total)->nothing)
    p=Dict{String,Any}("aero.atmosphere"=>s["atmosphere"],"aero.altitude"=>s["altitude"],"aero.speed"=>s["speed"],
        "aero.density"=>s["density"],"aero.speed_of_sound"=>s["speed_of_sound"])
    flight=flight_condition(p);speed=s["speed"];rho=flight["density_kg_m3"];q=flight["q_Pa"];mach=flight["Mach"]
    mach<=.5+8eps(.5)||throw(ArgumentError("VLM requires Mach <= 0.5; change speed or atmosphere"))
    reference=aerodynamic_reference(w,s);origin=(w.root_ref_x,w.root_ref_y,w.root_ref_z+vertical_shift(w,0.))
    ref_local=reference.-origin
    physfs=VortexLattice.Freestream(speed,deg2rad(s["alpha"]),deg2rad(s["beta"]),deg2rad.([s["p"],s["q"],s["r"]]))
    R=VortexLattice.body_to_wind(physfs);B=s["compressibility"]=="incompressible" ? 1. : sqrt(1-mach^2)
    rotate(v)=Tuple(R*collect(v));unrotate(v)=Tuple(transpose(R)*collect(v))
    forward(v)=begin r=rotate(v);(r[1],B*r[2],B*r[3]);end
    inverse(v)=unrotate((v[1],v[2]/B,v[3]/B))
    physical_rotation(r)=Tuple(VortexLattice.rotational_velocity(collect(r),physfs, VortexLattice.Reference(w.area,w.mac,w.span,collect(ref_local),speed)))
    known(r)=VortexLattice.SVector{3}(forward(physical_rotation(inverse(r))))
    grids=[similar(p.grid) for p in patches]
    for (grid,patch) in zip(grids,patches),j in axes(grid,3),i in axes(grid,2)
        grid[:,i,j].=forward(Tuple(patch.grid[:,i,j]).-origin)
    end
    ratios=[zeros(2,size(g,2)-1,size(g,3)-1).+[.5,.75] for g in grids]
    system=VortexLattice.System(grids;ratios=ratios)
    ref=VortexLattice.Reference(w.area,w.mac,w.span,collect(forward(ref_local)),speed)
    fs=VortexLattice.Freestream(speed,0.,0.,[0.,0.,0.])
    element_ids=Dict{String,Int}();surface_ids=[get!(()->length(element_ids)+1,element_ids,p.element_name) for p in patches]
    VortexLattice.steady_analysis!(system,ref,fs;symmetric=false,derivatives=false,surface_id=surface_ids,additional_velocity=known,xhat=[1.,0.,0.],
        fcore=(c,ds)->s["wake_model"]=="relaxed" ? s["wake_core"]*w.mac : 1e-3)
    wake=s["wake_model"]=="relaxed" ? aerodynamic_free_wake!(system,ref,fs,known,s,w,forward,inverse,origin;seed=wake_seed,frozen=frozen_wake,progress) : nothing
    all(isfinite,system.Γ)||error("VLM returned nonfinite circulation")
    payload=aerodynamic_mesh_payload(patches,w,s);panels=payload["panels"];force=AERO_ZERO;moment=AERO_ZERO;index=0;offset=0;strips=Any[]
    for (patchno,patch) in enumerate(patches)
        surface=system.surfaces[patchno];properties=system.properties[patchno];nc,ns=size(surface)
        for j in 1:ns
            stripF=AERO_ZERO;stripM=AERO_ZERO;weightedCp=0.;area=0.;gamma=0.
            for i in 1:nc
                index+=1;panel=surface[i,j];prop=properties[i,j];record=panels[index]
                G=system.Γ[offset+(j-1)*nc+i]/B^2;Gb=i==1 ? G : G-system.Γ[offset+(j-1)*nc+i-1]/B^2
                center=inverse(VortexLattice.top_center(panel));rotation=physical_rotation(center)
                solver_known=known(VortexLattice.top_center(panel));v=prop.velocity.*speed
                disturbance=(v[1]-speed-solver_known[1],v[2]-solver_known[2],v[3]-solver_known[3])
                velocity=Tuple(VortexLattice.freestream_velocity(physfs)).+rotation.+unrotate((disturbance[1]/B^2,disturbance[2]/B,disturbance[3]/B))
                F=AERO_ZERO;M=AERO_ZERO
                for (point,segment,circulation,vel) in (
                    (VortexLattice.top_center(panel),VortexLattice.top_vector(panel),Gb,velocity),
                    (VortexLattice.left_center(panel),VortexLattice.left_vector(panel),G,nothing),
                    (VortexLattice.right_center(panel),VortexLattice.right_vector(panel),G,nothing))
                    x=inverse(point);u=vel===nothing ? Tuple(VortexLattice.freestream_velocity(physfs)).+physical_rotation(x) : vel
                    f=(rho*circulation).*cross3(u,inverse(segment));F=F.+f;M=M.+cross3(x.-ref_local,f)
                end
                metric=patch.metrics[i,j];pressure=sum(F.*metric.normal)/metric.area
                all(isfinite,(F...,M...,pressure,G))||error("Nonfinite aerodynamic panel recovery")
                record["force_N"]=collect(F);record["moment_Nm"]=collect(M);windF=rotate(F);record["force_wind_N"]=[-windF[1],windF[2],-windF[3]];record["wind_loads_N"]=collect(windF);record["delta_pressure_Pa"]=pressure;record["delta_cp"]=pressure/q
                record["circulation_m2_s"]=G;record["velocity_m_s"]=collect(velocity);record["speed_ratio"]=norm3(velocity)/speed
                force=force.+F;moment=moment.+M;stripF=stripF.+F;stripM=stripM.+M;weightedCp+=pressure/q*metric.area;area+=metric.area;gamma+=G
            end
            eta=(patch.etas[j]+patch.etas[j+1])/2;dy=abs(patch.etas[j+1]-patch.etas[j])*w.semispan;c=chord(w,eta);wind=rotate(stripF)
            push!(strips,Dict("side"=>patch.side,"region"=>patch.name,"eta"=>eta,"y_m"=>w.root_ref_y+(patch.side=="right" ? 1 : -1)*eta*w.semispan,
                "width_m"=>dy,"chord_m"=>c,"force_per_m"=>collect(stripF./dy),"moment_per_m"=>collect(stripM./dy),
                "lift_per_m"=>wind[3]/dy,"drag_per_m"=>wind[1]/dy,"side_force_per_m"=>wind[2]/dy,
                "cl"=>wind[3]/(q*c*dy),"cdi_near"=>wind[1]/(q*c*dy),"cy"=>wind[2]/(q*c*dy),"mean_delta_cp"=>weightedCp/area,"mean_circulation"=>gamma/nc))
        end
        offset+=length(surface)
    end
    sort!(strips;by=r->r["y_m"])
    coefficients=aerodynamic_coefficients(force,moment,s,q*w.area,w.span,w.mac)
    cdi=wake===nothing ? VortexLattice.far_field_drag(system)/B^4 : wake["trefftz"]["CDi"];cl=coefficients["wind"]["force"][3]
    residual=maximum(abs,system.AIC*system.Γ-system.w)/speed
    warnings=String[]
    payload["min_panel_aspect_ratio"]<.7-1e-9&&push!(warnings,"True cosine spacing: lower aspect ratio 0.7 is advisory; short interior panels are retained. The 1.5 upper limit is enforced.")
    abs(s["alpha"])+maximum(abs(rad2deg(twist(w,e))) for e in vcat(0.,w.twist_etas,1.))>12&&push!(warnings,"High local incidence: attached-flow extrapolation; VLM does not predict stall.")
    any(abs(c[side])>15 for c in values(s["controls"]) for side in ("left","right"))&&push!(warnings,"Large control deflection: thin-sheet attached-flow approximation; separation and hinge gaps are not modeled.")
    maximum(abs.([deg2rad(s["p"])*w.span/(2speed),deg2rad(s["q"])*w.mac/(2speed),deg2rad(s["r"])*w.span/(2speed)]))>.2&&push!(warnings,"Large rotation-rate parameter: this is a quasi-steady snapshot, not an unsteady maneuver simulation.")
    if wake!==nothing
        payload["wake"]=wake
        payload["trefftz"]=wake["trefftz"]
        if !wake["trefftz"]["valid"]
            push!(warnings,"Trefftz estimate unavailable: "*wake["trefftz"]["reason"])
        else
            change=wake["trefftz"]["relative_cut_change"]
            if change!==nothing&&change>.05
                push!(warnings,"Trefftz terminal-shape sensitivity: $(round(100change;digits=1))% relative change at an earlier wake section with fixed circulation. Refine wake length and spacing before relying on drag/efficiency.")
            end
            near=coefficients["wind"]["force"][1]
            difference=abs(near-cdi)/max(abs(near),abs(cdi),eps(Float64))
            wake["trefftz"]["near_field_CDi"]=near
            wake["trefftz"]["near_far_relative_difference"]=difference
            difference>.2&&push!(warnings,"Near-field and terminal-wake Trefftz drag differ by $(round(100difference;digits=1))%; check wing/wake refinement and the wake cutoff.")
        end
    end
    payload["condition"]=s;payload["flight"]=flight;payload["coefficients"]=coefficients;payload["CDi_trefftz"]=cdi;payload["span_efficiency"]=cdi===nothing ? nothing : inviscid_span_efficiency(cl,cdi,w.span^2/w.area)
    payload["force_N"]=collect(force);payload["moment_Nm"]=collect(moment);payload["strips"]=strips;payload["residual_over_V"]=residual;payload["warnings"]=warnings
    return payload
end

function run_aerodynamic_study(flat,raw;mesh_only=false,progress=(stage,done,total)->nothing)
    progress("Reading aerodynamic geometry",0,1);p,w,controls=aerodynamic_geometry(flat);s=aerodynamic_settings(raw,controls)
    cases=mesh_only ? [s] : aerodynamic_conditions(s,controls);results=Any[];retained=0;retained_wake=0;mesh_cache=Dict{String,Any}();meshes=Any[]
    for (i,condition) in enumerate(cases)
        progress("Meshing full wing: condition $i / $(length(cases))",i-1,length(cases))
        patches=get!(()->aerodynamic_mesh(w,controls,condition;progress=progress),mesh_cache,JSON.json(condition["controls"]));retained+=sum(length(p.metrics) for p in patches)
        retained<=AERODYNAMIC_MAX_RETAINED_PANELS||throw(ArgumentError("Sweep result size exceeds $AERODYNAMIC_MAX_RETAINED_PANELS retained panels; reduce cases or mesh density"))
        if condition["wake_model"]=="relaxed"
            vertices=sum((condition["wake_rows"]+1)*(size(p.grid,3)) for p in patches)
            vertices<=12000||throw(ArgumentError("Free wake exceeds 12,000 vertices; reduce wake rows or wing mesh density"))
            retained_wake+=vertices
            retained_wake<=120000||throw(ArgumentError("Free-wake sweep exceeds 120,000 retained wake vertices; reduce sweep count or density"))
        end
        push!(meshes,patches)
    end
    for (i,condition) in enumerate(cases)
        patches=meshes[i]
        progress(mesh_only ? "Preparing mesh preview" : "Solving VLM: condition $i / $(length(cases))",i-1,length(cases))
        push!(results,mesh_only ? aerodynamic_mesh_payload(patches,w,condition) : aerodynamic_solve(w,patches,condition;progress=(stage,done,total)->progress("Condition $i / $(length(cases)): "*stage,done,total)))
        results[end]["condition"]=condition;results[end]["id"]=i
        if !mesh_only&&s["derivatives"]
            results[end]["derivatives"]=aerodynamic_derivatives(w,controls,patches,condition,results[end];
                progress=(stage,done,total)->progress("Condition $i / $(length(cases)): "*stage,done,total))
        end
    end
    progress("Complete",length(cases),length(cases))
    return Dict{String,Any}("version"=>AERODYNAMIC_STUDY_VERSION,"mesh_only"=>mesh_only,"settings"=>s,"cases"=>results,
        "geometry"=>Dict(k=>v for (k,v) in p if aerodynamic_geometry_key(k)),"created_at"=>string(Dates.now(Dates.UTC)),
        "basis"=>"Unscaled full symmetric-wing geometry, both halves solved explicitly; Construction C/BASIC X aft, Y right, Z up. B axes forward/right/down; A follows current alpha; S is fixed at stability_alpha; W-prime is American wind, not gravity-defined trajectory W. No FE model, structural load multiplier or inertia loads. Forces/moments about the displayed reference. Positions, dimensional panel/resultant vectors and their cross products remain in C. Coefficient vectors/moments are rotated dimensionally before normalization. Body/A/S forces are signed CX/CY/CZ; W-prime force displays positive CDi/CY/CL with signed force_components alongside. Axes are translated from the book CG origin to the selected reference (enter CG to use CG moments). Coefficient moments use standard dynamics signs (+roll right wing down, +pitch nose up, +yaw nose right).",
        "limitations"=>"Steady/quasi-steady attached-flow thin mean-camber VLM. Straight wakes support Prandtl-Glauert through Mach 0.5. Relaxed free wakes use incompressible flow, finite-core convection and a straight far continuation; no time-accurate shedding. Their derivatives explicitly freeze or re-relax wake geometry. Relaxed-wake Trefftz drag/span efficiency use the terminal cross-section with straight far continuation, as an approximate discrete wake-sheet integral with terminal-shape sensitivity diagnostics. Refine wake length/spacing/core; convergence of the wake alone does not establish drag accuracy. Control sheets follow authored rigid kinematics about their true 3D hinge. Offset boundaries use separate fixed/control lifting elements and can open gaps; finite thickness and viscous slot flow remain outside thin-sheet VLM. No viscous/profile drag, stall, shocks, hinge-gap leakage, aeroelastic feedback or time-accurate unsteady wake.")
end
