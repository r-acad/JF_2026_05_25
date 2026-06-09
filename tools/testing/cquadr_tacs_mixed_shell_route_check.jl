using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
delete!(ENV, "JFEM_BACKEND")

using OpenJFEM

const TACS_SHELL_FORMULATION = "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"

function _relative_symmetry_error(K)
    denom = max(norm(K), eps(Float64))
    return norm(K - transpose(K)) / denom
end

function _write_common_bulk(io; load_kind::Symbol=:vertical)
    println(io, "PARAM,AUTOSPC,YES")
    coords = Dict(
        1 => (0.0, 0.0, 0.0), 2 => (1.0, 0.0, 0.0), 3 => (2.0, 0.0, 0.0),
        4 => (0.0, 1.0, 0.0), 5 => (1.0, 1.0, 0.0), 6 => (2.0, 1.0, 0.0),
        7 => (0.0, 2.0, 0.0), 8 => (1.0, 2.0, 0.0), 9 => (2.0, 2.0, 0.0),
    )
    for gid in 1:9
        x, y, z = coords[gid]
        println(io, "GRID,$gid,,$x,$y,$z")
    end
    println(io, "CQUAD4,1,1,1,2,5,4")
    println(io, "CQUADR,2,1,2,3,6,5")
    println(io, "CTRIA3,3,1,4,5,8")
    println(io, "CTRIA3,4,1,4,8,7")
    println(io, "CQUAD4,5,1,5,6,9,8")
    println(io, "PSHELL,1,1,0.018")
    println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
    println(io, "SPC1,1,123456,1,4,7")
    if load_kind == :compression
        for nid in (3, 6, 9)
            println(io, "FORCE,1,$nid,0,-600.,1.,0.,0.")
        end
    else
        for nid in (3, 6, 8, 9)
            println(io, "FORCE,1,$nid,0,75.,0.,0.,-1.")
        end
    end
    return nothing
end

function _write_mixed_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated mixed CQUAD4/CQUADR/CTRIA3 TACS SOL101 check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        _write_common_bulk(io; load_kind=:vertical)
        println(io, "ENDDATA")
    end
    return path
end

function _write_mixed_sol103_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated mixed CQUAD4/CQUADR/CTRIA3 TACS SOL103 check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        _write_common_bulk(io; load_kind=:vertical)
        println(io, "EIGRL,1,0.,1.0E9,6")
        println(io, "ENDDATA")
    end
    return path
end

function _write_mixed_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated mixed CQUAD4/CQUADR/CTRIA3 TACS SOL105 check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "SUBCASE 2")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "  STATSUB = 1")
        println(io, "BEGIN BULK")
        _write_common_bulk(io; load_kind=:compression)
        println(io, "EIGRL,1,0.,1.0E9,4")
        println(io, "ENDDATA")
    end
    return path
end

function _element_type_counts(model::Dict)
    counts = Dict{String,Int}()
    for (_, el) in get(model, "CSHELLs", Dict())
        typ = uppercase(string(get(el, "TYPE", "")))
        counts[typ] = get(counts, typ, 0) + 1
    end
    return counts
end

function _diagnostics_record_cquadr_forcing(results::Dict)
    diagnostics = get(results, "solver_diagnostics", nothing)
    if diagnostics isa AbstractDict
        return get(diagnostics, "backend_forced_by", "") == "CQUADR"
    elseif diagnostics isa AbstractVector
        return any(
            d -> d isa AbstractDict &&
                 get(d, "phase", "") == "backend_selection" &&
                 get(d, "backend_forced_by", "") == "CQUADR",
            diagnostics,
        )
    end
    return false
end

function _check_model_scope(model::Dict)
    @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
    counts = _element_type_counts(model)
    @test counts["CQUAD4"] == 2
    @test counts["CQUADR"] == 1
    @test counts["CTRIA3"] == 2
    @test sum(values(counts)) == 5
    return true
end

