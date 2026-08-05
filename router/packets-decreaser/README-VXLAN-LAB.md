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

## Temporary /24 hairpin (Proximus, GRE6 down)
While Digi has no global WAN IPv6, PD `/24` can hairpin over the Proximus Linux VXLAN
(no VPP plugin, no PPPoE restart):

```bash
# Digi
/usr/local/sbin/pd-vxlan-prox-digi.sh
/usr/local/sbin/pd-vxlan-prox-hairpin-digi.sh
# VPS
/usr/local/sbin/pd-vxlan-prox-hairpin-vps.sh
```

Path: `host ↔ VPP table 81 ↔ tap208 ↔ vxlan-prox ↔ VPS vxlan-lab ↔ BGP`.

Revert when GRE6 is back:
```bash
# Digi then VPS
/usr/local/sbin/pd-vxlan-prox-hairpin-digi-off.sh
/usr/local/sbin/pd-vxlan-prox-hairpin-vps-off.sh
# then let pd-gre-watchdog reclaim gre0
```
