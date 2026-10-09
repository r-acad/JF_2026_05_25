# Exact directional derivatives of the generated beam model. No property or
# displacement finite differences are used here. Directions are SI values per
# one selected UI variable unit (the caller applies, e.g., GPa -> Pa scaling).

"""PBARL section values and exact directional derivatives for T, BAR and ROD.

`dimensions` uses native PBARL order. `As_y/z` reproduces the current parser:
BAR/ROD Cowper factors are evaluated at its fixed nu=0.3, not the MAT1 nu.
`offset_y` follows WingFEGen's outside-face placement for T/BAR.
"""
function sensitivity_analytic_section(shape::AbstractString,dimensions,direction=zeros(length(dimensions)))
    dims=Float64.(dimensions);d=Float64.(direction)
    length(d)==length(dims)||throw(ArgumentError("Beam section direction has the wrong number of dimensions"))
    all(isfinite,dims)&&all(isfinite,d)||throw(ArgumentError("Beam section dimensions/directions must be finite"))
    shape=uppercase(shape)
    if shape=="T"
        length(dims)==4||throw(ArgumentError("T section needs four dimensions"))
        b,h,f,t=dims;db,dh,df,dt=d;q=h-f;dq=dh-df
        b>t>0&&h>f>0||throw(ArgumentError("Invalid T dimensions for analytic sensitivity"))
        af=b*f;aw=q*t;A=af+aw;dA=f*db+b*df+t*dq+q*dt
        Q=t*q^2/2+b*f*(h-f/2)
        dQ=q^2*dt/2+t*q*dq+f*(h-f/2)*db+b*(h-f)*df+b*f*dh
        yc=Q/A;dyc=(dQ-yc*dA)/A
        # Raw second moment minus A*centroid^2 avoids differentiating repeated
        # parallel-axis terms while remaining algebraically identical.
        I1=t*q^3/3+b*(h^3-q^3)/3-A*yc^2
        dI1=q^3*dt/3+t*q^2*dq+(h^3-q^3)*db/3+b*(h^2*dh-q^2*dq)-yc^2*dA-2A*yc*dyc
        I2=(q*t^3+f*b^3)/12;dI2=(t^3*dq+3q*t^2*dt+b^3*df+3f*b^2*db)/12
        J=(q*t^3+b*f^3)/3;dJ=(t^3*dq+3q*t^2*dt+f^3*db+3b*f^2*df)/3
        offset_y=yc-h;doffset_y=dyc-dh
        polygon=[[h-yc,-b/2],[h-yc,b/2],[q-yc,b/2],[q-yc,t/2],[-yc,t/2],[-yc,-t/2],[q-yc,-t/2],[q-yc,-b/2]]
        dpolygon=[[dh-dyc,-db/2],[dh-dyc,db/2],[dq-dyc,db/2],[dq-dyc,dt/2],[-dyc,dt/2],[-dyc,-dt/2],[dq-dyc,-dt/2],[dq-dyc,-db/2]]
        As_y=aw;As_z=af;dAs_y=t*dq+q*dt;dAs_z=f*db+b*df
    elseif shape=="BAR"
        length(dims)==2||throw(ArgumentError("BAR section needs two dimensions"))
        b,h=dims;db,dh=d;b>0&&h>0||throw(ArgumentError("BAR dimensions must be positive"))
        A=b*h;dA=h*db+b*dh
        I1=b*h^3/12;dI1=(h^3*db+3b*h^2*dh)/12
        I2=h*b^3/12;dI2=(b^3*dh+3h*b^2*db)/12
        # Native rectangular torsion approximation is nonsmooth at a square
        # for independent width/height changes. The app's square-cap variable
        # changes both together, so its derivative is unique.
        if b==h&&db!=dh
            throw(ArgumentError("Independent BAR dimensions at a square have no unique derivative in the current torsion approximation; vary the common square side"))
        end
        if b>=h
            J=(b*h^3-.63h^4)/3;dJ=(h^3*db+(3b*h^2-2.52h^3)*dh)/3
        else
            J=(h*b^3-.63b^4)/3;dJ=(b^3*dh+(3h*b^2-2.52b^3)*db)/3
        end
        offset_y=-h/2;doffset_y=-dh/2
        polygon=[[h/2,-b/2],[h/2,b/2],[-h/2,b/2],[-h/2,-b/2]]
        dpolygon=[[dh/2,-db/2],[dh/2,db/2],[-dh/2,db/2],[-dh/2,-db/2]]
        factor=10*1.3/(12+11*.3);As_y=As_z=factor*A;dAs_y=dAs_z=factor*dA
    elseif shape=="ROD"
        length(dims)==1||throw(ArgumentError("ROD section needs one radius"))
        r=only(dims);dr=only(d);r>0||throw(ArgumentError("ROD radius must be positive"))
        A=pi*r^2;dA=2pi*r*dr;I1=I2=pi*r^4/4;dI1=dI2=pi*r^3*dr
        J=pi*r^4/2;dJ=2pi*r^3*dr;offset_y=doffset_y=0.
        polygon=[[-r,0.],[0.,-r],[r,0.],[0.,r]];dpolygon=[[-dr,0.],[0.,-dr],[dr,0.],[0.,dr]]
        factor=6*1.3/(7+6*.3);As_y=As_z=factor*A;dAs_y=dAs_z=factor*dA
    else
        throw(ArgumentError("Analytic section derivatives support T, BAR and ROD, received $shape"))
    end
    return (;area=A,I1,I2,J,offset_y,polygon,As_y,As_z,darea=dA,dI1,dI2,dJ,doffset_y,dpolygon,dAs_y,dAs_z)
