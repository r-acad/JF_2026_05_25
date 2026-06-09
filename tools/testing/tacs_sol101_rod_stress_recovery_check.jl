# Guard for TACS-formulation SOL101 CROD/CONROD stress recovery.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol101_rod_stress_recovery_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

const E_ROD = 7.0e10
const G_ROD = 2.6923e10
const RHO_ROD = 2700.0

function _write_crod_deck(path::AbstractString)
    A = 1.0e-2
    J = 2.5e-5
    L = 2.0
    F = 1000.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CROD stress recovery check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CROD,1,1,1,2")
        println(io, "PROD,1,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, force=F, family="crod")
end

function _write_conrod_deck(path::AbstractString)
    A = 7.0e-3
    J = 1.6e-5
    L = 1.5
    F = 600.0
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL101 CONROD stress recovery check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,$L,0.,0.")
        println(io, "CONROD,1,1,2,1,$A,$J")
        println(io, "MAT1,1,$E_ROD,$G_ROD,0.3,$RHO_ROD")
        println(io, "SPC1,1,123456,1")
        println(io, "SPC1,1,23456,2")
        println(io, "FORCE,1,2,0,$F,1.,0.,0.")
        println(io, "ENDDATA")
    end
    return (path=path, area=A, force=F, family="conrod")
end

function _solve(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _relerr(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _first_row(subcase::AbstractDict, table::AbstractString, family::AbstractString)
    rows = subcase[table][family]
    @test length(rows) == 1
    return first(rows)
end

function _check_case(case)
    results = _solve(case.path)
    @test results["backend"] == "tacs_formulation"
    subcase = results["subcases"][1]
    force_row = _first_row(subcase, "forces", case.family)
    stress_row = _first_row(subcase, "stresses", case.family)
    strain_row = _first_row(subcase, "strains", case.family)

    expected_force = case.force
    expected_stress = case.force / case.area
    expected_strain = expected_stress / E_ROD

    force_relerr = _relerr(force_row["axial"], expected_force)
    stress_relerr = _relerr(stress_row["axial"], expected_stress)
    strain_relerr = _relerr(strain_row["axial"], expected_strain)
    @test force_relerr < 1e-10
    @test stress_relerr < 1e-10
    @test strain_relerr < 1e-10
    @test abs(Float64(force_row["torque"])) < 1e-12
    @test abs(Float64(stress_row["torsional"])) < 1e-12
    return force_relerr, stress_relerr, strain_relerr
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_rod_stress_")
    crod = _write_crod_deck(joinpath(tmp, "tacs_crod_stress.bdf"))
    conrod = _write_conrod_deck(joinpath(tmp, "tacs_conrod_stress.bdf"))
    crod_force, crod_stress, crod_strain = _check_case(crod)
    conrod_force, conrod_stress, conrod_strain = _check_case(conrod)

    println("TACS SOL101 rod stress recovery guard passed")
    println("  CROD axial force relerr   = $crod_force")
    println("  CROD axial stress relerr  = $crod_stress")
    println("  CROD axial strain relerr  = $crod_strain")
    println("  CONROD axial force relerr = $conrod_force")
    println("  CONROD axial stress relerr= $conrod_stress")
    println("  CONROD axial strain relerr= $conrod_strain")
    return true
end

exit(main() ? 0 : 1)
