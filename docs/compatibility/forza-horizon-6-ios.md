# Forza Horizon 6 on iOS — boot record

Status: **does not boot.** Steam now launches the game and the game's own code
runs; it then dies on the same protected-code fault as before, at the same
offset, with the same bytes. Everything below is measured on device unless it
says otherwise.

How to read this: each entry is a claim with its evidence and a verdict.
**Negative results are kept deliberately** — several of them cost a full
session each, and the whole point of this file is that no future session
re-runs them.

Device: iPhone 17 Pro (`iPhone18,1`), iOS 27.0.1 (24A446), Madeira 0.2.6 (15),
running under LiveContainer.

---

## 1. Where the boot stands

| Stage | State | Evidence |
|---|---|---|
| JIT acquired under LiveContainer | **works** | §2 |
| Steam signs in online | works | `session-authenticated-online=1` |
| Steam accepts the launch request | **works** | `launch-client-error=0`, `launch-game-running=1` |
| `forzahorizon6.exe` loads | works | `[jit-pool] image 0x160b50000+0xb3c0000 (forzahorizon6.exe)` |
| Game code runs | works, ~6 s | spawn `t+7.633s`, crash at `[xp] +13.86` |
| Protected code decrypts | **never** | §4 |
| In-game window | never | — |

The last `[xp]` sample before the fault:

```
[xp] 15:27:14.329 +13.86 dt=320 cpu=326 (thr 326) P=313 E=13 run=343
     pgw=0.0 GHz P=1.96 E=2.01 Minst=3172 IPC=4.94 mJ=311 pin=92 rdKB=60 fpMB=1851
```

---

## 2. SOLVED — JIT under LiveContainer

**Claim.** LiveContainer does hand the guest JIT, but only inside a window that
closes before Play is tapped.

**Evidence.** At launch the guest really is traced, and the flag really is set:

```
[14:25:30.256] [device] signing: cs-flags=0x32003005 get-task-allow=1 cs-debugged=1 debugger-attached=1
```

Seven minutes later, with the flag still set and the debugger gone:

```
[14:32:24.398] [jit-on-play] JIT is not on: enabling it, then starting the game
[14:32:24.476] [jit-on-play] JIT did not come on: the game was not started
```

The pool request is a `BRK #0xf00d` that only a debugger can answer
(`jit26_prepare_region`, `app/Madeira/JITAllocator.c`). LiveContainer's StikDebug
session attaches, sets `CS_DEBUGGED` on the whole tree, and detaches — so the
request had nobody to serve it.

**Fix** (`6037b04`). Claim the pool at start-up while the debugger is still
attached, and have the launch path reuse it:

```
[15:00:33] [jit-early] debugger is attached at start-up: claiming the JIT pool now
[15:00:35] [jit-early] pool claimed at start-up: RX=0x148000000 RW=0x7000000000 608MB
[15:08:33] [jit-early] using the pool claimed at start-up: 576MB (this launch would have asked for 896MB)
```

Gated on `LC_HOME_PATH` so a normal install still enables JIT from Play and
keeps per-game pool sizing; `env.MADEIRA_JIT_EARLY_POOL=1` forces it elsewhere.

**Consequence for other work:** inside LiveContainer, "Enable JIT" can never
succeed — the built-in helper refuses to run in a guest and StikDebug belongs to
the host. The app now says to relaunch the guest instead of opening a setup
sheet whose methods are both unavailable there.

---

## 3. SOLVED — Steam refused the launch (`launch-client-error=46`)

**Claim.** Shipping `FEX_SMCCHECKS=full` made **Steam itself** refuse to start
the game. It is not an anti-tamper verdict and not a network problem.

**Why it is not obviously the package's fault:** the emulator is process-wide.
A package that targets `${system32}/xtajit64.dll` replaces the emulator for
every process, Steam included — so the check ran inside `steam.exe` too.

**Evidence — five launches, FH6 online, one variable each:**

| DLL | environment | `launch-client-error` | `launch-game-running` |
|---|---|---|---|
| patched | full reference set | 46 | — |
| **stock** | full reference set | 46 | — |
| patched | `FEX_*` keys only | 46 | — |
| patched | `FEX_SMCCHECKS` alone | 46 | — |
| patched | everything **except** that key | **0** | **1** |

The stock-DLL row is what isolates the environment from the module: the same
failure with an unpatched emulator means the code change is not the cause. The
single-key row then names the key.

**Why the key hurts.** The reference (DroidDeck) sets `full` because *its* FEX
carries patches 0002/0004 — block-level CRC validation, so `full` is cheap
there. This port has only the checks that came before those, so `full` means a
per-instruction check on every writable page in every process.

**Fix** (`ddb6409`). `FEX_SMCCHECKS` is no longer emitted by
`tools/wcp/make-fh6-wcp.sh`; re-add it once 0002/0004 land.

**Correction to an earlier belief:** the objective's preset sweep concluded
"the `FEX_*` environment preset changes nothing — emptying all twelve entries
changed nothing". That was measured while Steam was refusing the launch, so the
only thing the sweep could observe was a launch that never happened. The preset
*does* change behaviour; the fault bytes stayed identical because the fault is a
different problem (§4).

---

## 4. OPEN — the protected code never decrypts

**Claim.** The game jumps into its own protected code while that code is still
ciphertext, so the first byte executes as an invalid instruction.

**What the protection actually is** (measured off-device against
`Reference/forzahorizon6.exe`, which is the build on the device — see §4f). The
ciphertext is not a whole encrypted region. It is **per-function entry stubs**:

