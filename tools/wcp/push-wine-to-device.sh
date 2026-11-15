#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Push rebuilt Windows PE libraries into a Madeira Wine component on a paired
# iPhone, over devicectl -- no IPA, no file picker, no screen automation.
#
#   tools/wcp/push-wine-to-device.sh <dll-or-directory>... [--name <version>]
#
# This is the Wine-side twin of push-fex-to-device.sh, for the other half of the
# Forza fix surface: a .wcp can replace any PE module in the prefix, so a fix
# that lives in a Windows DLL (ucrtbase, kernel32, d3d9, vkd3d, dxgi, ...) ships
# as a component.
#
# Modules Wine resolves out of the app bundle -- ntdll, xtajit64 -- are the
# exception. The prefix link WineProcessBridge.m makes over them is shadowed by
# the bundle's own arm64ec-windows copy, so this script writes those two into
# the bundle as well. Without that second copy the run is a no-op: on
# 2026-11-15 five pushes resolved to a months-old ntdll/xtajit64 and the crash
# stayed byte-identical because none of the patched code ever executed.
#
# It can NOT replace the iOS unix layer (build/ntdll-unix/*.c: virtual_ios.c,
# signal_arm64_ios.c, loader_ios.c). That is compiled into the app binary
# (libntdll_unix.a), not a PE, so a fix there needs a new build of Madeira.
# Rule of thumb: if the crash names a .dll and the fix is in wine/dlls/<lib>,
# it belongs here; if it names a pool address or the JIT, it does not.
#
# Layout follows WCPInstaller.layout(kind: .wine), so a component installed here
# and one installed through the app resolve to the same prefix paths:
#   i386-windows/...      -> ${syswow64}/<name>
#   aarch64-windows/...   -> ${aarch64}/<name>   (sysaa64 in an ARM64EC session)
#   anything else         -> ${system32}/<name>
#
# state.json is the list WineProcessBridge.m reads, so the entry is rewritten in
# place and the package's existing environment is carried over untouched. Quit
# Madeira first: it keeps its own copy of the list in memory and would save it
# back over this one if you toggle a component in the UI.
set -euo pipefail

NAME=""
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="${2:?--name needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FILES+=("$1"); shift ;;
    esac
done
[ "${#FILES[@]}" -gt 0 ] || { echo "usage: push-wine-to-device.sh <dll-or-directory>... [--name <version>]" >&2; exit 1; }

command -v iosdev >/dev/null || PATH="$HOME/bin:$PATH"
command -v iosdev >/dev/null || { echo "iosdev is required (put it on PATH or in ~/bin)" >&2; exit 1; }

# Expand directories, keep files whose parent directory names the machine.
DLLS=()
for f in "${FILES[@]}"; do
    if [ -d "$f" ]; then
        while IFS= read -r p; do DLLS+=("$p"); done < <(find "$f" -type f -name '*.dll')
    elif [ -f "$f" ]; then
        DLLS+=("$f")
    else
        echo "missing $f" >&2; exit 1
    fi
done
[ "${#DLLS[@]}" -gt 0 ] || { echo "no .dll among the arguments" >&2; exit 1; }

# LiveContainer's appDataContainer; the guest app's Documents is MAD/Documents.
MAD="Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents"
STATE="$MAD/Components/state.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

iosdev app-get "$STATE" "$TMP/state.json" >/dev/null 2>&1 || true
[ -s "$TMP/state.json" ] || { echo "could not read $STATE; is the phone connected and Madeira installed?" >&2; exit 1; }

ID="$(python3 - "$TMP/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
wine = [c for c in state.get("components", []) if c.get("kind") == "wine"]
print(wine[0]["id"] if wine else "")
PY
)"

if [ -z "$ID" ]; then
    ID="madeira-wine-wine"
    echo "no Wine component in state.json yet; creating $ID"
fi

ROOT="$MAD/Components/$ID"
# One folder per machine, so a dll and its 32-bit namesake can coexist. The
# component's layout records the bare "files/..." path (a "payload/" prefix
# points at nothing -- the staging payload directory is what became the folder).
DEST="$ROOT/files/arm64ec-windows"
REMOTE_DLLS=()

