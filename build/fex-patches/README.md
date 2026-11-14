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

A patch must apply on the current FEX pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
