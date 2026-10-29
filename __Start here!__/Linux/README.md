> **Fresh installation:** run `bash setup.sh` from the repository root first. For an already hydrated package environment, use [Already prepared Linux packages](#already-prepared-linux-packages) instead. All applications use the root `sysimage/`; this folder contains application shortcuts only.

# JFEM on Linux

## Install once

1. Install **Julia 1.13.1** for your processor architecture from
   [Julia downloads](https://julialang.org/downloads/manual-downloads/) and make
   `julia` available on PATH. Check with `julia --version` in a new terminal.
2. Download and extract the complete repository to a writable directory.
3. Open a terminal at the repository root and run:

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
| `bash Results-viewer.sh` | Existing `.jfem` results through a lightweight local server; WebGPU preferred. |
| `bash JFEM-solver.sh` | A deck chooser, or a terminal prompt if no dialog tool is available. |

You can pass a deck directly: `bash JFEM-solver.sh '/path/to/model.bdf'`.
The app-owned launchers are also available in `APPS/<app>/Linux/`. Keep the Boxer/PANDEATOR/results-viewer terminal open while
using the local browser app; press **Ctrl+C** there to stop it.
The results-viewer server loads only browser assets, not the FE solver. If Julia
is unavailable, the launcher opens the offline WebGL viewer directly. Opening
`APPS/JFEM_results_viewer/postv11.html` directly provides the same fallback.

Commands below assume a terminal opened in this Linux folder.

## Repair and updates

- **Julia not found:** put the tested Julia executable on PATH and reopen the
  terminal or launcher. `JFEM_JULIA` can name its full executable path without flags.
- **Download failure:** restore network/proxy access and rerun setup; completed
  downloads are reused. Keep the error text if it fails again.
- **Image missing or stale:** rebuild with the prepared-environment command
  documented below if using that workflow; otherwise rerun setup after source, Julia,
  package or folder changes. Launchers check the image receipt before loading it. Do not force an
  old image with `-J`.
- **Image build runs out of memory:** close other applications and use
  `bash setup.sh --sysimage-threads=1`. `bash setup.sh --no-sysimage` explicitly skips the image;
  normal source loading remains available and may compile on first use.
- **Browser cannot connect:** wait for the console's ready message, then open
  its printed local address. Keep that console open while using the app.

`bash setup.sh --dry-run` shows the setup plan. Build concurrency defaults to two threads;
this does not limit normal analysis threads. Do not delete your studies or decks
to repair an installation. See the [solver reference](../../utils/julia_tools/README.md)
for batch commands and representative precompile workloads.

The generated image (`sysimage/OpenJFEM_sysimage.dll` on Windows, `.so` on
Linux or `.dylib` on macOS) is local installation output. It is not included
in GitHub: it depends on the operating system, Julia version, CPU and source
revision. Setup builds it for this computer and launchers check its receipt.

## Already prepared Linux packages

Use this path when the Linux machine is disconnected and already has a working
Julia runtime, a hydrated Linux depot and the prepared Project/Manifest that
matches its cached versions. Download the complete current repository on a
connected computer (Windows is fine for downloading/copying the source) and
copy it into the Linux repository directory. Keep the prepared package records
and depot in place. The earlier two-file source-runner update alone does not
include all image-building helpers.

Open a Bash terminal at the repository root and set your existing locations:

```bash
export JFEM_PACKAGE_ENV=/path/to/prepared/project
export JULIA_DEPOT_PATH=/path/to/depot
```

`JFEM_PACKAGE_ENV` contains `Project.toml` and `Manifest.toml`;
`JULIA_DEPOT_PATH` contains the cached package sources and native artifacts.
Do not copy the prepared project over the repository's own project metadata.
Use the matching Julia executable already installed on Linux. PackageCompiler
must be present in the prepared environment, and a compiler must be available:

```bash
command -v gcc || command -v clang
```

If your compiler has another executable name/path, set `JULIA_CC` to it.
Then check inputs and build the shared image:

```bash
julia --startup-file=no --threads=2 --project="$JFEM_PACKAGE_ENV" \
  utils/julia_tools/build_prepared_sysimage.jl --check-only

julia --startup-file=no --threads=2 --project="$JFEM_PACKAGE_ENV" \
  utils/julia_tools/build_prepared_sysimage.jl
```

This does not run the installer or fetch missing inputs. Missing package trees,
platform artifacts (including lazy artifacts) or a compiler produce an error
before compilation. `--check-only` performs the checks without compiling an
image. A separate build environment under `sysimage/builds/` preserves the
prepared dependency graph and adds the local solver/application packages;
both original Project/Manifest pairs remain intact. PackageCompiler still
performs its internal instantiate/precompile checks against the already
cached build environment and may create compiled caches.

The builder creates a candidate image, checks imports in a fresh Julia process,
and publishes `sysimage/OpenJFEM_sysimage.so` and its `.jfem.toml` receipt after
success. Keep `JFEM_PACKAGE_ENV` and `JULIA_DEPOT_PATH` set when launching the
normal app shortcuts. They load the image only while its source, environment,
preferences and runtime identity match. A missing or stale default image falls
back to source loading. Rebuild with the same command after source, package
metadata/preferences or Julia changes; this prepared workflow does not require
`bash setup.sh --offline`.

Use `--threads=1` on the Julia command if build memory is limited. Workload
options `--deck PATH` (repeatable), `--manifest PATH` and `--flags NAME=value,...`
and a custom `--sysimage=/absolute/path/image.so` are supported. See
[Existing prepared package environments](../../utils/julia_tools/README.md#existing-prepared-package-environments)
for details. The generated image is local Linux output, not part of GitHub.

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
