#!/usr/bin/env python3
"""Pull a file out of Madeira's guest container inside LiveContainer.

    tools/local/afc-pull.py <remote> <local> [bundle-id]

Why this exists instead of `pymobiledevice3 apps pull`. That command asks the
device's AFC service to open the file, and AFC in this container refuses to open
a file with more than one hard link: FILE_OPEN fails with status 1 ("unknown"),
not the status 8 ("not found") that a missing path gives, so it reads like a
transport fault rather than a policy one.

That is not an edge case here. `LogStore.startSessionLog` deliberately hard-links
the live log to `Documents/logs/<program>-<stamp>.txt` so a run can be found by
name without renaming anything, which makes `madeira-log.txt` nlink=2 for the
whole session. Measured 2026-11-21:

    madeira-log.txt                  nlink 2  -> FILE_OPEN status 1
    madeira-log.prev.txt             nlink 2  -> FILE_OPEN status 1
    madeira-last-game-log.txt        nlink 1  -> reads fine
    every logs/<program>-<stamp>.txt nlink 1  -> reads fine (rotated, link dropped)

So: stat first, and when nlink > 1, find the redundant name under `logs/` (same
inode: identical size and mtime) and unlink THAT one, leaving the name the app
writes to intact. Nothing is lost -- the inode stays reachable as the file we are
reading, and the app prunes `logs/` itself (keeps the newest 40). Re-creating the
link afterwards is not possible: AFC's MAKE_LINK answers status 15 here.

Paths are relative to the container root, i.e. the same form
`pymobiledevice3 apps pull` takes ("Documents/...").
"""

import asyncio
import os
import sys

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

UDID = os.environ.get("IOSDEV_UDID", "00008150-001564AE3407801C")
DEFAULT_BUNDLE = os.environ.get("LC_BUNDLE", "com.kdt.livecontainer.4CDWTGR84Z")


async def read_all(svc, path):
    data = await svc.get_file_contents(path)
    if hasattr(data, "__aiter__"):
        return b"".join([chunk async for chunk in data])
    return data


def same_file(a, b):
    try:
        return (a.get("st_size") == b.get("st_size")
                and str(a.get("st_mtime")) == str(b.get("st_mtime")))
    except Exception:
        return False


async def drop_extra_link(svc, path, info):
    """Unlink a redundant name for the same inode under a sibling `logs/` directory."""
    parent, name = os.path.split(path)
    for candidate_dir in ("logs", "Documents/logs"):
        directory = os.path.join(parent, candidate_dir) if candidate_dir == "logs" else \
            os.path.join(os.path.dirname(parent), candidate_dir)
        try:
            entries = await svc.listdir(directory)
        except Exception:
            continue
        for entry in entries:
            candidate = f"{directory}/{entry}"
            if candidate == path:
                continue
            try:
                other = await svc.stat(candidate)
            except Exception:
                continue
            if same_file(info, other):
                await svc.rm_single(candidate, force=True)
                print(f"afc-pull: unlinked redundant name {candidate} "
                      f"(same inode as {name}); AFC will not open nlink>1", file=sys.stderr)
                return True
    return False


async def main():
    remote = sys.argv[1]
    local = sys.argv[2]
    bundle = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_BUNDLE

    lockdown = await create_using_usbmux(serial=UDID)
    try:
        svc = await HouseArrestService.create(lockdown, bundle)
        info = await svc.stat(remote)
        nlink = int(info.get("st_nlink") or 1)
        if nlink > 1:
            if not await drop_extra_link(svc, remote, info):
                print(f"afc-pull: {remote} has nlink={nlink} and no redundant name was found; "
                      "AFC will probably refuse it", file=sys.stderr)
            else:
                info = await svc.stat(remote)
                print(f"afc-pull: {remote} now nlink={info.get('st_nlink')}", file=sys.stderr)
        data = await read_all(svc, remote)
        with open(local, "wb") as out:
            out.write(data)
        print(f"afc-pull: {len(data)} bytes -> {local}", file=sys.stderr)
    finally:
        await lockdown.close()


if __name__ == "__main__":
    asyncio.run(main())
