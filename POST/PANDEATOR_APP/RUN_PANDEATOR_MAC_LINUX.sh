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
# Only select images with matching receipts. Optional build: bash setup.sh --sysimage.
SYSIMG_ARG=()
for ext in so dylib; do
  cand="$REPO_ROOT/sysimage/OpenJFEM_sysimage.$ext"
  if [ -f "$cand" ]; then
    if "$PANEL_JULIA" --startup-file=no --threads=1 --project="$REPO_ROOT" "$REPO_ROOT/JFEM_installation/julia_tools/check_sysimage.jl" "$REPO_ROOT" "$cand"; then
      SYSIMG_ARG=(--sysimage="$cand"); echo "Using verified sysimage: $cand"; break
    fi
  fi
done
exec "$PANEL_JULIA" "${SYSIMG_ARG[@]}" --startup-file=no --project="$REPO_ROOT" --threads=auto "$APP_DIR/panel_launch.jl" "$@"
