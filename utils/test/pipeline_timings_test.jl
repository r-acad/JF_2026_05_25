using Test
module PipelineTimingFixture
using JSON
include(joinpath(@__DIR__, "..", "..", "src", "pipeline_timings.jl"))
end
const PT=PipelineTimingFixture

module MarkdownTimingFixture
using Dates, Printf
_export_base_name(filename) = splitext(basename(filename))[1]
_export_ensure_parent_dir!(path) = mkpath(dirname(path))
_export_fs_path(path) = path
include(joinpath(@__DIR__, "..", "..", "src", "MarkdownReport.jl"))
end
const MT = MarkdownTimingFixture

@testset "Report retains authoritative pipeline timing and unavailable execution" begin
    # Parallel compilation counters can exceed wall time. This reproduces the
    # cold two-thread CLI case without rerunning an FE solve to test formatting.
    phases = Dict{String,Any}(
        "parse" => Dict("wall_seconds"=>3., "compilation_seconds"=>2., "execution_seconds"=>1.),
        "solve" => Dict("wall_seconds"=>100., "compilation_seconds"=>120., "execution_seconds"=>nothing),
        "export" => Dict("wall_seconds"=>2., "compilation_seconds"=>1., "execution_seconds"=>1.))
    payload = PT._pipeline_timing_payload(phases)
    results = Dict{String,Any}("sol_type"=>0, "timings"=>Dict("solve"=>36.62, "assembly_K"=>21.72))
    @test MT._report_resolve_timings(results, payload) === payload
    @test payload["solution_seconds"] === nothing
    @test MT._report_fmt_time(nothing) == "Unavailable"
    legacy = MT._report_resolve_timings(results, Dict("solve"=>100., "parse"=>3.))
    @test legacy["solve"] == 100.
    @test legacy["assembly_K"] == 21.72
    io = IOBuffer()
    MT._report_timing_section(io, payload)
    text = String(take!(io))
    @test occursin("| Numerical execution (excluding compilation) | Unavailable |", text)
    @test occursin("| Input parsing | 3.00 s | 2.00 s | 1.00 s |", text)
    @test occursin("| Measured pipeline wall time | " * MT._report_fmt_time(105.), text)
    @test occursin("| Measured Julia compilation | " * MT._report_fmt_time(123.), text)
    @test occursin("Compilation counters can overlap across threads", text)
    @test !occursin("36.62", text)
    @test !occursin("BDF parsing", text)
    @test !occursin("Total (non-overlapping stages)", text)
    mktempdir() do directory
        report = MT.export_markdown_report(results, "model.inp", directory; timings=payload)
        @test isfile(report)
        @test occursin("Numerical execution (excluding compilation) | Unavailable", read(report, String))
        @test !occursin("36.62", read(report, String))
    end
end

@testset "Nested stage timing does not double count" begin
    phases=Dict{String,Any}();calls=Ref(0)
    PT._pipeline_measure!(phases,"solve") do
        for _ in 1:2
            PT._pipeline_detail_measure!("assembly","Assemble stiffness") do
                calls[]+=1
                PT._pipeline_detail_measure!("factorization","Factor matrix") do
                    sum(sqrt(Float64(i)) for i in 1:100)
                end
            end
        end
    end
    PT._pipeline_measure!(phases,"export") do
        PT._pipeline_detail_measure!("recovery","Deferred numerical recovery") do
            sum(sin(Float64(i)) for i in 1:100)
        end
    end
    payload=PT._pipeline_timing_payload(phases)
    rows=payload["stages"]
    @test calls[]==2
    @test payload["schema_version"]==2
    @test only(filter(r->r["phase"]=="assembly",rows))["calls"]==2
    @test only(filter(r->r["phase"]=="factorization",rows))["parent"]=="solve/assembly"
    @test sum(r["exclusive"]["wall_seconds"] for r in rows)≈payload["measured_wall_seconds"]
    @test sum(r["exclusive"]["compilation_seconds"] for r in rows)≈payload["compilation_seconds"] atol=1e-9
    if all(r->r["exclusive"]["execution_seconds"]!==nothing,rows)
        @test payload["solution_seconds"]+payload["export_seconds"]+payload["preparation_seconds"]+payload["compilation_seconds"]≈payload["measured_wall_seconds"]
    end
    @test only(filter(r->r["phase"]=="recovery",rows))["category"]=="numerical"
    @test isempty(get(task_local_storage(),PT._PIPELINE_CONTEXT_KEY,Dict()))
    @test_throws ErrorException PT._pipeline_measure!(Dict{String,Any}(),"solve") do
        PT._pipeline_detail_measure!(() -> error("expected"),"assembly","Failure test")
    end
    @test get(task_local_storage(),PT._PIPELINE_CONTEXT_KEY,nothing)===nothing
end
@testset "Compilation excluded from measured solution time" begin
    phases=Dict{String,Any}();calls=Ref(0)
    value=PT._pipeline_measure!(phases,"solve") do
        calls[]+=1
        sum(sqrt(Float64(i)) for i in 1:1000)
    end
    @test calls[]==1 # Timing must not solve a real model twice for warm-up.
    @test value≈sum(sqrt.(Float64.(1:1000)))
    p=phases["solve"]
    @test p["wall_seconds"]>=0
    @test p["compilation_seconds"]>=p["recompilation_seconds"]>=0
    @test p["execution_seconds"]===nothing || p["execution_seconds"]+p["compilation_seconds"]≈p["wall_seconds"]
    phases["parse"]=Dict("wall_seconds"=>15.,"execution_seconds"=>3.,"compilation_seconds"=>12.)
    result=PT._pipeline_timing_payload(phases)
    @test result["solution_seconds"]==p["execution_seconds"]
    @test result["compilation_seconds"]≈12+p["compilation_seconds"]
    @test result["measured_wall_seconds"]≈15+p["wall_seconds"]
end
