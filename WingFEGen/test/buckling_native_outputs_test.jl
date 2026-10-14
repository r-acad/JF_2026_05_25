# Replay the native two-preload column regression, without assembling or solving.
using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
length(ARGS)==3||error("Usage: julia --project=. test/buckling_native_outputs_test.jl <two-preload-column.bdf> <native-output-root> <evidence-dir>")
const deckpath=abspath(ARGS[1]);const resultroot=abspath(ARGS[2]);const evidence=abspath(ARGS[3]);mkpath(evidence)
container=abspath(joinpath(@__DIR__,"..",".."));explicit=strip(get(ENV,"JFEM_SOLVER_SOURCE_ROOT",""))
candidates=isempty(explicit) ? [container,joinpath(container,"01_PUBLIC_PROJECT_REPOSITORY","JFEM")] : [abspath(explicit)]
parser=findfirst(root->isfile(joinpath(root,"src","parsing","ReferenceParser.jl")),candidates)
parser===nothing&&error("Set JFEM_SOLVER_SOURCE_ROOT to the JFEM repository root")
include(joinpath(candidates[parser],"src","parsing","ReferenceParser.jl"));const N=ReferenceParser
source_text=read(deckpath,String);_,bulk=N.read_bulk_and_case(String.(split(source_text,'\n')));cards=N.process_cards(bulk)
# This fixture has BASIC GRID positions. Node 2's output CD is deliberately
# non-BASIC; native JSON states BASIC_GLOBAL and must not be rotated twice.
subs=Dict(11=>Dict("LOAD"=>101),12=>Dict("LOAD"=>102),21=>Dict("STATSUB"=>11),22=>Dict("STATSUB"=>12))
native=Dict{String,Any}("SOL"=>105,"CASE_CONTROL"=>Dict("SUBCASES"=>subs),"GRIDs"=>N.extract_grid(cards["GRID"]),
    "CORDs"=>N.extract_coords(cards["CORD2R"]),"MATs"=>N.extract_mats(cards["MAT1"]),"CBARs"=>N.extract_cbar(cards["CBAR"]),
    "CBEAMs"=>N.extract_cbeam(cards["CBEAM"]),"PBARLs"=>N.extract_pbar(cards["PBAR"]),"SPC1s"=>N.extract_spc1(cards["SPC1"]))
source=W.imported_source(Dict("name"=>basename(deckpath),"text"=>source_text));model=W.imported_model(native,source,W.default_params();cards)
job(dir)=W.JfemJob("native-output-replay","",deckpath,dir,joinpath(dir,"log"),"",model,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
suite=@testset "Native SOL105 output bridge replay" begin
    payloads=Dict{String,Any}()
    for name in ("normal","compact","energy")
        dir=joinpath(resultroot,name);path,data=W.find_results_json(dir);@test path!==nothing
        @test data["coordinate_frame"]=="BASIC_GLOBAL"
        payload= W.imported_results_payload(job(dir));payloads[name]=payload
        buckling=filter(row->get(row,"buckling_subcase_id",0) in (21,22)&&get(row,"source","")!="buckling_preload",payload["load_cases"])
        @test sort([row["id"] for row in buckling])==[21,22]
        for row in buckling
            sid=row["id"];raw=filter(mode->mode["buckling_subcase_id"]==sid,data["modes"])
            @test row["available"]&&row["node_count"]==length(model.node_ids)
            @test row["static_subcase_id"]==subs[sid]["STATSUB"]
            if name=="compact"
                @test row["compact_buckling"]&&isempty(row["modes"])&&row["static"]===nothing
                @test !haskey(row,"variants")&&isempty(row["contours"])
                @test [mode["eigenvalue"] for mode in row["buckling_roots"]]==[mode["eigenvalue"] for mode in raw]
                @test [mode["peak_translation"] for mode in row["buckling_roots"]]==[mode["peak_translation"] for mode in raw]
            else
                @test !row["compact_buckling"]&&length(row["modes"])==3&&row["static"]!==nothing
                @test [mode["eigenvalue"] for mode in row["modes"]]==[mode["eigenvalue"] for mode in raw]
                @test length(row["variants"])==2
                if name=="energy"
                    @test all(length(mode["energy_contours"])==2 for mode in row["modes"])
                    @test length(row["preload_energy_contours"])==2
                    @test [contour["unit"] for contour in row["modes"][1]["energy_contours"]]==["force * length","force / length^2"]
                    state=only(filter(state->state["static_subcase_id"]==row["static_subcase_id"],data["static_subcases"]))
                    @test row["element_energy"]===nothing
                    @test collect(reinterpret(Float32,row["preload_energy_contours"][1]["values"].bytes))≈Float32[record["deformation_energy"] for record in state["element_energy"]["records"]]
                    @test occursin("Physical static",row["preload_energy_contours"][1]["note"])
                else
                    @test all(isempty(mode["energy_contours"]) for mode in row["modes"])
                end
            end
        end
        write(joinpath(evidence,name*"-results.msgpack"),W.MsgPack.pack(payload))
    end
    @test length(payloads["compact"]["load_cases"])==2
    @test length(payloads["energy"]["load_cases"])==4
    write(joinpath(evidence,"payload.msgpack"),W.MsgPack.pack(W.imported_mesh_payload(model)))
end
counts=Test.get_test_counts(suite);write(joinpath(evidence,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"source_results"=>resultroot),2))
