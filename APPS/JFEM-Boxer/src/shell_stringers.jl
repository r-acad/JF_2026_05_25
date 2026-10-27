# Shell stringers use shared skin nodes throughout their flange footprint.
# One skin-plus-flange section replaces the skin in each flange footprint, and
# the blade extends inward by h-tf, or h for a blade-only section. Ribs attach
# through this skin footprint; blade/rib interior crossings are not welded or
# rigidly linked. The existing small-area runout connector remains at runouts.

"""An exact surface point on a physical skin row, between coarse columns."""
function shell_stringer_row_point(g,bay,j,t,upper)
    xcs=upper ? g.upper_xcs : g.lower_xcs
    spans=upper ? g.upper_etas : g.lower_etas
    if t==0 || t==1
        i=bay+Int(t)
        return spans[i+1,j+1],xcs[i+1,j+1]
    end
    if !oriented_ribs(g)
        return g.etas[j+1],(1-t)*xcs[bay+1,j+1]+t*xcs[bay+2,j+1]
    end
    context=g.rib_layout
    ls=bay==0 ? -1 : g.collapsed[bay+1,j+1]
    rs=bay+1==ni(g) ? 1 : g.collapsed[bay+2,j+1]
    xc(eta)=(1-t)*rib_curve_xc(g.wing,context,bay+1,ls,eta,upper)+t*rib_curve_xc(g.wing,context,bay+2,rs,eta,upper)
    plane=main_rib_plane(g.wing,context,g.etas[j+1])
    surface=upper ? upper_point : lower_point
    cuts=rib_intersection_cuts(g.wing,context,last(g.etas))
    eta,_=rib_curve_intersection(e->surface(g.wing,e,xc(e)),plane,cuts,"shell stringer flange footprint")
    return eta,xc(eta)
end

function shell_stringer_offset_fraction(g,bay,j,width,from_right,upper)
    width==0&&return from_right ? 1.0 : 0.0
    surface=upper ? upper_point : lower_point
    position(t)=surface(g.wing,shell_stringer_row_point(g,bay,j,t,upper)...)
    anchor=position(from_right ? 1.0 : 0.0)
    available=norm3(position(from_right ? 0.0 : 1.0).-anchor)
    width<available-1e-10||throw(ArgumentError("shell stringer flange width does not fit between physical boundaries at row $(j+1); reduce flange width or increase stringer pitch"))
    lo,hi=0.,1.
    for _ in 1:38
        t=(lo+hi)/2
        distance=norm3(position(from_right ? 1-t : t).-anchor)
        distance<width ? (lo=t) : (hi=t)
    end
    t=(lo+hi)/2
    return from_right ? 1-t : t
end

