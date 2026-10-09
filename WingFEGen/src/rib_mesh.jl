# Surface intersections for the existing conforming box topology. A row's
# coordinate remains its rear-spar anchor; each skin GRID has its own ETA.

function airfoil_gradient(af::Airfoil,xc::Float64,upper::Bool)
    xs,zs=upper ? (af.xu,af.zu) : (af.xl,af.zl)
    (xc<=first(xs)||xc>=last(xs))&&return 0.0
    i=clamp(searchsortedlast(xs,xc),1,length(xs)-1)
    return (zs[i+1]-zs[i])/(xs[i+1]-xs[i])
end

"""Invert one piecewise-linear twisted skin, allowing temporary runout extrapolation."""
function rib_skin_xc(w,eta,target,upper)
    surface=upper ? upper_point : lower_point
    c=chord(w,eta);s,ct=sin(twist(w,eta)),cos(twist(w,eta))
    xc=(target-section_point(w,eta,0.0,0.0)[1])/(c*ct)
    for _ in 1:16
        point=surface(w,eta,xc);error=point[1]-target
        abs(error)<=2e-13*max(c,1.0)&&return xc
        left,right,t=airfoil_blend(w,eta)
        dz=(1-t)*airfoil_gradient(left,xc,upper)+t*airfoil_gradient(right,xc,upper)
        derivative=c*(ct+s*dz)
        derivative>1e-8*c||throw(ArgumentError("twisted airfoil cannot uniquely intersect stringer planes in the master-rib mesh"))
        xc-=error/derivative
    end
    lo,hi=min(-1.0,xc-1),max(2.0,xc+1)
    for _ in 1:48
        mid=(lo+hi)/2
        surface(w,eta,mid)[1]<target ? (lo=mid) : (hi=mid)
    end
    return (lo+hi)/2
end

function rib_curve_xc(w,context,index,state,eta,upper)
    count=length(context.roots)
    if index==1||index==count||state!=0
        return spar_surface_xc(w,context.arc.spar,eta,index==1||state<0 ? :front : :rear)
    end
    return rib_skin_xc(w,eta,context.roots[index]+stringer_offset(context.path,eta),upper)
end

function rib_intersection_cuts(w,context,end_eta)
    return sort!(unique(vcat(collect(range(0.0,end_eta;length=33)),filter(eta->0<=eta<=end_eta,
        vcat(planform_breakpoints(w),context.arc.spar.breakpoints,context.path.kink_etas,w.airfoil_etas)))))
end

function oriented_row(w,context,eta,previous,pitch,cuts)
    plane=main_rib_plane(w,context,eta);count=length(context.roots)
    clearance=pitch*get(context.params,"mesh.stringer_runout_ratio",1.0)
    states=copy(previous);lx=zeros(count);ux=zeros(count);le=zeros(count);ue=zeros(count)
    function intersect(index,state,upper)
        if index==count||state>0
            return eta,spar_surface_xc(w,context.arc.spar,eta,:rear)
        end
        xc(e)=rib_curve_xc(w,context,index,state,e,upper)
        surface=upper ? upper_point : lower_point
        curve(e)=surface(w,e,xc(e))
        found,_=rib_curve_intersection(curve,plane,cuts,"main-box row at rear-spar ETA $eta")
        return found,xc(found)
    end
    for upper in (false,true)
        table,spans=upper ? (ux,ue) : (lx,le)
        for index in (1,count)
            spans[index],table[index]=intersect(index,0,upper)
        end
    end
    for index in 2:count-1
        if states[index]==0
            df=Inf;dr=Inf;solved=true
            for upper in (false,true)
                table,spans=upper ? (ux,ue) : (lx,le)
                try
                    spans[index],table[index]=intersect(index,0,upper)
                    e=spans[index];x=context.roots[index]+stringer_offset(context.path,e)
                    fs,rs=spar_surface_xc(w,context.arc.spar,e,:front),spar_surface_xc(w,context.arc.spar,e,:rear)
                    surface=upper ? upper_point : lower_point
                    df=min(df,x-surface(w,e,fs)[1]);dr=min(dr,surface(w,e,rs)[1]-x)
                catch error
                    error isa ArgumentError||rethrow()
                    # Outside-box stringer curves can cease to intersect an
                    # otherwise valid row. Such lines terminate into the cap.
                    solved=false
                end
            end
            if !solved
                x=context.roots[index]+stringer_offset(context.path,eta)
                front=sum((lower_point(w,eta,spar_surface_xc(w,context.arc.spar,eta,:front))[1],upper_point(w,eta,spar_surface_xc(w,context.arc.spar,eta,:front))[1]))/2
                rear=(plane.lower[1]+plane.upper[1])/2
                df,dr=x-front,rear-x
                min(df,dr)>=clearance&&throw(ArgumentError("stringer $index cannot intersect master-rib row at rear ETA $eta; reduce the rib angle or adjust the stringer path"))
            end
            min(df,dr)<clearance-1e-10*max(w.chord_root,pitch)&&(states[index]=df<=dr ? -1 : 1)
        end
        if states[index]!=0
            source=states[index]<0 ? 1 : count
            lx[index]=lx[source];ux[index]=ux[source];le[index]=le[source];ue[index]=ue[source]
        end
    end
    return (;states,lx,ux,le,ue)
