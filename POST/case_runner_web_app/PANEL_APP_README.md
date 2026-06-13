# JFEM Buckling & FE Analysis Web App (pure Julia)

A browser app with **two analysis sources**, chosen with the *Analysis source*
toggle at the top of the sidebar:

1. **Build stiffened panel** — define a **curved cylindrical stiffened panel**
   (skin + a central "T" stringer running along x), set materials/laminates/
   loads, refine the mesh, and run a **SOL 105 linear buckling** analysis. The
   generated Nastran deck is written to disk as a `.bdf` for your reference.
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
| `RUN_PANDEATOR_WINDOWS.cmd`   | Windows double-click launcher (calls `panel_launch.jl`). Uses plain `julia` (no `julia +release`), and auto-loads `../../sysimage/OpenJFEM_sysimage.dll` via `--sysimage` when it exists. |
| `RUN_PANDEATOR_MAC_LINUX.sh`    | macOS/Linux launcher (`chmod +x` then run). Uses plain `julia` and auto-loads `../../sysimage/OpenJFEM_sysimage.so`/`.dylib` when it exists. |
| `vendor/`         | Local copies of the front-end libraries (`babylon.js` minified, `msgpack.min.js`) so the app loads fast and works fully offline — no CDN needed. The server serves these at `/vendor/...`. |
| `PANEL_APP_README.md` | This runbook. |

`HTTP.jl` and `MsgPack.jl` were added to the OpenJFEM `Project.toml`. The
browser libraries are vendored under `vendor/` (no internet connection
required at runtime).

## Prerequisites

- **Julia** with the OpenJFEM project instantiated. If the new deps aren't
  resolved yet:

  ```
  julia --project=<...>/JFEM -e "using Pkg; Pkg.instantiate()"
  ```

  (No Python, no Node, no other tooling is required.)

## Run

### Easiest - one launcher (Windows / macOS / Linux)

- **Windows:** double-click **`RUN_PANDEATOR_WINDOWS.cmd`**.
- **macOS / Linux:** `chmod +x RUN_PANDEATOR_MAC_LINUX.sh` once, then `./RUN_PANDEATOR_MAC_LINUX.sh`.

The launcher starts the Julia server and, after a moment, opens your default
browser at `http://127.0.0.1:8088/`. The launcher uses whatever `julia` is on
your `PATH` (a 1.12.x Julia; **no juliaup / no `+release` needed**). The
**first** start compiles the server + solver (~1-2 min, shown in the startup
banner); later analyses in the same session are warm. Press **Ctrl+C** in the
terminal (or close the window) to stop.

### Faster startup with a sysimage (optional)

Build a sysimage once per machine using the scripts in the repo-root
**`JFEM_installation/`** folder:

- Windows: `JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd`
- Linux: `./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh` (after `chmod +x`)
- macOS: `JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command`

From then on `RUN_PANDEATOR_WINDOWS.cmd` / `RUN_PANDEATOR_MAC_LINUX.sh` load it automatically
(`--sysimage`), so startup and the first analysis are near-instant. The image is
machine-specific (tied to the exact Julia version + OS + CPU) and git-ignored;
rebuild it after a Julia upgrade. See `JFEM_installation/README.md` for details.

### Manual

```
julia --project=<...>/JFEM --threads=auto <...>/JFEM/POST/case_runner_web_app/panel_launch.jl
# or, to run the server without auto-opening a browser:
julia --project=<...>/JFEM --threads=auto <...>/JFEM/POST/case_runner_web_app/panel_server.jl --port 8088
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

Each run lands under `POST/case_runner_web_app/panel_runs/<case_id>/`:

```
<case_id>.bdf              the form-built deck (panel mode only; file mode runs your deck in place)
<stem>.jfem                binary results (mesh + mode shapes / deformation) - also streamed to the browser
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

## Notes & limitations

- Eigenvalues are buckling **load factors**: multiply your applied force flows
  by lambda to get the predicted critical load.
- Default BCs model a simply-supported panel (loaded end pinned, far end
  radial-only so it slides to take compression, lateral edges radial). Adjust
  the `spc1(...)` calls in `buildBDF()` for different edge conditions.
- This is a modeling aid; **validate** critical results against a reference
  solver using the written `.bdf`.
