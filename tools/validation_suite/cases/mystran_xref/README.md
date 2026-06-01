# MYSTRAN Cross-Check Cases

Two decks taken from the MYSTRAN open-source test suite, used as
cross-solver references for the validation suite.

## Source

MYSTRAN, MIT-licensed: <https://github.com/MYSTRANsolver/MYSTRAN>.

A snapshot of the MYSTRAN repository is bundled with this workspace at
`03_EXTERNAL_TOOLS/MYSTRANSolver-main/`. The two decks here are copied from
that snapshot:

| Local file | Source path in MYSTRAN |
| --- | --- |
| `sol101_simple.bdf` | `Build_Test_Cases/statics/cquad4_pshell_center.bdf` |
| `sol105_buckling.bdf` | `Build_Test_Cases/buckling/bar.bdf` |

`LICENSE.MYSTRAN.txt` in this folder is the upstream MIT license.

## What These Cases Test

- `sol101_simple.bdf` -- a small CQUAD4 patch on a PSHELL with point loads.
  SOL 101 linear static. Reference quantity: T1 displacement at node 1013.
- `sol105_buckling.bdf` -- a 10-element CBAR cantilever under axial end
  load. SOL 105 (legacy `SOL 5`) Euler column buckling. Reference quantity:
  first buckling eigenvalue.

## Modifications Made For Portability

MYSTRAN supports a handful of case-control and bulk-data entries that
classical BDF-based solvers in general do not. To keep each deck
parseable across solvers we commented the MYSTRAN-only entries; the
in-deck comments document each change. No geometry, no material, no
load, no SPC was touched.

| Deck | What was commented |
| --- | --- |
| `sol101_simple.bdf` | six `ELDATA(*)` case-control lines; two `DEBUG` bulk entries; inline `$ fixed`/`$ free` comments on four `GRID` lines |
| `sol105_buckling.bdf` | one `EIGRL` continuation containing `DGB`; one `DEBUG` bulk entry |

JFEM is expected to parse the same files; lines starting with `$` are
ignored by every classical BDF parser.

## Reference Values

Reference numbers for these two decks are tabulated in
[`../../references/commercial_reference.csv`](../../references/commercial_reference.csv).
They were produced once on the maintainer's machine with an established
commercial finite-element solver and are committed as numbers only; no
solver-branded output files are shipped with the suite.

## No SOL 103 Case

The MYSTRAN public test suite (as of this snapshot) does not contain a
SOL 103 / normal-modes case. The validation suite's modal cross-check
is supplied by the CRM case in [`../crm/`](../crm/).
