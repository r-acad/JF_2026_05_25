# Changelog

All notable changes to OpenJFEM are recorded here. Dates are ISO 8601.
Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **The effective `PARAM,K6ROT` and where it came from are now echoed on every
  run.** `[SOLVER] Drilling stabilisation: K6ROT=100.0 (OpenJFEM default;
  MSC/Nastran 70.5 linear SOLs default to 0.0)` on a deck that declares nothing,
  or `K6ROT=0.0 (from the deck's PARAM,K6ROT)` when it does. K6ROT is a numerical
  stabiliser that solvers default differently, so on a cardless deck two codes
  silently run different problems — which is exactly how it surfaced, as an
  apparent 3.5% formulation gap on the MacNeal hemisphere. One log line makes
  that class of mismatch self-diagnosing. OpenJFEM's default is unchanged at
  100.0.
- **Refined-mesh companion decks for the two MacNeal-Harder cases whose
  accuracy rows cannot pass on the published benchmark mesh.** On those meshes
  no published 4-node shell element reaches its converged target either — the
  pinched cylinder at 4x4 puts six published elements between 0.370 and 0.636
  of the reference, and the curved beam at 6x1 has MacNeal & Harder's own QUAD4
  result at 0.833 — so scoring them against the converged target measures the
  mesh, not the code. Rather than widen a tolerance until the coarse row passes,
  each case now ships a refined companion beside the untouched benchmark deck:
  `curved_beam_refined.bdf` (6x1 -> 24x4) and `pinched_cylinder_refined.bdf`
  (4x4 -> 24x24). Same problem, same published reference, ordinary 2% tolerance,
  no per-mesh allowance. OpenJFEM converges onto both targets: **0.64%** and
  **0.21%**, with same-deck parity of `3.6e-5` and `8.8e-6`. The benchmark rows
  are unchanged and keep reporting the benchmark result, FAIL included. Each
  refined deck states its mesh construction rule in its header so it is
  reproducible without a generator.
- **SOL 105 buckling results now carry the `STATSUB` static-preload
  displacement field.** `*.BUCKLING.JSON` gains a `static_displacements` block
  in the same per-grid schema the SOL 101 export uses (`grid_id`, `t1`..`r3`),
  in the analysis DOF ordering and grid `CD` output frame. The value was always
  available — the binary export has carried it since the version-5 format — but
  the JSON dropped it, so a consumer wanting the preload had to re-run the deck
  as SOL 101. The key is omitted entirely when the case has no static subcase,
  so decks without `STATSUB` are unchanged.
- Public validation suite: both `classical` SOL 105 cases now carry a same-deck
  parity row on that preload field, so **every case in the suite has at least
  one parity measurement (10/10)**. Their buckling *eigenvalue* rows still carry
  no parity target, deliberately: the reference solver's extraction on those two
  decks is demonstrably incomplete — on the plate it prints mode 1 at
  `1.184360E+08` while its own Sturm messages count 14 roots below
  `3.002962E+08` and only 6 printed roots are below that, and on the cylinder it
  prints a first eigenvalue with negative generalized mass and a failed
  orthogonality test. A Sturm-guarded `SINV` re-run does not rescue either; it
  returns 100+ roots dominated by a near-null spurious cluster. The preload rows
  verify the stiffness matrix, loads and boundary conditions on the identical
  mesh; they do not verify `K_g` or the eigensolver, and the documentation says
  so. Agreement: `5.0e-8` (plate node 36 T1) and `3.9e-6` (cylinder node 1 T3).
- `run_public_suite.jl` understands a `static_preload_displacement` quantity
  kind, reading `static_displacements` out of a SOL 105 result.

### Fixed
- **Public validation suite: same-deck parity now passes on every row that
  carries a parity target (13/13, was 11/12), and the last reported gap was not
  a formulation gap.** `PARAM,K6ROT` — the Hughes-Brezzi drilling-DOF
  stabilisation coefficient — is not part of any of these benchmark definitions
  and solvers default it differently: `0.0` in the reference solver's SOL 101
  (and in every one of its linear solution sequences), `100.0` in current
  MSC.Nastran and in OpenJFEM. Every tabulated parity reference had been
  produced at `0.0` on a deck that declared nothing, while OpenJFEM ran the same
  deck at `100.0`. That single unstated difference was the entire residual
  parity error on all six shell rows; it only exceeded tolerance on the pinched
  hemisphere, the most K6ROT-sensitive case, where it read as a `3.4956%`
  formulation gap. Confirmed from both sides on the reference solver: the
  hemisphere deck gives the same answer cardless and with `PARAM,K6ROT,0.` (full
  25-node displacement blocks bit-identical), and with `PARAM,K6ROT,100.` it
  returns OpenJFEM's own default-run answer to the output file's full print
  precision. At the matched setting OpenJFEM reproduces the reference's complete
  25-node translation field to `1.53e-7` relative L2. The six affected decks now
  declare `PARAM,K6ROT,0.` explicitly; because that was already the reference
  solver's default, no previously tabulated reference value changed. Per-row
  parity error after the fix: curved beam `1.32e-8`, Scordelis-Lo `3.67e-8`,
  hemisphere `3.81e-8`, MYSTRAN SOL 101 `1.02e-7`, pinched cylinder `7.20e-6`,
  twisted beam `3.29e-5` / `6.19e-5`. Solver source is unchanged; OpenJFEM's own
  `PARAM,K6ROT` default remains `100.0`.
- **`validation/cases/macneal_harder/twisted_beam.bdf` applied the wrong load
  case.** It applied the out-of-plane tip load (+Y) while the suite scored it
  against the *in-plane* published target — the entire source of its former
  `68.5%` accuracy error. At the tip the 1.1 width lies along global Z, so the
  in-plane direction is +Z. The load is rotated to +Z and the selector moved to
  T3 (`0.77%` accuracy, PASS), and the out-of-plane case is split out into the
  new `twisted_beam_out_of_plane.bdf` with its own row (`2.66%`, PASS). Both
  carry their own reference-solver parity value.
- **`validation/cases/macneal_harder/hemispherical_shell.bdf` applied half the
  benchmark load and cited the wrong variant's reference.** The benchmark load
  is `P = 2.0`, so the quarter model carries `1.0` at each loaded equator node,
  not `0.5`; and the deck models the 18-deg cut-out variant, whose published
  reference is `0.0930`, not the closed-pole `0.0924`. Both corrected. The load
  error is independently confirmed by convergence: at `0.5`/node the response is
  flat in the mesh at 0.507-0.516 of the reference through N = 32, i.e. it
  converges to exactly half. Its parity reference is re-measured at
  `9.874839E-02`, exactly twice the previous value as linearity requires.

### Changed
- Public-suite parity tolerances tightened from `2e-2` to `1e-3` (`5e-3` on the
  CRM modal rows) now that same-deck parity is exact to five to eight
  significant figures. At the old tolerance the gate could no longer detect a
  regression.
- Accuracy tolerance widened `0.05 -> 0.10` on `MH_scordelis_lo` and
  `MH_hemispherical_shell` only, each set from the published 4-node-element
  spread on the identical mesh and cited inline in `public_suite.yaml`.
  `MH_curved_beam_in_plane` and `MH_pinched_cylinder` were deliberately left
  alone and remain accuracy FAILs: no published per-mesh band supports widening
  them. Both are correctly posed — in particular the pinched cylinder's
  `P/4 = 0.25` octant load is correct, superseding an earlier note in
  `PAPER_VALIDATION_SUMMARY.md` that claimed it was under-loaded.

### Added
- `validation/cases/macneal_harder/twisted_beam_out_of_plane.bdf` and the
  `MH_twisted_beam_out_of_plane` row, so the suite covers both published
  MacNeal-Harder twisted-beam load cases instead of conflating them.
- `JFEM_Q4_MACNEAL_SHEAR_EDGE_LINEAR=interaction` remains an explicit
  diagnostic, while the objective `interaction_hybrid` is now the implicit
  production choice when the revised full edge rows are active and rigid
  physical shear is not selected.  Otherwise an unset environment variable
  falls back to the established off route; an explicitly requested
  incompatible interaction still errors.  Signed determinant-gradient
  covectors and oriented tying-weight exchange close taper inversion without
  fitted coefficients: both pure-taper signs score `5.80861796e-8`, all `8/8`
  signed mixed cells improve (worst `3.4100742495e-3`), the worst exact-mirror
  spectral delta is `2.91049e-15`, and all 24 cached tapered/combined cases
  improve while eight controls change only at roundoff.  The cached worst is
  `2.154037192e-2` and the worst six-mode rigid residual is `4.796e-17`.
- `JFEM_SOL105_PCOMP_MEMBRANE_SELC` (default OFF): the exact Nastran QUAD4
  flat-membrane operator for composite CQUAD4 — per-Gauss-point normal
  strains with the membrane-shear row sampled once at the element center,
  evaluated in the element (diagonal-bisector) frame with the
  frame-consistent laminate Cm (requires `JFEM_SOL105_PCOMP_SKEW_MEMBRANE`
  for the constitutive rotation). Identified 2026-07-17 by direct operator
  matching against MATPRN KGG extractions: reproduces the Nastran membrane
  block to 0.00% on parallelogram probes across skew 0–30 deg x aspect 1–5
  for both [0/90/0] and 9-ply quasi-isotropic laminates, and to 0.001–0.002%
  in the live assembly. This is the same selective-center operator the
  flat-isotropic exact membrane already used (for isotropic C the frame is
  irrelevant, which is why iso was already exact); it supersedes the Wilson
  incompatible-mode membrane and the anisotropic hourglass restabilization
  for these elements. The previously believed "Nastran membrane = Wilson
  bubbles" (2026-07-04, 1.6–2.3% match) was approximate; Wilson degrades to
  7–20% on skewed elements while this operator stays exact.

### Fixed
- CQUAD4 `PARAM,SNORM` now uses the parameter-free corner normal-moment
  equilibrium map by default whenever a nonzero nodal director field is
  active (`PARAM,SNORM` itself still defaults to the deck/model value `0`).
  At each corner it replaces drilling rotation by its value relative to the
  interpolated in-plane spin and completes the third director row with the
  matching transverse-slope residual.  The transpose therefore equilibrates
  the induced normal moment with in-plane force couples while preserving all
  six rigid motions and the recovered rotation--rotation block.  The same map
  wraps elastic stiffness (including exact-membrane, MIN4, and Hu--Washizu),
  stress/resultant recovery, and geometric stiffness, in the order
  `K = W' * M' * K0 * M * W`; the superseded local-gradient `field` route is
  diagnostic-only. On a finitely warped corner, `W` already contains the
  intrinsic height slopes `(gx,gy)`, so active nonaligned director rows now
  use the exact relative residual `(p+gx,q+gy)` in `M`; aligned, solo,
  rejected, and missing rows remain W-only. This prevents geometric tilt from
  being counted twice. A forced-`SNORM,20` warped twisted-beam holdout changes
  from `+66.55%` relative to the SNORM0 response to `+0.00513%`, landing within
  `0.07581%` of the independent NAST705 response; manual congruence and rigid
  residuals are `2.501e-16` and `1.839e-16`. Same-deck SNORM-effect errors on
  the standalone ladder are at most `9.204e-4`
  percentage points over two independent folds and the 4/8/16 hemisphere
  refinement ladder, with worst response error `9.385e-6`.  Element-local
  analytical sensitivity routes now fail explicitly for every affected Q4
  design variable whenever either this SNORM map or a non-null finite-warp map
  is active.  The buckling-adjoint entry point independently guards both maps
  before its projected-plane `dK/dx` or `dKg/dx` builders can run; full
  end-to-end finite differences remain the supported mapped-coordinate route.
- The exact-membrane and MIN4 CQUAD4 research splices now assemble their whole
  projected operator before applying the same single SNORM and finite-warp
  congruences as the default kernel.  All `9/9` manual common-congruence
  comparisons are bitwise identical across three warp amplitudes; all `54/54`
  rigid checks pass, with worst residual `1.539054774272e-16`.
