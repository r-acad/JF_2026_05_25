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
