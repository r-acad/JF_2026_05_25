# Guard for the TACS-formulation SOL101 CBAR/CBEAM stiffness slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_beam_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    Fz = 100.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 $card route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "FORCE,1,2,0,$Fz,0.,0.,1.")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, force_z=Fz)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _check_beam_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, _, ndof, _, max_elem_stiff, _, _, _ = OpenJFEM._tacs_assemble_sol101(model)
    @test ndof == 12
    @test norm(Matrix(K) - transpose(Matrix(K))) / max(norm(K), 1e-30) < 1e-12

    uz2 = _grid_dof(id_map, 2, 3)
    ry2 = _grid_dof(id_map, 2, 5)
    uncondensed_bending_k = 12.0 * E_BEAM * case.I2 / case.length^3
    end_rotation_k = E_BEAM * case.I2 / case.length
    @test abs(K[uz2, uz2] - uncondensed_bending_k) / uncondensed_bending_k < 1e-12
    @test abs(K[ry2, ry2] - 4.0 * end_rotation_k) / (4.0 * end_rotation_k) < 1e-12
    @test max_elem_stiff > 0.0

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test "beam_cbar" in results["formulation"]["core_contracts"]["element_kernels"] ||
          "beam_cbeam" in results["formulation"]["core_contracts"]["element_kernels"]

    u = Float64.(results["subcases"][1]["u_analysis"])
    expected_uz = case.force_z * case.length^3 / (3.0 * E_BEAM * case.I2)
    relerr = abs(u[uz2] - expected_uz) / max(abs(expected_uz), 1e-30)
    @test relerr < 1e-10
    return relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_route_")
    cbar = _write_beam_deck(joinpath(tmp, "tacs_cbar_sol101.bdf"), "CBAR")
    cbeam = _write_beam_deck(joinpath(tmp, "tacs_cbeam_sol101.bdf"), "CBEAM")

    cbar_relerr = _check_beam_case(cbar)
    cbeam_relerr = _check_beam_case(cbeam)

    println("TACS SOL101 beam route guard passed")
    println("  CBAR tip displacement relerr  = $cbar_relerr")
    println("  CBEAM tip displacement relerr = $cbeam_relerr")
    return true
end

exit(main() ? 0 : 1)
