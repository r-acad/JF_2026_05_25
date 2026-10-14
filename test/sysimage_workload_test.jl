module SharedImageWorkloadTests
using Test, HTTP, MsgPack, JSON
include(joinpath(@__DIR__, "..", "__Start here!__", "julia_tools", "shared_precompile_workloads.jl"))
const W = JFEMSharedPrecompileWorkloads
const root = dirname(@__DIR__)
const deck_dir = joinpath(root, "__Start here!__", "examples", "precompile")
const small_deck = joinpath(deck_dir, "sol101_adjoint_shell.bdf")

function fake_response(request; post_status=200, result=Dict("ok"=>false))
    request.method == "OPTIONS" && return HTTP.Response(204)
    request.method == "GET" && return HTTP.Response(200, "ready")
    return HTTP.Response(post_status, MsgPack.pack(result))
end

tests = @testset "Shared image warmups require every app and propagate failures" begin
    @test W.required_packages() == W.SHARED_PACKAGES
    for missing in W.SHARED_PACKAGES
        @test_throws ErrorException W.required_packages(;
            find_package=name -> name == string(missing) ? nothing : "available")
    end
    mktempdir() do absent_root
        @test_throws ErrorException W.run_pandeator(absent_root, [small_deck])
    end
    @test_throws ErrorException W.exercise_pandeator(fake_response, String[])
    @test_throws ErrorException W.exercise_pandeator(_ -> HTTP.Response(500), [small_deck])
    @test_throws ErrorException W.exercise_pandeator(
        request -> fake_response(request; post_status=500), [small_deck])
    @test_throws ErrorException W.exercise_pandeator(fake_response, [small_deck])
    @test_throws ErrorException W.exercise_pandeator(
        request -> fake_response(request; result=Dict("ok"=>true, "jfem_bytes"=>UInt8[])), [small_deck])

    # Routine Pkg.test runs one real POST. Release image validation runs every
    # bundled SOL101/103/105/106 deck with this explicit additional coverage.
    all_decks = get(ENV, "JFEM_TEST_ALL_PANDEATOR_WARMUPS", "0") == "1"
    decks = all_decks ? sort(filter(endswith(".bdf"), readdir(deck_dir; join=true))) : [small_deck]
    results = W.run_pandeator(root, decks)
    @test length(results) == length(decks)
    @test all(result -> result["ok"], results)
    @test all(result -> result["viewer_bytes"] > 0, results)
    @test Set(result["sol"] for result in results) == (all_decks ? Set([101, 103, 105, 106]) : Set([101]))
    evidence = get(ENV, "JFEM_WORKLOAD_TEST_EVIDENCE", "")
    if !isempty(evidence)
        mkpath(evidence)
        write(joinpath(evidence, "pandeator_warmups.json"), JSON.json(results))
    end
end

evidence = get(ENV, "JFEM_WORKLOAD_TEST_EVIDENCE", "")
if !isempty(evidence)
    counts = Test.get_test_counts(tests)
    write(joinpath(evidence, "summary.json"), JSON.json(Dict("passed"=>true,
        "assertions"=>counts.passes+counts.cumulative_passes)))
end
end
