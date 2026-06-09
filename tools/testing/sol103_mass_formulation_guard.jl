# Guard SOL 103 shell mass formulation selection.
#
# Usage:
#   julia --project=. tools/testing/sol103_mass_formulation_guard.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

const MASS_ENV_KEYS = (
    "JFEM_SOL103_SHELL_MASS",
    "JFEM_SOL103_SHELL_COUPLED_MASS_DEFAULT",
)

function _with_mass_env(f::Function, settings::Dict{String,String})
    old = Dict(key => get(ENV, key, nothing) for key in MASS_ENV_KEYS)
    try
        for key in MASS_ENV_KEYS
            delete!(ENV, key)
        end
        for (key, value) in settings
            ENV[key] = value
        end
        return f()
    finally
        for key in MASS_ENV_KEYS
            delete!(ENV, key)
            value = old[key]
            value === nothing || (ENV[key] = value)
        end
    end
end

function _grid_card(nid::Integer, x, rotated_cd_nodes)
    cd = nid in rotated_cd_nodes ? ",10" : ""
    return "GRID,$nid,,$(x[1]),$(x[2]),$(x[3])$cd"
end

function _write_tria3_deck(path::AbstractString; coupmass=nothing,
                           rotated_cd_nodes=Set{Int}())
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated SOL103 mass formulation guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        if coupmass !== nothing
            println(io, "PARAM,COUPMASS,$coupmass")
        end
        if !isempty(rotated_cd_nodes)
            println(io, "CORD2R,10,,0.,0.,0.,0.,0.,1.,0.,1.,0.")
        end
        println(io, _grid_card(1, ("0.", "0.", "0."), rotated_cd_nodes))
        println(io, _grid_card(2, ("1.", "0.", "0."), rotated_cd_nodes))
        println(io, _grid_card(3, ("1.", "1.", "0."), rotated_cd_nodes))
        println(io, _grid_card(4, ("0.", "1.", "0."), rotated_cd_nodes))
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

function _solve_mass_case(deck::AbstractString, settings::Dict{String,String})
    return _with_mass_env(settings) do
        model = OpenJFEM.bdf_to_model(deck)
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                OpenJFEM.solve_model(model)
            end
        end
    end
end

function _check_mass_case(label::AbstractString, deck::AbstractString,
                          expected::AbstractString;
                          settings=Dict{String,String}())
    results = _solve_mass_case(deck, Dict{String,String}(settings))
    @testset "$label" begin
        @test results["sol_type"] == 103
        @test results["mass_summary"]["shell_mass_formulation"] == expected
        @test results["solver_diagnostics"]["shell_mass_formulation"] == expected
        @test isapprox(results["mass_summary"]["total_mass_x"], 54.0; rtol=1e-12, atol=1e-10)
        @test isapprox(results["mass_summary"]["total_mass_y"], 54.0; rtol=1e-12, atol=1e-10)
        @test isapprox(results["mass_summary"]["total_mass_z"], 54.0; rtol=1e-12, atol=1e-10)
        @test !isempty(results["eigenvalues"])
        @test all(isfinite, Float64.(results["eigenvalues"]))
        @test get(results["solver_diagnostics"], "modal_effective_mass_frame", "") ==
              "global_translation_in_analysis_dof_frame"
        @test !isempty(results["modal_effective_mass"])
        @test all(row -> isapprox(row["generalized_mass"], 1.0; rtol=1e-8, atol=1e-8),
                  results["modal_effective_mass"])
    end
    return results
end

function main()
    tmp = mktempdir(; prefix="openjfem_sol103_mass_formulation_")
    default_deck = _write_tria3_deck(joinpath(tmp, "default_mass.bdf"))
    coupmass_yes_deck = _write_tria3_deck(joinpath(tmp, "coupmass_yes.bdf"); coupmass="YES")
    coupmass_no_deck = _write_tria3_deck(joinpath(tmp, "coupmass_no.bdf"); coupmass="NO")
    rotated_cd_deck = _write_tria3_deck(
        joinpath(tmp, "rotated_cd_mass.bdf");
        rotated_cd_nodes=Set([2, 3]),
    )

    _check_mass_case("default coupled shell mass", default_deck, "coupled_consistent")
    _check_mass_case("PARAM COUPMASS YES", coupmass_yes_deck, "coupled_consistent")
    _check_mass_case("PARAM COUPMASS NO", coupmass_no_deck, "nastran_lumped")
    _check_mass_case("rotated GRID CD coupled shell mass", rotated_cd_deck, "coupled_consistent")
    _check_mass_case("environment forces lumped", default_deck, "nastran_lumped";
        settings=Dict("JFEM_SOL103_SHELL_MASS" => "lumped"))
    _check_mass_case("environment forces consistent over deck NO", coupmass_no_deck, "coupled_consistent";
        settings=Dict("JFEM_SOL103_SHELL_MASS" => "consistent"))
    _check_mass_case("environment default false", default_deck, "nastran_lumped";
        settings=Dict("JFEM_SOL103_SHELL_COUPLED_MASS_DEFAULT" => "false"))

    println("SOL103 mass formulation guard passed")
    println("  deck root = ", tmp)
    return true
end

main()
