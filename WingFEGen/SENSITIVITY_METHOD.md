# What the WingFEGen adjoint calculation does

The current implementation is a **semi-analytic discrete adjoint with finite
differences of native assembled operators**. It is not a fully analytic or
automatically differentiated implementation. It also does not use full-response
finite differences that solve a new equilibrium problem for each property.

## Static scalar response

For a fixed mesh and support/constraint partition, write the reduced linear
equations as

\[
K(p)u(p)=f(p).
\]

Here `p` is the vector of properties, `u` the independent displacement vector,
`K` the assembled system matrix and `f` the assembled load vector. Let the scalar
response be `J(u,p)`, such as a displacement component or a recovered stress.

The baseline forward analysis solves for `u0` at `p0`. The adjoint solves

\[
K(p_0)^T\lambda_0=\frac{\partial J}{\partial u}(u_0,p_0).
\]

For every property `pi`, the derivative is

\[
\frac{dJ}{dp_i}=
\left.\frac{\partial J}{\partial p_i}\right|_u+
\lambda_0^T\left(
\frac{\partial f}{\partial p_i}-\frac{\partial K}{\partial p_i}u_0
\right).
\]

The same `u0` and `lambda0` are used for all selected properties. A new scalar
response generally needs its own adjoint right-hand side and solve. This is the
reason the static solve count depends on the number of responses, not on the
number of properties.

The actual adapter uses the native reduced equations after RBE/MPC handling.
For supported SOL101 follower loads, the reduced operator includes the
nonsymmetric load tangent and the adjoint uses its transpose. The fixed-state
operator samples include property-dependent body loads, beam offsets and
explicit stress recovery, rather than differentiating stiffness alone.

## Where finite differences enter

The current code rebuilds the native operators at nearby property values. In
schematic form, a central derivative uses

\[
K_{,i}\simeq\frac{K(p_0+h_i e_i)-K(p_0-h_i e_i)}{2h_i},
\qquad
f_{,i}\simeq\frac{f(p_0+h_i e_i)-f(p_0-h_i e_i)}{2h_i}.
\]

Explicit property dependence in `J` is evaluated with `u0` held fixed. In the
implementation these terms can be combined by sampling a fixed-state
Lagrangian:

\[
L_i(\delta)=J(u_0,p_0+\delta e_i)+
\lambda_0^T\big[f(p_0+\delta e_i)-K(p_0+\delta e_i)u_0\big].
\]

The central difference of `L_i` gives the derivative above. There is no
calculation of `u(p0 + delta ei)` in these samples. They parse the sample deck,
assemble operators, recover the requested response at the fixed state and
perform matrix-vector products/dot products. They do not factor and solve a
perturbed equilibrium system. Samples are retained as operator diagnostics,
not exported as new physical load cases.

## Work for 166 properties

| Operation | Count for one static response |
| --- | ---: |
| Baseline forward analysis | 1 |
| Shared adjoint solve | 1 |
| Perturbed forward analyses | 0 |
| Central operator samples without step checking | 332 |
| Central operator samples with half-step checking | 664 |
| Baseline operator replay/check | 1 |

With the check enabled, each property is sampled at `+h`, `-h`, `+h/2`, `-h/2`.
The displayed operator-evaluation total is therefore `1 + 4 * 166 = 665`.
The finer derivative is reported and compared with the coarse one. Near a
property bound, the code uses a labeled second-order one-sided stencil; its
half-step check reuses a sample and can need three unique samples rather than
four. Counts report the calls actually made.

The total work is approximately

`one forward + one adjoint + N * (two or four operator samples)`.

Matrix assembly is usually cheaper than a solve, but can still be substantial.
This implementation currently reassembles the whole model for each sample.
Deck generation/parsing, response recovery and fresh-worker Julia compilation
also contribute. Hence constant solve count does not imply constant total time.

## Accuracy and a fully analytic alternative

The adjoint equation is solved numerically to solver tolerances. The property
derivatives additionally have finite-difference truncation and roundoff errors.
Central differences are second-order in the step for smooth responses. Steps
that are too large cause truncation error; steps that are too small cause
cancellation. The half-step check is a useful consistency check, not proof of
convergence and not an independent comparison against solved perturbed models.

A fully analytic discrete adjoint would supply exact formulas, or suitable
automatic differentiation, for the required operator/response derivatives.
It would remove the property finite-difference step. Element-local derivative
contractions could also avoid repeated full-model assembly. It would still
need to evaluate and output each requested property derivative; total gradient
work does not become independent of the number of variables.

The current method has been checked against independent full-response finite
differences in separate numerical regressions. That validation does not turn
the production operator derivatives into analytic ones.

## Supported scope

Static displacement and stress sensitivities use SOL101. SOL103 eigenvalue
derivatives reuse the baseline eigenvector and do not require a separate static
adjoint equation. SOL105 buckling derivatives include the baseline eigenproblem
and a shared static-preload adjoint; they are not simply a generic pair of
linear static solves. SOL106 nonlinear response sensitivities are not offered
by this adapter.

Connectivity, property IDs, coordinate ordering and the support/constraint
partition must remain fixed. The adapter checks replay consistency and rejects
unsupported changes. Repeated eigenvalues and nondifferentiable objective
branches cannot be treated as ordinary unique scalar derivatives.

Relevant implementation files:

- [sensitivity_compute.jl](src/sensitivity_compute.jl): property stencils, counts and orchestration.
- [sensitivity_operators.jl](src/sensitivity_operators.jl): static adjoint and fixed-state native assembly.
- [sensitivity_eigen_adjoint.jl](src/sensitivity_eigen_adjoint.jl): modal/buckling derivatives.
- [sensitivity_baseline.jl](src/sensitivity_baseline.jl): retained physical baseline results.
