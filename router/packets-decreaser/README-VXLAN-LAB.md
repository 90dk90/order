# VXLAN lab maquette (parallel to GRE — does not replace PD)
#
## Goal
UDP outer + sport entropy → measure X520 RSS multi-queue vs GRE q0 monopoly.
Production path stays on gre0 / gre-pd.

## Topology
- Digi VPP: L2 VXLAN + BVI loop208 → 172.16.208.2/30
- VPS Linux: classic VXLAN vxlan-lab → 172.16.208.1/30
- VNI 100, UDP 4789, MTU 1400
- GRE 172.16.207.0/30 untouched

## Why not VXLAN-GPE
Linux GPE requires `external` (not simple P2P). Classic VXLAN interops both sides.

## Prep (safe, no PPPoE touch)
1. Files on Digi: `/etc/pd/pd-vxlan-lab.conf`, `pd-vxlan-lab-digi.sh`, `pd-vxlan-lab-arm.sh`, `pd-vxlan-lab-rss.sh`
2. Files on VPS: `/etc/pd-vxlan-lab.conf`, `pd-vxlan-lab-vps.sh` (+ interface can be pre-created)
3. Plugin: `startup.conf.with-vxlan-lab` ready; **do not** enable until Digi IPv6 stable
4. One planned VPP restart later loads `vxlan_plugin.so`, then `pd-vxlan-lab-arm.sh`

## Activate later (when Digi IPv6 back)
```bash
# Digi — ONLY after IPv6 observed, ONE restart to load plugin if needed:
#   install startup with vxlan_plugin, systemctl restart vpp  # planned window
/usr/local/sbin/pd-vxlan-lab-arm.sh
# VPS:
/usr/local/sbin/pd-vxlan-lab-vps.sh
# Measure RSS while flooding lab /30:
/usr/local/sbin/pd-vxlan-lab-rss.sh x520wan 5
```

## Success criteria
- `rx_q1/q2/q3` non-zero under multi-flow lab traffic
- GRE path still healthy on 172.16.207.0/30

## Mode: VXLAN only (GRE retired)

PD transport is **VXLAN only** — no GRE fallback.

- **Now:** Digi VPP VXLAN over Proximus interim (`tap36→Linux`) while PPPoE off
- **Next:** Digi PPPoE up → `pd-vpp-digi-vxlan-cutover.sh` → underlay Digi IPv6 on `x520wan`

```bash
# Current (Proximus interim)
/usr/local/sbin/pd-vpp-prox-vxlan-activate.sh
/usr/local/sbin/pd-vpp-prox-vxlan-vps.sh

# Later (Digi underlay — after PPPoE + global IPv6)
/usr/local/sbin/pd-vpp-digi-vxlan-cutover.sh
DIGI_VTEP=<digi-wan-ipv6> /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh
```

Path (interim): `host ↔ VPP table 81 ↔ loop208/VXLAN ↔ tap36 → Linux SNAT → Proximus → VPS`.

## Pre-PPPoE validation scorecard (2026-08-05)

| Check | Result |
|---|---|
| PPPoE masked, `x520wan` admin-down by policy | OK |
| `vxlan_plugin` loaded, tunnel Digi↔VPS | OK |
| `/24` `.1`/`.2` + egress `1.1.1.1` table 81 | OK |
| VPP VXLAN outer **UDP sport entropy** (multi-flow) | OK (≠ fixed like GRE) |
| Scripts idempotent (`pd-vpp-prox-vxlan.sh`) | OK |
| `x520wan` 4 RX queues + workers placed | OK |
| `x520wan` RSS **activates on admin-up** (`ipv4-udp` included) | OK |
| af_packet on `enp36s0` | FAIL (SEGV in `ethernet_input`) — do not use |
| Digi PPPoE session / WAN IPv6 | **needs** `PD_ALLOW_PPPOE_RESTART=1 pd-pppoe-enable-once.sh` |
| RSS multi-queue counters under Digi load | **needs PPPoE** (traffic on `x520wan`) |
| GRE6 vs VXLAN throughput on Digi | N/A — GRE retired |

## Done now (no PPPoE session)
- MSS clamp 1360 on `loop208` / `vxlan_tunnel208` / `loop10` (live clamped >0)
- PPPoE **plugins preloaded** in VPP; **session still masked**
- No-flap guards: `PD_ALLOW_VPP_RESTART` / `PD_ALLOW_PPPOE_RESTART`
- `pd-pppoe-enable-once.sh` — one planned PPPoE bring-up, **no VPP restart**
- `pd-vxlan-vtep-watchdog` — Digi IPv6 drift without PPPoE flap
- Proximus iperf baseline ~400 Mbps (shared by PD via tap36) in `/etc/pd/pd-proximus-baseline.txt`
- Cutover dry-run: exits cleanly without Digi IPv6
