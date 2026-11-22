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

### 4u. The census was silent for its OWN bug: a 130-byte header read

The 19:18 run (now with `ml2030` actually loaded — confirmed by the loader line,
and this time the import ordering was right) still printed no `[stub-census]`
line, while `[xp]` and `[jit-pool]` lines flowed normally.

The dylib on the device contained the probe (format string and `_ios_stub_census`
present, sha verified by read-back), so this was not a deployment miss. It was my
own bounds check:

```c
unsigned char opt[130];
...
dir = (magic == 0x20b) ? 112 : 96;      /* data-directory table starts here */
if (!dir || dir + 4 * 8 > sizeof(opt)) return;   /* 144 > 130 -> always return */
```

The PE32+ data-directory table is 16 entries of 8 bytes starting at optional-header
offset 112, so `IMAGE_DIRECTORY_ENTRY_EXCEPTION` (index 3) lives at 136..143 — past a
130-byte buffer. **Every image took the return, silently, on every sample.** Measured
offline on the real image: the table needs 240 bytes.

Two fixes, both about the same lesson:

1. read 264 bytes of optional header;
2. **a probe that can be silent is not a probe.** Every early return now carries a
   reason code (`no-pdata`, `pdata-outside-image`, `unreadable-opt`, …) and the
   sampler prints `no image >=1MB in ios_jit_mappings (count=N)` when the table
   yields nothing. Zero samples is now a statement, not an absence.

`tools/pe/check-stub-census.py` is the offline guard: it runs the same walk from the
same field offsets against a real image and compares with
`tools/pe/protected-stubs.py`. It found a second bug immediately — the offline walk
treated RVA as a file offset, but `.pdata` lives at RVA `0xac00000` and file offset
`0xa7c4600`, so it reported `pdata-outside-image` on a perfectly good image. With the
section table applied, it reproduces the independent enumerator exactly:

```
.pdata functions : 414805
0xEA entries     : 4538
protected-stubs  : 4538 stubs
OK: counts match the independent enumerator
```

(The device-side C code reads the *mapped* image, where RVA and address offset are
the same number, so no translation is needed there — the mistake was only possible in
the offline model, which is exactly why the model needed the check.)

### 4v0. HAZARD: two global config keys can break the shell or hide the Steam library

Both of these were introduced on 2026-11-22 by editing `madeira.cfg` to run a
probe binary, and both are measured before/after. The pristine contents — the
exact set 104 of 104 recorded runs used — are:

```
env.-MADEIRA_SWAP_COVERAGE = wide
env.MADEIRA_JIT_SHORTCUT = 1
env.MADEIRA_ONE_SESSION_PER_RUN = 0
env.MADEIRA_SWAP_COVERAGE = wide
pool = 512
swap-mb = 2048
```

**a. `env.MADEIRA_DOCK = 0` removes the Steam library.** 
`SteamOwnedLibrary.enabled == MadeiraDock.enabled && MADEIRA_STEAM_LIBRARY`,
and `MadeiraDock.enabled == MADEIRA_DOCK (default 1) && bundled`
(SteamOwnedLibrary.swift:296, MadeiraDock.swift:58). Setting it to 0 did not
merely skip the dock: it removed the Steam section, its games and the Workshop
row. Measured: `[library-sections] native-steam=0 sections=0` with the key, and
`native-steam=1 sections=1` — games back on screen — without it. Leave this key
OUT; the default is already the value you want.

