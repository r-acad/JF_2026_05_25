# JFEM Buckling & FE Analysis Web App (pure Julia)

![PANDEATOR with the default stiffened panel ready for analysis](<../../__Start here!__/images/pandeator.png>)

New users can follow the [illustrated setup steps](<../../__Start here!__/README.md>)
and the [original buckling assignment](../../Reference_documentation/07_Exercises/Linear_Finite_Elements_Buckling_exercises_AV_AC_DES_26.pdf).

A browser app with **two analysis sources**, chosen with the *Analysis source*
toggle at the top of the sidebar:

1. **Build stiffened panel** — define a **curved cylindrical stiffened panel**
   (skin + a central "T" stringer running along x), set materials/laminates/
   loads, refine the mesh, and run a **SOL 105 linear buckling** analysis. The
   generated Reference deck is written to disk as a `.bdf` for your reference.
2. **Run a .bdf file** — give a **server-side path** to an existing
   `.bdf`/`.dat`/`.nas` deck and run it as-is. The solution sequence
   (**SOL 101** static, **103** normal modes, **105** buckling, **106**
   nonlinear static) is **auto-detected** from the deck — you don't tell the
   app which one it is. The deck runs *in place*, so its `INCLUDE` cards
   resolve relative to the deck's own folder.

Either way, results are shown interactively in the 3D viewer (mode shapes /
buckling modes / static deformation, labelled by analysis type), the solver's
markdown report is surfaced in a panel, and a **progress modal with a live
elapsed-seconds counter** is shown while the solver runs.

The whole server side is **Julia only** — no Python. The browser talks to a
small Julia HTTP server over **msgpack**.

## Files

| File | Role |
|------|------|
| `panel_app.html`  | The browser app: *Analysis source* toggle (build panel vs. run a deck), parameter form, cylindrical mesh + BDF generator (comma free-field), msgpack client, Babylon.js viewer (`parseJFEM`, v3/v4/v5). |
| `panel_server.jl` | Pure-Julia **msgpack-over-HTTP** server. Serves the app, runs a deck through OpenJFEM in-process, and is **SOL-agnostic** — it detects the SOL from the deck and returns `sol`, `analysis_type`, eigenvalues, frequencies, the report text, and the `.jfem` bytes. Uses `HTTP.jl` + `MsgPack.jl`. |
| `panel_launch.jl` | Cross-platform launcher: starts the server **and** opens the browser. |
| `RUN_PANDEATOR_WINDOWS.cmd`   | Windows double-click launcher (calls `panel_launch.jl`). Honors `JFEM_JULIA` and loads the standard solver image only after its provenance receipt passes. |
| `RUN_PANDEATOR_MAC_LINUX.sh`    | macOS/Linux launcher (`chmod +x` then run). Honors `JFEM_JULIA` and loads the standard solver image only after its provenance receipt passes. |
| `vendor/`         | Local copies of the front-end libraries (`babylon.js` minified, `msgpack.min.js`) so the app loads fast and works fully offline — no CDN needed. The server serves these at `/vendor/...`. |
| `PANEL_APP_README.md` | This runbook. |

`HTTP.jl` and `MsgPack.jl` were added to the OpenJFEM `Project.toml`. The
browser libraries are vendored under `vendor/` (no internet connection
required at runtime).

## Installation and launch

From the repository root, run `setup.cmd` on Windows or `bash setup.sh` on
macOS/Linux. This is the shared installer for JFEM, JFEM-Boxer, PANDEATOR and the
static viewer; no manual package list is needed. PANDEATOR uses the root JFEM
environment. Missing package sources are also installed before first launch;
explicit setup repairs missing artifacts. See
[the installation guide](<../../__Start here!__/README.md>).

- **Windows:** double-click `RUN_PANDEATOR_WINDOWS.cmd`.
- **macOS/Linux:** run `bash APPS/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh` from the repository root.

The launcher uses `JFEM_JULIA` when set, otherwise `julia` on `PATH`. The
checkout's recorded Julia release line is checked before package installation.
The browser opens at `http://127.0.0.1:8088/` after server warm-up. First use may
download dependencies and compile Julia code; duration depends on the machine
and cache. Keep the terminal open; Ctrl+C stops the server. Use `--port 8090` to
choose another port or `--no-open` to open the browser yourself.

### Optional sysimage through the same setup

From the repository root run `setup.cmd --sysimage` or
`bash setup.sh --sysimage`. Add `--dry-run` to inspect the plan without building.
The historical CLICK/RUN installation scripts delegate to this same command.

PANDEATOR's launchers automatically use the standard local image only when
its provenance receipt matches the Julia runtime, source and trained workload.
Otherwise they start with normal Julia. Building is optional and can require
substantial time and RAM; it does not change the solver equations. A sysimage
for the solver/PANDEATOR does not accelerate JFEM-Boxer's separate web-server runtime.
See [setup options](<../../__Start here!__/README.md>) for representative decks,
custom output paths and build thread limits.

### Manual

