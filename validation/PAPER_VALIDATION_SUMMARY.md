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
| MacNeal-Harder shell benchmarks | 101 | 6 | 6 | Analytical / published benchmark values | 6 | Published classical benchmark set |
| Classical buckling | 105 | 2 | 4 | Closed-form formulas + STATSUB preload | 2 | Published plate and shell buckling theory |
| MYSTRAN cross-checks | 101, 105 | 2 | 2 | Tabulated reference values | 2 | MIT-licensed open-source test suite |
| CRM/uCRM wingbox modal | 103 | 1 | 5 | Tabulated modal eigenvalues | 5 | Apache-2.0 TACS CRM example with synthesized public properties |

## Two Independent Measurements: Accuracy And Parity

Every row is scored against a published or closed-form target (**accuracy**).
Fifteen of the seventeen rows are additionally scored against a tabulated
reference-solver value obtained by running **this folder's own deck,
unmodified**, through an established solver (**parity**). Every one of the ten
cases carries at least one such measurement.

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
deliberately coarse.

Parity tolerances are deliberately tighter than the accuracy tolerance on the
same row; there is no mesh-convergence allowance to spend. Since same-deck
parity is now exact to five to eight significant figures, they were tightened
from `2%` to `0.1%` (`0.5%` on the CRM modal rows) so the gate can still detect
a regression.

### One unstated solver parameter accounted for every residual parity error

`PARAM,K6ROT`, the Hughes-Brezzi drilling-DOF stabilisation coefficient, is not
part of any of these benchmark definitions and solvers default it differently:
`0.0` in the reference solver's SOL 101, `100.0` in current MSC.Nastran and in
OpenJFEM. Every tabulated parity reference had been produced at `0.0` on a deck
that declared nothing, while OpenJFEM ran the same deck at `100.0`.

That single unstated difference was the *entire* residual parity error on all
six shell rows. It only broke tolerance on the pinched hemisphere, the most
K6ROT-sensitive case in the set, where it read as a 3.50% "formulation gap".

Confirmed from both sides on the reference solver: the hemisphere deck returns
the same answer cardless and with `PARAM,K6ROT,0.` (the full 25-node
displacement blocks are bit-identical), and with `PARAM,K6ROT,100.` it returns
OpenJFEM's own default-run answer to the output file's full print precision. At
the matched setting OpenJFEM reproduces the reference's complete 25-node
translation field to `1.5e-7` relative L2.

Every shell deck here now declares the parameter — see `README.md`,
"PARAM,K6ROT". Because `0.0` was already the reference solver's default, none of
the previously tabulated reference values changed.

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
| Total scalar validation rows | 17 |
| Accuracy PASS / FAIL | 15 / 2 |
| Rows carrying a parity target | 15 |
| Parity PASS / FAIL | **15 / 0** |
| Cases with at least one parity row | **10 / 10** |
| SOL 101 rows | 7 |
| SOL 103 rows | 5 |
| SOL 105 rows | 5 |

Per-family maxima, both measurements side by side:

| Family | Max accuracy error | Accuracy tol | Max parity error | Parity tol |
| --- | ---: | ---: | ---: | ---: |
| MacNeal-Harder | 47.6% | 2-10% by case | 0.0000062% | 0.1% |
| Classical buckling | 3.56% | 3-15% by case | 0.00039% (STATSUB preload) | 0.1% |
| MYSTRAN cross-check | 0.0000102% | 2-5% by case | 0.0000102% | 0.1% |
| CRM/uCRM modal | 0.0282% | 5% | 0.0282% | 0.5% |

The MYSTRAN and CRM families show identical accuracy and parity figures because
their published reference values *are* reference-solver values; those rows were
always parity measurements, and the parity column now says so explicitly.

### Same-deck parity, all 15 rows

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
| `TG_plate_uniaxial_buckling` STATSUB preload | `5.00e-8` | `1e-3` |
| `BA_cylinder_axial_buckling` STATSUB preload | `3.90e-6` | `1e-3` |

### Status notes behind the MacNeal-Harder rows

