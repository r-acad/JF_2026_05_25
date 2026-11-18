# Finite-thickness MSC CHAN2: two side walls and a bottom web, open in +y.
# DIM1=side thickness, DIM2=bottom thickness, DIM3=height, DIM4=width.
# Analytic centroid/inertias use disjoint rectangles. A quadratic section mesh
# solves Saint-Venant torsion and the energy-equivalent geometric shear areas.
const _chan2_warping_cache = Dict{NTuple{4,Float64},NamedTuple}()
const _chan2_warping_cache_lock = ReentrantLock()

function chan2_section_geometry(tw,tb,h,b)
    all(isfinite,(tw,tb,h,b)) && tw>0 && tb>0 && h>=tb && b>=2tw ||
        throw(ArgumentError("CHAN2 requires finite DIM1,DIM2 > 0, DIM3 >= DIM2 and DIM4 >= 2*DIM1"))
    hw=h-tb
    area=b*tb+2tw*hw
    yc=(b*tb^2/2+2tw*hw*(tb+hw/2))/area
    i1=b*tb^3/12+b*tb*(yc-tb/2)^2+2*(tw*hw^3/12+tw*hw*(tb+hw/2-yc)^2)
    i2=tb*b^3/12+2*(hw*tw^3/12+tw*hw*((b-tw)/2)^2)
    return (;A=area,I1=i1,I2=i2,I12=0.0,yc)
end

"""The explicit TWBRBML=1 open-channel library equations.

Area and centroidal moments retain the disjoint, finite-thickness geometry.
Saint-Venant torsion is the sum of the three wall-midline strip terms;
the two effective shear areas are the side walls and clear bottom web.
The shear center follows equilibrium of the open-channel shear flows on
the wall midlines. It lies below the bottom web, measured in the same +y
direction as chan2_section_geometry. No external section values are fitted.
These legacy equations do not define the collapsed solid-rectangle limit.
"""
function chan2_section_legacy(tw,tb,h,b)
    geometry=chan2_section_geometry(tw,tb,h,b)
    h>tb && b>2tw || throw(ArgumentError(
        "TWBRBML=1 CHAN2 requires an open section: DIM3 > DIM2 and DIM4 > 2*DIM1; use TWBRBML=0 for a solid-rectangle limit"))
    clear_height=h-tb
    mid_height=h-tb/2
    mid_width=b-tw
    shear_center=tb/2-3tw*mid_height^2/(tb*mid_width+6tw*mid_height)
    return (J=(mid_width*tb^3+2mid_height*tw^3)/3,
        K1=2tw*clear_height/geometry.A,K2=(b-2tw)*tb/geometry.A,
        N1=geometry.yc-shear_center,relative_change=0.0)
end

