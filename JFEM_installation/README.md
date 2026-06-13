# OpenJFEM One-Click Installation

This folder contains the setup files intended for first-time users. After Julia
is installed, the user should run one platform-specific file from this folder.
That file installs the Julia packages and creates the local sysimage used for
fast startup.

## Before You Click

Install Julia 1.12.x and make sure the `julia` command is available on `PATH`.
Git is also recommended so the repository can be cloned and updated normally.

## Click One File

| Platform | What to do |
|---|---|
| Windows | Double-click `CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd`. |
| macOS | Double-click `CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command`. |
| Linux | Run `RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh` from a terminal. |

Linux usually needs the executable bit set once:

```bash
chmod +x JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
```

If macOS blocks the double-click launcher, run:

```bash
chmod +x JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command
open JFEM_installation/CLICK_MAC_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.command
```

The setup can take several minutes and may use a lot of CPU and memory while
Julia compiles the solver. That is normal.

## What The Setup Does

1. Installs and instantiates the packages declared by the repository
   `Project.toml` and `Manifest.toml`.
2. Runs a small precompile workload using bundled SOL 101, SOL 103, and SOL 105
   decks from `examples/precompile/`.
3. Builds a PackageCompiler sysimage under the repository `sysimage/` folder.

The sysimage file is platform-specific:

```text
sysimage/OpenJFEM_sysimage.dll     Windows
sysimage/OpenJFEM_sysimage.so      Linux
sysimage/OpenJFEM_sysimage.dylib   macOS
```

The command-line launchers and web-app launchers load it automatically when it
exists:

| Launcher | Uses the sysimage if present |
|---|---|
| `jfem` / `jfem.cmd` | yes |
| `POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd` / `POST/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh` | yes |

The sysimage is a startup-speed optimization. It does not change solver
results, model data, load factors, or equations. If it is missing, OpenJFEM
still runs, but startup is slower.

## After Installation

Run a deck from the repository root:

```powershell
.\jfem C:\models\my_model.bdf
```

```bash
./jfem ~/models/my_model.bdf
```

Open `.jfem` result files with:

```text
POST/JFEM_results_viewer/postv11.html
```

On Windows, the web case runner can be started by double-clicking:

```text
POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd
```

## Representative Decks

The default setup uses tiny bundled decks so a new user does not need any model
files. For best startup performance on a recurring model family, rebuild the
sysimage from a terminal and pass representative decks:

```powershell
.\JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd --deck C:\models\representative_sol105.bdf
```

```bash
./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh --deck ~/models/representative_sol105.bdf
```

A JSON batch manifest can also be supplied:

```powershell
.\JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd --manifest C:\models\cases.json
```

## Installation Assets

- `julia_tools/`: Julia helper scripts used by setup launchers, wrappers,
  manifest batches, and Python worker workflows.
- `examples/precompile/`: tiny decks used only to warm common solver paths when
  no representative user deck is supplied.
- `examples/manifests/`: small manifest templates for checking the batch runner.
- `python_client/`: optional Python helpers for external automation that needs
  to write manifests or drive the JSONL worker.

## Troubleshooting

- If `julia` is not found, install Julia 1.12.x and put it on `PATH`.
- If package installation fails on a machine without internet access, see
  `OFFLINE_DEPENDENCIES.md`.
- If the sysimage build fails on Linux/macOS, install a native toolchain
  (`gcc`/`build-essential` on Linux, Xcode command-line tools on macOS).
- Rebuild the sysimage after upgrading Julia or changing OpenJFEM package
  dependencies.
- To stop using the sysimage, delete `sysimage/OpenJFEM_sysimage.*`.
