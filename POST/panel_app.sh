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
# Pin to the juliaup "release" channel (currently 1.12.3). Drop "+release" if
# you don't use juliaup.
exec julia +release --project="$REPO_ROOT" --threads=auto "$POST_DIR/panel_launch.jl" "$@"
