#!/bin/bash
# One bisection step: build a kernel32 with prologues on the named exports, push it
# into the live component, launch, and report whether the game process spawned.
#
#   tools/local/k32-bisect.sh <names.txt> [<label>]
#
# The component and its state.json entry are left untouched, so a step costs one
# launch (~170 s) instead of a re-import (~70 s on top). Exit status is 0 when the
# game spawned (the patch set is safe) and 1 when it did not.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMES="${1:?usage: k32-bisect.sh <names.txt> [label]}"
LABEL="${2:-$(basename "$NAMES" .txt)}"
G="Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents"
COMP="$G/Components/FH6-iOS-1.13-k32one-pe-wine/files/lib/wine/arm64ec-windows/kernel32-one.dll"
OUT="/tmp/k32-$LABEL.dll"

cd "$R"
python3 tools/local/pe-thunks-apply.py app/Madeira/arm64ec-windows/kernel32.dll "$OUT" "$NAMES" \
    | head -1 || exit 2
python3 tools/local/pe-thunks.py "$OUT" | grep machine= || exit 2
DEVICE_FILE_ROUTE=pmd3 tools/local/device-file.sh put "$OUT" "$COMP" 2>&1 | tail -1 || exit 2

./tools/local/dev-run-fh6.sh --wait 90 --no-install >/dev/null 2>&1
cp /tmp/fh6-run.txt "/tmp/run-$LABEL.txt" 2>/dev/null
n=$(LC_ALL=C grep -ac 'phase\] spawn.*forzahorizon' "/tmp/run-$LABEL.txt" 2>/dev/null)
if [ "$n" -gt 0 ]; then echo "RESULT $LABEL: game SPAWNED -> set is safe"; exit 0
else echo "RESULT $LABEL: game BLOCKED -> set contains a culprit"; exit 1; fi
