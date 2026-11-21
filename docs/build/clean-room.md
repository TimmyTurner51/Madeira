# Clean room: stock Madeira + WCP, and what it takes to iterate without an IPA

Date: 2026-11-21. Replaces the accumulated probe state that preceded it.

## What "clean room" means here

The app was reset to `adb1555` — stock Madeira plus the WCP import work and the file
picker, with **no FH6 probe commits**. The point is that `adb1555` is the last commit
where the `wine` and `FEX` submodules still point at their upstream pins
(`wine ddf92bab`, `FEX 1dc6ed49`), so the source tree had no agent-authored
instrumentation in either emulation layer.

Everything removed is recoverable, not deleted:

| Ref | What it is |
|---|---|
| `pre-cleanroom-2026-11-21` (tag) | superproject HEAD before the reset |
| `backup/probes-2026-11-21` (branch) | the same commit, browsable |
| `wine` submodule: `backup/probes-2026-11-21` | the probe wine tree |
| `FEX` submodule: `backup/probes-2026-11-21` | the probe FEX tree |
| submodule stashes `cleanroom-2026-11-21 pre-reset` | uncommitted working-tree edits |

Probe marker counts (occurrences of `mlNNNN`):

| Tree | Before | After |
|---|---|---|
| `wine/` source | 897 | 90 (upstream's own) |
| `FEX/` source | 641 | 70 (upstream's own) |
| `build/` unix layer | 2634 | 791 (upstream's own) |

## The measured cause of the crash on entering the game view

A `SIGABRT` in LiveContainer, 11:43:52, faulting thread:

```
libsystem_c  __assert_rtn
Madeira.debug.dylib  init_registry.cold.1
Madeira.debug.dylib  init_registry
Madeira.debug.dylib  wineserver_main
```

`init_registry` is `wine/server/registry.c:1872`, and the assertion is
`assert( root_key )` right after `create_key_object` for the root key. The archive the
app links is **`app/Madeira/libwineserver.a`, which is not tracked by git** — it is a
build product. A clean `git checkout` leaves it on disk, so the app kept linking the
probe-era wineserver no matter what the source tree said.

That is the general trap this document exists to record: **the Wine unix half is not in
git.** `libntdll_unix.a`, `libwineserver.a` and `libwin32u_unix.a` are silently stale
across a source reset, and stale is indistinguishable from current until you `nm` them:

```sh
nm -a app/Madeira/libwineserver.a | grep -c ml1   # must be 0
```

All three were deleted and rebuilt from the stock sources for this reset. Same for the
iOS FEX build (`FEX/build-ios`), the dock (`build/madeira-dock`), and every runtime
component (`runtime-components.py build all`, needed because each component's manifest
key includes the SDK, so a re-keyed SDK invalidates every cached bundle at once).

## Why an IPA is still required, and the one seam that removes it

Three runtime layers, and in the stock layout only two can be replaced without an IPA:

| Layer | Form | Shipped by |
|---|---|---|
| FEX | PE DLL (`xtajit64.dll`) | **WCP component** |
| Wine PE half (`ntdll.dll`, `kernel32.dll`, ...) | PE DLLs | **WCP component** |
| Wine unix half (`libntdll_unix.a`, `libwineserver.a`, `libwin32u_unix.a`) | Mach-O, static | **IPA only** |

The unix half is Madeira-authored for iOS: `build/ntdll-unix/virtual_ios.c` (the memory
layer), `build/ntdll-unix/signal_arm64_ios.c` (exception delivery) and
`build/wineserver/request_ios.c`. These are exactly the files FH6 work touches, which is
why every Wine-side experiment has cost an IPA.

**The seam.** The unix half is reached through data, not through link-time symbols:

```c
/* wine/dlls/ntdll/unix/loader.c */
*p__wine_unixlib_handle = (UINT_PTR)unix_call_funcs;
```

`__wine_unixlib_handle` is a global in the *PE* ntdll (`wine/dlls/ntdll/loader.c:100`),
and the PE side dispatches every unix call through that table. A different table means a
different unix half.

Also, `build/ntdll-unix/build.sh` already renames each library's table per component
(`-D__wine_unix_call_funcs=${prefix}_unix_call_funcs`) and registers the tables by name
in `virtual_ios.c`'s `load_builtin_unixlib`. A name-keyed registry of function tables is
a much smaller step away from a table loaded from a file than it first appears.

**The unverified assumption.** Delivering that via WCP means `dlopen`ing a Mach-O from
`Documents/Components/<id>/files/`. `Madeira.entitlements` carries
`com.apple.security.cs.allow-jit` and `get-task-allow` but **not**
`com.apple.security.cs.disable-library-validation`, and commit `fae3c55` already measured
that a *replacement* dylib is rejected under LiveContainer ("code signature invalid").
Loading a *new* library is a different dyld path, but it is not proven, and it must be
proven before any load-bearing work is built on it.

So the first IPA after this reset should carry a loader whose only job is to answer that
question and print dyld's exact error. If it loads, the unix half joins FEX and the PE
half as WCP-iterable and the IPA loop ends. If it does not, the honest fallback is to
keep `virtual_ios.c` policy data-driven so that most changes become component *config*
rather than component *code*, and to state plainly that Mach-O changes still need an IPA.

## Build traps worth keeping

- `runtime-components.py verify` fails with "source or SDK does not match" for every
  component after a submodule reset or an Xcode/SDK change, because `input_key()`
  hashes the SDK. `build all` re-keys them; there is no per-component shortcut worth
  using.
- Rebuilding the dock is required after resetting `madeira-dock`, or its manifest key
  disagrees with the bundled `dockhost.exe`.
- `nm -a <archive> | grep -c ml1` after every rebuild. A cached `obj/` directory will
  happily relink stale probe objects into an archive built from clean sources — this
  happened here and produced a byte-identical 5,214,032-byte archive that still had
  eight probe markers in it.
