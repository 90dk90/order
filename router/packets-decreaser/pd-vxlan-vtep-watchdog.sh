#!/bin/bash
# Digi VTEP drift fix for VXLAN-only — never touches PPPoE / never restarts VPP.
# If Digi WAN IPv6 changes, recreate VXLAN tunnel src only.
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf"
. /etc/default/pd-underlay 2>/dev/null || true

[ "${PD_TRANSPORT:-vxlan}" = "vxlan" ] || exit 0
[ "${PD_UNDERLAY:-}" = "digi-vxlan" ] || [ "${PD_PPPOE:-0}" = "1" ] || exit 0

VPP="${VPP:-/usr/bin/vppctl}"
DST="${PD_VTEP:-2a0e:97c0:4c1::60}"
VNI="${VXLAN_VNI:-100}"
PORT="${VXLAN_PORT:-4789}"
INST="${DIGI_VXLAN_INSTANCE:-${LAB_VXLAN_INSTANCE:-209}}"
BD="${LAB_BD:-208}"
LOOP="${LAB_LOOP:-loop208}"
MTU="${VXLAN_MTU:-1400}"

SRC=$($VPP show pppoe client detail 2>/dev/null | sed -n 's/.*wan-ipv6 observed \([^ /]*\).*/\1/p' | tr -d '\r' | head -1)
SRC=${SRC%%/*}
if [ -z "$SRC" ] || [ "$SRC" = "<none>" ]; then
  SRC=$($VPP show interface addr digi 2>/dev/null | awk '/L3 2a/{gsub(/\/.*/,"",$2); print $2; exit}')
fi
[ -n "$SRC" ] || exit 0

CUR=$($VPP show vxlan tunnel 2>/dev/null | awk -v v="$VNI" '
  $0 ~ ("vni " v) {
    for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }
  }')
[ "$CUR" = "$SRC" ] && exit 0

echo "pd-vxlan-vtep-watchdog: VTEP drift $CUR -> $SRC (no PPPoE/VPP restart)"
$VPP create vxlan tunnel src "$CUR" dst "$DST" vni "$VNI" instance "$INST" del 2>/dev/null || \
  $VPP create vxlan tunnel src 10.255.36.1 dst 77.90.4.48 vni "$VNI" instance "$INST" del 2>/dev/null || true
$VPP create vxlan tunnel src "$SRC" dst "$DST" vni "$VNI" instance "$INST" dst_port "$PORT" 2>/dev/null || true
IFACE="vxlan_tunnel${INST}"
$VPP set interface l2 bridge "$IFACE" "$BD" 2>/dev/null || true
$VPP set interface state "$IFACE" up 2>/dev/null || true
$VPP set interface mtu packet "$MTU" "$IFACE" 2>/dev/null || true
printf '%s\n' "$SRC" > /run/pd-vxlan-digi-vtep.txt
# best-effort nudge VPS (key must exist)
if [ -r /root/.ssh/id_ed25519_pd_vps ]; then
  ssh -i /root/.ssh/id_ed25519_pd_vps -o BatchMode=yes -o ConnectTimeout=5 \
    root@77.90.4.48 "DIGI_VTEP=$SRC /usr/local/sbin/pd-vpp-digi-vxlan-vps.sh" >/dev/null 2>&1 || true
fi
