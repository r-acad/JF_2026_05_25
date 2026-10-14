# Analytic adjoint sensitivities in WingFEGen

The default method is an **analytic discrete adjoint**. Property derivatives
use exact chain rules: explicit section/material/load formulas and forward-mode
automatic differentiation of the actual native shell kernels. Automatic
differentiation propagates derivatives through arithmetic; it does not evaluate
the model at nearby property values or choose a finite-difference step.

The explicit **Legacy · operator finite differences** option retains the old
semi-analytic implementation for comparison. Saved results identify their method.
Analytic mode never silently falls back to finite differences.

Choose the solution explicitly in **Analysis / Sensitivity / Analysis**:
SOL101 for static displacement/stress, SOL103 for a modal eigenvalue, SOL105
for a buckling factor, or SOL106 for final-load nonlinear displacement.
This choice is saved with the study and is independent of FE Analysis. Old
studies infer their original sequence from the response type.

## Static scalar response

For a fixed mesh and constraint partition, the reduced equations and adjoint are

\[
K(p)u(p)=f(p), \qquad K(p_0)^T\lambda=J_{,u}(u_0,p_0).
\]

One forward solve supplies `u0`; one adjoint solve supplies `lambda`. For every
selected property, the same vectors give

\[
\frac{dJ}{dp_i}=J_{,i}|_u+\lambda^T(f_{,i}-K_{,i}u_0).
\]

The implementation contracts affected element derivatives directly with the
expanded state and adjoint. It does not assemble and solve a new global system
for every property. A new scalar response generally needs its own adjoint.
Native RBE/MPC reductions and GRID frames are retained. Supported SOL101 follower
loads use the nonsymmetric load tangent and its transpose in the adjoint;
the current structural variables do not change prescribed aerodynamic follower
loads. Property-dependent structural inertia is differentiated.

## What is differentiated

- Native shell stiffness: constitutive laws, thickness, symmetric sandwich
  layers, condensation, drilling terms and the active warped-shell formulation.
  Fixed element and GRID transformations are replayed exactly.
- T-section dimensions, centroid offsets, stiffness, shear correction and
  recovered beam stresses; square caps and fixed runout bars follow their native
  section definitions.
- Explicit dependence of shell/beam stress on properties, including the viewer's
  shell axes and actual T-section polygon vertices.
- Structural body loads and offset moments, routed to fixed mid-bay references.
  Fuel fill and density remain fixed for the selected load case.
- Modal mass, including shell mass moments and the native bar mass formulation.
  The solver's mass scale is applied once.
- Buckling geometric stiffness and the static preload state, using one shared
  preload adjoint.

Panel-local variables act on their panel even when the value is inherited.
Shared defaults act only where the field has not been overridden. These are
distinct, potentially overlapping variables; do not simply add their derivatives.

## Work for 166 properties

| Operation | Analytic static response | Legacy with half-step checking |
| --- | ---: | ---: |
| Baseline forward analysis | 1 | 1 |
| Shared adjoint solve | 1 | 1 |
| Perturbed forward analyses | 0 | 0 |
| Property finite-difference samples | 0 | 664 |
| Exact property derivative contractions | 166 | 0 |
| Baseline operator replay/check | 1 | 1 |

The previous `665 evaluations` counted the baseline replay plus four operator
samples per property (`+h`, `-h`, `+h/2`, `-h/2`). Those samples are absent in
analytic mode. Each property still needs its affected element derivatives and
contractions. Compilation, baseline analysis and replay also take time; constant
solve count does not imply constant total time.

Progress and saved results distinguish analytic derivatives from finite-difference
samples. Analytic rows have no step or step-error estimate and generate no
perturbed `variable_*` decks.

## Scope and accuracy

This is the derivative of the **discrete FE equations**, evaluated to floating
point and solver tolerances. It does not remove modelling error or poor
conditioning. Independent finite differences of rebuilt decks and solved
responses are used in validation tests only.

The adapter supports fixed geometry/connectivity, isotropic PSHELL, centered
symmetric isotropic PCOMP sandwich, and generated T-section, square-cap and
fixed runout bars. Unsupported constitutive/kernel branches fail explicitly,
including anisotropic or independent-material PSHELL, unsymmetric/off-center
laminates and experimental shell recovery branches. Optional aerodynamic shells
exported as structural deck elements must be disabled for analytic sensitivity;
the normal aerodynamic load surface is supported.

Static displacement and stress objectives use SOL101. SOL103 uses the baseline
eigenvector and analytic stiffness/mass derivatives without a static adjoint.
SOL105 also needs the static-preload adjoint; its workload is not simply two
linear static solves. SOL106 uses the converged nonlinear displacement and its
exact residual Jacobian, as described below.

