# Solver commands and automation

This reference covers solver flags, exports, batch manifests, Python integration
and result interpretation. Run its commands from the **repository root** after
following your [operating-system installation guide](../README.md).
The helper files in this directory share that root Project/Manifest and sysimage.

## Comparing eigenvalues and modes

Use the same model, constraints, physical matrices and extraction request on
both sides. SOL103 eigenvalues are squared angular frequencies in rad²/s²;
convert frequency in Hz with `lambda = (2*pi*f)^2`. SOL105 eigenvalues are
signed buckling load factors. Do not compare these different quantities.

`compare_eigenvalue_spectra(reference, candidate)` compares real root lists
without relying on their output order. It preserves signs, repeated-root
multiplicity and original indices. The default strict error threshold is
below 0.5% relative to each reference root. It reports a complete assignment
with numerical errors and a separate maximum matching within tolerance.
Equal counts with inaccurate values remain numerical gaps; missing roots,
extra roots and sign differences remain coverage gaps. No large finite root
is discarded. Nonfinite values prevent a pass.

For JSON arrays, or JSON objects containing an `eigenvalues` array:

```powershell
julia --project=. utils/julia_tools/compare_spectra.jl reference.json candidate.json comparison.json
```

The command writes a new report and exits 0 for agreement, 1 for disagreement.
It refuses to overwrite an existing report. Optional `--lower=value` and
`--upper=value` apply the same inclusive interval to both lists, in eigenvalue
units, with a ledger of every exclusion. They do not change the extraction
request. `--absolute-tolerance=value` and `--zero-tolerance=value` default to
zero; set them only when the units and independent rigid-mode evidence justify
them. Zero tolerance changes the near-zero sign classification, not the roots.
`--relative-tolerance=value` defaults to 0.005.

For a complete repeated or clustered spectral group, compare the columns of
its mode matrices with `compare_eigenspaces(U, V)`. This checks rank and
principal angles, so signs, normalization, ordering and basis rotations inside
the same space do not create mismatches. Both matrices must use identical
physical DOF order. A positive definite `metric` can supply the energy inner
product; a singular full-space mass matrix must first be represented in
separately validated finite-mode coordinates. If ND cuts through a repeated
cluster, extract the whole cluster before concluding that different partial
bases indicate an error. Unrestricted individual-mode MAC must not reassign
roots from different spectral groups.

`eigenpair_diagnostics(A, B, values, vectors)` checks the original pencil
`A*u = lambda*B*u`, independently of the shifted or inverted extraction.
It reports action-relative and matrix-backward residuals with overflow-safe
scaling, including rotated rigid modes. Residual acceptance does not prove
eigenvalue accuracy for an ill-conditioned pencil. Root-list agreement,
eigenspace agreement and interval completeness are separate claims: a small
residual or the requested number of roots alone is not a completeness proof.

Modal EIGRL input preserves whether each field was actually specified.
Specify a positive ND for normal modal runs. A blank ND without V2 requests
the lowest root. A blank ND with V2 requests every root in that interval;
the current modal API rejects that unsupported request with a clear message,
instead of silently using the parser's stored placeholder. An explicit METHOD
must resolve to a supported EIGRL entry. Programmatic calls without METHOD
retain their documented convenience mode-count default.
SOL103 currently publishes real-frequency modes; negative finite roots are
reported in diagnostics rather than as a complete signed modal spectrum.
Use a positive frequency upper bound or leave V2 blank for an unbounded
request; the current numeric modal API interprets nonpositive V2 as unbounded.
These output/request limitations must remain separate from spectrum matching.

## Shared image workloads

Normal setup includes representative static, modal, buckling, nonlinear,
generation and sensitivity workloads. Sensitivity warmup includes imported
material properties and generated skin, T-stringer and material dimensions.
To add your own representative cases,
run one of these from the repository root:

```powershell
& ".\setup.cmd" --deck 'C:\models\representative.bdf'
& ".\setup.cmd" --manifest 'C:\models\cases.json'
```

On Linux/macOS, use `bash "setup.sh"` or
`bash "setup.command"` with the same options. `--deck` is repeatable;
`--flags` accepts workload `NAME=value` options. Setup verifies the resulting
shared image before launchers use it. Workloads prepare compilation; they are
separate from your analysis runs. New specializations may still compile.

