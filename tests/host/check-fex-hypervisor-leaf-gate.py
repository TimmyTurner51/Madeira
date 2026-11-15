#!/usr/bin/env python3
"""The FEX hypervisor-leaf gate (FEXCore/Source/Interface/Core/CPUID.h); no FEX runs.

FEX_HIDEHYPERVISORBIT exists so a title that misbehaves under emulation can be told it
is on bare metal. It cleared CPUID.1[31] as advertised but left the 0x40000000 range
alone, so the option defeated itself: the guest could still ask the standard "which
hypervisor is this" question and get

    0x40000000: eax = 0x40000001, signature "FEXIFEXIEMU"
    0x40000001: eax[3:0] = 2 = the host is AArch64

while leaf 1 said no hypervisor was present. No real machine answers both ways, so the
inconsistency is the fingerprint -- and a stronger one than the bit, because emulator
detection asks these leaves precisely because they are trivial to read.

This check extracts the real gate text from CPUID.h, compiles it verbatim against stubs
that mirror FEX's own leaf table, and asserts the behaviour in both states:
  - with the option OFF, both hypervisor leaves still answer exactly as before, so
    nothing that relies on FEX's leaves changes;
  - with the option ON, every leaf in the range answers all zeros (the shape a real CPU
    gives an unimplemented leaf), so neither the signature nor the host-architecture
    answer survives;
  - the gate covers the WHOLE range, not just 0x40000000: 0x40000001 leaks the host
    architecture and must be hidden with it.
Needs python3 and a C++17 compiler.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
hdr = (root / 'FEX/FEXCore/Source/Interface/Core/CPUID.h').read_text()

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


# ------------------------------------------------------------------ extract the gate
m = re.search(r'( *constexpr uint32_t HypervisorBase = 0x4000\'0000;\n'
              r' *if \(Function >= HypervisorBase.*?\n    \})', hdr, re.S)
if not m:
    print('FAIL: the hypervisor-leaf gate is not present in CPUID.h')
    sys.exit(1)
gate = m.group(1)

check('HideHypervisorBit()' in gate,
      'the gate must consult HideHypervisorBit, or the option cannot hide the leaves')
check('return {};' in gate,
      'the hidden case must return empty results (all zeros)')
check(gate.index('HideHypervisorBit()') < gate.index('(this->*Handler)'),
      'the option must be tested before the handler is dispatched, not after')

# The range test must be over Hypervisor.size(), which is what covers 0x40000001 too.
count = re.search(r'static constexpr size_t HYPERVISOR_FUNCTION_COUNT = (\d+);', hdr)
check(count and int(count.group(1)) >= 2,
      'HYPERVISOR_FUNCTION_COUNT must cover 0x40000000 and 0x40000001; '
      '0x40000001 reports the host architecture and leaks emulation on its own')

harness = r'''
#include <array>
#include <cstdint>
#include <cstring>
#include <cstdio>

struct FunctionResults { uint32_t eax {}, ebx {}, ecx {}, edx {}; };
static bool g_hide = false;

struct CPUIDEmu {
  bool HideHypervisorBit() const { return g_hide; }

  FunctionResults Function_4000_0000h(uint32_t) const {
    FunctionResults Res {};
    Res.eax = 0x40000001;
    constexpr static char HypervisorID[12] = "FEXIFEXIEMU";
    memcpy(&Res.ebx, HypervisorID, sizeof(HypervisorID));
    return Res;
  }
  FunctionResults Function_4000_0001h(uint32_t) const {
    FunctionResults Res {};
    Res.eax = 2;   /* "the host architecture is AArch64" */
    return Res;
  }

  static constexpr size_t N = 2;
  static constexpr std::array<FunctionResults (CPUIDEmu::*)(uint32_t) const, N> Hypervisor = {
    &CPUIDEmu::Function_4000_0000h,
    &CPUIDEmu::Function_4000_0001h,
  };

  FunctionResults RunFunction(uint32_t Function, uint32_t Leaf) const {
@GATE@
    return {};
  }
};

static int zeros(const FunctionResults& r) {
  return r.eax == 0 && r.ebx == 0 && r.ecx == 0 && r.edx == 0;
}

int main() {
  CPUIDEmu Emu;

  /* OFF: byte-for-byte the previous behaviour. */
  g_hide = false;
  auto a = Emu.RunFunction(0x40000000, 0);
  if (a.eax != 0x40000001) { printf("off: 0x40000000 eax=%x\n", a.eax); return 1; }
  char sig[13] = {};
  memcpy(sig, &a.ebx, 12);
  if (strcmp(sig, "FEXIFEXIEMU")) { printf("off: signature=%s\n", sig); return 2; }
  auto b = Emu.RunFunction(0x40000001, 0);
  if (b.eax != 2) { printf("off: 0x40000001 eax=%x\n", b.eax); return 3; }

  /* ON: no hypervisor leaves at all. */
  g_hide = true;
  if (!zeros(Emu.RunFunction(0x40000000, 0))) { printf("on: 0x40000000 not hidden\n"); return 4; }
  if (!zeros(Emu.RunFunction(0x40000001, 0))) { printf("on: 0x40000001 not hidden\n"); return 5; }
  if (!zeros(Emu.RunFunction(0x40000001, 2))) { printf("on: 0x40000001/2 not hidden\n"); return 6; }

  /* Outside the range the gate must not interfere. */
  if (!zeros(Emu.RunFunction(0x40000100, 0))) { printf("on: out-of-range changed\n"); return 7; }

  printf("ok\n");
  return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='fex-hvleaf-') as tmp:
    tmp = Path(tmp)
    src = tmp / 'hv.cpp'
    src.write_text(harness.replace('@GATE@', gate))
    exe = tmp / 'hv'
    cc = subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-Wall',
                         '-Wno-unused-function', str(src), '-o', str(exe)],
                        capture_output=True, text=True)
    if cc.returncode != 0:
        print('FAIL: the extracted gate does not compile:\n' + cc.stderr[-2000:])
        sys.exit(1)
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    check(run.returncode == 0 and run.stdout.strip() == 'ok',
          'gate behaviour: %s' % (run.stdout.strip() or run.stderr.strip() or 'no output'))

if failures:
    for f in failures:
        print('FAIL: ' + f)
    sys.exit(1)
print('PASS: with FEX_HIDEHYPERVISORBIT off the hypervisor leaves answer as before; with it on '
      '0x40000000 and 0x40000001 both answer all zeros, so neither the FEXIFEXIEMU signature '
      'nor the AArch64 host-architecture answer survives')
