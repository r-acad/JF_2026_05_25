using Test, SHA
using OpenJFEM
# Run under the containing solver project. Optional output directory retains
# the fixture and receipts; without it the regression writes no artifacts.
length(ARGS)<=1||throw(ArgumentError("Usage: coordinate_generated_payload_test.jl [output-dir]"))
push!(LOAD_PATH,dirname(@__DIR__))
include(joinpath(@__DIR__,"..","src","WingFEGen.jl"));const W=WingFEGen
const P=OpenJFEM.ReferenceParser
const OUT=isempty(ARGS) ? nothing : abspath(only(ARGS));OUT===nothing||mkpath(OUT)
parsecards(text)=P.process_cards(last(P.read_bulk_and_case(readlines(IOBuffer(text)))))

tests=@testset "Generated coordinate usage agrees with the written deck" begin
    params=merge(W.default_params(),Dict("planform.area"=>4.,"planform.aspect_ratio"=>4.,
        "box.rib_pitch"=>1.,"box.stringer_pitch"=>.35,"mesh.elements_between_ribs"=>1,
        "mesh.elements_between_stringers"=>1,"loads.method"=>"analytic","loads.cases"=>Any[]))
    model=W.build_model(params);deck_before=sprint(W.write_deck,model);cards=parsecards(deck_before)
    coords=P.extract_coords(cards["CORD2R"])
    shells=P.extract_shells(vcat(get(cards,"CQUAD4",Any[]),get(cards,"CTRIA3",Any[])))
    grids=P.extract_grid(cards["GRID"]);payload=W.mesh_payload(model);frames=payload["coordinate_systems"]["systems"]
    @test W.all_checks_pass(model)
    @test parsecards(sprint(W.write_deck,model))==cards
    @test length(frames)==length(coords)+1==length(shells)+1
    @test length(unique(frame["id"] for frame in frames))==length(frames)
    @test first(frames)["usage"]["grid_cp"]==first(frames)["usage"]["grid_cd"]==length(grids)
    @test all(grid["CP"]==grid["CD"]==0 for grid in values(grids))
    for frame in frames[2:end]
        id=frame["id"];source=coords[string(id)];shell=shells[string(id)]
        @test frame["origin"]==source["Origin"]==[0.,0.,0.]
        @test frame["x"]≈source["U"] atol=2e-5
        @test frame["z"]≈source["W"] atol=2e-5
        @test shell["MCID"]==id
        @test frame["usage"]==Dict("grid_cp"=>0,"grid_cd"=>0,"shell_mcid"=>1,"shell_eids"=>[id])
    end
    @test occursin("nearby RBE3",payload["coordinate_systems"]["note"])
    if OUT!==nothing
        write(joinpath(OUT,"generated.bdf"),deck_before)
        write(joinpath(OUT,"payload.msgpack"),W.MsgPack.pack(payload))
        write(joinpath(OUT,"schema.json"),W.JSON.json(W.schema_payload(params,"coordinate_generated.toml")))
        write(joinpath(OUT,"params.json"),W.JSON.json(params))
        write(joinpath(OUT,"model-summary.json"),W.JSON.json(Dict("passed"=>true,"coordinate_count"=>length(frames),
            "shell_count"=>length(shells),"grid_count"=>length(grids),"all_shells_have_one_mcid"=>true,
            "deck_cards_unchanged_by_payload"=>true,"deck_sha256"=>bytes2hex(sha256(deck_before)))))
    end
end
counts=Test.get_test_counts(tests)
OUT===nothing||write(joinpath(OUT,"test-summary.json"),W.JSON.json(Dict("passed"=>true,"assertions"=>counts.passes+counts.cumulative_passes)))
