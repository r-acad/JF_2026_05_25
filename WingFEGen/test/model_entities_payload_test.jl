using Test, LinearAlgebra
using OpenJFEM
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen;const N=OpenJFEM
const OUT=isempty(ARGS) ? mktempdir(;cleanup=false) : abspath(ARGS[1]);mkpath(OUT)
const SOURCE="""
SOL 101
CEND
BEGIN BULK
GRID,11,,0.,0.,0.
GRID,12,,1.,0.,0.
GRID,21,,0.,1.,0.
GRID,22,,1.,1.,0.
GRID,31,,0.,2.,0.
GRID,32,,1.,2.,0.
GRID,41,,0.,3.,0.
GRID,42,,1.,3.,0.
GRID,43,,2.,3.,0.
GRID,51,,0.,4.,0.
GRID,52,,1.,4.,0.
GRID,61,,0.,5.,0.
GRID,62,,0.,5.,0.
GRID,71,,0.,6.,0.
GRID,81,,0.,7.,0.
GRID,82,,1.,7.,0.
GRID,83,,1.,8.,0.
GRID,84,,0.,8.,0.
GRID,101,,0.,-2.,-3.
GRID,102,,1.,-2.,-3.
GRID,103,,1.,-1.,-3.
GRID,104,,0.,-1.,-3.
CQUAD4,701,1,101,102,103,104
PSHELL,1,1,.01
MAT1,1,7.1E10,,.3,2700.
RBE2,201,11,123,12
RBAR,202,21,22,123,,,123
RBE1,203,31,123,UM,32,123
RSPLINE,204,.1,41,42,123,43
CELAS1,205,2,51,3,52,3
PELAS,2,2500.
CELAS2,206,5000.,61,2,62,2
CONM2,207,71,0,20.,.1,.2,.3
+,1.,0.,2.,0.,0.,3.
RBE3,208,,81,123456,1.,123,82,83
+,84
CORD2R,10,0,1.,2.,3.,1.,2.,4.
+,1.,3.,3.
CORD2C,20,10,2.,0.,0.,2.,0.,1.
+,3.,0.,0.
CORD2S,30,20,2.,90.,1.,2.,90.,2.
+,3.,90.,1.
GRID,501,10,0.,0.,0.
GRID,502,10,0.,0.,1.
GRID,503,10,1.,0.,0.
CORD1R,40,501,502,503
CORD1C,50,501,502,503
CORD1S,60,501,502,503
ENDDATA
"""
function fixture()
    source=W.imported_source(Dict("name"=>"coordinate_misc.bdf","text"=>SOURCE))
    cc,bulk=N.NastranParser.read_bulk_and_case(readlines(IOBuffer(SOURCE)));cards=N.NastranParser.process_cards(bulk)
    native=N.build_model(cards,cc);N.resolve_nested_coords!(native);N.transform_geometry!(native)
    model=W.imported_model(native,source,W.default_params();cards)
    W.imported_prepare_inventory!(N,model,cards,joinpath(OUT,"inventory.log"));W.imported_prepare_loads!(N,model)
    data=W.imported_mesh_payload(model);data["imported_deck"]["token"]="coordinate-misc-fixture"
    data["model_source"]=Dict(key=>source[key] for key in ("kind","name","text","includes"))
    model,native,data
end
tests=@testset "Coordinate and miscellaneous source payload" begin
    model,native,data=fixture();frames=Dict(row["id"]=>row for row in data["coordinate_systems"]["systems"])
    @test isempty(data["coordinate_systems"]["warnings"])
    @test Set(keys(frames))==Set([0,10,20,30,40,50,60])
    @test frames[10]["origin"]≈[1.,2.,3.]
    @test frames[10]["x"]≈[0.,1.,0.]
    @test frames[10]["y"]≈[-1.,0.,0.]
    @test frames[20]["origin"]≈[1.,4.,3.]
    @test frames[30]["origin"]≈[-1.,4.,4.]
    @test frames[30]["x"]≈[-1.,0.,0.]
    for (cid,type,card) in ((40,"RECTANGULAR","CORD1R"),(50,"CYLINDRICAL","CORD1C"),(60,"SPHERICAL","CORD1S"))
        @test frames[cid]["origin"]≈[1.,2.,3.]
        @test frames[cid]["x"]≈[0.,1.,0.]
        @test frames[cid]["type"]==type
        @test frames[cid]["card"]==card
        @test frames[cid]["properties"]["G1"]==501
    end
    records=Dict(row["eid"]=>row for group in data["imported_connections"] for row in group["elements"])
    @test Set(keys(records))==Set(201:207)
    @test records[202]["type"]=="RBAR"
    @test records[202]["properties"]["source_definition"]["CNA"]=="123"
    @test records[201]["properties"]["CM"]==123
    @test records[205]["properties"]["property"]["K"]==2500.
    @test records[207]["properties"]["M"]==20.
    @test records[207]["properties"]["X"]==[.1,.2,.3]
    @test only(data["rbe3"]["elements"])["source_definition"]["type"]=="RBE3"
    @test only(data["rbe3"]["elements"])["source_properties"]["REFC"]==123456
    write(joinpath(OUT,"payload.msgpack"),W.MsgPack.pack(data))
    @test W.MsgPack.unpack(read(joinpath(OUT,"payload.msgpack")))["coordinate_systems"]["systems"]==data["coordinate_systems"]["systems"]
    bad=deepcopy(native);bad["CORDs"]["99"]=Dict("TYPE"=>"UNSUPPORTED","Origin"=>[0.,0.,0.])
    rejected=W.imported_coordinate_payload(bad)
    @test length(rejected["warnings"])==1
    @test all(row->row["id"]!=99,rejected["systems"])
    # Synthetic existing shell-frame payload checks MCIDs without an expensive
    # aerodynamic solve; the frontend uses exactly these same frame buffers.
    group=Dict("kind"=>"quad","eids"=>W.blob_i32([71]),"axes"=>Dict("x"=>W.blob_f32([0.,1.,0.]),"y"=>W.blob_f32([-1.,0.,0.]),"z"=>W.blob_f32([0.,0.,1.])))
    generated=W.generated_coordinate_payload([group]);row=last(generated["systems"])
    @test row["id"]==71&&row["card"]=="CORD2R"
    @test row["origin"]==[0.,0.,0.]
    @test row["x"]==[0.,1.,0.]
    @test row["properties"]["Element ID"]==71
    write(joinpath(OUT,"schema.json"),W.JSON.json(W.schema_payload(W.default_params(),"coordinate_misc.toml")))
end
c=Test.get_test_counts(tests);write(joinpath(OUT,"payload-summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes)))
