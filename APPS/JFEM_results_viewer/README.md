> **Before first launch:** run `setup.cmd` (Windows), `bash setup.sh` (Linux), or `bash setup.command` (macOS) at the repository root. This installs shared packages and creates the shared image under the root `sysimage/` directory. Wait until setup completes.

# JFEM results viewer

Use the launcher for your operating system:

- Windows: `Windows/Results-viewer.cmd`.
- Linux: `bash Linux/Results-viewer.sh` from this folder.
- macOS: open `Mac/Results-viewer.command`.

The launcher starts a lightweight local server for the bundled browser assets;
it does not load the finite-element solver. Keep its terminal open while using
the viewer. If Julia is unavailable, it opens `postv11.html` directly as an
offline WebGL fallback. See [viewer controls](POST_GUIDE.html) and the
[installation guide](<../../__Start here!__/README.md>).
