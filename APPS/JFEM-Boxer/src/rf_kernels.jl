# Native reserve-factor numerical kernels. Values are utilization (LIMIT demand
# times the appropriate assessment factor / capacity), never display sentinels.
# Local AD is used only for scalar constitutive/recovery chains; plate spectral
# derivatives use the stationary Rayleigh quotient of a verified eigenpair.
using LinearAlgebra
import ForwardDiff

function rf_get(x,k,default=nothing)
    if x isa AbstractDict
        k isa keytype(x)&&haskey(x,k)&&return x[k]
        s=string(k);s isa keytype(x)&&haskey(x,s)&&return x[s]
        key=tryparse(Int,s);key!==nothing&&key isa keytype(x)&&haskey(x,key)&&return x[key]
    elseif x isa NamedTuple
        key=Symbol(string(k));hasproperty(x,key)&&return getproperty(x,key)
    end
    default
end
rf_entries(x)=x isa AbstractDict ? collect(pairs(x)) : x isa AbstractVector ? collect(enumerate(x)) : Pair{Any,Any}[]
rf_positive(x)=x isa Real&&isfinite(x)&&x>0
rf_number(x)=x isa Real&&isfinite(x)
rf_flat(x)=x isa AbstractMatrix ? [x[i,j] for i in axes(x,1) for j in axes(x,2)] : x isa AbstractVector&&length(x)>0&&first(x) isa AbstractVector ? reduce(vcat,x) : collect(x)
rf_matrix(x)=reshape(rf_flat(x),3,3)'
rf_primal(x::ForwardDiff.Dual)=ForwardDiff.value(x)
rf_primal(x)=x
"""Exact extremum value with a seed-independent Clarke-average tie partial.
The active set is chosen from primal values, never Dual ordering/partials.
"""
function rf_active_max(values)
    v=collect(values);isempty(v)&&throw(ArgumentError("Empty RF extremum"))
    peak=maximum(rf_primal(x) for x in v);tolerance=64eps(Float64)*max(abs(peak),floatmin(Float64))
    active=filter(x->abs(rf_primal(x)-peak)<=tolerance,v)
    peak+sum(x-rf_primal(x) for x in active)/length(active)
end
rf_active_min(values)=-rf_active_max(-x for x in values)
function rf_vm(x,y,s)
    q=max(zero(x+y+s),x*x+y*y-x*y+3s*s)
    rf_primal(q)==0 ? zero(q) : sqrt(q)
end
function rf_principal(e1,e2,g)
    radius=hypot((e1-e2)/2,g/2)
    rf_primal(radius)==0&&(radius=zero(e1+e2+g))
    ((e1+e2)/2+radius,(e1+e2)/2-radius)
end

function rf_section_matrix(parts)
    isempty(parts)&&throw(ArgumentError("No cross-section parts are available"))
    # Integrate the extension/bending energy in a common physical reference;
    # condense extension ONCE, preserving all parallel-axis/coupling effects.
    T=promote_type([typeof(v) for p in parts for v in (haskey(p,"axial_matrix") ? rf_flat(p["axial_matrix"]) : [p["area_m2"],p["young_pa"]])]...)
    K=zeros(T,3,3)
    for p in parts
        if haskey(p,"axial_matrix")
            K.+=rf_matrix(p["axial_matrix"])
        else
            A,E,y,z=p["area_m2"],p["young_pa"],p["centroid_y_m"],p["centroid_z_m"]
            iy,iz,iyz=p["iyy_m4"],p["izz_m4"],rf_get(p,"iyz_m4",0.)
            K.+=E.*[A A*y A*z; A*y iz+A*y*y iyz+A*y*z; A*z iyz+A*y*z iy+A*z*z]
        end
    end
    K
end

