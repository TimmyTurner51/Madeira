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
