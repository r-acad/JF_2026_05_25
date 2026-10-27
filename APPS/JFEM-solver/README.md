# Standalone JFEM solver launchers

This folder contains launchers for the shared solver in `../../src/`.
It uses the root Julia project and sysimage; it is not a second solver copy.
Install first using the [setup guide](<../../__Start here!__/README.md>).

| Operating system | Choose or drop a deck | Command-line runner |
| --- | --- | --- |
| Windows | `Windows/JFEM-solver.cmd` | `Windows/jfem.cmd` |
| Linux | `Linux/JFEM-solver.sh` | `Linux/jfem` |
| macOS | `Mac/JFEM-solver.command` | `Mac/jfem` |

The chooser accepts a deck argument or opens a file chooser when no argument
is supplied. Linux falls back to a terminal prompt if no dialog tool is present.
The command-line runner accepts `[-formats] <deck> [output_folder]` without a
chooser. Inputs include Reference `.bdf`/`.dat`/`.nas` and supported Abaqus
`.inp`/`.inp.gz` files.

Examples from the repository root:

```powershell
.\APPS\JFEM-solver\Windows\jfem.cmd -rs C:\models\model.bdf C:\results\run1
```

```bash
bash APPS/JFEM-solver/Linux/jfem -rs /path/to/model.bdf /path/to/results
bash APPS/JFEM-solver/Mac/jfem -rs /path/to/model.bdf /path/to/results
```

Launchers also work from an unrelated current directory when given their full
path. Keep the complete checkout together. For a short `jfem` command, add the
appropriate operating-system folder to PATH or symlink the Unix `jfem` script.
See the [solver reference](../../utils/julia_tools/README.md) for output flags,
batch commands and diagnostics.
