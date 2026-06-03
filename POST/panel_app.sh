#!/usr/bin/env bash
# ====================================================================
#  Stiffened-panel buckling web app - macOS/Linux launcher.
#  Starts the pure-Julia server and opens the browser automatically.
#  Usage:  ./panel_app.sh [--port 8088] [--no-open]
# ====================================================================
set -euo pipefail
POST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$POST_DIR/.." && pwd)"
echo "Starting JFEM stiffened-panel server (Julia)..."
echo "The browser will open at http://127.0.0.1:8088/ once the server is up."
echo "Press Ctrl+C to stop the server."

# Optional sysimage: load a prebuilt OpenJFEM sysimage with --sysimage when one
# exists (Linux .so, macOS .dylib), so startup and the first analysis are
# near-instant. Build it once with build_sysimage/build_sysimage.sh. If absent,
# we start normally (just a slower first run).
SYSIMG_ARG=()
for ext in so dylib; do
  cand="$REPO_ROOT/build/OpenJFEM_sysimage.$ext"
  if [ -f "$cand" ]; then SYSIMG_ARG=(--sysimage="$cand"); echo "Using prebuilt sysimage: $cand"; break; fi
done

# Use whatever "julia" is on PATH (Julia 1.12.x). No juliaup / no "+release":
# a standalone julia treats "+release" as a bad path argument and errors.
exec julia "${SYSIMG_ARG[@]}" --project="$REPO_ROOT" --threads=auto "$POST_DIR/panel_launch.jl" "$@"
