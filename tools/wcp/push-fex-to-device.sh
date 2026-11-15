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

# The component link is NOT what the session loads. Wine resolves xtajit64.dll
# out of the app bundle's own arm64ec-windows folder, and the bundle's copy
# shadows the ${system32}/xtajit64.dll link that WineProcessBridge.m creates
# over the prefix. A component pushed without this second copy is a no-op: on
# 2026-11-15 five FEX pushes in a row all resolved to the old bundle DLL, and
# the crash stayed byte-identical because none of the patched code ever ran.
# The bundle copy lives in the *host app's own* data container, not in MAD. The
# path the session logs is
#   /…/Data/Application/<container>/Documents/Applications/<appid>/arm64ec-windows/<dll>
# where <container> is the container the running session reports, and it is NOT
# always the LiveContainer appDataContainer that MAD points at. On 2026-11-15
# this script still wrote to "$MAD/Applications/…", which does not exist, so
# every push printed "SKIPPED" and the session kept loading the old bundle DLL
# (build-id rev=ml908, compiled 00:26) for nine revisions of FEX work.
#
# Push to every plausible container instead of guessing one: a duplicate copy
# holding the same bytes is harmless, a missing one silently reverts a session.
APP_REL="Documents/Applications/com.willfaust.madeora.app/arm64ec-windows/xtajit64.dll"
BUNDLE_WROTE=0
for BUNDLE in \
    "Documents/Data/Application/BD038598-DE0F-4AA5-B8F3-6AC778939190/$APP_REL" \
    "$MAD/Applications/com.willfaust.madeora.app/arm64ec-windows/xtajit64.dll" \
    "Documents/Data/Application/BD038598-DE0F-4AA5-B8F3-6AC778939190/Documents/Applications/com.willfaust.madeora.app/Frameworks/arm64ec-windows/xtajit64.dll"
do
    if iosdev app-put "$DLL" "$BUNDLE" >/dev/null 2>&1; then
        echo "bundle $BUNDLE  (a copy the session may load)"
        BUNDLE_WROTE=$((BUNDLE_WROTE + 1))
    fi
done
if [ "$BUNDLE_WROTE" -eq 0 ]; then
    echo "bundle copy SKIPPED -- no known bundle path accepted the file, so the" >&2
    echo "       component link is the only path; verify with the build-id below" >&2
fi
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

That line prints "rev=<tag> compiled <date>". It MUST match the build you just
pushed. If it still shows the previous date, the session is loading a bundle
copy this script did not reach and no patch in that DLL ran -- do not read the
run's crash as evidence about the new code.
EOF
