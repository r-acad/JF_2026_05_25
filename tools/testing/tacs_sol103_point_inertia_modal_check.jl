# Finite-difference guard for TACS SOL103 CONM2 point-inertia modal sensitivity.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_point_inertia_modal_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

function _write_rotational_oscillator(path::AbstractString)
    k = 4500.0
    i11 = 2.5
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 CONM2 point inertia check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "CELAS2,1,$k,1,4")
        println(io, "CONM2,1,1,,0.1,0.,0.,0.,,$i11,0.,0.,0.,0.,0.")
        println(io, "SPC1,1,12356,1")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, k=k, i11=i11)
end

function _write_coupled_rotational_oscillator(path::AbstractString)
    k1 = 4200.0
    k2 = 5100.0
    i11 = 2.5
    i21 = 0.35
    i22 = 3.0
    i33 = 1.0
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 CONM2 coupled point inertia check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "CELAS2,1,$k1,1,4")
        println(io, "CELAS2,2,$k2,1,5")
        println(io, "CONM2,1,1,,0.1,0.,0.,0.,,$i11,$i21,$i22,0.,0.,$i33")
        println(io, "SPC1,1,1236,1")
        println(io, "EIGRL,1,0.,1.0E8,2")
        println(io, "ENDDATA")
    end
    return (path=path, k1=k1, k2=k2, i11=i11, i21=i21, i22=i22)
end

function _relative_error(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function _solve_tacs(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _eigenvalue(model::AbstractDict, mode::Integer=1)
    return Float64(_solve_tacs(model)["eigenvalues"][Int(mode)])
end

function _grid_dof(id_map, grid::Int, dof::Int)
    return (id_map[grid] - 1) * 6 + dof
end

function _expected_coupled_inertia_derivative(case, term::Integer, mode::Integer)
    K2 = Diagonal([case.k1, case.k2])
    M2 = Symmetric([case.i11 case.i21; case.i21 case.i22])
    eig = eigen(Symmetric(Matrix(K2)), M2)
    order = sortperm(Float64.(eig.values))
    idx = order[Int(mode)]
    lambda = Float64(eig.values[idx])
    phi = Float64.(eig.vectors[:, idx])
    dM = zeros(Float64, 2, 2)
    if Int(term) == 1
        dM[1, 1] = 1.0
    elseif Int(term) == 2
        dM[1, 2] = 1.0
        dM[2, 1] = 1.0
    elseif Int(term) == 3
        dM[2, 2] = 1.0
    else
        error("Coupled CONM2 point-inertia guard supports terms 1, 2, and 3.")
    end
    return -lambda * dot(phi, dM * phi) / dot(phi, Matrix(M2) * phi)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_point_inertia_modal_")
    case = _write_rotational_oscillator(joinpath(tmp, "tacs_conm2_point_inertia_sol103.bdf"))
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    expected_lambda = case.k / case.i11
    actual_lambda = Float64(results["eigenvalues"][1])
    eig_rel = _relative_error(actual_lambda, expected_lambda)
    @test eig_rel < 1e-12
    @test occursin("shared_jfem_modal_point_mass", results["tacs_formulation_sol103"]["mass"])

    dv = Dict{String,Any}(
        "id" => "conm2_i11",
        "type" => "point_inertia",
        "eids" => [1],
        "component" => 1,
    )
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    @test response["response"] == "modal_eigenvalue"
    @test response["gradient_backend"] == "tacs_formulation_modal_mass_design_fd"
    h = Float64(response["design_variable_diagnostics"]["conm2_i11"]["step"])
    hook = Float64(response["gradient"]["conm2_i11"])
    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (_eigenvalue(model_p) - _eigenvalue(model_m)) / (2.0 * h)
    expected_grad = -case.k / case.i11^2
    rel_fd = _relative_error(hook, fd)
    rel_expected = _relative_error(hook, expected_grad)
    @test isfinite(hook)
    @test isfinite(fd)
    @test rel_fd < 1e-6
    @test rel_expected < 1e-10

    println("TACS SOL103 point-inertia modal guard passed")
    println("  eigenvalue actual/expected/rel = ", actual_lambda, " / ", expected_lambda, " / ", eig_rel)
    println("  dLambda/dI11 FD/hook/expected = ", fd, " / ", hook, " / ", expected_grad)
    println("  derivative rel FD/expected    = ", rel_fd, " / ", rel_expected)

    coupled = _write_coupled_rotational_oscillator(joinpath(tmp, "tacs_conm2_coupled_point_inertia_sol103.bdf"))
    coupled_model = OpenJFEM.bdf_to_model(coupled.path)
    coupled_model["backend"] = "tacs_formulation"
    coupled_results = OpenJFEM.solve_model(coupled_model)
    K2 = Diagonal([coupled.k1, coupled.k2])
    M2 = Symmetric([coupled.i11 coupled.i21; coupled.i21 coupled.i22])
    expected = sort(Float64.(eigen(Symmetric(Matrix(K2)), M2).values))
    actual = sort(Float64.(coupled_results["eigenvalues"][1:2]))
    coupled_rels = [_relative_error(actual[i], expected[i]) for i in eachindex(expected)]
    @test maximum(coupled_rels) < 1e-10

    dv_i21 = Dict{String,Any}(
        "id" => "conm2_i21",
        "type" => "point_inertia",
        "eids" => [1],
        "term" => 2,
    )
    response_i21 = OpenJFEM.modal_eigenvalue_design_gradient(coupled_results, [dv_i21]; mode=1)
    @test response_i21["gradient_backend"] == "tacs_formulation_modal_mass_design_fd"
    h_i21 = Float64(response_i21["design_variable_diagnostics"]["conm2_i21"]["step"])
    hook_i21 = Float64(response_i21["gradient"]["conm2_i21"])
    dM_i21, id_map, _, _, _, _ =
        OpenJFEM._tacs_assemble_sol103_mass_design_derivative(coupled_model, dv_i21; step=h_i21)
    r1 = _grid_dof(id_map, 1, 4)
    r2 = _grid_dof(id_map, 1, 5)
    @test isapprox(dM_i21[r1, r2], 1.0; rtol=0.0, atol=1e-9)
    @test isapprox(dM_i21[r2, r1], 1.0; rtol=0.0, atol=1e-9)
    coupled_p = OpenJFEM._tacs_model_with_design_delta(coupled_model, dv_i21, h_i21)
    coupled_m = OpenJFEM._tacs_model_with_design_delta(coupled_model, dv_i21, -h_i21)
    fd_i21 = (_eigenvalue(coupled_p, 1) - _eigenvalue(coupled_m, 1)) / (2.0 * h_i21)
    expected_i21 = _expected_coupled_inertia_derivative(coupled, 2, 1)
    rel_i21_fd = _relative_error(hook_i21, fd_i21)
    rel_i21_expected = _relative_error(hook_i21, expected_i21)
    @test isfinite(hook_i21)
    @test isfinite(fd_i21)
    @test rel_i21_fd < 1e-6
    @test rel_i21_expected < 1e-8

    println("  coupled eigenvalues expected/actual = ", expected, " / ", actual)
    println("  coupled max relative error          = ", maximum(coupled_rels))
    println("  dLambda/dI21 FD/hook/expected      = ", fd_i21, " / ", hook_i21, " / ", expected_i21)
    println("  dLambda/dI21 rel FD/expected       = ", rel_i21_fd, " / ", rel_i21_expected)
    return true
end

exit(main() ? 0 : 1)
