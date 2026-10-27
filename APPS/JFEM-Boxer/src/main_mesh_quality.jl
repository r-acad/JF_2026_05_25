"""An invalid generated mesh, with actionable physical-region diagnostics."""
struct MeshQualityError <: Exception
    message::String
    issues::Vector{Dict{String,Any}}
end
Base.showerror(io::IO,error::MeshQualityError)=print(io,error.message)

# Application warning thresholds, not solver error estimates. Valid geometry
# remains available for inspection and analysis; no physical boundary is moved.
const MAIN_MESH_MIN_ANGLE_DEG=10.0
const MAIN_MESH_MAX_EDGE_RATIO=15.0

function main_shell_quality(reg,ids)
    n=length(ids);ps=[Tuple(reg.xyz[3id-2:3id]) for id in ids]
    edges=[ps[mod1(i+1,n)].-ps[i] for i in 1:n];lengths=norm3.(edges)
    longest,shortest=maximum(lengths),minimum(lengths)
    normal=foldl((a,b)->a.+b,[cross3(ps[i].-ps[1],ps[i+1].-ps[1]) for i in 2:n-1])
    area=norm3(normal)
    valid=all(isfinite,lengths)&&longest>0&&shortest>0&&area>1e-12longest^2
    angles=Float64[]
    if valid
        for i in 1:n
            a,b=edges[i],.-edges[mod1(i-1,n)]
            push!(angles,acosd(clamp(sum(a.*b)/(norm3(a)*norm3(b)),-1.,1.)))
            valid &= sum(cross3(a,b).*normal)>0
        end
    end
    (;edge_ratio=shortest>0 ? longest/shortest : Inf,
        minimum_angle=isempty(angles) ? 0. : minimum(angles),
        maximum_angle=isempty(angles) ? 180. : maximum(angles),valid)
end

function main_mesh_geometry_controls(p)
    controls=Dict{String,Any}[]
    for (key,label,menu) in (
        ("box.front_spar_points","Front spar point","Structure / Spars"),
        ("box.rear_spar_points","Rear spar point","Structure / Spars"),
        ("planform.leading_edge_points","Leading-edge point","Geometry / Planform"),
        ("planform.trailing_edge_points","Trailing-edge point","Geometry / Planform"),
        ("loft.twist_stations","Twist station","Geometry / Loft"),
        ("loft.thickness_stations","Thickness station","Geometry / Loft"),
        ("loft.vertical_shift_stations","Vertical-shift station","Geometry / Loft"))
        for (i,row) in enumerate(get(p,key,Any[]))
            eta=get(row,"eta",nothing);eta isa Real||continue
            0<eta<1||continue
            push!(controls,Dict("key"=>key,"row"=>i,"label"=>"$label $i","menu"=>menu,"eta"=>Float64(eta)))
        end
    end
    controls
end

function main_mesh_region(group,reg,ids,g)
    base=component_base_pid(group.pid)
    base==PID_SKIN_UPPER&&return "Upper skin"
    base==PID_SKIN_LOWER&&return "Lower skin"
    base==PID_SPAR_WEB&&return all(reg.keys[id][1]==0 for id in ids) ? "Front spar web" : "Rear spar web"
    base==PID_RIB_WEB&&return "Rib web"
    base==PID_LE_RIB&&return "Leading-edge rib"
    occursin("UPPER",group.name) ? "Leading-edge upper skin" : "Leading-edge lower skin"
end

