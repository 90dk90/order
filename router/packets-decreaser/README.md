# Packets Decreaser — hands-off Digi GRE + BGP

## Auto VTEP sync
When Digi PPPoE renumbers IPv6:
1. `vpp-pppoe-native.service` → `ExecStartPost=pd-gre-activate.sh`
2. Router rebuilds VPP `gre0` to `2a0e:97c0:4c1::60` (src = Digi `2a01:4700:80ff:…` only)
3. SSH to BGP VPS → `pd-gre-set-vtep.sh <new-vtep>` rebuilds `gre-pd`
4. `pd-gre-watchdog.timer` (every 60s) catches drift / GRE down

Always pick the Digi **`80ff`** underlay address — Digi also installs a secondary `807f` prefix that is not a usable VTEP.

## Roles
| Host | Role |
|------|------|
| Digi/VPP router | PPPoE + GRE client + table 81 LAN (BD10 / loop10 BVI) |
| PD VPS `77.90.4.48` | BGP AS219084 + GRE hub + forward `/24` |
| PVE `79.172.242.2` | BBR+fq, MSS 1408, rings 8192 |

Infrawire GRE/BGP stays disabled (`/run/infrawire-gre-cut.flag`).

## Optional VPP dataplane opts (`router/debian-vpp/startup.conf`)
| Knob | Live value | Note |
|------|------------|------|
| Slim plugins | `plugin default { disable }` + Digi/GRE/NAT set | Empty `api-trace {}` aborts VPP — omit the block |
| DPDK desc | **4096** | X520/82599 hard-cap; 8192 will not probe |
| Scheduler | `fifo` + `scheduler-priority 1` | Without priority, VPP stays `SCHED_OTHER` |

## Known path issue (Digi inbound GRE)
Underlay ICMPv6 Digi ↔ PD VPS works. **Outbound** GRE (Digi→VPS) arrives on the VPS. **Inbound** GRE (VPS→Digi, including echo replies) never hits `x520wan` — Digi appears to drop IP proto 47 toward the PPPoE session. Until that clears (or underlay moves to UDP/WG), public `/24` via PD GRE stays one-way.