**b. `env.MADEIRA_USE_ARM64EC = 1` kills the shell with `0xc000007b`.**
`explorer.exe` is Machine `0xaa64`. Correct routing is
`PE routing: machine=0xaa64 bundle=aarch64-windows force-ec=0`. With the key set,
the same exe is force-routed as `bundle=arm64ec-windows ... force-ec=1`, and
`explorer.exe` exits `0xc000007b` after ~1 s — before any child spawns, so every
library "Play" appears to do nothing. EC is a per-game decision the app makes
itself (the game's own `game-cfg` line carries it); a global key breaks every
AA64 image in the session. Measured both ways in the same hour: with the key,
`exit-report status=0xc000007b` and no spawns; without it,
`[phase] spawn: dockhost.exe / services.exe / conhost.exe / rpcss.exe` and the
session lives.

An earlier version of this note called that shell failure "pre-existing". It was
not: the archives show 97 runs with `Target exe: explorer.exe` and not one exiting
`0xc000007b`, and the last good one differs from the broken one only in this key.

There is exactly one config the app reads —
`Documents/Data/Application/EDAFB512-.../Documents/madeira.cfg` — and no backup is
taken automatically. Never write it blind:

1. `afc-pull.py` it first. A 0-byte result is a FAILED read (AFC returns nothing
   for some files), not an empty config; re-read the effective values from the
   last line starting `[INFO] madeira.cfg:` in the log instead.
2. Reconstruct from the 104/104 baseline above and add only keys you mean to
   test, one at a time, so a regression has a single suspect.
3. After a push, confirm in the next log both `[library-sections]
   native-steam=1` and `PE routing: ... force-ec=0` before concluding anything
   about a game.

**c. The two keys a component unix half NEEDS (not a hazard — a prerequisite).**
`§4ac` proves a component half leaves the app's statically linked copy of the half
uninitialised, and the first direct call into it writes to fd 0 and aborts the
calling pseudo-process (usually `explorer.exe`, the session's main process). Until
the app-side fix lands, any run with a component half needs:

```
env.MADEIRA_SRV_CLOSED_IS_EPIPE = 1
env.MADEIRA_WAIT_CHILDREN = 1
```

Measured with them: dock host started, `forzahorizon6.exe` spawned at `t+8.043s`,
session stayed up through the game's fault. Without them: no spawn, or a session torn
down at ~11 s. These two are the only additions this project's probes require, and
they are *not* part of the 104/104 stock baseline — remove them to compare against
stock behaviour.

### 4v. Iteration win: a dylib change is one push, effective next launch

The two-launch cost seen in §4s was an artefact of deploying through the `Import`
inbox. A component's files are loaded from
`Documents/Components/<id>/files/libntdll_unix.dylib`, and AFC can write that path
directly, so replacing the half is now:

```
codesign -f -s "<dev identity>" /tmp/slot/libntdll_unix.dylib   # identifier + team
pymobiledevice3 apps push ... <component>/files/libntdll_unix.dylib
afc-pull.py <same path> /tmp/readback                          # sha256 must match
```

Measured this turn: 3.7 s for push + read-back, and the change applies on the *next*
launch (no install pass). Keep the file name `libntdll_unix.dylib` when signing —
`codesign` derives the identifier from it, and the previous slot's identifier is
`libntdll_unix`.

### 4w. The census works, and the answer it first seemed to give is NOT the answer

The first working census sample (19:22 run, `ml2030`, game image reached at t=10.4 s):

```
[stub-census] t=10.4s image=0x133a40000 (188481536 bytes) .pdata functions=414805
              | first byte still 0xEA (ciphertext)=4538  decrypted=410267  unreadable=0
```

Read this carefully, because the numbers are easy to misread:

- `414805` is the whole `.pdata` function table and it matches the offline
  enumerator exactly — so the walk, the header offsets and the section handling are
  right on the device, not just offline.
- `4538` is *precisely* the protected set. Not "most of it", not "a few hundred" —
  the entire set is still `0xEA`.
- `410267` is not "decrypted stubs". It is `414805 − 4538`: ordinary functions that
  never started with `0xEA` in the first place. Nothing went from ciphertext to
  plaintext.

**Correcting my own first reading of this line.** I initially wrote that this proves
"the protector decrypted nothing, ever". The timeline says otherwise, and the
timeline is the more interesting result:

```
t= 8.10  RWX arena 0x170e30000+0x1008000 mapped   ([guest-rwx] #1, [jit-pool] off=0x21214000)
t=10.35  200,000 emulated 32-byte stores into it   ([fault-class] "200000 emulated stores so far")
t=13.70  400,000 emulated stores, 12.5 MB spans    ([fault-class] "...400000")
t=15.38  fault at image+0x537099c
```

So the t=10.4 sample was taken **in the middle of the unpack**, before any decrypt
pass on the image could have run. The census is not wrong; it is simply early, and
v1's 6-second cadence meant it never got a post-unpack sample in a session that ends
at t=15.4. Two probes answer this properly (below); the claim "not one entry was
decrypted ~5 s before the fault" is true but says nothing about the decrypt pass,
because at t=10.4 the protector was still copying.

**What the timeline does establish, and it is a lot:**

1. The decryptor does run, and it is enormous: **400,000 emulated stores, one Mach
   round trip each, 7.7 µs average, 1.5 s of pure handler time**, writing ~12.5 MB
   contiguously at 32 bytes per store into the RWX arena. On Windows that is a
   `memcpy` of a few milliseconds. 99 % of it comes from a single thread
   (`[fault-by-thread] port=0x139e3 faults=399996 (99%)`).
2. The arena is entered through the pool path because iOS refuses host EXEC:
   ```
   [guest-rwx] #1 0x170e30000+0x1008000 prot=rwx — ... applying rw- instead
   [guest-rwx] #1 ... HONOURING guest EXEC (MADEIRA_GUEST_RWX_EXEC=1 ...)
   iOS mprotect(rwx) appeared to succeed but EXEC not actually granted (qkr=0 prot=0x3)
   → falling through to JIT-pool path
   [jit-copy] ml634 #5 PRE-REMAP ... 0/16809984 bytes nonzero — copied into pool off=0x21214000
   D E8 Add SMC interval: 170E30000 - 171E35000
   ```
   Note `Add SMC interval`: FEX is told this range is self-modifying. But every store
   into it arrives through the **emulated Mach store path**, not through a write to
   the RX page — and that path is documented in `signal_arm64_ios.c` as never
   invalidating FEX's cached translation. For a *data* destination that is merely
   slow; for code it is the difference between executing the unpacked bytes and
   executing whatever FEX translated the page as when it was still zeros.
3. The two copies of a PE image are **not** aliases. Anon RWX uses `vm_remap` on the
   pool slot, so guest VA and RW alias are the same physical pages. A PE image's pool
   copy is a `memcpy`, and `NtProtectVirtualMemory`'s sync explicitly refuses to copy
   `.text`:
   ```
   iOS JIT IAT sync: partial copy %p+0x%lx → JIT (skipping text [0x%lx-0x%lx])
   ```
   So a decryptor that writes image `.text` through the guest view has its work
   discarded, then executes stale ciphertext — which is exactly our symptom, and
   exactly the one hypothesis the t=10.4 census sample cannot see (it was too early).

### 4x. Two probes that close the gap instead of guessing

`[text-sync]` (virtual_ios.c, at the sync that skips `.text`) compares the two copies
of the overlapping `.text` window *before* the copy and reports how many bytes differ
at the moment the caller protects `.text` executable. Nonzero is the decryption being
thrown away, with the byte count as the size of the loss. Rate-limited, 40 reports.

`[arena-progress]` samples one 4 KB page per MB of the largest live anon RWX alias
every 250 ms, so the log says how far the unpack had got and whether it finished
before the fault — the fact v1's cadence missed.

`[stub-census]` v2 also reads the same 4,538 RVAs in **both** copies every 250 ms and
prints on change, with a loud `THE COPIES DISAGREE` line. Pool address is measured,
not assumed: run 8's `pool_rip=0x158db499c − jit_base=0x153a44000 = 0x537099c`, the
faulting RVA exactly.

All three ship in one dylib (`ml2030` slot, sha `2d606889…` verified by read-back).

### 4y. The configuration the reference *requires* is the one we could not afford

The reference's troubleshooting table says, for an anti-tamper or integrity error:
"the preset is **Denuvo** (it turns on full code checks)". Its per-game environment
list includes `FEX_SMCCHECKS=full`, and the GameNative note repeats it. So the
package that boots FH6 on Android runs FEX with **full self-modifying-code
validation** — the anti-tamper depends on it.

§3 records why we do not: with `full` on this port, Steam's own launch timed out
(`launch-client-error=46`), and it was isolated to that single key with the DLL
swapped for stock. The reference gets away with `full` because its FEX carries
patch 0002 (block-level CRC validation). **This port did not.** My earlier note said
0001/0002 were both ported; that is true of 0001 and false of 0002 — verified by
`grep -r ContainsWritableCode` and `grep -r FEX_SMC_BLOCK` over `FEXCore/Source`,
both empty before this change.

`full` on unpatched code means a CRC per *instruction* on **every** decoded block in
**every** process. That is why Steam's launch timed out; it is not an anti-tamper
verdict and not a module problem.

**Partial port of 0002 (this commit).** The patch is only 126 lines / 3 files, but
its chunked-CRC half rides on 0004 (a `crc32` helper, patchable CRC,
`_ThreadRemoveCodeEntry(entry, end)`), none of which exists here. The half that
survives without 0004 is the one with the argument, and it is the reference's own
reasoning:

> Non-writable code can only change through a protection change or remap, which the
> frontend invalidates, so FULL only needs per-instruction validation for writable
> code.

So: `DecodedBlockInformation` gains `ContainsWritableCode`, set from
`RangeInfo.Writable` in `CheckRangeExecutable`, reset per decode, and the
per-instruction CRC under `CONFIG_SMC_FULL` is gated on it. Code that cannot
self-modify stops paying for validation; code that can still gets it.

This is **behaviour-neutral for the configuration on the device** (`SMCChecks` is
not `FULL`, so the condition reduces to `ForceFullSMCDetection || HotSMCBlock`
exactly as before) and is therefore safe to stage ahead of the experiment that needs
it. It also builds for the ARM64EC module the game actually runs
(`build/fex-arm64ec/build.sh` → `app/Madeira/arm64ec-windows/xtajit64.dll`), which
is the module that becomes `${system32}/xtajit64.dll`.

**Sequencing, because the two halves of a `.wcp` land on different launches.** A
package's *files* apply on the launch after it is imported; its *environment* applies
at import. So turning on `full` in the same package as the gated DLL would run one
launch of `full` against the ungated emulator — which is exactly the launch that
times out. Order:

1. Stage `FH6-iOS-1.4-fex.wcp` (gated DLL, unchanged 14-key environment) — **done**,
   in `Documents/Import`, sha `acabb660…` verified by read-back.
2. After it installs, add `FEX_SMCCHECKS=full` as an environment-only change. The
   gated emulator is already in place, so that launch measures the thing we want.

Not a claim that `full` will then boot the game. It is the precondition for the
experiment, and it is the first time that experiment can be run at all.

### 4aa. Census v2 answers it directly: the arena holds ciphertext, and nothing ever writes it again

This closes the question §4w left open. Census v2 (`ml2040`+) runs on its own 250 ms
thread inside the component and samples **both** copies of all 4,538 protected entries,
plus the guest's 16 MB RWX arena. Raw log, run 20:44:

```
[stub-census] waiting for a >=32MB image at t=0.3s (iojit mappings=22)
[stub-census] v2 armed at t=5.3s: image=0x16c340000 pool=0x1267a0000 size=0xb3c0000
              | 4538 protected entries to watch (expected 4538)
[stub-census] t=5.3s  of 4538 still 0xEA: image=4538 pool=4538 (pool readable=4538/4538)
[stub-census] t=16.6s of 4538 still 0xEA: image=4538 pool=4538 (pool readable=4538/4538)
[stub-census] t=36.3s of 4538 still 0xEA: image=4538 pool=4538 (pool readable=4538/4538)
[stub-census]   rva=0x1500 bytes: ea 49 f5 8a d5 | pool: ea 49 f5 8a d5
                (IDENTICAL: neither copy was written)
```

**1. Nothing is ever written to either copy.** Not at t=5.3 s, not at fault time, not
30 s after the process is already dead. `image` and `pool` agree at every sample, so
this is *not* the dual-map loss of §4x — there is simply no write to lose. The
`[text-sync]` counter is 0 for the same reason: at protect-to-exec the two `.text`
copies are identical.

**2. The decryptor's output is not plaintext.** The arena's own contents, at the
moment it is full (`ml2042`, 20:46):

```
[arena-content] t=74.4s arena=0x16e900000:
   80 dd df 44 6d 7e 23 35 cc f2 b3 7a eb f6 09 35 c7 9d 19 49 d1 5b 1a 35
 | image.text@0x1000:
   48 8d 0d 09 a4 25 07 48 ff 25 6a b4 39 06 cc cc 48 8d 05 e9 ff ff ff c3
 | 0xEA in arena[0,4K)=13 of 4096 (ciphertext ~16, code ~0)
 | arena==image:NO
```

The image's `.text` at `0x1000` is ordinary x86 (`lea rcx,[rip+…]; jmp [rip+…]`) — so
`.text` is *not* wholesale encrypted, only the protected region is. The arena is
high-entropy with `13/4096` occurrences of `0xEA`, which is the random-incidence rate
(4096/256 = 16), not the rate code shows (~0). So the 12.5 MB the protector staged is
**ciphertext**, and no pass ever turns it into code.

**3. It is not a copy of the image.** `[arena-needle]` searched all 16 MB of the arena
for the exact bytes of the faulting stub (`stub@0x537099c = ea e9 6b e6 14`):
`NOT FOUND`. So the arena is an independent blob, not a staging copy of the section
the protector was about to patch back.

**4. The arena is frozen after the fill.** Every `[arena-content]` sample from t=17.4 s
to t=87.5 s reports byte-identical contents. There is no second pass, at any point,
ever.

**5. The fault tracks the END of the fill, not a fixed time.** In the 20:33 run the
fault was at t=17.05 s with the arena at 17/17 sampled pages; in the 20:46 run the
fault was at t=16.96 s with 16/17. Read together with the 19:22 run (fault at 15.38 s,
12.5 MB staged) the sequence is: stage → **call the first protected stub** → `#UD`.
The stage is the last work the protector does.

So the refined statement, which replaces both "it decrypted nothing, ever" and "it
decrypted into a staging buffer and we lost the copy-back", is:

> The protector stages ~12.5 MB of ciphertext into a fresh 16 MB RWX mapping and then
> immediately calls `image+0x537099c`, where the bytes are still `0xEA`. Nothing has
> ever decrypted that entry, in any copy, and no write to either copy is ever observed.

That makes the open question much narrower than it was: **what is supposed to turn
`0xEA` into code before that first call, and why does it not run here?** §4e boundary
applies — the answer has to be a platform-fidelity difference we can name, not
something that convinces the protector we are Windows.

**Tooling corrections from this run, because they cost several false negatives:**

- `build/ntdll-unix/build.sh` does **not** produce `libntdll_unix.dylib`. It builds the
  static archive for the app. The dylib is `build/ntdll-unix/build-dylib.sh`. Skipping
  that step is silent: `build.sh` prints "41 succeeded", `make-native-wcp.sh` signs and
  packages the **previous** library, and every probe reports the old build's output.
  Five builds (`ml2035`…`ml2039`) were shipped this way. `tools/local/build-half.sh`
  now runs both and refuses to package a dylib older than its newest source.
- A `.wcp` pushed to `Import` installs on the *current* launch but only runs on the
  *next* one, so `tools/local/dev-run-fh6.sh` counts packages before restarting and
  restarts twice when there were any.
- The interpreter lives under `Application Support`, so an unquoted `$PMD3` splits at
  the space; every in-script log pull failed for six runs while the same command typed
  by hand worked. Now a function.
- `afc-pull.py` matched hard links by exact mtime, then by exact size. Both race a log
  that is being appended to. It now matches the other `nlink>=2` entry in `logs/` by
  closest size.
- A 1 MB stack array in the census thread crashed the whole app
  (`___chkstk_darwin` + Mach exception). Heap only on that thread.

### 4s. Reproduced, and the fault is RVA-invariant

The 19:07 run (ml2029 still loaded — see below) died the same way, with the image
at a different base:

```
[jit-pool] image 0x1333c0000+0xb3c0000 (forzahorizon6.exe)
E E8 Invalid instruction in entry block: 13873099C
wine: Unhandled illegal instruction at address 000000013873099C (thread 00e8)
```

`0x13873099C − 0x1333c0000 = 0x537099c`, exactly as at base `0x132b50000`. Third
independent placement, same RVA, so the fault tracks the image and not any pool
address (which is what retracted the alias theory earlier, §4 alias-retraction).

**The census did not run: this session loaded the wrong half.** The log's first
line is the loader's verdict, and it predates the import:

```
[19:07:37.021] [unix-half] component half INSTALLED from .../unixhalf-ml2029-census...
[19:07:39.672] [wcp] 1 package(s) waiting in Import; installing
[19:07:39.822] [wcp] imported ml2030-stubcensus-native-native type=UnixHalf files=2 links=2
```

`UnixHalf.install()` runs at app launch and picks the newest enabled native
package; the package that `installInboxAtLaunch()` unpacked two seconds later is
correctly the newest one for *next* launch. So a package pushed into `Import`
needs **two** launches: one to install it, the next to use it. Worth knowing
before reading silence as a negative result — this is the same failure mode as
"the probe never ran" being mistaken for "the probe saw nothing".

### 4t. Tooling: AFC refuses a hard-linked log, which is every live log

Pulling `madeira-log.txt` mid-session failed with

```
AfcException: [Errno 1] Opcode: FILE_OPEN failed with status: 1
```

Status 1 ("unknown"), not status 8 ("not found") — the file existed and stated
fine at 5,006,752 bytes. Cause, measured:

| file | nlink | read |
|---|---|---|
| `madeira-log.txt` | 2 | status 1 |
| `madeira-log.prev.txt` | 2 | status 1 |
| `madeira-last-game-log.txt` | 1 | ok |
| rotated `logs/<program>-<stamp>.txt` | 1 | ok |

`LogStore.startSessionLog` hard-links the live log to
`logs/<program>-<stamp>.txt` so a run can be found by name without renaming
anything — which makes the live log nlink 2 for the whole session, and AFC in
this container will not open it. `svc.link` (MAKE_LINK) is refused too (status
15), so the link cannot be recreated from the Mac side.

`tools/local/afc-pull.py` handles it: stat, and when `nlink > 1` find the
redundant name under `logs/` by identical size+mtime and unlink **that** one, so
the name the app writes to survives and the inode becomes readable. Verified on
a real hard-linked log (`madeira-log.prev.txt`, 7,422,139 bytes, link dropped,
read succeeded). `tools/local/device-file.sh` now falls back to it when
`apps pull` fails, which is what makes mid-session log reads possible at all.

### 4r. The next probe: count the whole protected set, not one address

§4q leaves one question, and it is not answerable from the faulting address:
**is `image+0x537099c` the only protected entry still holding its ciphertext, or
is the whole set?**

* All (or nearly all) still `0xEA` → the protector's decrypt pass never ran, and
  the game dies on the first protected call it makes. The search moves to why
  the pass does not run under Wine.
* Only that one still `0xEA` → the pass ran and missed this entry, and the
  question becomes which call was made and why it lands on an encrypted stub.

`[stub-census]` answers it by walking the image's own `.pdata` at run time and
counting function entries whose first byte is still `0xEA` (4,538 at rest, which
`tools/pe/protected-stubs.py` computes offline — an agreeing count is the
probe's self-check). It rides the `[xp]` tick for six samples per session, so the
log shows whether the count *moves*, and it only reads, through
`mach_vm_read_overwrite`.

Two copies exist because the two halves deploy differently:

| where | ships as | state |
|---|---|---|
| `build/ntdll-unix/virtual_ios.c` | `dist/ml2030-stubcensus-native.wcp` | pushed and verified on device by read-back (sha256 `2a82f32f…`) |
| `wine/dlls/ntdll/exception.c` (`7e73ce77`) | next IPA build | built, not deployed |

The PE copy also reports the vectored-handler chain depth and each handler's
answer for `#UD`; the existing `[veh]` probe is gated to
`STATUS_ACCESS_VIOLATION`, so "Unhandled illegal instruction … starting
debugger" could not distinguish *no handler registered* from *handlers
declined*. A Wine `.wcp` cannot replace `ntdll.dll` (see `docs/COMPONENTS.md`),
which is why that half of the probe waits for an IPA.

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

### 4ab. MEASURED — the faulting function is *still ciphertext in the image*, and the protector's own handler declines it

Run 22:42, components `ml2111-nestedexc` (unix half), `FH6-iOS-1.5-fex`, `FH6-iOS-1.5-ntdll-builtin`.
The decisive lines, in order:

```
00e8:err:seh:prepare_exception_arm64ec [rtcs] pre: code=c000001d addr=0000000175F7099C …
00e8:err:seh:madeira_stub_census [stub-census] #1 image=0000000170C00000 |
      129 sampled protected entries: 129 still 0xEA (ciphertext), 0 not |
      fault rva 0x537099c: ea e9 6b e6 14 48 89 7c
00e8:err:seh:call_vectored_handlers [stub-census] illegal instruction at 0000000175F7099C:
      1 vectored handler(s) in the process chain before dispatch
00e8:err:seh:call_vectored_handlers … vectored handler 0000000175FCD858 returned 0
00e8:err:seh:ios_seh_xlate_note [seh-xlate] handler=0000000176AAA3B8 GUEST left in PE space
      (icall -> FEX)  module=L"forzahorizon6.exe"+0x5eaa3b8
00e8:err:seh:call_seh_handlers [unwind-root] ml633 ACCEPTING terminal root frame 7043d50000
      (== stack hi) ControlPc=71f3843d30  — this is the unhandled-exception filter frame
wine: Unhandled illegal instruction at address 0000000175F7099C (thread 00e8) …
00e8:err:process:NtTerminateProcess … exit_code=0xc000001d
```

Three things this settles:

1. **The faulting RVA is ciphertext in the image itself** (`fault rva 0x537099c: ea e9 6b e6 14 48 89 7c`,
   base `0x170C00000`), and 129 of 129 sampled protected entries are still `0xEA`. There is no
   decrypted copy anywhere to execute yet. This is not a stale-copy or sync problem at this point;
   the protector has not decrypted.
2. **The protector's own vectored handler runs and declines** ("returned 0" = continue search).
   So the VEH is not failing to be called — it is choosing not to handle this address. The process
   then unwinds to the image's own unhandled-exception filter and exits `0xC000001D`. Any work on
   exception plumbing (nested-exception delivery, unwind cost, self-setcontext) changes *how*
   this ends, not *whether* the code gets decrypted.
3. **Cross-thread `NtGetContextThread` is refused with `STATUS_ACCESS_DENIED`**, three times, just
   before the fault:

```
[ec-getctx] ml715 #1 handle=00000000000001FC status=c0000022 native_pc=0 is_ec=-1
            -> returned rip=0 rsp=0 flags=0
```

   On Windows that call succeeds **if the handle carries `THREAD_GET_CONTEXT`**, and `c0000022`
   is the server's access check (`get_thread_from_handle( handle, THREAD_GET_CONTEXT )`,
   `wine/server/thread.c`), not a machine/state refusal. So this is only a divergence if the
   protector opened the handle for context access.

   **MEASURED, and it is NOT a divergence.** `NtOpenThread` was wrapped to log the requested
   mask beside the handle it produces (`[ec-openthread]`), and `[ec-getctx]` now prints the
   requested `ContextFlags`. Run 22:54, probe `dist/FH6-iOS-1.6-ntdll-builtin.wcp`:

```
[ec-openthread] #1 status=00000000 access=00000040 -> handle=...0100 tid=008c
... 64 logged opens, ALL access=00000040 ...
[ec-getctx] #1 handle=...01FC status=c0000022 requested=00000000 ...
```

   Every open asks for `0x40` = `THREAD_QUERY_INFORMATION` only; not one asks for `THREAD_GET_CONTEXT`
   (`0x4`). A `GetThreadContext` on such a handle is refused on Windows too, with the same
   status, so Wine is behaving correctly here and there is nothing to fix. The requested
   `ContextFlags` is also **`0`** — no caller in this run asks for any register class at all,
   let alone `CONTEXT_AMD64_DEBUG_REGISTERS`.

   Two consequences, both useful:
   - the x64 debug-register port (§4ab, `dbgregs`) is **correct but dormant** in this title:
     nothing exercises it, so it can neither be the cause nor the cure of the decrypt failure;
   - "the protector probes debug registers and we answer wrong" is **falsified** as a
     hypothesis. That closes the `getctx-access` line of investigation.

Also re-measured in the same session: **`FEX_SMCCHECKS=full` still breaks the launch after 0002**
(`launch-client-error=46` with the key, `=0` without it, same DLL), so the 0002 writable-range
gating did not make the reference's required configuration affordable. `0004` remains the candidate.

Two fixes landed and are deployed:

- **Imported PE builtins are resolved by the loader** (`loader_ios.c`, `builtin_override_pe_file`).
  The app-side `WINEDLLPATH` change never applied to ntdll: `load_ntdll()` and
  `ios_load_child_ec_ntdll()` build the path from `ntdll_dir`/`dll_dir` directly. Log proof:
  `[builtin-override] using .../Components/FH6-iOS-1.5-ntdll-builtin-builtin/pe/arm64ec-windows/ntdll.dll`.
- **A nested exception on the signal stack is delivered there instead of `abort_thread(1)`**
  (`virtual_ios.c`, `virtual_setup_exception`), matching the reference's "no longer kills the
  process". Untriggered in this run (`nested exception` count 0), so it is deployed but unproven.

---

### 4ac. MEASURED — a component unix half kills the session, and the reason is that the *static* copy still runs

This is a platform defect, not an FH6 finding, and it was blocking every probe that
ships as a component. Recorded first because it cost this session's opening hour.

**The failure.** With any component unix half enabled, every dock launch printed:

```
[srv-wfail] #1 tid=0000 errno=9 request_fd=0 fcntl(F_GETFD)=0 fcntl_errno=9
            sections=0 abortflag=0 peb=0x0 treat_ebadf_as_epipe=0 rev=ml1382
wine client error:0: write: Bad file descriptor
err:thread:abort_process abort_process: status=0x1 — tearing down this pseudo-process only
[madeira-dock] session ended without a host result
```

`request_fd=0` is stdin. `tid=0000` and `peb=0x0` mean the caller has no TEB. So a
thread that is not a Wine client wrote to the wineserver, and the protocol-error path
took the whole pseudo-process down. With no component enabled the same launch is clean.

**Why it is the static copy.** The probe was rebuilt with a changed marker
(`rev=ml2122`) and pushed into the component slot (`Components/ml2120-srvbt-native-native/
files/libntdll_unix.dylib`, verified read-back). The run still printed `rev=ml1382`,
and the new `[srv-wfail-bt]` backtrace never appeared. That is conclusive: the code
executing this path is the copy linked into the app binary, not the component. UnixHalf
redirects the work, but the app still holds direct references into the statically linked
half — and that copy's `server_request_fd` is never initialised once a component owns
the real connection, so the first such call writes to fd 0.

**Working configuration until the app-side fix lands** (measured this turn):

```
env.MADEIRA_SRV_CLOSED_IS_EPIPE = 1     # spurious EBADF ends a thread, not the process
env.MADEIRA_WAIT_CHILDREN = 1           # session outlives explorer while the game runs
```

With both: the dock host started, `forzahorizon6.exe` spawned at `t+8.043s`, and the
game reached its documented fault while the session stayed up. Without them the game
either never spawned or the session was torn down at ~11 s with
`the main process exited while 5 child process(es) it started still run`.

The real fix is app-side: those direct references must go through the component's
dispatch table like the rest of UnixHalf. Until then, **a component half is only usable
with the two keys above**, and that caveat belongs in every future probe run.

**Separate collateral damage — and its correction.** At first, `FH6-iOS-1.6-ntdll-builtin`
(the PE `ntdll.dll` override carrying the 0002 patches and the `[ec-openthread]` probes)
appeared to break the dock on its own: with it enabled `[builtin-override] using
.../FH6-iOS-1.6-ntdll-builtin-builtin/pe/arm64ec-windows/ntdll.dll` appeared and the
session died before the game spawned. **That was that artifact, not PE overrides in
general.** A rebuilt override (`FH6-iOS-1.7-veh`) is loaded through the same path
(`[builtin-override] using .../FH6-iOS-1.7-veh-builtin-builtin/pe/arm64ec-windows/ntdll.dll`)
and the same run reports `host finished (result 0)` and spawns the game at `t+6.14s`.
So the 1.6 DLL should be treated as a bad build, not as evidence against the mechanism.

Two practical notes about placing an override by hand: the loader looks for
`Components/<id>/pe/<machine>/<dll>`, which is what the installer *materialises* from a
package's layout, so copying only `files/lib/wine/...` silently does nothing; and a
layout whose `dest` has no `${...}` token is counted as `failed` by the link pass
(`[wcp] ... 1 failed`) while still working for the override, because the override and
the system32 symlink farm are two different consumers of the same layout.

### 4ad. Four hypotheses falsified this turn (do not re-run these)

Measured on the clean stock run that reproduced `0xC000001D` at `image+0x537099c`:

1. **"The 16MB RWX arena is a staging copy of the image and the copy-back failed."**
   `[arena-needle] stub@0x537099c = ea e9 6b e6 14; scanning 16.0MB arena for it` →
   `NOT FOUND: the arena is not a copy of the image around the faulting stub`.
   `[arena-content] … 0xEA in arena[0,4K)=11 of 4096 (ciphertext ~16, code ~0) | arena==image:NO`.
   The arena holds high-entropy data that is neither image bytes nor guest code.
2. **"The arena hunt's 28,416 refusals are the input to the decrypt decision."**
   This run refused **13** hinted allocations (`STAGE=none err=3` ×12, `err=1` ×1) and the
   arena was granted, with a byte-identical fault. The hunt's length follows the pool
   layout, not the protector's decision.
3. **"The protector's decryptor is a TLS callback we skip."** It runs:
   `[tls-life] ml704 RUN callbacks module=000000016C2A0000 reason=1 count=2
   first=0000000172694588`. That address is rva `0x63f4588`, matching the PE TLS
   directory exactly (below), and `reason=2`/`reason=3` follow for thread attach/detach.
4. **"The arena is the protector's."** It is a guest `NtAllocateVirtualMemory`
   (`type=0x3000 prot=0x40`, `req_addr=0x178663000 size=0x1001000`) that FEX then marks as
   code (`Add SMC interval`), and we downgrade to `rw-` (`[guest-rwx] … applying rw- instead`).
   That downgrade was already falsified as a fix; the point here is that the buffer is
   ordinary guest memory, so its contents describe the guest's own unpacking, not ours.

**Offline PE facts about `Reference/forzahorizon6.exe`** (cheap, reusable, no device):

```
ImageBase 0x140000000  entry 0x5a66394  .text rva 0x1000 vs 0x639ace3
TLS dir rva 0x7756180 size 0x28, AddressOfCallBacks rva 0x63f4588
callback[0] rva 0x5a658c0  (83 fa 02 75 … = cmp edx,2; jne)  plaintext
callback[1] rva 0x5a65e98  (48 8b c4 …)                       plaintext
```
So the protected range and the protector's own scaffolding are in the same section, and
the scaffolding is not encrypted. Whatever was supposed to decrypt `0x537099c` was
supposed to run before the first call into it.

**Build trap, hit again (the script exists for this):** `build/ntdll-unix/build.sh` builds
only the static archive. The `.dylib` a component ships comes from `build-dylib.sh`, and
packaging without it ships the *previous* build silently — the first `[srv-wfail-bt]`
attempt did exactly that (dylib timestamp 00:53, source edited 01:28, probe string absent
from the artifact). Always use `tools/local/build-half.sh <version> <desc>`; it refuses a
dylib older than its newest source.

### 4ae. MEASURED LIVE — the vectored handler is called with correct inputs and returns 0

The claim "the protector's VEH declines the #UD" had been carried over from a build that
no longer exists: the `[veh-add]`/`[veh-chain]` probes are **not in the current tree**, and
`call_vectored_handlers` only logged `STATUS_ACCESS_VIOLATION`, so `0xC000001D` was invisible.
Rebuilt with both fixed (`wine/dlls/ntdll/exception.c`, probes widened to
`STATUS_ILLEGAL_INSTRUCTION` and the registration logged), shipped as
`FH6-iOS-1.7-veh-builtin.wcp`, and reproduced on the phone:

```
00e4:err:seh:add_vectored_handler [veh-add] func=000000013736D858 first=1
00e4:err:seh:call_vectored_handlers [veh] calling handler 000000013736D858 code=c000001d
      addr=000000013731099C nparams=0 info0=0 info1=0 ctx=00000070417DF4… Rsp=00000070417DFE08
      Rip=000000013731099C
00e4:err:seh:call_vectored_handlers [veh] handler 000000013736D858 RETURNED 0 code=c000001d
      addr=000000013731099C Rsp=… Rip=000000013731099C
```

Read this carefully, because it closes a whole family of hypotheses:

- exactly **one** handler is registered, `first=1` (exception chain, not the continue chain);
- it is called for the real `#UD`, with `ExceptionAddress` **and** `ContextRecord->Rip`
  both equal to the faulting protected RVA (`base + 0x537099c`, base `0x131FA0000` here);
- `NumberOfParameters=0`, matching Windows' `#UD` (so no parameter mismatch to fix);
- it returns **0 = EXCEPTION_CONTINUE_SEARCH** with `Rip` and `Rsp` untouched.

So the handler is not being starved, mis-addressed, or handed a wrong context: it is asked
to handle exactly this fault and declines. Combined with `§4ab` (the bytes are still
ciphertext at the fault) this says the protector does not decrypt lazily through this
path. Any future work on exception plumbing — nested delivery, unwind cost, context
fidelity — changes *how* this ends, not whether the code gets decrypted.

### 4af. The 16MB buffer holds ciphertext-like data, measured against real `.text`

`§4ad` showed the buffer is not image bytes. It is also not decrypted code, by a calibrated
byte statistic on the shipped `Reference/forzahorizon6.exe` (4MB samples):

| sample | 0x00 | 0xCC | 0x48 | 0xEA |
|---|---|---|---|---|
| plaintext `.text` (first 4MB) | 5.85% | 8.33% | 8.16% | 0.093% |
| an "encrypted island" (0x7f0000, 4MB) | 1.80% | 3.36% | 3.44% | 0.299% |
| the 16MB buffer `[0,4K)` on device | — | — | — | **0.269%** |

The buffer's `0xEA` rate sits with the encrypted islands, not with code, so "the decryptor
wrote plaintext into the buffer and we failed to copy it back" is not supported either:
the buffer is input to a decrypt step that never runs.

**And it is not a copy of `.text`, measured three ways** (`[arena-sig]`, ml2124, 32-byte
signatures, 16MB pass each):

```
[arena-needle] stub@0x537099c = ea e9 6b e6 14 … NOT FOUND
[arena-sig] rva=0x7f0010  NOT FOUND in the arena     (inside an encrypted island)
[arena-sig] rva=0x537099c NOT FOUND in the arena     (the faulting stub)
[arena-sig] rva=0x1b22670 NOT FOUND in the arena     (encrypted body, non-0xEA start)
```

So the workspace is not "`.text` moved elsewhere to be decrypted", and not "`.text` copied
to be written back". It holds the protector's own payload. The decrypt-in-place never
begins, and the payload in the workspace is not the reason — nothing in the workspace
corresponds to the code that faults.

About **5.8% of `.text` (92 of 1594 64KB blocks, 0x00 < 0.4%) looks encrypted**. That also
means the `[stub-census]` set — functions whose *first byte* is `0xEA` — is not the whole
protected range: `rva 0x1b226ca` and `rva 0x3cbeb92` sit inside functions starting
`b0 75 3b` / `5a f4 40` and are themselves high-entropy. Do not treat "all 4538 entry bytes
unchanged" as "no byte of `.text` changed".

### 4ag. CORRECTED — the `.text` divergence was in the POOL, not the guest; the guest never wrote `.text`

The `ml2039` probe printed **only the differing bytes**, which for a 1-byte run is a single
byte. That is not enough to say which side of the comparison changed, and I read the result
the wrong way round. `[text-sync] ml2127` prints 24 bytes *from the run start* on both
sides, and in the same event (`differ=10`, protect-to-exec, image `0x170a41000`,
`region=0x639b000 off=0x1000`) the six runs are:

| image RVA | guest view | pool copy | file |
|---|---|---|---|
| `0x5a08e9` | `44` | `84` | `44` |
| `0x5a08eb` | `78` | `5b` | `78` |
| `0x1661999` | `c6 87 78` | `06 88 5b` | `c6 87 78` |
| `0x1fcfb49` | `c6 81 78` | `06 82 5b` | `c6 81 78` |
| `0x4b8f649` | `80` | `c0` | `80` |
| `0x4b8f64b` | `7a` | `5d` | `7a` |

**The guest view equals the file in all six runs.** The pool copy — the one FEX executes —
is the side that differs. So:

- The guest did **not** write `.text` here. There is no measured guest `.text` write in
  FH6 at all.
- The RVAs previously published (`0x1b226ca`, `0x3cbeb92`) were also wrong: the region
  base was applied twice. The correct offsets are the ones in the table.
- The 10 bytes are a **pool-side** difference. What writes them is not identified; they
  did not recur in the `ml2127` run (`differ=0` for the same protect event), so they are
  not a fixed property of the image.

Consequence: the "guest edits `.text`, the pool never gets it" fidelity bug is **not
measured**. The diff-apply fix described here is still reasonable in principle (two copies
of one module is a real divergence), but nothing observed so far needs it, and the 104MB
whole-`.text` baseline it implies is not worth building on this evidence. Retire it as a
lead; keep it only if a guest write is ever actually caught.

---

### 4ah. MEASURED — the protector DOES unlock `.text`, then writes nothing; and two copies of the unix half run at once

The `[prot-img]` line for the game's own code:

```
[prot-img] #45 tid=00e4 0x16c491000+0x639b000 (rva 0x1000) new_prot=0x4 old=0x20 status=0
           | rva 0x1000, section #0 '.text' rva 0x1000+0x639ace3 chars 0x60000020 (R-X CODE)
```

`0x20` is `PAGE_EXECUTE_READ` and `0x4` is **`PAGE_READWRITE`** (my earlier note in this
document said 0x4 was read-only; it is not — `0x2` is). So the protector does the first
step of an in-place decrypt: it takes the entire 104MB `.text` from execute-read to
**read-write, dropping execute**, exactly as `[prot-img]` #48 does for `.pdata`
(`0x2` → `0x4`). Then:

- **No later protect on that range.** #45 is the only event for `0x16c491000+0x639b000`;
  `.text` is left read-write and non-executable for the rest of the run.
- **Nothing is written.** The census samples the watched set three times —
  `t=5.0s`, `t=7.4s`, `t=9.8s` — and every time reports `image=4538 pool=4538` entries
  still `0xEA`, with the sampled entry (`rva=0x1500`) byte-identical in both copies.
  So the unlock happens and the decrypt does not.

Timeline for this run (single session: one `Wine exited`, one `Invalid instruction`):

| t | event |
|---|---|
| 4.5 s | `.text` RX → RW, `.pdata` R → RW (`prot-img` #45, #48) |
| 5.0 s | census arms; 4538/4538 still ciphertext in both copies |
| 5.0 s | **static** half's server write fails: `[srv-wfail] errno=9 request_fd=0 … peb=0x0 treat_ebadf_as_epipe=1` → `abort_process(0)`; the Wine main process exits and orphans 5 children (incl. `forzahorizon6.exe`) |
| 5.0–8.5 s | FH6 keeps running hard — `cpu=1143`, `cpu=333` per 300ms sample, IPC 5–6 |
| 8.5 s | first call into `0x537099c` → `#UD`; VEH returns 0; exit `0xC000001D` |

So the teardown did **not** stop the game: it kept executing for another 3.5 s. The `#UD`
is not "the protector died with the parent".

**Two copies of the unix half run in one process — proven, not inferred.** In this single
session the log contains both:

```
[stub-census] ml2126 not enabled (set MADEIRA_STUB_CENSUS=1); no samples this run
[stub-census] v2 armed at t=5.0s: image=0x16c490000 pool=0x1263a8000 …
```

`ml2126` is the component I installed, whose census is gated off. `v2 armed` can only be
printed by `ios_stub_census_thread_start`, which has exactly one starter
(`ios_stub_census_ensure` → `pthread_once`). One `pthread_once` cannot both return early
and start the thread, so these lines come from **two loaded copies**: the component, and
the half statically linked into the app (an older build, census still always-on).

That is the `comp-half-fix` defect (§4ac) seen directly rather than through its symptom.
It is no longer only a cleanliness issue: **probe output cannot be attributed to a build**
while both copies print, and a fix shipped in a `.wcp` is only half-applied. Any future
measurement that depends on a half-side gate must either eliminate the static copy or
prove which one answered.

---

### 4ai. Objective item 4 — the divergences this work introduced, each with its evidence

Audited against the clean-room baseline `0beaf14` ("stock Madeira + WCP import +
picker"), filtering logging out of the diff so only behaviour remains. Ten source files
changed, 1,420 insertions. This is the list that matters when something *other* than FH6
breaks, as `dockhost.exe` already did once.

| # | divergence | path | default | status |
|---|---|---|---|---|
| 1 | census sampler: detached thread, reads other images' memory, started for every session | `virtual_ios.c` | **was on** | **FIXED** — now `MADEIRA_STUB_CENSUS=1`; prints one line when off. Caveat: the app's static half still runs its older always-on build (§4ah) |
| 2 | `[map-name]`: a wineserver round trip + `fcntl` per builtin image, on the loader path, only to log | `virtual_ios.c` | **was on** | **FIXED** — now `MADEIRA_MAP_NAME=1` |
| 3 | nested exception delivered on the signal stack instead of `abort_thread(1)` | `virtual_ios.c` | **on** | **DOCUMENTED, active** — changes exception delivery for every process, not just FH6. Was `abort_thread(1)` at baseline. Needs an A/B on a non-FH6 title before it is trusted |
| 4 | `[pool-caller]`: six `dladdr` calls per image map | `virtual_ios.c` | on | documented; logging only, no behaviour. Cheap enough to leave |
| 5 | `[store-noalias]` wording: requires the region to cover the address, and names the FAR-echo case | `signal_arm64_ios.c` | on | documented; logging only, and it fixed a probe that had sent a session after a non-existent memory fault |
| 6 | failed server write treated as EPIPE | `server_ios.c` | **off** | env-gated (`MADEIRA_SRV_CLOSED_IS_EPIPE`); baseline behaviour preserved without it |
| 7 | guest `PROT_EXEC` honoured on anonymous RWX | `virtual_ios.c` | **off** | env-gated (`MADEIRA_GUEST_RWX_EXEC`); the RX-strip is baseline behaviour, so not a divergence by default |
| 8 | unix half loaded from a `.wcp` instead of the linked archive | `UnixHalf.swift`, `WineProcessBridge.m` | on | **DOCUMENTED, active** — start/log/`i386` flag/child table are routed to whichever half runs; the remaining direct references are `comp-half-fix`, and §4ah proves both halves run at once |
| 9 | JIT pool claimed at app start, so a game-specific `pool=` may be ignored under LiveContainer | `ContentView.swift`, `StikJITHelper.swift` | on | **DOCUMENTED, active** — a real semantic change; the log says which pool was used |
| 10 | `[[maybe_unused]]` `files/` components skipped in the link count | `WineProcessBridge.m` | on | documented; prevents a native component being reported as a failed link |

Nothing else in the half or the app changes behaviour by default: the other probes are
`dprintf`/`ERR` only. The two that were genuinely risky (#1, #2) are now opt-in on the
component side; #3, #8 and #9 remain active and are the ones to watch if a non-FH6 title
regresses.

### 4aj. DroidDeck port status, and two probes that had to be retracted

The north star is the reference implementation, so the question "what has actually been
ported from it" deserves a table rather than an impression. A port counts as *in* only if
the change is in this tree and something has exercised it.

| reference change | where it lands here | in tree? | exercised? |
|---|---|---|---|
| import-thunk hotpatch prologues (`8b ff 55 8b ec 5d`, `48 8d a4 24 …`, `ff 25`) | `build/wine-patches/0001`, rewrites `winebuild` output; applied at `wine/tools/winebuild/spec32.c:264,603,613` | **yes** | **no effect on this fault** — the fault is byte-identical with it applied |
| x64 debug-register round trip | `build/wine-patches/0002` (`signal_arm64ec.c:44,1851`) + `build/fex-patches/0002` | **yes** | **DORMANT, measured** — every `NtOpenThread` asks `0x40` only and every failing `NtGetContextThread` passes `ContextFlags=0`, so the code never runs (§4ad) |
| nested exception on the signal stack instead of `abort_thread(1)` | `virtual_ios.c:30034`, shipped as `ml2111-nestedexc` | **yes** | **never hit** — branch count 0 across the run that was meant to test it |
| SMC traps per 16K host page | `build/fex-patches/0001` | **yes** | yes, as the FEX half of §4ac |
| block-level SMC validation gated on writable code | `build/fex-patches/0002` (partial port of ref 0002/0004) | **yes** | yes — this is what makes `FEX_SMCCHECKS=full` stop returning launch-client-error 46; the full result is still a *different* failure, not a boot |
| `FEX_POOL_CLONE` (ref 1.2 headline, `libarm64ecfex-poolclone.dll`) | — | **no** | 0 occurrences in `Config.json.in`; 4 in the reference's `0004` patch |
| `FEX_FH6_FASTUD`, `FEX_FH6_SPINSAMPLE`, `FEX_FH6_STATS` | — | **no** | 0 occurrences anywhere in `FEX/`; they exist only in ref `0004` |
| `FEX_DISKCACHEMAXFILESIZE` | — | **no** | absent from the schema |
| hide FEX from file/module queries | — | **no, deliberately last** | the reference itself records that this went in *before* its root cause was found and may be unnecessary; test by removal if ever added |
| cross-thread debug-register lookup | — | **no** | logged, never answered |

Two things follow, and neither is comfortable:

1. **The reference's load-bearing pieces are the ones we do not have.** Its own README says
   FH6 gets through "with no checks disabled" because the FEX package makes
   `FEX_SMCCHECKS=full` cheap (block invalidation plus a 255-byte chunk CRC) *and* the Wine
   thunks stop looking hooked. We have the Wine half and a partial FEX half. The pool-clone
   and `FEX_FH6_*` work is absent. Our 0002 is per-instruction gated validation, not the
   reference's chunk CRC.
2. **Every ported change targets a verdict class the reference names** — hooked imports,
   hypervisor bit, SMC churn, debug registers. Our fault is in none of those classes: a
   ciphertext `.text` is unlocked to RW, never written, and then executed (§4ah). Porting
   more reference material cannot decrypt it unless one of those knobs happens to gate the
   decryptor, and the one lever we did test (`FEX_SMCCHECKS=full`) changed the failure
   without reaching a window.

**Two retractions, so nobody inherits them:**

- `[guest-stk] ml2129` read the CHPE guest context at `CPUArea+0x50` and got `rip=0 rsp=0`
  for the very thread that performs the unlock. The guest CONTEXT chain is **not** populated
  on this path; do not use it here.
- `[guest-stk] ml2130` then read the ARM64 syscall frame (`TEB+0x378`, `x29@+0xe8`) and
  printed frames labelled `ntdll.dll+0x5d9b8` and friends. **Those labels are not
  trustworthy.** The values sit in FEX's JIT/pool domain, not in ntdll's image (its pool
  starts at `0x11a9dc000`), so the ARM-level stack does not carry the guest's x64 return
  addresses at all. The unlocker has **not** been named. That is why the probe moved to the
  Wine PE side, where FEX packs the guest state into the ARM64EC context it hands to ntdll:
  `prepare_exception_arm64ec()` has `arm_ctx->Pc`, which `dispatch_syscall()` already treats
  as the guest return address. `[syscall-rip] ml2131` logs it when it lands inside the main
  image (`MADEIRA_SYSCALL_RIP=1`, 3000 lines). First run: zero lines, ambiguous — a missing
  line could mean "path not reached" or "gate off". An unconditional bounded entry marker
  was added to separate those two, and the follow-up run aborted before reporting. **No
  result yet.**

### 4ak. The reference's root cause is REAL and the app ships the broken copy

Asked directly "does the DroidDeck code hide FEX from file/module queries?", so here is
what the reference actually contains, checked rather than remembered, plus what the check
turned up.

**The hide-FEX question, answered from the reference's own transcript** (the handoff store,
`fh6-transcript.jsonl`):

- It *was* implemented. The reference agent built it: FEX off the PEB loader lists, plus
  "file lookups for the FEX DLL say not found, and memory queries for its mapping don't
  reveal its file name".
- It was **measured not to help**: *"hiding FEX from the module list and from file-name
  lookups didn't change that"* (the punishments kept firing).
- It **caused a boot regression**: removing FEX from the address-to-module lookups broke
  exception dispatch, because that map is how an address is resolved to a module during
  unwinding. The reference pulled it back to "the module lists that a module walk reads",
  leaving FEX visible to address and name lookups, and fixed the boot.
- The reference's own note: it went in *before* the real cause was found and may be
  unnecessary. So `hidefex` stays where it was: last, and only if something new points at it.
- None of the reference's four FEX patches or two Wine patches hide FEX. The single
  `NtQueryVirtualMemory` in the 0004 patch is a `NtTerminateProcess` stack dump, not a mask.

**What the reference says the real cause was, and the check that followed.** Its README is
explicit: *"Forza's anti-tamper checks the first bytes of exported Windows functions. Native
Windows, and Wine on x86_64, start those import thunks with a standard 8-byte hotpatch
prologue. Wine on ARM64EC used to emit a bare `jmp` instead, so the game decided its imports
were hooked."* DroidDeck-Proton 11-12.3 ships kernel32 with 797 fixed thunks.

We ported that (`build/wine-patches/0001`) and it is in the **build tree**: the freshly built
`wine/build-arm64ec/dlls/kernel32/arm64ec-windows/kernel32.dll` measures **796 hotpatch
thunks, 0 bare `ff 25`**.

But the **shipped** copy does not have it. Bytes, from the same checker:

| artifact | hotpatch prologues | bare `ff 25` |
|---|---|---|
| `wine/build-arm64ec/.../kernel32.dll` (built) | **796** | 0 |
| `.runtime-cache/windows/files/arm64ec-windows/kernel32.dll` (staged) | **0** | **796** |
| `app/Madeira/arm64ec-windows/kernel32.dll` (bundle) | **0** | **796** |
| `app/DerivedData/.../Madeira.app/arm64ec-windows/kernel32.dll` (installed) | **0** | **796** |
| `Components/FH6-iOS-1.7-kernel32/pe/.../kernel32.dll` (override, **never enabled**) | **795** | 0 |

`tools/build/runtime-components.py:stage()` copies from `.runtime-cache/<name>/files/` into
`app/Madeira/`, so the stale cache is what the phone runs: every import thunk the game binds
to kernel32 is a bare `jmp`, which is precisely the condition the reference says makes the
protector refuse to run. The cache mtime is 21:32, the patched build 23:37 — the cache was
snapshotted before the patch landed and never refreshed.

Other staged modules are bare too: `user32.dll` 206, `advapi32.dll` 200, `kernelbase.dll` 2.
The reference only names kernel32, so kernel32 is the one to test first.

This also dissolves the "0 bare ff 25 thunks among the game's 592 imports" note in the
objective: that measured the *game's own* IAT, not the thunks our builtins point at.

**Two clean negatives measured this turn, so nobody re-runs them:**

- **`NtQueryVirtualMemory` is not on the boot path.** The reference profiled the working game
  and found the protector queries memory *three times per decrypted function* (its "decrypt
  trio"), which made "the decryptor queried, disliked the answer and bailed" the leading
  hypothesis. Measured here with `[query-vm]` (unconditional, self-describing, ml2135): a run
  that reached the `.text` unlock (`prot-img` past #45) contains **exactly one** `[query-vm]`
  process header, for a 112 KB image — i.e. the `dock`/`explorer` process consumes all 300
  samples. The **game process makes zero** `MemoryBasicInformation` queries before the fault.
  The decrypt trio is steady-state gameplay, not a pre-decrypt gate.
- **Debug registers remain dormant.** `[ec-openthread]` still shows every open asking
  `access=0x00000040` (never `THREAD_GET_CONTEXT`, `0x8`) and every failing
  `NtGetContextThread` passing `requested=00000000`. The reference's hardware-breakpoint
  route is not exercised on this path.

**A harness defect that made several of these ambiguous.** At one point **six** `UnixHalf`
components were enabled at once (`ml2132`, `ml2133`, `ml2134`, `ml2130`, `ml2120`, plus the
PE builtin): each half installs the same `libntdll_unix.dylib` symbols, each prints its own
probe lines, and `--no-install` meant some freshly built packages were never imported at all
while the counters still came from the app's static half. Two runs of the same probe then
disagreed. Fixed in the harness, not in a note: `dev-run-fh6.sh` now reduces the enabled
`UnixHalf` set to one after the import step, and says which it kept. `MADEIRA_KEEP_OTHER_HALVES=1`
opts out. The old `build-half.sh` attempt ran before the component existed in `state.json` and
left nothing enabled; that is why the check lives after the import.

---

### 4al. Why the app kept shipping bare `ff 25` thunks: patch 0001 never fired on ARM64EC

§4ak proved the app bundle carried 796 bare `ff 25` import thunks while the build tree was
believed to be fixed. The actual cause was not a stale cache. **Patch 0001's post-link fixup
never ran on any `arm64ec-windows` builtin**, so every build produced the bare thunks and the
"fixed" build tree the earlier session measured must have been hand-patched.

The fixup is `fixup_arm64x_import_thunks()` in `tools/winebuild/spec32.c`. It returned at its
second gate:

```c
if (get_le16( data + nt + 4 ) != IMAGE_FILE_MACHINE_ARM64) return 0;
```
That is the right test for an **ARM64X hybrid** (`aarch64-windows`), whose x64 export view is
reached through ARM64X dynamic relocations. Every `arm64ec-windows` builtin is a **pure ARM64EC**
image instead: machine `0x8664`, one ordinary export directory, no CHPE code map to consult and
no ARM64X relocations. Measured on `dlls/kernel32/arm64ec-windows/kernel32.dll`:

```
machine=0x8664 nsec=14 nb_dirs=16 loadcfg_rva=0x526f8   exp_rva=0x56a40  nfuncs=1358
func[2] rva=0x350c0  ff 25 3a af 01 00 00 00 00 00 00 00   <- bare, exactly as shipped
```

Confirmed by instrumenting the fixup and relinking: it was entered, and returned before the
thunk loop because of that gate.

**Fix (committed `c168c39`):** accept both machines. For a pure ARM64EC image use the regular
export directory and treat every 16-byte-aligned export slot as x64 thunk code. The existing
per-thunk validation still applies (slot must be `ff 25`, the padding must be uniform, the
relative target must land inside the IAT and be 8-byte aligned), so nothing but import thunks
is rewritten. Measured immediately after a clean rebuild:

```
before: kernel32.dll  hotpatch=0   bare-ff25=796 other=562
after:  kernel32.dll  hotpatch=796 bare-ff25=0   other=562
```

No manual patch, no cache refresh: `build.sh` now produces prologue-bearing builtins.

**The fault is unchanged with the fixed DLL loaded.** Pushed the patched, stripped `kernel32.dll`
(795 hotpatch, 0 bare) onto the device and ran a full session: the game spawns, and dies at
**`Invalid instruction in entry block: 17547099C`** — same low 12 bits as the documented
`image+0x537099c`. So the DroidDeck import-thunk-prologue root cause is now **falsified on this
fault on-device**, not merely by static analysis. It remains a genuine Windows-fidelity fix.

### 4am. CORRECTED — `kernel32.dll` CAN ship in a `.wcp`; the farm was wrong

An earlier note here said a `.wcp` could not carry `kernel32.dll` and blamed the
`WINEDLLPATH` override. That diagnosis was **wrong** and is retracted. The real cause was
the package landing the file in the **wrong architecture farm**, and the real channel —
which needs no app change at all — works.

Every symptom blamed on the DLL or on `WINEDLLPATH` reproduces with the **byte-identical**
`kernel32.dll` copied out of the app bundle (`sha256 5866094b…` on both sides), which rules
out the bytes and rules in placement.

What this session actually shows (session routing line, logged by the bridge):

```
[WineProc] PE routing: machine=0xaa64 bundle=aarch64-windows i386-set=1 force-ec=0
[WineProc] Symlinked 147 DLLs from aarch64-windows -> sys32
[WineProc] Farm sysx64:  422 links -> arm64ec-windows
[WineProc] Farm sysaa64: 147 links -> aarch64-windows
```

The launcher process is **aarch64**, so *its* binaries own `system32` and the ARM64EC set
lives in `sysx64`. A `Wine`-kind package whose source path contains `arm64ec-windows` was
mapped to `${system32}`, overwriting the aarch64 `kernel32.dll` the launcher needs:

```
err:module:load_dll [dll-missing] L"kernel32.dll" status=c000007b
[child-census] ml2029 session end status=-1073741701   (no `phase] spawn` at all)
```

That is a machine mismatch inside the loader, and it is why the launcher died before it
could ever spawn the game. Pointing the same payload at `${sysx64}` fixes it outright
(`[wcp] 1 links`, no `could not load kernel32`, game spawns and faults at the usual
`…99C`).

**Two changes landed for this:**

- `tools/wcp/make-pe-wcp.sh` — packages PE builtins as kind `Wine` (prefix link) rather
  than kind `Wine-Builtin` (`pe/` + `WINEDLLPATH`). This is the DroidDeck-equivalent
  channel: the component is symlinked over the bundle's copy in the prefix for the session,
  and disabling it re-links the bundle on the next launch. Nothing in the app bundle changes,
  nothing is re-signed, nothing is reinstalled.
- A new `${sysarm64ec}` token (`WCPComponents.swift` + `WineProcessBridge.m`): `sysx64` in an
  aarch64 session, `system32` in an ARM64EC one. `.wine` layout now maps `arm64ec-windows`
  sources through it, so the mistake cannot be made again. **Needs an app rebuild to take
  effect**; until then the farm has to be set in `state.json` by hand (which is how the
  runs above were made).

The `[wcp] N links, M failed` line also stopped counting `.builtin` `pe/` deps as failures —
they are staged for the loader, not linked, so `failed` now means a genuinely broken entry.

### 4an. A patched `kernel32.dll`, once actually loaded, stops the game from launching

With the farm fixed, a patched `kernel32.dll` (795 hotpatch prologues, 0 bare `ff 25`)
really is the DLL the session loads — and the launch changes shape:

| payload in `${sysx64}` | links | game spawns | outcome |
|---|---|---|---|
| none (baseline) | – | yes | `#UD` at `…99C` |
| bundle's own `kernel32.dll` | 1 | yes | `#UD` at `…99C` |
| build `kernel32`, **792** prologues (corruption fixed) | 1 | **no** | dock never authorises |
| build `kernel32`, **134** prologues — only the exports the game actually imports | 1 | **no** | dock never authorises |
| build `kernel32`, 0 prologues but *with* the truncated slot left in | 1 | yes | no `#UD`; idle at 60 s, `P=0.00` |

**The last row is retracted as evidence.** That "bare" file still carried the truncated
prologue (§4ao) at the very last thunk: 5 of its 11 differing bytes were the residue. Its
idle-with-no-fault result was a stack-corrupting export, not a property of unthunked code.
A clean zero-prologue file has not been run yet.

The two middle rows are the useful measurement. Reducing the patch set from 792 exports to
exactly the 134 the game imports (`tools/local/pe-thunks-apply.py`, names parsed out of the
reference EXE's own import table: `KERNEL32.dll`, 173 names, 39 of which are real function
bodies rather than `ff 25` thunks) does **not** restore the launch. So the dock is not reacting
to some incidental export; it stops authorising as soon as its own dependency set carries
prologues. The same `kernel32` containing 134 prologues still lets `services.exe` and
`rpcss.exe` start, so this is specific to the Steam launch flow rather than to the file.

`[wcp] 1 links` and `[main-exe] find_dll_file mixed-arch fallback: kernel32.dll ->
\??\C:\windows\sysx64\kernel32.dll` confirm it is the overridden DLL that loads, and the
baseline control was re-run immediately before these (§4am) so device drift is excluded.

What this changes: the reference's fix cannot be validated here by patching **all** exports.
The next experiment is a bisection over *which* exports may carry a prologue, not a broader
port — and the honest prior is that the set is small or empty, because a prologue is
semantically a no-op (`lea rsp,[rsp+0]` then the same `jmp [rip+rel]`, verified for all 792:
inside the IAT, 8-byte aligned, and no other export RVA inside any rewritten 16-byte slot).

One measurement is genuinely new regardless of the bisection: this is the **first time a
patched `kernel32.dll` has actually been loaded by a session** (§4am explains why every
earlier one was ignored). Every previous "fault unchanged with the hotpatch kernel32" result
was measured without the DLL loaded and is unmeasured, not falsified.

**This is a shipping blocker, not just an experiment.** `runtime-components.py build windows`
runs with patch `0001` applied, so it writes 792 prologues into
`app/Madeira/arm64ec-windows/kernel32.dll` — the exact file that becomes `sysx64/kernel32.dll`
at prefix setup. A rebuilt component therefore produces an app whose Steam dock cannot launch
any game. Caught by rebuilding the component (verify then passed) and measuring the artifact
instead of trusting the build: 795 prologues reported by `pe-thunks.py` where the shipped file
had 0. The artifact has been reverted to its bare form, and `build/wine-patches/README.md`
carries the warning. `kernel32` is the only builtin the patch touches — `ntdll` and
`kernelbase` have no `ff 25` import thunks — so patch `0001` is, today, exactly the change that
breaks the dock and nothing else.

**Run-to-run variance, measured — do not read it as signal.** Two runs of the *same*
unmodified baseline (no links, bundle `kernel32`) produced different post-spawn outcomes:

| baseline run | game spawns | after spawn |
|---|---|---|
| control earlier in this session | yes | `#UD` at `…99C` |
| final verification, minutes later | yes | no `#UD`; `.text` unlocked once; still running at 60 s, `P=0.00` |

So "the game spawns but never faults" is **baseline noise, not a kernel32 or prologue
signature**, and any earlier conclusion that read it as one needs revisiting. The robust
signal is only the binary one — *does the game process spawn at all*: 5/5 blocked with
prologues in `sysx64`, 4/4 spawned without them. Everything downstream of the spawn must be
replicated before it is believed.



### 4ao. FIXED — a prologue written past `VirtualSize` is silently corrupted by `llvm-strip`

This is the bug behind every "the DLL is nearly byte-identical but behaves completely
differently" surprise above, and it would have shipped in the next app build.

`fixup_arm64x_import_thunks` writes a 16-byte hotpatch slot (`lea rsp,[rsp+0]` + `jmp [rip+rel]`
+ 2 padding bytes) at an export's RVA. It validated the write with `pe_rva_ptr()`, which bounds
against the section's **`SizeOfRawData`** — the file-padded size. The **last** import thunk in
`kernel32.dll` sits flush against the end of `.text`, so its slot is 6 real bytes
(`ff 25 rel32`) followed by file padding:

```
bundle    037a30  ff 25 da 9e 01 00 cc cc ...
build     037a30  48 8d a4 24 00 00 00 00 ff 25 d2 9e 01 00 00 00
```

`.text` has `VirtualSize 0x27a36`, so the section ends at RVA `0x37a36`. The prologue is
written into padding that is not part of the mapped section. Harmless — until something
rewrites the image by section size, which is exactly what every `.wcp` DLL goes through:

```
$ xcrun llvm-strip --strip-debug kernel32.dll
037a30  48 8d a4 24 00 00 cc cc cc cc cc cc cc cc cc cc
```

The prologue is cut to its first 6 bytes; those plus the `cc` padding decode as
`lea rsp,[rsp+0xcccc0000]`, an export that destroys the stack the moment anything calls it —
in a DLL that otherwise measures "792 hotpatch prologues, 0 bare `ff 25`" and looks perfect.
Section file-pointers are identical before and after stripping, so this is a real content
change, not an offset shift (verified via each file's own section table).

Measured, deterministic run to run:

| file | prologues before strip | after strip |
|---|---|---|
| before the fix | 793 | 792 + one truncated slot |
| after the fix | 792 | 792, last thunk correctly left bare |

**Fix** (`build/wine-patches/0001`): `pe_rva_in_virtual_size()` plus a guard requiring the
whole 16-byte slot to be inside `VirtualSize`, not just the file data. The last thunk keeps its
bare `ff 25` — which native Windows also has when a slot abuts the section end.

Consequences worth keeping:

- **Never trust "the bytes are identical" as a control** unless the comparison is at RVA level
  using each file's own section table *and* both files went through the same post-processing.
  The 11-byte diff above was 6 timestamp bytes plus this 5-byte residue, and that residue is
  what made the "zero-prologue" control idle instead of faulting.
- Only a prologue can trigger it, so the app's shipped `kernel32` was never affected (bare
  thunks). The next rebuild would have been.
- Tooling: `pe-thunks.py` counts, `pe-thunks-apply.py` writes a named subset with the same
  `VirtualSize` rule, `pe-unthunk.py` reverses. `tools/wcp/make-pe-wcp.sh` packages PE
  builtins as prefix links (kind `Wine`) instead of `pe/` staging.

---

## 5. Premise corrections


The objective carries "established facts" that no longer match measurement. They
are listed here so the next session does not pursue the objective from a
falsified starting point.

1. **"The binary cannot register a vectored exception handler by any name;
   `[veh-chain] EMPTY` is the only possible state."** Now measured directly on
   the current build (§4ae): exactly one handler is registered and it *is* called
   for the `#UD` with the correct address and `Rip`, then returns 0. The claim is
   falsified — and so is its converse ("a skipped or mis-addressed handler is the
   problem"), because the handler receives everything it needs and declines.
2. **"The `FEX_*` environment preset changes nothing."** See §3 — it does, and
   one key in it was blocking the launch outright.
3. **"Dies within ~1 s."** Now ~6 s of real execution (`t+7.633s` spawn,
   `+13.86` at the fault). The longer life is a consequence of §3, not of the
   fault changing.
4. **"The arena hunt rejects 28,416 consecutive hinted VirtualAllocs (~1GB) — the
   single most Windows-unlike input."** Re-measured on a stock run: **13** refusals,
   arena granted, byte-identical fault (§4ad item 2). The count tracks the pool
   layout, so it is a symptom to correlate, not a decision input.
5. **"The protector allocates a 16MB+64KB RWX arena"** is true but not protective
   machinery: it is a plain guest `NtAllocateVirtualMemory`, and its contents do not
   match the image (§4ad items 1 and 4). Do not model the decrypt as "copy the arena
   into `.text`".

Still standing and re-confirmed: the faulting bytes are ciphertext at fault time,
and the fault is at `image+0x537099c`.

---

## 6. Next experiments, cheapest first

1. **Catch the guest stack at the moment `.text` is unlocked (§4ah).**
   The decrypt question has narrowed to one moment: `prot-img` #45 takes `.text`
   from `PAGE_EXECUTE_READ` to `PAGE_READWRITE` at t≈4.5 s, and nothing ever
   writes it. So the gate is *upstream of the write*, inside the code that just
   unlocked the section. Walking the guest stack at that protect event names that
   code as guest RVAs, which can then be read offline with
   `tools/local/pe-calltree.py` — no guessing about which `Nt*` it "must" be
   calling. This is strictly cheaper than an API census and it produces the
   actual function.
   Do **not** re-run these: they are closed. `.text` is not written by the guest
   (§4ag), `NtWriteVirtualMemory`/`NtFlushInstructionCache` never touch any image
   (§4ah), the VEH receives and declines the `#UD` (§4ae), and the 16 MB buffer
   holds neither `.text` nor decrypted output (§4af/§4aa).
2. **Attribute the two halves before trusting any probe (§4ah).** One process
   runs the app's static half and the component's half simultaneously, so a gate
   added to a `.wcp` is only half-applied (`ml2126`'s census gate printed both
   "not enabled" and "v2 armed" in one session). Either finish `comp-half-fix`
   (route the app's direct references through the component's dispatch) or, for
   every future measurement, print a per-copy build id so the answering copy is
   known.
3. **Fix the two probe defects in §4a** so a future fault is not mislabelled as
   a wild store. Already written and packaged (`dist/unixhalf-ml2026-native.wcp`);
   needs the phone.
4. **Port the remaining SMC patch, `fh6-fex 0004`, and be precise about what is
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
5. **DroidDeck comparison (north star).** Compare what DroidDeck's FEX does with
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
