# Analytic fixed-mesh shell tangents. Capture the production kernel calls,
# differentiate their arithmetic with one forward-mode direction, and retain
# the same drilling, warp, SNORM and GRID-coordinate congruences.
mutable struct AnalyticShellCapture
    model::Any
    contexts::Dict{Int,Any}
    calls::Dict{Int,Vector{Any}}
    lock::ReentrantLock
end
AnalyticShellCapture(model) = AnalyticShellCapture(model, Dict{Int,Any}(), Dict{Int,Vector{Any}}(), ReentrantLock())

@inline _analytic_shell_call(::Nothing, eid, f, args...; kwargs...) = f(args...; kwargs...)
function _analytic_shell_call(c::AnalyticShellCapture, eid, f, args...; kwargs...)
    # Scratch workspaces are intentionally not retained: Dual kernels allocate
    # matching scalar workspaces; all geometric/branch inputs are copied.
    kw = (; (k => deepcopy(v) for (k,v) in kwargs if k ∉ (:ws,:msws))...)
    call = (f=f, args=deepcopy(args), kwargs=kw)
    lock(c.lock) do
        push!(get!(c.calls, eid, Any[]), call)
    end
    f(args...; kwargs...)
end

@inline _analytic_shell_finish!(::Nothing, args...; kwargs...) = nothing
function _analytic_shell_finish!(c::AnalyticShellCapture, eid, pid, dofs, transform, ke;
        blend=0.0, macneal_blend=0.0, drill=ones(size(ke,1)), raw_shear=false,
        cm_scale=ones(3,3), cb_scale=1.0, cs_scale=1.0, unsupported="")
    calls = lock(c.lock) do
        c.calls[eid]
    end
    weights = length(calls) - (macneal_blend>0 ? 1 : 0) == 2 ? [1-blend,blend] : [1.0]
    if macneal_blend>0
        weights .*= 1-macneal_blend
        push!(weights,macneal_blend)
    end
    length(weights)==length(calls) || error("Analytic shell $eid: unexpected production kernel blend")
    T = Diagonal(drill)*transform
    ctx = (eid=eid,pid=pid,model=c.model,calls=calls,weights=weights,dofs=copy(dofs),
        transform=Matrix(T),Ke=copy(ke),raw_shear=raw_shear,cm_scale=copy(cm_scale),
        cb_scale=cb_scale,cs_scale=cs_scale,unsupported=unsupported)
    lock(c.lock) do
        haskey(c.contexts,eid) && error("Analytic shell derivatives require unique CQUAD4/CTRIA3 element IDs (EID $eid)")
        c.contexts[eid]=ctx
    end
    nothing
end

_asget(x,k,default) = x isa AbstractDict ? get(x,k,get(x,String(k),default)) : get(x,k,default)
function _as_material(model, mid, direction, x)
    m=model["MATs"][string(mid)]
    (haskey(m,"E1") || haskey(m,"G11")) && throw(ArgumentError("Analytic shell derivatives currently require isotropic MAT1 plies/materials"))
    dirs=_asget(direction,:materials,Dict())
    d=get(dirs,mid,get(dirs,string(mid),NamedTuple()))
    E=m["E"]+x*_asget(d,:E,0.0); nu=m["NU"]+x*_asget(d,:nu,0.0)
    rho=get(m,"RHO",0.0)+x*_asget(d,:rho,0.0)
    G0=get(m,"G",m["E"]/(2*(1+m["NU"])))
    isapprox(G0,m["E"]/(2*(1+m["NU"]));rtol=1e-9,atol=0) ||
        throw(ArgumentError("Analytic MAT1 derivatives require G=E/(2(1+nu)); independently specified shear modulus is unsupported"))
    (E=E,nu=nu,rho=rho,G=E/(2*(1+nu)))
end

