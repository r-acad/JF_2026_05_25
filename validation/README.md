# OpenJFEM Public Validation Suite

A self-contained, public-domain reproducibility set for the paper validation
of OpenJFEM. Every case here uses geometry, loads, and references that are
in the open literature or in a permissively-licensed open-source repository.

This folder is the **public validation set for the paper**. Cases used
internally for development are kept outside the public repository and are not
referenced from anything under this directory. In particular, the internal GAME,
HTP, and VTP aircraft-tail cases are not part of this public validation set.

## Folder Layout

```text
validation/
|-- README.md                       this file
|-- CASE_INVENTORY.csv              compact provenance and coverage table
|-- PAPER_VALIDATION_SUMMARY.md     paper-facing validation synopsis
|-- public_suite.yaml               THE manifest of cases (single source of truth)
|-- run_public_suite.jl             top-level driver
|-- analytical/                     Julia functions for closed-form references
|-- cases/
|   |-- macneal_harder/             six benchmark decks + two refined companions
|   |-- classical/                  two closed-form plate/cylinder buckling decks
|   |-- mystran_xref/               cross-checks against the MYSTRAN test suite
|   `-- crm/                        Common Research Model wing-box
`-- references/                     tabulated reference values
```

Full runs create `comparison.csv` and `comparison.md` locally in this folder.
Those generated reports are ignored by Git so the public validation tree stays
focused on auditable inputs and references.

## How To Run

From this folder:

```powershell
# Resolve every case in public_suite.yaml, run JFEM, parse references,
# emit comparison.csv and comparison.md.
julia --project=.. run_public_suite.jl

# Verbose mode (per-case timing and per-quantity diagnostics)
julia --project=.. run_public_suite.jl --verbose

# Run only a single family
julia --project=.. run_public_suite.jl --family macneal_harder

# Fast reference/provenance check without loading OpenJFEM or touching
# comparison.csv / comparison.md.
julia --project=.. run_public_suite.jl --dry-run --no-write
```

The driver intentionally does **not** invoke any external solver at run
time. Reference values are either:

- analytical Julia functions in `analytical/`, or
- tabulated CSVs under `references/`.

This separation keeps the run-time pipeline solver-free and the paper's
reference set auditable from source.

## SOL 103 Shell Mass

OpenJFEM's SOL 103 shell modal route uses coupled consistent PSHELL mass by
default for quadrilateral and triangular shells. This matches the CRM modal
reference family and gives physically meaningful modal participation factors
from the full mass operator. Decks can request Nastran-style lumped shell mass
with `PARAM,COUPMASS,NO`; `PARAM,COUPMASS,YES` requests coupled mass explicitly.
For diagnostics, `JFEM_SOL103_SHELL_MASS=consistent` or `lumped` can force the
route without editing a deck. Total-mass and modal-effective-mass diagnostics
are evaluated in the assembled analysis DOF frame using global rigid-translation
vectors, so rotated GRID `CD` frames do not change the reported physical mass.

## Per-Case Provenance

| Case | Source | License | Reference kind |
| --- | --- | --- | --- |
| `macneal_harder/curved_beam.bdf` | MacNeal & Harder (1985), Sec.\ 3 | Public domain (40+ yr journal) | Analytical |
| `macneal_harder/curved_beam_refined.bdf` | MacNeal & Harder (1985), Sec.\ 3, refined 24x4 mesh | Public domain | Analytical |
| `macneal_harder/pinched_cylinder_refined.bdf` | MacNeal & Harder (1985), Sec.\ 8, refined 24x24 mesh | Public domain | Analytical |
| `macneal_harder/twisted_beam.bdf` | MacNeal & Harder (1985), Sec.\ 4, in-plane load | Public domain | Analytical |
| `macneal_harder/twisted_beam_out_of_plane.bdf` | MacNeal & Harder (1985), Sec.\ 4, out-of-plane load | Public domain | Analytical |
| `macneal_harder/scordelis_lo.bdf` | MacNeal & Harder (1985), Sec.\ 7 | Public domain | Analytical |
| `macneal_harder/pinched_cylinder.bdf` | MacNeal & Harder (1985), Sec.\ 8 | Public domain | Analytical |
| `macneal_harder/hemispherical_shell.bdf` | MacNeal & Harder (1985), Sec.\ 9, 18-deg cut-out variant | Public domain | Analytical |
| `classical/timoshenko_plate_buckling.bdf` | Timoshenko \& Gere, *Theory of Elastic Stability* (1961), Ch.\ 9 | Public domain | Closed-form |
| `classical/cylinder_axial_buckling.bdf` | Brush \& Almroth, *Buckling of Bars, Plates and Shells* (1975), Ch.\ 5 | Public domain | Closed-form |
| `mystran_xref/sol101_simple.bdf` | MYSTRAN test suite (MIT) | MIT | Tabulated commercial reference |
| `mystran_xref/sol105_buckling.bdf` | MYSTRAN test suite (MIT) | MIT | Tabulated commercial reference |
| `crm/wingbox_modal_with_props.bdf` | TACS examples/crm (Apache 2.0), augmented in-folder | Apache 2.0 | Tabulated commercial reference |