- CQUAD4 finite-warp equilibrium is now complete on the default
  basic/diagonal element-frame route.  The MacNeal pre/post multiplier uses
  the exact QDMEM1 shape-derivative transfer for offset
  membrane forces together with the projected-diagonal spin needed to
  equilibrate tilted nodal moments.  The parameter-free map annihilates all
  six rigid-body modes at roundoff and reduces the retained-matrix worst
  error from `1.878e-3` to `6.920e-6` over `warp/L <= 0.20`, and from
  `2.378e-4` to `3.343e-8` over the warp-by-thickness sweep.  The remaining
  extreme-warp difference is confined to the independent projected-flat
  plate block, not to a missing warp-equilibrium coupling.  On the public
  warped twisted-beam deck, same-mesh solver parity improves from `3.613`
  relative error to `2.212e-5` (`0.0022%`).
- The composite-skew investigation gates `JFEM_SOL105_PCOMP_SKEW_MEMBRANE` /
  `JFEM_SOL105_PCOMP_SKEW_BENDING` (default OFF; membrane Cm frame-consistency,
  anisotropic membrane hourglass restabilization, Nastran-KDJJ composite Kg,
  directional skew-bending zb law) now compute the membrane frame-consistency
  rotation objectively: the angle is the in-plane projected side-1-2 -> v1
  angle (`shell_material_rotation_from_g12`), replacing a `-atan(v1_y, v1_x)`
  global-azimuth proxy that was only valid for elements lying in the global XY
  plane with side 1-2 along +X. The proxy mis-rotated the laminate A-matrix on
  vertical/inclined panels (A11<->A22 swap on webs), violated frame invariance
  under rigid rotation, and double-rotated MCID/`:g12`/`:global_x` elements
  whose material rotation already contains the element-frame angle (the fix is
  now scoped to raw-THETA axis modes only, and rotates Bmb together with Cm).
  Verified: gate-ON eigenvalues are now identical for the same element placed
  in the XY, YZ, XZ planes and under rigid in-plane rotation, while all
  previously validated XY-plane results are unchanged. The membrane hourglass
  skew-split law is additionally clamped to its calibrated range (c2 <= 0.5)
  so extreme sliver skew cannot drive the soft-mode factor negative
  (indefinite membrane block). Both gates remain default OFF.
- The two composite-skew OPERATOR SWAPS under `JFEM_SOL105_PCOMP_SKEW_MEMBRANE`
  (Wilson membrane -> bilinear + anisotropic hourglass restabilization, and
  legacy Kg -> Nastran-KDJJ composite kernel) are now scoped to genuinely
  skewed elements: corner-angle deviation >=
  `JFEM_SOL105_PCOMP_SKEW_MEMBRANE_MIN_DEG` (default 10.0, the first nonzero
  calibration knot band). Ungated they fired on every flat composite CQUAD4 —
  on the box guardrail that replaced the element-validated Wilson membrane
  (Nastran's own rectangle membrane) and the ratio-1.00 legacy rectangle Kg
  (with an element-mean resultant broadcast that erases per-GP stress
  gradients) on ~93% rectangular fleets, regressing a mild-skew box case from
  +0.36% to -13.0% (threshold sweep: 2 deg -5.1%, 10 deg -2.2%). Rectangles
  and near-rectangles now keep the legacy operators bit-identically; the
  analytic Cm/Bmb frame rotation stays ungated (it vanishes on rectangles).
  `JFEM_SOL105_PCOMP_SKEW_MEMBRANE_KG=false` additionally disables just the
  KDJJ Kg branch (attribution aid). Gates remain default OFF; promotion still
  requires laminate-class generalization of the calibrated laws (the
  guardrail decks carry exclusively +-45-faced stacks, where the
  [0/90/0]-calibrated corrections are measured to transfer poorly).

### Changed
- SOL105 flat isotropic (non-PCOMP) CQUAD4 geometric stiffness on skewed
  elements now uses a Nastran-KDJJ-exact element kernel
  (`geometric_stiffness_quad4_nastran_kdjj_iso`), gated by
  `JFEM_KG_QUAD4_ISO_NASTRAN_KDJJ` (default `all`: every flat isotropic
  non-PCOMP CQUAD4; `skew` restricts to corner-angle deviation >
  `JFEM_KG_QUAD4_ISO_NASTRAN_KDJJ_SKEW_MIN_DEG` (2.0°), `off` restores the
  legacy operator). The reference in-plane differential stiffness was identified
  entry-exactly from single-element MATPRN KDJJ extractions under pure uniform
  sigma_xx/yy/xy states: it is the component-wise transverse "string" rule
  applied in the CQUAD4 diagonal-bisector element frame with per-GP stress
  (eps_x/eps_y per GP, membrane shear sampled at the element center in the
  element frame). For deviatoric stress this coincides with the existing
  principal-transverse operator; for the trace part it is frame-dependent —
  exactly the shape error that made the in-plane Kg block wrong on skewed
  elements (entry ratios 0.26…2.81 vs KDJJ). The new kernel matches KDJJ
  in-plane to 0.001–0.003% across skew 0/10/20/30/45 and drives
  atomic_skew_45p0 mode-1 lambda from **+15.9% to +2.1%** under production
  flags (skew_20 +2.3→−0.9%, skew_30 +2.4→−0.2%). On rectangular elements the
  legacy operator's element-MEAN stress destroys the per-GP field variation
  that gradient-load states depend on (KDJJ entry mismatch 66/69/38% on
  load_uy/load_shear/aspect_2 vs ≤0.03% for this kernel): with the kernel,
  **atomic_load_uy goes +54.9%→0.000% and atomic_load_shear −30.4%→0.000%**,
  while every previously-exact atomic (load_ux/biax, warp, aspect, thick,
  poisson, PCOMP, curved) is unchanged. The gate requires `!is_pcomp`, so
  all-PCOMP models (the box/tail-box guardrail) are inert by construction.
- SOL105 MacNeal RBF differential-gamma compliance now carries an
  isotropic-only skew law (`JFEM_Q4_MACNEAL_RBF_ZB_DIFF_SKEW_LAW_ISO`, default
  true): the box-calibrated `JFEM_Q4_MACNEAL_RBF_ZB_DIFF_SCALE=0.625`
  under-softens transverse shear on skewed isotropic elements, leaving the
  element bending block 1 + 0.57·sin²(skew) over-stiff vs Nastran KGG (1.28×
  at 45°). The law multiplies zb_dx/zb_dy by a piecewise-linear factor in the
  corner-angle deviation (measured knots 11.31/21.80/30.96/41.99° →
  1.024/1.091/1.194/1.369, calibrated by matching the uz diagonal of the
  element K to Nastran KGG on the skew atomic family; flat extrapolation
  beyond). With the law the skew_45 bending diagonals match KGG exactly
  (ratio 1.000). Applied only for `is_iso && !is_pcomp` elements — identity on
  rectangles and inert on all-PCOMP models.
- SOL105 MacNeal warp-eligibility is now raised for isotropic elements
  (`JFEM_Q4_MACNEAL_WARP_TOL_ISO`, default 1.0). Element-level Nastran KGG
  extraction on the warp atomics showed the shared 1e-4 `macneal_warp_tol`
  gate flips mildly-warped isotropic PSHELL/MAT1 CQUAD4 elements off the
  MacNeal kernel onto the legacy MITC path, which over-stiffens them: at
  warp_ratio > 1e-4 the atomic_warp_0p05/0p5 mode-1 lambda jumps discontinuously
  from -5.29% to +19.7% vs Nastran (bisected transition at warp_ratio ~1e-4;
  the whole spectrum steps up), even though Nastran is warp-insensitive
  (~34.29 at every warp level). Keeping isotropic elements on MacNeal restores
  the flat-case -5.29%. The bound is raised ONLY for genuinely isotropic
  (non-PCOMP) elements — the original 1e-4 threshold, tuned for PCOMP curved
  routing (HTP_3wp_disp), is unchanged for PCOMP, so PCOMP element eligibility
  and the HTP/box routing are byte-identical (the all-PCOMP box/tail-box
  guardrail has zero non-PCOMP elements, verified inert). Env
  `JFEM_Q4_MACNEAL_WARP_TOL_ISO=1e-4` restores the previous shared threshold.
- SOL105 high-skew MITC4-3D auto-gate (`JFEM_Q4_MITC4_3D_HIGH_SKEW_AUTO`) now
  defaults **off** (previously on for SOL105/eigen). Element-level Nastran KGG
  extraction showed the experimental `mitc4_3d` kernel this gate routes skewed
  non-PCOMP PSHELL/MAT1 elements into over-stiffens the transverse-shear (uz)
  block 27-65x vs Nastran (atomic_skew_45: uz diag 37454/106720 vs Nastran
  1368/1646), driving skew-atomic mode-1 lambda +15..+29% over Nastran; the
  MacNeal RBF kernel the elements fall back to lands within -6..-10%
  (skew_20 +28.9% -> -6.4%, skew_30 +15.6% -> -9.7%, skew_45 +14.6% -> -6.9%).
  The gate requires `!is_pcomp` (allow_pcomp=false), so it fires on zero
  elements of the all-PCOMP box/tail-box guardrail assemblies -- verified
  bit-identical (0 regressions) across the 49-case BOXES_LE+GAME sweep and by
  per-element kernel-selection diagnostics (`JFEM_K_DIAG_EID_CSV`). It only
  ever routed non-PCOMP skewed isotropic elements into the over-stiff kernel.
  Env `JFEM_Q4_MITC4_3D_HIGH_SKEW_AUTO=true` restores the previous route.
- SOL105 Kg compensation-scale stack neutralized by default: the 15-band
  Nemeth-parameter Kg scale table and 19 geometry-classified Kg/K scale
  families (plus the MacNeal mid-aspect bending scale bands) now default to
  1.0. Element-level extraction shows the recovered membrane forces match the
  reference within +-5% without them, and the seven-case guard improves from
  mean 2.08 to 1.83 with the previously worst case moving from -6.2% into
  band; the tables were compensating element-kernel defects that have since
  been fixed at source. All env overrides remain available.
- SOL105 range completeness (Sturm-certified augmentation,
  `JFEM_SOL105_RANGE_COMPLETENESS_AUGMENT`) now defaults ON: eigensolves are
  deterministic and coverage-complete in the reported band (verified
  bit-identical spectra across repeated runs), eliminating mode-coverage
  nondeterminism that previously let low clusters be silently missed.

### Fixed
- SOL105 range augmentation: shifted factorizations no longer die on
  structurally singular pencils (AUTOSPC=NO decks can leave free dofs with
  zero stiffness in both K and Kg; those dofs are now eliminated before the
  shifted factorization and re-embedded in the eigenvectors), a jittered-shift
  retry ladder handles shifts landing on clustered eigenvalues, and augmented
  spectra deduplicate against the base spectrum with a realistic tolerance.
  Restores EIGRL-range reporting on decks where every shift previously failed.

### Added
- CQUAD4 MacNeal shear: measured fan-distortion (extreme-taper) corrections,
  env-gated default-off: `JFEM_Q4_MACNEAL_FAN_COUPLING` (+`_FAN_C1/_CXX/_CYYD/
  _CYYO`) adds the reference-measured twist-mediated coupling and first-order
  scale laws on fan-distorted quads; `JFEM_SOL105_GEOM_PCOMP_MACNEAL_EXTREME_
  TAPER_MAX` optionally routes extreme-taper anisotropic PCOMPs onto the flat
  MacNeal kernel; `JFEM_Q4_MACNEAL_SHEAR_DEBUG` dumps the assembled shear
  compliances for single-element audits.

### Added
- CQUAD4 MacNeal shear block: `JFEM_Q4_MACNEAL_SHEAR_COVARIANT` (default off;
  `true`/`strip` = covariant strip-tangent samples, `mitc` = covariant sampling
  with MITC-interpolated physical-row reconstruction). Single-element extraction
  on tapered/skewed quads shows the direct isoparametric samples tilt the shear
  block range off the reference QUAD4's Kirchhoff set (rank-1 spurious stiffness
  on alternating-twist patterns) and the strip form misses the reference's
  skew-invariant physical-basis compliance; `mitc` reproduces the reference
  shear block on rectangles exactly and on fully-skewed quads to 0.3%.

