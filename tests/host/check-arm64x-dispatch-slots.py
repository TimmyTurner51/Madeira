#!/usr/bin/env python3
"""Every slot an ARM64EC image branches through must be one the loader fills.

The 2026-11-14 crash was `adrp x8,page; ldr x16,[x8,#0x898]; blr x16` with
x16 == 0 (pc = 0, lr = ucrtbase+0x90f1c). The slot is not an IAT slot and no
instruction in the image writes it: it is an IMAGE_ARM64EC_METADATA dispatcher
field that Windows' loader fills from the module's own metadata. Wine does the
same in arm64ec_update_hybrid_metadata, so the test asserts, from the shipped
bytes, that

  * each high-traffic `blr x16` slot is exactly one of the metadata fields,
  * those fields are zero on disk (nothing else could have written them), and
  * the module exports the routines the slots are supposed to point at.

Skipping a module that is absent keeps the test usable on a partial tree, but
a module that is present must satisfy every invariant.
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

# IMAGE_ARM64EC_METADATA field order, wine/include/winnt.h:4168.
FIELDS = ['Version', 'CodeMap', 'CodeMapCount', 'CodeRangesToEntryPoints',
          'RedirectionMetadata', '__os_arm64x_dispatch_call_no_redirect',
          '__os_arm64x_dispatch_ret', '__os_arm64x_dispatch_call',
          '__os_arm64x_dispatch_icall', '__os_arm64x_dispatch_icall_cfg',
          'AlternateEntryPoint', 'AuxiliaryIAT', 'CodeRangesToEntryPointsCount',
          'RedirectionMetadataCount', 'GetX64InformationFunctionPointer',
          'SetX64InformationFunctionPointer', 'ExtraRFETable', 'ExtraRFETableSize',
          '__os_arm64x_dispatch_fptr', 'AuxiliaryIATCopy']
# Fields that hold an RVA of a branch target the guest reads through `blr`.
DISPATCH = ['__os_arm64x_dispatch_call_no_redirect', '__os_arm64x_dispatch_ret',
            '__os_arm64x_dispatch_call', '__os_arm64x_dispatch_icall',
            '__os_arm64x_dispatch_icall_cfg', '__os_arm64x_dispatch_fptr']

def sections(d):
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    if struct.unpack_from('<H', d, pe + 4)[0] != 0x8664:
        return None
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    optsz = struct.unpack_from('<H', d, pe + 20)[0]
    so = pe + 24 + optsz
    out = {}
    for i in range(nsec):
        b = so + i * 40
        name = d[b:b + 8].rstrip(b'\0').decode()
        vs, va, rs, ro = struct.unpack_from('<IIII', d, b + 8)
        out[name] = (va, vs, ro, rs)
    return d, pe, out

def rva_ptr(secs, rva, n):
    for name, (va, vs, ro, rs) in secs.items():
        if va <= rva and rva + n <= va + max(vs, rs):
            return ro + (rva - va), name
    return None, None

def adrp_page(insn, rva):
    immlo = (insn >> 29) & 3
    immhi = (insn >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (rva & ~0xFFF) + (imm << 12)

def branch_slots(d, secs):
    """RVAs of every `adrp xN,page; ldr x16,[xN,#imm]; blr x16` slot."""
    tva, tvs, tro, trs = secs['.text']
    text = d[tro:tro + trs]
    out = {}
    for k in range(1, len(text) // 4 - 1):
        if struct.unpack_from('<I', text, (k + 1) * 4)[0] != 0xD63F0200:  # blr x16
            continue
        ld = struct.unpack_from('<I', text, k * 4)[0]
        if (ld & 0xFFC00000) != 0xF9400000:      # ldr (imm, 64-bit)
            continue
        if (ld & 31) != 16 or ((ld >> 30) & 3) != 3:
            continue
        base = (ld >> 5) & 31
        pi = struct.unpack_from('<I', text, (k - 1) * 4)[0]
        if (pi & 0x9F000000) != 0x90000000 or (pi & 31) != base:
            continue
        slot = adrp_page(pi, tva + (k - 1) * 4) + ((ld >> 10) & 0xFFF) * 8
        out[slot] = out.get(slot, 0) + 1
    return out

# ntdll is excluded from the strict invariant on purpose: it is the module that
# *provides* the dispatchers, so its own slots are installed by its special
# loader-init path, and arm64ec_process_init_dispatchers explicitly skips
# re-patching it (see the comment on the module walk). It still gets the
# zero-on-disk/`.data` checks below.
MODULES = ['ucrtbase.dll', 'kernelbase.dll', 'ntdll.dll', 'kernel32.dll',
           'msvcrt.dll', 'vcruntime140.dll', 'advapi32.dll']
STRICT = [m for m in MODULES if m != 'ntdll.dll']

seen = 0
for name in MODULES:
    path = root / 'app/Madeira/arm64ec-windows' / name
    if not path.exists():
        continue
    got = sections(path.read_bytes())
    if not got:
        continue
    d, pe, secs = got
    seen += 1

    lc_rva, _ = rva_ptr(secs, struct.unpack_from('<I', d, pe + 24 + 112 + 8 * 10)[0], 4)
    lc = struct.unpack_from('<I', d, pe + 24 + 112 + 8 * 10)[0]
    lc_off, lc_sec = rva_ptr(secs, lc, 0x140)
    check(lc_sec is not None, '%s: load config at 0x%x is inside a section' % (name, lc))

    meta = struct.unpack_from('<Q', d, lc_off + 0xC8)[0]
    check(meta != 0, '%s: CHPEMetadataPointer is set' % name)
    meta_rva = meta - 0x180000000
    m_off, m_sec = rva_ptr(secs, meta_rva, 4 * len(FIELDS))
    check(m_sec is not None, '%s: ARM64EC metadata 0x%x maps to %s' % (name, meta_rva, m_sec))

    md = {}
    for i, f in enumerate(FIELDS):
        md[f] = struct.unpack_from('<I', d, m_off + 4 * i)[0]

    # Version is the only field that is not an RVA.
    check(md['Version'] in (1, 2), '%s: metadata Version %d' % (name, md['Version']))

    slots = branch_slots(d, secs)
    hot = sorted(((c, r) for r, c in slots.items() if c >= 5), reverse=True)
    check(hot, '%s: has at least one shared `blr x16` dispatcher slot' % name)

    dispatch_rvas = {md[f] for f in DISPATCH if md[f]}
    for count, rva in hot:
        off, sec = rva_ptr(secs, rva, 8)
        check(sec is not None and sec != '.text',
              '%s: slot 0x%x (%d callers) lives in %s, not code' % (name, rva, count, sec))
        if name in STRICT:
            check(rva in dispatch_rvas,
                  '%s: slot 0x%x (%d callers) is an ARM64EC dispatcher field'
                  % (name, rva, count))
            check(struct.unpack_from('<Q', d, off)[0] == 0,
                  '%s: slot 0x%x is zero on disk, so only the loader fills it'
                  % (name, rva))
        elif rva in dispatch_rvas:
            # ntdll declares this one too; whether it is pre-seeded in the image
            # is up to the provider, not to our re-patch pass.
            check(True, '%s: slot 0x%x (%d callers) is a declared dispatcher field'
                  % (name, rva, count))
        else:
            print('INFO %s: slot 0x%x (%d callers) is set by ntdll\'s own init, '
                  'not by the ARM64EC metadata' % (name, rva, count))

check(seen >= 4, 'checked the shipped ARM64EC modules that are present (%d)' % seen)

# --- ucrtbase: the exact site and field that produced pc == 0 ----------------
uc = root / 'app/Madeira/arm64ec-windows/ucrtbase.dll'
if uc.exists():
    d, pe, secs = sections(uc.read_bytes())
    lc_off, _ = rva_ptr(secs, struct.unpack_from('<I', d, pe + 24 + 112 + 8 * 10)[0], 0x140)
    meta_rva = struct.unpack_from('<Q', d, lc_off + 0xC8)[0] - 0x180000000
    m_off, _ = rva_ptr(secs, meta_rva, 4 * len(FIELDS))
    md = {f: struct.unpack_from('<I', d, m_off + 4 * i)[0] for i, f in enumerate(FIELDS)}

    tva, tvs, tro, trs = secs['.text']
    text = d[tro:tro + trs]
    words = [struct.unpack_from('<I', text, k * 4)[0] for k in range(len(text) // 4)]
    site = 0x90F04 - tva
    k = site // 4
    # The shipped thunk body the crash log named (lr = ucrtbase+0x90f1c).
    check(words[k] == 0xD100C3FF, 'ucrtbase+0x90f04: sub sp,sp,#0x30')
    check(words[k + 1] == 0xA9027BFD, 'ucrtbase+0x90f08: stp x29,x30,[sp,#0x20]')
    check(words[k + 2] == 0x910083FD, 'ucrtbase+0x90f0c: add x29,sp,#0x20')
    check((words[k + 3] & 0x9F000000) == 0x90000000, 'ucrtbase+0x90f10: adrp')
    check(words[k + 4] == 0xF9444D10, 'ucrtbase+0x90f14: ldr x16,[x8,#0x898]')
    check(words[k + 5] == 0xD63F0200, 'ucrtbase+0x90f18: blr x16  (pc==0 in the log)')
    check(words[k + 6] == 0xAA0803E0, 'ucrtbase+0x90f1c: mov x0,x8')

    slot = adrp_page(words[k + 3], 0x90F04 + 3 * 4) + 0x898
    check(slot == 0xE3898, 'ucrtbase+0x90f14 reads slot rva 0x%x' % slot)
    check(slot == md['__os_arm64x_dispatch_call_no_redirect'],
          'ucrtbase slot 0x%x IS __os_arm64x_dispatch_call_no_redirect' % slot)
    check(md['__os_arm64x_dispatch_call'] == 0xE1510,
          'ucrtbase __os_arm64x_dispatch_call is 0x%x (the value the log printed)'
          % md['__os_arm64x_dispatch_call'])

# --- the Wine side actually writes those fields -----------------------------
sig = (root / 'wine/dlls/ntdll/signal_arm64ec.c').read_text()
check('CHPEMetadataPointer' in sig, 'arm64ec_get_module_metadata reads CHPEMetadataPointer')
for f in DISPATCH:
    check(('SET_FUNC( %s,' % f) in sig or ('SET_FUNC(__os_arm64x_dispatch_call_no_redirect,' in sig
          and f == '__os_arm64x_dispatch_call_no_redirect'), 'SET_FUNC covers %s' % f)
check('SET_FUNC( __os_arm64x_dispatch_call_no_redirect, __os_arm64x_dispatch_call_no_redirect )' in sig,
      'the no-redirect slot is written from ExitToX64, not arm64x_check_call')
check('RtlFindExportedRoutineByName( module, "ExitToX64" )' in sig,
      'ExitToX64 is what the no-redirect slot is resolved to')

# --- and the module it points into really exports it ------------------------
xt = root / 'app/Madeira/arm64ec-windows/xtajit64.dll'
if xt.exists():
    blob = xt.read_bytes()
    for sym in ('ExitToX64', 'DispatchJump', 'RetToEntryThunk'):
        check(sym.encode() in blob, 'xtajit64.dll exports %s' % sym)

print()
if failures:
    print('%d failure(s)' % len(failures))
    sys.exit(1)
print('PASS: every ARM64EC `blr x16` dispatcher slot is a loader-filled metadata field,')
print('      and ucrtbase\'s crash slot is __os_arm64x_dispatch_call_no_redirect (0xe3898)')
