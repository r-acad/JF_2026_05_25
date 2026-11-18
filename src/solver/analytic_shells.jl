# Analytic fixed-mesh shell tangents. Capture the production kernel calls,
# differentiate their arithmetic with one forward-mode direction, and retain
# the same drilling, warp, SNORM and GRID-coordinate congruences.
mutable struct AnalyticShellCapture
    model::Any
    contexts::Dict{Int,Any}
    calls::Dict{Int,Vector{Any}}
    lock::ReentrantLock
end
function AnalyticShellCapture(model)
    assert_no_corner_thickness_analytic(model)
    return AnalyticShellCapture(model, Dict{Int,Any}(), Dict{Int,Vector{Any}}(), ReentrantLock())
end

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
        cm_scale=ones(3,3), cb_scale=1.0, cs_scale=1.0, bmb_scale=1.0,
        membrane_rotation=0.0, bending_rotation=0.0, unsupported="")
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
    ctx = (eid=eid,pid=pid,model=c.model,capture_model=c.model,calls=calls,weights=weights,dofs=copy(dofs),
        transform=Matrix(T),Ke=copy(ke),raw_shear=raw_shear,cm_scale=copy(cm_scale),
        cb_scale=cb_scale,cs_scale=cs_scale,bmb_scale=bmb_scale,
        membrane_rotation=membrane_rotation,bending_rotation=bending_rotation,unsupported=unsupported)
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

"""Physical ply law for exact thickness/material jets, including MAT8."""
function _as_ply_material(model,mid,direction,x)
    m=model["MATs"][string(mid)];dirs=_asget(direction,:materials,Dict())
    d=get(dirs,mid,get(dirs,string(mid),NamedTuple()))
    if !haskey(m,"E1")
        p=_as_material(model,mid,direction,x)
        return (E1=p.E,E2=p.E,nu12=p.nu,G12=p.G,G13=p.G,G23=p.G,rho=p.rho)
    end
    v(k)=get(m,k,0.)+x*_asget(d,Symbol(k),0.)
    g=v("G12");g13=get(m,"G1Z",0.)<=0 ? g : v("G1Z")
    g23=get(m,"G2Z",0.)<=0 ? g : v("G2Z")
    (E1=v("E1"),E2=v("E2"),nu12=v("NU12"),G12=g,G13=g13,G23=g23,rho=v("RHO"))
end

function _as_rotate_law(C,angle)
    c=cos(angle);s=sin(angle);T=[c*c s*s c*s;s*s c*c -c*s;-2c*s 2c*s c*c-s*s]
    transpose(T)*C*T
