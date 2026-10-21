using Test, JSON
# Runs the actual image workload in the shared package environment. No custom
# image or subprocess is needed; all workload outputs live in mktempdir scopes.
records=include(joinpath(@__DIR__,"..","julia_tools","sensitivity_precompile_workload.jl"))
checks=@testset "Shared image warms both sensitivity paths" begin
    @test Set(row["kind"] for row in records)==Set(["imported","generated"])
    @test all(row->row["status"]=="complete"&&row["finite_derivatives"],records)
    generated=only(filter(row->row["kind"]=="generated",records))
    @test generated["variables"]==6
    @test generated["has_shells"]&&generated["has_bars"]
    @test generated["solver_counts"]["forward_solves"]==1
    @test generated["solver_counts"]["perturbed_forward_solves"]==0
end
if !isempty(ARGS)
    out=abspath(only(ARGS));mkpath(out)
    write(joinpath(out,"summary.json"),JSON.json(Dict("passed"=>true,"records"=>records)))
end
