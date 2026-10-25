"""Move regular interior ribs to attachment stations, then fill excessive gaps.

The inboard/outboard closure ribs are immutable. When there are more masters
than interior ribs, only the necessary additional master ribs are inserted.
"""
function movable_master_rib_layout(a,b,row,attachments)
    nominal=(b-a)/row["span_bays"]
    ribs=[Dict{String,Any}("eta"=>eta,"attachment"=>0,"closure"=>i in (1,row["span_bays"]+1)) for (i,eta) in enumerate(range(a,b;length=row["span_bays"]+1))]
    for ai in sortperm(attachments;by=x->x["eta"])
        eta=attachments[ai]["eta"]
        coincident=findfirst(r->abs(r["eta"]-eta)<1e-10,ribs)
        if coincident!==nothing
            ribs[coincident]["attachment"]=ai
            continue
        end
        available=findall(r->!r["closure"]&&r["attachment"]==0,ribs)
        if isempty(available)
            push!(ribs,Dict{String,Any}("eta"=>eta,"attachment"=>ai,"closure"=>false))
        else
            index=available[argmin([abs(ribs[i]["eta"]-eta) for i in available])]
            ribs[index]["eta"]=eta;ribs[index]["attachment"]=ai
        end
    end
    sort!(ribs;by=r->r["eta"])
    maximum_pitch=get(row,"max_rib_pitch_ratio",1.5)*nominal
    i=1
    while i<length(ribs)
        lo,hi=ribs[i]["eta"],ribs[i+1]["eta"]
        if hi-lo>maximum_pitch*(1+1e-12)
            insert!(ribs,i+1,Dict{String,Any}("eta"=>(lo+hi)/2,"attachment"=>0,"closure"=>false,"gap_refinement"=>true))
        else
            i+=1
        end
    end
    ribs
end

"""Partition around a real secondary spar, without adding a near-duplicate row."""
function movable_chord_stations(row)
    n=row["chord_elements"];secondary=row["secondary_spar"]
    secondary<=0&&return collect(range(0.,1.;length=n+1))
    min(secondary,1-secondary)>=1/(100max(n,2))||throw(ArgumentError("$(row["surface"]): the secondary spar is too close to a control boundary for this chord mesh. Increase chord elements or move the secondary spar; its exact location cannot be merged with another spar to hide a slender cell."))
    # Keep both physical spar positions exact. Allocate the requested cells
    # between their intervals, then redistribute each interval uniformly.
    n=max(n,2);left=clamp(round(Int,n*secondary),1,n-1)
    vcat(collect(range(0.,secondary;length=left+1)),collect(range(secondary,1.;length=n-left+1))[2:end])
end

"""Retain physical ribs and geometry anchors; repartition their intervals."""
function movable_span_stations(w,row,rib_etas)
    scalar_stations(etas,values,method)=method===:linear ? first(physical_polyline(etas,values)) : etas
    anchors=movable_distinct_stations(vcat(planform_breakpoints(w),w.airfoil_etas,
        scalar_stations(w.thickness_etas,w.thickness_values,w.thickness_interpolation),
        scalar_stations(w.twist_etas,w.twist_values,w.twist_interpolation),
        scalar_stations(w.vertical_shift_etas,w.vertical_shift_values,w.vertical_shift_interpolation)))
    result=Float64[]
    for (lo,hi) in zip(rib_etas[1:end-1],rib_etas[2:end])
        target=(hi-lo)/row["span_elements"]
        cuts=movable_distinct_stations(vcat(lo,filter(t->lo+1e-10<t<hi-1e-10,anchors),hi))
        for (a,b) in zip(cuts[1:end-1],cuts[2:end])
            b-a>=target/100||throw(ArgumentError("$(row["surface"]): a required geometry station and rib/geometry station at eta $a and $b are nearly coincident. Move the geometry station or rib, or refine the movable span mesh; preserving both in this mesh would create an extremely slender skin strip."))
            n=max(1,round(Int,(b-a)/target))
            append!(result,[a+(b-a)*i/n for i in 0:n-1])
        end
    end
    push!(result,last(rib_etas))
    result
end