"""Aggregate failed faces by physical rib bay, retaining every failing EID."""
function main_mesh_quality_issues(reg,g,p,groups)
    regions=Dict{Tuple{String,Int,String},Dict{String,Any}}();w=g.wing
    for group in groups
        group.kind in (:quad,:tria)||continue
        component_base_pid(group.pid) in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_SPAR_WEB,PID_RIB_WEB,PID_LE_SKIN,PID_LE_RIB)||continue
        n=group.kind===:quad ? 4 : 3
        for (e,eid) in enumerate(group.eids)
            ids=view(group.conn,n*(e-1)+1:n*e);quality=main_shell_quality(reg,ids)
            quality.valid&&quality.edge_ratio<=MAIN_MESH_MAX_EDGE_RATIO&&
                quality.minimum_angle>=MAIN_MESH_MIN_ANGLE_DEG&&quality.maximum_angle<=180-MAIN_MESH_MIN_ANGLE_DEG&&continue
            j=minimum(reg.keys[id][2] for id in ids)
            bay=clamp(searchsortedlast(g.ribs,j),1,length(g.ribs)-1)
            name=main_mesh_region(group,reg,ids,g)
            severity=quality.valid ? "warning" : "error"
            issue=get!(regions,(name,bay,severity)) do
                Dict{String,Any}("component"=>name,"rib_start"=>bay,"rib_end"=>bay+1,
                    "severity"=>severity,
                    "rib_start_eta"=>g.etas[g.ribs[bay]+1],"rib_end_eta"=>g.etas[g.ribs[bay+1]+1],
                    "element_ids"=>Int[],"property_ids"=>Int[],"eta_min"=>Inf,"eta_max"=>-Inf,
                    "minimum_corner_deg"=>180.,"maximum_corner_deg"=>0.,"maximum_edge_ratio"=>0.,"inverted_or_collapsed"=>false)
            end
            push!(issue["element_ids"],eid);push!(issue["property_ids"],group.pid)
            etas=[(reg.xyz[3id-1]-w.root_ref_y)/w.semispan for id in ids]
            issue["eta_min"]=min(issue["eta_min"],minimum(etas));issue["eta_max"]=max(issue["eta_max"],maximum(etas))
            issue["minimum_corner_deg"]=min(issue["minimum_corner_deg"],quality.minimum_angle)
            issue["maximum_corner_deg"]=max(issue["maximum_corner_deg"],quality.maximum_angle)
            issue["maximum_edge_ratio"]=max(issue["maximum_edge_ratio"],quality.edge_ratio)
            issue["inverted_or_collapsed"]|=!quality.valid
        end
    end
    controls=main_mesh_geometry_controls(p)
    result=sort!(collect(values(regions));by=x->(x["rib_start"],x["component"]))
    for issue in result
        unique!(issue["property_ids"]);issue["count"]=length(issue["element_ids"])
        nearby=Dict{String,Any}[]
        for c in controls
            issue["component"]=="Front spar web"&&c["key"]=="box.rear_spar_points"&&continue
            issue["component"]=="Rear spar web"&&c["key"]=="box.front_spar_points"&&continue
            startswith(issue["component"],"Leading-edge")&&c["key"]=="box.rear_spar_points"&&continue
            issue["eta_min"]-1e-8<=c["eta"]<=issue["eta_max"]+1e-8||continue
            r=argmin(abs.(g.etas[g.ribs.+1].-c["eta"]));re=g.etas[g.ribs[r]+1]
            d=copy(c);d["nearest_rib"]=r;d["rib_eta"]=re
            d["distance_mm"]=abs(c["eta"]-re)*w.semispan*1000
            masters=get(p,"ribs.masters",Any[])
            d["master_rib_row"]=findfirst(row->abs(get(row,"eta",-1.)-re)<1e-9,masters)
            push!(nearby,d)
        end
        issue["nearby_controls"]=nearby
        columns=sort!(unique(reg.keys[id][1] for group in groups if group.pid in issue["property_ids"] for id in group.conn))
        issue["nearby_stringers"]=[q for (q,i) in enumerate(g.stringer_indices) if i in columns]
    end
    result
end

"""Movable regions use their own physical rib numbers, never the wing rib indices."""
function movable_mesh_quality_issues(reg,p,groups,metadata)
    surfaces=Dict(s["name"]=>s for s in get(metadata,"surfaces",Any[]))
    rows=movable_structure_rows(p);regions=Dict{Tuple{String,Int,Int,String},Dict{String,Any}}()
    for group in groups
        group.kind in (:quad,:tria)||continue
        family,index=divrem(group.pid,1_000_000);31<=family<=35||continue
        si,station=divrem(index,1000);1<=si<=length(rows)||continue
        name=rows[si]["surface"];haskey(surfaces,name)||continue
        surface=surfaces[name];rib_etas=surface["rib_etas"]
        rib=clamp(station,1,length(rib_etas)-1)
        n=group.kind===:quad ? 4 : 3
        for (e,eid) in enumerate(group.eids)
            ids=view(group.conn,n*(e-1)+1:n*e);quality=main_shell_quality(reg,ids)
            quality.valid&&quality.edge_ratio<=MAIN_MESH_MAX_EDGE_RATIO&&quality.minimum_angle>=MAIN_MESH_MIN_ANGLE_DEG&&quality.maximum_angle<=180-MAIN_MESH_MIN_ANGLE_DEG&&continue
            severity=quality.valid ? "warning" : "error"
            issue=get!(regions,(name,family,station,severity)) do
                part=("upper skin","lower skin","front spar web","spar web","rib web at local R$station")[family-30]
                Dict{String,Any}("component"=>"$name $part","surface"=>name,"rib_reference"=>"movable",
                    "rib_start"=>rib,"rib_end"=>rib+1,"rib_start_eta"=>rib_etas[rib],"rib_end_eta"=>rib_etas[rib+1],
                    "movable_station"=>station,"severity"=>severity,"element_ids"=>Int[],"property_ids"=>[group.pid],
                    "eta_min"=>rib_etas[rib],"eta_max"=>rib_etas[rib+1],"minimum_corner_deg"=>180.,
                    "maximum_corner_deg"=>0.,"maximum_edge_ratio"=>0.,"inverted_or_collapsed"=>false,
                    "nearby_controls"=>Dict{String,Any}[],"nearby_stringers"=>Int[])
            end
            push!(issue["element_ids"],eid)
            issue["minimum_corner_deg"]=min(issue["minimum_corner_deg"],quality.minimum_angle)
            issue["maximum_corner_deg"]=max(issue["maximum_corner_deg"],quality.maximum_angle)
            issue["maximum_edge_ratio"]=max(issue["maximum_edge_ratio"],quality.edge_ratio)
            issue["inverted_or_collapsed"]|=!quality.valid
        end
    end
    result=sort!(collect(values(regions));by=i->(i["surface"],i["rib_start"],i["component"]))
    foreach(i->i["count"]=length(i["element_ids"]),result)
    result
