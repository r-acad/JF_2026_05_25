# Objective corotational Q4 work with additive rotation-vector unknowns.
# Local constitutive work uses the captured linear shell operator. The force
# map uses physical engineering spin; its consistent Jacobian is nonsymmetric.
module CorotationalShell
using LinearAlgebra, ForwardDiff
struct TrialDomainError <: Exception
    message::String
end
Base.showerror(io::IO,error::TrialDomainError)=print(io,error.message)
skew(v)=[zero(v[1]) -v[3] v[2];v[3] zero(v[1]) -v[1];-v[2] v[1] zero(v[1])]
function rotation_exp(v)
    t2=dot(v,v);A=skew(v)
    if abs(t2)<1e-10
        a=1-t2/6+t2^2/120-t2^3/5040
        b=.5-t2/24+t2^2/720-t2^3/40320
    else
        t=sqrt(t2);a=sin(t)/t;b=2sin(t/2)^2/t2
    end
    Matrix{eltype(v)}(I,3,3)+a*A+b*(A*A)
end
function rotation_log(R)
    c=(tr(R)-1)/2
    c > -0.99 || throw(TrialDomainError("Corotational shell relative rotation is outside the supported principal-log domain"))
    if abs(1-c)<1e-8
        z=1-c;fac=1+z/3+2z^2/15+2z^3/35
    else
        theta=acos(clamp(c,-one(c),one(c)));fac=theta/sin(theta)
    end
    fac/2*[R[3,2]-R[2,3],R[1,3]-R[3,1],R[2,1]-R[1,2]]
end
function element_frame(X)
    a=X[2,:]+X[3,:]-X[1,:]-X[4,:]
    b=X[3,:]+X[4,:]-X[1,:]-X[2,:]
    e1=a/norm(a);e3=cross(a,b);e3/=norm(e3);e2=cross(e3,e1)
    hcat(e1,e2,e3)
end
# Pure scalar products retain derivatives when a Dual has a zero primal part.
function polar_small_product(A,B)
    [sum(A[i,k]*B[k,j] for k in axes(A,2)) for i in axes(A,1),j in axes(B,2)]
end
function polar_inverse3(A)
    a,b,c=A[1,1],A[1,2],A[1,3]
    d,e,f=A[2,1],A[2,2],A[2,3]
    g,h,i=A[3,1],A[3,2],A[3,3]
    detA=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
    isfinite(detA) && !iszero(detA) || throw(TrialDomainError("Singular corotational trial geometry"))
    [e*i-f*h c*h-b*i b*f-c*e;
     f*g-d*i a*i-c*g c*d-a*f;
     d*h-e*g b*g-a*h a*e-b*d]/detA
end
function nodal_polar_rotation(X,Q0,Y)
    Xc=X .- sum(X;dims=1)/4
    Yc=Y .- sum(Y;dims=1)/4
    reference_scale=norm(Xc)
    isfinite(reference_scale) && reference_scale>0 || throw(ArgumentError("Degenerate corotational reference geometry"))
    if norm(Xc*Q0[:,3])<=64eps(Float64)*reference_scale
        xy=polar_small_product(Xc,Q0[:,1:2])
        A=polar_small_product(transpose(Yc),xy)
        M=polar_small_product(transpose(A),A)
        determinant=norm(cross(A[:,1],A[:,2]))
        isfinite(determinant) && determinant>0 || throw(TrialDomainError("Collapsed corotational trial geometry"))
        scale=sqrt(M[1,1]+M[2,2]+2determinant)
        r11=(M[1,1]+determinant)/scale;r12=M[1,2]/scale
        r21=M[2,1]/scale;r22=(M[2,2]+determinant)/scale
        divisor=determinant # det(sqrt(M)) = sqrt(det(M))
        planar=[j==1 ? (A[i,1]*r22-A[i,2]*r21)/divisor :
            (-A[i,1]*r12+A[i,2]*r11)/divisor for i in 1:3,j in 1:2]
        return polar_small_product(hcat(planar,cross(planar[:,1],planar[:,2])),transpose(Q0))
    end
    # Full-rank orthogonal Procrustes polar factor for a warped reference.
    # Scaled Newton iteration uses only explicit products/cofactors. Eight
    # iterations converge for the bounded reference/trial geometries checked.
    R=polar_small_product(transpose(Yc),Xc)
    for _ in 1:8
        inverse=polar_inverse3(R)
        factor=sqrt(sqrt(sum(x*x for x in inverse)/sum(x*x for x in R)))
        R=[(factor*R[i,j]+inverse[j,i]/factor)/2 for i in 1:3,j in 1:3]
    end
    norm(polar_small_product(transpose(R),R)-I)<2e-12 || throw(TrialDomainError("Polar frame did not converge"))
    det(R)>0 || throw(TrialDomainError("Improper polar frame"))
    R
