# OpenJFEM

JFEM is a Julia finite-element solver for static, modal, buckling and nonlinear
structural analysis. The repository includes **JFEM-Boxer**, **PANDEATOR** and a
browser **results viewer**.

## Install and launch

Download the complete repository with **Code / Download ZIP** and extract it.
Open `__Start here!__`, then choose your operating system:

| Operating system | Instructions and launchers |
| --- | --- |
| Windows | [Windows](<__Start here!__/Windows/README.md>) |
| Linux | [Linux](<__Start here!__/Linux/README.md>) |
| macOS | [Mac](<__Start here!__/Mac/README.md>) |

Each folder has one setup launcher and the application launchers. Setup installs
the packages and automatically builds one shared Julia image for the solver,
apps and workers. The first build can take an hour or longer. Keep its console
open until it finishes; native code generation can have long quiet periods.
The existing root launchers remain available.

| Application | Purpose |
| --- | --- |
| **JFEM-Boxer** | Build lifting-surface models, define loads, run FE and sensitivity analyses, and inspect results. |
| **PANDEATOR** | Generate and analyse stiffened panels. |
| **Results viewer** | Open existing `.jfem` results without a server. |
| **JFEM solver** | Run a Reference deck or a supported Abaqus input directly. |

![JFEM-Boxer displaying a lifting-surface model](<utils/images/fgen-model.png>)

**Project / Read Abaqus** in Boxer opens local `.inp` or `.inp.gz` meshes
and supported static/modal analyses. Inspect named sets and diagnostics, or
explicitly add material, constraints and loads to a mesh-only solid model.
See [Abaqus import and its supported subset](APPS/JFEM-Boxer/README.md#read-an-abaqus-input)
for the workflow and a [JuliaFEM/FEModels](https://github.com/JuliaFEM/FEModels)
example. Boxer renders solid surfaces and preserves all ten nodes of quadratic
tetrahedra, including when opening current `.jfem` result files.

Supporting decks, images, automation helpers and solver regression tests are grouped
in [`utils/`](utils/README.md). Generated Julia images in `sysimage/` stay local;
setup builds the appropriate image on each computer.

## Guides and solver reference

- [Illustrated installation PDF](<__Start here!__/jfem_2026_installation_guide.pdf>)
- [JFEM-Boxer user guide](Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf)
- [Solver commands, exports and automation](<utils/julia_tools/README.md>)
- [Solver capabilities](general_description.md), [apps](APPS/README.md) and [documentation index](Reference_documentation/README.md)

## Validation

The [illustrated validation collection](validation/README.md) contains 18 case
folders with models, recorded results, two-page cards and explicit tolerances.
Its default check compares 44 quantities; coarse-mesh failures and historical
regression targets remain identified. See the [results summary](validation/VALIDATION_SUMMARY.md)
and [automated tests](utils/test/README.md) to verify a checkout.

## Contribute

Contributions are not accepted yet. The project is evolving quickly and is
still immature; interfaces and workflows may change. See
[the contribution policy](CONTRIBUTING.md).
