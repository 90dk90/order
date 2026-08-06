# Digi PPPoE on Linux (pppd + rp-pppoe)

## Why

Among **software** PPPoE clients, Linux kernel PPPoE (`pppd` + `rp-pppoe.so`) is the most
stable / widely deployed path. It is **not** Digi-10G hardware offload, but it beats
VPP `pppoeclient` for Digi multi-gig in practice because:

- RX softirq can use **RPS** across host CPUs
- No VPP worker-0 coupling with VXLAN/BGP on the same core
- Years of ISP FTTH production use

NIC RSS on `0x8864` still collapses to one hardware queue — RPS is the mitigation.

## Dataplane (Digi host)

```
Digi ONT → x520wan (DPDK) → VPP BD20 → tap20 (vpp-pppoe)
                                         ↓
                                   pppd + rp-pppoe
                                         ↓
                                       ppp0
                                         ↓
                          VPP (VXLAN / PD) via existing softpath
```

`x520wan` stays in VPP — **no** DPDK unbind, **never** af_packet on `enp36s0`.

## Cutover (one Digi flap)

```bash
# On Digi, after installing units + peers:
install -m 0644 pppoe-vpp.service /etc/systemd/system/
install -m 0600 /etc/ppp/peers/digi   # from pppoe-peers-digi.example + real user
# chap-secrets must contain Digi password

systemctl daemon-reload
install -m 0755 pd-digi-linux-pppoe.sh /usr/local/sbin/
install -m 0755 pd-pppoe-enable-linux-once.sh /usr/local/sbin/

PD_ALLOW_PPPOE_RESTART=1 /usr/local/sbin/pd-pppoe-enable-linux-once.sh
```

Then re-arm VXLAN after Digi IPv6 is visible on `ppp0`:

```bash
/usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh
DIGI_VTEP=<ppp0-global-v6> /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh
```

## Rollback to VPP native

```bash
PD_ALLOW_PPPOE_RESTART=1 /usr/local/sbin/pd-pppoe-enable-once.sh
```

## Verify

```bash
systemctl status pppoe-vpp --no-pager
ip -br addr show ppp0
cat /sys/class/net/vpp-pppoe/queues/rx-0/rps_cpus   # expect non-zero mask
journalctl -u pppoe-vpp -n 50 --no-pager
```

## Perf expectation

- Better than VPP native soft-handoff for Digi WAN RX softpath
- Digi **10G line-rate not guaranteed** (RSS PPPoE still HW-limited)
- For true 10G prefer PPPoE off Digi (PPE / dedicated box) and keep Digi IP-only
