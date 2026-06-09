# Guard for the TACS-formulation SOL103 CBAR/CBEAM modal slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_beam_modal_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_modal_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $card modal route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,1246,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _expected_bending_lambda(case)
    L = case.length
    K2 = [
        12.0 * E_BEAM * case.I2 / L^3    -6.0 * E_BEAM * case.I2 / L^2;
        -6.0 * E_BEAM * case.I2 / L^2     4.0 * E_BEAM * case.I2 / L
    ]
    M2 = Diagonal([
        RHO_BEAM * case.area * L / 2.0,
        RHO_BEAM * case.I2 * L / 2.0,
    ])
    vals = sort!(real.(eigvals(Symmetric(K2), Symmetric(Matrix(M2)))))
    return vals[1]
end

function _check_modal_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, _, _, _ =
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(103,), route_label="SOL103")
    M = OpenJFEM._tacs_sol103_modal_mass_builder(model, id_map, X, node_R, ndof)
    @test norm(Matrix(K) - transpose(Matrix(K))) / max(norm(K), 1e-30) < 1e-12
    @test norm(Matrix(M) - transpose(Matrix(M))) / max(norm(M), 1e-30) < 1e-12

    uz2 = _grid_dof(id_map, 2, 3)
    ry2 = _grid_dof(id_map, 2, 5)
    m_trans = RHO_BEAM * case.area * case.length / 2.0
    m_rot_y = RHO_BEAM * case.I2 * case.length / 2.0
    @test abs(M[uz2, uz2] - m_trans) / m_trans < 1e-12
    @test abs(M[ry2, ry2] - m_rot_y) / m_rot_y < 1e-12

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test occursin("residual_first_cbar_cbeam_sol101_sol103_sol105", results["tacs_formulation_sol103"]["linear_stiffness"])
    @test occursin("tacs_lumped_cbar_cbeam_mass", results["tacs_formulation_sol103"]["mass"])
    @test !isempty(results["eigenvalues"])

    expected_lambda = _expected_bending_lambda(case)
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
    tmp = mktempdir(; prefix="openjfem_tacs_beam_modal_")
    cbar = _write_beam_modal_deck(joinpath(tmp, "tacs_cbar_sol103.bdf"), "CBAR")
    cbeam = _write_beam_modal_deck(joinpath(tmp, "tacs_cbeam_sol103.bdf"), "CBEAM")

    cbar_lambda_relerr, cbar_freq_relerr = _check_modal_case(cbar)
    cbeam_lambda_relerr, cbeam_freq_relerr = _check_modal_case(cbeam)

    println("TACS SOL103 beam modal route guard passed")
    println("  CBAR eigenvalue relerr  = $cbar_lambda_relerr")
    println("  CBAR frequency relerr   = $cbar_freq_relerr")
    println("  CBEAM eigenvalue relerr = $cbeam_lambda_relerr")
    println("  CBEAM frequency relerr  = $cbeam_freq_relerr")
    return true
end

exit(main() ? 0 : 1)
