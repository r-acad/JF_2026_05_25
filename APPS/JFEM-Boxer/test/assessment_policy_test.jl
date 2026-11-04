# julia --project=. --startup-file=no APPS/JFEM-Boxer/test/assessment_policy_test.jl OUTPUT
using Test, JSON, WingFEGen, OpenJFEM
const W=WingFEGen
const OUT=abspath(only(ARGS));mkpath(OUT)
const SAFETY="assessment.strength_safety_factor"
const BUCKLING="assessment.buckling_policy_factor"

function policy_fixture()
    p=W.default_params()
    merge!(p,Dict{String,Any}("planform.area"=>8.,"planform.aspect_ratio"=>8.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"planform.dihedral"=>0.,
        "planform.twist_tip"=>0.,"airfoil.root"=>"NACA0012","airfoil.tip"=>"NACA0012",
        "box.end_eta"=>1.,"box.rib_pitch"=>1.,"box.stringer_pitch"=>.3,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"airfoil.n_points"=>21,"mesh.aero_chord_points"=>11,
        "loads.method"=>"analytic","loads.lift_total"=>100.,"loads.torque_y"=>35.,
        "loads.structure_inertia"=>true,"loads.fuel_accel_x"=>.2,
        "loads.fuel_accel_y"=>-.3,"loads.fuel_accel_z"=>-2.,"fuel.enabled"=>true,
        "loads.fuel_percent"=>60.,"leading_edge.enabled"=>false,"output.solution"=>"101",
        "engines.items"=>Any[Dict("name"=>"Policy engine","x"=>-.4,"y"=>1.4,"z"=>-1.2,
            "mass"=>500.,"length"=>2.4,"front_rib"=>3,"aft_rib"=>3,"aft_xc"=>.55)],
        "loads.engine_thrust"=>Any[Dict("engine"=>"Policy engine","thrust_n"=>300.)],
        "loads.cases"=>Any[Dict("id"=>2,"label"=>"Reversed physical case","load_factor"=>-.7,
            "fuel_percent"=>25.,"fuel_accel_z"=>1.)]))
    first(W.normalize_params(p))
end
physical_deck(m)=begin
    decks=String[]
    for spec in W.load_case_specs(m.params)
        case_model=W.model_for_load_case(m,spec)
        io=IOBuffer();W.write_deck(IOContext(io,:full_precision=>true),case_model)
        push!(decks,join(filter(line->!startswith(strip(line),'$'),split(String(take!(io)),'\n')),'\n'))
    end
    join(decks,"\n")
end

