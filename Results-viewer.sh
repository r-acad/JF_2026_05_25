#!/usr/bin/env sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
julia_bin=${JFEM_JULIA:-julia}
if command -v "$julia_bin" >/dev/null 2>&1; then
    echo "Starting the results viewer. Keep this terminal open; Ctrl+C stops it."
    exec "$julia_bin" --startup-file=no --threads=1 --project="$root" "$root/utils/julia_tools/serve_results_viewer.jl" "$@"
fi
echo "Julia was not found. Opening the offline WebGL viewer directly."
if [ "$(uname -s)" = Darwin ]; then
    exec open "$root/APPS/JFEM_results_viewer/postv11.html"
fi
exec xdg-open "$root/APPS/JFEM_results_viewer/postv11.html"
