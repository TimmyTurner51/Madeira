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

The dock regression in §4au is cleared (§4av). `forzahorizon6.exe` is created
again, and it dies at this same fault.

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
  sources through it, so the mistake cannot be made again. A FEX package had the same
  assumption: `libarm64ecfex.dll` was linked to `${system32}/xtajit64.dll`, and
  `libwow64fex.dll` to `${system32}/xtajit.dll`. Those now use `${sysarm64ec}` and
  `${aarch64}`. **Needs an app rebuild to take effect**; until then the farm has to be
  set in `state.json` by hand (which is how the runs above were made).

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

### 4ap. MEASURED — it is the *number* of prologued exports, and the dock **crashes**

Bisection was expected to find a bad export. It found a **count threshold** instead. Every
set below is a `kernel32.dll` identical to the bundle's except for the named exports' 16-byte
slots, pushed straight over the live component file (`tools/local/k32-bisect.sh`, one launch
per step because no re-import is needed):

| exports prologued | sets tried | verdict |
|---|---|---|
| 1 | `CreateThreadpoolIo` | spawns |
| 8 | two halves of the 17-set | spawns (both) |
| 9, 12 | disjoint slices of the untouched rest | spawns |
| 16 | a slice of the 17-set, a **disjoint** 16, and a **third** disjoint 16 | **blocked (3/3)** |
| 17, 134 | | blocked |

The 16-export blocking sets share almost no names: `{CloseHandle…CreateThreadpoolIo}`,
`{CreateTimerQueue…FlushFileBuffers}`, and `{12 from one end + WideCharToMultiByte,
WriteFile, WerRegister*}`. So the trigger is not *which* export carries a prologue but *how
many do* — the threshold is between 12 and 16, which points at a fixed-size bookkeeping
structure somewhere in our own stack rather than at anything about the functions.

**The dock does not refuse the launch — it crashes.** All three blocked runs contain an
unhandled `c0000005` in `dockhost.exe` tid 0038, and the spawning run contains none. The
fault is `pc=0x0`, `nparams=2`, `p0=8` (execute), i.e. a call through a NULL function
pointer, in a ucrtbase dispatch stub:

```
call_site@(lr-16): a9029be5 f9444d10 f90013e4 d63f0200   ; ... ldr x16,[x8,#imm] ; blr x16
callee:            d10143ff a9047bfd 910103fd d0000288
x8=0x11d25f000  x16=0x0  x9=0x11d2e40c0
[thunk-slot] exec-relative slot @0x11d25e480 = 0x0     ; target was never written
```

`x8+imm` resolves to `0x11d25e480`, inside ucrtbase's pool copy, and it holds `0`.
`[subfloor] DECLINING: pc=0 unreadable` then turns that into an unhandled `c0000005`, and
`NtTerminateProcess exit_code=0xc0000005` ends the dock before it authorises anything. So
this is **our** dispatch metadata being incomplete, not a tamper verdict — squarely inside
the "platform-fidelity bug, pursue aggressively" side of the boundary.

Next: find what fills the ucrtbase exec-relative slot at `+0x480` from the thunk's `adrp`
target and why it is skipped for some exports, and look for a 13–16-entry table in that path
(a fixed-size array is the shape the threshold implies).

### 4aq. The reference's fix is BLOCKED by a known, unlandable landmine — and one test was void

Two results, one of them a methodology trap worth writing down.

**1. The `arm64x_check_call` landmine is what kills the dock.** The crash dump names the
callee directly:

```
call_site@(lr-16): a9029be5 f9444d10 f90013e4 d63f0200   ; ... ldr x16,[x8,#0x898] ; blr x16
callee prologue:   d10143ff a9047bfd 910103fd d0000288
callee[+0x38]=9100c3fd  (LDR x11,[x18,#0x60] should be B-tramp if patched)
__os_arm64x_check_call=0x0 (not set or bad)
```

The instruction that "should be a B-tramp if patched" is exactly the `ldr x11,[x18,#0x60]`
that the `ml246` comment in `signal_arm64ec.c` records as **deliberately wrong and
A/B-proven unlandable**: iOS clobbers `x18`, so the TEB read yields garbage, and the fix that
would make it correct broke CEF for 8 consecutive runs. Prologues in `sysx64/kernel32` drive
`dockhost.exe` into that path once enough thunks need it.

So the reference's stated root-cause fix — give import thunks the hotpatch prologue — is
**not landable on this stack** as things stand. That is a platform finding, not a tamper
verdict, and it means the prologue thread cannot be used to reach the decryptor.

