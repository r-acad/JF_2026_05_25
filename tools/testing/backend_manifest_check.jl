# Guard backend propagation through JSON batch manifests.
#
# Usage:
#   julia --project=. tools/testing/backend_manifest_check.jl

using JSON
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

include(joinpath(repo_root, "tools", "testing", "run_manifest.jl"))
include(joinpath(repo_root, "tools", "manifest_batch_core.jl"))

function _load_json(path::AbstractString)
    isfile(path) || error("expected JSON file was not written: $path")
    data = JSON.parsefile(path)
    data isa AbstractDict || error("expected JSON object in $path")
    return Dict{String,Any}(string(k) => v for (k, v) in data)
end

function main()
    tmp = mktempdir(; prefix="openjfem_backend_manifest_check_")
    deck = joinpath(repo_root, "examples", "precompile", "sol101_quad_static.bdf")
    manifest = Dict{String,Any}(
        "batch_id" => "backend_manifest_check",
        "output_root" => joinpath(tmp, "out"),
        "defaults" => Dict{String,Any}(
            "backend" => "tacs_formulation",
            "flags" => Dict{String,Any}(
                "JFEM_EXPORT_BINARY" => "false",
                "JFEM_SUPPRESS_THREAD_HINT" => "1",
            ),
            "output_options" => Dict{String,Any}(
                "json" => true,
                "binary" => false,
                "report" => false,
            ),
            "gc_between" => false,
            "stop_on_error" => true,
        ),
        "cases" => Any[
            Dict{String,Any}(
                "case_id" => "sol101_tacs_manifest",
                "input" => deck,
            ),
        ],
    )

    summary = run_batch_manifest!(manifest;
        manifest_path=nothing,
        repo_root=repo_root,
        script_path=@__FILE__,
        args=String[],
        quiet=true,
        stop_on_error_override=true)

    @test summary["completed"] == 1
    @test summary["failed"] == 0
    @test length(summary["cases"]) == 1
    row = summary["cases"][1]
    @test row["status"] == "ok"
    @test row["sol_type"] == 101
    @test isfile(row["result_json"])

    run_manifest = _load_json(joinpath(row["output_dir"], "run_manifest.json"))
    @test run_manifest["applied_flags"]["JFEM_BACKEND"] == "tacs_formulation"
    @test run_manifest["jfem_environment"]["JFEM_BACKEND"] == "tacs_formulation"
    @test run_manifest["extra"]["export_report"] == false
    @test run_manifest["extra"]["export_jfem_binary"] == false

    result_json = _load_json(row["result_json"])
    @test result_json["backend"] == "tacs_formulation"
    @test result_json["backend_version"] == "0.1.0-dev"
    @test occursin("residual_first", result_json["formulation"]["shell"])
    @test occursin("sol101", result_json["formulation"]["shell"])

    println("JFEM backend manifest check passed")
    println("  result backend = ", result_json["backend"])
    println("  summary_json = ", summary["summary_json"])
    return true
end

exit(main() ? 0 : 1)