end

function oriented_stringer_grid(w,p,xcs,base_etas,base_ribs,nh,layout)
    roots=[section_point(w,0.0,xc,0.0)[1] for xc in xcs]
    context=merge(layout,(params=p,path=stringer_path(w,p),roots=roots,fuel_cache=Dict{Tuple{Int,Int},Float64}()))
    cuts=rib_intersection_cuts(w,context,Float64(p["box.end_eta"]))
    count=length(xcs);pitch=p["box.stringer_pitch"]
    etas=Float64[0.0]
    rows=[(states=zeros(Int,count),lx=copy(xcs),ux=copy(xcs),le=zeros(count),ue=zeros(count))]
    function advance(eta,depth=0)
        previous=last(rows).states;row=oriented_row(w,context,eta,previous,pitch,cuts)
        nf=Base.count(i->previous[i]==0&&row.states[i]==-1,2:length(xcs)-1)
        nr=Base.count(i->previous[i]==0&&row.states[i]==1,2:length(xcs)-1)
        if nf>1||nr>1
            depth<40||throw(ArgumentError("master-rib stringer runouts cannot be separated; adjust pitch or angle"))
            advance((last(etas)+eta)/2,depth+1);advance(eta,depth+1)
        else
            push!(etas,eta);push!(rows,row)
        end
    end
    for eta in base_etas[2:end];advance(eta);end
    ribs=[searchsortedfirst(etas,base_etas[j+1])-1 for j in base_ribs]
    g=BoxGrid(w,xcs,etas,nh,ribs,hcat([row.lx for row in rows]...),hcat([row.ux for row in rows]...),hcat([row.states for row in rows]...),
        collect(1:length(xcs)-2),hcat([row.le for row in rows]...),hcat([row.ue for row in rows]...),context)
    # Kinks cut different stringers at different row coordinates when ribs are
    # angled. Insert those vertices locally after shell construction instead of
    # propagating every crossing into a complete (often almost coincident) row.
    validate_rib_grid_order(g)
    return g
end

function refine_oriented_stringer_bays(g,subdivisions)
    w,context=g.wing,g.rib_layout;n=ni(g)*subdivisions;ns=length(g.etas)
    xcs=zeros(n+1);lower=zeros(n+1,ns);upper=similar(lower);le=similar(lower);ue=similar(lower);collapsed=zeros(Int,n+1,ns)
    cuts=rib_intersection_cuts(w,context,last(g.etas))
    for bay in 0:ni(g)-1,sub in 0:subdivisions-1
        dst=bay*subdivisions+sub+1;t=sub/subdivisions
        xcs[dst]=(1-t)*g.xcs[bay+1]+t*g.xcs[bay+2]
        for j in 1:ns
            if sub==0
                lower[dst,j]=g.lower_xcs[bay+1,j];upper[dst,j]=g.upper_xcs[bay+1,j]
                le[dst,j]=g.lower_etas[bay+1,j];ue[dst,j]=g.upper_etas[bay+1,j];collapsed[dst,j]=g.collapsed[bay+1,j];continue
            end
            ls=bay==0 ? -1 : g.collapsed[bay+1,j];rs=bay+1==ni(g) ? 1 : g.collapsed[bay+2,j]
            if ls==rs&&ls!=0
                src=ls<0 ? 1 : ni(g)+1;collapsed[dst,j]=ls
                lower[dst,j]=g.lower_xcs[src,j];upper[dst,j]=g.upper_xcs[src,j];le[dst,j]=g.lower_etas[src,j];ue[dst,j]=g.upper_etas[src,j];continue
            end
            plane=main_rib_plane(w,context,g.etas[j])
            for side in (false,true)
                xc(eta)=(1-t)*rib_curve_xc(w,context,bay+1,ls,eta,side)+t*rib_curve_xc(w,context,bay+2,rs,eta,side)
                surface=side ? upper_point : lower_point
                eta,_=rib_curve_intersection(e->surface(w,e,xc(e)),plane,cuts,"shell subdivision on master-rib row at rear ETA $(g.etas[j])")
                (side ? upper : lower)[dst,j]=xc(eta);(side ? ue : le)[dst,j]=eta
            end
        end
    end
    xcs[end]=g.xcs[end];lower[end,:]=g.lower_xcs[end,:];upper[end,:]=g.upper_xcs[end,:];le[end,:]=g.lower_etas[end,:];ue[end,:]=g.upper_etas[end,:];collapsed[end,:]=g.collapsed[end,:]
    refined=BoxGrid(w,xcs,g.etas,g.nh,g.ribs,lower,upper,collapsed,g.stringer_indices.*subdivisions,le,ue,context)
    validate_rib_grid_order(refined);return refined
