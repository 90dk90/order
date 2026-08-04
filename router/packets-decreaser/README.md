# Packets Decreaser — hands-off Digi GRE + BGP

## Mode (2026-08)
**PD-only egress**: all LAN traffic via `gre0` → PD dedicated IP.
Digi sticky outbound (classify/tap/NAT) is **abandoned** (VPP SIGSEGV + ARP storms).
Opt-in only: `PD_ENABLE_STICKY=1`.

## LAN anti-ARP (latency)
Never install connected `79.172.242.0/24` or `via loop10` glean on the BVI.
Use `pd-lan-prepare.sh`: GW `.1/32`, known hosts `/32` + static neigh, cover `/24 via drop`.
Works **without** Digi global IPv6 (safe while Digi withholds RA).

## Auto VTEP sync
When Digi PPPoE renumbers IPv6:
1. `vpp-pppoe-native.service` → `ExecStartPost=pd-gre-activate.sh`
2. Router rebuilds VPP `gre0` to `2a0e:97c0:4c1::60`
3. SSH to BGP VPS → `pd-gre-set-vtep.sh <new-vtep>` rebuilds `gre-pd`
4. `pd-gre-watchdog.timer` (every 60s) catches drift / GRE down
5. While Digi `wan-ipv6` is `<none>`/`80ff`, watchdog **does not** recreate PPPoE

### Digi VTEP selection (critical)
Use **pppoeclient `wan-ipv6 observed`** (`807f` / `817f`).

Do **not** use synthetic `2a01:4700:80ff:ffff::` (outbound-ok, inbound blackhole).

## Roles
| Host | Role |
|------|------|
| Digi/VPP router | PPPoE + GRE client + table 81 LAN (BD10 / loop10 BVI `/32`) |
| PD VPS `77.90.4.48` | BGP AS219084 + GRE hub + forward `/24` |
| PVE `79.172.242.2` | BBR+fq, MSS 1408, rings 8192 |

## Underlay
Keep **GRE over IPv6**. Digi CGNAT IPv4 does not NAT proto 47 cleanly for DIY GRE.

## Harden
`pd-gre-harden.sh` is **off by default** (`PD_SKIP_HARDEN=1`) after ACL SIGSEGV under recreate.
Force with `PD_SKIP_HARDEN=0`. VPS harden still runs via `pd-gre-set-vtep`.

Install Digi:
```bash
install -m 755 pd-gre-activate.sh pd-gre-watchdog.sh pd-lan-prepare.sh /usr/local/sbin/
/usr/local/sbin/pd-lan-prepare.sh          # now, no IPv6 needed
PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh   # when Digi global is up
```