for dll in "${DLLS[@]}"; do
    base="$(basename "$dll")"
    lower="$(printf '%s' "$dll" | tr '[:upper:]' '[:lower:]')"
    case "/$lower/" in
        */i386-windows/*|*/i386-unix/*)  token='${syswow64}' ;;
        */aarch64-windows/*|*/arm64-windows/*) token='${aarch64}' ;;
        *) token='${system32}' ;;
    esac
    # 2026-11-15: a ${system32} overlay of ARM64EC kernelbase made ARM64
    # wineboot load it as kernel32's import (c000007b, session died in 0.8s).
    # system32 is the first search path for every process, including the 0xaa64
    # host. ARM64EC copies of the boot DLLs belong in sysx64 (the EC farm);
    # ntdll is loaded from the bundle, so it needs no prefix link at all.
    case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
        ntdll.dll) token="" ;;
        kernelbase.dll|kernel32.dll) token='${sysx64}' ;;
    esac
    # ntdll: skip the prefix link entirely (empty token).
    if [ -z "$token" ]; then
        if iosdev app-put "$dll" "Documents/Applications/com.willfaust.madeora.app/arm64ec-windows/$base" >/dev/null 2>&1; then
            printf '%-34s %s  -> app bundle arm64ec-windows/%s (the copy that loads; no prefix link)\n' \
                "$base" "$(shasum -a 256 "$dll" | cut -c1-16)" "$base"
        fi
        continue
    fi
    iosdev app-put "$dll" "$DEST/$base" >/dev/null
    REMOTE_DLLS+=("$base|$token")
    printf '%-34s %s  -> %s/%s\n' "$base" "$(shasum -a 256 "$dll" | cut -c1-16)" "$token" "$base"

    # The ${system32} link is shadowed for the modules Wine takes from the app
    # bundle (ntdll, xtajit64): the bundle's own arm64ec-windows copy wins, so
    # a component written only into the prefix changes nothing at runtime. Write
    # the bundle copy too. Best effort -- a normal install has no writable
    # bundle, and then the component link is all there is.
    if iosdev app-put "$dll" "Documents/Applications/com.willfaust.madeora.app/arm64ec-windows/$base" >/dev/null 2>&1; then
        printf '%-34s %s  -> app bundle arm64ec-windows/%s (the copy that loads)\n' '' 'bundle' "$base"
    fi
done
echo "       $DEST"

if [ "${#REMOTE_DLLS[@]}" -eq 0 ]; then
    echo "no prefix links (bundle copies only); state.json unchanged"
    exit 0
fi

python3 - "$TMP/state.json" "$ID" "$NAME" "${REMOTE_DLLS[@]}" <<'PY'
import hashlib, json, sys, time

path, cid, version = sys.argv[1], sys.argv[2], sys.argv[3]
pairs = [a.split("|", 1) for a in sys.argv[4:]]
state = json.load(open(path))
components = state.setdefault("components", [])
entry = next((c for c in components if c.get("id") == cid), None)

now = time.time()
if entry is None:
    entry = {
        "id": cid,
        "name": version or "Madeira Wine",
        "kind": "wine",
        "type": "Wine",
        "versionName": version or "Madeira Wine",
        "versionCode": 0,
        "detail": "Windows libraries pushed by tools/wcp/push-wine-to-device.sh.",
        "enabled": True,
        "installedAt": now,
        "sourceFile": "push-wine-to-device.sh",
        "notes": [],
    }
    components.append(entry)

# Merge into the existing layout. Replacing it wholesale is how an
# ntdll+kernelbase push on 2026-11-15 dropped every other Wine overlay and
# put ARM64EC kernelbase on system32, which ARM64 wineboot then loaded
# (c000007b). A dest of "" means "bundle only, no prefix link".
layout = [x for x in (entry.get("layout") or []) if isinstance(x, dict)]
by_dest = {x.get("dest"): i for i, x in enumerate(layout) if x.get("dest")}
for name, token in pairs:
    if not token:
        continue
    item = {"source": "files/arm64ec-windows/" + name, "dest": token + "/" + name}
    if item["dest"] in by_dest:
        layout[by_dest[item["dest"]]] = item
    else:
        by_dest[item["dest"]] = len(layout)
        layout.append(item)
entry["layout"] = layout
entry["fileCount"] = len(layout)
entry["enabled"] = True
if version:
    entry["versionName"] = version
    entry["name"] = version
entry["versionCode"] = int(entry.get("versionCode") or 0) + 1
entry["installedAt"] = now
entry["sha256"] = hashlib.sha256("".join(sorted(n for n, _ in pairs)).encode()).hexdigest()
entry.setdefault("notes", []).append("Pushed by tools/wcp/push-wine-to-device.sh")

json.dump(state, open(path, "w"), indent=2, sort_keys=True)
print(f"entry  {entry['id']}: {entry['name']} ({len(pairs)} dll(s), versionCode {entry['versionCode']})")
PY

iosdev app-put "$TMP/state.json" "$STATE" >/dev/null
echo "state  $STATE"

cat <<'EOF'

Relaunch Madeira and start the game, then confirm the component was applied:
    iosdev mad-log | rg '\[wcp\]|\[build-id\]'
EOF
