"""Native CAD construction for the current authored wing, in millimetres.

The aerodynamic loft is evaluated from the same Wing functions used by Boxer.
Structural profiles use the authored physical grid and property definitions.
Generated coordinate-system IDs use a private geometric mesh to resolve their
authored axes. The export plan is constructed from a copy of the study inputs.
"""

solidcraft_command(name, parameters) = Dict{String,Any}("command"=>name, "params"=>parameters)
# Native cap construction is sensitive to long binary tails in very thin
# profiles. A 0.1 nm CAD coordinate grid is far below the loft tolerance and
# keeps authored coincident section edges numerically coincident in the kernel.
solidcraft_mm(point) = [round(1000.0 * Float64(value);digits=7) for value in point]
solidcraft_project(point,origin,x,y) = [round(1000sum((point.-origin).*axis);digits=7) for axis in (x,y)]

function solidcraft_clean_loop(points)
    clean = NTuple{3,Float64}[]
    for point in points
        length(point)==3 && all(isfinite,point) || throw(ArgumentError("SolidCraft profile contains an invalid point"))
        value=Tuple(Float64.(point))
        (isempty(clean) || norm3(value.-last(clean))>1e-10) && push!(clean,value)
    end
    length(clean)>1 && norm3(first(clean).-last(clean))<=1e-10 && pop!(clean)
    length(clean)>=3 || throw(ArgumentError("SolidCraft profile has fewer than three distinct points"))
    clean
end

"""An orthonormal sketch plane and a closed planar polygon in native CAD units."""
function solidcraft_polygon(points; normal=nothing)
    loop=solidcraft_clean_loop(points)
    origin=first(loop);x=unit3(loop[2].-origin)
    n=normal
    if n===nothing
        area=foldl((a,b)->a.+b,
            (cross3(loop[i].-origin,loop[i+1].-origin) for i in 2:length(loop)-1);init=(0.,0.,0.))
        norm3(area)>1e-16 || throw(ArgumentError("SolidCraft profile has zero enclosed area"))
        n=unit3(area)
    end
    n=unit3(n);x=unit3(x.-sum(x.*n).*n);y=unit3(cross3(n,x))
    norm3(x)>.9 && norm3(y)>.9 || throw(ArgumentError("SolidCraft profile plane is undefined"))
    scale=max(1.,maximum(norm3(point.-origin) for point in loop))
    maximum(abs(sum((point.-origin).*n)) for point in loop)<=1e-8*scale ||
        throw(ArgumentError("A structural CAD profile is not planar. Review its rib or stringer geometry."))
    points2=[solidcraft_project(point,origin,x,y) for point in loop]
    Dict{String,Any}("origin_mm"=>solidcraft_mm(origin),"x_dir"=>collect(x),"y_dir"=>collect(y),"points_mm"=>points2)
end

function solidcraft_profile_commands(name, profile)
    commands=Any[solidcraft_command("sketch.create",Dict("name"=>name,"plane"=>Dict(
        "origin"=>profile["origin_mm"],"x_dir"=>profile["x_dir"],"y_dir"=>profile["y_dir"])))]
    if haskey(profile,"curves_mm")
        curves=profile["curves_mm"]
        for (index,curve) in enumerate(curves)
            push!(commands,solidcraft_command("sketch.spline.fit_point",Dict("points"=>curve)))
            following=curves[mod1(index+1,length(curves))]
            hypot((last(curve).-first(following))...)>1e-6 && push!(commands,
                solidcraft_command("sketch.line",Dict("points"=>[last(curve),first(following)])))
        end
    else
        push!(commands,solidcraft_command("sketch.line",Dict("points"=>profile["points_mm"],"closed"=>true)))
    end
    push!(commands,solidcraft_command("sketch.finish",Dict{String,Any}()))
    commands
end

"""Append one independently named, closed native solid and its editable profiles."""
function solidcraft_add_body!(bodies, label, group, profiles; color="#77b7dc", opacity=1., thickness=nothing,
                             metadata=Dict{String,Any}())
    length(profiles)>0 || throw(ArgumentError("SolidCraft body $label has no profiles"))
    thickness===nothing && !(2<=length(profiles)<=50) &&
        throw(ArgumentError("SolidCraft loft $label needs between two and fifty profiles"))
    name="JFEM_"*lpad(length(bodies)+1,4,'0')*"_"*replace(label,r"[^A-Za-z0-9_]+"=>"_")
    commands=Any[];sections=Any[]
    for (index,profile) in enumerate(profiles)
        sketch=name*"_Section_"*lpad(index,3,'0')
        append!(commands,solidcraft_profile_commands(sketch,profile))
        push!(sections,Dict("sketch"=>sketch))
    end
    if thickness===nothing
        if haskey(first(profiles),"points_mm") && group in ("Spar webs","Stringers","Spar caps","Rib stiffeners","Engine beams","Actuator symbols")
            # The native automatic solid-loft cap can reject valid thin,
            # oblique profiles. Capping with each original sketch plane and
            # stitching preserves those exact sections and yields one solid.
            push!(commands,solidcraft_command("surface.loft",Dict("sections"=>sections,
                "name"=>name*"_Loft","body_name"=>name)))
            push!(commands,solidcraft_command("surface.patch",Dict("sketch"=>first(sections)["sketch"],"body_name"=>name*"_StartCap")))
            push!(commands,solidcraft_command("surface.patch",Dict("sketch"=>last(sections)["sketch"],"body_name"=>name*"_EndCap")))
            push!(commands,solidcraft_command("surface.stitch",Dict("bodies"=>[name,name*"_StartCap",name*"_EndCap"])))
        else
            push!(commands,solidcraft_command("solid.loft",Dict("sections"=>sections,
                "operation"=>"new","name"=>name*"_Loft","body_name"=>name)))
        end
    else
        isfinite(thickness) && thickness>0 || throw(ArgumentError("$label needs a positive thickness"))
        push!(commands,solidcraft_command("solid.extrude",Dict("sketch"=>sections[1]["sketch"],
            "distance"=>1000thickness,"direction"=>"symmetric","operation"=>"new",
            "name"=>name*"_Extrude","body_name"=>name)))
    end
    push!(commands,solidcraft_command("appearance.assign",Dict("bodies"=>[name],"color"=>color,"opacity"=>opacity)))
    push!(bodies,Dict{String,Any}("name"=>name,"label"=>label,"group"=>group,
        "kind"=>thickness===nothing ? "loft" : "extrusion","color"=>color,"opacity"=>opacity,
        "commands"=>commands,"metadata"=>metadata))
    name