"""Reject collapsed, inverted or extremely slender control skins explicitly."""
function validate_movable_skin_cell(reg,nodes,label)
    pts=[reg.xyz[3n-2:3n] for n in nodes];n=length(pts)
    edges=[pts[i%n+1].-pts[i] for i in 1:n];lengths=sqrt.([sum(abs2,e) for e in edges])
    longest=maximum(lengths);shortest=minimum(lengths)
    longest>0&&shortest>longest/100||throw(ArgumentError("$label: skin edge aspect ratio exceeds 100 or the cell has collapsed. Separate physical ribs/spars or refine the longer mesh direction; no element has been silently removed."))
    triangles=[cross3(pts[i].-pts[1],pts[i+1].-pts[1]) for i in 2:n-1]
    normal=ntuple(k->sum(t[k] for t in triangles),3)
    area2=sqrt(sum(abs2,normal));area2>1e-10*longest^2||throw(ArgumentError("$label: control skin has zero area; check its rib, hinge and spar geometry."))
    for i in 1:n
        corner=cross3(edges[i],.-edges[mod1(i-1,n)])
        jacobian=sum(corner.*normal)/(lengths[i]*lengths[mod1(i-1,n)]*area2)
        jacobian>sinpi(1/180)||throw(ArgumentError("$label: a control skin corner is inverted or narrower than one degree. Move the attachment ribs apart or reduce their obliquity; the invalid cell has not been exported."))
    end
    nothing
end

function movable_attachment_planes(g,s,row,rot,attachments)
    a,b=s["eta_start"],movable_structural_end(row,s);delta=rot.h1.-rot.h0
    map(attachments) do original
        attachment=copy(original);eta=attachment["eta"];jr=g.ribs[attachment["rib"]]
        column=attachment["spar"]=="front" ? 0 : ni(g)
        anchor=(grid_point(g,column,jr,0).+grid_point(g,column,jr,g.nh))./2
        center_at(normal)=begin
            denominator=sum(normal.*delta)
            abs(denominator)>max(g.wing.mac,1.)*1e-12||throw(ArgumentError("$(s["name"]): hinge line is parallel to the attachment plane"))
            t=sum(normal.*(anchor.-rot.h0))/denominator
            rot.h0.+t.*delta,s["eta_start"]+t*(s["eta_end"]-s["eta_start"])
        end
        normal=s["kind"]=="flap" ? (0.,1.,0.) : rot.axis
        center,hinge_eta=center_at(normal);clearance=0.;underside=false;requested_ratio=0.;actual_ratio=0.
        for iteration in 1:4
            center,hinge_eta=center_at(normal)
            section_eta=clamp(hinge_eta,a,b)
            chordvec=section_point(g.wing,section_eta,1.,0.).-section_point(g.wing,section_eta,0.,0.)
            chordlen=sqrt(sum(abs2,chordvec));chordaxis=chordvec./chordlen
            front=(upper_point(g.wing,section_eta,rot.front_spar(section_eta)).+lower_point(g.wing,section_eta,rot.front_spar(section_eta)))./2
            clearance=sum((front.-center).*chordaxis)/chordlen
            requested_ratio=movable_chord_coordinate(s,"hinge_z",section_eta)
            leading=section_point(g.wing,section_eta,0.,0.)
            xc=clamp(sum((center.-leading).*chordaxis)/chordlen,0.,1.)
            lo,up=lower_point(g.wing,section_eta,xc),upper_point(g.wing,section_eta,xc)
            thickness=up.-lo;thickness2=sum(abs2,thickness)
            actual_ratio=thickness2>eps(chordlen)^2 ? sum((center.-(lo.+up)./2).*thickness)/thickness2 : requested_ratio
            # The hinge is straight between its endpoints; with twist/camber
            # its local height need not equal an interpolation of endpoint z/t.
            # Both the requested limit and the actual lower contour must be
            # crossed. The exact -0.5 boundary remains a front-spar fitting.
            underside=attachment["fitting"]=="shell_lugs"&&s["edge"]=="trailing"&&requested_ratio<-.5-1e-12&&actual_ratio<-.5-1e-12
            desired=s["kind"]=="flap"&&!underside ? (0.,1.,0.) : rot.axis
            sum(abs2,desired.-normal)<1e-20&&break
            iteration==4&&throw(ArgumentError("$(s["name"]): the hinge crosses the lower airfoil contour when its master rib rotates. Adjust hinge z/t slightly to choose a stable fitting layout"))
            normal=desired
        end
        a-1e-10<=hinge_eta<=b+1e-10||throw(ArgumentError("$(s["name"]): the attachment plane at rib $(attachment["rib"]) meets the hinge outside the control structure; select an interior rib or adjust the hinge"))
        merge!(attachment,Dict("hinge_center"=>center,"hinge_eta"=>hinge_eta,"plane_normal"=>normal,"underside_lug"=>underside,"front_spar_clearance_c"=>clearance,
            "requested_hinge_z_t"=>requested_ratio,"actual_hinge_z_t"=>actual_ratio))
        attachment
    end
