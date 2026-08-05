#!/bin/bash
# Digi: VXLAN in VPP over Proximus.
# Underlay: VPP tap36 ↔ Linux vpp-prox ↔ enp36s0 (af_packet on enp36s0 SIGSEGVs on this box).
# VXLAN encap stays in VPP. Digi PPPoE must stay disabled (PD_PPPOE=0).
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/default/pd-underlay 2>/dev/null || true

VPP="${VPP:-/usr/bin/vppctl}"
PBR_TABLE="${PBR_TABLE:-81}"
TAP_ID="${PROX_TAP_ID:-36}"
TAP_HOST_IF="${PROX_TAP_HOST_IF:-vpp-prox}"
TAP_VPP_IP="${PROX_TAP_VPP:-10.255.36.1/30}"
TAP_HOST_IP="${PROX_TAP_HOST:-10.255.36.2/30}"
TAP_HOST_PEER="${TAP_HOST_IP%/*}"
TAP_VPP_ADDR="${TAP_VPP_IP%/*}"
PROX_DEV="${PROX_HOST_IF:-enp36s0}"
PROX_SNAT_IP="${PROX_LOCAL:-192.168.129.7}"
# Prefer secondary .8 for VXLAN DNAT/UPnP if present; else .7
PROX_PUB_LOCAL="${PROX_VPP_IP%/*}"
PROX_PUB_LOCAL="${PROX_PUB_LOCAL:-192.168.129.8}"
VPS_V4="${VPS_V4:-77.90.4.48}"
VXLAN_VNI="${VXLAN_VNI:-100}"
VXLAN_PORT="${VXLAN_PORT:-4789}"
VXLAN_MTU="${VXLAN_MTU:-1400}"
LAB_BD="${LAB_BD:-208}"
LAB_LOOP="${LAB_LOOP:-loop208}"
LAB_DIGI="${LAB_DIGI:-172.16.208.2}"
LAB_VPS="${LAB_VPS:-172.16.208.1}"
LAB_DIGI_MAC="${LAB_DIGI_MAC:-de:ad:00:00:00:d1}"
LAB_VPS_MAC="${LAB_VPS_MAC:-de:ad:00:00:00:d2}"
LAB_VXLAN_INSTANCE="${LAB_VXLAN_INSTANCE:-208}"

$VPP show version >/dev/null
if ! $VPP show vxlan tunnel >/dev/null 2>&1; then
  echo "pd-vpp-prox-vxlan: vxlan_plugin not loaded" >&2
  exit 1
fi

# --- underlay tap (VPP ↔ Linux) ---
if ! $VPP show interface 2>/dev/null | awk -v n="tap${TAP_ID}" '$1==n{f=1} END{exit !f}'; then
  $VPP create tap id "$TAP_ID" host-if-name "$TAP_HOST_IF" host-mtu-size 1500
fi
$VPP set interface state "tap${TAP_ID}" up
if ! $VPP show interface addr "tap${TAP_ID}" 2>/dev/null | grep -q "${TAP_VPP_ADDR}/"; then
  $VPP set interface ip address "tap${TAP_ID}" "$TAP_VPP_IP" 2>/dev/null || true
fi
ip link set "$TAP_HOST_IF" up 2>/dev/null || true
ip addr replace "$TAP_HOST_IP" dev "$TAP_HOST_IF"
ip link set "$TAP_HOST_IF" mtu 1500 2>/dev/null || true

HOST_MAC=$(ip -o link show "$TAP_HOST_IF" | awk '{for(i=1;i<=NF;i++) if($i=="link/ether"){print $(i+1); exit}}')
[ -n "$HOST_MAC" ] && $VPP set ip neighbor "tap${TAP_ID}" "$TAP_HOST_PEER" "$HOST_MAC" static 2>/dev/null || true

# VPP default via Linux (Proximus behind Linux)
$VPP ip route add 0.0.0.0/0 via "$TAP_HOST_PEER" "tap${TAP_ID}" 2>/dev/null || true

# Linux: forward underlay toward Proximus; SNAT VXLAN outer to LAN IP
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.all.rp_filter=0
sysctl -q -w "net.ipv4.conf.${TAP_HOST_IF}.rp_filter=0" 2>/dev/null || true
sysctl -q -w "net.ipv4.conf.${PROX_DEV}.rp_filter=0" 2>/dev/null || true

# Secondary local for UPnP/DNAT (do not steal .7)
ip addr replace "${PROX_PUB_LOCAL}/23" dev "$PROX_DEV" 2>/dev/null || true

