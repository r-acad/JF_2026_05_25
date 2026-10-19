# Independent analytical values for the authored ACA01--ACA05 verification cases.
# SI units. No JFEM, fitted numerical result or stored reference-solver value is used.
# Sources and model limitations are recorded in each case_definition.json.

function slender_tip_displacement()
    force,length,E,width,height = .1,2.,70e9,.04,.01
    inertia=width*height^3/12
    force*length^3/(3E*inertia)
end

function short_tip_displacement()
    force,length,E,nu,width,height,kappa = 100.,1.,70e9,.3,.04,.2,5/6
    area=width*height;inertia=width*height^3/12;G=E/(2*(1+nu))
    force*length^3/(3E*inertia)+force*length/(kappa*G*area)
end

function cantilever_characteristic_root(mode)
    # Newton iteration on cos(beta)*cosh(beta)+1=0, initialized near each root.
    beta = mode==1 ? 1.9 : (mode-.5)*pi
    for _ in 1:20
        f=cos(beta)*cosh(beta)+1
        derivative=-sin(beta)*cosh(beta)+cos(beta)*sinh(beta)
        step=f/derivative;beta-=step
        abs(step)<4eps(beta) && break
    end
    beta
end

function slender_modal_eigenvalue(mode)
    E,rho,width,height,length = 70e9,2700.,.04,.01,2.
    area=width*height;inertia=width*height^3/12
    beta=cantilever_characteristic_root(mode)
    beta^4*E*inertia/(rho*area*length^4)
end

function cross_ply_stiffnesses()
    E1,E2,nu12,G12,t = 135e9,10e9,.3,5e9,.002
    denominator=1-nu12^2*E2/E1
    Q11,Q22,Q12,Q66=E1/denominator,E2/denominator,nu12*E2/denominator,G12
    D11=D22=D12=D66=0.
    for (k,angle) in enumerate((0,90,90,0))
        zminus=-t/2+(k-1)*t/4;zplus=zminus+t/4
        integration=(zplus^3-zminus^3)/3
        d11,d22=angle==0 ? (Q11,Q22) : (Q22,Q11)
        D11+=d11*integration;D22+=d22*integration
        D12+=Q12*integration;D66+=Q66*integration
    end
    D11,D22,D12,D66
end

function cross_ply_spectrum(kind)
    a,b,rho,t,Nx = .6,.4,1600.,.002,1000.
    D11,D22,D12,D66=cross_ply_stiffnesses()
    values=Float64[]
    for m in 1:14,n in 1:14
        alpha=m*pi/a;beta=n*pi/b
        H=D11*alpha^4+2*(D12+2D66)*alpha^2*beta^2+D22*beta^4
        push!(values,kind==:buckling ? H/(Nx*alpha^2) : H/(rho*t))
    end
    sort(values)
end

membrane_tip_displacement_110()=(1.10-1)*1.
membrane_lateral_contraction_110()=.4*(sqrt(1-.3*(1.10^2-1))-1)

for mode in 1:4
    name=Symbol("slender_modal_eigenvalue_",mode)
    @eval $name()=slender_modal_eigenvalue($mode)
end
for mode in 1:6
    bname=Symbol("cross_ply_buckling_factor_",mode)
    mname=Symbol("cross_ply_modal_eigenvalue_",mode)
    @eval $bname()=cross_ply_spectrum(:buckling)[$mode]
    @eval $mname()=cross_ply_spectrum(:modal)[$mode]
end
