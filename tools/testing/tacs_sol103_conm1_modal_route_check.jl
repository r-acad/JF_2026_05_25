# Guard for TACS-formulation SOL103 CONM1 full-matrix modal mass support.
#
# Usage:
#   julia --project=. tools/testing/tacs_sol103_conm1_modal_route_check.jl

using LinearAlgebra
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

using OpenJFEM

function _write_conm1_modal_deck(path::AbstractString)
    kx = 1200.0
    ky = 1800.0
    m11 = 4.0
    m21 = 0.6
    m22 = 5.0
    m33 = 2.0
    m44 = 1.0
    m55 = 1.1
    m66 = 1.2
    terms = [
        m11, m21, m22,
        0.0, 0.0, m33,
        0.0, 0.0, 0.0, m44,
        0.0, 0.0, 0.0, 0.0, m55,
        0.0, 0.0, 0.0, 0.0, 0.0, m66,
    ]
    open(path, "w") do io
        println(io, "SOL 103")
        println(io, "CEND")
        println(io, "TITLE = Generated TACS SOL103 CONM1 modal mass check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  METHOD = 1")
        println(io, "BEGIN BULK")
        println(io, "PARAM,AUTOSPC,YES")
        println(io, "GRID,1,,0.,0.,0.")
        println(io, "CELAS2,1,$kx,1,1")
        println(io, "CELAS2,2,$ky,1,2")
        println(io, "CONM1,1,1,,", join(string.(terms), ","))
        println(io, "SPC1,1,3456,1")
        println(io, "EIGRL,1,0.,1.0E8,2")
        println(io, "ENDDATA")
    end
    return (path=path, kx=kx, ky=ky, m11=m11, m21=m21, m22=m22)
end

function _relative_error(actual::Real, expected::Real)
    return abs(Float64(actual) - Float64(expected)) / max(abs(Float64(expected)), 1e-30)
end

function _solve_tacs(model::AbstractDict)
    m = deepcopy(model)
    m["backend"] = "tacs_formulation"
    return OpenJFEM.solve_model(m)
end

function _eigenvalue(model::AbstractDict, mode::Integer)
    return Float64(_solve_tacs(model)["eigenvalues"][Int(mode)])
end

function _expected_mass_term_derivative(case, row::Integer, col::Integer, mode::Integer)
    K2 = Diagonal([case.kx, case.ky])
    M2 = Symmetric([case.m11 case.m21; case.m21 case.m22])
    eig = eigen(Symmetric(Matrix(K2)), M2)
    order = sortperm(Float64.(eig.values))
    idx = order[Int(mode)]
    lambda = Float64(eig.values[idx])
    phi = Float64.(eig.vectors[:, idx])
    dM = zeros(Float64, 2, 2)
    dM[Int(row), Int(col)] = 1.0
    dM[Int(col), Int(row)] = 1.0
    return -lambda * dot(phi, dM * phi) / dot(phi, Matrix(M2) * phi)
end

function _check_conm1_point_mass_term(model::AbstractDict, results::AbstractDict;
    row::Integer,
    col::Integer,
    mode::Integer,
    expected=nothing,
)
    row_i = Int(row)
    col_i = Int(col)
    dv_id = "conm1_m$(row_i)$(col_i)"
    dv = Dict{String,Any}(
        "id" => dv_id,
        "type" => "point_mass",
        "eids" => [1],
        "component_pairs" => [(row_i, col_i)],
    )
    response = OpenJFEM.modal_eigenvalue_design_gradient(results, [dv]; mode=mode)
    @test response["response"] == "modal_eigenvalue"
    @test response["gradient_backend"] == "tacs_formulation_modal_mass_design_fd"
    @test response["mode"] == mode
    h = Float64(response["design_variable_diagnostics"][dv_id]["step"])
    hook = Float64(response["gradient"][dv_id])

    dM, _, _, _, _, dM_steps = OpenJFEM._tacs_assemble_sol103_mass_design_derivative(model, dv; step=h)
    @test !isempty(dM_steps)
    @test isapprox(dM[row_i, col_i], 1.0; rtol=0.0, atol=1e-9)
    @test isapprox(dM[col_i, row_i], 1.0; rtol=0.0, atol=1e-9)

    model_p = OpenJFEM._tacs_model_with_design_delta(model, dv, h)
    model_m = OpenJFEM._tacs_model_with_design_delta(model, dv, -h)
    fd = (_eigenvalue(model_p, mode) - _eigenvalue(model_m, mode)) / (2.0 * h)
    rel = _relative_error(hook, fd)
    @test isfinite(hook)
    @test isfinite(fd)
    @test rel < 1e-6
    expected_rel = isnothing(expected) ? 0.0 : _relative_error(hook, Float64(expected))
    isnothing(expected) || @test expected_rel < 1e-8
    return (fd=fd, hook=hook, rel=rel, expected=expected, expected_rel=expected_rel)
