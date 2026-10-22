# Automated regression tests

You do not need to run these files to install or use JFEM. They are retained in
the public repository because they protect solver correctness and let users
verify a build. They contain small synthetic models, isolated attributed public
element fixtures and assertions.

`runtests.jl` is the entry point. It runs the curated `validation/` suite and then
focused checks of constraints, beam and shell operators, mass and buckling,
input parsing, result recovery, timing, and installation behavior. It also checks
the shared application package environment and PANDEATOR's local HTTP listener.
Individual
`*_test.jl` files isolate regressions that would be harder to diagnose from a
large application model. The JFEM-Boxer browser/generator checks live separately
under `APPS/JFEM-Boxer/test/`.

The material and stress-report checks include `material_allowables_test.cjs`,
`material_library_browser_test.cjs`, `stress_report_data_test.cjs` and
`stress_report_material_roles_test.jl`. They verify MPa/Pa conversion, saved
material limits, percentile trimming, per-case envelopes, incomplete recovery
and mixed-material exclusions. `stress_report_browser_test.cjs` replays actual
multicase solver payloads through the app and checks the tables and exports;
its header describes the required local fixtures and browser arguments.
`material_defaults_test.jl` and `material_defaults_test.cjs` check the editable
AL2024 default, explicit opt-outs, imported-unit exclusions and missing fixities.
`assessment_defaults_browser_test.cjs SCHEMA_JSON OUTPUT PLAYWRIGHT` checks
the actual forms, parameter persistence, material renaming and FE-signature
invariance; use a schema JSON produced by a generator fixture.

`reserve_factor_table_data_test.cjs` checks structural locations, actual property
regions, incomplete assessments, the RF = 1 color threshold and exports.
`reserve_factor_table_browser_test.cjs` checks the complete app and detached
window with recovered SOL101/SOL106 payloads, verified generated-model locations,
live/off-tab updates, invalidation and exports. Its header lists fixture and
browser arguments; synthetic samples are used only to exercise color thresholds.
`rf_field_data_test.cjs` checks actual-EID projection, shared criterion ownership,
overlapping incomplete regions, categorical identities and current-result cache
invalidation. `rf_field_browser_test.cjs` replays actual recovered results through
Boxer and checks every shell/beam vertex color, 3D sections, legends, live
assessment edits, stale-result gates, inspection and competing display modes.
Its header lists the fixture, output and Playwright arguments.

`rf_field_visibility_test.cjs` verifies index filtering, exact picking ownership,
hidden-layer restoration and geometry replacement. `rf_filter_browser_test.cjs`
checks RF below/equal/above 1 through complete Boxer startup, including thick
shells, 3D bars, labels, picking and stale-result gates.
`rf_property_editor_test.cjs` and `rf_property_editor_browser_test.cjs` check
exact PID-to-local-override mapping, SI/mm conversion, section validation,
minimum gauges and atomic dialog commits. `rf_property_bridge_browser_test.cjs`
exercises the detached RF table against the live Study, including invalid red
drafts, locked/stale inputs, cancellation and result invalidation. Browser
fixture/output/Playwright arguments are documented in each test header.
`load_plots_test.cjs` checks themes and standalone SVG content;
`aerodynamic_load_plots_browser_test.cjs` checks actual multicase plots, light
mode, responsive graph heights, visible-component exports and stale annotations.
These checks exercise UI behavior; they do not constitute new solver validation.

`beam_stress_envelope_test.jl OUTPUT` checks the thin-walled T equivalent-stress
envelope against independent section calculations and sampled stress fields,
including sign, scale, missing-resultant and unsupported-section cases.
`beam_equivalent_recovery_test.jl OUTPUT` solves small synthetic CBAR/CBEAM
SOL101 and SOL106 cases and checks recovered equivalent stresses.
`APPS/JFEM-Boxer/test/beam_stress_payload_test.jl FIXTURE RECOVERY OUTPUT`
checks upgrading actual earlier force records through Boxer's result reader
without another solve. Keep its generated outputs outside the source folders.

