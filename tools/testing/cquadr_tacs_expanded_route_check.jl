using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
delete!(ENV, "JFEM_BACKEND")

using OpenJFEM

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _write_cquadr_sol103_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR TACS SOL103 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUADR,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "EIGRL,1,0.,1.0E9,4")
        println(io, "ENDDATA")
    end
    return path
end

function _write_cquadr_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR TACS SOL105 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUADR,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
        println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "ENDDATA")
    end
    return path
end

function _write_cquadr_sol200_deck(path::AbstractString)
    thickness = 0.02
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR TACS SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
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
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "DESVAR,1,T1,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _assert_forced_cquadr_metadata(results::Dict, sol_type::Int)
    @test results["sol_type"] == sol_type
    @test results["backend"] == "tacs_formulation"
    @test results["requested_backend"] == "nastran_parity"
    @test results["backend_forced_by"] == "CQUADR"
    @test results["backend_selection_note"] == "CQUADR shell elements are always formulated through the TACS backend."
    @test haskey(results, "solver_diagnostics")
    return true
end

function _check_model_has_cquadr(model::Dict)
    @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
    @test haskey(model, "CSHELLs")
    @test haskey(model["CSHELLs"], "1")
    @test uppercase(string(model["CSHELLs"]["1"]["TYPE"])) == "CQUADR"
    return true
end

function _check_sol103(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_has_cquadr(model)
    results = OpenJFEM.solve_model(model)
    _assert_forced_cquadr_metadata(results, 103)
    eigenvalues = Float64.(results["eigenvalues"])
    frequencies = Float64.(results["frequencies"])
    @test results["tacs_formulation_sol103"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol103"]["mass"] == "shared_jfem_mass"
    @test !isempty(eigenvalues)
    @test !isempty(frequencies)
    @test all(isfinite, eigenvalues)
    @test all(isfinite, frequencies)
    @test all(>=(0.0), frequencies)
    @test _relative_symmetry_error(results["K"]) < 1e-12
    return results
end

function _check_sol105(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_has_cquadr(model)
    results = OpenJFEM.solve_model(model)
    _assert_forced_cquadr_metadata(results, 105)
    eigenvalues = Float64.(results["eigenvalues"])
    @test results["tacs_formulation_sol105"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test !isempty(eigenvalues)
    @test all(isfinite, eigenvalues)
    @test nnz(results["Kg"]) > 0
    @test results["solver_diagnostics"][1]["kg_timings"]["tacs_native_kg_elements"] == 1
    @test _relative_symmetry_error(results["K"]) < 1e-12

    gradient_response = OpenJFEM.buckling_load_factor_thickness_gradient(results; pids=[1], mode=1)
    @test gradient_response["gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    @test isfinite(Float64(gradient_response["gradient"]["1"]))
    return results, gradient_response
end

function _check_sol200(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_has_cquadr(model)
    results = OpenJFEM.solve_model(model)
    _assert_forced_cquadr_metadata(results, 200)
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test haskey(results, "optimization")
    opt = results["optimization"]
    @test haskey(opt, "iterations")
    @test !isempty(opt["iterations"])
    @test opt["iterations"][1]["solver_diagnostics"]["backend"] == "tacs_formulation"
    @test opt["iterations"][1]["solver_diagnostics"]["formulation"]["thickness_derivative"] == "element_ad"
    @test haskey(results, "forward_results")
    @test results["forward_results"]["backend"] == "tacs_formulation"
    @test isfinite(Float64(opt["history"][1]))
    return results
end

function main()
    tmp = mktempdir(; prefix="openjfem_cquadr_expanded_tacs_")
    sol103_deck = _write_cquadr_sol103_deck(joinpath(tmp, "cquadr_sol103.bdf"))
    sol105_deck = _write_cquadr_sol105_deck(joinpath(tmp, "cquadr_sol105.bdf"))
    sol200_deck = _write_cquadr_sol200_deck(joinpath(tmp, "cquadr_sol200.bdf"))

    sol103_results = _check_sol103(sol103_deck)
    sol105_results, gradient_response = _check_sol105(sol105_deck)
    sol200_results = _check_sol200(sol200_deck)

    println("CQUADR expanded TACS route check passed")
    println("  SOL103 deck       = ", abspath(sol103_deck))
    println("  SOL103 first freq = ", Float64(sol103_results["frequencies"][1]))
    println("  SOL105 deck       = ", abspath(sol105_deck))
    println("  SOL105 first eig  = ", Float64(sol105_results["eigenvalues"][1]))
    println("  SOL105 dLambda/dt = ", Float64(gradient_response["gradient"]["1"]))
    println("  SOL200 deck       = ", abspath(sol200_deck))
    println("  SOL200 objective  = ", Float64(sol200_results["optimization"]["history"][1]))
    return true
end

exit(main() ? 0 : 1)
