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

## Conclusion

Two blockers have been retired by measurement rather than inference. The ARM64EC
import-slot mis-route is not present in a current run: no `c0000005` at `pc=0`,
and the iat-sync pass binds every slot it is asked to. And the licence gate is
real but is now satisfied: with Valve's client authenticated in the session, the
client itself starts the game.

What is left is capacity, and it is the third distinct thing this session has
uncovered: a Dock launch's compact 512 MB pool cannot hold the Steam client's
186 MB of image copies, FEX's 272 MB of code buffers and the game's 180 MB image
copy at once. The fix is sizing, not emulation.

`[ud-decrypt]` stays in the tree because it is still the only way to tell a
protection verdict from a later failure, and the game has not yet reached its
first instruction in a Dock session.

Nothing here requires modifying the game, and doing so is excluded: the
protection is meant to run exactly as shipped.

## Next measurement

With the pool raised, the first question is whether the game now reaches its
encrypted entry and what `[ud-decrypt]` says about it — `DECRYPTED` means the
protection accepted this environment, `BYTES UNCHANGED` means it still declined
and the remaining difference is something other than Steam authentication.
