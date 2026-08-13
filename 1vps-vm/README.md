# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3)

Bucket: `1vps-vm-images` @ `https://fsn1.your-objectstorage.com`

**Linux** objects are **public-read**:
`https://fsn1.your-objectstorage.com/1vps-vm-images/<os>.qcow2`

Override base URL with env `VM_IMAGE_BASE`.

**Windows / Redstar / Linux desktops** come from Lumen (`LICENSE` + `/content`). Linux desktops are public-read on S3; Windows/Redstar are **private**.

```bash
LICENSE='…' ./scripts/sync-lumen-desktops-to-s3.sh
# or single Windows:
LICENSE='…' ./scripts/fetch-windows-from-lumen.sh windows-2022-desktop
```

Ballooning for Windows: host QEMU wrapper injects `virtio-balloon` + attaches `virtio/balloon-setup.iso` when the disk path contains `windows` (or use IDE disk name with `windows`).

Sync (prefer **dash** — better egress than Wings; needs `rclone` remote `hetzner` + optional `aria2`):

```bash
# Fast path: parallel aria2 downloads + rclone multipart uploads (Linux only)
./scripts/sync-images-to-s3.sh
# Live copy on dash:
/usr/local/sbin/sync-images-fast.sh
```

Public objects: ~12 OS images (Debian 10–13, Ubuntu 18–24, Rocky, Alma, Alpine, Arch, Fedora 40).
Windows stays on host cache / private objects.

Warm local cache from S3:

```bash
./scripts/fetch-images.sh debian-12 ubuntu-24
```

## Host stack reused

- QEMU wrapper → TAP + virtio-net + DHCP `10.0.2.15`
- `lumen-autoballoon` (QMP)
- `lumen-dedicated-ip-forward`

## Layout

- `agent/1vps-vm` — container entrypoint
- `scripts/fetch-images.sh` — pull from S3 → host cache
- `scripts/sync-images-to-s3.sh` — mirrors → S3
- `docker/Dockerfile` — thin image (`ENTRYPOINT` → host-mounted agent)

## Deploy

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
install -m 0755 scripts/*.sh /opt/1vps/lumenvm-net/bin/
# Build every panel OS tag (ENTRYPOINT → 1vps-vm)
./docker/build-all-tags.sh
```

Panel egg **VM Linux/Windows** (`id=77`) must point docker images at
`ghcr.io/david1117dev/lumenvm:1vps-<os>` (not the stock Lumen tags).

Host image cache: bind-mount `/mnt/gamedata/pterodactyl/1vps-vm-templates`
→ `/opt/1vps/lumenvm-net/vm-images` so containers see warm qcow2 without
calling `api.lumenvm.cloud`.
