#!/bin/bash
# Tear down Digi Proximus hairpin so GRE watchdog can reclaim table 81 default.
# Does not delete vxlan-prox lab link (keep for RSS maquette).
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"

VPP="${VPP:-vppctl}"
PBR_TABLE="${PBR_TABLE:-81}"
TAP_ID="${HAIRPIN_TAP_ID:-208}"
TAP_HOST_IF="${HAIRPIN_TAP_HOST_IF:-vpp-vxlan-lab}"
RT_TABLE="${HAIRPIN_RT_TABLE:-208}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"
VXLAN_IF="${HAIRPIN_VXLAN_IF:-vxlan-prox}"

$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 via 10.255.208.2 "tap${TAP_ID}" 2>/dev/null || true
ip rule del from "$LAN_PREFIX" table "$RT_TABLE" 2>/dev/null || true
ip rule del iif "$TAP_HOST_IF" table "$RT_TABLE" 2>/dev/null || true
ip route flush table "$RT_TABLE" 2>/dev/null || true
ip route del "$LAN_PREFIX" via 10.255.208.1 dev "$TAP_HOST_IF" 2>/dev/null || true
iptables -D FORWARD -i "$VXLAN_IF" -o "$TAP_HOST_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$TAP_HOST_IF" -o "$VXLAN_IF" -j ACCEPT 2>/dev/null || true

echo "pd-vxlan-prox-hairpin-digi-off: removed table ${PBR_TABLE} hairpin (run GRE activate/watchdog next)"
