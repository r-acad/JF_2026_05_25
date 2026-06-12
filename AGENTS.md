# Agent Rules For The Public OpenJFEM Repository

This directory is the only GitHub-published repository in the workspace.

Canonical path:

```text
01_PUBLIC_PROJECT_REPOSITORY/JFEM/
```

The old `01_PROJECT_FOLDER/` and `JFEM_GitHub_repo/` wrappers have been
removed. Agents should treat this path as the public repo root.

## Public Boundary

Keep this repository public-safe:

- Source code, package metadata, public examples, public tests, and curated
  public validation cases are allowed.
- Private validation decks, solver outputs, external papers, LaTeX sources,
  commercial solver artifacts, and campaign notes are not allowed here.
- Public validation material is curated through
  `validation/public_suite.yaml` and the private manifest
  `02_PROJECT_DEVELOPMENT/02.1_AGENTIC_DEVELOPMENT/public_validation_cases.json`.
- Reference documentation is curated from reviewed `.pdf`/`.pptx` files staged
  in `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/PUBLIC_PDFS/`; do not copy
  private PDFs or document sources here by hand.

## Git

Run `git status`, `git add`, `git commit`, and `git push` from this directory
only. Do not initialize Git in the workspace root or private directories.

Before pushing:

- Check `CHANGELOG.md` has an `[Unreleased]` entry for code or documentation
  changes.
- Make sure public validation is listed in its manifest and public docs are
  staged in `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/PUBLIC_PDFS/`.
- Do not stage private paths from `02_PROJECT_DEVELOPMENT/02.3_PRIVATE VALIDATION/`,
  `02_PROJECT_DEVELOPMENT/02.2_CODE_DEVELOPMENT/`,
  `02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/`,
  `02_PROJECT_DEVELOPMENT/02.6_EXTERNAL_PAPERS/`, or
  `02_PROJECT_DEVELOPMENT/02.4_EXTERNAL_TOOLS/`.
