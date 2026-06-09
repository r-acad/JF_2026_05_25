# Guard for mixed shell-plus-rod SOL105 geometric-stiffness assembly.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_mixed_rod_route_check.jl

using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_mixed_deck(path::AbstractString)
    A = 1.0e-2
    J = 2.5e-5
    L = 2.0
    axial_force = -800.0
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS mixed shell rod SOL105 Kg check")
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
        println(io, "GRID,5,,2.,0.,0.")
        println(io, "GRID,6,,$(2.0 + L),0.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "CROD,10,10,5,6")
        println(io, "PROD,10,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1,2,3,4,5")
        println(io, "SPC1,1,23456,6")
        println(io, "FORCE,1,6,0,$(-axial_force),-1.,0.,0.")
        println(io, "EIGRL,1,,,4")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, length=L, axial_force=axial_force)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_mixed_sol105_")
    case = _write_mixed_deck(joinpath(tmp, "mixed_shell_rod_sol105.bdf"))
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, rbe3_map, snorm_normals, _ =
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(105,), route_label="SOL105 mixed rod guard")
    @test ndof == 36
    @test nnz(K) > 0

    u_static = zeros(Float64, ndof)
    ux6 = _grid_dof(id_map, 6, 1)
    uy6 = _grid_dof(id_map, 6, 2)
    uz6 = _grid_dof(id_map, 6, 3)
    u_static[ux6] = case.axial_force * case.length / (E_ROD * case.area)

    timings = Dict{String,Any}()
    Kg = OpenJFEM._tacs_assemble_sol105_geometric_stiffness(
        model,
        id_map,
        X,
        node_R,
        ndof,
        u_static,
        snorm_normals,
        rbe3_map;
        timings=timings,
    )
    @test nnz(Kg) > 0
    @test Int(timings["tacs_native_kg_elements"]) == 1
    @test Int(timings["tacs_native_kg_rod_elements"]) == 1
    force_relerr = abs(Float64(timings["tacs_native_kg_avg_rod_axial_force"]) - case.axial_force) /
        max(abs(case.axial_force), 1e-30)
    @test force_relerr < 1e-12

    expected_c = case.axial_force / case.length
    uy_relerr = abs(Kg[uy6, uy6] - expected_c) / max(abs(expected_c), 1e-30)
    uz_relerr = abs(Kg[uz6, uz6] - expected_c) / max(abs(expected_c), 1e-30)
    @test uy_relerr < 1e-12
    @test uz_relerr < 1e-12

    println("TACS SOL105 mixed shell-plus-rod Kg guard passed")
    println("  rod axial-force relerr = $force_relerr")
    println("  rod Uy Kg relerr       = $uy_relerr")
    println("  rod Uz Kg relerr       = $uz_relerr")
    return true
end

exit(main() ? 0 : 1)