"""Insert flange edges, retaining exact physical paths and panel identities.

All flange widths used by either skin/bay on a physical line are represented
on both skins. Width steps therefore share the same rib-row nodes. The mesh
setting controls subdivisions of the remaining gap between flange footprints.
"""
function shell_stringer_grid(coarse::BoxGrid,p)
    layout=stiffened_panel_layout(coarse)
    register_panel_properties!(p,coarse;layout)
    widths=Dict(i=>Float64[] for i in coarse.stringer_indices)
    for panel in layout.panels
        b=first(panel_stringer_dimensions(p,panel_stringer_pid(panel.id)))
        b>0&&push!(widths[panel.column],b/2)
    end
    for vals in values(widths);sort!(unique!(vals));end
    n=Int(get(p,"mesh.elements_between_stringers",1))
    specs=NamedTuple[];physical=Int[];edgecols=Dict{Tuple{Int,Float64,Int},Int}()
    for bay in 0:ni(coarse)-1
        bay>0&&push!(physical,length(specs))
        push!(specs,(bay=bay,kind=:fixed,value=0.))
        left=get(widths,bay,Float64[]);right=get(widths,bay+1,Float64[])
        for width in left
            edgecols[(bay,width,1)]=length(specs)
            push!(specs,(bay=bay,kind=:left,value=width))
        end
        for q in 1:n-1
            push!(specs,(bay=bay,kind=:gap,value=q/n))
        end
        for width in reverse(right)
            edgecols[(bay+1,width,-1)]=length(specs)
            push!(specs,(bay=bay,kind=:right,value=width))
        end
    end
    push!(specs,(bay=ni(coarse)-1,kind=:fixed,value=1.))
    count=length(specs);rows=length(coarse.etas)
    lower=zeros(count,rows);upper=similar(lower);le=similar(lower);ue=similar(lower)
    fractions=Dict(false=>similar(lower),true=>similar(lower));collapsed=zeros(Int,count,rows)
    offsets=Dict{Tuple{Int,Int,Float64,Bool,Bool},Float64}()
    offset(bay,j,width,right,up)=get!(()->shell_stringer_offset_fraction(coarse,bay,j,width,right,up),offsets,(bay,j,width,right,up))
    for (dst,spec) in enumerate(specs),j in 0:nj(coarse)
        bay=spec.bay
        ls=bay==0 ? -1 : coarse.collapsed[bay+1,j+1]
        rs=bay+1==ni(coarse) ? 1 : coarse.collapsed[bay+2,j+1]
        for up in (false,true)
            left=get(widths,bay,Float64[]);right=get(widths,bay+1,Float64[])
            lf=isempty(left)||ls!=0 ? 0. : offset(bay,j,last(left),false,up)
            rf=isempty(right)||rs!=0 ? 1. : offset(bay,j,last(right),true,up)
            ls==rs || lf<rf-1e-10 || throw(ArgumentError("shell stringer flange footprints overlap at skin row $(j+1); reduce the widths or increase the pitch"))
            t=spec.kind===:fixed ? spec.value : spec.kind===:gap ? (1-spec.value)*lf+spec.value*rf :
                spec.kind===:left ? (ls!=0 ? 0. : offset(bay,j,spec.value,false,up)) :
                (rs!=0 ? 1. : offset(bay,j,spec.value,true,up))
            fractions[up][dst,j+1]=t
            eta,xc=shell_stringer_row_point(coarse,bay,j,t,up)
            (up ? upper : lower)[dst,j+1]=xc;(up ? ue : le)[dst,j+1]=eta
            side=ls==rs ? ls : t==0 ? ls : t==1 ? rs : 0
            # Actual spar columns are not marked collapsed, as in the base grid.
            collapsed[dst,j+1]=dst in (1,count) ? 0 : side
        end
    end
    xcs=copy(lower[:,1])
    metadata=(;coarse,specs,fractions,edgecols,widths,blade_bases=Dict{Int,NTuple{3,Float64}}(),
        axis_cache=Dict{Tuple{Int,String},Any}())
    grid=BoxGrid(coarse.wing,xcs,coarse.etas,coarse.nh,coarse.ribs,lower,upper,collapsed,physical,le,ue,coarse.rib_layout,metadata)
    oriented_ribs(grid)&&validate_rib_grid_order(grid)
    return grid
end

"""Preserve local kink knots after adding nonuniform footprint columns."""
function shell_stringer_kink_point(g,i,j,eta,upper)
    data=g.shell_columns;coarse=data.coarse;spec=data.specs[i+1]
    spans=upper ? g.upper_etas : g.lower_etas
    a,b=spans[i+1,j+1],spans[i+1,j+2]
    u=clamp((eta-a)/(b-a),0.,1.)
    t=(1-u)*data.fractions[upper][i+1,j+1]+u*data.fractions[upper][i+1,j+2]
    bay=spec.bay;ls=bay==0 ? -1 : coarse.collapsed[bay+1,j+1]
    rs=bay+1==ni(coarse) ? 1 : coarse.collapsed[bay+2,j+1]
    xc=(1-t)*rib_curve_xc(g.wing,coarse.rib_layout,bay+1,ls,eta,upper)+t*rib_curve_xc(g.wing,coarse.rib_layout,bay+2,rs,eta,upper)
    return (upper ? upper_point : lower_point)(g.wing,eta,xc)
end

"""Local loft normal, independent of chordwise shell refinement."""
function shell_stringer_inward(g::BoxGrid,i::Int,j::Int,upper::Bool)
    eta=grid_surface_eta(g,i,j,upper);xc=(upper ? g.upper_xcs : g.lower_xcs)[i+1,j+1]
    return shell_stringer_inward(g.wing,eta,xc,upper)
end

function shell_stringer_inward(w::Wing,eta::Real,xc::Real,upper::Bool)
    surface=upper ? upper_point : lower_point
    delta=1e-6
    ea,eb=max(0.,eta-delta),min(1.,eta+delta)
    dspan=surface(w,eb,xc).-surface(w,ea,xc)
    dchord=surface(w,eta,xc+delta).-surface(w,eta,xc-delta)
    normal=unit3(cross3(dchord,dspan))
    norm3(normal)>.5||throw(ArgumentError("cannot determine shell stringer skin normal at ETA $eta"))
    return (upper ? -1. : 1.).*normal
end