end

"""Resolve a generator section dictionary, including its fixed-area PBAR runout."""
function sensitivity_analytic_section(section::AbstractDict,direction=zeros(length(section["dimensions_m"])))
    if section["type"]=="PBAR"
        all(iszero,direction)||throw(ArgumentError("Fixed-area runout dimensions are not design variables"))
        polygon=deepcopy(section["polygon_yz_m"])
        return (area=Float64(section["area_m2"]),I1=Float64(section["I1_m4"]),I2=Float64(section["I2_m4"]),J=Float64(section["J_m4"]),
            offset_y=Float64(section["offset_y_m"]),polygon,As_y=Inf,As_z=Inf,darea=0.,dI1=0.,dI2=0.,dJ=0.,doffset_y=0.,
            dpolygon=[zeros(2) for _ in polygon],dAs_y=0.,dAs_z=0.)
    end
    return sensitivity_analytic_section(section["shape"],section["dimensions_m"],direction)
end

"""Directional Timoshenko stiffness, at fixed length and principal section axes."""
function sensitivity_analytic_frame_stiffness(L,section,E,G,dE,dG)
    L>1e-9||throw(ArgumentError("Degenerate beam length"))
    K=zeros(12,12);dK=zeros(12,12)
    function pair!(i,j,value,derivative)
        K[i,i]=K[j,j]=value;K[i,j]=K[j,i]=-value
        dK[i,i]=dK[j,j]=derivative;dK[i,j]=dK[j,i]=-derivative
    end
    pair!(1,7,E*section.area/L,(dE*section.area+E*section.darea)/L)
    pair!(4,10,G*section.J/L,(dG*section.J+G*section.dJ)/L)
    for (indices,sign,I,dI,As,dAs) in (((3,5,9,11),-1.,section.I2,section.dI2,section.As_z,section.dAs_z),
                                     ((2,6,8,12),1.,section.I1,section.dI1,section.As_y,section.dAs_y))
        B=E*I;dB=dE*I+E*dI
        if isinf(As)
            phi=dphi=0.
        else
            G>0&&As>0||throw(ArgumentError("Beam shear rigidity must be positive"))
            phi=12B/(G*As*L^2);dphi=12/(G*As*L^2)*(dB-B*(dG/G+dAs/As))
        end
        den=1+phi;c=B/den;dc=(dB-c*dphi)/den
        a=12c/L^3;da=12dc/L^3;b=6c/L^2;db=6dc/L^2
        c4=(4+phi)*c/L;dc4=((4+phi)*dc+c*dphi)/L
        c2=(2-phi)*c/L;dc2=((2-phi)*dc-c*dphi)/L
        block=[a sign*b -a sign*b;sign*b c4 -sign*b c2;-a -sign*b a -sign*b;sign*b c2 -sign*b c4]
        derivative=[da sign*db -da sign*db;sign*db dc4 -sign*db dc2;-da -sign*db da -sign*db;sign*db dc2 -sign*db dc4]
        for i in 1:4,j in 1:4;K[indices[i],indices[j]]=block[i,j];dK[indices[i],indices[j]]=derivative[i,j];end
    end
    return (;K,dK)
