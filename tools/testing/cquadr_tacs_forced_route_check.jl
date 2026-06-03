using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
delete!(ENV, "JFEM_BACKEND")

using OpenJFEM

function _write_cquadr_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR forced-TACS route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUADR,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function main()
    tmp = mktempdir(; prefix="openjfem_cquadr_forced_tacs_")
    deck = _write_cquadr_sol101_deck(joinpath(tmp, "cquadr_forced_tacs.bdf"))
    model = OpenJFEM.bdf_to_model(deck)

    @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
    @test haskey(model["CSHELLs"], "1")
    @test uppercase(string(model["CSHELLs"]["1"]["TYPE"])) == "CQUADR"
    @test length(model["CSHELLs"]["1"]["NODES"]) == 4

    results = OpenJFEM.solve_model(model)
    @test results["sol_type"] == 101
    @test results["backend"] == "tacs_formulation"
    @test results["requested_backend"] == "nastran_parity"
    @test results["backend_forced_by"] == "CQUADR"
    @test results["solver_diagnostics"]["backend"] == "tacs_formulation"
    @test results["solver_diagnostics"]["backend_forced_by"] == "CQUADR"
    @test haskey(results, "subcases")
    @test !isempty(results["subcases"])

    println("CQUADR forced-TACS route check passed")
    println("  deck              = ", abspath(deck))
    println("  requested backend = ", results["requested_backend"])
    println("  actual backend    = ", results["backend"])
    println("  forced by         = ", results["backend_forced_by"])
    return true
end

exit(main() ? 0 : 1)