function rf_weakest_ei(K)
    ea=K[1,1];rf_primal(ea)>0||throw(ArgumentError("Nonpositive section axial stiffness"))
    a=K[2,2]-K[1,2]^2/ea; d=K[3,3]-K[1,3]^2/ea
    b=(K[2,3]+K[3,2])/2-K[1,2]*K[1,3]/ea
    scale=max(abs(a),abs(d),abs(b));rf_primal(scale)>0||throw(ArgumentError("Nonpositive section bending stiffness"))
    aa,dd,bb=a/scale,d/scale,b/scale
    # At an exactly repeated bending axis the individual eigenvalue has a
    # subspace derivative. The trace partial is the symmetric subgradient;
    # a tied square-side direction has that same, unique directional value.
    gap=hypot(aa-dd,2bb)
    major=rf_primal(gap)==0 ? (aa+dd)/2 : (aa+dd+gap)/2
    ei=scale*(aa*dd-bb*bb)/major
    rf_primal(ei)>0||throw(ArgumentError("Singular or indefinite section bending stiffness"))
    ei
end

rf_blade_capacity(E,nu,h,t)=.425*pi^2/(12*(1-nu*nu))*E*(t/h)^2

"""Exact scalar arithmetic of native conservative PBARL equivalent recovery.
Forces: N,V1,V2,T,Ma1,Ma2,Mb1,Mb2. Dimensions/J carry explicit section effects.
"""
function rf_beam_equivalent(shape,forces,dimensions,J=0.)
    n,vy,vz,torque,ma1,ma2,mb1,mb2=forces
    if shape=="BAR"
        b,h=dimensions;A=b*h;i1=b*h^3/12;i2=h*b^3/12
        normal=rf_active_max(abs(n/A-m1*y/i1-m2*z/i2) for (m1,m2) in ((ma1,ma2),(mb1,mb2)) for y in (-h/2,h/2) for z in (-b/2,b/2))
        transverse=1.5*(abs(vy)+abs(vz))/A
        torsion=5abs(torque)/(rf_active_max((b,h))*rf_active_min((b,h))^2)
        return hypot(normal,sqrt(3.)*(transverse+torsion))
    end
    shape=="T"||throw(ArgumentError("Equivalent beam stress requires BAR or T"))
    b,h,tf,tw=dimensions;hw=h-tf;A=b*tf+hw*tw
    yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/A;yf=hw+tf/2
    i1=tw*hw^3/12+hw*tw*(yc-hw/2)^2+b*tf^3/12+b*tf*(yf-yc)^2
    i2=hw*tw^3/12+tf*b^3/12
    polygon=((h-yc,-b/2),(h-yc,b/2),(hw-yc,b/2),(hw-yc,tw/2),(-yc,tw/2),(-yc,-tw/2),(hw-yc,-tw/2),(hw-yc,-b/2))
    normal=rf_active_max(abs(n/A-m1*y/i1-m2*z/i2) for (m1,m2) in ((ma1,ma2),(mb1,mb2)) for (y,z) in polygon)
    clampyc=clamp(yc,zero(yc),hw)
    webq=rf_active_max((abs(yc*hw-hw^2/2),abs(yc*clampyc-clampyc^2/2)))
    web_horizontal_q=(tf*(b^2-tw^2)+h*tw^2)/(8h)
    flange_y=clamp(yc,hw,h)
    flange_vertical_q=rf_active_max((abs((h-yc)^2-(hw-yc)^2),abs((h-yc)^2-(flange_y-yc)^2)))/2
    webs=abs(vy)*webq/i1+abs(vz)*web_horizontal_q/i2
    flanges=abs(vy)*(abs(yf-yc)*b/2+flange_vertical_q)/i1+abs(vz)*b^2/(8i2)
    torquebound=abs(torque)+abs(vz)*abs(yf-yc)
    rectangular_j=(width,height)->begin
        a=rf_active_max((width,height));t=rf_active_min((width,height))
        a*t^3/3*(1-192t/(pi^5*a)*sum(tanh(k*pi*a/(2t))/k^5 for k in 1:2:197))
    end
    # This is the same nominal rectangular-limb stress model as native
    # recovery. The exact whole-section J still enters the equilibrium model;
    # stress recovery's limb rigidity is an explicit dimension-dependent law.
    nominal_j=rectangular_j(b,tf)+rectangular_j(tw,hw)
    shear=rf_active_max((webs+torquebound*tw/nominal_j,flanges+torquebound*tf/nominal_j))
    hypot(normal,sqrt(3.)*shear)
