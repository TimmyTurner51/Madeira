#!/usr/bin/env python3
"""The ml1250 ud-decrypt probe (wine/dlls/ntdll/signal_arm64ec.c); no Wine runs.

A protected title's per-function encrypted prologues raise #UD, and its own
handler decrypts the function and returns ExceptionContinueExecution. When the
handler instead returns ExceptionContinueSearch, two very different causes look
identical in a log: the protection never decrypted (a licence or tamper
verdict), or it decrypted and something else failed. The bytes at the faulting
address are the only evidence that separates them.

This check pins the properties that make the probe trustworthy:
  - the snapshot is taken inside call_seh_handlers, before the handler walk,
    so no handler can have written the bytes yet;
  - it is armed only for STATUS_ILLEGAL_INSTRUCTION with a non-NULL address;
  - it reads through NtReadVirtualMemory, which returns a status instead of
    faulting, because it runs inside exception dispatch;
  - it allocates nothing (no malloc/HeapAlloc/strdup) and takes no lock;
  - the report fires on BOTH decline paths (EC handler and TEB handler);
  - the report is rate limited, so a #UD storm cannot flood the log.
Needs python3 only.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
src = (root / 'wine/dlls/ntdll/signal_arm64ec.c').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def body_of(name, text):
    """Text of a top-level function, from its definition to the first '\\n}'."""
    at = text.index(name)
    end = text.index('\n}\n', at)
    return text[at:end]


# ---------------------------------------------------------------- the helpers

snapshot = body_of('static void ml1250_ud_snapshot(', src)
report = body_of('static void ml1250_ud_report(', src)

check('STATUS_ILLEGAL_INSTRUCTION' in snapshot,
      'snapshot must arm only for STATUS_ILLEGAL_INSTRUCTION')
check('rec->ExceptionAddress' in snapshot, 'snapshot must need a non-NULL faulting address')
check('NtReadVirtualMemory' in snapshot, 'snapshot must read through NtReadVirtualMemory (fault-safe)')
check('sizeof(ml1250_ud_before)' in snapshot, 'snapshot must bound its own read')
check('ml1250_ud_armed = 1' in snapshot, 'snapshot must arm the probe only after a successful read')

check('NtReadVirtualMemory' in report, 'report must re-read through NtReadVirtualMemory')
check('InterlockedIncrement' in report, 'report must be rate limited')
check('unchanged' in report.lower(), 'report must name the undecrypted case explicitly')
check('DECRYPTED' in report, 'report must name the decrypted case explicitly')

for fn, name in ((snapshot, 'snapshot'), (report, 'report')):
    for banned in ('malloc', 'HeapAlloc', 'calloc', 'strdup', 'RtlAllocateHeap', 'EnterCriticalSection'):
        check(banned not in fn, '%s must not call %s (runs inside exception dispatch)' % (name, banned))

# ---------------------------------------------------------------- placement

seh = body_of('NTSTATUS call_seh_handlers(', src)

arm_at = seh.index('ml1250_ud_snapshot( rec );')
check(arm_at < seh.index('call_seh_handler( rec'), 'snapshot must run before the first handler is called')

declines = [m.start() for m in re.finditer(r'ml1250_ud_report\(', seh)]
check(len(declines) == 2, 'both decline paths must report (EC handler and TEB handler), found %d' % len(declines))

for m in re.finditer(r'case ExceptionContinueSearch:\s*\n\s*(ml1250_ud_report\([^)]*\);)', seh):
    pass
ec_ok = re.search(r'case ExceptionContinueSearch:\s*\n\s*ml1250_ud_report\( "EC handler declined" \);', seh)
teb_ok = re.search(r'case ExceptionContinueSearch:\s*\n\s*ml1250_ud_report\( "TEB handler declined" \);', seh)
check(ec_ok is not None, 'the EC ContinueSearch branch must call the report')
check(teb_ok is not None, 'the TEB ContinueSearch branch must call the report')

# the report belongs to a DECLINE, never to the continue-execution path
cont = seh.index('case ExceptionContinueExecution:')
first_report = seh.index('ml1250_ud_report(')
check(first_report > cont, 'the report must not be wired into ExceptionContinueExecution')

if failures:
    for f in failures:
        print('FAIL: ' + f)
    sys.exit(1)
print('PASS: ml1250 arms on STATUS_ILLEGAL_INSTRUCTION before the handler walk, reads fault-safely '
      'and allocation-free, and reports on both decline paths only')
