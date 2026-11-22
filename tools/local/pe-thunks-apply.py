#!/usr/bin/env python3
"""Give named ARM64EC import thunks the Windows hotpatch prologue.

The reference fix for FH6 (and `build/wine-patches/0001`) rewrites every import
thunk in an ARM64EC builtin. That is the right shape, but it is also the reason
a rebuilt `kernel32.dll` makes the Steam dock stop authorising launches: 792
exports change their first bytes at once, and the dock is a consumer of that
same DLL.

Anti-tamper only inspects the functions a binary actually imports, so this tool
patches the prologue on exactly those exports and leaves every other export
byte-identical:

    tools/local/pe-thunks-apply.py <in.dll> <out.dll> <names.txt>

`names.txt` is one export name per line (see the FH6 list in
`docs/compatibility/forza-horizon-6-ios.md`). A name that is not an
`ff 25` import thunk in a 16-byte slot is reported and skipped, never guessed
at -- forwarders and real function bodies must stay untouched.
"""
import struct
import sys

PROLOG = bytes.fromhex('488da42400000000')


def table(d):
    nt = struct.unpack_from('<I', d, 0x3c)[0]
    nsec = struct.unpack_from('<H', d, nt + 6)[0]
    opt = nt + 24
    secoff = opt + struct.unpack_from('<H', d, nt + 20)[0]
    secs = []
    for i in range(nsec):
        vs, va, rs, p = struct.unpack_from('<IIII', d, secoff + 40 * i + 8)
        secs.append((va, vs, rs, p))
    return secs, opt


def rva2off(secs, rva):
    for va, vs, rs, p in secs:
        if va <= rva < va + max(vs, rs):
            return p + (rva - va)
    return None


def in_vsize(secs, rva, length):
    """The section's mapped extent, not its file padding (see patch 0001)."""
    for va, vs, rs, p in secs:
        if va <= rva < va + vs and vs - (rva - va) >= length:
            return True
    return False


def main():
    src, dst, listpath = sys.argv[1], sys.argv[2], sys.argv[3]
    want = {l.strip() for l in open(listpath) if l.strip()}
    d = bytearray(open(src, 'rb').read())
    secs, opt = table(d)
    exp_rva = struct.unpack_from('<I', d, opt + 112)[0]
    e = rva2off(secs, exp_rva)
    nfuncs = struct.unpack_from('<I', d, e + 20)[0]
    nnames = struct.unpack_from('<I', d, e + 24)[0]
    funcs_rva = struct.unpack_from('<I', d, e + 28)[0]
    names_rva = struct.unpack_from('<I', d, e + 32)[0]
    ords_rva = struct.unpack_from('<I', d, e + 36)[0]
    f = rva2off(secs, funcs_rva)
    n = rva2off(secs, names_rva)
    o_ = rva2off(secs, ords_rva)
    iat_rva, iat_size = struct.unpack_from('<II', d, opt + 112 + 8 * 12)

    patched, skipped, missing = [], [], []
    for i in range(nnames):
        name_rva = struct.unpack_from('<I', d, n + 4 * i)[0]
        no = rva2off(secs, name_rva)
        name = d[no:d.index(b'\0', no)].decode('latin1')
        if name not in want:
            continue
        idx = struct.unpack_from('<H', d, o_ + 2 * i)[0]
        if idx >= nfuncs:
            missing.append(name)
            continue
        rva = struct.unpack_from('<I', d, f + 4 * idx)[0]
        if not rva:
            skipped.append((name, 'forwarder'))
            continue
        if rva & 15:
            skipped.append((name, 'thunk not 16-byte aligned'))
            continue
        if not in_vsize(secs, rva, 16):
            skipped.append((name, 'no room inside VirtualSize'))
            continue
        o = rva2off(secs, rva)
        if d[o:o + 2] != b'\xff\x25':
            skipped.append((name, 'export is not an ff 25 thunk'))
            continue
        pad = d[o + 6]
        if pad not in (0, 0xcc) or any(d[o + j] != pad for j in range(7, 16)):
            skipped.append((name, 'thunk slot is not padded'))
            continue
        rel = struct.unpack_from('<i', d, o + 2)[0]
        target = rva + 6 + rel
        if not (iat_rva <= target < iat_rva + iat_size) or target & 7:
            skipped.append((name, 'jump target is not an IAT slot'))
            continue
        rel -= len(PROLOG)
        d[o:o + 8] = PROLOG
        d[o + 8] = 0xff
        d[o + 9] = 0x25
        d[o + 10:o + 14] = struct.pack('<i', rel)
        d[o + 14] = d[o + 15] = pad
        patched.append(name)

    open(dst, 'wb').write(d)
    print(f'{dst}: patched {len(patched)} of {len(want)} requested')
    for name, why in skipped:
        print(f'  skipped {name}: {why}')
    if missing:
        print(f'  not exported here: {len(missing)} ({", ".join(missing[:6])})')


if __name__ == '__main__':
    main()