"""Exact constitutive chain for fixed-mesh PSHELL or centered isotropic PCOMP.
`direction` contains `thickness`, `ply_thicknesses`, and `materials[mid]=(E,nu,rho)`.
The scalar x is a differentiation seed, never a finite perturbation.
"""
function analytic_shell_constitutive(model,pid,direction=NamedTuple(),x=0.0)
    prop=model["PSHELLs"][string(pid)]
    native=parentmodule(@__MODULE__)
    Q(E,nu,G)=getfield(native,:laminate_plane_stress_qbar)(E,E,nu,G,0.0)
    br=get(prop,"BEND_RATIO",1.0)
    if get(prop,"TYPE","")!="PCOMP_CLT"
        mid=prop["MID"]
        all(get(prop,k,mid) in (0,mid) for k in ("MID2","MID3")) ||
            throw(ArgumentError("Analytic PSHELL derivatives require common membrane/bending/shear material"))
        get(prop,"MID4",0)==0 || throw(ArgumentError("Analytic PSHELL MID4 is unsupported"))
        mat=_as_material(model,mid,direction,x)
        h=prop["T"]+x*_asget(direction,:thickness,0.0)
        q=Q(mat.E,mat.nu,mat.G)
        tst=get(prop,"TS_T",get(prop,"TST",5/6))
        Cs=(br>1e-12 ? tst*mat.G*h : zero(h))*Matrix{typeof(h)}(I,2,2)
        return (Cm=h*q,Cb=br*h^3/12*q,Cs=Cs,Cs_raw=Cs,Bmb=zeros(typeof(h),3,3),
            h=h,Eref=mat.E,Gref=mat.G,E=mat.E,nu=mat.nu,plies=Any[],
            mass_moments=(mat.rho*h,zero(h),mat.rho*h^3/12))
    end
    pd=prop["PLY_DATA"]
    Bool(get(prop,"IS_ISOTROPIC",false)) || throw(ArgumentError("Analytic sandwich derivatives require isotropic plies"))
    h0=sum(p["z_top"]-p["z_bot"] for p in pd)
    isapprox(pd[1]["z_bot"],-h0/2;rtol=1e-9,atol=1e-12) ||
        throw(ArgumentError("Analytic sandwich derivatives require a centered laminate reference plane"))
    dt=_asget(direction,:ply_thicknesses,zeros(length(pd)))
    length(dt)==length(pd) || throw(ArgumentError("Expected one ply-thickness direction per PCOMP ply"))
    total_direction=_asget(direction,:thickness,0.0)
    (iszero(total_direction) || isapprox(total_direction,sum(dt);rtol=1e-12,atol=1e-14)) ||
        throw(ArgumentError("PCOMP total-thickness direction must equal the sum of its ply-thickness directions"))
    ts=[p["z_top"]-p["z_bot"]+x*dt[i] for (i,p) in enumerate(pd)]
    h=sum(ts); T=typeof(h); A=zeros(T,3,3); B=copy(A); D=copy(A); Ash=zeros(T,2,2)
    m0=zero(h);m1=zero(h);m2=zero(h); z=-h/2; plies=Any[]; Es=Any[]
    for (i,p) in enumerate(pd)
        mid=parse(Int,string(p["mid"]));mat=_as_material(model,mid,direction,x);push!(Es,mat.E)
        q=Q(mat.E,mat.nu,mat.G);qs=mat.G*Matrix{T}(I,2,2);zt=z+ts[i]
        A .+= q*(zt-z);B .+= q*((zt^2-z^2)/2);D .+= q*((zt^3-z^3)/3);Ash .+= qs*(zt-z)
        m0+=mat.rho*(zt-z);m1+=mat.rho*(zt^2-z^2)/2;m2+=mat.rho*(zt^3-z^3)/3
        push!(plies,Dict("Qbar"=>q,"Qshear"=>qs,"z_bot"=>z,"z_top"=>zt,"mid"=>mid,"theta"=>p["theta"]))
        z=zt
    end
    # Current WingFEGen sandwich variables preserve material/thickness symmetry.
    maximum(abs,ForwardDiff.value.(B)) <= 1e-9*maximum(abs,ForwardDiff.value.(A)) ||
        throw(ArgumentError("Analytic shell support currently requires symmetric sandwich laminates"))
    if x isa ForwardDiff.Dual
        maximum(abs,first.(ForwardDiff.partials.(B))) <= 1e-9*max(maximum(abs,first.(ForwardDiff.partials.(A))),1.0) ||
            throw(ArgumentError("This ply direction breaks sandwich symmetry; no silent coupling approximation is permitted"))
    end
    kappas=Bool(get(prop,"PCOMP_WHITNEY_SHEAR",false)) ? getfield(native,:pcomp_whitney_kappa)(plies,h) : (5/6,5/6)
    Cs=getfield(native,:_laminate_corrected_shear)(Ash,kappas...)
    nu=clamp(A[1,2]/A[1,1],0.0,0.49);E=A[1,1]*(1-nu^2)/h
    (Cm=A,Cb=D,Cs=Cs,Cs_raw=Ash,Bmb=B,h=h,Eref=maximum(Es),Gref=(Ash[1,1]+Ash[2,2])/(2h),
        E=E,nu=nu,plies=plies,mass_moments=(m0,m1,m2))
