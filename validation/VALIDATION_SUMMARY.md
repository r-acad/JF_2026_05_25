# JFEM validation results

Recorded results, 19 October 2026. **[Browse the illustrated gallery](index.html)**
or consult the [19-case inventory](CASE_INVENTORY.csv). Every case has its own
[case card, model, figures and numerical data](README.md).

## Coverage and interpretation

| Recorded collection | Analyses | Comparisons and outcome |
|---|---:|---|
| Earlier cases and selected refinements | 18 | 24 quantities: 14 PASS, two coarse-mesh FAIL, eight REGRESSION_PASS |
| Five analytical cases, all meshes and load levels | 39 | 126 comparisons: 98 PASS, 28 coarse-mesh FAIL |
| Original published uCRM9, static and modal | **2** | 20/20 frequencies and 19/20 angular eigenvalues below 0.5%; static sampling point unqualified |
| Total distinct completed analyses with retained results | **59** | 57 earlier analyses plus two runs of the original published uCRM9 model |
| Retained cylinder diagnostic | **1** | Partial spectrum; excluded from qualification |
| Earlier selected-manifest snapshot | **24** | **44 quantities: 34 PASS, two coarse-mesh FAIL, eight REGRESSION_PASS** |

The existing cases additionally carry **17 secondary HISTORICAL_PASS** checks.
These secondary numbers are not extra analyses or independent validation
comparisons. The full new set has **28 quantities on its finest meshes; all 28
pass** their declared tolerances, across the relevant load levels.

The earlier 57 analyses retain their recorded solver revisions. The two original
uCRM9 analyses use the corrected shell implementation described below; this
addition does not represent a rerun of the complete collection on that source.
The uniform CRM's five-mode historical control was repeated and changed by at
most 9.18e-9% in angular eigenvalue. It is a repeat of an existing analysis and
does not increase the distinct-analysis count.

Seventeen of the 19 case folders have independent analytical or published
computational targets. The uniform-material CRM modal model and open-source
static patch provide historical regression and model-scale demonstrations.
Their stored historical numbers establish regression only. The original
anisotropic uCRM9 is a separate case with author-published structural targets.

All comparisons use the production solver and documented input controls. A
completed analysis can still fail its continuum accuracy tolerance on a coarse mesh.
These are equation and benchmark checks with the assumptions stated on each
card, rather than experimental material or structural-capacity measurements.

## New analytical cases

| Case card | Solutions | Distinct analyses | Finest responses | Worst finest error | Declared response tolerance |
|---|---|---:|---:|---:|---:|
| [ACA01 · Slender cantilever](cases/ACA01/case_card.pdf) | 101, 103 | 8 | 6 | 0.00096223% | 0.5% |
| [ACA02 · Shear-flexible cantilever](cases/ACA02/case_card.pdf) | 101 | 5 | 2 | 1.3877e-10% | 0.01% |
| [ACA03 · Cross-ply plate buckling](cases/ACA03/case_card.pdf) | 105 | 5 | 6 | 0.18339% | 2% |
| [ACA04 · Cross-ply plate vibration](cases/ACA04/case_card.pdf) | 103 | 5 | 6 | 0.077249% | 2% |
| [ACA05 · Finite-strain membrane](cases/ACA05/case_card.pdf) | 106 | 16 | 8 | 5.6736e-12% | 0.01% |

ACA01 checks Euler–Bernoulli bending and four natural frequencies. ACA02 adds
the explicitly prescribed effective shear area of a Timoshenko beam. ACA03 and
ACA04 compare the first six responses of a symmetric cross-ply laminate with
Navier solutions. Their full nodal transverse mode shapes also agree closely
with the analytical shapes: minimum MAC is **0.99999847** for buckling and
**0.99999995** for vibration. MAC is computed from the recorded nodal shapes;
arbitrary mode sign and amplitude cancel.

ACA05 checks homogeneous finite-strain membrane tension at four stretch levels
and four meshes using a reduced plane-stress constitutive equation. Thickness
strain is condensed by plane stress. It does not establish finite-rotation
bending or plasticity behavior. For ACA04, both the reference and FE model omit
independent rotary inertia; thin-theory and finite-element differences include
transverse-shear flexibility and discretization.

The 28 coarse-mesh failures remain in each new case's `results/comparison.csv`
and convergence figures. The tolerances were declared before execution.
The default manifest compares selected eigenvalues, while the modal cards and
complete convergence tables report frequencies; their units and tolerances are
specified for the quantity actually compared.

## Existing benchmarks and refinements

| Case card | Supplied-model error | Refined result |
|---|---:|---|
| [Curved beam, coarse](cases/MH_curved_beam_in_plane/case_card.pdf) | **16.663% FAIL** | [24×4 companion](cases/MH_curved_beam_refined/case_card.pdf): 0.63818% |
| [Twisted beam, in-plane](cases/MH_twisted_beam_in_plane/case_card.pdf) | 0.77172% | Published target, 2% tolerance |
| [Twisted beam, out-of-plane](cases/MH_twisted_beam_out_of_plane/case_card.pdf) | 2.6627% | Published target, 5% tolerance |
| [Scordelis–Lo roof](cases/MH_scordelis_lo/case_card.pdf) | 5.8210% | 8×8: 1.0624%; 16×16: **0.097123%** |
| [Pinched cylinder, coarse](cases/MH_pinched_cylinder/case_card.pdf) | **47.591% FAIL** | [24×24 companion](cases/MH_pinched_cylinder_refined/case_card.pdf): **0.21088%** |
| [Hemisphere with opening](cases/MH_hemispherical_shell/case_card.pdf) | 6.1811% | 8×8: 2.4620%; 16×16: **0.93755%** |
| [Square plate buckling](cases/TG_plate_uniaxial_buckling/case_card.pdf) | 1.6680% | Analytical target, 3% tolerance |
| [Cylinder screening strip](cases/BA_cylinder_axial_buckling/case_card.pdf) | 4.2809% | Finest certified 16×4: **0.53713%** |
| [One-element cantilever buckling](cases/MYSTRAN_sol105_buckling/case_card.pdf) | 0.75223% | Independent Euler target, 5% tolerance |

