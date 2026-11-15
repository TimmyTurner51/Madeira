#!/usr/bin/env python3
"""Test the production TLS/pointer sync call, including failed copy and bad arguments."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'build/ntdll-unix/virtual_ios.c').read_text()
a=s.index('NTSTATUS unixcall_ios_sync_pe_write(void *args)')
fn=s[a:s.index('\n}',a)+2]
loader=(root/'build/ntdll-unix/loader_ios.c').read_text()
pe=(root/'wine/dlls/ntdll/loader.c').read_text()
sig=(root/'wine/dlls/ntdll/signal_arm64ec.c').read_text()
assert 'unix_ios_sync_pe_write' in (root/'wine/dlls/ntdll/unixlib.h').read_text()
assert 'ios_wrap_13,' in loader and 'wow64_ios_unsupported,               /* ios_sync_pe_write */' in loader
slot=pe[pe.index('static BOOL alloc_tls_slot('):pe.index('static void free_tls_slot(')]
assert slot.index('*(DWORD *)dir->AddressOfIndex = i;') < slot.index('WINE_UNIX_CALL( unix_ios_sync_pe_write') < slot.index('tls_dirs[i] = *dir;')

# The ARM64EC dispatcher path reuses the same call with a pointer-sized request.
# If either side drifts back to four bytes only, ucrtbase's
# __os_arm64x_dispatch_call_no_redirect slot keeps its pre-sync zero and
# `ldr x16,[x8,#0x898]; blr x16` branches to pc=0 again.
assert 'sizeof(ULONG) && p->size != sizeof(void *)' in fn, \
    'unixcall_ios_sync_pe_write must accept the pointer-sized request'
hyb=sig[sig.index('static void update_hybrid_pointer('):sig.index('arm64ec_update_hybrid_metadata\n')]
assert 'sizeof(void *)' in hyb and 'unix_ios_sync_pe_write' in hyb, \
    'update_hybrid_pointer must sync the pointer slot into the pool copy'
assert 'ios_jit_translate_addr_for_owner' in fn, \
    'the pointer path must store the pool alias, not the PE VA'

code=r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef uint32_t ULONG, NTSTATUS;
typedef uint64_t uintptr_t_;
#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER 1
#define STATUS_UNSUCCESSFUL 2
#define STATUS_PROCEDURE_NOT_FOUND 3
struct ios_sync_pe_write_params { void *address; ULONG size,synced; };
static unsigned char pe_word[8];        /* the PE-side slot the loader filled      */
static unsigned char copy[8];           /* the pool copy the guest executes        */
static unsigned char aliasword[8];      /* what the pool alias resolves to         */
static int copied=1, fail, calls, x86;
static void *alias_of(void *v) { (void)v; return (void *)aliasword; }
static void *ios_jit_translate_addr(void *p) { return copied ? (void *)copy : p; }
static void *ios_jit_translate_addr_for_owner(void *p, void *peb) { (void)peb; return alias_of(p); }
static void *ios_jit_current_peb(void) { return (void *)0x1234; }
static int ios_va_is_x86_code(uint64_t v) { (void)v; return x86; }
static void ios_jit_sync_write(void *p, ULONG size) { calls++; if(!fail) memcpy(copy,p,size); }
FUNCTION
int main(void) {
    struct ios_sync_pe_write_params p;
    uint64_t v;

    assert(unixcall_ios_sync_pe_write(NULL)==STATUS_INVALID_PARAMETER);

    /* 16 bytes stays refused so a wide request cannot stomp live neighbours. */
    p.address=&pe_word; p.size=16; p.synced=7;
    assert(unixcall_ios_sync_pe_write(&p)==STATUS_INVALID_PARAMETER && p.synced==7);

    /* 4-byte TLS index path, unchanged. */
    p.size=4; p.address=NULL; assert(unixcall_ios_sync_pe_write(&p)==STATUS_INVALID_PARAMETER);
    memset(pe_word,0,8); memset(copy,0,8); pe_word[0]=9; p.address=&pe_word; copied=0;
    assert(!unixcall_ios_sync_pe_write(&p) && !p.synced && !calls);
    copied=1; assert(!unixcall_ios_sync_pe_write(&p) && p.synced && copy[0]==9);
    fail=1; pe_word[0]++; calls=0;
    assert(unixcall_ios_sync_pe_write(&p)==STATUS_UNSUCCESSFUL && !p.synced);

    /* 8-byte dispatcher slot: the pool copy gets the POOL ALIAS, never the PE
     * VA, because guest code branches through the pool word. */
    fail=0; x86=0; calls=0; memset(copy,0,8);
    v=0x71fe810f1cULL; memcpy(pe_word,&v,8); p.address=&pe_word; p.size=8; p.synced=0;
    assert(!unixcall_ios_sync_pe_write(&p) && p.synced);
    { uint64_t got; memcpy(&got,copy,8);
      assert(got==(uint64_t)(uintptr_t_)alias_of(0)); }
    assert(((uint64_t*)pe_word)[0]==v);          /* PE side keeps the Windows value */

    /* An x86/FEX target must stay untranslated: emulation needs the real VA. */
    memset(copy,0,8); x86=1;
    assert(!unixcall_ios_sync_pe_write(&p) && p.synced);
    { uint64_t got; memcpy(&got,copy,8); assert(got==v); }

    /* A zero slot stays zero: the loader has not resolved it yet. */
    memset(copy,0xff,8); v=0; memcpy(pe_word,&v,8);
    assert(!unixcall_ios_sync_pe_write(&p) && p.synced);
    { uint64_t got; memcpy(&got,copy,8); assert(got==0); }

    puts("PASS: TLS index sync, pointer-slot alias sync, invalid requests and failed verification");
}
'''.replace('FUNCTION',fn)
with tempfile.TemporaryDirectory() as d:
    c,exe=Path(d)/'tls.c',Path(d)/'tls';c.write_text(code)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-function',
                    '-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
