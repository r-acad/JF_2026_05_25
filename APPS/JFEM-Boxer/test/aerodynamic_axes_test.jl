using Test,WingFEGen,LinearAlgebra
const W=WingFEGen
@testset "Quaderno 1: construction, body, A, W-prime and fixed S" begin
    s=W.aerodynamic_settings(Dict{String,Any}("alpha"=>13.,"beta"=>17.,"stability_alpha"=>7.),Any[])
    a,b,a0=deg2rad.([13.,17.,7.]);T=W.aerodynamic_frame_matrices(s)
    # Independently construct the physical basis vectors from book definitions.
    expected=Dict("body"=>[[-1.,0.,0.],[0.,1.,0.],[0.,0.,-1.]],
      "aerodynamic"=>[[-cos(a),0.,-sin(a)],[0.,1.,0.],[sin(a),0.,-cos(a)]],
      "wind"=>[[-cos(a)*cos(b),sin(b),-sin(a)*cos(b)],[cos(a)*sin(b),cos(b),sin(a)*sin(b)],[sin(a),0.,-cos(a)]],
      "stability"=>[[-cos(a0),0.,-sin(a0)],[0.,1.,0.],[sin(a0),0.,-cos(a0)]])
    F=[2.,-3.,11.];M=[17.,23.,31.];qS=43.;span=8.;mac=1.7
    C=W.aerodynamic_coefficients(F,M,s,qS,span,mac)
    for name in keys(expected)
        basis=expected[name]
        @test T[name]*T[name]' ≈ Matrix{Float64}(I,3,3)
        @test det(T[name]) ≈ 1
        @test T[name]*F ≈ [dot(v,F) for v in basis]
        @test C[name]["force_components"] ≈ [dot(v,F)/qS for v in basis]
        @test C[name]["moment"] ≈ [dot(v,M) for v in basis]./(qS.*[span,mac,span])
        @test T[name]*cross(F,M) ≈ cross(T[name]*F,T[name]*M)
        @test T[name]'*C[name]["force_N"] ≈ F
    end
    @test C["wind"]["force"] ≈ [-C["wind"]["force_components"][1],C["wind"]["force_components"][2],-C["wind"]["force_components"][3]]
    @test C["body"]["force"]==[-2.,-3.,-11.]./qS
    moved=W.aerodynamic_frame_matrices(merge(s,Dict("alpha"=>21.,"beta"=>-4.)))
    @test moved["stability"]==T["stability"]
    @test moved["aerodynamic"]!=T["aerodynamic"]
    # Relative wind is -V: positive beta arrives from the pilot's right.
    wind=W.VortexLattice.freestream_velocity(W.VortexLattice.Freestream(1.,a,b,[0.,0.,0.]))
    @test collect(wind) ≈ -expected["wind"][1]
    @test wind[2]<0
    # Rate convention in C is Omega_C=(-p,q,-r); relative flow is r x Omega_C.
    fs=W.VortexLattice.Freestream(1.,0.,0.,[.2,.3,.4]);point=[2.,3.,5.]
    @test W.VortexLattice.rotational_velocity(point,fs,W.VortexLattice.Reference(1.,1.,1.,[0.,0.,0.],1.)) ≈ cross(point,[-.2,.3,-.4])
end

@testset "European rudder command on mirrored winglet fins" begin
    p=W.default_params();merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012"))
    p["loft.vertical_shift_stations"]=[Dict("eta"=>e,"shift_percent"=>z) for (e,z) in ((0.,0.),(.8,0.),(1.,45.))]
    p["movable_surfaces.items"]=[Dict{String,Any}("name"=>"Fin rudder","kind"=>"rudder","edge"=>"trailing","eta_start"=>.8,"eta_end"=>1.,"hinge_start"=>.7,"hinge_end"=>.7,"deflection"=>0.,"color"=>"#ffcc00")]
    _,w,controls=W.aerodynamic_geometry(p)
    base=Dict{String,Any}("chord_panels"=>2,"span_panels"=>3,"control_chord_panels"=>1,"alpha"=>0.,"beta"=>0.,"speed"=>30.,"compressibility"=>"incompressible","derivatives"=>true,"controls"=>Dict("Fin rudder"=>Dict("source"=>"override","enabled"=>true,"pairing"=>"symmetric","right"=>5.,"left"=>5.)))
    c=only(W.run_aerodynamic_study(p,base)["cases"])
    @test c["coefficients"]["body"]["force"][2]>0
    @test c["coefficients"]["body"]["moment"][3]<0
    d=only(filter(d->d["variable"]=="control:Fin rudder",c["derivatives"]["rows"]))
    @test d["coefficients"]["body"]["force"][2]>0
    @test d["coefficients"]["body"]["moment"][3]<0
    s=W.aerodynamic_settings(base,controls);patches=W.aerodynamic_mesh(w,controls,s)
    for side in ("left","right")
        patch=only(filter(p->p.side==side&&!isempty(p.active),patches));e=sum(patch.etas)/length(patch.etas);zero=W.camber_point(w,e,1.)
        # The physical trailing-edge displacement is left on BOTH fins.
        angle=W.aerodynamic_command_angle(w,only(controls),side,5.)
        moved=W.aerodynamic_control_point(w,only(controls),e,1.,zero,angle)
        @test (side=="right" ? 1 : -1)*(moved[2]-zero[2])<0
    end
end
