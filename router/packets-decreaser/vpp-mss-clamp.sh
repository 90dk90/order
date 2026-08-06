#!/bin/sh
# MSS clamp for PD — enable on VXLAN path; leave unused ifaces disabled.
# Does not restart VPP/PPPoE.
set -eu
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
for _ in $(seq 1 60); do $VPP show version >/dev/null 2>&1 && break; sleep 1; done

MSS="${PD_VXLAN_MSS:-1360}"

# Disable on non-PD / unused
for iface in x520extra0 x520extra1 gre0; do
  $VPP set interface l2-mss-clamp "$iface" disable >/dev/null 2>&1 || true
done

# Enable on VXLAN PD path + LAN BVI
for iface in loop208 vxlan_tunnel208 loop10; do
  if $VPP show interface 2>/dev/null | grep -q "^${iface}[[:space:]]"; then
    $VPP set interface l2-mss-clamp "$iface" mss "$MSS" enable >/dev/null 2>&1 || \
      $VPP set interface l2-mss-clamp "$iface" enable >/dev/null 2>&1 || true
  fi
done

$VPP show l2-mss-clamp 2>/dev/null || true
