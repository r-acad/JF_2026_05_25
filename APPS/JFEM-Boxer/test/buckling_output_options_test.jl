using Test
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
length(ARGS)==2||error("Usage: julia --project=. test/buckling_output_options_test.jl <evidence-dir> <fixture-dir>")
const evidence=abspath(ARGS[1]);const fixtures=abspath(ARGS[2]);mkpath(evidence);mkpath(fixtures)
const flags=("buckling_energy_density","buckling_deformation_energy","buckling_compact")
p=merge(W.default_params(),Dict("box.rib_pitch"=>10.,"box.stringer_pitch"=>1.,"mesh.elements_between_ribs"=>1,"output.solution"=>"105"))
m=W.build_model(p)
modelparams(params)=W.Model((field===:params ? params : getfield(m,field) for field in fieldnames(W.Model))...)
job(model,dir)=W.JfemJob("output-test","",joinpath(fixtures,"generated.bdf"),dir,joinpath(dir,"log"),"",model,nothing,String[],ReentrantLock(),0.,0.,:done,0,"")
peak=Dict("magnitude"=>1.,"relative_tolerance"=>1e-6,"nodes"=>[Dict("node_id"=>last(m.node_ids),"property_ids"=>[10,20],"element_ids"=>[1,2])],"property_ids"=>[10,20],"normalization"=>"solver eigenvector; arbitrary amplitude")
compact=Dict{String,Any}("analysis_type"=>"SOL105_BUCKLING","output_options"=>Dict("compact"=>true,"energy_density"=>false,"deformation_energy"=>false),
    "mode_shape_status"=>"omitted_compact","eigenvalues"=>[11.,22.],"modes"=>[
        Dict("mode_number"=>1,"eigenvalue"=>11.,"static_subcase_id"=>1,"buckling_subcase_id"=>2,"peak_translation"=>peak),
        Dict("mode_number"=>2,"eigenvalue"=>22.,"static_subcase_id"=>3,"buckling_subcase_id"=>4,"peak_translation"=>peak)],
    "static_subcases"=>[Dict("static_subcase_id"=>1),Dict("static_subcase_id"=>3)])
