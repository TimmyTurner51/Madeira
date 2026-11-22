#!/usr/bin/env python3
"""Put an ARM64EC builtin's import thunks back to the bare `ff 25` form.

Companion to pe-thunks.py: it reads the prologue bytes out of a builtin, this
writes the original thunk back. Used to separate two explanations for a build
behaving differently from the one in the app bundle -- "the hotpatch prologues
changed something" versus "this whole DLL is from a different build".

    tools/local/pe-unthunk.py <in.dll> <out.dll>
"""
import struct
import sys


def sections(d):
    nt = struct.unpack_from('<I', d, 0x3c)[0]
    nsec = struct.unpack_from('<H', d, nt + 6)[0]
    opt = nt + 24
    secoff = opt + struct.unpack_from('<H', d, nt + 20)[0]
    return [struct.unpack_from('<IIII', d, secoff + 40 * i + 8) for i in range(nsec)], opt


def size_of_headers(d, opt):
    return struct.unpack_from('<I', d, opt + 60)[0]


def offset_of(d, secs, rva):
    for vsize, va, rsize, ptr in secs:
        if va <= rva < va + max(vsize, rsize):
            return ptr + (rva - va)
    return None


PROLOG = bytes.fromhex('488da42400000000')


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d = bytearray(open(src, 'rb').read())
    secs, opt = sections(d)
    hdr = size_of_headers(d, opt)
    export_rva = struct.unpack_from('<I', d, opt + 112)[0]
    e = offset_of(d, secs, export_rva)
    nfuncs = struct.unpack_from('<I', d, e + 20)[0]
    funcs_rva = struct.unpack_from('<I', d, e + 28)[0]
    f = offset_of(d, secs, funcs_rva)
    iat_rva, iat_size = struct.unpack_from('<II', d, opt + 112 + 8 * 12)

    undone = 0
    for i in range(nfuncs):
        rva = struct.unpack_from('<I', d, f + 4 * i)[0]
        if not rva:
            continue
        o = offset_of(d, secs, rva)
        if o is None or o < hdr or o + 16 > len(d):
            continue
        if d[o:o + 8] != PROLOG or d[o + 8] != 0xff or d[o + 9] != 0x25:
            continue
        rel = struct.unpack_from('<i', d, o + 10)[0]
        target = rva + 14 + rel
        if not (iat_rva <= target < iat_rva + iat_size) or target & 7:
            continue
        pad = d[o + 14]
        if any(d[o + 15:o + 16]) != any(bytes([pad])):
            continue
        back = target - (rva + 6)
        d[o:o + 16] = b'\xff\x25' + struct.pack('<i', back) + bytes([pad]) * 10
        undone += 1

    open(dst, 'wb').write(d)
    print(f'{dst}: restored {undone} bare thunk(s)')


if __name__ == '__main__':
    main()
