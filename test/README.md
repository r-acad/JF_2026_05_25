# Automated regression tests

You do not need to run these files to install or use JFEM. They are retained in
the public repository because they protect solver correctness and let users
verify a build. They contain small synthetic models and assertions.

`runtests.jl` is the entry point. It runs the curated `validation/` suite and then
focused checks of constraints, beam and shell operators, mass and buckling,
input parsing, result recovery, timing, and installation behavior. It also checks
the shared application package environment and PANDEATOR's local HTTP listener.
Individual
`*_test.jl` files isolate regressions that would be harder to diagnose from a
large application model. The JFEM-Boxer browser/generator checks live separately
under `APPS/JFEM-Boxer/test/`.

After installation, from the repository root:

```julia
using Pkg
Pkg.test()
```

Or use `julia --project=. test/runtests.jl`. These developer checks can take
longer than ordinary app startup; they are not part of the everyday launch.
Generated results belong in a temporary directory, never beside source tests.
The two documented coarse-mesh accuracy misses are asserted explicitly; the
same-deck parity checks must still pass. See `validation/VALIDATION_SUMMARY.md`.

Three integration scripts run separately because they require input-deck and
output-directory arguments: `buckling_output_test.jl`,
`pipeline_timings_solver_test.jl`, and `pipeline_timings_variants_test.jl`.
Their usage is documented at the top of each file; they are not invoked by
`runtests.jl` or `Pkg.test()`.

All current files participate in maintained regression coverage or support its
fixtures. Moving them out of the repository would break reproducible testing;
no active tests were removed merely because everyday users do not open them.
