# OpenJFEM Reference Documentation

This folder is the public documentation drop. It contains the finished PDFs
generated from LaTeX sources kept outside the public repository, plus a small
set of Markdown notes that complement the source code.

PDFs in this folder are mirrored automatically from
`04_DOCUMENTATION_IN_WORK/` by `sync_pdfs_to_reference.ps1`. The mirror
includes every PDF the project produces - canonical OpenJFEM documentation,
external talks, and pitches.

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

## How These Documents Are Built

LaTeX sources are kept in the private development workspace at
`04_DOCUMENTATION_IN_WORK/` to avoid shipping build byproducts (`.aux`,
`.log`, `.fdb_latexmk`, etc.) to end users. Only the finished PDFs are
published here. When a source document is updated, run
`04_DOCUMENTATION_IN_WORK/build_all.ps1` (or any per-folder `build.ps1`);
the sync script then refreshes this folder automatically.
