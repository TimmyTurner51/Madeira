#!/usr/bin/env python3
"""ml2030 FPPROBE: the ownership ladder that decides jetsam-exempt memory; no Wine runs.

The ml458 ladder over the pool's EXISTING mappings came back kr=4 for every
(entry-flags, owner) pair (device runs protprobe/001-002). The xnu source
(osfmk/vm/vm_memory_entry.c, mach_memory_entry_ownership) explains why: an
entry must be "fully owned" -- its objects already owned or external (file
backed) -- or the call returns KERN_INVALID_ARGUMENT before the owner/flags
matter. The debugger's _M pool pages are internal and unowned, so no entry over
them can ever be made no-footprint.

The probe therefore tests CREATION recipes (named/create, named/tagged,
named/purgeable, file-backed) plus the anon baseline, and reads the
phys_footprint delta around every ownership call as the verdict. This check is
textual (the probe runs on device, where only the kernel can answer):

  - JITAllocator.c carries the ladder in order, with the kernel model comment,
    the fixed VM_LEDGER_TAG_DEFAULT = 1 (xnu's value; 0 is TAG_NONE), the
    footprint delta in every verdict line, and the bless test behind
    MADEIRA_FP_PROBE_BLESS on a watchdog thread (a TXM rejection may not
    signal);
  - the anon baselines expect failure and the no-gate control expects success,
    so the log lines say [UNEXPECTED] on this kernel if the model is wrong;
  - StikJITHelper.allocatePool runs the probe once per app run behind
    env.MADEIRA_FP_PROBE = 1, inside the debugger window the bless half needs.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
c = (root / 'app/Madeira/JITAllocator.c').read_text()
h = (root / 'app/Madeira/JITAllocator.h').read_text()
swift = (root / 'app/Madeira/StikJITHelper.swift').read_text()

# The kernel model is written down where the next person will look.
assert 'is_fully_owned' in c, 'the probe must name the kernel gate it works around'
assert 'KERN_INVALID_ARGUMENT' in c and 'KERN_NO_ACCESS' in c, 'kr=4 vs kr=5 must be in the comment'

# The ladder, in order, one variant per creation recipe plus the baselines.
ladder = ['named/create tag0', 'named/create tag1', 'named/tagged nofoot',
          'named/tagged owner-only', 'named/tagged owner->nofp',
          'named/purgeable nofoot', 'anon/plain-entry nofoot',
          'anon/share-entry nofoot', 'filebacked nofoot']
positions = [c.index('"%s"' % name) for name in ladder]
assert positions == sorted(positions), 'the fp-probe ladder must run in documented order'

# Each verdict carries the billing story: footprint either side and the delta.
assert 'fp %llu -> %llu MB (delta %lld MB)' in c, 'the footprint delta is the verdict'

# tag=0 vs tag=1 both present: the constant bug (xnu VM_LEDGER_TAG_DEFAULT is 1)
# must stay measurable, and the define must be fixed to the kernel value.
assert 'named/create tag0' in c and 'named/create tag1' in c
assert '#define VM_LEDGER_TAG_DEFAULT 1' in c, 'VM_LEDGER_TAG_DEFAULT must be xnu\'s 1, not 0'

# Expectations: the anon baselines reproduce today's failure (expect 0), the
# no-gate control must succeed (expect 1); anything else prints [UNEXPECTED].
assert 'anon/plain-entry nofoot' in c and 'anon/share-entry nofoot' in c
assert 'named/tagged owner-only' in c
assert 'fp_probe_try("named/tagged owner-only", e, p, FPPROBE_TAG_DEFAULT_FIXED, 0, 1, 1)' in c, \
    'the no-gate control must expect success'

# The bless half: gated, watchdogged, and honest about its three failure modes.
assert 'MADEIRA_FP_PROBE_BLESS' in c, 'the bless test must be opt-in'
assert 'sigsetjmp' in c and 'pthread_create' in c, 'the bless test must run on a watchdog thread'
assert 'WATCHDOG' in c

# The header exposes it; the app runs it once, behind the flag, inside the
# debugger window (allocatePool is where a debugger is guaranteed live).
assert 'void jit_footprint_probe(int bless);' in h
assert 'fpProbed' in swift and 'jit_footprint_probe(' in swift
assert 'MadeiraConfig.flag("MADEIRA_FP_PROBE", fallback: false)' in swift, \
    'the probe must be opt-in via env.MADEIRA_FP_PROBE'

print('check-footprint-probe: PASS')
