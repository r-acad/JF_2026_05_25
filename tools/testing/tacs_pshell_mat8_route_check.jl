# Guard for direct PSHELL/MAT8 support in the TACS-formulation backend.
#
# This checks that a PSHELL referencing MAT8 routes through the residual-first
# shell formulation and that supported MAT8 design derivatives match full
# plus/minus SOL101 re-solves.
#
# Usage:
#   julia --project=. tools/testing/tacs_pshell_mat8_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_pshell_mat8_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS PSHELL MAT8 route guard")
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
        println(io, "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function _with_material_field(model, mid::Int, field::AbstractString, delta::Float64)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + delta
    field_key == "E1" && (mat["E"] = mat[field_key])
    field_key == "G12" && (mat["G"] = mat[field_key])
    field_key == "NU12" && (mat["NU"] = mat[field_key])
    m["backend"] = "tacs_formulation"
    return m
end

function _compliance_value(results)
    u = Float64.(results["subcases"][1]["u_analysis"])
    return dot(u, results["K"] * u)
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), 1e-30)
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_pshell_mat8_")
    deck = _write_pshell_mat8_sol101_deck(joinpath(tmp, "pshell_mat8_sol101.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["constitutive"] == "mat1_mat2_mat8_pshell_pcomp_clt"
    @test isfinite(_compliance_value(results))

    @test uppercase(string(results["model"]["MATs"]["1"]["TYPE"])) == "MAT8"

    material_checks = Dict{String,Any}()
    for (dv_type, field) in (
        ("material_E1", "E1"),
        ("material_E2", "E2"),
        ("material_G12", "G12"),
        ("material_NU12", "NU12"),
    )
        dv = Dict{String,Any}("id" => lowercase(field), "type" => dv_type, "mids" => [1])
        response = OpenJFEM.static_compliance_design_gradient(results, [dv])
        @test response["gradient_backend"] == "tacs_formulation_design_tangent"
        diag = response["design_variable_diagnostics"][dv["id"]]
        h = Float64(diag["step"])
        @test h > 0.0

        results_p = OpenJFEM.solve_model(_with_material_field(model, 1, field, h))
        results_m = OpenJFEM.solve_model(_with_material_field(model, 1, field, -h))
        fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
        hook = Float64(response["gradient"][dv["id"]])
        relerr = _relerr(hook, fd)
        @test relerr < 1e-5 || abs(hook - fd) < 1e-12
        material_checks[field] = (fd=fd, hook=hook, relerr=relerr)
    end

    println("TACS PSHELL/MAT8 route check passed")
    println("  deck                  = ", abspath(deck))
    println("  compliance            = ", _compliance_value(results))
    for field in sort(collect(keys(material_checks)))
        check = material_checks[field]
        println("  dCompliance/d", field, " FD     = ", check.fd)
        println("  dCompliance/d", field, " hook   = ", check.hook)
        println("  dCompliance/d", field, " relerr = ", check.relerr)
    end
end

main()
