# JFEM on Linux

## Install once

1. Install **Julia 1.13.1** for your processor architecture from
   [Julia downloads](https://julialang.org/downloads/manual-downloads/) and make
   `julia` available on PATH. Check with `julia --version` in a new terminal.
2. Download and extract the complete repository to a writable directory.
3. Open a terminal in `__Start here!__/Linux` and run:

   ```bash
   bash setup.sh
   ```

Stay online until setup succeeds. It installs one root package environment and
builds one shared image for JFEM, Boxer, PANDEATOR and workers. The first build
can take an hour or longer and can be quiet during code generation. Keep the
terminal open; later setup runs reuse a current image.

## Launch an app

From this Linux folder, run the matching command:

| Command | Opens |
| --- | --- |
| `bash JFEM-Boxer.sh` | Lifting-surface modeling and analysis. |
| `bash PANDEATOR.sh` | Stiffened-panel modeling and analysis. |
| `bash Results-viewer.sh` | Existing `.jfem` results in the default browser. |
| `bash JFEM-solver.sh` | A deck chooser, or a terminal prompt if no dialog tool is available. |

You can pass a deck directly: `bash JFEM-solver.sh '/path/to/model.bdf'`.
Root launchers remain available. Keep the Boxer/PANDEATOR terminal open while
using the local browser app; press **Ctrl+C** there to stop it.
The viewer can also open `APPS/JFEM_results_viewer/postv11.html` directly.

Commands below assume a terminal opened in this Linux folder.

## Repair and updates

- **Julia not found:** put the tested Julia executable on PATH and reopen the
  terminal or launcher. `JFEM_JULIA` can name its full executable path without flags.
- **Download failure:** restore network/proxy access and rerun setup; completed
  downloads are reused. Keep the error text if it fails again.
- **Image missing or stale:** rerun setup after source, Julia, package or folder
  changes. Launchers check the image receipt before loading it. Do not force an
  old image with `-J`.
- **Image build runs out of memory:** close other applications and use
  `bash setup.sh --sysimage-threads=1`. `bash setup.sh --no-sysimage` explicitly skips the image;
  normal source loading remains available and may compile on first use.
- **Browser cannot connect:** wait for the console's ready message, then open
  its printed local address. Keep that console open while using the app.

`bash setup.sh --dry-run` shows the setup plan. Build concurrency defaults to two threads;
this does not limit normal analysis threads. Do not delete your studies or decks
to repair an installation. See the [solver reference](../julia_tools/README.md)
for batch commands and representative precompile workloads.

## Offline use

1. On a connected computer with the same OS, architecture and Julia release,
   complete normal setup for this checkout.
2. Copy the complete repository and Julia depot to the offline computer.
   The default depot is `~/.julia`; copy the depot named by
   `JULIA_DEPOT_PATH` instead if you set that variable.
3. Install the matching Julia runtime and put it on PATH. Run
   `bash setup.sh --offline` on the target computer. This uses cached packages and native
   artifacts and rebuilds the image when its machine/location receipt differs.
4. If a package or artifact is missing, repeat setup on the connected computer
   and refresh the copied depot. Keep the pinned Manifest unchanged.

The results viewer opens existing `.jfem` files offline using bundled assets.
Julia packages and images are platform-specific; a cache from another operating
system is not sufficient.

[Illustrated PDF](../jfem_2026_installation_guide.pdf) · [Choose another OS](../README.md)
