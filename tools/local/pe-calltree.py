#!/usr/bin/env python3
"""Static call graph of a PE image, rooted at its entry point and TLS callbacks.

    tools/local/pe-calltree.py <exe> [--path-to 0xRVA] [--tree] [--depth N]
                                    [--encrypted-only] [--max-nodes N]

Why this exists. Forza Horizon 6 dies on its first call into protected code, and
every question about *why* kept being answered by watching the process run: six
seconds of log, then one #UD. The interesting half of that is offline — the
plaintext init that decides whether to decrypt — and reading it by hand means
finding the chain of callers from the entry point. `--path-to` prints exactly
that chain, so a fault address can be traced back to the code that set it up
without a device, a push, or a launch.

Two things make this cheap and reliable on a protected binary:

  * .pdata is the authoritative function table (414,932 entries in this image),
    so recursion stops at real boundaries instead of guessing from padding.
  * A 64KB block whose zero-byte fraction is under 0.4% is encrypted in this
    image (measured: ~5.8% of .text; plaintext blocks run 5-8% zeros, encrypted
    ones under 0.4%). Functions that start in ciphertext are reported as such
    instead of being disassembled into nonsense, so a chain that dead-ends at an
    encrypted body is *visible* rather than looking like "no callers".

Only direct `call rel32` edges are followed. That is deliberate: indirect calls
(vtables, IAT, register) are exactly where a protector hides its dispatch, so the
graph under-approximates reachability. A missing path here never proves a
function is unreachable; a present path is real.
"""

import struct
import sys
from collections import deque

try:
    import capstone
except ImportError:
    sys.exit("pe-calltree: needs capstone (pip3 install capstone)")


class PE:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        d = self.data
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        nsec = struct.unpack_from("<H", d, pe + 6)[0]
        opt = pe + 24
        self.image_base = struct.unpack_from("<Q", d, opt + 24)[0]
        self.entry = struct.unpack_from("<I", d, opt + 16)[0]
        secoff = opt + struct.unpack_from("<H", d, pe + 20)[0]
        self.sections = []
        for i in range(nsec):
            o = secoff + 40 * i
            name = d[o:o + 8].rstrip(b"\0").decode("ascii", "replace")
            vs, va, rs, ptr = struct.unpack_from("<IIII", d, o + 8)
            ch = struct.unpack_from("<I", d, o + 36)[0]
            self.sections.append((name, va, vs, ptr, rs, ch))
        # .pdata: every (begin, end, unwind) triple
        self.pdata = {}
        for name, va, vs, ptr, rs, ch in self.sections:
            if name == ".pdata":
                for i in range(rs // 12):
                    s, e, u = struct.unpack_from("<III", d, ptr + 12 * i)
                    if s:
                        self.pdata[s] = e
                break
        self._enc = {}
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.md.detail = True
        self._calls = {}

    # ---- address helpers -------------------------------------------------
    def off(self, rva):
        for name, va, vs, ptr, rs, ch in self.sections:
            if va <= rva < va + max(vs, rs):
                delta = rva - va
                return ptr + delta if delta < rs else None
        return None

    def section_of(self, rva):
        for name, va, vs, ptr, rs, ch in self.sections:
            if va <= rva < va + max(vs, rs):
                return name
        return "?"

    def encrypted(self, rva):
        """True when the 64KB block holding rva looks encrypted (see module doc)."""
        block = rva & ~0xFFFF
        if block in self._enc:
            return self._enc[block]
        o = self.off(block)
        verdict = False
        if o is not None:
            chunk = self.data[o:o + 0x10000]
            if len(chunk) >= 1024:
                verdict = chunk.count(0) / len(chunk) < 0.004
        self._enc[block] = verdict
        return verdict

    def func_of(self, rva):
        """Exact .pdata entry covering rva, or rva itself if it is an entry."""
        if rva in self.pdata:
            return rva
        for s, e in self.pdata.items():
            if s <= rva < e:
                return s
        return None

    def func_end(self, fn):
        return self.pdata.get(fn, fn + 0x200)

    # ---- graph -----------------------------------------------------------
    def calls(self, fn):
        """Direct call targets of fn. Empty for a function that starts in ciphertext."""
        if fn in self._calls:
            return self._calls[fn]
        out = []
        end = self.func_end(fn)
        o = self.off(fn)
        if o is None or end <= fn or end - fn > 0x10000 or self.encrypted(fn):
            self._calls[fn] = out
            return out
        blobs = []
        for name, va, vs, ptr, rs, ch in self.sections:
            if va <= fn and end <= va + max(vs, rs) and fn - va < rs:
                blobs.append(self.data[ptr + (fn - va): ptr + (end - va)])
        if not blobs:
            self._calls[fn] = out
            return out
        blob = blobs[0]
        for insn in self.md.disasm(blob, fn):
            if insn.mnemonic in ("ret", "jmp") and insn.mnemonic == "ret":
                break
            if insn.mnemonic == "int3" and insn.address > fn:
                break
            if insn.mnemonic == "call":
                # only rel32 targets are static edges
                if len(insn.bytes) == 5 and insn.bytes[0] == 0xE8:
                    tgt = insn.address + 5 + struct.unpack_from("<i", insn.bytes, 1)[0]
                    if tgt in self.pdata:
                        out.append((tgt, insn.address))
        self._calls[fn] = out
        return out

    # ---- roots -----------------------------------------------------------
    def roots(self):
        out = [("entry", self.entry)]
        o = self.off(0x7756000)
        # TLS directory is not required for the graph; find callbacks if cheap
        for name, va, vs, ptr, rs, ch in self.sections:
            pass
        return out


def tls_callbacks(pe):
    d = pe.data
    # locate TLS directory: data dir 9 in the optional header
    pd = struct.unpack_from("<I", d, 0x3C)[0]
    opt = pd + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96)
    rva, size = struct.unpack_from("<II", d, dd + 8 * 9)
    out = []
    o = pe.off(rva) if rva else None
    if o is None:
        return out
    start, end, index, cbs, zf, ch = struct.unpack_from("<QQQQII", d, o)
    co = pe.off(cbs - pe.image_base) if cbs else None
    if co is None:
        return out
    for i in range(16):
        v = struct.unpack_from("<Q", d, co + 8 * i)[0]
        if v == 0:
            break
        out.append(v - pe.image_base)
    return out


