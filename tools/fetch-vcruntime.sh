#!/usr/bin/env bash
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$R/app/Madeira/x86_64-vcruntime"
URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/madeira-vcrt.XXXXXX" 2>/dev/null || mktemp -d)"

trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"
mkdir -p "$TMP/cab_out" "$TMP/stage"

echo "fetching VC_redist.x64.exe..."
curl --proto '=https' --tlsv1.2 -fL --retry 3 -o "$TMP/VC_redist.x64.exe" "$URL"

if command -v shasum >/dev/null 2>&1; then
    echo -n "downloaded sha256: "
    shasum -a 256 "$TMP/VC_redist.x64.exe" | awk '{print $1}'
fi

SEVENZIP=""
if command -v 7zz >/dev/null 2>&1; then
    SEVENZIP="7zz"
elif command -v 7z >/dev/null 2>&1; then
    SEVENZIP="7z"
else
    echo "error: 7zz or 7z not found (brew install sevenzip)" >&2
    exit 1
fi

# The installer is a PE whose overlay chains cabinets without .cab names:
# a metadata cabinet followed by the component cabinets (each a raw MSCF
# stream, some nested one level deeper). 7-Zip only opens the first cabinet
# of a blob, so carve every MSCF offset and extract each slice until no new
# cabinets appear.
SEVENZIP="$SEVENZIP" python3 - "$TMP" <<'PY'
import os
import subprocess
import sys
from pathlib import Path

tmp = Path(sys.argv[1])
sevenzip = os.environ['SEVENZIP']
out = tmp / 'cab_out'
seen = set()


def carve(blob, depth):
    if depth > 3:
        return
    data = blob.read_bytes()
    off = data.find(b'MSCF')
    while off != -1:
        if (blob.stat().st_size, off) not in seen:
            seen.add((blob.stat().st_size, off))
            slice_file = tmp / 'slice.bin'
            slice_file.write_bytes(data[off:])
            subprocess.run([sevenzip, 'x', str(slice_file), f'-o{out}', '-y'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        off = data.find(b'MSCF', off + 1)


carve(tmp / 'VC_redist.x64.exe', 0)
rounds = 0
while rounds < 3:
    rounds += 1
    for f in sorted(out.rglob('*')):
        if f.is_file() and f.stat().st_size > 8:
            carve(f, rounds)
PY

WANTED=(
    "concrt140.dll"
    "msvcp140.dll"
    "msvcp140_1.dll"
    "msvcp140_2.dll"
    "msvcp140_atomic_wait.dll"
    "msvcp140_codecvt_ids.dll"
    "vcamp140.dll"
    "vccorlib140.dll"
    "vcomp140.dll"
    "vcruntime140.dll"
    "vcruntime140_1.dll"
    "vcruntime140_threads.dll"
    "mfc140.dll"
    "mfc140u.dll"
)

is_x64() {
    python3 -c '
import struct, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = f.read(1024)
        if len(d) >= 0x40 and d[:2] == b"MZ":
            pe = struct.unpack_from("<I", d, 0x3c)[0]
            m = struct.unpack_from("<H", d, pe + 4)[0]
            if m == 0x8664:
                sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$1" 2>/dev/null
}

missing=()
for name in "${WANTED[@]}"; do
    base="${name%.dll}"
    # the exact amd64 component first, then the plain name, then name
    # prefixes (F_CENTRAL_...); only an x64 image is ever copied
    matches=()
    for pat in "${name}_amd64" "$name" "${name}*" "F_CENTRAL_${base}_*"; do
        while IFS= read -r -d '' match; do
            if is_x64 "$match"; then
                matches+=("$match")
            fi
        done < <(find "$TMP/cab_out" -type f -iname "$pat" -print0)
        if [ "${#matches[@]}" -gt 0 ]; then
            break
        fi
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        missing+=("$name")
    else
        cp "${matches[0]}" "$TMP/stage/$name"
    fi
done

if [ "${#missing[@]}" -ne 0 ]; then
    echo "error: ${#missing[@]} of ${#WANTED[@]} files not found in installer:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    exit 1
fi

cp "$TMP/stage/"*.dll "$DEST/"
echo "${#WANTED[@]}/${#WANTED[@]} runtime files copied to $DEST"

python3 "$R/tests/host/check-vcruntime.py" --strict
