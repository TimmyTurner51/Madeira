#!/usr/bin/env python3
"""Verify virtual_alloc_teb / virtual_alloc_first_teb anti-deadlock invariants.

In fh6-ml342b, ios_swap_whole_resv() file-backed 2 MB TEB reservations onto
ios_swap_fd, and virtual_alloc_teb() called memset() and init_teb() while
holding virtual_mutex without checking NtAllocateVirtualMemory(MEM_COMMIT)'s
return status. A page-in stall or fault on init_teb+0xb4 deadlocked
wine-x18-exc on virtual_mutex.

This host test enforces three invariants in build/ntdll-unix/virtual_ios.c:
  1. ios_alloc_no_swap is thread-local and checked by ios_swap_commit,
     ios_swap_reserve, and ios_swap_whole_resv.
  2. Both virtual_alloc_first_teb() and virtual_alloc_teb() wrap TEB
     reservations/commits with ios_alloc_no_swap++ / ios_alloc_no_swap-- and
     virtual_alloc_teb() checks the MEM_COMMIT return status.
  3. virtual_alloc_teb() releases virtual_mutex before memset() and
     init_teb_fields(), re-acquiring only to link into teb_list.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
VIRT = ROOT / "build/ntdll-unix/virtual_ios.c"
src = VIRT.read_text()


def extract_fn(name: str) -> str:
    m = re.search(rf"^[A-Za-z_][^\n]*\b{re.escape(name)}\s*\([^\)]*\)\n\{{", src, re.M)
    assert m, f"function {name} not found in {VIRT}"
    start = m.start()
    depth = 0
    for i in range(m.end() - 1, len(src)):
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
    raise AssertionError(f"unterminated function {name}")


assert re.search(r"static\s+_Thread_local\s+int\s+ios_alloc_no_swap\s*;", src), (
    "ios_alloc_no_swap must be declared static _Thread_local int"
)

for fn_name in ("ios_swap_commit", "ios_swap_reserve", "ios_swap_whole_resv"):
    body = extract_fn(fn_name)
    assert "if (ios_alloc_no_swap) return" in body, f"{fn_name} must skip swap when ios_alloc_no_swap is set"

first_teb = extract_fn("virtual_alloc_first_teb")
assert first_teb.count("ios_alloc_no_swap++;") >= 2, "virtual_alloc_first_teb must guard reserve and commit with ios_alloc_no_swap"
assert first_teb.count("ios_alloc_no_swap--;") == first_teb.count("ios_alloc_no_swap++;"), (
    "unbalanced ios_alloc_no_swap in virtual_alloc_first_teb"
)

alloc_teb = extract_fn("virtual_alloc_teb")
assert "ios_alloc_no_swap++;" in alloc_teb, "virtual_alloc_teb must guard TEB allocations with ios_alloc_no_swap"
assert re.search(r"status\s*=\s*NtAllocateVirtualMemory\([^;]*MEM_COMMIT", alloc_teb, re.S), (
    "virtual_alloc_teb must check the return status of MEM_COMMIT"
)

# Ensure memset and init_teb_fields happen AFTER releasing virtual_mutex.
leave_pos = alloc_teb.find("/* Release virtual_mutex before writing into the new TEB block")
assert leave_pos != -1, "virtual_alloc_teb must release virtual_mutex before touching TEB memory"
after_release = alloc_teb[leave_pos:]
m_leave = after_release.find("server_leave_uninterrupted_section( &virtual_mutex, &sigset );")
m_memset = after_release.find("memset( ptr, 0, teb_size );")
m_init = after_release.find("init_teb_fields( ptr, is_wow );")
m_reenter = after_release.find("server_enter_uninterrupted_section( &virtual_mutex, &sigset );")
assert 0 <= m_leave < m_memset < m_init < m_reenter, (
    "virtual_alloc_teb must execute memset and init_teb_fields strictly outside virtual_mutex"
)

# Ensure init_teb_fields does not touch global teb_list.
fields_fn = extract_fn("init_teb_fields")
assert "teb_list" not in fields_fn, "init_teb_fields must not touch global teb_list outside virtual_mutex"

print("PASS: virtual_alloc_teb no-swap, checked MEM_COMMIT, and unlocked init invariants verified")