end
function deformational_dofs(X,Q0,u)
    eltype(u)<:AbstractFloat && all(iszero,u) && return zero(u) # AD must retain the reference derivative.
    Y=(X .- sum(X;dims=1)/4)+permutedims(reshape(u,6,4)[1:3,:])
    c0=vec(sum(X,dims=1))/4;c=vec(sum(Y,dims=1))/4
    R=nodal_polar_rotation(X,Q0,Y)
    d=similar(u)
    for i in 1:4
        for a in 1:3
            d[6i-6+a]=sum((R[b,a]-(b==a ? 1 : 0))*(X[i,b]-c0[b])+R[b,a]*(u[6i-6+b]-sum(u[6j-6+b] for j in 1:4)/4) for b in 1:3)
        end
        relative=polar_small_product(transpose(R),rotation_exp(u[6i-2:6i]))
        d[6i-2:6i]=rotation_log(relative)
    end
    d
end

function potential(e,u)
    d=deformational_dofs(e.X,e.Q0,u)
    .5dot(d,e.K*d)
end
function rotation_left_jacobian(theta)
    t2=dot(theta,theta);W=skew(theta)
    if t2<.01
        a=.5-t2/24+t2^2/720-t2^3/40320+t2^4/3628800
        b=1/6-t2/120+t2^2/5040-t2^3/362880+t2^4/39916800
    else
        t=sqrt(t2);a=2sin(t/2)^2/t2;b=(t-sin(t))/(t2*t)
    end
    Matrix{eltype(theta)}(I,3,3)+a*W+b*polar_small_product(W,W)
end
function engineering_physical_force(e,u)
    Y=(e.X .- sum(e.X;dims=1)/4)+permutedims(reshape(u,6,4)[1:3,:])
    R=nodal_polar_rotation(e.X,e.Q0,Y)
    d=deformational_dofs(e.X,e.Q0,u)
    local_force=permutedims(reshape(e.K*d,6,4))
    Yc=Y .- sum(Y;dims=1)/4
    local_positions=polar_small_product(Yc,R)
    torque=sum(cross(local_positions[i,:],local_force[i,1:3])+local_force[i,4:6] for i in 1:4)
    derivative=ForwardDiff.jacobian(y->vec(nodal_polar_rotation(e.X,e.Q0,reshape(y,4,3))),vec(Y))
    spin=zeros(eltype(derivative),3,12)
    for j in 1:12
        dR=reshape(view(derivative,:,j),3,3)
        relative=polar_small_product(transpose(R),dR)
        spin[:,j]=[relative[3,2]-relative[2,3],relative[1,3]-relative[3,1],relative[2,1]-relative[1,2]]/2
    end
    correction=reshape([sum(spin[k,j]*torque[k] for k in 1:3) for j in 1:12],4,3)
    centered_forces=local_force[:,1:3] .- sum(local_force[:,1:3];dims=1)/4
    forces=polar_small_product(centered_forces,transpose(R))-correction
    moments=polar_small_product(local_force[:,4:6],transpose(R))
    hcat(forces,moments)
