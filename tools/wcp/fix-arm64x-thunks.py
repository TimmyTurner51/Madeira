#!/usr/bin/env python3
"""Give ARM64EC import thunks the x86_64 hotpatch prologue Forza's anti-tamper expects.

Port of fh6-wine-fex/wine/spec32-arm64x-import-thunk.patch (fixup_arm64x_import_thunks)
as a PE post-processor, so shipped DLLs can be fixed without rebuilding wine.

The linker emits an x64 import thunk as a bare "jmp *__imp_x(%rip)" in a 16-byte slot.
Code that inspects export prologues (Forza's anti-tamper) reads that as an inline hook and
sets its tampered flag, after which it refuses to decrypt its own #UD-trapped functions.

x86_64 output_exports emits instead:

    48 8d a4 24 00 00 00 00     lea rsp,[rsp+0]      <- 8-byte hotpatch prologue
    ff 25 xx xx xx xx           jmp *__imp_x(%rip)   <- relocated by 8

Only x64 code ranges (per the CHPE code map) are touched.

usage: fix-arm64x-thunks.py --check|--apply <dll> [...]
"""

import struct
import sys

IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x20B
DIR_EXPORT, DIR_IAT, DIR_LOAD_CONFIG = 0, 12, 10
DYNAMIC_RELOCATION_ARM64X = 6

PROLOG = bytes([0x48, 0x8D, 0xA4, 0x24, 0x00, 0x00, 0x00, 0x00])


class PE:
    def __init__(self, data):
        self.d = data
        nt = self.u32(0x3C)
        if data[nt:nt + 4] != b"PE\0\0":
            raise ValueError("not PE")
        self.machine = self.u16(nt + 4)
        nb_sec = self.u16(nt + 6)
        opt = nt + 24
        if self.u16(opt) != IMAGE_NT_OPTIONAL_HDR64_MAGIC:
            raise ValueError("not PE32+")
        self.opt = opt
        sec = opt + self.u16(nt + 20)
        self.sec = sec
        self.nb_sec = nb_sec
        self.image_base = self.u32(opt + 24) | (self.u32(opt + 28) << 32)
        self.nb_dirs = self.u32(opt + 108)
        self.dirs = opt + 112

    def u16(self, o):
        return struct.unpack_from("<H", self.d, o)[0]

    def u32(self, o):
        return struct.unpack_from("<I", self.d, o)[0]

    def rva_ptr(self, rva, length):
        for i in range(self.nb_sec):
            s = self.sec + i * 40
            va = self.u32(s + 12)
            raw_size = self.u32(s + 16)
            raw_ptr = self.u32(s + 20)
            if rva < va or rva - va >= raw_size or raw_size - (rva - va) < length:
                continue
            if raw_ptr + (rva - va) + length > len(self.d):
                return None
            return raw_ptr + (rva - va)
        return None

    def x64_ranges(self):
        """[(start, end)] of x64 code from the CHPE code map."""
        lc_rva = self.u32(self.dirs + 8 * DIR_LOAD_CONFIG)
        lc = self.rva_ptr(lc_rva, 4)
        if lc is None:
            raise ValueError("no load config")
        lc_size = self.u32(lc)
        if lc_size < 232:
            raise ValueError("load config too small")
        lc = self.rva_ptr(lc_rva, lc_size)
        if lc is None:
            raise ValueError("load config unreadable")
        chpe_va = self.u32(lc + 200) | (self.u32(lc + 204) << 32)
        if not chpe_va:
            raise ValueError("no CHPE metadata")
        chpe = self.rva_ptr(chpe_va - self.image_base, 12)
        if chpe is None:
            raise ValueError("CHPE metadata unreadable")
        map_rva, map_count = self.u32(chpe + 4), self.u32(chpe + 8)
        m = self.rva_ptr(map_rva, map_count * 8)
        if m is None:
            raise ValueError("CHPE map unreadable")
        out = []
        for i in range(map_count):
            start = self.u32(m + 8 * i)
            length = self.u32(m + 8 * i + 4)
            if (start & 3) == 2:
                out.append((start & ~3, (start & ~3) + length))
        return out

    def export_dir_rva(self):
        """x64 view export directory from the ARM64X dynamic relocations."""
        lc_rva = self.u32(self.dirs + 8 * DIR_LOAD_CONFIG)
        lc = self.rva_ptr(lc_rva, 232)
        idx = self.u16(lc + 228)
        if not idx or idx > self.nb_sec:
            return None
        sec_va = self.u32(self.sec + (idx - 1) * 40 + 12)
        dvrt_rva = sec_va + self.u32(lc + 224)
        dvrt = self.rva_ptr(dvrt_rva, 8)
        if dvrt is None or self.u32(dvrt) != 1:
            return None
        dvrt_size = self.u32(dvrt + 4)
        dvrt = self.rva_ptr(dvrt_rva, 8 + dvrt_size)
        if dvrt is None:
            return None
        exp_rva = 0
        pos = 8
        while pos + 12 <= 8 + dvrt_size:
            symbol = self.u32(dvrt + pos)
            block_size = self.u32(dvrt + pos + 8)
            end = pos + 12 + block_size
            if end > 8 + dvrt_size:
                break
            pos += 12
            if symbol != DYNAMIC_RELOCATION_ARM64X:
                pos = end
                continue
            while pos + 8 <= end:
                page = self.u32(dvrt + pos)
                blk_end = pos + self.u32(dvrt + pos + 4)
                if blk_end <= pos or blk_end > end:
                    break
                pos += 8
                while pos + 2 <= blk_end:
                    entry = self.u16(dvrt + pos)
                    rva = page + (entry & 0xFFF)
                    pos += 2
                    if not entry:
                        continue
                    kind = (entry >> 12) & 3
                    if kind == 1:
                        if (entry >> 14) == 2 and pos + 4 <= blk_end:
                            # the ARM64X block redirects the data directory array itself
                            if rva == self.dirs:
                                exp_rva = self.u32(dvrt + pos)
                        pos += 1 << (entry >> 14)
                    elif kind == 2:
                        pos += 2
                pos = blk_end
            pos = end
        return exp_rva


