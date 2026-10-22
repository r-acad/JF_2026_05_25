using Test, JSON, TOML, WingFEGen
const W=WingFEGen
suite=@testset "Editable AL2024 allowable and assessment fixity defaults" begin
    expected=W.default_material_allowables()
    @test only(expected)["stress"]==300e6
    @test W.default_params()["materials.allowables"]==expected
    for value in (nothing,Any[])
        p,_=W.normalize_params(Dict("materials.allowables"=>value))
        @test p["materials.allowables"]==expected
    end
    for name in ("AL2024","AA2024-T3","Aluminium 2024","Aluminum2024","2024 aluminium alloy")
        p,_=W.normalize_params(Dict("material.name"=>name,"materials.allowables"=>Any[]))
        @test only(p["materials.allowables"])["stress"]==300e6
    end
    for name in ("Steel","AL7075","Material1","AL20240","M2024","Steel 2024","Test 2024")
        p,_=W.normalize_params(Dict("material.name"=>name))
        @test isempty(p["materials.allowables"])
    end
    for row in (Dict("material_id"=>1,"mode"=>"stress","stress"=>275e6),Dict("material_id"=>1,"mode"=>"stress","stress"=>300e6),Dict("material_id"=>1,"mode"=>"stress"),Dict("material_id"=>1,"mode"=>"none"))
        p,_=W.normalize_params(Dict("materials.allowables"=>[row]))
        @test p["materials.allowables"]==[row]
        fromjson,_=W.normalize_params(JSON.parse(JSON.json(p)))
        fromtoml,_=W.normalize_params(W.flatten_toml(TOML.parse(W.params_to_toml(p))))
        @test fromjson["materials.allowables"]==[row]
        @test fromtoml["materials.allowables"]==[row]
        renamed,_=W.normalize_params(merge(p,Dict("material.name"=>"Steel")))
        @test renamed["materials.allowables"]==[row]
    end
    p,_=W.normalize_params(Dict{String,Any}())
    for restored in (JSON.parse(JSON.json(p)),W.flatten_toml(TOML.parse(W.params_to_toml(p))))
        loaded,_=W.normalize_params(restored)
        @test loaded["materials.allowables"]==expected
        renamed,_=W.normalize_params(merge(loaded,Dict("material.name"=>"Steel")))
        @test isempty(renamed["materials.allowables"])
    end
    explicit=merge(only(expected),Dict("stress"=>310e6))
    p,_=W.normalize_params(Dict("material.name"=>"Steel","materials.allowables"=>[explicit]))
    @test only(p["materials.allowables"])["stress"]==310e6
    @test !haskey(only(p["materials.allowables"]),"origin")
    library=vcat(W.default_material_library(),[Dict("id"=>7,"name"=>"AL2024-T351","E"=>71e9,"nu"=>.33,"rho"=>2780.)])
    p,_=W.normalize_params(Dict("materials.library"=>library))
    @test [row["material_id"] for row in p["materials.allowables"]]==[1,7]
    native=Dict("SOL"=>101,"GRIDs"=>Dict("1"=>Dict("X"=>[0.,0.,0.])),"CASE_CONTROL"=>Dict("SUBCASES"=>Dict()),"SPC1s"=>Any[])
    source=Dict("name"=>"Unknown-unit source")
    imported=W.imported_model(native,source,W.default_params())
    @test isempty(imported.params["materials.allowables"])
    explicit_source=Dict("material_id"=>1,"mode"=>"stress","stress"=>300.)
    imported=W.imported_model(native,source,merge(W.default_params(),Dict("materials.allowables"=>[explicit_source])))
    @test imported.params["materials.allowables"]==[explicit_source]
    keys=("stringers.euler_fixity_coefficient","stringers.skin_fixity_coefficient",W.COMPONENT_RF_FIXITY_KEYS...)
    baseline,_=W.normalize_params(W.default_params())
    legacy=deepcopy(baseline);legacy["materials.allowables"]=Any[]
    for (i,key) in enumerate(keys);isodd(i) ? delete!(legacy,key) : (legacy[key]=nothing);end
    migrated,_=W.normalize_params(legacy)
    @test migrated==baseline
    @test W.sensitivity_definition(migrated)==W.sensitivity_definition(baseline)
    for key in keys
        p,_=W.normalize_params(Dict(key=>nothing));@test p[key]==1.
        @test W.default_params()[key]==1.
        p,_=W.normalize_params(Dict(key=>2.));@test p[key]==2.
        restored,_=W.normalize_params(JSON.parse(JSON.json(p)));@test restored[key]==2.
        for value in (0.,-1.,NaN,Inf,"",true,false)
            @test_throws ArgumentError W.normalize_params(Dict(key=>value))
        end
    end
end
if !isempty(ARGS)
    mkpath(first(ARGS));counts=Test.get_test_counts(suite)
    write(joinpath(first(ARGS),"material_defaults_backend.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
end
