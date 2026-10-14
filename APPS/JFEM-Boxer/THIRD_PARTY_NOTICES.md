# Third-party frontend software

WingFEGen serves its frontend libraries from `web/vendor/`. These files are
included deliberately so the application does not need a CDN to start. They
retain their own licenses; the application's license does not replace them.

| Bundled file | Package and version | License | Included notices |
| --- | --- | --- | --- |
| `web/vendor/babylon.js` | Babylon.js (`babylonjs`) 9.27.1 | Apache-2.0 | [License](web/vendor/babylon.LICENSE.md), [upstream notice](web/vendor/babylon.NOTICE.md) |
| `web/vendor/babylonjs.loaders.min.js` | `babylonjs-loaders` 9.27.1 | Apache-2.0 | [License](web/vendor/babylonjs-loaders.LICENSE.md) |
| `web/vendor/msgpack.min.js` | `@msgpack/msgpack` 2.8.0 | ISC | [License and copyright](web/vendor/msgpack.LICENSE) |

On 2026-10-08 all three JavaScript files were compared with their pinned
upstream npm distribution archives and matched byte for byte. They are
unmodified upstream bundles. Exact package URLs, integrity strings, file sizes
and SHA-256 hashes are recorded in [provenance.json](web/vendor/provenance.json).

## Upstream sources

- Babylon.js: [repository at 9.27.1](https://github.com/BabylonJS/Babylon.js/tree/9.27.1),
  [license](https://github.com/BabylonJS/Babylon.js/blob/9.27.1/license.md),
  [NOTICE](https://github.com/BabylonJS/Babylon.js/blob/9.27.1/NOTICE.md).
- Babylon.js loaders: [source at 9.27.1](https://github.com/BabylonJS/Babylon.js/tree/9.27.1/packages/dev/loaders).
- MessagePack: [repository at v2.8.0](https://github.com/msgpack/msgpack-javascript/tree/v2.8.0),
  [license](https://github.com/msgpack/msgpack-javascript/blob/v2.8.0/LICENSE).

## Distribution and runtime scope

The Babylon runtime is approximately 8.56 MB and the loader bundle 0.85 MB.
These are the existing pinned browser runtime dependencies, not generated model
data. They are retained in full to preserve the tested rendering and reference
import behavior. Development source maps referenced in bundle comments are not
included; they are not required to execute the application.

All application scripts, styles, workers and detached-window pages are local
assets. No frontend package installation or build step is required. The UIUC
airfoil catalogue is an optional external data source, requested through the
Julia server only when that source is selected. NACA generation and already
embedded airfoils do not need it. No downloaded UIUC coordinate database is
redistributed with these frontend assets.

Reference geometry uses the included STL/OBJ/GLB loaders. OBJ material sidecars
are ignored, external GLB geometry buffers and Draco/meshopt compression are
rejected, and imported materials are skipped. The application generates its
metallic-view reflection map locally. The larger Babylon distribution contains
optional network-capable features; WingFEGen does not require their CDN assets
for its supported viewer and reference-import paths.

The Julia backend dependencies are declared separately by `Project.toml` and
`Manifest.toml`; their licenses are not replaced by this frontend notice.

Run `node test/portable_frontend_test.cjs` from the WingFEGen directory for
offline asset, syntax, vendored-library and pure frontend smoke checks. The test
uses only Node.js builtins and bundled sources; it does not start a server or
run an analysis.