end

function _analytic_shell_replay(ctx,state)
    isempty(ctx.unsupported) || throw(ArgumentError("Analytic shell $(ctx.eid): $(ctx.unsupported)"))
    result=nothing
    for (call,weight) in zip(ctx.calls,ctx.weights)
        args=call.args; length(args)==6 || throw(ArgumentError("Unsupported shell kernel argument layout"))
        cm=state.Cm.*ctx.cm_scale;cb=state.Cb*ctx.cb_scale
        cs=(ctx.raw_shear ? state.Cs_raw : state.Cs)*ctx.cs_scale
        # Baseline parity catches material-axis and branch mismatches before AD.
        Eref=size(args[1],1)==4 ? state.Eref : state.Gref
        if state.Eref isa ForwardDiff.Dual && !isempty(state.plies) && size(args[1],1)==4 &&
           get(call.kwargs,:k6rot,0.0)!=0 && get(call.kwargs,:drill_scale,1.0)!=0
            # max(E_ply) is the production drilling reference. At a material
            # tie, unequal directional slopes have no unique derivative.
            values=[_as_material(ctx.model,p["mid"],NamedTuple(),0.0).E for p in state.plies]
            maxvalue=maximum(values)
            slopes=Float64[]
            for (p,E0) in zip(state.plies,values)
                abs(E0-maxvalue)<=1e-12max(abs(maxvalue),1.0) || continue
                # Q11*(1-nu^2) recovers each isotropic ply's E without
                # retaining a second parameter dictionary in the context.
                q=p["Qbar"];nu=q[1,2]/q[1,1];E=q[1,1]*(1-nu^2)
                push!(slopes,ForwardDiff.partials(E)[1])
            end
            maximum(slopes)-minimum(slopes)<=1e-10max(maximum(abs,slopes),1.0) ||
                throw(ArgumentError("Analytic shell $(ctx.eid): tied ply moduli give a nondifferentiable drilling reference"))
        end
        kw=haskey(call.kwargs,:Bmb) ? merge(call.kwargs,(Bmb=call.kwargs.Bmb===nothing ? nothing : state.Bmb,)) : call.kwargs
        ke=call.f(args[1],cm,cb,cs,state.h,Eref;kw...)
        result=result===nothing ? weight*ke : result+weight*ke
    end
    ctx.transform'*result*ctx.transform
end

function analytic_shell_tangent(ctx,direction)
    baseline=analytic_shell_constitutive(ctx.model,ctx.pid)
    replay=_analytic_shell_replay(ctx,baseline)
    mismatch=norm(replay-ctx.Ke)/max(norm(ctx.Ke),eps())
    mismatch<=2e-10 || throw(ArgumentError("Analytic shell $(ctx.eid) production replay differs by $mismatch; unsupported constitutive/branch configuration"))
    x=ForwardDiff.Dual(0.0,1.0)
    state=analytic_shell_constitutive(ctx.model,ctx.pid,direction,x)
    kd=_analytic_shell_replay(ctx,state)
    derivative=map(v->ForwardDiff.partials(v)[1],kd)
    (dKe=derivative,Ke=ctx.Ke,dofs=ctx.dofs,pid=ctx.pid,eid=ctx.eid,
        mass_moments=baseline.mass_moments,dmass_moments=map(v->ForwardDiff.partials(v)[1],state.mass_moments),
        constitutive=state,replay_error=mismatch)
