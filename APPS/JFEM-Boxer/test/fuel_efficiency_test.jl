using Test, LinearAlgebra
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const F=WingFEGen
length(ARGS)==2||error("Usage: julia --project=. test/fuel_efficiency_test.jl <evidence-directory> <fixture-directory>")
const evidence=abspath(ARGS[1]);const fixtures=abspath(ARGS[2]);mkpath(evidence);mkpath(fixtures)
function solver_parser_path()
    explicit=strip(get(ENV,"JFEM_SOLVER_SOURCE_ROOT",""))
    container=abspath(joinpath(@__DIR__,"..",".."))
    candidates=isempty(explicit) ? [container,joinpath(container,"01_PUBLIC_PROJECT_REPOSITORY","JFEM")] : [abspath(explicit)]
    for root in candidates
        parser=joinpath(root,"src","parsing","ReferenceParser.jl")
        isfile(parser)&&return parser
    end
    error("Set JFEM_SOLVER_SOURCE_ROOT to the JFEM repository root containing src/parsing/ReferenceParser.jl")
end
include(solver_parser_path())
const N=ReferenceParser
profile=Dict{String,Any}("version"=>1,"id"=>"fuel_plateau.dat","name"=>"Analytic constant-height tank",
    "raw_sha256"=>repeat("b",64),"source_url"=>F.UIUC_AIRFOIL_URL*"fuel_plateau.dat","fetched_at"=>"2026-10-13T00:00:00Z",
    "xu"=>[0.,.1,.9,1.],"zu"=>[0.,.1,.1,0.],"xl"=>[0.,.1,.9,1.],"zl"=>[0.,-.1,-.1,0.])
p=merge(F.default_params(),Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>2.,
    "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
    "planform.root_ref_x"=>10.,"planform.root_ref_y"=>20.,"planform.root_ref_z"=>30.,
    "airfoil.root_source"=>"uiuc","airfoil.tip_source"=>"uiuc","airfoil.root_profile"=>F.JSON.json(profile),"airfoil.tip_profile"=>F.JSON.json(profile),
    "airfoil.root"=>"fuel_plateau.dat","airfoil.tip"=>"fuel_plateau.dat","box.front_spar_xc"=>.2,"box.rear_spar_xc"=>.55,
    "box.end_eta"=>1.,"box.rib_pitch"=>1.,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,
    "mesh.elements_between_stringers"=>1,"mesh.aero_chord_points"=>11,"mesh.elements_spar_height"=>1,
    "fuel.enabled"=>true,"fuel.start_rib"=>1,"fuel.end_rib"=>3,"fuel.density"=>800.,
    "loads.fuel_percent"=>25.,"loads.fuel_accel_x"=>.2,"loads.fuel_accel_y"=>.1,"loads.fuel_accel_z"=>-1.,
    "loads.load_factor"=>1.5,"loads.lift_total"=>0.,"loads.torque_y"=>0.,"loads.method"=>"analytic",
    "loads.structure_inertia"=>false,"leading_edge.enabled"=>false,"properties.rib_stiffeners_enabled"=>false,"output.solution"=>"103"))
