# WingFEGen

WingFEGen is the wing finite-element generator and browser interface included
with OpenJFEM. It generates shell/bar wing structures, aerodynamic lattices and
load cases, writes NASTRAN decks, launches the solver in this repository and
displays structural results and property sensitivities.

The complete application source and browser libraries are in this directory.
No private workspace, downloaded Study, proprietary solver, Node build pipeline
or Python environment is needed to run the application.

## Install and start

Install **Julia 1.13.1**, then clone the repository:

```sh
git clone https://github.com/r-acad/JF_2026_05_25.git
cd JF_2026_05_25
julia WingFEGen/setup.jl
julia --project=WingFEGen WingFEGen/run.jl
```

Setup installs the pinned dependencies for both the generator and the enclosing
OpenJFEM solver. The first setup and first analysis can take several minutes
while Julia downloads and compiles packages. A separately built solver sysimage
is optional; the application works without one.

The app opens a browser at `http://127.0.0.1:8080`. If the browser does not open,
visit that address manually. It is a local desktop web app, not a hosted service.
Keep its terminal open while using it. Stop the server with Ctrl+C in that terminal.

Alternatively, run the launchers in this directory:

- Windows: `setup.cmd`, followed by `run_fe_generator.cmd`.
- Linux/macOS: `sh setup.sh`, followed by `sh run_fe_generator.sh`.

The repository may be cloned to a different folder name, including a path with
spaces. WingFEGen discovers the enclosing OpenJFEM source. An explicit
`jfem.path` in a TOML definition can point to another compatible solver checkout.
Both project manifests record the tested Julia/dependency versions.

Useful command-line options, from the repository root:

```sh
julia --project=WingFEGen WingFEGen/run.jl --port 8090 --no-browser
julia --project=WingFEGen WingFEGen/run.jl --nastran
julia --project=WingFEGen WingFEGen/run.jl /path/to/my_wing.toml
```

Without a specified input, the first start creates a writable
`input/wing_input.toml` from [examples/wing_default.toml](examples/wing_default.toml).
Later starts retain that input. The example is a factory definition, not a user
Study. Generated decks, caches and solver jobs go under `output/` by default.
Relative output paths are resolved from this application directory.

Internet access is needed for initial Julia dependency installation. The normal
viewer uses bundled JavaScript. NACA profiles work locally; downloading a new
UIUC database profile or importing remote resources requires access to its
source. Previously embedded airfoil and reference data travel with a saved Study.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for vendored components and
optional external-resource details.

## First study

1. In **Study Options**, choose **Start new study**, **Load last study**,
   **Open existing study**, or **Read Nastran file**.
2. Define the planform, airfoils, spars, ribs and optional leading-edge mesh.
   Planform edge perturbations refine the aerodynamic outline; spar perturbations
   define the structural spar paths independently.
3. Use **Model / Mesh / Structural Mesh** to create or refine the FEM. Live mesh
   rebuilds it after valid edits. Geometry and mesh locks help retain the layout
   while assigning properties.
4. Define materials, skins, stringers, ribs, spars and leading-edge properties
   under **Model / Properties**. Detached panel tables assign local overrides;
   blank entries inherit the shared values. Rows are stringers, columns are rib
   bays, and P-numbers match the panel display.
5. Define supports and cases. Cases include aerodynamic settings, load multiplier,
   fuel state and inertia options. Aerodynamic loads use rib-plane RBE3s; mass
   loads use rib-bay-center references. The default multiplier of 1.5 converts
   specified limit aerodynamic loads to ultimate loads.
6. Use **Analysis / Run in JFEM**. Open **Results / FE Results** for displacements, shell/bar
   stresses and forces, modes, buckling or linear/nonlinear comparisons.
7. **Save Study** stores the complete model definition, display settings and
   selected portable reference data. **Save TOML** exports the text definition.
   The first save chooses a destination; subsequent saves update that linked
   file. **Save Study as…** selects another filename and folder. The Save Study
   button is orange for unsaved definition changes and green after saving.
   Camera, palette and display edits leave its status unchanged; an explicit
   save still captures their current settings. Browsers without
   file-picker support use their download settings instead.

The definition is saved independently from solved results. Exported decks and
solver result files remain in their run directories. A stale model/result is
identified in the GUI rather than being silently presented as current.

