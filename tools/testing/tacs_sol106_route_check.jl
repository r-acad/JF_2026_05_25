# Smoke check for routing SOL 106 nonlinear static through the TACS-formulation backend.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol106_route_check.jl

using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_sol106_deck(path::AbstractString; formal::Bool=false)
    open(path, "w") do io
        println(io, "SOL 106")
        println(io, "CEND")
        println(io, formal ? "TITLE = OpenJFEM TACS SOL106 formal route check" : "TITLE = OpenJFEM TACS SOL106 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "PARAM,NLLOADSTEPS,1")
        println(io, "PARAM,NLMAXITER,2")
        println(io, "PARAM,NLTOL,1.0E-6")
        formal && println(io, "PARAM,NLMETHOD,formal_shell_von_karman")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,,1.0,0.,0.,-25.")
        println(io, "FORCE,1,3,,1.0,0.,0.,-25.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_sol106_patch_deck(path::AbstractString; formal::Bool=false)
    nx = 2
    ny = 1
    left = [_grid_id(0, j, nx) for j in 0:ny]
    right = [_grid_id(nx, j, nx) for j in 0:ny]
    open(path, "w") do io
        println(io, "SOL 106")
        println(io, "CEND")
        println(io, formal ? "TITLE = OpenJFEM TACS SOL106 formal patch route check" : "TITLE = OpenJFEM TACS SOL106 patch route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "PARAM,NLLOADSTEPS,2")
        println(io, "PARAM,NLMAXITER,3")
        println(io, "PARAM,NLTOL,1.0E-6")
        formal && println(io, "PARAM,NLMETHOD,formal_shell_von_karman")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,1,2,3,6,5")
        println(io, "PSHELL,1,1,0.018")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,", join(left, ","))
        for nid in right
            println(io, "FORCE,1,$nid,,1.0,0.,0.,-18.")
        end
        println(io, "ENDDATA")
    end
    return path
end

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function main()
    tempdir_path = mktempdir(; prefix="openjfem_tacs_sol106_route_")
    deck = _write_sol106_deck(joinpath(tempdir_path, "tacs_sol106_route.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    K = results["K"]
    Kg = results["Kg"]

    @test results["sol_type"] == 106
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test results["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test results["formulation"]["nonlinear_state"] == "backend_sol106_state_callback"
    @test results["tacs_formulation_sol106"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol106"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol106"]["nonlinear_route"] == "backend_nonlinear_state_callback"
    @test results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_tangent_operator"
    @test size(K, 1) == size(K, 2)
    @test size(Kg) == size(K)
    @test nnz(Kg) > 0
    @test _relative_symmetry_error(K) < 1e-12
    @test haskey(results, "subcases")
    @test length(results["subcases"]) == 1
    @test length(results["subcases"][1]["raw_displacement"]) == results["ndof"]
    @test !isempty(results["solver_diagnostics"])

    details = results["solver_diagnostics"][1]["details"]
    @test get(details, "nonlinear_method", "") == "legacy_geometric"
    @test get(details, "residual_model", "") == "tangent_operator"
    @test get(details, "state_evaluation_count", 0) > 0

    formal_deck = _write_sol106_deck(joinpath(tempdir_path, "tacs_sol106_formal_route.bdf"); formal=true)
    formal_model = OpenJFEM.bdf_to_model(formal_deck)
    formal_model["backend"] = "tacs_formulation"
    formal_results = OpenJFEM.solve_model(formal_model)
    formal_details = formal_results["solver_diagnostics"][1]["details"]

    @test formal_results["sol_type"] == 106
    @test formal_results["backend"] == "tacs_formulation"
    @test formal_results["formulation"]["nonlinear_state"] == "backend_sol106_state_callback"
    @test formal_results["tacs_formulation_sol106"]["nonlinear_route"] == "backend_nonlinear_state_callback"
    @test formal_results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_formal_shell_von_karman"
    @test get(formal_details, "nonlinear_method", "") == "formal_shell_von_karman"
    @test get(formal_details, "residual_model", "") == "formal_internal_force"
    @test get(formal_details, "correction_tangent_model", "") == "formal_consistent_tangent"
    @test get(formal_details, "state_evaluation_count", 0) > 0

    patch_deck = _write_sol106_patch_deck(joinpath(tempdir_path, "tacs_sol106_patch_route.bdf"))
    patch_model = OpenJFEM.bdf_to_model(patch_deck)
    patch_model["backend"] = "tacs_formulation"
    patch_results = OpenJFEM.solve_model(patch_model)
    patch_details = patch_results["solver_diagnostics"][1]["details"]

    @test patch_results["sol_type"] == 106
    @test patch_results["backend"] == "tacs_formulation"
    @test patch_results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_tangent_operator"
    @test patch_results["ndof"] > results["ndof"]
    @test nnz(patch_results["Kg"]) > nnz(Kg)
    @test _relative_symmetry_error(patch_results["K"]) < 1e-12
    @test get(patch_details, "nonlinear_method", "") == "legacy_geometric"
    @test get(patch_details, "state_evaluation_count", 0) >= get(details, "state_evaluation_count", 0)
    @test get(patch_details, "final_kg_nnz", 0) > get(details, "final_kg_nnz", 0)

    formal_patch_deck = _write_sol106_patch_deck(joinpath(tempdir_path, "tacs_sol106_formal_patch_route.bdf"); formal=true)
    formal_patch_model = OpenJFEM.bdf_to_model(formal_patch_deck)
    formal_patch_model["backend"] = "tacs_formulation"
    formal_patch_results = OpenJFEM.solve_model(formal_patch_model)
    formal_patch_details = formal_patch_results["solver_diagnostics"][1]["details"]

    @test formal_patch_results["sol_type"] == 106
    @test formal_patch_results["backend"] == "tacs_formulation"
    @test formal_patch_results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_formal_shell_von_karman"
    @test formal_patch_results["ndof"] == patch_results["ndof"]
    @test get(formal_patch_details, "nonlinear_method", "") == "formal_shell_von_karman"
    @test get(formal_patch_details, "residual_model", "") == "formal_internal_force"
    @test get(formal_patch_details, "correction_tangent_model", "") == "formal_consistent_tangent"
    @test get(formal_patch_details, "state_evaluation_count", 0) > 0

    println("TACS SOL106 route check passed")
    println("  deck              = ", abspath(deck))
    println("  formal deck       = ", abspath(formal_deck))
    println("  patch deck        = ", abspath(patch_deck))
    println("  formal patch deck = ", abspath(formal_patch_deck))
    println("  ndof              = ", results["ndof"])
    println("  patch ndof        = ", patch_results["ndof"])
    println("  K symmetry error  = ", _relative_symmetry_error(K))
    println("  Kg nnz            = ", nnz(Kg))
    println("  patch Kg nnz      = ", nnz(patch_results["Kg"]))
    println("  state evaluations = ", details["state_evaluation_count"])
    println("  patch evaluations = ", patch_details["state_evaluation_count"])
    println("  formal callback   = ", formal_results["tacs_formulation_sol106"]["state_callback"])
    return true
end

exit(main() ? 0 : 1)
