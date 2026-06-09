# Guard for grouped SOL103/SOL105 TACS design-variable eigen sensitivities.
#
# The grouped design variable semantics are additive: one scalar design
# perturbation is applied to every listed property or material id. The hook
# gradients are checked against a full central re-solve where the whole group is
# moved together.
#
# Usage:
#   julia --project=. tools/testing/tacs_grouped_eigen_design_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function _write_grouped_deck(path::AbstractString, sol::Integer)
    sol in (103, 105) || error("Grouped eigen guard only supports SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS grouped SOL", sol, " design sensitivity guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        if sol == 103
            println(io, "  METHOD = 1")
        else
            println(io, "  LOAD = 1")
            println(io, "SUBCASE 2")
            println(io, "  SPC = 1")
            println(io, "  METHOD = 1")
            println(io, "  STATSUB = 1")
        end
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        sol == 103 && println(io, "PARAM,COUPMASS,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,2.,0.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "GRID,5,,1.,1.,0.")
        println(io, "GRID,6,,2.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,5,4")
        println(io, "CQUAD4,2,2,2,3,6,5")
        println(io, "PSHELL,1,1,0.018")
        println(io, "PSHELL,2,2,0.026")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "MAT1,2,5.6E10,2.1538E10,0.3,2600.")
        println(io, "SPC1,1,123456,1,4")
        if sol == 105
            println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
            println(io, "FORCE,1,6,0,-1000.,1.,0.,0.")
        end
        println(io, "EIGRL,1,0.,1.0E9,4")
        println(io, "ENDDATA")
    end
    return path
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _solve_first_eigenvalue(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(m)
    return Float64(results["eigenvalues"][1])
end

function _with_grouped_thickness_delta(model::AbstractDict, pids, delta::Real)
    m = deepcopy(model)
    for pid in Int.(collect(pids))
        prop = get(get(m, "PSHELLs", Dict()), string(pid), nothing)
        prop === nothing && error("Grouped thickness guard could not find PSHELL $pid.")
        t = Float64(get(prop, "T", 0.0)) + Float64(delta)
        t > 0.0 || error("Grouped thickness guard produced nonpositive thickness for PSHELL $pid.")
        prop["T"] = t
        if uppercase(string(get(prop, "TYPE", "PSHELL"))) == "PSHELL"
            prop["Z1"] = -0.5 * t
            prop["Z2"] = 0.5 * t
        end
    end
    m["backend"] = "tacs_formulation"
    return m
end

function _with_grouped_material_delta(model::AbstractDict, mids, field::AbstractString, delta::Real)
    m = deepcopy(model)
    field_key = uppercase(strip(field))
    for mid in Int.(collect(mids))
        mat = get(get(m, "MATs", Dict()), string(mid), nothing)
        mat === nothing && error("Grouped material guard could not find material $mid.")
        mat[field_key] = Float64(mat[field_key]) + Float64(delta)
    end
    m["backend"] = "tacs_formulation"
    return m
end

function _fd_grouped_thickness(results::AbstractDict, pids, h::Real)
    model = results["model"]
    lambda_p = _solve_first_eigenvalue(_with_grouped_thickness_delta(model, pids, h))
    lambda_m = _solve_first_eigenvalue(_with_grouped_thickness_delta(model, pids, -h))
    return (lambda_p - lambda_m) / (2.0 * Float64(h))
end

function _fd_grouped_material(results::AbstractDict, mids, field::AbstractString, h::Real)
    model = results["model"]
    lambda_p = _solve_first_eigenvalue(_with_grouped_material_delta(model, mids, field, h))
    lambda_m = _solve_first_eigenvalue(_with_grouped_material_delta(model, mids, field, -h))
    return (lambda_p - lambda_m) / (2.0 * Float64(h))
end

function _check_modal_grouped(results::AbstractDict)
    pids = [1, 2]
    mids = [1, 2]
    t0 = minimum(Float64(results["model"]["PSHELLs"][string(pid)]["T"]) for pid in pids)
    h_t = max(1e-5 * t0, 1e-7)

    thickness_dv = Dict{String,Any}(
        "id" => "t_group_1_2",
        "type" => "shell_thickness",
        "pids" => pids,
        "step" => h_t,
    )
    material_dv = Dict{String,Any}(
        "id" => "E_group_1_2",
        "type" => "material_E",
        "mids" => mids,
    )
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [thickness_dv, material_dv]; mode=1)
    @test response["response"] == "modal_eigenvalue"
    @test response["design_variable_type"] == "mixed"
    @test haskey(response["design_variable_diagnostics"], "t_group_1_2")
    @test haskey(response["design_variable_diagnostics"], "E_group_1_2")
    @test response["design_variable_diagnostics"]["t_group_1_2"]["type"] == "shell_thickness"
    @test response["design_variable_diagnostics"]["t_group_1_2"]["pids"] == pids
    @test response["design_variable_diagnostics"]["E_group_1_2"]["type"] == "material_E"
    @test response["design_variable_diagnostics"]["E_group_1_2"]["mids"] == mids

    h_E = Float64(response["design_variable_diagnostics"]["E_group_1_2"]["step"])
    @test h_E > 0.0
    fd_t = _fd_grouped_thickness(results, pids, h_t)
    fd_E = _fd_grouped_material(results, mids, "E", h_E)
    hook_t = Float64(response["gradient"]["t_group_1_2"])
    hook_E = Float64(response["gradient"]["E_group_1_2"])
    rel_t = _relerr(hook_t, fd_t)
    rel_E = _relerr(hook_E, fd_E)
    @test rel_t < 2e-4 || abs(hook_t - fd_t) < 1e-3
    @test rel_E < 5e-5 || abs(hook_E - fd_E) < 1e-6
    return Dict(
        "modal_grouped_thickness" => (fd=fd_t, hook=hook_t, rel=rel_t),
        "modal_grouped_material_E" => (fd=fd_E, hook=hook_E, rel=rel_E),
    )
end

function _check_buckling_grouped(results::AbstractDict)
    pids = [1, 2]
    mids = [1, 2]
    t0 = minimum(Float64(results["model"]["PSHELLs"][string(pid)]["T"]) for pid in pids)
    h_t = max(1e-4 * t0, 1e-7)

    thickness_dv = Dict{String,Any}(
        "id" => "t_group_1_2",
        "type" => "shell_thickness",
        "pids" => pids,
        "step" => h_t,
    )
    material_dv = Dict{String,Any}(
        "id" => "E_group_1_2",
        "type" => "material_E",
        "mids" => mids,
    )
    response = OpenJFEM.buckling_load_factor_design_gradient(results, [thickness_dv, material_dv]; mode=1)
    @test response["response"] == "buckling_load_factor"
    @test response["design_variable_type"] == "mixed"
    @test response["design_variable_diagnostics"]["t_group_1_2"]["type"] == "shell_thickness"
    @test response["design_variable_diagnostics"]["t_group_1_2"]["pids"] == pids
    @test response["design_variable_diagnostics"]["E_group_1_2"]["type"] == "material_E"
    @test response["design_variable_diagnostics"]["E_group_1_2"]["mids"] == mids

    h_E = Float64(response["design_variable_diagnostics"]["E_group_1_2"]["step"])
    @test h_E > 0.0
    fd_t = _fd_grouped_thickness(results, pids, h_t)
    fd_E = _fd_grouped_material(results, mids, "E", h_E)
    hook_t = Float64(response["gradient"]["t_group_1_2"])
    hook_E = Float64(response["gradient"]["E_group_1_2"])
    rel_t = _relerr(hook_t, fd_t)
    rel_E = _relerr(hook_E, fd_E)
    @test rel_t < 2e-4 || abs(hook_t - fd_t) < 1e-6
    @test rel_E < 2e-4 || abs(hook_E - fd_E) < 1e-8
    return Dict(
        "buckling_grouped_thickness" => (fd=fd_t, hook=hook_t, rel=rel_t),
        "buckling_grouped_material_E" => (fd=fd_E, hook=hook_E, rel=rel_E),
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_grouped_eigen_")
    sol103 = _write_grouped_deck(joinpath(tmp, "grouped_sol103.bdf"), 103)
    sol105 = _write_grouped_deck(joinpath(tmp, "grouped_sol105.bdf"), 105)
    modal_results = _solve(sol103)
    buckling_results = _solve(sol105)

    @test modal_results["backend"] == "tacs_formulation"
    @test buckling_results["backend"] == "tacs_formulation"
    @test modal_results["sol_type"] == 103
    @test buckling_results["sol_type"] == 105
    @test length(modal_results["eigenvalues"]) >= 1
    @test length(buckling_results["eigenvalues"]) >= 1
    @test all(isfinite, Float64.(modal_results["eigenvalues"]))
    @test all(isfinite, Float64.(buckling_results["eigenvalues"]))

    checks = merge(
        _check_modal_grouped(modal_results),
        _check_buckling_grouped(buckling_results),
    )

    println("TACS grouped eigen design sensitivity check passed")
    println("  workdir = ", abspath(tmp))
    for (name, check) in sort(collect(checks); by=first)
        println("  ", name, " FD = ", check.fd, " hook = ", check.hook, " rel = ", check.rel)
    end
    return true
end

main()