def fmt(pe, rva):
    if rva is None:
        return "?"
    mark = ""
    if pe.encrypted(rva):
        mark = "  [CIPHERTEXT body]"
    return f"{rva:#x} ({pe.section_of(rva)}){mark}"


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path = argv[1]
    args = argv[2:]
    pe = PE(path)
    path_to = None
    tree = False
    depth = 10
    enc_only = False
    max_nodes = 4000
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--path-to":
            i += 1
            path_to = int(args[i], 0)
        elif a == "--tree":
            tree = True
        elif a == "--depth":
            i += 1
            depth = int(args[i], 0)
        elif a == "--encrypted-only":
            enc_only = True
        elif a == "--max-nodes":
            i += 1
            max_nodes = int(args[i], 0)
        else:
            sys.exit(f"unknown argument {a}")
        i += 1

    roots = [("entry", pe.entry)] + [(f"tls[{n}]", r) for n, r in enumerate(tls_callbacks(pe))]
    print(f"image base {pe.image_base:#x}  entry {pe.entry:#x}  "
          f"pdata functions {len(pe.pdata)}  encrypted blocks: ", end="")
    enc_blocks = sum(1 for b in range(0x1000, 0x639ace3, 0x10000) if pe.encrypted(b))
    print(enc_blocks)

    if path_to is not None:
        target = pe.func_of(path_to) or path_to
        print(f"\npaths from roots to {path_to:#x} (function {target:#x}):")
        # BFS with predecessor tracking, then walk back one shortest chain per root
        prev = {}
        seen = set()
        q = deque()
        for label, r in roots:
            fn = pe.func_of(r) or r
            if fn in seen:
                continue
            seen.add(fn)
            prev[fn] = (None, label, r)
            q.append((fn, 0))
        found = []
        nodes = 0
        while q and nodes < max_nodes:
            fn, dist = q.popleft()
            nodes += 1
            if fn == target:
                chain = []
                cur = fn
                while cur is not None:
                    p, label, addr = prev[cur]
                    chain.append((cur, label, addr))
                    cur = p
                chain.reverse()
                found.append(chain)
                continue
            for callee, site in pe.calls(fn):
                if callee in seen:
                    continue
                seen.add(callee)
                prev[callee] = (fn, f"call@{site:#x}", callee)
                q.append((callee, dist + 1))
        if not found:
            print("  no direct-call path found. The graph follows only direct calls, so a")
            print("  protector dispatch (vtable/IAT/register) hides the real edge.")
        for chain in found[:4]:
            total = len(chain)
            for n, (fn, label, addr) in enumerate(chain):
                print(f"  {'  ' * n}{fmt(pe, fn)}   <- {label}")
            print(f"  ({total} nodes)\n")
        return

    if tree:
        def walk(fn, d, label, seen):
            print(f"{'  ' * d}{fmt(pe, fn)}   {label}")
            if d >= depth or fn in seen:
                return
            seen = seen | {fn}
            for callee, site in pe.calls(fn):
                if enc_only and not pe.encrypted(callee):
                    continue
                walk(callee, d + 1, f"call@{site:#x}", seen)

        for label, r in roots:
            fn = pe.func_of(r) or r
            print(f"\n### root {label} -> {fn:#x}")
            walk(fn, 0, label, frozenset())


if __name__ == "__main__":
    main(sys.argv)