`--no-precompile` and `--no-verify` do not suppress image construction;
download-only preparation also needs `--no-sysimage`. The OS guides explain
normal installation, repair and offline preparation.

## Fast Settings

The commands below assume normal setup has completed. They
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
  optional diagnostic. Blank `ND` retains its distinct Reference all-roots semantics for
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

With `AUTOSPC` enabled, singularity decisions use each grid's remaining
translational and rotational stiffness blocks after explicit constraints.
`EPZERO` compares local principal stiffnesses; a very stiff region or an
amplified RBE3 dependent-coordinate transformation does not clamp unrelated
flexible grids through a model-wide diagonal cutoff. The preliminary diagonal
pass handles exact zeros and retains the existing optional negative-diagonal
rule. `JFEM_AUTOSPC_GPST_REL` overrides deck `PARAM,EPZERO`, which otherwise
defaults to `JFEM_AUTOSPC_TRANS_REL` (normally `1e-8`). If directional processing
is explicitly disabled, `JFEM_AUTOSPC_TRANS_REL` and `JFEM_AUTOSPC_ROT_REL`
control a per-grid diagonal fallback. Diagnostics distinguish zero, negative,
local diagonal, and principal-stiffness constraints.

If the static system still requires singular-LU regularization, the default
perturbation is relative to each coordinate's own absolute stiffness diagonal.
It has no absolute stiffness floor and does not scale flexible regions from
an unrelated large MPC coefficient. Exact zero diagonals remain zero; the
boundary-condition partition handles inactive or constrained coordinates.
The solver continues to report the perturbation and the residual of the
original equations: successful regularization does not establish equilibrium
or reference-solver agreement. Explicit
`JFEM_SOL101_SINGULAR_LU_REGULARIZATION_MODE=global` retains the former mode;
explicit absolute or relative shift overrides retain their existing behavior
(the explicit relative override uses the global stiffness reference).

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
- **Repeated buckling roots**: strict partial-mode requests on eligible
  symmetric pencils with at most 600 free degrees of freedom use a selected
  symmetric eigensolver. It retains repeated eigenvalues by index, requests
  only the specified number of eigenvectors, and checks the original-pencil
  residuals. `JFEM_SOL105_PARTIAL_SYMMETRIC_MAX_DOF` changes this work bound;
  `0` disables the automatic path. A positive-definite shifted or elastic
  metric is required. Larger or genuinely indefinite pencils retain their
  iterative path; a requested mode count alone does not certify that every
  repeated direction among the lowest roots was found.
- **Laminate initial stress**: planar ordinary MacNeal quadrilateral laminates in
  SOL105 use compatible nodal normal strains, center membrane shear and full
  compatible curvature for the initial-stress field. Elastic output retains
  the enhanced elastic recovery. Set `JFEM_Q4_DIFFERENTIAL_PRESTRESS=false`
  only to compare with the previous elastic-recovery interpolation. Warped,
  director, alternate-plate and nonlinear paths retain their separate formulations.
  `JFEM_Q4_DIFFERENTIAL_PRESTRESS_WARPED=true` explicitly enables a diagnostic
  projected extension; it does not establish the complete warped-shell
  initial-stress tangent, including initial moments and eccentricity terms.
- **Modal mass rank**: small modal pencils detect massless combinations after
  diagonal scaling, including combinations hidden by offsets. The default
  `JFEM_SOL103_MASS_RANK_MAX_DOF=600` bounds this classification work; `0`
  disables it. Diagnostics report rank, nullity and numerical tolerance.
  Finite-mode requests are capped by this rank. Rank completeness additionally
  requires the positive-stiffness certificate; larger or indefinite pencils
  retain their existing extraction policy.
  For a bounded PSD mass pencil with a positive shifted Cholesky factor and
  zero negative stiffness inertia, modal mass is checked against the roundoff
  bound of its own quadratic form. This avoids a cutoff that depends on the
  units of the coordinates. Diagnostics identify whether this check is active.
  Eigenvector residual tests are unchanged; indefinite, higher-index and
  unclassified pencils retain the existing mass-acceptance policy.