Individual derivatives require a smooth response branch. Repeated eigenvalues,
ambiguous stress extrema and tied material maxima with unequal directional
derivatives are rejected where relevant. Nodes, property IDs, constraints and
active numerical branches must remain consistent with the baseline replay.

## Nonlinear displacement (SOL106)

The supported `legacy_geometric` formulation solves a final-load residual

\[
R(u,p)=K(p)u+cK_g(u,p)u-f(p)=0,
\qquad R_{,u}^{T}\lambda=J_{,u},
\qquad \frac{dJ}{dp_i}=J_{,i}|_u-\lambda^TR_{,i}|_u.
\]

Here `c=1` for `tangent_operator` and `c=1/2` for `secant_geometric`.
The residual Jacobian includes the derivative of prestress with respect to
displacement, `d(Kg(u)u)/du`. The nonlinear iteration matrix alone is not this
Jacobian. Local automatic differentiation and exact beam chain rules assemble
the generally nonsymmetric residual Jacobian; one transpose solve supplies the
adjoint for all selected properties. One forward analysis can contain many load
increments and equilibrium iterations, which are counted as part of that
baseline, not as property perturbation solves.

The baseline must be accepted at the full requested load, with a replayed
residual no greater than `1e-6`. Partial-load checkpoints cannot supply a
full-load sensitivity. The supported scope is displacement of MAT1/isotropic
shell and CBAR models, homogeneous constraints and fixed-direction loads, with
the existing supported native RBE/MPC reductions. Formal von Karman kernels,
nonlinear stress objectives, follower-load derivatives, thermal loads and
unsupported element/material branches are rejected explicitly. Generated
structural inertia loads retain their analytic property derivatives; imported
mass-dependent load tangents remain outside this path's supported scope.

## Imported Reference decks

Read Reference uses the original deck, identifiers and chosen subcase for the
baseline. Imported sensitivity supports SOL101 displacement and shell/bar stress,
SOL103 modal eigenvalues, SOL105 buckling factors and the supported SOL106
nonlinear displacement path, with PSHELL thickness, proportional symmetric
isotropic PCOMP thickness, MAT1 E/nu/density and T/BAR/ROD PBARL dimensions.
It uses the same analytic element derivatives and shared adjoint; there are no
property finite differences or automatic legacy fallback.

An imported deck can contain cards beyond the viewport and derivative adapters.
Unsupported owners of a selected property/material, releases, offsets,
constitutive branches and mass-dependent load tangents must be supported before
their derivatives can be reported. Otherwise the row fails explicitly instead
of returning a partial contribution. Ordinary analyses still use the source
deck and the solver's native card support. Modal derivatives include native mass
scaling, consistent/lumped mass and shell mass moments. Buckling derivatives
include both the explicit elastic/geometric terms and the static-preload
adjoint. Selecting a source buckling companion follows its `STATSUB` ownership;
distinct preload/eigenproblem constraint sets are retained and rejected when
the derivative adapter cannot represent them. The source cards are unchanged.

Every sensitivity baseline is retained as an ordinary FE result. SOL105 also
retains its SOL101 preload, including requested stress and constraint reactions,
without another forward solve. Physical reactions are shown on static results
and preload shapes; modal/buckling eigenmode views do not relabel arbitrarily
normalized mode quantities as physical preload reactions.

Workers load the selected solver's precompiled package and verify its source
path. This removes repeated source-module compilation without changing numerical
operators. Package loading, deck parsing, analysis, compilation and export have
separate recorded timings. First use after source/package changes can still
require cache rebuilding and compilation.

## Source map

- [sensitivity_compute.jl](src/sensitivity_compute.jl): method selection and progress.
- [sensitivity_analytic.jl](src/sensitivity_analytic.jl): direct element contractions.
- [sensitivity_analytic_properties.jl](src/sensitivity_analytic_properties.jl): ownership and layer/material chain rules.
- [sensitivity_analytic_beams.jl](src/sensitivity_analytic_beams.jl): section, offset, stiffness, mass and stress derivatives.
- [sensitivity_analytic_loads.jl](src/sensitivity_analytic_loads.jl): body loads and shell mass.
- [sensitivity_analytic_geometric.jl](src/sensitivity_analytic_geometric.jl): native geometric stiffness and preload gradients.
- [native analytic_shells.jl](../../src/solver/analytic_shells.jl): shell kernel replay and differentiation.
- [sensitivity_eigen_adjoint.jl](src/sensitivity_eigen_adjoint.jl): modal and buckling equations.
- [sensitivity_nonlinear.jl](src/sensitivity_nonlinear.jl): exact final-state nonlinear residual and adjoint.
- [reference_import_sensitivity.jl](src/reference_import_sensitivity.jl): native-source catalog, coverage checks and solution dispatch.
- [native_solver_loader.jl](src/native_solver_loader.jl): verified package-cache loading.
