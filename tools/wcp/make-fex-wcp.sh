#!/usr/bin/env bash
# Package a FEX ARM64EC module as a .wcp Madeira can import.
#
#   tools/wcp/make-fex-wcp.sh <version-name> <libarm64ecfex.dll> [description] [env-json]
#   -> dist/<version-name>-fex.wcp
#
# The module must be built for iOS: run build/fex-arm64ec/build.sh first, which
# leaves it at app/Madeira/arm64ec-windows/xtajit64.dll. Madeira's importer
# maps libarm64ecfex.dll to that name.
#
# env-json (optional) is a JSON object holding "environment" and/or
# "description". Its environment becomes the component's environment, which
# Madeira exports into every Wine session it starts -- the game-specific FEX
# and VKD3D settings live there, so a rebuild that dropped them would launch
# Forza with the wrong emulator configuration entirely.
# tools/wcp/fh6-fex-env.json is Forza Horizon 6's.
set -euo pipefail

VERSION="${1:?usage: make-fex-wcp.sh <version-name> <libarm64ecfex.dll> [description] [env-json]}"
DLL="${2:?missing libarm64ecfex.dll}"
DESC="${3:-FEX built from the Madeira FEX fork (branch ios-port-2607).}"
ENVJSON="${4:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$DLL" ] || { echo "missing $DLL" >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

OUT="$ROOT/dist"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/files/lib/wine/aarch64-windows"
cp "$DLL" "$WORK/files/lib/wine/aarch64-windows/libarm64ecfex.dll"

if [ -n "$ENVJSON" ] && [ -f "$ENVJSON" ]; then
    python3 - "$ENVJSON" "$WORK/profile.json" "$VERSION" "$DESC" <<'PY'
import json, sys
env_path, out_path, version, desc = sys.argv[1:5]
extra = json.load(open(env_path))
profile = {
    "type": "FEXCore",
    "versionName": version,
    "versionCode": 1,
    "description": extra.get("description", desc),
    "environment": extra.get("environment", {}),
    "files": [
        {
            "source": "files/lib/wine/aarch64-windows/libarm64ecfex.dll",
            "target": "${system32}/xtajit64.dll",
        }
    ],
}
json.dump(profile, open(out_path, "w"), indent=2)
print("environment keys: %d" % len(profile["environment"]))
PY
else
    cat > "$WORK/profile.json" <<EOF
{
  "type": "FEXCore",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "$DESC",
  "files": [
    {
      "source": "files/lib/wine/aarch64-windows/libarm64ecfex.dll",
      "target": "\${system32}/xtajit64.dll"
    }
  ]
}
EOF
fi

DEST="$OUT/$VERSION-fex.wcp"
( cd "$WORK" && tar -cf - profile.json files ) | zstd -q -19 -o "$DEST"

echo "dll  $(shasum -a 256 "$DLL" | cut -c1-64)"
echo "wcp  $DEST ($(stat -f%z "$DEST") bytes)"
