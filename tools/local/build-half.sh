#!/bin/bash
# Build the Wine unix half, prove the artifact is FRESH, package it, and push it to the
# phone's Import folder. One command for the whole "change the unix half" loop.
#
#   tools/local/build-half.sh <version-name> [description]
#
# Why the freshness check exists, in the plainest terms: build/ntdll-unix/build.sh does
# NOT produce libntdll_unix.dylib. It compiles every object and links the static archive
# that goes into the app. The dylib -- the thing a .wcp ships and the thing that actually
# runs when a component is installed -- is a separate script, build-dylib.sh. Skipping it
# is invisible: build.sh prints "41 succeeded", ar rebuilds the archive, the dylib keeps
# its old timestamp, and make-native-wcp.sh happily signs and packages the OLD library.
#
# That happened here for five consecutive probe builds (ml2035..ml2039). Each one
# reported success, installed, loaded, and produced the previous build's output. It cost
# a set of runs that looked like "the probe prints nothing", and one wrong conclusion
# about the component override not being used at all. So this script refuses to package
# a dylib older than its newest source.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

VERSION="${1:?usage: build-half.sh <version-name> [description]}"
DESC="${2:-Unix half build}"
HALF=build/ntdll-unix
DY="$HALF/libntdll_unix.dylib"

echo "== compiling objects + archive"
./$HALF/build.sh 2>&1 | LC_ALL=C grep -E "FAILED|Results:|error:" || true

echo "== linking the dylib (the step build.sh does not do)"
./$HALF/build-dylib.sh 2>&1 | tail -2

# Freshness: the dylib must be at least as new as every source it was built from.
newest=$(ls -t "$HALF"/*.c "$HALF"/*.h 2>/dev/null | head -1)
if [ -n "$newest" ] && [ "$newest" -nt "$DY" ]; then
    echo "STALE: $DY is older than $newest -- packaging it would ship the previous build." >&2
    echo "       (This is the exact failure this script exists to prevent.)" >&2
    exit 1
fi
echo "== freshness ok: $(basename "$DY") $(date -r "$DY" '+%H:%M:%S') newer than $(basename "$newest")"

echo "== signing and packaging"
./tools/wcp/make-native-wcp.sh "$VERSION" "$DY" "$DESC" 2>&1 | tail -1

echo "== pushing to the guest Import folder"
WCP="dist/$VERSION-native.wcp"
~/Library/Application\ Support/pipx/venvs/pymobiledevice3/bin/python - "$WCP" <<'PY'
import asyncio, sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
src = sys.argv[1]
dst = ("Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E"
       "/Documents/Import/" + src.rsplit("/", 1)[-1])
async def main():
    lk = await create_using_usbmux(serial="00008150-001564AE3407801C")
    svc = await HouseArrestService.create(lk, "com.kdt.livecontainer.4CDWTGR84Z")
    await svc.push(src, dst)
    print("pushed", dst.rsplit("/", 1)[-1], (await svc.stat(dst)).get("st_size"), "bytes")
    await lk.close()
asyncio.run(main())
PY

echo "== done. Next: tools/local/dev-run-fh6.sh (it installs, restarts once more, then launches)"