end

function analytic_shell_contexts(model;kwargs...)
    capture=AnalyticShellCapture(model)
    assembly=assemble_stiffness(model;shell_capture=capture,kwargs...)
    (capture=capture,contexts=capture.contexts,assembly=assembly)
end

"""Recover exact native shell stress features and their explicit property tangent
at a fixed physical displacement. The op geometry/frames are those returned by
the same production assembly; RBE/MPC expansion is the caller's responsibility.
Returns stresses in the native element recovery frame, before viewer rotation.
"""
function analytic_shell_stress_tangent(ctx,direction,u,id_map,X,node_R,snorm_normals;surface="z2")
    el=ctx.model["CSHELLs"][string(ctx.eid)]; nodes=el["NODES"];indices=[id_map[n] for n in nodes]
    points=[SVector{3}(X[i,:]) for i in indices]; n=length(nodes)
    if n==4
        frame=shell_element_frame_quad4(points...,q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC"))
    elseif n==3
        frame=shell_element_frame_fast(points[1],points[2],points[3],SVector(0.0,0.0,0.0),3)
    else
        throw(ArgumentError("Analytic stress recovery supports CQUAD4 and CTRIA3"))
    end
    v1,v2,v3=apply_snorm_to_frame(frame...,indices,snorm_normals)
    center=sum(points)/n;lc=[dot(p-center,v) for p in points,v in (v1,v2)]
    R=transpose(hcat(v1,v2,v3));ue=zeros(6n)
    for (k,i) in enumerate(indices), offset in (0,3)
        ue[(6k-5+offset):(6k-3+offset)] = R*node_R[i]*u[(6i-5+offset):(6i-3+offset)]
    end
    snpq=n==4 ? snorm_element_pq(v1,v2,v3,indices,snorm_normals) : nothing
    coords3d=n==4 ? reduce(vcat,transpose.(points)) : nothing
    prop=ctx.model["PSHELLs"][string(ctx.pid)];isclt=get(prop,"TYPE","")=="PCOMP_CLT"
    br=get(prop,"BEND_RATIO",1.0)
    function features(x)
        state=analytic_shell_constitutive(ctx.model,ctx.pid,direction,x)
        recovered=if n==4
            FEM.stress_strain_quad4(lc,ue,state.E,state.nu,state.h,state.h;
                bend_ratio=br,Cm_override=isclt ? state.Cm : nothing,
                Cb_override=isclt ? state.Cb : nothing,
                snorm_pq=snpq,coords_3d=coords3d,recover_corners=false,
                membrane_incomp_center_jacobian=q4_sol105_membrane_incomp_center_jacobian_enabled())
        else
            FEM.stress_strain_tria3(lc,ue,state.E,state.nu,state.h;
                bend_ratio=br,Cm_override=isclt ? state.Cm : nothing)
        end
        which=surface=="z1" ? 1 : surface=="z2" ? 2 : throw(ArgumentError("Expected surface z1 or z2"))
        if !isclt
            return collect(recovered[3+which])
        end
        # Native PCOMP z1/z2 are the outer ply MIDPOINT stresses.
        epsmem=(recovered[6]+recovered[7])/2; kap=(recovered[7]-recovered[6])/state.h
        ply=state.plies[which==1 ? 1 : end]
        ply["Qbar"]*(epsmem+(ply["z_bot"]+ply["z_top"])/2*kap)
    end
    baseline=features(0.0); differentiated=features(ForwardDiff.Dual(0.0,1.0))
    (features=baseline,dfeatures=map(v->ForwardDiff.partials(v)[1],differentiated))
end
