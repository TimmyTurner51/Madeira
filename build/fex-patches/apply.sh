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

# Why a marker file and not just `git apply --reverse --check`.
#
# 2026-11-27: the FEX working tree was found with several patch hunks applied
# THREE to FIVE times (InternalThreadState.h had `GuestDebugRegisters` three
# times, Core.cpp had QueueSMCInvalidate() five times, LookupCache.h had
# GetSharedMap() three times, CPUBackend.h had two stray closing braces). The
# tree did not compile, so no FEX-side fix could be built at all.
#
# The old guard treated "does it reverse-apply?" as "is it applied?". That is
# not a proof for a pure-insertion hunk: after one application the hunk's
# context still matches, so the FORWARD check also succeeds and the next run
# inserts a second copy. Reverse-check keeps succeeding afterwards, so the
# corruption is invisible to the guard forever.
#
# Record the exact patch bytes that were applied. If the recorded digest still
# matches, the patch is applied, full stop -- no context guessing, and no way
# for a later run to stack a second copy on top.
# FEX is a submodule, so .git may be a *file* pointing at the real git dir.
FEX_GITDIR="$(git -C "$F" rev-parse --absolute-git-dir 2>/dev/null || echo "$F/.git")"
STATE="$FEX_GITDIR/madeira-fex-patches-applied"
if [ "${1:-}" = --revert ]; then
    for ((i = ${#patches[@]} - 1; i >= 0; i--)); do
        p="${patches[$i]}"
        if git -C "$F" apply --reverse --check "$p" 2>/dev/null; then
            git -C "$F" apply --reverse "$p"
            echo "fex-patches: reverted $(basename "$p")"
        fi
    done
    rm -f "$STATE"
    exit 0
fi
for p in "${patches[@]}"; do
    digest="$(basename "$p"):$(shasum -a 256 "$p" | cut -d' ' -f1)"
    if [ -f "$STATE" ] && grep -qxF "$digest" "$STATE" 2>/dev/null; then
        echo "fex-patches: $(basename "$p") already applied (recorded)"
    elif git -C "$F" apply --reverse --check "$p" 2>/dev/null; then
        echo "fex-patches: $(basename "$p") already applied"
        printf '%s\n' "$digest" >> "$STATE"
    elif git -C "$F" apply --check "$p" 2>/dev/null; then
        git -C "$F" apply "$p"
        printf '%s\n' "$digest" >> "$STATE"
        echo "fex-patches: applied $(basename "$p")"
    else
        echo "fex-patches: $(basename "$p") does not apply on FEX $(git -C "$F" rev-parse --short HEAD)" >&2
        exit 1
    fi
done