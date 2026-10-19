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
