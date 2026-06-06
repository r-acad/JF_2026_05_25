# Changelog

All notable changes to OpenJFEM are recorded here. Dates are ISO 8601.
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- SOL 105 buckling: optional **load-aware shear kernel** (opt-in via
  `JFEM_SOL105_LOAD_AWARE_KERNEL`, default off). On warped/curved PCOMP elements
  under shear preload, JFEM's default MITC4+phi2 transverse shear diverges from
  MSC Nastran's released CQUAD4 (flat MacNeal RBF) by up to ~46% on the buckling
  eigenvalue, while compression stays ~1%. The discriminator is a conjunction —
  an element is non-flat AND shear-dominated
  (`|Nxy|/(|Nx|+|Ny|+|Nxy|) >= JFEM_SOL105_LOAD_AWARE_SHEAR_RATIO_MIN`, default
  0.12; warp ≥ `JFEM_SOL105_LOAD_AWARE_WARP_MIN`, default 1e-5). The effect
  enters through the static solve (u_static → Kg), so the feature runs a 2-pass
  static: solve, classify shear-dominated elements from the static field,
  reassemble the static stiffness forcing those elements onto the flat MacNeal
  kernel, and re-solve. Thresholds are probe-population separation values
  (a documented heuristic, not benchmark-fitted; the GAME decks are held out).
  Validated: the strongest warped-shear probe goes 46.2% → 2.3% vs Nastran with
  zero regressions across the 23-deck probe set. Flag OFF is byte-identical to
  prior behavior. Known limitation: combined-load / lower-warp shear cases are
  not yet covered (the per-element shear metric is entangled with the kernel it
  selects — see SOL105_load_aware_kernel notes).
- SOL 105 buckling JSON now exports per-subcase eigenvalues under a `subcases`
  array (`buckling_subcase_id`, `static_subcase_id`, `eigenvalues`). The
  top-level `eigenvalues` list merges and sorts all subcases together, which
  interleaves modes from different buckling subcases and makes per-subcase
  parity comparison against a reference `.f06` (one eigenvalue table per
  subcase) ambiguous. Consumers can now compare each subcase to its own
  reference table. No solver behavior change — purely additional output.

### Fixed
- Public validation suite manifest now extracts the MacNeal-Harder twisted
  beam, Scordelis-Lo roof, and hemispherical-shell quantities from the
  documented benchmark nodes, and supports explicit absolute-value comparison
  for signed displacement quantities reported as magnitudes.
- Public validation suite CSV output now quotes fields containing commas,
  quotes, or newlines, so solver error notes remain parseable.
- Public validation suite analytical-reference lookup now wraps both runtime
  binding access and function invocation in `Base.invokelatest`, avoiding Julia
  1.12 world-age deprecation warnings during `run_public_suite.jl`.
- Exporters now write JSON, Markdown report, HDF5, and JFEM binary artifacts
  through a Windows long-path helper when paths approach the classic
  260-character limit. Long SOL105 validation case names could solve
  successfully but fail at `*.BUCKLING.JSON` export with `ENOENT`; a
  409-character smoke path and the 13-case NAST705 patch rerun now pass.
- SOL 105 GAME parity: the spectral-gap buckling cluster filter is now opt-in
  (`JFEM_BUCKLING_CLUSTER_FILTER=false` by default), so broad physical low-mode
  bands remain available to MAC/Rayleigh comparison. A generic orthotropic PCOMP
  geometric-stiffness scale was added for thick high-aspect elements
  (`aspect=5..25`, assembly-scale `h/Lmax>=0.03` and shell elements `>=100`,
  scale `0.98`), while small a8-like PCOMP matrix-fingerprint meshes
  (`aspect=7.8..8.2`) retain the legacy scale `1.032`. The discriminator uses
  only material and geometry, with no case-name, group-name, or stress-state
  gate.
- SOL 105 buckling now correctly inherits the static subcase's SPC when the
  buckling subcase omits one. A buckling subcase carrying an `SPC` key with a
  `nothing` value (the common case) previously resolved to no constraints, so
  the eigen pass assembled an unconstrained, non-SPD `K_ff` and returned a wrong
  buckling spectrum. The classical simply-supported plate buckling benchmark
  goes from ~76% error to ~3% as a result; the MYSTRAN bar case is unchanged.