```
julia --project=<...>/JFEM --threads=auto <...>/JFEM/APPS/PANDEATOR_APP/panel_launch.jl
# or, to run the server without auto-opening a browser:
julia --project=<...>/JFEM --threads=auto <...>/JFEM/APPS/PANDEATOR_APP/panel_server.jl --port 8088
```

Then browse to `http://127.0.0.1:8088/`.

> You *can* also just double-click `panel_app.html` (file://) and use
> **Preview mesh** / **Download .bdf** without a server. To **Analyze**, the
> Julia server must be running; the app will POST to the URL in the
> **Server URL** box (defaults to the page's origin when served by Julia,
> else `http://127.0.0.1:8088`).

## Running an existing deck ("Run a .bdf file")

Pick **Run a .bdf file** in the *Analysis source* toggle and enter the path to
a `.bdf`/`.dat`/`.nas` deck. Notes:

- The path is read **by the Julia server**, so it must exist on the machine
  running the server (the same machine, in the usual local setup). This is a
  server-side path, not a browser upload.
- The **solution sequence is auto-detected** from the deck's executive control
  (`SOL 101/103/105/106`); the deck's own `EIGRL`/`METHOD` is respected — the
  *Modes to extract* box applies only to the form-built panel.
- `INCLUDE` cards resolve relative to the deck's folder (the deck is run in
  place), so multi-file models work.
- Results are labelled by type in the viewer: **Mode k  f=… Hz** (SOL 103),
  **Buckling mode k  λ=…** (SOL 105), **Static deformation** (SOL 101/106).

## Geometry & conventions

- **x** = panel length (stringer axis). **y,z** = cross-section plane.
- The skin is an **arc of radius R** (curvature about the y-direction); the
  crown sits at the mid-width line where the **T stringer** attaches.
- The **T stringer** = a vertical **web** (height *h*) + a flat **foot**
  (width *w*) bonded to the skin crown, both running the full length *x*. The
  web base and foot centerline **share** the skin crown nodes, so the parts
  are structurally connected.
- Geometry is generated in rectangular GRID coordinates, but each GRID
  references a **CORD2C** cylindrical frame via its `CD` field, so constraints
  and loads act in a radial / tangential / axial frame
  (dof 1 = radial, 2 = tangential, 3 = axial along x).
- **Loads** are entered as **force flows (N/mm)**: axial compression `Nx`,
  shear flow `Nxy`, transverse compression `Ny`, lumped to edge nodes.

## Laminate notation

For composite plies the skin/web/foot accept standard notation:

| Input | Expands to |
|-------|-----------|
| `(45/-45/0/90)S` | 45,-45,0,90, **90,0,-45,45** (full symmetric mirror) |
| `(45/-45/0/90)$` | 45,-45,0,90, **0,-45,45** (mid-plane symmetric: mirror excluding the mid ply) |
| `(45/-45/0/90)`  | 45,-45,0,90 (as listed) |
| `2(45/-45)`      | 45,-45,45,-45 (repeat group) |

Symmetry is expanded **client-side** into explicit PCOMP plies, so the deck
lists every ply (no reliance on the solver's SYM handling).

## Where outputs go

Each run gets a separate `<case_id>_<unique>/` directory under the repository's
`output/panel_runs/`. Set `JFEM_PANEL_RUN_ROOT` to choose another writable parent
directory. The response includes the actual output path.

```
<case_id>.bdf              the form-built deck (panel mode only; file mode runs your deck in place)
<stem>.jfem                binary results (mesh + mode shapes / deformation) - also streamed to the browser
<stem>_Subcase_<id>.jfem    separate binary for each SOL 105 subcase when more than one is solved
<stem>.BUCKLING_FILES.JSON ownership manifest for the separate SOL 105 binaries
<stem>.BUCKLING.JSON       eigenvalues + modes  (SOL 103 and 105)
<stem>.JU.JSON             displacements + stresses  (SOL 101)
<stem>.NONLINEAR.JSON      nonlinear results  (SOL 106)
<stem>.REPORT.md           human-readable report
batch_summary.json/.csv    run summary
jfem_case_stdout.log       solver log
```

The exact results-JSON name depends on the auto-detected SOL (the server probes
all of the above). In **file mode** the deck is run from its original location,
so only the derived artifacts above are written into the run dir.

When a SOL 105 deck produces several binary files, the result-file selector
chooses the matching buckling subcase and static preload. The standalone viewer
can also open each binary individually.

Both browser tools use `APPS/jfem_binary.js`. Keep the `APPS/` directory structure
when copying the tools; the panel server also includes
`PANDEATOR_APP/panel_artifacts.jl` for artifact discovery and path checks.

## Notes & limitations

- Eigenvalues are buckling **load factors**: multiply your applied force flows
  by lambda to get the predicted critical load.
- Default BCs model a simply-supported panel (loaded end pinned, far end
  radial-only so it slides to take compression, lateral edges radial). Adjust
  the `spc1(...)` calls in `buildBDF()` for different edge conditions.
- This is a modeling aid; **validate** critical results against a reference
  solver using the written `.bdf`.
