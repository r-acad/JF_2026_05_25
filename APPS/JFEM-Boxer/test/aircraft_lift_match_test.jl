using Test, WingFEGen
const W = WingFEGen

@testset "Aircraft mass and load-factor lift matching" begin
    p = W.default_params()
    p["loads.structure_inertia"] = false
    p["loads.fuel_accel_z"] = 0.0
    p["loads.aircraft_mass"] = 7450.0
    p["loads.maneuver_factor"] = 3.0
    p["loads.load_factor"] = 1.5
    p["loads.lift_total"] = 1234.0
    p["box.end_eta"] = 0.8
    p["loads.distribution"] = "schrenk"
    @test W.effective_prescribed_lift(p) == 1234.0
    p["loads.match_aircraft_lift"] = true
    target = 0.5 * 7450.0 * 3.0 * 9.80665
    @test isapprox(W.effective_prescribed_lift(p), target)
    m = W.build_model(p)
    loads = W.aerodynamic_loads(m)
    @test loads.summary["lift_N"] ≈ target * 1.5
    @test sum(s.force[3] for s in loads.stations) ≈ target * 1.5
    @test isapprox(loads.summary["lift_matching"]["target_unscaled_half_lift_N"], target)
    plots = W.spanwise_load_data(m, loads)
    @test plots["distribution"]["total_lift_N"] ≈ target * 1.5
    # Outboard loading and its moment arm scale consistently with the match.
    moment = W.analytic_outboard_couple(m)
    m.params["loads.match_aircraft_lift"] = false
    m.params["loads.lift_total"] = target
    @test all(isapprox.(moment, W.analytic_outboard_couple(m); rtol=1e-12))
    @test W.aerodynamic_loads(m).summary["lift_matching"]["enabled"] == false
    m.params["loads.lift_total"] = 1234.0
    @test W.aerodynamic_loads(m).summary["lift_N"] ≈ 1234.0 * 1.5

    p["loads.cases"] = [Dict("id"=>2,"label"=>"Negative maneuver", "maneuver_factor"=>-1.0),
        Dict("id"=>3,"label"=>"Entered flight condition", "match_aircraft_lift"=>false,"lift_total"=>2222.0)]
    m = W.build_model(p)
    cases = W.case_loads(m)
    @test cases[1].loads.summary["lift_N"] ≈ target * 1.5
    @test cases[2].loads.summary["lift_N"] ≈ -7450.0 * 9.80665 / 2 * 1.5
    @test cases[3].loads.summary["lift_N"] ≈ 2222.0 * 1.5
    deck = IOBuffer(); W.write_deck(deck,m)
    @test occursin("Aircraft lift match: complete mass",String(take!(deck)))
    normalized, unknown = W.normalize_params(Dict("loads.match_aircraft_lift"=>true,
        "loads.aircraft_mass"=>7450.0,"loads.maneuver_factor"=>3.0,"loads.cases"=>p["loads.cases"]))
    @test isempty(unknown)
    @test normalized["loads.cases"][2]["match_aircraft_lift"] == false
    for (key,value) in (("loads.aircraft_mass",0.0),("loads.aircraft_mass",Inf),("loads.maneuver_factor",NaN))
        bad=deepcopy(p);bad[key]=value
        @test_throws ArgumentError W.validate_params(bad)
    end
end

@testset "VLM incidence solves the requested aircraft lift" begin
    p = W.default_params()
    p["loads.method"] = "vortex_lattice"
    p["loads.load_factor"] = 1.0
    p["loads.structure_inertia"] = false
    p["loads.fuel_accel_z"] = 0.0
    p["aero.alpha"] = 5.0
    p["aero.span_panels"] = 4
    p["aero.chord_panels"] = 2
    w = W.make_wing(p)
    baseline = W.solve_vlm(w,p)
    target = baseline.summary["lift_N"]
    p["loads.aircraft_mass"] = 2target/9.80665
    p["loads.maneuver_factor"] = 1.0
    p["loads.match_aircraft_lift"] = true
    p["aero.alpha"] = -2.0
    p["loads.load_factor"] = 1.5
    solution = W.solve_vlm(w,p)
    @test solution.summary["lift_N"] ≈ 1.5target rtol=1e-8
    @test solution.summary["alpha_deg"] ≈ 5.0 atol=1e-6
    @test p["aero.alpha"] == -2.0 # trim never mutates the entered flight condition
    @test solution.summary["lift_matching"]["iterations"] > 1
    @test solution.summary["lift_matching"]["target_unscaled_half_lift_N"] ≈ target
    @test all(isapprox.(solution.panels[1].force, 1.5.*baseline.panels[1].force;rtol=1e-7))
    @test solution.summary["CL"] ≈ baseline.summary["CL"] rtol=1e-8
    m = W.build_model(p);loads=W.aerodynamic_loads(m)
    plots = W.spanwise_load_data(m,loads)
    @test plots["distribution"]["total_lift_N"] ≈ 1.5target rtol=1e-8
    @test loads.summary["force_error_N"] < 1e-7
    @test loads.summary["moment_error_Nm"] < 1e-7
    p["loads.match_aircraft_lift"] = false
    supplied = W.solve_vlm(w,p)
    @test supplied.summary["alpha_deg"] == -2.0
    @test !isapprox(supplied.summary["lift_N"],solution.summary["lift_N"];rtol=0.1)
    p["loads.match_aircraft_lift"] = true
    p["loads.maneuver_factor"] = -1.0
    negative = W.solve_vlm(w,p)
    @test negative.summary["lift_N"] ≈ -1.5target rtol=1e-8
    p["loads.aircraft_mass"] = 1e10
    @test_throws ArgumentError W.solve_vlm(w,p)
end