iptables -t nat -C POSTROUTING -s "${TAP_VPP_ADDR}/32" -o "$PROX_DEV" -j SNAT --to-source "$PROX_PUB_LOCAL" 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "${TAP_VPP_ADDR}/32" -o "$PROX_DEV" -j SNAT --to-source "$PROX_PUB_LOCAL"
iptables -t nat -C PREROUTING -i "$PROX_DEV" -p udp --dport "$VXLAN_PORT" -j DNAT --to-destination "$TAP_VPP_ADDR" 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$PROX_DEV" -p udp --dport "$VXLAN_PORT" -j DNAT --to-destination "$TAP_VPP_ADDR"
iptables -C FORWARD -i "$TAP_HOST_IF" -o "$PROX_DEV" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$TAP_HOST_IF" -o "$PROX_DEV" -j ACCEPT
iptables -C FORWARD -i "$PROX_DEV" -o "$TAP_HOST_IF" -j ACCEPT 2>/dev/null || \
  iptables -I FORWARD 1 -i "$PROX_DEV" -o "$TAP_HOST_IF" -j ACCEPT

# --- VXLAN L2 + BVI ---
$VPP create bridge-domain "$LAB_BD" 2>/dev/null || true
if ! $VPP show interface 2>/dev/null | awk -v n="$LAB_LOOP" '$1==n{f=1} END{exit !f}'; then
  $VPP create loopback interface instance "$LAB_BD" 2>/dev/null || true
fi
$VPP set interface mac address "$LAB_LOOP" "$LAB_DIGI_MAC" 2>/dev/null || true
$VPP set interface l2 bridge "$LAB_LOOP" "$LAB_BD" bvi 2>/dev/null || true
$VPP set interface state "$LAB_LOOP" up
if ! $VPP show interface addr "$LAB_LOOP" 2>/dev/null | grep -q "${LAB_DIGI}/30"; then
  $VPP set interface ip address "$LAB_LOOP" "${LAB_DIGI}/30" 2>/dev/null || true
fi

SRC="$TAP_VPP_ADDR"
DST="$VPS_V4"
IFACE="vxlan_tunnel${LAB_VXLAN_INSTANCE}"
if ! $VPP show interface 2>/dev/null | awk -v n="$IFACE" '$1==n{f=1} END{exit !f}'; then
  $VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" del 2>/dev/null || true
  OUT=$($VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VXLAN_VNI" instance "$LAB_VXLAN_INSTANCE" dst_port "$VXLAN_PORT" 2>&1) || true
  echo "pd-vpp-prox-vxlan: create tunnel: $OUT"
fi
$VPP show interface 2>/dev/null | awk -v n="$IFACE" '$1==n{f=1} END{exit !f}' || {
  echo "pd-vpp-prox-vxlan: missing $IFACE" >&2
  $VPP show vxlan tunnel 2>/dev/null || true
  exit 1
}

$VPP set interface l2 bridge "$IFACE" "$LAB_BD" 2>/dev/null || true
$VPP set interface state "$IFACE" up
$VPP set interface mtu packet "$VXLAN_MTU" "$IFACE" 2>/dev/null || true
$VPP set interface mtu packet "$VXLAN_MTU" "$LAB_LOOP" 2>/dev/null || true
$VPP set ip neighbor "$LAB_LOOP" "$LAB_VPS" "$LAB_VPS_MAC" static 2>/dev/null || true

# PD table 81 default via VXLAN BVI
$VPP ip route del table "$PBR_TABLE" 0.0.0.0/0 2>/dev/null || true
$VPP ip route add table "$PBR_TABLE" 0.0.0.0/0 via "$LAB_VPS" "$LAB_LOOP"

/usr/local/sbin/pd-vpp-vxlan-mss.sh 2>/dev/null || true

# UPnP → Proximus local used for SNAT
if command -v upnpc >/dev/null 2>&1; then
  upnpc -d "$VXLAN_PORT" UDP >/dev/null 2>&1 || true
  upnpc -a "$PROX_PUB_LOCAL" "$VXLAN_PORT" "$VXLAN_PORT" UDP >/dev/null 2>&1 || true
fi
PUB=$(curl -4 -sS -m 5 ifconfig.me || true)
echo "${PUB:-}" > /run/pd-vpp-prox-pub.txt
printf 'TAP=tap%s\nVXLAN=%s\nSRC=%s\nDST=%s\nPUB=%s\nSNAT=%s\n' \
  "$TAP_ID" "$IFACE" "$SRC" "$DST" "${PUB:-}" "$PROX_PUB_LOCAL" > /run/pd-vpp-prox-vxlan.env

echo "pd-vpp-prox-vxlan: VPP VXLAN $SRC=>$DST vni $VXLAN_VNI via tap${TAP_ID}/Proximus snat=$PROX_PUB_LOCAL pub=${PUB:-?} (PPPoE off)"
$VPP ping "$LAB_VPS" repeat 3 2>&1 | tail -8 || true
$VPP ping 1.1.1.1 source loop10 table-id "$PBR_TABLE" repeat 2 2>&1 | tail -8 || true
