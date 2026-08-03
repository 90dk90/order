# Native Digi PPPoE in VPP

## Status

**Dataplane: native (no Linux pppd hairpin)**

```
x520wan → pppoeclient → digi
  IPv4: 100.64.x.x/32 (CGNAT) — Digi SNAT only if /run/vpp-prefer-digi-snat
  IPv6: 2a01:4700:80ff:ffff::<ipv4-hex>/64  (Digi WAN, globally routed)
  GRE:  gre0 → Packets Decreaser VTEP 2a0e:97c0:4c1::60 (see router/packets-decreaser/)
```

Verified baseline:
- `ping 1.1.1.1 source digi` OK
- Digi `80ff` underlay ICMPv6 to PD VPS OK
- session `PPPOE_CLIENT_SESSION`, no `pppd` / `tap20`

Transit BGP for `79.172.242.0/24` runs on the **PD VPS**, not Digi Bird.

## Mode switch

```bash
# Native (current)
echo 'VPP_PPPOE_MODE=native' | sudo tee /etc/default/vpp-pppoe-mode
sudo systemctl disable --now pppoe-vpp vpp-stack-reconcile
sudo systemctl enable --now vpp-pppoe-native
sudo systemctl restart vpp

# Rollback to Linux pppd
sudo /usr/local/sbin/vpp-pppoe-rollback-linux.sh
```

## Packages / plugin note

- Official VPP `26.06-release` + `vpp-pppoeclient-plugins` (Hi-Jiajun)
- Binary patch on router: IPv6CP link-local install uses `/128` (stock plugin used `/64`, rejected by VPP 26.06)
- Backup: `/usr/lib/.../pppoeclient_plugin.so.bak-ll128`

## Digi WAN IPv6 formula

```
2a01:4700:80ff:ffff:: + hex(CGNAT IPv4)
example: 100.64.142.24 → 2a01:4700:80ff:ffff::6440:8e18/64
```

Live Digi VTEP for PD GRE: `cat /run/pd-vtep-live.txt`

After Digi reconnect / VPP restart:

```bash
sudo PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
```

## Notes

- Do **not** bounce Digi/VPP just to “refresh” the VTEP — IPv4/IPv6 change every reconnect; watchdog + `ExecStartPost` handle sync.
- DHCPv6-PD via LCP `vpp-digi` still does not get Digi replies; PD GRE uses Digi WAN IPv6 directly.
