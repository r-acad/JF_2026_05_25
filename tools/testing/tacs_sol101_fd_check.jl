# Finite-difference checks for the first TACS-formulation SOL101 slice.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_fd_check.jl
#   julia --project=. tools/testing/tacs_sol101_fd_check.jl path/to/plain_quad.bdf

using LinearAlgebra
using Random
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _fd_relerr(a, b)
    return norm(a - b) / max(norm(a), norm(b), 1e-30)
end

function _with_thickness(model, pid::Int, thickness::Float64)
    m = deepcopy(model)
    prop = m["PSHELLs"][string(pid)]
    prop["T"] = thickness
    prop["Z1"] = -0.5 * thickness
    prop["Z2"] = 0.5 * thickness
    return m
end

function _first_supported_element(model)
    cshells = get(model, "CSHELLs", Dict())
    isempty(cshells) && error("no CSHELLs in model")
    first(values(cshells))
end

function _pcomp_ply_design_variables(prop::AbstractDict, pid::Int)
    get(prop, "TYPE", "") == "PCOMP_CLT" || return Dict{String,Any}[]
    ply_data = get(prop, "PLY_DATA", Any[])
    isempty(ply_data) && return Dict{String,Any}[]
    dvs = Dict{String,Any}[
        Dict("id" => "pcomp_$(pid)_ply1_t", "type" => "pcomp_ply_thickness", "pids" => [pid], "ply_index" => 1),
    ]
    angle_ply = findfirst(ply -> abs(sind(2.0 * Float64(get(ply, "theta", 0.0)))) > 1e-8, ply_data)
    if !isnothing(angle_ply)
        push!(dvs, Dict("id" => "pcomp_$(pid)_ply$(angle_ply)_theta", "type" => "pcomp_ply_angle", "pids" => [pid], "ply_index" => angle_ply))
    end
    return dvs
end

function _compliance_value(results)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return dot(u, results["K"] * u)
end

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_quad_patch_deck(path::AbstractString; nx::Int, ny::Int,
                                lx::Float64=1.0, ly::Float64=1.0,
                                skew::Float64=0.0, warp::Float64=0.0,
                                thickness::Float64=0.02)
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 patch")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = lx * i / nx + skew * j / max(ny, 1)
            y = ly * j / ny
            z = warp * sin(pi * i / max(nx, 1)) * sin(pi * j / max(ny, 1))
            println(io, "GRID,$gid,,$x,$y,$z")
        end
        eid = 1
        for j in 0:(ny - 1), i in 0:(nx - 1)
            n1 = _grid_id(i, j, nx)
            n2 = _grid_id(i + 1, j, nx)
            n3 = _grid_id(i + 1, j + 1, nx)
            n4 = _grid_id(i, j + 1, nx)
            println(io, "CQUAD4,$eid,1,$n1,$n2,$n3,$n4")
            eid += 1
        end
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        f = -100.0 / length(top)
        for nid in top
            println(io, "FORCE,1,$nid,0,$(abs(f)),0.,0.,-1.")
        end
        println(io, "ENDDATA")
    end
    return path
end

function _write_tria3_patch_deck(path::AbstractString; thickness::Float64=0.02)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CTRIA3 patch")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CTRIA3,1,1,1,2,3")
        println(io, "CTRIA3,2,1,1,3,4")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,50.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,50.,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function _write_pcomp_patch_deck(path::AbstractString; symmetric::Bool)
    nx = 2
    ny = 1
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 PCOMP patch")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            x = i / nx + 0.08 * j
            y = j / ny
            println(io, "GRID,$gid,,$x,$y,0.")
        end
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,1,2,3,6,5")
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        if symmetric
            println(io, "PCOMP,1,,,,,,,,1,0.0025,0.,YES,1,0.0025,90.,YES,1,0.0025,90.,YES,1,0.0025,0.,YES")
        else
            println(io, "PCOMP,1,,,,,,,,1,0.003,0.,YES,1,0.002,45.,YES,1,0.0015,-30.,YES")
        end
        println(io, "SPC1,1,123456,", join(bottom, ","))
        f = -75.0 / length(top)
        for nid in top
            println(io, "FORCE,1,$nid,0,$(abs(f)),0.,0.,-1.")
        end
        println(io, "ENDDATA")
    end
    return path
end

