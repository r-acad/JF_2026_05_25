#!/usr/bin/env sh
set -eu
app_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
julia_bin=${WINGFEGEN_JULIA:-julia}
exec "$julia_bin" --startup-file=no --project="$app_dir" "$app_dir/run.jl" "$@"
