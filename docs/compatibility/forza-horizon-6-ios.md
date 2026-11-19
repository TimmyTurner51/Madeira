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

## 2026-11-15 16:08 — this is Denuvo's protect, not a failed check

ml1261 save/restore logged `pBeginSimulation=0000000163595600` then the next
`dispatch_emulation` loaded 0 from the same slot. The guest
`VirtualProtect(ntdll .data, PAGE_EXECUTE_READWRITE)` is Denuvo making that
page runnable, the same thing DroidDeck runs under `FEX_SMCCHECKS=full`. We
do not skip it and we do not hide it from FEX.

DroidDeck has one mapping and `mprotect`s in place, so live ARM64 ntdll
statics survive. iOS IAT-sync copies the PE file (zeros) over the pool copy
those statics live in. ml1262 writes the FEX hooks back through the existing
8-byte `unix_ios_sync_pe_write` path (the loader's CHPE slot path) after the
protect, and forwards the exec notify so FEX can SMC-watch the page. A unix
skip of that PE→pool memcpy sits in `virtual_ios.c` for the next IPA; the
guest protect still applies either way.

## 2026-11-15 16:16 — JIT pool swallowed 0x140000000; Wine never started

After a full Madeira quit for ml1262, the 896MB pool did not fit. Census:

`0x12547c000+552MB` (swallows `0x140000000`), `0x14d9b8000+514MB`,
`0x16e378000+284MB`. Occupants at `0x147d00000` and `0x148000000+4MB`
left `windowHeld=false`, so `pool-pair` was skipped. Shrink used the
overlapping 552MB hole (544MB at `0x12547c000`, BAD POOL), then the
guest 64G window, then "The JIT memory landed at an address Madeira
cannot use."

ml1263 pairs above `0x140000000` even when the window is not held
(514+284MB), shrinks from the largest non-overlapping hole, and plugs
holes that swallow the executable window so first-fit cannot land there.

## 2026-11-15 16:27 — pool + ntdll `.data` held; `#UD` with empty VEH

b29 placed an 800MB pair at `0x14c000000+544MB` / `0x16f500000+256MB`,
`windowHeld=true`. FH6 loaded at `0x140000000`. Child CHPE
`dispatch_call rva=d0b90 pe=00000001630FB2C4`. Twelve raw syscalls
including `nr=50`. Guest `VirtualProtect` of ntdll `.data` RWX:
`[ntdll-data-sync] SKIP PE→pool copy` and
`restore pBeginSimulation=0000000163595600` both sides.

Then `#UD` at `forzahorizon6.exe+0x537099c` (`ea e9 6b e6…`, the
encrypted prologue). `[veh-chain] EMPTY (0 handler(s))` — the game
never registered a decrypt VEH. b29's IPA restored stock kernel32
(`wine_get_unix_file_name` visible). Hide it again in the farm copies
and the WCP overlay; look for a non-empty VEH on the next `#UD`.

## 2026-11-15 16:35 — kernel32 unix hide live; still 0 VEH

WCP overlay `ml1264-hide-wine-exports` was on device (`wine=0 xine=2`
in mapped kernel32). Pool, CHPE, ntdll `.data` skip, and `nr=50` all
held. Zero `[veh-add]` lines: `RtlAddVectoredExceptionHandler` was
never called. The documented hash is still
`wine_get_unix_file_name`; kernel32 was clean. Remaining Wine-only
names on the same PEB walk: ntdll `wine_get_version` /
`wine_get_build_id` / `wine_get_host_version`, kernel32
`wine_get_dos_file_name`, and matching import strings in dxgi/d3d12.

ml1265 rewrites every same-length pair to `xine_*` (not `wine_server_*`),
ships unstripped ntdll with a mapped-image `[wine-export]` count of
those needles, and overlays kernel32/shell32/dxgi/d3d12/user32/dbghelp
so import names match the hidden exports. GameConfigs `env.FEX_*`
stays reverted. Look for `[wine-export]` unix=0 on kernel32/ntdll and
a non-empty `[veh-add]` before the next `#UD`.

## 2026-11-15 16:51 — unix gone from kernel32; still Wine staging, still 0 VEH

ml1265 ntdll probe: only `xtajit64.dll` still had `wine_get_version`
(FEX's `GetProcAddress` needle). kernel32/ntdll did not log, so the
unix string was gone from those mapped images. The game still took the
Wine path: 28k failed 16MB maps, then `[guest-rwx] 0x70722e0000+0x1004000`
and an SMC interval — the same staging 14:38 used before it registered
the Dr7 VEH. This launch jumped from staging to the encrypted `#UD` at
`0x14537099C` with **no** `[veh-add]`. CRT UEF at `+0x5A669D0` did
install. `nr=50` and ntdll `.data` skip/restore held.

Hiding `wine_get_version` was a miss: FEX sets `IsWine` from
`GetProcAddress(ntdll, "wine_get_version")`. ml1266 restores that export,
keeps only unix/dos hidden, and FNV-1a's every PEB module's **export
directory** for `0xb2dc38a8e4baecd` at iat-sync, ntdll `.data` exec, and
empty VEH so the remaining hit names the DLL. `[veh-add] enter` logs even
if the heap insert never happens.

## 2026-11-15 17:00 — unix-hits=0; FEX xrems ntdll `.data` after the honest protect

Census at iat-sync (6 mods), ntdll `.data` exec (85), and empty VEH (85):
**unix-hits=0**. Zero `[veh-add] enter`. This is the Windows path: no
Dr7 VEH, decrypt gadgets on ntdll `.data`. Guest
`VirtualProtect(.data, PAGE_EXECUTE_READWRITE)` returned success, FEX
`Add SMC interval: 71F3372000-71F3374000`, then hook restore
`unix_ios_sync_pe_write` mprotect'd the page without EXEC and FEX
`[iOS-xrem] via=protect` dropped the interval. Then the 16MB staging
alloc and `#UD` at the still-encrypted `EA` prologue.

ml1267 skips the post-notify restore (hooks already restored post-unix)
so the SMC interval Denuvo armed stays. Look for Add SMC on ntdll `.data`
**without** a following `[iOS-xrem]` of the same range, then either a
decrypt VEH or no `#UD`.

## 2026-11-15 17:05 — pair 560 MB, C 16 KB short; libxess never loads

ml1267 did not run. The child died `NtTerminateProcess exit_code=0xc0000135`
while importing `libxess.dll` / `MSVCP140.dll`. No ntdll `.data` protect, no
census-after-protect, no `#UD`.

Holes with the window held: `0x12bf64000+320MB 0x14c000000+253MB
0x1619a8000+148MB 0x16b600000+330MB`. Pair `A=0x14c000000+240MB
B=0x16b600000+320MB` = 560 MB (16 MB grain dropped 13+10 MB). The 148 MB run
between them was held PROT_NONE (179 MB of the 262 MB gap). RX span
`[0x14c000000,0x17f600000)` 822 MB, hole offsets `[0xf000000,0x1f600000)`.

Region C was 272 MB (`0x12f000000`, margin 48 on the 320 MB run below the
window). Sequence: 4 KB + 16 MB + 128 MB from C, then the 16 MB freed, then

```
[pool-low] region C has 0x7ffc000 of 0x11000000 left, not enough for carve
           0x8000000: it goes to the pool tail
[jit-pool] tail EC_CODE rx=0x177600000 size=0x8000000 tail_resv=0x8000000
```

Image room = A 240 + (B 320 − tail 128) = 432 MB. 17:00 reached libxess at
`used=0x248fe000` (580 MB) of an 816 MB pair. 17:05:

```
[jit-pool] EXHAUSTED (image …libxess.dll): want=0x4a40000
           bump=0x2b5c4000/0x33600000 tail_resv=0x8000000
[pool-capacity] … main_virgin=0x3c000 c_virgin=0x7ff8000 c_image_virgin=0x7bf8000
```

`c_image_virgin` is ~124 MB, but `MADEIRA_POOL_LOW_IMAGES` caps overflow at
16 MB, so the 74 MB copy cannot go to C. `env.FEX_*` stays reverted.

GameConfigs (no IPA): `pool-mid=1` takes the 148 MB run; `pool-page-fit=1`
keeps the 13+10 MB the grain dropped; `pool-low-margin=32` leaves C 288 MB so
the second 128 MB carve stays in C (`0x8ffc000 > 0x8000000`). Image room
becomes 240+148+320 = 708 MB with tail_resv=0. Look for `[pool-split] pool-mid`
and libxess `used=` without EXHAUSTED, then the ml1267 SMC keep.

## 2026-11-15 17:10 — libxess fits; restore loop never ends

Cfg applied (`pool-mid=1 pool-page-fit=1 pool-low-margin=32`). Pair
`A=0x14c000000+562MB B=0x16fa0c000+261MB` = 824 MB, 7 MB hole, C 334 MB,
`tail_resv=0`. `libxess.dll` loaded at `used=0x2070a000/0x34000000`. Child
CHPE, `nr=50`, ntdll `.data` EXEC skip all held. unix-hits=0.

Then `00e8` stuck in `syscall_protect_preserving_ntdll_data` at
`ntdll.dll+0x5e744` (`str x10,[x27]; cbz x8, loop`). ml1267 inlined
`ios_restore_fex_hooks` and clang dropped the 21-iteration bound, so the
RX-pool stores ran off the end of ntdll `.data` (fault-class 7.3M hits
walking `0x163198000`+, `wine-x18-exc` hot). No `restore via=post-unix`, no
Add SMC, no `#UD`. 17:00's non-inlined restore completed in one step.

ml1268: `DECLSPEC_NOINLINE` plus a local `n = 21` so the loop cannot run
away. Unstripped ntdll overlay. Look for `restore via=post-unix … n=21`,
Add SMC on `71F3372000-71F3374000` without `[iOS-xrem] via=protect`, then
either a decrypt VEH or no `#UD`.

## 2026-11-15 17:20 — restore bounded; SMC still xrem'd; empty VEH `#UD`

ml1268 held: `restore via=post-unix … n=21`, unix-hits=0, libxess loaded,
`[ntdll-data-sync] SKIP`, `skip post-notify restore`. Then in order:

```
[exec-req] #2 addr=71F3372000 size=2000 new_prot=40 -> status=00000000
Add SMC interval: 71F3372000 - 71F3374000
skip post-notify restore (keeps FEX SMC)
[iOS-xrem] via=protect … 0x71f3372000-0x71f3374000
```

ml1267's skipped second restore was not the xrem. The 16 MB staging scan
then succeeded (`[jit-pool] anon RWX 0x706f2d0000`, Add SMC
`706F2D0000-70702E0000`), `[veh-chain] EMPTY`, `#UD` at
`forzahorizon6.exe+0x537099c` (`ea e9 6b e6…`), `exit_code=0xc000001d`.

ml1269 (FEX): a non-exec protect notify of a small range that is already
an RWX/SMC interval does not drop that interval. Host mprotect without
EXEC is the dual-map, not the guest dropping execute. Look for
`[iOS-xrem] SUPPRESSED SMC keep` on `71F3372000-71F3374000`, build-id
`rev=ml1269`, then either gadgets on ntdll `.data` or a decrypt VEH
before the next `#UD`.

## 2026-11-15 17:34 — SMC keep held; gadgets still never decoded

ml1269 loaded (`rev=ml1269 compiled Nov 15 2026 17:26:45`). Restore `n=21`,
unix-hits=0, libxess loaded. In order:

```
[exec-req] #2 addr=71F3372000 size=2000 new_prot=40 -> status=00000000
Add SMC interval: 71F3372000 - 71F3374000
skip post-notify restore
[iOS-xrem] SUPPRESSED SMC keep 0x71f3372000-0x71f3374000 notify_prot=0x4
(~28k 16MB alloc-fails)
[guest-rwx] #1 0x70712e0000+0x1004000
Add SMC interval: 70712E0000 - 70722E2000
Invalid instruction in entry block: 14537099C  bytes=ea e9 6b e6…
[veh-chain] EMPTY
NtTerminateProcess exit_code=0xc000001d
```

SMC keep did what it advertised. No `[veh-add]`. No compile of
`0x71F3372xxx`. Terminate GPRs still hold the 14:38 xor constant
(`f58ad36680ab1cf9`) and the `EA` byte: the Windows-path handler body
ran as SEH, the decrypt-map pointer was null, CONTINUE_SEARCH.

iOS never grants W+X on a file-backed PE page (unix ml999). The guest
`VirtualProtect(ntdll .data, PAGE_EXECUTE_READWRITE)` is therefore host
RX; x64 stores Mach-emulate into the pool copy; FEX compiled the PE VA
and decoded the still-RX file bytes. DroidDeck has one mapping — the
stored bytes are the fetched bytes. ml1270 (FEX): when a PE VA is a
guest RWX/SMC interval and has a pool alias, decode and SMC-validate
from the pool copy. ntdll dumps PE vs pool 16 bytes and
`NtQueryVirtualMemory` at ntdll-data-exec and empty-veh.

Look for `rev=ml1270`, `[ios-smc-fetch]` of `71F3372…` with pool bytes
that are not the PE file view, then either a decrypt VEH or no `#UD` at
the still-encrypted `EA` prologue. `[iOS-prot] protect … prot=0x4` names
who restated the page as PAGE_READWRITE after the honest RWX. Do not
re-add GameConfigs `env.FEX_*`. Do not strip ntdll. Do not hide
`wine_get_version`.

## 2026-11-15 17:51 — ml1270 loaded; Query reports 0x80; gadgets never compiled

ml1270 loaded (`rev=ml1270 compiled Nov 15 2026 17:43:11`). Restore `n=21`,
unix-hits=0, SMC keep held, JIT pair 831 MB / peak 543 MB. In order:

```
[exec-req] #2 addr=71F3372000 size=2000 new_prot=40 -> status=00000000
Add SMC interval: 71F3372000 - 71F3374000
query via=ntdll-data-exec Protect=80 AllocProtect=80  (PAGE_EXECUTE_WRITECOPY)
bytes pe= pool= 16×00 at +0
[iOS-xrem] SUPPRESSED SMC keep … notify_prot=0x4
(~28k 16MB alloc-fails)
[guest-rwx] #1 0x70712e0000+0x1004000
Invalid instruction … 14537099C  bytes=ea e9 6b e6…
[veh-chain] EMPTY
census via=empty-veh   (no exec-data dump — ios_fex_hooks_pe was NULL)
NtTerminateProcess exit_code=0xc000001d
```

Zero `[ios-smc-fetch]`: guest RIP never entered `0x71F3372xxx`, so the
pool-fetch alias never engaged. Dual-map fetch remains correct for when
they do JMP; it was not this launch's blocker.

Wine `get_vprot_flags(PAGE_EXECUTE_READWRITE, image)` stores
`VPROT_EXEC|READ|WRITECOPY`, so `NtQueryVirtualMemory` reports `0x80`
even after a successful guest `VirtualProtect(..., 0x40)`. Windows after
that protect reports `PAGE_EXECUTE_READWRITE` (`0x40`). The empty-veh dump
pointer lives in the same 8KB (`ios_fex_hooks_pe` rva `0xd3f00`) Denuvo
writes, so the post-write dump did not run.

ml1271 (PE ntdll): `NtQueryVirtualMemory` remaps that honestly
exec-protected ntdll `.data` page from `0x80`/`0x08` to `0x40`, matching
Windows. Dump pointers live next to `ios_fex_arena_*` (first `.data`
page, outside the 8KB). Look for `query-win32 … Protect=80->40`, empty-veh
bytes at `+0` / `+ea0` that are not 16×00, then `[ios-smc-fetch]` of
`71F3372…` or a decrypt VEH before the next `#UD`. Do not re-add
GameConfigs `env.FEX_*`. Do not strip ntdll. Do not hide
`wine_get_version`.

## 2026-11-15 17:59 — ml1271 ntdll loaded; libxess EXHAUSTED before Denuvo

ml1271 ntdll was on the session bundle (`query-win32` strings present).
FEX still `rev=ml1270`. Child died in `loader_init` importing
`forzahorizon6.exe`, `exit_code=0xc0000135`, before any ntdll `.data`
protect. Cause:

```
[game-cfg] … pool-low-margin=32 pool-mid=1 pool-page-fit=1
[pool-low] region C 0x1399b0000+102MB (runs 120MB + 102MB)
[jit-pool] tail EC_CODE … tail_resv=0x8000000
[jit-pool] tail EC_CODE … tail_resv=0x10000000
[jit-pool] EXHAUSTED … want=0x4a40000 bump=0x1bcc8000/0x34000000 tail_resv=0x10000000
Loading library libxess.dll … failed (error c0000017)
```

Pair A=502 MB + B=321 MB (824 MB), 7 MB stack hole. C 102 MB cannot hold a
128 MB FEX carve, so both 128 MB buffers took the pool tail. Remaining
contiguous: 58 MB in A to the hole, 65 MB in B after the tail. libxess
wants 74 MB. 17:10 had C 334 MB and tail_resv=0.

GameConfigs (not `env.FEX_*`): `MADEIRA_POOL_BIG_SLOT_MB=80` and
`MADEIRA_POOL_BIG_SLOT_BELOW=1` reserve 80 MB immediately below the hole
for one ≥64 MB image. An upper slot is unsafe (widens the hole so the
second tail carve walks into the bump). Look for `[pool-big] … below the
hole`, libxess `used=` without EXHAUSTED, then ml1271 `query-win32` /
empty-veh bytes / `[ios-smc-fetch]`. Do not re-add `env.FEX_*`. Do not
strip ntdll. Do not hide `wine_get_version`.

## 2026-11-15 18:05 — libxess loaded; Query 0x40; gadgets still never stored

Big-slot cfg applied (`[pool-big] slot [0x1a8e4000,0x1f8e4000) (80 MB) below
the hole`). `libxess.dll` placed in the slot and loaded. FEX still
`rev=ml1270`. ml1271 wrap live. Restore `n=21`, unix-hits=0, SMC keep held.
In order:

```
[exec-req] #2 addr=71F3372000 size=2000 new_prot=40 -> status=00000000
query via=ntdll-data-exec unixProtect=80 guestProtect=40  (80->40)
bytes +0 16×00 PE and pool; +eb0 live FEX hooks both views
Add SMC 71F3372000-71F3374000
[iOS-xrem] SUPPRESSED SMC keep … notify_prot=0x4
(~28k 16MB alloc-fails)
[jit-pool] anon RWX 0x706f2d0000 size=0x1010000
Add SMC 706F2D0000-70702E0000
(emulated stores into staging, 395k hits at 0x706f2d0000)
Invalid instruction … 14537099C  bytes=ea e9 6b e6…
[veh-chain] EMPTY
query via=empty-veh unixProtect=8 Region=1e000  (8->40)
bytes +0 still 16×00 PE and pool; +eb0 hooks intact
NtTerminateProcess exit_code=0xc000001d
```

Lower 80 MB slot did what it advertised. Query wrap reported 0x40 at
ntdll-data-exec; Denuvo never Query'd through the wrap (only two
`query-win32` lines, both from our dump). Empty-veh dump ran (sticky
survived). Zero `[ios-smc-fetch]`: RIP never entered `0x71F3372xxx`.
No `[guest-rwx]` this launch; staging still mapped.

The Windows-path block at `0x1453caf8e` is: find `48 8B` at a scanned
ntdll pointer, `VirtualProtect(page, 0x2000, 0x40)` (BOOL via `setns` on
NTSTATUS, so our success is theirs), then `mov qword ptr [rax], gadget`.
That 8-byte store is the decrypt-map pointer, not executable thunks at
`+0`. Four dump offsets of zeros did not prove the qword was never
written — and unix IAT-sync on the WRITECOPY restore (skip is EXEC-only)
would copy PE zeros over the pool copy of it. Mach STR emulation uses
`ios_jit_anon_alias_lookup`, not the PE→pool image table, so a store
into file-backed RX ntdll `.data` has no RW alias.

ml1272: ntdll skips that 8KB WRITECOPY restore (keep guest EXEC; census
the 8KB for PE/pool/split qwords); Query remaps only `0x80` not `0x08`.
FEX `rev=ml1272` completes SMC stores to the pool RW alias and
`NtWrite`s the PE view (`[ios-smc-store]`). Look for `keep-exec skip
restore`, census `split=` or extra `pe_nz` beyond the FEX hooks, then
`[ios-smc-store]` of `71F3372…` or a decrypt VEH before the next `#UD`.
Do not re-add `env.FEX_*`. Do not strip ntdll. Do not hide
`wine_get_version`. Do not use an upper big-slot.

## 2026-11-15 18:52 — ml1272; decrypt pointer stored at pWow64PrepareForException

ml1272 loaded (`rev=ml1272 compiled Nov 15 2026 18:14:28`). libxess in the
80 MB slot. unix-hits=0. Query wrap 80→40. SMC keep held. In order:

```
[exec-req] #2 addr=71F3372000 size=2000 new_prot=40
Add SMC 71F3372000-71F3374000
keep-exec skip restore new_prot=4
census keep-exec pe_nz=24 (was 23) first_pe=510
(~28k 16MB alloc-fails)
[guest-rwx] #1 0x70692d0000+0x100c000
Add SMC 70692D0000-706A2DA000
Invalid instruction 14537099C  bytes=ea e9 6b e6…
[veh-chain] EMPTY
unixProtect still 80 Region=2000
NtTerminateProcess exit_code=0xc000001d
```

Zero `[ios-smc-store]`: the 8-byte store did not fault. Census first_pe moved
from `e68` (hooks) to `510` — rva `0xd2510` is ntdll
`pWow64PrepareForException`. Denuvo writes its decrypt gadget there, which
Windows `KiUserExceptionDispatcher` calls. ARM64EC prepare_exception reads
the pool copy of that pointer (still NULL), so it skipped the x64 thunk and
ran ARM64 `dispatch_exception` with an empty VEH.

ml1273 (PE ntdll): copy the PE slot into `pWow64PrepareForException` after
the store so the existing x64-thunk path runs the guest hook; dump `+510`
and first-pe bytes; log `[ki-path]` for `#UD`. Look for
`pWow64PrepareForException=00000001454f21b9` (or similar EXE address),
`[ki-path] … x64-THUNK`, then either a decrypt VEH or no `#UD` at the
still-encrypted `EA` prologue. Do not re-add `env.FEX_*`. Do not strip
ntdll. Do not hide `wine_get_version`.

## 2026-11-15 19:34 — ml1273; hook pointer live, x64 ntdll stub never ran it

ml1273 ntdll loaded. unix-hits=0. libxess in the slot. keep-exec copied PE
`+0x510` into the live pointer:

```
pWow64PrepareForException=00000001454F21B9 from pe+510
keep-exec +510 pe=b9 21 4f 45 01 00 00 00  (and pool too)
[guest-rwx] #1 0x70702e0000+0x1004000
Invalid instruction 14537099C  bytes=ea e9 6b e6…
[ki-path] … x64-THUNK (guest hook runs) (patched=0 wow64=00000001454F21B9)
[veh-chain] EMPTY
BYTES UNCHANGED (eae96be61448897c)
exit_code=0xc000001d
```

Zero FEX compiles of `1454F21B9`. Wine ARM64EC `KiUserExceptionDispatcher`
returns `EXP+#KiUserExceptionDispatcher` (an x64 stub that `call`s that
pointer) to `ExitToX64`. ntdll is hybrid, so ExitToX64's EC bitmap treats
the stub as ARM64EC and does not enter the JIT; the stub never `call`s the
gadget. Empty VEH is expected on the Windows path — decrypt is the KiUser
hook, not a vectored handler.

ml1274 (PE ntdll): call `0x1454F21B9` through `ExitToX64` with RCX=rec
RDX=x64 context (Windows KiUserExceptionDispatcher), then ARM64
`dispatch_exception`. Look for `[ki-path] calling pWow64PrepareForException=`
and `returned` with Rip bytes no longer `ea e9 6b e6`, or a further fault
inside the gadget. Do not re-add `env.FEX_*`. Do not strip ntdll. Do not
hide `wine_get_version`.

## 2026-11-17 20:18 — the KiUser hook runs, and it is not the decryptor

ml1274 (ntdll sha `94a3c462…`, `wow64=00000001454F21B9`) was live. The x64
call through `ExitToX64` worked exactly as designed:

```
[ki-path] calling pWow64PrepareForException=00000001454F21B9 ExitToX64=00000001635A55C4
          rec=000000706C9EFD50 ctx=000000706C9EF4D0 Rip=000000014537099C bytes=eae96be61448897c
[ki-path] pWow64PrepareForException returned Rip=000000014537099C code=c000001d bytes=eae96be61448897c
[veh-chain] EMPTY (0 handler(s))
[ud-decrypt] BYTES UNCHANGED (eae96be61448897c)
```

FEX compiled and ran the gadget: the call returned through the gadget's own
epilogue, and `[ki-path] … returned` printed after it. So the hook is not
blocked any more — the store Denuvo made into ntdll `.data +0x510` is now
honoured by the dispatcher, which is what Windows does.

### The 8-byte store is a pre-dispatch callback, not a decrypt map

The 18:05 entry guessed that the `mov [rax], gadget` store *was* the decrypt
map. The gadget (`0x1454F21B9`) forwards to the body at `0x1453D9270`, which is
the same harness the Wine-path VEH pointed at (`0x1453CD858` → `jmp +0x53D9270`):

- `(ExceptionCode ^ 0xf58ad36680ab1cf9) * 2` of `0xc000001d` is
  `0xeb15a6cc815639c8` **exactly** — the `#UD` arm is entered, no doubt left.
- that arm compares the word at `ctx->Rip` with `0x0F0B` (`UD2`) and skips two
  bytes when it matches (our entries start `EA`, so it does not), then branches
  on `ctx->Dr7 != 0` and finally looks `ctx->Rip` up in a range map rooted at
  `forzahorizon6.exe+0xab885b8` (object) / `+0xab885c0` (tree):
  `cmp [node+0x20], rip`, children at `+0x0`/`+0x10`, end flag at `+0x19`.
- a NULL object pointer returns `(wine_flag == 0)` and CONTINUE_SEARCH; a miss
  in the tree goes to the `0x1453DA482` arm, which also ends in
  CONTINUE_SEARCH after taking a map lock.

The hook returned without any fault inside `0x1453D9EAB`, so the map header was
readable and its entries were sane pointers — the decline is the lookup, not a
half-initialised table.

### Two more things this run rules out

- `[x64-dr]` shows only the two reads at fault time (`dr0=0 dr7=0 valid=0`) and
  the log has **no** `NtSetContextThread` at all: nothing ever arms `Dr0`-`Dr3`
  in this process, so the single-step arm of the harness is not what Windows
  would use here either.
- `forzahorizon6.exe` is at its preferred base this time (`[main-exe]
  virtual_map_module = 0x0`, `ml988 … CLAIMING`, `ImageBase=0x140000000`,
  `TransferAddress=0x145a66394`), so the relocated-image theory is off the
  table for this crash.

ml1275 adds `[dec-map]`: at the hook call it dumps the eight qwords at
`exe+0xab885b8`, the object/root pointers, the `wine-flag` byte, and walks the
tree with the guest's own comparisons, marking a `MATCH`. Look for
`root is not a pointer -- the map was never built` (the table is still raw
RVAs) versus a walk whose keys bracket `0x14537099C` without a `MATCH`.

## 2026-11-17 20:34 — the decrypt map is a real structure, read at the wrong depth

ml1276's probe ran at the hook call and printed the protection's own globals:

```
[dec-map] code=c000001d rip=000000014537099C obj=00000070725E8040 root=00000070725E80A0
[dec-map] table 00000070725E8040 00000070725E80A0 0 00000070725E0990 0 0 00000070725E0920 0000000140000000
[dec-map] wine-flag ptr=00000070725E0B40 value=00
[dec-map] node[0]=00000070725E0CA0 key=0 end=01 left=self right=self
```

The cells are live HEAP pointers (not the raw RVAs still visible in the file image),
so the initialiser at `0x1453CAE60..0x1453CBF80` did run: it allocates the two map
objects (`st rax -> exe+0xab885b8` at `0x1453CB0B9`, `exe+0xab885c0` at
`0x1453CB115`) and the Wine-detection flag cell (`exe+0xab88560`). `wine-flag = 0`
confirms the Windows branch was taken, which is also why the ntdll gadget store
happened.

The `node[0]` line is a measurement artefact, not a result: the guest dereferences
twice (`r9 = [cell]; rdx = [r9]; rcx = [rdx+8]`), so `0x70725E0CA0` is the map
CONTAINER and the header is `*(container+8)`. ml1277/ml1278 walk it at the right
depth, count the keys, compare them with the faulting RIP, and print the hook's own
return value (`x0`) plus the initialiser's progress slots (`ctx+0x00`, `ctx+0x90..`).

### What the harness actually does with an `EA` entry

Reading the arms of `0x1453D9270` disambiguates the stub kinds by first byte:

- `0x17` at `Rip`: look up `(TEB.ClientId.UniqueThread, Rip)` in the object at
  `exe+0xab88558` and **rewrite `ctx->Rip`** to the recorded target
  (`mov [ctx+0xf8], rbx`, then `eax = 1`).
- `0x07` at `Rip`: the same shape through the `r15d = 3` path on the map at
  `exe+0xab885b8`.
- `0xEA` (ours): `lower_bound(Rip)` in the map at `exe+0xab885c0`; a hit loads the
  record (`[node+0x140]`) and redirects `ctx->Rip` the same way, a miss falls through
  to `0x1453DA482`, inserts the RIP with value `-1`, and returns
  `(wine_flag == 0)` — i.e. `1`, which is why the wrapper took its clean epilogue and
  returned to us.

So the map is a **redirect table for the protection's own entry stubs**, keyed by RIP,
and the encrypted `EA` prologue is a stub whose real body was supposed to be
registered there. Nothing in the fault path can decrypt without that registration,
and the only writer of the table in this image is the protection's own loader — so
the question ml1278 answers is whether the table has entries at all, and whether
`0x14537099C` is among them.

### ml1278 answers it: both maps are empty, and that is a timing result

The 20:34 run (ml1278, unstripped ntdll, `sha256 a0710234…`) walked the tree at the
right depth for the first time:

```
[dec-map] code=c000001d rip=000000014537099C ctx.Rip=000000014537099C
[dec-map] wine-flag ptr=000000706DAD0B40 value=00
[dec-map] obj:  obj=000000706DAD8040 cont=000000706DADC690 head=000000706DADC690 isnil=01
[dec-map] obj:  RIP not registered (all keys below it)
[dec-map] root: obj=000000706DAD80A0 cont=000000706DAD0CA0 head=000000706DAD0CA0 isnil=01
[dec-map] root: RIP not registered (all keys below it)
[ki-path] hook returned x0=000000706C75FD50 (0 = declined)
```

`isnil=01` on both headers means neither map has a single node: the initialiser ran
(it allocated the objects and the `wine_flag` cell) but nothing has been *inserted*
yet. So `pWow64PrepareForException` behaved exactly as written — the harness is not
broken, it is unpopulated — and the fault is not "the hook refused", it is "the
protection had not finished unpacking when the game called a function whose prologue
is still `EA`".

The frame handler that ran next is `forzahorizon6.exe+0x5eaa3b8`, a table of
`jmp [rip+…]` thunks; it declined, VEH was empty (`[veh-chain] ml1251 EMPTY`), and the
process died `0xc000001d`. The ordering is the bug.

### The ordering is the store emulator: 179561 stores at 8.4 µs each

Same run, before the fault:

```
[fault-class]   pc=0x16390eb68 blockRIP=0x71f332b067 hits=195878 page=0x706f2d0000
                stride=32 restarts=0 pages>=64
[jit-pool] anon RWX 0x706f2d0000 size=0x1010000 → used=0x1dd34000/0x34000000
                NEW off=0x1cd24000 tid=00e8 peb=0x101038000 rev=ml625
[fault-cost] ml685 emulated-store faults=179561 total=1501 ms avg=8363 ns
```

The protection asked for 16 MB + 64 KB of `PAGE_EXECUTE_READWRITE` and filled it
32 bytes at a time from the guest's own ntdll `memcpy` (`pc=0x16390eb68`). That size
is a multiple of 64 KB, so `ios_guest_anon_rwx_view_ok()` classified the block as a
Mono-style *code chunk*, `mprotect_exec()` backed it with a JIT pool slot, and every
store became a Mach fault into the emulator: ~2 ms per KB, ~4.3 s for the fill.

On Windows the same fill is a plain `memcpy`. The protection unpacks on one thread
while the game's CRT initialisers run on another, and the main thread reached a
still-encrypted function ~4 s ahead of the unpacker. The 1501 ms is the whole gap.

### ml1283: an 8 MB+ anonymous RWX allocation is data, whatever its low bits say

`IOS_GUEST_RWX_DATA_MIN` (8 MB) is the discriminator the 64 KB-modulo test was
standing in for. Mono's code chunks are 1 MB and V8's are 256 KB — no runtime
allocates code in one RWX block this large, while a protector's unpack staging is.
A page FEX has compiled from is still armed (`GetTrapProt -> PAGE_EXECUTE_READ`) and
still traps the first write, so SMC invalidation is unchanged; what is skipped is
per-store emulation of a page FEX has never translated.

`[guest-rwx] ml1283 %p+0x%lx DECLINED plain RW: <gate>` now says outright why a
large request still landed on the pool (`MADEIRA_GUEST_RWX_DATA off`, `EC_CODE
request`, `no arm64ec_view`, `already alias-backed`, or the view's `protect`/
`valloc`/size), so a repeat cannot be silently attributed to this policy.
### ml1286/ml1287: the `#UD` hook declines on the opcode, and the FEX fix never loaded

The 21:02 run settled what the `0xC000001D` at `0x14537099C` actually is, and it
was not what the previous three probes assumed.

**The hook was never declining.** `[ki-path] hook returned x0=<rec>` was read as
"0 = declined", but the game's thunk at `0x1454F21B9` pushes `rax` at `0x1454F21C3`
and pops it at `0x1454F222F` before `ret`, so the caller's `rax` is restored on
every path. `x0 == rec` is what a *successful* run leaves, not a refusal.

**The hook's real contract.** `r14` is a `{rec, ctx}` pair, not the record: the
thunk calls the body with `rcx = ~(rsp+8)` and the body's `not r14` (taken only
when `[[0x14ab88560]] == 0`) undoes it, so `[r14] = rec` and `[r14+8] = ctx`.
The body hashes `(ExceptionCode ^ 0xf58ad36680ab1cf9) * 2` and branches on the
result:

