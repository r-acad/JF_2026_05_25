#!/usr/bin/env sh
set -eu
app_dir=$(CDPATH= cd "$(dirname "$0")/APPS/JFEM-Boxer" && pwd)
julia_bin=${WINGFEGEN_JULIA:-${JFEM_JULIA:-julia}}
exec "$julia_bin" --startup-file=no --threads=auto --project="$app_dir/../.." "$app_dir/JFEM-Boxer.jl" "$@"
