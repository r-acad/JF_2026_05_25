using Test

module PcompLegacyAxisFixture
using Test, LinearAlgebra, OpenJFEM
const FD=OpenJFEM.ForwardDiff

function stack(angles,thicknesses;isotropic=false,offset=0.)
    h=sum(thicknesses);z=-h/2+offset;plies=Any[]
    E1,E2,nu,G=isotropic ? (63e9,63e9,.24,63e9/2.48) : (119e9,9.3e9,.26,4.2e9)
    g1,g2=isotropic ? (G,G) : (4.7e9,2.6e9)
    for (a,t) in zip(angles,thicknesses)
        theta=deg2rad(a)
        push!(plies,Dict("Qbar"=>OpenJFEM.laminate_plane_stress_qbar(E1,E2,nu,G,theta),
            "Qshear"=>OpenJFEM.laminate_transverse_shear_qbar(g1,g2,theta),
            "z_bot"=>z,"z_top"=>z+t))
        z+=t
    end
    plies,h
end

function checks()
    for phi in (0.,19.3,77.1)
        p,h=stack([phi],[.0017])
        C=OpenJFEM.pcomp_legacy_axis_shear(p,h)
        @test isapprox(C,(5/6)*h*p[1]["Qshear"];rtol=8e-15)
        a=OpenJFEM._laminate_stiffest_axis(h*p[1]["Qbar"])
        @test abs(sin(a-deg2rad(phi)))<2e-14
    end
    angles=[11.,-29.,64.,23.];ts=[.0009,.0013,.0007,.0016]
    p,h=stack(angles,ts);C=OpenJFEM.pcomp_legacy_axis_shear(p,h)
    @test C==transpose(C)
    @test isposdef(Symmetric(C))
    A=sum((q["z_top"]-q["z_bot"])*q["Qbar"] for q in p)
    a=OpenJFEM._laminate_stiffest_axis(A)
    work(t)=begin v=[cos(t)^2,sin(t)^2,2sin(t)*cos(t)];dot(v,A*v) end
    @test work(a)>=maximum(work(t) for t in range(0,pi;length=361))*(1-2e-15)
    c,s=cos(a),sin(a);Te=[c*c s*s -c*s;s*s c*c c*s;2c*s -2c*s c*c-s*s]
    @test abs((Te'*A*Te)[1,3])<2e-14norm(A)
    for phi in (7.123,31.,91.456,-83.5)
        pr,hr=stack(angles.+phi,ts);v=deg2rad(phi);R=[cos(v) -sin(v);sin(v) cos(v)]
        @test isapprox(OpenJFEM.pcomp_legacy_axis_shear(pr,hr),R*C*R';rtol=3e-13)
    end
    reversed=[merge(q,Dict("z_bot"=>-q["z_top"],"z_top"=>-q["z_bot"])) for q in reverse(p)]
    @test isapprox(OpenJFEM.pcomp_legacy_axis_shear(reversed,h),C;rtol=2e-14)
    split,hs=stack(repeat(angles;inner=2),repeat(ts./2;inner=2))
    @test isapprox(OpenJFEM.pcomp_legacy_axis_shear(split,hs),C;rtol=2e-14)
    shifted,_=stack(angles,ts;offset=7h)
    @test isapprox(OpenJFEM.pcomp_legacy_axis_shear(shifted,h),C;rtol=4e-14)
    scaled,hscale=stack(angles,3.7ts)
    @test isapprox(OpenJFEM.pcomp_legacy_axis_shear(scaled,hscale),3.7C;rtol=2e-14)
    @test OpenJFEM.pcomp_shear_for_convention(p,h,"legacy_stiffest_axis")==C
    @test OpenJFEM.pcomp_shear_for_convention(p,h,"material_frame")==OpenJFEM.pcomp_energy_shear(p,h)
    @test_throws ArgumentError OpenJFEM.pcomp_shear_for_convention(p,h,"unknown")

    # Isotropy is a material-frame tie, not permission to invent a smooth
    # derivative for a perturbation that creates a unique anisotropic axis.
    balanced=[0.,45.,-45.,90.,90.,-45.,45.,0.]
    q,hq=stack(balanced,fill(.0004,8))
    Aq=sum((v["z_top"]-v["z_bot"])*v["Qbar"] for v in q)
    @test OpenJFEM._laminate_isotropic_membrane(Aq)
    @test OpenJFEM._laminate_stiffest_axis(Aq)==0.
    @test OpenJFEM.pcomp_legacy_axis_shear(q,hq)==OpenJFEM.pcomp_energy_shear(q,hq)
    d=FD.Dual(0.,1.)
    function directional_law(x)
        pd,hd=stack(angles.+x.*[3.,-2.,1.,.5],ts.+x.*[.1ts[1],0.,0.,0.])
        OpenJFEM.pcomp_legacy_axis_shear(pd,hd)
    end
    step=1e-5
    tangent=first.(FD.partials.(directional_law(d)))
    central=(directional_law(step)-directional_law(-step))/(2step)
    @test isapprox(tangent,central;rtol=5e-8)
    weights=[1. .3;.3 -.2]
    scalar_law(x)=sum(weights.*directional_law(x))
    second=FD.derivative(x->FD.derivative(scalar_law,x),0.)
    delta=.002
    second_central=(-scalar_law(2delta)+16scalar_law(delta)-30scalar_law(0.)+
        16scalar_law(-delta)-scalar_law(-2delta))/(12delta^2)
    @test isapprox(second,second_central;rtol=3e-6)
    # An aligned primal maximum can still have a nonzero orientation tangent.
    # ForwardDiff's primal-only iszero is insufficient for that shortcut.
    @test iszero(FD.Dual(0.,1.))
    aligned_angles=[-25.,25.,0.];aligned_t=[.001,.001,.0017]
    aligned(x)=begin ps,ht=stack(aligned_angles.+x,aligned_t);OpenJFEM.pcomp_legacy_axis_shear(ps,ht) end
    C0=aligned(0.);generator=[0. -1.;1. 0.]
    exact_rotation_tangent=(pi/180)*(generator*C0-C0*generator)
    @test isapprox(first.(FD.partials.(aligned(d))),exact_rotation_tangent;rtol=3e-13)
    tied=[10. 2. 0.;2. 8. 0.;0. 0. 6.]
    @test_throws ArgumentError OpenJFEM._laminate_stiffest_axis(tied;check_unique=true)
    qd,hqd=stack(balanced,fill(.0004,8).+d.*[.0004,0.,0.,0.,0.,0.,0.,0.])
    @test_throws ArgumentError OpenJFEM.pcomp_legacy_axis_shear(qd,hqd)
    qi,hi=stack([27.],[(1+d)*.0017];isotropic=true)
    Ci=OpenJFEM.pcomp_legacy_axis_shear(qi,hi)
    @test isapprox(first.(FD.partials.(Ci)),(5/6)*.0017*qi[1]["Qshear"];rtol=8e-15)

    # Build and sensitivity reconstruction share explicit convention
    # provenance. Older serialized properties retain their material frame.
    mktempdir() do dir
        path=joinpath(dir,"section.bdf")
        write(path,"""
SOL 101
CEND
BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,0.,1.,0.
CTRIA3,1,10,1,2,3
MAT8,1,1.19E11,9.3E9,.26,4.2E9,4.7E9,2.6E9,1600.
PCOMP,10
+,1,.0009,11.,YES,1,.0013,-29.,YES
+,1,.0007,64.,YES,1,.0016,23.,YES
ENDDATA
""")
        model=OpenJFEM.bdf_to_model(path);prop=model["PSHELLs"]["10"]
        @test prop["PCOMP_SHEAR_CONVENTION"]=="legacy_stiffest_axis"
        @test isapprox(prop["Cs"],C;rtol=2e-14)
        @test prop["Cs_ref"]==prop["Cs"]
    end
end
end

@testset "Legacy laminate shear axis and explicit differentiation scope" begin
    PcompLegacyAxisFixture.checks()
end
