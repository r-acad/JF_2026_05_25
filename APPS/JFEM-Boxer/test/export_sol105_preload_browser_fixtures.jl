# Export browser fixtures from the completed synthetic sol105_preload_results_test.
# Usage: julia --project=<WingFEGen> this-file <preload-test-output> <fixture-directory>
# This reuses saved numerical results and never starts a new equilibrium solve.
using JSON, SHA, Test
length(ARGS)==2 || error("Usage: export_sol105_preload_browser_fixtures.jl <preload-test-output> <fixture-directory>")
const APP=normpath(joinpath(@__DIR__,".."))
push!(LOAD_PATH,APP)
include(joinpath(APP,"src","WingFEGen.jl")); const W=WingFEGen
repo,_=W.find_jfem(APP); push!(LOAD_PATH,repo)
include(joinpath(APP,"src","native_solver_loader.jl")); const N=load_cached_jfem(repo)
fixture=abspath(ARGS[1]); out=abspath(ARGS[2]); mkpath(out)
original=joinpath(fixture,"SOL105.bdf"); results=joinpath(fixture,"results")
resultpath,data=W.find_results_json(results)
resultpath===nothing && error("Run sol105_preload_results_test.jl to completion before exporting browser fixtures")
source_text=read(original,String); rows=Any[]
tests=@testset "Native and legacy preload presentation fixtures without a new solve" begin
    for legacy in (false,true)
        label=legacy ? "legacy" : "native"
        text=legacy ? replace(source_text,r"(?m)^\s*STATSUB\s*=\s*17\s*\r?\n"=>"") : source_text
        path=joinpath(out,label*"_source.bdf"); write(path,text)
        source=W.imported_source(Dict("name"=>label*"105.bdf","text"=>text))
        parsed=Base.invokelatest(N.bdf_to_model,path)
        model=W.imported_model(parsed,source,W.default_params())
        Base.invokelatest(W.imported_prepare_loads!,N,model)
        @test W.imported_buckling_ownership(data,parsed["CASE_CONTROL"]["SUBCASES"])==Dict(18=>17)
        legacy && (@test !haskey(parsed["CASE_CONTROL"]["SUBCASES"][18],"STATSUB"))
        job=W.JfemJob(label,"",path,results,joinpath(out,label*".log"),repo,model,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
        payload=W.imported_results_payload(job)
        @test Set(c["id"] for c in payload["load_cases"])==Set([17,18])
        direct=only(filter(c->c["id"]==17,payload["load_cases"]))
        buckling=only(filter(c->c["id"]==18,payload["load_cases"]))
        @test direct["source"]=="buckling_preload" && !isempty(direct["contours"])
        @test direct["static"]["disp"].bytes==first(buckling["variants"])["static"]["disp"].bytes
        @test length(last(buckling["variants"])["modes"])==length(data["modes"])
        write(joinpath(out,label*"_model.msgpack"),W.MsgPack.pack(W.imported_mesh_payload(model)))
        write(joinpath(out,label*"_results.msgpack"),W.MsgPack.pack(payload))
        push!(rows,Dict("scenario"=>label,"case_ids"=>[17,18],"source_sha256"=>bytes2hex(sha256(codeunits(text))),
            "legacy_fixture_note"=>legacy ? "Presentation-only metadata scenario: STATSUB omitted, saved solver preload ownership retained; no new solve or result values fabricated" : "Actual synthetic SOL105 source and saved native JSON"))
    end
end
cp(joinpath(fixture,"schema.json"),joinpath(out,"schema.json");force=true)
counts=Test.get_test_counts(tests)
write(joinpath(out,"fixture_receipt.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,
    "new_equilibrium_solves"=>0,"native_result_json"=>resultpath,"native_result_sha256"=>bytes2hex(sha256(read(resultpath))),
    "scenarios"=>rows,"script_sha256"=>bytes2hex(sha256(read(@__FILE__))))))
