using LinearAlgebra
using SparseArrays
using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
delete!(ENV, "JFEM_BACKEND")

using OpenJFEM

const TACS_SHELL_FORMULATION = "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
const TACS_LINEAR_ROUTE = "residual_first_quad4_cquadr_tria3"
const TACS_GEOMETRIC_ROUTE = "native_residual_first_quad4_cquadr_tria3"

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
    println(io, "CQUADR,2,2,2,3,6,5")
    println(io, "CTRIA3,3,1,4,5,8")
    println(io, "CTRIA3,4,1,4,8,7")
    println(io, "CQUAD4,5,2,5,6,9,8")
    println(io, "PSHELL,1,1,0.016")
    println(io, "PSHELL,2,1,0.024")
    println(io, "MAT1,1,7.0E10,2.6923E10,0.3,2700.")
    println(io, "SPC1,1,123456,1,4,7")
    if load_kind == :compression
        for nid in (3, 6, 9)
            println(io, "FORCE,1,$nid,0,-550.,1.,0.,0.")
        end
    else
        for nid in (3, 6, 8, 9)
            println(io, "FORCE,1,$nid,0,70.,0.,0.,-1.")
        end
    end
    return nothing
end

function _write_sol101_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 101")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR multi-property TACS SOL101 check")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        _write_common_bulk(io; load_kind=:vertical)
        println(io, "ENDDATA")
    end
    return path
end

function _write_sol105_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 105")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR multi-property TACS SOL105 check")
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

function _write_sol200_deck(path::AbstractString)
    open(path, "w") do io
        println(io, "SOL 200")
        println(io, "CEND")
        println(io, "TITLE = Generated CQUADR multi-property TACS SOL200 check")
        println(io, "DESOBJ(MIN) = 1")
        println(io, "SUBCASE 1")
        println(io, "  SPC = 1")
        println(io, "  LOAD = 1")
        println(io, "BEGIN BULK")
        _write_common_bulk(io; load_kind=:vertical)
        println(io, "DESVAR,1,TLEFT,0.016,0.008,0.04,0.2")
        println(io, "DESVAR,2,TRIGHT,0.024,0.008,0.05,0.2")
        println(io, "DVPREL1,1,PSHELL,1,T,0.008,0.04,0.0,1,1.0")
        println(io, "DVPREL1,2,PSHELL,2,T,0.008,0.05,0.0,2,1.0")
        println(io, "DRESP1,1,COMP,COMP")
        println(io, "DRESP1,2,MASS,MASS")
        println(io, "DCONSTR,1,2,,260.0")
        println(io, "DOPTPRM,DESMAX,1,CONV1,1.0E-6,DELX,0.2")
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

function _kg_timing_diagnostics(results::Dict)
    diagnostics = get(results, "solver_diagnostics", Any[])
    diagnostics isa AbstractVector || error("Expected vector solver diagnostics.")
    for d in diagnostics
        d isa AbstractDict || continue
        haskey(d, "kg_timings") && return d
    end
    error("Could not find SOL105 Kg timing diagnostics.")
end

function _check_model_scope(model::Dict)
    @test OpenJFEM.backend_name(OpenJFEM.backend_from_model(model)) == "nastran_parity"
    counts = _element_type_counts(model)
    @test counts["CQUAD4"] == 2
    @test counts["CQUADR"] == 1
    @test counts["CTRIA3"] == 2
    @test sum(values(counts)) == 5
    @test sort!(Int[parse(Int, pid) for pid in keys(model["PSHELLs"])]) == [1, 2]
    return true
end

function _check_forced_metadata(results::Dict, sol_type::Int)
    @test results["sol_type"] == sol_type
    @test results["backend"] == "tacs_formulation"
    @test results["requested_backend"] == "nastran_parity"
    @test results["backend_forced_by"] == "CQUADR"
    @test results["formulation"]["shell"] == TACS_SHELL_FORMULATION
    @test results["formulation"]["geometric_stiffness"] == TACS_GEOMETRIC_ROUTE
    @test _diagnostics_record_cquadr_forcing(results)
    return true
end

function _check_pid_gradient_payload(payload::Dict; expected_backend::AbstractString)
    @test payload["gradient_backend"] == expected_backend
    gradient = payload["gradient"]
    @test sort!(collect(keys(gradient))) == ["1", "2"]
    values = Float64[Float64(gradient["1"]), Float64(gradient["2"])]
    @test all(isfinite, values)
    @test sum(abs, values) > 0.0
    return values
end

