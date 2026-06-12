# OpenJFEM Reference Documentation

This folder is the curated public documentation drop. It contains finished
documents selected from private sources kept outside the public repository,
plus a small set of Markdown notes that complement the source code.

Documents in this folder are published from the private public-ready drop:
`02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/PUBLIC_PDFS/`.
Place only reviewed `.pdf`/`.pptx` files there, then run
`02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/publish_reference_documents.ps1`.
Use `-Prune` when this public folder should remove files that are no longer in
`PUBLIC_PDFS/`.

## PDF Documents

### Canonical OpenJFEM Documentation

| File | Purpose | Audience |
| --- | --- | --- |
| `jfem_2026_architecture_manuscript.pdf` | Long-form technical manuscript covering the parse/solve/export workflow, supported SOL families, the adjoint infrastructure, and the validation harness. | Developers, researchers extending the solver. |
| `jfem_2026_shell_paper.pdf` | Companion paper focused on the shell-element formulation, material handling (`MAT1`/`MAT2`/`MAT8`/`PCOMP`), and the internal gates that select each kernel. | Researchers, FEM specialists. |
| `jfem_2026_architecture_and_shell_presentation.pdf` | Beamer slide deck that summarizes the architecture and shell formulation; companion to the two papers above. | Talks, review meetings, onboarding. |
| `jfem_user_reference_guide.pdf` | How to launch the solver on Windows and Linux, options, output formats, batch runs, sysimage generation, first-time user notes. | End users running the solver. |

### Talks And Pitches

| File | Purpose | Audience |
| --- | --- | --- |
| `jfem_openludwig_overview.pdf` | External overview of the JFEM structural solver and the OpenLUDWIG CFD solver. | Technical reviewers, partner labs. |
| `agentic_coding_lessons.pdf` | Lessons, tips, psychology, costs, and ways of working in agentic AI-assisted software development. | Small companies transitioning to agentic workflows. |
| `gpu_workstation_pitch.pdf` | Business case for a ~15000 EUR GPU workstation: evidence from current results, options, and ROI. | Management / decision-maker. |

## Markdown Notes

| File | Purpose |
| --- | --- |
| `case_submission_methods.md` | The supported ways to submit a case to OpenJFEM (single deck, batch, JSON manifest, JSONL worker). |
| `hdf5_export.md` | Layout of the aggregated and per-solution HDF5 outputs. |
| `tacs_core_capability_matrix.md` | Current JFEM-core TACS formulation/sensitivity coverage and the implementation order for missing core capabilities. |

## How These Documents Are Built

LaTeX sources are kept in the private development workspace under
`02_PROJECT_DEVELOPMENT/02.5_PROJECT_DOCUMENTS/DOCUMENTS_IN_PROGRESS/` to avoid shipping source material or build byproducts
(`.aux`, `.log`, `.fdb_latexmk`, etc.) to end users. Build documents privately,
then copy reviewed finished files into `PUBLIC_PDFS/` and publish them with
the private script.
