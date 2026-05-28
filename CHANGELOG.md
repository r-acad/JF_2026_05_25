# Changelog

All notable changes to OpenJFEM are recorded here. Dates are ISO 8601.
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- `solver/boundary_conditions`: SOL 101 AUTOSPC machinery with load-path
  protection. New helpers `_autospc_model_sol_type`,
  `autospc_rot_relative_threshold`, `_load_path_add_components!`,
  `_load_path_element_components`, `_load_path_protect_element_nodes!`,
  `_build_sol101_load_path_protected_trans_dofs`, `_autospc_inverse_id_map`.
  Prevents the auto single-point constraint from clamping DOFs touched by
  elements that carry applied load.
- `solver/assembly`: distributed `assemble_stiffness` updates aligned with
  the new AUTOSPC / load-path machinery (~60 lines).
- `ModelBuilder.build_model_from_json`: propagate new model fields.
- `parsing/extract_materials`: new material parsing branch.
- `parsing/extract_properties.extract_props_shell`: shell property
  extraction extension. Line endings normalized (CRLF -> LF) on
  `ModelBuilder.jl`, `extract_materials.jl`, `extract_properties.jl`.
- `JFEMSolver`: new SOL 101 capability gates and env-bool helpers
  (unsymmetric `PCOMP`, transverse `CELAS`, static membrane-incomp).
- `FEMKernels.stiffness_quad4_matrices`: new kwargs
  `marguerre_warp_to_uz`, `min4_disable`, `bmb_incomp_coupling_mode`, plus
  ~400 lines of CQUAD4 kernel work.
- `solver/assembly`: new `build_node_has_frame_elements` helper and assembly
  path updates.
- `solver/solve_case`: `solve_buckling` internal updates.
- `solver/loads`: new `_shell_normal_moment_filter_data` helper for shell
  normal-moment filtering on `resolve_loads`.
- `solver/sol105_options` and `solver/sol105_calibrated_constants`: new
  kernel options exposed, calibrated constants updated.
- Minor cleanups in `solver/buckling_result`, `solver/helpers`,
  `solver/constraints`, `OpenJFEM.jl`, `main.jl`, and the `tools/*`
  runners. Line endings normalized (CRLF -> LF) on
  `solver/constraints.jl` and `solver/loads.jl`.

### Added
- `Reference_documentation/README.md` index listing every published PDF and
  Markdown note with its audience and purpose.
- `Reference_documentation/jfem_2026_architecture_manuscript.pdf` (renamed
  from the previous `main.pdf` to a meaningful name).
- `Reference_documentation/jfem_2026_architecture_and_shell_presentation.pdf`
  (renamed from `jfem_2026_presentation.pdf`).
- `CONTRIBUTING.md` and this `CHANGELOG.md`.

### Removed
- `Reference_documentation/main.pdf` (replaced by the renamed copy).
- `Reference_documentation/jfem_2026_presentation.pdf` (replaced by the
  renamed copy).

## [0.1.0] - 2026-04-26

Initial public layout of the OpenJFEM repository under the new workspace.

### Added
- Julia package `OpenJFEM` with parse / solve / export pipeline.
- Solution sequences: SOL 101 (linear static), SOL 103 (normal modes,
  including normalized SOL 63), SOL 105 (linear buckling), experimental
  SOL 106 (geometrically nonlinear static).
- Shell, bar, beam, rod, spring, rigid, mass, and solid elements; composite
  laminates from `PCOMP` cards.
- Adjoint sensitivity framework for static responses and buckling eigenvalues.
- Python client and JSONL worker for external optimization loops.
- HDF5, VTK, JSON, and `.jfem` binary exporters; browser-based `.jfem` viewer.
- Initial reference documentation: architecture manuscript, shell-formulation
  paper, companion slide deck, user reference guide.