end

function _check_conm1_point_mass_component(model::AbstractDict, results::AbstractDict;
    component::Integer,
    mode::Integer,
    expected=nothing,
)
    return _check_conm1_point_mass_term(
        model,
        results;
        row=component,
        col=component,
        mode=mode,
        expected=expected,
    )
end

function main()
    tmp = mktempdir(; prefix="openjfem_tacs_conm1_modal_")
    case = _write_conm1_modal_deck(joinpath(tmp, "tacs_conm1_sol103.bdf"))
    model = OpenJFEM.bdf_to_model(case.path)
    model["backend"] = "tacs_formulation"
    parsed_m = Matrix{Float64}(model["CONM1s"]["1"]["M_FULL"])
    @test parsed_m[1, 2] == case.m21
    @test parsed_m[2, 1] == case.m21

    results = OpenJFEM.solve_model(model)
    @test occursin("shared_jfem_modal_point_mass", results["tacs_formulation_sol103"]["mass"])
    M_global = results["M"]
    @test isapprox(M_global[1, 1], case.m11; rtol=0.0, atol=1e-12)
    @test isapprox(M_global[1, 2], case.m21; rtol=0.0, atol=1e-12)
    @test isapprox(M_global[2, 1], case.m21; rtol=0.0, atol=1e-12)
    @test isapprox(M_global[2, 2], case.m22; rtol=0.0, atol=1e-12)

    K2 = Diagonal([case.kx, case.ky])
    M2 = Symmetric([case.m11 case.m21; case.m21 case.m22])
    expected = sort(Float64.(eigen(Symmetric(Matrix(K2)), M2).values))
    actual = sort(Float64.(results["eigenvalues"][1:2]))
    rels = [_relative_error(actual[i], expected[i]) for i in eachindex(expected)]
    @test maximum(rels) < 1e-10
    m11_expected = _expected_mass_term_derivative(case, 1, 1, 1)
    m12_expected = _expected_mass_term_derivative(case, 1, 2, 1)
    m22_expected = _expected_mass_term_derivative(case, 2, 2, 2)
    m11 = _check_conm1_point_mass_component(model, results; component=1, mode=1, expected=m11_expected)
    m12 = _check_conm1_point_mass_term(model, results; row=1, col=2, mode=1, expected=m12_expected)
    m22 = _check_conm1_point_mass_component(model, results; component=2, mode=2, expected=m22_expected)

    println("TACS SOL103 CONM1 modal route guard passed")
    println("  expected eigenvalues = ", expected)
    println("  actual eigenvalues   = ", actual)
    println("  max relative error   = ", maximum(rels))
    println("  assembled M12/M21    = ", M_global[1, 2], " / ", M_global[2, 1])
    println("  dLambda/dM11 FD/hook/expected/rel = ",
        m11.fd, " / ", m11.hook, " / ", m11.expected, " / ", m11.rel)
    println("  dLambda/dM12 FD/hook/expected/rel = ",
        m12.fd, " / ", m12.hook, " / ", m12.expected, " / ", m12.rel)
    println("  dLambda/dM22 FD/hook/expected/rel = ",
        m22.fd, " / ", m22.hook, " / ", m22.expected, " / ", m22.rel)
    return true
end

exit(main() ? 0 : 1)
