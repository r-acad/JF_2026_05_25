using Test
module PipelineTimingFixture
include(joinpath(@__DIR__, "..", "src", "pipeline_timings.jl"))
end
const PT=PipelineTimingFixture
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
