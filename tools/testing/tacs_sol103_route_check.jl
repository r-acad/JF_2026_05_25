# Smoke check for routing SOL 103 normal modes through the TACS-formulation backend.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _relative_error(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function _write_tria3_sol103_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS CTRIA3 SOL103 route check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "PARAM,COUPMASS,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CTRIA3,1,1,1,2,3")
        println(io, "CTRIA3,2,1,1,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "EIGRL,1,0.,1.0E9,6")
        println(io, "ENDDATA")
    end
    return path
end

function _check_sol103_deck(deck::AbstractString; expected_shell_mass::AbstractString="coupled_consistent")
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    eigenvalues = Float64.(results["eigenvalues"])
    frequencies = Float64.(results["frequencies"])
    K = results["K"]

    @test results["sol_type"] == 103
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test results["tacs_formulation_sol103"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol103"]["mass"] == "shared_jfem_mass_" * expected_shell_mass
    @test results["tacs_formulation_sol103"]["eigensolver"] == "shared_sol103"
    @test !isempty(eigenvalues)
    @test !isempty(frequencies)
    @test all(isfinite, eigenvalues)
    @test all(isfinite, frequencies)
    @test all(>=(0.0), frequencies)
    @test size(K, 1) == size(K, 2)
    @test _relative_symmetry_error(K) < 1e-12
    @test haskey(results, "mass_summary")
    @test results["mass_summary"]["shell_mass_formulation"] == expected_shell_mass
    @test haskey(results, "solver_diagnostics")
    @test results["solver_diagnostics"]["shell_mass_formulation"] == expected_shell_mass
    @test haskey(results, "subcases")
    @test length(results["subcases"]) == 1
    return results, eigenvalues, frequencies, K
end

function _solve_first_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(m)
    return Float64(results["eigenvalues"][1])
end

function _model_with_pshell_thickness_delta(model::AbstractDict, pid::Integer, delta::Real)
    m = deepcopy(model)
    prop = get(get(m, "PSHELLs", Dict()), string(Int(pid)), nothing)
    prop === nothing && error("Could not find PSHELL property $pid for SOL103 FD check.")
    t = Float64(get(prop, "T", 0.0)) + Float64(delta)
    t > 0.0 || error("SOL103 FD check produced nonpositive thickness for property $pid.")
    prop["T"] = t
    if uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL"
        prop["Z1"] = -0.5 * t
        prop["Z2"] = 0.5 * t
    end
    m["backend"] = "tacs_formulation"
    return m
end

function _model_with_material_field_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = get(get(m, "MATs", Dict()), string(Int(mid)), nothing)
    mat === nothing && error("Could not find material $mid for SOL103 FD check.")
    field_key = uppercase(field)
    mat[field_key] = Float64(get(mat, field_key, 0.0)) + Float64(delta)
    m["backend"] = "tacs_formulation"
    return m
end

function _model_with_grid_coord_delta(model::AbstractDict, grid::Integer, comp::Integer, delta::Real)
    m = deepcopy(model)
    grid_data = get(get(m, "GRIDs", Dict()), string(Int(grid)), nothing)
    grid_data === nothing && error("Could not find GRID $grid for SOL103 FD check.")
    x = Float64.(collect(get(grid_data, "X", Float64[])))
    length(x) >= 3 || error("GRID $grid does not have three coordinates.")
    x[Int(comp)] += Float64(delta)
    grid_data["X"] = x
    m["backend"] = "tacs_formulation"
    return m
end

function _check_modal_gradient(results::AbstractDict, dv::AbstractDict, fd_gradient::Real; rel_tol=5e-5, abs_tol=1e-4)
    modal_gradient = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    dv_id = string(dv["id"])
    hook_gradient = Float64(modal_gradient["gradient"][dv_id])
    rel_err = _relative_error(hook_gradient, fd_gradient)
    @test modal_gradient["response"] == "modal_eigenvalue"
    @test modal_gradient["mode"] == 1
    @test isfinite(hook_gradient)
    @test isfinite(Float64(modal_gradient["frequency_gradient"][dv_id]))
    @test rel_err < rel_tol || abs(hook_gradient - Float64(fd_gradient)) < abs_tol
    return modal_gradient, hook_gradient, rel_err
end

function _check_sol103_modal_design_gradients(results::AbstractDict)
    model = results["model"]

    t0 = Float64(model["PSHELLs"]["1"]["T"])
    h_t = max(1e-5 * t0, 1e-7)
    lambda_t_p = _solve_first_eigenvalue(_model_with_pshell_thickness_delta(model, 1, h_t))
    lambda_t_m = _solve_first_eigenvalue(_model_with_pshell_thickness_delta(model, 1, -h_t))
    fd_t = (lambda_t_p - lambda_t_m) / (2.0 * h_t)
    thickness_dv = Dict{String,Any}("id" => "t_pid1", "type" => "shell_thickness", "pids" => [1], "step" => h_t)
    _, hook_t, rel_t = _check_modal_gradient(results, thickness_dv, fd_t)

    E0 = Float64(model["MATs"]["1"]["E"])
    h_E = max(1e-6 * E0, 1e-3)
    lambda_E_p = _solve_first_eigenvalue(_model_with_material_field_delta(model, 1, "E", h_E))
    lambda_E_m = _solve_first_eigenvalue(_model_with_material_field_delta(model, 1, "E", -h_E))
    fd_E = (lambda_E_p - lambda_E_m) / (2.0 * h_E)
    E_dv = Dict{String,Any}("id" => "E_mid1", "type" => "material_E", "mids" => [1])
    _, hook_E, rel_E = _check_modal_gradient(results, E_dv, fd_E)

    rho0 = Float64(model["MATs"]["1"]["RHO"])
    h_rho = max(1e-6 * rho0, 1e-6)
    lambda_rho_p = _solve_first_eigenvalue(_model_with_material_field_delta(model, 1, "RHO", h_rho))
    lambda_rho_m = _solve_first_eigenvalue(_model_with_material_field_delta(model, 1, "RHO", -h_rho))
    fd_rho = (lambda_rho_p - lambda_rho_m) / (2.0 * h_rho)
    rho_dv = Dict{String,Any}("id" => "rho_mid1", "type" => "material_RHO", "mids" => [1], "step" => h_rho)
    _, hook_rho, rel_rho = _check_modal_gradient(results, rho_dv, fd_rho)

    h_x = 1e-6
    lambda_x_p = _solve_first_eigenvalue(_model_with_grid_coord_delta(model, 2, 1, h_x))
    lambda_x_m = _solve_first_eigenvalue(_model_with_grid_coord_delta(model, 2, 1, -h_x))
    fd_x = (lambda_x_p - lambda_x_m) / (2.0 * h_x)
    x_dv = Dict{String,Any}("id" => "grid2_x", "type" => "node_coord", "grid" => 2, "comp" => 1, "step" => h_x)
    _, hook_x, rel_x = _check_modal_gradient(results, x_dv, fd_x; rel_tol=1e-4, abs_tol=1e-3)

    return Dict(
        "thickness" => (fd_t, hook_t, rel_t),
        "material_E" => (fd_E, hook_E, rel_E),
        "material_RHO" => (fd_rho, hook_rho, rel_rho),
        "node_coord" => (fd_x, hook_x, rel_x),
    )
end

function main()
    deck = joinpath(repo_root, "examples", "precompile", "sol103_quad_modes.bdf")
    tria3_deck = _write_tria3_sol103_deck(joinpath(mktempdir(; prefix="openjfem_tacs_sol103_route_"), "tacs_tria3_sol103_route.bdf"))

    results, eigenvalues, frequencies, K = _check_sol103_deck(deck)
    tria3_results, tria3_eigenvalues, tria3_frequencies, tria3_K =
        _check_sol103_deck(tria3_deck; expected_shell_mass="coupled_consistent")
    modal_gradient_checks = _check_sol103_modal_design_gradients(results)

    println("TACS SOL103 route check passed")
    println("  deck              = ", abspath(deck))
    println("  tria3 deck        = ", abspath(tria3_deck))
    println("  modes             = ", length(eigenvalues))
    println("  first eigenvalue  = ", eigenvalues[1])
    println("  first frequency   = ", frequencies[1])
    println("  K symmetry error  = ", _relative_symmetry_error(K))
    println("  tria3 modes       = ", length(tria3_eigenvalues))
    println("  tria3 first eigenvalue = ", tria3_eigenvalues[1])
    println("  tria3 first frequency = ", tria3_frequencies[1])
    println("  tria3 K symmetry error = ", _relative_symmetry_error(tria3_K))
    for (name, check) in sort(collect(modal_gradient_checks); by=first)
        fd, hook, rel = check
        println("  modal dLambda/d", name, " FD = ", fd, " hook = ", hook, " rel = ", rel)
    end
    return true
end

main()