end
function engineering_element_force(e,u)
    physical=engineering_physical_force(e,u)
    force=similar(u)
    for i in 1:4
        force[6i-5:6i-3]=physical[i,1:3]
        J=rotation_left_jacobian(u[6i-2:6i])
        force[6i-2:6i]=[sum(J[b,a]*physical[i,b+3] for b in 1:3) for a in 1:3]
    end
    force
end
end # module CorotationalShell

function _corotational_shell_support_report(model, snorm_normals, rbe3_map; load_id=nothing)
    shells=get(model,"CSHELLs",Dict())
    has_quad=any(length(get(e,"NODES",Int[]))==4 for e in values(shells))
    fail(reason)=(supported=false,has_quad=has_quad,reason=reason)
    has_quad || return fail("no_quad4_shell")
    all(length(get(e,"NODES",Int[]))==4 for e in values(shells)) || return fail("mixed_shell_topologies")
    for family in ("CBARs","CBEAMs","CRODs","CONRODs","CTUBEs","CBUSHs","CELASs","CELAS1s","CELAS2s","CSOLIDs")
        isempty(get(model,family,Dict())) || return fail("mixed_"*family)
    end
    isempty(rbe3_map) || return fail("active_linear_MPC_or_rigid_mapping")
    for family in ("RBE1s","RBE2s","RBE3s","RSPLINEs")
        isempty(get(model,family,Dict())) || return fail("finite_rigid_element_"*family)
    end
    _selected_direct_matrix(model,"K2GG")===nothing || return fail("active_direct_stiffness_K2GG")
    scales=_load_sid_scales(model,load_id)
    for load in get(model,"RFORCEs",[])
        iszero(get(scales,Int(load["SID"]),0.)) && continue
        all(iszero,get(load,"R",[0.,0.,0.])) && continue
        iszero(Float64(get(load,"A",0.))) && iszero(Float64(get(load,"RACC",0.))) && continue
        return fail("active_RFORCE_requires_current_configuration_force_and_tangent")
    end
    isempty(snorm_normals) || return fail("active_shell_nodal_normals")
    for e in values(shells)
        iszero(Float64(get(e,"ZOFFS",0.0))) || return fail("element_reference_offset")
        prop=get(get(model,"PSHELLs",Dict()),string(e["PID"]),nothing)
        prop===nothing && return fail("missing_shell_property")
        data=shell_corner_thickness_data(e,prop)
        data===nothing || data.uniform || return fail("nonuniform_corner_thickness")
    end
    (supported=true,has_quad=true,reason="objective_corotational_quad4_engineering_spin")
end

const _COROTATIONAL_PRECISION_LOCK=ReentrantLock()