- Classical thin-cylinder axial-buckling benchmark deck
  (`tools/validation_suite/cases/classical/cylinder_axial_buckling.bdf`): the
  axial end load was applied in `-Z`, which is **tension** for the deck's own
  boundary layout (the `z=100` midspan plane is fixed in Z, the loaded `z=0` end
  is free) — so the strip stretched and the buckling spectrum came out all
  negative. Investigation confirmed the solver was correct: static stress,
  displacement, and the fixed-end reaction all flip cleanly and consistently
  when the load direction flips, so this was a **deck** error, not a solver sign
  bug. Load corrected to `+Z` (compression toward the fixed midspan). Separately,
  the lowest computed mode was a spurious sub-critical drilling (local Rz)
  near-mechanism left by the soft `PARAM,K6ROT` stiffness; constraining the
  in-plane drilling DOF (`SPC1, 1, 6, 1, THRU, 18`) removes it. The benchmark now
  reports the physical axisymmetric mode at +11.1% vs the Brush-Almroth value,
  within its 15% tolerance, and the case PASSes.

### Added
- `tools/validation_suite/run_public_suite.jl` now actually runs JFEM on each
  case (was a stub) and extracts the compared quantity (displacement by
  node/dof, eigenvalue by mode), so the public suite is a working regression
  net. Also fixed a world-age error in analytical-reference resolution
  (`Base.invokelatest`), and the JFEM value is now recorded even when a
  reference fails to resolve, so changes are always diff-able.
- SOL 105 buckling: **Sturm inertia diagnostic** on iterative eigensolves.
  After the spectrum is filtered, the solver records the inertia (Sturm) count
  of the (K, -Kg) pencil over the returned band — the exact number of pencil
  eigenvalues in the interval via the `sturm(b) - sturm(a)` difference — in
  `solver_diagnostics.sturm_completeness` (`sturm_eigs_in_interval` vs
  `reported_in_interval`). This is INFORMATIONAL, not a pass/fail verdict: the
  buckling pencil is indefinite and its inertia counts spurious low-energy modes
  (drilling, localized mechanisms, near-singular DOFs) that JFEM's localization
  and cluster filters deliberately drop, so the pre-filter Sturm count normally
  exceeds the post-filter reported count without any physical mode being missed.
  (An earlier iteration emitted a complete/incomplete verdict from this and
  consequently cried "incomplete" on every realistic model — that verdict was
  removed.) Toggle with `JFEM_SOL105_STURM_COMPLETENESS` (default on); the dense
  path computes the full spectrum and skips it.
  - **Performance fix (the important part):** the inertia is now read correctly
    via `diag(F)` on the CHOLMOD sparse LDLᵀ factor. The previous code called
    `diag(F.D)` on a CHOLMOD `FactorComponent`, which throws `CanonicalIndexError`
    and fell through to a dense `lu(Matrix(M))` fallback — densifying the
    26k–60k+ sparse pencil into tens of GB and effectively hanging large-model
    SOL 105 runs. The dense fallback is removed; the sparse path is the right
    algorithm and is fast (≈1.5 s per shift at 60k DOF). The GAME aircraft-tail
    decks (VTP 27k DOF, HTP 61k DOF ~42 s end-to-end) now complete with the
    diagnostic on; both previously stalled. The size valve
    `JFEM_SOL105_STURM_MAX_DOF` is retained but its default is raised to
    **200000** (effectively off for realistic models; 0 = never skip).

### Changed
- SOL 105 production defaults now use only element material and geometry for the
  promoted PCOMP parity refinements. The QUAD4 geometric-stiffness stress-field
  mode defaults to fixed Gauss recovery, disabling the prior default
  stress-state-discriminating `auto` path; PCOMP static stiffness and geometric
  stiffness receive generic aspect/taper/curvature/thickness-ratio gates. The
  opt-in load-aware route remains available but is not active by default.
- SOL 105 buckling: the dense symmetric-definite eigensolver is no longer the
  default for systems up to 4000 DOF. It is now gated by
  `JFEM_SOL105_DENSE_MAX_DOF` (default **200**) and serves only as a fast exact
  oracle for small systems; larger systems go straight to the iterative
  shift-invert Lanczos/Krylov path, which the new Sturm check then certifies.
  Behavior is unchanged on the existing validation corpus (all cases ≤189 free
  DOF still solve densely). Set to 0 to force the iterative path at every size.

