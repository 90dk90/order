# Packets Decreaser — Proximus primary + Digi Linux backup

## Mode (2026-08-05)
**Proximus = primary underlay** (IPv4 GRE, no WireGuard required).
**Digi PPPoE = Linux pppd** (TAP `vpp-pppoe`), not VPP native pppoeclient (avoids VPP SIGSEGV).
**GRE = Linux `gre-pd`**, not VPP `gre0`.
**VPP = LAN only** (BD10 / loop10 `/32` anti-ARP) + exit tap `vpp-pd-exit` → Linux GRE.

## Underlay selection (`pd-linux-gre-activate.sh`)
1. `PD_UNDERLAY=auto` (default): Proximus IPv4 if VPS reachable, else Digi `807f`/`817f` on `ppp0`
2. Reject Digi synthetic `80ff` for Digi underlay
3. If Proximus local is RFC1918, VPS remote = public NAT IP (`ifconfig.me`) — enable **hôte LAN ponté** on the Proximus box so inbound GRE works

## Digi PPPoE placement
- **Current live default:** Digi stays on **VPP native** `pppoeclient` (stable IPv4).
- **Optional:** `/usr/local/sbin/pd-digi-linux-pppoe.sh` moves Digi to Linux `pppd` via TAP (BD20). Use only when VPP softpath is healthy — it has crashed this box under churn.
- GRE for PD is **Linux `gre-pd`**, not VPP `gre0`, to avoid GRE SIGSEGV.

## Proximus hôte ponté (required for GRE inbound)
Without ponté, Digi box is `192.168.129.x` behind NAT; VPS sees `91.179.x.x` but **GRE return path fails**.
Bridge/hôte ponté Digi `enp36s0` MAC on the Proximus box so the public IPv4 sits on Digi → inner GRE comes up.
## Activate / watchdog
```bash
/usr/local/sbin/pd-linux-gre-activate.sh
# timer → pd-gre-watchdog-linux.sh (ppp0 + linux GRE health; no PPPoE flap on missing Digi IPv6)
```

## VPS
`pd-gre-set-vtep.sh <v4-or-v6>` rebuilds `gre-pd` as GRE or ip6gre automatically.

## Roles
| Host | Role |
|------|------|
| Router | Proximus underlay + Digi Linux PPPoE backup + Linux GRE + VPP LAN |
| PD VPS `77.90.4.48` | BGP AS219084 + GRE hub |
| PVE `79.172.242.2` | dedicated LAN host |
