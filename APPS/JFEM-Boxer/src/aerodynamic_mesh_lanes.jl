# Shared chord coordinates on connected fixed-wing sheets. An inactive control
# cut is a mesh lane, not a lifting-element boundary or an additional wake.
function aerodynamic_lane_ranks(rows)
    n=length(rows);parent=collect(1:n)
    root(i)=begin while parent[i]!=i;i=parent[i];end;i;end
    relations=Tuple{Int,Int}[]
    for i in 1:n-1
        rows[i].b==rows[i+1].a||continue
        x=movable_chord_coordinate(rows[i].row,"front_spar",rows[i].b)
        y=movable_chord_coordinate(rows[i+1].row,"front_spar",rows[i+1].a)
        if x==y;parent[root(i+1)]=root(i)
        else;push!(relations,x<y ? (i,i+1) : (i+1,i));end
    end
    ranks=zeros(Int,n)
    # Same-edge controls cannot overlap. Touching intervals form chains; their
    # endpoint ordering is acyclic, including after identical cuts are merged.
    for pass in 1:n
        changed=false
        for (a,b) in relations
            a=root(a);b=root(b)
            if ranks[b]<=ranks[a];ranks[b]=ranks[a]+1;changed=true;end
        end
        changed||break
        pass==n&&error("Inconsistent control endpoint lane ordering")
    end
    assignment=Dict(rows[i].row["name"]=>ranks[root(i)]+1 for i in 1:n)
    assignment,isempty(ranks) ? 0 : maximum(values(assignment))
end

function aerodynamic_lane_values(program,eta)
    j=clamp(searchsortedlast(program.stations,eta),1,length(program.stations)-1)
    t=(eta-program.stations[j])/(program.stations[j+1]-program.stations[j])
    (1-t).*program.values[:,j].+t.*program.values[:,j+1]
end

function aerodynamic_lane_programs(w,controls,boundaries)
    active(e)=sort([c for c in controls if c["eta_start"]<e<c["eta_end"]];by=c->movable_chord_coordinate(c,"front_spar",e))
    fixed_interval(rows,e)=begin
        lo=0.;hi=1.
        for c in rows
            x=movable_chord_coordinate(c,"front_spar",e)
            c["edge"]=="leading" ? (lo=max(lo,x)) : (hi=min(hi,x))
        end
        (lo,hi)
    end
    # No shared edge exists when the fixed portions on either side of a station
    # are disjoint. Their lane topologies need not constrain one another.
    breaks=[1]
    for j in 2:length(boundaries)-1
        e=boundaries[j]
        a=fixed_interval(active((boundaries[j-1]+e)/2),e)
        b=fixed_interval(active((e+boundaries[j+1])/2),e)
        max(a[1],b[1])>=min(a[2],b[2])&&push!(breaks,j)
    end
    push!(breaks,length(boundaries));programs=NamedTuple[]
    for (first,last) in zip(breaks[1:end-1],breaks[2:end])
        stations=boundaries[first:last];a=stations[1];b=stations[end]
        rows=[(row=c,a=max(a,c["eta_start"]),b=min(b,c["eta_end"])) for c in controls if max(a,c["eta_start"])<min(b,c["eta_end"])]
        assignment=Dict{String,Int}();nlanes=0
        for edge in ("leading","trailing")
            edge_rows=sort(filter(c->c.row["edge"]==edge,rows);by=c->c.a)
            ranks,count=aerodynamic_lane_ranks(edge_rows)
            for (name,rank) in ranks;assignment[name]=nlanes+rank;end
            nlanes+=count
        end
        anchors=[Dict{Float64,Float64}() for _ in 1:nlanes]
        for c in rows,e in (c.a,c.b)
            anchors[assignment[c.row["name"]]][e]=movable_chord_coordinate(c.row,"front_spar",e)
        end
        function nominal(i,e)
            eta=sort!(collect(keys(anchors[i])));ordinate=[anchors[i][x] for x in eta]
            e<=eta[1]&&return ordinate[1];e>=eta[end]&&return ordinate[end]
            j=searchsortedlast(eta,e);t=(e-eta[j])/(eta[j+1]-eta[j])
            (1-t)*ordinate[j]+t*ordinate[j+1]
        end
        values=zeros(nlanes+2,length(stations))
        for (j,e) in enumerate(stations)
            v=vcat(0.,[nominal(i,e) for i in 1:nlanes],1.)
            pinned=Dict(1=>0.,nlanes+2=>1.)
            for c in rows
                c.a<=e<=c.b||continue
                i=assignment[c.row["name"]]+1;x=movable_chord_coordinate(c.row,"front_spar",e)
                haskey(pinned,i)&&pinned[i]!=x&&error("Inconsistent shared control endpoint")
                pinned[i]=x;v[i]=x
            end
            indices=sort!(collect(keys(pinned)))
            for (lo,hi) in zip(indices[1:end-1],indices[2:end])
                v[lo]<v[hi]||error("Collapsed fixed-wing lane interval")
                if !all(diff(v[lo:hi]).>0)
                    # Only unpinned virtual lanes move. Authored control cuts
                    # and slopes remain exact; ordered station values cannot
                    # cross under linear interpolation between stations.
                    for i in lo+1:hi-1;v[i]=v[lo]+(v[hi]-v[lo])*(i-lo)/(hi-lo);end
                end
            end
            all(diff(v).>0)||throw(ArgumentError("Control cut spacing is below coordinate precision"))
            values[:,j].=v
        end
        push!(programs,(stations=stations,values=values,control_lane=assignment,controls=[c.row for c in rows]))
    end
    programs
