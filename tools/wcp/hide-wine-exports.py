#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rewrite Wine-only PE export/import names that Forza hashes for.

The VEH at forzahorizon6.exe+0x53D9270 calls 0x1453E2A50, which FNV-1a's every
loaded module's export names and looks for 0xb2dc38a8e4baecd. That value is
exactly wine_get_unix_file_name (kernel32). Windows does not export it. Finding
it sets a flag that skips decrypt-map setup and makes the handler return
CONTINUE_SEARCH on the encrypted EA prologues.

ntdll also exports wine_get_version / wine_get_build_id / wine_get_host_version,
which Windows does not. Those are hashed on the same PEB walk because ntdll is
always loaded. Same-length rewrites so RVAs, ordinals, and already-built IATs
stay valid. wine_server_* is left alone; Wine calls those by name internally.

GetProcAddress("wine_get_unix_file_name") then returns NULL; madeira-d3d12
already has a fallback. wine_get_version callers (winver, winecfg, wined3d)
already tolerate NULL.
"""
from __future__ import annotations

import sys

# Longer names first so a short needle cannot rewrite inside a long one.
PAIRS = [
    (b"wine_get_unix_file_name", b"xine_get_unix_file_name"),
    (b"wine_get_dos_file_name", b"xine_get_dos_file_name"),
    (b"wine_get_host_version", b"xine_get_host_version"),
    (b"wine_get_build_id", b"xine_get_build_id"),
    (b"wine_get_version", b"xine_get_version"),
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
        print(f"{path}: {rewrite(path)} replacement(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
