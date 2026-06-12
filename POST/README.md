# OpenJFEM Post-Processing And Web Apps

`POST/` contains two separate browser tools:

| Folder | Purpose | Main file |
| --- | --- | --- |
| `JFEM_results_viewer/` | Open existing `.jfem` result files directly in a browser. | `postv11.html` |
| `case_runner_web_app/` | Launch a local Julia server that builds/runs cases and streams results to the browser. | `panel_app.cmd` or `panel_app.sh` |

Use `JFEM_results_viewer/POST_GUIDE.html` for the result viewer controls.
Use `case_runner_web_app/PANEL_APP_README.md` for the server-backed case runner.