tests=@testset "Independent limit, ultimate and buckling policy contracts" begin
    p=W.default_params()
    @test p["loads.load_factor"]==1.
    @test p[SAFETY]==1.5
    @test p[BUCKLING]==1.
    @test W.SCHEMA_BY_KEY[SAFETY].group=="Sizing load policy"
    @test W.SCHEMA_BY_KEY[BUCKLING].group=="Sizing load policy"
    fresh,unknown=W.normalize_params(Dict{String,Any}())
    @test isempty(unknown)
    @test fresh["loads.load_factor"]==1.
    @test !haskey(fresh,"assessment.migration_note")
    # Explicit old multipliers are authored physical cases, never divided or
    # silently rewritten. Sparse old TOMLs also keep their former implicit1.5.
    old,unknown=W.normalize_params(Dict{String,Any}("loads.label"=>"Legacy sparse"))
    @test isempty(unknown)
    @test old["loads.load_factor"]==1.5
    @test old[SAFETY]==1.5&&old[BUCKLING]==1.
    @test occursin("ultimate safety factor",old["assessment.migration_note"])
    for factor in (1.,1.5,2.,-.7)
        legacy,_=W.normalize_params(Dict{String,Any}("loads.load_factor"=>factor))
        @test legacy["loads.load_factor"]==factor
        @test haskey(legacy,"assessment.migration_note")==(!isone(factor))
    end
    explicit,_=W.normalize_params(Dict{String,Any}(SAFETY=>2.,BUCKLING=>1.2))
    @test explicit["loads.load_factor"]==1.
    @test !haskey(explicit,"assessment.migration_note")
    oldcases,_=W.normalize_params(Dict{String,Any}("loads.load_factor"=>1.,
        "loads.cases"=>Any[Dict("id"=>2,"label"=>"Legacy nonunit","load_factor"=>1.5)]))
    @test occursin("retained",oldcases["assessment.migration_note"])
    @test last(W.load_case_specs(oldcases)).params["loads.load_factor"]==1.5
    for key in (SAFETY,BUCKLING),invalid in (0.,-.1,NaN,Inf,-Inf,true)
        bad=merge(p,Dict(key=>invalid))
        @test_throws ArgumentError W.validate_params(bad)
        @test_throws ArgumentError W.assessment_policy_payload(bad)
        @test_throws ArgumentError W.normalize_params(bad)
    end
    for (s,b) in ((1.5,1.),(2.,1.25),(.9,.8))
        p2=merge(p,Dict(SAFETY=>s,BUCKLING=>b))
        W.validate_params(p2)
        written=W.params_to_toml(p2)
        restored,_=W.normalize_params(W.flatten_toml(W.TOML.parse(written)))
        @test restored[SAFETY]==s&&restored[BUCKLING]==b
        @test restored["loads.load_factor"]==1.
        metadata=W.assessment_policy_payload(restored)
        @test metadata["load_basis"]=="limit"
        @test metadata["strength_load_level"]=="ultimate"
        @test metadata["strength_safety_factor"]==s
        @test metadata["buckling_policy_factor"]==b
    end
    schema=W.schema_payload(old,"legacy.toml")
    @test schema["values"]["assessment.migration_note"]==old["assessment.migration_note"]
    @test schema["assessment_policy"]["migration_note"]==old["assessment.migration_note"]
    oldrestored,_=W.normalize_params(W.flatten_toml(W.TOML.parse(W.params_to_toml(old))))
    @test oldrestored["assessment.migration_note"]==old["assessment.migration_note"]
    reset=merge(copy(p),Dict(SAFETY=>2.,BUCKLING=>1.25,"assessment.migration_note"=>"old note"))
    W.apply_assessment_policy!(reset,Dict();reset=true)
    @test reset[SAFETY]==1.5&&reset[BUCKLING]==1.
    @test !haskey(reset,"assessment.migration_note")
    W.apply_assessment_policy!(reset,Dict(SAFETY=>2.,BUCKLING=>1.25))
    @test reset[SAFETY]==2.0&&reset[BUCKLING]==1.25
    @test_throws ArgumentError W.apply_assessment_policy!(copy(reset),Dict(SAFETY=>0.))
    @test_throws ArgumentError W.apply_assessment_policy!(copy(reset),Dict(BUCKLING=>true))
    @test_throws ArgumentError W.apply_assessment_policy!(copy(reset),Dict("assessment.migration_note"=>12))

    # Exercise actual aero/torque, structural inertia, fuel and engine forces.
    p=policy_fixture();m=W.build_model(p)
    original_cases=W.case_loads(m)
    original_deck=physical_deck(m)
    original_signature=W.sensitivity_model_signature(m)
    original_fingerprint=W.physical_parameter_fingerprint(m.params)
    source_payload=W.mesh_payload(m)
    fixture=joinpath(OUT,"browser_fixture");mkpath(fixture)
    write(joinpath(fixture,"schema.json"),JSON.json(W.schema_payload(source_payload["model_params"],"load_policy_fixture.toml")))
    write(joinpath(fixture,"params.json"),JSON.json(source_payload["model_params"]))
    write(joinpath(fixture,"payload.msgpack"),W.MsgPack.pack(source_payload))
    legacy_flat=Dict(k=>deepcopy(v) for (k,v) in source_payload["model_params"] if !startswith(k,"assessment."))
    legacy_flat["loads.load_factor"]=1.5
    legacy_normalized,_=W.normalize_params(legacy_flat)
    write(joinpath(fixture,"legacy_normalized_params.json"),JSON.json(legacy_normalized))
    @test source_payload["assessment_policy"]["strength_safety_factor"]==1.5
    @test source_payload["loads"]["load_basis"]=="limit"
    @test !isempty(source_payload["loads"]["fuel_stations"])
    @test !isempty(source_payload["loads"]["structure_stations"])
    @test !isempty(source_payload["loads"]["engine_stations"])
    @test !isempty(source_payload["loads"]["moment_stations"])
    @test original_cases[1].loads.summary["lift_N"]≈100.
    @test original_cases[2].loads.summary["lift_N"]≈-70.
    # Changing assessment factors must reuse physical loads and preserve the
    # exported FE cards, sensitivity identity and every authored case scale.
    cached_cases=W.case_loads(m)
    cached_aero=W.aerodynamic_loads(m)
    m.params[SAFETY]=2.;m.params[BUCKLING]=1.25
    changed_cases=W.case_loads(m)
    @test all(a.loads===b.loads for (a,b) in zip(cached_cases,changed_cases))
    @test W.aerodynamic_loads(m)===cached_aero
    @test all(c.params[SAFETY]==2.0 && c.params[BUCKLING]==1.25 for c in changed_cases)
    @test physical_deck(m)==original_deck
    @test W.sensitivity_model_signature(m)==original_signature
    @test W.physical_parameter_fingerprint(m.params)==original_fingerprint
    changed_payload=W.mesh_payload(m)
    for (oldcase,newcase) in zip(source_payload["load_cases"],changed_payload["load_cases"])
        for field in ("stations","force_stations","moment_stations","fuel_stations","structure_stations","engine_stations")
            @test oldcase["loads"][field]==newcase["loads"][field]
        end
        @test newcase["loads"]["assessment_policy"]["strength_safety_factor"]==2.
        @test newcase["loads"]["assessment_policy"]["buckling_policy_factor"]==1.25
    end
    @test changed_payload["assessment_policy"]["buckling_policy_factor"]==1.25
    child=W.model_for_load_case(m,(id=2,label="policy",params=merge(copy(m.params),Dict(SAFETY=>1.8))))
    @test W.validate_comparison_model(m,child,first(W.load_case_specs(m.params)))===nothing
    badchild=W.model_for_load_case(m,(id=2,label="different load",params=merge(copy(m.params),Dict("loads.load_factor"=>1.1))))
    @test_throws ArgumentError W.validate_comparison_model(m,badchild,first(W.load_case_specs(m.params)))
    result=Dict{String,Any}("load_cases"=>Any[Dict{String,Any}("variants"=>Any[Dict{String,Any}()])])
    W.attach_result_source!(result,m.params)
    @test result["assessment_policy"]["strength_safety_factor"]==2.
    @test result["load_cases"][1]["variants"][1]["assessment_policy"]["buckling_policy_factor"]==1.25
    # The raw SOL105 preload/search and SOL106 loading are unchanged too.
    for solution in ("105","106")
        params=merge(copy(m.params),Dict("output.solution"=>solution,SAFETY=>1.5,BUCKLING=>1.))
        other=W.model_for_load_case(m,(id=2,label="policy export",params=params))
        before=physical_deck(other)
        other.params[SAFETY]=2.;other.params[BUCKLING]=1.25
        @test physical_deck(other)==before
    end
    m.params["loads.load_factor"]=1.1
    @test W.physical_parameter_fingerprint(m.params)!=original_fingerprint
    @test W.sensitivity_model_signature(m)!=original_signature
