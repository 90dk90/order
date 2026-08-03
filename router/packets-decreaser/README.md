# Packets Decreaser — hands-off Digi GRE + BGP

## Auto VTEP sync
When Digi PPPoE renumbers IPv6:
1. `vpp-pppoe-native.service` → `ExecStartPost=pd-gre-activate.sh`
2. Router rebuilds VPP `gre0` to `2a0e:97c0:4c1::60`
3. SSH to BGP VPS → `pd-gre-set-vtep.sh <new-vtep>` rebuilds `gre-pd`
4. `pd-gre-watchdog.timer` (every 60s) catches drift / GRE down

## Roles
| Host | Role |
|------|------|
| Digi/VPP router | PPPoE + GRE client + table 81 LAN |
| PD VPS `77.90.4.48` | BGP AS219084 + GRE hub + forward `/24` |
| PVE `79.172.242.2` | BBR+fq, MSS 1408, rings 8192 |

Infrawire GRE/BGP stays disabled (`/run/infrawire-gre-cut.flag`).
