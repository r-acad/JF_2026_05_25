#!/usr/bin/env bash
set -eu
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$root/APPS/JFEM-solver/Mac/JFEM-solver.command" "$@"
