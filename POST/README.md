# OpenJFEM Post-Processing And Web Apps

`POST/` contains two separate browser tools:

| Folder | Purpose | Main file |
| --- | --- | --- |
| `JFEM_results_viewer/` | Open existing `.jfem` result files directly in a browser. | `postv11.html` |
| `PANDEATOR_APP/` | Launch a local Julia server that builds/runs cases and streams results to the browser. | `RUN_PANDEATOR_WINDOWS.cmd` or `RUN_PANDEATOR_MAC_LINUX.sh` |

Use `JFEM_results_viewer/POST_GUIDE.html` for the result viewer controls.
Use `PANDEATOR_APP/PANEL_APP_README.md` for the server-backed case runner.

Both viewers share `jfem_binary.js`, which reads JFEM binary versions 1–5 and
validates result framing. Keep the `POST/` folder structure when copying either
tool. Corrected and archived v5 files are supported; v5 includes the static
preload alongside the buckling modes.
