#!/usr/bin/env bash
# macOS double-click wrapper for installing packages and creating the OpenJFEM sysimage.
set -u

HERE="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"

bash "$HERE/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh" "$@"
STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
  echo "Done. The OpenJFEM sysimage is ready."
else
  echo "Sysimage build failed - see the messages above."
fi
echo "Press Return to close this window."
read -r _
exit "$STATUS"
