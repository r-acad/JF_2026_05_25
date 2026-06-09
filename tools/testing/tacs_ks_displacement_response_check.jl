# Guard for the TACS-formulation static KS displacement response.
#
# The response aggregates selected displacement components with KS smooth-max
# weights and uses the existing static adjoint design-gradient path.
#
# Usage:
#   julia --project=. tools/testing/tacs_ks_displacement_response_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS KS displacement response guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pressure_quad_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS KS displacement pressure-load guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,2,4")
        println(io, "PLOAD4,1,1,100.")
        println(io, "ENDDATA")
    end
    return path
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _with_shell_thickness(model, pid::Int, delta::Real)
    m = deepcopy(model)
    prop = m["PSHELLs"][string(pid)]
    t = Float64(prop["T"]) + Float64(delta)
    t > 0.0 || error("KS displacement guard produced nonpositive thickness.")
    prop["T"] = t
    prop["Z1"] = -0.5 * t
    prop["Z2"] = 0.5 * t
    m["backend"] = "tacs_formulation"
    return m
end

function _with_material_field(model, mid::Int, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + Float64(delta)
    field_key == "NU" && (mat["G"] = Float64(mat["E"]) / (2.0 * (1.0 + Float64(mat["NU"]))))
    m["backend"] = "tacs_formulation"
    return m
end

function _with_node_coord(model, grid::Int, comp::Int, delta::Float64)
    m = deepcopy(model)
    grid_data = m["GRIDs"][string(grid)]
    coords = Float64.(collect(grid_data["X"]))
    coords[comp] += delta
    grid_data["X"] = coords
    m["backend"] = "tacs_formulation"
    return m
end

function _ks_value(results, response)
    subcase = results["subcases"][1]
    u = Float64.(subcase["u_analysis"])
    return OpenJFEM.Solver.evaluate_response(
        response,
        u,
        results["model"],
        results["id_map"],
        Int(results["ndof"]),
        results["node_coords"],
        results["node_R"],
    )
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function main()
    deck = _write_sol101_deck(joinpath(mktempdir(; prefix="openjfem_tacs_ks_disp_"), "ks_displacement_sol101.bdf"))
    results = _solve(deck)
    @test results["backend"] == "tacs_formulation"

    response = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2, 3],
        "dof" => 3,
        "scale" => -1.0,
        "displacement_ref" => 1e-6,
        "rho" => 25.0,
    )
    value = _ks_value(results, response)
    @test isfinite(value)

    design_variables = [
        Dict{String,Any}("id" => "t_pid1", "type" => "shell_thickness", "pids" => [1]),
        Dict{String,Any}("id" => "E_mid1", "type" => "material_E", "mids" => [1]),
    ]
    gradient = OpenJFEM.static_ks_displacement_design_gradient(results, response, design_variables)
    @test gradient["response"] == "ks_displacement"
    @test gradient["gradient_backend"] == "tacs_formulation_ks_displacement_design_tangent_adjoint"
    @test abs(Float64(gradient["value"]) - value) < 1e-12
    @test gradient["response_contract"]["family"] == "ks_displacement"

    h_t = Float64(gradient["design_variable_diagnostics"]["t_pid1"]["step"])
    results_t_p = OpenJFEM.solve_model(_with_shell_thickness(results["model"], 1, h_t))
    results_t_m = OpenJFEM.solve_model(_with_shell_thickness(results["model"], 1, -h_t))
    fd_t = (_ks_value(results_t_p, response) - _ks_value(results_t_m, response)) / (2.0 * h_t)
    hook_t = Float64(gradient["gradient"]["t_pid1"])
    rel_t = _relerr(hook_t, fd_t)
    @test rel_t < 1e-5

    h_E = Float64(gradient["design_variable_diagnostics"]["E_mid1"]["step"])
    results_E_p = OpenJFEM.solve_model(_with_material_field(results["model"], 1, "E", h_E))
    results_E_m = OpenJFEM.solve_model(_with_material_field(results["model"], 1, "E", -h_E))
    fd_E = (_ks_value(results_E_p, response) - _ks_value(results_E_m, response)) / (2.0 * h_E)
    hook_E = Float64(gradient["gradient"]["E_mid1"])
    rel_E = _relerr(hook_E, fd_E)
    @test rel_E < 1e-5

    coord_dv = Dict{String,Any}("id" => "grid3_x", "type" => "node_coord", "grid" => 3, "comp" => 1)
    coord_gradient = OpenJFEM.static_ks_displacement_design_gradient(results, response, [coord_dv])
    @test coord_gradient["gradient_backend"] == "tacs_formulation_coordinate_fd"
    coord_diag = coord_gradient["design_variable_diagnostics"][coord_dv["id"]]
    @test coord_diag["sensitivity_contract"]["coordinate_supported"] == true
    h_X = Float64(coord_diag["step"])
    @test h_X > 0.0
    coord_results_p = OpenJFEM.solve_model(_with_node_coord(results["model"], 3, 1, h_X))
    coord_results_m = OpenJFEM.solve_model(_with_node_coord(results["model"], 3, 1, -h_X))
    fd_X = (_ks_value(coord_results_p, response) - _ks_value(coord_results_m, response)) / (2.0 * h_X)
    hook_X = Float64(coord_gradient["gradient"][coord_dv["id"]])
    rel_X = _relerr(hook_X, fd_X)
    @test rel_X < 2e-2

    pressure_deck = _write_pressure_quad_deck(joinpath(dirname(deck), "ks_displacement_pressure_sol101.bdf"))
    pressure_results = _solve(pressure_deck)
    pressure_response = Dict{String,Any}(
        "type" => "ks_displacement",
        "grids" => [2, 3],
        "dof" => 3,
        "displacement_ref" => 1e-6,
        "rho" => 25.0,
    )
    pressure_value = _ks_value(pressure_results, pressure_response)
    @test isfinite(pressure_value)
    pressure_gradient = OpenJFEM.static_ks_displacement_design_gradient(pressure_results, pressure_response, [coord_dv])
    pressure_diag = pressure_gradient["design_variable_diagnostics"][coord_dv["id"]]
    @test pressure_gradient["gradient_backend"] == "tacs_formulation_coordinate_fd"
    @test pressure_diag["load_derivative_nonzero"] == true
    @test Float64(pressure_diag["load_derivative_norm"]) > 1e-6
    h_load_X = Float64(pressure_diag["step"])
    @test h_load_X > 0.0
    pressure_results_p = OpenJFEM.solve_model(_with_node_coord(pressure_results["model"], 3, 1, h_load_X))
    pressure_results_m = OpenJFEM.solve_model(_with_node_coord(pressure_results["model"], 3, 1, -h_load_X))
    fd_load_X = (_ks_value(pressure_results_p, pressure_response) - _ks_value(pressure_results_m, pressure_response)) / (2.0 * h_load_X)
    hook_load_X = Float64(pressure_gradient["gradient"][coord_dv["id"]])
    rel_load_X = _relerr(hook_load_X, fd_load_X)
    @test rel_load_X < 5e-4

    println("TACS KS displacement response check passed")
    println("  deck                = ", abspath(deck))
    println("  KS displacement     = ", value)
    println("  dKSdisp/dt FD       = ", fd_t)
    println("  dKSdisp/dt hook     = ", hook_t)
    println("  dKSdisp/dt relerr   = ", rel_t)
    println("  dKSdisp/dE FD       = ", fd_E)
    println("  dKSdisp/dE hook     = ", hook_E)
    println("  dKSdisp/dE relerr   = ", rel_E)
    println("  dKSdisp/dX FD       = ", fd_X)
    println("  dKSdisp/dX hook     = ", hook_X)
    println("  dKSdisp/dX relerr   = ", rel_X)
    println("  pressure deck       = ", abspath(pressure_deck))
    println("  pressure dF/dX norm = ", pressure_diag["load_derivative_norm"])
    println("  pressure dKS/dX FD  = ", fd_load_X)
    println("  pressure dKS/dX hook= ", hook_load_X)
    println("  pressure dKS/dX err = ", rel_load_X)
    return true
end

main()
