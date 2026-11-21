#!/usr/bin/env bash
# Package Madeira's FEX as the Forza Horizon 6 component, environment included.
#
#   tools/wcp/make-fh6-wcp.sh [version-name] [libarm64ecfex.dll]
#   -> dist/<version-name>-fex.wcp
#
# This is the iOS analogue of the DroidDeck `fh6-fex-droiddeck.wcp`: the FEX module plus
# the game's environment, so importing one package is the whole change. The reference
# package cannot set its own environment (DroidDeck takes it from the game's profile), and
# Madeira's importer can, so the variables ride along here instead of being typed in.
#
# Environment provenance, per ~/Projects/fh6-wine-fex/README.md step 4. Only the keys this
# FEX fork actually declares are listed: the rest (`FEX_POOL_CLONE`,
# `FEX_DISKCACHEMAXFILESIZE`, `FEX_SKIP_SRA_FLUSH`, `FEX_FH6_*`) are options of the
# reference's own patched FEX that arrive with fh6-fex 0004, and setting an unknown FEX_*
# key is a silent no-op that reads in a log like a test that ran.
#
# `VKD3D_FEATURE_LEVEL` / `VKD3D_SHADER_MODEL` are included even though Madeira's default
# Direct3D 12 route is DXMT (Metal), not vkd3d: they are the pair the reference found to
# gate the game's own "GPU unsupported" dialog, they are inert when vkd3d is not the
# renderer, and a Vulkan-route run (MADEIRA_MOLTENVK=1) needs them.
set -euo pipefail

VERSION="${1:-FH6-iOS-1.3}"
DLL="${2:-app/Madeira/arm64ec-windows/xtajit64.dll}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$ROOT/$DLL" ] && DLL="$ROOT/$DLL"
[ -f "$DLL" ] || { echo "missing $DLL (run build/fex-arm64ec/build.sh)" >&2; exit 1; }
command -v zstd >/dev/null || { echo "zstd is required (brew install zstd)" >&2; exit 1; }

OUT="$ROOT/dist"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/files/lib/wine/aarch64-windows"
cp "$DLL" "$WORK/files/lib/wine/aarch64-windows/libarm64ecfex.dll"

# FEX_SMCCHECKS=full is deliberately NOT set. The reference stack sets it, but its
# FEX carries 0002/0004 (block-level CRC validation); this port has only the checks
# that came before those, so "full" means a per-instruction check on every writable
# page in EVERY process. Measured on device 2026-11-21: with it, Steam's own client
# refuses the launch (launch-client-error=46, host result 45); remove that one key
# and the same build gets launch-client-error=0 and launch-game-running=1. The DLL
# was swapped for the stock build for that A/B, so the key is the cause, not the
# module. Re-add it once 0002/0004 land.
cat > "$WORK/profile.json" <<EOF
{
  "type": "FEXCore",
  "versionName": "$VERSION",
  "versionCode": 1,
  "description": "Forza Horizon 6: iOS FEX with fh6-fex 0001/0003 (block invalidation, L1 recommit) and the reference environment.",
  "files": [
    {
      "source": "files/lib/wine/aarch64-windows/libarm64ecfex.dll",
      "target": "\${system32}/xtajit64.dll"
    }
  ],
  "environment": {
    "FEX_TSOENABLED": "1",
    "FEX_HALFBARRIERTSOENABLED": "1",
    "FEX_VECTORTSOENABLED": "0",
    "FEX_MEMCPYSETTSOENABLED": "0",
    "FEX_DYNAMICL1CACHE": "0",
    "FEX_PROFILESTATS": "0",
    "FEX_SILENTLOG": "1",
    "FEX_HIDEHYPERVISORBIT": "1",
    "FEX_MULTIBLOCK": "1",
    "FEX_X87REDUCEDPRECISION": "1",
    "VKD3D_FEATURE_LEVEL": "12_2",
    "VKD3D_SHADER_MODEL": "6_9",
    "WINE_FAST_YIELD": "1",
    "WINEDEBUG": "-all"
  }
}
EOF

DEST="$OUT/$VERSION-fex.wcp"
# -f: a rebuilt package must replace the previous one, or the script silently ships
# yesterday's module under today's name.
( cd "$WORK" && tar -cf - profile.json files ) | zstd -q -f -19 -o "$DEST"
printf '%s  (%s)\n' "$DEST" "$(du -h "$DEST" | cut -f1)"
python3 - "$DEST" <<'PY'
import json, subprocess, sys, tarfile, tempfile, os
d = sys.argv[1]
with tempfile.TemporaryDirectory() as t:
    raw = os.path.join(t, "a.tar")
    subprocess.run(["zstd","-q","-d","-o",raw,d], check=True)
    with tarfile.open(raw) as tf:
        p = json.load(tf.extractfile("profile.json"))
    print(f"  type={p['type']} version={p['versionName']} env={len(p['environment'])} keys")
PY
