#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Package rebuilt Windows PE libraries as a .wcp Madeira can import.
#
#   tools/wcp/make-wine-wcp.sh <version-name> <dll>... [--out <file.wcp>]
#   -> dist/<version-name>-wine.wcp
#
# This is the packaging twin of push-wine-to-device.sh: that script writes into a
# component on a paired phone, this one emits the same component as a file so it
# can be imported through the app's file picker (or handed to someone else).
# Every .dll lands in a folder named after the machine it was built for, which is
# what WCPInstaller.layout(kind: .wine) keys the prefix token off:
#   i386-windows/...      -> ${syswow64}/<name>
#   aarch64-windows/...   -> ${aarch64}/<name>   (sysaa64 in an ARM64EC session)
#   anything else         -> ${system32}/<name>   (arm64ec-windows included)
#
# Only PE modules belong here. The iOS unix layer (build/ntdll-unix/*.c) is
# compiled into the app binary, so a fix there still needs a new Madeira build.
set -euo pipefail

VERSION="${1:?usage: make-wine-wcp.sh <version-name> <dll>... [--out <file.wcp>]}"
shift
OUTFILE=""
DLLS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUTFILE="${2:?--out needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) DLLS+=("$1"); shift ;;
    esac
done
[ "${#DLLS[@]}" -gt 0 ] || { echo "no .dll given" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stage each dll under a machine folder so the importer can resolve a token.
ENTRIES=()
for dll in "${DLLS[@]}"; do
    [ -f "$dll" ] || { echo "missing $dll" >&2; exit 1; }
    case "$(basename "$dll")" in
        *.dll|*.drv|*.cpl) ;;
        *) echo "not a PE module: $dll" >&2; exit 1 ;;
    esac
    machine="$(basename "$(dirname "$dll")")"
    case "$machine" in
        i386-windows|i386-unix|aarch64-windows|arm64-windows|arm64ec-windows|x86_64-windows) ;;
        *) echo "cannot tell the machine for $dll (parent dir is '$machine')" >&2; exit 1 ;;
    esac
    mkdir -p "$WORK/files/$machine"
    cp "$dll" "$WORK/files/$machine/$(basename "$dll")"
    ENTRIES+=("files/$machine/$(basename "$dll")")
done

DEST="${OUTFILE:-$ROOT/dist/$VERSION-wine.wcp}"
mkdir -p "$(dirname "$DEST")"

python3 - "$WORK/profile.json" "$VERSION" "${ENTRIES[@]}" <<'PY'
import json, sys

path, version = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
profile = {
    "type": "Wine",
    "versionName": version,
    "versionCode": 1,
    "description": "Windows libraries packaged by tools/wcp/make-wine-wcp.sh.",
    # The importer derives the prefix paths from the folder names, so `target`
    # only has to describe the same intent for readers of the package.
    "files": [
        {
            "source": f,
            "target": "${system32}/" + f.rsplit("/", 1)[-1]
                      if "aarch64-windows" not in f and "arm64-windows" not in f
                      and "i386-windows" not in f
                      else ("${syswow64}/" if "i386-windows" in f else "${aarch64}/")
                           + f.rsplit("/", 1)[-1],
        }
        for f in files
    ],
}
json.dump(profile, open(path, "w"), indent=2)
print("files: %d" % len(profile["files"]))
PY

( cd "$WORK" && tar -cf - profile.json files ) | zstd -q -19 -o "$DEST"

for dll in "${DLLS[@]}"; do
    printf 'dll  %-24s %s\n' "$(basename "$dll")" "$(shasum -a 256 "$dll" | cut -c1-64)"
done
echo "wcp  $DEST ($(stat -f%z "$DEST") bytes)"