end

solidcraft_reflect(point, mirror, root_y) = mirror ? (point[1],2root_y-point[2],point[3]) : Tuple(point)

"""Profile points and its transformed plane retain physical camber and hinge height."""
function solidcraft_airfoil_profile(w, eta, front, rear; motion=identity, mirror=false)
    0<=front<rear<=1 || throw(ArgumentError("The CAD loft has a crossed or collapsed chord interval at eta $eta"))
    fractions=[(1-cospi(k/64))/2 for k in 0:64]
    xcs=front.+(rear-front).*fractions
    transform(point)=solidcraft_reflect(motion(point),mirror,w.root_ref_y)
    origin=transform((0.,w.root_ref_y+w.semispan*eta,0.))
    axisx=unit3(transform((1.,w.root_ref_y+w.semispan*eta,0.)).-origin)
    axisy=unit3(transform((0.,w.root_ref_y+w.semispan*eta,1.)).-origin)
    project(point)=solidcraft_project(transform(point),origin,axisx,axisy)
    upper=[project(upper_point(w,eta,xc)) for xc in xcs]
    lower=[project(lower_point(w,eta,xc)) for xc in reverse(xcs)]
    # Native loft sections must enclose a positive airfoil area.
    solidcraft_polygon(vcat([transform(upper_point(w,eta,xc)) for xc in xcs],
        [transform(lower_point(w,eta,xc)) for xc in reverse(xcs)]))
    Dict{String,Any}("origin_mm"=>solidcraft_mm(origin),"x_dir"=>collect(axisx),"y_dir"=>collect(axisy),
        "curves_mm"=>[upper,lower])
end

function solidcraft_span_samples(w, start, stop, boundaries, tolerance; bounds=nothing)
    stations=sort!(unique(vcat(start,stop,filter(eta->start<eta<stop,boundaries))))
    # Midpoint deviation is measured independently of the CAD kernel, using
    # both surfaces at fixed chord fractions and the actual authored loft.
    function refine(a,b,depth)
        middle=(a+b)/2
        error=maximum(norm3(point(w,middle,xc).-(point(w,a,xc).+point(w,b,xc))./2)
            for point in (upper_point,lower_point) for xc in (0.,.1,.25,.5,.75,1.))
        if bounds!==nothing
            fa,ra=bounds(a);fm,rm=bounds(middle);fb,rb=bounds(b)
            moving_error=maximum(norm3(point(w,middle,fm+(rm-fm)*fraction).-
                (point(w,a,fa+(ra-fa)*fraction).+point(w,b,fb+(rb-fb)*fraction))./2)
                for point in (upper_point,lower_point) for fraction in (0.,.1,.25,.5,.75,1.))
            error=max(error,moving_error)
        end
        if error>tolerance && depth<12
            return vcat(refine(a,middle,depth+1)[1:end-1],refine(middle,b,depth+1))
        end
        [a,b]
    end
    samples=Float64[]
    for i in 1:length(stations)-1
        append!(samples,refine(stations[i],stations[i+1],0)[1:end-1])
    end
    push!(samples,stop)
    length(samples)<=2048 || throw(ArgumentError("The authored loft needs too many CAD sections. Increase the CAD sampling tolerance."))
    samples
end

function solidcraft_loft_chunks!(bodies,label,group,profiles;kwargs...)
    first=1;part=1
    while first<length(profiles)
        last=min(first+49,length(profiles))
        solidcraft_add_body!(bodies,label*"_"*string(part),group,profiles[first:last];kwargs...)
        first=last;part+=1
    end
end

function solidcraft_body_rotation!(body,motion,w,reflected)
    iszero(motion.angle) && return body
    origin=solidcraft_mm(solidcraft_reflect(motion.h0,reflected,w.root_ref_y))
    axis=reflected ? [motion.axis[1],-motion.axis[2],motion.axis[3]] : collect(motion.axis)
    angle=reflected ? -motion.angle : motion.angle
    # Move a completed neutral solid rigidly, preserving its closed cap planes.
    append!(body["commands"],[
        solidcraft_command("solid.move",Dict("bodies"=>[body["name"]],"translate"=>-origin,"copy"=>false)),
        solidcraft_command("solid.move",Dict("bodies"=>[body["name"]],"axis"=>axis,"angle"=>string(angle)*" deg","copy"=>false)),
        solidcraft_command("solid.move",Dict("bodies"=>[body["name"]],"translate"=>origin,"copy"=>false))])
    body["metadata"]["rigid_rotation"]=Dict("origin_mm"=>origin,"axis"=>axis,"angle_deg"=>angle)
    body
end

