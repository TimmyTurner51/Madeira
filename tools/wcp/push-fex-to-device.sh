#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Push a built iOS FEX module into Madeira's installed FEX component on a paired
# iPhone, over devicectl.
#
#   tools/wcp/push-fex-to-device.sh <libarm64ecfex.dll> [version-name]
#
# The FEX loop is then build -> push -> relaunch -> read the log, with no file
# picker, no screen automation and no IPA: Madeira links
# Documents/Components/<id>/files/... over drive_c/windows/system32/xtajit64.dll
# at the start of the next session (WineProcessBridge.m, madeira_wcp_apply), which
# happens after the bundle's own pass, and the component's symlink replaces it.
#
# state.json is the list WineProcessBridge.m reads, so this rewrites the entry in
# place: the environment the package already set is carried over untouched. Quit
# Madeira first; it keeps its own copy of the list in memory and would save it
# back over this one if you toggle a component in the UI.
set -euo pipefail

DLL="${1:?usage: push-fex-to-device.sh <libarm64ecfex.dll> [version-name]}"
VERSION="${2:-}"
[ -f "$DLL" ] || { echo "missing $DLL" >&2; exit 1; }
command -v iosdev >/dev/null || PATH="$HOME/bin:$PATH"
command -v iosdev >/dev/null || { echo "iosdev is required (put it on PATH or in ~/bin)" >&2; exit 1; }

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
fex = [c for c in state.get("components", []) if c.get("kind") == "fex"]
if not fex:
    sys.exit("no FEX component in state.json: import one in the app once, then this script maintains it")
print(fex[0]["id"])
PY
)"

REMOTE="$MAD/Components/$ID/files/lib/wine/aarch64-windows/libarm64ecfex.dll"
iosdev app-put "$DLL" "$REMOTE" >/dev/null
echo "dll    $(shasum -a 256 "$DLL" | cut -c1-64)"
echo "       $REMOTE"

python3 - "$TMP/state.json" "$DLL" "${VERSION:-}" <<'PY'
import hashlib, json, os, sys, time

path, dll, version = sys.argv[1], sys.argv[2], sys.argv[3]
state = json.load(open(path))
entry = [c for c in state["components"] if c.get("kind") == "fex"][0]

# Bare path: the staging payload/ directory is what became the component folder,
# so a recorded "payload/..." prefix points at nothing (WineProcessBridge.m still
# falls back for packages installed before that was fixed).
entry["layout"] = [{"source": "files/lib/wine/aarch64-windows/libarm64ecfex.dll",
                    "dest": "${system32}/xtajit64.dll"}]
entry["fileCount"] = 1
entry["enabled"] = True
if version:
    entry["versionName"] = version
    entry["name"] = version
entry["versionCode"] = int(entry.get("versionCode") or 0) + 1
entry["installedAt"] = time.time()
entry["sha256"] = hashlib.sha256(open(dll, "rb").read()).hexdigest()
entry.setdefault("notes", []).append("Pushed by tools/wcp/push-fex-to-device.sh")

json.dump(state, open(path, "w"), indent=2, sort_keys=True)
print(f"entry  {entry['id']}: {entry['name']} (versionCode {entry['versionCode']})")
PY

iosdev app-put "$TMP/state.json" "$STATE" >/dev/null
echo "state  $STATE"

cat <<'EOF'

Relaunch Madeira and start the game, then check the module that actually loaded:
    iosdev mad-log | rg '\[build-id\]'
EOF
