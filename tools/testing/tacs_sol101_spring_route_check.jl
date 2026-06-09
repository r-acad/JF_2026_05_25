# Guard for the TACS-formulation SOL101 CELAS1/CELAS2/CBUSH spring stiffness slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_spring_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

function _write_celas1_deck(path::AbstractString)
    k = 2500.0
    f = 125.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CELAS1 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "CELAS1,1,1,1,1,2,1")
        println(io, "PELAS,1,$k")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _write_celas2_deck(path::AbstractString)
    k = 1750.0
    f = 70.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CELAS2 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "CELAS2,1,$k,1,1,2,1")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _write_cbush_deck(path::AbstractString)
    k = 3200.0
    f = 160.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CBUSH route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "CBUSH,1,1,1,2")
        println(io, "PBUSH,1,K,$k,0.,0.,0.,0.,0.")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$f,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, stiffness=k, force=f)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    K, id_map, _, ndof, _, max_elem_stiff, _, _, _ = OpenJFEM._tacs_assemble_sol101(model)
    @test ndof == 12
    ux1 = _grid_dof(id_map, 1, 1)
    ux2 = _grid_dof(id_map, 2, 1)
    @test abs(K[ux2, ux2] - case.stiffness) / case.stiffness < 1e-12
    @test abs(K[ux1, ux2] + case.stiffness) / case.stiffness < 1e-12
    @test abs(max_elem_stiff - case.stiffness) / case.stiffness < 1e-12

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["spring"] == "residual_first_celas1_celas2_cbush_sol101_sol103"
    u = Float64.(results["subcases"][1]["u_analysis"])
    expected = case.force / case.stiffness
    relerr = abs(u[ux2] - expected) / max(abs(expected), 1e-30)
    @test relerr < 1e-12
    return relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_spring_")
    celas1 = _write_celas1_deck(joinpath(tmp, "tacs_celas1_sol101.bdf"))
    celas2 = _write_celas2_deck(joinpath(tmp, "tacs_celas2_sol101.bdf"))
    cbush = _write_cbush_deck(joinpath(tmp, "tacs_cbush_sol101.bdf"))
    celas1_relerr = _check_case(celas1)
    celas2_relerr = _check_case(celas2)
    cbush_relerr = _check_case(cbush)
    println("TACS SOL101 spring route guard passed")
    println("  CELAS1 displacement relerr = $celas1_relerr")
    println("  CELAS2 displacement relerr = $celas2_relerr")
    println("  CBUSH displacement relerr  = $cbush_relerr")
    return true
end

exit(main() ? 0 : 1)
