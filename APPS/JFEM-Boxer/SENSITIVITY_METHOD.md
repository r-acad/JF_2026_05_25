# Analytic adjoint sensitivities in JFEM-Boxer

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

## Reserve-factor derivatives and structural sizing

Open **Results / Stress Report / RF sensitivities and structural sizing**.
This section computes derivatives of physical failure checks, including the
effect of changes in structural stiffness and internal-load redistribution.
It is separate from the immediate fixed-force RF estimates shown while
manually editing a property.

The RF service uses generated models and fixed nodal geometry/topology, with
supported structural inertia-load derivatives. RF derivatives currently require
fixed-direction loads for both SOL101 and SOL106; follower-force definitions
are rejected before a derivative or sizing solve. SOL101 uses its verified linear
equilibrium. For eligible elastic SOL106 cases choose **Geometric stiffness ·
consistent residual** in **Analysis / FE Analysis / Nonlinear formulation**;
the RF derivative uses the accepted full-load residual and its consistent
Jacobian. Automatic selection is preserved and unsupported formal shell,
history/contact, follower-load or recovery branches are rejected explicitly,
not replaced by a linear analysis. SOL106 RFs remain proportional assessments
of the full-load recovered demands, not nonlinear collapse-load predictions.
A capability gap is never filled with zero sensitivity. Imported engineering
regions, shape changes and coupled aerodynamic/inertia-relief derivatives need
their own verified adapters. The ordinary scalar sensitivity capabilities
described earlier are a separate service.

### Compute an RF sensitivity matrix

1. Define the materials, allowables, load cases and minimum gauges. Create the
   current FEM. Finish outstanding property-edit drafts before starting.
2. Open **RF sensitivities and structural sizing** and choose **Read RFs and
   design variables**. This reads a catalog; it does not start differentiation.
   Catalog RFs can be marked as not yet analysed. The native run performs the
   required forward analyses before evaluating their derivatives.
3. Select physical RF checks on the left and independent dimensions on the
   right. Filter either list and use **Select matching RFs** or **Select
   matching variables**. Selection includes all matches, including entries
   beyond the displayed page. An unavailable check remains visible with its
   reason.
4. Choose **RF-by-dimension matrix**. Select either **Reserve factor** or
   **Utilization**, where utilization is the inverse of RF.
5. Choose the explicit **Strength envelope** used for this calculation:
   maximum element stress, equal-element average, or average below the
   specified percentile. This setting is recorded with the derivative run;
   it is independent of the Stress Report's table display controls.
6. Choose **Run RF sensitivities**. Progress identifies the current numerical
   phase. **Cancel run** requests a cooperative stop; the current numerical
   block may need to finish first.
7. Inspect the matrix below or choose **Open RF sensitivity table ↗**. The
   detached table has row filtering, row/column pages and CSV export. A full
   matrix can be much larger than its displayed page.

One row identifies a physical criterion and load case. One column identifies
a continuous dimension, such as shell thickness or stringer web thickness.
A T-section can have several columns despite having one property ID. A shared
skin/stringer Euler-column check is one physical response even though its RF
appears against several properties in the normal RF table.

Negative derivatives are red, positive derivatives blue and zero neutral.
Each column uses its own symmetric color range. Grey means unavailable,
not zero. With utilization selected, a negative derivative means increasing
the dimension reduces the assessed utilization on the current smooth branch.
RF derivatives have the opposite sign where RF is finite and nonzero.

Dimensional derivatives use the column's physical unit. For example, an RF
derivative per metre must be multiplied by 0.001 to obtain the derivative per
millimetre. **Relative elasticity** displays
`dimension / response × derivative` where both baseline quantities permit it.
The numerical service retains full floating-point precision; display rounding
does not quantize derivative calculations.

Large Jacobians are retained as native files. The table then explicitly shows
a preview. **Export full CSV** downloads all computed entries;
**Download numeric matrix** and **Download matrix metadata** provide Float64
data and the response/variable mapping. Metadata records matrix shape,
column-major storage order, endianness and quantity. Nonfinite/missing entries
are identified rather than converted to zero. **Export result JSON** retains
the recorded descriptors, numerical results or preview, signatures and statuses.

Matrix metadata is self-contained: it includes physical response scopes,
failure modes, load cases, variable units and source signatures. Its
`export_complete` flag means the requested file was written completely.
`derivative_complete` separately states whether every requested derivative was
available. A completely written matrix can still contain unavailable entries;
review their status and reason before using it for sizing.

### Directional and weighted-response products

A complete matrix is useful for investigation, but it is often unnecessary
inside an optimizer:

- **Jacobian product · Jv** applies the recorded Jacobian or selected
  subgradient along one design direction. Enter one value per selected
  dimension, in catalog order.
- **Directional derivative · mode-cluster aware** resolves supported
  tied/clustered plate modes for the supplied direction. At a mode crossing,
  this true directional result need not be a linear function of the direction;
  a single Jacobian or selected subgradient cannot represent every direction.
- **Weighted response gradient · Jᵀw** computes the design gradient of a
  weighted sum of selected responses. Enter one weight per selected RF.