function solidcraft_outer_geometry!(bodies,w,p,mirror,deflected,tolerance,progress)
    surfaces=normalize_movable_surfaces(get(p,"movable_surfaces.items",Any[]))
    boundaries=sort!(unique(vcat(0.,1.,planform_breakpoints(w),w.airfoil_etas,loft_control_etas(w),
        [value for surface in surfaces for value in (surface["eta_start"],surface["eta_end"])])))
    for reflected in (mirror ? (false,true) : (false,))
        side=reflected ? "Left" : "Right"
        for i in 1:length(boundaries)-1
            a,b=boundaries[i:i+1];middle=(a+b)/2
            active=filter(surface->surface["eta_start"]<=middle<=surface["eta_end"],surfaces)
            front(eta)=maximum((movable_chord_coordinate(surface,"front_spar",eta) for surface in active if surface["edge"]=="leading");init=0.)
            rear(eta)=minimum((movable_chord_coordinate(surface,"front_spar",eta) for surface in active if surface["edge"]=="trailing");init=1.)
            progress("Sampling $side wing loft")
            stations=solidcraft_span_samples(w,a,b,boundaries,tolerance;
                bounds=isempty(active) ? nothing : eta->(front(eta),rear(eta)))
            profiles=[solidcraft_airfoil_profile(w,eta,front(eta),rear(eta);mirror=reflected) for eta in stations]
            solidcraft_loft_chunks!(bodies,side*"_Wing_"*string(i),"Wing outer geometry",profiles;
                color="#85bddd",opacity=.22,metadata=Dict("eta_start"=>a,"eta_end"=>b,"geometry"=>"fixed outer loft"))
        end
        for (index,surface) in enumerate(surfaces)
            a,b=movable_material_interval(w,surface)
            motion=movable_kinematics(w,surface;angle=deflected ? surface["deflection"] : 0.)
            front(eta)=surface["edge"]=="trailing" ? movable_chord_coordinate(surface,"front_spar",eta) : 0.
            rear(eta)=surface["edge"]=="trailing" ? 1. : movable_chord_coordinate(surface,"front_spar",eta)
            stations=solidcraft_span_samples(w,a,b,boundaries,tolerance;bounds=eta->(front(eta),rear(eta)))
            cuts=sort!(unique(vcat(a,b,filter(eta->a<eta<b,boundaries))))
            for segment in 1:length(cuts)-1
                lo,hi=cuts[segment:segment+1]
                samples=sort!(unique(vcat(lo,hi,filter(eta->lo<eta<hi,stations))))
                profiles=[solidcraft_airfoil_profile(w,eta,front(eta),rear(eta);mirror=reflected) for eta in samples]
                firstbody=length(bodies)+1
                solidcraft_loft_chunks!(bodies,side*"_"*surface["name"]*"_"*string(segment),"Movable surfaces",profiles;
                    color=surface["color"],opacity=.75,metadata=Dict("surface_name"=>surface["name"],
                        "deflection_deg"=>deflected ? surface["deflection"] : 0.,"eta_start"=>lo,"eta_end"=>hi))
                if deflected && !iszero(motion.angle)
                    for body in bodies[firstbody:end]
                        # Native fitted splines can lose their cap plane when
                        # authored in an oblique sketch. Move the completed
                        # neutral solid as one exact rigid CAD transformation.
                        solidcraft_body_rotation!(body,motion,w,reflected)
                    end
                end
            end
        end
    end
end

"""A thin skin section, retaining local total shell gauges along the chord."""
function solidcraft_skin_profile(points,thicknesses,normal,inward;mirror=false,root_y=0.,top_m=0.,bottom_m=nothing)
    length(points)==length(thicknesses)+1 || throw(ArgumentError("CAD skin profile/gauge membership is incomplete"))
    outer=NTuple{3,Float64}[Tuple(first(points))]
    directions=NTuple{3,Float64}[];gauges=Float64[];top_offsets=Float64[];bottom_offsets=Float64[]
    for i in eachindex(thicknesses)
        tangent=points[i+1].-points[i]
        norm3(tangent)<=1e-10 && continue
        direction=unit3(cross3(normal,tangent))
        target=inward isa AbstractVector && first(inward) isa Tuple ? inward[i].+inward[i+1] : inward
        sum(direction.*target)<0 && (direction=(-1.).*direction)
        thickness=thicknesses[i]
        isfinite(thickness)&&thickness>0 || throw(ArgumentError("A CAD skin gauge is not positive"))
        push!(directions,direction);push!(gauges,thickness);push!(outer,Tuple(points[i+1]))
        push!(top_offsets,-Float64(top_m isa Real ? top_m : top_m[i]))
        push!(bottom_offsets,bottom_m===nothing ? thickness : -Float64(bottom_m isa Real ? bottom_m : bottom_m[i]))
    end
    isempty(directions) && throw(ArgumentError("The CAD skin section has no finite chordwise interval"))
    function offset_curve(offsets)
        curve=NTuple{3,Float64}[outer[1].+offsets[1].*directions[1]]
        for i in 2:length(outer)-1
            before,after=directions[i-1],directions[i]
            bisector=before.+after;denominator=sum(bisector.*before)
            denominator>1e-8 || throw(ArgumentError("A CAD skin section folds back through itself. Review the rib and airfoil geometry."))
            # Meet offset edges at their miter, avoiding tiny crossed loops.
            push!(curve,outer[i].+(offsets[i-1]/denominator).*bisector)
            abs(offsets[i]-offsets[i-1])>1e-12 && push!(curve,outer[i].+(offsets[i]/denominator).*bisector)
        end
        push!(curve,outer[end].+offsets[end].*directions[end])
        curve
    end
    outside=offset_curve(top_offsets)
    inside=offset_curve(bottom_offsets)
    solidcraft_polygon([solidcraft_reflect(point,mirror,root_y) for point in vcat(outside,reverse(inside))])
end

function solidcraft_shell_blade_profile(g,p,i,j,upper,pid,axis;mirror=false)
    b,h,tf,tw=panel_stringer_dimensions(p,pid)
    height=b>0 ? h-tf : h
    k=upper ? g.nh : 0;row=min(j,nj(g)-1)
    base=grid_point(g,i,j,k)
    tangent=unit3(grid_point(g,i,row+1,k).-grid_point(g,i,row,k))
    direction=shell_stringer_direction(shell_stringer_inward(g,i,j,upper),axis)
    normal=unit3(cross3(tangent,direction));norm3(normal)>.9 || throw(ArgumentError("A shell stringer blade is parallel to its spanwise path"))
    tip=base.+height.*direction;offset=(tw/2).*normal
    outline=[base.-offset,tip.-offset,tip.+offset,base.+offset]
    solidcraft_polygon([solidcraft_reflect(q,mirror,g.wing.root_ref_y) for q in outline])
