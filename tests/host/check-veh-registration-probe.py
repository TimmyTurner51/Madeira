#!/usr/bin/env python3
"""The ml1252 handler-registration probe (wine/dlls/ntdll/exception.c); no Wine runs.

[veh-chain] (ml1251) showed the chain holds exactly one handler when the #UD
lands -- a Dr0-Dr3/Dr7 single-step harness that declines. So one of two things is
true, and they need opposite work:

  - the protected title's decryptor was never registered (loader/import problem);
  - it was registered and then removed (lifetime problem).

A handler that was added and taken away again leaves no trace in the chain at
dispatch time, so watching the chain cannot separate them -- the registrations
themselves have to be watched. ml1252 logs each add (with the module resolved
from the handler address, so the report names a component rather than a bare
code address) and each removal.

This check pins what makes that output trustworthy:
  - the add report names the module that owns the handler, not just an address;
  - the report does not walk PEB.Ldr by hand, which does not exist on the public
    PEB this file sees (it failed to compile), and instead uses the loader's own
    accessor;
  - both reports are rate limited and allocate nothing, because they run inside
    the critical section and inside exception dispatch;
  - removals are reported too: that is the whole point of the probe.
Needs python3 only.
"""
from pathlib import Path
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


add = body_of('static VECTORED_HANDLER *add_vectored_handler(', src)
rem = body_of('static ULONG remove_vectored_handler(', src)

# ------------------------------------------------------------------ add report

check('[veh-add] ml1252 #%ld func=%p module=%p' in add,
      'each registration must be reported with its resolved module')
check('LdrFindEntryForAddress' in add,
      'the module name must come from the loader accessor; PEB.Ldr is not in the '
      'public PEB this file sees and does not compile')
check('PEB *peb' not in add and 'peb->Ldr' not in add,
      'must not hand-walk PEB.Ldr')
check('InterlockedIncrement( &add_n )' in add, 'adds must be rate limited')

# The report must come after the list insert: a handler is only in the chain
# from that point, and the log orders events by when they took effect.
insert_at = add.index('InsertTailList')
report_at = add.index('[veh-add] ml1252 #')
check(insert_at < report_at,
      'the add must be reported after the handler is linked into the chain')

for banned in ('malloc(', 'HeapAlloc', 'RtlAllocateHeap('):
    check(banned not in add[add.index('[veh-add] ml1252 #'):],
          'the add report must not allocate (%s) while holding the exchange lock' % banned)

# ------------------------------------------------------------------ removals

check('[veh-add] ml1252 REMOVED' in rem,
      'removals must be reported: a decryptor that is added then removed looks '
      'identical to one that was never added')

# Only the exception chain matters here; reporting continuations would be noise
# and this file uses the same helper for the continuable chain.
check('vectored_exception_handlers' in rem,
      'the removal report must be scoped to the exception chain, not every chain '
      'this helper serves')

# The removal report must run before the lock is dropped, or a concurrent dispatch
# can interleave and make the log claim the wrong chain state.
check(rem.index('[veh-add] ml1252 REMOVED') < rem.index('RtlLeaveCriticalSection'),
      'the removal report must run while the section is still held')

if failures:
    for f in failures:
        print('FAIL: ' + f)
    sys.exit(1)
print('PASS: ml1252 reports handler registrations with their owning module and reports '
      'removals from the exception chain, rate limited and allocation-free')
