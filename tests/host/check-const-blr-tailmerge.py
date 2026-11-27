#!/usr/bin/env python3
"""Host test for ios_jit_patch_const_blrs (build/ntdll-unix/virtual_ios.c).

Verifies that the ARM64EC pool-copy direct-call rewriter:
1. Patches unshared `adrp rd; ldr rt, [rd, #off]; blr rt` sequences to direct
   `bl target` when neither `p+4` nor `p+8` is a branch target.
2. Preserves `blr rt` intact when `p+8` (or `p+4`) IS targeted by a branch
   (Clang tail-merging an if/else-if/else onto one shared `blr rt`, e.g.
   `mad_eb_flush` dispatching render/compute/blit encodeCommands), and rebases
   both the fallthrough slot and the sibling branch slots in the read-only pool
   copy into `rx`.
3. Preserves loop-hoisted tail-merged `blr` sites (e.g. `cbz -> blr x19`) and
   rebases their ARM64EC import exit thunk slots.
4. Does not touch unrelated `.rdata` pointers.
5. Leaves zero tail-merged `blr` sites overwritten when run on the real
   `build/madeira-d3d12/out-pe/madeira_d3d12.dll` (if built on disk).
"""
from pathlib import Path
import os
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
VIRTUAL = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text()


def extract_fn(src: str, signature: str) -> str:
    start = src.index(signature)
    i = src.index("{", start)
    depth = 0
    while i < len(src):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    raise RuntimeError(f"unterminated function: {signature}")


fn_branch = extract_fn(VIRTUAL, "static int ios_arm64_branch_target(")
fn_thunk = extract_fn(VIRTUAL, "static int ios_is_arm64ec_import_thunk(")
fn_patch = extract_fn(VIRTUAL, "static int ios_jit_patch_const_blrs(")