**2. Adding the prologue-skip to `arm64x_check_call` does not prevent it.** A faithful port
was added (`ml260`): if the first 8 bytes are `48 8d a4 24 00 00 00 00`, skip to the `ff 25`
and re-check. It is a no-op for every DLL shipping today (the bundle's `kernel32` is bare),
and it is correct per Windows. Measured with it genuinely loaded (`[builtin-override] using
…1.12-htdisc…` present, 792 prologues): still `pc=0`, still
`callee[+0x38]… should be B-tramp`, still `exit_code=0xc0000005`. So the skip is necessary but
far from sufficient — the failure is in how the *checker* is entered, not in how it
classifies a prologued thunk.

**Methodology trap — a void A/B looks exactly like a valid negative.** One run in this series
(`run-fix16`) enabled the fixed ntdll *without* restarting the app. The override path is
`BuiltinOverrides.cSearchPath()`, cached per process and consulted only on the EC-child load
path (`ios_load_child_ec_ntdll`), so the enabled flag had no effect: the log contained **zero**
`[builtin-override]` lines and the bundle's ntdll ran. Read naively it says "the fix doesn't
work"; in fact it says nothing. **Always grep `[builtin-override] using` before believing any
ntdll A/B**, and restart the app after changing which builtin components are enabled.





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

### 4ar. The dock dies on a NULL exit thunk in the pool copy — partially fixed

The reference Wine (`TimmyTurner51/proton-wine`, branch `fh6`, `dlls/ntdll/signal_arm64ec.c`)
does **not** skip a hotpatch prologue. Its `arm64x_check_call` still matches only `ff 25` and
still reads the TEB from `x18`. That works on Android, where `x18` is the TEB. The same
README says the thunk patch is not required for the in-world result once DroidDeck-Proton
11-12.5 is installed; the FEX package is what gets the game playing. There is no separate
local Wine tree beyond those two patch files in `fh6-wine-fex/wine/`.

Our crash is the iOS pool copy, and it is now named. The faulting instruction is in
`ucrtbase.dll` at RVA `0x91028`:

```
adrp x8, ...
ldr  x16, [x8, #0x898]
blr  x16          ; x16 = 0, pc = 0, exit 0xc0000005
```

The slot is RVA `0xe3898`, which is `IMAGE_ARM64EC_METADATA.__os_arm64x_dispatch_call_no_redirect`.
ntdll's own copy of that slot is initialised (`ExitToX64`). The copy ucrtbase actually
executes, in the JIT pool, is still zero. `arm64ec_update_hybrid_metadata` writes the PE
image and relies on the NtProtect sync to mirror it; that mirror is not reaching this slot.

`update_hybrid_pointer` now also writes the pool alias (`xlate_ios_jit`). Shipped as
`dist/FH6-iOS-1.14-poolslot-builtin.wcp`. It only loads when a unix half that knows about
builtin overrides is enabled (`ml2136`); the app's static unix ignores the package and the
log then has no `[builtin-override]` line. One run in this series was that void case.

With the fixed ntdll confirmed loaded:

| `kernel32` in `sysx64` | game spawns | `pc=0` |
|---|---|---|
| bundle plus 16 prologues | **yes** | 0 |
| bundle plus all 792 prologues | no | 6 |
| build-tree `kernel32` (795 prologues) | no | 6 |

So the slot we filled is the one a small prologue set hits, and a full set still finds
another NULL call. The game that did spawn was still ciphertext at 85 s (4538/4538 entries
`0xEA`, no `#UD` in that window). Decrypt has not started. The component file was put back
to the bundle's bare `kernel32` afterwards; `1.14` and `ml2136` were left enabled.

### 4as. The pool slot is not zero — instruction fetch does not see the store

A volatile read of ucrtbase's pool slot, after the NtProtect that is supposed to
mirror it, returns the exit thunk (`jit@…=…1C44`, not 0). The fault handler's own
load of the same address (`JIT *slot`) returns that same pointer. `x16` at the
`blr` is still 0, and the branch goes to `pc=0`. The bytes the CPU was supposed to
execute and the bytes a data load sees are not the same view.

Rewriting that `blr` to a `bl` in the pool copy does land in memory: the fault dump
shows `97eb034b` where the file has `d63f0200`. The CPU still takes the old `blr`
(`x16=0`, `pc=0`) after `NtFlushInstructionCache` of the whole section and again
after a 4-byte invalidate of that instruction plus an `isb`. The x18 patcher is the
path that does change what the CPU executes, and it writes the RW alias, then
invalidates the RX address. A store to the RX address, which is what
`xlate_ios_jit` returns, updates the view a data load reads and not the view
instruction fetch uses.

A plain `b` (no link) instead of `bl` does not return. One run with that encoding
left `dockhost` spinning at full speed for the whole wait, and never spawned the
game. The branch rewriter was taken back out of `signal_arm64ec.c`. The on-device
`kernel32` is the bundle's bare copy again, and the ntdll component is the build
that only does the volatile read, not the rewriter. Unix half `ml261-rxmirror`
(it also copies the NtProtect sync onto the RX data pages) was left enabled; it
did not change this crash. The phone was later put back on the 795-prologue
`kernel32` for the runs in §4at; that is the copy it still has.

### 4at. The RW-alias write does not change a fetch that already happened, and at copy time the target is not known yet

Two runs, both with the 795-prologue `kernel32`. The dock dies at
`ucrtbase+0x90f1c`, `pc=0`, `x16=0`, exit `0xc0000005`. `forzahorizon6.exe` does
not spawn.

`ml263-rwbl` installed the retarget into the ARM64EC child (the first build only
installed it for the aarch64 ntdll, so it never ran). The log then shows 19
ucrtbase sites rewritten. A kernel read of the executable address returns the new
`bl` (`97eb034b`) and a kernel read of the slot returns ExitToX64
(`0x11c4cdc44`). The CPU still executes the old `blr`: the link register is
`ucrtbase+0x90f1c`. Writing the writable alias and invalidating the executable
address, which is what the x18 patcher does, does not change an instruction the
CPU has already fetched. 14:12 run.

`ml264-copybl` moved that write to image-copy time, next to the x18 patch, which
is before the guest can fetch. It patched nothing. `ntdll`, `libarm64ecfex`,
`ucrtbase`, `kernel32` and `kernelbase` each logged that the exit thunk was not
stored yet. The slot is filled in `arm64ec_process_init_dispatchers`, from
xtajit64's `ExitToX64` export, and that runs only after those copies. 14:28 run.
Same crash.

The next write resolves `ExitToX64` from the export table while xtajit64 itself
is being copied (it is copied before ucrtbase; the tree's `xtajit64.dll` exports
it at RVA `0x118c44`, and the bytes there are `ldr x16, [x9]`, the real body)
and patches the later images in that same window, ahead of the full-image
invalidate the copy already does. The same pass also rewrites `blr` through a
read-only slot that already holds an in-image pointer. ucrtbase has 181 of
those, and one of them is `ucrtbase+0x17680` (`adrp; ldr x8, [x8, #0x1d0]; blr
x8`, slot RVA `0xd81d0` in `.rdata`, file pointer `0x18008fec4`). The earlier
branch rewrite died at that instruction as soon as `0x90f1c` was no longer the
one that ran. Those 181 targets are not the C runtime functions. Each is a
five-instruction thunk that loads a constant into x11, computes a code address
in x10, and branches to a shared stub. The stub does `blr` through
`__os_arm64x_dispatch_icall` (metadata + `0x20`, ucrtbase slot RVA `0xe1508`,
11 sites). The file qword there is 0. `arm64ec_update_hybrid_metadata` fills it
with `arm64x_check_call` after the copy, so a direct branch into the thunk
still dies at the stub if that load returns 0. ntdll is copied first. `arm64x_check_call` is the only place that starts
with `lsr x16, x11, #39` / `cbnz x16`, in both the tree's ntdll and the ntdll
on the phone (RVA `0x56fe0`). The x18 patcher runs before this scan and has
already replaced the following `ldr x16, [x18, #0x60]` with a branch, so the
scan matches those two instructions. It records that pool address and rewrites
the stub's `blr` to `bl` it, in the same pre-fetch window. The
`bl` sets the link register the same way `blr` does, and the stub still
returns into `br x11`. Packaged locally as `dist/ml265-exitexport-native.wcp`.
It has not been on the phone. The phone is still on `ml264-copybl`, the
795-prologue `kernel32`, and the retarget ntdll, so Play crashes the dock.

On that crash `x9` is already set. `ucrtbase` pool base `0x11cb44000`, `x9` =
`0x11ccada78`, which is `kernel32+0x35a78` in the pool copy at `0x11cc78000`.
The kernel32 on the phone has `ff 25 d2 ab 01 00` there, the `jmp [rip+rel32]`
of a hotpatch thunk whose prologue sits at `0x35a70`. `ExitToX64` compares
`[x9]` with the fast-forward sequence `48 8b c4 48 89 58 20 55 5d` and only
then takes the native bypass. These bytes do not match, so a direct branch
that actually runs falls through into the emulator. A fault inside `ldr x16,
[x9]` would mean that address was not the mapped thunk. `arm64x_check_call` in
the same log is at `0x11c2aefe0`, about 7MB from ucrtbase, inside `bl` range.

The constant-call pass does not check that its target is executable. A file
simulation of the same match, on the arm64ec DLLs the app ships, patched
ucrtbase 181, kernel32 79, kernelbase 744, win32u 1 and ntdll 0, and every
target was in an executable section. The packaged dylib carries the log lines
for `ExitToX64`, `arm64x_check_call`, `icall patched` and `constant calls
patched`, so a run that prints none of them is not running this package.

### 4au. The copy-time branch does run, and the x18 patcher was eating the x64 jmp

`ml265` was pushed and loaded (`[unix-half] ... ml265-exitexport`). ucrtbase
logged slot patched 19, icall patched 11, constant calls patched 181. The
faulting instruction, read back from the link register, is `97eb034b`, which is
`bl` to the logged `ExitToX64`. The copy-time window is what the CPU fetches.

The call is `GetCommandLineA` (kernel32 export at `0x35a70`) during
`load_arm64ec_module`'s dependency attach, before `arm64ec_process_init`. The
fast-forward bypass does not match a hotpatch jmp, so `ExitToX64` tries to
enter the emulator. `EmulatorData[2]` is still 0, and `br` to it dies at
`pc=0`. `ThreadInit` has not run: the log never reaches "about to call
arm64ec_process_init".

The bytes at the jmp are not `ff 25`. They are `48 8d a4 24 00 00 00 00` then
`b` (`14 02 32 bb`) into the x18 trampoline area. `ff 25 d2 ab` is the word
`0xabd225ff`. Its bits [20:16] are 18, so the x18 patcher classifies that x64
jmp as an ARM add that reads x18 and replaces it. `GetCommandLineA` sits in
the code map's x64 range `0x34000` for `0xdcc0`. `ml267` leaves those ranges
alone (kernel32 logged 3726 instructions left). `arm64ec_process_init` then
returns 0, and both `pProcessInit` and `pThreadInit` return 0. The dock loads
Steam modules past that point and later dies at host `pc=0xb3724a68`
(`c0000005`, tid `00ac` in the dock). The guest RIP is the pool address of
kernel32+`0x319cc`, the instruction after a patched `bl ExitToX64` (the `blr`
was at `0x319c8`, no_redirect slot `0x70390`, one of the nine). The code map
marks `0x10000`–`0x338e4` as ARM64EC, so that page is ARM. The emulator used
the pool pointer as an x64 RIP and the host left the block for an unmapped
address. `forzahorizon6.exe` does not start. "Failed to mprotect last page of
code buffer" is logged earlier and execution continues past it.

### 4av. The crash at kernel32+`0x319cc` is the return check, and the game now reaches the ciphertext fault

Widening `ExitToX64`'s pool window does not touch this crash. A window of
`0x10`–`0x13` missed a pool whose base had moved to `0x148000000` (guest RIP
`0x14a3459cc`, `unix_calls=4589`, still no `[exit-pool]` line). Widening it to
`0x10`–`0x17` (`poolgate2 compiled Nov 22 2026 16:08:27`) loaded and changed
nothing: the same guest RIP, `unix_calls=4517`. The window inspects `x9`, and
`x9` at the `bl` is the call target. The address that becomes the guest RIP is
the link register, which `ios_ffs_no_bypass` pushes as the x86 return address.
Do not widen that window again.

The EC bitmap for the pool page is set. The dispatcher loop takes
`ExitFunctionEC` with `x9` = the pool epilogue. `ExitFunctionEC` loads the
word at `[x9-4]` and compares it with `blr x16` (`0xd63f0200`). The copy-time
patch replaced that `blr` with a direct `bl`, so the word is the BL encoding.
The miss path adds that word, masked to a 4-byte offset, to the return
address and branches there. kernel32's BL at pool `0x14a3459c8` is
`0x97e7acbb`; adding it to `0x14a3459cc` lands on `0xe21c0684`, which is the
fault pc, with `x16` still holding `0xd63f0200` and `x9` still the epilogue.

A BL (top six bits `0x25`) is the same return edge as `blr x16`, so
`ExitFunctionEC` now branches to the epilogue. The image that did this prints
`blrret compiled Nov 22 2026 16:15:39`. The dock survives.
`NtCreateUserProcess` creates
`C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6\forzahorizon6.exe`
at t+5.4 s (image `0x132f00000`, pool `0x153a44000`). The process then dies
`0xc000001d` at `0x13827099c`, which is image+`0x537099c`. The bytes there are
still `ea e9 6b e6 14`, and the arena needle does not find that stub in the
16 MB arena. That is the halt in §4. It is not a new one. `unix_calls=9958`.

The return-edge check is in the FEX working tree (`Module.S`,
`ExitFunctionEC`) and in the `ml268-exitpool` component file on the phone. It
is not a submodule commit: `Module.cpp` in the same tree also carries the
unlanded debug-register exports.

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

0. **The dock crash at kernel32+`0x319cc` is fixed, and the game dies at the
   known ciphertext site.** Do not point the FEX package at `${sysx64}`: the
   dock opens `C:\windows\system32\xtajit64.dll` (§4av). Do not widen
   `ExitToX64`'s pool window: `x9` is the call target, and the guest RIP is
   the pushed link register. The bitmap already sent that return to
   `ExitFunctionEC`; the fault pc `0xe21c0684` was the BL encoding added to
   the return address. The phone is running `blrret compiled Nov 22 2026
   16:15:39` from `ml268-exitpool` at `${system32}/xtajit64.dll`.
   `forzahorizon6.exe` is created and dies `0xc000001d` at image+`0x537099c`
   with bytes `ea e9 6b e6 14`. That halt is §4. The closed decryptor
   experiments stay closed. The kernel32 component is still the 795-prologue
   build; putting the bundle's bare `kernel32.dll` back on
   `kernel32-one.dll` gives up that test.

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

---

## 8. Milestone reached (2026-11-22): Live 1920×1080 rendered Forza Horizon 6 title screen on iPhone 17 Pro (46 FPS)

Forza Horizon 6 (`forzahorizon6.exe`, Steam AppID `2483190`) now boots cleanly through its anti-tamper runtime decryption, hardware checks, D3D12 PSO compilation (2,946 pipelines), intro playback, and `ResizeBuffers(1920×1080)` to the **live rendered 3D title screen ("FORZA HORIZON 6 — [Enter] Start Game  [X] Accessibility/Settings") at 46 FPS (`21.9 ms` frame time, `5.2 ms` GPU time, `3,675 MB` footprint)** on iPhone 17 Pro (`iPhone18,1`, iOS 27.0.1), with live audio and zero app re-signing required for game-specific fixes (all shipped as `.wcp` packages + `madeira.cfg`).

### 8.1 Root-cause chain resolved (chronological)

1. **`ml272`–`ml276` (Runtime decryption, exception dispatch, memory & Win32 compatibility)**:
   - `ml272-fastexc-fex.wcp` (`FEXCore`): dropped FEX DEBUG logging by default, sampled invalid-instruction logs, and added JIT-pool direct dispatch for `KiUserExceptionDispatcher` and `__wine_dbg_output`.
   - `ml273-comctl32v6-pe.wcp` (`Wine`): ARM64EC `comctl32.dll` v6 exporting `TaskDialog` (#344) and `TaskDialogIndirect` (#345) so FH6's compatibility/error dialogs render and respond cleanly (`FH302` dismissed via *"Don't show again"*, `ret=4`).
   - `ml275`/`ml276-veneer-native.wcp` (`UnixHalf`): `fastexc`, `hiexe`, `totalphys` (`16384 MB`), `winios_drv` UnixHalf exports, and ARM64EC retarget far-branch veneers.
2. **`ml277-d3d12-dev10-pe.wcp` (`FH621` GPU check)**:
   - Implemented `ID3D12Device10` (`IID_ID3D12Device10` = `{517f8718-aa66-49f9-b02b-a7ab89c06031}`, `CreateCommittedResource3`, `CreatePlacedResource2`, `CreateReservedResource2`) in `madeira-d3d12`, plus Enhanced Barriers (`OPTIONS12`, `ID3D12GraphicsCommandList7::Barrier`).
   - Resolved `FH621` ("Your graphics card is not supported").
3. **`madeira.cfg` virtual-memory & jetsam tuning (`FHD21` & 4,970 MB jetsam)**:
   - FH6 allocates two virtual reserved DEFAULT buffers via `CreateReservedResource2` (`1024 MB` + `2048 MB` = `3072 MB`). Setting `d3d12-reserved-max-mb = 4096` resolved `FHD21` ("Out of Video Memory").
   - Setting `swap-mb = 6144`, `default-buffer-swap = 2` (placing both reserved DEFAULT buffers on sparse file-backed storage), and `pso-lazy-libs = 1` (releasing 2,946 `MTLLibrary` objects at PSO creation) cut `phys_footprint` from `4,970 MB` (jetsam) to a stable **`3,413–3,675 MB`**.
4. **`ml278-kernelbase-pe.wcp` (Post-intro `FHE21` abort)**:
   - FH6 calls `api-ms-win-core-sysinfo-l1-2-3.dll!GetIntegratedDisplaySize` right after the intro video (`apisetschema.spec` routes `api-ms-win-core-sysinfo-l1-2-*` → `kernelbase.dll`, where `GetIntegratedDisplaySize` was commented out).
   - Exported and implemented `HRESULT WINAPI GetIntegratedDisplaySize(double *size_in_inches)` in `wine/dlls/kernelbase/` (`E_INVALIDARG` on NULL, else `E_FAIL`).
5. **`mip0-full = 1` (First 3D title-screen frame Metal assertion)**:
   - FH6 created a `400×225` `MipLevels = 0` render target and then created SRVs for mip levels `1..7`, tripping `_mtlValidateArgumentsForTextureViewOnDevice` (`newLevelRange > mipmapLevelCount(1)`). Enabling existing `madeira.cfg` key `mip0-full = 1` gave `MipLevels = 0` textures their full mip chain and passed cleanly into `ResizeBuffers(1920×1080)`.
6. **`ml281-d3d12-present-pe.wcp` (iOS `CAMetalLayer` pixel format conversion)**:
   - FH6 creates its intro swapchain as `DXGI_FORMAT_R10G10B10A2_UNORM` (`MTLPixelFormatRGB10A2Unorm = 90`) and its title-screen swapchain as `DXGI_FORMAT_R8G8B8A8_UNORM` (`MTLPixelFormatRGBA8Unorm = 70`). Neither format is accepted by iOS `CAMetalLayer` (Apple's iOS `CAMetalLayer` only accepts `BGRA8Unorm` (`80`), `BGRA8Unorm_sRGB` (`81`), `RGBA16Float` (`115`), and XR10 formats — notably *not* `BGR10A2Unorm` (`94`) either, which is macOS-only and produced blank output in `ml279`).
   - Added `mad_present_vs` + `mad_present_fs_arr` / `mad_present_fs_2d` in `madeira-d3d12/src/pe/mad_kernels.metal` and `mad_layer_pixel_format()` in `madeira-d3d12/src/pe/madeira_d3d12.c` mapping unsupported swapchain formats (`RGB10A2Unorm`, `BGR10A2Unorm`, `RGBA8Unorm(_sRGB)`) to `BGRA8Unorm(_sRGB)` and presenting via a fullscreen render pass when `s->layer_pf != s->pf`.
7. **`ml282-zorder-native.wcp` + `Winios.m` (Win32 Z-order backdrop occlusion — the final black-screen root cause!)**:
   - Frame capture (`auto-capture-present = 150` → `f151_sheet00.png`) proved `Backbuffer` already contained crisp rendered FH6 frames while the screen showed solid black.
   - `[winios-tree]` revealed FH6 creates its Metal window `0x1005a` (`{128,0,1280,648}`) *first*, then creates an opaque black `1408×648` letterbox backdrop window `0x1006c` (`WS_POPUP | WS_VISIBLE | WS_DISABLED | WS_CLIPSIBLINGS`, `WS_EX_TOOLWINDOW`) *second*, and calls `SetWindowPos(0x1006c, hwndInsertAfter = 0x1005a, ...)` repeatedly to place `0x1006c` behind `0x1005a`.
   - `Winios.m` appended `CALayer`s in creation order and never synced Win32 `insert_after` Z-order, so `0x1006c`'s opaque black GDI layer occluded `0x1005a`'s Metal layer for the entire session.
   - Added `winios_window_zorder(HWND hwnd, HWND insert_after)` to `app/Madeira/Winios/Winios.m` (reordering top-level `CALayer`s in `g_compositor_view.layer` via `insertSublayer:below:`/`above:` while keeping `g_desk_bg` at bottom and `g_cursor_layer` at `zPosition = 10000`), wired it in `build/win32u-unix/driver_ios.c` via `dlsym(RTLD_DEFAULT, "winios_window_zorder")`, and added a safe fallback in `driver_ios.c` for older host app binaries that suppresses `WS_POPUP | WS_DISABLED | WS_EX_TOOLWINDOW` backdrops explicitly placed behind another top-level window.

### 8.2 Active working `.wcp` + `madeira.cfg` set on iPhone 17 Pro

- **Enabled `.wcp`s** (measured from `Components/state.json` on 2026-11-22 23:06):
  - `ml288-cfnumber-native.wcp` (`UnixHalf`: the `ml288-cfnumber` NULL guards in `NtSetInformationFile`/`system.c`/`mountmgr.sys`)
  - `ml290-k32hotpatch-pe.wcp` (`Wine`: `kernel32.dll`, 795 hotpatch prologues — see §9)
  - `ml285-gs-stagein-pe.wcp` (`Wine`: `d3d12.dll`, `d3d12core.dll`; geometry-stage emulation)
  - `ml287-poolslot-fex.wcp` (`FEXCore`)
  - `ml278-kernelbase-pe.wcp` (`Wine`: `kernelbase.dll`)
  - `FH6-iOS-1.14-poolslot-builtin.wcp` (`Wine-Builtin`: `ntdll.dll`)
  - `ml273-comctl32v6-pe.wcp` (`Wine`: `comctl32.dll`)
- **Not enabled, and why**: `FH6-iOS-1.13-k32one` installs `kernel32-one.dll`, a test file nothing loads — it never could have fixed the prologue check. `ml289-fh6diag` carried temporary `[fh6-diag]` probes that have since been removed from the tree.
- **Required `madeira.cfg` settings**:
  `d3d12-fl-12-1 = 1`, `d3d12-tiled-resources = 1`, `d3d12-typed-uav-load = 1`, `d3d12-binding-tier = 3`, `d3d12-sm-6-7 = 1`, `d3d12-tile-based = 0`, `d3d12-enhanced-barriers = 1`, `vram-mb = 8192`, `totalphys = 16384`, `swap-mb = 6144`, `d3d12-reserved-max-mb = 4096`, `default-buffer-swap = 2`, `pso-lazy-libs = 1`, `mip0-full = 1`.

### 8.3 Local macOS iteration feasibility (honest assessment)

- The full Forza Horizon 6 Steam installation exists locally on the Mac at `/Volumes/RETROBACKUP/SteamLibrary/steamapps/common/ForzaHorizon6/`.
- However, Madeira's iOS runtime stack (iOS Mach exception delivery, 16 KB page JIT pool with `W^X` split aliases, `LiveContainer` guest container, iOS `CAMetalLayer` pixel format restrictions, and iOS Jetsam `phys_footprint` accounting) cannot be faithfully replicated by running under macOS Wine/CrossOver or the iOS Simulator (which lacks Metal ARM64EC JIT / iOS jetsam / real `AGXMetalG18P` shader validation).
- **What IS fast and effective locally on macOS**: offline PE/DXIL inspection, host regression checks (`tests/host/check-*.py`), and rapid `.wcp` cross-compilation (`< 10 s` for `madeira-d3d12`, `kernelbase`, `win32u-unix`, and `UnixHalf`) pushed directly over USB via `pymobiledevice3` without rebuilding or re-signing the iOS IPA. This `.wcp` hot-swap workflow gave ~15–20s build+push turnaround directly on real iPhone 17 Pro hardware.


---

## 9. Milestone (2026-11-22/23): the anti-tamper now passes *faithfully*, and the invisible sign-in card is isolated

### 9.1 The 2.5–3.3 minute punishment is fixed by real hotpatch prologues (measured)

With the temporary `[fh6-diag]` build (`ml289-fh6diag`), two delayed punishments were captured live in `/tmp/fh6-289-final.log`:

1. **`0118`:** `NtWaitForSingleObject` expired with `STATUS_TIMEOUT` (`0x102`) after `-1264930000` (`126.5 s`).
2. **`0120`:** the same after `-1978770000` (`197.9 s`); it spawned `02e4` (`+0x54f4418`), decrypted `+0x53e5b41`, shut down every Arxan sibling thread, called `NtSetInformationFile(FileAllocationInformation = 19)` on **`forzahorizon6.exe:4`** (`alloc=8`), called `NtSuspendThread` on every thread in the process, and ended with `0154` at `pc=0` (`rip = ForzaHorizon6 + 0x3545824`, identical in all three runs).

**Cause.** ~7–8 s after launch FH6 checks the prologue bytes of ~28 exported `kernel32.dll` timing/system functions. Real Windows x64 emits the 8-byte hotpatch prologue `48 8d a4 24 00 00 00 00 ff 25` (`lea rsp,[rsp+0]; jmp [rip+rel32]`). Bare Wine ARM64EC emitted a bare `ff 25`, which FH6 classifies as a detoured timing API.

**Fix — faithful, not a bypass.** `dist/ml290-k32hotpatch-pe.wcp` packages the stripped `wine/build-arm64ec/dlls/kernel32/arm64ec-windows/kernel32.dll` so the game sees the same prologues Windows has. Verify with `tools/local/pe-thunks.py kernel32.dll` → `hotpatch=795 bare-ff25=1 other=562`; the single remaining bare `ff 25` is the trailing thunk that respects `VirtualSize` (see `48b5692` and `4ao`). Reproduce from source (the artifact is not committed — recent `.wcp`s are untracked by convention):

```sh
# the generator is wine commit cd01b9c0 "winebuild: give x86_64 -import exports
# the 8-byte hotpatch prologue"
cp wine/build-arm64ec/dlls/kernel32/arm64ec-windows/kernel32.dll /tmp/k32/kernel32.dll
arm64ec-w64-mingw32-strip --strip-debug /tmp/k32/kernel32.dll
python3 tools/local/pe-thunks.py /tmp/k32/kernel32.dll    # expect hotpatch=795 bare-ff25=1
tools/wcp/make-pe-wcp.sh ml290-k32hotpatch /tmp/k32/kernel32.dll
```

**Result, measured on device:** FH6 survived **past +350 s** with **zero** `STATUS_TIMEOUT`, zero `0120`, zero `forzahorizon6.exe:4`, zero `SuspendThread`, 60 FPS, 3.7 GB footprint, GPU 13.8 ms/frame. The deterministic death is gone.

### 9.2 The "Sign In To Xbox" card is *never emitted* — it is not empty and not mis-composited

Everything up to the card works: `CredEnumerateW`, `title.mgt.xboxlive.com`, `device.auth.xboxlive.com`, `sisu.xboxlive.com`, `POST login.live.com/oauth20_connect.srf` → **200** with `{"user_code":"Q79ZESJL","verification_uri":"https://www.microsoft.com/link","interval":5,"expires_in":900}`, `go.microsoft.com/fwlink/?linkid=2323820` → `signinupcdn.blob.core.windows.net/remoteconnect/xbox_remote_qrcode.png` → **200**, decoded to `345×345` BGRA32 via `windowscodecs.dll`, uploaded to D3D12 as `r#936`.

**Frame census (`/tmp/fh6-290-245s.log`).** Title frame: `406 commands, 26 draws`. Sign-in frame: `544 commands, 32 draws`. The *only* `+6` draws are `enc#105828` (`cs 60×34`), `enc#105829..105831` (3× `120×67` blur), `enc#105832` (`1920×1080` blur quad, `idx=30`), `enc#105834` (`cs 60×34`). **No card geometry, no QR quad, no text.** `0 skipped`, `0` Metal errors.

**Ruled out, with evidence:**

- **A second window / GDK overlay.** `[winios-tree]` shows the same 12 top-level windows before and after `A`, one visible (`0x1005a` "Forza Horizon 6"). `d2d1.dll`, `dwrite.dll`, `dcomp.dll` and `d3d11.dll` are **never loaded** into the FH6 process although all four exist in the bundle, and there are **zero** `CreateSwapChain*` / `IDComposition*` calls. The `XGameUiShowWebAuthenticationAsync` path is not taken on this build.
- **Presentation/composition.** The full-screen blur quad composites correctly, so `ml281`-style format conversion is not implicated.
- **WinRT factories.** `Windows.Internal.System.Profile.RegionPolicyEvaluator` fails hard at startup (line 169639), a full ~2 minutes *before* `oauth20_connect` (line 190795), and `EasClientDeviceInformation` is a harmless semi-stub. Neither correlates with the card.
- **RETRACTED — do not repeat:** an "`nsrv` never reaches 742, so the QR is never sampled" test. `nsrv` is the **global SRV registry size** (2607 draws at `741`, 108 at `739`, none above), not a per-draw sampling count, so it cannot show which textures a draw reads.

### 9.3 RETRACTED within the hour: "the poll is answered 302" — it is 302 *bytes*

An earlier reading of this section claimed every `oauth20_token.srf` poll returned an HTTP `302`. **That was a misreading of the `[sock-tl]` format string** and is withdrawn.

`wine/dlls/ntdll/unix/socket.c:939-947` formats the field as

```c
snprintf( post, sizeof(post), "%d:%02x %02x", e->post_len, e->post5[0], e->post5[1] );
```

so `post=302:17 03` means **302 bytes read after the handshake tail, first bytes `0x17 0x03`** — a TLS application-data record header, not a status line. The "302" is a byte count. The `~5 s` in `tail->post=5003.9` is the server holding the long poll, which is exactly what the device flow does between `interval:5` polls.

**Consequence:** there is no evidence of an HTTP-level fault in the poll loop. 302 bytes of application data is the size of a small JSON error body plus headers, consistent with `authorization_pending`. Combined with: all DNS resolutions succeeding (`go.microsoft.com` 2, `signinupcdn` 2, `login.live.com` 16 results), zero `winsock`/`winhttp` errors after the press, and `winhttp` option `140` being the benign `WINHTTP_OPTION_IPV6_FAST_FALLBACK` — **the network side is not implicated in the invisible card.** Treat §9.2 (no card draw emitted) as the single remaining fault.

Recorded here rather than deleted because the misreading was plausible enough to repeat: `[sock-tl]` prints *bytes and raw TLS record bytes*, never an HTTP status. (The HTTP status of a response is not instrumented at all.) Before drawing a protocol conclusion from that line, read the format string.

### 9.4 Offline isolation of `A_MessageBox.xaml` and missing `windows.media.speech.dll` (2026-11-23)

1. **`OnRemoteConnectShow` (`forzahorizon6.exe` `0x144ee2520..0x144ee2942`) and WIC decode verified clean.**
   - Disassembly shows the UI thread runs `GetLayer(0x1c1)` -> `CreatePopupRemoteConnect` -> `PushPopup` (`0x1418b96f0`) -> `SetTitle("Main", 0xdfb1ef55)` -> `SetMessage("Main", 0x8b7eb555, formatted)` -> `SetImageMargin(25,25,25,25)` -> `AddOption(1, "HelpButtons"/0x40399493, cb, 1, true)` -> `SetQRImage(png_ptr, png_size, true)`.
   - `+wincodecs` trace (`/tmp/fh6-diag2500-end.log` `L153606..153728`) confirms `CommonDecoder_GetFrame -> 345x345, 32-bit BGRA32` (`{6fddc324-4e03-4bfe-b185-3d77768dc90f}`) and `CopyPixels(..., 1380, 476100, ...)`, followed by D3D12 upload to `r#936` (`/tmp/fh6-ml287b-end.log` `L45928`).
2. **Exact mapping of the `+6` GPU ops to `Scenes/Anthem/A_MessageBox.xaml` (extracted from `media/UI.zip`).**
   - `/tmp/fh6-cap2500/f2501_sheets_index.txt` (`enc#99982..99992`) matches children 0–2 of `A_MessageBox`'s root `<Grid>`:
     - Child 0: `<FZMaterialGlassCapture />` (`enc#99982`, `cs 60x34x1`) — **drawn**.
     - Child 1: `<FZMaterial Style="A_Style_FZMaterial_Popup_Background" />` (`enc#99984..99990`, 3× `120x67` blur + `1920x1080` quad) — **drawn**.
     - Child 2: `<FZMaterialGlassCapture />` (`enc#99992`, `cs 60x34x1`) — **drawn**.
     - Child 4: `<Grid Style="A_Style_FrameworkElement_LayoutRoot"><DockPanel x:Name="MainContent" Style="A_Style_FrameworkElement_DefaultTransition_0">` (title, message, QR `<FZMaterial x:Name="Image">`, `PART_Menu` Cancel button) — **0 draws** (starts at `Opacity="0"` until `UIPageTransitionManager` triggers `PART_transition_in`).
   - Audited `madeira_d3d12.c` (`queue_ExecuteCommandLists`, `queue_Signal`, `list_Draw*`), `mad_kernels.metal`, `driver_ios.c`, `Winios.m`, `FEX`, and the live 145-thread stack dump in `/tmp/fh6-291-afterB.log` (`L52922`) — zero dropped draws, zero fence stalls, and zero `longjmp` faults.
3. **Only missing Wine WinRT DLL FH6 calls: `windows.media.speech.dll`.**
   - Full `[dll-missing]` and `err:`/`fixme:` audit of `/tmp/fh6-292-run.log` shows `C:\windows\system32\windows.media.speech.dll` (`c0000135` -> `RoOriginateLanguageException 0x8007007e` -> C++ exception `0xe06d7363`) during `RoGetActivationFactory("Windows.Media.SpeechSynthesis.SpeechSynthesizer")`.
   - `build/wine-pe/farm-modules.txt` shipped every other `windows.*` WinRT DLL except `windows.media.speech`. `A_MessageBox.xaml` attaches `ScreenReader.Event="OnLoad"` to both `PopupTitleBlock` and the message `FZTextBlock` (whereas `A_Splash.xaml` only uses `OnChange`), and `forzahorizon6.exe` contains `ScreenReaderManager::RefreshSpeechAccessibilitySettingsBeforePlayerSignIn` + `ScreenReader::TryReadLine`.
   - Added `windows.media.speech` to `build/wine-pe/farm-modules.txt`, built ARM64EC `app/Madeira/arm64ec-windows/windows.media.speech.dll` (self-contained: `combase`, `ucrtbase`, `kernel32`, `ntdll`, zero delay imports), and packaged **`dist/ml291-speech-pe.wcp`**.

### 9.5 Next experiments on device, cheapest first

1. **Test `dist/ml296-tailguard-native.wcp` (tail head-guard fix for `FHE21`):** install `dist/ml296-tailguard-native.wcp` (no app rebuild required; backward-compatible with the currently installed app binary) and verify `mfreadwrite.dll` / `windows.gaming.input.dll` never hit `[jit-pool] EXHAUSTED` during long FEX `4 MB` `PoolArena` growth (log shows `[jit-pool] TAIL HEAD-GUARD` with `>= 48 MB` preserved).
2. **Isolate why `A_MessageBox`'s `MainContent` emits 0 draws despite being live & focused:**
   - Test `MADEIRA_FEX_AVX=0` (DroidDeck/Snapdragon has no AVX; `strictfex` already ruled out `FEX_HALFBARRIERTSOENABLED=0`, `FEX_VECTORTSOENABLED=1`, `FEX_MEMCPYSETTSOENABLED=1`, `FEX_X87REDUCEDPRECISION=0`, `FEX_MULTIBLOCK=0`).
   - Run a 1-change XAML A/B inside `media/UI.zip` (`Scenes/Anthem/A_MessageBox.xaml`) on a disposable test copy: replace `Style="A_Style_FrameworkElement_DefaultTransition_0"` on `MainContent` with `Style="A_Style_FrameworkElement_FadeOnlyTransition_0"` (or no transition style) and `Preset="A_UIPageTransitionManagerPreset_Popup"` with `Preset="A_UIPageTransitionManagerPreset_NoAudio"` — this immediately splits **`ZPanel.ZOffset` / `QuarticEasing` culling** vs **`UIPageTransitionManager` `AudioEvent` / `IControlReady` (`FZMaterial`) stall** in a single launch.

### 9.6 Offline audit: DroidDeck/CrossOver, live-but-invisible `MainContent`, and `FHE21` root cause + fix (2026-11-23)

1. **No missing DLLs or DroidDeck/CrossOver secrets.**
   - Audited `/Users/timmycraft/Projects/fh6-wine-fex` (`README.md`, `BUILDING.md`, `fex/0001..0005`, `wine/`, full git log): DroidDeck needs **no** extra Xbox or UI DLLs — only the 5 FEX SMC patches + `kernel32` hotpatch prologues + `FEX_TSOENABLED=1`, `FEX_HALFBARRIERTSOENABLED=1`, `VKD3D_FEATURE_LEVEL=12_2`, `VKD3D_SHADER_MODEL=6_9`.
   - Audited local CrossOver FH6 install (`/Volumes/RETROBACKUP/SteamLibrary/steamapps/common/ForzaHorizon6/`): FH6 ships `xgameruntime.dll` (contains `RemotePromptOperation`, `FetchQRCode`, `/oauth20_connect.srf`, `/oauth20_token.srf`, and the two optional unregistered Gaming Services COM CLSIDs `{834366da-...}` / `{0134a8b2-...}` whose fallback to `RemoteConnect` is normal on Wine), `PlayFab*.dll`, `XCurl.dll`, `libHttpClient.dll`.
   - Full audit of `/tmp/fh6-xtest.log` (run **with** `dist/ml291-speech-pe.wcp`): `windows.media.speech.dll` loads cleanly (`L22384`), all 102 DLLs including `xaudio2_9.dll`, `mmdevapi.dll`, `FMOD` threads, `FAudio_AudioClientThread`, `winhttp.dll`, `windowscodecs.dll` load with **zero** missing DLLs and **zero** D3D12/DXMT/WinRT/WIC errors after pressing `X`/`A`. Thus `windows.media.speech.dll` is **not** the cause of the invisible card.
   - `strictfex` run (`/tmp/fh6-strictfex.log`, testing `FEX_HALFBARRIERTSOENABLED=0`, `FEX_VECTORTSOENABLED=1`, `FEX_MEMCPYSETTSOENABLED=1`, `FEX_X87REDUCEDPRECISION=0`, `FEX_MULTIBLOCK=0`) also ruled out those FEX flags.
2. **Confirmed `A_MessageBox` `MainContent` is live, focused, and handles gamepad input despite emitting 0 GPU draws.**
   - In `/tmp/fh6-xtest.log` and `/tmp/fh6-292-afterX2.log`: pressing **`X`** (`0x4000`) on `A_Splash` *also* triggers Xbox sign-in (`winhttp:set_cookies` + `libpng` QR decode -> `PopupRemoteConnect`), not an offline settings menu.
   - Pressing **`B`** (`0x2000`) leaves the screen blurred (`/tmp/fh6-xtest-afterB.png`), whereas pressing **`A`** on the blurred screen activates `"Cancel"` inside `MainContent -> PART_Menu` and dismisses `A_MessageBox` back to `A_Splash` (`/tmp/fh6-xtest-afterA2.png`).
   - In WPF/AVUI, a `Collapsed`/`Hidden` element cannot take focus; an element with `Opacity == 0` or culled by `ZPanel.ZOffset` **can** take focus and handle `A` while emitting 0 draw calls.
   - Side-by-side comparison of `A_Splash.xaml` (renders!) vs `A_MessageBox.xaml` (0 draws for `MainContent`) narrows the fault to the exact four differences: (a) `A_Style_FrameworkElement_DefaultTransition_0` (animates `Opacity` + `local:ZPanel.ZOffset` with `QuarticEasing`) vs `A_Style_FrameworkElement_FadeOnlyTransition_0` (`Opacity` only), (b) `A_UIPageTransitionManagerPreset_Popup` (`AudioEvent`) vs `NoAudio`, (c) `FZMaterial::IControlReady` (the sole `IControlReady` implementor in the binary) on `<FZMaterial x:Name="Image">` (`r#936`), or (d) `MADEIRA_FEX_AVX=1`.
3. **Root cause and fix for the `FHE21` crash (`461691 \ c2a8fa9d`, `/tmp/crash-screen.png`, `/tmp/crash-madeira-log.txt`).**
   - In `/tmp/crash-madeira-log.txt`, PE images used `jit_pool_offset = 0x15fb0000` (351 MB) of the `0x373a8000` (883 MB) split pool. Because `ios_pool_code_cap` (`build/ntdll-unix/virtual_ios.c:335`) floors `cap` at `16 MB`, FEX's `4 MB` (`0x400000`) `PoolArena` carves bypassed `ios_pool_head_reserve` (`48 MB`) completely, and the collision check at `virtual_ios.c:35628` only tested `pool_tail_off < jit_pool_offset` (`0` bytes headroom). The `4 MB` carves marched down to `pool_tail_off = 0x16000000`, leaving only `0x50000` (320 KB) for HEAD.
   - Late PE loads (`mfreadwrite.dll` and `windows.gaming.input.dll`, each `want=0xa4000`) then failed with `[jit-pool] EXHAUSTED` (`STATUS_NO_MEMORY`), causing `RoGetActivationFactory("Windows.Gaming.Input...")` -> `RoOriginateLanguageException(0x80070008)` -> uncaught `0xe06d7363` -> **`FHE21`**.
   - **Fix (`build/ntdll-unix/virtual_ios.c`):** added `ios_pool_tail_breaches_head_reserve` / `ios_pool_tail_head_guard_check` to refuse fresh `>= 1 MB` tail carves that would shrink usable HEAD headroom (excluding split-pool holes) below `ios_pool_head_reserve` (default `48 MB`) once the process already owns a live `>= 1 MB` code carve. Free-list reuse, Region C, `< 1 MB` dispatcher carves, and a process's first code buffer remain unaffected; `MADEIRA_POOL_TAIL_HEAD_GUARD=0` disables it.
   - **Verification (host):** added `tests/host/check-pool-tail-head-guard.py` (replays the exact `/tmp/crash-madeira-log.txt` split-pool geometry: stops after 53 × 4 MB arenas with 49 MB usable headroom preserved), passed all 9 `check-pool-*` / `check-tail-carve-exec` host tests, and rebuilt `app/Madeira/libntdll_unix.a` via `build/ntdll-unix/compile_patched.sh`.

### 9.7 Platform `.wcp` coverage: `wineserver` and `madeira_ir_unix` now overridable without app rebuilds (2026-11-24)

1. **`wineserver` bundled into `libntdll_unix.dylib` (`UnixHalf`).**
   - `nm` analysis of `app/Madeira/libwineserver.a` against `Madeira.debug.dylib` (from `dist/Madeira.ipa`) showed `libwineserver.a` depends on 9 hidden `libntdll_unix` symbols (`madsync_ioctl`/`post`/`close`/`enabled`, `ios_eco_gen`, `madeira_get_eco`, `ios_wait_reg`, `ios_hang_kill_pid`, `madeira_dircache_changed`) while `libntdll_unix` depends on 3 `libwineserver` symbols (`ios_srv_direct_call`, `ios_wineserver_ring`, `madeira_sync_cells`). Previously, loading `libntdll_unix.dylib` alone split `madsync` and those globals across two images.
   - Renamed the 3 remaining `wineserver`↔`ntdll-unix` global collisions (`server_start_time`, `supported_machines_count`, `native_machine`) in `build/wineserver/build.sh` (`objcopy` sweep), linked `libwineserver.a` into `build/ntdll-unix/libntdll_unix.dylib` alongside `libwin32u_unix.a`, and exported 8 `madeira_unix_half_wineserver_*` entry points in `build/ntdll-unix/unixhalf_entry.c` (23 exported symbols total; 0 missing host imports out of 65 app/wine/madeira symbols against `Madeira.debug.dylib`).
   - Wired `UnixHalf.swift`, `WineServerBridge.m`, `WineProcessBridge.m`, `LogStore.swift`, and `ContentView.swift` to route wineserver lifecycle/state through `UnixHalf` with fallback to `libwineserver.a` when no component (or an older component) is installed.
   - Preserved full backward compatibility with older app binaries: `server_ios.c` and `wine/dlls/ntdll/unix/sync.c` check hidden `madeira_unix_half_is_dylib` / `madeira_unix_half_wineserver_active`; if an older app loads the new `libntdll_unix.dylib` without calling `madeira_unix_half_wineserver_main`, `dlsym(RTLD_DEFAULT, ...)` routes `ios_srv_direct_call`, `ios_wineserver_ring`, and `madeira_sync_cells` to the host app's running `libwineserver.a`.
   - Packaged **`dist/ml296-tailguard-native.wcp`** (4.0 MB, signed team `4CDWTGR84Z`).
2. **Standalone `libmadeira_ir_unix.dylib` override for D3D12 shader conversion.**
   - `nm` confirmed all 76 LLVM/airconv symbols needed by `madeira_ir_unix.o` + `madeira_sm5_ia.o` + `madeira_ags.o` + `madeira_sc_pack.o` are already exported by `Madeira.debug.dylib` (0 missing).
   - Added `build/dxmt-patches/0002-winemetal-ir-unix-wcp-override.patch` (`_madeira_ir_convert` in `dxmt/src/winemetal/unix/winemetal_unix.c` resolves `libmadeira_ir_unix.dylib` once via `madeira_wcp_dylib_path` before falling back to linked `madeira_ir_convert`) and `build/dxmt-ios/build-ir-dylib.sh` (163 KB dylib exporting only `_madeira_ir_convert`).
   - Packaged **`dist/ml296-ir-unix-native.wcp`** (52 KB, signed team `4CDWTGR84Z`) and verified all invariants via `tests/host/check-wcp-native-overrides.py` plus a full offline `xcodebuild` (`** BUILD SUCCEEDED **`).

### 9.8 Regression sweep: complete inventory of divergences from stock Madeira (2026-11-24)

Full diff audit across all 5 repositories (`Madeira`, `FEX`, `wine`, `dxmt`, `madeira-dock`). Two latent bugs were found and fixed during the sweep; every remaining divergence is documented with its gating/risk assessment below.

**Bugs caught and fixed during the regression sweep:**
1. **`app/Madeira/Winios/Winios.m:2122` (FIXED):** `winios_window_zorder` (added for `ml282` z-order layering) referenced `g_cursor_layer` before its `static CALayer *g_cursor_layer;` declaration at line 2643, breaking `xcodebuild` of `Madeira.app`. Fixed by hoisting `static CALayer *g_cursor_layer;` next to `g_desk_bg` (line 1249); full iOS `xcodebuild` now succeeds cleanly.
2. **`FEX/FEXCore/Source/Interface/Core/LookupCache.cpp:217` (FIXED):** `GuestToHostMap::ClearCache()` reset `PoolArenaCount` to `0` while keeping `OwnedPoolArenas` alive (cannot be freed while other threads may still execute in them), which broke `InPoolArena()` and allowed `AddPoolArena()` to allocate past `MaxPoolArenas` on top of existing arenas. Fixed by keeping `PoolArenaCount` intact across `ClearCache()` until `~GuestToHostMap()` frees `OwnedPoolArenas`. (Also removed duplicate `#include <FEXCore/fextl/unordered_map.h>` in `Core.cpp`.)

**Complete divergence inventory vs stock Madeira:**

| Repo / Area | Files | Change | Default-on / Gating | Collateral Risk to Stock Titles & Dock |
|---|---|---|---|---|
| **Madeira / `ntdll-unix` JIT pool** | `build/ntdll-unix/virtual_ios.c` | (1) `ios_pool_tail_head_guard_check` preserves `ios_pool_head_reserve` (48 MB) against fresh `>=1 MB` tail carves after 1st carve (`MADEIRA_POOL_TAIL_HEAD_GUARD=0` disables); (2) `map_image_view` starts `>=64 MB` relocatable 64-bit images above `0x200000000` (with fallback); (3) ARM64EC `ios_jit_retarget_at_copy` + `0x100` far-branch veneer tail room; (4) `virtual_get_system_info` honours explicit `totalphys`/`MADEIRA_TOTAL_PHYS_MB` upward as well as downward; (5) removed unsafe `ml2130` diagnostic stack walker under `virtual_mutex`. | Default on (all 9 `check-pool-*` host tests pass) | **Low / beneficial:** prevents `FHE21` HEAD starvation, prevents stack-guard deadlock under `virtual_mutex`, keeps stock 64-bit relocations intact. |
| **Madeira / `ntdll-unix` loader & signals** | `build/ntdll-unix/loader_ios.c`, `signal_arm64_ios.c`, `server_ios.c` | (1) `p_ios_jit_retarget` hook exported to PE `ntdll.dll`; (2) `ios_active_srv_direct_call` / `ios_active_wineserver_ring` backward-compat `UnixHalf` bridge; (3) fast signal/exception polish for ARM64EC. | Default on | **Low:** backward-compatible with old apps & old `.wcp`s. |
| **Madeira / `UnixHalf` & `wineserver`** | `build/ntdll-unix/unixhalf_entry.c`, `build-dylib.sh`, `compile_patched.sh`, `build/wineserver/build.sh`, `window_ios.c`, `app/Madeira/UnixHalf.swift`, `WineServerBridge.m`, `WineProcessBridge.m`, `LogStore.swift`, `ContentView.swift` | Bundled `libwineserver.a` into `libntdll_unix.dylib` (eliminates `madsync`/`ios_eco_gen`/`ios_wait_reg` split-brain when a `UnixHalf` `.wcp` runs), renamed 3 global collisions (`server_start_time`, `supported_machines_count`, `native_machine`), added `winios_drv_*` + `wineserver` dispatchers; `WineProcessBridge.m` resolves loose dylib overrides via `madeira_wcp_dylib_path`. | Default on when `UnixHalf` `.wcp` is installed; stock fallback unchanged | **Low / fixes real split-brain**; verified by `tests/host/check-wcp-native-overrides.py` and `xcodebuild`. |
| **Madeira / `win32u` & `Winios`** | `build/win32u-unix/driver_ios.c`, `opengl_ios.c`, `app/Madeira/Winios/Winios.m` | `winios_window_zorder` syncs Core Animation sublayer z-order with Win32 `WindowPosChanged` `insert_after`; `Winios.m` resolves `winios_drv_*` through `madeira_unix_half_symbol`; `opengl_ios.c` checks `madeira_wcp_dylib_path`. | Default on | **Low (after `g_cursor_layer` fix):** preserves cursor on top and desktop bg at bottom; fixes games with black letterbox backdrops hiding Metal surfaces. |
| **Madeira / App GUI** | `app/Madeira/Library.swift`, `MadeiraApp.swift`, `SettingsPages.swift`, `DockStartScreen.swift` | (1) Edge-swipe gesture (`sessionEdgeSwipe`, 18 pt edge bands with `allowsHitTesting(false)` centre) opens session menu (`6fdf677`, needs device verification); (2) Close-session button always shown on starting screen and cancels/closes desktop cleanly (`check-dock-start-screen.py` passes); (3) `OrientationLock` (`Auto`/`Landscape`/`Portrait`, default `Auto`). | Default `Auto`; all Dock start-screen host tests pass | **Low:** `Auto` keeps `.allButUpsideDown`; needs on-device edge-swipe ergonomics check. |
| **Madeira / `madeira-d3d12`** | `madeira-d3d12/src/pe/madeira_d3d12.c`, `mad_kernels.metal`, `src/unix/madeira_ir_unix.mm` | D3D12 device10/enhanced-barriers/present/GS stage-in fixes, `madeira_ir_unix.mm` resolves `libmetalirconverter.dylib` via `madeira_wcp_dylib_path`. | Default on for D3D12 titles | **Low:** only affects D3D12 titles (`madeira-d3d12`). |
| **Madeira / PE farm & WCP tools** | `build/wine-pe/farm-modules.txt`, `tools/wcp/make-*.sh`, `app/Madeira/arm64ec-windows/{ntdll,xtajit64,windows.media.speech}.dll` | Added `windows.media.speech` to PE farm; `COPYFILE_DISABLE=1 tar --disable-copyfile` prevents macOS `._*` AppleDouble entries in `.wcp`s. | Default on | **Zero negative risk** (`windows.media.speech.dll` is additive). |
| **FEX (`ios-port-2607` + working tree)** | 33 files in `FEX/` (`Core.cpp`, `LookupCache.{h,cpp}`, `BranchOps.cpp`, `JIT.cpp`, `Dispatcher.cpp`, `MiscOps.cpp`, `MemoryOps.cpp`, `Frontend.cpp`, `Module.{cpp,S}`, `InvalidationTracker.cpp`, `Logging.cpp`, etc.) | (1) Ported DroidDeck `0001..0005` SMC fixes: per-block CRC32C (`FEX_SMC_BLOCK`, default on under `SMCChecks=full` + writable code), out-of-line `ThreadDispatchRemoveCodeEntry`, pool-clone + reusable 4 MB `PoolArena` stub slots (`FEX_POOL_CLONE`, default on under `SMCChecks=full` + anonymous writable exec pages); (2) `FEX_FH6_FASTUD=1` opt-in fast `#UD` dispatch; (3) `BTCpu64GetContext`/`SetContext` x64 debug register round-trip; (4) `PF`/`AF`/`DF`/`RF` EFLAGS preservation in `SyncThreadContext`; (5) `ExitToX64` pool-address guard; (6) `MADEIRA_EC_SYS_TRACE` opt-in syscall trace; (7) `InvalidationTracker.cpp` missing `Info` compile fix. | SMC block CRC + pool clone active **only** under `SMCChecks=full` + writable code; `FEX_FH6_FASTUD` & `MADEIRA_EC_SYS_TRACE` opt-in | **Low for stock titles** (stock titles run default `SMCChecks=mtrack`, bypassing block-CRC and pool-clone); **watch item:** rebuild `xtajit64.dll` when next spinning a FEX `.wcp` to pick up the `LookupCache.cpp` `PoolArenaCount` fix. |
| **Wine (`wine/` submodule)** | `dlls/ntdll/{signal_arm64ec.c,unwind.h,ntdll.spec}`, `dlls/ntdll/unix/{file.c,sync.c,system.c}`, `dlls/kernelbase/{main.c,kernelbase.spec}`, `dlls/comctl32_v6/taskdialog.c`, `dlls/mountmgr.sys/unixlib.c`, `Makefile.in`s (`winebuild` hotpatch prologues) | (1) `arm64x_check_call` `.Lhotpatch` skips 8-byte `lea rsp,[rsp+0]` hotpatch prologue before `ff 25` (prevents `dockhost.exe` RPC livelock when hotpatch prologues are enabled); (2) `BTCpu64GetContext`/`SetContext` + `Bvr`/`Wvr` Dr0–Dr7 carry + `PF`/`AF`/`DF`/`RF` CPSR bits in `unwind.h`; (3) `update_hybrid_pointer` + `ios_jit_retarget` pool mirror; (4) `file.c` `\\GLOBAL??\\` + `GLOBALROOT\\` DOS prefix handling and NULL `CFNumber` guard (`ml288`); (5) `system.c` NULL `CFNumber` guard in `fill_battery_state`; (6) `sync.c` `ios_active_sync_cells()` backward-compat `UnixHalf` bridge; (7) `comctl32_v6` `TaskDialogIndirect` guard; (8) `kernelbase` export fix. | Default on | **Low / broadly beneficial** (fixes real NULL derefs in `file.c`/`system.c` and restores standard Windows `GLOBALROOT` + ARM64EC hotpatch semantics). |
| **DXMT (`dxmt/` submodule)** | `src/d3d9/d3d9_{buffer,device}.{h,c}pp`, `src/airconv/shaders/air_tessellation.metal`, `src/winemetal/unix/winemetal_unix.c` | (1) Stock `build/dxmt-patches/0001-d3d9-index-range-per-draw.patch`; (2) `0002-winemetal-ir-unix-wcp-override.patch` (`libmadeira_ir_unix.dylib` override); (3) `__METAL_MEMORY_FLAGS_NONE__` guard in `air_tessellation.metal` for newer Metal SDK compatibility. | Default on (fallback identical when no `libmadeira_ir_unix.dylib` `.wcp` is installed) | **Zero regression risk.** |
| **Madeira Dock (`madeira-dock/`)** | `src/{launch,scm,validation}.c`, `tests/test-validation.c` | Starts registered `Steam Client Service` via SCM (`MADEIRA_DOCK_CEG_SERVICE_START=0` disables), retries CEG error `55` (`RemoteCallFailed`) up to 3×, treats `result=1, jobs=0` on first request as already prepared. | Default on | **Low / beneficial** for Steam CEG titles under emulation. |

### 9.9 On-device verification of `ml297-tailguard` (`FHE21` fixed) & `A_MessageBox` isolation experiments (2026-11-24)

1. **`ml297-tailguard` (`UnixHalf` `.wcp`) verified on iPhone 17 Pro — `FHE21` FIXED.**
   - Installed `dist/ml297-tailguard-native.wcp` (built after fixing the pre-CAS `pool_tail_off` guard ordering bug found in `ml296` where `ml296`'s guard ran *after* `pool_tail_off` was committed, leaking 4 MB per refusal).
   - Verified cleanly via `UnixHalf` `.wcp` override on the existing installed app (no app rebuild required):
     - **`266,240+` `TAIL HEAD-GUARD` refusals with `0 bytes` leaked** (`head_usable` held steady at `49 MB`, never dipping below the `48 MB` `ios_pool_head_reserve` floor).
     - Both previously failing late PE images (`mfreadwrite.dll` and `windows.gaming.input.dll`, each `want=0xa4000`) loaded cleanly with zero `[jit-pool] EXHAUSTED` events.
     - **`FHE21` (`0x80070008` / uncaught `0xe06d7363`) is eliminated** — FH6 reaches `A_Splash` -> `PopupRemoteConnect` cleanly every run.
2. **Falsified hypotheses on device:**
   - **`MADEIRA_FEX_AVX=0` (Exp 1):** falsified — FH6 requires AVX during early startup and terminates immediately with `0xc000001d` (`STATUS_ILLEGAL_INSTRUCTION`). Note: `FEX/FEXCore/Source/Interface/Core/CPUID.cpp` also supports **`MADEIRA_FEX_AVX=2`** (advertises XSAVE + AVX *without* AVX2, verified in `tests/host/check-hw-registry.py` as `FeatureSet 0x63f9ffff`), which remains an untested zero-code-change A/B knob once the device returns.
   - **Patching `media/UI.zip` on disk (Exp 4b):** falsified — FH6's integrity thread (`019c`) detects any modification to `media/UI.zip`, calls `NtSetInformationFile(19)` on `forzahorizon6.exe:4`, suspends all threads (`srv-suspend`), and exits cleanly via `NtTerminateProcess(-1, 0x0)` (`/tmp/fh6-exp4b.log`). Original `media/UI.zip` was immediately restored and read-back verified (`sha256=566f920b79240b66426dbfd906b87367d3ca5e2651899fd6e76a4afabc8e5ec7`). **Rule going forward:** never modify game files on disk; keep all diagnostics and fixes strictly on our runtime side (Madeira / Wine / FEX / `madeira-d3d12`).
3. **Refined offline analysis of `A_MessageBox` (`PopupRemoteConnect`) invisible card:**
   - **Ruled out from device logs + `UI.zip` XAML inspection:**
     - **Audio / FMOD:** ruled out — FMOD (`slot=0`, 12 ch 48 kHz) actively outputs audio throughout splash and popup (`mean|x|=0.0102 peak=0.207`).
     - **WIC QR decode & D3D12 upload:** ruled out — `IWICStreamImpl_InitializeFromMemory(..., 32827)` decoded `345x345` BGRA32 and uploaded it via `[capture-op] list#15383 enc#75716 copy buffer -> texture mip 0 slice 0 345x345 at 0,0 -> r#936 own memory`.
     - **D3D12 shader/PSO failures:** ruled out — `Present #2600` (`A_Splash`, 26 draws) -> `Present #2800` (`A_MessageBox`, 32 draws = exact same 26 draws + 6 draws for root children 0–2: 2× `FZMaterialGlassCapture` `cs 60x34`, 3× `120x67` blur, 1× `1920x1080` `Popup_Background` quad) reports `0 skipped`, `0 ENDED IN ERROR`, `0 failed` lazy PSOs (`17 -> 19`), and `largest list 32 draws` stays flat for `>200s` (`/tmp/fh6-290-245s.log`).
     - **`UIPageTransitionManager` / `LayoutRoot` in general:** ruled out — `Scenes/Anthem/A_Splash.xaml` (which renders cleanly) **also** uses `<local:UIPageTransitionManager Preset="{StaticResource A_UIPageTransitionManagerPreset_NoAudio}"/>`, `A_Style_FrameworkElement_SplashFadeOnlyTransition` (`BasedOn=A_Style_FrameworkElement_FadeOnlyTransition_0`), and `A_Style_FrameworkElement_LayoutRoot` (`PART_UIResolutionScaler` `ScaleTransform` + `ScaleTransform3D`).
   - **Exact remaining XAML differences between `A_Splash.xaml` (renders) and `A_MessageBox.xaml` (`MainContent` emits 0 GPU draws):**
     - Child-by-child correlation between `A_MessageBox.xaml` and `Present #2600` (`list#18994` in `/tmp/fh6-diag2500-end.log`) proves: Child 0 (`<FZMaterialGlassCapture />`) runs `cs 60x34` + 3× `120x67` blur (`enc#105829..105831`); Child 1 (`Popup_Background`) draws `enc#105832` (`idx=30`); Child 2 (`<FZMaterialGlassCapture />`) runs `cs 60x34` with **0** blur passes (confirming `H_Style_Container_GlassHighBlur_Description` inside `MainContent` never submits a draw); and `BottomBar` + `MainContent` emit **0 draws**. Plaintext disassembly of `OnRemoteConnectShow` (`0x144ee2520..0x144ee2942`) confirms all popup fields are populated in order (title `"Main"` `0xdfb1ef55`, URL+code body `"Main"` `0x8b7eb555`, `Thickness(25)`, `"HelpButtons"` Cancel callback, `SetQRImage` `0x1442106f0`). Because `A_Style_FrameworkElement_DefaultTransition` defaults to `Opacity=1, ZOffset=0`, `MainContent` can only stay invisible if `UIPageTransitionManager` hid it (`TransitionIndex=0`) and never started or completed `PART_transition_in`:
     1. **`Preset`:** `A_UIPageTransitionManagerPreset_NoAudio` vs `A_UIPageTransitionManagerPreset_Popup` (`AudioEvent="/Master/UI/PopUpMenu/HZ2_SFX_HUD_PopUpMenu_Open_01"`, `DurationSpread=0.0s`, `TransitionDelay=0.15s`, `DurationOverride=0.3s`).
     2. **`TransitionIndex="0"` style:** `FadeOnlyTransition_0` (`Opacity` only) vs `DefaultTransition_0` (`Opacity` **and** `local:ZPanel.ZOffset` with `QuarticEasing`, `Outwards=-600`, `Inwards=300`).
     3. **`<FZMaterial x:Name="Image">` (`IControlReady` gate):** `FZMaterial` is the sole implementor of `IControlReady` in `ForzaHorizon6.exe` (`InterfaceInfoInstance<IControlReady, FZMaterial>` at `0x14671a4a0`, `Cast` at `0x141949eb0`, `IsControlReady` body at `0x14193e2e0` is Arxan-encrypted on disk); the `Image` material is the sole runtime-uploaded `FZMaterial` on `A_MessageBox` (`r#936`, `345x345` BGRA32). (`madeira_d3d12.c` `device_GetCopyableFootprints`, `list_CopyTextureRegion`, and `queue_Signal`/`queue_Wait` were audited offline and match D3D12 spec for odd-dimension `345x345` uploads.)
     4. **`BottomBar` (`PART_HelpPanel`):** uses `A_ControlTemplate_ButtonBar`, which remains hidden until `ShowControllerButtonPanel` / non-zero `ActualWidth`.
   - **Next device-ready experiments & artifacts (in order, once iPhone 17 Pro is reconnected):**
     1. Zero-code-change **`MADEIRA_FEX_AVX=2`** test (AVX without AVX2) to check whether AVX2 emulation affects `DefaultTransition_0` / `ZPanel.ZOffset` / `QuarticEasing` or `UIPageTransitionManager` math.
     2. Zero-code-change **`madeira-d3d12` built-in sync diagnostics (`fence-strict = 2`, `queue-trace = 1`, `vis-trace = 1` in `madeira.cfg`)** to force synchronous `Signal` / GPU drain and trace COPY-queue fence completion for `r#936` without needing a new D3D12 build.
     3. Deploy **`dist/ml298-poolarenafix-fex.wcp`** (`xtajit64.dll` `sha256=1c15460d1c43f9fab230ca90e2f414202cfc2ffa0c2a7013ef637b37265acb87`, rebuilt with the `LookupCache.cpp` `ClearCache()` `PoolArenaCount` fix from §9.8).
     4. On-device verification of **`sessionEdgeSwipe`** (`app/Madeira/Library.swift:5729`, `app/Madeira/ContentView.swift:4302`, commit `6fdf677`; offline audit confirmed `GeometryReader.ignoresSafeArea()` aligns the 18 pt edge bands with `ControlsWindow.hitTest` and the `Color.clear.allowsHitTesting(false)` centre preserves starting-screen buttons).

### 9.10 Local macOS / CrossOver GPTK4 iteration assessment (2026-11-24)

Evaluated `/Applications/CrossOver GPTK4.app` as a potential fast local iteration harness when the iPhone is unavailable:
- Existing CrossOver bottle crash telemetry (`/Users/timmycraft/Library/Application Support/CrossOver/Bottles/Steam/drive_c/users/crossover/AppData/Local/ForzaHorizon6/Upload_CrashReport.xml`, plus 16 `report_2026_11_20..21_*` crash folders) confirms **FH6 currently crashes during startup on CrossOver GPTK4** (`PLM_STATE="STARTUP"`, `UI_SCENE="Splash"`, `EXCEPTION_INFO="0x0000000080000100"`, `RUNNING_UNDER_WINE="2"`, `MEM_USED=138011983872`).
- Even aside from that startup crash, CrossOver GPTK4 runs macOS Rosetta 2 + D3DMetal (`libd3dshared.dylib`) rather than Madeira's iOS-specific stack (ARM64EC FEX JIT + 16 KB split JIT pool + Mach exception delivery + `madeira-d3d12` + `UnixHalf` + `LiveContainer`/Jetsam), so it cannot reproduce or validate Madeira iOS runtime bugs (such as `FHE21`, `A_MessageBox` under `madeira-d3d12`/FEX, or iOS touch/edge-swipe UI).
- **Recommended offline iteration workflow:** (1) offline PE / XAML / saved-device-log analysis, (2) host regression suite (`tests/host/check-*.py` — all 8 applicable suites passing, including ASan/TSan and fuzzing), and (3) `<10 s` `.wcp` rebuilds + `xcodebuild` verification ready for immediate deployment once the iPhone reconnects.

### 9.11 On-device root cause & fix for frame-graph/audio stutter (`ml298-rtcsfix`), `TAIL HEAD-GUARD` heap-corruption regression, and `PopupRemoteConnect` tests (2026-11-24)

1. **`MADEIRA_POOL_TAIL_HEAD_GUARD=1` (`ml297-tailguard`) triggers deterministic `ntdll.dll` heap corruption (`FHE21`) during startup.**
   - 4/4 runs with `ml297-tailguard` (`UnixHalf`) + `MADEIRA_POOL_TAIL_HEAD_GUARD=1` (`Exp 3b`, `Exp B`, `Exp B4`, `Exp B5`) crashed shortly after `BCryptCreateHash` (`Present #300..#600`) with `SEGV` (`0xc0000005`) in `arm64ec-windows/ntdll.dll` (`heap.c` `find_free_block` / `free_block`) dereferencing corrupted free-list pointers (including bit-identical `0xff10371a8feb569d` across two independent boots 11 hours apart).
   - Single-variable A/B proved `env.MADEIRA_POOL_TAIL_HEAD_GUARD = 0` on the exact same `ml297-tailguard` binary eliminated the crash **3/3 runs** (`/tmp/fh6-nohg.log`, `/tmp/fh6-fs1-60s.log`, `/tmp/fh6-rtcsfix-90s.log`). Kept `MADEIRA_POOL_TAIL_HEAD_GUARD = 0` in `madeira.cfg` until `FEX` `AddPoolArena` failure handling under `TAIL HEAD-GUARD` refusals is fixed.
2. **Root cause & fix for frame-graph instability and audible audio stutter (`wine/dlls/ntdll/signal_arm64ec.c:3662`, `dist/ml298-rtcsfix-builtin.wcp`).**
   - `prepare_exception_arm64ec` had a missing `{ ... }` block on `if (rtcs_n < 40 && InterlockedIncrement(&rtcs_n) <= 40)`: an intervening `if (rec->ExceptionCode == STATUS_ACCESS_VIOLATION) { ... }` became the sole guarded statement, leaving `ERR("[rtcs] pre: ...")` at line 4023 completely unguarded.
   - Because FH6's Arxan `#UD` (`0xc000001d`) handlers fire ~14,154 times/second, every exception ran `snprintf` + Wine stderr lock + iOS log pipe write + `MADEIRA_LOG_THROTTLE` (**141,541 dropped lines every 10 s**), driving 1,122–1,432% CPU, 258 mJ/300 ms, severe thermal throttling (`TEMP Hot`, P-cores parked), 500–870 ms scheduler stalls, and **`[ios_audio]` underruns (`340.0 ms` short in 17 of 500 passes)**.
   - Fixed the missing braces in `wine/dlls/ntdll/signal_arm64ec.c`, rebuilt stripped+padded `app/Madeira/arm64ec-windows/ntdll.dll` (`dist/ml298-rtcsfix-builtin.wcp`), and verified on-device (`/tmp/fh6-rtcsfix-90s.log`, `/tmp/fh6-rtcsfix-afterA2.log`, `/tmp/rtcsfix-afterA2.png`):
     - `[rtcs] pre:` flood: `141,541 / 10 s` -> **`0`**
     - `[ios_audio]` (`slot=0` & `slot=1`): `340.0 ms` short in 17/500 passes -> **`0.0 ms` short in 0/500 passes (`100.0%` locked across 5 consecutive 10 s windows, worst late wake `0.0 ms`)**
     - Frame graph & lows: `200–500 ms` spikes (`0.1% LOW 1 FPS`, `1% LOW 3–4 FPS`) -> **`67 ms` scale (`0.1% LOW 11–13 FPS`, `1% LOW 15–16 FPS`)**
     - CPU / energy / contention: `1,122–1,432%` / `258 mJ` / `5,657` CS contended/s / `1.18M` `x64->EC`/s -> **`548–675%` / `74–95 mJ` / `109` CS contended/s / `540k` `x64->EC`/s**
   - **Remaining secondary frame-jitter contributors identified:** (a) `37,615 / 10 s` dropped `fixme:bcrypt:BCryptCreateHash ignoring object buffer` lines (`env.WINEDEBUG = fixme-bcrypt`), (b) `ml292-eflags` `xtajit64.dll` `4 MB` `PoolArena` churn (`slot_reuse=0`, `arenas=224`, `tail FREE`/`REUSE` every ~1 s + `1,154 / 10 s` `[iOS-xrem]`), (c) `~13,600 / s` `[subfloor]` Mach exceptions reading `0x7ffe0004`/`0x7ffe0320` (`wine-x18-exc` at 28% CPU), and (d) iOS thermal P-core parking (`P=0 E=1.70 GHz` under sustained `TEMP Hot`).
3. **`PopupRemoteConnect` (`A_MessageBox`) on-device tests:**
   - **`fence-strict = 1` (`/tmp/fh6-fs1-afterA.log`, `/tmp/fs1-afterA.png`):** ruled out D3D12 `COPY -> GRAPHICS` queue-wait races (`[sync-diag]` logged `0` uncommitted `Queue::Wait` signals through `Present #3000`; `GPU-done -> fence advanced 0.10 ms avg`). `Popup_Background` blurs cleanly, `windowscodecs.dll` decodes the `345x345` QR PNG (`setjmp#1/#2`), `nsrv` increments `739 -> 741`, and `MainContent` still emits **0 GPU draws** (`largest list 32 draws`, `0 skipped`).
   - **`MADEIRA_FEX_AVX = 2` (`/tmp/fh6-avx2-70s.log`):** falsified — FH6 requires AVX2 and immediately hits a NULL-deref `FHE21` (`SEGV pc=0x17e2e0574 addr=0x0`) during early startup.
   - **Exact remaining split for `A_MessageBox`:** `FZMaterial::IControlReady` (`<FZMaterial x:Name="Image">` dynamic `345x345` QR texture) vs `A_Style_FrameworkElement_DefaultTransition_0` (`ZPanel.ZOffset` + `QuarticEasing`) / `A_UIPageTransitionManagerPreset_Popup` (`AudioEvent`).

### 9.12 Xbox Sign-In fixed (`query-timestamps = 1`), `ml320c-subfloor` locked 60 FPS, Steam update audit & host test fixes (2026-11-25)

1. **`PopupRemoteConnect` (Xbox Sign-In & QR Code) FIXED — reached `"MISSING TITLE UPDATE"` gate.**
   - **Root cause:** ForzaTech's `ENG_C0` frame timer relied on D3D12 timestamp queries; with `query-timestamps` off, `dt` stayed `0.0`, freezing `A_MessageBox`'s `UIPageTransitionManager` (`TransitionDelay=0.15s` / `DurationOverride=0.3s`) permanently before `MainContent` faded in.
   - **Fix:** setting `query-timestamps = 1` in `madeira.cfg` immediately unblocked `ENG_C0` frame delta timing. `PopupRemoteConnect` rendered cleanly with the live QR code, Xbox sign-in succeeded live on iPhone 17 Pro, and FH6 advanced past sign-in to the **"MISSING TITLE UPDATE"** dialog (the account's cloud save requires a newer FH6 build than the installed `461.691`).
2. **FPS Optimization #1 (`ml320c-subfloor`) — two-layer `KUSER_SHARED_DATA` (`0x7ffe0000`) inline translation verified on device (locked 60 FPS).**
   - **Problem:** FH6 polled `KUSER_SHARED_DATA` (`0x7ffe0004` / `0x7ffe0320`) at `~13,600+/s`, trapping into Mach `[subfloor]` (`1,093,633` traps per run, `wine-x18-exc` burning `~135–380 ms` and parking P-cores).
   - **Fix (two layers):**
     1. *Compile-time direct rewrite* (`FEX/FEXCore/Source/Interface/Core/OpcodeDispatcher.h`): absolute accesses in `0x7ffe0000..0x7ffe0fff` are rewritten inline via `IosSubfloorToReal()` to the real mapped `KUSER_SHARED_DATA` page.
     2. *Lock-free hot-page promotion* (`build/ntdll-unix/signal_arm64_ios.c` `ios_subfloor_translate_win` + `build/ntdll-unix/virtual_ios.c` + `FEX/Source/Windows/ARM64EC/IosJitAlias.cpp` `kIosHotSubfloorPageMark` / `IosPopHotSubfloorPageToInvalidate` + `FEX/FEXCore/Source/Interface/Core/Core.cpp`): guest code pages that fault on a subfloor window via register-indirect addressing are promoted lock-free into FEX and recompiled once with inline translation.
   - **Measured on iPhone 17 Pro (`A_Splash` / Sign-In):**
     - `[subfloor]` Mach traps: `1,093,633` -> **`1`**
     - `wine-x18-exc`: `~135–380 ms` -> **`0 ms`** (P-cores restored)
     - Frame rate: `50 FPS` (`1% LOW 11–17`) -> **locked `60 FPS` (`16.7 ms` flatline, `1% LOW 54 FPS`, `SWAP 0`)**
3. **Host regression sweep & fixes (offline while iPhone unplugged):**
   - **`app/Madeira/ContentView.swift:3523` (FIXED):** session teardown still wrote `ws_log_quiet = 0` directly instead of `UnixHalf.setWineserverLogQuiet(0)`, leaving a WCP-overridden `libntdll_unix.dylib` wineserver's quiet flag stuck at `1` after a session ended. Caught by `tests/host/check-wcp-native-overrides.py`; fixed and verified.
   - **`build/ntdll-unix/signal_arm64_ios.c:14274` (FIXED):** restored the inline `ios_subfloor_ceiling` fast-path reject in `ios_subfloor_translate()` wrapper after extracting `ios_subfloor_translate_win()`; `tests/host/check-subfloor-high.py` now passes.
   - **`tests/host/check-swap-diag.py` (UPDATED):** updated source anchors for `ml293` real `swap_GetFrameStatistics` (`SyncRefreshCount` + `SyncQPCTime`) and `Winios.m`'s `winios_call_dump_all_thread_stacks()` WCP wrapper; full ASan/UBSan/TSan suite passes.
   - **Host suites verified passing:** `check-subfloor-high`, `check-wcp-native-overrides`, `check-pool-tail-head-guard`, `check-dock-start-screen`, `check-rtcs-cap`, `check-runtime-components`, `check-app-link-inputs`, `check-build-inputs`, `check-steam-games`, `check-steam-library`, `check-swap-diag`, `check-swap-images`, `check-x18-{arith,derived-base,tramp-align}`, `check-teb-trampoline-capacity`, `check-reserved-area-retry`, `check-rwx-kernel-writes`, `check-wow-{guard,sweep}`, `check-d3d12-{caps-by-family,fl-12-1,optin-stubs,tiled}`. (Note: `check-swap-coverage.py` fails to compile on macOS due to an untouched pre-existing `ios_donor_system_free` stub collision when slicing `virtual_ios.c` on Darwin.)
4. **Native Steam update audit & fixes (to resolve FH6's `"MISSING TITLE UPDATE"`):**
   - Madeira **does** implement native incremental Steam updates via `SteamOwnedLibrary.updateAvailable()` (`app/Madeira/SteamOwnedLibrary.swift:1239`), `DepotDownloader.install()` (`app/Madeira/SwiftSteam/Content/DepotDownloader.swift:247-375`, chunk SHA-1 check + delta download + `appmanifest_<appid>.acf` update), and **Game details › Steam › `Update available — download` / `Repair installed files`** (`app/Madeira/SteamGames.swift:1583, 1631`).
   - Fixed three freshness/discoverability gaps that made updates easy to miss (verified with `check-steam-games.py`, `check-steam-library.py`, and full iOS `xcodebuild` `** BUILD SUCCEEDED **`):
     - `app/Madeira/SteamOwnedLibrary.swift` (`refreshBranches`): now updates `owned[index].buildID` (in addition to `branches`) whenever fresh PICS `AppInfo` is fetched, instead of waiting up to 6 hours for `steam-library.json` TTL expiry.
     - `app/Madeira/Library.swift` (`LibraryDetail`): now observes `SteamOwnedLibrary.shared` and `SteamGamesModel.shared`, refreshes the app's PICS build/branches on open, surfaces **`Update available — download`** (plus pause/resume) right under **Play** on the top-level Game details page, and shows `"Update available"` on the `Steam` row summary.
     - `app/Madeira/LibraryGridPage.swift:418`: now passes `installedBranch: context.games.branches[id]` to `updateAvailable(...)` so grid cards match `SteamGames.swift`.
5. **Ready for next on-device session (once iPhone 17 Pro is reconnected):**
   - Packaged **`dist/ml320c-subfloor-native.wcp`** (4.0 MB, signed team `4CDWTGR84Z`) with the clean `signal_arm64_ios.c` + `UnixHalf` wineserver bundle.
   - Update FH6 via Madeira's Steam updater (top-level **Game details › `Update available — download`** or **`Steam › Repair installed files`**) to clear `"MISSING TITLE UPDATE"` and enter gameplay.
   - Benchmark `inproc-sync = 1` (`ml321-madsync`, already set in `madeira.cfg`) on the remaining `~71,400/s` wineserver IPC hotspot.
   - Commit the verified milestones once on-device verification of the title update and `inproc-sync = 1` completes.

### 9.13 Main Menu reached, Metal integer-RTV blend fix (`ml321-rtblend`), Xbox auto sign-in persistence (`ml322-cred`), and XNU `IOGPU` <-> `F_PUNCHHOLE` world-load deadlock root cause & fix (`ml323-punchdefer`, `ml324-nopunch`) (2026-11-25)

1. **`ml321-rtblend` — Fixed Metal Render Pipeline Descriptor Validation Crash (`MTLPixelFormatRGBA8Uint` non-blendable).**
   - **Symptom:** After updating FH6 and advancing past sign-in into loading/Main Menu, Metal aborted with `validateWithDevice: ... colorAttachments[i] ... pixelFormat (MTLPixelFormatRGBA8Uint) is not blendable` because FH6 creates graphics PSOs with `IndependentBlendEnable = FALSE` (inheriting RT0's `BlendEnable = TRUE` onto integer G-buffer RTVs — valid in D3D12 where `BlendEnable` is ignored on integer formats, fatal in Metal).
   - **Fix (`madeira-d3d12/src/pe/madeira_d3d12.c`, `dist/ml321-rtblend-pe.wcp`):**
     - `D3D12_FEATURE_FORMAT_SUPPORT` (line `11902`): stopped advertising `D3D12_FORMAT_SUPPORT1_BLENDABLE` for integer DXGI formats (`!mad_format_is_int(f->Format)`).
     - `device_CreateGraphicsPipelineState` (line `19345`): forced `rp.colors[i].blending_enabled = 0` whenever `b->BlendEnable && mad_format_is_int(desc->RTVFormats[i])`.
   - **Verified on-device:** Zero Metal validation assertions across **8,160+ pipelines / 17,920+ shader conversions / 58,590+ command lists**.
2. **`ml322-cred` — Fixed Xbox Live Sign-In Resetting on Every Launch.**
   - **Root cause:** In Madeira Dock sessions on iOS, `services.exe`/`mountmgr.sys` is never started. In `wine/dlls/advapi32/cred.c`, all four `host_*_credential` helpers (`host_write_credential`, `host_delete_credential`, `host_enumerate_credentials`, `host_read_credential`) returned `GetLastError()` (`ERROR_FILE_NOT_FOUND = 2`) when `CreateFileW(MOUNTMGR_DOS_DEVICE_NAME, ...)` failed, whereas `CredEnumerateW` only ignored `ERROR_NOT_SUPPORTED`. As a result, `CredEnumerateW("Xbl*", ...)` discarded all 11 saved Xbox Live credentials that `registry_enumerate_credentials` had already retrieved from `user.reg`, forcing XAL to regenerate `Xbl|DeviceKey` and re-prompt the QR code on every cold boot.
   - **Fix (`wine/dlls/advapi32/cred.c`, `dist/ml322-cred-pe.wcp`):**
     - Changed all four `if (mgr == INVALID_HANDLE_VALUE)` returns in `host_*_credential` from `GetLastError()` to `ERROR_NOT_SUPPORTED` so callers fall back cleanly to Wine's registry credential store.
     - Updated `CredEnumerateW` to accept `CRED_ENUMERATE_ALL_CREDENTIALS` (`0x1`) when `Filter == NULL` (rejecting non-NULL filter with `ERROR_INVALID_PARAMETER`).
   - **Verified on-device across multiple cold launches:** FH6 automatically signs in as **`Welcome, TimmyCraft5063`** with **zero QR prompt**, loads real cloud save stats, and enters the Main Menu (`Continue`) at up to `59–60 FPS`.
3. **World-load freeze & `6,144 MB` jetsam root cause + fixes (`ml323-punchdefer`, `ml324-nopunch`, `broad` + `swap-images = 1` + `vram-mb = 4096`).**
   - **Freeze #1 (`ml299`, `/tmp/fh6-worldload3-full.log`):** At `presents=5313` (`t+266s`), `port=0x11aab` called `NtFreeVirtualMemory(MEM_DECOMMIT)` -> `decommit_pages()` -> `ios_swap_punch_resv()` -> synchronous `fcntl(ios_swap_fd, F_PUNCHHOLE)` while holding `virtual_mutex`, wedging in `run=4` (`TH_STATE_UNINTERRUPTIBLE`) for `18+ minutes` (`MS 1,076,452`) and blocking 5+ threads on `virtual_mutex`, `vm_read_overwrite`, and `_MTLCommandBuffer_waitUntilCompleted`. Killing the process also caused a `180 s` `runningboardd` userspace watchdog panic (`panic-full-2026-11-25-180035.0002.ips`) while tearing down the uninterruptible thread.
   - **Fix step 1 (`ml323-punchdefer`, `build/ntdll-unix/virtual_ios.c`, `dist/ml323-punchdefer-native.wcp`):** Updated `ios_swap_punch_resv` so decommits inside reservation extents never call `F_PUNCHHOLE` under `virtual_mutex` or on a still-mapped range (swaps to a fresh zeroed offset via `MAP_FIXED | MAP_SHARED`, queues the unmapped old slice off `virtual_mutex`, and enlarges `IOS_SWAP_PQ` to `8192`). Verified on-device under `wide`: bypassed the deadlock completely (`17,920` conversions, `0` retries) and reached `phys=6,134 MB` (`10 MB` from jetsam).
   - **Memory headroom (`madeira.cfg`):** Switching from `wide` (`small=3223 MB` left in jetsam RAM) + `vram-mb = 8192` to `env.MADEIRA_SWAP_COVERAGE = broad`, `env.MADEIRA_SWAP_MIN_KB = 512`, `swap-images = 1`, and `vram-mb = 4096` cut world-load footprint by **`~640 MB`** (`5,351–5,664 MB` vs `5,994–6,134 MB`, `480+ MB` below jetsam).
   - **Freeze #2 — Root cause proven (`ml323` under `broad`, `/tmp/dev-ml323-broad-live.log` lines `62050..62952`):** Caught the exact 2-thread XNU kernel AB-BA deadlock red-handed:
     - `port=0xff0f` (Metal/IOGPU submission worker) wedged in `run=4` inside `IOKit` `iokit_user_client_trap` -> `IOGPU` (wiring pages of the `3,448 MB` of `default-buffer-swap=2` / `upload-swap` `newBufferWithBytesNoCopy:` Metal buffers backed by `ios_swap_fd`).
     - `port=0x7e5b` (`madeira-swap-punch`) wedged in `run=4` inside `__fcntl(ios_swap_fd, F_PUNCHHOLE)` (taking XNU APFS's exclusive vnode lock on the **exact same `ios_swap_fd` vnode**).
   - **Fix step 2 (`ml324-nopunch`, `build/ntdll-unix/virtual_ios.c`, `dist/ml324-nopunch-native.wcp`):** Added `MADEIRA_SWAP_NO_PUNCH=1`, which skips all `F_PUNCHHOLE` syscalls on the shared Metal/CPU swap vnode while keeping `msync(MS_KILLPAGES)` before unmapping so dead dirty RAM is discarded without flash writeback and `broad`'s `128 GB` sparse APFS offset space hands out fresh zeroed bump offsets with zero vnode-lock contention. Fixed the macOS `#ifndef __APPLE__` stub guard in `tests/host/check-swap-coverage.py` (`PASS, 0 failures`), built & signed `dist/ml324-nopunch-native.wcp`, and pushed it + `env.MADEIRA_SWAP_NO_PUNCH = 1` onto the iPhone for verification.

### 9.14 Root cause & fix for `winemetal_unix.c:2658` (`ml325-constblr`), first 3D world frame reached (`ml326`), Jetsam headroom tuned (`ml327`), and `ml328` ready for gameplay capture (2026-11-25)

1. **`ml325-constblr` — Fixed silent ARM64EC function mis-dispatch across ALL PE DLLs (`winemetal_unix.c:2658` `assert(0 && "unhandled blit command")`).**
   - **Symptom:** Right as FH6 finished loading the 3D world (past `Present #5500+`), `libwinemetal.dylib` aborted in `winemetal_unix.c:2658` (`assert(0 && "unhandled blit command")`) inside `mad_eb_flush` (`madeira_d3d12.c`), receiving a render/compute command struct (`type=31`/`35`) inside `MTLBlitCommandEncoder_encodeCommands`.
   - **Root cause (`build/ntdll-unix/virtual_ios.c` `ios_jit_patch_const_blrs`):**
     - `ios_jit_patch_const_blrs` scans every ARM64EC PE `.text` section for the 3-instruction sequence `adrp rd; ldr rt, [rd, #off]; blr rt` and rewrites `blr rt` into a direct `bl target` to eliminate the indirect call.
     - Clang's tail-merging optimization frequently merges multiple `switch`/branch arms that load different function pointers into the same register `rt` (`case RENDER: ldr x8, [render_fn]; b Lcommon`, `case COMPUTE: ldr x8, [compute_fn]; b Lcommon`, `case BLIT: ldr x8, [blit_fn]; Lcommon: blr x8`).
     - Because `ios_jit_patch_const_blrs` checked only the single linearly preceding `adrp + ldr` before `blr rt` without checking whether `blr rt` was itself a branch target, it overwrote the shared `blr x8` with a hardcoded `bl <fallthrough_arm_fn>` — silently routing **all** sibling arms to the wrong function! In `mad_eb_flush`, render and compute command encoders were silently dispatched to `MTLBlitCommandEncoder_encodeCommands`.
   - **Fix (`build/ntdll-unix/virtual_ios.c`):**
     - Added `ios_arm64_branch_target()` and `ios_is_arm64ec_import_thunk()`.
     - Before rewriting in `ios_jit_patch_const_blrs`, built a per-executable-section branch-target bitset (`is_target`) covering `b`, `bl`, `b.cond`, `cbz`/`cbnz`, and `tbz`/`tbnz`.
     - When `p + 8` (the `blr rt`) or `p + 4` (the `ldr`) is a branch target, `blr rt` is **preserved** instead of overwritten with `bl`, and all sibling read-only pool-copy slots (`b <skipped_blr>` and ARM64EC import exit thunks) are rebased into `rx`.
   - **Verified on-device (`ml326`, `/tmp/ml326-final.log`) — systemic fix across 12 ARM64EC PE DLLs:**
     - Tail-merged `blr`s preserved: `ucrtbase.dll` (**17**), `madeira_d3d12.dll` (**11**), `kernelbase.dll` (**6**), `wininet.dll` (**4**), `comctl32_v6.dll` (**4**), `advapi32.dll` (**3**), `gdi32.dll` (**3**), `user32.dll` (**2**), `oleaut32.dll` (**1**), `urlmon.dll` (**1**), `comdlg32.dll` (**1**), `mlang.dll` (**1**).
     - **ZERO** `winemetal_unix.c:2658` assertions, **ZERO** bad blit commands, **ZERO** crash reports.
   - **Host unit test added:** `tests/host/check-const-blr-tailmerge.py` extracts and compiles the real production C functions from `virtual_ios.c` with `-Wall -Wextra`, exercising direct patching, 3-way tail-merged dispatch, loop-hoisted `cbz -> blr`, and unrelated `.rdata` preservation (**PASS**).
2. **`ml326` on-device verification (`/tmp/ml326-final.log`, `vram-mb=4096`, `MADEIRA_SWAP_MIN_KB=512`, `pso-parallel=1`):**
   - Cleanly passed the `ml325` crash point and entered 3D World Frame #1 (`pso-parallel: built 78 pipelines on 4 threads before replay (284 so far)`).
   - Hit iOS Jetsam at `fpMB = 6065 MB` (`Metal currentAllocatedSize = 5845 MB`, `small=1958 MB` anonymous RAM) right during the 4-thread parallel Metal compiler RAM spike (`+~220 MB`).
3. **`ml327` on-device verification (`/tmp/ml327-now.log`, `/tmp/ml327-worldload.png`, `MADEIRA_SWAP_MIN_KB=128`, `default-buffer-swap-mb=16`, `swap-mb=12288`, `pso-parallel=0`, `vram-mb=3072`):**
   - Slashed small anonymous commits from `1,958 MB` -> **`158 MB`** and kept peak footprint at **`5,760 MB`** (**380+ MB below iOS's ~6.1 GB Jetsam ceiling — ZERO Jetsam** through all 3D world shader compiles).
   - Identified two config trade-offs:
     - `vram-mb = 3072` pops FH6's `FH202` Compatibility Warning dialog (pausing ~200 s until dismissed); keeping `vram-mb = 4096` avoids `FH202` completely (48 s boot straight to Start Game).
     - `pso-parallel = 0` without `pso-async = 1` stalls the render thread `30–60 s` during single-threaded Metal shader compilation, triggering FH6's hang watchdog thread (`tid=01a4`) to call `SuspendThread(tid=012c)` + `GetThreadContext` (`[srv-suspend] ml730 SUSPEND #7 tid=012c by=01a4`), which deadlocked holding FEX's `CodeInvalidationMutex` shared (`read-holder[0] teb=70493d0000 tid=01a4`, blocking write-waiter `027c` and read-waiters `01c8`/`024c`).
4. **`ml328` ready for live 3D gameplay capture (already pushed to phone, awaiting iPhone reboot to clear XNU kernel-stuck `LiveContainer pid 2414`):**
   - Clean, probe-free binaries deployed to iPhone (`libntdll_unix.dylib` + `madeira_d3d12.dll`, signed team `4CDWTGR84Z`, zero temporary `ml325` diagnostics).
   - `madeira.cfg` tuned to combine every proven win: `vram-mb = 4096` (no `FH202`), `env.MADEIRA_SWAP_MIN_KB = 128` + `swap-mb = 12288` + `default-buffer-swap-mb = 16` + `env.MADEIRA_SWAP_NO_PUNCH = 1` (`380+ MB` Jetsam headroom, zero `F_PUNCHHOLE` deadlock), and `pso-parallel = 0` + `pso-async = 1` (builds new render PSOs asynchronously on 2 background threads: avoids both the 4-thread `+220 MB` Jetsam spike and the `30–60 s` main-thread stall that tripped watchdog `tid=01a4`).
   - Hardened `tools/local/fh6-worldload.sh` with a `6 s` kill guard around `iosdev launch` and OCR homescreen liveness detection.
5. **Regression sweep & host test status (2026-11-25):**
   - **Divergences added since §9.8 table (all safe/beneficial across stock titles):**
     - `build/ntdll-unix/virtual_ios.c`: `ios_jit_patch_const_blrs` branch-target preservation (fixes latent silent tail-merged `blr` mis-dispatch across all ARM64EC PE DLLs); `ml323` off-mutex swap punch deferral; `ml324` `MADEIRA_SWAP_NO_PUNCH` opt-in (`default 0`); `ml320c` subfloor window export.
     - `build/ntdll-unix/signal_arm64_ios.c` + `FEX`: `ml320c` `KUSER_SHARED_DATA` inline translation + lock-free hot-page promotion (drops `[subfloor]` Mach traps from `1.09M` -> `1`).
     - `madeira-d3d12/src/pe/madeira_d3d12.c`: `ml321-rtblend` integer-RTV `BlendEnable` guard (spec-compliant D3D12 -> Metal translation).
     - `wine/dlls/advapi32/cred.c`: `ml322-cred` `ERROR_NOT_SUPPORTED` fallback when `mountmgr` is absent + `CRED_ENUMERATE_ALL_CREDENTIALS` handling.
     - `app/Madeira/{ContentView,Library,LibraryGridPage,SteamOwnedLibrary}.swift`: `UnixHalf.setWineserverLogQuiet(0)` WCP teardown fix + native Steam incremental update freshness/discoverability fixes.
   - **Updated `tests/host/check-pool-split.py`** to match `ml296b`'s pre-CAS refusal check (which reduced `ios_pool_tail_unreserve` sites from 3 to 1 and eliminated concurrent 4 MB leak races).
   - **All 11 applicable host suites PASSING:** `check-const-blr-tailmerge`, `check-pool-split`, `check-pool-tail-head-guard`, `check-subfloor-kuser`, `check-wcp-native-overrides`, `check-swap-coverage`, `check-swap-diag`, `check-dock-start-screen`, `check-d3d12-fl-12-1`, `check-fence-early`, `check-unixlib-binder`.

### 9.15 WCP `madeira_unix_half_symbol` fix, `fh6-ml342b` graphics verification (`252 -> 2` PSO failures, `0` skipped draws), `virtual_alloc_teb` deadlock root cause & fix, modular D3D12/DXIL `.wcp` split, and macOS local-iteration assessment (2026-11-26)

1. **Fixed `madeira_unix_half_symbol` split-brain in `app/Madeira/UnixHalf.swift`:**
   - **Symptom (`fh6-ml342`):** When running with a WCP-loaded `libntdll_unix.dylib`, `Winios.m` called `dlsym(RTLD_DEFAULT, "madeira_unix_half_symbol")` to dispatch `winios_drv_*` (11 functions including `winios_drv_census_owner`) into the loaded dylib. `UnixHalf.swift` implemented `UnixHalf.symbol(_:)` in Swift but did not export `@_cdecl("madeira_unix_half_symbol")`, so `Winios.m` fell back to `Madeira.debug.dylib`'s uninitialized static `libwin32u_unix.a` and crashed at `get_window_thread+0x34` (`NULL+0x18`) before `ForzaHorizon6.exe` could create a visible window.
   - **Fix:** Exported `@_cdecl("madeira_unix_half_symbol")` in `app/Madeira/UnixHalf.swift` and added an explicit assertion in `tests/host/check-wcp-native-overrides.py` (`PASS`). Verified both `_madeira_unix_half_symbol` and `_madeira_wcp_dylib_path` exported in `Madeira.debug.dylib`.
2. **Verified WCP native IR override & DXIL/D3D12 graphics fixes live on-device (`fh6-ml342b`, `/tmp/fh6-ml342b-full.log`):**
   - Booted on Attempt 1 with the `880 MB` split JIT pool, reached **Start Game** in 60 s, Main Menu (**Continue**) at `menu+16s`, and entered 3D world load through the skybox frame (`/tmp/fh6-ml342b-now2.png`).
   - Verified `.wcp` native IR override live: `[ir-wcp] loaded libmadeira_ir_unix.dylib from .../Components/FH6-iOS-unixhalf-native/files/libmadeira_ir_unix.dylib` and `[madeira-ir] DXBC register spaces other than 0 are mapped (madeira.cfg dxbc-register-spaces)`.
   - **Measured pipeline & draw improvements vs prior runs:**
     - Dual-source blending PSO failures: `224` -> **`0`** (including clean retry with dual-source disabled for non-dual-source PS variants)
     - SM5.1 non-zero register-space compute PSO failures: `24` -> **`0`** (`568` compute pipelines built, `0` failed)
     - DXIL GS void-VS failures: `4` -> **`0`**
     - Total PSO success rate: **`13,010 / 13,012` (`99.985%`)** — only 2 VRS (`SV_ShadingRate`) pipelines failed (`D3D12_FEATURE_D3D12_OPTIONS6` reports `VariableShadingRateTier = NOT_SUPPORTED`).
     - Skipped draws (`ml1042`): dropped from `280,258` cumulative `L8579` skips to **`0` skipped per 600 command lists (`13,827–14,190` draws, `0` skipped)** once PSOs warmed (`L8579` cumulative `1,184`). New 3D world pipelines saved into binary archive chunks 17–19 (`89` pipelines, `9.5 MB`, ~`0.1 ms` load on subsequent runs).
   - **Perf telemetry (`ml342b` during late world load):** `gpu_busy = 12.3–17.8 ms/frame`, `ExecuteCommandLists` caller `0.01–0.02 ms`, `Present` caller `0.59–1.37 ms`, `fence-chain 6` (`134.6` encoders, `15.4` overlapped, `84.1` compute encoders kept open at barriers), `f6-rar` (`3.9` read-to-read batches without sync), `fence-early` (`108` fences advanced when GPU reached them).
3. **Root-caused & fixed the world-load completion freeze (`virtual_alloc_teb` / `init_teb+0xb4` under `virtual_mutex`):**
   - **Evidence (`/tmp/fh6-ml342b-deadlock-slice.log`, `/tmp/fh6-ml342b-tail2.log`):** At world-load completion (`phys=5,112 MB`, `563.7 GB` free flash storage verified via `com.apple.disk_usage`, ruling out `ENOSPC`), `port=0x11d1b` (`wine_threadpool_timer_queue`) called `NtCreateThreadEx` -> `virtual_alloc_teb()` -> `init_teb()` and stalled on `init_teb+0xb4` (`str w8, [x19, #0x2030]`, the very first store into a newly committed TEB block) **while still holding `virtual_mutex`**. `port=0xf827` (`wine-x18-exc` in `ios_virtual_handle_fault_for_thread+0xd0`) and `port=0x12763` (`NtFsControlFile` -> `virtual_locked_server_call`) deadlocked behind `virtual_mutex`.
   - **Three contributing bugs in `build/ntdll-unix/virtual_ios.c`:**
     1. `ios_swap_whole_resv()` had been backing `2 MB` TEB reservations (`[swap] ml1077 backed 0x71ffe00000+0x200000 (whole reservation, ml1257) (file off 0 MB)`) onto the shared APFS swap file, violating `ml1081`'s invariant against file-backed page-ins under `virtual_mutex`.
     2. `virtual_alloc_teb()` ignored the return status of `NtAllocateVirtualMemory(..., MEM_COMMIT, PAGE_READWRITE)`.
     3. `virtual_alloc_teb()` executed `memset(ptr, 0, teb_size)` and `init_teb(ptr, is_wow)` while holding `virtual_mutex`.
   - **Fix (`build/ntdll-unix/virtual_ios.c`):**
     - Added `_Thread_local int ios_alloc_no_swap` checked by `ios_swap_commit`, `ios_swap_reserve`, and `ios_swap_whole_resv`, and guarded both `virtual_alloc_first_teb()` and `virtual_alloc_teb()` so TEB blocks always remain in anonymous RAM.
     - Checked the `NtAllocateVirtualMemory(..., MEM_COMMIT, ...)` return status in `virtual_alloc_teb()`.
     - Split `init_teb()` into `init_teb_fields()` (thread-private writes only) + `teb_list` insertion so `virtual_alloc_teb()` releases `virtual_mutex` **before** `memset` / `init_teb_fields` / `signal_alloc_thread`, and re-acquires `virtual_mutex` only to link into `teb_list` (or roll back to `*p_next_free_teb` on error).
   - **Verified on host:** Disassembly of `_virtual_alloc_teb` confirms `_server_leave_uninterrupted_section` precedes `_init_teb_fields`; `check-swap-coverage.py`, `check-swap-diag.py`, `check-wcp-native-overrides.py`, `check-d3d12-tiled.py`, and `check-pool-split.py` all **PASS**.
4. **Modular `.wcp` packaging & stock `Madeira.app` cleanliness audit (Objectives #3 & #4):**
   - Split D3D12 PE and DXIL native converter into independently selectable packages via `tools/wcp/make-d3d12-wcp.sh`:
     - `dist/Madeira-D3D12-v1-pe.wcp` (`type: Wine`): `d3d12.dll` + `d3d12core.dll`
     - `dist/Madeira-D3D12-v1-dxil-native.wcp` (`type: UnixHalf`): `libmadeira_ir_unix.dylib` (signed `4CDWTGR84Z`)
     - `dist/FH6-iOS-unixhalf.wcp` (`v3`, `type: UnixHalf`): `libntdll_unix.dylib` only (signed `4CDWTGR84Z`, TEB deadlock fix included)
     - `dist/FH6-iOS-wine-pe.wcp` (`v7`, `type: Wine`): `advapi32.dll`, `comctl32.dll`, `kernel32.dll`, `kernelbase.dll`, `windows.media.speech.dll`
     - `dist/FH6-iOS-fex.wcp` (`type: FEXCore`): clean `xtajit64.dll` (`PoolArenaCount` atomic fix, `ml320c-subfloor`, no broken `ml295-syncsmc`)
     - `dist/FH6-iOS-ntdll.wcp` (`type: Wine-Builtin`): `ntdll.dll` (`ml298-rtcsfix`)
   - Audited all diffs in `app/Madeira/*.swift` and `app/Madeira/*.m`: changes in `Madeira.app` are strictly general-purpose platform features (WCP import/override plumbing in `UnixHalf.swift`/`WCPComponents.swift`/`WineProcessBridge.m`/`WineServerBridge.m`/`Winios.m`, interface orientation lock in `MadeiraApp.swift`/`SettingsPages.swift`, session close/edge-swipe UX in `Library.swift`, and Steam incremental update freshness in `SteamOwnedLibrary.swift`/`LibraryGridPage.swift`) with zero FH6-specific hacks.
5. **Local iteration on macOS assessment (Objective #6):**
   - Inspected `~/Library/Application Support/CrossOver/Bottles/Steam` (`dosdevices/m: -> /Volumes/RETROBACKUP`, mounted on this Mac).
   - **Honest engineering verdict:** Porting Madeira's runtime onto macOS to run FH6 locally against CrossOver's bottle is **not worthwhile** for the remaining FH6 work, because the execution stack differs at every layer that matters: macOS CrossOver runs x86-64 via Apple Rosetta 2 + D3DMetal on macOS virtual memory, whereas every real FH6 blocker we hit and fixed on iPhone 17 Pro (`__PAGEZERO` 4 GB subfloor `KUSER_SHARED_DATA`, split JIT RX/RW pool layout, `ios_jit_patch_const_blrs` ARM64EC pool-copy rewriting, `FEX` ARM64EC `PoolArena` / invalidation, `ios_swap` APFS file-backing + `F_PUNCHHOLE` / `virtual_mutex` / `wine-x18-exc` Mach faults, iOS 6.1 GB Jetsam ceiling, and `madeira-d3d12` + `libmadeira_ir_unix.dylib` Metal Shader Converter on Apple A19 Pro) is specific to iOS Madeira's Wine+FEX+Metal stack and would neither reproduce nor validate under Rosetta/CrossOver.
   - Instead, the fast local iteration loop that **does** transfer 1:1 is compiling and running the real production C slices under `tests/host/` (with `-Wall -Wextra` and ASan/UBSan/TSan where applicable), which already caught `check-swap-coverage.py` and `check-wcp-native-overrides.py` regressions in <2 seconds before any device push.

### 9.16 `ml344` private-vnode swap isolation (zero stalls) & `ml345` zero-copy tiled-buffer aliasing + `fence-early` fix — live 3D open-world driving in Japan verified on-device (2026-11-26)

1. **`ml344` (`build/ntdll-unix/virtual_ios.c`) — Eliminated XNU shared-vnode deadlock (`0` GPU stalls, `0` `[fexlock] STUCK`, `0` command buffer errors over 10+ minute open-world runs):**
   - **Root cause:** Even with `MADEIRA_SWAP_NO_PUNCH=1`, `21` large `ml1154`/`default-buffer-swap` Metal buffers (`3,450 MB`) and hundreds of CPU swap mappings all shared the single `madeira-swap.bin` vnode. Concurrent IOGPU page wiring (`newBufferWithBytesNoCopy:`) and CPU page-ins/unmaps/truncates contended on XNU APFS's exclusive vnode lock, causing periodic GPU stalls and `fexlock` hangs under memory pressure.
   - **Fix (`build/ntdll-unix/virtual_ios.c`):**
     - Added `IOS_SWAP_PRIV_FLAG` (`>= 8 MB` swap allocations open and immediately `unlink()` a private sparse APFS fd under `madeira-swap-priv.XXXXXX`, giving every large Metal buffer and large heap allocation its own independent XNU vnode with zero lock sharing against `madeira-swap.bin`).
     - Suppressed `msync(..., MS_KILLPAGES)` when `MADEIRA_SWAP_NO_PUNCH=1` and gated `ios_tls38_poll()` on `madeira_diag_enabled` (removing background polling overhead in normal runs).
   - **Verified on-device (`/tmp/fh6-ml344-full.log`, `14.1 MB`, `124,347` lines):** `229` private vnodes (`4,626 MB`), **`93,063` Metal command buffers retired, `0 ENDED IN ERROR`, `0 ml1061 GPU STALL`, `0 [fexlock] STUCK`, `0` skipped draws per 600 lists (`39,418` draws)** — reached Ohtani Region free roam (`5,592 MB` footprint, live minimap, speedometer, volumetric clouds, Session menu verified live).
2. **`ml345` (`madeira-d3d12/src/pe/madeira_d3d12.c`) — Fixed invisible 3D cars/world geometry AND eliminated `88.8 ms/frame` `fence-early` fallback:**
   - **Root cause #1 — Invisible 3D car and world geometry in `ml344`:** ForzaTech creates a 1 GB reserved buffer `r#15` (`CreateReservedResource2`, backed by `default-buffer-swap` unified `own_mem`), maps a 32 MB `UPLOAD` heap `heap9` into `r#15+0` via `UpdateTileMappings #1`, and calls `CreatePlacedResource(heap9, 0, 32 MB)` -> `r#18` so the CPU can `Map()` it and write all per-frame world/instance/transform matrices that the GPU reads through `r#15`. Because `UpdateTileMappings` was previously a no-op, `r#18` received a standalone buffer (`NOT in the heap: standalone`), leaving `r#15` all zeros on the GPU.
   - **Fix #1 (zero-copy tiled-buffer aliasing in `madeira-d3d12/src/pe/madeira_d3d12.c`):**
     - Added `tiled_alias_owner` on `struct mad_resource` and `tiled_res`/`tiled_byte_off`/`tiled_bytes` on `struct mad_memheap` (with proper lifecycle cleanup in `res_Release` and `memheap_Release`).
     - `queue_UpdateTileMappings()` records the heap-to-reserved-buffer binding when `r->own_mem != NULL`.
     - `mad_create_resource_at()` aliases placed buffers on a tiled-bound heap directly onto `(char *)tr->own_mem + aoff` via `MTLDevice_newBuffer` (`WMTResourceStorageModeShared`, or retaining `tr->buffer` when `aoff == 0`) and marks the aliased buffer resident via `mad_resident()`.
   - **Root cause #2 — `fence-early` falling back 67% (`88.8 ms/frame` wasted):** `device_CreateQueryHeap()` unconditionally set `d->has_query_heaps = 1` even for `D3D12_QUERY_HEAP_TYPE_TIMESTAMP` (type 1), attaching an unused visibility buffer to every render pass and pushing an empty `mad_vis_batch` onto `d->vis_pending`, which forced `mad_vis_job_pending()` to return `1` on 100% of graphics batches.
   - **Fix #2 (`madeira-d3d12/src/pe/madeira_d3d12.c`):** Only set `d->has_query_heaps = 1` when `desc->Type == D3D12_QUERY_HEAP_TYPE_OCCLUSION`.
   - **Verified live on iPhone 17 Pro (`/tmp/fh6-ml345-full.log`, `14.5 MB`, `129,582` lines):**
     - `[d3d12-tiled] ml345 bound heap9 (32768 KB, type 2) -> reserved r#15 +0 MB (32 MB, existing placed=0)` and `[d3d12-tiled] ml345 placed buffer r#18 (32 MB, heap-type 2) in heap9 aliased onto reserved r#15 +0 MB`, plus 6 × 64 MB `DEFAULT` heaps (`heap12/38/39/48/55/78`) bound to `r#16 +0..320 MB`.
     - **`46,348` Metal command buffers retired, `0 ENDED IN ERROR`, `0 ml1061 GPU STALL`, `0 [fexlock] STUCK`, `0` visibility fallbacks, `0` null CBVs bound to zeros.**
     - **`fence-early`: `100.0%` early (`0 the old way`)**, `GPU-done -> fence advanced 0.10–0.19 ms avg`.
     - **Visual & gameplay milestones verified on-device:**
       - Main Menu (`/tmp/fh6-ml345-mainmenu.png`): Full 3D Nissan Figaro at Japanese railway crossing — **`60 FPS` (`16.7 ms`, GPU `4.7 ms`, `2,867 MB`)**.
       - Garage (`/tmp/fh6-ml345-world.png`, `/tmp/fh6-ml345-freeroam-final.png`): Full photorealistic 3D **2023 Audi R8 Coupé V10 GT RWD** (`S1 769`) inside the detailed Garage interior — **`13–15 FPS` (`65.8–68.0 ms`, GPU `18.7–22.9 ms`, `5,355 MB`, nearly 2× `ml344`)**.
       - Open-world Japan free roam (`/tmp/fh6-ml345-ohtani.png`, `/tmp/fh6-ml345-driving.png`, `/tmp/fh6-ml345-driving2.png`): Live **Ohtani Region** at night in winter snow (`Complete the Horizon Invitational`), 3D Audi R8 actively driven down the snowy Japanese town street with headlights, wet asphalt reflections, snow-covered houses, power lines, and mountains in the distance — **`5–8 FPS` (`1% HIGH 27–34 FPS`, GPU `29–35 ms`, `5,135–5,480 MB`, `SWAP 0`)**.
3. **Final `.wcp` package set & host verification (2026-11-26):**
   - Repackaged `dist/FH6-iOS-unixhalf.wcp` (`ml344`, `3,572 KB`, signed team `4CDWTGR84Z`, `sha256=04d5cd1e635c`) and `dist/Madeira-D3D12-v1-pe.wcp` (`ml345`, `322 KB`, `d3d12.dll` `sha256=75f8b4846823` + `d3d12core.dll` `sha256=141c01933757`) alongside `dist/Madeira-D3D12-v1-dxil-native.wcp` (`49 KB`, team `4CDWTGR84Z`), `dist/FH6-iOS-fex.wcp` (`988 KB`), `dist/FH6-iOS-ntdll.wcp` (`958 KB`), and `dist/FH6-iOS-wine-pe.wcp` (`1,257 KB`).
   - **11/11 host test suites PASS:** `check-swap-coverage`, `check-swap-diag`, `check-d3d12-tiled`, `check-fence-early`, `check-wcp-native-overrides`, `check-pool-split`, `check-pool-tail-head-guard`, `check-const-blr-tailmerge`, `check-subfloor-kuser`, `check-teb-alloc-noswap`, `check-dock-start-screen`.

### 9.17 `ml1299`/`ml1300` — why the automation "did not press A", the invisible `FH202` dialog, and what the 4.4 GB swap actually holds (2026-11-26)

1. **The tapping script DID press A — for 33 ms, which the game never drew.** `iosdev tap` holds the touch contact for 50 ms (`_do_tap` sleeps 0.05 s). Madeira forwards it to XInput and the guest samples it exactly once:
   `[11:40:18.947] [xinput] ml2180 app slot=0 input: buttons=0x1000` then `[11:40:18.980] ... rest: buttons=0x0`. FH6 runs at 10–20 FPS (50–100 ms/frame), so between those two samples there was frequently **no frame at all** — the press was delivered, sampled once, and dropped. Library taps worked in the same session because those are handled by Madeira's own UI, not by the guest's frame loop, which is exactly why the failure looked like "the script never taps A".
   - **Fix (`tools/local/dev-run-fh6.sh`):** every pad press is now `pad_press` — `iosdev swipe x y x y --duration 0.45 --steps 1`, i.e. a drag with identical endpoints, which holds the contact for ~450 ms (≈7 frames at 15 FPS).
   - **Verified:** `== menu: A on Continue (held, then verified)` → `A at 506,2210 (hold 0.45s)` → `== A accepted (after 1 press(es))`. The A geometry itself was already correct: the OCR'd `RB` label lands at exactly the predicted `bumperY × 3 = 254 px`, which pins `R = 62 pt`, `k = 1.005` and the `stacked` branch of `TouchControlPresets.xbox(for:)`.
   - `drive_into_game` now *verifies* instead of pressing once per 4 s look: `press_A_until_gone` re-checks the on-state text and reports `A NEVER accepted` when a press is swallowed, instead of silently continuing.
2. **A blank screen is usually the invisible `FH202` dialog.** Two runs stalled for 4+ minutes with no OCR text, no FPS and 7% CPU. `[win-name] #51 ... text="We have detected the following hardware issues ... (Code: FH202)"` with `visible=0` on every window: the warning, its `Ignore Warning` button and `Don't show again` are all created hidden, so nothing is drawn and the game waits behind a modal nobody can see. The drive loop now presses `Enter` then A after two blank looks (`== blank screen: Enter + A`); both stalled runs reached the world after that.
   - It is triggered by the *effective* DXGI budget, not by `vram-mb` alone: `vram-trim-mb = 4096` starts trimming at `6144 − 4096 = 2048 MB` of footprint, so the budget fell to `772 MB` during loading and FH6 popped `FH202` even though `vram-mb = 4096`. With `vram-trim-mb = 1536` the budget holds at **3194–3332 MB** across the whole session and the dialog never appears.
3. **Swap is load-bearing, and the frame cost is memory pressure — not the swap policy.** Measured on the same build:
   - **Guest swap off** (`MADEIRA_SWAP_COVERAGE = classic`, `MADEIRA_SWAP_MIN_KB = 8388608`): the title runs, then is **jetsam-killed** — `fpMB` climbs `5892 → 6122` with `compressed=922 MB`, budget collapses `3000 → 2630 MB`, and the app disappears to the home screen. Swap exists to keep this title alive; removing it is not an option.
   - **1 MB floor** (`MADEIRA_SWAP_MIN_KB = 1024`, so sub-MB heap stays anonymous): jetsam too — one `2331 ms` frame, then gone. The small blocks are hot *and* they do not fit in RAM at 6.1 GB.
   - **`ml1299` live census** (what the tier holds *now*, printed with the 30 s census, allocation-free): `4399MB in 14198 extents: 0x7000-0x7400=3346 0x7400-0x8000=686 jit-pool=0 images=367 other=0 MB | <64K 32/0 <1M 13471/1169 <16M 678/1954 <256M 16/762 big 1/512`. So the file holds **13,471 heap blocks under 1 MB (1,169 MB)**, 678 medium blocks (1,954 MB) and one 512 MB reservation — i.e. Wine heap and D3D12 heaps, not one big allocation. The commit census's `backed=`/`present=` counters count requests since start and never showed this.
   - **In-world after the change:** free roam at the Horizon Invitational start, `FPS 17`, `MS 58.1`, `GPU MS 23.9` (41%) — CPU/main-thread bound, consistent with §9.16's `13–15 FPS` garage.
4. **Packaged:** `dist/ml1300-native.wcp` (`3,660,492` bytes, team `4CDWTGR84Z`) — the same half with the live census written through `ios_swap_put`/`write(2)` instead of `dprintf`, so it is safe to call under `virtual_mutex`.
5. **`madeira.cfg` changes proven here:** `vram-trim-mb = 1536` (was `4096`: no `FH202`, budget stays ~3.2 GB). `env.MADEIRA_SWAP_COVERAGE = broad` + `env.MADEIRA_SWAP_MIN_KB = 64` retained — the alternatives above are jetsam kills.









### 9.18 `ml1301`/`ml1302` — barrier-batch split (neutral) and the real FPS limiter: thermal P-core loss (2026-11-26)

Measured on the `ml1300` baseline and then on each change, in the open world
(`Horizon Invitational`, Japan). Frame time is what the game itself reports
(`[perf] ml1119 ... (frame N ms)`), so it is the same number the HUD shows.

1. **`ml1301` — a full barrier batch no longer becomes a global sync.**
   `list_ResourceBarrier` folds entries into one `MC_BARRIER` record of 8
   resources; the 9th used to set `u.barrier.all` and discard every class in
   the batch, i.e. "synchronise everything". FH6 folds ~86 entries per batch,
   so the overflow was the *normal* path. A full record now starts a **new**
   batch instead.
   - **Result: neutral.** Barrier-caused syncs/frame `139.6 → 125-133`
     ("all" `122.3 → 112-119`), and the game's own fence wait was already only
     `1.5 ms/frame = 2% of wall`. The remaining `all` syncs come from genuine
     transitions *into* write states, which must sync. Kept (more precise
     classification, no measured regression), but it is not an FPS lever.
2. **`ml1302` — the command-list `Reset` wait sleeps instead of spinning.**
   `mad_list_wait_idle` spun (`256 × YieldProcessor`, then `3840 × Sleep(0)`,
   then `Sleep(1)`), which is `16.9 ms` of a `50 ms` frame — and on a
   throttled phone the spinning game thread competes with the submission
   worker it is waiting on. It now spins 512 times and then blocks on a
   per-list condition variable that the worker signals when `inflight` hits 0.
   - **Result: neutral in wall time** (reset wait `17.3 → 14.0-19.8 ms`), which
     is the useful finding: the wait is the worker's *replay*, not spin waste.
     Kept — it no longer burns the CPU it is waiting for.
3. **The real limiter is thermal, and it is visible in `[xp]`.** `P=` and `E=`
   are `ri_pcycles` vs `cpu − pcycles` from `proc_pid_rusage`, i.e. the whole
   process's performance- vs efficiency-core time. Over one 8.5-minute session:

   | window | P-core share |
   |---|---|
   | `13:58:16..13:58:46` (first 30 s) | **61.8 %** |
   | `13:59:47..14:00:19` | 31.4 % |
   | `14:01:26..14:02:09` | 16.0 % |
   | `14:02:09..14:02:59` | 2.7 % |
   | `14:05:16..14:05:58` | **0.7 %** |

   E-core clock falls to **1.63–1.66 GHz** and the HUD reads thermal `• Hot`.
   Frame time tracks it exactly:

   | frame-time window | ms/frame | FPS |
   |---|---|---|
   | first samples (cool) | 20.7–25.8 | **38–48** |
   | after heat soak | 58.5–74.8 | **13–17** |

   So the ~2.8× FPS collapse is the process being moved off the performance
   cores as the phone heat-soaks — not a regression in the port. QoS is not
   the cause: no `[eco]` line was ever emitted (`eco` defaults off, so every
   guest thread is set `USER_INTERACTIVE`), no `eco-prio` refusal was logged,
   and `[bg-qos]` never fired (it only ever demotes the listed *helper*
   processes, never the game's own).
   - **Practical consequence:** measure FPS only on a cool device (or accept
     that a long session reads 13-17 FPS no matter what the code does), and
     treat per-frame CPU work as a *heat* budget as much as a latency budget.

### 9.19 `ml1303` — the two missing SSPI providers, and a separate guest null-deref crash on opening Settings (2026-11-26)

1. **The only modules the title asked for and did not get were `kerberos.dll` and
   `msv1_0.dll`.** `[file-fail] ... status=0xc0000034` (`OBJECT_NAME_NOT_FOUND`)
   is logged 12 times each, and every other failed lookup in the session is one
   of those two (plus a benign optional `microsoft.windows.common-controls.dll`
   probe). They *are* built by the Wine pin
   (`wine/build-arm64ec/dlls/{kerberos,msv1_0}/arm64ec-windows/*.dll`) but were
   never in the shipped farm, so `secur32` had no Kerberos/NTLM provider to
   enumerate. That is the emulation-side candidate for "Unable to join session"
   after a successful sign-in: the profile name is on screen, so credentials are
   fine and it is the security-package stack that is incomplete.
   - **Fix:** packaged `dist/ml1303-sspi-pe.wcp` (`make-pe-wcp.sh`, kind `Wine`,
     32 KB). A `Wine` component is linked into `drive_c/windows/system32/<name>`
     after the bundle's links, so it needs no app rebuild and no re-sign.
   - **Verified on-device:** `[jit-pool] image ... (kerberos.dll)` and
     `(msv1_0.dll)`, and the `c0000034` count for both drops to **0**.
   - Do **not** instead drop these into `app/Madeira/*-windows/`: that changes
     `input_key`'s `farm-inventory` and invalidates `.runtime-cache/windows`,
     which then needs a full `build-runtime-component.sh windows` — and that
     currently fails earlier on unrelated FEX patch drift
     (`0002-arm64x-x64-debug-registers.patch does not apply on FEX f199ce479`).
2. **Four `[fault_rip]` records at boot are benign and unrelated.** They are
   `rip=0x0 pc=<native>+0x6700 addr=0x0 x18=0x0`, repeat exactly 4 times, and the
   title continues each time. `x18=0` places them in native code, and the same
   four appear in every session including clean ones.
3. **Opening Settings is a different, fatal fault, and it is a *guest*
   dereference:** `[fault_rip] cnt=5 rip=0x7058ad0130 pc=0x17ab5ba38 addr=0x10
   x18=0x0`, then `[win-name] ... "Forza Horizon 6 has terminated unexpectedly
   due to an error."` `rip` is a guest address, so FH6 read/wrote `0x10` — a
   null base plus field offset. `x18=0` means the FEX guest state was already
   zero for that thread, i.e. the call arrived from a thread whose emulation
   state was torn down, not a normal guest `mov` fault.
   - Not caused by the SSPI gap: the crash happens after the providers are
     present.
   - Next step is a guest backtrace for that thread (`State.RIP=0`,
     `x18=0`), not a sampler — arming the sampler kills this title (§9.18/prior
     finding), so the backtrace has to come from the fault handler's own
     record.

### 9.20 `ml1304` — the frame graph lied about a stalled title, and the stall it hid (2026-11-26)

**Symptom.** After the title screen (59-60 FPS, 16.7 ms, GPU 14-17 %) pressing **A** to
enter the world put the title on `LOADING... PLEASE WAIT` and it never came back. The HUD
still showed `60 FPS` and `MS 13415`, the log still printed
`[promote] link ran 601 ticks in 10.0 s = 60.0 Hz`, and nothing on screen or in the log
said the title had stopped drawing.

**What the logs actually said about that freeze** (`madeira-log.txt`):

| signal | value | meaning |
|---|---|---|
| last `[perf]` per-frame line | `14:46:50.280`, the instant of the A press | **zero frames for 300+ s** |
| `detach-wait: presents=` | frozen at **14281** from `14:47:09` | no `Present` calls at all |
| `[xp] cpu=` | 60-80 ms per 320 ms (was 1032 ms) | the work stopped |
| `GPU` | 3-14 %, `GPU MS 2.4` | the GPU had nothing to do |
| `[xp] rdKB=` | **0** | no disk reads while "loading" |
| DNS / `NtCreateFile` | **none** after `14:46:54` | not the network, not I/O |
| `[footprint]` | 3149 MB, compressed 329 MB | not memory pressure |
| `[waiters]` | 14 parked, inf waits aged 243-245 s | parked exactly at the freeze |
| `[xp-api]` | `x64->EC 2700-3200/s`, `wakes 0/s` | a polling loop, not a blocked process |
| `[xp-api-cs]` | `steamclient64.dll+0x1753230` = 100 % of contended enters | one static CS dominated |

So that event was a genuine present-path stop (work stops, no I/O, no network, no frames),
not a slow load. **It has not reproduced since**, and the two candidate causes could not be
separated with one sample: Steam's overlay renderer (`gameoverlayrenderer64.dll`, resident
since `14:42:15`) hooks DXGI/D3D12 `Present`, and the title only exercises that once it
starts drawing the world.

**The overlay is *not* required to be off.** That was tested and it is exonerated: with
`GameOverlayRenderer64.dll` restored, the same path walked title -> main menu (`Continue`
/ `Sign Out` / `Exit`) -> world load, presenting continuously the whole way
(`game presents +593`, `+557`, `+596` per 10 s at the menu) with `fpMB` climbing
`3091 -> 4336 -> 5473 -> 5560`. The rename is therefore **not** a fix; `fh6-steam-overlay.sh`
is kept only as a reversible switch for future deadlock hunting.

**What the freeze most likely was: a bad JIT pool.** `app/Madeira` refuses to run against
one and says so — `BAD POOL — ... Relaunch the app.` — but this session produced a second,
worse variant: the app was replaced by an IPA install *while the title was running*, so the
guest was killed mid-flight and the next launches faulted in unmapped foreign memory
(`exc-disp raise ... addr=0x71eae28fe4 pc=12b444fe4`, `p1=0x7f10371a73dd5af5`,
`[fault-rgn] NO wine view — Wine doesn't own this addr`). Those are wild-pointer jumps, which
is what a guest executes when its code buffer/pool state is stale. After a full LiveContainer
restart the same install booted and ran normally, so the install itself is fine.
Operational rule: **never replace the app bundle while a guest is running**, and if a launch
fails, relaunch once before reading anything into the failure.

**Fixed: the frame graph can no longer report a dead title as healthy.** All three readouts
came from things that keep running when the title dies:

1. `[promote]` now reports the title's own present counter beside the link rate, and says so
   when it stops, e.g.
   `... = 60.0 Hz ... | game presents +0 (STALLED 120.0 s: the link is live, the title is not presenting)`
   plus a one-shot `[stall] ml1304 the title has presented nothing for ... s` line. A healthy
   run reads `| game presents +600`, which is how the world load above was verified.
2. The HUD's `FPS`/`MS` cells show `STALL <n>s` in red after 2 s without a present instead of
   the last computed values (the `60 FPS` next to `MS 13415` combination).
3. The compact pill does the same.

The load that follows is still slow — at the title-to-world transition the process ran
`cpu=1072 ms` per `336 ms` sample (~3.2 cores), `rdKB=48-304`, `P=1.31/E=1.70 GHz` thermally
clamped, presenting 16-19 frames/s. That is the standing load-time/P-core ceiling from §9.18,
not the stall.

### 9.21 `ml2030` — why no pool entry can be made no-footprint, and the probe that picks the fix (2026-11-26)

**Symptom.** The 6144 MB jetsam ceiling leaves no room for `tex-drop-mip = 1`
(the garage's texture floor; §9.16 measured +536 MB for one mip). The
880 MB JIT pool (624 MB RX + 256 MB RW alias, up to 848 MB written at world
load) is billed to Madeira's `phys_footprint`, and the ml458 ladder that tried
to exempt it returned `ownership failed kr=4` for every (entry-flags, owner)
pair — `protprobe/001-002` on device — with the plain variants also reporting
`entry covers only 16384 of 554762240 bytes (partial)`: a 16 KB entry for a
529 MB region.

**Root cause, from the xnu source (osfmk/vm/vm_memory_entry.c).** The ladder
was testing the wrong thing. `mach_memory_entry_ownership` rejects an entry
before owner or flags matter:

```c
if (mem_entry->is_sub_map || !mem_entry->is_fully_owned)
    return KERN_INVALID_ARGUMENT;
```

An entry is *fully owned* only when its objects are already owned
(`vo_owner != TASK_NULL`) or external (file-backed). The debugger's `_M` pool
pages are internal and unowned — `VM_OBJECT_OWNER(...) == TASK_NULL` — so
**no entry over the existing pool can ever be made no-footprint**, whatever
flags or owner the call passes. Three further facts from the same reading:

* `TASK_NULL` as owner means *"leave the owner unchanged"* (`owner =
  VM_OBJECT_OWNER_UNCHANGED`), not "no owner". Memory is un-billed only by
  `VM_LEDGER_FLAG_NO_FOOTPRINT` or by the owner exiting — the donor-pool
  mechanism `DonorPool.m` already uses at 14.5 GB scale.
* The no-footprint path passes through an entitlement gate
  (`com.apple.private.memory.ownership_transfer`, `KERN_NO_ACCESS` when it
  refuses). The observed `kr=4` rather than `kr=5` says the gate passed on this
  device and the failures were purely the entry-shape checks — but only a
  fully-owned entry proves that end to end.
* `VM_LEDGER_TAG_DEFAULT` is `0x1` in xnu (`0` is `VM_LEDGER_TAG_NONE`);
  `JITAllocator.c` defined it as `0`, so every ml458 call also tagged the
  object "none". Now fixed to `1`, with tag 0 kept measurable in the probe.

**What can be fully owned at all** — the fix's real question, now that the
pool's own entries are known dead: `MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED`
and `MAP_MEM_PURGABLE` named entries are owned at creation
(`vm_object_ownership_change(..., owner = current_task(), ...)` in
`mach_make_memory_entry_named_create`), and entries over file-backed objects
are fully owned by definition (`!object->internal`). Which of those recipes
*also* survives the no-footprint call on this kernel is what `jit_footprint_probe`
(live where a debugger is: the top of `allocatePool`) now measures — each
variant writes 16 MB first, so the `phys_footprint` delta around the call is
the verdict, not the return code alone.

**The second half is execution.** Un-billing the pool only helps if its RX
side still fetches when it no longer comes from the debugger's `_M` pages.
`MADEIRA_FP_PROBE_BLESS = 1` runs strategy 1 of `jit_test_execute` in
miniature — self-mapped RWX named entry, `prepare`, call a `mov x0, #42; ret` —
on a watchdog thread, because a TXM rejection is not guaranteed to signal. The
fault containment stays installed afterwards (chaining to the previous
handler) so a thread that faults late cannot crash the app.

**What the run decides.** If a recipe both drops 16 MB of footprint and (for
the bless half) executes, the pool is rebuilt from that recipe and `tex-drop-mip
= 1` gets its 536 MB back. If no recipe drops the footprint, only the
donor-exit mechanism remains (extension-owned pool, exit, billed to nobody) and
the headroom must come from elsewhere — the ~1.5 GB of guest memory still
billed anonymously (§9.17's census) is the next lever.

**The verdict (2026-11-26 21:01 run, iPhone 17 Pro).** The ladder ran at
`allocatePool` time (`[fp-probe] ml2030`, `madeira-log.txt`) and three recipes
dropped the full 16 MB, exactly as the xnu reading predicted:

| recipe | ownership kr | fp delta |
| --- | --- | --- |
| `named/create tag0` (`jit_region_create`'s old recipe, tag 0) | 4 EINVAL | 0 |
| `named/create tag1` (same, tag 1) | 4 EINVAL | 0 |
| **`named/tagged nofoot`** (`MAP_MEM_LEDGER_TAGGED` at creation, then `ownership(TASK_NULL, 1, NO_FOOTPRINT)`) | **0** | **−16 MB** |
| **`named/tagged owner->nofp`** (own first, then no-footprint) | **0** | **−16 MB** |
| **`named/purgeable nofoot`** (`MAP_MEM_PURGABLE`) | **0** | **−16 MB** |
| `anon/plain-entry nofoot` | 4 EINVAL | 0 |
| `anon/share-entry nofoot` | 4 EINVAL | 0 |
| `filebacked nofoot` | 0 | 0 (already un-billed: external) |

So the shape of the fix is settled: **create the pool's entry with
`MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED` and apply
`mach_memory_entry_ownership(entry, TASK_NULL, VM_LEDGER_TAG_DEFAULT=1,
VM_LEDGER_FLAG_NO_FOOTPRINT)`** — the tagged-at-creation entry is fully owned,
the call is accepted, and the pages leave `phys_footprint`. `jit_region_create`
now carries the flag (its own `mach_memory_entry_ownership` call was the
"named/create" loser all along and only ever logged "non-fatal" failure), and
the production pool follows once the bless half clears.

The bless half did not run in this session: the gate was `getenv()` on a cfg
`env.*` export that never reaches the app's environ at pool time. It now
travels as a parameter from `MadeiraConfig`, so the next run answers whether
the debugger's `jit26_prepare_region` will arm EXECUTION on self-mapped tagged
pages — the one remaining question before the 880 MB pool can move to this
recipe.

**Round 2 (2026-11-26 21:36 run) — the recipe is proven end to end.** The
bless half ran with word-level read-backs on both views:

```
after write   rx=[d2800540 d65f03c0] rw=[d2800540 d65f03c0]   (mov x0, #42; ret)
after prepare rx=[d2800569 d65f03c0] rw=[d2800569 d65f03c0]   ← prepare PATCHED the word
execute -> 0                                                  ← the patched instruction ran
execute-after-write -> 42                                     ← write AFTER prepare runs exactly
```

Three facts, all favorable:

1. **The dual views alias** — the RW write is visible in the RX view bit for
   bit. The `0` of round 1 was never a fetch failure.
2. **`jit26_prepare_region` authenticates content at arm time** (TXM): it
   rewrote the first instruction word (`d2800540` → `d2800569`, a marker
   patch), so code written *before* prepare does not survive verbatim — and
   the round-1 `0` was simply the patched instruction leaving `x0` alone.
   This is the same "prepare patches the page" contract the pool stamps work
   around (dispatcher marker trampolines, §9.20).
3. **Code written after prepare executes exactly** (`execute-after-write ->
   42`) — which is production's own shape: the pool is armed once at session
   start and written continuously afterwards. Self-mapped tagged pages are
   therefore a full replacement for the debugger's `_M` pool.

The pool itself now allocates through the recipe (`jit_pool_alloc_rx_named` +
`requestPoolRegion`, cfg `pool-nofoot`, automatic fallback to the debugger
allocator on any failure):

```
[pool-named] 560MB tagged entry RX=0x148000000 fp 18 -> 18 MB (delta 0)
[pool-named] 320MB tagged entry RX=0x16b600000 fp 18 -> 18 MB (delta 0)
[no-footprint] pool-RW-alias: [plain/TASK_NULL] ownership OK for 560 MB
```

`delta 0` at allocation is the honest reading: the mappings are fresh
zero-fill reserves and `phys_footprint` counts *resident* pages — nothing is
billed yet either way. The verdict that matters is world load, where the pool
writes its ~848 MB: if the recipe holds, that 848 MB never appears in
`phys_footprint`. Note also `pool-RW-alias: ownership OK` — the old ml458
ladder that returned `kr=4` on the debugger's object now succeeds on the
tagged entry's alias, a second, independent exemption over the same pages.

### 9.22 `ml458` — world-load verdict: the pool is un-billed (~6.0 GB -> 2.3 GB), and the garage headroom it frees (2026-11-26)

The verdict §9.21 deferred, measured on device with the tagged pool live and
the game writing freely through it:

* **World load: `phys_footprint` ~2342 MB active, peak 2377 MB**, against the
  ~6000 MB baseline that ran the title at the jetsam ceiling. The ~3.5 GB
  recovered is the pool's ~848 MB written pages plus the second region and the
  swap-tier shrink (`ml1299` census: `jit-pool=0 MB` in the swap billing).
* The RW-alias ladder now reports `ownership OK` on the tagged entry's alias
  every run — the same call that returned `kr=4` on the debugger's `_M` object
  (§9.21), confirming the recipe independently of the RX view.
* The `pool-nofoot` fallback path is exercised on every run that allocates:
  any failure logs and returns the debugger's allocator unchanged, so the
  recipe is strictly better than the old pool when it holds and identical
  when it does not.

**Consequence:** `tex-drop-mip = 1` (and possibly `0`) is now affordable —
§9.16 measured the garage mip floor at +536 MB for one mip, and the recovered
headroom is an order of magnitude larger. Garage visual verification is queued
for the next run.

### 9.23 `ml459` — the lost-wake stall: the waited word moves under parked waiters (2026-11-26)

The stall dumps (`/tmp/mlog9.txt`) showed two convoys parking for 90 s+ while
the alert ring kept advancing: six waiters on `0x705fb87580` while the word
moved `0x17 -> 0x6`, and a growing crowd (4 -> 7 -> 9) on `0x70636d5898`
around a live counter at 500. Both are the **register-after-check race**: the
compared word changes before the waiter registers, the one wake fires at
nobody, and no later transition exists to fire again.

**Fix (`wine/dlls/ntdll/unix/sync.c`, alert-wait monitor):** park entry records
the compared word (`w0_park`); the monitor nudges waiters whose word changed
since park (age >= 15 s, so a wake already in flight is not raced) and every
>= 120 s parker regardless (sentinel/unknown-predicate safety valve), capped
16 per cycle. A delivered alert is always safe — `RtlWaitOnAddress` is a
compare-loop API and every caller re-checks and re-parks after any return —
so a nudged thread either proceeds on its lost wake or re-parks. A lost wake
becomes a bounded hiccup instead of a permanent stall. Verification on device
is queued: world load should complete with `[waiters] nudge` lines appearing
where the convoys used to form.

### 9.24 Where the frame time goes (2026-11-26 telemetry), and the instrumentation armed for the next run

From `fh6-ml1319c.txt` (menu state, 60 FPS cap, frame 16.7 ms, GPU 6 ms):

* **`ml1120 async per frame: worker busy 13.96 ms (9.0 jobs)`** — the D3D12
  submission worker consumes 83 % of the frame wall; `Present` drain 0.00 ms
  and `list Reset` waits only 1.15 ms, so the cost is the replay itself, not
  waiting. `ml1119`: the caller thread pays 0.01 ms — everything is in the
  worker.
* **`ml1116`: 43 encoders/frame with 43.5 fence waits and 43.0 fence updates**
  — almost every encoder syncs (42 of 43; the one shared-attachment skip is
  the only elision firing). `ml1137` census: 49.5 barrier entries/frame
  (51 into write/common/alias, 38 read->read, 29 UAV, 20.5 rt/depth->read,
  3.5 copy->read), 30.5 barrier-caused syncs of which **28 "all"**; the
  census's own state-aware rule would save only 2.5 (subset) and 0.0 (none),
  so the barrier syncs are close to minimal *by the census's model* — the
  lever is likely the per-encoder fence chain and the replay bookkeeping
  around it, not the barrier classification.
* `encode split`: Metal encode calls 0.3 ms, encoder open+end 0.75 ms,
  `useResource` 79 (49 deduped) — the Metal submission is ~1 ms; "the rest
  of ExecuteCommandLists is the replay itself". `draw-dedup`: 123 of 410
  state sets elided per frame, 64 buffer binds as offsets.
* `ml1109`: `GetCompletedValue` polls 32/frame; `cpu_blocked_in_retire` ~0.

The four replay buckets named in the earlier 122 ms/frame reading are
`RS_STATE` (the "rest is state" bucket), `RS_LISTEND`, `RS_FLUSH` (the
per-list flush/encoder end) and `RS_TABLES` (argument-table building inside
every draw/dispatch, `mad_air_build_tables_ex`). Which dominates in-world is
exactly what the run did not capture. **Armed for the next run:** set
`replay-split = 1` in `madeira.cfg` (zero-cost when off; `[perf] replay
split per frame` every 5 s) and keep thread sampling on, so the split pins
the bucket and the sample pins the ARM64 worker instructions inside it. Then
fix against that split; the thermal finding (§9.18: per-frame CPU work is a
heat budget — P-core share falls 61.8 % -> 0.7 % over 8 minutes) makes every
saved CPU cycle a sustained-FPS win.

### 9.25 `ml1312+` — Settings AV: the object behind it, its vtable, and the corruption signature (2026-11-26, offline from the shipped binary)

The fault (`[fault_rip] rip=...b0130 (fh6.exe+0x3600130) addr=0x10`, `x86 @rip:
48 83 ec 18 33 c0 48 89 02 ... 48 8b 81 98 15 00 00 lock inc [rax+8]`) is now
fully characterized against the game binary (the local CrossOver copy is
byte-identical to the device's — same 184,268,248-byte build).

**The faulting block is an inlined `shared_ptr` copy into an sret return:**
`rcx` = object, `rdx` = return buffer; it copies `this+0x1590` (ptr) and
`this+0x1598` (control block) and does `lock inc [ctrl+8]` (`_Uses`). The
crash state is `ctrl == 8` — a pointer-sized field holding a small integer —
so the increment writes to address `0x10`. The two stores to `*rdx` complete
first, so the caller's return buffer is valid.

**Reachability is exhaustively bounded** (whole-binary scans):
* The getter (`0x3600130`) is referenced by exactly one vtable slot in the
  image: `+0x688` (slot 209) of the 234-slot vtable at RVA `0x6a982a8`
  (preceding `.rdata` names: `AsyncCompute::Delegator`, `CommandListRecorder`).
* No direct calls or jumps reach it, no rip-indirect slot holds its address,
  and exactly two `call [reg+0x688]` sites exist: `0x36008c7` and `0x41c2f27`.
* **Neither site's slot-209 signature matches the getter.** Site `0x36008c7`
  dispatches `(this)` and consumes the result as a `uint16`; site `0x41c2f27`
  dispatches `(this, uint32 f7b0, bool 1)` on a sub-object. For the getter to
  run, `rcx`'s vptr at fault time pointed at a vtable its caller was not
  compiled against.

**Writers of `+0x1598` found in `.text`** (complete): the getter's two reads,
one qword store in a constructor-like region (`0x49a0182`, storing `r14`,
followed by `memcmp(&f15a0, &f1598, 8)` — a self-check, not an init), two
**32-bit** stores (`0x49a07bb`, `0x49a07ee`, `mov [rbp+0x1598], r14d`) in a
region that reads the same field back as an `int` and scales it into a double
(a ticks/duration-style member), and one read. The 32-bit int use of the same
offset by a same-sized sibling class is exactly what a **recycled heap block**
leaves behind: a stale `8` in the shared_ptr control slot.

**Hypothesis set for the next run** (all fit the static evidence; the fault
record discriminates):
1. **Use-after-free:** the object was destroyed and its block reused by the
   int-at-`+0x1598` class; a stale pointer dispatched through the stale vptr
   region — but the vptr survived or was re-written.
2. **Constructor race:** another thread dispatched slot 209 before the
   `shared_ptr` member was initialized (the ctor zeroes/sets the pair late).
   Our FEX scheduling can make this race deterministic where Windows rarely
   loses it.
3. **vptr corruption:** a write went to the wrong place (dropped/misrouted
   store in our stack) and the object's first qword or the member pair got
   clobbered.

**On-device discriminator:** the fault record's `rcx`/`rdx`/`rax` and which
site's frame is on the stack (the `uint16` consumer vs the `Update` caller)
name the dispatch path; a watchpoint/log at `+0x1598` writes (`0x49a0182`,
`0x49a07bb`, `0x49a07ee`) names the writer. `signal_arm64_ios.c` `ml1312`
already prints the object's vtable slot count and first slots at fault time —
extend it with the caller-frame RVA to settle 1 vs 2 vs 3.

### 9.26 `ml1326` — table-cache: the same-state draw re-uses the previous draw's argument tables (2026-11-26, offline fix against §9.24's RS_TABLES bucket)

§9.24 put "the rest of ExecuteCommandLists is the replay itself" and named
the buckets the next run will split. One of them needed no split to act on:
`RS_TABLES`, `mad_air_build_tables_ex` "inside every draw/dispatch" — the
build takes fresh zeroed ring slots for the constant-buffer and argument
tables, resolves every shader binding through the root signature
(`mad_air_resolve`), and copies root constants into a ring slot of their own.
FH6's draw bursts pay that for byte-identical tables: `draw-dedup` already
elides 123 of 410 state sets a frame, which only happens when consecutive
draws really do repeat state — and a repeated state resolves to the same
table bytes.

**The fix** (`table-cache`, madeira.cfg, default 1): the cache remembers each
build's ring offsets in `struct mad_exec` (8 entries, so the vertex/fragment/
tessellation/compute tables of a draw burst do not thrash), and a later build
with the same key returns those offsets instead of building. The draw then
re-binds the same table offsets — `draw-dedup` elides those binds too. The
cache is scoped to one list replay, so the offsets it returns always live in
this list's ring chunks (pooled, GPU-lifetime aware).

**Correctness is entirely invalidation**, and both halves are exhaustive:

* **Replay state** (the root signature, `root[]`, `consts[]`, the heaps): the
  only writers on this thread are seven replay commands (`MC_ROOT`,
  `MC_ROOT_CONST`, `MC_ROOTSIG`, `MC_CROOT`, `MC_CROOT_CONST`, `MC_CROOTSIG`,
  `MC_HEAPS`), each bumped into `tc_gen`. The cbv-snapshot and static-cbv
  transformers write only stack copies of the root array — the builds take
  the arrays themselves, which those never touch.
* **Descriptor contents** (what a table resolve reads out of the bound heaps,
  the UAV-counter map, the typed-view registries): every writer is the
  application thread through `Create*View` / `CopyDescriptors*` — the six
  functions that already carry the `mad_dg_write` desc-guard marker — each
  bumps `g_desc_gen`, and a hit is refused whenever anything moved since the
  build. The generation is sampled *before* the body reads any descriptor, so
  a write landing mid-build conservatively invalidates.

A build that fails is never cached (the failure diagnostics run again);
skin-check frames and `dump-tables` builds run the body every time. Nothing
about a draw's GPU work changes: the tables are the same bytes at the same
addresses, only built once.

**Verification on device** (queued with the §9.24 replay-split run): the
`ml1326` line every 3000 lists reports `table-cache N reused, M built`; the
same run's `replay split` line shows RS_TABLES against the previous run's
share, and the frame-graph should show the worker busy time falling from
13.96 ms toward the 1 ms Metal-submission floor. `table-cache = 0` restores
the old behaviour in one line if anything diverges.
