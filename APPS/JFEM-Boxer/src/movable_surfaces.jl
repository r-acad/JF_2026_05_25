"""Geometry definitions only: these surfaces do not introduce FE joints or loads."""
const MOVABLE_SURFACE_KINDS = ("aileron", "flap", "slat", "elevator", "rudder", "tab", "other")
const MOVABLE_SURFACE_FIELDS = Set(["name", "kind", "edge", "eta_start", "eta_end",
    "hinge_start", "hinge_end", "deflection", "color"])
const MOVABLE_SURFACE_OPTIONAL_FIELDS = Set(["front_spar_start", "front_spar_end", "hinge_z_start", "hinge_z_end"])

movable_chord_coordinate(s,role,eta) = begin
    a=get(s,role*"_start",s["hinge_start"]);b=get(s,role*"_end",s["hinge_end"])
    a+(b-a)*(eta-s["eta_start"])/(s["eta_end"]-s["eta_start"])
end

"""Hinge endpoints measured through the local airfoil thickness, before rotation.

The upper/lower loft points include section twist, camber and vertical shift.
A ratio of +0.5 is therefore exactly the upper surface even on a twisted wing.
The physical hinge is the straight line between these two endpoint positions.
"""
function movable_hinge_endpoints(w,s)
    point(side)=begin
        eta=s["eta_"*side];xc=s["hinge_"*side]
        lo,up=lower_point(w,eta,xc),upper_point(w,eta,xc)
        ratio=get(s,"hinge_z_"*side,0.)
        lo.+(.5+ratio).*(up.-lo)
    end
    point("start"),point("end")
end

function normalize_movable_surfaces(value)
    value isa AbstractVector && length(value)<=100 ||
        throw(ArgumentError("Movable surfaces must be a table of at most 100 surfaces"))
    result=Dict{String,Any}[]; names=Set{String}()
    for (i,row) in enumerate(value)
        row isa AbstractDict && issubset(MOVABLE_SURFACE_FIELDS,Set(String.(keys(row)))) &&
            issubset(Set(String.(keys(row))),union(MOVABLE_SURFACE_FIELDS,MOVABLE_SURFACE_OPTIONAL_FIELDS)) ||
            throw(ArgumentError("Movable surface $i requires name, kind, edge, eta_start, eta_end, hinge_start, hinge_end, deflection and color; optional front_spar_start/end separate the control spar from its hinge and hinge_z_start/end define hinge height in local-thickness units"))
        row["name"] isa AbstractString || throw(ArgumentError("Movable surface $i needs a name"))
        name=strip(row["name"])
        1<=length(name)<=80 && !any(iscntrl,name) || throw(ArgumentError("Movable surface $i needs a name of 1 to 80 characters without control characters"))
        lowercase(name) in names && throw(ArgumentError("Movable surface names must be unique: $name"))
        push!(names,lowercase(name))
        row["kind"] in MOVABLE_SURFACE_KINDS || throw(ArgumentError("$name: choose a valid surface type"))
        row["edge"] in ("leading","trailing") || throw(ArgumentError("$name: choose leading or trailing edge"))
        clean=Dict{String,Any}("name"=>name,"kind"=>row["kind"],"edge"=>row["edge"])
        for field in ("eta_start","eta_end","hinge_start","hinge_end","front_spar_start","front_spar_end","deflection")
            number=get(row,field,field=="front_spar_start" ? row["hinge_start"] : field=="front_spar_end" ? row["hinge_end"] : nothing)
            number isa Real && !(number isa Bool) && isfinite(number) ||
                throw(ArgumentError("$name: $field must be a finite number"))
            clean[field]=Float64(number)
        end
        for field in ("hinge_z_start","hinge_z_end")
            number=get(row,field,0.)
            number isa Real && !(number isa Bool) && isfinite(number) ||
                throw(ArgumentError("$name: $field must be a finite local-thickness ratio"))
            clean[field]=Float64(number)
        end
        0<=clean["eta_start"]<clean["eta_end"]<=1 && clean["eta_end"]-clean["eta_start"]>=1e-6 ||
            throw(ArgumentError("$name: require 0 <= start eta < end eta <= 1, separated by at least 0.000001"))
        all(k->0<clean[k]<1,("hinge_start","hinge_end","front_spar_start","front_spar_end")) ||
            throw(ArgumentError("$name: hinge and control-spar x/c must be strictly between 0 and 1"))
        color=row["color"]
        color isa AbstractString && occursin(r"^#[0-9a-fA-F]{6}$",color) ||
            throw(ArgumentError("$name: color must be a six-digit hex color"))
        clean["color"]=lowercase(color)
        push!(result,clean)
    end
    # Disallow intersecting footprints, including a leading/trailing pair whose
    # hinge lines cross. Adjacent surfaces may share their spanwise boundary.
    cut(s,eta)=movable_chord_coordinate(s,"front_spar",eta)
    for i in eachindex(result),j in i+1:length(result)
        a,b=result[i],result[j]; lo=max(a["eta_start"],b["eta_start"]); hi=min(a["eta_end"],b["eta_end"])
        hi<=lo && continue
        a["edge"]==b["edge"] && throw(ArgumentError("$(a["name"]) and $(b["name"]) overlap on the same edge"))
        front,rear=a["edge"]=="leading" ? (a,b) : (b,a)
        all(eta->cut(front,eta)<cut(rear,eta),(lo,hi)) ||
            throw(ArgumentError("$(a["name"]) and $(b["name"]) have overlapping chordwise footprints"))
    end
    return result
