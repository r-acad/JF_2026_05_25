using Test, JSON, MsgPack, WingFEGen
const W=WingFEGen
out=isempty(ARGS) ? nothing : abspath(ARGS[1])
out===nothing||mkpath(out)

function aero_plot_params()
    merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>16.,"planform.aspect_ratio"=>8.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012","box.end_eta"=>1.,
        "box.rib_pitch"=>2.,"box.stringer_pitch"=>.3,"mesh.elements_between_ribs"=>1,
        "mesh.elements_between_stringers"=>1,"mesh.elements_spar_height"=>1,
        "airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "aero.span_panels"=>16,"aero.chord_panels"=>4,"aero.alpha"=>2.,
        "aero.atmosphere"=>"manual","aero.speed"=>120.,"aero.speed_of_sound"=>1e12,"loads.method"=>"vortex_lattice",
        "loads.load_factor"=>1.,"loads.torque_y"=>0.,"loads.structure_inertia"=>false,
        "fuel.enabled"=>false,"leading_edge.enabled"=>false,"output.solution"=>"101"))
end

checks=@testset "Equal-lift ellipse and inviscid aerodynamic coefficients" begin
    # Nonuniform strip boundaries; independently integrate the ideal ellipse
    # by a fine midpoint rule, rather than using the production antiderivative.
    edges=[0.,.02,.2,.53,.9,1.];lows=edges[1:end-1];highs=edges[2:end];widths=3.2.*(highs.-lows)
    for lift in (-250.,0.,900.)
        clc,forces=W.elliptical_reference_distribution(lows,highs,widths,[lift,0.,0.,0.,0.],740.)
        @test sum(clc.*widths)*740. ≈ lift atol=1e-10
        @test sum(forces) ≈ lift atol=1e-10
        @test all(isfinite,clc)
        for i in eachindex(lows)
            count=20000;step=(highs[i]-lows[i])/count
            fraction=4/pi*step*sum(sqrt(1-(lows[i]+(j-.5)*step)^2) for j in 1:count)
            @test forces[i] ≈ lift*fraction atol=1e-4
        end
    end
    @test all(iszero,first(W.elliptical_reference_distribution(lows,highs,widths,[1.,-1.,0.,0.,0.],740.)))
    @test W.inviscid_span_efficiency(.7,.7^2/(pi*8),8) ≈ 1.
    @test W.inviscid_span_efficiency(-.7,.7^2/(pi*8),8) ≈ 1.
    @test W.inviscid_span_efficiency(0.,.001,8)==0.
    @test W.inviscid_span_efficiency(0.,0.,8)===nothing
    @test W.inviscid_span_efficiency(.5,-.001,8)===nothing
    @test W.inviscid_span_efficiency(NaN,.001,8)===nothing
    @test W.inviscid_span_efficiency(.5,.001,0.)===nothing
    p=aero_plot_params()
    p["loads.label"]="VLM positive lift"
    p["loads.cases"]=Any[
        Dict("id"=>2,"label"=>"VLM reversed lift","alpha"=>-4.),
        Dict("id"=>3,"label"=>"VLM zero incidence","alpha"=>0.),
        Dict("id"=>4,"label"=>"Prescribed elliptical lift","method"=>"analytic","distribution"=>"elliptical","lift_total"=>700.),
        Dict("id"=>5,"label"=>"VLM structural multiplier","load_factor"=>2.),
        Dict("id"=>6,"label"=>"VLM Mach 0.5","speed_of_sound"=>240.)]
    m=W.build_model(first(W.normalize_params(p)));payload=W.mesh_payload(m)
    cases=payload["load_cases"]
    for c in cases
        loads=c["loads"];d=loads["spanwise"]["distribution"];s=loads["summary"]
        @test sum(d["elliptical_cl_chord_m"].*d["strip_width_m"])*d["q_Pa"] ≈ d["total_lift_N"] atol=1e-8
        @test sum(d["elliptical_strip_lift_N"]) ≈ sum(d["strip_lift_N"]) atol=1e-8
        if s["method"]=="vortex_lattice"
            @test s["aspect_ratio"] ≈ m.wing.span^2/m.wing.area
            @test s["reference_span_m"] == m.wing.span
            @test d["total_lift_N"] ≈ s["CL"]*s["q_Pa"]*m.wing.area/2*s["load_factor"] atol=1e-8
            @test s["CDi"]>=0.
            if s["CDi"]>0
                @test s["span_efficiency"] ≈ s["CL"]^2/(pi*s["aspect_ratio"]*s["CDi"])
            else
                @test s["span_efficiency"]===nothing
            end
        else
            @test !haskey(s,"CDi")
            @test d["elliptical_cl_chord_m"] ≈ d["cl_chord_m"]
        end
    end
    one,two,zero,analytic,scaled,mach=[c["loads"] for c in cases]
    @test two["summary"]["CL"]<0<one["summary"]["CL"]
    @test all(<(0),two["spanwise"]["distribution"]["elliptical_cl_chord_m"])
    @test abs(zero["summary"]["CL"])<1e-12
    @test zero["summary"]["span_efficiency"]===nothing
    @test scaled["summary"]["span_efficiency"] == one["summary"]["span_efficiency"]
    @test scaled["summary"]["CDi"] == one["summary"]["CDi"]
    @test scaled["spanwise"]["distribution"]["elliptical_cl_chord_m"] ≈ 2 .* one["spanwise"]["distribution"]["elliptical_cl_chord_m"]
    # Primary reference: MIT AVL 3.52 rectangular AR8, alpha2deg, 4x16 cosine
    # lattice: CL=.16000, CDff=.0010484 (see compressibility regression).
    # Compare aerodynamic coefficients, not just the derived e identity.
    @test one["summary"]["CL"] ≈ .16000 rtol=.02
    @test one["summary"]["CDi"] ≈ .0010484 rtol=.03
    # e is derived from these two coefficients, so its comparison interval
    # must propagate both independent tolerances, including CL being squared.
    # The coarse VLM and AVL near-field/wake conventions differ; this check
    # does not assert exact e=1 for a rectangular planform or clip its value.
    avl_efficiency=.16000^2/(pi*8*.0010484)
    @test avl_efficiency*.98^2/1.03 <= one["summary"]["span_efficiency"] <= avl_efficiency*1.02^2/.97
    if out!==nothing
        write(joinpath(out,"schema.json"),JSON.json(W.schema_payload(m.params,"aerodynamic-load-plots.toml")))
        write(joinpath(out,"payload.msgpack"),MsgPack.pack(payload))
        write(joinpath(out,"aero_cases.json"),JSON.json(cases))
        write(joinpath(out,"avl_baseline_comparison.json"),JSON.json(Dict("reference_CL"=>.16000,"reference_CDi"=>.0010484,"reference_span_efficiency"=>avl_efficiency,"actual_summary"=>one["summary"],"scope"=>"Coarse rectangular VLM baseline coefficient check; established near-field/wake convention differences remain. This work does not modify the force algorithm.")))
    end
end
out===nothing||write(joinpath(out,"aerodynamic_test_summary.json"),JSON.json(Dict("passed"=>true,"counts"=>string(Test.get_test_counts(checks)))))
