#!/bin/bash
# Temporary PD /24 hairpin: Digi VPP table 81 → Linux tap → Proximus VXLAN → VPS.
# Use ONLY while Digi GRE6 is down (no global WAN IPv6). Does NOT touch PPPoE.
# Pair with pd-vxlan-prox-hairpin-vps.sh on the VPS.
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"

VPP="${VPP:-vppctl}"
PBR_TABLE="${PBR_TABLE:-81}"
TAP_ID="${HAIRPIN_TAP_ID:-208}"
TAP_HOST_IF="${HAIRPIN_TAP_HOST_IF:-vpp-vxlan-lab}"
TAP_VPP_IP="${HAIRPIN_TAP_VPP:-10.255.208.1/30}"
TAP_HOST_IP="${HAIRPIN_TAP_HOST:-10.255.208.2/30}"
TAP_HOST_PEER="${HAIRPIN_TAP_VPP%/*}"
VXLAN_IF="${HAIRPIN_VXLAN_IF:-vxlan-prox}"
RT_TABLE="${HAIRPIN_RT_TABLE:-208}"
LAN_PREFIX="${LAN_PREFIX:-79.172.242.0/24}"

# Ensure Proximus VXLAN underlay exists
if ! ip link show "$VXLAN_IF" &>/dev/null; then
  /usr/local/sbin/pd-vxlan-prox-digi.sh
fi

# VPP tap ↔ Linux
if ! $VPP show interface addr "tap${TAP_ID}" 2>/dev/null | grep -q "${TAP_HOST_PEER}"; then
  $VPP create tap id "$TAP_ID" host-if-name "$TAP_HOST_IF" 2>/dev/null || true
fi
$VPP set interface state "tap${TAP_ID}" up
if ! $VPP show interface addr "tap${TAP_ID}" 2>/dev/null | grep -q "${TAP_HOST_PEER}/"; then
  $VPP set interface ip address "tap${TAP_ID}" "$TAP_VPP_IP" 2>/dev/null || true
fi
$VPP set interface mtu packet 1400 "tap${TAP_ID}" 2>/dev/null || true

ip link set "$TAP_HOST_IF" up 2>/dev/null || true
ip addr replace "$TAP_HOST_IP" dev "$TAP_HOST_IF"
ip link set "$TAP_HOST_IF" mtu 1400 2>/dev/null || true

# Static neigh both sides
HOST_MAC=$(ip -o link show "$TAP_HOST_IF" | awk '{print $17}')
VPP_MAC=$($VPP show hardware-interfaces "tap${TAP_ID}" 2>/dev/null | awk '/Ethernet address/{print $3; exit}')
[ -n "$HOST_MAC" ] && $VPP set ip neighbor "tap${TAP_ID}" "${TAP_HOST_IP%/*}" "$HOST_MAC" static 2>/dev/null || true
[ -n "$VPP_MAC" ] && ip neigh replace "$TAP_HOST_PEER" lladdr "$VPP_MAC" nud permanent dev "$TAP_HOST_IF"

# Table 81 default → Linux hairpin (replace GRE default while down)
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "${TAP_HOST_IP%/*}" "tap${TAP_ID}"

# Linux: PD sources / iif tap → VXLAN to VPS
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w "net.ipv4.conf.${VXLAN_IF}.rp_filter=0" 2>/dev/null || true
sysctl -q -w "net.ipv4.conf.${TAP_HOST_IF}.rp_filter=0" 2>/dev/null || true

ip route replace default via "${LAB_VPS}" dev "$VXLAN_IF" table "$RT_TABLE"
ip route replace "$LAN_PREFIX" via "$TAP_HOST_PEER" dev "$TAP_HOST_IF"
ip rule del from "$LAN_PREFIX" table "$RT_TABLE" 2>/dev/null || true
ip rule add from "$LAN_PREFIX" table "$RT_TABLE" priority 90
ip rule del iif "$TAP_HOST_IF" table "$RT_TABLE" 2>/dev/null || true
ip rule add iif "$TAP_HOST_IF" table "$RT_TABLE" priority 100

iptables -C FORWARD -i "$VXLAN_IF" -o "$TAP_HOST_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$VXLAN_IF" -o "$TAP_HOST_IF" -j ACCEPT
iptables -C FORWARD -i "$TAP_HOST_IF" -o "$VXLAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$TAP_HOST_IF" -o "$VXLAN_IF" -j ACCEPT

echo "pd-vxlan-prox-hairpin-digi: table ${PBR_TABLE} default → ${TAP_HOST_IP%/*} → ${VXLAN_IF} (Proximus, PPPoE untouched)"
$VPP ping 1.1.1.1 source loop10 table-id "$PBR_TABLE" repeat 2 || true