function _check_forced_metadata(results::Dict, sol_type::Int)
    @test results["sol_type"] == sol_type
    @test results["backend"] == "tacs_formulation"
    @test results["requested_backend"] == "nastran_parity"
    @test results["backend_forced_by"] == "CQUADR"
    @test results["formulation"]["shell"] == TACS_SHELL_FORMULATION
    @test _diagnostics_record_cquadr_forcing(results)
    return true
end

function _check_sol101(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 101)
    @test haskey(results, "subcases")
    @test length(results["subcases"]) == 1
    @test length(results["subcases"][1]["raw_displacement"]) == results["ndof"]
    @test _relative_symmetry_error(results["K"]) < 1e-12

    gradient = OpenJFEM.static_compliance_thickness_gradient(results; pids=[1])
    @test gradient["gradient_backend"] == "tacs_formulation_element_ad"
    @test isfinite(Float64(gradient["value"]))
    @test isfinite(Float64(gradient["gradient"]["1"]))
    return results, gradient
end

function _check_sol103(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 103)
    eigenvalues = Float64.(results["eigenvalues"])
    frequencies = Float64.(results["frequencies"])
    expected_shell_mass = OpenJFEM.Solver.sol103_shell_mass_formulation_name(model)
    @test results["tacs_formulation_sol103"]["linear_stiffness"] == "residual_first_quad4_cquadr_tria3"
    @test results["tacs_formulation_sol103"]["mass"] == "shared_jfem_mass_" * expected_shell_mass
    @test !isempty(eigenvalues)
    @test !isempty(frequencies)
    @test all(isfinite, eigenvalues)
    @test all(isfinite, frequencies)
    @test all(>=(0.0), frequencies)
    @test _relative_symmetry_error(results["K"]) < 1e-12
    return results
end

function _check_sol105(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 105)
    eigenvalues = Float64.(results["eigenvalues"])
    @test results["tacs_formulation_sol105"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test !isempty(eigenvalues)
    @test all(isfinite, eigenvalues)
    @test nnz(results["Kg"]) > 0
    @test results["solver_diagnostics"][1]["kg_timings"]["tacs_native_kg_elements"] == 5
    @test _relative_symmetry_error(results["K"]) < 1e-12

    gradient = OpenJFEM.buckling_load_factor_thickness_gradient(results; pids=[1], mode=1)
    @test gradient["gradient_backend"] == "tacs_formulation_rayleigh_ad_kg_directional_fd"
    @test isfinite(Float64(gradient["gradient"]["1"]))
    return results, gradient
end

function main()
    tmp = mktempdir(; prefix="openjfem_cquadr_mixed_shell_tacs_")
    sol101_deck = _write_mixed_sol101_deck(joinpath(tmp, "mixed_shell_sol101.bdf"))
    sol103_deck = _write_mixed_sol103_deck(joinpath(tmp, "mixed_shell_sol103.bdf"))
    sol105_deck = _write_mixed_sol105_deck(joinpath(tmp, "mixed_shell_sol105.bdf"))

    sol101_results, compliance_gradient = _check_sol101(sol101_deck)
    sol103_results = _check_sol103(sol103_deck)
    sol105_results, buckling_gradient = _check_sol105(sol105_deck)

    println("CQUADR mixed-shell TACS route check passed")
    println("  SOL101 deck       = ", abspath(sol101_deck))
    println("  SOL101 ndof       = ", sol101_results["ndof"])
    println("  dCompliance/dt    = ", Float64(compliance_gradient["gradient"]["1"]))
    println("  SOL103 deck       = ", abspath(sol103_deck))
    println("  SOL103 first freq = ", Float64(sol103_results["frequencies"][1]))
    println("  SOL105 deck       = ", abspath(sol105_deck))
    println("  SOL105 first eig  = ", Float64(sol105_results["eigenvalues"][1]))
    println("  SOL105 dLambda/dt = ", Float64(buckling_gradient["gradient"]["1"]))
    println("  SOL105 Kg nnz     = ", nnz(sol105_results["Kg"]))
    return true
end

exit(main() ? 0 : 1)
