#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 ft7t8drgwf-wq
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Replace forzahorizon6.exe's unexecutable function entry with a 5-byte jump.

Evidence (device log 2026-11-15 10:03, build ml1238):

    [entry-invalid] op=12F8F099C entry=12F8F099C decoded=1
                    bytes=ea e9 6b e6 14 48 89 7c 24 10 55 48 8b ec 48 83

Relating that to the image (base 0x140000000, so rva 0x537099c):

  * .pdata lists 0x537099c-0x5370b0d as one function, and exactly one
    `call rel32` targets it (from 0x536d6f1) -- a legitimate call.
  * the guest bytes are byte-identical to the file, so nothing rewrote them
    at runtime, and the stored PE checksum recomputes exactly, so the file is
    as the linker produced it.
  * `ea` is invalid in 64-bit mode, so nothing can execute the entry.
  * starting at +5 the code is a textbook function: `mov [rsp+0x10],rdi`,
    `push rbp`, `mov rbp,rsp`, `sub rsp,0x60`, then a /GS cookie
    (`mov rax,[rip+x]; xor rax,rsp; mov [rbp-8],rax`) and a static-local
    guard (`cmp byte ptr [rip+x],0; jne`). That is a real initialiser.

So the entry is a 5-byte slot that should hold a jump to the prologue -- the
same shape as the hotpatch prologues this project already handles. Writing
`e9 00 00 00 00` (jmp +0, i.e. fall through to +5) makes the entry executable
while leaving the prologue and every RIP-relative displacement untouched,
because the jump lands on the same address the real code expects.

This is an EXPERIMENT on the game image, not a layer fix: it exists to prove
or disprove the hypothesis cheaply. If the game advances, the same 5-byte
substitution belongs in Wine/FEX at block decode instead, where it can be
gated and logged, and the image can go back to stock.

    patch-fh6-entry-slot.py <in.exe> <out.exe> [rva]

Original image sha256 (2026-11-15 install): b8c18ec88ab3143da03c3bb9bd9d0761
"""
import struct
import sys

ENTRY_RVA = 0x537099C
FIX = b"\xe9\x00\x00\x00\x00"  # jmp +0 -> the real prologue at +5


def rva_to_offset(raw, rva):
    pe = struct.unpack_from("<I", raw, 0x3C)[0]
    if raw[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    nsec = struct.unpack_from("<H", raw, pe + 6)[0]
    optsz = struct.unpack_from("<H", raw, pe + 20)[0]
    sec = pe + 24 + optsz
    for i in range(nsec):
        o = sec + i * 40
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", raw, o + 8)
        if va <= rva < va + max(vsize, rawsize):
            return rawptr + (rva - va)
    raise SystemExit("rva %#x is in no section" % rva)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    rva = int(sys.argv[3], 0) if len(sys.argv) > 3 else ENTRY_RVA

    raw = bytearray(open(src, "rb").read())
    off = rva_to_offset(raw, rva)
    before = bytes(raw[off:off + 5])
    if before == FIX:
        print("already patched")
        return
    if before[0] != 0xEA:
        raise SystemExit("refusing: rva %#x starts with %#04x, not the 0xea entry slot"
                         % (rva, before[0]))
    raw[off:off + 5] = FIX
    open(dst, "wb").write(raw)
    print("patched rva %#x (file offset %#x): %s -> %s"
          % (rva, off, before.hex(" "), FIX.hex(" ")))


if __name__ == "__main__":
    main()
