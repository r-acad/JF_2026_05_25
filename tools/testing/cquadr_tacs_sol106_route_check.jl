using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
delete!(ENV, "JFEM_BACKEND")

using OpenJFEM

const TACS_SHELL_FORMULATION = "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _write_cquadr_sol106_deck(path::AbstractString; formal::Bool=false)
    open(path, "w") do io
        println(io, "SOL 106")
        println(io, "CEND")
        println(io, formal ? "TITLE = Generated CQUADR TACS SOL106 formal route check" :
                            "TITLE = Generated CQUADR TACS SOL106 route check")
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
        println(io, "CQUADR,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,,1.0,0.,0.,-25.")
        println(io, "FORCE,1,3,,1.0,0.,0.,-25.")
        println(io, "ENDDATA")
    end
    return path
end

function _check_model_has_default_cquadr_route(model::Dict)
    @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
    @test haskey(model, "CSHELLs")
    @test haskey(model["CSHELLs"], "1")
    @test uppercase(string(model["CSHELLs"]["1"]["TYPE"])) == "CQUADR"
    return true
end

function _diagnostics_record_cquadr_forcing(results::Dict)
    diagnostics = get(results, "solver_diagnostics", nothing)
    if diagnostics isa AbstractDict
        return get(diagnostics, "backend_forced_by", "") == "CQUADR"
    elseif diagnostics isa AbstractVector
        return any(
            d -> d isa AbstractDict &&
                 get(d, "phase", "") == "backend_selection" &&
                 get(d, "backend_forced_by", "") == "CQUADR",
            diagnostics,
        )
    end
    return false
end

function _check_common_forced_sol106(results::Dict)
    @test results["sol_type"] == 106
    @test results["backend"] == "tacs_formulation"
    @test results["requested_backend"] == "nastran_parity"
    @test results["backend_forced_by"] == "CQUADR"
    @test results["backend_selection_note"] == "CQUADR shell elements are always formulated through the TACS backend."
    @test results["formulation"]["shell"] == TACS_SHELL_FORMULATION
    @test results["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test results["formulation"]["nonlinear_state"] == "backend_sol106_state_callback"
    @test results["tacs_formulation_sol106"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol106"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol106"]["nonlinear_route"] == "backend_nonlinear_state_callback"
    @test _diagnostics_record_cquadr_forcing(results)
    @test size(results["K"], 1) == size(results["K"], 2)
    @test size(results["Kg"]) == size(results["K"])
    @test nnz(results["Kg"]) > 0
    @test _relative_symmetry_error(results["K"]) < 1e-12
    @test haskey(results, "subcases")
    @test length(results["subcases"]) == 1
    @test length(results["subcases"][1]["raw_displacement"]) == results["ndof"]
    return true
end

function _check_standard(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_has_default_cquadr_route(model)
    results = OpenJFEM.solve_model(model)
    _check_common_forced_sol106(results)
    details = results["solver_diagnostics"][1]["details"]
    @test results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_tangent_operator"
    @test get(details, "nonlinear_method", "") == "legacy_geometric"
    @test get(details, "residual_model", "") == "tangent_operator"
    @test get(details, "state_evaluation_count", 0) > 0
    return results
end

function _check_formal(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_has_default_cquadr_route(model)
    results = OpenJFEM.solve_model(model)
    _check_common_forced_sol106(results)
    details = results["solver_diagnostics"][1]["details"]
    @test results["tacs_formulation_sol106"]["state_callback"] == "tacs_formulation_formal_shell_von_karman"
    @test get(details, "nonlinear_method", "") == "formal_shell_von_karman"
    @test get(details, "residual_model", "") == "formal_internal_force"
    @test get(details, "correction_tangent_model", "") == "formal_consistent_tangent"
    @test get(details, "state_evaluation_count", 0) > 0
    return results
end

function main()
    tmp = mktempdir(; prefix="openjfem_cquadr_sol106_tacs_")
    deck = _write_cquadr_sol106_deck(joinpath(tmp, "cquadr_sol106.bdf"))
    formal_deck = _write_cquadr_sol106_deck(joinpath(tmp, "cquadr_sol106_formal.bdf"); formal=true)

    results = _check_standard(deck)
    formal_results = _check_formal(formal_deck)

    println("CQUADR TACS SOL106 route check passed")
    println("  deck              = ", abspath(deck))
    println("  formal deck       = ", abspath(formal_deck))
    println("  ndof              = ", results["ndof"])
    println("  Kg nnz            = ", nnz(results["Kg"]))
    println("  K symmetry error  = ", _relative_symmetry_error(results["K"]))
    println("  state callback    = ", results["tacs_formulation_sol106"]["state_callback"])
    println("  formal callback   = ", formal_results["tacs_formulation_sol106"]["state_callback"])
    return true
end

exit(main() ? 0 : 1)
