#!/usr/bin/env bash
# Hash all qcow2 in CACHE_DIR (incl. Windows) and upload public SHA256SUMS.
set -euo pipefail

CACHE_DIR="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
S3_REMOTE="${S3_REMOTE:-hetzner:1vps-vm-images}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"

rc() {
  if [[ -n "${RCLONE_CONFIG}" ]]; then
    "$RCLONE_BIN" --config "$RCLONE_CONFIG" "$@"
  else
    "$RCLONE_BIN" "$@"
  fi
}

mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"
shopt -s nullglob
files=(*.qcow2)
[[ "${#files[@]}" -gt 0 ]] || { echo "No qcow2 in ${CACHE_DIR}"; exit 1; }

: >SHA256SUMS
for f in "${files[@]}"; do
  echo "hash $f"
  sha256sum "$f" >>SHA256SUMS
done
echo "---"
cat SHA256SUMS

# Public ACL for the sums file (qcow ACL unchanged)
rc copyto SHA256SUMS "${S3_REMOTE%/}/SHA256SUMS" \
  --s3-acl public-read \
  --header-upload "Cache-Control: no-cache"
echo "uploaded ${S3_REMOTE%/}/SHA256SUMS"
