# Packets Decreaser BGP VPS + GRE to Digi

## Live
- VPS: `77.90.4.48` / `2a0e:97c0:4c1::60` (AS219084)
- BGP peers: `77.90.4.247` + `77.90.4.246` (AS214243) — Established
- GRE: VPS `gre-pd` ↔ Digi/VPP `gre0` over IPv6 (`encaplimit none` required)
- Inner: `172.16.207.1/30` (VPS) ↔ `172.16.207.2/30` (home)
- Prefix: `79.172.242.0/24` via GRE to origin

## Critical Linux GRE flag
`ip -6 tunnel ... encaplimit none` — without this, Linux adds IPv6 DSTOPT and VPP drops GRE.

## After Digi PPPoE reconnect
1. New Digi VTEP in `/run/infrawire-vtep.txt`
2. Run `/usr/local/sbin/pd-gre-activate.sh` on router (also ExecStartPost on vpp-pppoe-native)
3. Update VPS `/etc/pd-gre.env` DIGI_VTEP=... and `systemctl restart pd-gre-to-digi`

## Ask Packets Decreaser if /24 not global
- Propagate `79.172.242.0/24` to upstreams
- Allow source `79.172.242.0/24` out of BGP VPS (disable uRPF/anti-spoof)
