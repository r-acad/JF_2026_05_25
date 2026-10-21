Babylon.js loaders 9.27.1
========================

`babylonjs.loaders.min.js` is the unmodified UMD bundle pinned to the same
9.27.1 version as the existing `babylon.js` runtime.

Downloaded 2026-09-28 from:
https://cdn.jsdelivr.net/npm/babylonjs-loaders@9.27.1/babylonjs.loaders.min.js

License: Apache-2.0; see `babylonjs-loaders.LICENSE.md` (upstream 9.27.1).
Upstream source: https://github.com/BabylonJS/Babylon.js/tree/9.27.1/packages/dev/loaders

The reference-geometry viewer uses the included STL, OBJ and GLB importers.
Runtime loading uses local browser files and this vendored bundle. OBJ sidecar
materials are ignored. External GLB geometry buffers and geometry compression
requiring additional decoder downloads are rejected before invoking the loader.

The complete repository includes both bundles; users do not need to download
Babylon.js separately or visit an online page first. Setup checks the pinned
SHA-256 hashes in `provenance.json`, including for `--boxer-only`. These checks
read local files and do not contact a CDN. Keep this directory with the rest of
the application when copying an installation to an offline computer.

The `glslang/` and `twgsl/` subdirectories contain the matching WebGPU shader
compiler JavaScript/WebAssembly files. Shared graphics startup loads these local
files explicitly, prefers WebGPU, and falls back to WebGL with a reported reason
if the browser, adapter or compiler initialization is unavailable.