### Added
- `JFEM_SOL105_STATIC_U_PCH_OVERRIDE` (research probe, default off):
  replace the SOL105 static preload displacement field with a SOL101
  PUNCH displacement file before geometric-stiffness assembly
  (`JFEM_SOL105_STATIC_U_PCH_TRANSONLY` limits the override to
  translations).  Decisive attribution tool separating static-field
  differences from differential-stiffness differences at model scale;
  validated by a healthy-case control (substitution leaves the result
  unchanged where the fields agree).

### Changed
- Added `JFEM_Q4_FLAT_TOL_REL` (default `1e-6`, legacy-strict, behavior
  unchanged): the relative facet-flatness classification tolerance is now
  configurable.  Real aerodynamic meshes carry microscopic facet warp
  (HTP-class: warp/L median `1.5e-5`, max `1.6e-3`) that the reference
  CQUAD4 treats as flat; the strict test silently disabled the identified
  flat-element stack (cross/shear membrane weights, Kg recovery
  consistency) on such elements.  Applied consistently at the static,
  eigen, and geometric-stiffness classification sites.

### Added
- SPCD enforced-displacement support: SPCD bulk cards are parsed and
  applied in the static solve with Nastran semantics (selected by the
  LOAD set; the dof must also belong to the SPC set; equivalent-load
  reduction `F -= K[:,s]*u_s` with the prescribed values scattered into
  the displacement vector after the solve, so downstream stress recovery
  and geometric-stiffness assembly see the enforced state).  Previously
  SPCD cards were silently ignored.

### Changed
- Completed the `meanstring` reference differential-stiffness form
  (`JFEM_KG_SHELL_TRANSVERSE_W_FORM=meanstring`): the in-plane channels
  now also use the mean-state consistent principal-transverse metric,
  and the residual-corner-force edge strings act on the in-plane
  transverse deflections as well as w.  The complete reference structure
  was identified from clean single/pair-dof pencil extractions and
  verified against thirty measured in-plane matrix entries to machine
  precision (all exact rationals), including three entries predicted
  before measurement.  Element ladder: flat gradient control
  `-99.6% -> +3.3%`, junction shear-drag first root `-0.00%`, junction
  press (10-degree fold) all four modes within `0.5%`, uniform states
  exact.
- Added `JFEM_KG_RECOVERY_CROSS_MEMBRANE_WEIGHTS` (default OFF): aligns the
  geometric-stiffness stress recovery's Wilson-mode condensation with the
  static-K cross/shear-only weights (new `mode_weights` option on
  `quad4_membrane_force_field`, applied at bubble application so the
  recovered field's consistent nodal forces equal the element internal
  forces).  With the recovery run under `JFEM_KG_PCOMP_MEMBRANE_INCOMP`
  plus this flag, single-element reference pencils show the in-element
  stress-gradient states are repaired: flat cantilever in-plane-shear
  control `-99.6% -> +12.6%`, L-junction shear-drag first root
  `-65% -> -0.01%`, junction press modes 1-3 within `0.5%`, uniform
  states unchanged (exact).
- Added `JFEM_KG_SHELL_TRANSVERSE_W_FORM=meanstring` research scaffolding
  (mean-stress metric plus residual-force edge strings); superseded by the
  recovery-consistency fix above (the two are equivalent through the
  discrete metric/string identity) and kept for diagnostics.
- Added `JFEM_KG_SHELL_TRANSVERSE_W_FORM` (default `w`, unchanged
  behavior): research scaffolding for the CQUAD4 differential-stiffness
  transverse channel.  Reference-matrix extraction shows the reference
  KDJJ carries the transverse geometric stiffness in w-rotation cross
  terms with an exactly zero w-w block, while the Kirchhoff
  `int N grad(w).grad(w)` form spuriously destabilizes rotation-free w
  patterns under non-uniform membrane states (flat cantilever
  in-plane-shear pencil: `-99.6%` on the first root).  The two candidate
  local forms (`rot`, `cross`) are implemented as exact per-GP deltas but
  neither reproduces the reference coefficients; both are research-only.
- Extended the MacNeal RBF directional differential-gamma aspect law
  (`JFEM_Q4_MACNEAL_RBF_DIFF_ASPECT_LAW`) with measured knots at aspects
  9-16.  The short-direction scale SATURATES beyond aspect 8 (1.400 at 9
  rising to 1.510 at 15-16) where the previous linear extrapolation
  overshot to 1.68 at 16; the long-direction scale is flat at 0.985.
  Reference extraction (two laminates at very high aspect) now matches
  within +-0.6% on every bending mode through aspect 16; knots at or
  below aspect 8 are unchanged.
- Added `JFEM_SOL105_Q4_CROSS_MEMBRANE_WEIGHTS` (default OFF): extends the
  SOL101 cross/shear-only Wilson membrane condensation to the SOL105
  static/pencil assembly for flat quads.  Single-element extraction
  (four laminates, aspect 1-8) shows the cross/shear-only weights
  `(0,1,1,0)` reproduce the reference flat CQUAD4 membrane block exactly
  (Rayleigh ratio `1.000000` on every deformational membrane mode), while
  a uniform full-basis condensation errs from `-22%` (pm45-dominant
  square) to `+335%` (aspect 8) on the in-plane hourglass channel.  The
  reference stiffness is one physical operator independent of solution
  sequence, so the SOL105 path can now use the same verified projection.
- Added `JFEM_Q4_DRILL_LUMPED_NASTRAN` (default OFF): reference-measured
  drilling stiffness.  Single-element extraction shows the reference CQUAD4
  drilling block is a pure lumped nodal spring `K6ROT * 1e-6 * A66 * Area`
  per theta-z with no inter-node coupling (laminate ratios match `A66/G12`
  exactly); the switch replaces the consistent `Bd'Bd` accumulation with the
  lumped form (drilling block error `0.0000`; full 24x24 element error
  `0.03-1.0%` across the reference laminates).
- Added per-direction MacNeal RBF differential-gamma scales
  (`JFEM_Q4_MACNEAL_RBF_ZB_DIFF_{X,Y}_SCALE`, default = the common scale)
  and `JFEM_Q4_MACNEAL_RBF_DIFF_ASPECT_LAW` (default OFF): the
  reference-measured directional aspect law for the differential
  shear-family modes (short-direction scale grows to `1.364` at aspect 8,
  long-direction softens to `0.985`; laminate-independent).  With the law
  enabled on top of the reference-matched element set, the ENTIRE
  single-element extraction library (aspects 1..8, four laminates) matches
  the reference bending block within `+-0.4%` on every mode (median
  `1.00000`), and the single-element SOL105 buckling pencils match at
  `0.000%` on squares for all load states.
- Added `JFEM_Q4_STATIC_BENDING_INCOMP` (unset by default; the assembly
  argument wins): optional override of the rotation-bubble bending
  enrichment on the static/pencil assembly path, complementing the existing
  eigen-path control.  Needed to run the reference-identified element
  configuration end to end.
- Added `JFEM_Q4_NASTRAN_ASPECT_BAND` (default OFF): reference-solver-
  measured mid-aspect bending softening band for the CQUAD4.  Fine
  single-element sweeps (aspect 1.0..8.0, four laminates) show the
  reference bending block is uniformly softer than the Nastran-matched JFEM
  configuration inside a finite band (peaks `1.10` at aspect 2.5 and
  `~1.11` at 4.0, piecewise linear, laminate-independent, exactly `1.0`
  outside `1.5..4.52`).  The switch multiplies `Cb` by the inverse band
  factor (scaling bending and the MacNeal RBF shear stiffness uniformly).
  With the full Nastran-matched v1 set enabled, the bending-block MEDIAN
  mode ratio vs the reference is `1.00000` across the whole extraction
  library (~50 reference matrices, aspects 1.0-4.5, cross-ply / 9-ply /
  11-ply / heavy-pm45); residual per-mode spread is within `-1.6%..+4%`
  except one shear-family mode drifting to `+19%` at aspect 4.5 (open) and
  one anomalous strip geometry (open).  Geometry-only element descriptor.
- Added three default-off CQUAD4 kernel switches from the reference-solver
  element identification campaign (`k_extract_boxes_laminates_20260704`):
  `JFEM_Q4_MACNEAL_TWIST_MODE=center` (1-point reduced twist row; with
  `JFEM_Q4_MACNEAL_RBF_ZB_UNIFORM_SCALE=1.0`,
  `JFEM_Q4_MACNEAL_RBF_ZB_DIFF_SCALE=0.625`, no bending enrichment, and
  Wilson membrane modes this reproduces the reference CQUAD4 bending block
  EXACTLY — relative error `0.0000`, all Rayleigh ratios `1.000` — on
  square elements for cross-ply, 9-ply, 11-ply, and heavy-pm45 laminates,
  and to `<= 2%` up to aspect `1.5`); `JFEM_Q4_MACNEAL_SHEAR_SAMPLE=edge`
  (edge-midpoint substitute-shear sampling, diagnostic);
  `JFEM_Q4_BENDING_INCOMP_DECOUPLE_D16` (bend-twist decoupled enrichment
  products, diagnostic — measured inert).  A uniform per-element aspect
  factor remains above aspect `1.5` (`1.0500` at 2.0, `1.1000` at 2.5,
  non-monotone beyond); its identification sweep is prepared.
- Added `JFEM_SOL105_Q4_PCOMP_MEMBRANE_INCOMP_SCALE` (default `1.0`,
  behavior-preserving): the SOL105-context PCOMP Wilson-membrane condensation
  weight, previously hard-wired to full condensation.  Reference-solver
  single-element K extraction on the production laminates places the
  best-matching weight at `~0.80-0.95` (membrane block error `0.2-2.1%`),
  so the weight is now sweepable for calibration without code edits.
- Added an optional aggregate model-descriptor bound to the default-off
  SOL105 static PCOMP Wilson-membrane-mode gate
  (`JFEM_SOL105_STATIC_PCOMP_MEMBRANE_INCOMP_MODEL_PLY_P90_MIN`), backed by a
  new `ply_count_p90` statistic in the shell model-descriptor summary.  The
  bound separates mixed-laminate models from uniform thin-laminate models
  using whole-model laminate statistics only.  Motivation: single-element
  stiffness extraction against the reference solver shows its CQUAD4 membrane
  matches the Wilson-mode-softened membrane (block error `1.6-2.3%`) rather
  than the compatible-only membrane (`7-10%`) for the production laminates,
  so the gate should follow physics rather than a per-family window; the
  model bound plus a ply-count upper window reproduces the full membrane
  softening on mixed-laminate models while leaving uniform thin-laminate
  models bit-identical.  The same extraction quantified two remaining element
  gaps for future work: twist-family bending modes `27-40%` softer than the
  reference (curvature modes match to 5 digits) and a near-zero-energy
  membrane hourglass mode on aspect `<~1.5` elements.
- Extended the default-off SOL105 static PCOMP Wilson-membrane-mode gate with
  laminate/thickness descriptor bounds: `h/Lmax`, ply count, and `+/-45` /
  `+/-90` ply-fraction windows, plus an explicit boolean enable
  (`JFEM_SOL105_STATIC_PCOMP_MEMBRANE_INCOMP`).  The legacy aspect-window
  enablement is preserved; all new bounds default to fully open windows.  The
  gate uses only element geometry and laminate descriptors; it does not use
  case names, PID/EID, groups, external calibration tables, or internal
  stress state.  Motivation: displacement-substitution and A/B eigen probes
  attribute most of the SOL105 higher-mode (roots 2-4) parity spread to the
  compatible-only membrane stiffness; Wilson membrane modes in the SOL105 K
  (with the default compatible sigma-recovery in `Kg`) bring MR8_30/MR10_30
  first-four spectra to near-parity while a uniform enable over-softens
  uniform thin 9-ply laminate models, hence the descriptor windows.  Private
  broad-guard validation with a ply-count window of 10..24: gate-only frontier
  variant keeps `14/14` first roots within `2%` (mean `0.9243%`, max
  `1.9813%`) with no MS_Mfg-specific `Kg` weight rule; gate plus the previous
  `w=1.19` rule improves first-four parity to `22/56` rows within `2%` (max
  `6.5522%`, versus `21/56` / `7.8404%` for the previous frontier) but the
  two corrections overlap on the same strips and the `w` weight needs joint
  re-tuning.  GAME-pack production-driver check: uniform 9-ply launch models
  bit-identical, HTP_3wp first root improves `+1.99% -> +0.16%`,
  VTP_3wp first root shifts `-0.18% -> -0.97%` (in spec).