- Parsing the PE `.pdata` exception directory gives 414,805 x64 functions.
- **4,538 of them (1.09%) begin with byte `0xEA`**, which is the far-jump opcode
  and is *invalid in 64-bit mode*. That is the ciphertext signature.
- Of those 4,538, **only ~19 have readable code immediately after the stub**.
  The other 99.6% are encrypted throughout their bodies.
- The stub is **5 bytes** — exactly the length of a `jmp rel32`, i.e. the size of
  a call-redirection stub that gets decrypted in place at run time.
- 4,538 stubs share only **247 distinct 5-byte values** (`eac704bed2` ×2693,
  `ea49dd8ad5` ×1362, …), so the stub ciphertext is drawn from a small set
  rather than being 4,538 independent blobs.

The faulting function is one of the ~19 stub-only ones, which is why its body
disassembles into a normal MSVC prologue and made this look like ordinary code.

**Fault site** — identical to the one the objective describes:

```
[jit-pool] image 0x160b50000+0xb3c0000 (forzahorizon6.exe)
[fault_rip] rip=0x165ec099c
```

`0x165ec099c - 0x160b50000 = 0x537099c` — the objective's `image+0x537099c`,
unchanged.

**Mechanism, now positively identified** (previously inferred from bytes alone):

```
[rsp-trunc]   x86 @rip: ea e9 6b e6 14 48 89 7c 24 10 55 48 8b ec 48 83
[guest-code] rev=ml333 pool_rip=0x12ab0099c (PE 0x165ec099c): ea e9 6b e6 ...
E E8 Invalid instruction in entry block: 165EC099C
[exc-disp] raise tid=00e8 code=c000001d ...
```

FEX's frontend decodes the guest bytes as x86 and refuses the block
(`FEXCore/Source/Interface/Core/Frontend.cpp:1640`). The first byte `EA` is a far
jump, which is invalid in 64-bit mode — it is not code, it is ciphertext.

The host-side fault is `EXC_BAD_INSTRUCTION` on ARM64 `HLT #0`:

```
[fault-host] 13ed444e8: d4400000 d53b420a b9040b8a a9020388 ...
[mach_exc] UNHANDLED #2 pc=0x13ed444e8 addr=0xd4400000 type=2
```

`0xD4400000` decodes as `HLT #0` — the emulator's deliberate stub, which the Mach
handler maps to `EXCEPTION_ILLEGAL_INSTRUCTION`
(`signal_arm64_ios.c:9947`). So the `c000001d` is FEX refusing ciphertext, not
the hardware rejecting real code.

### 4a. CORRECTION — there is no wild store to `0xd4400000`

Do **not** chase this. Earlier this session `[store-noalias]` reported:

```
[store-noalias] #1 rev=ml348 addr=0xd4400000 insn=0xd4400000 pc=0x13ed444e8
   NO pool/anon alias | region 0x1026d0000+0xc000 prot=5 max=5
   (prot without W = exec-downgraded page that never got dual-mapped)
```

That reads like a store to an unmapped guest address on a page that lost write
permission — a memory bug. It is neither:

- `addr` equals `insn` exactly, and both equal the `HLT #0` word. For an
  instruction-class fault, FAR holds no meaningful address.
- The probe sits in the *write-fault* emulation path and calls `mach_vm_region`,
  which answers with the region **at or after** the address. `0xd4400000` is
  unmapped, so it returned the next region — `0x1026d0000`, some 400 MB away and
  unrelated to the fault. The verdict was then derived from that innocent region.

Two fixes are needed in `build/ntdll-unix/signal_arm64_ios.c` (probe only, no
behaviour change): require the returned region to actually cover the address
before calling it "the faulting page", and name the case where `addr` equals the
instruction word.

### 4b. FALSIFIED — the arena hunt is not the cause

The objective recorded "28,416 consecutive hinted VirtualAllocs
(KERN_NO_SPACE / `STAGE=fixed-map err=3`) spanning ~1 GB" as *the single most
Windows-unlike input* and the leading suspect.

This run gets the same fault after **two** refusals:

```
[exec-alloc] NtAllocateVirtualMemory #4 req_addr=0x16cf13000 size=0x1001000 type=0x3000 protect=0x40
[alloc-fail] ml814 #2 status=c0000018 ... STAGE=fixed-map err=3 at 0x16cf10000+0x1004000
[exec-alloc] NtAllocateVirtualMemory #5 req_addr=0x16df14000 ...
[alloc-fail] ml814 #3 status=c0000018 ...
[exec-alloc] NtAllocateVirtualMemory #6 req_addr=0x16ef15000 ...
[guest-rwx] #1 0x16ef10000+0x1008000 prot=rwx — anonymous guest memory, EXEC is FEX bookkeeping; applying rw- instead
```

The arena the protector asked for is granted. The rejection count fell by four
orders of magnitude and the fault did not move a byte. **The hunt is not
causal.** (The `type=0x3000 protect=0x40` request is the 16 MB+64 KB RWX arena
the objective describes — unchanged.)

### 4c. FALSIFIED — the `[pool-rip-fix]` redirects are not the cause

24 redirects appear immediately before the fault:

```
[pool-rip-fix] #24 guest RIP 0x130bd8050 is a module POOL-COPY alias of PE 0x71f3868050
   -- redirecting to PE VA and re-entering the dispatcher
```

This is the already-solved ml314 class (`FEXCore/Source/Interface/Core/Core.cpp:1569`):
a guest RIP inside a module's JIT-pool copy is reverse-translated to its PE VA.
The fix is working, its logging is capped at 24 (`N < 24`), and the count is
therefore an artefact of the cap rather than a runaway. The steady
`[iOS-xrem]` interleave is the same mechanism.

