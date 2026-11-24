# JFEM Public Validation and Regression Report

Generated: 2026-11-24T19:21:11.732

Summary: 44 quantity rows (34 PASS, 2 FAIL, 0 JFEM_SKIPPED, 0 ERROR_REF)
Historical primary targets: 8 REGRESSION_PASS, 0 REGRESSION_FAIL.

Secondary targets: 17 rows (0 PARITY_PASS, 0 PARITY_FAIL, 17 HISTORICAL_PASS).

Published and closed-form targets measure validation error including mesh discretization.
REGRESSION and HISTORICAL labels identify stored values whose independent public source
artifact is not included. These preserve reproducibility across releases and do not
establish independent published or experimental validation. Secondary results do not change
the primary verdict. Every nested convergence case is included in a full run.

## Family: macneal_harder

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| MH_curved_beam_in_plane | tip_disp_in_plane | 0.08734 | 0.0775097 | 0.112553 | 0.02 | FAIL | 0.0775097 | 3.22972e-11 | 0.001 | HISTORICAL_PASS |
| MH_curved_beam_refined | tip_disp_in_plane | 0.08734 | 0.0882676 | 0.0106204 | 0.02 | PASS | 0.0882676 | 2.60861e-10 | 0.001 | HISTORICAL_PASS |
| MH_twisted_beam_in_plane | tip_disp_in_plane | 0.005424 | 0.0053879 | 0.00665595 | 0.02 | PASS | 0.0053879 | 8.54677e-12 | 0.001 | HISTORICAL_PASS |
| MH_twisted_beam_out_of_plane | tip_disp_out_of_plane | 0.001754 | 0.00172906 | 0.0142174 | 0.05 | PASS | 0.00172906 | 1.39681e-12 | 0.001 | HISTORICAL_PASS |
| MH_scordelis_lo | midedge_vertical_disp | -0.3024 | -0.320003 | 0.0582104 | 0.1 | PASS | -0.320003 | 3.67099e-08 | 0.001 | HISTORICAL_PASS |
| MH_scordelis_lo_N08 | midedge_vertical_disp | -0.3024 | -0.305613 | 0.0106241 | 0.1 | PASS |  |  |  |  |
| MH_scordelis_lo_N16 | midedge_vertical_disp | -0.3024 | -0.302694 | 0.000971233 | 0.1 | PASS |  |  |  |  |
| MH_pinched_cylinder | radial_disp_under_load | 1.8248e-05 | -9.71027e-06 | 0.467872 | 0.1 | FAIL | -9.71027e-06 | 1.74461e-16 | 0.001 | HISTORICAL_PASS |
| MH_pinched_cylinder_refined | radial_disp_under_load | 1.8248e-05 | -1.83038e-05 | 0.00305708 | 0.02 | PASS | -1.82863e-05 | 0.000955114 | 0.001 | HISTORICAL_PASS |
| MH_hemispherical_shell | radial_disp_at_load | 0.093 | 0.0989038 | 0.0634817 | 0.1 | PASS | 0.0989038 | 1.76377e-13 | 0.001 | HISTORICAL_PASS |
| MH_hemispherical_shell_N08 | radial_disp_at_load | 0.093 | 0.0953564 | 0.0253379 | 0.1 | PASS |  |  |  |  |
| MH_hemispherical_shell_N16 | radial_disp_at_load | 0.093 | 0.0939231 | 0.00992596 | 0.1 | PASS |  |  |  |  |