end

function validate_rib_grid_order(g)
    tolerance=1e-11
    for j in 0:nj(g)
        plane=main_rib_plane(g.wing,g.rib_layout,g.etas[j+1])
        hinge=unit3(plane.upper.-plane.lower)
        forward=unit3(plane.direction.-sum(plane.direction.*hinge).*hinge)
        for i in 0:ni(g)-1,k in (0,g.nh)
            delta=grid_point(g,i+1,j,k).-grid_point(g,i,j,k)
            norm3(delta)<1e-11&&continue # canonical merged runout columns
            sum(forward.*delta)< -1e-11||throw(ArgumentError("master rib at rear ETA $(g.etas[j+1]) reverses chordwise or crosses a stringer; adjust its angle or the spar/stringer paths"))
        end
    end
    for side in (g.lower_etas,g.upper_etas),i in axes(side,1)
        all(diff(side[i,:]).>tolerance)||throw(ArgumentError("master ribs/skin rows cross or collapse; adjust master ETA, angle or pitch"))
    end
    for j in 0:nj(g)-1
        a,b=main_rib_plane(g.wing,g.rib_layout,g.etas[j+1]),main_rib_plane(g.wing,g.rib_layout,g.etas[j+2])
        for i in 0:ni(g),k in (0,g.nh)
            before,after=grid_point(g,i,j,k),grid_point(g,i,j+1,k)
            sum(a.normal.*(after.-a.origin))>1e-11&&sum(b.normal.*(before.-b.origin))< -1e-11||
                throw(ArgumentError("master rib planes cross inside the box between rear ETA $(g.etas[j+1]) and $(g.etas[j+2]); adjust their angles or spacing"))
        end
    end
end

function rib_reference_point(g,p,j,xc)
    plane=main_rib_plane(g,p,j);cuts=rib_intersection_cuts(g.wing,g.rib_layout,last(g.etas))
    _,point=rib_curve_intersection(eta->section_point(g.wing,eta,Float64(xc),0.0),plane,cuts,"RBE3 center on rib at rear ETA $(g.etas[j+1])")
    return point
end

function aero_attachment_oriented(g,reg,n_loop,aero_etas,xyz)
    # Shared-row x/z projections and rear-anchor blending are continuous even
    # when extrapolated rib planes cross outside the spars. The remaining
    # offset follows interpolated rotations (aero_rotation_levers). This
    # display-only attachment preserves rigid motions; off-plane strain is
    # an approximation and never participates in load/stiffness transfer.
    return aero_attachment_refined(g,reg,n_loop,aero_etas,xyz)
end

function validate_main_rib_mesh(m)
    g=m.grid;w=m.wing
    for group in m.groups
        group.kind in (:quad,:tria)&&component_base_pid(group.pid) in (PID_SKIN_UPPER,PID_SKIN_LOWER,PID_SPAR_WEB,PID_RIB_WEB)||continue
        for e in eachindex(group.eids)
            points=element_points(m,group,e);corners=length(points)==3 ? ((1,2,3),) : ((1,2,3),(2,3,4),(3,4,1),(4,1,2))
            normals=[cross3(points[b].-points[a],points[c].-points[a]) for (a,b,c) in corners]
            all(norm3(n)>1e-17*max(w.chord_root,1.0)^2 for n in normals)&&all(sum(first(normals).*n)>0 for n in normals)||
                throw(ArgumentError("master-rib shell EID $(group.eids[e]) is folded or collapsed; adjust master angles or mesh refinement"))
        end
    end
    all(diff([sp.eta for sp in m.rbe3]).>1e-10)||throw(ArgumentError("RBE3 centers cross between master ribs; move the reference chord location or reduce the rib angle"))