end

"""Conforming master-rib grid: every physical rib node lies in its own plane."""
function movable_rib_eta_grid(w,s,row,rot,ribs,attachments,us,nh)
    a,b=s["eta_start"],movable_structural_end(row,s);edge=s["edge"]=="trailing" ? 1. : 0.
    result=zeros(length(us),length(ribs),nh+1)
    point(eta,u,k)=begin
        xc=rot.front_spar(eta)+(edge-rot.front_spar(eta))*u
        lo,up=lower_point(w,eta,xc),upper_point(w,eta,xc)
        rot.rotate(lo.+(k/nh).*(up.-lo))
    end
    tolerance=max(w.mac,1.)*1e-11
    for (ri,rib) in enumerate(ribs),i in eachindex(us),k in 0:nh
        ai=rib["attachment"]
        if ai==0||attachments[ai]["fitting"]!="shell_lugs"
            result[i,ri,k+1]=rib["eta"];continue
        end
        attachment=attachments[ai];normal=attachment["plane_normal"];origin=attachment["hinge_center"]
        f(eta)=sum(normal.*(point(eta,us[i],k).-origin))
        if rib["closure"]
            abs(f(rib["eta"]))<=tolerance||throw(ArgumentError("$(s["name"]): an oblique attachment master rib cannot replace the fixed span-end closure. Select an interior main-box rib or change the hinge alignment"))
            result[i,ri,k+1]=rib["eta"];continue
        end
        lo,hi=a,b;flo,fhi=f(lo),f(hi)
        flo*fhi<=0||throw(ArgumentError("$(s["name"]): the attachment master-rib plane extends outside the control span. Move the attachment inward or reduce its sweep"))
        for iteration in 1:60
            mid=(lo+hi)/2;fm=f(mid)
            if abs(fm)<=tolerance;lo=hi=mid;break;end
            if signbit(fm)==signbit(flo);lo=mid;flo=fm;else;hi=mid;end
        end
        result[i,ri,k+1]=(lo+hi)/2
    end
    for i in eachindex(us),k in 0:nh,ri in 1:length(ribs)-1
        result[i,ri+1,k+1]-result[i,ri,k+1]>1e-9||throw(ArgumentError("$(s["name"]): adjacent movable master ribs cross on the control surface. Move the attachments apart or change their hinge alignment"))
    end
    result
end

