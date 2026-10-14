# Advanced setup and sysimages

For a first installation, follow the [numbered walkthrough](INSTALLATION.md) or
[illustrated PDF](jfem_2026_installation_guide.pdf). This page covers runtime
selection, setup switches, optional sysimages and repair.

## Runtime and project selection

This checkout records and is tested with Julia **1.13.1** in both manifests.
Setup accepts later patches in the same minor release and checks compatibility
before installation. It does not change Juliaup defaults, the global Julia
environment, startup files or persistent depot settings. The Project/Manifest
files define the packages; no manual package list is needed.

If Juliaup already manages your Julia installation, add the recorded release
line and run setup with it explicitly:

```text
juliaup add 1.13
julia +1.13 --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl
```

This leaves your existing Juliaup default unchanged. The `+1.13` syntax is for
Juliaup; a standalone Julia installation uses its executable directly.
Root/PANDEATOR launchers accept `JFEM_JULIA`, and FGen launchers accept
`WINGFEGEN_JULIA`. Supply an executable path without extra flags.

For Juliaup installation, use the [official instructions](https://docs.julialang.org/en/v1/manual/installation/).
Windows PowerShell:

```powershell
winget install --name Julia --id 9NJNWW8PVKMN -e -s msstore
```

macOS/Linux:

```bash
curl -fsSL https://install.julialang.org | sh
```

Reopen the terminal after installing Julia. A standalone installer is also
available on the [manual downloads page](https://julialang.org/downloads/manual-downloads/).
Use the checkout's recorded Julia release line rather than changing manifests
to force a different minor release to work.

## What normal setup checks

Run `.\setup.cmd` on Windows or `bash setup.sh` on macOS/Linux from the repository
root. Setup installs the root JFEM and separate WingFEGen environments, explicitly
precompiles packages and verifies:

- the JFEM solver module;
- the FGen module;
- PANDEATOR's server and HTML/health/browser-asset routes, without starting a user server or solving a model;
- the static viewer's local files.

PANDEATOR shares the root environment. The static viewer has no Julia packages.
First-launch paths can install missing package sources automatically; explicit
setup also repairs missing artifacts. `JFEM_AUTO_INSTALL=0` requires explicit
setup instead. Downloads require network access or a populated matching cache.

## Setup options

Use `.\setup.cmd --help`, `bash setup.sh --help`, or the Julia helper with `--help` for the current options. `WingFEGen/setup.cmd`, `setup.sh` and `setup.jl` delegate to the same setup.

| Option | Effect |
|---|---|
| `--dry-run` | Validate and print the plan without installing or creating an image. |
| `--no-precompile --no-verify` | Install without explicit precompilation or module/asset verification. Later imports still compile; this does not prove the apps load. |
| `--solver-only` | Prepare the root project and associated tools; omit the separate FGen project. |
| `--wingfegen-only` | Prepare FGen only; not a complete solver-backed installation. Cannot combine with `--sysimage`. |
| `--wingfegen-project=PATH` | Select another FGen project folder. |
| `--offline` | Use a populated matching cache; cannot bootstrap an empty offline machine. |
| `--update-registry` | Refresh registries before installation; ignored in offline mode. |
| `--sysimage` | After setup, build the standard local solver/PANDEATOR image. |
| `--sysimage=PATH` | Build at a custom path. Automatic launchers still search their standard path. |
| `--sysimage-threads=N` | Set the build child's Julia threads; `auto` uses automatic selection. This is not a memory limit. |
| `--deck PATH` / `--manifest PATH` | Supply representative image workloads; requires `--sysimage`. |
| `--flags VALUE` | Pass `FLAG=value,...` workload settings; requires `--sysimage`. |

`--no-precompile` alone does not stop verification imports from compiling. Neither `--no-precompile` nor `--no-verify` cancels an explicitly requested image build. Omit `--sysimage` for dependency installation only.

## Build an optional sysimage

A sysimage stores loaded packages and selected compiled methods to reduce repeated startup/first-use compilation. It does not replace Julia or the checkout, and it does not guarantee zero compilation for every model. Embedded package versions are fixed at build time. [PackageCompiler sysimages](https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html).

This image covers **OpenJFEM and the PANDEATOR server stack/workload**. Eligible native solver processes launched by FGen can also use it. **It does not compile the FGen application server or all FGen geometry/UI paths.** The static viewer does not use a Julia image.

1. Stop your own solver/server processes before replacing an image they may have loaded. Keep source and representative decks unchanged during the build.
2. Use the same compatible Julia executable that will run the apps.
3. Run `.\setup.cmd --sysimage` or `bash setup.sh --sysimage`. Portable equivalent:

```text
julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl --sysimage
```

4. Wait for package setup, workload compilation, image creation and the provenance receipt. Read workload warnings. The build can use substantial CPU/RAM and several minutes; it executes representative decks to compile their methods.
5. Check the image and adjacent receipt, then verify it and run the [tiny example](INSTALLATION.md#6-try-the-standalone-solver-optional).

If the optional build fails after dependency setup succeeds, setup returns exit
status **2** and prints a separate build error. The applications remain usable
without an image; correct the build problem before retrying `--sysimage`.

| Platform | Standard image | Adjacent receipt |
|---|---|---|
| Windows | `sysimage/OpenJFEM_sysimage.dll` | `OpenJFEM_sysimage.dll.jfem.toml` |
| Linux | `sysimage/OpenJFEM_sysimage.so` | `OpenJFEM_sysimage.so.jfem.toml` |
| macOS | `sysimage/OpenJFEM_sysimage.dylib` | `OpenJFEM_sysimage.dylib.jfem.toml` |

PackageCompiler requires a C compiler. It automatically provides one on Windows when needed. macOS needs an appropriate clang toolchain such as Xcode Command Line Tools; Linux needs a current gcc or clang. Use official Julia binaries. [PackageCompiler prerequisites](https://julialang.github.io/PackageCompiler.jl/stable/).

### Existing click-to-build entry points

These delegate to the unified setup with `--sysimage`:

```text
JFEM_installation/CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd
JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command
JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
```

Double-click the platform file, or invoke the Linux/macOS script with `bash`. Workload arguments such as `--deck` and `--manifest` are forwarded. Prefer root setup for a reproducible terminal transcript.

## Verify, use and rebuild the image

From the root, on Windows:

```powershell
julia --startup-file=no --project=. JFEM_installation/julia_tools/check_sysimage.jl . sysimage/OpenJFEM_sysimage.dll
```

Use `.so` on Linux or `.dylib` on macOS. A zero exit code means eligibility for automatic use; success is silent. A nonzero code prints a reason and says normal package loading will be used.

`jfem.cmd`/`jfem` and PANDEATOR wrappers select the standard image only after its receipt matches. FGen's eligible native solver runs check it too. Repeat the [first tiny solve](INSTALLATION.md#6-try-the-standalone-solver-optional) to verify actual operation. An image build alone does not validate a user's model or every solver feature.

The receipt checks exact Julia/runtime/CPU identity, checkout location, source/project inputs, image hash and representative workload. A moved checkout, changed source/manifest, changed or missing build deck, missing receipt or changed image triggers fallback. This is an eligibility check, not an audit of arbitrary package-depot edits or native system libraries.

**Rebuild after:** Julia upgrades (including patches), project/dependency/code changes, checkout moves, machine/OS/CPU changes, or changed/removed representative decks. Stop your own affected runs, update the full checkout, rerun setup with `--sysimage`, check the new receipt and repeat the tiny solve. Package setup can accept a newer Julia patch while an old image still requires rebuilding for that exact runtime.

**Run without an image:** start fresh Julia without `-J`/`--sysimage`:

```text
julia --startup-file=no --project=. JFEM_installation/julia_tools/run_bdf.jl JFEM_installation/examples/precompile/sol101_quad_static.bdf output/source_smoke
```

Alternatively, move the optional image and receipt together into an archive outside the standard path while no process uses them. Wrappers then load ordinary packages. Do not force a stale image with `-J`: direct loading bypasses automatic provenance checks and may load old compiled code.

## Advanced workload and direct build example

Unified setup invokes the existing `JFEM_installation/julia_tools/deploy_fast.jl`. With no workload arguments, it uses tiny bundled decks in `JFEM_installation/examples/precompile`. Add a small representative deck:

```text
julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl --sysimage --deck path/to/representative.bdf --sysimage-threads=4
```

Repeat `--deck` for multiple decks. `--manifest path/to/cases.json` reads a JSON `cases` array whose entries supply `input` (or `deck`), relative to the JSON file. `--flags "NAME=value,OTHER=value"` changes workload flags. These options require `--sysimage` in unified setup. Keep build inputs at stable paths: their locations and hashes are recorded. A representative workload improves coverage, not every possible future analysis.

After unified setup, experienced users can invoke the original builder directly. Windows:

```powershell
julia --threads=auto --startup-file=no --project=. JFEM_installation/julia_tools/deploy_fast.jl --sysimage=sysimage/OpenJFEM_sysimage.dll
```

Use `.so` on Linux or `.dylib` on macOS. The current project already declares PackageCompiler; no extra package-install option is needed. The legacy `--install-packagecompiler` option is only for an older project where it is absent and may change dependency files. Direct `deploy_fast.jl` is not complete all-app setup. Without `--sysimage=...` it refreshes package/workload precompilation but creates no image.

A custom image is not automatically discovered. Prefer the standard location. For deliberate direct use, first run `check_sysimage.jl . PATH`, require exit code zero, then pass `--sysimage=PATH` to the intended Julia process with the root project. Do not attach this solver image indiscriminately to the separate FGen server project.

## Repair, updates and offline use

- **Interrupted installation:** rerun setup; downloaded content is reused.
- **Julia missing/wrong minor release:** reopen the terminal, check its version and select the matching runtime. Do not edit manifests to bypass compatibility.
- **Network/proxy/certificate failure:** retain the error, correct access to package servers and artifacts, then retry. Do not disable certificate checks.
- **Access denied:** use a writable user folder. Stop your own process using an image before replacing it.
- **Image build failure:** check compiler/artifact availability, build logs and memory. A smaller `--sysimage-threads` may help; it is not a memory cap. Ordinary setup/source-mode execution remains available.
- **Image skipped:** read `runtime_changed`, `project_changed`, `project_moved`, `workload_changed`, or the reported reason, then rebuild if needed. Do not borrow an image from another machine.
- **Browser connection refused:** wait for readiness and use the printed URL. FGen/PANDEATOR have different ports and different no-browser switches.
- **Static viewer blank:** retain the complete `POST` tree, check browser/WebGL support and load an actual `.jfem` result. Report/JSON-only output has no viewer binary.
- **Update:** stop active runs, update the whole checkout (`git pull` or a new ZIP), retain Studies/results, rerun setup and rebuild an image whose receipt no longer matches.
- **Offline:** populate a complete package/artifact cache on a connected machine with matching Julia, OS and architecture, transfer it deliberately, then use `--offline`. An empty cache cannot install offline. A temporary `JULIA_DEPOT_PATH` selects an isolated cache. See [offline notes](OFFLINE_DEPENDENCIES.md); current manifests, not historical package tables, define the environment.

Further reading: [installation PDF](jfem_2026_installation_guide.pdf), [FGen user guide](../Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf), [PANDEATOR](../POST/PANDEATOR_APP/PANEL_APP_README.md), [result viewer controls](../POST/JFEM_results_viewer/POST_GUIDE.html).
