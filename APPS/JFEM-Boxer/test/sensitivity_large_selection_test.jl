using Test, JSON, OpenJFEM
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"))
const W=WingFEGen
out=abspath(only(ARGS));mkpath(out)
metrics=Dict{String,Any}()

suite=@testset "Large sensitivity selection and persistence" begin
    # A real generated model with more variables than the reported 10,580.
    p=merge(W.default_params(),Dict{String,Any}(
        "planform.area"=>40.,"planform.aspect_ratio"=>10.,"planform.taper_ratio"=>1.,
        "planform.sweep"=>0.,"planform.dihedral"=>0.,"planform.twist_tip"=>0.,
        "box.end_eta"=>1.,"box.rib_pitch"=>.125,"box.stringer_pitch"=>.05,
        "mesh.elements_between_ribs"=>1,"mesh.elements_between_stringers"=>1,
        "mesh.elements_spar_height"=>1,"mesh.aero_chord_points"=>9,"airfoil.n_points"=>31,
        "loads.method"=>"analytic","fuel.enabled"=>false,"loads.cases"=>Any[]))
    elapsed=@elapsed m=W.build_model(p)
    metrics["model_seconds"]=elapsed
    elapsed=@elapsed catalog=W.sensitivity_catalog(m)
    metrics["catalog_seconds"]=elapsed
    ids=[d["id"] for d in catalog["variables"]]
    @test length(ids)>10580
    @test catalog["max_variables"]==length(ids)
    raw=Dict("case_id"=>1,"solution"=>"101","variables"=>ids,
        "objective"=>Dict("type"=>"displacement","node_id"=>last(m.node_ids),"component"=>"z"))
    elapsed=@elapsed request=W.sensitivity_request(m,raw)
    metrics["request_seconds"]=elapsed
    expected=W.sensitivity_expand_selection(catalog,ids)
    @test request["variables"]==expected
    @test length(expected)>10580
    @test last(ids) in request["variables"]
    @test W.sensitivity_request(m,request)==request
    @test_throws ArgumentError W.sensitivity_request(m,merge(raw,Dict("variables"=>vcat(ids,[first(ids)]))))
    @test_throws ArgumentError W.sensitivity_request(m,merge(raw,Dict("variables"=>vcat(ids,["missing.property"]))))

    # Settings larger than the former 1 MiB limit remain lossless. IDs stay
    # short, validated strings; malformed values are still rejected.
    many=["properties.panels#upper:bay$(i):stringer12:segment1#stringer#flange_thickness" for i in 1:20000]
    large=merge(raw,Dict("variables"=>many))
    text=JSON.json(large)
    @test ncodeunits(text)>1024*1024
    @test JSON.parse(W.normalize_sensitivity_settings(text))["variables"]==many
    for bad in (42,[12],[""],[repeat("x",241)])
        @test_throws ArgumentError W.normalize_sensitivity_settings(JSON.json(merge(raw,Dict("variables"=>bad))))
    end
    saved=merge(copy(p),Dict("sensitivity.settings"=>JSON.json(request)))
    study_path=joinpath(out,"large-selection.toml")
    write(study_path,W.params_to_toml(saved))
    @test JSON.parse(W.read_input(study_path)["sensitivity.settings"])["variables"]==expected
    worker_path=joinpath(out,"request.json");write(worker_path,JSON.json(request))
    @test W.sensitivity_request(m,JSON.parsefile(worker_path))["variables"]==expected

    # Result import must accept every derivative and broad material ownership.
    selected=Set(expected)
    rows=[Dict{String,Any}("id"=>d["id"],"label"=>d["label"],"pids"=>d["pids"],
        "value"=>d["value"],"derivative"=>Float64(i),"normalized_derivative"=>nothing)
        for (i,d) in enumerate(catalog["variables"]) if d["id"] in selected]
    result=Dict("status"=>"complete","objective"=>raw["objective"],"rows"=>rows)
    run_dir=joinpath(out,"sensitivity_large_selection");mkpath(run_dir)
    write(joinpath(run_dir,"result.json"),JSON.json(result))
    restored=W.sensitivity_read_result(run_dir)
    @test length(restored["rows"])==length(expected)
    @test Set(d["id"] for d in restored["rows"])==selected
    @test last(restored["rows"])["derivative"]==last(rows)["derivative"]
    runs=W.sensitivity_saved_list(Dict("jfem.output_dir"=>out),out)
    @test runs["skipped_unreadable"]==0
    @test only(runs["runs"])["variable_count"]==length(expected)
    broad=deepcopy(result);first(broad["rows"])["pids"]=collect(1:10580)
    write(joinpath(run_dir,"result.json"),JSON.json(broad))
    @test length(first(W.sensitivity_read_result(run_dir)["rows"])["pids"])==10580
    first(broad["rows"])["pids"]=[0]
    write(joinpath(run_dir,"result.json"),JSON.json(broad))
    @test_throws ArgumentError W.sensitivity_read_result(run_dir)
    write(joinpath(run_dir,"result.json"),JSON.json(result))

    elapsed=@elapsed scope=W.sensitivity_scope(m,rows;catalog)
    metrics["scope_seconds"]=elapsed
    @test length(scope["variables"])==length(expected)
    for row in rows[[1,cld(length(rows),2),end]]
        reference=sort!(unique([eid for g in m.groups if g.pid in row["pids"] for eid in g.eids]))
        @test scope["variables"][row["id"]]["eids"]==reference
    end
    # Shared PID groups, duplicate IDs and missing ownership retain old semantics.
    duplicate_scope=Dict{String,Any}("groups"=>[
        Dict("pid"=>1,"eids"=>[8,3]),Dict("pid"=>1,"eids"=>[3,5]),Dict("pid"=>2,"eids"=>[9])])
    W.sensitivity_scope_variables!(duplicate_scope,[Dict("id"=>"x","pids"=>[2,1,1,99])])
    @test duplicate_scope["variables"]["x"]["eids"]==[3,5,8,9]
    metrics["catalog_variables"]=length(ids)
    metrics["requested_variables"]=length(expected)
    metrics["settings_bytes"]=ncodeunits(text)
    metrics["model_elements"]=sum(length(g.eids) for g in m.groups)

    # Import a deck with 10,580 independent cards. Shared topology deliberately
    # keeps this catalogue/request test small; no equilibrium solve is needed.
    io=IOBuffer()
    println(io,"SOL 101\nCEND\nSUBCASE 1\n SPC=1\n LOAD=2\nBEGIN BULK")
    println(io,"GRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,1.,1.,0.\nGRID,4,,0.,1.,0.")
    println(io,"MAT1,1,7.0E10,,.3,2700.\nSPC1,1,123456,1,4\nFORCE,2,2,0,1.,0.,0.,1.")
    for i in 1:10580
        println(io,"PSHELL,$i,1,.002\nCQUAD4,$i,$i,1,2,3,4")
    end
    println(io,"ENDDATA")
    source=W.imported_source(Dict("name"=>"large-properties.bdf","text"=>String(take!(io))))
    cc,bulk=OpenJFEM.ReferenceParser.read_bulk_and_case(readlines(IOBuffer(source["flattened"])))
    cards=OpenJFEM.ReferenceParser.process_cards(bulk)
    native=OpenJFEM.build_model(cards,cc)
    imported=W.imported_model(native,source,W.default_params();cards)
    ic=W.sensitivity_catalog(imported)
    @test length(ic["variables"])==10583 # PSHELL thicknesses plus MAT1 E/nu/rho.
    @test ic["max_variables"]==10583
    imported_ids=[d["id"] for d in ic["variables"]]
    ir=W.sensitivity_request(imported,Dict("case_id"=>1,"variables"=>imported_ids,
        "objective"=>Dict("type"=>"displacement","node_id"=>2,"component"=>"z")))
    @test ir["variables"]==imported_ids
    @test "reference.PSHELL#10580#T" in ir["variables"]
    @test length(first(d["pids"] for d in ic["variables"] if d["id"]=="reference.MAT1#1#E"))==10580
    metrics["imported_variables"]=length(imported_ids)
end
counts=Test.get_test_counts(suite)
metrics["passed"]=counts.passes+counts.cumulative_passes
write(joinpath(out,"summary.json"),JSON.json(metrics))
