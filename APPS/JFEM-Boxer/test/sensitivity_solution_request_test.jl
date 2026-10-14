using Test, JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
    "box.rib_pitch"=>.6,"box.stringer_pitch"=>.2,"mesh.elements_between_ribs"=>1,
    "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
    "loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[],"loads.follower_forces"=>false))
m=W.build_model(p)
base=Dict{String,Any}("case_id"=>1,"variables"=>["material.E"],
    "objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z"))
tests=@testset "Sensitivity sequence is explicit, compatible and persistent" begin
    catalog=W.sensitivity_catalog(m)
    @test Set(keys(catalog["solutions"]))==Set(["101","103","105","106"])
    @test all(info["available"]&&info["case_ids"]==[1] for info in values(catalog["solutions"]))
    @test W.sensitivity_request(m,base)["solution"]=="101"
    for (sol,kind) in (("103","frequency_eigenvalue"),("105","buckling_factor"))
        raw=merge(base,Dict("objective"=>Dict("type"=>kind,"mode"=>2)))
        request=W.sensitivity_request(m,raw)
        @test request["solution"]==sol
        @test W.sensitivity_request(m,merge(raw,Dict("solution"=>sol)))==request
        @test W.sensitivity_request(m,JSON.parse(W.normalize_sensitivity_settings(JSON.json(request))))==request
        @test_throws ArgumentError W.sensitivity_request(m,merge(raw,Dict("solution"=>"106")))
        @test_throws ArgumentError W.sensitivity_request(m,merge(base,Dict("solution"=>sol)))
    end
    nonlinear=W.sensitivity_request(m,merge(base,Dict("solution"=>"106")))
    @test nonlinear["solution"]=="106"
    @test nonlinear["derivative_method"]=="analytic"
    saved=merge(copy(p),Dict("sensitivity.settings"=>JSON.json(nonlinear)))
    path=joinpath(out,"study_settings.toml");write(path,W.params_to_toml(saved))
    restored=JSON.parse(W.read_input(path)["sensitivity.settings"])
    @test restored==nonlinear
    @test_throws ArgumentError W.sensitivity_request(m,merge(nonlinear,Dict("derivative_method"=>"operator_differences")))
    @test_throws ArgumentError W.normalize_sensitivity_settings(JSON.json(merge(base,Dict("solution"=>"108"))))
    @test_throws ArgumentError W.sensitivity_request(m,merge(base,Dict("solution"=>true)))
    # FE Analysis solution does not change the meaning of old or explicit setups.
    other=W.sensitivity_model(m,merge(copy(p),Dict("output.solution"=>"105")))
    @test W.sensitivity_request(other,base)["solution"]=="101"
    @test W.sensitivity_request(other,nonlinear)["solution"]=="106"
    follower=W.sensitivity_model(m,merge(copy(p),Dict("loads.follower_forces"=>true)))
    fc=W.sensitivity_catalog(follower)
    for sol in ("105","106")
        @test isempty(fc["solutions"][sol]["case_ids"])
        @test occursin("follower",fc["solutions"][sol]["case_reasons"]["1"])
        objective=sol=="105" ? Dict("type"=>"buckling_factor","mode"=>1) : base["objective"]
        @test_throws ArgumentError W.sensitivity_request(follower,merge(base,Dict("solution"=>sol,"objective"=>objective)))
    end
    @test fc["solutions"]["103"]["case_ids"]==[1]
    # Deck conversion is independent of the numerical solver. An FE Analysis
    # overlay has its own bulk PARAMs even though the cached source graph has
    # none; do not append duplicate sensitivity defaults over those controls.
    text="SOL 101\nCEND\nSUBCASE 17\n SPC=20\n LOAD=31\nBEGIN BULK\nGRID,11,,0.,0.,0.\nENDDATA\n"
    ip=merge(copy(p),Dict{String,Any}("imported.source"=>Dict("flattened"=>text,"signature"=>"synthetic"),
        "imported.native"=>Dict("SOL"=>101,"CASE_CONTROL"=>Dict("SUBCASES"=>Dict(17=>Dict("SPC"=>20,"LOAD"=>31)))),
        "imported.cases"=>[Dict("id"=>17,"label"=>"Original")]))
    im=W.Model((f===:params ? ip : getfield(m,f) for f in fieldnames(W.Model))...)
    converted=W.imported_sensitivity_deck(im,17,"106")
    @test occursin("PARAM,NLLOADSTEPS,20",converted)
    @test occursin("PARAM,NLMAXITER,40",converted)
    @test occursin("PARAM,NLRESTOL,1.0e-8",converted)
    overlay=W.imported_analysis_model(im,Dict("solution"=>"106","load_steps"=>7,"max_iterations"=>81,"residual_tolerance"=>2e-5))
    custom=W.imported_sensitivity_deck(overlay,17,"106")
    @test occursin("PARAM,NLLOADSTEPS,7",custom)
    @test occursin("PARAM,NLMAXITER,81",custom)
    @test occursin("PARAM,NLRESTOL,2.0e-5",custom)
    for name in ("NLLOADSTEPS","NLMAXITER","NLRESTOL","NLTOL","NLCUTMAX","NLMETHOD")
        @test length(collect(eachmatch(Regex("(?m)^PARAM,"*name*","),custom)))==1
    end
    @test im.params["imported.source"]["flattened"]==text
    write(joinpath(out,"catalog.json"),JSON.json(catalog))
end
counts=Test.get_test_counts(tests)
write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
