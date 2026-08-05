#!/bin/bash
# VPS: parallel Linux VXLAN lab peer for Digi VPP (GRE gre-pd untouched).
set -euo pipefail
CONF="${1:-/etc/pd-vxlan-lab.conf}"
[ -f "$CONF" ] || CONF="$(dirname "$0")/pd-vxlan-lab.conf"
# shellcheck disable=SC1090
. "$CONF"
ENV_FILE=/etc/pd-gre.env
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

DIGI_VTEP="${DIGI_VTEP:-}"
if [ -z "$DIGI_VTEP" ]; then
  echo "pd-vxlan-lab-vps: DIGI_VTEP missing in /etc/pd-gre.env" >&2
  exit 1
fi
LOCAL_VTEP="${LOCAL_VTEP:-${PD_VTEP:-2a0e:97c0:4c1::60}}"
IFACE=vxlan-lab
PING_PEER="${PING_PEER:-1}"

modprobe vxlan 2>/dev/null || true

# Allow VXLAN UDP (IPv6 underlay)
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -C INPUT -p udp --dport "$VXLAN_PORT" -j ACCEPT 2>/dev/null || \
    ip6tables -I INPUT 1 -p udp --dport "$VXLAN_PORT" -j ACCEPT
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p udp --dport "$VXLAN_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p udp --dport "$VXLAN_PORT" -j ACCEPT
fi

need=1
if ip link show "$IFACE" >/dev/null 2>&1; then
  CUR=$(ip -d link show "$IFACE" 2>/dev/null | tr '\n' ' ')
  echo "$CUR" | grep -q "id $VXLAN_VNI" \
    && echo "$CUR" | grep -q "remote $DIGI_VTEP" \
    && echo "$CUR" | grep -q "local $LOCAL_VTEP" \
    && need=0 || true
fi

if [ "$need" = 1 ]; then
  ip link del "$IFACE" 2>/dev/null || true
  ip link add "$IFACE" type vxlan id "$VXLAN_VNI" \
    local "$LOCAL_VTEP" \
    remote "$DIGI_VTEP" \
    dstport "$VXLAN_PORT" \
    nolearning \
    udp6zerocsumtx udp6zerocsumrx
fi

# Stable MAC so Digi static neigh works across recreate
ip link set "$IFACE" address "$LAB_VPS_MAC" 2>/dev/null || true
ip addr replace "$LAB_VPS/30" dev "$IFACE"
ip link set "$IFACE" mtu "$VXLAN_MTU" up

# Digi BVI MAC
ip neigh replace "$LAB_DIGI" lladdr "$LAB_DIGI_MAC" nud permanent dev "$IFACE"

echo "pd-vxlan-lab-vps: OK $IFACE $LAB_VPS/30 remote=$DIGI_VTEP (gre-pd untouched)"
ip -d link show "$IFACE" | head -8
if [ "$PING_PEER" = 1 ]; then
  ping -c 2 -W 1 "$LAB_DIGI" 2>&1 | tail -6 || echo "(peer Digi lab not up yet — expected while waiting)"
fi
