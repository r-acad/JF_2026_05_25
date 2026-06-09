# Guard for TACS-formulation SOL105 CBAR/CBEAM beam Kg and sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_beam_route_sensitivity_check.jl

using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_BEAM = 2.1e11
const G_BEAM = 8.0e10
const RHO_BEAM = 7800.0

function _write_beam_buckling_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.0e-6
    I2 = 2.0e-6
    J = 3.0e-6
    L = 2.0
    axial_force = -800.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 $card beam Kg/sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 2")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "SPC1,2,123456,1")
        println(io, "SPC1,2,1246,2")
        println(io, "FORCE,1,2,0,$(-axial_force),-1.,0.,0.")
        println(io, "EIGRL,1,,,2")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, axial_force=axial_force)
end

function _write_beam_buckling_y_deck(path::AbstractString, card_type::AbstractString)
    A = 1.0e-2
    I1 = 1.5e-6
    I2 = 2.4e-6
    J = 3.0e-6
    L = 2.0
    axial_force = -800.0
    card = uppercase(card_type)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 $card beam_I1 Kg/sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 2")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "$card,1,1,1,2,0.,1.,0.")
        println(io, "PBAR,1,1,$A,$I1,$I2,$J")
        println(io, "MAT1,1,$E_BEAM,$G_BEAM,0.3125,$RHO_BEAM")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "SPC1,2,123456,1")
        println(io, "SPC1,2,1345,2")
        println(io, "FORCE,1,2,0,$(-axial_force),-1.,0.,0.")
        println(io, "EIGRL,1,,,2")
        println(io, "ENDDATA")
    end
    return (path=path, card=card, area=A, I1=I1, I2=I2, torsion=J, length=L, axial_force=axial_force)
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _relative_error(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function _solve(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _first_eigenvalue(model::AbstractDict)
    return Float64(_solve(model)["eigenvalues"][1])
end

function _expected_eigenvalue_from_submatrices(K::SparseMatrixCSC, Kg::SparseMatrixCSC, dofs::Vector{Int})
    Ksub = Matrix(K[dofs, dofs])
    Gsub = Matrix(Kg[dofs, dofs])
    vals = eigvals(Symmetric(Ksub), Symmetric(-Gsub))
    positive = sort!([Float64(v) for v in vals if isfinite(Float64(v)) && Float64(v) > 0.0])
    isempty(positive) && error("Beam SOL105 guard found no positive generalized eigenvalues.")
    return positive[1]
end

function _check_design_gradient(
    model::AbstractDict,
    results::AbstractDict,
    dv::Dict{String,Any};
    rel_tol::Real=1e-6,
    abs_tol::Real=0.0,
)
    response = OpenJFEM.buckling_load_factor_design_gradient(results, [dv]; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    h = Float64(response["directional_steps"][dv["id"]])
    hook = Float64(response["gradient"][dv["id"]])
    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (_first_eigenvalue(model_p) - _first_eigenvalue(model_m)) / (2.0 * h)
    err = abs(hook - fd)
    rel = _relative_error(hook, fd)
    @test isfinite(hook)
    @test isfinite(fd)
    if max(abs(hook), abs(fd)) <= Float64(abs_tol)
        @test err <= Float64(abs_tol)
    else
        @test rel < Float64(rel_tol)
    end
    return (fd=fd, hook=hook, rel=rel, err=err)
end

function _check_ks_gradient(
    model::AbstractDict,
    results::AbstractDict,
    dv::Dict{String,Any};
    rel_tol::Real=1e-6,
    abs_tol::Real=0.0,
)
    response = OpenJFEM.buckling_load_factor_ks_design_gradient(results, [dv]; modes=[1], rho=1.0)
    @test response["gradient_backend"] == "tacs_formulation_buckling_ks_weighted_rayleigh"
    @test response["base_gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    h = Float64(response["design_variable_diagnostics"][dv["id"]]["mode_diagnostics"]["1"]["directional_step"])
    hook = Float64(response["gradient"][dv["id"]])
    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (_first_eigenvalue(model_p) - _first_eigenvalue(model_m)) / (2.0 * h)
    err = abs(hook - fd)
    rel = _relative_error(hook, fd)
    @test isfinite(hook)
    @test isfinite(fd)
    if max(abs(hook), abs(fd)) <= Float64(abs_tol)
        @test err <= Float64(abs_tol)
    else
        @test rel < Float64(rel_tol)
    end
    return (fd=fd, hook=hook, rel=rel, err=err)
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, rbe3_map, snorm_normals, _ =
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(105,), route_label="SOL105 beam guard")
    @test ndof == 12
    ux2 = _grid_dof(id_map, 2, 1)
    uz2 = _grid_dof(id_map, 2, 3)
    ry2 = _grid_dof(id_map, 2, 5)

    u_static = zeros(Float64, ndof)
    u_static[ux2] = case.axial_force * case.length / (E_BEAM * case.area)
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
    @test Int(timings["tacs_native_kg_beam_elements"]) == 1
    force_relerr = _relative_error(Float64(timings["tacs_native_kg_avg_beam_axial_force"]), case.axial_force)
    @test force_relerr < 1e-12

    c1 = 6.0 * case.axial_force / (5.0 * case.length)
    c2 = case.axial_force / 10.0
    c3 = 2.0 * case.axial_force * case.length / 15.0
    kg_uz_relerr = _relative_error(Kg[uz2, uz2], c1)
    kg_couple_relerr = _relative_error(Kg[uz2, ry2], c2)
    kg_ry_relerr = _relative_error(Kg[ry2, ry2], c3)
    @test kg_uz_relerr < 1e-12
    @test kg_couple_relerr < 1e-12
    @test kg_ry_relerr < 1e-12

    expected_lambda = _expected_eigenvalue_from_submatrices(K, Kg, [uz2, ry2])
    results = _solve(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test results["formulation"]["beam_geometric_stiffness"] == "native_residual_first_cbar_cbeam_operator"
    @test results["tacs_formulation_sol105"]["beam_geometric_stiffness"] == "native_residual_first_cbar_cbeam_operator"
    @test Int(get(get(results["solver_diagnostics"][1], "kg_timings", Dict()), "tacs_native_kg_beam_elements", 0)) == 1
    eig_relerr = _relative_error(Float64(results["eigenvalues"][1]), expected_lambda)
    @test eig_relerr < 1e-9

    i2_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I2", "type" => "beam_I2", "pids" => [1])
    area_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_area", "type" => "beam_area", "pids" => [1])
    j_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_J", "type" => "beam_J", "pids" => [1])
    e_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_E", "type" => "material_E", "mids" => [1])
    i2 = _check_design_gradient(model, results, i2_dv)
    area = _check_design_gradient(model, results, area_dv; abs_tol=1e-3)
    torsion = _check_design_gradient(model, results, j_dv; abs_tol=1e-3)
    mat_e = _check_design_gradient(model, results, e_dv)
    i2_ks = _check_ks_gradient(model, results, i2_dv)
    area_ks = _check_ks_gradient(model, results, area_dv; abs_tol=1e-3)
    torsion_ks = _check_ks_gradient(model, results, j_dv; abs_tol=1e-3)

    return Dict(
        "force" => force_relerr,
        "kg_uz" => kg_uz_relerr,
        "kg_couple" => kg_couple_relerr,
        "kg_ry" => kg_ry_relerr,
        "eigenvalue" => eig_relerr,
        "beam_I2" => i2,
        "beam_area" => area,
        "beam_J" => torsion,
        "material_E" => mat_e,
        "beam_I2_ks" => i2_ks,
        "beam_area_ks" => area_ks,
        "beam_J_ks" => torsion_ks,
    )
end

function _check_i1_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, rbe3_map, snorm_normals, _ =
        OpenJFEM._tacs_assemble_sol101(model; allowed_sol_types=(105,), route_label="SOL105 beam_I1 guard")
    @test ndof == 12
    ux2 = _grid_dof(id_map, 2, 1)
    uy2 = _grid_dof(id_map, 2, 2)
    rz2 = _grid_dof(id_map, 2, 6)

    u_static = zeros(Float64, ndof)
    u_static[ux2] = case.axial_force * case.length / (E_BEAM * case.area)
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
    @test Int(timings["tacs_native_kg_beam_elements"]) == 1
    force_relerr = _relative_error(Float64(timings["tacs_native_kg_avg_beam_axial_force"]), case.axial_force)
    @test force_relerr < 1e-12

    c1 = 6.0 * case.axial_force / (5.0 * case.length)
    c2 = case.axial_force / 10.0
    c3 = 2.0 * case.axial_force * case.length / 15.0
    kg_uy_relerr = _relative_error(Kg[uy2, uy2], c1)
    kg_couple_relerr = _relative_error(Kg[uy2, rz2], -c2)
    kg_rz_relerr = _relative_error(Kg[rz2, rz2], c3)
    @test kg_uy_relerr < 1e-12
    @test kg_couple_relerr < 1e-12
    @test kg_rz_relerr < 1e-12

    expected_lambda = _expected_eigenvalue_from_submatrices(K, Kg, [uy2, rz2])
    results = _solve(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test results["formulation"]["beam_geometric_stiffness"] == "native_residual_first_cbar_cbeam_operator"
    eig_relerr = _relative_error(Float64(results["eigenvalues"][1]), expected_lambda)
    @test eig_relerr < 1e-9

    i1_dv = Dict{String,Any}("id" => "$(lowercase(case.card))_I1", "type" => "beam_I1", "pids" => [1])
    i1 = _check_design_gradient(model, results, i1_dv)
    i1_ks = _check_ks_gradient(model, results, i1_dv)

    return Dict(
        "force" => force_relerr,
        "kg_uy" => kg_uy_relerr,
        "kg_couple" => kg_couple_relerr,
        "kg_rz" => kg_rz_relerr,
        "eigenvalue" => eig_relerr,
        "beam_I1" => i1,
        "beam_I1_ks" => i1_ks,
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_beam_sol105_")
    cbar = _write_beam_buckling_deck(joinpath(tmp, "tacs_cbar_sol105_beam.bdf"), "CBAR")
    cbeam = _write_beam_buckling_deck(joinpath(tmp, "tacs_cbeam_sol105_beam.bdf"), "CBEAM")
    cbar_i1 = _write_beam_buckling_y_deck(joinpath(tmp, "tacs_cbar_sol105_beam_i1.bdf"), "CBAR")
    cbeam_i1 = _write_beam_buckling_y_deck(joinpath(tmp, "tacs_cbeam_sol105_beam_i1.bdf"), "CBEAM")

    cbar_checks = _check_case(cbar)
    cbeam_checks = _check_case(cbeam)
    cbar_i1_checks = _check_i1_case(cbar_i1)
    cbeam_i1_checks = _check_i1_case(cbeam_i1)

    println("TACS SOL105 beam Kg/sensitivity guard passed")
    for (name, checks, i1_checks) in (
        ("CBAR", cbar_checks, cbar_i1_checks),
        ("CBEAM", cbeam_checks, cbeam_i1_checks),
    )
        println("  $name beam axial-force relerr = ", checks["force"])
        println("  $name Kg UZ relerr            = ", checks["kg_uz"])
        println("  $name Kg UZ/RY relerr         = ", checks["kg_couple"])
        println("  $name Kg RY relerr            = ", checks["kg_ry"])
        println("  $name eigenvalue relerr       = ", checks["eigenvalue"])
        println("  $name beam_I2 FD/hook/rel     = ",
            checks["beam_I2"].fd, " / ", checks["beam_I2"].hook, " / ", checks["beam_I2"].rel)
        println("  $name beam_area FD/hook/err   = ",
            checks["beam_area"].fd, " / ", checks["beam_area"].hook, " / ", checks["beam_area"].err)
        println("  $name beam_J FD/hook/err      = ",
            checks["beam_J"].fd, " / ", checks["beam_J"].hook, " / ", checks["beam_J"].err)
        println("  $name material_E FD/hook/rel  = ",
            checks["material_E"].fd, " / ", checks["material_E"].hook, " / ", checks["material_E"].rel)
        println("  $name beam_I2 KS FD/hook/rel  = ",
            checks["beam_I2_ks"].fd, " / ", checks["beam_I2_ks"].hook, " / ", checks["beam_I2_ks"].rel)
        println("  $name beam_area KS FD/hook/err = ",
            checks["beam_area_ks"].fd, " / ", checks["beam_area_ks"].hook, " / ", checks["beam_area_ks"].err)
        println("  $name beam_J KS FD/hook/err    = ",
            checks["beam_J_ks"].fd, " / ", checks["beam_J_ks"].hook, " / ", checks["beam_J_ks"].err)
        println("  $name beam_I1 Kg UY relerr    = ", i1_checks["kg_uy"])
        println("  $name beam_I1 Kg UY/RZ relerr = ", i1_checks["kg_couple"])
        println("  $name beam_I1 Kg RZ relerr    = ", i1_checks["kg_rz"])
        println("  $name beam_I1 eigen relerr    = ", i1_checks["eigenvalue"])
        println("  $name beam_I1 FD/hook/rel     = ",
            i1_checks["beam_I1"].fd, " / ", i1_checks["beam_I1"].hook, " / ", i1_checks["beam_I1"].rel)
        println("  $name beam_I1 KS FD/hook/rel  = ",
            i1_checks["beam_I1_ks"].fd, " / ", i1_checks["beam_I1_ks"].hook, " / ", i1_checks["beam_I1_ks"].rel)
    end
    return true
end

exit(main() ? 0 : 1)