### Fixed
- Windows launchers (`POST/panel_app.cmd`, `jfem.cmd`,
  `build_sysimage/build_sysimage.cmd`) now work when the install path contains
  parentheses or spaces (e.g. a browser download named
  `...\JF_2026_05_25-main (7)\...`). Previously the `)` inside such a path
  prematurely closed the `if exist (...)` block, producing
  `...OpenJFEM_sysimage.dll was unexpected at this time`. Fixed by enabling
  delayed expansion and referencing/quoting paths as `!VAR!`.

### Changed
- `POST/panel_launch.jl`: the web app now opens exactly ONE browser tab on
  launch. Previously up to four tabs appeared because `explorer.exe` returns a
  non-zero exit code even on success (triggering a second `start` fallback) and
  the launcher also called the opener twice; both are fixed.
- `POST/panel_app.html`: the Analyze button now turns RED when any model/analysis
  input changes (results are stale) and GREEN once results are available, giving
  clear at-a-glance feedback on whether the shown results match the inputs.
- `README.md` and `Reference_documentation/case_submission_methods.md`: document
  how to invoke the `jfem` wrapper - shells do not run a bare command name from
  the current directory, so use `.\jfem` (Windows) / `./jfem` (Linux/macOS) from
  the repo folder, or add the repo to `PATH` to call `jfem` from anywhere;
  Linux/macOS also need the execute bit (`chmod +x jfem`).
- Dense BLAS (the Cholesky factorization in SOL 101/105 and the eigensolve in
  SOL 103/105) now runs on the physical-core count instead of OpenBLAS's
  default (~half the logical processors). The web server (`POST/panel_server.jl`)
  and the `jfem`/`tools/jfem.jl` runner set this at startup; benchmarks show the
  physical-core count is the fastest setting for FE factorization (all-logical
  hyperthreads are slower). The server logs the chosen BLAS/thread counts.
- `tools/deploy_fast.jl`: the prebuilt sysimage now covers the web app's hot
  path, not just startup. It bakes in the server stack (`HTTP`, `MsgPack`,
  `JSON`) and a precompile workload that drives the server's own `run_analysis`
  + HTTP-handler + msgpack path on the bundled decks, so the FIRST browser
  Analyze no longer pays just-in-time compilation for the solve/export path.
- `POST/panel_server.jl`: `/health` and the startup banner now report whether
  the process is running inside a custom sysimage and the Julia/BLAS thread
  counts, and each run logs a per-phase timing breakdown (parse / build / solve
  / export). The `/analyze` response includes a `timings` map and the web app
  surfaces a phase breakdown, so a slow run is diagnosable.
- `POST/panel_app.html`: 3D viewer camera controls. Double-clicking the empty
  background resets and recenters the view on the model (an escape hatch for
  getting lost after rotating/panning); middle-clicking a point on the model
  makes that point the camera's rotation center without moving the eye.
- `POST/panel_server.jl`: the solve now runs on a worker thread (still
  serialised by the solve lock) and `HTTP.serve` uses `readtimeout=0`, so the
  server stays responsive to health checks and other requests during long
  multi-minute solves. This removes the spurious `ECANCELED` connection errors
  and false "server may have stopped" warnings seen on large models. The
  front-end health watcher is also more tolerant (warns only after a sustained
  no-response window).
- Generalized the internal SOL200-lite material-route helper names and
  user-facing diagnostics from MAT1-only wording to material-route wording now
  that the route executes both MAT1 and MAT8 material design relations.
- `CQUADR` shell cards are now accepted directly and are always solved through
  the TACS formulation. When the requested/default backend is `nastran_parity`,
  `solve_model(model)` forces the actual route to `tacs_formulation` and
  records `backend_forced_by = "CQUADR"`.
- Expanded the `CQUADR` TACS validation envelope beyond the initial SOL101
  forced-route guard. The new generated route check exercises default-backend
  `CQUADR` decks through SOL103 modal analysis, SOL105 buckling plus thickness
  sensitivity, and SOL200-lite shell-thickness sizing.
- Extended forced-route diagnostics so vector-shaped solver diagnostics, such
  as SOL103/SOL105/SOL106 results, also receive an explicit
  `backend_forced_by = "CQUADR"` backend-selection entry.
- Updated TACS route guard metadata expectations to the current
  `residual_first_quad4_cquadr_tria3_sol101_sol103_sol105_sol106` shell
  formulation label.