end

"""Exact surface curve at a coarse or shell-only stringer column."""
function kink_column_point(g,i,j,eta,upper)
    w,context=g.wing,g.rib_layout
    subdivisions=ni(g)÷(length(context.roots)-1)
    coarse,sub=divrem(i,subdivisions)
    if i==ni(g) || sub==0
        xc=rib_curve_xc(w,context,coarse+1,0,eta,upper)
    else
        # A shell-only line interpolates the two original physical boundaries,
        # exactly as refine_oriented_stringer_bays does on each rib plane.
        left=coarse*subdivisions+1;right=(coarse+1)*subdivisions+1
        ls=coarse==0 ? -1 : g.collapsed[left,j+1]
        rs=coarse+1==length(context.roots)-1 ? 1 : g.collapsed[right,j+1]
        t=sub/subdivisions
        xc=(1-t)*rib_curve_xc(w,context,coarse+1,ls,eta,upper)+t*rib_curve_xc(w,context,coarse+2,rs,eta,upper)
    end
    return (upper ? upper_point : lower_point)(w,eta,xc)
end

"""Constrained polygon triangulation maximizing the worst triangle quality.

Every inserted boundary vertex must remain on a shell edge. Choosing each ear
greedily can leave the last three vertices almost collinear on a spar/stringer
edge. An interval dynamic program selects all diagonals together, maximizing
the minimum projected area / sum(edge-length²). Admissible diagonals stay inside
the polygon and may not cross or skip a boundary vertex.
"""
function kink_polygon_triangles(reg,nodes)
    point(id)=Tuple(reg.xyz[3id-2:3id])
    origin=point(first(nodes));normal=(0.,0.,0.)
    for q in 2:length(nodes)-1
        normal=normal.+cross3(point(nodes[q]).-origin,point(nodes[q+1]).-origin)
    end
    normal=unit3(normal);triangles=Vector{Int}[];n=length(nodes)
    scale=maximum(norm3(point(id).-origin) for id in nodes)
    tolerance=1e-14*max(scale^2,1e-12)
    signed(a,b,c)=sum(normal.*cross3(point(b).-point(a),point(c).-point(a)))
    axis=unit3(point(nodes[2]).-origin);vertical=cross3(normal,axis)
    xy=[(sum(axis.*(point(id).-origin)),sum(vertical.*(point(id).-origin))) for id in nodes]
    orient(i,j,k)=signed(nodes[i],nodes[j],nodes[k])
    function inside(p)
        winding=false
        for i in 1:n
            a,b=xy[i],xy[mod1(i+1,n)]
            if (a[2]>p[2])!=(b[2]>p[2]) && p[1]<(b[1]-a[1])*(p[2]-a[2])/(b[2]-a[2])+a[1]
                winding=!winding
            end
        end
        return winding
    end
    allowed=falses(n,n)
    for i in 1:n,j in i+1:n
        if j==i+1 || i==1&&j==n
            allowed[i,j]=true;continue
        end
        any(k->k!=i&&k!=j&&abs(orient(i,j,k))<=tolerance&&
            sum((xy[k].-xy[i]).*(xy[k].-xy[j]))<=tolerance,1:n)&&continue
        any(k->begin
            l=mod1(k+1,n)
            k in (i,j)||l in (i,j) ? false :
                orient(i,j,k)*orient(i,j,l)<-tolerance^2 && orient(k,l,i)*orient(k,l,j)<-tolerance^2
        end,1:n)&&continue
        allowed[i,j]=inside((xy[i].+xy[j])./2)
    end
    quality=fill(-Inf,n,n);pivot=zeros(Int,n,n)
    for i in 1:n-1;quality[i,i+1]=Inf;end
    for gap in 2:n-1,i in 1:n-gap
        j=i+gap;allowed[i,j]||continue
        for k in i+1:j-1
            allowed[i,k]&&allowed[k,j]||continue
            area=orient(i,k,j);area>tolerance||continue
            denominator=sum(sum((point(nodes[v]).-point(nodes[u])).^2) for (u,v) in ((i,k),(k,j),(j,i)))
            score=min(area/denominator,quality[i,k],quality[k,j])
            if score>quality[i,j];quality[i,j]=score;pivot[i,j]=k;end
        end
    end
    isfinite(quality[1,n])&&quality[1,n]>0||throw(ArgumentError("cannot triangulate a shell at an angled-rib kink; check spar/rib intersections"))
    function collect_triangles(i,j)
        j<=i+1&&return
        k=pivot[i,j];push!(triangles,nodes[[i,k,j]])
        collect_triangles(i,k);collect_triangles(k,j)
    end
    collect_triangles(1,n)
    return triangles
