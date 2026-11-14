#!/usr/bin/env python3
"""The ExitToX64 fast-forward-stub follow (build/fex-patches/0005); no device needed.

ExitToX64's ios_thunk_slot resolves an x64 import thunk to its IAT slot, then
has to decide whether the slot's value is ARM64EC code it may branch to
natively. A hybrid export's slot holds the 14-byte x64 fast-forward sequence
(FFS) that lives in .hexpthk -- and .hexpthk is NOT in the image's CodeMap as
ARM64EC, while the body it jumps to (.text) is. So the slot value always fails
the EcCodeBitMap test unless the stub is followed first, and the call falls to
emulation with no CpuStateFrame yet during the DllMain walk, which branches to
NULL (the 2026-11-14 c0000005 at pc=0, lr=ucrtbase+0x90f1c).

This pins the two facts that fix depends on, against a shipped ARM64EC image:

  - .hexpthk is outside every ARM64EC CodeMap range and .text is inside one, so
    "follow, never accept" is required -- the same invariant virtual_ios.c's
    ios_aux_native_entry states for the aux-IAT heal;
  - every FFS in .hexpthk jumps into .text, so following ONE hop is sufficient
    (the asm's bounded loop is insurance for forwarder chains, not a
    requirement), and no FFS targets a NOP landing pad, so ec-ffs-pad.py's
    repoint (which adds a second hop) is not part of any built image.

It also checks that Module.S's byte predicates agree with the C reference in
virtual_ios.c's ios_aux_ec_target, because two independent decoders of the same
16 bytes must not drift: the asm tests qword@0 == 48 8b c4 48 89 58 20 55 and
ldrh@8 == 5d e9, i.e. ten bytes, and computes v + 14 + rel32.
"""
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parents[2]
failures = []

def check(cond, what):
    print(('PASS ' if cond else 'FAIL ') + what)
    if not cond:
        failures.append(what)

virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
module_s = (root / 'FEX/Source/Windows/ARM64EC/Module.S').read_text()

# --- 1. The FFS bytes are the same ten in both decoders -----------------------
FFS = bytes([0x48, 0x8b, 0xc4, 0x48, 0x89, 0x58, 0x20, 0x55, 0x5d, 0xe9])

# The C reference, from virtual_ios.c's ios_aux_ec_target.
i = virtual.index('static int ios_aux_ec_target(')
ref = virtual[i:virtual.index('\n}', i)]
cbytes = [int(x, 16) for x in
          __import__('re').findall(r'0x([0-9a-fA-F]{2})', ref[:ref.index('}')])][:10]
check(bytes(cbytes) == FFS,
      'virtual_ios.c ios_aux_ec_target still decodes 48 8b c4 48 89 58 20 55 5d e9')

# The asm builds the same qword from movz/movk and compares ldrh@8.
qword = 0x8b48 | (0x48c4 << 16) | (0x5889 << 32) | (0x5520 << 48)
check(qword.to_bytes(8, 'little') == FFS[0:8],
      'Module.S movz/movk qword predicate covers FFS bytes 0..7')
check(int.from_bytes(FFS[8:10], 'little') == 0xE95D,
      'Module.S ldrh predicate covers FFS bytes 8..9 (5d e9)')
for insn in ('movz x23, #0x8b48', 'movk x23, #0x48c4, lsl #16',
             'movk x23, #0x5889, lsl #32', 'movk x23, #0x5520, lsl #48',
             'movz w23, #0xe95d', 'ldursw x16, [x17, #10]', 'add x17, x17, #14'):
    check(insn in module_s, 'Module.S still contains `%s`' % insn)

# --- 2. Shipped hybrids: .hexpthk is not EC, .text is ------------------------
# ucrtbase is the module the 2026-11-14 crash exits from, so it is the one that
# matters most; kernel32/kernelbase hold the forwarders the chain walks through.
MODULES = ['ucrtbase.dll', 'kernel32.dll', 'ntdll.dll', 'kernelbase.dll']
seen = 0
for name in MODULES:
    pe_path = root / 'app/Madeira/arm64ec-windows' / name
    if not pe_path.exists():
        continue
    seen += 1
    d = pe_path.read_bytes()
    e = struct.unpack_from('<I', d, 0x3c)[0]
    nsec = struct.unpack_from('<H', d, e + 6)[0]
    optsz = struct.unpack_from('<H', d, e + 20)[0]
    image_base = struct.unpack_from('<Q', d, e + 24 + 0x18)[0]
    machine = struct.unpack_from('<H', d, e + 4)[0]
    if machine != 0x8664:
        continue

    so = e + 24 + optsz
    secs = {}
    for s in range(nsec):
        o = so + s * 40
        nm = d[o:o + 8].rstrip(b'\0').decode('latin1')
        vs, va, rs, rp = struct.unpack_from('<IIII', d, o + 8)
        secs[nm] = (va, vs, rp, rs)
    if '.hexpthk' not in secs:
        continue

    # ARM64EC ranges from IMAGE_ARM64EC_METADATA::CodeMap, reached via LoadConfig.
    dd = e + 24 + 0x70
    lc_rva, _lc_sz = struct.unpack_from('<II', d, dd + 10 * 8)
    chpe = struct.unpack_from('<Q', d, lc_rva + 0xC8)[0]
    cm_rva, cm_cnt = struct.unpack_from('<II', d, chpe - image_base + 4)
    ec = []
    for k in range(cm_cnt):
        st, ln = struct.unpack_from('<II', d, cm_rva + k * 8)
        if (st & 3) == 1:
            ec.append((st & ~3, ln))
    check(len(ec) > 0, '%s: CodeMap declares an ARM64EC range' % name)

    def ec_marks(rva, _ec=ec):
        return any(a <= rva < a + n for a, n in _ec)

    check(not ec_marks(secs['.hexpthk'][0]),
          '%s: .hexpthk is NOT ARM64EC (an FFS slot value can never pass the bitmap '
          'test -- it must be followed, never accepted)' % name)
    check(ec_marks(secs['.text'][0]),
          '%s: .text IS ARM64EC (so the FFS target does pass it)' % name)

    # --- 3. Every FFS jumps into EC-marked .text, none to a NOP pad -----------
    va, vs, rp, _rs = secs['.hexpthk']
    total = into_ec = padded = 0
    for off in range(0, vs - 10, 16):
        if d[rp + off:rp + off + 10] != FFS:
            continue
        rel = struct.unpack_from('<i', d, rp + off + 10)[0]
        tgt = va + off + 14 + rel      # v + 14 + rel32, as both decoders compute
        total += 1
        if ec_marks(tgt):
            into_ec += 1
        for _nm, (sva, svs, srp, _srs) in secs.items():
            if sva <= tgt < sva + svs and d[srp + (tgt - sva):srp + (tgt - sva) + 4] == b'\x90' * 4:
                padded += 1
                break
    check(total > 0, '%s: .hexpthk holds fast-forward sequences (%d)' % (name, total))
    check(into_ec == total,
          '%s: every FFS target is ARM64EC (%d/%d), so one hop suffices' % (name, into_ec, total))
    check(padded == 0,
          '%s: no FFS targets a NOP landing pad (%d), so ec-ffs-pad.py is not in a built image'
          % (name, padded))

check(seen > 0, 'at least one shipped ARM64EC hybrid image was available to check')

print('\n%d failure(s)' % len(failures) if failures else '\nall checks passed')
sys.exit(1 if failures else 0)
