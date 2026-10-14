#!/usr/bin/env bash
# Compatibility entry: canonical setup owns dependencies, verification and build.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/../setup.sh" --sysimage "$@"