| constant | exception code | arm |
|---|---|---|
| `0xeb15a6cc015639f4` | `0x80000003` | breakpoint / single-step shim |
| `0xeb15a6cc015639fa` | `0x80000004` | single-step shim |
| `0xeb15a6cc815639c8` | `0xc000001d` | the encrypted-prologue arm |

The `0xC000001D` arm is at `0x1453d9df3` and does this:

```
1453d9e0a: mov rax, [rcx+0xf8]          ; ctx->Rip
1453d9e1a: mov edx, 0xb0f
1453d9e1f: cmp word ptr [rax], dx       ; REQUIRES 0F 0B = UD2
1453d9e22: jne 0x1453d9eab              ; else decline
1453d9e28: add rax, 2                   ; resume at Rip + 2
```

Our site holds `ea e9 6b e6 14`, so the arm declines on the **opcode**, not on the
exception code and not on a missing map entry. `.text` holds two stub shapes:
934 sites starting `0F 0B` (UD2, what the arm handles) and 979 starting `EA E9`
(4-byte opcode, out of range for the following `mov`, so these are not jumps either).
Only one site in the image compares against `0xb0f`; nothing compares against
`0x0b0a` or the `EA` form.

The block *before* the arm tests `[ctx+0x70]`, which is `Dr7` (`ctx+0x68..0x78` is
`Dr0..Dr7`, then `EFlags` at `0x7c`) — it is an anti-debug shim, so `Dr7=0` and the
empty decrypt map are both expected and neither is the fault. `[veh-add]` is
compiled in (three call sites) and logged **zero** lines in 15,872, so the
protection never registered a vectored handler at all; it was not added then
removed. No handler in the chain is a decryptor: the only frame handler is an IAT
thunk, and the top filter is MSVC `__CxxFrameHandler`, which returns 0 for anything
that is not `0xe06d7363`.