end

function solidcraft_beam_profile(a,b,orientation,section;mirror=false,root_y=0.)
    x=unit3(b.-a);y=unit3(orientation.-sum(x.*orientation).*x);z=unit3(cross3(x,y))
    norm3(x)>.9 && norm3(y)>.9 || throw(ArgumentError("A CAD beam has a collapsed length or section axis"))
    center=a.+Float64(section["offset_y_m"]).*y
    corners=[center.+point[1].*y.+point[2].*z for point in section["polygon_yz_m"]]
    solidcraft_polygon([solidcraft_reflect(point,mirror,root_y) for point in corners])
end

"""Structural CAD profiles share the physical layout and local property gauges."""
function solidcraft_structure_geometry!(bodies,w,p,mirror,progress)
    progress("Reading physical ribs, spars and stringer paths")
    # A material-only assignment cannot change CAD section geometry. Keep
    # dimensional overrides authenticated against their actual physical layout.
    p["properties.panels"]=filter(get(p,"properties.panels",Any[])) do row
        any(part->haskey(row,part) && any(key->key!="material",keys(row[part])),("skin","stringer"))
    end
    xcs,_=chord_stations(w,p);etas,ribs,_=span_stations(w,p)
    nh=vertical_mesh_count(p["mesh.elements_spar_height"])
    coarse=stringer_grid(w,p,xcs,etas,ribs,nh)
    g=get(p,"stringers.model","beam")=="shell" ? shell_stringer_grid(coarse,p) :
        refine_stringer_bays(coarse,get(p,"mesh.elements_between_stringers",1))
    layout=stiffened_panel_layout(g);register_panel_properties!(p,g;layout)
    source_axis=nothing
    if shell_stringers(p)
        if get(p,"stringers.orientation","surface_normal")!="surface_normal" && Int(get(p,"stringers.axis_cid",0))!=0
            progress("Resolving the authored shell-stringer coordinate frame")
            native=build_model(deepcopy(p);summaries=false,progress=stage->progress("Resolving stringer frame: "*String(stage)))
            key=(Int(p["stringers.axis_cid"]),String(p["stringers.axis"]))
            source_axis=get(native.grid.shell_columns.axis_cache,key,nothing)
            source_axis===nothing && throw(ArgumentError("The authored shell-stringer coordinate frame could not be resolved"))
        else
            source_axis=stringer_axis_direction(p,g,NodeRegistry(),ElemGroup[])
        end
    end
    properties=resolved_component_properties(p,length(ribs));sections=Dict{Any,Any}()
    section(pid)=get!(sections,(component_base_pid(pid),
        component_base_pid(pid)==PID_STRINGER ? panel_stringer_dimensions(p,pid) :
        component_base_pid(pid)==PID_RIB_STIFFENER ? rib_stiffener_dimensions(p,pid==PID_RIB_STIFFENER ? 0 : pid%COMPONENT_PID_STRIDE) :
        component_base_pid(pid)==PID_SPAR_CAP ? get(component_table_override(p,pid),"side",p["properties.spar_cap_side"]) : pid)) do
        section_definition(p,pid)
    end
    for reflected in (mirror ? (false,true) : (false,))
        side=reflected ? "Left" : "Right"
        for (rib,j) in enumerate(ribs)
            progress("Preparing $side rib $rib")
            plane=main_rib_plane(g,p,j)
            outline=vcat([grid_point(g,i,j,nh) for i in 0:ni(g)],
                [grid_point(g,i,j,0) for i in ni(g):-1:0])
            profile=solidcraft_polygon([solidcraft_reflect(point,reflected,w.root_ref_y) for point in outline])
            if !(reflected && all(abs(point[2]-w.root_ref_y)<1e-9 for point in outline))
                solidcraft_add_body!(bodies,side*"_Rib_"*string(rib),"Ribs",[profile];
                    color="#42b9a4",thickness=properties.ribs[rib].thickness,
                    metadata=Dict("rib"=>rib,"property_id"=>properties.ribs[rib].web_pid))
            end
            properties.ribs[rib].stiffener_enabled || continue
            for (stringer,i) in enumerate(g.stringer_indices)
                g.collapsed[i+1,j+1]==0 || continue
                a,b=grid_point(g,i,j,0),grid_point(g,i,j,nh)
                orient=(rib==length(ribs) ? 1. : -1.).*plane.normal
                sec=section(properties.ribs[rib].stiffener_pid)
                profiles=[solidcraft_beam_profile(a,b,orient,sec;mirror=reflected,root_y=w.root_ref_y),
                    solidcraft_beam_profile(b,b.+(b.-a),orient,sec;mirror=reflected,root_y=w.root_ref_y)]
                solidcraft_add_body!(bodies,side*"_Rib_"*string(rib)*"_Stiffener_"*string(stringer),"Rib stiffeners",profiles;
                    color="#8ed8cb",metadata=Dict("rib"=>rib,"property_id"=>properties.ribs[rib].stiffener_pid))
            end
        end
        for bay in 1:length(ribs)-1
            a,b=ribs[bay:bay+1]
            rows=collect(a:b)
            progress("Preparing $side structural bay $bay")
            for (spar,i) in (("Front",0),("Rear",ni(g)))
                t=spar=="Front" ? properties.bays[bay].front_thickness : properties.bays[bay].rear_thickness
                profiles=Any[]
                for j in rows
                    low,up=grid_point(g,i,j,0),grid_point(g,i,j,nh)
                    normal=unit3(cross3(up.-low,main_rib_plane(g,p,j).normal))
                    points=[low.+(t/2).*normal,up.+(t/2).*normal,up.-(t/2).*normal,low.-(t/2).*normal]
                    push!(profiles,solidcraft_polygon([solidcraft_reflect(point,reflected,w.root_ref_y) for point in points]))
                end
                solidcraft_loft_chunks!(bodies,side*"_"*spar*"_Spar_Web_Bay_"*string(bay),"Spar webs",profiles;color="#e4a350")
            end
            for upper in (false,true)
                k=upper ? nh : 0;profiles=Any[];pids=Set{Int}()
                for j in rows
                    cell=min(j,b-1)
                    ids=[layout.skins[upper][i+1,cell+1] for i in 0:ni(g)-1]
                    localpids=[id==0 ? (upper ? PID_SKIN_UPPER : PID_SKIN_LOWER) : panel_skin_pid(id,upper) for id in ids]
                    union!(pids,localpids)
                    gauges=[shell_thickness(p,pid) for pid in localpids]
                    tops=gauges./2;bottoms=(-.5).*gauges
                    if shell_stringers(p)
                        for (stringer,column) in enumerate(g.stringer_indices)
                            id=get(layout.bars,(column,cell,upper),nothing)
                            id===nothing && continue
                            flange_width=first(panel_stringer_dimensions(p,panel_stringer_pid(id)))
                            flange_width>0 || continue
                            definition=shell_stringer_flange_definition(p,panel_stringer_flange_pid(id))
                            left=g.shell_columns.edgecols[(stringer,flange_width/2,-1)]
                            right=g.shell_columns.edgecols[(stringer,flange_width/2,1)]
                            for strip in left:right-1
                                gauges[strip+1]=definition["thickness_m"]
                                tops[strip+1]=definition["z_top_m"]
                                bottoms[strip+1]=definition["z_bottom_m"]
                            end
                            push!(pids,panel_stringer_flange_pid(id))
                        end
                    end
                    points=[grid_point(g,i,j,k) for i in 0:ni(g)]
                    inward=[grid_point(g,i,j,upper ? 0 : nh).-points[i+1] for i in 0:ni(g)]
                    push!(profiles,solidcraft_skin_profile(points,gauges,main_rib_plane(g,p,j).normal,inward;
                        mirror=reflected,root_y=w.root_ref_y,top_m=tops,bottom_m=bottoms))
                end
                label=upper ? "Upper" : "Lower"
                solidcraft_loft_chunks!(bodies,side*"_"*label*"_Skin_Bay_"*string(bay),"Box skins",profiles;
                    color="#70a9cb",opacity=.75,metadata=Dict("property_ids"=>sort!(collect(pids)),"bay"=>bay))
            end
        end
        for upper in (false,true),i in vcat(0,g.stringer_indices,ni(g))
            k=upper ? nh : 0;cap=i==0 || i==ni(g);label=cap ? (i==0 ? "Front_Cap" : "Rear_Cap") : "Stringer_"*string(findfirst(==(i),g.stringer_indices))
            progress("Preparing $side "*(upper ? "upper " : "lower ")*replace(label,"_"=>" "))
            j=0;segment=0
            while j<nj(g)
                g.collapsed[i+1,j+1]!=0 && (j+=1;continue)
                bay=min(searchsortedlast(ribs,j),length(ribs)-1)
                pid=cap ? component_table_pid(p,(i==0 ? "front" : "rear")*(upper ? "_upper_cap" : "_lower_cap"),bay,PID_SPAR_CAP) :
                    haskey(layout.bars,(i,j,upper)) ? panel_stringer_pid(layout.bars[(i,j,upper)]) : PID_STRINGER_RUNOUT
                sec=section(pid);profiles=Any[];start=j;endpoint=false
                blade=shell_stringers(p) && !cap && component_base_pid(pid)==PID_STRINGER
                member_profile=(row,a,b,v)->blade ? solidcraft_shell_blade_profile(g,p,i,row,upper,pid,source_axis;mirror=reflected) :
                    solidcraft_beam_profile(a,b,v,sec;mirror=reflected,root_y=w.root_ref_y)
                while j<nj(g)
                    g.collapsed[i+1,j+1]!=0 && break
                    nextbay=min(searchsortedlast(ribs,j),length(ribs)-1)
                    nextpid=cap ? component_table_pid(p,(i==0 ? "front" : "rear")*(upper ? "_upper_cap" : "_lower_cap"),nextbay,PID_SPAR_CAP) :
                        haskey(layout.bars,(i,j,upper)) ? panel_stringer_pid(layout.bars[(i,j,upper)]) : PID_STRINGER_RUNOUT
                    nextsec=section(nextpid)
                    (nextsec["polygon_yz_m"]==sec["polygon_yz_m"] && nextsec["offset_y_m"]==sec["offset_y_m"]) || break
                    a,b=grid_point(g,i,j,k),grid_point(g,i,j+1,k)
                    norm3(b.-a)>1e-10 || (j+=1;continue)
                    push!(profiles,member_profile(j,a,b,skin_normal(g,i,j,upper)))
                    j+=1
                    if j==nj(g) || g.collapsed[i+1,j+1]!=0 || j-start==49
                        push!(profiles,member_profile(j,b,b.+(b.-a),skin_normal(g,i,j-1,upper)))
                        endpoint=true
                        break
                    end
                end
                if j>start && !endpoint
                    a,b=grid_point(g,i,j-1,k),grid_point(g,i,j,k)
                    push!(profiles,member_profile(j,b,b.+(b.-a),skin_normal(g,i,j-1,upper)))
                end
                if length(profiles)>=2
                    segment+=1
                    solidcraft_loft_chunks!(bodies,side*"_"*(upper ? "Upper_" : "Lower_")*label*"_"*string(segment),
                        cap ? "Spar caps" : "Stringers",profiles;color=cap ? "#e7ca70" : "#d3e0ec",
                        metadata=Dict("property_id"=>pid,"section_shape"=>blade ? "Shell blade" : sec["shape"],
                            "stringer_orientation"=>blade ? p["stringers.orientation"] : "beam local section",
                            "axis_cid"=>blade ? Int(get(p,"stringers.axis_cid",0)) : 0))
                end
                j==start && (j+=1)
            end
        end
        if get(p,"leading_edge.enabled",false)
            lelayout=leading_edge_layout(p,length(ribs));stations=leading_edge_mesh_stations(g,p,lelayout)
            count=leading_edge_column_count(stations)
            for bay in lelayout.active_bays, upper in (false,true)
                profiles=Any[]
                for j in (ribs[bay],ribs[bay+1])
                    points=[leading_edge_skin_points(stations,g,i,j)[upper ? 2 : 1] for i in 0:count]
                    opposite=[leading_edge_skin_points(stations,g,i,j)[upper ? 1 : 2] for i in 0:count]
                    thickness=shell_thickness(p,component_table_pid(p,upper ? "leading_upper_skin" : "leading_lower_skin",bay,PID_LE_SKIN))
                    perimeter=solidcraft_polygon(vcat(points,reverse(opposite)))
                    normal=cross3(Tuple(perimeter["x_dir"]),Tuple(perimeter["y_dir"]))
                    inward=[opposite[i].-points[i] for i in eachindex(points)]
                    push!(profiles,solidcraft_skin_profile(points,fill(thickness,count),normal,inward;
                        mirror=reflected,root_y=w.root_ref_y,top_m=thickness/2,bottom_m=-thickness/2))
                end
                solidcraft_loft_chunks!(bodies,side*"_Leading_Edge_"*(upper ? "Upper_" : "Lower_")*"Bay_"*string(bay),
                    "Leading edge skins",profiles;color="#70bfc9",opacity=.75)
            end
            for rib in lelayout.active_ribs
                j=ribs[rib]
                outline=vcat([leading_edge_skin_points(stations,g,i,j)[2] for i in 0:count],
                    [leading_edge_skin_points(stations,g,i,j)[1] for i in count:-1:0])
                profile=solidcraft_polygon([solidcraft_reflect(point,reflected,w.root_ref_y) for point in outline])
                thickness=shell_thickness(p,component_table_pid(p,"leading_rib",rib,PID_LE_RIB))
                if !(reflected && all(abs(point[2]-w.root_ref_y)<1e-9 for point in outline))
                    solidcraft_add_body!(bodies,side*"_Leading_Edge_Rib_"*string(rib),"Leading edge ribs",[profile];
                        color="#54c2ad",thickness)
                end
            end
        end
    end
    g
