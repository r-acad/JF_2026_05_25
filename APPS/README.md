**Run the root `setup.cmd`, `bash setup.sh` or `bash setup.command` first.** Setup installs shared packages and automatically reuses/builds the shared image when resources permit. Low memory or an image-build failure selects ordinary Julia loading; apps remain usable. App folders contain launchers, not installers.

# JFEM applications

Install once with the setup launcher for your operating system in
[`__Start here!__`](<../__Start here!__/README.md>). All applications share the
repository root Project/Manifest. They run without a sysimage and use a compatible
local image when available. Setup handles image construction and fallback
automatically. Without an image, first use can compile Julia code.

Each application keeps its launchers in `Windows/`, `Linux/` and `Mac/`.
The shortcuts in `__Start here!__` forward here; only the shared setup launchers live at the repository root.

| Application | Windows | Linux | macOS |
| --- | --- | --- | --- |
| JFEM-Boxer | [JFEM-Boxer.cmd](JFEM-Boxer/Windows/JFEM-Boxer.cmd) | [JFEM-Boxer.sh](JFEM-Boxer/Linux/JFEM-Boxer.sh) | [JFEM-Boxer.command](JFEM-Boxer/Mac/JFEM-Boxer.command) |
| PANDEATOR | [PANDEATOR.cmd](PANDEATOR_APP/Windows/PANDEATOR.cmd) | [PANDEATOR.sh](PANDEATOR_APP/Linux/PANDEATOR.sh) | [PANDEATOR.command](PANDEATOR_APP/Mac/PANDEATOR.command) |
| Results viewer | [Results-viewer.cmd](JFEM_results_viewer/Windows/Results-viewer.cmd) | [Results-viewer.sh](JFEM_results_viewer/Linux/Results-viewer.sh) | [Results-viewer.command](JFEM_results_viewer/Mac/Results-viewer.command) |
| Standalone solver | [JFEM-solver.cmd](JFEM-solver/Windows/JFEM-solver.cmd) | [JFEM-solver.sh](JFEM-solver/Linux/JFEM-solver.sh) | [JFEM-solver.command](JFEM-solver/Mac/JFEM-solver.command) |

Windows `.cmd` and macOS `.command` entries can be opened directly. On Linux,
run the selected `.sh` script with Bash. Launchers accept arguments and resolve
all application paths from their own location, including checkouts with spaces.
The standalone solver folder also contains [command-line launchers](JFEM-solver/README.md).

[JFEM-Boxer guide](JFEM-Boxer/README.md) |
[PANDEATOR guide](PANDEATOR_APP/PANEL_APP_README.md) |
[Results-viewer controls](JFEM_results_viewer/POST_GUIDE.html)

![JFEM-Boxer model](<../utils/images/fgen-model.png>)

Keep the full `APPS/` tree together. The result viewers share `jfem_binary.js`
and `jfem_graphics.js`. The results-viewer server serves bundled browser assets
without loading the FE solver and enables WebGPU where available. Directly
opening `JFEM_results_viewer/postv11.html` remains an offline WebGL fallback
without Julia. All viewers use bundled browser libraries.
