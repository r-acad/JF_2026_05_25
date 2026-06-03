# Guard that bundled production-path examples still solve on the default backend.
#
# Usage:
#   julia --project=. tools/testing/backend_parity_smoke_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
ENV["JFEM_EXPORT_BINARY"] = "false"
ENV["JFEM_MATRIX_ASYMMETRY_CHECK"] = "false"
ENV["JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES"] = "false"
using OpenJFEM

function _check_default_solve(deck::AbstractString, expected_sol::Integer)
    had_backend_env = haskey(ENV, "JFEM_BACKEND")
    old_backend_env = get(ENV, "JFEM_BACKEND", "")
    try
        delete!(ENV, "JFEM_BACKEND")
        model = OpenJFEM.bdf_to_model(deck)
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
        results = OpenJFEM.solve_model(model)
        @test results["sol_type"] == expected_sol
        @test results["backend"] == "nastran_parity"
        @test results["formulation"]["shell"] == "existing_calibrated_jfem"
        if expected_sol in (103, 105)
            @test !isempty(results["eigenvalues"])
            @test all(isfinite, Float64.(results["eigenvalues"]))
        else
            @test !isempty(results["subcases"])
        end
        return results
    finally
        if had_backend_env
            ENV["JFEM_BACKEND"] = old_backend_env
        else
            delete!(ENV, "JFEM_BACKEND")
        end
    end
end

function main()
    decks = [
        (joinpath(repo_root, "examples", "precompile", "sol101_quad_static.bdf"), 101),
        (joinpath(repo_root, "examples", "precompile", "sol103_quad_modes.bdf"), 103),
        (joinpath(repo_root, "examples", "precompile", "sol105_quad_buckling.bdf"), 105),
    ]
    summaries = Any[]
    for (deck, sol) in decks
        results = _check_default_solve(deck, sol)
        push!(summaries, Dict(
            "deck" => basename(deck),
            "sol_type" => results["sol_type"],
            "backend" => results["backend"],
            "eigenvalue_count" => length(get(results, "eigenvalues", Any[])),
        ))
    end
    println("JFEM backend parity smoke check passed")
    for summary in summaries
        println("  ", summary["deck"], " SOL", summary["sol_type"], " backend=", summary["backend"],
            " eigenvalues=", summary["eigenvalue_count"])
    end
    return true
end

exit(main() ? 0 : 1)
