#!/bin/sh
set -eu
MSS="1408"
VPP="/usr/bin/vppctl -s /run/vpp/cli.sock"
IFS_TO_CLAMP="x520lan x520extra0 x520extra1 loop10 gre0"

for _ in $(seq 1 60); do
  if $VPP show version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

for iface in $IFS_TO_CLAMP; do
  if $VPP show interface "$iface" >/dev/null 2>&1; then
    # Prefer SYN-only tcp-mss-clamp; L2 clamp inspects every frame (too costly at multi-G).
    $VPP set interface l2-mss-clamp "$iface" disable >/dev/null 2>&1 || true
    $VPP set interface tcp-mss-clamp "$iface" ip4 tx ip4-mss "$MSS" ip6 disable >/dev/null 2>&1 || true
  fi
done
exit 0
