# OpenJFEM

> **Last pushed: 2026-09-17.** `main` is the current, default branch — a
> plain clone includes the September solver audit, corrected buckling and
> sensitivity algorithms, output improvements, and deployment checks:
>
> ```bash
> git clone https://github.com/r-acad/JF_2026_05_25.git
> cd JF_2026_05_25
> ```
>
> `Manifest.toml` records the dependency versions. Run the curated public
> validation suite using the commands below to check an installation.
> The earlier `decalibration/strip-tier-a` work is merged into `main`.

OpenJFEM is a Julia finite-element solver focused on fast linear buckling
analysis for bulk-data structural models. It reads an input deck, builds the
finite-element model, solves the requested case, and writes a run manifest plus
human-readable reports and optional visualization files.

The recommended workflow is intentionally small:

1. Install Julia 1.12.x.
2. Click one platform setup file in `JFEM_installation/`.
3. Run single cases or batches with the `jfem` launcher.
4. For Python-driven optimization loops, keep one JSONL worker open and submit
   batch manifests repeatedly so Julia startup and compilation are not paid per
   iteration.

## One-Click Installation

After cloning the repository, run exactly one setup launcher from
`JFEM_installation/`. The launcher installs every Julia package declared by
`Project.toml` and `Manifest.toml`, then creates the local sysimage used for
fast startup.

| Platform | Setup file |
|---|---|
| Windows | `JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd` |
| macOS | `JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command` |
| Linux | `JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh` |

Windows users can double-click the `.cmd` file. macOS users can double-click
the `.command` file. Linux users should run the `.sh` file from a terminal,
making it executable once if needed:

```bash
chmod +x JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
```

When the setup finishes, run a deck from the repository root:

```powershell
.\jfem C:\models\my_model.bdf
```

```bash
./jfem ~/models/my_model.bdf
```

See [`JFEM_installation/README.md`](JFEM_installation/README.md) for the
plain-language installer guide, representative-deck options, offline notes, and
troubleshooting.

## Requirements

- Julia 1.12.x
- Git
- One or more bulk-data input decks, usually with `.bdf`, `.dat`, or `.nas`
  extension

Run all commands from the repository root. The repository tree below uses `/`
as a visual convention. Command examples are written separately for Windows
PowerShell and Linux/macOS Bash, and each command is a single line with no
line-continuation character.

## Repository Layout

