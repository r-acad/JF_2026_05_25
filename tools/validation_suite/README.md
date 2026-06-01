# OpenJFEM Public Validation Suite

A self-contained, public-domain reproducibility set for the paper validation
of OpenJFEM. Every case here uses geometry, loads, and references that are
in the open literature or in a permissively-licensed open-source repository.

This folder is the **only** location of validation-paper material. Cases used
internally for development are kept in the private workspace and are not
referenced from anything under this directory.

## Folder Layout

```text
tools/validation_suite/
|-- README.md                       this file
|-- public_suite.yaml               THE manifest of cases (single source of truth)
|-- run_public_suite.jl             top-level driver
|-- analytical/                     Julia functions for closed-form references
|-- cases/
|   |-- macneal_harder/             five hand-coded classical shell/beam decks
|   |-- classical/                  two closed-form plate/cylinder buckling decks
|   |-- mystran_xref/               cross-checks against the MYSTRAN test suite
|   `-- crm/                        Common Research Model wing-box
|-- helpers/                        small utilities (deck synthesisers, parsers)
|-- references/                     tabulated reference values
|-- comparison.csv                  GENERATED: row per (case, quantity)
`-- comparison.md                   GENERATED: paper-ready summary
```

## How To Run

From this folder:

```powershell
# Resolve every case in public_suite.yaml, run JFEM, parse references,
# emit comparison.csv and comparison.md.
julia --project=..\.. run_public_suite.jl

# Verbose mode (per-case timing and per-quantity diagnostics)
julia --project=..\.. run_public_suite.jl --verbose

# Run only a single family
julia --project=..\.. run_public_suite.jl --family macneal_harder
```

The driver intentionally does **not** invoke any external solver at run
time. Reference values are either:

- analytical Julia functions in `analytical/`, or
- tabulated CSVs under `references/`.

This separation keeps the run-time pipeline solver-free and the paper's
reference set auditable from source.

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

For the cross-check cases, the reference numbers were produced once on the
maintainer's machine using an established commercial finite-element solver
that accepts the classical BDF input format, and tabulated in
`references/commercial_reference.csv` with one row per (case, quantity).
The solver itself is not invoked by anything in this folder, and no
solver-generated output files are shipped here.

## What This Suite Is Not

- It is not the OpenJFEM regression test set. That lives elsewhere.
- It is not a complete coverage of OpenJFEM's feature surface. It is the
  minimum reproducible, citable set sufficient to support the publication.
- It does not include any deck whose redistribution is restricted (no
  proprietary aircraft data, no commercial-solver verification kits).
- It does not ship any solver-generated output that may carry a third
  party's branding or copyright.
