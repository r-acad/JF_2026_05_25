#!/usr/bin/env bash
set -uo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deck=${1:-}
if [ -z "$deck" ]; then
    if [ "$(uname -s)" = Darwin ]; then
        deck=$(osascript -e 'POSIX path of (choose file with prompt "Choose a finite element deck")') || exit 0
    elif command -v zenity >/dev/null 2>&1; then
        deck=$(zenity --file-selection --title="Choose a finite element deck") || exit 0
    elif command -v kdialog >/dev/null 2>&1; then
        deck=$(kdialog --getopenfilename . '*.bdf *.dat *.nas') || exit 0
    else
        read -r -p 'Deck path (.bdf, .dat or .nas): ' deck
    fi
    [ -n "$deck" ] || exit 0
else
    shift
fi
bash "$root/jfem" "$deck" "$@"
result=$?
echo "JFEM finished with exit code $result. Output paths are listed above."
if [ "${OPENJFEM_NO_PAUSE:-}" != 1 ] && [ -t 0 ]; then
    read -r -p 'Press Return to close. ' answer
fi
exit "$result"
