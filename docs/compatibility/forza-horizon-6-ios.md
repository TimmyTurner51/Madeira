# Forza Horizon 6 — iOS launch record and current blocker

Status: **not yet playable on iOS.** The game loads, runs a large part of its own
code, and then dies on an illegal instruction inside one of its own protected
functions. This document records measured evidence only; it is not a
compatibility report and makes no performance claim.

Device: iPhone 17 Pro, game through LiveContainer inside Madeira, Steam build
`forzahorizon6.exe` (app `2483190`), ARM64EC under FEX.

## The `#UD` on a function entry is the protection's own mechanism

This is the single most important thing to get right, because it inverts the
obvious reading. `build/wine-patches/README.md` already records the same shape
at RVA `0x537099C`:

> the anti-tamper read its own imports as hooked, set its tampered flag, and then
> declined the `#UD` its own encrypted function prologues raise, so the VEH
> returned `CONTINUE_SEARCH` without decrypting.

So an entry that begins with an undecodable byte is **not** by itself evidence
that nothing was ever decrypted. It is the protected image's normal form, and the
`#UD` it raises is the trigger the protection uses to decrypt that function on
first call. The current fault is the same class of event as the one that was
solved, one function over.

Supporting measurements:

- The image's first executable section is 7.740 bits/byte and 5,985 functions
  begin with bytes that are not a valid 64-bit instruction.
- Each of those still decodes from a later byte, and the section's
  `UNWIND_INFO` `prolog_size` accounts for the scrambled prefix exactly
  (`5 + 27 = 32` at RVA `0x537099C`).
- At RVA `0x53749D0` memory and the file both hold
  `d4 7d f5 82 cb 91 0b 1f 93 42 01 82 48 8b f8 48`. `0xd4` (`AAM`) is invalid
  in 64-bit mode, so FEX decodes one byte and reports
  `Invalid instruction in entry block`; real code (`48 8b f8`, `mov rdi, rax`)
  begins at `+0x0b`.
- Plenty of the image plainly does execute: the process installs and enters SEH
  handlers at `forzahorizon6.exe+0x5A66460` and `+0x5EAA3B8`.

## The exception reaches the game and is declined

The `#UD` is not lost in Wine's exception path. The run logs, in order,
`Passing through exception`, `[exc] ml811 code=c000001d addr=000000012D3709D0`,
both of the game's own handlers (located by `[seh-xlate]`), and only then Wine's
unhandled filter (`[unwind-root] ml633 … unhandled-exception filter frame`).
`[SEH_RATE] n=1` confirms a single dispatch: the handler returned, and it did not
resume execution at the faulting address.

So the question is not "why did Wine lose the exception" but "what did the
protection decide, and on what evidence".

## The failure is at 4.5 s, before the anti-tamper's own check batch

Timing puts the decline earlier than the documented integrity checks:

| Event | Wall clock | Relative |
|---|---|---|
| `[steam-start] app=2483190 direct source=steam` | `10:06:23.389` | t+0.0 s |
| `Invalid instruction in entry block: 12D3709D0` | — | — |
| `[exit-report] status=0xc000001d` | `10:06:27.903` | **t+4.5 s** |

`fh6_linux_handoff2.md` records that "FH6's anti-tamper runs a batch of checks
about 7 seconds after launch". Dying at t+4.5 s means that batch never ran, so
whatever declined the exception is an earlier gate — the initial licence/DRM
validation, not the post-startup integrity sweep.

Nothing has been decrypted at that point, and nothing has been asked of Steam:
the run loads `steam_api64.dll` and resizes it into the pool, and then does
nothing further with it. No Steam client IPC appears anywhere in the session.

For contrast, in the reference build this same `#UD` is handled and the game
reaches a real window: compositor logs show the window renamed to
`Forza Horizon 6` at `08:21:38`, ~57 fps of splash frames, then the documented
stall. So the `#UD` is survivable; it is the decision around it that differs.

## Candidate causes, ranked, with what would settle each

### 1. The launch path never asks Steam for a licence (highest confidence)

The launch in use starts the executable itself:

```
[steam-start] app=2483190 direct source=steam args=0 folder=program
[steam-start] direct start: the game's own Steam identity (app 2483190) published
```

That is `LibraryEntry.steamStart == "game"` (`SteamDirectStart.mode`), the mode
`SteamGames.swift` documents for "games that do not need Steam (DRM-free ones)".
It publishes `SteamAppId`/`SteamGameId`/`SteamAppPath` and runs the exe.
`steam_api64.dll` loads, but no Steam client process exists in that session, so
there is nothing to authenticate against and the licence question is never asked.

The prefix holds the app manifest and the client but no stored sign-in, and no
retained Madeira log contains `dockhost`, `steam-host` or `steam-signin`:

| Check | Result |
|---|---|
| `.../Steam/config/loginusers.vdf` | absent |
| `.../Steam/config/ssfn*` | absent |
| `.../Steam/steamclient64.dll` | present, SHA-256 `71b391fe…ecf640` |
| `.../Steam/steamapps/appmanifest_2483190.acf` | present |

`loginusers.vdf` is written by the full client UI, which Dock deliberately does
not run, so its absence is supporting detail rather than proof. What matters is
that Dock is the only path that populates the client's licence cache — an online
logon precedes any offline logon — and Dock has never run here.

The faithful path already exists and is verified against this exact client build:
`docs/MADEIRA_DOCK.md` has `dockhost.exe` load Valve's own `steamclient64.dll`,
sign in with the user's own Steam sign-in, and start the game with Valve's
`LaunchApp` — "Valve's client performs the online authentication and the licence
check. The game, its Steam API calls and any DRM run exactly as Valve ships
them." It is explicitly not a DRM bypass and fails closed without a licence.
`madeira-dock/docs/CLIENT_LAYOUTS.md` lists `71b391fe…` as its January adapter,
so the hash check will not reject this prefix.

The reference build this is compared against (FEX ARM64EC inside Proton on an
ARM64 Android device) reaches gameplay and starts the game the same way —
through the signed-in Steam client, with its UI running — never by spawning the
executable.

### 2. iOS-specific rewrites of module `.text` that Proton never makes

Proton/Android has no reason to modify module code. Madeira on iOS does, because
`x18` is reserved by the platform and cannot appear as a general register:

```
[x18-patch] ml1005 text=0x1533d4000+0x780a5 (rw=0x700b3d4000) patched=744 skipped=0 …
```