end

imports=@testset "Imported policy restoration preserves native FE source" begin
    deck="""
SOL 101
CEND
SUBCASE 17
 SPC = 2
 LOAD = 4
BEGIN BULK
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,.5,0.
GRID,49,,0.,.5,0.
CQUAD4,701,123,11,25,38,49
PSHELL,123,8,.02,8,,8
MAT1,8,7.0E10,,.3,2700.
SPC1,2,123456,11,49
FORCE,4,25,0,100.,0.,0.,1.
ENDDATA
"""
    path=joinpath(OUT,"imported_policy_panel.bdf");write(path,deck)
    source=W.imported_source(Dict("name"=>basename(path),"text"=>deck))
    native=OpenJFEM.bdf_to_model(path)
    model=W.imported_model(native,source,W.default_params())
    token="assessment_policy_"*source["signature"]
    lock(W.IMPORTED_MODELS_LOCK) do;W.IMPORTED_MODELS[token]=model;end
    try
        handle=Dict("token"=>token,"signature"=>source["signature"])
        raw=Dict("parameters"=>Dict{String,Any}("imported_deck"=>handle,
            SAFETY=>2.,BUCKLING=>1.25,"assessment.migration_note"=>"Review authored load level"))
        changed=W.request_imported_model(raw)
        @test changed.params[SAFETY]==2.0 && changed.params[BUCKLING]==1.25
        @test model.params[SAFETY]==1.5&&model.params[BUCKLING]==1.
        @test changed.xyz===model.xyz&&changed.groups===model.groups
        @test W.imported_analysis_signature(changed)==W.imported_analysis_signature(model)
        @test changed.params["imported.source"]["flattened"]==deck
        payload=W.imported_mesh_payload(changed)
        @test payload["assessment_policy"]["strength_safety_factor"]==2.
        @test payload["assessment_policy"]["buckling_policy_factor"]==1.25
        @test payload["assessment_policy"]["migration_note"]=="Review authored load level"
        for value in (0.,-1.,NaN,Inf,true)
            invalid=deepcopy(raw);invalid["parameters"][BUCKLING]=value
            @test_throws ArgumentError W.request_imported_model(invalid)
        end
    finally
        lock(W.IMPORTED_MODELS_LOCK) do;delete!(W.IMPORTED_MODELS,token);end
    end
end

write(joinpath(OUT,"assessment_policy_backend_summary.json"),JSON.json(Dict("passed"=>true,
    "counts"=>string(Test.get_test_counts(tests)),"imported_counts"=>string(Test.get_test_counts(imports)),"load_basis"=>"limit",
    "new_case_multiplier"=>1.,"strength_safety_default"=>1.5,"buckling_policy_default"=>1.,
    "physical_loads_preserved_on_policy_edits"=>true,"legacy_loads_preserved"=>true),2))
