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
`0x1533d4000`, i.e. the copy the guest executes and whose addresses
`GetProcAddress`/the IAT hand out). If the protection hashes code at the
addresses it is given, it sees those 744 sites differ from the file. On a
conforming machine every module reports a zero diff — that is exactly what the
conformance probe's `TextDiff` measures, and what the reference run shows for
every module:

```
module  1 ntdll.dll  … text=75bd0 diff=0 first=ffffffff
module  2 kernel32.dll … text=32310 diff=0 first=ffffffff
```

This is a faithfulness problem, not a game problem: the bytes are ours, not the
protected image's.

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

## Conclusion

The remaining blocker is not an ARM64EC import slot, nor a JIT-pool fault, nor a
lost `#UD`. The protection raises its decrypt trigger and then declines it, so
either it was never given a Steam licence in this session (candidate 1) or it can
see the platform's own rewrites of module code (candidate 2).

Candidate 1 has a supported, faithful path in this tree and is being exercised
next. Candidate 2 would need the `x18` handling to stop modifying the bytes the
guest is handed, which is a real design constraint for this platform and is not
something patching the game could fix — and patching the game is excluded
outright: the protection is meant to run exactly as shipped.
