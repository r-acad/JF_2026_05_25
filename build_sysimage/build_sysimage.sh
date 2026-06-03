#!/usr/bin/env bash
# ====================================================================
#  build_sysimage.sh  --  Linux / macOS
#
#  Builds a prebuilt OpenJFEM sysimage so the solver and the web app start
#  near-instantly (including the FIRST analysis), instead of paying Julia's
#  one-time compilation on every fresh run.
#
#  HOW TO USE
#    Make it executable once, then run it:
#        chmod +x build_sysimage/build_sysimage.sh
#        ./build_sysimage/build_sysimage.sh
#
#  WHAT IT PRODUCES
#    <repo>/build/OpenJFEM_sysimage.so      (Linux)
#    <repo>/build/OpenJFEM_sysimage.dylib   (macOS)
#    The launchers (jfem, POST/panel_app.sh) load it AUTOMATICALLY when present.
#
#  NOTES
#    * Takes several minutes and uses a lot of CPU/RAM - this is normal.
#    * The image is tied to THIS machine's Julia version + OS + CPU. It is NOT
#      portable: build it on each machine, and rebuild after a Julia upgrade or
#      a change to the OpenJFEM packages.
#    * If you never build it, everything still works - just slower to start.
#    * Needs a Julia 1.12.x on PATH.
# ====================================================================
set -euo pipefail

# Resolve this script's directory (follow symlinks), then the repo root (..).
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
HERE="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "$HERE/.." >/dev/null 2>&1 && pwd)"

# Pick the platform-correct shared-library extension the launchers look for.
case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  *)      EXT="so" ;;
esac
SYSIMG="$REPO_ROOT/build/OpenJFEM_sysimage.$EXT"

echo "==================================================================="
echo "  BUILDING OpenJFEM sysimage ($(uname -s))"
echo "  target: $SYSIMG"
echo "==================================================================="
echo
echo "  *** PLEASE WAIT ***  Compiling OpenJFEM + the web-server stack into a"
echo "  single native image. Several minutes; this is normal."
echo

if ! command -v julia >/dev/null 2>&1; then
  echo "ERROR: 'julia' was not found on PATH. Install Julia 1.12.x first." >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/build"

# deploy_fast.jl runs the precompile workload and, with --sysimage, the
# PackageCompiler build. --install-packagecompiler adds PackageCompiler if
# it is not already in the project.
julia --threads=auto --startup-file=no --project="$REPO_ROOT" \
  "$REPO_ROOT/tools/deploy_fast.jl" \
  --sysimage="$SYSIMG" \
  --install-packagecompiler "$@"

echo
if [ -f "$SYSIMG" ]; then
  echo "Done. The launchers will now use the sysimage automatically:"
  echo "  - ./jfem               (command-line runs)"
  echo "  - POST/panel_app.sh    (web app)"
else
  echo "Build did NOT produce the sysimage - see the messages above." >&2
  exit 1
fi
