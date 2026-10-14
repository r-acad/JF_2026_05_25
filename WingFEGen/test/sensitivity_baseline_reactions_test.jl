# Reuse the public synthetic sol105_preload_results_test.jl output. No solve.
# Usage: julia --project=<WingFEGen> this-file <preload-output> <evidence-dir>
using Test, JSON, SHA
length(ARGS) in (2,4)||error("Pass completed preload output and evidence directory; optionally a generated SOL106 study TOML and completed baseline directory")
const APP=normpath(joinpath(@__DIR__,".."))
push!(LOAD_PATH,APP)
include(joinpath(APP,"src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(APP);push!(LOAD_PATH,repo)
include(joinpath(APP,"src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
fixture,out=abspath.(ARGS[1:2]);mkpath(out)
deck=joinpath(fixture,"SOL105.bdf");path,data=W.find_results_json(joinpath(fixture,"results"))
path===nothing&&error("The completed synthetic SOL105 native JSON is required")
hashes=Dict(p=>bytes2hex(sha256(read(p))) for p in (deck,path))
# Make any accidental forward solve in this presentation regression fail loudly.
@eval N solve_model(model::Dict)=error("Reaction presentation must not run a new solve")
source=W.imported_source(Dict("name"=>"synthetic-preload.bdf","text"=>read(deck,String)))
parsed=Base.invokelatest(N.bdf_to_model,deck)
model=W.imported_model(parsed,source,W.default_params())
Base.invokelatest(W.imported_prepare_loads!,N,model)
directory=joinpath(out,"sensitivity_retained_105");mkpath(directory)
metadata=Dict{String,Any}("solution"=>"105","case_id"=>17,"case_label"=>"Original physical load", "seconds"=>0.)
tests=@testset "Physical reactions and sensitivity buckling preload reuse" begin
 payload=W.sensitivity_baseline_payload(model,model,data,path,directory,metadata)
 item=only(payload["load_cases"]);preload,buckling=item["variants"]
 @test item["default_variant"]=="sensitivity_sensitivity_retained_105_sol105"
 @test item["analysis_variants"]==["sensitivity_sensitivity_retained_105_sol101",item["default_variant"]]
 @test preload["source"]==buckling["source"]=="sensitivity_baseline"
 @test preload["physical_case_id"]==buckling["physical_case_id"]==17
 @test preload["baseline_role"]=="buckling_preload"
 @test preload["static_subcase_id"]==17
 @test buckling["native_subcase_id"]==18
 @test isempty(preload["modes"])&&!isempty(buckling["modes"])
 @test preload["analysis_type"]=="SOL101_STATIC"
 @test !isempty(preload["contours"])
 @test preload["reactions"]["available"]
 actual=only(data["static_subcases"])["static_result"]
 expected=W.support_reactions_payload(model,actual)
 @test preload["reactions"]["forces"].bytes==expected["forces"].bytes
 @test preload["reactions"]["moments"].bytes==expected["moments"].bytes
 @test buckling["reactions"]["forces"].bytes==preload["reactions"]["forces"].bytes
 @test item["reactions"]["forces"].bytes==preload["reactions"]["forces"].bytes
 @test W.MsgPack.unpack(W.MsgPack.pack(payload))["load_cases"][1]["variants"][1]["reactions"]["count"]==expected["count"]
 @test !W.support_reactions_payload(model,Dict())["available"]
 @test !W.support_reactions_payload(model,Dict("spc_forces"=>Any[]))["available"]
 suppressed=W.support_reactions_payload(model,merge(copy(actual),Dict("result_requests"=>Dict("SPCFORCES"=>false))))
 @test !suppressed["available"]&&occursin("suppressed",suppressed["reason"])
 zero=deepcopy(actual)
 for row in zero["spc_forces"],key in ("t1","t2","t3","r1","r2","r3");row[key]=0.;end
 @test W.support_reactions_payload(model,zero)["available"] # A solved zero is valid.
 ambiguous=deepcopy(data);push!(ambiguous["static_subcases"],deepcopy(first(ambiguous["static_subcases"])))
 @test_throws ArgumentError W.sensitivity_baseline_payload(model,model,ambiguous,path,directory,metadata)
 @test all(bytes2hex(sha256(read(p)))==hash for (p,hash) in hashes)
 # Browser presentation fixtures only; retained native numerical files stay immutable.
 payload["compatibility"]=Dict("map_allowed"=>true,"is_current"=>true)
 write(joinpath(out,"baseline_results.msgpack"),W.MsgPack.pack(payload))
 write(joinpath(out,"model.msgpack"),W.MsgPack.pack(W.imported_mesh_payload(model)))
 write(joinpath(out,"schema.json"),W.JSON.json(W.schema_payload(W.default_params(),"synthetic-preload.toml")))
 job=W.JfemJob("retained","",deck,joinpath(fixture,"results"),joinpath(out,"read.log"),repo,model,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
 write(joinpath(out,"ordinary_results.msgpack"),W.MsgPack.pack(W.imported_results_payload(job)))
 if length(ARGS)==4
  parameters=W.read_input(abspath(ARGS[3]));generated=W.build_model(parameters)
  retained=abspath(ARGS[4]);nativepath=joinpath(retained,"baseline_native.json")
  native=JSON.parsefile(nativepath);meta=W.sensitivity_baseline_metadata(retained)
  @test meta["solution"]=="106"
  nonlinear=W.sensitivity_baseline_payload(generated,generated,native,nativepath,retained,meta)
  @test nonlinear["available"]&&nonlinear["convergence"]["full_load"]
  @test nonlinear["reactions"]["available"]&&nonlinear["reactions"]["count"]>0
  expected_nl=W.support_reactions_payload(generated,native)
  @test nonlinear["reactions"]["forces"].bytes==expected_nl["forces"].bytes
  @test nonlinear["reactions"]["moments"].bytes==expected_nl["moments"].bytes
  write(joinpath(out,"nonlinear_model.msgpack"),W.MsgPack.pack(W.mesh_payload(generated)))
  write(joinpath(out,"nonlinear_results.msgpack"),W.MsgPack.pack(nonlinear))
  write(joinpath(out,"nonlinear_schema.json"),W.JSON.json(W.schema_payload(parameters,abspath(ARGS[3]))))
  hashes[nativepath]=bytes2hex(sha256(read(nativepath)))
 end
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes,"new_forward_solves"=>0,"input_sha256"=>hashes)))
