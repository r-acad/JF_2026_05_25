# Guard for direct PSHELL/MAT2 support in the TACS-formulation backend.
#
# This checks that a PSHELL referencing MAT2 routes through the residual-first
# shell formulation and that shell-thickness and MAT2 material-field
# compliance derivatives match full plus/minus SOL101 re-solves.
#
# Usage:
#   julia --project=. tools/testing/tacs_pshell_mat2_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _write_pshell_mat2_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = TACS PSHELL MAT2 route guard")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "GRID,2,,1.,0.,0.")
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4,15.")
        println(io, "PSHELL,1,1,0.02")
        println(io, "MAT2,1,1.20E11,2.00E10,5.00E9,8.00E10,3.00E9,4.00E10,1600.")
        println(io, "SPC1,1,123456,1,4")
        println(io, "FORCE,1,2,0,100.,0.,0.,-1.")
        println(io, "FORCE,1,3,0,100.,0.,0.,-1.")
        println(io, "ENDDATA")
    end
    return path
end

function _with_shell_thickness(model, pid::Int, value::Real)
    m = deepcopy(model)
    prop = m["PSHELLs"][string(pid)]
    prop["T"] = Float64(value)
    m["backend"] = "tacs_formulation"
    return m
end

function _with_material_field(model, mid::Int, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = m["MATs"][string(mid)]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + Float64(delta)
    G11 = Float64(get(mat, "G11", 0.0))
    G12 = Float64(get(mat, "G12", 0.0))
    G33 = Float64(get(mat, "G33", 0.0))
    nu_eq = G11 > 0.0 ? clamp(G12 / G11, 0.0, 0.49) : 0.3
    mat["E"] = G11 > 0.0 ? G11 * (1.0 - nu_eq^2) : 0.0
    mat["G"] = G33
    mat["NU"] = nu_eq
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
    tmp = mktempdir(; prefix="openjfem_tacs_pshell_mat2_")
    deck = _write_pshell_mat2_sol101_deck(joinpath(tmp, "pshell_mat2_sol101.bdf"))
    model = OpenJFEM.bdf_to_model(deck)
    model["backend"] = "tacs_formulation"

    results = OpenJFEM.solve_model(model)
    @test results["backend"] == "tacs_formulation"
    @test results["formulation"]["constitutive"] == "mat1_mat2_mat8_pshell_pcomp_clt"
    @test isfinite(_compliance_value(results))
    @test uppercase(string(results["model"]["MATs"]["1"]["TYPE"])) == "MAT2"

    response = OpenJFEM.static_compliance_thickness_gradient(results; pids=[1])
    @test response["gradient_backend"] == "tacs_formulation_element_ad"
    @test haskey(response["gradient"], "1")

    t0 = Float64(model["PSHELLs"]["1"]["T"])
    h = max(1e-5 * t0, 1e-7)
    results_p = OpenJFEM.solve_model(_with_shell_thickness(model, 1, t0 + h))
    results_m = OpenJFEM.solve_model(_with_shell_thickness(model, 1, t0 - h))
    fd = (_compliance_value(results_p) - _compliance_value(results_m)) / (2.0 * h)
    hook = Float64(response["gradient"]["1"])
    relerr = _relerr(hook, fd)
    @test relerr < 1e-5

    material_checks = Dict{String,Any}()
    for (dv_type, field) in (
        ("material_G11", "G11"),
        ("material_G12", "G12"),
        ("material_G13", "G13"),
        ("material_G22", "G22"),
        ("material_G23", "G23"),
        ("material_G33", "G33"),
    )
        dv = Dict{String,Any}("id" => lowercase(field), "type" => dv_type, "mids" => [1])
        material_response = OpenJFEM.static_compliance_design_gradient(results, [dv])
        @test material_response["gradient_backend"] == "tacs_formulation_design_tangent"
        diag = material_response["design_variable_diagnostics"][dv["id"]]
        h_mat = Float64(diag["step"])
        @test h_mat > 0.0

        results_p_mat = OpenJFEM.solve_model(_with_material_field(model, 1, field, h_mat))
        results_m_mat = OpenJFEM.solve_model(_with_material_field(model, 1, field, -h_mat))
        fd_mat = (_compliance_value(results_p_mat) - _compliance_value(results_m_mat)) / (2.0 * h_mat)
        hook_mat = Float64(material_response["gradient"][dv["id"]])
        relerr_mat = _relerr(hook_mat, fd_mat)
        @test relerr_mat < 1e-5 || abs(hook_mat - fd_mat) < 1e-12
        material_checks[field] = (fd=fd_mat, hook=hook_mat, relerr=relerr_mat)
    end

    println("TACS PSHELL/MAT2 route check passed")
    println("  deck                  = ", abspath(deck))
    println("  compliance            = ", _compliance_value(results))
    println("  dCompliance/dt FD     = ", fd)
    println("  dCompliance/dt hook   = ", hook)
    println("  dCompliance/dt relerr = ", relerr)
    for field in sort(collect(keys(material_checks)))
        check = material_checks[field]
        println("  dCompliance/d", field, " FD     = ", check.fd)
        println("  dCompliance/d", field, " hook   = ", check.hook)
        println("  dCompliance/d", field, " relerr = ", check.relerr)
    end
end

main()