J, Jv and Jᵀw use the same selected gradient or generalized gradient. At
nonsmooth ties, these linear products need not equal the true directional
derivative; use the mode-cluster-aware operation for supported directional
assessments.

Vectors accept numeric lists, for example `[1, 0, -1]`, or JSON objects keyed
by the displayed catalog IDs. Omitted IDs in an object have zero weight;
unknown IDs and nonfinite values are rejected. Values are in the displayed
variable units, not automatically relative percentages.

Adjoints share forward/factorization work across responses where compatible.
One independent scalar response generally needs its own adjoint right-hand
side; it does not supply every RF row. Weighted products can require far fewer
right-hand sides than exporting the entire matrix.

### Run bounded minimum-mass sizing

1. Select all physical checks that the proposed sizing must satisfy. Checks
   omitted from the request are not optimization constraints.
2. Select the dimensions allowed to change. Review their **Minimum** and
   **Maximum** bounds in the column unit. A lower bound cannot be below the
   model's minimum gauge. These bounds define the permitted sizing range.
3. Choose **Minimum-mass sizing**. Utilization is selected automatically:
   each selected constraint requires utilization ≤ 1, equivalent to RF ≥ 1.
4. Set the iteration budget, relative move limit and sizing tolerance. A
   smaller move limit limits each trial dimension change and can help when
   governing failure modes change. Feasibility uses utilization ≤ 1 plus the
   selected numerical tolerance; inspect RFs close to 1 before accepting the
   final engineering design.
5. Choose **Run minimum-mass sizing**. The history reports mass, maximum
   utilization and feasibility. Sizing uses full-equilibrium derivatives,
   not the fixed-force manual preview.
6. Read the termination reason and independent final-verification status.
   Reaching the iteration limit is not proof of convergence or feasibility.
   An incomplete or uncertified approximate constraint cannot silently pass.
   Convergence checks feasibility, scaled projected Lagrangian stationarity
   and complementary slackness together. This prevents accepting a slack
   augmented-subproblem stationary point as a minimum-mass design.
7. After the final independent assessment completes, Boxer applies the final
   dimensions, regenerates the FEM while preserving the camera, and enables
   the updated property color field. The Study is marked unsaved. Review the
   **Optimized structural dimensions** table for the initial value, optimized
   value, percentage change and bounds of each physical dimension.
8. A stopped run can provide a final assessed design. Its termination and
   feasibility status remain visible alongside the applied properties.
   Cancelled or failed runs require another run before automatic application.
   If model regeneration fails, **Apply optimized dimensions** retries the
   assessed design while the Study and assessment still match.

All selected load cases share one structural design vector. Every trial
solves those cases and applies every selected case-specific RF constraint,
so sizing solves

\[
\min_x m_{\mathrm{structure}}(x),\qquad
U_{i,c}(x)\leq1\quad\text{for every selected check }i\text{ and case }c,
\qquad x_{\min}\leq x\leq x_{\max}.
\]

Each case can govern different regions or failure modes. The displayed maximum
utilization is the maximum over the selected checks and cases. The minimum RF
is its inverse. Case loads retain their individual aerodynamic definitions,
while structural inertia loads follow the updated structural mass. The log
records case solves, RF assessment, adjoint work, iteration mass and RF,
governing case/mode/property, accepted steps and final independent verification.

If a plate's numerical basis cannot establish convergence, sizing can use a
certified conservative all-mode constraint for that physical check. The exported
physical plate RF and sizing bound are recorded separately. If a new check needs
this certificate during a trial, the optimizer reassesses the accepted design
and resets its multipliers, penalty and curvature history before continuing.
The log and checkpoint record the constraint-policy revision. Other converged
plate checks retain their physical criteria. Exhausting trial assessments stops
with an explicit assessment-limited reason. A changed criterion at final
verification requires renewed sizing before claiming convergence.

Starting a new analysis clears displayed results from previous runs, including
the detached derivative table. Current-run results appear as they arrive.

Strength uses the configured ULTIMATE safety factor applied to recovered
LIMIT demands. Buckling uses the separate buckling-policy factor. The factors
are not applied a second time to the FE load case. RF99/no-demand and the
RF999 display cap are presentation conventions, not constants to differentiate.

The governing case, stress face, percentile membership or buckling mode can
switch. Exact minima/maxima are piecewise differentiable; near-ties and
unavailable derivatives require attention. Plate eigenpair derivatives refer
to their recorded basis. A truncated Ritz basis is not automatically a
conservative sizing constraint.

Changing the Study, material allowables, sizing policy or relevant assessment
definition marks retained derivatives as stale. Read a current catalog and run
again before applying dimensions to the changed design.

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
- [rf_native_assessment.jl](src/rf_native_assessment.jl): physical RF responses and local recovery/capacity partials.
- [rf_kernels.jl](src/rf_kernels.jl): material, column, blade and plate calculations.
- [rf_recovery.jl](src/rf_recovery.jl): native recovered-feature pullbacks.
- [rf_adjoint.jl](src/rf_adjoint.jl): response matrices and directional/weighted products.
- [rf_sensitivity.jl](src/rf_sensitivity.jl): design maps, analysis orchestration and exports.
- [rf_optimization.jl](src/rf_optimization.jl): bounded minimum-mass sizing.