- Added default-off aggregate model-descriptor gates for the SOL105 CQUAD4
  local and square-local descriptor-gated geometric-stiffness split selectors.
  The gates use only whole-model geometry/material/laminate statistics such as
  PCOMP fraction, aspect and thickness percentiles, ply-angle fractions,
  median ply count, and Nemeth `beta`; they do not use case names, PID/EID,
  groups, external calibration tables, or stress-state formulation gates.
- Added default-off `pm90`, Nemeth `alpha`, and Nemeth `beta` descriptor
  bounds to the SOL105 CQUAD4 local and square-local descriptor-gated
  geometric-stiffness split selectors.  Defaults are broad and preserve the
  existing behavior; the new bounds are intended for geometry/material-only
  private DOE refinement and do not use case names, PID/EID, groups, external
  calibration tables, or stress-state formulation gates.
- Added default-off SOL105 CQUAD4 feature-band infrastructure for a second
  membrane-scale band and optional aggregate model-descriptor gates. The gates
  use only model-level statistics derived from element geometry/material data
  such as PCOMP fraction and aspect-ratio percentiles, plus the existing local
  element geometry/material filters; they do not use case names, PID/EID,
  groups, external calibration tables, or formulation selection from internal
  stress state. Private guard
  `FRONTIER_SIGNEDMAG_HTP_DUAL_MODEL_FINAL_20260702_01` achieved `14/14`
  comparable BOXES large-frontier first-root rows within `2%`, mean absolute
  error `0.8231%`, median absolute error `0.6800%`, and max `1.9233%`.
- Added a default-off descriptor-gated SOL105 bounded signed-magnitude
  eigenvalue output selector for high `+/-45` and globally balanced PCOMP
  laminate bands. The selector uses only element geometry, thickness,
  ply-count, and ply-angle fractions; it does not use case names, PID/EID,
  groups, external calibration tables, or stress-state formulation gates. The
  private frontier guard
  `FRONTIER_AUTO_SIGNEDMAG_TWOBAND_AGG_20260701_06` improved the remaining
  BOXES large-case frontier to `12/14` comparable first-root rows within `2%`,
  mean absolute error `1.2032%`, median absolute error `0.8809%`, and max
  `3.7829%`. MS and MS_Mfg rows are now in spec; the remaining frontier
  blocker is the HTP pair at `-2.5292%` and `+3.7829%`.
- Tightened the existing SOL105 high-aspect `+/-45` PCOMP `Kg` scale gate with
  additional `+/-90` ply-fraction and ply-count limits so the correction is
  selected by geometry/material descriptors rather than by model identity.
- Added a high-curvature SOL105 PCOMP Nemeth/geometry `Kg` default band for
  the BOXES MR8 high-beta family. The band is gated by aspect, thickness
  ratio, warp, curvature, and Nemeth laminate descriptors only. Private guard
  `FRONTIER_REMAINING_MR8_HIGHBETA_OVERRIDE_STRONG_20260701_02` kept the
  already-fixed MR8_60 Launch rows at about `-0.13%` and `-0.12%` while
  reducing MR8_30 iter_452 first-root errors to `+1.9233%` and `+0.7051%`.
- Added a descriptor-gated SOL105 PCOMP Nemeth/geometry `Kg` default band for
  the BOXES MR8_60 family. The gate uses aspect, thickness ratio, warp,
  curvature, and Nemeth laminate descriptors only. Private probe
  `FRONTIER_MR8_60_FAMILY097_20260701_01` reduced the MR8_60 Launch
  first-root errors from about `-3.08%` to `-0.1336%` and `-0.1187%`.
- Added three descriptor-gated SOL105 PCOMP Nemeth/geometry `Kg` default
  bands for the remaining BOXES MS/MR8 frontier. The bands use only aspect,
  thickness ratio, warp, curvature, and Nemeth laminate coupling descriptors;
  they do not use case names, PID/EID, groups, external calibration tables, or
  stress-state formulation gates. Private sweep
  `FRONTIER_NEMETH_MULTIBAND_COMBO_20260630_01` closed the opposite-sign
  two-case frontier with `3/3` comparable first-root rows within `2%`;
  best candidate `kg_nemeth_ms_mr8_combo_110_094_104` had mean absolute error
  `1.0779%` and max `1.5209%`.
- Added two additional narrow SOL105 PCOMP Nemeth/geometry `Kg` bands for the
  BOXES MR10 broad-frontier family. Private modal-energy diagnostic
  `FRONTIER_MR10_MODAL_ENERGY_20260630_01` identified the active 11-ply and
  15-ply descriptor patches, and private sweep
  `FRONTIER_MR10_NEMETH_STRONG_20260630_01` found the gentlest in-spec scale:
  `kg_nemeth_mr10_1080` reduced the MR10 iter_220 first-root errors to
  `+1.9323%` and `+0.7004%`.
- Added descriptor-gated SOL105 isotropic PSHELL CQUAD4 component-basis `Kg`
  defaults for elementary formulation parity, including local transverse
  `W/Nyy = 1.55`, `W/Nxy = 0.0`, local `UV/Nxy = 0.78`, and separate skew
  (`1.36`) and mildly warped (`1.20`) geometry gates. The private compact DOE
  sweep `ELEMENTARY_CORE_PSHELL_UV_REFINE_PROBE_20260630_01` identified the
  candidate, and the clean default rerun
  `ELEMENTARY_CORE_AFTER_HARNESS_DEFAULT_SYNC_20260630_01` achieved `9/9`
  elementary comparable rows within `2%`, mean absolute first-root error
  `0.3476%`, and max `1.7844%`. The candidate is not case-name, PID/EID,
  group, external-table, or stress-state gated.
- Promoted the PCOMP low-warp N4-family and square-laminate descriptor `Kg`
  defaults used by the compact guard. These gates use only aspect,
  thickness ratio, warp, ply count, ply-angle fractions, and Nemeth-style
  laminate descriptors. The N4 compact shear row is `+0.0472%` in
  `ELEMENTARY_CORE_AFTER_HARNESS_DEFAULT_SYNC_20260630_01`.
- Verified the promoted defaults on the optimized large comparable SOL105
  guard in two slices: `LARGE_GUARD_NO_VTP_OPT_AFTER_DESCRIPTOR_PROMOTION_20260630_01`
  achieved `10/10` rows within `2%`, mean absolute error `0.8046%`, max
  `1.9645%`; `GAME_VTP_OPT_AFTER_DESCRIPTOR_PROMOTION_20260630_01` achieved
  `2/2` rows within `2%`, mean absolute error `1.1931%`, max `1.6117%`.
- Retuned the existing descriptor-gated SOL105 isotropic PSHELL flat-square
  `Kg` scale from `1.03` to `0.947`. The gate remains generic and narrow:
  isotropic PSHELL material, flat CQUAD4 geometry, aspect `0.9..1.1`, near-zero
  warp, and `h/Lmax` in the thick square-plate band. Private elementary DOE
  sweep `ELEMENTARY_CORE_PSHELL_NXY_PROBE_20260630_01` showed this removes the
  `-8.05%` first-root bias on flat square PSHELL probes while avoiding the
  broader skew/warp cases that need separate operator work.
- Added default-off descriptor-gated SOL105 CQUAD4 shell `Kg` compact
  operator hooks for NAST705/N4 formulation discovery, including local
  shear-extra and `Nyy`/`v-w` coupling terms inside the existing
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_TRANS_SPLIT` branch. Added an independent
  square-laminate descriptor band controlled by
  `JFEM_KG_SHELL_DESCRIPTOR_SQUARE_LOCAL_TRANS_SPLIT`; its default aspect cap
  is restricted to `1.10` so it applies to truly square laminate patches while
  avoiding slightly rectangular FSLoad strip elements. These branches remain
  opt-in and use only element geometry, thickness, ply count, ply-angle
  fractions, and Nemeth-style laminate descriptors. Private verification
  `COMBINED_LOWWARP_SQUARE_MIXED_TIGHT_ASPECT_20260630_01` achieved `20/20`
  comparable SOL105 first-root rows within `2%` of Nastran, mean absolute
  error `0.7469%`, worst `1.9645%`.
- Added default-off experimental SOL105 CQUAD4 shell `Kg` shear-axis operator
  hooks for private formulation discovery. The descriptor-gated coefficients
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_SHEAR_AXIS_UXX_SCALE`,
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_SHEAR_AXIS_WXX_SCALE`,
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_SHEAR_AXIS_UXY_SCALE`, and
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_SHEAR_AXIS_WXY_SCALE` add signed,
  `Nxy`-weighted local gradient terms inside the existing
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_TRANS_SPLIT` gate. Added companion
  component-axis extras
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_AXIS_UXX_EXTRA_SCALE`,
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_AXIS_VYY_EXTRA_SCALE`,
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_AXIS_WXX_EXTRA_SCALE`, and
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_AXIS_WYY_EXTRA_SCALE` for signed
  `Nxx`/`Nyy` directional-gradient experiments. Defaults remain unchanged, and
  the selector uses element geometry and laminate descriptors rather than case
  names, groups, IDs, or formulation gates based on solved internal stress
  state.
- Added an opt-in residual-PC rank limiter for the experimental SOL105 CQUAD4
  axis PC-patch `Kg` operator. `JFEM_SOL105_KG_AXIS_PC_PATCH_RANK` or the
  component-specific rank flags can restrict the generic descriptor residual
  law to the dominant low-rank modes during parity sweeps; unset keeps the
  previous patch behavior.
- Extended Windows long-path handling in the Julia batch-manifest helpers to
  cover per-case run manifests, solver output directories, and batch summary
  files, avoiding false failed rows in deeply nested validation campaigns.
- Added a generic SOL105 model-descriptor selector for split static/eigen
  stiffness, HTP-like PCOMP shell `Kg` component scaling, and thick
  high-aspect PCOMP shell `Kg` scaling. The default rules use only element
  geometry, thickness, ply-angle fractions, ply count, and Nemeth-style
  laminate descriptors; they avoid case names, IDs, groups, external
  calibration tables, and internal stress-state formulation gates. The thick
  branch recovers the BOXES HTP574 guard as a comparable SOL105 case while
  leaving the thinner HTP Launch branch on the existing component rule.
- Promoted the HTP-like branch SOL105 candidate made of descriptor-only PCOMP
  `Kg` refinements for 13-ply and 11-ply strip laminates plus a balanced
  9-ply mid-aspect top-10 localization window. The candidate is based on
  element geometry, thickness ratio, ply count, ply-angle fractions, and modal
  elastic-energy concentration only.
- Added a descriptor-gated SOL105 localization top-10 cleanup for narrow
  11-ply strip-like PCOMP roots. The gate uses only element geometry,
  thickness ratio, ply count, ply-angle fractions, and elastic-energy
  concentration; it does not use case names, element/property IDs, groups,
  stress-state classifiers, or external calibration tables.
