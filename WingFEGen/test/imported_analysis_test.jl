using Test
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
out=isempty(ARGS) ? mktempdir() : abspath(ARGS[1]);mkpath(out)
const DECK="""
SOL 101
CEND
TITLE = Preserved imported cantilever
DISPLACEMENT(PRINT) = ALL
SPCFORCES(PRINT) = ALL
SUBCASE 17
 LABEL = Original load case
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
FORCE,4,38,0,100.,0.,0.,1.
FORCE,4,25,0,1000.,-1.,0.,0.
FORCE,4,38,0,1000.,-1.,0.,0.
MOMENT,4,25,0,1.,0.,1.,0.
EIGRL,41,,,2
PARAM,K6ROT,100.
ENDDATA
"""
report=Dict{String,Any}();started=time()
suite=@testset "Imported analysis source-preserving overlays" begin
 source=W.imported_source(Dict("name"=>"cantilever.bdf","text"=>DECK))
 input=joinpath(out,"original.bdf");write(input,DECK)
 native=Base.invokelatest(N.bdf_to_model,input);m=W.imported_model(native,source,W.default_params())
 Base.invokelatest(W.imported_prepare_loads!,N,m)
 @test W.imported_analysis_model(m)===m
 @test W.imported_analysis_signature(m)==source["signature"]
 @test_throws ArgumentError W.imported_analysis_model(m,Dict("solution"=>"103","follower"=>"force"))
 @test_throws ArgumentError W.imported_analysis_model(m,Dict("solution"=>"108"))
 @test_throws ArgumentError W.imported_analysis_model(m,Dict("modes"=>.5))
 for sol in ("101","103","105","106")
  options=Dict("solution"=>sol,"follower"=>"fixed","modes"=>2,"load_steps"=>2,"buckling_max_factor"=>1e9)
  variant=W.imported_analysis_model(m,options);text=variant.params["imported.analysis_deck"]
  @test variant.xyz===m.xyz&&variant.groups===m.groups
  @test m.params["imported.source"]["flattened"]==DECK
  @test !haskey(m.params,"imported.analysis")
  @test W.imported_analysis_signature(variant)!=source["signature"]
  @test occursin("SPC1,2,123456,11,49",text)&&occursin("MOMENT,4,25,0,1.,0.,1.,0.",text)
  path=joinpath(out,"SOL$sol.bdf");write(path,text)
  parsed=Base.invokelatest(N.bdf_to_model,path)
  @test parsed["SOL"]==parse(Int,sol)
  @test parsed["GRIDs"]==native["GRIDs"]&&parsed["CSHELLs"]==native["CSHELLs"]&&parsed["PSHELLs"]==native["PSHELLs"]
  @test parsed["CASE_CONTROL"]["SUBCASES"][17]["SPC"]==2
  @test parsed["CASE_CONTROL"]["SUBCASES"][17]["LOAD"]==4
  @test parsed["SPC1s"]==native["SPC1s"]
  expected=sol=="105" ? 18 : 17
  @test variant.params["imported.analysis_cases"][17]==expected
  @test W.imported_native(variant)["CASE_CONTROL"]["SUBCASES"][expected]["SPC"]==2
  if sol in ("103","105");@test parsed["CASE_CONTROL"]["SUBCASES"][expected]["METHOD"]==42;end
  if sol=="105";@test parsed["CASE_CONTROL"]["SUBCASES"][18]["STATSUB"]==17;end
  @test native["SOL"]==101
  # Real native assembly, solve and recovery, not a mocked return code.
  result=Base.invokelatest(N.solve_model,parsed)
  exportdir=joinpath(out,"results_SOL$sol");mkpath(exportdir)
  Base.invokelatest(N.export_results,result,basename(path),exportdir;export_json=true,export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
  job=W.JfemJob("test", "",path,exportdir,joinpath(exportdir,"log"),repo,variant,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
  payload=W.imported_results_payload(job)
  @test only(payload["load_cases"])["id"]==17
  @test payload["available"]===true
  @test payload["imported_analysis_signature"]==W.imported_analysis_signature(variant)
  @test payload["imported_analysis"]["solution"]==sol
  report[sol]=Dict("analysis_type"=>get(result,"analysis_type",""),"timings"=>get(result,"timings",Dict()),"keys"=>sort!(collect(keys(result))))
  @test haskey(result,"model")
 end
 for sol in ("101","106")
  variant=W.imported_analysis_model(m,Dict("solution"=>sol,"follower"=>"force","load_steps"=>2))
  path=joinpath(out,"SOL$(sol)_follower.bdf");write(path,variant.params["imported.analysis_deck"])
  parsed=Base.invokelatest(N.bdf_to_model,path)
  @test parsed["PARAM_JFFOLLOW"]==1
  @test all(force->force["FLLW"]=="ROT",parsed["FORCEs"])
  @test parsed["MOMENTs"]==native["MOMENTs"]
  @test !haskey(native,"PARAM_JFFOLLOW")||native["PARAM_JFFOLLOW"]!=1
  result=Base.invokelatest(N.solve_model,parsed)
  report[sol*"_follower"]=Dict("analysis_type"=>get(result,"analysis_type",""),"timings"=>get(result,"timings",Dict()))
  @test haskey(result,"model")
 end
 # Routing uses the retained facade without build_model, native restoration or
 # solver execution. An invalid source handle must fail, not build a wing.
 token="test-imported-analysis";W.IMPORTED_MODELS[token]=m
 raw=Dict("model_kind"=>"nastran","imported_deck"=>Dict("token"=>token,"signature"=>source["signature"],"analysis"=>Dict("solution"=>"103")))
 @test W.request_imported_model(raw).params["output.solution"]=="103"
 @test_throws ArgumentError W.request_imported_model(Dict("model_kind"=>"nastran"))
 @test_throws ArgumentError W.request_imported_model(Dict("imported_deck"=>Dict("token"=>token,"signature"=>"wrong")))
 delete!(W.IMPORTED_MODELS,token)
end
report["seconds"]=time()-started;report["passed"]=true
write(joinpath(out,"summary.json"),W.JSON.json(report))
