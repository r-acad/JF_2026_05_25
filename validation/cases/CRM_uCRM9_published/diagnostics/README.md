# Isolated shell energy diagnostics

These small fixtures document two corrections exposed by the original uCRM9
wing-box model. They preserve the authors' node coordinates, thickness and
anisotropic section matrices. The global static and modal comparisons are in
the parent case folder.

| Fixture | Issue corrected |
| --- | --- |
| `element_energy_fixture.json`, element 22498 / property 229 | Supplying membrane–bending coupling incorrectly enabled an unrequested internal-curvature condensation and an inconsistent modified bending tensor. Internal-mode flags are now respected, with the complete bending law retained in coupled energy. |
| `element_shear_fixture_19371.json`, element 19371 / property 222 | Directionally reduced shear rules omitted the one-point Gauss weight 2, while cross terms retained full weight. The diagonal rules now use their proper weights. |

`element_energy_before_after.json` retains the same negative-work direction
before and after the coupled-energy correction. `energy_consistency_summary.json`
records source hashes, local spectra, the full 25,055-element scan and 632 passing
regression assertions. Eigenvalues of an element stiffness matrix mix
translation and rotation units: their sign tests local energy consistency;
they are **not** physical modal frequencies. Small negative minima at roundoff
are assessed relative to the largest absolute local eigenvalue.

All 25,055 corrected local operators have no negative eigenvalues below a
relative threshold of−1e−14. This result establishes neither a global frequency
error threshold nor static-displacement accuracy; those require the separate
unchanged-model comparisons. Test and scan timings include only the explicitly
stated stages and are not general performance measurements.

Coordinates use metres. Section matrices use A[N/m], B[N], D[N m] and S[N/m],
with engineering shear components in element local axes.

Source: Timothy R. Brooks, Gaetan G. W. Kenway and Joaquim R. R. A. Martins,
[uCRM: undeflected Common Research Model](https://data.mendeley.com/datasets/gpk4zn73xn/1),
DOI 10.17632/gpk4zn73xn.1. These extracted diagnostics are attributed derivatives
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
