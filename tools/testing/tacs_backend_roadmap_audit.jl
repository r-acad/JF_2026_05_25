# Static audit for the documented TACS backend roadmap gates.
#
# This is intentionally lightweight: it checks that the public guard scripts,
# backend hooks, and opt-in/default metadata needed by the roadmap are present.
# The referenced guards still need to be run for numerical evidence.
#
# Usage:
#   julia --project=. tools/testing/tacs_backend_roadmap_audit.jl

using Test

repo_root = normpath(joinpath(@__DIR__, "..", ".."))
pushfirst!(LOAD_PATH, repo_root)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"
using OpenJFEM

const REQUIRED_GUARDS = Dict(
    "phase0_default_backend" => "backend_default_check.jl",
    "phase0_parity_solve_smoke" => "backend_parity_smoke_check.jl",
    "phase0_manifest_backend" => "backend_manifest_check.jl",
    "phase1_sol101_derivatives" => "tacs_sol101_fd_check.jl",
    "phase2_sol103_modes" => "tacs_sol103_route_check.jl",
    "phase2_sol105_buckling" => "tacs_sol105_route_check.jl",
    "phase2_sol106_nonlinear" => "tacs_sol106_route_check.jl",
    "phase3_sol200_tacs_routes" => "tacs_sol200_route_check.jl",
    "phase3_sol200_shared_backend" => "backend_sol200_shared_route_check.jl",
    "cquadr_forced_tacs_route" => "cquadr_tacs_forced_route_check.jl",
    "cquadr_expanded_tacs_routes" => "cquadr_tacs_expanded_route_check.jl",
    "cquadr_sol106_tacs_route" => "cquadr_tacs_sol106_route_check.jl",
    "cquadr_mixed_shell_tacs_route" => "cquadr_tacs_mixed_shell_route_check.jl",
    "cquadr_multiproperty_tacs_route" => "cquadr_tacs_multiproperty_route_check.jl",
)

function _read(path)
    return read(path, String)
end

function _require_source_marker(path::AbstractString, marker::AbstractString)
    text = _read(path)
    @test occursin(marker, text)
end

function main()
    delete!(ENV, "JFEM_BACKEND")
    parity = OpenJFEM.backend_metadata(OpenJFEM.backend_from_model(Dict{String,Any}()))
    tacs = OpenJFEM.backend_metadata(OpenJFEM.backend_from_name("tacs_formulation"))

    @test parity["backend"] == "nastran_parity"
    @test parity["formulation"]["shell"] == "existing_calibrated_jfem"
    @test tacs["backend"] == "tacs_formulation"
    @test tacs["formulation"]["shell"] == "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106"
    @test tacs["formulation"]["constitutive"] == "mat1_pshell_pcomp_clt"
    @test tacs["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test tacs["formulation"]["nonlinear_state"] == "backend_sol106_state_callback"

    for (_, file) in REQUIRED_GUARDS
        @test isfile(joinpath(repo_root, "tools", "testing", file))
    end

    backend_interface = joinpath(repo_root, "src", "backend", "BackendInterface.jl")
    tacs_sol101 = joinpath(repo_root, "src", "backend", "tacs_formulation", "sol101.jl")
    solver = joinpath(repo_root, "src", "JFEMSolver.jl")
    manifest_core = joinpath(repo_root, "tools", "manifest_batch_core.jl")
    python_client = joinpath(repo_root, "python_client", "jfem_client.py")

    _require_source_marker(backend_interface, "static_compliance_design_gradient")
    _require_source_marker(backend_interface, "static_displacement_design_gradient")
    _require_source_marker(backend_interface, "static_ks_von_mises_design_gradient")
    _require_source_marker(backend_interface, "buckling_load_factor_thickness_gradient")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol101")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol103")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol105")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol106")
    _require_source_marker(tacs_sol101, "_tacs_evaluate_sol106_formal_nonlinear_state")
    _require_source_marker(tacs_sol101, "CQUAD4/CQUADR/CTRIA3")
    _require_source_marker(solver, "_solve_sol200_lite")
    _require_source_marker(solver, "_model_has_cquadr_shells")
    _require_source_marker(solver, "backend_forced_by")
    _require_source_marker(solver, "_solve_sol200_lite_pcomp_ply_optimization")
    _require_source_marker(solver, "_solve_sol200_lite_material_optimization")
    _require_source_marker(solver, "_solve_sol200_lite_stress_response")
    _require_source_marker(solver, "material_E1")
    _require_source_marker(solver, "material_E2")
    _require_source_marker(solver, "material_G12")
    _require_source_marker(solver, "material_NU12")
    _require_source_marker(tacs_sol101, "_tacs_refresh_pcomp_clt_for_material!")
    _require_source_marker(tacs_sol101, "material_G12")
    _require_source_marker(manifest_core, "JFEM_BACKEND")
    _require_source_marker(python_client, "backend: Optional[str]")

    println("JFEM TACS backend roadmap static audit passed")
    for (gate, file) in sort(collect(REQUIRED_GUARDS); by=first)
        println("  ", gate, " => tools/testing/", file)
    end
    return true
end

exit(main() ? 0 : 1)