end

function aerodynamic_lane_counts(program,s)
    widths=vec(maximum(diff(program.values;dims=1);dims=2))
    counts=max.(1,ceil.(Int,widths.*s["chord_panels"].-1e-10))
    for c in program.controls
        lane=program.control_lane[c["name"]]
        zones=c["edge"]=="leading" ? (1:lane) : (lane+1:length(counts))
        width=maximum(sum(program.values[i+1,j]-program.values[i,j] for i in zones) for j in axes(program.values,2))
        base=max(1,ceil(Int,width*s["chord_panels"]-1e-10))
        target=max(s["control_chord_panels"]+1,base+1,ceil(Int,1.25base))
        while sum(counts[zones])<target
            i=collect(zones)[argmax([widths[i]/counts[i] for i in zones])];counts[i]+=1
        end
    end
    if s["chord_spacing"]=="uniform"
        h=minimum(minimum(program.values[i+1,:].-program.values[i,:])/counts[i] for i in eachindex(counts))
        counts=max.(counts,ceil.(Int,widths./h.-1e-10))
    end
    counts
end

function aerodynamic_mesh(w,controls,s;progress=(stage,done,total)->nothing)
    vlm_checked_size("VLM requested grid",3,s["chord_panels"]+1,s["span_panels"]+1)
    material=Dict(c["name"]=>movable_material_interval(w,c) for c in controls)
    gaps=Dict(c["name"]=>aerodynamic_control_gap(w,c) for c in controls)
    detached=Dict((side,c["name"])=>gaps[c["name"]]&&!iszero(aerodynamic_motion_angle(w,c,side,s["controls"][c["name"]])) for side in ("left","right") for c in controls)
    # A detached sheet can trim its own span without splitting adjacent fixed
    # skin. A sealed sheet needs span topology changes at its material ends so
    # the central sheet stays joined and the actual end holes remain open.
    # At zero motion an offset hinge still has coincident material. Keep that
    # sheet joined: separate tessellations of a curved seam can cross, and a
    # fictitious internal trailing edge must not shed a neutral-control wake.
    trim_stations=[e for c in controls if any(!detached[(side,c["name"])] for side in ("left","right")) for e in material[c["name"]]]
    boundaries=with_planform_stations(w,sort!(unique(vcat(0.,1.,w.airfoil_etas,loft_control_etas(w),[c[k] for c in controls for k in ("eta_start","eta_end")],trim_stations))))
    programs=aerodynamic_lane_programs(w,controls,boundaries)
    cosine=s["chord_spacing"]=="cosine";patches=NamedTuple[]
    for program in programs
        counts=aerodynamic_lane_counts(program,s);accepted=false
        for refinement in 1:10
            candidate=NamedTuple[];failed=false
            knots=vcat([i-1+aerodynamic_spacing(k/counts[i],s["chord_spacing"]) for i in eachindex(counts) for k in 0:counts[i]-1],Float64(length(counts)))
            function band(side,a,b,depth=0)
                depth<=12||return false
                mid=(a+b)/2
                active=sort([c for c in controls if c["eta_start"]<mid<c["eta_end"]];by=c->movable_chord_coordinate(c,"front_spar",mid))
                seams=Set(i for i in eachindex(active) if detached[(side,active[i]["name"])]||!(material[active[i]["name"]][1]<mid<material[active[i]["name"]][2]))
                groups=UnitRange{Int}[];firstzone=1
                for i in eachindex(active)
                    if i in seams;push!(groups,firstzone:i);firstzone=i+1;end
                end
                push!(groups,firstzone:length(active)+1)
                start_count=length(candidate)
                for component in groups
                    firstlane=first(component)==1 ? 0 : program.control_lane[active[first(component)-1]["name"]]
                    lastlane=last(component)>length(active) ? length(counts) : program.control_lane[active[last(component)]["name"]]
                    local_knots=filter(x->firstlane<=x<=lastlane,knots)
                    function chord_coordinate(e,xi)
                        z=aerodynamic_lane_values(program,e);i=min(floor(Int,xi)+1,length(z)-1);t=xi-(i-1)
                        (1-t)*z[i]+t*z[i+1]
                    end
                    element_name="fixed wing"
                    for idx in seams
                        row=active[idx]
                        if row["edge"]=="trailing" ? first(component)>idx : last(component)<=idx;element_name="control: "*row["name"];end
                    end
                    # Keep the authored fixed-wing cutout in an end gap. Only
                    # the moving material disappears; no fixed skin fills it.
                    moving=findfirst(c->element_name=="control: "*c["name"],active)
                    ca,cb=a,b
                    if moving!==nothing
                        ma,mb=material[active[moving]["name"]]
                        ca,cb=max(a,ma),min(b,mb)
                        ca<cb||continue
                    end
                    cmid=(ca+cb)/2
                    function point(e,x)
                        v=camber_point(w,e,x)
                        for (idx,row) in enumerate(active)
                            idx in seams&&((row["edge"]=="trailing"&&last(component)<=idx)||(row["edge"]=="leading"&&first(component)>idx))&&continue
                            v=aerodynamic_control_point(w,row,e,x,v,aerodynamic_motion_angle(w,row,side,s["controls"][row["name"]]))
                        end
                        v
                    end
                    samples=collect(range(ca,cb;length=65));weighted=[0.]
                    for (u,v) in zip(samples[1:end-1],samples[2:end])
                        e=(u+v)/2;density=(s["span_spacing"]=="cosine" ? 1+.15*cospi(e)^8 : 1.)+.15*sum(exp(-abs(e-k)/.025) for k in boundaries[2:end-1];init=0.)
                        push!(weighted,last(weighted)+norm3(camber_point(w,v,.5).-camber_point(w,u,.5))/chord(w,e)*density)
                    end
                    last(weighted)>0||throw(ArgumentError("Collapsed aerodynamic span interval"))
                    inverse(t)=begin
                        t==0&&return ca;t==1&&return cb
                        q=t*last(weighted);i=clamp(searchsortedlast(weighted,q),1,length(samples)-1)
                        samples[i]+(samples[i+1]-samples[i])*(q-weighted[i])/(weighted[i+1]-weighted[i])
                    end
                    actualh=minimum(minimum(diff([chord_coordinate(e,xi) for xi in local_knots])) for e in (ca,cmid,cb))
                    actualh>0||throw(ArgumentError("Collapsed aerodynamic chord interval"))
                    n=max(1,ceil(Int,s["span_panels"]*(cb-ca)),ceil(Int,last(weighted)/actualh/(cosine ? 1.3 : 1.)))
                    valid=false
                    for attempt in 1:8
                        vlm_checked_size("VLM coordinate grid",3,length(local_knots),Base.checked_add(n,1))
                        spans=[inverse(aerodynamic_span_fraction(j/n,s["span_spacing"];cosine_chord=cosine)) for j in 0:n]
                        grid=Array{Float64}(undef,3,length(local_knots),length(spans));xcs=Matrix{Float64}(undef,length(local_knots),length(spans))
                        for (j,e) in enumerate(spans),(i,xi) in enumerate(local_knots);xcs[i,j]=chord_coordinate(e,xi);grid[:,i,j].=point(e,xcs[i,j]);end
                        if side=="left";grid=grid[:,:,end:-1:1];grid[2,:,:].=2w.root_ref_y.-grid[2,:,:];xcs=xcs[:,end:-1:1];end
                        metrics=validate_vlm_grid(grid);lo=minimum(first(aerodynamic_aspect(m)) for m in metrics);hi=maximum(last(aerodynamic_aspect(m)) for m in metrics)
                        geometryok=maximum(m.warp_deg for m in metrics)<=s["max_panel_warp"]&&maximum(m.control_normal_error_deg for m in metrics)<=s["max_normal_error"]&&maximum(abs(rad2deg(twist(w,spans[j+1])-twist(w,spans[j]))) for j in 1:n)<=s["max_strip_twist"]
                        progress("Checking 3D mesh quality: $side, $(length(metrics)) panels in conforming span patch",0,1)
                        if (cosine||lo>=.7-1e-9)&&hi<=1.5+1e-9&&geometryok
                            z=vcat(0.,[movable_chord_coordinate(c,"front_spar",cmid) for c in active],1.)
                            xis=map(local_knots) do xi
                                x=chord_coordinate(cmid,xi);k=clamp(searchsortedlast(z,x),1,length(z)-1);k-1+(x-z[k])/(z[k+1]-z[k])
                            end
                            push!(candidate,(grid=grid,metrics=metrics,xis=xis,chord_coordinates=xcs,etas=side=="left" ? reverse(spans) : spans,side=side,element_name=element_name,zone_range=component,split_boundaries=copy(seams),name=side*" / chord zones $(first(component)):$(last(component)) / "*(isempty(active) ? "fixed wing" : join([c["name"] for c in active]," + ")),active=active))
                            valid=true;break
                        end
                        if !geometryok;n=ceil(Int,1.6n);continue;end
                        lower=max(1,ceil(Int,n*hi/1.5-1e-8));upper=cosine ? typemax(Int) : floor(Int,n*lo/.7+1e-8)
                        lower>upper&&break
                        next=cosine ? max(lower,ceil(Int,n*hi/1.35)) : clamp(round(Int,n*sqrt(lo*hi)/sqrt(.7*1.5)),lower,upper)
                        next==n&&break;n=next
                    end
                    if !valid
                        resize!(candidate,start_count)
                        split=inverse(.5)
                        return band(side,a,split,depth+1)&&band(side,split,b,depth+1)
                    end
                end
                true
            end
            for side in ("left","right"),(a,b) in zip(program.stations[1:end-1],program.stations[2:end])
                if !band(side,a,b);failed=true;break;end
            end
            if !failed;append!(patches,candidate);accepted=true;break;end
            # A change in chord resolution applies to the entire connected
            # sheet, preserving shared knots across every retry and span split.
            counts=max.(counts.+1,ceil.(Int,1.35.*counts))
        end
        accepted||throw(ArgumentError("Cannot meet VLM geometry/aspect quality with a conforming chord mesh; inspect closely spaced control cuts and loft changes"))
    end
    patches
end