function _check_sol101(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 101)
    @test length(results["subcases"][1]["raw_displacement"]) == results["ndof"]
    @test _relative_symmetry_error(results["K"]) < 1e-12

    compliance_gradient = OpenJFEM.static_compliance_thickness_gradient(results)
    compliance_values = _check_pid_gradient_payload(
        compliance_gradient;
        expected_backend="tacs_formulation_element_ad",
    )

    response = Dict{String,Any}("type" => "displacement", "grid" => 9, "dof" => 3)
    displacement_gradient = OpenJFEM.static_displacement_thickness_gradient(results, response)
    displacement_values = _check_pid_gradient_payload(
        displacement_gradient;
        expected_backend="tacs_formulation_element_ad_adjoint",
    )
    @test displacement_gradient["grid"] == 9
    @test displacement_gradient["dof"] == 3
    return results, compliance_values, displacement_values
end

function _check_sol105(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 105)
    @test results["tacs_formulation_sol105"]["linear_stiffness"] == TACS_LINEAR_ROUTE
    @test results["tacs_formulation_sol105"]["geometric_stiffness"] == TACS_GEOMETRIC_ROUTE
    @test !isempty(results["eigenvalues"])
    @test all(isfinite, Float64.(results["eigenvalues"]))
    @test _relative_symmetry_error(results["K"]) < 1e-12
    @test nnz(results["Kg"]) > 0

    kg_diag = _kg_timing_diagnostics(results)
    @test kg_diag["kg_timings"]["tacs_native_kg_elements"] == 5

    buckling_gradient = OpenJFEM.buckling_load_factor_thickness_gradient(results; mode=1)
    buckling_values = _check_pid_gradient_payload(
        buckling_gradient;
        expected_backend="tacs_formulation_rayleigh_ad_kg_directional_fd",
    )
    @test sort!(collect(keys(buckling_gradient["directional_steps"]))) == ["1", "2"]
    return results, buckling_values
end

function _check_sol200(deck::AbstractString)
    model = OpenJFEM.bdf_to_model(deck)
    _check_model_scope(model)
    results = OpenJFEM.solve_model(model)
    _check_forced_metadata(results, 200)
    @test results["analysis_type"] == "SOL200_LITE_OPTIMIZATION"
    @test results["route_summary"]["translated_objective"] == "min_compliance"
    @test results["route_summary"]["forward_sol_type"] == 101
    @test results["forward_results"]["backend"] == "tacs_formulation"
    @test results["forward_results"]["formulation"]["shell"] == TACS_SHELL_FORMULATION

    opt = results["optimization"]
    @test opt["design_variable_count"] == 2
    @test haskey(opt["initial_design_variables"], "TLEFT")
    @test haskey(opt["initial_design_variables"], "TRIGHT")
    @test haskey(opt["design_variables"], "TLEFT")
    @test haskey(opt["design_variables"], "TRIGHT")
    @test length(opt["group_metadata"]) == 2
    @test length(opt["iterations"]) == 1

    iter = opt["iterations"][1]
    @test isfinite(Float64(iter["objective"]))
    @test isfinite(Float64(iter["gradient_norm"]))
    @test Float64(iter["gradient_norm"]) > 0.0
    @test iter["solver_diagnostics"]["backend"] == "tacs_formulation"
    @test iter["solver_diagnostics"]["formulation"]["thickness_derivative"] == "element_ad"
    return results
end

function main()
    tmp = mktempdir(; prefix="openjfem_cquadr_multiprop_tacs_")
    sol101_deck = _write_sol101_deck(joinpath(tmp, "cquadr_multiprop_sol101.bdf"))
    sol105_deck = _write_sol105_deck(joinpath(tmp, "cquadr_multiprop_sol105.bdf"))
    sol200_deck = _write_sol200_deck(joinpath(tmp, "cquadr_multiprop_sol200.bdf"))

    sol101_results, compliance_values, displacement_values = _check_sol101(sol101_deck)
    sol105_results, buckling_values = _check_sol105(sol105_deck)
    sol200_results = _check_sol200(sol200_deck)

    println("CQUADR multi-property TACS route check passed")
    println("  SOL101 deck         = ", abspath(sol101_deck))
    println("  SOL101 ndof         = ", sol101_results["ndof"])
    println("  dCompliance/dt PID1 = ", compliance_values[1])
    println("  dCompliance/dt PID2 = ", compliance_values[2])
    println("  dU9z/dt PID1        = ", displacement_values[1])
    println("  dU9z/dt PID2        = ", displacement_values[2])
    println("  SOL105 deck         = ", abspath(sol105_deck))
    println("  SOL105 first eig    = ", Float64(sol105_results["eigenvalues"][1]))
    println("  dLambda/dt PID1     = ", buckling_values[1])
    println("  dLambda/dt PID2     = ", buckling_values[2])
    println("  SOL200 deck         = ", abspath(sol200_deck))
    println("  SOL200 objective    = ", Float64(sol200_results["optimization"]["history"][1]))
    return true
end

exit(main() ? 0 : 1)
