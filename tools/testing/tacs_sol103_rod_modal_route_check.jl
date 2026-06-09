# Guard for the TACS-formulation SOL103 CROD/CONROD modal slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_rod_modal_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_crod_modal_deck(path::AbstractString)
    A = 1.0e-2
    J = 2.5e-5
    L = 2.0
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 CROD modal route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CROD,1,1,1,2")
        println(io, "PROD,1,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, torsion=J, length=L)
end

function _write_conrod_modal_deck(path::AbstractString)
    A = 7.0e-3
    J = 1.6e-5
    L = 1.5
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 CONROD modal route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CONROD,1,1,2,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, torsion=J, length=L)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _check_modal_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, _, _, _ =
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(103,), route_label="SOL103")
    M = OpenJFEM._tacs_sol103_modal_mass_builder(model, id_map, X, node_R, ndof)
    @test norm(Matrix(K) - transpose(Matrix(K))) / max(norm(K), 1e-30) < 1e-12
    @test norm(Matrix(M) - transpose(Matrix(M))) / max(norm(M), 1e-30) < 1e-12

    ux2 = _grid_dof(id_map, 2, 1)
    axial_k = E_ROD * case.area / case.length
    axial_m = RHO_ROD * case.area * case.length / 2.0
    @test abs(K[ux2, ux2] - axial_k) / axial_k < 1e-12
    @test abs(M[ux2, ux2] - axial_m) / axial_m < 1e-12

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["rod"] == "residual_first_crod_conrod_sol101_sol103"
    @test !isempty(results["eigenvalues"])
    expected_lambda = axial_k / axial_m
    expected_freq = sqrt(expected_lambda) / (2.0 * pi)
    lambda_relerr = abs(Float64(results["eigenvalues"][1]) - expected_lambda) /
        max(abs(expected_lambda), 1e-30)
    freq_relerr = abs(Float64(results["frequencies"][1]) - expected_freq) /
        max(abs(expected_freq), 1e-30)
    @test lambda_relerr < 1e-10
    @test freq_relerr < 1e-10
    return lambda_relerr, freq_relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_rod_modal_")
    crod = _write_crod_modal_deck(joinpath(tmp, "tacs_crod_sol103.bdf"))
    conrod = _write_conrod_modal_deck(joinpath(tmp, "tacs_conrod_sol103.bdf"))

    crod_lambda_relerr, crod_freq_relerr = _check_modal_case(crod)
    conrod_lambda_relerr, conrod_freq_relerr = _check_modal_case(conrod)

    println("TACS SOL103 rod modal route guard passed")
    println("  CROD eigenvalue relerr   = $crod_lambda_relerr")
    println("  CROD frequency relerr    = $crod_freq_relerr")
    println("  CONROD eigenvalue relerr = $conrod_lambda_relerr")
    println("  CONROD frequency relerr  = $conrod_freq_relerr")
    return true
end

exit(main() ? 0 : 1)
