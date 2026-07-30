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
|   |-- macneal_harder/             five hand-coded classical shell/beam decks
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
| `macneal_harder/twisted_beam.bdf` | MacNeal & Harder (1985), Sec.\ 4 | Public domain | Analytical |
| `macneal_harder/scordelis_lo.bdf` | MacNeal & Harder (1985), Sec.\ 7 | Public domain | Analytical |
| `macneal_harder/pinched_cylinder.bdf` | MacNeal & Harder (1985), Sec.\ 8 | Public domain | Analytical |
| `macneal_harder/hemispherical_shell.bdf` | MacNeal & Harder (1985), Sec.\ 9 | Public domain | Analytical |
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
closed-form target) and, on 12 of the 14 rows, an optional `parity` block
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

## Current Paper Status

The maintained public-suite snapshot contains 14 scalar validation rows: 9
accuracy PASS / 5 FAIL, and 9 parity PASS / 3 parity FAIL across the 12 rows
that carry a parity target. Three of the five accuracy failures are in
0.02-2.3% parity and are dominated by the benchmark mesh and by a load
convention still under review; the remaining two are genuine formulation gaps.
`PAPER_VALIDATION_SUMMARY.md` itemises all of them.

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

Two of the fourteen rows deliberately have **no** tabulated parity value. A
reference-solver run of `timoshenko_plate_buckling` returns a first eigenvalue
56% away from both the analytical value and OpenJFEM's, which is unexplained
and may be a convention mismatch rather than a gap; and
`cylinder_axial_buckling` reports a critical stress where the reference-solver
run yields a raw eigenvalue, so the suite's own lambda-to-stress conversion has
to be applied before the two are comparable. Wiring in an unverified number
would assert a parity result that has not been established, so those rows stay
empty until each is resolved.

## What This Suite Is Not

- It is not the OpenJFEM regression test set. That lives elsewhere.
- It is not a complete coverage of OpenJFEM's feature surface. It is the
  minimum reproducible, citable set sufficient to support the publication.
- It does not include any deck whose redistribution is restricted (no
  proprietary aircraft data, no commercial-solver verification kits).
- It does not ship any solver-generated output that may carry a third
  party's branding or copyright.
