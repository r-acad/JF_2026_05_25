# Guard for the TACS-formulation CROD/CONROD geometric-stiffness operator.
#
# Usage:
#   julia --project=. tools/testing/tacs_rod_geometric_stiffness_operator_check.jl

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
    F = -1000.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CROD Kg operator check")
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
        println(io, "FORCE,1,2,0,$(abs(F)),-1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, length=L, force=F, group="CRODs")
end

function _write_conrod_deck(path::AbstractString)
    A = 7.0e-3
    J = 1.6e-5
    L = 1.5
    F = -600.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CONROD Kg operator check")
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
        println(io, "FORCE,1,2,0,$(abs(F)),-1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, length=L, force=F, group="CONRODs")
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    rod = first(values(results["model"][case.group]))
    Kg, dofs, axial_force = OpenJFEM._tacs_rod_geometric_stiffness_operator(
        results["model"],
        rod,
        results["id_map"],
        results["node_coords"],
        results["node_R"],
        Float64.(results["subcases"][1]["u_analysis"]),
    )
    @test norm(Kg - transpose(Kg)) / max(norm(Kg), 1e-30) < 1e-12
    force_relerr = abs(axial_force - case.force) / max(abs(case.force), 1e-30)
    @test force_relerr < 1e-10

    uy1 = findfirst(==( _grid_dof(results["id_map"], 1, 2)), dofs)
    uz1 = findfirst(==( _grid_dof(results["id_map"], 1, 3)), dofs)
    uy2 = findfirst(==( _grid_dof(results["id_map"], 2, 2)), dofs)
    uz2 = findfirst(==( _grid_dof(results["id_map"], 2, 3)), dofs)
    c = case.force / case.length
    @test abs(Kg[uy1, uy1] - c) / max(abs(c), 1e-30) < 1e-12
    @test abs(Kg[uy2, uy2] - c) / max(abs(c), 1e-30) < 1e-12
    @test abs(Kg[uy1, uy2] + c) / max(abs(c), 1e-30) < 1e-12
    @test abs(Kg[uz1, uz1] - c) / max(abs(c), 1e-30) < 1e-12
    @test abs(Kg[uz2, uz2] - c) / max(abs(c), 1e-30) < 1e-12
    @test abs(Kg[uz1, uz2] + c) / max(abs(c), 1e-30) < 1e-12
    return force_relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_rod_kg_")
    crod = _write_crod_deck(joinpath(tmp, "tacs_crod_kg.bdf"))
    conrod = _write_conrod_deck(joinpath(tmp, "tacs_conrod_kg.bdf"))
    crod_force_relerr = _check_case(crod)
    conrod_force_relerr = _check_case(conrod)
    println("TACS rod geometric-stiffness operator guard passed")
    println("  CROD axial-force relerr   = $crod_force_relerr")
    println("  CONROD axial-force relerr = $conrod_force_relerr")
    return true
end

exit(main() ? 0 : 1)