function shell_stringer_direction(inward,axis)
    axis===nothing&&return inward
    alignment=sum(axis.*inward)
    abs(alignment)>1e-5||throw(ArgumentError("selected coordinate axis is tangent to the skin at a shell stringer; choose an axis pointing through the skin"))
    return sign(alignment).*axis
end

function add_shell_stringers!(reg,g,p,groups,layout,eid)
    axis=stringer_axis_direction(p,g,reg,groups)
    n=Int(get(p,"mesh.elements_stringer_height",2))
    levels=Dict{Tuple{Int,Bool},Vector{Float64}}()
    dims=Dict(panel.id=>panel_stringer_dimensions(p,panel_stringer_pid(panel.id)) for panel in layout.panels)
    for panel in layout.panels
        b,h,tf,_=dims[panel.id];height=b>0 ? h-tf : h
        append!(get!(levels,(panel.column,panel.upper),Float64[]),[height*q/n for q in 1:n])
    end
    for vals in values(levels);sort!(unique!(vals));end
    nodes=Dict{Tuple{Int,Int,Bool,Float64},Int}();cache=Dict{Tuple{String,Symbol,Int},ElemGroup}()
    replaced=Set{Tuple}()
    function blade_node(i,j,upper,height)
        height==0&&return node!(reg,g,i,j,upper ? g.nh : 0)
        get!(nodes,(i,j,upper,height)) do
            inward=shell_stringer_inward(g,i,j,upper)
            direction=shell_stringer_direction(inward,axis)
            base=grid_point(g,i,j,upper ? g.nh : 0)
            position=base.+height.*direction
            # Positive row indices remain valid for shell frames, loads and
            # physical component metadata; negative height cannot alias box nodes.
            key=(i,j,-length(reg.keys)-2)
            push!(reg.keys,key);append!(reg.xyz,position)
            id=length(reg.keys);reg.index[key]=id;g.shell_columns.blade_bases[id]=base;id
        end
    end
    function shell!(name,pid,base,conn)
        unique_nodes=unique(conn);length(unique_nodes)<3&&return
        kind=length(unique_nodes)==3 ? :tria : :quad
        group=panel_element_group!(groups,cache,name,kind,pid,base)
        push!(group.eids,eid);append!(group.conn,unique_nodes);eid+=1
    end
    for panel in layout.panels
        i=panel.column;upper=panel.upper;k=upper ? g.nh : 0
        b,h,tf,_=dims[panel.id];height=b>0 ? h-tf : h
        heights=vcat(0.,filter(v->v<=height+1e-12,levels[(i,upper)]))
        for j in panel.start_row:panel.end_row-1,q in 1:length(heights)-1
            shell!("STRINGER_WEBS",panel_stringer_web_pid(panel.id),PID_STRINGER_WEB,
                [blade_node(i,j,upper,heights[q]),blade_node(i,j+1,upper,heights[q]),
                 blade_node(i,j+1,upper,heights[q+1]),blade_node(i,j,upper,heights[q+1])])
        end
        if b>0
            physical=findfirst(==(i),g.stringer_indices)
            left=g.shell_columns.edgecols[(physical,b/2,-1)]
            right=g.shell_columns.edgecols[(physical,b/2,1)]
            for j in panel.start_row:panel.end_row-1,column in left:right-1
                conn=[node!(reg,g,column,j,k),node!(reg,g,column+1,j,k),node!(reg,g,column+1,j+1,k),node!(reg,g,column,j+1,k)]
                # Match the underlying skin's starting corner as well as
                # winding, so local kink triangulation chooses identical faces.
                !upper&&(conn=conn[[1,4,3,2]])
                push!(replaced,Tuple(sort(unique(conn))))
                shell!("STRINGER_FLANGES",panel_stringer_flange_pid(panel.id),PID_STRINGER_FLANGE,conn)
            end
        end
    end
    # The flange property already includes its selected underlying skin.
    # Delete the coincident skin face, retaining its boundary nodes and all
    # skins outside the exact footprint. Kink splitting runs afterwards on
    # this single connected shell layer.
    for group in groups
        component_base_pid(group.pid) in (PID_SKIN_UPPER,PID_SKIN_LOWER)||continue
        n=group.kind===:tria ? 3 : 4
        keep=[e for e in eachindex(group.eids) if !(Tuple(sort(group.conn[n*(e-1)+1:n*e])) in replaced)]
        kept_conn=[node for e in keep for node in group.conn[n*(e-1)+1:n*e]]
        kept_eids=group.eids[keep]
        empty!(group.conn);append!(group.conn,kept_conn)
        empty!(group.eids);append!(group.eids,kept_eids)
    end
    filter!(group->!isempty(group.eids),groups)
    return eid
