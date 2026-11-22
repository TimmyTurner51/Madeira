# Madeira's Wine patches

Changes to Wine that Madeira needs and that live in this repository, not in the
Wine submodule's repository. `apply.sh` applies them, in file-name order, to the
Wine working tree before `tools/build/build-wine.sh` configures and builds it;
it skips a patch that is already applied, and `apply.sh --revert` takes them
out. The Wine submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-arm64ec-import-thunk-hotpatch-prologues.patch` | Gives x64 import thunks in ARM64EC builtins the same hotpatch prologue as native Windows (`48 8d a4 24 00 00 00 00 ff 25`), which anti-tamper checks inspect (Forza Horizon 6). Also refuses to write a prologue that would run past a section's `VirtualSize`: the last thunk in `kernel32` sits flush against the end of `.text`, and the truncated prologue `llvm-strip` would leave behind decodes as `lea rsp,[rsp+0xcccc0000]` (§4ao) |

The patch changes build output only: `winebuild` rewrites the thunk bytes as it
installs each ARM64EC builtin. Rebuild the PE modules after changing it.

> **WARNING — do not ship this patch's output in the app bundle yet (§4an, §4aq).** The
> only builtin it changes is `kernel32.dll` (`ntdll` and `kernelbase` have no
> `ff 25` import thunks to rewrite). A `kernel32.dll` carrying those prologues
> reproducibly stops `dockhost.exe` from authorising a launch: no game process is
> spawned, with no loader error and no `#UD`. The dock does not refuse — it dies on an
> unhandled `c0000005` at `pc=0` inside the `arm64x_check_call` path whose `x18`/TEB read
> is documented in `signal_arm64ec.c` as wrong-but-unlandable. The trigger is the
> *number* of prologued exports (1, 8, 9, 12 all launch; 13–16 and up crash), not which
> ones, so there is no safe subset to ship. The bundle's bare-thunk `kernel32` is
> therefore kept, and `runtime-components.py build windows` will overwrite it — re-check
> `tools/local/pe-thunks.py` after any component rebuild.
