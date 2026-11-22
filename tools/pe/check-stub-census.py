#!/usr/bin/env python3
"""Check the [stub-census] parser against a real image, before it ever runs on device.

    tools/pe/check-stub-census.py <image.exe>

Why this exists. The first [stub-census] build was silent on device, and the cause
was its own header handling: it read 130 bytes of optional header, so the
data-directory entry it needs (index 3, at offset 136 for PE32+) was outside the
buffer, and its bounds check returned without printing. A probe that cannot say
"here is what I saw" is indistinguishable from a negative result, so the fix was
twofold: read 264 bytes, and print a reason code on every path.

This script is the offline half of that: it runs the SAME walk the C code runs,
from the same fields, and compares the count with tools/pe/protected-stubs.py.
Run it after touching the C parser; it costs no device launch.

It reproduces the C code's arithmetic literally (including the byte offsets) so a
transcription mistake here or there shows up as a count mismatch rather than a
plausible number.
"""

import struct
import subprocess
import sys
import os
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def sections(data):
    """(va, vsize, raw_off, raw_size) per section — the mapping the loader builds."""
    e = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, e + 6)[0]
    optsz = struct.unpack_from("<H", data, e + 20)[0]
    base = e + 24 + optsz
    out = []
    for i in range(nsec):
        s = data[base + i * 40: base + i * 40 + 40]
        vsz, va, rsz, roff = struct.unpack_from("<IIII", s, 8)
        out.append((va, vsz, roff, rsz))
    return out


def rva_to_off(secs, rva):
    """File offset for an RVA, or None for a byte the mapping zero-fills.

    The image the device walks is the MAPPING, where RVA and address offset are
    the same number. A file is not: .pdata sits at RVA 0xac00000 but at file
    offset 0xa7c4600. Getting this wrong is how the first offline check reported
    'pdata-outside-image' against a perfectly good image -- so it is done by the
    section table here, exactly as the loader does it.
    """
    for va, vsz, roff, rsz in secs:
        if va <= rva < va + max(vsz, rsz):
            delta = rva - va
            if delta < rsz:
                return roff + delta
            return None
    return None


def walk(data):
    """Exactly ios_stub_census_image, reading through the loader's mapping."""
    if len(data) < 0x1000:
        return 0, 0, "no-dos-header"
    if data[0:2] != b"MZ":
        return 0, 0, "no-dos-header"
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if e_lfanew > 0x1000 or e_lfanew + 24 + 264 > len(data):
        return 0, 0, "no-dos-header"
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return 0, 0, "not-pe32"
    magic = struct.unpack_from("<H", data, e_lfanew + 24)[0]
    if magic not in (0x20B, 0x10B):
        return 0, 0, "bad-magic"
    dir_off = e_lfanew + 24 + (112 if magic == 0x20B else 96)
    exc_rva, exc_size = struct.unpack_from("<II", data, dir_off + 3 * 8)
    if not exc_rva or exc_size < 12 or exc_size > 0x4000000:
        return 0, 0, "no-pdata"

    soc = sections(data)
    soimage = struct.unpack_from("<I", data, e_lfanew + 24 + 56)[0]
    if exc_rva + exc_size > soimage:
        return 0, 0, "pdata-outside-image"

    n = cipher = 0
    for i in range(exc_size // 12):
        entry_off = rva_to_off(soc, exc_rva + i * 12)
        if entry_off is None or entry_off + 4 > len(data):
            continue
        rva = struct.unpack_from("<I", data, entry_off)[0]
        if not rva or rva >= soimage:
            continue
        n += 1
        insn_off = rva_to_off(soc, rva)
        if insn_off is None or insn_off >= len(data):
            continue                      # zero-filled page: not executable code
        if data[insn_off] == 0xEA:
            cipher += 1
    return n, cipher, None


def main():
    image = sys.argv[1]
    data = open(image, "rb").read()
    n, cipher, why = walk(data)

    with tempfile.TemporaryDirectory() as t:
        out = os.path.join(t, "stubs.txt")
        subprocess.run([sys.executable, os.path.join(HERE, "protected-stubs.py"),
                        image, "--watch-list", out],
                       check=True, stdout=subprocess.DEVNULL)
        expected = sum(1 for line in open(out) if line.strip())

    print(f"image            : {image}")
    print(f".pdata functions : {n}")
    print(f"0xEA entries     : {cipher}")
    print(f"reason code      : {why or '(none: parsed)'}")
    print(f"protected-stubs  : {expected} stubs")
    if why:
        print("FAIL: the parser bailed on a real image, which is exactly the bug this checks")
        return 1
    if n != 414805 or cipher != expected:
        print(f"FAIL: expected {414805} functions / {expected} stubs for this build")
        return 1
    print("OK: counts match the independent enumerator")
    return 0


if __name__ == "__main__":
    sys.exit(main())
