# Stiffened Panel Buckling Web App (pure Julia)

A browser app to define a **curved cylindrical stiffened panel** (skin + a
central "T" stringer running along x), set materials/laminates/loads, refine
the mesh, and run a **SOL 105 linear buckling** analysis through OpenJFEM. The
generated Nastran deck is written to disk as a `.bdf` for your reference, and
the buckling eigenvalues + eigenmodes are shown interactively.

The whole server side is **Julia only** — no Python. The browser talks to a
small Julia HTTP server over **msgpack**.

## Files

| File | Role |
|------|------|
| `panel_app.html`  | The browser app: parameter form, cylindrical mesh + BDF generator (comma free-field), msgpack client, Babylon.js mode-shape viewer (v4 `parseJFEM`). |
| `panel_server.jl` | Pure-Julia **msgpack-over-HTTP** server. Serves the app, writes the `.bdf`, runs SOL 105 through OpenJFEM in-process, returns eigenvalues + the `.jfem` bytes. Uses `HTTP.jl` + `MsgPack.jl`. |
| `panel_launch.jl` | Cross-platform launcher: starts the server **and** opens the browser. |
| `panel_app.cmd`   | Windows double-click launcher (calls `panel_launch.jl`). |
| `panel_app.sh`    | macOS/Linux launcher (`chmod +x` then run). |
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

- **Windows:** double-click **`panel_app.cmd`**.
- **macOS / Linux:** `chmod +x panel_app.sh` once, then `./panel_app.sh`.

The launcher starts the Julia server and, after a moment, opens your default
browser at `http://127.0.0.1:8088/`. The **first** analysis compiles the
solver (~10-60 s); later runs are warm. Press **Ctrl+C** in the terminal (or
close the window) to stop.

### Manual

```
julia --project=<...>/JFEM --threads=auto <...>/JFEM/POST/panel_launch.jl
# or, to run the server without auto-opening a browser:
julia --project=<...>/JFEM --threads=auto <...>/JFEM/POST/panel_server.jl --port 8088
```

Then browse to `http://127.0.0.1:8088/`.

> You *can* also just double-click `panel_app.html` (file://) and use
> **Preview mesh** / **Download .bdf** without a server. To **Analyze**, the
> Julia server must be running; the app will POST to the URL in the
> **Server URL** box (defaults to the page's origin when served by Julia,
> else `http://127.0.0.1:8088`).

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

Each run lands under `POST/panel_runs/<case_id>/`:

```
<case_id>.bdf              the deck you can re-run / validate
<stem>.jfem                v4 binary (mesh + mode shapes) - also streamed to the browser
<stem>.BUCKLING.JSON       eigenvalues + mode shapes
<stem>.REPORT.md           human-readable report
batch_summary.json/.csv    run summary
jfem_case_stdout.log       solver log
```

## Notes & limitations

- Eigenvalues are buckling **load factors**: multiply your applied force flows
  by lambda to get the predicted critical load.
- Default BCs model a simply-supported panel (loaded end pinned, far end
  radial-only so it slides to take compression, lateral edges radial). Adjust
  the `spc1(...)` calls in `buildBDF()` for different edge conditions.
- This is a modeling aid; **validate** critical results against a reference
  solver using the written `.bdf`.
