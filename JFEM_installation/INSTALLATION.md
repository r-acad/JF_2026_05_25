# Install JFEM and its browser applications

One complete checkout supplies all four tools:

| Tool | Purpose | Environment |
|---|---|---|
| JFEM | Standalone finite element solver | Root Julia project |
| FGen / `WingFEGen` | Lifting-surface geometry, FEM generation, analysis and results | `WingFEGen` project; solver runs use the root project |
| PANDEATOR | Stiffened-panel case generation, analysis and results | Root Julia project; local Julia server |
| JFEM results viewer | Read existing `.jfem` results in a browser | Static HTML and bundled JavaScript; no Julia server |

Normal setup installs **two package environments and verifies all four entry points**. Keep the complete repository structure: browser tools share local assets. Normal use needs no private development folders, external reference solver, Python, Node.js or separately installed web server.

Printable guides: [installation and sysimages](../Reference_documentation/00_Getting_Started/jfem_2026_installation_guide.pdf) and [FGen user guide](../Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf).

## 1. Install Julia

This checkout records and is tested with **Julia 1.13.1** in both committed manifests. Setup accepts later patches in that minor release; it does not rewrite dependencies to force another minor release to work.

Windows, in PowerShell:

```powershell
winget install --name Julia --id 9NJNWW8PVKMN -e -s msstore
```

macOS/Linux, in a terminal:

```bash
curl -fsSL https://install.julialang.org | sh
```