end
function _as_rotate_shear(C,angle)
    c=cos(angle);s=sin(angle);R=[c s;-s c]
    transpose(R)*C*R
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
    isempty(pd)&&throw(ArgumentError("Analytic PCOMP derivatives require a complete physical ply stack"))
    h0=sum(p["z_top"]-p["z_bot"] for p in pd)
    dt=_asget(direction,:ply_thicknesses,zeros(length(pd)))
    length(dt)==length(pd) || throw(ArgumentError("Expected one ply-thickness direction per PCOMP ply"))
    total_direction=_asget(direction,:thickness,0.0)
    (iszero(total_direction) || isapprox(total_direction,sum(dt);rtol=1e-12,atol=1e-14)) ||
        throw(ArgumentError("PCOMP total-thickness direction must equal the sum of its ply-thickness directions"))
    ts=[p["z_top"]-p["z_bot"]+x*dt[i] for (i,p) in enumerate(pd)]
    h=sum(ts); T=typeof(h); A=zeros(T,3,3); B=copy(A); D=copy(A); Ash=zeros(T,2,2)
    # Explicit Z0 is fixed unless its owning generator supplies a reference-
    # plane direction (combined attached flanges can move that plane).
    z0direction=_asget(direction,:z0,get(prop,"PCOMP_Z0_DEFAULT",false) ? -sum(dt)/2 : 0.)
    m0=zero(h);m1=zero(h);m2=zero(h); z=pd[1]["z_bot"]+x*z0direction; plies=Any[]; Es=Any[]
    for (i,p) in enumerate(pd)
        mid=parse(Int,string(p["mid"]));mat=_as_ply_material(model,mid,direction,x);push!(Es,max(mat.E1,mat.E2))
        theta=deg2rad(p["theta"])+x*deg2rad(_asget(direction,:ply_angles,zeros(length(pd)))[i])
        q=getfield(native,:laminate_plane_stress_qbar)(mat.E1,mat.E2,mat.nu12,mat.G12,theta)
        qs=getfield(native,:laminate_transverse_shear_qbar)(mat.G13,mat.G23,theta);zt=z+ts[i]
        A .+= q*(zt-z);B .+= q*((zt^2-z^2)/2);D .+= q*((zt^3-z^3)/3);Ash .+= qs*(zt-z)
        m0+=mat.rho*(zt-z);m1+=mat.rho*(zt^2-z^2)/2;m2+=mat.rho*(zt^3-z^3)/3
        push!(plies,Dict("Qbar"=>q,"Qshear"=>qs,"z_bot"=>z,"z_top"=>zt,"mid"=>mid,"theta"=>p["theta"],"Eref"=>max(mat.E1,mat.E2)))
        z=zt
    end
    Cs=Bool(get(prop,"PCOMP_WHITNEY_SHEAR",false)) ?
        getfield(native,:pcomp_shear_for_convention)(plies,h,get(prop,"PCOMP_SHEAR_CONVENTION","material_frame")) : (5/6)*Ash
    nu=clamp(A[1,2]/A[1,1],0.0,0.49);E=A[1,1]*(1-nu^2)/h
    (Cm=A,Cb=D,Cs=Cs,Cs_raw=Ash,Bmb=B,h=h,Eref=maximum(Es),Gref=(Ash[1,1]+Ash[2,2])/(2h),
        E=E,nu=nu,plies=plies,mass_moments=(m0,m1,m2))
end

function _analytic_shell_replay(ctx,state)
    isempty(ctx.unsupported) || throw(ArgumentError("Analytic shell $(ctx.eid): $(ctx.unsupported)"))
    result=nothing
    for (call,weight) in zip(ctx.calls,ctx.weights)
        args=call.args; length(args)==6 || throw(ArgumentError("Unsupported shell kernel argument layout"))
        cm=_as_rotate_law(state.Cm,ctx.membrane_rotation).*ctx.cm_scale
        cb=_as_rotate_law(state.Cb,ctx.bending_rotation)*ctx.cb_scale
        bmb=_as_rotate_law(state.Bmb,ctx.membrane_rotation)*ctx.bmb_scale
        cs=_as_rotate_shear(ctx.raw_shear ? state.Cs_raw : state.Cs,ctx.bending_rotation)*ctx.cs_scale
        # Baseline parity catches material-axis and branch mismatches before AD.
        Eref=size(args[1],1)==4 ? state.Eref : state.Gref
        if state.Eref isa ForwardDiff.Dual && !isempty(state.plies) && size(args[1],1)==4 &&
           get(call.kwargs,:k6rot,0.0)!=0 && get(call.kwargs,:drill_scale,1.0)!=0
            # max(E_ply) is the production drilling reference. At a material
            # tie, unequal directional slopes have no unique derivative.
                values=[begin m=_as_ply_material(ctx.model,p["mid"],NamedTuple(),0.0);max(m.E1,m.E2) end for p in state.plies]
            maxvalue=maximum(values)
            slopes=Float64[]
            for (p,E0) in zip(state.plies,values)
                abs(E0-maxvalue)<=1e-12max(abs(maxvalue),1.0) || continue
                # Q11*(1-nu^2) recovers each isotropic ply's E without
                # retaining a second parameter dictionary in the context.
                E=p["Eref"]
                push!(slopes,ForwardDiff.partials(E)[1])
            end
            maximum(slopes)-minimum(slopes)<=1e-10max(maximum(abs,slopes),1.0) ||
                throw(ArgumentError("Analytic shell $(ctx.eid): tied ply moduli give a nondifferentiable drilling reference"))
        end
        # Preserve the production branch. A baseline zero B with a nonzero
        # directional coupling cannot be discarded by a `nothing` shortcut.
        coupling=maximum(abs,ForwardDiff.value.(bmb))>1e-10maximum(abs,ForwardDiff.value.(cm)) ||
            (eltype(bmb)<:ForwardDiff.Dual && any(v->any(!iszero,ForwardDiff.partials(v)),bmb))
        kw=haskey(call.kwargs,:Bmb) ? merge(call.kwargs,(Bmb=coupling ? bmb : nothing,)) : call.kwargs
        ke=call.f(args[1],cm,cb,cs,state.h,Eref;kw...)
        result=result===nothing ? weight*ke : result+weight*ke
    end
    ctx.transform'*result*ctx.transform
