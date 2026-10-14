# Offline installation of the shared JFEM environment

JFEM, JFEM-Boxer and PANDEATOR use the **same root Project.toml and Manifest.toml**.
The manifest is the authoritative package/version list; there are no separate
app dependency environments to prepare. Everyday online installation is simply
**setup.cmd** (or `bash setup.sh`).

## Prepare on a connected computer

1. Use the same operating system, processor architecture and recorded Julia
   release as the offline computer. The current checkout records Julia 1.13.1.
2. Download/extract the complete repository and run **setup.cmd** successfully.
   This downloads packages and their native artifacts and builds the shared image.
3. Copy the complete repository and the Julia depot to the offline computer.
   The default depot is `%USERPROFILE%\.julia` on Windows or `~/.julia` on
   macOS/Linux. If using `JULIA_DEPOT_PATH`, copy that depot instead.
4. Install Julia on the target computer, **add Julia to PATH**, and reopen the
   launcher. On the target, run `setup.cmd --offline` from a terminal, or
   `bash setup.sh --offline` on macOS/Linux. It uses cached packages/artifacts
   and rebuilds the shared image when the receipt does not match the new location.
5. Start the root app launcher normally.

Native artifacts are specific to operating system and architecture. A depot
prepared on Windows is not a substitute for a Linux depot. Do not force an old
image using `-J`; the normal launchers verify the environment and sources.

## Diagnose missing packages

An offline cache must contain both package sources and their native artifacts.
If setup names a missing dependency/artifact, repeat setup on the connected
computer with the same platform, then refresh the copied depot. Do not edit the
manifest or install random newer package versions to silence the error.

For a readable package list, run this in the **repository root**:

```powershell
julia --project=. -e "using Pkg; Pkg.status(;mode=Pkg.PKGMODE_MANIFEST)"
```

The static results viewer uses bundled JavaScript and needs no Julia packages,
network connection or CDN to open an existing `.jfem` file.

See [installation](INSTALLATION.md) and [advanced setup](ADVANCED_SETUP.md).
