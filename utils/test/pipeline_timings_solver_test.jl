using Test,OpenJFEM,JSON
length(ARGS)==2 || throw(ArgumentError("Usage: pipeline_timings_solver_test.jl <tiny_SOL105_deck> <output_directory>"))
const O=OpenJFEM
const DECK=abspath(ARGS[1]);const OUT=abspath(ARGS[2]);mkpath(OUT)
@testset "Native detailed timing and numerical invariance" begin
    unmeasured=O.solve_model(O.bdf_to_model(DECK))
    measured=O.main(DECK;output_dir=OUT,export_json=true,export_jfem_binary=false,export_report=true)
    @test measured["eigenvalues"]==unmeasured["eigenvalues"]
    @test measured["_raw_mode_shapes"]==unmeasured["_raw_mode_shapes"]
    timing=JSON.parsefile(joinpath(OUT,splitext(basename(DECK))[1]*".TIMINGS.JSON"))
    rows=timing["stages"]
    names=Set(row["phase"] for row in rows)
    @test issubset(Set(["parse","build_model","solve","assembly","loads","constraints",
        "constraints_linear_solve","factorization","eigensolve","recovery","export","report"]),names)
    @test all(row["calls"]>=1 for row in rows)
    @test timing["schema_version"]==2
    @test sum(row["exclusive"]["wall_seconds"] for row in rows)≈timing["measured_wall_seconds"] rtol=1e-9
    @test sum(row["exclusive"]["compilation_seconds"] for row in rows)≈timing["compilation_seconds"] atol=1e-9
    @test timing["solution_seconds"]!==nothing
    @test timing["preparation_seconds"]!==nothing
    @test timing["export_seconds"]!==nothing
    @test timing["solution_seconds"]+timing["preparation_seconds"]+timing["export_seconds"]+
        timing["compilation_seconds"]≈timing["measured_wall_seconds"] rtol=1e-9
    @test all(row["exclusive"]["execution_seconds"]>=0 for row in rows)
    @test any(row["phase"]=="recovery" && row["parent"]=="export" for row in rows)
    @test timing["phases"]["solve"]["compilation_seconds"]>=timing["phases"]["solve"]["recompilation_seconds"]
    @test get(task_local_storage(),O._PIPELINE_CONTEXT_KEY,nothing)===nothing
    summary=Dict("status"=>"PASS","eigenvalues"=>measured["eigenvalues"],"timing"=>timing)
    open(joinpath(OUT,"summary.json"),"w") do io;JSON.print(io,summary,2);end
end
