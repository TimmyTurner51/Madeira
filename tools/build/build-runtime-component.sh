#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT
case "${1:-}" in
  dock) deps=() ;;
  windows) deps=(cmake ninja meson pkg-config bison flex) ;;
  moltenvk) deps=(cmake ninja) ;;
  zink) deps=(bison flex pkg-config) ;;
  kosmickrisp) deps=(cmake ninja pkg-config llvm@21 spirv-tools) ;;
  mesa-d3d12) deps=(ninja bison) ;;
  vulkan-pe) deps=(meson ninja glslang) ;;
  *) echo "Unknown runtime component: ${1:-}" >&2; exit 2 ;;
esac
[ ${#deps[@]} -eq 0 ] || brew install "${deps[@]}"
if brew --prefix bison >/dev/null 2>&1; then
    export PATH="$(brew --prefix bison)/bin:$PATH"
fi
case "${1:-}" in
  dock|windows|mesa-d3d12|vulkan-pe) "$ROOT/tools/build/setup-llvm-mingw.sh" ;;
esac
case "${1:-}" in
  windows)
    git -C "$ROOT" submodule update --init --recursive wine dxmt FEX
    xcodebuild -downloadComponent MetalToolchain
    "$ROOT/tools/build/build-shader-headers.sh"
    ;;
  dock) git -C "$ROOT" submodule update --init madeira-dock ;;
esac
case "${1:-}" in
  dock) bash "$ROOT/build/madeira-dock/build.sh" --check ;;
  windows) bash "$ROOT/build/windows-runtime/build.sh"
           # Forza Horizon 6 hashes export names looking for Wine-only ones
           # (wine_get_unix_file_name), and finding them makes it skip decrypt
           # setup. The rename must happen HERE, before runtime-components
           # snapshots hashes: package-ipa.sh used to apply it afterwards, so
           # every rebuilt component failed verification with a checksum
           # mismatch against bytes that had never shipped. Doing it in the
           # component build keeps the manifest describing the shipped bytes,
           # and leaves package-ipa's pass as a no-op.
           python3 "$ROOT/tools/wcp/hide-wine-exports.py" \
               "$ROOT/app/Madeira/arm64ec-windows/"*.dll \
               "$ROOT/app/Madeira/aarch64-windows/"*.dll \
               "$ROOT/app/Madeira/i386-windows/ntdll.dll" \
               "$ROOT/app/Madeira/i386-windows/kernel32.dll" \
               "$ROOT/app/Madeira/i386-windows/shell32.dll" >/dev/null ;;
  moltenvk|zink|kosmickrisp) bash "$ROOT/tools/build/prepare-graphics.sh" "$1" ;;
  mesa-d3d12) bash "$ROOT/build/mesa-d3d12/build.sh" ;;
  vulkan-pe)
    bash "$ROOT/build/dxvk/build.sh"
    bash "$ROOT/build/vkd3d-proton/build.sh"
    ;;
  *) echo "Unknown runtime component: ${1:-}" >&2; exit 2 ;;
esac