### Read an existing Nastran deck

**Read Nastran** in the top bar opens a complete `.bdf`, `.dat` or `.nas` deck
using the native JFEM parser. By default, **Browse** selects a file on the
WingFEGen computer, or you can paste its full path. INCLUDE files are read
automatically relative to their containing files. The former 32 MiB import
limit is removed. Import progress shows elapsed time and the current stage;
errors remain fully visible in the import dialog.

Opening another BDF starts with a fitted isometric view, default entity
visibility, expanded lists and fresh case/result/sensitivity selections. Filters,
external references and analysis results from the previous model are cleared
only after the new deck loads successfully. A failed import leaves the previous
model available. Opening a saved Study restores its saved display settings.

Read Nastran opens the normal Windows **Open** dialog immediately. **Browse**
reopens it; the selected full path remains editable in the import form. A
foreground owner keeps the dialog above the browser. Cancel returns to the
form, and **Read deck** starts the import. The Windows picker supplies the
actual folder so INCLUDE files can be resolved without selecting them again.
On other platforms, paste the main deck's full local path. Parser preparation
starts while you choose the file, with a stage and timer. The first import can
include Julia package loading and compilation; later imports reuse the parser.
The Log reports source/INCLUDE reading, parser startup, native model creation,
viewport conversion and delivery separately. Preparation runs no analysis and
does not modify the current Study.

The previous complete model remains on screen while the new one is decoded
and prepared. Geometry, property visibility and camera are committed together;
an import error restores the previous view. Logs separate transfer, decoding
and viewport preparation. Large imported property groups use preallocated axis
buffers, and viewport material/visibility updates are batched to avoid repeated
whole-model work. These optimizations preserve element/property identities,
case-specific supports and loads, and inspection data.

Large imported models retain their individual property groups for visibility and
inspection, while sharing bounded GPU geometry batches. Entity lists are paged
instead of creating thousands of controls at once. Binary arrays and repeated
material records share transport storage; native model data is restored only
when a later backend operation needs it. Import still includes building material
and composite constitutive data, preparing viewer geometry and caching the model.
These stages can exceed the time spent reading and parsing a large deck; the
stage timings in Log distinguish them from file I/O and from an analysis solve.
Fit view and context planes use the connected structural extent by default, so
distant orientation or unused GRIDs do not dwarf the model. Showing all GRID
markers includes their full source extent; no source nodes are removed.

The form needs only the main file on your computer; no model-folder selection
is required. Missing files and cyclic INCLUDE dependencies are reported.
A local import is saved as a self-contained expanded source in the Study, so
reopening does not depend on the original file locations. **Study Options**
also offers **Read Nastran file** directly at startup.

**Loads / Cases** displays imported case-control settings, selected load sets,
equivalent nodal loads and the source-card inventory. **Model / Supports**
displays the selected case's effective SPC constraints, prescribed values,
source sets and GRID displacement coordinate systems. Both selectors update
the viewport. Click a GRID in the tables to inspect its conditions and results.
Tables can be filtered and paged for large models. Support cones and rotation
boxes follow each GRID's displacement axes, including non-BASIC coordinates.
The inventory reports cards without a native interpretation; retaining every
source card does not imply that every Nastran formulation is supported.
Linear static solves apply selected SPCD prescribed values before constraint
recovery, overriding SPC values without double-counting them. SOL106 currently
rejects nonzero prescribed SPC/SPCD motion with an explicit capability message;
it must not silently solve a different boundary condition.

Coordinate systems are available in **Display > Entities**, with optional
CID/type labels in **Axes & Labels**. Their triads use resolved BASIC origins
and defining axes for rectangular, cylindrical and spherical systems.
Generated shell MCIDs retain their actual shared BASIC origin; element-centered
shell axes remain a separate display. **Inspect** also accepts coordinate IDs
(including 0), rigid connections, springs and concentrated masses. Miscellaneous
element families use distinct pink/magenta/violet colors, with pickable lines
and mass/zero-length-spring markers and retained source properties.

The imported source is authoritative: original GRID/EID/PID values,
subcases, constraints and loads are retained. **Analysis > Imported deck analysis**
selects the original solution or SOL101, SOL103, SOL105 or SOL106. An analysis
override creates a separate run deck; it never modifies the stored source or
regenerates wing geometry. SOL105 adds a buckling companion for each static
case. Imported SOL106 runs only the selected nonlinear solution. Modes and
nonlinear convergence controls appear for the corresponding solution.