- Expanded CQUADR validation from single-element generated decks to a mixed
  `CQUAD4`/`CQUADR`/`CTRIA3` patch. The new guard verifies forced TACS routing
  for SOL101 compliance sensitivity, SOL103 modal response, and SOL105
  buckling plus thickness sensitivity on the same mixed shell envelope.
- Updated TACS per-SOL route diagnostics so linear stiffness and native
  geometric stiffness labels explicitly include `CQUADR`
  (`residual_first_quad4_cquadr_tria3` and
  `native_residual_first_quad4_cquadr_tria3`), matching the supported shell
  formulation metadata.
- Expanded CQUADR validation to two-property mixed shell patches. The new guard
  verifies PID-separated SOL101 compliance/displacement gradients, SOL105
  buckling sensitivities, and SOL200-lite grouped thickness sizing when a
  `CQUADR` element forces the TACS formulation.
- Promoted the conservative SOL105 formulation refinement from the 2026-06-03
  parity sweep: CQUAD4 `Kg` stress recovery now defaults to load-classified
  `auto`, and SOL105 static preload K enables Wilson membrane modes only for
  simple-compression loads accepted by the direct-FORCE classifier. Broad
  SOL101 membrane transfer and `macneal_all` remain experimental because they
  regressed shear/mixed NAST705 probes and the GAME guard, respectively. The
  current TACS-formulation SOL105 route pins the auto-load static reassembly
  off until it has a native load-classified reassembly path.

### Added
- `build_sysimage/` folder: clearly identified, cross-platform sysimage build
  scripts - `build_sysimage.cmd` (Windows), `build_sysimage.sh` (Linux/macOS),
  and a `README.md` with step-by-step instructions. Building a sysimage is
  optional (everything runs without one, just slower to start); the launchers
  load it automatically when present. `POST/panel_app.sh` now loads a
  `.so`/`.dylib` sysimage when present and uses plain `julia` (dropped the
  juliaup-only `+release`), matching `panel_app.cmd`.
- `Reference_documentation/jfem_method_origins_review.pdf`: literature review
  mapping the reference paper corpus to the numerical methods implemented in
  JFEM, organised along the solver pipeline (MITC/MacNeal shells, DKMQ,
  Hu--Washizu, drilling rotations, DKT triangles, buckling, composites,
  geometrically-exact shells), with full citations.
- One-line deck runner for all platforms: `jfem` (Linux/macOS) and `jfem.cmd`
  (Windows) wrappers plus the underlying `tools/jfem.jl`. Usage is just
  `jfem model.bdf [output_folder]` — the wrapper supplies Julia, the project,
  `--threads=auto`, viewer-ready defaults, and the sysimage if present, and the
  SOL is auto-detected. Results default to `<deck_dir>/<deckname>_out/`. An
  optional `-letters` string before the deck selects output formats in any order
  (`j` .jfem, `r` REPORT.md, `s` results JSON, `v` VTK, `h` HDF5, `m` model
  JSON, `c` card inventory); omitting it gives the default `-jrs` set.
- Added backend-dispatched generic static design-gradient hooks for the
  TACS-formulation SOL101 slice:
  `static_compliance_design_gradient` and
  `static_displacement_design_gradient`.
- Added the first TACS-formulation PCOMP ply-level design tangent route for
  CQUAD4/PCOMP_CLT SOL101 decks. The route supports ply thickness and ply
  angle design variables, preserves the ModelBuilder PCOMP transverse-shear
  correction policy during perturbations, and returns compliance and
  displacement-response gradients through the generic backend hooks.
- Added SOL200-lite parsing/routing for PCOMP ply DVPREL fields (`T<n>` and
  `THETA<n>`) on the TACS backend. The route performs bounded projected-
  gradient SOL101 compliance/displacement optimization through the
  TACS-formulation design-gradient hooks, records per-iteration ply
  sensitivities, and reports the explicit
  `SOL200_LITE_PCOMP_PLY_OPTIMIZATION` analysis type.
- Extended the TACS PCOMP ply SOL200-lite route with an optional upper-bound
  MASS/WEIGHT constraint. Ply-thickness variables now report laminate mass
  coefficients, ply-angle variables report zero mass coefficient, and the
  projected-gradient update is clipped back to the translated mass target.