## Publication Inclusion Rule

The public validation set may contain:

- CRM/uCRM decks from the TACS repository or similarly permissive public
  repositories.
- Classical published benchmark cases with analytical or clearly tabulated
  references.
- Synthetic decks generated solely from public formulas, public geometry, or
  code in this repository.
- Small cross-solver cases from open-source suites with compatible licenses.

The public validation set must not contain GAME, HTP, VTP, proprietary aircraft
models, commercial-solver verification kits, private run outputs, or decks whose
redistribution rights are unclear.

## Accuracy And Parity Are Scored Separately

Each quantity in `public_suite.yaml` carries a `reference` (published or
closed-form target) and, on 15 of the 17 rows, an optional `parity` block
holding a tabulated reference-solver value for **this folder's own deck,
unmodified**.

They measure different things. The accuracy columns (`reference`, `rel_err`,
`verdict`) include the discretisation error of a deliberately coarse benchmark
mesh. The parity columns (`parity_ref`, `parity_rel_err`, `parity_tol_rel`,
`parity_verdict`) do not: both sides run the identical mesh, so that error is
common and cancels, and what remains is a formulation difference.

The two are independent by construction — a parity result never changes the
accuracy verdict and vice versa — because conflating them hides defects in both
directions. A case can miss its textbook value by 6% while being in 0.02%
parity (coarse mesh, not a defect), and a case can sit inside its accuracy
tolerance while being hundreds of percent out of parity.

Parity tolerances are deliberately **tighter** than the accuracy tolerance on
the same row: there is no mesh-convergence allowance to spend.

An empty parity cell means *unmeasured*, not passing. A quantity with no
`parity` block behaves exactly as it did before the column existed.

## Benchmark Meshes vs Refined Companions

The MacNeal-Harder decks use the mesh densities the benchmark specifies. Those
meshes are deliberately coarse, and on the two hardest cases **no** published
4-node shell element reaches its converged target on them — the pinched
cylinder at 4x4 puts six published elements between 0.370 and 0.636 of the
reference, and the curved beam at 6x1 has MacNeal & Harder's own QUAD4 result at
0.833. Scoring those meshes against the converged target measures the mesh, not
the code.

Rather than widen the tolerance until the coarse row passes — which would be
fitting the gate to the answer — those two cases each ship a **refined
companion** alongside the untouched benchmark deck:

| benchmark deck | refined companion | mesh |
| --- | --- | --- |
| `curved_beam.bdf` | `curved_beam_refined.bdf` | 6x1 -> 24x4 |
| `pinched_cylinder.bdf` | `pinched_cylinder_refined.bdf` | 4x4 -> 24x24 |

Same problem, same material, same loads, same published reference, ordinary 2%
tolerance, no per-mesh allowance. The benchmark rows keep reporting the
benchmark result — including their honest FAIL against the converged target —
and the refined rows show the element converging onto it. Each refined deck
states its mesh construction rule in its header, so it is reproducible without
a generator.

## PARAM,K6ROT

Every shell deck in this folder declares `PARAM,K6ROT` explicitly. This is
deliberate and it matters.

K6ROT is the Hughes-Brezzi drilling-DOF stabilisation coefficient — a numerical
stabiliser, not part of any of these benchmark definitions. Solvers disagree on
its default:

| solver | default in SOL 101 |
| --- | ---: |
| MSC/Nastran 70.5 | `0.0` |
| MSC.Nastran 2004+ | `100.0` |
| OpenJFEM | `100.0` |

A deck that does not declare it therefore runs a *different problem* in each,
and neither the accuracy comparison nor the same-deck parity comparison means
what it claims. On the pinched hemisphere the difference alone is 3.5%.

The decks pin it at `0.0`: the setting under which both the published benchmark
values and this folder's tabulated reference-solver values were produced, and
the setting that leaves the element unstabilised so the accuracy rows measure
the element rather than the stabiliser. Declaring it is a numerical no-op for a
solver that already defaults to 0 — verified by re-running the reference solver
on the decks with and without the card and getting identical output.

`cases/classical/*` and `cases/crm/*` declare `PARAM,K6ROT,100.0`; those decks
were always explicit and their reference values were produced at that setting.

