# Digi PPPoE on Linux (pppd + rp-pppoe)

## Why

Among **software** PPPoE clients, Linux kernel PPPoE (`pppd` + `rp-pppoe.so`) is the most
stable / widely deployed path. It is **not** Digi-10G hardware offload, but it beats
VPP `pppoeclient` for Digi multi-gig in practice because:

- RX softirq can use **RPS** across host CPUs
- No VPP worker coupling with Digi WAN RX
- Years of ISP FTTH production use

NIC RSS on `0x8864` still collapses toward one hardware queue — RPS is the mitigation.

## Preferred dataplane on this host (`VPP_PPPOE_MODE=kernel`)

```
Digi ONT → digi-wan (kernel ixgbe) → pppd/rp-pppoe → ppp0
                                              ↓
                                     Linux VXLAN (vxlan-digi)
                                              ↑
                       VPP LAN/PBR ── tap30/vpp6-host ──┘
```

Digi WAN PCI `0000:2b:00.0` leaves DPDK. VPP keeps `x520lan` (+ extras).
**Never** af_packet on `enp36s0`. PPPoE unit is **not** `BindsTo=vpp` (survives VPP restarts).

### Cutover (one Digi flap + one VPP restart)

```bash
install -m 0755 pd-pppoe-enable-kernel-once.sh /usr/local/sbin/
install -m 0755 pd-linux-vxlan-digi-activate.sh /usr/local/sbin/
install -m 0755 pd-digi-linux-wan6.sh /usr/local/sbin/
# also refresh vpp-bootstrap.sh (MODE=kernel)

PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1 \
  /usr/local/sbin/pd-pppoe-enable-kernel-once.sh
```

## Alternate: softpath Linux PPPoE (no DPDK unbind)

```
Digi ONT → x520wan (DPDK) → VPP BD20 → tap20 → pppd → ppp0 → Linux VXLAN
```

```bash
PD_ALLOW_PPPOE_RESTART=1 /usr/local/sbin/pd-pppoe-enable-linux-once.sh
/usr/local/sbin/pd-digi-linux-wan6.sh
/usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh
```

More softpath loss under load (`vpp-pppoe` TX drops / `x520wan` rx-miss).

## Rollback to VPP native (ONE VPP restart)

Requires a prior Digi backup under `/root/pd-backup-kernel-mode-*.tgz` (see `packets-decreaser/backups/README.md`).

```bash
install -m 0755 pd-pppoe-enable-native-once.sh /usr/local/sbin/
PD_ALLOW_PPPOE_RESTART=1 PD_ALLOW_VPP_RESTART=1   /usr/local/sbin/pd-pppoe-enable-native-once.sh
```

This re-binds Digi WAN into DPDK, starts `vpp-pppoe-native`, runs VPP VXLAN cutover, and syncs the VPS VTEP. Soft-handoff must already be loaded.

Legacy (PPPoE only, no DPDK re-bind):

```bash
PD_ALLOW_PPPOE_RESTART=1 /usr/local/sbin/pd-pppoe-enable-once.sh
```

## Verify

```bash
systemctl status pppoe-vpp --no-pager
ip -br addr show ppp0 digi-wan
dpdk-devbind.py -s | head -20   # 2b:00.0 on ixgbe when MODE=kernel
ping -c2 172.16.208.1
```

## Perf expectation

- Kernel WAN removes BD20/tap hairpin (main prior drop source)
- Digi **10G line-rate still not guaranteed** (PPPoE ethertype RSS limits)
- For true 10G: terminate PPPoE on a second box; Digi stays IP-only
- PVE-via-PD softpath ceiling is typically well below Digi-native `ppp0`
  (VPP → `tap30` → Linux VXLAN → `ppp0`) and below VPS native (~5G). Softpath
  knobs that do **not** flap PPPoE:
  - Digi: `/usr/local/sbin/vpp-performance-tuning.sh` (`vxlan-digi` RPS,
    `digi-wan` rings 4096, `pfifo_fast`)
  - VPS: `/usr/local/sbin/pd-vps-nic-tune.sh` (`eth0` mq+`pfifo_fast`, backlog,
    RPS) + `pd-vps-nic-tune.service`