- Added the first TACS material-design SOL200-lite route for
  `DVMREL1,MAT1,E`, `DVMREL1,MAT1,G`, `DVMREL1,MAT1,NU`, and
  `DVMREL1,MAT1,RHO` / `DVMREL1,MAT8,RHO` on supported SOL101 shell decks.
  The stiffness-material route performs bounded projected-gradient compliance/displacement
  optimization through the generic design-gradient hooks and records
  `SOL200_LITE_MATERIAL_OPTIMIZATION`. The route also accepts a feasible
  upper-bound MASS/WEIGHT constraint, reports invariant shell-mass diagnostics,
  and records zero mass coefficients for MAT1 `E/G/NU` variables. The `RHO`
  route supports `DESOBJ(MIN)=MASS` with analytic shell-mass coefficients for
  MAT1/PSHELL and MAT8/PCOMP shell mass.
- Extended the TACS material-design SOL200-lite route to MAT8 laminate
  stiffness variables (`DVMREL1,MAT8,E1/E2/G12/NU12`) for supported
  PCOMP/MAT8 SOL101 shell decks. The route refreshes affected PCOMP_CLT
  stiffness matrices after each MAT8 update and uses the generic
  TACS-formulation design-tangent hook for compliance/displacement gradients.
  The generated material-route coverage now exercises E1, E2, G12, and NU12
  laminate stiffness variables.
- Added the first executable TACS SOL200-lite stress-response route for
  `DRESP1,STRESS` / `DRESP1,VMSTRS` with `DESOBJ(MIN)`. The route dispatches
  a SOL101 TACS forward solve, recovers shell through-thickness von-Mises
  stresses, computes a KS aggregate controlled by `DOPTPRM,KSRHO`, and reports
  the explicit `SOL200_LITE_STRESS_RESPONSE` analysis type. When the same
  route carries a unit `DVPREL1,PSHELL/PCOMP,T` shell-thickness design
  relation, it also reports a TACS adjoint/design-tangent KS stress gradient
  through `static_ks_von_mises_design_gradient`. The generated route coverage
  now includes both PSHELL/MAT1 and PCOMP/MAT8 uniform-thickness stress
  design-gradient decks.
- Extended SOL200-lite mass minimization so upper-bound `DRESP1,STRESS` /
  `DRESP1,VMSTRS` constraints are translated to KS von-Mises static response
  constraints. The TACS route now supports generated `DESOBJ(MIN)=MASS` decks
  with `DCONSTR` stress limits and shell-thickness sizing, using the grouped
  exact search for single-design-variable decks and the multi-group response
  search for multi-property decks through the TACS KS stress adjoint/design-
  tangent hook. The generated route coverage now includes PSHELL/MAT1 and
  PCOMP/MAT8 stress-constrained mass-minimization decks.
- Added a backend nonlinear-state callback boundary for SOL106. The
  TACS-formulation route now evaluates tangent-operator nonlinear states
  through a backend callback that returns the native residual-first
  geometric stiffness, effective tangent, and residual metrics. The guarded
  flat-shell `PARAM,NLMETHOD,formal_shell_von_karman` path is also routed
  through the backend callback using the formal internal-force and consistent-
  tangent state evaluator.
- Extended `tools/testing/tacs_sol106_route_check.jl` with two-element
  flat-shell SOL106 patch decks. The expanded check now validates the
  TACS tangent-operator callback and the guarded formal von-Karman callback on
  a larger residual-first shell model, including larger `Kg` assembly and
  state-evaluation diagnostics.
- Preserved `PARAM,NLMETHOD` and `PARAM,NLRESMODEL` as string-valued BDF
  parameters so nonlinear method selection survives model construction.
- Broadened the TACS-formulation shell slice from CQUAD4-only to
  CQUAD4/CTRIA3 for the guarded PSHELL/MAT1 and PCOMP_CLT residual-first
  paths. CTRIA3 now uses the TACS constitutive abstraction for SOL101
  residual/tangent assembly, AD shell-thickness derivatives, SOL105/SOL106
  native geometric stiffness, and backend metadata.
- Added explicit CTRIA3 TACS route coverage for SOL103 modal analysis and
  SOL200-lite compliance sizing.
- Exported static, modal/buckling, nonlinear, and SOL200-lite optimization
  JSON payloads now carry solver backend metadata when the solve result
  provides it, making manifest and worker outputs self-describing across
  `nastran_parity` and `tacs_formulation` runs.
