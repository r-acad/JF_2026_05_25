#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JULIA_BIN="${JFEM_JULIA:-julia}"
if ! command -v "$JULIA_BIN" >/dev/null 2>&1; then
  echo "Julia was not found. Install it from https://julialang.org/downloads/ then reopen this terminal." >&2
  echo "Or set JFEM_JULIA to an installed Julia executable." >&2
  exit 1
fi
exec "$JULIA_BIN" --startup-file=no --project="$ROOT" "$ROOT/__Start here!__/julia_tools/install_julia_packages.jl" "$@"
