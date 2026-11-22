#!/usr/bin/env python3
"""Count `.wcp` packages sitting in Madeira's Import folder, inside LiveContainer.

    tools/local/wcp-count.py [--list]

Prints a bare integer (or one file name per line with --list) and exits 0. Exits 1 if
the container cannot be reached, which is DIFFERENT from "no packages": a caller that
treats an unreachable container as zero silently skips the install step and then
measures the previous build, which has already happened here twice.

This exists as a file rather than a heredoc inside dev-run-fh6.sh because a heredoc in
command substitution is exactly the kind of thing that fails quietly: the previous
inline version printed a python traceback's absence and returned "0" for a folder that
had a package in it.
"""

import asyncio
import os
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

UDID = os.environ.get("IOSDEV_UDID", "00008150-001564AE3407801C")
BUNDLE = os.environ.get("LC_BUNDLE", "com.kdt.livecontainer.4CDWTGR84Z")
IMPORT = ("Documents/Data/Application/"
          "EDAFB512-48D7-4839-98DA-E66816D6174E/Documents/Import")


async def main():
    want_list = "--list" in sys.argv[1:]
    lockdown = await create_using_usbmux(serial=UDID)
    try:
        svc = await HouseArrestService.create(lockdown, BUNDLE)
        names = [e for e in await svc.listdir(IMPORT) if e.lower().endswith(".wcp")]
    finally:
        await lockdown.close()
    if want_list:
        for n in sorted(names):
            print(n)
    else:
        print(len(names))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as exc:            # unreachable container is not "zero packages"
        print(f"wcp-count: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