- Extended `tools/testing/tacs_sol101_fd_check.jl` with PCOMP ply-level
  design-gradient regression checks. The generated suite now verifies
  symmetric PCOMP ply thickness and unsymmetric off-axis ply thickness/angle
  gradients in addition to the existing residual, tangent, thickness, and
  response checks.
- Backend selection scaffold and first TACS-formulation vertical slice:
  public backend types, `JFEM_BACKEND`/model/manifest selection, explicit
  `nastran_parity` default metadata, plus a restricted residual-first
  `tacs_formulation` SOL 101 path for CQUAD4 + PSHELL + MAT1 models.
- Added `tools/testing/backend_default_check.jl` to guard the backend
  selection contract: blank/default/parity aliases normalize to
  `nastran_parity`, `JFEM_BACKEND=tacs_formulation` remains opt-in, explicit
  model backend selection overrides the environment, and default metadata
  stays on the existing calibrated JFEM formulation.
- Added `tools/testing/backend_manifest_check.jl` to guard JSON batch
  manifest backend propagation. The check runs a quiet SOL101 batch with
  `backend = "tacs_formulation"` and verifies the generated run manifest and
  exported static JSON preserve the selected backend.
- Added `tools/testing/backend_sol200_shared_route_check.jl` to guard the
  Phase 3 SOL200 contract. The generated deck runs once through the implicit
  `nastran_parity` default and once through `tacs_formulation`, proving the
  same SOL200-lite route surface dispatches both backend forward solves.
- Added `tools/testing/backend_parity_smoke_check.jl` to guard that bundled
  SOL101, SOL103, and SOL105 production-path examples still solve through the
  implicit `nastran_parity` backend and report the existing calibrated JFEM
  formulation.
- Added `tools/testing/tacs_backend_roadmap_audit.jl`, a static roadmap
  closure guard that maps the documented Phase 0-3 TACS backend requirements
  to the public numerical guard scripts and backend source hooks.
- Added `tools/testing/cquadr_tacs_expanded_route_check.jl` to guard the
  expanded `CQUADR` TACS route contract for SOL103, SOL105, and SOL200-lite.
- Added `tools/testing/cquadr_tacs_sol106_route_check.jl` to guard default
  `CQUADR` SOL106 routing through the TACS tangent-operator and formal
  von-Karman nonlinear-state callbacks.
- Added `tools/testing/cquadr_tacs_mixed_shell_route_check.jl` to guard mixed
  CQUAD4/CQUADR/CTRIA3 generated patches through the TACS formulation.
- Added `tools/testing/cquadr_tacs_multiproperty_route_check.jl` to guard
  two-property CQUAD4/CQUADR/CTRIA3 generated patches through forced TACS
  PID-separated gradients and SOL200-lite grouped sizing.
- `tools/testing/tacs_sol101_fd_check.jl`: finite-difference smoke and
  generated patch-suite check for the new TACS-formulation SOL 101
  residual/tangent slice, including PSHELL thickness `dK/dt` and `dR/dt`
  audits.
- TACS-formulation result metadata now records the active thickness
  derivative route (`element_ad`) for the supported PSHELL/MAT1 and
  PCOMP_CLT uniform-thickness slice.
- Added a backend-dispatched static compliance/thickness-gradient hook for
  the TACS SOL 101 slice, with finite-difference coverage in the patch suite.
- Extended the TACS-formulation SOL 101 slice to consume PCOMP/MAT8-derived
  CLT shell properties (`PCOMP_CLT` with `Cm`, `Bmb`, `Cb`, and `Cs`) while
  supporting the same backend-local AD thickness derivative for
  PSHELL/MAT1 and uniform-thickness PCOMP_CLT laminate scaling.
- Routed SOL 200-lite compliance sizing through the opt-in
  `tacs_formulation` backend for supported CQUAD4/PSHELL/MAT1 static
  and PCOMP_CLT forward solves, including backend/formulation fields in
  optimization iteration diagnostics.
- `tools/testing/tacs_sol200_route_check.jl`: generated-deck smoke test for
  SOL 200-lite -> TACS routing, covering static compliance sizing for PSHELL
  and PCOMP_CLT plus max-buckling sizing through the TACS SOL 105 route.
- Added a backend-dispatched buckling load-factor/thickness-gradient hook for
  the supported TACS SOL 105 shell slice. SOL 200-lite max-buckling sizing now
  consumes this hook for TACS shell-thickness variables and records a
  backend-local Rayleigh derivative route
  (`tacs_formulation_rayleigh_ad_kg_directional_fd`) in optimization
  diagnostics.