### 4d. MEASURED NEGATIVE — the host exception address is reconstructed correctly

The guest-visible record starts out carrying the **host** pc, which looks like a
fidelity bug and is not one:

```
[exc-disp] raise tid=00e8 code=c000001d flags=0 addr=0x13ed444e8 pc=13ed444e8 nparams=0 p0=0 p1=0
D E8 Exception: Code: C000001D Address: 13ED444E8
D E8 Reconstructing context
D E8 pc: 13ED444E8 rip: 165EC099C
[set-ctx] ml946 distinct#10 ... is_ec(frame.pc)=1 ec_cur=1
D E8 Exception: Code: C000001D Address: 165EC099C
D E8 Passing through exception
```

The reconstruction path repairs `ExceptionAddress` and `Rip` to the guest VA
before the record reaches managed code, so the `#UD` is delivered to the guest at
`0x165EC099C` as Windows would deliver it. Do not re-open this.

What the tail actually shows is that **nothing handles it**: `Passing through
exception` is immediately followed by

```
wine: Unhandled illegal instruction at address 0000000165EC099C (thread 00e8), starting debugger...
... process_exit_wrapper(-1073741795)
```

So at the moment of the first protected call there is no handler for `#UD` in
this process — not a handler that declined. That is a different question from
"the decryptor rejected the exception", and it is the one worth asking next: on
the reference platform the same call decrypts *before* it ever executes.

### 4f. Which binary we are actually testing

Three copies exist and they are **not the same build**. Always confirm identity
before drawing conclusions:

| copy | size | sha256 (first 8) | `.pdata` funcs | `0xEA` entries |
|---|---|---|---|---|
| `Reference/forzahorizon6.exe` | 184,038,360 | `b8c18ec8` | 414,805 | **4,538 (1.09%)** |
| CrossOver/Steam bottle | — | not installed | — | — |
| `/Volumes/RETROBACKUP/.../ForzaHorizon6/` | 184,268,248 | `63791d0b` | 415,564 | 668 (0.16%) |

The device runs the **Reference** build: the 16 bytes captured in memory
(`ea e9 6b e6 14 48 89 7c 24 10 55 48 8b ec 48 83`) are byte-identical to
Reference at RVA `0x537099c` and are followed by the same
`ec 60 48 8b 05 8b f0 c9 03`. They are not identical to the RETROBACKUP build,
where RVA `0x537099c` is not even a function entry and the surrounding bytes are
entirely different.

Consequence for objective item 6: the RETROBACKUP install is a *different,
more heavily protected* build, so **a local run against it cannot validate this
bug**. Testing locally would test the wrong binary.

### 4g. RETRACTION — the faulting bytes ARE ciphertext

While working §4, the first five bytes were momentarily read as "not ciphertext,
because byte 5 onward is a valid MSVC prologue with a `/GS` cookie". That was
wrong, and the mistake is worth recording because it is easy to repeat.

The bytes at `image+0x537099c` are: `ea e9 6b e6 14` followed by a genuine
prologue. But `.pdata` says the function **starts exactly at `0x537099c`** and is
305 bytes long, and cross-checking the other 4,537 stub functions shows the body
is normally encrypted too. This function is simply one of the ~19 whose body
happens to be readable. A readable prologue after the stub is therefore *not*
evidence that the stub was decrypted — and the objective's original statement
stands unchanged:

> **The 5-byte stub at fault time is still ciphertext. `memory == file` at fault
> time, byte for byte, so it was never decrypted.**

The correct conclusion from §4c's `memory == file` observation is the *opposite*
of the one briefly drawn: it is positive evidence that the decryptor never ran.

### 4h. MEASURED — both copies are ciphertext, and a real sync bug exists

Three separate readings agree at the fault:

| where | probe | bytes |
|---|---|---|
| the PE file at RVA `0x537099c` | offline read | `ea e9 6b e6 14 48 89 7c 24 …` |
| the **backing** at `0x165ec099c` | `[rsp-trunc] x86 @rip` reads `cs[0]` via `mach_vm_read_overwrite` | same |
| the **pool copy** at `0x12ab0099c` | `[guest-code] rev=ml333` | same |

So **nothing decrypted this function in either copy.** That retires a plausible
theory (below) rather than confirming it.

**Theory retired: "the pool is a stale snapshot".** The pool really is a
`memcpy`, not a shared mapping:

```
/* Copy ENTIRE PE image to JIT pool (code + data + headers). */
memcpy((char *)jit_rw_base + offset, image_base, image_size);
```

so the split looked like an obvious root cause: decrypt writes to the backing,
execution reads the pool. It is not, because the backing is ciphertext too.

**But the split is still a real bug, and it is ours.** The only code path that
syncs a written region from the backing into the pool is the
`NtProtectVirtualMemory` hook, and when the region overlaps `.text` it
deliberately drops the code bytes:

```
else
{
    /* Copy only the parts OUTSIDE .text */
    ...
    ERR("iOS JIT IAT sync: partial copy %p+0x%lx → JIT (skipping text [0x%lx-0x%lx])\n", ...);
}
```

The comment explaining why is sound for ARM64EC modules, whose pool `.text`
carries `[x18-patch]` trampolines that a raw copy would destroy. For a **pure
x64 guest image** (`Machine=0x8664`) the pool `.text` is a faithful memcpy with
no such patches, so skipping it is wrong: any program that does the ordinary
Windows decrypt dance (`VirtualProtect` writable → write code → restore
executable) has its code writes silently discarded and then executes the old
bytes. That is a platform-fidelity defect independent of this bug, and it
explains `0` `NtProtect`-sync lines for the image only because the protector
never made a protect call at all.