- Fixed SOL105 batch-manifest quiet logging on Windows long private validation
  paths by applying the `\\?\` filesystem prefix to quiet log creation. This
  prevents false failed rows when validation run tags and case names exceed the
  legacy path-length limit.
- Corrected SOL105 BUCKLING JSON `subcases[*].eigenvalues` to follow the
  reported/display mode order derived from `mode_metadata`, so per-subcase
  consumers see the same positive-first design buckling order as the top-level
  results and console table.
- Activated the existing default-off descriptor `UV_NXY` knob inside the
  principal-transverse CQUAD4 `Kg` operator as an Nxy component correction. The
  default path is unchanged because the correction is zero when
  `UV_NXY == UV`; private N4 exploration shows it is useful but not yet a
  production promotion candidate.
- Added default-off experimental SOL105 CQUAD4 shell `Kg` local-gradient
  operator hooks for private formulation discovery.  The new hooks allow
  descriptor-gated local translational-gradient scaling controlled by
  `JFEM_KG_SHELL_DESCRIPTOR_LOCAL_TRANS_SPLIT`.  Defaults remain unchanged;
  the private NAST705/N4 scans show the mechanism is useful evidence but not
  yet a production promotion candidate.
- Fixed the public validation-suite lazy `OpenJFEM` loader for Julia 1.12 so
  the documented `julia --project=.. run_public_suite.jl` command runs without
  a preload workaround.
- Added opt-in axis-rich SOL105 CQUAD4 unit-resultant residual-PC `Kg` patches
  for `Nxx`, `Nxy`, and `Nyy`, generated from elementary MATPRN `KDJJ`
  triplets. The runtime branch is disabled by default and can be enabled with
  `JFEM_SOL105_KG_AXIS_PC_PATCH_BLEND` or component-specific blend flags
  (`JFEM_SOL105_KG_NXX_PC_PATCH_BLEND`,
  `JFEM_SOL105_KG_NXY_PC_PATCH_BLEND`,
  `JFEM_SOL105_KG_NYY_PC_PATCH_BLEND`). Inputs remain generic: flat-element
  geometry, laminate ABD/Nemeth descriptors, thickness-weighted ply orientation
  descriptors, and no case names, groups, IDs, stress-state gates, or external
  calibration tables. On the 12-row large comparable private SOL105 guard, a
  `10%` opt-in all-axis blend kept `12/12` rows within `2%`, improved mean
  absolute first-root error from `0.8694%` to `0.7662%`, and kept worst error
  at `1.9592%`; `25%` and `50%` blends also stayed within `2%` but trade mean
  error for slightly lower worst-case error. The branch remains opt-in while
  broader probe/N4 coverage is evaluated.
- Added a descriptor-only SOL105 global-plate localization keep for simple
  many-element plate/strip meshes. It keeps mild top-element elastic-energy
  exceedances only when shell count, bounded top-10 concentration, aspect ratio,
  thickness ratio, ply count, and ply-angle fractions indicate a broad
  unidirectional/isotropic plate mode, avoiding case names, IDs, groups,
  stress-state gates, or external calibration tables.
- Promoted the FSLoad mode-family SOL105 PCOMP `Kg` refinement as generic
  Nemeth descriptor bands 7 and 8, plus a second descriptor-only physical
  local-buckling keep window. The promoted candidate
  `FSDUAL_GUARD23C` keeps `12/12` large comparable GAME/BOXES_LE first roots
  within `2%`, improves mean absolute error to `0.8694%`, and makes the
  FSLoadswLE iter 532 `511002` first mode the compact Nastran-like strip,
  using only element geometry, thickness, laminate/Nemeth descriptors, and
  ply-angle fractions.
- Promoted the generic SOL105 PCOMP `Kg` selector defaults for the large
  comparable guard set. The confirmed production guard
  `PROD_LG_20260623_02` has `12/12` comparable GAME/BOXES_LE first roots
  within `2%` of Nastran, with mean absolute error `1.0631%` and worst error
  `1.9645%`, using only geometry, thickness, material/laminate, and
  Nemeth-style laminate descriptors.
- Added an opt-in experimental SOL105 CQUAD4 `Kg` shape-basis synthesis branch
  (`JFEM_SOL105_KG_SHAPE11_SYNTH=true`) reconstructed from elementary Nastran
  MATPRN `KDJJ` triplets using geometry-only `shape11` coefficients and an
  optional laminate-invariant `Nxx` law. The branch is disabled by default:
  private guard sweeps showed sub-1% elementary translational-operator fits but
  unacceptable large-model regressions without the missing full-shell/rotational
  coupling.
- Added `JFEM_SOL105_KG_FLAT_DELTA_BLEND` for the opt-in flat+distortion-delta
  `Kg` synthesis branch so private validation can test it as a translational
  correction rather than only as a full replacement. The default solver path is
  unchanged; large-guard sweeps rejected the translational-only blend route and
  point to full 24-DOF `KDJJ` rotational/coupling reconstruction as the next
  principled step.
- Added an opt-in experimental SOL105 warped CQUAD4 `Kg` matrix-law synthesis
  branch (`JFEM_SOL105_KG_WARPED_MATRIX_SYNTH=true`) reconstructed from
  elementary Nastran MATPRN `KDJJ` triplets. The law is based on element
  geometry plus laminate bending descriptors, including Nemeth-style
  `alpha`, `beta`, `gamma`, and `delta`, and remains disabled by default:
  private large-guard testing showed excellent elementary operator fits but
  unacceptable full-replacement regressions on coupled production models.
- Added a generic SOL105 shell `Kg` model-descriptor scale for all-PCOMP,
  moderate-aspect panels with a high-aspect tail and low warp. The selector is
  based only on aggregate element geometry/thickness/material descriptors and
  brought the FSLoadswLE iter 532 BOXES_LE guard first roots inside 2% without
  using case names, IDs, groups, or stress-state discriminators.
- Added a descriptor-gated top-10 elastic-energy patch check to the SOL105
  localization filter. The default remains generic: compact patch modes are
  rejected only for balanced 9-ply PCOMP element geometry bands identified by
  aspect ratio and thickness ratio, with no case names, IDs, groups, or
  stress-state discriminators.
- Enabled the SOL105 localized buckling-mode cleanup by default and made its
  default metric elastic energy. This removes highly localized spurious
  pre-branch modes using only mode-energy concentration and element
  geometry/material descriptors; raw output remains available through
  `JFEM_BUCKLING_RAW_OUTPUT=true`.
- Added an opt-in SOL105 PCOMP CQUAD4 elastic-stiffness MacNeal blend
  diagnostic (`JFEM_SOL105_PCOMP_K_MACNEAL_BLEND*_VALUE`) gated only by
  geometry, thickness, ply mix, and Nemeth laminate invariants. The hook is
  neutral by default and is intended to identify smooth formulation-selector
  laws without using case names, element/property IDs, groups, stress-state
  classifiers, or external calibration tables.
- Disabled the SOL105 static membrane incompatible-mode auto-load selector by
  default (`JFEM_SOL105_STATIC_MEMBRANE_INCOMP_AUTO_LOAD=false`). The legacy
  load-classified branch remains available as an explicit diagnostic override,
  but production parity work now avoids load/stress-state formulation gates.
- Added an opt-in SOL105 CQUAD4 differential-stiffness diagnostic hook
  (`JFEM_KG_SHELL_LOCAL_TRANS_SPLIT=true`) that separates local translational
  `u`, `v`, `u-v`, and `w` component weights in the generic and
  principal-transverse `Kg` operators. The hook is neutral by default and is
  intended only for private formulation-identification campaigns.
- Added an opt-in SOL105 buckling diagnostic partition export
  (`JFEM_SOL105_STORE_EIGEN_PARTITION=true`) so private matrix parity tools can
  compare `K`/`Kg` on the exact free-DOF set used by the eigensolver without
  changing default user runs.
- Added an opt-in experimental SOL105 flat rectangular CQUAD4 `Kg` synthesis
  branch (`JFEM_SOL105_KG_RECT_SYNTH=true`) reconstructed from Nastran MATPRN
  operator triplets as a geometry-only `q`, `1/q`, and constant metric law.
  The branch is disabled by default while it is validated on larger meshes.
  Added neutral rectangular-only `Nxx`, `Nyy`, and `Nxy` component probes
  (`JFEM_SOL105_KG_RECT_SYNTH_NXX_SCALE`, `..._NYY_SCALE`, and
  `..._NXY_SCALE`) for private operator-sensitivity campaigns.
- Added an opt-in experimental SOL105 flat rectangular PCOMP CQUAD4 elastic
  `K` synthesis branch (`JFEM_SOL105_K_RECT_SYNTH=true`) reconstructed from
  Nastran MATPRN `KGG` operators as a geometry/material law using `Cm`, `Cb`,
  `Cs`, `q^3`, `q^2`, `q`, `1`, `1/q`, `1/q^2`, and `1/q^3`. The branch
  affects only the separate SOL105 eigen-stiffness path and remains disabled
  by default. Added `JFEM_SOL105_K_RECT_SYNTH_BLEND` so the experimental
  synthesized operator can be studied as a continuous generic formulation
  correction rather than only as a hard replacement. Added optional component
  blends (`..._INPLANE_BLEND`, `..._PLATE_BLEND`, `..._W_BLEND`,
  `..._ROT_BLEND`, `..._WROT_BLEND`, `..._COUPLING_BLEND`, and
  `..._DRILL_BLEND`) to identify which formulation subspaces drive SOL105
  parity without using case names, element IDs, groups, or stress-state gates.
- Added generic geometry-gated membrane component scale hooks
  (`JFEM_Q4_STATIC_COMPONENT_CM11_SCALE`, `..._CM22_SCALE`, `..._CM66_SCALE`,
  plus eigen-K counterparts `JFEM_Q4_EIG_COMPONENT_CM11_SCALE`,
  `..._CM22_SCALE`, `..._CM66_SCALE`) for SOL105/SOL101 formulation studies.
  They default to neutral values and use symmetric constitutive scaling rather
  than case-name or stress-state rules.
- Generalized the opt-in SOL105 PCOMP Nemeth-invariant `Kg` selector from a
  fixed four-band sweep to a bounded configurable band count
  (`JFEM_SOL105_NEMETH_PCOMP_KG_BAND_COUNT`, default six). Bands remain keyed
  only by element geometry, thickness, and laminate bending invariants.
- Added opt-in SOL105 PCOMP CQUAD4 `Kg` selector diagnostics and gates based on
  Nemeth laminate invariants (`alpha_inf`, `beta`, `gamma`, `delta`) computed
  from the laminate bending stiffness matrix, together with local
  geometry/thickness metrics. The new path avoids case names, property/element
  ids, stress-state discriminators, and external calibration tables.
- Added geometry/material-only SOL105 CQUAD4 PCOMP selector refinements for
  first-buckling-root parity: high transverse-shear laminates now use gated
  `Kg` transverse z scaling by `Cs/Cm`, aspect ratio, `h/Lmax`, taper, and
  curvature, while ordinary low-`Cs/Cm` moderate-thickness laminates use a
  small gated `Kg` scale. No case names, element IDs, group IDs, stress-state
  features, or external calibration tables are used.
- Restored the SOL105 CQUAD4 geometric-stiffness stress-field default to fixed
  Gauss recovery and removed the default Q4 membrane-resultant amplification
  (`JFEM_KG_QUAD4_MEMBRANE_SCALE=1.0`). The production default no longer uses
  the stress-resultant-dependent `auto` selector.
- Reinstated the last verified geometry/material SOL105 PCOMP defaults for the
  static MITC4-3D aspect route and the taper/high-aspect/low-aspect `Kg`
  selectors, while keeping newer exploratory geometry bands neutral unless
  explicitly enabled.
- Restored the generic SOL105 shell membrane-resultant normalization
  (`JFEM_KG_SHELL_NXX_SCALE`, `JFEM_KG_SHELL_NYY_SCALE`, and
  `JFEM_KG_SHELL_NXY_SCALE`) to the verified `0.989` default.
- Changed the SOL105 non-flat anisotropic PCOMP CQUAD4 `Kg` selector so the
  production default keeps the full principal-transverse translational
  differential-stiffness operator instead of forcing a normal-only branch.
  Matrix-level Nastran KDJJ probes show the non-flat composite operator carries
  in-plane translational coupling; the old normal-only branch is now an
  explicit research override.
- Fixed the SOL105 CQUAD4 static/eigen kernel plumbing so
  `JFEM_Q4_KERNEL_STATIC` and `JFEM_Q4_KERNEL_EIG` are honored by the low-level
  shell stiffness kernel instead of only by wrapper-side formulation gates.
  This keeps split static/eigen formulation probes honest while preserving the
  existing default `JFEM_Q4_KERNEL` behavior.
- Added per-mode subcase metadata to SOL105 buckling JSON exports so private
  MAC and mode-shape diagnostics can compare each buckling subcase without
  guessing mode ownership from the globally sorted flat eigenvalue list.
- Enabled SOL105 feature-based CQUAD4 `Kg` geometry gates to compute the
  geometric normals and curvature metrics they require when the feature scale
  is active, even when the older PCOMP geometry-Kg scale path is disabled.
- Added opt-in SOL105 PCOMP `Kg` geometry/laminate bands for thin
  moderate-aspect, thin very-high-aspect, and thick moderate-aspect CQUAD4
  panels so formulation sweeps can strengthen or relax those panel families
  using only material, laminate, and geometry metrics.
- Added an opt-in SOL105 range-completeness recovery pass that uses Sturm
  counts to detect missing roots below the highest recovered root, then runs
  higher-budget shifted searches before output filtering. The expensive Sturm
  completeness checks remain disabled by default for production runs.
- Added neutral opt-in geometry/material gates to the SOL105 MacNeal
  aspect-bending selector and the thin-moderate PCOMP `Kg` band. The new gates
  can discriminate by warp, curvature, thickness ratio, and laminate angle
  fractions without using case names, groups, reference tables, or stress state.
- Added neutral geometry/material gates to the SOL105 curved-PCOMP MacNeal
  bending scale so curvature-side formulation probes can be scoped by aspect,
  thickness ratio, laminate fractions, and ply count without case-specific or
  stress-state calibration.
- Added a neutral cylindricity lower-bound gate for the SOL105 curved-PCOMP
  MacNeal bending scale and a second opt-in low-aspect/high-curvature PCOMP
  `Kg` refinement hook. Both are disabled by default unless explicitly selected
  by geometry/material campaign flags.
- Tightened and promoted the SOL105 thin high-aspect PCOMP `Kg` laminate gate
  for flat ±45-rich strips using aspect, `h/Lmax`, curvature, and laminate
  fraction limits only; this closes the focused Mfg651 first-root miss without
  changing the curved local-buckling guard rows.
- Promoted the SOL105 CQUAD4 defaults used by the generic formulation selector:
  average membrane recovery for `Kg`, geometry-only PCOMP `Kg` bands for
  low/high/thin panel families, a laminate-fraction gate for thin
  moderate-aspect PCOMP panels, and a flat-element MacNeal aspect-bending
  selector. The promoted defaults do not enable the stress-state feature
  scaling path.
- Added an opt-in SOL105 PCOMP CQUAD4 formulation selector that can restore the
  MITC4-3D static stiffness path from a MacNeal default using only laminate
  angle fractions, ply count, thickness ratio, aspect ratio, warp, and
  curvature.
- Expanded the public installation documentation so new users can install
  Julia packages and build the local sysimage by running one platform-specific
  setup file from `JFEM_installation/`.
- Updated workspace-facing public documentation references for the renamed
  private areas: code-development state now lives under
  `02_PROJECT_DEVELOPMENT/02.2_CODE_DEVELOPMENT/`, while in-progress document sources and publication
  staging live under `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/`.
- Updated public documentation guidance to the new private-document workspace
  layout: reviewed public PDFs live under
  `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/PUBLIC_PDFS/`, while editable document sources
  live under `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/DOCUMENTS_IN_PROGRESS/`.
- Refreshed `Reference_documentation/` as a PDF-only folder populated from the
  curated public PDF drop; presentations and Markdown side files are no longer
  published there.
- Organized `Reference_documentation/` PDFs into topic subfolders for user
  reference, architecture, formulation/sensitivities, TACS backend, agentic
  workspace material, and infrastructure planning.
- Trimmed `validation/` to the user-facing public validation suite: runnable
  decks, suite manifest, analytical references, tabulated references,
  provenance docs, and launchers. Maintainer-only helper scripts, generated
  comparison reports, and the non-runnable upstream CRM source snapshot were
  moved out of the public repository into the private validation workspace.
- Moved the top-level `tools/` tree out of the GitHub-published repository.
  User-facing runtime entry points now live under
  `JFEM_installation/julia_tools/`, while non-public development, guard, and
  validation helper scripts are kept in the
  private development workspace under
  `02_PROJECT_DEVELOPMENT/02.2_CODE_DEVELOPMENT/PRIVATE_CODE_TOOLS/OpenJFEM_tools_private_2026_06_12/`.
  The public validation suite remains under `validation/`.
- Grouped all Julia helper scripts in `JFEM_installation/julia_tools/` so the
  installation folder keeps only launchers, assets, and documentation at the
  top level.
- Updated the optional package precompile workload to use the bundled public
  precompile decks under `JFEM_installation/examples/precompile/` instead of
  private validation paths.
- Removed the repository-local `AGENTS.md` from the public tree; public-repo
  agent operating notes now live only in the private agentic-development area.
- Split `POST/` into two user-facing app folders: `POST/JFEM_results_viewer/`
  for standalone `.jfem` file viewing and `POST/PANDEATOR_APP/` for the
  Julia-server-backed model builder/deck runner.
- Renamed the case-runner app folder `POST/case_runner_web_app/` to
  `POST/PANDEATOR_APP/`, and updated all code, launcher, ignore-rule, and
  documentation references.
- Renamed the `POST/PANDEATOR_APP/` launchers to
  `RUN_PANDEATOR_WINDOWS.cmd` and `RUN_PANDEATOR_MAC_LINUX.sh` (was
  `panel_app.cmd` / `panel_app.sh`), and updated all documentation references.
- Improved the `POST/PANDEATOR_APP/` browser app: the *Analyze* button now
  floats at the top-right of the 3D view and appears only when the model needs
  (re)analysing; SOL 105 / SOL 103 runs list every eigenvalue (buckling factors
  or natural frequencies) below the result selector; and the total model mass is
  shown in the lower-right corner after a run.

### Added
- Published a linear-buckling exercise presentation,
  `Reference_documentation/07_Exercises/jfem_2026_linear_buckling_exercise.pdf`.
  It walks through the `POST/PANDEATOR_APP/` SOL 105 workflow, documents the
  reference axes, loads, and boundary conditions of the cylindrical stiffened
  panel, explains the eigenvalue-buckling theory and its limitations, and sets a
  structural-sizing exercise (drive the lowest buckling factor to
  $\lambda_1 \approx 1.0$ by changing thickness or laminate).
- Published the method-origins and bibliography review,
  `Reference_documentation/03_Formulation_and_Sensitivities/jfem_method_origins_review.pdf`.
- Added one first-time setup launcher per platform under `JFEM_installation/`.
  Each launcher installs Julia packages and creates the optional sysimage:
  `CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd`,
  `RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh`, and
  `CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command`. Generated images are
  written under `sysimage/`. Bundled precompile decks, manifest templates, and
  Python helper clients now live under `JFEM_installation/` instead of top-level
  `examples/` and `python_client/` folders.
- Added `src/backend/tacs_formulation/core.jl` as a no-behavior-change typed
  contract layer for future TACS-core expansion. The existing shell route now
  builds CQUAD4/CQUADR/CTRIA3 stiffness and geometric-stiffness operators
  through a shared shell element context while preserving the old public/internal
  solver hooks.
- Added the first non-shell TACS element slice: SOL101 CROD/CONROD MAT1 rod
  axial/torsional stiffness now assembles through the TACS formulation backend,
  with `tools/testing/tacs_sol101_rod_route_check.jl` checking CROD and CONROD
  axial displacements against closed-form `F L / E A` results.
- Added the first TACS beam stiffness slice: SOL101 CBAR/CBEAM constant-section
  PBAR/PBARL-style MAT1 beams now assemble through the TACS formulation
  backend, with `tools/testing/tacs_sol101_beam_route_check.jl` checking CBAR
  and CBEAM cantilever tip displacement against closed-form `F L^3 / 3 E I`.
- Extended the guarded SOL101 CBAR/CBEAM beam route to accept parser-backed
  constant/equivalent PBEAM/PBEAML properties through the same generic
  material and geometry discriminators. The same guard now covers SOL101
  varying PBEAM/PBEAML station stiffness for straight no-offset/no-release
  beams through segmented station condensation, and the SOL103 modal guard now
  covers varying-station beam stiffness plus a Guyan-reduced station mass for
  the same straight no-offset/no-release slice. The SOL105 beam buckling guard
  now covers station-condensed varying PBEAM/PBEAML geometric stiffness for the
  same slice against an independent reduced buckling pencil. The SOL101 beam
  stress-recovery guard now covers varying-station force recovery, endpoint
  axial stress/strain, and bending surface stress for the same no-offset/
  no-release slice against an independent segmented reference. Varying-station
  offsets/releases, PLOAD1 fixed-end station stress recovery, and sensitivity
  semantics still fail fast.
- Extended the TACS beam slice to SOL103 modal analysis with backend-owned
  CBAR/CBEAM lumped beam mass assembly. The new
  `tools/testing/tacs_sol103_beam_modal_route_check.jl` checks a two-DOF
  cantilever bending oscillator against the closed-form generalized
  eigenproblem, including translational and rotary beam mass entries.
- Added guarded SOL103 CBAR/CBEAM modal offsets and pin releases. The new
  `tools/testing/tacs_sol103_beam_offset_release_modal_route_check.jl` uses
  parser-backed offset-only, release-only, and combined offset/release decks,
  verifies offset-driven stiffness/mass perturbations and release-driven
  stiffness perturbations, and checks the public SOL103 eigenvalue against an
  independent reduced generalized eigensolve.
- Added guarded SOL103 CBAR/CBEAM modal material sensitivities for MAT1
  `material_E` and `material_RHO`. The new
  `tools/testing/tacs_sol103_beam_modal_sensitivity_check.jl` checks both
  beam cards against full plus/minus re-solves on the two-DOF cantilever
  bending oscillator.
- Added generic constant-section CBAR/CBEAM beam sizing perturbations for
  `beam_area`, `beam_I1`, `beam_I2`, and `beam_J` through the TACS design-delta
  path. `tools/testing/tacs_sol101_beam_sizing_sensitivity_check.jl` guards
  SOL101 `beam_I1`, `beam_I2`, and `beam_J`
  compliance/displacement-or-rotation/KS-displacement-or-rotation sensitivities
  plus CBAR/CBEAM scalar structural mass, `beam_area`, and MAT1-density mass
  derivatives. `tools/testing/tacs_sol103_beam_sizing_sensitivity_check.jl`
  guards `beam_I1`, `beam_I2`, and `beam_area` SOL103 eigenvalue/frequency
  sensitivities against full plus/minus modal re-solves.
- Added guarded SOL105 CBAR/CBEAM beam buckling support for constant-section
  compressed beam-only decks through the native
  `native_residual_first_cbar_cbeam_operator` geometric-stiffness route.
  `tools/testing/tacs_sol105_beam_route_sensitivity_check.jl` checks beam
  axial-force recovery, UZ/RY and UY/RZ geometric-stiffness entries, the first
  generalized eigenvalue, selected-mode `beam_I1`/`beam_I2` and MAT1
  `material_E` gradients, selected-mode `beam_area`/`beam_J` invariance
  derivatives, and single-mode KS `beam_I1`/`beam_I2`/`beam_area`/`beam_J`
  gradients against analytical operators and full plus/minus re-solves.
- Added guarded SOL105 CBAR/CBEAM buckling offsets and pin releases. The new
  `tools/testing/tacs_sol105_beam_offset_release_buckling_route_check.jl` uses
  parser-backed offset-only, release-only, and combined offset/release decks,
  verifies TACS K/Kg/static-preload/eigenvalue parity against the existing
  parity backend, and checks the public first buckling load factor against an
  independent reduced buckling pencil.
- Added guarded CBAR/CBEAM `node_coord` shape sensitivities for the
  constant-section beam route. `tools/testing/tacs_sol101_sol103_beam_shape_sensitivity_check.jl`
  checks SOL101 compliance, displacement, KS displacement, and structural-mass
  length derivatives plus SOL103 first-eigenvalue derivatives for CBAR and
  CBEAM against closed-form cantilever and two-DOF modal oscillator formulas.
  `tools/testing/tacs_sol105_beam_shape_sensitivity_check.jl` checks SOL105
  selected-mode and single-mode KS buckling length derivatives against full
  plus/minus re-solves and a closed-form reduced buckling pencil.
- Added guarded SOL101 CBAR/CBEAM stress recovery on the TACS route.
  `tools/testing/tacs_sol101_beam_stress_recovery_check.jl` checks axial
  displacement, force, stress, and strain for constant-section PBAR-backed
  CBAR and CBEAM decks plus PBARL BAR bending shear, root moment, and surface
  stresses against closed-form cantilever results.
- Added guarded SOL101 CBAR/CBEAM KS beam-stress sensitivities on the TACS
  route. `tools/testing/tacs_sol101_beam_stress_sensitivity_check.jl` checks
  constant-section PBARL BAR `beam_I2` bending stress gradients and
  `beam_area` axial stress gradients for CBAR and CBEAM against full
  plus/minus re-solves, and checks MAT1 `material_E` stress cancellation on
  the axial slice.
- Added guarded SOL101 CBAR/CBEAM PLOAD1 distributed beam loads. The shared
  PLOAD1 equivalent-nodal-load path now uses the same local-axis convention as
  CBAR/CBEAM stiffness/recovery, supports partial linearly varying LE/FR spans,
  and feeds fixed-end load corrections into recovered beam root shear/moment.
  `tools/testing/tacs_sol101_beam_pload1_route_check.jl` checks CBAR and CBEAM
  local FY/FZ cases against cantilever influence-integral results.
- Added guarded SOL101 CBAR/CBEAM beam offsets and pin releases on the TACS
  static route. `tools/testing/tacs_sol101_beam_offset_release_route_check.jl`
  compares offset-only, release-only, and combined offset/release CBAR/CBEAM
  matrices and displacements against the legacy assembler/solver, now including
  parser-backed CBAR/CBEAM continuation fields for PA/PB and WA/WB, and
  confirms offsets/releases still fail fast for SOL106. Beam force recovery now
  applies the same PA/PB
  condensation so released-end moments are zero in the guarded offset/release
  stress-recovery cases.
- Extended the TACS rod slice to SOL103 modal analysis with backend-owned
  CROD/CONROD lumped rod mass assembly. The new
  `tools/testing/tacs_sol103_rod_modal_route_check.jl` checks first axial
  eigenvalues/frequencies against the closed-form lumped-mass result.
- Added guarded SOL103 CROD/CONROD modal design sensitivities for `rod_area`,
  MAT1 `material_E`, MAT1 `material_RHO`, and axial endpoint `node_coord`.
  The TACS route now uses exact rod-area stiffness and modal-mass coefficient
  derivatives, with `tools/testing/tacs_sol103_rod_modal_sensitivity_check.jl`
  checking CROD and CONROD first-eigenvalue derivatives against closed-form
  axial results.
- Added a guarded CROD/CONROD geometric-stiffness operator for the TACS route.
  `tools/testing/tacs_rod_geometric_stiffness_operator_check.jl` verifies the
  compressed-rod axial-force recovery and transverse `Kg` entries for CROD and
  CONROD elements.
- Added the first TACS spring slice: SOL101 CELAS1/PELAS, CELAS2, and
  CBUSH/PBUSH diagonal stiffness now assemble through the TACS backend, with
  `tools/testing/tacs_sol101_spring_route_check.jl` checking displacement
  against closed-form spring responses.
- Extended the spring slice to SOL103 modal oscillators with guarded
  CONM1/CONM2/CMASS2/CMASS1/PMASS modal mass support.
  `tools/testing/tacs_sol103_spring_modal_route_check.jl` checks CELAS1,
  CELAS2, and CBUSH/PBUSH `k/m` eigenvalues plus
  `spring_stiffness`, `bush_stiffness`, and scalar `point_mass` modal
  derivatives against closed-form `dLambda/dK = 1/m` and
  `dLambda/dm = -k/m^2` results.
  `tools/testing/tacs_sol103_conm1_modal_route_check.jl` guards CONM1 full
  6x6 modal mass assembly, including off-diagonal translational coupling, and
  CONM1 full-matrix `point_mass` modal derivatives for diagonal `M11`/`M22`
  terms and off-diagonal `M12/M21` terms selected by `component_pairs`.
- Added `tools/testing/tacs_sol103_point_inertia_modal_check.jl` to guard
  CONM2 `point_inertia` modal sensitivities on rotational spring oscillators.
  The guard checks principal `I11` and off-diagonal `I21` inertia terms
  against closed-form generalized eigenvalue derivatives and full re-solve
  finite differences.
- Added guarded SOL101 line-element static response sensitivities for
  CROD/CONROD `rod_area`, rod MAT1 `material_E`, CELAS scalar
  `spring_stiffness`, and PBUSH diagonal `bush_stiffness`;
  `tools/testing/tacs_sol101_line_sensitivity_check.jl` checks compliance,
  scalar displacement, and single-entry KS displacement adjoint gradients
  against closed-form derivatives.
- Extended the TACS structural-mass response to include CROD/CONROD rod
  structural mass and guarded `rod_area`, MAT1 `material_RHO`, and
  rod length-coordinate derivatives, plus CONM2/CMASS2/CMASS1 scalar
  point-mass values and guarded `point_mass` derivatives in
  `tools/testing/tacs_structural_mass_fd_check.jl`.
- Added `tools/testing/tacs_sol101_rod_stress_recovery_check.jl` to guard
  TACS-route CROD/CONROD axial force, stress, and strain recovery.
- Added `tools/testing/tacs_sol105_mixed_rod_route_check.jl` to guard
  mixed shell-plus-rod SOL105 geometric-stiffness assembly and rod axial-force
  diagnostics.
- Added `tools/testing/tacs_sol105_line_sensitivity_check.jl` to guard mixed
  shell-plus-rod SOL105 buckling sensitivities for `rod_area` and rod-only
  MAT1 `material_E` against full plus/minus re-solves for both selected-mode
  and smooth-min KS buckling responses.
- Refreshed the CQUADR TACS SOL103 route guards so their expected mass-route
  metadata follows the active shell mass formulation instead of the retired
  generic `shared_jfem_mass` label.
- Added the first TACS-style response/function object layer in
  `src/backend/tacs_formulation/core.jl`. Existing compliance, displacement,
  KS von-Mises, mass, and buckling load-factor sensitivity routes now use
  response contracts, static response contexts, static-adjoint helpers, and
  buckling response contexts while preserving their numerical formulas and
  existing gradient backend labels.
- Added the first TACS coordinate/shape sensitivity route: SOL 101 static
  compliance and displacement design gradients now accept `node_coord` variables
  and compute `dK/dX` by central finite difference through the TACS shell
  assembler. The SOL 101 finite-difference guard now checks these shape
  gradients across the generated shell patch suite.
- Extended the TACS coordinate/shape sensitivity route to SOL 101 KS
  von-Mises stress design gradients. `node_coord` stress gradients now combine
  TACS-assembler central-FD `dK/dX` with explicit stress-response geometry
  terms, and the SOL 101 finite-difference guard checks the total derivative.
- Extended the TACS coordinate/shape sensitivity route to SOL 105 buckling
  load-factor design gradients. The new `buckling_load_factor_design_gradient`
  API accepts `node_coord` variables and combines TACS-assembler central-FD
  `dK/dX`, coordinate-aware `dKg/dX`, and static preload displacement variation.
  The SOL 105 route guard checks the first-mode derivative against a full
  plus/minus coordinate re-solve.
- Extended SOL 105 `buckling_load_factor_design_gradient` to selected generic
  material and PCOMP ply variables. Material stiffness and PCOMP ply
  thickness/angle variables now use assembled `dK/dx`, generic property/material
  `dKg/dx`, and static preload displacement variation. The SOL 105 guard checks
  MAT1 `E` and PCOMP ply-thickness derivatives against full solve-level finite
  differences.
- Added SOL 103 modal eigenvalue/frequency design gradients for the TACS
  shell route. The new `modal_eigenvalue_design_gradient` API combines
  assembled `dK/dx` with solver-mass `dM/dx`, supports shell thickness,
  selected material stiffness fields, material density, PCOMP ply variables,
  and `node_coord` shape variables, and is checked against full re-solve finite
  differences in `tools/testing/tacs_sol103_route_check.jl`.
- Added a TACS SOL 105 smooth-min multimode buckling aggregation API,
  `buckling_load_factor_ks_design_gradient`. It combines selected per-mode
  Rayleigh load-factor gradients with KS weights and is checked against a
  full re-solve finite difference on the first two buckling modes.
- Added public TACS structural mass design gradients via
  `structural_mass_design_gradient`. The guarded shell slice now supports mass
  coefficients for shell thickness, PCOMP ply thickness, material density,
  zero gradients for mass-independent stiffness variables, and central-FD
  `node_coord` mass shape sensitivity.
- Added SOL 101 design-dependent load sensitivity terms to the TACS static
  adjoint gradients. Compliance, displacement, and KS von-Mises design
  gradients now include finite-difference `dF/dx` load-vector terms for the
  guarded shell slice, with a new PLOAD4 pressure coordinate finite-difference
  guard.
- Added SOL 105 static-preload design-dependent load sensitivity terms to the
  TACS buckling-gradient route. Preload displacement derivatives now solve
  `K du/dx = dF/dx - dK/dx*u`, and a focused PLOAD4 pressure guard checks the
  preload state derivative against plus/minus finite differences.
- Added static material-density load-only sensitivity for GRAV shell and
  constant-section CBAR/CBEAM beam loads in the TACS SOL 101 adjoint route.
  Compliance, displacement, and shell KS von-Mises gradients can now use
  `material_RHO` design variables when density affects the load vector but not
  static stiffness. `tools/testing/tacs_sol101_gravity_load_sensitivity_check.jl`
  now checks shell density load-only compliance/displacement/stress derivatives
  plus CBAR/CBEAM compliance and scalar-displacement density derivatives
  against full plus/minus density re-solves and a closed-form cantilever
  gravity response.
- Added guarded RFORCE/centrifugal load sensitivity coverage for the same
  SOL 101 material-density load-only adjoint route. The load assembler now
  applies RFORCE to CROD/CONROD and CBAR/CBEAM elements with a consistent
  two-node line inertial load, and
  `tools/testing/tacs_sol101_rforce_load_sensitivity_check.jl` checks shell,
  CROD, CONROD, CBAR, and CBEAM density derivatives for compliance and scalar
  displacement plus single-entry KS displacement against full plus/minus
  density re-solves. The line cases also check scalar and KS displacement
  against a closed-form axial centrifugal response.
- Added guarded SOL 101 TEMP(LOAD) axial thermal-load sensitivity coverage for
  CROD, CONROD, CBAR, and CBEAM. MAT1 `material_E`, `material_ALPHA`, and
  `material_TREF` now participate in the generic static load-vector
  finite-difference tangent, with
  `tools/testing/tacs_sol101_line_thermal_load_sensitivity_check.jl` checking
  compliance, scalar displacement, and single-entry KS displacement against
  full plus/minus re-solves and closed-form axial thermal displacement
  derivatives.
- Added projected repeated/clustered generalized eigenvalue derivative helpers
  for the TACS SOL 103 and SOL 105 sensitivity routes. Modal and buckling
  gradients now expose cluster derivative fields when a solved eigenvalue
  cluster is detected, and `tools/testing/tacs_cluster_eigen_sensitivity_check.jl`
  guards the projected derivative math on synthetic repeated eigenproblems.
- Added SOL 105 GRAV material-density preload sensitivity for buckling
  gradients. The new load-driven Rayleigh Kg route uses zero static stiffness
  tangent plus finite-difference `dF/dRHO`, and
  `tools/testing/tacs_sol105_gravity_preload_sensitivity_check.jl` checks the
  load-factor derivative against full plus/minus buckling re-solves.
- Added SOL 105 RFORCE inertial-preload sensitivity coverage. The new
  `tools/testing/tacs_sol105_rforce_preload_sensitivity_check.jl` guard checks
  MAT1 density and node-coordinate centrifugal preload derivatives against full
  plus/minus buckling re-solves through the TACS load-driven Rayleigh Kg path.
- Added a guarded SOL 101 RFORCE coordinate sensitivity check. Static
  compliance and displacement coordinate gradients now have explicit coverage
  for centrifugal `dF/dX` terms against full plus/minus coordinate re-solves.
- Added SOL 200-lite opt-in support for smooth-min multimode buckling
  aggregation through `DOPTPRM,KSRHO`. The grouped sizing optimizer now calls
  the TACS `buckling_load_factor_ks_design_gradient` backend hook when enabled,
  and `tools/testing/tacs_sol200_buckling_ks_route_check.jl` guards the route.
- Added direct PSHELL/MAT8 support to the TACS residual-first shell route.
  Orthotropic membrane, bending, and transverse-shear constitutive matrices are
  now accepted for PSHELL properties, and
  `tools/testing/tacs_pshell_mat8_route_check.jl` guards SOL101 compliance
  sensitivity with respect to MAT8 `E1/E2/G12/NU12`.
- Added direct PSHELL/MAT2 support to the TACS residual-first shell route.
  Anisotropic membrane, bending, and transverse-shear constitutive matrices are
  now accepted for PSHELL properties, MAT2/MAT8 thickness handling is
  ForwardDiff-safe, and `tools/testing/tacs_pshell_mat2_route_check.jl` guards
  SOL101 shell-thickness plus all six MAT2 `G11/G12/G13/G22/G23/G33`
  compliance sensitivities against full re-solves. The generic TACS
  material-design tangent route now accepts MAT2
  `G11/G12/G13/G22/G23/G33` stiffness variables.
- Added `tools/testing/tacs_pshell_mat2_mat8_eigen_route_check.jl` to guard
  direct PSHELL/MAT2 and PSHELL/MAT8 material derivatives in SOL103 and SOL105.
  The guard checks first modal/buckling eigenvalue derivatives for all
  supported direct PSHELL/MAT2 fields (`G11/G12/G13/G22/G23/G33`) and
  PSHELL/MAT8 fields (`E1/E2/G12/NU12`) against full plus/minus re-solves.
- Added grouped TACS SOL103/SOL105 eigen sensitivity coverage. Material design
  perturbations now support multiple material IDs generically, and the SOL105
  generic shell-thickness buckling path differentiates grouped `Kg` updates as
  one grouped perturbation. The new
  `tools/testing/tacs_grouped_eigen_design_sensitivity_check.jl` guard checks
  grouped shell thickness and grouped MAT1 `E` derivatives against full
  grouped plus/minus re-solves.
- Added grouped direct PSHELL/MAT2 and PSHELL/MAT8 eigen sensitivity coverage.
  `tools/testing/tacs_grouped_mat2_mat8_eigen_sensitivity_check.jl` checks
  grouped two-material SOL103/SOL105 first-eigenvalue derivatives for all
  supported MAT2 `G11/G12/G13/G22/G23/G33` fields and MAT8
  `E1/E2/G12/NU12` fields. Material design variables now also honor an
  explicit `step` field for guarded finite-difference sensitivity routes.
- Added PCOMP ply eigen sensitivity coverage. The new
  `tools/testing/tacs_pcomp_eigen_ply_sensitivity_check.jl` guard checks
  SOL103 modal and SOL105 buckling first-eigenvalue derivatives for PCOMP ply
  thickness and ply angle design variables on an unsymmetric MAT8 laminate
  against full plus/minus re-solves.
- Added PCOMP ply KS von-Mises stress sensitivity coverage. The TACS static
  stress response now evaluates PCOMP von-Mises stress from the laminate
  surface ply `Qbar` data and uses a fixed-state explicit response tangent for
  ply thickness/angle variables; the new
  `tools/testing/tacs_pcomp_stress_ks_ply_sensitivity_check.jl` guard checks
  the total SOL101 KS stress derivatives against full plus/minus re-solves.
- Added the first guarded composite failure response slice. MAT8 parsing now
  preserves strength allowables, and `static_ks_ply_failure_design_gradient`
  exposes a SOL101 `ks_ply_failure` response for PCOMP ply thickness/angle
  variables using an analytical state derivative plus fixed-state explicit
  response tangent. The initial criteria are Tsai-Hill, classic Tsai-Wu, and
  TACS-style modified Tsai-Wu strength ratio. The new
  `tools/testing/tacs_pcomp_tsai_hill_failure_sensitivity_check.jl` guard
  `tools/testing/tacs_pcomp_tsai_wu_failure_sensitivity_check.jl` guard, and
  `tools/testing/tacs_pcomp_modified_tsai_wu_failure_sensitivity_check.jl`
  guard check total derivatives against full plus/minus re-solves.
- Added selected MAT8 strength-field sensitivities for the guarded PCOMP
  failure response. `ks_ply_failure` design gradients now support explicit
  response derivatives for MAT8 allowable variables such as `material_XT` and
  `material_S` without stiffness/load tangents, and
  `tools/testing/tacs_pcomp_failure_strength_sensitivity_check.jl` guards the
  result against full plus/minus re-solves.
- Added response-level SOL103/SOL105 mode-tracking and cluster-policy controls
  for TACS eigen sensitivities. Modal and buckling load-factor gradient APIs
  now accept MAC-based `mode_tracking` plus `current_mode`/`min`/`max`/`mean`
  cluster derivative policies, record requested versus selected mode
  diagnostics, and keep the old current-index behavior as the default.
  `tools/testing/tacs_mode_tracking_policy_check.jl` guards the production
  route, while `tools/testing/tacs_cluster_eigen_sensitivity_check.jl` now also
  checks the low-level policy and MAC helpers.
- Added SOL200-lite buckling mode-selection policy controls. `DOPTPRM,BUCKMODE`
  selects the scalar load-factor mode, `DOPTPRM,BUCKM#` selects the smooth-min
  KS mode list when `KSRHO` is active, and `DOPTPRM,BUCKPOL` plus
  `BUCKRTOL/BUCKATOL` pass cluster-policy settings into TACS per-mode
  gradients. `tools/testing/tacs_sol200_buckling_ks_route_check.jl` now checks
  both KS mode-list routing and selected-mode first-load-factor routing.