function _default_decks()
    decks = [joinpath(repo_root, "examples", "precompile", "sol101_quad_static.bdf")]
    tmp = mktempdir(; prefix="openjfem_tacs_sol101_patches_")
    push!(decks, _write_quad_patch_deck(joinpath(tmp, "patch_2x1_regular.bdf"); nx=2, ny=1))
    push!(decks, _write_quad_patch_deck(joinpath(tmp, "patch_2x2_regular.bdf"); nx=2, ny=2))
    push!(decks, _write_quad_patch_deck(joinpath(tmp, "patch_2x2_skew.bdf"); nx=2, ny=2, skew=0.18))
    push!(decks, _write_quad_patch_deck(joinpath(tmp, "patch_2x2_warped.bdf"); nx=2, ny=2, skew=0.08, warp=0.03))
    push!(decks, _write_tria3_patch_deck(joinpath(tmp, "patch_tria3_regular.bdf")))
    push!(decks, _write_pcomp_patch_deck(joinpath(tmp, "patch_pcomp_symmetric_mat8.bdf"); symmetric=true))
    push!(decks, _write_pcomp_patch_deck(joinpath(tmp, "patch_pcomp_unsymmetric_mat8.bdf"); symmetric=false))
    return decks
end

function _check_deck(deck::AbstractString)
    isfile(deck) || error("deck not found: $deck")

    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    K, id_map, X, ndof, node_R, _, _, _, _ = OpenJFEM._tacs_assemble_sol101(model)
    @test ndof == size(K, 1) == size(K, 2)
    Kdense = Matrix(K)
    @test norm(Kdense - transpose(Kdense)) / max(norm(Kdense), 1e-30) < 1e-12

    rng = MersenneTwister(20260601)
    eps_fd = 1e-6

    u = randn(rng, ndof)
    v = randn(rng, ndof)
    rgp = OpenJFEM._tacs_global_residual(K, u .+ eps_fd .* v)
    rgm = OpenJFEM._tacs_global_residual(K, u .- eps_fd .* v)
    global_fd = (rgp .- rgm) ./ (2.0 * eps_fd)
    global_tangent = K * v
    global_relerr = _fd_relerr(global_fd, global_tangent)
    @test global_relerr < 1e-8

    el = _first_supported_element(model)
    Ke, _ = OpenJFEM._tacs_shell_residual_tangent(model, el, id_map, X, node_R)
    elem_ndof = size(Ke, 1)
    ue = randn(rng, elem_ndof)
    ve = randn(rng, elem_ndof)
    rep = OpenJFEM._tacs_element_residual(Ke, ue .+ eps_fd .* ve)
    rem = OpenJFEM._tacs_element_residual(Ke, ue .- eps_fd .* ve)
    elem_fd = (rep .- rem) ./ (2.0 * eps_fd)
    elem_tangent = Ke * ve
    elem_relerr = _fd_relerr(elem_fd, elem_tangent)
    @test elem_relerr < 1e-8

    pid = Int(get(el, "PID", 1))
    prop = model["PSHELLs"][string(pid)]
    supports_thickness_derivative = OpenJFEM._tacs_shell_supports_thickness_derivative(prop)
    thickness_global_relerr = NaN
    thickness_elem_relerr = NaN
    thickness_residual_relerr = NaN
    compliance_grad_relerr = NaN
    displacement_grad_relerr = NaN
    pcomp_compliance_grad_relerr = NaN
    pcomp_displacement_grad_relerr = NaN
    model_p = nothing
    model_m = nothing
    dt = NaN
    if supports_thickness_derivative
        t0 = Float64(prop["T"])
        dt = max(1e-6 * t0, 1e-8)
        model_p = _with_thickness(model, pid, t0 + dt)
        model_m = _with_thickness(model, pid, t0 - dt)
        Kp, _, _, _, _, _, _, _, _ = OpenJFEM._tacs_assemble_sol101(model_p)
        Km, _, _, _, _, _, _, _, _ = OpenJFEM._tacs_assemble_sol101(model_m)
        dK_fd = (Matrix(Kp) .- Matrix(Km)) ./ (2.0 * dt)
        dK, _, _, _, _, _, _, _, _ = OpenJFEM._tacs_assemble_sol101(model; thickness_derivative_pid=pid)
        dK_dense = Matrix(dK)
        thickness_global_relerr = _fd_relerr(dK_fd, dK_dense)
        @test thickness_global_relerr < 1e-6

        Kep, _ = OpenJFEM._tacs_shell_residual_tangent(model_p, el, id_map, X, node_R)
        Kem, _ = OpenJFEM._tacs_shell_residual_tangent(model_m, el, id_map, X, node_R)
        dKe_fd = (Kep .- Kem) ./ (2.0 * dt)
        dKe, _ = OpenJFEM._tacs_shell_thickness_tangent_ad(model, el, id_map, X, node_R)
        thickness_elem_relerr = _fd_relerr(dKe_fd, dKe)
        @test thickness_elem_relerr < 1e-6

        thickness_residual_relerr = _fd_relerr(dK_fd * u, dK_dense * u)
        @test thickness_residual_relerr < 1e-6
    end

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test results["formulation"]["constitutive"] == "mat1_pshell_pcomp_clt"
    @test results["formulation"]["thickness_derivative"] == "element_ad"
    @test length(results["subcases"]) >= 1

    compliance_direct = dot(Float64.(results["subcases"][1]["u_analysis"]), results["K"] * Float64.(results["subcases"][1]["u_analysis"]))
    if supports_thickness_derivative
        response = OpenJFEM.static_compliance_thickness_gradient(results; pids=[pid])
        compliance = Float64(response["value"])
        @test abs(compliance - compliance_direct) / max(abs(compliance_direct), 1e-30) < 1e-12
        grad = Float64(response["gradient"][string(pid)])

        results_p = OpenJFEM.solve_model(model_p)
        results_m = OpenJFEM.solve_model(model_m)
        up = Float64.(results_p["subcases"][1]["u_analysis"])
        um = Float64.(results_m["subcases"][1]["u_analysis"])
        cp = dot(up, results_p["K"] * up)
        cm = dot(um, results_m["K"] * um)
        compliance_fd_grad = (cp - cm) / (2.0 * dt)
        compliance_grad_relerr = abs(grad - compliance_fd_grad) / max(abs(grad), abs(compliance_fd_grad), 1e-30)
        @test compliance_grad_relerr < 1e-5

        disp_grid = maximum(parse.(Int, string.(collect(keys(model["GRIDs"])))))
        disp_resp = Dict{String,Any}("type" => "displacement", "grid" => disp_grid, "dof" => 3)
        disp_grad_response = OpenJFEM.static_displacement_thickness_gradient(results, disp_resp; pids=[pid])
        @test disp_grad_response["gradient_backend"] == "tacs_formulation_element_ad_adjoint"
        disp_grad = Float64(disp_grad_response["gradient"][string(pid)])
        disp_p = Float64(OpenJFEM.Solver.evaluate_response(
            disp_resp, up, results_p["model"], results_p["id_map"], results_p["ndof"],
            results_p["node_coords"], results_p["node_R"]))
        disp_m = Float64(OpenJFEM.Solver.evaluate_response(
            disp_resp, um, results_m["model"], results_m["id_map"], results_m["ndof"],
            results_m["node_coords"], results_m["node_R"]))
        disp_fd_grad = (disp_p - disp_m) / (2.0 * dt)
        displacement_grad_relerr = abs(disp_grad - disp_fd_grad) / max(abs(disp_grad), abs(disp_fd_grad), 1e-30)
        @test displacement_grad_relerr < 1e-5
    end

    pcomp_dvs = _pcomp_ply_design_variables(prop, pid)
    if !isempty(pcomp_dvs)
        comp_design_response = OpenJFEM.static_compliance_design_gradient(results, pcomp_dvs)
        @test comp_design_response["gradient_backend"] == "tacs_formulation_design_tangent"
        @test abs(Float64(comp_design_response["value"]) - compliance_direct) / max(abs(compliance_direct), 1e-30) < 1e-12

        disp_grid = maximum(parse.(Int, string.(collect(keys(model["GRIDs"])))))
        disp_resp = Dict{String,Any}("type" => "displacement", "grid" => disp_grid, "dof" => 3)
        disp_design_response = OpenJFEM.static_displacement_design_gradient(results, disp_resp, pcomp_dvs)
        @test disp_design_response["gradient_backend"] == "tacs_formulation_design_tangent_adjoint"

        comp_errs = Float64[]
        disp_errs = Float64[]
        for dv in pcomp_dvs
            dv_id = string(dv["id"])
            diag = comp_design_response["design_variable_diagnostics"][dv_id]
            step = Float64(diag["step"])
            @test step > 0.0
            fd_step = string(dv["type"]) == "pcomp_ply_angle" ? max(step, 1e-4) : step

            model_p = OpenJFEM._tacs_model_with_pcomp_ply_delta(model, pid, Int(dv["ply_index"]), string(dv["type"]), fd_step)
            model_m = OpenJFEM._tacs_model_with_pcomp_ply_delta(model, pid, Int(dv["ply_index"]), string(dv["type"]), -fd_step)
            results_p = OpenJFEM.solve_model(model_p)
            results_m = OpenJFEM.solve_model(model_m)

            comp_fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * fd_step)
            comp_grad = Float64(comp_design_response["gradient"][dv_id])
            comp_relerr = abs(comp_grad - comp_fd) / max(abs(comp_grad), abs(comp_fd), 1e-30)
            push!(comp_errs, comp_relerr)
            @test comp_relerr < 2e-3

            up = Float64.(results_p["subcases"][1]["u_analysis"])
            um = Float64.(results_m["subcases"][1]["u_analysis"])
            disp_p = Float64(OpenJFEM.Solver.evaluate_response(
                disp_resp, up, results_p["model"], results_p["id_map"], results_p["ndof"],
                results_p["node_coords"], results_p["node_R"]))
            disp_m = Float64(OpenJFEM.Solver.evaluate_response(
                disp_resp, um, results_m["model"], results_m["id_map"], results_m["ndof"],
                results_m["node_coords"], results_m["node_R"]))
            disp_fd = (disp_p - disp_m) / (2.0 * fd_step)
            disp_grad = Float64(disp_design_response["gradient"][dv_id])
            disp_relerr = abs(disp_grad - disp_fd) / max(abs(disp_grad), abs(disp_fd), 1e-30)
            push!(disp_errs, disp_relerr)
            @test disp_relerr < 3e-2
        end
        pcomp_compliance_grad_relerr = maximum(comp_errs)
        pcomp_displacement_grad_relerr = maximum(disp_errs)
    end

    println("TACS SOL101 FD check passed")
    println("  deck              = ", abspath(deck))
    println("  ndof              = ", ndof)
    println("  property type     = ", get(prop, "TYPE", "PSHELL"))
    println("  global rel error  = ", global_relerr)
    println("  element rel error = ", elem_relerr)
    println("  dK/dt global err  = ", thickness_global_relerr)
    println("  dK/dt element err = ", thickness_elem_relerr)
    println("  dR/dt global err  = ", thickness_residual_relerr)
    println("  dC/dt rel error   = ", compliance_grad_relerr)
    println("  dU/dt rel error   = ", displacement_grad_relerr)
    println("  PCOMP dC/dx error = ", pcomp_compliance_grad_relerr)
    println("  PCOMP dU/dx error = ", pcomp_displacement_grad_relerr)
    return (
        global_relerr=global_relerr,
        elem_relerr=elem_relerr,
        thickness_global_relerr=thickness_global_relerr,
        thickness_elem_relerr=thickness_elem_relerr,
        thickness_residual_relerr=thickness_residual_relerr,
        compliance_grad_relerr=compliance_grad_relerr,
        displacement_grad_relerr=displacement_grad_relerr,
        pcomp_compliance_grad_relerr=pcomp_compliance_grad_relerr,
        pcomp_displacement_grad_relerr=pcomp_displacement_grad_relerr,
        ndof=ndof,
    )
