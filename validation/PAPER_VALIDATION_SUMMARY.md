# OpenJFEM Paper Validation Summary

This folder is the public validation evidence intended to accompany the
OpenJFEM paper. It contains only redistributable cases: published benchmarks,
synthetic decks derived from published formulas, and permissively licensed
open-source cross-checks.

Private GAME, HTP, and VTP cases are not included and are not referenced by the
public validation manifest.

## Included Families

| Family | SOL | Cases | Scalar rows | Reference type | Public basis |
| --- | ---: | ---: | ---: | --- | --- |
| MacNeal-Harder shell benchmarks | 101 | 5 | 5 | Analytical / published benchmark values | Published classical benchmark set |
| Classical buckling | 105 | 2 | 2 | Closed-form formulas | Published plate and shell buckling theory |
| MYSTRAN cross-checks | 101, 105 | 2 | 2 | Tabulated reference values | MIT-licensed open-source test suite |
| CRM/uCRM wingbox modal | 103 | 1 | 5 | Tabulated modal eigenvalues | Apache-2.0 TACS CRM example with synthesized public properties |

## Current Result Snapshot

A full public-suite run writes the comparison report to:

```text
validation/comparison.md
```

Generated comparison reports are not checked in; the source decks, analytical
references, tabulated references, and manifest are the public validation
payload. The latest maintained public-suite status is:

| Metric | Value |
| --- | ---: |
| Total scalar validation rows | 14 |
| PASS rows | 14 |
| FAIL rows | 0 |
| SOL 101 rows | 6 |
| SOL 103 rows | 5 |
| SOL 105 rows | 3 |

Largest relative errors by family:

| Family | Max relative error | Tolerance |
| --- | ---: | ---: |
| MacNeal-Harder | 4.145% | 2-10% by case |
| Classical buckling | 12.564% | 3-15% by case |
| MYSTRAN cross-check | 0.011% | 2-5% by case |
| CRM/uCRM modal | 0.048% | 5% |

The larger classical-cylinder tolerance is intentional: the reference is a
classical thin-shell formula and the deck includes a finite discretization and
drilling-stiffness treatment. See `public_suite.yaml` for row-level tolerances,
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