These are the official Juliaup commands. If the Windows Store is unavailable, use the alternatives on the [official installation page](https://docs.julialang.org/en/v1/manual/installation/). Reopen the terminal and check `julia --version`. If another minor release is the default:

```text
juliaup add 1.13
julia +1.13 --version
```

The `+1.13` syntax is for Juliaup. A standalone Julia installation uses its executable directly. Setup and solver wrappers accept `JFEM_JULIA`; FGen also accepts `WINGFEGEN_JULIA`. These variables take an executable path, without extra flags. A working Juliaup default need not be changed.

## 2. Obtain the complete repository

With Git installed:

```text
git clone https://github.com/r-acad/JF_2026_05_25.git JFEM
cd JFEM
```

Or choose **Code > Download ZIP** on the [repository page](https://github.com/r-acad/JF_2026_05_25), extract the entire archive, and open a terminal in its root. Do not run inside the ZIP. Use a writable folder such as `C:\Work\JFEM` or `~/JFEM`.

The root contains `Project.toml`, `Manifest.toml`, `setup.cmd`, `setup.sh`, `src`, `JFEM_installation`, `WingFEGen` and `POST`. Keep FGen inside the checkout for solver discovery. Keep both `POST` app folders and their shared assets together.

## 3. Run the unified setup

From the repository root, choose one command:

| Platform | Normal setup | Setup and optional local sysimage |
|---|---|---|
| Windows PowerShell | `.\setup.cmd` | `.\setup.cmd --sysimage` |
| macOS/Linux | `bash setup.sh` | `bash setup.sh --sysimage` |

Portable equivalent:

```text
julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl
```

With explicit Juliaup runtime selection:

```text
julia +1.13 --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl
```

Setup instantiates both Project/Manifest environments, precompiles them, and verifies the JFEM module, FGen module, PANDEATOR server/health entry point and static-viewer assets. PANDEATOR verification does not start a user server or solve a model. The viewer has no separate Julia environment. Wait for the completion message and confirm all selected checks passed.

First downloads and compilation can take several minutes. Internet is needed for missing packages/artifacts. Packages normally use `~/.julia`. Normal setup changes neither the global Julia environment nor Juliaup defaults, startup files or persistent depot settings. The recorded project files remain authoritative. [Pkg environment documentation](https://pkgdocs.julialang.org/v1/environments/).

Without `--sysimage`, setup does not build an image or run a user analysis. With it, the later image build executes representative precompile decks (section 6).

## 4. Launch any application

### FGen

Windows:

```powershell
.\WingFEGen\run_fe_generator.cmd
```

Portable command:

```text
julia --startup-file=no --project=WingFEGen WingFEGen/run.jl
```

The default address is `http://127.0.0.1:8080`; use the printed URL. For another port and manual browser opening:

```text
julia --startup-file=no --project=WingFEGen WingFEGen/run.jl --port 9000 --no-browser
```

Keep the terminal open. Choose **Start new study** or **Read Reference** and follow the [FGen user guide](../Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf). Save Studies and retain their separate solver results.

### PANDEATOR

Windows:

```powershell
.\POST\PANDEATOR_APP\RUN_PANDEATOR_WINDOWS.cmd
```

macOS/Linux:

```bash
bash POST/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh
```

Its default address is `http://127.0.0.1:8088/`. Both wrappers accept `--port 8090 --no-open`. Startup can warm representative solver paths before listening; wait for readiness. Keep the terminal open. Stop a server with Ctrl+C. See the [PANDEATOR guide](../POST/PANDEATOR_APP/PANEL_APP_README.md).

### Standalone JFEM and viewer-ready output

Run the bundled tiny SOL101 deck. Windows:

```powershell
.\jfem.cmd JFEM_installation\examples\precompile\sol101_quad_static.bdf output\installation_smoke
```

macOS/Linux:

```bash
bash jfem JFEM_installation/examples/precompile/sol101_quad_static.bdf output/installation_smoke
```

The default writes `.jfem` viewer data, a report and results JSON under `output/installation_smoke`. A successful run exits normally. `-rs` before the deck selects only report and JSON, omitting viewer binary output. A first solve can compile methods not covered by setup.

### Browser results viewer

Open `POST/JFEM_results_viewer/postv11.html` in a modern browser, then choose or drop a `.jfem` result. This static viewer needs no Julia server or extra packages. Its controls are described in `POST/JFEM_results_viewer/POST_GUIDE.html`. Keep the surrounding `POST` folders: local Babylon and shared `jfem_binary.js` load by relative path. The viewer reads results; it does not launch analyses.

Solver/FGen/PANDEATOR launch paths check dependencies and can install missing sources before loading modules. Explicit unified setup is the clearest way to prepare or repair every app. `JFEM_AUTO_INSTALL=0` disables automatic installation for managed/offline workflows.

## 5. Setup options

Use `setup.cmd --help`, `bash setup.sh --help`, or the Julia helper with `--help` for the current options. `WingFEGen/setup.cmd`, `setup.sh` and `setup.jl` delegate to the same setup.

| Option | Effect |
|---|---|
| `--dry-run` | Validate and print the plan without installing or creating an image. |
| `--no-precompile --no-verify` | Install without explicit precompilation or module/asset verification. Later imports still compile; this does not prove the apps load. |
| `--solver-only` | Prepare the root project and associated tools; omit the separate FGen project. |
| `--wingfegen-only` | Prepare FGen only; not a complete solver-backed installation. Cannot combine with `--sysimage`. |
| `--offline` | Use a populated matching cache; cannot bootstrap an empty offline machine. |
| `--sysimage` | After setup, build the standard local solver/PANDEATOR image. |
| `--sysimage=PATH` | Build at a custom path. Automatic launchers still search their standard path. |
| `--sysimage-threads=N` | Set the build child's Julia threads; `auto` uses automatic selection. This is not a memory limit. |

`--no-precompile` alone does not stop verification imports from compiling. Neither `--no-precompile` nor `--no-verify` cancels an explicitly requested image build. Omit `--sysimage` for dependency installation only.

## 6. Build an optional sysimage

A sysimage stores loaded packages and selected compiled methods to reduce repeated startup/first-use compilation. It does not replace Julia or the checkout, and it does not guarantee zero compilation for every model. Embedded package versions are fixed at build time. [PackageCompiler sysimages](https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html).

This image covers **OpenJFEM and the PANDEATOR server stack/workload**. Eligible native solver processes launched by FGen can also use it. **It does not compile the FGen application server or all FGen geometry/UI paths.** The static viewer does not use a Julia image.

1. Stop your own solver/server processes before replacing an image they may have loaded. Keep source and representative decks unchanged during the build.
2. Use the same compatible Julia executable that will run the apps.
3. Run `.\setup.cmd --sysimage` or `bash setup.sh --sysimage`. Portable equivalent:

```text
julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl --sysimage
```

4. Wait for package setup, workload compilation, image creation and the provenance receipt. Read workload warnings. The build can use substantial CPU/RAM and several minutes; it executes representative decks to compile their methods.
5. Check the image and adjacent receipt, then verify and run the tiny example below.

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

## 7. Verify, use and rebuild the image

From the root, on Windows:

```powershell
julia --startup-file=no --project=. JFEM_installation/julia_tools/check_sysimage.jl . sysimage/OpenJFEM_sysimage.dll
```

Use `.so` on Linux or `.dylib` on macOS. A zero exit code means eligibility for automatic use; success is silent. A nonzero code prints a reason and says normal package loading will be used.

`jfem.cmd`/`jfem` and PANDEATOR wrappers select the standard image only after its receipt matches. FGen's eligible native solver runs check it too. Repeat the section 4 tiny solve to verify actual operation. An image build alone does not validate a user's model or every solver feature.

The receipt checks exact Julia/runtime/CPU identity, checkout location, source/project inputs, image hash and representative workload. A moved checkout, changed source/manifest, changed or missing build deck, missing receipt or changed image triggers fallback. This is an eligibility check, not an audit of arbitrary package-depot edits or native system libraries.

**Rebuild after:** Julia upgrades (including patches), project/dependency/code changes, checkout moves, machine/OS/CPU changes, or changed/removed representative decks. Stop your own affected runs, update the full checkout, rerun setup with `--sysimage`, check the new receipt and repeat the tiny solve. Package setup can accept a newer Julia patch while an old image still requires rebuilding for that exact runtime.

**Run without an image:** start fresh Julia without `-J`/`--sysimage`:

```text
julia --startup-file=no --project=. JFEM_installation/julia_tools/run_bdf.jl JFEM_installation/examples/precompile/sol101_quad_static.bdf output/source_smoke
```

Alternatively, move the optional image and receipt together into an archive outside the standard path while no process uses them. Wrappers then load ordinary packages. Do not force a stale image with `-J`: direct loading bypasses automatic provenance checks and may load old compiled code.

## 8. Advanced workload and direct build example

Unified setup invokes the existing `JFEM_installation/julia_tools/deploy_fast.jl`. With no workload arguments, it uses tiny bundled decks in `JFEM_installation/examples/precompile`. Add a small representative deck:

```text
julia --startup-file=no JFEM_installation/julia_tools/install_julia_packages.jl --sysimage --deck path/to/representative.bdf --sysimage-threads=4
```

Repeat `--deck` for multiple decks. `--manifest path/to/cases.json` reads a JSON `cases` array whose entries supply `input` (or `deck`), relative to the JSON file. `--flags "NAME=value,OTHER=value"` changes workload flags. These options require `--sysimage` in unified setup. Keep build inputs at stable paths: their locations and hashes are recorded. A representative workload improves coverage, not every possible future analysis.

After unified setup, experienced users can invoke the original builder directly. Windows:

```powershell
julia --threads=auto --startup-file=no --project=. JFEM_installation/julia_tools/deploy_fast.jl --sysimage=sysimage/OpenJFEM_sysimage.dll --install-packagecompiler
```

Use `.so` on Linux or `.dylib` on macOS. The current project already declares PackageCompiler; `--install-packagecompiler` allows adding it in an older project where absent, which can change dependency files. Direct `deploy_fast.jl` is not complete all-app setup. Without `--sysimage=...` it refreshes package/workload precompilation but creates no image.

A custom image is not automatically discovered. Prefer the standard location. For deliberate direct use, first run `check_sysimage.jl . PATH`, require exit code zero, then pass `--sysimage=PATH` to the intended Julia process with the root project. Do not attach this solver image indiscriminately to the separate FGen server project.

## 9. Repair, updates and offline use

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

Further reading: [installation PDF](../Reference_documentation/00_Getting_Started/jfem_2026_installation_guide.pdf), [FGen user guide](../Reference_documentation/00_Getting_Started/jfem_2026_fgen_user_guide.pdf), [PANDEATOR](../POST/PANDEATOR_APP/PANEL_APP_README.md), [result viewer controls](../POST/JFEM_results_viewer/POST_GUIDE.html).