1. **The hemisphere parity gap was a solver-parameter default, not a
   formulation gap.** It closed from `3.50%` to `3.8e-8` once `PARAM,K6ROT` was
   declared in the deck, and the same correction took every other shell row to
   between `1.3e-8` and `6.2e-5`. See the K6ROT subsection above.

2. **`twisted_beam` was scoring the wrong load case.** The deck applied the
   out-of-plane tip load (+Y) while the row compared it against the *in-plane*
   published target — the entire source of its former 68.5% "accuracy error".
   At the tip the 1.1 width lies along global Z, so the in-plane direction is
   +Z. The deck's load was rotated to +Z (`0.77%` accuracy, PASS) and the
   out-of-plane case was split into its own deck and row (`2.66%`, PASS). Both
   carry their own reference-solver parity value.

3. **`hemispherical_shell` applied half the benchmark load and used the wrong
   variant's reference.** The benchmark load is `P = 2.0`, so the quarter model
   carries `1.0` at each loaded equator node, not `0.5`; and the deck is the
   18-deg cut-out variant, whose published reference is `0.0930`, not the
   closed-pole `0.0924`. Both are corrected. The load error was confirmed
   independently by convergence: at `0.5`/node the response is flat in the mesh
   at 0.507-0.516 of the reference through N = 32, i.e. it converges to exactly
   half. The row is now `+6.2%` against a `0.10` tolerance set from the
   published 4-node spread at this mesh (0.928-1.099).

4. **`scordelis_lo`** is at `5.8%` accuracy and `3.7e-8` parity. Its tolerance
   was widened `0.05 -> 0.10`, set from the published 4-node spread on the
   identical 4x4 mesh (0.9432-1.083); OpenJFEM sits at 1.0581 and converges to
   0.9999 at 16x16.

5. **`curved_beam` and `pinched_cylinder` remain accuracy FAILs, deliberately.**
   No published per-mesh band supports widening their tolerances, and widening
   them to pass would be fitting the gate to the answer. Both are correctly
   posed — in particular the pinched cylinder's `P/4 = 0.25` octant load is
   *correct*, because its load point lies on two of the three symmetry planes.
   At these meshes no published 4-node shell element approaches its converged
   target either (pinched cylinder at N=4: 0.370 to 0.636 across six published
   elements, OpenJFEM 0.5228, reference solver 0.5241; curved beam at 6x1:
   MacNeal & Harder's own published QUAD4 value 0.833, OpenJFEM 0.8310,
   reference solver 0.8334), and OpenJFEM converges onto both targets under
   refinement (1.0002 at 24x24 and 1.006 at 24x4 respectively).

   *This supersedes an earlier note in this file which stated that the pinched
   cylinder, like the hemisphere, "applies half the load its symmetry model
   requires". That was correct for the hemisphere and wrong for the pinched
   cylinder: doubling its load would put the converged solution at twice the
   published reference, trading a real coarse-mesh error for a permanent 100%
   load error that merely cancels at N = 4.*

6. **The two classical buckling EIGENVALUE rows still carry no parity target**,
   and the reason is now characterised rather than unexplained: the reference
   solver's eigenvalue extraction on those two decks is demonstrably incomplete
   (its own Sturm-sequence counts contradict its printed first mode) and a
   Sturm-guarded re-run returns a spurious near-null cluster instead. See
   `README.md`, "Tabulated commercial-solver values". An unverified number in a
   parity column is worse than an empty one.

   Both classical *cases* are nevertheless parity-covered: each now carries a
   second row on its SOL 105 `STATSUB` static preload field, which is well-posed
   for both codes and agrees to `5.0e-8` (plate) and `3.9e-6` (cylinder, in the
   deck's `CORD2C` cylindrical output frame). Be precise about the scope: those
   rows verify the stiffness matrix, the applied load and the boundary
   conditions on the identical mesh. They do **not** verify the geometric
   stiffness `K_g` or the eigensolver, which remain unverified against a
   reference solver on these two decks.

Published per-mesh comparators quoted above are from Y. Ko, P.-S. Lee and
K.-J. Bathe, "Performance of the MITC3+ and MITC4+ shell elements in
widely-used benchmark problems", *Computers & Structures* **193** (2017)
187-206, Tables 8, 10, 12, 13 and 15.

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
