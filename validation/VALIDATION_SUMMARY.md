# JFEM validation results

Recorded results, 19 October 2026. **[Browse the illustrated gallery](index.html)**
or consult the [18-case inventory](CASE_INVENTORY.csv). Every case has its own
[two-page card, model, figures and numerical data](README.md).

## Coverage and interpretation

| Recorded collection | Analyses | Comparisons and outcome |
|---|---:|---|
| Existing cases and selected refinements | 18 | 24 quantities: 14 PASS, two coarse-mesh FAIL, eight REGRESSION_PASS |
| Five new analytical cases, all meshes and load levels | 39 | 126 comparisons: 98 PASS, 28 coarse-mesh FAIL |
| Total completed analyses with retained results | **57** | Results and failed accuracy comparisons remain recorded |
| Retained cylinder diagnostic | **1** | Partial spectrum; excluded from qualification |
| Default manifest check, selected from the collection | **24** | **44 quantities: 34 PASS, two coarse-mesh FAIL, eight REGRESSION_PASS** |

The existing cases additionally carry **17 secondary HISTORICAL_PASS** checks.
These secondary numbers are not extra analyses or independent validation
comparisons. The full new set has **28 quantities on its finest meshes; all 28
pass** their declared tolerances, across the relevant load levels.

Sixteen of the 18 case folders have independent analytical or published targets.
The CRM modal model and open-source static patch provide historical regression
and model-scale demonstrations. Stored historical numbers lack an independently
reproducible public result artifact and therefore establish regression only.

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

## Reproduce and inspect

[README.md](README.md) gives the launcher, full convergence commands and the
**Project → Open JFEM results…** workflow. The current selected-run snapshot is
[comparison.csv](comparison.csv) / [comparison.md](comparison.md); individual
cards link the underlying references and recorded result files. Preserve model
units, explicit constraints, material assumptions and stabilization settings
when reproducing a comparison. Published displacement targets include their
reported precision, and eigenvector amplitude is arbitrary.