```text
.
|-- Project.toml
|-- Manifest.toml
|-- JFEM_installation/
|   |-- CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd
|   |-- RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
|   |-- CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command
|   |-- julia_tools/
|   |   |-- deploy_fast.jl
|   |   |-- install_julia_packages.jl
|   |   |-- jfem.jl
|   |   |-- run_bdf.jl
|   |   |-- run_bdf_batch.jl
|   |   |-- run_batch_manifest.jl
|   |   `-- jfem_worker_jsonl.jl
|   |-- examples/
|   |   |-- manifests/
|   |   `-- precompile/
|   `-- python_client/
|       |-- jfem_client.py
|       `-- jfem_manifest_cli.py
|-- src/
|-- validation/
|   |-- public_suite.yaml
|   |-- run_public_suite.jl
|   |-- cases/
|   |-- analytical/
|   `-- references/
|-- POST/
|   |-- JFEM_results_viewer/
|   |   |-- postv11.html
|   |   `-- POST_GUIDE.html
|   `-- PANDEATOR_APP/
|       |-- RUN_PANDEATOR_WINDOWS.cmd
|       |-- RUN_PANDEATOR_MAC_LINUX.sh
|       |-- panel_app.html
|       |-- panel_server.jl
|       |-- PANEL_APP_README.md
|       `-- vendor/
|-- general_description.md
`-- README.md
```

- `src`: solver source code.
- `JFEM_installation/julia_tools/deploy_fast.jl`: preferred one-command fast deployment and broad
  precompile setup.
- `JFEM_installation/examples/precompile`: tiny bundled decks used only by
  `deploy_fast.jl` when the user does not provide representative cases.
- `JFEM_installation/examples/manifests`: runnable JSON manifest templates for
  installation and automation checks.
- `JFEM_installation/julia_tools/run_batch_manifest.jl`: JSON manifest batch runner for explicit
  input/output mapping.
- `JFEM_installation/julia_tools/jfem_worker_jsonl.jl`: persistent JSONL worker for Python-driven
  optimization loops.
- `JFEM_installation/python_client/jfem_client.py`: Python 3.8+ stdlib-only
  helper for writing manifests and talking to the JSONL worker.
- `JFEM_installation/python_client/jfem_manifest_cli.py`: Python command-line
  helper for creating and running manifests from external workflows.
- `validation`: public, paper-facing validation suite. It contains only
  public or permissively licensed decks and references: MacNeal-Harder,
  classical buckling, MYSTRAN cross-checks, and CRM/uCRM. It intentionally
  excludes private GAME, HTP, and VTP cases.
- `jfem` (Linux/macOS) and `jfem.cmd` (Windows): one-line wrappers to analyze a
  single deck with good defaults — see "Quickest Way To Run A Deck" below. They
  call `JFEM_installation/julia_tools/jfem.jl`, the underlying simple single-deck runner.
- `JFEM_installation/`: first-time setup launchers with explicit Windows,
  Linux, and macOS filenames. Each launcher installs Julia packages and creates
  the optional sysimage that makes the solver and web app start near-instantly.
- `JFEM_installation/julia_tools/run_bdf.jl`: explicit single-case runner (what the wrapper
  runs for you).
- `JFEM_installation/julia_tools/run_bdf_batch.jl`: simple text-list batch runner retained
  for existing scripts. New automation should use `run_batch_manifest.jl`.
- `POST/JFEM_results_viewer/postv11.html`: browser viewer for `.jfem` result files.
- `POST/PANDEATOR_APP/panel_app.html` +
  `POST/PANDEATOR_APP/panel_server.jl`: interactive web app that
  builds a stiffened panel **or** runs an existing `.bdf`/`.dat`/`.nas` deck
  (SOL 101/103/105/106 auto-detected) and renders results in 3D. On Windows,
  double-click `POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd`; see
  `POST/PANDEATOR_APP/PANEL_APP_README.md`.
- `general_description.md`: broader description of solver capabilities.

## Installation And Fast Deployment

Clone the repository and enter it:

Windows PowerShell:

```powershell
git clone <repository-url> OpenJFEM
cd OpenJFEM
```

Linux/macOS Bash:

```bash
git clone <repository-url> OpenJFEM
cd OpenJFEM
```

Run one setup launcher once after installation or after updating the solver.
This is the same one-click setup described above: it installs the Julia
packages, then builds the local sysimage. With no user-supplied deck, OpenJFEM
uses bundled tiny SOL 101, SOL 103, and SOL 105 decks from
`JFEM_installation/examples/precompile` to warm common parser, assembly, solve,
and report paths.

Windows:

```powershell
.\JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd
```

Linux:

```bash
chmod +x JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
```

macOS:

```bash
open JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command
```

For best performance on a specific model family, add one or more representative
decks when launching from a terminal:

Windows PowerShell:

```powershell
.\JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd --deck C:\models\representative_sol105.bdf
```

Linux/macOS Bash:

```bash
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh --deck /home/user/models/representative_sol105.bdf
```

You can also build from a JSON batch manifest:

```powershell
.\JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd --manifest C:\models\cases.json
```

What this does:

- Julia downloads/instantiates the packages declared by `Project.toml` and
  `Manifest.toml`.
- Julia compiles functions when it first sees the specific data types and code
  paths used by a run.
- The bundled decks exercise common SOL 101, SOL 103, and SOL 105 paths.
- Representative user decks exercise the exact element, material, property,
  load, constraint, and output paths expected in production.
- The sysimage is written under `sysimage/` and loaded automatically by
  `jfem`, `jfem.cmd`, and the web-app launchers when its build receipt matches
  the project, runtime, image and recorded workload.
- The sysimage is a startup-speed optimization only. It does not change the
  model, solver equations, load factors, or numerical results.

Deployment explicitly refreshes the OpenJFEM package cache when representative
decks or workload flags are requested. Missing explicit inputs or failed explicit
workloads fail visibly. Automatic sysimage selection falls back to ordinary
package loading when the receipt is absent or stale, including after moving the
project or removing a recorded workload deck. Rebuild with `deploy_fast.jl` to
refresh it. The receipt covers project code and dependency locks; arbitrary
edits inside an installed global package depot are outside this check. Manual
`julia -J` selection bypasses the automatic guard. Validating an existing image
adds a launcher step; measure installed startup separately from warm solves.

## Fast Settings

The commands below assume the one-click setup above has already been run. They
use the default fast operating profile:

- `--threads=auto`: lets Julia use available CPU threads for assembly.
- `--startup-file=no`: avoids user startup files changing the run.
- `JFEM_EXPORT_BINARY=false`: skips `.jfem` binary export for maximum solve
  throughput.
- `JFEM_MATRIX_ASYMMETRY_CHECK=false`: skips an expensive buckling diagnostic
  matrix difference in production runs. The stiffness pair is still
  symmetrized before the eigenproblem.
- `JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false`: skips the duplicate in-memory
  `mode_shapes` list in the returned Julia dictionary. Report and JSON/VTK/HDF5
  exports still use the raw mode matrix.
- `JFEM_SUPPRESS_THREAD_HINT=1`: keeps batch logs compact.

Use this flag string in direct single-case and text-batch runs:

```text
JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1
```

### Performance Notes (2026-09)

Default mode-list construction uses less temporary storage for Float64 modes
while retaining mutable per-node dictionaries and the existing return types.
HDF5 input-table sorting caches numeric GRID and element IDs once, preserving
node order and file schemas. Buckling VTK exports reuse compressed mesh data
within each export call, with independent mode data and output documents;
unsupported WriteVTK interfaces retain the regular writer. Static and buckling
VTK exports also support Windows extended paths. Total run time still depends
on assembly, extraction, compilation and selected formats.
Compact SOL105 composite recovery avoids interior-ply and force-resultant
calculations that its binary endpoint fields do not consume. Validation caches
last for one recovery call; full composite recovery still evaluates every ply.

SOL 105 now treats the EIGRL card as the eigensolver contract, rather than as
an output-only cap:

- **Exact `ND` request**: an explicit EIGRL `ND=n` issues a partial spectral
  request for exactly `n` eigenvalues and eigenvectors. It no longer asks for
  `8*ND`, `3*ND`, `ND+5`, or a second range-completeness spectrum and then
  discards the surplus. Dense full-spectrum extraction is not used for a
  partial `ND`, even on a small model. KrylovKit can expose additional Ritz
  pairs that converged simultaneously (its API promises *at least* the
  requested count); JFEM records that raw count but, on each backend
  invocation, examines and back-transforms no more than `ND` candidates and
  retains, expands, and publishes no more than `ND` pairs. A residual-driven
  retry is a new backend invocation and again requests exactly `ND`.
- **Direct range targeting**: V1/V2 requests shift directly to the applicable
  lower or upper bound. Explicit `ND` normally skips a full range certificate.
  When all requested pairs pass the residual check but a finite upper bound
  excludes some, a positive-definite shifted pencil of at most 600 active DOFs
  can certify that the independent retained modes exhaust the interval and
  avoid an unnecessary retry. Larger systems and uncertain counts retain the
  retry while reusing the unchanged shifted factor within the solve.
  `JFEM_SOL105_STURM_COMPLETENESS=true` remains an
  optional diagnostic. Blank `ND` retains its distinct Nastran all-roots semantics for
  small problems; large all-roots requests fail clearly and ask for an
  explicit `ND` instead of starting an accidental O(n^2) Krylov run.
- **Accepted pairs are verified**: only converged Ritz pairs with a finite
  original-pencil backward residual (default limit `1e-6`) are published.
  If the first pass is partial, one same-target retry keeps the same exact
  `ND` request while tightening the transformed-space tolerance (default
  `JFEM_SOL105_KRYLOV_RETRY_TOL=1e-16`). Independent accepted pairs from the
  two starts are merged using an orthonormal basis to distinguish repeated
  eigenspaces from duplicate vectors; any remaining shortage is reported instead
  of filling `ND` with unconverged vectors.
- **Large finite factors remain valid**: an exactly zero transformed root is
  treated as an infinite mode, but a merely small nonzero transformed value is
  not discarded through a fixed cutoff. This preserves finite buckling factors
  above `1e14` when their original-pencil residual is acceptable.
- **EIGRL V1/V2/ND semantics are preserved**: blank V1, V2, and ND fields remain
  distinguishable from explicit zeros; negative and open bounds are signed
  and inclusive. Global `METHOD`, local overrides, and `STATSUB` selection are
  resolved deterministically. Invalid or missing references now produce an
  input error instead of silently solving three modes.

`SHFSCL`, `MAXSET`, and EIGRL `NORM` are retained by the parser but are not
yet numerical controls of the SOL 105 eigensolver.

Planar ordinary MAT1 Q4 shells use tied transverse gradients in the KDJJ
geometric stiffness to improve skew-mesh buckling. Exact rectangular elements
retain the equivalent original arithmetic. This change is limited to the
transverse block; warped shells, normal/director transformations and coupled
or anisotropic properties retain their existing formulation.

With `AUTOSPC=NO`, static preload solves exclude coordinates whose full
stiffness row and column are exactly zero, provided they carry no load.
Their displacements are set to zero without adding supports. Loading such
a coordinate raises an error, including on a cached subsequent subcase.
Diagnostics report active, inactive and constrained coordinates separately.

The earlier assembly improvements remain active:
- **Deterministic threading**: results are bit-identical at any
  `--threads` count (positional-slot assembly plus a pinned inner
  eigensolver thread pool), so `--threads=auto` is both the fastest and a
  reproducible choice.
- **Allocation-free element hot paths**: the CQUAD4 MacNeal shear
  construction runs against per-thread workspaces (per-invocation
  allocation down ~97%), repeated buckling subcases refill the geometric
  stiffness matrix through a cached sparsity pattern
  (`JFEM_KG_VALUES_ONLY_CSC=false` opts out), the eigen partition reuses
  its stability-trial factorization (`JFEM_EIGEN_TRIAL_FACTOR_KEEP=false`
  opts out), and binary exports are staged as a single write. All are
  verified bit-identical.
- **Research opt-ins** (OFF by default):
  `JFEM_SOL105_SHIFT_FACTOR_FUSION=true` fuses shifted-solve
  factorizations with Sturm certificates;
  `JFEM_SOL105_SYMM_LANCZOS=true` runs the zero-shift buckling
  eigensolve as symmetric Lanczos via a Cholesky congruence; and
  `JFEM_SOL105_BLOCK_LANCZOS=true` uses deterministic block starts (default
  block size 2) to preserve exact repeated eigenspaces. The block option may
  construct more Ritz pairs than `ND` and was slower on the audited large
  case, so it is intentionally outside the default exact-count profile.

## Quickest Way To Run A Deck

For everyday use there is a one-line wrapper that fills in Julia, the project,
threads, and good default options for you. The solution sequence
(SOL 101 / 103 / 105 / 106) is auto-detected from the deck.

Windows:

```bat
jfem  C:\models\my_model.bdf
```

Linux/macOS (make it executable once with `chmod +x jfem`):

```bash
./jfem  ~/models/my_model.bdf
```

That writes the **viewer-ready set** — the `.jfem` binary (opens in the POST 3D
viewer), `REPORT.md`, and the results JSON — into `<deck_dir>/<deckname>_out/`,
right next to the input deck.

### How to invoke it (important): `jfem` vs `.\jfem` / `./jfem`

By design, **shells do not run a program from the current directory by typing
its bare name** — the directory must be on your `PATH` first. This is true on
Windows PowerShell, Linux, and macOS alike. So if you `cd` into the repo and
type `jfem ...`, you will get *"jfem is not recognized"* (Windows) or
*"command not found"* (Linux/macOS) until you do one of the following.

**Option A — run it from the repo folder with a path prefix (no setup):**

```powershell
# Windows PowerShell (runs jfem.cmd):
.\jfem  .\my_model.bdf
```

```bash
# Linux/macOS (runs the jfem bash script):
./jfem  ./my_model.bdf
```

**Option B — call `jfem` from anywhere (one-time setup):** add the repository
root to your `PATH`.

```powershell
# Windows PowerShell - add to your USER PATH (persists; reopen the terminal):
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";C:\path\to\JFEM",
  "User")
