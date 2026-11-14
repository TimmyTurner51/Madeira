#!/usr/bin/env python3
"""Stack balance of ExitToX64's dispatch paths (FEX/Source/Windows/ARM64EC/Module.S).

Two different callers reach the shared "reject into emulation" tail, and only
one of them has pushed a frame:

  ios_ffs_check    ... stp x4, x9, [sp, #-16]! ... -> ios_ffs_reject, which pops
  ios_thunk_bare/  (no push -- these run BEFORE ios_ffs_check's push and branch
  ios_thunk_slot    straight there) -> must NOT reach the popping label

The baseline got this wrong: ios_thunk_slot pushed nothing, yet
ios_thunk_reject branched into ios_ffs_reject, so every thunk correctly
rejected into emulation popped 16 bytes that were never pushed -- moving sp by
+16 and loading garbage into x4 and x9. ios_thunk_slot now owns a 32-byte frame
it unwinds itself and joins the shared, non-popping counter at
ios_ffs_reject_count.

A wrong branch here does not fault where it happens; it corrupts the caller's
stack and surfaces later as an unrelated crash, so it is worth pinning.

The paths are label RANGES, not single labels: ios_thunk_slot_orig/_bitmap/
_reject are continuations of the frame ios_thunk_slot pushes, and
ios_ec_entry_miss is a continuation of ios_ec_entry's.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
src = (root / 'FEX/Source/Windows/ARM64EC/Module.S').read_text()
failures = []

def check(cond, what):
    print(('PASS ' if cond else 'FAIL ') + what)
    if not cond:
        failures.append(what)

def strip_comments(text):
    """Drop `//` comments: the baseline explanation QUOTES `ldp x4, x9, [sp], #16`
    while describing the bug, and that must not read as an instruction."""
    return '\n'.join(re.sub(r'//.*$', '', ln) for ln in text.splitlines())

BRANCH = r'\b(?:b|cbz|cbnz|tbz|tbnz)\b[^\n]*\b%s\b'

def span(first, last):
    """Text from `first:` up to (not including) `last:`; None if either is absent."""
    a = re.search(r'^%s:\s*$' % re.escape(first), src, re.M)
    if not a:
        return None
    b = re.search(r'^%s:\s*$' % re.escape(last), src[a.end():], re.M)
    return src[a.end():a.end() + b.start()] if b else None

# The thunk path: pushes its own 32-byte frame, unwinds it, never pops x4/x9.
THUNK = span('ios_thunk_slot', 'ios_ec_entry')
# ios_ec_entry through to ios_ffs_check (includes the _miss continuation).
ECENTRY = span('ios_ec_entry', 'ios_ffs_check')
# ios_ffs_check through the popping reject tail.
FFSCHK = span('ios_ffs_check', 'ios_ffs_no_bypass')

for name, text in (('thunk path', THUNK), ('ios_ec_entry region', ECENTRY),
                   ('ios_ffs_check region', FFSCHK)):
    check(text is not None, 'Module.S still has the %s (labels moved?)' % name)

THUNK = strip_comments(THUNK or '')
ECENTRY = strip_comments(ECENTRY or '')
FFSCHK = strip_comments(FFSCHK or '')

# --- the thunk path owns and unwinds a 32-byte frame -------------------------
check('stp x17, x4, [sp, #-32]!' in THUNK,
      'ios_thunk_slot pushes a 32-byte frame (slot value + x64 R10)')
check(THUNK.count('add sp, sp, #32') == 2,
      'the thunk path unwinds 32 bytes on both exits (found %d)'
      % THUNK.count('add sp, sp, #32'))
check('ldr x4, [sp, #8]' in THUNK,
      'the thunk path restores x4 (x64 R10), which the bitmap test uses as scratch')
check('ldp x4, x9, [sp], #16' not in THUNK,
      'the thunk path never pops the frame ios_ffs_check owns (it pushed nothing there)')

# --- the thunk path joins the NON-popping tail -------------------------------
check(re.search(r'^ios_ffs_reject_count:\s*$', src, re.M) is not None,
      'ios_ffs_reject_count exists')
check(re.search(BRANCH % 'ios_ffs_reject_count', THUNK) is not None,
      'the thunk reject path joins ios_ffs_reject_count')
check(re.search(BRANCH % 'ios_ffs_reject(?!_count)', THUNK) is None,
      'the thunk path never branches to the popping ios_ffs_reject')

# --- ios_ffs_check still owns the popping tail ------------------------------
check('ldp x4, x9, [sp], #16' in FFSCHK,
      'ios_ffs_reject still pops the frame ios_ffs_check pushed')
count_lbl = span('ios_ffs_reject_count', 'ios_ffs_no_bypass') or ''
check('ldp' not in count_lbl and 'add sp, sp' not in count_lbl,
      'ios_ffs_reject_count itself does not touch sp (callers unwind first)')
check(re.search(BRANCH % 'ios_ffs_reject(?!_count)', FFSCHK) is not None,
      'ios_ffs_check is the branch source for the popping ios_ffs_reject')

# --- ios_ec_entry pushes 16 and pops 16 on both exits -----------------------
check('stp x4, x23, [sp, #-16]!' in ECENTRY,
      'ios_ec_entry pushes a 16-byte frame')
check(ECENTRY.count('ldp x4, x23, [sp], #16') == 2,
      'ios_ec_entry pops it on both exits (found %d)'
      % ECENTRY.count('ldp x4, x23, [sp], #16'))

# --- x5 carries the ARM64EC variadic size and must never be touched ----------
for label, text in (('thunk path', THUNK), ('ios_ec_entry region', ECENTRY)):
    uses = re.findall(r'\b(?:movz|movk|mov|add|sub|subs|ldr|str|cmp|and|lsr|ldrh|ldursw|ldrb)'
                      r'\s+(?:w|x)5\b', text)
    check(not uses,
          '%s does not clobber x5 (the ARM64EC variadic size) -- found %s' % (label, uses or 'none'))

print('\n%d failure(s)' % len(failures) if failures else '\nall checks passed')
sys.exit(1 if failures else 0)