end

function solidcraft_engine_geometry!(bodies,w,p,mirror)
    for reflected in (mirror ? (false,true) : (false,)),engine in normalize_engines(get(p,"engines.items",Any[]))
        engine["enabled"] || continue
        center=(engine["x"],engine["y"],engine["z"])
        a=center.-(engine["length"]/2,0.,0.);b=center.+(engine["length"]/2,0.,0.)
        side=sqrt(engine["A"])
        section=Dict("offset_y_m"=>0.,"polygon_yz_m"=>[[side/2,-side/2],[side/2,side/2],[-side/2,side/2],[-side/2,-side/2]])
        profiles=[solidcraft_beam_profile(a,b,(0.,1.,0.),section;mirror=reflected,root_y=w.root_ref_y),
            solidcraft_beam_profile(b,b.+(b.-a),(0.,1.,0.),section;mirror=reflected,root_y=w.root_ref_y)]
        solidcraft_add_body!(bodies,(reflected ? "Left_" : "Right_")*engine["name"]*"_Equivalent_Beam","Engine beams",profiles;
            color="#df5050",metadata=Dict("engine"=>engine["name"],"mass_kg"=>engine["mass"],
                "length_m"=>engine["length"],"area_m2"=>engine["A"],"I1_m4"=>engine["I1"],"I2_m4"=>engine["I2"],"J_m4"=>engine["J"],
                "geometry"=>"Square area-equivalent representation of the authored flexible beam"))
    end
