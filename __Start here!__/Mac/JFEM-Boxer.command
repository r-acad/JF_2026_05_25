#!/usr/bin/env bash
set -eu
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$root/APPS/JFEM-Boxer/Mac/JFEM-Boxer.command" "$@"
