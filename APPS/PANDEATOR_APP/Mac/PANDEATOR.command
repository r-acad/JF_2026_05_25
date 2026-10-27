#!/usr/bin/env sh
set -eu
app_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
exec bash "$app_dir/Linux/PANDEATOR.sh" "$@"
