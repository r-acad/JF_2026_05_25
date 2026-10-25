using Test, WingFEGen, JSON, TOML
const W=WingFEGen
@testset "Report alloys: editable materials with preserved source values" begin
    presets=W.report_alloy_presets()
    @test length(presets)==2
    @test [r["E"] for r in presets]==[76e9,73.1e9]
    @test [r["rho"] for r in presets]==[2810.,2780.]
    @test [r["reference_data"]["compression_proof_Pa"] for r in presets]==[487e6,342e6]
    @test [r["reference_data"]["fn_Pa"] for r in presets]==[444e6,301e6]
    library=vcat(W.default_material_library(),[merge(row,Dict("id"=>i+4)) for (i,row) in enumerate(presets)])
    p,_=W.normalize_params(Dict("materials.library"=>library))
    @test W.material_definition(p,5)["E"]==76e9
    @test W.material_definition(p,6)["E"]==73.1e9
    @test W.material_allowable(p,5)===nothing
    @test W.material_allowable(p,6)["stress"]==300e6 # existing design default, not fn/UTS
    for saved in (JSON.parse(JSON.json(p)),W.flatten_toml(TOML.parse(W.params_to_toml(p))))
        loaded,unknown=W.normalize_params(saved)
        @test isempty(unknown)
        @test loaded["materials.library"]==p["materials.library"]
        mat=W.material_payload(W.material_definition(loaded,5))
        @test mat["reference_data"]["ultimate_tensile_Pa"]==572e6
        @test mat["reference_data"]["shear_Pa"]==331e6
        @test mat["reference_data"]["m"]==22.2
    end
    edited=deepcopy(library);last(edited)["E"]=72e9
    normalized=W.normalize_material_library(edited)
    @test last(normalized)["E"]==72e9
    @test last(normalized)["reference_data"]==last(presets)["reference_data"]
    bad=deepcopy(library);last(bad)["reference_data"]["fn_Pa"]=-1
    @test_throws ArgumentError W.normalize_material_library(bad)
end
