#!/usr/bin/env sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
if [ "$(uname -s)" = Darwin ]; then
    exec open "$root/APPS/JFEM_results_viewer/postv11.html"
fi
exec xdg-open "$root/APPS/JFEM_results_viewer/postv11.html"
