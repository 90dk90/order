#!/usr/bin/env bash
# Fetch LumenVM pre-activated Windows image into the host cache (PRIVATE).
# Requires env LICENSE (same egg variable as LumenVM).
# Does NOT publish to public S3 — Windows redistrib is license-bound.
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
OS="${1:-windows-2022-desktop}"
LICENSE="${LICENSE:-}"
UA="lumenvm-api-agent"

if [[ -z "$LICENSE" || "$LICENSE" == "PASTE-YOUR-LICENSE-HERE" ]]; then
  echo "LICENSE env required" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"
dest="${OS}.qcow2"
gz="${OS}.qcow2.gz"

if [[ -f "$dest" ]] && qemu-img info "$dest" >/dev/null 2>&1; then
  echo "Already cached: $CACHE_DIR/$dest ($(du -h "$dest" | awk '{print $1}'))"
  exit 0
fi

echo "Downloading ${OS} via Lumen API…"
rm -f "$gz" "${dest}.partial"
wget --user-agent="$UA" \
  --header="License: ${LICENSE}" \
  --header="Product: 1" \
  --header="File: ${OS}" \
  -O "$gz" \
  "https://api.lumenvm.cloud/content"

echo "Decompressing…"
gzip -dc "$gz" > "${dest}.partial"
rm -f "$gz"
qemu-img info "${dest}.partial" >/dev/null
mv -f "${dest}.partial" "$dest"
chmod 644 "$dest"
echo "OK $CACHE_DIR/$dest ($(du -h "$dest" | awk '{print $1}'))"
qemu-img info "$dest"
