# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3 only)

Bucket: `1vps-vm-images` @ `https://fsn1.your-objectstorage.com`

Runtime downloads **only** from S3:

| Images | Access | How |
|--------|--------|-----|
| Linux + Linux desktops | public-read | `curl`/`wget` → `VM_IMAGE_BASE/<os>.qcow2` |
| Windows / Redstar | private ACL | `rclone` + `/opt/1vps/lumenvm-net/rclone/rclone.conf` |

Override public base with `VM_IMAGE_BASE`. Private remote: `S3_REMOTE` (default `hetzner:1vps-vm-images`).

Host cache (`/opt/1vps/lumenvm-net/vm-images`) stores objects **after** an S3 download. No Lumen API at boot.

Admin-only seed scripts (offline / first upload to the bucket):

```bash
LICENSE='…' ./scripts/sync-lumen-desktops-to-s3.sh
LICENSE='…' ./scripts/fetch-windows-from-lumen.sh windows-2022-desktop
./scripts/sync-images-to-s3.sh   # Linux mirrors → S3
./scripts/fetch-images.sh debian-12 ubuntu-24  # warm host cache from S3
```

## Egg variables (panel egg 77)

| Variable | Notes |
|----------|--------|
| `OS_PASSWORD` / `OS_HOSTNAME` / `OS_PUBKEY` | Linux cloud-init; Windows Cloudbase-Init (password/hostname) |
| `OS_DISKSIZE` | **Auto** from `{{server.build.disk}}` (MiB → GiB). Hidden from users |
| `PACKAGE_UPDATE` | cloud-init `package_update` / `package_upgrade` on first boot |
| `DISPLAY_MODE` | `ssh` / `rdp` / `both` → hostfwd ports; vnc/novnc/spice reserved |
| `ADDITIONAL_PORTS` | Extra TCP/UDP forwards |
| `UEFI` | OVMF when present on image |
| `LICENSE` | Unused at runtime (S3 only) |

## Host stack reused

- QEMU wrapper → TAP + virtio-net + DHCP `10.0.2.15`
- `lumen-autoballoon` (QMP)
- `lumen-dedicated-ip-forward`

## Layout

- `agent/1vps-vm` — container entrypoint (v0.5.0+)
- `scripts/fetch-images.sh` — pull from S3 → host cache
- `scripts/sync-images-to-s3.sh` — mirrors → S3
- `docker/Dockerfile` — thin image (`ENTRYPOINT` → host-mounted agent)

## Deploy

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
# rclone + config for private Windows objects (shared mount)
install -m 0755 /usr/bin/rclone /opt/1vps/lumenvm-net/bin/rclone
# rclone.conf under /opt/1vps/lumenvm-net/rclone/ (from .s3.env)
./docker/build-all-tags.sh
```

Panel egg **VM Linux/Windows** (`id=77`) docker images:
`ghcr.io/david1117dev/lumenvm:1vps-<os>`

Host S3 cache bind: `/mnt/gamedata/pterodactyl/1vps-vm-s3-cache`
→ `/opt/1vps/lumenvm-net/vm-images`.
