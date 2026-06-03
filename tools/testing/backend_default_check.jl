# Guard the public backend-selection contract.
#
# Usage:
#   julia --project=. tools/testing/backend_default_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function main()
    had_backend_env = haskey(ENV, "JFEM_BACKEND")
    old_backend_env = get(ENV, "JFEM_BACKEND", "")
    try
        delete!(ENV, "JFEM_BACKEND")
        @test OpenJFEM.normalize_backend_name("") == "nastran_parity"
        @test OpenJFEM.normalize_backend_name("default") == "nastran_parity"
        @test OpenJFEM.normalize_backend_name("parity") == "nastran_parity"
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(Dict{String,Any}())) == "nastran_parity"

        ENV["JFEM_BACKEND"] = "tacs_formulation"
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(Dict{String,Any}())) == "tacs_formulation"
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(Dict{String,Any}("backend" => "nastran_parity"))) == "nastran_parity"

        delete!(ENV, "JFEM_BACKEND")
        parity_metadata = OpenJFEM.backend_metadata(OpenJFEM.backend_from_model(Dict{String,Any}()))
        @test parity_metadata["backend"] == "nastran_parity"
        @test parity_metadata["backend_version"] == "0.1.0"
        @test parity_metadata["formulation"]["shell"] == "existing_calibrated_jfem"

        println("JFEM backend default check passed")
        println("  default backend = ", parity_metadata["backend"])
        return true
    finally
        if had_backend_env
            ENV["JFEM_BACKEND"] = old_backend_env
        else
            delete!(ENV, "JFEM_BACKEND")
        end
    end
end

exit(main() ? 0 : 1)