The two coarse failures remain explicit. Their separate refined inputs show
decreasing error against the same references. Refinement evidence does not
prove that every remaining difference is discretization error. In particular,
the cylinder strip compares a finite constrained sector with ideal cylinder
theory and retains its stated **15% analytical-screening tolerance**.

The 32×8 cylinder diagnostic returns five accepted roots from an EIGRL request
for six. Its first candidate differs from theory by 0.43454%, but global
first-root and spectrum completeness are unqualified. Bounded extraction checks
recover seven of eight required roots, so the smaller error is **not** counted
as a qualified refinement or PASS. The input and partial result remain under
`cases/BA_cylinder_axial_buckling/diagnostics/N32x08/`.

The [CRM modal model](cases/CRM_wingbox_modal/case_card.pdf) contains 23,738 nodes
and 25,055 shell elements. Its geometry and material definitions are openly
documented, while its stored comparison values remain historical regression
targets. The [quadrilateral static patch](cases/MYSTRAN_sol101_simple/case_card.pdf)
has the same regression-only classification. Neither case is presented as an
independent accuracy certificate.

## Original published uCRM9 structural model

The [original uCRM9 case](cases/CRM_uCRM9_published/README.md) uses the authors'
released coarse model and structural reference workbook from the
[uCRM dataset](https://data.mendeley.com/datasets/gpk4zn73xn/1)
(DOI 10.17632/gpk4zn73xn.1, CC BY 4.0). Its associated article is
[Brooks, Kenway and Martins, *Benchmark Aerostructural Models for the Study of
Transonic Aircraft Wings*](https://doi.org/10.2514/1.J056603), 2018.
All original active cards, material frames, anisotropic section tensors, rigid
connections, masses, restraints and fixed cruise loads were retained.

The model contains 23,812 total nodes, 25,055 shell elements, 242 section
properties and 74 concentrated masses. Static equilibrium and the first 20
normal modes were solved. The [case card](cases/CRM_uCRM9_published/case_card.pdf),
[full-precision metrics](cases/CRM_uCRM9_published/metrics.csv) and
[numerical record](cases/CRM_uCRM9_published/results/comparison.json) preserve
the individual values and reference cells.

| Quantity | Available | Largest relative error | Interpretation at 0.5% |
|---|---:|---:|---|
| Natural frequency, Hz | 20/20 | **0.273387%** | **20/20 PASS** |
| Angular eigenvalue, `(2πf)²` | 20/20 | **0.546027%** | **19/20 PASS; first mode FAIL** |
| Static vertical displacement at inferred GRID 833 | 1 inferred point | 1.63893% | **AMBIGUOUS_POINT; no qualified PASS** |

Frequency and angular eigenvalue are two representations of the same modal
information; their percentage errors differ. The first computed frequency is
1.624820769 Hz against 1.629275 Hz. Its angular eigenvalue is 104.2247015 against
104.7969212 rad²/s², so frequency agreement below 0.5% does not imply that every
angular eigenvalue meets that threshold.

The static workbook gives 2.5239 m without identifying its observation node or
chord position. The predeclared inferred GRID 833 gives 2.4825351 m, while all
21 tip-rib nodes span 2.4725100–2.5324511 m. The complete
[tip-node table](cases/CRM_uCRM9_published/results/tip_comparison.csv) is retained;
no point is selected by matching the target. The references belong to the
workbook's fixed-load structural solution. The case documentation distinguishes
them from the publication's coupled aeroelastic results.

This run exposed two shell-energy defects. A bending internal-mode correction
could be applied while that option was disabled, and reduced shear integration
omitted the one-point quadrature weight on its diagonal terms. The corrections
also keep coupled internal-mode terms consistent with the complete section
energy. A scan of every source shell now finds zero negative-energy elements
at relative thresholds of 1e-14, 1e-12 and 1e-10; the worst remaining relative
eigenvalue is −3.09e-16, at roundoff level.

The corrected global static matrix factors by Cholesky with a relative
equilibrium residual of 3.29e-11 and zero regularization. The modal pencil has
zero negative inertia at the origin; an inertia-based completeness check counts
20 roots below the last-mode bound. All 20 independent returned modes satisfy
the original eigenproblem, with maximum relative residual **4.14e-11**. Ordered
frequency agreement does not establish mode-shape identity because the
reference workbook supplies no eigenvectors.

The original `K6ROT=1e5` card remains present; the native CQUADR operator uses its
internal drilling policy. The case card records this formulation limit.
Static displacements and constraint reactions are available, while independent-
material/MID4 shell stress and force recovery remain unavailable. This case does
not establish accuracy for those absent fields.

## Reproduce and inspect

[README.md](README.md) gives the launcher, full convergence commands and the
**Project → Open JFEM results…** workflow. The current selected-run snapshot is
[comparison.csv](comparison.csv) / [comparison.md](comparison.md); individual
cards link the underlying references and recorded result files. Preserve model
units, explicit constraints, material assumptions and stabilization settings
when reproducing a comparison. Published displacement targets include their
reported precision, and eigenvector amplitude is arbitrary.