- **Research opt-ins** (OFF by default):
  `JFEM_SOL105_SHIFT_FACTOR_FUSION=true` fuses shifted-solve
  factorizations with Sturm certificates;
  `JFEM_SOL105_SYMM_LANCZOS=true` runs the zero-shift buckling
  eigensolve as symmetric Lanczos via a Cholesky congruence; and
  `JFEM_SOL105_BLOCK_LANCZOS=true` uses deterministic block starts (default
  block size 2) to improve repeated-eigenspace coverage. Its block width must
  span the relevant multiplicity; it does not certify completeness. The block option may
  construct more Ritz pairs than `ND` and was slower on the audited large
  case, so it is intentionally outside the default exact-count profile.

## Quickest Way To Run A Deck

The command-line launchers live under `APPS/JFEM-solver/`, grouped by operating
system. They select Julia, the shared project and the verified local image.
The solution sequence is detected from the input deck.

Examples from the repository root:

```powershell
.\APPS\JFEM-solver\Windows\jfem.cmd C:\models\my_model.bdf
.\APPS\JFEM-solver\Windows\jfem.cmd C:\models\supported_modes.inp.gz C:\results\modes
```

```bash
bash APPS/JFEM-solver/Linux/jfem ~/models/my_model.bdf
bash APPS/JFEM-solver/Mac/jfem ~/models/my_model.bdf
```

An optional second argument selects the output folder. The default writes the
viewer-ready `.jfem`, `REPORT.md` and results JSON beside the input in
`<deckname>_out/`. Use the app's `JFEM-solver.cmd`, `.sh` or `.command` launcher
for a file chooser instead; the shortcuts under `__Start here!__` point there.

### Run an Abaqus input

