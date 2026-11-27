#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""build/dxmt-patches/*.patch must capture exactly the changes this repository
carries on top of the pinned dxmt: the dxmt working tree (the patches applied)
and the patch stack are the same hunks, nothing in one that is missing from the
other. A __METAL_MEMORY_FLAGS_NONE__ guard once shipped in the working tree
with no patch, so a fresh checkout built through apply.sh lost it; this check
fails whenever the two drift again. The stack applying in order on the pin is
checked by check-d3d9-index-range.py. Nothing is modified here.
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
dxmt = root / 'dxmt'
patchdir = root / 'build/dxmt-patches'

# Hunk headers carry the line numbers of the diff they were cut from; two
# descriptions of the same change (one patch per file, or one combined diff)
# number their hunks differently. Everything else about a hunk is comparable.
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@.*$', re.M)


def hunks(text):
    """(path, normalized hunk) for every hunk of a multi-file unified diff."""
    out, path, cur = [], None, None
    for line in text.splitlines():
        if line.startswith('diff --git '):
            path = line.split(' b/')[-1]
            cur = None
        elif line.startswith('@@ '):
            cur = [HUNK.sub('@@ @@', line)]
            out.append((path, cur))
        elif cur is not None and line != '':
            cur.append(line)
    return [(path, '\n'.join(h)) for path, h in out]


tree = subprocess.run(['git', 'diff'], cwd=dxmt, capture_output=True, text=True)
if tree.returncode != 0 or not (dxmt / 'src').exists():
    print('SKIP: dxmt submodule is not a git checkout')
    sys.exit(0)
if not tree.stdout.strip():
    print('SKIP: dxmt working tree is clean here (nothing applied yet); '
          'the stack applies in order on the pin is checked by check-d3d9-index-range.py')
    sys.exit(0)

stack = '\n'.join(p.read_text() for p in sorted(patchdir.glob('*.patch')))
have, want = sorted(hunks(tree.stdout)), sorted(hunks(stack))
ok = have == want
if ok:
    print(f'ok   {len(have)} hunk(s): the dxmt working tree is exactly build/dxmt-patches')
else:
    print('FAIL the dxmt working tree and build/dxmt-patches are different changes')
    for path, hunk in sorted(set(have) - set(want)):
        print(f'     only in the working tree: {path}: {hunk.splitlines()[0]}')
    for path, hunk in sorted(set(want) - set(have)):
        print(f'     only in a patch: {path}: {hunk.splitlines()[0]}')
print('PASS' if ok else 'FAILED')
sys.exit(0 if ok else 1)