end

_analytic_bar_direction(d,key,default)=d isa AbstractDict ? get(d,key,get(d,Symbol(key),default)) : get(d,Symbol(key),default)

"""Exact generated-CBAR tangent, in native analysis coordinates.

`direction` fields `dimensions`, `E`, `nu`, `rho` are directional derivatives,
not baseline values. `state` is the expanded full analysis-coordinate vector.
Matrices are element-local in the returned `dofs` ordering. No constraint map
has been applied; the caller uses its fixed native constraint transformation.
"""
function sensitivity_analytic_bar(native,op,wing,g,e,direction,state=nothing)
    g.kind===:bar||throw(ArgumentError("Analytic beam helper requires a bar element"))
    eid=g.eids[e];section=section_definition(wing.params,g.pid)
    dims=_analytic_bar_direction(direction,"dimensions",zeros(length(section["dimensions_m"])))
    sd=sensitivity_analytic_section(section,dims)
    # Imported offsets are fixed source-card data, independent of dimensions.
    is_imported_model(wing)&&(sd=merge(sd,(offset_y=0.,doffset_y=0.)))
    bd=native.Solver._get_beam_element_data(eid,op.model,op.id_map,op.X,op.node_R)
    bd===nothing&&error("Native CBAR $eid was not found")
    bar=bd.beam;prop=bd.prop
    (get(bar,"PA",0)==0&&get(bar,"PB",0)==0&&get(prop,"I12",0.)==0&&get(prop,"NSM",0.)==0)||
        error("Generated analytic CBAR derivatives require unreleased principal sections and zero NSM")
    haskey(prop,"STATIONS")&&error("Variable-station beam properties are outside the generated CBAR analytic scope")
    norm(bd.fixed_end_load)==0||error("Beam distributed fixed-end loads require a separate analytic load derivative")
    wa=Float64.(get(bar,"WA",zeros(3)));wb=Float64.(get(bar,"WB",zeros(3)))
    norm(wa-wb)<=1e-13max(norm(wa),1.)||error("Unequal beam offsets require geometry derivatives")
    E=Float64(bd.mat["E"]);nu=Float64(bd.mat["NU"]);G=Float64(bd.mat["G"]);rho=Float64(get(bd.mat,"RHO",0.))
    isapprox(G,E/(2(1+nu));rtol=1e-12)||error("Generated MAT1 analytic derivatives require G=E/(2(1+nu))")
    dE=Float64(_analytic_bar_direction(direction,"E",0.));dnu=Float64(_analytic_bar_direction(direction,"nu",0.));drho=Float64(_analytic_bar_direction(direction,"rho",0.))
    dG=dE/(2(1+nu))-E*dnu/(2(1+nu)^2)
    kernel=sensitivity_analytic_frame_stiffness(bd.L,sd,E,G,dE,dG)
    replay=norm(kernel.K-bd.Ke_loc)/max(norm(bd.Ke_loc),eps())
    replay<1e-10||error("Analytic CBAR $eid primitive replay differs from native stiffness ($replay)")
    T=bd.T12;dT=zeros(12,12)
    ia=op.id_map[bar["GA"]];ib=op.id_map[bar["GB"]]
    R=T[1:3,1:3]*transpose(op.node_R[ia])
    doffset=sd.doffset_y.*vec(R[2,:]);offset=sd.offset_y.*vec(R[2,:])
    is_imported_model(wing)||norm(wa-offset)<=1e-10max(norm(offset),1.)||error("Analytic CBAR $eid offset does not match its generated section placement")
    dT[1:3,4:6]=-R*native.Solver.skew3(doffset)*op.node_R[ia]
    dT[7:9,10:12]=-R*native.Solver.skew3(doffset)*op.node_R[ib]
    Ke=transpose(T)*kernel.K*T
    dKe=transpose(T)*kernel.dK*T+transpose(dT)*kernel.K*T+transpose(T)*kernel.K*dT
    # Current native CBAR mass is translationally lumped on the GRID line,
    # independently of shell consistent-mass options. WA/WB do not enter it.
    mass=rho*sd.area*bd.L;dmass=bd.L*(drho*sd.area+rho*sd.darea)
    Me=zeros(12,12);dMe=zeros(12,12);wtmass=Float64(get(op.model,"PARAM_WTMASS",1.))
    for i in (1,2,3,7,8,9);Me[i,i]=wtmass*mass/2;dMe[i,i]=wtmass*dmass/2;end
    u=state===nothing ? zeros(12) : Float64.(state[bd.dofs])
    ul=T*u;dul=dT*u;forces=kernel.K*ul;dforces=kernel.dK*ul+kernel.K*dul
    axial=forces[7]/sd.area;daxial=(dforces[7]-axial*sd.darea)/sd.area
    force_gradient=kernel.K*T
    axial_gradient=vec(force_gradient[7,:])./sd.area
    feature_rows=Vector{Float64}[];stress_features=Float64[];dstress_features=Float64[]
    for (moment1,moment2) in ((-forces[6],forces[5]),(forces[12],-forces[11]))
        ending=isempty(stress_features) ? 1 : 2
        dm1,dm2=ending==1 ? (-dforces[6],dforces[5]) : (dforces[12],-dforces[11])
        for (point,dpoint) in zip(sd.polygon,sd.dpolygon)
            y,z=point;dy,dz=dpoint
            stress=axial-moment1*y/sd.I1-moment2*z/sd.I2
            dstress=daxial-(dm1*y+moment1*dy)/sd.I1+moment1*y*sd.dI1/sd.I1^2-
                (dm2*z+moment2*dz)/sd.I2+moment2*z*sd.dI2/sd.I2^2
            coeff=zeros(12);coeff[7]=1/sd.area
            if ending==1;coeff[6]=y/sd.I1;coeff[5]=-z/sd.I2
            else;coeff[12]=-y/sd.I1;coeff[11]=z/sd.I2;end
            push!(feature_rows,vec(transpose(coeff)*force_gradient));push!(stress_features,stress);push!(dstress_features,dstress)
        end
    end
    stress_gradient=reduce(vcat,transpose.(feature_rows))
    kgunit=native.Solver.FEM.geometric_stiffness_frame3d(Float64(bd.L),1.)
    P=forces[7];dP=dforces[7];Kg=P.*(transpose(T)*kgunit*T)
    dKg=dP.*(transpose(T)*kgunit*T)+P.*(transpose(dT)*kgunit*T+transpose(T)*kgunit*dT)
    return (;eid,dofs=bd.dofs,section=sd,Ke,dKe,Me,dMe,Kg,dKg,mass,dmass,offset,doffset,
        axial_stress=axial,daxial_stress=daxial,axial_gradient,forces,dforces,force_gradient,
        stress_features,dstress_features,stress_gradient,axial_force_gradient=vec(force_gradient[7,:]),
        kg_unit=transpose(T)*kgunit*T,stiffness_replay_relative_error=replay)
end

"""Local beam contribution to d(φ'Kgφ)/du, using the true offset frame."""
function sensitivity_analytic_bar_preload_gradient(bar,phi)
    pe=phi[bar.dofs]
    return dot(pe,bar.kg_unit*pe).*bar.axial_force_gradient
end
