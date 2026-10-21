# Panels are physical stringer segments, not individual shell/CBAR elements.
# The layout is deterministic; sparse overrides use physical keys and a layout token.
const PANEL_UPPER_FAMILY=5
const PANEL_LOWER_FAMILY=6
const PANEL_STRINGER_FAMILY=7
const PANEL_STRINGER_WEB_FAMILY=19
const PANEL_STRINGER_FLANGE_FAMILY=20
const PID_STRINGER_WEB=15
const PID_STRINGER_FLANGE=16
stiffened_panel_id(pid::Integer)=pid÷COMPONENT_PID_STRIDE in (5,6,7,19,20) ? pid%COMPONENT_PID_STRIDE : nothing
panel_skin_pid(id,upper)=(upper ? PANEL_UPPER_FAMILY : PANEL_LOWER_FAMILY)*COMPONENT_PID_STRIDE+id
panel_stringer_pid(id)=PANEL_STRINGER_FAMILY*COMPONENT_PID_STRIDE+id
panel_stringer_web_pid(id)=PANEL_STRINGER_WEB_FAMILY*COMPONENT_PID_STRIDE+id
panel_stringer_flange_pid(id)=PANEL_STRINGER_FLANGE_FAMILY*COMPONENT_PID_STRIDE+id
shell_stringers(p)=get(p,"stringers.model","beam")=="shell"
is_shell_stringer_pid(pid)=component_base_pid(pid) in (PID_STRINGER_WEB,PID_STRINGER_FLANGE)

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
    register_shell_stringer_mass_geometry!(m.params,m.groups,m.xyz,m.grid)
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
        shells=[g for g in groups if component_base_pid(g.pid) in (PID_SKIN_UPPER,PID_SKIN_LOWER)]
        stringers=[g for g in groups if g.kind===:bar||is_shell_stringer_pid(g.pid)]
        bars=[g for g in stringers if g.kind===:bar]
        webids=sort!([e for g in stringers if component_base_pid(g.pid)==PID_STRINGER_WEB for e in g.eids])
        flangeids=sort!([e for g in stringers if component_base_pid(g.pid)==PID_STRINGER_FLANGE for e in g.eids])
        shellids=sort!([e for g in shells for e in g.eids]);stringerids=sort!([e for g in stringers for e in g.eids])
        skin=panel.upper ? "upper" : "lower"
        start_rib=panel.start_row==m.grid.ribs[panel.bay] ? panel.bay : nothing
        end_rib=panel.end_row==m.grid.ribs[panel.bay+1] ? panel.bay+1 : nothing
        area=sum((weight_shell_area(element_points(m,g,e)) for g in shells for e in eachindex(g.eids));init=0.)
        bar_length=sum((norm3(points[2].-points[1]) for g in bars for e in eachindex(g.eids) for points in (element_points(m,g,e),));init=0.)
        if shell_stringers(m.params)
            bar_length=something(shell_stringer_attachment_length(m.params,panel_stringer_web_pid(panel.id)),0.)
        end
        nodeids=sort!(unique([m.node_ids[n] for g in stringers for n in g.conn]))
        inherited=inherited_panel_properties(m.params,panel.upper);override=get(context.rows,panel.id,nothing)
        push!(rows,Dict{String,Any}("id"=>panel.id,"key"=>panel_key(panel),
            "label"=>"$(uppercasefirst(skin)) · R$(panel.bay)–R$(panel.bay+1) · stringer $(panel.stringer)",
            "skin"=>skin,"rib_bay"=>panel.bay,"stringer"=>panel.stringer,"segment"=>panel.segment,
            "start_rib"=>start_rib,"end_rib"=>end_rib,"start_kind"=>start_rib===nothing ? "runout" : "rib",
            "end_kind"=>end_rib===nothing ? "runout" : "rib","start_eta"=>m.grid.etas[panel.start_row+1],
            "end_eta"=>m.grid.etas[panel.end_row+1],"shell_pid"=>panel.shell_pid,
            "stringer_pid"=>isempty(webids) ? panel.stringer_pid : panel_stringer_web_pid(panel.id),
            "stringer_model"=>shell_stringers(m.params) ? "shell" : "beam",
            "stringer_web_pid"=>isempty(webids) ? nothing : panel_stringer_web_pid(panel.id),
            "stringer_flange_pid"=>isempty(flangeids) ? nothing : panel_stringer_flange_pid(panel.id),
            "shell_eids"=>shellids,"skin_eids"=>shellids,"stringer_eids"=>stringerids,
            "stringer_web_eids"=>webids,"stringer_flange_eids"=>flangeids,"stringer_grid_ids"=>nodeids,
            "skin_area_m2"=>area,"stringer_length_m"=>bar_length,"skin_thickness_m"=>shell_thickness(m.params,panel.shell_pid),
            "stringer_dimensions_m"=>collect(panel_stringer_dimensions(m.params,panel.stringer_pid)),
            "inherited_skin"=>inherited.skin,"inherited_stringer"=>inherited.stringer,
            "effective_skin"=>merge(inherited.skin,override===nothing ? Dict() : get(override,"skin",Dict())),
            "effective_stringer"=>merge(inherited.stringer,override===nothing ? Dict() : get(override,"stringer",Dict())),
            "override"=>override))
    end
    Dict{String,Any}("panels"=>rows,"count"=>length(rows),"layout_token"=>context.token,"unassigned_shell_eids"=>unassigned,
        "euler_columns"=>stringer_euler_payload(m;layout,compact=true),
        "coverage"=>Dict("assigned_shells"=>sum(length(r["shell_eids"]) for r in rows;init=0),
            "assigned_stringer_bars"=>sum(length(g.eids) for g in m.groups if g.kind===:bar&&component_base_pid(g.pid)==PID_STRINGER;init=0),
            "assigned_stringer_shells"=>sum(length(r["stringer_web_eids"])+length(r["stringer_flange_eids"]) for r in rows;init=0),
            "unassigned_shells"=>sum(length,values(unassigned))),
        "note"=>"One panel per skin and contiguous normal-stringer segment within a physical rib bay. Its skin extends aft to the next normal stringer or rear spar; the foremost active stringer also owns the forward strip. Kink triangles inherit their parent panel. Fixed-area runout connectors are excluded. Row strips with no normal stringer retain their original skin property and are reported as unassigned. Sparse panel overrides inherit blank fields from shared skin/stringer defaults. Beam sections retain dimension sensitivities. Shell stringers expose material and web-thickness sensitivities; their width, height and flange thickness change the mesh and require regeneration. Geometry/layout changes require resetting overrides before regeneration.")
end