Concentrated FORCE loads can keep their source settings, use fixed directions,
or follow nodal rotation in SOL101/SOL106. SOL101 uses the first-order load
tangent; SOL106 updates directions during nonlinear iterations. MOMENT,
pressure and body loads stay fixed. Modal/buckling overrides reject retained
follower FORCE cards; choose fixed directions for those analyses. Source
geometry and analysis options both participate in result compatibility checks.
Study files preserve these options. **Run in JFEM** solves the selected deck;
**Results** displays its supported physical fields. **Inspect** and
**Display / Properties** show native shell/beam/material data where supported.
Cards without a viewport representation are reported and remain in the source;
solver support is still governed by JFEM. Displayed units assume consistent SI
input because Nastran files do not declare a unit system.

**Bars 3D** preserves explicit section shapes. Where only an area is available,
it shows an equal-area square for bars/beams or a polygonal circular section for
rods. These are display approximations and do not infer section inertias.
**Display > Appearance > Shell geometry > Physical thickness** extrudes the
property thickness, including laminate Z0. Midsurface remains the default.
Imported element-level ZOFFS and corner thickness overrides are not represented
by this display. Filled shell state is restored when layers are re-enabled,
including after sensitivity and FE-result changes.

Imported Run preparation streams the deck bytes for checksums and reuses the
imported source without restoring the native graph in the GUI process. Log
separates preparation from worker parsing, assembly and solve. A first request
can still include Julia compilation; the solver worker independently reads and
assembles the chosen run deck.

Imported static sensitivities use analytic adjoints for supported PSHELL,
symmetric isotropic PCOMP, MAT1 and T/BAR/ROD PBARL variables. The catalog and
failed-row messages identify unsupported formulations and load-derivative
branches; no finite-difference fallback is used. Imported modal/buckling
sensitivity objectives are unavailable. Generated wing sensitivities retain
their existing modal/buckling support.

**Save Study** embeds the original deck and INCLUDE sources along with view
settings, references, notes and sensitivity setup. Reopening reparses those
sources; it does not depend on an old server token. **Write deck** produces a
self-contained deck with INCLUDE text expanded. Wing geometry/property forms
and TOML export are disabled for imported models. **New Study**, **Load TOML**
or loading a generated Study returns to the wing generator.

## Display and editing

Every left pane collapses with **−** and restores with **+**. Drawing panes
retain a separate Maximize action while expanded. **Collapse all trees / Expand all trees** changes the entity-list layout without
changing model visibility. Rib/stringer labels and rib
datum squares are together under **Display / Axes & labels**.
**Ribs** and **Stringers** are independent on/off checkboxes, like the datum
toggle. Enable both to show both label sets or clear both to hide them. Older
Studies using Off/Ribs/Stringers/Both are migrated without losing the choice.

The viewport supports entity filters, inspection, node/element IDs, local axes,
solid/translucent surfaces, beam sections, reference STL/OBJ/GLB geometry,
measurement and geometry export. Fuel-tank volume and mass properties include
rib-bay contributions. Panel isolation assigns distinct colors and P-labels.
While isolation is active, it controls the shell/beam visibility switches;
loads, aerodynamic surfaces, supports and other overlays remain independent.
**Display / Properties** colors the generated shell and beam properties and
material assignments without an analysis. Values include thickness, area,
section inertias and material E/nu/density, with units and a color scale. For a
sandwich, select its face or core material; no equivalent elastic modulus is
invented. This view uses the current generated FEM and warns about pending edits.
The **Ground** toolbar control includes a synchronized elevation input, shown
only while the ground is visible. Applied
forces and moments are drawn as signed global-axis components (X red, Y green,
Z blue); their lengths/radii retain the chosen display scaling.
VLM-panel arrows are magenta and show the signed normal pressure force at each
panel center. The full aerodynamic resultant is still applied at the rib RBE3s.
Structural faces and solid beam sections use lighting to distinguish orientation,
including when quantitative colors are shown; legends retain the selected palette.
Saved copies of the old unedited lighting presets adopt the improved defaults;
custom lighting remains unchanged.

