#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""ml320c-subfloor: two-layer inline KUSER_SHARED_DATA / subfloor translation.

Verifies the cross-boundary invariants between ntdll-unix (signal_arm64_ios.c,
virtual_ios.c) and FEX (OpcodeDispatcher.h, IosJitAlias.cpp, Core.cpp,
WOW64/Module.cpp):
- Layer 1 (compile-time direct rewrite): absolute loads in 0x7ffe0000..0x7ffe0fff
  rewrite directly via IosSubfloorToReal() when mapped, with zero runtime overhead.
- Layer 2 (hot-page promotion): guest code pages hitting a subfloor window >= 8 times
  via register-indirect addressing are pushed with bit 62 (kIosHotSubfloorPageMark,
  distinct from ml2240 bit 63 kIosSubfloorHighMark), queued lock-free in FEX,
  invalidated once in CompileBlock, and recompiled with inline window translation.
- WOW64 build keeps matching stub symbols so x86 builds continue linking.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sig = (ROOT / "build/ntdll-unix/signal_arm64_ios.c").read_text(encoding="utf-8", errors="replace")
virt = (ROOT / "build/ntdll-unix/virtual_ios.c").read_text(encoding="utf-8", errors="replace")

failures = 0


def check(cond, text):
    global failures
    print(("PASS: " if cond else "FAIL: ") + text)
    if not cond:
        failures += 1


def body(src, name, stop="\n}\n"):
    i = src.index(name)
    return src[i : src.index(stop, i)]


# ntdll-unix: signal handler promotes hot guest pages at hit #8
check(
    "uintptr_t real = ios_subfloor_translate_win( addr, peb, &win_lo, &win_sz );" in sig,
    "ios_subfloor_service resolves the matching window bounds (win_lo, win_sz)",
)
check(
    "if (hist[h].n == 8 && win_sz)" in sig
    and "ios_push_hot_subfloor_page( page << 12, win_lo, win_sz, peb );" in sig,
    "signal handler promotes a guest RIP page to FEX at hit #8 with window bounds",
)

# ntdll-unix: virtual_ios.c encodes hot-page mark with bit 62 (not bit 63)
push_hot = body(virt, "void ios_push_hot_subfloor_page(")
check(
    "(guest_page & ~0xFFFULL) | (1ull << 62)" in push_hot,
    "ios_push_hot_subfloor_page marks guest pages with bit 62 (distinct from bit 63)",
)

# FEX checks (when FEX submodule is present)
fex_alias = ROOT / "FEX/Source/Windows/ARM64EC/IosJitAlias.cpp"
fex_op = ROOT / "FEX/FEXCore/Source/Interface/Core/OpcodeDispatcher.h"
fex_core = ROOT / "FEX/FEXCore/Source/Interface/Core/Core.cpp"
fex_wow = ROOT / "FEX/Source/Windows/WOW64/Module.cpp"

if fex_alias.exists():
    alias = fex_alias.read_text(encoding="utf-8", errors="replace")
    op = fex_op.read_text(encoding="utf-8", errors="replace")
    core = fex_core.read_text(encoding="utf-8", errors="replace")
    wow = fex_wow.read_text(encoding="utf-8", errors="replace")

    check(
        "kIosSubfloorHighMark = 1ull << 63;" in alias
        and "kIosHotSubfloorPageMark = 1ull << 62;" in alias,
        "FEX uses distinct marks for high subfloor windows (bit 63) and hot pages (bit 62)",
    )
    check(
        "if (PeBase & kIosHotSubfloorPageMark) {" in alias
        and "IosHotSubfloorPageAdd(PeBase & ~kIosHotSubfloorPageMark, JitBase, Size);" in alias,
        "BTCpu64IosAddAliasMapping routes bit-62 marks to IosHotSubfloorPageAdd",
    )
    check(
        "IosSubfloorToReal(GuestAddr)" in op
        and "A.Offset >= 0x7ffe0000LL && A.Offset < 0x7ffe1000LL" in op
        and "if (RealAddr != GuestAddr)" in op,
        "OpcodeDispatcher rewrites direct absolute KUSER_SHARED_DATA loads at compile time",
    )
    check(
        "while (uint64_t HotPage = IosPopHotSubfloorPageToInvalidate())" in core,
        "Core.cpp drains and invalidates promoted hot subfloor pages for one-time recompile",
    )
    check(
        "IosPopHotSubfloorPageToInvalidate()" in wow
        and "IosSubfloorWindowForCode(" in wow,
        "WOW64 Module.cpp provides stub definitions for hot-subfloor hooks",
    )
else:
    print("SKIP: FEX sources not checked out")

print(f'check-subfloor-kuser: {"OK" if not failures else f"{failures} FAILED"}')
sys.exit(1 if failures else 0)
