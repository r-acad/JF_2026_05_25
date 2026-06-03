# Guard the roadmap requirement that SOL200 routing is shared above backends.
#
# Usage:
#   julia --project=. tools/testing/backend_sol200_shared_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _grid_id(i::Int, j::Int, nx::Int)
    return j * (nx + 1) + i + 1
end

function _write_shared_sol200_deck(path::AbstractString)
    nx = 1
    ny = 1
    thickness = 0.02
    bottom = [_grid_id(i, 0, nx) for i in 0:nx]
    top = [_grid_id(i, ny, nx) for i in 0:nx]

    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated shared-backend SOL200 route check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        for j in 0:ny, i in 0:nx
            gid = _grid_id(i, j, nx)
            println(io, "GRID,$gid,,$(i / nx),$(j / ny),0.")
        end
        println(io, "CQUAD4,1,1,1,2,4,3")
        println(io, "PSHELL,1,1,$thickness")
        println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
        println(io, "SPC1,1,123456,", join(bottom, ","))
        for nid in top
            println(io, "FORCE,1,$nid,0,100.,0.,0.,-1.")
        end
        println(io, "DESVAR,1,T1,$thickness,0.005,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.005,0.05,0.0,1,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,60.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
        println(io, "ENDDATA")
    end
    return path
end

function _check_shared_result(results::AbstractDict, expected_backend::AbstractString)
    @test results["sol_type"] == 200
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test results["backend"] == expected_backend
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["forward_results"]["backend"] == expected_backend
    opt = results["optimization"]
    @test !isempty(opt["design_variables"])
    @test all(Float64(v) > 0.0 for v in values(opt["design_variables"]))
    @test isfinite(Float64(opt["final_mass"]))
    @test !isempty(opt["history"])
    @test !isempty(opt["iterations"])
    first_iter = opt["iterations"][1]
    @test first_iter["solver_diagnostics"]["backend"] == expected_backend
    return first_iter["solver_diagnostics"]
end

function main()
    had_backend_env = haskey(ENV, "JFEM_BACKEND")
    old_backend_env = get(ENV, "JFEM_BACKEND", "")
    try
        delete!(ENV, "JFEM_BACKEND")
        deck = _write_shared_sol200_deck(joinpath(mktempdir(; prefix="openjfem_backend_sol200_shared_"), "shared_sol200.bdf"))

        parity_model = OpenJFEM.bdf_to_model(deck)
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(parity_model)) == "nastran_parity"
        parity_results = OpenJFEM.solve_model(parity_model)
        parity_diag = _check_shared_result(parity_results, "nastran_parity")

        tacs_model = OpenJFEM.bdf_to_model(deck)
        tacs_model["backend"] = "tacs_formulation"
        @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(tacs_model)) == "tacs_formulation"
        tacs_results = OpenJFEM.solve_model(tacs_model)
        tacs_diag = _check_shared_result(tacs_results, "tacs_formulation")

        @test parity_results["analysis_type"] == tacs_results["analysis_type"]
        @test parity_results["route_summary"]["translation_mode"] == tacs_results["route_summary"]["translation_mode"]

        println("JFEM backend SOL200 shared-route check passed")
        println("  parity backend = ", parity_results["backend"])
        println("  tacs backend = ", tacs_results["backend"])
        parity_sens = get(get(parity_diag, "sensitivity", Dict{String,Any}()), "gradient_backend", "not_reported")
        tacs_sens = get(get(tacs_diag, "sensitivity", Dict{String,Any}()), "gradient_backend", "not_reported")
        println("  parity sensitivity = ", parity_sens)
        println("  tacs sensitivity = ", tacs_sens)
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
