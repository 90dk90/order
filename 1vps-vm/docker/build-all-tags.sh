#!/usr/bin/env bash
# Build local 1vps-* tags (ENTRYPOINT → host-mounted agent).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE="${BASE:-ghcr.io/david1117dev/lumenvm:ubuntu-24}"
PREFIX="${PREFIX:-ghcr.io/david1117dev/lumenvm:1vps-}"

OS_LIST=(
  debian-10 debian-11 debian-12 debian-13
  ubuntu-18 ubuntu-20 ubuntu-22 ubuntu-24
  fedora-40 rockylinux almalinux alpine archlinux
  kali-desktop debian-12-desktop ubuntu-24-desktop
  windows-7-desktop windows-10-desktop windows-2022-desktop redstar-desktop
)

for os in "${OS_LIST[@]}"; do
  echo "BUILD ${PREFIX}${os} (VM_OS=${os})"
  docker build --build-arg "BASE=${BASE}" --build-arg "VM_OS=${os}" \
    -t "${PREFIX}${os}" -f "${ROOT}/Dockerfile" "${ROOT}"
done
echo DONE
docker images --format '{{.Repository}}:{{.Tag}}' | grep ':1vps-' | sort