end

"""Resolve every blade rail at the same physical kinks as its skin base."""
function add_shell_stringer_kink_splits!(reg,g,p,groups,splits,breaks)
    axis=stringer_axis_direction(p,g,reg,groups)
    panels=Dict(panel.id=>panel for panel in stiffened_panel_layout(g).panels)
    visited=Set{Tuple{Int,Int}}()
    for group in groups
        component_base_pid(group.pid)==PID_STRINGER_WEB||continue
        panel=panels[stiffened_panel_id(group.pid)];i=panel.column;upper=panel.upper
        physical=findfirst(==(i),g.stringer_indices);n=group.kind===:quad ? 4 : 3
        for e in eachindex(group.eids),q in 1:n
            conn=view(group.conn,n*(e-1)+1:n*e);a,b=conn[q],conn[mod1(q+1,n)]
            ka,kb=reg.keys[a],reg.keys[b]
            ka[3]<0&&kb[3]<0&&ka[2]!=kb[2]||continue
            edge=minmax(a,b);edge in visited&&continue;push!(visited,edge)
            ka[2]>kb[2]&&((a,b,ka,kb)=(b,a,kb,ka))
            j=ka[2]
            ea=grid_surface_eta(g,i,ka[2],upper);eb=grid_surface_eta(g,i,kb[2],upper)
            cuts=filter(eta->ea+1e-10<eta<eb-1e-10,breaks);isempty(cuts)&&continue
            height=norm3(Tuple(reg.xyz[3a-2:3a]).-grid_point(g,i,j,upper ? g.nh : 0))
            chain=Int[a]
            for eta in cuts
                xc=rib_curve_xc(g.wing,g.shell_columns.coarse.rib_layout,physical+1,0,eta,upper)
                base=(upper ? upper_point : lower_point)(g.wing,eta,xc)
                direction=shell_stringer_direction(shell_stringer_inward(g.wing,eta,xc,upper),axis)
                key=(i,j,-length(reg.keys)-2)
                push!(reg.keys,key);append!(reg.xyz,base.+height.*direction)
                id=length(reg.keys);reg.index[key]=id;g.shell_columns.blade_bases[id]=base;push!(chain,id)
            end
            push!(chain,b);splits[(a,b)]=chain;splits[(b,a)]=reverse(chain)
        end
    end
    nothing
end

"""Only exposed blade tips and physical segment ends may have free edges."""
function shell_stringer_unexpected_free_edges(m,edges)
    panels=Dict(panel.id=>panel for panel in stiffened_panel_layout(m.grid).panels)
    expected=Set{Tuple{Int,Int}}()
    for group in m.groups
        component_base_pid(group.pid)==PID_STRINGER_WEB||continue
        panel=panels[stiffened_panel_id(group.pid)]
        b,h,tf,_=panel_stringer_dimensions(m.params,group.pid);height=b>0 ? h-tf : h
        k=panel.upper ? m.grid.nh : 0;n=group.kind===:quad ? 4 : 3
        for e in eachindex(group.eids),q in 1:n
            conn=view(group.conn,n*(e-1)+1:n*e);a,b=conn[q],conn[mod1(q+1,n)]
            edge=minmax(a,b);get(edges,edge,0)==1||continue
            ja,jb=m.node_keys[a][2],m.node_keys[b][2]
            at_end=ja==jb&&ja in (panel.start_row,panel.end_row)
            if at_end
                plane=main_rib_plane(m.grid,m.params,ja)
                # Local-kink nodes retain the inboard row index. Test their
                # actual skin footpoints so an exposed longitudinal crack
                # cannot masquerade as a permitted physical blade end.
                at_end=all(abs(sum(plane.normal.*(get(m.grid.shell_columns.blade_bases,node,
                    Tuple(m.xyz[3node-2:3node])).-plane.origin)))<=2e-11plane.scale for node in (a,b))
            end
            at_tip=all(isapprox(norm3(Tuple(m.xyz[3node-2:3node]).-get(m.grid.shell_columns.blade_bases,node,grid_point(m.grid,panel.column,j,k))),height;atol=1e-9,rtol=1e-8)
                for (node,j) in ((a,ja),(b,jb)))
            (at_end||at_tip)&&push!(expected,edge)
        end
    end
    return count(pair->pair.second==1&&!(pair.first in expected),edges)
end
