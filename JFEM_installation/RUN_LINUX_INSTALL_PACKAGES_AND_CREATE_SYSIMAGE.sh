#!/usr/bin/env bash
# ====================================================================
#  RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh  --  Linux / macOS terminal
#
#  Builds a prebuilt OpenJFEM sysimage so the solver and the web app start
#  near-instantly (including the FIRST analysis), instead of paying Julia's
#  one-time compilation on every fresh run.
#
#  HOW TO USE
#    Make it executable once, then run it:
#        chmod +x JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
#        ./JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh
#
#  WHAT IT PRODUCES
#    <repo>/sysimage/OpenJFEM_sysimage.so      (Linux)
#    <repo>/sysimage/OpenJFEM_sysimage.dylib   (macOS)
#    The launchers (jfem, POST/case_runner_web_app/RUN_PANDEATOR_MAC_LINUX.sh) load it AUTOMATICALLY when present.
#
#  NOTES
#    * Takes several minutes and uses a lot of CPU/RAM - this is normal.
#    * Installs the Julia packages from Project.toml/Manifest.toml before
#      building the image.
#    * The image is tied to THIS machine's Julia version + OS + CPU. It is NOT
#      portable: build it on each machine, and rebuild after a Julia upgrade or
#      a change to the OpenJFEM packages.
#    * If you never build it, everything still works - just slower to start.
#    * Needs a Julia 1.12.x on PATH.
# ====================================================================
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "help" ]; then
  cat <<'EOF'
Usage:
  JFEM_installation/RUN_LINUX_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.sh [deploy_fast options]

This installs OpenJFEM Julia packages, then creates:
  sysimage/OpenJFEM_sysimage.so      Linux
  sysimage/OpenJFEM_sysimage.dylib   macOS

Optional deploy_fast options such as --deck or --manifest are passed to the
sysimage precompile workload.
EOF
  exit 0
fi

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
SYSIMG="$REPO_ROOT/sysimage/OpenJFEM_sysimage.$EXT"

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

mkdir -p "$REPO_ROOT/sysimage"

echo "Step 1 of 2: installing Julia packages from Project.toml/Manifest.toml..."
julia --startup-file=no --project="$REPO_ROOT" \
  "$REPO_ROOT/JFEM_installation/julia_tools/install_julia_packages.jl" \
  --no-precompile

echo
echo "Step 2 of 2: building the OpenJFEM sysimage..."
echo

# deploy_fast.jl runs the precompile workload and, with --sysimage, the
# PackageCompiler build. --install-packagecompiler adds PackageCompiler if
# it is not already in the project.
julia --threads=auto --startup-file=no --project="$REPO_ROOT" \
  "$REPO_ROOT/JFEM_installation/julia_tools/deploy_fast.jl" \
  --sysimage="$SYSIMG" \
  --install-packagecompiler "$@"

echo
if [ -f "$SYSIMG" ]; then
  echo "Done. The launchers will now use the sysimage automatically:"
  echo "  - ./jfem               (command-line runs)"
  echo "  - POST/case_runner_web_app/RUN_PANDEATOR_MAC_LINUX.sh    (web app)"
else
  echo "Build did NOT produce the sysimage - see the messages above." >&2
  exit 1
fi
