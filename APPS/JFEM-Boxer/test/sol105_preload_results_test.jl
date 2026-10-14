using Test, SparseArrays
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
repo,_=W.find_jfem(dirname(@__DIR__));push!(LOAD_PATH,repo)
include(joinpath(@__DIR__,"..","src","native_solver_loader.jl"));const N=load_cached_jfem(repo)
out=isempty(ARGS) ? mktempdir() : abspath(ARGS[1]);mkpath(out)
const DECK="""
SOL 101
CEND
TITLE = Preserved imported preload
DISPLACEMENT(PRINT) = ALL
SPCFORCES(PRINT) = ALL
STRESS(PRINT) = ALL
FORCE(PRINT) = ALL
STRAIN(PRINT) = ALL
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
# This diagnostic dispatch counts real equilibrium calls, then invokes the
# unchanged generic implementation. Export must not add another solve.
@eval N.Solver begin
 const PRELOAD_EXPORT_SOLVE_CALLS=Ref(0)
 function solve_case(K::SparseMatrixCSC,ndof,model,id_map,X,load_id,spc_id,node_R;kwargs...)
  PRELOAD_EXPORT_SOLVE_CALLS[]+=1
  invoke(solve_case,Tuple{Any,Any,Any,Any,Any,Any,Any,Any},K,ndof,model,id_map,X,load_id,spc_id,node_R;kwargs...)
 end
end
report=Dict{String,Any}();started=time()
@testset "SOL105 reuses actual static preload as SOL101 result" begin
 source=W.imported_source(Dict("name"=>"preload.bdf","text"=>DECK));input=joinpath(out,"original.bdf");write(input,DECK)
 native=Base.invokelatest(N.bdf_to_model,input);m=W.imported_model(native,source,W.default_params())
 Base.invokelatest(W.imported_prepare_loads!,N,m)
 baseline=Base.invokelatest(N.solve_model,native)
 baseline_calls=N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]
 variant=W.imported_analysis_model(m,Dict("solution"=>"105","follower"=>"fixed","modes"=>2,"buckling_max_factor"=>1e9))
 path=joinpath(out,"SOL105.bdf");write(path,variant.params["imported.analysis_deck"])
 parsed=Base.invokelatest(N.bdf_to_model,path);result=Base.invokelatest(N.solve_model,parsed)
 @test N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]==baseline_calls+1
 @test !haskey(result,"static_results_by_subcase")
 exportdir=joinpath(out,"results");mkpath(exportdir)
 Base.invokelatest(N.export_results,result,basename(path),exportdir;export_json=true,export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
 @test N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]==baseline_calls+1
 data=Base.invokelatest(N._sol105_static_results!,result,17)
 @test Base.invokelatest(N._sol105_static_results!,result,17)===data
 @test data["analysis_type"]=="SOL101_STATIC"
 @test data["coordinate_frame"]=="BASIC_GLOBAL"
 @test sort([r["grid_id"] for r in data["displacements"]])==[11,25,38,49]
 @test !isempty(data["stresses"]["quad4"])
 @test !isempty(data["forces"]["quad4"])
 @test !isempty(data["spc_forces"])
 @test all(r->r["grid_id"] in (11,49),data["spc_forces"])
 @test !haskey(data,"raw_residual_analysis")
 _,exported=W.find_results_json(exportdir)
 @test only(exported["static_subcases"])["static_subcase_id"]==17
 @test haskey(only(exported["static_subcases"]),"static_result")
 @test all(values(only(exported["static_subcases"])["static_result"]["result_requests"]))
 job=W.JfemJob("test","",path,exportdir,joinpath(exportdir,"log"),repo,variant,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
 payload=W.imported_results_payload(job);case=only(payload["load_cases"])
 @test case["id"]==17
 @test case["default_variant"]=="sol105"
 @test case["analysis_variants"]==["sol101","sol105"]
 preload,buckling=case["variants"]
 @test preload["id"]=="sol101"&&buckling["id"]=="sol105"
 @test preload["available"]&&buckling["available"]
 @test preload["static"]!==nothing
 @test !isempty(preload["contours"])
 @test !isempty(preload["element_results"])
 @test preload["static_subcase_id"]==17
 @test preload["native_subcase_id"]==17
 @test buckling["native_subcase_id"]==18
 @test all(!startswith(key,"imported.") for key in keys(preload["model_params"]))
 @test preload["analysis_type"]=="SOL101_STATIC"
 @test preload["mode_kind"]=="none"
 @test !isempty(buckling["modes"])
 @test N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]==baseline_calls+1
 write(joinpath(out,"model.msgpack"),W.MsgPack.pack(W.imported_mesh_payload(variant)))
 write(joinpath(out,"results.msgpack"),W.MsgPack.pack(payload))
 write(joinpath(out,"schema.json"),W.JSON.json(W.schema_payload(W.default_params(),"synthetic-preload.toml")))
 # Compare complete static fields with an independent ordinary SOL101 solve.
 baseline_dir=joinpath(out,"baseline");mkpath(baseline_dir)
 Base.invokelatest(N.export_results,baseline,"SOL101.bdf",baseline_dir;export_json=true,export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
 _,baseline_json=W.find_results_json(baseline_dir)
 function compare_records(a,b)
  @test keys(a)==keys(b)
  for key in keys(a)
   x,y=a[key],b[key]
   if x isa Number&&y isa Number;@test isapprox(x,y;rtol=1e-8,atol=1e-10)
   elseif x isa AbstractDict;compare_records(x,y)
   elseif x isa AbstractVector
    @test length(x)==length(y)
    for (xx,yy) in zip(x,y)
     if xx isa AbstractDict;compare_records(xx,yy)
     elseif xx isa Number;@test isapprox(xx,yy;rtol=1e-8,atol=1e-10)
     else;@test xx==yy;end
    end
   else;@test x==y;end
  end
 end
 for key in ("displacements","spc_forces","forces","forces_bilin","stresses","strains")
  compare_records(Dict(key=>data[key]),Dict(key=>baseline_json[key]))
 end
 # Requests on the static subcase apply to its SOL101-compatible export.
 control=result["model"]["CASE_CONTROL"]["SUBCASES"][17];saved_control=copy(control)
 for key in ("DISPLACEMENT","SPCFORCES","FORCE","STRESS","STRAIN");control[key]="NONE";end
 filtered_dir=joinpath(out,"filtered_requests");mkpath(filtered_dir)
 Base.invokelatest(N.export_results,result,basename(path),filtered_dir;export_json=true,export_vtk=false,export_hdf5=false,export_jfem_binary=false,export_report=false)
 _,filtered=W.find_results_json(filtered_dir);filtered_state=only(filtered["static_subcases"])
 @test isempty(filtered_state["static_result"]["displacements"])
 @test isempty(filtered_state["static_result"]["spc_forces"])
 @test all(isempty,values(filtered_state["static_result"]["stresses"]))
 @test all(isempty,values(filtered_state["static_result"]["forces"]))
 @test all(isempty,values(filtered_state["static_result"]["strains"]))
 @test !isempty(filtered_state["static_displacements"])
 @test !isempty(data["stresses"]["quad4"]) # Export did not erase the raw cached recovery.
 empty!(control);merge!(control,saved_control)
 filtered_job=W.JfemJob("filtered","",path,filtered_dir,joinpath(filtered_dir,"log"),repo,variant,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
 filtered_case=only(W.imported_results_payload(filtered_job)["load_cases"]);filtered_preload=first(filtered_case["variants"])
 @test filtered_preload["available"]
 @test filtered_preload["static"]["disp"].bytes==preload["static"]["disp"].bytes
 @test isempty(filtered_preload["contours"])
 @test !any(values(filtered_preload["result_requests"]))
 # Legacy exports may have only the actual retained preload displacement.
 legacy=deepcopy(exported);delete!(only(legacy["static_subcases"]),"static_result")
 legacy["static_result"]=Dict("static_subcase_id"=>999,"displacements"=>Any[])
 selected=W.imported_case_result(legacy,18,Dict(17=>Dict(),18=>Dict("STATSUB"=>17)),[18])
 @test !haskey(selected,"static_result") # Never inherit stale top-level fields.
 legacy_case=Dict{String,Any}("id"=>17,"static_subcase_id"=>17,"buckling_subcase_id"=>18,"summary"=>Any[],"model_params"=>Dict("output.solution"=>"105"))
 W.attach_buckling_preload!(job,path,legacy_case,selected,17)
 @test first(legacy_case["variants"])["static"]["disp"].bytes==preload["static"]["disp"].bytes
 @test isempty(first(legacy_case["variants"])["contours"])
 @test any(row->first(row)=="Legacy results",first(legacy_case["variants"])["summary"])
 @test_throws ArgumentError W.attach_buckling_preload!(job,path,copy(legacy_case),merge(selected,Dict("static_result"=>Dict("static_subcase_id"=>999))),17)
 generated_selected=W.buckling_case_result(legacy,9,1) # Generated physical case9 uses native17/18.
 @test !haskey(generated_selected,"static_result")
 @test generated_selected["static_displacements"]==selected["static_displacements"]
 partial_source=deepcopy(only(exported["static_subcases"])["static_result"])
 partial_source["recovery_diagnostics"]=Dict("status"=>"partial","unavailable_shell_eids"=>[701],"reason"=>"Synthetic unavailable recovery metadata")
 partial_source["stresses"]=Dict("quad4"=>Any[]);partial_case=copy(legacy_case)
 W.attach_buckling_preload!(job,path,partial_case,merge(selected,Dict("static_result"=>partial_source)),17)
 @test first(partial_case["variants"])["recovery_diagnostics"]["unavailable_shell_eids"]==[701]
 @test any(row->first(row)=="Partial field recovery",first(partial_case["variants"])["summary"])
 @test first(partial_case["variants"])["static"]["disp"].bytes==preload["static"]["disp"].bytes
 @test all(!haskey(variant,"variants") for variant in partial_case["variants"])
 @test all(!haskey(variant,"default_variant") for variant in partial_case["variants"])
 @test N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]==baseline_calls+1
 # A native SOL105 source exposes the preload under its original Loads case,
 # as well as inside the buckling case's analysis selector.
 native_source=W.imported_source(Dict("name"=>"native105.bdf","text"=>read(path,String)))
 native_model=W.imported_model(parsed,native_source,W.default_params())
 Base.invokelatest(W.imported_prepare_loads!,N,native_model)
 native_job=W.JfemJob("native105","",path,exportdir,joinpath(exportdir,"log"),repo,native_model,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
 native_cases=W.imported_results_payload(native_job)["load_cases"]
 @test Set(c["id"] for c in native_cases)==Set([17,18])
 static_case=only(filter(c->c["id"]==17,native_cases))
 @test static_case["source"]=="buckling_preload"
 @test static_case["analysis_type"]=="SOL101_STATIC"
 @test static_case["static"]["disp"].bytes==preload["static"]["disp"].bytes
 @test !isempty(static_case["contours"])
 @test !haskey(static_case,"variants")
 # The solver records its actual legacy local-METHOD preload resolution.
 legacy_subs=Dict(17=>Dict("LOAD"=>4),18=>Dict("METHOD"=>41))
 @test W.imported_buckling_ownership(exported,legacy_subs)==Dict(18=>17)
 @test W.imported_case_result(exported,18,legacy_subs,[18])["static_displacements"]==exported["static_displacements"]
 empty_modes=deepcopy(exported);empty!(empty_modes["modes"])
 @test W.imported_buckling_ownership(empty_modes,legacy_subs)==Dict(18=>17)
 bad_ownership=deepcopy(exported);bad_ownership["subcases"][1]["static_subcase_id"]=18
 @test_throws ArgumentError W.imported_buckling_ownership(bad_ownership,legacy_subs)
 @test_throws ArgumentError W.imported_buckling_ownership(exported,Dict(17=>Dict(),18=>Dict("STATSUB"=>18)))
 @test N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]==baseline_calls+1
 report["equilibrium_calls"]=N.Solver.PRELOAD_EXPORT_SOLVE_CALLS[]
 report["native_static_subcase_id"]=17;report["native_buckling_subcase_id"]=18
 report["variants"]=[v["id"] for v in case["variants"]]
 report["source_preserved"]=m.params["imported.source"]["flattened"]==DECK
 @test report["source_preserved"]
end
report["seconds"]=time()-started;report["passed"]=true
write(joinpath(out,"summary.json"),W.JSON.json(report))