end
rf_sc(m,p)=(iseven(m+p)||m==p) ? 0. : 4m/(pi*(m*m-p*p))
rf_integral_cos(k,lo,hi)=k==0 ? hi-lo : (sin(k*pi*hi)-sin(k*pi*lo))/(k*pi)
rf_integral_sin(k,lo,hi)=k==0 ? zero(lo+hi) : (cos(k*pi*lo)-cos(k*pi*hi))/(k*pi)
function rf_integrals(i,j,lo,hi)
    a=rf_integral_cos(i-j,lo,hi);b=rf_integral_cos(i+j,lo,hi)
    (;cc=(a+b)/2,ss=(a-b)/2,
      cs=(rf_integral_sin(j+i,lo,hi)+rf_integral_sin(j-i,lo,hi))/2,
      sc=(rf_integral_sin(i+j,lo,hi)+rf_integral_sin(i-j,lo,hi))/2)
end

"""Physical Fourier matrices. Compression-positive signed N, full D16/D26.
`cells` holds normalized rectangles and their spatial membrane resultant.
"""
function rf_plate_matrices(L,W,D,N,modes;cells=nothing)
    d=rf_flat(D);T=promote_type(typeof(L),typeof(W),eltype(d),eltype(N))
    n=length(modes);B=zeros(T,n,n);G=zeros(T,n,n)
    for i in 1:n
        m,k=modes[i];a=m*pi/L;b=k*pi/W;aa=a*a;bb=b*b
        B[i,i]=d[1]*aa*aa+2*(d[2]+2d[9])*aa*bb+d[5]*bb*bb
        for j in 1:i
            p,q=modes[j];c=p*pi/L;e=q*pi/W
            if j<i
                sscc=rf_sc(m,p)*rf_sc(k,q);ccss=rf_sc(p,m)*rf_sc(q,k)
                B[i,j]=B[j,i]=-2*(d[3]*(aa*c*e*sscc+a*b*c*c*ccss)+d[6]*(bb*c*e*sscc+a*b*e*e*ccss))
            end
            if cells===nothing
                value=i==j ? N[1]*aa+N[2]*bb : N[3]*(a*e*rf_sc(p,m)*rf_sc(k,q)+b*c*rf_sc(m,p)*rf_sc(q,k))
            else
                value=zero(L+W+sum(d)+sum(N))
                for cell in cells
                    u0,u1,v0,v1=cell.bounds;nx,ny,nxy=cell.N
                    x=rf_integrals(m,p,u0,u1);y=rf_integrals(k,q,v0,v1)
                    value+=4*(nx*a*c*x.cc*y.ss+ny*b*e*x.ss*y.cc+nxy*(a*e*x.cs*y.sc+b*c*x.sc*y.cs))
                end
            end
            G[i,j]=G[j,i]=value
        end
    end
    B,G
end

