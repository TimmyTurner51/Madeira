# Madeira's Wine patches

Changes to Wine that Madeira needs and that live in this repository, not in the
Wine submodule's repository. `apply.sh` applies them, in file-name order, to the
Wine working tree before `tools/build/build-wine.sh` configures and builds it;
it skips a patch that is already applied, and `apply.sh --revert` takes them
out. The Wine submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-arm64ec-import-thunk-hotpatch-prologues.patch` | Gives x64 import thunks in ARM64EC builtins the same hotpatch prologue as native Windows (`48 8d a4 24 00 00 00 00 ff 25`), which anti-tamper checks inspect (Forza Horizon 6). Covers both ARM64X builtins (via the CHPE map and the ARM64X export directory) and pure `x86_64` builtins in the ARM64EC farm, which have neither |
| `0002-arm64ec-check-call-hotpatch-thunks.patch` | Teaches `__os_arm64x_check_call` to follow a hotpatched import thunk (prologue + `ff 25`) the same way it already followed a bare `ff 25`. Without it every such call is classified "not a special sequence", routed to the x64 exit thunk, and enters the JIT with no `CpuStateFrame` (`x28 == 0`), faulting at `pc 0`. The first to hit it was `TlsAlloc`, called from ucrtbase's exit thunk during process init |

| `0003-arm64ec-sync-hybrid-metadata-slots.patch` | Mirrors `arm64ec_update_hybrid_metadata`'s stores into the JIT-pool copy of the image. The store lands in the PE view, but the guest executes the pool copy and the `NtProtectVirtualMemory` that precedes the store already copied PE -> pool, so the slot keeps its pre-sync zero. `ucrtbase`'s `__os_arm64x_dispatch_call_no_redirect` (rva `e3898`) was the first victim: `adrp x8,page; ldr x16,[x8,#0x898]; blr x16` with `x16 == 0`, `pc = 0`, `lr = ucrtbase+0x90f1c`. Reuses the loader's verified `unix_ios_sync_pe_write` call (widened from 4 to 4-or-8 bytes) and reports NULL dispatcher globals |

The patches change build output only: 0001 has `winebuild` rewrite the thunk
bytes as it installs each builtin, and 0002 is compiled into the ARM64EC ntdll.
Rebuild the PE modules after changing either.

A Forza Horizon 6 run against a farm that still had bare `jmp *__imp_x` thunks
died deterministically with `0xC000001D` at `forzahorizon6.exe+0x537099C`: the
anti-tamper read its own imports as hooked, set its tampered flag, and then
declined the `#UD` its own encrypted function prologues raise, so the VEH
returned `CONTINUE_SEARCH` without decrypting. After rebuilding with 0001 that
exception disappears from the log entirely.

0001 on its own regressed the process to an earlier death: with the prologue in
place, `__os_arm64x_check_call` no longer matched the bare `ff 25`, so every
import call took the exit-thunk path and the process faulted at `pc 0` while
still loading its first six modules. 0002 restores that classification. The two
patches belong together.
