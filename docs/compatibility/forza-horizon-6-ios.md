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
