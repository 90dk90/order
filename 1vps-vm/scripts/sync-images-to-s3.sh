#!/usr/bin/env bash
# Download official cloud images then upload to Hetzner S3 (public-read).
# Requires: /root/.1vps-s3.env (AWS_* from panel) and aws CLI.
set -euo pipefail
export PATH="/usr/local/bin:$PATH"
ENV_FILE="${S3_ENV_FILE:-/root/.1vps-s3.env}"
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

ENDPOINT="${AWS_ENDPOINT:?}"
BUCKET="${VM_IMAGES_BUCKET:-1vps-vm-images}"
CACHE="${CACHE_DIR:-/opt/1vps/lumenvm-net/vm-images}"
mkdir -p "$CACHE"

declare -A URLS=(
  [debian-10]="https://cloud.debian.org/images/cloud/buster/latest/debian-10-genericcloud-amd64.qcow2"
  [debian-11]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  [debian-12]="https://gemmei.ftp.acc.umu.se/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  [debian-13]="https://gemmei.ftp.acc.umu.se/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
  [ubuntu-18]="https://cloud-images.ubuntu.com/releases/18.04/release/ubuntu-18.04-server-cloudimg-amd64.img"
  [ubuntu-20]="https://cloud-images.ubuntu.com/releases/20.04/release/ubuntu-20.04-server-cloudimg-amd64.img"
  [ubuntu-22]="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
  [ubuntu-24]="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  [fedora-40]="https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2"
  [rockylinux]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
  [almalinux]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  [alpine]="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/cloud/nocloud_alpine-3.20.3-x86_64-bios-cloudinit-r0.qcow2"
  [archlinux]="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
)

echo "[$(date -Is)] sync start → s3://${BUCKET}"

for os in debian-10 debian-11 debian-12 debian-13 ubuntu-18 ubuntu-20 ubuntu-22 ubuntu-24 fedora-40 rockylinux almalinux alpine archlinux; do
  dest="${CACHE}/${os}.qcow2"
  url="${URLS[$os]}"
  echo "==== $os ===="
  if [[ -f "$dest" && $(stat -c%s "$dest") -gt 1048576 ]] && qemu-img info "$dest" >/dev/null 2>&1; then
    echo "local cache hit ($(du -h "$dest" | awk '{print $1}'))"
  else
    echo "download $url"
    tmp="${dest}.partial"
    rm -f "$tmp"
    curl -4 -fL --retry 5 --retry-delay 3 --connect-timeout 45 -o "$tmp" "$url"
    qemu-img info "$tmp" >/dev/null
    mv -f "$tmp" "$dest"
  fi
  echo "upload s3://${BUCKET}/${os}.qcow2"
  aws --endpoint-url "$ENDPOINT" s3 cp "$dest" "s3://${BUCKET}/${os}.qcow2" --acl public-read
  code=$(curl -4 -sI -o /dev/null -w '%{http_code}' "https://fsn1.your-objectstorage.com/${BUCKET}/${os}.qcow2" || true)
  echo "public_http=$code"
done

echo "[$(date -Is)] sync done"
aws --endpoint-url "$ENDPOINT" s3 ls "s3://${BUCKET}/"
