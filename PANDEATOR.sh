#!/usr/bin/env sh
set -eu
root=$(CDPATH= cd "$(dirname "$0")" && pwd)
exec bash "$root/APPS/PANDEATOR_APP/RUN_PANDEATOR_MAC_LINUX.sh" "$@"
