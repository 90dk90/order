#!/usr/bin/env bash
# Prefetch popular OS images from Hetzner S3 into the host cache.
# Public objects: curl. Private (Windows/Redstar): rclone.
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
VM_IMAGE_BASE="${VM_IMAGE_BASE:-https://fsn1.your-objectstorage.com/1vps-vm-images}"
S3_REMOTE="${S3_REMOTE:-hetzner:1vps-vm-images}"
RCLONE_BIN="${RCLONE_BIN:-/opt/1vps/lumenvm-net/bin/rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/1vps/lumenvm-net/rclone/rclone.conf}"
LOG="${LOG:-/var/log/1vps-prewarm.log}"

PUBLIC_DEFAULT=(
  debian-12 debian-13 ubuntu-22 ubuntu-24 alpine
  debian-12-desktop ubuntu-24-desktop
)
PRIVATE_DEFAULT=(
  windows-2022-desktop windows-10-desktop
)

mkdir -p "$CACHE_DIR"
exec >>"$LOG" 2>&1
echo "[$(date -Is)] prewarm start"

is_private() {
  case "$1" in windows-*|redstar-desktop) return 0 ;; *) return 1 ;; esac
}

valid_qcow() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 1048576 ]] || return 1
  qemu-img info "$f" >/dev/null 2>&1
}

fetch_one() {
  local os="$1" dest tmp url
  dest="${CACHE_DIR}/${os}.qcow2"
  if valid_qcow "$dest"; then
    echo "cached: $os ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi
  tmp="${dest}.partial"
  rm -f "$tmp"
  if is_private "$os"; then
    echo "fetch private $os"
    [[ -x "$RCLONE_BIN" && -f "$RCLONE_CONFIG" ]] || {
      echo "skip $os: rclone not configured"; return 1
    }
    "$RCLONE_BIN" --config "$RCLONE_CONFIG" copyto \
      "${S3_REMOTE%/}/${os}.qcow2" "$tmp" \
      --retries 5 --stats 60s --stats-one-line
  else
    url="${VM_IMAGE_BASE%/}/${os}.qcow2"
    echo "fetch public $os <- $url"
    curl -4 -fL --retry 5 --retry-delay 2 --connect-timeout 30 -o "$tmp" "$url"
  fi
  qemu-img info "$tmp" >/dev/null
  # optional checksum
  if [[ -f "${CACHE_DIR}/SHA256SUMS" ]]; then
    (cd "$(dirname "$tmp")" && sha256sum -c --ignore-missing "${CACHE_DIR}/SHA256SUMS" 2>/dev/null) || true
  fi
  mv -f "$tmp" "$dest"
  echo "ok: $os ($(du -h "$dest" | awk '{print $1}'))"
}

if [[ "$#" -gt 0 ]]; then
  for os in "$@"; do fetch_one "$os" || true; done
else
  for os in "${PUBLIC_DEFAULT[@]}"; do fetch_one "$os" || true; done
  for os in "${PRIVATE_DEFAULT[@]}"; do fetch_one "$os" || true; done
fi

# Refresh checksums file from S3 when public
curl -4 -fsSL --connect-timeout 15 \
  -o "${CACHE_DIR}/SHA256SUMS.tmp" \
  "${VM_IMAGE_BASE%/}/SHA256SUMS" 2>/dev/null \
  && mv -f "${CACHE_DIR}/SHA256SUMS.tmp" "${CACHE_DIR}/SHA256SUMS" \
  || rm -f "${CACHE_DIR}/SHA256SUMS.tmp"

echo "[$(date -Is)] prewarm done"
ls -lh "$CACHE_DIR"/*.qcow2 2>/dev/null | awk '{print $5,$9}'
