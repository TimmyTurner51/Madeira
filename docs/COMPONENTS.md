# Windows components (.wcp)

Madeira can import **FEX** and **Wine** component packages in the `.wcp` format
used by [DroidDeck](https://github.com/Droid-Deck) and GameNative/Winlator-style
apps. Settings › **Runtimes** › **Windows components (.wcp)** → **Import .wcp**,
or share a `.wcp` from Files to Madeira.

A `.wcp` is a Zstandard-compressed tar containing a `profile.json` and the
component's files. The importer reads the profile, checks every path, and keeps
the payload in Madeira's own container:

```
Documents/Components/
  state.json                 enabled packages and their file mappings
  <id>/
    profile.json             the package's own profile, kept for reference
    payload/...              its files, unpacked
```

The same button row also has **Import DLL or folder**, for a FEX module or a
set of Wine libraries that was not wrapped in a `.wcp`. Pick
`libarm64ecfex.dll`/`xtajit64.dll` and choose **FEX module**, or pick `.dll`,
`.drv` and `.cpl` files (or a whole folder) and choose **Wine libraries**.
A selected folder keeps its name, so a folder called `aarch64-windows` or
`i386-windows` maps the same way as a package's architecture folder; files
outside one go to `system32`. A direct import is stored like a package and
uses the same enable, disable and remove controls.

Nothing in the app bundle or the code signature changes: the package lives in
the writable Documents folder, and `WineProcessBridge.m` links its files over
the Wine prefix at the start of each Windows session, after the bundle's own
links. Links from a package that is no longer enabled are cleared at that
point, so disabling or removing a package brings the bundled file back at the
next launch. A session already running keeps the files it started with.

## Supported packages

| `profile.json` type | Treated as | Files linked |
|---|---|---|
| contains `FEXCore` | FEX | `libarm64ecfex.dll` → `${sysarm64ec}/xtajit64.dll`, `libwow64fex.dll` → `${aarch64}/xtajit.dll` |
| contains `Builtin` | Wine builtins (PE override) | staged in the component, ahead of the bundle on `WINEDLLPATH` — see below |
| contains `Wine` or `Proton` | Wine | `.dll`, `.drv` and `.cpl` files, by their architecture folder |
| anything else with a `libarm64ecfex.dll` | FEX | as above |
| anything else with DLLs | Wine | as above |

Wine files are mapped by the architecture folder in their path:

| Path contains | Destination |
|---|---|
| `arm64ec-windows`, `x86_64-windows` | `drive_c/windows/system32` |
| `aarch64-windows` | `system32` in an ARM64EC-native session, `sysaa64` in an ARM64EC one |
| `i386-windows` | `drive_c/windows/syswow64` |
| no architecture folder | `system32` |

The package's own `files[].target` paths (DroidDeck writes `${proton}/...` and
`${system32}/...`) are not required; the importer resolves each file by its name
and architecture folder. A `.so` in a FEX package is kept but not linked:
Madeira runs the PE modules, not a Linux host.

## PE builtins that must come from a package (`Wine-Builtin`)

Most Wine PE files live in the prefix and are linked there. `ntdll.dll` does not: Wine's
loader takes it from `WINEDLLPATH`, and the app points that at its own bundle. A package whose
type contains `Builtin` is therefore not linked into the prefix at all — its arch-folder DLLs
are staged into the component folder and that folder is put **in front of the bundle**:

| | |
|---|---|
| staged at | `Documents/Components/<id>/pe/arm64ec-windows/ntdll.dll` |
| `WINEDLLPATH` becomes | `<that pe directory>:<app bundle>` |
| switching the component off | the bundle's own copy is used again |
| the bundle or its signature | unchanged |

```json
{ "type": "Wine-Builtin", "versionName": "ntdll-1.5", "versionCode": 1,
  "files": [ { "source": "files/lib/wine/arm64ec-windows/ntdll.dll",
               "target": "${system32}/ntdll.dll" } ] }
```

`tools/wcp/make-builtin-wcp.sh <version-name> <dll>...` builds one, and the log line
`WINEDLLPATH=... (builtin override first)` confirms the ordering took effect. Only the newest
enabled builtin package contributes, so a replacement release needs no manual removal of the
previous one. A DLL outside `arm64ec-windows`, `aarch64-windows` or `i386-windows` is refused:
landing a module in an architecture it was not built for is worse than not installing it.

## Environment variables

A profile may carry an optional `environment` (or `env`) object:

```json
"environment": { "FEX_TSOENABLED": "1", "FEX_SMCCHECKS": "full" }
```

These are exported while the package is enabled, so a FEX package can ship its
own switches. Values with invalid names are ignored. Per-game variables still
belong in the game's profile or `madeira.cfg` (`env.NAME = value`), which is the
better place for anything game-specific.

## The FEX module must be built for iOS

Madeira's FEX ARM64EC module is a PE with an iOS host layer
(`FEX_IOS_HOST_BUILD`): the JIT pool comes from Madeira's allocator, the
transition code reads the TEB from `TPIDR`, and writes are trapped per 16 KB
host page. A FEX package built for Android or Linux **cannot run** inside
Madeira even though its `libarm64ecfex.dll` is a Windows PE. The importer still
accepts it and notes the mismatch, but a game will not boot on it.

To use a patched FEX (for example one with fixes for a particular game), its
source patches must be applied to Madeira's FEX fork and the module rebuilt:

```sh
# FEX is Madeira's submodule, branch ios-port-2607.
cd FEX
git apply /path/to/your-fex.patch        # rebase it onto this pin first
cd ..
build/fex-arm64ec/build.sh               # writes arm64ec-windows/xtajit64.dll
```

Then package the result in the format this importer accepts:

```sh
tools/wcp/make-fex-wcp.sh MyFEX-1.0 path/to/libarm64ecfex.dll
# -> dist/MyFEX-1.0-fex.wcp
```

`tools/wcp/make-fex-wcp.sh` writes a `FEXCore` profile and a
`libarm64ecfex.dll` payload, which is all Madeira needs. The module is the same
file the build script installs as `xtajit64.dll`.

## Limits and safety

- The archive is streamed through a size-in-advance-free Zstandard decoder
  (`WCP/zstddeclib.c`, zstd 1.5.7; BSD). Decoded output is capped at 6 GB, each
  file at 2 GB, and a package at 100,000 files.
- Absolute paths, `..` components, symlinks and device nodes are rejected; only
  regular files are unpacked.
- `ntdll.dll` is loaded by the Wine loader straight from the bundle's
  `arm64ec-windows/` folder rather than through `system32`, so a Wine package
  that replaces `ntdll.dll` does not replace the session's ntdll. Other system
  DLLs (kernel32, kernelbase, user32, …) do resolve through the prefix and can
  be replaced.
- Logs are tagged `[wcp]`: import results in the app log, the link count for
  each session in the Wine log.
