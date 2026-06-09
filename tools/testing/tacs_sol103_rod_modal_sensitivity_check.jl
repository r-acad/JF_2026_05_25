# Guard for TACS-formulation SOL103 CROD/CONROD modal design sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_rod_modal_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_rod_modal_deck(path::AbstractString, kind::Symbol)
    A = kind == :crod ? 1.0e-2 : 7.0e-3
    J = kind == :crod ? 2.5e-5 : 1.6e-5
    L = kind == :crod ? 2.0 : 1.5
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 $(uppercase(string(kind))) modal sensitivity check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        if kind == :crod
            println(io, "CROD,1,1,1,2")
            println(io, "PROD,1,1,$A,$J")
        else
            println(io, "CONROD,1,1,2,1,$A,$J")
        end
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "EIGRL,1,0.,1.0E8,1")
        println(io, "ENDDATA")
    end
    return (path=path, kind=kind, area=A, torsion=J, length=L)
end

function _first_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(m)
    return Float64(results["eigenvalues"][1])
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _centered_fd(model::AbstractDict, dv::AbstractDict, h::Real)
    hp = Float64(h)
    mp, mm = if string(get(dv, "type", "")) == "node_coord"
        grid = Int(get(dv, "grid", get(dv, "gid", 0)))
        comp = Int(get(dv, "comp", get(dv, "component", 0)))
        (
            OpenJFEM._tacs_model_with_grid_coord_delta(model, grid, comp, hp),
            OpenJFEM._tacs_model_with_grid_coord_delta(model, grid, comp, -hp),
        )
    else
        (
            OpenJFEM._tacs_model_with_design_delta(model, dv, hp),
            OpenJFEM._tacs_model_with_design_delta(model, dv, -hp),
        )
    end
    return (_first_eigenvalue(mp) - _first_eigenvalue(mm)) / (2.0 * hp)
end

function _check_gradient(results::AbstractDict, dv::Dict{String,Any}, expected::Real; rel_tol=1e-7, abs_tol=1e-6)
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=1)
    hook = Float64(response["gradient"][dv["id"]])
    freq_hook = Float64(response["frequency_gradient"][dv["id"]])
    lambda = Float64(results["eigenvalues"][1])
    expected_freq = lambda > 0.0 ? Float64(expected) / (4.0 * pi * sqrt(lambda)) : NaN
    @test isfinite(hook)
    @test isfinite(freq_hook)
    @test _relative_error(freq_hook, expected_freq) < rel_tol ||
        abs(freq_hook - expected_freq) < abs_tol
    @test _relative_error(hook, expected) < rel_tol ||
        abs(hook - expected) < abs_tol
    return hook, freq_hook, response
end

function _check_case(case)
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    lambda = Float64(results["eigenvalues"][1])
    expected_lambda = 2.0 * E_ROD / (RHO_ROD * case.length^2)
    @test _relative_error(lambda, expected_lambda) < 1e-10
    @test occursin("lumped_crod_conrod_mass", results["tacs_formulation_sol103"]["mass"])

    h_E = max(1e-6 * E_ROD, 1e-3)
    E_dv = Dict{String,Any}("id" => "$(case.kind)_E", "type" => "material_E", "mids" => [1], "step" => h_E)
    expected_E = expected_lambda / E_ROD
    hook_E, _, _ = _check_gradient(results, E_dv, expected_E)
    fd_E = _centered_fd(model, E_dv, h_E)
    @test _relative_error(hook_E, fd_E) < 1e-6

    h_rho = max(1e-6 * RHO_ROD, 1e-9)
    rho_dv = Dict{String,Any}("id" => "$(case.kind)_rho", "type" => "material_RHO", "mids" => [1], "step" => h_rho)
    expected_rho = -expected_lambda / RHO_ROD
    hook_rho, _, _ = _check_gradient(results, rho_dv, expected_rho)
    fd_rho = _centered_fd(model, rho_dv, h_rho)
    @test _relative_error(hook_rho, fd_rho) < 1e-6

    h_A = max(1e-4 * case.area, 1e-7)
    area_dv = case.kind == :crod ?
        Dict{String,Any}("id" => "$(case.kind)_area", "type" => "rod_area", "pids" => [1], "step" => h_A) :
        Dict{String,Any}("id" => "$(case.kind)_area", "type" => "rod_area", "eids" => [1], "step" => h_A)
    hook_A, _, response_A = _check_gradient(results, area_dv, 0.0; abs_tol=1e-5)
    fd_A = _centered_fd(model, area_dv, h_A)
    @test abs(hook_A) < 1e-5
    @test abs(fd_A) < 1e-2
    @test abs(hook_A - fd_A) < 1e-2
    @test response_A["design_variable_diagnostics"][area_dv["id"]]["type"] == "rod_area"

    h_x = max(1e-6 * case.length, 1e-7)
    x_dv = Dict{String,Any}(
        "id" => "$(case.kind)_x2",
        "type" => "node_coord",
        "grid" => 2,
        "comp" => 1,
        "step" => h_x,
    )
    expected_x = -2.0 * expected_lambda / case.length
    hook_x, _, _ = _check_gradient(results, x_dv, expected_x; rel_tol=1e-5, abs_tol=1e-3)
    fd_x = _centered_fd(model, x_dv, h_x)
    @test _relative_error(hook_x, fd_x) < 1e-5

    return Dict(
        "lambda_relerr" => _relative_error(lambda, expected_lambda),
        "material_E" => (fd=fd_E, hook=hook_E, expected=expected_E),
        "material_RHO" => (fd=fd_rho, hook=hook_rho, expected=expected_rho),
        "rod_area" => (fd=fd_A, hook=hook_A, expected=0.0),
        "node_coord_x" => (fd=fd_x, hook=hook_x, expected=expected_x),
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_rod_modal_sens_")
    crod = _write_rod_modal_deck(joinpath(tmp, "tacs_crod_sol103_sensitivity.bdf"), :crod)
    conrod = _write_rod_modal_deck(joinpath(tmp, "tacs_conrod_sol103_sensitivity.bdf"), :conrod)

    crod_checks = _check_case(crod)
    conrod_checks = _check_case(conrod)

    println("TACS SOL103 rod modal sensitivity guard passed")
    for (name, checks) in (("CROD", crod_checks), ("CONROD", conrod_checks))
        println("  $name eigenvalue relerr       = ", checks["lambda_relerr"])
        println("  $name material_E FD/hook/exp  = ",
            checks["material_E"].fd, " / ", checks["material_E"].hook, " / ", checks["material_E"].expected)
        println("  $name material_RHO FD/hook/exp = ",
            checks["material_RHO"].fd, " / ", checks["material_RHO"].hook, " / ", checks["material_RHO"].expected)
        println("  $name rod_area FD/hook/exp    = ",
            checks["rod_area"].fd, " / ", checks["rod_area"].hook, " / ", checks["rod_area"].expected)
        println("  $name node_coord_x FD/hook/exp = ",
            checks["node_coord_x"].fd, " / ", checks["node_coord_x"].hook, " / ", checks["node_coord_x"].expected)
    end
    return true
end

exit(main() ? 0 : 1)
