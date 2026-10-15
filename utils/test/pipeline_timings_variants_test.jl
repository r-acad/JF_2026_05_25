using Test,OpenJFEM,JSON
length(ARGS)==3 || error("Usage: pipeline_timings_variants_test.jl <tiny_SOL105_deck> <tiny_SOL103_deck> <output_directory>")
const O=OpenJFEM
const OUT=abspath(ARGS[3]);mkpath(OUT)
timings(dir,deck)=JSON.parsefile(joinpath(dir,splitext(basename(deck))[1]*".TIMINGS.JSON"))
function check_accounting(timing)
    @test sum(r["exclusive"]["wall_seconds"] for r in timing["stages"])≈timing["measured_wall_seconds"] rtol=1e-9
    @test timing["solution_seconds"]+timing["preparation_seconds"]+timing["export_seconds"]+
        timing["compilation_seconds"]≈timing["measured_wall_seconds"] rtol=1e-9
end
@testset "Modal mass and binary preload timing scopes" begin
    binarydir=joinpath(OUT,"binary")
    buckling=O.main(ARGS[1];output_dir=binarydir,export_json=false,export_jfem_binary=true,export_report=false)
    binary=timings(binarydir,ARGS[1]);check_accounting(binary)
    recovered=filter(r->r["phase"]=="recovery" && r["parent"]=="export",binary["stages"])
    @test !isempty(recovered)
    @test only(recovered)["category"]=="numerical"
    @test only(recovered)["calls"]==2
    @test length(filter(f->endswith(lowercase(f),".jfem"),readdir(binarydir)))==2
    @test length(buckling["eigenvalues"])==6
    modal=O.bdf_to_model(ARGS[2])
    plain=O.solve_model(modal)
    modaldir=joinpath(OUT,"modal")
    measured=O.main(ARGS[2];output_dir=modaldir,export_json=true,export_jfem_binary=false,export_report=false)
    @test measured["eigenvalues"]==plain["eigenvalues"]
    @test measured["_raw_mode_shapes"]==plain["_raw_mode_shapes"]
    timing=timings(modaldir,ARGS[2]);check_accounting(timing)
    mass=filter(r->r["phase"]=="mass_assembly",timing["stages"])
    @test length(mass)==1
    @test only(mass)["category"]=="numerical"
    @test only(mass)["inclusive"]["wall_seconds"]>0
    @test any(r->r["phase"]=="eigensolve",timing["stages"])
    write(joinpath(OUT,"summary.json"),JSON.json(Dict("status"=>"PASS","modal_eigenvalues"=>measured["eigenvalues"],
        "buckling_eigenvalues"=>buckling["eigenvalues"],"binary"=>binary,"modal"=>timing),2))
end