The Euler column checks are `euler_column_data_test.cjs` (section stiffness,
signed compression and case coverage), `stringer_euler_test.jl OUTPUT`
(actual beam/shell sections, offsets, laminate laws and compact payloads), and
`stringer_euler_spatial_test.jl` (conservative spatial queries).
`stringer_euler_membership_test.jl OUTPUT` checks that beam and shell run-outs
retain exact physical skin/member ownership even when their Euler end restraint
is unsupported, without changing valid neighboring regions.
Run `stringer_euler_recovery_test.jl OUTPUT` after the geometry test, with the
same output directory, to solve its generated compression/tension SOL101 and
SOL106 fixtures and inspect actual recovered forces. Run Julia checks from
the shared repository project. `euler_report_browser_test.cjs` uses those
generated geometry fixtures with explicitly synthetic force samples to check
live fixity edits, the RF 99 marker, incomplete recovery and detached tables;
its header lists browser arguments. These checks validate the documented
elastic column assessment, not local plate buckling or nonlinear collapse.
The separate free-web checks are `stringer_blade_test.jl OUTPUT`
(actual PBARL T geometry, material data and source-member ownership),
`stringer_blade_data_test.cjs` (elastic outstand capacity, signed arithmetic
stress averages, coverage and case envelopes), and
`stringer_blade_report_browser_test.cjs` (main/detached tables and exports).
The Julia test optionally accepts the existing Euler recovery directory as
its second argument to check actual recovered SOL101/SOL106 bar stresses.
The browser test uses those recovered payloads as well as explicitly synthetic
samples for threshold colors, mixed stress signs and incomplete recovery;
its header lists the required arguments. This is an elastic local plate check,
not a validation of crippling, yielding or nonlinear collapse.
`skin_buckling_test.jl` checks actual rib/stringer/spar-bounded compartments,
physical boundary lengths, shell-result frames, laminate bending stiffness and
the separately saved skin fixity control. `skin_buckling_data_test.cjs` checks
the plate energy matrices, combined biaxial/shear loads, mode convergence,
signed membrane averaging and incomplete-data gates. The main and detached
table workflows are exercised by `skin_buckling_report_browser_test.cjs`;
its header lists geometry and optional actual-recovery fixture arguments.
`skin_rf_convergence_browser_test.cjs` accepts external geometry, recovery and
expected-result fixtures to check difficult tension/shear convergence through
the tables, exports, 3D fields and Inspect. It also removes one recovery record
temporarily to verify that incomplete data stay unassessed. Numerical tests
cover direction-guided refinement, diagonal normalization, noise-floor rejection
and independent large-basis reference values.
These tests concern the documented equivalent rectangular thin-plate model.
`stringer_runout_rib_test.jl [OUTPUT]` checks that beam and shell stringers
terminate at physical rib datums, with 5 mm² connectors to the next spar row.
It covers front/rear run-outs, simultaneous terminations, angled ribs, mesh
refinement, kink excursions, strict clearance thresholds, conforming skin
coverage and complete skin/column assessment boundaries.
`component_buckling_test.jl OUTPUT` checks spar/rib support topology, exact
element membership, mapped web cells, current laminate laws and cap/stiffener
sections. It writes small generated fixtures for
`component_buckling_recovery_test.jl FIXTURE OUTPUT [linear-only]`, which runs
opposite axial and bending SOL101 cases and, unless disabled, a converged
full-load SOL106 case. `component_buckling_data_test.cjs` checks spatial plate
energy, stress gradients, conservative non-governing-case bounds, column/blade
capacities and strict incomplete-data gates. `component_rf_report_browser_test.cjs` exercises all five component
assessments, relocated fixity controls, live updates, detached grids and
exports; its header gives fixture/browser arguments. These validate the
documented elastic component assessments, not nonlinear collapse or all
possible modes of structural failure.
The minimum-gauge checks are `minimum_gauge_test.jl OUTPUT`
(active family/local bounds, generated sections and exact physical membership),
`minimum_gauge_edge_test.jl` (local sandwich flanges on default blades and
movable-surface minima),
`minimum_gauge_sensitivity_test.jl` (one-sided steps at bounds and unchanged
analytic derivatives), `minimum_gauge_inputs_test.cjs` (editor validation), and
`minimum_gauge_inputs_browser_test.cjs` (relocated controls, saved parameters,
local tables and sandwich inputs). `minimum_rf_data_test.cjs` checks the combined
property RF envelope, verified shared membership, laminate strain criteria,
incomplete coverage, minimum-gauge highlighting and no-demand markers.
`minimum_rf_report_browser_test.cjs` exercises the main/detached reports, critical
case/mode presentations and exports with actual recovered payloads. Browser
test headers list their generated fixtures and local browser dependencies.
`aerodynamic_load_plots_test.jl OUTPUT` checks signed equal-lift elliptical
references, nonuniform strip integration, case multipliers and inviscid
efficiency from full-wing VLM coefficients. It emits a six-case fixture for
`aerodynamic_load_plots_browser_test.cjs`; that test checks case changes,
plotted traces, hover values and metric availability in the complete app.
The coefficient comparison retains the documented VLM discretization tolerance;
it does not claim an exact Oswald factor from a coarse mesh or a viscous model.
`sensitivity_warmup_test.jl` runs the installation's imported/generated
sensitivity workloads and checks finite analytic results with one baseline
solve and no perturbed equilibrium solves.
`sensitivity_persistent_worker_test.jl OUTPUT` uses a controlled IPC worker to
check shared FE/sensitivity ordering, independent outputs, errors, cancellation,
timeout, crash/restart and application shutdown. Run it with `--threads=4` from
the shared project. Its synthetic replies test lifecycle behavior, not accuracy.

