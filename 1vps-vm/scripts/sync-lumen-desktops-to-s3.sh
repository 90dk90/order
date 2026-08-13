#!/usr/bin/env bash
# Sync Lumen desktop / Windows / Redstar images → Hetzner S3.
# Linux desktops: public-read. Windows/Redstar: private (license-bound).
# Requires: LICENSE env, rclone remote `hetzner`.
set -uo pipefail
export PATH="/usr/local/bin:/root/.local/bin:$PATH"
CACHE="${CACHE:-/mnt/gamedata/pterodactyl/1vps-vm-templates}"
HOSTCACHE="${HOSTCACHE:-/opt/1vps/lumenvm-net/vm-images}"
LOG="${LOG:-/var/log/1vps-lumen-images-s3.log}"
LICENSE="${LICENSE:-}"
mkdir -p "$CACHE"
exec >>"$LOG" 2>&1

PUBLIC_OS=(kali-desktop debian-12-desktop ubuntu-24-desktop)
PRIVATE_OS=(windows-7-desktop windows-10-desktop windows-2022-desktop redstar-desktop)

if [[ -z "$LICENSE" || "$LICENSE" == "PASTE-YOUR-LICENSE-HERE" ]]; then
  echo "[$(date -Is)] LICENSE required" >&2
  exit 1
fi

download_one() {
  local os="$1"
  local dest="$CACHE/${os}.qcow2"
  local gz="$CACHE/${os}.qcow2.gz"
  if [[ -f "$dest" ]] && qemu-img info "$dest" >/dev/null 2>&1; then
    echo "[$(date -Is)] CACHE_OK $os ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi
  if [[ -f "$HOSTCACHE/${os}.qcow2" ]] && qemu-img info "$HOSTCACHE/${os}.qcow2" >/dev/null 2>&1; then
    cp -f "$HOSTCACHE/${os}.qcow2" "$dest"
    echo "[$(date -Is)] COPIED_HOST $os"
    return 0
  fi
  local attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    echo "[$(date -Is)] DL_TRY $os attempt=$attempt"
    rm -f "$gz" "${dest}.partial"
    if wget --user-agent=lumenvm-api-agent --tries=3 --timeout=60 --waitretry=5 \
        --header="License: ${LICENSE}" --header="Product: 1" --header="File: ${os}" \
        -O "$gz" "https://api.lumenvm.cloud/content"; then
      local sz; sz=$(stat -c%s "$gz" 2>/dev/null || echo 0)
      [[ "$sz" -gt 1000000 ]] || { sleep $((attempt*3)); continue; }
      if gzip -dc "$gz" > "${dest}.partial" 2>/dev/null && qemu-img info "${dest}.partial" >/dev/null 2>&1; then
        mv -f "${dest}.partial" "$dest"; rm -f "$gz"
        echo "[$(date -Is)] OK_DL $os ($(du -h "$dest" | awk '{print $1}'))"
        return 0
      fi
      if qemu-img info "$gz" >/dev/null 2>&1; then
        mv -f "$gz" "$dest"
        echo "[$(date -Is)] OK_RAW $os"
        return 0
      fi
    fi
    sleep $((attempt*4))
  done
  echo "[$(date -Is)] FAIL_DL $os"
  return 1
}

upload_one() {
  local os="$1" acl="$2"
  local src="$CACHE/${os}.qcow2"
  [[ -f "$src" ]] || src="$HOSTCACHE/${os}.qcow2"
  [[ -f "$src" ]] || { echo "[$(date -Is)] MISSING $os"; return 1; }
  local local_sz remote
  local_sz=$(stat -c%s "$src")
  remote=$(rclone ls "hetzner:1vps-vm-images/${os}.qcow2" 2>/dev/null | awk '{print $1}')
  if [[ -n "${remote:-}" && "$remote" == "$local_sz" ]]; then
    echo "[$(date -Is)] SKIP_UP $os"; return 0
  fi
  echo "[$(date -Is)] UP $os acl=$acl ($(du -h "$src" | awk '{print $1}'))"
  rclone copyto "$src" "hetzner:1vps-vm-images/${os}.qcow2" \
    --s3-acl "$acl" --s3-chunk-size 64M --s3-upload-concurrency 16 \
    --transfers 1 --checkers 8 --retries 8 --stats 20s --stats-one-line \
    && echo "[$(date -Is)] OK_UP $os" || echo "[$(date -Is)] FAIL_UP $os"
}

echo "[$(date -Is)] lumen image sync start"
for os in "${PUBLIC_OS[@]}" "${PRIVATE_OS[@]}"; do
  download_one "$os" || true
done
for os in "${PUBLIC_OS[@]}"; do upload_one "$os" public-read || true; done
for os in "${PRIVATE_OS[@]}"; do upload_one "$os" private || true; done
echo "[$(date -Is)] lumen image sync done"
rclone lsl hetzner:1vps-vm-images
