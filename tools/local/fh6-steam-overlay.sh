#!/bin/bash
# Turn Steam's in-process overlay hook off (or back on) inside the FH6 prefix.
#
#   tools/local/fh6-steam-overlay.sh off      # rename GameOverlayRenderer64.dll
#   tools/local/fh6-steam-overlay.sh on       # restore it
#   tools/local/fh6-steam-overlay.sh status
#
# Why. FH6 loaded to the title screen at 60 FPS, then on pressing A to enter the
# world it stopped presenting entirely and never recovered (see
# docs/compatibility/forza-horizon-6-ios.md §9.20): presents frozen at 14281 for
# 300+ s, no frames at all, ~20 % of one core, GPU idle, rdKB=0, no DNS and no
# NtCreateFile after the freeze, 14 threads parked >60 s, and a static critical
# section inside steamclient64.dll (steamclient64.dll+0x1753230) accounting for
# 100 % of sampled contended enters. gameoverlayrenderer64.dll was resident in the
# process with a thread parked in the JIT pool copy of its own image.
#
# The overlay renderer hooks the DXGI/D3D12 present path, which the title only
# exercises once it starts drawing the world. Neutralising it (a rename, so it
# can be put back) took the same launch path to the open world: presents climbed
# 1603 -> 4769 over 90 s, 35-42 FPS at 23.6-28.7 ms/frame, GPU 74 %, and the
# "Unable to join session" message no longer appeared.
#
# The rename lives in the guest prefix, not the app bundle: nothing is re-signed
# and nothing is reinstalled. Steam can restore the file during its own update,
# so this is idempotent and safe to re-run.
set -u
cd "$(dirname "$0")/../.." || exit 1

MODE="${1:-status}"
export IOSDEV_UDID="${IOSDEV_UDID:-00008150-001564AE3407801C}"
export LC_BUNDLE="${LC_BUNDLE:-com.kdt.livecontainer.4CDWTGR84Z}"
PMD3="${IOSDEV_PMD3:-$HOME/Library/Application Support/pipx/venvs/pymobiledevice3/bin/python}"
[ -x "$PMD3" ] || PMD3="$HOME/.local/bin/pymobiledevice3"

exec "$PMD3" - "$MODE" <<'PY'
import asyncio, sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
import os

MODE = sys.argv[1]
UDID = os.environ["IOSDEV_UDID"]
BUNDLE = os.environ["LC_BUNDLE"]
# The prefix is the guest container the launcher creates for its Windows side.
PREFIX = "Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents/wine/drive_c"
STEAM = f"{PREFIX}/Program Files (x86)/Steam"
LIVE = f"{STEAM}/GameOverlayRenderer64.dll"
OFF = LIVE + ".off"


async def stat(svc, p):
    try:
        return await svc.stat(p)
    except Exception:
        return None


async def main():
    ld = await create_using_usbmux(serial=UDID)
    try:
        svc = await HouseArrestService.create(ld, BUNDLE)
        live, off = await stat(svc, LIVE), await stat(svc, OFF)
        state = ("on" if live else "off") if (live or off) else "missing"
        if MODE == "status":
            print(f"steam overlay hook: {state}"
                  + (f"  (live {live['st_size']} B)" if live else "")
                  + (f"  (disabled copy {off['st_size']} B)" if off else ""))
            return 0
        if MODE == "off":
            if off and not live:
                print("already off"); return 0
            if not live:
                print("error: GameOverlayRenderer64.dll is missing; nothing to disable", file=sys.stderr)
                return 1
            await svc.rename(LIVE, OFF)
            print(f"overlay hook disabled ({live['st_size']} B kept as GameOverlayRenderer64.dll.off)")
            return 0
        if MODE == "on":
            if live and not off:
                print("already on"); return 0
            if not off:
                print("error: no GameOverlayRenderer64.dll.off to restore", file=sys.stderr)
                return 1
            if live:
                await svc.rm_single(LIVE, force=True)
            await svc.rename(OFF, LIVE)
            print("overlay hook restored")
            return 0
        print("usage: fh6-steam-overlay.sh off|on|status", file=sys.stderr)
        return 2
    finally:
        await ld.close()


sys.exit(asyncio.run(main()))
PY
