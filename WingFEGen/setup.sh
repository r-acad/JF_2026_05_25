#!/usr/bin/env sh
set -eu
app_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
julia_bin=${WINGFEGEN_JULIA:-julia}
exec "$julia_bin" --startup-file=no "$app_dir/setup.jl" "$@"
