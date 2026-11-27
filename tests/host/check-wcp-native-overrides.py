#!/usr/bin/env python3
"""Host verification for native .wcp overrides:

1. Bundled wineserver in libntdll_unix.dylib:
   - unixhalf_entry.c exports all 8 madeira_unix_half_wineserver_* entry points
     and sets madeira_unix_half_wineserver_active=1 when the app launches wineserver
     through the dylib.
   - build/ntdll-unix/build-dylib.sh links libwineserver.a and exports all 8 symbols.
   - build/ntdll-unix/server_ios.c and wine/dlls/ntdll/unix/sync.c preserve backward
     compatibility with older app binaries by falling back to dlsym(RTLD_DEFAULT, ...)
     when madeira_unix_half_is_dylib=1 and madeira_unix_half_wineserver_active=0.
   - app/Madeira/UnixHalf.swift, WineServerBridge.m, WineProcessBridge.m,
     LogStore.swift, and ContentView.swift route wineserver lifecycle/state through
     UnixHalf with fallback to libwineserver.a.
   - build/wineserver/build.sh renames server_start_time, supported_machines_count,
     and native_machine so libwineserver.a links cleanly alongside ntdll-unix.

2. Standalone libmadeira_ir_unix.dylib override:
   - dxmt/src/winemetal/unix/winemetal_unix.c resolves libmadeira_ir_unix.dylib via
     madeira_wcp_dylib_path before falling back to the linked madeira_ir_convert.
   - build/dxmt-patches/0002-winemetal-ir-unix-wcp-override.patch is present.
   - build/dxmt-ios/build-ir-dylib.sh exports only _madeira_ir_convert.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

WS_EXPORTS = [
    "madeira_unix_half_wineserver_main",
    "madeira_unix_half_wineserver_log_set_file",
    "madeira_unix_half_wineserver_set_nls_dir",
    "madeira_unix_half_wineserver_inject_client_fd",
    "madeira_unix_half_wineserver_foreground_addr",
    "madeira_unix_half_wineserver_ready_addr",
    "madeira_unix_half_wineserver_log_quiet_addr",
    "madeira_unix_half_wineserver_set_ui_log_callback",
]

entry_c = (ROOT / "build/ntdll-unix/unixhalf_entry.c").read_text()
build_dylib = (ROOT / "build/ntdll-unix/build-dylib.sh").read_text()
for sym in WS_EXPORTS:
    assert sym in entry_c, f"missing {sym} in unixhalf_entry.c"
    assert f"_{sym}" in build_dylib, f"missing _{sym} in build-dylib.sh export list"

assert '"$ROOT_APP/libwineserver.a"' in build_dylib, "libwineserver.a not linked in build-dylib.sh"
assert "int madeira_unix_half_is_dylib = 1;" in entry_c
assert "volatile int madeira_unix_half_wineserver_active = 0;" in entry_c

ws_build = (ROOT / "build/wineserver/build.sh").read_text()
for sym in ("server_start_time", "supported_machines_count", "native_machine"):
    assert sym in ws_build, f"missing collision rename for {sym} in build/wineserver/build.sh"

server_c = (ROOT / "build/ntdll-unix/server_ios.c").read_text()
assert "ios_active_srv_direct_call" in server_c
assert "ios_active_wineserver_ring" in server_c
assert 'dlsym( RTLD_DEFAULT, "ios_srv_direct_call" )' in server_c
assert 'dlsym( RTLD_DEFAULT, "ios_wineserver_ring" )' in server_c

sync_c = (ROOT / "wine/dlls/ntdll/unix/sync.c").read_text()
assert "ios_active_sync_cells" in sync_c
assert 'dlsym( RTLD_DEFAULT, "madeira_sync_cells" )' in sync_c

unix_half_swift = (ROOT / "app/Madeira/UnixHalf.swift").read_text()
for sym in WS_EXPORTS:
    assert f'"{sym}"' in unix_half_swift, f"UnixHalf.swift missing {sym}"
for cdecl in (
    "madeira_unix_half_wineserver_start",
    "madeira_unix_half_wineserver_set_log_file",
    "madeira_unix_half_wineserver_set_nls_dir_bridge",
    "madeira_unix_half_wineserver_inject_fd",
    "madeira_unix_half_wineserver_set_foreground",
    "madeira_unix_half_wineserver_ready_ptr",
    "madeira_unix_half_symbol",
    "madeira_wcp_dylib_path",
):
    assert f'@_cdecl("{cdecl}")' in unix_half_swift, f"UnixHalf.swift missing @_cdecl {cdecl}"

ws_bridge = (ROOT / "app/Madeira/WineServerBridge.m").read_text()
for fn in (
    "madeira_unix_half_wineserver_start",
    "madeira_unix_half_wineserver_set_log_file",
    "madeira_unix_half_wineserver_set_nls_dir_bridge",
    "madeira_unix_half_wineserver_set_foreground",
    "madeira_unix_half_wineserver_ready_ptr",
):
    assert fn in ws_bridge, f"WineServerBridge.m missing {fn}"

proc_bridge = (ROOT / "app/Madeira/WineProcessBridge.m").read_text()
assert "madeira_unix_half_wineserver_inject_fd" in proc_bridge

log_store = (ROOT / "app/Madeira/LogStore.swift").read_text()
assert "UnixHalf.setWineserverUILogCallback" in log_store

content_view = (ROOT / "app/Madeira/ContentView.swift").read_text()
assert "UnixHalf.setWineserverLogQuiet(1)" in content_view
assert "UnixHalf.setWineserverLogQuiet(0)" in content_view

# Check libmadeira_ir_unix.dylib override
wm_c = (ROOT / "dxmt/src/winemetal/unix/winemetal_unix.c").read_text()
assert '"libmadeira_ir_unix.dylib"' in wm_c
assert '"madeira_wcp_dylib_path"' in wm_c
assert '"madeira_ir_convert"' in wm_c
assert (ROOT / "build/dxmt-patches/0002-winemetal-ir-unix-wcp-override.patch").is_file()

ir_script = (ROOT / "build/dxmt-ios/build-ir-dylib.sh").read_text()
assert "_madeira_ir_convert" in ir_script

# If the dylibs are already built on disk, verify their Mach-O export tables directly.
nt_dylib = ROOT / "build/ntdll-unix/libntdll_unix.dylib"
if nt_dylib.is_file():
    out = subprocess.check_output(["nm", "-gU", str(nt_dylib)], text=True)
    exported = {line.split()[-1] for line in out.splitlines() if len(line.split()) >= 3}
    for sym in WS_EXPORTS:
        assert f"_{sym}" in exported, f"_{sym} not exported by built libntdll_unix.dylib"
    print(f"PASS: built libntdll_unix.dylib exports all {len(WS_EXPORTS)} wineserver entry points ({len(exported)} total)")

ir_dylib = ROOT / "build/dxmt-ios/libmadeira_ir_unix.dylib"
if ir_dylib.is_file():
    out = subprocess.check_output(["nm", "-gU", str(ir_dylib)], text=True)
    exported = sorted({line.split()[-1] for line in out.splitlines() if len(line.split()) >= 3})
    assert exported == ["_madeira_ir_convert"], f"unexpected exports in libmadeira_ir_unix.dylib: {exported}"
    print("PASS: built libmadeira_ir_unix.dylib exports only _madeira_ir_convert")

print("PASS: all native .wcp override invariants verified")
