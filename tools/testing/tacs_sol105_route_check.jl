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

function _ks_min_load_factor(eigenvalues, modes, rho::Real)
    rho_f = Float64(rho)
    values = Float64[Float64(eigenvalues[Int(mode)]) for mode in modes]
    lambda_min = minimum(values)
    raw = exp.(-rho_f .* (values .- lambda_min))
    return lambda_min - log(sum(raw)) / rho_f
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

function _with_node_coord(model::Dict, grid::Int, comp::Int, delta::Float64)
    m = deepcopy(model)
    grid_data = m["GRIDs"][string(grid)]
    coords = Float64.(collect(grid_data["X"]))
    coords[comp] += delta
    grid_data["X"] = coords
    return m
end

function _with_material_field(model::Dict, mid::Int, field::AbstractString, delta::Float64)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + delta
    if field_key == "NU"
        E = Float64(mat["E"])
        mat["G"] = E / (2.0 * (1.0 + Float64(mat[field_key])))
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

function _write_pcomp_sol105_deck(path::AbstractString; ply1_t::Float64=0.0025)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL105 PCOMP design-gradient check")
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
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "PCOMP,1,,,,,,,,1,$ply1_t,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
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
    @test results["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test results["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol105"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
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

    thickness_dv = Dict{String,Any}(
        "id" => "pid$(pid)_thickness",
        "type" => "shell_thickness",
        "pids" => [pid],
    )
    generic_thickness_response = OpenJFEM.buckling_load_factor_design_gradient(results, [thickness_dv]; mode=1)
    @test generic_thickness_response["gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    lambda_generic_t = Float64(generic_thickness_response["gradient"]["pid$(pid)_thickness"])
    lambda_generic_t_relerr = abs(lambda_generic_t - lambda_fd) / max(abs(lambda_generic_t), abs(lambda_fd), 1e-30)
    @test lambda_generic_t_relerr < 1e-4

    ks_modes = [1, 2]
    ks_rho = 0.01
    ks_fd = (
        _ks_min_load_factor(results_p["eigenvalues"], ks_modes, ks_rho) -
        _ks_min_load_factor(results_m["eigenvalues"], ks_modes, ks_rho)
    ) / (2.0 * dt)
    ks_response = OpenJFEM.buckling_load_factor_ks_design_gradient(results, [thickness_dv]; modes=ks_modes, rho=ks_rho)
    @test ks_response["response"] == "buckling_ks_load_factor"
    @test ks_response["aggregation"] == "smooth_min_load_factor"
    @test ks_response["gradient_backend"] == "tacs_formulation_buckling_ks_weighted_rayleigh"
    @test ks_response["base_gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    @test ks_response["modes"] == ks_modes
    @test abs(sum(values(ks_response["mode_weights"])) - 1.0) < 1e-12
    ks_hook = Float64(ks_response["gradient"]["pid$(pid)_thickness"])
    ks_relerr = abs(ks_hook - ks_fd) / max(abs(ks_hook), abs(ks_fd), 1e-30)
    @test isfinite(ks_fd)
    @test isfinite(ks_hook)
    @test ks_relerr < 1e-4

    mid = 1
    e0 = Float64(results["model"]["MATs"][string(mid)]["E"])
    dE = max(1e-6 * e0, 1e-3)
    mat_model_p = _with_material_field(model, mid, "E", dE)
    mat_model_m = _with_material_field(model, mid, "E", -dE)
    mat_results_p = OpenJFEM.solve_model(mat_model_p)
    mat_results_m = OpenJFEM.solve_model(mat_model_m)
    lambda_fd_E = (Float64(mat_results_p["eigenvalues"][1]) - Float64(mat_results_m["eigenvalues"][1])) / (2.0 * dE)
    material_dv = Dict{String,Any}(
        "id" => "mat$(mid)_E",
        "type" => "material_E",
        "mids" => [mid],
    )
    material_response = OpenJFEM.buckling_load_factor_design_gradient(results, [material_dv]; mode=1)
    @test material_response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    lambda_hook_E = Float64(material_response["gradient"]["mat$(mid)_E"])
    lambda_hook_E_relerr = abs(lambda_hook_E - lambda_fd_E) / max(abs(lambda_hook_E), abs(lambda_fd_E), 1e-30)
    @test isfinite(lambda_fd_E)
    @test isfinite(lambda_hook_E)
    @test lambda_hook_E_relerr < 1e-4

    coord_grid = 2
    coord_comp = 1
    dx = 1e-5
    coord_dv = Dict{String,Any}(
        "id" => "grid$(coord_grid)_x",
        "type" => "node_coord",
        "grid" => coord_grid,
        "comp" => coord_comp,
        "step" => dx,
    )
    coord_model_p = _with_node_coord(model, coord_grid, coord_comp, dx)
    coord_model_m = _with_node_coord(model, coord_grid, coord_comp, -dx)
    coord_results_p = OpenJFEM.solve_model(coord_model_p)
    coord_results_m = OpenJFEM.solve_model(coord_model_m)
    lambda_fd_x = (Float64(coord_results_p["eigenvalues"][1]) - Float64(coord_results_m["eigenvalues"][1])) / (2.0 * dx)

    coord_gradient_response = OpenJFEM.buckling_load_factor_design_gradient(results, [coord_dv]; mode=1)
    @test coord_gradient_response["gradient_backend"] == "tacs_formulation_rayleigh_coordinate_kg_directional_fd"
    @test coord_gradient_response["mode"] == 1
    @test haskey(coord_gradient_response["design_variable_diagnostics"], "grid$(coord_grid)_x")
    @test coord_gradient_response["design_variable_diagnostics"]["grid$(coord_grid)_x"]["sensitivity_contract"]["coordinate_supported"] == true
    lambda_hook_x = Float64(coord_gradient_response["gradient"]["grid$(coord_grid)_x"])
    lambda_hook_x_relerr = abs(lambda_hook_x - lambda_fd_x) / max(abs(lambda_hook_x), abs(lambda_fd_x), 1e-30)
    @test isfinite(lambda_fd_x)
    @test isfinite(lambda_hook_x)
    @test lambda_hook_x_relerr < 5e-4

    pcomp_tmp = mktempdir(; prefix="openjfem_tacs_sol105_pcomp_")
    pcomp_t0 = 0.0025
    dpcomp_t = max(1e-6 * pcomp_t0, 1e-10)
    pcomp_deck = _write_pcomp_sol105_deck(joinpath(pcomp_tmp, "tacs_sol105_pcomp.bdf"); ply1_t=pcomp_t0)
    pcomp_deck_p = _write_pcomp_sol105_deck(joinpath(pcomp_tmp, "tacs_sol105_pcomp_p.bdf"); ply1_t=pcomp_t0 + dpcomp_t)
    pcomp_deck_m = _write_pcomp_sol105_deck(joinpath(pcomp_tmp, "tacs_sol105_pcomp_m.bdf"); ply1_t=pcomp_t0 - dpcomp_t)
    pcomp_model = OpenJFEM.bdf_to_model(pcomp_deck)
    pcomp_model["backend"] = "tacs_formulation"
    pcomp_model_p = OpenJFEM.bdf_to_model(pcomp_deck_p)
    pcomp_model_p["backend"] = "tacs_formulation"
    pcomp_model_m = OpenJFEM.bdf_to_model(pcomp_deck_m)
    pcomp_model_m["backend"] = "tacs_formulation"
    pcomp_results = OpenJFEM.solve_model(pcomp_model)
    pcomp_results_p = OpenJFEM.solve_model(pcomp_model_p)
    pcomp_results_m = OpenJFEM.solve_model(pcomp_model_m)
    lambda_fd_pcomp_t = (Float64(pcomp_results_p["eigenvalues"][1]) - Float64(pcomp_results_m["eigenvalues"][1])) / (2.0 * dpcomp_t)
    pcomp_dv = Dict{String,Any}(
        "id" => "pcomp1_ply1_t",
        "type" => "pcomp_ply_thickness",
        "pids" => [1],
        "ply_index" => 1,
    )
    pcomp_gradient_response = OpenJFEM.buckling_load_factor_design_gradient(pcomp_results, [pcomp_dv]; mode=1)
    @test pcomp_gradient_response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    lambda_hook_pcomp_t = Float64(pcomp_gradient_response["gradient"]["pcomp1_ply1_t"])
    lambda_hook_pcomp_t_relerr = abs(lambda_hook_pcomp_t - lambda_fd_pcomp_t) / max(abs(lambda_hook_pcomp_t), abs(lambda_fd_pcomp_t), 1e-30)
    @test isfinite(lambda_fd_pcomp_t)
    @test isfinite(lambda_hook_pcomp_t)
    @test lambda_hook_pcomp_t_relerr < 1e-3

    tmp = mktempdir(; prefix="openjfem_tacs_sol105_tria3_")
    tri_deck = _write_tria3_sol105_deck(joinpath(tmp, "tacs_sol105_tria3.bdf"))
    tri_model = OpenJFEM.bdf_to_model(tri_deck)
    tri_model["backend"] = "tacs_formulation"
    tri_results = OpenJFEM.solve_model(tri_model)
    tri_eigenvalues = Float64.(tri_results["eigenvalues"])
    @test tri_results["sol_type"] == 105
    @test tri_results["backend"] == "tacs_formulation"
    @test tri_results["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test tri_results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
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
    println("  generic dt hook   = ", lambda_generic_t)
    println("  generic dt relerr = ", lambda_generic_t_relerr)
    println("  KS dLambda/dt FD  = ", ks_fd)
    println("  KS dLambda/dt hook = ", ks_hook)
    println("  KS dLambda relerr = ", ks_relerr)
    println("  dLambda/dE FD     = ", lambda_fd_E)
    println("  dLambda/dE hook   = ", lambda_hook_E)
    println("  dLambda/dE relerr = ", lambda_hook_E_relerr)
    println("  dLambda/dX FD     = ", lambda_fd_x)
    println("  dLambda/dX hook   = ", lambda_hook_x)
    println("  dLambda/dX relerr = ", lambda_hook_x_relerr)
    println("  pcomp deck        = ", abspath(pcomp_deck))
    println("  dLambda/dT1 FD    = ", lambda_fd_pcomp_t)
    println("  dLambda/dT1 hook  = ", lambda_hook_pcomp_t)
    println("  dLambda/dT1 relerr = ", lambda_hook_pcomp_t_relerr)
    println("  tria3 first eigen = ", tri_eigenvalues[1])
    return true
end

main()