**What the 99 MB dirty figure does and does not mean.** The observed region is
exactly `header + .text` (`0x639c000`, matching `.text` `0x1000+0x639ace3`
rounded), `dirty=99 MB`. Tempting to read as "the protector decrypted 99 MB".
It is not conclusive: the image was rebased from `0x140000000` to `0x160b50000`,
and recounting the `.reloc` directory gives **1,370,862 DIR64 entries over
9,276 distinct 4 KiB pages ≈ 36 MB** of unavoidable dirtying. So relocations
account for roughly a third; the rest is unidentified. Do not treat the dirty
total as proof of decryption — it was nearly mistaken for exactly that here.

**Still open, and now sharply posed:** the protector allocates its 16 MB+64 KB
arena, then enters a stub that was never written. Whether it *intended* to write
that stub (and the write went somewhere ineffective) or never reached the write
is the next question, and one probe answers it.

### 4i. MEASURED — the `.text` sync hypothesis is REJECTED, and two deploy traps

The suppressed traces were turned back on for one run by shipping a FEX component with
`WINEDEBUG=err+virtual` (the app's default is `err+all,err-virtual`, which is why every
`virtual_ios.c` `ERR()` was invisible; component environment is applied *after* the
default, at `WineProcessBridge.m:2485`). Control: `iOS JIT: copied image` went from 0 to
221 hits. Then:

```
00e4 NtProtectVirtualMemory(orig=0x16bc41000 sz=0x639ae00 prot=0x4)
[prot-img] #45 tid=00e4 ... section #0 '.text' chars 0x60000020 (R-X CODE) new_prot=0x4 old=0x20
[...]
#46 .rdata -> RW, "re-applied 1209291 DIR64 fixups"
#47 .data  -> RW, "re-applied 161049 DIR64 fixups"
#48 .pdata -> RW
```

That sweep is the **loader's relocation pass**, not the protector: the image is rebased
`0x140000000 -> 0x16bc40000` and 1,370,340 of the 1,370,862 DIR64 entries are applied
here. So `.text` becoming writable is **not** evidence of a decrypt.

The `.text` sync really was dropping the code bytes (`skipping text [0x0-0x639ace3]`,
i.e. the whole region, copying nothing). A fix was implemented and **measured as a
non-fix**: with `.text` copied into the pool (`text INCLUDED`, 4 hits), the fault was
byte-identical.

**Why it cannot work, and this is the useful part:** for a *pure x64 guest image* FEX
reads the x86 bytes from the **backing**, not from the pool. The pool copy exists so
ARM64EC/ARM64 code in an image is host-executable; x86 is data to FEX. Confirmed by the
RIP staying a PE VA (`State.RIP=0x170fb099c`) while `[pool-rip-fix]` only ever redirects
*module* pool-copy aliases. Copying `.text` into the pool is therefore off the execution
path — and costs a 99 MB memcpy per protect call. **Reverted.**

What the run did surface is a new, concrete lead, one line before the fault:

```
[exec-alloc] NtAllocateVirtualMemory #4 req_addr=0x178003000 size=0x1001000 protect=0x40
[guest-rwx] #1 0x178000000+0x1004000 prot=rwx — anonymous guest memory, EXEC is FEX
             bookkeeping; applying rw- instead
D E4 Add SMC interval: 178000000 - 179004000
E E4 Invalid instruction in entry block: 170FB099C
```

The protector asks for `PAGE_EXECUTE_READWRITE` and **we silently return non-executable
memory**. That is a real protection-fidelity deviation, it is on the faulting thread, and
it is immediately followed by an SMC interval and the fault.

**Two deploy traps, both hit, both worth remembering.** (1) A newly pushed UnixHalf
component does **not** take effect on the launch that installs it: `UnixHalf` loads the
half at app start (16:53:49) while `installInboxAtLaunch` only imports it afterwards
(16:53:52). One extra launch is required. (2) With two UnixHalf components enabled, the
**older** one is installed, so the new one must be pushed *and* the old disabled in
`Components/state.json` — otherwise the fix never runs and reads as "no effect".

### 4j. MEASURED — the fault is ELIMINATED by honouring guest PROT_EXEC on anon RWX

**First, the address was never written.** `MADEIRA_PROBE_RVA=0x537099c` samples 8 bytes
at `view->base+RVA` on every protect that covers it:

```
[rva-probe] #1 new_prot=0x4  (PAGE_READWRITE)    bytes: ea e9 6b e6 14 48 89 7c
[rva-probe] #2 new_prot=0x20 (PAGE_EXECUTE_READ) bytes: ea e9 6b e6 14 48 89 7c
```

The writable window opened and closed and the stub was **unchanged**, so the protector
makes `.text` writable and then does not write this function. That is the answer to
"does the protector ever write the page containing `image+0x537099c`": it protects it,
it never writes it.

**Second, the same run found the actual defect.** With `MADEIRA_GUEST_RWX_EXEC=1`:

```
[exec-alloc]  NtAllocateVirtualMemory #4 req_addr=0x17a823000 size=0x1001000 protect=0x40
[guest-rwx]   HONOURING guest EXEC
mprotect_exec(0x17a820000, 0x1004000, rwx)
iOS mprotect(rwx) appeared to succeed but EXEC not actually granted (qkr=0 prot=0x3);
  falling through to JIT-pool path
[jit-copy] #5 PRE-REMAP 0x17a820000+0x1004000: 0/16793600 bytes nonzero
[jit-copy] #5 POST-REMAP rx=... rw=... pre=... => PRESERVED
iOS JIT: anon RWX 0x17a820000+0x1004000 → pool off=0x21214000 (rx=0x13ab60000 rw=0x7021214000)
Add SMC interval: 17A820000 - 17B824000
[stp-emul] #1..#8 ... stores redirected into the pool RW alias
```