"""Largest algebraic reciprocal buckling root; not largest absolute root."""
function rf_plate_pair(L,W,D,N,modes;cells=nothing)
    B,G=rf_plate_matrices(L,W,D,N,modes;cells)
    # Uniform signed membrane loading preserves m+n parity, including full
    # D16/D26 coupling. Solve BOTH sectors; halving each dense eigenproblem
    # reduces cubic work by about four without discarding a physical mode.
    # A spatially varying web field generally breaks this symmetry.
    sectors=cells===nothing ? [findall(mode->iseven(sum(mode)),modes),findall(mode->isodd(sum(mode)),modes)] : [collect(eachindex(modes))]
    blocks=Any[];d=rf_flat(D);all_values=Float64[];normH=0.
    for ids in sectors
        isempty(ids)&&continue
        if d[3]==0&&d[6]==0
            diagonal=sqrt.(diag(B)[ids]);all(>(0),diagonal)||throw(ArgumentError("Singular diagonal plate bending law"))
            H=Symmetric(G[ids,ids]./(diagonal*transpose(diagonal)));E=eigen(H)
            push!(blocks,(;ids,E,diagonal,C=nothing))
        else
            C=cholesky(Symmetric(B[ids,ids]));H=Symmetric(C.L\G[ids,ids]/C.U);E=eigen(H)
            push!(blocks,(;ids,E,diagonal=nothing,C))
        end
        normH=max(normH,opnorm(H,Inf));append!(all_values,E.values)
    end
    sort!(all_values);mu=last(all_values);gap=length(all_values)>1 ? mu-all_values[end-1] : Inf
    cluster_tolerance=128length(modes)*eps(Float64)*max(abs(mu),normH)
    vectors=Vector{Float64}[];cluster_values=Float64[]
    for block in blocks
        indices=findall(value->mu-value<=cluster_tolerance,block.E.values)
        isempty(indices)&&continue
        local_vectors=block.C===nothing ? block.E.vectors[:,indices]./block.diagonal : block.C.U\block.E.vectors[:,indices]
        for (j,index) in enumerate(indices)
            vector=zeros(length(modes));vector[block.ids]=local_vectors[:,j]
            push!(vectors,vector);push!(cluster_values,block.E.values[index])
        end
    end
    cluster=hcat(vectors...);q=vectors[argmax(cluster_values)]
    resolution=128length(modes)*eps(Float64)*normH
    residual=norm(G*q-mu*B*q)/max(norm(G*q),abs(mu)*norm(B*q),eps())
    (;mu,q,cluster,gap,resolution,residual,B,G,modes)
end

# Matrix-free eigenvector energy contractions used by local partials. These
# avoid ForwardDiff over a dense n-by-n matrix for every recovered shell term.
function rf_plate_bending_quadratic(L,W,D,modes,q)
    d=rf_flat(D);value=zero(L+W+sum(d))
    for i in eachindex(modes)
        m,k=modes[i];a=m*pi/L;b=k*pi/W;aa=a*a;bb=b*b
        value+=q[i]^2*(d[1]*aa*aa+2*(d[2]+2d[9])*aa*bb+d[5]*bb*bb)
        for j in 1:i-1
            p,n=modes[j];c=p*pi/L;e=n*pi/W
            sscc=rf_sc(m,p)*rf_sc(k,n);ccss=rf_sc(p,m)*rf_sc(n,k)
            bij=-2*(d[3]*(aa*c*e*sscc+a*b*c*c*ccss)+d[6]*(bb*c*e*sscc+a*b*e*e*ccss))
            value+=2q[i]*q[j]*bij
        end
    end
    value
end
function rf_plate_geometric_quadratic(L,W,N,modes,q;bounds=nothing)
    value=zero(L+W+sum(N))
    for i in eachindex(modes)
        m,k=modes[i];a=m*pi/L;b=k*pi/W
        for j in 1:i
            p,n=modes[j];c=p*pi/L;e=n*pi/W
            gij=if bounds===nothing
                i==j ? N[1]*a*a+N[2]*b*b : N[3]*(a*e*rf_sc(p,m)*rf_sc(k,n)+b*c*rf_sc(m,p)*rf_sc(n,k))
            else
                u0,u1,v0,v1=bounds;x=rf_integrals(m,p,u0,u1);y=rf_integrals(k,n,v0,v1)
                4*(N[1]*a*c*x.cc*y.ss+N[2]*b*e*x.ss*y.cc+N[3]*(a*e*x.cs*y.sc+b*c*x.sc*y.cs))
            end
            value+=(i==j ? 1 : 2)*q[i]*q[j]*gij
        end
    end
    value
end

