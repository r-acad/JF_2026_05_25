# Building the OpenJFEM sysimage (optional speed-up)

A **sysimage** is a prebuilt native image of OpenJFEM and the web-server stack.
With one present, the solver and the web app start near-instantly — including
the **first** analysis — instead of paying Julia's one-time compilation on every
fresh run.

> **It is optional.** Everything works without a sysimage; runs are just slower
> to start (each fresh process compiles on first use). Build it once per machine
> to remove that wait.

## Build it (once per machine)

The build takes **several minutes** and uses a lot of CPU/RAM. The window may
look frozen — that is normal. You need a **Julia 1.12.x** on your `PATH`.

### Windows

Double-click **`build_sysimage.cmd`**, or from a console at the repo root:

```bat
build_sysimage\build_sysimage.cmd
```

Produces `build\OpenJFEM_sysimage.dll`.

### Linux / macOS

Make it executable once, then run it (from the repo root):

```bash
chmod +x build_sysimage/build_sysimage.sh
./build_sysimage/build_sysimage.sh
```

Produces `build/OpenJFEM_sysimage.so` (Linux) or `build/OpenJFEM_sysimage.dylib`
(macOS).

## After building — nothing else to do

The launchers load the sysimage **automatically** when it exists:

| Launcher | Uses the sysimage if present |
|---|---|
| `jfem` / `jfem.cmd` (command-line deck runner) | yes |
| `POST/panel_app.cmd` / `POST/panel_app.sh` (web app) | yes |

You can confirm the web app picked it up: its server window prints
`sysimage: YES (OpenJFEM_sysimage.dll)` at startup, and the `/health` endpoint
reports `sysimage.custom = true`.

## What gets baked in

The build runs `tools/deploy_fast.jl --sysimage=...`, which compiles OpenJFEM
**plus** the web-server stack (`HTTP`, `MsgPack`, `JSON`) and exercises the
server's real run path (`run_analysis` + the HTTP handler + msgpack) on the
bundled SOL 101/103/105 decks. That is why the **first** browser "Run a .bdf
file" is fast, not just process startup. If `PackageCompiler` is not yet in the
project, the build adds it automatically (`--install-packagecompiler`).

## Important notes

- **Not portable.** The image is tied to this machine's exact Julia version, OS,
  and CPU. Build it on each machine; it is git-ignored and never committed.
- **Rebuild it** after upgrading Julia or changing the OpenJFEM packages.
- **It is a speed layer only** — results are identical with or without it.
- To stop using it, just delete `build/OpenJFEM_sysimage.*`; the launchers fall
  back to a normal start.

## Troubleshooting

- *"julia is not recognized / command not found"* — install Julia 1.12.x and
  ensure it is on your `PATH`.
- *Build finishes but no file appears* — read the console output; a failed
  `PackageCompiler` step (e.g. missing C toolchain on Linux/macOS) is reported
  there. On Linux you may need `build-essential`/`gcc`; on macOS the Xcode
  command-line tools (`xcode-select --install`).
- *The app still starts slowly* — confirm the file exists at
  `build/OpenJFEM_sysimage.<dll|so|dylib>` and that the server banner reports
  `sysimage: YES`.
