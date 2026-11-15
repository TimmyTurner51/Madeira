#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rewrite Wine-only PE export/import names that Forza hashes for.

The VEH at forzahorizon6.exe+0x53D9270 calls 0x1453E2A50, which FNV-1a's every
loaded module's export names and looks for 0xb2dc38a8e4baecd. That value is
exactly wine_get_unix_file_name (kernel32). Windows does not export it. Finding
it sets a flag that skips decrypt-map setup and makes the handler return
CONTINUE_SEARCH on the encrypted EA prologues.

The documented hash is only that unix name (and the dos sibling is the same
class of Wine-only kernel32 export). wine_get_version must stay: FEX's ARM64EC
module does GetProcAddress(ntdll, "wine_get_version") to set IsWine, and hiding
it made OvercommitTracker / HostFeatures run the native Windows path.
wine_server_* is left alone; Wine calls those by name.

GetProcAddress("wine_get_unix_file_name") then returns NULL; madeira-d3d12
already has a fallback.
"""
from __future__ import annotations

import os
import sys

# Longer names first so a short needle cannot rewrite inside a long one.
PAIRS = [
    (b"wine_get_unix_file_name", b"xine_get_unix_file_name"),
    (b"wine_get_dos_file_name", b"xine_get_dos_file_name"),
]

for old, new in PAIRS:
    if len(old) != len(new):
        raise SystemExit(f"replacement length mismatch: {old!r} vs {new!r}")


def rewrite(path: str) -> int:
    orig = open(path, "rb").read()
    data = orig
    total = 0
    for old, new in PAIRS:
        n = data.count(old)
        if n:
            data = data.replace(old, new)
            total += n
    if data != orig:
        open(path, "wb").write(data)
    return total


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: hide-wine-exports.py <dll>...", file=sys.stderr)
        return 2
    for path in argv[1:]:
        base = os.path.basename(path).lower()
        if base == "xtajit64.dll":
            print(f"{path}: skipped (FEX GetProcAddress wine_get_version)")
            continue
        print(f"{path}: {rewrite(path)} replacement(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
