# Smoke check for routing SOL 103 normal modes through the TACS-formulation backend.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _write_tria3_sol103_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CTRIA3 SOL103 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CTRIA3,1,1,1,2,3")
        println(io, "CTRIA3,2,1,1,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "EIGRL,1,0.,1.0E9,6")
        println(io, "ENDDATA")
    end
    return path
end

function _check_sol103_deck(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    eigenvalues = Float64.(results["eigenvalues"])
    frequencies = Float64.(results["frequencies"])
    K = results["K"]

    @test results["sol_type"] == 103
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["shell"] == "residual_first_quad4_tria3_sol101_sol103_sol105_sol106"
    @test results["tacs_formulation_sol103"]["linear_stiffness"] == "residual_first_quad4_tria3"
    @test results["tacs_formulation_sol103"]["mass"] == "shared_jfem_mass"
    @test results["tacs_formulation_sol103"]["eigensolver"] == "shared_sol103"
    @test !isempty(eigenvalues)
    @test !isempty(frequencies)
    @test all(isfinite, eigenvalues)
    @test all(isfinite, frequencies)
    @test all(>=(0.0), frequencies)
    @test size(K, 1) == size(K, 2)
    @test _relative_symmetry_error(K) < 1e-12
    @test haskey(results, "mass_summary")
    @test haskey(results, "solver_diagnostics")
    @test haskey(results, "subcases")
    @test length(results["subcases"]) == 1
    return results, eigenvalues, frequencies, K
end

function main()
    deck = joinpath(repo_root, "examples", "precompile", "sol103_quad_modes.bdf")
    tria3_deck = _write_tria3_sol103_deck(joinpath(mktempdir(; prefix="openjfem_tacs_sol103_route_"), "tacs_tria3_sol103_route.bdf"))

    results, eigenvalues, frequencies, K = _check_sol103_deck(deck)
    tria3_results, tria3_eigenvalues, tria3_frequencies, tria3_K = _check_sol103_deck(tria3_deck)

    println("TACS SOL103 route check passed")
    println("  deck              = ", abspath(deck))
    println("  tria3 deck        = ", abspath(tria3_deck))
    println("  modes             = ", length(eigenvalues))
    println("  first eigenvalue  = ", eigenvalues[1])
    println("  first frequency   = ", frequencies[1])
    println("  K symmetry error  = ", _relative_symmetry_error(K))
    println("  tria3 modes       = ", length(tria3_eigenvalues))
    println("  tria3 first eigenvalue = ", tria3_eigenvalues[1])
    println("  tria3 first frequency = ", tria3_frequencies[1])
    println("  tria3 K symmetry error = ", _relative_symmetry_error(tria3_K))
    return true
end

main()