end

"""Physical movable rib planes, gauges and fittings reuse their mesher geometry."""
function solidcraft_movable_structure_geometry!(bodies,w,p,g,mirror,deflected,progress)
    definitions=Dict(surface["name"]=>surface for surface in normalize_movable_surfaces(get(p,"movable_surfaces.items",Any[])))
    for row in movable_structure_rows(p)
        row["enabled"] || continue
        surface=definitions[row["surface"]]
        progress("Preparing $(row["surface"]) structural profiles")
        rot=movable_rotation(w,surface,false)
        motion=movable_kinematics(w,surface;angle=deflected ? surface["deflection"] : 0.)
        attachments=snapped_movable_attachments(p,surface,row,g.etas[g.ribs.+1];w)
        attachments=movable_attachment_planes(g,surface,row,rot,attachments)
        start=first(movable_material_interval(w,surface));stop=movable_structural_end(row,surface,w)
        ribs=movable_master_rib_layout(start,stop,row,attachments)
        us=movable_chord_stations(row);nh=row["height_elements"]
        etas=movable_rib_eta_grid(w,surface,row,rot,ribs,attachments,us,nh)
        edge=surface["edge"]=="trailing" ? 1. : 0.
        function point(rib,i,k)
            eta=etas[i,rib,k+1]
            xc=rot.front_spar(eta)+(edge-rot.front_spar(eta))*us[i]
            low,up=lower_point(w,eta,xc),upper_point(w,eta,xc)
            rot.rotate(low.+(k/nh).*(up.-low))
        end
        lowers=[[point(rib,i,0) for i in eachindex(us)] for rib in eachindex(ribs)]
        uppers=[[point(rib,i,nh) for i in eachindex(us)] for rib in eachindex(ribs)]
        planes=[solidcraft_polygon(vcat(uppers[rib],reverse(lowers[rib]))) for rib in eachindex(ribs)]
        normals=[cross3(Tuple(plane["x_dir"]),Tuple(plane["y_dir"])) for plane in planes]
        for reflected in (mirror ? (false,true) : (false,))
            prefix=(reflected ? "Left_" : "Right_")*surface["name"]
            first_control_body=length(bodies)+1
            for rib in eachindex(ribs)
                outline=vcat(uppers[rib],reverse(lowers[rib]))
                profile=solidcraft_polygon([solidcraft_reflect(q,reflected,w.root_ref_y) for q in outline])
                owner=ribs[rib]["attachment"]
                thickness=owner>0 && attachments[owner]["fitting"]=="shell_lugs" ? attachments[owner]["lug_thickness"] : row["rib_thickness"]
                solidcraft_add_body!(bodies,prefix*"_Rib_"*string(rib),"Movable ribs",[profile];
                    color="#56bfa8",thickness,metadata=Dict("surface"=>surface["name"],"rib"=>rib))
            end
            for bay in 1:length(ribs)-1
                for upper in (false,true)
                    profiles=Any[]
                    for rib in (bay,bay+1)
                        points=upper ? uppers[rib] : lowers[rib]
                        opposite=upper ? lowers[rib] : uppers[rib]
                        inward=[opposite[i].-points[i] for i in eachindex(points)]
                        thickness=row[upper ? "upper_thickness" : "lower_thickness"]
                        push!(profiles,solidcraft_skin_profile(points,fill(thickness,length(us)-1),normals[rib],inward;
                            mirror=reflected,root_y=w.root_ref_y,top_m=thickness/2,bottom_m=-thickness/2))
                    end
                    solidcraft_add_body!(bodies,prefix*(upper ? "_Upper" : "_Lower")*"_Skin_Bay_"*string(bay),
                        "Movable skins",profiles;color=surface["color"],opacity=.7)
                end
                columns=unique(vcat([1],row["secondary_spar"]>0 ? [findfirst(==(row["secondary_spar"]),us)] : Int[]))
                for column in columns
                    profiles=Any[]
                    for rib in (bay,bay+1)
                        low,up=lowers[rib][column],uppers[rib][column]
                        direction=unit3(cross3(up.-low,normals[rib]));offset=(row["web_thickness"]/2).*direction
                        outline=[low.+offset,up.+offset,up.-offset,low.-offset]
                        push!(profiles,solidcraft_polygon([solidcraft_reflect(q,reflected,w.root_ref_y) for q in outline]))
                    end
                    solidcraft_add_body!(bodies,prefix*"_Spar_"*string(column)*"_Bay_"*string(bay),"Movable spars",profiles;color="#d6a15c")
                end
            end
            for body in bodies[first_control_body:end]
                solidcraft_body_rotation!(body,motion,w,reflected)
            end
            for (index,attachment) in enumerate(attachments)
                rib=findfirst(r->r["attachment"]==index,ribs)
                rib===nothing && continue
                if attachment["fitting"]=="shell_lugs"
                    center=Tuple(attachment["hinge_center"]);normal=Tuple(attachment["plane_normal"])
                    plane=(;origin=center,normal,scale=max(w.semispan,w.mac,1.))
                    spar=attachment["spar"]=="front" ? :front : :rear
                    curve(eta,upper)=begin
                        xc=spar_surface_xc(w,spar_geometry(p),eta,spar)
                        upper ? upper_point(w,eta,xc) : lower_point(w,eta,xc)
                    end
                    cuts=sort!(unique(vcat(0.,Float64(p["box.end_eta"]),filter(e->0<e<p["box.end_eta"],
                        vcat(planform_breakpoints(w),spar_breakpoints(p),loft_control_etas(w))))))
                    _,lower=rib_curve_intersection(eta->curve(eta,false),plane,cuts,"Main-box hinge lug")
                    _,upper=rib_curve_intersection(eta->curve(eta,true),plane,cuts,"Main-box hinge lug")
                    profile=solidcraft_polygon([solidcraft_reflect(q,reflected,w.root_ref_y) for q in (lower,upper,center)])
                    solidcraft_add_body!(bodies,prefix*"_Box_Hinge_Lug_"*string(index),"Hinge fittings",[profile];
                        color="#d38d42",thickness=attachment["lug_thickness"])
                    if attachment["underside_lug"]
                        xyz=Float64[value for q in vcat(lowers[rib],uppers[rib]) for value in q]
                        count=length(us);fake=(;xyz)
                        fitting=movable_underside_fitting(fake,collect(1:count),collect(count+1:2count),center,normal,
                            "$(surface["name"]) CAD underside fitting";
                            minimum_end=row["secondary_spar"]>0 ? findfirst(==(row["secondary_spar"]),us) : 2)
                        at(node)=node==0 ? center : node== -1 ? fitting.knee_point : Tuple(xyz[3node-2:3node])
                        for (triangle,ids) in enumerate(fitting.triangles)
                            profile=solidcraft_polygon([solidcraft_reflect(at(node),reflected,w.root_ref_y) for node in ids])
                            solidcraft_add_body!(bodies,prefix*"_Movable_Hinge_Lug_"*string(index)*"_"*string(triangle),
                                "Hinge fittings",[profile];color="#d38d42",thickness=attachment["lug_thickness"])
                            solidcraft_body_rotation!(last(bodies),motion,w,reflected)
                        end
                    else
                        outline=[lowers[rib][1],uppers[rib][1],center]
                        profile=solidcraft_polygon([solidcraft_reflect(q,reflected,w.root_ref_y) for q in outline])
                        solidcraft_add_body!(bodies,prefix*"_Movable_Hinge_Lug_"*string(index),"Hinge fittings",[profile];
                            color="#d38d42",thickness=attachment["lug_thickness"])
                        solidcraft_body_rotation!(last(bodies),motion,w,reflected)
                    end
                end
                if get(attachment,"actuator",false) && attachment["kind"]=="hinge" && attachment["actuator_stiffness"]>0
                    jr=g.ribs[attachment["rib"]]
                    main=grid_point(g,ni(g),jr,g.nh);control=motion.transform(uppers[rib][1])
                    actuator_length=norm3(control.-main);actuator_length>1e-10 || throw(ArgumentError("The CAD actuator has coincident endpoints"))
                    axis=unit3(control.-main)
                    for (part,lo,hi,radius) in (("Barrel",0.,.55,.018),("Rod",.55,1.,.010))
                        a=main.+(lo*actuator_length).*axis;b=main.+(hi*actuator_length).*axis
                        # An octagonal equivalent is a closed native solid with
                        # clear endpoints, retaining the symbolic actuator scope.
                        x=unit3(cross3(axis,abs(axis[3])<.9 ? (0.,0.,1.) : (0.,1.,0.)))
                        sec=Dict("offset_y_m"=>0.,"polygon_yz_m"=>[[radius*cospi(2k/8),radius*sinpi(2k/8)] for k in 0:7])
                        profiles=[solidcraft_beam_profile(a,b,x,sec;mirror=reflected,root_y=w.root_ref_y),
                            solidcraft_beam_profile(b,b.+(b.-a),x,sec;mirror=reflected,root_y=w.root_ref_y)]
                        solidcraft_add_body!(bodies,prefix*"_Actuator_"*string(index)*"_"*part,"Actuator symbols",profiles;
                            color="#e3ca55",metadata=Dict("stiffness_N_per_m"=>attachment["actuator_stiffness"],
                                "geometry"=>"Symbolic actuator with authored endpoints"))
                    end
                end
            end
        end
    end
