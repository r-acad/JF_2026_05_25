# Install JFEM

Use the [illustrated installation guide (PDF)](jfem_2026_installation_guide.pdf)
or the [numbered instructions online](INSTALLATION.md).

1. **Install Julia.** Get Julia **1.13.1**, the version recorded by this checkout, from the [official downloads page](https://julialang.org/downloads/manual-downloads/). On Windows, tick **Add Julia To PATH** in the installer.
2. **Download JFEM.** On the [GitHub repository](https://github.com/r-acad/JF_2026_05_25), click **Code**, then **Download ZIP**, and extract the whole ZIP.
3. **Run setup.** Open the extracted folder containing `setup.cmd`. Click the address bar, type `powershell`, press Enter, then run `.\setup.cmd`. On macOS/Linux, run `bash setup.sh` in that folder.
4. **Wait for completion.** Keep the terminal open until it prints **Application dependency setup complete.** The first download and compilation can take several minutes.
5. **Open an application.** Use the launch files below.

![Folder map showing the setup command and all four application entry points](images/launch-files.png)

*Keep the extracted folders together. Setup prepares all four applications.*

| Application | Windows launch file, relative to the extracted repository |
| --- | --- |
| FGen | `WingFEGen/run_fe_generator.cmd` |
| PANDEATOR | `POST/PANDEATOR_APP/RUN_PANDEATOR_WINDOWS.cmd` |
| Static results viewer | `POST/JFEM_results_viewer/postv11.html` |
| JFEM solver | Follow the [tiny standalone example](INSTALLATION.md#6-try-the-standalone-solver-optional). |

Setup installs the required Julia packages automatically for all four tools.
Keep the complete repository together. You do not need Python, Node.js or a
separate web server.

**Optional later:** `.\setup.cmd --sysimage` or `bash setup.sh --sysimage` builds a
local solver/PANDEATOR image. It can reduce repeated startup work, takes extra
time and memory, and does not cover FGen's separate server. Normal setup works
without it. The older `CLICK_*_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE` files run
this optional build through the same setup.

See [advanced setup and sysimages](ADVANCED_SETUP.md) for all flags, runtime
selection, image checks/rebuilds, representative workloads and troubleshooting.
The [offline guide](OFFLINE_DEPENDENCIES.md) covers prepared package caches.
