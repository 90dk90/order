#!/bin/bash
# Build Digi Option B pppoeclient_plugin.so (soft-handoff) against local vpp-dev.
# Compile only — does NOT install the .so or restart VPP / flap PPPoE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${PD_PPPOECLIENT_BUILD_DIR:-/tmp/pd-pppoeclient-handoff-build}"
OUT="${PD_PPPOECLIENT_OUT:-/tmp/pd-pppoeclient-handoff/pppoeclient_plugin.so}"

if ! command -v cmake >/dev/null; then
  echo "pd-pppoeclient-handoff-build: cmake required" >&2
  exit 1
fi
if [[ ! -f /usr/lib/x86_64-linux-gnu/cmake/vpp/VPPConfig.cmake ]]; then
  echo "pd-pppoeclient-handoff-build: vpp-dev (VPPConfig.cmake) not found" >&2
  exit 1
fi

cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"

SO="$(find "$BUILD" -name 'pppoeclient_plugin.so' -type f 2>/dev/null | head -1)"
# Older VPP cmake may emit under /vpp_plugins when output dir unset — never
# treat Digi's live plugin path as the build product.
if [[ -z "$SO" && -f /vpp_plugins/pppoeclient_plugin.so ]]; then
  SO=/vpp_plugins/pppoeclient_plugin.so
fi
if [[ -z "$SO" ]]; then
  echo "pd-pppoeclient-handoff-build: plugin .so not produced" >&2
  exit 1
fi
if [[ "$SO" == /usr/lib/* ]]; then
  echo "pd-pppoeclient-handoff-build: refusing live plugin path $SO" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
cp -f "$SO" "$OUT"
# Clean accidental root-level emit
if [[ "$SO" == /vpp_plugins/pppoeclient_plugin.so ]]; then
  rm -f /vpp_plugins/pppoeclient_plugin.so
  rmdir /vpp_plugins 2>/dev/null || true
fi
ls -l "$OUT"
md5sum "$OUT"
echo "pd-pppoeclient-handoff-build: OK (compile only — not installed)"
echo "  Deploy requires explicit approval (VPP restart + PPPoE re-arm)."
