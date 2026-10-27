# Thickness integration for an ordinary convex planar quadrilateral.
# The section's kinematic enrichment remains independent of thickness; its
# physical energy, residual compliance, drilling work and inertia use Ti.

function quad4_variable_thickness_packet(coords,Cm,Cb,Cs,h,E_ref,thickness;
        k6rot=100.0,drill_scale=1.0,bend_ratio=1.0,rigid_shear=false)
    length(thickness)==4 && all(t->isfinite(t)&&t>0,thickness) ||
        throw(ArgumentError("CQUAD4 corner thickness requires four positive finite values"))
    isfinite(h)&&h>0 || throw(ArgumentError("A positive section reference thickness is required"))
    # This packet shares the ordinary planar MacNeal kinematic map. Director,
    # MID4, nonlinear, warped and alternate-plate dispatches are outside its scope.
    scalar_type=foldl(promote_type,(typeof(v) for a in (Cm,Cb,Cs,thickness) for v in a);
        init=promote_type(eltype(coords),typeof(h)))
    ws=create_quad4_workspace(scalar_type);mw=create_macneal_shear_workspace(scalar_type)
    capture=Any[]
    K=copy(stiffness_quad4_matrices(coords,Cm,Cb,Cs,h,E_ref;
        k6rot=k6rot,drill_scale=drill_scale,bend_ratio=bend_ratio,
        ws=ws,msws=mw,bending_incomp=true,membrane_incomp=true,
        kernel_planar=true,kernel_mode="macneal",macneal_rigid_shear=rigid_shear,
        field_capture=capture))
    ws.section_kinematic[] || throw(ArgumentError("Variable corner thickness requires the ordinary kinematic enrichment"))
    length(capture)==4 || throw(ArgumentError("Variable corner thickness requires the ordinary four-point section field"))
    pm=copy(ws.enrichment_membrane);pb=copy(ws.enrichment_bending)
    p=inv(sqrt(3.0));gps=((-p,-p),(p,-p),(p,p),(-p,p))
    area=sum(f.weight for f in capture);fields=Any[]
    Hshear=zeros(scalar_type,4,4);inverse_cube=zero(scalar_type)
    mean_t=zero(scalar_type);mean_cube=zero(scalar_type)
    for (f,(r,s)) in zip(capture,gps)
        N=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]./4
        t=sum(N.*thickness);ratio=t/h
        Bm=f.Bm+f.Bi*pm;Bb=f.Bb+f.Bi_bend*pb
        A=f.A*ratio;D=f.D*ratio^3
        K .+= f.weight.*(Bm'*(A-f.A)*Bm+Bb'*(D-f.D)*Bb)
        shear_shape=[one(scalar_type) s 0 0;0 0 1 r]
        Hshear .+= f.weight.*(shear_shape'*(Cs*ratio)*shear_shape)
        inverse_cube+=f.weight/ratio^3;mean_t+=f.weight*t;mean_cube+=f.weight*t^3
        push!(fields,(shape=N,t=t,A=A,D=D,Bm=Bm,Bb=Bb,
            compatible_Bm=f.Bm,compatible_Bb=f.Bb,weight=f.weight))
    end
    # Physical shear coefficients and bending-residual flexibility are work
    # conjugate. The material kinematic map stays fixed while section thickness
    # weights physical energy and compliance at the same quadrature points.
    transfer=copy(mw.Gcan);Zb=copy(mw.Zb)*(inverse_cube/area)
    Zs=rigid_shear ? zeros(scalar_type,4,4) : transfer*(Hshear\transfer')
    Kplate=mw.D_mat'*((Zb+Zs)\mw.D_mat)
    plate=[6(i-1)+j for i in 1:4 for j in 3:5]
    K[plate,plate].+=Kplate-mw.K_plate
    Ks=zeros(scalar_type,24,24);Ks[plate,plate].=Kplate
    # Corner drilling work has its own corner section weight. Do not use the
    # section mean: it would change the shared-GRID drilling equilibrium.
    dc1,dc2=shape_derivs_quad(0.,0.);detc=abs(det([dc1';dc2']*coords))
    for (i,(r,s)) in enumerate(((-1.,-1.),(1.,-1.),(1.,1.),(-1.,1.)))
        dr,ds=shape_derivs_quad(r,s);J=[dr';ds']*coords;d=J\[dr';ds']
        Bd=zeros(scalar_type,24)
        for a in 1:4;Bd[6a-5]=d[2,a]/2;Bd[6a-4]=-d[1,a]/2;end
        Bd[6i]=1
        alpha=drill_scale*k6rot*1e-6*Cm[3,3]*(4detc)*abs(det(J))/detc
        K .+= alpha*(thickness[i]/h-1).*(Bd*Bd')
    end
    return (K=K,Kshear=Ks,fields=fields,membrane_map=pm,bending_map=pb,
        area=area,mean_thickness=mean_t/area,mean_cube=mean_cube/area,
        reported_thickness=sum(thickness)/4,reported_cube=sum(f.t^3 for f in fields)/4,
        coords=copy(coords),reference_thickness=h,Cm=copy(Cm),Cb=copy(Cb))
end

function quad4_variable_thickness_mass(packet,rho;nsm=0.0,rotary=false)
    T=promote_type(eltype(packet.K),typeof(rho),typeof(nsm));M=zeros(T,24,24)
    for f in packet.fields
        m=(rho*f.t+nsm)*f.weight*(f.shape*f.shape')
        for a in 1:4,b in 1:4,j in 1:3;M[6a-6+j,6b-6+j]+=m[a,b];end
        if rotary
            mr=rho*f.t^3/12*f.weight*(f.shape*f.shape')
            for a in 1:4,b in 1:4,j in 4:5;M[6a-6+j,6b-6+j]+=mr[a,b];end
        end
    end
    M
end

function quad4_variable_thickness_mass(coords,thickness,rho;nsm=0.0,rotary=false)
    T=promote_type(eltype(coords),eltype(thickness),typeof(rho),typeof(nsm))
    fields=Any[];p=inv(sqrt(3.))
    for (r,s) in ((-p,-p),(p,-p),(p,p),(-p,p))
        N=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]./4
        dr,ds=shape_derivs_quad(r,s);weight=abs(det([dr';ds']*coords))
        push!(fields,(shape=N,t=sum(N.*thickness),weight=weight))
    end
    return quad4_variable_thickness_mass((K=zeros(T,0,0),fields=fields),rho;nsm=nsm,rotary=rotary)
end

function quad4_variable_thickness_geometric(coords,u,Cm,h,thickness)
    N,_,_=quad4_differential_membrane_force_field(coords,u,Cm,nothing)
    p=inv(sqrt(3.));gps=((-p,-p),(p,-p),(p,p),(-p,p))
    for (i,(r,s)) in enumerate(gps)
        shape=[(1-r)*(1-s),(1+r)*(1-s),(1+r)*(1+s),(1-r)*(1+s)]./4
        N[i,:].*=sum(shape.*thickness)/h
    end
    K=geometric_stiffness_quad4(coords,N/h,h;trans_mode=:principal_transverse)
    add_quad4_assumed_transverse_gradient_delta!(K,coords,N/h,h)
    return K,N
end

function quad4_variable_thickness_fields(packet,u)
    hasproperty(packet,:warp_map) && (u=packet.warp_map*u)
    N=reduce(vcat,[(f.A*(f.Bm*u))' for f in packet.fields])
    M=reduce(vcat,[(f.D*(f.Bb*u))' for f in packet.fields])
    eps=reduce(vcat,[(f.Bm*u)' for f in packet.fields])
    kappa=reduce(vcat,[(f.Bb*u)' for f in packet.fields])
    force=packet.Kshear*u
    Q=[sum(force[5:6:end]),-sum(force[4:6:end])]/packet.area
    dr,ds=shape_derivs_quad(0.,0.);d=([dr';ds']*packet.coords)\[dr';ds']
    ec=[sum(d[1,i]*u[6i-5] for i=1:4),sum(d[2,i]*u[6i-4] for i=1:4),
        sum(d[2,i]*u[6i-5]+d[1,i]*u[6i-4] for i=1:4)]
    kc=[sum(d[1,i]*u[6i-1] for i=1:4),-sum(d[2,i]*u[6i-2] for i=1:4),
        sum(d[2,i]*u[6i-1]-d[1,i]*u[6i-2] for i=1:4)]
    # Centroid reporting averages the section law in the reference square.
    # Bilinear t has center value mean(Ti); its cubic bending law has the
    # exact reference-square mean given by the unweighted 2x2 Gauss rule.
    # Physical energy, inertia and GP resultants retain their Jacobian weights.
    Nc=(packet.Cm*(packet.reported_thickness/packet.reference_thickness))*ec
    Mc=(packet.Cb*(packet.reported_cube/packet.reference_thickness^3))*kc
    (N=N,M=M,eps=eps,kappa=kappa,Q_mean=Q,N_reported=Nc,M_reported=Mc,
        eps_center=ec,kappa_center=kc,reported_thickness=packet.reported_thickness)
end

function quad4_variable_thickness_prestress(packet,u)
    dr,ds=shape_derivs_quad(0.,0.);d=([dr';ds']*packet.coords)\[dr';ds']
    gamma=sum(d[2,i]*u[6i-5]+d[1,i]*u[6i-4] for i=1:4)
    reduce(vcat,[begin
        eps=f.compatible_Bm*u;eps[3]=gamma;(f.A*eps)'
    end for f in packet.fields])
end