The rendering checks use the bundled Babylon engine. `graphics_engine_test.cjs`
checks WebGPU startup and capability fallback; Boxer's
`renderer_compatibility_browser_test.cjs` checks Standard/PBR surfaces, ground
finishes, shadows and resize/recreation. `viewport_svg_depth_test.cjs` checks
surface ordering, hidden lines and constraint/datum depth conventions with
forward and reversed depth. `transparency_scaling_test.cjs` protects switching
performance on thousands of property materials. The actual-pixel regression
`transparency_depth_browser_test.cjs` checks 3 mm-separated skins across a
30 m model from above, below and rotated, in perspective and orthographic views.

The Boxer geometry checks cover local coordinate-file parsing, loft thickness
and twist interpolation, exact maximum-thickness evaluation, shared structural/
aerodynamic/fuel geometry, and portable drawing settings. Run
`APPS/JFEM-Boxer/test/loft_controls_test.jl` from the shared Julia environment.
The adjacent `airfoil_file_test.cjs`, `loft_test.cjs` and
`svg_registration_math_test.cjs` use Node's built-in assertions. Browser checks
in `loft_file_browser_test.cjs` and `svg_registration_browser_test.cjs` also need
Playwright; their first two arguments select a temporary evidence directory
and the installed Playwright module. `CHROME_PATH` optionally selects an
installed browser. These are developer tools, not additional app requirements.

`loft_cuts_test.cjs` checks cyan span-plane intersections against analytical
sections, degenerate/coplanar mesh edges and a deformed render mesh; it also
checks buffer reuse and disposal. `loft_cut_workspace_test.cjs` checks saved
counts, visibility and defaults. The 2D registration browser check covers
right-button pan, immediate pin alignment and window zoom in shared, detached
and fallback views. The geometry display browser check exercises compact
entity controls across repeated panel rebuilds.
`loft_cuts_browser_test.cjs` also checks real Babylon/WebGL pixels: intersections
stay cyan after deformation and buffer growth, and disappear when hidden.

The shared structural drawing checks are
`APPS/JFEM-Boxer/test/structural_plan_views_test.cjs` and
`structural_plan_views_browser_test.cjs`. They compare the Spar/Rib/Stringer
plan backgrounds, retain editing handles and independent cameras, and distinguish
reference previews from generated stringer attachment paths. The browser test
also checks viewport state across repeated form updates.

`svg_image_controls_browser_test.cjs` checks image-only numeric/window zoom,
width/height ratios, original-ratio reset, rendered pin alignment and unchanged
model geometry in both shared and detached views. Like the structural drawing
browser test, it takes an evidence directory and Playwright module as its two
arguments; `CHROME_PATH` can select the browser. `plan_view_registration_test.jl`
checks backend normalization, saved metadata and legacy defaults for those
presentation settings.

