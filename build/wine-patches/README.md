# Madeira's Wine patches

Changes to Wine that Madeira needs and that live in this repository, not in the
Wine submodule's repository. `apply.sh` applies them, in file-name order, to the
Wine working tree before `tools/build/build-wine.sh` configures and builds it;
it skips a patch that is already applied, and `apply.sh --revert` takes them
out. The Wine submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-arm64ec-import-thunk-hotpatch-prologues.patch` | Gives x64 import thunks in ARM64EC builtins the same hotpatch prologue as native Windows (`48 8d a4 24 00 00 00 00 ff 25`), which anti-tamper checks inspect (Forza Horizon 6). Covers both ARM64X builtins (via the CHPE map and the ARM64X export directory) and pure `x86_64` builtins in the ARM64EC farm, which have neither |

The patch changes build output only: `winebuild` rewrites the thunk bytes as it
installs each builtin. Rebuild the PE modules after changing it.

A Forza Horizon 6 run against a farm that still had bare `jmp *__imp_x` thunks
died deterministically with `0xC000001D` at `forzahorizon6.exe+0x537099C`: the
anti-tamper read its own imports as hooked, set its tampered flag, and then
declined the `#UD` its own encrypted function prologues raise, so the VEH
returned `CONTINUE_SEARCH` without decrypting. After rebuilding with this patch
that exception disappears from the log entirely.
