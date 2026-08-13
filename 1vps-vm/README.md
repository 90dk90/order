# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3 only)

Bucket: `1vps-vm-images` @ `https://fsn1.your-objectstorage.com`

| Images | Access | How |
|--------|--------|-----|
| Linux + Linux desktops | public-read | `curl` → `VM_IMAGE_BASE/<os>.qcow2` |
| Windows / Redstar | private ACL | `rclone` + `/opt/1vps/lumenvm-net/rclone/rclone.conf` |

Optional `SHA256SUMS` (public) is checked after download / cache hit.

```bash
./scripts/prewarm-cache.sh                 # popular OS → host cache
./scripts/publish-checksums.sh             # hash cache → upload SHA256SUMS
LICENSE='…' ./scripts/sync-lumen-desktops-to-s3.sh   # admin seed only
```

## Console / DISPLAY_MODE

| Mode | Behavior |
|------|----------|
| `ssh` / `rdp` / `both` | Guest port forwards + **panel console = serial ttyS0** |
| `vnc` | QEMU VNC on container `:5900` (password = `OS_PASSWORD` when supported) |
| `novnc` | VNC on localhost + websockify `:6080` → `http://IP:6080/vnc.html` |
| `spice` | SPICE on `:5901` (not 3128 — host firewall) |

**Important:** allocate `5900` / `6080` / `5901` on the dedicated IP. Do **not** put them in `ADDITIONAL_PORTS` (those are DNAT’d to the guest). The QEMU wrapper skips DNAT for display ports if they appear anyway.

## Egg variables (panel egg 77)

| Variable | Notes |
|----------|--------|
| `OS_PASSWORD` / `OS_HOSTNAME` / `OS_PUBKEY` | Linux cloud-init; Windows Cloudbase-Init when present in image |
| `OS_DISKSIZE` | Auto from `{{server.build.disk}}` (MiB → GiB), hidden |
| `PACKAGE_UPDATE` | Hidden, always `0` (images stay warm; client can `apt update`) |
| `DISPLAY_MODE` | see above |
| `ADDITIONAL_PORTS` | Extra guest TCP/UDP forwards |
| `UEFI` | Hidden, default SeaBIOS (`0`). OVMF on host if an admin forces `1` |

## Layout

- `agent/1vps-vm` — container entrypoint (v0.6.0+)
- `host/qemu-system-x86_64` — TAP/DNAT wrapper (skip display ports)
- `scripts/prewarm-cache.sh` — warm S3 cache (+ Windows via rclone)
- `scripts/publish-checksums.sh` — SHA256SUMS → S3
- `docker/` — thin `1vps-*` tags

## Deploy

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
install -m 0755 host/qemu-system-x86_64 /opt/1vps/lumenvm-net/qemu-system-x86_64
install -m 0755 scripts/*.sh /opt/1vps/lumenvm-net/bin/
# rclone + rclone.conf under /opt/1vps/lumenvm-net/
./scripts/prewarm-cache.sh
```

Panel egg **VM Linux/Windows** (`id=77`):
`ghcr.io/david1117dev/lumenvm:1vps-<os>`

Host S3 cache: `/mnt/gamedata/pterodactyl/1vps-vm-s3-cache` → `/opt/1vps/lumenvm-net/vm-images`.
