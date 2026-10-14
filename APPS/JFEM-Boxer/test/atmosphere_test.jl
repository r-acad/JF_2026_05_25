using Test
length(ARGS) <= 1 || error("Usage: atmosphere_test.jl [evidence-directory]")
include(joinpath(@__DIR__, "..", "src", "WingFEGen.jl"))
const W = WingFEGen

@testset "ISA 1976 standard atmosphere and load-case persistence" begin
    # Independent NOAA/NASA 1976 standard tabulations (rounded published values).
    sea = W.isa1976(0.0)
    @test sea["temperature_K"] == 288.15
    @test sea["pressure_Pa"] == 101325
    @test sea["density_kg_m3"] ≈ 1.225 rtol=2e-6
    @test sea["speed_of_sound_m_s"] ≈ 340.294 rtol=2e-6
    for (h, temperature, pressure, density) in ((11000.,216.65,22632.1,.363918),
            (20000.,216.65,5474.89,.0880349), (32000.,228.65,868.019,.0132250),
            (47000.,270.65,110.906,.00142753), (51000.,270.65,66.9389,.000861606),
            (71000.,214.65,3.95642,.0000642110))
        z = W.geometric_altitude(h); air = W.isa1976(z)
        @test air["altitude_geopotential_m"] ≈ h atol=1e-10
        @test air["temperature_K"] ≈ temperature atol=1e-10
        @test air["pressure_Pa"] ≈ pressure rtol=5e-6
        @test air["density_kg_m3"] ≈ density rtol=5e-6
        @test W.isa1976(z-1e-4)["pressure_Pa"] ≈ W.isa1976(z+1e-4)["pressure_Pa"] rtol=1e-7
    end
    @test W.isa1976(86000.)["temperature_K"] ≈ 186.8673 atol=.001
    @test W.isa1976(-5000.)["pressure_Pa"] > sea["pressure_Pa"]
    @test_throws ArgumentError W.isa1976(86001.)
    @test_throws ArgumentError W.isa1976(NaN)
    p = merge(W.default_params(), Dict{String,Any}("loads.method"=>"vortex_lattice", "aero.speed"=>100.,
        "aero.span_panels"=>4, "aero.chord_panels"=>2, "aero.alpha"=>2., "planform.area"=>4.,
        "planform.aspect_ratio"=>4., "box.rib_pitch"=>1., "box.stringer_pitch"=>.35,
        "mesh.elements_between_ribs"=>1, "mesh.elements_between_stringers"=>1))
    @test p["aero.atmosphere"] == "isa1976"
    # Legacy density/sound speed must not silently change to sea-level ISA.
    legacy = copy(p)
    for key in ("aero.atmosphere","aero.altitude","aero.altitude_unit","aero.speed_unit")
        delete!(legacy,key)
    end
    legacy["aero.density"] = .7; legacy["aero.speed_of_sound"] = 310.
    old, unknown = W.normalize_params(legacy)
    @test isempty(unknown)
    @test old["aero.atmosphere"] == "manual"
    @test W.flight_condition(old)["density_kg_m3"] == .7
    @test W.flight_condition(old)["speed_of_sound_m_s"] == 310.
    @test W.flight_condition(old)["temperature_K"] === nothing
    p["loads.cases"] = Any[
        Dict("id"=>2,"label"=>"FL300","altitude"=>W.geometric_altitude(300*30.48),"altitude_unit"=>"FL","speed_unit"=>"Mach"),
        Dict("id"=>3,"label"=>"Manual","atmosphere"=>"manual","density"=>.9,"speed_of_sound"=>320.),
    ]
    @test isnothing(W.validate_params(p))
    specs = W.load_case_specs(p)
    @test W.flight_condition(specs[2].params)["pressure_altitude_ft"] ≈ 30000
    @test W.flight_condition(specs[3].params)["speed_of_sound_m_s"] == 320.
    @test p["aero.altitude"] == 0 # case resolution does not mutate the base.
    decoded, unknown = W.normalize_params(W.flatten_toml(W.TOML.parse(W.params_to_toml(p))))
    @test isempty(unknown)
    @test decoded["loads.cases"] == W.normalize_load_cases(p["loads.cases"])
    @test decoded["aero.atmosphere"] == "isa1976"
    @test W.flight_condition(W.load_case_specs(decoded)[2].params) == W.flight_condition(specs[2].params)
    # Density and sound speed supplied by ISA, not stale manual fields.
    changed = merge(copy(p), Dict("aero.density"=>100.,"aero.speed_of_sound"=>1000.))
    @test W.flight_condition(changed) == W.flight_condition(p)
    too_fast = deepcopy(p); too_fast["loads.cases"][1]["speed"] = 160.
    @test 160 / sea["speed_of_sound_m_s"] < .5
    @test_throws ArgumentError W.validate_params(too_fast) # colder case exceeds .5
    bad = deepcopy(p); bad["loads.cases"][1]["altitude_unit"] = "yards"
    @test_throws ArgumentError W.validate_params(bad)
    # Small aerodynamic solve verifies dimensional loads use each case's ISA rho
    # and its local a in the PG transformation. No structural solver is started.
    model = W.build_model(p); cases = W.case_loads(model)
    @test length(cases) == 3
    for (case, spec) in zip(cases, specs)
        air = W.flight_condition(spec.params)
        @test case.loads.summary["q_Pa"] ≈ air["q_Pa"]
        @test case.loads.summary["Mach"] ≈ air["Mach"]
        @test case.loads.summary["density_kg_m3"] ≈ air["density_kg_m3"]
        @test case.loads.summary["flight_condition"] == air
        @test W.spanwise_load_data(W.model_for_load_case(model,spec),case.loads)["distribution"]["q_Pa"] ≈ air["q_Pa"]
    end
    high = specs[2].params
    direct = merge(copy(high),Dict("aero.atmosphere"=>"manual", "aero.density"=>W.flight_condition(high)["density_kg_m3"],
        "aero.speed_of_sound"=>W.flight_condition(high)["speed_of_sound_m_s"]))
    direct_load = W.solve_vlm(model.wing,direct)
    @test direct_load.summary["force_N"] ≈ cases[2].loads.summary["force_N"] rtol=1e-12
    if !isempty(ARGS)
        output = abspath(only(ARGS)); mkpath(output)
        write(joinpath(output,"schema.json"),W.JSON.json(W.schema_payload(p,"atmosphere_fixture.toml"),2))
        write(joinpath(output,"params.json"),W.JSON.json(p,2))
        write(joinpath(output,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(model)))
        write(joinpath(output,"atmosphere_values.json"),W.JSON.json(Dict(string(z)=>W.isa1976(z) for z in (-5000.,0.,10000.,20000.,80000.,82500.,86000.)),2))
    end
end