**Display / Entities / Explode stiffened panels** moves each panel and its
normal stringer rigidly away from the structural-node centroid, midspan,
its own rib-bay center, or the corresponding inboard rib center. Rib origins
follow the actual rib centers, including sweep and twist; runout panels keep
their owning bay. For a panel in R3–R4, the corresponding rib is R3.
Choose the separation distance with the numeric input or manual slider;
uncheck Explode panels to reassemble. Panel edges,
labels, axes and picking follow the displayed panel; shared GRID markers,
loads, aerodynamic geometry and comparison overlays stay at their physical
positions. This changes neither the FEM nor any result. SVG captures the
exploded view; STL/GLB retain physical geometry. The settings travel with a Study.

**Structural Mesh / Stringer runout distance / pitch** defaults to 0.75 for
new studies. A normal stringer terminates at a spar when either skin's
projected x-clearance is below that fraction of its pitch. The ratio must be
greater than zero and at most one. Legacy studies and TOML definitions retain
the original ratio of 1.0 so their existing panel overrides stay attached to
the same physical panels; root stringer pitch is unchanged.

VLM flight cases now support **Mach up to 0.5**, using a Prandtl-Glauert
wind-axis lattice transformation and physical Kutta-Joukowski force recovery.
For example, 120 m/s with a speed of sound of 340 m/s is valid. The model
assumes attached, subsonic small-disturbance flow and does not predict shocks,
stall or aeroelastic feedback. Displayed geometry and applied loads remain in
physical coordinates. The full guide documents the transformation and tests.
Previously saved generated results remain inspectable as historical values
when their geometry matches; rerun analyses before treating them as current.
Imported Nastran results retain their independent source-based checks.

**Display / Environment / Lighting** includes an adjustable camera fill for
underside views. Neutral ambient light and a balanced directional key improve
underside visibility without washing out face contrast. The aerodynamic loft
offers Auto, Metallic, Wireframe and Translucent finishes. Auto uses wireframe
while shell contours are displayed; explicit finishes are always respected.
Sensitivity fields use the undeformed geometry; switch to the primal case in
FE Results for the deformed aero surface. Imported decks without an aero loft
explain why these controls are unavailable. Loading a sensitivity primal case
also exits temporary fuel isolation.

The viewport toolbar switches bars between lines and 3D sections. Selecting
Translucent reveals a percentage slider; Fully solid restores opaque shells.
Supported WebGL 2 devices order translucent fragments by pixel depth, including
batched imported shells. Five dual passes retain up to ten depth layers per
pixel; deeper interiors can be omitted in dense or grazing views, and coincident
faces remain ambiguous. Isolate components or use Solid to inspect such regions.
Unsupported devices keep approximate mesh sorting and report the fallback in
the Log. Explicit **Show bars through surfaces** and measurement overlays stay
visible above the composed surfaces.
Ground elevation appears only when the ground is visible, with source units
identified for imported decks. Panning scales to the viewport and model size,
including millimetre-scale decks; ground bounds follow the imported geometry.
Entity lists have independent collapse/expand buttons saved in the Study.
RBE3 lines are light pink. **Label support force and moment values** adds signed
component values at the visible reaction arrows, using the axis colors.
Returning to **FE Results** exits temporary panel/fuel isolation and restores
the selected physical deformation. Saved sensitivity baselines retain their
binary displacement/rotation buffers through the server response. Malformed
buffers are rejected before they can corrupt the displayed geometry. Modal
section rendering tolerates very small rotations and exaggerated display
scales; an unavailable section shape falls back to its source beam line with
a diagnostic, leaving the analysis deck unchanged.

Planform and structural 2D editors support pan/zoom, background images, snapping,
distance/angle dimensions and SVG export. The dimensioned plan view and property
tables can open in separate browser tabs for another monitor. Detached property
and sensitivity tables include a shared light/dark theme switch.
Consecutive table edits are queued without starting an analysis. Live mesh waits
for unfinished cell edits, then rebuilds after they settle. Existing results stay
marked out of date until an explicitly requested analysis matches the definition;
fields are not mapped onto an incompatible rebuilt mesh.