**`build/{wine,fex}-patches/apply.sh` were skipping the fix.** Both aborted on a
patch that the fork already carries, so `0012-hypervisor-leaves-*` never shipped.
That patch's own note describes this exact symptom: a `0x40000000` leaf answering
`eax = 0x40000001` with signature `FEXIFEXIEMU` while leaf 1 says no hypervisor is
present is a fingerprint no real machine can produce, and anti-tamper that reads it
concludes "emulator" and never decrypts. With `FEX_HIDEHYPERVISORBIT=1` (already in
the FEX component's `environment`) that range now returns zero.

`build/fex-patches/apply.sh` was also **destructive**: `stack_applied()` reversed
patches to probe and restored them with `|| true`, so one failed restore left a tree
that was neither the pin nor the series and silently dropped the `ml1230` blocks
from `Module.S`. It is removed; a patch that no longer applies is now reported and
skipped, with `MADEIRA_PATCHES_STRICT=1` to make that fatal.

**`push-fex-to-device.sh` was not reaching the bundle.** Its bundle candidates all
prepended the wrong container id, so every write failed silently and only the
component path was updated — which `arm64ec-windows/xtajit64.dll` shadows. The
21:20 session therefore ran the 20:47 bundle DLL while the script reported success.
`APP_REL` is now tried first and every copy is read back and hash-checked.
Note that `[build-id] rev=` cannot detect this: it is a hand-maintained literal in
`Module.cpp`, which a `CPUID.h` change does not recompile, so a correct build still
prints the previous revision and date. Hash the bundle copy instead.

## The shipped FEX cannot currently be rebuilt (ml1288)

`dockhost.exe` is the first x86-64 process up and it is what launches the game, so a
`pc=0` crash there blocks every launch. Builds made from the current FEX tree crash it:

```
[x9-probe] x9 is not a thunk shape ExitToX64 knows
err:seh:segv_handler SEGV at pc=0x0 addr=0x0
err:seh:segv_handler   __os_arm64x_check_call=0x0 (not set or bad)
```

`x9` is a plain x64 target in `dockhost.exe`'s own `.text` (base+0x8120). It fails the
thunk shape tests, `ios_ec_entry` correctly misses because the image is `0x8664`, and
`ios_ffs_no_bypass` emulates -- but during `process_attach` no thread has a
`CpuStateFrame`, so `enter_jit` reads an all-zero CPU area and `br x16` jumps to NULL.
This is the failure patch `0004` documents as already fixed by `ml1220`/`ml1230`; those
labels and `ios_ec_entry` are present in the tree, so the guard itself is not missing.

What is established:

* `FEX` HEAD is `12ed8a268` (all commits dated 11-15, none after the good build).
* The build is deterministic: two builds of one tree give one hash (`8770dab9...`).
* A fresh configure is not the cause: the CMake caches of the original and the
  regenerated build directory are identical (76 entries, no diff).
* The patches are not the cause: `0006`/`0011` fail `git apply` but their markers are
  present in HEAD, and skipping them leaves the tree as `HEAD + 0012`.
* HEAD alone (`8770dab9`), HEAD + `0012` (`2816faeb`), and the rebuild after the stash
  (`cc91eff8`) all load on device (verified by hash) and all crash the dock the same way.
* The shipped `xtajit64.dll` (`34632810`) differs from a build of this tree in 34.6% of
  its bytes. Same size, same flags, same source base, so it was **not** produced by
  `build/fex-arm64ec/build.sh` from `12ed8a268`. It is an older artifact that
  `package-ipa.sh` copied out of `app/Madeira/arm64ec-windows/`.

Consequences:

* `34632810` is restored to all three device bundle copies and to
  `app/Madeira/arm64ec-windows/` and `.runtime-cache/windows/files/`, which the 21:18
  build had overwritten with the broken module. Verify with
  `shasum -a 256` on the bundle path, not on `[build-id]`.
* `0012` (hypervisor leaf hiding) is therefore **untested**: it cannot be evaluated
  until a FEX build matches the shipped behaviour, because any build we can currently
  make never reaches the game.
* Next step is to find which source state produced `34632810` -- most likely the FEX
  tree as it stood before the SMC commits (`062205f2b`/`583fbd00e`/`12ed8a268`) were
  built into the shipped module, or with the pre-`IOS_PE_TO_POOL_TO` form of
  `ios_ec_entry`.
## Correction to ml1288: the dock crash is not a FEX regression (ml1290)

The `ml1288` section above is superseded. It read the `dockhost.exe` `pc=0` as caused by a
rebuilt FEX. It is not:

* The shipped `xtajit64.dll` (`34632810`) was restored to all three device bundle paths and
  read back by hash; the crash is **byte-identical** -- same `x9=0x111098120`, same `pc=0`,
  same `addr=0`, same `callee+0x38`. A build cannot be the cause of a fault the known-good
  build also takes.
* The `ml1288` claim that "the good session had no dock crash" compared a *game* log
  (`madeira-last-game-log.txt`) against *app* logs. `dockhost` writes to the app log. That
  comparison was invalid and is what made the regression look real.

Two other explanations were also disproved:

* **`EmulatorData[2]` was not NULL.** `ThreadInit` logs
  `EnterEC=0x12f9b0108` for `teb=0x71fffa0000 area=0x111250000`, i.e.
  `ChpeV2CpuAreaInfo->EmulatorData[2]` was populated, so `enter_jit`'s
  `ldr x16,[x17,#0x40]; br x16` could not have gone to NULL. At the fault `x16=0x14e321900`,
  a valid JIT address.
* **`__os_arm64x_check_call=0x0` is not a signal.** Every module logs
  `check_call=0x000000014DB47354`; the zero is reported for `dockhost.exe`, a pure x64 image
  (`Machine=0x8664`) that legitimately has no ARM64EC metadata.
* **`[jit-gate]` absence proves nothing.** The `enter_jit` route stamp writes 14 raw bytes to
  fd 2, and the marker appears in **zero** logs -- including sessions where the game ran and
  emulated x64 code continuously. fd 2 there is not `madeira-log.txt`, so the marker cannot be
  used as evidence either way.

What the crash actually looks like: `dockhost.exe` is the launch host
(`starting the host for app 2483190; Valve's client authenticates and authorizes the launch`).
Thread `0038` logs the SEGV and then never logs again, and **no further process is spawned** --
no `steam.exe`, no `steamwebhelper`, no game. The UI sits at "Starting Madeira Dock..."
indefinitely, which is consistent with the host dying mid-handshake.

`x9 = 0x111098120` = `dockhost.exe + 0x8120`, whose bytes in the rebuilt image are
`56 57 48 83 ec 28 48 8b 05 43 38 00 00 83 38 02` -- a genuine x64 function
(`push rsi; push rdi; sub rsp,0x28; mov rax,[rip+0x3843]; cmp dword ptr [rax],2`), which is
exactly what must be *emulated*, not branched to. The `[x9-probe]` verdict
"AArch64 code (not an x64 thunk)" is a wrong heuristic in a `dprintf`-only diagnostic; it
cannot affect routing.

Build-infrastructure notes found while packaging:

* `runtime-components.py verify` fails on `dock` unless `HOST_CC` names a real host clang.
  `build-runtime-component.sh` runs `build/madeira-dock/build.sh --check`, whose test build
  uses `clang` from `PATH`, and `setup-llvm-mingw.sh` has already put the mingw clang first --
  so it fails with `'assert.h' file not found`. `HOST_CC=/usr/bin/clang` fixes it, and the
  full dock suite then passes (including *launch-start-when-ceg-already-prepared*).
* `app/Madeira/aarch64-windows/d3d11.dll` no longer matches the shipped IPA at identical size,
  so the tree has drifted. Do not run `runtime-components.py build windows` to "fix" it without
  first checking that it does not overwrite the good `arm64ec-windows/xtajit64.dll`.

Open: `dockhost.exe` is loaded from the **bundle**, not from the prefix, so pushing a rebuilt
copy into `arm64ec-windows/` takes effect on the next launch with no reinstall. That is the
next experiment: the fresh build is `5f7b663f9463ec0b`, and the device copy before this was
never verified against it.
## The dock crash blocks the game, and it is in DllMain (ml1291)

Two facts settled by comparing launches:

* `dockhost.exe` is rebuilt clean (`5f7b663f9463ec0b`, Dock's own suite passing) and pushed
  to all four `arm64ec-windows/` bundle paths with hash read-back. The crash does not change,
  so a stale Dock binary is not the cause either.
* Every launch so far -- including the preserved `madeira-log.prev.txt` -- has
  `dockcrash=2` **and zero game spawns** (`[phase] spawn` lists only dockhost, services,
  conhost and rpcss). No `steam.exe`, no `steamwebhelper`, no game, and none of the host's
  report stages (`probe-start-bits`, `session-authenticated-online`, `ceg-request`, ...)
  ever appear. The Dock report (`C:\madeira-dock.txt`) is never written, so the starting
  screen sits on "Starting Madeira Dock…" (docs/MADEIRA_DOCK.md, the status table).
  This corrects the guess that the crash might be survivable: it is the blocker.

`x9 = dockhost.exe + 0x8120` is **DllMain**:

```
140008120: push %rsi; push %rdi; sub $0x28,%rsp
140008126: mov 0x3843(%rip),%rax      # 0x14000b970
14000812d: cmpl $0x2,(%rax)
140008130: je ...
140008132: movl $0x2,(%rax)
140008138: cmpl $0x1,%edx             # fdwReason
14000813b: je ...
14000813d: cmpl $0x2,%edx
```

So the fault is taken during **process attach's DllMain walk** -- the window `Module.S`
already documents as having no `CpuStateFrame` yet. That makes the guard placement below the
prime suspect rather than the emulator itself.

Guard placement, in the current tree:

```
ios_ec_entry_miss:
  ldp x4, x23, [sp], #16
  b ios_ffs_no_bypass          <-- skips ios_thunk_reject entirely
```

`ml1220`'s "FEX is uninitialised, so do not emulate" guard lives in `ios_thunk_reject`. The
`ios_ec_entry` miss edge branches straight to `ios_ffs_no_bypass`, which is past that guard,
so a fault that arrives via `check_target_ec` -> `ios_ec_entry` -> miss never gets the
protection the comment claims. This is consistent with the crash being byte-identical in the
shipped `34632810` too: the bug is old, not a rebuild artefact.

Caveat, recorded so it is not over-read: at the fault `x16=0x14e321900` and
`[cpu-area] ThreadInit-done tid=0x38 ... EnterEC=0x12f9b0108` show that a valid dispatcher
*was* published for that thread. So "ED2 is NULL" is not established -- the emulator was
entered and then faulted at guest `pc=0`, which is why the next step is instrumentation
(`[cpu-area]` + a slot decode in `build/ntdll-unix/signal_arm64_ios.c`, `ml1290`) rather than
a blind patch to the guard.
## Bisect: FEX and PE ntdll are exonerated; the app binary or the prefix is left (ml1292)

Every committed `xtajit64.dll` and `ntdll.dll` is recoverable with
`git show <commit>:app/Madeira/arm64ec-windows/<file>`, so the guest stack can be bisected
with a push and a relaunch and no rebuild. Hashes per commit:

```
051835e  xtajit=b4f12015 ntdll=f756d580   11-15 12:30   (f756d580 is 1.5MB -- see below)
a7f7bef  xtajit=3ae2dff3 ntdll=20e43e9a   11-15 16:48
03c0422  xtajit=382c1119 ntdll=683a26dd   11-15 17:27
0fdd16c  xtajit=e6931987 ntdll=937edcc0   11-15 17:44
a1187a9  xtajit=34632810 ntdll=6eda4406   11-15 18:14
c6b8dd2  xtajit=34632810 ntdll=001de7db   11-15 18:57
3934444  xtajit=34632810 ntdll=94a3c462   11-15 19:37
06b437a  xtajit=34632810 ntdll=572c8f9a   11-17 20:31
ae7091c  xtajit=34632810 ntdll=b7eff7dd   11-17 20:32
17435bc  xtajit=34632810 ntdll=a0710234   11-17 20:39
```

`b29` (built 11-15 16:23) shipped `xtajit=b4f12015 ntdll=46bd300a`, i.e. the FEX from
`051835e` and an ntdll that is in no commit after it -- b29 is the last pre-FH6 build.

Results, holding the app at `b31` (HEAD) throughout:

| `xtajit64.dll` | `ntdll.dll` | dock |
|---|---|---|
| `34632810` (HEAD) | `a0710234` (HEAD) | crash |
| `b4f12015` (b29) | `a0710234` (HEAD) | crash |
| `b4f12015` (b29) | `46bd300a` (b29) | crash |

So neither guest PE is the cause: the fault stays `pc=...fc70`, `addr=0xfffffffffffffc70`,
`[cpu-area] ED0=0x0`, then the `pc=0` cascade, with both stocks in place. What is left is the
**app binary** (`libntdll_unix.a`, `build/ntdll-unix/virtual_ios.c`) or the **Wine prefix**,
which is why the next test is a full `b29` install: a stock app that still stalls means the
code was never the problem.

If it is the app, the twelve `wine` commits after b29 are the bisect range, and two are
prime suspects because they change how FEX's own hooks are restored:

* `b633c163` (17:02) *do not restore FEX hooks after Denuvo's ntdll .data exec protect* --
  `ios_finish_ntdll_data_preserve` now sets `ios_fex_hooks_live = FALSE` and returns without
  calling `ios_restore_fex_hooks`, relying on post-unix having already done it. That ordering
  is Denuvo-specific; a plain x64 process such as `dockhost.exe` never arms the ntdll `.data`
  interval, so it is the case least likely to satisfy the assumption.
* `f2c8a65c` (17:16) *keep ios_restore_fex_hooks out of line* -- the previous inlined loop
  lost its trip count and became `str; add #8; b` over the RX pool copy of ntdll `.data`
  (7.3M SIGBUS stores, 59MB+ smashed). The fix is correct, but it documents that this area
  can corrupt arbitrary memory, which matches the wild-pointer faults
  (`0xfffffffffffffc70`, `0xffffffffffffff50`, `gregs[RSP]=0`) better than a NULL-slot call
  does.

Also corrected: the 1.5MB `app/Madeira/arm64ec-windows/ntdll.dll` is `051835e`'s committed
content (`n 1572864`), not a stripped-file accident, and the `d3d11.dll` mismatch is
`package-ipa.sh`'s `hide-wine-exports.py` rewriting `app/Madeira/*-windows/*.dll` in place
(git holds `f1cfc568`), not repository drift.
## The Dock stall is not a regression: stock b29 fails identically (ml1293)

`Madeira-0.2.0-b29.ipa` (the last pre-FH6 build, `[build] v0.2.0 (29)`) was installed and
launched. It crashes the Dock exactly as `b31` does -- `pc=...fc70`,
`addr=0xfffffffffffffc70`, the same `pc=0` cascade, the same infinite fault loop, and the same
`dockhost.exe-09d95efb7c42a67b` module. `allow-jit` reads `false` on all four launches, so
that is not the difference either.

That closes the bisect. No component of the FH6 work is responsible:

| `xtajit64.dll` | `ntdll.dll` | app | dock |
|---|---|---|---|
| HEAD `34632810` | HEAD `a0710234` | b31 | crash |
| b29 `b4f12015` | HEAD `a0710234` | b31 | crash |
| b29 `b4f12015` | b29 `46bd300a` | b31 | crash |
| b29 `b4f12015` | b29 `46bd300a` | **b29** | crash |

The Dock path is simply a part that has been broken for at least as long as b29; it was never
exercised by the direct library launches that were working. It is a separate bug, not damage
from the Denuvo/SMC work.

### Root cause

During `dockhost.exe`'s DllMain process-attach, the guest thread runs with an uninitialised
CPU area. The instrumentation shows both halves:

```
[cpu-area] teb=0x71fffa0000 ChpeV2CpuAreaInfo=0x110820000
           ED0=0x0 ED1=... ED2=... ED3=...      <- ED0 is the CpuStateFrame, and it is NULL
[rsp-forensics] x23(SRA RSP)=0x400007 gregs[RSP]=0x0
```

`ED0` NULL and `gregs[RSP]=0` are the same fact seen twice: there is no frame, so RSP reads as
zero. The first stack store in the callee then computes `0 - 0x390` and faults at
`0xfffffffffffffc70` (`x20` = that value, faulting instruction `str w8,[x20]`), which cascades
to `pc=0` and then into the repeating `0x10eb1a8b4` / `0xffffffffffffff50` loop. The starting
screen reads that loop as "Still starting Madeira Dock…" because the host never writes
`C:\madeira-dock.txt`, so no report field ever arrives.

`x23` holding `0x400007` -- the same value as `rax` -- is the register-aliasing signature
`Module.cpp` describes for the broken `SpillStaticRegs` ("State.gregs[REG_RSP] never spilled
before CompileBlock"). That workaround's own logs (`[FEX-iOS] DispatcherPatch`) are dead
channels (ml1216/ml1217), so it cannot be confirmed or refuted from a log; it needs a
LogMan-side counter.

This is case (a) in `IosLogCPUArea`'s taxonomy: **ThreadInit never ran for this thread before
its DllMain was emulated.** The fix belongs there -- make the CPU area and CpuStateFrame exist
before the process-attach walk is emulated -- not in the `x9`/`ios_ec_entry` dispatch route
that earlier notes blamed. Patching that route cannot help: the fault is a stack store with a
zero RSP, which arrives regardless of how the target was reached.
## Where the Dock investigation stands (ml1296)

**Pending one relaunch.** `94c941ae` is on all four bundle paths. It adds the first two
diagnostics this area has ever had on a working channel:

* `[area-state] init-enter | init-set | fail-nostate | fail-callret`
* `[dispatcher-patch] enterEC=… patched=N already_ok=M`

Read `[dispatcher-patch]` first. `patched=0 already_ok=0` means the dispatcher holds no
`SpillStaticRegs` site at all, so RSP is never spilled — that is the fix to write. Non-zero
means the workaround fires and the fault is elsewhere.

### The logging trap that cost three cycles

`LogMan::Msg::EFmt` **works** from this module; `LogMan::Msg::DFmt` is the **no-op**. The
evidence: `IosLogCPUArea` uses `EFmt` and its `[cpu-area]` lines are in every log, while both
attempts at `DFmt` printed nothing. Note this contradicts what the `ml1216`/`ml1217` comments
in `Module.cpp` assert about *all* of this file's logging being dead — those comments are
about `log_hex` (which writes through `WriteFile(hStdError)` / raw `write(2)`), not about
`LogMan`. Before adding a diagnostic here, copy the exact `LogMan` form from a line that
already appears in `madeira-log.txt`.

### What is settled

* Not a regression: stock `b29` fails identically (`ml1293`).
* Not FEX or the PE `ntdll`: bisected to stock and still fails (`ml1292`).
* The `CpuStateFrame` is **intact**, not clobbered. `x28=0x7c00801140` at the fault equals the
  frame published at `ThreadInit-done`. An earlier `ED0=0x0` reading in `ml1294`/`ml1295` was
  misleading — that field only has meaning on the teardown path.
* The real defect: `gregs[RSP]=0` **inside a live frame**, with `x23` (SRA's RSP) holding
  `0x400007` — the same value as `rax`, i.e. the register-aliasing signature `Module.cpp`
  documents for broken `SpillStaticRegs`. The first stack store then computes `0-0x390` and
  faults at `0xfffffffffffffc70`, cascading to `pc=0` and a repeating `0xffffffffffffff50`
  loop that the UI reads as "Still starting Madeira Dock…".
## Cleanroom audit (ml1297): the tested artifact never contained the fix

The ml1296 "pending one relaunch" plan was wrong, and the reason matters more than the
result: **every device test that was supposed to produce `[area-state]` and
`[dispatcher-patch]` ran a binary built before the `DFmt` → `EFmt` change.** The
instrumentation was present as source and as string literals, but the emitted calls were
`DFmt`, which `MSG_LEVEL = INFO` compiles out entirely (`if (MSG_LEVEL < DEBUG) return;` —
`DEBUG > INFO`, so the body, including the format call, is dead code).

Evidence, all offline:

* `Source/Windows/ARM64EC/Module.cpp` mtime `23:03:20`, `Bin/libarm64ecfex.dll` `23:03:28`,
  and `find build-arm64ec -name '*.o' -newer Module.cpp` returned **0 objects**. The link
  ran, the compile did not: the build was mid-flight when the file was edited, so ninja
  linked objects produced from the pre-edit source.
* `strings` finds `[area-state]` / `[dispatcher-patch]` in the old DLL, which is why a
  strings check "confirmed" the instrumentation and cost a relaunch. Their presence proves
  only that the literals exist, not that a logging call references them.
* Rebuilding the same source changed the hash: `94c941ae` → `42c6f147`.

So the absence of `[area-state]` was never evidence about `ThreadInit` — it was evidence
about the build. The `[cpu-area] ThreadInit-done` line that *did* appear comes from an
`EFmt` call that predates this work, which is exactly why it was the only survivor.

**Rule for this area:** before trusting any FEX-side log line, confirm the running artifact
by hash against a freshly built `Bin/libarm64ecfex.dll`, not against the app bundle copy,
and confirm the object is newer than the source.

### `ninja` will silently skip the rebuild

`ninja -C build-arm64ec` reported `no work to do` for `arm64ecfex` while `Module.cpp` was
newer than the *object* but older than the *DLL*. Ninja's mtime check on the final link
output wins, so an edit that lands between compile and link is invisible forever. After
editing `Module.cpp`, `touch` it and rebuild, or check the object mtime explicitly.

### `ninja` default target is broken

`ninja -C build-arm64ec` (all) fails in `FEXOfflineCompiler.exe`, which links `libFEXCore.a`
without the `Source/Windows/ARM64EC` objects and therefore cannot resolve `IosSubfloorEnum`,
`ios_fex_mono_*`, `IosJitSMCFetch`, `FEXCore::DualMap::WriteOffset`, and similar. This is
not a regression in the emulator: build the target instead.
`ninja -C build-arm64ec arm64ecfex` is the only correct invocation.

### Packaging drift

`dist/Madeira.ipa` held `f6baa4f3` for `xtajit64.dll` while `app/Madeira/arm64ec-windows/`
held `94c941ae` — the IPA was older than the bundle it was supposed to contain, so
installing the IPA and pushing the DLL tested two different emulators. The IPA has been
repacked (build 30). Built artifacts and the IPA now agree at `d97aa74f`, which also adds
`[area-state] init-post-crt` -- the first checkpoint after `InitCRTThread`, and therefore the
first one whose silence actually means ThreadInit was not entered.

### Checked and found correct

* The `SpillStaticRegs` patcher's seven hardcoded `stp` words decode exactly as claimed,
  and the register mapping matches `Arm64Emitter.cpp`'s ARM64EC `SRA` table: RAX=x8,
  RCX=x0, RDX=x1, RBX=x27, **RSP=x23**, RBP=x29, RSI=x25, RDI=x26, R8=x2, R9=x3, R10=x4,
  R11=x5, R12=x19, R13=x20, R14=x21, R15=x22. The patcher is not corrupting the spill.
* `SpillStaticRegs` emits from `GPRSpillMask` defaulting to `~0U`, so a *correct* build
  spills all eight pairs including RSP. A missing RSP spill therefore implies either a
  mis-emitted site or a mask that dropped it — it cannot be the mask's default.
* The Wine cross-link pass removes and recreates every `sys32` symlink, so the bundle copy
  does reach the prefix (`[WineProc] Cross-linked 0 non-colliding files` refers only to the
  other arch and is benign).
* `7644eadb6`'s `enter_jit` frame fix is sound. Its root cause is worth remembering: the
  path enters with `sp ≡ 8 (mod 16)` because of `str x30,[sp,#-8]!`, and pairing with SP as
  a writeback base requires 16-byte alignment.

### Workspace hygiene applied

* `Reference/` (176 MB `forzahorizon6.exe`) is now git-ignored; it was untracked and one
  `git add -A` from entering the repo.
* `FEX/build-arm64ec.old.40099` removed. A `find` for `libarm64ecfex.dll` matched it before
  the live build directory, which is how a stale hash can be "verified" by accident.
## Cleanroom audit (ml1298): the component FEX has been overriding the bundle

The bundle was never the emulator the device ran. An **enabled FEX component** is installed in
LiveContainer:

```
Components/FH6-iOS-1.4-fex-fex   name=ml1289  versionCode=41  enabled=true
  layout: ${system32}/xtajit64.dll <- files/lib/wine/aarch64-windows/libarm64ecfex.dll
```

`madeira_wcp_apply` links that file over `${system32}/xtajit64.dll` *after* the bundle's own
pass, replacing it — `push-fex-to-device.sh` documents this explicitly. The session log
confirms it fires: `[wcp] 2 enabled package(s): 8 links, 0 failed` (1 FEX link + 7 wine links).

That component held `cc91eff8`, a **14 Nov** build whose `strings` contain none of
`area-state`, `dispatcher-patch`, or `init-post-crt`. So:

* Every `[area-state]` / `[dispatcher-patch]` absence is explained twice over — the component
  FEX predates the instrumentation entirely, and the bundle copy that did contain it was never
  loaded.
* **The `ml1292`/`ml1293` bisect is invalid.** Stock `b29` and HEAD both reported the same
  `dockhost` fault because both runs executed the same `cc91eff8` component module. That
  "proves" nothing about a regression; it only proves the component was installed. Any FEX-side
  change landed after 14 Nov never ran on device.
* Pushing `xtajit64.dll` into the bundle directory — which is what earlier verification did,
  hashing the bundle path and reading "verified" — leaves the loaded emulator unchanged.

Always push FEX through the component (`tools/wcp/push-fex-to-device.sh`), which now writes all
five bundle copies *and* the component entry. It is the component that decides.

### Verifying which module actually loaded

`Module.cpp:1140` emits, through `EFmt`:

```
[build-id] xtajit64 rev=ml1272 compiled Nov 17 2026 23:17:46
```

The `compiled` timestamp is unique per build and is the only trustworthy answer. If it does not
match the build just pushed, nothing in that DLL ran and the run's crash is not evidence about
it. (The `rev=` tag is stale at `ml1272` and should be bumped; the timestamp is what matters.)

### State after ml1297

Component `FH6-iOS-1.4-fex-fex` is now `ml1297`, versionCode 42, `sha256 d97aa74f…`, enabled,
and its file carries `area-state`, `dispatcher-patch`, `init-post-crt` and `build-id`.
## First honest measurement (ml1299): SpillStaticRegs is NOT broken

The 18 Nov 19:25 run is the first one whose artifact was verified on device:
`[build-id] xtajit64 rev=ml1272 compiled Nov 17 2026 23:17:46` matches the pushed
`d97aa74f`. What it printed:

```
[area-state] init-enter   tid=0x38 area=0x10d010000 ED0=0x0        ED1=0x0 ED2=0x0
[area-state] init-post-crt tid=0x38 area=0x10d010000 ED0=0x0        ED1=0x0 ED2=0x0
[area-state] init-set     tid=0x38 area=0x10d010000 ED0=0x7c00801140 ED1=0x0 ED2=0x0
[dispatcher-patch] enterEC=0x126044108 scan-bytes=8192 patched=0 already_ok=17
```

**`patched=0 already_ok=17`.** The dispatcher holds 17 `SpillStaticRegs` sites and every one
of them already emits the correct `stp`. Nothing was patched, so nothing was broken. Guest RSP
*is* spilled. The theory that has driven this investigation since ml1288 — "FEX emits 7 stale
`madd` where 7 `stp` should be, so `gregs[REG_RSP]` is never spilled" — is **refuted**.

Consequences:

* The ~200-line patcher in `Module.cpp` has never fired on any verified build. It is dead
  code that scans 8 KB at every `ThreadInit`, and it has repeatedly supplied a false
  explanation for a real crash. It should be reduced to a reporter (log the counts, never
  write), or removed.
* `x23 == rax == 0x400007` in the ml1296 notes is *not* evidence of a skipped spill. RSP being
  zero has another cause.

### What the crash actually looks like

`ThreadInit` runs cleanly for `dockhost.exe` (tid `0x38`), publishes a valid frame
(`ED0=0x7c00801140`), and **no failure path runs** — there is no `fail-nostate`, no
`fail-callret`, no "thread state unavailable". So nothing in `ThreadInit` cleared the frame.

The guest state at the fault is nevertheless empty:

```
[x86_live] RAX=0x157566000 RCX=0x10ac30000 ... RSP=0x0
[x86_live] State.RIP=0x0 callret_sp=0x7c01001000
[x86_stk]  live_rsp=0x0 out of range — RSP not yet established
```

`callret_sp` is valid, so the frame itself is sound — `RIP` and `RSP` inside it were simply
never populated. Order of events:

1. `BUS #1: pc=0x157975d74 addr=0x0 insn=0xf90003e0` — a **write to address 0**, inside
   `libarm64ecfex.dll` (pool pc maps to PE `0x71fce79d74`), *before* any x86 code executes.
2. `SEGV #1: pc=0x10f35d64c addr=0xfffffffffffffc70` — the known `0-0x390` stack store.
3. `SEGV #2: pc=0x0 addr=0x0`, then `setup_exception: virtual_handle_fault failed`.

Also decisive, by absence: **`[jit-gate]` never printed.** `enter_jit` publishes its route
before doing anything else, so the crashing entry did *not* come through `enter_jit`. The
`x9`/`ios_ec_entry` dispatch route that the ml1288 notes blamed is therefore not the path
being taken.

So the open question is now narrow and testable: an ARM64EC → x64 dispatch arrives with a null
target and a null stack. The next instrumentation belongs at the EC dispatch entry — log the
target the native code requested, the code-map result, and the RIP/RSP FEX derived from it —
and it must print *before* `enter_jit`, since that is not where this arrives.
## ml1301: the gate faulted on alignment, not a null address

`ml1300` made the `enter_jit` gate test SP before spilling. It still printed no `[jit-gate]`,
and the fault moved from `enter_jit+0x4` to `enter_jit+0x34`. That offset is only reachable
through the `b.hs` taken when SP *passes* the 0x1000 test, which forced a re-read of the
exception rather than another theory:

```
BUS #1: pc=0x14e179da4 addr=0x0 ... insn=0xf90003e0 si_code=1
```

**`si_code=1` is `BUS_ADRALN`, not an address fault.** The `addr=0x0` is the handler's
placeholder, and equal to the immediate in `str x0, [sp]` — the same coincidence that
misleadingly "confirmed" a null SP in ml1296. Disassembling the loaded build settled it:

```
002a: 180119da0: d10103ff   sub  sp, sp, #0x40     <- the b.hs target (SP passed 0x1000)
002b: 180119da4: f90003e0   str  x0, [sp]          <- FLT, BUS_ADRALN
```

So SP is a **real stack that is only 4-byte aligned**. A 32-bit x86 caller can legitimately
hand us `sp ≡ 4 (mod 8)`, and ARM64 stores require natural alignment. ml1231 already fixed one
alignment fault here (16-byte `stp`), and this is the same defect one class down: any spill
through SP faults regardless of the address, which also means the gate could *never* have
reported — it always wrote through SP before writing the tag.

### Why the fix is to not use the stack at all

Guarding on the SP *value* cannot help: the address is fine, the alignment is not, and testing
alignment would only let the gate tag the failure without ever reporting the route. So the gate
now saves `x0-x5` and the incoming SP to a static slot (`IosJitGateSave`) and restores from
there — no stack use, no alignment requirement, report in every case. Verified in the linked
image: `enter_jit` contains no SP-relative store.

Single-slot, so a concurrent second entry could lose a saved value. That only affects the
diagnostic's `x0-x5` payload, never the process, and is preferable to never reporting.

### Verification must use `rev=`, not only the timestamp

`build-id`'s timestamp is `__DATE__`/`__TIME__` of **`Module.cpp`**. A `Module.S`-only change
does not touch it, so the `Nov 17 23:17:46` string persisted across a real rebuild and made a
correctly-deployed binary look stale. `MADEIRA_REV` is now bumped per deploy and must be read
alongside the timestamp: `ml1301 compiled Nov 18 2026 19:37:48`.

### Where this leaves the dock crash

The `enter_jit` gate is no longer part of the crash. ml1301 should print a route tag, and the
first `blr x16` into `enter_jit` from `ntdll.dll+0x81f5c` is the transition to watch. If the tag
arrives with SP at 4 mod 8, the defect is an x86 → ARM64EC entry that does not realign the
stack, and the fix belongs where that ABI boundary is crossed — not in the JIT.
## The dock crash is fixed (ml1301), and it was the gate all along

The ml1301 run is the first with a working `enter_jit` gate, and it settles the whole thread:

```
[build-id] xtajit64 rev=ml1301 compiled Nov 18 2026 19:37:48
[jit-gate] 0                     (x295,583)
BUS faults: none
```

* **No BUS/SEGV at all.** The crash that has blocked the dock since ml1288 does not occur.
* The screen advanced from `Still starting Madeira Dock…` to **`Loading Steam...`**, with
  `dockhost.exe` setting its own unhandled-exception filter (`[uef] ml1255 set #1`).

What the faulting instruction actually was:

```
180119d6c: str x30, [sp, #-0x8]!    <- the push every dispatch path does
180119d70: enter_jit:
180119d70: sub sp, sp, #0x40        <- the gate's frame
180119d74: str x0, [sp]             <- FLT: BUS_ADRALN when SP is 4-byte aligned
```

The `enter_jit` *gate itself* was the crash. It spilled `x0-x5` through SP before writing its
tag, so whenever the dispatch handed it a 4-byte-aligned SP -- which a 32-bit caller can
legitimately do -- the spill faulted, the tag was never written, no `[jit-gate]` line appeared,
and the downstream `0-0x390` store, `pc=0x0`, and the repeating `0xffffffffffffff50` loop all
followed from that first fault. ml1231 fixed the 16-byte `stp` variant of this; the 8-byte
`str` variant survived until ml1301 removed the stack dependency entirely.

So the entire `SpillStaticRegs` / `gregs[RSP]=0` line of reasoning -- ml1288 through ml1299 --
was chasing damage produced by the diagnostic itself. `patched=0 already_ok=17` was the real
answer all along: the emitter was always correct.

### ml1302: the gate now reports once

295,583 `write(2)` calls in four minutes, and 5.9 MB of log. A syscall in the path of every JIT
entry can turn a slow load into a stalled one, so the gate reports the first entry and then
costs three instructions. `x9` (the target the dispatcher asked for) is recorded too.

### Current frontier: `Loading Steam...`

`Steam` is where it stops now. Mapped and running at that point: `steamclient64.dll`,
`tier0_s64.dll`, and an `IPC:CSteamEngine` thread. The engine thread samples at 0% CPU in a
wait state, and `enter_jit` stops being entered, so the next investigation is what that thread
is waiting on -- not FEX, and not the dock.
## ml1302 run: dock clean, Steam reached, then backgrounded

The one-shot gate did its job — 1 line instead of 295,583, and a 10k-line log instead of 613k:

```
[build-id] rev=ml1302 compiled Nov 18 2026 19:44:11
[jit-gate] 0
BUS/SEGV: none
```

`dockhost.exe` completed and the screen advanced to `Loading Steam...`. **The dock stage is no
longer the blocker.**

### What ended the session

Not a crash. Madeira's own summary says *"up to when Madeira went to the background"*, and the
log agrees:

```
19:46:48  [bg-run] keeping Madeira running in the background for: game
          (game 10 min, downloads 60 min, CPU held under 50% of one core)
```

So a run that looks stuck at `Loading Steam... 11s` may simply be **backgrounded**: iOS
suspends it, the log stops, and `enter_jit` stops being entered. Check for that line before
reading a stall as a hang.

`steamerrorreporter64.exe` was spawned and then `[proc-gate] REFUSING spawn … (steamerrorreporter
gate)` — deliberate, so Steam's error dialog cannot cover the screen. It is a symptom worth
noting, not the cause of the stop.

### Where Steam got to

`Steam/logs/connection_log.txt`, `configstore_log.txt` and `appinfo_log.txt` were all written
at 19:46:

```
[2026-11-18 19:46:27] Client version: no bootstrapper found
[2026-11-18 19:46:27] Loaded store 'install' from config\config.vdf successfully
[2026-11-18 19:46:27] Connectivity test: Starting test, fetching 'http://test.steampowered.com/204'
```

and then nothing — the connectivity fetch never completed, because the session was backgrounded
21 seconds later. For contrast, the **17 Nov 21:02 session did log on successfully**
(`Logged On`, `U:1:1189646074`), so the Steam login path has worked before and is not the thing
to fix first.

### Memory is near the ceiling and worth watching

```
[footprint] phys=1575 MB (peak 1581) internal=1568 MB
[jit-pool] used=0x9bcc000/0x34000000          (156 MB of 832 MB)
[no-footprint] pool-RW-alias: ALL 4 variants refused — pool stays jetsam-counted
```

The pool is not the bulk of it (156 MB used); the ~1.5 GB is guest memory. But the exemption
still does not apply: every variant returned `ownership failed kr=4`, and the `plain` variants
report `entry covers only 16384 of 554762240 bytes (partial)` — a 16 KB entry for a 529 MB
region, which is the real reason ownership is rejected. `kr=4` is the consequence, not the
cause. If the dock/Steam stages start getting killed rather than backgrounded, fix the partial
entry first.
## The dock works end to end (ml1302, 18 Nov 19:57)

The stage this document opened on -- `dockhost.exe` dying in `DllMain` and the UI hanging on
"Still starting Madeira Dock…" forever -- is finished. The same day's later run:

```
[dock-report] session-requested-app-entitled=1
[dock-report] session-requested-app-listed=1
[dock-report] session-subscription-count=490
[dock-offline] Valve's client can log this account on offline: saved
[dock-report] launch-client-error=0
[dock-report] session-auth-test-result=0
[dock-report] probe-result=0
[dock-report] shutdown-complete=1
[madeira-dock] host finished (result 0)
```

and then `forzahorizon6.exe` is created, mapped into the pool (`0x70732c0000+0xb3c0000`), loads
85 modules, installs its own unhandled-exception filter, and starts executing. The screen passes
`Loading Steam...` and the game runs its own code.

`Madeira Dock stopped / exited before a game window appeared` is a consequence of what follows,
not a dock failure: the dock returned 0 (success) and the game died before presenting a window.

### What stops the game: Denuvo never decrypts

```
[exc] ml811 code=c000001d addr=000000707863099C        (STATUS_ILLEGAL_INSTRUCTION)
[ud-decrypt] EC handler declined at 000000707863099C: BYTES UNCHANGED (eae96be61448897c)
wine: Unhandled illegal instruction at address 000000707863099C
```

The runtime bytes are **byte-identical to the on-disk image** for that RVA:

```
RVA 0x537099c, .text, file offset 0x536ff9c
on disk : eae96be61448897c 241055488bec4883
in memory: eae96be61448897c ...
region entropy 7.82 bits/byte (Denuvo-encrypted section)
```

So the page was never decrypted. The protection declined to decrypt its own code, the game
executed ciphertext, took an illegal-instruction fault with no valid x64 text window to unwind
through (`[guest-insn] no registered x64 text window`), and terminated with `0xc000001d`. No
missing Windows API accounts for it -- the surrounding `fixme:` lines are unrelated stubs.

This is not an emulation defect in the dock, FEX's dispatcher, or the memory manager. It is the
title's own anti-tamper refusing to run in this environment, and it is a licensing/DRM boundary
rather than a bug to engineer around.

### So the honest status

Everything Madeira owns in this path now works: dock, service manager, Steam launch, PE loader,
ARM64EC emulation, and the pool. What remains is outside the emulator.
## The delivery bug behind "best-effort": native SP is not the guest SP (ml1304)

`[mach-deliver]` picks the faulting thread's TEB by testing whether the faulting SP
lies inside that TEB's stack. That test was written for faults in **native** code,
where the ARM64 SP is the thread's stack. FH6's fault comes from FEX's translated
x86, where the ARM64 SP is the **JIT's** stack; FEX keeps the guest's RSP in its
CpuStateFrame (x28: `+0x18` RIP, `+0x40` RSP — what `[rsp-trunc]` already reads).

The two are wildly different, and the native one is not even plausible:

```
[rsp-trunc]    guest_rip=0x707b5f099c  rsp=0x7081e3fe08   <- inside the TEB stack
[guest-state]  rsp=0x7081e3fe08 rbp=0x7081e3fe60
[mach-deliver] sp=0x71f29f0000                            <- native, outside it
```

`0x71f29f0000` is the **load base of `kernelbase.dll`** in that session
(`[jit-pool] image 0x71f29f0000+0x2f0000 (kernelbase.dll)`). In the previous session
the same field read `0x71f29b0000`, which was kernelbase's base *there*. A module
base, not a stack: so no containment test could ever pass.

Consequences were all in the delivery, not in emulation:

- the TEB was chosen by the ml378 "best-effort" path instead of by containment;
- the frame was placed at `SP_sig(&uc) & ~15`, i.e. at a module base;
- `save_context` wrote that value into `CONTEXT.Sp`, so **the game's own handler ran
  with `Rsp` = a module base** rather than the guest's stack, then declined.

ml1304 reads the guest RSP out of the CpuStateFrame and adopts it when the native SP
is outside the thread's stack and the guest's is inside it. This is safe because the
delivery overwrites SP with the exception frame regardless (`SP_sig(&uc) = frame_addr`),
so the value only feeds frame placement and the handler's `CONTEXT.Rsp` — precisely
the two things that were wrong.

## The cheaper lever this turned up: export-name hashing

`tools/build/package-ipa.sh` already carries the note that settles the shape of this
bug:

> FH6 hashes kernel32 export names for `wine_get_unix_file_name`. Windows does not
> export it; leaving the Wine name makes the game **skip decrypt VEH setup**.

The run reports the same thing from the other side:

```
[wine-export] ... census via=empty-veh mods=85 unix-hits=0 other-wine=19
[wine-export] ... census via=ntdll-data-exec ... other-wine=19
```

`via=empty-veh` is the census firing with **no decrypt VEH installed**, and 19
Wine-identifying exports were still visible to the guest. If the gate is export-name
hashing, then a faithful Windows ABI surface — hiding names Windows does not have —
is what lets the protection take its normal path, and it needs no app rebuild: those
are PE exports in the pushed DLLs.
## The export-name check, recovered exactly (and closed)

`tools/wcp/hide-wine-exports.py` described the check as "FNV-1a's every loaded
module's export names and looks for `0xb2dc38a8e4baecd`". The first half is right and
the constant is real, but the function is not standard FNV-1a 64: FNV-1a 64 of
`wine_get_unix_file_name` is `0x1bdc07c70c6e46ad`, not that constant. Anyone trying to
re-derive the check from that description will conclude the premise is wrong.

It is an FNV-1a with **32-bit constants in a 64-bit accumulator**, over the
**lowercased** name, stopping at NUL or non-ASCII:

```
mov    r13d, 0x811c9dc5
loop:
  movsx  edi, byte [rbx]        ; inc rbx
  cmp    dil, 0x7f ; ja  bail    ; non-ASCII ends the string
  test   dil, dil  ; je  end     ; NUL ends it
  or     edx, 0x20               ; A-Z -> a-z, other bytes unchanged
  xor    rdx, rsi
  imul   rsi, rdx, 0x01000193    ; h = (h ^ c) * 0x01000193
  cmp    rsi, r14
```

at RVA `0x53e30a2`..`0x53e3142`, inside the VEH at `0x53D9270`. With that function
`wine_get_unix_file_name` hashes to `0xb2dc38a8e4baecd` exactly, so the rename to
`xine_get_unix_file_name` (hash `0x6a3373b64979fc54`) does defeat this check -- and the
run agrees: `unix-hits=0`.

### Nothing left to hide

Two more 60-bit constants sit in the same function with the same shape
(`0x0103832b93855b60` at RVA `0x53E0E66`, `0x0ed0cce49a3270ac` at RVA `0x53E1885`), so
the check exists in three copies. Hashing **every export name of every bundled DLL**
(182,299 names across `arm64ec-windows`, `aarch64-windows`, `i386-windows`,
`syswow64`) against all three constants yields **no match at all** -- including no
match for `wine_get_unix_file_name`, which we had already renamed.

So the export-name gate is satisfied, and the `other-wine=19` count in the log is our
own census, not a list the protection compares against. Hiding the remaining 19 names
would have bought nothing; `wine_get_version` correctly stays because FEX resolves it.

Note for the next rebuild: `build/wine-pe/build-ntdll.sh` produces an **unrenamed**
ntdll, and the rename is applied afterwards by `tools/build/package-ipa.sh`. Shipping a
rebuilt ntdll without re-running `hide-wine-exports.py` silently restores the trigger.
