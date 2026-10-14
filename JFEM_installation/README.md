# Unified JFEM application setup

Follow the [from-scratch guide](INSTALLATION.md) to install the Julia version
recorded by this checkout. From the repository root, run one command:

```powershell
.\setup.cmd
```

```bash
bash setup.sh
```

This installs the recorded JFEM and WingFEGen environments and verifies all four
applications: the JFEM CLI, FGen, PANDEATOR and the static results viewer.
PANDEATOR shares the solver environment; the static viewer needs only its bundled
browser assets. Keep the complete repository folder structure. Setup does not
change the global Julia environment, depot configuration or dependency versions.
Normal setup does not build a sysimage.

The JFEM, FGen and PANDEATOR first-launch paths also install missing package
sources automatically. Run explicit setup to repair missing package artifacts.
Set `JFEM_AUTO_INSTALL=0` to require explicit setup instead. Use `JFEM_JULIA` to
select a Julia executable for the root and PANDEATOR launchers; FGen's own
launchers use `WINGFEGEN_JULIA`.

## Setup options

| Option | Effect |
| --- | --- |
| `--dry-run` | Print projects, application checks and any sysimage build command without installing or building. |
| `--offline` | Use existing package/artifact caches; uncached dependencies cannot be downloaded. |
| `--no-precompile` | Skip explicit package precompilation. Module verification can still compile code. |
| `--no-verify` | Skip application checks. Combine with `--no-precompile` for dependency installation only. |
| `--solver-only` | Install JFEM dependencies and check JFEM, PANDEATOR and static viewer. |
| `--wingfegen-only` | Install and verify only the FGen environment. |
| `--wingfegen-project=PATH` | Select another FGen project location. |
| `--update-registry` | Refresh registries before installing; ignored in offline mode. |
| `--sysimage` | After setup, build the optional local solver/PANDEATOR image. |
| `--sysimage=PATH` | Build at a custom path instead of the standard location. |
| `--sysimage-threads=N` | Limit build-process threads; default `auto`. |
| `--deck PATH` / `--manifest PATH` | Supply representative image workloads; requires `--sysimage`. Decks may be repeated. |
| `--flags VALUE` | Pass `FLAG=value,...` workload settings; requires `--sysimage`. |

Use `--help` for the CLI reference. FGen's `setup.cmd`, `setup.sh` and `setup.jl`
delegate to this same installer. Application verification loads modules and checks
PANDEATOR's health/static routes; it does not run a solver analysis or start a
browser. The static viewer check confirms required local assets exist.

## Optional local sysimage

```powershell
.\setup.cmd --sysimage
.\setup.cmd --sysimage --deck C:\models\representative_sol105.bdf
.\setup.cmd --sysimage --dry-run
```

```bash
bash setup.sh --sysimage
bash setup.sh --sysimage --manifest ~/models/cases.json
bash setup.sh --sysimage --sysimage-threads=2
```

The same setup first installs dependencies, then invokes PackageCompiler with
tiny bundled SOL101/103/105 examples and PANDEATOR handlers. Representative decks
replace the default deck workload. `--no-precompile` and `--no-verify` do not
cancel an explicitly requested image build. `--wingfegen-only --sysimage` is
rejected because the image belongs to the solver environment.

The historical `CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd`,
`CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command` and
`RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh` are compatibility wrappers
for `setup --sysimage`; they accept the same options. Set `OPENJFEM_NO_PAUSE=1`
for unattended Windows/macOS wrapper use.

The default output is `sysimage/OpenJFEM_sysimage.dll` on Windows, `.so` on Linux
or `.dylib` on macOS, plus a `.jfem.toml` provenance receipt. JFEM/PANDEATOR
launchers and FGen native solver jobs automatically select the standard image
only when its source, workload, runtime and image hashes still match. FGen's web
server itself uses its own environment and does not load this solver image.
Custom image paths are not automatically selected by these launchers.

Builds can require substantial CPU, RAM and time. A build failure returns status
2 after successful dependency setup; the applications still work without an
image. No timing or performance gain is guaranteed for an untrained model family.
Rebuild after changes to Julia, source, dependencies or representative workloads.
A stale or missing receipt makes the standard launchers fall back to normal Julia.

## Launch the applications

| Application | Entry point from the repository root |
| --- | --- |
| JFEM CLI | `jfem.cmd model.bdf` (Windows), `bash jfem model.bdf` (macOS/Linux) |
| FGen | `julia --startup-file=no --project=WingFEGen WingFEGen/run.jl` |
| PANDEATOR | `POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd` or `bash POST/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh` |
| Static results viewer | Open `POST/JFEM_results_viewer/postv11.html` in a browser and select a `.jfem` file. No Julia server or CDN is needed. |

## Troubleshooting and assets

If Julia is unavailable, install it from [Julia's official downloads](https://julialang.org/downloads/)
and reopen the terminal. The installer checks the checkout's recorded Julia
release line before installing packages. For offline preparation see
[OFFLINE_DEPENDENCIES.md](OFFLINE_DEPENDENCIES.md). Package/artifact download
errors require working network/proxy access or an existing cache.

Native sysimage compilation may require a compiler toolchain (for example Xcode
command-line tools on macOS or a system C compiler on Linux). The build's error
log identifies missing tools; ordinary application setup remains usable.
See [PackageCompiler's installation requirements](https://julialang.github.io/PackageCompiler.jl/stable/#Installation-instructions)
for the platform toolchain details.

`julia_tools/` contains shared setup, CLI, batch and worker helpers.
`examples/precompile/` contains redistributable tiny image workloads;
`examples/manifests/` contains batch templates. `python_client/` is optional
external automation and is not needed to install or launch the four applications.
