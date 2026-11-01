using Test, WingFEGen, LinearAlgebra
const NC=WingFEGen

@testset "Neutral offset hinges retain a continuous physical wing" begin
    p=NC.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>.6,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "loft.twist_stations"=>[Dict("eta"=>0.,"twist"=>3.),Dict("eta"=>1.,"twist"=>0.)],
        "airfoil.root"=>"NACA2412","airfoil.tip"=>"NACA2412"))
    control=Dict{String,Any}("name"=>"Offset flap","kind"=>"flap","edge"=>"trailing","eta_start"=>.2,"eta_end"=>.8,
        "front_spar_start"=>.7,"front_spar_end"=>.7,"hinge_start"=>.8,"hinge_end"=>.8,
        "hinge_z_start"=>-.5,"hinge_z_end"=>-.5,"deflection"=>0.,"color"=>"#ffcc00")
    p["movable_surfaces.items"]=[control]
    _,w,rows=NC.aerodynamic_geometry(p)
    s=NC.aerodynamic_settings(Dict{String,Any}("chord_panels"=>3,"span_panels"=>6,"control_chord_panels"=>1,
        "chord_spacing"=>"uniform","span_spacing"=>"uniform","speed"=>30.,"derivatives"=>false),rows)
    mesh=NC.aerodynamic_mesh(w,rows,s)
    @test NC.aerodynamic_control_gap(w,only(rows))
    @test all(q.element_name=="fixed wing" for q in mesh)
    @test NC.aerodynamic_body_interference(mesh)["valid"]
    base=NC.aerodynamic_solve(w,mesh,s)
    @test isfinite(base["span_efficiency"])
    @test base["residual_over_V"]<1e-8
    blocked=NC.aerodynamic_derivatives(w,rows,mesh,s,base)
    @test any(r["variable"]=="control:Offset flap" for r in blocked["unavailable"])

    # End material clearances remain genuine holes at neutral motion.
    gapped=deepcopy(p);gapped["movable_surfaces.items"][1]["clearance_inboard_m"]=.02
    _,gw,gr=NC.aerodynamic_geometry(gapped);gm=NC.aerodynamic_mesh(gw,gr,s)
    @test NC.aerodynamic_body_interference(gm)["valid"]
    @test any(q.element_name=="fixed wing"&&first(q.etas)>=.2&&last(q.etas)<=.2+.02/gw.semispan&&maximum(q.chord_coordinates)<=.7+1e-12 for q in gm if q.side=="right")
    @test sum(m.area for q in gm for m in q.metrics)<sum(m.area for q in mesh for m in q.metrics)

    # The derivative rebuilds each real detached perturbation, so no fixed
    # panel is stretched from its neutral location to the offset moving edge.
    derivative_p=deepcopy(p);derivative_p["loft.twist_stations"]=Any[];derivative_p["planform.taper_ratio"]=1.
    derivative_p["movable_surfaces.items"][1]["eta_start"]=0.
    derivative_p["movable_surfaces.items"][1]["eta_end"]=1.
    _,dw,dr=NC.aerodynamic_geometry(derivative_p);dm=NC.aerodynamic_mesh(dw,dr,s);db=NC.aerodynamic_solve(dw,dm,s)
    d=NC.aerodynamic_derivatives(dw,dr,dm,s,db)
    @test d["remeshed_control_stencils"]==["control:Offset flap"]
    @test isempty(d["unavailable"])
    deriv=only(filter(r->r["variable"]=="control:Offset flap",d["rows"]))
    samples=Any[]
    for angle in (-rad2deg(.001),rad2deg(.001))
        t=deepcopy(s);t["controls"]["Offset flap"]["left"]=t["controls"]["Offset flap"]["right"]=angle
        moved=NC.aerodynamic_mesh(dw,dr,t)
        @test any(q.element_name=="control: Offset flap" for q in moved)
        push!(samples,NC.aerodynamic_solve(dw,moved,t))
    end
    @test deriv["coefficients"]["wind"]["force"][3]≈(samples[2]["coefficients"]["wind"]["force"][3]-samples[1]["coefficients"]["wind"]["force"][3])/.002

    # Exact loaded/API commands can place either stencil endpoint at neutral,
    # even though the base control is detached. That sample must rejoin the
    # wing, with no artificial internal trailing-edge wake left behind.
    step=1e-3*(180/pi)
    for center in (-step,step)
        t=deepcopy(s);command=t["controls"]["Offset flap"]
        merge!(command,Dict("source"=>"override","pairing"=>"symmetric","left"=>center,"right"=>center))
        moved=NC.aerodynamic_mesh(dw,dr,t);base_moved=NC.aerodynamic_solve(dw,moved,t)
        derivative=NC.aerodynamic_derivatives(dw,dr,moved,t,base_moved)
        @test derivative["remeshed_control_stencils"]==["control:Offset flap"]
        @test isempty(derivative["unavailable"])
        actual=only(filter(r->r["variable"]=="control:Offset flap",derivative["rows"]))
        expected=Any[]
        for angle in (center-step,center+step)
            sample=deepcopy(t);sample["controls"]["Offset flap"]["left"]=sample["controls"]["Offset flap"]["right"]=angle
            sample_mesh=NC.aerodynamic_mesh(dw,dr,sample)
            if iszero(angle);@test all(q.element_name=="fixed wing" for q in sample_mesh);end
            push!(expected,NC.aerodynamic_solve(dw,sample_mesh,sample))
        end
        @test actual["coefficients"]["wind"]["force"]≈(expected[2]["coefficients"]["wind"]["force"]-expected[1]["coefficients"]["wind"]["force"])/.002
    end
end