end

"""Complete primitive recovery jet for RF demands, at fixed physical state.

Uses the production shell kinematics and actual section A/B/D/shear laws.
Callers must retain the same native/view rotation and replay every requested
primitive against ordinary native recovery before using its derivative.
"""
function analytic_shell_recovery_tangent(ctx,direction,u,id_map,X,node_R,snorm_normals)
    get(ctx,:capture_model,ctx.model)===ctx.model||throw(ArgumentError("Analytic shell recovery requires a context captured from the actual model; recapture after changing material data"))
    el=ctx.model["CSHELLs"][string(ctx.eid)];prop=ctx.model["PSHELLs"][string(ctx.pid)]
    nodes=el["NODES"];indices=[id_map[n] for n in nodes];points=[SVector{3}(X[i,:]) for i in indices];n=length(nodes)
    frame=n==4 ? shell_element_frame_quad4(points...,q4_frame_mode_from_env("JFEM_Q4_FRAME_MODE_STATIC")) :
        shell_element_frame_fast(points[1],points[2],points[3],SVector(0.,0.,0.),3)
    v1,v2,v3=apply_snorm_to_frame(frame...,indices,snorm_normals);center=sum(points)/n
    lc=[dot(p-center,v) for p in points,v in (v1,v2)];R=transpose(hcat(v1,v2,v3));ue=zeros(6n)
    for (k,i) in enumerate(indices),offset in (0,3)
        ue[(6k-5+offset):(6k-3+offset)]=R*node_R[i]*u[(6i-5+offset):(6i-3+offset)]
    end
    snpq=n==4 ? snorm_element_pq(v1,v2,v3,indices,snorm_normals) : nothing
    if n==4&&snpq!==nothing&&!snorm_quad4_field_is_active(snpq,Tuple(points),v1,v3);snpq=nothing;end
    coords3d=n==4 ? reduce(vcat,transpose.(points)) : nothing
    if n==3
        tri=tria3_snorm_element_pq(v1,v2,v3,indices,snorm_normals)
        tri===nothing||(ue=tria3_snorm_normal_moment_displacement_map(lc,tri)*ue)
    end
    isclt=get(prop,"TYPE","")=="PCOMP_CLT";br=get(prop,"BEND_RATIO",1.)
    compatible=n==4&&isclt&&q4_pcomp_compatible_recovery_enabled(ctx.model,prop,lc,coords3d,snpq)
    planar=n==4&&isclt&&coupled_pcomp_projected_enabled(lc,get(prop,"Bmb",nothing);
        require_coupling=false,is_pcomp=true,isotropic=get(prop,"IS_ISOTROPIC",false),coords_3d=coords3d,
        snorm_pq=snpq,curvature_membrane=nothing,kernel_mode=get(ENV,"JFEM_Q4_KERNEL_STATIC",get(ENV,"JFEM_Q4_KERNEL","macneal")),
        sol_type=get(ctx.model,"SOL",101),rigid_shear=get(prop,"TRANSVERSE_SHEAR_RIGID_LIMIT",false),
        legacy_nonlinear=coupled_pcomp_legacy_nonlinear_enabled(ctx.model))
    coupling=isclt&&get(prop,"Bmb",nothing)!==nothing&&any(!iszero,prop["Bmb"])
    projected=planar&&coupling
    rectangle=planar&&n==4&&FEM.quad4_is_axis_aligned_rectangle(lc)&&FEM.quad4_finite_warp_displacement_map(lc,coords3d)===nothing
    mean_recovery=isclt&&!rectangle&&(snpq===nothing||maximum(abs,snpq)<=1e-12)&&
        lowercase(get(ENV,"JFEM_Q4_KERNEL_STATIC",get(ENV,"JFEM_Q4_KERNEL","macneal")))=="macneal"
    condensed=n==4&&isclt&&!planar&&!compatible&&mean_recovery&&solver_env_bool("JFEM_Q4_COUPLED_CONDENSED_RECOVERY",true)
    function packet(x)
        state=analytic_shell_constitutive(ctx.model,ctx.pid,direction,x)
        A=_as_rotate_law(state.Cm,ctx.membrane_rotation)
        D=_as_rotate_law(state.Cb,ctx.bending_rotation)
        B=_as_rotate_law(state.Bmb,ctx.membrane_rotation)
        Cs=_as_rotate_shear(state.Cs,ctx.bending_rotation)
        # A symmetric baseline can acquire membrane/bending coupling when
        # only part of its physical stack changes thickness. Match the
        # elastic tangent's directional guard: do not discard a nonzero dB
        # merely because the baseline ModelBuilder stored B as `nothing`.
        packet_coupling=coupling || (eltype(B)<:ForwardDiff.Dual &&
            any(v->any(!iszero,ForwardDiff.partials(v)),B))
        physical=ue.+zero(x)
        zoffs=get(el,"ZOFFS",0.)+x*_asget(direction,:zoffs,0.)
        if n==4&&!iszero(get(el,"ZOFFS",0.))&&shell_projected_reference_offset_enabled(ctx.model)&&
                (snpq===nothing||FEM.quad4_snorm_normal_moment_mode())
            physical=shell_projected_reference_offset_map(lc,coords3d,zoffs;snorm_pq=snpq)*physical
        else
            # Generic arithmetic permits a thickness-driven reference offset.
            for k=1:n
                physical[6k-5]+=zoffs*physical[6k-1]
                physical[6k-4]-=zoffs*physical[6k-2]
            end
        end
        recovered=if n==4
            FEM.stress_strain_quad4(lc,physical,state.E,state.nu,state.h,state.h;bend_ratio=br,
                Cm_override=isclt ? A : nothing,Cb_override=isclt ? D : nothing,
                Cs_override=isclt ? Cs : nothing,Bmb_override=packet_coupling ? B : nothing,
                coupled_projected=projected,coupled_condensed=condensed,compatible_center=compatible,
                recovery_bending_incomp=solver_env_bool("JFEM_Q4_STATIC_BENDING_INCOMP",true),
                recovery_membrane_incomp=get(ctx.model,"SOL",101)==105 ? sol105_static_membrane_incomp_enabled() : solver_env_bool("JFEM_Q4_STATIC_MEMBRANE_INCOMP",true),
                recovery_kernel_mode=get(ENV,"JFEM_Q4_KERNEL_STATIC",get(ENV,"JFEM_Q4_KERNEL","macneal")),
                recover_shear=false,recover_corners=false,snorm_pq=snpq,coords_3d=coords3d,
                membrane_shear_center_row=compatible,
                membrane_incomp_center_jacobian=q4_sol105_membrane_incomp_center_jacobian_enabled())
        else
            FEM.stress_strain_tria3(lc,physical,state.E,state.nu,state.h;bend_ratio=br,Cm_override=isclt ? A : nothing,Bmb=packet_coupling ? B : nothing)
        end
        N,M,Q,s1,s2,e1,e2=recovered
        eps=(e1+e2)/2;kap=(e2-e1)/state.h
        if isclt&&!projected&&!condensed
            N=A*eps;M=-D*kap
            if n==3&&packet_coupling;N+=B*kap;M-=transpose(B)*eps;end
        end
        strain=Dict{String,Any}("z1"=>Dict("normal_x"=>eps[1],"normal_y"=>eps[2],"shear_xy"=>eps[3]),
            "z2"=>Dict("normal_x"=>-kap[1],"normal_y"=>-kap[2],"shear_xy"=>-kap[3]))
        if isclt
            cm=cos(ctx.membrane_rotation);sm=sin(ctx.membrane_rotation)
            cb=cos(ctx.bending_rotation);sb=sin(ctx.bending_rotation)
            Tm=[cm^2 sm^2 cm*sm;sm^2 cm^2 -cm*sm;-2cm*sm 2cm*sm cm^2-sm^2]
            Tb=[cb^2 sb^2 cb*sb;sb^2 cb^2 -cb*sb;-2cb*sb 2cb*sb cb^2-sb^2]
            faces=Any[]
            for (i,ply) in enumerate(state.plies)
                angle=deg2rad(ply["theta"]);c=cos(angle);s=sin(angle)
                Tp=[c*c s*s c*s;s*s c*c -c*s;-2c*s 2c*s c*c-s*s]
                row=Dict{String,Any}()
                for (face,z) in (("bottom",ply["z_bot"]),("top",ply["z_top"]))
                    values=Tp*(Tm*eps+z*(Tb*kap))
                    row[face]=Dict("e1"=>values[1],"e2"=>values[2],"g12"=>values[3])
                end
                push!(faces,row)
                sigma=transpose(Tm)*(ply["Qbar"]*(Tm*eps))+
                    (ply["z_bot"]+ply["z_top"])/2*(transpose(Tb)*(ply["Qbar"]*(Tb*kap)))
                i==1&&(s1=sigma);i==length(state.plies)&&(s2=sigma)
            end
            strain["ply_faces"]=faces
        end
        stress=Dict{String,Any}("z1"=>Dict("normal_x"=>s1[1],"normal_y"=>s1[2],"shear_xy"=>s1[3]),
            "z2"=>Dict("normal_x"=>s2[1],"normal_y"=>s2[2],"shear_xy"=>s2[3]))
        force=Dict("fx"=>N[1],"fy"=>N[2],"fxy"=>N[3],"mx"=>M[1],"my"=>M[2],"mxy"=>M[3],"qx"=>Q[1],"qy"=>Q[2])
        Dict{String,Any}("stress"=>stress,"strain"=>strain,"forces"=>force)
    end
    baseline=packet(0.);dual=packet(ForwardDiff.Dual(0.,1.))
    derivative(x::AbstractDict)=Dict(k=>derivative(v) for (k,v) in x)
    derivative(x::AbstractVector)=map(derivative,x)
    derivative(x::ForwardDiff.Dual)=ForwardDiff.partials(x)[1]
    derivative(x::Real)=0.
    (;value=baseline,derivative=derivative(dual))
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
    surface in ("z1","z2")||throw(ArgumentError("Expected surface z1 or z2"))
    packet=analytic_shell_recovery_tangent(ctx,direction,u,id_map,X,node_R,snorm_normals)
    keys=("normal_x","normal_y","shear_xy")
    (features=[packet.value["stress"][surface][k] for k in keys],
        dfeatures=[packet.derivative["stress"][surface][k] for k in keys])
end
