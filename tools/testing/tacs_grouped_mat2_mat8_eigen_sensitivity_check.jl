# Guard for grouped direct PSHELL/MAT2 and PSHELL/MAT8 eigen sensitivities.
#
# This complements tacs_pshell_mat2_mat8_eigen_route_check.jl by checking a
# grouped material design variable: one scalar perturbation is applied to two
# material IDs of the same direct shell material family.
#
# Usage:
#   julia --project=. tools/testing/tacs_grouped_mat2_mat8_eigen_sensitivity_check.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

function _material_card(material::Symbol, mid::Integer)
    i = Int(mid)
    if material == :mat2
        i == 1 && return "MAT2,1,1.20E11,2.00E10,5.00E9,8.00E10,3.00E9,4.00E10,1600."
        i == 2 && return "MAT2,2,1.05E11,1.60E10,4.00E9,7.20E10,2.50E9,3.60E10,1550."
    elseif material == :mat8
        i == 1 && return "MAT8,1,1.35E11,9.0E9,0.28,5.0E9,4.0E9,3.6E9,1600."
        i == 2 && return "MAT8,2,1.10E11,8.0E9,0.26,4.4E9,3.6E9,3.2E9,1550."
    end
    error("Unsupported material '$material' id $mid.")
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

function _write_deck(path::AbstractString, sol::Integer, material::Symbol)
    sol in (103, 105) || error("Grouped MAT2/MAT8 eigen guard only writes SOL103/SOL105 decks.")
    open(path, "w") do io
        println(io, "SOL ", sol)
        println(io, "CEND")
        println(io, "TITLE = TACS grouped ", uppercase(string(material)), " SOL", sol, " eigen guard")
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
        println(io, "GRID,3,,2.,0.,0.")
        println(io, "GRID,4,,0.,1.,0.")
        println(io, "GRID,5,,1.,1.,0.")
        println(io, "GRID,6,,2.,1.,0.")
        println(io, "CQUAD4,1,1,1,2,5,4,10.")
        println(io, "CQUAD4,2,2,2,3,6,5,25.")
        println(io, "PSHELL,1,1,0.018")
        println(io, "PSHELL,2,2,0.026")
        println(io, _material_card(material, 1))
        println(io, _material_card(material, 2))
        println(io, "SPC1,1,123456,1,4")
        if sol == 105
            println(io, "FORCE,1,3,0,-1000.,1.,0.,0.")
            println(io, "FORCE,1,6,0,-1000.,1.,0.,0.")
        end
        println(io, "EIGRL,1,0.,1.0E9,4")
        println(io, "ENDDATA")
    end
    return path
end