- Added a backend-dispatched static displacement/thickness-gradient hook for
  the supported TACS SOL 101 shell slice. SOL 200-lite displacement-constrained
  mass minimization now consumes this adjoint hook for TACS shell-thickness
  variables and records `tacs_formulation_element_ad_adjoint` in optimization
  diagnostics.
- Promoted the supported TACS SOL 101 shell-thickness tangent from an element
  finite-difference route to backend-local ForwardDiff AD through the active
  residual-first Quad4 operator. The AD route covers PSHELL/MAT1 and
  uniform-thickness PCOMP_CLT scaling, including unsymmetric `Bmb` coupling.
- Added the first TACS-formulation SOL 103 route for supported CQUAD4 shell
  modal decks. The route assembles the residual-first TACS shell stiffness and
  reuses the shared mass assembly, modal eigensolver, modal effective mass, and
  result packaging.
- `tools/testing/tacs_sol103_route_check.jl`: bundled-deck smoke test for
  TACS SOL 103 routing, finite modal frequencies, stiffness symmetry, and route
  metadata.
- Added the first TACS-formulation SOL 106 route for supported CQUAD4 shell
  nonlinear-static decks on the shared geometric route. The route assembles the
  residual-first TACS shell stiffness, supplies the native residual-first
  CQUAD4 geometric stiffness through a nonlinear callback, and now also routes
  the guarded flat-shell formal von-Karman path through the backend
  nonlinear-state callback.
- `tools/testing/tacs_sol106_route_check.jl`: generated-deck smoke test for
  TACS SOL 106 routing, native geometric-stiffness callback use, convergence
  diagnostics, nonzero `Kg`, and stiffness symmetry.
- Added the first TACS-formulation SOL 105 route for supported CQUAD4 shell
  buckling decks. The route assembles the residual-first shell tangent for
  `K`/`K_eig`, supplies a backend-native residual-first CQUAD4 geometric
  stiffness for `Kg`, reuses the shared SOL 105 preload/eigenvalue/result
  machinery, and records route metadata for the first buckling slice.
- `tools/testing/tacs_sol105_route_check.jl`: bundled-deck smoke test for
  TACS SOL 105 routing, finite eigenvalues, stiffness symmetry, and nonzero
  geometric stiffness, plus a thickness finite-difference/Rayleigh quotient
  derivative check on the first buckling factor.
- `Reference_documentation/JFEM_TACS_Backend_Roadmap_Beamer.pdf`: roadmap
  slides for a TACS-style backend.
- `POST/` stiffened-panel buckling web app: a pure-Julia HTTP + MsgPack
  server (`panel_server.jl`, `panel_launch.jl`, `panel_app.cmd/.sh`) plus a
  single-file Babylon.js front-end (`panel_app.html`, vendored libs under
  `POST/vendor/`). Generates a SOL 105 cylindrical stiffened-panel deck,
  solves it through OpenJFEM in-process, and renders the buckling modes and
  static results in 3D with load/BC overlays. Adds `HTTP` and `MsgPack` to
  the project dependencies; ignores `POST/panel_runs/` run artifacts.
- SOL 105 `.jfem` export now carries a STATIC results block (format bumped
  to v5): the static-preload nodal displacement (rotated to global) plus
  per-element von Mises stress, an equivalent membrane strain, and a
  strain-energy-density proxy, recovered from `u_static` via
  `_recover_sol105_static_fields`. Appended after the `EVAL` footer so v3/v4
  readers are unaffected. The web viewer parses v5 and lets the user select
  total / X / radial / tangential deformation contours and the static
  stress/strain/energy fields.
- `tools/validation_suite/`: public verification suite (MacNeal-Harder
  shell benchmarks, classical plate/cylinder buckling, CRM wingbox, MYSTRAN
  cross-reference cases) with analytical references and a runner.
- `Reference_documentation/agentic_numerical_software_report.pdf`: new
  long-form report covering workspace shape, working philosophy, useful
  prompts, agents, skills, hooks, the harness classifier, the technology
  stack, validation discipline, and the documentation build chain.
- `Reference_documentation/Agentic_Numerical_Software_Blueprint.pptx`:
  PowerPoint companion (10.4 MB).

