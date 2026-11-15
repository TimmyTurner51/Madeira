#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rewrite Wine-only PE export/import names that Forza hashes for.

The VEH at forzahorizon6.exe+0x53D9270 calls 0x1453E2A50, which FNV-1a's every
loaded module's export names and looks for 0xb2dc38a8e4baecd. That value is
exactly wine_get_unix_file_name (kernel32). Windows does not export it. Finding
it sets a flag that skips decrypt-map setup and makes the handler return
CONTINUE_SEARCH on the encrypted EA prologues.

Same-length rewrite so RVAs, ordinals, and already-built IATs stay valid:
  wine_get_unix_file_name -> xine_get_unix_file_name

Wine modules that import the old name (shell32) must be rewritten too, or they
fail to bind. GetProcAddress("wine_get_unix_file_name") then returns NULL;
madeira-d3d12 already has a fallback for that.
"""
from __future__ import annotations

import sys

OLD = b"wine_get_unix_file_name"
NEW = b"xine_get_unix_file_name"

if len(OLD) != len(NEW):
    raise SystemExit("replacement must be the same length as the original")


def rewrite(path: str) -> int:
    orig = open(path, "rb").read()
    count = orig.count(OLD)
    if count:
        open(path, "wb").write(orig.replace(OLD, NEW))
    return count


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: hide-wine-exports.py <dll>...", file=sys.stderr)
        return 2
    for path in argv[1:]:
        print(f"{path}: {rewrite(path)} replacement(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