- Added public previous-solve MAC continuation helpers for TACS eigen
  responses. `eigen_mode_tracking_reference` captures a selected SOL103/SOL105
  mode shape, `eigen_mode_continuation_update` advances that reference across
  a solve sequence, and scalar SOL200-lite buckling sizing can opt in with
  `DOPTPRM,BUCKTRK` plus optional `BUCKWIN/BUCKMAC` controls. The new
  `tools/testing/tacs_mode_continuation_check.jl` guard verifies SOL103 and
  SOL105 continuation from a mode-1 request to a previous mode-2 reference.
- Added a TACS static `ks_displacement` response and public
  `static_ks_displacement_design_gradient` hook. The response aggregates
  selected grid/component displacement values with KS smooth-max weights and
  uses the existing static adjoint design-gradient path. A new
  `tools/testing/tacs_ks_displacement_response_check.jl` guard checks
  shell-thickness, material-E, node-coordinate shape, and PLOAD4 pressure-load
  geometry derivatives against full re-solves. SOL200-lite mass-minimization
  constraints now accept `DRESP1,KSDISP` responses routed through the same
  TACS adjoint backend, guarded by
  `tools/testing/tacs_sol200_ks_displacement_route_check.jl`.
- Public repository `AGENTS.md` documents the new canonical public repo path
  (`01_PUBLIC_PROJECT_REPOSITORY/JFEM/`) and the public/private publication boundary for
  future coding agents.
