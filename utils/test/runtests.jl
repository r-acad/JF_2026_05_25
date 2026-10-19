# Package release gate uses the curated public suite and source-level guards.
using Test, LinearAlgebra
BLAS.set_num_threads(1)
ENV["JFEM_SUPPRESS_THREAD_HINT"] = "1"

saved_args = copy(ARGS)
empty!(ARGS)
push!(ARGS, "--no-write")
suite_rows = try
    # The suite remains independently usable as a CLI and returns structured
    # rows here; a successful process exit alone does not establish parity.
    include(joinpath(@__DIR__, "..", "..", "validation", "run_public_suite.jl"))
finally
    empty!(ARGS)
    append!(ARGS, saved_args)
end

include("rbe3_um_test.jl")
include("constraint_coupling_test.jl")
include("tacs_linear_compatibility_test.jl")
include("assembly_compute_barriers_test.jl")
include("rspline_interpolation_test.jl")
include("q4_active_mode_condensation_test.jl")
include("coupled_quad4_internal_policy_test.jl")
include("quad4_affine_hourglass_test.jl")
include("autospc_local_scale_test.jl")
include("singular_regularization_test.jl")
include("lu_equilibrium_quality_test.jl")
include("coupled_timoshenko_beam_test.jl")
include("cbar_coupled_mass_test.jl")
include("modal_lumped_mass_geometry_test.jl")
include("shell_frame_rigid_motion_test.jl")
include("shell_operator_locality_test.jl")
include("tria_snorm_normal_moment_test.jl")
include("geometric_capture_thread_safety_test.jl")
include("pshell_mat2_membrane_projection_test.jl")
include("macneal_shear_resultants_test.jl")
include("natural_shear_work_transport_test.jl")
include("blank_continuation_test.jl")
include("fixed_bulk_continuation_test.jl")
include("pcomp_tria_prestress_coupling_test.jl")
include("tria_geometric_transverse_test.jl")
include("pcomp_isotropic_operator_equivalence_test.jl")
include("pcomp_energy_shear_test.jl")
include("pcomp_planar_coupled_energy_test.jl")
include("pcomp_warped_coupled_energy_test.jl")
include("shell_shear_rotation_covariance_test.jl")
include("tria_bending_flexibility_guard_test.jl")
include("pcomp_shear_frame_recovery_test.jl")
include("shell_basic_material_coordinate_test.jl")
include("shell_material_orientation_export_test.jl")
include("modal_shell_inertia_test.jl")
include("modal_indefinite_singular_pencil_test.jl")
include("sol106_coupled_dispatch_test.jl")
include("sol106_nlparm_test.jl")
include("sol106_shell_energy_test.jl")
include("pcomp_projected_recovery_work_test.jl")
include("pcomp_constitutive_frame_recovery_test.jl")
include("pcomp_snorm_transverse_work_test.jl")
include("warped_assumed_transverse_test.jl")
include("warped_pcomp_prestress_test.jl")
include("macneal_taper_energy_continuity_test.jl")
include("q4_taper_compliance_test.jl")
include("pipeline_timings_test.jl")
include("installation_setup_test.jl")
include("runtime_images_test.jl")
include("platform_launcher_test.jl")
include("pandeator_http_test.jl")
include("sysimage_workload_test.jl")
include("shared_app_environment_test.jl")
include("sol105_recovery_reuse_test.jl")
include("sol105_constraint_selection_test.jl")
include("k6rot_metadata_test.jl")
include("pipeline_long_path_test.jl")
include("beam_geometric_resultants_test.jl")
include("rectangular_torsion_test.jl")
include("beam_buckling_sensitivity_test.jl")
include("buckling_independent_modes_test.jl")
include("pbeam_neutral_axis_derivative_test.jl")
include("pbeam_neutral_axis_test.jl")
include("pbeam_taper_flexibility_test.jl")
include("pbeam_nonlinear_scope_test.jl")
include("pbeam_load_scope_test.jl")

@testset "Curated public release gate" begin
    declared_cases=expand_public_cases(YAML.load_file(MANIFEST_PATH))
    expected=Set((String(case["id"]),String(q["name"])) for case in declared_cases for q in get(case,"quantities",[]))
    observed=Set((r.case_id,r.quantity) for r in suite_rows)
    @test length(suite_rows) == length(expected)
    @test observed == expected
    @test all(r -> r.jfem !== nothing && isfinite(r.jfem), suite_rows)
    @test all(r -> !startswith(r.verdict, "ERROR") && r.verdict != "JFEM_SKIPPED", suite_rows)
    expected_secondary=Set((String(case["id"]),String(q["name"])) for case in declared_cases for q in get(case,"quantities",[]) if haskey(q,"parity"))
    secondary_rows = filter(r -> r.parity_ref !== nothing, suite_rows)
    @test Set((r.case_id,r.quantity) for r in secondary_rows) == expected_secondary
    @test all(r -> r.parity_verdict == (startswith(r.parity_source,"historical_regression:") ? "HISTORICAL_PASS" : "PARITY_PASS"), secondary_rows)

    # Existing coarse-mesh analytical limitations remain visible as FAIL
    # accuracy rows; reference parity never turns them into accuracy passes.
    # A new failing case or quantity must be reviewed explicitly.
    known_accuracy_limits = Set([
        ("MH_curved_beam_in_plane", "tip_disp_in_plane"),
        ("MH_pinched_cylinder", "radial_disp_under_load"),
    ])
    for row in suite_rows
        @test row.verdict == (startswith(row.ref_source,"historical_regression:") ? "REGRESSION_PASS" : "PASS") ||
            (row.verdict == "FAIL" && (row.case_id, row.quantity) in known_accuracy_limits)
    end
end
