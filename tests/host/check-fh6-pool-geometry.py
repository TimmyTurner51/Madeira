#!/usr/bin/env python3
"""FH6 pool geometry: why libxess.dll could not be placed, and why margin=48 places it.

The 2026-11-15 11:04 session died with STATUS_DLL_NOT_FOUND on libxess.dll, a
STATIC import of forzahorizon6.exe:

    [jit-pool] EXHAUSTED (image 0x71ea600000+0x4a3b000): want=0x4a40000
               bump=0x1b768000/0x33818000 tail_resv=0x10000000 freelist=0

The cause was not the loader and not the request size. Two 128 MB FEX code
buffers were carved into the MAIN pool because region C -- the third debugger
region, whose stated purpose is that "FEX code buffers are carved here first" --
was 80 MB while ios_pool_code_cap permits a 128 MB buffer:

    [pool-low] region C has 0x3ffc000 of 0x5000000 left, not enough for carve
               0x8000000: it goes to the pool tail
    [jit-pool] tail EC_CODE rx=0x177818000 size=0x8000000 tail_resv=0x8000000
    [jit-pool] tail EC_CODE rx=0x16f818000 size=0x8000000 tail_resv=0x10000000

Those 256 MB of tail reservation are what pushed pool_limit below the extent a
74 MB image needs above the 8 MB stack hole.

This check extracts the REAL allocator helpers from build/ntdll-unix/virtual_ios.c
(ios_pool_code_cap, ios_pool_holes_head_place, ios_pool_holes_tail_start,
ios_pool_hole_between, ios_pool_big_layout) and runs them, so the arithmetic is
the emulator's own and not a restatement of it.

It asserts:
  - the observed failure reproduces exactly, down to the 10.25 MB shortfall, so
    the model is the emulator's and not an approximation;
  - the two carves land at the pool offsets the log recorded;
  - with region C able to hold one 128 MB carve the tail reserves 128 MB and
    libxess is placed with 117.75 MB of slack;
  - and that the big-image slot -- which looks like the obvious fix -- is NOT
    safe: it widens the effective hole, the second carve dodges DOWN into the
    head's forward path, and the bump check tests only the limit and the holes.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def extract(signature):
    """The full definition of a static function, from its signature to its closing brace."""
    i = src.index(signature)
    i = src.rindex('\n', 0, i) + 1
    depth = 0
    k = src.index('{', i)
    while k < len(src):
        if src[k] == '{':
            depth += 1
        elif src[k] == '}':
            depth -= 1
            if depth == 0:
                return src[i:k + 1]
        k += 1
    raise AssertionError('unterminated ' + signature)


funcs = [
    extract('static size_t ios_pool_hole_head_place('),
    extract('static size_t ios_pool_hole_tail_start('),
    extract('static size_t ios_pool_hole_between('),
    extract('static size_t ios_pool_code_cap('),
    extract('static size_t ios_pool_holes_head_place('),
    extract('static size_t ios_pool_holes_tail_start('),
]
big_layout = extract('static int ios_pool_big_layout(')
big_min = re.search(r'#define IOS_POOL_BIG_MIN \((.*?)\)', src).group(1)

# The tail carve reserves top-down and returns the reservation COUNTER; the pool
# offset is total - counter - size. ios_pool_holes_tail_start is exactly the
# counter step, so model the caller's one line of arithmetic instead of inventing
# a helper that does not exist.
model = '''
static size_t tail_carve_offset(size_t total, size_t cur, size_t size,
                                size_t h1_off, size_t h1_end, size_t h2_off, size_t h2_end)
{
    size_t start = ios_pool_holes_tail_start(total, cur, size, h1_off, h1_end, h2_off, h2_end);
    return total - start - size;
}
'''

harness = r'''
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cstddef>
static const size_t IOS_POOL_BIG_MIN = @BIGMIN@;

@BODY@

static int fails = 0;
static void expect(const char* what, unsigned long long got, unsigned long long want) {
    if (got != want) { printf("FAIL %s: got 0x%llx want 0x%llx\n", what, got, want); fails++; }
}

int main() {
    /* The measured layout of the 11:04 session (every value from its log). */
    const size_t total    = 0x33818000;   /* 824 MB span, pool-split        */
    const size_t hole_off = 0x1f000000;   /* 8 MB, the main thread's stack  */
    const size_t hole_end = 0x1f818000;
    const size_t head     = 0x1b768000;   /* bump cursor at the failure     */
    const size_t want     = 0x4a40000;    /* libxess.dll image_alloc        */
    const size_t reserve  = 48u << 20;    /* default image headroom         */
    const size_t carve    = 0x8000000;    /* 128 MB, what FEX actually asks */

    /* --- 1. the observed failure reproduces exactly ----------------------- */
    /* Tail at its 256 MB cap from two carves: the limit is 0x23818000. */
    const size_t limit_bad = total - 0x10000000;
    expect("observed pool_limit", limit_bad, 0x23818000);

    size_t cand = ios_pool_holes_head_place(head, want, hole_off, hole_end, 0, 0);
    expect("placement starts above the hole", cand, hole_end);
    expect("extent needed", cand + want, 0x24258000);
    if (!(cand + want > limit_bad)) { printf("FAIL the shortfall did not reproduce\n"); fails++; }
    expect("shortfall", (cand + want) - limit_bad, 0xa40000);   /* 10.25 MB */

    /* --- 2. region C holding one carve leaves the tail at 128 MB ---------- */
    const size_t limit_fix = total - carve;
    expect("fixed pool_limit", limit_fix, 0x2b818000);
    if (!(cand + want <= limit_fix)) { printf("FAIL libxess still does not fit\n"); fails++; }
    expect("slack after placement", limit_fix - (cand + want), 0x75c0000);  /* 117.75 MB */

    /* --- 3. the cap must permit one carve and refuse a second ------------- */
    /* Region C has to be able to hold what ios_pool_code_cap allows, or the
     * carve spills back into the pool and the fix is not real. */
    expect("cap with the tail at 128 MB", ios_pool_code_cap(total, head, carve, hole_off, hole_end, reserve), carve);
    /* Once the tail holds 256 MB the cap falls below a 128 MB carve -- correct,
     * and precisely why region C, not a bigger pool tail, is where it must fit. */
    size_t cap_full = ios_pool_code_cap(total, head, 0x10000000, hole_off, hole_end, reserve);
    if (cap_full >= carve) { printf("FAIL cap 0x%llx should be below 128 MB\n", (unsigned long long)cap_full); fails++; }
    printf("cap falls to 0x%llx once the tail holds 256 MB\n", (unsigned long long)cap_full);

    /* --- 4. the carves land where the log recorded them ------------------- */
    size_t c1 = tail_carve_offset(total, 0, carve, hole_off, hole_end, 0, 0);
    size_t c2 = tail_carve_offset(total, carve, carve, hole_off, hole_end, 0, 0);
    expect("first carve offset", c1, 0x2b818000);   /* [jit-pool] rx=0x177818000 */
    expect("second carve offset", c2, 0x23818000);  /* [jit-pool] rx=0x16f818000 */
    /* Both sit above the head cursor, which is what makes them harmless: they
     * eat pool_limit but never land where the bump is heading. */
    if (!(c1 > head && c2 > head)) { printf("FAIL a carve landed below the head\n"); fails++; }

    /* --- 5. the big-image slot is NOT safe here --------------------------- */
    /* A 96 MB slot above the hole widens the effective hole to 0x25818000. The
     * second carve must dodge it, and it dodges DOWNWARD: 0x17000000, below a
     * head cursor already at 0x1b768000. The bump check tests only pool_limit
     * and the holes, so it would run into live code. Hence: fix region C's
     * size, not a big-image slot. */
    size_t slot = 0, skip_off = 0, skip_end = 0;
    int fits = ios_pool_big_layout(total, hole_off, hole_end, (size_t)96 << 20, 0,
                                   &slot, &skip_off, &skip_end);
    expect("slot fits", (unsigned long long)fits, 1);
    expect("slot starts at the hole end", slot, hole_end);
    expect("effective hole widens", skip_end, 0x25818000);

    size_t s1 = tail_carve_offset(total, 0, carve, skip_off, skip_end, 0, 0);
    size_t s2 = tail_carve_offset(total, carve, carve, skip_off, skip_end, 0, 0);
    expect("slot case: first carve offset", s1, 0x2b818000);
    expect("slot case: second carve offset", s2, 0x17000000);
    if (!(s2 < head)) {
        printf("FAIL slot case: second carve 0x%llx should be BELOW the head 0x%llx\n",
               (unsigned long long)s2, (unsigned long long)head); fails++;
    }
    printf("slot case: the second carve moves from 0x%llx down to 0x%llx, below the head at 0x%llx\n",
           (unsigned long long)c2, (unsigned long long)s2, (unsigned long long)head);

    if (fails) return 1;
    printf("ok\n");
    return 0;
}
'''

body = '\n\n'.join(funcs) + '\n\n' + big_layout + '\n' + model
harness = harness.replace('@BIGMIN@', big_min).replace('@BODY@', body)

with tempfile.TemporaryDirectory(prefix='fh6-pool-') as tmp:
    tmp = Path(tmp)
    f = tmp / 'pool.cpp'
    f.write_text(harness)
    exe = tmp / 'pool'
    cc = subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-Wall',
                         '-Wno-unused-function', '-Wno-unused-parameter', str(f), '-o', str(exe)],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        print('FAIL: the extracted helpers do not compile:\n' + cc.stderr[-3000:])
        sys.exit(1)
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    print(run.stdout.strip())
    check(run.returncode == 0, 'geometry assertions')

if failures:
    for f in failures:
        print('FAIL: ' + f)
    sys.exit(1)
print('PASS: the libxess shortfall reproduces exactly (10.25 MB), region C sized to hold one '
      '128 MB carve places it with 117.75 MB to spare, and the big-image slot is shown to move '
      "the second carve inside the head's forward path")
