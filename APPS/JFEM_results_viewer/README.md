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
