# JFEM on Windows

## Install once

1. Install **Julia 1.13.1 (64-bit)** from [Julia downloads](https://julialang.org/downloads/manual-downloads/).
   **Tick Add Julia to PATH**, then reopen any terminal/File Explorer window.
2. Download the complete JFEM ZIP from GitHub and choose **Extract All**. Keep
   the entire extracted folder together in a writable location.
3. Open `__Start here!__/Windows` and double-click **setup.cmd**.
   Stay connected to the internet. It installs the shared packages and builds
   one shared image for JFEM, Boxer, PANDEATOR and their workers.
4. Wait for successful completion. The first image build can take an hour or
   longer, including quiet periods during machine-code generation. Keep the
   window open. Later setup runs reuse a current image.

![Download Julia for your operating system](../../utils/images/julia-download.png)

## Launch an app

Double-click a launcher in this Windows folder:

| File | Opens |
| --- | --- |
| **JFEM-Boxer.cmd** | Lifting-surface modeling, FE analysis, sensitivity and results. |
| **PANDEATOR.cmd** | Stiffened-panel modeling and analysis. |
| **Results-viewer.cmd** | Existing `.jfem` results through a lightweight local server; WebGPU preferred. |
| **JFEM-solver.cmd** | A deck chooser. Dropping a `.bdf`, `.dat` or `.nas` file also works. |

The app-owned launchers are also available in `APPS/<app>/Windows/`. Keep the
Boxer/PANDEATOR/results-viewer console open while using its browser page. Close the app or
press **Ctrl+C** in that console when finished.

The results-viewer server loads only browser assets, not the FE solver. If Julia
is unavailable, its launcher opens the offline WebGL viewer directly. You can
also open `APPS/JFEM_results_viewer/postv11.html` directly for this fallback.

To try the solver, choose `utils/examples/precompile/sol101_quad_static.bdf`.
The console reports the output location. In Results viewer, use **Struct /
Choose File** for Model A and open the resulting `.jfem` file.

Commands below assume PowerShell opened in this Windows folder.

## Repair and updates

- **Julia not found:** put the tested Julia executable on PATH and reopen the
  terminal or launcher. `JFEM_JULIA` can name its full executable path without flags.
- **Download failure:** restore network/proxy access and rerun setup; completed
  downloads are reused. Keep the error text if it fails again.
- **Image missing or stale:** rerun setup after source, Julia, package or folder
  changes. Launchers check the image receipt before loading it. Do not force an
  old image with `-J`.
- **Image build runs out of memory:** close other applications and use
  `.\setup.cmd --sysimage-threads=1`. `.\setup.cmd --no-sysimage` explicitly skips the image;
  normal source loading remains available and may compile on first use.
- **Browser cannot connect:** wait for the console's ready message, then open
  its printed local address. Keep that console open while using the app.

`.\setup.cmd --dry-run` shows the setup plan. Build concurrency defaults to two threads;
this does not limit normal analysis threads. Do not delete your studies or decks
to repair an installation. See the [solver reference](../../utils/julia_tools/README.md)
for batch commands and representative precompile workloads.

The generated image (`sysimage/OpenJFEM_sysimage.dll` on Windows, `.so` on
Linux or `.dylib` on macOS) is local installation output. It is not included
in GitHub: it depends on the operating system, Julia version, CPU and source
revision. Setup builds it for this computer and launchers check its receipt.

## Offline use

1. On a connected computer with the same OS, architecture and Julia release,
   complete normal setup for this checkout.
2. Copy the complete repository and Julia depot to the offline computer.
   The default depot is `%USERPROFILE%\.julia`; copy the depot named by
   `JULIA_DEPOT_PATH` instead if you set that variable.
3. Install the matching Julia runtime and put it on PATH. Run
   `.\setup.cmd --offline` on the target computer. This uses cached packages and native
   artifacts and rebuilds the image when its machine/location receipt differs.
4. If a package or artifact is missing, repeat setup on the connected computer
   and refresh the copied depot. Keep the pinned Manifest unchanged.

Boxer, PANDEATOR and the results viewer use bundled Babylon.js and browser
libraries, with no CDN downloads or pre-existing browser cache needed. Setup
includes the WebGPU shader compilers. The renderer prefers WebGPU and falls
back to WebGL if needed, reporting the active backend and fallback reason. Setup
verifies their files and checksums, including with `--boxer-only`. Keep the
complete repository together. If setup reports a missing or changed browser
asset, extract a fresh complete copy of the same release; do not copy individual
library files from another release.

Opening local models, solving them and reading `.jfem` results work offline
after Julia setup. Downloading new UIUC airfoils requires internet; locally
imported airfoils and profiles embedded in saved Studies work offline.
Julia packages and images are platform-specific; a cache from another operating
system is not sufficient.

[Illustrated PDF](../jfem_2026_installation_guide.pdf) · [Choose another OS](../README.md)
