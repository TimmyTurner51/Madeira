# Forza Horizon 6 — iOS launch record and current blocker

Status: **not yet playable on iOS.** The game loads, runs a large part of its own
code, and then dies on an illegal instruction inside one of its own protected
functions. This document records measured evidence only; it is not a
compatibility report and makes no performance claim.

Device: iPhone 17 Pro, game through LiveContainer inside Madeira, Steam build
`forzahorizon6.exe` (app `2483190`), ARM64EC under FEX.

## What is established, with the evidence

`.text` is protected and only partly decrypted. The image's first executable
section has entropy **7.740 bits/byte**, and 5,985 functions begin with bytes
that are not a valid 64-bit instruction (`0xea`, `0xd4` and similar). Each of
those still decodes from the second instruction on, and each section's
`UNWIND_INFO` `prolog_size` accounts for the scrambled prefix exactly
(`5 + 27 = 32` at RVA `0x537099C`). That is the signature of per-function
encrypted prologues, not of a packer and not of an unpacked image.

The bytes at the faulting address are identical to the file on disk. At RVA
`0x53749D0` memory and the file both hold
`d4 7d f5 82 cb 91 0b 1f 93 42 01 82 48 8b f8 48`. The first byte, `0xd4`
(`AAM`), is an invalid opcode in 64-bit mode and FEX therefore decodes one byte
and reports `Invalid instruction in entry block`; real code (`48 8b f8`,
`mov rdi, rax`) only begins at `+0x0b`. So the prologue at that address was
never decrypted, while surrounding code plainly was: the process ran enough
of the image to install and enter SEH handlers at
`forzahorizon6.exe+0x5A66460` and `+0x5EAA3B8`.

The exception is raised and then declined by the game's own code, not lost by
Wine. The run logs `Passing through exception`, then
`[exc] ml811 code=c000001d`, then both game handlers, then Wine's unhandled
filter. Nothing in the exception path drops the `#UD`; the protection decides
not to act on it.

## Why it is declined: the launch never asks Steam for a licence

The launch path in use starts the executable itself:

```
[steam-start] app=2483190 direct source=steam args=0 folder=program
[steam-start] direct start: the game's own Steam identity (app 2483190) published
```

That is `LibraryEntry.steamStart == "game"` (`SteamDirectStart.mode`), which
`SteamGames.swift` documents as the mode for "games that do not need Steam
(DRM-free ones)". It publishes `SteamAppId`/`SteamGameId`/`SteamAppPath` and
runs the exe. `steam_api64.dll` does load, but no Steam client process exists in
that session, so there is nothing for the client to authenticate against and no
ticket for the protection to accept. This holds regardless of whether the prefix
has ever been signed in: in this mode the licence question is never asked.

Supporting detail from the prefix — it holds the app manifest and the client but
no stored sign-in:

| Check | Result |
|---|---|
| `.../Steam/config/loginusers.vdf` | absent |
| `.../Steam/config/ssfn*` | absent |
| `.../Steam/steamclient64.dll` | present, SHA-256 `71b391fe…ecf640` |
| `.../Steam/steamapps/appmanifest_2483190.acf` | present |

`loginusers.vdf` is written by the full client UI, which Dock deliberately does
not run, so its absence alone does not prove no sign-in ever happened. What is
missing is any evidence of a Dock session at all: no retained Madeira log
contains `dockhost`, `steam-host` or `steam-signin`. Dock is also the only path
that populates the client's licence cache (an online logon precedes any offline
logon, and the client caches the answer itself), so the licence question has
never been put to Valve in this prefix.

## The faithful path already exists in this tree

`docs/MADEIRA_DOCK.md` describes exactly what this title needs: `dockhost.exe`
loads Valve's own `steamclient64.dll`, signs in with the user's own Steam
sign-in, and asks the client to start the game with Valve's `LaunchApp` — "Valve's
client performs the online authentication and the licence check. The game, its
Steam API calls and any DRM run exactly as Valve ships them." It is explicitly
not a DRM bypass and it fails closed without a confirmed licence.

The client build in the device prefix is one of the two builds Dock is verified
against (`madeira-dock/docs/CLIENT_LAYOUTS.md`, the January adapter), so the
adapter is available and does not fail closed on the hash:

```
71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640  steamclient64.dll
```

The reference implementation this is being compared against (FEX ARM64EC inside
Proton on an ARM64 Android device) reaches gameplay on this title, and it starts
it the same way — through the Steam client, with the client signed in and its UI
running — never by spawning the executable.

## Conclusion

The remaining blocker is not an ARM64EC import slot or a JIT-pool fault. It is
that the launch path never presents a Steam licence, so the protection stops
decrypting. Two things are needed, in this order:

1. Sign in to Steam in Madeira once, so the prefix has a client session.
2. Start the game through the Steam client (Madeira Dock, i.e. **Start with:
   Steam**), not as its own program.

Anything else — resolving more import slots, teaching more hotpatch shapes,
patching the image — cannot substitute for the licence, and patching the image
is excluded outright: the protection is meant to run exactly as shipped.
