#!/usr/bin/env bash
set -euo pipefail
boxer_mcp_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
boxer_mcp_julia="${WINGFEGEN_JULIA:-${JFEM_JULIA:-julia}}"
exec "$boxer_mcp_julia" --startup-file=no --project="$boxer_mcp_dir/../../.." "$boxer_mcp_dir/../BoxerMCP.jl" "$@"