## Current Paper Status

The maintained public-suite snapshot contains 17 scalar validation rows: 15
accuracy PASS / 2 FAIL, and **15 parity PASS / 0 parity FAIL** across the 15
rows that carry a parity target. Every one of the ten cases now carries at
least one same-deck parity measurement. Worst same-deck parity error on any row is
`2.82e-4` (CRM mode 4) and `6.19e-5` across the MacNeal-Harder family, against
parity tolerances of `1e-3` (`5e-3` for the CRM modal rows).

The two remaining accuracy failures — the curved beam (16.7%) and the pinched
cylinder (47.6%) — are properties of the deliberately coarse standard benchmark
meshes, not solver defects: the reference solver misses the same targets by the
same amounts on the same decks, no published 4-node shell element comes near its
converged value at these meshes either, and OpenJFEM converges onto both targets
under refinement. `PAPER_VALIDATION_SUMMARY.md` itemises each row.

Run the suite to recreate `comparison.md` and `comparison.csv` with the exact
values, tolerances, and relative errors for the local solver revision.

## Building The Reference Set

Reference values come in two flavours.

### Analytical

Closed-form formulas live in `analytical/` as one Julia file per problem.
Each exposes a function returning the expected scalar quantity:

```julia
include("analytical/macneal_curved_beam.jl")
ref = macneal_curved_beam_tip_disp(:in_plane)   # -> 0.08734
```

These never need to be regenerated; they are the references in source form.

### Tabulated commercial-solver values

For the cross-check cases, and for the parity column, the reference numbers
were produced once on the maintainer's machine using an established commercial
finite-element solver that accepts the classical BDF input format, and
tabulated in `references/commercial_reference.csv` with one row per
(case, quantity). The solver itself is not invoked by anything in this folder,
and no solver-generated output files are shipped here.

Two of the seventeen rows deliberately have **no** tabulated parity value: the
two `classical` **buckling-eigenvalue** rows. This is a limitation of the
reference solver on those two decks, and it has been characterised rather than
left unexplained.

Note that both of those *cases* are still parity-covered — each carries a
second row measuring its SOL 105 `STATSUB` static preload field, which is
well-posed for both codes (see below). Every case in the suite therefore has at
least one same-deck parity measurement; what remains unverified against a
reference solver is the buckling **eigenvalue** on these two decks specifically.

The reference solver cannot produce a trustworthy *first* buckling eigenvalue
for either deck:

- On `timoshenko_plate_buckling` its unguarded inverse-power extraction reports
  a first eigenvalue 56% away from both the analytical value and OpenJFEM's —
  but its own Sturm-sequence messages count 14 roots below `3.003e8` while only
  6 of the printed roots are below that. Eight roots below the printed minimum
  were missed, so the printed "mode 1" is not the first eigenvalue of that
  discretisation and is not comparable to anything.
- On `cylinder_axial_buckling` it reports a first eigenvalue of `3.33e-5` with a
  **negative** generalized mass and a failed orthogonality test (66 pairs).

Re-running both with the Sturm-guarded extraction method does not rescue them:
it returns 100+ roots dominated by a near-null spurious cluster. The reference
solver's `K`/`K_g` pair on these decks carries a large spurious near-null
subspace; OpenJFEM's spectrum has 5 roots below `5e8` where the reference's own
Sturm count claims 17.

Wiring in a number from a demonstrably incomplete extraction would assert a
parity result that has not been established, so those two eigenvalue rows stay
empty.

**What is measured instead.** Each classical case carries a second row on its
SOL 105 `SUBCASE 1` `STATSUB` preload field, requested with `DISPLACEMENT = ALL`
and emitted by OpenJFEM under `static_displacements` in the `*.BUCKLING.JSON`.
That field is well-posed for both codes and agrees to `5.0e-8` (plate, node 36
T1) and `3.9e-6` (cylinder, node 1 T3, in the deck's `CORD2C` cylindrical output
frame).

Be precise about what this buys: the preload row verifies the **stiffness
matrix, the applied load and the boundary conditions** on the identical mesh.
It does **not** verify the geometric stiffness `K_g` or the eigensolver. Those
remain unverified against a reference solver on these two decks, and saying so
is the point of keeping the eigenvalue parity cells empty.

## What This Suite Is Not

- It is not the OpenJFEM regression test set. That lives elsewhere.
- It is not a complete coverage of OpenJFEM's feature surface. It is the
  minimum reproducible, citable set sufficient to support the publication.
- It does not include any deck whose redistribution is restricted (no
  proprietary aircraft data, no commercial-solver verification kits).
- It does not ship any solver-generated output that may carry a third
  party's branding or copyright.