function _chan2_section_warping_mesh(tw,tb,h,b,n)
    geometry=chan2_section_geometry(tw,tb,h,b)
    r=_section_graded_coordinates(n)
    x=vcat((-b/2 .+tw.*r)[1:end-1],
        (-b/2+tw .+(b-2tw).*r)[1:end-1], b/2-tw .+tw.*r)
    y=vcat((tb.*r)[1:end-1],tb .+(h-tb).*r)
    node_ids=Dict{Tuple{Int,Int},Int}()
    coordinates=NTuple{2,Float64}[]
    elements=Vector{Int}[]
    for j in 1:2:length(y)-2, i in 1:2:length(x)-2
        y[j]>=tb && abs(x[i+1])<b/2-tw && continue
        nodes=Int[]
        for jj in 0:2, ii in 0:2
            id=get!(node_ids,(i+ii,j+jj)) do
                push!(coordinates,(x[i+ii],y[j+jj]-geometry.yc))
                length(coordinates)
            end
            push!(nodes,id)
        end
        push!(elements,nodes)
    end
    nn=length(coordinates)
    nn<=200_000 || throw(ArgumentError("CHAN2 section mesh exceeds 200000 points; use explicit section properties"))
    rows=Int[];cols=Int[];values=Float64[]
    sizehint!(rows,81length(elements));sizehint!(cols,81length(elements));sizehint!(values,81length(elements))
    f=zeros(nn);qz=zeros(nn);qy=zeros(nn)
    points=((-sqrt(3/5),5/9),(0.,8/9),(sqrt(3/5),5/9))
    for nodes in elements
        xx=[coordinates[k][1] for k in nodes];yy=[coordinates[k][2] for k in nodes]
        dx=xx[3]-xx[1];dy=yy[7]-yy[1]
        ke=zeros(9,9);fe=zeros(9);qze=zeros(9);qye=zeros(9)
        for (s,ws) in points,(t,wt) in points
            nx,dnx=_section_quadratic_shape(s);ny,dny=_section_quadratic_shape(t)
            N=kron(ny,nx)
            B=vcat(transpose(kron(ny,dnx)*(2/dx)),transpose(kron(dny,nx)*(2/dy)))
            z=dot(N,xx);yc=dot(N,yy);weight=dx*dy*ws*wt/4
            ke .+= weight.*(B'*B)
            fe .+= weight.*(B'*[yc,-z])
            qze .+= (weight*z).*N;qye .+= (weight*yc).*N
        end
        for (i,a) in enumerate(nodes)
            f[a]+=fe[i];qz[a]+=qze[i];qy[a]+=qye[i]
            for (j,c) in enumerate(nodes)
                push!(rows,a);push!(cols,c);push!(values,ke[i,j])
            end
        end
    end
    matrix=sparse(rows,cols,values,nn,nn)
    factor=cholesky(Symmetric(matrix[2:end,2:end]))
    fields=vcat(zeros(1,3),factor\hcat(f,qz,qy)[2:end,:])
    # Integrate the positive torsional energy, avoiding subtraction of two
    # nearly equal polar moments for very thin open sections.
    torsion=0.0
    for nodes in elements
        xx=[coordinates[k][1] for k in nodes];yy=[coordinates[k][2] for k in nodes]
        dx=xx[3]-xx[1];dy=yy[7]-yy[1];warp=fields[nodes,1]
        for (s,ws) in points,(t,wt) in points
            nx,dnx=_section_quadratic_shape(s);ny,dny=_section_quadratic_shape(t)
            N=kron(ny,nx)
            wz=dot(kron(ny,dnx)*(2/dx),warp)
            wy=dot(kron(dny,nx)*(2/dy),warp)
            z=dot(N,xx);yc=dot(N,yy)
            torsion+=dx*dy*ws*wt/4*((wz-yc)^2+(wy+z)^2)
        end
    end
    n1=-dot(fields[:,1],qz)/geometry.I2
    k1=geometry.I1^2/(geometry.A*dot(qy,fields[:,3]))
    k2=geometry.I2^2/(geometry.A*dot(qz,fields[:,2]))
    all(x->isfinite(x)&&x>0,(torsion,k1,k2)) && isfinite(n1) ||
        throw(ArgumentError("CHAN2 finite-thickness section solution is not finite and positive"))
    return (J=torsion,N1=n1,K1=k1,K2=k2,nodes=nn,resolution=n)
end

"""Converged finite-thickness CHAN2 torsion, shear areas and neutral-axis offset.

The section problem is material independent, following the existing geometric
shear-area convention (rectangle K=5/6). No legacy thin-wall approximation or
fit to external output is used. PBEAML applies N1; PBARL omits that coupling.
"""
function chan2_section_warping(tw,tb,h,b)
    chan2_section_geometry(tw,tb,h,b)
    (2tw==b || tb==h) && return _t_section_rectangle_limit(b,h)
    scale=max(b,h)
    min(tw,tb,h-tb,b-2tw)/scale>=1e-6 || throw(ArgumentError(
        "CHAN2 thickness or opening is below 1e-6 of section size; supply explicit section properties"))
    key=(Float64(tw/scale),Float64(tb/scale),Float64(h/scale),Float64(b/scale))
    result=lock(_chan2_warping_cache_lock) do
        if !haskey(_chan2_warping_cache,key) && length(_chan2_warping_cache)>=1024
            delete!(_chan2_warping_cache,first(keys(_chan2_warping_cache)))
        end
        get!(_chan2_warping_cache,key) do
            previous=_chan2_section_warping_mesh(key...,2)
            for n in (4,8,16,32)
                current=_chan2_section_warping_mesh(key...,n)
                change=maximum(abs(getproperty(current,k)-getproperty(previous,k))/max(abs(getproperty(current,k)),eps(Float64))
                    for k in (:J,:N1,:K1,:K2))
                change<=1e-4 && return merge(current,(relative_change=change,))
                previous=current
            end
            throw(ArgumentError("CHAN2 section did not converge to a 0.01% successive-mesh tolerance; supply explicit section properties"))
        end
    end
    return merge(result,(J=result.J*scale^4,N1=result.N1*scale))
end
