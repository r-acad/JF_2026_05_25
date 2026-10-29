#!/usr/bin/env bash
set -u
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bash "$root/setup.sh" "$@"
result=$?
if [ "${OPENJFEM_NO_PAUSE:-}" != 1 ] && [ -t 0 ]; then
  read -r -p "Setup finished with exit code $result. Press Return to close. " answer
fi
exit "$result"
