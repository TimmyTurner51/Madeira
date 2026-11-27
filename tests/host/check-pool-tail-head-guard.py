#!/usr/bin/env python3
"""Verify the fresh-tail head-reserve guard prevents 4 MB PoolArena growth from
starving late PE image loads (FH6 FHE21 crash: mfreadwrite / windows.gaming.input).
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def function(src, signature, closing='\n}'):
    start = src.index(signature)
    return src[start:src.index(closing, start) + len(closing)] + '\n'


helpers = ''.join(function(source, sig) for sig in (
    'static size_t ios_pool_hole_tail_start(',
    'static size_t ios_pool_hole_between(',
    'static size_t ios_pool_holes_tail_start(',
    'static size_t ios_pool_holes_between(',
    'static int ios_pool_tail_breaches_head_reserve(',
))

# Source-contract check: NtAllocateVirtualMemoryEx checks ios_pool_tail_head_guard_check
# BEFORE committing ios_jit_tail_reserved via CAS (preventing concurrent tail_reserved leaks)
# and logs TAIL HEAD-GUARD on refusal.
site = source[source.index('int tail_refused = 0, tail_head_breach = 0;'):]
site = site[:site.index('return STATUS_NO_MEMORY;')]
guard_pos = site.index('ios_pool_tail_head_guard_check(')
cas_pos = site.index('__sync_bool_compare_and_swap( &ios_jit_tail_reserved')
assert guard_pos < cas_pos, 'tail head-guard must run before CAS mutates ios_jit_tail_reserved'
assert 'if (tail_refused)' in site
assert 'TAIL HEAD-GUARD' in site

c_fixture = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define MB ((size_t)1 << 20)
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
''' + helpers + r'''
int main(void)
{
    /* 1. Exact replay of /tmp/crash-madeira-log.txt (FH6 FHE21):
     *    total = 0x373a8000, head = 0x15e48000, hole = [0x21000000, 0x273a8000),
     *    reserve = 48 MB, main 128 MB buffer already live, FEX asks for 64 x 4 MB arenas. */
    const size_t total = 0x373a8000;
    const size_t head = 0x15e48000;
    const size_t h1_off = 0x21000000, h1_end = 0x273a8000;
    const size_t reserve = 48 * MB;
    size_t tail = 0xa808000; /* after initial 128 MB + startup carves */
    int granted = 0;

    for (int i = 0; i < 64; i++) {
        size_t start = ios_pool_holes_tail_start(total, tail, 4 * MB, h1_off, h1_end, 0, 0);
        size_t tail_after = start + 4 * MB;
        if (ios_pool_tail_breaches_head_reserve(total, head, tail_after, 4 * MB,
                                                h1_off, h1_end, 0, 0, reserve, 1))
            break;
        tail = tail_after;
        granted++;
    }
    size_t tail_off = total - tail;
    size_t hole_left = ios_pool_holes_between(total, head, tail, h1_off, h1_end, 0, 0);
    size_t usable_headroom = tail_off - head - hole_left;
    CHECK(granted > 20 && granted < 64);
    CHECK(usable_headroom >= reserve);
    /* Late PE loads (mfreadwrite.dll 0xa4000 + windows.gaming.input.dll 0xa4000 + speech 0xa0000) fit easily. */
    CHECK(usable_headroom >= 0xa4000 + 0xa4000 + 0xa0000);

    /* 2. A brand-new process with NO live >=1MB code buffer is NOT blocked by the guard. */
    CHECK(!ios_pool_tail_breaches_head_reserve(total, head, total - head - 20 * MB, 16 * MB,
                                               0, 0, 0, 0, reserve, 0));

    /* 3. Small 16 KB dispatcher carves (< 1 MB) are NEVER blocked by the guard. */
    CHECK(!ios_pool_tail_breaches_head_reserve(total, head, total - head - 0x4000, 0x4000,
                                               0, 0, 0, 0, reserve, 1));

    /* 4. Hole between head and tail is subtracted from usable headroom. */
    /* head=0x10000000, hole=[0x11000000,0x16000000) (80MB), tail_off=0x18000000 ->
     * span is 128MB, hole is 80MB, usable is 48MB (allowed); another 4MB drops usable to 44MB (refused). */
    CHECK(!ios_pool_tail_breaches_head_reserve(0x30000000, 0x10000000, 0x30000000 - 0x18000000, 4 * MB,
                                               0x11000000, 0x16000000, 0, 0, reserve, 1));
    CHECK(ios_pool_tail_breaches_head_reserve(0x30000000, 0x10000000, 0x30000000 - 0x17c00000, 4 * MB,
                                              0x11000000, 0x16000000, 0, 0, reserve, 1));

    /* 5. reserve == 0 disables the guard. */
    CHECK(!ios_pool_tail_breaches_head_reserve(total, head, total - head - 4 * MB, 4 * MB,
                                               0, 0, 0, 0, 0, 1));

    printf("PASS: tail head-guard stops FH6 4MB arena growth after %d arenas with %zu MB usable headroom preserved\n",
           granted, usable_headroom >> 20);
    return 0;
}
'''

with tempfile.TemporaryDirectory() as td:
    src = Path(td) / 't.c'
    exe = Path(td) / 't'
    src.write_text(c_fixture)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