end

"""Construction-point bounds include deflected controls, gauges and engine beams."""
function solidcraft_plan_bounds(bodies)
    points=Vector{Float64}[]
    for body in bodies
        bodypoints=Vector{Float64}[]
        plane=nothing;sketchpoints=Vector{Float64}[]
        for command in body["commands"]
            name,parameters=command["command"],command["params"]
            if name=="sketch.create"
                plane=parameters["plane"];empty!(sketchpoints)
            elseif name in ("sketch.line","sketch.spline.fit_point")
                for point in parameters["points"]
                    world=plane["origin"].+point[1].*plane["x_dir"].+point[2].*plane["y_dir"]
                    push!(bodypoints,world);push!(sketchpoints,world)
                end
            elseif name=="solid.extrude"
                normal=cross3(Tuple(plane["x_dir"]),Tuple(plane["y_dir"]))
                distance=Float64(parameters["distance"])/2
                for point in sketchpoints,sign in (-1.,1.)
                    push!(bodypoints,point.+sign*distance.*normal)
                end
            end
        end
        rotation=get(body["metadata"],"rigid_rotation",nothing)
        if rotation!==nothing
            origin=rotation["origin_mm"];axis=rotation["axis"];sn,cs=sincosd(rotation["angle_deg"])
            bodypoints=[begin
                v=point.-origin
                origin.+cs.*v.+sn.*cross3(Tuple(axis),Tuple(v)).+(1-cs)*sum(axis.*v).*axis
            end for point in bodypoints]
        end
        append!(points,bodypoints)
    end
    isempty(points) && throw(ArgumentError("The SolidCraft construction plan is empty"))
    Dict("min"=>[minimum(point[k] for point in points) for k in 1:3],
        "max"=>[maximum(point[k] for point in points) for k in 1:3])