That is 744 rewritten instructions in ntdll's own `.text` (the pool copy at
`0x1533d4000`, i.e. the copy the guest executes). On a conforming machine every
module reports a zero diff — that is exactly what the conformance probe's
`TextDiff` measures, and what the reference run shows for every module:

```
module  1 ntdll.dll  … text=75bd0 diff=0 first=ffffffff
module  2 kernel32.dll … text=32310 diff=0 first=ffffffff
```

**This does not apply to the game's own `.text`, which is the section the
protection is most likely to hash.** The patcher skips any image that is not
ARM64 and has no `.a64xrm` section (`virtual_ios.c`, "skipping x18 patcher for
non-ARM64 PE"), and `forzahorizon6.exe` is a pure x64 PE that FEX emulates. The
lowest patched copy in the run is ntdll at `0x1533d4000`; the exe's copy spans
`0x148005000`–`0x14E3A1CE3`, untouched. The loader's `DllBase` also points at
the unmodified PE copy, so a module-integrity check that starts from `DllBase`
sees the file's own bytes.

This is therefore a real faithfulness divergence from Proton, but a weaker
suspect for a decline that happens at t+4.5 s, before the integrity sweep runs.

### How to settle both at once

The probe that answers this is already written and has a reference answer from a
machine where the game runs (`fh6conf.exe`, source `fh6conf.c`). Run it inside
the same Madeira session as the game and diff against the reference:

- `watch …` lines: `GetWriteWatch`/`ResetWriteWatch` semantics per write kind.
- `module …` lines: per-module `.text` bytes in memory versus the file on disk —
  the `diff`/`first` columns, which must be `0`/`ffffffff`.
- `export …` lines: the first 16 bytes of ~50 security-relevant exports.
- `cpuid`/`timing` lines: hypervisor bit, TSC rate versus `QueryPerformanceCounter`.

The `diff` column is the direct test of candidate 2, and the reference values are
`/Users/timmycraft/Library/Application Support/Cursor/AgentStores/u289638033/files/fh6_linux_conf2.txt`.

## 2026-11-15 10:33 — Dock launch: the licence path works, a pool limit is next

Routing the game through Madeira Dock instead of a direct spawn changed the
picture completely. Valve's own client, running headless in the session,
authenticated online and authorised the launch:

```
[dock-report] session-authenticated-online=1
[dock-report] session-requested-app-entitled=1
[dock-report] session-requested-app-listed=1
[dock-report] session-offline-ready=1
[dock-report] launch-request-submitted=1
[phase] spawn:L"...\ForzaHorizon6\forzahorizon6.exe" t+ 10.639s
```

That settles candidate 1: given a real, authenticated Steam session the
protection's prerequisites are met, and the game is started by Valve's client
with Valve's own `LaunchApp`. The Dock's own report ends with
`launch-client-error=46`, but that is downstream of the real failure — the
process exited within a second of being created — not a refusal to authorise.

The real failure is the pool, and it is arithmetic:

```
ml985: preferred base 0x140000000+0xb3c0000 REFUSED status=0xc0000018
[jit-pool] EXHAUSTED (image 0x132050000+0xb3c0000): want=0xb3c0000
           bump=0xba44000/0x20000000 tail_resv=0x11004000 freelist=0
wine: failed to start ... c0000017
```

- The pool was **512 MB**, not the 896 MB standard: a Dock launch defaults to the
  compact pool (`DockPerformancePolicy.compactPoolMB`), on the assumption that a
  headless client needs less.
- Valve's client had already spent **186 MB** (`bump=0xba44000`) of it on its own
  image copies before the game loaded.
- FEX's code buffers held **272 MB** (`tail_resv`).
- The game's own image copy wants **180 MB** (`0xb3c0000`, its `SizeOfImage`),
  because TXM cannot execute anything except from a debugger-allocated pool, so
  the main image is copied whole.

186 + 272 + 180 = 638 MB against a 512 MB pool, so the copy fails and the load
dies with `STATUS_NO_MEMORY`. Direct-spawn runs never hit this because the game
loaded first, into an empty 512 MB pool (`used=0xb3c4000` right after its copy).

The fix is the game's own config, which wins over both the compact-pool default
and `madeira.cfg`:

```
pool = 896
pool-split = 1
pool-pair = 1
pool-low = 1
```

The pool census at launch found no single run big enough for 896 MB, but three
usable runs — `0x1301a4000+254MB` (below the executable window),
`0x148000000+598MB` and `0x16ddc0000+290MB`. `pool-pair` takes the two above the
window as one split pool (≈888 MB), and `pool-low` moves FEX's code buffers to
the run below the window so the pool above is left to image copies. Either
mechanism alone covers the 638 MB; together there is margin.

Nothing about this touches the game: it is the same exe, unmodified, launched by
Valve's client, and the pool is Madeira's own execution substrate.

## 2026-11-15 10:40 — the game loads and executes, and refuses to decrypt

With the pool sized correctly the load succeeds and the game runs its own code:
it installs SEH, creates threads, executes at RVAs `0x9E629C` and `0x5BFD6F6`,
and calls into `0x537099C`. The `[ud-decrypt]` probe added in `c46ce86` then
answers the question it was built for:

```
[ud-decrypt] EC handler declined at 0000007069B7099C: BYTES UNCHANGED
             (eae96be61448897c) -- the protection never decrypted this function
```

Two runs reproduce it byte for byte, so it is deterministic and not a race. The
bytes are the shape already documented above: five scrambled bytes, then a real
prologue from `+5` (`48 89 7c 24 10` `mov [rsp+10h],rdi`, `55` `48 8b ec`, …),
matching the `prolog_size` of 32 that `.pdata` gives for this function. So the
exception is raised exactly where it should be, at the encrypted prefix, and the
protection is reached and declines.

That separates the two causes the probe was designed to distinguish. The
protection is not failing after a successful decrypt; it is deciding not to
decrypt.

### The remaining infidelity: the image is not at its preferred base

```
ml985: preferred base 0x140000000+0x70000 REFUSED status=0xc0000018
[main-exe] NOT_AT_BASE (relocated) — continuing normally
Load module forzahorizon6.exe: 7064800000
```

The executable window that Madeira reserves at `0x140000000` is 128 MB, but this
image's `SizeOfImage` is `0xb3c0000` (180 MB), so it does not fit and the loader
relocates it to `0x7064800000`. Every other platform this title runs on — the
DroidDeck Proton/ARM64EC build included — loads it at `0x140000000`. A
self-decrypting protection that is otherwise content to run relocated is a
weaker assumption than it looks: its decryptor and its integrity values are
derived from the image it was built as, and this build has never been asked to
run anywhere else.

`exe-window-mb` exists for exactly this and is read from the game's own config,
so it needs no rebuild:

```
exe-window-mb = 192      # 0x140000000 + 192MB = 0x14C000000, ends below the 0x180000000 ceiling
```

`pool-low` was dropped at the same time. Region C fragmented: it was carved to
160 MB (224 MB in the previous launch), FEX asked for 128 MB buffers, and the
log records `region C has 0xffc000 of 0xa000000 left, not enough for carve
0x8000000`. Inside an 864 MB pool the image copies take 366 MB, leaving over
490 MB for the tail, so a dedicated low region buys nothing and costs
contiguity. The pool becomes 810 MB with the wider window, still far above the
638 MB that failed.

### Why the auto-widening did not fire — and then did

As checked in, `StikJITHelper.fixedBaseWindowMB` only widens for an image whose
relocations are stripped (`characteristics & 1` or an empty relocation directory).
This exe reports `chars=0x22` with a `0x2b1ac0`-byte `.reloc`, so that measurement
returns nil: `0x22 & 1 == 0` and `relocSize != 0`, and the function computes nothing.

The installed build nevertheless widened to exactly the value that measurement would
have produced — `ceil(0xb3c0000 / 16MB) * 16 = 192` MB — and the game's entry carries
no `exe-window-mb`, `pool`, `pool-split` or `pool-pair` key. So on device the sizing is
arriving from Madeira itself rather than from a hand-edited key, and the guard in this
tree is stricter than what produced the successful run. That discrepancy is recorded
rather than resolved: the window is 192 MB and the image loads at its base either way,
and the per-game key remains the explicit override if the automatic path ever stops
covering this image.

### The next question: is the decryptor in the chain at all

`[ud-decrypt]` proves the protection declined. It cannot say *why*, and the two
possibilities need opposite work:

- the protection's decryptor is not registered as a vectored handler at all —
  a Wine/ARM64EC registration problem, ours to fix;
- it is registered and declines deliberately — a verdict, and the remaining
  difference is the environment, not the handler machinery.

That distinction is invisible in a log by construction. A decryptor must be a
**vectored** handler, because only a vectored handler runs before the frame-based
walk and can resume at the faulting address. But `call_vectored_handlers`'s
per-handler lines are `TRACE` and Madeira captures no trace channels (`rg 'trace:'`
over a full session log returns nothing), so an empty chain prints exactly what a
chain of declining handlers prints.

`[veh-chain]` (`0006`) reports the chain length once per process, names the empty
case explicitly rather than printing `0 handler(s)`, and then reports every
handler's verdict with `CONTINUE_EXECUTION` called out as "decrypted, resuming".
It walks the list under the critical section the caller already holds — taking it
again would deadlock inside exception dispatch — bounded to 32 entries, and
allocates nothing.

If the chain is empty, the next step is Wine's `RtlAddVectoredExceptionHandler`
path on ARM64EC. If it is populated and declining, the handler machinery is
exonerated and the environment is the whole question.

### Relocation is refuted; the fault is a deliberate `#UD` trap

The image now maps at its preferred base, and relocation is refuted as the cause of the
decline. The window that allows it is 192 MB, and the log names the mechanism:

```
[exe-window] widened to [0x140000000,0x14c000000) 192MB for a large fixed-base image (exe-window-mb); the pool is placed above it
ml977: executable window [0x140000000,0x14c000000) is reserved
Load module forzahorizon6.exe (forzahorizon6.exe-7352369b5ed8f54b): 140000000
Invalid instruction in entry block: 14537099C
```

The fault moved from `0x7069B7099C` (pool copy) to `0x14537099C` (the image itself)
and stayed at RVA `0x537099C` — the same RVA in every run at every base, which is what
a deliberate trap looks like.

**The five bytes are invalid in the file, not just in memory.** `EA E9 6B E6 14`
sits at `0x537099C`, and `EA` is `JMP FAR`, invalid in 64-bit mode. `.pdata`
confirms `0x537099C` genuinely is a function start (not a misaligned entry), and
5 bytes later a textbook MSVC prologue begins (`mov [rsp+0x10],rdi; push rbp;
mov rbp,rsp`) followed by an `/GS` cookie load.

That is not one damaged function. Of 414,805 `.pdata` function starts, **4,538
begin with `EA`** and 247 distinct 5-byte prefixes cover all of them — `EAC704BED2`
alone accounts for 2,693. Short, repeated, and structured: the protection
encrypts function prologues and expects its own handler to catch the `#UD`,
decrypt the prologue and resume.

### The handler that should decrypt is not there

`[veh-chain]` answers the question the log could not: at the moment the `#UD`
lands, the exception chain holds **exactly one handler**, and it is not a
decryptor.

```
[veh-chain] ml1251 #1 code=c000001d addr=000000014537099C tid=00e8
[veh-chain] ml1251   #1 handler=00000001453CD858
[veh-chain] ml1251 handler 00000001453CD858 -> 0 (CONTINUE_SEARCH: declined)
[ud-decrypt] EC handler declined at 000000014537099C: BYTES UNCHANGED (eae96be61448897c)
```

Static analysis of that handler (it is a `jmp` thunk to `0x1453D9270`) shows
what it is: it reads `Dr7` and `Dr0`–`Dr3`, decodes the exception code with
`code = 2*(record->code ^ 0xF58AD36680AB1CF9)`, and compares against the two
values that decode to `0x80000003` (`STATUS_BREAKPOINT`) and `0x80000004`
(`STATUS_SINGLE_STEP`). It is a hardware-breakpoint harness. Declining a `#UD`
is correct behaviour for it, so the chain is not malfunctioning — it is simply
missing the handler that matters.

Two things follow, and they need opposite work:

- the decryptor was never registered — a loader or import problem, ours;
- it was registered and removed — a lifetime problem.

`BYTES UNCHANGED` also rules out the other half: the protection never wrote to
`.text` at all. No `VirtualProtect`/`NtProtectVirtualMemory` call in the whole
session touches the image range, so there is no decryption pass that ran and
failed. `[veh-add]` (0007) watches registrations, because a handler added and
taken away again is invisible in the chain at dispatch time.

### The Android reference config, for comparison

The DroidDeck package for the same title documents the environment that does
reach the menu, and its troubleshooting table has no entry for `#UD` or invalid
instructions at all. It relies on `FEX_SMCCHECKS=full`, `FEX_HIDEHYPERVISORBIT=1`,
`FEX_MULTIBLOCK=1` and a set of FH6-specific FEX options. Measured against this
tree:

| Option | Android | This tree |
|---|---|---|
| `FEX_FH6_FASTUD` | `1` | absent |
| `FEX_FH6_UDINPROC` | `0` | absent |
| `FEX_POOL_CLONE` | `1` | absent |
| `FEX_SKIP_SRA_FLUSH` | `0` | absent |
| `FEX_FH6_STATS` | `0` | absent |
| `FEX_SMCCHECKS` | `full` | present |
| `FEX_DYNAMICL1CACHE` | `0` | present |

`FEX_FH6_FASTUD=1` raises `#UD` through the syscall handler instead of the host
signal path, which matters here because this port's host signal path is the part
that has needed the most repair. It does not by itself explain a declined
verdict — the handler ran either way — but it is part of the configuration known
to work, and this tree cannot express it.

### How the game expects to be told about the `#UD`

This is now the crux, and the answer is not "a vectored handler registered by name".

The exe's import table contains **no** vectored-exception API at all, and the string
`AddVectoredExceptionHandler` does not appear anywhere in the 175 MB binary (nor does
`RtlAdd…` or `RemoveVectored…`). The only exception-registration APIs it imports are
`SetUnhandledExceptionFilter` from `KERNEL32.dll` and `UnhandledExceptionFilter` from
`api-ms-win-core-errorhandling-l1-1-0.dll`.

Yet `[veh-chain]` found a handler inside the exe itself (`0x1453CD858`, RVA
`0x53CD858`), so one is registered without a name — resolved by hash, as protections
do. That handler is the `Dr7` harness and it declines, correctly.

Where the walk actually went is visible in `[seh-xlate]`: for the faulting thread it
invoked exactly two handlers, `forzahorizon6.exe+0x5eaa3b8` and then ntdll's terminal
root. `0x5eaa3b8` disassembles to `ff 25 …` — an **import thunk**, i.e. the frame walk
resolved the game's handler to `UnhandledExceptionFilter` and called it, and it
declined. So the game's frame-based and unhandled-filter paths both exist and both
said no; nothing decrypted.

### What is not the cause

Two plausible explanations were tested and rejected, which narrows the search:

- **A fixed 5-byte stub.** `0x537099C` has a textbook MSVC prologue with an `/GS`
  cookie load exactly 5 bytes in, which invited the theory that the trap is a constant
  5-byte prefix the handler skips. Across all 4,538 `EA`-starting functions only
  **one** has a recognisable prologue at `+5` (and at `+1`…`+9` the counts are 0–12 of
  4,538). So it is encryption, not a fixed stub that can be stepped over.
- **A failed DLL load.** The game's process window has exactly two `[dll-missing]`
  entries, `Kerberos.dll` and `MSV1_0.dll`, both authentication-related and irrelevant
  to the protection. The 42 `c0000135` and 16 `c000007b` failures in the session all
  belong to Steam's webhelper and `SDL3.dll`.

### The allocation shape just before death

Between module load and the fault the game issues a storm of failed allocations —
28,416 attempts, sampled into 523 log lines — of exactly one shape:

```
[alloc-fail] ml814 #28416 status=c0000018 hint=0x70512c1000 size=0x1001000 type=0x3000 protect=0x40
                              | STAGE=fixed-map err=3
```

`type=0x3000` is `MEM_COMMIT|MEM_RESERVE`, `protect=0x40` is `PAGE_EXECUTE_READWRITE`,
the size is 16 MB + 4 KB, and `err=3` is Mach's `KERN_INVALID_ADDRESS` at the hinted
address. The hints step by `0x40040000`, so this is the protection probing for a free
16 MB RWX slot. Failing a hinted `VirtualAlloc` whose address is taken is correct
Windows behaviour, so the failures themselves are not a bug — and the probing does
succeed twice (`0x704b2b0000`, then `0x70692d0000`).

The successful one is worth noting, because it is the last thing in the log before the
fault and this port deliberately refuses `PROT_EXEC` on it:

```
[guest-rwx] #1 0x70692d0000+0x100c000 prot=rwx — anonymous guest memory, EXEC is FEX bookkeeping; applying rw- instead
Add SMC interval: 70692D0000 - 706A2DA000
```

That downgrade is architecturally sound here (FEX reads guest bytes and never executes
them at the guest VA), so it is recorded as a correlation to rule out rather than
presented as the cause.

### The emulator was announcing itself to the protection

The encipherment is confirmed structural, not incidental. Of 414,805 `.pdata`
function starts, 4,538 begin with `EA`, but only **247 distinct 5-byte prefixes**
cover all of them and the most common covers **2,693** — and neighbouring functions
carry byte-identical 13-byte prefixes. Per-function encryption cannot produce that;
repeated ciphertext under repeated plaintext is the signature of a **block cipher in
ECB mode**, applied over roughly the first 8–11 bytes of each prologue (the distinct-
prefix count is flat at 8 bytes and jumps by 9× at 12). So the file holds ciphertext,
the protection must decrypt it at run time, and it declined.

That reframes the question. A protection declines for a reason, and FEX was handing it
an unusually loud one. `FEX_HIDEHYPERVISORBIT=1` is in this game's environment and was
doing what it advertises — clearing `CPUID.1[31]`, the "a hypervisor is present" bit —
but the `0x40000000` range was **not** gated on it:

```
CPUID.4000_0000h  eax = 0x40000001, signature "FEXIFEXIEMU"
CPUID.4000_0001h  eax[3:0] = 2   ->  "the host architecture is AArch64"
```

while leaf 1 said no hypervisor existed. No real machine answers both ways, so the
inconsistency was itself the fingerprint — and a stronger one than the bit it was
trying to hide, because emulator detection asks these leaves precisely because they are
trivial to read. An anti-tamper that sees `FEXIFEXIEMU` and `AArch64` reaches an
unambiguous verdict and stops decrypting, which is exactly the observable: ciphertext at
a prologue, unchanged, with no `#UD` handler willing to decrypt it.

`ml1253` gates the whole range on `HideHypervisorBit`, so with the option on both leaves
answer all zeros — the shape a real CPU gives an unimplemented leaf — and with the
option off nothing changes. This makes the emulator stop volunteering that it is an
emulator; it does not weaken, skip or disable anything the game checks. It is the same
class of fix as the hotpatch import thunks: make the ARM64EC runtime behave the way
native x64 Windows does.

## ⛔ RETRACTED (2026-11-15 11:53) — `ml1253` was never validated

**The section below is wrong and is kept only to record the mistake.** It claimed the
11:04 run proved that hiding the hypervisor leaves made the protection decrypt. That
run never executed a single instruction of the game:

```
[jit-pool] L"...\libxess.dll": no JIT-pool copy for executable section .text
00e8:err:process:NtTerminateProcess ... exit_code=0xc0000135     <- STATUS_DLL_NOT_FOUND
```

`libxess.dll` is a static import, so the loader failed and the process exited before its
entry point ran. There was no `#UD` because there was no execution — not because the
protection decrypted. Every `[seh-xlate]` line in that log belongs to `rpcrt4`, `sechost`,
`kernel32` and `kernelbase`, i.e. Wine's own modules from earlier processes; none is the
game. The "99 s to 24 threads at IPC 3.39" is Wine's services and Steam's webhelper.

The measurement that settles it is the protection's own probing, which is present only
when the game runs:

| Run | `libxess.dll` | `[alloc-fail]` | `c000001d` |
|---|---|---|---|
| 11:04:31 | EXHAUSTED — load fails | **1** | 0 |
| 11:17:59 | pool `0x16bc7e000` | **507** | 10 |
| 11:37:38 | pool `0x16776a000` | **507** | 10 |

Absence of a fault in a process that never ran is not evidence of a fix. The `#UD` at
RVA `0x537099C` has been present in **every** run that reached the game's code, before
and after `ml1253`.

## Next blocker: the JIT pool cannot fit `libxess.dll`

The process now dies for an ordinary reason, and not a crash:

```
[jit-pool] EXHAUSTED (image 0x71ea600000+0x4a3b000): want=0x4a40000 bump=0x1b768000/0x33818000
           tail_resv=0x10000000 freelist=0
[pool-capacity] failed_want=0x4a40000 entries=0 free_bytes=0x0 main_virgin=0x7898000 ...
[jit-pool] L"...\libxess.dll": no JIT-pool copy for executable section .text -- the load fails
00e8:err:module:import_dll Loading library libxess.dll (which is needed by ...forzahorizon6.exe) failed
[Wine ntdll/server] process_exit_wrapper(-1073741515)      <- STATUS_DLL_NOT_FOUND
```

`libxess.dll` is a **static** import of the exe, so the load must succeed. It needs
`0x4a40000` (74 MB) **contiguous**. The pool is one 824 MB span that the app splits with
an 8 MB hole (the main thread's stack) at offsets `0x1F000000..0x1F818000`, and the head
has already bumped to `0x1b768000`:

| region | bytes |
|---|---|
| below the hole: `0x1F000000 - 0x1b768000` | 59 MB |
| above the hole up to `pool_limit` (`0x23818000`) | 67 MB |
| **largest contiguous run available** | **67 MB** |
| **requested** | **74 MB** |

So 126 MB is genuinely free and still unusable: the hole splits it into 59 + 67, and
`pool_limit` is `jit_pool_size - ios_jit_tail_reserved`.

### The tail took 256 MB because region C was too small to do its job

The interesting part is *why* the tail reservation reached its full 256 MB cap. Two
128 MB FEX code buffers were carved into the main pool:

```
[jit-pool] tail EC_CODE rx=0x177818000 size=0x8000000 tail_resv=0x8000000  head_used=0x9534000
[jit-pool] tail EC_CODE rx=0x16f818000 size=0x8000000 tail_resv=0x10000000 head_used=0xba44000
```

(`0x177818000` and `0x16f818000` are pool offsets `0x2B818000` and `0x23818000`.) Region C
— which exists precisely so code buffers *don't* come out of the image pool — served only
`0x4000` + 16 MB, and then reported

```
[pool-low] region C has 0x3ffc000 of 0x5000000 left, not enough for carve 0x8000000:
           it goes to the pool tail (freed C carves are still reused first)
```

Region C was 80 MB (`pool-low-margin = 128` left only `218 - 128 = 90` MB of the free run
below the window, rounded down to 80 MB) while `ios_pool_code_cap` permits a **128 MB**
buffer. One buffer could never fit, so both fell through into the pool and permanently
consumed 256 MB of image room.

`pool-low-margin = 48` gives region C 160 MB — one 128 MB buffer plus the 16 MB one, with
58 MB of the run still free. The tail then reserves 128 MB instead of 256, `pool_limit`
rises to `0x2B818000`, and `libxess`'s 74 MB lands above the hole at
`0x1f818000..0x24258000` — 117.75 MB under the limit. (The observed failure was 10.25 MB
short of `0x23818000`, not the 12.5 MB first estimated: the extent is `0x1f818000 +
0x4a40000` = `0x24258000`, and `tests/host/check-fh6-pool-geometry.py` pins every value
here by running the allocator's own helpers.)

A 96 MB big-image slot (`MADEIRA_POOL_BIG_SLOT_MB`) looks like the obvious answer and is
*not* safe here: it widens the effective hole to `0x25818000`, and the second 128 MB tail
carve then moves from `0x23818000` down to `0x17000000` — below a head cursor already at
`0x1b768000`, inside the region the bump is walking through. The bump check tests only
`pool_limit` and the holes, so it would run into a live code buffer. That test asserts this
too, so a future change cannot quietly reintroduce it.

## Conclusion

Three blockers have been retired. The ARM64EC import-slot mis-route is not
present in a current run. The licence gate is real and is now satisfied: with
Valve's client authenticated, the client itself starts the game. And the pool is
no longer a limit, once sized for a Dock session that has already spent 186 MB
on Valve's own image copies.

The live blocker is the protection's decision, and it is now measured rather than
inferred: it is reached, it is asked to decrypt `forzahorizon6.exe+0x537099C`,
and it leaves the bytes untouched. The only structural difference from every
platform this title is known to run on is that the image is loaded 5.4 GB away
from the base it was built for.

Nothing here requires modifying the game, and doing so is excluded: the
protection is meant to run exactly as shipped.

## Next measurement

With the image at its preferred base, `[ud-decrypt]` is the whole verdict:

- `DECRYPTED` — the protection accepted the environment and wrote plaintext; the
  next blocker is whatever executes afterwards.
- `BYTES UNCHANGED` — relocation was not the objection either, and the remaining
  suspects are the ARM64EC session itself (an ARM64EC host running pure-x64 guest
  code is not the Proton arrangement) and the platform rewrites of module
  `.text`.

## 2026-11-15 11:37 — the Android FEX preset changes nothing measurable

This entry first claimed the preset re-broke decryption. **That was wrong, and the
mistake is worth keeping**: it compared the 11:37 run against the 11:04 run, which
(see the retraction above) never executed the game, so it had no `#UD` for reasons that
have nothing to do with any environment variable.

The run that settles it is 11:17, which had **no** `env.FEX_*` line at all and behaves
identically to 11:37:

| Session | `env.FEX_*` | `[alloc-fail]` | `c000001d` |
|---|---|---|---|
| `11:17:59` | none | 507 | 10 |
| `11:37:38` | the full Android preset | 507 | 10 |

Same fault, same address, same count. So the preset is neither a fix nor the cause, and
the environment it sets is not what the protection reads. It has been removed from
`f19a86ea48b779e2.cfg` anyway — not because it hurt, but because it was never shown to
help, and a shorter environment is one less variable. The file records this.

Nothing here weakens what the protection checks, and `FEX_HIDEHYPERVISORBIT=1` remains
FEX's default behaviour on this host. What is now out of the sandbox is the claim that
the hypervisor leaves were ever the reason for the decline: `ml1253` is still a
reasonable change, but it has no measurement behind it.

### Correcting the size of the enciphered set

The record above counts 4,538 functions "beginning with `EA`". `EA` is only one of
the byte values that cannot start an x64 instruction, so that number undercounts
what has to be decrypted. Testing every `.pdata` function start against the full
set of x64-invalid first bytes gives:

```
.pdata functions: 414805
unexecutable entry byte: 22758 (5.5%)
first byte: 0xEA×4538, 0xCE×1625, 0xD6×1623, 0xD5×1599, 0x60×1328, 0x16×1252
pages containing a bad entry: 10017
  pages where EVERY function is bad : 229
  pages where only some are bad     : 9788
```

5.5 % of functions, scattered over 10,017 pages of which only 229 are fully
unreadable. That is per-function encipherment, not whole-page encryption, which is
consistent with the ECB-over-the-prologue reading (and rules out "the section is
encrypted and gets decrypted in one pass", since either pass would have to touch
10,017 pages). It also sets the bar for any future claim that decryption
partially happened: it must show plaintext at some of these 22,758 entries.

### No protector in the import table, and no TLS callback of its own

Two mechanisms that could have decrypted the image before the entry point are
absent, so the decryptor has to live in the exe's own plaintext code and run from
there:

- the import table is 38 DLLs — Microsoft CRT, PlayFab, DirectX, AMD, Bink, XeSS,
  Steam — with no vendor DLL among them;
- the TLS directory has exactly two callbacks, `0x5a658c0` and `0x5a65e98`, and
  both are the CRT's own (`cmp edx,2 / jne`, `mov rax,rsp`), in the same
  `0x5a65xxx` block as the entry `0x5a66394`.

All three references to `SetUnhandledExceptionFilter` are at `0x5a664f3`,
`0x5a668f4` and `0x5a669c8` — after the entry `0x5a66394`, in the CRT's `__scrt`
path — so the filter is installed late in CRT startup rather than by the loader.
Whether that code had run by the time of the fault is not established, and the
frame walk does reach an `UnhandledExceptionFilter` import thunk at `0x5eaa3b8`,
so the filter path was exercised; what the log cannot show is whether a *guest*
filter had been registered by then.

## Known defect, not yet exercised: the x64-stub test is blind to the hotpatch shape

`build/wine-patches/0001` gives every x64 import thunk the hotpatch prologue
(`48 8d a4 24 00 00 00 00` then `ff 25 rel32`). `arm64x_check_call` was taught
that shape (`.Lhotpatch`), and `sync_hotpatched_thunks` exists to keep the pool
copy of those thunks in step with the file. Two functions that also parse these
stubs were not taught it, and the mismatch is the described shape of a mis-routed
EC import slot:

- `arm64ec_iat_slot_is_x64_export` (`wine/dlls/ntdll/arm64ec_x64_export_iat.c`)
  recognises a stub only when `image[rva] == 0xff && image[rva+1] == 0x25`. With
  the hotpatch prologue the export's first byte is `0x48`, so the test misses it
  and returns "not an x64 export stub".
- `arm64ec_redirect_ptr` decodes `ff 25` at offset 0 and the 14-byte fast-forward
  at offset 0, then falls through to `xlate_ios_jit(ptr)` — which for a stub that
  begins with the prologue returns the **pool alias** of x64 bytes.

Together: a slot whose target is an x64 export stub keeps getting redirected to a
JIT-pool address holding emulated x64 code, which is exactly what an ARM64EC
caller must never be handed. The run so far does not exercise it — the 11:37
session logs `[x64-iat]` **zero** times (no slot was ever classified as an x64
export stub), so there is no measurement to fix against yet.

The 0x90000000 / `ucrtbase.dll+0x90f1c` fault reported against this tree is the
signature this predicts (`adrp x8; ldr x16,[x8,#0x898]; blr x16` where the slot
holds a pool address). What is missing is a run that reaches it: the current
blocker is the `#UD`, and the session that clears the `#UD` is the one to read
`[x64-iat]` and `[iat-sync]` from. Fixing this without that log would be guessing
between widening the predicate (keep the stub, ml943's intent) and decoding the
prologue in `arm64ec_redirect_ptr` (follow through to the real target) — the two
differ in what the guest executes, and the second changes a hot path that the CEF
work already found booby-trapped.

## 2026-11-15 11:53 — the decryptor is never registered, and never writes

With the pool fixed, the 11:17 and 11:37 runs both reach the game's own code and both
die at the same `#UD`. Three measurements now describe that state precisely, and
together they rule out "the protection ran and declined":

1. `[veh-add]` — the registration log added for exactly this question — prints **one**
   line in each session, and it is the anti-debug harness that `[veh-chain]` sees at
   dispatch time:

   ```
   [veh-add] ml1252 #1 func=62F86DCE80000000 module=0000000000000000 ? order=first
   ```

   One registration, in a session that passes through the protection's allocation
   probing. A decryptor that was registered and removed would leave a second line,
   because the probe sits in `add_vectored_handler`, not in the chain. So the
   protection never registers an in-process exception handler beyond the `Dr0`-`Dr7`
   harness.

2. `BYTES UNCHANGED` and no `[Add SMC interval]` anywhere in the exe's
   `0x140000000+0xb3c0000` — the protection never writes a code page. So no decryption
   pass ran and failed; none was ever attempted.

3. The last thing before the fault is the protection probing for a staging area: 506
   requests of `size=0x1001000` (16 MB + 4 KB), `type=0x3000`
   (`MEM_COMMIT|MEM_RESERVE`), `protect=0x40` (`PAGE_EXECUTE_READWRITE`), at hints that
   step by `0x10001000` starting at `0x14c3c3000` — the page just above Madeira's
   192 MB executable window. 505 of 506 fail with `STAGE=fixed-map err=3`.

   That first hint is where a native x64 process would succeed immediately. Here the
   pool's own reserved runs sit exactly there (the doc's `0x148000000+598MB` and
   `0x16ddc0000+290MB`), so the protection walks through ~8 GB of Madeira's
   reservations before it finds anything, and gets two blocks to work with.

The consistent reading is that the protection's own loader stage does not reach the
point of installing its exception handler in this process, and the enciphered
prologues are simply never decrypted. Nothing observed supports "it checked and said
no": there is no registration to remove, no write to revert, and no verdict to read.

### What the next build has to answer

Both remaining questions are invisible in the current logs, so they need instrumentation
rather than another inference:

- **Was the staging area usable?** The 16 MB RWX blocks that *did* succeed are the ones
  the decryptor would live in. Whether the protection then saw them as executable is a
  `VirtualQuery`-visible property, and this port currently answers `rw-` for them (the
  `[guest-rwx]` line says so). Reporting the protection the guest *asked for* while the
  host mapping stays non-exec would close that difference without changing what executes.
- **Do the registrations include a removal?** `[veh-add]` logs the encoded pointer, so
  its `func=` value cannot be attributed to a module. Logging the decoded value and the
  removal path turns "one registration" into "this function, from this module, added and
  not removed".

## 2026-11-15 12:01 — the one handler is the anti-debug harness, and it declines by design

A clean rerun (12:01:54, same 28 build, no `env.FEX_*`) reproduced the state exactly:
`c000001d` = 10, `[alloc-fail]` = 507, fault at `0x14537099C`. That makes the counts in
this document a measurement rather than a one-off, and it let the chain entry be
identified without a rebuild.

The single handler `[veh-chain]` reports, `0x1453CD858`, is `forzahorizon6.exe+0x53CD858`,
a 5-byte jump to the real body at `+0x53D9270`. Disassembled, that body:

- reads the `ContextRecord` pointer and does `cmp byte ptr [rax + 0x70], sil` — offset
  `0x70` is `AMD64_Dr7` in the ARM64EC `CONTEXT`, i.e. the debug-register check;
- loads a lazily-initialised pointer at `+0xab88560`, calls it, stores its return into a
  flag byte, and branches on that flag before anything else;
- xors the exception code with the immediate `0xf58ad36680ab1cf9` before testint it, so
  `c000001d` is not compared in the clear.

So the earlier reading is right and now has a mechanism: this handler is the protection's
anti-debug and switch harness. It is reached and returns `CONTINUE_SEARCH` because it was
never meant to decrypt anything — the decryptor is a *different* component that never
appears in the chain (`[veh-add]` = 1, `[veh-remove]` = 0).

### The staging block is not the problem

Compared with the earlier reading of the 506 failures, the interesting part is the one
that **succeeds**, and it succeeds immediately before the handler is registered:

```
[alloc-fail] ml814 #28416 ... hint=0x70512c1000 size=0x1001000 type=0x3000 protect=0x40
[guest-rwx] #1 0x706d2d0000+0x1010000 prot=rwx — anonymous guest memory, EXEC is FEX bookkeeping; applying rw- instead
D EC Add SMC interval: 706D2D0000 - 706E2DE000
[veh-add] ml1252 #1 func=...  order=first
E EC Invalid instruction in entry block: 14537099C
```

A 16 MB RWX block is granted and announced to FEX as an SMC interval, the handler is
installed, and only then is the enciphered entry reached. So the protection's loader does
get a staging area here; what it does not do is decrypt.

### The debugger is not the reason it declines

Madeira's Mach debugger detaches at `12:01:45.416`, long before the fault, so the `Dr7`
check cannot be reading a Madeira-induced value. That refutes the one "we broke it"
hypothesis this shape supported, and it means the declining decision is made on data the
protection reads about the process, not on the debug registers.

### What the next build measures

Two things are now cheap and decisive, and both are in the build that is compiling
(`ml1254`/`ml1255`):

- `[veh-add]`/`[veh-add] REMOVED` now report the **decoded** pointer and its module. The
  old line passed `RtlEncodePointer( func )`, so every registration printed
  `module=...0 ?` — the one field that would name the harness's own module was always
  unreadable.
- `[uef]` reports every `SetUnhandledExceptionFilter` call (filter, its module, its
  caller), and `UnhandledExceptionFilter`'s verdict: `BeingDebugged`, `top_filter`, and
  what the filter returned. The unhandled filter is the other chain a decryptor could
  register on, and nothing has ever looked at it.

## 2026-11-15 14:34 — the handler is the game's, and Dr7 is the next lever

Build 28 with the decoded `[veh-add]` (ml1254 ntdll in the bundle, stock kernelbase
after a WCP overlay of ARM64EC kernelbase onto system32 killed wineboot in 0.8s
with `c000007b`).

```
[veh-add] ml1254 #1 func=00000001453CD858 module=0000000140000000 L"forzahorizon6.exe" order=first
[veh-chain] handler 00000001453CD858 -> 0 (CONTINUE_SEARCH)
[ud-decrypt] BYTES UNCHANGED (eae96be61448897c)
```

That is the body at RVA `0x53D9270`: it matches `STATUS_SINGLE_STEP` /
`STATUS_BREAKPOINT` (the xor constants decode to `0x80000004` / `0x80000003`),
copies `Dr0`-`Dr3` out of the exception CONTEXT, and for a `#UD` only continues
if `Dr7` is set. Wine's ARM64EC path memsets the x64 CONTEXT and drops
`CONTEXT_AMD64_DEBUG_REGISTERS`, so `Dr7` is 0 and the handler declines.

ml1256 stores `Dr0`-`Dr7` in the per-thread cpu-area blob and writes them back
after every ARM→x64 conversion (Set/GetContext, NtContinue, exception
dispatch). Pushed as ntdll in the bundle only.

## 2026-11-15 14:38 — Dr7 was never armed; the decline is a Wine export fingerprint

ml1256 was live. 25 `[x64-dr] SET` lines, every one all-zero: those were
`NtContinue` of a context we ourselves had tagged `CONTEXT_AMD64_DEBUG_REGISTERS`
after filling zeros. The `#UD` at `0x14537099C` still had `dr7=0 valid=1`. The
VEH declined, `BYTES UNCHANGED`. Staging still succeeded (`[guest-rwx]
0x70702e0000+0x1004000`, SMC interval set). No other-thread SET.

So missing `Dr7` is not why this `#UD` is declined. The same handler body at
`0x1453D9270` is more than a debug-register harness:

1. Exception-code xor `0xf58ad36680ab1cf9` then `*2` matches
   `STATUS_SINGLE_STEP` (`0xeb15a6cc015639fa`), `STATUS_BREAKPOINT`
   (`0xeb15a6cc015639f4`), `STATUS_PRIVILEGED_INSTRUCTION`
   (`0xeb15a6cc815638de`, RIP word `0x6cf3`), and `#UD`
   (`0xeb15a6cc815639c8`).
2. For `#UD` it first looks for `UD2` (`0F 0B`) at RIP and skips two bytes.
   Encrypted entries begin with `EA`, so that path is not taken.
3. The `EA` path needs a decrypt-map pointer. If that global is null, it
   returns `CONTINUE_SEARCH`. That is the 14:38 verdict.
4. First-time init calls `0x1453E2A50`, which FNV-1a's every loaded module's
   export names (offset `0x811c9dc5`, prime `0x1000193`, ASCII folded) looking
   for `0xb2dc38a8e4baecd`. That value is exactly `wine_get_unix_file_name` in
   kernel32. Windows does not export it. Finding it sets the flag that skips
   the Windows-only gadget/map setup (`jne 0x1453cb01b`).

Dr7 only feeds the `#UD` path when that flag is 0. On Wine it is 1, so Dr7 is
ignored. Hiding the named export (same-length rewrite to
`xine_get_unix_file_name` in kernel32 and in shell32's import of it, via
`tools/wcp/hide-wine-exports.py`) makes the PEB walk see what Windows has.
That is not decrypting their functions; it is not advertising a non-Windows
API. `[uef]` kernelbase is on sysx64 for the same launch, so the unhandled
filter chain is logged if the flag change is not enough.

## 2026-11-15 14:59 — `#UD` gone; raw `syscall` hits a null ntdll dispatch slot

Hiding `wine_get_unix_file_name` worked. No `c000001d`, no `[ud-decrypt]`.
The game installed its CRT unhandled filter
(`forzahorizon6.exe+0x5A669D0`) and then issued a real Windows `syscall`
(`0F 05` at `0x14551012A`, Wine number `0x50` = `NtProtectVirtualMemory`).
FEX raises `STATUS_EMULATION_SYSCALL`; Wine's `dispatch_syscall` is the
honest path.

The process then AVs at `arm64x_check_call` (`ntdll+0x572d4`,
`ldr x16,[x11]`) with `x11=0`. `[nullfp-probe]` names the load:
`ntdll+0x61ca8` reads CHPE `dispatch_call` at rva `0xd2ea0`, and both the
PE view and the child's pool copy are 0. `arm64ec_process_init_dispatchers`
logged `SKIP ntdll re-patch` — that skip assumed ntdll's slots were filled
elsewhere. They are not, on a child pseudo-process's private ntdll copy.

ml1258 fills ntdll's CHPE slots the same way as every other ARM64EC module,
but without `NtProtect` of ntdll `.data` (that protect is what the skip was
avoiding: iOS IAT-sync rewriting a live ntdll pointer). Look for
`ntdll re-patch (no NtProtect)` and `ntdll hybrid dispatch_call rva=... pe=`
non-NULL, then `[ec-syscall]`.

## 2026-11-15 15:49 — CHPE fill worked; FEX then clobbers ntdll .data

ml1258 loaded. Child ntdll logged `ntdll re-patch (no NtProtect)` and
`dispatch_call rva=d0b90 pe=00000001630FB2C4` (non-NULL). Twelve raw
syscalls ran, including `nr=50` (`NtProtectVirtualMemory`) at
`0x14551012C` — the instruction that killed 14:59.

Then the game `VirtualProtect`'d ntdll `.data` itself
(`0x71F3372000+0x2000`, `PAGE_EXECUTE_READWRITE`). Wine forwarded that
to FEX as "this page is now x64 code". FEX copied the PE view (on-disk
zeros) over the pool copy ARM64 ntdll actually reads, wiping
`pBeginSimulation` at rva `0xd2ea0`. The next `dispatch_emulation` did
`ldr x11,[ntdll+0xd2ea0]; blr check_call` with `x11=0`.

`0xd2ea0` is not the CHPE `dispatch_call` slot (`0xd0b90`); it is a
compiler-generated load of `pBeginSimulation` inside inlined
`dispatch_emulation`. The 14:59 probe named the same rva because that
run never got far enough for the CHPE fill to matter, and crashed on
the first syscall's return path through the already-zero slot.

ml1259 still performs the guest `NtProtect` (Denuvo is allowed to change
ntdll's protection) but does not tell FEX that a PE **data** section is
now executable. Look for `[exec-data] SUPPRESSED` on that ntdll `.data`
protect, then more `[ec-syscall]` after it.

## 2026-11-15 15:54 — FEX notify skip fired; unix protect still zeros the page

`[exec-data] SUPPRESSED via=cur-pre` on `ntdll.dll` rva `d2000` prot=40,
then `[exec-req]` succeeded, then the same `x11=0` crash at
`pBeginSimulation` (`rva 0xd2ea0` still 0 in PE and pool). Twelve
syscalls had already used that pointer, so the live pool page was good
until `syscall_NtProtectVirtualMemory` itself. ml1260 snapshots the live
ARM64 page around `pBeginSimulation` and writes it back after the
protect. Look for `[exec-data] save ... pBeginSimulation=` non-NULL and
`restore pBeginSimulation=` the same value.

## 2026-11-15 16:00 — preserve memcpy used a 32-bit page mask

ml1260 loaded (`SUPPRESSED via=save`) then AV READ of `0x63176000` in
ntdll `memcpy` (`ntdll+0x65448`), called from
`syscall_protect_preserving_ntdll_data`. Guest RIP was still the
NtProtect hp_target; we never reached unix protect or the save log.
`0x63176000` is the live pool page `0x163176000` with the top 32 bits
cleared: `~0xfffUL` is 32-bit on LLP64. ml1261 uses `~(ULONG_PTR)0xfff`.
Look for `[exec-data] save n=8192 live=0000000163176000 pBeginSimulation=`
non-NULL, then more `[ec-syscall]`.