p=F.normalize_params(p)[1];model=F.build_model(p)
viewmodel(eff,percent=25.)=F.sensitivity_model(model,merge(copy(p),Dict("fuel.fill_efficiency"=>eff,"loads.fuel_percent"=>percent)))
reports=Any[]
suite=@testset "Uniform usable fuel volume fraction" begin
    @test F.default_params()["fuel.fill_efficiency"]===.9
    spec=F.SCHEMA_BY_KEY["fuel.fill_efficiency"]
    @test spec.group=="Fuel tank" && spec.label=="Fill efficiency factor"
    @test occursin("without changing",spec.help) && occursin("Fuel status",spec.help)
    legacy=copy(p);delete!(legacy,"fuel.fill_efficiency")
    @test F.normalize_params(legacy)[1]["fuel.fill_efficiency"]==.9
    @test F.fuel_mass_state(F.sensitivity_model(model,legacy))==F.fuel_mass_state(model)
    for invalid in (-.001,1.001,Inf,-Inf,NaN)
        bad=merge(p,Dict("fuel.fill_efficiency"=>invalid))
        @test_throws ArgumentError F.validate_params(bad)
        @test_throws ArgumentError F.fuel_mass_state(model;params=bad)
    end
    for efficiency in (0.,.35,1.),percent in (0.,25.,60.,100.)
        m=viewmodel(efficiency,percent);state=F.fuel_mass_state(m)
        baseline=F.fuel_mass_state(model;params=merge(p,Dict("loads.fuel_percent"=>percent,"fuel.fill_efficiency"=>1.)))
        capacity=F.fuel_summary(m);weights=F.weights_payload(m)
        expected_volume=.56*efficiency;expected_mass=800expected_volume*percent/100
        @test capacity["gross_volume_m3"]≈.56 atol=1e-10
        @test capacity["volume_m3"]≈expected_volume atol=1e-10
        @test capacity["mirrored_volume_m3"]≈2expected_volume atol=1e-10
        @test capacity["mirrored_gross_volume_m3"]≈1.12 atol=1e-10
        @test state["mass_kg"]≈expected_mass atol=2e-6
        @test state["filled_volume_m3"]≈expected_volume*percent/100 atol=3e-9
        @test state["gross_filled_volume_m3"]≈.56percent/100 atol=3e-9
        @test state["fill_efficiency"]==efficiency && state["fuel_percent"]==percent
        @test weights["fuel"]["gross_volume_m3"]≈.56 atol=1e-10
        @test weights["fuel"]["volume_m3"]≈expected_volume atol=1e-10
        @test weights["fuel"]["capacity_mass_kg"]≈800expected_volume atol=1e-8
        @test weights["totals"]["fuel_mass_kg"]≈expected_mass atol=2e-6
        @test weights["totals"]["deck_mass_kg"]≈weights["totals"]["structure_mass_kg"]+expected_mass atol=2e-6
        for (bay,base) in zip(state["bays"],baseline["bays"])
            @test bay["volume_m3"]≈efficiency*base["volume_m3"] atol=1e-12
            @test bay["mass_kg"]≈efficiency*base["mass_kg"] atol=1e-10
            @test bay["center_of_gravity_m"]==base["center_of_gravity_m"]
            @test bay["fill_level_z_m"]==base["fill_level_z_m"]
            @test bay["offset_m"]==base["offset_m"]
            @test bay["conm2_inertia_kg_m2"]≈efficiency.*base["conm2_inertia_kg_m2"] atol=1e-10
            @test reduce(hcat,bay["inertia_kg_m2"])≈efficiency.*reduce(hcat,base["inertia_kg_m2"]) atol=1e-10
        end
        loads=F.fuel_applied_loads(m);sources=F.fuel_plot_sources(m,[0.,.2,.5,.8,1.])
        expected_force=expected_mass*1.5*9.80665.*[.2,.1,-1.]
        @test sum((collect(x.force) for x in loads);init=zeros(3))≈expected_force atol=4e-5
        @test sum((collect(x.force) for x in sources);init=zeros(3))≈expected_force atol=4e-5
        expected_moment=sum((cross(row["center_of_gravity_m"],row["mass_kg"]*1.5*9.80665.*[.2,.1,-1.]) for row in state["bays"]);init=zeros(3))
        @test sum((collect(x.origin_moment) for x in sources);init=zeros(3))≈expected_moment atol=1e-8
        expected_mass==0 && (@test isempty(loads) && isempty(sources) && !state["in_deck"])
        push!(reports,Dict("efficiency"=>efficiency,"percent"=>percent,"gross_capacity_m3"=>capacity["gross_volume_m3"],
            "usable_capacity_m3"=>capacity["volume_m3"],"fuel_mass_kg"=>state["mass_kg"]))
    end
    # Native parser checks the actual generated small-field cards, including
    # inertia products, CG offsets and dead FORCE/MOMENT vectors.
    for efficiency in (0.,.35,1.)
        m=viewmodel(efficiency);state=F.fuel_mass_state(m);deck=sprint(F.write_deck,m)
        _,bulk=N.read_bulk_and_case(String.(split(deck,'\n')));cards=N.process_cards(bulk)
        masses=N.extract_conm2(get(cards,"CONM2",Any[]))
        forces=N.extract_loads(get(cards,"FORCE",Any[]));moments=N.extract_moments(get(cards,"MOMENT",Any[]))
        @test length(masses)==(efficiency>0 ? 2 : 0)
        for bay in state["bays"]
            efficiency>0||continue
            card=masses[string(bay["conm2_eid"])]
            @test card["M"]≈bay["mass_kg"] rtol=2e-6
            @test card["X"]≈bay["offset_m"] atol=2e-6
            @test card["I"]≈bay["conm2_inertia_kg_m2"] rtol=2e-6
            load=only(filter(x->x.gid==bay["reference_grid"],F.fuel_applied_loads(m)))
            parsed_force=sum((row["Mag"].*row["Dir"] for row in forces if row["GID"]==card["GID"]);init=zeros(3))
            parsed_moment=sum((row["Mag"].*row["Dir"] for row in moments if row["GID"]==card["GID"]);init=zeros(3))
            @test parsed_force≈collect(load.force) rtol=3e-6
            @test parsed_moment≈collect(load.moment) rtol=3e-6
        end
        write(joinpath(fixtures,"fuel_efficiency_$(efficiency).bdf"),deck)
        write(joinpath(fixtures,"fuel_efficiency_$(efficiency).toml"),F.params_to_toml(m.params))
    end
    for (disabled,enabled,expected) in (("1",true,.28),("1-2",true,0.),("",false,0.))
        m=F.build_model(merge(p,Dict("fuel.disabled_bays"=>disabled,"fuel.enabled"=>enabled,"fuel.fill_efficiency"=>.35)))
        summary=F.fuel_summary(m);state=F.fuel_mass_state(m);weights=F.weights_payload(m)
        @test get(summary,"gross_volume_m3",0.)≈expected atol=1e-10
        @test get(summary,"volume_m3",0.)≈.35expected atol=1e-10
        @test state["mass_kg"]≈800*.35expected*.25 atol=2e-6
        @test weights["fuel"]["capacity_mass_kg"]≈800*.35expected atol=1e-8
        @test length(state["bays"])==(expected>0 ? 1 : 0)
        @test expected>0 || isempty(F.fuel_applied_loads(m))
    end
    roundtrip=F.normalize_params(F.flatten_toml(F.TOML.parse(F.params_to_toml(viewmodel(.35).params))))[1]
    @test roundtrip["fuel.fill_efficiency"]==.35 && roundtrip["loads.fuel_percent"]==25.
    @test F.fuel_mass_state(F.sensitivity_model(model,roundtrip))==F.fuel_mass_state(viewmodel(.35))
    # Efficiency is shared by cases; fill percentages remain independent.
    cases=F.sensitivity_model(model,merge(viewmodel(.35).params,Dict("loads.cases"=>[Dict("id"=>2,"label"=>"Full","fuel_percent"=>100.)])))
    states=[F.fuel_mass_state(cases;params=s.params) for s in F.load_case_specs(cases.params)]
    @test [s["fill_efficiency"] for s in states]==[.35,.35]
    @test [s["mass_kg"] for s in states]≈[39.2,156.8] atol=2e-6
    @test F.fuel_states_differ(cases)
    @test !F.fuel_states_differ(F.sensitivity_model(cases,merge(cases.params,Dict("fuel.fill_efficiency"=>0.))))
    # Current property sensitivities keep fuel geometry/fill fixed. Changing
    # shell thickness or material density must not change fuel inertia/loads.
    altered=F.sensitivity_model(viewmodel(.35),merge(viewmodel(.35).params,
        Dict("properties.t_skin_upper"=>2p["properties.t_skin_upper"],"material.rho"=>1.2p["material.rho"])))
    @test F.fuel_mass_state(altered)==F.fuel_mass_state(viewmodel(.35))
    @test F.fuel_applied_loads(altered)==F.fuel_applied_loads(viewmodel(.35))
    payload=F.mesh_payload(viewmodel(.35))
    @test payload["fuel"]["volume_m3"]≈.196 atol=1e-10
    @test payload["fuel"]["mass_state"]["mass_kg"]≈39.2 atol=2e-6
    @test payload["load_cases"][1]["weights"]["totals"]["fuel_mass_kg"]≈39.2 atol=2e-6
    @test payload["loads"]["spanwise"]["applied_force_N"]≈39.2*1.5*9.80665.*[.2,.1,-1.] atol=4e-5
    @test F.fuel_surface(viewmodel(.35))==F.fuel_surface(model)
    write(joinpath(evidence,"fuel_payload.msgpack"),F.MsgPack.pack(payload))
    write(joinpath(evidence,"schema.json"),F.JSON.json(F.schema_payload(p,"")))
end
counts=Test.get_test_counts(suite)
write(joinpath(evidence,"summary.json"),F.JSON.json(Dict("passed"=>true,
    "assertions"=>counts.passes+counts.cumulative_passes,"cases"=>reports),2))
