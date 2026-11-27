#!/usr/bin/env python3
"""Argument tables reused between same-state draws (madeira.cfg table-cache, default 1);
no Wine, no Metal.

mad_air_build_tables_ex rebuilt a draw's argument tables from scratch every
time: fresh zeroed ring slots for the constant-buffer and argument tables, one
root-signature resolve walk per shader binding (mad_air_resolve), a ring copy
per root-constants parameter. In the replay split that whole build is RS_TABLES,
and the same-state draw (FH6's draw bursts) pays it again for identical bytes.
The tables are a pure function of the state a build reads -- the root
signature, the root and constant arrays, the PSO's AIR ranges and binds, the
bound descriptor heaps -- so the cache remembers each build's ring offsets and
a later draw with the same key re-binds them (draw-dedup then elides the binds
too) instead of building again.

Correctness is entirely in the invalidation:

* tc_gen (in struct mad_exec, so the cache is scoped to one list replay and the
  offsets it returns live in that list's ring chunks) is bumped at every replay
  writer of the state the resolve reads: MC_ROOT, MC_ROOT_CONST, MC_ROOTSIG,
  MC_CROOT, MC_CROOT_CONST, MC_CROOTSIG, MC_HEAPS. The cbv-snapshot and
  static-cbv transformers write only stack copies of the root array, never the
  arrays the builds take.
* g_desc_gen is bumped by the application thread at every descriptor write
  (Create*View, CopyDescriptors*, the only writers of a heap's CPU descriptors;
  mad_uavctr_put rides on CreateUnorderedAccessView). A hit is refused whenever
  anything was written since the build.
* A build that fails is never cached; skin-check frames and table dumps run the
  body every time.

In the source: the key compare names every input of the body plus both
generations and runs before the body; the store runs after it and only on
success; g_desc_gen is sampled before the body reads any descriptor; the
switch is read once (default 1); the catalog lists table-cache, on by default.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
src = (root / "madeira-d3d12/src/pe/madeira_d3d12.c").read_text()
cat = (root / "app/Madeira/ConfigCatalog.generated.swift").read_text()
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


def block(start_anchor, end_anchor):
    i = src.index(start_anchor)
    return src[i:src.index(end_anchor, i)]


# --- the cache lives in struct mad_exec (one list replay) -----------------
ex = block("struct mad_exec {", "};")
check("table-cache fields live in struct mad_exec (per list replay)",
      "unsigned tc_gen;" in ex and "unsigned tc_hit, tc_miss;" in ex)
check("a cache entry keys on every input and holds the ring offsets",
      all(s in ex for s in ("const struct mad_rootsig *rs;", "const void *consts;", "const void *airv;",
                            "unsigned nair, cb_bind, arg_bind, arg_qwords, vis_mask;",
                            "unsigned gen; LONG dgen;", "obj_handle_t cb_buf, arg_buf; UINT64 cb_off, arg_off;")))

# --- invalidation: every replay writer of the resolve inputs bumps tc_gen -
run = block("case MC_PSO: if (c->u.pso && c->u.pso->is_compute)", "case MC_BARRIER:")
for case in ("case MC_ROOT:", "case MC_ROOT_CONST:", "case MC_ROOTSIG:",
             "case MC_CROOT:", "case MC_CROOT_CONST:", "case MC_CROOTSIG:", "case MC_HEAPS:"):
    i = run.index(case)
    nxt = [p for p in (run.find("case MC_", i + 5), run.find("case MC_BARRIER", i + 5)) if p >= 0]
    check("%s bumps tc_gen (table-cache invalidation)" % case[:-1],
          "e.tc_gen++;" in run[i:min(nxt)])
check("exactly those seven writers exist in the replay switch",
      len(re.findall(r"e\.tc_gen\+\+;", run)) == 7)

# --- invalidation: every descriptor writer bumps g_desc_gen --------------
writers = ("device_CreateConstantBufferView", "device_CreateShaderResourceView",
           "device_CreateUnorderedAccessView", "device_CreateSampler",
           "device_CopyDescriptorsSimple", "device_CopyDescriptors")
ranges = []
for w in writers:
    i = src.index("static void STDMETHODCALLTYPE %s(" % w)
    j = src.index("\nstatic ", i + 10)
    ranges.append((i, j))
    check("%s bumps g_desc_gen at every descriptor write" % w,
          "InterlockedIncrement(&g_desc_gen);" in src[i:j] and "mad_dg_write(" in src[i:j])
calls = [m.start() for m in re.finditer(r"(?<!void )mad_dg_write\(", src)]
check("every mad_dg_write call site (the descriptor-write markers) sits in a g_desc_gen writer",
      all(any(lo < p < hi for lo, hi in ranges) for p in calls))

# --- the cache decision in mad_air_build_tables_ex ----------------------
b = block("static int mad_air_build_tables_ex(struct mad_exec *e", "static int mad_air_build_tables(")
check("config read once, default 1",
      'g_tab_cache = mad_cfg_int_pe("table-cache", 1) ? 1 : 0;' in b and "if (g_tab_cache < 0) {" in b)
check("g_desc_gen is sampled before the body reads any descriptor",
      b.index("LONG dg = g_desc_gen;") < b.index("mad_air_build_tables_ex_body("))
check("the key compare names every input plus both generations",
      all(s in b for s in ("t->gen == e->tc_gen", "t->dgen == g_desc_gen", "t->rs == rs", "t->root == root",
                           "t->consts == (const void *)consts", "t->pso == pso", "t->airv == (const void *)airv",
                           "t->nair == nair", "t->cb_bind == cb_bind", "t->arg_bind == arg_bind",
                           "t->arg_qwords == arg_qwords", "t->vis_mask == vis_mask")))
check("the compare runs before the body; the hit returns the stored offsets",
      b.index("t->dgen == g_desc_gen") < b.index("mad_air_build_tables_ex_body(")
      and "e->tc_hit++;\n            return 1;" in b)
check("the store runs after the body and only on success, with the pre-body generation",
      b.index("if (t0) mad_rs_step(RS_TABLES, &t0);") < b.index("if (ok && t) {")
      and "t->dgen = dg;" in b and "t->cb_off = *cb_off;" in b and "e->tc_miss++;" in b)
check("failed builds are not cached", "a failed build is not cached" in b)
check("skin-check frames and table dumps build every time",
      "if (g_tab_cache && !e->sk && !g_dump_tables) {" in b)

# --- the config surface -------------------------------------------------
seg = cat[cat.index('"table-cache"'):]
check("the catalog lists table-cache, on by default",
      'defaultValue: "1"' in seg[:seg.index("\n")] and 'title: "Reuse argument tables' in seg[:seg.index("\n")])

print("PASS" if ok else "FAILED")
raise SystemExit(0 if ok else 1)