The same CLI detects supported `.inp` and `.inp.gz` files. A complete supported
`*STATIC` step selects SOL101; an unprestressed `*FREQUENCY` step selects SOL103.
Unsupported mechanics or missing model definitions produce an explicit error.
For a mesh-only solid input, use Boxer's explicit setup or provide the required
materials, sections and analysis data first. See the
[Boxer Abaqus workflow](../../APPS/JFEM-Boxer/README.md#read-an-abaqus-input).
Input values retain their original units.

For programmatic inspection:

```julia
using OpenJFEM
source = OpenJFEM.abaqus_read_input("mesh.inp.gz"; strict=false)
source["inventory"]
model = OpenJFEM.abaqus_to_model(source; require_analysis=false)
model["abaqus_import"]["analysis_ready"]
```

`strict=false` retains recognized unsupported features as diagnostics;
malformed geometry still fails. `require_analysis=false` permits inspection
but does not make an incomplete model runnable.

### Invoke the CLI from another directory

Use the full launcher path, add `APPS/JFEM-solver/Windows` (Windows) or
`APPS/JFEM-solver/Linux` / `Mac` to PATH, or symlink the Unix launcher:

```bash
ln -s "/path/to/JFEM/APPS/JFEM-solver/Linux/jfem" ~/.local/bin/jfem
```

Use `Mac` instead of `Linux` for a macOS checkout. Unix launchers follow
symlinks to find the shared repository. A Git clone preserves executable bits;
a ZIP extraction may require `chmod +x` on the selected launcher. After adding
the OS folder to PATH, `jfem model.bdf` works from any current directory.
Images remain platform-specific and must be built on the destination machine.

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
| `b` | SOL105 compact eigenvalue and peak-node property JSON; omits full field exports |
| `e` | SOL105 ESE: element strain energy and density in results JSON |
| `d` | Alias of `e`; standard ESE supplies both quantities |

For example, `jfem -b model.bdf output` exports the buckling roots and the
GRID/property IDs at maximum translational magnitude, without exporting mode
vectors or preload fields. `jfem -sed model.bdf output` adds both element energy
fields to full SOL105 JSON. These three letters require SOL105; `b` takes
precedence over energy, binary, VTK and HDF5 output. It still computes
eigenvectors internally to locate each peak. Tied maxima retain all directly
incident PIDs, and propertyless nodes are identified explicitly.

Use the standard **Case Control** output request for energy, before `BEGIN BULK`:

```text
ESE(PLOT) = ALL
```

`ESE` requests both element strain energy and strain-energy density. Put it
before the first `SUBCASE` to cover every static preload and buckling subcase.
Put `ESE = NONE` in a subcase to suppress its output. A numeric selector refers
to a Case Control element `SET`, for example:

```text
SET 80 = 101 THRU 110, 205
ESE(PLOT) = 80
SUBCASE 1
  LOAD = 1
SUBCASE 2
  STATSUB = 1
  METHOD = 1
  ESE = NONE
```

This exports the selected preload element energies but no modal energies.
Comma continuations, `THRU`, `BY` and `EXCEPT` are supported in element SETs.
The request's `PRINT`, `PLOT`, `PUNCH` and `SORT1` qualifiers are accepted;
JFEM writes these values to `.BUCKLING.JSON`, not to a separate punch or
binary file selected by those qualifiers. Other qualifiers produce an explicit
unsupported-request error. Omitting ESE leaves energy recovery off. The CLI
`e`/`d` shortcuts override all subcases with `ESE(PLOT) = ALL`.

The JFEM-Boxer SOL105 form has one **Export element strain energy and density
(ESE)** checkbox and saves it with the Study. Earlier separate energy/density
selections are combined when reopening a Study. Compact output still uses
`PARAM,JFBKCOMP,1` in Bulk Data (0 or omitted means normal output).
`JFBKCOMP` means JFEM buckling compact output: a JFEM-specific export request,
not a stiffness or accuracy parameter. It is useful for small reports and
repeated studies needing only roots and peak-node properties. Omit it or set
it to 0 to retain normal graphical results; the solved eigenproblem is unchanged.

Deformation energy uses `0.5 * u_e' * K_e * u_e` from the actual assembled
elastic element matrix, including its numerical stabilization; density divides
this by the physical element volume. JSON separates the static preload from
each buckling mode and records normalization, units and coverage. Static energy
is physical for the applied load. Mode energy scales with arbitrary eigenvector
amplitude squared, so it is not a critical-load energy or a directly comparable
measure across differently normalized modes. Springs have no density without a
defined volume. Rigid constraints, penalties and direct matrices are excluded;
unsupported energies are marked unavailable. Thermal preload stored energy
(which needs initial-strain subtraction) and non-native stiffness backends are
not available through this output adapter. Energy units are force * length,
and density units are force / length^2; these are J and J/m^3 only for N-m input.

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
strain rows include principal membrane strains and principal Reference-sign
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
bash APPS/JFEM-solver/Linux/jfem  -rs     model.bdf            # only the report and results JSON
bash APPS/JFEM-solver/Linux/jfem  -jrsvh  model.bdf  out       # viewer + report + JSON + VTK + HDF5
```

A `run_manifest.json` recording the exact inputs and flags is always written.
The wrappers use `JFEM_JULIA` when set, otherwise `julia` on `PATH` (the
checkout records Julia 1.13.1) and automatically load a prebuilt sysimage from `sysimage/` when its
build receipt matches. (See "How to invoke it" above to call `jfem` from any
directory.)

### Rebuild The Local Sysimage

Normal setup builds the shared image automatically. After changing Julia, source,
dependencies or recorded workloads, rerun the setup launcher in your
`__Start here!__` operating-system folder. Standard launchers validate the receipt and
fall back to source loading when it is absent or stale. See the
[installation guides](../README.md) for repair and offline preparation.

The sections below show the fully explicit `julia ... run_bdf.jl` form, which
the wrapper runs for you and which you may still prefer for scripting or batch
automation.

## Public Validation Suite

The illustrated validation cases live in `validation/`. Run the default public suite
from the repository root with:

Windows PowerShell:

```powershell
.\validation\run_public_validation.ps1
```

Linux/macOS Bash:

```bash
julia --startup-file=no --project=. validation/run_public_suite.jl --output-dir validation/local_runs/my_check
```

The output directory retains native results, numerical fields, run receipts
and comparison tables. The default check selects 24 analyses and 44 quantities
from 18 documented case folders. The recorded results contain 34 accuracy
passes, two declared coarse-mesh accuracy failures and eight historical
regression passes, with 17 additional historical checks reported separately.
See [the validation guide](../../validation/README.md) for the complete mesh
studies, PDF cards, figures, reference sources and scientific limits.

The package release gate runs the curated suite without rewriting its reports:

```julia
using Pkg
include("utils/test/runtests.jl")
```

Run this from Julia started with `--project=.` at the repository root. The test
target declares its YAML dependency and fails on execution errors, skipped
results, regression failures, or new analytical failure cases. The two
existing analytical limitations remain visible in the test output.

## Run One SOL 105 Case

Use this command for a single buckling deck:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. '.\utils\julia_tools\run_bdf.jl' C:\models\panel_001.bdf output\panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. './utils/julia_tools/run_bdf.jl' /home/user/models/panel_001.bdf output/panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Read the command from left to right:

- `julia`: starts Julia.
- `--threads=auto`: lets Julia use available CPU threads.
- `--startup-file=no`: ignores any local Julia startup script.
- `--project=.`: selects the OpenJFEM Julia environment in the current
  repository root.
- `.\utils\julia_tools\run_bdf.jl` or
  `./utils/julia_tools/run_bdf.jl`: runs one input deck.
- `C:\models\panel_001.bdf` or `/home/user/models/panel_001.bdf`: this is the
  input file to solve. Replace it with your SOL 105 deck.
- `output\panel_001` or `output/panel_001`: this is the output folder
  created by OpenJFEM for this run.
- the quoted `JFEM_...` string: speed-oriented run flags. Keep the quotes.

The output folder is the second path after the input deck. To write results to
a custom folder, change that argument:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. '.\utils\julia_tools\run_bdf.jl' C:\models\panel_001.bdf D:\jfem_runs\panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. './utils/julia_tools/run_bdf.jl' /home/user/models/panel_001.bdf /home/user/jfem_runs/panel_001 "JFEM_EXPORT_BINARY=false,JFEM_MATRIX_ASYMMETRY_CHECK=false,JFEM_SOL105_STORE_PUBLIC_MODE_SHAPES=false,JFEM_SUPPRESS_THREAD_HINT=1"
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

Native runs also write `<stem>.TIMINGS.JSON` and stream structured progress and
completed timing records. Detailed stages identify input parsing, model building,
numerical assembly/solution/recovery and output work. Each stage records calls,
inclusive wall time and exclusive execution/compilation time. A child stage is
already included in its parent's inclusive time; category totals use exclusive
execution to avoid counting it twice. Recompilation is part of compilation, and
GC is part of wall time. These are elapsed-time measurements, not CPU usage.

Measured Julia compilation is excluded from reported numerical execution.
Package loading/precompilation before the measured pipeline belongs to startup
overhead, and is not presented as an exact precompile-only duration. Julia's
counters do not reliably identify live compilation inside a running numerical
stage: the web app colors numerical phases blue and labels that uncertainty.
Explicit preparation, compilation and file operations are orange. Completed
Log rows show the measured split. Missing or overlapping measurements remain
unavailable instead of substituting total elapsed time for solution time.

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
python '.\utils\python_client\jfem_manifest_cli.py' make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --batch-id batch_001
```

Linux/macOS Bash:

```bash
python './utils/python_client/jfem_manifest_cli.py' make --input-dir /home/user/models --manifest /home/user/models/cases.json --output-root /home/user/jfem_runs/batch_001 --batch-id batch_001
```

Create a manifest from specific decks:

Windows PowerShell:

```powershell
python '.\utils\python_client\jfem_manifest_cli.py' make --input C:\models\panel_001.bdf --input C:\models\panel_002.bdf --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --batch-id batch_001
```

Linux/macOS Bash:

```bash
python './utils/python_client/jfem_manifest_cli.py' make --input /home/user/models/panel_001.bdf --input /home/user/models/panel_002.bdf --manifest /home/user/models/cases.json --output-root /home/user/jfem_runs/batch_001 --batch-id batch_001
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
julia --threads=auto --startup-file=no --project=. '.\utils\julia_tools\run_batch_manifest.jl' C:\models\cases.json --quiet
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. './utils/julia_tools/run_batch_manifest.jl' /home/user/models/cases.json --quiet
```

Run the included manifest example:

Windows PowerShell:

```powershell
julia --threads=auto --startup-file=no --project=. '.\utils\julia_tools\run_batch_manifest.jl' '.\utils\examples\manifests\sol105_batch_manifest.json' --quiet
```

Linux/macOS Bash:

```bash
julia --threads=auto --startup-file=no --project=. './utils/julia_tools/run_batch_manifest.jl' './utils/examples/manifests/sol105_batch_manifest.json' --quiet
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

For repeated PSHELL thickness updates to a fixed wing-box topology, use the
[warm-model sizing example](../python_client/README.md). It generates the model
with Boxer, parses it once in Julia, exchanges compact property updates/results
and keeps one solver process alive until the buckling target is reached.
The manifest workflow below remains useful for independent decks.

For heavy optimization, Python should not launch Julia for every case or every
iteration. Run Python from the repository root, or put the repository root on
`PYTHONPATH`, then start one OpenJFEM JSONL worker, keep it warm, and send
batch manifests repeatedly.

Python example:

```python
from pathlib import Path
from utils.python_client.jfem_client import (
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
python '.\utils\python_client\jfem_manifest_cli.py' run-worker C:\models\cases.json --repo-root .
```

Linux/macOS Bash:

```bash
python './utils/python_client/jfem_manifest_cli.py' run-worker /home/user/models/cases.json --repo-root .
```

For heavy optimization, prefer the `JFEMWorker` example above so the same Julia
worker remains open across many design iterations.

To create an eigenvalues-only manifest from the command line:

```powershell
python '.\utils\python_client\jfem_manifest_cli.py' make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --eigenvalues-only --no-report
```

To request eigenvectors instead:

```powershell
python '.\utils\python_client\jfem_manifest_cli.py' make --input-dir C:\models --manifest C:\models\cases.json --output-root D:\jfem_runs\batch_001 --export-eigenvectors --no-report
```

## Post-Processing

The fastest commands above skip `.jfem` export. When you need interactive
visual inspection, enable binary export for that run and launch
the Results-viewer entry in `APPS/JFEM_results_viewer/Windows`, `Linux` or `Mac`. The launcher starts a small local browser-asset server so
the viewer can use WebGPU; it does not load or run the FE solver. Keep its
console open while using the viewer, then press Ctrl+C to stop it.

Without Julia, you can open `APPS/JFEM_results_viewer/postv11.html` directly as a
WebGL fallback. Both options use bundled libraries and work offline.

The viewer loads `.jfem` result files directly in the browser. Boxer also opens
them through **Project / Open JFEM results**. The shared binary reader accepts
versions 1-7. Boxer renders solid exterior faces and inspects the original
volume elements.
Version 6 stores the actual tetrahedron node count, preserving all ten nodes of
a quadratic tetrahedron; version 7 also retains an available buckling static
preload. Older files remain readable. Archive field availability depends on the
original export request. See `APPS/JFEM_results_viewer/POST_GUIDE.html` for controls.

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
Beam sections with a nonzero product of inertia use the complete coupled
bending/shear flexibility, including unequal transverse shear areas. Shear
softening applies to the coupled terms as well as the two bending directions;
uncoupled sections retain the ordinary Timoshenko formulas. This avoids
artificial negative element stiffness in short unsymmetric sections.
MPC, rigid-element and SPC constraints reject missing GRID references,
invalid component digits and repeated dependent assignments. MPC coefficients
must be finite with a nonzero first coefficient. RBE3 UM continuations are
honored automatically: they redefine the dependent components, while cards
without UM retain their REFGRID/REFC dependent set. UM must specify a complete,
non-repeated dependent set with a nonsingular coefficient block. Invalid sets
report an error instead of silently dropping constraint equations. The former
`JFEM_RBE3_USE_UM_DEPENDENT` switch is no longer needed and does not override the
input card, even when set to `false`. JSON input retains SPCD prescriptions.
Mutually coupled MPC/rigid-element dependencies are eliminated as complete
equation blocks when their selected dependent block is nonsingular. Singular
cycles report an error; the solver does not drop equations or silently change
the dependent set. The log reports the number and size of resolved blocks.
When constraint redistribution would exceed 100 million temporary matrix
entries, JFEM first assembles the sparse operator and then applies the same
constraint congruence. This avoids expanding duplicate element contributions
and exact zeros into large temporary arrays. Smaller models retain the
original accumulation path. Solver phase messages are flushed immediately
to redirected logs.

Explicit shell normals use `SNORM,GID,CID,N1,N2,N3`. The vector is normalized
and its coordinate system defaults to BASIC; cylindrical and spherical
components use the coordinate basis at the referenced GRID. Explicit normals
override generated normals for the supported CQUAD4/CQUADR/CTRIA3/CTRIAR cards.
`PARAM,SNORM,0` disables generation while retaining explicit normals; a negative
value disables both. A positive value enables generation followed by explicit
overrides. The effective normals are shared by stiffness, mass, prestress and
recovery, without changing the GRID displacement coordinate system.

On supported SOL101/105 normal-moment paths, coupled laminate recovery uses
the complete A/B/D section law. The geometric-stiffness preload uses its
compatible differential membrane field and applies the physical normal map
once before evaluating coupled curvature. Reference offsets and the outer
perturbation-work transformation remain separate; elastic enrichment is not
substituted into this differential field.

Ordinary constant-thickness SOL101/105 normal-moment shells recover physical
area-mean transverse shear from the same four-channel section-energy law as
their elastic stiffness. The physical normal map is applied once; other section
forces, stresses, strains and ply fields keep their recovery laws. This mean is
not an element-centre extrapolation convention. Director, variable-thickness,
research and alternative-backend routes retain their separate contracts.

Supported projected offset shells evaluate geometric work on the GRID reference
surface with the consistent shifted section law. Their verified material and
thickness sensitivities retain the existing exclusions for other kinematics.
Generated normal axes at sharp folds preserve prescribed normals and separate
director paths. Geometry derivatives reject discrete normal or prestress branch
crossings. The cylindrical-curvature classifier uses dimensionless numerical
rank, so a change of length units cannot turn the same saddle into a cylinder.

The native solver retains unsupported FORCE1/FORCE2/MOMENT1/MOMENT2 records
and rejects an active nonzero selected load before assembly. These geometric
follower definitions are not replaced by fixed-direction loads. Unselected
records, zero card magnitudes and cancelled LOAD coefficients remain harmless.

Concentrated follower forces are an explicit native-backend extension for
SOL101 and experimental SOL106. `PARAM,JFFOLLOW,1` activates only `FORCE`
entries whose optional field after `N3` is `ROT`; JSON FORCE records use
`"FLLW":"ROT"`. Other FORCE entries and body loads remain fixed. MOMENT
directions remain fixed; the corotational shell route transforms their physical
moments into the work coordinates of the rotation unknowns. Normal shell
pressures have the separate SOL106 behavior described below. In SOL101 the
direction law is linearized at zero rotation,
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
This concentrated-force option does not change linear constraint kinematics
or perform aerodynamic iteration. A follower SOL101 baseline at a
different physical load must be solved again because its load stiffness changes;
uniformly scaling a full-load result is not equivalent. The activation is
OpenJFEM-specific and does not claim full external-solver FLLWER compatibility.

### SOL106 increment and convergence controls

With `PARAM,LGDISP,1` and `PARAM,NLMETHOD,AUTO` (or an omitted NLMETHOD),
eligible quadrilateral-shell models use an objective corotational formulation.
It removes the element's rigid translation and polar rotation, evaluates the
existing isotropic or laminate section on its remaining distortions, and
transforms physical forces and moments using consistent virtual work. Its
Newton tangent is generally nonsymmetric. The line search uses a fixed linear
compliance norm of the equilibrium residual; it does not assume the resulting
force law is the gradient of the reported section energy.

Supported planar isotropic membranes explicitly constrained to in-plane
translations retain their established Green–Lagrange finite-strain energy.
This selection uses the active SPC/SPCADD and permanent GRID constraints in
their coordinate bases; numerical AUTOSPC decisions do not define a membrane.
Free bending or normal motion retains the corotational route. Explicit
`PARAM,NLMETHOD,COROT` still selects engineering-strain corotational work;
explicit `FORMAL` retains the finite-strain energy method.

The verified automatic scope is CQUAD4-only stiffness with uniform corner
thickness, no element reference offsets, no smoothed or prescribed shell normals, no active
MPC/RBE mapping, no added direct stiffness matrix and no selected nonzero
RFORCE centrifugal loading. Rotation vectors must
remain within the supported principal-rotation domain. Other AUTO models keep
their previous formal-energy, linear or approximate geometric route. In the
formal route, planar isotropic PSHELL models use Green-Lagrange membrane
stretching with linear reference bending/shear energy; CBAR members remain
elastic. Diagnostics identify the selected method and the reason a model is
outside corotational scope. `PARAM,NLMETHOD,COROT` explicitly requests the new
formulation and rejects an unsupported model instead of falling back.

With LGDISP enabled, uniform normal `PLOAD`, `PLOAD2` and `PLOAD4` pressures on
supported three- and four-node shell faces follow the current face and its
current area, with consistent nodal integration and load tangent. This does
not require `JFFOLLOW`. PLOAD4 entries with a prescribed
nonzero direction remain fixed; CID alone or a zero direction still denotes
normal pressure. Selected `SORL=LINE` edge loads on CQUADR/CTRIAR are unsupported
and raise an error. SORL is ignored on other shell cards according to their
card semantics.

With AUTO, omitted or disabled LGDISP keeps geometric nonlinearity off;
CBAR-only systems also remain elastic when LGDISP is enabled. Their selected
load increments and convergence checks still run, with a constant elastic
tangent. This does not add material nonlinearity.

`PARAM,NLMETHOD,LEGACY` explicitly retains the approximate geometric-force
residual for comparison. An explicit `NLRESMODEL` also retains that legacy
residual. The explicit `NLMETHOD,FORMAL` experimental option remains available;
its canonical diagnostic name is `formal_shell_green_lagrange`. Historical
`FORMAL_SHELL_VON_KARMAN` aliases also select this corrected energy.
Its wider experimental scope does not widen the automatic or analytic-adjoint
scope. Fixed MPC/RBE dependencies use the same virtual-work transformation
for nonlinear forces and tangents as for elastic stiffness.

Corotational recovery uses each element's net distortions. Displacement
reporting uses gimbal angles for `PARAM,LANGLE,1` (the default), or rotation
vectors for `PARAM,LANGLE,2`. The internal GRID-coordinate rotation vectors are
recorded separately. Gimbal reporting at its angular singularity requires
rotation-vector output; Euler-angle triples cannot be transformed between
coordinate systems by ordinary vector rotation.

Use the standard `NLPARM` Bulk Data card and select its ID in Case Control.
A global selection is inherited by each subcase; a subcase selection overrides
it. For example, this requests six nominal load increments, at most 35 Newton
iterations per increment, all three convergence checks at `1e-7`, intermediate
results, and at most eight load bisections:

```text
SOL 106
CEND
NLPARM = 11
SUBCASE 1
  SPC = 1
  LOAD = 1
BEGIN BULK
PARAM,LGDISP,1
NLPARM,11,6,,,1,35,UPW,YES
+,1.e-7,1.e-7,1.e-7,,,,,
+,8
```

The first data line is `SID,NINC,DT,KMETHOD,KSTEP,MAXITER,CONV,INTOUT`.
The second starts with `EPSU,EPSP,EPSW`; `MAXBIS` is the first field of
the third line. `CONV` selects `U` (displacement correction), `P` (force
residual), `W` (incremental work), or a combination such as `UPW`. Every
selected check must pass. JFEM uses the norm of the correction divided by the
norm of the current displacement for U, the norm of the free residual divided
by the norm of the free applied force for P, and
`abs(correction' * preceding_residual) / abs(displacement' * applied_force)`
for W. Each denominator has a `1e-30` zero guard. The requested tolerances and
each iteration's pass/fail checks appear in `nonlinear_diagnostics`.

`NINC` sets equal nominal load increments; failed increments can be bisected
up to `MAXBIS`. Automatic step growth is disabled when an NLPARM is selected.
`MAXLS` sets the residual line-search backtracking limit. `INTOUT=YES` or
`ALL` retains each accepted increment's displacements, reactions, forces,
stresses and strains in `nonlinear_intermediate_results`; `NO` keeps the final
fields and diagnostic history.

The supported iteration method is JFEM's updated-tangent Newton method.
`KMETHOD=AUTO` or `ITER` selects this method; use `KSTEP=1` if explicit.
Reference-specific automatic tangent-update and quasi-Newton heuristics are
not reproduced. An explicit nonzero `MAXQN`, another `KMETHOD`, a nonzero
`DT`, or explicit `MAXDIV`, `FSTRESS`, `LSTOL`, `MAXR` or `RTOLB` produces a
clear unsupported-control error. Defining an unselected NLPARM does not affect
other cases or solutions. Without an NLPARM selection, the existing `NL...`
PARAM controls and `P AND (U OR W)` convergence policy remain in effect.

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
Older Reference reference executables can differ in offset moments, so these
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
Reference reference executable used for validation rejects ACCEL1; support is checked against the
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