### Changed
- `POST/panel_app.cmd`: launch with plain `julia` instead of `julia +release`
  so the app runs on machines without juliaup (a standalone `julia.exe`
  treats `+release` as a bad path and errors). Now also auto-loads a
  prebuilt sysimage via `--sysimage` when `build/OpenJFEM_sysimage.dll`
  exists, for near-instant startup, and falls back to a normal start when
  it does not. The `build_sysimage/` helper scripts build that sysimage
  once per machine via `tools/deploy_fast.jl` (the `.dll` is git-ignored
  and machine-specific).
- `POST/panel_app.html`: clicking "Analyze (SOL 105)" now shows a modal
  overlay with a spinner and a live elapsed-seconds counter (updates
  10x/sec) while the solver runs; it closes automatically when results are
  ready or on error.
- `POST/` web app can now run an arbitrary deck, not just the form-built
  stiffened panel. A sidebar "Analysis source" toggle switches between
  "Build stiffened panel" (unchanged) and "Run a .bdf file", where the user
  gives a server-side path to a `.bdf`/`.dat`/`.nas` deck. The deck runs in
  place so its `INCLUDE` cards resolve, and the solution sequence (SOL 101
  static, 103 modes, 105 buckling, 106 nonlinear) is auto-detected from the
  deck rather than assumed. `panel_server.jl` is now SOL-agnostic: it reads
  the matching results JSON per SOL (`.JU.JSON` / `.BUCKLING.JSON` /
  `.NONLINEAR.JSON`), returns `sol`, `analysis_type`, eigenvalues,
  frequencies, and the markdown report, and the 3D viewer labels results by
  type (mode frequency for SOL 103, buckling factor for SOL 105, static
  deformation for SOL 101/106). Fixes a latent bug where the one-case
  manifest used the key `options` instead of `output_options`, which had
  suppressed the results JSON and stored mode-shape eigenvectors.
- `solver/assembly.assemble_stiffness`: PSHELL MAT2/MAT8 elements with
  `MCID > 0` now follow the same THETA/MCID material-axis rotation path
  used by PCOMP. Adds two tracking arrays (`q4_el_theta`, `q4_el_mcid`)
  and a new rotation branch for Cm, Cb, Cs, and Bmb under the element
  material frame.
- `Reference_documentation/`: author and affiliation corrected on all
  four external-talk PDFs (`agentic_coding_lessons.pdf`,
  `agentic_numerical_software_report.pdf`,
  `gpu_workstation_pitch.pdf`, `jfem_openludwig_overview.pdf`).
  Author now reads "Raul Llamas-Sandin, Universidad de Sevilla".

### Added (continued)
- `Reference_documentation/`: PowerPoint companions to the three external
  talks published as PDFs (`Engineering_Autonomy.pptx`,
  `JFEM_Solver_Architecture.pptx`, `Local_GPU_Workstation_Proposal.pptx`).

### Changed
- `solver/assembly`: new `pshell_bending_constitutive_matrix` helper that
  builds the shell bending constitutive matrix C_b for PSHELL/PCOMP with
  proper handling of MAT1, MAT2 (anisotropic), and PCOMP_CLT including
  theta rotation. Two new env-var gates: `JFEM_PSHELL_USE_MID2_BENDING`
  (when true, use the MID2 material for bending separately from the
  membrane material) and `JFEM_SOL101_PSHELL_MAT2_CB_SCALE` (scale factor
  for MAT2 bending under SOL 101). New tracking array `q4_pshell_mat2`.

### Added (continued)
- `Reference_documentation/` now publishes three additional PDFs sourced
  from `04_DOCUMENTATION_IN_WORK/`:
  `jfem_openludwig_overview.pdf`, `agentic_coding_lessons.pdf`,
  `gpu_workstation_pitch.pdf` (plus a duplicate
  `agentic_coding_lessons copy.pdf`).
- `Reference_documentation/README.md` index rewritten to list every
  published PDF (canonical OpenJFEM docs, talks, and pitches) and to
  describe the build-and-sync chain that keeps the folder fresh.

### Changed
- `solver/assembly.assemble_stiffness`: when in SOL 101 context and not in
  shear-centre-only mode, the default Q4 kernel is now `mitc4_3d_aspect`
  instead of the historical `macneal`. Controlled by the new env var
  `JFEM_SOL101_PCOMP_MITC4_3D_ASPECT_DEFAULT` (default `true`).
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
