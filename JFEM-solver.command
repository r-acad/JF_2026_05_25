#!/usr/bin/env sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec bash "$root/JFEM-solver.sh" "$@"