end

"""Build a serializable native SolidCraft solid-construction plan for a study."""
function solidcraft_geometry(parameters::AbstractDict; include_structure::Bool=true,mirror::Bool=false,
                             deflected::Bool=false,tolerance_m::Real=2.5e-5,progress=(_)->nothing)
    isfinite(tolerance_m) && 1e-6<=tolerance_m<=.01 ||
        throw(ArgumentError("CAD loft sampling tolerance must be between 0.001 and 10 millimetres"))
    haskey(parameters,"imported.native") && throw(ArgumentError("SolidCraft wing export requires an authored wing Study"))
    p=deepcopy(Dict{String,Any}(parameters));apply_point_angle_constraints!(p)
    w=make_wing(p);bodies=Dict{String,Any}[]
    solidcraft_outer_geometry!(bodies,w,p,mirror,deflected,Float64(tolerance_m),progress)
    if include_structure
        grid=solidcraft_structure_geometry!(bodies,w,p,mirror,progress)
        solidcraft_movable_structure_geometry!(bodies,w,p,grid,mirror,deflected,progress)
        solidcraft_engine_geometry!(bodies,w,p,mirror)
    end
    names=[body["name"] for body in bodies]
    length(names)==length(unique(names)) || throw(ArgumentError("CAD body names are not unique"))
    Dict{String,Any}("bodies"=>bodies,"body_count"=>length(bodies),"source_units"=>"m","cad_units"=>"mm",
        "bbox_mm"=>solidcraft_plan_bounds(bodies),"profile_tolerance_m"=>Float64(tolerance_m),
        "notes"=>["Editable native closed loft and extrusion bodies use current study geometry and total shell gauges.",
            "CAD section sampling approximates continuous loft interpolation between the authored controls.",
        "Spar-web, beam and blade lofts retain their original oblique sections. Native capping can use a verified transactional alternate over the same unchanged sketches.",
            "Shell blades follow the authored surface-normal or coordinate-axis direction. Attached flanges share the skin solid at their combined section gauge and reference offset.",
            "Structural solids include main and leading-edge members, plus authored movable ribs, skins, spars and shell hinge lugs.",
            "CAD component colors identify geometry families. The original material definitions remain associated with the Study.",
            "Engine geometry is an area-equivalent flexible beam. Its stiffness and concentrated mass remain authored model data.",
            "Actuator bodies are schematic symbols located at the actual authored attachment endpoints.",
            "Joint constraints, loads, nonstructural mass and analysis results remain study data."],
        "include_structure"=>include_structure,"mirror"=>mirror,"deflected"=>deflected)
end
