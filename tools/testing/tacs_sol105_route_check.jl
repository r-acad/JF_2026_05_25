# Smoke check for routing SOL 105 buckling through the TACS-formulation backend.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_route_check.jl

using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _with_property_thickness(model::Dict, pid::Int, value::Float64)
    m = deepcopy(model)
    prop = m["PSHELLs"][string(pid)]
    prop["T"] = value
    if uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL"
        prop["Z1"] = -0.5 * value
        prop["Z2"] = 0.5 * value
    end
    return m
end

function _write_tria3_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 CTRIA3 route check")
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
        println(io, "CTRIA3,1,1,1,2,3")
        println(io, "CTRIA3,2,1,1,3,4")
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

function main()
    deck = joinpath(repo_root, "examples", "precompile", "sol105_quad_buckling.bdf")
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    eigenvalues = Float64.(results["eigenvalues"])
    K = results["K"]
    Kg = results["Kg"]

    @test results["sol_type"] == 105
    @test results["backend"] == "tacs_formulation"
    @test results["backend_version"] == "0.1.0-dev"
    @test results["formulation"]["shell"] == "residual_first_quad4_tria3_sol101_sol103_sol105_sol106"
    @test results["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_tria3"
    @test results["tacs_formulation_sol105"]["linear_stiffness"] == "residual_first_quad4_tria3"
    @test results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_tria3"
    @test results["tacs_formulation_sol105"]["eig_stiffness"] == "same_as_static_tangent"
    @test !isempty(eigenvalues)
    @test all(isfinite, eigenvalues)
    @test results["ndof"] == size(K, 1) == size(K, 2)
    @test size(results["K_eig"]) == size(K)
    @test size(Kg) == size(K)
    @test nnz(Kg) > 0
    @test length(results["u_static"]) == results["ndof"]
    @test _relative_symmetry_error(K) < 1e-12

    diagnostics = results["solver_diagnostics"]
    @test !isempty(diagnostics)
    @test haskey(diagnostics[1], "buckling_subcase")
    @test diagnostics[1]["buckling_subcase"] == 2
    @test diagnostics[1]["static_subcase"] == 1
    @test haskey(diagnostics[1]["kg_timings"], "tacs_native_kg_assembly")
    @test diagnostics[1]["kg_timings"]["tacs_native_kg_elements"] == 1

    pid = 1
    t0 = Float64(results["model"]["PSHELLs"][string(pid)]["T"])
    dt = max(1e-4 * t0, 1e-7)
    model_p = _with_property_thickness(model, pid, t0 + dt)
    model_m = _with_property_thickness(model, pid, t0 - dt)
    results_p = OpenJFEM.solve_model(model_p)
    results_m = OpenJFEM.solve_model(model_m)
    lambda_fd = (Float64(results_p["eigenvalues"][1]) - Float64(results_m["eigenvalues"][1])) / (2.0 * dt)

    phi = Vector{Float64}(results["_raw_mode_shapes"][:, 1])
    dK = (results_p["K_eig"] - results_m["K_eig"]) / (2.0 * dt)
    dKg = (results_p["Kg"] - results_m["Kg"]) / (2.0 * dt)
    lambda0 = Float64(eigenvalues[1])
    denom = dot(phi, -results["Kg"] * phi)
    lambda_rayleigh = dot(phi, (dK + lambda0 * dKg) * phi) / denom
    lambda_relerr = abs(lambda_rayleigh - lambda_fd) / max(abs(lambda_rayleigh), abs(lambda_fd), 1e-30)
    @test isfinite(lambda_fd)
    @test isfinite(lambda_rayleigh)
    @test lambda_relerr < 1e-4

    gradient_response = OpenJFEM.buckling_load_factor_thickness_gradient(results; pids=[pid], mode=1)
    @test gradient_response["gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    @test gradient_response["mode"] == 1
    lambda_hook = Float64(gradient_response["gradient"][string(pid)])
    lambda_hook_relerr = abs(lambda_hook - lambda_fd) / max(abs(lambda_hook), abs(lambda_fd), 1e-30)
    @test lambda_hook_relerr < 1e-4

    tmp = mktempdir(; prefix="openjfem_tacs_sol105_tria3_")
    tri_deck = _write_tria3_sol105_deck(joinpath(tmp, "tacs_sol105_tria3.bdf"))
    tri_model = OpenJFEM.bdf_to_model(tri_deck)
    tri_model["backend"] = "tacs_formulation"
    tri_results = OpenJFEM.solve_model(tri_model)
    tri_eigenvalues = Float64.(tri_results["eigenvalues"])
    @test tri_results["sol_type"] == 105
    @test tri_results["backend"] == "tacs_formulation"
    @test tri_results["formulation"]["shell"] == "residual_first_quad4_tria3_sol101_sol103_sol105_sol106"
    @test tri_results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_tria3"
    @test !isempty(tri_eigenvalues)
    @test all(isfinite, tri_eigenvalues)
    @test nnz(tri_results["Kg"]) > 0
    @test tri_results["solver_diagnostics"][1]["kg_timings"]["tacs_native_kg_elements"] == 2
    @test _relative_symmetry_error(tri_results["K"]) < 1e-12

    println("TACS SOL105 route check passed")
    println("  deck              = ", abspath(deck))
    println("  tria3 deck        = ", abspath(tri_deck))
    println("  modes             = ", length(eigenvalues))
    println("  first eigenvalue  = ", eigenvalues[1])
    println("  K symmetry error  = ", _relative_symmetry_error(K))
    println("  Kg nnz            = ", nnz(Kg))
    println("  dLambda/dt FD     = ", lambda_fd)
    println("  dLambda/dt RQ     = ", lambda_rayleigh)
    println("  dLambda rel error = ", lambda_relerr)
    println("  dLambda hook      = ", lambda_hook)
    println("  hook rel error    = ", lambda_hook_relerr)
    println("  tria3 first eigen = ", tri_eigenvalues[1])
    return true
end

main()