end

function _finite_max(values)
    finite_values = [v for v in values if isfinite(v)]
    return isempty(finite_values) ? NaN : maximum(finite_values)
end

function main(args=ARGS)
    decks = isempty(args) ? _default_decks() : collect(args)
    summaries = []
    for deck in decks
        push!(summaries, _check_deck(deck))
    end
    println("TACS SOL101 patch suite passed")
    println("  decks checked = ", length(decks))
    println("  max global rel error  = ", maximum(s.global_relerr for s in summaries))
    println("  max element rel error = ", maximum(s.elem_relerr for s in summaries))
    println("  max dK/dt global err  = ", _finite_max(s.thickness_global_relerr for s in summaries))
    println("  max dK/dt element err = ", _finite_max(s.thickness_elem_relerr for s in summaries))
    println("  max dR/dt global err  = ", _finite_max(s.thickness_residual_relerr for s in summaries))
    println("  max dC/dt rel error   = ", _finite_max(s.compliance_grad_relerr for s in summaries))
    println("  max dU/dt rel error   = ", _finite_max(s.displacement_grad_relerr for s in summaries))
    println("  max PCOMP dC/dx error = ", _finite_max(s.pcomp_compliance_grad_relerr for s in summaries))
    println("  max PCOMP dU/dx error = ", _finite_max(s.pcomp_displacement_grad_relerr for s in summaries))
    return true
end

main()
