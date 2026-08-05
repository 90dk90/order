#!/bin/bash
# Enable L2 TCP MSS clamp on PD VXLAN path (MTU 1400 → MSS 1360).
# Safe anytime — does not restart VPP or PPPoE.
set -euo pipefail
. /etc/pd/pd-vxlan-lab.conf 2>/dev/null || . "$(dirname "$0")/pd-vxlan-lab.conf" 2>/dev/null || true

VPP="${VPP:-/usr/bin/vppctl}"
MSS="${PD_VXLAN_MSS:-1360}"
LAB_LOOP="${LAB_LOOP:-loop208}"
IFACE="vxlan_tunnel${LAB_VXLAN_INSTANCE:-208}"

$VPP show version >/dev/null

for iface in "$LAB_LOOP" "$IFACE" loop10; do
  if $VPP show interface 2>/dev/null | awk -v n="$iface" '$1==n{f=1} END{exit !f}'; then
    $VPP set interface l2-mss-clamp "$iface" mss "$MSS" enable 2>/dev/null || \
      $VPP set interface l2-mss-clamp "$iface" enable 2>/dev/null || true
  fi
done

echo "pd-vpp-vxlan-mss: mss=$MSS on $LAB_LOOP $IFACE loop10 (no VPP/PPPoE restart)"
$VPP show l2-mss-clamp 2>/dev/null || true
