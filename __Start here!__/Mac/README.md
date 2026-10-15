# JFEM on macOS

## Install once

1. Install **Julia 1.13.1** for your Mac's processor architecture from
   [Julia downloads](https://julialang.org/downloads/manual-downloads/). Make
   `julia` available on PATH and confirm `julia --version` in a new Terminal.
2. Download and extract the complete repository to a writable directory.
3. Open `__Start here!__/Mac` and double-click **setup.command**. If the ZIP
   did not retain executable permissions, open Terminal in that folder and run:

   ```bash
   chmod +x ./*.command
   bash setup.command
   ```

Stay online until setup succeeds. It installs one root package environment and
builds one shared image for JFEM, Boxer, PANDEATOR and workers. The first build
can take an hour or longer and can be quiet during code generation. Keep the
Terminal window open; later setup runs reuse a current image.

## Launch an app

Double-click a launcher in this Mac folder, or run it with `bash` in Terminal:

| File | Opens |
| --- | --- |
| **JFEM-Boxer.command** | Lifting-surface modeling and analysis. |
| **PANDEATOR.command** | Stiffened-panel modeling and analysis. |
| **Results-viewer.command** | Existing `.jfem` results in the default browser. |
| **JFEM-solver.command** | A deck chooser for standalone JFEM. |

You can pass a deck directly: `bash JFEM-solver.command '/path/to/model.bdf'`.
Root launchers remain available. Keep the Boxer/PANDEATOR Terminal open while
using the local browser app; press **Ctrl+C** there to stop it.
The viewer can also open `APPS/JFEM_results_viewer/postv11.html` directly.

Commands below assume Terminal opened in this Mac folder.

## Repair and updates

- **Julia not found:** put the tested Julia executable on PATH and reopen the
  terminal or launcher. `JFEM_JULIA` can name its full executable path without flags.
- **Download failure:** restore network/proxy access and rerun setup; completed
  downloads are reused. Keep the error text if it fails again.
- **Image missing or stale:** rerun setup after source, Julia, package or folder
  changes. Launchers check the image receipt before loading it. Do not force an
  old image with `-J`.
- **Image build runs out of memory:** close other applications and use
  `bash setup.command --sysimage-threads=1`. `bash setup.command --no-sysimage` explicitly skips the image;
  normal source loading remains available and may compile on first use.
- **Browser cannot connect:** wait for the console's ready message, then open
  its printed local address. Keep that console open while using the app.

`bash setup.command --dry-run` shows the setup plan. Build concurrency defaults to two threads;
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
   The default depot is `~/.julia`; copy the depot named by
   `JULIA_DEPOT_PATH` instead if you set that variable.
3. Install the matching Julia runtime and put it on PATH. Run
   `bash setup.command --offline` on the target computer. This uses cached packages and native
   artifacts and rebuilds the image when its machine/location receipt differs.
4. If a package or artifact is missing, repeat setup on the connected computer
   and refresh the copied depot. Keep the pinned Manifest unchanged.

The results viewer opens existing `.jfem` files offline using bundled assets.
Julia packages and images are platform-specific; a cache from another operating
system is not sufficient.

[Illustrated PDF](../jfem_2026_installation_guide.pdf) · [Choose another OS](../README.md)
