# Native Digi PPPoE in VPP

## Status (2026-08-03)

**Dataplane: DONE (native, no Linux pppd hairpin)**

```
x520wan → pppoeclient → digi
  IPv4: 100.64.x.x/32 (CGNAT) + NAT44 ← loop10/79.172.242.0/24
  IPv6: 2a01:4700:80ff:ffff::<ipv4-hex>/64  (Digi WAN, globally routed)
  GRE:  gre0 src=<Digi WAN IPv6> dst=2a10:4646:500::1  underlay=digi
```

Verified:
- `ping 1.1.1.1 source digi` OK
- `ping 2a10:4646:500::1 source digi` OK (Infrawire underlay)
- session `PPPOE_CLIENT_SESSION`, no `pppd` / `tap20`

**Infrawire BGP:** waiting on Infrawire VTEP update to the live Digi WAN IPv6 in `/run/infrawire-vtep.txt`. Until then clients stay on Digi SNAT (`digi-snat-fallback.sh`).

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

Live VTEP for Infrawire: `cat /run/infrawire-vtep.txt`

After they update:

```bash
sudo /usr/local/sbin/infrawire-gre-activate.sh
```

## Notes

- Do **not** bounce Digi/VPP just to “refresh” the VTEP — IPv4/IPv6 change every reconnect.
- DHCPv6-PD via LCP `vpp-digi` still does not get Digi replies; Infrawire underlay no longer depends on it.