Dropping `PROT_EXEC` (the ml1030 behaviour) sent the protector's
`VirtualAlloc(PAGE_EXECUTE_READWRITE)` arena to **plain, incoherent `rw-` anonymous
memory**. Honouring it falls through to the JIT-pool path, which **dual-maps the arena
(`rx`+`rw`), keeps contents across the remap, and makes its stores SMC-coherent**. The
ml1030 strip is right for image pages and wrong for anonymous RWX, which is precisely
where a JIT or protector needs coherence.

**Result, measured on device 2026-11-21:** `Invalid instruction in entry block` and
`Unhandled illegal instruction` both **0 for the whole run**, no `fault_rip` whose RIP
ends in `099c`, and the process runs **290 s+** where every previous run died at ~6 s.
The protection crash is gone.

**What is left is a different problem:** the process is alive but idle (`[freeze] alive
t+272s ... threads=52`, `0 wakes/s`, `[rip-profile] no guest threads found`) and no game
window ever appears — the UI returns to the library after "Waiting for its window…".
Also a cost: the 16 MB arena is now a 16 MB pool copy and
`[jit-pool] anon RWX ... used=0x22218000/0x26000000` is **~94% of the pool**, so pool
exhaustion is the risk this trades against.

`MADEIRA_GUEST_RWX_EXEC` is **default off**; the shipped behaviour is unchanged until
this is validated across other titles.

### 4k. Why no window appears — the game is not blocked, the session is

Measured on the 290 s run after 4j. The obvious suspects are all clear:

* **D3D12 / VKD3D is not the blocker.** `d3d12.dll` resolves through the mixed-arch
  fallback to `C:\windows\sysx64\d3d12.dll` → `madeira_d3d12.dll`, and `DXGI.dll` and
  `winemetal.dll` load into the game too. `[winios-vk] Vulkan is off for this session`
  is **expected** on that path, not a failure: it only means `MADEIRA_VULKAN_LIBRARY`
  is unset, i.e. vkd3d is not in use. `[DBG] madeira-d3d12: gate off` only means the
  M1 shader-converter canary did not run (Content View's own note).
* **Steam is not the blocker.** The Dock logged `session-logon-start-result=1`,
  `session-authenticated-online=1`, `session-requested-app-entitled=1`,
  `session-requested-app-listed=1`, `launch-client-error=0`, and `steam_api64.dll`
  loaded into the game at `0x71E9910000`. The game's `IPC:CSteamEngine` peers are the
  Steam client hosted in `dockhost.exe`, and they are alive and idle, not dead.

What actually happened, in order:

```
17:15:09.369  [promote] display link armed (60 Hz)
17:15:09.371  [steam-launch-view] hold app=2483190 auto-reveal=1
17:15:15      [proc-ident] slot 4 = forzahorizon6.exe (peb=0x109fec000, 85 modules)
17:15:19.385  [promote] link ran 593 ticks in 10.0 s = 59.2 Hz
17:15:20.303  [dock-report] launch-client-error=0
17:15:20.431  Wine finished after 10.8s
17:15:20.877  [steam-launch-view] end reason=session-ended scene=waiting revealed=0 t=11s
17:15:20.878  [promote] display link released
17:15:29.926  [ERR] [madeira-dock] session ended without a host result
```

`Wine finished after 10.8s` is `ContentView`'s debugger-wait loop leaving because
`wine_process_is_running()` returned 0. That getter is just `g_wine_running`, set from
`wine_launched_process_did_exit()` — and `WineProcessBridge.h` is explicit that this
fires for **the session's initial process**, and "other processes are not reported".

In the Dock path the initial process is Steam's launch stub: it exits as soon as
`launch-client-error=0` comes back. The game is not that process. So the session is
declared over at 10.8 s, the display link is released, and the launch view gives up
(`revealed=0`) — while `forzahorizon6.exe` is 5 s into an initialization that takes
~5 minutes here. It then runs headless to t+289 s (`[xp]` IPC 3.7–4.0, ~36 % of a
core, `[rip-profile] no guest threads found`, all sampled threads idle).

**Consequence:** "why no window?" cannot be answered from this run, because the
harness stopped watching before the game could reach presentation. Nothing presented
a frame (`presents=` / frame counters: 0 hits) and the display link was never
re-armed. The next experiment has to keep the session bound to the *game* process,
not to the launch stub, and then ask the window question with the game actually
being watched.

**Independent defect found while tracing this.** During window creation there are
three Mach exceptions whose backtrace is exactly the window path:

```
NtUserCreateWindowEx+0xb44
  apply_window_pos+0x970
    winios_drv_window_pos_changed+0x388
      winios_window_frame -> winios_census_note_frame
        winios_drv_census_owner -> get_window_long -> get_window_long_size
          get_user_handle_ptr   (pc fault, addr=0x18, x9=0x18, insn c8dffd29 = CAS)
```

`winios_drv_census_owner()` (this repo, `build/win32u-unix/driver_ios.c`) calls
`get_window_long(hwnd, GWL_STYLE)` on the handle it is handed; the lookup resolves to
no object and the refcount CAS then dereferences `NULL+0x18`. It occurs in
`explorer.exe` (peb `0x71ffff0000`) while the desktop window is created, and the run
recovers, so it is **not proven** to be the game's window blocker — but it is a fault
inside the exact syscall that creates windows and should be guarded regardless.

### 4l. A/B: the census faults are gone, and they were NOT what ends the session

Hypothesis from 4k: the census probe's Mach exceptions fault the desktop and end
the session. Tested without a rebuild by `env.MADEIRA_DOCK_HIDE_DESKTOP = 0` in
`madeira.cfg`, which also switches the window census off (DockStartScreen.swift
returns before `winios_window_census_enable(1)`).

| | before (census on) | after (census off) |
|---|---|---|
| `get_user_handle_ptr` faults | 4 of 5 unhandled exceptions | **0** |
| unhandled Mach exceptions | 5 | 5, at *different* PCs |
| `wine client error:0: write: Bad file descriptor` | 1 | **3** |
| desktop exit | code 1 at 10.8 s | **code 1 at 10.6 s** |
| `Invalid instruction in entry block` | 0 | 0 |

So the census guard (this repo, `winios_drv_census_owner`) removes a real fault —
it is worth keeping — but the census was **not** what ends the session. The desktop
dies either way, with an identical signature and at the identical moment relative
to the game's start.

**The session-ending defect, now isolated.** Immediately before the desktop goes:

```
wine client error:0: write: Bad file descriptor
err:thread:abort_process abort_process: status=0x1 — tearing down this pseudo-process only
[Wine ntdll/server] process_exit_wrapper(1)
[WineProc] Wine exited with code 1 (caught by longjmp)
```

The client cannot write to the wineserver on its server fd, calls
`abort_process(0x1)`, and because explorer.exe *is* the session's initial process
this ends the whole session (`g_wine_running = 0`, then `wineserver_stop()`). The
game — started by the Steam client in `dockhost.exe` — keeps running with no
desktop, so nothing can ever be presented.

The three failures come in a burst right after a pair of 64 KB
`VirtualAlloc`/`VirtualFree` from one thread. The wineserver connection is the
thing to instrument, and that lives in the **unix half**, which is component-
overridable — so this is a `.wcp` push, not an IPA rebuild.

The 5 remaining unhandled exceptions are unrelated addresses
(`0x111f59bfc` `addr=0x8` twice, `0x198e1ff94` `addr=0x0` twice — the known wild
pointer from 4b — and `0x1106c59ac` `type=6`).

### 4q. The session fix exposes the original bug cleanly: 0xC000001D at t+16.6 s

With the session now held open, the game's own end is unambiguous in the log:

```
[jit-pool] image 0x132b50000+0xb3c0000 (forzahorizon6.exe) → pool 0x153a44000
E E8 Invalid instruction in entry block: 137EC099C
D E8 Exception: Code: C000001D Address: 137EC099C
wine: Unhandled illegal instruction at address 0000000137EC099C (thread 00e8), starting debugger...
[jit-pool] RECLAIM peb=0x107fec000: 90 ranges 0x167d4000 bytes freed, 85 mappings tombstoned
[Wine ntdll/server] process_exit_wrapper(-1073741795)
```

`-1073741795` as a 32-bit status is **0xC000001D**, `STATUS_ILLEGAL_INSTRUCTION`, and
`0x137EC099C − 0x132B50000 = 0x537099C` — the same `image+0x537099c` this document was
opened for. So:

* the game is not blocked, and not failing anywhere new: it runs 16.6 s, reaches the
  protected stub, and dies exactly as §4 describes;
* what the session fix changed is that the death is now **the game's own and observable**
  instead of a five-second teardown that also killed it;
* the trailing `[zombie] … faulted pc=0x71f38361c0 … ended this thread only` and the
  `[store-noalias] … prot=1 … exec-downgraded page that never got dual-mapped` are
  consequences of the pool reclaim that follows the exit (the thread's page was freed
  under it), not the cause.

Everything open therefore reduces again to §4: does the protector ever write the five bytes
at `image+0x537099c` before control reaches them? The session-lifetime work is no longer in
the way of answering that.

### 4p. FIXED: the session now outlives the launcher, and the game is blocked, not dead

The app rebuild (Debug, incremental, ~100 s) carried three changes: the child-table reader
through the half, the app-side reader preferring it, and the half-side holder. Measured on
the first run afterwards:

```
[WineProc] Wine exited with code 0 (caught by longjmp)
[WineProc] the main process exited but 5 child process(es) it started still run
            (dockhost.exe services.exe conhost.exe rpcss.exe forzahorizon6.exe)
            -- a launcher started the game; the session goes on until they exit
[WineProc] still running: 4 child process(es) (dockhost.exe services.exe conhost.exe rpcss.exe), 60 s
[WineProc] still running: 2 child process(es) (services.exe rpcss.exe), 240 s
```

The session stayed up for the whole 240 s window instead of ending at 5–15 s, and the
screen kept a live session (HUD, "Game menu") the whole time. **`MADEIRA_WAIT_CHILDREN` is
the fix, and it only works once the child table is read from the image that fills it** —
which is the app's own copy, so this needed the rebuild, not a package.

Two things this exposes, both new:

* The game does **not** exit. It is blocked in a native wait with no window:

  ```
  [thread-sample] modmap peb=0x107fec000 modules=85 first=forzahorizon6.exe@0x132b50000
  [thread-sample] b0 teb=0x703b3b0000 cpu=0% wait pc=0x71f38361c0 NATIVE (no FEX state)
                  sp-cand=[forzahorizon6.exe+0x63f4510 forzahorizon6.exe+0x639e4c0 ...]
  ```

  So the "no window" question is no longer "does the session end" (it does not) but "what
  is the game's first thread waiting on". 0 % CPU, 85 modules mapped, the stack holding
  return addresses in its own image: a blocker inside the guest, not a crash and not the
  protection fault of §4.

* `forzahorizon6.exe` is listed at the first census and missing from the 60 s one while its
  threads are demonstrably alive. Its child slot is being released or marked exited early
  (`ios_child_slot_release` when a child's boot thread returns, `ios_child_slot_exited` by
  PEB), so the session currently stays alive only because `services.exe` and `rpcss.exe`
  outlast the game's slot — not because the game is tracked. That has to be fixed before
  the wait can be trusted as a game-lifetime signal.

`[child-census] ml2029 … games=0() used=0() session=0x0 caller=0x0` also now appears, from
the half's copy of the table, in the same seconds the app's copy listed five names: the two
arrays are confirmed distinct, and the app's is the populated one.

### 4n. The session-ending exit is not in the copy a `.wcp` can patch

Four consecutive unix-half packages were pushed, verified loaded on device, and produced no
output at all on the path that ends the session:

| package | probe | result |
|---|---|---|
| `unixhalf-ml1381-ebadf` | `[srv-ebadf]`, EBADF only | silent |
| `unixhalf-ml1382-wfail` | `[srv-wfail]`, **any** failed server write | silent |
| `unixhalf-ml2027/2028-sessionhold` | hold the session while a spawned game runs (unconditional on entry to the else-branch) | silent |
| `unixhalf-ml2029-census` | **unconditional** `[child-census]` line at every session exit | silent |

Each was confirmed to be the loaded half (`[unix-half] component half INSTALLED from
…unixhalf-ml2029-census-native…`, and the strings are in the pushed dylib), and each run
still ended with the same sequence:

```
wine client error:0: write: Bad file descriptor
err:thread:abort_process abort_process: status=0x1 — tearing down this pseudo-process only
[Wine ntdll/server] process_exit_wrapper(1)
[WineProc] Wine exited with code 1 (caught by longjmp)
```

The exception backtrace names the image, and it is the app, not the component:

```
bt[0] Madeira.debug.dylib`__wine_main / init_options
bt[2] Madeira.debug.dylib`abort_process+0x58
bt[3] Madeira.debug.dylib`abort_thread
bt[5] Madeira.debug.dylib`wait_select
```

So the half that reaches `server_protocol_perror("write")` → `abort_thread` → `abort_process`
→ `process_exit_wrapper` → `exit()` is the **static archive linked into
`Madeira.debug.dylib`**. That is why every probe in the component was silent: none of them
was on the failing path. `GetCurrentThreadId()` printing **0** in the message (`wine client
error:0:`) agrees — the writer has no TEB.

Consequence, and it retracts an earlier conclusion: **unix-half instrumentation is not
sufficient to diagnose or fix this path, whatever the packaging says.** A change to
`server_ios.c` reaches it only through an app rebuild. `app/Madeira/libntdll_unix.a` is
already rebuilt from the current sources, so the next app build carries the probes, the
holder and the entry-surface reader together.

What the run also shows is that the game is no longer failing at the fault this document
was opened for. In the same run the game loaded its own code:

```
00e8: NtProtectVirtualMemory(orig=0x131851000 sz=0x639ae00 prot=0x4)
[rva-probe] #1 tid=00e8 pe=0x136bc099c+0x537099c new_prot=0x4 bytes: ea e9 6b e6 14 48 89 7c
```

i.e. it committed and protected 104 MB of `.text`, and the stub at image+0x537099c is still
ciphertext, as §4g says it should be at that moment. The remaining blocker before any window
can appear is now this exit path, not the protection.

### 4m. The failing write is NOT in the component half — it needs an app rebuild

Two probes were pushed as `native` components and measured on device:

| probe | what it logs | result |
|---|---|---|
| `unixhalf-ml1381-ebadf` | `[srv-ebadf]`, only when `errno == EBADF` at the failed server write | **silent** (run 17:55) |
| `unixhalf-ml1382-wfail` | `[srv-wfail]`, **unconditionally** on any failed server write | **silent** (run 18:02) |

Both runs were verified to be executing the component half, not a stale one:

```
[unix-half] component half INSTALLED from .../Components/unixhalf-ml1382-wfail-native-native/files/libntdll_unix.dylib
ml989: running image .../unixhalf-ml1382-wfail-native-native/files/libntdll_unix.dylib base=0x10b898000 LC_UUID=B067...
```

and both runs still printed `wine client error:0: write: Bad file descriptor` and still
ended the session with `Wine exited with code 1`. The string `[srv-wfail]` is present in
the pushed dylib (`strings` check) and `ml1382` replaced `ml1381` as the only enabled
native component.

**Conclusion.** The write that fails is executed by a *second* copy of the half — the
`libntdll_unix.a` that `build/ntdll-unix/build.sh` copies into `app/Madeira/` and that
the app links statically. A source change in `build/ntdll-unix/server_ios.c` therefore
does not reach this path by `.wcp` push. **This corrects the earlier note that unix-half
instrumentation ships by package push without an IPA**: that is true for whatever is
reached through the function table the component installs, and false for this path.

Also note `GetCurrentThreadId()` printed **0** in the message, i.e. the failing write
comes from a thread with no TEB — consistent with app-side code rather than a guest
thread.

The probes are kept in the source (behind `#ifdef WINE_IOS`, no behaviour change by
default) so the next app rebuild answers the fd question immediately, and
`MADEIRA_SRV_CLOSED_IS_EPIPE=1` is available to test the "closed pipe is the
killed-thread case" hypothesis in that same rebuild.

### 4o. What the dock session looks like end to end (measured, JIT on)

A clean run with JIT, `env.MADEIRA_DOCK_HIDE_DESKTOP = 0`, `env.MADEIRA_WAIT_CHILDREN = 1`,
`unixhalf-ml2029-census`:

```
t+0.67s  spawn dockhost.exe          (the session's first program after explorer.exe is the
                                      desktop: argv[1]=explorer.exe /desktop=…, argv[3]=dockhost.exe)
t+0.76s  spawn conhost.exe
t+0.82s  spawn rpcss.exe
t+5.15s  spawn forzahorizon6.exe     (Steam's launch, from dockhost's client hand-off)
t+5.2s   game commits/protects 104 MB of its own .text; rva-probe sees the stub still `ea`
t+~13s   a TEB-less thread writes to a torn-down server pipe → EBADF → abort_process(1)
         → process_exit_wrapper(1) → exit() → longjmp → [WineProc] stopping wineserver
```

So `dockhost.exe` is a launcher stub in the sense `MADEIRA_WAIT_CHILDREN` was written for,
and the game it starts is a *grandchild* (dockhost → Steam client → game). `[dock-report]
launch-client-error=0` is dockhost saying the hand-off worked, seconds before the session
ends.

`MADEIRA_WAIT_CHILDREN=1` did not hold it, and the reason is not the value: the check is in
`WineProcessBridge.m`, which calls `madeira_live_game_children` through the app's linked
copy of the half, while `spawn_process` fills the child table from the unix side. With a
unix-half component installed those are different arrays, so the app's copy is always empty
and both the launcher-stub wait and the program-end watch silently do nothing. That is why
ml2027 moved the wait into the half (`server_ios.c`, where the table is) and ml2029 logs the
table unconditionally — but per §4n neither ran, because the exit is in the archive copy.

### 4e. Scope note

Per the objective's boundary: this is a memory-layout / loader-fidelity question
and is in scope. Nothing here indicates an anti-tamper verdict about emulation,
and no detection-evasion work is warranted or done.

---

## 5. Premise corrections

The objective carries "established facts" that no longer match measurement. They
are listed here so the next session does not pursue the objective from a
falsified starting point.

1. **"The binary cannot register a vectored exception handler by any name;
   `[veh-chain] EMPTY` is the only possible state."** Measured otherwise in an
   earlier session: `[veh-add] func=1453CD858` is registered and `[veh-chain]`
   delivers to it. *This* build's log has no `veh-*` lines at all — the probe is
   not present, so this log can neither confirm nor refute it. Treat the claim
   as unproven rather than established.
2. **"The `FEX_*` environment preset changes nothing."** See §3 — it does, and
   one key in it was blocking the launch outright.
3. **"Dies within ~1 s."** Now ~6 s of real execution (`t+7.633s` spawn,
   `+13.86` at the fault). The longer life is a consequence of §3, not of the
   fault changing.

Still standing and re-confirmed: the faulting bytes are ciphertext at fault time,
and the fault is at `image+0x537099c`.

---

## 6. Next experiments, cheapest first

1. **Find out whether the stub decryptor ran at all.** §4c/§4g establish that the
   5-byte stub was never written as of the fault. So the single highest-value
   question is whether the protector's own decrypt/init path executed. The
   decisive observation is cheap: catch the *first* guest write whose range
   touches any of the 4,538 stub RVAs (the set is enumerable from `.pdata` +
   `byte==0xEA`, so a probe can be preloaded with it). Then:
   - never written → the decryptor never ran; search upstream in the protector's
     init, and compare against a run where `FEX_SMCCHECKS` is default rather than
     `full` (§3 shows the env genuinely matters).
   - written, but the executed bytes are stale → SMC invalidation, see item 3.
2. **Fix the two probe defects in §4a** so a future fault is not mislabelled as
   a wild store. Already written and packaged (`dist/unixhalf-ml2026-native.wcp`);
   needs the phone.
3. **Port the remaining SMC patch, `fh6-fex 0004`, and be precise about what is
   left.** An earlier note claimed 0001/0002/0004 were all unported. That is
   wrong: **0001 and 0002 are already in** (`1774c2fd9`, then `01161827e`
   re-ported 0001 properly onto the FULL path), and 0003 is ported
   (`a72fe4093`). Only **0004 "jit-stability-and-smc-batching"** remains — 2,395
   lines across ~20 files plus two new files (`SharedCodeBufferManager.{h,cpp}`)
   that do not exist in our tree, and it does not 3-way apply. Its central
   abstraction `FH6Stats` has 0 occurrences here.
   This matters because the protection *is* self-modifying code: 4,538
   functions are decrypted in place at run time (§4), which is exactly what a
   block-level SMC validator has to notice. The reference's own README says the
   patches let FH6 "boot past its anti-tamper checks" — read carefully, those
   patches are SMC **correctness**, not evasion: making FEX notice code writes
   lets the game's own self-checks pass honestly. That is in scope under
   boundary rule 2; faking detection results would not be.
4. **DroidDeck comparison (north star).** Compare what DroidDeck's FEX does with
   the same two VirtualAllocs — the count of refusals and the granted protection
   are directly comparable from its logs, and that is the one measurement that
   says whether our allocator is Windows-like where it matters.

---

## 7. Evidence appendix

Logs referenced: `madeira-log.txt` of the 15:27 run (`forzahorizon6.exe-
2026-11-21_15-27-06.txt`), 13,826 lines. Fault at line 9592; arena sequence at
9580–9596; spawn at 7324.

Note for whoever pulls the next log: `madeira-log.txt` is hard-linked into
`logs/<exe>-<stamp>.txt`, and **AFC refuses to read or copy a file with
`st_nlink > 1`** (`FILE_OPEN failed with status: 1`). Delete the `logs/` link
first, or the copy silently produces a 0-byte file.
