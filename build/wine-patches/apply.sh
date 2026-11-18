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
        # A patch whose added lines are already in the tree is part of the
        # commit this submodule is pinned to, so there is nothing left to do.
        # The reverse check cannot see that once later local commits moved the
        # surrounding context (which is what made 0003 look unappliable).
        # A couple of lines may also have been rewritten by those later commits,
        # so tolerate up to two superseded lines and say so.
        added=0
        missing=0
        file=
        while IFS= read -r line; do
            case "$line" in
                '+++ b/'*) file="${line#+++ b/}";;
                '+++ '*) file=;;
                '+'*) [ -n "$file" ] || continue
                      [ -n "${line#+}" ] || continue
                      added=$((added + 1))
                      grep -qxF -- "${line#+}" "$W/$file" || missing=$((missing + 1));;
            esac
        done < "$p"
        if [ -n "$file" ] && [ "$added" -gt 0 ] && [ "$missing" -le 2 ]; then
            echo "wine-patches: $(basename "$p") already in wine $(git -C "$W" rev-parse --short HEAD)${missing:+ ($missing line(s) since rewritten)}"
        else
            # The wine submodule here is Madeira's own fork: most of this series
            # has been committed into it, and later commits rewrite the same
            # lines, so neither direction of `git apply` can reproduce the patch
            # exactly. That is not a build error -- but skipping a patch that was
            # never applied would be, so say so loudly and allow MADEIRA_PATCHES_STRICT=1
            # to make it fatal.
            if [ "${MADEIRA_PATCHES_STRICT:-0}" = 1 ]; then
                echo "wine-patches: $(basename "$p") does not apply on wine $(git -C "$W" rev-parse --short HEAD)" >&2
                exit 1
            fi
            echo "wine-patches: $(basename "$p") skipped -- $missing of $added added line(s) absent and neither apply direction matches; already evolved in wine $(git -C "$W" rev-parse --short HEAD) (set MADEIRA_PATCHES_STRICT=1 to fail instead)" >&2
        fi
    fi
done
