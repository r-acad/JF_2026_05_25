# Guard for direct PSHELL/MAT2 and PSHELL/MAT8 modal/buckling routes.
#
# This checks that direct anisotropic/orthotropic PSHELL constitutives flow
# through SOL103 and SOL105 design gradients, not just SOL101 static solves.
#
# Usage:
#   julia --project=. tools/testing/tacs_pshell_mat2_mat8_eigen_route_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _material_card(material::Symbol)
    if material == :mat2
        return "MAT2,1,1.20E11,2.00E10,5.00E9,8.00E10,3.00E9,4.00E10,1600."
    elseif material == :mat8
        return "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600."
    end
    error("Unsupported material '$material'.")
end

function _write_deck(path::AbstractString, sol::Integer, material::Symbol)
    sol in (103, 105) || error("This guard only writes SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS PSHELL ", uppercase(string(material)), " SOL", sol, " eigen route guard")
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
        println(io, "GRID,3,,1.,1.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,3,4,12.")
        println(io, "PSHELL,1,1,0.02")
        println(io, _material_card(material))
        println(io, "SPC1,1,123456,1,4")
        if sol == 105
            println(io, "FORCE,1,2,0,-1000.,1.,0.,0.")
            println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
        end
        println(io, "EIGRL,1,0.,1.0E9,3")
        println(io, "ENDDATA")
    end
    return path
end

function _solve_model(path::AbstractString)
    model = OpenJFEM.bdf_to_model(path)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _with_material_field_delta(model::AbstractDict, mid::Integer, field::AbstractString, delta::Real)
    m = deepcopy(model)
    mat = m["MATs"][string(Int(mid))]
    field_key = uppercase(strip(string(field)))
    mat[field_key] = Float64(mat[field_key]) + Float64(delta)
    mat_type = uppercase(string(get(mat, "TYPE", "MAT1")))
    if mat_type == "MAT2"
        G11 = Float64(get(mat, "G11", 0.0))
        G12 = Float64(get(mat, "G12", 0.0))
        G33 = Float64(get(mat, "G33", 0.0))
        nu_eq = G11 > 0.0 ? clamp(G12 / G11, 0.0, 0.49) : 0.3
        mat["E"] = G11 > 0.0 ? G11 * (1.0 - nu_eq^2) : 0.0
        mat["G"] = G33
        mat["NU"] = nu_eq
    elseif mat_type == "MAT8"
        field_key == "E1" && (mat["E"] = mat[field_key])
        field_key == "G12" && (mat["G"] = mat[field_key])
        field_key == "NU12" && (mat["NU"] = mat[field_key])
    end
    m["backend"] = "tacs_formulation"
    return m
end

function _first_eigenvalue(results)
    return Float64(results["eigenvalues"][1])
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function _field_specs(material::Symbol)
    material == :mat2 && return (
        ("material_G11", "G11"),
        ("material_G12", "G12"),
        ("material_G13", "G13"),
        ("material_G22", "G22"),
        ("material_G23", "G23"),
        ("material_G33", "G33"),
    )
    material == :mat8 && return (
        ("material_E1", "E1"),
        ("material_E2", "E2"),
        ("material_G12", "G12"),
        ("material_NU12", "NU12"),
    )
    error("Unsupported material '$material'.")
end

function _check_modal(results::AbstractDict, material::Symbol)
    specs = _field_specs(material)
    dvs = Dict{String,Any}[
        Dict{String,Any}("id" => lowercase(field), "type" => dv_type, "mids" => [1])
        for (dv_type, field) in specs
    ]
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, dvs; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_modal_design_tangent_fd"
    checks = Dict{String,Any}()
    for (_, field) in specs
        dv_id = lowercase(field)
        h = Float64(response["design_variable_diagnostics"][dv_id]["step"])
        @test h > 0.0
        lambda_p = _first_eigenvalue(OpenJFEM.solve_model(_with_material_field_delta(results["model"], 1, field, h)))
        lambda_m = _first_eigenvalue(OpenJFEM.solve_model(_with_material_field_delta(results["model"], 1, field, -h)))
        fd = (lambda_p - lambda_m) / (2.0 * h)
        hook = Float64(response["gradient"][dv_id])
        rel = _relerr(hook, fd)
        @test rel < 5e-5 || abs(hook - fd) < 1e-6
        checks[field] = (fd=fd, hook=hook, rel=rel)
    end
    return checks
end

function _check_buckling(results::AbstractDict, material::Symbol)
    specs = _field_specs(material)
    dvs = Dict{String,Any}[
        Dict{String,Any}("id" => lowercase(field), "type" => dv_type, "mids" => [1])
        for (dv_type, field) in specs
    ]
    response = OpenJFEM.buckling_load_factor_design_gradient(results, dvs; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    checks = Dict{String,Any}()
    for (_, field) in specs
        dv_id = lowercase(field)
        h = Float64(response["design_variable_diagnostics"][dv_id]["step"])
        @test h > 0.0
        lambda_p = _first_eigenvalue(OpenJFEM.solve_model(_with_material_field_delta(results["model"], 1, field, h)))
        lambda_m = _first_eigenvalue(OpenJFEM.solve_model(_with_material_field_delta(results["model"], 1, field, -h)))
        fd = (lambda_p - lambda_m) / (2.0 * h)
        hook = Float64(response["gradient"][dv_id])
        rel = _relerr(hook, fd)
        @test rel < 1e-4 || abs(hook - fd) < 1e-8
        checks[field] = (fd=fd, hook=hook, rel=rel)
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_pshell_eigen_routes_")
    checks = Dict{String,Any}()
    for material in (:mat2, :mat8)
        sol103 = _write_deck(joinpath(tmp, "$(material)_sol103.bdf"), 103, material)
        sol105 = _write_deck(joinpath(tmp, "$(material)_sol105.bdf"), 105, material)
        modal_results = _solve_model(sol103)
        buckling_results = _solve_model(sol105)
        @test modal_results["backend"] == "tacs_formulation"
        @test buckling_results["backend"] == "tacs_formulation"
        @test modal_results["sol_type"] == 103
        @test buckling_results["sol_type"] == 105
        @test modal_results["formulation"]["constitutive"] == "mat1_mat2_mat8_pshell_pcomp_clt"
        @test buckling_results["formulation"]["constitutive"] == "mat1_mat2_mat8_pshell_pcomp_clt"
        for (field, check) in _check_modal(modal_results, material)
            checks["$(material)_sol103_$(field)"] = check
        end
        for (field, check) in _check_buckling(buckling_results, material)
            checks["$(material)_sol105_$(field)"] = check
        end
    end

    println("TACS PSHELL/MAT2-MAT8 eigen route check passed")
    println("  workdir = ", abspath(tmp))
    for (name, check) in sort(collect(checks); by=first)
        println("  ", name, " FD = ", check.fd, " hook = ", check.hook, " rel = ", check.rel)
    end
    return true
end

main()
