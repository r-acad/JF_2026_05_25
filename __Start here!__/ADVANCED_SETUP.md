# Advanced setup and the shared sysimage

For a first installation use the [five-step walkthrough](INSTALLATION.md).
**setup.cmd** / `bash setup.sh` installs all apps and builds the shared sysimage by
default. These instructions are for troubleshooting or automation.

## Runtime and project selection

The manifests record **Julia 1.13.1**. Use the recorded minor release; later
compatible patches are checked by setup. **Add Julia to PATH** on Windows.
`JFEM_JULIA` selects an explicit executable for the root launchers;
`WINGFEGEN_JULIA` remains available for the app runtime. Values are executable
paths, without flags. Juliaup users can install the recorded line with
`juliaup add 1.13` and invoke it as `julia +1.13`.

JFEM, JFEM-Boxer and PANDEATOR all use the repository root Project/Manifest.
There is one environment and one pinned set of package versions. The APPS
folders organize the interfaces within this same workspace; no separate app
installation or external solver checkout is needed. No global Julia environment
is modified.

## Automatic shared image

Setup creates `sysimage/OpenJFEM_sysimage.dll` on Windows (`.so` on Linux,
`.dylib` on macOS). It includes the solver and Boxer application workloads.
The app servers and analysis/sensitivity workers select this same image.

The image has a provenance receipt tied to Julia, source and the shared
Project/Manifest. Launchers validate it before loading it so an update cannot
silently execute stale compiled code.

Rerun **setup.cmd** after updating code, Julia, manifests or moving the checkout.
Current images are reused. Missing/stale images are rebuilt by setup. Launching
without a usable image is allowed and is reported; it can compile code at startup.
The representative workloads cannot cover every possible user model, so a new
code path may still incur first-use compilation.

## Setup switches

Run these from the repository root (PowerShell examples):

```powershell
.\setup.cmd --dry-run
.\setup.cmd --no-sysimage
.\setup.cmd --sysimage-threads=4
.\setup.cmd --offline
.\setup.cmd --solver-only
```

`--no-sysimage` intentionally opts out of image construction. `--no-precompile`
and `--no-verify` alone do not prevent image builds; download-only preparation also
needs `--no-sysimage`. `--offline` uses only already cached packages/artifacts.
The default package/image compilation concurrency is two tasks/threads.
`--sysimage-threads=auto` is an explicit advanced override; ordinary analysis
launches still use the normal solver thread setting. A build-thread count is
not a memory limit.

To add representative solver workloads:

```powershell
.\setup.cmd --deck 'C:\models\representative.bdf' --sysimage-threads=4
```

`--deck` is repeatable; `--manifest` accepts a JSON batch manifest and `--flags`
accepts workload `NAME=value` options. The bundled workloads cover basic static,
modal, buckling, nonlinear and sensitivity routes. These solves are compilation
workloads, separate from your own analyses.

## Standalone and automation

Everyday Windows use: double-click **JFEM-solver.cmd**, choose a deck, or drop a
deck onto the launcher. For scripted execution:

```powershell
.\jfem.cmd 'C:\models\model.bdf' output\my_run
```

```bash
bash jfem path/to/model.bdf output/my_run
```

For a source-only diagnostic, invoke the helper without `-J`:

```powershell
julia --startup-file=no --project=. '__Start here!__/julia_tools/run_bdf.jl' '__Start here!__/examples/precompile/sol101_quad_static.bdf' output/source_check
```

Quote paths containing spaces, including `__Start here!__`. Never force a stale
image with `-J`. See the launch console for the selected runtime and image.
The [PackageCompiler documentation](https://julialang.github.io/PackageCompiler.jl/stable/sysimages.html)
explains compiled-image behavior and its version-locking implications.

## Repair

Restore network access and rerun setup after download failures. For an out-of-memory
image build, close other applications and retry with fewer build threads; an
explicit `--no-sysimage` setup leaves the normal source workflow available.
Do not delete input decks or studies to repair an installation.
