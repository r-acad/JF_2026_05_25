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
| **JFEM solver** | Choose a bulk-data deck and run it directly. |

![JFEM-Boxer displaying a lifting-surface model](<__Start here!__/images/fgen-model.png>)

## Guides and solver reference

- [Illustrated installation PDF](<__Start here!__/jfem_2026_installation_guide.pdf>)
- [JFEM-Boxer user guide](Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf)
- [Solver commands, exports and automation](<__Start here!__/julia_tools/README.md>)
- [Solver capabilities](general_description.md), [apps](APPS/README.md) and [documentation index](Reference_documentation/README.md)

## Validation

The [reproducible validation suite](validation/README.md) contains published
benchmark models, references and explicit tolerances. Seventeen scalar rows
have reference parity targets; two coarse-mesh analytical discrepancies remain
documented. Reference agreement on a given mesh does not establish mesh-converged
accuracy. See [automated tests](test/README.md) to verify a checkout.

## Contribute

Contributions are not accepted yet. The project is evolving quickly and is
still immature; interfaces and workflows may change. See
[the contribution policy](CONTRIBUTING.md).
