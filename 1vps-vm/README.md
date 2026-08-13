# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3 only)

| Images | Access | How |
|--------|--------|-----|
| Linux + Linux desktops | public-read | `curl` → S3 |
| Windows / Redstar | private ACL | `rclone` |

`SHA256SUMS` (public) verified after download / cache hit.

```bash
./scripts/prewarm-cache.sh
./scripts/publish-checksums.sh
PUSH=1 ./docker/build-all-tags.sh   # needs ghcr auth
```

## Console / DISPLAY_MODE

| Mode | Behavior |
|------|----------|
| `ssh` / `rdp` / `both` | Guest ports + serial log |
| `vnc` | `:5900` (password = OS_PASSWORD when supported) |
| `novnc` | `http://IP:6080/vnc.html` |
| `spice` | `:5901` |

Panel sync (`sync-egg-runtime.sh`) auto-creates allocations 5900/6080/5901 when needed. Do **not** put those ports in guest DNAT (`ADDITIONAL_PORTS`).

## Egg variables (egg 77)

**Client-visible:** `OS_PASSWORD`, `OS_HOSTNAME`, `DISPLAY_MODE`, `UEFI`  
**Hidden / auto:** `OS_DISKSIZE` (from `servers.disk` via Panel `environment_variables` + sync), `PACKAGE_UPDATE`, `OS_PUBKEY`, `ADDITIONAL_PORTS`  
**Removed leftovers:** `LICENSE`, `BANNER`, `OVERWRITE_*` (cleaned from egg)

Panel config (`config/jexactyl.php`):

```php
'environment_variables' => [
    'P_SERVER_ALLOCATION_LIMIT' => 'allocation_limit',
    'OS_DISKSIZE' => 'disk',
    'SERVER_DISK' => 'disk',
    'SERVER_MEMORY' => 'memory',
],
```

## Runtime guarantees (v0.7+)

- Guest RAM = `SERVER_MEMORY − headroom` (scales 256–1024 MiB) → no cgroup OOM
- Boot waits until guest SSH/RDP answers → logs `Guest READY`
- Windows seed: Cloudbase-Init + unattend.xml password/hostname

## Deploy

```bash
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
install -m 0755 host/qemu-system-x86_64 /opt/1vps/lumenvm-net/qemu-system-x86_64
install -m 0755 scripts/*.sh /opt/1vps/lumenvm-net/bin/
# On dash:
install -m 0755 scripts/sync-egg-runtime.sh /usr/local/sbin/1vps-sync-egg-runtime
# cron every minute + Panel config environment_variables (see above)
```
