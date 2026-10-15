# JFEM applications

Install once using **setup.cmd** in the repository root. It installs the packages
and creates the shared sysimage automatically. Then double-click a launcher:

| Application | Root launcher | App folder |
| --- | --- | --- |
| JFEM-Boxer: lifting-surface modeling, analysis and sensitivity | `JFEM-Boxer.cmd` | `JFEM-Boxer/` |
| PANDEATOR: stiffened-panel modeling and analysis | `PANDEATOR.cmd` | `PANDEATOR_APP/` |
| Results viewer: open an existing `.jfem` file | `Results-viewer.cmd` | `JFEM_results_viewer/` |
| Standalone solver: choose or drop an input deck | `JFEM-solver.cmd` | Shared solver in `../src/` |

[Installation walkthrough](<../__Start here!__/README.md>) |
[JFEM-Boxer guide](JFEM-Boxer/README.md) |
[PANDEATOR guide](PANDEATOR_APP/PANEL_APP_README.md) |
[Results-viewer controls](JFEM_results_viewer/POST_GUIDE.html)

![JFEM-Boxer model](<../utils/images/fgen-model.png>)

Keep the full `APPS/` tree together. The two result viewers share `jfem_binary.js`,
including static-preload and buckling-mode output support. JFEM-Boxer and PANDEATOR
use local Julia servers; the static viewer needs no Julia process or CDN.
