using Test,JSON
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
p=merge(W.default_params(),Dict{String,Any}("planform.area"=>2.,"planform.aspect_ratio"=>2.,
    "planform.taper_ratio"=>1.,"planform.sweep"=>0.,"box.end_eta"=>1.,"box.rib_pitch"=>.6,
    "box.stringer_pitch"=>.15,"mesh.elements_between_ribs"=>1,"mesh.elements_spar_height"=>1,
    "mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,"leading_edge.enabled"=>true,
    "leading_edge.chord_elements"=>2,"loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[]))
m=W.build_model(p);catalog=W.sensitivity_catalog(m);locals=filter(d->haskey(d,"component_key"),catalog["variables"])
shared=filter(d->d["id"] in ("properties.t_spar_web","properties.t_rib_web","properties.spar_cap_side",
    "leading_edge.t_skin","leading_edge.t_rib","properties.rib_stiffener_height"),catalog["variables"])
tests=@testset "Native component catalogue metadata for detached tables" begin
    @test isempty(p["properties.components"])
    @test Set(first(split(d["component_key"],':')) for d in locals)==Set(W.COMPONENT_TABLE_PARTS)
    scope=W.sensitivity_scope(m,shared;catalog)
    @test length(scope["available_components"])==length(locals)
    @test all(!haskey(d,"derivative") for d in scope["available_components"])
    @test Set(keys(scope["variables"]))==Set(d["id"] for d in shared)
    @test all(d->d["pids"]==[W.component_table_family(first(split(d["component_key"],':')))*W.COMPONENT_PID_STRIDE+parse(Int,last(split(d["component_key"],':')))],locals)
    # Synthetic numbers exercise table routing, not numerical solver accuracy.
    result(selected)=Dict("status"=>"complete","case_id"=>1,"baseline"=>Dict("value"=>2.,"unit"=>"m"),
        "objective"=>Dict("type"=>"displacement","component"=>"z","node_id"=>last(m.node_ids)),
        "baseline_model_signature"=>W.sensitivity_model_signature(m),"baseline_model_signature_version"=>2,
        "load_application_version"=>W.APPLIED_LOAD_VERSION,"request"=>Dict("variables"=>[d["id"] for d in selected]),
        "rows"=>[merge(d,Dict("derivative"=>(isodd(i) ? -1. : 1.)*i,"derivative_unit"=>"m / m","status"=>"ok")) for (i,d) in enumerate(selected)],
        "scope"=>W.sensitivity_scope(m,selected;catalog))
    saved=result(shared);runid="sensitivity_component_table_fixture";directory=joinpath(out,runid);mkpath(directory)
    write(joinpath(directory,"result.json"),JSON.json(saved))
    write(joinpath(directory,"baseline.bdf"),sprint(io->W.write_deck(IOContext(io,:full_precision=>true),m)))
    reloaded=W.sensitivity_saved_load(merge(p,Dict("jfem.output_dir"=>out)),out,runid;model=m)
    @test reloaded["compatibility"]["is_current"]
    @test reloaded["scope"]["available_components"]==scope["available_components"]
    @test all(!isempty(g["name"]) for g in reloaded["scope"]["groups"])
    @test reloaded["result"]["rows"]==saved["rows"]
    write(joinpath(out,"table_fixture.json"),JSON.json(Dict("catalog"=>catalog,"rib_count"=>length(m.grid.ribs),
        "shared_only"=>saved,"all_local"=>result(vcat(shared,locals)),"reloaded"=>reloaded["result"],"note"=>"Native generated catalogue and ownership; synthetic derivative values for routing tests only.")))
end
c=Test.get_test_counts(tests);write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"assertions"=>c.passes+c.cumulative_passes,"local_variables"=>length(locals))))
