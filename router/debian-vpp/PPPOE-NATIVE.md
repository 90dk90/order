# Native Digi PPPoE in VPP

## Status (2026-08-03)

**IPv4 dataplane: DONE** — Digi session runs inside VPP (`pppoeclient`), no `pppd` / `tap20` hairpin.

```
x520wan → pppoeclient → digi (100.64.x.x) → NAT44 ← loop10/79.172.242.0/24
```

Verified: `ping 1.1.1.1 source digi` OK, session `PPPOE_CLIENT_SESSION`, AC `ftth`.

**IPv6 / Infrawire underlay: NOT DONE yet**

- Plugin reports `dhcp6 ia-na/pd <unavailable>` on stock FD.io `dhcp_plugin` (needs Hi-Jiajun fork dhcp runtime symbols).
- Linux `dhcp6c` via LCP `vpp-digi` solicits but Digi does not answer (LL / path quirk vs old `ppp0`).
- GRE Infrawire still needs a routed Digi PD + Infrawire VTEP update.

## Mode switch

```bash
# Native (current)
echo 'VPP_PPPOE_MODE=native' | sudo tee /etc/default/vpp-pppoe-mode
sudo systemctl disable --now pppoe-vpp
sudo systemctl enable --now vpp-pppoe-native
sudo systemctl restart vpp

# Rollback to Linux pppd
sudo /usr/local/sbin/vpp-pppoe-rollback-linux.sh
```

## Packages

- `vpp-pppoeclient-plugins` 26.06-rc0 (Hi-Jiajun) on official VPP 26.06-release — loads OK.

## Next for full perfection

1. Get Digi DHCPv6-PD working on `digi` (fork dhcp plugin or fix LCP dhcp6 path).
2. Point GRE src at live PD `::2`, underlay via `digi` (no Linux).
3. Ask Infrawire to update VTEP, then `infrawire-gre-activate.sh`.
4. Speedtest `.2` Infrawire UL — expect large gain vs old softpath.
