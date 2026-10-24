# Scalar Saint-Venant cross-section analysis. The natural boundary condition
# is traction-free; pinning one value removes only the arbitrary warp constant.
# K*omega = integral(grad(N)' * [z,-y]); J = Iy+Iz - omega'K*omega.
# The centre of twist follows from the first moments of omega, independent
# of the arbitrary constant when coordinates are measured from the centroid.
# The quadratic tensor-product mesh resolves the flange/web junction exactly.

const _t_warping_cache = Dict{NTuple{4,Float64},NamedTuple}()
const _t_warping_cache_lock = ReentrantLock()
const _t_warping_cache_limit = 1024

# Exact rectangular limit of the Saint-Venant problem. Independent T-shape
# derivatives cease to share the interior mesh topology at this boundary.
function _t_section_rectangle_limit(b,h)
    a,c=max(b,h),min(b,h)
    series=sum(tanh(k*pi*a/(2c))/k^5 for k in 1:2:999)
    j=a*c^3/3*(1-192c/(pi^5*a)*series)
    return (J=j,N1=0.0,K1=5/6,K2=5/6,nodes=0,resolution=0,
        relative_change=0.0,J_gradient=nothing,N1_gradient=nothing,
        K1_gradient=nothing,K2_gradient=nothing)
end

@inline _section_quadratic_shape(s) =
    ([s*(s-1)/2, 1-s*s, s*(s+1)/2], [s-.5, -2s, s+.5])

function _section_graded_coordinates(n)
    ends=[begin s=k/n;s^3/(s^3+(1-s)^3) end for k in 0:n]
    r=zeros(2n+1);r[1:2:end]=ends
    r[2:2:end]=(ends[1:end-1]+ends[2:end])/2
    return r
end

