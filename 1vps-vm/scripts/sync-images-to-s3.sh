#!/usr/bin/env bash
# Fast mirror → Hetzner Object Storage (FSN).
# Prefer: dash host (good egress) + aria2 multi-conn DL + rclone multipart UP.
set -uo pipefail
export PATH="/root/.local/bin:/usr/local/bin:$PATH"
CACHE=/var/cache/1vps-vm-images
BUCKET=hetzner:1vps-vm-images
LOG=/var/log/1vps-vm-s3-fast.log
DL_PARALLEL="${DL_PARALLEL:-8}"
UP_PARALLEL="${UP_PARALLEL:-4}"
ARIA_CONN="${ARIA_CONN:-16}"
mkdir -p "$CACHE"
exec >>"$LOG" 2>&1

declare -A URLS=(
  [debian-10]="https://cloud.debian.org/images/cloud/buster/latest/debian-10-genericcloud-amd64.qcow2"
  [debian-11]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  [debian-12]="https://gemmei.ftp.acc.umu.se/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  [debian-13]="https://gemmei.ftp.acc.umu.se/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  [ubuntu-18]="https://cloud-images.ubuntu.com/releases/18.04/release/ubuntu-18.04-server-cloudimg-amd64.img"
  [ubuntu-20]="https://cloud-images.ubuntu.com/releases/20.04/release/ubuntu-20.04-server-cloudimg-amd64.img"
  [ubuntu-22]="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
  [ubuntu-24]="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  # Fedora 40 left the live mirror tree; use archives.
  [fedora-40]="https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2"
  [rockylinux]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
  [almalinux]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  [alpine]="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.3-x86_64-bios-cloudinit-r0.qcow2"
  [archlinux]="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
)

OS_ORDER=(debian-10 debian-11 debian-12 debian-13 ubuntu-18 ubuntu-20 ubuntu-22 ubuntu-24 fedora-40 rockylinux almalinux alpine archlinux)

echo "[$(date -Is)] FAST sync start (dl=$DL_PARALLEL up=$UP_PARALLEL aria=$ARIA_CONN)"
rclone lsf "$BUCKET" > /tmp/s3-existing.txt 2>/dev/null || true
cat /tmp/s3-existing.txt

download_one() {
  local os="$1" url="$2" dest="$CACHE/${os}.qcow2"
  if [[ -f "$dest" && $(stat -c%s "$dest") -gt 1048576 ]]; then
    echo "CACHE $os ($(du -h "$dest" | awk '{print $1}'))"; return 0
  fi
  echo "DL $os"
  rm -f "${dest}.partial" "${dest}.aria2"
  if command -v aria2c >/dev/null 2>&1; then
    if aria2c -x "$ARIA_CONN" -s "$ARIA_CONN" -k 4M \
      --file-allocation=none --allow-overwrite=true --auto-file-renaming=false \
      --max-tries=8 --retry-wait=2 --timeout=60 --connect-timeout=20 \
      -o "${os}.qcow2.partial" -d "$CACHE" "$url"
    then
      mv -f "${dest}.partial" "$dest"
      echo "OK_DL $os ($(du -h "$dest" | awk '{print $1}'))"
      return 0
    fi
  fi
  if curl -4 -fL --retry 4 --retry-delay 2 --connect-timeout 20 -o "${dest}.partial" "$url"; then
    mv -f "${dest}.partial" "$dest"
    echo "OK_DL $os ($(du -h "$dest" | awk '{print $1}'))"
  else
    rm -f "${dest}.partial"
    echo "FAIL_DL $os"
  fi
}

upload_one() {
  local os="$1" dest="$CACHE/${os}.qcow2"
  [[ -f "$dest" ]] || { echo "SKIP_UP $os"; return 0; }
  local local_sz remote
  local_sz=$(stat -c%s "$dest")
  remote=$(rclone ls "$BUCKET/${os}.qcow2" 2>/dev/null | awk '{print $1}')
  if [[ -n "${remote:-}" && "$remote" == "$local_sz" ]]; then
    echo "SKIP_UP $os (same)"; return 0
  fi
  echo "UP $os ($(du -h "$dest" | awk '{print $1}'))"
  rclone copyto "$dest" "$BUCKET/${os}.qcow2" \
    --s3-acl public-read \
    --s3-chunk-size 64M \
    --s3-upload-concurrency 32 \
    --transfers 1 \
    --checkers 16 \
    --retries 8 \
    --low-level-retries 20 \
    --stats 20s --stats-one-line \
    && echo "OK_UP $os" || echo "FAIL_UP $os"
}

for os in "${!URLS[@]}"; do
  download_one "$os" "${URLS[$os]}" &
  while (( $(jobs -rp | wc -l) >= DL_PARALLEL )); do sleep 0.3; done
done
wait
echo "[$(date -Is)] DL phase done"

for os in "${OS_ORDER[@]}"; do
  upload_one "$os" &
  while (( $(jobs -rp | wc -l) >= UP_PARALLEL )); do sleep 0.3; done
done
wait
echo "[$(date -Is)] FAST sync done"
rclone lsl "$BUCKET"