end

# Suggested coincidences must round-trip exactly: a shortened eta copied back
# into the form could otherwise introduce another microscopic geometric gap.
mesh_eta_label(x)=string(Float64(x))
"""Deduplicate physical edits shared by skin and spar diagnostic regions.

These are suggestions, never automatic repairs: alignment changes the Study's
physical geometry and is appropriate only when coincident features are intended.
"""
function main_mesh_quality_actions(issues)
    actions=Dict{String,Any}[];seen=Dict{String,Dict{String,Any}}()
    for issue in issues
        localrib=get(issue,"rib_reference","")=="movable"
        region="$(issue["component"]), $(localrib ? "local " : "")R$(issue["rib_start"])-R$(issue["rib_end"])"
        if localrib
            id="movable:$(issue["surface"])"
            if haskey(seen,id)
                push!(seen[id]["regions"],region)
            else
                name=issue["surface"]
                action=Dict{String,Any}("id"=>id,"kind"=>"review_movable_rib_bay","label"=>region,
                    "menu"=>"Structure / Movable surfaces","surface"=>name,"regions"=>[region],"automatic"=>false,
                    "message"=>"In Structure / Movable surfaces, select $name and review the local rib ranges listed in the affected regions. Check attachment-rib placement and the secondary-spar fraction. Separate unintended close physical features, or increase the elements along the longer cell direction (chord, span or web height). Global wing rib numbers do not identify these local ribs.")
                push!(actions,action);seen[id]=action
            end
            continue
        end
        for c in issue["nearby_controls"]
            id="$(c["key"]):$(c["row"]):R$(c["nearest_rib"])"
            if haskey(seen,id)
                push!(seen[id]["regions"],region);continue
            end
            rib=c["nearest_rib"];row=c["master_rib_row"]
            ribedit=row===nothing ? "Structure / Ribs, the pitch or angle defining R$rib" : "Structure / Ribs, master-rib row $row"
            message="$(c["label"]) at eta $(mesh_eta_label(c["eta"])) is $(@sprintf("%.3f",c["distance_mm"])) mm in span from R$rib at eta $(mesh_eta_label(c["rib_eta"])). Review $(c["menu"]) or $ribedit. If they should coincide, explicitly set the point eta to $(mesh_eta_label(c["rib_eta"])); otherwise separate the features or refine their long mesh direction."
            action=merge(copy(c),Dict{String,Any}("id"=>id,"kind"=>"review_geometry_control",
                "target_eta"=>c["rib_eta"],"message"=>message,"regions"=>[region],"automatic"=>false))
            push!(actions,action);seen[id]=action
        end
        if isempty(issue["nearby_controls"])
            id="rib_bay:$(issue["rib_start"]):$(issue["rib_end"])"
            if haskey(seen,id)
                push!(seen[id]["regions"],region)
            else
                stringers=issue["nearby_stringers"]
                suffix=isempty(stringers) ? "" : " and stringers $(join(first(stringers,8),", "))"
                action=Dict{String,Any}("id"=>id,"kind"=>"review_rib_bay","label"=>"R$(issue["rib_start"])-R$(issue["rib_end"])",
                    "menu"=>"Structure / Ribs","rib_start"=>issue["rib_start"],"rib_end"=>issue["rib_end"],
                    "message"=>"Review R$(issue["rib_start"])/R$(issue["rib_end"]) positions and angles in Structure / Ribs$suffix. Move the conflicting physical boundary, reduce its obliquity, or refine the long element direction.",
                    "regions"=>[region],"automatic"=>false)
                push!(actions,action);seen[id]=action
            end
        end
        skin=occursin("skin",lowercase(issue["component"]))
        id=skin ? "refine_skin" : "refine_web"
        if haskey(seen,id)
            push!(seen[id]["regions"],region)
        else
            text=skin ? "For a short spanwise feature, increase Mesh / elements between stringers (leading-edge chord elements for nose skins); for long span cells, increase elements between ribs. Refinement must improve the reported angles, not add a parallel narrow strip." :
                "For a short spanwise feature on a spar web, increase Mesh / spar-height elements. For a narrow rib-web cell, refine its long direction or move the conflicting spar/stringer boundary."
            action=Dict{String,Any}("id"=>id,"kind"=>"review_refinement","label"=>(skin ? "Skin refinement" : "Web refinement"),
                "menu"=>"Mesh","message"=>text,"regions"=>[region],"automatic"=>false)
            push!(actions,action);seen[id]=action
        end
    end
    foreach(a->unique!(a["regions"]),actions)
    actions