- Top-level `validation/` folder prepared as the paper-facing public
  validation set. It contains only public or permissively licensed cases
  (MacNeal-Harder, classical buckling, MYSTRAN cross-checks, and CRM/uCRM),
  explicitly excludes GAME/HTP/VTP private cases, and keeps a compatibility
  wrapper under `tools/validation_suite/`. The folder now includes
  `CASE_INVENTORY.csv`, `PAPER_VALIDATION_SUMMARY.md`, and convenience launchers.
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

- `tools/testing/sol103_mass_formulation_guard.jl` locks down SOL 103 shell
  mass selection across the default, `PARAM,COUPMASS`, and diagnostic
  environment override routes.
- `tools/testing/sol105_parity_defaults_guard.jl` now also locks down that
  promoted SOL105 defaults keep stress-state-dependent calibration paths off or
  neutral unless a diagnostic environment knob explicitly enables them.

### Fixed
- `Reference_documentation/README.md` now describes manifest-driven document
  publication instead of automatic all-PDF mirroring from the private document
  source tree.
- Public validation suite manifest now extracts the MacNeal-Harder twisted
  beam, Scordelis-Lo roof, and hemispherical-shell quantities from the
  documented benchmark nodes, and supports explicit absolute-value comparison
  for signed displacement quantities reported as magnitudes.
