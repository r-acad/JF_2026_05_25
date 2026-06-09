# Compatibility Wrapper

The public validation suite now lives at the repository top level:

```text
validation/
```

Use that folder for paper validation decks, references, manifests, and reports.
This `tools/validation_suite/` directory is kept only so older commands still
have an obvious landing point.

Run the suite from the new location:

```powershell
cd ..\..\validation
julia --project=.. run_public_suite.jl
```

or use the wrapper script in this directory:

```powershell
julia --project=..\.. run_public_suite.jl
```

For a quick reference/provenance check that does not rewrite comparison files:

```powershell
julia --project=..\.. run_public_suite.jl --dry-run --no-write
```
