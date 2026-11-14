# Madeira's FEX patches

Changes to FEX that Madeira needs and that live in this repository, not in
the FEX submodule's repository. `apply.sh` applies them, in file-name order,
to the FEX working tree before `build/fex-arm64ec/build.sh` and
`build/fex-wow64/build.sh` build `xtajit64.dll` and `xtajit.dll`; it skips a
patch that is already applied, and `apply.sh --revert` takes them out. The
FEX submodule pin does not change.

These patches are for Madeira only and are not to be sent to FEX-Emu.

| Patch | What it fixes |
|---|---|
| `0001-windows-ios-smc-traps-per-16k-host-page.patch` | Self-modifying-code write traps per 16 KB iOS host page, both modules (The Escapists 2, Project Zomboid) |
| `0002-single-block-invalidation.patch` | Single-block invalidation under `SMCChecks=full`, ported from the DroidDeck FH6 build: `InvalidateCodeBuffersBlock` / `InvalidateThreadCachedBlock` / `InvalidateGuestBlock`, and `InvalidateUntrackedRange` for a block whose page bookkeeping is missing |
| `0003-exittox64-resolve-import-thunks.patch` | `ExitToX64` resolves an x64 import thunk — bare `ff 25 rel32` or hotpatched (prologue + `ff 25`, see `build/wine-patches/0001`) — through its IAT slot before its FFS tests. Without it a call that arrives here with `x9` = an import thunk takes `ios_ffs_no_bypass` and enters the JIT with `x9` still the thunk. EC targets now branch natively; genuine x64 ones fall through to emulation with `x9` restored, which is the correct x64 behaviour (the first case seen was `TlsAlloc` from ucrtbase's exit thunk) |
| `0004-exittox64-branch-native-for-ec-targets.patch` | `ios_ec_entry`: when `x9` matches no thunk shape it is a raw ARM64EC target, so canonicalise it into pool space and branch to it natively if `EcCodeBitMap` says EC, instead of entering the JIT with an all-zero CPU area (no `CpuStateFrame` yet during the DllMain walk) and branching to NULL |
| `0005-exittox64-follow-slot-fastforward.patch` | `ios_thunk_slot` follows a hotpatched thunk's IAT slot through a hybrid export's 14-byte x64 fast-forward stub (`48 8b c4 … 55 5d e9 rel32`, the shape `build/tools/ec-ffs-pad.py` preserves) and canonicalises both the slot value and each stub target from PE VAs into pool space before the `EcCodeBitMap` test — up to four hops, because kernel32 → kernelbase forwarders can chain. `arm64ec_iat_is_exported_x64` deliberately keeps those stubs x64-visible in `.hexpthk`, so without this the slot value is x64 byte space, fails the bitmap test, and reaches emulation (the 2026-11-14 `c0000005` at `pc=0`, `lr=ucrtbase+0x90f1c`). The original slot value is restored on every miss, so a miss behaves exactly as before. It also gives `ios_thunk_slot` a real 32-byte frame: the baseline pushed nothing while `ios_thunk_reject` branched into `ios_ffs_reject`, whose `ldp x4, x9, [sp], #16` pairs with `ios_ffs_check`'s push — so every correctly-rejected thunk popped 16 bytes that were never pushed. `x4` (x64 `R10`), which the bitmap test uses as scratch, is now saved and restored so `R10` reaches the callee intact; `x5` is deliberately untouched because `x4`/`x5` carry the ARM64EC variadic descriptor |
| `0006-report-unresolved-import-slots.patch` | Diagnostics: `IosFfsBypassLog` grows to 12 slots. `[6]`/`[7]` count import slots the fast-forward walk could not resolve and record the last such value; `[8]`/`[9]` count FFS prologues actually followed and record the last native target reached (`[ffs-follow]`); `[10]` keeps the unresolved slot value across `[7]` overwrites. A run with `followed=0` plus an `[ffs-slot]` value means the slot never held an FFS at all, which distinguishes a broken unwrap from a wrong diagnosis |

A patch must apply on the current FEX pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
