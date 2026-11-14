#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Applies Madeira's Wine changes (build/wine-patches/*.patch, in order) to the
# Wine checkout before tools/build/build-wine.sh configures and builds it. The
# submodule and its repository are not changed: the patches only touch the
# working tree, and a patch already applied is skipped. `apply.sh --revert`
# takes them out again.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$R/wine"
shopt -s nullglob
patches=("$R"/build/wine-patches/*.patch)
# bash 3.2 under set -u rejects "${patches[@]}" when empty.
[ ${#patches[@]} -gt 0 ] || exit 0
if [ "${1:-}" = --revert ]; then
    for ((i = ${#patches[@]} - 1; i >= 0; i--)); do
        p="${patches[$i]}"
        if git -C "$W" apply --reverse --check "$p" 2>/dev/null; then
            git -C "$W" apply --reverse "$p"
            echo "wine-patches: reverted $(basename "$p")"
        fi
    done
    exit 0
fi
for p in "${patches[@]}"; do
    if git -C "$W" apply --reverse --check "$p" 2>/dev/null; then
        echo "wine-patches: $(basename "$p") already applied"
    elif git -C "$W" apply --check "$p" 2>/dev/null; then
        git -C "$W" apply "$p"
        echo "wine-patches: applied $(basename "$p")"
    else
        echo "wine-patches: $(basename "$p") does not apply on wine $(git -C "$W" rev-parse --short HEAD)" >&2
        exit 1
    fi
done
