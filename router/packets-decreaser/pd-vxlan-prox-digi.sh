#!/bin/bash
# Digi: VXLAN lab over Proximus (Linux) — does NOT touch VPP/PPPoE.
# Underlay: enp36s0 NAT → VPS 77.90.4.48:4789 (UPnP maps WAN UDP/4789).
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
VPS_V4="${VPS_V4:-77.90.4.48}"
LOCAL="${PROX_LOCAL:-192.168.129.7}"
IFACE=vxlan-prox
DEV=enp36s0

modprobe vxlan
ip link del "$IFACE" 2>/dev/null || true
ip link add "$IFACE" type vxlan id "$VXLAN_VNI" \
  local "$LOCAL" remote "$VPS_V4" dstport "$VXLAN_PORT" \
  dev "$DEV" nolearning ttl 64
ip link set "$IFACE" address "$LAB_DIGI_MAC"
ip addr replace "$LAB_DIGI/30" dev "$IFACE"
ip link set "$IFACE" mtu "$VXLAN_MTU" up
ip neigh replace "$LAB_VPS" lladdr "$LAB_VPS_MAC" nud permanent dev "$IFACE"
iptables -C INPUT -p udp --dport "$VXLAN_PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p udp --dport "$VXLAN_PORT" -j ACCEPT

# Best-effort UPnP so VPS→Digi works through Proximus NAT
if command -v upnpc >/dev/null 2>&1; then
  upnpc -a "$LOCAL" "$VXLAN_PORT" "$VXLAN_PORT" UDP >/dev/null 2>&1 || true
fi
PUB=$(curl -4 -sS -m 5 ifconfig.me || true)
echo "$PUB" > /run/pd-vxlan-prox-pub.txt
echo "pd-vxlan-prox-digi: $IFACE $LAB_DIGI/30 via Proximus pub=${PUB:-?} (PPPoE untouched)"
ping -c 2 -W 2 "$LAB_VPS" 2>&1 | tail -6 || true