def fix(data, apply=False):
    pe = PE(data)
    if pe.machine == IMAGE_FILE_MACHINE_AMD64:
        ranges = None  # x86_64 PE: every export is x64 code
    elif pe.machine == IMAGE_FILE_MACHINE_ARM64:
        ranges = pe.x64_ranges()
    else:
        raise ValueError(f"unsupported machine {pe.machine:#x}")
    if pe.nb_dirs <= DIR_IAT:
        raise ValueError("no IAT directory")

    exp_rva = pe.export_dir_rva() if ranges is not None else None
    if not exp_rva:
        exp_rva = pe.u32(pe.dirs + 8 * DIR_EXPORT)
    exp = pe.rva_ptr(exp_rva, 40)
    if exp is None:
        raise ValueError("no export directory")
    exp_size = pe.u32(exp + 4)
    iat_rva = pe.u32(pe.dirs + 8 * DIR_IAT)
    iat_size = pe.u32(pe.dirs + 8 * DIR_IAT + 4)
    nb_funcs = pe.u32(exp + 20)
    funcs = pe.rva_ptr(pe.u32(exp + 28), nb_funcs * 4)
    if funcs is None:
        raise ValueError("no export address table")

    patched = skipped = 0
    for i in range(nb_funcs):
        func = pe.u32(funcs + 4 * i)
        if not func or (func & 15):
            continue
        if exp_rva <= func < exp_rva + exp_size:
            continue
        if ranges is not None and not any(a <= func and func + 16 <= b for a, b in ranges):
            continue
        code = pe.rva_ptr(func, 16)
        if code is None:
            continue
        if data[code] != 0xFF or data[code + 1] != 0x25:
            continue
        pad = data[code + 6]
        if pad and pad != 0xCC:
            skipped += 1
            continue
        if any(data[code + j] != pad for j in range(7, 16)):
            skipped += 1
            continue
        rel = struct.unpack_from("<i", data, code + 2)[0]
        target = func + 6 + rel
        if target < iat_rva or target >= iat_rva + iat_size or (target & 7):
            skipped += 1
            continue
        if apply:
            rel -= len(PROLOG)
            data[code:code + 8] = PROLOG
            data[code + 8] = 0xFF
            data[code + 9] = 0x25
            struct.pack_into("<i", data, code + 10, rel)
            data[code + 14] = data[code + 15] = pad
        patched += 1
    return patched, skipped


def main(argv):
    if len(argv) < 3 or argv[1] not in ("--check", "--apply"):
        print(__doc__.strip().splitlines()[-1])
        return 2
    apply = argv[1] == "--apply"
    total = skipped_total = files = 0
    for path in argv[2:]:
        try:
            data = bytearray(open(path, "rb").read())
            n, s = fix(data, apply)
        except Exception as e:
            print(f"  skip {path.split('/')[-1]}: {e}")
            continue
        if n:
            files += 1
            total += n
            skipped_total += s
            print(f"  {'patched' if apply else 'would patch'} {n:5d}  {path.split('/')[-1]}")
            if apply:
                open(path, "wb").write(data)
    print(f"{'patched' if apply else 'would patch'} {total} thunks in {files} files "
          f"({skipped_total} non-conforming stubs left alone)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
