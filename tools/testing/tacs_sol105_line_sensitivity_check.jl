# Finite-difference guard for mixed shell-plus-rod SOL105 buckling sensitivities.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol105_line_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

function _write_mixed_shell_rod_buckling(path::AbstractString)
    lines = readlines(joinpath(repo_root, "examples", "precompile", "sol105_quad_buckling.bdf"))
    output = String[]
    for line in lines
        stripped = strip(line)
        if startswith(stripped, "MAT1,1,")
            push!(output, line)
            push!(output, "MAT1,2,7.0E10,2.6923E10,0.3,2700.")
            continue
        elseif stripped == "ENDDATA"
            push!(output, "CROD,10,10,2,3")
            push!(output, "PROD,10,2,0.002,1.0E-6")
        end
        push!(output, line)
    end
    write(path, join(output, "\n") * "\n")
    return path
end

function _relative_error(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function _solve(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _eigenvalue(model::AbstractDict, mode::Integer)
    return Float64(_solve(model)["eigenvalues"][Int(mode)])
end

function _ks_min_load_factor(eigenvalues::AbstractVector, modes::AbstractVector{<:Integer}, rho::Real)
    values = Float64[Float64(eigenvalues[mode]) for mode in modes]
    lambda_min = minimum(values)
    weights = exp.(-Float64(rho) .* (values .- lambda_min))
    return lambda_min - log(sum(weights)) / Float64(rho)
end

function _check_design(model::AbstractDict, results::AbstractDict, dv::Dict{String,Any}; mode::Integer=2)
    response = OpenJFEM.buckling_load_factor_design_gradient(results, [dv]; mode=mode)
    @test response["response"] == "buckling_load_factor"
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    @test response["mode"] == mode
    h = Float64(response["directional_steps"][dv["id"]])
    hook = Float64(response["gradient"][dv["id"]])
    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (_eigenvalue(model_p, mode) - _eigenvalue(model_m, mode)) / (2.0 * h)
    rel = _relative_error(hook, fd)
    @test isfinite(hook)
    @test isfinite(fd)
    @test rel < 1e-6
    return (fd=fd, hook=hook, rel=rel, h=h)
end

function _check_ks_design(model::AbstractDict, results::AbstractDict, dv::Dict{String,Any};
    modes::Vector{Int}=[1, 2],
    rho::Real=0.001,
)
    response = OpenJFEM.buckling_load_factor_ks_design_gradient(results, [dv]; modes=modes, rho=rho)
    dv_id = String(dv["id"])
    @test response["response"] == "buckling_ks_load_factor"
    @test response["aggregation"] == "smooth_min_load_factor"
    @test response["gradient_backend"] == "tacs_formulation_buckling_ks_weighted_rayleigh"
    @test response["base_gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    @test response["modes"] == modes
    @test abs(sum(values(response["mode_weights"])) - 1.0) < 1e-12
    mode_diag = response["design_variable_diagnostics"][dv_id]["mode_diagnostics"][string(modes[end])]
    h = Float64(mode_diag["directional_step"])
    hook = Float64(response["gradient"][dv_id])
    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (
        _ks_min_load_factor(_solve(model_p)["eigenvalues"], modes, rho) -
        _ks_min_load_factor(_solve(model_m)["eigenvalues"], modes, rho)
    ) / (2.0 * h)
    rel = _relative_error(hook, fd)
    @test isfinite(hook)
    @test isfinite(fd)
    @test rel < 1e-6
    return (fd=fd, hook=hook, rel=rel, h=h, value=Float64(response["value"]))
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_sol105_line_sens_")
    deck = _write_mixed_shell_rod_buckling(joinpath(tmp, "mixed_shell_rod_sol105.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"
    results = OpenJFEM.solve_model(model)
    @test results["sol_type"] == 105
    @test results["backend"] == "tacs_formulation"
    @test length(results["eigenvalues"]) >= 2
    @test Int(get(get(results["solver_diagnostics"][1], "kg_timings", Dict()), "tacs_native_kg_rod_elements", 0)) >= 1

    area_dv = Dict{String,Any}("id" => "rod_area", "type" => "rod_area", "pids" => [10])
    e_dv = Dict{String,Any}("id" => "rod_E", "type" => "material_E", "mids" => [2])
    area = _check_design(model, results, area_dv; mode=2)
    rod_e = _check_design(model, results, e_dv; mode=2)
    area_ks = _check_ks_design(model, results, area_dv)
    rod_e_ks = _check_ks_design(model, results, e_dv)

    println("TACS SOL105 line sensitivity guard passed")
    println("  mode 2 load factor      = ", Float64(results["eigenvalues"][2]))
    println("  dLambda/dA FD/hook/rel  = ", area.fd, " / ", area.hook, " / ", area.rel)
    println("  dLambda/dE FD/hook/rel  = ", rod_e.fd, " / ", rod_e.hook, " / ", rod_e.rel)
    println("  KS value                = ", area_ks.value)
    println("  KS dLambda/dA FD/hook/rel = ", area_ks.fd, " / ", area_ks.hook, " / ", area_ks.rel)
    println("  KS dLambda/dE FD/hook/rel = ", rod_e_ks.fd, " / ", rod_e_ks.hook, " / ", rod_e_ks.rel)
    return true
end

exit(main() ? 0 : 1)