function rf_plate_diagonal(L,W,D,N)
    d=rf_flat(D);nx,ny=N[1:2];ax=(pi/L)^2;by=(pi/W)^2
    best=Inf;mode=(0,0);roots=Dict{Tuple{Int,Int},Float64}()
    function trial(m,n)
        m>=1&&n>=1||return
        x=ax*m*m;y=by*n*n;den=nx*x+ny*y
        if den>0
            ratio=(d[1]*x*x+2*(d[2]+2d[9])*x*y+d[5]*y*y)/den
            ratio>0&&(roots[(m,n)]=ratio)
            if ratio>0&&ratio<best;best=ratio;mode=(m,n);end
        end
    end
    for m in 1:3,n in 1:3;trial(m,n);end
    H=d[2]+2d[9]
    if nx>0
        trial(max(1,floor(Int,sqrt(max(0.,-ny*by/(nx*ax))))+1),1)
        a=d[1]*nx;b=2d[1]*ny*by;c=(2H*ny-d[5]*nx)*by*by;disc=b*b-4a*c
        if disc>=0
            x=(-b+sqrt(disc))/(2a);m=sqrt(max(0.,x/ax));trial(floor(Int,m),1);trial(ceil(Int,m),1)
        end
    end
    if ny>0
        trial(1,max(1,floor(Int,sqrt(max(0.,-nx*ax/(ny*by))))+1))
        a=d[5]*ny;b=2d[5]*nx*ax;c=(2H*nx-d[1]*ny)*ax*ax;disc=b*b-4a*c
        if disc>=0
            y=(-b+sqrt(disc))/(2a);n=sqrt(max(0.,y/by));trial(1,floor(Int,n));trial(1,ceil(Int,n))
        end
    end
    isfinite(best)||throw(ArgumentError("No finite diagonal plate root"))
    coupling=min(0.,H);large=(d[1]+d[5]+hypot(d[1]-d[5],2coupling))/2
    C=(d[1]*d[5]-coupling^2)/large
    C>0||throw(ArgumentError("Plate high-mode bound is unresolved"))
    radius=2max(nx,ny)*best/C;mmax=max(1,floor(Int,sqrt(radius/ax)));nmax=max(1,floor(Int,sqrt(radius/by)))
    mmax*nmax<=1_000_000||throw(ArgumentError("Diagonal plate mode search exceeds limit"))
    for m in 1:mmax,n in 1:nmax;ax*m*m+by*n*n<=radius*(1+64eps())&&trial(m,n);end
    eigenvalues=sort!(collect(values(roots)))
    gap=length(eigenvalues)>1 ? inv(eigenvalues[1])-inv(eigenvalues[2]) : Inf
    active_modes=sort!([key for (key,value) in roots if abs(value-best)<=1e-8max(abs(best),eps())])
    pair=rf_plate_pair(L,W,D,N,active_modes)
    merge(pair,(gap=gap,converged=true,approximation=false,error=0.,history=Any[],basisM=mmax,basisN=nmax,method="Exact bounded integer sine-mode search"))
end

rf_non_destabilizing(N)=N[1]<=0&&N[2]<=0&&N[1]*N[2]-N[3]^2>=0

"""Certified lower bound on every positive equivalent-plate buckling RF.

This is not a missing eigenvalue. D >= d I, N <= n I and the rectangular
Dirichlet Poincare inequality imply lambda >= d*pi^2*(L^-2+W^-2)/n.
Scaled Gershgorin and principal-load bounds include roundoff margins. A
nonpositive bending lower bound cannot certify a case and returns nothing.
"""
function rf_plate_lower_bound(L,W,D,N;cells=nothing,factor=1.,fixity=1.)
    rf_positive(L)&&rf_positive(W)&&rf_positive(factor)&&rf_positive(fixity)||return nothing
    d=rf_flat(D);length(d)==9&&all(isfinite,d)||return nothing
    ds=maximum(abs,d);rf_positive(ds)||return nothing
    rounding=128eps(Float64)
    lower=minimum(d[3(i-1)+i]/ds-sum(abs(d[3(i-1)+j]/ds) for j in 1:3 if j!=i) for i in 1:3)-rounding
    lower>0||return nothing
    loads=cells===nothing ? [N] : [cell.N for cell in cells]
    isempty(loads)&&return nothing
    all(n->length(n)==3&&all(isfinite,n),loads)||return nothing
    ns=maximum(maximum(abs,n) for n in loads);rf_positive(ns)||return nothing
    upper=maximum(begin
        x,y,s=n./ns
        (x+y)/2+hypot((x-y)/2,s)+rounding
    end for n in loads)
    upper>0||return nothing
    bound=fixity/factor*(ds/ns)*(lower/upper)*pi^2*(1/L^2+1/W^2)*(1-256eps(Float64))
    rf_positive(bound) ? bound : nothing
