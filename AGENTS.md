# Agent Rules For The Public OpenJFEM Repository

This directory is the only GitHub-published repository in the workspace.

Canonical path:

```text
01_PROJECT_FOLDER/JFEM/
```

Until the old wrapper is physically removable, this path may be a junction to
`01_PROJECT_FOLDER/JFEM_GitHub_repo/JFEM/`. Agents should still treat
`01_PROJECT_FOLDER/JFEM/` as the public repo root.

## Public Boundary

Keep this repository public-safe:

- Source code, package metadata, public examples, public tests, and curated
  public validation cases are allowed.
- Private validation decks, solver outputs, external papers, LaTeX sources,
  commercial solver artifacts, and campaign notes are not allowed here.
- Public validation material is curated through
  `validation/public_suite.yaml` and the private manifest
  `00_AGENTIC_DEVELOPMENT/MANIFESTS/public_validation_cases.json`.
- Reference documentation is curated through
  `03_PRIVATE_DOCUMENTS/MANIFESTS/published_documents.json`; do not copy
  private PDFs or document sources here by hand.

## Git

Run `git status`, `git add`, `git commit`, and `git push` from this directory
only. Do not initialize Git in the workspace root or private directories.

Before pushing:

- Check `CHANGELOG.md` has an `[Unreleased]` entry for code or documentation
  changes.
- Make sure public validation/docs are listed in their manifests.
- Do not stage private paths from `02_PRIVATE_VALIDATION/`,
  `03_PRIVATE_DOCUMENTS/`, or `04_EXTERNAL_TOOLS/`.
