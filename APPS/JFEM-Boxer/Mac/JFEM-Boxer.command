#!/usr/bin/env sh
set -eu
app_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
exec sh "$app_dir/Linux/JFEM-Boxer.sh" "$@"
