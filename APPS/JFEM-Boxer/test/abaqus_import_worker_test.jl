# Exercises the production one-shot importer, not a mock endpoint or solver.
using Test
using WingFEGen;const W=WingFEGen
repo=normpath(joinpath(@__DIR__,"..","..",".."));app=normpath(joinpath(@__DIR__,".."))
const TEXT="""
*NODE
11,0,0,0
12,1,0,0
13,0,1,0
14,0,0,1
*ELEMENT,TYPE=C3D4,ELSET=BODY
51,11,12,13,14
*NSET,NSET=FIXED
11,12,13
*NSET,NSET=TIP
14
"""
const COMPLETION=Dict("enabled"=>true,"E"=>7e10,"nu"=>.3,"rho"=>2700.,"element_set"=>"ALL","constraint_set"=>"FIXED","constraint_dofs"=>"123","force_set"=>"TIP","force_direction"=>[0.,0.,-1.],"total_force"=>90.,"solution"=>"101","modes"=>3)
@testset "Production Abaqus importer worker keeps original source and runnable deck" begin
    mktempdir() do dir
        source=W.imported_source(Dict("name"=>"portable.inp.gz","text"=>TEXT,"format"=>"abaqus","completion"=>COMPLETION))
        W.Serialization.serialize(joinpath(dir,"input.jls"),(source,W.default_params()))
        script=joinpath(app,"src","reference_import_worker.jl")
        open(joinpath(dir,"worker.log"),"w") do output
            run(pipeline(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$repo $script $dir $repo $app`;stdout=output,stderr=output))
        end
        @test isfile(joinpath(dir,"done.txt"))&&!isfile(joinpath(dir,"error.json"))
        payload=W.MsgPack.unpack(read(joinpath(dir,"payload.msgpack")))
        @test payload["model_source"]["text"]==TEXT
        @test payload["model_source"]["format"]=="abaqus"
        @test payload["model_source"]["completion"]==COMPLETION
        @test payload["imported_deck"]["analysis_ready"]
        @test payload["solid_boundary"]["triangles"]["count"]==4
        @test payload["loads"]["force_stations"][1]["force"]==[0.,0.,-90.]
        model=W.Serialization.deserialize(joinpath(dir,"model.jls"))
        @test model.params["imported.native"]===nothing
        @test model.params["imported.analysis_deck"]!=TEXT
        @test startswith(model.params["imported.analysis_deck"],TEXT)
        @test occursin("*STATIC",model.params["imported.analysis_deck"])
        @test !haskey(model.params,"imported.analysis_native_pending")
        native=W.Serialization.deserialize(joinpath(dir,"native.jls"))
        @test native["abaqus_import"]["analysis_ready"]
        @test native["CSOLIDs"]["51"]["NODES"]==[11,12,13,14]
        @test native["SOL"]==101
        # Writing the run deck must remove only the compression suffix; the
        # captured source has already been decompressed and expanded.
        input=joinpath(dir,"input.toml");write(input,W.params_to_toml(W.default_params()))
        st=W.AppState(app,input;deck_store_dir=joinpath(dir,"cache"))
        path,_=W.imported_written_deck(st,model)
        @test basename(path)=="portable.inp"
        @test read(path,String)==model.params["imported.analysis_deck"]
    end
end