Every active viewport quantitative color scale provides palette selection, hide/show and
manual minimum/maximum limits. **Automatic** restores the data-driven range.
Manual limits clip only the endpoint colors; numerical data are not changed.
Limits are independent for each quantity/unit. FE, sensitivity and VLM displays
have independent palettes, so changing one legend leaves the others unchanged.
The detached **Sensitivity data** table also has an independent Color scale
selector. Its legend and cell colors use the same fitted data limits; CSV values
remain unchanged. Text contrast adapts to the selected palette.
Unavailable result types have gray labels. Current results are green, while
retained results from an outdated definition retain their warning state. JFEM
activity indicators alternate blue and white (steady blue with reduced motion).
These settings are saved with the Study.

## Analyses and sensitivities

The GUI supports SOL101 static, SOL103 modal, SOL105 linear buckling and an
experimental SOL106 geometric nonlinear comparison. SOL106 also runs a linear
case for comparison and labels partial convergence and accepted load levels.
Follower-force options follow the solver's documented supported formulations.

Under **Loads / Sensitivity**, select one load case, one scalar response and the
design variables. Supported responses are SOL101 displacement/shell/bar stress,
SOL103 eigenvalues and SOL105 buckling factors. Panel-local variables and shared
defaults are distinct variables; the interface shows their actual scope.
The property filter defaults to **Wildcards**. Examples: `P*` (or `P_`) selects names
beginning with P, `*skin*` finds "skin" anywhere, and `*bar*lower*` finds "bar"
followed by "lower" within a name, group or ID. Other characters are literal;
a trailing underscore is a name-prefix shortcut. **Text** and **Regex** modes
remain available for literal phrases and regular expressions. **Add matches**
adds matching variables without clearing earlier selections, so successive
patterns build a selection. Invalid expressions show an error without changing
it. After a mesh update, an existing catalog refreshes to the new definition;
the Run button explains any remaining blocker and offers the relevant recovery
action. Refreshing properties or editing a selection never starts a solve.
The **? Help** button beside the filter explains regex syntax, examples,
additive selection and the difference between clearing a filter and selection.

The default is an **analytic discrete adjoint**. For a static scalar response it
uses one forward solve and one shared adjoint solve, followed by exact chain-rule
element derivatives and contractions. Explicit formulas and automatic
differentiation of native kernels replace property finite differences. The
legacy operator-difference method remains an explicit comparison option.
Read [SENSITIVITY_METHOD.md](SENSITIVITY_METHOD.md) for equations, work counts,
supported formulations and limitations.

Results include signed and normalized derivatives, residual checks, analytic
derivative/solve counts and timings (step comparisons in legacy mode). **Open data table** opens
panel grids and complete/shared-property lists with CSV export. Color fields
automatically fit the actual finite minimum and maximum of the relevant data.
The panel table uses its selected skin, property family, quantity and filter;
raw derivatives with different units have separate scales. All-negative or
all-positive values no longer create an unused opposite half of the scale.
The viewport uses mapped properties and, when enabled, only visible elements.
Explicit manual viewport limits still take precedence. Uniform values have a
single-valued scale; missing derivatives stay gray and are excluded from bounds.

Sensitivity color fields
display the derivative of the selected scalar response with respect to the
property attached to each element, not a new local stress solution. A shared
property repeats its one derivative on its member elements. Local panel
derivatives take precedence over shared defaults in the corresponding field.
Sensitivity table numbers use a labeled blue–neutral–orange scale centered on
zero. Raw derivatives have separate ranges for each unit; normalized values
share a dimensionless range. Limits follow the displayed rows and filter.
Failed/unavailable values remain uncolored, and CSV keeps full precision.

Sensitivity and import workers reuse the selected solver's precompiled package
instead of loading a fresh copy of its source module. Progress and timing files
separate package loading, baseline parsing, analysis, compilation and export.
Installation or source changes can still require a one-time cache rebuild, and
first-use compilation can remain within the generator/solver process. No
stiffness, solve tolerance or derivative formula is changed by this optimization.
Native imports use a separate reusable parser process and avoid parsing the
same deck twice. Its reduced compilation optimization affects import only;
analysis workers retain their normal solver settings. First import still
includes package startup/compilation; subsequent imports reuse that work.

**Results / Sensitivity** becomes available after a sensitivity analysis. Its
**Show sensitivity field** button is orange until the field is displayed, then
green. The primal solution is also available in **Results / FE Results** without
another solve. **Show baseline case** selects that original solved case;
the retained baseline deck and native/portable result files can be
downloaded. Existing solved cases remain available. Completed sensitivity runs
can be reopened without solving. Historical/stale compatibility is checked before
mapping values onto a current mesh.

