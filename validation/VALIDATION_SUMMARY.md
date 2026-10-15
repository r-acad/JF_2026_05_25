# OpenJFEM Validation Summary

This folder contains the public validation evidence for OpenJFEM:
published benchmarks, synthetic decks derived from published formulas, and
open-source cross-checks.

## Included Families

| Family | SOL | Cases | Scalar rows | Reference type | Parity rows | Public basis |
| --- | ---: | ---: | ---: | --- | ---: | --- |
| MacNeal-Harder shell benchmarks | 101 | 6 | 6 | Analytical / published benchmark values | 6 | Published classical benchmark set |
| MacNeal-Harder refined companions | 101 | 2 | 2 | Same published values, refined mesh | 2 | Convergence evidence for the two hardest cases |
| Classical buckling | 105 | 2 | 4 | Closed-form formulas + STATSUB preload | 2 | Published plate and shell buckling theory |
| MYSTRAN cross-checks | 101, 105 | 2 | 2 | Tabulated reference values | 2 | MIT-licensed open-source test suite |
| CRM/uCRM wingbox modal | 103 | 1 | 5 | Tabulated modal eigenvalues | 5 | Apache-2.0 TACS CRM example with synthesized public properties |

## Two Independent Measurements: Accuracy And Parity

Every row is scored against a published or closed-form target (**accuracy**).
Seventeen of the nineteen rows are additionally scored against a tabulated
reference-solver value obtained by running **this folder's own deck,
unmodified**, through an established solver (**parity**). Every one of the
thirteen cases carries at least one such measurement.

The two answer different questions and must not be conflated:

- Accuracy carries the discretisation error of a deliberately coarse benchmark
  mesh. No solver scores zero on it.
- Parity does not: both sides run the identical mesh and loads, so the
  discretisation error is common and cancels. A parity gap is a formulation
  difference.

Reporting only accuracy hides defects in both directions, and did. The two rows
that still miss their textbook targets — by 16.7% and 47.6% — are in `1.3e-8`
and `7.2e-6` same-deck parity: the reference solver misses the same targets by
the same amounts on the same decks, because the standard benchmark meshes are
deliberately coarse. Their refined companions settle the question directly, at
0.64% and 0.21% of the same published targets.

Parity tolerances are deliberately tighter than the accuracy tolerance on the
same row; there is no mesh-convergence allowance to spend. Since same-deck
parity is now exact to five to eight significant figures, they were tightened
from `2%` to `0.1%` (`0.5%` on the CRM modal rows) so the gate can still detect
a regression.

### Reproducible shell settings

All shell decks specify `PARAM,K6ROT` explicitly. Keep those values when
reproducing this suite; changing drilling-rotation stabilization can change
the response. The individual decks and the manifest record the tested inputs.

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
| Total scalar validation rows | 19 |
| Accuracy PASS / FAIL | 17 / 2 |
| Rows carrying a parity target | 17 |
| Parity PASS / FAIL | **17 / 0** |
| Cases with at least one parity row | **13 / 13** |
| SOL 101 rows | 9 |
| SOL 103 rows | 5 |
| SOL 105 rows | 5 |

Per-family maxima, both measurements side by side:

| Family | Max accuracy error | Accuracy tol | Max parity error | Parity tol |
| --- | ---: | ---: | ---: | ---: |
| MacNeal-Harder (benchmark + refined) | 47.6% | 2-10% by case | 0.0036% | 0.1% |
| Classical buckling | 3.56% | 3-15% by case | 0.00039% (STATSUB preload) | 0.1% |
| MYSTRAN cross-check | 0.0000362% | 2-5% by case | 0.0000362% | 0.1% |
| CRM/uCRM modal | 0.0014% | 5% | 0.0014% | 0.5% |

The MYSTRAN and CRM families show identical accuracy and parity figures because
their published reference values *are* reference-solver values; those rows were
always parity measurements, and the parity column now says so explicitly.

### Same-deck parity, all 17 rows

| Row | Parity rel. error | Tol |
| --- | ---: | ---: |
| `MH_curved_beam_in_plane` | `1.32e-8` | `1e-3` |
| `MH_twisted_beam_in_plane` | `3.29e-5` | `1e-3` |
| `MH_twisted_beam_out_of_plane` | `6.19e-5` | `1e-3` |
| `MH_scordelis_lo` | `3.67e-8` | `1e-3` |
| `MH_pinched_cylinder` | `7.20e-6` | `1e-3` |
| `MH_hemispherical_shell` | `3.81e-8` | `1e-3` |
| `MYSTRAN_sol101_simple` | `1.02e-7` | `1e-3` |
| `MYSTRAN_sol105_buckling` | `3.62e-7` | `1e-3` |
| `CRM_wingbox_modal` modes 1-5 | `2.91e-5` .. `2.82e-4` | `5e-3` |
| `MH_curved_beam_refined` | `3.59e-5` | `1e-3` |
| `MH_pinched_cylinder_refined` | `8.83e-6` | `1e-3` |
| `TG_plate_uniaxial_buckling` STATSUB preload | `5.00e-8` | `1e-3` |
| `BA_cylinder_axial_buckling` STATSUB preload | `3.90e-6` | `1e-3` |

### Limits of these results

- The standard curved-beam and pinched-cylinder meshes miss their analytical
  targets by 16.7% and 47.6%. They remain reported as accuracy failures. The
  supplied refined companion decks reduce those errors to 0.64% and 0.21%.
- The two classical buckling eigenvalue rows have analytical targets but no
  tabulated parity values. Their static-preload rows are parity checked; this
  does not establish agreement of their geometric stiffness or eigenvalues.
- Accuracy and parity are separate checks. Agreement on an identical coarse
  mesh does not demonstrate mesh convergence.

See `public_suite.yaml` for quantities and tolerances. A fresh run produces
the comparison values for your installed source revision.

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