```

```bash
# Linux/macOS - add to PATH in ~/.bashrc or ~/.zshrc:
echo 'export PATH="$PATH:/path/to/JFEM"' >> ~/.bashrc
# ...or symlink the script into a directory already on PATH (common idiom):
ln -s "/path/to/JFEM/jfem" ~/.local/bin/jfem
```

After Option B, plain `jfem my_model.bdf` works from any directory.

**Linux/macOS only — the execute bit.** The `jfem` script must be executable.
A fresh `git clone` preserves this, but if it was lost run once:

```bash
chmod +x jfem
```

> The repo ships two launcher files: `jfem.cmd` (Windows) and `jfem` (the bash
> script for Linux/macOS). On Windows, `.\jfem` resolves to `jfem.cmd`
> automatically. The sysimage is platform-specific — `jfem.cmd` looks for
> `sysimage\OpenJFEM_sysimage.dll`, while `jfem` looks for
> `sysimage/OpenJFEM_sysimage.so` (Linux) or `.dylib` (macOS); build it on each
> machine with the sysimage helper.

Give a second argument to choose the output folder:

```bat
jfem  C:\models\my_model.bdf  D:\jfem_runs\run1
```

### Choosing which output files to write

Put an optional format string **before** the deck: a `-` followed by letters in
any order. Each letter turns on one output type. If you omit the string you get
the default set `-jrs`.

| Letter | Output |
|---|---|
| `j` | `.jfem` binary (3D viewer) |
| `r` | `REPORT.md` (markdown report) |
| `s` | results JSON (`BUCKLING`/`JU`/`NONLINEAR` per SOL) |
| `v` | VTK files (ParaView) |
| `h` | HDF5 (`.h5`) |
| `m` | model JSON dump |
| `c` | card inventory |

Anisotropic, independently assigned-material and MID4 PSHELL stress recovery
is currently incomplete. Affected force/stress/strain rows are omitted with
recovery diagnostics; displacements and support reactions remain available.
Supported ordinary PSHELL stresses use the property's `Z1` and `Z2` fiber
distances, defaulting to `-T/2` and `+T/2`. Changing these output locations does
not change the shell force resultants or generalized membrane strains and
curvatures.
Blank fiber locations follow the current thickness during design updates;
explicit distances remain fixed. Stress-response gradients currently require
default fiber locations and reject explicit/custom locations, including
explicit distances that happen to equal the initial `-T/2` and `+T/2`.
HDF5 PSHELL metadata records the effective fiber distances at the current
thickness. For programmatic edits, set `Z1_DEFAULT` or `Z2_DEFAULT` to `false`
when replacing a parsed blank location with a fixed numeric distance.
Supported shell stress rows include ordered principal stresses. Generalized
strain rows include principal membrane strains and principal Nastran-sign
curvatures; those rows retain their existing units and are not fiber strains.
VTK and Markdown use recovered von Mises values for ordinary shells and the
all-ply maximum for supported composites. Principal values remain available
in JSON; the current binary and HDF5 schemas do not add principal-value slots.
The compact SOL105 binary static block retains its endpoint stress convention:
for composites it uses the first and last ply midplanes, so it can differ from
the all-ply maximum in VTK and Markdown when an interior ply governs.
Beam/rod scalar stresses remain absolute axial stresses and exclude combined
bending, shear and torsion. Markdown labels mixed stress summaries accordingly;
the legacy VTK non-shell scalar entries retain this axial-only limitation.
VTK retains geometry/displacements and omits an unavailable stress array.
SOL105 binary output omits an incomplete optional static block. Static binary
output is skipped when its fixed shell fields cannot represent missing results,
with a `.BINARY_UNAVAILABLE.JSON` explanation. JSON contains the recovery
diagnostics; JSON/HDF5 retain available nodal results.

Examples:

```bat
jfem  -rs       model.bdf            :: only the report and results JSON
jfem  -jrsvh    model.bdf  out       :: viewer + report + JSON + VTK + HDF5
```

```bash
./jfem  -rs     model.bdf            # only the report and results JSON
./jfem  -jrsvh  model.bdf  out       # viewer + report + JSON + VTK + HDF5
```

A `run_manifest.json` recording the exact inputs and flags is always written.
The wrappers use whatever `julia` is on `PATH` (Julia 1.12.x; no juliaup
needed) and automatically load a prebuilt sysimage from `sysimage/` when its
build receipt matches. (See "How to invoke it" above to call `jfem` from any
directory.)

### Rebuild The Local Sysimage

Each fresh Julia environment pays one-time compilation cost. The one-click
installation step builds a **sysimage** once per machine so the launchers start
quickly, including the first analysis. Re-run the same setup file after
upgrading Julia, changing package dependencies, or pulling major solver changes:

```bat
JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd          :: Windows
```

```bash
chmod +x JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh              # Linux
open JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command      # macOS
```

The sysimage is optional for correctness: everything works without it, just
slower to start.
See [`JFEM_installation/README.md`](JFEM_installation/README.md) for details.

The sections below show the fully explicit `julia ... run_bdf.jl` form, which
the wrapper runs for you and which you may still prefer for scripting or batch
automation.

## Public Validation Suite

The paper validation cases live in `validation/`. Run the full public suite
from the repository root with:

Windows PowerShell:

```powershell
.\validation\run_public_validation.ps1
```

Linux/macOS Bash:

```bash
julia --startup-file=no --project=. validation/run_public_suite.jl
```

The suite writes `validation/comparison.csv` and `validation/comparison.md`.
The maintained suite has 19 scalar rows. Seventeen have declared reference
solver parity targets, and all 17 passed the September 15 run. The
accuracy checks pass on 17 of 19 rows; the coarse curved-beam and pinched-cylinder
meshes retain their documented analytical discrepancies. Matching a reference
solver on the same mesh does not establish mesh-converged accuracy. Rerun the
suite to regenerate the local report for the current solver revision.

The package release gate runs the curated suite without rewriting its reports:

```julia
using Pkg
Pkg.test()
```

Run this from Julia started with `--project=.` at the repository root. The test
target declares its YAML dependency and fails on execution errors, skipped
results, reference parity failures, or new analytical failure cases. The two
existing analytical limitations remain visible in the test output. Private
industrial reference campaigns are maintained separately in the development
workspace.

## Run One SOL 105 Case

Use this command for a single buckling deck:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. .\JFEM_installation\julia_tools\run_bdf.jl C:\models\panel_001.bdf output\panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. ./JFEM_installation/julia_tools/run_bdf.jl /home/user/models/panel_001.bdf output/panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Read the command from left to right:

- `julia`: starts Julia.
- `--threads=auto`: lets Julia use available CPU threads.
- `--startup-file=no`: ignores any local Julia startup script.
- `--project=.`: selects the OpenJFEM Julia environment in the current
  repository root.
- `.\JFEM_installation\julia_tools\run_bdf.jl` or
  `./JFEM_installation/julia_tools/run_bdf.jl`: runs one input deck.
- `C:\models\panel_001.bdf` or `/home/user/models/panel_001.bdf`: this is the
  input file to solve. Replace it with your SOL 105 deck.
- `output\panel_001` or `output/panel_001`: this is the output folder
  created by OpenJFEM for this run.
- the quoted `JFEM_...` string: speed-oriented run flags. Keep the quotes.

The output folder is the second path after the input deck. To write results to
a custom folder, change that argument:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. .\JFEM_installation\julia_tools\run_bdf.jl C:\models\panel_001.bdf D:\jfem_runs\panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. ./JFEM_installation/julia_tools/run_bdf.jl /home/user/models/panel_001.bdf /home/user/jfem_runs/panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Outputs are written under the output directory:

Windows:

```text
output\panel_001\run_manifest.json
output\panel_001\panel_001.REPORT.md
```

Linux/macOS:

```text
output/panel_001/run_manifest.json
output/panel_001/panel_001.REPORT.md
```

For the example above, `panel_001.REPORT.md` is the main result file to open.
It is named from the input file stem: `panel_001.bdf` becomes
`panel_001.REPORT.md`.

The report contains the buckling load factors, model counts, active flags, and
solver timing.

## First Production Interface: JSON Manifests

The first production automation interface is manifest-based. A manifest is a
small JSON file that describes the run before Julia starts solving anything.
It is robust because the external workflow does not depend on shell quoting,
current working directory assumptions, or positional command arguments for
every case.

The same manifest can be used by:

- a command-line batch run;
- a Python optimization loop;
- a job scheduler;
- a future faster worker or sysimage-based deployment.

Required manifest fields:

| Field | Meaning |
|---|---|
| `output_root` | batch-level output folder where summaries are written |
| `cases` | list of cases to solve |
| `cases[].input` | input `.bdf`, `.dat`, or `.nas` deck |

Recommended manifest fields:

| Field | Meaning |
|---|---|
| `batch_id` | readable name for the batch |
| `defaults.flags` | default `JFEM_*` run flags for all cases |
| `defaults.output_options` | result formats to write; use `eigenvalues_only` and `report` for optimization loops |
| `defaults.gc_between` | run garbage collection between cases |
| `defaults.stop_on_error` | stop the batch at the first failed case |
| `cases[].case_id` | stable case name used in summaries |
| `cases[].output_dir` | exact output folder for that case |

You can write the JSON file yourself, or generate it from existing decks with
the included Python helper.

Create a manifest from one directory of decks:

Windows PowerShell:

```powershell
python .\JFEM_installation\python_client\jfem_manifest_cli.py make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --batch-id batch_001
```

Linux/macOS Bash:

```bash
python ./JFEM_installation/python_client/jfem_manifest_cli.py make --input-dir /home/user/models --manifest /home/user/models/cases.json --output-root /home/user/jfem_runs/batch_001 --batch-id batch_001
```

Create a manifest from specific decks:

Windows PowerShell:

```powershell
python .\JFEM_installation\python_client\jfem_manifest_cli.py make --input C:\models\panel_001.bdf --input C:\models\panel_002.bdf --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --batch-id batch_001
```

Linux/macOS Bash:

```bash
python ./JFEM_installation/python_client/jfem_manifest_cli.py make --input /home/user/models/panel_001.bdf --input /home/user/models/panel_002.bdf --manifest /home/user/models/cases.json --output-root /home/user/jfem_runs/batch_001 --batch-id batch_001
```

## Run a Batch of SOL 105 Cases

For more than one case, use a JSON batch manifest. This is the preferred
command-line batch interface because every input deck, output folder, run flag,
and output option is explicit.

In JSON files, using `/` as the path separator is valid on Windows, Linux, and
macOS. That keeps the examples easier to read and avoids escaping every
backslash.

Example `cases.json`:

```json
{
  "batch_id": "batch_001",
  "output_root": "D:/jfem_runs/batch_001",
  "defaults": {
    "flags": {
      "JFEM_EXPORT_BINARY": "false",
      "JFEM_MATRIX_ASYMMETRY_CHECK": "false",
      "JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES": "false",
      "JFEM_SUPPRESS_THREAD_HINT": "1"
    },
    "output_options": {
      "binary": false,
      "json": true,
      "report": true
    },
    "gc_between": true,
    "stop_on_error": false
  },
  "cases": [
    {
      "case_id": "panel_001",
      "input": "C:/models/panel_001.bdf",
      "output_dir": "D:/jfem_runs/batch_001/panel_001"
    },
    {
      "case_id": "panel_002",
      "input": "C:/models/panel_002.bdf",
      "output_dir": "D:/jfem_runs/batch_001/panel_002"
    }
  ]
}
```

Run it:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. .\JFEM_installation\julia_tools\run_batch_manifest.jl C:\models\cases.json --quiet
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. ./JFEM_installation/julia_tools/run_batch_manifest.jl /home/user/models/cases.json --quiet
```

