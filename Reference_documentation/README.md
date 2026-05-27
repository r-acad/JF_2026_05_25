# OpenJFEM Reference Documentation

This folder is the public documentation drop. It contains the finished PDFs
generated from LaTeX sources kept outside the public repository, plus a small
set of Markdown notes that complement the source code.

## PDF Documents

| File | Purpose | Audience |
| --- | --- | --- |
| `jfem_2026_architecture_manuscript.pdf` | Long-form technical manuscript covering the parse/solve/export workflow, supported SOL families, the adjoint infrastructure, and the validation harness. | Developers, researchers extending the solver. |
| `jfem_2026_shell_paper.pdf` | Companion paper focused on the shell-element formulation, material handling (`MAT1`/`MAT2`/`MAT8`/`PCOMP`), and the internal gates that select each kernel. | Researchers, FEM specialists. |
| `jfem_2026_architecture_and_shell_presentation.pdf` | Beamer slide deck that summarizes the architecture and shell formulation; companion to the two papers above. | Talks, review meetings, onboarding. |
| `jfem_user_reference_guide.pdf` | How to launch the solver on Windows and Linux, options, output formats, batch runs, sysimage generation, first-time user notes. | End users running the solver. |

## Markdown Notes

| File | Purpose |
| --- | --- |
| `case_submission_methods.md` | The supported ways to submit a case to OpenJFEM (single deck, batch, JSON manifest, JSONL worker). |
| `hdf5_export.md` | Layout of the aggregated and per-solution HDF5 outputs. |

## How These Documents Are Built

LaTeX sources are kept in the private development workspace, not in this
repository, to avoid shipping build byproducts (`.aux`, `.log`, `.fdb_latexmk`,
etc.) to end users. Only the finished PDFs are published here. When a source
document is updated, rebuild the PDF and copy it into this folder, replacing
the previous version.