suite=@testset "Saved SOL105 output requests and compact result bridge" begin
    @test all(!p["output."*key] for key in flags)
    @test !occursin("JFBK",sprint(W.write_deck,m))
    for selected in (flags,(flags[1],),(flags[2],),(flags[3],))
        params=merge(p,Dict("output."*key=>true for key in selected));variant=modelparams(params)
        deck=sprint(W.write_deck,variant)
        @test occursin("ESE(PLOT) = ALL",deck)==any(key in selected for key in flags[1:2])
        @test occursin("PARAM,JFBKCOMP,1",deck)==("buckling_compact" in selected)
        @test !occursin("JFBKENG",deck) && !occursin("JFBKDEN",deck)
        restored=W.normalize_params(W.flatten_toml(W.TOML.parse(W.params_to_toml(params))))[1]
        @test restored["output.buckling_deformation_energy"]==any(params["output."*key] for key in flags[1:2])
        @test !restored["output.buckling_energy_density"]
        @test restored["output.buckling_compact"]==params["output.buckling_compact"]
        @test !occursin("JFBK",sprint(W.write_deck,modelparams(merge(params,Dict("output.solution"=>"103")))))
    end
    source_text="SOL 105\nCEND\nESE = 31\nSET 31 = 101,\n102\nSUBCASE 1\n LOAD = 1\n ESE = NONE\nSUBCASE 2\n STATSUB = 1\n METHOD = 7\nBEGIN BULK\nGRID,1,,0.,0.,0.\nEIGRL,7,1.e-6,70.,5\nPARAM,JFBKCOMP,1\nENDDATA\n"
    source=W.imported_source(Dict("name"=>"source.bdf","text"=>source_text))
    @test W.imported_source_case_control(Dict("flattened"=>"CEND\nSET   32 = 101\n102\nBEGIN BULK\n"))["globals"]["SET 32"]=="101,102"
    @test W.imported_source_case_control(Dict("flattened"=>"CEND\nESE(PLOT,THRESH=0.)=ALL\nBEGIN BULK\n"))["globals"]["ESE"]=="ALL"
    imported=modelparams(merge(p,Dict("imported.source"=>source,"imported.native"=>Dict{String,Any}("CASE_CONTROL"=>Dict("SUBCASES"=>Dict(1=>Dict("LOAD"=>1),2=>Dict("STATSUB"=>1)))),
        "imported.cases"=>[Dict("id"=>1,"label"=>"Preload"),Dict("id"=>2,"label"=>"Buckling")])) )
    @test W.imported_analysis_model(imported)===imported
    @test_throws ArgumentError W.imported_analysis_options(Dict("buckling_compact"=>1))
    options=Dict("buckling_output_override"=>true,"buckling_energy_density"=>true)
    overlaid=W.imported_analysis_model(imported,options);deck=overlaid.params["imported.analysis_deck"]
    @test occursin("ESE(PLOT) = ALL",deck)&&occursin("PARAM,JFBKCOMP,0",deck)
    @test !occursin("JFBKENG",deck)&&!occursin("JFBKDEN",deck)&&!occursin("ESE = NONE",deck)
    @test !occursin("PARAM,JFBKCOMP,1",deck)
    @test occursin("EIGRL,7,1.e-6,70.,5",deck)
    @test !occursin("DISPLACEMENT(PRINT)",deck)
    @test imported.params["imported.source"]["flattened"]==source_text
    restored_options=W.JSON.parse(W.JSON.json(overlaid.params["imported.analysis"]))
    @test W.imported_analysis_options(restored_options)==overlaid.params["imported.analysis"]
    alloff=W.imported_analysis_model(imported,Dict("buckling_output_override"=>true))
    @test occursin("ESE(PLOT) = NONE",alloff.params["imported.analysis_deck"])
    @test occursin("PARAM,JFBKCOMP,0",alloff.params["imported.analysis_deck"])
    @test W.imported_native(overlaid)["CASE_CONTROL"]["ESE"]=="ALL"
    @test W.imported_native(overlaid)["PARAM_JFBKCOMP"]==0
    write(joinpath(fixtures,"source.bdf"),source_text);write(joinpath(fixtures,"imported_energy_override.bdf"),deck)
    enabled=modelparams(merge(p,Dict("output."*key=>true for key in flags)))
    write(joinpath(fixtures,"generated.bdf"),sprint(W.write_deck,enabled));write(joinpath(fixtures,"generated.toml"),W.params_to_toml(enabled.params))
    # Prepare immutable worker snapshots without launching any solver process.
    workerparams=merge(enabled.params,Dict("jfem.output_dir"=>joinpath(evidence,"worker_snapshots"),"loads.cases"=>[Dict("id"=>2,"label"=>"Second case")]))
    workerparent=W.prepare_jfem_case_jobs(modelparams(workerparams),workerparams,dirname(@__DIR__),joinpath(fixtures,"generated.bdf"),"outputs")
    @test length(workerparent.runs)==2
    @test all(child.proc===nothing&&occursin("ESE(PLOT) = ALL",read(child.bdf,String))&&occursin("PARAM,JFBKCOMP,1",read(child.bdf,String)) for child in workerparent.runs)
    importedparams=merge(overlaid.params,Dict("jfem.output_dir"=>joinpath(evidence,"worker_snapshots")))
    importedworker=W.prepare_jfem_job(modelparams(importedparams),importedparams,dirname(@__DIR__),joinpath(fixtures,"imported_energy_override.bdf"),"imported_outputs")
    @test importedworker.proc===nothing&&read(importedworker.bdf,String)==deck
    @test !W.compact_buckling_output(Dict("output_options"=>nothing))
    resultdir=joinpath(evidence,"compact");mkpath(resultdir);write(joinpath(resultdir,"test.BUCKLING.JSON"),W.JSON.json(compact))
    path,data=W.find_results_json(resultdir);@test path!==nothing && data["mode_shape_status"]=="omitted_compact"
    for (case,value) in ((1,11.),(2,22.))
        selected=W.buckling_case_result(data,case,2)
        payload=W.jfem_case_results_payload(job(m,resultdir),path,selected)
        @test payload["available"] && payload["compact_buckling"]
        @test isempty(payload["modes"]) && payload["static"]===nothing && isempty(payload["contours"])
        @test only(payload["buckling_roots"])["eigenvalue"]==value
        @test only(payload["buckling_roots"])["peak_translation"]==peak
        @test occursin("intentionally omitted",payload["message"])
        @test W.attach_buckling_preload!(job(m,resultdir),path,payload,selected,2case-1)===payload
        @test !haskey(payload,"variants")
        selected_import=W.imported_case_result(data,2case,Dict(1=>Dict(),2=>Dict("STATSUB"=>1),3=>Dict(),4=>Dict("STATSUB"=>3)),[2,4])
        @test selected_import["eigenvalues"]==[value]
        case==1&&write(joinpath(evidence,"compact-results.msgpack"),W.MsgPack.pack(payload))
    end
    multicase=modelparams(merge(p,Dict("loads.cases"=>[Dict("id"=>2,"label"=>"Second case")])))
    payload=W.jfem_results_payload(job(multicase,resultdir))
    @test [only(row["buckling_roots"])["eigenvalue"] for row in payload["load_cases"]]==[11.,22.]
    ids=[first(group.eids) for group in m.groups if !isempty(group.eids)][1:2]
    energy=Dict("normalization"=>"static preload: physical displacement","units"=>Dict("deformation_energy"=>"force * length","energy_density"=>"force / length^2"),
        "records"=>[Dict("eid"=>ids[1],"pid"=>10,"deformation_energy"=>4.,"energy_density"=>20.,"volume"=>.2),
                    Dict("eid"=>ids[2],"pid"=>20,"deformation_energy"=>2.,"energy_density"=>nothing,"volume"=>0.)])
    contours=W.element_energy_contours(m,energy)
    @test [c["unit"] for c in contours]==["J","J/m³"]
    @test collect(reinterpret(Int32,contours[1]["ids"].bytes))==ids
    @test collect(reinterpret(Int32,contours[2]["ids"].bytes))==ids[1:1]
    @test W.element_energy_contours(imported,energy)[1]["unit"]=="force * length"
    @test all(occursin("physical displacement",c["note"]) for c in contours)
    shape=[Dict("grid_id"=>id,"t1"=>0.,"t2"=>0.,"t3"=>.001*index,"r1"=>0.,"r2"=>0.,"r3"=>0.) for (index,id) in enumerate(m.node_ids)]
    modal_energy=merge(energy,Dict("normalization"=>"solver eigenvector; arbitrary amplitude","records"=>[merge(row,Dict("deformation_energy"=>2row["deformation_energy"])) for row in energy["records"]]))
    full=Dict{String,Any}("analysis_type"=>"SOL105_BUCKLING","modes"=>[Dict("mode_number"=>1,"eigenvalue"=>11.,"mode_shape"=>shape,"element_energy"=>modal_energy)],
        "static_result"=>Dict("displacements"=>shape,"element_energy"=>energy),"static_displacements"=>shape)
    fullpayload=W.jfem_case_results_payload(job(m,resultdir),path,full)
    @test !fullpayload["compact_buckling"] && length(fullpayload["modes"])==1
    @test length(only(fullpayload["modes"])["energy_contours"])==2
    @test length(fullpayload["preload_energy_contours"])==2
    @test occursin("arbitrary amplitude",only(fullpayload["modes"])["energy_contours"][1]["note"])
    write(joinpath(evidence,"energy-results.msgpack"),W.MsgPack.pack(fullpayload))
    write(joinpath(evidence,"payload.msgpack"),W.MsgPack.pack(W.mesh_payload(m)))
    write(joinpath(evidence,"schema.json"),W.JSON.json(W.schema_payload(p,"")))
end
counts=Test.get_test_counts(suite);write(joinpath(evidence,"summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes),2))
