#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Applies Madeira's own FEX changes (build/fex-patches/*.patch, in order) to the
# FEX checkout before build/fex-arm64ec/build.sh and build/fex-wow64/build.sh
# build it. The FEX submodule and its repository are not changed: the patches
# only touch the working tree, and a patch already applied is skipped, so both
# build scripts can call this. `apply.sh --revert` takes them out again.
# These patches are Madeira's, not FEX-Emu's: see build/fex-patches/README.md.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F="$R/FEX"
shopt -s nullglob
patches=("$R"/build/fex-patches/*.patch)
# Nothing to do without patches (and bash 3.2 under set -u rejects "${patches[@]}" when empty).
[ ${#patches[@]} -gt 0 ] || exit 0
if [ "${1:-}" = --revert ]; then
    for ((i = ${#patches[@]} - 1; i >= 0; i--)); do
        p="${patches[$i]}"
        if git -C "$F" apply --reverse --check "$p" 2>/dev/null; then
            git -C "$F" apply --reverse "$p"
            echo "fex-patches: reverted $(basename "$p")"
        fi
    done
    exit 0
fi
# A patch counts as already applied when every line it adds is present in its
# target file. `git apply --reverse --check` alone is not enough once a later
# patch edits the same region: reversing 0003 fails while 0004 sits on top of it,
# and the second build script's call to this file then reports "does not apply".
already_applied() {
    python3 - "$1" "$F" <<'PY'
import os, sys
patch, root = sys.argv[1], sys.argv[2]
target, added = None, []
for line in open(patch, encoding='utf-8', errors='replace'):
    if line.startswith('+++ b/'):
        target = os.path.join(root, line[6:].strip())
    elif line.startswith('+') and not line.startswith('+++'):
        added.append(line[1:].rstrip('\n'))
if not target or not added or not os.path.exists(target):
    sys.exit(1)
body = open(target, encoding='utf-8', errors='replace').read()
missing = [a for a in added if a and a not in body]
sys.exit(0 if not missing else 1)
PY
}

for p in "${patches[@]}"; do
    if git -C "$F" apply --reverse --check "$p" 2>/dev/null || already_applied "$p"; then
        echo "fex-patches: $(basename "$p") already applied"
    elif git -C "$F" apply --check "$p" 2>/dev/null; then
        git -C "$F" apply "$p"
        echo "fex-patches: applied $(basename "$p")"
    else
        echo "fex-patches: $(basename "$p") does not apply on FEX $(git -C "$F" rev-parse --short HEAD)" >&2
        exit 1
    fi
done