function _solve(path_or_model)
    if path_or_model isa AbstractString
        model = OpenJFEM.bdf_to_model(path_or_model)
        model["backend"] = "tacs_formulation"
        return OpenJFEM.solve_model(model)
    end
    model = deepcopy(path_or_model)
    model["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(model)
end

function _first_eigenvalue(results_or_model)
    results = haskey(results_or_model, "eigenvalues") ? results_or_model : _solve(results_or_model)
    return Float64(results["eigenvalues"][1])
end

function _with_grouped_material_delta(model::AbstractDict, material::Symbol, field::AbstractString, delta::Real)
    m = deepcopy(model)
    field_key = uppercase(strip(field))
    for mid in (1, 2)
        mat = m["MATs"][string(mid)]
        mat[field_key] = Float64(mat[field_key]) + Float64(delta)
        if material == :mat2
            G11 = Float64(get(mat, "G11", 0.0))
            G12 = Float64(get(mat, "G12", 0.0))
            G33 = Float64(get(mat, "G33", 0.0))
            nu_eq = G11 > 0.0 ? clamp(G12 / G11, 0.0, 0.49) : 0.3
            mat["E"] = G11 > 0.0 ? G11 * (1.0 - nu_eq^2) : 0.0
            mat["G"] = G33
            mat["NU"] = nu_eq
        elseif material == :mat8
            field_key == "E1" && (mat["E"] = mat[field_key])
            field_key == "G12" && (mat["G"] = mat[field_key])
            field_key == "NU12" && (mat["NU"] = mat[field_key])
        end
    end
    m["backend"] = "tacs_formulation"
    return m
end

function _relerr(a::Real, b::Real)
    return abs(Float64(a) - Float64(b)) / max(abs(Float64(a)), abs(Float64(b)), eps(Float64))
end

function _grouped_material_dv(dv_type::AbstractString, field::AbstractString)
    dv = Dict{String,Any}("id" => "group_" * lowercase(field), "type" => dv_type, "mids" => [1, 2])
    uppercase(strip(field)) == "NU12" && (dv["step"] = 1e-5)
    return dv
end

function _check_modal(results::AbstractDict, material::Symbol)
    specs = _field_specs(material)
    dvs = Dict{String,Any}[
        _grouped_material_dv(dv_type, field)
        for (dv_type, field) in specs
    ]
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, dvs; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_modal_design_tangent_fd"
    checks = Dict{String,Any}()
    for (_, field) in specs
        dv_id = "group_" * lowercase(field)
        diag = response["design_variable_diagnostics"][dv_id]
        @test diag["mids"] == [1, 2]
        h = Float64(diag["step"])
        @test h > 0.0
        lambda_p = _first_eigenvalue(_with_grouped_material_delta(results["model"], material, field, h))
        lambda_m = _first_eigenvalue(_with_grouped_material_delta(results["model"], material, field, -h))
        fd = (lambda_p - lambda_m) / (2.0 * h)
        hook = Float64(response["gradient"][dv_id])
        rel = _relerr(hook, fd)
        @test rel < 8e-5 || abs(hook - fd) < 1e-6
        checks["sol103_" * field] = (fd=fd, hook=hook, rel=rel)
    end
    return checks
end

function _check_buckling(results::AbstractDict, material::Symbol)
    specs = _field_specs(material)
    dvs = Dict{String,Any}[
        _grouped_material_dv(dv_type, field)
        for (dv_type, field) in specs
    ]
    response = OpenJFEM.buckling_load_factor_design_gradient(results, dvs; mode=1)
    @test response["gradient_backend"] == "tacs_formulation_rayleigh_design_kg_directional_fd"
    checks = Dict{String,Any}()
    for (_, field) in specs
        dv_id = "group_" * lowercase(field)
        diag = response["design_variable_diagnostics"][dv_id]
        @test diag["mids"] == [1, 2]
        h = Float64(diag["step"])
        @test h > 0.0
        lambda_p = _first_eigenvalue(_with_grouped_material_delta(results["model"], material, field, h))
        lambda_m = _first_eigenvalue(_with_grouped_material_delta(results["model"], material, field, -h))
        fd = (lambda_p - lambda_m) / (2.0 * h)
        hook = Float64(response["gradient"][dv_id])
        rel = _relerr(hook, fd)
        @test rel < 2e-4 || abs(hook - fd) < 1e-8
        checks["sol105_" * field] = (fd=fd, hook=hook, rel=rel)
    end
    return checks
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_grouped_mat_eigen_")
    checks = Dict{String,Any}()
    for material in (:mat2, :mat8)
        sol103 = _write_deck(joinpath(tmp, "$(material)_grouped_sol103.bdf"), 103, material)
        sol105 = _write_deck(joinpath(tmp, "$(material)_grouped_sol105.bdf"), 105, material)
        modal_results = _solve(sol103)
        buckling_results = _solve(sol105)
        @test modal_results["backend"] == "tacs_formulation"
        @test buckling_results["backend"] == "tacs_formulation"
        @test modal_results["sol_type"] == 103
        @test buckling_results["sol_type"] == 105
        for (name, check) in _check_modal(modal_results, material)
            checks["$(material)_$(name)"] = check
        end
        for (name, check) in _check_buckling(buckling_results, material)
            checks["$(material)_$(name)"] = check
        end
    end

    println("TACS grouped MAT2/MAT8 eigen sensitivity check passed")
    println("  workdir = ", abspath(tmp))
    for (name, check) in sort(collect(checks); by=first)
        println("  ", name, " FD = ", check.fd, " hook = ", check.hook, " rel = ", check.rel)
    end
    return true
end

main()