function _corotational_shell_context(K_linear,ndof,model,id_map,X,node_R,spc_id,rbe3_map; residual_tol=1e-6)
    captured=Dict{Int,Any}();capture_lock=ReentrantLock()
    capture=(eid,pid,dofs,Ke)->lock(capture_lock) do
        captured[eid]=(eid=eid,dofs=copy(dofs),K=copy(Ke))
    end
    K_check,ids_check,_,nd_check,_,_,map_check,_,_=assemble_stiffness(model;element_capture=capture)
    id_map==ids_check && ndof==nd_check && isempty(map_check) || throw(ArgumentError("Corotational shell capture changed the analysis DOF layout"))
    norm(K_check-K_linear)<=2e-12max(norm(K_linear),1.) || throw(ArgumentError("Corotational shell capture differs from the active linear operator"))
    elements=Any[];ii=Int[];jj=Int[];vv=Float64[]
    for (eid,c) in sort(collect(captured);by=first)
        haskey(model["CSHELLs"],string(eid)) || throw(ArgumentError("Corotational shell capture includes a non-shell element"))
        nodes=model["CSHELLs"][string(eid)]["NODES"];indices=[id_map[n] for n in nodes]
        T=zeros(24,24)
        for (k,idx) in enumerate(indices), component in (0,3)
            range=6k-5+component:6k-3+component;T[range,range]=node_R[idx]
        end
        xyz=copy(X[indices,:]);basic_K=T*c.K*transpose(T)
        e=(eid=eid,dofs=c.dofs,X=xyz,Q0=CorotationalShell.element_frame(xyz),K=basic_K,T=T)
        H0=ForwardDiff.jacobian(u->CorotationalShell.engineering_element_force(e,u),zeros(24))
        norm(H0-basic_K)<=2e-10max(norm(basic_K),1.) || throw(ArgumentError("Corotational shell linear operator does not preserve rigid work for element $eid"))
        push!(elements,e)
        for b in 1:24,a in 1:24;push!(ii,c.dofs[a]);push!(jj,c.dofs[b]);push!(vv,c.K[a,b]);end
    end
    K_elements=sparse(ii,jj,vv,ndof,ndof)
    norm(K_elements-K_linear)<=2e-12max(norm(K_linear),1.) || throw(ArgumentError("Corotational shells do not account for the full active stiffness; mixed elements or direct matrices require an explicit compatible nonlinear work law"))
    free,fixed,diagnostics=compute_free_dofs(K_linear,ndof,model,id_map,spc_id,rbe3_map;return_diagnostics=true)
    metric=isempty(free) ? nothing : cholesky(Symmetric(K_linear[free,free]))
    # This estimate triggers more accurate arithmetic only. It never changes
    # the requested convergence tolerance or accepts an unconverged state.
    subtraction_scale=zeros(ndof)
    for e in elements
        length_scale=max(norm(e.X),norm(e.X .- sum(e.X;dims=1)/4))
        scale=repeat([length_scale,length_scale,length_scale,1.,1.,1.],4)
        subtraction_scale[e.dofs]+=abs.(transpose(e.T))*(abs.(e.K)*scale)
    end
    roundoff_force_bound=64eps(Float64)*norm(subtraction_scale[free])
    (elements=elements,free=free,fixed=fixed,bc_diagnostics=diagnostics,metric=metric,ndof=ndof,
        residual_tol=Float64(residual_tol),roundoff_force_bound=roundoff_force_bound,
        precise_elements=Ref{Any}(nothing),precision_refinements=Ref(0))
end

function _corotational_precise_internal_force(context,u)
    lock(_COROTATIONAL_PRECISION_LOCK) do
        setprecision(BigFloat,128) do
            if context.precise_elements[]===nothing
                context.precise_elements[]=[merge(e,(X=BigFloat.(e.X),
                    Q0=CorotationalShell.element_frame(BigFloat.(e.X)),
                    K=BigFloat.(e.K),T=BigFloat.(e.T))) for e in context.elements]
            end
            force=zeros(BigFloat,context.ndof);q=BigFloat.(u)
            for e in context.precise_elements[]
                local_u=e.T*q[e.dofs]
                force[e.dofs]+=transpose(e.T)*CorotationalShell.engineering_element_force(e,local_u)
            end
            context.precision_refinements[]+=1
            Float64.(force)
        end
    end
end

function _corotational_applied_force(physical,u)
    force=eltype(u).(physical)
    for i in 1:div(length(u),6)
        theta=view(u,6i-2:6i);J=CorotationalShell.rotation_left_jacobian(theta)
        force[6i-2:6i]=[sum(J[b,a]*physical[6i-3+b] for b in 1:3) for a in 1:3]
    end
    force
end