VLM mesh, pressure/Cp, panel-force vectors and applied RBE3 loads can be displayed
with sensitivities. Each legend names its case. The aerodynamic view represents
the prescribed undeformed lattice, not a newly computed aeroelastic solution.

## Portable checks

Startup prints the Julia version, thread count, package names and versions,
package timings, source-loading phases and local-listener readiness. A separate
progress process keeps elapsed-time messages visible during first-use Julia
compilation. No FEM or analysis is run while loading the application.

From the repository root:

```sh
julia --project=WingFEGen WingFEGen/test/portable_smoke_test.jl
julia --project=WingFEGen WingFEGen/test/portable_smoke_test.jl --native
```

The ordinary smoke test checks the factory model, mesh/deck generation,
aerodynamics, source discovery and browser assets without user data. The native
option additionally exercises a small solver case and adjoint worker, so it takes
longer on first use. Test-generated data are temporary or in an explicitly
selected output directory. Portable browser/data unit checks use Node.js only
when running those developer checks; Node is not a runtime prerequisite.

```sh
node WingFEGen/test/portable_frontend_test.cjs
node WingFEGen/test/study_files_test.cjs
node WingFEGen/test/result_palettes_test.cjs
node WingFEGen/test/property_display_test.cjs
node WingFEGen/test/load_glyphs_test.cjs
node WingFEGen/test/sensitivity_filter_test.cjs
node WingFEGen/test/import_and_table_colors_test.cjs
node WingFEGen/test/panel_explode_test.cjs
node WingFEGen/test/scene_lighting_test.cjs
node WingFEGen/test/support_glyphs_test.cjs
node WingFEGen/test/nastran_import_large_test.cjs
node WingFEGen/test/sections_viewer_test.cjs
node WingFEGen/test/solid_geometry_test.cjs
node WingFEGen/test/imported_analysis_test.cjs
node WingFEGen/test/imported_follower_display_test.cjs
julia --project=WingFEGen WingFEGen/test/startup_progress_test.jl
julia --project=WingFEGen WingFEGen/test/imported_analysis_overlay_test.jl
julia --project=WingFEGen WingFEGen/test/shell_display_payload_test.jl
julia --project=WingFEGen WingFEGen/test/portable_paths_test.jl
julia --project=WingFEGen WingFEGen/test/payload_roundtrip_test.jl
julia --project=WingFEGen WingFEGen/test/nastran_source_test.jl
julia --project=. WingFEGen/test/nastran_import_smoke_test.jl
julia --project=. WingFEGen/test/nastran_case_metadata_test.jl
julia --project=. WingFEGen/test/model_entities_payload_test.jl
julia --project=. WingFEGen/test/follower_metadata_test.jl
julia --project=. WingFEGen/test/imported_analysis_test.jl
```

The solver's separate curated validation suite is described in the repository
[README](../README.md). Development campaigns and user analysis outputs are not
part of this distribution.

## Source layout

| Path | Purpose |
| --- | --- |
| `src/` | Geometry, mesh, properties, loads, solver integration, sensitivities and HTTP server |
| `web/` | Browser UI, rendering and detached editors |
| `web/vendor/` | Bundled browser dependencies and their license notices |
| `examples/wing_default.toml` | Portable factory model definition |
| `test/` | Selected self-contained checks |
| `setup.jl`, platform launchers | Dependency setup and local startup |
| `Project.toml`, `Manifest.toml` | Generator dependency environment |

Original application source is covered by the repository [LICENSE](../LICENSE).
Third-party libraries retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Results availability is evaluated for the selected load case. With no physical
or sensitivity results for that case, its Results labels are gray; retained
results that no longer match the definition remain marked as stale.

For static result display, load-glyph origins, the VLM lattice and VLM force
centers follow the deformed structural shape. Participating aerodynamic FORCE
vectors use SOL101's first-order or SOL106's finite-rotation follower law.
Display magnification affects geometry but never the physical force direction.
Inertial loads and MOMENT directions remain fixed in global axes. Prescribed
VLM pressure is not recomputed as an aeroelastic solution.
