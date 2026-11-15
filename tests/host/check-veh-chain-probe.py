#!/usr/bin/env python3
"""The ml1251 veh-chain probe (wine/dlls/ntdll/exception.c); no Wine runs.

A protected title's per-function encrypted prologues raise #UD; its own handler
decrypts the function and returns EXCEPTION_CONTINUE_EXECUTION. That handler is
normally VECTORED, because only a vectored handler runs before the frame-based
walk and can resume at the faulting address.

The per-handler lines in call_vectored_handlers are TRACE, and Madeira captures
no trace channels, so an EMPTY chain and a chain whose handlers all decline look
identical in a log -- yet they call for opposite work (a registration problem in
Wine, versus a verdict from the protection). The probe separates them.

This check pins the properties that make its output trustworthy:
  - it reports the chain once per process, before the walk, and names the empty
    case explicitly instead of printing "0 handlers" and letting the reader guess;
  - the list walk is bounded, so a cyclic/corrupt chain cannot hang dispatch;
  - it does not take vectored_handlers_section again: the caller already holds
    it, and a recursive acquisition inside exception dispatch is a lockup;
  - it allocates nothing and only formats into the log;
  - each handler's verdict is reported with CONTINUE_EXECUTION called out as the
    "decrypted, resuming" outcome.
Needs python3 only.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
src = (root / 'wine/dlls/ntdll/exception.c').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def body_of(name, text):
    at = text.index(name)
    return text[at:text.index('\n}\n', at)]


veh = body_of('static LONG call_vectored_handlers(', src)

# ---------------------------------------------------------------- chain report

check('STATUS_ILLEGAL_INSTRUCTION' in veh,
      'the report must be armed for STATUS_ILLEGAL_INSTRUCTION')
check('EMPTY' in veh,
      'the empty chain must be named explicitly, not left as "0 handler(s)"')
check('InterlockedIncrement( &ih_n )' in veh,
      'the chain report must be rate limited')
check('> 32' in veh or '>= 32' in veh,
      'the list walk must be bounded so a corrupt chain cannot hang dispatch')

# The dump must happen while the lock is held, and must NOT take it again.
first_lock = veh.index('RtlEnterCriticalSection( &vectored_handlers_section )')
first_unlock = veh.index('RtlLeaveCriticalSection( &vectored_handlers_section )')
report_at = veh.index('[veh-chain] ml1251 #')
check(first_lock < report_at < first_unlock,
      'the chain report must run inside the critical section the caller already holds')

# Walk the raw list, not a locking accessor: re-entering the section here deadlocks.
LOCK = 'RtlEnterCriticalSection( &vectored_handlers_section )'
between = veh[first_lock + len(LOCK):report_at]
check('RtlEnterCriticalSection' not in between,
      'the report must not re-enter vectored_handlers_section (already held -> deadlock)')

for banned in ('malloc', 'HeapAlloc', 'RtlAllocateHeap', 'calloc', 'strdup'):
    check(banned not in veh, 'must not call %s (runs inside exception dispatch)' % banned)

# ---------------------------------------------------------------- verdicts

check('ml1251 handler %p -> %ld' in veh, 'each vectored handler verdict must be reported')
check('CONTINUE_EXECUTION' in veh and 'decrypted, resuming' in veh,
      'CONTINUE_EXECUTION must be named as the decrypted outcome')
check('CONTINUE_SEARCH' in veh and 'declined' in veh,
      'CONTINUE_SEARCH must be named as a decision, not a failure')

verdict_at = veh.index('ml1251 handler %p -> %ld')
call_at = veh.index('ret = func( &except_ptrs );')
check(call_at < verdict_at, 'the verdict must be reported after the handler runs')

# The vector chain must still run before the frame walk in dispatch_exception.
disp = body_of('NTSTATUS WINAPI dispatch_exception(', src)
check(disp.index('call_vectored_handlers(') < disp.index('call_seh_handlers('),
      'dispatch_exception must offer the fault to the vectored chain first')

if failures:
    for f in failures:
        print('FAIL: ' + f)
    sys.exit(1)
print('PASS: ml1251 reports the vectored chain (including the empty case) inside the held lock, '
      'bounded and allocation-free, and reports every handler verdict')
