# OpenJFEM Public Validation Suite -- Comparison Report

Generated: 2026-06-06T21:37:49.279

Summary: 14 quantity rows (14 PASS, 0 FAIL, 0 JFEM_SKIPPED, 0 ERROR_REF)

## Family: macneal_harder

| case_id | quantity | reference | JFEM | rel_err | tol | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| MH_curved_beam_in_plane | tip_disp_in_plane | 0.08734 | 0.0856613 | 0.0192199 | 0.02 | PASS |
| MH_twisted_beam_in_plane | tip_disp_in_plane | 0.005424 | 0.00535799 | 0.0121694 | 0.02 | PASS |
| MH_scordelis_lo | midedge_vertical_disp | -0.3024 | -0.289864 | 0.0414538 | 0.05 | PASS |
| MH_pinched_cylinder | radial_disp_under_load | 1.8248e-05 | -1.82115e-05 | 0.00199927 | 0.1 | PASS |
| MH_hemispherical_shell | radial_disp_at_load | 0.0924 | 0.095432 | 0.0328143 | 0.05 | PASS |

## Family: classical

| case_id | quantity | reference | JFEM | rel_err | tol | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| TG_plate_uniaxial_buckling | first_buckling_lambda | 7.592e+07 | 7.60891e+07 | 0.00222716 | 0.03 | PASS |
| BA_cylinder_axial_buckling | classical_critical_stress | 1.27098e+09 | 1.43067e+09 | 0.125643 | 0.15 | PASS |

## Family: mystran_xref

| case_id | quantity | reference | JFEM | rel_err | tol | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| MYSTRAN_sol101_simple | T1_node_1013 | 0.00305328 | 0.00305294 | 0.000109947 | 0.02 | PASS |
| MYSTRAN_sol105_buckling | lambda_1 | 10358.2 | 10358.2 | 3.61679e-07 | 0.05 | PASS |

## Family: crm

| case_id | quantity | reference | JFEM | rel_err | tol | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| CRM_wingbox_modal | eigenvalue_mode1 | 111.776 | 111.737 | 0.000349883 | 0.05 | PASS |
| CRM_wingbox_modal | eigenvalue_mode2 | 990.31 | 989.832 | 0.00048304 | 0.05 | PASS |
| CRM_wingbox_modal | eigenvalue_mode3 | 1355.94 | 1355.33 | 0.000451669 | 0.05 | PASS |
| CRM_wingbox_modal | eigenvalue_mode4 | 5946.72 | 5944.14 | 0.000433742 | 0.05 | PASS |
| CRM_wingbox_modal | eigenvalue_mode5 | 10448.8 | 10444.8 | 0.000383229 | 0.05 | PASS |
