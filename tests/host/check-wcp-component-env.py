#!/usr/bin/env python3
"""A .wcp component's `environment` map must reach the launch environment.

A package's `profile.json` carries an `environment` map for the same reason
DroidDeck's do: the component *is* the preset. A FEX package needs
`FEX_SMCCHECKS=full`, `FEX_HIDEHYPERVISORBIT=1` and the rest of the set to be in
the process environment before FEX reads its configuration, and FEX reads it
exactly once, at startup. The package itself only carries files.

Until WCPComponents ml1254 that map was dead data: `environment` was parsed,
stored, and then used only to render "· N environment variables" on the settings
row. No `setenv` ever saw it. The evidence is a launch log: the 2026-11-15 11:17
session had the FH6 FEX component (ml1253-hvleaf, enabled, carrying the
reference build's Denuvo baseline) installed and yet exported no `[madeira-env]`
or `[wcp-env]` line for a single one of its keys, so FEX ran under its own
defaults -- `SMCChecks=mtrack` rather than `full`, the hypervisor bit set, and
`CPUID.0x40000000` answering `FEXIFEXIEMU`. An installed component that is not
exported is indistinguishable from one that was never installed.

This check holds the rules the fix depends on, by reading the sources:

  1. WCPComponents exposes the merged environment of ENABLED components only.
  2. The merge is ordered by id, so a key two packages set resolves the same way
     every run instead of following Dictionary order.
  3. Library.applyEnvironment exports it as the FIRST statement -- ahead of
     configureLaunch(). That function returns early for a Steam game started
     through Madeira Dock, which is precisely the case a FEX preset package is
     installed for, so an export written after it would be skipped exactly where
     it matters. (This check exists because the first draft made that mistake.)
  4. The per-game "automatic" x87 choice does not unset a key the component set:
     "automatic" means "leave the baseline", and with a package installed the
     baseline is the package's value.
  5. The precedence the package is documented to have: the component is written
     before the game's own config lines, which still win.

Run with python3; no device, SDK or credentials needed.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def check(ok, what, detail=None):
    if not ok:
        raise SystemExit("FAIL: " + what + ("\n" + repr(detail) if detail is not None else ""))
    print("ok:", what)


components = read("app/Madeira/WCPComponents.swift")
library = read("app/Madeira/Library.swift")

# --- 1/2. the merged environment: enabled only, ordered by id ----------------
block = re.search(r"var launchEnvironment: \[\(name: String, value: String\)\] \{(.*?)\n    \}",
                  components, re.S)
check(block is not None, "WCPComponents declares launchEnvironment")
body = block.group(1)
check("components.filter(\\.enabled)" in body,
      "only enabled components contribute", body)
check("sorted(by: { $0.id < $1.id })" in body,
      "components merge in id order, not Dictionary order", body)
check(re.search(r"merged\[name\] = value", body) is not None,
      "a later component overrides an earlier one for the same key", body)
check(".sorted { $0.key < $1.key }" in body,
      "the result is key-sorted so the launch log is stable", body)

# --- 3. exported first, ahead of configureLaunch's Dock early return ---------
apply_env = re.search(r"func applyEnvironment\(\) \{(.*?)\n    \}\n",
                      library, re.S)
check(apply_env is not None, "Library declares applyEnvironment")
body = apply_env.group(1)
export_at = body.find("WCPComponentsModel.shared.launchEnvironment")
# The STATEMENT, not the mention: this comment names configureLaunch() and that
# mention sits above the export, so a plain find() would compare the wrong pair
# and pass a broken order.
launch_stmt = re.search(r"\n\s+configureLaunch\(\)\n", body)
check(launch_stmt is not None, "applyEnvironment calls configureLaunch()",
      body[:400])
launch_at = launch_stmt.start()
check(0 <= export_at < launch_at,
      "the export is written BEFORE configureLaunch(), whose Dock early return "
      "would otherwise skip it", (export_at, launch_at))
check(re.search(r"for entry in componentEnvironment \{ setenv\(entry\.name, entry\.value, 1\) \}",
                body) is not None,
      "every entry reaches setenv (overwriting, since the package is a baseline)", body[:600])
check("[wcp-env]" in body, "the launch log says what the component exported")
check(body.find("MadeiraConfig.applyGame") > export_at,
      "the game's own config lines are applied after the component, so they win", body[:900])

# --- 4. "automatic" must not delete a component's key ------------------------
x87 = re.search(r"switch x87Precision \{(.*?)\n        \}", body, re.S)
check(x87 is not None, "applyEnvironment still switches on x87Precision")
x87 = x87.group(1)
automatic = re.search(r"case \.automatic:(.*)", x87, re.S)
check(automatic is not None, "the automatic x87 branch is present", x87[:400])
automatic = automatic.group(1)   # to the end of the switch, so the else's unsetenv is included
check("FEX_X87REDUCEDPRECISION" in automatic,
      "the automatic branch names the key it would clear", automatic)
check("componentEnvironment.contains" in automatic,
      "the automatic branch keeps a component's value instead of unsetting it", automatic)
check(0 <= automatic.find("componentEnvironment.contains") < automatic.find("unsetenv"),
      "the component check comes before the unset", automatic)

# --- 5. the preset the FH6 component ships is the reference baseline ---------
# The keys are compared against fh6-wine-fex/README.md when that tree is present,
# because the whole point of the component is to reproduce that environment.
readme = ROOT.parent / "fh6-wine-fex" / "README.md"
if readme.exists():
    text = readme.read_text(encoding="utf-8", errors="replace")
    for key, value in [("FEX_SMCCHECKS", "full"), ("FEX_HIDEHYPERVISORBIT", "1"),
                       ("FEX_MULTIBLOCK", "1"), ("FEX_TSOENABLED", "1")]:
        check(f"{key}={value}" in text,
              f"the reference build documents {key}={value}")

# --- 6. the installed environment actually carries the CPU identity keys ------
# These are read by the FEX module, so a package that sets them but a component
# entry that does not leaves the module on its defaults without saying so.
preset = json.loads((ROOT / "tools/wcp/fh6-fex-env.json").read_text(encoding="utf-8"))
preset_env = preset.get("environment", {})
check(preset_env.get("FEX_CPUBRAND", "").startswith("Intel(R) Core(TM)"),
      "the FH6 preset presents an x86 brand consistent with the vendor leaves that "
      "CPUID 0 and 1 already announce", preset_env)
check("FEX_LOG_CPUID_LEAVES" in preset_env,
      "the FH6 preset keeps CPUID leaf telemetry on so identity probing is observable",
      preset_env)

print("\nPASS: a component's environment reaches the launch, under the game's own settings")
