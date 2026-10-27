# Geometry and materials for the local free-web instability assessment.
# This is postprocessing metadata: it never changes the FE model or results.

"""Physical beam stringer segments and their actual PBARL free-web dimensions.

The unsupported blade height is DIM2-DIM3, measured from the attached
flange/web junction to the free tip; a zero-flange PBARL BAR uses its full height from the attached skin edge. Fixed-area runout connectors, rib bars
and spar caps are excluded. Normal T-stringer segments ending at a runout
remain eligible for the long-outstand-plate check; it does not require the
two rib restraints used by the separate global Euler-column check.
"""
function stringer_blade_payload(m::Model;layout=nothing)
    is_imported_model(m)&&return Any[]
    layout===nothing&&(layout=stiffened_panel_layout(m.grid))
    isempty(layout.panels)&&return Any[]
    owned=Dict{Int,Vector{ElemGroup}}()
    members=Dict{Int,Vector{Int}}()
    for group in m.groups
        if component_base_pid(group.pid) in (PID_STRINGER,PID_STRINGER_WEB)
            id=stiffened_panel_id(group.pid)
            id===nothing||append!(get!(members,id,Int[]),group.eids)
        end
        group.kind===:bar&&component_base_pid(group.pid)==PID_STRINGER||continue
        panel_id=stiffened_panel_id(group.pid)
        panel_id===nothing&&continue
        push!(get!(owned,panel_id,ElemGroup[]),group)
    end
    sections=Dict{Int,Dict{String,Any}}()
    rows=Dict{String,Any}[]
    for panel in layout.panels
        skin=panel.upper ? "upper" : "lower"
        start_rib=panel.start_row==m.grid.ribs[panel.bay] ? panel.bay : nothing
        end_rib=panel.end_row==m.grid.ribs[panel.bay+1] ? panel.bay+1 : nothing
        row=Dict{String,Any}("panel_id"=>panel.id,"key"=>panel_key(panel),"skin"=>skin,
            "label"=>"$(uppercasefirst(skin)) · R$(panel.bay)–R$(panel.bay+1) · stringer $(panel.stringer)",
            "rib_bay"=>panel.bay,"stringer"=>panel.stringer,"segment"=>panel.segment,
            "pid"=>shell_stringers(m.params) ? panel_stringer_web_pid(panel.id) : panel.stringer_pid,
            "start_rib"=>start_rib,"end_rib"=>end_rib,
            "start_kind"=>start_rib===nothing ? "runout" : "rib",
            "end_kind"=>end_rib===nothing ? "runout" : "rib",
            "start_eta"=>m.grid.etas[panel.start_row+1],"end_eta"=>m.grid.etas[panel.end_row+1],
            "length_m"=>0.,"bars"=>Any[],"status"=>"unassessed","reason"=>"",
            "member_element_ids"=>sort!(unique(get(members,panel.id,Int[]))),"membership_complete"=>true,
            "applicable"=>!shell_stringers(m.params),
            "method"=>"Elastic isotropic long outstand plate; supported attached edge and free web tip; arithmetic mean of signed bar axial stresses")
        push!(rows,row)
        if shell_stringers(m.params)
            row["reason"]="This bar-stress blade check requires beam stringers; shell-stringer stresses need a separate plate assessment"
            continue
        end
        try
            groups=get(owned,panel.id,ElemGroup[])
            isempty(groups)&&throw(ArgumentError("No physical stringer bars are available for this segment"))
            seen=Set{Int}()
            for group in groups
                section=get!(sections,group.pid) do
                    definition=section_definition(m.params,group.pid)
                    shape=get(definition,"shape","")
                    get(definition,"type","")=="PBARL"&&shape in ("T","BAR")||
                        throw(ArgumentError("The blade check requires an actual PBARL T or rectangular blade section"))
                    dimensions=Float64.(definition["dimensions_m"])
                    web_height,web=if shape=="BAR"
                        thickness,height=dimensions;iszero(panel_stringer_dimensions(m.params,group.pid)[1])||
                            throw(ArgumentError("A rectangular free-web check requires a blade attached along one edge"))
                        height,thickness
                    else
                        width,height,flange,thickness=dimensions
                        height-flange,thickness
                    end
                    all(isfinite,dimensions)&&minimum(dimensions)>0&&web_height>0||
                        throw(ArgumentError("The stringer section has invalid free-web dimensions"))
                    material=bar_material_definition(m.params,group.pid)
                    young=Float64(material["E"]);poisson=Float64(material["nu"])
                    isfinite(young)&&young>0&&isfinite(poisson)&&-1<poisson<.5||
                        throw(ArgumentError("The blade check requires a positive isotropic Young's modulus and -1 < Poisson ratio < 0.5"))
                    Dict{String,Any}("pid"=>group.pid,"source"=>"PBARL","section_shape"=>shape,
                        "dimensions_m"=>dimensions,"web_height_m"=>web_height,"web_thickness_m"=>web,
                        "young_pa"=>young,"poisson"=>poisson,"material_id"=>Int(material["id"]),"material_type"=>"MAT1")
                end
                length(group.conn)==2length(group.eids)||throw(ArgumentError("Stringer bar connectivity is incomplete"))
                for index in eachindex(group.eids)
                    eid=group.eids[index]
                    eid in seen&&throw(ArgumentError("A stringer bar occurs more than once in this segment"))
                    push!(seen,eid)
                    points=element_points(m,group,index)
                    member_length=norm3(points[2].-points[1])
                    isfinite(member_length)&&member_length>0||throw(ArgumentError("A stringer bar has zero or invalid length"))
                    push!(row["bars"],merge(section,Dict("eid"=>eid,"length_m"=>member_length)))
                    row["length_m"]+=member_length
                end
            end
            isempty(row["bars"])&&throw(ArgumentError("No physical stringer bars are available for this segment"))
            sort!(row["bars"];by=bar->bar["eid"])
            row["status"]="ready"
        catch failure
            failure isa ArgumentError||rethrow()
            row["reason"]=sprint(showerror,failure)
            empty!(row["bars"]);row["length_m"]=0.
        end
    end
    rows
end