## Family: classical

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| TG_plate_uniaxial_buckling | first_buckling_lambda | 7.592e+07 | 7.70672e+07 | 0.0151106 | 0.03 | PASS |  |  |  |  |
| TG_plate_uniaxial_buckling | preload_ux_node_36 | -4.76191e-12 | -4.7619e-12 | 2.50255e-09 | 0.001 | REGRESSION_PASS | -4.76191e-12 | 2.50255e-09 | 0.001 | HISTORICAL_PASS |
| BA_cylinder_axial_buckling | classical_critical_stress | 1.27098e+09 | 1.29782e+09 | 0.0211176 | 0.15 | PASS |  |  |  |  |
| BA_cylinder_axial_buckling | preload_uz_node_1 | 4.7716e-10 | 4.77209e-10 | 0.000103025 | 0.001 | REGRESSION_PASS | 4.7716e-10 | 0.000103025 | 0.001 | HISTORICAL_PASS |
| BA_cylinder_axial_buckling_N16x04 | classical_critical_stress | 1.27098e+09 | 1.27104e+09 | 4.55042e-05 | 0.15 | PASS |  |  |  |  |

## Family: mystran_xref

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| MYSTRAN_sol101_simple | T1_node_1013 | 0.0030625 | 0.0030625 | 0 | 0.02 | REGRESSION_PASS | 0.0030625 | 0 | 0.001 | HISTORICAL_PASS |
| MYSTRAN_sol105_buckling | lambda_1 | 10280.8 | 10358.2 | 0.00752233 | 0.05 | PASS | 10358.2 | 3.61679e-07 | 0.001 | HISTORICAL_PASS |

## Family: crm

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| CRM_wingbox_modal | eigenvalue_mode1 | 111.776 | 111.749 | 0.000249131 | 0.05 | REGRESSION_PASS | 111.776 | 0.000249131 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode2 | 990.31 | 990.082 | 0.000230533 | 0.05 | REGRESSION_PASS | 990.31 | 0.000230533 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode3 | 1355.94 | 1355.45 | 0.000361442 | 0.05 | REGRESSION_PASS | 1355.94 | 0.000361442 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode4 | 5946.72 | 5943.69 | 0.000508412 | 0.05 | REGRESSION_PASS | 5946.72 | 0.000508412 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode5 | 10448.8 | 10445.3 | 0.000330564 | 0.05 | REGRESSION_PASS | 10448.8 | 0.000330564 | 0.005 | HISTORICAL_PASS |

## Family: academic_analytical

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| ACA01_static | tip_y | 0.00114286 | 0.00114286 | 1.49127e-08 | 0.005 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_1 | 166.93 | 166.93 | 5.87805e-08 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_2 | 6556 | 6556.01 | 6.42073e-07 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_3 | 51400.1 | 51400.4 | 5.02376e-06 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_4 | 197378 | 197382 | 1.92448e-05 | 0.01 | PASS |  |  |  |  |
| ACA02_static | tip_y | 1.84143e-05 | 1.84143e-05 | 1.34132e-12 | 0.0001 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_1 | 5.65426 | 5.64949 | 0.000843112 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_2 | 10.4535 | 10.445 | 0.000809942 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_3 | 21.1043 | 21.0856 | 0.000886257 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_4 | 22.617 | 22.5877 | 0.00129814 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_5 | 28.2951 | 28.2431 | 0.00183528 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_6 | 36.3635 | 36.3207 | 0.00117621 | 0.02 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_1 | 48442.1 | 48411 | 0.000642458 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_2 | 358234 | 358232 | 7.14186e-06 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_3 | 382711 | 382817 | 0.000276233 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_4 | 775074 | 774690 | 0.000495672 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_5 | 1.62727e+06 | 1.62877e+06 | 0.000920616 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_6 | 1.75781e+06 | 1.76053e+06 | 0.00154521 | 0.04 | PASS |  |  |  |  |
| ACA05_nonlinear | tip_x | 0.1 | 0.1 | 5.55112e-16 | 0.0001 | PASS |  |  |  |  |
| ACA05_nonlinear | lateral_contraction | -0.012805 | -0.012805 | 3.17006e-14 | 0.0001 | PASS |  |  |  |  |

_Note: rows with an empty parity column declare no `parity` block in `public_suite.yaml` -- no reference-solver value has been verified for that quantity. An empty parity cell means unmeasured, not passing._
