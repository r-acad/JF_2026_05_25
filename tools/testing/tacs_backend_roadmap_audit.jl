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
    "clustered_eigen_sensitivity" => "tacs_cluster_eigen_sensitivity_check.jl",
    "phase0_default_backend" => "backend_default_check.jl",
    "phase0_parity_solve_smoke" => "backend_parity_smoke_check.jl",
    "phase0_manifest_backend" => "backend_manifest_check.jl",
    "phase1_sol101_derivatives" => "tacs_sol101_fd_check.jl",
    "phase1_sol101_line_sensitivities" => "tacs_sol101_line_sensitivity_check.jl",
    "phase1_sol101_rod_route" => "tacs_sol101_rod_route_check.jl",
    "phase1_sol101_beam_route" => "tacs_sol101_beam_route_check.jl",
    "phase1_sol101_beam_pload1_route" => "tacs_sol101_beam_pload1_route_check.jl",
    "phase1_sol101_beam_offset_release_route" => "tacs_sol101_beam_offset_release_route_check.jl",
    "phase1_sol101_beam_sizing_sensitivities" => "tacs_sol101_beam_sizing_sensitivity_check.jl",
    "phase1_sol101_beam_stress_recovery" => "tacs_sol101_beam_stress_recovery_check.jl",
    "phase1_sol101_beam_stress_sensitivities" => "tacs_sol101_beam_stress_sensitivity_check.jl",
    "phase1_sol101_rod_stress_recovery" => "tacs_sol101_rod_stress_recovery_check.jl",
    "phase1_sol101_spring_route" => "tacs_sol101_spring_route_check.jl",
    "phase2_sol103_conm1_modal_route" => "tacs_sol103_conm1_modal_route_check.jl",
    "phase2_sol103_point_inertia_modal" => "tacs_sol103_point_inertia_modal_check.jl",
    "phase2_sol103_spring_modal_route" => "tacs_sol103_spring_modal_route_check.jl",
    "phase2_rod_geometric_stiffness_operator" => "tacs_rod_geometric_stiffness_operator_check.jl",
    "phase2_sol105_mixed_rod_route" => "tacs_sol105_mixed_rod_route_check.jl",
    "phase2_sol105_line_sensitivities" => "tacs_sol105_line_sensitivity_check.jl",
    "phase2_sol103_rod_modal_route" => "tacs_sol103_rod_modal_route_check.jl",
    "phase2_sol103_beam_modal_route" => "tacs_sol103_beam_modal_route_check.jl",
    "phase2_sol103_beam_offset_release_modal_route" => "tacs_sol103_beam_offset_release_modal_route_check.jl",
    "phase2_sol103_beam_modal_sensitivities" => "tacs_sol103_beam_modal_sensitivity_check.jl",
    "phase2_sol103_beam_sizing_sensitivities" => "tacs_sol103_beam_sizing_sensitivity_check.jl",
    "phase2_sol101_sol103_beam_shape_sensitivities" => "tacs_sol101_sol103_beam_shape_sensitivity_check.jl",
    "phase2_sol105_beam_shape_sensitivities" => "tacs_sol105_beam_shape_sensitivity_check.jl",
    "phase2_sol105_beam_route_sensitivities" => "tacs_sol105_beam_route_sensitivity_check.jl",
    "phase2_sol105_beam_offset_release_buckling_route" => "tacs_sol105_beam_offset_release_buckling_route_check.jl",
    "phase2_sol103_rod_modal_sensitivities" => "tacs_sol103_rod_modal_sensitivity_check.jl",
    "phase1_sol101_gravity_load_sensitivities" => "tacs_sol101_gravity_load_sensitivity_check.jl",
    "phase1_sol101_load_sensitivities" => "tacs_sol101_load_sensitivity_check.jl",
    "phase1_ks_displacement_response" => "tacs_ks_displacement_response_check.jl",
    "phase3_sol200_ks_displacement_routes" => "tacs_sol200_ks_displacement_route_check.jl",
    "phase1_pshell_mat2_constitutive" => "tacs_pshell_mat2_route_check.jl",
    "phase1_pshell_mat8_constitutive" => "tacs_pshell_mat8_route_check.jl",
    "phase2_pshell_mat2_mat8_eigen_routes" => "tacs_pshell_mat2_mat8_eigen_route_check.jl",
    "phase2_grouped_eigen_design_sensitivities" => "tacs_grouped_eigen_design_sensitivity_check.jl",
    "phase2_grouped_mat2_mat8_eigen_sensitivities" => "tacs_grouped_mat2_mat8_eigen_sensitivity_check.jl",
    "phase2_mode_tracking_cluster_policy" => "tacs_mode_tracking_policy_check.jl",
    "phase2_mode_continuation" => "tacs_mode_continuation_check.jl",
    "phase2_pcomp_eigen_ply_sensitivities" => "tacs_pcomp_eigen_ply_sensitivity_check.jl",
    "phase2_pcomp_stress_ks_ply_sensitivities" => "tacs_pcomp_stress_ks_ply_sensitivity_check.jl",
    "phase2_pcomp_modified_tsai_wu_failure_sensitivities" => "tacs_pcomp_modified_tsai_wu_failure_sensitivity_check.jl",
    "phase2_pcomp_failure_strength_sensitivities" => "tacs_pcomp_failure_strength_sensitivity_check.jl",
    "phase2_pcomp_tsai_hill_failure_sensitivities" => "tacs_pcomp_tsai_hill_failure_sensitivity_check.jl",
    "phase2_pcomp_tsai_wu_failure_sensitivities" => "tacs_pcomp_tsai_wu_failure_sensitivity_check.jl",
    "phase1_sol101_rforce_coordinate_sensitivities" => "tacs_sol101_rforce_coordinate_sensitivity_check.jl",
    "phase1_sol101_rforce_load_sensitivities" => "tacs_sol101_rforce_load_sensitivity_check.jl",
    "phase1_sol101_line_thermal_load_sensitivities" => "tacs_sol101_line_thermal_load_sensitivity_check.jl",
    "phase1_structural_mass_derivatives" => "tacs_structural_mass_fd_check.jl",
    "phase2_sol103_modes" => "tacs_sol103_route_check.jl",
    "phase2_sol105_buckling" => "tacs_sol105_route_check.jl",
    "phase2_sol105_gravity_preload_sensitivities" => "tacs_sol105_gravity_preload_sensitivity_check.jl",
    "phase2_sol105_rforce_preload_sensitivities" => "tacs_sol105_rforce_preload_sensitivity_check.jl",
    "phase2_sol105_preload_load_sensitivities" => "tacs_sol105_preload_load_sensitivity_check.jl",
    "phase3_sol200_buckling_ks_routes" => "tacs_sol200_buckling_ks_route_check.jl",
    "phase2_sol106_nonlinear" => "tacs_sol106_route_check.jl",
    "phase3_sol200_tacs_routes" => "tacs_sol200_route_check.jl",
    "phase3_sol200_shared_backend" => "backend_sol200_shared_route_check.jl",
    "cquadr_forced_tacs_route" => "cquadr_tacs_forced_route_check.jl",
    "cquadr_expanded_tacs_routes" => "cquadr_tacs_expanded_route_check.jl",
    "cquadr_sol106_tacs_route" => "cquadr_tacs_sol106_route_check.jl",
    "cquadr_mixed_shell_tacs_route" => "cquadr_tacs_mixed_shell_route_check.jl",
    "cquadr_multiproperty_tacs_route" => "cquadr_tacs_multiproperty_route_check.jl",
    "core_capability_matrix" => "tacs_core_capability_matrix_guard.jl",
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
    @test tacs["formulation"]["rod"] == "residual_first_crod_conrod_sol101_sol103"
    @test tacs["formulation"]["beam"] == "residual_first_cbar_cbeam_sol101_sol103_sol105"
    @test tacs["formulation"]["spring"] == "residual_first_celas1_celas2_cbush_sol101_sol103"
    @test tacs["formulation"]["constitutive"] == "mat1_mat2_mat8_pshell_pcomp_clt"
    @test tacs["formulation"]["geometric_stiffness"] == "native_residual_first_quad4_cquadr_tria3"
    @test tacs["formulation"]["rod_geometric_stiffness"] == "native_residual_first_crod_conrod_operator"
    @test tacs["formulation"]["beam_geometric_stiffness"] == "native_residual_first_cbar_cbeam_operator"
    @test tacs["formulation"]["nonlinear_state"] == "backend_sol106_state_callback"

    for (_, file) in REQUIRED_GUARDS
        @test isfile(joinpath(repo_root, "tools", "testing", file))
    end

    backend_interface = joinpath(repo_root, "src", "backend", "BackendInterface.jl")
    openjfem_module = joinpath(repo_root, "src", "OpenJFEM.jl")
    model_builder = joinpath(repo_root, "src", "ModelBuilder.jl")
    tacs_core = joinpath(repo_root, "src", "backend", "tacs_formulation", "core.jl")
    tacs_sol101 = joinpath(repo_root, "src", "backend", "tacs_formulation", "sol101.jl")
    extract_elements = joinpath(repo_root, "src", "parsing", "extract_elements.jl")
    extract_geometry = joinpath(repo_root, "src", "parsing", "extract_geometry.jl")
    solve_case = joinpath(repo_root, "src", "solver", "solve_case.jl")
    solver_loads = joinpath(repo_root, "src", "solver", "loads.jl")
    stress_recovery = joinpath(repo_root, "src", "solver", "stress_recovery.jl")
    solver_adjoint = joinpath(repo_root, "src", "solver", "adjoint.jl")
    solver = joinpath(repo_root, "src", "JFEMSolver.jl")
    optimize_thickness = joinpath(repo_root, "src", "solver", "optimize_thickness.jl")
    manifest_core = joinpath(repo_root, "tools", "manifest_batch_core.jl")
    python_client = joinpath(repo_root, "python_client", "jfem_client.py")
    capability_matrix = joinpath(repo_root, "Reference_documentation", "tacs_core_capability_matrix.md")

    _require_source_marker(backend_interface, "static_compliance_design_gradient")
    _require_source_marker(backend_interface, "static_displacement_design_gradient")
    _require_source_marker(backend_interface, "static_ks_displacement_design_gradient")
    _require_source_marker(backend_interface, "static_ks_von_mises_design_gradient")
    _require_source_marker(backend_interface, "static_ks_ply_failure_design_gradient")
    _require_source_marker(backend_interface, "structural_mass_design_gradient")
    _require_source_marker(backend_interface, "modal_eigenvalue_design_gradient")
    _require_source_marker(backend_interface, "buckling_load_factor_thickness_gradient")
    _require_source_marker(backend_interface, "buckling_load_factor_design_gradient")
    _require_source_marker(backend_interface, "buckling_load_factor_ks_design_gradient")
    _require_source_marker(openjfem_module, "eigen_mode_tracking_reference")
    _require_source_marker(openjfem_module, "eigen_mode_continuation_update")
    _require_source_marker(openjfem_module, "static_ks_ply_failure_design_gradient")
    _require_source_marker(backend_interface, "core_contracts")
    _require_source_marker(model_builder, "KSDISP")
    _require_source_marker(model_builder, "ks_displacement")
    _require_source_marker(tacs_core, "TACSShellElementKernel")
    _require_source_marker(tacs_core, "TACSRodElementKernel")
    _require_source_marker(tacs_core, "_tacs_rod_element_kernel")
    _require_source_marker(tacs_core, "rod_crod")
    _require_source_marker(tacs_core, "rod_conrod")
    _require_source_marker(tacs_core, "TACSBeamElementKernel")
    _require_source_marker(tacs_core, "_tacs_beam_element_kernel")
    _require_source_marker(tacs_core, "beam_cbar")
    _require_source_marker(tacs_core, "beam_cbeam")
    _require_source_marker(tacs_core, "beam_pbar_mat1")
    _require_source_marker(tacs_core, "TACSSpringElementKernel")
    _require_source_marker(tacs_core, "_tacs_spring_element_kernel")
    _require_source_marker(tacs_core, "spring_celas1")
    _require_source_marker(tacs_core, "spring_celas2")
    _require_source_marker(tacs_core, "spring_cbush")
    _require_source_marker(tacs_core, "spring_damping_orientation_and_broader_mass_sensitivities")
    _require_source_marker(tacs_core, "TACSConstitutiveKernel")
    _require_source_marker(tacs_core, "pshell_mat2")
    _require_source_marker(tacs_core, "pshell_mat8")
    _require_source_marker(tacs_core, "TACSResponseContract")
    _require_source_marker(tacs_core, "TACSResponseFunction")
    _require_source_marker(tacs_core, "ks_displacement")
    _require_source_marker(tacs_core, "ks_ply_failure")
    _require_source_marker(tacs_core, "TACSSensitivityContract")
    _require_source_marker(tacs_core, "rod_area")
    _require_source_marker(tacs_core, "beam_area")
    _require_source_marker(tacs_core, "beam_i2")
    _require_source_marker(tacs_core, "TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE")
    _require_source_marker(tacs_core, "spring_stiffness")
    _require_source_marker(tacs_core, "bush_stiffness")
    _require_source_marker(tacs_core, "point_inertia")
    _require_source_marker(tacs_core, "TACSModalResponseContext")
    _require_source_marker(tacs_core, "_tacs_eigenvalue_cluster_modes")
    _require_source_marker(tacs_core, "_tacs_select_cluster_derivative")
    _require_source_marker(tacs_core, "_tacs_resolve_tracked_mode")
    _require_source_marker(tacs_core, "_tacs_modal_cluster_projected_derivatives")
    _require_source_marker(tacs_core, "_tacs_buckling_cluster_projected_derivatives")
    _require_source_marker(tacs_core, "clustered_eigenvalue_projected_derivative")
    _require_source_marker(tacs_core, "eigenvalue_cluster_policy")
    _require_source_marker(tacs_core, "mac_mode_tracking")
    _require_source_marker(tacs_core, "previous_solve_mac_mode_continuation")
    _require_source_marker(tacs_core, "eigen_mode_tracking_reference")
    _require_source_marker(tacs_core, "eigen_mode_continuation_update")
    _require_source_marker(tacs_core, "_tacs_static_response_context")
    _require_source_marker(tacs_core, "_tacs_static_adjoint")
    _require_source_marker(tacs_core, "_tacs_shell_element_context")
    _require_source_marker(tacs_core, "static_shell_coordinate_sensitivity")
    _require_source_marker(tacs_core, "static_design_dependent_load_sensitivity")
    _require_source_marker(tacs_core, "static_material_density_load_sensitivity")
    _require_source_marker(tacs_core, "static_line_thermal_load_sensitivity")
    _require_source_marker(tacs_core, "static_load_design_derivative")
    _require_source_marker(tacs_core, "sol105_preload_design_dependent_load_sensitivity")
    _require_source_marker(tacs_core, "static_ks_von_mises_coordinate_sensitivity")
    _require_source_marker(tacs_core, "static_ks_von_mises_beam_design_tangent")
    _require_source_marker(tacs_core, "static_ks_ply_failure_design_tangent")
    _require_source_marker(tacs_core, "adjoint_design_tangent_explicit_failure")
    _require_source_marker(tacs_core, "explicit_failure_strength")
    _require_source_marker(tacs_core, "structural_mass_coordinate_sensitivity")
    _require_source_marker(tacs_core, "mass_coordinate_fd")
    _require_source_marker(tacs_core, "modal_eigenvalue_shell_coordinate")
    _require_source_marker(tacs_core, "modal_eigenvalue_shell_design_tangent")
    _require_source_marker(tacs_core, "modal_eigenvalue_clustered_subspace")
    _require_source_marker(tacs_core, "modal_mass_design_fd")
    _require_source_marker(tacs_core, "buckling_load_factor_shell_coordinate")
    _require_source_marker(tacs_core, "buckling_load_factor_shell_design_tangent")
    _require_source_marker(tacs_core, "response_family in buckling_families && design_family == :rod_area")
    _require_source_marker(tacs_core, "response_family in buckling_families && design_family in beam_sizing_designs")
    _require_source_marker(tacs_core, "buckling_load_factor_inertial_preload_density")
    _require_source_marker(tacs_core, "buckling_load_factor_clustered_subspace")
    _require_source_marker(tacs_core, "buckling_ks_load_factor_shell_design_tangent")
    _require_source_marker(tacs_core, "adjoint_coordinate_fd")
    _require_source_marker(tacs_core, "adjoint_coordinate_fd_explicit_stress")
    _require_source_marker(tacs_core, "rayleigh_coordinate_kg_directional_fd")
    _require_source_marker(tacs_core, "rayleigh_design_kg_directional_fd")
    _require_source_marker(tacs_core, "rayleigh_load_kg_directional_fd")
    _require_source_marker(tacs_core, "modal_coordinate_fd")
    _require_source_marker(tacs_core, "modal_design_tangent_fd")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol101")
    _require_source_marker(tacs_sol101, "_tacs_validate_rod_slice")
    _require_source_marker(tacs_sol101, "_tacs_rod_residual_tangent")
    _require_source_marker(tacs_sol101, "_tacs_rod_local_stiffness")
    _require_source_marker(tacs_sol101, "_tacs_validate_beam_slice")
    _require_source_marker(tacs_sol101, "_tacs_beam_frame_and_transform")
    _require_source_marker(tacs_sol101, "_tacs_beam_residual_tangent")
    _require_source_marker(tacs_sol101, "_tacs_beam_mass_tangent")
    _require_source_marker(tacs_sol101, "_tacs_assemble_beam_mass")
    _require_source_marker(tacs_sol101, "tacs_lumped_cbar_cbeam_mass")
    _require_source_marker(tacs_sol101, "_tacs_beam_geometric_stiffness_operator")
    _require_source_marker(tacs_sol101, "tacs_native_kg_beam_elements")
    _require_source_marker(tacs_sol101, "tacs_native_kg_avg_beam_axial_force")
    _require_source_marker(tacs_sol101, "beam_geometric_stiffness")
    _require_source_marker(tacs_sol101, "allow_offsets_releases")
    _require_source_marker(tacs_sol101, "default_beam_offsets_releases")
    _require_source_marker(tacs_sol101, "allow_beam_offsets_releases")
    _require_source_marker(tacs_sol101, "Solver.bar_offsets_and_endpoints")
    _require_source_marker(tacs_sol101, "Solver.apply_bar_pin_flags!")
    _require_source_marker(extract_geometry, "\"PA\"=>pa, \"PB\"=>pb, \"WA\"=>wa, \"WB\"=>wb, \"TYPE\"=>\"CBEAM\"")
    _require_source_marker(solver_loads, "_beam_pload1_equivalent_local_load_vector")
    _require_source_marker(solver_loads, "_beam_pload1_local_load_vector_for_sid")
    _require_source_marker(solver_loads, "_line_rforce_consistent_endpoint_forces")
    _require_source_marker(solver_loads, "_add_line_rforce!")
    _require_source_marker(solver_loads, "resolve_thermal_loads")
    _require_source_marker(stress_recovery, "active_load_id")
    _require_source_marker(stress_recovery, "fixed_end_load")
    _require_source_marker(stress_recovery, "apply_bar_pin_flags!")
    _require_source_marker(solver_adjoint, "_beam_stress_sample_value_and_cache")
    _require_source_marker(solver_adjoint, "_beam_response_explicit_fd")
    _require_source_marker(solver_adjoint, "_beam_design_field_from_dv")
    _require_source_marker(tacs_sol101, "allow_beams=allow_beam_slice")
    _require_source_marker(tacs_sol101, "_tacs_validate_spring_slice")
    _require_source_marker(tacs_sol101, "_tacs_validate_modal_mass_slice")
    _require_source_marker(tacs_sol101, "allow_conm1")
    _require_source_marker(tacs_sol101, "_tacs_spring_residual_tangent")
    _require_source_marker(tacs_sol101, "_tacs_bush_residual_tangent")
    _require_source_marker(tacs_sol101, "_tacs_line_static_stiffness_design_types")
    _require_source_marker(tacs_sol101, "_tacs_beam_sizing_design_types")
    _require_source_marker(tacs_sol101, "_tacs_beam_design_values")
    _require_source_marker(tacs_sol101, "_tacs_model_with_beam_property_delta")
    _require_source_marker(tacs_sol101, "_tacs_model_with_rod_area_delta")
    _require_source_marker(tacs_sol101, "_tacs_model_with_spring_stiffness_delta")
    _require_source_marker(tacs_sol101, "_tacs_model_with_bush_stiffness_delta")
    _require_source_marker(tacs_sol101, "_tacs_conm1_point_mass_components")
    _require_source_marker(tacs_sol101, "_tacs_conm1_point_mass_terms")
    _require_source_marker(tacs_sol101, "component_pairs")
    _require_source_marker(tacs_sol101, "_tacs_conm2_point_inertia_terms")
    _require_source_marker(tacs_sol101, "\"term\"")
    _require_source_marker(tacs_sol101, "_tacs_point_mass_values")
    _require_source_marker(tacs_sol101, "_tacs_point_inertia_values")
    _require_source_marker(tacs_sol101, "_tacs_model_with_point_mass_delta")
    _require_source_marker(tacs_sol101, "_tacs_model_with_point_inertia_delta")
    _require_source_marker(tacs_sol101, "_tacs_assemble_sol101_full_stiffness_design_derivative")
    _require_source_marker(tacs_sol101, "_tacs_static_load_design_dependent")
    _require_source_marker(tacs_sol101, "_tacs_rod_mass_tangent")
    _require_source_marker(tacs_sol101, "_tacs_rod_area_stiffness_derivative_tangent")
    _require_source_marker(tacs_sol101, "_tacs_assemble_rod_area_stiffness_derivative")
    _require_source_marker(tacs_sol101, "_tacs_rod_area_mass_derivative_tangent")
    _require_source_marker(tacs_sol101, "_tacs_assemble_rod_area_mass_derivative")
    _require_source_marker(tacs_sol101, "_tacs_rod_geometric_stiffness_operator")
    _require_source_marker(tacs_sol101, "tacs_native_kg_rod_elements")
    _require_source_marker(tacs_sol101, "_tacs_sol103_modal_mass_builder")
    _require_source_marker(tacs_sol101, "_tacs_sol103_modal_mass_route_label")
    _require_source_marker(tacs_sol101, "_tacs_sol103_linear_stiffness_route_label")
    _require_source_marker(tacs_sol101, "shared_jfem_modal_point_mass")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_rod_value")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_rod_area_derivative")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_beam_value")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_beam_area_derivative")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_point_mass_value")
    _require_source_marker(tacs_sol101, "_tacs_structural_mass_point_mass_derivative")
    _require_source_marker(extract_elements, "\"M_FULL\"")
    _require_source_marker(solve_case, "raw_full = get(cm, \"M_FULL\", nothing)")
    _require_source_marker(tacs_sol101, "_tacs_mat8_pshell_constitutive")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol103")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol105")
    _require_source_marker(tacs_sol101, "_solve_tacs_sol106")
    _require_source_marker(tacs_sol101, "_tacs_evaluate_sol106_formal_nonlinear_state")
    _require_source_marker(tacs_sol101, "_tacs_assemble_sol101_coordinate_derivative")
    _require_source_marker(tacs_sol101, "allow_beams=allow_beam_slice")
    _require_source_marker(tacs_sol101, "_tacs_assemble_sol101_load_design_derivative")
    _require_source_marker(tacs_sol101, "_tacs_static_load_vector")
    _require_source_marker(tacs_sol101, "load_derivative_norm")
    _require_source_marker(tacs_sol101, "tacs_formulation_load_fd_adjoint")
    _require_source_marker(tacs_sol101, "tacs_formulation_coordinate_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_stress_coordinate_fd_adjoint")
    _require_source_marker(tacs_sol101, "_tacs_sol105_geometric_stiffness_coordinate_derivative")
    _require_source_marker(tacs_sol101, "_tacs_sol105_geometric_stiffness_design_derivative")
    _require_source_marker(tacs_sol101, "_tacs_sol105_static_load_design_derivative")
    _require_source_marker(tacs_sol101, "_tacs_sol105_static_subcase_sid")
    _require_source_marker(tacs_sol101, "_tacs_assemble_sol103_mass_design_derivative")
    _require_source_marker(tacs_sol101, "_tacs_sol103_analysis_modes")
    _require_source_marker(tacs_sol101, "cluster_gradient_eigenvalues")
    _require_source_marker(tacs_sol101, "structural_mass_design_gradient(::TACSFormulationBackend")
    _require_source_marker(tacs_sol101, "_tacs_model_with_design_delta")
    _require_source_marker(tacs_sol101, "_tacs_material_group_design_step")
    _require_source_marker(tacs_sol101, "_tacs_model_with_material_fields_delta")
    _require_source_marker(tacs_sol101, "material_ALPHA")
    _require_source_marker(tacs_sol101, "material_TREF")
    _require_source_marker(tacs_sol101, "static_ks_displacement_design_gradient(::TACSFormulationBackend")
    _require_source_marker(tacs_sol101, "static_ks_ply_failure_design_gradient(::TACSFormulationBackend")
    _require_source_marker(tacs_sol101, "function modal_eigenvalue_design_gradient(")
    _require_source_marker(tacs_sol101, "function buckling_load_factor_design_gradient(")
    _require_source_marker(tacs_sol101, "function buckling_load_factor_ks_design_gradient(")
    _require_source_marker(tacs_sol101, "mode_tracking")
    _require_source_marker(tacs_sol101, "cluster_policy_projected_derivative")
    _require_source_marker(tacs_sol101, "tacs_formulation_modal_coordinate_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_modal_design_tangent_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_modal_mass_design_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_mass_coordinate_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_mass_coefficient")
    _require_source_marker(tacs_sol101, "tacs_formulation_ks_displacement_design_tangent_adjoint")
    _require_source_marker(tacs_sol101, "tacs_formulation_ply_failure_adjoint_design_tangent")
    _require_source_marker(tacs_sol101, "tacs_formulation_rayleigh_coordinate_kg_directional_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_rayleigh_design_kg_directional_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_rayleigh_load_kg_directional_fd")
    _require_source_marker(tacs_sol101, "tacs_formulation_buckling_ks_weighted_rayleigh")
    _require_source_marker(tacs_sol101, "CQUAD4/CQUADR/CTRIA3")
    _require_source_marker(solver, "_solve_sol200_lite")
    _require_source_marker(solver, "_model_has_cquadr_shells")
    _require_source_marker(solver, "backend_forced_by")
    _require_source_marker(solver, "_solve_sol200_lite_pcomp_ply_optimization")
    _require_source_marker(solver, "_solve_sol200_lite_material_optimization")
    _require_source_marker(solver, "_solve_sol200_lite_stress_response")
    _require_source_marker(solver, "ks_displacement")
    _require_source_marker(solver, "buckling_aggregation")
    _require_source_marker(solver, "buckling_ks_rho")
    _require_source_marker(solver, "BUCKMODE")
    _require_source_marker(solver, "BUCKM")
    _require_source_marker(solver, "BUCKPOL")
    _require_source_marker(solver, "BUCKTRK")
    _require_source_marker(solver, "BUCKWIN")
    _require_source_marker(solver, "BUCKMAC")
    _require_source_marker(optimize_thickness, "_backend_buckling_load_factor_ks_design_gradient")
    _require_source_marker(optimize_thickness, "_backend_eigen_mode_continuation_update")
    _require_source_marker(optimize_thickness, "_backend_static_ks_displacement_design_gradient")
    _require_source_marker(optimize_thickness, "ks_displacement")
    _require_source_marker(optimize_thickness, "buckling_ks_rho")
    _require_source_marker(optimize_thickness, "buckling_ks_modes")
    _require_source_marker(optimize_thickness, "buckling_cluster_policy")
    _require_source_marker(optimize_thickness, "buckling_mode_tracking")
    _require_source_marker(solver, "material_E1")
    _require_source_marker(solver, "material_E2")
    _require_source_marker(solver, "material_G12")
    _require_source_marker(solver, "material_NU12")
    _require_source_marker(tacs_sol101, "_tacs_refresh_pcomp_clt_for_material!")
    _require_source_marker(tacs_sol101, "material_G11")
    _require_source_marker(tacs_sol101, "material_G12")
    _require_source_marker(tacs_sol101, "material_G33")
    _require_source_marker(solver_adjoint, "_pcomp_surface_ply")
    _require_source_marker(solver_adjoint, "_pcomp_von_mises_explicit_fd")
    _require_source_marker(solver_adjoint, "_ks_ply_failure_items")
    _require_source_marker(solver_adjoint, "_tsai_hill_failure_index")
    _require_source_marker(solver_adjoint, "_tsai_wu_failure_index")
    _require_source_marker(solver_adjoint, "_modified_tsai_wu_failure_index")
    _require_source_marker(solver_adjoint, "_pcomp_ply_failure_explicit_fd")
    _require_source_marker(solver_adjoint, "_failure_strength_explicit_fd")
    _require_source_marker(manifest_core, "JFEM_BACKEND")
    _require_source_marker(python_client, "backend: Optional[str]")
    _require_source_marker(capability_matrix, "CQUAD4, CQUADR, and CTRIA3")
    _require_source_marker(capability_matrix, "CROD and CONROD")
    _require_source_marker(capability_matrix, "CBAR and CBEAM")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM beam stiffness")
    _require_source_marker(capability_matrix, "SOL101 beam sizing sensitivities")
    _require_source_marker(capability_matrix, "SOL103 beam sizing sensitivities")
    _require_source_marker(capability_matrix, "SOL101/SOL103 CBAR/CBEAM beam shape sensitivities")
    _require_source_marker(capability_matrix, "SOL105 CBAR/CBEAM beam buckling")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM axial and bending stress recovery")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM KS von-Mises beam stress sensitivities")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM PLOAD1 beam loads")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM GRAV material-density load-only")
    _require_source_marker(capability_matrix, "closed-form cantilever gravity derivative")
    _require_source_marker(capability_matrix, "SOL101 CBAR/CBEAM RFORCE material-density load-only sensitivity")
    _require_source_marker(capability_matrix, "SOL101 CROD/CONROD RFORCE material-density load-only sensitivity")
    _require_source_marker(capability_matrix, "closed-form axial centrifugal response")
    _require_source_marker(capability_matrix, "TEMP(LOAD) axial thermal load sensitivities")
    _require_source_marker(capability_matrix, "MAT1 `material_E`, `material_ALPHA`, and `material_TREF`")
    _require_source_marker(capability_matrix, "closed-form axial thermal displacement")
    _require_source_marker(capability_matrix, "SOL101 rod stiffness")
    _require_source_marker(capability_matrix, "SOL103 rod modal")
    _require_source_marker(capability_matrix, "rod geometric-stiffness operator")
    _require_source_marker(capability_matrix, "CELAS1, CELAS2, and CBUSH")
    _require_source_marker(capability_matrix, "SOL101 line-element static response sensitivities")
    _require_source_marker(capability_matrix, "rod structural mass")
    _require_source_marker(capability_matrix, "rod stress recovery")
    _require_source_marker(capability_matrix, "mixed shell-plus-rod SOL105")
    _require_source_marker(capability_matrix, "SOL105 buckling line sensitivities")
    _require_source_marker(capability_matrix, "CONM1 full-matrix `point_mass` modal derivatives")
    _require_source_marker(capability_matrix, "point_inertia")
    _require_source_marker(capability_matrix, "dLambda/dI21")
    _require_source_marker(capability_matrix, "SOL 103 eigenvalue/frequency sensitivity")
    _require_source_marker(capability_matrix, "Coordinate/shape sensitivity")
    _require_source_marker(capability_matrix, "node-coordinate shape variables")
    _require_source_marker(capability_matrix, "explicit stress-geometry")
    _require_source_marker(capability_matrix, "Recommended Implementation Order")

    println("JFEM TACS backend roadmap static audit passed")
    for (gate, file) in sort(collect(REQUIRED_GUARDS); by=first)
        println("  ", gate, " => tools/testing/", file)
    end
    return true
end

exit(main() ? 0 : 1)
