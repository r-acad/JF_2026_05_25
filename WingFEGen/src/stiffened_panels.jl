# Panels are physical stringer segments, not individual shell/CBAR elements.
# The layout is deterministic; sparse overrides use physical keys and a layout token.
const PANEL_UPPER_FAMILY=5
const PANEL_LOWER_FAMILY=6
const PANEL_STRINGER_FAMILY=7
stiffened_panel_id(pid::Integer)=pid÷COMPONENT_PID_STRIDE in (5,6,7) ? pid%COMPONENT_PID_STRIDE : nothing
panel_skin_pid(id,upper)=(upper ? PANEL_UPPER_FAMILY : PANEL_LOWER_FAMILY)*COMPONENT_PID_STRIDE+id
panel_stringer_pid(id)=PANEL_STRINGER_FAMILY*COMPONENT_PID_STRIDE+id

function stiffened_panel_layout(g::BoxGrid)
    panels=NamedTuple[];bars=Dict{Tuple{Int,Int,Bool},Int}()
    for upper in (false,true),bay in 1:length(g.ribs)-1,(stringer,i) in enumerate(g.stringer_indices)
        firstrow,lastrow=g.ribs[bay:bay+1];j=firstrow;segment=0
        while j<lastrow
            if g.collapsed[i+1,j+1]!=0||g.collapsed[i+1,j+2]!=0
                j+=1;continue
            end
            start=j
            while j<lastrow&&g.collapsed[i+1,j+1]==0&&g.collapsed[i+1,j+2]==0;j+=1;end
            segment+=1;id=length(panels)+1
            id<COMPONENT_PID_STRIDE||throw(ArgumentError("The panel layout exceeds 999999 stiffened panels"))
            push!(panels,(;id,upper,bay,stringer,column=i,segment,start_row=start,end_row=j,
                shell_pid=panel_skin_pid(id,upper),stringer_pid=panel_stringer_pid(id)))
            for row in start:j-1;bars[(i,row,upper)]=id;end
        end
    end
    # Every shell in a row strip belongs to its forward normal stringer.
    # Before the first normal stringer, use that foremost stringer's same PID.
    # If all normal stringers have ended, keep that strip explicitly unstiffened.
    skins=Dict{Bool,Matrix{Int}}()
    for upper in (false,true)
        owners=zeros(Int,ni(g),nj(g))
        for j in 0:nj(g)-1
            active=[i for i in g.stringer_indices if haskey(bars,(i,j,upper))]
            isempty(active)&&continue
            for i in 0:ni(g)-1
                q=max(1,searchsortedlast(active,i))
                owners[i+1,j+1]=bars[(active[q],j,upper)]
            end
        end
        skins[upper]=owners
    end
    (;panels,bars,skins)
end

function panel_element_group!(groups,cache,name,kind,pid,basepid)
    get!(cache,(String(name),kind,pid)) do
        group=ElemGroup(pid==basepid ? name : name*"_P"*string(pid),kind,pid)
        push!(groups,group);group
    end
end

function stiffened_panels_payload(m::Model)
    layout=stiffened_panel_layout(m.grid)
    context=register_panel_properties!(m.params,m.grid;layout)
    owned=Dict{Int,Vector{ElemGroup}}()
    unassigned=Dict("upper"=>Int[],"lower"=>Int[])
    for group in m.groups
        isempty(group.eids)&&continue
        id=stiffened_panel_id(group.pid)
        if id!==nothing;push!(get!(owned,id,ElemGroup[]),group)
        elseif group.pid in (PID_SKIN_UPPER,PID_SKIN_LOWER)
            append!(unassigned[group.pid==PID_SKIN_UPPER ? "upper" : "lower"],group.eids)
        end
    end
    rows=Dict{String,Any}[]
    for panel in layout.panels
        groups=get(owned,panel.id,ElemGroup[]);isempty(groups)&&continue # legacy serialized mesh
        shells=[g for g in groups if g.kind!==:bar];bars=[g for g in groups if g.kind===:bar]
        shellids=sort!([e for g in shells for e in g.eids]);barids=sort!([e for g in bars for e in g.eids])
        skin=panel.upper ? "upper" : "lower"
        start_rib=panel.start_row==m.grid.ribs[panel.bay] ? panel.bay : nothing
        end_rib=panel.end_row==m.grid.ribs[panel.bay+1] ? panel.bay+1 : nothing
        area=sum((weight_shell_area(element_points(m,g,e)) for g in shells for e in eachindex(g.eids));init=0.)
        bar_length=sum((norm3(points[2].-points[1]) for g in bars for e in eachindex(g.eids) for points in (element_points(m,g,e),));init=0.)
        nodeids=sort!(unique([m.node_ids[n] for g in bars for n in g.conn]))
        inherited=inherited_panel_properties(m.params,panel.upper);override=get(context.rows,panel.id,nothing)
        push!(rows,Dict{String,Any}("id"=>panel.id,"key"=>panel_key(panel),
            "label"=>"$(uppercasefirst(skin)) · R$(panel.bay)–R$(panel.bay+1) · stringer $(panel.stringer)",
            "skin"=>skin,"rib_bay"=>panel.bay,"stringer"=>panel.stringer,"segment"=>panel.segment,
            "start_rib"=>start_rib,"end_rib"=>end_rib,"start_kind"=>start_rib===nothing ? "runout" : "rib",
            "end_kind"=>end_rib===nothing ? "runout" : "rib","start_eta"=>m.grid.etas[panel.start_row+1],
            "end_eta"=>m.grid.etas[panel.end_row+1],"shell_pid"=>panel.shell_pid,"stringer_pid"=>panel.stringer_pid,
            "shell_eids"=>shellids,"stringer_eids"=>barids,"stringer_grid_ids"=>nodeids,
            "skin_area_m2"=>area,"stringer_length_m"=>bar_length,"skin_thickness_m"=>shell_thickness(m.params,panel.shell_pid),
            "stringer_dimensions_m"=>section_definition(m.params,panel.stringer_pid)["dimensions_m"],
            "inherited_skin"=>inherited.skin,"inherited_stringer"=>inherited.stringer,
            "effective_skin"=>merge(inherited.skin,override===nothing ? Dict() : get(override,"skin",Dict())),
            "effective_stringer"=>merge(inherited.stringer,override===nothing ? Dict() : get(override,"stringer",Dict())),
            "override"=>override))
    end
    Dict{String,Any}("panels"=>rows,"count"=>length(rows),"layout_token"=>context.token,"unassigned_shell_eids"=>unassigned,
        "coverage"=>Dict("assigned_shells"=>sum(length(r["shell_eids"]) for r in rows;init=0),
            "assigned_stringer_bars"=>sum(length(r["stringer_eids"]) for r in rows;init=0),
            "unassigned_shells"=>sum(length,values(unassigned))),
        "note"=>"One panel per skin and contiguous normal-stringer segment within a physical rib bay. Its skin extends aft to the next normal stringer or rear spar; the foremost active stringer also owns the forward strip. Kink triangles inherit their parent panel. Fixed-area runout connectors are excluded. Row strips with no normal stringer retain their original skin property and are reported as unassigned. Sparse panel overrides inherit blank fields from shared skin/stringer defaults. Each panel has independent thickness/section sensitivities, including inherited values. Geometry/layout changes require resetting overrides before regeneration.")
end