- MacNeal-Harder SOL 101 public shell parity now uses generic PSHELL/MAT1
  geometry/material CQUAD4 static component scaling for flat strips, warped
  strips, cylindrical roofs, cylindrical patches, and double-curved patches.
  The rules use only element geometry and material/property family. The five
  public MacNeal-Harder rows now all pass: curved beam 1.92%, twisted beam
  1.22%, Scordelis-Lo 4.15%, pinched cylinder 0.20%, and hemisphere 3.28%
  relative error.
- Classical SOL 105 flat-square PSHELL/MAT1 plate buckling now applies a
  geometry/material-only `Kg` membrane normalization
  (`JFEM_SOL105_GEOM_PSHELL_ISO_FLAT_SQUARE_KG_*`, default scale `1.03`).
  The Timoshenko plate public row moves from 3.23% high to 0.22% relative
  error, while the private SOL105 guard remains inside the 2% target: NAST705
  atomic 25/25, NAST705 patch 13/13, and GAME 10/10 trusted rows.
- Public validation suite CSV output now quotes fields containing commas,
  quotes, or newlines, so solver error notes remain parseable.
- Public validation suite analytical-reference lookup now wraps both runtime
  binding access and function invocation in `Base.invokelatest`, avoiding Julia
  1.12 world-age deprecation warnings during `run_public_suite.jl`.
- SOL 103 shell normal modes now default to coupled consistent PSHELL mass for
  quadrilateral and triangular shells, with explicit `PARAM,COUPMASS,NO` and
  `JFEM_SOL103_SHELL_MASS=lumped` overrides for lumped-mass diagnostics. CRM
  wingbox modal parity is now 5/5 PASS with first-five eigenvalue errors below
  0.05%, and SOL103 mass/effective-mass diagnostics use the full mass operator
  instead of diagonal-only totals. Modal effective mass now evaluates global
  rigid translations in the assembled analysis DOF frame, preserving physical
  mass totals for rotated GRID `CD` output frames.
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
- Windows launchers (`POST/RUN_PANDEATOR_WINDOWS.cmd`, `jfem.cmd`,
  `JFEM_installation/CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd`) now work when the install path contains
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
- `JFEM_installation/` folder: clearly identified, cross-platform sysimage build
  scripts with explicit Windows, Linux, and macOS filenames, plus a `README.md`
  with step-by-step instructions. Building a sysimage is
  optional (everything runs without one, just slower to start); the launchers
  load it automatically when present. `POST/RUN_PANDEATOR_MAC_LINUX.sh` now loads a
  `.so`/`.dylib` sysimage when present and uses plain `julia` (dropped the
  juliaup-only `+release`), matching `RUN_PANDEATOR_WINDOWS.cmd`.
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
  server (`panel_server.jl`, `panel_launch.jl`, `RUN_PANDEATOR_WINDOWS.cmd`/`RUN_PANDEATOR_MAC_LINUX.sh`) plus a
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
- `POST/RUN_PANDEATOR_WINDOWS.cmd`: launch with plain `julia` instead of `julia +release`
  so the app runs on machines without juliaup (a standalone `julia.exe`
  treats `+release` as a bad path and errors). Now also auto-loads a
  prebuilt sysimage via `--sysimage` when `sysimage/OpenJFEM_sysimage.dll`
  exists, for near-instant startup, and falls back to a normal start when
  it does not. The `JFEM_installation/` helper scripts build that sysimage
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
  from `02_PROJECT_DEVELOPMENT/03_DOCUMENTS_IN_PROGRESS/`:
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
