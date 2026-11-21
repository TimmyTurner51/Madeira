#!/usr/bin/env python3
"""Enumerate the protected function entries in a PE image.

    tools/pe/protected-stubs.py <image.exe> [--watch-list out.txt]

Why this exists. Forza Horizon 6's protector does not encrypt whole sections; it
encrypts a stub at the entry of selected functions and decrypts it in place at
run time. Measured on the build the iPhone runs (2026-11-21, see
docs/compatibility/forza-horizon-6-ios.md):

    .pdata functions            414,805
    entries beginning with 0xEA   4,538  (1.09%)
    distinct 5-byte stubs           247
    stub length                       5  == sizeof(jmp rel32)

0xEA is the x86 far-jump opcode and is INVALID in 64-bit mode, so a function
whose first byte is 0xEA cannot be executing what is on disk. Confirmed
independently: at fault time guest memory was byte-identical to the file.

That makes the stub set enumerable offline, which is the point of this script.
A run-time probe can be handed `--watch-list` and report the FIRST guest write
whose range touches any of these RVAs. That single observation splits the two
remaining explanations:

    never written  -> the protector's decrypt path never ran
    written, stale -> FEX's self-modifying-code invalidation missed it

The list is RVAs relative to the image base, one hex value per line, so it stays
valid wherever the loader places the image (this image's preferred base is
refused and it ends up in the JIT pool).

This is a diagnostic. It reports where protection lives; it does not decrypt
anything, and it must not be used to. Turning a platform-fidelity bug into "make
the protector believe it is not emulated" is out of scope for this project.
"""

import argparse
import struct
import sys

# 0xEA = far jmp; invalid in 64-bit mode, so it can only be an encrypted stub.
STUB_FIRST_BYTE = 0xEA


def parse_pe(data):
    if data[:2] != b"MZ":
        raise SystemExit("not a PE: missing MZ")
    e = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e:e + 4] != b"PE\0\0":
        raise SystemExit("not a PE: missing PE signature")
    nsections, = struct.unpack_from("<H", data, e + 6)
    optsize, = struct.unpack_from("<H", data, e + 20)
    opt = e + 24
    magic, = struct.unpack_from("<H", data, opt)
    if magic == 0x20B:
        dd = opt + 112
    elif magic == 0x10B:
        dd = opt + 96
    else:
        raise SystemExit(f"unsupported optional-header magic {magic:#x}")

    sections = []
    secoff = opt + optsize
    for i in range(nsections):
        o = secoff + i * 40
        name = data[o:o + 8].rstrip(b"\0").decode(errors="replace")
        vsize, va, rsize, rawoff = struct.unpack_from("<IIII", data, o + 8)
        sections.append((name, va, vsize, rawoff, rsize))

    def rva_to_offset(rva):
        for _, va, vsize, rawoff, rsize in sections:
            if va <= rva < va + max(vsize, rsize):
                delta = rva - va
                if delta >= rsize:      # virtual tail with no file backing
                    return None
                return rawoff + delta
        return None

    return sections, rva_to_offset, dd


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--watch-list", metavar="PATH",
                    help="write the stub RVAs, one hex value per line")
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        data = f.read()

    sections, rva_to_offset, dd = parse_pe(data)
    exc_rva, exc_size = struct.unpack_from("<II", data, dd + 3 * 8)
    if not exc_rva or not exc_size:
        raise SystemExit("no exception directory (.pdata) -- is this a 64-bit image?")

    exc_off = rva_to_offset(exc_rva)
    if exc_off is None:
        raise SystemExit("exception directory is not file-backed")
    count = exc_size // 12

    stubs = []
    for i in range(count):
        begin, end, _unwind = struct.unpack_from("<III", data, exc_off + i * 12)
        off = rva_to_offset(begin)
        if off is None or data[off] != STUB_FIRST_BYTE:
            continue
        stubs.append((begin, end, data[off:off + 5]))

    print(f"image      : {args.image}")
    print(f"sections   : {len(sections)}")
    print(f".pdata     : {count} functions")
    print(f"stub starts: {len(stubs)} ({100.0 * len(stubs) / max(count, 1):.2f}%)")

    if stubs:
        distinct = {}
        for _begin, _end, five in stubs:
            distinct[five] = distinct.get(five, 0) + 1
        print(f"distinct 5-byte stubs: {len(distinct)}")
        for five, n in sorted(distinct.items(), key=lambda kv: -kv[1])[:5]:
            print(f"  {five.hex()}  x{n}")

    if args.watch_list:
        with open(args.watch_list, "w") as f:
            for begin, _end, _five in sorted(stubs):
                f.write(f"{begin:#x}\n")
        print(f"wrote {len(stubs)} RVAs to {args.watch_list}")
        print("note: RVAs are image-relative; a run-time probe must add the loaded base")

    return 0


if __name__ == "__main__":
    sys.exit(main())