`summary_export_test.cjs` and `summary_export_browser_test.cjs` cover General
and Mass properties CSV, Markdown and self-contained HTML exports, preserving
units and selected-case context, escaping content and reporting unavailable or
stale summaries. The browser test needs Playwright; use
`WINGFEGEN_PLAYWRIGHT_MODULE` and `CHROME_BIN` to select its module and browser.

`native_windows_dialog_test.jl` verifies the Windows file-dialog ABI, UTF-16
buffers, cancellation/error protocol and argument handling without opening an
OS dialog. `study_save_server_test.jl` and the Study browser checks cover
session-selected file capabilities and save/fallback behavior. The production
Windows picker uses Julia and Win32, with no PowerShell execution-policy changes.
`import_runtime_test.jl` verifies that Reference/Abaqus input inspection uses the
shared parser/model definitions without loading the numerical solver or
unrelated application packages; production-worker checks cover warm reuse.

The Abaqus and solid-element checks exercise portable/gzip inputs, recursive
INCLUDE files, named sets, explicit mesh-only completion, supported mechanics
and blocking diagnostics. Quadratic tetrahedron checks retain every midside
node and cover stiffness, consistent mass, recovery and geometric stiffness.
The solid-viewer checks verify exterior-face cancellation, complete parent
connectivity, picking metadata and version 6/7 binary records. Interfaces with
matching corner nodes but different midside IDs remain visible as separate
faces. Focused commands from the repository root are:

```sh
julia --project=. utils/test/abaqus_input_test.jl
julia --project=. utils/test/tetra10_test.jl
julia --project=. APPS/JFEM-Boxer/test/abaqus_import_test.jl
julia --project=. APPS/JFEM-Boxer/test/abaqus_import_worker_test.jl
node APPS/JFEM-Boxer/test/abaqus_import_test.cjs
node APPS/JFEM-Boxer/test/solid_geometry_test.cjs
node APPS/JFEM-Boxer/test/solid_binary_test.cjs
node APPS/JFEM-Boxer/test/abaqus_import_browser_test.cjs
```

The production importer-worker check uses a tiny synthetic input and does not
launch an FE solve. The browser-form check uses explicit test callbacks and
needs Playwright; `WINGFEGEN_PLAYWRIGHT_MODULE` and `CHROME_BIN` can select its
installed module and browser. Neither dependency is needed to use Boxer.
External mesh downloads and result campaigns are not prerequisites for these
portable tests.
The parser and quadratic-solid operator checks are also included in the normal
`runtests.jl` release gate. `APPS/JFEM-Boxer/test/solid_results_payload_test.jl`
checks live centroidal solid-stress fields and inspection by original EID.

After installation, from the repository root:

```sh
julia --project=. utils/test/runtests.jl
```

These developer checks can take
longer than ordinary app startup; they are not part of the everyday launch.
Generated results belong in a temporary directory, never beside source tests.
The two documented coarse-mesh accuracy misses are asserted explicitly.
Historical regression checks remain separate from analytical and published
accuracy checks. See `validation/VALIDATION_SUMMARY.md`.

The coupled-quadrilateral checks independently integrate the section energy and
test quadrature weights, enrichment switches and derivatives. Their isolated
uCRM9 element fixture retains the original public dataset attribution under
`validation/cases/CRM_uCRM9_published/diagnostics`. The modal pencil tests use
exact small eigenproblems to check singular mass, negative finite roots and
coupled coordinates whose diagonal stiffness is zero.

Three integration scripts run separately because they require input-deck and
output-directory arguments: `buckling_output_test.jl`,
`pipeline_timings_solver_test.jl`, and `pipeline_timings_variants_test.jl`.
Their usage is documented at the top of each file; they are not invoked by
`runtests.jl`.

The tests live under `utils/test/` rather than the standard package `test/`
folder. Use the command above instead of `Pkg.test()`.

All current files participate in maintained regression coverage or support its
fixtures. Moving them out of the repository would break reproducible testing;
no active tests were removed merely because everyday users do not open them.
