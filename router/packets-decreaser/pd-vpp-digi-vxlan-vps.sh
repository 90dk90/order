#!/bin/bash
# VPS: peer Digi VPP VXLAN over Digi IPv6 underlay (VXLAN only, no gre-pd).
set -euo pipefail
# Capture CLI/env override BEFORE sourcing conf files that may carry a stale Digi VTEP.
CLI_DIGI_VTEP="${DIGI_VTEP:-}"
. /etc/pd-vxlan-lab.conf 2>/dev/null || . /etc/pd/pd-vxlan-lab.conf 2>/dev/null || \
  . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/pd/digi-vtep.env 2>/dev/null || true
. /etc/pd-gre.env 2>/dev/null || true
# Prefer: explicit CLI → /run live file → conf DIGI_VTEP
if [ -z "$CLI_DIGI_VTEP" ] && [ -f /run/pd-digi-vtep.txt ]; then
  CLI_DIGI_VTEP=$(tr -d ' \r\n' </run/pd-digi-vtep.txt)
fi
DIGI_VTEP="${CLI_DIGI_VTEP:-${DIGI_VTEP:-}}"

IFACE=vxlan-lab
VNI="${VXLAN_VNI:-100}"
PORT="${VXLAN_PORT:-4789}"
MTU="${VXLAN_MTU:-1400}"
LOCAL="${PD_VTEP:-2a0e:97c0:4c1::60}"
REMOTE="${DIGI_VTEP:-}"
[ -n "$REMOTE" ] || { echo "set DIGI_VTEP=<digi-wan-ipv6>" >&2; exit 1; }
LAB_VPS="${LAB_VPS:-172.16.208.1}"
LAB_DIGI="${LAB_DIGI:-172.16.208.2}"
LAB_VPS_MAC="${LAB_VPS_MAC:-de:ad:00:00:00:d2}"
LAB_DIGI_MAC="${LAB_DIGI_MAC:-de:ad:00:00:00:d1}"
HOSTS="${HAIRPIN_HOSTS:-79.172.242.1 79.172.242.2 79.172.242.3 79.172.242.10 79.172.242.48}"

modprobe vxlan
ip6tables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  ip6tables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT

ip link del "$IFACE" 2>/dev/null || true
ip link add "$IFACE" type vxlan id "$VNI" \
  local "$LOCAL" remote "$REMOTE" dstport "$PORT" \
  nolearning ttl 64 udp6zerocsumtx udp6zerocsumrx
ip link set "$IFACE" address "$LAB_VPS_MAC"
ip addr replace "${LAB_VPS}/30" dev "$IFACE"
ip link set "$IFACE" mtu "$MTU" up
ip neigh replace "$LAB_DIGI" lladdr "$LAB_DIGI_MAC" nud permanent dev "$IFACE"

# Prefer vxlan-lab over gre-pd for PD hosts; leave gre-pd unused
for ip in $HOSTS; do
  ip route replace "$ip/32" via "$LAB_DIGI" dev "$IFACE"
done
# Do not use gre-pd
ip link set gre-pd down 2>/dev/null || true

echo "pd-vpp-digi-vxlan-vps: $IFACE local=$LOCAL remote=$REMOTE vni $VNI (GRE down)"
ping -c 2 -W 2 "$LAB_DIGI" 2>&1 | tail -5 || true
