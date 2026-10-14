#!/usr/bin/env bash
# Finder compatibility wrapper around the same canonical setup command.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/../setup.sh" --sysimage "$@"
STATUS=$?
if [ "${OPENJFEM_NO_PAUSE:-0}" != "1" ]; then
  echo "Setup exited with status $STATUS. Press Return to close this window."
  read -r _
fi
exit "$STATUS"
