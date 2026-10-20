using Test, JSON, TOML
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)

suite=@testset "Study material assessment limits" begin
    stress=Dict{String,Any}("material_id"=>1,"mode"=>"stress","stress"=>320e6)
    strain=Dict{String,Any}("material_id"=>81,"mode"=>"strain","e1_t"=>.012,"e1_c"=>.009,
        "e2_t"=>.004,"e2_c"=>.006,"g12"=>.018)
    rows=W.normalize_material_allowables([strain,stress])
    @test rows==[stress,strain]
    @test isempty(W.default_params()["materials.allowables"])
    @test W.normalize_material_allowables([Dict("material_id"=>81,"mode"=>"strain")])==[Dict("material_id"=>81,"mode"=>"strain")]
    for bad in ([merge(stress,Dict("stress"=>v))] for v in (0.,-1.,NaN,Inf,true,"300"))
        @test_throws ArgumentError W.normalize_material_allowables(bad)
    end
    for bad in ([stress,stress],[merge(stress,Dict("extra"=>1))],
                [merge(stress,Dict("material_id"=>0))],[merge(stress,Dict("mode"=>"auto"))])
        @test_throws ArgumentError W.normalize_material_allowables(bad)
    end
    p=merge(W.default_params(),Dict{String,Any}("planform.area"=>4.,"planform.aspect_ratio"=>4.,
        "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"box.rib_pitch"=>.6,"box.stringer_pitch"=>.2,
        "box.end_eta"=>.9,"mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.aero_chord_points"=>9,"airfoil.n_points"=>41,"fuel.enabled"=>false,
        "loads.method"=>"analytic","materials.allowables"=>rows))
    normalized,unknown=W.normalize_params(p)
    @test isempty(unknown)
    @test normalized["materials.allowables"]==rows
    text=W.params_to_toml(normalized)
    roundtrip,unknown=W.normalize_params(W.flatten_toml(TOML.parse(text)))
    @test isempty(unknown)
    @test roundtrip["materials.allowables"]==rows
    jsonroundtrip,unknown=W.normalize_params(JSON.parse(JSON.json(normalized)))
    @test isempty(unknown)
    @test jsonroundtrip["materials.allowables"]==rows
    @test W.material_payload(W.material_definition(p,1))["allowables"]==stress
    @test !haskey(W.material_payload(W.material_definition(p,2)),"allowables")
    baseline=merge(p,Dict("materials.allowables"=>Any[]))
    @test W.sensitivity_definition(p)==W.sensitivity_definition(baseline)
    m=W.build_model(p);clean=W.build_model(baseline)
    @test m.xyz==clean.xyz
    @test W.sensitivity_model_signature(m)==W.sensitivity_model_signature(clean)
    deck=sprint(io->W.write_deck(IOContext(io,:full_precision=>true),m))
    cleandeck=sprint(io->W.write_deck(IOContext(io,:full_precision=>true),clean))
    without_write_time(text)=replace(text,r"(?m)^\$ Written[^\r\n]*"=>"")
    @test without_write_time(deck)==without_write_time(cleandeck)
    @test occursin("STRAIN(PLOT) = ALL",deck)
    payload=W.mesh_payload(m)
    @test payload["materials"]["allowables"]==rows
    @test first(payload["materials"]["library"])["allowables"]==stress
    @test payload["model_params"]["materials.allowables"]==rows
    write(joinpath(out,"generated.msgpack"),W.MsgPack.pack(payload))

    # Imported laminate IDs are independent of the generated material library.
    native=Dict{String,Any}("SOL"=>101,"CASE_CONTROL"=>Dict("SUBCASES"=>Dict(1=>Dict("LABEL"=>"Laminate"))),
        "GRIDs"=>Dict(string(i)=>Dict("ID"=>i,"X"=>xyz,"CP"=>0,"CD"=>0) for (i,xyz) in enumerate(([0.,0.,0.],[1.,0.,0.],[1.,1.,0.],[0.,1.,0.]))),
        "CORDs"=>Dict(),"CSHELLs"=>Dict("1"=>Dict("ID"=>1,"PID"=>91,"TYPE"=>"CQUAD4","NODES"=>[1,2,3,4],"THETA"=>0.,"MCID"=>0)),
        "PSHELLs"=>Dict("91"=>Dict("PID"=>91,"MID"=>81,"T"=>.002,"TYPE"=>"PCOMP_CLT","PCOMP_Z0"=>-.001,
            "PLY_DATA"=>[Dict("mid"=>81,"z_bot"=>-.001,"z_top"=>0.,"theta"=>30.),Dict("mid"=>81,"z_bot"=>0.,"z_top"=>.001,"theta"=>-30.)])),
        "MATs"=>Dict("81"=>Dict("MID"=>81,"TYPE"=>"MAT8","E"=>130e9,"E1"=>130e9,"E2"=>9e9,"G12"=>4.5e9,
            "NU"=>.28,"NU12"=>.28,"RHO"=>1600.,"XT"=>1000e6,"XC"=>800e6,"YT"=>30e6,"YC"=>120e6,"S"=>50e6,"STRN"=>0.)),
        "CBARs"=>Dict(),"PBARLs"=>Dict(),"SPC1s"=>Any[])
    source=W.imported_source(Dict("name"=>"laminate.bdf","text"=>"SOL 101\nCEND\nSTRAIN(PLOT) = NONE\nSUBCASE 1\n  STRAIN(PRINT) = NONE\nBEGIN BULK\nENDDATA\n"))
    imported=W.imported_model(native,source,p)
    before=deepcopy(native)
    imported_payload=W.imported_mesh_payload(imported)
    mat=only(imported_payload["materials"]["library"])
    @test mat["allowables"]==strain
    @test mat["E1_Pa"]==130e9
    @test mat["E2_Pa"]==9e9
    @test mat["G12_Pa"]==4.5e9
    @test mat["source_strength_fields"]["XT"]==1000e6
    @test native==before
    @test only(imported_payload["groups"])["properties"]["plies"][1]["material"]["allowables"]==strain
    @test W.imported_analysis_model(imported,nothing)===imported
    configured=W.imported_analysis_model(imported,Dict("solution"=>"101"))
    configureddeck=configured.params["imported.analysis_deck"]
    @test occursin("STRAIN(PRINT) = ALL",configureddeck)
    @test !occursin("STRAIN(PLOT) = NONE",configureddeck)
    @test !occursin("STRAIN(PRINT) = NONE",configureddeck)
    @test imported.params["imported.source"]["text"]==source["text"]
    write(joinpath(out,"imported.msgpack"),W.MsgPack.pack(imported_payload))
    token="material-allowables-test"
    W.IMPORTED_MODELS[token]=imported
    try
        replacement=[merge(strain,Dict("e1_t"=>.02))]
        requested=W.request_imported_model(Dict("parameters"=>Dict("imported_deck"=>Dict("token"=>token,"signature"=>source["signature"]),"materials.allowables"=>replacement)))
        @test requested.params["materials.allowables"]==replacement
        @test imported.params["materials.allowables"]==rows
        @test W.imported_analysis_signature(requested)==W.imported_analysis_signature(imported)
        @test requested.params["imported.source"]==imported.params["imported.source"]
        @test_throws ArgumentError W.request_imported_model(Dict("parameters"=>Dict("imported_deck"=>Dict("token"=>token),"materials.allowables"=>[merge(strain,Dict("g12"=>-1.))])))
    finally
        delete!(W.IMPORTED_MODELS,token)
    end
end
counts=Test.get_test_counts(suite)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
