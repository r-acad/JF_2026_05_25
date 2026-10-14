using Test
module PipelineTimingFixture
using JSON
include(joinpath(@__DIR__, "..", "src", "pipeline_timings.jl"))
end
const PT=PipelineTimingFixture

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
