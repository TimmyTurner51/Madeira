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
# target file. That is the cheap first test, but it cannot decide a stacked
# patch: 0004 sits on top of 0003 in Module.S and rewrites some of the lines
# 0003 adds, so neither `git apply --reverse --check` nor the content test
# recognises a stack that is fully applied. stack_applied() answers the question
# for the whole stack at once, by reversing the patches in reverse order (the
# exact order they were applied) and then putting them back; it only runs when a
# patch fails both cheap tests, so a clean tree never touches the files twice.
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

stack_applied() {
    local n=${#patches[@]} i j reverted=()
    for ((i = n - 1; i >= 0; i--)); do
        git -C "$F" apply --reverse "${patches[$i]}" 2>/dev/null || break
        reverted+=("$i")
    done
    if [ "${#reverted[@]}" -eq "$n" ]; then
        for ((i = 0; i < n; i++)); do
            git -C "$F" apply "${patches[$i]}" || {
                echo "fex-patches: could not restore $(basename "${patches[$i]}") after probing the stack" >&2
                exit 1
            }
        done
        return 0
    fi
    # Partly applied: put back exactly what the probe reversed.
    for ((j = ${#reverted[@]} - 1; j >= 0; j--)); do
        git -C "$F" apply "${patches[${reverted[$j]}]}" || true
    done
    return 1
}

for p in "${patches[@]}"; do
    if git -C "$F" apply --reverse --check "$p" 2>/dev/null || already_applied "$p" || [ "${stack_ok:-0}" -eq 1 ]; then
        echo "fex-patches: $(basename "$p") already applied"
    elif git -C "$F" apply --check "$p" 2>/dev/null; then
        git -C "$F" apply "$p"
        echo "fex-patches: applied $(basename "$p")"
    elif stack_applied; then
        stack_ok=1
        echo "fex-patches: $(basename "$p") already applied (stack verified)"
    else
        echo "fex-patches: $(basename "$p") does not apply on FEX $(git -C "$F" rev-parse --short HEAD)" >&2
        exit 1
    fi
done
