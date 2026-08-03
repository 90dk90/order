# Router tune - target “perfect” before Infrawire VTEP update

## Opinion on the stack advice you pasted

**VPP + Bird here is justified**, not overkill. Digi is 10G PPPoE softpathed through Linux taps; Infrawire is GRE+BGP for a public `/24`. Kernel+Bird alone would work for “a few GRE tunnels”, but you already hit softpath CPU walls (~1M softnet drops on CPU0, `tap20-tx no free tx slots`, Infrawire UL stuck ~2.6G vs Digi local ~6G). VPP on X520 is the right dataplane; Bird stays control-plane.

Where that advice is **right for you**:
- **SMT Off** - already your case (6c/6t). Keep it Off.
- **PBO Off** - agree. You want stable clocks, not overdrive jitter.
- **isolcpus / nohz_full** for VPP workers - prepared in GRUB (`2-5`); apply on next reboot.
- **Bird/OS off VPP cores** - Linux + Bird + `pppd` pinned to **0-1**; VPP workers **2-5**.
- **MSS/MTU** - GRE 1448 / MSS 1408 (Digi PPPoE 1492 − IPv6 40 − GRE 4).

Where to **ignore / nuance**:
- “Don’t use VPP for GRE+BGP on Ryzen” - true for a light router; **false** once you push multi-G through a Linux PPPoE hairpin.
- “PBO/Precision Boost Off entirely” - **PBO Off**, but stock turbo/CPB On + `performance` governor is fine for throughput. Deep C-states Off in BIOS.
- Native Digi PPPoE via Hi-Jiajun `pppoeclient` is **live** (`VPP_PPPOE_MODE=native`). No Linux `pppd` / `tap20` hairpin. See `PPPOE-NATIVE.md`.

## Live layout (native - do not bounce Digi)

| Role | CPUs |
|------|------|
| Linux / Bird / RPS | 0-1 |
| VPP main | 0 |
| VPP workers | 2-5 |

| Knob | Value |
|------|-------|
| TAP/DPDK rings | 4096 |
| Queues | 4 |
| GRE MTU / MSS | 1448 / 1408 |
| Digi | VPP `pppoeclient` → `digi` |
| VTEP (ask Infrawire) | `cat /run/infrawire-vtep.txt` (Digi WAN IPv6 `2a01:4700:80ff:ffff::…`) |

## BIOS checklist (next physical visit)

- SMT **Disabled** (already)
- PBO **Disabled**
- Maximum Performance profile
- C-states / deep idle **Disabled**
- CPB/turbo **Enabled** (throughput) unless you want ultra-flat latency
- After BIOS: reboot once so GRUB `isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5` applies

## After Infrawire confirms VTEP

```bash
sudo /usr/local/sbin/infrawire-gre-activate.sh
ping -c 3 172.16.206.1
sudo birdc show protocols
# then speedtest from 79.172.242.2
```

## Throughput ceiling (dedicated `79.172.242.2`)

Measured live (BBR+`fq`, rings 8192, GRE MTU 1448 / MSS 1408, VPP SYN-only MSS clamp):

| Ookla peer | Down | Up | Note |
|------------|------|----|------|
| Orange Slovakia (Banska Bystrica) | **~7.0–7.3 Gbps** | **~4.6 Gbps** | path can hit the 6↓ / 4–5↑ target |
| Detronics / several Budapest peers | ~4.8–6.8 Gbps | ~2.1–2.3 Gbps | peer-limited upload, not local stack |
| Digi CGNAT IPv4 alone (earlier) | — | ~4.7 Gbps | Digi line has headroom |

So further local tuning is mostly marginal. Remaining structural limits:

1. **Ookla peer quality** - always test 2–3 servers; one bad peer looks like a 2.3G “cap”.
2. **GRE outer RSS** - Infrawire GRE/IPv6 5-tuple is near-constant → download mostly on one VPP worker (still clears 7G).
3. **Inner MTU 1448** - hard max under Digi PPPoE 1492 − IPv6/GRE; no free lunch without a different underlay.
4. **PVE `enp16s0` rx_missed** under 7G bursts - rings already maxed; optional BIOS C-state off / slightly higher coalesce.

PVE persist files live under `router/pve/` (`pve-nic-tune.sh`, `pve-mss-clamp.sh`, `99-infrawire-tcp.conf`).
