# Common Research Model (CRM) Wing-Box

The TACS `examples/crm/CRM_box_2nd.bdf` uCRM coarse wing-box deck.
Used for the suite's industrial-scale modal cross-check (SOL 103).

## Files In This Folder

| File | What it is |
| --- | --- |
| `wingbox_modal.bdf` | The original TACS deck, with one mechanical edit (`CQUADR` -> `CQUAD4`). Has no `PSHELL`/`MAT*`; not runnable on its own. |
| `wingbox_modal_with_props.bdf` | The runnable deck: original + synthesised properties + case-control + EIGRL. **This is the one the manifest points at.** |
| `LICENSE.TACS.txt` | Upstream Apache 2.0 license. |

The augmented deck is regenerated from `wingbox_modal.bdf` by
[`../../helpers/synthesize_crm_properties.ps1`](../../helpers/synthesize_crm_properties.ps1).
Re-run that script if the source BDF or the material properties change.

## Source

Copied from `03_EXTERNAL_TOOLS/tacs-master/examples/crm/CRM_box_2nd.bdf`
(Apache 2.0). The TACS Python runner that drives this mesh is
`03_EXTERNAL_TOOLS/tacs-master/examples/crm/crm_frequency.py`.

## Modifications Made

1. **CQUADR -> CQUAD4** (25055 elements). The two cards have identical
   field layout. The substitution removes a dependence on the CQUADR
   spelling that not every BDF-based solver recognises.
2. **PSHELL/MAT/EIGRL/case-control synthesised** from the TACS Python
   runner. The synthesis is:
   - one `MAT1` with `E = 70e9` Pa, `nu = 0.3`, `rho = 2500` kg/m^3
     (values lifted verbatim from `crm_frequency.py` lines 17--19);
   - 242 `PSHELL` cards (one per CQUAD4 PID in the source), all with
     `t = 0.02` m (the initial design value from line 24);
   - `EIGRL` requesting the 5 lowest eigenvalues;
   - case-control adding `SPC = 1`, `METHOD = 1`,
     `DISPLACEMENT(PLOT) = ALL`;
   - `PARAM, K6ROT = 100` for drilling stabilisation;
   - `PARAM, AUTOSPC = NO` so the solver does not silently constrain
     DOFs we did not explicitly fix.

Geometry, node numbering, element connectivity, and the SPC set are
unchanged from the upstream TACS deck.

## Mesh Summary

- 23,738 GRID points (long-field format)
- 25,055 CQUAD4 elements distributed across 242 PIDs
- SPC set 1 fixing several thousand grids
- BDF size: 5.4 MB (augmented), 5.3 MB (original)

## Reference Values

Five first-eigenvalue references for this case are tabulated in
[`../../references/commercial_reference.csv`](../../references/commercial_reference.csv)
under row IDs `CRM_wingbox_modal_mode1` through `..._mode5`. They were
produced once on the maintainer's machine with a commercial
finite-element solver and are committed here as numbers only; no
solver-branded output files are shipped with the suite.

| Mode | eigenvalue (omega^2) | frequency (Hz) |
| --- | ---: | ---: |
| 1 | 1.117764e2 | 1.683 |
| 2 | 9.903101e2 | 5.008 |
| 3 | 1.355943e3 | 5.861 |
| 4 | 5.946717e3 | 12.273 |
| 5 | 1.044876e4 | 16.269 |

A maintainer with access to a BDF-based commercial solver can
regenerate these numbers by running `wingbox_modal_with_props.bdf` and
parsing the first five eigenvalues from the result. An open-source path
(MYSTRAN, Code_Aster, CalculiX) is equally acceptable and may eventually
replace the commercial-source values entirely.

## Citation

Brooks, T. R., Kennedy, G. J., Kenway, G. K. W., Martins, J. R. R. A.,
*"Benchmarking the Common Research Model wingbox structural design
optimization"*, AIAA Journal (2018). Repository:
<https://github.com/smdogroup/tacs/tree/master/examples/crm>.
