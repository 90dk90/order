# 1vps-vm

Self-hosted KVM agent replacing LumenVM for Digi / 1VPS.

## Image source (Hetzner S3 only)

| Images | Access | How |
|--------|--------|-----|
| Linux + Linux desktops | public-read | `curl` / rclone multi-stream → S3 |
| Windows / Redstar | private ACL | `rclone` |

`SHA256SUMS` (public) verified after download / cache hit.

**Fast path:** rclone multi-stream (16); server disks use a **qcow2 backing file** on the host cache → near-instant provision when warm.

```bash
./scripts/prewarm-cache.sh          # multi-stream warm cache
./scripts/publish-checksums.sh
```

Create-time: Panel dispatches `PrewarmVmImageJob` (egg 77) → SSH → `prewarm-cache.sh <os>` before/during first start. Status: `/var/lib/1vps-prewarm/<uuid>.json`.

## Console / DISPLAY_MODE

| Mode | Behavior |
|------|----------|
| `ssh` / `rdp` / `both` | Guest ports + serial log |
| `vnc` | `:5900` (password = OS_PASSWORD when supported) |
| `novnc` | `http://IP:6080/vnc.html` + **panel embed** via HTTPS proxy `/1vps-novnc/...` |
| `spice` | `:5901` |

Panel console (DISPLAY_MODE=`novnc`/`vnc`): tabs **Série** / **Graphique (noVNC)**. Embed uses `1vps-novnc-proxy` on dash (avoids mixed-content).

## Hot RAM

Agent boots with `-m size=<guest>M,slots=16,maxmem=<ceiling>M` (default ceiling 128 GiB).

Panel memory edits / build changes call `HotRamSyncService` → node `/usr/local/sbin/1vps-hot-ram <uuid> <mib>`:

- decrease → virtio-balloon
- increase → pc-dimm hotplug (needs maxmem/slots from a v0.8+ boot)

## VirtIO / rescue ISO

Host QEMU wrapper attaches for Windows:

- `/opt/1vps/lumenvm-net/virtio/balloon-setup.iso`
- `/opt/1vps/lumenvm-net/virtio/virtio-win.iso`

Optional: `RESCUE_ISO` / `EXTRA_ISO` env paths.

## Egg variables (egg 77)

**Client-visible:** `OS_PASSWORD`, `OS_HOSTNAME`, `DISPLAY_MODE`, `UEFI`  
**Hidden / auto:** `OS_DISKSIZE` (from `servers.disk`), `PACKAGE_UPDATE`, `OS_PUBKEY`, `ADDITIONAL_PORTS`

Panel `config/jexactyl.php`:

```php
'environment_variables' => [
    'P_SERVER_ALLOCATION_LIMIT' => 'allocation_limit',
    'OS_DISKSIZE' => 'disk',
    'SERVER_DISK' => 'disk',
    'SERVER_MEMORY' => 'memory',
],
'vm_egg_id' => 77,
'novnc_proxy' => [ /* secret, map_dir */ ],
'hot_ram' => [ 'enabled' => true ],
'vm_prewarm' => [ 'enabled' => true ],
```

## Runtime guarantees (v0.8+)

- Guest RAM = `SERVER_MEMORY − headroom` + **maxmem** for hot-plug
- Boot waits until guest SSH/RDP answers → `Guest READY`
- Windows seed + VirtIO ISOs on host wrapper
- Create-time S3 prewarm queue

## Deploy

```bash
# Node
install -m 0755 agent/1vps-vm /opt/1vps/lumenvm-net/bin/1vps-vm
install -m 0755 host/qemu-system-x86_64 /opt/1vps/lumenvm-net/qemu-system-x86_64
install -m 0755 host/1vps-hot-ram /usr/local/sbin/1vps-hot-ram
install -m 0755 scripts/*.sh /opt/1vps/lumenvm-net/bin/

# Dash — see panel/ (NoVncController, ExternalConsole, HotRamSyncService,
# PrewarmVmImageJob, novnc-proxy.py + systemd, nginx location)
```
