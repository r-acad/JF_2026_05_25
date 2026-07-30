# OpenJFEM Paper Validation Summary

This folder is the public validation evidence intended to accompany the
OpenJFEM paper. It contains only redistributable cases: published benchmarks,
synthetic decks derived from published formulas, and permissively licensed
open-source cross-checks.

Private GAME, HTP, and VTP cases are not included and are not referenced by the
public validation manifest.

## Included Families

| Family | SOL | Cases | Scalar rows | Reference type | Parity rows | Public basis |
| --- | ---: | ---: | ---: | --- | ---: | --- |
| MacNeal-Harder shell benchmarks | 101 | 5 | 5 | Analytical / published benchmark values | 5 | Published classical benchmark set |
| Classical buckling | 105 | 2 | 2 | Closed-form formulas | 0 | Published plate and shell buckling theory |
| MYSTRAN cross-checks | 101, 105 | 2 | 2 | Tabulated reference values | 2 | MIT-licensed open-source test suite |
| CRM/uCRM wingbox modal | 103 | 1 | 5 | Tabulated modal eigenvalues | 5 | Apache-2.0 TACS CRM example with synthesized public properties |

## Two Independent Measurements: Accuracy And Parity

Every row is scored against a published or closed-form target (**accuracy**).
Twelve of the fourteen rows are additionally scored against a tabulated
reference-solver value obtained by running **this folder's own deck,
unmodified**, through an established solver (**parity**).

The two answer different questions and must not be conflated:

- Accuracy carries the discretisation error of a deliberately coarse benchmark
  mesh. No solver scores zero on it.
- Parity does not: both sides run the identical mesh and loads, so the
  discretisation error is common and cancels. A parity gap is a formulation
  difference.

Reporting only accuracy hides defects in both directions, and did: three cases
that miss their textbook target by 5-48% are in 0.02-2.3% parity (a coarse-mesh
artifact, not a solver defect), while the twisted beam sits inside a 9.7%
accuracy error and is **249% away in parity** — the largest known formulation
gap in this suite, and it was invisible until the parity column existed.

Parity tolerances are deliberately tighter than the accuracy tolerance on the
same row; there is no mesh-convergence allowance to spend.

## Current Result Snapshot

A full public-suite run writes the comparison report to:

```text
validation/comparison.md
```

Generated comparison reports are not checked in; the source decks, analytical
references, tabulated references, and manifest are the public validation
payload. The status of the current maintained revision is:

| Metric | Value |
| --- | ---: |
| Total scalar validation rows | 14 |
| Accuracy PASS / FAIL | 9 / 5 |
| Rows carrying a parity target | 12 |
| Parity PASS / FAIL | 9 / 3 |
| SOL 101 rows | 6 |
| SOL 103 rows | 5 |
| SOL 105 rows | 3 |

Per-family maxima, both measurements side by side:

| Family | Max accuracy error | Accuracy tol | Max parity error | Parity tol |
| --- | ---: | ---: | ---: | ---: |
| MacNeal-Harder | 47.8% | 2-10% by case | 249% | 2% |
| Classical buckling | 1.39% | 3-15% by case | not measured | — |
| MYSTRAN cross-check | 0.011% | 2-5% by case | 0.011% | 2-5% |
| CRM/uCRM modal | 0.14% | 5% | 0.14% | 5% |

The MYSTRAN and CRM families show identical accuracy and parity figures because
their published reference values *are* reference-solver values; those rows were
always parity measurements, and the parity column now says so explicitly.

### Open items behind the MacNeal-Harder rows

These are recorded rather than papered over. None is closed.

1. **Two decks are mis-loaded.** `hemispherical_shell` and `pinched_cylinder`
   apply half the load their symmetry model requires. Doubling the load brings
   both inside their accuracy tolerance. Left unchanged pending a decision on
   the load convention, because these decks feed the paper's validation table.
   Their accuracy FAILs (47.8% / 47.3%) are dominated by this, not by the
   solver: both are in 2.3% / 0.65% parity.
2. **`curved_beam` (28% parity) and `twisted_beam` (249% parity) are genuine
   formulation gaps.** The twisted beam's elements are warped, and it is one of
   the two cases affected by shell-normal smoothing. It is the worst parity
   case in the suite.
3. **`scordelis_lo`** misses its textbook target by 5.8% against a 5%
   tolerance while being in **0.017% parity** — a mesh-resolution artifact of
   the published deck, not a solver defect.
4. **The two classical buckling rows carry no parity target.** A reference-solver
   run of `timoshenko_plate_buckling` returns a first eigenvalue 56% away from
   both the analytical value and OpenJFEM's, which is unexplained and may be a
   convention mismatch; and `cylinder_axial_buckling` compares a critical stress
   against a raw eigenvalue, so the suite's own conversion has to be applied
   first. Neither was wired in: an unverified number in a parity column is worse
   than an empty one.

See `public_suite.yaml` for row-level tolerances and the reasoning behind them,
and rerun the suite to regenerate `comparison.csv` with the local values.

## Reproduce

From the repository root:

```powershell
.\validation\run_public_validation.ps1
```

For a quick reference/provenance check that does not run OpenJFEM and does not
overwrite `comparison.csv` or `comparison.md`:

```powershell
julia --startup-file=no --project=. validation\run_public_suite.jl --dry-run --no-write
```

The runner never calls an external solver. Analytical references are implemented
under `validation/analytical/`; tabulated references are in
`validation/references/commercial_reference.csv`.

## Publication Exclusion Rule

Do not add any of the following to this folder:

- GAME, HTP, or VTP decks or derived data.
- Proprietary aircraft or customer models.
- Commercial-solver verification kits.
- Solver-generated `.f06`, `.op2`, `.xdb`, `.h5`, `.vtk`, `.jfem`, or run
  output folders.
- Any deck whose redistribution rights are unclear.

Candidate additions should first be recorded in
`02_PROJECT_DEVELOPMENT/02.1_AGENTIC_DEVELOPMENT/public_validation_cases.json`, then added to
`validation/public_suite.yaml` only after provenance and license status are
clear.
