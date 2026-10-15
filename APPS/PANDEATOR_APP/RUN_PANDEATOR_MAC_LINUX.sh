#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"
PANEL_JULIA="${JFEM_JULIA:-julia}"
if ! command -v "$PANEL_JULIA" >/dev/null 2>&1; then
  echo "Julia was not found. Install Julia from https://julialang.org/downloads/" >&2
  echo "Or set JFEM_JULIA to an installed Julia executable." >&2
  exit 1
fi
echo "Starting PANDEATOR. First use may install dependencies and compile packages."
echo "The browser opens after server warm-up. Keep this terminal open; Ctrl+C stops it."
exec "$PANEL_JULIA" --startup-file=no --threads=1 "$REPO_ROOT/utils/julia_tools/launch.jl" solver "$REPO_ROOT" "$APP_DIR/panel_launch.jl" "$@"
