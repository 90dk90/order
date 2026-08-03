# Router tune — Digi/VPP + Packets Decreaser

## Stack

**VPP + Digi PPPoE native** on the home router; **BGP + GRE hub** on the Packets Decreaser VPS (`77.90.4.48`). Digi Bird is local-only (no transit peer).

Where the advice is **right for you**:
- **SMT Off** - already your case (6c/6t). Keep it Off.
- **PBO Off** - agree. You want stable clocks, not overdrive jitter.
- **isolcpus / nohz_full** for VPP workers - prepared in GRUB (`2-5`); apply on next reboot.
- **Bird/OS off VPP cores** - Linux + Bird + sync SSH pinned to **0-1**; VPP workers **2-5**.
- **MSS/MTU** - GRE 1448 / MSS 1408 (Digi PPPoE 1492 − IPv6 40 − GRE 4).

## Live layout (native - do not bounce Digi lightly)

| Role | CPUs |
|------|------|
| Linux / Bird / RPS | 0-1 |
| VPP main | 0 |
| VPP workers | 2-5 |

| Knob | Value |
|------|-------|
| TAP/DPDK rings | 4096 (X520 max; 8192 unsupported) |
| Queues | 4 |
| Scheduler | `fifo` + priority `1` |
| Plugins | slim allow-list (see `startup.conf`) |
| GRE MTU / MSS | 1448 / 1408 |
| Digi | VPP `pppoeclient` → `digi` |
| VTEP | Digi `80ff` only (`cat /run/pd-vtep-live.txt`) |

## BIOS checklist (next physical visit)

- SMT **Disabled** (already)
- PBO **Disabled**
- Maximum Performance profile
- C-states / deep idle **Disabled**
- CPB/turbo **Enabled** (throughput) unless you want ultra-flat latency
- After BIOS: reboot once so GRUB `isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5` applies

## After Digi reconnect / PD GRE sync

```bash
sudo PD_FORCE_SYNC=1 /usr/local/sbin/pd-gre-activate.sh
sudo vppctl ping 172.16.207.1 repeat 3
# then speedtest from 79.172.242.2 once public path is up
```

## Throughput ceiling (dedicated `79.172.242.2`)

Measured live (BBR+`fq`, rings 8192, GRE MTU 1448 / MSS 1408, VPP SYN-only MSS clamp):

| Ookla peer | Down | Up | Note |
|------------|------|----|------|
| Orange Slovakia (Banska Bystrica) | **~7.0–7.3 Gbps** | **~4.6 Gbps** | path can hit the 6↓ / 4–5↑ target |
| Detronics / several Budapest peers | ~4.8–6.8 Gbps | ~2.1–2.3 Gbps | peer-limited upload, not local stack |
| Digi CGNAT IPv4 alone (earlier) | — | ~4.7 Gbps | Digi line has headroom |

Remaining structural limits:

1. **Ookla peer quality** - always test 2–3 servers; one bad peer looks like a 2.3G “cap”.
2. **GRE outer RSS** - GRE/IPv6 5-tuple is near-constant → download mostly on one VPP worker (still clears 7G).
3. **Inner MTU 1448** - hard max under Digi PPPoE 1492 − IPv6/GRE.
4. **PVE `enp16s0` rx_missed** under 7G bursts - rings already maxed; optional BIOS C-state off / slightly higher coalesce.
5. **Digi inbound GRE filter** - proto 47 toward PPPoE can be dropped (see `packets-decreaser/README.md`).

PVE persist files live under `router/pve/` (`pve-nic-tune.sh`, `pve-mss-clamp.sh`, `99-dedicated-tcp.conf`).
