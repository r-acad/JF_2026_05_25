# Contributing to OpenJFEM

Thank you for your interest in OpenJFEM. This document explains how to make
changes that fit the project's structure and validation discipline.

## Repository Scope

This repository is the **public** surface of the OpenJFEM project. Internal
validation decks, run outputs, external reference solvers, papers, and
development notes live in a separate workspace and are deliberately kept out
of Git. Only the following kinds of files belong here:

- Julia source code in `src/`.
- Public installation and automation helpers in `JFEM_installation/`.
- Bundled installation/precompile decks in `JFEM_installation/examples/`.
- Finished PDFs and Markdown notes in `Reference_documentation/`.
- Top-level metadata: `Project.toml`, `Manifest.toml`, `README.md`,
  `CHANGELOG.md`, `LICENSE`, `.gitignore`, `.gitattributes`.

If a change needs a heavy input deck, a reference solver, or a generated run
output, the file goes in the private development workspace, not here.

## Branch And Commit Conventions

- Branch names: `feature/<short-name>`, `fix/<short-name>`, `docs/<short-name>`.
- Commit messages: one-line subject in the imperative mood (e.g. "Add CQUAD4
  geomnormal frame"), followed by an optional body explaining *why*.
- Keep commits focused; do not bundle unrelated refactors with feature work.

## Code Standards

- Julia 1.12 is the supported runtime; do not depend on nightly features.
- Match the surrounding style; no auto-formatter is enforced.
- Prefer typed `Dict{Symbol,Any}` payloads at module boundaries so payloads
  round-trip through JSON without surprise.
- New solver kernels must keep behavior on existing solution sequences
  unchanged; add a gate rather than rewriting a shared code path.

## Adding A Validation Case

1. Land the deck in the private workspace under `VALIDATION_FILES/`.
2. Add a row to the private `VALIDATION_CASE_REGISTRY.csv`.
3. Record at least one timestamped run under `RUN_OUTPUTS/` with a
   `RUN_REPORT.md` describing inputs, reference values, and tolerances.
4. Only after the case is stable, distill a public-facing summary into the
   `Reference_documentation/` (Markdown or PDF) if it documents an exposed
   capability.

## Documentation Changes

LaTeX sources are kept in the private development workspace, not in this
repository. To update a PDF:

1. Edit the `.tex` file under
   `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/DOCUMENTS_IN_PROGRESS/OPENJFEM_REFERENCE_DOCS/`.
2. Rebuild with the folder's `build.ps1` or with `build_all.ps1`.
3. Copy the reviewed PDF into
   `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/PUBLIC_PDFS/`.
4. Run the private document publisher to update `Reference_documentation/`.
5. Add a `Reference_documentation/` line to `CHANGELOG.md` under `[Unreleased]`.

## Releasing

1. Bump `version` in `Project.toml`.
2. Move the `[Unreleased]` section in `CHANGELOG.md` under the new version
   with the release date.
3. Tag the commit `vX.Y.Z`.

## Reporting Issues

When filing a bug, include:

- Julia version and OS.
- The minimal input deck that triggers the issue (anonymized if needed).
- The full command line and console output.
- What you expected vs. what happened.