function _t_section_warping_mesh(b,h,tf,tw,n)
    hw=h-tf
    area=b*tf+hw*tw
    yc=(hw*tw*hw/2+b*tf*(hw+tf/2))/area
    i1=tw*hw^3/12+tw*hw*(yc-hw/2)^2+b*tf^3/12+b*tf*(hw+tf/2-yc)^2
    i2=hw*tw^3/12+tf*b^3/12
    # Grade toward the free corners and flange/web junction. Fixed topology
    # also permits exact shape derivatives without differentiating a remesh.
    r=_section_graded_coordinates(n)
    x=vcat((-b/2 .*(1 .-r).-tw/2 .*r)[1:end-1],
           (tw.*(r.-.5))[1:end-1], tw/2 .*(1 .-r).+b/2 .*r)
    y=vcat((hw.*r)[1:end-1],hw.+tf.*r)
    xp=vcat([(-(1-s)/2,0.,0.,-s/2) for s in r[1:end-1]],
            [(0.,0.,0.,s-.5) for s in r[1:end-1]],
            [(s/2,0.,0.,(1-s)/2) for s in r])
    yp=vcat([(0.,s,-s,0.) for s in r[1:end-1]],[(0.,1.,s-1,0.) for s in r])
    da=[tf,tw,b-tw,hw]
    dq=[tf*(h-tf/2),tw*hw+b*tf,-tw*hw+b*(h-tf),hw^2/2]
    dyc=(dq.-yc.*da)./area
    di1=zeros(4);di2=zeros(4)
    for k in 1:4
        db,dh,df,dt=(k==j ? 1. : 0. for j in 1:4);dqw=dh-df
        di1[k]=hw^3*dt/3+tw*hw^2*dqw+(h^3-hw^3)*db/3+b*(h^2*dh-hw^2*dqw)-yc^2*da[k]-2area*yc*dyc[k]
        di2[k]=(tw^3*dqw+3hw*tw^2*dt+b^3*df+3tf*b^2*db)/12
    end
    node_ids=Dict{Tuple{Int,Int},Int}()
    coords=NTuple{2,Float64}[]
    coord_derivatives=Tuple{NTuple{4,Float64},NTuple{4,Float64}}[]
    elements=Vector{Int}[]
    for j in 1:2:length(y)-2, i in 1:2:length(x)-2
        y[j]<hw && abs(x[i+1])>tw/2 && continue
        nodes=Int[]
        for jj in 0:2, ii in 0:2
            nid=get!(node_ids,(i+ii,j+jj)) do
                push!(coords,(x[i+ii],y[j+jj]-yc))
                push!(coord_derivatives,(xp[i+ii],ntuple(k->yp[j+jj][k]-dyc[k],4)))
                length(coords)
            end
            push!(nodes,nid)
        end
        push!(elements,nodes)
    end
    nn=length(coords)
    nn<=200_000 || throw(ArgumentError("T-section warping mesh exceeds 200000 points; use explicit section properties for this extreme thickness ratio."))
    rows=Int[];cols=Int[];values=Float64[]
    sizehint!(rows,81length(elements));sizehint!(cols,81length(elements));sizehint!(values,81length(elements))
    f=zeros(nn);q=zeros(nn);qy=zeros(nn)
    points=((-sqrt(3/5),5/9),(0.,8/9),(sqrt(3/5),5/9))
    for nodes in elements
        xx=[coords[k][1] for k in nodes]; yy=[coords[k][2] for k in nodes]
        dx=xx[3]-xx[1];dy=yy[7]-yy[1]
        ke=zeros(9,9);fe=zeros(9);qe=zeros(9);qye=zeros(9)
        for (s,ws) in points, (t,wt) in points
            nx,dnx=_section_quadratic_shape(s);ny,dny=_section_quadratic_shape(t)
            N=kron(ny,nx);B=vcat(transpose(kron(ny,dnx)*(2/dx)),transpose(kron(dny,nx)*(2/dy)))
            xp=dot(N,xx);yp=dot(N,yy);weight=dx*dy*ws*wt/4
            ke .+= weight.*(B'*B)
            fe .+= weight.*(B'*[yp,-xp]);qe .+= (weight*xp).*N
            qye .+= (weight*yp).*N
        end
        for (i,a) in enumerate(nodes)
            f[a]+=fe[i];q[a]+=qe[i];qy[a]+=qye[i]
            for (j,bid) in enumerate(nodes)
                push!(rows,a);push!(cols,bid);push!(values,ke[i,j])
            end
        end
    end
    K=sparse(rows,cols,values,nn,nn)
    factor=cholesky(Symmetric(K[2:end,2:end]))
    fields=vcat(zeros(1,3),factor\hcat(f,q,qy)[2:end,:])
    omega=fields[:,1]
    j=i1+i2-dot(omega,f)
    neutral_offset=-dot(omega,q)/i2
    # Energy-equivalent shear areas: solve the section equilibrium Poisson
    # problems with unit linear bending-stress gradients. The geometric
    # section definition omits Poisson flexure coupling (as does 5/6 for a
    # rectangle); all three fields reuse the same scalar factorization.
    k1=i1^2/(area*dot(qy,fields[:,3]))
    k2=i2^2/(area*dot(q,fields[:,2]))
    # Adjoint shape derivatives use the same three solved fields. Differentiate
    # stationary energy functionals with nodal fields held fixed; their implicit
    # derivatives cancel. No perturbed section solve or finite difference is used.
    dJ=zeros(4);dnum=zeros(4);dhx=zeros(4);dhy=zeros(4)
    for nodes in elements
        xx=[coords[k][1] for k in nodes];yy=[coords[k][2] for k in nodes]
        dx=xx[3]-xx[1];dy=yy[7]-yy[1]
        local_fields=fields[nodes,:]
        dxnodes=[coord_derivatives[node][1][k] for node in nodes,k in 1:4]
        dynodes=[coord_derivatives[node][2][k] for node in nodes,k in 1:4]
        for (s,ws) in points,(t,wt) in points
            nx,dnx=_section_quadratic_shape(s);ny,dny=_section_quadratic_shape(t)
            N=kron(ny,nx);B=vcat(transpose(kron(ny,dnx)*(2/dx)),transpose(kron(dny,nx)*(2/dy)))
            xv=dot(N,xx);yv=dot(N,yy);weight=dx*dy*ws*wt/4
            values=N'*local_fields;grad=B*local_fields
            wx,wz=grad[:,1];px,pz=grad[:,2];qx,qz=grad[:,3]
            omega_v,phi_v,chi_v=values
            jw=(wx-yv)^2+(wz+xv)^2
            num=px*(yv-wx)+pz*(-xv-wz)+xv*omega_v
            hx=2xv*phi_v-px^2-pz^2;hy=2yv*chi_v-qx^2-qz^2
            for k in 1:4
                ddx=(dxnodes[3,k]-dxnodes[1,k])/dx;ddy=(dynodes[7,k]-dynodes[1,k])/dy
                dxv=dot(N,dxnodes[:,k]);dyv=dot(N,dynodes[:,k]);dw=ddx+ddy
                dwx=-wx*ddx;dwz=-wz*ddy;dpx=-px*ddx;dpz=-pz*ddy;dqx=-qx*ddx;dqz=-qz*ddy
                dJ[k]+=weight*(2(wx-yv)*(dwx-dyv)+2(wz+xv)*(dwz+dxv)+jw*dw)
                dnum[k]+=weight*(dpx*(yv-wx)+px*(dyv-dwx)+dpz*(-xv-wz)+pz*(-dxv-dwz)+dxv*omega_v+num*dw)
                dhx[k]+=weight*(2dxv*phi_v-2(px*dpx+pz*dpz)+hx*dw)
                dhy[k]+=weight*(2dyv*chi_v-2(qx*dqx+qz*dqz)+hy*dw)
            end
        end
    end
    numerator=dot(omega,q)
    dn1=-dnum./i2.+(numerator/i2^2).*di2
    dk1=k1.*(2di1./i1.-da./area.-dhy./dot(qy,fields[:,3]))
    dk2=k2.*(2di2./i2.-da./area.-dhx./dot(q,fields[:,2]))
    return (J=j,N1=neutral_offset,K1=k1,K2=k2,nodes=nn,resolution=n,
        J_gradient=Tuple(dJ),N1_gradient=Tuple(dn1),K1_gradient=Tuple(dk1),K2_gradient=Tuple(dk2))
end

"""Finite-thickness T-section torsion and neutral-to-shear-axis offset.

Analytic area/inertias remain exact. Warping is refined until successive
quadratic-mesh torsion constants differ by less than 0.01%; its section shape
is cached independently of units. No material or reference-output fit enters
the cross-section problem.
"""
function t_section_warping(b,h,tf,tw)
    all(isfinite,(b,h,tf,tw)) && b>=tw>0 && h>=tf>0 ||
        throw(ArgumentError("T section requires finite b >= tw > 0 and h >= tf > 0"))
    (b==tw || h==tf) && return _t_section_rectangle_limit(b,h)
    scale=max(b,h)
    min(tf,tw,h-tf,(b-tw)/2)/scale>=1e-6 || throw(ArgumentError(
        "T-section thickness or junction width is below 1e-6 of its overall size; " *
        "section warping would be ill-conditioned. Supply explicit section properties."))
    key=(Float64(b/scale),Float64(h/scale),Float64(tf/scale),Float64(tw/scale))
    result=lock(_t_warping_cache_lock) do
        # Retain only small scalar results and gradients; factorization and mesh
        # storage are temporary. Bound memory for interactive section sizing.
        if !haskey(_t_warping_cache,key) && length(_t_warping_cache)>=_t_warping_cache_limit
            delete!(_t_warping_cache,first(keys(_t_warping_cache)))
        end
        get!(_t_warping_cache,key) do
            previous=_t_section_warping_mesh(key...,2)
            for n in (4,8,16,32)
                current=_t_section_warping_mesh(key...,n)
                change=abs(current.J/previous.J-1)
                if change<=1e-4
                    return merge(current,(relative_change=change,))
                end
                previous=current
            end
            throw(ArgumentError("T-section warping did not converge to a 0.01% successive-mesh tolerance; supply explicit section properties."))
        end
    end
    return merge(result,(J=result.J*scale^4,N1=result.N1*scale,
        J_gradient=map(v->v*scale^3,result.J_gradient),
        K1_gradient=map(v->v/scale,result.K1_gradient),
        K2_gradient=map(v->v/scale,result.K2_gradient)))
end
