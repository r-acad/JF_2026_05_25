# Guard for the TACS-formulation SOL101 CROD/CONROD stiffness slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_rod_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_crod_deck(path::AbstractString)
    A = 1.0e-2
    J = 2.5e-5
    L = 2.0
    F = 1000.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CROD route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CROD,1,1,1,2")
        println(io, "PROD,1,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, torsion=J, length=L, force=F)
end

function _write_conrod_deck(path::AbstractString)
    A = 7.0e-3
    J = 1.6e-5
    L = 1.5
    F = 600.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CONROD route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CONROD,1,1,2,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, torsion=J, length=L, force=F)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _check_rod_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, _, ndof, _, max_elem_stiff, _, _, _ = OpenJFEM._tacs_assemble_sol101(model)
    @test ndof == 12
    @test norm(Matrix(K) - transpose(Matrix(K))) / max(norm(K), 1e-30) < 1e-12

    ux2 = _grid_dof(id_map, 2, 1)
    rx2 = _grid_dof(id_map, 2, 4)
    axial_k = E_ROD * case.area / case.length
    torsion_k = G_ROD * case.torsion / case.length
    @test abs(K[ux2, ux2] - axial_k) / axial_k < 1e-12
    @test abs(K[rx2, rx2] - torsion_k) / max(torsion_k, 1e-30) < 1e-12
    @test abs(max_elem_stiff - axial_k) / axial_k < 1e-12

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["rod"] == "residual_first_crod_conrod_sol101_sol103"
    @test "rod_crod" in results["formulation"]["core_contracts"]["element_kernels"] ||
          "rod_conrod" in results["formulation"]["core_contracts"]["element_kernels"]

    u = Float64.(results["subcases"][1]["u_analysis"])
    expected_ux = case.force * case.length / (E_ROD * case.area)
    relerr = abs(u[ux2] - expected_ux) / max(abs(expected_ux), 1e-30)
    @test relerr < 1e-10
    return relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_rod_route_")
    crod = _write_crod_deck(joinpath(tmp, "tacs_crod_sol101.bdf"))
    conrod = _write_conrod_deck(joinpath(tmp, "tacs_conrod_sol101.bdf"))

    crod_relerr = _check_rod_case(crod)
    conrod_relerr = _check_rod_case(conrod)

    println("TACS SOL101 rod route guard passed")
    println("  CROD axial displacement relerr   = $crod_relerr")
    println("  CONROD axial displacement relerr = $conrod_relerr")
    return true
end

exit(main() ? 0 : 1)
