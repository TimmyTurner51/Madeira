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
| `0003-arm64ec-sync-hybrid-metadata-slots.patch` | Mirrors `arm64ec_update_hybrid_metadata`'s stores into the JIT-pool copy of the image. The store lands in the PE view, but the guest executes the pool copy and the `NtProtectVirtualMemory` that precedes the store already copied PE -> pool, so the slot keeps its pre-sync zero. `ucrtbase`'s `__os_arm64x_dispatch_call_no_redirect` (rva `e3898`) was the first victim: `adrp x8,page; ldr x16,[x8,#0x898]; blr x16` with `x16 == 0`, `pc = 0`, `lr = ucrtbase+0x90f1c`. Reuses the loader's verified `unix_ios_sync_pe_write` call (widened from 4 to 4-or-8 bytes) and reports NULL dispatcher globals. Each write to that slot is also reported unconditionally (`(watched)`), because sampling hid the second pass: the first writes 0 (before `ExitToX64` resolves) and only the re-patch writes the real value, so the two are otherwise indistinguishable |
| `0004-arm64ec-sync-bound-import-slots.patch` | Does for every bound import slot what 0003 does for the dispatcher slots, and does it in one pass before `process_attach` runs any DllMain. `ExitToX64` reads the slot the guest executes, i.e. the POOL copy, but `import_dll` binds by storing through a PE VA; the pool slot therefore still held `0xcc` trap filler, so `ucrtbase`'s exit to `kernelbase!GetCommandLineA` had no target and fell through to `enter_jit`, which branched to NULL (`DispatcherLoopTopEnterEC` is Phase 2, after this walk). Slots still holding an rva are resolved from the provider's export directory with `RtlFindExportedRoutineByName`, which cannot attach a module and so cannot nest the walk it protects. Reported per module: slots, already bound, unbound, synced |
| `0005-arm64ec-ud-decrypt-probe.patch` | Adds `[ud-decrypt]`, which measures whether the protection decrypts before it declines the `#UD`. FH6 dies 4.5 s after launch, before the 7 s integrity batch the DroidDeck handoff documents, so an earlier gate declines; and two causes log identically — the protection never decrypted (a licence or tamper verdict), or it decrypted and something else then failed. The bytes at `ExceptionAddress` are the only evidence that separates them, so they are snapshotted when the `#UD` is dispatched and re-read when a handler returns `ContinueSearch`: `BYTES UNCHANGED` means nothing was decrypted, `DECRYPTED` means plaintext was written and the decline came from elsewhere. An import slot shape fix (0001..0004) cannot answer this, which is why it is measured rather than inferred. The probe reads through `NtReadVirtualMemory` and allocates nothing, takes no lock and is rate limited, because it runs inside exception dispatch and recursed to death once before |
The patches change build output only: 0001 has `winebuild` rewrite the thunk
bytes as it installs each builtin, and 0002 is compiled into the ARM64EC ntdll.
Rebuild the PE modules after changing either.

**Deploying ntdll is not enough on its own.** On device, the `ntdll.dll` that
runs is the one in the LiveContainer app bundle
(`Documents/Applications/com.willfaust.madeora.app/arm64ec-windows/ntdll.dll`),
not the `${system32}/ntdll.dll` link the Wine component creates: the bundle copy
shadows the prefix link. Through the whole 2026-11-15 session every `ntdll` and
`xtajit64` push went to the prefix and had no effect, so builds 24..34 all
crashed identically -- the patched code never executed. Both
`tools/wcp/push-wine-to-device.sh` and `push-fex-to-device.sh` now write the
bundle copy as well; confirm a run picked the new DLL by the
`[ntdll ml1xxx iat-sync vN]` suffix on `loader_init: calling
load_arm64ec_module`, which a stale bundle cannot print.

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
