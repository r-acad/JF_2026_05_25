# Install and run JFEM

Choose your operating system. Each folder contains its setup launcher,
application launchers and one guide covering installation, repair and offline use.

| System | Open this guide |
| --- | --- |
| Windows | [Windows/README.md](Windows/README.md) |
| Linux | [Linux/README.md](Linux/README.md) |
| macOS | [Mac/README.md](Mac/README.md) |

Use the complete extracted repository in a writable location. All apps share
the root Project/Manifest and one compiled image. These shortcuts forward to
the `Windows/`, `Linux/` and `Mac/` launchers inside each [app folder](../APPS/README.md).

After installation, Boxer, PANDEATOR and the results viewer run offline.
Babylon.js and the browser libraries are included in the download; no CDN or
browser cache is required. Setup checks the bundled files and their checksums.
Rendering prefers **WebGPU** when the browser and graphics driver support it;
otherwise the app uses **WebGL** and shows the fallback reason. The required
WebGPU shader compilers are bundled too. Boxer reports its renderer under
**Display / Environment** and in **Log**; the other viewers show it on screen.
The Results-viewer launcher starts a small local server for WebGPU; it loads
only browser assets, without loading the FE solver. Keep its console open while
viewing results. Opening `APPS/JFEM_results_viewer/postv11.html` directly remains
available as an offline WebGL fallback without Julia.
Keep the complete repository together. Downloading new UIUC airfoils still
requires internet; local files and profiles embedded in a Study work offline.
For installation on a disconnected computer, follow your operating system's
**Offline use** instructions to transfer Julia's package and artifact cache too.

[Illustrated installation PDF](jfem_2026_installation_guide.pdf) ·
[Solver commands and automation](../utils/julia_tools/README.md) ·
[Application user guides](../Reference_documentation/README.md)
