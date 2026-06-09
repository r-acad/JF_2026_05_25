# Static guard for the public JFEM TACS core capability matrix.
#
# This does not prove numerical correctness. It keeps the public capability
# matrix tied to concrete backend hooks, fail-fast implementation markers, and
# known missing sensitivity classes so future work cannot silently drift.
#
# Usage:
#   julia --project=. tools/testing/tacs_core_capability_matrix_guard.jl

using Test

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

function _read_rel(parts...)
    return read(joinpath(REPO_ROOT, parts...), String)
end

function _require_marker(text::AbstractString, marker::AbstractString)
    @test occursin(marker, text)
end

function main()
    matrix_path = joinpath(REPO_ROOT, "Reference_documentation", "tacs_core_capability_matrix.md")
    backend_interface_path = joinpath(REPO_ROOT, "src", "backend", "BackendInterface.jl")
    model_builder_path = joinpath(REPO_ROOT, "src", "ModelBuilder.jl")
    solver_adjoint_path = joinpath(REPO_ROOT, "src", "solver", "adjoint.jl")
    solve_case_path = joinpath(REPO_ROOT, "src", "solver", "solve_case.jl")
    loads_path = joinpath(REPO_ROOT, "src", "solver", "loads.jl")
    stress_recovery_path = joinpath(REPO_ROOT, "src", "solver", "stress_recovery.jl")
    extract_elements_path = joinpath(REPO_ROOT, "src", "parsing", "extract_elements.jl")
    extract_geometry_path = joinpath(REPO_ROOT, "src", "parsing", "extract_geometry.jl")
    tacs_shell_path = joinpath(REPO_ROOT, "src", "backend", "tacs_formulation", "sol101.jl")
    tacs_core_path = joinpath(REPO_ROOT, "src", "backend", "tacs_formulation", "core.jl")
    solver_path = joinpath(REPO_ROOT, "src", "JFEMSolver.jl")
    optimize_path = joinpath(REPO_ROOT, "src", "solver", "optimize_thickness.jl")

    @test isfile(matrix_path)
    @test isfile(backend_interface_path)
    @test isfile(model_builder_path)
    @test isfile(solver_adjoint_path)
    @test isfile(solve_case_path)
    @test isfile(loads_path)
    @test isfile(stress_recovery_path)
    @test isfile(extract_elements_path)
    @test isfile(extract_geometry_path)
    @test isfile(tacs_core_path)
    @test isfile(tacs_shell_path)
    @test isfile(solver_path)
    @test isfile(optimize_path)

    matrix = read(matrix_path, String)
    backend_interface = read(backend_interface_path, String)
    model_builder = read(model_builder_path, String)
    solver_adjoint = read(solver_adjoint_path, String)
    solve_case = read(solve_case_path, String)
    loads = read(loads_path, String)
    stress_recovery = read(stress_recovery_path, String)
    extract_elements = read(extract_elements_path, String)
    extract_geometry = read(extract_geometry_path, String)
    tacs_core = read(tacs_core_path, String)
    tacs_shell = read(tacs_shell_path, String)
    solver = read(solver_path, String)
    optimize = read(optimize_path, String)

    for marker in (
        "This note tracks the JFEM-core work",
        "CQUAD4, CQUADR, and CTRIA3",
        "CROD and CONROD",
        "CBAR and CBEAM",
        "SOL101 CBAR/CBEAM beam stiffness",
        "SOL103 CBAR/CBEAM beam modal",
        "SOL103 CBAR/CBEAM modal offsets and pin releases",
        "SOL105 CBAR/CBEAM buckling offsets and pin releases",
        "SOL103 CBAR/CBEAM beam modal material sensitivities",
        "SOL101 beam sizing sensitivities",
        "CBAR/CBEAM `beam_I1`/`beam_I2`/`beam_J`",
        "SOL103 beam sizing sensitivities",
        "`beam_I1`, `beam_I2`, and `beam_area`",
        "SOL101/SOL103 CBAR/CBEAM beam shape sensitivities",
        "SOL105 CBAR/CBEAM buckling shape sensitivities",
        "closed-form reduced buckling pencil",
        "SOL105 CBAR/CBEAM beam buckling",
        "`beam_I1`/`beam_I2`/`beam_area`/`beam_J`",
        "SOL101 CBAR/CBEAM axial and bending stress recovery",
        "SOL101 CBAR/CBEAM KS von-Mises beam stress sensitivities",
        "constant-section `beam_I2` bending",
        "SOL101 CBAR/CBEAM PLOAD1 beam loads",
        "SOL101 CBAR/CBEAM GRAV/RFORCE",
        "closed-form cantilever gravity derivative",
        "SOL101 CBAR/CBEAM RFORCE material-density load-only sensitivity",
        "SOL101 CROD/CONROD RFORCE material-density load-only sensitivity",
        "closed-form axial centrifugal response",
        "TEMP(LOAD) axial thermal load sensitivities",
        "MAT1 `material_E`, `material_ALPHA`, and `material_TREF`",
        "closed-form axial thermal displacement",
        "SOL101 CBAR/CBEAM beam offsets and pin releases",
        "parser-backed CBAR/CBEAM continuation fields",
        "released-end moments",
        "fixed-end-corrected recovered root forces/moments",
        "SOL101 rod stiffness",
        "SOL103 rod modal",
        "rod geometric-stiffness operator",
        "CELAS1, CELAS2, and CBUSH",
        "SOL103 spring-plus-point/scalar-mass modal",
        "CONM1 full-matrix modal mass",
        "CONM1 full-matrix `point_mass` modal derivatives",
        "M12/M21",
        "dLambda/dM12",
        "dLambda/dm = -k/m^2",
        "dMass/dpoint_mass = 1",
        "point_inertia",
        "dLambda/dI21",
        "SOL101 line-element static response sensitivities",
        "SOL103 rod modal sensitivities",
        "rod structural mass",
        "rod stress recovery",
        "mixed shell-plus-rod SOL105",
        "SOL105 buckling line sensitivities",
        "Unsupported element rejection",
        "PSHELL / MAT1",
        "PSHELL / MAT2",
        "PSHELL / MAT8",
        "SOL103/SOL105 first-eigenvalue material derivative guards",
        "PCOMP_CLT",
        "PCOMP ply thickness/angle eigen sensitivities",
        "PCOMP ply KS von-Mises sensitivities",
        "PCOMP Tsai-Hill, classic Tsai-Wu, and modified Tsai-Wu strength-ratio",
        "MAT8 strength-field sensitivities",
        "modified Tsai-Wu strength-ratio",
        "SOL 103 eigenvalue/frequency sensitivity",
        "all six MAT2",
        "E1/E2/G12/NU12",
        "Direct PSHELL/MAT2 `G11/G12/G13/G22/G23/G33` and PSHELL/MAT8 `E1/E2/G12/NU12`",
        "Grouped shell-thickness and grouped MAT1 `E` modal sensitivities",
        "including grouped two-material perturbations for every supported direct field",
        "response-level MAC mode tracking",
        "previous-solve MAC continuation",
        "cluster-policy controls",
        "grouped shell-thickness `Kg` derivatives",
        "SOL 105 generic design sensitivity",
        "SOL 105 multimode/KS buckling aggregation",
        "`DOPTPRM,BUCKM#`",
        "`DOPTPRM,BUCKMODE`",
        "`DOPTPRM,BUCKPOL`",
        "`DOPTPRM,BUCKTRK`",
        "SOL200-lite buckling objectives can opt into",
        "Projected repeated/clustered subspace derivatives",
        "`current_mode`, `min`, `max`, and `mean` cluster-policy controls",
        "Automatic mode-crossing continuation",
        "KS displacement response",
        "SOL200-lite `DRESP1,KSDISP`",
        "PLOAD4 pressure-load geometry",
        "SOL 106 nonlinear sensitivity",
        "Coordinate/shape sensitivity",
        "node-coordinate shape variables",
        "explicit stress-geometry",
        "Design-dependent load sensitivity",
        "CBAR/CBEAM GRAV material-density load-only sensitivity",
        "CROD/CONROD/CBAR/CBEAM RFORCE material-density load-only sensitivity",
        "CROD/CONROD/CBAR/CBEAM TEMP(LOAD) MAT1 `E`/`ALPHA`/`TREF` thermal-load sensitivity",
        "SOL 105 RFORCE",
        "DVMREL-driven stress derivatives and broader beam stress/failure sensitivity semantics remain incomplete",
        "Recommended Implementation Order",
    )
        _require_marker(matrix, marker)
    end

    for marker in (
        "residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106",
        "residual_first_crod_conrod_sol101_sol103",
        "residual_first_cbar_cbeam_sol101_sol103_sol105",
        "residual_first_celas1_celas2_cbush_sol101_sol103",
        "mat1_mat2_mat8_pshell_pcomp_clt",
        "native_residual_first_quad4_cquadr_tria3",
        "native_residual_first_crod_conrod_operator",
        "beam_geometric_stiffness",
        "native_residual_first_cbar_cbeam_operator",
        "static_compliance_thickness_gradient",
        "static_compliance_design_gradient",
        "static_displacement_design_gradient",
        "static_ks_displacement_design_gradient",
        "static_ks_von_mises_design_gradient",
        "static_ks_ply_failure_design_gradient",
        "structural_mass_design_gradient",
        "modal_eigenvalue_design_gradient",
        "buckling_load_factor_thickness_gradient",
        "buckling_load_factor_design_gradient",
        "buckling_load_factor_ks_design_gradient",
        "core_contracts",
    )
        _require_marker(backend_interface, marker)
    end

    for marker in (
        "_beam_pload1_equivalent_local_load_vector",
        "_beam_pload1_local_load_vector_for_sid",
        "_line_rforce_consistent_endpoint_forces",
        "_add_line_rforce!",
        "resolve_thermal_loads",
        "Keep PLOAD1 local axes aligned",
    )
        _require_marker(loads, marker)
    end

    for marker in (
        "active_load_id",
        "active_load_scale",
        "fixed_end_load",
        "frame_force_dict_from_local",
        "apply_bar_pin_flags!",
    )
        _require_marker(stress_recovery, marker)
    end

    for marker in (
        "\"PA\"=>pa, \"PB\"=>pb, \"WA\"=>wa, \"WB\"=>wb, \"TYPE\"=>\"CBEAM\"",
    )
        _require_marker(extract_geometry, marker)
    end

    for marker in (
        "KSDISP",
        "ks_displacement",
    )
        _require_marker(model_builder, marker)
    end

    for marker in (
        "_pcomp_surface_ply",
        "_pcomp_von_mises_explicit_fd",
        "_shell_response_stress_data",
        "_ks_ply_failure_items",
        "_tsai_hill_failure_index",
        "_tsai_wu_failure_index",
        "_modified_tsai_wu_failure_index",
        "_pcomp_ply_failure_explicit_fd",
        "_failure_strength_explicit_fd",
        "_beam_stress_sample_value_and_cache",
        "_beam_response_explicit_fd",
        "_beam_design_field_from_dv",
    )
        _require_marker(solver_adjoint, marker)
    end

    for marker in (
        "abstract type AbstractTACSCoreContract",
        "struct TACSShellElementKernel",
        "struct TACSRodElementKernel",
        "_tacs_rod_element_kernel",
        "rod_crod",
        "rod_conrod",
        "struct TACSBeamElementKernel",
        "_tacs_beam_element_kernel",
        "beam_cbar",
        "beam_cbeam",
        "struct TACSSpringElementKernel",
        "_tacs_spring_element_kernel",
        "spring_celas1",
        "spring_celas2",
        "spring_cbush",
        "spring_damping_orientation_and_broader_mass_sensitivities",
        "struct TACSConstitutiveKernel",
        "pshell_mat2",
        "pshell_mat8",
        "struct TACSResponseContract",
        "struct TACSResponseFunction",
        "ks_displacement",
        "ks_ply_failure",
        "struct TACSSensitivityContract",
        "rod_area",
        "beam_area",
        "beam_i2",
        "TACS_GEOMETRIC_BEAM_STIFFNESS_ROUTE",
        "spring_stiffness",
        "bush_stiffness",
        "point_inertia",
        "struct TACSShellElementContext",
        "struct TACSStaticResponseContext",
        "struct TACSModalResponseContext",
        "struct TACSBucklingResponseContext",
        "_tacs_response_function",
        "_tacs_static_response_context",
        "_tacs_response_value",
        "_tacs_static_adjoint",
        "_tacs_response_explicit_design_derivative",
        "_tacs_shell_element_context",
        "_tacs_core_contract_metadata",
        "static_shell_coordinate_sensitivity",
        "static_design_dependent_load_sensitivity",
        "static_material_density_load_sensitivity",
        "static_line_thermal_load_sensitivity",
        "static_load_design_derivative",
        "sol105_preload_design_dependent_load_sensitivity",
        "buckling_load_factor_inertial_preload_density",
        "static_ks_von_mises_coordinate_sensitivity",
        "static_ks_von_mises_beam_design_tangent",
        "static_ks_ply_failure_design_tangent",
        "adjoint_design_tangent_explicit_failure",
        "explicit_failure_strength",
        "structural_mass_coordinate_sensitivity",
        "mass_coordinate_fd",
        "modal_eigenvalue_shell_coordinate",
        "modal_eigenvalue_shell_design_tangent",
        "modal_mass_design_fd",
        "buckling_load_factor_shell_coordinate",
        "buckling_load_factor_shell_design_tangent",
        "response_family in buckling_families && design_family == :rod_area",
        "response_family in buckling_families && design_family in beam_sizing_designs",
        "buckling_ks_load_factor_shell_design_tangent",
        "clustered_eigenvalue_projected_derivative",
        "modal_eigenvalue_clustered_subspace",
        "buckling_load_factor_clustered_subspace",
        "_tacs_eigenvalue_cluster_modes",
        "_tacs_select_cluster_derivative",
        "_tacs_resolve_tracked_mode",
        "eigen_mode_tracking_reference",
        "eigen_mode_continuation_update",
        "_tacs_modal_cluster_projected_derivatives",
        "_tacs_buckling_cluster_projected_derivatives",
        "eigenvalue_cluster_policy",
        "mac_mode_tracking",
        "previous_solve_mac_mode_continuation",
        "adjoint_coordinate_fd",
        "adjoint_coordinate_fd_explicit_stress",
        "rayleigh_coordinate_kg_directional_fd",
        "rayleigh_design_kg_directional_fd",
        "rayleigh_load_kg_directional_fd",
        "modal_coordinate_fd",
        "modal_design_tangent_fd",
        "coordinate_shape_sensitivity",
    )
        _require_marker(tacs_core, marker)
    end

    for marker in (
        "SOL101/SOL103/SOL105/SOL106",
        "CQUAD4/CQUADR/CTRIA3",
        "guarded CROD/CONROD rod",
        "CBAR/CBEAM beam",
        "_tacs_validate_rod_slice",
        "_tacs_rod_residual_tangent",
        "_tacs_rod_local_stiffness",
        "_tacs_validate_beam_slice",
        "_tacs_beam_frame_and_transform",
        "_tacs_beam_residual_tangent",
        "_tacs_beam_mass_tangent",
        "_tacs_assemble_beam_mass",
        "tacs_lumped_cbar_cbeam_mass",
        "_tacs_beam_geometric_stiffness_operator",
        "tacs_native_kg_beam_elements",
        "tacs_native_kg_avg_beam_axial_force",
        "beam_geometric_stiffness",
        "allow_offsets_releases",
        "default_beam_offsets_releases",
        "allow_beam_offsets_releases",
        "Solver.bar_offsets_and_endpoints",
        "Solver.apply_bar_pin_flags!",
        "allow_beams=allow_beam_slice",
        "_tacs_validate_spring_slice",
        "_tacs_validate_modal_mass_slice",
        "allow_conm1",
        "_tacs_spring_residual_tangent",
        "_tacs_bush_residual_tangent",
        "_tacs_line_static_stiffness_design_types",
        "_tacs_beam_sizing_design_types",
        "_tacs_beam_design_values",
        "_tacs_model_with_beam_property_delta",
        "_tacs_model_with_rod_area_delta",
        "_tacs_model_with_spring_stiffness_delta",
        "_tacs_model_with_bush_stiffness_delta",
        "_tacs_conm1_point_mass_components",
        "_tacs_conm1_point_mass_terms",
        "component_pairs",
        "_tacs_conm2_point_inertia_terms",
        "\"term\"",
        "_tacs_point_mass_values",
        "_tacs_point_inertia_values",
        "_tacs_model_with_point_mass_delta",
        "_tacs_model_with_point_inertia_delta",
        "_tacs_assemble_sol101_full_stiffness_design_derivative",
        "_tacs_static_load_design_dependent",
        "_tacs_rod_mass_tangent",
        "_tacs_rod_area_stiffness_derivative_tangent",
        "_tacs_assemble_rod_area_stiffness_derivative",
        "_tacs_rod_area_mass_derivative_tangent",
        "_tacs_assemble_rod_area_mass_derivative",
        "_tacs_rod_geometric_stiffness_operator",
        "tacs_native_kg_rod_elements",
        "_tacs_sol103_modal_mass_builder",
        "_tacs_sol103_modal_mass_route_label",
        "_tacs_sol103_linear_stiffness_route_label",
        "shared_jfem_modal_point_mass",
        "_tacs_structural_mass_rod_value",
        "_tacs_structural_mass_rod_area_derivative",
        "_tacs_structural_mass_beam_value",
        "_tacs_structural_mass_beam_area_derivative",
        "_tacs_structural_mass_point_mass_value",
        "_tacs_structural_mass_point_mass_derivative",
        "_tacs_model_has_modal_point_mass",
        "_tacs_shell_residual_tangent(kernel::TACSShellElementKernel",
        "_tacs_mat2_pshell_constitutive",
        "_tacs_mat8_pshell_constitutive",
        "_tacs_shell_geometric_stiffness_operator(",
        "for key in (\"CBARs\", \"CBEAMs\")",
        "allow_rods=allow_rod_slice",
        "\"RBE1s\", \"RBE2s\", \"RBE3s\"",
        "_solve_tacs_sol101",
        "_solve_tacs_sol103",
        "_solve_tacs_sol105",
        "_solve_tacs_sol106",
        "static_compliance_thickness_gradient(::TACSFormulationBackend",
        "static_compliance_design_gradient(::TACSFormulationBackend",
        "static_displacement_design_gradient(::TACSFormulationBackend",
        "static_ks_displacement_design_gradient(::TACSFormulationBackend",
        "static_ks_von_mises_design_gradient(::TACSFormulationBackend",
        "static_ks_ply_failure_design_gradient(::TACSFormulationBackend",
        "structural_mass_design_gradient(::TACSFormulationBackend",
        "function modal_eigenvalue_design_gradient(",
        "function buckling_load_factor_thickness_gradient(",
        "function buckling_load_factor_design_gradient(",
        "function buckling_load_factor_ks_design_gradient(",
        "_tacs_model_with_grid_coord_delta",
        "_tacs_assemble_sol101_coordinate_derivative",
        "allow_beams=allow_beam_slice",
        "_tacs_assemble_sol101_load_design_derivative",
        "_tacs_static_load_vector",
        "load_derivative_norm",
        "tacs_formulation_load_fd_adjoint",
        "_tacs_sol105_geometric_stiffness_coordinate_derivative",
        "_tacs_sol105_geometric_stiffness_design_derivative",
        "_tacs_sol105_static_load_design_derivative",
        "_tacs_sol105_static_subcase_sid",
        "_tacs_assemble_sol103_mass_design_derivative",
        "_tacs_sol103_analysis_modes",
        "cluster_gradient_eigenvalues",
        "mode_tracking",
        "cluster_policy_projected_derivative",
        "_tacs_structural_mass_coordinate_derivative",
        "_tacs_model_with_design_delta",
        "_tacs_material_group_design_step",
        "_tacs_model_with_material_fields_delta",
        "material_ALPHA",
        "material_TREF",
        "tacs_formulation_coordinate_fd",
        "tacs_formulation_stress_coordinate_fd_adjoint",
        "tacs_formulation_modal_coordinate_fd",
        "tacs_formulation_modal_design_tangent_fd",
        "tacs_formulation_modal_mass_design_fd",
        "tacs_formulation_mass_coordinate_fd",
        "tacs_formulation_mass_coefficient",
        "tacs_formulation_ks_displacement_design_tangent_adjoint",
        "tacs_formulation_ply_failure_adjoint_design_tangent",
        "tacs_formulation_rayleigh_coordinate_kg_directional_fd",
        "tacs_formulation_rayleigh_design_kg_directional_fd",
        "tacs_formulation_rayleigh_load_kg_directional_fd",
        "tacs_formulation_buckling_ks_weighted_rayleigh",
        "material_G11",
        "material_G12",
        "material_G13",
        "material_G22",
        "material_G23",
        "material_G33",
        "node_coord",
    )
        _require_marker(tacs_shell, marker)
    end

    for marker in ("\"M_FULL\"",)
        _require_marker(extract_elements, marker)
    end

    for marker in ("raw_full = get(cm, \"M_FULL\", nothing)",)
        _require_marker(solve_case, marker)
    end

    for marker in (
        "_solve_sol200_lite_pcomp_ply_optimization",
        "_solve_sol200_lite_material_optimization",
        "_solve_sol200_lite_stress_response",
        "ks_displacement",
        "buckling_aggregation",
        "buckling_ks_rho",
        "BUCKMODE",
        "BUCKM",
        "BUCKPOL",
        "BUCKTRK",
        "BUCKWIN",
        "BUCKMAC",
        "material_E1",
        "material_E2",
        "material_G12",
        "material_NU12",
        "SOL 200-lite stress response route does not yet support DVMREL-driven stress derivatives",
    )
        _require_marker(solver, marker)
    end

    for marker in (
        "_backend_buckling_load_factor_ks_design_gradient",
        "_backend_eigen_mode_continuation_update",
        "_backend_static_ks_displacement_design_gradient",
        "ks_displacement",
        "buckling_ks_rho",
        "buckling_ks_modes",
        "buckling_cluster_policy",
        "buckling_mode_tracking",
        "smooth_min_load_factor",
    )
        _require_marker(optimize, marker)
    end

    println("JFEM TACS core capability matrix guard passed")
    println("  matrix = Reference_documentation/tacs_core_capability_matrix.md")
    return true
end

exit(main() ? 0 : 1)
