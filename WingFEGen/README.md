# WingFEGen

WingFEGen is the wing finite-element generator and browser interface included
with OpenJFEM. It generates shell/bar wing structures, aerodynamic lattices and
load cases, writes NASTRAN decks, launches the solver in this repository and
displays structural results and property sensitivities.

The complete application source and browser libraries are in this directory.
No private workspace, downloaded Study, proprietary solver, Node build pipeline
or Python environment is needed to run the application.

## Install and start

Install **Julia 1.12.x**, then clone the repository:

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

1. Choose **Start new study**, **Load last study**, or **Open existing study**.
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
6. Use **Analysis / Run in JFEM**. Open **Results** for displacements, shell/bar
   stresses and forces, modes, buckling or linear/nonlinear comparisons.
7. **Save Study** stores the complete model definition, display settings and
   selected portable reference data. **Save TOML** exports the text definition.
   The browser's file picker/download settings determine the destination.

The definition is saved independently from solved results. Exported decks and
solver result files remain in their run directories. A stale model/result is
identified in the GUI rather than being silently presented as current.

## Display and editing

The viewport supports entity filters, inspection, node/element IDs, local axes,
solid/translucent surfaces, beam sections, reference STL/OBJ/GLB geometry,
measurement and geometry export. Fuel-tank volume and mass properties include
rib-bay contributions. Panel isolation assigns distinct colors and P-labels.

Planform and structural 2D editors support pan/zoom, background images, snapping,
distance/angle dimensions and SVG export. The dimensioned plan view and property
tables can open in separate browser tabs for another monitor. Detached property
and sensitivity tables include a shared light/dark theme switch.

Every active quantitative color scale provides palette selection, hide/show and
manual minimum/maximum limits. **Automatic** restores the data-driven range.
Manual limits clip only the endpoint colors; numerical data are not changed.
Settings are independent for each quantity/unit and saved with the Study.

## Analyses and sensitivities

The GUI supports SOL101 static, SOL103 modal, SOL105 linear buckling and an
experimental SOL106 geometric nonlinear comparison. SOL106 also runs a linear
case for comparison and labels partial convergence and accepted load levels.
Follower-force options follow the solver's documented supported formulations.

Under **Loads / Sensitivity**, select one load case, one scalar response and the
design variables. Supported responses are SOL101 displacement/shell/bar stress,
SOL103 eigenvalues and SOL105 buckling factors. Panel-local variables and shared
defaults are distinct variables; the interface shows their actual scope.

The implementation is a **semi-analytic discrete adjoint**. For a static scalar
response it uses one forward solve and one shared adjoint solve. It then uses
finite differences of assembled operators and fixed-state response recovery for
each property. These evaluations are not perturbed equilibrium solves. Thus the
solve count is independent of property count, while assembly work is not.
Read [SENSITIVITY_METHOD.md](SENSITIVITY_METHOD.md) for equations, sample counts,
step-size effects and the distinction from a fully analytic adjoint.

Results include signed and normalized derivatives, residual checks, step-size
comparisons, solve/operator counts and stage timings. **Open data table** opens
panel grids and complete/shared-property lists with CSV export. Color fields
display the derivative of the selected scalar response with respect to the
property attached to each element, not a new local stress solution. A shared
property repeats its one derivative on its member elements. Local panel
derivatives take precedence over shared defaults in the corresponding field.

**Show baseline case** displays the original solved case through ordinary
Results; the retained baseline deck and native/portable result files can be
downloaded. Existing solved cases remain available. Completed sensitivity runs
can be reopened without solving. Historical/stale compatibility is checked before
mapping values onto a current mesh.

VLM mesh, pressure/Cp, panel-force vectors and applied RBE3 loads can be displayed
with sensitivities. Each legend names its case. The aerodynamic view represents
the prescribed undeformed lattice, not a newly computed aeroelastic solution.

## Portable checks

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
julia --project=WingFEGen WingFEGen/test/portable_paths_test.jl
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