end

"""Same nested Fourier families and explicit 100-term fallback as the viewer.
Derivatives always freeze the returned physical `modes`.
"""
function rf_solve_plate(L,W,D,N;cells=nothing,options=Dict(),frozen_modes=nothing)
    rf_positive(L)&&rf_positive(W)||throw(ArgumentError("Positive panel length/width required"))
    d=Float64.(rf_flat(D));isposdef(Symmetric(rf_matrix(d)))||throw(ArgumentError("Plate bending law is not positive definite"))
    all(isfinite,d)&&all(isfinite,N)||throw(ArgumentError("Nonfinite plate data"))
    if cells===nothing ? rf_non_destabilizing(N) : all(rf_non_destabilizing(cell.N) for cell in cells)
        return (;mu=0.,q=Float64[],gap=Inf,resolution=0.,residual=0.,modes=Tuple{Int,Int}[],converged=true,approximation=false,error=0.,history=Any[],basisM=0,basisN=0,method="No destabilizing membrane state")
    end
    frozen_modes===nothing||return merge(rf_plate_pair(L,W,d,N,frozen_modes;cells),(converged=true,approximation=false,error=0.,history=Any[],basisM=maximum(first,frozen_modes),basisN=maximum(last,frozen_modes),method="Frozen physical Fourier basis"))
    stiffness=max(abs.(d)...);abs(d[3])<=64eps()*stiffness&&(d[3]=d[7]=0.);abs(d[6])<=64eps()*stiffness&&(d[6]=d[8]=0.)
    scale=cells===nothing ? maximum(abs,N) : maximum(maximum(abs,cell.N) for cell in cells)
    direction=N./scale
    if cells===nothing&&d[3]==0&&d[6]==0&&abs(direction[3])<=64eps()
        return rf_plate_diagonal(L,W,d,[N[1],N[2],0.])
    end
    maxdim=min(Int(rf_get(options,"maxDimension",cells===nothing ? 1024 : 256)),cells===nothing ? 1024 : 256)
    tolerance=rf_get(options,"tolerance",.005);aspect=L/W*(d[5]/d[1])^.25
    history=Any[];best=Inf;answer=nothing
    function refine(stage,dimensions,limit)
        previous=nothing;stable=0
        for order in 3:2:63
            m,n=dimensions(order);m*n<=limit||break
            modes=[(i,j) for i in 1:m for j in 1:n]
            trial=rf_plate_pair(L,W,d,N,modes;cells)
            rf=trial.mu>trial.resolution ? 1/trial.mu : Inf
            change=previous===nothing||!isfinite(rf) ? Inf : abs(previous.rf-rf)/rf
            stable=isfinite(change)&&change<=tolerance&&m>previous.m&&n>previous.n ? stable+1 : 0
            push!(history,Dict("stage"=>stage,"order"=>order,"m"=>m,"n"=>n,"reserveFactor"=>isfinite(rf) ? rf : nothing,"relativeChange"=>isfinite(change) ? change : nothing))
            notworse=rf<=best*(1+64eps());best=min(best,rf)
            previous=isfinite(rf) ? (;rf,m,n) : nothing
            answer=merge(trial,(converged=stable>=2&&notworse,approximation=false,error=change,history=copy(history),basisM=m,basisN=n,method=cells===nothing ? "Simply supported double-sine Ritz plate" : "Spatial membrane-field double-sine Ritz plate"))
            answer.converged&&break
        end
    end
    refine("geometry",q->(max(q,ceil(Int,aspect)+q-1),max(q,ceil(Int,1/aspect)+q-1)),min(256,maxdim))
    if (answer===nothing||!answer.converged)&&cells===nothing&&maxdim>256
        ratio=aspect
        if direction[3]!=0
            principal=(direction[1]+direction[2]+hypot(direction[1]-direction[2],2direction[3]))/2
            candidate=L/W*abs(direction[3]/(principal-direction[1]));isfinite(candidate)&&candidate>0&&(ratio=candidate)
        end
        refine("load_direction",q->ratio>=1 ? (ceil(Int,q*ratio),q) : (q,ceil(Int,q/ratio)),maxdim)
    end
    answer===nothing&&throw(ArgumentError("No admissible Fourier basis within requested limit"))
    answer.converged&&return answer
    rf_get(options,"truncatedFallback",true)||return answer
    sources=filter(h->rf_get(h,"reserveFactor",nothing)!==nothing,history)
    isempty(sources)&&return answer
    source=sources[argmin([h["reserveFactor"] for h in sources])];m,n=source["m"],source["n"]
    modes=[(i,j) for i in 1:m for j in 1:n];selected=Int[]
    sectors=cells===nothing ? [findall(i->iseven(sum(modes[i])),eachindex(modes)),findall(i->isodd(sum(modes[i])),eachindex(modes))] : [collect(eachindex(modes))]
    B,G=rf_plate_matrices(L,W,d,N,modes;cells)
    for (s,ids) in enumerate(sectors)
        isempty(ids)&&continue
        C=cholesky(Symmetric(B[ids,ids]));E=eigen(Symmetric(C.L\G[ids,ids]/C.U));q=C.U\E.vectors[:,end]
        ranking=sortperm([q[i]^2*B[ids[i],ids[i]] for i in eachindex(ids)];rev=true)
        keep=min(length(ids),div(100,length(sectors))+(s<=rem(100,length(sectors)) ? 1 : 0))
        append!(selected,ids[ranking[1:keep]])
    end
    selected_modes=modes[sort!(selected)];pair=rf_plate_pair(L,W,d,N,selected_modes;cells)
    merge(pair,(converged=false,approximation=true,error=answer.error,history,basisM=maximum(first,selected_modes),basisN=maximum(last,selected_modes),sourceBasisM=m,sourceBasisN=n,method="Eigenvector-guided 100-term truncated physical Ritz approximation"))
end

function rf_validate_tiling(cells)
    isempty(cells)&&throw(ArgumentError("No spatial plate cells"));tol=1e-9
    for cell in cells
        a,b,c,d=cell.bounds
        0<=a<b<=1&&0<=c<d<=1||throw(ArgumentError("Invalid normalized spatial cell bounds"))
    end
    xs=sort!(unique(reduce(vcat,[[c.bounds[1],c.bounds[2]] for c in cells])))
    abs(first(xs))<=tol&&abs(last(xs)-1)<=tol||throw(ArgumentError("Spatial plate cells leave uncovered length"))
    for i in 1:length(xs)-1
        xs[i+1]-xs[i]<=tol&&continue;x=(xs[i]+xs[i+1])/2
        ys=sort!([(c.bounds[3],c.bounds[4]) for c in cells if c.bounds[1]<x<c.bounds[2]])
        stop=0.
        for (lo,hi) in ys
            abs(lo-stop)<=tol||throw(ArgumentError(lo<stop ? "Spatial plate cells overlap" : "Spatial plate cells leave a hole"));stop=hi
        end
        abs(stop-1)<=tol||throw(ArgumentError("Spatial plate cells leave uncovered height"))
    end
    nothing
end
