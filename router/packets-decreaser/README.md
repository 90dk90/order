# Packets Decreaser — hands-off Digi GRE + BGP

## Auto VTEP sync
When Digi PPPoE renumbers IPv6:
1. `vpp-pppoe-native.service` → `ExecStartPost=pd-gre-activate.sh`
2. Router rebuilds VPP `gre0` to `2a0e:97c0:4c1::60`
3. SSH to BGP VPS → `pd-gre-set-vtep.sh <new-vtep>` rebuilds `gre-pd`
4. `pd-gre-watchdog.timer` (every 60s) catches drift / GRE down

### Digi VTEP selection (critical)
Use **pppoeclient `wan-ipv6 observed`** (today `2a01:4700:807f:ffff::…`).

Do **not** use the synthetic `2a01:4700:80ff:ffff::` address derived from CGNAT IPv4:
- Digi→world from `80ff` works
- **world/PD→`80ff` does not** (ICMP/GRE blackhole)
- Digi-observed `807f` is reachable both ways from the PD VPS

## Roles
| Host | Role |
|------|------|
| Digi/VPP router | PPPoE + GRE client + table 81 LAN (BD10 / loop10 BVI) |
| PD VPS `77.90.4.48` | BGP AS219084 + GRE hub + forward `/24` |
| PVE `79.172.242.2` | BBR+fq, MSS 1408, rings 8192 |

Infrawire has been removed from the Digi router.

## Optional VPP dataplane opts (`router/debian-vpp/startup.conf`)
| Knob | Live value | Note |
|------|------------|------|
| Slim plugins | `plugin default { disable }` + Digi/GRE/NAT set | Empty `api-trace {}` aborts VPP — omit the block |
| DPDK desc | **4096** | X520/82599 hard-cap; 8192 will not probe |
| Scheduler | `fifo` + `scheduler-priority 1` | Without priority, VPP stays `SCHED_OTHER` |

## Underlay
Keep **GRE over IPv6** (ip6gre / VPP gre with IPv6 endpoints). Digi CGNAT IPv4 does not NAT proto 47 cleanly for DIY GRE.