end

"""Resolve physical kinks locally, sharing every inserted GRID with all neighbors.

Angled ribs intersect a constant-ETA kink at a different rear-row coordinate
for every stringer. A separate global row for each crossing multiplies mesh
density across the whole box. Instead enrich only affected longitudinal edges,
then triangulate their adjoining shells and split caps/stringers on those exact
same vertices. Rib planes and the regular row grid stay unchanged. Leading-edge
shells touching a split front cap use the same boundary vertices automatically.
"""
function split_oriented_kink_edges!(reg,g,groups,eid)
    context=g.rib_layout;w=g.wing
    breaks=sort!(unique(vcat(context.arc.spar.breakpoints,context.path.kink_etas,planform_breakpoints(w))))
    filter!(eta->1e-10<eta<last(g.etas)-1e-10,breaks)
    isempty(breaks)&&return eid
    splits=Dict{Tuple{Int,Int},Vector{Int}}()
    for i in 0:ni(g),j in 0:nj(g)-1,k in (i in (0,ni(g)) ? (0:g.nh) : (0:g.nh:g.nh))
        g.collapsed[i+1,j+1]==0&&g.collapsed[i+1,j+2]==0||continue
        a=node!(reg,g,i,j,k);b=node!(reg,g,i,j+1,k)
        ea=(reg.xyz[3a-1]-w.root_ref_y)/w.semispan;eb=(reg.xyz[3b-1]-w.root_ref_y)/w.semispan
        cuts=filter(eta->ea+1e-10<eta<eb-1e-10,breaks)
        isempty(cuts)&&continue
        chain=Int[a]
        for eta in cuts
            position=if k==0 || k==g.nh
                kink_column_point(g,i,j,eta,k==g.nh)
            else
                xc=spar_surface_xc(w,context.arc.spar,eta,i==0 ? :front : :rear)
                pl,pu=lower_point(w,eta,xc),upper_point(w,eta,xc)
                pl.+(k/g.nh).*(pu.-pl)
            end
            # Preserve the nearby real row index for metadata/frame consumers;
            # a negative height distinguishes local knots from structured GRIDs.
            key=(i,j,-length(reg.keys)-2)
            push!(reg.keys,key);append!(reg.xyz,position)
            push!(chain,length(reg.keys));reg.index[key]=last(chain)
        end
        push!(chain,b);splits[(a,b)]=chain;splits[(b,a)]=reverse(chain)
    end
    isempty(splits)&&return eid
    appended=ElemGroup[]
    for group in groups
        nn=group.kind==:bar ? 2 : group.kind==:tria ? 3 : 4
        oldids=copy(group.eids);oldconn=copy(group.conn);oldorient=copy(group.orient)
        empty!(group.eids);empty!(group.conn);empty!(group.orient)
        trias=group.kind==:tria ? group : ElemGroup(group.name*"_KINKS",:tria,group.pid)
        for e in eachindex(oldids)
            corners=oldconn[nn*(e-1)+1:nn*e]
            if group.kind==:bar
                chain=get(splits,(corners[1],corners[2]),corners)
                for q in 1:length(chain)-1
                    push!(group.eids,q==1 ? oldids[e] : eid);q>1&&(eid+=1)
                    append!(group.conn,chain[q:q+1]);append!(group.orient,oldorient[3*e-2:3*e])
                end
            else
                boundary=Int[]
                for q in 1:nn
                    chain=get(splits,(corners[q],corners[mod1(q+1,nn)]),[corners[q],corners[mod1(q+1,nn)]])
                    append!(boundary,chain[1:end-1])
                end
                if length(boundary)==nn
                    push!(group.eids,oldids[e]);append!(group.conn,corners)
                else
                    for (q,triangle) in enumerate(kink_polygon_triangles(reg,boundary))
                        push!(trias.eids,q==1 ? oldids[e] : eid);q>1&&(eid+=1)
                        append!(trias.conn,triangle)
                    end
                end
            end
        end
        group.kind!=:tria&&!isempty(trias.eids)&&push!(appended,trias)
    end
    append!(groups,appended)
    return eid
end
