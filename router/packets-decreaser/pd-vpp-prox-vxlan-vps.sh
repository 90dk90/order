#!/bin/bash
# VPS: VXLAN peer for Digi VPP over Proximus IPv4 (not Digi GRE6).
set -euo pipefail
. /etc/pd-vxlan-lab.conf 2>/dev/null || . /etc/pd/pd-vxlan-lab.conf 2>/dev/null || \
  . "$(dirname "$0")/pd-vxlan-lab.conf"

IFACE=vxlan-lab
VNI="${VXLAN_VNI:-100}"
PORT="${VXLAN_PORT:-4789}"
MTU="${VXLAN_MTU:-1400}"
LOCAL="${VPS_V4:-77.90.4.48}"
# Digi Proximus public (NAT). Override with DIGI_PROX_PUB=...
REMOTE="${DIGI_PROX_PUB:-}"
if [ -z "$REMOTE" ] && [ -f /run/pd-digi-prox-pub.txt ]; then
  REMOTE=$(cat /run/pd-digi-prox-pub.txt)
fi
if [ -z "$REMOTE" ]; then
  REMOTE="${DIGI_PROX_PUB_DEFAULT:-91.179.61.119}"
fi
LAB_VPS="${LAB_VPS:-172.16.208.1}"
LAB_DIGI="${LAB_DIGI:-172.16.208.2}"
LAB_VPS_MAC="${LAB_VPS_MAC:-de:ad:00:00:00:d2}"
LAB_DIGI_MAC="${LAB_DIGI_MAC:-de:ad:00:00:00:d1}"
HOSTS="${HAIRPIN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10}"

modprobe vxlan
iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT

need=1
if ip link show "$IFACE" >/dev/null 2>&1; then
  CUR=$(ip -d link show "$IFACE" 2>/dev/null | tr '\n' ' ')
  echo "$CUR" | grep -q "id $VNI" \
    && echo "$CUR" | grep -q "remote $REMOTE" \
    && echo "$CUR" | grep -q "local $LOCAL" \
    && need=0 || true
fi
if [ "$need" = 1 ]; then
  ip link del "$IFACE" 2>/dev/null || true
  ip link add "$IFACE" type vxlan id "$VNI" \
    local "$LOCAL" remote "$REMOTE" dstport "$PORT" \
    nolearning ttl 64
fi
ip link set "$IFACE" address "$LAB_VPS_MAC"
ip addr replace "${LAB_VPS}/30" dev "$IFACE"
ip link set "$IFACE" mtu "$MTU" up
ip neigh replace "$LAB_DIGI" lladdr "$LAB_DIGI_MAC" nud permanent dev "$IFACE"

for ip in $HOSTS; do
  ip route replace "$ip/32" via "$LAB_DIGI" dev "$IFACE"
done
iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -o "$IFACE" -j ACCEPT
iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -i "$IFACE" -j ACCEPT

echo "pd-vpp-prox-vxlan-vps: $IFACE local=$LOCAL remote=$REMOTE vni $VNI"
ping -c 2 -W 2 "$LAB_DIGI" 2>&1 | tail -5 || true
