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

## Mode: Proximus VPP VXLAN (PPPoE disabled)

Current path: **VXLAN encapsulation inside VPP**, outer underlay via Proximus.
Digi PPPoE is masked (`x520wan` down). Do not use `af_packet` on `enp36s0` —
it SIGSEGVs VPP 26.06 on this Digi; underlay is `tap36 ↔ Linux ↔ enp36s0` instead.

```bash
# Digi (loads vxlan_plugin once, disables PPPoE)
/usr/local/sbin/pd-vpp-prox-vxlan-activate.sh
# VPS
DIGI_PROX_PUB=$(cat /run/pd-vpp-prox-pub.txt)  # from Digi
/usr/local/sbin/pd-vpp-prox-vxlan-vps.sh
```

Path: `host ↔ VPP table 81 ↔ loop208/VXLAN ↔ tap36 → Linux SNAT → Proximus → VPS vxlan-lab ↔ BGP`.

Linux keeps `192.168.129.7` (Tailscale). VXLAN SNAT/UPnP uses `192.168.129.8`.