function _corotational_applied_force_tangent(physical,u)
    ndof=length(u);force=_corotational_applied_force(physical,u)
    ii=Int[];jj=Int[];vv=Float64[];wi=Int[];wj=Int[];wv=Float64[]
    for i in 1:div(ndof,6)
        base=6i-6;theta=u[base+4:base+6];moment=physical[base+4:base+6]
        J=transpose(CorotationalShell.rotation_left_jacobian(theta))
        for a in 1:3;push!(wi,base+a);push!(wj,base+a);push!(wv,1.);end
        for b in 1:3,a in 1:3;push!(wi,base+3+a);push!(wj,base+3+b);push!(wv,J[a,b]);end
        if any(!iszero,moment)
            block=ForwardDiff.jacobian(q->transpose(CorotationalShell.rotation_left_jacobian(q))*moment,theta)
            for b in 1:3,a in 1:3;push!(ii,base+3+a);push!(jj,base+3+b);push!(vv,block[a,b]);end
        end
    end
    force,sparse(ii,jj,vv,ndof,ndof),sparse(wi,wj,wv,ndof,ndof)
end

function _evaluate_nonlinear_state_corotational(context,K_linear,F_applied,u)
    ndof=context.ndof;force=zeros(ndof);ii=Int[];jj=Int[];vv=Float64[];stored=0.
    for e in context.elements
        local_u=e.T*u[e.dofs]
        maximum(norm(view(local_u,6i-2:6i)) for i in 1:4)<pi-0.05 || throw(CorotationalShell.TrialDomainError("Corotational shell nodal rotation is outside the supported principal rotation-vector domain"))
        f=CorotationalShell.engineering_element_force(e,local_u)
        H=ForwardDiff.jacobian(v->CorotationalShell.engineering_element_force(e,v),local_u)
        force[e.dofs]+=transpose(e.T)*f;H=transpose(e.T)*H*e.T
        stored+=CorotationalShell.potential(e,local_u)
        for b in 1:24,a in 1:24;push!(ii,e.dofs[a]);push!(jj,e.dofs[b]);push!(vv,H[a,b]);end
    end
    # The undeformed reference has exactly zero constitutive distortion. This
    # identity also prevents roundoff from inventing a load at u=0.
    reference_state=all(iszero,u)
    reference_state && fill!(force,0.)
    tangent=sparse(ii,jj,vv,ndof,ndof);residual=force-F_applied
    active=context.free;linear=K_linear*u
    rn=norm(residual[active]);fn=norm(F_applied[active])
    refined=!reference_state && rn<=context.roundoff_force_bound &&
        context.residual_tol*max(fn,1e-30)<=context.roundoff_force_bound
    if refined
        force=_corotational_precise_internal_force(context,u)
        residual=force-F_applied;rn=norm(residual[active])
    end
    nonlinear=force-linear
    merit=isempty(active) ? 0. : .5dot(residual[active],context.metric\residual[active])
    (Kg=tangent-K_linear,K_eff=tangent,residual_vector=residual,residual_norm=rn,
        relative_residual=rn/max(fn,1e-30),internal_force_norm=norm(force[active]),
        linear_force_norm=norm(linear[active]),geometric_force_norm=norm(nonlinear[active]),
        free_dofs=context.free,fixed_dofs=context.fixed,bc_diagnostics=context.bc_diagnostics,
        internal_energy=stored,potential_energy=nothing,line_search_merit=merit,
        line_search_merit_directional_derivative=-2merit,unsymmetric_tangent=true,
        internal_force_precision_bits=refined ? 128 : 53)
end

function _corotational_element_distortions(context,u)
    Dict(e.eid=>transpose(e.T)*CorotationalShell.deformational_dofs(e.X,e.Q0,e.T*u[e.dofs]) for e in context.elements)
end

function _corotational_gimbal_rotation(theta; frame=nothing)
    R=CorotationalShell.rotation_exp(theta)
    frame===nothing || (R=transpose(frame)*R*frame)
    abs(R[3,1])<1-1e-10 || throw(ArgumentError("Gimbal rotation reporting is singular; use rotation-vector output for this state"))
    [atan(R[3,2],R[3,3]),asin(clamp(-R[3,1],-1.,1.)),atan(R[2,1],R[1,1])]
end