end

"""Sample the common loft, then rotate each closed surface about its endpoint hinge axis.

Positive deflection is trailing-edge down, using a right-handed rotation about
the axis from the inboard hinge point to the outboard hinge point in BASIC xyz.
The untouched plan outline is returned separately for the definition drawing.
No FE model, aerodynamic lattice, active case or server state is modified.
"""
function movable_surfaces_preview(p::AbstractDict)
    rows=normalize_movable_surfaces(get(p,"movable_surfaces.items",Any[]))
    w=make_wing(p)
    etas=sort!(unique(vcat(collect(range(0.,1.;length=61)),loft_control_etas(w))))
    camber(eta,xc)=section_point(w,eta,xc,(zup(w,eta,xc)+zlo(w,eta,xc))/2)
    outline=vcat([camber(eta,0.) for eta in etas],[camber(eta,1.) for eta in reverse(etas)])
    surfaces=Any[]
    for row in rows
        a,b=row["eta_start"],row["eta_end"]
        stations=sort!(unique(vcat(collect(range(a,b;length=25)),filter(eta->a<eta<b,loft_control_etas(w)))))
        hinge(eta)=row["hinge_start"]+(row["hinge_end"]-row["hinge_start"])*(eta-a)/(b-a)
        front_spar(eta)=movable_chord_coordinate(row,"front_spar",eta)
        h0,h1=movable_hinge_endpoints(w,row); delta=h1.-h0
        axis_length=sqrt(sum(abs2,delta));axis_length>1e-12 || throw(ArgumentError("$(row["name"]): hinge axis is too short"))
        axis=delta./axis_length; sine,cosine=sincosd(row["deflection"])
        function rotate(point)
            v=point.-h0; cross=(axis[2]*v[3]-axis[3]*v[2],axis[3]*v[1]-axis[1]*v[3],axis[1]*v[2]-axis[2]*v[1])
            projection=sum(axis.*v)
            return ntuple(k->h0[k]+cosine*v[k]+sine*cross[k]+(1-cosine)*projection*axis[k],3)
        end
        edge=row["edge"]=="trailing" ? 1. : 0.
        # Each spanwise ring follows upper hinge -> edge -> lower hinge.
        n=9; ring=2n; xyz=Float64[]
        for eta in stations
            xcs=collect(range(front_spar(eta),edge;length=n))
            for point in vcat([upper_point(w,eta,xc) for xc in xcs],[lower_point(w,eta,xc) for xc in reverse(xcs)])
                append!(xyz,rotate(point))
            end
        end
        triangles=Int[]
        for strip in 0:length(stations)-2,k in 0:ring-1
            next=(k+1)%ring; v=strip*ring
            append!(triangles,(v+k,v+next,v+ring+next,v+k,v+ring+next,v+ring+k))
        end
        # End caps follow the chord subdivisions, preserving cambered shapes.
        for offset in (0,(length(stations)-1)*ring),k in 0:n-2
            append!(triangles,(offset+k,offset+k+1,offset+ring-2-k,offset+k,offset+ring-2-k,offset+ring-1-k))
        end
        boundary=vcat([camber(eta,front_spar(eta)) for eta in stations],[camber(eta,edge) for eta in reverse(stations)])
        push!(surfaces,Dict("definition"=>row,"xyz"=>xyz,"triangles"=>triangles,
            "hinge"=>[h0,h1],"outline"=>boundary,"hinge_curve"=>[h0.+((eta-a)/(b-a)).*delta for eta in stations],
            "front_spar_curve"=>[camber(eta,front_spar(eta)) for eta in stations]))
    end
    return Dict("outline"=>outline,"surfaces"=>surfaces,"units"=>"m","geometry_only"=>true)
end

function handle_movable_surfaces(st,req)
    try
        raw=JSON.parse(String(req.body));raw isa AbstractDict || throw(ArgumentError("Expected geometry parameters"))
        # Do not make a preview depend on unfinished load/property form edits.
        geometry=Dict{String,Any}(k=>v for (k,v) in raw if any(prefix->startswith(k,prefix),("planform.","airfoil.","loft.","movable_surfaces.")))
        p,unknown=normalize_params(geometry)
        isempty(unknown)||throw(ArgumentError("Unknown geometry parameters: "*join(unknown,", ")))
        return json_response(movable_surfaces_preview(p))
    catch error
        return error_response("Movable surfaces: "*describe_error(error))
    end
end