"""Reject a lower-skin lug that enters the actual closed master-rib polygon."""
function movable_underside_fitting(reg,lower,upper,center,normal,label)
    pos(n)=reg.xyz[3n-2:3n]
    chord=pos(last(lower)).-pos(first(lower));chord=chord./sqrt(sum(abs2,chord))
    vertical=cross3(normal,chord);vertical=vertical./sqrt(sum(abs2,vertical))
    project(point)=(sum(point.*chord),sum(point.*vertical))
    hinge=project(center);poly=[project(pos(n)) for n in vcat(lower,reverse(upper))]
    lp=[project(pos(n)) for n in lower]
    cross2(a,b,c)=(b[1]-a[1])*(c[2]-a[2])-(b[2]-a[2])*(c[1]-a[1])
    tolerance=1e-11*max(1.,sum(abs2,chord))
    function inside_polygon(point)
        inside=false
        for (a,b) in zip(poly,vcat(poly[2:end],poly[1:1]))
            abs(cross2(a,b,point))<=tolerance&&min(a[1],b[1])-tolerance<=point[1]<=max(a[1],b[1])+tolerance&&min(a[2],b[2])-tolerance<=point[2]<=max(a[2],b[2])+tolerance&&return false
            if (a[2]>point[2])!=(b[2]>point[2])
                point[1]<(b[1]-a[1])*(point[2]-a[2])/(b[2]-a[2])+a[1]&&(inside=!inside)
            end
        end
        inside
    end
    inside_polygon(hinge)&&throw(ArgumentError("$label: the hinge is inside the closed control section. Lower hinge z/t so the underside fitting remains outside the skin"))
    function exterior_triangle(triangle)
        abs(cross2(triangle...))>tolerance||return false
        inside_triangle(point)=begin
            v=[cross2(triangle[i],triangle[i%3+1],point) for i in 1:3]
            all(>(tolerance),v)||all(<(-tolerance),v)
        end
        any(inside_triangle,poly)&&return false
        for (ta,tb) in zip(triangle,(triangle[2],triangle[3],triangle[1])),(pa,pb) in zip(poly,vcat(poly[2:end],poly[1:1]))
            cross2(ta,tb,pa)*cross2(ta,tb,pb)<-tolerance^2&&cross2(pa,pb,ta)*cross2(pa,pb,tb)<-tolerance^2&&return false
        end
        midpoint=((triangle[1][1]+triangle[2][1]+triangle[3][1])/3,(triangle[1][2]+triangle[2][2]+triangle[3][2])/3)
        !inside_polygon(midpoint)
    end
    # Every lower fitting starts at the lower front-spar node. Extend a
    # conforming fan along the existing lower-rib edges to the hinge region;
    # choosing only its closest skin cell left the spar outside the load path.
    order=sortperm([abs((lp[i][1]+lp[i+1][1])/2-hinge[1]) for i in 1:length(lp)-1])
    for index in order
        if all(i->exterior_triangle((lp[i],lp[i+1],hinge)),1:index)
            return (foot_nodes=lower[1:index+1],triangles=[(lower[i],lower[i+1],0) for i in 1:index],knee_point=nothing,shape="front-spar-connected lower fan")
        end
    end
    # A hinge ahead of the front web can be above the lower skin without being
    # inside the box. Route a compact two-triangle knee around its lower-front
    # corner instead of cutting through the web or changing the user's hinge.
    area2=sum(a[1]*b[2]-b[1]*a[2] for (a,b) in zip(poly,vcat(poly[2:end],poly[1:1])))
    orientation=sign(area2)
    outward(a,b)=begin
        dx,dy=b[1]-a[1],b[2]-a[2];len=hypot(dx,dy)
        len>sqrt(tolerance)||throw(ArgumentError("$label: the front-lower corner has a degenerate boundary edge"))
        (orientation*dy/len,-orientation*dx/len)
    end
    a,b=lp[1],lp[2];front=outward(project(pos(first(upper))),a);bottom=outward(a,b)
    if sum((hinge[i]-a[i])*front[i] for i in 1:2)>sqrt(tolerance)
        bisector=front.+bottom;bisector_length=sqrt(sum(abs2,bisector))
        if bisector_length>1e-8
            distance=.5min(hypot(hinge[1]-a[1],hinge[2]-a[2]),hypot(b[1]-a[1],b[2]-a[2]))
            knee=a.+distance.*bisector./bisector_length
            if exterior_triangle((hinge,a,knee))&&exterior_triangle((a,b,knee))
                point=pos(first(lower)).+(knee[1]-a[1]).*chord.+(knee[2]-a[2]).*vertical
                return (foot_nodes=[lower[1],lower[2]],triangles=[(0,lower[1],-1),(lower[1],lower[2],-1)],knee_point=point,shape="exterior knee")
            end
        end
    end
    throw(ArgumentError("$label: no external underside fitting fits between this hinge and the lower skin without crossing the control section. Lower hinge z/t or move the hinge forward."))
end
