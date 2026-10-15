#!/usr/bin/env bash
set -u
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$root/JFEM-solver.sh" "$@"
