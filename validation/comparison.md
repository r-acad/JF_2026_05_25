# JFEM Public Validation and Regression Report

Generated: 2026-10-19T12:05:54.531

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
| MH_curved_beam_in_plane | tip_disp_in_plane | 0.08734 | 0.072787 | 0.166625 | 0.02 | FAIL | 0.072787 | 1.32585e-08 | 0.001 | HISTORICAL_PASS |
| MH_curved_beam_refined | tip_disp_in_plane | 0.08734 | 0.0878974 | 0.00638177 | 0.02 | PASS | 0.0879005 | 3.59063e-05 | 0.001 | HISTORICAL_PASS |
| MH_twisted_beam_in_plane | tip_disp_in_plane | 0.005424 | 0.00538214 | 0.00771719 | 0.02 | PASS | 0.00538214 | 6.13769e-09 | 0.001 | HISTORICAL_PASS |
| MH_twisted_beam_out_of_plane | tip_disp_out_of_plane | 0.001754 | 0.0017073 | 0.0266271 | 0.05 | PASS | 0.0017073 | 2.35724e-09 | 0.001 | HISTORICAL_PASS |
| MH_scordelis_lo | midedge_vertical_disp | -0.3024 | -0.320003 | 0.0582104 | 0.1 | PASS | -0.320003 | 3.671e-08 | 0.001 | HISTORICAL_PASS |
| MH_scordelis_lo_N08 | midedge_vertical_disp | -0.3024 | -0.305613 | 0.0106241 | 0.1 | PASS |  |  |  |  |
| MH_scordelis_lo_N16 | midedge_vertical_disp | -0.3024 | -0.302694 | 0.000971233 | 0.1 | PASS |  |  |  |  |
| MH_pinched_cylinder | radial_disp_under_load | 1.8248e-05 | -9.56357e-06 | 0.475911 | 0.1 | FAIL | -9.5635e-06 | 7.19678e-06 | 0.001 | HISTORICAL_PASS |
| MH_pinched_cylinder_refined | radial_disp_under_load | 1.8248e-05 | -1.82865e-05 | 0.00210881 | 0.02 | PASS | -1.82863e-05 | 8.83235e-06 | 0.001 | HISTORICAL_PASS |
| MH_hemispherical_shell | radial_disp_at_load | 0.093 | 0.0987484 | 0.0618106 | 0.1 | PASS | 0.0987484 | 3.76131e-08 | 0.001 | HISTORICAL_PASS |
| MH_hemispherical_shell_N08 | radial_disp_at_load | 0.093 | 0.0952897 | 0.0246204 | 0.1 | PASS |  |  |  |  |
| MH_hemispherical_shell_N16 | radial_disp_at_load | 0.093 | 0.0938719 | 0.00937553 | 0.1 | PASS |  |  |  |  |

## Family: classical

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| TG_plate_uniaxial_buckling | first_buckling_lambda | 7.592e+07 | 7.71864e+07 | 0.0166801 | 0.03 | PASS |  |  |  |  |
| TG_plate_uniaxial_buckling | preload_ux_node_36 | -4.76191e-12 | -4.7619e-12 | 5e-08 | 0.001 | REGRESSION_PASS | -4.76191e-12 | 5e-08 | 0.001 | HISTORICAL_PASS |
| BA_cylinder_axial_buckling | classical_critical_stress | 1.27098e+09 | 1.32539e+09 | 0.042809 | 0.15 | PASS |  |  |  |  |
| BA_cylinder_axial_buckling | preload_uz_node_1 | 4.7716e-10 | 4.7716e-10 | 1.80847e-08 | 0.001 | REGRESSION_PASS | 4.7716e-10 | 1.80847e-08 | 0.001 | HISTORICAL_PASS |
| BA_cylinder_axial_buckling_N16x04 | classical_critical_stress | 1.27098e+09 | 1.2778e+09 | 0.00537132 | 0.15 | PASS |  |  |  |  |