end

function main_mesh_quality_message(issues)
    isempty(issues)&&return "Wing-box, leading-edge and movable-surface shell quality checks passed."
    fatal=any(i->i["severity"]=="error",issues)
    count=sum(issue["count"] for issue in issues)
    lines=[fatal ? "Mesh generation stopped: invalid shell faces were found in the locations below." :
        "Mesh generated with $count quality warnings in $(length(issues)) physical regions. You can inspect, edit and analyse this model; review these regions before relying on its results.",
        "Recommended: corner angles 10 to 170 degrees and edge ratio at most 15. Collapsed, inverted or invalid faces stop generation. No rib, spar or control point has been moved."]
    fatal&&push!(lines,"Element IDs below belong to the rejected mesh; a previously displayed mesh may have different IDs.")
    for issue in first(issues,12)
        a,b=issue["rib_start"],issue["rib_end"]
        prefix=get(issue,"rib_reference","")=="movable" ? "local " : ""
        push!(lines,"\n$(issue["component"]), $(prefix)R$(a)-R$(b) (eta $(mesh_eta_label(issue["rib_start_eta"]))-$(mesh_eta_label(issue["rib_end_eta"]))): $(issue["count"]) elements; smallest corner $(@sprintf("%.2f",issue["minimum_corner_deg"])) deg, largest edge ratio $(@sprintf("%.2f",issue["maximum_edge_ratio"])).")
        issue["maximum_corner_deg"]>180-MAIN_MESH_MIN_ANGLE_DEG&&push!(lines,"Largest corner $(@sprintf("%.2f",issue["maximum_corner_deg"])) deg exceeds 170 deg.")
        issue["inverted_or_collapsed"]&&push!(lines,"This region contains an inverted, collapsed or invalid face; correct its boundary geometry before refinement.")
        push!(lines,"Affected eta $(mesh_eta_label(issue["eta_min"]))-$(mesh_eta_label(issue["eta_max"])); example element IDs: $(join(first(issue["element_ids"],6),", ")).")
    end
    length(issues)>12&&push!(lines,"$(length(issues)-12) additional affected regions are included in the diagnostic details.")
    actions=main_mesh_quality_actions(issues)
    isempty(actions)||push!(lines,"\nSuggested edits (not applied):")
    append!(lines,[a["message"] for a in actions])
    join(lines,"\n")
end

"""Return advisory quality metadata; only genuinely invalid faces are fatal."""
function validate_main_mesh_quality(reg,g,p,groups;movable_structure=Dict{String,Any}())
    issues=main_mesh_quality_issues(reg,g,p,groups)
    append!(issues,movable_mesh_quality_issues(reg,p,groups,movable_structure))
    errors=filter(i->i["severity"]=="error",issues)
    isempty(errors)||throw(MeshQualityError(main_mesh_quality_message(issues),issues))
    count=sum((issue["count"] for issue in issues);init=0)
    Dict{String,Any}("status"=>isempty(issues) ? "ok" : "warning",
        "severity"=>isempty(issues) ? "none" : "warning", "analysis_allowed"=>true,
        "warning_count"=>count,"warning_element_count"=>count,"warning_region_count"=>length(issues),"error_element_count"=>0,
        "issues"=>issues,"actions"=>main_mesh_quality_actions(issues),
        "message"=>main_mesh_quality_message(issues),
        "scope"=>"Main wing-box, leading-edge and movable-surface skins, spar webs and rib webs. Thin stringer blades/flanges and hinge fittings are outside this proportion check.",
        "thresholds"=>Dict("minimum_corner_deg"=>MAIN_MESH_MIN_ANGLE_DEG,
            "maximum_corner_deg"=>180-MAIN_MESH_MIN_ANGLE_DEG,"maximum_edge_ratio"=>MAIN_MESH_MAX_EDGE_RATIO,
            "nonfatal"=>true),
        "geometry_modified"=>false)
end
