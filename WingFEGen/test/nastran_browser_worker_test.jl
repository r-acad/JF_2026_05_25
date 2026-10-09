using Test
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
const OUT=get(ENV,"WINGFEGEN_IMPORT_TEST_OUTPUT",mktempdir(;cleanup=false))
mkpath(OUT)
const MIXED="""
SOL 101
CEND
SPC=1
LOAD=2
BEGIN BULK
GRID,11,,0.,0.,0.
GRID,25,,1.,0.,0.
GRID,38,,1.,1.,0.
GRID,49,,0.,1.,0.
GRID,60,,.5,.5,0.
CQUAD4,701,123,11,25,38,49
CTRIA3,702,123,11,25,38
PSHELL,123,8,.02,8,,8
MAT1,8,7.0E10,,.3,2700.
CBAR,801,92,11,25,0.,0.,1.
PBARL,92,8,,T
+,.04,.03,.004,.003
RBE3,901,,60,123456,1.,123,11,25
+,38,49
CONM2,902,60,0,10.,0.,0.,0.
+,1.,0.,1.,0.,0.,1.
SPC1,1,123456,11
FORCE,2,60,0,1.,0.,0.,1.
ENDDATA
"""
params=W.default_params();input=joinpath(OUT,"input.toml");write(input,W.params_to_toml(params))
st=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(OUT,"store"))
request(method,url,data=nothing)=W.HTTP.Request(method,url,["Content-Type"=>"application/json","X-Wing-Activity"=>"import-test"],data===nothing ? "" : W.JSON.json(data))
records=Any[]
function readdeck(raw,label)
    started=time();response=W.handle_import_nastran(st,request("POST","/api/import_nastran",raw));response.status==200||error(String(response.body))
    seconds=time()-started;data=W.MsgPack.unpack(response.body)
    data["import_timings"]=W.JSON.parse(W.HTTP.header(response,"X-Wing-Import-Timings"))
    write(joinpath(OUT,label*".msgpack"),response.body)
    push!(records,Dict("label"=>label,"seconds"=>seconds,"timings"=>data["import_timings"]))
    data
end
try
@testset "Local browser and import-only native worker" begin
    directory=joinpath(OUT,"files");mkpath(joinpath(directory,"subfolder"));write(joinpath(directory,"panel.bdf"),MIXED);write(joinpath(directory,"notes.txt"),"local notes");write(joinpath(directory,"second.dat"),MIXED)
    listing=W.imported_directory_listing(directory;limit=2)
    @test listing["entries"][1]["directory"]
    @test listing["total"]==3
    @test listing["next_offset"]==2
    @test only(W.imported_directory_listing(directory;offset=2)["entries"])["name"]=="second.dat"
    @test W.imported_directory_listing(directory;all_files=true)["total"]==4
    @test W.imported_directory_listing(joinpath(directory,"panel.bdf"))["directory"]==normpath(directory)
    @test_throws ArgumentError W.imported_directory_listing(joinpath(directory,"missing"))
    response=W.handle_import_nastran_browse(st,request("GET","/api/import_nastran/browse?path="*W.HTTP.escapeuri(directory)))
    @test response.status==200
    @test W.JSON.parse(String(response.body))["total"]==3
    if !isempty(ARGS)
        cold=readdeck(Dict("path"=>ARGS[1]),"actual-cold")
        warm=readdeck(Dict("path"=>ARGS[1]),"actual-warm")
        @test cold["nodes"]==warm["nodes"]
        @test cold["groups"]==warm["groups"]
        @test cold["load_cases"]==warm["load_cases"]
        @test cold["nodes"]["count"]>0
        @test warm["import_timings"]["worker_was_ready"]
    end
    mixed=readdeck(Dict("name"=>"mixed.bdf","text"=>MIXED),"mixed")
    @test Set(row["kind"] for row in mixed["groups"])==Set(["bar","quad","tria"])
    @test only(filter(row->row["kind"]=="bar",mixed["groups"]))["properties"]["section"]["shape"]=="T"
    @test mixed["rbe3"]["count"]==1
    @test mixed["imported_deck"]["card_inventory"]["CONM2"]==1
    @test mixed["nodes"]["xyz"] isa Vector{UInt8}
    @test only(mixed["loads"]["force_stations"])["gid"]==60
    @test st.model isa W.Model
    @test length(W.imported_native(st.model)["CONM2s"])==1
    # Opening Read Nastran starts one bounded preparation, independently of
    # browsing. Repeated polls must never launch another worker.
    prepared=W.AppState(dirname(@__DIR__),input;deck_store_dir=joinpath(OUT,"prepared-store"))
    response=W.handle_import_nastran_prepare(prepared,request("POST","/api/import_nastran/prepare"))
    @test response.status==200
    deadline=time()+180
    while time()<deadline
        status=W.JSON.parse(String(W.handle_import_nastran_prepare(prepared,request("GET","/api/import_nastran/prepare")).body))
        status["state"]=="ready"&&break
        status["state"]=="failed"&&error(status["stage"])
        sleep(.2)
    end
    status=W.JSON.parse(String(W.handle_import_nastran_prepare(prepared,request("GET","/api/import_nastran/prepare")).body))
    @test status["state"]=="ready"
    @test prepared.model===nothing
    push!(records,Dict("label"=>"preparation","seconds"=>status["seconds"],"timings"=>status["timings"]))
    if !isempty(ARGS)
        started=time();response=W.handle_import_nastran(prepared,request("POST","/api/import_nastran",Dict("path"=>ARGS[1])));response.status==200||error(String(response.body));elapsed=time()-started
        data=W.MsgPack.unpack(response.body);data["import_timings"]=W.JSON.parse(W.HTTP.header(response,"X-Wing-Import-Timings"));@test data["nodes"]==cold["nodes"]
        @test data["groups"]==cold["groups"]
        @test data["load_cases"]==cold["load_cases"]
        push!(records,Dict("label"=>"actual-after-preparation","seconds"=>elapsed,"timings"=>data["import_timings"]))
    end
    W.sensitivity_json_write(joinpath(OUT,"summary.json"),Dict("passed"=>true,"records"=>records))
end
finally
    for worker in values(W.IMPORT_WORKERS);process_running(worker.process)&&kill(worker.process);end
end