Run the included manifest example:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. .\JFEM_installation\julia_tools\run_batch_manifest.jl .\JFEM_installation\examples\manifests\sol105_batch_manifest.json --quiet
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. ./JFEM_installation/julia_tools/run_batch_manifest.jl ./JFEM_installation/examples/manifests/sol105_batch_manifest.json --quiet
```

The batch writes:

```text
<output_root>/batch_summary.csv
<output_root>/batch_summary.json
<output_root>/<case_id>/run_manifest.json
<output_root>/<case_id>/<input_stem>.REPORT.md
<output_root>/<case_id>/<input_stem>.JU.JSON
<output_root>/<case_id>/jfem_case_stdout.log
```

When `output_options.report` is `false`, the `.REPORT.md` file is skipped and
the `report` column in `batch_summary.csv` is left blank for that case.
For modal and buckling runs, `batch_summary.csv` and `batch_summary.json` also
include `sol_type`, `eigenvalue_count`, `first_eigenvalue`, and the full
`eigenvalues` vector. This lets optimization scripts read buckling factors from
one summary file without reopening every case result JSON.
When mode shapes are written, the summary also includes `mode_shape_count`,
`mode_shapes_available`, and `result_json`, which points to the per-case JSON
file containing the eigenvectors.

Use JSON manifests when another program needs exact control of input paths,
output paths, and output options. The `.JU.JSON` file is written when
`"json": true` is present in `output_options`.

For SOL 105 optimization loops that only need buckling load factors, add:

```json
"eigenvalues_only": true
```

inside `output_options`. This skips full mode-shape expansion and disables
mode-dependent exports such as VTK, HDF5, and `.jfem` for that run. Add
`"report": false` when the optimizer reads `.BUCKLING.JSON` or
`batch_summary.csv` directly and does not need `.REPORT.md` files.

If the optimization algorithm also needs buckling eigenvectors, use:

```json
"eigenvectors": true
```

inside `output_options` instead of `eigenvalues_only`. This keeps mode-shape
recovery enabled and writes the eigenvectors to `.BUCKLING.JSON` under
`modes[].mode_shape`. The path is also recorded in
`batch_summary.json` as `cases[].result_json`.

## Python Optimization Loop

For heavy optimization, Python should not launch Julia for every case or every
iteration. Run Python from the repository root, or put the repository root on
`PYTHONPATH`, then start one OpenJFEM JSONL worker, keep it warm, and send
batch manifests repeatedly.

Python example:

```python
from pathlib import Path
from JFEM_installation.python_client.jfem_client import (
    JFEMWorker,
    load_summary,
    write_batch_manifest,
)

