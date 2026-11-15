#!/usr/bin/env python3
"""Region C must be big enough to do its job: the margin yields to a floor.

Region C (takeLowRegion, app/Madeira/StikJITHelper.swift) exists so FEX's code
buffers are carved there instead of out of the image pool. The pool tail's own
cap (ios_pool_code_cap in build/ntdll-unix/virtual_ios.c) grants up to 128 MB per
carve plus the 16 MB small one, so a C under 160 MB cannot hold a carve and the
carve lands in the pool tail, permanently consuming image room.

Forza Horizon 6 (2026-11-15) hit exactly that: a 218 MB free run with the default
128 MB margin gave C 80 MB, two 128 MB carves went to the pool tail (the 256 MB
cap), the head reached 0x1b768000 with an 8 MB stack hole at 0x1f000000 and
pool_limit 0x23818000, and libxess.dll -- a STATIC import of the exe, so a hard
startup failure -- needed 0x4a40000 at 0x1e000000, an extent of 0x24258000: 10.25 MB
short. The game died with STATUS_DLL_NOT_FOUND (0xc0000135).

The fix is not a per-game setting: the margin now yields to `minUseful` (160 MB,
rounded to the region granule) whenever the chosen run can give it. This checks the
arithmetic of that rule against the same helpers, and pins the Swift source so the
floor cannot be dropped silently.

Run: python3 tests/host/check-pool-region-c-floor.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "app/Madeira/StikJITHelper.swift"

MB = 1 << 20
FAILS = []


def check(name, cond, detail=""):
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILS.append(name)


# --- the helpers, transcribed from the Swift -------------------------------

def pool_run_size(available, wanted, page_fit=False):
    """poolRunSize: round down the available run, round the request up, take the
    smaller. Never returns more than the run holds."""
    granule = 0x4000 if page_fit else 16 * MB
    if page_fit:
        request = wanted & ~(granule - 1)
    else:
        request = (wanted + granule - 1) & ~(granule - 1)
    return min(available & ~(granule - 1), request)


def own_margin(run_size, margin, lower_runs, min_useful=160 * MB, page_fit=False):
    """ownMargin: no margin when a lower run already holds one; otherwise the
    configured margin, unless that would leave the run under min_useful, in which
    case the margin yields down to (run - min_useful) on the granule."""
    if any(size >= margin for size in lower_runs):
        return 0
    if run_size >= min_useful and run_size - margin < min_useful:
        grain = 0x4000 if page_fit else 16 * MB
        return (run_size - min_useful) & ~(grain - 1)
    return margin


def region_c(runs, margin, page_fit=False):
    """The region C the run set yields: the largest C any run gives."""
    best = 0
    for i, r in enumerate(runs):
        keep = own_margin(r, margin, runs[:i], page_fit=page_fit)
        available = r - keep if r > keep else 0
        best = max(best, pool_run_size(available, available, page_fit))
    return best


# --- the source still says what this models --------------------------------

def main():
    src = SRC.read_text()

    print("source: the floor and the granule are in takeLowRegion")
    check("minUseful floor is 160 MB", re.search(r"let minUseful: vm_address_t = 160 << 20", src) is not None)
    check("grain follows page-fit", re.search(
        r"let grain: vm_address_t = pageFit \? 0x4000 : 16 << 20", src) is not None)
    check("margin yields rather than starving the region", re.search(
        r"r\.size >= minUseful && r\.size - margin < minUseful", src) is not None)
    check("leftover is kept as margin on the granule", re.search(
        r"return \(r\.size - minUseful\) & ~\(grain - 1\)", src) is not None)
    check("a lower run still suppresses the margin", re.search(
        r"runs\.contains\(where: \{ \$0\.base < r\.base && \$0\.size >= margin \}\) \{ return 0 \}",
        src) is not None)
    check("the log reports the effective margin, not the configured one",
          "let keepMB = (pick?.keep ?? 0) >> 20" in src and "Int((best.size - size) >> 20)" not in src)

    print("\nmodel: the helpers reproduce the documented behaviour")
    # build 437, the case the margin design came from: 134 + 184 MB runs. The run
    # below (134 >= 128) holds the margin, so the 184 MB run keeps none and region C
    # was always 176 MB here -- the floor must not change that.
    check("build 437 (134+184, margin 128) keeps C at 176 MB",
          region_c([134 * MB, 184 * MB], 128 * MB) == 176 * MB,
          f"got {region_c([134 * MB, 184 * MB], 128 * MB) // MB} MB")

    # Forza Horizon 6: one 218 MB run. Before the floor: 218-128 = 90 -> 80 MB, too
    # small, and the carves went to the pool tail. After: keep 48, C 160 MB.
    fh6 = region_c([218 * MB], 128 * MB)
    check("FH6 (218 run, margin 128) now gives C 160 MB", fh6 == 160 * MB, f"got {fh6 // MB} MB")
    check("FH6 keep is 48 MB, the remainder on the 16 MB granule",
          own_margin(218 * MB, 128 * MB, []) == 48 * MB)

    # What the old arithmetic did, kept as the before-picture. If this ever stops
    # holding the helper changed in a way that matters.
    old_keep = 128 * MB
    old_c = pool_run_size(218 * MB - old_keep, 218 * MB - old_keep)
    check("before the floor the same run gave only 80 MB", old_c == 80 * MB, f"got {old_c // MB} MB")
    check("80 MB is under one 128 MB carve -- the shortfall was structural",
          old_c < 128 * MB)

    # The floor must never hand out more than the run holds, and must not invent
    # margin where the run is already too small.
    check("a 160 MB run keeps no margin at all", own_margin(160 * MB, 128 * MB, []) == 0)
    check("a 150 MB run keeps its old margin (too small for the floor)",
          own_margin(150 * MB, 128 * MB, []) == 128 * MB)
    check("a run under the margin still yields nothing",
          region_c([100 * MB], 128 * MB) == 0)
    check("the floor never exceeds the run", all(
        region_c([n * MB], 128 * MB) <= n * MB for n in (160, 200, 218, 256, 512)))

    # page-fit runs in 16 KB steps; the floor has to survive that too.
    pf = region_c([218 * MB], 128 * MB, page_fit=True)
    check("page-fit also reaches the floor", pf == 160 * MB, f"got {pf // MB} MB")
    check("page-fit keep is on the 16 KB granule", own_margin(
        218 * MB, 128 * MB, [], page_fit=True) % 0x4000 == 0)

    if FAILS:
        print(f"\nFAILED: {len(FAILS)} check(s)")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