## Family: mystran_xref

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| MYSTRAN_sol101_simple | T1_node_1013 | 0.00305328 | 0.00305328 | 1.02013e-07 | 0.02 | REGRESSION_PASS | 0.00305328 | 1.02013e-07 | 0.001 | HISTORICAL_PASS |
| MYSTRAN_sol105_buckling | lambda_1 | 10280.8 | 10358.2 | 0.00752233 | 0.05 | PASS | 10358.2 | 3.61679e-07 | 0.001 | HISTORICAL_PASS |

## Family: crm

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| CRM_wingbox_modal | eigenvalue_mode1 | 111.776 | 111.776 | 6.43444e-09 | 0.05 | REGRESSION_PASS | 111.776 | 6.43444e-09 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode2 | 990.31 | 990.31 | 7.99372e-08 | 0.05 | REGRESSION_PASS | 990.31 | 7.99372e-08 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode3 | 1355.94 | 1355.94 | 3.30779e-07 | 0.05 | REGRESSION_PASS | 1355.94 | 3.30779e-07 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode4 | 5946.72 | 5946.72 | 8.00996e-08 | 0.05 | REGRESSION_PASS | 5946.72 | 8.00996e-08 | 0.005 | HISTORICAL_PASS |
| CRM_wingbox_modal | eigenvalue_mode5 | 10448.8 | 10448.8 | 3.70786e-07 | 0.05 | REGRESSION_PASS | 10448.8 | 3.70786e-07 | 0.005 | HISTORICAL_PASS |

## Family: academic_analytical

| case_id | quantity | reference | JFEM | rel_err | tol | verdict | parity ref | parity rel_err | parity tol | parity |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | --- |
| ACA01_static | tip_y | 0.00114286 | 0.00114286 | 1.15498e-11 | 0.005 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_1 | 166.93 | 166.93 | 5.87805e-08 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_2 | 6556 | 6556.01 | 6.42073e-07 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_3 | 51400.1 | 51400.4 | 5.02376e-06 | 0.01 | PASS |  |  |  |  |
| ACA01_modal | bending_eigenvalue_4 | 197378 | 197382 | 1.92448e-05 | 0.01 | PASS |  |  |  |  |
| ACA02_static | tip_y | 1.84143e-05 | 1.84143e-05 | 1.34132e-12 | 0.0001 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_1 | 5.65426 | 5.64949 | 0.000842836 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_2 | 10.4535 | 10.445 | 0.000809579 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_3 | 21.1043 | 21.0856 | 0.000885901 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_4 | 22.617 | 22.5877 | 0.00129703 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_5 | 28.2951 | 28.2432 | 0.00183387 | 0.02 | PASS |  |  |  |  |
| ACA03_buckling | buckling_factor_6 | 36.3635 | 36.3207 | 0.00117586 | 0.02 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_1 | 48442.1 | 48411 | 0.000642182 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_2 | 358234 | 358232 | 6.77831e-06 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_3 | 382711 | 382817 | 0.000276591 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_4 | 775074 | 774690 | 0.000494568 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_5 | 1.62727e+06 | 1.62877e+06 | 0.000920973 | 0.04 | PASS |  |  |  |  |
| ACA04_modal | modal_eigenvalue_6 | 1.75781e+06 | 1.76053e+06 | 0.00154557 | 0.04 | PASS |  |  |  |  |
| ACA05_nonlinear | tip_x | 0.1 | 0.1 | 9.99201e-15 | 0.0001 | PASS |  |  |  |  |
| ACA05_nonlinear | lateral_contraction | -0.012805 | -0.012805 | 2.33013e-14 | 0.0001 | PASS |  |  |  |  |

_Note: rows with an empty parity column declare no `parity` block in `public_suite.yaml` -- no reference-solver value has been verified for that quantity. An empty parity cell means unmeasured, not passing._