repo = Path(r"C:\path\to\OpenJFEM")

with JFEMWorker(repo_root=repo, threads="auto") as worker:
    for iteration in range(100):
        output_root = repo / "JFEM" / "output" / f"opt_{iteration:04d}"
        cases = [
            {
                "case_id": f"design_{iteration:04d}",
                "input": rf"C:\opt\decks\design_{iteration:04d}.bdf",
                "output_dir": str(output_root / f"design_{iteration:04d}"),
            }
        ]
        manifest = write_batch_manifest(
            output_root / "cases.json",
            cases,
            output_root,
            batch_id=f"opt_{iteration:04d}",
            output_options={
                "binary": False,
                "json": True,
                "eigenvalues_only": True,
                "report": False,
            },
        )
        response = worker.run_batch(manifest)
        summary = load_summary(response["summary_json"])
        first_buckling_factor = summary["cases"][0]["first_eigenvalue"]
        all_buckling_factors = summary["cases"][0]["eigenvalues"]
        # Use factors, update design variables, generate next decks.
```

When eigenvectors are needed, create the manifest with:

```python
output_options={
    "binary": False,
    "json": True,
    "eigenvectors": True,
    "report": False,
}
```

Then read the per-case JSON path from:

```python
mode_json = summary["cases"][0]["result_json"]
```

The JSONL worker keeps stdout as protocol-only JSON. Solver output is written
to each case's `jfem_case_stdout.log`, which makes the protocol safe for Python
parsing.

The example uses `eigenvalues_only=True` and `report=False`, which is the
preferred setting when the optimizer reads buckling factors from JSON/CSV and
does not inspect mode shapes or Markdown reports.

This is the fastest production automation path currently exposed by OpenJFEM:

```text
deploy once -> start JSONL worker once -> Python sends many manifests -> Python reads summaries/results
```

For a simple one-manifest Python-triggered production run, use:

Windows PowerShell:

```powershell
python .\JFEM_installation\python_client\jfem_manifest_cli.py run-worker C:\models\cases.json --repo-root .
```

Linux/macOS Bash:

```bash
python ./JFEM_installation/python_client/jfem_manifest_cli.py run-worker /home/user/models/cases.json --repo-root .
```

For heavy optimization, prefer the `JFEMWorker` example above so the same Julia
worker remains open across many design iterations.

To create an eigenvalues-only manifest from the command line:

```powershell
python .\JFEM_installation\python_client\jfem_manifest_cli.py make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --eigenvalues-only --no-report
```

To request eigenvectors instead:

```powershell
python .\JFEM_installation\python_client\jfem_manifest_cli.py make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --export-eigenvectors --no-report
```

## Post-Processing

The fastest commands above skip `.jfem` export. When you need interactive
visual inspection, enable binary export for that run and open:

```text
POST/JFEM_results_viewer/postv11.html
```

The viewer loads `.jfem` result files directly in the browser. See
`POST/JFEM_results_viewer/POST_GUIDE.html` for its controls.

## Reading SOL 105 Results

For buckling cases, inspect the generated report first:

- Positive buckling load factors by subcase.
- Static preload status.
- Geometric-stiffness diagnostics.
- Solver timing and model counts.

The batch summary files provide a compact view of success/failure status and
runtime across all cases.

The Julia result's `results["buckling"].subcases` is the authoritative mapping
from each buckling subcase to its `STATSUB`, eigenpairs, K, Kg, and static
displacement. The legacy flat mode list is sorted across subcases; the legacy
K/Kg/static keys describe only the last preload. Structured `raw_*` fields
remain aligned value/vector pairs and currently share the reported storage.
Candidate-only values and filter decisions are available in each subcase's
`details["candidate_eigenvalues"]` and `details["candidate_filter_decisions"]`.

SOL105 exports retain this subcase ownership. Multiple buckling subcases write
separate `<base>_Subcase_<id>.jfem` files with a JSON file index, since each
binary file can store only one preload; a single subcase retains `<base>.jfem`.
JSON and HDF5 identify the static and buckling states explicitly and write
nodal displacement and modes in basic/global coordinates. Solver-internal
static displacement and stiffness matrices remain in the analysis/grid-CD
frame.

Static shell fields are recovered only when binary export requests them and
are cached by static subcase, with its temperature-dependent material context.
`results["static_shell_fields"]` starts as `nothing`; programmatic callers can
request a state's fields with `OpenJFEM._sol105_static_fields!(results, sid)`.
Shared-STATSUB cases reuse Kg by default. Set
`JFEM_SOL105_REUSE_PRELOAD_KG=false` for an independent assembly comparison;
custom builders and per-subcase element diagnostic CSV output bypass reuse.

Strict interval searches deflate rejected outside roots and retry with the
same `ND`. `JFEM_SOL105_BOUNDARY_RETRIES` limits these retries (default 8).
Check `details["boundary_targeting"]`, `details["output_request_status"]` and
`details["output_pairs_shortage"]` when an interval contains too few acceptable
pairs or the retry limit is reached. Failed full-spectrum dense extraction
raises an error instead of substituting an incomplete partial solve.

Case-control `MPC`, `K2GG` and `M2GG` selections apply to shared assembly.
Different selections across subcases currently require separate model runs.
Direct matrices support one named, real symmetric GRID matrix per selector;
unselected DMIG cards remain inactive. Varying PBEAML stations are rejected
by the bulk-data parser until their integration is supported.
MPC, rigid-element and SPC constraints reject missing GRID references,
invalid component digits and repeated dependent assignments. MPC coefficients
must be finite with a nonzero first coefficient. RBE3 UM dependent selection
requires `JFEM_RBE3_USE_UM_DEPENDENT=true` and a valid, complete dependent set;
otherwise it reports an error. JSON input retains SPCD prescriptions.

Concentrated follower forces are an explicit native-backend extension for
SOL101 and experimental SOL106. `PARAM,JFFOLLOW,1` activates only `FORCE`
entries whose optional field after `N3` is `ROT`; JSON FORCE records use
`"FLLW":"ROT"`. Other FORCE entries, MOMENT entries and pressure/body loads
remain fixed. In SOL101 the direction law is linearized at zero rotation,
`f=f0+theta cross f0`, and the solver retains the unsymmetric load stiffness
in `(Kstruct-Kload)*u=F0`. This is a first-order load linearization, not a
finite-rotation SOL101 formulation. In SOL106, force direction follows the
nodal rotation vector through Rodrigues' formula at every trial; the matching
load Jacobian is included without symmetrization. GRID frames and MPC/RBE3
transformations apply to both force and tangent. Structural support detection
does not use follower stiffness, and a singular follower equilibrium fails
without diagonal regularization. The TACS backend rejects this extension.

Follower loads disable conservative potential-energy line-search acceptance;
residual checks, cutbacks and accepted-state recovery remain active. Each
exported subcase's solver diagnostics includes `follower_loading`, identifying
the force law and actual BASIC force/rotation vectors at the exported state.
The existing structural geometric
formulation and linear constraint kinematics are unchanged, and no pressure
update or aerodynamic iteration is implied. A follower SOL101 baseline at a
different physical load must be solved again because its load stiffness changes;
uniformly scaling a full-load result is not equivalent. The activation is
OpenJFEM-specific and does not claim full external-solver FLLWER compatibility.

Thermal strain recovery is available for the supported isotropic linear
shell, line and solid elements. SOL106 rejects nonzero thermal expansion;
its nonlinear residual does not yet include thermal eigenstrain. TACS rejects
active temperature-dependent MAT1 reassembly to preserve its selected
formulation. Active PCOMP, anisotropic PSHELL and rigid-element thermal expansion
report unsupported-operation errors. Both `TEMP` and `TEMPERATURE` accept
the supported LOAD/BOTH/default selection; missing sets, conflicting selections,
and separate MATERIAL/INITIAL modifiers are diagnosed explicitly.

Planar rectangular anisotropic PCOMP cells in the compatible default MacNeal
SOL101/SOL105 route use projected elastic and initial-stress operators with
separate physical, elastic-work and geometric resultants. Shear reporting uses
the actual laminate transverse-shear law and ply reporting retains the material
orientation. The symmetric zero-coupling limit retains its K and Kg matrices.
This bounded formulation does not extend to skew, warped or mapped cells and
does not establish a complete nonlinear tangent. Research kernel, shear and
frame overrides retain their explicit eligibility restrictions.

Gravity includes the full CONM1 mass block, CONM2 offset moments, both CMASS
terminals in their GRID coordinate systems, and supported structural and
nonstructural mass. RFORCE defaults to METHOD=1 in BDF input. METHOD=2 applies
the full assembled mass matrix to the rigid rotational acceleration, including
RACC; it does not separately accelerate a CONM2 center-of-mass offset.
METHOD=1 CONM2 force and moment follow rigid-body balance at the mass center.
Older Nastran reference executables can differ in offset moments, so these
are checked independently against particle force/moment sums. METHOD=1 requires
lumped structural mass; scalar masses and translation/rotation-coupled CONM1
require METHOD=2. Superelement MB/IDRF selections are diagnosed as unsupported.
WTMASS scales dynamic mass matrices and does not rescale GRAV/RFORCE loads.
Negative or zero COUPMASS selects lumped shell mass; positive values select
coupled shell mass, subject to an explicit shell-mass environment override.

ACCEL1 supports SOL101/SOL105 static loading at selected GRID points, with
basic or rectangular acceleration CID and unit WTMASS. Its acceleration is
`A*N` without normalizing N; unlisted GRID accelerations are zero. The full
unreduced mass operator retains coupling and offset moments before ordinary
constraint mapping. THRU/BY lists and signed nested LOAD factors are supported;
mass assembly is reused only within that load-resolution call. Selected ACCEL
tables, curvilinear acceleration CID, nonunit WTMASS, external M2GG,
superelements and scalar-point masses report capability errors. Inactive or
zero-weight unsupported load branches do not block supported loading.
Acceleration-dependent optimization derivatives remain guarded. The legacy
Nastran reference executable used for validation rejects ACCEL1; support is checked against the
card specification, independent mechanics and equivalent FORCE cases.

Sensitivity results are scoped to each subcase. Material-E buckling
derivatives reuse the actual forward operators and equilibrium derivative.
Shell-thickness and Poisson-ratio derivatives use full forward differences
where the local adjoint does not represent the active geometric stiffness.
For eligible blank-MID3 Q4 shells in SOL105, thickness, Young's modulus and
Poisson-ratio derivatives use complete perturbed solves with mode tracking;
this includes the rigid-shear stiffness and preload and costs two solves per
design-variable group. For eligible SOL101 blank-MID3 Q4 shells,
`solve_adjoint` uses complete response differences for thickness, Young's
modulus and Poisson ratio. It shares two perturbed solves per variable group
across responses and subcases, plus one unperturbed replay that verifies the
supplied forward state and settings. Perturbations must preserve the DOF and
constraint partition. Direct local stiffness derivatives and optimizer routes
that use them reject this rigidity limit; this support is specific to
`solve_adjoint`. Existing mapped-shell, stress-location and load restrictions
still apply.
For supported SOL101 PCOMP displacement and KS-displacement responses,
`solve_adjoint` also uses complete response differences for individual ply
thickness, ply angle, and physical MAT1 ply E/NU variables. Angle gradients are
per degree. Laminate reconstruction retains blank/explicit Z0 and the selected
shear model. Perturbed solves are shared across responses and subcases, with
forward replay and partition checks. A perturbation crossing zero laminate
membrane/bending coupling is supported only in the verified continuous
rectangular projected domain. Skew cells and incompatible formulation settings
fail explicitly at this boundary because a centered difference can conceal a
finite stiffness jump. Context-free local laminate derivatives,
total-PCOMP-thickness variables, unsupported laminate options, PCOMP stress
gradients and PCOMP buckling sensitivities report errors instead of returning
derivatives of a different operator.
Other unsupported geometric-stiffness, thermal, load-dependent or changing
constraint-frame derivative paths report an error. Such cases need a complete
forward finite-difference study; changing solver tolerances is not a substitute.

## Troubleshooting

Package cannot be found:

```text
ERROR: ArgumentError: Package OpenJFEM not found
```

Run the command from the repository root with `--project=.`.

First run is slower than later runs:

Julia compiles methods on first use. Rebuild the local sysimage with a
representative deck, then use the batch runner for production so any remaining
compilation is paid once for the full set of cases.

No `.jfem` file is written:

The fast commands use `JFEM_EXPORT_BINARY=false`. Set it to `true` only for
runs that need browser visualization output.

Large batches use too much memory:

Keep the default batch behavior, which performs garbage collection between
cases. Avoid changing memory behavior unless you have measured the effect on
your model family.

## Source-Control Policy

The repository tracks source, configuration, documentation, runner scripts, and
the HTML post-processing viewer. Generated solver products are ignored:

- `output/`
- solver run products such as `.f04`, `.f06`, `.log`, `.op2`, `.pch`, and
  `.xdb`
- OpenJFEM reports and result exports such as `.REPORT.md`, `.JU.JSON`,
  `.jfem`, `.h5`, and `.vtk`
- Julia caches and local temporary files
