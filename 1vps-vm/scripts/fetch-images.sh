#!/usr/bin/env bash
# Prefetch OS cloud images into the host cache used by 1vps-vm.
set -euo pipefail
CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
mkdir -p "$CACHE_DIR"

declare -A URLS=(
  [debian-12]="https://gemmei.ftp.acc.umu.se/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  [debian-13]="https://gemmei.ftp.acc.umu.se/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  [ubuntu-22]="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
  [ubuntu-24]="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
)

OS_LIST="${*:-debian-12 ubuntu-24}"

for os in $OS_LIST; do
  url="${URLS[$os]:-}"
  if [[ -z "$url" ]]; then
    echo "skip unknown os: $os" >&2
    continue
  fi
  dest="${CACHE_DIR}/${os}.qcow2"
  if [[ -f "$dest" && $(stat -c%s "$dest") -gt 1048576 ]]; then
    echo "cached: $dest ($(du -h "$dest" | awk '{print $1}'))"
    continue
  fi
  echo "fetch $os <- $url"
  tmp="${dest}.partial"
  curl -4 -fL --retry 5 --retry-delay 2 -o "$tmp" "$url"
  qemu-img info "$tmp" >/dev/null
  mv -f "$tmp" "$dest"
  echo "ok: $dest ($(du -h "$dest" | awk '{print $1}'))"
done
