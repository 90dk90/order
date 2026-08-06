# Digi / VPS / PVE configuration backups (pre native cutover)

Backups stay **on the hosts** (contain PPP secrets — do not commit tarballs).

## Digi (`100.88.2.25` / Tailscale)

| Artifact | Path |
|----------|------|
| Full tarball | `/root/pd-backup-kernel-mode-20260806T142338Z.tgz` |
| Unpacked tree | `/root/pd-backup-kernel-mode-20260806T142338Z/` |

Includes: `/etc/vpp`, `/etc/ppp`, systemd units, `usr-local-sbin` PD/VPP scripts, PCI bind state, light `vppctl` dumps, mode files.

## VPS (`77.90.4.48`)

| Artifact | Path |
|----------|------|
| Tarball | `/root/pd-backup-vps-20260806T143416Z.tgz` |

## PVE (`1vps`)

| Artifact | Path |
|----------|------|
| Tarball | `/root/pd-backup-pve.tgz` |

## Cutover / rollback

- Native (one VPP restart): `PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 /usr/local/sbin/pd-pppoe-enable-native-once.sh`
- Back to kernel: `PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 /usr/local/sbin/pd-pppoe-enable-kernel-once.sh`