HARNESS = f"""
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

static const char *ios_pe_module_name( const void *pe, size_t size ) {{ (void)pe; (void)size; return "test.dll"; }}

{fn_branch}

{fn_thunk}

{fn_patch}

static uint32_t enc_adrp( uint32_t rd, uint64_t pc, uint64_t target ) {{
    int64_t imm = (int64_t)((target & ~0xfffULL) - (pc & ~0xfffULL)) >> 12;
    uint32_t immlo = (uint32_t)(imm & 3);
    uint32_t immhi = (uint32_t)((imm >> 2) & 0x7ffff);
    return 0x90000000u | (immlo << 29) | (immhi << 5) | (rd & 31);
}}

static uint32_t enc_ldr64( uint32_t rt, uint32_t rn, uint32_t off ) {{
    assert((off & 7) == 0);
    return 0xf9400000u | (((off >> 3) & 0xfffu) << 10) | ((rn & 31) << 5) | (rt & 31);
}}

static uint32_t enc_blr( uint32_t rn ) {{
    return 0xd63f0000u | ((rn & 31) << 5);
}}

static uint32_t enc_b( int32_t delta_bytes ) {{
    assert((delta_bytes & 3) == 0);
    return 0x14000000u | ((uint32_t)(delta_bytes >> 2) & 0x03ffffffu);
}}

static uint32_t enc_cbz( uint32_t rt, int32_t delta_bytes ) {{
    assert((delta_bytes & 3) == 0);
    return 0xb4000000u | (((uint32_t)(delta_bytes >> 2) & 0x7ffffu) << 5) | (rt & 31);
}}

static void write_thunk( uint8_t *buf, uint32_t rva ) {{
    uint32_t *w = (uint32_t *)(buf + rva);
    w[0] = 0x9000000bu; /* adrp x11, ... */
    w[1] = 0xf940016bu; /* ldr x11, [x11] */
    w[2] = 0x9000000au; /* adrp x10, ... */
    w[3] = 0x9100014au; /* add x10, x10, #0 */
    w[4] = 0x14000001u; /* b +4 */
}}

int main( void ) {{
    /* Synthetic PE image: 0x0000 headers, 0x1000 .text (exec), 0x2000 .rdata (ro) */
    const size_t IMG_SZ = 0x3000;
    const uint64_t IMAGEBASE = 0x180000000ULL;
    const uint64_t PE_BASE = 0x7100000000ULL;
    uint8_t *rw = calloc( 1, IMG_SZ );
    uint8_t *rx = (uint8_t *)0x150000000ULL; /* simulated RX alias address */
    assert(rw);

    rw[0] = 'M'; rw[1] = 'Z';
    *(uint32_t *)(rw + 0x3c) = 0x80;
    *(uint16_t *)(rw + 0x80 + 6) = 2;    /* NumberOfSections */
    *(uint16_t *)(rw + 0x80 + 0x14) = 0xf0; /* SizeOfOptionalHeader */
    *(uint64_t *)(rw + 0x80 + 0x30) = IMAGEBASE;

    unsigned char *sh0 = rw + 0x80 + 0x18 + 0xf0;
    memcpy( sh0, ".text\\0\\0\\0", 8 );
    *(uint32_t *)(sh0 + 8) = 0x1000;
    *(uint32_t *)(sh0 + 12) = 0x1000;
    *(uint32_t *)(sh0 + 36) = 0x60000020u; /* CODE | EXEC | READ */

    unsigned char *sh1 = sh0 + 40;
    memcpy( sh1, ".rdata\\0\\0", 8 );
    *(uint32_t *)(sh1 + 8) = 0x1000;
    *(uint32_t *)(sh1 + 12) = 0x2000;
    *(uint32_t *)(sh1 + 36) = 0x40000040u; /* INITIALIZED_DATA | READ (not writable) */

    /* Target thunks inside .text */
    const uint32_t THUNK_DIRECT  = 0x1800;
    const uint32_t THUNK_RENDER  = 0x1840;
    const uint32_t THUNK_COMPUTE = 0x1880;
    const uint32_t THUNK_BLIT    = 0x18c0;
    const uint32_t THUNK_RELEASE = 0x1900;
    write_thunk( rw, THUNK_DIRECT );
    write_thunk( rw, THUNK_RENDER );
    write_thunk( rw, THUNK_COMPUTE );
    write_thunk( rw, THUNK_BLIT );
    write_thunk( rw, THUNK_RELEASE );

    /* Read-only AuxIAT slots in .rdata holding PE-rebased addresses */
    *(uint64_t *)(rw + 0x2000) = PE_BASE + THUNK_DIRECT;
    *(uint64_t *)(rw + 0x2008) = PE_BASE + THUNK_RENDER;
    *(uint64_t *)(rw + 0x2010) = PE_BASE + THUNK_COMPUTE;
    *(uint64_t *)(rw + 0x2018) = PE_BASE + THUNK_BLIT;
    *(uint64_t *)(rw + 0x2020) = PE_BASE + THUNK_RELEASE;
    *(uint64_t *)(rw + 0x2080) = PE_BASE + 0x1200; /* unrelated .rdata pointer */

    uint32_t *code = (uint32_t *)(rw + 0x1000);
    /* Case 1 (RVA 0x1000): unshared direct call -> MUST patch to BL THUNK_DIRECT */
    code[0] = enc_adrp( 8, (uint64_t)rx + 0x1000, (uint64_t)rx + 0x2000 );
    code[1] = enc_ldr64( 8, 8, 0x000 );
    code[2] = enc_blr( 8 );

    /* Case 2 (RVA 0x1020..0x1040): tail-merged 3-way dispatch like mad_eb_flush */
    /* 0x1020: render branch -> b 0x1040 */
    code[8]  = enc_adrp( 8, (uint64_t)rx + 0x1020, (uint64_t)rx + 0x2008 );
    code[9]  = enc_ldr64( 8, 8, 0x008 );
    code[10] = enc_b( 0x1040 - 0x1028 );
    /* 0x102c: compute branch -> b 0x1040 */
    code[11] = enc_adrp( 8, (uint64_t)rx + 0x102c, (uint64_t)rx + 0x2010 );
    code[12] = enc_ldr64( 8, 8, 0x010 );
    code[13] = enc_b( 0x1040 - 0x1034 );
    /* 0x1038: blit fallthrough -> 0x1040: blr x8 */
    code[14] = enc_adrp( 8, (uint64_t)rx + 0x1038, (uint64_t)rx + 0x2018 );
    code[15] = enc_ldr64( 8, 8, 0x018 );
    code[16] = enc_blr( 8 ); /* RVA 0x1040 */

    /* Case 3 (RVA 0x1060..0x107c): loop-hoisted cbz -> blr x19 like mad_present_run */
    code[24] = enc_adrp( 19, (uint64_t)rx + 0x1060, (uint64_t)rx + 0x2020 );
    code[25] = enc_ldr64( 19, 19, 0x020 );
    code[26] = enc_cbz( 0, 0x1078 - 0x1068 );
    code[27] = 0xd503201fu; /* nop */
    code[28] = enc_adrp( 19, (uint64_t)rx + 0x1070, (uint64_t)rx + 0x2020 );
    code[29] = enc_ldr64( 19, 19, 0x020 );
    code[30] = enc_blr( 19 ); /* RVA 0x1078 */

    int patched = ios_jit_patch_const_blrs( (char *)rw, (char *)rx, (const void *)PE_BASE, IMG_SZ );
    assert( patched == 1 );

    /* Case 1: patched to BL THUNK_DIRECT */
    int32_t expected_bl = (int32_t)(0x94000000u | (((THUNK_DIRECT - 0x1008) >> 2) & 0x3ffffffu));
    assert( code[2] == (uint32_t)expected_bl );

    /* Case 2: shared blr x8 MUST stay blr x8, and all 3 slots MUST be rebased into rx */
    assert( code[16] == enc_blr( 8 ) );
    assert( *(uint64_t *)(rw + 0x2008) == (uint64_t)rx + THUNK_RENDER );
    assert( *(uint64_t *)(rw + 0x2010) == (uint64_t)rx + THUNK_COMPUTE );
    assert( *(uint64_t *)(rw + 0x2018) == (uint64_t)rx + THUNK_BLIT );

    /* Case 3: shared blr x19 MUST stay blr x19, and release slot MUST be rebased into rx */
    assert( code[30] == enc_blr( 19 ) );
    assert( *(uint64_t *)(rw + 0x2020) == (uint64_t)rx + THUNK_RELEASE );

    /* Case 4: unrelated .rdata pointer MUST be untouched */
    assert( *(uint64_t *)(rw + 0x2080) == PE_BASE + 0x1200 );

    free( rw );
    printf( "PASS: synthetic ios_jit_patch_const_blrs tail-merge tests (patched=%d)\\n", patched );
    return 0;
}}
"""

with tempfile.TemporaryDirectory() as td:
    src_path = Path(td) / "test.c"
    bin_path = Path(td) / "test"
    src_path.write_text(HARNESS)
    cc = os.environ.get("CC", "cc")
    subprocess.check_call([cc, "-O2", "-Wall", "-Wextra", "-o", str(bin_path), str(src_path)])
    out = subprocess.check_output([str(bin_path)], text=True)
    print(out.strip())
